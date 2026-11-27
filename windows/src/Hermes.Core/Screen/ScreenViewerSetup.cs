// [WIN-SCREEN-VIEWER-CORE] Bot Screen's hooks into the app that are not drawing, from the Mac's
// App/Screen/AppModel+Screen.swift at 93f984bb1 (docs/spec/3x-screen.md §5.1, §5.13, §6.1): the ledger that keeps
// "Set up with Hermes" to one request at a time per bot, the rule for a request that is already there, the viewer's
// configuration when the app opens it, and the Bot Info row's words. Opening the bot's chat and sending the request
// (`runScreenSetup`) are the page's; it runs on the UI thread, as the Swift's @MainActor ledger does.


namespace Hermes.Core.Screen;

/// Which bots had setup requested in this run, and the request in flight per bot (a second tap joins the first).
public sealed class ScreenSetupLedger
{
    /// The app's one ledger (Swift's `enum ScreenSetupLedger` statics).
    public static ScreenSetupLedger Shared { get; } = new();

    private readonly HashSet<string> _submitted = [];
    private readonly Dictionary<string, Task<ScreenSetupError?>> _inFlight = [];

    public static string Key(string accountId, string profile) => $"{accountId}|{profile}";

    public bool Submitted(string key) => _submitted.Contains(key);
    public void MarkSubmitted(string key) => _submitted.Add(key);
    public bool InFlight(string key) => _inFlight.ContainsKey(key);

    /// The viewer's `setupRequested`: submitted in this run, or on its way.
    public bool Requested(string key) => _submitted.Contains(key) || _inFlight.ContainsKey(key);

    /// One request at a time per bot (`requestScreenSetup`): a second call while one runs waits for the first's answer.
    public async Task<ScreenSetupError?> Request(string key, Func<Task<ScreenSetupError?>> run)
    {
        if (_inFlight.TryGetValue(key, out var pending)) return await pending;
        // Started after the entry is in, as the Swift's `Task {}` is: a run that finishes at once still joins nothing.
        var started = new TaskCompletionSource();
        var task = Started(started.Task, run);
        _inFlight[key] = task;
        started.SetResult();
        try { return await task; }
        finally { if (_inFlight.TryGetValue(key, out var now) && now == task) _inFlight.Remove(key); }
    }

    private static async Task<ScreenSetupError?> Started(Task gate, Func<Task<ScreenSetupError?>> run)
    {
        await gate;
        return await run();
    }

    /// Already there: a queued request, or one made this run that is not being continued. Marks it submitted.
    public bool AlreadyThere(string key, bool hasQueuedSetup, bool resume)
    {
        if (!hasQueuedSetup && !(_submitted.Contains(key) && !resume)) return false;
        _submitted.Add(key);
        return true;
    }

    /// The viewer the app opens (`openScreen`): setup goes through `request`, its "requested" state through this
    /// ledger, and a Hermes Cloud gateway's missing add-on opens the agent's page instead.
    public void Configure(ScreenViewerController viewer, string accountId, Func<bool, Task<ScreenSetupError?>> request,
                          Action? openCloudAgent, Func<string, bool>? ownsSession)
    {
        var key = Key(accountId, viewer.Profile);
        viewer.RequestSetup = resume => Request(key, () => request(resume));
        viewer.SetupRequested = () => Requested(key);
        viewer.OpenCloudAgent = openCloudAgent;
        viewer.OwnsSession = ownsSession == null ? null : runtime => runtime.Length > 0 && ownsSession(runtime);
    }
}

/// Bot Info's Computer group and its Screen row (ScreenInfoRow).
public static class ScreenInfoRowWords
{
    public const string Header = "Computer";
    /// Shown at the row's end while the bot's screen is running and the bot itself is in control.
    public const string Live = "Live";

    /// The line under the title: what the row shows.
    public static string Subtitle(ScreenKind kind) =>
        kind == ScreenKind.Screenshots ? "See what was on its screen last" : "See its desktop live";

    /// A setup failure's alert (`screenSetupFailed`): the title, the message, OK.
    public static (string Title, string Message, string Button) SetupFailed(ScreenSetupError failure) =>
        (ScreenSetupError.AlertTitle, ScreenWire.Plain(failure.Message), "OK");
}
