// Images at https URLs in replies and generated-image results (docs/spec/1x-attachments.md §8.4, A15;
// R:ios/App/App/HermesPicker.swift:238-322): fetched on their own ephemeral session with no cookies, no credentials and
// no cache, only from hosts that resolve to public internet addresses — checked before the request and on every
// redirect (at most 5) — so a reply (which a prompt injection can write) can't make the phone reach LAN or Tailscale
// machines. URLSession resolves the name again for the connection, so a host that answers public first and private
// next (DNS rebinding) is caught afterwards: the address each request actually reached (task metrics) must be public
// too, else the answer is thrown away. The answer must be `image/*` (never SVG), ≤ 32 MB and ≤ 100 megapixels. The
// gateway's cookies and bearer never go to these hosts.

import Foundation
import Darwin
import Synchronization

nonisolated enum RemoteImagePolicy {
    static let maxBytes: Int64 = 32 << 20
    static let maxPixels = 100_000_000
    static let maxRedirects = 5

    /// The URL itself may be fetched (scheme, host name and literal checks; DNS comes after).
    static func isAllowedURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return false }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bare == "localhost" || bare.hasSuffix(".localhost") || bare.hasSuffix(".local") || bare.hasSuffix(".ts.net")
            || bare.hasSuffix(".internal") || bare.hasSuffix(".lan") || bare.hasSuffix(".home.arpa") { return false }
        if isIPLiteral(bare) { return isPublicAddress(bare) }
        return bare.contains(".")
    }

    static func isIPLiteral(_ text: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
    }

    /// Public unicast only: no loopback, RFC 1918, link-local, CGNAT 100.64/10 (Tailscale), multicast, ULA fc00::/7
    /// (Tailscale's fd7a:115c:a1e0::/48 included), ::1, unspecified, or IPv4-mapped forms of those.
    static func isPublicAddress(_ text: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            let b = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            return isPublicV4(b)
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0) }
            if b.allSatisfy({ $0 == 0 }) { return false }                                   // ::
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return false }             // ::1
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF { return isPublicV4(Array(b[12..<16])) }
            if b[0] & 0xFE == 0xFC { return false }                                          // fc00::/7
            if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return false }                          // fe80::/10
            if b[0] == 0xFF { return false }                                                 // multicast
            if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0D && b[3] == 0xB8 { return false } // documentation
            return true
        }
        return false
    }

    private static func isPublicV4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        switch (b[0], b[1]) {
        case (0, _), (10, _), (127, _): return false
        case (100, 64...127): return false          // CGNAT, Tailscale
        case (169, 254): return false
        case (172, 16...31): return false
        case (192, 168): return false
        case (192, 0) where b[2] == 0 || b[2] == 2: return false
        case (198, 18...19): return false
        case (198, 51) where b[2] == 100: return false
        case (203, 0) where b[2] == 113: return false
        default: return b[0] < 224                    // multicast and reserved above
        }
    }

    /// Every address `host` resolves to (blocking; call off the main thread).
    static func resolve(_ host: String) -> [String] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0,
                             ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var out: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                out.append(String(decoding: bytes, as: UTF8.self))
            }
            cursor = info.pointee.ai_next
        }
        return out
    }

    /// The URL may be fetched now: allowed, and its host resolves only to public addresses.
    static func admits(_ url: URL, resolver: (String) -> [String] = resolve) -> Bool {
        guard isAllowedURL(url), let host = url.host(percentEncoded: false) else { return false }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if isIPLiteral(bare) { return isPublicAddress(bare) }
        return allPublic(resolver(bare))
    }

    /// A resolved host is public only when it has addresses and every one is (IPv6 zone stripped).
    private static func allPublic(_ addresses: [String]) -> Bool {
        !addresses.isEmpty && addresses.allSatisfy { isPublicAddress($0.split(separator: "%").first.map(String.init) ?? $0) }
    }

    /// `admits` without holding a thread it shouldn't: the cheap checks first, then the lookup on a GCD thread
    /// ([perf] getaddrinfo blocks and can't be cancelled; on the cooperative pool slow DNS starved all async work).
    /// `done` gets the answer once, or nil when the lookup outlasts `timeout` (a slow network, not a refusal).
    static func check(_ url: URL, timeout: Duration = .seconds(10), resolver: @escaping @Sendable (String) -> [String] = resolve,
                      done: @escaping @Sendable (Bool?) -> Void) {
        guard isAllowedURL(url), let host = url.host(percentEncoded: false) else { return done(false) }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if isIPLiteral(bare) { return done(isPublicAddress(bare)) }
        let once = Once()
        DispatchQueue.global(qos: .utility).async {
            let ok = allPublic(resolver(bare))
            if once.take() { done(ok) }
        }
        let (seconds, atto) = timeout.components
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Double(seconds) + Double(atto) / 1e18) {
            if once.take() { done(nil) }
        }
    }

    /// `check` awaited: true, false, or nil when the lookup timed out.
    static func admission(_ url: URL, timeout: Duration = .seconds(10),
                          resolver: @escaping @Sendable (String) -> [String] = resolve) async -> Bool? {
        await withCheckedContinuation { continuation in
            check(url, timeout: timeout, resolver: resolver) { continuation.resume(returning: $0) }
        }
    }

    /// `admits` off the cooperative pool; a timed-out lookup counts as refused.
    static func admitsAsync(_ url: URL, timeout: Duration = .seconds(10),
                            resolver: @escaping @Sendable (String) -> [String] = resolve) async -> Bool {
        await admission(url, timeout: timeout, resolver: resolver) == true
    }

    /// The lookup and its timeout race; whichever comes first answers.
    private final class Once: Sendable {
        private let taken = Mutex(false)
        func take() -> Bool { taken.withLock { was in defer { was = true }; return !was } }
    }
}

