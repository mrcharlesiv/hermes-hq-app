using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using Hermes.Core.Composer;

namespace Hermes.Core.Insights;

/// Spawn Tree (HermesKit/Pages/More/SpawnTree.swift, docs/spec/3x-morepages.md §16): the gateway's own list of running
/// subagents, JSON-RPC `delegation.status` with `{"profile"?}` only, one call per bot. The lenient decoder and the pure
/// tree builder (grouped by bot, then by owning chat; orphans attach to the root, cycles are broken, repeated ids are
/// dropped) with its words.
public enum SpawnStatus { Running, Queued, Done, Failed }

public static class SpawnStatusWords
{
    public static SpawnStatus Parse(string? raw) => (raw ?? "").ToLowerInvariant() switch
    {
        "queued" or "pending" or "waiting" or "starting" => SpawnStatus.Queued,
        "done" or "completed" or "complete" or "finished" or "success" or "succeeded" => SpawnStatus.Done,
        "failed" or "error" or "errored" or "interrupted" or "timeout" or "timed_out" or "cancelled" or "canceled" or "killed" => SpawnStatus.Failed,
        _ => SpawnStatus.Running,
    };

    /// The web's four words: Running / Failed / Done / Queued.
    public static string Word(this SpawnStatus s) => s switch
    {
        SpawnStatus.Running => "Running",
        SpawnStatus.Queued => "Queued",
        SpawnStatus.Done => "Done",
        _ => "Failed",
    };
}

public sealed record SpawnRecord(string Id, string? ParentId = null, int? Depth = null, string? Goal = null, string? Model = null,
    double? StartedAt = null, SpawnStatus Status = SpawnStatus.Running, int? ToolCount = null, string? OwnerSession = null)
{
    /// null for a record with no id (it cannot be a row).
    public static SpawnRecord? From(JsonNode? j)
    {
        if (j is not JsonObject) return null;
        if (PgString(j.Get("subagent_id")) is not { Length: > 0 } id) return null;
        var goal = j.Get("goal") is JsonValue gv && gv.TryGetValue(out string? g) && g.Trim().Length > 0 ? g : null;
        var model = j.Get("model") is JsonValue mv && mv.TryGetValue(out string? m) && m.Length > 0 ? m : null;
        var status = j.Get("status") is JsonValue sv && sv.TryGetValue(out string? st) ? st : null;
        return new SpawnRecord(id,
            PgString(j.Get("parent_id")) is { Length: > 0 } p ? p : null,
            IntOf(j.Get("depth")), goal, model, Seconds(j.Get("started_at")), SpawnStatusWords.Parse(status),
            IntOf(j.Get("tool_count")) is { } t ? Math.Max(0, t) : null,
            PgString(j.Get("owner_agent_session_id")) is { Length: > 0 } o ? o : null);
    }

    /// A string, or a number written as one ("9"), or a bool's word.
    internal static string? PgString(JsonNode? v) => v switch
    {
        JsonValue jv when jv.TryGetValue(out string? s) => s,
        JsonValue jv when jv.GetValueKind() == JsonValueKind.Number && jv.TryGetValue(out double d) =>
            Math.Round(d) == d && Math.Abs(d) < 9.007e15 ? ((long)d).ToString(CultureInfo.InvariantCulture) : d.ToString(CultureInfo.InvariantCulture),
        JsonValue jv when jv.GetValueKind() == JsonValueKind.True => "true",
        JsonValue jv when jv.GetValueKind() == JsonValueKind.False => "false",
        _ => null,
    };

    internal static double? Double(JsonNode? v) => v switch
    {
        JsonValue jv when jv.GetValueKind() == JsonValueKind.Number && jv.TryGetValue(out double d) => d,
        JsonValue jv when jv.TryGetValue(out string? s) && double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) => d,
        _ => null,
    };

    internal static int? IntOf(JsonNode? v) => Double(v) is { } d && double.IsFinite(d) && Math.Abs(d) < 2e9 ? (int)d : null;

    internal static double? Seconds(JsonNode? v) => Double(v) is { } d && double.IsFinite(d) && d > 0 ? d : null;
}

public sealed record DelegationStatus(IReadOnlyList<SpawnRecord> Active, bool Paused = false, int? MaxDepth = null, int? MaxChildren = null)
{
    public static DelegationStatus Parse(JsonNode? j) => new(
        [.. (j.Arr("active") ?? []).Select(SpawnRecord.From).OfType<SpawnRecord>()],
        j.Get("paused") is JsonValue pv && pv.TryGetValue(out bool p) && p,
        SpawnRecord.IntOf(j.Get("max_spawn_depth")), SpawnRecord.IntOf(j.Get("max_concurrent_children")));
}

