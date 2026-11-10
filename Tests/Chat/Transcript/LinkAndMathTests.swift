// [transcript] Link titles and icons (the markup reading and the bounded read's guards), and math in words
// (docs/spec/3x-transcript.md §3.5, §3.7).

import Foundation
import UIKit
import Testing
@testable import HermesHQNative

@Suite struct LinkPreviewParsingTests {
    @Test func titles() {
        #expect(LinkPreviewParsing.titleFromHTML("<html><head><title> Example \n Domain </title></head>") == "Example Domain")
        #expect(LinkPreviewParsing.titleFromHTML("<title>Tom &amp; Jerry &#8212; &#x1F600; &mdash; caf&eacute;</title>") == "Tom & Jerry — 😀 — caf&eacute;")
        #expect(LinkPreviewParsing.titleFromHTML("<title></title><meta property=\"og:title\" content=\"From OG\">") == "From OG")
        #expect(LinkPreviewParsing.titleFromHTML("<meta name='twitter:title' content='From Twitter'>") == "From Twitter")
        #expect(LinkPreviewParsing.titleFromHTML("<title>Just a moment...</title>") == "")
        #expect(LinkPreviewParsing.titleFromHTML("<title>Sign in - Google Accounts</title>") == "")
        #expect(LinkPreviewParsing.titleFromHTML("<title>404 Error</title>") == "")
        #expect(LinkPreviewParsing.titleFromHTML("<title>Access Denied</title>") == "")
        #expect(LinkPreviewParsing.titleFromHTML("") == "")
        #expect(LinkPreviewParsing.titleFromHTML("<title>" + String(repeating: "t", count: 500) + "</title>").count == 240)
        // Reordering marks never reach the screen.
        #expect(LinkPreviewParsing.titleFromHTML("<title>abc\u{202E}gnp.exe</title>") == "abcgnp.exe")
        // Only the first 256 KiB is read.
        let late = String(repeating: " ", count: 256 * 1024) + "<title>Too late</title>"
        #expect(LinkPreviewParsing.titleFromHTML(late) == "")
        #expect(LinkPreviewParsing.isSignInArrival(URL(string: "https://accounts.google.com/x")!))
        #expect(LinkPreviewParsing.isSignInArrival(URL(string: "https://example.com/login")!))
        #expect(!LinkPreviewParsing.isSignInArrival(URL(string: "https://example.com/blog")!))
    }

    @Test func iconCandidatesAreRankedAndHTTPSOnly() {
        let html = """
        <link rel="icon" href="/small.png" sizes="16x16">
        <link rel="icon" href="/big.png" sizes="192x192">
        <link rel="apple-touch-icon" href="touch.png">
        <link rel="mask-icon" href="/mask.svg">
        <link rel="icon" href="http://insecure.example/i.png">
        <link rel="stylesheet" href="/s.css">
        """
        let found = LinkPreviewParsing.iconCandidates(html, pageURL: "https://example.com/a/page")
        #expect(found == ["https://example.com/mask.svg", "https://example.com/big.png", "https://example.com/a/touch.png",
                          "https://example.com/apple-touch-icon.png", "https://example.com/favicon.ico"])
        #expect(LinkPreviewParsing.iconCandidates("", pageURL: "https://example.com/x")
                == ["https://example.com/apple-touch-icon.png", "https://example.com/favicon.ico", "https://example.com/favicon.png"])
    }

    @Test func magicBytesDecideWhatIsAPicture() {
        func padded(_ head: [UInt8]) -> Data { Data(head + [UInt8](repeating: 0, count: 64)) }
        #expect(LinkPreviewParsing.imageMime(padded([0x89, 0x50, 0x4E, 0x47])) == "image/png")
        #expect(LinkPreviewParsing.imageMime(padded([0xFF, 0xD8, 0xFF])) == "image/jpeg")
        #expect(LinkPreviewParsing.imageMime(padded([0x47, 0x49, 0x46, 0x38])) == "image/gif")
        #expect(LinkPreviewParsing.imageMime(padded([0, 0, 1, 0])) == "image/x-icon")
        #expect(LinkPreviewParsing.imageMime(padded([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])) == "image/webp")
        #expect(LinkPreviewParsing.imageMime(Data([0x89, 0x50, 0x4E, 0x47])) == "")                      // under 48 bytes
        #expect(LinkPreviewParsing.imageMime(Data("<html><body>blocked</body></html>                         ".utf8), declared: "image/png") == "")
        #expect(LinkPreviewParsing.imageMime(Data("<svg xmlns='http://www.w3.org/2000/svg'></svg>            ".utf8)) == "image/svg+xml")
    }

    @Test func aBareLinkShowsWhereItGoes() {
        #expect(LinkPreviewParsing.bareLinkLabel(title: nil, target: "https://www.example.com/docs/guide/?a=1#top") == "example.com/docs/guide…")
        #expect(LinkPreviewParsing.bareLinkLabel(title: nil, target: "https://example.com/") == "example.com")
        #expect(LinkPreviewParsing.bareLinkLabel(title: nil, target: "https://example.com:8443/x") == "example.com:8443/x")
        #expect(LinkPreviewParsing.bareLinkLabel(title: "Example Domain", target: "https://example.com/") == "Example Domain · example.com")
        #expect(LinkPreviewParsing.bareLinkLabel(title: "Docs | example.com", target: "https://www.example.com/x") == "Docs | example.com")
        #expect(LinkPreviewParsing.bareLinkLabel(title: " ", target: "https://example.com/a") == "example.com/a")
    }
}

