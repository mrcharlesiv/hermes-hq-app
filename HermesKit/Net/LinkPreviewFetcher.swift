// [transcript] Link titles and site icons: the phone's own bounded, cookieless https read (docs/spec/3x-transcript.md
// §3.7, rows L312, L313, L1007; the old shell's `linkFetch`, ios/App/App/HermesPlatformExtras.swift:1091-1151).
// Ephemeral session, no cookies, no cache, no credentials, 5 s timeouts, two connections per host; public hosts only
// (`PublicHostPolicy`), every redirect checked again and never down to http, the connected peer's address checked
// public; 256 KiB of a page is read (the rest is dropped), an icon over 64 KiB is refused. Nothing about the gateway,
// the bot or the user is sent, and it never goes through the gateway.

import Foundation

nonisolated struct LinkFetchResult: Sendable {
    /// Where the read ended up after redirects.
    var url: URL
    /// The response's Content-Type.
    var type: String
    var data: Data
}

nonisolated protocol LinkFetching: Sendable {
    func page(_ url: URL) async throws -> LinkFetchResult
    func image(_ url: URL) async throws -> LinkFetchResult
}

nonisolated struct LinkFetchRefused: Error, Sendable { var reason: String }

/// [link-retry] The read failed because the network was not there (not ready at a return, a blip, a timeout): worth
/// asking again later, unlike a refusal.
nonisolated struct LinkFetchTransient: Error, Sendable {
    var code: URLError.Code

    static let codes: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
                                         .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed]

    /// The error as a transient failure, or nil when it is anything else (TLS and certificate errors included).
    static func from(_ error: Error) -> LinkFetchTransient? {
        guard let url = error as? URLError, codes.contains(url.code) else { return nil }
        return LinkFetchTransient(code: url.code)
    }
}

nonisolated final class LinkPreviewFetcher: LinkFetching, @unchecked Sendable {
    static let maxRedirects = 5
    let session: URLSession
    let hosts: PublicHostPolicy.PublicHosts
    /// Off in the unit tests' stubbed sessions (a `URLProtocol` stub has no peer address).
    let checksPeer: Bool

    static func configuration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        c.urlCredentialStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 5
        c.timeoutIntervalForResource = 5
        c.httpMaximumConnectionsPerHost = 2
        c.waitsForConnectivity = false
        return c
    }

    init(session: URLSession = URLSession(configuration: LinkPreviewFetcher.configuration()),
         hosts: PublicHostPolicy.PublicHosts = .shared, checksPeer: Bool = true) {
        self.session = session
        self.hosts = hosts
        self.checksPeer = checksPeer
    }

    func page(_ url: URL) async throws -> LinkFetchResult {
        try await read(url, accept: "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1", limit: LinkPreviewParsing.htmlLimit, truncates: true)
    }

    func image(_ url: URL) async throws -> LinkFetchResult {
        try await read(url, accept: "image/*", limit: LinkPreviewParsing.imageLimit, truncates: false)
    }

    @concurrent
    private func read(_ url: URL, accept: String, limit: Int, truncates: Bool) async throws -> LinkFetchResult {
        guard await PublicHostPolicy.allowed(url, hosts: hosts) else { throw LinkFetchRefused(reason: "not a public https host") }
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        let hosts = self.hosts
        let load = LinkLoad(limit: limit, truncates: truncates, checksPeer: checksPeer) { hop, next in
            guard hop <= LinkPreviewFetcher.maxRedirects, next?.scheme?.lowercased() == "https" else { return false }
            return await PublicHostPolicy.allowed(next, hosts: hosts)
        }
        let session = self.session
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in load.start(request, on: session, continuation) }
        } onCancel: {
            load.cancel()
        }
    }

    /// An address as text ("93.184.216.34", "2606:2800::1") to its bytes; nil when it is not one.
    static func addressBytes(_ text: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 { return withUnsafeBytes(of: v4) { Array($0) } }
        var v6 = in6_addr()
        let bare = text.split(separator: "%").first.map(String.init) ?? text
        if inet_pton(AF_INET6, bare, &v6) == 1 { return withUnsafeBytes(of: v6) { Array($0) } }
        return nil
    }
}

