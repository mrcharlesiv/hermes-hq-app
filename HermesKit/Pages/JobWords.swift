// The Jobs page's words (docs/spec/1x-pages.md §3.3), ported from the web app with its tests as the oracle:
// `src/audit-c-format.ts` (schedules, runs, delivery, Run Now), `src/list-time.ts` (next run), the vendored
// `app/cron/job-state.ts` and `cron-job-model.ts`, `src/fe-pages-r4.ts` (`lastRunFailed`), `src/fe-lists-r3.ts`
// (`lastRunNote`) and `src/ui-pages/job-sections-model.ts`. en-US words and clock, as the web formats them; every
// function takes `now` and a `calendar` (its time zone is "the phone's") so tests pin America/Chicago.

import Foundation

// MARK: - Dates

nonisolated enum PagesDate {
    private static let iso = RX(#"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?)?\s*(Z|[+-]\d{2}:?\d{2})?$"#)

    /// JS `new Date(iso)` for the gateway's ISO times: with a zone ("-05:00", "Z", "+0530") that instant; without one,
    /// the wall clock in `calendar`'s zone (date-only strings are UTC midnight, as JS reads them). nil when unreadable.
    static func parse(_ text: String?, calendar: Calendar = .current) -> Date? {
        guard let text = text?.pgTrim, !text.isEmpty, let g = iso.exec(text) else { return nil }
        guard let y = Int(g[1] ?? ""), let mo = Int(g[2] ?? ""), let d = Int(g[3] ?? "") else { return nil }
        let h = Int(g[4] ?? "") ?? 0, mi = Int(g[5] ?? "") ?? 0, s = Int(g[6] ?? "") ?? 0
        guard (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, s < 61 else { return nil }
        var fraction = 0.0
        if let digits = g[7] { fraction = Double("0." + digits) ?? 0 }
        var cal = Calendar(identifier: .gregorian)
        if let zone = g[8] {
            cal.timeZone = TimeZone(secondsFromGMT: offsetMinutes(zone) * 60) ?? .gmt
        } else if g[4] == nil {
            cal.timeZone = .gmt
        } else {
            cal.timeZone = calendar.timeZone
        }
        var parts = DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
        parts.calendar = cal
        guard let date = cal.date(from: parts), cal.component(.day, from: date) == d else { return nil }
        return date.addingTimeInterval(fraction)
    }

    /// "-05:00" → -300, "Z" → 0, "+0530" → 330.
    static func offsetMinutes(_ zone: String) -> Int {
        if zone == "Z" { return 0 }
        let digits = zone.dropFirst().replacingOccurrences(of: ":", with: "")
        guard digits.count == 4, let hh = Int(digits.prefix(2)), let mm = Int(digits.suffix(2)) else { return 0 }
        return (zone.hasPrefix("-") ? -1 : 1) * (hh * 60 + mm)
    }
}

// MARK: - Words

nonisolated enum JobWords {
    static let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let shortDays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                         "October", "November", "December"]
    static let shortMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// The scheduler's grace before a run is overdue (`CRON_OVERDUE_GRACE_MS`, `NEXT_RUN_OVERDUE_GRACE_MS`).
    static let overdueGrace: TimeInterval = 15 * 60

    // MARK: Formatting (en-US, fixed: never the device locale)

    static func int(_ value: String) -> Int? { !value.isEmpty && value.allSatisfy({ $0.isASCII && $0.isNumber }) ? Int(value) : nil }

    /// "8:15 AM".
    static func clock(_ hour: Int, _ minute: Int) -> String {
        let h = ((hour % 24) + 24) % 24
        let twelve = h % 12 == 0 ? 12 : h % 12
        return "\(twelve):\(minute < 10 ? "0" : "")\(minute) \(h < 12 ? "AM" : "PM")"
    }

    static func clock(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return clock(c.hour ?? 0, c.minute ?? 0)
    }

    static func weekdayIndex(_ date: Date, calendar: Calendar) -> Int { calendar.component(.weekday, from: date) - 1 }

    /// "Wed, Sep 30" (+ ", 2025" when `year`).
    static func dayDate(_ date: Date, calendar: Calendar, year: Bool = false) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let base = "\(shortDays[weekdayIndex(date, calendar: calendar)]), \(shortMonths[(c.month ?? 1) - 1]) \(c.day ?? 1)"
        return year ? base + ", \(c.year ?? 0)" : base
    }

    /// "Sep 30" (+ ", 2025").
    static func monthDay(_ date: Date, calendar: Calendar, year: Bool = false) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let base = "\(shortMonths[(c.month ?? 1) - 1]) \(c.day ?? 1)"
        return year ? base + ", \(c.year ?? 0)" : base
    }

    static func sameYear(_ a: Date, _ b: Date, calendar: Calendar) -> Bool {
        calendar.component(.year, from: a) == calendar.component(.year, from: b)
    }

    /// Calendar days from `now` to `date` (0 today, -1 yesterday, 1 tomorrow).
    static func daysFrom(_ date: Date, _ now: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }

    static func list(_ items: [String]) -> String {
        items.count <= 1 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    // MARK: Schedules (audit-c-format.ts:18-117)

    private static func dayField(_ field: String) -> String? {
        if field == "*" { return "" }
        if field == "1-5" { return "weekdays" }
        if RX.c(#"^(0,6|6,0|6,7|7,6|6-7)$"#).test(field) { return "weekends" }
        if let range = RX.c(#"^(\d)-(\d)$"#).exec(field), let a = Int(range[1] ?? ""), let b = Int(range[2] ?? "") {
            return "\(shortDays[a % 7])–\(shortDays[b % 7])"
        }
        let values = field.split(separator: ",", omittingEmptySubsequences: false).map { int(String($0)) }
        if values.contains(where: { $0 == nil || $0! > 7 }) { return nil }
        return values.count == 1 ? "every \(days[values[0]! % 7])" : list(values.map { shortDays[$0! % 7] })
    }

    /// "15 8 * * 1-5" → "Weekdays at 8:15 AM". nil for expressions it cannot say plainly.
    static func describeCron(_ expr: String) -> String? {
        let parts = expr.pgTrim.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 5 else { return nil }
        let (minute, hour, dayOfMonth, month, dayOfWeek) = (parts[0], parts[1], parts[2], parts[3], parts[4])
        if month != "*" { return nil }
        guard let on = dayField(dayOfWeek) else { return nil }
        let dom: Int? = dayOfMonth == "*" ? nil : int(dayOfMonth)
        if dayOfMonth != "*" && (dom == nil || !on.isEmpty) { return nil }
        let when = dom != nil ? "monthly on day \(dom!)" : (on.isEmpty ? "every day" : on)
        let m = int(minute)
        let everyMinutes = RX.c(#"^\*/(\d+)$"#).exec(minute)
        let everyHours = RX.c(#"^\*/(\d+)$"#).exec(hour)
        let hourRange = RX.c(#"^(\d+)-(\d+)$"#).exec(hour)
        let hours = hour.split(separator: ",", omittingEmptySubsequences: false).map { int(String($0)) }
        if let m, !hours.contains(where: { $0 == nil }) {
            return when.prefix(1).uppercased() + when.dropFirst() + " at " + list(hours.map { clock($0!, m) })
        }
        let window = hourRange.map { ", \(clock(Int($0[1] ?? "") ?? 0, 0))–\(clock(Int($0[2] ?? "") ?? 0, 59))" } ?? ""
        if hour != "*" && hourRange == nil && everyHours == nil { return nil }
        let suffix = when == "every day" ? "" : " (\(when))"
        if let everyMinutes { return "Every \(everyMinutes[1] ?? "") minutes\(window)\(suffix)" }
        if minute == "*" { return "Every minute\(window)\(suffix)" }
        guard let m else { return nil }
        let mm = m < 10 ? "0\(m)" : "\(m)"
        if let everyHours { return "Every \(everyHours[1] ?? "") hours at :\(mm)\(suffix)" }
        return (m == 0 ? "Every hour, on the hour" : "Every hour at :\(mm)") + window + suffix
    }

    /// Any stored schedule ("every 30m", a cron line, a one-off time) in words, or nil.
    static func describeSchedule(_ schedule: String, now: Date = Date(), calendar: Calendar = .current) -> String? {
        let text = schedule.pgTrim
        if let every = RX.c(#"^every (\d+)\s*([mhd])$"#, .caseInsensitive).exec(text), let n = Int(every[1] ?? "") {
            let unit = (every[2] ?? "m").lowercased()
            let minutes = n * (unit == "h" ? 60 : unit == "d" ? 1440 : 1)
            if minutes % 1440 == 0 { return minutes == 1440 ? "Every day" : "Every \(minutes / 1440) days" }
            if minutes % 60 == 0 { return minutes == 60 ? "Every hour" : "Every \(minutes / 60) hours" }
            return "Every \(minutes) minutes"
        }
        if let once = RX.c(#"^(?:once in )?(\d+)\s*([mhd])$"#, .caseInsensitive).exec(text) {
            return "Once, \(once[1] ?? "")\((once[2] ?? "").lowercased()) after it was set"
        }
        if RX.c(#"^\d{4}-\d{2}-\d{2}T"#).test(text), let date = PagesDate.parse(text, calendar: calendar) {
            return onceOn(date, now: now, calendar: calendar)
        }
        if let at = RX.c(#"^once at (\d{4})-(\d{2})-(\d{2})[ T](\d{1,2}):(\d{2})$"#, .caseInsensitive).exec(text) {
            let v = (1...5).map { Int(at[$0] ?? "") ?? -1 }
            guard v[1] >= 1, v[1] <= 12, v[3] < 24, v[4] < 60 else { return nil }
            var parts = DateComponents(year: v[0], month: v[1], day: v[2], hour: v[3], minute: v[4])
            parts.calendar = calendar
            guard let date = calendar.date(from: parts),
                  calendar.component(.month, from: date) == v[1], calendar.component(.day, from: date) == v[2] else { return nil }
            return onceOn(date, now: now, calendar: calendar)
        }
        return describeCron(text)
    }

    /// "Once on Wed, Sep 30 at 9:00 AM" (the year only when it is not this one).
    static func onceOn(_ date: Date, now: Date, calendar: Calendar) -> String {
        "Once on \(dayDate(date, calendar: calendar, year: !sameYear(date, now, calendar: calendar))) at \(clock(date, calendar: calendar))"
    }

    static func zoneLabel(_ offset: String) -> String {
        if RX.c(#"^(Z|[+-]00:?00)$"#).test(offset) { return "UTC" }
        guard let g = RX.c(#"^([+-])(\d{2}):?(\d{2})$"#).exec(offset), let hh = Int(g[2] ?? "") else { return "" }
        return "UTC\(g[1] == "-" ? "−" : "+")\(hh)\(g[3] == "00" ? "" : ":" + (g[3] ?? ""))"
    }

    /// A cron line the scheduler runs in another time zone than the phone's, said in the phone's time where that is
    /// plain (daily, or one weekday), else with the zone named. nil when they agree.
    static func localCronSchedule(_ expr: String, nextRunAt: String?, calendar: Calendar = .current) -> String? {
        let parts = expr.pgTrim.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 5, parts[2] == "*", parts[3] == "*" else { return nil }
        let written = RX.c(#"T(\d{2}):(\d{2})(?::\d{2}(?:\.\d+)?)?(Z|[+-]\d{2}:?\d{2})$"#).exec(nextRunAt ?? "")
        guard let minute = int(parts[0]), let hour = int(parts[1]), let written,
              let next = PagesDate.parse(nextRunAt, calendar: calendar) else { return nil }
        guard Int(written[1] ?? "") == hour, Int(written[2] ?? "") == minute else { return nil }
        let local = calendar.dateComponents([.hour, .minute], from: next)
        if local.hour == hour && local.minute == minute { return nil }
        let time = clock(local.hour ?? 0, local.minute ?? 0)
        if parts[4] == "*" { return "Every day at \(time)" }
        if int(parts[4]) != nil { return "Every \(days[weekdayIndex(next, calendar: calendar)]) at \(time)" }
        guard let said = describeCron(expr) else { return nil }
        return "\(said) \(zoneLabel(written[3] ?? ""))".pgTrim
    }

    /// A job's schedule in words, in the phone's time.
    static func jobScheduleWords(expr: String, display: String, runAt: String, nextRunAt: String?, known: String = "",
                                 now: Date = Date(), calendar: Calendar = .current) -> String {
        if let local = localCronSchedule(expr, nextRunAt: nextRunAt, calendar: calendar) { return local }
        if !runAt.isEmpty, let once = describeSchedule(runAt, now: now, calendar: calendar) { return once }
        if !known.isEmpty { return known }
        return describeSchedule(expr, now: now, calendar: calendar) ?? describeSchedule(display, now: now, calendar: calendar) ?? display
    }

    /// `jobScheduleExpr` / `jobScheduleDisplay` (vendor `app/cron/index.tsx:135-141`).
    static func scheduleExpr(_ job: CronJob) -> String {
        nonEmpty(job.schedule?.expr) ?? nonEmpty(job.scheduleDisplay) ?? ""
    }

    static func scheduleDisplay(_ job: CronJob) -> String {
        nonEmpty(job.scheduleDisplay) ?? nonEmpty(job.schedule?.display) ?? nonEmpty(job.schedule?.expr) ?? "—"
    }

    static func scheduleWords(_ job: CronJob, now: Date = Date(), calendar: Calendar = .current) -> String {
        jobScheduleWords(expr: scheduleExpr(job), display: scheduleDisplay(job), runAt: job.schedule?.runAt ?? "",
                         nextRunAt: job.nextRunAt, now: now, calendar: calendar)
    }

    private static func nonEmpty(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }

    // MARK: Next run (list-time.ts:60-173)

    /// Minutes east of UTC written at the end of an ISO time; nil when it names none.
    static func writtenOffset(_ iso: String?) -> Int? {
        guard let g = RX.c(#"(Z|([+-])(\d{2}):?(\d{2}))$"#).exec(iso ?? "") else { return nil }
        if g[1] == "Z" { return 0 }
        return (g[2] == "-" ? -1 : 1) * ((Int(g[3] ?? "") ?? 0) * 60 + (Int(g[4] ?? "") ?? 0))
    }

    private static func cronField(_ text: String, _ lo: Int, _ hi: Int) -> Set<Int>? {
        var allowed = Set<Int>()
        let re = RX.c(#"^(\*|(\d+)(?:-(\d+))?)(?:/(\d+))?$"#)
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            guard let m = re.exec(String(part)) else { return nil }
            let step = m[4].flatMap { Int($0) } ?? 1
            let star = m[1] == "*"
            let from = star ? lo : Int(m[2] ?? "") ?? -1
            let to = star ? hi : (m[3] != nil ? Int(m[3]!) ?? -1 : (m[4] != nil ? hi : from))
            if step == 0 || from < lo || to > hi || from > to { return nil }
            var v = from
            while v <= to { allowed.insert(v); v += step }
        }
        return allowed
    }

    /// The first time after `after` a five-field cron line fires, on the wall clock `offset` minutes east of UTC
    /// (the gateway's zone), or `calendar`'s zone when nil. nil for a line it cannot read or that never fires in a year.
    static func nextCronFire(_ expr: String, after: Date, offset: Int? = nil, calendar: Calendar = .current) -> Date? {
        let parts = expr.pgTrim.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 5,
              let minute = cronField(parts[0], 0, 59), let hour = cronField(parts[1], 0, 23),
              let dom = cronField(parts[2], 1, 31), let month = cronField(parts[3], 1, 12),
              let dow = cronField(parts[4], 0, 7) else { return nil }
        let weekday = { (day: Int) -> Bool in dow.contains(day) || (day == 0 && dow.contains(7)) }
        let either = parts[2] != "*" && parts[4] != "*"
        let dayMatches = { (d: Int, m: Int, wd: Int) -> Bool in
            month.contains(m) && (either ? (dom.contains(d) || weekday(wd)) : (dom.contains(d) && weekday(wd)))
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = offset.flatMap { TimeZone(secondsFromGMT: $0 * 60) } ?? calendar.timeZone
        let hours = (0..<24).filter { hour.contains($0) }
        let minutes = (0..<60).filter { minute.contains($0) }
        let base = cal.dateComponents([.year, .month, .day], from: after)
        for dayIndex in 0...366 {
            var noon = DateComponents(year: base.year, month: base.month, day: (base.day ?? 1) + dayIndex, hour: 12)
            noon.calendar = cal
            guard let probe = cal.date(from: noon) else { continue }
            let p = cal.dateComponents([.year, .month, .day, .weekday], from: probe)
            guard dayMatches(p.day ?? 0, p.month ?? 0, (p.weekday ?? 1) - 1) else { continue }
            for h in hours {
                for mi in minutes {
                    var at = DateComponents(year: p.year, month: p.month, day: p.day, hour: h, minute: mi)
                    at.calendar = cal
                    if let date = cal.date(from: at), date > after { return date }
                }
            }
        }
        return nil
    }

    /// Whether the gateway's next run is later than the schedule's own next time by more than an hour, on every offset
    /// a daylight-saving change could have left.
    static func skippedRuns(_ expr: String, now: Date, next: Date, offset: Int?, calendar: Calendar = .current) -> Bool {
        let offsets: [Int?] = offset.map { [$0, $0 - 60, $0 + 60] } ?? [nil]
        return offsets.allSatisfy { zone in
            guard let due = nextCronFire(expr, after: now, offset: zone, calendar: calendar) else { return false }
            return next.timeIntervalSince(due) > 3600
        }
    }

    /// "Today", "Tomorrow", "Sunday" within the week, else "Mon, Oct 5".
    private static func jobDay(_ date: Date, _ now: Date, calendar: Calendar) -> String {
        let d = daysFrom(date, now, calendar: calendar)
        if d == 0 { return "Today" }
        if d == 1 { return "Tomorrow" }
        if d > 1 && d < 7 { return days[weekdayIndex(date, calendar: calendar)] }
        return dayDate(date, calendar: calendar)
    }

    /// What a job row says after its schedule: "", "Due now", "Overdue", "Next in 12 min", "Next tomorrow",
    /// "Next Sun 6:00 PM", "Skipped until Mon, Oct 5".
    static func jobNextWords(state: String, schedule: CronSchedule?, nextRunAt: String?, scheduleWords: String,
                             now: Date = Date(), calendar: Calendar = .current) -> String {
        if ["paused", "completed", "disabled"].contains(state) || schedule?.kind == "once"
            || RX.c(#"^Once\b"#).test(scheduleWords) { return "" }
        guard let next = PagesDate.parse(nextRunAt, calendar: calendar) else { return "" }
        let late = now.timeIntervalSince(next)
        if late > overdueGrace { return "Overdue" }
        if late >= 0 { return "Due now" }
        let times = RX.c(#"\b\d{1,2}:\d{2}\s?[AP]M\b"#).all(scheduleWords).compactMap { $0[0] }
        let day = jobDay(next, now, calendar: calendar)
        let time = clock(next, calendar: calendar)
        let when: String
        if times.count == 1 && times[0] == time {
            when = day
        } else if day == "Today" {
            when = time
        } else {
            let lead = daysFrom(next, now, calendar: calendar) >= 7 ? day + "," : day == "Tomorrow" ? day : shortDays[weekdayIndex(next, calendar: calendar)]
            when = "\(lead) \(time)"
        }
        let kind = schedule?.kind
        let expr = (kind == "cron" || (kind == nil && !(schedule?.expr ?? "").isEmpty)) ? schedule?.expr : nil
        if let expr, !expr.isEmpty, skippedRuns(expr, now: now, next: next, offset: writtenOffset(nextRunAt), calendar: calendar) {
            return "Skipped until \(when)"
        }
        let ahead = next.timeIntervalSince(now)
        // One "Next …" form for every row (UX study 2026-10-19 #117: a bare "in 4 min" beside "Next: Tomorrow").
        if ahead < 3600 { return "Next in \(max(1, Int((ahead / 60).rounded()))) min" }
        return "Next " + (when.hasPrefix("Today") || when.hasPrefix("Tomorrow") ? when.prefix(1).lowercased() + when.dropFirst() : when)
    }

    // MARK: Relative times (audit-c-format.ts:306-321)

    /// "Today at 9:05 AM", "Yesterday at…", "Tomorrow at…", "Wed at 6:01 AM" within a week either side, else
    /// "Sep 12 at 4:07 PM" ("Dec 31, 2025 at 11:00 PM" in another year). "" for no time.
    static func relativeDateTime(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "" }
        let time = clock(date, calendar: calendar)
        let d = daysFrom(date, now, calendar: calendar)
        if d == 0 { return "Today at \(time)" }
        if d == -1 { return "Yesterday at \(time)" }
        if d == 1 { return "Tomorrow at \(time)" }
        if abs(d) < 7 { return "\(shortDays[weekdayIndex(date, calendar: calendar)]) at \(time)" }
        return "\(monthDay(date, calendar: calendar, year: !sameYear(date, now, calendar: calendar))) at \(time)"
    }

    static func relativeDateTime(_ iso: String?, now: Date = Date(), calendar: Calendar = .current) -> String {
        relativeDateTime(PagesDate.parse(iso, calendar: calendar), now: now, calendar: calendar)
    }

    // MARK: Runs (audit-c-format.ts:119-162)

    private static let injected = RX(#"^\s*\[(?:IMPORTANT|SYSTEM|NOTE|CONTEXT|SCHEDULED|CRON)\b[^\]]*(?:\]|$)\s*"#, .caseInsensitive)

    static func runPreview(_ text: String?) -> String {
        var value = (text ?? "").pgTrim
        var previous = ""
        while previous != value {
            previous = value
            value = injected.replace(value, with: "", all: false).pgTrim
        }
        return value
    }

    private static let autoRunTitle = RX(#" · (?:[A-Z][a-z]{2,8},? )?[A-Z][a-z]{2} \d{1,2}(?:, \d{4})?,? \d{1,2}:\d{2}(?:\s?[AP]M)?$"#)

    /// A run's title ("Fri, Oct 3, 1:00 PM") and detail ("4 messages · Weekly review sent", "Running", "Completed",
    /// "Failed · <reason>").
    static func cronRunLabel(_ run: CronRun, calendar: Calendar = .current) -> (title: String, detail: String) {
        let seconds = run.startedAt ?? run.lastActive
        let title: String
        if let seconds {
            let date = Date(timeIntervalSince1970: seconds)
            title = "\(dayDate(date, calendar: calendar)), \(clock(date, calendar: calendar))"
        } else {
            title = "Scheduled run"
        }
        if run.source == "cron_output" {
            let raw = run.title ?? ""
            var status: String
            var rest = ""
            if let m = RX.c(#"^([A-Z][A-Z ]+) · ([\s\S]*)$"#).exec(raw) {
                status = m[1] ?? ""
                rest = m[2] ?? ""
            } else {
                status = RX.c(#"^# [^\n]*\(FAILED\)"#).test(raw) ? "FAILED" : "COMPLETED"
            }
            let reason = status == "FAILED" && !rest.isEmpty && !rest.hasPrefix("#")
                ? RX.c(#"^[A-Za-z_][\w.]*(?:Error|Exception):\s*"#).replace(rest, with: "", all: false) : ""
            if !status.isEmpty { status = status.prefix(1) + status.dropFirst().lowercased() }
            return (title, [status, reason].filter { !$0.isEmpty }.joined(separator: " · "))
        }
        let said = [run.title, run.preview].map(runPreview).first { !$0.isEmpty && !autoRunTitle.test($0) } ?? ""
        let count = run.messageCount ?? 0
        let status = run.isActive ? "Running" : count > 0 ? "\(count) \(count == 1 ? "message" : "messages")" : ""
        return (title, [status, said].filter { !$0.isEmpty }.joined(separator: " · "))
    }

    // MARK: Delivery (audit-c-format.ts:197-239, 323-342)

    static let platformNames: [String: String] = [
        "telegram": "Telegram", "discord": "Discord", "slack": "Slack", "email": "Email", "whatsapp": "WhatsApp",
        "signal": "Signal", "matrix": "Matrix", "sms": "SMS", "homeassistant": "Home Assistant", "mattermost": "Mattermost",
        "imessage": "iMessage", "webhook": "Webhook", "groupme": "GroupMe", "bluebubbles": "BlueBubbles",
        "dingtalk": "DingTalk", "wecom": "WeCom", "wechat": "WeChat", "qq": "QQ", "line": "LINE",
    ]

    /// `titleCase`: "my_bridge" → "My Bridge"; "Url" → "URL", "Id" → "ID".
    static func titleCase(_ key: String) -> String {
        let spaced = RX.c(#"[_-]+"#).replace(key, with: " ")
        var out = ""
        var previousIsWord = false
        for ch in spaced {
            let isWord = ch.isLetter || ch.isNumber || ch == "_"
            out += (!previousIsWord && isWord) ? ch.uppercased() : String(ch)
            previousIsWord = isWord
        }
        return RX.c(#"\bId\b"#).replace(RX.c(#"\bUrl\b"#).replace(out, with: "URL"), with: "ID")
    }

    static func platformName(_ id: String, labels: [String: String] = [:]) -> String {
        labels[id] ?? platformNames[id] ?? titleCase(id)
    }

    static func known(_ value: String?) -> String {
        let text = (value ?? "").pgTrim
        return text == "None" ? "" : text
    }

    private static func unnamedChat(_ chat: String, full: Bool) -> String {
        guard RX.c(#"^-?\d+$"#).test(chat) else { return chat }
        let kind = RX.c(#"^-100\d+$"#).test(chat) ? "group" : "chat"
        let shown = full || chat.count <= 4 ? RX.c(#"^-100(?=\d)"#).replace(chat, with: "", all: false) : "…" + chat.suffix(4)
        return "\(kind) \(shown)"
    }

    static func humanDeliverTarget(_ target: String, origin: CronOrigin? = nil, labels: [String: String] = [:],
                                   full: Bool = false, names: [String: String] = [:]) -> String {
        let value = target.pgTrim
        if value.isEmpty { return "" }
        if value == "origin" {
            let platform = known(origin?.platform), chat = known(origin?.chatName)
            return ["Where it was created", platform.isEmpty ? "" : platformName(platform, labels: labels), chat]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if value == "local" { return labels["local"] ?? "Keep in Hermes (no message)" }
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let platform = pieces[0], chat = pieces.count > 1 ? pieces[1] : "", thread = pieces.count > 2 ? pieces[2] : ""
        if chat.isEmpty { return platformName(platform, labels: labels) }
        let sameChat = known(origin?.platform) == platform && known(origin?.chatId) == chat
        let named = names["\(platform):\(chat)"] ?? ""
        let name = sameChat && !known(origin?.chatName).isEmpty ? known(origin?.chatName)
            : (!named.isEmpty ? named : unnamedChat(chat, full: full))
        return "\(platformName(platform, labels: labels)) · \(name)\(thread.isEmpty ? "" : " (topic \(thread))")"
    }

    static func humanDeliver(_ deliver: String, origin: CronOrigin? = nil, labels: [String: String] = [:],
                             names: [String: String] = [:]) -> String {
        var targets = deliver.split(separator: ",", omittingEmptySubsequences: false).map(String.init).filter { !$0.pgTrim.isEmpty }
        // `local` beside another place says nothing more: every result is kept in Run History anyway (as the editor).
        if targets.contains(where: { $0.pgTrim != "local" }) { targets.removeAll { $0.pgTrim == "local" } }
        let short = targets.map { humanDeliverTarget($0, origin: origin, labels: labels, full: false, names: names) }
        let said = short.enumerated().map { index, label in
            short.firstIndex(of: label) != short.lastIndex(of: label)
                ? humanDeliverTarget(targets[index], origin: origin, labels: labels, full: true, names: names) : label
        }
        let joined = said.joined(separator: " + ")
        return joined.isEmpty ? humanDeliverTarget("local", origin: origin, labels: labels) : joined
    }

    /// Chat names the jobs' origins know, by "platform:chat id".
    static func knownChatNames(_ jobs: [CronJob]) -> [String: String] {
        var names: [String: String] = [:]
        for job in jobs {
            let platform = known(job.origin?.platform), chat = known(job.origin?.chatId), name = known(job.origin?.chatName)
            if !platform.isEmpty, !chat.isEmpty, !name.isEmpty, names["\(platform):\(chat)"] == nil { names["\(platform):\(chat)"] = name }
        }
        return names
    }

    /// "Bot Chat (maple-revenue-operator)" → "Bot Chat (Maple Revenue Operator)".
    static func readableTargetName(_ name: String, profiles: [String: String] = [:]) -> String {
        RX.c(#"\(([a-z0-9][a-z0-9_-]*)\)$"#, .caseInsensitive).replace(name, all: false) { g in
            let id = g[1] ?? ""
            if id == "default" { return "(Hermes)" }
            let shown = profiles[id] ?? (RX.c(#"[-_]"#).test(id) || RX.c(#"^[a-z]"#).test(id) ? titleCase(id) : id)
            return "(\(shown))"
        }
    }

    /// The question Run Now asks (r3-47). `title` is "Run “name” now?"; alerts use `runAlertTitle`.
    static func runNowCopy(_ name: String, deliver: String, origin: CronOrigin? = nil, labels: [String: String] = [:],
                           names: [String: String] = [:]) -> (title: String, description: String) {
        let targets = deliver.split(separator: ",").map { String($0).pgTrim }.filter { !$0.isEmpty && $0 != "local" }
        let places = targets.map { target -> String in
            if target == "origin" {
                let platform = known(origin?.platform), chat = known(origin?.chatName)
                if !chat.isEmpty && !platform.isEmpty { return "\(chat) on \(platformName(platform, labels: labels))" }
                return platform.isEmpty ? "the chat it came from" : "the \(platformName(platform, labels: labels)) chat it came from"
            }
            let said = humanDeliverTarget(target, origin: origin, labels: labels, full: false, names: names).components(separatedBy: " · ")
            return said.count > 1 ? "\(said[1]) on \(said[0])" : said[0]
        }
        let said = places.count > 1 ? places.dropLast().joined(separator: ", ") + " and " + places[places.count - 1] : places.first ?? ""
        let lead = said.isEmpty ? "Its result is kept in its Run History." : "It delivers to \(said)."
        return ("Run “\(name)” now?", "\(lead) Its schedule does not change.")
    }

    /// "Run “Weekly review” now?" → "Run “Weekly review” Now?" (alert titles are Title Case).
    static func runAlertTitle(_ title: String) -> String { RX.c(#" now\?$"#).replace(title, with: " Now?", all: false) }

    // MARK: Titles (audit-c-format.ts:478-506, job-state.ts)

    private static let slugName = RX(#"^[a-z0-9]+(?:[-_][a-z0-9]+)+$"#)
    private static let acronyms: Set<String> = ["ai", "api", "ap", "ci", "cpu", "crm", "csv", "dm", "dns", "gpu", "http", "id",
                                                 "ios", "json", "kpi", "llm", "mcp", "os", "pdf", "pr", "qa", "rss", "seo",
                                                 "sms", "sql", "ssh", "tts", "ui", "url", "ux"]
    private static let iosWords = ["ios": "iOS", "macos": "macOS", "iphone": "iPhone", "ipad": "iPad"]

    /// How other names spell a word ("GBrain", "NHB"), from titles that are already words.
    static func knownWordCasing<S: Sequence>(_ titles: S) -> [String: String] where S.Element == String {
        var casing: [String: String] = [:]
        let word = RX.c(#"[A-Za-z][A-Za-z0-9]*"#)
        for title in titles where !slugName.test(title) {
            for match in word.all(title) {
                guard let w = match[0] else { continue }
                let rest = String(w.dropFirst())
                if rest.contains(where: { $0.isUppercase }) || (w.count > 1 && w == w.uppercased()) { casing[w.lowercased()] = w }
            }
        }
        return casing
    }

    /// A slug-like job name as words; any other name unchanged.
    static func humanJobTitle(_ name: String, casing: [String: String] = [:]) -> String {
        let text = name.pgTrim
        guard slugName.test(text) else { return name }
        return text.split(whereSeparator: { $0 == "-" || $0 == "_" }).enumerated().map { index, part in
            let word = String(part)
            if let known = iosWords[word] ?? casing[word] ?? (acronyms.contains(word) ? word.uppercased() : nil) { return known }
            return index == 0 ? word.prefix(1).uppercased() + word.dropFirst() : word
        }.joined(separator: " ")
    }

    /// Effective state: explicit state wins; else from `enabled`. A scheduled job whose work is out (`workIsOut`) is
    /// running: Hermes never stores that state, so a run the scheduler started read as Scheduled.
    static func jobState(_ job: CronJob) -> String {
        let stored = (job.state ?? "").pgTrim
        let state = !stored.isEmpty ? stored : job.enabled == false ? "disabled" : "scheduled"
        if (state == "scheduled" || state == "enabled") && workIsOut(job) { return "running" }
        return state
    }

    /// The job's run is out, or a bot is still working on what the run handed it (`botWorking`): a Bot Chat job's run
    /// ends at the handoff, minutes before the bot is done with it.
    static func workIsOut(_ job: CronJob) -> Bool { runIsOut(job) || job.botWorking != nil }

    /// The job's latest run attempt is claimed or running, and the job has not been marked run since it was claimed
    /// (Hermes stamps `last_run_at` a moment before it closes the attempt; a read between the two would say Running on).
    static func runIsOut(_ job: CronJob) -> Bool {
        let status = (job.latestRunStatus ?? "").pgTrim.lowercased()
        guard status == "claimed" || status == "running" else { return false }
        guard let last = PagesDate.parse(job.lastRunAt), let claimed = PagesDate.parse(job.latestRunClaimedAt) else { return true }
        return last < claimed
    }

    /// The row's and the detail's Running: the state, or work out for a job whose own state wins (a paused job run
    /// from another device).
    static func isRunning(_ job: CronJob) -> Bool { jobState(job) == "running" || workIsOut(job) }

    /// name → first 60 of prompt → first 60 of script → id.
    static func jobTitle(_ job: CronJob) -> String {
        func clip(_ v: String) -> String { v.count > 60 ? String(v.prefix(60)) + "…" : v }
        let name = (job.name ?? "").pgTrim, prompt = (job.prompt ?? "").pgTrim, script = (job.script ?? "").pgTrim
        if !name.isEmpty { return name }
        if !prompt.isEmpty { return clip(prompt) }
        if !script.isEmpty { return clip(script) }
        return job.id.isEmpty ? "Cron job" : job.id
    }

    /// Seconds the stored next run sits past the grace, or nil.
    static func nextRunOverdue(_ job: CronJob, now: Date = Date()) -> TimeInterval? {
        let state = jobState(job)
        guard !["paused", "completed", "disabled"].contains(state), let next = PagesDate.parse(job.nextRunAt) else { return nil }
        let overdue = now.timeIntervalSince(next)
        return overdue > overdueGrace ? overdue : nil
    }

    static func jobIsScriptOnly(_ job: CronJob) -> Bool { job.noAgent && !(job.script ?? "").pgTrim.isEmpty }

    static func jobDescription(_ job: CronJob) -> String {
        if let prompt = job.prompt, !prompt.isEmpty { return prompt }
        return job.script ?? ""
    }

    private static let errorPrefix = RX(#"^(?:[A-Za-z_][\w.]*(?:Error|Exception)|Exception):\s*"#)
    private static let errorMarker = RX(#"^\[[a-z_]+(?::[a-z_]+)?\]\s*"#)
    private static let errorEmoji = RX("^(?:\u{26A0}\u{FE0F}?|\u{1F6D1}|\u{274C}|\u{1F6AB})\\s*")

    /// The first plain sentence of a scheduler error ("RuntimeError: …" → "…").
    static func lastErrorSummary(_ lastError: String?) -> String {
        var text = (lastError ?? "").pgTrim
        var previous = ""
        while previous != text {
            previous = text
            text = errorPrefix.replace(errorEmoji.replace(errorMarker.replace(text, with: "", all: false), with: "", all: false),
                                       with: "", all: false).pgTrimStart
        }
        let end = RX.c(#"\. |\n"#).search(text)
        let sentence = (end == -1 ? text : text.pgSlice(0, end + 1)).pgTrim
        return sentence.count > 200 ? String(sentence.prefix(199)).trimmingCharacters(in: .whitespaces) + "…" : sentence
    }

    /// A scheduled job whose last run failed.
    static func lastRunFailed(_ job: CronJob) -> Bool {
        let state = (job.state ?? "").pgTrim.isEmpty ? "scheduled" : (job.state ?? "").pgTrim
        guard state == "scheduled" || state == "enabled" else { return false }
        return RX.c(#"^(error|failed|fail)$"#, .caseInsensitive).test(job.lastStatus ?? "") || !(job.lastError ?? "").isEmpty
    }

    /// "Last ran today at 9:05 AM · OK".
    static func lastRunNote(_ job: CronJob, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let at = PagesDate.parse(job.lastRunAt, calendar: calendar) else { return nil }
        let status = (job.lastStatus ?? "").lowercased()
        let failed = !(job.lastError ?? "").isEmpty || RX.c(#"^(error|failed|fail)$"#).test(status)
        var when = relativeDateTime(at, now: now, calendar: calendar)
        if when.hasPrefix("Today") || when.hasPrefix("Yesterday") { when = when.prefix(1).lowercased() + when.dropFirst() }
        return "Last ran \(when) · \(failed ? "Failed" : "OK")"
    }

    // MARK: Sections (ui-pages/job-sections-model.ts)

    enum Section: String, CaseIterable, Sendable {
        case needsAttention = "Needs Attention", running = "Running", scheduled = "Scheduled", paused = "Paused", completed = "Completed"
    }

    /// Explicit inactive states win over stale next dates and errors from older runs.
    static func jobSection(state: String, overdue: TimeInterval?, failed: Bool) -> Section {
        if state == "completed" { return .completed }
        if state == "paused" || state == "disabled" { return .paused }
        if state == "running" { return .running }
        if state == "error" || failed || overdue != nil { return .needsAttention }
        return .scheduled
    }

    static func section(_ job: CronJob, now: Date = Date()) -> Section {
        jobSection(state: jobState(job), overdue: nextRunOverdue(job, now: now), failed: lastRunFailed(job))
    }

    /// The row's subtitle: schedule words, then " · " and the next-run words when there are any. A running job (the
    /// gateway says so, or `running`: a Run Now still out) drops the next-run words; its lead says "Running". So does an
    /// overdue one, whose lead says "Overdue" (UX study #80). The dot keeps to the schedule with a no-break space, so a
    /// wrapped line never ends in a lone dot (#86).
    static func rowSubtitle(_ job: CronJob, now: Date = Date(), calendar: Calendar = .current, running: Bool = false) -> String {
        let schedule = scheduleWords(job, now: now, calendar: calendar)
        if running || jobState(job) == "running" { return schedule }
        let next = jobNextWords(state: jobState(job), schedule: job.schedule, nextRunAt: job.nextRunAt,
                                scheduleWords: schedule, now: now, calendar: calendar)
        if next == "Overdue" && !lastRunFailed(job) { return schedule }   // the lead says it
        return next.isEmpty ? schedule : "\(schedule)\u{00A0}· \(next)"
    }

    /// The row's coloured lead before its subtitle: "Running · ", "Last run failed · ", "Overdue · ", "Paused · " or
    /// nothing.
    enum RowLead: String, Sendable {
        case none = "", running = "Running · ", failed = "Last run failed · ", overdue = "Overdue · ", paused = "Paused · "
    }

    /// [model-scope] Owner 2026-11-03: under the editor's Model row, what a pick changes (the job's own `model`) and what
    /// Default (global model) means: the job's bot's own model, not one shared by every bot.
    static func modelScope(bot: String?) -> String {
        guard let bot = bot?.trimmingCharacters(in: .whitespacesAndNewlines), !bot.isEmpty else {
            return "Applies to this job only. Default uses the bot’s own model."
        }
        return "Applies to this job only. Default uses \(bot)’s own model."
    }

    static func rowLead(running: Bool, failed: Bool, overdue: Bool = false, paused: Bool) -> RowLead {
        running ? .running : failed ? .failed : overdue ? .overdue : paused ? .paused : .none
    }

    /// The detail's status line: "Scheduled", "Running", "Paused", "Completed", "Off", or "Last run failed". A run
    /// out says Running over an earlier failure, as the row's lead does.
    static func statusWord(_ job: CronJob) -> String {
        if isRunning(job) { return "Running" }
        if lastRunFailed(job) { return "Last run failed" }
        switch jobState(job) {
        case "paused": return "Paused"
        case "completed": return "Completed"
        case "disabled": return "Off"
        case "error": return "Last run failed"
        default: return "Scheduled"
        }
    }
}
