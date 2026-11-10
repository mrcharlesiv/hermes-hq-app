// [device-access] Reminders for Device Access: the pure plans and shapes (HermesKit/Device/DeviceAccess+Reminders.swift),
// and a live round trip against the Simulator's own Reminders when this Mac/Simulator has granted it (skipped
// otherwise, so it never fails on a Simulator without Reminders access).

import EventKit
import Foundation
import Testing
@testable import HermesHQNative

@MainActor struct DeviceAccessRemindersTests {
    private let id = String(repeating: "a", count: 32)

    private func request(_ op: String, _ args: [String: JSONValue] = [:]) -> DeviceAccess.Request {
        DeviceAccess.Request(id: id, op: op, args: args)
    }

    @Test func priorityBothWays() {
        #expect(DeviceAccess.ReminderPriority(ekPriority: 1) == .high && DeviceAccess.ReminderPriority(ekPriority: 4) == .high)
        #expect(DeviceAccess.ReminderPriority(ekPriority: 5) == .medium)
        #expect(DeviceAccess.ReminderPriority(ekPriority: 6) == .low && DeviceAccess.ReminderPriority(ekPriority: 9) == .low)
        #expect(DeviceAccess.ReminderPriority(ekPriority: 0) == .none && DeviceAccess.ReminderPriority(ekPriority: 42) == .none)
        #expect(DeviceAccess.ReminderPriority.high.ekPriority == 1 && DeviceAccess.ReminderPriority.medium.ekPriority == 5)
        #expect(DeviceAccess.ReminderPriority.low.ekPriority == 9 && DeviceAccess.ReminderPriority.none.ekPriority == 0)
    }

    @Test func listPlanDefaultsAndClamps() {
        let plan = DeviceAccess.reminderListPlan(request("reminders.list"))
        #expect(plan.search == nil && plan.list == nil && !plan.includeCompleted && plan.limit == 50)
        let clamped = DeviceAccess.reminderListPlan(request("reminders.list", ["limit": 500]))
        #expect(clamped.limit == 100)
        let floor = DeviceAccess.reminderListPlan(request("reminders.list", ["limit": 0]))
        #expect(floor.limit == 1)
        let withRange = DeviceAccess.reminderListPlan(request("reminders.list", ["search": "milk", "include_completed": true,
                                                                                  "due_after": "2026-11-01", "due_before": "2026-11-02"]))
        #expect(withRange.search == "milk" && withRange.includeCompleted && withRange.dueAfter != nil && withRange.dueBefore != nil)
    }

    @Test func createPlanNeedsATitle() {
        #expect(DeviceAccess.reminderCreatePlan(request("reminders.create")) == nil)
        let plan = DeviceAccess.reminderCreatePlan(request("reminders.create", ["title": "Milk", "due": "2026-11-01T09:00", "priority": "high"]))
        #expect(plan?.title == "Milk" && plan?.dueHasTime == true && plan?.priority == .high)
        let noPriority = DeviceAccess.reminderCreatePlan(request("reminders.create", ["title": "Eggs"]))
        #expect(noPriority?.priority == DeviceAccess.ReminderPriority.none, "no “priority” defaults to none, not left unset")
    }

    @Test func updatePlanTellsClearingADueDateFromLeavingItAlone() throws {
        #expect(DeviceAccess.reminderUpdatePlan(request("reminders.update")) == nil, "needs an id")
        let leaveAlone = try #require(DeviceAccess.reminderUpdatePlan(request("reminders.update", ["id": "x", "completed": true])))
        #expect(leaveAlone.due == nil)
        let clear = try #require(DeviceAccess.reminderUpdatePlan(request("reminders.update", ["id": "x", "due": JSONValue.null])))
        #expect(clear.due != nil && clear.due! == nil, "due: null clears it")
        let set = try #require(DeviceAccess.reminderUpdatePlan(request("reminders.update", ["id": "x", "due": "2026-11-01"])))
        #expect(set.due != nil && set.due! != nil)
    }

