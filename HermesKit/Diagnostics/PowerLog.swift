// [diagnostics] One `power` event in the performance log per real change (the web shell's `HermesPerfLog` power
// source, `ios/App/App/HermesPerfLog.swift:551-558`): Low Power Mode on or off, the thermal state by name, and whether
// the app is saving power because of them. A re-read that changed nothing records nothing. The app log gets one
// "saver on" / "saver off" line when saving flips.

import Foundation
import Synchronization

nonisolated final class PowerLog: Sendable {
    static let shared = PowerLog { detail, saving in
        LogUploader.shared.record("power", [("lowPower", detail.lowPower), ("thermal", detail.thermal), ("saver", saving)])
    }

    struct Reading: Sendable, Equatable {
        var detail: PowerState.PowerDetail
        var saving: Bool
    }

    private let last = Mutex<Reading?>(nil)
    private let record: @Sendable (PowerState.PowerDetail, Bool) -> Void
    private let count = Mutex(0)

    init(record: @escaping @Sendable (PowerState.PowerDetail, Bool) -> Void) { self.record = record }

    /// Events recorded so far (tests and the DEBUG probe).
    var events: Int { count.withLock { $0 } }

    /// Records the reading when it differs from the last one. Answers whether it did.
    @discardableResult
    func note(_ detail: PowerState.PowerDetail, saving: Bool) -> Bool {
        let reading = Reading(detail: detail, saving: saving)
        let previous: Reading?? = last.withLock { last in
            guard last != reading else { return nil }
            defer { last = reading }
            return .some(last)
        }
        guard let previous else { return false }
        count.withLock { $0 += 1 }
        record(detail, saving)
        if let before = previous, before.saving != saving { AppLog.note("power", saving ? "saver on" : "saver off") }
        else if previous == nil, saving { AppLog.note("power", "saver on") }
        return true
    }

    /// The launch's reading, then one observer of the system's two notifications and of the app's own power state
    /// (which also carries the DEBUG override). Nothing here touches the main thread except to read `saving`.
    @MainActor static func start() {
        guard !started else { return }
        started = true
        shared.note(PowerState.detail(), saving: PowerState.shared.saving)
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification, PowerState.changed] {
            center.addObserver(forName: name, object: nil, queue: nil) { _ in
                // `PowerState` republishes on the main actor; read it there, after it has.
                Task { @MainActor in shared.note(PowerState.detail(), saving: PowerState.shared.saving) }
            }
        }
    }

    @MainActor private static var started = false
}