public static class SpawnTreeApi
{
    /// `delegation.status` with `{"profile": id}` for a named bot and `{}` for the default one: no other key.
    public static async Task<DelegationStatus> StatusAsync(HermesClient client, string? profile, CancellationToken ct = default) =>
        DelegationStatus.Parse(await client.Rpc.RequestAsync("delegation.status", InsightsWire.ProfileParams(profile), TimeSpan.FromSeconds(15), ct));
}

public sealed class SpawnTree
{
    public sealed record Row(string Id, SpawnRecord Record, int Level)
    {
        /// The indent drawn: `Level` capped at `MaxIndent`.
        public int Indent => Math.Min(Level, MaxIndent);
    }
    public sealed record Chat(string Id, string? SessionId, string Title, IReadOnlyList<Row> Rows);
    public sealed record BotGroup(string Id, IReadOnlyList<Chat> Chats)
    {
        public int Count => Chats.Sum(c => c.Rows.Count);
        public int Running => Chats.Sum(c => c.Rows.Count(r => r.Record.Status == SpawnStatus.Running));
    }
    /// What the app knows about a chat: its bot and title.
    public sealed record Session(string Profile, string Title);

    public const int MaxIndent = 4;
    public const double IndentWidth = 16;
    /// Narrow/wide dashboard breakpoint matching Mac's 960 pt at Catalyst scale (741.76 stays List; >= 742 shows Dashboard).
    public const double WideAt = 742;

    public static bool IsWide(double width) => double.IsFinite(width) && width >= WideAt;

    public List<BotGroup> Bots { get; } = [];
    public bool Paused { get; set; }

    public int Total => Bots.Sum(b => b.Count);
    public int Active => Bots.Sum(b => b.Running);
    public bool IsEmpty => Total == 0;
    public IEnumerable<SpawnRecord> Records => Bots.SelectMany(b => b.Chats.SelectMany(c => c.Rows.Select(r => r.Record)));

    /// "14 subagents · 9 active".
    public string Header => $"{Total} {(Total == 1 ? "subagent" : "subagents")} · {Active} active";

    /// Value equality on what is drawn (the page redraws only when it changed).
    public string Signature => (Paused ? "P|" : "") + string.Join(";", Bots.Select(b => b.Id + ":" +
        string.Join(",", b.Chats.Select(c => c.Id + "=" + c.Title + "[" + string.Join(",", c.Rows.Select(r => $"{r.Id}/{r.Level}/{r.Record}")) + "]"))));

    /// Groups each bot's answer by bot, then by owning chat. A subagent listed under several bots is kept once: under the
    /// bot that owns its chat when the app knows the chat, else under the first bot that listed it.
    public static SpawnTree Build(IReadOnlyList<(string Profile, DelegationStatus Status)> answers, IReadOnlyDictionary<string, Session> sessions)
    {
        var owner = new Dictionary<string, string>();
        var order = new List<string>();
        var records = new Dictionary<string, SpawnRecord>();
        foreach (var (profile, status) in answers)
            foreach (var record in status.Active)
            {
                if (records.ContainsKey(record.Id)) continue;
                records[record.Id] = record;
                order.Add(record.Id);
                owner[record.Id] = record.OwnerSession != null && sessions.TryGetValue(record.OwnerSession, out var s) ? s.Profile : profile;
            }
        var profiles = answers.Select(a => a.Profile).ToList();
        foreach (var id in order) if (!profiles.Contains(owner[id])) profiles.Add(owner[id]);

        var tree = new SpawnTree { Paused = answers.Any(a => a.Status.Paused) };
        var seen = new HashSet<string>();
        foreach (var profile in profiles)
        {
            if (!seen.Add(profile)) continue;
            var mine = order.Where(id => owner[id] == profile).Select(id => records[id]).ToList();
            if (mine.Count == 0) continue;
            var chatOrder = new List<string>();
            var byChat = new Dictionary<string, List<SpawnRecord>>();
            foreach (var record in mine)
            {
                var key = record.OwnerSession ?? "";
                if (!byChat.TryGetValue(key, out var list)) { chatOrder.Add(key); byChat[key] = list = []; }
                list.Add(record);
            }
            var chats = chatOrder.Select(key =>
            {
                var title = sessions.TryGetValue(key, out var s) ? s.Title.Trim() : "";
                var rows = Flatten(byChat[key]).Select(x => new Row(profile + "|" + x.Record.Id, x.Record, x.Level)).ToList();
                return new Chat(profile + "|" + key, key.Length == 0 ? null : key, title.Length == 0 ? "Chat" : title, rows);
            }).ToList();
            tree.Bots.Add(new BotGroup(profile, chats));
        }
        return tree;
    }

