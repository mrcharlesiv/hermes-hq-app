// [WIN-ROWS-STEP-WALK] The row-steps walk's pure checks (Hermes.Core/Shell/RowStepsWalkProof.cs): the Mac's words the
// rows must read (93f984bb1 HermesKit/Activity/LiveSteps.swift + ToolNow.swift, App/Bots/BotListModel.swift "Waking up…"),
// the stand-in's controls (windows/ci/fixtures/settings-gateway.py /__settings/hold, /__settings/release, a slow
// session.resume for one bot) and the checks on the real rows' UI Automation names and drawn words. Synthetic only.

using System.Text.Json.Nodes;
using Proof = Hermes.Core.Shell.RowStepsWalkProof;

namespace Hermes.Core.Tests;

public sealed class RowStepsWalkProofTests
{
    [Fact]
    public void TheWalkIsNamedAndShootsItsThreeRows()
    {
        Assert.Equal("row-steps", Proof.Walk);
        Assert.Equal("row-steps", Proof.Tag);
        Assert.Equal(["row-step-bots", "row-step-sessions", "row-waking"], Proof.Shots);
        Assert.Equal(Proof.Walk, Proof.FinalShot);
    }

    [Fact]
    public void TheStepsReadAsTheMacsToolNowWords()
    {
        // The Mac's own words for these calls (ToolNowTests.swift: read_file → "reading package.json", a terminal's
        // `cd … && npm test` → "running npm test"), as a row's live line (LiveSteps.line).
        Assert.Equal("Reading package.json…", Proof.BotLine);
        Assert.Equal("Running npm test…", Proof.SideLine);
        Assert.Equal(Proof.BotLine, Proof.StepLine(Proof.BotStep()));
        Assert.Equal(Proof.SideLine, Proof.StepLine(Proof.SideStep()));
        Assert.Null(Proof.Lines());
        Assert.Equal("Waking up…", Proof.Waking);
        Assert.Equal("Working…", Proof.Working);
    }

    [Fact]
    public void TheHoldAsksForTheBotChatsStepThenTheSideChats()
    {
        var hold = JsonNode.Parse(Proof.HoldBody())!.AsObject();
        Assert.Equal(["steps"], hold.Select(kv => kv.Key));
        var steps = hold["steps"]!.AsArray();
        Assert.Equal(2, steps.Count);
        Assert.Equal("read_file", steps[0]!["name"]!.GetValue<string>());
        Assert.Equal("/Users/me/app/package.json", steps[0]!["args"]!["path"]!.GetValue<string>());
        Assert.Equal("terminal", steps[1]!["name"]!.GetValue<string>());
        Assert.Equal("cd /Users/me/app && npm test", steps[1]!["args"]!["command"]!.GetValue<string>());
        Assert.Equal("{}", Proof.ReleaseBody());
    }

    [Fact]
    public void TheSlowOpenIsOneResumeOfResearchsChatOverASecond()
    {
        var slow = JsonNode.Parse(Proof.SlowOpenBody())!;
        Assert.Equal("session.resume", slow["method"]!.GetValue<string>());
        Assert.Equal("slow", slow["mode"]!.GetValue<string>());
        Assert.Equal("research", slow["profile"]!.GetValue<string>());
        Assert.Equal(1, slow["count"]!.GetValue<int>());
        var seconds = slow["seconds"]!.GetValue<double>();
        Assert.True(seconds > 1 && seconds < 10, $"{seconds} s");   // past the Mac's 1 s grace, short of the walk's deadline
        Assert.Equal("Research", Proof.WakingName);
    }

    private static JsonNode State(int held, int slowLeft = 1, params (string Profile, string Session, string Text)[] prompts) => new JsonObject
    {
        ["held"] = held,
        ["prompts"] = new JsonArray([.. prompts.Select(p => (JsonNode)new JsonObject { ["profile"] = p.Profile, ["session"] = p.Session, ["text"] = p.Text })]),
        ["fail"] = new JsonArray(new JsonObject { ["method"] = "session.resume", ["mode"] = "slow", ["count"] = slowLeft, ["profile"] = "research" }),
    };

    [Fact]
    public void TheStandInHoldsBothTurnsAndTookBothPrompts()
    {
        const string bot = "20260929_120000_aabbcc02", side = "20260929_120000_aabbcc06";
        var both = State(2, 1, ("ivy", bot, Proof.BotText), ("ivy", side, Proof.SideText));
        Assert.Null(Proof.Held(both, 2));
        Assert.Contains("1", Proof.Held(State(1), 2));
        Assert.Contains("held", Proof.Held(new JsonObject(), 0));
        Assert.Null(Proof.Prompts(both, bot, side));
        Assert.Contains(Proof.SideText, Proof.Prompts(State(2, 1, ("ivy", bot, Proof.BotText)), bot, side));
        // The side chat's words in the Bot Chat are not the side chat's turn.
        Assert.NotNull(Proof.Prompts(State(2, 1, ("ivy", bot, Proof.BotText), ("ivy", bot, Proof.SideText)), bot, side));
        Assert.NotNull(Proof.Prompts(State(2, 1, ("ivy", bot, Proof.BotText), ("ivy", bot, Proof.BotText), ("ivy", side, Proof.SideText)), bot, side));
    }