/// A scripted fetcher: what each URL answers, and every read asked of it.
nonisolated final class ScriptedLinkFetcher: LinkFetching, @unchecked Sendable {
    private let lock = NSLock()
    var pages: [String: LinkFetchResult] = [:]
    var images: [String: LinkFetchResult] = [:]
    private(set) var asked: [String] = []
    private(set) var peak = 0
    private var active = 0
    var delay: Duration = .zero
    /// The first this many page reads fail as if the network were not there.
    var offlineReads = 0

    func page(_ url: URL) async throws -> LinkFetchResult {
        lock.withLock { asked.append(url.absoluteString); active += 1; peak = max(peak, active) }
        defer { lock.withLock { active -= 1 } }
        if delay > .zero { try? await Task.sleep(for: delay) }
        let offline = lock.withLock { () -> Bool in
            guard offlineReads > 0 else { return false }
            offlineReads -= 1
            return true
        }
        if offline { throw LinkFetchTransient(code: .notConnectedToInternet) }
        guard let result = lock.withLock({ pages[url.absoluteString] }) else { throw LinkFetchRefused(reason: "none") }
        return result
    }

    func image(_ url: URL) async throws -> LinkFetchResult {
        lock.withLock { asked.append(url.absoluteString) }
        guard let result = lock.withLock({ images[url.absoluteString] }) else { throw LinkFetchRefused(reason: "none") }
        return result
    }

    var requests: [String] { lock.withLock { asked } }
    var mostAtOnce: Int { lock.withLock { peak } }
}

@Suite struct LinkPreviewsTests {
    static let png = Data([0x89, 0x50, 0x4E, 0x47] + [UInt8](repeating: 1, count: 80))

    func page(_ url: String, _ html: String, type: String = "text/html; charset=utf-8") -> LinkFetchResult {
        LinkFetchResult(url: URL(string: url)!, type: type, data: Data(html.utf8))
    }

    @Test func oneReadPerURLAndTheIconFromTheSite() async {
        let fetcher = ScriptedLinkFetcher()
        fetcher.pages["https://example.com/"] = page("https://example.com/", "<title>Example Domain</title><link rel='icon' href='/i.png'>")
        fetcher.images["https://example.com/i.png"] = LinkFetchResult(url: URL(string: "https://example.com/i.png")!, type: "image/png", data: Self.png)
        let previews = LinkPreviews(fetcher: fetcher)
        async let a = previews.preview(for: "https://example.com/")
        async let b = previews.preview(for: "https://example.com/")
        let (first, second) = await (a, b)
        #expect(first == LinkPreview(title: "Example Domain", icon: Self.png) && second == first)
        _ = await previews.preview(for: "https://example.com/")
        #expect(fetcher.requests.filter { $0 == "https://example.com/" }.count == 1)
        #expect(await previews.known("https://example.com/")?.title == "Example Domain")
    }