    /// The records in tree order (a parent, then its children by start time) with each one's level. A record whose parent
    /// is not in the list is a root; a cycle is entered at its earliest member, which becomes a root.
    public static List<(SpawnRecord Record, int Level)> Flatten(IReadOnlyList<SpawnRecord> records)
    {
        var byId = new Dictionary<string, SpawnRecord>();
        var order = new List<string>();
        foreach (var r in records) if (byId.TryAdd(r.Id, r)) order.Add(r.Id);
        var position = order.Select((id, i) => (id, i)).ToDictionary(x => x.id, x => x.i);
        int Compare(string a, string b)
        {
            var x = byId[a].StartedAt ?? double.MaxValue;
            var y = byId[b].StartedAt ?? double.MaxValue;
            return x != y ? x.CompareTo(y) : position[a].CompareTo(position[b]);
        }
        var children = new Dictionary<string, List<string>>();
        var roots = new List<string>();
        foreach (var id in order)
        {
            if (byId[id].ParentId is { } parent && parent != id && byId.ContainsKey(parent))
            {
                if (!children.TryGetValue(parent, out var l)) children[parent] = l = [];
                l.Add(id);
            }
            else roots.Add(id);
        }
        var output = new List<(SpawnRecord, int)>();
        var visited = new HashSet<string>();
        void Walk(string start)
        {
            var stack = new Stack<(string Id, int Level)>();
            stack.Push((start, 0));
            while (stack.Count > 0)
            {
                var (id, level) = stack.Pop();
                if (!visited.Add(id)) continue;
                output.Add((byId[id], level));
                if (!children.TryGetValue(id, out var kids)) continue;
                var sorted = kids.ToList();
                sorted.Sort(Compare);
                for (var i = sorted.Count - 1; i >= 0; i--)
                    if (!visited.Contains(sorted[i])) stack.Push((sorted[i], level + 1));
            }
        }
        roots.Sort(Compare);
        foreach (var root in roots) Walk(root);
        while (true)
        {
            var left = order.Where(id => !visited.Contains(id)).ToList();
            if (left.Count == 0) break;
            left.Sort(Compare);
            Walk(left[0]);
        }
        return output;
    }

    // ------------------------------------------------------------------ words

    /// 45 → "45s", 130 → "2m 10s", 3900 → "1h 5m", 93,600 → "1d 2h"; null for a time that is not known.
    public static string? Duration(double? seconds)
    {
        if (seconds is not { } d || !double.IsFinite(d) || d < 0 || d >= 3.2e9) return null;
        var s = (long)d;
        if (s < 60) return $"{s}s";
        if (s < 3600) return $"{s / 60}m {s % 60}s";
        if (s < 86400) return $"{s / 3600}h {s % 3600 / 60}m";
        return $"{s / 86400}d {s % 86400 / 3600}h";
    }

    public static string Tools(int count) => count == 1 ? "1 tool" : $"{count} tools";

    /// "Hermes 4 · 3 tools · running 2m 10s".
    public static string Detail(SpawnRecord r, double now)
    {
        var parts = new List<string>();
        if (r.Model != null) parts.Add(ModelNames.DisplayModelName(r.Model));
        if (r.ToolCount is { } c) parts.Add(Tools(c));
        parts.Add(r.Status switch
        {
            SpawnStatus.Running => Duration(r.StartedAt is { } st ? now - st : null) is { } t ? $"running {t}" : "running",
            SpawnStatus.Queued => "queued",
            SpawnStatus.Done => "done",
            _ => "failed",
        });
        return string.Join(" · ", parts);
    }

