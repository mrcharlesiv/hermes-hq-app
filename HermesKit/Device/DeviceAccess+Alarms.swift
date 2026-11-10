// [device-access] Alarms & Timers for Device Access (docs/device-access.md), the parts that don't touch AlarmKit:
// parsing a time ("07:30") or a seconds count, "mon"…"sun" tokens, the next moment an alarm goes off, formatting the
// answers, and a small record of what Hermes HQ itself set. AlarmKit doesn't hand back a label, or which alarms were
// timers, so App/DeviceAccess/AlarmsAccess.swift keeps this record in UserDefaults and prunes it against AlarmKit's
// own list; everything here is pure Foundation, so it's tested without AlarmKit.

import Foundation

nonisolated extension DeviceAccess {
    /// "07:30" (24-hour) parsed to hour and minute, or nil.
    static func alarmTime(_ text: String) -> (hour: Int, minute: Int)? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    static func alarmTimeString(hour: Int, minute: Int) -> String { String(format: "%02d:%02d", hour, minute) }

    private static let weekdayTokens: [(token: String, day: Locale.Weekday, names: Set<String>)] = [
        ("mon", .monday, ["mon", "monday"]), ("tue", .tuesday, ["tue", "tues", "tuesday"]),
        ("wed", .wednesday, ["wed", "weds", "wednesday"]), ("thu", .thursday, ["thu", "thur", "thurs", "thursday"]),
        ("fri", .friday, ["fri", "friday"]), ("sat", .saturday, ["sat", "saturday"]), ("sun", .sunday, ["sun", "sunday"]),
    ]

    /// "mon"…"sun", case-insensitive, to the weekday AlarmKit and `Calendar` share. The day's whole name and the usual
    /// short forms ("tues", "thurs") count too. Audit 09-28: a word only starting like a day isn't one ("monthly" was
    /// Monday).
    static func alarmWeekday(_ token: String) -> Locale.Weekday? {
        let lowered = token.trimmingCharacters(in: .whitespaces).lowercased()
        return weekdayTokens.first { $0.names.contains(lowered) }?.day
    }

    /// The days one `repeat` word names, as "mon"…"sun": a day, or "daily" / "everyday", "weekdays", "weekends".
    /// nil: not a day.
    static func alarmRepeatTokens(_ word: String) -> [String]? {
        let lowered = word.trimmingCharacters(in: .whitespaces).lowercased()
        switch lowered {
        case "daily", "everyday", "every day": return weekdayTokens.map(\.token)
        case "weekdays", "weekday": return ["mon", "tue", "wed", "thu", "fri"]
        case "weekends", "weekend": return ["sat", "sun"]
        default: return weekdayTokens.first { $0.names.contains(lowered) }.map { [$0.token] }
        }
    }

    /// `Calendar`'s 1-for-Sunday weekday number, as `Locale.Weekday`.
    static func alarmWeekday(calendarComponent n: Int) -> Locale.Weekday {
        [Locale.Weekday.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday][(n - 1 + 7) % 7]
    }

    /// `alarms.set`'s plan; nil when `time` is missing or not like "07:30". `rawRepeat` is the days the bot sent, as
    /// "mon"…"sun" in the week's order, for the record and the answer's `repeat`; `unknownRepeat` the words that
    /// weren't days (the handler turns the request down rather than set a one-off alarm in their place).
    struct AlarmSetPlan: Equatable, Sendable {
        var hour: Int
        var minute: Int
        var label: String?
        var rawRepeat: [String]
        var repeatDays: Set<Locale.Weekday>
        var unknownRepeat: [String] = []
    }

    static func alarmSetPlan(_ request: Request) -> AlarmSetPlan? {
        guard let text = request.string("time", max: 10), let time = alarmTime(text) else { return nil }
        var named = Set<String>(), unknown: [String] = []
        for word in request.strings("repeat") {
            if let tokens = alarmRepeatTokens(word) { named.formUnion(tokens) } else { unknown.append(String(word.prefix(20))) }
        }
        let raw = weekdayTokens.map(\.token).filter(named.contains)
        return AlarmSetPlan(hour: time.hour, minute: time.minute, label: request.string("label", max: 60),
                             rawRepeat: raw, repeatDays: Set(raw.compactMap(alarmWeekday)), unknownRepeat: unknown)
    }

    /// `alarms.timer`'s plan; nil when `seconds` is missing or out of range (1 to 86400).
    struct AlarmTimerPlan: Equatable, Sendable {
        var seconds: Int
        var label: String?
    }

    static func alarmTimerPlan(_ request: Request) -> AlarmTimerPlan? {
        guard let seconds = request.int("seconds"), (1...86400).contains(seconds) else { return nil }
        return AlarmTimerPlan(seconds: seconds, label: request.string("label", max: 60))
    }

    /// The next moment an alarm at `hour:minute` goes off from `now`: today or tomorrow once, or the next matching
    /// day within the next two weeks when it repeats.
    static func nextAlarmFire(hour: Int, minute: Int, days: Set<Locale.Weekday>, now: Date = .now, calendar: Calendar = .current) -> Date? {
        guard let at = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
        if days.isEmpty { return at > now ? at : calendar.date(byAdding: .day, value: 1, to: at) }
        for offset in 0..<14 {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: at), candidate > now else { continue }
            if days.contains(alarmWeekday(calendarComponent: calendar.component(.weekday, from: candidate))) { return candidate }
        }
        return nil
    }

    // MARK: Wire shapes

    static func alarmSetWire(id: String, hour: Int, minute: Int, label: String?, rawRepeat: [String], next: Date) -> [String: JSONValue] {
        ["alarm": ["id": .string(id), "time": .string(alarmTimeString(hour: hour, minute: minute)), "label": .string(label ?? ""),
                   "repeat": .array(rawRepeat.map { JSONValue.string($0) }), "next": .string(DeviceAccess.stamp(next))]]
    }

    static func alarmTimerWire(id: String, label: String?, ends: Date) -> [String: JSONValue] {
        ["timer": ["id": .string(id), "label": .string(label ?? ""), "ends": .string(DeviceAccess.stamp(ends))]]
    }

    /// One entry of `alarms.list`.
    static func alarmListItemWire(id: String, kind: String, time: String?, ends: Date?, label: String, rawRepeat: [String], state: String) -> JSONValue {
        var out: [String: JSONValue] = ["id": .string(id), "kind": .string(kind), "label": .string(label), "state": .string(state)]
        if let time { out["time"] = .string(time) }
        if let ends { out["ends"] = .string(DeviceAccess.stamp(ends)) }
        if !rawRepeat.isEmpty { out["repeat"] = .array(rawRepeat.map { JSONValue.string($0) }) }
        return .object(out)
    }

    // MARK: Hermes HQ's own record

    /// One alarm or timer Hermes HQ set: AlarmKit doesn't hand back a label or which were a timer, so this is kept
    /// only so `alarms.list` can say them. Pruned against AlarmKit's own list each time it's read.
    struct AlarmRecord: Codable, Equatable, Sendable {
        var kind: String   // "alarm" or "timer"
        var label: String
        var time: String?  // alarms: "07:30"
        var ends: Date?    // timers: the moment it goes off
        var rawRepeat: [String]
    }

    enum AlarmStore {
        static let key = "hq.deviceAccess.alarms"

        static func load(_ defaults: UserDefaults = .standard) -> [String: AlarmRecord] {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: AlarmRecord].self, from: $0) } ?? [:]
        }

        static func remember(_ id: String, _ record: AlarmRecord, _ defaults: UserDefaults = .standard) {
            var all = load(defaults)
            all[id] = record
            defaults.set(try? JSONEncoder().encode(all), forKey: key)
        }

        static func forget(_ id: String, _ defaults: UserDefaults = .standard) {
            var all = load(defaults)
            all[id] = nil
            defaults.set(try? JSONEncoder().encode(all), forKey: key)
        }

        /// Drops anything AlarmKit no longer has, and returns what's left.
        @discardableResult
        static func prune(keeping ids: Set<String>, _ defaults: UserDefaults = .standard) -> [String: AlarmRecord] {
            let kept = load(defaults).filter { ids.contains($0.key) }
            defaults.set(try? JSONEncoder().encode(kept), forKey: key)
            return kept
        }
    }
}
