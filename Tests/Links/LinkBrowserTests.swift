import Foundation
import SafariServices
import SwiftUI
import Testing
import UIKit
@testable import HermesHQNative

/// [links-browser] Settings › Open Links In: web links go to the browser chosen; a file a bot made never does.
@Suite struct LinkBrowserTests {
    private let everyChoice: [LinkBrowserChoice] = [.inApp, .system, .browser("chrome"), .browser("com.example.browser")]

    @Test func webPagesFollowTheChoice() {
        let page = URL(string: "https://example.com/report.html?week=2#top")!
        #expect(LinkRoute.route(page, choice: .inApp) == .inApp(page))
        #expect(LinkRoute.route(page, choice: .system) == .outside(page, browser: nil))
        #expect(LinkRoute.route(page, choice: .browser("chrome")) == .outside(page, browser: "chrome"))
    }

    /// The owner's rule: a local HTML file opens inside the app whatever browser is chosen.
    @Test func filesNeverLeaveTheApp() {
        let links: [(String, String)] = [
            ("file:///Users/me/dashboards/revenue.html", "/Users/me/dashboards/revenue.html"),
            ("file://localhost/Users/me/dashboards/revenue.html", "/Users/me/dashboards/revenue.html"),
            ("FILE:///Users/me/Sales%20Report.htm", "/Users/me/Sales Report.htm"),
            ("file:///C:/Users/me/report.html", "C:/Users/me/report.html"),
            ("file:///Users/me/notes.md", "/Users/me/notes.md"),
            (FileLinks.url("/Users/me/dashboards/revenue.html")!.absoluteString, "/Users/me/dashboards/revenue.html"),
            (FileLinks.url("~/pages/index.html")!.absoluteString, "~/pages/index.html"),
        ]
        for choice in everyChoice {
            for (link, path) in links {
                #expect(LinkRoute.route(URL(string: link)!, choice: choice) == .file(path), "\(link) with \(choice)")
            }
        }
    }

    /// Nothing but an http(s) page on another computer is ever handed to a browser.
    @Test func onlyWebPagesGoOutside() {
        let stay = ["http://localhost:8000/report.html", "http://127.0.0.1:3000/index.html", "http://[::1]:9/a.html",
                    "file://elsewhere.example.com/a.html", "file:///", "javascript:alert(1)", "data:text/html,<p>hi</p>",
                    "ftp://example.com/a.html", "about:blank", "#media:abc", "report.html", "/Users/me/report.html",
                    "mailto:a@example.com", "tel:5550100"]
        for choice in everyChoice {
            for link in stay {
                guard let url = URL(string: link) else { continue }
                switch LinkRoute.route(url, choice: choice) {
                case .inApp, .outside: Issue.record("\(link) went to a browser with \(choice)")
                case .file, .system, .loopback, .refused: break
                }
            }
        }
        #expect(LinkRoute.route(URL(string: "http://localhost:8000/report.html")!, choice: .browser("chrome")) == .loopback)
        #expect(LinkRoute.route(URL(string: "mailto:a@example.com")!, choice: .system) == .system(URL(string: "mailto:a@example.com")!))
    }

    @Test func phoneBrowserLinks() {
        let page = URL(string: "https://example.com/a%20b?q=one two&x=1#frag".replacingOccurrences(of: " ", with: "%20"))!
        #expect(PhoneBrowsers.link(page, in: "chrome")?.absoluteString == "googlechromes://example.com/a%20b?q=one%20two&x=1#frag")
        #expect(PhoneBrowsers.link(URL(string: "http://example.com/")!, in: "chrome")?.absoluteString == "googlechrome://example.com/")
        #expect(PhoneBrowsers.link(page, in: "edge")?.absoluteString == "microsoft-edge-https://example.com/a%20b?q=one%20two&x=1#frag")
        #expect(PhoneBrowsers.link(URL(string: "HTTP://example.com/")!, in: "edge")?.absoluteString == "microsoft-edge-http://example.com/")
        let wrapped = "https%3A%2F%2Fexample.com%2Fa%2520b%3Fq%3Done%2520two%26x%3D1%23frag"
        #expect(PhoneBrowsers.link(page, in: "firefox")?.absoluteString == "firefox://open-url?url=" + wrapped)
        #expect(PhoneBrowsers.link(page, in: "firefox-focus")?.absoluteString == "firefox-focus://open-url?url=" + wrapped)
        #expect(PhoneBrowsers.link(page, in: "brave")?.absoluteString == "brave://open-url?url=" + wrapped)
        // The wrapped address comes back whole.
        let query = URLComponents(string: "firefox://open-url?url=" + wrapped)?.queryItems?.first?.value
        #expect(query == page.absoluteString)
        #expect(PhoneBrowsers.link(page, in: "netscape") == nil)
        #expect(PhoneBrowsers.link(URL(string: "file:///Users/me/a.html")!, in: "chrome") == nil)
        #expect(PhoneBrowsers.link(URL(string: "mailto:a@example.com")!, in: "firefox") == nil)
    }

