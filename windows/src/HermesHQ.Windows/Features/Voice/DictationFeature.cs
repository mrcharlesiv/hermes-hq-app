using Hermes.Core.Voice;
using HermesHQ.Features.Transcript;
using HermesHQ.Pages;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.Voice;

/// Dictation feature registration & per-chat wiring.
/// Uses Windows on-device speech recognition when available with automatic fallback to gateway
/// `/api/audio/transcribe`, inserting dictated words at the composer caret.
public static class DictationFeature
{
    private static readonly Lazy<DictationController> SharedController = new(BuildController);
    private static bool _registered;

    public static DictationController Controller => SharedController.Value;

    public static void Register()
    {
        if (_registered) return;
        _registered = true;

        AppState.ClientChanged += OnClientChanged;

        ChatExtensions.OnOpen.Add(ctx =>
        {
            if (ctx.Page is not ChatPage) return;
            var host = new DictationHost(ctx);
            ctx.Closed += host.Dispose;
        });
    }

    private static void OnClientChanged(Hermes.Core.HermesClient? client)
    {
        if (client == null && SharedController.IsValueCreated) SharedController.Value.Reset();
    }

    internal static void StopForQuit()
    {
        AppState.ClientChanged -= OnClientChanged;
        if (SharedController.IsValueCreated) SharedController.Value.Reset();
    }

    /// Starts dictation into `ctx`'s composer text box.
    public static void StartDictation(ChatContext ctx)
    {
        ReadAloudFeature.Center.Stop();
        if (TalkFeature.Controller.IsActive) TalkFeature.Controller.End(TalkEnd.Replaced);
        var scope = ctx.Session.MemoScope ?? ctx.Session.DraftScope;
        _ = Controller.StartAsync(scope, ctx.Session.Profile);
    }

    public static void CancelDictation()
    {
        if (SharedController.IsValueCreated) SharedController.Value.Cancel();
    }

    private static DictationController BuildController()
    {
        var capture = WindowsVoiceAudio.CreateDictationCapture();
        var liveWords = WindowsVoiceAudio.CreateLiveWords();
        var fixes = new WordFixes(FilePreferences.Shared);
        return new DictationController(capture, new ActiveClientVoiceGateway(), liveWords, fixes);
    }

    private sealed class DictationHost : IDisposable
    {
        private readonly ChatContext _ctx;
        private readonly DispatcherQueue _queue;
        private readonly DictationRowView _row;
        private bool _disposed;

        public DictationHost(ChatContext ctx)
        {
            _ctx = ctx;
            _queue = DispatcherQueue.GetForCurrentThread();
            _row = new DictationRowView();
            _row.CancelClicked += () => Controller.Cancel();
            _row.DoneClicked += () => _ = Controller.DoneAsync();

            ctx.Shelf.Children.Add(_row);

            Controller.Changed += OnStateChanged;
            Controller.Completed += OnCompleted;
            Controller.NoticePosted += OnNoticePosted;

            UpdateRow(Controller.State);
        }

        private string Scope => _ctx.Session.MemoScope ?? _ctx.Session.DraftScope;

        private void OnStateChanged(DictationState state) =>
            _queue.TryEnqueue(() => UpdateRow(state));

        private void UpdateRow(DictationState state)
        {
            if (_disposed) return;
            _row.Update(state, state.TargetScope == Scope);
        }

        private void OnCompleted(string scope, string text)
        {
            if (scope != Scope) return;
            _queue.TryEnqueue(() =>
            {
                if (_disposed) return;
                InsertAtCaret(_ctx.Composer, text);
                _ctx.Composer.Focus(FocusState.Programmatic);
                _ctx.RefreshComposer();
            });
        }

        private void OnNoticePosted(string scope, MemoNotice notice)
        {
            if (scope != Scope) return;
            _queue.TryEnqueue(() =>
            {
                if (_disposed) return;
                if (VoiceMemosFeature.Controller is { } memoCtrl)
                {
                    memoCtrl.Post(notice, scope);
                }
                else if (_ctx.Page is ChatPage page)
                {
                    page.ShowNotice($"{notice.Title}: {notice.Message}", TimeSpan.FromSeconds(4));
                }
            });
        }

        public static void InsertAtCaret(TextBox box, string dictated)
        {
            var clean = dictated.Trim();
            if (clean.Length == 0) return;

            var existing = box.Text ?? "";
            var start = Math.Clamp(box.SelectionStart, 0, existing.Length);
            var len = Math.Clamp(box.SelectionLength, 0, existing.Length - start);

            var before = existing[..start];
            var after = existing[(start + len)..];
            var needLeadSpace = before.Length > 0 && !char.IsWhiteSpace(before[^1]);
            var needTrailSpace = after.Length > 0 && !char.IsWhiteSpace(after[0]);
            var inserted = (needLeadSpace ? " " : "") + clean + (needTrailSpace ? " " : "");

            box.Text = before + inserted + after;
            box.SelectionStart = before.Length + inserted.Length;
            box.SelectionLength = 0;
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            if (Controller.IsActiveIn(Scope)) Controller.Cancel();
            Controller.Changed -= OnStateChanged;
            Controller.Completed -= OnCompleted;
            Controller.NoticePosted -= OnNoticePosted;
            _ctx.Shelf.Children.Remove(_row);
        }
    }
}

/// Dynamic IVoiceGateway backed by the currently signed-in `AppState.Client`.
internal sealed class ActiveClientVoiceGateway : IVoiceGateway
{
    private static VoiceGateway Require()
    {
        var client = AppState.Client ?? throw new InvalidOperationException("Not signed in to a Hermes gateway.");
        return new VoiceGateway(client);
    }

    public Task<TalkConfig> ConfigAsync(string? profile, CancellationToken ct = default) =>
        Require().ConfigAsync(profile, ct);

    public Task<string> TranscribeAsync(byte[] audio, string mime, string? profile, CancellationToken ct = default) =>
        Require().TranscribeAsync(audio, mime, profile, ct);

    public Task<SpeechClip> SpeakAsync(string text, string? voice, string? profile, CancellationToken ct = default) =>
        Require().SpeakAsync(text, voice, profile, ct);

    public Task<LiveVoiceStatus> LiveStatusAsync(string? profile, CancellationToken ct = default) =>
        Require().LiveStatusAsync(profile, ct);

    public Task<VoiceLease> LiveSessionAsync(string? profile, string? voice, CancellationToken ct = default) =>
        Require().LiveSessionAsync(profile, voice, ct);

    public Task<GrokLiveStatus> GrokStatusAsync(string? profile, CancellationToken ct = default) =>
        Require().GrokStatusAsync(profile, ct);

    public Task<GrokLiveSession> GrokSessionAsync(string? profile, string? voice, CancellationToken ct = default) =>
        Require().GrokSessionAsync(profile, voice, ct);
}
