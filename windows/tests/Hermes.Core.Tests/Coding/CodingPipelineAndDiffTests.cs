using System.Text.Json.Nodes;
using Hermes.Core.Coding;
using Hermes.Core.Composer;
using Hermes.Core.Kanban;
using Hermes.Core.Net;
using Hermes.Core.Sessions;

namespace Hermes.Core.Tests.Coding;

public class CodingPipelineAndDiffTests
{
    private static SessionSummary MakeSession(string id, string profile, DateTimeOffset lastActive,
        SessionStatus status = SessionStatus.Idle, bool running = false, bool unread = false, bool pinned = false, string? branch = null) =>
        new()
        {
            Id = id,
            Profile = profile,
            Title = "Task " + id,
            LastActive = lastActive,
            Status = status,
            IsRunning = running,
            Unread = unread,
            Pinned = pinned,
            Branch = branch,
        };

    [Fact]
    public void PipelineClassifiesAllCalmShippingStagesAndHonorsToggles()
    {
        var t0 = new DateTimeOffset(2026, 11, 24, 12, 0, 0, TimeSpan.Zero);
        var sReady = MakeSession("ready", "otto", t0.AddMinutes(1), branch: "feat/ready");
        var sFail = MakeSession("fail", "otto", t0.AddMinutes(2), branch: "fix/ci");
        var sReview = MakeSession("review", "ivy", t0.AddMinutes(3), branch: "feat/review");
        var sRunning = MakeSession("run", "ivy", t0.AddMinutes(4), branch: "feat/run");
        var sDraft = MakeSession("draft", "herald", t0.AddMinutes(5), branch: "wip/draft");
        var sMerged = MakeSession("merged", "otto", t0.AddMinutes(6), branch: "feat/done");
        var sClosed = MakeSession("closed", "otto", t0.AddMinutes(7), branch: "feat/old");

        var prs = new Dictionary<string, SessionPRStatus>
        {
            [sReady.Key] = new(SessionPRState.Open, Number: 10, Checks: new(SessionPRCheckState.Passed, 3, 0, 0, []), ReviewVerdict: PRReviewVerdict.Approved),
            [sFail.Key] = new(SessionPRState.Open, Number: 11, Checks: new(SessionPRCheckState.Failed, 1, 1, 0, [])),
            [sReview.Key] = new(SessionPRState.Open, Number: 12, Checks: new(SessionPRCheckState.Passed, 2, 0, 0, []), ReviewVerdict: PRReviewVerdict.ReviewRequired),
            [sRunning.Key] = new(SessionPRState.Open, Number: 13, Checks: new(SessionPRCheckState.Running, 1, 0, 1, [])),
            [sDraft.Key] = new(SessionPRState.Draft, Number: 14),
            [sMerged.Key] = new(SessionPRState.Merged, Number: 15),
            [sClosed.Key] = new(SessionPRState.Closed, Number: 16),
        };
        var all = new[] { sReady, sFail, sReview, sRunning, sDraft, sMerged, sClosed };

        // Default filter: ShowDrafts=true, ShowMerged=false, ShowClosed=false
        var byStatus = CodingPipelineEngine.BuildSections(all, prs, ProjectPageSort.ByStatus, new CodingPipelineFilter());
        Assert.Equal([
            CodingPipelineStage.NeedsAttention,
            CodingPipelineStage.ReadyToMerge,
            CodingPipelineStage.InReview,
            CodingPipelineStage.ChecksRunning,
            CodingPipelineStage.Draft,
        ], byStatus.Select(s => s.Stage!.Value));

        // Toggles: hide drafts, show merged, filter by bot "otto"
        var filtered = CodingPipelineEngine.BuildSections(all, prs, ProjectPageSort.ByStatus, new CodingPipelineFilter
        {
            ShowDrafts = false,
            ShowMerged = true,
            ShowClosed = false,
            FilterByBot = "otto",
        });
        Assert.Equal([CodingPipelineStage.NeedsAttention, CodingPipelineStage.ReadyToMerge, CodingPipelineStage.Merged],
            filtered.Select(s => s.Stage!.Value));

        // Newest sort respects the exact same toggles
        var newest = CodingPipelineEngine.BuildSections(all, prs, ProjectPageSort.Newest, new CodingPipelineFilter
        {
            ShowDrafts = false,
            ShowMerged = true,
            ShowClosed = false,
            FilterByBot = "otto",
        });
        var single = Assert.Single(newest);
        Assert.Equal(["merged", "fail", "ready"], single.Rows.Select(r => r.Session.Id));

        // Counts reflect full picture
        var counts = CodingPipelineEngine.ComputeCounts(all, prs);
        Assert.Equal(7, counts.Total);
        Assert.Equal(1, counts.ReadyToMerge);
        Assert.Equal(1, counts.NeedsAttention);
        Assert.Equal(1, counts.Merged);
        Assert.Equal(1, counts.Closed);
    }

