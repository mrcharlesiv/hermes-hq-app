// [toolnow] The chat's thinking row: the typing dots and "<Bot> is thinking…" at the transcript's newest end while a
// turn runs, naming the step that runs ("Ivy is running npm test…"). App/Chat/ChatRow.swift at 93f984bb1:
// `ToolNowRows` (which part of a running reply the row speaks for), `ChatRowBuilder.waitingRow` (its words) and the
// rule in `rows(…)` that draws it; ActivityRows.swift `suppressesWaiting`; ChatCells.swift `ChatWaitingCell.words`,
// `line` and `elapsed` (what it says as time passes). [WIN-THINKING-STEP] The words are Hermes.Core.Activity.ToolNow's.

using Hermes.Core.Activity;
using Hermes.Core.Groups;
using Hermes.Core.Model;

namespace Hermes.Core.Transcripts;

/// [toolnow] Which part of a running reply the thinking row speaks for.
public static class ToolNowRows
{
    /// The reply's newest drawn part is a step or a thought (it isn't writing): the thinking row stays under it.
    public static bool Working(ChatMessage m)
    {
        if (m.Role != Role.Assistant) return false;
        for (var i = m.Parts.Count - 1; i >= 0; i--)
        {
            switch (m.Parts[i])
            {
                case TextPart t: if (t.Text.Trim().Length > 0) return false; break;
                case ReasoningPart r: if (r.Text.Trim().Length > 0) return true; break;
                case ToolPart tp: if (!(RunSummary.IsSilent(tp.Call.Name) && tp.Call.State != ToolState.Failed)) return true; break;
            }
        }
        return false;
    }

    /// The step the row names: the reply's newest step, running or just finished, until the reply writes. A finished
    /// one stays through the thinking after it (owner, 2026-10-27: the row never showed a step; 60% of steps ended in
    /// under a second and the thinking between them took ~4 s, so it said "is thinking…" nearly always).
    public static ToolCall? Latest(ChatMessage? m)
    {
        if (m == null || m.Role != Role.Assistant || !Working(m)) return null;
        for (var i = m.Parts.Count - 1; i >= 0; i--)
        {
            switch (m.Parts[i])
            {
                case ToolPart tp when !RunSummary.IsSilent(tp.Call.Name): return tp.Call;
                case TextPart t when t.Text.Trim().Length > 0: return null;
            }
        }
        return null;
    }
}

/// The thinking row (ChatRow.swift `WaitingRow`). `Label`: "Ivy is thinking…" or the step ("Ivy is reading
/// package.json…"). `LongLabel`: what it says after 60 s with no step running ("Ivy is still working…" once the turn
/// ran steps, else "Ivy is still thinking…"). `Doing`: a step runs now (its words stay past 60 s). `OpensSteps`: the turn
/// has steps, so clicking it shows them. `Turn`: the prompt it answers (its timer starts when first seen).
public sealed record WaitingRow(string Label, string? LongLabel, bool Doing, bool OpensSteps, string Turn);

public static class ThinkingRow
{
    /// The row's automation id (ChatWaitingCell `accessibilityIdentifier`).
    public const string AutomationId = "chat.waiting";
    /// [mac] The pointer's word for the click (ChatWaitingCell `stepsTip`) and VoiceOver's hint.
    public const string StepsTip = "Show Steps";
    public const string StepsHint = "Shows every step";

    /// What decides the row: the chat's messages, whether a turn runs (ours or another process's), the bot's name.
    public sealed record Input(IReadOnlyList<ChatMessage> Messages, bool IsRunning, string BotName)
    {
        public ToolCallStyle Style { get; init; } = ToolCallStyle.Bottom;
        /// [questions] An open approval or question: the header says "Waiting for your reply" instead.
        public bool WaitsOnUser { get; init; }
        /// The roster a message to another bot names it by (`BotDMs.sender`).
        public IReadOnlyList<DeliveryMessages.Seat> Roster { get; init; } = [];
        /// The reply's layout inputs (whether its newest message draws anything yet); null: this style's defaults.
        public ReplyContext? Context { get; init; }
    }

    /// The row at the newest end, or null when it isn't drawn: the turn runs, it doesn't wait on you, and the last
    /// message is your prompt or a reply that shows nothing yet or is still working (a step runs, or it thinks between
    /// steps); not under a reply In Header keeps steps out of (§10.4).
    public static WaitingRow? Build(Input input)
    {
        var messages = input.Messages;
        if (!input.IsRunning || input.WaitsOnUser || messages.Count == 0) return null;
        var last = messages[^1];
        if (last.Role == Role.User) return Row(input);
        if (last.Role != Role.Assistant) return null;
        var context = input.Context ?? new ReplyContext
        {
            Style = input.Style, Working = true, RunningTail = true, BotName = input.BotName,
        };
        var visible = ReplyLayout.Build(last, context).Count > 0;
        if ((!visible || ToolNowRows.Working(last)) && !SuppressesWaiting(last, input.Style)) return Row(input);
        return null;
    }

    /// No row under a reply that has started In Header: the status line under the name says what runs (§10.4).
    /// (The Mac's `display.tool_progress` off case is not read on Windows.)
    public static bool SuppressesWaiting(ChatMessage last, ToolCallStyle style) =>
        last.Role == Role.Assistant && last.Parts.Count > 0 && style == ToolCallStyle.Header;

    private static WaitingRow Row(Input input)
    {
        var messages = input.Messages;
        var turn = messages.LastOrDefault(m => m.Role == Role.User)?.Id ?? messages.FirstOrDefault()?.Id ?? "pending";
        var call = ToolNowRows.Latest(messages[^1]);
        string? step = null;
        if (call != null)
        {
            // A message to another bot names it as the roster does ("messaging Ivy", not its handle).
            step = call.Name == ToolNow.MessageAgent && input.Roster.Count > 0 && ToolArgs.Str(ToolArgs.Of(call), "target") is { } target
                ? "messaging " + ToolNow.Short(LiveSteps.SenderName(target, input.Roster))
                : ToolNow.Phrase(call);
        }
        var label = $"{input.BotName} is {step ?? "thinking"}…";
        var lastUser = -1;
        for (var i = messages.Count - 1; i >= 0; i--) if (messages[i].Role == Role.User) { lastUser = i; break; }
        var opens = false;
        for (var i = lastUser + 1; i < messages.Count && !opens; i++)
            opens = messages[i].Role == Role.Assistant && messages[i].Parts.Any(p => p is ToolPart tp && !RunSummary.IsSilent(tp.Call.Name));
        return new WaitingRow(label, $"{input.BotName} is still {(call == null ? "thinking" : "working")}…",
            Doing: call?.State == ToolState.Running, OpensSteps: opens, Turn: turn);
    }

    /// What the row reads and its name says (`turnStatusCopy`): the words, then the timer from 10 s.
    public static string Words(string label, string? longLabel = null, double elapsed = 0, bool doing = false)
    {
        var seconds = Math.Max(0, (int)elapsed);
        var text = Line(label, longLabel, seconds, doing);
        return seconds >= 10 ? text + " " + Elapsed(seconds) : text;
    }

    /// The words before the timer: `longLabel` takes over at 60 s unless a step is running.
    public static string Line(string label, string? longLabel, int seconds, bool doing) =>
        seconds >= 60 && !doing ? longLabel ?? label : label;

    /// The timer beside the words: nothing for the first 10 s, then "· 0:12".
    public static string Elapsed(int seconds) => seconds < 10 ? "" : $"· {seconds / 60}:{seconds % 60:00}";
}
