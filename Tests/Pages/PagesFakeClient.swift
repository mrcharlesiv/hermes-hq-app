// A scripted GatewayClient for the pages' tests: each REST call is answered by an async responder keyed on method and
// path, and logged (method, path, query, body).

import Foundation
import Synchronization
@testable import HermesHQNative

nonisolated final class PagesFakeClient: GatewayClient, Sendable {
    struct Request: Sendable, CustomStringConvertible {
        var method: String
        var path: String
        var query: [String: String]
        var body: JSONValue?
        var description: String {
            let q = query.keys.sorted().map { "\($0)=\(query[$0]!)" }.joined(separator: "&")
            return "\(method) \(path)\(q.isEmpty ? "" : "?" + q)"
        }
    }
    typealias Responder = @Sendable (Request) async throws -> JSONValue

    let account = GatewayAccount(id: "http://127.0.0.1:9735|pages", baseURL: URL(string: "http://127.0.0.1:9735")!, kind: .password,
                                 username: "pages", label: "pages fixture")
    private let state = Mutex<(log: [Request], responder: Responder)>(([], { _ in .object([:]) }))

    init(_ responder: @escaping Responder = { _ in .object([:]) }) { state.withLock { $0.responder = responder } }

    func respond(_ responder: @escaping Responder) { state.withLock { $0.responder = responder } }
    var log: [Request] { state.withLock { $0.log } }
    var logLines: [String] { log.map(\.description) }

    func rest(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async throws -> Data {
        var q: [String: String] = [:]
        for item in query { q[item.name] = item.value ?? "" }
        let request = Request(method: method, path: path, query: q, body: body.flatMap { try? JSONValue.parse($0) })
        let responder = state.withLock { s -> Responder in s.log.append(request); return s.responder }
        let answer = try await responder(request)
        return try answer.encoded()
    }

    func call(_ method: String, _ params: JSONValue, timeout: Duration) async throws -> JSONValue { .object([:]) }
    func events() -> AsyncStream<GatewayEvent> { AsyncStream { _ in } }
    func connectionStates() -> AsyncStream<ConnectionState> { AsyncStream { $0.yield(.ready) } }
    var latestReady: JSONValue? { ["change_events": true] }
    func appDidBecomeActive() {}
    func appDidEnterBackground() {}
    func shutdown() {}
}

nonisolated func httpError(_ status: Int, _ detail: String) -> HTTPError {
    HTTPError(status: status, body: (try? String(decoding: JSONValue.object(["detail": .string(detail)]).encoded(), as: UTF8.self)) ?? "")
}
