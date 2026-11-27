using System.Globalization;
using System.Text;

namespace Hermes.Core.Transcripts;

// Port of HermesKit/Chat/Transcript/TimelineNotes.swift (docs/spec/3x-transcript.md §2.2): timeline notes in words, the
// failed-turn note beside its error card, the silent run, process and helper notes, and the request Hermes restates
// after compressing a chat. The list pass (`resolve`) waits for the C# model's report/silentNote fields; these are its
// pieces. The silent-run words come from HermesKit/Chat/Hydration.swift, the heredoc fold from ToolWords.swift.

public enum TimelineNoteKind
{
    /// Drawn as a centred note with these words.
    Words,
    /// Not drawn.
    Hidden,
    /// Left as it is.
    Raw,
}

public sealed record TimelineNote(TimelineNoteKind Kind, string Text = "")
{
    public static TimelineNote OfWords(string words) => new(TimelineNoteKind.Words, words);
    public static readonly TimelineNote Hidden = new(TimelineNoteKind.Hidden);
    public static TimelineNote OfRaw(string text) => new(TimelineNoteKind.Raw, text);
}

public static class TimelineNotes
{
    private static readonly TranscriptRx ModelSwitch = new(@"^\[System: The active model for this chat has changed to (\S+?)(?: via provider (\S+?))?\. From this point");
    private static readonly TranscriptRx FailedTurn = new(@"^(?:Your request was not processed\.|This turn did not complete\.)");
    private static readonly TranscriptRx SystemNote = new(@"^\[System:\s*([\s\S]*?)\]?\s*$");

    /// A reply's text longer than this (UTF-8 bytes, all text parts) can't be a padded "[SILENT]".
    public const int SilentScanLimit = 256;

    /// Hydration.silentRunText.
    public const string SilentRunText = "Nothing to report — this run was silent";

    /// The note of a turn that failed ("Your request was not processed. …").
    public static bool IsFailedTurn(string words) => FailedTurn.Test(words);

    private const string TaskSnapshotHeader = "[Your active task list was preserved across context compression]";

    /// `tools/todo_tool.py` reinjects the agent's task list as a user-role row after compression: not a message from the
    /// person, nor a progress update.
    public static bool IsTaskSnapshot(string text)
    {
        var trimmed = text.TrimStart();
        if (!trimmed.StartsWith(TaskSnapshotHeader, StringComparison.Ordinal)) return false;
        var rest = trimmed[TaskSnapshotHeader.Length..];
        if (rest.Length > 0 && !char.IsWhiteSpace(rest[0])) return false;
        var body = rest.TrimStart();
        return body.Length == 0 || new[] { "- [>] ", "- [ ] ", "- [x] ", "- [~] ", "- [?] " }.Any(m => body.StartsWith(m, StringComparison.Ordinal));
    }

    /// "Model changed to Opus 5.5"; the id when it has no name; "Model changed" when the text names none.
    /// `displayName`: the model's name for an id; ModelNames.DisplayModelName when not given (the Mac's default).
    public static string ModelSwitchLabel(string content, Func<string, string>? displayName = null)
    {
        var text = content.Trim();
        if (ModelSwitch.Groups(text) is not { } g || g[1] is not { Length: > 0 } id) return "Model changed";
        // [WIN-36] By default the model's name, as the Mac (`displayName: ModelNames.displayModelName`) and the switch toast.
        var name = ((displayName ?? Composer.ModelNames.DisplayModelName)(id) ?? id).Trim();
        // An id too long to be a name stays out of the timeline (bad data): the row says what happened.
        if (id.Length > 80) return "Model changed";
        return $"Model changed to {(name.Length == 0 ? id : name)}";
    }

    public static bool IsModelSwitch(string text) =>
        text.Trim().StartsWith("[System: The active model for this chat has changed", StringComparison.Ordinal);

