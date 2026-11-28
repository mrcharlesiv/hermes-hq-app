using System.Text.Json.Nodes;
using Hermes.Core.Coding;
using Hermes.Core.Composer;
using Hermes.Core.Insights;
using Hermes.Core.Kanban;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Sessions;

namespace Hermes.Core.Tests;

/// Wave 4D parity tests covering:
/// - 4-bucket `CodingPipelineBucket` classification (`3e7f6374a`, `1f3a49712`, `997919566`)
/// - 1-to-1 bucket counts and header toggles across `NeedsMeFirst`, `ByStatus`, and `Newest`
/// - Strict `https://github.com` `PRFacts.ValidCheckRunUrl`
/// - `"Ask <Bot> to Open PR"` primary action for bare branches (`number == null`)
/// - `chatWorking` merge confirm warning and per-failing-check `"Ask <Bot> to Fix"` helper
/// - `PRVerdict` formatting (`✓ +128 −12` / `✕ N checks failing` / `checks running`)
/// - `CodingStore.RepositoryFolderChoices` (`here`/`elsewhere`), `PublicRepoChoices`, `LinkOwnFolderIfUnlinkedAsync`, `PrAutoLinkFailed`
/// - `SessionRow` preserving `Cwd`/`Branch` and hidden tile chat filtering in `SessionListPipeline`
public sealed class CodingPipelineParityTests
{
    private static readonly DateTimeOffset BaseTime = new(2026, 11, 24, 12, 0, 0, TimeSpan.Zero);

    private static SessionSummary Row(
        string id,
        string profile = "otto",
        string cwd = "/Users/me/Projects/app",
        SessionStatus status = SessionStatus.Idle,
        bool running = false,
        bool unread = false,
        bool archived = false,
        bool pinned = false,
        SessionPRStatus? pr = null,
        string? title = null,
        string? preview = "preview",
        DateTimeOffset? lastActive = null) =>
        new()
        {
            Id = id,
            Profile = profile,
            Title = title ?? id,
            Preview = preview,
            Cwd = cwd,
            Status = status,
            IsRunning = running,
            Unread = unread,
            Archived = archived,
            Pinned = pinned,
            PullRequest = pr,
            LastActive = lastActive ?? BaseTime,
        };

    [Fact]
    public void CodingPipelineBucketLabelsAndDefaultsMatchSwift()
    {
        Assert.Equal("Ready", CodingPipelineBucket.Ready.Label());
        Assert.Equal("Ready to Ship", CodingPipelineBucket.Ready.SectionTitle());
        Assert.False(CodingPipelineBucket.Ready.CollapsedByDefault());

        Assert.Equal("Needs You", CodingPipelineBucket.NeedsYou.Label());
        Assert.Equal("Needs You", CodingPipelineBucket.NeedsYou.SectionTitle());
        Assert.False(CodingPipelineBucket.NeedsYou.CollapsedByDefault());

        Assert.Equal("Active", CodingPipelineBucket.InFlight.Label());
        Assert.Equal("Active", CodingPipelineBucket.InFlight.SectionTitle());
        Assert.False(CodingPipelineBucket.InFlight.CollapsedByDefault());

        Assert.Equal("Shipped", CodingPipelineBucket.Shipped.Label());
        Assert.Equal("Shipped", CodingPipelineBucket.Shipped.SectionTitle());
        Assert.True(CodingPipelineBucket.Shipped.CollapsedByDefault());
    }

