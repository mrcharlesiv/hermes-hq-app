// [device-access] Alarms & Timers for Device Access: the pure parts (HermesKit/Device/DeviceAccess+Alarms.swift) that
// don't touch AlarmKit, and a live round trip against the Simulator's own AlarmKit when this run is authorized
// (skipped otherwise, so it never fails on a Simulator without that grant). AlarmKit itself isn't on Mac Catalyst.

import Foundation
import Testing
@testable import HermesHQNative

@MainActor struct DeviceAccessAlarmsTests {
    private let id = String(repeating: "a", count: 32)

    private func request(_ op: String, _ args: [String: JSONValue] = [:]) -> DeviceAccess.Request {
        DeviceAccess.Request(id: id, op: op, args: args)
    }

    @Test func timeParsesHourMinuteAndRejectsOutOfRange() {
        #expect(DeviceAccess.alarmTime("07:30").map { "\($0.hour):\($0.minute)" } == "7:30")
        #expect(DeviceAccess.alarmTime("7:5").map { "\($0.hour):\($0.minute)" } == "7:5")
        #expect(DeviceAccess.alarmTime("24:00") == nil && DeviceAccess.alarmTime("07:60") == nil)
        #expect(DeviceAccess.alarmTime("0730") == nil && DeviceAccess.alarmTime("") == nil)
        #expect(DeviceAccess.alarmTimeString(hour: 7, minute: 5) == "07:05")
    }

    @Test func weekdayTokensAreCaseInsensitiveAndPrefixed() {
        #expect(DeviceAccess.alarmWeekday("mon") == .monday && DeviceAccess.alarmWeekday("Monday") == .monday)
        #expect(DeviceAccess.alarmWeekday("SAT") == .saturday && DeviceAccess.alarmWeekday("sun") == .sunday)
        #expect(DeviceAccess.alarmWeekday("xyz") == nil)
        // Audit 09-28: only a day's own names, not any word starting like one.
        #expect(DeviceAccess.alarmWeekday("monthly") == nil && DeviceAccess.alarmWeekday("sunny") == nil)
        #expect(DeviceAccess.alarmWeekday("Thurs") == .thursday && DeviceAccess.alarmWeekday("tues") == .tuesday)
    }

    @Test func repeatWordsNameTheirDays() {
        #expect(DeviceAccess.alarmRepeatTokens("everyday") == ["mon", "tue", "wed", "thu", "fri", "sat", "sun"])
        #expect(DeviceAccess.alarmRepeatTokens("Daily")?.count == 7)
        #expect(DeviceAccess.alarmRepeatTokens("weekdays") == ["mon", "tue", "wed", "thu", "fri"])
        #expect(DeviceAccess.alarmRepeatTokens("weekends") == ["sat", "sun"])
        #expect(DeviceAccess.alarmRepeatTokens("Friday") == ["fri"])
        #expect(DeviceAccess.alarmRepeatTokens("monthly") == nil)
    }

