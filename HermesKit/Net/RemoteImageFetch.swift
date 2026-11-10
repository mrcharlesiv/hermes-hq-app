// A hosted image named in a transcript (an Artifacts tile or the viewer), fetched the way the reference app's
// `RemoteImage` does (ios/App/App/HermesPicker.swift, r1-10): https only, public hosts only (`PublicHostPolicy`), on an
// ephemeral session that keeps nothing (no cache, cookies or credentials) and asks for images; at most five redirects,
// each to a public https host, refused before its request goes out; the body read as it arrives and dropped past
// 16 MiB. Anything else is "hosted elsewhere": the tile offers Open instead.

import Foundation

nonisolated enum RemoteImageFetch {
    static let ceiling = 16 << 20
    static let maxRedirects = 5

    /// Not fetched here (http, a private or unknown host, a refused redirect, not an image, too large, unreachable).
    struct Refused: Error, LocalizedError, Sendable {
        var reason: String
        var errorDescription: String? { "This image is on another site and couldn’t be shown here. \(DeviceWord.Tap) Open to view it." }
    }

    /// One pool for every hosted image: connections reused, nothing stored.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    /// The image's bytes, or `Refused`.
    @concurrent
    static func fetch(_ raw: String, hosts: PublicHostPolicy.PublicHosts = .shared, session: URLSession = session,
                      ceiling: Int = ceiling) async throws -> Data {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https" else { throw Refused(reason: "not https") }
        guard await PublicHostPolicy.allowed(url, hosts: hosts) else { throw Refused(reason: "not a public host") }
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        let load = RemoteImageLoad(ceiling: ceiling) { hop, next in await admitRedirect(hops: hop, to: next, hosts: hosts) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in load.start(request, on: session, continuation) }
        } onCancel: {
            load.cancel()
        }
    }

    /// A redirect hop (`hops` counted from 1) is followed only within five hops and to a public https host.
    static func admitRedirect(hops: Int, to url: URL?, hosts: PublicHostPolicy.PublicHosts = .shared) async -> Bool {
        guard hops <= maxRedirects, url?.scheme?.lowercased() == "https" else { return false }
        return await PublicHostPolicy.allowed(url, hosts: hosts)
    }
}

/// One fetch's task delegate: the redirect guard and the byte ceiling.
nonisolated final class RemoteImageLoad: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Whether redirect hop `n` (from 1) to `url` may be followed.
    typealias Admit = @Sendable (_ hop: Int, _ url: URL?) async -> Bool
    private let lock = NSLock()
    private let ceiling: Int
    private let admit: Admit
    private var body = Data()
    private var hops = 0
    private var failure: Error?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Data, Error>?
    private var cancelled = false

    init(ceiling: Int, admit: @escaping Admit) {
        self.ceiling = ceiling
        self.admit = admit
    }

    func start(_ request: URLRequest, on session: URLSession, _ continuation: CheckedContinuation<Data, Error>) {
        let task = session.dataTask(with: request)
        task.delegate = self
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        self.task = task
        lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    private func fail(_ error: Error, _ task: URLSessionTask) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
        task.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            fail(RemoteImageFetch.Refused(reason: "status \((response as? HTTPURLResponse)?.statusCode ?? 0)"), dataTask)
            return completionHandler(.cancel)
        }
        guard (http.mimeType ?? "").lowercased().hasPrefix("image/") else {
            fail(RemoteImageFetch.Refused(reason: "not an image"), dataTask)
            return completionHandler(.cancel)
        }
        if http.expectedContentLength > Int64(ceiling) {
            fail(RemoteImageFetch.Refused(reason: "too large"), dataTask)
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        body.append(data)
        let over = body.count > ceiling
        if over { body = Data() }
        lock.unlock()
        if over { fail(RemoteImageFetch.Refused(reason: "too large"), dataTask) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.lock()
        hops += 1
        let hop = hops
        lock.unlock()
        let admit = self.admit
        Task {
            if await admit(hop, request.url) {
                completionHandler(request)
            } else {
                self.fail(RemoteImageFetch.Refused(reason: "redirect refused"), task)
                completionHandler(nil)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let failure = self.failure, cancelled = self.cancelled, body = self.body
        self.body = Data()
        lock.unlock()
        guard let continuation else { return }
        if cancelled { return continuation.resume(throwing: CancellationError()) }
        if let failure { return continuation.resume(throwing: failure) }
        if let error { return continuation.resume(throwing: RemoteImageFetch.Refused(reason: error.localizedDescription)) }
        // A refused redirect ends the task with the 3xx response and no error.
        guard let http = task.response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return continuation.resume(throwing: RemoteImageFetch.Refused(reason: "status \((task.response as? HTTPURLResponse)?.statusCode ?? 0)"))
        }
        continuation.resume(returning: body)
    }
}
