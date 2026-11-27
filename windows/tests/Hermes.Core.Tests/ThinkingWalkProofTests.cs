// [WIN-THINKING-WALK] The chat-thinking walk's pure checks (Hermes.Core/Shell/ThinkingWalkProof.cs): the Mac's words the
// chat's thinking row must read while a turn holds on a step (93f984bb1 UITests/activity/ActivityEndToEndTests.swift
// test19b_WaitingRowNamesTheBot, test19d_ThinkingRowNamesTheRunningStep, test19e_AtTheBottomNamesEachStepBelow), the
// settings stand-in's controls it uses (/__settings/hold, /__settings/release) and the checks on the real row's UI
// Automation name and drawn words, the inspector's Steps tab its click opens, and the row's end. Synthetic only.

using System.Text.Json.Nodes;
using Proof = Hermes.Core.Shell.ThinkingWalkProof;

namespace Hermes.Core.Tests;

public sealed class ThinkingWalkProofTests
{
    [Fact]
    public void TheWalkIsNamedAndShootsTheStepAndTheOpenSteps()
    {
        Assert.Equal("chat-thinking", Proof.Walk);
        Assert.Equal("chat-thinking", Proof.Tag);
        Assert.Equal(["thinking-step", "thinking-steps-open"], Proof.Shots);
        Assert.Equal(Proof.Walk, Proof.FinalShot);
        Assert.Equal(9841, Proof.Port);
    }

    [Fact]
    public void TheRowReadsTheMacsWordsForTheHeldStep()
    {
        // test19d: "<Bot> is running npm test…" for a terminal's `cd … && npm test`.
        Assert.Equal("Ivy is running npm test…", Proof.Label);
        Assert.Null(Proof.Words());
        // The inspector's Steps row for a running terminal step (StepSheets.swift: "Running a command"), its command
        // drawn under it.
        Assert.Equal("Running a command", Proof.StepRowWords());
        Assert.Equal("cd /Users/me/app && npm test", Proof.StepCode());
        Assert.Equal("1 step", Proof.StepCount);
        Assert.Equal("Steps", Proof.StepsTab);
        Assert.Equal(["Info", "Steps", "Files", "Helpers"], Proof.Tabs);
        Assert.Equal("Hi! I'm Ivy.", Proof.Reply);
    }

    [Fact]
    public void TheHoldAsksForOneTerminalStep()
    {
        var hold = JsonNode.Parse(Proof.HoldBody())!.AsObject();
        Assert.Equal(["steps"], hold.Select(kv => kv.Key));
        var step = Assert.Single(hold["steps"]!.AsArray())!;
        Assert.Equal("terminal", step["name"]!.GetValue<string>());
        Assert.Equal("cd /Users/me/app && npm test", step["args"]!["command"]!.GetValue<string>());
        Assert.Equal("{}", Proof.ReleaseBody());
        Assert.Equal("/__settings/hold", Proof.HoldPath);
        Assert.Equal("/__settings/release", Proof.ReleasePath);
        Assert.Equal("/__settings/state", Proof.StatePath);
    }

    [Fact]
    public void TheStandInHoldsTheTurnAndTookThePromptOnce()
    {
        const string chat = "20260929_120000_aabbcc02";
        JsonNode State(int held, params (string Session, string Text)[] prompts) => new JsonObject
        {
            ["held"] = held,
            ["prompts"] = new JsonArray([.. prompts.Select(p => (JsonNode)new JsonObject { ["profile"] = "ivy", ["session"] = p.Session, ["text"] = p.Text })]),
        };
        Assert.Null(Proof.Held(State(1), 1));
        Assert.Contains("0", Proof.Held(State(0), 1));
        Assert.Contains("held", Proof.Held(new JsonObject(), 1));
        Assert.Null(Proof.Prompt(State(1, (chat, Proof.Text)), chat));
        Assert.Contains("no prompt", Proof.Prompt(State(1), chat));
        Assert.Contains("2 times", Proof.Prompt(State(1, (chat, Proof.Text), (chat, Proof.Text)), chat));
        Assert.Contains("went to", Proof.Prompt(State(1, ("other", Proof.Text)), chat));
    }

