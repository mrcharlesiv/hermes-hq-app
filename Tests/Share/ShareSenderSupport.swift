// [share] A stand-in gateway inside the test process for `ShareSender`: a URLProtocol for its HTTP calls and a stub
// socket for its RPC calls, writing one ledger in the order things happened. No port is opened and nothing leaves
// the process (the hosts end in `.test`).

import Foundation
import Testing
@testable import HermesHQNative

nonisolated final class ShareStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated struct Seen: Sendable {
        let method: String
        let path: String
        let query: String
        let headers: [String: String]
        let body: Data
        let handlesCookies: Bool
        let timeout: Double
    }

    nonisolated struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body = Data("{}".utf8)
        var failure: URLError.Code?
        var redirect: String?

        static func json(_ object: [String: Any], status: Int = 200) -> Reply {
            Reply(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        }
        static func status(_ status: Int, body: String = "{\"detail\":\"no\"}") -> Reply { Reply(status: status, body: Data(body.utf8)) }
        static func fail(_ code: URLError.Code) -> Reply { Reply(failure: code) }
        static func redirect(to location: String) -> Reply { Reply(status: 302, redirect: location) }
    }

    typealias Handler = @Sendable (Seen) -> Reply

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func register(_ authority: String, _ handler: @escaping Handler) { lock.withLock { handlers[authority] = handler } }
    static func remove(_ authority: String) { lock.withLock { handlers[authority] = nil } }
    private static func handler(for request: URLRequest) -> Handler? {
        guard let url = request.url, let host = url.host() else { return nil }
        return lock.withLock { handlers[host + ":" + String(url.port ?? 80)] }
    }

    override class func canInit(with request: URLRequest) -> Bool { handler(for: request) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let handler = Self.handler(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        let seen = Seen(method: request.httpMethod ?? "GET", path: url.path(percentEncoded: false), query: url.query(percentEncoded: true) ?? "",
                        headers: request.allHTTPHeaderFields ?? [:], body: body, handlesCookies: request.httpShouldHandleCookies,
                        timeout: request.timeoutInterval)
        let reply = handler(seen)
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure)); return
        }
        var headers = reply.headers
        // A redirect is answered as the plain 302 it is: a stubbed `wasRedirectedTo` never completes once the sender
        // refuses it. The refusal itself is tested on the sender's delegate and against the real fixture gateway.
        if let redirect = reply.redirect { headers["Location"] = redirect }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// One entry of the stub gateway's ledger.
nonisolated struct ShareStubEvent: Sendable {
    /// "GET /api/auth/me", "POST /api/files/upload-stream", "connect", "client.capabilities", …
    let label: String
    let keys: [String]
    let text: String
    let headers: [String: String]
    let handlesCookies: Bool
    let timeout: Double
    let bodyBytes: Int
}

