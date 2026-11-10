// [device-access] Health for Device Access (docs/device-access.md): read-only, never on the Mac (HealthKit isn't part
// of Mac Catalyst here; the whole of HealthLookup.swift compiles to nothing there), and only while this phone is
// unlocked (HealthKit can't be read before then). HealthLookup does the actual HealthKit work.

import Foundation
import UIKit

enum HealthAccess: DeviceAccessHandler {
    static let kind = DeviceAccess.Kind.health

    static var permission: DeviceAccessPermission {
        #if targetEnvironment(macCatalyst)
        .denied
        #else
        HealthLookup.permission
        #endif
    }

    static func requestPermission(turningOn key: String) async -> Bool {
        #if targetEnvironment(macCatalyst)
        false
        #else
        await HealthLookup.requestPermission(turningOn: key)
        #endif
    }

    /// [health-all-types] A Health group's Turn On All: one iOS sheet asks about all of its types.
    static func requestPermission(turningOn keys: [String]) async -> Bool {
        #if targetEnvironment(macCatalyst)
        false
        #else
        await HealthLookup.requestPermission(turningOn: keys)
        #endif
    }

    static var permissionNote: String? {
        #if targetEnvironment(macCatalyst)
        nil
        #else
        "If Health shows nothing, check Health › Sharing › Apps › \(AppIdentity.current.displayName)."
        #endif
    }

    static func answer(_ request: DeviceAccess.Request, scopes: Set<String>) async -> DeviceAccess.Answer {
        #if targetEnvironment(macCatalyst)
        .unavailable(DeviceAccess.notHereWords(.health))
        #else
        guard UIApplication.shared.isProtectedDataAvailable else {
            return .unavailable("Health can be read only while \(DeviceAccess.here) is unlocked.")
        }
        guard request.op == "health.summary" else { return .unavailable(DeviceAccess.unknownWords) }
        return await HealthLookup.summary(request, scopes: scopes)
        #endif
    }
}