    /// Hermes closing a failed turn (`agent/turn_failure_copy.py`).
    public static bool IsFailedTurnNote(string text) => FailedTurn.Test(text.Trim());

    /// A system row's text as the timeline reads it. `errorNearby`: an error card covers the same turn.
    public static TimelineNote Note(string text, bool errorNearby = false, Func<string, string>? displayName = null)
    {
        var trimmed = text.Trim();
        if (IsFailedTurnNote(trimmed)) return errorNearby ? TimelineNote.Hidden : TimelineNote.OfRaw(text);
        if (!trimmed.StartsWith("[System:", StringComparison.Ordinal)) return TimelineNote.OfRaw(text);
        if (IsModelSwitch(trimmed)) return TimelineNote.OfWords(ModelSwitchLabel(trimmed, displayName));
        if (SystemNote.Groups(trimmed) is not { } g || g[1] is not { } inside) return TimelineNote.OfRaw(text);
        var words = inside.Trim();
        return words.Length == 0 ? TimelineNote.Hidden : TimelineNote.OfWords(words);
    }

    // The silent run (HermesKit/Chat/Hydration.swift isSilentWords / isSilenceMarker)

    private static readonly HashSet<string> SilenceMarkers = ["[SILENT]", "SILENT", "NO_REPLY", "NO REPLY", "[静默]", "静默", "[沉默]", "沉默"];
    private static readonly TranscriptRx SilentStandIn = new(@"\b(?:no (?:additional|further) (?:\S+ ){0,2}(?:response|reply)|no (?:user[-‐‑ ]facing|visible) (?:response|reply)|no (?:response|reply) (?:is )?(?:needed|required|necessary)|nothing (?:further |more )?to (?:report|add|say))\b",
        System.Text.RegularExpressions.RegexOptions.IgnoreCase);

