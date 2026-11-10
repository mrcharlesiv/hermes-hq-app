// [device-access] Alarms & Timers for Device Access (docs/device-access.md): AlarmKit sets what rings like the Clock
// app's own alarms and timers. AlarmKit doesn't hand back a label, or which one was a timer, so DeviceAccess+Alarms
// (HermesKit) keeps a small record of what Hermes HQ itself set, pruned against AlarmKit's own list each time
// alarms.list runs; a bot sees only the alarms in that record. No countdown presentation (that needs a widget this
// app doesn't have): every alarm and timer is a plain alert with a Stop button. Not on Mac Catalyst: AlarmKit isn't
// there.

import Foundation
#if !targetEnvironment(macCatalyst)
import AlarmKit
import SwiftUI

/// AlarmKit needs a metadata type; Hermes HQ's alarms carry none (the label lives in DeviceAccess+Alarms' own record).
nonisolated struct HQAlarmMetadata: AlarmMetadata {}
#endif

enum AlarmsAccess: DeviceAccessHandler {
    static let kind = DeviceAccess.Kind.alarms

    static var permission: DeviceAccessPermission {
        #if targetEnvironment(macCatalyst)
        .notAsked
        #else
        switch AlarmManager.shared.authorizationState {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        case .denied: .denied
        @unknown default: .denied
        }
        #endif
    }

    static func requestPermission(turningOn key: String) async -> Bool {
        #if targetEnvironment(macCatalyst)
        false
        #else
        if AlarmManager.shared.authorizationState == .notDetermined { _ = try? await AlarmManager.shared.requestAuthorization() }
        return AlarmManager.shared.authorizationState == .authorized
        #endif
    }

    static func answer(_ request: DeviceAccess.Request, scopes: Set<String>) async -> DeviceAccess.Answer {
        #if targetEnvironment(macCatalyst)
        .unavailable(DeviceAccess.notHereWords(.alarms))
        #else
        await AlarmsWork.answer(request)
        #endif
    }
}

#if !targetEnvironment(macCatalyst)
/// Off the main thread: AlarmKit's own calls can block under the hood.
nonisolated enum AlarmsWork {
    @concurrent static func answer(_ request: DeviceAccess.Request) async -> DeviceAccess.Answer {
        guard !Task.isCancelled else { return .failed("Cancelled.") }
        guard AlarmManager.shared.authorizationState == .authorized else { return .unavailable(DeviceAccess.notAllowedWords(.alarms)) }
        switch request.op {
        case "alarms.set": return await set(request)
        case "alarms.timer": return await timer(request)
        case "alarms.list": return list()
        case "alarms.cancel": return cancel(request)
        default: return .unavailable(DeviceAccess.unknownWords)
        }
    }

    private static func set(_ request: DeviceAccess.Request) async -> DeviceAccess.Answer {
        guard let plan = DeviceAccess.alarmSetPlan(request) else { return .failed("“time” must be a 24-hour time, like “07:30.”") }
        if let word = plan.unknownRepeat.first {
            return .failed("“repeat” takes days of the week, “mon” to “sun”; “\(word)” isn’t one.")
        }
        guard let next = DeviceAccess.nextAlarmFire(hour: plan.hour, minute: plan.minute, days: plan.repeatDays) else {
            return .failed("The alarm couldn’t be set.")
        }
        let id = UUID()
        let schedule = Alarm.Schedule.relative(.init(time: .init(hour: plan.hour, minute: plan.minute),
                                                       repeats: plan.repeatDays.isEmpty ? .never : .weekly(Array(plan.repeatDays))))
        let configuration = AlarmManager.AlarmConfiguration<HQAlarmMetadata>.alarm(schedule: schedule, attributes: attributes(title: plan.label ?? "Alarm"))
        do { _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration) } catch { return .failed("The alarm couldn’t be set.") }
        DeviceAccess.AlarmStore.remember(id.uuidString, .init(kind: "alarm", label: plan.label ?? "",
                                                               time: DeviceAccess.alarmTimeString(hour: plan.hour, minute: plan.minute),
                                                               ends: nil, rawRepeat: plan.rawRepeat))
        return .done(DeviceAccess.alarmSetWire(id: id.uuidString, hour: plan.hour, minute: plan.minute, label: plan.label, rawRepeat: plan.rawRepeat, next: next))
    }

    private static func timer(_ request: DeviceAccess.Request) async -> DeviceAccess.Answer {
        guard let plan = DeviceAccess.alarmTimerPlan(request) else { return .failed("“seconds” must be between 1 and 86400.") }
        let id = UUID()
        let ends = Date.now.addingTimeInterval(TimeInterval(plan.seconds))
        let configuration = AlarmManager.AlarmConfiguration<HQAlarmMetadata>.alarm(schedule: .fixed(ends), attributes: attributes(title: plan.label ?? "Timer"))
        do { _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration) } catch { return .failed("The timer couldn’t be set.") }
        DeviceAccess.AlarmStore.remember(id.uuidString, .init(kind: "timer", label: plan.label ?? "", time: nil, ends: ends, rawRepeat: []))
        return .done(DeviceAccess.alarmTimerWire(id: id.uuidString, label: plan.label, ends: ends))
    }

    private static func list() -> DeviceAccess.Answer {
        let alarms: [Alarm]
        do { alarms = try AlarmManager.shared.alarms } catch { return .failed("Alarms couldn’t be read.") }
        let records = DeviceAccess.AlarmStore.prune(keeping: Set(alarms.map { $0.id.uuidString }))
        let items: [JSONValue] = alarms.compactMap { alarm in
            guard let record = records[alarm.id.uuidString] else { return nil }   // not one Hermes HQ set
            return DeviceAccess.alarmListItemWire(id: alarm.id.uuidString, kind: record.kind, time: record.time, ends: record.ends,
                                                   label: record.label, rawRepeat: record.rawRepeat, state: stateWord(alarm.state))
        }
        return .list("alarms", items)
    }

    private static func cancel(_ request: DeviceAccess.Request) -> DeviceAccess.Answer {
        guard let text = request.string("id", max: 60), let id = UUID(uuidString: text) else { return .failed("That alarm wasn’t found.") }
        do { try AlarmManager.shared.cancel(id: id) } catch { return .failed("That alarm wasn’t found.") }
        DeviceAccess.AlarmStore.forget(text)
        return .done(["cancelled": .string(text)])
    }

    private static func attributes(title: String) -> AlarmAttributes<HQAlarmMetadata> {
        let stop = AlarmButton(text: LocalizedStringResource(stringLiteral: "Stop"), textColor: .white, systemImageName: "stop.fill")
        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title), stopButton: stop)
        return AlarmAttributes(presentation: AlarmPresentation(alert: alert), metadata: HQAlarmMetadata(), tintColor: .accentColor)
    }

    private static func stateWord(_ state: Alarm.State) -> String {
        switch state {
        case .scheduled: "scheduled"
        case .countdown: "countdown"
        case .paused: "paused"
        case .alerting: "alerting"
        @unknown default: "scheduled"
        }
    }
}
#endif
