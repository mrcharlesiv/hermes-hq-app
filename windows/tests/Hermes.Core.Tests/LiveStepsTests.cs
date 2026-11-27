// [WIN-LIVE-STEPS] The Bots and Sessions rows name the running step instead of "Working…" (owner, 2026-10-30), per chat,
// from the client socket's frames. Ported case for case from the Mac at 93f984bb1: Tests/Chat/LiveStepsTests.swift
// (namesTheNewestStepUntilTheReplyWrites, theTurnsEndClearsIt, eachChatKeepsItsOwn, argumentsAsTheChatReadsThem,
// rowLine, rowsSayTheStep) and Tests/Chat/ToolNowTests.swift (commandsKeepSudoAndMaskPasswords, phrases; the thinking
// row's case is the chat's, not the rows'). The rest state App/AppModel.swift `pushSteps` (each step by its chat's bot
// and stored id; a side chat's step never the bot row's), `offScreenTurnEnded` (`liveSteps.clear`) and `tearDown`
// (`liveSteps.reset()`), and BotStore `ownSteps`/SessionStore `setSteps`. Windows' stores hold the row's line
// ("Reading package.json…"; PushSteps applies LiveSteps.Line), where the Mac's hold the words and the row applies it.
// The Mac's roster bot "Otto" stays (a demo bot). Synthetic data only.

using System.Text.Json.Nodes;
using Hermes.Core.Activity;
using Hermes.Core.Bots;
using Hermes.Core.Chat;
using Hermes.Core.Groups;
using Hermes.Core.Model;
using Hermes.Core.Rpc;
using Hermes.Core.Sessions;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Tests;

public class LiveStepsTests
{
    private static RpcEvent Event(string type, JsonObject? payload = null, string runtime = "r1") => new(type, runtime, payload ?? [], null);

    private static RpcEvent Start(string name, JsonObject args, string runtime = "r1") =>
        Event("tool.start", new JsonObject { ["name"] = name, ["tool_id"] = $"t-{name}", ["args"] = args }, runtime);

    // MARK: LiveStepsTests.swift

    [Fact]
    public void NamesTheNewestStepUntilTheReplyWrites()
    {
        var steps = new LiveSteps();
        Assert.False(steps.Handle(Event("message.start")));
        Assert.False(steps.ByRuntime.ContainsKey("r1"));                     // no step yet: "Working…"
        Assert.True(steps.Handle(Start("read_file", new() { ["path"] = "/Users/x/app/package.json" })));
        Assert.Equal("reading package.json", steps.ByRuntime["r1"]);
        // A finished step stays named through the thinking after it (the thinking row's rule).
        Assert.False(steps.Handle(Event("tool.complete", new() { ["name"] = "read_file", ["tool_id"] = "t-read_file" })));
        Assert.False(steps.Handle(Event("reasoning.delta", new() { ["text"] = "Let me check" })));
        Assert.Equal("reading package.json", steps.ByRuntime["r1"]);
        Assert.True(steps.Handle(Start("terminal", new() { ["command"] = "cd /Users/x/app && npm test" })));
        Assert.Equal("running npm test", steps.ByRuntime["r1"]);
        // A silent step leaves the one before it.
        Assert.False(steps.Handle(Start("todo", new() { ["todos"] = new JsonArray() })));
        Assert.Equal("running npm test", steps.ByRuntime["r1"]);
        // Blank deltas don't count as writing; words do.
        Assert.False(steps.Handle(Event("message.delta", new() { ["text"] = "\n " })));
        Assert.True(steps.Handle(Event("message.delta", new() { ["text"] = "All tests pass." })));
        Assert.False(steps.ByRuntime.ContainsKey("r1"));
        Assert.False(steps.Handle(Event("message.delta", new() { ["text"] = " More." })));   // nothing to clear: no change
    }

