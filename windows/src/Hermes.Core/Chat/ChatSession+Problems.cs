// [WIN-COMPOSER-CARD-IDS] The chat's problem card beyond the locked chat (93f984bb1 HermesKit/Chat/LiveChatSession.swift
// `sessionProblem`, `resumeNow`'s failure path, `noteResumeFailed`, `retryAfterProblem`, `send`'s `sessionProblem = nil`;
// LiveChatSession+Events.swift's `error` with no turn in flight; HermesKit/Chat/Transcript/TurnErrorCopy.swift
// `SessionProblem.make` / `reopenFailed`):
//   - an `error` frame with no turn in flight is a card above the composer (`SessionProblem.Make`: Choose a Model for a
//     usage limit or a model that won't start, else Try Again; nothing for the ignored ones), not an error row;
//   - a resume that got no answer in time on both attempts says "Couldn’t reopen this chat" (Try Again);
//   - a resume that lands clears a reopen problem and the locked chat's (the chat came back);
//   - a fresh send clears the card (§6.2), as it clears Couldn’t Send;
//   - Try Again resumes once more when the problem was a reopen or nothing is bound, then reads the page when the
//     chat shows nothing or its open failed, and a read that lands clears the page's own failure ([WIN-PROBLEM-CARD-REST]);
//   - [WIN-PROBLEM-CARD-REST] a resume refused for a locked chat is the locked chat's card, and only that one.

using Hermes.Core.Net;

namespace Hermes.Core.Chat;

public sealed partial class ChatSession
{
    /// `SessionProblem.make(text:botName:)` for an `error` that came with no turn in flight; the ignored ones raise nothing.
    internal void RaiseProblem(string words)
    {
        var problem = Transcripts.SessionProblem.Make(words, BotName);
        if (problem == null || problem == SessionProblem) return;
        SessionProblem = problem;
        Changed?.Invoke();
    }

    /// `send`'s `sessionProblem = nil`: a new send answers the chat's problem card.
    private void ClearProblemForSend()
    {
        if (SessionProblem == null) return;
        SessionProblem = null;
        Changed?.Invoke();
    }

    /// `noteResumeFailed`: both resume attempts got no answer in time. Only a timeout: a lost link is the connection's
    /// own state and a cancelled wait says nothing. Every resume here is the waiting kind, so the words are `starting`.
    /// [WIN-PROBLEM-CARD-REST] Before it, `resumeNow`'s `if isChatLocked(rpc) { sessionProblem = .chatLocked(detail:) }`:
    /// a resume refused because Hermes won't open this chat (`4001 profile_mismatch`) is the locked chat's card, never
    /// "Couldn’t Send" as well (a send that resumed first is refused into it: SetSendFailure keeps one card).
    private void NoteResumeFailed(GatewayException e)
    {
        if (IsChatLocked(e)) { ShowChatLocked(e.Message); return; }
        if (e.Code != "timeout") return;
        SessionProblem = Transcripts.SessionProblem.ReopenFailed(starting: true);
        Changed?.Invoke();
    }

    /// `resumeNow`: a resume that lands clears the reopen problem and the locked chat's (`[transcript] the chat came back`).
    private void NoteResumed()
    {
        if (SessionProblem is not { } p || !(p.Reopen || p.Primary == Transcripts.SessionProblemPrimary.NewChat)) return;
        SessionProblem = null;
    }

    /// [WIN-PROBLEM-CARD-REST] The open's first read failed (the Mac's `openError`): the page says "Couldn't load this
    /// chat" until a read succeeds again.
    public bool OpenFailed { get; private set; }

    /// [WIN-PROBLEM-CARD-REST] A read after a failed open succeeded (`start()`'s `beginOpen(failedOpen:)` clears
    /// `openError`): the page takes its own failure away and the chat is open. Raised on a background thread.
    public event Action? OpenRecovered;

    /// The problem card's Try Again (`retryAfterProblem`): the card goes; a reopen problem or an unbound chat resumes once
    /// more (its own quiet retry inside), and a chat whose open failed or that shows nothing reads its newest page
    /// (`if self.openError != nil || self.messages.isEmpty { self.start() }`).
    public async Task RetryAfterProblemAsync()
    {
        var wasReopen = SessionProblem?.Reopen == true;
        SessionProblem = null;
        Changed?.Invoke();
        if (wasReopen || _runtimeId == null)
        {
            try { await ResumeAsync(CancellationToken.None); } catch (GatewayException) { /* the card says it again */ }
        }
        if (OpenFailed || Messages.Count == 0)
        {
            try { await RefreshAsync(CancellationToken.None); } catch (GatewayException) { return; /* the page's own failure stays */ }
            if (!OpenFailed) return;
            OpenFailed = false;
            OpenRecovered?.Invoke();
        }
    }
}
