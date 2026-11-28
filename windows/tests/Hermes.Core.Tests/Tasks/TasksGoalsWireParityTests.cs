// Wave 1B wire-parity regression tests for Tasks, TaskIdeas, Offers, and Goals
// against HermesKit (TodoModel.swift, TaskIdeas.swift, TodoLists.swift, GoalModel.swift, GoalBots.swift, TasksStore.swift).

using System.Text.Json.Nodes;
using Hermes.Core.Tasks;

namespace Hermes.Core.Tests.Tasks;

public sealed class TasksGoalsWireParityTests
{
    private static readonly TimeZoneInfo Chicago = TimeZoneInfo.FindSystemTimeZoneById("America/Chicago");
    private static readonly DateTimeOffset Now = new(2026, 12, 14, 9, 41, 0, TimeSpan.FromHours(-6));

    // ------------------------------------------------------------------ TodoChat, TodoWire.NewTask, TodoSettings

    [Fact]
    public void TodoChatWiresSessionIdAndParsesEmptyObjectAsNull()
    {
        var chat = new TodoChat("ivy", "sess_42");
        var wire = chat.Wire();
        Assert.Equal("ivy", wire.Str("profile"));
        Assert.Equal("sess_42", wire.Str("session_id"));
        Assert.Null(wire.Get("session"));

        var parsed = TodoChat.From(wire);
        Assert.Equal(chat, parsed);
        Assert.Null(TodoChat.From(new JsonObject()));
    }

    [Fact]
    public void TodoWireNewTaskPreservesRepeatOnTogetherWhenFieldsSupported()
    {
        var legacy = TodoWire.NewTask("Sync", TodoWho.Together, "ivy", "2026-12-20", "weekly", prep: true, fieldsSupported: false);
        Assert.Null(legacy.Get("repeat"));

        var modern = TodoWire.NewTask("Sync", TodoWho.Together, "ivy", "2026-12-20", "every:2:weeks", prep: true, fieldsSupported: true);
        Assert.Equal("every:2:weeks", modern.Str("repeat"));
        Assert.Equal("together", modern.Str("who"));
        Assert.Equal("ivy", modern.Str("bot"));

        var botOnly = TodoWire.NewTask("Check logs", TodoWho.Bot, "ivy", "2026-12-20", "daily", prep: true, fieldsSupported: true);
        Assert.Null(botOnly.Get("repeat"));

        var personal = TodoWire.NewTask("Water plants", TodoWho.Me, null, "2026-12-20", "after:3:days", prep: false, fieldsSupported: false);
        Assert.Equal("after:3:days", personal.Str("repeat"));
    }

    [Fact]
    public void TodoSettingsRoundTripsIdeasBotsSourcesAndNoteAndListAnswerReadsCustomRepeat()
    {
        var sources = new TodoIdeasSources(
            chats: true,
            chatBots: ["default", "work"],
            memory: true,
            files: true,
            web: false,
            connectors: ["composio:gmail", "mcp:notion"]);

        var settings = new TodoSettings(Enabled: true, Capture: "ask", Sort: "smart")
        {
            Ideas = true,
            IdeasBot = "default",
            IdeasBots = ["default", "work"],
            IdeasAt = "07:30",
            IdeasMax = 4,
            IdeasSources = sources,
            IdeasNote = "Check Notion Inbox. Skip newsletters.",
        };

        var wire = settings.Wire();
        var reparsed = TodoSettings.From(TodoEdits.Reparse(wire));
        Assert.Equal(settings, reparsed);
        Assert.Equal(["default", "work"], reparsed.ActiveIdeasBots);
        Assert.Equal(["composio:gmail", "mcp:notion"], reparsed.IdeasSources!.Connectors);
        Assert.Equal("Check Notion Inbox. Skip newsletters.", reparsed.IdeasNote);

        // Older add-on without 0.9.86 keys omits them on Wire()
        var older = TodoSettings.From(JsonNode.Parse("""{"enabled":true,"capture":"ask","sort":"smart","ideas":false,"ideas_bot":"default","ideas_at":"07:30","ideas_max":3}"""));
        var olderWire = older.Wire();
        Assert.Null(olderWire.Get("ideas_bots"));
        Assert.Null(olderWire.Get("ideas_sources"));
        Assert.Null(olderWire.Get("ideas_note"));
        Assert.Equal(["default"], older.ActiveIdeasBots);

        // TodoListAnswer.CustomRepeat
        var list = TodoListAnswer.From(JsonNode.Parse("""{"rev":9,"tasks":[],"custom_repeat":true}"""));
        Assert.True(list.CustomRepeat);
        Assert.False(TodoListAnswer.From(JsonNode.Parse("""{"rev":9,"tasks":[]}""")).CustomRepeat);
    }

