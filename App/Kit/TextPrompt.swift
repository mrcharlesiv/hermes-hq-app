// A one-field alert (`nativePrompt`): New Section, Rename Section, Rename Gateway. The action is enabled only while the
// text is acceptable (non-blank unless blank is allowed; changed when `requireChange`; no `problem` with it, whose
// words then stand in for the message).

import UIKit

enum TextPrompt {
    static func present(title: String, message: String? = nil, text: String = "", placeholder: String? = nil,
                        action: String, maxLength: Int? = nil, allowBlank: Bool = false, requireChange: Bool = false,
                        identifier: String? = nil, selectText: Bool = false,
                        autocapitalization: UITextAutocapitalizationType = .words, autocorrection: UITextAutocorrectionType = .default,
                        secondary: (title: String, action: () -> Void)? = nil, problem: ((String) -> String?)? = nil,
                        from presenter: UIViewController?, done: @escaping (String) -> Void) {
        guard let host = FailureAlert.topmost(presenter) else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        weak let shown = alert
        let confirm = UIAlertAction(title: action, style: .default) { [weak alert] _ in
            var value = alert?.textFields?.first?.text ?? ""
            if let maxLength { value = String(value.prefix(maxLength)) }
            done(value)
        }
        func check(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let changed = trimmed != text.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = problem?(trimmed)
            confirm.isEnabled = (allowBlank || !trimmed.isEmpty) && (!requireChange || changed) && reason == nil
            if problem != nil, shown?.message != (reason ?? message) { shown?.message = reason ?? message }
        }
        alert.addTextField { field in
            field.text = text
            field.placeholder = placeholder
            field.autocapitalizationType = autocapitalization
            field.autocorrectionType = autocorrection
            field.clearButtonMode = .whileEditing
            field.returnKeyType = .done
            field.accessibilityIdentifier = identifier ?? "prompt.field"
            field.addAction(UIAction { [weak field] _ in
                guard let field else { return }
                if let maxLength, (field.text ?? "").count > maxLength { field.text = String((field.text ?? "").prefix(maxLength)) }
                check(field.text ?? "")
            }, for: .editingChanged)
        }
        // [provider-manager] A second way out (Reset to Original), between Cancel and the action.
        if let secondary { alert.addAction(UIAlertAction(title: secondary.title, style: .default) { _ in secondary.action() }) }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(confirm)
        alert.preferredAction = confirm
        check(text)
        host.present(alert, animated: true) { [weak alert] in
            // `selectText`: the text starts selected, so typing replaces it (Rename Chat).
            guard selectText, let field = alert?.textFields?.first else { return }
            field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
        }
    }

    /// A destructive confirmation (`nativeConfirm`).
    static func confirm(title: String, message: String?, action: String, style: UIAlertController.Style = .alert,
                        from presenter: UIViewController?, sourceView: UIView? = nil, sourceRect: CGRect? = nil,
                        done: @escaping () -> Void) {
        guard let host = FailureAlert.topmost(presenter) else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: style)
        alert.addAction(UIAlertAction(title: action, style: .destructive) { _ in done() })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = sourceView ?? host.view
            if let sourceRect, sourceView != nil { popover.sourceRect = sourceRect }
            if sourceView == nil { popover.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.maxY, width: 0, height: 0) }
        }
        host.present(alert, animated: true)
    }
}

// MARK: - [mac] Escape in a typing alert

/// [mac] Audit 2026-11-02 #17: an alert answers Return with its preferred action and Escape with Cancel on its own,
/// except while its text field has the keyboard: the field kept Escape, so Rename, New Section, Add Goal and the rest
/// stayed up. The app's Escape (View › Stop or Close) closes such an alert as its Cancel does (`AlertCancel.close`),
/// running a Cancel made with `UIAlertAction.hqCancel` (a page's prompt that must hear "no"). A plain Cancel has nothing
/// to run. Every other alert keeps the system's own keys.
@MainActor enum AlertCancel {
    private static let handlerKey = malloc(1)!

    fileprivate static func store(_ handler: @escaping () -> Void, on action: UIAlertAction) {
        objc_setAssociatedObject(action, handlerKey, handler, .OBJC_ASSOCIATION_RETAIN)
    }

    /// An alert whose text field holds the keyboard (the only kind the system's Escape misses) and that has a Cancel.
    static func typing(_ top: UIViewController?) -> UIAlertController? {
        guard let alert = top as? UIAlertController, !alert.isBeingDismissed,
              alert.textFields?.contains(where: \.isFirstResponder) == true,
              alert.actions.contains(where: { $0.style == .cancel }) else { return nil }
        return alert
    }

    /// Closes `alert` as its Cancel button would.
    static func close(_ alert: UIAlertController) {
        let cancel = alert.actions.first { $0.style == .cancel }
        let handler = cancel.flatMap { objc_getAssociatedObject($0, handlerKey) as? () -> Void }
        alert.dismiss(animated: true) { handler?() }
    }
}

extension UIAlertAction {
    /// A Cancel whose handler also runs when Escape closes the alert from its text field (`AlertCancel`).
    static func hqCancel(_ title: String = "Cancel", handler: @escaping () -> Void) -> UIAlertAction {
        let action = UIAlertAction(title: title, style: .cancel) { _ in handler() }
        AlertCancel.store(handler, on: action)
        return action
    }
}
