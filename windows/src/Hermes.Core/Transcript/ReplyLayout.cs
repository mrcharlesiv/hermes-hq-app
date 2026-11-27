using Hermes.Core.Model;

namespace Hermes.Core.Transcripts;

/// Tool Call Style (Settings › Chat › Tool Calls; HermesKit/Activity/ToolCallSettings.swift). At the Bottom is the
/// default (owner, 2026-10-28).
public enum ToolCallStyle { Rows, Line, Bottom, Bubbles, Header }
public enum ToolCallsAfterReply { Keep, Hide }

public static class ToolCallStyleWords
{
    public static string Title(this ToolCallStyle s) => s switch
    {
        ToolCallStyle.Rows => "Rows",
        ToolCallStyle.Line => "One Line",
        ToolCallStyle.Bottom => "At the Bottom",
        ToolCallStyle.Bubbles => "Bubbles",
        _ => "In Header",
    };

    /// The line under each option on Settings › Tool Calls (the Mac says "click").
    public static string Detail(this ToolCallStyle s) => s switch
    {
        ToolCallStyle.Rows => "Each run of steps is a quiet line you click to open.",
        ToolCallStyle.Line => "A reply’s steps fold into one line above its words, such as “Worked for 42s · 5 steps”.",
        ToolCallStyle.Bottom => "While the bot works, the line under the typing dots names each step as it runs. Then they fold into one line.",
        ToolCallStyle.Bubbles => "Each step in its own bubble, commands in a code block, as Hermes posts them in Telegram.",
        _ => "Steps stay out of the chat. The line under the bot’s name shows the step it’s on.",
    };

    public static string Title(this ToolCallsAfterReply a) => a == ToolCallsAfterReply.Keep ? "Keep" : "Hide";

    /// One Line and At the Bottom fold a reply's steps into one line (they differ only while it runs).
    public static bool Folds(this ToolCallStyle s) => s is ToolCallStyle.Line or ToolCallStyle.Bottom;

    public static string Key(this ToolCallStyle s) => s switch
    {
        ToolCallStyle.Rows => "rows", ToolCallStyle.Line => "line", ToolCallStyle.Bottom => "bottom",
        ToolCallStyle.Bubbles => "bubbles", _ => "header",
    };

    public static ToolCallStyle? Parse(string? key) => key switch
    {
        "rows" => ToolCallStyle.Rows, "line" => ToolCallStyle.Line, "bottom" => ToolCallStyle.Bottom,
        "bubbles" => ToolCallStyle.Bubbles, "header" => ToolCallStyle.Header, _ => null,
    };
}

/// A device-local preference store the app supplies (Windows: a JSON file under LocalAppData).
public interface IPreferences
{
    string? Get(string key);
    void Set(string key, string? value);
}

/// Tool Call Style, After Reply, Fewer Timestamps and Message Reactions, under the Mac's keys. Drawing only.
public static class ChatDisplaySettings
{
    public const string StyleKey = "hq.chat.toolCallStyle";
    public const string AfterReplyKey = "hq.chat.toolCallsAfterReply";
    public const string FewerTimestampsKey = "hq.chat.fewerTimestamps";
    public const string ReactionsKey = "hqn.reactions";

    public static IPreferences? Store { get; set; }
    public static event Action? Changed;

    public static ToolCallStyle Style
    {
        get => ToolCallStyleWords.Parse(Store?.Get(StyleKey)) ?? ToolCallStyle.Bottom;
        set { Store?.Set(StyleKey, value == ToolCallStyle.Bottom ? null : value.Key()); Changed?.Invoke(); }
    }

    public static ToolCallsAfterReply AfterReply
    {
        get => Store?.Get(AfterReplyKey) == "hide" ? ToolCallsAfterReply.Hide : ToolCallsAfterReply.Keep;
        set { Store?.Set(AfterReplyKey, value == ToolCallsAfterReply.Keep ? null : "hide"); Changed?.Invoke(); }
    }

