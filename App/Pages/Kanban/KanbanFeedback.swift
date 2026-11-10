// What the board and the task sheet both say after a write (UX study 2026-10-19 #133, #134): the "Archived" pill with
// Undo (from the board's menu or the sheet's ⋯), a "Couldn’t …" alert with Try Again when a deliberate write fails, and
// the Jobs page's lock HUD when changes are off for the gateway.

import UIKit

@MainActor
enum KanbanFeedback {
    /// "Archived" with Undo over `host` (the board). Archive stays silent: the Undo pill is the feedback (§2.6). The
    /// pill Bots and Sessions show (UX study #152: held while touched or VoiceOver-focused, a 44 pt Undo).
    static func archived(_ task: KanbanTask, from status: String, board: String, store: KanbanStore, on host: UIViewController) {
        UndoPill.show(label: "Archived", detail: "Archived tasks are on the desktop board.", in: host) { [weak host] in
            undo(task, to: status, board: board, store: store, host: host)
        }
    }

    private static func undo(_ task: KanbanTask, to status: String, board: String, store: KanbanStore, host: UIViewController?) {
        Task {
            guard let reason = await store.unarchive(task, to: status, board: board) else {
                PagesHaptics.success()   // a confirmed write (the archive itself stays silent)
                return
            }
            failed(KanbanWriteWords.undoArchive, reason: reason, from: host) { undo(task, to: status, board: board, store: store, host: host) }
        }
    }

    /// A deliberate write failed: the alert with the gateway's reason and Try Again (its own error haptic).
    static func failed(_ key: String, reason: String, from host: UIViewController?, retry: @escaping () -> Void) {
        FailureAlert.present(title: KanbanWriteWords.failureTitle(key) ?? "Couldn’t Save the Change", reason: reason,
                             from: host, retry: retry)
    }

    /// Changes are off for this gateway: the lock HUD the Jobs page shows.
    static func readOnly(from host: UIViewController?) {
        guard let host else { return }
        PagesHUD.show(JobsStore.readOnlyNotice, symbol: "lock", from: host, duration: 2.5)
        PagesHaptics.error()
    }
}
