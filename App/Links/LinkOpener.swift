// [transcript] Opens a link tapped in a chat (docs/spec/3x-transcript.md §7.1, rows L311 and L982): a web page in the
// in-app Safari view, mail and phone links in their own apps, and a notice in words for a page that can't open here.

import SafariServices
import UIKit

enum LinkOpener {
    static func open(_ url: URL, from host: UIViewController) {
        switch LinkTargets.target(url) {
        case .page(let page):
            let safari = SFSafariViewController(url: page)
            safari.dismissButtonStyle = .done
            safari.view.accessibilityIdentifier = "link.safari"
            host.present(safari, animated: true)
        case .system(let other):
            UIApplication.shared.open(other)
        case .loopback:
            notice(LinkTargets.loopbackNotice(device: DeviceWord.name), from: host)
        case .refused:
            notice(LinkTargets.refusedNotice, from: host)
        }
    }

    /// The app's own notices, not a system alert: in a chat the chat's notice (it wraps and stays until tapped),
    /// anywhere else the pages' HUD.
    static func notice(_ text: String, from host: UIViewController) {
        if let chat = host as? ChatViewController {
            chat.showLongNotice(text)
            HQAnnounce.say(text, priority: .high, coalesce: true)
        } else {
            PagesHUD.show(text, symbol: "exclamationmark.circle", from: host, duration: 5)
        }
    }

    /// The screen a notice about a link from outside the app belongs on: the chat on show, else the root itself (never
    /// a sheet or a Safari view that happens to be up).
    static func noticeHost(root: UIViewController) -> UIViewController {
        func find(_ vc: UIViewController) -> ChatViewController? {
            if let chat = vc as? ChatViewController, chat.viewIfLoaded?.window != nil { return chat }
            for child in vc.children { if let found = find(child) { return found } }
            return nil
        }
        return find(root) ?? root
    }
}

#if DEBUG
/// `-HQNDebugOpenLink <url>`: once the first chat is on screen, opens the link as a tap on it would (a web or
/// loopback address through `LinkOpener`; one of the app's own links through the system, as a tap outside the app
/// does). For UI tests and screenshots (scripts/e2e-transcript.sh).
enum LinkDebugHook {
    /// The link is opened once per launch, by the first chat that comes on screen.
    private static weak var opener: UIViewController?
    private static var opened = false

    static func runIfAsked(from host: UIViewController) {
        guard !opened, opener == nil, let text = UserDefaults.standard.string(forKey: "HQNDebugOpenLink"), let url = URL(string: text) else { return }
        opener = host
        // On the next turn of the run loop after the chat's appearance has finished (a presentation begun inside
        // `viewDidAppear`'s own transition is dropped): the transition's completion when there is one.
        let run: @MainActor @Sendable () -> Void = { [weak host] in
            guard let host, !opened else { return }
            opened = true
            if ["http", "https"].contains(url.scheme?.lowercased() ?? "") { LinkOpener.open(url, from: host) } else { UIApplication.shared.open(url) }
        }
        if let coordinator = host.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { _ in DispatchQueue.main.async(execute: run) }
        } else {
            DispatchQueue.main.async(execute: run)
        }
    }
}
#endif
