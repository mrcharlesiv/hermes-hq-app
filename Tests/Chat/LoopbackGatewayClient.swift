// A minimal real-socket GatewayClient for end-to-end tests against the loopback stand-in gateways (spec 05 Part A).
// Test-only: password sign-in once (never in a loop), cookie on REST and on the /api/ws upgrade, JSON-RPC over
// URLSessionWebSocketTask. The production client is the Net module's job.

import Foundation
import Synchronization
@testable import HermesHQNative

nonisolated final class LoopbackGatewayClient: GatewayClient, Sendable {
    struct Failure: Error, CustomStringConvertible { var description: String }

    private struct State: Sendable {
        var cookie = ""
        var socket: URLSessionWebSocketTask?
        var socketGeneration = 0
        var nextId = 1
        var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
        var events: [UUID: AsyncStream<GatewayEvent>.Continuation] = [:]
        var states: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]
        var connection: ConnectionState = .connecting
        var ready: JSONValue?
        var framesIn = 0
    }

    let account: GatewayAccount
    let base: URL
    private let session = URLSession(configuration: .ephemeral)
    private let state = Mutex(State())

    init(base: URL) {
        self.base = base
        account = GatewayAccount(id: "\(base.absoluteString)|loopback", baseURL: base, kind: .password, username: "loopback",
                                 label: base.host() ?? "loopback")
    }

    var framesIn: Int { state.withLock { $0.framesIn } }

    // MARK: Sign-in and socket

    func signIn(username: String, password: String) async throws {
        var request = URLRequest(url: base.appending(path: "/auth/password-login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(ChatJSON.stringify(["provider": "basic", "username": .string(username), "password": .string(password)]).utf8)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw Failure(description: "sign-in refused") }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: http.allHeaderFields as? [String: String] ?? [:], for: base)
        state.withLock { $0.cookie = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ") }
    }

    /// Opens /api/ws (ticket + cookie) and waits for `gateway.ready`.
    func connect() async throws {
        setConnection(.connecting)
        let ticketData = try await rest("POST", "/api/auth/ws-ticket", query: [], body: Data("{}".utf8))
        let ticket = (try? ChatJSON.parse(ticketData))?["ticket"]?.string ?? ""
        var components = URLComponents(url: base.appending(path: "/api/ws"), resolvingAgainstBaseURL: false)!
        components.scheme = base.scheme == "https" ? "wss" : "ws"
        components.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
        var request = URLRequest(url: components.url!)
        request.setValue(state.withLock { $0.cookie }, forHTTPHeaderField: "Cookie")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 32 * 1024 * 1024
        let generation = state.withLock { s -> Int in s.socket = task; s.socketGeneration += 1; return s.socketGeneration }
        task.resume()
        Task.detached { [weak self] in await self?.receiveLoop(task, generation: generation) }
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if state.withLock({ $0.connection == .ready && $0.socketGeneration == generation }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure(description: "no gateway.ready")
    }

    /// Drops the socket like a network cut (no close frame) and dials again.
    func reconnect() async throws {
        let old = state.withLock { s -> URLSessionWebSocketTask? in let t = s.socket; s.socket = nil; return t }
        old?.cancel(with: .abnormalClosure, reason: nil)
        failPending(Failure(description: "socket dropped"))
        setConnection(.reconnecting(attempt: 1))
        try await Task.sleep(for: .milliseconds(100))
        try await connect()
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask, generation: Int) async {
        while true {
            let message: URLSessionWebSocketTask.Message
            do { message = try await task.receive() } catch {
                if state.withLock({ $0.socketGeneration == generation }) {
                    failPending(error)
                    setConnection(.reconnecting(attempt: 1))
                }
                return
            }
            guard state.withLock({ $0.socketGeneration == generation }) else { return }
            let data: Data
            switch message {
            case .string(let s): data = Data(s.utf8)
            case .data(let d): data = d
            @unknown default: continue
            }
            guard let frame = try? ChatJSON.parse(data) else { continue }
            state.withLock { $0.framesIn += 1 }
            handle(frame)
        }
    }

    private func handle(_ frame: JSONValue) {
        if frame["method"]?.string == "event", let params = frame["params"], let type = params["type"]?.string {
            let event = GatewayEvent(type: type, sessionId: params["session_id"]?.string ?? "", seq: params["seq"]?.int,
                                     payload: params["payload"] ?? .null)
            if type == "gateway.ready" {
                state.withLock { $0.ready = event.payload }
                setConnection(.ready)
            }
            let continuations = state.withLock { Array($0.events.values) }
            for c in continuations { c.yield(event) }
            return
        }
        guard let id = frame["id"]?.int, frame["method"] == nil else { return }   // server→client requests: never answered (01 §11.6.1)
        guard let continuation = state.withLock({ $0.pending.removeValue(forKey: id) }) else { return }
        if let error = frame["error"] {
            continuation.resume(throwing: RPCError(code: error["code"]?.int ?? -32603, message: error["message"]?.string ?? "Hermes RPC failed",
                                                   data: error["data"]))
        } else {
            continuation.resume(returning: frame["result"] ?? .null)
        }
    }

    private func failPending(_ error: any Error) {
        let pending = state.withLock { s -> [CheckedContinuation<JSONValue, any Error>] in
            let all = Array(s.pending.values); s.pending = [:]; return all
        }
        pending.forEach { $0.resume(throwing: error) }
    }

    private func setConnection(_ c: ConnectionState) {
        let continuations = state.withLock { s -> [AsyncStream<ConnectionState>.Continuation] in s.connection = c; return Array(s.states.values) }
        for k in continuations { k.yield(c) }
    }

    // MARK: GatewayClient

    func rest(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async throws -> Data {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue(state.withLock { $0.cookie }, forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw HTTPError(status: status, body: String(data: data.prefix(300), encoding: .utf8)) }
        return data
    }

    func call(_ method: String, _ params: JSONValue, timeout: Duration) async throws -> JSONValue {
        let (id, socket) = state.withLock { s -> (Int, URLSessionWebSocketTask?) in let id = s.nextId; s.nextId += 1; return (id, s.socket) }
        guard let socket else { throw Failure(description: "socket not open") }
        let frame: JSONValue = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]
        let timer = Task.detached { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            let continuation = self.state.withLock { $0.pending.removeValue(forKey: id) }
            continuation?.resume(throwing: Failure(description: "request timed out: \(method)"))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            state.withLock { $0.pending[id] = continuation }
            socket.send(.string(ChatJSON.stringify(frame))) { [weak self] error in
                guard let error, let self else { return }
                let c = self.state.withLock { $0.pending.removeValue(forKey: id) }
                c?.resume(throwing: error)
            }
        }
    }

    func events() -> AsyncStream<GatewayEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            state.withLock { $0.events[id] = continuation }
            continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.events.removeValue(forKey: id) } }
        }
    }

    func connectionStates() -> AsyncStream<ConnectionState> {
        let id = UUID()
        return AsyncStream { continuation in
            let current = state.withLock { s -> ConnectionState in s.states[id] = continuation; return s.connection }
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.states.removeValue(forKey: id) } }
        }
    }

    var latestReady: JSONValue? { state.withLock { $0.ready } }
    func appDidBecomeActive() {}
    func appDidEnterBackground() {}
    func shutdown() {
        let task = state.withLock { s -> URLSessionWebSocketTask? in let t = s.socket; s.socket = nil; s.socketGeneration += 1; return t }
        task?.cancel(with: .goingAway, reason: nil)
        failPending(Failure(description: "shut down"))
    }

    // MARK: Fixture controls (loopback only)

    func fixture(_ path: String, _ body: JSONValue) async throws {
        _ = try await rest("POST", path, query: [], body: Data(ChatJSON.stringify(body).utf8))
    }
}