    // ------------------------------------------------------------------ TaskIdeas schema, sources, summary, polling, disk cache

    [Fact]
    public void TaskIdeasSchemaSummaryAndConnectorToggleMatchSwift()
    {
        var page = TaskIdeasPage.From(JsonNode.Parse("""
            {
              "on": true,
              "bot": "default",
              "bots": ["default", "work"],
              "at": "08:00",
              "max": 4,
              "looking": true,
              "ran_at": "2026-12-14T08:01:00Z",
              "note": "Focus on launch",
              "sources": {"chats": true, "chat_bots": ["default"], "memory": true, "files": false, "web": true, "connectors": ["mcp:notion"]},
              "available_sources": {
                "bots": ["default", "work"],
                "connectors": [
                  {"id": "composio:gmail", "name": "Gmail", "kind": "composio", "bots": ["default"]},
                  {"id": "mcp:notion", "name": "Notion", "kind": "mcp", "bots": ["work"]}
                ]
              },
              "ideas": [
                {
                  "id": "id_1",
                  "created_at": "2026-12-14T08:01:00Z",
                  "bot": "work",
                  "title": "Follow up with vendor",
                  "why": "They asked for PO yesterday",
                  "source": "Chat with Work, Mon",
                  "who": "together",
                  "help": "Draft the reply email",
                  "state": "new",
                  "task_id": null
                },
                {
                  "id": "id_2",
                  "title": "Buy milk",
                  "who": "me",
                  "state": "added",
                  "task_id": "t_99"
                }
              ]
            }
            """));

        Assert.True(page.On);
        Assert.True(page.Looking);
        Assert.True(page.Running);
        Assert.Equal("2026-12-14T08:01:00Z", page.RanAt);
        Assert.Equal(["default", "work"], page.ActiveBots);
        Assert.Equal("Focus on launch", page.Note);
        Assert.True(page.Sources!.Web);
        Assert.Equal(2, page.AvailableSources!.Connectors.Count);

        var first = page.Ideas[0];
        Assert.Equal("together", first.Who);
        Assert.Equal("Draft the reply email", first.Help);
        Assert.Equal("Chat with Work, Mon", first.Source);
        Assert.Equal("new", first.State);
        Assert.Null(first.TaskId);
        Assert.True(first.BotHelps);

        var second = page.Ideas[1];
        Assert.False(second.BotHelps);
        Assert.Equal("added", second.State);
        Assert.Equal("t_99", second.TaskId);

        // TaskIdeasSummary formatting & multi-bot auto-include
        var connectors = new[]
        {
            new TaskIdeasConnector("composio:gmail", "Gmail", "composio", ["default"]),
            new TaskIdeasConnector("mcp:notion", "Notion", "mcp", ["work"]),
        };
        var sources = new TodoIdeasSources();
        Assert.Equal("Chats, Memory", TaskIdeasSummary.ActiveSourcesLabel(sources, connectors));

        IReadOnlyList<string> activeBots = ["default"];
        (sources, var nextBots) = TaskIdeasSummary.ToggleConnector("mcp:notion", true, connectors[1], sources, activeBots);
        Assert.Equal(["mcp:notion"], sources.Connectors);
        Assert.Equal(["default", "work"], nextBots);
        Assert.Equal("Chats, Memory, Notion", TaskIdeasSummary.ActiveSourcesLabel(sources, connectors));

        (sources, nextBots) = TaskIdeasSummary.ToggleConnector("composio:gmail", true, connectors[0], sources, nextBots);
        Assert.Equal(["default", "work"], nextBots);
        Assert.Equal("Chats, Memory, Notion, Gmail", TaskIdeasSummary.ActiveSourcesLabel(sources, connectors));

        (sources, nextBots) = TaskIdeasSummary.ToggleConnector("mcp:notion", false, connectors[1], sources, nextBots);
        Assert.Equal(["composio:gmail"], sources.Connectors);

        Assert.Equal("Google Calendar", TaskIdeasSummary.PrettyConnectorName("composio:google_calendar"));
        Assert.Equal("Custom App", TaskIdeasSummary.PrettyConnectorName("mcp:custom-app"));

        (string Id, string Name)[] roster = [("default", "Hermes"), ("work", "Work"), ("research", "Research")];
        Assert.Equal("Hermes", TaskIdeasSummary.ActiveBotsLabel(["default"], roster));
        Assert.Equal("Hermes & Work", TaskIdeasSummary.ActiveBotsLabel(["default", "work"], roster));
        Assert.Equal("Hermes, Work +1", TaskIdeasSummary.ActiveBotsLabel(["default", "work", "research"], roster));
        Assert.Equal("All bots", TaskIdeasSummary.ChatBotsSubtitle(sources, roster));
        Assert.Equal("Hermes, Work · 1 bot excluded", TaskIdeasSummary.ChatBotsSubtitle(sources with { ChatBots = ["default", "work"] }, roster));
        Assert.Equal("Off · blocked during runs", TaskIdeasSummary.ChatBotsSubtitle(sources with { Chats = false }, roster));
    }

