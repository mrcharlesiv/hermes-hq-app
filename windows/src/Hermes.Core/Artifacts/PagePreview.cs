namespace Hermes.Core.Artifacts;

// An HTML page's live Preview (ArtifactTextViewController.swift `showPreviewChild` at 93f984bb1, its web view the page
// sheet's own: HTMLPageSheet.swift `reveal`, "A page that fails to draw still shows what it has, not a spinner
// forever"). The Mac's WKWebView is ready the moment it is made; Windows' WebView2 is not: its CoreWebView2 comes
// later, asynchronously, and the view can be taken off screen or its window closed before it does. What the view
// does with each thing that happens lives here, without WinUI, so the late work of a view that's gone (dropped,
// quietly) is never mistaken for a page that failed to draw in a view still on show (said so, with Try Again and its
// Source), and a page that hasn't drawn is never called ready. The view is Features/Artifacts/ArtifactViewers.cs
// `ArtifactHtmlView`.

public enum PagePreviewPhase
{
    /// Made, not on screen yet (or taken off before the page drew): nothing started, or what started was dropped.
    Waiting,
    /// The web view is being made or the page is loading: the spinner, \u201CLoading index.html\u2026\u201D.
    Loading,
    /// The page drew (its navigation finished well). Only now is the Preview ready.
    Shown,
    /// The page didn't draw in a view still on show: the failure state says why, with Try Again and Source.
    Failed,
    /// Its window closed or its body was replaced: anything still under way is dropped.
    Closed,
}

/// What the view does next.
public enum PagePreviewStep
{
    /// Nothing (already settled, or a load the next one replaced).
    None,
    /// Make the web view and load the page (attempt `Attempt`).
    Start,
    /// The web view is ready: guard it and navigate.
    Navigate,
    /// Hide the spinner: the page is on show.
    Show,
    /// Show the failure state (`Reason`).
    Fail,
    /// Late work of an attempt that's no longer live (the view taken off screen, its window closed): drop it, and
    /// say so in the log as late, not as a failure.
    Drop,
}

public readonly record struct PagePreviewDecision(PagePreviewStep Step, int Attempt = 0, string? Reason = null);

/// The life of one Preview. Every async result carries the attempt it belongs to; only the live attempt counts.
public sealed class PagePreviewLife
{
    /// How long a page may take to draw before the view says it didn't (a WebView2 runtime's first start on a cold
    /// PC takes a few seconds; a blank that looks ready forever is what this stops).
    public static readonly TimeSpan DrawLimit = TimeSpan.FromSeconds(30);

    /// How long WebView2 may take to be ready (EnsureCoreWebView2Async) before the view says the page didn't draw.
    /// Windows only: the Mac's WKWebView is ready the moment it is made. `DrawLimit` runs from then, not from here: a
    /// cold runtime's first start took 37 s on CI (run 45114288543, the page drawn 0.1 s after), longer than the whole
    /// draw limit, and every later page window was ready in under a second.
    public static readonly TimeSpan StartLimit = TimeSpan.FromSeconds(90);

    /// How long a walk waits for a Preview to settle: the web view's start, then the page's draw.
    public static TimeSpan SettleLimit => StartLimit + DrawLimit;

    private bool _webReady;

    private int _attempt;
    private bool _onScreen;

    public PagePreviewPhase Phase { get; private set; } = PagePreviewPhase.Waiting;
    public string? Reason { get; private set; }
    /// The attempt now live (0 before the first).
    public int Attempt => _attempt;
    public bool IsReady => Phase == PagePreviewPhase.Shown;

    /// The view came on screen (Loaded). `webAlive`: its web view still has its CoreWebView2 (a view shown again after
    /// its web view was closed starts over).
    public PagePreviewDecision OnScreen(bool webAlive = true)
    {
        _onScreen = true;
        switch (Phase)
        {
            case PagePreviewPhase.Closed:
            case PagePreviewPhase.Loading:
            case PagePreviewPhase.Failed:
                return new(PagePreviewStep.None, _attempt);
            case PagePreviewPhase.Shown when webAlive:
                return new(PagePreviewStep.None, _attempt);
            default:
                return Begin();
        }
    }

    /// The view went off screen (Unloaded). A load under way is dropped; on screen again, it starts over. A page on
    /// show stays on show.
    public void OffScreen()
    {
        _onScreen = false;
        if (Phase == PagePreviewPhase.Loading)
        {
            _attempt++;
            Phase = PagePreviewPhase.Waiting;
        }
    }

    /// Its window closed or its body was replaced by the page just made: nothing more happens in it.
    public void Close()
    {
        if (Phase == PagePreviewPhase.Closed) return;
        _attempt++;
        _onScreen = false;
        Phase = PagePreviewPhase.Closed;
    }

