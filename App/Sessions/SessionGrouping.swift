// The Sessions list's date groups, as the web phone app draws them: the desktop's `calendarBucket`
// (`vendor/hermes/apps/desktop/src/lib/time.ts:84-190`) with every group labelled on a phone, the newest too
// (`build/fe-lists-gates.ts:3080-3100`). Groups coarsen with age — "Earlier today", "Yesterday", "Earlier this week",
// "Last week", "Earlier this month", then the month ("August") and the month and year ("August 2025") — and a day
// runs from 4 AM, so a 12:30 AM session groups with 11:50 PM. Newest first; rows with no time go last ("Earlier").
// Which rows are listed at all is `SessionList.visible` (spec 02 §9.2).

import Foundation

nonisolated struct SessionGroup: Hashable, Sendable {
    var id: String          // stable bucket key: "today", "this-week", "m-2026-8", "my-2025-12", "none"…
    var title: String
    var sessions: [SessionSummary]
    /// A platform folder (`ChatSource`): the platform id. Its header names the platform and opens or closes it.
    var source: String? = nil
    /// The folder is closed: no rows drawn (`total` still counts them).
    var collapsed = false
    /// Every chat the folder holds, drawn or not.
    var total = 0
    /// Chats past the drawn ones ("Show More").
    var more = 0
    /// A capped project opened with Show More: every chat drawn, and "Show Less" under them.
    var expanded = false
    /// Unread chats it holds (a closed group's header says so).
    var unread = 0
    /// The Other Apps row: its platforms, the one with the newest chat first, and that chat's time.
    var platforms: [String] = []
    var newest: Date? = nil
    /// A chat in it waits on the user (an approval, a question): the Other Apps row shows the orange needs-you dot.
    var waiting = false
    /// [manual-order] A favorite project's group (first under Group By Project; its header shows a star).
    var favorite = false
    /// [sessions-layout] A project's summary row: its newest chat's title (`newest` is that chat's time) and the bots
    /// its chats belong to, the one with the newest chat first. Filled while it is folded too.
    var latestTitle: String? = nil
    var profiles: [String] = []
    /// [project-cards] A project with a chat whose bot is working in it now: its closed card shows the working dots.
    var working = false
    /// [project-cards] With a bot chip picked, every chat the project holds under all bots ("Otto · 3 of 12 chats");
    /// nil without a chip.
    var whole: Int? = nil
    /// [sessions-fresh] The first project under Group By Recent: how many projects the list has (its caption's "See
    /// All N"), and whether all of them are drawn ("Show Less"). nil and false on every other group.
    var projectsTotal: Int? = nil
    var projectsAll = false
}

nonisolated enum SessionGrouping {
    /// The web's `DAY_ROLLOVER_HOUR`.
    static let dayRolloverHour = 4

    static func groups(_ sessions: [SessionSummary], now: Date = Date(), calendar: Calendar = .current) -> [SessionGroup] {
        // Newest first; ties keep the gateway's order (stable).
        let ordered = sessions.enumerated().sorted { a, b in
            let ta = a.element.lastActive?.timeIntervalSince1970 ?? -.infinity
            let tb = b.element.lastActive?.timeIntervalSince1970 ?? -.infinity
            return ta != tb ? ta > tb : a.offset < b.offset
        }.map(\.element)
        var groups: [SessionGroup] = []
        var index: [String: Int] = [:]
        for session in ordered {
            let (id, title) = label(session.lastActive, now: now, calendar: calendar)
            if let at = index[id] { groups[at].sessions.append(session) } else {
                index[id] = groups.count
                groups.append(SessionGroup(id: id, title: title, sessions: [session]))
            }
        }
        return groups
    }

    /// The group a time falls in (`calendarBucket` + `sessionBucketLabel`, English labels from the web's
    /// `dateDivider` strings). The week starts on the calendar's `firstWeekday` (the locale's, as the web's
    /// `localeWeekStartDay`).
    static func label(_ date: Date?, now: Date, calendar: Calendar) -> (id: String, title: String) {
        guard let date, date.timeIntervalSince1970 > 0 else { return ("none", "Earlier") }
        let nominal = nominalDayStart(date, calendar: calendar)
        let today = nominalDayStart(now, calendar: calendar)
        let dayDiff = calendar.dateComponents([.day], from: nominal, to: today).day ?? 0
        if dayDiff <= 0 { return ("today", "Earlier today") }       // a time a little ahead reads as today
        if dayDiff == 1 { return ("yesterday", "Yesterday") }
        let weekStart = startOfWeek(today, calendar: calendar)
        if nominal >= weekStart { return ("this-week", "Earlier this week") }
        if let lastWeek = calendar.date(byAdding: .day, value: -7, to: weekStart), nominal >= lastWeek {
            return ("last-week", "Last week")
        }
        let d = calendar.dateComponents([.year, .month], from: nominal)
        let n = calendar.dateComponents([.year, .month], from: today)
        let sameYear = d.year == n.year
        if sameYear, d.month == n.month { return ("this-month", "Earlier this month") }
        let ym = "\(d.year ?? 0)-\(d.month ?? 0)"
        return sameYear
            ? ("m-\(ym)", ListTime.formatter("MMMM", calendar: calendar).string(from: nominal))
            : ("my-\(ym)", ListTime.formatter("MMMM y", calendar: calendar).string(from: nominal))
    }

    /// The start of the day `date` belongs to, a day running from 4 AM: Saturday 1 AM → the start of Friday.
    static func nominalDayStart(_ date: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: date.addingTimeInterval(-Double(dayRolloverHour) * 3600))
    }

    /// The start of the week holding the day that starts at `day`.
    static func startOfWeek(_ day: Date, calendar: Calendar) -> Date {
        let back = (calendar.component(.weekday, from: day) - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -back, to: day).map { calendar.startOfDay(for: $0) } ?? day
    }

    /// When the groups next change on their own: the coming 4 AM (the times on the rows change at midnight, which
    /// `UIApplication.significantTimeChangeNotification` covers).
    static func nextRollover(after now: Date, calendar: Calendar = .current) -> Date? {
        calendar.nextDate(after: now, matching: DateComponents(hour: dayRolloverHour, minute: 0, second: 0),
                          matchingPolicy: .nextTime)
    }
}

/// Which sessions the list shows (spec 02 §9.2).
nonisolated enum SessionList {
    /// Background runs (`tool`, `oneshot`, `subagent`, `kanban`) are hidden unless Show › Background Runs is on, which
    /// M1 doesn't have (`S/session-runs.ts:6-22`). Cron runs are never mixed into the date groups (spec 02 §6:
    /// `source == "cron"` or an id starting `cron_`); with a store they have the Other Apps page's "Scheduled Runs"
    /// section (`ChatSource.scheduled`).
    static let hiddenSources: Set<String> = ["tool", "oneshot", "subagent", "kanban", "cron"]

    static func visible(_ sessions: [SessionSummary]) -> [SessionSummary] {
        sessions.filter(isVisible)
    }

    static func isVisible(_ session: SessionSummary) -> Bool {
        if let source = session.source?.lowercased(), hiddenSources.contains(source) { return false }
        return !session.id.hasPrefix("cron_")
    }

    /// The Sessions tab badge: listed rows that are unread (hidden runs excluded, spec 02 §9.3).
    static func unreadCount(_ sessions: [SessionSummary]) -> Int {
        sessions.reduce(0) { $0 + (isVisible($1) && $1.unread ? 1 : 0) }
    }
}
