// Test support for the Bots data module: a scripted GatewayClient, fixture loading and small waits.

import Foundation
import Testing
@testable import HermesHQNative

/// A scripted `GatewayClient`: per-method RPC handlers, one REST handler, every call recorded, events and connection
/// states pushed by the test. Unknown RPC methods answer -32601 like real Hermes.
nonisolated final class BotsFakeGatewayClient: GatewayClient, @unchecked Sendable {
    typealias RPCHandler = @Sendable (JSONValue) async throws -> JSONValue
    typealias RESTHandler = @Sendable (_ method: String, _ path: String, _ query: [URLQueryItem], _ body: Data?) async throws -> Data

    struct Call: Sendable { var method: String; var params: JSONValue; var timeout: Duration; var at: ContinuousClock.Instant }
    struct RESTCall: Sendable { var method: String; var path: String; var query: [URLQueryItem]; var body: Data?; var at: ContinuousClock.Instant }

    let account: GatewayAccount
    private let lock = NSLock()
    private var handlers: [String: RPCHandler] = [:]
    private var restHandler: RESTHandler?
    private var callLog: [Call] = []
    private var restLog: [RESTCall] = []
    private var eventSinks: [UUID: AsyncStream<GatewayEvent>.Continuation] = [:]
    private var stateSinks: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]
    private var state: ConnectionState = .ready
    private var ready: JSONValue?

    init(account: GatewayAccount = .botsTestAccount, latestReady: JSONValue? = nil, state: ConnectionState = .ready) {
        self.account = account
        ready = latestReady
        self.state = state
    }

    // Scripting

    func on(_ method: String, _ handler: @escaping RPCHandler) { lock.withLock { handlers[method] = handler } }
    func onREST(_ handler: @escaping RESTHandler) { lock.withLock { restHandler = handler } }

    var calls: [Call] { lock.withLock { callLog } }
    var restCalls: [RESTCall] { lock.withLock { restLog } }
    func calls(_ method: String) -> [Call] { calls.filter { $0.method == method } }

    func emit(_ event: GatewayEvent) {
        let sinks = lock.withLock { Array(eventSinks.values) }
        for sink in sinks { sink.yield(event) }
    }

    func emit(_ type: String, payload: JSONValue = .object([:])) {
        emit(GatewayEvent(type: type, sessionId: "", seq: nil, payload: payload))
    }

    func setState(_ newState: ConnectionState) {
        let sinks = lock.withLock { state = newState; return Array(stateSinks.values) }
        for sink in sinks { sink.yield(newState) }
    }

    var subscriberCount: Int { lock.withLock { eventSinks.count } }

    // GatewayClient

    func rest(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async throws -> Data {
        let handler = lock.withLock { () -> RESTHandler? in
            restLog.append(RESTCall(method: method, path: path, query: query, body: body, at: .now))
            return restHandler
        }
        guard let handler else { throw HTTPError(status: 404, body: nil) }
        return try await handler(method, path, query, body)
    }

    func call(_ method: String, _ params: JSONValue, timeout: Duration) async throws -> JSONValue {
        let handler = lock.withLock { () -> RPCHandler? in
            callLog.append(Call(method: method, params: params, timeout: timeout, at: .now))
            return handlers[method]
        }
        guard let handler else { throw RPCError(code: -32601, message: "method not found: \(method)", data: nil) }
        return try await handler(params)
    }

    func events() -> AsyncStream<GatewayEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.withLock { eventSinks[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.eventSinks.removeValue(forKey: id) }
            }
        }
    }

    func connectionStates() -> AsyncStream<ConnectionState> {
        let id = UUID()
        return AsyncStream { continuation in
            let current = lock.withLock { stateSinks[id] = continuation; return state }
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.stateSinks.removeValue(forKey: id) }
            }
        }
    }

    var latestReady: JSONValue? { lock.withLock { ready } }
    func appDidBecomeActive() {}
    func appDidEnterBackground() {}
    func shutdown() {}
}

extension GatewayAccount {
    nonisolated static let botsTestAccount = GatewayAccount(id: "http://127.0.0.1:9715|voice-fixture", baseURL: URL(string: "http://127.0.0.1:9715")!,
                                                    kind: .password, username: "voice-fixture", label: "127.0.0.1")
}