    [Fact]
    public void TheTurnsEndClearsIt()
    {
        foreach (var end in new[]
                 {
                     Event("message.complete", new() { ["text"] = "Done" }), Event("error", new() { ["message"] = "x" }),
                     Event("session.interrupt"), Event("session.info", new() { ["running"] = false }),
                 })
        {
            var each = new LiveSteps();
            each.Handle(Start("web_search", new() { ["query"] = "swift actors" }));
            Assert.Equal("searching the web for swift actors", each.ByRuntime["r1"]);
            Assert.True(each.Handle(end));
            Assert.False(each.ByRuntime.ContainsKey("r1"));
        }
        var steps = new LiveSteps();
        steps.Handle(Start("web_search", new() { ["query"] = "swift actors" }));
        Assert.False(steps.Handle(Event("session.info", new() { ["running"] = true })));
        Assert.True(steps.Clear("r1"));
        Assert.Empty(steps.ByRuntime);
    }

    [Fact]
    public void EachChatKeepsItsOwn()
    {
        var steps = new LiveSteps();
        steps.Handle(Start("read_file", new() { ["path"] = "/a/notes.md" }, runtime: "r1"));
        steps.Handle(Start("browser_navigate", new() { ["url"] = "https://www.apple.com/iphone/" }, runtime: "r2"));
        Assert.Equal(new Dictionary<string, string> { ["r1"] = "reading notes.md", ["r2"] = "opening apple.com" }, steps.ByRuntime);
        steps.Handle(Event("message.complete", runtime: "r2"));
        Assert.Equal(new Dictionary<string, string> { ["r1"] = "reading notes.md" }, steps.ByRuntime);
        Assert.False(steps.Handle(Start("read_file", new() { ["path"] = "/a/notes.md" }, runtime: "")));   // broadcasts: nobody's
    }

    [Fact]
    public void ArgumentsAsTheChatReadsThem()
    {
        var steps = new LiveSteps();
        steps.Handle(Event("tool.start", new() { ["name"] = "terminal", ["args_text"] = """{"command": "git status"}""" }));
        Assert.Equal("running git status", steps.ByRuntime["r1"]);
        steps.Handle(Event("tool.start", new() { ["name"] = "read_file", ["arguments"] = new JsonObject { ["path"] = "/x/a.swift" } }));
        Assert.Equal("reading a.swift", steps.ByRuntime["r1"]);
        // A message to another bot names it as the roster does.
        var roster = new[] { new DeliveryMessages.Seat("otto", "Otto", null) };
        steps.Handle(Start("message_agent", new() { ["target"] = "@otto", ["message"] = "hi" }), roster);
        Assert.Equal("messaging Otto", steps.ByRuntime["r1"]);
    }

    [Fact]
    public void RowLine()
    {
        Assert.Equal("Reading package.json…", LiveSteps.Line("reading package.json"));
        Assert.Equal("Running npm test…", LiveSteps.Line("running npm test"));
    }

    [Fact]
    public void RowsSayTheStep()
    {
        var p = RosterProfile.From(JsonNode.Parse("""{"name":"otto"}"""))!;
        var bot = new BotRow { Id = "otto", Name = "Otto", Profile = p, Model = p.ToModel("Otto", new BotMeta()), Role = "Earlier", IsWorking = true };
        Assert.Equal("Working…", BotList.SecondLine(bot).Text);
        bot = bot with { Step = LiveSteps.Line("reading package.json") };
        Assert.Equal("Reading package.json…", BotList.SecondLine(bot).Text);
        Assert.Equal(BotList.Tone.Tint, BotList.SecondLine(bot).Tone);
        Assert.Contains("Reading package.json", BotList.AccessibilityLabel(bot, "2:34 PM"));
        bot = bot with { IsWorking = false };                                 // a stale step never shows on an idle row
        Assert.Equal("Earlier", BotList.SecondLine(bot).Text);

        var session = new SessionSummary { Id = "s", Profile = "otto", Title = "Pricing", Preview = "Earlier", IsRunning = true, Status = SessionStatus.Working };
        var none = new HashSet<SessionRowDetail>();
        Assert.Equal("Working…", SessionRowWords.DetailText(session, none));
        session = session with { Step = LiveSteps.Line("running npm test") };
        Assert.Equal("Running npm test…", SessionRowWords.DetailText(session, none));
        Assert.Contains("Running npm test", SessionRowWords.AccessibilityLabel("Pricing", session, "Otto", none, ""));
    }

    // MARK: ToolNowTests.swift

    private static ToolCall Call(string name, string args) =>
        new($"c-{name}", name, args, null, ToolState.Running);