    [Fact]
    public void BucketClassifiesEveryCodingStateOneToOneWithSwift()
    {
        var readyPR = new SessionPRStatus(SessionPRState.Open, Number: 10, Checks: new(SessionPRCheckState.Passed, 6, 0, 0, []));
        var readyNoCI = new SessionPRStatus(SessionPRState.Open, Number: 11);
        var failingPR = new SessionPRStatus(SessionPRState.Open, Number: 12, Checks: new(SessionPRCheckState.Failed, 2, 1, 0, []));
        var runningPR = new SessionPRStatus(SessionPRState.Open, Number: 13, Checks: new(SessionPRCheckState.Running, 2, 0, 1, []));
        var draftPR = new SessionPRStatus(SessionPRState.Draft, Number: 14);
        var mergedPR = new SessionPRStatus(SessionPRState.Merged, Number: 15);
        var closedPR = new SessionPRStatus(SessionPRState.Closed, Number: 16);
        var unmatched = new SessionPRStatus(SessionPRState.Unknown, SessionPRUnknownReason.Unmatched);

        // Ready to Ship
        Assert.Equal(CodingPipelineBucket.Ready, CodingPipeline.BucketFor(Row("ready", pr: readyPR)));
        Assert.Equal(CodingPipelineBucket.Ready, CodingPipeline.BucketFor(Row("ready-noci", pr: readyNoCI)));
        Assert.True(CodingPipeline.IsReadyToMerge(Row("ready", pr: readyPR)));

        // Needs You: needsInput, failing CI, or unread && !working (even when an earlier PR merged or closed)
        Assert.Equal(CodingPipelineBucket.NeedsYou, CodingPipeline.BucketFor(Row("ask", status: SessionStatus.NeedsInput, pr: readyPR)));
        Assert.Equal(CodingPipelineBucket.NeedsYou, CodingPipeline.BucketFor(Row("fail", pr: failingPR)));
        Assert.True(CodingPipeline.HasFailingChecks(Row("fail", pr: failingPR)));
        Assert.Equal(CodingPipelineBucket.NeedsYou, CodingPipeline.BucketFor(Row("unread-draft", unread: true, pr: draftPR)));
        Assert.Equal(CodingPipelineBucket.NeedsYou, CodingPipeline.BucketFor(Row("unread-merged", unread: true, pr: mergedPR)));
        Assert.Equal(CodingPipelineBucket.NeedsYou, CodingPipeline.BucketFor(Row("unread-closed", unread: true, pr: closedPR)));

        // Active (InFlight): working bot (even on open/merged PR or unread), running checks, quiet draft, bare/plain chat
        Assert.Equal(CodingPipelineBucket.InFlight, CodingPipeline.BucketFor(Row("working-open", running: true, pr: readyPR)));
        Assert.Equal(CodingPipelineBucket.InFlight, CodingPipeline.BucketFor(Row("working-merged", running: true, pr: mergedPR)));
        Assert.Equal(CodingPipelineBucket.InFlight, CodingPipeline.BucketFor(Row("working-unread", running: true, unread: true, pr: draftPR)));
        Assert.Equal(CodingPipelineBucket.InFlight, CodingPipeline.BucketFor(Row("running-ci", pr: runningPR)));
        Assert.Equal(CodingPipelineBucket.InFlight, CodingPipeline.BucketFor(Row("draft", pr: draftPR)));
        Assert.Equal(CodingPipelineBucket.InFlight, CodingPipeline.BucketFor(Row("unmatched", pr: unmatched)));
        Assert.Equal(CodingPipelineBucket.InFlight, CodingPipeline.BucketFor(Row("plain", pr: null)));

        // Shipped: quiet merged/closed or archived (even unread archived stays Shipped)
        Assert.Equal(CodingPipelineBucket.Shipped, CodingPipeline.BucketFor(Row("merged", pr: mergedPR)));
        Assert.Equal(CodingPipelineBucket.Shipped, CodingPipeline.BucketFor(Row("closed", pr: closedPR)));
        Assert.Equal(CodingPipelineBucket.Shipped, CodingPipeline.BucketFor(Row("archived", archived: true, pr: readyPR)));
        Assert.Equal(CodingPipelineBucket.Shipped, CodingPipeline.BucketFor(Row("archived-unread", unread: true, archived: true, pr: mergedPR)));
    }