    @Test func aFailureIsRememberedForTheRun() async {
        let fetcher = ScriptedLinkFetcher()
        let previews = LinkPreviews(fetcher: fetcher)
        #expect(await previews.preview(for: "https://down.example.com/x") == nil)
        #expect(await previews.preview(for: "https://down.example.com/x") == nil)
        #expect(fetcher.requests.filter { $0 == "https://down.example.com/x" }.count == 1)
        #expect(await previews.settled("https://down.example.com/x"))
    }

    @Test func aNetworkFailureIsAskedAgainAfterItsWait() async throws {
        let fetcher = ScriptedLinkFetcher()
        fetcher.offlineReads = 1
        fetcher.pages["https://example.com/"] = page("https://example.com/", "<title>Example Domain</title>")
        let previews = LinkPreviews(fetcher: fetcher, retryAfter: .milliseconds(200))
        #expect(await previews.preview(for: "https://example.com/") == nil)
        #expect(await previews.settled("https://example.com/"))
        // Inside the wait: not asked again.
        #expect(await previews.preview(for: "https://example.com/") == nil)
        #expect(fetcher.requests.filter { $0 == "https://example.com/" }.count == 1)
        try await Task.sleep(for: .milliseconds(250))
        #expect(await previews.preview(for: "https://example.com/")?.title == "Example Domain")
        #expect(fetcher.requests.filter { $0 == "https://example.com/" }.count == 2)
    }

    @Test func aRefusalIsNotAskedAgainAfterTheWait() async throws {
        let fetcher = ScriptedLinkFetcher()
        let previews = LinkPreviews(fetcher: fetcher, retryAfter: .milliseconds(50))
        #expect(await previews.preview(for: "https://down.example.com/x") == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await previews.preview(for: "https://down.example.com/x") == nil)
        #expect(fetcher.requests.filter { $0 == "https://down.example.com/x" }.count == 1)
    }

    @Test func privateAndLocalHostsAreNeverAsked() async {
        let fetcher = ScriptedLinkFetcher()
        let previews = LinkPreviews(fetcher: fetcher)
        for url in ["https://gateway.tail1234.ts.net/", "https://printer.local/", "https://127.0.0.1/", "https://[::1]/",
                    "https://169.254.1.1/", "https://10.0.0.5/", "http://example.com/", "https://user:pw@example.com/",
                    "javascript:alert(1)", "file:///etc/passwd", "https://localhost/"] {
            #expect(await previews.preview(for: url) == nil)
        }
        #expect(fetcher.requests.isEmpty)
    }

    @Test func atMostThreePageReadsAtOnce() async {
        let fetcher = ScriptedLinkFetcher()
        fetcher.delay = .milliseconds(40)
        let previews = LinkPreviews(fetcher: fetcher)
        await withTaskGroup(of: Void.self) { group in
            for n in 0..<12 { group.addTask { _ = await previews.preview(for: "https://site\(n).example.com/") } }
        }
        #expect(fetcher.mostAtOnce <= 3)
        #expect(Set(fetcher.requests).count == 12)
    }

    @Test func aSignInArrivalAndANonPictureIconGiveNothing() async {
        let fetcher = ScriptedLinkFetcher()
        fetcher.pages["https://docs.example.com/x"] = page("https://accounts.google.com/ServiceLogin", "<title>Private doc</title>")
        fetcher.images["https://accounts.google.com/favicon.ico"] = LinkFetchResult(
            url: URL(string: "https://accounts.google.com/favicon.ico")!, type: "image/png", data: Data("<html>blocked</html>                              ".utf8))
        let previews = LinkPreviews(fetcher: fetcher)
        #expect(await previews.preview(for: "https://docs.example.com/x") == nil)
    }
}