    [Fact]
    public void TheSlowOpenIsTakenOnce()
    {
        Assert.Null(Proof.SlowOpenTaken(State(0, slowLeft: 0)));
        Assert.Contains("isn't taken", Proof.SlowOpenTaken(State(0, slowLeft: 1)));
        Assert.Contains("armed", Proof.SlowOpenTaken(new JsonObject { ["fail"] = new JsonArray() }));
    }

    [Fact]
    public void TheBotRowSaysTheStepInItsNameAndOnItsSecondLine()
    {
        Assert.Null(Proof.BotRow("Ivy. Reading package.json… 4:05 PM", ["Ivy", "Reading package.json…"], "Ivy", Proof.BotLine));
        Assert.Null(Proof.BotRow("Ivy. Reading package.json…", ["Ivy", "Reading package.json…"], "Ivy", Proof.BotLine));
        Assert.Contains("no row", Proof.BotRow(null, [], "Ivy", Proof.BotLine));
        Assert.Contains("Working…", Proof.BotRow("Ivy. Working… 4:05 PM", ["Ivy", "Working…"], "Ivy", Proof.BotLine));
        // Read aloud but not drawn, drawn but not read: both wrong.
        Assert.Contains("drawn", Proof.BotRow("Ivy. Reading package.json…", ["Ivy", "Working…"], "Ivy", Proof.BotLine));
        Assert.Contains("reads", Proof.BotRow("Ivy. Working…", ["Ivy", "Reading package.json…"], "Ivy", Proof.BotLine));
        // Another bot's row.
        Assert.NotNull(Proof.BotRow("Research. Reading package.json…", ["Research", "Reading package.json…"], "Ivy", Proof.BotLine));
    }

    [Fact]
    public void TheSessionsRowSaysTheStepInItsNameAndOnItsSecondLine()
    {
        // SessionRowWords.AccessibilityLabel drops the ellipsis; the second line is "<owner> · <step>" (or the step alone).
        Assert.Null(Proof.SessionRow("Trip ideas. Running npm test. Ivy. 4:05 PM", ["Trip ideas", "Ivy · Running npm test…", "4:05 PM"], "Trip ideas", Proof.SideLine));
        Assert.Null(Proof.SessionRow("Trip ideas. Running npm test. Ivy", ["Trip ideas", "Running npm test…"], "Trip ideas", Proof.SideLine));
        Assert.Contains("no row", Proof.SessionRow(null, [], "Trip ideas", Proof.SideLine));
        Assert.Contains("reads", Proof.SessionRow("Trip ideas. Working. Ivy", ["Trip ideas", "Ivy · Working…"], "Trip ideas", Proof.SideLine));
        Assert.Contains("drawn", Proof.SessionRow("Trip ideas. Running npm test. Ivy", ["Trip ideas", "Ivy · Working…"], "Trip ideas", Proof.SideLine));
        // The Bot Chat's step on the side chat's row is wrong (each chat its own step).
        Assert.NotNull(Proof.SessionRow("Trip ideas. Reading package.json. Ivy", ["Trip ideas", "Ivy · Reading package.json…"], "Trip ideas", Proof.SideLine));
    }