    /// On by default (owner, 2026-10-19): a day line only when the date changes; a time only under the bot's replies.
    public static bool FewerTimestamps
    {
        get => Store?.Get(FewerTimestampsKey) != "false";
        set { Store?.Set(FewerTimestampsKey, value ? null : "false"); Changed?.Invoke(); }
    }

    /// Settings › Chat › Message Reactions, default Off: Off hides the React menu; reactions already there still show.
    public static bool Reactions
    {
        get => Store?.Get(ReactionsKey) == "true";
        set { Store?.Set(ReactionsKey, value ? "true" : null); Changed?.Invoke(); }
    }

    /// After Reply applies only outside In Header.
    public static bool HidesSteps => Style != ToolCallStyle.Header && AfterReply == ToolCallsAfterReply.Hide;
}

// MARK: - Rows

/// What one reply draws, top to bottom (App/Chat/ChatRow.swift appendAssistant, ported for one message).
public abstract record ReplyRow;
/// The reply's words (Markdown), several text parts with only silent things between them joined as one.
public sealed record WordsRow(string Text, int PartIndex, bool Streaming) : ReplyRow;
/// Rows style: a thought ("Thinking", "Thought for 7s", "Thought").
public sealed record ThoughtRow(string Title, string Text, bool Live, int PartIndex) : ReplyRow;
/// A run of steps as one line ("Explored 3 files, ran 5 commands"), or One Line's whole line ("Worked for 42s · 5
/// steps"), which opens on the thought and every step.
public sealed record StepsRow(string Key, IReadOnlyList<ToolCall> Steps, string Title, StepGlyph Glyph, bool Live,
    string? Meta = null, string? Short = null, string? Thought = null, bool IsLine = false) : ReplyRow;
/// Bubbles style: the run as a Telegram-style bubble of progress lines; Earlier lines folded away past eight.
public sealed record ToolBubbleRow(string Key, IReadOnlyList<ToolCall> Calls, IReadOnlyList<ToolLine> Lines, int Earlier) : ReplyRow;
/// A tool that draws its own card (clarify, image_generate, a delegate in Rows): ChatExtensions.ToolRenderers, else a step.
public sealed record CardRow(ToolCall Call) : ReplyRow;
/// The reply failed: the error card (title and words from TurnErrors / ErrorCard).
public sealed record ErrorRow(string Error, bool Retry) : ReplyRow;
/// "Stopped" under a reply that had said something.
public sealed record CaptionRow(string Text) : ReplyRow;
/// "Stopped before Hermes replied", with Retry when it is the newest turn.
public sealed record StoppedEarlyRow(string Text, bool Retry) : ReplyRow;
/// A part another feature draws (a photo, a file, a generated image), in its place among the reply's rows.
public sealed record PartRow(ChatPart Part, int PartIndex) : ReplyRow;

/// What a reply's layout needs from around it.
public sealed record ReplyContext
{
    public ToolCallStyle Style { get; init; } = ToolCallStyle.Bottom;
    public bool HideSteps { get; init; }
    public bool ShowReasoning { get; init; } = true;
    /// Show Steps brought this reply's hidden steps back.
    public bool Revealed { get; init; }
    /// StepRules.isWorking: it streams, or the chat runs and it is the newest reply after the last prompt.
    public bool Working { get; init; }
    /// The chat runs a turn and this is its newest message (At the Bottom holds the line back then).
    public bool RunningTail { get; init; }
    /// [WIN-OWN-TURN-ROWS] Another Hermes process's turn runs in the chat and this is its last row: its line says the
    /// latest step as a streaming reply's does (ChatRow.swift `oneLineRow`'s `externalTail`; TranscriptTurn.ExternalTail).
    public bool ExternalTail { get; init; }
    /// The turn's measured length, when this device saw it run (TurnMarks).
    public double? TurnSeconds { get; init; }
    /// Measured "Thought for Ns" seconds by reasoning part index.
    public IReadOnlyDictionary<int, double>? ReasoningSeconds { get; init; }
    public string BotName { get; init; } = "Hermes";
    /// Newest turn, nothing running, its prompt right above: the error card and "Stopped before…" offer Retry.
    public bool CanRetry { get; init; }
}

