using Hermes.Core.Artifacts;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// An HTML page's live Preview (ArtifactTextViewController.swift `showPreviewChild`, HTMLPageSheet.swift `reveal` at
/// 93f984bb1; Hermes.Core/Artifacts/PagePreview.cs). Windows run 45034520666's file-windows walk shot index.html's
/// window with its bar and a blank body after 10 s (the view had called itself ready when it was made), then the page
/// opened again replaced that body, the window closed, and the first view's late start touched a web view that had
/// closed: "page preview failed: NullReferenceException". These replay that order and the cases around it, with no
/// WinUI: late work of a view that's gone is dropped; a still-live view that can't draw says so; nothing is ready
/// until the page drew.
public class PagePreviewTests
{
    [Fact]
    public void TheCiRunsCloseAndReopenDropsTheFirstViewsLateWorkInsteadOfFailing()
    {
        // index.html's window opens: its first view comes on screen and starts.
        var first = new PagePreviewLife();
        var start = first.OnScreen();
        Assert.Equal(new PagePreviewDecision(PagePreviewStep.Start, 1), start);
        Assert.False(first.IsReady);   // a drawn bar over a page still loading is not ready
        Assert.Equal(PagePreviewPhase.Loading, first.Phase);

        // The page opened again: the window keeps, its body is the page just made (ArtifactFileWindow.ShowContent).
        first.Close();
        var second = new PagePreviewLife();
        Assert.Equal(PagePreviewStep.Start, second.OnScreen().Step);

        // Ctrl+W: the window closes, and the second view with it.
        second.Close();

        // Then the first view's web view comes back, closed with its window (CoreWebView2 null): before, Guard read
        // CoreWebView2 and threw. Now it's late work, dropped, not a failure.
        var late = first.WebReady(start.Attempt, webAlive: false);
        Assert.Equal(PagePreviewStep.Drop, late.Step);
        Assert.Equal(PagePreviewStep.Drop, first.Threw(start.Attempt, nameof(NullReferenceException)).Step);
        Assert.Equal(PagePreviewStep.Drop, second.NavigationDone(1, success: true, null).Step);
        Assert.Equal(PagePreviewPhase.Closed, first.Phase);
        Assert.Null(first.Reason);
        // Nothing comes back to life after its window closed.
        Assert.Equal(PagePreviewStep.None, first.OnScreen().Step);
        Assert.Equal(PagePreviewStep.None, first.Retry().Step);
        Assert.Equal(PagePreviewStep.None, first.TimedOut(start.Attempt).Step);
    }

    [Fact]
    public void AStillLiveViewWhoseWebViewClosedOrThrewSaysSoInsteadOfABlank()
    {
        var life = new PagePreviewLife();
        var a = life.OnScreen().Attempt;
        var d = life.WebReady(a, webAlive: false);
        Assert.Equal(new PagePreviewDecision(PagePreviewStep.Fail, a, PagePreviewWords.ViewerClosed), d);
        Assert.Equal(PagePreviewPhase.Failed, life.Phase);
        Assert.False(life.IsReady);

        var other = new PagePreviewLife();
        var b = other.OnScreen().Attempt;
        Assert.Equal(new PagePreviewDecision(PagePreviewStep.Fail, b, PagePreviewWords.ViewerFailed),
            other.Threw(b, nameof(InvalidOperationException)));
    }

    [Fact]
    public void ReadyOnlyOnceThePageDrew()
    {
        var life = new PagePreviewLife();
        var a = life.OnScreen().Attempt;
        Assert.Equal(PagePreviewStep.Navigate, life.WebReady(a, webAlive: true).Step);
        Assert.False(life.IsReady);
        Assert.Equal(PagePreviewStep.Show, life.NavigationDone(a, success: true, "Unknown").Step);
        Assert.True(life.IsReady);
        Assert.Equal(PagePreviewPhase.Shown, life.Phase);
    }

    [Fact]
    public void APageThatNeverDrawsFailsAtTheLimitNotABlankForever()
    {
        Assert.Equal(TimeSpan.FromSeconds(30), PagePreviewLife.DrawLimit);
        var life = new PagePreviewLife();
        var a = life.OnScreen().Attempt;
        life.WebReady(a, webAlive: true);
        Assert.Equal(new PagePreviewDecision(PagePreviewStep.Fail, a, PagePreviewWords.DidntDraw), life.TimedOut(a));
        // A navigation finishing after the limit doesn't turn the failure into a blank "ready".
        Assert.Equal(PagePreviewStep.None, life.NavigationDone(a, success: true, null).Step);
        Assert.False(life.IsReady);

        // Drawn in time: the limit passing later changes nothing.
        var drawn = new PagePreviewLife();
        var b = drawn.OnScreen().Attempt;
        drawn.NavigationDone(b, success: true, null);
        Assert.Equal(PagePreviewStep.None, drawn.TimedOut(b).Step);
        Assert.True(drawn.IsReady);
    }

