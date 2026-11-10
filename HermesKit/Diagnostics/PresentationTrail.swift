// [diagnostics] Every sheet, alert and cover the window shows and closes, as `screen` lines: "sheet ChatInfoSheet
// (form sheet)", "alert 'Couldn't Send': The gateway refused… [Try Again / Cancel]", "closed ChatInfoSheet". PageKit
// names pushed pages and MainTabController the tabs; presentations had no line (owner, Oct 29: "catch everything").
// MeteredWindow calls this when a presentation's container comes or goes; the window's chain of presented
// controllers is compared with the one last logged. An alert's title and message are what the person was shown (through
// AppLog.scrub); a text field's contents never are.

import UIKit

@MainActor enum PresentationTrail {
    private static var shown: [ObjectIdentifier: String] = [:]
    private static var pending = false

    /// The window gained or lost a subview: look once the presentation has settled into the hierarchy.
    /// The window is found again by identity, never held: a window being freed (swiping the app away frees the scene's
    /// window, which removes its subviews) can't be weakly referenced, and doing so killed builds 460-515 on every
    /// swipe-away (a tester's "Closing the app out it crashed" and the owner's, 2026-10-30).
    static func windowChanged(_ window: UIWindow) {
        guard !pending else { return }
        pending = true
        let id = ObjectIdentifier(window)
        DispatchQueue.main.async {
            pending = false
            guard let window = liveWindow(id) else { return }
            update(chain(window))
        }
    }

    /// The app's connected window with this identity, if it is still there.
    static func liveWindow(_ id: ObjectIdentifier) -> UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            .first { ObjectIdentifier($0) == id }
    }

    static func chain(_ window: UIWindow) -> [UIViewController] {
        var out: [UIViewController] = []
        var next = window.rootViewController?.presentedViewController
        while let current = next {
            out.append(current)
            next = current.presentedViewController
        }
        return out
    }

    private static func update(_ chain: [UIViewController]) {
        let now = Set(chain.map(ObjectIdentifier.init))
        for (id, name) in shown where !now.contains(id) {
            AppLog.note("screen", "closed \(name)")
            shown[id] = nil
        }
        for controller in chain where shown[ObjectIdentifier(controller)] == nil {
            let name = self.name(controller)
            shown[ObjectIdentifier(controller)] = name
            AppLog.note("screen", describe(controller))
        }
    }

    /// The controller's kind; a navigation controller is named by its first page.
    static func name(_ controller: UIViewController) -> String {
        let shown = (controller as? UINavigationController)?.viewControllers.first ?? controller
        let name = String(describing: type(of: shown))
        return name.count > 72 ? String(name.prefix(72)) + "…" : name
    }

    static func describe(_ controller: UIViewController) -> String {
        if let alert = controller as? UIAlertController {
            var line = alert.preferredStyle == .actionSheet ? "action sheet" : "alert"
            if let title = alert.title, !title.isEmpty { line += " '\(AppLog.scrub(String(title.prefix(80))))'" }
            if let message = alert.message, !message.isEmpty { line += ": " + AppLog.scrub(String(message.prefix(240))) }
            let actions = alert.actions.compactMap(\.title).filter { !$0.isEmpty }
            if !actions.isEmpty { line += " [\(actions.map { String($0.prefix(30)) }.joined(separator: " / "))]" }
            if !(alert.textFields ?? []).isEmpty { line += " with \(alert.textFields!.count) field(s)" }
            return line
        }
        return "\(kind(controller.modalPresentationStyle)) \(name(controller))"
    }

    private static func kind(_ style: UIModalPresentationStyle) -> String {
        switch style {
        case .fullScreen, .overFullScreen: "cover"
        case .formSheet: "sheet (form)"
        case .popover: "popover"
        case .pageSheet, .automatic: "sheet"
        default: "presented"
        }
    }
}