    [Fact]
    public void CommandsKeepSudoAndMaskPasswords()
    {
        Assert.Equal("running sudo brew upgrade", ToolNow.Phrase(Call("terminal", """{"command": "sudo env FOO=1 /usr/local/bin/brew upgrade"}""")));
        Assert.Equal("running sudo mysql -u root -p•••• db", ToolNow.Phrase(Call("terminal", """{"command": "sudo mysql -u root -pHunter22 db"}""")));
        Assert.DoesNotContain("hunter2", ToolNow.Phrase(Call("terminal", """{"command": "mysql --password=*** -e x"}""")));
    }

    [Fact]
    public void Phrases()
    {
        Assert.Equal("running npm test", ToolNow.Phrase(Call("terminal", """{"command": "cd /Users/x/app && npm test"}""")));
        Assert.Equal("running python3 run_checks.py --fast",
            ToolNow.Phrase(Call("terminal", """{"command": "PYTHONPATH=. /usr/bin/python3 /a/b/run_checks.py --fast\nmore"}""")));
        Assert.Equal("reading package.json", ToolNow.Phrase(Call("read_file", """{"path": "/Users/x/app/package.json"}""")));
        Assert.Equal("searching the web for swift actors", ToolNow.Phrase(Call("web_search", """{"query": "swift actors"}""")));
        Assert.Equal("opening apple.com", ToolNow.Phrase(Call("browser_navigate", """{"url": "https://www.apple.com/iphone/compare/"}""")));
        Assert.Equal("making an image", ToolNow.Phrase(Call("image_generate", """{"prompt": "a red fox"}""")));
        Assert.Equal("using linear search issues", ToolNow.Phrase(Call("mcp__linear__search_issues", "{}")));
        // Composio's say the action inside the app, never "Composio" (owner, 2026-10-29).
        Assert.Equal("looking for the right tool", ToolNow.Phrase(Call("mcp__composio__COMPOSIO_SEARCH_TOOLS", """{"queries": []}""")));
        Assert.Equal("looking for a tool to send email",
            ToolNow.Phrase(Call("mcp__composio__COMPOSIO_SEARCH_TOOLS", """{"queries": [{"use_case": "Send email"}]}""")));
        Assert.Equal("running SOQL query in Salesforce", ToolNow.Phrase(Call("mcp__composio__COMPOSIO_MULTI_EXECUTE_TOOL",
            """{"tools": [{"tool_slug": "SALESFORCE_RUN_SOQL_QUERY"}]}""")));
        Assert.Equal("searching page in Notion", ToolNow.Phrase(Call("mcp__composio__COMPOSIO_MULTI_EXECUTE_TOOL",
            """{"tools": [{"tool_slug": "NOTION_SEARCH_NOTION_PAGE"}]}""")));
        Assert.Equal("running 2 actions in Gmail", ToolNow.Phrase(Call("mcp__composio__COMPOSIO_MULTI_EXECUTE_TOOL",
            """{"tools": [{"tool_slug": "GMAIL_FETCH_EMAILS"}, {"tool_slug": "GMAIL_LIST_LABELS"}]}""")));
        Assert.Equal("running 2 actions in Google Calenda…", ToolNow.Phrase(Call("mcp__composio__COMPOSIO_MULTI_EXECUTE_TOOL",
            """{"tools": [{"tool_slug": "GOOGLECALENDAR_FIND_EVENT"}, {"tool_slug": "SLACK_SEND_MESSAGE"}]}""")));
        Assert.Equal("checking the Google Drive connection",
            ToolNow.Phrase(Call("mcp__composio__COMPOSIO_MANAGE_CONNECTIONS", """{"toolkits": ["googledrive"]}""")));
        Assert.Equal("reading how to use download file in…",
            ToolNow.Phrase(Call("mcp__composio__COMPOSIO_GET_TOOL_SCHEMAS", """{"tool_slugs": ["GOOGLEDRIVE_DOWNLOAD_FILE"]}""")));
        Assert.Equal("running a script that does download…", ToolNow.Phrase(Call("mcp__composio__COMPOSIO_REMOTE_WORKBENCH",
            """{"code_to_execute": "r,err=run_composio_tool('GOOGLEDRIVE_DOWNLOAD_FILE',{'fileId':1})"}""")));
        Assert.Equal("running a script", ToolNow.Phrase(Call("mcp__composio__COMPOSIO_REMOTE_WORKBENCH", """{"code_to_execute": "print(1)"}""")));
        Assert.DoesNotContain("composio", ToolNow.Phrase(Call("mcp__composio__COMPOSIO_SOMETHING_NEW", "{}")).ToLowerInvariant());
        // Bots reach Composio through the gateway's tool_call wrapper: the call inside is what's named.
        const string wrapped = """{"calls": [{"name": "mcp__composio__COMPOSIO_MULTI_EXECUTE_TOOL", "arguments": {"tools": [{"tool_slug": "GOOGLEDRIVE_FIND_FILE"}]}}]}""";
        Assert.Equal("finding file in Google Drive", ToolNow.Phrase(Call("tool_call", wrapped)));
        Assert.Equal("Finding file in Google Drive", ToolLines.Line(Call("tool_call", wrapped)).Text);
        Assert.Equal("using github get issue", ToolNow.Phrase(Call("mcp_github_GET_ISSUE", "{}")));
        var longQuery = ToolNow.Phrase(Call("web_search", """{"query": "how do I make a swiftui list scroll to the bottom on appear"}"""));
        Assert.Equal("searching the web for how do I make a swiftui list scroll…", longQuery);
        Assert.Equal(ToolNow.SubjectLimit, ToolNow.Short(new string('a', 40)).Length);
    }

