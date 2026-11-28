using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Bots;
using Hermes.Core.Model;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Groups;

// [botdm] One bot messaging another from its Bot Chat (port of HermesKit/Groups/BotDMs.swift).
// Hermes's `message_agent` tool (`tools/bot_mode_dm.py`) hands the message to a background runner; when the runner
// ends, the sender's chat gets "[IMPORTANT: Background process proc_… completed …] Command: …/bot_mode_dm.py
// --run-delivery … Output: {"reply": …, "status": "settled"}" on the user role. That note becomes the other bot
// speaking ("<Bot>: <its reply>", its face), nothing when it holds no reply, and a plain line when it failed.
public static class BotDMs
{
    public enum OutcomeKind { Replied, Delivered, NoReply, Failed }

    /// What the runner reported.
    public sealed record Outcome(OutcomeKind Kind, string? Text = null)
    {
        public static Outcome Replied(string reply) => new(OutcomeKind.Replied, reply);
        /// Delivered (or queued for a live chat) with no reply to show.
        public static readonly Outcome Delivered = new(OutcomeKind.Delivered);
        public static readonly Outcome NoReply = new(OutcomeKind.NoReply);
        public static Outcome Failed(string reason) => new(OutcomeKind.Failed, reason);
    }

    /// The tool a bot messages another bot with.
    public const string Tool = "message_agent";

    /// Hermes's placeholder when a turn ends without words ("⚠️ Processing completed but no response was generated…").
    public const string EmptyTurn = "Processing completed but no response was generated";

    private static readonly Regex PeerTarget = new(@"\bpeer\s+dm\s+'?([^\s']+)", RegexOptions.Compiled);
    private static readonly Regex ProfileFlag = new(@"/hermes\s+-p\s+'?([^\s']+)'?\s*$", RegexOptions.Compiled);
    private static readonly Regex ReplyFrom = new(@"^Reply from [^\n]*:\n([\s\S]+)$", RegexOptions.Multiline | RegexOptions.Compiled);
    private static readonly Regex FailedLine = new(@"^Delivery to [^\n]* failed[^:\n]*: *([^\n]*)", RegexOptions.Multiline | RegexOptions.Compiled);
    private static readonly Regex SentenceEnd = new(@"[.!?](\s|$)", RegexOptions.Compiled);
    private static readonly Regex InlineMarkdown = new(@"[*_`]", RegexOptions.Compiled);
    private static readonly Regex[] InternalAckPatterns =
    [
        new(@"\b(not|won['’]?t|am not|i['’]?m not)\s+(writing|messaging|replying|responding|notifying|pinging)\s+(to\s+)?(the\s+)?(owner|user)\b", RegexOptions.IgnoreCase | RegexOptions.Compiled),
        new(@"\bno\s+user[- ]facing\b", RegexOptions.IgnoreCase | RegexOptions.Compiled),
        new(@"\bstaying\s+silent\s+for\s+(the\s+)?(owner|user)\b", RegexOptions.IgnoreCase | RegexOptions.Compiled),
    ];

    /// A background-process note's words are a bot DM's runner finishing.
    public static bool IsDelivery(string words) =>
        words.Contains("bot_mode_dm.py", StringComparison.Ordinal)
        && words.Contains("--run-delivery", StringComparison.Ordinal);

    /// Who the message went to, as written in the runner's command: `peer dm <target>`, else the `-p <profile>` after
    /// the hermes program (the sender's own `-p` comes first on a peer DM, so the peer form is read first).
    public static string? Target(string words)
    {
        var command = words.Split('\n').FirstOrDefault(l => l.StartsWith("Command:", StringComparison.Ordinal));
        if (command == null) return null;
        var peer = PeerTarget.Match(command);
        if (peer.Success && peer.Groups[1].Value.Length > 0) return peer.Groups[1].Value;
        var profile = ProfileFlag.Match(command);
        return profile.Success && profile.Groups[1].Value.Length > 0 ? profile.Groups[1].Value : null;
    }

