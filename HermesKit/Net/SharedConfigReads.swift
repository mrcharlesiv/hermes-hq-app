// [load-cache] `GET /api/config` shared by the app's readers that only read it (display flags, the approval timeout,
// Reopen Last Chat, launch prefs, voice settings, memo transcription). Hermes reads the whole config under one lock,
// and right after a launch up to five of these were out at once for the same 36 KB answer (5-6 s each on the owner's
// phone, 2026-10-31). Here a read joins one in flight for the same query, and an answer under `maxAge` old is reused.
// Any write through the client (a REST call that isn't a read, or a `config.*` RPC) drops what is kept and lets the
// next reader start afresh, before the write is sent and again once it is answered. Settings pages and the connector
// editor read past this (GatewaySettingsAPI.config, CapabilitiesStore.mcpEntry): they edit what they read.

import Foundation
import Synchronization

nonisolated final class SharedConfigReads: Sendable {
    /// How long an answer stands in for a new read when the reader doesn't say.
    static let defaultMaxAge: TimeInterval = 10

    private struct Flight {
        var id: UInt64
        var task: Task<Data, any Error>
    }

    private struct Kept {
        var data: Data
        var at: ContinuousClock.Instant
    }

    private struct State {
        var flights: [String: Flight] = [:]
        var kept: [String: Kept] = [:]
        var nextId: UInt64 = 0
        /// Reads started (the tests count them).
        var started = 0
    }

    private enum Plan {
        case hit(Data)
        case wait(Task<Data, any Error>)
    }

    private let state = Mutex(State())

    init() {}

    /// The key for a query: its items in order ("" for none).
    static func key(_ query: [URLQueryItem]) -> String {
        query.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
    }

    var readsStarted: Int { state.withLock { $0.started } }

    /// The config for `query`: kept (under `maxAge` seconds old), the read in flight, or a new read through `read`.
    /// `maxAge` 0: only a read in flight is shared. A failed read is never kept.
    func data(_ query: [URLQueryItem], maxAge: TimeInterval = defaultMaxAge,
              read: @escaping @Sendable () async throws -> Data) async throws -> Data {
        let key = Self.key(query)
        let now = ContinuousClock.now
        let plan: Plan = state.withLock { s in
            if maxAge > 0, let kept = s.kept[key], now - kept.at <= .seconds(maxAge) { return .hit(kept.data) }
            if let flight = s.flights[key] { return .wait(flight.task) }
            s.nextId += 1
            s.started += 1
            let id = s.nextId
            // Created under the lock: its own bookkeeping (`finish`) waits for the lock, so it always finds its flight.
            let task = Task<Data, any Error> { [self] in
                do {
                    let data = try await read()
                    finish(key, id, data)
                    return data
                } catch {
                    finish(key, id, nil)
                    throw error
                }
            }
            s.flights[key] = Flight(id: id, task: task)
            return .wait(task)
        }
        switch plan {
        case .hit(let data): return data
        case .wait(let task): return try await task.value
        }
    }

    private func finish(_ key: String, _ id: UInt64, _ data: Data?) {
        state.withLock { s in
            // A read that `invalidate` let go no longer speaks for the key: it neither clears nor fills it.
            guard s.flights[key]?.id == id else { return }
            s.flights[key] = nil
            if let data { s.kept[key] = Kept(data: data, at: .now) }
        }
    }

    /// A write: nothing kept is reused, and reads in flight finish for their own callers only.
    func invalidate() {
        state.withLock { s in
            s.kept = [:]
            s.flights = [:]
        }
    }

    /// Whether this RPC may change the config (it drops what is kept).
    static func writes(rpc method: String) -> Bool { method.hasPrefix("config.") }
}
