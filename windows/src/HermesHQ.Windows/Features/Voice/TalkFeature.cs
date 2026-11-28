using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Voice;
using HermesHQ.Features.Transcript;
using HermesHQ.Pages;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.Voice;

/// Port of App/Chat/Voice/ChatTalkHost.swift & TalkFeature:
/// registers Talk button + Voice Options menu in `ctx.ComposerTrailing`, hosts `TalkDockView`
/// in `ctx.Dock`, hosts `TalkAwayPillView` in `ctx.TranscriptOverlay` when navigated away from
/// an active Talk chat, intercepts typed stop phrases, and wires `VoiceConnectedChime`.
public static class TalkFeature
{
    private static readonly Lazy<TalkController> SharedController = new(BuildController);
    private static readonly Dictionary<string, (string Profile, string StoredId, string Title)> KnownChats = [];
    private static SessionTalkBridge? _activeBridge;
    private static bool _registered;

    public static TalkController Controller => SharedController.Value;

    public static void Register()
    {
        if (_registered) return;
        _registered = true;

        AppState.ClientChanged += OnClientChanged;

        ChatExtensions.OnOpen.Add(ctx =>
        {
            if (ctx.Page is not ChatPage) return;
            var host = new ChatTalkHost(ctx);
            ctx.Closed += host.Dispose;
        });
    }

    private static void OnClientChanged(Hermes.Core.HermesClient? client)
    {
        if (client == null && SharedController.IsValueCreated)
            SharedController.Value.Reset();
    }

    internal static void StopForQuit()
    {
        AppState.ClientChanged -= OnClientChanged;
        if (SharedController.IsValueCreated) SharedController.Value.Reset();
        _activeBridge?.Dispose();
        _activeBridge = null;
    }

    /// Starts (or stops) a voice conversation in `ctx`, showing the first-time intro dialog if needed.
    public static void StartTalk(ChatContext ctx, TalkEngine? engine = null)
    {
        _ = StartTalkAsync(ctx, engine);
    }

    public static async Task StartTalkAsync(ChatContext ctx, TalkEngine? engine = null)
    {
        var scope = ctx.Session.MemoScope ?? ctx.Session.DraftScope;
        if (Controller.IsActiveIn(scope))
        {
            Controller.End(TalkEnd.User);
            return;
        }

        var accepted = await TalkIntroDialog.EnsureIntroAcceptedAsync(ctx.Page.XamlRoot, ctx.Session.Title, isLiveOffered: true);
        if (!accepted) return;

        ReadAloudFeature.Center.Stop();
        if (DictationFeature.Controller.IsActive) DictationFeature.Controller.Cancel();

        RememberChat(scope, ctx.Session);
        _activeBridge?.Dispose();
        var bridge = new SessionTalkBridge(ctx.Session);
        _activeBridge = bridge;
        await Controller.StartAsync(bridge, engine);
    }

    /// Hook for composer send interception: ends active Talk when user types "stop" / "hang up".
    public static bool InterceptTypedSend(ChatContext ctx, string typed)
    {
        if (!SharedController.IsValueCreated) return false;
        var scope = ctx.Session.MemoScope ?? ctx.Session.DraftScope;
        return SharedController.Value.InterceptTypedSend(scope, typed);
    }

    private static void RememberChat(string scope, ChatSession session)
    {
        lock (KnownChats) KnownChats[scope] = (session.Profile, session.StoredId, session.Title);
    }

    private static TalkController BuildController()
    {
        var capture = WindowsVoiceAudio.CreateTalkCapture();
        var speaker = WindowsVoiceAudio.CreateTalkSpeaker();
        var liveWords = WindowsVoiceAudio.CreateLiveWords();
        var ctrl = new TalkController(
            capture,
            speaker,
            FilePreferences.Shared,
            new ActiveClientVoiceGateway(),
            WindowsVoiceAudio.CreateLiveTransport,
            liveWords,
            WindowsVoiceAudio.SystemEvents);

        ctrl.ChimeRequested += VoiceConnectedChime.Play;
        ctrl.RecordCompleted += _ =>
        {
            _activeBridge?.Dispose();
            _activeBridge = null;
        };
        ctrl.SetRoutes(WindowsVoiceAudio.ListOutputRoutes());
        ctrl.ReturnToChatRequested += scope =>
        {
            (string Profile, string StoredId, string Title) target;
            lock (KnownChats)
            {
                if (!KnownChats.TryGetValue(scope, out target)) return;
            }
            Navigator.Go(new ChatDestination(target.Profile, target.StoredId, target.Title));
        };
        return ctrl;
    }

    private sealed class SessionTalkBridge : ITalkChatBridge, IDisposable
    {
        private readonly ChatSession _session;
        private bool _disposed;

        public SessionTalkBridge(ChatSession session)
        {
            _session = session;
            _session.Changed += OnChanged;
        }

