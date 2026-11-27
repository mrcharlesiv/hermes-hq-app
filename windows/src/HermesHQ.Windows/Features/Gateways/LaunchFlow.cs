using System.Text.Json;
using Hermes.Core;
using Hermes.Core.Auth;
using Hermes.Core.Gateways;
using Hermes.Core.Net;
using Hermes.Core.Offline;
using Hermes.Core.Onboarding;
using Hermes.Core.Rpc;
using Hermes.Core.Shell;
using HermesHQ.Features.Onboarding;
using HermesHQ.Services;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.Gateways;

/// What the window shows from launch until the app is worth showing, and after (App/Offline/LaunchCoordinator.swift):
/// the launch screen while the saved sign-in is read and until the gateway is open with a first list (5 s at most once
/// open); the offline screen when the saved sign-in can't be opened, or the gateway can't be reached before anything is
/// on show; the sign-in form (welcome first on a first run); and the sheets that sign in, add or switch a gateway.
public static partial class LaunchFlow
{
    private enum Stage { Booting, Waiting, Offline, SignIn, App, Stopped }

    private static MainWindow? _window;
    private static DispatcherQueue? _ui;
    private static DispatcherClock? _clock;
    private static Stage _stage = Stage.Booting;
    private static LaunchGate? _gate;
    private static LaunchView? _launch;
    private static OfflineScreenModel? _screen;
    private static OfflineView? _offline;
    private static HermesClient? _watched;
    private static IDisposable? _keychainTimer, _statusTimer;
    private static CancellationTokenSource? _workStop;
    private static readonly List<Task> PendingWork = [];
    private static CancellationToken WorkToken => (_workStop ??= new()).Token;
    private static int _keychainAttempt;
    private static string? _keychainReason;
    private static bool _coldLaunch;

    private static string HintPath => Path.Combine(AppPaths.Root, "last-gateway.json");
    private static string SignedInBeforePath => Path.Combine(AppPaths.Root, "signed-in-before");

    /// The app is on screen (the shell): notices and the launch-chat memory apply.
    public static bool AppShown => _stage == Stage.App;
    private static bool Quitting => _window?.Lifetime.IsClosing == true || AppShutdown.Stopping || _stage == Stage.Stopped;

    // ------------------------------------------------------------------ launch

    public static void AttachWindow(MainWindow window)
    {
        if (Quitting || _window == window) return;
        _clock?.Dispose();
        _window = window;
        _ui = window.DispatcherQueue;
        _clock = new DispatcherClock(_ui);
    }

    public static Task StartAsync()
    {
        if (Quitting) return Task.CompletedTask;
        GatewayNaming.ThisComputer = Environment.MachineName;
        AppState.LaunchChat.Launch();
        _coldLaunch = true;
        Cover();
        Restore();
        return Task.CompletedTask;
    }

    /// The window closed cleanly: no chat of this run counts as crashed.
    public static void Closed() => AppState.LaunchChat.Closed();

    /// The launch screen covers while the saved sign-in is read (launch, Try Again).
    private static void Cover()
    {
        StopOffline();
        _stage = Stage.Booting;
        ShowLaunchScreen();
    }

    private static void ShowLaunchScreen()
    {
        _launch = new LaunchView(LaunchTryAgain, () => DifferentGateway()) { OffersDifferentGateway = KnownGateway() != null };
        var shown = _launch;
        _gate = new LaunchGate(_clock!, Blocker, view =>
        {
            shown.Render(view);
            if (view.Phase == LaunchGate.Phase.Leaving && _stage == Stage.Waiting && shown == _launch) HandOver();
        }, throughTailscale: () => KnownGateway() is { } g && g.Url.Contains(".ts.net"),
           nous: () => KnownGateway() is { } h && Uri.TryCreate(h.Url, UriKind.Absolute, out var u) && OfflineCopy.NousHosted(u));
        _window?.ShowRoot(_launch);
    }

    private static void Restore()
    {
        switch (AppState.SignIn.Restore())
        {
            case SignIn.RestoreState.SignedIn s:
                AppLog.Note("launch", "restore: signed in");
                Activate(AppState.Adopt(s.Session), viaLaunch: true);
                break;
            case SignIn.RestoreState.SignedOut o:
                AppLog.Note("launch", "restore: signed out");
                ShowSignIn(o.Prefill);
                break;
            case SignIn.RestoreState.Unavailable u:
                AppLog.Note("launch", $"restore: {u.Reason}");
                Unavailable(u.Reason);
                break;
        }
    }

