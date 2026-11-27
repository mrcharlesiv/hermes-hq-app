using System.Text.Json.Nodes;
using Hermes.Core.Coding;
using Hermes.Core.Sessions;

namespace Hermes.Core.Tests.Coding;

public class PullRequestFactsAndCardTests
{
    private static SessionSummary SampleSession(string id = "s1", string profile = "otto", string title = "Fix widget parser") =>
        new() { Id = id, Profile = profile, Title = title, Branch = "feat/widget" };

    [Fact]
    public void ParseStatusDecodesFullDetailAndEnforcesLimits()
    {
        var longTitle = new string('A', PRFacts.TitleLimit + 50);
        var longPatch = new string('x', PRFacts.PatchLimit + 500);
        var json = new JsonObject
        {
            ["state"] = "open",
            ["repo"] = "acme/widget",
            ["branch"] = "feat/widget",
            ["base"] = "main",
            ["number"] = 42,
            ["url"] = "https://github.com/acme/widget/pull/42",
            ["title"] = longTitle,
            ["review_decision"] = "changes_requested",
            ["comments"] = 5,
            ["size"] = new JsonObject { ["files"] = 3, ["additions"] = 128, ["deletions"] = 12 },
            ["checks"] = new JsonObject
            {
                ["state"] = "failed",
                ["passed"] = 4,
                ["failed"] = 2,
                ["running"] = 0,
                ["runs"] = new JsonArray(
                    new JsonObject { ["name"] = "Unit Tests", ["state"] = "failed", ["url"] = "https://github.com/acme/widget/actions/runs/1" },
                    new JsonObject { ["name"] = "Lint", ["state"] = "passed", ["url"] = "http://insecure.example.com/bad" }),
            },
            ["files"] = new JsonArray(
                new JsonObject { ["path"] = "src/App.cs", ["additions"] = 20, ["deletions"] = 4, ["patch"] = longPatch },
                new JsonObject { ["path"] = "assets/logo.png", ["additions"] = 0, ["deletions"] = 0, ["binary"] = true, ["patch"] = "ignored" }),
        };

        var status = SessionPRStatus.From(json);
        Assert.Equal(SessionPRState.Open, status.State);
        Assert.Equal(42, status.Number);
        Assert.Equal("https://github.com/acme/widget/pull/42", status.Url);
        Assert.Equal(PRFacts.TitleLimit, status.Title!.Length);
        Assert.Equal(PRReviewVerdict.ChangesRequested, status.ReviewVerdict);
        Assert.Equal(5, status.CommentsCount);
        Assert.Equal("+128 \u221212", status.Size!.FormattedDelta);
        Assert.Equal(2, status.Checks!.Runs.Count);
        Assert.NotNull(status.Checks.Runs[0].Url);
        Assert.Null(status.Checks.Runs[1].Url); // non-HTTPS rejected
        Assert.Equal(2, status.AllFiles.Count);
        Assert.True(status.AllFiles[0].PatchCut);
        Assert.Equal(PRFacts.PatchLimit, status.AllFiles[0].Patch!.Length);
        Assert.True(status.AllFiles[1].Binary);
        Assert.Null(status.AllFiles[1].Patch);
    }

    [Theory]
    [InlineData("https://github.com/acme/widget/pull/7", true)]
    [InlineData("https://github.com/acme/widget/commit/abc123", true)]
    [InlineData("http://github.com/acme/widget/pull/7", false)]
    [InlineData("https://evil.example.com/acme/widget/pull/7", false)]
    [InlineData("javascript:alert(1)", false)]
    [InlineData("https://github.com/acme/widget", false)]
    public void ValidGitHubPullUrlRejectsUnsafeOrMalformedLinks(string url, bool expectedValid)
    {
        Assert.Equal(expectedValid, PRFacts.ValidGitHubPullUrl(url) != null);
    }

