// [diagnostics] Per-build counts for Diagnostics › "Stability, this build" (the web shell's `DispatchFieldMetrics`
// counters): crashes iOS reported, crashes the app caught itself, long main-thread waits, CPU and disk-write reports.
// Kept in UserDefaults under one key; another build's counts read as none.

import Foundation

nonisolated enum StabilityCounts {
    static let key = "hqn.stability"

    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }

    private static let lock = NSLock()

    /// `<name>` counts and `<name>LastAt` epoch milliseconds of this build.
    static func values(defaults: UserDefaults = .standard, build: String = StabilityCounts.build) -> [String: Double] {
        guard let stored = defaults.dictionary(forKey: key), stored["build"] as? String == build else { return [:] }
        return stored.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    static func count(_ name: String, by amount: Int = 1, at date: Date = Date(), defaults: UserDefaults = .standard, build: String = StabilityCounts.build) {
        guard amount > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        var stored: [String: Any] = values(defaults: defaults, build: build)
        stored["build"] = build
        stored[name] = ((stored[name] as? Double) ?? 0) + Double(amount)
        stored["\(name)LastAt"] = (date.timeIntervalSince1970 * 1000).rounded()
        defaults.set(stored, forKey: key)
    }

    /// Keeps the largest value seen (the longest unresponsive stretch).
    static func raise(_ name: String, to value: Double, defaults: UserDefaults = .standard, build: String = StabilityCounts.build) {
        lock.lock(); defer { lock.unlock() }
        var stored: [String: Any] = values(defaults: defaults, build: build)
        guard value > ((stored[name] as? Double) ?? 0) else { return }
        stored["build"] = build
        stored[name] = value
        defaults.set(stored, forKey: key)
    }

    /// Crash records the app wrote itself (an exception, a fatal signal) that have not been counted yet, counted
    /// once each. Run at launch, after the last run's signal file has been sorted out. A crash in the last run of
    /// the build before an update is counted against the new build: the record does not say which build wrote it.
    static func countCaughtCrashes(_ records: [URL], defaults: UserDefaults = .standard, build: String = StabilityCounts.build) {
        let seenKey = "hqn.stability.countedRecords"
        let names = records.map(\.lastPathComponent).filter { ($0.hasPrefix("exception-") || $0.hasPrefix("signal-")) && !$0.hasSuffix("-pending.txt") }
        let seen = Set(defaults.stringArray(forKey: seenKey) ?? [])
        let fresh = names.filter { !seen.contains($0) }
        guard !fresh.isEmpty else { return }
        // The first launch of a build that counts them only notes what is already there.
        if defaults.object(forKey: seenKey) != nil { count("caughtCrashes", by: fresh.count, defaults: defaults, build: build) }
        defaults.set(Array(names.suffix(200)), forKey: seenKey)
    }
}