    [Fact]
    public void PipelineHeaderTogglesMatchCountsOneToOneAcrossAllSorts()
    {
        var projects = new Dictionary<string, List<SessionProject>>
        {
            ["otto"] = [new SessionProject("app", "App", "/app", ["/app"])],
        };
        var entries = new List<SessionProjectEntry> { new("/app", "App") };

        var live = new List<SessionSummary>
        {
            Row("r1", cwd: "/app", pr: new SessionPRStatus(SessionPRState.Open, Number: 538, Checks: new(SessionPRCheckState.Passed, 6, 0, 0, [])), lastActive: BaseTime.AddMinutes(5)),
            Row("n1", cwd: "/app", pr: new SessionPRStatus(SessionPRState.Open, Number: 535, Checks: new(SessionPRCheckState.Failed, 1, 2, 0, [])), lastActive: BaseTime.AddMinutes(4)),
            Row("f1", cwd: "/app", running: true, pr: new SessionPRStatus(SessionPRState.Draft, Number: 541), lastActive: BaseTime.AddMinutes(3)),
            Row("c1", cwd: "/app", pr: new SessionPRStatus(SessionPRState.Unknown, SessionPRUnknownReason.Unmatched), lastActive: BaseTime.AddMinutes(2)),
            Row("s1", cwd: "/app", pr: new SessionPRStatus(SessionPRState.Merged, Number: 532), lastActive: BaseTime.AddMinutes(1)),
        };
        var archived = new List<SessionSummary>
        {
            Row("s2", cwd: "/app", archived: true, pr: new SessionPRStatus(SessionPRState.Merged, Number: 500), lastActive: BaseTime),
        };
        var all = live.Concat(archived).ToList();

        var counts = CodingPipelineEngine.ComputeBucketCounts(all, null);
        Assert.Equal(1, counts[CodingPipelineBucket.Ready]);
        Assert.Equal(1, counts[CodingPipelineBucket.NeedsYou]);
        Assert.Equal(2, counts[CodingPipelineBucket.InFlight]);
        Assert.Equal(2, counts[CodingPipelineBucket.Shipped]);

        // CodingPipelineEngine.BuildBucketSections honors SelectedBucket across NeedsMeFirst, ByStatus, and Newest
        foreach (var sort in new[] { ProjectPageSort.NeedsMeFirst, ProjectPageSort.ByStatus, ProjectPageSort.Newest })
        {
            if (sort != ProjectPageSort.Newest)
            {
                var unfiltered = CodingPipelineEngine.BuildBucketSections(all, null, sort, new CodingPipelineFilter());
                Assert.Equal(["Ready to Ship", "Needs You", "Active", "Shipped"], unfiltered.Select(s => s.Title));
                Assert.True(unfiltered.Last().CollapsedByDefault);
            }
            foreach (var bucket in CodingPipeline.AllBuckets)
            {
                var filtered = CodingPipelineEngine.BuildBucketSections(all, null, sort, new CodingPipelineFilter { SelectedBucket = bucket });
                var displayed = filtered.SelectMany(s => s.Rows).ToList();
                Assert.Equal(counts[bucket], displayed.Count);
                Assert.All(filtered, s => Assert.False(s.CollapsedByDefault));
            }
        }

        // SessionListPipeline.ProjectPage also aligns 1-to-1 across NeedsMeFirst, ByStatus, and Newest
        var prefs = new SessionsViewPrefs { GroupBy = SessionGroupBy.Project, ProjectFilter = ["/app"] };
        var baseInput = new SessionListInput
        {
            Live = live,
            Archived = archived,
            Prefs = prefs,
            ProjectsByProfile = projects,
            Projects = entries,
            CodingProjects = new HashSet<string> { "/app" },
        };

        var groups = SessionListPipeline.Groups(baseInput);
        Assert.Equal(["Ready to Ship", "Needs You", "Active", "Shipped"], groups.Skip(1).Select(g => g.Title));
        var shipped = groups.First(g => g.Title == "Shipped");
        Assert.True(shipped.Collapsed);
        Assert.Equal(2, shipped.Total);
        Assert.Empty(shipped.Sessions);

        foreach (var bucket in CodingPipeline.AllBuckets)
        {
            var byStatus = SessionListPipeline.Groups(new SessionListInput
            {
                Live = live,
                Archived = archived,
                Prefs = prefs,
                ProjectsByProfile = projects,
                Projects = entries,
                CodingProjects = new HashSet<string> { "/app" },
                ProjectsByStatus = new HashSet<string> { "/app" },
                ProjectPipelineBucket = bucket,
            });
            Assert.Equal(counts[bucket], byStatus.Skip(1).SelectMany(g => g.Sessions).Count());

            var byNewest = SessionListPipeline.Groups(new SessionListInput
            {
                Live = live,
                Archived = archived,
                Prefs = prefs,
                ProjectsByProfile = projects,
                Projects = entries,
                CodingProjects = new HashSet<string> { "/app" },
                ProjectsByNewest = new HashSet<string> { "/app" },
                ProjectPipelineBucket = bucket,
            });
            Assert.Equal(counts[bucket], byNewest.Skip(1).SelectMany(g => g.Sessions).Count());
        }
    }

