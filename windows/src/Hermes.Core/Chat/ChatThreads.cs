using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Model;

namespace Hermes.Core.Chat;

/// [threads] Durable link between a thread session and the Bot Chat it started from (HermesKit/Chat/Threads/ChatThread.swift).
public sealed record BotThreadLink(string StoredId, string Profile, string ParentId, double StartedAt, int? AnchorRow = null)
{
    public const int MaxKept = 200;

    public JsonObject ToJson()
    {
        var o = new JsonObject
        {
            ["storedId"] = StoredId,
            ["profile"] = Profile,
            ["parentId"] = ParentId,
            ["startedAt"] = StartedAt,
        };
        if (AnchorRow is { } row) o["anchorRow"] = row;
        return o;
    }

    public static List<BotThreadLink> Decode(JsonNode? node)
    {
        if (node is not JsonArray arr) return [];
        var list = new List<BotThreadLink>();
        foreach (var item in arr)
        {
            var sid = item.Str("storedId")?.Trim();
            var prof = item.Str("profile")?.Trim();
            var parent = item.Str("parentId")?.Trim();
            var started = item.Num("startedAt");
            if (string.IsNullOrEmpty(sid) || string.IsNullOrEmpty(prof) || string.IsNullOrEmpty(parent) || started is null) continue;
            list.Add(new BotThreadLink(sid, prof, parent, started.Value, item.Int("anchorRow") is { } ar ? (int)ar : null));
        }
        return list;
    }

    public enum MergePolicy { Replace, FirstContact, Rebase }

    public static List<BotThreadLink> Merged(IReadOnlyList<BotThreadLink> local, IReadOnlyList<BotThreadLink> remote,
        IReadOnlyList<BotThreadLink> @base, MergePolicy policy)
    {
        static List<BotThreadLink> Dedupe(IEnumerable<BotThreadLink> items)
        {
            var seen = new HashSet<(string, string)>();
            var out_ = new List<BotThreadLink>();
            foreach (var item in items.OrderByDescending(x => x.StartedAt))
            {
                if (seen.Add((item.Profile, item.StoredId))) out_.Add(item);
                if (out_.Count == MaxKept) break;
            }
            return out_;
        }
        return policy switch
        {
            MergePolicy.Replace => Dedupe(remote),
            MergePolicy.FirstContact => Dedupe(remote.Concat(local)),
            _ => Rebase(),
        };

        List<BotThreadLink> Rebase()
        {
            if (local.SequenceEqual(@base)) return Dedupe(remote);
            var baseKeys = @base.Select(x => (x.Profile, x.StoredId)).ToHashSet();
            var localKeys = local.Select(x => (x.Profile, x.StoredId)).ToHashSet();
            var remoteKeys = remote.Select(x => (x.Profile, x.StoredId)).ToHashSet();
            var removed = baseKeys.Except(localKeys).Union(baseKeys.Except(remoteKeys)).ToHashSet();
            return Dedupe(local.Concat(remote).Where(x => !removed.Contains((x.Profile, x.StoredId))));
        }
    }
}

/// One side thread hanging inline in a bot chat (HermesKit/Chat/Threads/ChatThread.swift).
public sealed record ChatThread(
    string Id,
    string? StoredId,
    string? Title,
    DateTimeOffset StartedAt,
    string? AnchorMessageId,
    int? AnchorRow,
    IReadOnlyList<ChatMessage> Messages,
    bool Running,
    string? Problem = null)
{
    public IReadOnlyList<ChatMessage> Spoken => [.. Messages.Where(m => m.Role != Role.System)];
}

/// Calm routing banner shown over the composer when a busy chat auto-routes sends into a thread.
public sealed record ThreadBusyBanner(string Title, string Note, string? ThreadKey = null);

public enum BusyReasonKind { RunningReply, BackgroundTask, MessagingTurn, OtherWindow }

