using System.Text.Json.Nodes;
using Hermes.Core.Kanban;
using Hermes.Core.Net;
using Hermes.Core.Tasks;

namespace Hermes.Core.Tests.Tasks;

public class GoalsV2Tests
{
    private static readonly TimeZoneInfo Utc = TimeZoneInfo.Utc;
    private static readonly DateTimeOffset Now = new(2026, 11, 24, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void GoalModelReadsV2BotsStandsCheckinAndConflictResolution()
    {
        var json = new JsonObject
        {
            ["id"] = "g1",
            ["rev"] = 4,
            ["title"] = "1,000 beta testers",
            ["why"] = "Validate desktop workflows",
            ["status"] = "active",
            ["lead"] = "ivy",
            ["helpers"] = new JsonArray("herald", "otto"),
            ["adds"] = "auto",
            ["review"] = new JsonObject { ["day"] = 0, ["time"] = "08:00" },
            ["known_to_all"] = true,
            ["stands"] = new JsonObject { ["by"] = "ivy", ["at"] = "2026-11-24T08:00:00Z", ["text"] = "340 signed up", ["next"] = "Share release notes" },
            ["checkin"] = new JsonObject { ["at"] = "2026-11-23T08:00:00Z", ["offer"] = "of_c", ["state"] = "offered" },
            ["chat"] = new JsonObject { ["profile"] = "ivy", ["session_id"] = "g-chat-1" },
            ["offer"] = new JsonObject { ["kind"] = "done", ["what"] = "goal", ["by"] = "ivy", ["text"] = "Hit 1,000 testers!", ["kept"] = false },
            ["measure"] = new JsonObject
            {
                ["unit"] = "testers", ["start"] = 0, ["target"] = 1000, ["now"] = 340,
                ["source"] = new JsonObject { ["bot"] = "ivy", ["what"] = "TestFlight" },
                ["history"] = new JsonArray(new JsonObject { ["value"] = 300, ["at"] = "2026-11-17T00:00:00Z" }),
            },
        };

        var goal = Goal.From(json)!;
        Assert.Equal("ivy", goal.Lead);
        Assert.Equal(["ivy", "herald", "otto"], goal.Team);
        Assert.True(goal.HasBots);
        Assert.True(goal.KnownToAll);
        Assert.Equal(new GoalReview(0, "08:00"), goal.Review);
        Assert.Equal("340 signed up", goal.Stands!.Text);
        Assert.Equal("340 signed up", goal.Stands!.Summary);
        Assert.Equal("offered", goal.Checkin!.State);
        Assert.Equal("of_c", goal.Checkin!.Offer);
        Assert.Equal("g-chat-1", goal.Chat!.SessionId);
        Assert.Equal("goal", goal.Offer!.What);
        Assert.Equal("done", goal.Offer!.Kind);
        Assert.Equal("ivy", goal.Measure!.EffectiveSource.Bot);
        Assert.Equal("TestFlight", goal.Measure!.EffectiveSource.What);
        Assert.Single(goal.Measure!.History);

        // Disjoint 409 conflict merges cleanly; same-field conflict returns null
        var serverCurrent = GoalWire.Applying(new JsonObject { ["rev"] = 5, ["why"] = "Updated elsewhere" }, goal)!;
        Assert.Equal(5, GoalWire.Resolve(goal, serverCurrent, new JsonObject { ["title"] = "New title" }));
        Assert.Null(GoalWire.Resolve(goal, serverCurrent, new JsonObject { ["why"] = "My why" }));
    }

    [Fact]
    public void GoalStallDetects14DayInactivityAndResetsOnActivityOrKeptAt()
    {
        var old = new Goal("g-old") { Title = "Write handbook", CreatedAt = "2026-11-01T00:00:00Z", UpdatedAt = "2026-11-01T00:00:00Z" };
        Assert.True(GoalStall.IsStalled(old, [], Now));
        Assert.Contains("23 days", GoalStall.Message(old, [], Now));

        // KeptAt resets stall
        var kept = old with { KeptAt = "2026-11-20T00:00:00Z" };
        Assert.False(GoalStall.IsStalled(kept, [], Now));

        // Recent task activity resets stall
        var activeTask = new TodoTask("t1") { Goal = "g-old", UpdatedAt = "2026-11-22T00:00:00Z" };
        Assert.False(GoalStall.IsStalled(old, [activeTask], Now));

        // Paused goal never shows stall card
        Assert.False(GoalStall.IsStalled(old with { Status = "paused" }, [], Now));
    }

    [Fact]
    public void GoalOffersBotsAndTeamPickFormatSetupPlansAndPrompts()
    {
        var setupPlan = new GoalPlanSetup(
            name: "Ship Windows v2",
            why: "Feature parity",
            due: "2026-12-31",
            measure: new GoalOfferMeasure("features", 0, 10, 3));
        var offer = new TodoOffer("off-1")
        {
            Kind = "plan",
            Bot = "ivy",
            Summary = "Proposed milestones",
            Goal = "g1",
            Setup = setupPlan,
            Milestones = [new GoalOfferMilestone("Coding Pipeline"), new GoalOfferMilestone("Phone Calls")],
            Tasks = [new TodoOfferTask("Port diff comments")],
            BuiltOn = ["Existing Tasks layout", "Gateway add-on routes"],
        };

        Assert.Equal(2, GoalOffers.BuiltOnLines(offer).Count);
        var rows = GoalOffers.SetupRows(setupPlan, Now, Utc);
        Assert.Contains(rows, r => r.Label == "Name" && r.Value == "Ship Windows v2");
        Assert.Contains(rows, r => r.Label == "Number" && r.Value == "3 of 10 features");
        Assert.Equal([TodoOfferAction.Accept, TodoOfferAction.AcceptNoPlan], GoalOffers.Buttons(offer).Select(b => b.Action));
        Assert.Equal("Proposed by Ivy", GoalOffers.Foot(offer, _ => "Ivy"));

        var told = new GoalPlanTold();
        Assert.True(told.Remember("g1", "off-1"));
        Assert.False(told.Remember("g1", "off-1"));

        var guard = new GoalPlanGuard();
        Assert.True(guard.TryBegin("g1"));
        Assert.False(guard.TryBegin("g1"));
        guard.End("g1");
        Assert.True(guard.TryBegin("g1"));

        var g = new Goal("g1") { Title = "Ship Windows v2", Lead = "ivy", Helpers = ["herald"] };
        Assert.Equal("ivy", GoalBots.PickPlanner(g, ["default", "otto"]));
        Assert.Contains("Ship Windows v2", GoalBots.PlanRequest(g));
        Assert.Equal("Led by Ivy + 1", GoalTeamPick.Summary(g, id => id == "ivy" ? "Ivy" : "Herald"));

        var patch = GoalTeamPick.PatchFields("ivy", ["ivy", "herald", "herald"], "auto", knownToAll: true);
        Assert.Equal("ivy", patch.Str("lead"));
        Assert.Single(patch.Arr("helpers")!); // duplicate & lead filtered out
        Assert.Equal("auto", patch.Str("adds"));
    }

    [Fact]
    public async Task TasksStorePatchesMilestonesMeasuresConflictsAndDeletesGoals()
    {
        var rest = new FakeGoalV2Rest();
        var store = new TasksStore(new TasksApi(rest));

        await MainLoop.Drive(async () =>
        {
            await store.RefreshAsync(force: true);
            Assert.True(store.GoalBotsSupported);
            Assert.Single(store.Goals);

            // Disjoint 409 conflict on first patch retries automatically on rev 2
            rest.TriggerDisjointConflictOnce = true;
            Assert.True(await store.AddGoalMilestoneAsync("g1", "Beta launch"));
            var g = store.FindGoal("g1")!;
            Assert.Single(g.Milestones);
            var msId = g.Milestones[0].Id;

            Assert.True(await store.SetGoalMilestoneDoneAsync("g1", msId, true));
            Assert.True(store.FindGoal("g1")!.Milestones[0].Done);

            Assert.True(await store.UpdateGoalMeasureAsync("g1", new GoalMeasure("users", 0, 500, 120)));
            Assert.Equal(120, store.FindGoal("g1")!.Measure!.Now);

            Assert.True(await store.AnswerGoalLooksDoneAsync("g1", achieved: true));
            Assert.Equal(GoalState.Achieved, store.FindGoal("g1")!.State);

            Assert.True(await store.DeleteGoalAsync("g1"));
            Assert.Empty(store.Goals);
        });
    }

    private sealed class FakeGoalV2Rest : IPagesRest
    {
        public bool TriggerDisjointConflictOnce { get; set; }
        private JsonObject _goal = new()
        {
            ["id"] = "g1",
            ["rev"] = 1,
            ["title"] = "Grow testers",
            ["why"] = "Initial why",
            ["status"] = "active",
            ["milestones"] = new JsonArray(),
            ["offer"] = new JsonObject { ["kind"] = "done", ["what"] = "goal", ["by"] = "ivy", ["text"] = "Done!", ["kept"] = false },
        };

        public Task<JsonNode?> JsonAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query = null,
            JsonNode? body = null, TimeSpan? timeout = null, CancellationToken ct = default)
        {
            if (method == HttpMethod.Get && path.EndsWith("/tasks", StringComparison.Ordinal))
            {
                return Task.FromResult<JsonNode?>(new JsonObject
                {
                    ["rev"] = 1,
                    ["tasks"] = new JsonArray(),
                    ["sections"] = new JsonArray(),
                    ["goal_bots"] = true,
                    ["goals"] = new JsonArray((JsonNode)_goal.DeepClone()),
                });
            }
            if (method == HttpMethod.Patch && path.EndsWith("/goals/g1", StringComparison.Ordinal) && body is JsonObject fields)
            {
                if (TriggerDisjointConflictOnce)
                {
                    TriggerDisjointConflictOnce = false;
                    _goal["rev"] = 2;
                    _goal["why"] = "Edited on Mac";
                    throw new GatewayException("http", "conflict", 409, new JsonObject { ["goal"] = _goal.DeepClone() }.ToJsonString());
                }
                foreach (var (k, v) in fields)
                {
                    if (k == "rev") continue;
                    if (k == "offer_answer" && J.AsString(v) == "done")
                    {
                        _goal["status"] = "achieved";
                        _goal["offer"] = null;
                    }
                    else if (k == "keep" && fields.Bool("keep") == true)
                    {
                        _goal["kept_at"] = TodoDates.Now();
                    }
                    else
                    {
                        _goal[k] = v?.DeepClone();
                    }
                }
                _goal["rev"] = (int)(_goal.Int("rev") ?? 1) + 1;
                return Task.FromResult<JsonNode?>(_goal.DeepClone());
            }
            if (method == HttpMethod.Delete && path.EndsWith("/goals/g1", StringComparison.Ordinal))
                return Task.FromResult<JsonNode?>(new JsonObject { ["ok"] = true });

            return Task.FromResult<JsonNode?>(new JsonObject());
        }

        public Task<string> UploadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string contentType, string bodyFile,
            TimeSpan timeout, Action<long, long>? progress = null, CancellationToken ct = default) => Task.FromResult("{}");
        public Task DownloadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string file, long ceiling,
            CancellationToken ct = default) => Task.CompletedTask;
    }
}