    [Fact]
    public async Task TaskIdeasStorePollsWhileLookingReadsSourcesAndCachesToDisk()
    {
        var tempDir = Path.Combine(Path.GetTempPath(), "hermes-ideas-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            var pollCalls = 0;
            var sourcesCalled = false;
            var rest = new FakeRest(r =>
            {
                if (r.Method == "GET" && r.Path == TasksApi.Base + "/ideas/sources")
                {
                    sourcesCalled = true;
                    return new JsonObject
                    {
                        ["bots"] = new JsonArray("default", "work"),
                        ["connectors"] = new JsonArray(new JsonObject
                        {
                            ["id"] = "mcp:notion", ["name"] = "Notion", ["kind"] = "mcp", ["bots"] = new JsonArray("work"),
                        }),
                    };
                }
                if (r.Method == "POST" && r.Path == TasksApi.Base + "/ideas/run")
                    return new JsonObject { ["started"] = true };
                if (r.Method == "GET" && r.Path == TasksApi.Base + "/ideas")
                {
                    pollCalls++;
                    var stillLooking = pollCalls < 3;
                    return new JsonObject
                    {
                        ["on"] = true,
                        ["bot"] = "default",
                        ["looking"] = stillLooking,
                        ["ran_at"] = stillLooking ? null : "2026-12-14T09:42:00Z",
                        ["ideas"] = stillLooking
                            ? new JsonArray()
                            : new JsonArray(new JsonObject { ["id"] = "i_fresh", ["title"] = "Send launch notes", ["who"] = "together", ["bot"] = "work" }),
                    };
                }
                return new JsonObject();
            });

            var api = new TasksApi(rest);
            var avail = await api.GetIdeasSourcesAsync();
            Assert.True(sourcesCalled);
            Assert.Equal(["default", "work"], avail.Bots);
            Assert.Equal("Notion", Assert.Single(avail.Connectors).Name);

            var store = new TaskIdeasStore(api, cacheDirectory: tempDir, pollInterval: TimeSpan.FromMilliseconds(20), pollTimeout: TimeSpan.FromSeconds(5));
            Assert.True(await store.LookNowAsync());
            Assert.True(store.Looking);

            // Wait for background poll to finish once looking flips to false
            var deadline = DateTime.UtcNow.AddSeconds(3);
            while ((store.Looking || store.IsPolling || store.VisibleIdeas.Count == 0) && DateTime.UtcNow < deadline)
                await Task.Delay(15);

            Assert.False(store.Looking);
            Assert.False(store.IsPolling);
            Assert.Equal("i_fresh", Assert.Single(store.VisibleIdeas).Id);
            Assert.True(File.Exists(Path.Combine(tempDir, "task-ideas.json")));

            // Fresh store paints cached page immediately via Prepare() without network
            var offlineStore = new TaskIdeasStore(new TasksApi(new FakeRest(_ => throw FakeRest.Http(503, "offline"))), cacheDirectory: tempDir);
            offlineStore.Prepare();
            Assert.True(offlineStore.Loaded);
            Assert.Equal("Send launch notes", Assert.Single(offlineStore.VisibleIdeas).Title);
            Assert.Equal("2026-12-14T09:42:00Z", offlineStore.Page.RanAt);

            store.Forget();
        }
        finally
        {
            if (Directory.Exists(tempDir)) Directory.Delete(tempDir, recursive: true);
        }
    }