/// The real fetcher against a stubbed `URLProtocol` (no network): what it sends and what it refuses.
nonisolated final class LinkStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var seen: [URLRequest] = []
    /// When set, every load fails with it.
    nonisolated(unsafe) static var failure: URLError?
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.seen.append(request) }
        if let failure = Self.lock.withLock({ Self.failure }) { client?.urlProtocol(self, didFailWithError: failure); return }
        guard let handler = Self.lock.withLock({ Self.handler }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let (response, data) = handler(request)
        if (300..<400).contains(response.statusCode), let location = response.value(forHTTPHeaderField: "Location"),
           let next = URL(string: location) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: next), redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // In pieces, so the limit is met mid-body.
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + 32 * 1024)
            client?.urlProtocol(self, didLoad: data.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct LinkPreviewFetcherTests {
    func fetcher() -> LinkPreviewFetcher {
        let configuration = LinkPreviewFetcher.configuration()
        configuration.protocolClasses = [LinkStubProtocol.self]
        LinkStubProtocol.lock.withLock { LinkStubProtocol.seen = []; LinkStubProtocol.handler = nil; LinkStubProtocol.failure = nil }
        // Every name "resolves" to a public address, except the ones a test names private.
        let hosts = PublicHostPolicy.PublicHosts { host in host.contains("private") ? [[10, 0, 0, 5]] : [[93, 184, 216, 34]] }
        return LinkPreviewFetcher(session: URLSession(configuration: configuration), hosts: hosts, checksPeer: false)
    }

    nonisolated static func ok(_ url: URL, type: String, extra: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type].merging(extra) { $1 })!
    }

    @Test func theSessionKeepsNothing() {
        let c = LinkPreviewFetcher.configuration()
        #expect(c.httpCookieStorage == nil && c.urlCache == nil && c.urlCredentialStorage == nil)
        #expect(!c.httpShouldSetCookies && c.timeoutIntervalForRequest == 5 && c.timeoutIntervalForResource == 5)
        #expect(c.httpMaximumConnectionsPerHost == 2 && !c.waitsForConnectivity)
    }

    @Test func noCookieIsSentAndNoneIsStored() async throws {
        let f = fetcher()
        LinkStubProtocol.lock.withLock {
            LinkStubProtocol.handler = { request in
                (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                 headerFields: ["Content-Type": "text/html", "Set-Cookie": "sid=1; Path=/"])!, Data("<title>One</title>".utf8))
            }
        }
        _ = try await f.page(URL(string: "https://example.com/a")!)
        _ = try await f.page(URL(string: "https://example.com/b")!)
        let seen = LinkStubProtocol.lock.withLock { LinkStubProtocol.seen }
        #expect(seen.count == 2)
        for request in seen {
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Referer") == nil)
            #expect(request.value(forHTTPHeaderField: "Accept") == "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1")
        }
    }

    @Test func aLongPageIsReadToItsFirst256KiBAndABigIconIsRefused() async throws {
        let f = fetcher()
        let big = Data("<title>Kept</title>".utf8) + Data(repeating: 0x20, count: 257 * 1024)
        LinkStubProtocol.lock.withLock {
            LinkStubProtocol.handler = { request in
                request.url!.path.hasSuffix(".png") ? (Self.ok(request.url!, type: "image/png"), Data(repeating: 1, count: 65 * 1024 + 1))
                    : (Self.ok(request.url!, type: "text/html"), big)
            }
        }
        let page = try await f.page(URL(string: "https://example.com/long")!)
        #expect(page.data.count == 256 * 1024)
        #expect(LinkPreviewParsing.titleFromHTML(String(decoding: page.data, as: UTF8.self)) == "Kept")
        await #expect(throws: (any Error).self) { _ = try await f.image(URL(string: "https://example.com/i.png")!) }
    }

    @Test func redirectsDownToHTTPOrToAPrivateHostAreRefused() async {
        let f = fetcher()
        LinkStubProtocol.lock.withLock {
            LinkStubProtocol.handler = { request in
                let to = request.url!.path == "/down" ? "http://example.com/plain" : "https://private.example.com/x"
                return (HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": to])!, Data())
            }
        }
        await #expect(throws: (any Error).self) { _ = try await f.page(URL(string: "https://example.com/down")!) }
        await #expect(throws: (any Error).self) { _ = try await f.page(URL(string: "https://example.com/inside")!) }
        let seen = LinkStubProtocol.lock.withLock { LinkStubProtocol.seen.compactMap { $0.url?.absoluteString } }
        #expect(!seen.contains("http://example.com/plain") && !seen.contains("https://private.example.com/x"))
    }

    @Test func nonPublicHostsNeverConnect() async {
        let f = fetcher()
        for raw in ["https://gateway.tail1234.ts.net/", "https://printer.local/", "https://127.0.0.1/", "https://[::1]/",
                    "https://169.254.1.1/", "https://private.example.com/", "http://example.com/"] {
            await #expect(throws: (any Error).self) { _ = try await f.page(URL(string: raw)!) }
        }
        #expect(LinkStubProtocol.lock.withLock { LinkStubProtocol.seen.isEmpty })
    }

    @Test func noNetworkIsTransientAndA404IsARefusal() async {
        let f = fetcher()
        LinkStubProtocol.lock.withLock {
            LinkStubProtocol.handler = { request in
                (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!, Data())
            }
        }
        await #expect(throws: LinkFetchRefused.self) { _ = try await f.page(URL(string: "https://example.com/gone")!) }
        LinkStubProtocol.lock.withLock { LinkStubProtocol.failure = URLError(.notConnectedToInternet) }
        defer { LinkStubProtocol.lock.withLock { LinkStubProtocol.failure = nil } }
        await #expect(throws: LinkFetchTransient.self) { _ = try await f.page(URL(string: "https://example.com/off")!) }
        LinkStubProtocol.lock.withLock { LinkStubProtocol.failure = URLError(.serverCertificateUntrusted) }
        await #expect(throws: LinkFetchRefused.self) { _ = try await f.page(URL(string: "https://example.com/tls")!) }
    }

    @Test func peerAddressesAreRead() {
        #expect(LinkPreviewFetcher.addressBytes("93.184.216.34") == [93, 184, 216, 34])
        #expect(LinkPreviewFetcher.addressBytes("::1")?.count == 16)
        #expect(LinkPreviewFetcher.addressBytes("fe80::1%en0")?.count == 16)
        #expect(LinkPreviewFetcher.addressBytes("not an address") == nil)
        #expect(!PublicHostPolicy.publicAddress(LinkPreviewFetcher.addressBytes("10.0.0.5")!))
    }
}