    [Theory]
    [InlineData("https://github.com/acme/widget/actions/runs/12345", true)]
    [InlineData("https://github.com/acme/widget/runs/999", true)]
    [InlineData("https://circleci.com/gh/acme/widget/42", false)]
    [InlineData("https://evil.github.com/acme/widget/runs/1", false)]
    [InlineData("https://github.com.evil.example/acme/widget/runs/1", false)]
    [InlineData("http://github.com/acme/widget/actions/runs/1", false)]
    [InlineData("https://user:pass@github.com/acme/widget/runs/1", false)]
    [InlineData("https://github.com:8443/acme/widget/runs/1", false)]
    [InlineData("https://github.com/", false)]
    [InlineData("javascript:alert(1)", false)]
    public void ValidCheckRunUrlRestrictsStrictlyToHttpsGithubCom(string url, bool expected)
    {
        Assert.Equal(expected, PRFacts.ValidCheckRunUrl(url) != null);
    }

    [Fact]
    public void BareBranchShowsAskBotToOpenPRAsPinnedPrimaryAction()
    {
        var session = Row("b1", profile: "otto", title: "Draft auth work");
        var bareBranch = new SessionPRStatus(
            SessionPRState.Draft,
            Repo: "acme/widget",
            Branch: "feat/oauth-pkce",
            Number: null,
            Base: "main");

        var card = PullRequestCardModel.Build(session, bareBranch, botName: "Otto");
        Assert.Equal("Branch", card.SheetTitle);
        var openAction = Assert.Single(card.Actions, a => a.Kind == PullRequestQuickAction.AskBotToOpenPR);
        Assert.Equal("Ask Otto to Open PR", openAction.Label);
        Assert.True(openAction.Primary);
        Assert.Contains("feat/oauth-pkce", openAction.BotPrompt);
        Assert.Contains("main", openAction.BotPrompt);
        Assert.NotNull(card.PinnedPrimaryAction);
        Assert.Equal(PullRequestQuickAction.AskBotToOpenPR, card.PinnedPrimaryAction!.Kind);
    }

    [Fact]
    public void MergeConfirmTitleWarnsWhenChatWorkingOrDraftOrFailing()
    {
        var passing = new SessionPRChecks(SessionPRCheckState.Passed, 3, 0, 0, []);
        var failing = new SessionPRChecks(SessionPRCheckState.Failed, 1, 2, 0, []);

        Assert.Equal("Ask Otto to Merge",
            PullRequestCardModel.MergeConfirmTitle(SessionPRState.Open, 42, passing, "Otto", chatWorking: false));
        Assert.Equal("Otto Is Still Working — Merge?",
            PullRequestCardModel.MergeConfirmTitle(SessionPRState.Open, 42, passing, "Otto", chatWorking: true));
        Assert.Equal("Checks Are Failing — Merge Anyway?",
            PullRequestCardModel.MergeConfirmTitle(SessionPRState.Open, 42, failing, "Otto", chatWorking: true));
        Assert.Equal("Merge Draft Pull Request?",
            PullRequestCardModel.MergeConfirmTitle(SessionPRState.Draft, 42, passing, "Otto", chatWorking: false));
        Assert.Equal("Merge Unopened Branch?",
            PullRequestCardModel.MergeConfirmTitle(SessionPRState.Draft, null, null, "Otto", chatWorking: false));

        var workingSession = Row("w1", profile: "otto", running: true, status: SessionStatus.Working);
        var openPR = new SessionPRStatus(SessionPRState.Open, Number: 42, Checks: passing);
        var card = PullRequestCardModel.Build(workingSession, openPR, botName: "Otto");
        Assert.True(card.ChatWorking);
        Assert.Equal("Otto Is Still Working — Merge?", card.MergeConfirmTitle());
        var mergeAction = Assert.Single(card.Actions, a => a.Kind == PullRequestQuickAction.Merge);
        Assert.Equal("Otto Is Still Working — Merge?", mergeAction.ConfirmationTitle);
        Assert.True(mergeAction.Destructive);
    }

