// [onboarding] What the guide's Copy, Send… and link buttons do (docs/spec/3x-onboarding.md §4, §5.10), behind one
// value so tests can make each of them fail and read the lines that follow. The app only hands text to the pasteboard,
// the share sheet or the browser: it never runs a command and never fetches the setup script.

import Observation
import SafariServices
import UIKit

struct GuideActions {
    /// Puts text on the pasteboard; false when it did not get there.
    var copy: (String) -> Bool
    /// Opens the share sheet with one text item; false when it could not open. The rectangle is the tapped button's
    /// frame in window coordinates (an iPad's popover points at it); nil when it is not known.
    var share: (String, CGRect?) -> Bool
    /// Opens a link (the browser sheet, or the App Store for its own links); false when it could not.
    var open: (URL) async -> Bool
    /// Says a status line to VoiceOver.
    var announce: (String) -> Void = { text in AccessibilityNotification.Announcement(text).post() }

    /// The real ones, presenting over `presenter` (the flow's navigation controller).
    static func live(presenter: @escaping () -> UIViewController?) -> GuideActions {
        GuideActions(
            copy: { text in
                #if DEBUG
                if GuideDebug.fails("copy") { return false }
                #endif
                UIPasteboard.general.string = text
                let done = UIPasteboard.general.hasStrings
                #if DEBUG
                if done { GuideDebug.record(text, as: "copy.txt") }
                #endif
                if done { Haptics.play(.success) }
                return done
            },
            share: { text, anchor in
                #if DEBUG
                if GuideDebug.fails("share") { return false }
                #endif
                guard let host = presenter().map(Self.top) else { return false }
                // One sheet at a time: a second tap while one is up (or still rising) changes nothing.
                if host is UIActivityViewController || host.isBeingPresented || host.isBeingDismissed { return true }
                let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
                if let popover = sheet.popoverPresentationController {
                    popover.sourceView = host.view
                    if let anchor, !anchor.isEmpty {
                        popover.sourceRect = host.view.convert(anchor, from: nil)
                    } else {
                        popover.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.maxY - 80, width: 1, height: 1)
                    }
                }
                host.present(sheet, animated: true)
                #if DEBUG
                GuideDebug.record(text, as: "share.txt")
                #endif
                return true
            },
            open: { url in
                guard Self.opens(url) else { return false }
                #if DEBUG
                GuideDebug.record(url.absoluteString, as: "open.txt")
                if GuideDebug.fails("open") { return false }
                #endif
                if url.host()?.lowercased() == "apps.apple.com" {
                    // DECISION D6: the App Store's own page, not a store page inside a browser sheet.
                    return await UIApplication.shared.open(url)
                }
                guard let host = presenter().map(Self.top) else { return false }
                // One browser at a time: a second tap while one is up (or still rising) changes nothing and is no error.
                if host is SFSafariViewController || host.isBeingPresented || host.isBeingDismissed { return true }
                let browser = SFSafariViewController(url: url)
                host.present(browser, animated: true)
                return true
            })
    }

    /// Only plain https links with no sign-in part are ever opened.
    nonisolated static func opens(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil && !(url.host() ?? "").isEmpty
    }

    private static func top(_ controller: UIViewController) -> UIViewController {
        var top = controller
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}

/// Whether this device already runs Tailscale and Hermes should stay off the internet (the setup's `--private`). One
/// per flow, so the choice made on the first screen holds on the ones after it.
@Observable final class SetupReach {
    var tailnetOnly = false
}

/// One command card's (or the manual page's) status line: the web's `.ios-setup-copied` (`wireGuide`,
/// `W:src/connection-guide.ts:191-208`). The line belongs to its card and stays until the next tap on it.
@Observable final class GuideFeedback {
    let kind: OnboardingCopy.FeedbackKind
    private(set) var status = ""
    @ObservationIgnored private let actions: GuideActions
    @ObservationIgnored private let reach: SetupReach?

    init(_ kind: OnboardingCopy.FeedbackKind, actions: GuideActions, reach: SetupReach? = nil) {
        self.kind = kind; self.actions = actions; self.reach = reach
    }

    /// What Copy and Send hand over: the `--private` command or message once the device is said to run Tailscale.
    var text: String { kind.text(tailnetOnly: reach?.tailnetOnly ?? false) }

    func copy() {
        status = ""
        say(actions.copy(text) ? kind.copied : kind.couldNotCopy)
    }

    /// A share that opens (and is then cancelled or completed) leaves the line empty.
    func share(from anchor: CGRect? = nil) {
        status = ""
        if !actions.share(text, anchor) { say(OnboardingCopy.couldNotShare) }
    }

    private func say(_ text: String) {
        status = text
        if !text.isEmpty { actions.announce(text) }
    }
}

/// One screen's links and its error line (`.ios-doc-error`, `role="alert"`): cleared on each tap, set when the link
/// could not open.
@Observable final class GuideLinkOpener {
    private(set) var error = ""
    @ObservationIgnored private let actions: GuideActions
    @ObservationIgnored private let failure: (String) -> String
    /// The latest attempt (tests await it).
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    init(actions: GuideActions, failure: @escaping (String) -> String = OnboardingCopy.couldNotOpen) {
        self.actions = actions; self.failure = failure
    }

    func open(_ address: String) {
        error = ""
        task = Task { [weak self, actions, failure] in
            let opened: Bool
            if let url = URL(string: address) { opened = await actions.open(url) } else { opened = false }
            guard let self, !opened else { return }
            self.error = failure(address)
            actions.announce(self.error)
        }
    }
}

#if DEBUG
/// `-HQDebugGuideOut <folder>` and `-HQDebugGuideFail copy,share,open` (App/Debug/DebugHooks.swift).
enum GuideDebug {
    static func fails(_ action: String) -> Bool {
        (UserDefaults.standard.string(forKey: "HQDebugGuideFail") ?? "").split(separator: ",").contains { $0 == action }
    }

    static func record(_ text: String, as name: String) {
        guard let folder = UserDefaults.standard.string(forKey: "HQDebugGuideOut"), !folder.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? text.write(toFile: (folder as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
#endif
