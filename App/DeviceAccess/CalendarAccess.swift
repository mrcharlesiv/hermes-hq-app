// [device-access] Calendar for Device Access (docs/device-access.md): EventKit's own events, read within See Events
// and added (never changed or deleted) within Add Events. This file is the main-actor side iOS asks permission
// through and DeviceAccessCenter calls; CalendarWork (nonisolated, off the main thread: EventKit's own calls are
// synchronous under the hood) does the actual fetching and saving. EventKitAccess
// (App/DeviceAccess/RemindersAccess.swift) holds the one EKEventStore Reminders and Calendar share.

import EventKit
import Foundation

enum CalendarAccess: DeviceAccessHandler {
    static let kind = DeviceAccess.Kind.calendar

    static var permission: DeviceAccessPermission { EventKitAccess.permission(for: .event) }

    static func requestPermission(turningOn key: String) async -> Bool { await EventKitAccess.requestEvents() }

    static var permissionNote: String? {
        guard EventKitAccess.permission(for: .event) == .limited else { return nil }
        return "\(AppIdentity.current.displayName) can add events but not see them. Turn on Full Access in \(DeviceWord.settingsApp) to let it see them."
    }

    static func answer(_ request: DeviceAccess.Request, scopes: Set<String>) async -> DeviceAccess.Answer {
        await CalendarWork.answer(request)
    }
}

/// Off the main thread: EventKit's fetch, save and calendar lookups are synchronous under the hood.
nonisolated enum CalendarWork {
    private static var store: EKEventStore { EventKitAccess.store }

    @concurrent static func answer(_ request: DeviceAccess.Request) async -> DeviceAccess.Answer {
        guard !Task.isCancelled else { return .failed("Cancelled.") }
        // Raw EventKit status, not `DeviceAccessPermission`: that type's Equatable conformance is main-actor
        // isolated (the project's default), and this work runs off the main actor.
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess || status == .writeOnly else { return .unavailable(DeviceAccess.notAllowedWords(.calendar)) }
        switch request.op {
        case "calendar.list": return list(request, writeOnly: status == .writeOnly)
        case "calendar.create": return create(request)
        default: return .unavailable(DeviceAccess.unknownWords)
        }
    }

    private static func list(_ request: DeviceAccess.Request, writeOnly: Bool) -> DeviceAccess.Answer {
        guard !writeOnly else { return .unavailable("Calendar needs Full Access in \(DeviceWord.settingsApp) to be seen.") }
        let plan = DeviceAccess.calendarListPlan(request)
        let predicate = store.predicateForEvents(withStart: plan.start, end: plan.end, calendars: nil)
        let events = store.events(matching: predicate)
        let matched = events.filter { event in
            if let search = plan.search, !DeviceAccess.calendarMatches(title: event.title ?? "", location: event.location, notes: event.notes, query: search) { return false }
            if let name = plan.calendar, (event.calendar?.title ?? "").caseInsensitiveCompare(name) != .orderedSame { return false }
            return true
        }
        let items = matched.prefix(plan.limit).map(wire)
        let calendars = store.calendars(for: .event).map(\.title)
        return .list("events", items, more: matched.count > plan.limit, extra: ["calendars": .array(calendars.map { JSONValue.string($0) })])
    }

    private static func create(_ request: DeviceAccess.Request) -> DeviceAccess.Answer {
        guard let plan = DeviceAccess.calendarCreatePlan(request) else { return .failed("An event needs a “title” and a “start.”") }
        let event = EKEvent(eventStore: store)
        event.title = plan.title
        event.startDate = plan.start
        event.endDate = plan.end
        event.isAllDay = plan.allDay
        event.location = plan.location
        event.notes = plan.notes
        guard let calendar = targetCalendar(plan.calendar) ?? store.defaultCalendarForNewEvents else {
            return .failed("There’s no calendar to add to.")
        }
        event.calendar = calendar
        do { try store.save(event, span: .thisEvent, commit: true) } catch { return .failed("The event couldn’t be saved.") }
        return .done(["event": wire(event)])
    }

    private static func targetCalendar(_ name: String?) -> EKCalendar? {
        guard let name else { return nil }
        return store.calendars(for: .event).first { $0.title.caseInsensitiveCompare(name) == .orderedSame && $0.allowsContentModifications }
    }

    private static func wire(_ event: EKEvent) -> JSONValue {
        DeviceAccess.calendarEventWire(id: event.eventIdentifier, title: event.title ?? "", start: event.startDate, end: event.endDate,
                                        allDay: event.isAllDay, location: event.location, notes: event.notes, calendar: event.calendar?.title ?? "")
    }
}
