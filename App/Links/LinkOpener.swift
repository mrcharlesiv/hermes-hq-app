// [transcript] Opens a link tapped in a chat (docs/spec/3x-transcript.md §7.1, rows L311 and L982): a web page in the
// in-app Safari view, mail and phone links in their own apps, and a notice in words for a page that can't open here.
// [links-browser] Settings › Open Links In sends web pages to a browser of your choice instead; a file a bot made
// still opens in the app (`LinkRoute`, HermesKit/Links/LinkBrowsers.swift).

import SafariServices
import SwiftUI
import UIKit

enum LinkOpener {
    // MARK: The browser chosen (Settings › Open Links In)

    /// The browsers on this device that links can be handed to by name.
    static func browsers() -> [LinkBrowser] {
        #if targetEnvironment(macCatalyst)
        return MacBrowsers.installed()
        #else
        return PhoneBrowsers.all.compactMap { known in
            guard let probe = URL(string: known.probe + "://"), UIApplication.shared.canOpenURL(probe) else { return nil }
            return LinkBrowser(id: known.id, name: known.name)
        }
        #endif
    }

    /// What Settings offers: In the App (iPhone and iPad), Default Browser, then each browser installed.
    static func choices(installed: [LinkBrowser]) -> [LinkBrowserChoice] {
        (DeviceWord.isMac ? [.system] : [.inApp, .system]) + installed.map { .browser($0.id) }
    }

    /// The saved choice, as it holds now: a browser that was removed counts as the default browser.
    static var choice: LinkBrowserChoice { LinkBrowserChoice.stored.resolved(installed: browsers()) }

    /// "Open in Chrome" for the menus that send a page out of the app: the browser chosen, else the default one.
    static var outsideTitle: String {
        let installed = browsers()
        if case .browser(let id) = LinkBrowserChoice.stored.resolved(installed: installed),
           let name = installed.first(where: { $0.id == id })?.name {
            return "Open in \(name)"
        }
        #if targetEnvironment(macCatalyst)
        if let page = URL(string: "https://example.com"), let name = MacFileWindow.defaultApp(for: page) { return "Open in \(name)" }
        #endif
        return "Open in Safari"
    }

    // MARK: Opening

    static func open(_ url: URL, from host: UIViewController) {
        switch LinkRoute.route(url, choice: choice) {
        case .inApp(let page):
            let safari = SFSafariViewController(url: page)
            safari.dismissButtonStyle = .done
            safari.view.accessibilityIdentifier = "link.safari"
            host.present(safari, animated: true)
        case .outside(let page, let browser):
            hand(page, to: browser)
        case .file(let path):
            // A file on the bot's computer opens in the app (a page runs live there), never in a browser. Only a chat
            // knows whose computer that is.
            if let chat = host as? ChatViewController, let link = FileLinks.url(path), chat.openFileLink(link) { return }
            notice(LinkTargets.refusedNotice, from: host)
        case .system(let other):
            UIApplication.shared.open(other)
        case .loopback:
            notice(LinkTargets.loopbackNotice(device: DeviceWord.name), from: host)
        case .refused:
            notice(LinkTargets.refusedNotice, from: host)
        }
    }

    /// A web page the app itself sends out (a menu's "Open in …", a Get a Key button, a help page): the browser
    /// chosen, else the default one. Never the Safari view, and anything that isn't a web page goes to the system as
    /// before.
    static func openOutside(_ url: URL) {
        let target = LinkTargets.target(url)
        // A file never goes to the system: the Mac would hand a page to its browser.
        if case .file = target { AppLog.note("links", "a file link isn't sent outside the app"); return }
        guard case .page(let page) = target else { UIApplication.shared.open(url); return }
        if case .browser(let id) = choice { hand(page, to: id) } else { hand(page, to: nil) }
    }

    /// For SwiftUI pages (`.environment(\.openURL, LinkOpener.openURLAction)`): the Safari view while links open in
    /// the app, else the browser chosen.
    static var openURLAction: OpenURLAction {
        OpenURLAction { url in
            if choice == .inApp { return .systemAction(url, prefersInApp: true) }
            openOutside(url)
            return .handled
        }
    }

    /// Hands `page` to the browser `id` (nil: the default browser). If that browser doesn't take it (removed since,
    /// or it refused), the default browser does, so a tap always opens the page somewhere.
    private static func hand(_ page: URL, to id: String?) {
        guard let id else { UIApplication.shared.open(page); return }
        let fallBack: @MainActor @Sendable () -> Void = {
            AppLog.note("links", "the chosen browser didn't take the page: default browser")
            UIApplication.shared.open(page)
        }
        #if targetEnvironment(macCatalyst)
        if !MacBrowsers.open(page, in: id, failed: fallBack) { fallBack() }
        #else
        guard let link = PhoneBrowsers.link(page, in: id) else { fallBack(); return }
        UIApplication.shared.open(link) { opened in
            if !opened { fallBack() }
        }
        #endif
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
            if ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") { LinkOpener.open(url, from: host) } else { UIApplication.shared.open(url) }
        }
        if let coordinator = host.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { _ in DispatchQueue.main.async(execute: run) }
        } else {
            DispatchQueue.main.async(execute: run)
        }
    }
}
#endif