    [Fact]
    public void PerFailingCheckHelperFormatsLabelAndTargetedPrompt()
    {
        var run = new SessionPRCheckRun("windows-compile-check", SessionPRCheckState.Failed, Summary: "CS0246 missing type");
        Assert.Equal("Ask Ivy to Fix", PullRequestCardModel.FixSingleCheckTitle("Ivy"));

        var prompt = PullRequestCardModel.FixSingleCheckPrompt(77, run);
        Assert.Contains("windows-compile-check", prompt);
        Assert.Contains("pull request #77", prompt);
        Assert.Contains("CS0246 missing type", prompt);

        var branchPrompt = PullRequestCardModel.FixSingleCheckPrompt(null, new SessionPRCheckRun("lint", SessionPRCheckState.Failed));
        Assert.Contains("this branch", branchPrompt);
        Assert.Contains("lint", branchPrompt);
    }

    [Fact]
    public void PRVerdictDisplayTextMatchesMacFormatting()
    {
        var size = new SessionPRSize(4, 128, 12);
        var passedWithSize = PRVerdict.From(new SessionPRChecks(SessionPRCheckState.Passed, 5, 0, 0, []), size)!;
        Assert.Equal("\u2713 +128 \u221212", passedWithSize.DisplayText);

        var passedNoSize = PRVerdict.From(new SessionPRChecks(SessionPRCheckState.Passed, 2, 0, 0, []), null)!;
        Assert.Equal("\u2713", passedNoSize.DisplayText);

        var failingTwo = PRVerdict.From(new SessionPRChecks(SessionPRCheckState.Failed, 1, 2, 0, []), size)!;
        Assert.Equal("\u2715 2 checks failing", failingTwo.DisplayText);

        var running = PRVerdict.From(new SessionPRChecks(SessionPRCheckState.Running, 1, 0, 1, []), size)!;
        Assert.Equal("checks running", running.DisplayText);

        // Merged / manually closed PRs yield null from ForActiveRow
        Assert.Null(PRVerdict.ForActiveRow(new SessionPRStatus(SessionPRState.Merged, Size: size)));
        Assert.Null(PRVerdict.ForActiveRow(new SessionPRStatus(SessionPRState.Open, Manual: true, Size: size)));
        Assert.NotNull(PRVerdict.ForActiveRow(new SessionPRStatus(SessionPRState.Open, Size: size)));
    }

    [Fact]
    public async Task RepositoryChoicesAndAutoLinkWorkAndTrackPrAutoLinkFailed()
    {
        var rest = new FakeCodingRest();
        var store = new CodingStore(new CodingApi(rest), new MemoryKv());

        // Populate projects and gateway repos + PR statuses
        var projectsByProfile = new Dictionary<string, List<SessionProject>>
        {
            ["otto"] =
            [
                new SessionProject("app", "App", "/Users/me/Projects/app", ["/Users/me/Projects/app", "/Users/me/Projects/app/sub"]),
                new SessionProject("docs", "Docs", "/Users/me/Projects/docs", ["/Users/me/Projects/docs"]),
            ],
        };
        rest.OnRequest = (method, path, _) =>
        {
            if (method == HttpMethod.Get && path.EndsWith("/pr-repos", StringComparison.Ordinal))
            {
                return new JsonObject
                {
                    ["repos"] = new JsonArray(
                        new JsonObject { ["project"] = "/Users/me/Projects/other", ["path"] = "/Users/me/Projects/zeta", ["public_repo"] = "acme/zeta" }),
                };
            }
            if (method == HttpMethod.Put && path.EndsWith("/pr-repos", StringComparison.Ordinal))
                throw new GatewayException("http", "not a repo", 422, """{"error":"not_a_repository"}""");
            return new JsonObject();
        };

        await store.RefreshReposAsync();
        store.PutStatus("otto:s1", new SessionPRStatus(SessionPRState.Open, Repo: "acme/app", Number: 10));
        store.PutStatus("otto:s2", new SessionPRStatus(SessionPRState.Draft, Repo: "ACME/APP", Number: 11,
            Items: [new SessionPRItem(SessionPRSource.GitHub, SessionPRState.Open, "acme/shared", "feat/x", 12, null)]));

        var choices = store.RepositoryFolderChoices("/Users/me/Projects/app", projectsByProfile);
        Assert.Equal(["/Users/me/Projects/app", "/Users/me/Projects/app/sub"], choices.Here);
        Assert.Equal(["/Users/me/Projects/docs", "/Users/me/Projects/zeta"], choices.Elsewhere);

        var pubChoices = store.PublicRepoChoices();
        Assert.Equal(["acme/app", "acme/shared", "acme/zeta"], pubChoices);

        // Auto-link requires CodingProject = true and records PrAutoLinkFailed on not_a_repository
        Assert.False(await store.LinkOwnFolderIfUnlinkedAsync("/Users/me/Projects/notes"));
        Assert.False(store.HasAutoLinkFailed("/Users/me/Projects/notes"));

        store.SaveSettings(new ProjectSettings("/Users/me/Projects/notes") { CodingProject = true });
        Assert.False(await store.LinkOwnFolderIfUnlinkedAsync("/Users/me/Projects/notes"));
        Assert.True(store.HasAutoLinkFailed("/Users/me/Projects/notes"));

        // Manual link clears PrAutoLinkFailed
        rest.OnRequest = (method, path, body) => new JsonObject { ["repo"] = body?.DeepClone() };
        await store.LinkRepoAsync(new SessionPRRepo("/Users/me/Projects/notes", "/Users/me/Projects/real-git"));
        Assert.False(store.HasAutoLinkFailed("/Users/me/Projects/notes"));
        Assert.Equal("/Users/me/Projects/real-git", store.RepoFor("/Users/me/Projects/notes")?.Path);
    }