/// Pure thread anchoring, folding, and busy-chat auto-routing rules (HermesKit/Chat/Threads/ChatThread.swift).
public static class ThreadRules
{
    public const string DefaultTitle = "Thread";
    public const string BusyNotice = "This chat is busy, so your message went into a thread.";
    public static readonly TimeSpan BusyThreadTtl = TimeSpan.FromMinutes(15);
    public static readonly TimeSpan BusyOwnerGrace = TimeSpan.FromMilliseconds(1500);

    private static readonly Regex InheritedBotChatPattern = new(@"^bot chat(?:\s+#\d+)?$", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    public static ChatMessage? BusyAnchor(IReadOnlyList<ChatMessage> messages, string? leavingOutLocalId) =>
        messages.LastOrDefault(m => m.Id != leavingOutLocalId && m.Role != Role.System && !m.IsStreaming)
        ?? messages.LastOrDefault(m => m.Id != leavingOutLocalId && m.Role != Role.System);

    public static bool TakesNextBusySend(int? heldAt, int accepted, bool reachable, bool problem,
        bool mainIdleSinceHold, DateTimeOffset lastActivity, DateTimeOffset now, TimeSpan? ttl = null)
    {
        if (heldAt != accepted || !reachable || problem || mainIdleSinceHold) return false;
        return (now - lastActivity) <= (ttl ?? BusyThreadTtl);
    }

    public static string BackInMainNotice(string? botName)
    {
        var who = botName?.Trim();
        return $"{(string.IsNullOrEmpty(who) ? "The bot" : who)} is back in the main chat.";
    }

    public static ThreadBusyBanner ProactiveBanner(string? activeTitle, string? threadKey, BusyReasonKind reason = BusyReasonKind.RunningReply, string? messagingApp = null)
    {
        var title = string.IsNullOrWhiteSpace(activeTitle) || activeTitle.Trim() == DefaultTitle ? null : activeTitle.Trim();
        if (title != null)
            return new("Replying in Thread", $"Continuing “{title}”", threadKey);
        var note = reason switch
        {
            BusyReasonKind.BackgroundTask => "Busy with a background task",
            BusyReasonKind.MessagingTurn => string.IsNullOrWhiteSpace(messagingApp) ? "Busy with a messaging turn" : $"Busy with a {messagingApp} message",
            BusyReasonKind.OtherWindow => "Busy in another window",
            _ => "Busy in the main chat",
        };
        return new("Sending to Thread", note, threadKey);
    }

    public static int? AnchorIndex(ChatThread thread, IReadOnlyList<ChatMessage> messages)
    {
        if (!string.IsNullOrEmpty(thread.AnchorMessageId))
        {
            for (var i = messages.Count - 1; i >= 0; i--)
                if (messages[i].Id == thread.AnchorMessageId) return i;
        }
        if (thread.AnchorRow is { } row)
        {
            for (var i = messages.Count - 1; i >= 0; i--)
                if (messages[i].RowId == row) return i;
            int? best = null;
            var sawStored = false;
            for (var i = 0; i < messages.Count; i++)
            {
                if (messages[i].RowId is not { } own) continue;
                sawStored = true;
                if (own <= row) best = i;
            }
            if (best != null || sawStored) return best;
        }
        int? byTime = null;
        for (var i = 0; i < messages.Count; i++)
        {
            if (messages[i].Role != Role.User || messages[i].Timestamp is not { } at) continue;
            if (at <= thread.StartedAt) byTime = i; else break;
        }
        return byTime;
    }

    public static bool IsOpen(ChatThread thread, int anchor, IReadOnlyList<ChatMessage> messages)
    {
        if (thread.Running || thread.Problem != null) return true;
        for (var i = anchor + 1; i < messages.Count; i++)
        {
            var m = messages[i];
            if (m.Role == Role.Assistant && m.Sender == null && !m.IsStreaming && !string.IsNullOrWhiteSpace(m.Text))
                return false;
        }
        return true;
    }

    public static (IReadOnlyList<ChatMessage> Messages, int Earlier) Shown(ChatThread thread)
    {
        var spoken = thread.Spoken;
        for (var i = spoken.Count - 1; i >= 0; i--)
            if (spoken[i].Role == Role.User)
                return ([.. spoken.Skip(i)], i);
        return (spoken, 0);
    }

    public static bool IsInheritedBotChatTitle(string? title) =>
        !string.IsNullOrWhiteSpace(title) && InheritedBotChatPattern.IsMatch(title.Trim());

    public static string Name(ChatThread thread)
    {
        var title = thread.Title?.Trim();
        if (string.IsNullOrEmpty(title) || title == DefaultTitle || IsInheritedBotChatTitle(title)) return DefaultTitle;
        return title;
    }

    public static string CountWords(int count) => count == 1 ? "1 message" : $"{count} messages";

    public static (string Name, string? Tail) Header(ChatThread thread)
    {
        var (_, earlier) = Shown(thread);
        return (Name(thread), earlier > 0 ? CountWords(thread.Spoken.Count) : null);
    }

    public static Dictionary<int, List<ChatThread>> ByAnchor(IEnumerable<ChatThread> threads, IReadOnlyList<ChatMessage> messages)
    {
        var map = new Dictionary<int, List<ChatThread>>();
        foreach (var thread in threads.OrderBy(t => t.StartedAt))
        {
            if (AnchorIndex(thread, messages) is not { } idx) continue;
            if (!map.TryGetValue(idx, out var list)) map[idx] = list = [];
            list.Add(thread);
        }
        return map;
    }
}

/// Hidden seed history built for a new side thread (HermesKit/Chat/Threads/ThreadSeed.swift).
public static class ThreadSeed
{
    public sealed record Row(string Role, string Text);