    [Fact]
    public void AColdWebViewStartHasItsOwnLimitAndTheDrawLimitRunsFromWhenItIsReady()
    {
        // CI run 45114288543: the run's first page window's web view was ready after 37 s and drew 0.1 s later; the
        // 30 s draw limit, then counted from the view's start, had already failed it.
        Assert.Equal(TimeSpan.FromSeconds(90), PagePreviewLife.StartLimit);
        Assert.Equal(PagePreviewLife.StartLimit + PagePreviewLife.DrawLimit, PagePreviewLife.SettleLimit);
        var life = new PagePreviewLife();
        var a = life.OnScreen().Attempt;
        // The draw limit passing while the web view is still starting is not a failure.
        Assert.Equal(PagePreviewStep.None, life.TimedOut(a).Step);
        Assert.Equal(PagePreviewPhase.Loading, life.Phase);
        Assert.Equal(PagePreviewStep.Navigate, life.WebReady(a, webAlive: true).Step);
        // Ready: the start limit no longer counts; the page draws.
        Assert.Equal(PagePreviewStep.None, life.StartTimedOut(a).Step);
        Assert.Equal(PagePreviewStep.Show, life.NavigationDone(a, success: true, null).Step);
        Assert.True(life.IsReady);

        // A web view that never starts fails at the start limit, in the same words, and Try Again starts over.
        var never = new PagePreviewLife();
        var b = never.OnScreen().Attempt;
        Assert.Equal(new PagePreviewDecision(PagePreviewStep.Fail, b, PagePreviewWords.DidntDraw), never.StartTimedOut(b));
        Assert.Equal(PagePreviewStep.Drop, never.WebReady(b + 1, webAlive: true).Step);
        Assert.Equal(PagePreviewStep.None, never.WebReady(b, webAlive: true).Step);   // late, after the failure: no navigate
        var retry = never.Retry();
        Assert.Equal(PagePreviewStep.Start, retry.Step);
        // The retry's own start: the draw limit doesn't count until it is ready.
        Assert.Equal(PagePreviewStep.None, never.TimedOut(retry.Attempt).Step);
        Assert.Equal(PagePreviewStep.Navigate, never.WebReady(retry.Attempt, webAlive: true).Step);
        Assert.Equal(PagePreviewStep.Fail, never.TimedOut(retry.Attempt).Step);
    }

    [Fact]
    public void AFailedLoadFailsACancelledOneDoesntAndLaterNavigationsDontUndoADrawnPage()
    {
        var life = new PagePreviewLife();
        var a = life.OnScreen().Attempt;
        // A link the guard kept out (NavigationStarting e.Cancel) finishes as OperationCanceled: not a failure.
        Assert.Equal(PagePreviewStep.None, life.NavigationDone(a, success: false, "OperationCanceled").Step);
        Assert.Equal(PagePreviewPhase.Loading, life.Phase);
        Assert.Equal(new PagePreviewDecision(PagePreviewStep.Fail, a, PagePreviewWords.DidntLoad),
            life.NavigationDone(a, success: false, "ConnectionAborted"));

        var drawn = new PagePreviewLife();
        var b = drawn.OnScreen().Attempt;
        drawn.NavigationDone(b, success: true, null);
        Assert.Equal(PagePreviewStep.None, drawn.NavigationDone(b, success: false, "ConnectionAborted").Step);
        Assert.True(drawn.IsReady);
        // Its renderer going takes the page away: said so.
        Assert.Equal(new PagePreviewDecision(PagePreviewStep.Fail, b, PagePreviewWords.ProcessGone), drawn.ProcessGone(b));
        Assert.False(drawn.IsReady);
    }

    [Fact]
    public void OffScreenWhileLoadingDropsThatAttemptAndOnScreenAgainStartsOver()
    {
        var life = new PagePreviewLife();
        var a = life.OnScreen().Attempt;
        life.OffScreen();
        Assert.Equal(PagePreviewPhase.Waiting, life.Phase);
        Assert.Equal(PagePreviewStep.Drop, life.WebReady(a, webAlive: true).Step);
        Assert.Equal(PagePreviewStep.Drop, life.NavigationDone(a, success: true, null).Step);
        Assert.Equal(PagePreviewStep.None, life.TimedOut(a).Step);

        var again = life.OnScreen();
        Assert.Equal(PagePreviewStep.Start, again.Step);
        Assert.NotEqual(a, again.Attempt);
        Assert.Equal(PagePreviewStep.Navigate, life.WebReady(again.Attempt, webAlive: true).Step);
        Assert.Equal(PagePreviewStep.Show, life.NavigationDone(again.Attempt, success: true, null).Step);
    }

