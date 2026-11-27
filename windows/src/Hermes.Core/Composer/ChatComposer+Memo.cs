using Hermes.Core.Chat;
using Hermes.Core.Voice;

namespace Hermes.Core.Composer;

// [WIN-MEMO-SEND-HOST] Where a voice memo goes from the composer (LiveChatSession+Memo.swift `sendMemo` at 93f984bb1,
// and its queue hooks in LiveChatSession.swift): while a reply runs it goes into that reply as typed words do (staged,
// then `session.redirect` with its prompt); a queued send (Ctrl+Enter, Send While Replying set to Queue), or a reply
// that can't take a steer, waits in the queue as a memo row, drained with `queued:true`; otherwise it goes now.
public sealed partial class ChatComposer
{
    /// Sends `memo` (with `typed` beside it, possibly "") as this chat's next message.
    public void SendMemo(MemoFile memo, string typed)
    {
        var toQueue = Queue.QueuesNextSend;
        Queue.QueuesNextSend = false;
        if (!toQueue && Session.MemoSteers(typed, Queue.RedirectUnsupported))
        {
            SteerMemo(memo, typed);
            return;
        }
        Queue.Send(typed, payload: memo, steer: false);
    }

    /// The memo's bubble shows at once under the running reply; it stages, then steers after any steer still out. Stop
    /// while it stages hands it back as the draft; not taken, or staging failed, it joins the queue as a memo row.
    public Task SteerMemo(MemoFile memo, string typed)
    {
        var local = Session.BeginMemoSteer(memo, typed);
        var staged = Session.StageMemoSteerAsync(local);
        return Queue.SteerStaged(local, staged, typed, memo, taken =>
        {
            if (taken) Session.MemoSteerTaken(local);
            else Session.MemoSteerNotTaken(local);
        });
    }

    /// Remove on a queued memo returns it as the draft chip; Delete throws the recording away.
    private void MemoRowTaken(QueuedMessage item, bool discarded)
    {
        if (item.Payload is not MemoFile memo) return;
        if (discarded) Session.MemoQueueItemDiscarded(memo);
        else Session.MemoQueueItemRemoved(memo);
    }

    /// A chat that keeps no queue beyond its screen is left: its queued memos come back as drafts (the Mac's
    /// `memoQueueLeaving`); the app's chats keep them queued.
    public void MemoQueueLeaving()
    {
        var memos = Queue.Items.Where(i => i.Payload is MemoFile).ToList();
        if (memos.Count == 0) return;
        foreach (var item in memos) Queue.Drop(item.Id);
        Session.MemoQueueLeaving([.. memos.Select(i => new MemoDraft((MemoFile)i.Payload!, i.Text))]);
    }
}