    // MARK: AppModel.swift pushSteps / offScreenTurnEnded / tearDown, BotStore ownSteps, SessionStore setSteps

    private static BotStore Bots()
    {
        var store = new BotStore(new FakeGateway(), new MemoryDeviceStore());
        store.ApplyFull(new JsonObject
        {
            ["profiles"] = new JsonArray
            {
                new JsonObject { ["name"] = "ivy", ["canonical_session"] = new JsonObject { ["id"] = "ivy-chat", ["title"] = "Bot Chat", ["preview"] = "old words", ["last_active"] = 1_791_000_000.0 } },
                new JsonObject { ["name"] = "wren", ["canonical_session"] = new JsonObject { ["id"] = "wren-chat", ["title"] = "Bot Chat", ["preview"] = "wren's", ["last_active"] = 1_791_000_500.0 } },
            },
        }, DateTimeOffset.UtcNow);
        return store;
    }

    private static SessionStore Sessions()
    {
        var sessions = new SessionStore(new FakeGateway(), new MemoryDeviceStore());
        sessions.Apply(SidebarPayload.Decode(JsonNode.Parse("""
            {"recents":{"sessions":[
              {"id":"side-1","profile":"ivy","title":"Pricing","preview":"Check the prices.","last_active":1791000100,"message_count":2,"source":"desktop"},
              {"id":"side-2","profile":"wren","title":"Notes","preview":"Tidy the notes.","last_active":1791000200,"message_count":2,"source":"desktop"}]},
             "cron":{"sessions":[]},"messaging":{"sessions":[]}}
            """)));
        return sessions;
    }

    private static TurnRows Rows(BotStore bots, SessionStore sessions)
    {
        var rows = new TurnRows { Roster = () => [] };
        rows.Changed += change => rows.ApplyTo(change, bots, sessions);
        return rows;
    }

