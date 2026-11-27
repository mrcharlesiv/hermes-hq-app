// [Mac AAA 2026-11-16] DEBUG: `-HQDebugSettingsTour <stops>` with `-HQDebugSettingsWindow <name>`: once the Settings
// window is up, each stop is opened in it and the window photographed (`<name>-s<n>-<stop>.png`, and
// `…-end.png` scrolled to the foot when the page is taller than the window), then the app quits. Hold the main tour
// open with `-HQDebugMacShotsWait 600`. Stops, comma separated:
//   cat:<general|appearance|chat|sounds|gateway|tools|about>   a category of the column
//   <root id>                                                  a root page (`SettingsNavigator.openRoot`: theme, about…)
//   page:<config page key>                                     a config page (`page:model.main`)
//   search:<words>                                             the column's search field holding the words
//   look:<desktop|ios>, skin:<id>, light, dark                 the theme or appearance switched live, as Theme does
//   all                                                        every category and root page

#if DEBUG && targetEnvironment(macCatalyst)
import UIKit

@MainActor enum SettingsWindowTour {
    static let allStops = ["cat:general", "cat:appearance", "cat:chat", "cat:gateway", "cat:accounts", "cat:tools", "cat:about",
                           "gateway", "notifications", "device-access", "theme", "chat-bubbles", "backgrounds", "background:app",
                           "background:chats", "app-icon", "tab-order", "tool-calls", "providers", "keys", "vault", "billing",
                           "sessions", "auxiliary-models", "capabilities", "diagnostics", "licenses", "search:sound", "search:zzzz"]