    @Test func dueRoundTripsThroughDateComponents() throws {
        let zone = try #require(TimeZone(identifier: "America/Chicago"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let withTime = try #require(DeviceAccess.date("2026-11-01 09:30", calendar: calendar))
        let components = DeviceAccess.reminderDueComponents(withTime.date, hasTime: true, calendar: calendar)
        #expect(components.hour == 9 && components.minute == 30)
        let back = try #require(DeviceAccess.reminderDue(components, calendar: calendar))
        #expect(back.hasTime && back.date == withTime.date)

        let dayOnly = try #require(DeviceAccess.date("2026-11-01", calendar: calendar))
        let dayComponents = DeviceAccess.reminderDueComponents(dayOnly.date, hasTime: false, calendar: calendar)
        #expect(dayComponents.hour == nil)
        let backDay = try #require(DeviceAccess.reminderDue(dayComponents, calendar: calendar))
        #expect(!backDay.hasTime)

        #expect(DeviceAccess.reminderDue(nil) == nil)
    }

    @Test func matchesTitleOrNotesCaseInsensitively() {
        #expect(DeviceAccess.reminderMatches(title: "Buy Milk", notes: nil, query: "milk"))
        #expect(DeviceAccess.reminderMatches(title: "Errands", notes: "Pick up Milk", query: "MILK"))
        #expect(!DeviceAccess.reminderMatches(title: "Errands", notes: "Dry cleaning", query: "milk"))
    }

    @Test func wireCarriesOnlyWhatsThere() throws {
        let noDue = DeviceAccess.reminderWire(id: "1", title: "Milk", notes: nil, list: "Home", due: nil, priority: .high, completed: false, completedAt: nil)
        let body = try #require(noDue.object)
        #expect(body["id"] == "1" && body["title"] == "Milk" && body["list"] == "Home" && body["priority"] == "high")
        #expect(body["due"] == nil && body["notes"] == nil && body["completed_at"] == nil)

        let withDay = try #require(DeviceAccess.date("2026-11-01"))
        let dayWire = DeviceAccess.reminderWire(id: "1", title: "Milk", notes: "2%", list: "Home", due: (withDay.date, false),
                                                 priority: .none, completed: true, completedAt: withDay.date)
        let dayBody = try #require(dayWire.object)
        #expect(dayBody["due"] == .string(DeviceAccess.day(withDay.date)))
        #expect(dayBody["notes"] == "2%" && dayBody["completed"] == true && dayBody["completed_at"] != nil)
    }

    // MARK: Live (the Simulator's own Reminders; skipped unless this run has full access)

    @Test func liveCreateListUpdateAndCleanUpARealReminder() async throws {
        guard RemindersAccess.permission == .allowed else { return }   // no grant on this Simulator: nothing to verify
        let title = "HQ test \(UUID().uuidString.prefix(8))"

        let create = await RemindersAccess.answer(request("reminders.create", ["title": .string(title), "priority": "low"]), scopes: ["write"])
        #expect(create.status == .done)
        let createdId = try #require(create.result["reminder"]?.object?["id"]?.string)
        #expect(create.result["reminder"]?.object?["title"] == .string(title))

        defer {
            // Clean up directly through EventKit: the bot contract has no delete op.
            if let reminder = EventKitAccess.store.calendarItem(withIdentifier: createdId) as? EKReminder {
                try? EventKitAccess.store.remove(reminder, commit: true)
            }
        }

        let list = await RemindersAccess.answer(request("reminders.list", ["search": .string(title)]), scopes: ["read"])
        #expect(list.status == .done)
        let foundIt = list.result["reminders"]?.array?.contains { $0.object?["id"]?.string == createdId } ?? false
        #expect(foundIt)

        let update = await RemindersAccess.answer(request("reminders.update", ["id": .string(createdId), "completed": true]), scopes: ["write"])
        #expect(update.status == .done)
        #expect(update.result["reminder"]?.object?["completed"] == true)
    }
}