    private static LaunchBlocker? Blocker()
    {
        if (AppState.Client is not { } c) return LaunchBlocker.Cover;
        if (c.Rpc.State != ConnectionState.Open) return LaunchBlocker.Cover;
        return c.Bots == null ? LaunchBlocker.Loading : null;
    }

    private static void LaunchTryAgain()
    {
        if (Quitting) return;
        if (_stage == Stage.Waiting && AppState.Client is { } c && _gate?.HasFailed == false)
        {
            c.Rpc.ReconnectNow(); // the dial in flight is dropped and made again; the 12 s start over
            _gate.Retry();
        }
        else
        {
            _gate?.Retry();
            Restore();
        }
    }

    /// An account is in use: the app shows at once when it has something to show; otherwise (`viaLaunch`) the launch
    /// screen waits for a first list. From the shell (a switch, Add Gateway) the shell shows at once with its own
    /// loading state, as the Mac's tabs repaint.
    private static void Activate(HermesClient client, bool viaLaunch)
    {
        if (Quitting) return;
        StopOffline();
        Watch(client);
        RememberHint();
        if (!viaLaunch || Blocker() == null) { HandOver(); return; }
        _stage = Stage.Waiting;
        if (_launch == null || _gate == null || _gate.Current.Phase != LaunchGate.Phase.Shown) ShowLaunchScreen();
        else _window?.ShowRoot(_launch);
        _gate!.Mount();
        StateChanged();
    }