    [Fact]
    public void SessionRowPreservesCwdAndBranchWithoutBreakingPositionalConstructor()
    {
        // Legacy 11-arg positional construction still compiles
        var legacy = new SessionRow("s1", "Title", "Preview", "otto", "desktop", BaseTime, 3, false, false, false, "gpt-5");
        Assert.Null(legacy.Cwd);
        Assert.Null(legacy.Branch);

        var decoded = SessionRow.From(JsonNode.Parse("""
            {"id":"s2","title":"Fix","profile":"otto","cwd":"/Users/me/Projects/app","git_branch":"feat/calm-pipeline"}
            """));
        Assert.NotNull(decoded);
        Assert.Equal("/Users/me/Projects/app", decoded!.Cwd);
        Assert.Equal("feat/calm-pipeline", decoded.Branch);
    }

    [Fact]
    public void SessionListPipelineFiltersHiddenTileChatsEverywhere()
    {
        const string rememberedId = "tile-remembered-4d-test";
        TileChats.RememberSession(rememberedId);
        try
        {
            var realChat = Row("chat-1", title: "Ship Wave 4D", preview: "Reviewing PR #42", unread: true);
            var tileByTitle = Row("chat-2", title: "Make me a live tile for my Hermes HQ Dashboard", preview: "Make me a live tile for my Hermes HQ Dashboard", unread: true);
            var tileByDisplayTitle = Row("chat-3", title: "New tile: Build Status", preview: "Working on tile", running: true, status: SessionStatus.Working);
            var tileByPreview = Row("chat-4", title: "Dashboard Widget", preview: "Change my Hermes HQ Dashboard tile to show CI", unread: true);
            var tileBySessionId = Row(rememberedId, title: "Background refresh", preview: "Updated JSON", unread: true);

            var input = new SessionListInput
            {
                Live = [realChat, tileByTitle, tileByDisplayTitle, tileByPreview, tileBySessionId],
                Prefs = new SessionsViewPrefs { GroupBy = SessionGroupBy.Date },
            };

            var listedIds = SessionListPipeline.Groups(input).SelectMany(g => g.Sessions).Select(s => s.Id).ToList();
            Assert.Equal(["chat-1"], listedIds);

            var chipCounts = SessionListPipeline.ChipCounts(input);
            Assert.Equal(1, chipCounts[SessionStatusChip.New]);
            Assert.Equal(0, chipCounts[SessionStatusChip.Working]);

            var stateCounts = SessionListPipeline.StateCounts(input);
            Assert.Equal((0, 1, 0), stateCounts);
        }
        finally
        {
            TileChats.ForgetSession(rememberedId);
        }
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
        public Func<HttpMethod, string, JsonNode?, JsonNode?>? OnRequest { get; set; }

        public Task<JsonNode?> JsonAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query = null,
            JsonNode? body = null, TimeSpan? timeout = null, CancellationToken ct = default) =>
            Task.FromResult(OnRequest?.Invoke(method, path, body));

        public Task<string> UploadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string contentType, string bodyFile,
            TimeSpan timeout, Action<long, long>? progress = null, CancellationToken ct = default) => Task.FromResult("{}");

        public Task DownloadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string file, long ceiling,
            CancellationToken ct = default) => Task.CompletedTask;
    }
}