    // ------------------------------------------------------------------ KeepTaskOpen PATCH wire format

    [Fact]
    public async Task KeepTaskOpenSendsPatchWithKeepOpenTrueAndRevNeverPost()
    {
        var rest = new FakeRest(r => (r.Method, r.Path) switch
        {
            ("GET", TasksApi.Base) => new JsonObject
            {
                ["rev"] = 4,
                ["tasks"] = new JsonArray(new JsonObject
                {
                    ["id"] = "t1",
                    ["rev"] = 7,
                    ["title"] = "Call the clinic",
                    ["status"] = "open",
                    ["offer"] = new JsonObject { ["by"] = "ivy", ["text"] = "Clinic emailed back", ["kept"] = false },
                }),
            },
            ("PATCH", TasksApi.Base + "/t1") => new JsonObject
            {
                ["id"] = "t1",
                ["rev"] = 8,
                ["title"] = "Call the clinic",
                ["status"] = "open",
                ["offer"] = new JsonObject { ["by"] = "ivy", ["text"] = "Clinic emailed back", ["kept"] = true },
            },
            _ => throw new InvalidOperationException($"Unexpected call: {r.Method} {r.Path}"),
        });

        var store = new TasksStore(new TasksApi(rest));
        await store.RefreshAsync(force: true);
        Assert.True(await store.KeepTaskOpenAsync("t1"));

        var patch = Assert.Single(rest.Log, r => r.Method == "PATCH");
        Assert.Equal(TasksApi.Base + "/t1", patch.Path);
        Assert.True(patch.Body!.Bool("keep_open"));
        Assert.Equal(7, patch.Body!.Int("rev"));
        Assert.DoesNotContain(rest.Log, r => r.Path.Contains("keep-open", StringComparison.Ordinal));
        Assert.True(store.Find("t1")!.Offer!.Kept);
    }

    // ------------------------------------------------------------------ GoalModel schema fixes

    [Fact]
    public void GoalModelDecodesWireSchemasForSourceReviewStandsCheckinDoneOfferAndKnownToAllDefault()
    {
        // Goal from 0.9.65 without team keys: KnownToAll defaults true, measure.source defaults "you"
        var plain = Goal.From(JsonNode.Parse("""
            {
              "id": "g_plain",
              "rev": 2,
              "title": "Run a 10K",
              "status": "active",
              "measure": {"unit": "km", "start": 0, "target": 10, "now": 3, "source": "you"}
            }
            """))!;
        Assert.True(plain.KnownToAll);
        Assert.True(plain.Measure!.EffectiveSource.IsYou);
        Assert.Equal("\"you\"", plain.Measure.EffectiveSource.Wire().ToJsonString());
        Assert.Equal("You", GoalBots.NumberFromWords(plain.Measure, p => p ?? "Hermes"));

        // Full 0.9.66 goal
        var full = Goal.From(JsonNode.Parse("""
            {
              "id": "g_1",
              "rev": 3,
              "title": "Ship the beta",
              "status": "active",
              "lead": "default",
              "helpers": ["ivy", "default", "", "wren"],
              "adds": "auto",
              "review": {"day": 0, "time": "08:00"},
              "known_to_all": false,
              "stands": {"by": "default", "at": "2026-12-14T08:02:00Z", "text": "Build 12 is out.", "next": "the invites"},
              "checkin": {"at": "2026-12-14T08:00:00Z", "offer": "of_c", "state": "offered"},
              "chat": {},
              "offer": {"kind": "done", "what": "goal", "by": "default", "text": "All done.", "at": "2026-12-14T08:00:00Z"},
              "measure": {"unit": "testers", "start": 0, "target": 10, "now": 4, "source": {"bot": "ivy", "what": "TestFlight"}, "checked_at": "2026-12-14T08:02:00Z"}
            }
            """))!;

        Assert.Equal(["default", "ivy", "wren"], full.Team);
        Assert.Equal(["ivy", "wren"], full.Helpers);
        Assert.Equal("auto", full.Adds);
        Assert.False(full.KnownToAll);
        Assert.Equal(new GoalReview(0, "08:00"), full.Review);
        Assert.Equal("Mondays 8 AM", GoalBots.ReviewWords(full.Review));
        Assert.Equal("Build 12 is out.", full.Stands!.Text);
        Assert.Equal("the invites", full.Stands.Next);
        Assert.Equal("offered", full.Checkin!.State);
        Assert.Equal("of_c", full.Checkin.Offer);
        Assert.Null(full.Chat);
        Assert.Equal("goal", full.Offer!.What);
        Assert.Equal("done", full.Offer.Kind);
        Assert.Equal("ivy", full.Measure!.EffectiveSource.Bot);
        Assert.Equal("TestFlight", full.Measure.EffectiveSource.What);
        Assert.Equal("""{"bot":"ivy","what":"TestFlight"}""", full.Measure.EffectiveSource.Wire().ToJsonString());
        Assert.Equal("TestFlight · Ivy", GoalBots.NumberFromWords(full.Measure, id => id == "ivy" ? "Ivy" : "Hermes"));
        Assert.Equal("TestFlight · 2:02 AM", GoalBots.SourceWords(full.Measure, Now, id => id == "ivy" ? "Ivy" : "Hermes", Chicago));

        // Invalid review slots & unknown adds fall back cleanly
        var bad = Goal.From(JsonNode.Parse("""{"id":"g_2","review":{"day":9,"time":"8"},"adds":"sometimes","offer":{"by":"ivy","text":"missing what"}}"""))!;
        Assert.Null(bad.Review);
        Assert.Equal("ask", bad.Adds);
        Assert.Null(bad.Offer);
        Assert.True(bad.KnownToAll);
    }

