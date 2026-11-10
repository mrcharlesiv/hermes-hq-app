// [device-access] The Health side of Device Access: `health.summary`, read with HealthKit's async query descriptors.
// Read-only (`toShare: []`; Info.plist's update description is there only because an App Store upload with the
// HealthKit entitlement needs one). Not part of Mac Catalyst here, so this whole file compiles to nothing on the Mac;
// HealthAccess.swift answers Mac requests itself.
//
// [health-all-types] Every type in HealthCatalog, each switched on by itself or a whole Health group at once (one iOS
// sheet asks about all of a group's types). A request from an add-on of 0.9.46 or later (`format: "types"`) gets one
// entry per type; an older add-on's gets the four old sections (steps, sleep, workouts, heart), from whichever of their
// types are on. Types are read a few at a time; the answer is cut down to fit what the add-on takes.
//
// HealthKit hides whether reading was ever refused, to protect the owner's privacy: once a type has been asked
// about, `getRequestStatusForAuthorization` answers `.unnecessary` forever after, whatever the owner chose. So
// `permission` can only ever read "asked" or "not asked yet" (never "denied"); a switch that was in fact refused just
// comes back with no data, same as one that's genuinely empty.

#if !targetEnvironment(macCatalyst)
import Foundation
import HealthKit

nonisolated enum HealthLookup {
    private static let askedKey = "hq.deviceAccess.health.asked"
    private static let store = HKHealthStore()
    /// Beats per minute, as HealthKit's own unit algebra spells it.
    private static let bpm = HKUnit.count().unitDivided(by: .minute())
    /// How many types are read at once.
    private static let width = 6

    static var permission: DeviceAccessPermission {
        guard HKHealthStore.isHealthDataAvailable() else { return .denied }
        return UserDefaults.standard.bool(forKey: askedKey) ? .allowed : .notAsked
    }

    /// The HealthKit type a catalog key names, or nil when this iOS doesn't have it.
    static func objectType(_ key: String) -> HKObjectType? {
        guard let item = HealthCatalog.byKey[key] else { return nil }
        switch item.shape {
        case .cumulative, .discrete: return HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: key))
        case .category, .sleep: return HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: key))
        case .characteristic: return HKObjectType.characteristicType(forIdentifier: HKCharacteristicTypeIdentifier(rawValue: key))
        case .workout: return HKObjectType.workoutType()
        case .activitySummary: return HKObjectType.activitySummaryType()
        case .electrocardiogram: return HKObjectType.electrocardiogramType()
        case .audiogram: return HKObjectType.audiogramSampleType()
        case .stateOfMind: return HKObjectType.stateOfMindType()
        case .assessment:
            // Swift has only the non-failable init, so only the identifiers this SDK names.
            let identifier = HKScoredAssessmentTypeIdentifier(rawValue: key)
            return [.GAD7, .PHQ9].contains(identifier) ? HKScoredAssessmentType(identifier) : nil
        }
    }

    /// One switch turned on (an old key stands for its types).
    @concurrent static func requestPermission(turningOn key: String) async -> Bool {
        await requestPermission(turningOn: Array(HealthCatalog.expandingLegacy([key])))
    }

    /// Several switches turned on at once (a group's Turn On All): iOS's Health sheet asks about all of them together.
    @concurrent static func requestPermission(turningOn keys: [String]) async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        let ask = Set(keys.compactMap(objectType))
        guard !ask.isEmpty else { return false }
        _ = try? await store.requestAuthorization(toShare: [], read: ask)
        if await requestStatus(ask) == .unnecessary { UserDefaults.standard.set(true, forKey: askedKey) }
        return true
    }

    private static func requestStatus(_ types: Set<HKObjectType>) async -> HKAuthorizationRequestStatus {
        await withCheckedContinuation { continuation in
            store.getRequestStatusForAuthorization(toShare: [], read: types) { status, _ in continuation.resume(returning: status) }
        }
    }

    @concurrent static func summary(_ request: DeviceAccess.Request, scopes: Set<String>) async -> DeviceAccess.Answer {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable(DeviceAccess.notHereWords(.health)) }
        let (start, end) = DeviceAccess.healthRange(request)
        let plan = DeviceAccess.healthPlan(request, shared: scopes)
        var result: [String: JSONValue] = ["range": .object(["start": .string(DeviceAccess.stamp(start)), "end": .string(DeviceAccess.stamp(end))])]
        guard let legacy = plan.legacy else { return await typesSummary(plan, start: start, end: end, result: result) }
        for metric in legacy {
            guard !Task.isCancelled else { return .failed("The \(DeviceWord.name) took too long to answer.") }
            switch metric {
            case "steps": result["steps"] = await steps(start: start, end: end, on: scopes)
            case "sleep": result["sleep"] = .object(["nights": .array(await sleepNights(start: start, end: end).map(\.wire))])
            case "workouts": result["workouts"] = .array(await workouts(start: start, end: end).items)
            default: result["heart"] = await heart(start: start, end: end, on: scopes)
            }
        }
        return .done(result)
    }

    // MARK: Every type (0.9.46's `format: "types"`)

    private static func typesSummary(_ plan: DeviceAccess.HealthPlan, start: Date, end: Date,
                                     result: [String: JSONValue]) async -> DeviceAccess.Answer {
        var result = result
        let calendar = Calendar.current
        let multiDay = calendar.startOfDay(for: start) < calendar.startOfDay(for: max(start, end.addingTimeInterval(-1)))
        var found: [Int: JSONValue] = [:]
        let keys = Array(plan.types.enumerated())
        for first in stride(from: 0, to: keys.count, by: width) {
            guard !Task.isCancelled else { return .failed("The \(DeviceWord.name) took too long to answer.") }
            let batch = keys[first..<min(first + width, keys.count)]
            // Not `withTaskGroup`: optimized builds abort when a child finishes into a destroyed group (ChildTasks.swift).
            await withChildTasks(of: (Int, JSONValue?).self) { group in
                for (index, key) in batch {
                    group.addTask { (index, await entry(key, start: start, end: end, multiDay: multiDay)) }
                }
                while let (index, value) = await group.next() {
                    if let value { found[index] = value }
                }
            }
        }
        let entries = found.keys.sorted().compactMap { index in found[index].map { (key: plan.types[index], value: $0) } }
        let cut = DeviceAccess.healthTrimmed(entries)
        result["types"] = .object(cut.types)
        result["count"] = .number(Double(cut.types.count))
        let empty = plan.types.indices.filter { found[$0] == nil }.map { plan.types[$0] }
        if !empty.isEmpty { result["no_data"] = .array(empty.map(JSONValue.string)) }
        if !plan.off.isEmpty { result["off"] = .array(plan.off.map(JSONValue.string)) }
        if !plan.unknown.isEmpty { result["unknown"] = .array(plan.unknown.map(JSONValue.string)) }
        if cut.trimmed {
            result["trimmed"] = true
            result["note"] = .string(DeviceAccess.healthTrimmedWords)
            if !cut.leftOut.isEmpty { result["left_out"] = .array(cut.leftOut.map(JSONValue.string)) }
        }
        return .done(result)
    }

    /// One type's entry, or nil when it has nothing in the range (or this iOS doesn't have it).
    private static func entry(_ key: String, start: Date, end: Date, multiDay: Bool) async -> JSONValue? {
        guard let item = HealthCatalog.byKey[key], let type = objectType(key) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        switch item.shape {
        case .cumulative, .discrete:
            guard let type = type as? HKQuantityType, let unitName = item.unit else { return nil }
            return await quantity(item, type: type, unit: HKUnit(from: unitName), predicate: predicate, start: start, end: end, multiDay: multiDay)
        case .category:
            guard let type = type as? HKCategoryType else { return nil }
            let (samples, more) = await categorySamples(type, predicate: predicate)
            let events = samples.map { DeviceAccess.HealthEvent(start: $0.startDate, end: $0.endDate, value: $0.value) }
            return DeviceAccess.healthCategory(item, events: events, multiDay: multiDay, more: more)
        case .sleep:
            let nights = await sleepNights(start: start, end: end)
            guard !nights.isEmpty else { return nil }
            var out = DeviceAccess.healthEntry(item)
            out["nights"] = .array(nights.map(\.wire))
            return .object(out)
        case .workout:
            let (items, more) = await workouts(start: start, end: end)
            guard !items.isEmpty else { return nil }
            var out = DeviceAccess.healthEntry(item)
            out["workouts"] = .array(items)
            out["count"] = .number(Double(items.count))
            if more { out["more"] = true }
            return .object(out)
        case .activitySummary: return await rings(item, start: start, end: end)
        case .characteristic: return characteristic(item)
        case .electrocardiogram, .audiogram, .stateOfMind, .assessment:
            guard let type = type as? HKSampleType else { return nil }
            return await samples(item, type: type, predicate: predicate)
        }
    }

    private static func quantity(_ item: HealthCatalog.Item, type: HKQuantityType, unit: HKUnit, predicate: NSPredicate,
                                 start: Date, end: Date, multiDay: Bool) async -> JSONValue? {
        guard type.is(compatibleWith: unit) else { return nil }
        let cumulative = item.shape == .cumulative
        let options: HKStatisticsOptions = cumulative ? .cumulativeSum : [.discreteAverage, .discreteMin, .discreteMax]
        let collection = HKStatisticsCollectionQueryDescriptor(predicate: .quantitySample(type: type, predicate: predicate), options: options,
                                                               anchorDate: Calendar.current.startOfDay(for: start),
                                                               intervalComponents: DateComponents(day: 1))
        var days: [DeviceAccess.HealthDay] = []
        if let stats = try? await collection.result(for: store) {
            stats.enumerateStatistics(from: start, to: end) { one, _ in
                days.append(day(one, unit: unit))
            }
        }
        guard !cumulative else { return DeviceAccess.healthQuantity(item, days: days, multiDay: multiDay) }
        let whole = HKStatisticsQueryDescriptor(predicate: .quantitySample(type: type, predicate: predicate), options: options)
        let overall = (try? await whole.result(for: store)).flatMap { $0 }.map { day($0, unit: unit) }
        let newest = HKSampleQueryDescriptor(predicates: [.quantitySample(type: type, predicate: predicate)],
                                             sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: 1)
        let latest = (try? await newest.result(for: store))?.first.map { (value: $0.quantity.doubleValue(for: unit), at: $0.endDate) }
        return DeviceAccess.healthQuantity(item, days: days, overall: overall, latest: latest, multiDay: multiDay)
    }

    private static func day(_ stats: HKStatistics, unit: HKUnit) -> DeviceAccess.HealthDay {
        DeviceAccess.HealthDay(day: DeviceAccess.day(stats.startDate), sum: stats.sumQuantity()?.doubleValue(for: unit),
                               average: stats.averageQuantity()?.doubleValue(for: unit),
                               minimum: stats.minimumQuantity()?.doubleValue(for: unit),
                               maximum: stats.maximumQuantity()?.doubleValue(for: unit))
    }

    private static func categorySamples(_ type: HKCategoryType, predicate: NSPredicate) async -> (samples: [HKCategorySample], more: Bool) {
        let limit = DeviceAccess.healthMaxSamples
        let descriptor = HKSampleQueryDescriptor(predicates: [.categorySample(type: type, predicate: predicate)],
                                                 sortDescriptors: [SortDescriptor(\.startDate)], limit: limit + 1)
        let found = (try? await descriptor.result(for: store)) ?? []
        return (Array(found.prefix(limit)), found.count > limit)
    }

    /// Activity Rings, one per day: what was done and the goal for each ring.
    private static func rings(_ item: HealthCatalog.Item, start: Date, end: Date) async -> JSONValue? {
        let calendar = Calendar.current
        let parts: Set<Calendar.Component> = [.era, .year, .month, .day]
        var from = calendar.dateComponents(parts, from: start), to = calendar.dateComponents(parts, from: end)
        from.calendar = calendar
        to.calendar = calendar
        let descriptor = HKActivitySummaryQueryDescriptor(predicate: HKQuery.predicate(forActivitySummariesBetweenStart: from, end: to))
        guard let found = try? await descriptor.result(for: store), !found.isEmpty else { return nil }
        let kcal = HKUnit.kilocalorie(), minutes = HKUnit.minute(), count = HKUnit.count()
        func number(_ quantity: HKQuantity?, _ unit: HKUnit) -> JSONValue? {
            quantity.map { .number(DeviceAccess.round2($0.doubleValue(for: unit))) }
        }
        let days: [JSONValue] = found.map { summary in
            var one: [String: JSONValue] = [:]
            if let date = summary.dateComponents(for: calendar).date { one["day"] = .string(DeviceAccess.day(date)) }
            if summary.activityMoveMode == .appleMoveTime {
                one["move_minutes"] = number(summary.appleMoveTime, minutes)
                one["move_goal_minutes"] = number(summary.appleMoveTimeGoal, minutes)
            } else {
                one["move_kcal"] = number(summary.activeEnergyBurned, kcal)
                one["move_goal_kcal"] = number(summary.activeEnergyBurnedGoal, kcal)
            }
            one["exercise_minutes"] = number(summary.appleExerciseTime, minutes)
            one["exercise_goal_minutes"] = number(summary.exerciseTimeGoal, minutes)
            one["stand_hours"] = number(summary.appleStandHours, count)
            one["stand_goal_hours"] = number(summary.standHoursGoal, count)
            return .object(one)
        }
        var out = DeviceAccess.healthEntry(item)
        out["days"] = .array(days)
        return .object(out)
    }

    /// Date of birth, sex, blood type and the like: one value each, not dated (nil when not set).
    private static func characteristic(_ item: HealthCatalog.Item) -> JSONValue? {
        guard let value = characteristicValue(item.key) else { return nil }
        var out = DeviceAccess.healthEntry(item)
        out["value"] = .string(value)
        return .object(out)
    }

    private static func characteristicValue(_ key: String) -> String? {
        switch HKCharacteristicTypeIdentifier(rawValue: key) {
        case .dateOfBirth:
            return DeviceAccess.birthday(try? store.dateOfBirthComponents())
        case .biologicalSex:
            switch (try? store.biologicalSex())?.biologicalSex {
            case .female: return "female"
            case .male: return "male"
            case .other: return "other"
            default: return nil
            }
        case .bloodType:
            switch (try? store.bloodType())?.bloodType {
            case .aPositive: return "A+"
            case .aNegative: return "A-"
            case .bPositive: return "B+"
            case .bNegative: return "B-"
            case .abPositive: return "AB+"
            case .abNegative: return "AB-"
            case .oPositive: return "O+"
            case .oNegative: return "O-"
            default: return nil
            }
        case .fitzpatrickSkinType:
            switch (try? store.fitzpatrickSkinType())?.skinType {
            case .I: return "I"
            case .II: return "II"
            case .III: return "III"
            case .IV: return "IV"
            case .V: return "V"
            case .VI: return "VI"
            default: return nil
            }
        case .wheelchairUse:
            switch (try? store.wheelchairUse())?.wheelchairUse {
            case .yes: return "yes"
            case .no: return "no"
            default: return nil
            }
        case .activityMoveMode:
            return (try? store.activityMoveMode())?.activityMoveMode == .appleMoveTime ? "move time" : "active energy"
        default:
            return nil
        }
    }

    /// ECGs, hearing tests, State of Mind logs and GAD-7 or PHQ-9 results: how many, what they found, the latest.
    private static func samples(_ item: HealthCatalog.Item, type: HKSampleType, predicate: NSPredicate) async -> JSONValue? {
        let descriptor = HKSampleQueryDescriptor(predicates: [.sample(type: type, predicate: predicate)],
                                                 sortDescriptors: [SortDescriptor(\.startDate)], limit: DeviceAccess.healthMaxSamples)
        guard let found = try? await descriptor.result(for: store), let last = found.last else { return nil }
        var out = DeviceAccess.healthEntry(item)
        out["count"] = .number(Double(found.count))
        out["latest"] = .string(DeviceAccess.stamp(last.startDate))
        func counted(_ names: [String]) -> JSONValue {
            var counts: [String: Double] = [:]
            for name in names { counts[name, default: 0] += 1 }
            return .object(counts.mapValues(JSONValue.number))
        }
        switch item.shape {
        case .electrocardiogram:
            let ecgs = found.compactMap { $0 as? HKElectrocardiogram }
            out["results"] = counted(ecgs.map { ecgName($0.classification) })
            let rates = ecgs.compactMap { $0.averageHeartRate?.doubleValue(for: bpm) }
            if !rates.isEmpty { out["average_bpm"] = .number(DeviceAccess.round2(rates.reduce(0, +) / Double(rates.count))) }
        case .stateOfMind:
            let logs = found.compactMap { $0 as? HKStateOfMind }
            out["kinds"] = counted(logs.map { $0.kind == .dailyMood ? "daily mood" : "momentary emotion" })
            out["feelings"] = counted(logs.map { valenceName($0.valenceClassification) })
            out["labels"] = counted(logs.flatMap { $0.labels.map(labelName) })
            if !logs.isEmpty { out["average_valence"] = .number(DeviceAccess.round2(logs.reduce(0) { $0 + $1.valence } / Double(logs.count))) }
        case .assessment:
            if let gad = last as? HKGAD7Assessment {
                out["latest_score"] = .number(Double(gad.score))
                out["latest_risk"] = .string(gadRisk(gad.risk))
            } else if let phq = last as? HKPHQ9Assessment {
                out["latest_score"] = .number(Double(phq.score))
                out["latest_risk"] = .string(phqRisk(phq.risk))
            }
        default: break
        }
        return .object(out)
    }

    private static func ecgName(_ value: HKElectrocardiogram.Classification) -> String {
        switch value {
        case .sinusRhythm: "sinus rhythm"
        case .atrialFibrillation: "atrial fibrillation"
        case .inconclusiveLowHeartRate: "inconclusive: low heart rate"
        case .inconclusiveHighHeartRate: "inconclusive: high heart rate"
        case .inconclusivePoorReading: "inconclusive: poor reading"
        case .inconclusiveOther: "inconclusive"
        case .unrecognized: "unrecognized"
        default: "not set"
        }
    }

    private static func valenceName(_ value: HKStateOfMind.ValenceClassification) -> String {
        switch value {
        case .veryUnpleasant: "very unpleasant"
        case .unpleasant: "unpleasant"
        case .slightlyUnpleasant: "slightly unpleasant"
        case .neutral: "neutral"
        case .slightlyPleasant: "slightly pleasant"
        case .pleasant: "pleasant"
        case .veryPleasant: "very pleasant"
        @unknown default: "unknown"
        }
    }

    private static func labelName(_ label: HKStateOfMind.Label) -> String {
        switch label {
        case .amazed: "amazed"
        case .amused: "amused"
        case .angry: "angry"
        case .anxious: "anxious"
        case .ashamed: "ashamed"
        case .brave: "brave"
        case .calm: "calm"
        case .content: "content"
        case .disappointed: "disappointed"
        case .discouraged: "discouraged"
        case .disgusted: "disgusted"
        case .embarrassed: "embarrassed"
        case .excited: "excited"
        case .frustrated: "frustrated"
        case .grateful: "grateful"
        case .guilty: "guilty"
        case .happy: "happy"
        case .hopeless: "hopeless"
        case .irritated: "irritated"
        case .jealous: "jealous"
        case .joyful: "joyful"
        case .lonely: "lonely"
        case .passionate: "passionate"
        case .peaceful: "peaceful"
        case .proud: "proud"
        case .relieved: "relieved"
        case .sad: "sad"
        case .scared: "scared"
        case .stressed: "stressed"
        case .surprised: "surprised"
        case .worried: "worried"
        case .annoyed: "annoyed"
        case .confident: "confident"
        case .drained: "drained"
        case .hopeful: "hopeful"
        case .indifferent: "indifferent"
        case .overwhelmed: "overwhelmed"
        case .satisfied: "satisfied"
        @unknown default: "other"
        }
    }

    private static func gadRisk(_ risk: HKGAD7Assessment.Risk) -> String {
        switch risk {
        case .noneToMinimal: "none to minimal"
        case .mild: "mild"
        case .moderate: "moderate"
        case .severe: "severe"
        @unknown default: "unknown"
        }
    }

    private static func phqRisk(_ risk: HKPHQ9Assessment.Risk) -> String {
        switch risk {
        case .noneToMinimal: "none to minimal"
        case .mild: "mild"
        case .moderate: "moderate"
        case .moderatelySevere: "moderately severe"
        case .severe: "severe"
        @unknown default: "unknown"
        }
    }

    // MARK: Steps (the old section)

    private static func steps(start: Date, end: Date, on: Set<String>) async -> JSONValue {
        var out: [String: JSONValue] = [:]
        if on.contains(HKQuantityTypeIdentifier.stepCount.rawValue) {
            let byDay = await dailySum(.stepCount, unit: .count(), start: start, end: end)
            out["steps"] = .number(byDay.reduce(0) { $0 + $1.steps })
            out["by_day"] = .array(byDay.map { .object(["day": .string($0.day), "steps": .number($0.steps)]) })
        }
        if on.contains(HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue) {
            let km = await totalSum(.distanceWalkingRunning, unit: .meterUnit(with: .kilo), start: start, end: end)
            out["distance_km"] = .number(DeviceAccess.round2(km))
        }
        if on.contains(HKQuantityTypeIdentifier.flightsClimbed.rawValue) {
            out["flights"] = .number(await totalSum(.flightsClimbed, unit: .count(), start: start, end: end))
        }
        return .object(out)
    }

    private static func dailySum(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date) async -> [(day: String, steps: Double)] {
        let type = HKQuantityType(identifier)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKStatisticsCollectionQueryDescriptor(predicate: .quantitySample(type: type, predicate: predicate), options: .cumulativeSum,
                                                               anchorDate: Calendar.current.startOfDay(for: start), intervalComponents: DateComponents(day: 1))
        guard let collection = try? await descriptor.result(for: store) else { return [] }
        var out: [(day: String, steps: Double)] = []
        collection.enumerateStatistics(from: start, to: end) { stats, _ in
            guard let sum = stats.sumQuantity() else { return }
            out.append((DeviceAccess.day(stats.startDate), sum.doubleValue(for: unit)))
        }
        return out
    }

    private static func totalSum(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date) async -> Double {
        let type = HKQuantityType(identifier)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKStatisticsQueryDescriptor(predicate: .quantitySample(type: type, predicate: predicate), options: .cumulativeSum)
        guard let stats = try? await descriptor.result(for: store), let sum = stats.sumQuantity() else { return 0 }
        return sum.doubleValue(for: unit)
    }

    // MARK: Sleep

    private static func sleepNights(start: Date, end: Date) async -> [DeviceAccess.SleepNight] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
                                                 sortDescriptors: [SortDescriptor(\.startDate)], limit: DeviceAccess.healthMaxSamples)
        guard let samples = try? await descriptor.result(for: store) else { return [] }
        let parsed = samples.compactMap { sample in
            DeviceAccess.SleepSample.stage(sample.value).map { DeviceAccess.SleepSample(start: sample.startDate, end: sample.endDate, stage: $0) }
        }
        return DeviceAccess.sleepNights(parsed)
    }

    // MARK: Workouts

    private static func workouts(start: Date, end: Date) async -> (items: [JSONValue], more: Bool) {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let limit = DeviceAccess.healthMaxWorkouts
        let descriptor = HKSampleQueryDescriptor(predicates: [.workout(predicate)], sortDescriptors: [SortDescriptor(\.startDate)], limit: limit + 1)
        guard let found = try? await descriptor.result(for: store) else { return ([], false) }
        let items: [JSONValue] = found.prefix(limit).map { workout in
            var out: [String: JSONValue] = [
                "type": .string(HealthCatalog.workoutName(workout.workoutActivityType.rawValue)),
                "start": .string(DeviceAccess.stamp(workout.startDate)), "end": .string(DeviceAccess.stamp(workout.endDate)),
                "minutes": .number(DeviceAccess.round2(workout.duration / 60)),
            ]
            if let energy = energyKcal(workout) { out["energy_kcal"] = .number(DeviceAccess.round2(energy)) }
            if let distance = distanceKm(workout) { out["distance_km"] = .number(DeviceAccess.round2(distance)) }
            if let heart = workout.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: bpm) {
                out["average_bpm"] = .number(DeviceAccess.round2(heart))
            }
            return .object(out)
        }
        return (items, found.count > limit)
    }

    private static func energyKcal(_ workout: HKWorkout) -> Double? {
        workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
    }

    private static let distanceIdentifiers: [HKQuantityTypeIdentifier] = [
        .distanceWalkingRunning, .distanceCycling, .distanceSwimming, .distanceWheelchair, .distanceDownhillSnowSports,
        .distanceCrossCountrySkiing, .distancePaddleSports, .distanceRowing, .distanceSkatingSports,
    ]

    private static func distanceKm(_ workout: HKWorkout) -> Double? {
        for identifier in distanceIdentifiers {
            if let value = workout.statistics(for: HKQuantityType(identifier))?.sumQuantity()?.doubleValue(for: .meterUnit(with: .kilo)) {
                return value
            }
        }
        return nil
    }

    // MARK: Heart (the old section)

    private static func heart(start: Date, end: Date, on: Set<String>) async -> JSONValue {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        var out: [String: JSONValue] = [:]
        if on.contains(HKQuantityTypeIdentifier.heartRate.rawValue) {
            let statsDescriptor = HKStatisticsQueryDescriptor(predicate: .quantitySample(type: HKQuantityType(.heartRate), predicate: predicate),
                                                              options: [.discreteMin, .discreteMax, .discreteAverage])
            if let stats = try? await statsDescriptor.result(for: store) {
                if let min = stats.minimumQuantity()?.doubleValue(for: bpm) { out["min_bpm"] = .number(DeviceAccess.round2(min)) }
                if let max = stats.maximumQuantity()?.doubleValue(for: bpm) { out["max_bpm"] = .number(DeviceAccess.round2(max)) }
                if let avg = stats.averageQuantity()?.doubleValue(for: bpm) { out["average_bpm"] = .number(DeviceAccess.round2(avg)) }
            }
        }
        if on.contains(HKQuantityTypeIdentifier.restingHeartRate.rawValue) {
            let restingDescriptor = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(.restingHeartRate), predicate: predicate)],
                                                            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)], limit: 1)
            if let resting = try? await restingDescriptor.result(for: store), let sample = resting.first {
                out["resting_bpm"] = .number(DeviceAccess.round2(sample.quantity.doubleValue(for: bpm)))
            }
        }
        return .object(out)
    }
}
#endif
