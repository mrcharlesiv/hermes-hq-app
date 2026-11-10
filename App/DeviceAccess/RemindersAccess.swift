// [device-access] Reminders for Device Access (docs/device-access.md): EventKit's own reminders, read within See and
// written within Add, Edit & Complete. This file is the main-actor side iOS asks permission through and
// DeviceAccessCenter calls; RemindersWork (nonisolated, off the main thread: EventKit's own calls are synchronous
// under the hood, same pattern as ContactsLookup) does the actual fetching and saving. EventKitAccess holds the one
// EKEventStore Reminders and Calendar share.

import EventKit
import Foundation

/// A value to send across a continuation that isn't itself `Sendable` (EventKit's own classes aren't marked so, but
/// are safe to read on whichever thread a completion handler calls back on).
nonisolated struct SendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// EventKit's own store and permission, shared by Reminders and Calendar (one store is enough).
nonisolated enum EventKitAccess {
    nonisolated(unsafe) static let store = EKEventStore()

    static func permission(for type: EKEntityType) -> DeviceAccessPermission {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: .allowed
        case .writeOnly: .limited
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    @concurrent static func requestReminders() async -> Bool {
        if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined { _ = try? await store.requestFullAccessToReminders() }
        // Raw EventKit status: `DeviceAccessPermission`'s Equatable conformance is main-actor isolated.
        let status = EKEventStore.authorizationStatus(for: .reminder)
        return status == .fullAccess || status == .writeOnly
    }

    @concurrent static func requestEvents() async -> Bool {
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined { _ = try? await store.requestFullAccessToEvents() }
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .fullAccess || status == .writeOnly
    }
}

enum RemindersAccess: DeviceAccessHandler {
    static let kind = DeviceAccess.Kind.reminders

    static var permission: DeviceAccessPermission { EventKitAccess.permission(for: .reminder) }

    static func requestPermission(turningOn key: String) async -> Bool { await EventKitAccess.requestReminders() }

    static var permissionNote: String? {
        guard EventKitAccess.permission(for: .reminder) == .limited else { return nil }
        return "\(AppIdentity.current.displayName) can add reminders but not see them. Turn on Full Access in \(DeviceWord.settingsApp) to let it see them."
    }

    static func answer(_ request: DeviceAccess.Request, scopes: Set<String>) async -> DeviceAccess.Answer {
        await RemindersWork.answer(request)
    }
}

/// Off the main thread: EventKit's fetch, save and calendar lookups are synchronous under the hood.
nonisolated enum RemindersWork {
    private static var store: EKEventStore { EventKitAccess.store }

    @concurrent static func answer(_ request: DeviceAccess.Request) async -> DeviceAccess.Answer {
        guard !Task.isCancelled else { return .failed("Cancelled.") }
        // Raw EventKit status, not `DeviceAccessPermission`: that type's Equatable conformance is main-actor
        // isolated (the project's default), and this work runs off the main actor.
        let status = EKEventStore.authorizationStatus(for: .reminder)
        guard status == .fullAccess || status == .writeOnly else { return .unavailable(DeviceAccess.notAllowedWords(.reminders)) }
        switch request.op {
        case "reminders.list": return await list(request, writeOnly: status == .writeOnly)
        case "reminders.create": return create(request)
        case "reminders.update": return update(request)
        default: return .unavailable(DeviceAccess.unknownWords)
        }
    }

    private static func list(_ request: DeviceAccess.Request, writeOnly: Bool) async -> DeviceAccess.Answer {
        guard !writeOnly else { return .unavailable("Reminders needs Full Access in \(DeviceWord.settingsApp) to be seen.") }
        let plan = DeviceAccess.reminderListPlan(request)
        var all = await fetch(store.predicateForIncompleteReminders(withDueDateStarting: plan.dueAfter, ending: plan.dueBefore, calendars: nil))
        if plan.includeCompleted {
            all += await fetch(store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: nil))
        }
        let matched = all.filter { reminder in
            if let search = plan.search, !DeviceAccess.reminderMatches(title: reminder.title ?? "", notes: reminder.notes, query: search) { return false }
            if let list = plan.list, (reminder.calendar?.title ?? "").caseInsensitiveCompare(list) != .orderedSame { return false }
            if let after = plan.dueAfter, let due = DeviceAccess.reminderDue(reminder.dueDateComponents)?.date, due < after { return false }
            if let before = plan.dueBefore, let due = DeviceAccess.reminderDue(reminder.dueDateComponents)?.date, due > before { return false }
            return true
        }
        let items = matched.prefix(plan.limit).map(wire)
        let lists = store.calendars(for: .reminder).map(\.title)
        return .list("reminders", items, more: matched.count > plan.limit, extra: ["lists": .array(lists.map { JSONValue.string($0) })])
    }

    private static func create(_ request: DeviceAccess.Request) -> DeviceAccess.Answer {
        guard let plan = DeviceAccess.reminderCreatePlan(request) else { return .failed("A reminder needs a “title.”") }
        let reminder = EKReminder(eventStore: store)
        reminder.title = plan.title
        reminder.notes = plan.notes
        reminder.priority = plan.priority.ekPriority
        if let due = plan.due {
            let components = DeviceAccess.reminderDueComponents(due, hasTime: plan.dueHasTime)
            reminder.dueDateComponents = components
            // iOS requires a start date alongside a due date, or saving fails.
            reminder.startDateComponents = components
        }
        guard let calendar = targetList(plan.list) ?? store.defaultCalendarForNewReminders() else {
            return .failed("There’s no reminders list to add to.")
        }
        reminder.calendar = calendar
        do { try store.save(reminder, commit: true) } catch { return .failed("The reminder couldn’t be saved.") }
        return .done(["reminder": wire(reminder)])
    }

    private static func update(_ request: DeviceAccess.Request) -> DeviceAccess.Answer {
        guard let plan = DeviceAccess.reminderUpdatePlan(request) else { return .failed("An “id” is needed.") }
        guard let reminder = store.calendarItem(withIdentifier: plan.id) as? EKReminder else { return .failed("That reminder wasn’t found.") }
        if let title = plan.title { reminder.title = title }
        if let notes = plan.notes { reminder.notes = notes }
        if let due = plan.due {
            if let date = due {
                let components = DeviceAccess.reminderDueComponents(date, hasTime: plan.dueHasTime)
                reminder.dueDateComponents = components
                if reminder.startDateComponents == nil { reminder.startDateComponents = components }
            } else {
                reminder.dueDateComponents = nil
            }
        }
        if let completed = plan.completed { reminder.isCompleted = completed }
        if let priority = plan.priority { reminder.priority = priority.ekPriority }
        do { try store.save(reminder, commit: true) } catch { return .failed("The reminder couldn’t be saved.") }
        return .done(["reminder": wire(reminder)])
    }

    private static func targetList(_ name: String?) -> EKCalendar? {
        guard let name else { return nil }
        return store.calendars(for: .reminder).first { $0.title.caseInsensitiveCompare(name) == .orderedSame && $0.allowsContentModifications }
    }

    /// `fetchReminders(matching:)` is completion-based; wrapped in a continuation (EventKit's own async work).
    /// `EKReminder` isn't `Sendable`; reading one on whichever thread EventKit calls back on is fine (its own
    /// contract), so the box just says so to the compiler.
    private static func fetch(_ predicate: NSPredicate) async -> [EKReminder] {
        let box: SendableBox<[EKReminder]> = await withCheckedContinuation { continuation in
            _ = store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: SendableBox(reminders ?? []))
            }
        }
        return box.value
    }

    private static func wire(_ reminder: EKReminder) -> JSONValue {
        DeviceAccess.reminderWire(id: reminder.calendarItemIdentifier, title: reminder.title ?? "", notes: reminder.notes,
                                  list: reminder.calendar?.title ?? "", due: DeviceAccess.reminderDue(reminder.dueDateComponents),
                                  priority: DeviceAccess.ReminderPriority(ekPriority: Int(reminder.priority)),
                                  completed: reminder.isCompleted, completedAt: reminder.completionDate)
    }
}