    // ------------------------------------------------------------------ TodoOffer schema & AnswerOfferAsync wire format

    [Fact]
    public void TodoOfferDecodesSwiftWireKeysSetupBuiltOnAndMove()
    {
        var listOffer = TodoOffer.From(JsonNode.Parse("""
            {
              "id": "o9",
              "bot": "otto",
              "session_id": "s1",
              "at": "2026-11-14T08:02:00-06:00",
              "list": "Work",
              "section": null,
              "new": true,
              "why": "From this week",
              "tasks": [{"title": "Send report", "due": "2026-11-16", "source": {"app": "Email", "who": "Ivy"}}],
              "move": [{"id": "t1", "title": "Call the bank"}],
              "state": "accepted",
              "move_state": "new",
              "listed": true,
              "added": ["t7"]
            }
            """))!;

        Assert.Equal("otto", listOffer.Bot);
        Assert.Equal("list", listOffer.Kind);
        Assert.False(listOffer.IsGoal);
        Assert.True(listOffer.IsNew);
        Assert.Equal("accepted", listOffer.State);
        Assert.True(listOffer.Undoable);
        Assert.True(listOffer.AsksMove);
        Assert.Equal("t1", Assert.Single(listOffer.Move).Id);
        Assert.Equal("Ivy", listOffer.Tasks[0].Source!.Who);

        var planOffer = TodoOffer.From(JsonNode.Parse("""
            {
              "id": "of_plan",
              "kind": "plan",
              "bot": "otto",
              "goal": "g_1",
              "title": "Draw every day",
              "state": "new",
              "milestones": [{"title": "A week of drawings"}],
              "tasks": [{"title": "Buy sketchbook", "who": "me"}, {"title": "Find prompts", "who": "bot"}],
              "setup": {"name": " Draw every day ", "why": "Get my hand back.", "due": "2027-03-31T00:00:00", "measure": {"unit": "drawings", "start": 0, "target": 100}},
              "built_on": ["Your  course\nnotes, 8 units", "  ", 3, "Sketching after work"]
            }
            """))!;

        Assert.True(planOffer.IsGoal);
        Assert.True(planOffer.IsWaiting);
        Assert.False(planOffer.Undoable);
        Assert.Equal("Draw every day", planOffer.Setup!.Name);
        Assert.Equal("2027-03-31", planOffer.Setup.Due);
        Assert.Equal(100, planOffer.Setup.Measure!.Target);
        Assert.Single(planOffer.Milestones);
        Assert.Equal(2, planOffer.Tasks.Count);
        Assert.Equal("otto", planOffer.Tasks[1].BotFor(planOffer));
        Assert.Equal(["Your course notes, 8 units", "Sketching after work"], GoalOffers.BuiltOnLines(planOffer));
        var setupRows = GoalOffers.SetupRows(planOffer, Now, Chicago);
        Assert.Equal(["Name", "Why", "Number", "By"], setupRows.Select(r => r.Label));
        Assert.Equal("Mar 31, 2027", setupRows.Single(r => r.Label == "By").Value);

        // Empty setup object becomes null; legacy "by" key is not read in place of "bot"
        var emptySetup = TodoOffer.From(JsonNode.Parse("""{"id":"of_2","by":"wrong","list":"Home","setup":{}}"""))!;
        Assert.Equal("default", emptySetup.Bot);
        Assert.Null(emptySetup.Setup);
    }