nonisolated final class ShareStubGateway: @unchecked Sendable {
    typealias HTTPOverride = @Sendable (ShareStubProtocol.Seen) -> ShareStubProtocol.Reply?
    typealias RPCOverride = @Sendable (String, [String: Any]) throws -> [String: Any]?

    let host: String
    let url: String
    private let authority: String
    private let lock = NSLock()
    private var ledger: [ShareStubEvent] = []
    private var http: HTTPOverride = { _ in nil }
    private var rpc: RPCOverride = { _, _ in nil }
    private var before: @Sendable (Int, String) -> Void = { _, _ in }
    private var closes = 0
    private var socketURLs: [URL] = []
    /// [ask-bot] What the socket says after prompt.submit (before its answer when `eventsBeforeAnswer`), to a listener.
    private var submitEvents: [ShareSocketEvent] = []
    private var eventsBeforeAnswer = false
    private var listener: (@Sendable (ShareSocketEvent) -> Void)?

    /// `host`: a name ending `.test`, or a tailnet address for the Tailscale test. Nothing is ever resolved.
    init(host: String = "share-stub-" + UUID().uuidString.prefix(8).lowercased() + ".test", port: Int = 8642) {
        self.host = host
        url = "http://\(host):\(port)"
        authority = host + ":" + String(port)
        ShareStubProtocol.register(authority) { [weak self] seen in self?.answer(seen) ?? .status(500) }
    }

    deinit { ShareStubProtocol.remove(authority) }

    var events: [ShareStubEvent] { lock.withLock { ledger } }
    var labels: [String] { events.map(\.label) }
    var closed: Int { lock.withLock { closes } }
    var sockets: [URL] { lock.withLock { socketURLs } }
    func event(_ label: String) -> ShareStubEvent? { events.first { $0.label == label } }
    func count(_ label: String) -> Int { events.filter { $0.label == label }.count }

    /// A share's calls without the clean-up at its end, and how many folders that clean-up asked to remove (the DELETE
    /// calls that are the very last things in the ledger).
    var endedWith: (steps: [String], removed: Int) {
        let all = labels
        let removed = all.reversed().prefix { $0 == "DELETE /api/files" }.count
        return (Array(all.dropLast(removed)), removed)
    }

    func onHTTP(_ override: @escaping HTTPOverride) { lock.withLock { http = override } }
    /// [ask-bot] Events the socket delivers once the prompt is submitted.
    func afterSubmit(_ events: [ShareSocketEvent], beforeAnswer: Bool = false) {
        lock.withLock { submitEvents = events; eventsBeforeAnswer = beforeAnswer }
    }
    fileprivate func listen(_ handler: @escaping @Sendable (ShareSocketEvent) -> Void) { lock.withLock { listener = handler } }
    fileprivate func submitted(answered: Bool) {
        let (events, early, listener) = lock.withLock { (submitEvents, eventsBeforeAnswer, self.listener) }
        guard let listener, early != answered else { return }
        if early { events.forEach(listener) } else { DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { events.forEach(listener) } }
    }
    func onRPC(_ override: @escaping RPCOverride) { lock.withLock { rpc = override } }
    /// Called with the entry's index and label just after it is written and before it is answered.
    func beforeAnswer(_ work: @escaping @Sendable (Int, String) -> Void) { lock.withLock { before = work } }

    private func record(_ event: ShareStubEvent) {
        let (index, hook) = lock.withLock { () -> (Int, @Sendable (Int, String) -> Void) in
            ledger.append(event); return (ledger.count - 1, before)
        }
        hook(index, event.label)
    }

    private func answer(_ seen: ShareStubProtocol.Seen) -> ShareStubProtocol.Reply {
        let text = String(decoding: seen.body.prefix(2000), as: UTF8.self)
        let keys = ((try? JSONSerialization.jsonObject(with: seen.body)) as? [String: Any])?.keys.sorted() ?? []
        record(ShareStubEvent(label: seen.method + " " + seen.path, keys: keys, text: seen.query + "\n" + text, headers: seen.headers,
                              handlesCookies: seen.handlesCookies, timeout: seen.timeout, bodyBytes: seen.body.count))
        if let reply = lock.withLock({ http })(seen) { return reply }
        switch (seen.method, seen.path) {
        case ("GET", "/api/auth/me"): return .json(["username": "share-fixture"])
        case ("GET", "/api/files"): return .json(["path": "/fixture/uploads", "entries": []])
        case ("POST", "/api/files/upload-stream"):
            // The destination the body names is where the file is stored.
            let marker = "name=\"path\"\r\n\r\n"
            var path = "/fixture/uploads/unknown"
            if let start = text.range(of: marker), let end = text[start.upperBound...].range(of: "\r\n") { path = String(text[start.upperBound..<end.lowerBound]) }
            return .json(["path": path, "size": seen.body.count])
        case ("POST", "/api/auth/ws-ticket"): return .json(["ticket": "ticket-\(count("POST /api/auth/ws-ticket"))"])
        case ("DELETE", "/api/files"): return .json(["ok": true])
        default: return .status(404)
        }
    }

    /// What `ShareSender` is given in place of `ShareSocket.open`.
    var connect: ShareSender.Connect {
        { [self] _, url in
            lock.withLock { socketURLs.append(url) }
            record(ShareStubEvent(label: "connect", keys: [], text: url.absoluteString, headers: [:], handlesCookies: false, timeout: 0, bodyBytes: 0))
            if let refused = try lock.withLock({ rpc })("connect", [:]), refused["refuse"] != nil { throw ShareFailure.transport(NSURLErrorDomain, -1004) }
            return StubSocket(self)
        }
    }

    fileprivate func call(_ method: String, _ params: [String: Any], timeout: Double) throws -> [String: Any] {
        let text = (params["text"] as? String) ?? (params["path"] as? String) ?? (params["session_id"] as? String) ?? ""
        record(ShareStubEvent(label: method, keys: params.keys.sorted(), text: text, headers: [:], handlesCookies: false, timeout: timeout, bodyBytes: 0))
        if let answer = try lock.withLock({ rpc })(method, params) { return answer }
        switch method {
        case "client.capabilities": return ["server_requests": ["approval.request", "clarify.request"], "declines_not_shown": true]
        case "session.resume": return ["session_id": "runtime-1", "resumed": params["session_id"] ?? ""]
        case "image.attach": return ["attached": true, "path": params["path"] ?? ""]
        case "file.attach":
            let name = params["name"] as? String ?? "file"
            return ["attached": true, "uploaded": true, "path": "/fixture-home/attachments/" + name, "ref_text": "@file:/fixture-home/attachments/" + name]
        case "prompt.submit": return ["status": "streaming"]
        default: throw ShareFailure.refused(ShareFailure.rpcCopy(code: -32601, message: "method not found"))
        }
    }

    fileprivate func socketClosed() { lock.withLock { closes += 1 } }

    private nonisolated final class StubSocket: ShareRPC, @unchecked Sendable {
        let gateway: ShareStubGateway
        init(_ gateway: ShareStubGateway) { self.gateway = gateway }
        func call(_ method: String, _ params: [String: Any], timeout: Double) async throws -> [String: Any] {
            if method == "prompt.submit" { gateway.submitted(answered: false) }
            let answer = try gateway.call(method, params, timeout: timeout)
            if method == "prompt.submit" { gateway.submitted(answered: true) }
            return answer
        }
        func notify(_ method: String, _ params: [String: Any]) { _ = try? gateway.call(method, params, timeout: 0) }
        func close() { gateway.socketClosed() }
        func listen(_ handler: @escaping @Sendable (ShareSocketEvent) -> Void) { gateway.listen(handler) }
    }

    // MARK: A share against this gateway

    func keychain(nous: [String: Any]? = nil, username: String = ShareSamples.username) -> MemoryShareKeychain {
        MemoryShareKeychain(json: ShareSamples.item(url: url, username: username, cookies: nous == nil ? ShareSamples.cookies() : nil, nous: nous))
    }

    func roster(username: String = ShareSamples.username) -> ShareRoster { ShareSamples.roster(url: url, username: username) }

    func sender(_ keychain: MemoryShareKeychain, interfaces: @escaping @Sendable () -> [ShareReach.Interface] = { [] },
                progress: @escaping @Sendable (ShareStep) -> Void = { _ in }) -> ShareSender {
        ShareSender(keychain: keychain, interfaces: interfaces, protocols: [ShareStubProtocol.self], connect: connect, progress: progress)
    }
}

