// [device-access] Calendar for Device Access: the pure plans and shapes (HermesKit/Device/DeviceAccess+Calendar.swift),
// and a live round trip against the Simulator's own Calendar when this Mac/Simulator has granted it (skipped
// otherwise, so it never fails on a Simulator without Calendar access).

import EventKit
import Foundation
import Testing
@testable import HermesHQNative

@MainActor struct DeviceAccessCalendarTests {
    private let id = String(repeating: "a", count: 32)

    private func request(_ op: String, _ args: [String: JSONValue] = [:]) -> DeviceAccess.Request {
        DeviceAccess.Request(id: id, op: op, args: args)
    }

    @Test func listPlanDefaultsAndClampsTheRange() throws {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let plan = DeviceAccess.calendarListPlan(request("calendar.list"), now: now)
        #expect(plan.start == now && plan.end == now.addingTimeInterval(7 * 86400))
        #expect(plan.search == nil && plan.calendar == nil && plan.limit == 50)

        let tooFar = DeviceAccess.calendarListPlan(request("calendar.list", ["start": "2026-11-01", "end": "2027-06-01"]), now: now)
        let start = try #require(DeviceAccess.date("2026-11-01"))
        #expect(tooFar.end <= start.date.addingTimeInterval(62 * 86400), "end is clamped to 62 days past start")

        let clamped = DeviceAccess.calendarListPlan(request("calendar.list", ["limit": 500]), now: now)
        #expect(clamped.limit == 100)
        let floor = DeviceAccess.calendarListPlan(request("calendar.list", ["limit": 0]), now: now)
        #expect(floor.limit == 1)
    }

    @Test func createPlanNeedsATitleAndAStart() throws {
        #expect(DeviceAccess.calendarCreatePlan(request("calendar.create")) == nil)
        #expect(DeviceAccess.calendarCreatePlan(request("calendar.create", ["title": "Standup"])) == nil, "needs a start")

        let dayOnly = try #require(DeviceAccess.calendarCreatePlan(request("calendar.create", ["title": "Trip", "start": "2026-11-01"])))
        #expect(dayOnly.allDay && dayOnly.end == dayOnly.start, "a date with no time of day defaults to all-day, one day")

        let withTime = try #require(DeviceAccess.calendarCreatePlan(request("calendar.create", ["title": "Call", "start": "2026-11-01T09:00"])))
        #expect(!withTime.allDay && withTime.end == withTime.start.addingTimeInterval(3600), "a default hour-long end")

        let explicit = try #require(DeviceAccess.calendarCreatePlan(request("calendar.create", ["title": "Call", "start": "2026-11-01T09:00",
                                                                                                  "end": "2026-11-01T10:30", "all_day": false,
                                                                                                  "location": "HQ", "calendar": "Work"])))
        #expect(explicit.end == (try #require(DeviceAccess.date("2026-11-01T10:30"))).date)
        #expect(explicit.location == "HQ" && explicit.calendar == "Work")
    }

    @Test func matchesTitleLocationOrNotesCaseInsensitively() {
        #expect(DeviceAccess.calendarMatches(title: "Standup", location: nil, notes: nil, query: "stand"))
        #expect(DeviceAccess.calendarMatches(title: "Call", location: "HQ Office", notes: nil, query: "hq"))
        #expect(DeviceAccess.calendarMatches(title: "Call", location: nil, notes: "bring the deck", query: "DECK"))
        #expect(!DeviceAccess.calendarMatches(title: "Call", location: "HQ", notes: "deck", query: "milk"))
    }

    @Test func notesAreCutTo500Characters() {
        #expect(DeviceAccess.calendarNotes(nil) == nil)
        #expect(DeviceAccess.calendarNotes("short") == "short")
        let long = String(repeating: "x", count: 600)
        #expect(DeviceAccess.calendarNotes(long)?.count == 500)
    }

    @Test func wireCarriesOnlyWhatsThere() throws {
        let start = try #require(DeviceAccess.date("2026-11-01T09:00"))
        let end = try #require(DeviceAccess.date("2026-11-01T10:00"))
        let bare = DeviceAccess.calendarEventWire(id: "1", title: "Call", start: start.date, end: end.date, allDay: false,
                                                   location: nil, notes: nil, calendar: "Home")
        let body = try #require(bare.object)
        #expect(body["id"] == "1" && body["title"] == "Call" && body["calendar"] == "Home" && body["all_day"] == false)
        #expect(body["location"] == nil && body["notes"] == nil)

        let full = DeviceAccess.calendarEventWire(id: "1", title: "Call", start: start.date, end: end.date, allDay: false,
                                                    location: "HQ", notes: "bring the deck", calendar: "Home")
        #expect(full.object?["location"] == "HQ" && full.object?["notes"] == "bring the deck")
    }

    // MARK: Live (the Simulator's own Calendar; skipped unless this run has full access)

    @Test func liveCreateAndListARealEvent() async throws {
        guard CalendarAccess.permission == .allowed else { return }   // no grant on this Simulator: nothing to verify
        let title = "HQ test \(UUID().uuidString.prefix(8))"

        let create = await CalendarAccess.answer(request("calendar.create", ["title": .string(title), "start": "2026-11-01T09:00",
                                                                               "end": "2026-11-01T09:30"]), scopes: ["write"])
        #expect(create.status == .done)
        let createdId = try #require(create.result["event"]?.object?["id"]?.string)
        #expect(create.result["event"]?.object?["title"] == .string(title))

        defer {
            // Clean up directly through EventKit: the bot contract has no delete op.
            if let event = EventKitAccess.store.event(withIdentifier: createdId) {
                try? EventKitAccess.store.remove(event, span: .thisEvent, commit: true)
            }
        }

        let list = await CalendarAccess.answer(request("calendar.list", ["start": "2026-11-01", "end": "2026-11-02",
                                                                           "search": .string(title)]), scopes: ["read"])
        #expect(list.status == .done)
        let foundIt = list.result["events"]?.array?.contains { $0.object?["id"]?.string == createdId } ?? false
        #expect(foundIt)
    }
}