    /// Narrator: "Read the networking changes, Running, Opus 5, 7 tools, for 2 minutes, 35 seconds, level 2".
    public static string Spoken(Row row, double now)
    {
        var parts = new List<string> { row.Record.Goal ?? "Subagent", row.Record.Status.Word() };
        if (row.Record.Model != null) parts.Add(ModelNames.DisplayModelName(row.Record.Model));
        if (row.Record.ToolCount is { } c) parts.Add(Tools(c));
        if (row.Record.Status == SpawnStatus.Running && row.Record.StartedAt is { } st && now >= st)
            parts.Add("for " + FullDuration(now - st));
        if (row.Level > 0) parts.Add($"level {row.Level + 1}");
        return string.Join(", ", parts);
    }

    /// DateComponentsFormatter .full, two units at most: "2 minutes, 10 seconds".
    public static string FullDuration(double seconds)
    {
        var s = (long)Math.Max(0, seconds);
        var units = new (long Size, string One)[] { (86400 * 7, "week"), (86400, "day"), (3600, "hour"), (60, "minute"), (1, "second") };
        var parts = new List<string>();
        foreach (var (size, one) in units)
        {
            if (parts.Count == 2) break;
            var n = s / size;
            if (n == 0 && parts.Count == 0) continue;
            if (n == 0) break;
            parts.Add($"{n} {one}{(n == 1 ? "" : "s")}");
            s -= n * size;
        }
        return parts.Count == 0 ? "0 seconds" : string.Join(", ", parts);
    }

    // ------------------------------------------------------------------ the Mac's dashboard (SpawnDashboard.swift)

    /// "3 Subagents Working".
    public string Headline => Active == 0 ? "No Subagents Working" : Active == 1 ? "1 Subagent Working" : $"{Active} Subagents Working";

    /// "14 listed, for 2 bots in 3 chats."
    public string HeadlineDetail
    {
        get
        {
            if (IsEmpty) return "Helpers a bot starts show up here while they run.";
            var chats = Bots.Sum(b => b.Chats.Count);
            return $"{Total} listed, for {Bots.Count} {(Bots.Count == 1 ? "bot" : "bots")} in {chats} {(chats == 1 ? "chat" : "chats")}.";
        }
    }

    /// The four tiles: title, value, note, whether the note is red.
    public IReadOnlyList<(string Title, string Value, string Note, bool Red)> Tiles(double now)
    {
        var rs = Records.ToList();
        int Count(SpawnStatus s) => rs.Count(r => r.Status == s);
        var starts = rs.Where(r => r.Status == SpawnStatus.Running && r.StartedAt != null).Select(r => r.StartedAt!.Value).ToList();
        var longest = starts.Count > 0 ? Duration(now - starts.Min()) : null;
        var failed = Count(SpawnStatus.Failed);
        return
        [
            ("Running", Count(SpawnStatus.Running).ToString(CultureInfo.InvariantCulture), longest != null ? $"longest {longest}" : "working now", false),
            ("Queued", Count(SpawnStatus.Queued).ToString(CultureInfo.InvariantCulture), "waiting to start", false),
            ("Done", Count(SpawnStatus.Done).ToString(CultureInfo.InvariantCulture), "finished, still listed", false),
            ("Failed", failed.ToString(CultureInfo.InvariantCulture), failed > 0 ? "stopped with an error" : "none", failed > 0),
        ];
    }

    public static string BotSummary(BotGroup bot) => $"{bot.Count} {(bot.Count == 1 ? "subagent" : "subagents")} · {bot.Running} running";
}

/// The page's words (App/Pages/More/SpawnTree/SpawnTreePage.swift, SpawnDashboard.swift).
public static class SpawnTreeCopy
{
    public const string Title = "Spawn Tree";
    public const string Loading = "Loading subagents…";
    public const string LoadFailed = "Couldn’t Load Spawn Tree";
    public const string EmptyTitle = "No Subagents Running";
    public const string EmptyText = "When a bot hands work to subagents (helper bots it starts), they show up here while they run.";
    public const string RefreshFailed = "Couldn’t refresh. Showing the last list.";
    public const string Paused = "New subagents are paused on this gateway.";
    public const string NoLive = "No live subagents.";
    public const string OpenChat = "Open Chat";
    public const string CopyTask = "Copy Task";
    public const string OpensChat = "Opens the chat";
    public const string Subagents = "Subagents";
    public static readonly string[] Headings = ["TASK", "MODEL", "TOOLS", "STATUS", "TIME"];
    /// The read every 3 s while on screen, 10 s after a failed read.
    public static readonly TimeSpan Interval = TimeSpan.FromSeconds(3), ErrorInterval = TimeSpan.FromSeconds(10);
}