    static func startIfAsked(window: UIWindow, name: String) {
        guard let asked = UserDefaults.standard.string(forKey: "HQDebugSettingsTour"), !asked.isEmpty else { return }
        let stops = asked == "all" ? allStops : asked.split(separator: ",").map(String.init)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            var log = ""
            for (index, stop) in stops.enumerated() {
                guard let root = MacSettingsWindow.root else { log += "\(stop): no root\n"; break }
                let router = root.router
                root.model.query = ""
                root.backToIndex()
                try? await Task.sleep(for: .seconds(0.4))
                if stop.hasPrefix("cat:"), let category = SettingsCategory(rawValue: String(stop.dropFirst(4))) {
                    root.model.category = category
                    root.backToIndex()
                } else if stop.hasPrefix("page:"), let page = ConfigCatalog.page(String(stop.dropFirst(5))) {
                    router.jump?(.gateway)
                    ConfigScreens.open(page: page, router: router)
                } else if stop.hasPrefix("search:") {
                    root.model.query = String(stop.dropFirst(7))
                    root.backToIndex()
                } else if stop.hasPrefix("skin:") {
                    Theme.shared.pick(skin: String(stop.dropFirst(5)))
                } else if stop.hasPrefix("look:") {
                    Theme.shared.setDesktopLook(stop == "look:desktop")
                } else if stop == "light" || stop == "dark" {
                    AppearanceSetting.current = stop == "light" ? .light : .dark
                } else {
                    SettingsNavigator.openRoot(stop, router: router)
                }
                try? await Task.sleep(for: .seconds(2.2))
                let slug = stop.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
                let base = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "\(name)-s\(String(format: "%02d", index + 1))-\(slug)")
                var top = window.rootViewController
                while let next = top?.presentedViewController { top = next }
                if let sheet = top?.viewIfLoaded?.window, sheet !== window {
                    MacShots.shoot(sheet, to: base.appendingPathExtension("sheet.png"))
                    top?.dismiss(animated: false)
                }
                MacShots.shoot(window, to: base.appendingPathExtension("png"))
                // `-HQDebugSettingsTourMain YES`: the main window too (a theme switched live: no stale colours there).
                if UserDefaults.standard.bool(forKey: "HQDebugSettingsTourMain"), let main = MainTabController.current?.view.window {
                    MacShots.shoot(main, to: URL(fileURLWithPath: base.path + "-main.png"))
                }
                let pane = root.paneStack?.topViewController?.view ?? root.view
                if let list = biggestScroll(in: pane ?? window), list.contentSize.height > list.bounds.height + 20 {
                    let bottom = list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom
                    list.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
                    try? await Task.sleep(for: .seconds(0.8))
                    MacShots.shoot(window, to: URL(fileURLWithPath: base.path + "-end.png"))
                }
                log += "\(stop): top \(root.paneStack?.topViewController.map { String(describing: type(of: $0)) } ?? "-") title \(root.paneStack?.topViewController?.title ?? "-")\n"
            }
            let file = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "\(name)-tour.txt")
            try? log.write(to: file, atomically: true, encoding: .utf8)
            MacShots.post(file)
            try? await Task.sleep(for: .seconds(2))
            exit(0)
        }
    }

    /// `-HQDebugSignedOutTour <address>|<username>|<password>`: the signed-out window (the env sign-in turned down or
    /// none): the form at rest, then the address typed and Return, then the username and password typed and Return,
    /// each photographed (`<name>-o<n>-….png`), and the last state again in a small window. Then the app quits.
    static func signedOutTourIfAsked(_ window: UIWindow, name: String, folder: URL) async -> Bool {
        guard let asked = UserDefaults.standard.string(forKey: "HQDebugSignedOutTour"), !asked.isEmpty else { return false }
        let parts = asked.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        func shot(_ n: Int, _ label: String) { MacShots.shoot(window, to: folder.appending(path: "\(name)-o\(n)-\(label).png")) }
        func fields() -> [UITextField] {
            func all(_ view: UIView) -> [UITextField] { ((view as? UITextField).map { [$0] } ?? []) + view.subviews.flatMap(all) }
            return all(window).filter { !$0.isHidden && $0.window != nil }
                .sorted { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY }
        }
        func type(_ text: String, into field: UITextField) {
            field.becomeFirstResponder()
            field.selectAll(nil)
            field.insertText(text)
        }
        try? await Task.sleep(for: .seconds(2))
        shot(1, "rest")
        if parts.count > 0, !parts[0].isEmpty, let address = fields().first {
            type(parts[0], into: address)
            _ = address.delegate?.textFieldShouldReturn?(address)
            try? await Task.sleep(for: .seconds(3))
            shot(2, "address")
        }
        if parts.count > 2 {
            let list = fields()
            if list.count >= 3 {
                type(parts[1], into: list[1])
                type(parts[2], into: list[2])
                _ = list[2].delegate?.textFieldShouldReturn?(list[2])
                try? await Task.sleep(for: .seconds(0.5))
                // Return through the delegate doesn't reach SwiftUI's onSubmit, nor did an accessibility press reach the
                // button: the form's own action, as the button runs it (the typed fields are already in its model).
                list[2].resignFirstResponder()
                try? await Task.sleep(for: .seconds(0.5))
                if !press("sign-in-password-button", in: window) || SignInModel.debugLast?.debugError == nil {
                    SignInModel.debugLast?.signInWithPassword()
                }
                // A fourth part: how long the answer may take (an unreachable address waits for its timeout).
                try? await Task.sleep(for: .seconds(parts.count > 3 ? Double(parts[3]) ?? 4 : 4))
                shot(3, "signin")
            }
        }
        window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: 80, y: 80, width: 700, height: 560))) { _ in }
        try? await Task.sleep(for: .seconds(1.5))
        shot(4, "small")
        try? await Task.sleep(for: .seconds(2))
        return true
    }

    /// `-HQDebugGuideTour all|<step>,<step>…` (with `-HQDebugMacShots <name>` and `-HQDebugWelcome YES`): each first-run
    /// screen in turn (`OnboardingFlow.go`, as its buttons go), photographed as `<name>-g<nn>-<step>.png`, the welcome
    /// and the form again in a small window, then the app quits. True when asked (the caller shows the flow at once).
    /// `flow` reads the scene's flow at each step (a failed launch sign-in builds the form's flow again).
    static func guideTourIfAsked(_ flow: @escaping () -> OnboardingFlow?, window: UIWindow) -> Bool {
        guard !guideTourStarted, let asked = UserDefaults.standard.string(forKey: "HQDebugGuideTour"), !asked.isEmpty,
              let name = UserDefaults.standard.string(forKey: "HQDebugMacShots") else { return false }
        guideTourStarted = true
        let steps = asked == "all" ? [.welcome] + OnboardingStep.guide + [.connect]
            : asked.split(separator: ",").compactMap { OnboardingStep(rawValue: String($0)) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mac-shots")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            @MainActor func shot(_ label: String) { MacShots.shoot(window, to: folder.appendingPathComponent("\(name)-\(label).png")) }
            for (index, step) in steps.enumerated() {
                guard let flow = flow() else { break }
                flow.animated = false
                flow.go(step)
                flow.animated = true
                try? await Task.sleep(for: .seconds(1.6))
                shot("g\(String(format: "%02d", index + 1))-\(step.rawValue)")
            }
            // [Mac calls 2026-11-17] Every screen again at the smallest window and at a tall one (`-HQDebugGuideTourSizes
            // YES`; without it only the welcome and the question at the small size, as before).
            let every = UserDefaults.standard.bool(forKey: "HQDebugGuideTourSizes")
            for (label, frame) in [("small", CGRect(x: 80, y: 80, width: 700, height: 560)), ("tall", CGRect(x: 40, y: 30, width: 1100, height: 1400))]
                where every || label == "small" {
                window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: frame)) { _ in }
                try? await Task.sleep(for: .seconds(1))
                for (index, step) in steps.enumerated() where every || [OnboardingStep.welcome, .start].contains(step) {
                    guard let flow = flow() else { break }
                    flow.animated = false
                    flow.go(step)
                    try? await Task.sleep(for: .seconds(1.6))
                    shot(every ? "\(label)-g\(String(format: "%02d", index + 1))-\(step.rawValue)" : "\(label)-\(step.rawValue)")
                }
            }
            try? await Task.sleep(for: .seconds(2))
            exit(0)
        }
        return true
    }

    private static var guideTourStarted = false

    /// Activates the accessibility element with this identifier (a SwiftUI button), as VoiceOver would.
    static func press(_ identifier: String, in root: NSObject) -> Bool {
        func search(_ node: NSObject, depth: Int) -> Bool {
            guard depth < 60 else { return false }
            if (node as? UIAccessibilityIdentification)?.accessibilityIdentifier == identifier, node.accessibilityActivate() { return true }
            if let view = node as? UIView {
                for sub in view.subviews where search(sub, depth: depth + 1) { return true }
            }
            for element in (node.accessibilityElements ?? []).compactMap({ $0 as? NSObject }) where search(element, depth: depth + 1) { return true }
            return false
        }
        return search(root, depth: 0)
    }

    private static func biggestScroll(in view: UIView) -> UIScrollView? {
        func lists(_ view: UIView) -> [UIScrollView] {
            ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap(lists)
        }
        return lists(view).filter { !$0.isHidden && $0.bounds.width > 200 }
            .max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }
}
#endif