    /// The runner's verdict from its output: its JSON line (`reply`, `error`), or the older printed lines.
    public static Outcome OutcomeOf(string words)
    {
        var at = words.IndexOf("\nOutput:", StringComparison.Ordinal);
        if (at < 0) return Outcome.Delivered;
        // The note closes with a "]" line, then the gateway's own footer: the output ends before them.
        var tail = words[(at + "\nOutput:".Length)..];
        var closeBracket = tail.IndexOf("\n]", StringComparison.Ordinal);
        if (closeBracket >= 0) tail = tail[..closeBracket];
        var output = tail.Trim();

        var open = output.IndexOf('{');
        var close = output.LastIndexOf('}');
        if (open >= 0 && close > open && J.Parse(output[open..(close + 1)]) is JsonObject json)
        {
            if (json.Str("reply")?.Trim() is { Length: > 0 } reply)
            {
                // Hermes's stand-in for a turn that wrote nothing is no reply, not words from the other bot; so is the
                // other bot choosing to say nothing ("[Notification processed; no additional user-facing response.]").
                return reply.Contains(EmptyTurn, StringComparison.Ordinal) || TimelineNotes.IsSilentWords(reply)
                    ? Outcome.Delivered
                    : Outcome.Replied(reply);
            }
            if (json.Str("error") is { Length: > 0 } error) return Outcome.Failed(error);
            if (json.Str("reason") is { } reason) return Outcome.Failed(reason);
            return Outcome.Delivered;
        }

        var rf = ReplyFrom.Match(output);
        if (rf.Success)
        {
            var reply = rf.Groups[1].Value.Trim();
            if (reply.Length > 0 && reply != "(empty reply)") return Outcome.Replied(reply);
        }
        var fl = FailedLine.Match(output);
        if (fl.Success) return Outcome.Failed(fl.Groups[1].Value);
        if (output.StartsWith("No reply from ", StringComparison.Ordinal)) return Outcome.NoReply;
        return Outcome.Delivered;
    }

    /// [exchange] The words open by speaking to one of these bots by name: "Thanks, Otto.", "Otto, your diagnosis…",
    /// "@otto: confirmed", "Got it, Home —". Only the first sentence counts, and the name must be set off as an address
    /// (a comma, a colon, a dash, a greeting before it): "Otto found the cause" and "Thanks to Otto, it works" are about
    /// the bot, not to it.
    public static bool SpeaksTo(IEnumerable<string> names, string text)
    {
        var start = 0;
        while (start < text.Length && (char.IsWhiteSpace(text[start]) || "*_#>`".Contains(text[start]))) start++;
        var opening = text.Length - start > 160 ? text.Substring(start, 160) : text[start..];
        var nl = opening.IndexOfAny(['\r', '\n']);
        if (nl >= 0) opening = opening[..nl];
        var stop = SentenceEnd.Match(opening);
        if (stop.Success) opening = opening[..stop.Index];
        opening = InlineMarkdown.Replace(opening, "");

        var unique = new HashSet<string>(StringComparer.Ordinal);
        foreach (var raw in names)
        {
            var n = raw.Trim('@', ' ').ToLowerInvariant();
            if (n.Length > 1) unique.Add(n);
        }
        foreach (var name in unique)
        {
            var escaped = Regex.Escape(name);
            var bot = $@"@?{escaped}(?![\w-])";
            string[] patterns =
            [
                $@"^{bot}\s*([,:—–]|-\s|$)",
                $@"^@{escaped}(?![\w-])",
                $@",\s*{bot}\s*([,:—–]|-\s|$)",
                $@"^(hi|hey|hello|thanks|thank you|understood|got it|noted|ok|okay|confirmed|acknowledged|agreed|received|copy that|roger)[,\s]+{bot}\s*([,:—–]|-\s|$)",
            ];
            foreach (var p in patterns)
                if (Regex.IsMatch(opening, p, RegexOptions.IgnoreCase)) return true;
        }
        return false;
    }

