// [transcript] Opens a link tapped in a chat (docs/spec/3x-transcript.md §7.1, rows L311 and L982): an installed
// app that claims the link (Universal Links) first, else the in-app Safari view; mail and phone links in their own
// apps; and a notice in words for a page that can't open here.
// [links-browser] Settings › Open Links In sends web pages that no installed app claims to a browser of your choice
// instead; a file a bot made still opens in the app (`LinkRoute`, HermesKit/Links/LinkBrowsers.swift).

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

    /// System calls `LinkOpener` makes, replaceable in unit tests so Universal Link hits, misses and fallbacks run
    /// without leaving the process.
    struct Platform {
        /// Tries to open `page` in an installed app that claims it as a Universal Link (`universalLinksOnly: true`),
        /// calling `done(true)` if an app took it or `done(false)` if none did.
        var openUniversalLink: (URL, @escaping @MainActor @Sendable (Bool) -> Void) -> Void
        /// Hands `url` to the system default handler (an installed app if one claims it, else the default browser).
        var openSystem: (URL) -> Void
        /// Hands `page` to the chosen browser `id`, calling `failed()` if that browser didn't take it.
        var openBrowser: (URL, String, @escaping @MainActor @Sendable () -> Void) -> Void
        /// Presents the in-app Safari view over `host`.
        var presentSafari: (URL, UIViewController) -> Void
        /// Shows the app's own notice over `host` for a loopback or refused link.
        var showNotice: (String, UIViewController) -> Void

        static let live = Platform(
            openUniversalLink: { page, done in
                UIApplication.shared.open(page, options: [.universalLinksOnly: true], completionHandler: done)
            },
            openSystem: { url in
                UIApplication.shared.open(url)
            },
            openBrowser: { page, id, failed in
                #if targetEnvironment(macCatalyst)
                if !MacBrowsers.open(page, in: id, failed: failed) { failed() }
                #else
                guard let link = PhoneBrowsers.link(page, in: id) else { failed(); return }
                UIApplication.shared.open(link) { opened in
                    if !opened { failed() }
                }
                #endif
            },
            presentSafari: { page, host in
                LinkOpener.presentSafari(page, from: host)
            },
            showNotice: { text, host in
                LinkOpener.notice(text, from: host)
            }
        )
    }

    static func open(_ url: URL, from host: UIViewController) {
        open(url, from: host, choice: choice, platform: .live)
    }

    static func open(_ url: URL, from host: UIViewController, choice: LinkBrowserChoice, platform: Platform) {
        switch LinkRoute.route(url, choice: choice) {
        case .inApp(let page):
            // Let an installed app that claims the link (Universal Links) take it before falling back to the Safari view.
            platform.openUniversalLink(page) { [weak host] opened in
                guard !opened, let host else { return }
                platform.presentSafari(page, host)
            }
        case .outside(let page, let browser):
            hand(page, to: browser, platform: platform)
        case .file(let path):
            // A file on the bot's computer opens in the app (a page runs live there), never in a browser. Only a chat
            // knows whose computer that is.
            if let chat = host as? ChatViewController, let link = FileLinks.url(path), chat.openFileLink(link) { return }
            platform.showNotice(LinkTargets.refusedNotice, host)
        case .system(let other):
            platform.openSystem(other)
        case .loopback:
            platform.showNotice(LinkTargets.loopbackNotice(device: DeviceWord.name), host)
        case .refused:
            platform.showNotice(LinkTargets.refusedNotice, host)
        }
    }

    /// A web page the app itself sends out (a menu's "Open in …", a Get a Key button, a help page): an installed app
    /// that claims the link first, else the browser chosen, else the default one. Never the Safari view, and anything
    /// that isn't a web page goes to the system as before.
    static func openOutside(_ url: URL) {
        openOutside(url, choice: choice, platform: .live)
    }

    static func openOutside(_ url: URL, choice: LinkBrowserChoice, platform: Platform) {
        if FileLinks.path(fromLink: url) != nil { AppLog.note("links", "a file link isn't sent outside the app"); return }
        let target = LinkTargets.target(url)
        // A file never goes to the system: the Mac would hand a page to its browser.
        if case .file = target { AppLog.note("links", "a file link isn't sent outside the app"); return }
        guard case .page(let page) = target else { platform.openSystem(url); return }
        if case .browser(let id) = choice { hand(page, to: id, platform: platform) } else { hand(page, to: nil, platform: platform) }
    }

    /// For SwiftUI pages (`.environment(\.openURL, LinkOpener.openURLAction)`): an installed app that claims the link,
    /// else the Safari view while links open in the app, else the browser chosen.
    static var openURLAction: OpenURLAction {
        OpenURLAction { url in
            handleOpenURL(
                url,
                choice: choice,
                host: { FailureAlert.topmost(UIApplication.shared.hqKeyWindow?.rootViewController) },
                platform: .live
            )
        }
    }

    static func handleOpenURL(
        _ url: URL,
        choice: LinkBrowserChoice,
        host: () -> UIViewController?,
        platform: Platform
    ) -> OpenURLAction.Result {
        if FileLinks.path(fromLink: url) != nil {
            AppLog.note("links", "a file link isn't sent outside the app")
            return .handled
        }
        let target = LinkTargets.target(url)
        if case .file = target {
            AppLog.note("links", "a file link isn't sent outside the app")
            return .handled
        }
        guard case .page = target else { return .systemAction }
        if choice == .inApp {
            if let presenter = host() {
                open(url, from: presenter, choice: choice, platform: platform)
                return .handled
            }
            return .systemAction(url, prefersInApp: true)
        }
        openOutside(url, choice: choice, platform: platform)
        return .handled
    }

    private static func presentSafari(_ page: URL, from host: UIViewController) {
        // The Universal Link check returned asynchronously: skip if the host left the screen or already presented
        // something (such as a second tap while the first Safari view is coming up).
        guard host.viewIfLoaded?.window != nil, !host.isBeingDismissed,
              !(host.navigationController?.isBeingDismissed ?? false),
              host.presentedViewController == nil else { return }
        let safari = SFSafariViewController(url: page)
        safari.dismissButtonStyle = .done
        safari.view.accessibilityIdentifier = "link.safari"
        host.present(safari, animated: true)
    }

    /// Hands `page` to an installed app that claims it (Universal Links), else the browser `id` (nil: the default
    /// browser). If that browser doesn't take it (removed since, or it refused), the default browser does, so a tap
    /// always opens the page somewhere.
    private static func hand(_ page: URL, to id: String?, platform: Platform) {
        // Default browser: `UIApplication.shared.open` already gives installed Universal Link apps first crack.
        guard let id else { platform.openSystem(page); return }
        let fallBack: @MainActor @Sendable () -> Void = {
            AppLog.note("links", "the chosen browser didn't take the page: default browser")
            platform.openSystem(page)
        }
        // A specific browser rewrites the address (iOS) or names the browser bundle (Mac), which bypasses Universal
        // Links: try an installed app first, and hand to the browser only if none claimed the link.
        platform.openUniversalLink(page) { opened in
            guard !opened else { return }
            platform.openBrowser(page, id, fallBack)
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