    [Fact]
    public async Task AnswerOfferSendsSwiftPayloadAndParsesRevOfferSectionsGoals()
    {
        var offerState = "new";
        var rest = new FakeRest(r =>
        {
            if (r.Method == "GET" && r.Path == TasksApi.Base)
            {
                return new JsonObject
                {
                    ["rev"] = 4,
                    ["tasks"] = new JsonArray(),
                    ["sections"] = new JsonArray(),
                    ["goals"] = new JsonArray(new JsonObject { ["id"] = "g1", ["rev"] = 1, ["title"] = "Launch" }),
                    ["goal_bots"] = true,
                    ["offers"] = new JsonArray(
                        new JsonObject { ["id"] = "o_list", ["bot"] = "otto", ["list"] = "Work", ["new"] = true, ["state"] = offerState, ["tasks"] = new JsonArray(new JsonObject { ["title"] = "Draft" }) },
                        new JsonObject { ["id"] = "o_goal", ["kind"] = "tasks", ["bot"] = "otto", ["goal"] = "g1", ["title"] = "Launch", ["state"] = offerState, ["tasks"] = new JsonArray(new JsonObject { ["title"] = "QA" }) }),
                };
            }
            if (r.Method == "POST" && r.Path == TasksApi.Base + "/offers/o_list")
            {
                offerState = "accepted";
                return new JsonObject
                {
                    ["rev"] = 5,
                    ["offer"] = new JsonObject { ["id"] = "o_list", ["bot"] = "otto", ["list"] = "Work", ["new"] = true, ["state"] = "accepted", ["listed"] = false, ["added"] = new JsonArray("t_new") },
                    ["sections"] = new JsonArray(new JsonObject { ["id"] = "sec_1", ["name"] = "Existing" }),
                };
            }
            if (r.Method == "POST" && r.Path == TasksApi.Base + "/offers/o_goal")
            {
                return new JsonObject
                {
                    ["rev"] = 6,
                    ["offer"] = new JsonObject { ["id"] = "o_goal", ["kind"] = "tasks", ["bot"] = "otto", ["goal"] = "g1", ["title"] = "Launch", ["state"] = "accepted", ["plan"] = false, ["in_goal"] = false },
                    ["sections"] = new JsonArray(),
                    ["goals"] = new JsonArray(new JsonObject { ["id"] = "g1", ["rev"] = 2, ["title"] = "Launch", ["lead"] = "otto" }),
                };
            }
            return new JsonObject();
        });

        var store = new TasksStore(new TasksApi(rest));
        await store.RefreshAsync(force: true);

        // List offer: AcceptNoList sends {"action":"accept","list":false} (never "accept_no_list")
        var listAns = await store.AnswerOfferAsync("o_list", TodoOfferAction.AcceptNoList);
        Assert.NotNull(listAns);
        Assert.Equal(5, listAns!.Rev);
        Assert.Equal("sec_1", Assert.Single(listAns.Sections).Id);
        var listPost = rest.Log.First(r => r.Method == "POST" && r.Path.EndsWith("/offers/o_list", StringComparison.Ordinal)).Body!;
        Assert.Equal("accept", listPost.Str("action"));
        Assert.False(listPost.Bool("list"));
        Assert.Null(listPost.Get("plan"));
        Assert.Null(listPost.Get("in_goal"));

        // Goal offer: sends action, list, plan, in_goal and parses rev/offer/sections/goals
        var goalAns = await store.AnswerOfferAsync("o_goal", TodoOfferAction.Accept, list: true, plan: false, inGoal: false);
        Assert.NotNull(goalAns);
        Assert.Equal(6, goalAns!.Rev);
        Assert.Equal("otto", Assert.Single(goalAns.Goals!).Lead);
        var goalPost = rest.Log.First(r => r.Method == "POST" && r.Path.EndsWith("/offers/o_goal", StringComparison.Ordinal)).Body!;
        Assert.Equal("accept", goalPost.Str("action"));
        Assert.True(goalPost.Bool("list"));
        Assert.False(goalPost.Bool("plan"));
        Assert.False(goalPost.Bool("in_goal"));
    }

