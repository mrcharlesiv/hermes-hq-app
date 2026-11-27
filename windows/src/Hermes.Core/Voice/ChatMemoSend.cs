using Hermes.Core.Composer;

namespace Hermes.Core.Voice;

// [WIN-MEMO-SEND-HOST] The chat screen's send half of ChatVoiceHost.swift at 93f984bb1 (`memoSend`, `primarySend`) and
// ChatViewController.sendMemo, without views: what the composer does as a memo goes, and where it goes. The page that
// implements `IMemoChatHost` calls `MemoSend` from its own `MemoSend` and `PrimarySend` from the composer's Send.
//
// Seams: `field` is the composer's text box (read, cleared); `nowSeconds` is CACurrentMediaTime(); `MemoPlayer` is
// MemoPlayer.shared. Not ported: the reply quote a memo goes under (Windows' composer has none yet), the scroll and the
// screen's "awaiting reply" marks (WinUI's), Talk and Read Aloud's `memoSending`.
public sealed class ChatMemoSend(ChatComposer composer, MemoController controller, IMemoChatHost host, MemoAccountStores stores,
    MemoPlayer? player = null, Func<double>? nowSeconds = null)
{
    /// A held memo sent with the keyboard down: nothing raises it for this long (spec §3.8).
    public const double FocusHold = 1.5;

    private readonly Func<double> _now = nowSeconds ?? (() => System.Diagnostics.Stopwatch.GetTimestamp() / (double)System.Diagnostics.Stopwatch.Frequency);

    public double FocusSuppressedUntil { get; private set; }

    /// Programmatic focus of the field may happen now (`focusComposer`); a click on the field always focuses it.
    public bool MayFocusField => _now() >= FocusSuppressedUntil;

    /// The chat's scope now (a new chat learns its stored id after it opened).
    public string Scope => composer.Session.MemoScope ?? composer.Session.DraftScope;

    /// The recorder handed a take to this chat (`IMemoChatHost.MemoSend`): it goes as the next message, with no words.
    public void MemoSend(MemoFile file, bool keyboardWasUp)
    {
        if (!keyboardWasUp) FocusSuppressedUntil = _now() + FocusHold;
        composer.SendMemo(file, "");
    }

    /// The composer's Send while a memo shows: the recorder's (locked, review), or the draft chip's with the field's
    /// words. `field` reads the box and `clearField` empties it. False when there was no memo to send.
    public bool PrimarySend(Func<string> field, Action clearField)
    {
        var phase = controller.State.Phase;
        if (controller.IsTarget(host) && phase is MemoPhase.Locked or MemoPhase.Review)
        {
            controller.Input(new MemoInput.Send());
            return true;
        }
        if (stores.Drafts is not { } drafts || drafts.Draft(Scope) == null) return false;
        if (drafts.Take(Scope) is not { } draft) return false;
        var text = field().Trim();
        clearField();
        if (player?.IsCurrent(draft.Path) == true) player.Stop();
        composer.SendMemo(draft, text);
        return true;
    }
}