@Suite struct MathTextTests {
    func sources(_ text: String) -> [String] { MathText.spans(in: text).map(\.source) }

    @Test func whatCountsAsAFormula() {
        #expect(sources("Energy is $E = mc^2$ here.") == ["E = mc^2"])
        #expect(sources("It costs $5 and $10 today.") == [])
        #expect(sources("Pay $5 = five dollars and $3") == [])               // "$5 = five dollars and $" closes before a digit
        #expect(sources("Block: $$\\frac{a}{b}$$ done") == ["\\frac{a}{b}"])
        #expect(MathText.spans(in: "$$x$$").first?.block == true)
        #expect(sources("Inline \\(a_1\\) and \\[b^2\\]") == ["a_1", "b^2"])
        #expect(MathText.spans(in: "\\[b^2\\]").first?.block == true)
        #expect(sources("unclosed $x = 1") == [])
        #expect(sources("unclosed $$x = 1") == [])
        #expect(sources("escaped \\$x = 1\\$") == [])
        #expect(sources("$ x = 1$") == [])                                    // a space after the opening $
        #expect(sources("$x = 1 $") == [])
        #expect(sources("$plain words$") == [])                               // nothing mathy inside
        #expect(sources("two $a^2$ and $b_1$") == ["a^2", "b_1"])
        // Price tiers (2026-11-04 shortlist): "~$$, OpenTable … $$-$$$, online" is prices, not one display formula.
        #expect(sources("Copper Kettle: ~5 min, ~$$, OpenTable. Bayside Grill: ~6 min, $$-$$$, online up to 4") == [])
        #expect(sources("Cheap ($) to fancy ($$$).") == [])
        #expect(sources("Then $$-\\frac{1}{2}$$ holds") == ["-\\frac{1}{2}"])   // a formula may still start with a minus
    }

