// Opt-in end-to-end check of BotStore and SessionStore against the demo stand-in gateway (spec 05 §A8), over a real
// WebSocket. Runs only when the test runner gets the fixture's credentials file:
//   TEST_RUNNER_HQN_DEMO_CREDENTIALS=<scratch>/demo.json scripts/build.sh test <SIM>
// (the Simulator shares the Mac's loopback). Signs in exactly once per run; loopback fixtures only.

import Foundation
import Testing
@testable import HermesHQNative

/// A minimal password-cookie GatewayClient for loopback fixtures (the real one is the Net module's).
nonisolated final class BotsMiniLiveClient: GatewayClient, @unchecked Sendable {
    let account: GatewayAccount
    private let base: URL
    private let session: URLSession
    private let cookie: String
    private var socket: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var sinks: [UUID: AsyncStream<GatewayEvent>.Continuation] = [:]
    private var ready: JSONValue?

    private init(base: URL, cookie: String, session: URLSession) {
        self.base = base; self.cookie = cookie; self.session = session
        account = GatewayAccount(id: "\(base.absoluteString)|live", baseURL: base, kind: .password, username: "voice-fixture",
                                 label: base.host ?? "fixture")
    }

    static func connect(credentialsFile: String) async throws -> BotsMiniLiveClient {
        let creds = try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: credentialsFile)))
        guard let url = creds["url"]?.string.flatMap(URL.init(string:)), ["127.0.0.1", "localhost"].contains(url.host ?? "") else {
            throw HTTPError(status: 0, body: "loopback fixtures only")
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config)
        var login = URLRequest(url: url.appendingPathComponent("auth/password-login"))
        login.httpMethod = "POST"
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.httpBody = try JSONValue.object(["provider": "fake", "username": creds["username"] ?? .null,
                                               "password": creds["password"] ?? .null]).encoded()
        let (_, response) = try await session.data(for: login)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let setCookie = http.value(forHTTPHeaderField: "Set-Cookie") else { throw HTTPError(status: 401, body: "sign-in failed") }
        let client = BotsMiniLiveClient(base: url, cookie: String(setCookie.split(separator: ";")[0]), session: session)
        let ticket = try JSONValue.parse(await client.rest("POST", "/api/auth/ws-ticket", query: [], body: Data("{}".utf8)))["ticket"]?.string ?? ""
        var components = URLComponents(url: url.appendingPathComponent("api/ws"), resolvingAgainstBaseURL: false)!
        components.scheme = "ws"
        components.queryItems = [URLQueryItem(name: "profile", value: "default"), URLQueryItem(name: "ticket", value: ticket)]
        var upgrade = URLRequest(url: components.url!)
        upgrade.setValue(client.cookie, forHTTPHeaderField: "Cookie")
        let socket = session.webSocketTask(with: upgrade)
        client.socket = socket
        socket.resume()
        client.receiveLoop()
        return client
    }

    private func receiveLoop() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            guard case .success(let message) = result else { return }
            let text: String
            switch message {
            case .string(let s): text = s
            case .data(let d): text = String(decoding: d, as: UTF8.self)
            @unknown default: text = ""
            }
            if let frame = try? JSONValue.parse(Data(text.utf8)) { self.dispatch(frame) }
            self.receiveLoop()
        }
    }

    private func dispatch(_ frame: JSONValue) {
        if let id = frame["id"]?.int {
            let waiter = lock.withLock { pending.removeValue(forKey: id) }
            if let error = frame["error"] {
                waiter?.resume(throwing: RPCError(code: error["code"]?.int ?? -1, message: error["message"]?.string ?? "RPC failed", data: error["data"]))
            } else {
                waiter?.resume(returning: frame["result"] ?? .null)
            }
        } else if frame["method"]?.string == "event", let params = frame["params"] {
            let event = GatewayEvent(type: params["type"]?.string ?? "", sessionId: params["session_id"]?.string ?? "",
                                     seq: params["seq"]?.int, payload: params["payload"] ?? .null)
            let sinks = lock.withLock { () -> [AsyncStream<GatewayEvent>.Continuation] in
                if event.type == "gateway.ready" { ready = event.payload }
                return Array(self.sinks.values)
            }
            for sink in sinks { sink.yield(event) }
        }
    }

    func rest(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async throws -> Data {
        var components = URLComponents(url: base.appendingPathComponent(String(path.dropFirst())), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw HTTPError(status: status, body: String(decoding: data, as: UTF8.self)) }
        return data
    }

    func call(_ method: String, _ params: JSONValue, timeout: Duration) async throws -> JSONValue {
        let id = lock.withLock { () -> Int in defer { nextId += 1 }; return nextId }
        let frame = try JSONValue.object(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]).encoded()
        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.lock.withLock { self.pending[id] = continuation }
                    self.socket?.send(.string(String(decoding: frame, as: UTF8.self))) { error in
                        if let error, let waiter = self.lock.withLock({ self.pending.removeValue(forKey: id) }) { waiter.resume(throwing: error) }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                if let waiter = self.lock.withLock({ self.pending.removeValue(forKey: id) }) {
                    waiter.resume(throwing: RPCError(code: -1, message: "request timed out: \(method)", data: nil))
                }
                throw RPCError(code: -1, message: "request timed out: \(method)", data: nil)
            }
            let answer = try await group.next()!
            group.cancelAll()
            return answer
        }
    }

    func events() -> AsyncStream<GatewayEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.withLock { sinks[id] = continuation }
            continuation.onTermination = { [weak self] _ in self?.lock.withLock { _ = self?.sinks.removeValue(forKey: id) } }
        }
    }

    func connectionStates() -> AsyncStream<ConnectionState> { AsyncStream { $0.yield(.ready) } }
    var latestReady: JSONValue? { lock.withLock { ready } }
    func appDidBecomeActive() {}
    func appDidEnterBackground() {}
    func shutdown() { socket?.cancel(with: .goingAway, reason: nil) }
}

