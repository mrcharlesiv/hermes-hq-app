// The Cancel / Save bar an editor inside a pushed page puts on the navigation bar while it edits (parity row L862,
// `S/phone-nav-edit-bar.tsx`): Cancel takes Back's place (Back hides), Save sits at the trailing edge, grey until
// something changed; while saving, Save reads "Saving…" and both are off. Swipe-back is held while the bar is up, so
// a slip of the thumb never drops what was typed. `end()` puts back exactly what the page had.
//
// Used by the SOUL.md editor (docs/spec/3x-morepages.md §10); any detail editor can use it:
//
//     bar = NavEditBar(host: self, onCancel: { … }, onSave: { … })
//     bar.begin()                         // on Edit
//     bar.update(dirty: true, saving: false)
//     bar.end()                           // after Save, or a confirmed Cancel
//
// The host calls `hostDidAppear()` / `hostWillDisappear()` from its own `viewDidAppear` / `viewWillDisappear`: the
// pop gestures belong to the whole navigation stack and must go back to it when another page shows.

import UIKit

/// A page with unsaved edits that hardware Escape must not simply pop (docs/spec/3x-morepages.md §9): the Escape rule
/// asks the visible page first.
@MainActor protocol EscapeCancelling: AnyObject {
    /// true when it handled Escape (ran its Cancel path)
    func escapeCancel() -> Bool
}

@MainActor final class NavEditBar {
    private weak var host: UIViewController?
    private let onCancel: () -> Void
    private let onSave: () -> Void

    /// What the page showed before `begin()`.
    private struct Saved {
        var hidesBackButton: Bool
        var leftItems: [UIBarButtonItem]?
        var rightItems: [UIBarButtonItem]?
        var leftItemsSupplementBackButton: Bool
    }
    private var saved: Saved?

    private(set) var cancelItem: UIBarButtonItem?
    private(set) var saveItem: UIBarButtonItem?
    private(set) var dirty = false
    private(set) var saving = false

    /// Between `begin()` and `end()`.
    var isEditing: Bool { saved != nil }

    init(host: UIViewController, onCancel: @escaping () -> Void, onSave: @escaping () -> Void) {
        self.host = host
        self.onCancel = onCancel
        self.onSave = onSave
    }

    /// Back hides; leading "Cancel", trailing prominent "Save" (disabled until `update(dirty: true, …)`).
    func begin() {
        guard let host, saved == nil else { return }
        let item = host.navigationItem
        saved = Saved(hidesBackButton: DesktopBack.intendedHidesBackButton(item),   // [desktoplook3] the page's own, not the look's
                      leftItems: item.leftBarButtonItems,
                      rightItems: item.rightBarButtonItems, leftItemsSupplementBackButton: item.leftItemsSupplementBackButton)
        let cancel = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.onCancel() })
        cancel.accessibilityIdentifier = "nav-edit.cancel"
        let save = UIBarButtonItem(title: "Save", style: .prominent, target: nil, action: nil)
        save.primaryAction = UIAction(title: "Save") { [weak self] _ in self?.onSave() }
        save.style = .prominent
        save.accessibilityIdentifier = "nav-edit.save"
        cancelItem = cancel
        saveItem = save
        dirty = false
        saving = false
        item.leftItemsSupplementBackButton = false
        item.setHidesBackButton(true, animated: false)
        item.leftBarButtonItems = [cancel]
        item.rightBarButtonItems = [save]
        apply()
        lockSwipeBack(true)
    }

    /// Save is enabled only while `dirty` and not `saving`; while `saving` it reads `savingLabel` and Cancel is off too.
    func update(dirty: Bool, saving: Bool, savingLabel: String = "Saving…") {
        self.dirty = dirty
        self.saving = saving
        apply(savingLabel)
    }

    private func apply(_ savingLabel: String = "Saving…") {
        guard isEditing else { return }
        cancelItem?.isEnabled = !saving
        let title = saving ? savingLabel : "Save"
        if saveItem?.title != title { saveItem?.title = title }
        saveItem?.setProminentEnabled(dirty && !saving)   // disabled it is a plain dimmed item, as on every other edit bar
        saveItem?.accessibilityLabel = title
    }

    /// Back and the page's own items return.
    func end() {
        guard let saved else { return }
        self.saved = nil
        cancelItem = nil
        saveItem = nil
        dirty = false
        saving = false
        guard let host else { return }
        let item = host.navigationItem
        item.leftBarButtonItems = saved.leftItems
        item.rightBarButtonItems = saved.rightItems
        item.leftItemsSupplementBackButton = saved.leftItemsSupplementBackButton
        item.setHidesBackButton(saved.hidesBackButton, animated: false)
        lockSwipeBack(false)
    }

    // MARK: Swipe-back

    /// The page came (back) on screen: the hold is put back while editing.
    func hostDidAppear() { if isEditing { lockSwipeBack(true) } }

    /// Another page is about to show: the recognizers go back to the stack.
    func hostWillDisappear() { lockSwipeBack(false) }

    private func lockSwipeBack(_ locked: Bool) {
        guard let navigation = host?.navigationController else { return }
        // Only the page on top may hold them (a page under another one never locks the one above).
        if locked, navigation.topViewController !== host { return }
        navigation.interactivePopGestureRecognizer?.isEnabled = !locked
        navigation.interactiveContentPopGestureRecognizer?.isEnabled = !locked
    }
}