    @Test func theSubsetReadsAsText() {
        #expect(MathText.readable("E = mc^2") == "E = mc²")
        #expect(MathText.readable("\\frac{a}{b}") == "a⁄b")
        #expect(MathText.readable("\\frac{a+b}{c}") == "(a+b)/c")
        #expect(MathText.readable("\\frac{n(n+1)}{2}") == "n(n+1)/2")   // brackets only where needed (F17)
        #expect(MathText.readable("\\sqrt{x}") == "√(x)")
        #expect(MathText.readable("\\alpha \\times \\beta \\leq \\infty") == "α × β ≤ ∞")
        #expect(MathText.readable("x_1 + x_{12} \\to y^{n+1}") == "x₁ + x₁₂ → yⁿ⁺¹")
        #expect(MathText.readable("a^{xy}") == "a^(xy)")
        // F17: a big operator's limit is wrapped for MathStyle to draw at a reduced size with a real baseline offset —
        // not squeezed into tiny Unicode sub/superscript glyphs (2026-10-31, "the Σ limits were tiny and cramped").
        let limits = "( ∑\(MathText.limitBelowOpen)i=1\(MathText.limitClose)\(MathText.limitAboveOpen)n\(MathText.limitClose) i )"
        #expect(MathText.readable("\\left( \\sum_{i=1}^{n} i \\right)") == limits)
        #expect(MathText.readable("\\text{speed of light} = c") == "speed of light = c")
        #expect(MathText.readable("a \\\\ b", block: true) == "a\nb")
        #expect(MathText.readable("a - b") == "a − b")
    }

    @Test func anythingOutsideTheSubsetFallsBackToSource() {
        #expect(MathText.readable("\\begin{aligned} a &= b \\end{aligned}") == nil)
        #expect(MathText.readable("\\frac{a}") == nil)                        // a missing brace group
        #expect(MathText.readable("\\frac{a}{b") == nil)
        #expect(MathText.readable("\\unknowncommand x") == nil)
        #expect(MathText.readable("a }") == nil)
        #expect(MathText.readable(String(repeating: "x", count: 10_000)) == nil)      // over the cap: source
        #expect(MathText.readable("") == nil)
    }
}

/// A path in backticks in a bot's reply opens in Files (owner, 2026-10-29).
@Suite struct FileLinkTests {
    private let style = ChatStyleCache.shared.style(for: .large)

    private func attributes(_ s: NSAttributedString, of word: String) -> [NSAttributedString.Key: Any] {
        let r = (s.string as NSString).range(of: word)
        return r.location == NSNotFound ? [:] : s.attributes(at: r.location, effectiveRange: nil)
    }

    @Test func pathsThatOpen() {
        let report = "/Users/me/.hermes/profiles/otto/research/weekly-notes-2026-10-28.md"
        #expect(FileLinks.path(inCode: report) == report)
        #expect(FileLinks.path(inCode: " \(report) ") == report)
        #expect(FileLinks.path(inCode: "~/notes/plan.md") == "~/notes/plan.md")
        #expect(FileLinks.path(inCode: "/Users/me/Projects/app") == "/Users/me/Projects/app")      // a folder at a home root
        #expect(FileLinks.path(inCode: "/Users/me/Projects/app/") == "/Users/me/Projects/app/")
        #expect(FileLinks.path(inCode: "/srv/app/src/main.swift:42") == "/srv/app/src/main.swift")  // the line number goes
        #expect(FileLinks.path(inCode: "/srv/app/src/main.swift:42:7") == "/srv/app/src/main.swift")
        #expect(FileLinks.path(inCode: "/data/out/report.tar.gz") == "/data/out/report.tar.gz")      // a name with an extension
        #expect(FileLinks.path(inCode: "/Users/me/My Reports/q3 plan.md") == "/Users/me/My Reports/q3 plan.md")
        #expect(FileLinks.path(inCode: "C:\\Users\\ivy\\notes.md") == "C:\\Users\\ivy\\notes.md")
        #expect(FileLinks.path(inCode: "/Users/me/project/Makefile") == "/Users/me/project/Makefile")
    }

    @Test func codeThatStaysCode() {
        for code in ["/new", "/compress", "/api/fs/list", "/api/status", "/README.md", "//server/share/a.md", "src/app.ts",
                     "npm test", "/usr/bin/env python3", "/Users/me/run.sh --fast", "/Users/me/*.md", "/Users/me/a.md && ls",
                     "https://example.com/a.md", "~", "~/", "/v1.2/x", "--user", "a.md", "/Users/me/$HOME/x.md"] {
            #expect(FileLinks.path(inCode: code) == nil, "\(code)")
        }
    }

