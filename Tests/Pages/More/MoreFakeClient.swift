// A scripted GatewayClient for the More pages' unit tests: REST and JSON-RPC are each answered by a responder and
// logged, so a test can check exactly which keys went out (Hermes refuses unknown params with error 4000).

import Foundation
import Synchronization
@testable import HermesHQNative

nonisolated final class MoreFakeClient: GatewayClient, Sendable {
    struct Request: Sendable, CustomStringConvertible {
        var method: String          // "GET" … or "RPC"
        var path: String            // the REST path, or the RPC method
        var query: [String: String]
        var body: JSONValue?        // the REST body, or the RPC params
        var description: String {
            let q = query.keys.sorted().map { "\($0)=\(query[$0]!)" }.joined(separator: "&")
            return "\(method) \(path)\(q.isEmpty ? "" : "?" + q)"
        }
    }
    typealias Responder = @Sendable (Request) async throws -> JSONValue

    let account = GatewayAccount(id: "http://127.0.0.1:10050|more", baseURL: URL(string: "http://127.0.0.1:10050")!, kind: .password,
                                 username: "more", label: "more fixture")
    private let state = Mutex<(log: [Request], responder: Responder)>(([], { _ in .object([:]) }))

    init(_ responder: @escaping Responder = { _ in .object([:]) }) { state.withLock { $0.responder = responder } }

    func respond(_ responder: @escaping Responder) { state.withLock { $0.responder = responder } }
    var log: [Request] { state.withLock { $0.log } }
    var logLines: [String] { log.map(\.description) }

    private func answer(_ request: Request) async throws -> JSONValue {
        let responder = state.withLock { s -> Responder in s.log.append(request); return s.responder }
        return try await responder(request)
    }

    func rest(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async throws -> Data {
        var q: [String: String] = [:]
        for item in query { q[item.name] = item.value ?? "" }
        return try await answer(Request(method: method, path: path, query: q, body: body.flatMap { try? JSONValue.parse($0) })).encoded()
    }

    func call(_ method: String, _ params: JSONValue, timeout: Duration) async throws -> JSONValue {
        try await answer(Request(method: "RPC", path: method, query: [:], body: params))
    }

    func events() -> AsyncStream<GatewayEvent> { AsyncStream { _ in } }
    func connectionStates() -> AsyncStream<ConnectionState> { AsyncStream { $0.yield(.ready) } }
    var latestReady: JSONValue? { ["change_events": true] }
    func appDidBecomeActive() {}
    func appDidEnterBackground() {}
    func shutdown() {}
}