        public string Scope => _session.MemoScope ?? _session.DraftScope;
        public string Profile => _session.Profile;
        public string BotName => string.IsNullOrWhiteSpace(_session.MemoBotName) ? _session.Title : _session.MemoBotName;
        public bool IsBusy => _session.Busy;

        public bool IsAnsweringVoiceRecord
        {
            get
            {
                if (!_session.Busy) return false;
                var lastUser = _session.Messages.LastOrDefault(m => m.Role == Role.User);
                return lastUser != null && VoiceChatRecordCodec.IsVoiceChatRecord(lastUser.Text);
            }
        }

        public event Action? Changed;

        public SpokenReply? NewestReply() => SpokenReply.Newest(_session.Messages);

        public IReadOnlyList<(string Role, string Text)> RecentHistory(int maxMessages = 10)
        {
            var msgs = _session.Messages;
            var list = new List<(string Role, string Text)>();
            for (var i = Math.Max(0, msgs.Count - maxMessages); i < msgs.Count; i++)
            {
                var m = msgs[i];
                if (m.Role is not (Role.User or Role.Assistant)) continue;
                if (m.Role == Role.User && VoiceChatRecordCodec.SeedSummary(m.Text) is { } voiceSeed)
                {
                    list.Add(("user", voiceSeed));
                    continue;
                }
                var text = m.Role == Role.Assistant ? SpokenReply.Of(m).Text : m.Text;
                if (m.Role == Role.Assistant && string.Equals(text.Trim(), "NO_REPLY", StringComparison.Ordinal))
                    continue;
                if (!string.IsNullOrWhiteSpace(text))
                    list.Add((m.Role == Role.User ? "user" : "assistant", text));
            }
            return list;
        }

        public async Task<SendOutcome> SendTurnAsync(string text, CancellationToken ct = default)
        {
            // Never steer a real spoken/delegated turn into a running NO_REPLY voice-record turn.
            if (IsAnsweringVoiceRecord)
                await _session.StopAsync();
            return await _session.SendAsync(text, ct);
        }

        /// Queues a `[Voice chat transcript …]` record as an ordinary (non-hidden) user message, waiting for any
        /// running reply to finish instead of steering into it (whose reply the `NO_REPLY` note would silence).
        public Task<SendOutcome> SendVoiceRecordAsync(string text, CancellationToken ct = default) =>
            QueueVoiceRecordAsync(_session, text, ct);

        public Task StopTurnAsync() => _session.StopAsync();

        private static async Task<SendOutcome> QueueVoiceRecordAsync(ChatSession session, string text, CancellationToken ct)
        {
            if (string.IsNullOrWhiteSpace(text)) return SendOutcome.Refused;
            if (session.Busy)
            {
                var idle = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                void OnTurnEnded(bool isIdle)
                {
                    if (isIdle || !session.Busy) idle.TrySetResult(true);
                }
                void OnChanged()
                {
                    if (!session.Busy) idle.TrySetResult(true);
                }
                session.TurnEnded += OnTurnEnded;
                session.Changed += OnChanged;
                try
                {
                    if (!session.Busy) idle.TrySetResult(true);
                    using var waitCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                    waitCts.CancelAfter(TimeSpan.FromMinutes(3));
                    using var reg = waitCts.Token.Register(() => idle.TrySetResult(false));
                    await idle.Task;
                }
                finally
                {
                    session.TurnEnded -= OnTurnEnded;
                    session.Changed -= OnChanged;
                }
                if (ct.IsCancellationRequested || AppShutdown.Stopping) return SendOutcome.Refused;
                return await session.SendAsync(text, ct, queued: true);
            }
            return await session.SendAsync(text, ct, queued: false);
        }