    [Fact]
    public void TheRowNamesTheStepAndNoCounterForItsFirstTenSeconds()
    {
        // test19b/19d: the row names the bot and the step, not the model; no "·" counter for the first 10 s.
        Assert.Null(Proof.Row("Ivy is running npm test…", ["Ivy is running npm test…"], 2));
        Assert.Contains("no thinking row", Proof.Row(null, [], 2));
        Assert.Contains("no thinking row", Proof.Row("", [], 2));
        Assert.Contains("reads", Proof.Row("Ivy is thinking…", ["Ivy is thinking…"], 2));
        Assert.Contains("model", Proof.Row("Waiting for fixture-1… Ivy is running npm test…", ["Ivy is running npm test…"], 2));
        Assert.Contains("counter", Proof.Row("Ivy is running npm test… · 0:03", ["Ivy is running npm test…", "· 0:03"], 3));
        Assert.Contains("drawn", Proof.Row("Ivy is running npm test…", ["Ivy is thinking…"], 2));
        // Past 10 s (a slow walk) the counter is the Mac's rule, not a fault.
        Assert.Null(Proof.Row("Ivy is running npm test… · 0:11", ["Ivy is running npm test…", "· 0:11"], 11));
    }

    [Fact]
    public void FromTenSecondsTheTimerReadsAndIsDrawnWhole()
    {
        // test19b: "· 0:1" after 10 s; test19e: the timer whole beside the words.
        Assert.Null(Proof.Timer("Ivy is running npm test… · 0:10", ["Ivy is running npm test…", "· 0:10"]));
        Assert.Null(Proof.Timer("Ivy is running npm test… · 0:17", ["Ivy is running npm test…", "· 0:17"]));
        Assert.Contains("timer", Proof.Timer("Ivy is running npm test…", ["Ivy is running npm test…", ""]));
        Assert.Contains("timer", Proof.Timer("Ivy is running npm test… · 0:09", ["Ivy is running npm test…", "· 0:09"]));
        Assert.Contains("drawn", Proof.Timer("Ivy is running npm test… · 0:12", ["Ivy is running npm test…"]));
        // Past a minute with a step running the words stay the step's (not "still working").
        Assert.Contains("reads", Proof.Timer("Ivy is still working… · 0:12", ["Ivy is still working…", "· 0:12"]));
        Assert.Contains("no thinking row", Proof.Timer(null, []));
    }

    [Fact]
    public void WhileItWorksTheStepIsNamedOnlyByTheRow()
    {
        // test19e (At the Bottom): no line above the reply while it works; the row alone names the step.
        Assert.Null(Proof.OnlyTheRow(["Run the tests", "Hi! I'm Ivy."]));
        Assert.Contains("npm test", Proof.OnlyTheRow(["Running npm test…"]));
        Assert.Contains("Working", Proof.OnlyTheRow(["Working… 1 step"]));
        Assert.Contains("Using", Proof.OnlyTheRow(["Using terminal"]));
        Assert.Contains("Worked", Proof.OnlyTheRow(["Worked for 3s"]));
    }

    [Fact]
    public void TheClickOpensTheInspectorOnStepsWithTheHeldStep()
    {
        var tabs = new[] { ("Info", false), ("Steps", true), ("Files", false), ("Helpers", false) };
        var step = Proof.StepRowWords();
        Assert.Null(Proof.StepsOpen(true, tabs, ["1 step", step, Proof.StepCode()], [step]));
        Assert.Contains("command", Proof.StepsOpen(true, tabs, ["1 step", step], [step]));
        Assert.Contains("closed", Proof.StepsOpen(false, tabs, ["1 step"], [step]));
        Assert.Contains("Info", Proof.StepsOpen(true, [("Info", true), ("Steps", false), ("Files", false), ("Helpers", false)], ["1 step"], [step]));
        Assert.Contains("tabs", Proof.StepsOpen(true, [("Steps", true)], ["1 step"], [step]));
        Assert.Contains("1 step", Proof.StepsOpen(true, tabs, ["No Steps"], []));
        Assert.Contains("step row", Proof.StepsOpen(true, tabs, ["1 step", Proof.StepCode()], ["Read package.json"]));
    }

