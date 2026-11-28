using System.Text.Json.Nodes;
using Hermes.Core.Heads;
using Hermes.Core.Kanban;
using Hermes.Core.Net;
using Hermes.Core.Rpc;

namespace Hermes.Core.Tests;

/// Wave 5D parity tests: Kanban Board Rename & Delete (`fe3104ec2`) and Smooth Animated Bot Faces
/// (`1f31817d5`, `0e852c6f1`: `BotMoods`, `FaceLoop.SoftSamples` C³ spring & exact periodic closure,
/// `FaceJelly` 0.82 damping, and `MatrixAct` 60fps elastic + glint frame generation).
public sealed class KanbanAndAnimatedFacesParityTests
{
    private sealed class FakeRest : IPagesRest
    {
        public List<(HttpMethod Method, string Path, JsonNode? Body)> Calls { get; } = [];
        public Func<HttpMethod, string, JsonNode?, Task<JsonNode?>> Handler { get; set; } = (_, _, _) => Task.FromResult<JsonNode?>(new JsonObject());

        public Task<JsonNode?> JsonAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query = null,
            JsonNode? body = null, TimeSpan? timeout = null, CancellationToken ct = default)
        {
            Calls.Add((method, path, body?.DeepClone()));
            return Handler(method, path, body);
        }