    [Fact]
    public void PRVerdictFormatsPassedFailingRunningAndSizeOnly()
    {
        var size = new SessionPRSize(2, 40, 8);
        var passed = PRVerdict.From(new SessionPRChecks(SessionPRCheckState.Passed, 3, 0, 0, []), size);
        Assert.IsType<PRVerdict.Passed>(passed);
        Assert.Equal("+40 \u22128", passed!.Words);
        Assert.Equal(PRVerdictTone.Positive, passed.Tone);

        var fail1 = PRVerdict.From(new SessionPRChecks(SessionPRCheckState.Failed, 2, 1, 0, []), size);
        Assert.Equal("1 check failing", fail1!.Words);
        Assert.Equal(PRVerdictTone.Critical, fail1.Tone);

        var fail3 = PRVerdict.From(new SessionPRChecks(SessionPRCheckState.Failed, 0, 3, 0, []), size);
        Assert.Equal("3 checks failing", fail3!.Words);

        var running = PRVerdict.From(new SessionPRChecks(SessionPRCheckState.Running, 1, 0, 2, []), size);
        Assert.Equal("checks running", running!.Words);
        Assert.Equal(PRVerdictTone.Active, running.Tone);

        var sizeOnly = PRVerdict.From(null, size);
        Assert.IsType<PRVerdict.SizeOnly>(sizeOnly);
        Assert.Equal("+40 \u22128", sizeOnly!.Words);
    }

    [Fact]
    public void PullRequestCardBuildsRiskAwareActionsAndSiblingItems()
    {
        var runs = new[] { new SessionPRCheckRun("build-windows", SessionPRCheckState.Failed) };
        var checks = new SessionPRChecks(SessionPRCheckState.Failed, 1, 1, 0, runs);
        var sibling = new SessionPRItem(SessionPRSource.GitHub, SessionPRState.Draft, "acme/widget", "feat/docs", 43,
            "https://github.com/acme/widget/pull/43", Title: "Update docs");
        var lead = new SessionPRItem(SessionPRSource.GitHub, SessionPRState.Open, "acme/widget", "feat/widget", 42,
            "https://github.com/acme/widget/pull/42", new SessionPRSize(5, 90, 10), checks, PRReviewVerdict.ChangesRequested, 3,
            "Fix parser", "main", [new SessionPRFile("src/Parser.cs", 90, 10, false, "@@ -1 +1 @@\n+ok")]);

        var status = new SessionPRStatus(SessionPRState.Open, Repo: "acme/widget", Branch: "feat/widget", Number: 42,
            Url: "https://github.com/acme/widget/pull/42", Items: [lead, sibling], Size: lead.Size, Checks: checks,
            ReviewVerdict: PRReviewVerdict.ChangesRequested, CommentsCount: 3, Title: "Fix parser", Base: "main", Files: lead.Files);

        var now = new DateTimeOffset(2026, 11, 24, 15, 0, 0, TimeSpan.Zero);
        var card = PullRequestCardModel.Build(
            SampleSession(), status, new PullRequestCardFocus.Lead(),
            new Dictionary<string, int> { ["src/Parser.cs"] = 2 },
            refreshedAt: now.AddMinutes(-5), now: now);

        Assert.Equal("#42 · Open", card.BadgeLabel);
        Assert.Equal("feat/widget \u2192 main", card.BranchRoute);
        Assert.Equal("4 more files on GitHub", card.MoreFilesWords);
        Assert.Equal("Updated 5m ago", card.RefreshedText);
        Assert.Equal(2, card.Files[0].CommentCount);
        Assert.Single(card.Others);
        Assert.Equal("#43", card.Others[0].Label);

        // Failing checks make AskBotToFixCI primary and Merge destructive ("Merge Anyway…")
        var fixCi = Assert.Single(card.Actions, a => a.Kind == PullRequestQuickAction.AskBotToFixCI);
        Assert.True(fixCi.Primary);
        Assert.Contains("build-windows", fixCi.BotPrompt);

        var merge = Assert.Single(card.Actions, a => a.Kind == PullRequestQuickAction.Merge);
        Assert.Equal("Merge Anyway…", merge.Label);
        Assert.True(merge.Destructive);
        Assert.Contains("Failing Checks", merge.ConfirmationTitle);

        Assert.Contains(card.Actions, a => a.Kind == PullRequestQuickAction.Approve);
        Assert.Contains(card.Actions, a => a.Kind == PullRequestQuickAction.RequestChanges);
        Assert.Contains(card.Actions, a => a.Kind == PullRequestQuickAction.AskBotToFixReview);
        Assert.Contains(card.Actions, a => a.Kind == PullRequestQuickAction.Checkout);
        Assert.Contains(card.Actions, a => a.Kind == PullRequestQuickAction.OpenInBrowser);

        // Switching focus to sibling PR #43 updates state & removes #43 from Others
        var focused = PullRequestCardModel.Build(SampleSession(), status, new PullRequestCardFocus.Item(1));
        Assert.Equal(SessionPRState.Draft, focused.State);
        Assert.Equal(43, focused.Number);
        Assert.Single(focused.Others);
        Assert.Equal("#42", focused.Others[0].Label);
    }
}