    [Fact]
    public void EachChatsStepGoesToItsOwnRows()
    {
        var (bots, sessions) = (Bots(), Sessions());
        var rows = Rows(bots, sessions);
        rows.Closed("ivy", "ivy-chat", "r-main", running: true);             // ivy's Bot Chat, off screen
        rows.Closed("ivy", "side-1", "r-side", running: true);               // one of its side chats
        rows.Event(Start("read_file", new() { ["path"] = "/a/package.json" }, runtime: "r-main"), onScreen: false);
        Assert.Equal("Reading package.json…", BotList.SecondLine(bots.Bot("ivy")!).Text);
        // The side chat's step is its Sessions row's, never the bot row's.
        rows.Event(Start("terminal", new() { ["command"] = "npm test" }, runtime: "r-side"), onScreen: false);
        Assert.Equal("Reading package.json…", BotList.SecondLine(bots.Bot("ivy")!).Text);
        var side = sessions.LiveSummaries().Single(s => s.Id == "side-1");
        Assert.Equal("Running npm test…", SessionRowWords.DetailText(side, new HashSet<SessionRowDetail>()));
        Assert.Equal(new Dictionary<string, string> { ["r-main"] = "reading package.json", ["r-side"] = "running npm test" }, rows.StepsByRuntime);
        // The Bot Chat's reply writes: its row is Working… again, the side chat keeps its step.
        rows.Event(Event("message.delta", new() { ["text"] = "Found it." }, runtime: "r-main"), onScreen: false);
        Assert.Equal("Working…", BotList.SecondLine(bots.Bot("ivy")!).Text);
        Assert.Equal("Running npm test…", sessions.LiveSummaries().Single(s => s.Id == "side-1").Step);
        // Another bot's untouched.
        Assert.Null(bots.Bot("wren")!.Step);
        Assert.Null(sessions.LiveSummaries().Single(s => s.Id == "side-2").Step);
    }

    [Fact]
    public void ABotChatNotStoredYetIsItsBotsOwn()
    {
        var (bots, sessions) = (Bots(), Sessions());
        var rows = Rows(bots, sessions);
        rows.Running("wren", null, "r-new", running: true, external: false);   // a Bot Chat not stored yet ("")
        rows.Event(Start("web_search", new() { ["query"] = "swift actors" }, runtime: "r-new"), onScreen: true);
        Assert.Equal("Searching the web for swift actors…", BotList.SecondLine(bots.Bot("wren")!).Text);
        // A step whose chat this run doesn't know is no row's.
        rows.Event(Start("read_file", new() { ["path"] = "/a/b.md" }, runtime: "r-unknown"), onScreen: false);
        Assert.Null(bots.Bot("ivy")!.Step);
        Assert.All(sessions.LiveSummaries(), s => Assert.Null(s.Step));
    }

    [Fact]
    public void TheStepClearsAtTheTurnsEndAndAtTheTeardown()
    {
        var (bots, sessions) = (Bots(), Sessions());
        var rows = Rows(bots, sessions);
        rows.Closed("ivy", "side-1", "r-side", running: true);
        rows.Event(Start("terminal", new() { ["command"] = "npm test" }, runtime: "r-side"), onScreen: false);
        Assert.Equal("Running npm test…", sessions.LiveSummaries().Single(s => s.Id == "side-1").Step);
        // `offScreenTurnEnded` → `liveSteps.clear(runtime)`.
        var end = rows.Event(Event("session.info", new() { ["running"] = false }, runtime: "r-side"), onScreen: false);
        Assert.True(end.Steps);
        Assert.Empty(rows.StepsByRuntime);
        Assert.Null(sessions.LiveSummaries().Single(s => s.Id == "side-1").Step);

        // The account's teardown: `liveSteps.reset()`, and the rows take no step.
        rows.Closed("ivy", "ivy-chat", "r-main", running: true);
        rows.Event(Start("read_file", new() { ["path"] = "/a/package.json" }, runtime: "r-main"), onScreen: false);
        Assert.Equal("Reading package.json…", bots.Bot("ivy")!.Step);
        var reset = rows.Reset();
        Assert.True(reset.Steps);
        Assert.Empty(rows.StepsByRuntime);
        Assert.Null(bots.Bot("ivy")!.Step);
        Assert.False(rows.Reset().Steps);                                    // nothing left: nothing to hand over
    }

    [Fact]
    public void OnlyAChangedStepIsHandedOver()
    {
        var rows = new TurnRows { Roster = () => [] };
        Assert.True(rows.Event(Start("read_file", new() { ["path"] = "/a/package.json" }), onScreen: false).OnlySteps);
        Assert.True(rows.Event(Start("read_file", new() { ["path"] = "/a/package.json" }), onScreen: false).IsEmpty);   // the same words
        Assert.True(rows.Event(Event("reasoning.delta", new() { ["text"] = "Hmm" }), onScreen: false).IsEmpty);
        var bots = Bots();
        var raised = 0;
        bots.Changed += () => raised++;
        bots.SetSteps(new Dictionary<string, IReadOnlyDictionary<string, string>>());   // nothing held: no redraw
        Assert.Equal(0, raised);
    }
}
