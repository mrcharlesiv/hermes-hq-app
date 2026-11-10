// A recording GatewayTransfers fake for the memo pipeline (A-U4): every REST read, transfer and RPC lands in one ordered
// log with its body, so a test can check the exact call order, the multipart bytes and the attach keys.

import Foundation
import Synchronization
@testable import HermesHQNative

nonisolated final class VoiceFakeClient: GatewayTransfers, Sendable {
    struct Entry: Sendable {
        var kind: String          // "GET /api/files", "POST /api/files/upload-stream", "rpc file.attach", …
        var query: [URLQueryItem] = []
        var body: Data? = nil
        var contentType: String? = nil
        var params: JSONValue? = nil
    }
    typealias Rest = @Sendable (_ method: String, _ path: String, _ body: Data?) throws -> Data
    typealias Call = @Sendable (_ method: String, _ params: JSONValue, _ attempt: Int) throws -> JSONValue

    private struct State: Sendable {
        var log: [Entry] = []
        var rest: Rest
        var call: Call
        var attempts: [String: Int] = [:]
        /// A wait before answering, by kind ("POST /api/files/upload-stream", "rpc prompt.submit"). It suspends (and
        /// ends early when the caller's task is cancelled, like a cancelled URLSession request): the fake's calls run on
        /// the caller's actor, so a blocking sleep would freeze the test's main actor too.
        var delays: [String: Duration] = [:]
    }
    let account: GatewayAccount
    private let state: Mutex<State>

    static let root = "/Users/owner"
    static let rid = "5cc537d1"

    init(accountId: String = "voice-fake-\(UUID().uuidString)") {
        account = GatewayAccount(id: accountId, baseURL: URL(string: "http://127.0.0.1:9799")!, kind: .password, username: "t", label: "fake")
        state = Mutex(State(rest: VoiceFakeClient.defaultRest, call: VoiceFakeClient.defaultCall))
    }

    /// The happy path: files root, an upload that answers its own path, STT on, a transcript, history pages empty.
    static let defaultRest: Rest = { method, path, body in
        switch (method, path) {
        case ("GET", "/api/files"): return Data(#"{"path":"/Users/owner","parent":null,"entries":[]}"#.utf8)
        case ("GET", "/api/config"): return Data(#"{"stt":{"enabled":true}}"#.utf8)
        case ("POST", "/api/files/upload-stream"):
            let text = String(decoding: body ?? Data(), as: UTF8.self)
            let path = text.components(separatedBy: "name=\"path\"\r\n\r\n").dropFirst().first?.components(separatedBy: "\r\n").first ?? ""
            return Data(ChatJSON.stringify(["ok": true, "path": .string(path)]).utf8)
        case ("DELETE", "/api/files"): return Data(#"{"ok":true}"#.utf8)
        case ("POST", "/api/audio/transcribe"): return Data(#"{"ok":true,"transcript":"Pick up milk on the way home.","provider":"fake"}"#.utf8)
        default: return Data(#"{"messages":[],"pagination":{"returned":0,"has_more":false}}"#.utf8)
        }
    }

    static let defaultCall: Call = { method, params, _ in
        switch method {
        case "session.resume": return ["session_id": .string(rid), "running": false, "resumed": params["session_id"] ?? "20260929_120000_aabbcc01"]
        case "file.attach":
            let name = params["name"]?.string ?? "voice-memo.m4a"
            let stored = "\(root)/.hermes/profiles/ivy/attachments/\(name)"
            return ["attached": true, "name": .string(name), "path": .string(stored), "ref_path": .string(stored),
                    "ref_text": .string("@file:\(stored)"), "uploaded": true]
        case "prompt.submit": return ["status": "streaming", "user_row_id": 42]
        case "session.active_list": return ["sessions": []]
        default: return [:]
        }
    }

    func onRest(_ rest: @escaping Rest) { state.withLock { $0.rest = rest } }
    func delay(_ kind: String, _ duration: Duration) { state.withLock { $0.delays[kind] = duration } }

    private func wait(_ kind: String) async throws {
        if let duration = state.withLock({ $0.delays[kind] }) { try await Task.sleep(for: duration) }
    }
    func onCall(_ call: @escaping Call) { state.withLock { $0.call = call } }

    var log: [Entry] { state.withLock { $0.log } }
    var kinds: [String] { log.map(\.kind) }
    func entries(_ kind: String) -> [Entry] { log.filter { $0.kind == kind } }

    func rest(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async throws -> Data {
        let responder = state.withLock { s -> Rest in s.log.append(Entry(kind: "\(method) \(path)", query: query, body: body)); return s.rest }
        try await wait("\(method) \(path)")
        return try responder(method, path, body)
    }

    func transfer(_ method: String, _ path: String, query: [URLQueryItem], body: Data?, contentType: String,
                  timeout: TimeInterval) async throws -> Data {
        let responder = state.withLock { s -> Rest in
            s.log.append(Entry(kind: "\(method) \(path)", query: query, body: body, contentType: contentType))
            return s.rest
        }
        try await wait("\(method) \(path)")
        return try responder(method, path, body)
    }

    func call(_ method: String, _ params: JSONValue, timeout: Duration) async throws -> JSONValue {
        let (responder, attempt) = state.withLock { s -> (Call, Int) in
            s.log.append(Entry(kind: "rpc \(method)", params: params))
            s.attempts[method, default: 0] += 1
            return (s.call, s.attempts[method]!)
        }
        try await wait("rpc \(method)")
        return try responder(method, params, attempt)
    }

    func events() -> AsyncStream<GatewayEvent> { AsyncStream { _ in } }
    func connectionStates() -> AsyncStream<ConnectionState> { AsyncStream { $0.yield(.ready) } }
    var latestReady: JSONValue? { ["heartbeat": true, "replay_epoch": "fake"] }
    func appDidBecomeActive() {}
    func appDidEnterBackground() {}
    func shutdown() {}
}

/// Memo stores in a temp folder, for one test.
@MainActor enum VoiceTestStores {
    static let base: URL = {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hq-voice-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        MemoPaths.supportBase = dir.appending(path: "support", directoryHint: .isDirectory)
        MemoPaths.cachesBase = dir.appending(path: "caches", directoryHint: .isDirectory)
        return dir
    }()

    /// Activates the stores for `accountId` under the test folder.
    static func activate(_ accountId: String) {
        _ = base
        MemoAccountStores.shared.activate(accountId: accountId)
    }

    /// A recording file under memos/<key>/ (a short WAV).
    static func recording(_ accountId: String, seconds: Double = 2) throws -> MemoFile {
        _ = base
        let url = MemoPaths.newRecording(MemoPaths.accountKey(accountId), ext: "wav")
        MemoPaths.ensure(url.deletingLastPathComponent())
        let wave = MemoRecorder.fixtureWave(seconds: seconds, levels: [0.3, 0.6, 0.9])
        try wave.write(to: url)
        return MemoFile(path: url.path, seconds: seconds, peaks: MemoPolicy.peaks([0.3, 0.6, 0.9]), mime: "audio/wav")
    }
}