    [Fact]
    public void AfterTheTurnTheRowsSayNeitherTheStepNorWorking()
    {
        Assert.Null(Proof.BotRowSettled("Ivy. Hi! I'm Ivy. 4:06 PM. Unread", ["Ivy", "Hi! I'm Ivy."], "Ivy", Proof.BotLine));
        Assert.Contains("still", Proof.BotRowSettled("Ivy. Reading package.json…", ["Ivy", "Reading package.json…"], "Ivy", Proof.BotLine));
        Assert.Contains("Working…", Proof.BotRowSettled("Ivy. Working…", ["Ivy", "Working…"], "Ivy", Proof.BotLine));
        Assert.Contains("no row", Proof.BotRowSettled(null, [], "Ivy", Proof.BotLine));
        Assert.Null(Proof.SessionRowSettled("Trip ideas. Ivy: Hi! I'm Ivy.. 4:06 PM", ["Trip ideas", "Ivy · Hi! I'm Ivy."], "Trip ideas", Proof.SideLine));
        Assert.Contains("still", Proof.SessionRowSettled("Trip ideas. Running npm test. Ivy", ["Trip ideas", "Ivy · Running npm test…"], "Trip ideas", Proof.SideLine));
        Assert.Contains("Working", Proof.SessionRowSettled("Trip ideas. Working. Ivy", ["Trip ideas", "Ivy · Working…"], "Trip ideas", Proof.SideLine));
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
        Assert.Contains("\"windows/ci/fixtures/settings-gateway.py\",\"--port\",\"9838\"", entry.Groups["args"].Value);
        Assert.Contains($"walks = @(\"{Proof.Walk}\")", entry.Groups["rest"].Value);
        Assert.Contains("shots = @(\"row-step-bots\",\"row-step-sessions\",\"row-waking\")", entry.Groups["rest"].Value);
        // The toasts extra stays last (WIN-61: a later sign-in clears the toasts).
        Assert.True(yml.IndexOf("tag = \"row-steps\"", StringComparison.Ordinal) < yml.IndexOf("tag = \"toasts\"", StringComparison.Ordinal));
        // The E2E step starts, waits for, hands over and stops its own stand-in.
        Assert.Contains("$rowsteps = Start-Process python -ArgumentList \"windows/ci/fixtures/settings-gateway.py\",\"--port\",\"9837\",\"--credentials\",\"$fix/e2e-rowsteps.json\"", yml);
        Assert.Contains("(Test-Path \"$fix/e2e-rowsteps.json\")", yml);
        Assert.Contains("\"e2e-rowsteps.json\"", yml);
        Assert.Contains("$env:HQW_E2E_ROWSTEPS_CREDENTIALS = (Resolve-Path \"$fix/e2e-rowsteps.json\").Path", yml);
        Assert.Contains("$rowsteps.Id", yml);
        var e2e = Read("scripts", "e2e.sh");
        Assert.Contains("RSPORT=${HQW_E2E_ROWSTEPS_PORT:-9837}", e2e);
        Assert.Contains("start_fixture $FIX/e2e-rowsteps.log python3 $FIXTURES/settings-gateway.py --port $RSPORT --credentials $FIX/e2e-rowsteps.json", e2e);
        Assert.Contains("export HQW_E2E_ROWSTEPS_CREDENTIALS=$PWD/$FIX/e2e-rowsteps.json", e2e);
    }

    [Fact]
    public void TheStandInHasTheHoldTheReleaseAndAOneBotSlowOpen()
    {
        var gateway = Read("ci", "fixtures", "settings-gateway.py");
        Assert.Contains($"if path == '{Proof.HoldPath}':", gateway);
        Assert.Contains($"if path == '{Proof.ReleasePath}':", gateway);
        Assert.Contains("'held': len(HELD)", gateway);
        Assert.Contains("time.sleep(taken.get('seconds', 35))", gateway);
        Assert.Contains("entry.get('profile') in (None, profile)", gateway);
        // A reset lets every held turn go.
        Assert.Contains("for gate in HELD: gate.set()", gateway);
        // The seed the walk counts on: ivy's side chat Trip ideas, and Research with a Bot Chat.
        Assert.Contains("trip['title'] = 'Trip ideas'", gateway);
        Assert.Contains("'research': {'display_name': 'Research'", gateway);
    }

    [Fact]
    public void TheAppRegistersTheWalkAndTakesEveryPicture()
    {
        Assert.Contains("        RegisterRowStepsWalks();", Read("src", "HermesHQ.Windows", "Services", "ProofWalks.cs"));
        var walk = Read("src", "HermesHQ.Windows", "Services", "ProofWalks.RowSteps.cs");
        // Literal names: WalkProofTests reads windows.yml's walks against the source as written.
        Assert.Contains("Automation.NamedWalks[\"row-steps\"] = RowStepsAsync;", walk);
        foreach (var name in Proof.Shots) Assert.Contains($"await shot(\"{name}\");", walk);
        Assert.Contains("await shot(\"row-steps\");", walk);
        // The rows are read as drawn: their UI Automation names and words, never the stores.
        Assert.Contains("AutomationProperties.GetName(", walk);
        Assert.Contains("RowStepsWalkProof.BotRow(", walk);
        Assert.Contains("RowStepsWalkProof.SessionRow(", walk);
        Assert.DoesNotContain(".Step", walk.Replace("RowStepsWalkProof.", ""));
        Assert.DoesNotContain("LiveSummaries", walk);
        // The app's own controls, no OS input.
        Assert.DoesNotContain("Keys.", walk);
        Assert.DoesNotContain("Mouse.", walk);
        // The stand-in's held turns are let go whatever happens.
        Assert.Matches(new System.Text.RegularExpressions.Regex(@"finally\n\s+\{\n\s+// Nothing left held"), walk);
    }

    [Fact]
    public void TheWakingRowAndItsEnd()
    {
        Assert.Null(Proof.BotRow("Research. Waking up… 1:00 PM", ["Research", "Waking up…"], "Research", Proof.Waking));
        Assert.Contains("Three papers", Proof.BotRow("Research. Three papers to read. 1:00 PM", ["Research", "Three papers to read."], "Research", Proof.Waking));
        Assert.Null(Proof.BotRowSettled("Research. Three papers to read. 1:00 PM", ["Research", "Three papers to read."], "Research", Proof.Waking));
        Assert.Contains("still", Proof.BotRowSettled("Research. Waking up…", ["Research", "Waking up…"], "Research", Proof.Waking));
    }
}
