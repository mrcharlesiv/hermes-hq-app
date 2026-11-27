using Hermes.Core;
using Hermes.Core.Chat;
using Hermes.Core.Groups;
using Hermes.Core.Model;
using Hermes.Core.Notifications;
using Hermes.Core.Questions;
using Hermes.Core.Rpc;
using Hermes.Core.Settings;
using Hermes.Core.Shell;
using HermesHQ.Features.Transcript;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace HermesHQ.Features.Notifications;

/// Local reply and failure toasts (App/Notifications/NotificationHub.swift observeTurnEnd/post/present, and
/// AppModel+Notifications.swift notificationsTurnEnded/notificationsFocus/openNotifiedChat): a chat this run opened
/// that finishes or fails a reply while it isn't on screen raises a toast through the Windows App SDK; the toast's
/// group is the chat (the Mac's thread), and clicking it opens that chat through the Navigator. What alerts, the words
/// and the arguments are Hermes.Core.Notifications (tested on any OS); this file only talks to Windows.
/// Approvals, questions and password prompts held for a chat that isn't on screen raise a toast too
/// (NotificationHub.observeRequest); an approval whose whole command shows carries Approve Once and Deny. Windows has no
/// notification categories: toast buttons are the necessary equivalent of the Mac's UNNotificationAction ("approve",
/// "deny" in DISPATCH_APPROVAL_LOCAL), and a click on one answers through QuestionCenter.AnswerApprovalFromAlertAsync,
/// which sends the in-chat card's own AnswerApprovalAsync, then opens the chat as the Mac's `.foreground` action does.
/// A request answered anywhere (QuestionCenter.Removed) takes its toast with it.
/// Not here yet: the push add-on, the in-app peek, the badge, and the Mac's "Approved" HUD / "Couldn’t Approve" alert
/// after a toast's answer (the outcome is logged; a failed answer leaves the card open in the chat it opened).
public static class NotificationsFeature
{
    private static readonly LocalAlerts Alerts = new(
        () => NotificationPrefs.Load(FilePreferences.Shared),
        () => NotificationPrefs.Banners(FilePreferences.Shared),
        Muted, () => _front, () => _active);
    /// [groups] A member's reply in a room not on screen (GroupsHub.replied): decided over the same local alerts.
    internal static readonly RoomAlerts Rooms = new(Alerts, () => _active);
    private static readonly NotificationOpener Opener = new();
    private static readonly LocalAnswerQueue Answers = new();
    /// Chats this run opened, by runtime id (the Mac's runningChats + its directory): who their alerts are from.
    private static readonly Dictionary<string, ChatSession> Chats = [];
    private static readonly Queue<string> ChatOrder = new();
    private static HermesClient? _client;
    private static ChatSession? _focused;
    private static volatile bool _front = true, _active = true;
    private static bool _registered;
    /// Register ran past the app-only check: the app raises its own alerts (room replies included).
    private static bool _on;
    /// [WIN-56] Why Windows wouldn't register this app for toasts (the exact error), or null.
    private static string? _registrationError;
    private static DispatcherQueueTimer? _waitForShell;
    private static DispatcherQueueTimer? _coldWatch;

    /// [WIN-10 review] This process's token as read at Register, or null when it couldn't be read.
    internal static ProcessElevation? Elevation { get; private set; }

