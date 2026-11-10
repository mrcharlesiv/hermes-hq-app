// [device-access] Photos for Device Access (docs/device-access.md): iOS's permission, and the two requests
// (PhotosLookup does the PhotoKit work off the main thread, as ContactsLookup does for Contacts).

import Foundation
import Photos

enum PhotosAccess: DeviceAccessHandler {
    static let kind = DeviceAccess.Kind.photos

    static var permission: DeviceAccessPermission {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: .allowed
        case .limited: .limited
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    static func requestPermission(turningOn key: String) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    static var permissionNote: String? {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .limited: "\(AppIdentity.current.displayName) can see only the photos you chose in \(DeviceWord.settingsApp)."
        default: nil
        }
    }

    static func answer(_ request: DeviceAccess.Request, scopes: Set<String>) async -> DeviceAccess.Answer {
        guard permission == .allowed || permission == .limited else { return .unavailable(DeviceAccess.notAllowedWords(.photos)) }
        switch request.op {
        case "photos.search": return await PhotosLookup.search(request)
        case "photos.get": return await PhotosLookup.get(request)
        default: return .unavailable(DeviceAccess.unknownWords)
        }
    }
}
