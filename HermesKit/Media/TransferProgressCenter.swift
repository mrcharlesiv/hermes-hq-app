// Upload and download progress straight to the views that show it (docs/spec/1x-attachments.md §7.8): keyed by a draft
// attachment's id or a download key, observed by the visible tile or row. Progress never rebuilds rows or touches the
// table (spec §15.3: 0 `performBatchUpdates` while only progress changes).

import Foundation
import Synchronization

@MainActor final class TransferProgressCenter {
    static let shared = TransferProgressCenter()

    /// An observation; ends when released or `cancel()`ed.
    final class Token {
        fileprivate let key: String
        fileprivate let id: UUID
        fileprivate weak var center: TransferProgressCenter?
        fileprivate init(key: String, id: UUID, center: TransferProgressCenter) { self.key = key; self.id = id; self.center = center }
        func cancel() { center?.remove(key: key, id: id); center = nil }
        isolated deinit { center?.remove(key: key, id: id) }
    }

    /// 0…1, or nil when the transfer isn't running.
    private var values: [String: Double] = [:]
    private var observers: [String: [UUID: (Double?) -> Void]] = [:]

    func fraction(_ key: String) -> Double? { values[key] }

    /// Calls `handler` with the current value now and on every change.
    func observe(_ key: String, _ handler: @escaping (Double?) -> Void) -> Token {
        let id = UUID()
        observers[key, default: [:]][id] = handler
        handler(values[key])
        return Token(key: key, id: id, center: self)
    }

    func set(_ key: String, _ fraction: Double?) {
        let clamped = fraction.map { min(1, max(0, $0)) }
        if values[key] == clamped { return }
        values[key] = clamped
        if clamped == nil { values.removeValue(forKey: key) }
        for handler in observers[key]?.values.map({ $0 }) ?? [] { handler(clamped) }
    }

    /// From any thread (a URLSession delegate queue): hops to the main actor, at most once per whole percent.
    nonisolated static func report(_ key: String, sent: Int64, total: Int64) {
        guard total > 0 else { return }
        let percent = Int((Double(sent) / Double(total) * 100).rounded(.down))
        let changed = lastReported.withLock { last -> Bool in
            if last[key] == percent { return false }
            last[key] = percent
            return true
        }
        guard changed else { return }
        Task { @MainActor in shared.set(key, Double(percent) / 100) }
    }

    /// Ends a transfer's progress (any thread).
    nonisolated static func finish(_ key: String) {
        _ = lastReported.withLock { $0.removeValue(forKey: key) }
        Task { @MainActor in shared.set(key, nil) }
    }

    private nonisolated static let lastReported = Mutex<[String: Int]>([:])

    private func remove(key: String, id: UUID) {
        observers[key]?[id] = nil
        if observers[key]?.isEmpty == true { observers[key] = nil }
    }
}