    /// Info.plist lists every scheme asked about, or iOS says the browser isn't installed.
    @Test func plistListsTheProbes() throws {
        let listed = Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String] ?? []
        #expect(Set(PhoneBrowsers.probes).isSubset(of: Set(listed)), "\(listed)")
        #expect(Set(PhoneBrowsers.all.map(\.id)).count == PhoneBrowsers.all.count)
    }

    @Test func choiceIsSavedAndFallsBack() {
        for choice in [LinkBrowserChoice.system, .browser("chrome"), .browser("com.example.browser")] {
            #expect(LinkBrowserChoice(saved: choice.saved) == choice)
        }
        #expect(LinkBrowserChoice(saved: "browser:") == nil)
        #expect(LinkBrowserChoice(saved: "nonsense") == nil)
        let installed = [LinkBrowser(id: "chrome", name: "Chrome")]
        #expect(LinkBrowserChoice.browser("chrome").resolved(installed: installed) == .browser("chrome"))
        #expect(LinkBrowserChoice.browser("firefox").resolved(installed: installed) == .system)   // removed since
        #expect(LinkBrowserChoice.inApp.resolved(installed: []) == .inApp)
        #expect(LinkBrowserChoice.browser("chrome").title(installed: installed) == "Chrome")
        #expect(LinkBrowserChoice.system.title(installed: installed) == "Default Browser")
        #expect(LinkBrowserChoice.inApp.title(installed: installed) == "In the App")
    }

    // MARK: Universal Links first (installed apps before in-app Safari or a specific browser)

    @MainActor private final class FakePlatform {
        var universalLinkOpens = false
        var deferUniversalLink = false
        var browserOpens = true
        var pendingUniversalCompletions: [@MainActor @Sendable (Bool) -> Void] = []
        var universalLinks: [URL] = []
        var systemLinks: [URL] = []
        var browserLinks: [(URL, String)] = []
        var safariLinks: [URL] = []
        var notices: [String] = []

        var platform: LinkOpener.Platform {
            LinkOpener.Platform(
                openUniversalLink: { [weak self] url, done in
                    guard let self else { return }
                    self.universalLinks.append(url)
                    if self.deferUniversalLink {
                        self.pendingUniversalCompletions.append(done)
                    } else {
                        done(self.universalLinkOpens)
                    }
                },
                openSystem: { [weak self] url in
                    self?.systemLinks.append(url)
                },
                openBrowser: { [weak self] url, id, failed in
                    guard let self else { return }
                    self.browserLinks.append((url, id))
                    if !self.browserOpens { failed() }
                },
                presentSafari: { [weak self] url, _ in
                    self?.safariLinks.append(url)
                },
                showNotice: { [weak self] text, _ in
                    self?.notices.append(text)
                }
            )
        }
    }

    @MainActor @Test func inAppTriesInstalledAppFirstAndSkipsSafariWhenHandled() {
        let fake = FakePlatform()
        fake.universalLinkOpens = true
        let page = URL(string: "https://app.example.com/workspace/page-123")!
        let host = UIViewController()
        LinkOpener.open(page, from: host, choice: .inApp, platform: fake.platform)
        #expect(fake.universalLinks == [page])
        #expect(fake.safariLinks.isEmpty)
        #expect(fake.browserLinks.isEmpty)
        #expect(fake.systemLinks.isEmpty)
    }

    @MainActor @Test func inAppFallsBackToSafariWhenNoInstalledAppClaimsLink() {
        let fake = FakePlatform()
        fake.universalLinkOpens = false
        let page = URL(string: "https://example.com/article")!
        let host = UIViewController()
        LinkOpener.open(page, from: host, choice: .inApp, platform: fake.platform)
        #expect(fake.universalLinks == [page])
        #expect(fake.safariLinks == [page])
        #expect(fake.browserLinks.isEmpty)
        #expect(fake.systemLinks.isEmpty)
    }

    @MainActor @Test func inAppSkipsSafariWhenHostDeallocatesBeforeUniversalLinkReturns() {
        let fake = FakePlatform()
        fake.deferUniversalLink = true
        let page = URL(string: "https://example.com/article")!
        var host: UIViewController? = UIViewController()
        LinkOpener.open(page, from: host!, choice: .inApp, platform: fake.platform)
        #expect(fake.pendingUniversalCompletions.count == 1)
        host = nil
        fake.pendingUniversalCompletions[0](false)
        #expect(fake.safariLinks.isEmpty)
    }

    @MainActor @Test func chosenBrowserTriesInstalledAppFirstBeforeRewritingURL() {
        let fake = FakePlatform()
        fake.universalLinkOpens = true
        let page = URL(string: "https://app.example.com/workspace/page-123")!
        let host = UIViewController()
        LinkOpener.open(page, from: host, choice: .browser("chrome"), platform: fake.platform)
        #expect(fake.universalLinks == [page])
        #expect(fake.browserLinks.isEmpty)
        #expect(fake.systemLinks.isEmpty)
        #expect(fake.safariLinks.isEmpty)
    }

    @MainActor @Test func chosenBrowserFallsBackToBrowserThenDefaultWhenNoAppClaimsLink() {
        let page = URL(string: "https://example.com/docs")!
        let host = UIViewController()

        let opensInBrowser = FakePlatform()
        opensInBrowser.universalLinkOpens = false
        opensInBrowser.browserOpens = true
        LinkOpener.open(page, from: host, choice: .browser("chrome"), platform: opensInBrowser.platform)
        #expect(opensInBrowser.universalLinks == [page])
        #expect(opensInBrowser.browserLinks.count == 1 && opensInBrowser.browserLinks[0].0 == page && opensInBrowser.browserLinks[0].1 == "chrome")
        #expect(opensInBrowser.systemLinks.isEmpty)

        let browserRemoved = FakePlatform()
        browserRemoved.universalLinkOpens = false
        browserRemoved.browserOpens = false
        LinkOpener.open(page, from: host, choice: .browser("chrome"), platform: browserRemoved.platform)
        #expect(browserRemoved.universalLinks == [page])
        #expect(browserRemoved.browserLinks.count == 1)
        #expect(browserRemoved.systemLinks == [page])
    }

    @MainActor @Test func defaultBrowserHandsDirectlyToSystem() {
        let fake = FakePlatform()
        let page = URL(string: "https://app.example.com/workspace/page-123")!
        let host = UIViewController()
        LinkOpener.open(page, from: host, choice: .system, platform: fake.platform)
        #expect(fake.systemLinks == [page])
        #expect(fake.universalLinks.isEmpty)
        #expect(fake.safariLinks.isEmpty)
        #expect(fake.browserLinks.isEmpty)
    }

    @MainActor @Test func openOutsideTriesInstalledAppFirstForChosenBrowserAndBlocksFiles() {
        let page = URL(string: "https://app.example.com/doc/42")!

        let handled = FakePlatform()
        handled.universalLinkOpens = true
        LinkOpener.openOutside(page, choice: .browser("chrome"), platform: handled.platform)
        #expect(handled.universalLinks == [page])
        #expect(handled.browserLinks.isEmpty)
        #expect(handled.systemLinks.isEmpty)

        let missed = FakePlatform()
        missed.universalLinkOpens = false
        LinkOpener.openOutside(page, choice: .browser("chrome"), platform: missed.platform)
        #expect(missed.universalLinks == [page])
        #expect(missed.browserLinks.count == 1 && missed.browserLinks[0].1 == "chrome")

        let fileBlocked = FakePlatform()
        LinkOpener.openOutside(URL(string: "file:///Users/me/report.html")!, choice: .browser("chrome"), platform: fileBlocked.platform)
        LinkOpener.openOutside(FileLinks.url("/Users/me/report.html")!, choice: .system, platform: fileBlocked.platform)
        #expect(fileBlocked.universalLinks.isEmpty && fileBlocked.browserLinks.isEmpty && fileBlocked.systemLinks.isEmpty)
    }

    @MainActor @Test func swiftUIOpenURLActionTriesInstalledAppFirst() {
        let page = URL(string: "https://app.example.com/doc/99")!
        let host = UIViewController()

        let handled = FakePlatform()
        handled.universalLinkOpens = true
        _ = LinkOpener.handleOpenURL(page, choice: .inApp, host: { host }, platform: handled.platform)
        #expect(handled.universalLinks == [page])
        #expect(handled.safariLinks.isEmpty)

        let missed = FakePlatform()
        missed.universalLinkOpens = false
        _ = LinkOpener.handleOpenURL(page, choice: .inApp, host: { host }, platform: missed.platform)
        #expect(missed.universalLinks == [page])
        #expect(missed.safariLinks == [page])

        let browserHandled = FakePlatform()
        browserHandled.universalLinkOpens = true
        _ = LinkOpener.handleOpenURL(page, choice: .browser("firefox"), host: { host }, platform: browserHandled.platform)
        #expect(browserHandled.universalLinks == [page])
        #expect(browserHandled.browserLinks.isEmpty)

        let fileBlocked = FakePlatform()
        _ = LinkOpener.handleOpenURL(URL(string: "file:///Users/me/report.html")!, choice: .inApp, host: { host }, platform: fileBlocked.platform)
        _ = LinkOpener.handleOpenURL(FileLinks.url("/Users/me/report.html")!, choice: .inApp, host: { host }, platform: fileBlocked.platform)
        #expect(fileBlocked.universalLinks.isEmpty && fileBlocked.safariLinks.isEmpty && fileBlocked.systemLinks.isEmpty)
    }

    @MainActor @Test func nonWebLinksNeverProbeUniversalLinks() {
        let fake = FakePlatform()
        let host = UIViewController()
        LinkOpener.open(URL(string: "http://localhost:3000/report.html")!, from: host, choice: .inApp, platform: fake.platform)
        LinkOpener.open(URL(string: "javascript:alert(1)")!, from: host, choice: .inApp, platform: fake.platform)
        LinkOpener.open(URL(string: "file:///Users/me/report.html")!, from: host, choice: .inApp, platform: fake.platform)
        LinkOpener.open(URL(string: "mailto:a@example.com")!, from: host, choice: .inApp, platform: fake.platform)
        #expect(fake.universalLinks.isEmpty)
        #expect(fake.safariLinks.isEmpty)
        #expect(fake.browserLinks.isEmpty)
        #expect(fake.systemLinks == [URL(string: "mailto:a@example.com")!])
        #expect(fake.notices.count == 3)
    }

    #if !targetEnvironment(macCatalyst)
    /// Live smoke test on Simulator: an unclaimed HTTPS link falls through `universalLinksOnly` to `SFSafariViewController`,
    /// and a second rapid tap does not try to present a second Safari view.
    @MainActor @Test func liveUnclaimedLinkFallsBackToInAppSafari() async {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer {
            root.dismiss(animated: false)
            window.isHidden = true
        }
        let page = URL(string: "https://hermes-hq.invalid/page")!
        LinkOpener.open(page, from: root, choice: .inApp, platform: .live)
        for _ in 0..<40 where !(root.presentedViewController is SFSafariViewController) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(root.presentedViewController is SFSafariViewController)
        let first = root.presentedViewController
        LinkOpener.open(page, from: root, choice: .inApp, platform: .live)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(root.presentedViewController === first)
    }
    #endif
}
