// Headless Watch Browser viewer controller, C# twin of App/Browser/BrowserViewerController.swift (matching the
// ScreenViewerController architecture in Hermes.Core/Screen). Drives plugin discovery/revalidation, activity
// subscription, BrowserWatchSession lifecycle, BrowserLastPages persistence, own-browser polling, tabs, address bar,
// Take Control / Give Back, page dialogs, popups update offer, notices/hints, clipboard, keyboard slot following, and
// clean close/shutdown — all testable headlessly without WinUI.

using Hermes.Core.Gateways;
using Hermes.Core.Net;
using Hermes.Core.Screen;

namespace Hermes.Core.Browser;

/// Timers on the UI thread (WinUI uses DispatcherQueueTimer; tests use a fake clock).
public interface IBrowserTimers
{
    IDisposable Schedule(TimeSpan after, bool repeats, Action fire);
}

public enum BrowserHaptic { Selection, Success, Warning }

public abstract record BrowserViewerSetup
{
    private BrowserViewerSetup() { }
    public sealed record Checking : BrowserViewerSetup { public static readonly Checking Instance = new(); }
    public sealed record Failed(string Message) : BrowserViewerSetup;
    public sealed record Missing : BrowserViewerSetup { public static readonly Missing Instance = new(); }
    public sealed record Update : BrowserViewerSetup { public static readonly Update Instance = new(); }
    public sealed record Drift(BrowserEmptyCopy Copy) : BrowserViewerSetup;
    public sealed record Ready : BrowserViewerSetup { public static readonly Ready Instance = new(); }

    public string DebugName => this switch
    {
        Checking => "checking",
        Failed f => $"failed({f.Message})",
        Missing => "missing",
        Update => "update",
        Drift => "drift",
        Ready => "ready",
        _ => "unknown",
    };
}

public sealed record BrowserViewerEmptyState(
    bool Spinner,
    bool Icon,
    string Title,
    string Body,
    string? ActionTitle,
    bool ActionEnabled,
    string? ProblemText);

public enum BrowserViewerBarMode { None, LastPage, Watch, Waiting, SomeoneElse, Mine }

public sealed record BrowserViewerBarState(
    BrowserViewerBarMode Mode,
    bool TakeEnabled,
    bool Typing,
    string? Caption,
    string? WaitingText);

public sealed record BrowserViewerState
{
    public string Title { get; init; } = "";
    public BrowserViewerSetup Setup { get; init; } = BrowserViewerSetup.Checking.Instance;
    public BrowserViewerEmptyState? Empty { get; init; }
    public bool StageHidden { get; init; } = true;
    public bool StageShowsCursor { get; init; }
    public bool AddressVisible { get; init; }
    public string AddressText { get; init; } = "";
    public bool AddressSecure { get; init; }
    public bool EditingAddress { get; init; }
    public bool BlankNoteVisible { get; init; }
    public string BlankNoteBody { get; init; } = "";
    public bool AskVisible { get; init; }
    public string AskTitle { get; init; } = "";
    public string AskBody { get; init; } = "";
    public IReadOnlyList<BrowserTab> Tabs { get; init; } = [];
    public string? CurrentTabId { get; init; }
    public bool Follow { get; init; } = true;
    public BrowserViewerBarState Bar { get; init; } = new(BrowserViewerBarMode.None, false, false, null, null);
    public string? NoticeText { get; init; }
    public string? HintText { get; init; }
    public bool ShowingLastPage { get; init; }
    public bool Live { get; init; }
    public bool Mine { get; init; }
    public bool HasPage { get; init; }
    public string? PacingSummary { get; init; }
}

/// What BrowserViewerController asks of its WinUI view. Every member has an inert default for headless tests.
public interface IBrowserViewerHost
{
    void Render(BrowserViewerState state) { }
    void ShowFrame(BrowserDecodedImage image, BrowserSize pageSize) { }
    void ClearStage() { }
    void Haptic(BrowserHaptic kind) { }
    void Announce(string text) { }
    void CopyText(string text) { }
    Task<string?> ReadClipboardAsync() => Task.FromResult<string?>(null);
    bool KeyboardFocused => false;
    BrowserKeyboardSlot? FocusedSlot => null;
    void RaiseKeyboard(BrowserKeyboardSlot slot, BrowserKeyboardKind kind) { }
    void UpdateKeyboard(BrowserKeyboardKind kind) { }
    void LowerKeyboard() { }
    void TakeKeys() { }
    void ShowPageDialog(BrowserPageDialog dialog) { }
    void DismissPageDialog() { }
    void OfferPopupsUpdate(bool useUpdateSheet, string helperName) { }
    void ShowInstallFailure(string helperName, string reason) { }
    void OpenPlugins() { }
    void Dismiss() { }
    (double Width, double Height, double Scale) StageMetrics => (0, 0, 1);
}

