using Hermes.Core.Composer;
using Hermes.Core.Transcripts;
using Hermes.Core.Voice;
using HermesHQ.Features.Transcript;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.Composer;

// [WIN-MEMO-SEND-WIRE] The chat page's memo send (93f984bb1 App/Chat/Voice/ChatVoiceHost.swift `memoSend`,
// `primarySend`; ChatViewController's sendFailureCard; AppModel's `onDraftReturned`) over Hermes.Core's ChatMemoSend:
//   IMemoChatHost.MemoSend  → ChatMemoSend.MemoSend (the take goes as the next message, the 1.5 s focus hold)
//   the composer's Send     → ChatMemoSend.PrimarySend (the recorder's locked/review take, or the draft chip with the
//                             field's words), before the text send; Ctrl+Enter sets QueuesNextSend first
//   ChatSession.SendFailure  → [WIN-SEND-FAILURE-ONE-CARD] the one "Couldn’t Send" card is TranscriptFeature's, for
//                             typed and memo refusals alike (its ✕, Try Again = the composer's submit)
//   ChatSession.MemoDraftReturned → the field's words (typing done meanwhile is never overwritten: the returned words go
//                             before it); a send Stop withdrew (no card) says why in the switch notice
// The recorder's own surface (mic, waveform, lock, review row: MemoStateChanged…MemoDismissTip) is the recorder lane's;
// until it exists the app has no MemoController (MemoApp.Controller null) and only the draft chip's path is live.
internal sealed class ComposerMemo : IMemoChatHost, IDisposable
{
    private readonly ChatContext _ctx;
    private readonly MemoAccountStores? _stores;
    private readonly ChatMemoSend? _send;
    private readonly Action<string> _setText;
    private readonly Action<string> _notice;
    private readonly Func<bool> _hasDraft;

    public ComposerMemo(ChatContext ctx, ChatComposer composer, MemoAccountStores? stores, MemoController? controller,
        MemoPlayer? player, Action<string> setText, Action<string> notice)
    {
        _ctx = ctx;
        _stores = stores;
        _setText = setText;
        _notice = notice;
        if (stores != null && ctx.Session.MemoStores == null) ctx.Session.MemoStores = stores;
        if (stores != null && controller != null) _send = new ChatMemoSend(composer, controller, this, stores, player);
        _hasDraft = () => HasDraft;
        ctx.HasDraftContent.Add(_hasDraft);
        ctx.Session.Changed += OnChanged;
        ctx.Session.MemoDraftReturned += OnDraftReturned;
    }

    /// The draft chip waits in this chat's composer.
    public bool HasDraft => _stores?.Drafts is { } drafts && drafts.Draft(Scope) != null;

    private string Scope => _ctx.Session.MemoScope ?? _ctx.Session.DraftScope;

    /// The composer's Send while a memo shows: true when a memo went (the field is cleared).
    public bool PrimarySend() =>
        _send?.PrimarySend(() => _ctx.Composer.Text, () => _setText("")) == true;

    // MARK: IMemoChatHost

    public bool IsOnScreen => _ctx.Page.IsLoaded && _ctx.Page.XamlRoot != null;
    public bool CanSendMemo => IsOnScreen && _ctx.Dock.Content == null;
    public void MemoSend(MemoFile file, bool keyboardWasUp) => _send?.MemoSend(file, keyboardWasUp);
    public void MemoStateChanged() => _ctx.Page.DispatcherQueue.TryEnqueue(() => _ctx.RefreshComposer());
    public void MemoLevelChanged() { }
    public void MemoWordsChanged() { }
    public void MemoFocusStatus() { }
    /// The recorder lane asks first; until then a long take is kept (never deleted unasked).
    public void MemoConfirmDelete(double seconds, bool recording, Action<bool> answer) => answer(false);
    public void MemoShowTip(MemoTip tip) { }
    public void MemoDismissTip() { }

    // MARK: The refusal

    private void OnChanged() => _ctx.Page.DispatcherQueue.TryEnqueue(Update);

    private void Update() => _ctx.RefreshComposer();

    private void OnDraftReturned(string text, string reason) => _ctx.Page.DispatcherQueue.TryEnqueue(() =>
    {
        var typed = _ctx.Composer.Text;
        if (typed.Length == 0) _setText(text);
        else if (text.Length > 0 && typed != text && !typed.StartsWith(text + "\n", StringComparison.Ordinal)) _setText(text + "\n" + typed);
        // A refused send says why in the "Couldn’t Send" card; only a send Stop withdrew says so in a notice.
        if (_ctx.Session.SendFailure == null) _notice(reason);
        _ctx.RefreshComposer();
    });

    public void Dispose()
    {
        _ctx.Session.Changed -= OnChanged;
        _ctx.Session.MemoDraftReturned -= OnDraftReturned;
        _ctx.HasDraftContent.Remove(_hasDraft);
    }
}
