// [device-access] Health's own rules for Device Access (docs/device-access.md), kept pure Foundation so they're
// unit-testable without HealthKit: a summary's date range, which types it covers, how each type's numbers are written
// for the bot, how a too-large answer is cut down, and grouping raw sleep samples into nights.
// App/DeviceAccess/HealthLookup.swift does the actual HealthKit queries and calls into these.
//
// [health-all-types] Two answers. An add-on from 0.9.46 on asks with `format: "types"` and gets `types`, one entry per
// Health type (HealthCatalog), keyed by its HealthKit identifier. An older add-on knows only the four old switches and
// gets the four old sections (steps, sleep, workouts, heart), read from whichever of their types are on.

import Foundation

nonisolated extension DeviceAccess {
    /// The four old sections (an add-on before 0.9.46 asks for these by name).
    static let healthMetricKeys: Set<String> = Set(HealthCatalog.legacyKeys)
    /// At most this many types named in one request.
    static let healthMaxAsked = 250
    /// An answer is cut down to about this many bytes of JSON (the add-on takes 64 KB at most).
    static let healthResultLimit = 48_000
    /// At most this many workouts, and this many samples read per type.
    static let healthMaxWorkouts = 100
    static let healthMaxSamples = 5_000

    /// `health.summary`'s range: `start` defaults to today's start, `end` to now, `end` clamped to 31 days after `start`
    /// (and never before it).
    static func healthRange(_ request: Request, now: Date = .now, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let start = request.date("start") ?? calendar.startOfDay(for: now)
        var end = request.date("end") ?? now
        if let ceiling = calendar.date(byAdding: .day, value: 31, to: start), end > ceiling { end = ceiling }
        if end < start { end = start }
        return (start, end)
    }

    /// What one summary covers.
    struct HealthPlan: Equatable, Sendable {
        /// An older add-on's request: the old sections to answer, in their order. nil for a `types` request.
        var legacy: [String]? = nil
        /// A `types` request: the types to read, all switched on, in the page's order.
        var types: [String] = []
        /// Asked for, but switched off here.
        var off: [String] = []
        /// Asked for, but not a Health type or group this phone knows.
        var unknown: [String] = []
    }

    /// The plan for a request, kept to the switches that are on (`shared`: the Health types on).
    /// An older add-on's request (no `format: "types"`): the old sections asked for that have a type on; nothing asked
    /// (or none of what was asked is on), every old section that has one (the same fallback as `contactsPlan`).
    /// A `types` request: the types named in `metrics` (an old key stands for its types) and those of the groups in
    /// `categories`, the ones switched off said as `off`; nothing named, every type that is on.
    static func healthPlan(_ request: Request, shared: Set<String>) -> HealthPlan {
        let on = shared.intersection(healthScopeKeys)
        guard request.string("format", max: 20) == "types" else {
            let onLegacy = HealthCatalog.legacyOn(on)
            let asked = Set(request.strings("metrics")).intersection(healthMetricKeys)
            let kept = asked.intersection(onLegacy)
            let chosen = kept.isEmpty ? onLegacy : kept
            return HealthPlan(legacy: HealthCatalog.legacyKeys.filter(chosen.contains))
        }
        var asked: [String] = [], unknown: [String] = []
        for name in request.strings("categories") {
            if let category = HealthCatalog.Category(rawValue: name) {
                asked += healthScopes.filter { HealthCatalog.byKey[$0.key]?.category == category }.map(\.key)
            } else {
                unknown.append(name)
            }
        }
        for key in request.strings("metrics", max: healthMaxAsked) {
            if healthMetricKeys.contains(key) {
                asked += HealthCatalog.legacyTypes(key)
            } else if healthScopeKeys.contains(key) {
                asked.append(key)
            } else {
                unknown.append(key)
            }
        }
        func ordered(_ keys: some Sequence<String>) -> [String] {
            Set(keys).sorted { healthScopeOrder[$0, default: 0] < healthScopeOrder[$1, default: 0] }
        }
        if asked.isEmpty && unknown.isEmpty { return HealthPlan(types: ordered(on)) }
        var seen = Set<String>()
        return HealthPlan(types: ordered(asked.filter(on.contains)), off: ordered(asked.filter { !on.contains($0) }),
                          unknown: Array(unknown.filter { seen.insert($0).inserted }.prefix(20)))
    }

    static let healthScopeOrder: [String: Int] = Dictionary(uniqueKeysWithValues: healthScopes.enumerated().map { ($1.key, $0) })

    // MARK: One type's summary

    /// One day of a quantity type (or the whole range): its total (added-up types) or its average, lowest and highest
    /// (measured ones).
    struct HealthDay: Equatable, Sendable {
        var day: String
        var sum: Double? = nil
        var average: Double? = nil
        var minimum: Double? = nil
        var maximum: Double? = nil
    }

    /// A value as the bot reads it: a percentage as 0–100 (HealthKit's is 0–1), rounded to two places.
    static func healthNumber(_ value: Double, unit: String?) -> JSONValue {
        .number(round2(unit == "%" ? value * 100 : value))
    }

    /// The part every type's entry has: {name, category, kind, unit?}.
    static func healthEntry(_ item: HealthCatalog.Item) -> [String: JSONValue] {
        var out: [String: JSONValue] = ["name": .string(item.name), "category": .string(item.category.rawValue),
                                        "kind": .string(item.shape.rawValue)]
        if let unit = item.unit { out["unit"] = .string(unit) }
        return out
    }

    /// A quantity type's entry, or nil when it has nothing in the range. Added up: `total`, and `by_day` {day: total}.
    /// Measured: `average`, `min`, `max` over the range (`overall`), `latest` {value, at}, and `by_day` {day: {average,
    /// min, max}}. `by_day` only for a range of more than a day.
    static func healthQuantity(_ item: HealthCatalog.Item, days: [HealthDay], overall: HealthDay? = nil,
                               latest: (value: Double, at: Date)? = nil, multiDay: Bool, zone: TimeZone = .current) -> JSONValue? {
        var out = healthEntry(item)
        let unit = item.unit
        func measures(_ day: HealthDay) -> [String: JSONValue] {
            var one: [String: JSONValue] = [:]
            if let average = day.average { one["average"] = healthNumber(average, unit: unit) }
            if let minimum = day.minimum { one["min"] = healthNumber(minimum, unit: unit) }
            if let maximum = day.maximum { one["max"] = healthNumber(maximum, unit: unit) }
            return one
        }
        if item.shape == .cumulative {
            let kept = days.filter { ($0.sum ?? 0) != 0 }
            guard !kept.isEmpty else { return nil }
            out["total"] = healthNumber(kept.reduce(0) { $0 + ($1.sum ?? 0) }, unit: unit)
            if multiDay { out["by_day"] = .object(Dictionary(kept.map { ($0.day, healthNumber($0.sum ?? 0, unit: unit)) }) { a, _ in a }) }
            return .object(out)
        }
        let kept = days.filter { !measures($0).isEmpty }
        let whole = overall.map(measures) ?? [:]
        guard !kept.isEmpty || !whole.isEmpty || latest != nil else { return nil }
        out.merge(whole) { a, _ in a }
        if let latest { out["latest"] = ["value": healthNumber(latest.value, unit: unit), "at": .string(stamp(latest.at, zone: zone))] }
        if multiDay, !kept.isEmpty {
            out["by_day"] = .object(Dictionary(kept.map { ($0.day, JSONValue.object(measures($0))) }) { a, _ in a })
        }
        return .object(out)
    }

    /// One logged category sample (a symptom, a stand hour, a mindful session).
    struct HealthEvent: Equatable, Sendable {
        var start: Date
        var end: Date
        var value: Int
    }

    /// A category type's entry, or nil when nothing was logged: `count`, `minutes` (when the samples last),
    /// `values` {name: count} (for a type with named values), `latest` (the last one's start), and `by_day` {day: count}
    /// for a range of more than a day; `more` when there were more samples than were read.
    static func healthCategory(_ item: HealthCatalog.Item, events: [HealthEvent], multiDay: Bool, more: Bool = false,
                               zone: TimeZone = .current) -> JSONValue? {
        guard !events.isEmpty else { return nil }
        var out = healthEntry(item)
        out["count"] = .number(Double(events.count))
        let minutes = events.reduce(0) { $0 + max(0, $1.end.timeIntervalSince($1.start)) } / 60
        if minutes > 0 { out["minutes"] = .number(round2(minutes)) }
        if let values = item.values {
            var counts: [String: Double] = [:]
            for event in events { counts[values.name(event.value), default: 0] += 1 }
            out["values"] = .object(counts.mapValues(JSONValue.number))
        }
        if let last = events.max(by: { $0.start < $1.start }) { out["latest"] = .string(stamp(last.start, zone: zone)) }
        if multiDay {
            var byDay: [String: Double] = [:]
            for event in events { byDay[day(event.start, zone: zone), default: 0] += 1 }
            out["by_day"] = .object(byDay.mapValues(JSONValue.number))
        }
        if more { out["more"] = true }
        return .object(out)
    }

    // MARK: Keeping the answer small

    /// The entries cut to about `limit` bytes: first entries' `by_day` go (the largest entry first), then whole entries
    /// from the end of the page's order. Returns what's left, whether anything was cut, and the keys left out.
    static func healthTrimmed(_ entries: [(key: String, value: JSONValue)], limit: Int = healthResultLimit)
        -> (types: [String: JSONValue], trimmed: Bool, leftOut: [String]) {
        func size(_ index: Int, _ value: JSONValue) -> Int { ((try? value.encoded().count) ?? 0) + entries[index].key.utf8.count + 4 }
        var values = entries.map(\.value)
        var sizes = values.indices.map { size($0, values[$0]) }
        var total = sizes.reduce(0, +)
        var trimmed = false
        for index in sizes.indices.sorted(by: { sizes[$0] > sizes[$1] }) where total > limit {
            guard var object = values[index].object, object["by_day"] != nil else { continue }
            object["by_day"] = nil
            values[index] = .object(object)
            let next = size(index, values[index])
            total -= sizes[index] - next
            sizes[index] = next
            trimmed = true
        }
        var keep = entries.count
        while total > limit, keep > 0 {
            keep -= 1
            total -= sizes[keep]
            trimmed = true
        }
        let kept = Dictionary((0..<keep).map { (entries[$0].key, values[$0]) }) { a, _ in a }
        return (kept, trimmed, entries[keep...].map(\.key))
    }

    /// What the bot hears when an answer was cut down.
    static let healthTrimmedWords = "Too much to send at once, so some days or types were left out. Ask for fewer types or a shorter range."

    // MARK: Sleep

    /// One raw sleep sample. Core, deep and REM (Apple Watch's stages) and plain asleep count as asleep; in bed toward
    /// in bed only; awake toward neither (it shows in the night's stages).
    struct SleepSample: Equatable, Sendable {
        enum Stage: String, Sendable { case inBed, asleep, core, deep, rem, awake }
        var start: Date
        var end: Date
        var stage: Stage

        init(start: Date, end: Date, stage: Stage) {
            self.start = start
            self.end = end
            self.stage = stage
        }

        init(start: Date, end: Date, asleep: Bool) {
            self.init(start: start, end: end, stage: asleep ? .asleep : .inBed)
        }

        var asleep: Bool { [.asleep, .core, .deep, .rem].contains(stage) }

        /// HealthKit's HKCategoryValueSleepAnalysis raw value as a stage.
        static func stage(_ raw: Int) -> Stage? {
            switch raw {
            case 0: .inBed
            case 1: .asleep
            case 2: .awake
            case 3: .core
            case 4: .deep
            case 5: .rem
            default: nil
            }
        }
    }

    struct SleepNight: Equatable, Sendable {
        var night: String
        var asleepHours: Double
        var inBedHours: Double
        var start: Date
        var end: Date
        /// Hours in each stage the source recorded (core, deep, rem, awake); empty when it recorded none.
        var stages: [String: Double] = [:]

        var wire: JSONValue {
            var out: [String: JSONValue] = ["night": .string(night), "asleep_hours": .number(asleepHours),
                                            "in_bed_hours": .number(inBedHours),
                                            "start": .string(DeviceAccess.stamp(start)), "end": .string(DeviceAccess.stamp(end))]
            if !stages.isEmpty { out["stages_hours"] = .object(stages.mapValues(JSONValue.number)) }
            return .object(out)
        }
    }

    /// Which calendar day a sleep sample's night belongs to: one starting before 2pm is still last night's (so a
    /// 1am wake-up doesn't start a new, empty night).
    static func sleepNight(for start: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: start)
        return calendar.component(.hour, from: start) < 14 ? (calendar.date(byAdding: .day, value: -1, to: day) ?? day) : day
    }

    /// Samples grouped into nights, oldest first.
    static func sleepNights(_ samples: [SleepSample], calendar: Calendar = .current, zone: TimeZone = .current) -> [SleepNight] {
        struct Bucket { var asleep = 0.0; var inBed = 0.0; var stages: [String: Double] = [:]; var start: Date; var end: Date }
        var buckets: [Date: Bucket] = [:]
        for sample in samples where sample.end > sample.start {
            let key = sleepNight(for: sample.start, calendar: calendar)
            var bucket = buckets[key] ?? Bucket(start: sample.start, end: sample.end)
            let hours = sample.end.timeIntervalSince(sample.start) / 3600
            switch sample.stage {
            case .inBed: bucket.inBed += hours
            case .awake: bucket.stages["awake", default: 0] += hours
            case .asleep: bucket.asleep += hours
            case .core, .deep, .rem:
                bucket.asleep += hours
                bucket.stages[sample.stage.rawValue, default: 0] += hours
            }
            bucket.start = min(bucket.start, sample.start)
            bucket.end = max(bucket.end, sample.end)
            buckets[key] = bucket
        }
        return buckets.keys.sorted().map { key in
            let bucket = buckets[key]!
            return SleepNight(night: day(key, zone: zone), asleepHours: round2(bucket.asleep),
                              inBedHours: round2(max(bucket.inBed, bucket.asleep)), start: bucket.start, end: bucket.end,
                              stages: bucket.stages.mapValues(round2))
        }
    }

    static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}

// MARK: - The Health page

nonisolated extension DeviceAccess.Settings {
    /// [health-all-types] A Health group's switches, in the page's order (only the types this iOS has).
    static func healthKeys(_ category: HealthCatalog.Category) -> [String] {
        DeviceAccess.healthScopes.map(\.key).filter { HealthCatalog.byKey[$0]?.category == category }
    }

    /// A Health group's row: Off, On (every type), or how many of how many ("3 of 12").
    func healthSummary(_ category: HealthCatalog.Category) -> String {
        let keys = Self.healthKeys(category)
        let on = keys.filter { has(.health, $0) }.count
        if on == 0 { return "Off" }
        return on == keys.count ? "On" : "\(on) of \(keys.count)"
    }
}
