// Long-running gateway actions the More pages start (docs/spec/3x-morepages.md §12 (6), §15): Restart Gateway, Update
// Hermes, Run Doctor. Each POST answers an action record with a `name`; progress is read from
// `GET /api/actions/<name>/status?lines=200` (`AG/hermes_cli/web_routers/actions.py`). `GatewayActionRun` polls it
// and keeps its state through the link dropping while a gateway restarts.

import Foundation
import Observation

nonisolated struct GatewayActionStatus: Sendable, Equatable {
    var name: String
    var running: Bool
    var exitCode: Int?
    var lines: [String]
    /// [update-flow] hermes-update's receipt summary (`receipt`), when the gateway sends one.
    var receipt: HermesUpdateReceipt?

    init(name: String, running: Bool, exitCode: Int?, lines: [String], receipt: HermesUpdateReceipt? = nil) {
        self.name = name; self.running = running; self.exitCode = exitCode; self.lines = lines; self.receipt = receipt
    }

    /// Lenient: a missing `running` reads as finished only when an exit code is there.
    init(json: JSONValue, fallbackName: String) {
        name = json["name"]?.string ?? fallbackName
        exitCode = json["exit_code"]?.double.map { Int($0) }
        running = json["running"]?.bool ?? (exitCode == nil)
        lines = json["lines"]?.array?.compactMap(\.pgString) ?? []
        receipt = HermesUpdateReceipt(json: json["receipt"])
    }

    var lastLine: String? { lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
}

nonisolated struct GatewayActionsAPI: Sendable {
    let client: any GatewayClient

    /// `POST /api/gateway/restart[?profile=]` → the action's name ("gateway-restart").
    func restart(profile: String? = nil) async throws -> String {
        try await start("/api/gateway/restart", query: MoreWire.profileQuery(profile), fallback: "gateway-restart")
    }

    /// `POST /api/hermes/update` → "hermes-update". The gateway answers `ok:false` with a `message` when it cannot start.
    func update() async throws -> String {
        try await start("/api/hermes/update", query: [], fallback: "hermes-update")
    }

    /// `POST /api/ops/doctor` with `{}` → "doctor".
    func doctor(profile: String? = nil) async throws -> String {
        try await start("/api/ops/doctor", query: MoreWire.profileQuery(profile), fallback: "doctor", body: .object([:]))
    }

    func start(_ path: String, query: [URLQueryItem], fallback: String, body: JSONValue? = nil) async throws -> String {
        let answer = try await PagesREST.json(client, "POST", path, query: query, json: body, timeout: 30)
        if answer["ok"]?.bool == false {
            let reason = answer["message"]?.string ?? answer["error"]?.string ?? "The gateway couldn’t start that."
            AppLog.note("config", "gateway action \(fallback) refused to start: \(reason)")
            throw PagesMessageError(reason)
        }
        let name = answer["name"]?.string ?? fallback
        AppLog.trace("config", "gateway action \(fallback) started as \(name)")
        return name
    }

    /// `GET /api/actions/<name>/status?lines=N`.
    func status(_ name: String, lines: Int = 200) async throws -> GatewayActionStatus {
        let answer = try await PagesREST.json(client, "GET", "/api/actions/\(PagesREST.segment(name))/status",
                                              query: [URLQueryItem(name: "lines", value: String(lines))], timeout: 10)
        return GatewayActionStatus(json: answer, fallbackName: name)
    }
}

/// One action from start to its end. The poll survives failed reads (a restarting gateway answers nothing for a
/// moment): after `patience` it says so (`stalled`) and keeps reading more slowly until an answer comes.
@MainActor @Observable
final class GatewayActionRun {
    enum Phase: Equatable {
        case idle
        case running
        /// Still no end after `patience`: "Still restarting. This page updates when your gateway is back."
        case stalled
        case finished(ok: Bool, lastLine: String?)
        /// Stress test 2026-10-28 #10: the status route answered "not found" (a Hermes without
        /// `/api/actions/<name>/status`): the action was sent, but its end can't be followed. Said once; no more reads.
        case untracked
        /// The action never started (the POST failed).
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var lines: [String] = []
    var isBusy: Bool { phase == .running || phase == .stalled }

    @ObservationIgnored var interval: Duration = .seconds(2)
    @ObservationIgnored var patience: Duration = .seconds(90)
    @ObservationIgnored var onFinish: ((Bool) -> Void)?
    /// [update-flow] Every poll: the answer, or nil when the read got none (the gateway restarting). Called before the
    /// phase changes for that answer.
    @ObservationIgnored var onRead: ((GatewayActionStatus?) -> Void)?
    /// [update-flow] The status route answered 404 (`untracked`): its end can't be followed.
    @ObservationIgnored var onUntracked: (() -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let status: @Sendable (String) async throws -> GatewayActionStatus

    init(status: @escaping @Sendable (String) async throws -> GatewayActionStatus) { self.status = status }

    convenience init(api: GatewayActionsAPI) { self.init(status: { try await api.status($0) }) }

    /// Starts the action with `begin` (the POST) and polls it to its end. Nothing while one is already running.
    func start(_ begin: @escaping @Sendable () async throws -> String) {
        guard !isBusy else { return }
        phase = .running
        lines = []
        task = Task { [weak self] in
            let name: String
            do { name = try await begin() } catch {
                guard !Task.isCancelled else { return }
                let reason = PagesREST.reason(error)
                AppLog.note("config", "gateway action failed to start: \(reason)")
                self?.phase = .failed(reason)
                self?.onFinish?(false)
                return
            }
            await self?.poll(name)
        }
    }

    private func poll(_ name: String) async {
        let clock = ContinuousClock()
        let started = clock.now
        var sawRunning = false
        while !Task.isCancelled {
            try? await Task.sleep(for: phase == .stalled ? interval * 2.5 : interval)
            guard !Task.isCancelled else { return }
            let read: GatewayActionStatus?
            do { read = try await status(name) } catch {
                // Polled quietly into "Still restarting" before; a 404 never turns into an answer.
                if PagesREST.status(error) == 404 {
                    AppLog.note("config", "gateway action \(name): status not found (404), not followed")
                    phase = .untracked
                    onUntracked?()
                    return
                }
                read = nil
            }
            onRead?(read)
            if let answer = read {
                if !answer.lines.isEmpty { lines = answer.lines }
                if answer.running { sawRunning = true }
                // An answer with no exit code and not running, before the action was ever seen running, is the action
                // not registered yet (or the status of an older run): keep reading.
                if !answer.running, answer.exitCode != nil || sawRunning {
                    let ok = (answer.exitCode ?? 0) == 0
                    AppLog.trace("config", "gateway action \(name) finished in \(AppLog.ms(since: started)) ms, ok \(ok), exit \(answer.exitCode.map(String.init) ?? "?")")
                    phase = .finished(ok: ok, lastLine: answer.lastLine)
                    onFinish?(ok)
                    return
                }
            }
            if phase == .running, clock.now - started > patience {
                AppLog.trace("config", "gateway action \(name) stalled after \(AppLog.ms(since: started)) ms")
                phase = .stalled
            }
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        phase = .idle
        lines = []
    }

    isolated deinit { task?.cancel() }
}