/// Captured payloads in Tests/Fixtures (see scripts/capture-roster-fixtures.py).
nonisolated enum BotsFixture {
    private final class Token {}

    static func data(_ name: String) throws -> Data {
        if let url = Bundle(for: Token.self).url(forResource: name, withExtension: "json") { return try Data(contentsOf: url) }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    static func json(_ name: String) throws -> JSONValue { try JSONValue.parse(data(name)) }

    static func parse(_ text: String) -> JSONValue { try! JSONValue.parse(Data(text.utf8)) }
}

/// Store timings for tests: no settle, short waits, polls far away unless a test asks.
extension BotStoreTiming {
    static var fast: BotStoreTiming {
        var t = BotStoreTiming()
        t.slimWait = .milliseconds(80)
        t.settle = .zero
        t.onListPoll = .seconds(3600)
        t.offListPoll = .seconds(3600)
        t.retryDelays = [.milliseconds(20), .milliseconds(40)]
        t.openWait = .milliseconds(300)
        t.confirmWait = .milliseconds(400)
        t.readsBotSaid = false       // [botsaid] the Bot Chat tail reads have their own tests (BotSaidTests)
        return t
    }
}

extension SessionStoreTiming {
    static var fast: SessionStoreTiming {
        var t = SessionStoreTiming()
        t.onScreenGap = .milliseconds(300)
        t.offScreenGap = .milliseconds(300)
        t.fallbackOnScreenPoll = .seconds(3600)
        t.fallbackOffScreenPoll = .seconds(3600)
        t.readsLatest = false        // the newest-message reads have their own tests (SessionLatestTests)
        return t
    }
}

nonisolated enum BotsTest {
    /// A fresh, empty cache directory per test.
    static func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bots-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Poll a main-actor condition until it holds or the time runs out.
    @MainActor @discardableResult
    static func waitUntil(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// JSON helpers for building roster rows in tests.
    static func profilesResult(_ rows: [JSONValue]) -> JSONValue { .object(["profiles": .array(rows), "bot_mode_protocol": true]) }

    static func row(_ name: String, display: String? = nil, canonical: JSONValue? = nil, last: JSONValue? = nil,
             meta: [String: JSONValue]? = nil, description: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["name": .string(name), "path": .string("/p/\(name)"), "is_default": .bool(name == "default"),
                                      "ui_meta_revisions": .object([:])]
        if let display { o["display_name"] = .string(display) }
        if let description { o["description"] = .string(description) }
        if let canonical { o["canonical_session"] = canonical }
        if let last { o["last_session"] = last }
        if let meta { o["ui_meta"] = .object(["hermes-bots": .object(meta)]) }
        return .object(o)
    }

    static func session(_ id: String, resolved: String? = nil, preview: String = "hello", lastActive: Double, count: Int = 4,
                 title: String = "Bot Chat", source: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "title": .string(title), "preview": .string(preview),
                                      "last_active": .number(lastActive), "message_count": .number(Double(count))]
        if let resolved { o["resolved_id"] = .string(resolved) }
        if let source { o["source"] = .string(source) }
        return .object(o)
    }

    /// Remove `canonical_session` / `last_session` / `worker_session` from every row (a real slim answer).
    static func slimmed(_ result: JSONValue) -> JSONValue {
        guard var root = result.object, let rows = root["profiles"]?.array else { return result }
        root["profiles"] = .array(rows.map { row in
            guard var o = row.object else { return row }
            for key in ["canonical_session", "last_session", "worker_session", "sessions"] { o[key] = nil }
            return .object(o)
        })
        return .object(root)
    }

    /// The text a formatted time shows, with the narrow no-break space ICU puts before AM/PM made a plain space.
    static func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ") }
}

/// Sleep that ignores cancellation: a gateway answer that is already on its way still arrives after the caller gave up.
nonisolated func botsUncancellableSleep(_ duration: Duration) async {
    await Task.detached { try? await Task.sleep(for: duration) }.value
}

/// A value shared between a test and the fake's `@Sendable` handlers.
nonisolated final class BotsTestBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    @discardableResult
    func mutate<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&stored) } }
}