public static class ReplyLayout
{
    /// Steps drawn as rows of their own in every style, never on the reply's line (ProgressNotes.ownRows).
    private static readonly HashSet<string> OwnRows = ["message_agent", "image_generate", "clarify"];
    /// Bubbles shows at most this many lines before "N earlier".
    public const int BubbleShownLines = 8;

    public static IReadOnlyList<ReplyRow> Build(ChatMessage m, ReplyContext c)
    {
        var rows = new List<ReplyRow>();
        var run = new List<ToolCall>();
        var folded = new List<ToolCall>();
        var thoughts = new List<string>();
        int? firstThought = null;
        var workedSinceWords = false;
        var oneLine = c.Style.Folds();
        var parts = m.Parts;
        var lastVisible = -1;
        for (var i = parts.Count - 1; i >= 0 && lastVisible < 0; i--)
            if (Draws(parts[i])) lastVisible = i;
        var stepsHidden = StepsHidden(m, c);
        var notes = oneLine && !stepsHidden ? ProgressNotes(m, c.Working) : [];
        var drawsThought = !stepsHidden && c.ShowReasoning;

        void Flush(int end)
        {
            if (run.Count == 0) return;
            if (oneLine && !run.Any(t => t.Name == "clarify")) { folded.AddRange(run); run = []; return; }
            var live = m.IsStreaming && end >= lastVisible;
            var key = run[0].Id;
            if (c.Style == ToolCallStyle.Bubbles && !run.Any(t => t.Name == "clarify"))
            {
                var lines = run.Select(ToolLines.Line).ToList();
                var earlier = lines.Count > BubbleShownLines ? lines.Count - (BubbleShownLines - 1) : 0;
                rows.Add(new ToolBubbleRow(key, run, lines, earlier));
            }
            else
            {
                var title = RunSummary.Summarize(run, live);
                rows.Add(new StepsRow(key, run, title, RunSummary.GlyphFor(title), live));
            }
            run = [];
        }

        for (var i = 0; i < parts.Count; i++)
        {
            switch (parts[i])
            {
                case TextPart t:
                    var text = t.Text.Trim();
                    if (text.Length == 0) continue;
                    if (notes.Contains(i))
                    {
                        thoughts.Add(text);
                        firstThought ??= i;
                        workedSinceWords = false;
                        continue;
                    }
                    Flush(i - 1);
                    if (!workedSinceWords && rows.Count > 0 && rows[^1] is WordsRow joined)
                        rows[^1] = joined with { Text = joined.Text + "\n\n" + text, Streaming = m.IsStreaming };
                    else rows.Add(new WordsRow(text, i, m.IsStreaming));
                    workedSinceWords = false;
                    break;
                case ReasoningPart r:
                    var thought = r.Text.Trim();
                    if (thought.Length == 0 || !drawsThought) continue;
                    if (oneLine) { thoughts.Add(thought); firstThought ??= i; continue; }
                    Flush(i - 1);
                    var liveThought = m.IsStreaming && i >= lastVisible;
                    rows.Add(new ThoughtRow(StepWords.ThoughtTitle(Seconds(c, i), liveThought), thought, liveThought, i));
                    break;
                case ToolPart { Call: var call }:
                    if (RunSummary.Hidden(call)) continue;
                    workedSinceWords = true;
                    // Cards drawn in place in every style (clarify, generated images), and a delegate's card in Rows/Bubbles.
                    if (call.Name is "clarify" or "image_generate" || (call.Name == "delegate_task" && !oneLine && !stepsHidden))
                    {
                        Flush(i - 1);
                        rows.Add(new CardRow(call));
                        continue;
                    }
                    if (stepsHidden) continue;
                    if (RunSummary.StandsAlone(call.Name) && !oneLine)
                    {
                        Flush(i - 1);
                        run = [call];
                        Flush(i);
                        continue;
                    }
                    run.Add(call);
                    break;
                default:
                    Flush(i - 1);
                    rows.Add(new PartRow(parts[i], i));
                    workedSinceWords = true;
                    break;
            }
        }
        Flush(parts.Count - 1);
        // At the Bottom: no line above a reply while its turn runs (ToolNowRows.holdsLine).
        var holdsLine = c.Style == ToolCallStyle.Bottom && c.RunningTail;
        if (oneLine && (folded.Count > 0 || thoughts.Count > 0) && !holdsLine)
            rows.Insert(0, OneLineRow(m, folded, thoughts, firstThought, lastVisible, c));

        var produced = rows.Count > 0;
        if (m.Error is { } error) rows.Add(new ErrorRow(error, c.CanRetry));
        else if (m.Interrupted)
        {
            if (produced) rows.Add(new CaptionRow("Stopped"));
            else rows.Add(new StoppedEarlyRow($"Stopped before {c.BotName} replied", c.CanRetry));
        }
        return rows;
    }

