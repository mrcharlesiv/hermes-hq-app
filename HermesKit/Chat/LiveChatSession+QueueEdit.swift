// [composer] A queued row's Delete and Edit (docs/spec/3x-composer.md §15.3, §15.5). Delete throws the row away: its
// photos and files leave the phone (and the gateway's staging), a memo's recording is deleted, and nothing comes back
// to the field, the tray or the draft chip. Edit holds a text-only row where it is while its words are changed in the
// composer: the queue doesn't send it (nor the rows behind it) until Save puts the new words in place, same id, same
// position, or Cancel leaves it as it was. The chat screen ends an edit when it leaves.

import Foundation

extension LiveChatSession {
    func discardQueued(_ id: String) {
        guard let index = queuedMessages.firstIndex(where: { $0.id == id }) else { return }
        let item = queuedMessages.remove(at: index)
        AppLog.trace("send", "queued \(AppLog.tag(id)) deleted (\(queuedMessages.count) left)")
        let wasHeld = queueEditingId == id
        if wasHeld { queueEditingId = nil }
        if queuedMessages.isEmpty { unparkQueue() }
        if let memo = item.memo {
            if MemoPlayer.shared.isCurrent(memo.path) { MemoPlayer.shared.stop() }
            MemoPaths.remove(memo.path)
        }
        if !item.attachments.isEmpty, let center = liveAttachmentCenter {
            center.sendEnded(item.attachments.map(\.id))
            for attachment in item.attachments { center.remove(attachment.id, scope: draftScope) }
        }
        changes.markState()
        scheduleFlush()
        if wasHeld, !turn.busy { drainQueueHead() }
    }

    /// Whether Edit is offered for this row: typed words only (no photo, file or memo), not a goal continuation, not
    /// a skill send (its words on the wire are the skill's body), not going out now.
    func canEditQueued(_ id: String) -> Bool {
        guard let item = queuedMessages.first(where: { $0.id == id }) else { return false }
        return Self.editable(item) && !steeringIds.contains(id)
    }

    nonisolated static func editable(_ item: QueuedMessage) -> Bool {
        !item.hidden && item.memo == nil && item.attachments.isEmpty && item.display == nil
    }

    func beginQueuedEdit(_ id: String) -> String? {
        guard queueEditingId == nil || queueEditingId == id, canEditQueued(id),
              let item = queuedMessages.first(where: { $0.id == id }) else { return nil }
        AppLog.trace("send", "queued \(AppLog.tag(id)) held for an edit")
        queueEditingId = id
        changes.markState()
        scheduleFlush()
        return item.text
    }

    @discardableResult
    func saveQueuedEdit(_ id: String, text: String) -> Bool {
        defer { endQueuedEdit() }
        guard let index = queuedMessages.firstIndex(where: { $0.id == id }) else { return false }
        let old = queuedMessages[index]
        AppLog.trace("send", "queued \(AppLog.tag(id)) edited in place (\(index + 1) of \(queuedMessages.count))")
        queuedMessages[index] = QueuedMessage(id: old.id, text: text, attachments: old.attachments, memo: old.memo,
                                              hidden: old.hidden, display: old.display)
        return true
    }

    func endQueuedEdit() {
        guard queueEditingId != nil else { return }
        queueEditingId = nil
        changes.markState()
        scheduleFlush()
        // The row may have reached the head while it was held (the reply ended): it, and the rows behind it, go now.
        if !turn.busy { drainQueueHead() }
    }

    func isQueuedSending(_ id: String) -> Bool { steeringIds.contains(id) }
}
