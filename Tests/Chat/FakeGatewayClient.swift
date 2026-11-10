// A scripted GatewayClient for chat tests: canned REST answers, scripted RPC results, and an event pump that can
// replay frames captured from the stand-in gateways (Tests/Fixtures/chat).

import Foundation
import Synchronization
@testable import HermesHQNative

nonisolated final class FakeGatewayClient: GatewayClient, Sendable {
    typealias RestResponder = @Sendable (_ path: String, _ query: [URLQueryItem]) throws -> Data
    typealias CallResponder = @Sendable (_ method: String, _ params: JSONValue) async throws -> JSONValue

    struct Call: Sendable { var method: String; var params: JSONValue }
    struct Rest: Sendable { var path: String; var query: [URLQueryItem] }

    private struct State: Sendable {
        var rest: RestResponder = { _, _ in Data("{\"messages\":[]}".utf8) }
        var call: CallResponder = { _, _ in .object([:]) }
        var calls: [Call] = []
        var restLog: [Rest] = []
        var holds: [Bool] = []                 // [talk-background]
        var events: [UUID: AsyncStream<GatewayEvent>.Continuation] = [:]
        var states: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]
        var state: ConnectionState = .ready
        var ready: JSONValue?
        var replayedFrom: [String: Int] = [:]
    }

    let account: GatewayAccount
    private let state = Mutex(State())

    init(ready: JSONValue? = ["heartbeat": true, "change_events": true, "replay_epoch": "fixture-epoch"]) {
        account = GatewayAccount(id: "http://127.0.0.1:9717|tester", baseURL: URL(string: "http://127.0.0.1:9717")!,
                                 kind: .password, username: "tester", label: "fixture")
        state.withLock { $0.ready = ready }
    }

    // MARK: Scripting

    func onRest(_ responder: @escaping RestResponder) { state.withLock { $0.rest = responder } }
    func onCall(_ responder: @escaping CallResponder) { state.withLock { $0.call = responder } }

    var calls: [Call] { state.withLock { $0.calls } }
    var restLog: [Rest] { state.withLock { $0.restLog } }
    func calls(_ method: String) -> [Call] { calls.filter { $0.method == method } }

    func emit(_ event: GatewayEvent) {
        let continuations = state.withLock { Array($0.events.values) }
        for c in continuations { c.yield(event) }
    }

    /// Emits a captured raw frame `{"jsonrpc","method":"event","params":{type,session_id,payload?,seq?}}`.
    func emit(frame: JSONValue) {
        guard frame["method"]?.string == "event", let params = frame["params"], let type = params["type"]?.string else { return }
        emit(GatewayEvent(type: type, sessionId: params["session_id"]?.string ?? "", seq: params["seq"]?.int,
                          payload: params["payload"] ?? .null))
    }

    func setConnection(_ s: ConnectionState) {
        let continuations = state.withLock { st -> [AsyncStream<ConnectionState>.Continuation] in st.state = s; return Array(st.states.values) }
        for c in continuations { c.yield(s) }
    }

    func setReady(_ payload: JSONValue) {
        state.withLock { $0.ready = payload }
        emit(GatewayEvent(type: "gateway.ready", sessionId: "", seq: nil, payload: payload))
    }

    var subscriberCount: Int { state.withLock { $0.events.count } }

    // MARK: GatewayClient

    func rest(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async throws -> Data {
        let responder = state.withLock { st -> RestResponder in st.restLog.append(Rest(path: path, query: query)); return st.rest }
        return try responder(path, query)
    }

    func call(_ method: String, _ params: JSONValue, timeout: Duration) async throws -> JSONValue {
        let responder = state.withLock { st -> CallResponder in st.calls.append(Call(method: method, params: params)); return st.call }
        return try await responder(method, params)
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
            let current = state.withLock { st -> ConnectionState in st.states[id] = continuation; return st.state }
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.states.removeValue(forKey: id) } }
        }
    }

    var latestReady: JSONValue? { state.withLock { $0.ready } }
    /// What `replayedCursor(session:)` answers (the connection's own replay of a session after a reconnect).
    func setReplayed(_ session: String, from cursor: Int?) { state.withLock { $0.replayedFrom[session] = cursor } }
    func replayedCursor(session: String) async -> Int? { state.withLock { $0.replayedFrom[session] } }
    func appDidBecomeActive() {}
    func appDidEnterBackground() {}
    /// [talk-background] Every hold asked for through the background, in order.
    func holdThroughBackground(_ on: Bool) { state.withLock { $0.holds.append(on) } }
    var holds: [Bool] { state.withLock { $0.holds } }
    func shutdown() {}
}

// MARK: - Fixtures

nonisolated enum ChatFixtures {
    static func url(_ name: String, file: String = #filePath) -> URL {
        URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/chat/\(name)")
    }

    static func data(_ name: String) throws -> Data {
        let local = url(name)
        if let d = try? Data(contentsOf: local) { return d }
        final class Marker {}
        if let bundled = Bundle(for: Marker.self).url(forResource: (name as NSString).deletingPathExtension, withExtension: "json") {
            return try Data(contentsOf: bundled)
        }
        throw CocoaError(.fileNoSuchFile)
    }

    static func json(_ name: String) throws -> JSONValue { try ChatJSON.parse(data(name)) }

    /// Captured frames, minus our own sent requests (`{"_sent": …}`).
    static func frames(_ name: String) throws -> [JSONValue] {
        (try json(name).array ?? []).filter { $0["_sent"] == nil }
    }

    static func eventFrames(_ name: String) throws -> [JSONValue] {
        try frames(name).filter { $0["method"]?.string == "event" }
    }
}

@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// A fresh cache in a temp folder.
func makeTempCache(limits: TranscriptCache.Limits = .init()) -> TranscriptCache {
    let dir = FileManager.default.temporaryDirectory.appending(path: "hq-cache-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    return TranscriptCache(root: dir, limits: limits)
}

nonisolated func encodeJSON(_ value: JSONValue) -> Data { Data(ChatJSON.stringify(value).utf8) }