    @Test func calendarWeekdayNumbersMapOntoLocaleWeekday() {
        let expected: [Locale.Weekday] = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
        for n in 1...7 { #expect(DeviceAccess.alarmWeekday(calendarComponent: n) == expected[n - 1]) }
    }

    @Test func setPlanNeedsATimeAndKeepsOnlyRealDays() {
        #expect(DeviceAccess.alarmSetPlan(request("alarms.set")) == nil)
        #expect(DeviceAccess.alarmSetPlan(request("alarms.set", ["time": "25:00"])) == nil)
        let bare = DeviceAccess.alarmSetPlan(request("alarms.set", ["time": "07:30"]))
        #expect(bare?.hour == 7 && bare?.minute == 30 && bare?.label == nil && bare?.rawRepeat == [] && bare?.repeatDays == [])
        let plan = DeviceAccess.alarmSetPlan(request("alarms.set", ["time": "7:30", "label": "Wake", "repeat": ["mon", "tue", "nope"]]))
        #expect(plan?.label == "Wake" && plan?.rawRepeat == ["mon", "tue"] && plan?.repeatDays == [.monday, .tuesday])
        #expect(plan?.unknownRepeat == ["nope"])
        // Said back as the days themselves, in the week's order, once each.
        let words = DeviceAccess.alarmSetPlan(request("alarms.set", ["time": "07:30", "repeat": ["Sunday", "weekdays", "mon"]]))
        #expect(words?.rawRepeat == ["mon", "tue", "wed", "thu", "fri", "sun"] && words?.unknownRepeat == [])
        #expect(DeviceAccess.alarmSetPlan(request("alarms.set", ["time": "07:30", "repeat": ["monthly"]]))?.repeatDays == [])
    }

    @Test func timerPlanNeedsSecondsInRange() {
        #expect(DeviceAccess.alarmTimerPlan(request("alarms.timer")) == nil)
        #expect(DeviceAccess.alarmTimerPlan(request("alarms.timer", ["seconds": 0])) == nil)
        #expect(DeviceAccess.alarmTimerPlan(request("alarms.timer", ["seconds": 86401])) == nil)
        let plan = DeviceAccess.alarmTimerPlan(request("alarms.timer", ["seconds": 600, "label": "Eggs"]))
        #expect(plan?.seconds == 600 && plan?.label == "Eggs")
    }

    @Test func nextFireNonRepeatingPicksTodayOrTomorrow() {
        let calendar = Calendar.current
        let now = Date()
        let soonComponents = calendar.dateComponents([.hour, .minute], from: calendar.date(byAdding: .minute, value: 3, to: now)!)
        let soon = DeviceAccess.nextAlarmFire(hour: soonComponents.hour!, minute: soonComponents.minute!, days: [], now: now, calendar: calendar)
        #expect(soon != nil && soon! > now && soon!.timeIntervalSince(now) < 3600, "a time still ahead today fires today")

        let agoComponents = calendar.dateComponents([.hour, .minute], from: calendar.date(byAdding: .minute, value: -3, to: now)!)
        let tomorrow = DeviceAccess.nextAlarmFire(hour: agoComponents.hour!, minute: agoComponents.minute!, days: [], now: now, calendar: calendar)
        #expect(tomorrow != nil && tomorrow! > now && tomorrow!.timeIntervalSince(now) > 23 * 3600, "a time already past today fires tomorrow")
    }

    @Test func nextFireRepeatingOnlyLandsOnAGivenWeekday() {
        let calendar = Calendar.current
        let now = Date()
        let tomorrowNumber = (calendar.component(.weekday, from: now) % 7) + 1
        let tomorrow = DeviceAccess.alarmWeekday(calendarComponent: tomorrowNumber)
        let fire = DeviceAccess.nextAlarmFire(hour: 9, minute: 0, days: [tomorrow], now: now, calendar: calendar)
        #expect(fire != nil)
        if let fire { #expect(fire > now && calendar.component(.weekday, from: fire) == tomorrowNumber) }
    }

    @Test func setWireShapesTheAnswer() throws {
        let next = try #require(DeviceAccess.date("2026-11-02T07:30"))
        let wire = DeviceAccess.alarmSetWire(id: "a1", hour: 7, minute: 30, label: "Wake", rawRepeat: ["mon", "tue"], next: next.date)
        let alarm = try #require(wire["alarm"]?.object)
        #expect(alarm["id"] == "a1" && alarm["time"] == "07:30" && alarm["label"] == "Wake")
        #expect(alarm["repeat"] == .array(["mon", "tue"]))
        #expect(alarm["next"] == .string(DeviceAccess.stamp(next.date)))
    }

    @Test func setWireUsesAnEmptyLabelWhenNoneWasGiven() throws {
        let next = try #require(DeviceAccess.date("2026-11-02T07:30"))
        let wire = DeviceAccess.alarmSetWire(id: "a1", hour: 7, minute: 30, label: nil, rawRepeat: [], next: next.date)
        #expect(wire["alarm"]?.object?["label"] == "")
    }

    @Test func timerWireShapesTheAnswer() throws {
        let ends = try #require(DeviceAccess.date("2026-11-02T07:30"))
        let wire = DeviceAccess.alarmTimerWire(id: "t1", label: nil, ends: ends.date)
        let timer = try #require(wire["timer"]?.object)
        #expect(timer["id"] == "t1" && timer["label"] == "" && timer["ends"] == .string(DeviceAccess.stamp(ends.date)))
    }

    @Test func listItemWireOmitsEmptyRepeatAndEnds() throws {
        let item = DeviceAccess.alarmListItemWire(id: "a1", kind: "alarm", time: "07:30", ends: nil, label: "Wake", rawRepeat: [], state: "scheduled")
        let body = try #require(item.object)
        #expect(body["id"] == "a1" && body["kind"] == "alarm" && body["time"] == "07:30" && body["state"] == "scheduled")
        #expect(body["repeat"] == nil && body["ends"] == nil)

        let withRepeat = DeviceAccess.alarmListItemWire(id: "a1", kind: "alarm", time: "07:30", ends: nil, label: "Wake", rawRepeat: ["mon"], state: "scheduled")
        #expect(withRepeat.object?["repeat"] == .array(["mon"]))
    }

    @Test func storeRemembersPrunesAndForgets() throws {
        let defaults = try #require(UserDefaults(suiteName: "device-access-alarms-\(UUID().uuidString)"))
        #expect(DeviceAccess.AlarmStore.load(defaults).isEmpty)
        let wake = DeviceAccess.AlarmRecord(kind: "alarm", label: "Wake", time: "07:30", ends: nil, rawRepeat: ["mon"])
        DeviceAccess.AlarmStore.remember("a1", wake, defaults)
        DeviceAccess.AlarmStore.remember("a2", .init(kind: "timer", label: "Eggs", time: nil, ends: Date(), rawRepeat: []), defaults)
        #expect(DeviceAccess.AlarmStore.load(defaults)["a1"] == wake)

        let kept = DeviceAccess.AlarmStore.prune(keeping: ["a1"], defaults)
        #expect(kept.count == 1 && kept["a1"] != nil && kept["a2"] == nil, "AlarmKit no longer having a2 drops it")
        #expect(DeviceAccess.AlarmStore.load(defaults).count == 1)

        DeviceAccess.AlarmStore.forget("a1", defaults)
        #expect(DeviceAccess.AlarmStore.load(defaults).isEmpty)
    }

    // MARK: Live (the Simulator's own AlarmKit; skipped unless this run is authorized)

    #if !targetEnvironment(macCatalyst)
    @Test func liveSetATimerListItAndCancelIt() async throws {
        guard AlarmsAccess.permission == .allowed else { return }   // not authorized on this Simulator: nothing to verify
        let label = "HQ test \(UUID().uuidString.prefix(8))"

        let timer = await AlarmsAccess.answer(request("alarms.timer", ["seconds": 120, "label": .string(label)]), scopes: [])
        #expect(timer.status == .done)
        let timerId = try #require(timer.result["timer"]?.object?["id"]?.string)

        let list = await AlarmsAccess.answer(request("alarms.list"), scopes: [])
        #expect(list.status == .done)
        let foundIt = list.result["alarms"]?.array?.contains { $0.object?["id"]?.string == timerId } ?? false
        #expect(foundIt)

        // Cancel through the bot's own contract: there's no direct-AlarmKit cleanup needed here.
        let cancel = await AlarmsAccess.answer(request("alarms.cancel", ["id": .string(timerId)]), scopes: [])
        #expect(cancel.status == .done)
        #expect(cancel.result["cancelled"] == .string(timerId))
    }
    #endif
}