public sealed class BrowserViewerController : IBrowserStageHost
{
    private static WeakReference<BrowserViewerController>? _current;
    public static BrowserViewerController? Current =>
        _current != null && _current.TryGetTarget(out var viewer) ? viewer : null;

    public static bool IsUp => Current != null;
    public static bool IsWatching(string profile) =>
        Current is { Closing: false } v && v.Scope.Profile == profile;

    public static void CloseCurrent(Action completion)
    {
        if (Current is not { } viewer) { completion(); return; }
        viewer.Close(completion);
    }

    public static TimeSpan OwnPollInterval { get; set; } = TimeSpan.FromSeconds(4);

    public BrowserService Service { get; }
    public BrowserScope Scope { get; }
    public BrowserStageState Stage { get; }
    public BrowserWatchSession? Session { get; private set; }
    public BrowserPluginInfo? Plugin { get; private set; }
    public BrowserViewerSetup Setup { get; private set; } = BrowserViewerSetup.Checking.Instance;
    public BrowserViewerState State { get; private set; } = new();

    public Func<string, Task>? AskToInstall { get; set; }
    public Action? CanAsk { get; set; }
    public string Helper { get; set; } = "Hermes";
    public Action? OpenPluginsAction { get; set; }
    public Action? UpdateAddOnAction { get; set; }
    public bool CloudGateway { get; set; }

    public string Name => string.IsNullOrEmpty(Scope.Title) ? "This bot" : Scope.Title;
    public string Title => $"{Name}’s Browser";
    public bool Closing { get; private set; }
    public bool ShowingLastPage { get; private set; }
    public bool EditingAddress { get; private set; }
    public bool Typing { get; private set; }
    public bool IsShown => _loaded && _appActive && _appeared && !Closing;
    public string DebugSetup => Setup.DebugName;

    private readonly IBrowserViewerHost _host;
    private readonly IBrowserTimers? _timers;
    private readonly Func<DateTimeOffset> _now;
    private readonly List<Action> _afterClose = [];

    private BrowserSubscription? _subscription;
    private bool _ownKnown;
    private OwnBrowser? _own;
    private CancellationTokenSource? _ownPollCts;
    private CancellationTokenSource? _checkCts;
    private BrowserLastPage? _lastPage;
    private double? _endedAgentAt;
    private bool _loaded;
    private bool _appeared;
    private bool _appActive = true;
    private bool _asking;
    private string? _emptyProblemText;
    private Action? _emptyAction;
    private string? _noticeText;
    private string? _hintText;
    private IDisposable? _noticeTimer;
    private IDisposable? _hintTimer;
    private bool _lastMine;
    private int? _shownDialogId;
    private int? _answeredDialogId;
    private int? _noticedDialogId;

    public BrowserViewerController(
        BrowserService service,
        BrowserScope scope,
        IBrowserViewerHost host,
        IBrowserTimers? timers = null,
        Func<DateTimeOffset>? now = null)
    {
        Service = service;
        Scope = scope;
        _host = host;
        _timers = timers;
        _now = now ?? (() => DateTimeOffset.Now);
        CloudGateway = service.HostedGateway;
        Stage = new BrowserStageState(timers) { Host = this };
    }

    public static BrowserViewerReopen CheckReopen(string askedProfile, bool ownWindow = true)
    {
        var shown = Current;
        return BrowserViewerReopenRule.Decide(shown?.Scope.Profile, shown?.Closing ?? false, askedProfile, ownWindow);
    }

    public void RegisterCurrent() => _current = new WeakReference<BrowserViewerController>(this);

    // ------------------------------------------------------------------ Lifecycle

    public void Load()
    {
        if (_loaded) return;
        _loaded = true;
        Service.Note?.Invoke("viewer open");
        if (Service.AccountId is { Length: > 0 } account &&
            Service.LastPages?.Page(account, Scope.Profile, _now()) is { } saved &&
            saved.Fits(Scope))
        {
            _lastPage = saved;
        }
        Render();
        Check(preferCache: true);
    }

    public void Appeared()
    {
        _appeared = true;
        UpdateShown();
        TakeKeys();
    }

    public void Disappeared()
    {
        _appeared = false;
        UpdateShown();
        FlushLastPage();
    }

    public void AppActiveChanged(bool active)
    {
        _appActive = active;
        Stage.Covered = !active;
        UpdateShown();
    }

    public void LayoutChanged() => SendViewSize();

    public void SendViewSize()
    {
        if (Session == null) return;
        var (w, h, scale) = _host.StageMetrics;
        if (w <= 0) return;
        var zoom = Stage.Drawn.Zoom;
        Session.SetViewSize(w * zoom, h * zoom, scale);
    }

    // ------------------------------------------------------------------ Setup & revalidation