@MainActor private var liveClient: BotsMiniLiveClient?

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HQN_DEMO_CREDENTIALS"] != nil))
struct LiveDemoGatewayTests {
    private func client() async throws -> BotsMiniLiveClient {
        if let liveClient { return liveClient }
        let made = try await BotsMiniLiveClient.connect(credentialsFile: ProcessInfo.processInfo.environment["HQN_DEMO_CREDENTIALS"]!)
        liveClient = made
        return made
    }

    @Test func rosterAndBotChatOverTheWire() async throws {
        let client = try await client()
        let dir = BotsTest.tempDirectory()
        let started = ContinuousClock.now
        var timing = BotStoreTiming.standard
        timing.settle = .zero
        let store = BotStore(client: client, account: client.account, cacheDirectory: dir, timing: timing)
        #expect(await BotsTest.waitUntil(.seconds(10)) { store.phase == .full })
        let loaded = ContinuousClock.now - started
        #expect(store.bots.count == 9)
        #expect(store.layout.tiles.map(\.name) == ["Hermes", "Deploys", "Research"])
        #expect(store.layout.sections.map(\.name) == ["Work", "Home"])
        let deploys = try #require(store.bot(named: "deploys"))
        #expect(try await store.chatSessionId(for: deploys) == "20261001_093800_aa000003")
        #expect(try await store.lookupChatSessionId(for: deploys) == "20261001_093800_aa000003")
        #expect(await store.registryReplacement(for: deploys, openedId: "20261001_093800_aa000003") == nil)
        store.stop()
        RosterDiskWriter.shared.flush()

        let paintStart = ContinuousClock.now
        let cached = BotStore(client: client, account: client.account, cacheDirectory: dir, autoStart: false)
        let paint = ContinuousClock.now - paintStart
        #expect(cached.bots.map(\.id) == store.bots.map(\.id))
        print("LIVE demo roster: full load \(loaded); cached paint in init \(paint)")
    }

    @Test func sessionsOverTheWire() async throws {
        let client = try await client()
        let store = SessionStore(client: client, account: client.account, cacheDirectory: BotsTest.tempDirectory())
        #expect(await BotsTest.waitUntil(.seconds(10)) { store.loadState == .ready })
        #expect(store.sessions.count == 7)
        #expect(store.sections().first?.title == "Pinned")
        store.stop()
    }
}
