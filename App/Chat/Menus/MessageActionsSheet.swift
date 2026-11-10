// [transcript] "Message actions" (docs/spec/3x-transcript.md §9.2, row L366): VoiceOver and the keyboard have no
// touch-and-hold, so the message's hold menu is offered as a list of the same actions, each running the menu's own
// handler.

import UIKit

enum MessageActionsSheet {
    static let name = "Message actions"

    /// The menu's actions in order, submenus flattened ("More › Branch"), disabled and hidden items left out.
    static func actions(of menu: UIMenu, prefix: String = "") -> [(title: String, destructive: Bool, action: UIAction)] {
        var out: [(title: String, destructive: Bool, action: UIAction)] = []
        for child in menu.children {
            if let action = child as? UIAction {
                guard !action.attributes.contains(.disabled), !action.attributes.contains(.hidden), !action.title.isEmpty else { continue }
                out.append((prefix + action.title, action.attributes.contains(.destructive), action))
            } else if let sub = child as? UIMenu {
                let inline = sub.options.contains(.displayInline) || sub.title.isEmpty
                out += actions(of: sub, prefix: inline ? prefix : prefix + sub.title + " › ")
            }
        }
        return out
    }

    @discardableResult
    static func present(_ menu: UIMenu, from source: UIView) -> Bool {
        guard let host = source.window?.rootViewController else { return false }
        var top = host
        while let next = top.presentedViewController { top = next }
        let items = actions(of: menu)
        guard !items.isEmpty else { return false }
        let sheet = UIAlertController(title: menu.title.isEmpty ? nil : menu.title, message: nil, preferredStyle: .actionSheet)
        sheet.view.accessibilityIdentifier = "message.actions"
        for item in items {
            sheet.addAction(UIAlertAction(title: item.title, style: item.destructive ? .destructive : .default) { _ in
                item.action.performWithSender(source, target: nil)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = source
        sheet.popoverPresentationController?.sourceRect = source.bounds
        top.present(sheet, animated: true)
        return true
    }
}