    /// #601: an explicit internal bot-to-bot acknowledgement stating the bot is not replying to the owner, even when it
    /// omits the sending bot's name in the opening clause.
    public static bool IsInternalAck(string text)
    {
        var start = 0;
        while (start < text.Length && (char.IsWhiteSpace(text[start]) || "*_#>`".Contains(text[start]))) start++;
        var opening = text.Length - start > 200 ? text.Substring(start, 200) : text[start..];
        return InternalAckPatterns.Any(rx => rx.IsMatch(opening));
    }

    /// The bot a target names, as the incoming deliveries find it (handle, then name, then `hermes` → default).
    public static ChatSender Sender(string target, IReadOnlyList<DeliveryMessages.Seat> roster)
    {
        var bare = target.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? target;
        var handle = bare.Trim('@', ' ').ToLowerInvariant();
        var found = roster.FirstOrDefault(s => s.Profile.ToLowerInvariant() == handle)
            ?? roster.FirstOrDefault(s => RosterRules.Handle(s.Profile) == handle)
            ?? roster.FirstOrDefault(s => s.Name.Trim().ToLowerInvariant() == handle)
            ?? (handle == "hermes" ? roster.FirstOrDefault(s => s.Profile == "default") : null);
        if (found != null)
            return new ChatSender("delivery:" + found.Profile, found.Name, found.Head, found.Profile, ChatSenderColors.Hex(found.Head, found.Profile));
        return new ChatSender("delivery:?" + handle, bare, null, "default", null);
    }

    /// `messages` with each bot DM runner's note turned into the other bot's reply (a delivery from it), hidden when
    /// there is none to show, or a line when it failed. Runs before `TimelineNotes`, which would otherwise make it
    /// "Background task finished: python3". The same list comes back when there is none.
    public static (IReadOnlyList<ChatMessage> Messages, bool Found) Resolve(IReadOnlyList<ChatMessage> messages, IReadOnlyList<DeliveryMessages.Seat> roster)
    {
        List<ChatMessage>? out_ = null;
        for (var i = 0; i < messages.Count; i++)
        {
            var m = messages[i];
            if (m.Role != Role.User || m.Sender != null || m.Parts.Count != 1 || m.Parts[0] is not TextPart tp
                || !tp.Text.StartsWith("[IMPORTANT:", StringComparison.Ordinal)
                || CronDeliveries.ProcessNote(tp.Text) is not { } words
                || !IsDelivery(words))
                continue;
            out_ ??= [.. messages];
            var who = Target(words) is { } t ? Sender(t, roster) : null;
            var outcome = OutcomeOf(words);
            out_[i] = outcome.Kind switch
            {
                OutcomeKind.Replied => m with
                {
                    Sender = who ?? Sender("hermes", roster),
                    ReplyToOurDM = true,
                    Parts = [new TextPart(outcome.Text ?? "")],
                },
                OutcomeKind.Delivered => m with { Role = Role.System, Parts = [new TextPart("")] },
                OutcomeKind.NoReply => m with { Role = Role.System, Parts = [new TextPart(who != null ? $"No reply from {who.Name} yet" : "No reply yet")] },
                OutcomeKind.Failed => m with
                {
                    Role = Role.System,
                    Parts = [new TextPart(FormatFailed(who?.Name, outcome.Text))],
                },
                _ => m,
            };
        }
        return (out_ ?? messages, out_ != null);
    }

    private static string FormatFailed(string? whoName, string? reason)
    {
        var name = whoName ?? "the other bot";
        var why = (reason ?? "").Trim();
        if (why.Length == 0) return $"Couldn’t reach {name}";
        var clipped = why.Length > 200 ? why[..199].TrimEnd() + "…" : why;
        return $"Couldn’t reach {name}: {clipped}";
    }
}