    private static double? Seconds(ReplyContext c, int part) =>
        c.ReasoningSeconds != null && c.ReasoningSeconds.TryGetValue(part, out var s) ? s : null;

    private static bool Draws(ChatPart p) => p switch
    {
        TextPart t => t.Text.Trim().Length > 0,
        ReasoningPart r => r.Text.Trim().Length > 0,
        ToolPart tp => !RunSummary.Hidden(tp.Call),
        _ => true, // a feature's part (photos, files, generated images)
    };

    /// In Header hides every step; After Reply › Hide hides a finished reply's steps unless Show Steps brought them back
    /// (ActivityRows.stepsHidden).
    public static bool StepsHidden(ChatMessage m, ReplyContext c)
    {
        if (c.Style == ToolCallStyle.Header) return true;
        if (!c.HideSteps || c.Revealed) return false;
        return State(m.Parts, c.Working) == StepsState.Done;
    }

    public enum StepsState { Working, Done, Failed }

    /// Still working; finished cleanly; or finished with a failed call no prose after it accounts for (StepRules.state).
    public static StepsState State(IReadOnlyList<ChatPart> parts, bool working)
    {
        if (working) return StepsState.Working;
        var failed = -1;
        for (var i = parts.Count - 1; i >= 0; i--)
            if (parts[i] is ToolPart { Call.State: ToolState.Failed }) { failed = i; break; }
        if (failed < 0) return StepsState.Done;
        var explained = parts.Skip(failed + 1).Any(p => p is TextPart t && t.Text.Trim().Length > 0);
        return explained ? StepsState.Done : StepsState.Failed;
    }

    /// The reply has steps the menu can show or hide (the message menu's Show Steps / Hide Steps).
    public static bool HasSteps(ChatMessage m) => m.Parts.Any(p => p is ToolPart tp && !RunSummary.Hidden(tp.Call));

    /// [narration] Once a reply has settled, a short note it wrote before going back to a step, with words after that
    /// step, joins its line (App/Chat/ProgressNotes.swift). Empty while the turn works.
    public static HashSet<int> ProgressNotes(ChatMessage m, bool working)
    {
        var o = new HashSet<int>();
        if (m.IsStreaming || m.Error != null || working) return o;
        var pending = new List<int>();
        var stepped = new List<int>();
        for (var i = 0; i < m.Parts.Count; i++)
        {
            switch (m.Parts[i])
            {
                case TextPart t:
                    if (t.Text.Trim().Length == 0) continue;
                    o.UnionWith(stepped);
                    stepped = [];
                    if (IsNote(t.Text)) pending.Add(i); else pending = [];
                    break;
                case ToolPart { Call: var call }:
                    if (RunSummary.Hidden(call)) continue;
                    if (OwnRows.Contains(call.Name)) { pending = []; stepped = []; continue; }
                    stepped.AddRange(pending);
                    pending = [];
                    break;
            }
        }
        return o;
    }

