// [device-access] Health for Device Access: the pure range/plan/night-grouping rules
// (HermesKit/Device/DeviceAccess+Health.swift), the catalog of every Health type (HermesKit/Device/HealthCatalog.swift,
// [health-all-types]) checked against this SDK's HealthKit, the old four switches carried over, and a live
// `health.summary` against this Simulator's own Health data (HealthKit hides whether reading was refused, so this runs
// either way: a fresh Simulator just answers with empty sections, which is the path this exercises without permission
// granted).

import Foundation
import HealthKit
import Testing
import UIKit
@testable import HermesHQNative

@MainActor struct DeviceAccessHealthTests {
    private let id = String(repeating: "a", count: 32)

    private func request(_ args: [String: JSONValue] = [:], op: String = "health.summary") -> DeviceAccess.Request {
        DeviceAccess.Request(id: id, op: op, args: args)
    }

    private func chicago() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        return calendar
    }

    @Test func rangeDefaultsToTodaysStartAndNow() throws {
        let calendar = try chicago()
        let now = try #require(DeviceAccess.date("2026-11-15T12:00", calendar: calendar)?.date)
        let startOfToday = try #require(DeviceAccess.date("2026-11-15", calendar: calendar)?.date)
        let range = DeviceAccess.healthRange(request(), now: now, calendar: calendar)
        #expect(range.start == startOfToday && range.end == now)
    }

    @Test func rangeClampsEndTo31DaysAfterStartAndNeverBeforeIt() throws {
        let calendar = try chicago()
        let now = try #require(DeviceAccess.date("2026-11-15T12:00", calendar: calendar)?.date)
        let farStart = try #require(DeviceAccess.date("2026-01-01", calendar: calendar)?.date)
        let ceiling = try #require(calendar.date(byAdding: .day, value: 31, to: farStart))
        let clamped = DeviceAccess.healthRange(request(["start": "2026-01-01"]), now: now, calendar: calendar)
        #expect(clamped.start == farStart && clamped.end == ceiling)

        let backwards = DeviceAccess.healthRange(request(["start": "2026-11-15", "end": "2026-11-01"]), now: now, calendar: calendar)
        #expect(backwards.end == backwards.start, "an end before start is pinned to start")
    }

    private static let steps = "HKQuantityTypeIdentifierStepCount", heartRate = "HKQuantityTypeIdentifierHeartRate",
                       resting = "HKQuantityTypeIdentifierRestingHeartRate", glucose = "HKQuantityTypeIdentifierBloodGlucose",
                       headache = "HKCategoryTypeIdentifierHeadache"

    @Test func anOlderAddOnsPlanIsTheOldSectionsThatHaveATypeOn() {
        // An add-on before 0.9.46 asks with the old keys and no format: the old sections, as before.
        let shared: Set<String> = [Self.steps, Self.heartRate, Self.glucose]
        #expect(DeviceAccess.healthPlan(request(), shared: shared).legacy == ["steps", "heart"], "nothing asked: every old section with a type on")
        #expect(DeviceAccess.healthPlan(request(["metrics": ["heart"]]), shared: shared).legacy == ["heart"])
        #expect(DeviceAccess.healthPlan(request(["metrics": ["sleep"]]), shared: shared).legacy == ["steps", "heart"],
                "none of what was asked is shared: the shared ones")
        #expect(DeviceAccess.healthPlan(request(), shared: [Self.glucose]).legacy == [], "a new type alone has no old section")
    }

    @Test func aTypesPlanKeepsToWhatIsOnAndSaysWhatIsOffOrUnknown() {
        let shared: Set<String> = [Self.steps, Self.heartRate, Self.headache]
        let all = DeviceAccess.healthPlan(request(["format": "types"]), shared: shared)
        #expect(all.legacy == nil && all.types == [Self.steps, Self.heartRate, Self.headache] && all.off.isEmpty,
                "nothing asked: every type on, in the page's order (Activity, Heart, Symptoms)")

        let asked = DeviceAccess.healthPlan(request(["format": "types", "metrics": [.string(Self.heartRate), .string(Self.glucose), "HKNope"]]), shared: shared)
        #expect(asked.types == [Self.heartRate] && asked.off == [Self.glucose] && asked.unknown == ["HKNope"])

        let old = DeviceAccess.healthPlan(request(["format": "types", "metrics": ["heart"]]), shared: shared)
        #expect(old.types == [Self.heartRate] && old.off == [Self.resting], "an old key stands for its types")

        let group = DeviceAccess.healthPlan(request(["format": "types", "categories": ["symptoms", "nope"]]), shared: shared)
        #expect(group.types == [Self.headache] && group.unknown == ["nope"])
        #expect(group.off.count == DeviceAccess.Settings.healthKeys(.symptoms).count - 1)
    }

    // MARK: The catalog

    @Test func theCatalogHasEveryGroupAndUniqueNamedKeys() {
        let all = HealthCatalog.all
        #expect(all.count >= 150, "\(all.count)")
        #expect(Set(all.map(\.key)).count == all.count, "keys are unique")
        #expect(Set(all.map(\.name)).count == all.count, "names are unique")
        for category in HealthCatalog.Category.allCases {
            #expect(!HealthCatalog.items(in: category).isEmpty, "\(category)")
        }
        for item in all {
            #expect(item.key.hasPrefix("HK") && !item.name.isEmpty, "\(item.key)")
            #expect([.cumulative, .discrete].contains(item.shape) == (item.unit != nil), "\(item.key): a unit only for quantities")
        }
        #expect(HealthCatalog.byKey[Self.steps]?.category == .activity && HealthCatalog.byKey[Self.headache]?.values == .severity)
        let ordered = HealthCatalog.available().map(\.category.order)
        #expect(ordered == ordered.sorted(), "the page lists the groups in the Health app's order")
    }

    @Test func aTypeNewerThanThisIOSIsLeftOff() {
        let rmssd = "HKQuantityTypeIdentifierHeartRateVariabilityRMSSD"
        #expect(!HealthCatalog.available(osVersion: 2600).contains { $0.key == rmssd })
        #expect(HealthCatalog.available(osVersion: 2700).contains { $0.key == rmssd })
        #expect(HealthCatalog.available(osVersion: 2601).contains { $0.key == "HKCategoryTypeIdentifierHypertensionEvent" } == false)
        #expect(HealthCatalog.available(osVersion: 2602).contains { $0.key == "HKCategoryTypeIdentifierHypertensionEvent" })
    }

    @Test func everyKeyIsAHealthKitTypeAndEveryUnitFitsIt() throws {
        for item in HealthCatalog.available() {
            guard let type = HealthLookup.objectType(item.key) else {
                Issue.record("\(item.key) isn't a HealthKit type here")
                continue
            }
            #expect(type.identifier == item.key, "\(item.key) → \(type.identifier)")
            if let unit = item.unit {
                let quantity = try #require(type as? HKQuantityType, "\(item.key)")
                #expect(quantity.is(compatibleWith: HKUnit(from: unit)), "\(item.key) in \(unit)")
                #expect(quantity.aggregationStyle == .cumulative ? item.shape == .cumulative : item.shape == .discrete,
                        "\(item.key): added up or measured, as HealthKit has it")
            }
        }
        #expect(HealthLookup.objectType("HKQuantityTypeIdentifierNope") == nil)
    }

    @Test func everyGroupsTileIsARealSymbol() {
        for category in HealthCatalog.Category.allCases {
            #expect(SettingsRowLabel.tiles[category.systemImage] != nil, "\(category)")
            #expect(UIImage(systemName: category.systemImage) != nil, "\(category.systemImage)")
        }
    }

    @Test func workoutsAreNamedForEveryActivity() {
        #expect(HealthCatalog.workoutName(HKWorkoutActivityType.running.rawValue) == "running")
        #expect(HealthCatalog.workoutName(HKWorkoutActivityType.pickleball.rawValue) == "pickleball")
        #expect(HealthCatalog.workoutName(HKWorkoutActivityType.underwaterDiving.rawValue) == "underwater diving")
        #expect(HealthCatalog.workoutName(HKWorkoutActivityType.traditionalStrengthTraining.rawValue) == "traditional strength training")
        #expect(HealthCatalog.workoutName(9999) == "other")
        #expect(HealthCatalog.workoutNames.count >= 80)
    }

    // MARK: The old four switches

    @Test func savedOldSwitchesTurnIntoTheirTypes() throws {
        let saved = Data(#"{"shared":{"health":["steps","heart"],"contacts":["phone"]}}"#.utf8)
        let settings = try JSONDecoder().decode(DeviceAccess.Settings.self, from: saved)
        #expect(settings.scopes(.health) == ["HKQuantityTypeIdentifierStepCount", "HKQuantityTypeIdentifierDistanceWalkingRunning",
                                             "HKQuantityTypeIdentifierFlightsClimbed", Self.heartRate, Self.resting])
        #expect(settings.scopes(.contacts) == ["phone"])
        let again = try JSONDecoder().decode(DeviceAccess.Settings.self, from: try JSONEncoder().encode(settings))
        #expect(again == settings, "saved as types from then on")
    }

    @Test func theAddOnStillHearsTheOldSwitchesAndEachTypeOn() throws {
        var settings = DeviceAccess.Settings()
        settings.set(.health, [Self.heartRate, Self.glucose], on: true)
        let health = try #require(settings.wire["health"] as? [String: Bool])
        #expect(health == ["steps": false, "sleep": false, "workouts": false, "heart": true, Self.heartRate: true, Self.glucose: true])
        #expect(settings.summary(.health) == "2 On" && settings.shares(.health))
        #expect(DeviceAccess.check(request(), settings: settings) == .run(.health, scopes: [Self.heartRate, Self.glucose]))

        settings.set(.health, [Self.heartRate, Self.glucose, Self.steps], on: false)
        #expect(!settings.shares(.health) && settings.summary(.health) == "Off")
        #expect(DeviceAccess.Settings.healthKeys(.vitals).contains(Self.glucose))
    }

    @Test func aGroupsRowSaysHowManyAreOn() {
        var settings = DeviceAccess.Settings()
        let vitals = DeviceAccess.Settings.healthKeys(.vitals)
        #expect(settings.healthSummary(.vitals) == "Off")
        settings.set(.health, Self.glucose, on: true)
        #expect(settings.healthSummary(.vitals) == "1 of \(vitals.count)")
        settings.set(.health, Set(vitals), on: true)
        #expect(settings.healthSummary(.vitals) == "On")
    }

    @Test func theAddOnsHealthTypesFlagIsRead() {
        #expect(DeviceAccess.supportsHealthTypes(["deviceAccessHealthTypes": true]))
        #expect(!DeviceAccess.supportsHealthTypes(["deviceAccessKinds": true]))
    }

    @Test func recentRequestsNameTheTypes() {
        #expect(DeviceAccess.describe(request()) == "Health summary")
        #expect(DeviceAccess.describe(request(["metrics": ["steps"]])) == "Health: Steps & Distance")
        let many: JSONValue = [.string(Self.heartRate), .string(Self.glucose), .string(Self.steps), .string(Self.headache)]
        #expect(DeviceAccess.describe(request(["metrics": many])) == "Health: Heart Rate, Blood Glucose, Steps and 1 more")
        #expect(DeviceAccess.describe(request(["categories": ["heart"]])) == "Health: Heart")
    }

    // MARK: One type's summary

    @Test func anAddedUpTypeHasItsTotalAndItsDays() throws {
        let item = try #require(HealthCatalog.byKey[Self.steps])
        let days = [DeviceAccess.HealthDay(day: "2026-11-01", sum: 4000), DeviceAccess.HealthDay(day: "2026-11-02", sum: 0),
                    DeviceAccess.HealthDay(day: "2026-11-03", sum: 6000.4)]
        let entry = try #require(DeviceAccess.healthQuantity(item, days: days, multiDay: true))
        #expect(entry["total"] == 10000.4 && entry["unit"] == "count" && entry["name"] == "Steps" && entry["category"] == "activity")
        #expect(entry["by_day"] == ["2026-11-01": 4000, "2026-11-03": 6000.4], "a day with nothing is left out")
        #expect(DeviceAccess.healthQuantity(item, days: days, multiDay: false)?["by_day"] == nil, "one day: no by_day")
        #expect(DeviceAccess.healthQuantity(item, days: [], multiDay: true) == nil, "nothing in the range: no entry")
    }

    @Test func aMeasuredTypeHasItsRangeAndLatestAndPercentagesReadAsPercent() throws {
        let item = try #require(HealthCatalog.byKey["HKQuantityTypeIdentifierOxygenSaturation"])
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = try #require(DeviceAccess.healthQuantity(item, days: [DeviceAccess.HealthDay(day: "2026-11-01", average: 0.975, minimum: 0.95, maximum: 0.99)],
                                                             overall: DeviceAccess.HealthDay(day: "", average: 0.975, minimum: 0.95, maximum: 0.99),
                                                             latest: (0.96, at), multiDay: true, zone: TimeZone(identifier: "UTC")!))
        #expect(entry["average"] == 97.5 && entry["min"] == 95 && entry["max"] == 99 && entry["unit"] == "%")
        #expect(entry["latest"]?["value"] == 96 && entry["latest"]?["at"] == "2027-01-15T08:00:00Z")
        #expect(entry["by_day"]?["2026-11-01"]?["average"] == 97.5)
    }

    @Test func aLoggedTypeCountsItsSamplesAndNamesItsValues() throws {
        let item = try #require(HealthCatalog.byKey[Self.headache])
        let utc = TimeZone(identifier: "UTC")!
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [DeviceAccess.HealthEvent(start: t, end: t.addingTimeInterval(1800), value: 2),
                      DeviceAccess.HealthEvent(start: t.addingTimeInterval(86400), end: t.addingTimeInterval(86400 + 1800), value: 4)]
        let entry = try #require(DeviceAccess.healthCategory(item, events: events, multiDay: true, zone: utc))
        #expect(entry["count"] == 2 && entry["minutes"] == 60 && entry["values"] == ["mild": 1, "severe": 1])
        #expect(entry["by_day"] == ["2027-01-15": 1, "2027-01-16": 1] && entry["latest"] == "2027-01-16T08:00:00Z")
        #expect(DeviceAccess.healthCategory(item, events: [], multiDay: true) == nil)
        let plain = try #require(HealthCatalog.byKey["HKCategoryTypeIdentifierToothbrushingEvent"])
        #expect(DeviceAccess.healthCategory(plain, events: events, multiDay: false)?["values"] == nil, "a type without named values")
    }

    @Test func aTooLargeAnswerLosesItsDaysFirstThenWholeTypes() {
        let byDay = JSONValue.object(Dictionary(uniqueKeysWithValues: (1...31).map { ("2026-10-\($0)", JSONValue.number(Double($0) * 1000.5)) }))
        let entries = (0..<10).map { (key: "HK\($0)", value: JSONValue.object(["total": 1, "by_day": byDay])) }
        let roomy = DeviceAccess.healthTrimmed(entries, limit: 1_000_000)
        #expect(!roomy.trimmed && roomy.types.count == 10 && roomy.types["HK0"]?["by_day"] != nil)
        let tight = DeviceAccess.healthTrimmed(entries, limit: 2_000)
        #expect(tight.trimmed && tight.types.count == 10 && tight.types.values.contains { $0["by_day"] == nil })
        #expect(tight.leftOut.isEmpty)
        let tiny = DeviceAccess.healthTrimmed(entries, limit: 60)
        #expect(tiny.trimmed && tiny.types.count < 10 && tiny.leftOut.last == "HK9", "whole types go from the end")
        #expect(tiny.types.keys.allSatisfy { !tiny.leftOut.contains($0) })
    }

    @Test func sleepNightBeforeTwoPMBelongsToThePreviousDay() throws {
        let calendar = try chicago()
        let early = try #require(DeviceAccess.date("2026-11-02T01:00", calendar: calendar)?.date)
        let afternoon = try #require(DeviceAccess.date("2026-11-02T15:00", calendar: calendar)?.date)
        #expect(DeviceAccess.day(DeviceAccess.sleepNight(for: early, calendar: calendar), zone: calendar.timeZone) == "2026-11-01")
        #expect(DeviceAccess.day(DeviceAccess.sleepNight(for: afternoon, calendar: calendar), zone: calendar.timeZone) == "2026-11-02")
    }

    @Test func sleepSamplesAcrossMidnightGroupIntoOneNight() throws {
        let calendar = try chicago()
        func at(_ text: String) throws -> Date { try #require(DeviceAccess.date(text, calendar: calendar)?.date) }
        let samples = [
            DeviceAccess.SleepSample(start: try at("2026-11-01T23:00"), end: try at("2026-11-02T01:00"), asleep: true),
            DeviceAccess.SleepSample(start: try at("2026-11-02T01:00"), end: try at("2026-11-02T06:30"), asleep: true),
            DeviceAccess.SleepSample(start: try at("2026-11-01T22:30"), end: try at("2026-11-02T06:30"), asleep: false),
        ]
        let nights = DeviceAccess.sleepNights(samples, calendar: calendar, zone: calendar.timeZone)
        #expect(nights.count == 1)
        let night = try #require(nights.first)
        #expect(night.night == "2026-11-01" && night.asleepHours == 7.5 && night.inBedHours == 8.0)
    }

    @Test func inBedNeverReadsBelowAsleepEvenWithoutItsOwnSamples() {
        let samples = [DeviceAccess.SleepSample(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 3600 * 3), asleep: true)]
        let night = try? #require(DeviceAccess.sleepNights(samples).first)
        #expect(night?.inBedHours == night?.asleepHours)
    }

    @Test func round2RoundsToTwoDecimalPlaces() {
        #expect(DeviceAccess.round2(1.234) == 1.23)
        #expect(DeviceAccess.round2(1.236) == 1.24)
    }

    @Test func sleepStagesAreCountedAndAwakeIsNotAsleep() throws {
        let calendar = try chicago()
        func at(_ text: String) throws -> Date { try #require(DeviceAccess.date(text, calendar: calendar)?.date) }
        let samples = [
            DeviceAccess.SleepSample(start: try at("2026-11-01T23:00"), end: try at("2026-11-02T01:00"), stage: .core),
            DeviceAccess.SleepSample(start: try at("2026-11-02T01:00"), end: try at("2026-11-02T02:00"), stage: .deep),
            DeviceAccess.SleepSample(start: try at("2026-11-02T02:00"), end: try at("2026-11-02T02:30"), stage: .awake),
            DeviceAccess.SleepSample(start: try at("2026-11-02T02:30"), end: try at("2026-11-02T03:30"), stage: .rem),
        ]
        let night = try #require(DeviceAccess.sleepNights(samples, calendar: calendar, zone: calendar.timeZone).first)
        #expect(night.asleepHours == 4 && night.stages == ["core": 2, "deep": 1, "rem": 1, "awake": 0.5])
        #expect(night.wire["stages_hours"]?["awake"] == 0.5)
        #expect(DeviceAccess.SleepSample.stage(4) == .deep && DeviceAccess.SleepSample.stage(9) == nil)
    }

    // MARK: Live (this Simulator's own Health data)

    @Test func liveTypesSummaryAgainstThisSimulatorsHealthData() async {
        let on = Set(HealthCatalog.available().map(\.key))
        let answer = await HealthAccess.answer(request(["format": "types"]), scopes: on)
        #expect(answer.status == .done, "every type at once, still within its time")
        #expect(answer.result["types"]?.object != nil && answer.result["range"]?["start"] != nil)
        let size = (try? JSONValue.object(answer.result).encoded().count) ?? .max
        #expect(size < 64 * 1024, "fits what the add-on takes: \(size) bytes")
    }

    @Test func liveSummaryAgainstThisSimulatorsHealthData() async {
        let all = HealthCatalog.expandingLegacy(DeviceAccess.healthMetricKeys)
        let answer = await HealthAccess.answer(request(["metrics": .array(DeviceAccess.healthMetricKeys.map(JSONValue.string))]), scopes: all)
        #expect(answer.status == .done, "HealthKit hides refusal: even without permission this comes back done, just empty")
        #expect(answer.result["range"]?["start"] != nil && answer.result["range"]?["end"] != nil)
        #expect(answer.result["types"] == nil, "an older add-on's request gets the old sections")
        if let steps = answer.result["steps"] { #expect(steps["by_day"]?.array != nil) }
        if let sleep = answer.result["sleep"] { #expect(sleep["nights"]?.array != nil) }
        if let workouts = answer.result["workouts"] { #expect(workouts.array != nil) }
    }

    @Test func liveSummaryIsUnavailableWhileLockedOrOnTheWrongOp() async {
        let wrongOp = await HealthAccess.answer(request(op: "health.other"), scopes: ["steps"])
        #expect(wrongOp.status == .unavailable)
    }
}