nonisolated enum RemoteImageError: Error, Equatable { case refused, notImage, tooLarge, failed }

nonisolated final class RemoteImageFetcher: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = RemoteImageFetcher()

    private static func makeSession(delegate: URLSessionDelegate) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 4
        config.httpAdditionalHeaders = ["Accept": "image/*"]
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// The session holds its delegate strongly; the shared fetcher lives for the whole run.
    private let sessionBox = Mutex<URLSession?>(nil)
    private var session: URLSession {
        sessionBox.withLock { box in
            if let made = box { return made }
            let made = Self.makeSession(delegate: self)
            box = made
            return made
        }
    }

    private final class Job: @unchecked Sendable {
        let target: URL
        var redirects = 0
        var tooLarge = false
        var notImage = false
        var refused = false
        /// A redirect's host lookup timed out: a failure that retries, not a refusal.
        var timedOut = false
        var moved = false
        var continuation: CheckedContinuation<URL, Error>?
        /// The task's metrics arrived (the addresses it connected to were checked).
        var metricsSeen = false
        /// The task finished (`didCompleteWithError`): its error, settled once the metrics are in too.
        var completed = false
        var error: (any Error)?
        init(target: URL) { self.target = target }
    }

    private let lock = NSLock()
    private var jobs: [ObjectIdentifier: Job] = [:]

    /// Downloads the image at `url` to `file`. Throws `RemoteImageError`.
    func fetch(_ url: URL, to file: URL) async throws -> URL {
        let admitted = await RemoteImagePolicy.admission(url)
        try Task.checkCancellation()
        guard let admitted else { throw RemoteImageError.failed }      // DNS too slow: unreachable (retries), not forbidden
        guard admitted else { throw RemoteImageError.refused }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        let task = session.downloadTask(with: request)
        let job = Job(target: file)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                job.continuation = continuation
                lock.lock(); jobs[ObjectIdentifier(task)] = job; lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func job(_ task: URLSessionTask) -> Job? {
        lock.lock(); defer { lock.unlock() }
        return jobs[ObjectIdentifier(task)]
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let job = job(task), let next = request.url else { return completionHandler(nil) }
        job.redirects += 1
        if job.redirects > RemoteImagePolicy.maxRedirects {
            job.refused = true
            completionHandler(nil)
            task.cancel()
            return
        }
        // [perf] Checked on a GCD thread: a slow lookup here would hold the session's serial delegate queue (every image's callbacks).
        RemoteImagePolicy.check(next) { admitted in
            guard admitted == true else {
                if admitted == nil { job.timedOut = true } else { job.refused = true }
                completionHandler(nil)
                task.cancel()
                return
            }
            var clean = request
            clean.httpShouldHandleCookies = false
            clean.setValue(nil, forHTTPHeaderField: "Authorization")
            completionHandler(clean)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let job = job(downloadTask) else { return }
        if let type = (downloadTask.response as? HTTPURLResponse)?.mimeType?.lowercased(),
           !type.hasPrefix("image/") || type.contains("svg") {
            job.notImage = true
            downloadTask.cancel()
            return
        }
        if totalBytesWritten > RemoteImagePolicy.maxBytes || totalBytesExpectedToWrite > RemoteImagePolicy.maxBytes {
            job.tooLarge = true
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let job = job(downloadTask) else { return }
        let response = downloadTask.response as? HTTPURLResponse
        guard let response, (200..<300).contains(response.statusCode) else { return }
        let type = response.mimeType?.lowercased() ?? ""
        guard type.hasPrefix("image/"), !type.contains("svg") else { job.notImage = true; return }
        try? FileManager.default.createDirectory(at: job.target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: job.target)
        job.moved = (try? FileManager.default.moveItem(at: location, to: job.target)) != nil
    }

    /// The addresses the task really connected to: any that isn't public refuses the answer (DNS rebinding).
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let reached = metrics.transactionMetrics.compactMap(\.remoteAddress)
        let privateHit = reached.contains { address in
            !RemoteImagePolicy.isPublicAddress(address.split(separator: "%").first.map(String.init) ?? address)
        }
        lock.lock()
        if let job = jobs[ObjectIdentifier(task)] {
            if privateHit { job.refused = true }
            job.metricsSeen = true
        }
        lock.unlock()
        settle(task)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        if let job = jobs[ObjectIdentifier(task)] {
            job.completed = true
            job.error = error
        }
        lock.unlock()
        settle(task)
        // Metrics normally come first; should they never come, settle on what is known.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self] in self?.settle(task, force: true) }
    }

    /// Resumes the caller once the task finished and its addresses were checked (or `force`: they never came).
    private func settle(_ task: URLSessionTask, force: Bool = false) {
        lock.lock()
        guard let job = jobs[ObjectIdentifier(task)], job.completed, job.metricsSeen || force else { lock.unlock(); return }
        jobs.removeValue(forKey: ObjectIdentifier(task))
        let continuation = job.continuation
        job.continuation = nil
        let error = job.error
        lock.unlock()
        guard let continuation else { return }
        if job.refused {
            try? FileManager.default.removeItem(at: job.target)
            return continuation.resume(throwing: RemoteImageError.refused)
        }
        if job.notImage { return continuation.resume(throwing: RemoteImageError.notImage) }
        if job.tooLarge { return continuation.resume(throwing: RemoteImageError.tooLarge) }
        if job.timedOut { return continuation.resume(throwing: RemoteImageError.failed) }
        if let error {
            if (error as? URLError)?.code == .cancelled { return continuation.resume(throwing: CancellationError()) }
            return continuation.resume(throwing: RemoteImageError.failed)
        }
        guard job.moved else { return continuation.resume(throwing: RemoteImageError.failed) }
        // ≤ 100 megapixels before anything decodes it.
        if let (w, h) = PhotoNormalizer.pixelSize(of: job.target), w * h > RemoteImagePolicy.maxPixels {
            try? FileManager.default.removeItem(at: job.target)
            return continuation.resume(throwing: RemoteImageError.tooLarge)
        }
        continuation.resume(returning: job.target)
    }
}
