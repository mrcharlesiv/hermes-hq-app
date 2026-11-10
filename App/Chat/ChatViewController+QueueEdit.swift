import UIKit

// [composer] Edit and Delete on a queued message (docs/spec/3x-composer.md §15.3, §15.5). Edit puts the row's words in
// the field under an "Editing Queued Message" strip with Cancel and Save; whatever was typed is set aside and comes
// back afterwards. The row keeps its place and doesn't send meanwhile (nor do the rows behind it). Save (the strip's
// Save, the circle or Return) replaces its words in place; Cancel, another edit or reply, or leaving the chat changes
// nothing. Delete throws the row away; a voice memo asks first, as deleting a memo does everywhere else.

extension ChatViewController {
    func beginQueueEdit(_ id: String) {
        guard let queue = session as? ChatQueueing else { return }
        // One strip at a time: a message edit or a reply in progress gives way first (its draft comes back).
        (composer.editBanner as? ComposerEditBanner)?.onCancel?()
        guard let words = queue.beginQueuedEdit(id) else { return }
        AppLog.trace("composer", "queued \(AppLog.tag(id)) edit began \(logTag)")
        let draft = composer.text
        let banner = ComposerEditBanner.editingQueued()
        let close: (ChatViewController) -> Void = { screen in
            screen.sendOverride = nil
            screen.composer.editingQueued = false
            screen.composer.editBanner = nil
        }
        banner.onCancel = { [weak self, weak queue] in
            guard let self else { return }
            close(self)
            queue?.endQueuedEdit()
            self.composer.text = draft
        }
        let save: (String) -> Void = { [weak self, weak queue] text in
            guard let self else { return }
            close(self)
            let saved = queue?.saveQueuedEdit(id, text: text) ?? false
            AppLog.trace("composer", "queued \(AppLog.tag(id)) edit saved=\(saved) \(self.logTag)")
            // The row went meanwhile (it can't take the words in place): they stay in the field, over the set-aside draft.
            self.composer.text = saved ? draft : QueueWords.editedField(current: text, queued: draft)
        }
        banner.onSave = { [weak self] in
            guard let self else { return }
            let text = ComposerKeyboard.sendText(self.composer.text)
            guard !text.isEmpty else { return }
            Haptics.play(.selection)
            save(text)
        }
        composer.editBanner = banner
        composer.editingQueued = true
        composer.text = words
        // The circle and Return save (a blank field keeps editing).
        sendOverride = { text in
            if !text.isEmpty { save(text) }
            return true
        }
        focusComposer()
    }

    /// Ends a queued message's edit as Cancel would (leaving the chat, the row deleted).
    func cancelQueueEdit() {
        guard composer.editingQueued else { return }
        (composer.editBanner as? ComposerEditBanner)?.onCancel?()
    }

    func deleteQueued(_ id: String) {
        guard let queue = session as? ChatQueueing, let item = queue.queuedMessages.first(where: { $0.id == id }) else { return }
        let discard = { [weak self, weak queue] in
            if queue?.queueEditingId == id { self?.cancelQueueEdit() }
            queue?.discardQueued(id)
        }
        guard let memo = item.memo else { discard(); return }
        voice.memoConfirmDelete(seconds: memo.seconds, recording: false) { yes in if yes { discard() } }
    }
}
