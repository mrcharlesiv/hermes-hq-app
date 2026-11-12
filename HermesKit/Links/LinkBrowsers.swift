// [links-browser] Settings › Open Links In (owner 2026-11-12: "an option to load URLs in an external browser of
// choice, but local html files should always be loaded inside the app"). Which browser a tapped web link opens in:
// the app's own Safari view (iPhone and iPad), the device's default browser, or one browser by name.
//
// The rule that keeps a bot's page in the app lives in one place, `LinkRoute.route`: only an http(s) address on
// another computer ever leaves the app. A file (a `#file:` path, a `file://` link, a page card, a tile) never
// reaches a browser at all; it opens in the app's viewer, where a page runs live.

import Foundation

/// A browser the links can open in: on the iPhone one of `PhoneBrowsers` (by a short id), on the Mac any app that
/// takes web links (by its bundle id).
nonisolated struct LinkBrowser: Hashable, Sendable, Identifiable {
    var id: String
    var name: String
}

nonisolated enum LinkBrowserChoice: Hashable, Sendable {
    /// The Safari view inside the app (iPhone and iPad; the Mac has none).
    case inApp
    /// The device's default browser.
    case system
    /// One browser, by `LinkBrowser.id`.
    case browser(String)

    /// Stays on each device (not in `SyncedSettingKeys`): the browsers on the Mac aren't the ones on the iPhone.
    static let key = "hqn.links.browser"
    static let didChange = Notification.Name("hqn.links.browserDidChange")

    static var platformDefault: LinkBrowserChoice {
        #if targetEnvironment(macCatalyst)
        .system
        #else
        .inApp
        #endif
    }

    /// What is saved, whether or not that browser is still installed (`LinkOpener.choice` checks).
    static var stored: LinkBrowserChoice {
        get { UserDefaults.standard.string(forKey: key).flatMap(LinkBrowserChoice.init(saved:)) ?? platformDefault }
        set {
            if newValue == platformDefault { UserDefaults.standard.removeObject(forKey: key) }
            else { UserDefaults.standard.set(newValue.saved, forKey: key) }
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    var saved: String {
        switch self {
        case .inApp: "app"
        case .system: "default"
        case .browser(let id): "browser:" + id
        }
    }

    init?(saved: String) {
        switch saved {
        case "app":
            #if targetEnvironment(macCatalyst)
            return nil   // a value from another kind of device: the Mac has no Safari view
            #else
            self = .inApp
            #endif
        case "default": self = .system
        default:
            guard saved.hasPrefix("browser:"), saved.count > 8 else { return nil }
            self = .browser(String(saved.dropFirst(8)))
        }
    }

    /// The choice that holds given the browsers installed now: one that was removed falls back to the default
    /// browser, and is taken up again if it comes back.
    func resolved(installed: [LinkBrowser]) -> LinkBrowserChoice {
        if case .browser(let id) = self, !installed.contains(where: { $0.id == id }) { return .system }
        return self
    }

    /// Its name in Settings.
    func title(installed: [LinkBrowser]) -> String {
        switch self {
        case .inApp: "In the App"
        case .system: "Default Browser"
        case .browser(let id): installed.first { $0.id == id }?.name ?? "Default Browser"
        }
    }
}

/// Where a tapped link goes, given the browser chosen.
nonisolated enum LinkRoute: Equatable, Sendable {
    /// The Safari view inside the app.
    case inApp(URL)
    /// A browser outside the app: the one named, or the default browser (nil).
    case outside(URL, browser: String?)
    /// A file on the gateway computer: the app's own viewer, always.
    case file(String)
    /// mailto:, tel: and the like.
    case system(URL)
    case loopback
    case refused

    static func route(_ url: URL, choice: LinkBrowserChoice) -> LinkRoute {
        // A path a bot named (`FileLinks`), whatever it is called: never a web address.
        if let path = FileLinks.path(fromLink: url) { return .file(path) }
        switch LinkTargets.target(url) {
        case .file(let path): return .file(path)
        case .system(let other): return .system(other)
        case .loopback: return .loopback
        case .refused: return .refused
        case .page(let page):
            switch choice {
            case .inApp: return .inApp(page)
            case .system: return .outside(page, browser: nil)
            case .browser(let id): return .outside(page, browser: id)
            }
        }
    }
}

/// The iPhone and iPad browsers that take a page from another app, each by its own link. iOS has no way to list
/// browsers or to hand a page to one by name; these are the ones that publish a link for it. Any other browser is
/// reached by making it the default one in the Settings app and choosing Default Browser here.
nonisolated enum PhoneBrowsers {
    struct Known: Sendable {
        var id: String
        var name: String
        /// The scheme asked about to see whether the app is installed (listed in Info.plist's
        /// `LSApplicationQueriesSchemes`, or iOS answers no).
        var probe: String
        var link: @Sendable (URL) -> URL?
    }

    static let all: [Known] = [
        Known(id: "chrome", name: "Chrome", probe: "googlechrome") { swapScheme($0, http: "googlechrome", https: "googlechromes") },
        Known(id: "firefox", name: "Firefox", probe: "firefox") { wrapped($0, "firefox://open-url?url=") },
        Known(id: "firefox-focus", name: "Firefox Focus", probe: "firefox-focus") { wrapped($0, "firefox-focus://open-url?url=") },
        Known(id: "edge", name: "Edge", probe: "microsoft-edge-https") { swapScheme($0, http: "microsoft-edge-http", https: "microsoft-edge-https") },
        Known(id: "brave", name: "Brave", probe: "brave") { wrapped($0, "brave://open-url?url=") },
    ]

    /// The schemes Info.plist has to list.
    static var probes: [String] { all.map(\.probe) }

    /// The link that opens `page` in the browser `id`; nil when the browser isn't known or the page isn't http(s).
    static func link(_ page: URL, in id: String) -> URL? {
        guard let scheme = page.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return all.first { $0.id == id }?.link(page)
    }

    /// "https://example.com/a?b=c" → "googlechromes://example.com/a?b=c": the address as written, under the browser's
    /// own scheme.
    private static func swapScheme(_ page: URL, http: String, https: String) -> URL? {
        let text = page.absoluteString
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let secure = text[..<colon].lowercased() == "https"
        return URL(string: (secure ? https : http) + text[colon...])
    }

    /// "firefox://open-url?url=https%3A%2F%2Fexample.com%2Fa%3Fb%3Dc": the whole address as one query value.
    private static func wrapped(_ page: URL, _ prefix: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let value = page.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: prefix + value)
    }
}