    public static void Register()
    {
        if (Automation.AppOnly)
        {
            AppLog.Note("automation", "app-only: desktop notifications excluded");
            return;
        }
        if (Automation.Enabled && Automation.Desktop == null) return;
        // A shell-launched app need not inherit CI environment variables. Latch proof mode BEFORE subscribing:
        // an absent/wrong marker or a second activation during this process can never fall through to real answers.
        if (!Automation.Enabled && File.Exists(ColdReceipt)) { _fixtureLaunch = true; _coldStamp = TakeColdStamp(); }
        _on = true;
        Settings.SettingsHooks.Notifications.Add(BuildSettingsSection);
        ChatExtensions.OnOpen.Add(OnChatOpen);
        AppState.ClientChanged += OnClient;
        OnClient(AppState.Client);
        // [WIN-10 review] The token Windows App SDK judges (IsSupported() is false for an elevated process): logged at
        // every start, so a refusal names its cause; windows/ci/windows.yml copies the cold relaunch's line.
        Elevation = ProcessToken.Read(out var tokenError);
        AppLog.Note("notify", ProcessElevation.LogLine(Elevation) + (tokenError is null ? "" : $" ({tokenError})"));
        try
        {
            if (!AppNotificationManager.IsSupported())
            {
                _registrationError = ProcessElevation.Unsupported(Elevation);
                AppLog.Note("notify", $"toasts unsupported here: {_registrationError}");
                return;
            }
            var manager = AppNotificationManager.Default;
            // Subscribed before Register, as the SDK asks, so a click that launched the app is never dropped.
            manager.NotificationInvoked += (_, args) => Tapped(args, "NotificationInvoked");
            var icon = Path.Combine(AppContext.BaseDirectory, "Assets", "HermesHQ-256.png");
            var name = Automation.Enabled ? Automation.Desktop!.AppName : _fixtureLaunch ? DesktopProof.AppNameFor(_coldStamp) : "Hermes HQ";
            if (name == null) throw new InvalidOperationException("invalid cold fixture receipt");
            if (File.Exists(icon)) manager.Register(name, new Uri(icon));
            else if (!Automation.Enabled && !_fixtureLaunch) manager.Register();
            else throw new InvalidOperationException("test app registration requires its own icon and display name");
            _registered = true;
            // A click on a toast while the app wasn't running launched it: that click's chat waits for the shell.
            if (AppInstance.GetCurrent().GetActivatedEventArgs() is { Kind: ExtendedActivationKind.AppNotification, Data: AppNotificationActivatedEventArgs launch })
            {
                // [WIN-10 review] The CI's cold-launch step reads these two lines (windows/ci/windows.yml).
                AppLog.Note("notify", "launched by a toast click (Kind AppNotification)");
                Tapped(launch, "launch");
            }
        }
        catch (Exception x)
        {
            _registrationError = ToastLog.Error(x);
            AppLog.Note("notify", $"toast registration failed: {_registrationError}");
        }
    }

    // ------------------------------------------------------------------ the window: in front, minimized

    private static bool _watching;

    private static void WatchWindow()
    {
        if (_watching || App.Window is not { } w) return;
        _watching = true;
        w.Activated += (_, e) =>
        {
            if (AppShutdown.Stopping) return;
            _front = e.WindowActivationState != WindowActivationState.Deactivated;
            _active = !Minimized(w);
        };
        w.AppWindow.Changed += (_, _) =>
        {
            if (AppShutdown.Stopping) return;
            _active = !Minimized(w);
        };
    }

    /// [WIN-EXIT-STOWED-PROBE] The quit's notifications step (Services/AppShutdown.cs, from the walk's exit or the
    /// window's Closed): the SDK's COM server goes with the process, so a later click starts the app again. It was a
    /// silent catch in the window's Closed handler; a throw now reaches the quit's log with its type and HRESULT.
    internal static string UnregisterForQuit()
    {
        _waitForShell?.Stop();
        _waitForShell = null;
        _coldWatch?.Stop();
        _coldWatch = null;
        AppState.ClientChanged -= OnClient;
        if (_client != null)
        {
            _client.Rpc.Event -= OnEvent;
            _client.Questions.Arrived -= OnArrived;
            _client.Questions.Removed -= OnRemoved;
            _client = null;
        }
        Opener.Ready(null);
        Answers.Ready(null);
        if (!_registered) return "not registered";
        _registered = false;
        AppNotificationManager.Default.Unregister();
        return "unregistered";
    }