    [Fact]
    public void AfterTheReplyStepsKeepsTheFinishedStep()
    {
        // [WIN-STEPS-AFTER-REPLY] Once the turn-end read lands: the stored turn's step, finished, with its command.
        Assert.Equal("Ran a command", Proof.StepDoneWords());
        var tabs = new[] { ("Info", false), ("Steps", true), ("Files", false), ("Helpers", false) };
        var done = Proof.StepDoneWords();
        Assert.Null(Proof.StepsKept(tabs, ["1 step", done, Proof.StepCode()!], [done]));
        // Run 45171524778's 230-chat-thinking: the panel's empty words after the reply.
        Assert.Contains("lost", Proof.StepsKept(tabs, [Hermes.Core.Transcripts.LatestSteps.EmptyTitle, Hermes.Core.Transcripts.LatestSteps.EmptyHint], []));
        Assert.Contains("finished step row", Proof.StepsKept(tabs, ["1 step", Proof.StepCode()!], [Proof.StepRowWords()]));
        Assert.Contains("command", Proof.StepsKept(tabs, ["1 step", done], [done]));
        Assert.Contains("Info", Proof.StepsKept([("Info", true), ("Steps", false), ("Files", false), ("Helpers", false)], ["1 step", done], [done]));
    }

    [Fact]
    public void TheTurnEndReadIsCountedFromTheStandInsRecord()
    {
        var state = JsonNode.Parse("""
            {"rest":[{"method":"GET","path":"/api/sessions/chat-ivy/messages?limit=50&order=latest"},
                     {"method":"GET","path":"/api/sessions/chat-ivy"},
                     {"method":"GET","path":"/api/sessions/chat-other/messages"},
                     {"method":"POST","path":"/api/sessions/chat-ivy/messages"},
                     {"method":"GET","path":"/api/sessions/chat-ivy/messages"}]}
            """)!;
        Assert.Equal(2, Proof.Reads(state, "chat-ivy"));
        Assert.Equal(0, Proof.Reads(JsonNode.Parse("{}")!, "chat-ivy"));
    }

    [Fact]
    public void BeforeTheClickTheInspectorIsClosed()
    {
        Assert.Null(Proof.Closed(false));
        Assert.Contains("open", Proof.Closed(true));
    }

    [Fact]
    public void OnceTheReplyWritesTheRowGoes()
    {
        Assert.Null(Proof.Gone(false, null, "Hi! I'm Ivy."));
        Assert.Contains("still", Proof.Gone(true, "Ivy is running npm test… · 0:14", "Hi! I'm Ivy."));
        Assert.Contains("reply", Proof.Gone(false, null, "Run the tests"));
        Assert.Contains("reply", Proof.Gone(false, null, null));
    }

    // ------------------------------------------------------------------ wiring