    public const int MaxTurns = 24;
    public const int MaxCharacters = 16_000;
    public const int PerRowCharacters = 4_000;
    private static readonly Regex AnchorRx = new(@"\[thread anchor: row (\d+)\]", RegexOptions.Compiled);

    public static List<Row> Rows(IReadOnlyList<ChatMessage> messages, bool running, int? anchorRow = null, string? busyReason = null)
    {
        var merged = new List<Row>();
        foreach (var m in messages)
        {
            if (m.Role == Role.System || m.Sender != null || m.Error != null) continue;
            if (m.Role == Role.Assistant && m.IsStreaming) continue;
            var text = m.Text.Trim();
            if (text.Length == 0) continue;
            var role = m.Role == Role.User ? "user" : "assistant";
            if (merged.Count > 0 && merged[^1].Role == role)
                merged[^1] = merged[^1] with { Text = merged[^1].Text + "\n\n" + text };
            else
                merged.Add(new Row(role, text));
        }
        var kept = new List<Row>();
        var budget = MaxCharacters;
        for (var i = merged.Count - 1; i >= 0 && kept.Count < MaxTurns && budget > 0; i--)
        {
            var clipped = Clipped(merged[i].Text, Math.Min(PerRowCharacters, budget));
            budget -= clipped.Length;
            kept.Add(new Row(merged[i].Role, clipped));
        }
        kept.Reverse();
        while (kept.Count > 0 && kept[0].Role == "assistant") kept.RemoveAt(0);
        if (kept.Count == 0) return [];
        var note = ClosingNote(running && kept[^1].Role == "user", anchorRow, busyReason);
        if (kept[^1].Role == "assistant") kept[^1] = kept[^1] with { Text = kept[^1].Text + "\n\n" + note };
        else kept.Add(new Row("assistant", note));
        return kept;
    }