    // ------------------------------------------------------------------ CreateGoalAsync team keys + teamLeft PATCH fallback

    [Fact]
    public async Task CreateGoalSendsTeamKeysInPostAndFallsBackToTeamLeftPatchOnOlderAddOn()
    {
        var olderAddOn = true;
        var rest = new FakeRest(r =>
        {
            if (r.Method == "GET" && r.Path == TasksApi.Base)
                return new JsonObject { ["rev"] = 1, ["tasks"] = new JsonArray(), ["goals"] = new JsonArray(), ["goal_bots"] = true };
            if (r.Method == "POST" && r.Path == TasksApi.Route + "/goals")
            {
                var resp = new JsonObject
                {
                    ["id"] = "g_new",
                    ["rev"] = 1,
                    ["title"] = r.Body!.Str("title"),
                    ["due"] = r.Body!.Str("due"),
                    ["measure"] = r.Body!.Get("measure")?.DeepClone(),
                };
                if (!olderAddOn)
                {
                    resp["lead"] = r.Body!.Str("lead");
                    resp["helpers"] = r.Body!.Get("helpers")?.DeepClone();
                    resp["adds"] = r.Body!.Str("adds");
                    resp["review"] = r.Body!.Get("review")?.DeepClone();
                }
                return resp;
            }
            if (r.Method == "PATCH" && r.Path == TasksApi.Route + "/goals/g_new")
            {
                return new JsonObject
                {
                    ["id"] = "g_new",
                    ["rev"] = 2,
                    ["title"] = "Draw every day",
                    ["due"] = "2027-03-31",
                    ["lead"] = r.Body!.Str("lead") ?? "otto",
                    ["helpers"] = r.Body!.Get("helpers")?.DeepClone() ?? new JsonArray("wren"),
                    ["adds"] = r.Body!.Str("adds") ?? "auto",
                    ["review"] = r.Body!.Get("review")?.DeepClone() ?? new JsonObject { ["day"] = 1, ["time"] = "09:00" },
                    ["known_to_all"] = r.Body!.Bool("known_to_all") ?? false,
                };
            }
            return new JsonObject();
        });

        var store = new TasksStore(new TasksApi(rest));
        await store.RefreshAsync(force: true);

        // 1) Older add-on ignores team fields on POST -> teamLeft PATCHes them + known_to_all
        var made = await store.CreateGoalAsync(
            title: "Draw every day",
            why: "Build the habit",
            due: "2027-03-31",
            measure: new GoalMeasure("drawings", 0, 100, 0),
            lead: "otto",
            helpers: ["wren"],
            adds: "auto",
            review: new GoalReview(1, "09:00"),
            knownToAll: false);

        Assert.NotNull(made);
        Assert.Equal("otto", made!.Lead);
        Assert.Equal(["wren"], made.Helpers);
        Assert.Equal("auto", made.Adds);
        Assert.Equal(new GoalReview(1, "09:00"), made.Review);
        Assert.False(made.KnownToAll);

        var post = Assert.Single(rest.Log, r => r.Method == "POST").Body!;
        Assert.Equal("2027-03-31", post.Str("due"));
        Assert.Equal(100, post.Obj("measure")!.Num("target"));
        Assert.Equal("otto", post.Str("lead"));
        Assert.Equal("auto", post.Str("adds"));
        Assert.Equal(1, post.Obj("review")!.Int("day"));
        Assert.Null(post.Get("known_to_all")); // POST never takes known_to_all

        var patch = Assert.Single(rest.Log, r => r.Method == "PATCH").Body!;
        Assert.Equal(1, patch.Int("rev"));
        Assert.Equal("otto", patch.Str("lead"));
        Assert.Equal("auto", patch.Str("adds"));
        Assert.Equal(1, patch.Obj("review")!.Int("day"));
        Assert.False(patch.Bool("known_to_all"));

        // 2) Modern add-on accepts all createTeamKeys in one POST -> no PATCH needed when known_to_all is omitted
        olderAddOn = false;
        rest.Log.Clear();
        var singleWrite = await store.CreateGoalAsync(
            title: "Ship v2",
            lead: "otto",
            helpers: ["wren"],
            adds: "auto",
            review: new GoalReview(0, "08:00"));
        Assert.NotNull(singleWrite);
        Assert.Single(rest.Log, r => r.Method == "POST");
        Assert.DoesNotContain(rest.Log, r => r.Method == "PATCH");
    }
}