    [Fact]
    public void ADrawnPageShownAgainKeepsItsWebViewOrStartsOverWhenItClosed()
    {
        var life = new PagePreviewLife();
        var a = life.OnScreen().Attempt;
        life.NavigationDone(a, success: true, null);
        life.OffScreen();
        Assert.Equal(PagePreviewPhase.Shown, life.Phase);
        Assert.Equal(PagePreviewStep.None, life.OnScreen(webAlive: true).Step);
        life.OffScreen();
        var restart = life.OnScreen(webAlive: false);
        Assert.Equal(PagePreviewStep.Start, restart.Step);
        Assert.False(life.IsReady);
    }

    [Fact]
    public void TryAgainStartsAFreshAttemptWhileOnScreen()
    {
        var life = new PagePreviewLife();
        var a = life.OnScreen().Attempt;
        life.WebReady(a, webAlive: true);
        Assert.Equal(PagePreviewStep.Fail, life.TimedOut(a).Step);
        var retry = life.Retry();
        Assert.Equal(PagePreviewStep.Start, retry.Step);
        Assert.Equal(PagePreviewPhase.Loading, life.Phase);
        Assert.Null(life.Reason);
        // The failed attempt's late navigation is dropped, the new one counts.
        Assert.Equal(PagePreviewStep.Drop, life.NavigationDone(a, success: true, null).Step);
        Assert.Equal(PagePreviewStep.Show, life.NavigationDone(retry.Attempt, success: true, null).Step);

        var off = new PagePreviewLife();
        var b = off.OnScreen().Attempt;
        off.WebReady(b, webAlive: true);
        off.TimedOut(b);
        off.OffScreen();
        Assert.Equal(PagePreviewStep.None, off.Retry().Step);
    }

    [Fact]
    public void TheWordsFollowTheMacTextViewersLoadingAndFailure()
    {
        Assert.Equal("Loading index.html\u2026", PagePreviewWords.Loading("index.html"));
        Assert.Equal("Couldn\u2019t Open This File", ArtifactPageWords.CouldntOpenFile);
        Assert.Equal("Try Again", ArtifactPageWords.TryAgain);
        Assert.All(new[] { PagePreviewWords.DidntLoad, PagePreviewWords.DidntDraw, PagePreviewWords.ProcessGone,
            PagePreviewWords.ViewerClosed, PagePreviewWords.ViewerFailed }, w => Assert.EndsWith("Its text is under Source.", w));
    }

    // ------------------------------------------------------------------ the walk's proof: drawn, not a bar over a blank

    [Fact]
    public void TheWalkAcceptsOnlyADrawnPageReadingItsHeading()
    {
        Assert.Equal("Release 2.4", WalkProof.WalkPageHeading);
        Assert.Null(WalkProof.PageDrawn(PagePreviewPhase.Shown, null, "Release 2.4\nExport, faster sync, six fixes.", "Release 2.4"));
        Assert.Equal("the page drew but its body reads \u201C\u201D, not \u201CRelease 2.4\u201D",
            WalkProof.PageDrawn(PagePreviewPhase.Shown, null, "", "Release 2.4"));
        Assert.Equal("the page drew but its body reads \u201C\u201D, not \u201CRelease 2.4\u201D",
            WalkProof.PageDrawn(PagePreviewPhase.Shown, null, null, "Release 2.4"));
        Assert.Equal($"the page didn't draw: {PagePreviewWords.DidntDraw}",
            WalkProof.PageDrawn(PagePreviewPhase.Failed, PagePreviewWords.DidntDraw, null, "Release 2.4"));
        Assert.Equal("the page's Preview is Loading, not drawn", WalkProof.PageDrawn(PagePreviewPhase.Loading, null, null, "Release 2.4"));
        Assert.Equal("the page's Preview is Closed, not drawn", WalkProof.PageDrawn(PagePreviewPhase.Closed, null, null, "Release 2.4"));
    }

    // ------------------------------------------------------------------ the app's code (WinUI doesn't run on a Mac)