    /// The gateway's own silence markers, matched as it does: the whole reply, any case, stray punctuation at the ends.
    public static bool IsSilenceMarker(string text)
    {
        var t = text.Trim();
        if (t.Length == 0 || t.Length > 64) return false;
        static bool Edge(char c) => c != '[' && c != ']' && char.IsPunctuation(c);
        var core = t.AsSpan();
        while (core.Length > 0 && Edge(core[0])) core = core[1..];
        while (core.Length > 0 && Edge(core[^1])) core = core[..^1];
        static string Canon(string s) => string.Join(" ", s.ToUpperInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return SilenceMarkers.Contains(Canon(t)) || SilenceMarkers.Contains(Canon(core.ToString()));
    }

    /// The bot's way of saying nothing: "[SILENT]", or a one-line bracketed stand-in a model writes instead
    /// ("[Notification processed; no additional user-facing response.]", "(no user-facing response)", "*[No reply needed]*").
    public static bool IsSilentWords(string text)
    {
        var t = text.Trim();
        if (IsSilenceMarker(t)) return true;
        while (t.Length > 2 && (t[0] == '*' || t[0] == '_') && t[^1] == t[0]) t = t[1..^1];
        if (t.Length > 200 || t.Length < 2) return false;
        var open = t[0];
        char close;
        if (open == '[') close = ']'; else if (open == '(') close = ')'; else return false;
        if (t[^1] != close) return false;
        var inside = t[1..^1];
        if (inside.Contains(open) || inside.Contains(close) || inside.Contains('\n')) return false;
        return SilentStandIn.Test(t);
    }

    /// Whether a settled reply's text parts together are a silent run (the scan bound included).
    public static bool IsSilentReply(IEnumerable<string> textParts)
    {
        var parts = textParts.ToList();
        if (parts.Sum(p => Encoding.UTF8.GetByteCount(p)) > SilentScanLimit) return false;
        return IsSilentWords(string.Concat(parts));
    }

    // Restated requests

    /// The note's words for a request Hermes restated after compressing the chat.
    public const string RestatedTitle = "Chat compressed · still on your request";

    private static readonly TranscriptRx RestatedHeader = new(@"(?m)^[ \t]*\[STILL IN PROGRESS\s*[—–-][^\]\n]*\bcompaction\b[^\]\n]*\][ \t]*\r?\n?");

    /// A message holding a restated request: the words before Hermes's header (else empty) and the request after it.
    /// `memoLine`: a voice memo's transcript line for the request (VoiceMemo.parse(…).transcriptLine), when it is one.
    public static (string Before, string Request)? RestatedRequest(string text, Func<string, string?>? memoLine = null)
    {
        if (!text.Contains("[STILL IN PROGRESS") || RestatedHeader.First(text) is not { } m) return null;
        var before = text[..m.Index].Trim();
        var after = text[(m.Index + m.Length)..].Trim();
        return (before, memoLine?.Invoke(after) ?? after);
    }

    // Helper notes

    private static readonly TranscriptRx HelperCount = new(@"(\d+) subagents?\b");
    private static readonly TranscriptRx HelperStatus = new(@"(?m)^Status: *([A-Za-z_]+)");
    private static readonly TranscriptRx HelperGoal = new(@"(?m)^Original goal: *(.+)$");

    private static readonly Dictionary<string, string> Outcomes = new()
    {
        ["failed"] = "Failed", ["error"] = "Failed", ["rejected"] = "Failed", ["cancelled"] = "Cancelled",
        ["interrupted"] = "Interrupted", ["timeout"] = "Timed Out", ["stalled"] = "Stalled",
    };

    /// Hermes's own title for a helper's note: "Subagent Task Completed: <goal>" for one helper, "2 background agents
    /// finished" for a batch.
    public static string HelperTitle(string content)
    {
        if (content.StartsWith("[ASYNC DELEGATION BATCH", StringComparison.Ordinal))
            return HelperCount.Groups(content)?[1] is { } count ? $"{count} background agents finished" : "Background agents finished";
        var status = HelperStatus.Groups(content)?[1]?.ToLowerInvariant() ?? "";
        var outcome = Outcomes.GetValueOrDefault(status, "Completed");
        var goal = HelperGoal.Groups(content)?[1] is { } g ? TxText.TrimSpaces(g.TrimEnd('\r')) : "";
        if (goal.Length == 0) return outcome == "Completed" ? "1 background agent finished" : $"Subagent Task {outcome}";
        return $"Subagent Task {outcome}: {(goal.Length > 200 ? goal[..197] + "..." : goal)}";
    }

    // Process notes

    /// "Background process proc_… completed normally (exit code 0)." over "Command: …\nOutput: …": the note in plain
    /// words ("Background task finished: npm test"), with the gateway's own line at the top of what opens under it.
    public static (string Headline, string Detail)? ProcessHeadline(string words)
    {
        if (!words.StartsWith("Background process ", StringComparison.Ordinal)) return null;
        var cut = words.IndexOf('\n');
        var first = (cut < 0 ? words : words[..cut]).Trim();
        var rest = cut < 0 ? "" : words[(cut + 1)..].Trim();
        if (first.Length == 0) return null;
        if (ProcessWords(first, rest) is { } plain) return (plain, rest.Length == 0 ? first : first + "\n" + rest);
        if (rest.Length == 0) return null;
        return (first, rest);
    }

    private static readonly TranscriptRx ExitCode = new(@"exit[ _]?code\W{0,3}(-?\d+)", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
    private static readonly TranscriptRx FailedWords = new(@"\b(?:failed|killed|crashed|errored|timed out)\b", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
    private static readonly TranscriptRx FinishedWords = new(@"\b(?:completed|finished|exited|done)\b", System.Text.RegularExpressions.RegexOptions.IgnoreCase);

    /// "Background task finished" / "Background task failed", plus the command's short name when the detail names one;
    /// null when the line says neither.
    public static string? ProcessWords(string line, string detail)
    {
        bool ok;
        if (ExitCode.Groups(line)?[1] is { } c && int.TryParse(c, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var code)) ok = code == 0;
        else if (FailedWords.Test(line)) ok = false;
        else if (FinishedWords.Test(line)) ok = true;
        else return null;
        var words = ok ? "Background task finished" : "Background task failed";
        return ShortCommand(detail) is { } command ? $"{words}: {command}" : words;
    }

    private static readonly TranscriptRx Interpreter = new(@"^(?:python[0-9.]*|node|bun|deno|ruby|perl|bash|sh|zsh)$");
    private static readonly TranscriptRx ScriptFile = new(@"\.(?:py|js|mjs|cjs|ts|rb|pl|sh|zsh)$");

    /// The "Command:" line's command in short, cut to 40 characters: paths without their folders, and a script without
    /// the interpreter that runs it ("…/bin/python3 /Users/…/tools/report.py --week" → "report.py --week").
    public static string? ShortCommand(string detail)
    {
        var line = detail.Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault(l => l.StartsWith("Command:", StringComparison.Ordinal));
        if (line is null) return null;
        var command = TxText.TrimSpaces(CollapseHeredocs(line["Command:".Length..]).Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "");
        var parts = command.Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(word =>
        {
            if (!(word.StartsWith('/') || word.StartsWith("~/", StringComparison.Ordinal) || word.StartsWith("./", StringComparison.Ordinal))) return word;
            return word.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? word;
        }).ToList();
        if (parts.Count == 0) return null;
        if (Interpreter.Test(parts[0]))
        {
            var script = Enumerable.Range(1, parts.Count - 1).Where(i => !parts[i].StartsWith('-')).Select(i => (int?)i).FirstOrDefault();
            if (script is { } s && ScriptFile.Test(parts[s])) parts.RemoveRange(0, s);
        }
        var shortText = string.Join(" ", parts);
        return shortText.Length > 40 ? TxText.TrimSpaces(shortText[..39]) + "…" : shortText;
    }

    // ToolWords.collapseHeredocs (HermesKit/Chat/Transcript/ToolWords.swift, r6-13)

    private static readonly HashSet<string> Interpreters = ["python", "python3", "python2", "node", "bash", "sh", "zsh", "ruby", "perl", "php",
        "osascript", "deno", "bun", "lua", "Rscript", "swift", "sqlite3", "psql", "mysql", "jq"];
    private static readonly TranscriptRx Heredoc = new("""(?<!<)<<(-?)\s*(['"]?)([A-Za-z_][\w-]*)\2""");
    private static readonly TranscriptRx Assignment = new(@"^[A-Za-z_]\w*=");
    private static readonly TranscriptRx LeadingTabs = new(@"^\t+");
    private static readonly TranscriptRx SpacesRe = new(@"\s+");

    /// The script with each heredoc's body folded into its command: "python3 - <<'PY' … PY" is one line,
    /// "python3 script" (an interpreter reading its program), else the command without the heredoc.
    internal static string CollapseHeredocs(string text)
    {
        if (!Heredoc.Test(text)) return text;
        var out_ = new List<string>();
        string? end = null;
        var tabs = false;
        foreach (var line in text.Split('\n'))
        {
            if (end is not null)
            {
                var candidate = tabs ? LeadingTabs.Replace(line, "") : line;
                if (TxText.TrimSpaces(candidate) == end) end = null;
                continue;
            }
            if (Heredoc.Groups(line) is not { } g || g[0] is not { } whole || g[3] is not { } word) { out_.Add(line); continue; }
            end = word;
            tabs = g[1] == "-";
            var at0 = line.IndexOf(whole, StringComparison.Ordinal);
            var rest = at0 >= 0 ? line[..at0] + " " + line[(at0 + whole.Length)..] : line;
            rest = TxText.TrimSpaces(SpacesRe.Replace(rest, " "));
            var words = rest.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            var at = 0;
            while (at < words.Length && Assignment.Test(words[at])) at++;
            var head = at < words.Length ? (words[at].Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? "") : "";
            out_.Add(Interpreters.Contains(head) ? $"{head} script" : rest);
        }
        return string.Join("\n", out_);
    }

    /// While a reply streams, a text that could still turn out to be "[SILENT]" is held back (never drawn, not even for
    /// a frame): a prefix of the sentinel no longer than it.
    public static bool HoldsBack(string streamingText)
    {
        var t = streamingText.Trim();
        return t.Length > 0 && t.Length <= 8 && "[SILENT]".StartsWith(t, StringComparison.Ordinal);
    }

    // Automated session wakes (HermesKit/Chat/Transcript/TimelineNotes.swift `e89ac4d51`)

    private static readonly TranscriptRx BracketedWake = new(
        @"^\[(?:(Scheduled|Automatic)\s+(?:wake|wakeup|check|run|trigger)(?::\s*([^\]\n]{1,120}))?|Loop\s+wakeup(?:\s+#(\d+))?(?::\s*([^\]\n]{1,120}))?)\][ \t]*(?:\r?\n|$)",
        System.Text.RegularExpressions.RegexOptions.IgnoreCase);

    private static readonly TranscriptRx SelfDeclaredWake = new(
        @"^(?:(Scheduled|Automatic)\s+)?([^\n(.]{2,80}?)(?:\s*\(([^)\n]{3,80})\))?[.:]?\s+This is an automatic (?:check|wake|wakeup|run|trigger)\b[^\n.]*\bnot a message from\b[^\n.]*[.!]?[ \t\r\n]*",
        System.Text.RegularExpressions.RegexOptions.IgnoreCase);

    private static readonly HashSet<string> GenericWakeNouns = ["check", "wake", "wakeup", "run", "trigger", "task", "job"];

    public static bool IsScheduledWake(string text) => ScheduledWake(text) != null;

    /// An automated session wake injected as a prompt: its short centered clock-row title and clean trigger body.
    public static (string Title, string Detail)? ScheduledWake(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return null;
        if (trimmed.StartsWith('[') && BracketedWake.Groups(trimmed) is { } g && g[0] is { } whole)
        {
            var body = trimmed[whole.Length..].Trim();
            var explicitTitle = (g[2] ?? g[4])?.Trim();
            string title;
            if (!string.IsNullOrEmpty(explicitTitle)) title = UppercaseFirst(explicitTitle);
            else if (!string.IsNullOrEmpty(g[3])) title = $"Loop wakeup #{g[3]}";
            else if (g[1] == null) title = "Loop wakeup";
            else title = "Scheduled check";
            return (title, body.Length == 0 ? trimmed : body);
        }
        if (trimmed.IndexOf("not a message from", StringComparison.OrdinalIgnoreCase) < 0) return null;
        if (SelfDeclaredWake.Groups(trimmed) is not { } sg || sg[0] is not { } sWhole || sg[2] is not { } rawLabel) return null;
        var label = rawLabel.Trim();
        if (label.Length == 0) return null;
        var prefix = sg[1]?.Trim();
        var sTitle = !string.IsNullOrEmpty(prefix) && GenericWakeNouns.Contains(label.ToLowerInvariant())
            ? UppercaseFirst(prefix.ToLowerInvariant()) + " " + label.ToLowerInvariant()
            : UppercaseFirst(label);
        var id = sg[3]?.Trim();
        var sBody = trimmed[sWhole.Length..].Trim();
        string detail;
        if (sBody.Length > 0) detail = !string.IsNullOrEmpty(id) ? $"{sBody}\n\nID: {id}" : sBody;
        else if (!string.IsNullOrEmpty(id)) detail = $"ID: {id}";
        else detail = trimmed;
        return (sTitle, detail);
    }

    private static string UppercaseFirst(string s) => s.Length == 0 ? s : char.ToUpperInvariant(s[0]) + s[1..];
}
