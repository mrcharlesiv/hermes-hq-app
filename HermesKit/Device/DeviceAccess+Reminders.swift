// [device-access] Reminders for Device Access (docs/device-access.md), the parts that don't touch EventKit: each
// request's plan (clamped and defaulted per the docs), a reminder's priority both ways (EventKit's own 1-9 scale),
// and a due date read back from EventKit's own DateComponents. Pure Foundation, so it's tested without EventKit;
// App/DeviceAccess/RemindersAccess.swift does the actual reading and writing.

import Foundation

nonisolated extension DeviceAccess {
    /// A reminder's priority as the bot reads it. EventKit's own scale (RFC 5545) is 1-9: 1-4 high, 5 medium, 6-9
    /// low, 0 none; and back the other way.
    enum ReminderPriority: String, Sendable {
        case high, medium, low, none

        init(ekPriority: Int) {
            switch ekPriority {
            case 1...4: self = .high
            case 5: self = .medium
            case 6...9: self = .low
            default: self = .none
            }
        }

        var ekPriority: Int {
            switch self {
            case .high: 1
            case .medium: 5
            case .low: 9
            case .none: 0
            }
        }
    }

    /// `reminders.list`'s own plan, clamped to what docs/device-access.md promises.
    struct ReminderListPlan: Equatable, Sendable {
        var search: String?
        var list: String?
        var includeCompleted: Bool
        var dueAfter: Date?
        var dueBefore: Date?
        var limit: Int
    }

    static func reminderListPlan(_ request: Request) -> ReminderListPlan {
        ReminderListPlan(search: request.string("search"), list: request.string("list"),
                          includeCompleted: request.bool("include_completed") ?? false,
                          dueAfter: request.date("due_after"), dueBefore: request.date("due_before"),
                          limit: min(max(request.int("limit") ?? 50, 1), 100))
    }

    /// `reminders.create`'s plan; nil when there's no `title` to make one from.
    struct ReminderCreatePlan: Equatable, Sendable {
        var title: String
        var notes: String?
        var due: Date?
        var dueHasTime: Bool
        var list: String?
        var priority: ReminderPriority
    }

    static func reminderCreatePlan(_ request: Request) -> ReminderCreatePlan? {
        guard let title = request.string("title", max: 200) else { return nil }
        return ReminderCreatePlan(title: title, notes: request.string("notes", max: 2000),
                                   due: request.date("due"), dueHasTime: request.hasTime("due"),
                                   list: request.string("list"),
                                   priority: request.string("priority").flatMap { ReminderPriority(rawValue: $0) } ?? .none)
    }

    /// `reminders.update`'s plan; nil when there's no `id`. `due` is `.some(nil)` when the bot sent `due: null` to
    /// clear it, and plain `nil` when `due` wasn't mentioned at all (leave it alone).
    struct ReminderUpdatePlan: Equatable, Sendable {
        var id: String
        var title: String?
        var notes: String?
        var due: Date??
        var dueHasTime: Bool
        var completed: Bool?
        var priority: ReminderPriority?
    }

    static func reminderUpdatePlan(_ request: Request) -> ReminderUpdatePlan? {
        guard let id = request.string("id", max: 200) else { return nil }
        var due: Date??
        if let raw = request.args["due"] { due = raw.isNull ? .some(nil) : .some(request.date("due")) }
        return ReminderUpdatePlan(id: id, title: request.string("title", max: 200), notes: request.string("notes", max: 2000),
                                   due: due, dueHasTime: request.hasTime("due"), completed: request.bool("completed"),
                                   priority: request.string("priority").flatMap { ReminderPriority(rawValue: $0) })
    }

    /// EventKit hands a due date back as plain `DateComponents` (not an EventKit type): the moment, and whether a
    /// time of day was set on it (an hour component means one was).
    static func reminderDue(_ components: DateComponents?, calendar: Calendar = .current) -> (date: Date, hasTime: Bool)? {
        guard let components, let date = calendar.date(from: components) else { return nil }
        return (date, components.hour != nil)
    }

    /// The components to hand back to EventKit for a due date: day only, or day and time of day.
    static func reminderDueComponents(_ date: Date, hasTime: Bool, calendar: Calendar = .current) -> DateComponents {
        var units: Set<Calendar.Component> = [.year, .month, .day]
        if hasTime { units.formUnion([.hour, .minute, .second]) }
        return calendar.dateComponents(units, from: date)
    }

    /// Case-insensitive: `query` is found in the title or the notes (`reminders.list`'s `search`).
    static func reminderMatches(title: String, notes: String?, query: String) -> Bool {
        let q = query.lowercased()
        return title.lowercased().contains(q) || (notes?.lowercased().contains(q) ?? false)
    }

    /// One reminder as the bot reads it (`R` in docs/device-access.md).
    static func reminderWire(id: String, title: String, notes: String?, list: String, due: (date: Date, hasTime: Bool)?,
                              priority: ReminderPriority, completed: Bool, completedAt: Date?) -> JSONValue {
        var out: [String: JSONValue] = ["id": .string(id), "title": .string(title), "list": .string(list),
                                         "priority": .string(priority.rawValue), "completed": .bool(completed)]
        if let notes, !notes.isEmpty { out["notes"] = .string(notes) }
        if let due { out["due"] = .string(due.hasTime ? DeviceAccess.stamp(due.date) : DeviceAccess.day(due.date)) }
        if let completedAt { out["completed_at"] = .string(DeviceAccess.stamp(completedAt)) }
        return .object(out)
    }
}
