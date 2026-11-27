// [WIN-THINKING-WALK] What the chat-thinking walk (HermesHQ.Windows/Services/ProofWalks.Thinking.cs) asks the stand-in
// for and checks on the real chat, against windows/ci/fixtures/settings-gateway.py (a turn held on one step with
// /__settings/hold until /__settings/release). The intent is the Mac's UI tests at 93f984bb1
// UITests/activity/ActivityEndToEndTests.swift:
//   test19b_WaitingRowNamesTheBot            the row names the bot, not the model; no "·" counter for the first 10 s,
//                                            then "· 0:1…"; it goes once the reply writes.
//   test19d_ThinkingRowNamesTheRunningStep   while a step runs it reads "<Bot> is running npm test…"; gone once the reply
//                                            writes.
//   test19e_AtTheBottomNamesEachStepBelow    At the Bottom nothing is drawn above the reply while it works, the timer
//                                            sits whole beside the words, and a click opens every step of the turn (the
//                                            Mac's Steps sheet; on Windows the inspector's Steps tab, as the Mac's
//                                            MacInspector does on the desktop).
// The words are Hermes.Core's ThinkingRow (the Mac's ChatRow `waitingRow`, ChatWaitingCell `turnStatusCopy`). Each check
// answers null when right, else what is wrong.

using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Shell;

public static class ThinkingWalkProof
{
    public const string Walk = "chat-thinking";
    /// The stand-in's tag in windows.yml's screenshot extras.
    public const string Tag = "chat-thinking";
    /// Its own settings stand-in's port (no other extra or e2e.sh stand-in uses it).
    public const int Port = 9841;

    public const string Bot = "ivy";
    public const string BotName = "Ivy";

    public const string StatePath = "/__settings/state";
    public const string HoldPath = "/__settings/hold";
    public const string ReleasePath = "/__settings/release";

    public const string StepShot = "thinking-step";
    public const string StepsShot = "thinking-steps-open";
    /// The walk's own picture (windows.yml wants one per walk name): the reply written, the row gone.
    public const string FinalShot = Walk;
    public static readonly IReadOnlyList<string> Shots = [StepShot, StepsShot];

    // ------------------------------------------------------------------ the Mac's words

    /// test19d: the row while the terminal's `npm test` runs.
    public const string Label = "Ivy is running npm test…";
    /// The timer shows from 10 s (ChatWaitingCell `elapsed`).
    public const int TimerFrom = 10;
    /// The inspector (MacInspector.swift): its tabs, the one a click opens, and its count line.
    public static readonly IReadOnlyList<string> Tabs = ["Info", "Steps", "Files", "Helpers"];
    public const string StepsTab = "Steps";
    public const string StepCount = "1 step";
    /// ChatInspector's kept tab (the walk sets Info first, so the click is what opens Steps).
    public const string InspectorTabKey = "HQMacInspectorTab";
    /// What the stand-in's held turn writes once released (settings-gateway.py `stream_intro`).
    public const string Reply = "Hi! I'm Ivy.";

    // ------------------------------------------------------------------ what is sent (synthetic)

    public const string Text = "Synthetic test run, please";

    public static JsonObject Step() => new() { ["name"] = "terminal", ["args"] = new JsonObject { ["command"] = "cd /Users/me/app && npm test" } };

    public static string HoldBody() => new JsonObject { ["steps"] = new JsonArray(Step()) }.ToJsonString();
    public static string ReleaseBody() => "{}";

    /// The call as the chat holds it from the stand-in's `tool.start` (Transcript.ToolStart).
    public static ToolCall StepCall()
    {
        var args = Step()["args"];
        return new ToolCall("call_hold_1", "terminal", HistoryFold.ArgsText(args), null, ToolState.Running, ArgsJson: HistoryFold.ArgsJson(args));
    }

    /// The inspector's step row's name for the held step (MessageView.StepRow: StepWords).
    public static string StepRowWords() => StepWords.Words(StepCall());

    /// [WIN-STEPS-AFTER-REPLY] The rows the stand-in stores for the held turn once released, as Hermes stores a turn's
    /// steps (settings-gateway.py `hold_on_step`): the assistant row calling the step, its tool row, then the words.
    public static JsonArray StoredTurn(long userRow) => new(
        new JsonObject { ["role"] = "user", ["content"] = Text, ["row_id"] = userRow },
        new JsonObject
        {
            ["role"] = "assistant", ["content"] = "", ["row_id"] = userRow + 1,
            ["tool_calls"] = new JsonArray(new JsonObject
            {
                ["id"] = "call_hold_1", ["type"] = "function",
                ["function"] = new JsonObject { ["name"] = "terminal", ["arguments"] = Step()["args"]!.ToJsonString() },
            }),
        },
        new JsonObject { ["role"] = "tool", ["tool_call_id"] = "call_hold_1", ["content"] = "ok", ["row_id"] = userRow + 2 },
        new JsonObject { ["role"] = "assistant", ["content"] = Reply, ["row_id"] = userRow + 3 });