/// Holds the task a test wants to cancel from inside the stub gateway.
nonisolated final class ShareTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancel: (@Sendable () -> Void)?
    func hold<T: Sendable>(_ task: Task<T, Error>) { lock.withLock { cancel = { task.cancel() } } }
    func cancelNow() { lock.withLock { cancel }?() }
}

nonisolated final class ShareSteps: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [ShareStep] = []
    func add(_ step: ShareStep) { lock.withLock { seen.append(step) } }
    var all: [ShareStep] { lock.withLock { seen } }
}

/// The failure a share ended with, or nil when it was sent.
func shareFailure(_ work: () async throws -> ShareResult) async -> ShareFailure? {
    do { _ = try await work(); return nil } catch let failure as ShareFailure { return failure } catch { return .refused("unexpected: \(error)") }
}

/// Several shares at the same moment (several share sheets, or a share and the app's own traffic): how each ended, in
/// the order given.
nonisolated func shareOutcomes(_ shares: [(sender: ShareSender, request: ShareRequest, roster: ShareRoster)]) async -> [ShareFailure?] {
    await withTaskGroup(of: (Int, ShareFailure?).self) { group in
        for (index, share) in shares.enumerated() {
            let sender = share.sender, request = share.request, roster = share.roster
            group.addTask {
                do { _ = try await sender.send(request, roster: roster); return (index, nil) }
                catch { return (index, error as? ShareFailure ?? .refused("unexpected: \(error)")) }
            }
        }
        var ended = [ShareFailure?](repeating: nil, count: shares.count)
        for await (index, failure) in group { ended[index] = failure }
        return ended
    }
}
