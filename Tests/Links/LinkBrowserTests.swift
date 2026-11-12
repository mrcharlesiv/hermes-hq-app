import Foundation
import Testing
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
}