    /// The held step as the turn-end read brings it back: finished, from the stored rows (HistoryFold).
    public static ToolCall? StoredStep() =>
        LatestSteps.Of(HistoryFold.Fold(StoredTurn(1))) is [var only] ? only.Call : null;

    /// The inspector's step row's name for the finished step ("Ran a command").
    public static string StepDoneWords() => StoredStep() is { } c ? StepWords.Words(c) : "";

    /// GET /__settings/state's `rest`: how many times the chat's stored messages were read (the turn-end read is one).
    public static int Reads(JsonNode state, string chatId) =>
        (state["rest"]?.AsArray().OfType<JsonObject>() ?? []).Count(r => r["method"]?.GetValue<string>() == "GET"
            && (r["path"]?.GetValue<string>() ?? "").Split('?')[0] == $"/api/sessions/{chatId}/messages");

    /// The command the step row draws under its words (StepWords.CodePreview of the step's code).
    public static string? StepCode() => ToolLines.Line(StepCall()).Code;

    /// The Mac's words written here agree with what Hermes.Core's ThinkingRow makes of the stand-in's turn.
    public static string? Words()
    {
        var at = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000);
        var you = new ChatMessage("u", Role.User, [new TextPart(Text)], at, RowId: 1);
        var reply = new ChatMessage("a", Role.Assistant, [new ToolPart(StepCall())], at.AddSeconds(1), RowId: 2, IsStreaming: true);
        var row = ThinkingRow.Build(new ThinkingRow.Input([you, reply], true, BotName));
        if (row == null) return "words: no thinking row for the held step";
        if (row.Label != Label) return $"words: the row reads \"{row.Label}\", not \"{Label}\"";
        if (!row.OpensSteps) return "words: the row doesn't open the turn's steps";
        return null;
    }

    // ------------------------------------------------------------------ the stand-in's record

    /// GET /__settings/state's `held`: the turns holding on their step now.
    public static string? Held(JsonNode state, int count) => RowStepsWalkProof.Held(state, count);

    /// The stand-in took the walk's prompt once, in Ivy's Bot Chat.
    public static string? Prompt(JsonNode state, string chatId)
    {
        var sent = (state["prompts"]?.AsArray().OfType<JsonObject>() ?? []).Where(p => p["text"]?.GetValue<string>() == Text).ToList();
        if (sent.Count == 0) return $"stand-in: no prompt \"{Text}\"";
        if (sent.Count > 1) return $"stand-in: \"{Text}\" sent {sent.Count} times";
        var to = sent[0]["session"]?.GetValue<string>();
        return to == chatId ? null : $"stand-in: \"{Text}\" went to {to}, not Ivy's chat ({chatId})";
    }

    // ------------------------------------------------------------------ the row as drawn

    /// The row once the step runs (test19b/19d): its automation name is the Mac's words, not the model's, and the
    /// words are drawn; under 10 s since the send (`seconds`) there is no "·" counter.
    public static string? Row(string? name, IReadOnlyList<string> texts, double seconds)
    {
        if (string.IsNullOrEmpty(name)) return "no thinking row";
        if (name.Contains("Waiting for", StringComparison.Ordinal)) return $"the row names the model: \"{name}\"";
        if (!name.StartsWith(Label, StringComparison.Ordinal)) return $"the row reads \"{name}\", not \"{Label}\"";
        if (seconds < TimerFrom && name != Label) return $"a counter before 10 s: \"{name}\"";
        if (seconds >= TimerFrom && name != Label && !Regex.IsMatch(name[Label.Length..], @"^ · \d+:\d\d$"))
            return $"the row reads \"{name}\"";
        if (!texts.Contains(Label)) return $"\"{Label}\" isn't drawn on the row (it draws {Quoted(texts)})";
        return null;
    }

    /// From 10 s (test19b "· 0:1", test19e "the timer"): the name ends with the timer, and the timer is drawn whole.
    public static string? Timer(string? name, IReadOnlyList<string> texts)
    {
        if (string.IsNullOrEmpty(name)) return "no thinking row";
        if (!name.StartsWith(Label, StringComparison.Ordinal)) return $"the row reads \"{name}\", not \"{Label}\"";
        var m = Regex.Match(name[Label.Length..], @"^ (?<timer>· (?<m>\d+):(?<s>\d\d))$");
        if (!m.Success) return $"no timer on the row: \"{name}\"";
        var seconds = int.Parse(m.Groups["m"].Value) * 60 + int.Parse(m.Groups["s"].Value);
        if (seconds < TimerFrom) return $"a timer before 10 s: \"{name}\"";
        var timer = m.Groups["timer"].Value;
        if (!texts.Contains(timer)) return $"the timer \"{timer}\" isn't drawn whole (the row draws {Quoted(texts)})";
        if (!texts.Contains(Label)) return $"\"{Label}\" isn't drawn on the row (it draws {Quoted(texts)})";
        return null;
    }

    /// test19e (At the Bottom): while the bot works the transcript's messages draw no steps line and don't name the
    /// step; the thinking row alone does.
    public static string? OnlyTheRow(IReadOnlyList<string> transcriptTexts)
    {
        foreach (var t in transcriptTexts)
        {
            if (t.Contains("npm test", StringComparison.OrdinalIgnoreCase)) return $"the transcript names the step too: \"{t}\"";
            if (t.StartsWith("Working", StringComparison.Ordinal) || t.StartsWith("Worked", StringComparison.Ordinal)
                || t.StartsWith("Using", StringComparison.Ordinal))
                return $"a steps line above the reply while it works: \"{t}\"";
        }
        return null;
    }

    /// Before the click the inspector is closed, so the click is what opens it.
    public static string? Closed(bool inspectorShown) => inspectorShown ? "the inspector is open before the click" : null;

    /// After the click (test19e "the Steps sheet opens"): the inspector shows, its Steps tab (only) is picked, it counts
    /// the turn's one step and lists the held step by name.
    public static string? StepsOpen(bool inspectorShown, IReadOnlyList<(string Title, bool Checked)> tabs,
        IReadOnlyList<string> texts, IReadOnlyList<string> buttonNames)
    {
        if (!inspectorShown) return "the inspector stayed closed";
        if (!tabs.Select(t => t.Title).SequenceEqual(Tabs)) return $"the inspector's tabs are {Quoted([.. tabs.Select(t => t.Title)])}";
        var picked = tabs.Where(t => t.Checked).Select(t => t.Title).ToList();
        if (picked.Count != 1 || picked[0] != StepsTab) return $"the inspector shows {Quoted(picked)}, not {StepsTab}";
        if (!texts.Contains(StepCount)) return $"Steps doesn't say \"{StepCount}\" (it draws {Quoted(texts)})";
        var step = StepRowWords();
        if (!buttonNames.Contains(step)) return $"no step row \"{step}\" (rows: {Quoted(buttonNames)})";
        if (StepCode() is { } code && !texts.Contains(code)) return $"the step's command \"{code}\" isn't drawn (Steps draws {Quoted(texts)})";
        return null;
    }

    /// [WIN-STEPS-AFTER-REPLY] After the reply writes and the turn-end read lands, Steps still shows the turn's step, now
    /// finished (the Mac's `turnSteps(endingAt: nil)` reads the stored turn): "1 step", the step's row "Ran a command" with
    /// its command, and not the panel's empty words.
    public static string? StepsKept(IReadOnlyList<(string Title, bool Checked)> tabs, IReadOnlyList<string> texts,
        IReadOnlyList<string> buttonNames)
    {
        var picked = tabs.Where(t => t.Checked).Select(t => t.Title).ToList();
        if (picked.Count != 1 || picked[0] != StepsTab) return $"the inspector shows {Quoted(picked)}, not {StepsTab}";
        if (texts.Contains(LatestSteps.EmptyTitle)) return $"Steps lost the finished reply's step: \"{LatestSteps.EmptyTitle}\"";
        if (!texts.Contains(StepCount)) return $"Steps doesn't say \"{StepCount}\" (it draws {Quoted(texts)})";
        var done = StepDoneWords();
        if (!buttonNames.Contains(done)) return $"no finished step row \"{done}\" (rows: {Quoted(buttonNames)})";
        if (StepCode() is { } code && !texts.Contains(code)) return $"the step's command \"{code}\" isn't drawn (Steps draws {Quoted(texts)})";
        return null;
    }

    /// Once released (test19b/19d/19e "gone once the reply writes"): the reply is drawn and the row isn't.
    public static string? Gone(bool rowShown, string? rowName, string? lastReply)
    {
        if (lastReply != Reply) return $"the reply isn't written (the last reply is \"{lastReply}\")";
        if (rowShown) return $"the row is still drawn: \"{rowName}\"";
        return null;
    }

    private static string Quoted(IReadOnlyList<string> texts) => texts.Count == 0 ? "nothing" : string.Join(", ", texts.Select(t => $"\"{t}\""));
}