    private static bool Minimized(Window w) => w.AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized };

    // ------------------------------------------------------------------ chats and the gateway socket

    private static void OnChatOpen(ChatContext ctx)
    {
        WatchWindow();
        var session = ctx.Session;
        lock (Chats) _focused = session;
        Track(session, session.RuntimeId);
        void Bound(string runtime)
        {
            Track(session, runtime);
            if (_focused == session) Focus(session);
        }
        session.RuntimeBound += Bound;
        Focus(session);
        ctx.Closed += () =>
        {
            session.RuntimeBound -= Bound;
            lock (Chats) if (_focused != session) return; else _focused = null;
            Alerts.Focus(null, null);
        };
    }

    /// The chat on screen: its own replies don't alert, and its toasts leave Notification Center (UX study #257).
    private static void Focus(ChatSession session)
    {
        Alerts.Focus(session.RuntimeId, session.StoredId);
        if (!_registered || !NotificationRules.Valid(session.StoredId)) return;
        _ = Withdraw(LocalToast.Key(session.StoredId));
    }

    private static async Task Withdraw(string group)
    {
        try { await AppNotificationManager.Default.RemoveByGroupAsync(group); }
        catch (Exception x) { AppLog.Note("notify", $"withdraw failed: {x.GetType().Name}"); }
    }

    private static void Track(ChatSession session, string? runtime)
    {
        if (string.IsNullOrEmpty(runtime)) return;
        lock (Chats)
        {
            if (!Chats.ContainsKey(runtime)) ChatOrder.Enqueue(runtime);
            Chats[runtime] = session;
            while (ChatOrder.Count > 512) Chats.Remove(ChatOrder.Dequeue());
        }
    }

    private static void OnClient(HermesClient? client)
    {
        if (_client == client) return;
        if (_client != null)
        {
            _client.Rpc.Event -= OnEvent;
            _client.Questions.Arrived -= OnArrived;
            _client.Questions.Removed -= OnRemoved;
        }
        // Signed out or another gateway: what this one alerted, and any tap still waiting, belong to the old one.
        ToastLog.Shared.Clear();
        if (_client != null)
        {
            Alerts.Clear();
            Rooms.Clear();
            lock (Chats) { Chats.Clear(); ChatOrder.Clear(); _focused = null; }
            Opener.TakePending();
            Answers.TakePending();
            if (_registered) _ = ClearAll();
        }
        _client = client;
        Opener.Ready(null);
        Answers.Ready(null);
        if (client == null) return;
        DeliverColdReply(client);
        client.Rpc.Event += OnEvent;
        client.Questions.Arrived += OnArrived;
        client.Questions.Removed += OnRemoved;
        WaitForShell();
    }

    private static void DeliverColdReply(HermesClient client)
    {
        var target = Interlocked.Exchange(ref _fixtureCold, null);
        if (target == null || client.Session.Address.ToString() != DesktopProof.Fixture) return;
        _coldStored = target.Stored;
        _coldFixtureShot = true;
        Opener.Tapped(target); // same readiness queue and navigation as an ordinary click
    }

    private static async Task ClearAll()
    {
        try { await AppNotificationManager.Default.RemoveAllAsync(); }
        catch (Exception x) { AppLog.Note("notify", $"clear failed: {x.GetType().Name}"); }
    }

    /// A turn of a chat this run opened ended (AppModel.gatewayEvent → notificationsTurnEnded).
    private static void OnEvent(RpcEvent e)
    {
        if (TurnEnd.From(e) is not { } end) return;
        ChatSession? chat;
        lock (Chats)
        {
            if (!Chats.TryGetValue(e.SessionId, out chat)) return;
            if (_focused == chat) return; // the open chat reports itself
        }
        var entry = NotificationDirectory.Entry(chat.Profile, chat.StoredId, chat.Title, _client?.Bots);
        var decision = Alerts.ObserveTurnEnd(e.SessionId, e.Seq, end.Failed, end.Text, entry);
        if (decision.Toast is not { } toast)
        {
            AppLog.Note("notify", $"local {(end.Failed ? "turnError" : "message.complete")} skipped: {decision.Skipped}");
            return;
        }
        Show(toast);
    }

    /// [groups] A member's reply landed in a room (GroupEngine.OnReply → GroupsHub.replied): one message.complete toast
    /// from the member in the room unless the room is on screen (RoomAlerts decides; this only shows it).
    internal static void RoomReplied(GroupRoom room, GroupMessage entry, GroupSeat? seat)
    {
        if (!_on) return;
        WatchWindow();
        var decision = Rooms.Replied(room, entry, seat);
        if (decision.Toast is not { } toast)
        {
            AppLog.Note("notify", $"room message.complete skipped: {decision.Skipped}");
            return;
        }
        Show(toast);
    }

    /// A request reached the app (ServerRequestCenter.onArrived → NotificationHub.observeRequest): it alerts unless its
    /// chat is on screen. Who it is from: the chat this run opened, else the request's own bot and stored id.
    private static void OnArrived(string id, PromptKind kind, string runtime, string? profile)
    {
        var client = _client;
        if (client == null) return;
        if (Automation.Enabled || _fixtureLaunch) return; // No request (including an in-app credential prompt) becomes a proof toast.
        var held = client.Questions.Held(id);
        ChatSession? chat;
        lock (Chats) Chats.TryGetValue(runtime, out chat);
        var entry = chat != null ? NotificationDirectory.Entry(chat.Profile, chat.StoredId, chat.Title, client.Bots)
            : (profile ?? held?.Profile) is { } who && held?.StoredId is { } stored ? NotificationDirectory.Entry(who, stored, "", client.Bots)
            : null;
        var decision = Alerts.ObserveRequest(id, kind, runtime, held?.Params, entry);
        if (decision.Toast is not { } toast)
        {
            AppLog.Note("notify", $"local {(kind == PromptKind.Approval ? "approval.request" : "input")} skipped: {decision.Skipped}");
            return;
        }
        Show(toast);
    }

    /// UX study #257: requests that went (answered here or elsewhere, withdrawn, expired): their toasts leave
    /// Notification Center, so no stale Approve Once is left to click.
    private static void OnRemoved(IReadOnlySet<string> ids)
    {
        if (!_registered) return;
        foreach (var id in ids) _ = WithdrawTag(LocalAlerts.RequestTag(id));
    }

    private static async Task WithdrawTag(string tag)
    {
        try { await AppNotificationManager.Default.RemoveByTagAsync(tag); }
        catch (Exception x) { AppLog.Note("notify", $"withdraw failed: {x.GetType().Name}"); }
    }

    private static bool Muted(string profile) =>
        HermesHQ.Features.Bots.ListsHub.Current?.Bots.MuteOf(profile, DateTimeOffset.UtcNow) != null;

    // ------------------------------------------------------------------ the toast

    /// [WIN-56] Every toast decided here goes into the app's own toast log (ToastLog.Shared) with what Windows did with
    /// it: shown, listed only, or not shown and the exact reason (unregistered, as an unpackaged app may be; turned off;
    /// or the post's own error). The log is this run's memory only; AppLog gets the kind and the reason, never the words.
    private static void Show(LocalToast toast)
    {
        if (_fixtureLaunch) return; // this process only observes the cold navigation
        TryShow(toast);
    }

    private static (bool Sent, string? Reason) TryShow(LocalToast toast)
    {
        if (_fixtureLaunch) return (false, "fixture launch"); // this process only observes the cold navigation
        var proof = Automation.Enabled ? Automation.Desktop : null;
        if (Automation.Enabled && (proof == null || _client?.Session.Address.ToString() != DesktopProof.Fixture || !proof.MayShow(toast))) return (false, "automation blocked");
        try
        {
            var setting = _registered ? AppNotificationManager.Default.Setting.ToString() : "";
            if (ToastLog.Blocked(_registered, _registrationError, setting) is { } blocked)
            {
                ToastLog.Shared.Note(toast, ToastDelivery.NotShown, blocked);
                AppLog.Note("notify", $"{toast.Kind} skipped: {blocked}");
                return (false, blocked);
            }
            var manager = AppNotificationManager.Default;
            var builder = new AppNotificationBuilder();
            foreach (var (key, value) in toast.Arguments)
                if (value.Length > 0) builder.AddArgument(key, value);
            if (proof?.NavigationPhase(toast) is { } phase) builder.AddArgument(DesktopProof.Marker, proof.Id(phase));
            if (toast.Title.Length > 0) builder.AddText(toast.Title);
            if (toast.Subtitle.Length > 0) builder.AddText(toast.Subtitle);
            builder.AddText(toast.Body);
            // The Mac's DISPATCH_APPROVAL_LOCAL actions as toast buttons, each carrying its own arguments.
            foreach (var b in toast.Buttons)
            {
                var button = new AppNotificationButton(b.Title);
                foreach (var (key, value) in b.Arguments)
                    if (value.Length > 0) button.AddArgument(key, value);
                builder.AddButton(button);
            }
            builder.SetTag(toast.Tag).SetGroup(toast.Group);
            var notification = builder.BuildNotification();
            notification.SuppressDisplay = toast.SuppressDisplay;
            if (!Alerts.MayPost(toast)) { AppLog.Note("notify", $"{toast.Kind} skipped: signed out mid-post"); return (false, "signed out"); }
            manager.Show(notification);
            ToastLog.Shared.Note(toast, ToastLog.Posted(toast), "");
            AppLog.Note("notify", $"posted {toast.Kind}{(toast.SuppressDisplay ? " (list only)" : "")}");
            return (true, null);
        }
        catch (Exception x)
        {
            var why = $"post failed: {ToastLog.Error(x)}";
            ToastLog.Shared.Note(toast, ToastDelivery.NotShown, why);
            AppLog.Note("notify", $"post {toast.Kind} failed: {ToastLog.Error(x)}");
            return (false, why);
        }
    }

    // ------------------------------------------------------------------ the click

    // Shell cold launches don't inherit the Actions environment. The guarded walk leaves a one-use copy of its
    // public run number for correlation; it grants nothing. Only open the reply on the same fixture account.
    internal static string ColdReceipt => Path.Combine(AppPaths.Root, "fixture-reply-run.txt");
    private static string? TakeColdStamp()
    {
        try
        {
            var file = new FileInfo(ColdReceipt);
            if (!file.Exists || file.Length is < 3 or > 41) return null;
            var stamp = File.ReadAllText(file.FullName);
            file.Delete();
            return stamp;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }
    private static bool _fixtureLaunch;
    private static string? _coldStamp;
    private static NotificationTarget? _fixtureCold;
    private static long _warmActivations;
    internal static long WarmActivations => Interlocked.Read(ref _warmActivations);
    private static string? _coldStored;
    private static bool _coldFixtureShot;

    // Only the SDK calls this. A proof-marked activation (including after a cold start without the runner's
    // environment) must be a plain open of the one fixture chat. It cannot enter the answer queue.
    private static void Tapped(AppNotificationActivatedEventArgs args, string source)
    {
        var arguments = args.Arguments;
        if (_fixtureLaunch || Automation.Enabled || arguments.ContainsKey(DesktopProof.Marker))
        {
            var phase = source == "launch" ? ReplyPhase.Cold : ReplyPhase.Warm;
            if (phase == ReplyPhase.Warm && (!Automation.Enabled || Automation.Desktop == null || _client?.Session.Address.ToString() != DesktopProof.Fixture)) return;
            var expected = phase == ReplyPhase.Cold ? Interlocked.Exchange(ref _coldStamp, null) : Automation.Desktop?.Stamp;
            if (expected == null || DesktopProof.ReplyTarget(args.Argument, arguments, phase, expected) is not { } reply) return;
            if (phase == ReplyPhase.Cold)
            {
                _fixtureCold = reply;
                if (_client != null) DeliverColdReply(_client);
            }
            else
            {
                Interlocked.Increment(ref _warmActivations);
                Opener.Tapped(reply);
            }
            AppLog.Note("notify", $"fixture reply activation {phase} {expected}");
            return;
        }
        var response = NotificationResponse.From(arguments);
        var target = response.Target;
        if (source == "launch") _coldStored = target?.Stored;
        var action = response.Approve is { } a ? (a ? "approve" : "deny") : "open";
        AppLog.Note("notify", target == null ? $"response {action}: no chat" : $"response {action}");
        // A local approval's Approve Once / Deny: the app answers it, then opens its chat (NotificationHub.respond).
        if (response.Request is { } request && response.Approve is { } approve) Answers.Answered(request, approve);
        if (target != null) Opener.Tapped(target);
    }

    /// Opens chats once the signed-in shell is listening and the bots are read (a cold launch's click waits ≤ 10 s,
    /// as openNotifiedChat's does).
    private static void WaitForShell()
    {
        if (AppShutdown.Stopping) return;
        var ui = App.Window?.DispatcherQueue ?? DispatcherQueue.GetForCurrentThread();
        if (ui == null) return;
        _waitForShell?.Stop();
        var tries = 0;
        var timer = ui.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(300);
        timer.IsRepeating = true;
        timer.Tick += (t, _) =>
        {
            if (AppShutdown.Stopping) { t.Stop(); return; }
            var client = AppState.Client;
            if (client == null) { t.Stop(); return; }
            if (!Navigator.Listening || (client.Bots == null && ++tries < 34)) return;
            t.Stop();
            Opener.Ready(target => { if (!AppShutdown.Stopping) ui.TryEnqueue(() => { if (!AppShutdown.Stopping) Open(target); }); });
            if (!Automation.Enabled && !_fixtureLaunch) Answers.Ready((request, approve) => { if (!AppShutdown.Stopping) _ = Answer(client, request, approve); });
        };
        _waitForShell = timer;
        timer.Start();
    }

    /// AppModel+Notifications.swift answerLocal: through the card's own call; one already answered or expired is gone.
    private static async Task Answer(HermesClient client, string request, bool approve)
    {
        try
        {
            var answer = await client.Questions.AnswerApprovalFromAlertAsync(request, approve ? ApprovalChoice.Once : ApprovalChoice.Deny);
            AppLog.Note("notify", answer == AlertAnswer.Sent ? $"local answer sent: {LocalApprovalWords.Sent(approve)}" : "local answer: gone");
        }
        catch (Exception x)
        {
            AppLog.Note("notify", $"local answer failed ({LocalApprovalWords.Title(approve)}): {x.GetType().Name}");
        }
    }

    private static void Open(NotificationTarget target)
    {
        // The signed-in client might have changed while a ready callback waited on the dispatcher.
        if ((Automation.Enabled || _fixtureLaunch) && (AppState.Client?.Session.Address.ToString() != DesktopProof.Fixture
            || target != new NotificationTarget(DesktopProof.Chat, DesktopProof.Profile))) return;
        if (App.Window is { } w)
        {
            if (w.AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } p) p.Restore();
            w.Activate();
        }
        // [groups] A room's alert opens the room (openNotifiedChat: `profile.hasPrefix("room:")`).
        if (NotificationOpen.RoomKey(target) is { } roomKey)
        {
            AppLog.Note("notify", "open chat");
            Navigator.Go(new RoomDestination(roomKey));
            return;
        }
        var bots = AppState.Client?.Bots ?? [];
        var route = NotificationOpen.Route(target, bots, Listed);
        if (route == null) { AppLog.Note("notify", "open chat: nothing to open it with"); return; }
        AppLog.Note("notify", "open chat");
        if (route.Bot is { } name && bots.FirstOrDefault(b => b.Name == name) is { } bot) Navigator.Go(new BotChatDestination(bot));
        else Navigator.Go(new ChatDestination(route.Profile, route.StoredId, route.Title));
        if (_coldStored is { } cold && cold == target.Stored) WatchColdOpen(cold);
    }

    /// [WIN-10 review] Once the chat a launching click named is on screen (≤ 15 s), the app log says so by its key.
    private static void WatchColdOpen(string stored)
    {
        if (AppShutdown.Stopping) return;
        _coldStored = null;
        bool fixtureShot = _coldFixtureShot;
        _coldFixtureShot = false;
        if (App.Window?.DispatcherQueue is not { } ui) return;
        _coldWatch?.Stop();
        var tries = 0;
        var timer = ui.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(250);
        timer.IsRepeating = true;
        timer.Tick += async (t, _) =>
        {
            if (AppShutdown.Stopping) { t.Stop(); return; }
            if (HermesHQ.Pages.ChatPage.Current is { IsLoaded: true } p && p.StoredId == stored)
            {
                t.Stop();
                if (fixtureShot)
                {
                    try { await Automation.SaveColdFixtureChatAsync(p); }
                    catch (Exception e) { AppLog.Note("notify", $"cold fixture screenshot failed: {e.GetType().Name}"); return; }
                }
                AppLog.Note("notify", ToastLog.ColdLaunchOpened(stored));
            }
            else if (++tries >= 60)
            {
                t.Stop();
                AppLog.Note("notify", $"toast cold launch: chat key {ToastLog.ChatKey(stored)} not on screen after 15 s");
            }
        };
        _coldWatch = timer;
        timer.Start();
    }

    /// [WIN-56] Whether a chat this run opened, stored as `stored`, is known by its runtime id (so its alerts can be told).
    internal static bool Tracks(string stored)
    {
        lock (Chats) return Chats.Any(kv => kv.Value.StoredId == stored && kv.Key.Length > 0);
    }

    /// [WIN-56] Whether Windows registered this app for toasts, and the exact error when it didn't.
    internal static (bool Registered, string? Error) Registration => (_registered, _registrationError);

    /// A chat this run opened, by stored id: whose it is and its title.
    private static ListedChat? Listed(string stored)
    {
        lock (Chats)
            return Chats.Values.FirstOrDefault(c => c.StoredId == stored) is { } c ? new ListedChat(c.Profile, c.Title) : null;
    }

    /// Settings › Notifications › Windows Alerts & Add-On card (Send Test Notification + `hermes-hq-push` status).
    private static FrameworkElement? BuildSettingsSection()
    {
        var stack = new Microsoft.UI.Xaml.Controls.StackPanel { Spacing = 8, Padding = new Thickness(14, 12, 14, 12) };
        var status = new Microsoft.UI.Xaml.Controls.TextBlock
        {
            Text = _registered ? "Windows notifications registered." : $"Windows notifications unavailable{(_registrationError is { Length: > 0 } e ? $": {e}" : ".")}",
            TextWrapping = TextWrapping.Wrap,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            FontSize = 12,
        };
        var addon = new Microsoft.UI.Xaml.Controls.TextBlock
        {
            Text = "Checking gateway push add-on…",
            TextWrapping = TextWrapping.Wrap,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            FontSize = 12,
        };
        var testBtn = new Microsoft.UI.Xaml.Controls.Button { Content = "Send Test Notification" };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(testBtn, "notifications.send-test");
        testBtn.Click += (_, _) =>
        {
            var sample = new LocalToast(
                Id: "hermes-test",
                Kind: "test",
                Tag: "hermes-test",
                Group: "hermes-test",
                Title: "Hermes HQ",
                Subtitle: "Test Notification",
                Body: "Notifications are working on this PC.",
                Arguments: [],
                SuppressDisplay: false,
                Epoch: Alerts.Epoch);
            var (sent, reason) = TryShow(sample);
            status.Text = sent ? "Sent a test notification to Windows." : $"Could not send test notification: {reason ?? _registrationError ?? "not registered"}";
        };
        stack.Children.Add(status);
        stack.Children.Add(addon);
        stack.Children.Add(testBtn);
        if (_client is { } client)
        {
            _ = PushPolicy.ReadStatusAsync(client.Session).ContinueWith(t =>
            {
                if (AppShutdown.Stopping) return;
                stack.DispatcherQueue?.TryEnqueue(() =>
                {
                    if (AppShutdown.Stopping) return;
                    if (!t.IsCompletedSuccessfully) { addon.Text = "Push add-on status unavailable."; return; }
                    var s = t.Result;
                    addon.Text = s.Error != null ? $"Push add-on check failed: {s.Error}"
                        : s.Installed ? $"hermes-hq-push {s.Version ?? "installed"} · {(s.Seals ? "sealed" : "active")} · {string.Join(", ", s.Kinds)}"
                        : "hermes-hq-push is not installed on this gateway (local Windows toasts still run while Hermes HQ is open).";
                });
            });
        }
        else addon.Text = "Sign in to a gateway to check hermes-hq-push.";
        return Settings.Kit.Section("Desktop & Add-On", "Local alerts use Windows notifications directly; hermes-hq-push syncs gateway capabilities.", stack);
    }
}