    /// Words that read as a note on progress: short (≤ 600), no picture or file in them.
    public static bool IsNote(string text)
    {
        var t = text.Trim();
        if (t.Length == 0 || t.Length > 600) return false;
        return !t.Contains("MEDIA:") && !t.Contains("![");
    }

    /// One Line: the reply's line. While it works, its latest step ("Running a command", "Thinking"); once it has
    /// moved on to writing or is done, "Worked for 42s · 5 steps" when the time is known, else what it did.
    private static StepsRow OneLineRow(ChatMessage m, List<ToolCall> steps, List<string> thoughts, int? firstThought,
        int lastVisible, ReplyContext c)
    {
        var latest = lastVisible >= 0 && lastVisible < m.Parts.Count ? m.Parts[lastVisible] : null;
        var working = (m.IsStreaming || c.ExternalTail) && latest != null && latest is not TextPart;
        string title;
        StepGlyph glyph;
        string? meta = null, shortTitle = null;
        if (working && latest is ReasoningPart) { title = "Thinking"; glyph = StepGlyph.Thinking; }
        else if (working && steps.Count > 0)
        {
            title = RunSummary.Summarize([steps[^1]], true);
            glyph = RunSummary.GlyphFor(title);
            if (steps.Count > 1) meta = $"{steps.Count} steps";
        }
        else if (steps.Count == 0)
        {
            title = StepWords.ThoughtTitle(firstThought is { } f ? Seconds(c, f) : null, false);
            glyph = StepGlyph.Thinking;
        }
        else
        {
            var timed = steps.All(s => s.DurationSeconds != null);
            var seconds = c.TurnSeconds ?? (timed ? steps.Sum(s => s.DurationSeconds ?? 0) : null);
            if (seconds is { } secs)
            {
                var whole = (int)Math.Round(secs, MidpointRounding.AwayFromZero);
                title = whole < 1 ? "Worked briefly" : $"Worked for {StepWords.FormatElapsed(whole)}";
                if (steps.Count > 1) title += $" · {steps.Count} steps";
            }
            else
            {
                title = RunSummary.Summarize(steps, false);
                // The summary can be cut short on its one line; the count sits apart, where it never is.
                if (steps.Count > 1) { meta = $"{steps.Count} steps"; shortTitle = $"{steps.Count} steps"; }
            }
            glyph = StepGlyph.Worked;
        }
        var thought = thoughts.Count == 0 ? null : string.Join("\n\n", thoughts);
        return new StepsRow("line", steps, title, glyph, working, meta, shortTitle, thought, IsLine: true);
    }
}

/// Day lines and times (ChatRowBuilder.needsDayBreak / dayLabel): "Today 11:13 AM", "Yesterday 9:14 AM", "Sep 26 9:14 AM"
/// (the year added when it isn't this one).
public static class DayLines
{
    public const double DayGapSeconds = 30 * 60;

    public static bool NeedsBreak(DateTimeOffset? previous, DateTimeOffset current, bool datesOnly)
    {
        if (previous is not { } p) return true;
        var a = p.ToLocalTime().Date;
        var b = current.ToLocalTime().Date;
        if (datesOnly) return a != b;
        return (current - p).TotalSeconds >= DayGapSeconds || a != b;
    }

    public static string DayName(DateTimeOffset current, DateTimeOffset now)
    {
        var d = current.ToLocalTime().Date;
        var n = now.ToLocalTime().Date;
        if (d == n) return "Today";
        if (d == n.AddDays(-1)) return "Yesterday";
        var us = System.Globalization.CultureInfo.CurrentCulture;
        return d.Year == n.Year ? d.ToString("MMM d", us) : d.ToString("MMM d, yyyy", us);
    }

    public static string Clock(DateTimeOffset t) => t.ToLocalTime().ToString("t");

    public static string Label(DateTimeOffset current, DateTimeOffset now) => $"{DayName(current, now)} {Clock(current)}";
}