    private static string WindowsDir()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return dir;
    }

    private static string Read(params string[] parts) => File.ReadAllText(Path.Combine([WindowsDir(), .. parts]));

    private static string HtmlView()
    {
        var all = Read("src", "HermesHQ.Windows", "Features", "Artifacts", "ArtifactViewers.cs");
        var at = all.IndexOf("internal sealed class ArtifactHtmlView", StringComparison.Ordinal);
        var end = all.IndexOf("internal sealed class PdfPagesView", StringComparison.Ordinal);
        Assert.True(at > 0 && end > at, "ArtifactHtmlView not found");
        return all[at..end];
    }

    [Fact]
    public void TheHtmlViewGoesThroughItsLifeAndIsNeverReadyWhenMade()
    {
        var view = HtmlView();
        var ctor = view[view.IndexOf("public ArtifactHtmlView(", StringComparison.Ordinal)..view.IndexOf("public void Close()", StringComparison.Ordinal)];
        Assert.DoesNotContain("IsReady = true", ctor);
        Assert.Contains("private readonly PagePreviewLife _life = new();", view);
        Assert.Contains("_life.OnScreen(", view);
        Assert.Contains("_life.OffScreen()", view);
        Assert.Contains("_life.WebReady(attempt", view);
        Assert.Contains("_life.NavigationDone(attempt, e.IsSuccess, e.WebErrorStatus.ToString())", view);
        Assert.Contains("_life.ProcessGone(attempt)", view);
        Assert.Contains("_life.TimedOut(attempt)", view);
        Assert.Contains("_life.StartTimedOut(attempt)", view);
        // The draw limit's watch starts only once WebReady said Navigate.
        Assert.True(view.IndexOf("_ = WatchAsync(attempt);", StringComparison.Ordinal) > view.IndexOf("ready.Step != PagePreviewStep.Navigate", StringComparison.Ordinal));
        // CoreWebView2 is read only after WebReady said Navigate.
        var ready = view.IndexOf("_life.WebReady(attempt", StringComparison.Ordinal);
        var navigate = view.IndexOf("ready.Step != PagePreviewStep.Navigate", StringComparison.Ordinal);
        var guard = view.IndexOf("Look.Guard(web, _preview)", StringComparison.Ordinal);
        Assert.True(ready > 0 && navigate > ready && guard > navigate, "the view reads CoreWebView2 before its life says it is live");
        Assert.Contains("IsReady = true", view[view.IndexOf("case PagePreviewStep.Show:", StringComparison.Ordinal)..]);
        // The failure state: accessible, Try Again, Show Source.
        Assert.Contains("\"artifact.page.failure\"", view);
        Assert.Contains("ArtifactPageWords.TryAgain", view);
        Assert.Contains("PagePreviewWords.ShowSource", view);
        Assert.Contains("AutomationLiveSetting.Assertive", view);
    }

    [Fact]
    public void TheGuardStillKeepsThePageInItsOwnFile()
    {
        var all = Read("src", "HermesHQ.Windows", "Features", "Artifacts", "ArtifactViewers.cs");
        var guard = all[all.IndexOf("public static void Guard(", StringComparison.Ordinal)..all.IndexOf("internal abstract class ArtifactViewer", StringComparison.Ordinal)];
        Assert.Contains("e.Cancel = true;", guard);
        Assert.Contains("if (e.IsUserInitiated) ArtifactActions.OpenOutside(e.Uri);", guard);
        Assert.Contains("e.Handled = true;", guard);
        Assert.DoesNotContain("AreDevToolsEnabled = true", all);
        Assert.DoesNotContain("SetVirtualHostNameToFolderMapping", all);
        // The page is still the file it was handed, by its own file URI.
        Assert.Contains("core.Navigate(new Uri(_preview).AbsoluteUri)", HtmlView());
    }

    [Fact]
    public void AFileWindowClosesItsPageViewWhenReplacedOrClosedAndTheWalkWaitsForADrawnPage()
    {
        var windows = Read("src", "HermesHQ.Windows", "Features", "Artifacts", "ArtifactWindows.cs");
        var show = windows[windows.IndexOf("private void ShowContent(", StringComparison.Ordinal)..];
        Assert.Contains("(_body as ArtifactHtmlView)?.Close();", show[..show.IndexOf("_body = body;", StringComparison.Ordinal)]);
        var closed = windows[windows.IndexOf("Closed += (_, _) =>", StringComparison.Ordinal)..];
        Assert.True(closed.IndexOf("(_body as ArtifactHtmlView)?.Close();", StringComparison.Ordinal) is >= 0 and < 200);

        var walk = Read("src", "HermesHQ.Windows", "Services", "ProofWalks.Windows.cs");
        var drawn = walk.IndexOf("await PageDrawnAsync(pageWindow, \"the page's window\");", StringComparison.Ordinal);
        var shotAt = walk.IndexOf("shot(\"file-windows-page\")", StringComparison.Ordinal);
        Assert.True(drawn > 0 && shotAt > drawn, "the walk shoots the page's window before its page drew");
        Assert.Contains("await PageDrawnAsync(pageWindow, \"the page opened again\");", walk);
        Assert.Contains("WalkProof.PageDrawn(view.Phase, view.FailureReason, text, WalkProof.WalkPageHeading)", walk);
    }
}