    private static string WindowsDir()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "windows", "HermesHQ.sln")))
                return Path.Combine(dir.FullName, "windows");
        throw new InvalidOperationException("repo root not found");
    }

    private static string Read(params string[] parts) => File.ReadAllText(Path.Combine([WindowsDir(), .. parts])).Replace("\r\n", "\n");

    [Fact]
    public void WindowsYmlAsksForTheWalkAndItsPicturesOnItsOwnSettingsStandIn()
    {
        var yml = Read("ci", "windows.yml");
        var entry = Assert.Single(System.Text.RegularExpressions.Regex.Matches(yml,
            @"@\{ tag = ""(?<tag>[^""]+)""; args = @\((?<args>[^)]*)\);(?<rest>[^\n]*)\}"), m => m.Groups["tag"].Value == Proof.Tag);
        Assert.Contains($"\"windows/ci/fixtures/settings-gateway.py\",\"--port\",\"{Proof.Port}\"", entry.Groups["args"].Value);
        Assert.Contains($"walks = @(\"{Proof.Walk}\")", entry.Groups["rest"].Value);
        Assert.Contains("shots = @(\"thinking-step\",\"thinking-steps-open\")", entry.Groups["rest"].Value);
        // The toasts extra stays last (WIN-61: a later sign-in clears the toasts).
        Assert.True(yml.IndexOf("tag = \"chat-thinking\"", StringComparison.Ordinal) < yml.IndexOf("tag = \"toasts\"", StringComparison.Ordinal));
        // Its port is its own: nothing else in windows.yml or e2e.sh uses it.
        Assert.Single(System.Text.RegularExpressions.Regex.Matches(yml, $@"\b{Proof.Port}\b"));
        Assert.DoesNotMatch($@"\b{Proof.Port}\b", Read("scripts", "e2e.sh"));
    }

    [Fact]
    public void TheStandInHasTheHoldAndTheRelease()
    {
        var gateway = Read("ci", "fixtures", "settings-gateway.py");
        Assert.Contains($"if path == '{Proof.HoldPath}':", gateway);
        Assert.Contains($"if path == '{Proof.ReleasePath}':", gateway);
        Assert.Contains("'held': len(HELD)", gateway);
        // The reply the held turn writes once released.
        Assert.Contains("text = f\"Hi! I'm {shown}.\"", gateway);
        Assert.Contains("'ivy': {'display_name': 'Ivy'", gateway);
    }

    [Fact]
    public void TheInspectorsTabKeyAndTitlesAreTheAppsOwn()
    {
        var inspector = Read("src", "HermesHQ.Windows", "Features", "Transcript", "ChatInspector.cs");
        Assert.Contains($"private const string TabKey = \"{Proof.InspectorTabKey}\";", inspector);
        Assert.Contains("private static readonly string[] Titles = [\"Info\", \"Steps\", \"Files\", \"Helpers\"];", inspector);
        Assert.Contains("Text = steps.Count == 1 ? \"1 step\"", inspector);
    }

    [Fact]
    public void TheAppRegistersTheWalkAndTakesEveryPicture()
    {
        Assert.Contains("        RegisterThinkingWalks();", Read("src", "HermesHQ.Windows", "Services", "ProofWalks.cs"));
        var walk = Read("src", "HermesHQ.Windows", "Services", "ProofWalks.Thinking.cs");
        // Literal names: WalkProofTests reads windows.yml's walks against the source as written.
        Assert.Contains("Automation.NamedWalks[\"chat-thinking\"] = ThinkingAsync;", walk);
        foreach (var name in Proof.Shots) Assert.Contains($"await shot(\"{name}\");", walk);
        Assert.Contains("await shot(\"chat-thinking\");", walk);
        // The row is read as drawn: its UI Automation name and words, found by the Mac's identifier, and clicked
        // through its automation peer (no OS input).
        Assert.Contains("ThinkingRow.AutomationId", walk);
        Assert.Contains("AutomationProperties.GetName(", walk);
        Assert.Contains("Invoke(row)", walk);
        Assert.DoesNotContain("Keys.", walk);
        Assert.DoesNotContain("Mouse.", walk);
        // At the Bottom, the default the Mac's test19e names.
        Assert.Contains("ChatDisplaySettings.Style = ToolCallStyle.Bottom;", walk);
        // The timer is waited for (>= 10 s deadlines).
        Assert.Contains("ThinkingWalkProof.Timer(", walk);
        // The stand-in's held turn is let go whatever happens.
        Assert.Matches(new System.Text.RegularExpressions.Regex(@"finally\n\s+\{\n\s+// Nothing left held"), walk);
    }
}