    /// Try Again on the failure state.
    public PagePreviewDecision Retry() =>
        Phase == PagePreviewPhase.Closed || !_onScreen ? new(PagePreviewStep.None, _attempt) : Begin();

    /// The web view of `attempt` is ready (EnsureCoreWebView2Async came back). `webAlive`: it has its CoreWebView2.
    public PagePreviewDecision WebReady(int attempt, bool webAlive)
    {
        if (!Live(attempt)) return new(PagePreviewStep.Drop, attempt, "the web view came after the view was gone");
        if (!webAlive) return Fail(attempt, PagePreviewWords.ViewerClosed);
        if (Phase != PagePreviewPhase.Loading) return new(PagePreviewStep.None, attempt);
        _webReady = true;
        return new(PagePreviewStep.Navigate, attempt);
    }

    /// Making the web view or starting the load of `attempt` threw.
    public PagePreviewDecision Threw(int attempt, string errorType)
    {
        if (!Live(attempt)) return new(PagePreviewStep.Drop, attempt, $"{errorType} after the view was gone");
        return Fail(attempt, PagePreviewWords.ViewerFailed);
    }

    /// A navigation in the page finished. `status`: WebView2's CoreWebView2WebErrorStatus name. A navigation the guard
    /// cancelled (a link it kept out) or the next load replaced is not a failure (the Mac's NSURLErrorCancelled / 102);
    /// once the page drew, later navigations don't change what's shown.
    public PagePreviewDecision NavigationDone(int attempt, bool success, string? status)
    {
        if (!Live(attempt)) return new(PagePreviewStep.Drop, attempt, "a navigation finished after the view was gone");
        if (Phase != PagePreviewPhase.Loading) return new(PagePreviewStep.None, attempt);
        if (success)
        {
            Phase = PagePreviewPhase.Shown;
            Reason = null;
            return new(PagePreviewStep.Show, attempt);
        }
        if (status == "OperationCanceled") return new(PagePreviewStep.None, attempt);
        return Fail(attempt, PagePreviewWords.DidntLoad);
    }

    /// The page's renderer or the browser process went (CoreWebView2.ProcessFailed): whatever it showed is gone.
    public PagePreviewDecision ProcessGone(int attempt)
    {
        if (!Live(attempt)) return new(PagePreviewStep.Drop, attempt, "the page's process went after the view was gone");
        if (Phase is not (PagePreviewPhase.Loading or PagePreviewPhase.Shown)) return new(PagePreviewStep.None, attempt);
        return Fail(attempt, PagePreviewWords.ProcessGone);
    }

    /// `DrawLimit` passed for `attempt` since its web view was ready (the Navigate step). Before then only `StartLimit`
    /// counts.
    public PagePreviewDecision TimedOut(int attempt)
    {
        if (!Live(attempt) || Phase != PagePreviewPhase.Loading || !_webReady) return new(PagePreviewStep.None, attempt);
        return Fail(attempt, PagePreviewWords.DidntDraw);
    }

    /// `StartLimit` passed for `attempt` and its web view still isn't ready: the page didn't draw, said so (a spinner
    /// forever is what this stops).
    public PagePreviewDecision StartTimedOut(int attempt)
    {
        if (!Live(attempt) || Phase != PagePreviewPhase.Loading || _webReady) return new(PagePreviewStep.None, attempt);
        return Fail(attempt, PagePreviewWords.DidntDraw);
    }

    private bool Live(int attempt) => attempt == _attempt && Phase is not (PagePreviewPhase.Closed or PagePreviewPhase.Waiting);

    private PagePreviewDecision Begin()
    {
        _attempt++;
        _webReady = false;
        Phase = PagePreviewPhase.Loading;
        Reason = null;
        return new(PagePreviewStep.Start, _attempt);
    }

    private PagePreviewDecision Fail(int attempt, string reason)
    {
        Phase = PagePreviewPhase.Failed;
        Reason = reason;
        return new(PagePreviewStep.Fail, attempt, reason);
    }
}

/// The Preview's words. The Mac has no failed state for a page (its WKWebView shows whatever it has); these follow
/// its text viewer's (ArtifactTextViewController.showFailure: \u201CCouldn\u2019t Open This File\u201D, Try Again) and its
/// loading words (\u201CLoading plan.md\u2026\u201D).
public static class PagePreviewWords
{
    public static string Loading(string name) => $"Loading {name}\u2026";
    public const string DidntLoad = "The page didn\u2019t load here. Its text is under Source.";
    public const string DidntDraw = "The page didn\u2019t draw in time. Its text is under Source.";
    public const string ProcessGone = "The page stopped drawing. Its text is under Source.";
    public const string ViewerClosed = "The page\u2019s viewer closed before the page could draw. Its text is under Source.";
    public const string ViewerFailed = "The page\u2019s viewer couldn\u2019t start here. Its text is under Source.";
    /// The failure state's second button: the page's text.
    public const string ShowSource = "Show Source";
}
