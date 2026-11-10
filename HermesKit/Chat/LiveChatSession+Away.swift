// Verify round 3: messages queued behind a running reply are never lost by leaving the chat. They are kept per chat in
// the account's `QueueStash` (an app kill keeps them too), and a chat left with a queue still waiting keeps listening
// off screen until the queue is out (`drainingAway`; the web drains a chat left in the background,
// app/session/hooks/use-background-queue-drain.ts). The app model holds such a chat and opens it again instead of a new
// one, so its queue card, running reply and next send are the same ones the user left.

import Foundation

extension LiveChatSession {
    /// The chat's queue scope is known once its stored id is (a queue only exists after a send, which resolves it).
    private var queueScope: String? { keepsQueue && storedSessionId != nil ? layoutScope : nil }

    /// Takes over what waits in the stash for this chat (at init, on screen again, once the stored id resolves).
    /// `keepingOwn`: messages queued here before the chat had a scope were never in the stash; they stay, after the
    /// stashed ones (older), and their fresh send's unpark stands.
    func claimStashedQueue(keepingOwn: Bool = false) {
        guard let scope = queueScope else { return }
        let stash = QueueStash.shared
        if stash.owns(accountId: account.id, scope: scope, owner: self) { return }
        guard let found = stash.claim(accountId: account.id, scope: scope, owner: self) else { return }
        AppLog.trace("send", "queue from the stash adopted by \(logIds): \(found.items.count) messages, parked=\(found.parked), had \(queuedMessages.count)\(keepingOwn ? " (kept)" : "")")
        if keepingOwn, !queuedMessages.isEmpty {
            let stashedIds = Set(found.items.map(\.id))
            adoptStashedQueue(found.items + queuedMessages.filter { !stashedIds.contains($0.id) }, parked: isQueueParked)
        } else {
            adoptStashedQueue(found.items, parked: found.parked)
        }
        scheduleFlush()
    }

    /// Lets go of the stash entry (what is left in it waits for the next open).
    func releaseStashedQueue() {
        guard let scope = queueScope else { return }
        QueueStash.shared.release(accountId: account.id, scope: scope, owner: self)
    }

    /// The stored id resolved (a bot's chat opened before the roster named it): a queue waiting for it is taken, and
    /// one made meanwhile is kept from now on.
    func queueScopeResolved() {
        claimStashedQueue(keepingOwn: true)
        stashQueue()
    }

    /// The queue (or its park) changed: written through while this chat owns it (never over another live chat's).
    func stashQueue() {
        guard let scope = queueScope, QueueStash.shared.owns(accountId: account.id, scope: scope, owner: self) else { return }
        QueueStash.shared.update(accountId: account.id, scope: scope, profile: profile, owner: self, items: queuedMessages,
                                 parked: isQueueParked)
    }

    /// Off screen: once the queue is out (or parked by a refusal), the last reply ended and no /btw or /bg is still out,
    /// the chat stops listening and the app model lets it go. A parked remainder waits in the stash for the next open.
    func endAwayDrainIfDone() {
        guard drainingAway, !observing, queuedMessages.isEmpty || isQueueParked, !turn.busy, !voiceHold,   // [talk] voiceHold
              !sideTasksOut() else { return }
        AppLog.trace("chat", "off-screen drain done \(logIds): queued=\(queuedMessages.count) parked=\(isQueueParked); stops listening")
        drainingAway = false
        stopListening()
        ticker.invalidate()
        saveCache()
        releaseStashedQueue()
        onDrainingAwayChange?(false)
    }

    /// Sign-out or a gateway switch while the chat drains off screen: it stops at once (the stash keeps the queue for
    /// this account until a sign-out purges it).
    func abandonAwayDrain() {
        guard drainingAway else { return }
        AppLog.note("chat", "off-screen drain abandoned \(logIds) (sign-out or gateway switch): \(queuedMessages.count) queued kept in the stash, busy=\(turn.busy)")
        drainingAway = false
        stopListening()
        ticker.invalidate()
        releaseStashedQueue()
    }

    /// A refused send with no screen to hand its words to: they go into the chat's draft (the field shows them when the
    /// chat opens), never lost (04 §2.4.1).
    func returnWordsToDraft(_ text: String) {
        guard !observing, !ChatText.trimmed(text).isEmpty else { return }
        AppLog.trace("send", "refused send's words saved to \(logIds)'s draft (off screen)")
        AttachmentCenter.existing(account.id)?.returnToDraft(draftScope, profile: profile, text: text, attachments: [], setTextIfEmpty: true)
    }
}
