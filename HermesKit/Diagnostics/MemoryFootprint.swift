// [diagnostics] The process's physical footprint (what jetsam counts), in release builds too. 2026-10-24: a day's peak
// was 383 MB (2.5x the usual) and nothing on the phone said which screen or chat was up. Now `mem.trim`, `main.hang`,
// `frames.bad` and `mk.day` carry it (`fp` now, `fpk` this run's peak), each moment that ends samples it, and the
// day's highest sample with its screen is kept for that day's `mk.day` (`hi`, `hiOn`) and logged as `mem.high` when it
// passes 250 MB and every 50 MB after.

import Darwin
import Foundation
import Synchronization

nonisolated enum MemoryFootprint {
    struct Sample: Equatable, Sendable { var mb: Int; var peakMB: Int }

    static let highFloorMB = 250
    static let highStepMB = 50
    static let dayKey = "hq.diagnostics.memoryDayHigh"

    private struct State { var day = ""; var dayHighMB = 0; var dayHighScreen = ""; var nextHighMB = MemoryFootprint.highFloorMB }
    private static let state = Mutex(State())

    /// Now and this run's peak, from `task_vm_info` (nil if the kernel refuses).
    static func sample() -> Sample? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let mb = Int(info.phys_footprint >> 20)
        return Sample(mb: mb, peakMB: max(mb, Int(info.ledger_phys_footprint_peak >> 20)))
    }

    /// The fields an event carries: `fp` (MB now) and `fpk` (MB, this run's peak).
    static func fields(_ sample: Sample? = sample()) -> [(String, Any)] {
        guard let sample else { return [] }
        return [("fp", sample.mb), ("fpk", sample.peakMB)]
    }

    /// One sample as a moment ends (or an event is logged) on `screen`: keeps the day's high and its screen, and
    /// says `mem.high` past the floor and each step above it.
    static func observe(screen: String, now: Date = Date(), defaults: UserDefaults = .standard) {
        guard let sample = sample() else { return }
        let day = FieldHistory.day(now)
        let decision = state.withLock { s in note(&s, mb: sample.mb, screen: screen, day: day) }
        if decision.saveDay { saveDayHigh(day: day, mb: sample.mb, screen: screen, defaults: defaults) }
        if decision.high {
            LogUploader.shared.record("mem.high", [("scr", screen)] + fields(sample))
            AppLog.note("mem", "footprint \(sample.mb) MB on \(screen) (peak this run \(sample.peakMB) MB)")
        }
    }

    /// The rule, apart for tests: (save the day's high, log `mem.high`).
    private static func note(_ s: inout State, mb: Int, screen: String, day: String) -> (saveDay: Bool, high: Bool) {
        if s.day != day { s.day = day; s.dayHighMB = 0; s.nextHighMB = highFloorMB }
        var saveDay = false
        if mb >= s.dayHighMB + 5 || (mb > s.dayHighMB && screen != s.dayHighScreen) {
            s.dayHighMB = mb; s.dayHighScreen = screen; saveDay = true
        }
        guard mb >= s.nextHighMB else { return (saveDay, false) }
        s.nextHighMB = (mb / highStepMB + 1) * highStepMB
        return (saveDay, true)
    }

    #if DEBUG
    /// Tests: forget this run's marks.
    static func reset() { state.withLock { $0 = State() } }
    #endif

    static func highDecisions(_ samples: [(mb: Int, screen: String)], day: String = "2026-10-24") -> [(saveDay: Bool, high: Bool)] {
        var s = State()
        return samples.map { note(&s, mb: $0.mb, screen: $0.screen, day: day) }
    }

    private static func saveDayHigh(day: String, mb: Int, screen: String, defaults: UserDefaults) {
        var days = defaults.dictionary(forKey: dayKey) as? [String: String] ?? [:]
        if let old = days[day], let oldMB = Int(old.prefix { $0 != "|" }), oldMB >= mb { return }
        days[day] = "\(mb)|\(screen)"
        for key in days.keys.sorted().dropLast(7) { days[key] = nil }
        defaults.set(days, forKey: dayKey)
    }

    /// `mk.day`'s extra fields for `day`: the highest footprint the app sampled that day and where (`hi`, `hiOn`).
    static func dayHighFields(day: String, defaults: UserDefaults = .standard) -> [(String, Any)] {
        guard let saved = (defaults.dictionary(forKey: dayKey) as? [String: String])?[day] else { return [] }
        let parts = saved.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let mb = Int(parts[0]) else { return [] }
        return [("hi", mb), ("hiOn", parts.count > 1 ? parts[1] : "")]
    }
}