        private void OnChanged() => Changed?.Invoke();

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            _session.Changed -= OnChanged;
        }
    }

    private sealed class ChatTalkHost : IDisposable
    {
        private readonly ChatContext _ctx;
        private readonly DispatcherQueue _queue;
        private readonly DispatcherQueueTimer _clockTimer;
        private readonly Button _talkBtn;
        private readonly FontIcon _talkIcon;
        private readonly TalkDockView _dockView;
        private readonly TalkAwayPillView _awayPill;
        private readonly Func<string, bool> _stopSendHandler;
        private bool _ownsDock;
        private bool _disposed;

        public ChatTalkHost(ChatContext ctx)
        {
            _ctx = ctx;
            _queue = DispatcherQueue.GetForCurrentThread();

            RememberChat(Scope, ctx.Session);

            _talkIcon = new FontIcon { Glyph = "\uE995", FontSize = 15 };
            _talkBtn = new Button
            {
                Content = _talkIcon,
                MinWidth = 34,
                MinHeight = 34,
                Padding = new Thickness(6),
                CornerRadius = new CornerRadius(17),
                Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
            };
            AutomationProperties.SetAutomationId(_talkBtn, "composer.talk");
            AutomationProperties.SetName(_talkBtn, "Start Voice Conversation");
            ToolTipService.SetToolTip(_talkBtn, "Start voice conversation (right-click for Voice options)");
            _talkBtn.Click += (_, _) => StartTalk(_ctx);
            _talkBtn.ContextRequested += (_, e) =>
            {
                var menu = TalkRouteMenu.BuildVoiceOptionsFlyout(_ctx, Controller, liveOffered: true, grokOffered: true);
                menu.ShowAt(_talkBtn);
                e.Handled = true;
            };

            _dockView = new TalkDockView(Controller);
            _awayPill = new TalkAwayPillView();
            _awayPill.ReturnClicked += () => Controller.RequestReturnToChat();
            _awayPill.EndClicked += () => Controller.End(TalkEnd.User);

            ctx.ComposerTrailing.Children.Add(_talkBtn);
            ctx.TranscriptOverlay.Children.Add(_awayPill);

            _stopSendHandler = typed => InterceptTypedSend(_ctx, typed);
            ctx.SendHandlers.Add(_stopSendHandler);

            ctx.WaitsOnUserChanged += OnWaitsOnUserChanged;
            Controller.StateChanged += OnTalkStateChanged;
            Controller.LevelChanged += OnTalkLevelChanged;
            Controller.RecordCompleted += OnRecordCompleted;

            _clockTimer = _queue.CreateTimer();
            _clockTimer.Interval = TimeSpan.FromSeconds(1);
            _clockTimer.Tick += (_, _) =>
            {
                if (Controller.IsActiveIn(Scope)) Controller.Tick(1.0);
            };

            Controller.ScreenChanged(Scope);
            ApplyState(Controller.CurrentState);
        }

        private string Scope => _ctx.Session.MemoScope ?? _ctx.Session.DraftScope;

        private void OnWaitsOnUserChanged()
        {
            if (Controller.IsActiveIn(Scope))
                Controller.NoteExternalQuestion(_ctx.WaitsOnUser);
        }

        private void OnTalkStateChanged(TalkState state) =>
            _queue.TryEnqueue(() => ApplyState(state));

        private void OnTalkLevelChanged(double level) =>
            _queue.TryEnqueue(() =>
            {
                if (_disposed) return;
                if (_ownsDock) _dockView.SetLevel(level);
                else _awayPill.SetLevel(level);
            });

        private void OnRecordCompleted(VoiceChatRecord record)
        {
            if (record.ChatScope != Scope) return;
            _queue.TryEnqueue(() =>
            {
                if (_disposed) return;
                if (_ctx.Page is ChatPage page) page.ShowNotice(record.Caption, TimeSpan.FromSeconds(4));
            });
        }

        private void ApplyState(TalkState state)
        {
            if (_disposed || AppShutdown.Stopping) return;

            var forThisChat = state.ActiveScope == Scope && state.Dock.Phase != TalkDockPhase.None;
            if (forThisChat)
            {
                _dockView.Update(state);
                if (!ReferenceEquals(_ctx.Dock.Content, _dockView))
                {
                    _ctx.Dock.Content = _dockView;
                    _ownsDock = true;
                }
                if (state.IsActive && !_clockTimer.IsRunning) _clockTimer.Start();
                else if (!state.IsActive) _clockTimer.Stop();
            }
            else
            {
                _clockTimer.Stop();
                if (_ownsDock && ReferenceEquals(_ctx.Dock.Content, _dockView))
                {
                    _ctx.Dock.Content = null;
                    _ownsDock = false;
                }
            }

            _talkIcon.Foreground = ThemeBrushes.Get(forThisChat && state.IsActive
                ? "AccentFillColorDefaultBrush"
                : "TextFillColorSecondaryBrush");
            AutomationProperties.SetName(_talkBtn, forThisChat && state.IsActive
                ? "End Voice Conversation"
                : "Start Voice Conversation");

            _awayPill.Update(state.AwayPill, state.Level);
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            _clockTimer.Stop();
            _ctx.WaitsOnUserChanged -= OnWaitsOnUserChanged;
            Controller.StateChanged -= OnTalkStateChanged;
            Controller.LevelChanged -= OnTalkLevelChanged;
            Controller.RecordCompleted -= OnRecordCompleted;
            _ctx.SendHandlers.Remove(_stopSendHandler);
            if (_ownsDock && ReferenceEquals(_ctx.Dock.Content, _dockView)) _ctx.Dock.Content = null;
            _ctx.ComposerTrailing.Children.Remove(_talkBtn);
            _ctx.TranscriptOverlay.Children.Remove(_awayPill);
            Controller.ScreenChanged(null);
        }
    }
}
