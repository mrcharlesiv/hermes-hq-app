// [jobs] The job editor's schedule (docs/spec/3x-jobs.md §6.5, §6.7, §6.10): the seven frequency presets with the
// web's expressions, the preset an expression belongs to (`scheduleOptionForExpr`, vendor app/cron/index.tsx:183-236),
// the time fields a cron line pins down and the line they compose (`cronTimeFields` / `composeCron` /
// `cronForPreset`, src/audit-c-format.ts:243-277), and the summary sentence (`scheduleSummary`, index.tsx:238-268).
// The cron line stays the single source of truth: the fields are read from it and written back only on a change, so
// opening a job never rewrites its schedule.

import Foundation

nonisolated enum JobFrequency: String, CaseIterable, Sendable, Identifiable {
    case daily, weekdays, weekly, monthly, hourly
    case every15 = "every-15-minutes"
    case custom

    var id: String { rawValue }

    /// The picker's word (vendor i18n/en.ts `scheduleOptions`).
    var title: String {
        switch self {
        case .daily: "Daily"
        case .weekdays: "Weekdays"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .hourly: "Hourly"
        case .every15: "Every 15 minutes"
        case .custom: "Custom"
        }
    }

    /// The preset's own expression (`SCHEDULE_OPTIONS`, index.tsx:105-113); nil for Custom.
    var presetExpr: String? {
        switch self {
        case .daily: "0 9 * * *"
        case .weekdays: "0 9 * * 1-5"
        case .weekly: "0 9 * * 1"
        case .monthly: "0 9 1 * *"
        case .hourly: "0 * * * *"
        case .every15: "*/15 * * * *"
        case .custom: nil
        }
    }

    /// `TIMED_PRESETS`: the presets with time and day controls.
    var isTimed: Bool { self != .every15 && self != .custom }
}

/// The time and day a cron line pins down, over the web's defaults (9:00, Monday, the 1st).
nonisolated struct JobTimeFields: Equatable, Sendable {
    var hour = 9
    var minute = 0
    /// Weekly's days, 0 = Sunday … 6 = Saturday (cron order), sorted, never empty.
    var weekdays: [Int] = [1]
    var day = 1

    init(hour: Int = 9, minute: Int = 0, weekday: Int = 1, day: Int = 1) {
        self.hour = hour; self.minute = minute; weekdays = [weekday]; self.day = day
    }

    init(hour: Int = 9, minute: Int = 0, weekdays: [Int], day: Int = 1) {
        self.hour = hour; self.minute = minute; self.weekdays = Self.cleanDays(weekdays); self.day = day
    }

    /// The first of Weekly's days; setting it makes it the only one.
    var weekday: Int {
        get { weekdays.first ?? 1 }
        set { weekdays = [newValue] }
    }

    /// Sorted, 7 read as Sunday, no repeats; nothing left is Monday.
    static func cleanDays(_ days: [Int]) -> [Int] {
        let clean = Set(days.filter { (0...7).contains($0) }.map { $0 % 7 }).sorted()
        return clean.isEmpty ? [1] : clean
    }
}

