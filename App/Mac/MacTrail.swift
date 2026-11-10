// [mac] [diagnostics] What happened on the Mac that the app's own lines don't say (owner, Oct 29: "i want to be able
// to catch everything so that we can fix everything"):
//   click    each click and right-click (Detailed Logging): "click UIButton 'Filter' in SessionsViewController",
//            "click SessionRowCell 1.4 in SessionsViewController". A control gives its accessibility identifier or
//            label (fixed words) only outside a list row; a row gives its kind and place, never its text; a field
//            never its value.
//   mac      the Mac going to sleep and waking (sockets drop across a sleep), the screens sleeping, the window's size
//            after a resize ends.
// The system's own errors and faults for the app are SystemLog.swift; sheets and alerts PresentationTrail.

import UIKit

#if targetEnvironment(macCatalyst)
@MainActor enum MacTrail {
    // MARK: Clicks

    /// MeteredWindow.sendEvent: a press of a mouse button (a touch beginning, on the Mac).
    static func event(_ event: UIEvent) {
        guard AppLog.detailed, event.type == .touches, let touches = event.allTouches, touches.count == 1,
              let touch = touches.first, touch.phase == .began else { return }
        let kind = event.buttonMask.contains(.secondary) ? "right-click" : touch.tapCount == 2 ? "double-click" : "click"   // system-ink-ok: the mouse button, not a colour
        AppLog.trace("click", "\(kind) \(describe(touch.view)) in \(screen(of: touch.view))")
    }

    /// The clicked thing in fixed words: its control (with a name only outside a list row) and its list row's place.
    static func describe(_ view: UIView?) -> String {
        var control: UIControl?
        var cell: UIView?
        var current = view
        while let next = current, !(next is UIWindow) {
            if control == nil, let found = next as? UIControl { control = found }
            if next is UICollectionViewCell || next is UITableViewCell { cell = next; break }
            current = next.superview
        }
        var parts: [String] = []
        if let control { parts.append(typeName(control) + (cell == nil ? name(control) : "")) }
        if let cell { parts.append(typeName(cell) + place(cell)) }
        if parts.isEmpty { parts.append(view.map(typeName) ?? "nothing") }
        return parts.joined(separator: " in ")
    }

    /// " 'Filter'": the control's identifier, else its label when short (an icon button's words); never a value.
    private static func name(_ control: UIControl) -> String {
        if let id = control.accessibilityIdentifier, !id.isEmpty { return " '\(AppLog.scrub(String(id.prefix(48))))'" }
        if control is UITextField || control is UISearchTextField { return "" }
        guard let label = control.accessibilityLabel, !label.isEmpty, label.count <= 40 else { return "" }
        return " '\(AppLog.scrub(label))'"
    }

    /// " 2.5": the row's section and item in its list.
    private static func place(_ cell: UIView) -> String {
        var view = cell.superview
        while let next = view {
            if let list = next as? UICollectionView, let cell = cell as? UICollectionViewCell, let path = list.indexPath(for: cell) {
                return " \(path.section).\(path.item)"
            }
            if let list = next as? UITableView, let cell = cell as? UITableViewCell, let path = list.indexPath(for: cell) {
                return " \(path.section).\(path.row)"
            }
            view = next.superview
        }
        return ""
    }

    /// The nearest view controller's kind (a SwiftUI page's hosting controller names its view).
    static func screen(of view: UIView?) -> String {
        var responder: UIResponder? = view
        while let next = responder, !(next is UIViewController) { responder = next.next }
        return responder.map(typeName) ?? "no screen"
    }

    private static func typeName(_ object: AnyObject) -> String {
        let name = String(describing: type(of: object))
        return name.count > 72 ? String(name.prefix(72)) + "…" : name
    }

    // MARK: The Mac itself

    /// The Mac's sleep and wake and its screens' (NSWorkspace's own notification center, reached through the
    /// Objective-C runtime as HangWatch reaches NSApp: a Catalyst app can't name AppKit).
    static func install() {
        guard let type = NSClassFromString("NSWorkspace") as? NSObject.Type,
              let workspace = type.value(forKey: "sharedWorkspace") as? NSObject,
              let center = workspace.value(forKey: "notificationCenter") as? NotificationCenter else {
            AppLog.note("mac", "no workspace notifications: sleep and wake go unlogged")
            return
        }
        let words = ["NSWorkspaceWillSleepNotification": "the Mac is going to sleep",
                     "NSWorkspaceDidWakeNotification": "the Mac woke up",
                     "NSWorkspaceScreensDidSleepNotification": "the screens went to sleep",
                     "NSWorkspaceScreensDidWakeNotification": "the screens woke up",
                     "NSWorkspaceSessionDidResignActiveNotification": "switched to another user",
                     "NSWorkspaceSessionDidBecomeActiveNotification": "back from another user"]
        for (name, line) in words {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    AppLog.note("mac", line)
                    switch name {
                    case "NSWorkspaceScreensDidSleepNotification": screensAsleep = true
                    case "NSWorkspaceScreensDidWakeNotification": screensAsleep = false
                    case "NSWorkspaceSessionDidResignActiveNotification": otherUser = true
                    case "NSWorkspaceSessionDidBecomeActiveNotification": otherUser = false
                    default: break
                    }
                }
            })
        }
        // The lock screen: the system's own notes (NSDistributedNotificationCenter is a NotificationCenter).
        if let distributed = (NSClassFromString("NSDistributedNotificationCenter") as? NSObject.Type)?
            .value(forKey: "defaultCenter") as? NotificationCenter {
            for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
                observers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        screenLocked = locked
                        AppLog.note("mac", locked ? "the screen locked" : "the screen unlocked")
                    }
                })
            }
        }
    }

    private static var observers: [NSObjectProtocol] = []
    private static var screenLocked = false, screensAsleep = false, otherUser = false

    /// Mac polish #26 (the lock check its fix left open): the window's scene stays in the foreground on a locked Mac,
    /// with its screens asleep and while another user has the Mac, so the app would count as open there; this says
    /// nobody is at it. Device Access then wants While Locked, as a locked iPhone does.
    static var nobodyAtIt: Bool { screenLocked || screensAsleep || otherUser }

    // MARK: Window size

    private static var pendingSize: DispatchWorkItem?

    /// The window's size once a resize has rested half a second (a live resize changes it every frame).
    static func windowResized(to size: CGSize) {
        pendingSize?.cancel()
        let item = DispatchWorkItem { AppLog.trace("mac", "window \(Int(size.width))×\(Int(size.height))") }
        pendingSize = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }
}
#endif
