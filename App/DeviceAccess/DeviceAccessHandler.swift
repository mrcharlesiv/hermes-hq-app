// [device-access] One kind's side of Device Access on this device: iOS's permission for it, and the requests it
// answers. DeviceAccessCenter runs a request only after DeviceAccess.check allowed it (the kind is shared and one of
// the request's switches is on); the handler still keeps to the switches it's given (Contacts' details, Health's
// kinds of data, Location's precision). A request may arrive while the app is in the background on a silent push,
// with about 30 seconds to answer: a handler answers within `DeviceAccessCenter.answerSeconds`, or the center
// answers "took too long" for it. Logs say what kind of request it was and how it ended, never what was asked or found.

import Foundation

enum DeviceAccessPermission: Equatable, Sendable {
    /// Allowed (for Photos and Contacts: all of them).
    case allowed
    /// Allowed for part (selected photos or contacts; Location while using the app).
    case limited
    case notAsked
    case denied
}

protocol DeviceAccessHandler {
    static var kind: DeviceAccess.Kind { get }
    /// iOS's permission as the page shows it.
    static var permission: DeviceAccessPermission { get }
    /// Asked when a switch is turned on (`key` is the switch). false keeps the switch off: refused, or not possible.
    static func requestPermission(turningOn key: String) async -> Bool
    /// Words for the page about the permission (part allowed, how to change it), or nil.
    static var permissionNote: String? { get }
    /// Why switch `key` can't be on on this device at all (no Messages composer on the Mac, no motion sensing), or nil.
    static func unsupported(_ key: String) -> String?
    /// One request the phone allowed, with the switches of its kind that are on.
    static func answer(_ request: DeviceAccess.Request, scopes: Set<String>) async -> DeviceAccess.Answer
}

extension DeviceAccessHandler {
    static var permissionNote: String? { nil }
    static func unsupported(_ key: String) -> String? { nil }
}

enum DeviceAccessHandlers {
    static func handler(_ kind: DeviceAccess.Kind) -> any DeviceAccessHandler.Type {
        switch kind {
        case .contacts: ContactsAccess.self
        case .location: LocationAccess.self
        case .reminders: RemindersAccess.self
        case .calendar: CalendarAccess.self
        case .alarms: AlarmsAccess.self
        case .photos: PhotosAccess.self
        case .health: HealthAccess.self
        case .motion: MotionAccess.self
        case .music: MusicAccess.self
        case .drafts: DraftsAccess.self
        }
    }
}

/// Contacts (ContactsLookup does the work off the main thread).
enum ContactsAccess: DeviceAccessHandler {
    static let kind = DeviceAccess.Kind.contacts

    static var permission: DeviceAccessPermission {
        switch ContactsLookup.permission {
        case .allowed: .allowed
        case .limited: .limited
        case .notAsked: .notAsked
        case .denied: .denied
        }
    }

    static func requestPermission(turningOn key: String) async -> Bool { await ContactsLookup.requestPermission() }

    static var permissionNote: String? {
        switch ContactsLookup.permission {
        case .limited: "\(AppIdentity.current.displayName) can see only the contacts you chose in \(DeviceWord.settingsApp)."
        case .allowed where !DeviceWord.isMac: "In \(DeviceWord.settingsApp) you can also limit \(AppIdentity.current.displayName) to selected contacts."
        default: nil
        }
    }

    static func answer(_ request: DeviceAccess.Request, scopes: Set<String>) async -> DeviceAccess.Answer {
        guard let plan = DeviceAccess.contactsPlan(request, shared: scopes) else { return .failed("Nothing to look up.") }
        return await ContactsLookup.search(plan.query, fields: plan.fields)
    }
}
