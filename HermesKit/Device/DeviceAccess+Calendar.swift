// [device-access] Calendar for Device Access (docs/device-access.md), the parts that don't touch EventKit: each
// request's plan for calendar.list / calendar.create (clamped and defaulted per the docs), and formatting one event
// back. Pure Foundation; App/DeviceAccess/CalendarAccess.swift does the actual reading and writing.

import Foundation

nonisolated extension DeviceAccess {
    /// `calendar.list`'s plan.
    struct CalendarListPlan: Equatable, Sendable {
        var start: Date
        var end: Date
        var search: String?
        var calendar: String?
        var limit: Int
    }

    static func calendarListPlan(_ request: Request, now: Date = .now) -> CalendarListPlan {
        let start = request.date("start") ?? now
        let maxEnd = start.addingTimeInterval(62 * 86400)
        let end = min(request.date("end") ?? start.addingTimeInterval(7 * 86400), maxEnd)
        return CalendarListPlan(start: start, end: max(end, start), search: request.string("search"),
                                 calendar: request.string("calendar"), limit: min(max(request.int("limit") ?? 50, 1), 100))
    }

    /// `calendar.create`'s plan; nil when there's no `title` or no `start`.
    struct CalendarCreatePlan: Equatable, Sendable {
        var title: String
        var start: Date
        var end: Date
        var allDay: Bool
        var location: String?
        var notes: String?
        var calendar: String?
    }

    static func calendarCreatePlan(_ request: Request) -> CalendarCreatePlan? {
        guard let title = request.string("title", max: 200), let start = request.date("start") else { return nil }
        // A date with no time of day makes an all-day event, unless the bot says otherwise.
        let allDay = request.bool("all_day") ?? !request.hasTime("start")
        let end = request.date("end") ?? (allDay ? start : start.addingTimeInterval(3600))
        return CalendarCreatePlan(title: title, start: start, end: max(end, start), allDay: allDay,
                                   location: request.string("location", max: 500), notes: request.string("notes", max: 2000),
                                   calendar: request.string("calendar"))
    }

    /// Case-insensitive: `query` is found in the title, the location or the notes (`calendar.list`'s `search`).
    static func calendarMatches(title: String, location: String?, notes: String?, query: String) -> Bool {
        let q = query.lowercased()
        return title.lowercased().contains(q) || (location?.lowercased().contains(q) ?? false) || (notes?.lowercased().contains(q) ?? false)
    }

    /// `calendar.list`'s own rule: notes cut to 500 characters.
    static func calendarNotes(_ notes: String?) -> String? { notes.map { String($0.prefix(500)) } }

    /// One event as the bot reads it (`E` in docs/device-access.md).
    static func calendarEventWire(id: String, title: String, start: Date, end: Date, allDay: Bool, location: String?,
                                   notes: String?, calendar: String) -> JSONValue {
        var out: [String: JSONValue] = ["id": .string(id), "title": .string(title), "start": .string(DeviceAccess.stamp(start)),
                                         "end": .string(DeviceAccess.stamp(end)), "all_day": .bool(allDay), "calendar": .string(calendar)]
        if let location, !location.isEmpty { out["location"] = .string(location) }
        if let notes = calendarNotes(notes), !notes.isEmpty { out["notes"] = .string(notes) }
        return .object(out)
    }
}