    public static string ClosingNote(bool running, int? anchorRow, string? busyReason = null)
    {
        string words;
        if (!string.IsNullOrWhiteSpace(busyReason))
            words = $"(The main chat is currently busy with {busyReason}. This is a side thread of the same chat: here I answer only what is asked in this thread, and I leave that job to the main chat.)";
        else if (running)
            words = "(I am still working on that in the main chat. This is a side thread of the same chat: here I answer only what is asked in this thread, and I leave that job to the main chat.)";
        else
            words = "(This is a side thread of the main chat above: here I answer only what is asked in this thread.)";
        return anchorRow is { } row ? $"{words} [thread anchor: row {row}]" : words;
    }

    public static int? AnchorRow(string text)
    {
        var matches = AnchorRx.Matches(text);
        if (matches.Count == 0) return null;
        return int.TryParse(matches[^1].Groups[1].Value, out var row) ? row : null;
    }

    public static bool IsClosingNote(string text) =>
        text.Contains("This is a side thread of the same chat: here I answer only what is asked in this thread", StringComparison.Ordinal)
        || text.Contains("This is a side thread of the main chat above: here I answer only what is asked in this thread", StringComparison.Ordinal);

    public static JsonArray Params(IReadOnlyList<Row> rows)
    {
        var arr = new JsonArray();
        foreach (var r in rows)
            arr.Add(new JsonObject { ["role"] = r.Role, ["content"] = r.Text, ["display_kind"] = "hidden" });
        return arr;
    }

    public static string Clipped(string text, int limit)
    {
        if (text.Length <= limit) return text;
        const string mark = "\n[…]\n";
        if (limit <= mark.Length + 40) return text[..Math.Max(0, limit)];
        var room = limit - mark.Length;
        var head = room * 2 / 3;
        return text[..head] + mark + text[^(room - head)..];
    }
}

/// Compact context note carried on the next main-chat prompt after an auto-thread settled.
public static class ThreadContextNote
{
    public const string Marker = "[Side thread context — handled while this chat was busy; use only as background for the message below]";
    public const int MaxCharacters = 2_400;
    public const int PerLineCharacters = 400;

    public static string? Format(IReadOnlyList<(string? Title, IReadOnlyList<ChatMessage> Messages)> threads, int maxCharacters = MaxCharacters)
    {
        var lines = new List<string>();
        var budget = maxCharacters - Marker.Length - 4;
        if (budget <= 80) return null;
        foreach (var (title, messages) in threads)
        {
            var spoken = messages.Where(m => m.Role != Role.System && m.Error == null && !m.IsStreaming).TakeLast(6).ToList();
            if (spoken.Count == 0) continue;
            var headerAdded = false;
            var heading = string.IsNullOrWhiteSpace(title) || title.Trim() == ThreadRules.DefaultTitle ? null : title.Trim();
            foreach (var m in spoken)
            {
                var raw = m.Text.Trim();
                if (raw.Length == 0) continue;
                var role = m.Role == Role.User ? "User" : "Assistant";
                var clipped = ThreadSeed.Clipped(raw.Replace('\n', ' '), PerLineCharacters);
                var line = $"- {role}: {clipped}";
                var cost = line.Length + 1;
                string? prefix = null;
                if (!headerAdded && heading != null)
                {
                    prefix = $"Thread “{heading}”:";
                    cost += prefix.Length + 1;
                }
                if (cost > budget) break;
                if (prefix != null) { lines.Add(prefix); headerAdded = true; }
                lines.Add(line);
                budget -= cost;
            }
        }
        return lines.Count == 0 ? null : Marker + "\n" + string.Join("\n", lines);
    }

    public static string Appended(string prompt, string note)
    {
        var trimmed = prompt.Trim();
        return trimmed.Length == 0 || note.Length == 0 ? prompt : trimmed + "\n\n" + note;
    }

    public static bool HasNote(string stored) => stored.Contains("\n\n" + Marker, StringComparison.Ordinal);

    public static string? Stripped(string stored)
    {
        var at = stored.IndexOf("\n\n" + Marker, StringComparison.Ordinal);
        if (at < 0) return null;
        var own = stored[..at].Trim();
        return own.Length == 0 ? null : own;
    }
}
