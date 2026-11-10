// [device-access] Motion & Fitness for Device Access (docs/device-access.md): CoreMotion's authorization, activity
// periods merged by DeviceAccess.mergeMotionPeriods, and today's steps from CMPedometer. CoreMotion isn't on the Mac,
// so this whole kind isn't (DeviceAccess.Kind.available agrees); the Simulator has no motion coprocessor either
// (CMMotionActivityManager.isActivityAvailable() is false there), which this answers plainly rather than failing.

import Foundation

#if !targetEnvironment(macCatalyst)
import CoreMotion

enum MotionAccess: DeviceAccessHandler {
    static let kind = DeviceAccess.Kind.motion

    static var permission: DeviceAccessPermission {
        switch CMMotionActivityManager.authorizationStatus() {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        default: .denied // .denied, .restricted
        }
    }

    /// Audit 09-10: said when the switch is turned on, rather than it flipping back without a word.
    static func unsupported(_ key: String) -> String? {
        CMMotionActivityManager.isActivityAvailable() ? nil : "This \(DeviceWord.name) doesn’t sense motion and activity."
    }

    /// A tiny query triggers the system prompt the first time.
    static func requestPermission(turningOn key: String) async -> Bool {
        guard CMMotionActivityManager.isActivityAvailable() else { return false }
        let status = CMMotionActivityManager.authorizationStatus()
        guard status != .denied, status != .restricted else { return false }
        if status == .notDetermined {
            let now = Date()
            _ = await Self.query(CMMotionActivityManager(), from: now.addingTimeInterval(-60), to: now)
        }
        return CMMotionActivityManager.authorizationStatus() == .authorized
    }

    static func answer(_ request: DeviceAccess.Request, scopes: Set<String>) async -> DeviceAccess.Answer {
        guard CMMotionActivityManager.isActivityAvailable() else { return .unavailable("This device has no motion data.") }
        guard CMMotionActivityManager.authorizationStatus() == .authorized else { return .unavailable(DeviceAccess.notAllowedWords(.motion)) }

        let end = request.date("end") ?? Date()
        let earliest = end.addingTimeInterval(-7 * 24 * 3600)
        let asked = request.date("start") ?? end.addingTimeInterval(-24 * 3600)
        let start = max(asked, earliest)

        guard let activities = await Self.query(CMMotionActivityManager(), from: start, to: end) else {
            return .failed("Motion & activity couldn’t be read.")
        }
        let samples = activities.map { (DeviceAccess.motionActivityName(walking: $0.walking, running: $0.running, cycling: $0.cycling,
                                                                         automotive: $0.automotive, stationary: $0.stationary, unknown: $0.unknown), $0.startDate) }
        let periods = DeviceAccess.mergeMotionPeriods(samples, until: end)
        let periodsValue: [JSONValue] = periods.map {
            ["activity": .string($0.activity), "start": .string(DeviceAccess.stamp($0.start)),
             "end": .string(DeviceAccess.stamp($0.end)), "minutes": .number(Double($0.minutes))]
        }

        let newest = activities.last
        let nowValue: JSONValue = [
            "activity": .string(samples.last?.0 ?? "unknown"),
            "confidence": .string(DeviceAccess.motionConfidenceWord(newest?.confidenceRaw ?? 0)),
            "since": .string(DeviceAccess.stamp(newest?.startDate ?? start)),
        ]

        var result: [String: JSONValue] = ["periods": .array(periodsValue), "steps": await Self.todaySteps()]
        // Audit 09-27: a window that ended in the past has no "now"; its last stretch is in `periods`.
        if DeviceAccess.motionReachesNow(end) { result["now"] = nowValue }
        return .done(result)
    }

    /// A plain, Sendable snapshot of a CMMotionActivity sample — CMMotionActivity itself isn't Sendable, so this is
    /// read out of it before the completion handler's value crosses back to `query`'s caller.
    private struct MotionSample: Sendable {
        var walking: Bool
        var running: Bool
        var cycling: Bool
        var automotive: Bool
        var stationary: Bool
        var unknown: Bool
        var confidenceRaw: Int
        var startDate: Date
    }

    @concurrent private static func query(_ manager: CMMotionActivityManager, from start: Date, to end: Date) async -> [MotionSample]? {
        defer { withExtendedLifetime(manager) {} }
        return await withCheckedContinuation { continuation in
            manager.queryActivityStarting(from: start, to: end, to: .main) { activities, _ in
                continuation.resume(returning: activities?.map {
                    MotionSample(walking: $0.walking, running: $0.running, cycling: $0.cycling, automotive: $0.automotive,
                                 stationary: $0.stationary, unknown: $0.unknown, confidenceRaw: $0.confidence.rawValue, startDate: $0.startDate)
                })
            }
        }
    }

    /// Likewise a plain Sendable snapshot: CMPedometerData isn't Sendable either.
    private struct StepsSnapshot: Sendable {
        var steps: Int
        var distanceM: Double?
        var floors: Int?
    }

    @concurrent private static func todaySteps() async -> JSONValue {
        guard CMPedometer.isStepCountingAvailable() else { return ["today": 0, "distance_km": 0, "floors_up": 0] }
        let end = Date()
        let start = Calendar.current.startOfDay(for: end)
        // Held until the answer comes: a pedometer let go of mid-query never calls back.
        let pedometer = CMPedometer()
        let data: StepsSnapshot? = await withCheckedContinuation { continuation in
            pedometer.queryPedometerData(from: start, to: end) { data, _ in
                continuation.resume(returning: data.map { StepsSnapshot(steps: $0.numberOfSteps.intValue, distanceM: $0.distance?.doubleValue, floors: $0.floorsAscended?.intValue) })
            }
        }
        withExtendedLifetime(pedometer) {}
        let steps = data?.steps ?? 0
        let km = (data?.distanceM ?? 0) / 1000
        let floors = data?.floors ?? 0
        return ["today": .number(Double(steps)), "distance_km": .number((km * 100).rounded() / 100), "floors_up": .number(Double(floors))]
    }
}
#else
enum MotionAccess: DeviceAccessHandler {
    static let kind = DeviceAccess.Kind.motion
    static var permission: DeviceAccessPermission { .notAsked }
    static func requestPermission(turningOn key: String) async -> Bool { false }
    static func answer(_ request: DeviceAccess.Request, scopes: Set<String>) async -> DeviceAccess.Answer {
        .unavailable(DeviceAccess.notHereWords(.motion))
    }
}
#endif