/// One read's task delegate: the redirect guard, the byte limit and the peer check.
nonisolated final class LinkLoad: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Admit = @Sendable (_ hop: Int, _ url: URL?) async -> Bool
    private let lock = NSLock()
    private let limit: Int
    private let truncates: Bool
    private let checksPeer: Bool
    private let admit: Admit
    private var body = Data()
    private var hops = 0
    private var failure: Error?
    private var truncated = false
    private var type = ""
    private var finalURL: URL?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<LinkFetchResult, Error>?
    private var cancelled = false

    init(limit: Int, truncates: Bool, checksPeer: Bool, admit: @escaping Admit) {
        self.limit = limit; self.truncates = truncates; self.checksPeer = checksPeer; self.admit = admit
    }

    func start(_ request: URLRequest, on session: URLSession, _ continuation: CheckedContinuation<LinkFetchResult, Error>) {
        let task = session.dataTask(with: request)
        task.delegate = self
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        self.task = task
        self.finalURL = request.url
        lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock(); cancelled = true; let task = self.task; lock.unlock()
        task?.cancel()
    }

    private func fail(_ error: Error, _ task: URLSessionTask) {
        lock.lock(); if failure == nil { failure = error }; body = Data(); lock.unlock()
        task.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            fail(LinkFetchRefused(reason: "status \((response as? HTTPURLResponse)?.statusCode ?? 0)"), dataTask)
            return completionHandler(.cancel)
        }
        if !truncates, http.expectedContentLength > Int64(limit) {
            fail(LinkFetchRefused(reason: "too large"), dataTask)
            return completionHandler(.cancel)
        }
        lock.lock()
        type = http.value(forHTTPHeaderField: "Content-Type") ?? http.mimeType ?? ""
        finalURL = http.url ?? finalURL
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        body.append(data)
        var stop = false, refuse = false
        if body.count > limit {
            if truncates { body = body.prefix(limit); truncated = true; stop = true } else { refuse = true }
        } else if body.count == limit && truncates {
            truncated = true; stop = true
        }
        lock.unlock()
        if refuse { fail(LinkFetchRefused(reason: "too large"), dataTask) }
        else if stop { dataTask.cancel() }     // what arrived is parsed
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.lock(); hops += 1; let hop = hops; lock.unlock()
        let admit = self.admit
        Task {
            if await admit(hop, request.url) {
                var next = request
                next.httpShouldHandleCookies = false
                next.setValue(nil, forHTTPHeaderField: "Cookie")
                next.setValue(nil, forHTTPHeaderField: "Authorization")
                completionHandler(next)
            } else {
                self.fail(LinkFetchRefused(reason: "redirect refused"), task)
                completionHandler(nil)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard checksPeer else { return }
        for transaction in metrics.transactionMetrics {
            guard let address = transaction.remoteAddress else { continue }
            guard let bytes = LinkPreviewFetcher.addressBytes(address), PublicHostPolicy.publicAddress(bytes) else {
                lock.lock(); if failure == nil { failure = LinkFetchRefused(reason: "peer is not public") }; body = Data(); lock.unlock()
                return
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let failure = self.failure, cancelled = self.cancelled, body = self.body, truncated = self.truncated
        let type = self.type, finalURL = self.finalURL
        self.body = Data()
        lock.unlock()
        guard let continuation else { return }
        if cancelled { return continuation.resume(throwing: CancellationError()) }
        if let failure { return continuation.resume(throwing: failure) }
        if let error, !truncated {
            if let transient = LinkFetchTransient.from(error) { return continuation.resume(throwing: transient) }
            return continuation.resume(throwing: LinkFetchRefused(reason: error.localizedDescription))
        }
        guard let http = task.response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let finalURL else {
            return continuation.resume(throwing: LinkFetchRefused(reason: "status \((task.response as? HTTPURLResponse)?.statusCode ?? 0)"))
        }
        continuation.resume(returning: LinkFetchResult(url: finalURL, type: type, data: body))
    }
}

/// What a link shows once its page was read.
nonisolated struct LinkPreview: Equatable, Sendable {
    /// "" when the page gave no usable title.
    var title: String
    /// The site's icon bytes (PNG, JPEG, GIF, WebP or ICO); nil = the globe.
    var icon: Data?
}

/// Titles and icons for the links on screen: one read per URL per app run (a refusal is remembered; a network failure
/// only for `retryAfter`), at most three page reads in flight, 64 pages and 128 host icons kept in memory, nothing on
/// disk.
actor LinkPreviews {
    static let shared = LinkPreviews(fetcher: LinkPreviewFetcher())
    static let maxPages = 64
    static let maxIcons = 128
    static let maxIconBytes = 1_500_000
    static let maxInFlight = 3
    static let maxCooling = 128

    /// What one read came to.
    private enum Outcome: Sendable {
        case ok(LinkPreview)
        case refused
        /// [link-retry] The network was not there: asked again once `retryAfter` has passed.
        case transient

        var preview: LinkPreview? { if case .ok(let preview) = self { preview } else { nil } }
    }

    private let fetcher: LinkFetching
    private let retryAfter: Duration
    private var pages: [String: LinkPreview] = [:]
    private var pageOrder: [String] = []
    private var failed: Set<String> = []
    /// [link-retry] URLs whose read failed for want of a network, and when they may be asked again.
    private var cooling: [String: ContinuousClock.Instant] = [:]
    private var flights: [String: Task<Outcome, Never>] = [:]
    private var icons: [String: Data?] = [:]
    private var iconOrder: [String] = []
    private var iconBytes = 0
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Every URL a read was started for (the tests count them).
    private(set) var started: [String] = []
    /// DEBUG: answers by URL instead of the network (`-HQNLinkPreviewStub`).
    private var stub: [String: LinkPreview?]?

    init(fetcher: LinkFetching, retryAfter: Duration = .seconds(60)) {
        self.fetcher = fetcher
        self.retryAfter = retryAfter
    }

    func setStub(_ entries: [String: LinkPreview?]) { stub = entries }

    /// What is already known, without starting a read.
    func known(_ url: String) -> LinkPreview? { pages[url] }

    /// Whether a read for this URL is over (answered or failed) or was never needed.
    /// A read that failed for want of a network counts as over too (until it is asked again).
    func settled(_ url: String) -> Bool { pages[url] != nil || failed.contains(url) || cooling[url] != nil }

    /// The link's title and icon; nil when the read was refused (remembered for the run) or the network was not there
    /// (asked again on the next call after `retryAfter`).
    func preview(for raw: String) async -> LinkPreview? {
        if let hit = pages[raw] { touch(raw); return hit }
        if failed.contains(raw) { return nil }
        if let flight = flights[raw] { return await flight.value.preview }
        if let until = cooling[raw] {
            if ContinuousClock.now < until { return nil }
            cooling[raw] = nil
        }
        guard let url = URL(string: raw), stub != nil || PublicHostPolicy.publicHTTPS(url) else { failed.insert(raw); return nil }
        started.append(raw)
        let task = Task<Outcome, Never> { await self.load(raw, url) }
        flights[raw] = task
        let outcome = await task.value
        flights[raw] = nil
        switch outcome {
        case .ok(let result): store(raw, result)
        case .refused: failed.insert(raw)
        case .transient: cool(raw)
        }
        return outcome.preview
    }

    private func cool(_ key: String) {
        cooling[key] = ContinuousClock.now + retryAfter
        while cooling.count > Self.maxCooling, let soonest = cooling.min(by: { $0.value < $1.value })?.key {
            cooling[soonest] = nil
        }
    }

    private func touch(_ key: String) {
        guard pageOrder.last != key else { return }
        pageOrder.removeAll { $0 == key }
        pageOrder.append(key)
    }

    private func store(_ key: String, _ value: LinkPreview) {
        if pages[key] == nil { pageOrder.append(key) }
        pages[key] = value
        while pageOrder.count > Self.maxPages { pages[pageOrder.removeFirst()] = nil }
    }

    private func enter() async {
        if active >= Self.maxInFlight { await withCheckedContinuation { waiters.append($0) } }
        active += 1
    }

    private func leave() {
        active -= 1
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    private func load(_ raw: String, _ url: URL) async -> Outcome {
        if let stub {
            guard let entry = stub[raw], let entry else { return .refused }
            return .ok(entry)
        }
        await enter()
        defer { leave() }
        let result: LinkFetchResult
        do { result = try await fetcher.page(url) } catch { return error is LinkFetchTransient ? .transient : .refused }
        let lower = result.type.lowercased()
        var title = ""
        var candidates = LinkPreviewParsing.iconCandidates("", pageURL: result.url.absoluteString)
        if lower.contains("html") || lower.contains("xml") {
            let html = LinkPreviewParsing.decode(result.data, contentType: result.type)
            title = LinkPreviewParsing.isSignInArrival(result.url) ? "" : LinkPreviewParsing.titleFromHTML(html)
            candidates = LinkPreviewParsing.iconCandidates(html, pageURL: result.url.absoluteString)
        }
        let (icon, iconTransient) = await icon(host: result.url.host ?? url.host ?? "", candidates: candidates)
        if title.isEmpty && icon == nil { return iconTransient ? .transient : .refused }
        return .ok(LinkPreview(title: title, icon: icon))
    }

    /// The host's icon, and whether a read for it failed for want of a network (then a miss is not remembered).
    private func icon(host: String, candidates: [String]) async -> (Data?, transient: Bool) {
        let key = host.lowercased()
        if let known = icons[key] { return (known, false) }
        var found: Data?
        var transient = false
        for candidate in candidates {
            guard let url = URL(string: candidate), PublicHostPolicy.publicHTTPS(url) else { continue }
            let result: LinkFetchResult
            do { result = try await fetcher.image(url) } catch {
                if error is LinkFetchTransient { transient = true }
                continue
            }
            let mime = LinkPreviewParsing.imageMime(result.data, declared: result.type)
            // No SVG rasteriser in the app: a scalable icon is skipped for the next candidate.
            guard !mime.isEmpty, mime != "image/svg+xml" else { continue }
            found = result.data
            break
        }
        if found == nil, transient { return (nil, true) }
        icons[key] = found
        iconOrder.append(key)
        iconBytes += found?.count ?? 0
        while iconOrder.count > Self.maxIcons || iconBytes > Self.maxIconBytes, iconOrder.count > 1 {
            let gone = iconOrder.removeFirst()
            if let data = icons.removeValue(forKey: gone) { iconBytes -= data?.count ?? 0 }
        }
        return (found, false)
    }
}