    @Test func extensions() {
        #expect(FileLinks.hasExtension("report.md") && FileLinks.hasExtension("a.tar.gz") && FileLinks.hasExtension("x.mp4"))
        #expect(!FileLinks.hasExtension(".env") && !FileLinks.hasExtension("Makefile") && !FileLinks.hasExtension("v1.2")
            && !FileLinks.hasExtension("name.") && !FileLinks.hasExtension("a.toolongextension"))
    }

    @Test func linkRoundTrip() throws {
        let path = "/Users/me/My Reports/plan #2 (final).md"
        let url = try #require(FileLinks.url(path))
        #expect(url.absoluteString.hasPrefix("#file:"))
        #expect(FileLinks.path(fromLink: url) == path)
        #expect(FileLinks.path(fromLink: URL(string: "https://example.com")!) == nil)
        #expect(MarkdownMedia.ref(fromLink: url) == nil, "not a media link")
    }

    @Test func folderAndName() {
        #expect(FileLinks.place("/a/b/c.md") == ("/a/b", "c.md"))
        #expect(FileLinks.place("/a/b/") == ("/a/b", nil))
        #expect(FileLinks.place("/a.md") == ("/", "a.md"))
        #expect(FileLinks.place("~/plan.md") == ("~", "plan.md"))
        #expect(FileLinks.place("C:\\Users\\ivy\\notes.md") == ("C:\\Users\\ivy", "notes.md"))
        #expect(FileLinks.place("C:\\notes.md") == ("C:\\", "notes.md"))
    }

    @Test func aBotsReplyLinksThePath() throws {
        let md = "Full detail: `/Users/me/.hermes/profiles/otto/research/leak.md` and run `npm test`."
        let r = MarkdownRenderer.render(md, style: style, filePaths: true)
        guard case .text(let s) = try #require(r.blocks.first) else { Issue.record("not text"); return }
        let link = attributes(s, of: "leak.md")[.chatLink] as? URL
        #expect(link.flatMap(FileLinks.path(fromLink:)) == "/Users/me/.hermes/profiles/otto/research/leak.md")
        #expect(attributes(s, of: "leak.md")[.backgroundColor] != nil, "still drawn in its code box")
        #expect(attributes(s, of: "leak.md")[.chatCopy] == nil, "a tap opens the file, it doesn't copy")
        #expect(attributes(s, of: "npm test")[.chatLink] == nil)
        #expect(attributes(s, of: "npm test")[.chatCopy] as? String == "npm test")
        // In a quote too.
        let quoted = MarkdownRenderer.render("> see `/tmp/out/log.txt`", style: style, filePaths: true)
        guard case .quote(let q, _) = try #require(quoted.blocks.first) else { Issue.record("not a quote"); return }
        #expect(attributes(q, of: "log.txt")[.chatLink] != nil)
    }

    @Test func barePathsInWords() {
        func paths(_ s: String) -> [String] { FileLinks.bare(in: s).map(\.path) }
        let pdf = "/Users/me/.hermes/profiles/otto/research/q4/Planning-Notes-2026-10-29.pdf"
        #expect(paths(pdf) == [pdf])
        #expect(paths("Saved to \(pdf).") == [pdf])
        #expect(paths("(see ~/notes/plan.md, then /srv/app/main.swift:42)") == ["~/notes/plan.md", "/srv/app/main.swift"])
        #expect(paths("\"/tmp/out/log.txt\"") == ["/tmp/out/log.txt"])
        #expect(paths("Moved to /Users/me/Projects/app/") == ["/Users/me/Projects/app/"])
        #expect(paths("(/Users/me/plan(1).md).") == ["/Users/me/plan(1).md"])
        #expect(paths("C:\\Users\\ivy\\notes.md") == ["C:\\Users\\ivy\\notes.md"])
        for words in ["and/or", "24/7 support", "10/29/2026", "run /new to start", "GET /api/fs/list", "https://example.com/Users/a.md",
                      "example.com/Users/a.md", "src/app/main.swift", "//server/share/a.md", "/README.md", "~/ is home", "/Users/me/*.md", "/Users/me/Alex's.md"] {
            #expect(paths(words).isEmpty, "\(words)")
        }
        // The drawn range keeps a line number and leaves sentence punctuation out.
        let s = "Open /srv/app/main.swift:42."
        #expect(FileLinks.bare(in: s).first.map { (s as NSString).substring(with: $0.range) } == "/srv/app/main.swift:42")
    }

    @Test func aPathWrittenOutLinksToo() throws {
        // Otto's reply, 2026-10-30 (owner: "The files mentioned in this aren't clickable").
        let pdf = "/Users/me/.hermes/profiles/otto/research/q4/Planning-Notes-2026-10-29.pdf"
        let md = "Don't say \"travel.\"\n\nFiles:\n- \(pdf)\n- /Users/me/reach_62/my_HANGUPS.md\n\nSee https://example.com/a.md and `npm test`."
        let r = MarkdownRenderer.render(md, style: style, filePaths: true)
        guard case .text(let s) = try #require(r.blocks.first) else { Issue.record("not text"); return }
        for word in ["/Users/me", "Planning-Notes-2026-10-29.pdf"] {
            let link = attributes(s, of: word)[.chatLink] as? URL
            #expect(link.flatMap(FileLinks.path(fromLink:)) == pdf, "\(word)")
            #expect(attributes(s, of: word)[.foregroundColor] as? UIColor == MarkdownTheme.bot.link)
        }
        // "_" is markup: the parser hands the path over in pieces, the link still covers all of it.
        let hangups = (attributes(s, of: "/Users/me/reach")[.chatLink] as? URL).flatMap(FileLinks.path(fromLink:))
        #expect(hangups == "/Users/me/reach_62/my_HANGUPS.md")
        #expect((attributes(s, of: "HANGUPS.md")[.chatLink] as? URL).flatMap(FileLinks.path(fromLink:)) == hangups)
        #expect(attributes(s, of: "Files:")[.chatLink] == nil)
        #expect(attributes(s, of: "example.com")[.chatLink] as? URL == URL(string: "https://example.com/a.md"), "a web address stays one")
        // Pages that draw markdown, and your own message, leave the words alone.
        guard case .text(let plain) = try #require(MarkdownRenderer.render(md, style: style).blocks.first) else { Issue.record("not text"); return }
        #expect(attributes(plain, of: "Planning-Notes")[.chatLink] == nil)
        guard case .text(let mine) = try #require(MarkdownRenderer.renderUser(md, style: style).blocks.first) else { Issue.record("not text"); return }
        #expect(attributes(mine, of: "Planning-Notes")[.chatLink] == nil)
    }

    @Test func onlyWhereAsked() throws {
        let md = "Saved to `/Users/me/notes/plan.md`."
        guard case .text(let s) = try #require(MarkdownRenderer.render(md, style: style).blocks.first) else { Issue.record("not text"); return }
        #expect(attributes(s, of: "plan.md")[.chatLink] == nil, "pages that draw markdown keep code as code")
        guard case .text(let mine) = try #require(MarkdownRenderer.renderUser(md, style: style).blocks.first) else { Issue.record("not text"); return }
        #expect(attributes(mine, of: "plan.md")[.chatLink] == nil, "your own message")
        // A path inside a link keeps the link's address.
        let linked = MarkdownRenderer.render("[`/Users/me/a.md`](https://example.com)", style: style, filePaths: true)
        guard case .text(let l) = try #require(linked.blocks.first) else { Issue.record("not text"); return }
        #expect(attributes(l, of: "a.md")[.chatLink] as? URL == URL(string: "https://example.com"))
    }

    @MainActor @Test func filesOpensOnTheFile() throws {
        let workspace = ChatWorkspace(client: MoreFakeClient(), profile: "otto")
        let note = WorkspacePage.make(path: "/Users/me/research/leak.md", workspace: workspace, media: nil)
        #expect(note.viewControllers.count == 2, "the file on top of its folder")
        #expect(note.viewControllers.first is WorkspacePage)
        #expect(note.viewControllers.last is ArtifactTextViewController, "Markdown reads formatted")
        let log = WorkspacePage.make(path: "/Users/me/research/build.log", workspace: workspace, media: nil)
        #expect(log.viewControllers.last is WorkspaceTextPage)
        // No extension: the folder lists first, then opens the entry; a trailing slash is the folder itself.
        #expect(WorkspacePage.make(path: "/Users/me/project/Makefile", workspace: workspace, media: nil).viewControllers.count == 1)
        #expect(WorkspacePage.make(path: "/Users/me/project/", workspace: workspace, media: nil).viewControllers.count == 1)
    }
}
