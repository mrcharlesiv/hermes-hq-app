// One account's URLSessions (spec 01 §8.2, §19.1): ephemeral, no cache, its own cookie jar (never the shared
// storage), redirects never followed, a byte ceiling on every body, and two pools over one jar: control (sign-in,
// session checks, renewals, tickets; waits for a network path up to 15 s) and bulk (everything else; fails fast).

import Foundation
import Synchronization

nonisolated final class HTTPTransport: Sendable {
    let bulk: URLSession
    let control: URLSession
    /// The account's own cookie jar (the ephemeral configuration's private store), shared by both pools.
    let jar: HTTPCookieStorage?
    private let delegate: TransportDelegate
    private let invalidated = Mutex(false)

    /// `cookies: false` makes a cookieless client (probe, Nous token exchange, Nous accounts).
    /// [cf-access] `headers`: sent on every request of both pools, sockets and transfers included (the gateway's
    /// Cloudflare Access token, `StoredAccount.accessHeaders`). These sessions only ever talk to the gateway's own
    /// address and never follow a redirect, so the headers go nowhere else.
    init(cookies: Bool = true, headers: [String: String] = [:]) {
        let config = URLSessionConfiguration.ephemeral
        if !headers.isEmpty { config.httpAdditionalHeaders = headers }
        config.timeoutIntervalForRequest = 30
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        if cookies {
            config.httpCookieAcceptPolicy = .always
            config.httpShouldSetCookies = true
        } else {
            config.httpCookieAcceptPolicy = .never
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil
        }
        let controlConfig = config.copy() as! URLSessionConfiguration
        controlConfig.waitsForConnectivity = true
        controlConfig.timeoutIntervalForResource = 15
        controlConfig.httpCookieStorage = config.httpCookieStorage
        let delegate = TransportDelegate()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "ai.hermes.hqnative.http"
        self.delegate = delegate
        self.jar = config.httpCookieStorage
        self.bulk = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        self.control = URLSession(configuration: controlConfig, delegate: delegate, delegateQueue: queue)
    }

    enum Pool: Sendable { case bulk, control }

    /// Sends one request; the whole body is returned once complete. Never follows a redirect (a 3xx is the answer).
    /// Throws `GatewayFailure.responseTooLarge` past `ceiling` (error statuses: past 1 MiB), URLError otherwise.
    func data(for request: URLRequest, pool: Pool, ceiling: Int) async throws -> (Data, HTTPURLResponse) {
        guard AppLog.detailed else { return try await send(request, pool: pool, ceiling: ceiling) }
        // [diagnostics] Detailed Logging: every request's route, answer, size and time; a failure's own words.
        let began = ContinuousClock.now
        let route = "\(request.httpMethod ?? "GET") \(AppLog.path(request.url))\(pool == .control ? " (control)" : "")"
        do {
            let (data, response) = try await send(request, pool: pool, ceiling: ceiling)
            let status = response.statusCode
            var line = "\(route) → \(status), \(data.count) B, \(AppLog.ms(since: began)) ms"
            if status >= 400 {
                line += ": " + AppLog.scrub(String(decoding: data.prefix(300), as: UTF8.self))
            }
            AppLog.trace("http", line)
            return (data, response)
        } catch {
            AppLog.trace("http", "\(route) → failed after \(AppLog.ms(since: began)) ms: \(AppLog.scrub(String(describing: error)))")
            throw error
        }
    }

    private func send(_ request: URLRequest, pool: Pool, ceiling: Int) async throws -> (Data, HTTPURLResponse) {
        let session = pool == .control ? control : bulk
        let made: URLSessionDataTask? = invalidated.withLock { dead in dead ? nil : session.dataTask(with: request) }
        guard let task = made else { throw GatewayFailure.connectionChanged }
        let collector = TransportDelegate.Collector(ceiling: ceiling)
        let delegate = self.delegate
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
                collector.continuation = continuation
                delegate.register(task, collector)
                // Cancelled before the collector was registered: the cancel handler's `task.cancel()` may already have
                // completed the task with nobody listening, so settle here (whoever takes the collector resumes it).
                if Task.isCancelled, delegate.take(task) != nil {
                    task.cancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// A WebSocket task on the bulk pool (its handshake carries the jar's cookies).
    func webSocketTask(with request: URLRequest) throws(GatewayFailure) -> URLSessionWebSocketTask {
        let bulk = self.bulk
        let task: URLSessionWebSocketTask? = invalidated.withLock { dead in dead ? nil : bulk.webSocketTask(with: request) }
        guard let task else { throw .connectionChanged }
        return task
    }

    /// An upload task on the bulk pool. Made under the same lock as `invalidate`, so a sign-out or a gateway switch
    /// mid-transfer answers "Connection changed" instead of asking an invalidated session for a task (which raises an
    /// Objective-C exception and ends the app).
    func uploadTask(with request: URLRequest, fromFile file: URL) throws(GatewayFailure) -> URLSessionUploadTask {
        let bulk = self.bulk
        let task: URLSessionUploadTask? = invalidated.withLock { dead in dead ? nil : bulk.uploadTask(with: request, fromFile: file) }
        guard let task else { throw .connectionChanged }
        return task
    }

    /// A download task on the bulk pool (guarded like `uploadTask`).
    func downloadTask(with request: URLRequest) throws(GatewayFailure) -> URLSessionDownloadTask {
        let bulk = self.bulk
        let task: URLSessionDownloadTask? = invalidated.withLock { dead in dead ? nil : bulk.downloadTask(with: request) }
        guard let task else { throw .connectionChanged }
        return task
    }

    // MARK: Cookies

    func cookies(for url: URL) -> [SavedCookie] {
        (jar?.cookies(for: url) ?? []).map(SavedCookie.init)
    }

    /// Replaces the jar's contents with saved cookies.
    func installCookies(_ cookies: [SavedCookie]) {
        guard let jar else { return }
        jar.cookies?.forEach(jar.deleteCookie)
        cookies.compactMap(\.cookie).forEach(jar.setCookie)
    }

    func clearCookies() { installCookies([]) }

    // MARK: Lifetime

    var isInvalidated: Bool { invalidated.withLock { $0 } }

    /// [stale-pool] Drops both pools' idle keep-alive connections, so the next request opens a fresh one. The app closes
    /// its socket for the background: a pooled connection the tunnel or NAT dropped silently while the app was away
    /// would otherwise take the first ticket after the return and sit out its 8 s timeout. `flush`, not `reset`: the
    /// cookie jar (the password session) stays, and requests in flight are left alone.
    func flushConnections() {
        guard !isInvalidated else { return }
        bulk.flush {}
        control.flush {}
    }

    /// Requests whose answer is still awaited (tests).
    var requestsInFlight: Int { delegate.inFlight }

    /// Cancels everything and releases the sessions (a URLSession keeps its delegate until invalidated).
    func invalidate() {
        let first = invalidated.withLock { dead -> Bool in
            defer { dead = true }
            return !dead
        }
        guard first else { return }
        bulk.invalidateAndCancel()
        control.invalidateAndCancel()
    }

    /// Lets requests in flight finish (a sign-out's logout), then releases the sessions.
    func finishAndInvalidate() {
        let first = invalidated.withLock { dead -> Bool in
            defer { dead = true }
            return !dead
        }
        guard first else { return }
        bulk.finishTasksAndInvalidate()
        control.finishTasksAndInvalidate()
    }
}

/// The sessions' delegate: refuses redirects and collects each data task's body under its ceiling.
nonisolated final class TransportDelegate: NSObject, URLSessionDataDelegate, Sendable {
    /// Touched only on the sessions' serial delegate queue (and once before `resume`).
    final class Collector: @unchecked Sendable {
        let ceiling: Int
        var data = Data()
        var response: HTTPURLResponse?
        var tooLarge = false
        /// The request went out on a kept-alive connection an earlier request opened, at least once (URLSession may
        /// send it again on a fresh one first): its metrics, nil until they come.
        var reused: Bool?
        var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        init(ceiling: Int) { self.ceiling = ceiling }

        /// Error bodies are capped at 1 MiB whatever the route allows.
        var limit: Int {
            if let status = response?.statusCode, status >= 400 { return min(ceiling, 1 << 20) }
            return ceiling
        }
    }

    /// Keyed by the task object, never by task number: this delegate serves both pools, and each URLSession numbers
    /// its tasks 1, 2, 3… on its own, so a control and a bulk request routinely share a number. An entry leaves the map
    /// when its task completes (or is cancelled before it started), so an address reused by a later task is safe.
    private let collectors = Mutex<[ObjectIdentifier: Collector]>([:])

    func register(_ task: URLSessionTask, _ collector: Collector) {
        collectors.withLock { $0[ObjectIdentifier(task)] = collector }
    }
    /// Removes and returns the task's collector (its taker resumes the continuation).
    func take(_ task: URLSessionTask) -> Collector? {
        collectors.withLock { $0.removeValue(forKey: ObjectIdentifier(task)) }
    }
    private func collector(_ task: URLSessionTask) -> Collector? { collectors.withLock { $0[ObjectIdentifier(task)] } }

    /// Requests still waiting for their task to finish (tests: nothing leaks).
    var inFlight: Int { collectors.withLock { $0.count } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil) // Never send credentials to a redirected host; the 3xx is the answer.
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let collector = collector(dataTask) else { return completionHandler(.allow) }
        collector.response = response as? HTTPURLResponse
        if response.expectedContentLength != NSURLSessionTransferSizeUnknown, response.expectedContentLength > Int64(collector.limit) {
            collector.tooLarge = true
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let collector = collector(dataTask), !collector.tooLarge else { return }
        if collector.data.count + data.count > collector.limit {
            collector.tooLarge = true
            dataTask.cancel()
            return
        }
        collector.data.append(data)
    }

    /// Comes before the task's completion.
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        collector(task)?.reused = metrics.transactionMetrics.contains(where: \.isReusedConnection)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let collector = take(task),
              let continuation = collector.continuation else { return }
        collector.continuation = nil
        if collector.tooLarge { return continuation.resume(throwing: GatewayFailure.responseTooLarge) }
        if let error {
            // [stale-pool] Says whether a lost connection was a pooled one (`URLError.onReusedConnection`).
            if let lost = error as? URLError, lost.code == .networkConnectionLost, collector.reused == true {
                return continuation.resume(throwing: URLError(lost.code, userInfo: lost.userInfo.merging(
                    [URLError.reusedConnectionKey: true]) { $1 }))
            }
            return continuation.resume(throwing: error)
        }
        guard let response = (task.response as? HTTPURLResponse) ?? collector.response else {
            return continuation.resume(throwing: URLError(.badServerResponse))
        }
        continuation.resume(returning: (collector.data, response))
    }
}

extension URLError {
    static let reusedConnectionKey = "HQReusedConnection"

    /// [stale-pool] The request went out on a kept-alive connection an earlier request had opened: a pooled connection
    /// may just have gone stale while the app was away, a fresh one dropped at once is the gateway's (or network's) answer.
    var onReusedConnection: Bool { (userInfo[Self.reusedConnectionKey] as? Bool) == true }
}