    public void Check(bool preferCache = true)
    {
        CancelCts(ref _checkCts);
        if (preferCache && Service.CachedPlugin is { } cached)
        {
            Plugin = cached;
            Setup = BrowserViewerSetup.Ready.Instance;
            Service.Note?.Invoke($"viewer setup ready (cached){(cached.Legacy ? " (old plugin name)" : "")}");
            UpdateShown();
            Render();
            var cts = _checkCts = new CancellationTokenSource();
            _ = RevalidateAsync(cts.Token);
            return;
        }
        Setup = BrowserViewerSetup.Checking.Instance;
        Render();
        var checkCts = _checkCts = new CancellationTokenSource();
        _ = RunCheckAsync(checkCts.Token);
    }

    private async Task RunCheckAsync(CancellationToken ct)
    {
        try
        {
            var found = await Service.PluginAsync(fresh: true, ct: ct).ConfigureAwait(false);
            if (ct.IsCancellationRequested) return;
            Service.Post(() =>
            {
                if (ct.IsCancellationRequested || Closing) return;
                Plugin = found;
                Setup = found.Setup switch
                {
                    BrowserSetup.Ready => BrowserViewerSetup.Ready.Instance,
                    BrowserSetup.Missing => BrowserViewerSetup.Missing.Instance,
                    BrowserSetup.Update => BrowserViewerSetup.Update.Instance,
                    BrowserSetup.Drift => new BrowserViewerSetup.Drift(BrowserEmptyCopy.AddOnOff(found.Health)),
                    _ => BrowserViewerSetup.Missing.Instance,
                };
                Service.Note?.Invoke($"viewer setup {found.Setup.ToString().ToLowerInvariant()}{(found.Legacy ? " (old plugin name)" : "")}");
                UpdateShown();
                Render();
            });
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            if (ct.IsCancellationRequested) return;
            Service.Post(() =>
            {
                if (ct.IsCancellationRequested || Closing) return;
                if (BrowserService.IsMissing(e)) Setup = BrowserViewerSetup.Missing.Instance;
                else Setup = new BrowserViewerSetup.Failed(e is GatewayException ge && ge.Message.Length > 0 ? ge.Message : "Check your connection, then try again.");
                Service.Note?.Invoke($"viewer setup {(BrowserService.IsMissing(e) ? "missing" : "failed")}");
                UpdateShown();
                Render();
            });
        }
    }