nonisolated enum JobSchedule {
    static let clockNote = "Times follow the clock on \(HostWord.phrase)."
    static let customPlaceholder = "0 9 * * * or weekdays at 9am"
    static let customHint = "Cron expression, or phrases like \"every hour\" or \"weekdays at 9am\"."

    private static func normalized(_ expr: String) -> String {
        expr.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func parts(_ expr: String) -> [String]? {
        let pieces = expr.split(whereSeparator: \.isWhitespace).map(String.init)
        return pieces.count == 5 ? pieces : nil
    }

    private static func isInteger(_ token: String) -> Bool { !token.isEmpty && token.allSatisfy { $0.isASCII && $0.isNumber } }

    /// The preset an expression opens on; anything it cannot classify is Custom (never a preset that would simplify it).
    static func frequency(for expr: String) -> JobFrequency {
        let line = normalized(expr)
        if let exact = JobFrequency.allCases.first(where: { $0.presetExpr == line }) { return exact }
        guard let p = parts(line) else { return .custom }
        let (minute, hour, dayOfMonth, month, dayOfWeek) = (p[0], p[1], p[2], p[3], p[4])
        // A number out of its range (hour 25) is Custom: a preset would show, and on any touch save, 9:00 / day 1.
        let timed = inRange(minute, 0, 59) != nil && inRange(hour, 0, 23) != nil
        if dayOfMonth == "*" && month == "*" && dayOfWeek == "*" && timed { return .daily }
        if dayOfMonth == "*" && month == "*" && dayOfWeek == "1-5" && timed { return .weekdays }
        if dayOfMonth == "*" && month == "*" && dayList(dayOfWeek) != nil && timed { return .weekly }
        if month == "*" && dayOfWeek == "*" && inRange(dayOfMonth, 1, 31) != nil && timed { return .monthly }
        if hour == "*" && dayOfMonth == "*" && month == "*" && dayOfWeek == "*" && inRange(minute, 0, 59) != nil { return .hourly }
        return .custom
    }

    private static func inRange(_ token: String, _ low: Int, _ high: Int) -> Int? {
        guard isInteger(token), let value = Int(token), value >= low, value <= high else { return nil }
        return value
    }

    /// Weekly's days as written: one day number or a comma list of them ("1,3,5"), 0-7. Ranges and steps are not a
    /// list of days here ("1-5" is Weekdays; anything else stays Custom).
    static func dayList(_ token: String) -> [Int]? {
        let pieces = token.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !pieces.isEmpty else { return nil }
        var days: [Int] = []
        for piece in pieces {
            guard let day = inRange(piece, 0, 7) else { return nil }
            days.append(day)
        }
        return JobTimeFields.cleanDays(days)
    }

    /// `cronTimeFields`: only plain numbers (and Weekly's list of days) count; everything else keeps `base`.
    static func fields(_ expr: String, base: JobTimeFields = JobTimeFields()) -> JobTimeFields {
        guard let p = parts(expr) else { return base }
        var out = base
        if let minute = inRange(p[0], 0, 59) { out.minute = minute }
        if let hour = inRange(p[1], 0, 23) { out.hour = hour }
        if let day = inRange(p[2], 1, 31) { out.day = day }
        if let days = dayList(p[4]) { out.weekdays = days }
        return out
    }

    /// `composeCron`. Every 15 minutes and Custom have no fields: their own line (Custom: "").
    static func compose(_ frequency: JobFrequency, _ fields: JobTimeFields) -> String {
        switch frequency {
        case .hourly: "\(fields.minute) * * * *"
        case .weekdays: "\(fields.minute) \(fields.hour) * * 1-5"
        case .weekly: "\(fields.minute) \(fields.hour) * * " + JobTimeFields.cleanDays(fields.weekdays).map(String.init).joined(separator: ",")
        case .monthly: "\(fields.minute) \(fields.hour) \(fields.day) * *"
        case .daily: "\(fields.minute) \(fields.hour) * * *"
        case .every15: "*/15 * * * *"
        case .custom: ""
        }
    }

    /// The line a preset switch starts from (`cronForPreset` + `handleSchedulePresetChange`, index.tsx:1163-1174):
    /// a timed preset keeps the time and day `current` already set; going to Custom keeps the current expression.
    static func expression(for preset: JobFrequency, keeping current: String) -> String {
        guard let own = preset.presetExpr else { return current }
        return preset.isTimed ? compose(preset, fields(current, base: fields(own))) : own
    }

    /// The hourly minute choices: :00 … :55, plus the current minute when it is off the grid.
    static func minuteChoices(current: Int) -> [Int] {
        let grid = Array(stride(from: 0, to: 60, by: 5))
        return grid.contains(current) ? grid : (grid + [current]).sorted()
    }

    /// "9:00 AM" or "09:00" (`formatCronTime` in the device's 12/24 h style).
    static func clock(_ hour: Int, _ minute: Int, uses24Hour: Bool) -> String {
        if uses24Hour { return String(format: "%02d:%02d", hour, minute) }
        let h = hour % 12 == 0 ? 12 : hour % 12
        return "\(h):" + String(format: "%02d", minute) + (hour < 12 ? " AM" : " PM")
    }

    /// The sentence under the fields. Empty for Custom (its field has its own preview).
    static func summary(_ frequency: JobFrequency, expr: String, uses24Hour: Bool = false) -> String {
        guard let p = parts(expr) else {
            return frequency == .every15 ? "Every 15 minutes" : ""
        }
        let time: String = {
            guard let hour = Int(p[1]), let minute = Int(p[0]), isInteger(p[0]), isInteger(p[1]),
                  (0...23).contains(hour), (0...59).contains(minute) else { return "\(p[1]):\(p[0])" }
            return clock(hour, minute, uses24Hour: uses24Hour)
        }()
        switch frequency {
        case .daily: return "Every day at \(time)"
        case .weekdays: return "Weekdays at \(time)"
        case .weekly:
            guard let days = dayList(p[4]) else { return "Every day \(p[4]) at \(time)" }
            if days.count == 1 { return "Every \(JobWords.days[days[0]]) at \(time)" }
            if days.count == 7 { return "Every day at \(time)" }
            if days == [1, 2, 3, 4, 5] { return "Weekdays at \(time)" }
            if days == [0, 6] { return "Weekends at \(time)" }
            return "Every \(dayNames(days)) at \(time)"
        case .monthly: return "Monthly on day \(p[2]) at \(time)"
        case .hourly:
            return p[0] == "0" ? "At the top of every hour" : "Every hour at :" + (p[0].count < 2 ? "0" + p[0] : p[0])
        case .every15: return "Every 15 minutes"
        case .custom: return ""
        }
    }

    /// "Mon, Wed and Fri", Monday first (Sunday last), as people say a week.
    static func dayNames(_ days: [Int]) -> String {
        let names = days.sorted { ($0 + 6) % 7 < ($1 + 6) % 7 }.map { JobWords.shortDays[$0] }
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    /// When a schedule next fires, on the gateway's clock (`hostOffset` minutes east of UTC, read from a job's
    /// `next_run_at`; the phone's zone when no job says). nil for a line the app cannot read (Custom phrases).
    static func nextRun(_ expr: String, hostOffset: Int?, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        JobWords.nextCronFire(cleanCustom(expr), after: now, offset: hostOffset, calendar: calendar)
    }

    /// "Months without day 31 skip this run." above 28; nil otherwise.
    static func skipNote(_ frequency: JobFrequency, _ fields: JobTimeFields) -> String? {
        frequency == .monthly && fields.day > 28 ? "Months without day \(fields.day) skip this run." : nil
    }

    /// What a typed or pasted Custom schedule is sent as: line breaks, tabs and non-breaking spaces collapse to single
    /// spaces, "smart" quotes and dashes become plain ones (a pasted expression from Notes), trimmed.
    static func cleanCustom(_ text: String) -> String {
        var out = ""
        var lastWasSpace = false
        for scalar in text.unicodeScalars {
            let ch: Character
            switch scalar {
            case "\u{2018}", "\u{2019}": ch = "'"
            case "\u{201C}", "\u{201D}": ch = "\""
            case "\u{2013}", "\u{2014}", "\u{2212}": ch = "-"
            case "\u{FF10}"..."\u{FF19}": ch = Character(UnicodeScalar(scalar.value - 0xFF10 + 0x30)!)
            default: ch = Character(scalar)
            }
            if ch.isWhitespace || scalar == "\u{00A0}" || scalar == "\u{202F}" {
                if !lastWasSpace && !out.isEmpty { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(ch)
                lastWasSpace = false
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// The preview under the Custom field: a five-field cron the app can say plainly, else nil.
    static func customPreview(_ text: String) -> String? {
        let line = cleanCustom(text)
        guard parts(line) != nil else { return nil }
        return JobWords.describeCron(line)
    }
}
