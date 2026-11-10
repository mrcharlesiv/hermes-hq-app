// [offline] Polls that run only because something is on screen wait longer while the phone saves power, and never run
// faster than every 5 s (docs/spec/3x-offline.md §6.9): a port of the web app's `src/power-state.ts` (`SAVER_FACTOR`,
// `saverInterval`, `powerInterval`) and `src/visible-poll.ts` (`PHONE_POLL_FLOOR_MS`). A poll that follows an action
// the user just started is exempt: it keeps its own timing.

import Foundation
import UIKit   // [diagnostics] only for the became-active notification's name

/// Low Power Mode or a hot phone (thermal state serious or critical).
@MainActor final class PowerState {
    static let shared = PowerState(observing: true)
    static let changed = Notification.Name("hqn.power.changed")

    /// Tests and the DEBUG launch argument `-HQDebugPowerSaving YES|NO` set this; nil reads the phone.
    var override: Bool? { didSet { if oldValue != override { publish() } } }
    private(set) var saving = false
    private var observers: [NSObjectProtocol] = []

    /// `shared` follows the phone. Any other instance is a test's own: it changes only through `override`, so a test
    /// never slows a poll some other test is timing.
    init(observing: Bool = false) {
        guard observing else { return }
        saving = Self.read()
        // Both are posted off the main thread: hop before touching anything. [diagnostics] §11.1: and on becoming
        // active, as the web shell does: iOS does not always post the power notification to an app that was suspended
        // when Low Power Mode changed (it turns itself off at 80 % charge). A re-read that changed nothing is dropped.
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification,
                     UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                Task { @MainActor in PowerState.shared.publish() }
            })
        }
    }

    nonisolated static func read() -> Bool {
        let info = ProcessInfo.processInfo
        return saving(lowPower: info.isLowPowerModeEnabled, thermal: info.thermalState)
    }

    /// [diagnostics] The rule itself: Low Power Mode, or a phone that is hot (serious or critical).
    nonisolated static func saving(lowPower: Bool, thermal: ProcessInfo.ThermalState) -> Bool {
        lowPower || thermal == .serious || thermal == .critical
    }

    /// [diagnostics] What the `power` log event carries: both readings, in the web shell's words.
    nonisolated struct PowerDetail: Sendable, Equatable {
        var lowPower: Bool
        var thermal: String   // nominal | fair | serious | critical
    }

    nonisolated static func detail() -> PowerDetail {
        let info = ProcessInfo.processInfo
        return PowerDetail(lowPower: info.isLowPowerModeEnabled, thermal: thermalWord(info.thermalState))
    }

    nonisolated static func thermalWord(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "nominal"
        }
    }

    /// [settings] DEBUG runs flip the state while the app is up (`notifyutil -p hqn.power.toggle`, OfflineDebug).
    func toggleOverride() { override = !saving }

    private func publish() {
        let now = override ?? (observers.isEmpty ? false : Self.read())
        guard now != saving else { return }
        saving = now
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}

nonisolated enum PowerPolls {
    /// How much longer an optional poll waits while saving power.
    static let saverFactor = 3
    /// No visible poll runs faster than this on the phone.
    static let floor: Duration = .seconds(5)

    /// `max(floor, base)`, three times that while saving power, never past `cap`.
    static func period(_ base: Duration, floor: Duration = PowerPolls.floor, cap: Duration? = nil, saving: Bool) -> Duration {
        let floored = max(floor, base)
        guard saving else { return floored }
        let stretched = floored * saverFactor
        return cap.map { max(floored, min($0, stretched)) } ?? stretched
    }

    /// The pure schedule behind `loop`: when the next run is due, and whether a power change makes it due now.
    struct Schedule: Sendable, Equatable {
        var base: Duration
        var floor: Duration
        var cap: Duration?
        /// Seconds on a steady clock.
        var lastRun: TimeInterval

        func period(saving: Bool) -> Duration { PowerPolls.period(base, floor: floor, cap: cap, saving: saving) }

        /// Seconds until the next run; 0 when the schedule left it overdue (leaving saver on a slow schedule).
        func wait(now: TimeInterval, saving: Bool) -> TimeInterval {
            let period = period(saving: saving)
            let seconds = Double(period.components.seconds) + Double(period.components.attoseconds) / 1e18
            return max(0, lastRun + seconds - now)
        }
    }

    /// Runs `work` every period while the returned task lives: sleeps one period, runs, repeats. A power change
    /// re-arms it with the new period, and leaving saver runs at once when the slower schedule left it overdue.
    @MainActor static func loop(every base: Duration, floor: Duration = PowerPolls.floor, cap: Duration? = nil,
                                power: PowerState = .shared, _ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            var schedule = Schedule(base: base, floor: floor, cap: cap, lastRun: ProcessInfo.processInfo.systemUptime)
            while !Task.isCancelled {
                let wait = schedule.wait(now: ProcessInfo.processInfo.systemUptime, saving: power.saving)
                if wait > 0 {
                    // Sleep the wait, or until the power state changes (then the wait is worked out again).
                    let changed = await Self.sleep(seconds: wait, power: power)
                    if Task.isCancelled { return }
                    if changed { continue }
                }
                schedule.lastRun = ProcessInfo.processInfo.systemUptime
                await work()
            }
        }
    }

    /// One period of a poll that exists because something is on screen, for loops that keep their own shape: sleeps
    /// `period(base)`, and a power change re-arms the wait from when it began (entering saver stretches it; leaving
    /// saver with the poll overdue returns at once). Returns early when the task is cancelled.
    @MainActor static func wait(_ base: Duration, floor: Duration = PowerPolls.floor, cap: Duration? = nil,
                                power: PowerState = .shared) async {
        let schedule = Schedule(base: base, floor: floor, cap: cap, lastRun: ProcessInfo.processInfo.systemUptime)
        while !Task.isCancelled {
            let wait = schedule.wait(now: ProcessInfo.processInfo.systemUptime, saving: power.saving)
            if wait <= 0 { return }
            if await !Self.sleep(seconds: wait, power: power) { return }
        }
    }

    /// Sleeps `seconds`; returns true when a power change cut it short.
    @MainActor private static func sleep(seconds: TimeInterval, power: PowerState) async -> Bool {
        let woke = PowerWake()
        let observer = NotificationCenter.default.addObserver(forName: PowerState.changed, object: power, queue: .main) { _ in
            MainActor.assumeIsolated { woke.fire() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let sleeper = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            woke.finish()
        }
        defer { sleeper.cancel() }
        return await withTaskCancellationHandler {
            await woke.wait()
        } onCancel: {
            Task { @MainActor in woke.finish() }
        }
    }
}

/// One wake-up: a power change (`fire`) or the end of the sleep (`finish`), whichever comes first.
@MainActor private final class PowerWake {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func wait() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }
    func fire() { settle(true) }
    func finish() { settle(false) }
    private func settle(_ value: Bool) {
        guard result == nil else { return }
        result = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}