    private async Task RevalidateAsync(CancellationToken ct)
    {
        BrowserPluginInfo found;
        try
        {
            found = await Service.PluginAsync(fresh: true, ct: ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { return; }
        catch (Exception e)
        {
            if (ct.IsCancellationRequested || Service.IsShutDown || !BrowserService.IsMissing(e)) return;
            Service.Post(() =>
            {
                if (ct.IsCancellationRequested || Service.IsShutDown || Closing) return;
                Setup = BrowserViewerSetup.Missing.Instance;
                Service.Note?.Invoke("viewer setup missing (rechecked)");
                UpdateShown();
                Render();
            });
            return;
        }
        if (ct.IsCancellationRequested || Service.IsShutDown) return;
        Service.Post(() =>
        {
            if (ct.IsCancellationRequested || Service.IsShutDown || Closing) return;
            switch (found.Setup)
            {
                case BrowserSetup.Ready:
                    var moved = found.Base != Plugin?.Base;
                    Plugin = found;
                    if (moved && Session != null)
                    {
                        Session.Stop();
                        Session = null;
                        Stage.Clear();
                        _host.ClearStage();
                        RowsChanged();
                    }
                    return;
                case BrowserSetup.Missing:
                    Setup = BrowserViewerSetup.Missing.Instance;
                    break;
                case BrowserSetup.Drift:
                    Setup = new BrowserViewerSetup.Drift(BrowserEmptyCopy.AddOnOff(found.Health));
                    break;
                case BrowserSetup.Update:
                    if (Session is { View: not null, Ended: false })
                    {
                        Service.Note?.Invoke("viewer setup update (rechecked, kept the page)");
                        ShowNotice($"The browser add\u2011on on {HostWord.Phrase} needs an update. You can keep watching for now.", warning: false);
                        return;
                    }
                    Setup = BrowserViewerSetup.Update.Instance;
                    break;
            }
            Service.Note?.Invoke($"viewer setup {found.Setup.ToString().ToLowerInvariant()} (rechecked)");
            UpdateShown();
            Render();
        });
    }

    // ------------------------------------------------------------------ Activity & watch session

    private BrowserRow? Row => Scope.Row(Service.Activity.Rows);

    private void UpdateShown()
    {
        if (!_loaded) return;
        var on = IsShown && Setup is BrowserViewerSetup.Ready;
        if (on && _subscription == null)
        {
            _subscription = Service.Activity.Subscribe(RowsChanged);
            RowsChanged();
        }
        else if (!on && _subscription != null)
        {
            _subscription.Cancel();
            _subscription = null;
        }
        Session?.SetShown(on);
        UpdateOwnPoll();
    }

    private void RowsChanged()
    {
        var row = Row;
        var reopened = Session is { Ended: true } && row != null && row.AgentAt > (_endedAgentAt ?? double.PositiveInfinity);
        if (row != null && (row.Id != Session?.RowId || reopened))
        {
            Session?.Stop();
            Stage.Clear();
            _host.ClearStage();
            _endedAgentAt = null;
            var watch = new BrowserWatchSession(Service, row.Id, Plugin?.Base ?? BrowserWire.Plugin, row.Profile, Name);
            Wire(watch);
            Session = watch;
            Service.Note?.Invoke("viewer watching a browser");
            watch.SetShown(IsShown && Setup is BrowserViewerSetup.Ready);
            SendViewSize();
        }
        UpdateOwnPoll();
        Render();
    }

    private void UpdateOwnPoll()
    {
        var wanted = Setup is BrowserViewerSetup.Ready && Row == null && Session == null && IsShown;
        if (!wanted) { CancelCts(ref _ownPollCts); return; }
        if (_ownPollCts != null) return;
        var cts = _ownPollCts = new CancellationTokenSource();
        _ = RunOwnPollAsync(cts.Token);
    }

    private async Task RunOwnPollAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var found = await Service.OwnBrowserAsync(Scope.Profile, ct).ConfigureAwait(false);
                if (ct.IsCancellationRequested) return;
                Service.Post(() =>
                {
                    if (ct.IsCancellationRequested || Closing) return;
                    _ownKnown = true;
                    _own = found;
                    Render();
                });
            }
            catch (OperationCanceledException) { return; }
            catch (Exception)
            {
                Service.Post(() =>
                {
                    if (ct.IsCancellationRequested || Closing) return;
                    if (!_ownKnown) { _ownKnown = true; _own = null; Render(); }
                });
            }
            try { await Task.Delay(OwnPollInterval, ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
        }
    }

    private void Wire(BrowserWatchSession watch)
    {
        watch.OnChange = () =>
        {
            if (watch.Ended && _endedAgentAt == null)
            {
                _endedAgentAt = Row?.AgentAt ?? 0;
                FlushLastPage();
            }
            Render();
        };
        watch.OnFrame = (image, frame) =>
        {
            var size = new BrowserSize(frame.Width, frame.Height);
            Stage.ShowFrame(size);
            _host.ShowFrame(image, size);
            KeepLastPage(frame, watch);
        };
        watch.OnNotice = (text, warning) => ShowNotice(text, warning);
        watch.OnCopied = OnCopied;
        watch.OnShutDown = () =>
        {
            ResignTyping();
            Session = null;
            _subscription?.Cancel();
            _subscription = null;
            Close();
        };
    }

    private void KeepLastPage(BrowserFrame frame, BrowserWatchSession watch)
    {
        var tab = watch.View?.CurrentTab;
        var row = Row;
        var page = new BrowserLastPage(frame.Jpeg, frame.Width, frame.Height, tab?.Url ?? row?.Url,
            tab?.Title, row?.Driver, _now());
        _lastPage = page;
        if (Service.AccountId is { Length: > 0 } account)
            Service.LastPages?.Keep(page, account, Scope.Profile);
    }

    private void FlushLastPage()
    {
        if (Service.AccountId is { Length: > 0 } account)
            Service.LastPages?.Flush(account, Scope.Profile);
    }

    private void ShowLastPageOnStage(BrowserLastPage page)
    {
        if (Stage.HasFrame) return;
        var image = Service.ImageDecoder.Decode(page.Jpeg);
        if (image == null) return;
        var size = new BrowserSize(page.Width, page.Height);
        Stage.ShowFrame(size);
        _host.ShowFrame(image, size);
    }

    // ------------------------------------------------------------------ Rendering

    public void Render()
    {
        if (!_loaded || Closing) return;
        var state = Session?.View;
        var mine = Session?.Mine ?? false;
        var waiting = Session?.Waiting ?? false;
        var someoneElse = Session?.SomeoneElse ?? false;
        var link = Session?.Link ?? BrowserWatchLink.Idle;
        var live = Session is { Page: not null, View: not null } && link != BrowserWatchLink.Stalled;

        BrowserViewerEmptyState? empty = null;
        _emptyAction = null;
        var last = false;

        switch (Setup)
        {
            case BrowserViewerSetup.Checking:
                empty = new(true, false, "", "", null, false, null);
                break;
            case BrowserViewerSetup.Failed f:
                _emptyAction = () => Check(preferCache: false);
                empty = new(false, false, $"Couldn’t Reach {Name}", f.Message, "Try Again", !_asking, _emptyProblemText);
                break;
            case BrowserViewerSetup.Missing when CloudGateway:
                empty = new(false, true, "Bots Browse in the Cloud Here",
                    "On Hermes Cloud, a bot uses a cloud browser that can’t be shown live. To watch your bots and take over, switch them to your own Browser Use account in Settings › Browser Use Cloud. You can still follow each page a bot visits in its steps.",
                    null, false, null);
                break;
            case BrowserViewerSetup.Missing or BrowserViewerSetup.Update:
            {
                var isUpdate = Setup is BrowserViewerSetup.Update;
                string? actionTitle = null;
                if (AskToInstall != null)
                {
                    actionTitle = _asking ? "Asking…" : $"Ask {Helper} to Install It";
                    _emptyAction = () => Install(BrowserSetupPrompt.Text);
                }
                empty = new(false, true,
                    isUpdate ? "Update Browser Watching" : "Watch Your Bots Browse",
                    isUpdate
                        ? $"{HostWord.Sentence} has an older browser add\u2011on from a test build. The new one leaves your bots’ own browser tools alone and needs no Chrome extension."
                        : $"See the browser a bot is using, live, and take over when it needs you to sign in or enter a code. It needs a small add\u2011on on {HostWord.Phrase}.",
                    actionTitle, !_asking, actionTitle != null ? _emptyProblemText : null);
                break;
            }
            case BrowserViewerSetup.Drift d:
            {
                string? actionTitle = null;
                if (d.Copy.Action == BrowserEmptyAction.Update)
                {
                    if (UpdateAddOnAction != null)
                    {
                        actionTitle = BrowserEmptyCopy.UpdateButton;
                        _emptyAction = StartUpdate;
                    }
                    else if (AskToInstall != null)
                    {
                        actionTitle = _asking ? "Asking…" : $"Ask {Helper} to Update It";
                        _emptyAction = () => Install(BrowserSetupPrompt.Update);
                    }
                }
                empty = new(false, true, d.Copy.Title, d.Copy.Body, actionTitle, !_asking, actionTitle != null ? _emptyProblemText : null);
                break;
            }
            case BrowserViewerSetup.Ready:
                if (Session is { Ended: true })
                {
                    if (_lastPage != null) last = true;
                    else empty = new(false, true, "Browser Closed", $"When {Name} opens a web page, you’ll see it here live.", null, false, null);
                }
                else if (Session == null)
                {
                    if (!Service.Activity.Connected)
                        empty = new(true, false, "Connecting…", "", null, false, null);
                    else if (_lastPage != null && (!_ownKnown || BrowserLastPage.Replaces(_own?.Status)))
                        last = true;
                    else
                    {
                        var why = BrowserEmptyCopy.NoBrowser(_ownKnown, _own, Name);
                        string? actionTitle = null;
                        if (Plugin?.Legacy == true && AskToInstall != null)
                        {
                            actionTitle = _asking ? "Asking…" : $"Ask {Helper} to Update It";
                            _emptyAction = () => Install(BrowserSetupPrompt.Text);
                        }
                        else if (why.Action == BrowserEmptyAction.Plugins && OpenPluginsAction != null)
                        {
                            actionTitle = $"Open {Name}’s Plugins";
                            _emptyAction = OpenPlugins;
                        }
                        empty = new(why.Waiting, !why.Waiting, why.Title, why.Body, actionTitle, !_asking, actionTitle != null ? _emptyProblemText : null);
                    }
                }
                else if (!live)
                {
                    var stalled = link == BrowserWatchLink.Stalled;
                    empty = new(true, false,
                        stalled ? $"{Name}’s Browser Isn’t Responding" : "",
                        stalled ? "It may be busy or restarting. Hermes HQ keeps trying."
                            : link == BrowserWatchLink.Reconnecting ? "Reconnecting…" : "Connecting…",
                        null, false, null);
                }
                break;
        }

        ShowingLastPage = last;
        if (last && _lastPage != null) ShowLastPageOnStage(_lastPage);

        var hasPage = Session != null && Setup is BrowserViewerSetup.Ready;
        var tab = state?.CurrentTab;
        var site = BrowserAddress.Parse(last ? _lastPage?.Url : tab?.Url ?? Row?.Url);
        var addressText = EditingAddress
            ? (state?.CurrentTab?.Url ?? "")
            : (site.Host.Length == 0 ? (live || last ? "" : "Loading…") : site.Host);
        var blank = live && tab != null && BrowserAddress.IsBlank(tab.Url) && !EditingAddress;
        var ask = state?.Ask ?? Row?.Ask;
        var askVisible = hasPage && !last && ask != null && (state?.Control.State ?? BrowserControl.Bot) == BrowserControl.Bot;

        RenderDialog(hasPage ? state?.Dialog : null, held: mine && state?.Control.State == BrowserControl.Person);

        Stage.ShowsCursor = mine && live;
        if (!mine) ResignTyping();
        if (mine != _lastMine)
        {
            _lastMine = mine;
            _host.Haptic(BrowserHaptic.Selection);
            if (mine)
            {
                ShowHint(ControlWords.BrowserGestures);
                OfferPopupsUpdate();
            }
        }

        FollowFieldFocus();

        if (link == BrowserWatchLink.Reconnecting && live && _noticeText == null)
            ShowNotice("Reconnecting…", warning: false, keep: true, render: false);
        if (link == BrowserWatchLink.Live && _noticeText == "Reconnecting…")
            HideNotice(render: false);

        BrowserViewerBarState bar;
        if (last && _lastPage != null)
            bar = new(BrowserViewerBarMode.LastPage, false, false, BrowserLastPage.Caption(Name, _lastPage.At, _now()), null);
        else if (!hasPage)
            bar = new(BrowserViewerBarMode.None, false, false, null, null);
        else if (mine)
            bar = new(BrowserViewerBarMode.Mine, false, Typing, null, null);
        else if (waiting)
            bar = new(BrowserViewerBarMode.Waiting, false, false, null, $"{Name} is finishing a step…");
        else if (someoneElse)
            bar = new(BrowserViewerBarMode.SomeoneElse, false, false, ControlWords.BrowserOther, null);
        else
            bar = new(BrowserViewerBarMode.Watch, live && link == BrowserWatchLink.Live, false, $"{Name} pauses its browser while you use it.", null);

        State = new BrowserViewerState
        {
            Title = Title,
            Setup = Setup,
            Empty = empty,
            StageHidden = empty != null && !live,
            StageShowsCursor = mine && live,
            AddressVisible = hasPage || last,
            AddressText = addressText,
            AddressSecure = !EditingAddress && site.Secure,
            EditingAddress = EditingAddress,
            BlankNoteVisible = blank,
            BlankNoteBody = mine ? "Type an address above to open a page." : $"{Name} hasn’t opened a page in its browser.",
            AskVisible = askVisible,
            AskTitle = $"{Name} needs you",
            AskBody = ask ?? "",
            Tabs = state?.Tabs ?? [],
            CurrentTabId = state?.Tab,
            Follow = state?.Follow ?? true,
            Bar = bar,
            NoticeText = _noticeText,
            HintText = _hintText,
            ShowingLastPage = last,
            Live = live,
            Mine = mine,
            HasPage = hasPage,
            PacingSummary = Session?.Pacing.Summary,
        };
        _host.Render(State);
    }

    // ------------------------------------------------------------------ Actions

    public void RunEmptyAction() => _emptyAction?.Invoke();

    public void TakeControl()
    {
        _host.Haptic(BrowserHaptic.Selection);
        HideNotice();
        Session?.Take();
        Service.Note?.Invoke("take control");
    }

    public void GiveBack()
    {
        _host.Haptic(BrowserHaptic.Selection);
        ResignTyping();
        Session?.Give();
        Service.Note?.Invoke("give back");
    }

    public void CancelTake()
    {
        _host.Haptic(BrowserHaptic.Selection);
        Session?.Give();
    }

    public void NavigateBack() => Session?.Input(new BrowserInput.Nav("back"));
    public void NavigateForward() => Session?.Input(new BrowserInput.Nav("forward"));
    public void Reload() => Session?.Input(new BrowserInput.Nav("reload"));
    public void FollowBot() => Session?.Follow();
    public void ShowTab(string tabId) => Session?.ShowTab(tabId);
    public void CopySelection() => Session?.Input(BrowserInput.Copy.Instance);
    public void SelectAll() => Session?.Input(BrowserInput.SelectAll.Instance);

    public async Task PasteAsync()
    {
        string? text;
        try { text = await _host.ReadClipboardAsync(); }
        catch (Exception) { text = null; }
        if (Closing) return;
        if (string.IsNullOrEmpty(text))
        {
            ShowNotice(ControlWords.NothingToPaste, warning: true);
            return;
        }
        foreach (var chunk in BrowserKeyboard.PasteChunks(text))
            Session?.Input(new BrowserInput.Text(chunk));
        _host.Haptic(BrowserHaptic.Selection);
    }

    private void OnCopied(string text)
    {
        if (string.IsNullOrEmpty(text))
        {
            ShowNotice("Nothing is selected. Double-click a word, or drag across text, then Copy.", warning: true);
            return;
        }
        _host.CopyText(text);
        _host.Haptic(BrowserHaptic.Success);
        ShowNotice("Copied", warning: false);
    }

    // ------------------------------------------------------------------ Address bar

    public bool TryBeginAddressEdit(out string fullUrl)
    {
        fullUrl = "";
        if (Session == null || ShowingLastPage) return false;
        if (!Session.Mine)
        {
            if (!Session.SomeoneElse && !Session.Waiting) StageWatchTap();
            return false;
        }
        EditingAddress = true;
        fullUrl = Session.View?.CurrentTab?.Url ?? "";
        TypingChanged();
        return true;
    }

    public void CommitAddress(string typed)
    {
        if (BrowserAddress.UrlFrom(typed) is { } url)
            Session?.Input(new BrowserInput.Go(url));
        EndAddressEdit();
    }

    public void EndAddressEdit()
    {
        if (!EditingAddress) return;
        EditingAddress = false;
        TypingChanged();
        Render();
    }

    // ------------------------------------------------------------------ Keyboard

    public (BrowserKeyboardSlot Slot, BrowserKeyboardKind Keyboard) WantedSlot
    {
        get
        {
            var field = Session?.Mine == true ? Session.View?.Field : null;
            return BrowserKeyboard.Slot(field?.Focus ?? field?.Under);
        }
    }

    public void RaiseKeyboard(BrowserKeyboardSlot slot, BrowserKeyboardKind kind)
    {
        if (Session?.Mine != true) return;
        _host.RaiseKeyboard(slot, kind);
    }

    public void ToggleKeyboard()
    {
        if (_host.KeyboardFocused) _host.LowerKeyboard();
        else
        {
            var wanted = WantedSlot;
            RaiseKeyboard(wanted.Slot, wanted.Keyboard);
        }
    }

    public void ResignTyping()
    {
        if (_host.KeyboardFocused) _host.LowerKeyboard();
    }

    private void FollowFieldFocus()
    {
        if (!_host.KeyboardFocused || Session?.View?.Field?.Focus == null) return;
        var wanted = WantedSlot;
        if (_host.FocusedSlot != wanted.Slot) RaiseKeyboard(wanted.Slot, wanted.Keyboard);
        else _host.UpdateKeyboard(wanted.Keyboard);
    }

    public void KeyText(string text)
    {
        if (!string.IsNullOrEmpty(text)) Session?.Input(new BrowserInput.Text(text));
    }

    public void KeyPress(string keyName)
    {
        if (!string.IsNullOrEmpty(keyName)) Session?.Input(new BrowserInput.Key(keyName));
    }

    public void KeyboardFocusChanged(bool focused) => TypingChanged();

    private void TypingChanged()
    {
        var now = _host.KeyboardFocused || EditingAddress;
        if (now == Typing) return;
        Typing = now;
        Render();
        if (!now) Service.Post(TakeKeys);
    }

    private void TakeKeys()
    {
        if (!Closing && !Typing && _shownDialogId == null) _host.TakeKeys();
    }

    public void Escape()
    {
        if (EditingAddress) EndAddressEdit();
        else if (_host.KeyboardFocused) KeyPress("Escape");
        else Close();
    }

    // ------------------------------------------------------------------ Page dialogs & popups update offer

    private void RenderDialog(BrowserPageDialog? dialog, bool held)
    {
        if (_shownDialogId is { } shown && (dialog == null || dialog.Id != shown || !held))
        {
            _shownDialogId = null;
            _host.DismissPageDialog();
        }
        if (dialog == null)
        {
            if (_noticedDialogId != null) { _noticedDialogId = null; HideNotice(render: false); }
            return;
        }
        if (!held)
        {
            if (_noticedDialogId != dialog.Id)
            {
                _noticedDialogId = dialog.Id;
                var what = dialog.Kind is BrowserPageDialogKind.Accounts or BrowserPageDialogKind.Signin
                    ? "is asking which account to sign in with"
                    : "is showing a message";
                ShowNotice($"{dialog.Site ?? "The page"} {what}. Take control to answer it.", warning: false, keep: true, render: false);
            }
            return;
        }
        if (_noticedDialogId != null) { _noticedDialogId = null; HideNotice(render: false); }
        if (_shownDialogId != null || _answeredDialogId == dialog.Id) return;
        _shownDialogId = dialog.Id;
        Service.Note?.Invoke($"page dialog shown: {dialog.Kind}");
        _host.Haptic(BrowserHaptic.Selection);
        _host.ShowPageDialog(dialog);
    }

    public void AnswerDialog(int id, bool accept, string? text = null, int? account = null)
    {
        _answeredDialogId = id;
        _shownDialogId = null;
        Session?.Input(new BrowserInput.Answer(id, accept, text, account));
    }

    private void OfferPopupsUpdate()
    {
        if (Plugin == null) return;
        if (AskToInstall == null && (UpdateAddOnAction == null || BrowserAddOn.Need(Plugin.Health) == null)) return;
        if (_shownDialogId != null) return;
        var offered = Service.Prefs.Get(BrowserHealth.PopupsOfferKey);
        if (BrowserHealth.PopupsUpdate(Plugin.Health, offered) is not { } version) return;
        Service.Prefs.Set(BrowserHealth.PopupsOfferKey, version);
        Service.Note?.Invoke("offered the popups update");
        var useSheet = UpdateAddOnAction != null && BrowserAddOn.Need(Plugin.Health) != null;
        _host.OfferPopupsUpdate(useSheet, Helper);
    }

    public void StartUpdate()
    {
        if (UpdateAddOnAction == null || Closing) return;
        Service.Note?.Invoke("viewer: update the add-on");
        Close(UpdateAddOnAction);
    }

    public void Install(string prompt = BrowserSetupPrompt.Text)
    {
        if (AskToInstall == null || _asking || Closing) return;
        var helper = Helper;
        var ask = AskToInstall;
        _asking = true;
        _emptyProblemText = null;
        Render();
        try
        {
            CanAsk?.Invoke();
        }
        catch (Exception e)
        {
            _asking = false;
            Service.Note?.Invoke("install: can't ask the main bot");
            var words = e.Message.Length > 0 ? e.Message : BrowserSetupPrompt.CouldNotSend;
            if (prompt == BrowserSetupPrompt.Update) { ShowNotice(words, warning: true); return; }
            _emptyProblemText = words;
            Render();
            _host.Announce(words);
            return;
        }
        Service.Note?.Invoke("viewer close: asking the main bot");
        Close(() =>
        {
            _ = Task.Run(async () =>
            {
                try { await ask(prompt).ConfigureAwait(false); }
                catch (Exception e)
                {
                    var words = e.Message.Length > 0 ? e.Message : BrowserSetupPrompt.CouldNotSend;
                    Service.Note?.Invoke("ask the main bot failed");
                    Service.Post(() => _host.ShowInstallFailure(helper, words));
                }
            });
        });
    }

    public void OpenPlugins()
    {
        if (Closing || OpenPluginsAction == null) return;
        OpenPluginsAction();
        _host.OpenPlugins();
    }

    // ------------------------------------------------------------------ Notices & Hints

    public void ShowNotice(string text, bool warning, bool keep = false, bool render = true)
    {
        _noticeTimer?.Dispose();
        _noticeTimer = null;
        if (string.IsNullOrEmpty(text)) { HideNotice(render); return; }
        _noticeText = text;
        _hintText = null;
        _host.Announce(text);
        if (warning) _host.Haptic(BrowserHaptic.Warning);
        if (!keep && _timers != null)
            _noticeTimer = _timers.Schedule(TimeSpan.FromSeconds(4), repeats: false, () => HideNotice());
        if (render) Render();
    }

    public void HideNotice(bool render = true)
    {
        _noticeTimer?.Dispose();
        _noticeTimer = null;
        if (_noticeText == null) return;
        _noticeText = null;
        if (render) Render();
    }

    public void ShowHint(string text)
    {
        if (_noticeText != null) return;
        _hintText = text;
        _hintTimer?.Dispose();
        if (_timers != null)
            _hintTimer = _timers.Schedule(TimeSpan.FromSeconds(6), repeats: false, () => { _hintText = null; Render(); });
        Render();
    }

    // ------------------------------------------------------------------ IBrowserStageHost

    public bool StageHasControl => Session?.Mine ?? false;
    public void StageSend(BrowserInput input) => Session?.Input(input);

    public void StageWillTap()
    {
        // Desktop/PC: after a click on the page, what is typed goes to the page right away.
        var wanted = WantedSlot;
        RaiseKeyboard(wanted.Slot, wanted.Keyboard);
    }

    public void StageZoomed() => SendViewSize();

    public void StageWatchTap()
    {
        if (ShowingLastPage) return;
        ShowHint($"{DeviceWord.TapCap} {ControlWords.Take} to click, scroll and type on this page.");
    }

    // ------------------------------------------------------------------ Close

    public void Close(Action? completion = null)
    {
        if (completion != null) _afterClose.Add(completion);
        if (Closing) return;
        Closing = true;
        ResignTyping();
        FlushLastPage();
        Session?.Stop();
        Session = null;
        _subscription?.Cancel();
        _subscription = null;
        CancelCts(ref _ownPollCts);
        CancelCts(ref _checkCts);
        _noticeTimer?.Dispose(); _noticeTimer = null;
        _hintTimer?.Dispose(); _hintTimer = null;
        Stage.Dispose();
        if (Current == this) _current = null;
        Service.Note?.Invoke("viewer close");
        _host.Dismiss();
        var waiting = _afterClose.ToArray();
        _afterClose.Clear();
        foreach (var done in waiting) done();
    }

    private static void CancelCts(ref CancellationTokenSource? cts)
    {
        if (cts == null) return;
        try { cts.Cancel(); } catch (ObjectDisposedException) { }
        try { cts.Dispose(); } catch (ObjectDisposedException) { }
        cts = null;
    }
}