        public Task<string> UploadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string contentType,
            string bodyFile, TimeSpan timeout, Action<long, long>? progress = null, CancellationToken ct = default) =>
            Task.FromResult("{}");

        public Task DownloadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string file, long ceiling,
            CancellationToken ct = default) => Task.CompletedTask;
    }

    private static JsonObject BoardsJson(string current, params (string Slug, string Name, int Total)[] boards)
    {
        var arr = new JsonArray();
        foreach (var (slug, name, total) in boards)
            arr.Add(new JsonObject { ["slug"] = slug, ["name"] = name, ["total"] = total });
        return new JsonObject { ["current"] = current, ["boards"] = arr };
    }

    private static JsonObject EmptyBoardJson() => new() { ["columns"] = new JsonArray() };

    // ---------------------------------------------------------------- Kanban Board Rename & Delete

    [Fact]
    public void CanDeleteBoardProtectsDefaultAndEmptyAndFormatsDeleteMessage()
    {
        Assert.False(KanbanModel.CanDeleteBoard("default"));
        Assert.False(KanbanModel.CanDeleteBoard(""));
        Assert.True(KanbanModel.CanDeleteBoard("ops"));
        Assert.True(KanbanModel.CanDeleteBoard("sprint-1"));

        Assert.Contains("It has no tasks.", KanbanModel.DeleteBoardMessage("Ops", 0));
        Assert.Contains("It has no tasks.", KanbanModel.DeleteBoardMessage("Ops", null));
        Assert.Contains("Its 1 task goes with it.", KanbanModel.DeleteBoardMessage("Ops", 1));
        Assert.Contains("Its 4 tasks go with it.", KanbanModel.DeleteBoardMessage("Ops", 4));
    }

    [Fact]
    public async Task KanbanApiRenameAndDeleteSendExactRoutesAndPayload()
    {
        var rest = new FakeRest();
        var api = new KanbanApi(rest);

        await api.RenameBoardAsync("team/ops", "  Platform Ops  ");
        await api.DeleteBoardAsync("team/ops");

        Assert.Equal(2, rest.Calls.Count);
        Assert.Equal(HttpMethod.Patch, rest.Calls[0].Method);
        Assert.Equal("/api/plugins/kanban/boards/team%2Fops", rest.Calls[0].Path);
        Assert.Equal("Platform Ops", rest.Calls[0].Body.Str("name"));
        Assert.Equal(HttpMethod.Delete, rest.Calls[1].Method);
        Assert.Equal("/api/plugins/kanban/boards/team%2Fops", rest.Calls[1].Path);
    }

    [Fact]
    public async Task KanbanStoreRenameBoardOptimisticallyUpdatesAndRollsBackOnError()
    {
        var gate = new TaskCompletionSource<JsonNode?>();
        var boards = BoardsJson("default", ("default", "Default Board", 2), ("ops", "Ops", 3));
        var rest = new FakeRest
        {
            Handler = (method, path, _) =>
            {
                if (method == HttpMethod.Get && path == "/api/plugins/kanban/boards")
                    return Task.FromResult<JsonNode?>(boards.DeepClone());
                if (method == HttpMethod.Patch && path == "/api/plugins/kanban/boards/ops")
                    return gate.Task;
                return Task.FromResult<JsonNode?>(EmptyBoardJson());
            },
        };
        var store = new KanbanStore(new KanbanApi(rest), "acct-1");
        await store.ReadBoardsAsync();

        var task = store.RenameBoardAsync("ops", "Operations");
        // Optimistic rename is visible before PATCH completes.
        Assert.Equal("Operations", store.Boards!.Boards.First(b => b.Slug == "ops").Name);

        // Failing PATCH rolls back to the previous title and returns the gateway error.
        gate.SetException(new GatewayException("http", "500", 500, """{"detail":"Disk full"}"""));
        var error = await task;
        Assert.Equal("Disk full", error);
        Assert.Equal("Ops", store.Boards!.Boards.First(b => b.Slug == "ops").Name);

        // Read-only gateway refuses before hitting REST.
        store.ReadOnlyGateway = true;
        var beforeCount = rest.Calls.Count;
        Assert.Equal(KanbanRest.ReadOnlyNotice, await store.RenameBoardAsync("ops", "Blocked"));
        Assert.Equal(beforeCount, rest.Calls.Count);
    }

    [Fact]
    public async Task KanbanStoreDeleteBoardGuardsDefaultRollsBackAndSwitchesActiveBoard()
    {
        var rest = new FakeRest();
        var serverBoards = BoardsJson("default", ("default", "Default Board", 2), ("ops", "Ops", 3), ("qa", "QA", 1));
        var failNextDelete = false;
        rest.Handler = (method, path, _) =>
        {
            if (method == HttpMethod.Get && path == "/api/plugins/kanban/boards")
                return Task.FromResult<JsonNode?>(serverBoards.DeepClone());
            if (method == HttpMethod.Delete && path == "/api/plugins/kanban/boards/ops")
            {
                if (failNextDelete)
                    throw new GatewayException("http", "500", 500, """{"detail":"Locked"}""");
                serverBoards = BoardsJson("default", ("default", "Default Board", 2), ("qa", "QA", 1));
                return Task.FromResult<JsonNode?>(new JsonObject());
            }
            return Task.FromResult<JsonNode?>(EmptyBoardJson());
        };

        var store = new KanbanStore(new KanbanApi(rest), "acct-2");
        await store.ReadBoardsAsync();

        // Default board cannot be deleted.
        var defaultGuard = await store.DeleteBoardAsync("default");
        Assert.Equal(KanbanModel.DefaultBoardKept, defaultGuard);
        Assert.DoesNotContain(rest.Calls, c => c.Method == HttpMethod.Delete);

        // Switch to "ops" so it is the active board, then test rollback on failure.
        store.Select("ops");
        Assert.Equal("ops", store.BoardKey);
        failNextDelete = true;
        var err = await store.DeleteBoardAsync("ops");
        Assert.Equal("Locked", err);
        Assert.Contains(store.Boards!.Boards, b => b.Slug == "ops");
        Assert.Equal("ops", store.BoardKey);

        // Successful delete removes "ops" and switches active board away to "default".
        failNextDelete = false;
        var ok = await store.DeleteBoardAsync("ops");
        Assert.Null(ok);
        Assert.DoesNotContain(store.Boards!.Boards, b => b.Slug == "ops");
        Assert.Equal("default", store.BoardKey);
    }

    [Fact]
    public async Task KanbanStoreDeleteActiveBoardFallsBackToFirstRemainingWhenNoDefault()
    {
        var serverBoards = BoardsJson("alpha", ("alpha", "Alpha", 1), ("beta", "Beta", 2));
        var rest = new FakeRest
        {
            Handler = (method, path, _) =>
            {
                if (method == HttpMethod.Get && path == "/api/plugins/kanban/boards")
                    return Task.FromResult<JsonNode?>(serverBoards.DeepClone());
                if (method == HttpMethod.Delete && path == "/api/plugins/kanban/boards/beta")
                {
                    serverBoards = BoardsJson("alpha", ("alpha", "Alpha", 1));
                    return Task.FromResult<JsonNode?>(new JsonObject());
                }
                return Task.FromResult<JsonNode?>(EmptyBoardJson());
            },
        };
        var store = new KanbanStore(new KanbanApi(rest), "acct-3");
        await store.ReadBoardsAsync();
        store.Select("beta");
        Assert.Equal("beta", store.BoardKey);

        Assert.Null(await store.DeleteBoardAsync("beta"));
        Assert.Equal("alpha", store.BoardKey);
    }

    // ---------------------------------------------------------------- BotMoods

    [Fact]
    public void BotMoodsDefinesAllTwelveMoodsAndMapsToolsAccurately()
    {
        var all = Enum.GetValues<BotMood>();
        Assert.Equal(12, all.Length);
        Assert.True(BotMood.Done.IsOnce());
        Assert.True(BotMood.Failed.IsOnce());
        Assert.Equal(2.4, BotMood.Done.Length());
        Assert.Equal(1.9, BotMood.Failed.Length());
        Assert.False(BotMood.Thinking.IsOnce());

        Assert.Null(BotMoods.FromTool(null));
        Assert.Null(BotMoods.FromTool("   "));
        Assert.Equal(BotMood.Running, BotMoods.FromTool("terminal"));
        Assert.Equal(BotMood.Reading, BotMoods.FromTool("functions.read_file"));
        Assert.Equal(BotMood.Searching, BotMoods.FromTool("web_search"));
        Assert.Equal(BotMood.Writing, BotMoods.FromTool("patch"));
        Assert.Equal(BotMood.Messaging, BotMoods.FromTool("delegate_task"));
        Assert.Equal(BotMood.Making, BotMoods.FromTool("image_generate"));
        Assert.Equal(BotMood.Asking, BotMoods.FromTool("clarify"));
        Assert.Equal(BotMood.Browsing, BotMoods.FromTool("browser_click"));
        Assert.Equal(BotMood.Browsing, BotMoods.FromTool("computer_use_type"));
        Assert.Equal(BotMood.Messaging, BotMoods.FromTool("GMAIL_SEND_EMAIL"));
        Assert.Equal(BotMood.Searching, BotMoods.FromTool("notion_search_pages"));
        Assert.Equal(BotMood.Running, BotMoods.FromTool("custom_opaque_tool"));
    }

    [Fact]
    public void BotMoodsHonorsDwellAskingPrecedenceOnceExpiryAndReplay()
    {
        var now = 100.0;
        var moods = new BotMoods { Clock = () => now, UsesTimers = false };
        var notifications = new List<string>();
        moods.Changed += p => notifications.Add(p);

        moods.Started("otto");
        Assert.Equal(BotMood.Thinking, moods.MoodFor("otto"));

        // Thinking yields immediately to an explicit tool mood.
        moods.Handle(new RpcEvent("tool.start", "s1", new JsonObject { ["name"] = "read_file" }, 1), "otto");
        Assert.Equal(BotMood.Reading, moods.MoodFor("otto"));

        // Another tool arriving within Dwell (2.2s) is held until Dwell elapses.
        now += 0.5;
        moods.Handle(new RpcEvent("tool.start", "s1", new JsonObject { ["name"] = "write_file" }, 2), "otto");
        Assert.Equal(BotMood.Reading, moods.MoodFor("otto"));

        now += 2.0;
        moods.Tick("otto");
        Assert.Equal(BotMood.Writing, moods.MoodFor("otto"));

        // Asking overrides active mood until cleared.
        moods.SetAsking("otto", true);
        Assert.Equal(BotMood.Asking, moods.MoodFor("otto"));
        Assert.Null(moods.Since("otto"));
        moods.SetAsking("otto", false);
        Assert.Equal(BotMood.Writing, moods.MoodFor("otto"));

        // Turn completion plays Done once; Settle does not interrupt once-only moods; Tick after 2.4s clears it.
        moods.HandleEvent("message.complete", "otto", status: "ok");
        Assert.Equal(BotMood.Done, moods.MoodFor("otto"));
        moods.Settle("otto");
        Assert.Equal(BotMood.Done, moods.MoodFor("otto"));
        now += 2.5;
        moods.Tick("otto");
        Assert.Null(moods.MoodFor("otto"));

        // Replayed start events are ignored; replayed endings clear any active mood quietly.
        moods.HandleEvent("tool.start", "otto", toolName: "terminal", replayed: true);
        Assert.Null(moods.MoodFor("otto"));
        moods.Show(BotMood.Running, "otto");
        moods.HandleEvent("message.complete", "otto", replayed: true);
        Assert.Null(moods.MoodFor("otto"));
        Assert.NotEmpty(notifications);
    }

    // ---------------------------------------------------------------- FaceMotion & FaceJelly

    [Fact]
    public void FaceBodyShortestAngleAndQuinticAreSmoothAndExact()
    {
        Assert.Equal(0.0, FaceBody.ShortestAngleDelta(360, 0), 9);
        Assert.Equal(0.0, FaceBody.ShortestAngleDelta(-360, 0), 9);
        Assert.Equal(-20.0, FaceBody.ShortestAngleDelta(10, 350), 9);
        Assert.Equal(20.0, FaceBody.ShortestAngleDelta(350, 10), 9);

        var spun = new FaceBody(Roll: 360, Turn: -360, Tip: 0);
        var mid = spun.MixedShortest(FaceBody.Rest, 0.5);
        Assert.Equal(360.0, mid.Roll, 9);
        Assert.Equal(-360.0, mid.Turn, 9);

        Assert.Equal(0.0, FaceBody.Quintic(0.0), 12);
        Assert.Equal(0.5, FaceBody.Quintic(0.5), 12);
        Assert.Equal(1.0, FaceBody.Quintic(1.0), 12);
    }

    [Fact]
    public void FaceLoopSoftSamplesCloseExactlyAndStayFiniteAndSmoothForAllMoods()
    {
        foreach (var mood in Enum.GetValues<BotMood>())
        {
            var loop = new FaceLoop(mood, facing: 1, seed: 42 + (int)mood);
            var once = mood.IsOnce();
            var soft = loop.SoftSamples(once, rate: 60);

            Assert.True(soft.Count > 20, $"{mood} should produce dense 60Hz samples");
            Assert.Equal(0.0, soft[0].At, 9);
            Assert.Equal(loop.Period, soft[^1].At, 9);

            foreach (var s in soft)
            {
                Assert.True(double.IsFinite(s.Body.X) && double.IsFinite(s.Body.Y)
                    && double.IsFinite(s.Body.Roll) && double.IsFinite(s.Body.Turn)
                    && double.IsFinite(s.Body.Tip) && double.IsFinite(s.Body.Squash),
                    $"{mood} body must be finite");
                Assert.True(double.IsFinite(s.Eyes.X) && double.IsFinite(s.Eyes.Y)
                    && double.IsFinite(s.Eyes.Lids) && double.IsFinite(s.Eyes.Wide)
                    && double.IsFinite(s.Eyes.Tilt),
                    $"{mood} eyes must be finite");
            }

            if (!once)
            {
                // Exact periodic closure at t = 0 and t = Period (modulo 360° wraps on angles).
                var first = soft[0];
                var last = soft[^1];
                Assert.Equal(first.Body.X, last.Body.X, 12);
                Assert.Equal(first.Body.Y, last.Body.Y, 12);
                Assert.Equal(first.Body.Squash, last.Body.Squash, 12);
                Assert.Equal(0.0, FaceBody.ShortestAngleDelta(first.Body.Roll, last.Body.Roll), 9);
                Assert.Equal(0.0, FaceBody.ShortestAngleDelta(first.Body.Turn, last.Body.Turn), 9);
                Assert.Equal(0.0, FaceBody.ShortestAngleDelta(first.Body.Tip, last.Body.Tip), 9);
                Assert.Equal(first.Eyes.X, last.Eyes.X, 12);
                Assert.Equal(first.Eyes.Y, last.Eyes.Y, 12);
                Assert.Equal(first.Eyes.Wide, last.Eyes.Wide, 12);
                Assert.Equal(first.Eyes.Tilt, last.Eyes.Tilt, 12);
            }
            else
            {
                // Once-only moods settle cleanly back to rest (modulo 360° for cartwheel/pirouette).
                var last = soft[^1];
                Assert.Equal(0.0, last.Body.X, 9);
                Assert.Equal(0.0, last.Body.Y, 9);
                Assert.Equal(0.0, last.Body.Squash, 9);
                Assert.Equal(0.0, FaceBody.ShortestAngleDelta(0.0, last.Body.Roll), 9);
                Assert.Equal(0.0, FaceBody.ShortestAngleDelta(0.0, last.Body.Turn), 9);
                Assert.Equal(0.0, FaceBody.ShortestAngleDelta(0.0, last.Body.Tip), 9);
                Assert.Equal(0.0, last.Eyes.Lids, 9);
            }

            // C³ smoothness: bounded 1st, 2nd, and 3rd finite differences on filtered body Y & Roll.
            var maxD1 = 0.0;
            var maxD2 = 0.0;
            var maxD3 = 0.0;
            for (var i = 3; i < soft.Count; i++)
            {
                var d1 = Math.Abs(soft[i].Body.Y - soft[i - 1].Body.Y);
                var d2 = Math.Abs(soft[i].Body.Y - 2 * soft[i - 1].Body.Y + soft[i - 2].Body.Y);
                var d3 = Math.Abs(soft[i].Body.Y - 3 * soft[i - 1].Body.Y + 3 * soft[i - 2].Body.Y - soft[i - 3].Body.Y);
                if (d1 > maxD1) maxD1 = d1;
                if (d2 > maxD2) maxD2 = d2;
                if (d3 > maxD3) maxD3 = d3;
            }
            Assert.True(maxD1 < 0.05, $"{mood} 1st diff too large: {maxD1}");
            Assert.True(maxD2 < 0.01, $"{mood} 2nd diff too large: {maxD2}");
            Assert.True(maxD3 < 0.005, $"{mood} 3rd diff too large: {maxD3}");
        }
    }

    [Fact]
    public void FaceJellyDampingStaysBoundedClosesLoopsAndFadesOnceMoods()
    {
        Assert.Equal(0.82, FaceJelly.Damping);

        var loop = new FaceLoop(BotMood.Running, facing: 1, seed: 7);
        var samples = loop.SoftSamples(once: false, rate: 60);
        var jelly = FaceJelly.Follow(samples, loop.Period, once: false);

        Assert.Equal(samples.Count, jelly.Count);
        Assert.Equal(jelly[0], jelly[^1]);
        Assert.Contains(jelly, j => Math.Abs(j.Squash) > 0.005 || Math.Abs(j.Lean) > 0.005);
        foreach (var j in jelly)
        {
            Assert.True(double.IsFinite(j.Squash) && Math.Abs(j.Squash) <= 0.200001);
            Assert.True(double.IsFinite(j.Lean) && Math.Abs(j.Lean) <= 0.140001);
        }

        // Once-only mood settles smoothly to zero wobble at end.
        var doneLoop = new FaceLoop(BotMood.Done, facing: 1, seed: 11);
        var doneSamples = doneLoop.SoftSamples(once: true, rate: 60);
        var doneJelly = FaceJelly.Follow(doneSamples, doneLoop.Period, once: true);
        Assert.Equal(0.0, doneJelly[^1].Squash, 12);
        Assert.Equal(0.0, doneJelly[^1].Lean, 12);
    }

    // ---------------------------------------------------------------- MatrixActs

    [Fact]
    public void MatrixActCoversAllTwelveMoodsAndGenerates60FpsElasticGlintFrames()
    {
        var head = Head.DefaultHead("otto") with { Theme = HeadTheme.Matrix };
        var design = MatrixDesign.Of(head);
        var effects = new HashSet<MatrixActEffect>();

        foreach (var mood in Enum.GetValues<BotMood>())
        {
            var act = MatrixAct.Make(mood, design);
            Assert.NotNull(act.Effect);
            effects.Add(act.Effect!.Value);
            Assert.Equal(mood == BotMood.Thinking, act.RimOnly);

            var loop = new FaceLoop(mood, design.Facing, seed: 100 + (int)mood);
            var frames = act.SampleFrames(loop, rate: 60);
            Assert.True(frames.Count > 20);
            foreach (var f in frames)
            {
                Assert.InRange(f.Glint.StartX, 0.12, 0.88);
                Assert.InRange(f.Glint.StartY, 0.10, 0.78);
                Assert.True(Math.Abs(f.Elastic.Squash) <= 0.20 * MatrixAct.ElasticSquashScale + 1e-6);
                Assert.True(Math.Abs(f.Elastic.Lean) <= 0.14 * MatrixAct.ElasticLeanScale + 1e-6);
            }
            if (!act.Once)
            {
                Assert.Equal(frames[0].Pose, frames[^1].Pose);
                Assert.Equal(frames[0].Elastic, frames[^1].Elastic);
                Assert.Equal(frames[0].Glint, frames[^1].Glint);
            }
        }
        Assert.Equal(12, effects.Count);

        // Failed starts with the 7-step glitch sequence.
        var failedAct = MatrixAct.Make(BotMood.Failed, design);
        var failedLoop = new FaceLoop(BotMood.Failed, design.Facing, seed: 3);
        var discrete = failedAct.Frames(failedLoop);
        Assert.True(discrete.Count >= MatrixAct.Glitches.Length);
        for (var i = 0; i < MatrixAct.Glitches.Length; i++)
        {
            Assert.Equal(MatrixAct.Glitches[i], discrete[i].Pose.Glitch);
            Assert.Equal(2, discrete[i].Pose.Lids);
        }

        // Helpers: typing lines, rain streaks, sparkle cells avoid face cells, and SVG renders wide/glitch poses.
        var lines = MatrixAct.TypingLines(design);
        Assert.NotEmpty(lines);
        var rain = MatrixAct.RainStreaks(seed: 19, streaks: 13);
        Assert.Equal(13, rain.Count);
        var faceCells = failedAct.FaceCells(design);
        var sparkles = MatrixAct.SparkleCells(design, faceCells, seed: 19, count: 5);
        Assert.Equal(5, sparkles.Count);
        Assert.All(sparkles, c => Assert.DoesNotContain(c, faceCells));

        var wideSvg = MatrixActSvg.Svg(head, 48, dark: true, new MatrixActPose(Wide: true));
        var glitchSvg = MatrixActSvg.Svg(head, 48, dark: false, new MatrixActPose(Lids: 2, Glitch: 2));
        Assert.StartsWith("<svg", wideSvg);
        Assert.StartsWith("<svg", glitchSvg);
        Assert.EndsWith("</svg>", wideSvg);
        Assert.EndsWith("</svg>", glitchSvg);
    }
}