    [Fact]
    public void DiffParserParsesHunksAndTracksOldAndNewLineNumbers()
    {
        const string patch =
            "@@ -10,3 +10,4 @@ public void Run()\n" +
            " var a = 1;\n" +
            "-var b = 2;\n" +
            "+var b = 3;\n" +
            "+var c = 4;\n" +
            " return;\n" +
            "@@ -40 +41 @@\n" +
            "-oldLine\n" +
            "+newLine";

        var parsed = DiffParser.Parse("src/Demo.cs", patch);
        Assert.Equal(2, parsed.Hunks.Count);
        Assert.Equal(3, parsed.Additions);
        Assert.Equal(2, parsed.Deletions);

        var h1 = parsed.Hunks[0];
        Assert.Equal(10, h1.OldStart);
        Assert.Equal(10, h1.NewStart);
        Assert.Equal(DiffLineKind.HunkHeader, h1.Lines[0].Kind);
        Assert.Equal((10, 10), (h1.Lines[1].OldLine, h1.Lines[1].NewLine));
        Assert.Equal((11, (int?)null), (h1.Lines[2].OldLine, h1.Lines[2].NewLine));
        Assert.Equal(DiffLineSide.Old, h1.Lines[2].AnchorSide);
        Assert.Equal(((int?)null, 11), (h1.Lines[3].OldLine, h1.Lines[3].NewLine));
        Assert.Equal(DiffLineSide.New, h1.Lines[3].AnchorSide);
        Assert.Equal(((int?)null, 12), (h1.Lines[4].OldLine, h1.Lines[4].NewLine));
        Assert.Equal((12, 13), (h1.Lines[5].OldLine, h1.Lines[5].NewLine));
    }

    [Fact]
    public void DiffCommentStorePersistsAndFormatsStructuredReview()
    {
        var kv = new MemoryKv();
        var store = new DiffCommentStore(kv, "diff.s1");
        var c1 = store.Add("src/Demo.cs", DiffLineSide.New, 11, "Use const here.")!;
        var c2 = store.Add("src/Demo.cs", DiffLineSide.Old, 11, "Why remove this?")!;
        Assert.Equal(2, store.OpenCount);

        Assert.True(store.Edit(c1.Id, "Prefer readonly here."));
        Assert.True(store.SetResolved(c2.Id, true));
        Assert.Equal(1, store.OpenCount);
        Assert.Equal(1, store.CountsByFile(openOnly: true)["src/Demo.cs"]);

        var review = store.FormatReviewMessage("PR #42", "Looks close!");
        Assert.Contains("PR #42", review);
        Assert.Contains("Looks close!", review);
        Assert.Contains("src/Demo.cs", review);
        Assert.Contains("Line 11", review);
        Assert.Contains("Prefer readonly here.", review);
        Assert.DoesNotContain("Why remove this?", review);

        // Reloads from kv store
        var reloaded = new DiffCommentStore(kv, "diff.s1");
        Assert.Equal(2, reloaded.All.Count);
        Assert.Equal(1, reloaded.OpenCount);
    }

    [Theory]
    [InlineData("acme/widget", "acme/widget")]
    [InlineData("https://github.com/acme/widget.git", "acme/widget")]
    [InlineData("https://github.com/acme/widget/pulls", "acme/widget")]
    [InlineData("git@github.com:acme/widget.git", "acme/widget")]
    [InlineData("not-a-repo", null)]
    [InlineData("", null)]
    public void RepoPathHelpersNormalizesPublicRepoSlugs(string input, string? expected)
    {
        Assert.Equal(expected, RepoPathHelpers.NormalizePublicRepo(input));
    }

    [Fact]
    public async Task CodingStoreFetchesStatusesLinksReposAndClassifiesErrors()
    {
        var rest = new FakeCodingRest();
        var store = new CodingStore(new CodingApi(rest), new MemoryKv());

        rest.NextResponse = new JsonObject
        {
            ["statuses"] = new JsonObject
            {
                ["otto:s1"] = new JsonObject { ["state"] = "open", ["number"] = 99, ["branch"] = "feat/x" },
            },
        };
        await store.RefreshPRStatusAsync([("otto", "s1")], fresh: true, detail: true);
        Assert.Equal(99, store.StatusFor("otto:s1")?.Number);

        // Error classification on not_a_repository
        rest.NextError = new GatewayException("http", "bad", 400, """{"error":"not_a_repository"}""");
        var ex = await Assert.ThrowsAsync<SessionPRRepoException>(() =>
            store.LinkRepoAsync(new SessionPRRepo("proj1", "/tmp/not-a-repo")));
        Assert.Equal(SessionPRRepoErrorKind.NotARepository, ex.Kind);

        // Settings persistence
        var saved = new ProjectSettings("proj1") { CodingProject = true, Notify = ProjectNotifyMode.NeedsMe };
        store.SaveSettings(saved);
        Assert.Equal(ProjectNotifyMode.NeedsMe, store.SettingsFor("proj1").Notify);
    }

    private sealed class MemoryKv : IKeyValueStore
    {
        private readonly Dictionary<string, string> _data = [];
        public string? Get(string key) => _data.TryGetValue(key, out var v) ? v : null;
        public void Set(string key, string? value)
        {
            if (value == null) _data.Remove(key); else _data[key] = value;
        }
    }

    private sealed class FakeCodingRest : IPagesRest
    {
        public JsonNode? NextResponse { get; set; }
        public Exception? NextError { get; set; }

        public Task<JsonNode?> JsonAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query = null,
            JsonNode? body = null, TimeSpan? timeout = null, CancellationToken ct = default)
        {
            if (NextError is { } err) { NextError = null; throw err; }
            return Task.FromResult(NextResponse);
        }

        public Task<string> UploadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string contentType, string bodyFile,
            TimeSpan timeout, Action<long, long>? progress = null, CancellationToken ct = default) => Task.FromResult("{}");

        public Task DownloadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string file, long ceiling,
            CancellationToken ct = default) => Task.CompletedTask;
    }
}