    private static void HandOver()
    {
        _stage = Stage.App;
        StopOffline();
        _gate?.Hide();
        try { Directory.CreateDirectory(AppPaths.Root); File.WriteAllText(SignedInBeforePath, "1"); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        AppLog.Note("launch", "app shown");
        _window?.ShowShell();
    }

    private static void Watch(HermesClient client)
    {
        if (_watched == client) return;
        Unwatch();
        _watched = client;
        client.Rpc.StateChanged += OnState;
        client.Rpc.RetryChanged += OnRetry;
        client.BotsChanged += OnBots;
        Track(ReadResumePreferenceAsync(client, WorkToken));
    }

    private static void OnState(ConnectionState _) => PostChange(StateChanged);
    private static void OnRetry() => PostChange(RefreshStatusSoon);
    private static void OnBots() => PostChange(StateChanged);

    private static void PostChange(Action change)
    {
        // The publisher can be off-thread, or already have taken its invocation list at unsubscribe.
        if (!AppShutdown.Stopping) _ui?.TryEnqueue(() => { if (!Quitting) change(); });
    }

    private static void StateChanged()
    {
        if (AppState.Client is not { } c) return;
        if (c.Rpc.State == ConnectionState.Open) c.StartFirstRead();
        if (c.Rpc.State == ConnectionState.SignedOut && _stage is Stage.Waiting or Stage.Offline) { SessionEnded(); return; }
        switch (_stage)
        {
            case Stage.Waiting:
                // Nothing to show and the gateway can't be reached: the offline screen.
                if (Blocker() == LaunchBlocker.Cover && c.Rpc.State == ConnectionState.Offline) ShowOffline();
                else _gate?.Check();
                break;
            case Stage.Offline:
                if (c.Rpc.State == ConnectionState.Open)
                {
                    // A connection that opens while a sign-in sheet is up leaves the sheet to its owner.
                    if (Blocker() == null) HandOver(); else EnterWaiting();
                }
                else RefreshOffline();
                break;
        }
    }

    /// Connected from the offline screen with a first list still out: the launch screen covers the load.
    private static void EnterWaiting()
    {
        StopOffline();
        _stage = Stage.Waiting;
        ShowLaunchScreen();
        _gate!.Mount();
    }

    // ------------------------------------------------------------------ the offline screen

    /// The saved sign-in can't be opened (§3.5 case A): this screen reads it again on the retry ladder.
    private static void Unavailable(string reason)
    {
        _keychainReason = reason;
        if (_stage != Stage.Offline) { _keychainAttempt = 0; ShowOffline(); }
        else RefreshOffline();
        ScheduleKeychainRetry();
    }

    private static void ShowOffline()
    {
        _stage = Stage.Offline;
        _gate?.Hide();
        _screen = new OfflineScreenModel();
        Fill(_screen);
        _offline = new OfflineView(_screen, OfflineTryAgain, () => DifferentGateway(), SignInAgain, SwitchFromOffline);
        _window?.ShowRoot(_offline);
        RefreshStatus();
        AppLog.Note("launch", $"offline screen: {_screen.Reason ?? "-"}");
    }

    private sealed record GatewayHint(string Url, string AccountName, string? Label, string? Username);

    /// The gateway to name, and to start "Change Address or Sign In" from: the one in use, else the last one opened.
    private static GatewayHint? KnownGateway()
    {
        if (AppState.Account is { } a)
            return new GatewayHint(a.Url, GatewayNaming.AccountName(a.Username), a.Label, a.IsNous ? null : a.Username);
        try { return JsonSerializer.Deserialize<GatewayHint>(File.ReadAllText(HintPath)); }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { return null; }
    }

    /// Nothing secret: an address, the account's display name and the name given on this PC.
    private static void RememberHint()
    {
        if (KnownGateway() is not { } hint || AppState.Account == null) return;
        try { Directory.CreateDirectory(AppPaths.Root); File.WriteAllText(HintPath, JsonSerializer.Serialize(hint)); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    private static void Fill(OfflineScreenModel screen)
    {
        var hint = KnownGateway();
        screen.Url = hint != null && Uri.TryCreate(hint.Url, UriKind.Absolute, out var u) ? u : null;
        screen.Label = hint?.Label;
        screen.AccountName = hint?.AccountName;
        // The other saved gateways, only once the saved sign-in was read.
        screen.OtherGateways = AppState.Client is { } c
            ? [.. AppState.Gateways.Rows.Where(r => r.Key != c.AccountId).Select(r => new OfflineScreenModel.OtherGateway(r.Key, r.Title))]
            : [];
        screen.Reason = AppState.Client is { } client ? client.Rpc.LastFailure ?? screen.Reason : _keychainReason;
    }

    private static void RefreshOffline()
    {
        if (_stage != Stage.Offline || _screen == null) return;
        Fill(_screen);
        _offline?.Render();
        RefreshStatusSoon();
    }

    /// The connection's state and its retry clock arrive separately: read both once they have settled.
    private static void RefreshStatusSoon()
    {
        if (_stage != Stage.Offline || _clock == null) return;
        _statusTimer?.Dispose();
        _statusTimer = _clock.Schedule(TimeSpan.FromMilliseconds(60), RefreshStatus);
    }

    private static void RefreshStatus()
    {
        if (_stage != Stage.Offline || _screen == null || AppState.Client is not { } c) { _offline?.Render(); return; }
        var due = c.Rpc.NextRetry;
        var dialing = due == null && c.Rpc.State is ConnectionState.Connecting or ConnectionState.Open;
        _screen.SetStatus(due, dialing);
        _screen.Reason = c.Rpc.LastFailure ?? _screen.Reason;
        _offline?.Render();
    }

    /// LaunchCoordinator.deinit: detach observers and cancel pending work. Hide() is a live transition: it
    /// renders and schedules a fade. At quit, disarm the clock itself, including deadlines from an older gate.
    internal static async Task StopTimersForQuit()
    {
        _stage = Stage.Stopped;
        var clock = _clock;
        _clock = null; _ui = null; _window = null; _gate = null; _launch = null;
        var pending = StopWorkAsync();
        try
        {
            try { Unwatch(); }
            finally { StopOffline(); }
        }
        finally
        {
            try { clock?.Dispose(); }
            finally { await pending; }
        }
    }

    private static void StopOffline()
    {
        var offline = _offline;
        IDisposable?[] timers = [_keychainTimer, _statusTimer];
        _keychainTimer = _statusTimer = null;
        _screen = null; _offline = null;
        try { offline?.EndCountdown(); }
        finally { ShutdownPlan.CloseEach(timers.OfType<IDisposable>(), timer => timer.Dispose()); }
    }

    private static void OfflineTryAgain()
    {
        if (Quitting || _stage != Stage.Offline || _screen is not { TryAgainEnabled: true } screen) return;
        screen.Problem = null;
        _offline?.FocusStatus();
        if (AppState.Client is { } c)
        {
            // One dial of the saved session now; the ladder keeps its place.
            screen.SetStatus(null, true);
            _offline?.Render();
            c.Rpc.ReconnectNow();
        }
        else ReadSavedSignInAgain();
    }

    private static void ScheduleKeychainRetry()
    {
        if (_clock == null) return;
        _keychainTimer?.Dispose();
        var wait = RetryLadder.Wait(_keychainAttempt);
        _keychainAttempt++;
        if (_screen != null)
        {
            _screen.KeychainReads = _keychainAttempt;
            _screen.SetStatus(DateTimeOffset.UtcNow + wait, false);
            _offline?.Render();
        }
        _keychainTimer = _clock.Schedule(wait, ReadSavedSignInAgain);
    }

    private static void ReadSavedSignInAgain()
    {
        if (_stage != Stage.Offline || AppState.Client != null) return;
        _keychainTimer?.Dispose();
        _screen?.SetStatus(null, true);
        _offline?.Render();
        switch (AppState.SignIn.Restore())
        {
            case SignIn.RestoreState.SignedIn s: Activate(AppState.Adopt(s.Session), viaLaunch: true); break;
            case SignIn.RestoreState.SignedOut o: ShowSignIn(o.Prefill); break;
            case SignIn.RestoreState.Unavailable u: Unavailable(u.Reason); break;
        }
    }

    /// Another saved gateway from the offline screen, as the switcher does; one whose session ended opens the sign-in
    /// prefilled with it.
    private static void SwitchFromOffline(string key) => _ = SwitchAsync(key, viaLaunch: true);

    // ------------------------------------------------------------------ switching

    /// The switcher, Manage Gateways, the offline screen and the sign-in form's "Switch to <name>" all come here.
    public static async Task SwitchAsync(string key, bool viaLaunch = false)
    {
        if (Quitting) return;
        var row = AppState.Gateways.Rows.FirstOrDefault(r => r.Key == key);
        if (row == null || row.IsCurrent || AppState.Gateways.SwitchingTo != null || AppState.Gateways.IsRemoving(key)) return;
        _coldLaunch = false;
        try
        {
            var client = await ResumeSwitchAsync(key);
            Activate(client, viaLaunch || _stage != Stage.App);
        }
        catch (OperationCanceledException) when (Quitting) { }
        catch (GatewayNeedsSignInException e)
        {
            PresentSignInSheet(e.Account, "Sign In", SignInCopy.SignInToSwitch);
        }
        catch (Exception e)
        {
            AppLog.Note("gateways", $"switch failed: {e.GetType().Name}");
            await Alert(GatewaySwitchWords.CouldNotSwitch(row.Title), GatewaySwitchWords.Reason(row.Title));
        }
    }

    private static async Task Alert(string title, string message)
    {
        if (_window?.Content?.XamlRoot is not { } root) return;
        try
        {
            await new ContentDialog { Title = title, Content = message, CloseButtonText = "OK", XamlRoot = root }.ShowAsync();
        }
        catch (Exception e) { AppLog.Error("alert", e); } // another dialog is already open
    }

    private static async Task<HermesClient> ResumeSwitchAsync(string key)
    {
        // Quit joins the outstanding saved read (and its switch rollback), not a sign-in or error dialog.
        // The actual caller still receives the result or exception, including an ordinary expired session.
        var settled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Track(settled.Task);
        try { return await AppState.SwitchToAsync(key, WorkToken); }
        finally { settled.SetResult(); }
    }

    // ------------------------------------------------------------------ sign-in

    /// The sign-in form owns the window: no saved sign-in, a sign-out, or the gateway ended the session. Prefilled with
    /// `prefill`'s address and username; `others`: saved gateways it can switch to instead.
    public static void ShowSignIn(StoredAccount? prefill = null, string? notice = null)
    {
        if (Quitting) return;
        StopOffline();
        _coldLaunch = false;
        _stage = Stage.SignIn;
        _gate?.Hide();
        if (AppState.Client == null) Unwatch();
        prefill ??= AppState.Gateways.Saved().CurrentAccount;
        var signedInBefore = File.Exists(SignedInBeforePath);
        var others = AppState.Gateways.Rows.Where(r => r.Key != prefill?.Key && r.HasSession).Select(r => (r.Key, r.Title)).ToList();
        var view = new OnboardingView(new OnboardingView.Options
        {
            Entry = OnboardingGate.EntryFor(null, prefill?.Url, notice, signedInBefore),
            Address = prefill?.Url ?? "",
            Username = prefill is { IsNous: false } p ? p.Username : "",
            Notice = notice,
            OtherGateways = others,
        });
        view.SignedIn += (s, outcome) => FormSignedIn(view, s, outcome, sheet: false);
        view.SwitchTo += key => _ = SwitchAsync(key, viaLaunch: true);
        _window?.ShowRoot(view);
    }

    private static void Unwatch()
    {
        if (_watched == null) return;
        _watched.Rpc.StateChanged -= OnState;
        _watched.Rpc.RetryChanged -= OnRetry;
        _watched.BotsChanged -= OnBots;
        _watched = null;
    }

    /// Add Gateway…, a signed-out gateway signing in before a switch, and Change Address or Sign In: the form in a
    /// sheet with Cancel. The gateway in use stays until the sign-in succeeds.
    public static void PresentSignInSheet(StoredAccount? prefill, string title, string? notice = null)
    {
        if (Quitting || _window == null) return;
        var view = new OnboardingView(new OnboardingView.Options
        {
            SheetTitle = title,
            Address = prefill?.Url ?? "",
            Username = prefill is { IsNous: false } p ? p.Username : "",
            Notice = notice,
        });
        view.Cancelled += () => _window?.DismissSheet();
        view.SignedIn += (s, outcome) => FormSignedIn(view, s, outcome, sheet: true);
        _window.PresentSheet(view);
    }

    public static void AddGateway() => PresentSignInSheet(null, "Add Gateway");

    /// The saved sign-in can't be read: signing in again asks first, drafts kept aside.
    private static async void SignInAgain()
    {
        try
        {
            if (Quitting || _window?.Content?.XamlRoot is not { } root) return;
            var confirm = new ContentDialog
            {
                Title = OfflineCopy.SignInAgainTitle, Content = OfflineCopy.SignInAgainMessage, PrimaryButtonText = OfflineCopy.SignInAgain,
                CloseButtonText = OfflineCopy.Cancel, DefaultButton = ContentDialogButton.Primary,
            };
            if (await SafeDialog.ShowAsync(root, confirm) == ContentDialogResult.Primary) DifferentGateway();
        }
        catch (Exception ex) { AppLog.Error("launch", ex); }
    }

    private static void DifferentGateway()
    {
        if (Quitting) return;
        var hint = KnownGateway();
        PresentSignInSheet(hint == null ? null : new StoredAccount(hint.Url, hint.Username ?? ""), "Sign In");
    }

    /// A sign-in from the form or a sheet: saved and current. An outdated Hermes shows "Update Hermes" first, locked,
    /// with the app underneath already on the new gateway (DECISION D12).
    private static void FormSignedIn(OnboardingView view, GatewaySession session, SignInOutcome outcome, bool sheet)
    {
        if (Quitting) { session.Dispose(); return; } // the form/sheet has transferred it, but no client will adopt it
        _coldLaunch = false;
        var client = AppState.Adopt(session);
        AppState.Gateways.AccountsChanged();
        void Enter()
        {
            if (Quitting) return;
            if (sheet) _window?.DismissSheet();
            Activate(client, viaLaunch: !sheet || _stage != Stage.App);
        }
        if (outcome.Update is not { } info) { Enter(); return; }
        if (sheet && _stage == Stage.App) _window?.ShowShell(); // the shell under the sheet is on the new gateway now
        var account = AppState.Account ?? session.Account;
        var model = new UpdateHermesModel(GatewayNaming.UpdateName(new Uri(account.Url.TrimEnd('/') + "/"), account.Label), info,
            ct => SignIn.CompatibilityAsync(session, ct), () => _ui?.TryEnqueue(Enter));
        view.PushLocked(new UpdateHermesView(model));
    }

    /// The gateway ended this PC's session: the form prefilled with it, saying why, offering the other gateways.
    public static async void SessionEnded()
    {
        try
        {
            if (Quitting) return;
            var key = AppState.Client?.AccountId;
            await AppState.EndedAsync();
            if (Quitting) return;
            Unwatch();
            var prefill = key != null ? AppState.Gateways.Saved().Find(key) : null;
            ShowSignIn(prefill?.WithoutSession, SignInCopy.Messages["session-ended"]);
        }
        catch (Exception ex) { AppLog.Error("launch", ex); }
    }

    /// Sign Out from the shell's account menu (App/Settings/GatewayPageView.swift `signOut`).
    public static async Task SignOutAsync(XamlRoot root)
    {
        if (Quitting) return;
        var rows = AppState.Gateways.Rows;
        var name = rows.FirstOrDefault(r => r.IsCurrent)?.Title ?? AppState.Client?.Session.Address.Base.Host ?? "";
        var next = rows.FirstOrDefault(r => !r.IsCurrent)?.Title;
        var words = SignOutWords.SignOut(name, next);
        var confirm = new ContentDialog
        {
            Title = words.Title, Content = words.Message, PrimaryButtonText = "Sign Out", CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await SafeDialog.ShowAsync(root, confirm) != ContentDialogResult.Primary || Quitting) return;
        Unwatch();
        var after = await AppState.SignOutAsync();
        if (Quitting) return;
        if (after != null && AppState.SignIn.Resume(after) is { } session) Activate(AppState.Adopt(session), viaLaunch: true);
        else ShowSignIn(after ?? AppState.Gateways.Saved().CurrentAccount);
    }

    // ------------------------------------------------------------------ reopen the last chat

    /// Consumed by the shell's first open: true only for the cold launch's own gateway (a sign-in, a sign-out or a
    /// switch never reopen a chat).
    public static bool TakeColdLaunch()
    {
        var was = _coldLaunch;
        _coldLaunch = false;
        return was;
    }

    /// `display.resume_last_session`, a moment after the link is first open; kept for the next cold launch.
    private static async Task ReadResumePreferenceAsync(HermesClient client, CancellationToken stop)
    {
        var account = client.AccountId;
        // Keep the start of the request and its final store write on the launch UI queue, like quit. A worker
        // could pass the stop check, wait for the preference store's lock, then write after quit began.
        try
        {
            if (AppShutdown.Stopping) return;
            stop.ThrowIfCancellationRequested();
            using (var ready = CancellationTokenSource.CreateLinkedTokenSource(stop))
            {
                ready.CancelAfter(TimeSpan.FromMinutes(5));
                await client.Rpc.WhenReadyAsync(ready.Token);
            }
            await Task.Delay(TimeSpan.FromSeconds(3), stop);
            if (AppShutdown.Stopping) return;
            stop.ThrowIfCancellationRequested();
            var config = await client.Session.GetJsonAsync("/api/config", ct: stop);
            if (!stop.IsCancellationRequested && !AppShutdown.Stopping)
                AppState.LaunchChat.SetResume(LaunchChatMemory.ResumeFrom(config), account);
        }
        catch (Exception e) when (e is GatewayException or OperationCanceledException or ObjectDisposedException) { }
    }

    // Registration and shutdown run on the UI queue.
    private static void Track(Task work)
    {
        PendingWork.RemoveAll(t => t.IsCompletedSuccessfully);
        PendingWork.Add(work);
    }

    private static async Task StopWorkAsync()
    {
        if (_workStop is not { } stop) return;
        _workStop = null;
        var pending = Task.WhenAll(PendingWork);
        PendingWork.Clear();
        // The coordinator bounds the join. A reader that ignores cancellation still cannot apply its result.
        using (stop) { try { stop.Cancel(); } finally { await pending; } }
    }
}

/// One UI clock for the launch gates and offline retries. Timer.Stop alone does not recall an already-posted Tick.
internal sealed class DispatcherClock(DispatcherQueue ui) : ILaunchClock, IDisposable
{
    private readonly HashSet<Alarm> _armed = [];
    private bool _ended;
    public DateTimeOffset Now => DateTimeOffset.UtcNow;

    public IDisposable Schedule(TimeSpan after, Action run)
    {
        var alarm = new Alarm(this);
        if (!_ended && !AppShutdown.Stopping) alarm.Start(ui.CreateTimer(), after, run);
        return alarm;
    }

    public void Dispose()
    {
        _ended = true;
        ShutdownPlan.CloseEach(_armed, alarm => alarm.Dispose());
    }

    private sealed class Alarm(DispatcherClock clock) : IDisposable
    {
        private DispatcherQueueTimer? _timer;
        private Action? _run;

        internal void Start(DispatcherQueueTimer timer, TimeSpan after, Action run)
        {
            _timer = timer; _run = run;
            clock._armed.Add(this);
            try
            {
                timer.Interval = after; timer.IsRepeating = false;
                timer.Tick += Tick;
                timer.Start();
            }
            catch { Dispose(); throw; }
        }

        private void Tick(DispatcherQueueTimer sender, object args)
        {
            var run = _run;
            Dispose();
            if (!AppShutdown.Stopping) run?.Invoke();
        }

        public void Dispose()
        {
            if (_timer is not { } timer) return;
            _timer = null; _run = null;
            clock._armed.Remove(this);
            try { timer.Tick -= Tick; } finally { timer.Stop(); }
        }
    }
}
