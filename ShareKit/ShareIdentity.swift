// [share] Share extension ("Hermes HQ" in other apps' share sheets), docs/spec/3x-share.md.
//
// ShareKit is compiled into the app AND the Share extension (target HermesHQShare). It is self-contained on purpose:
// Foundation, Security, CryptoKit, ImageIO, AVFoundation and UniformTypeIdentifiers only; no UIKit, no HermesKit
// (spec D2). Where HermesKit has the same rule, ShareKit carries its own copy and a parity unit test in Tests/Share
// keeps the two from drifting. Every declaration is `nonisolated`, so it means the same under the app's MainActor
// default and in the extension.

import Foundation

/// Which App Group and Keychain item this build uses. Both targets' Info.plist carry the same two keys, filled from the
/// same build settings (`HQAppGroup`, `HQKeychainService`).
nonisolated enum ShareIdentity {
    /// `group.com.charlesmcdowell.dispatch` in the Hermes HQ record; nil in the native identity (it has no App Group).
    static let appGroup: String? = value("HQAppGroup")
    /// The app's sign-in item: service `ai.hermes.ios.gateway` in the Hermes HQ record, account `primary`.
    static let keychainService: String = value("HQKeychainService") ?? "ai.hermes.ios.gateway"
    static let keychainAccount = "primary"

    /// Storage names stay as build 240 wrote them (spec D10): nobody sees them, and a roster, a remembered bot or a
    /// last-sent note written by build 240 is read by this build after the update.
    static let folderPath = "Library/Application Support/Dispatch Share"
    /// The folder on the gateway that staged uploads go to, and the prefix of this process's temporary folders.
    static let stagingFolder = ".dispatch-attachments"
    static let temporaryPrefix = "dispatch-share-"

    /// The shared folder, or nil when this build has no App Group (the native identity, a build without the entitlement).
    static func folder(_ manager: FileManager = .default) -> URL? {
        guard let appGroup, let container = manager.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        return container.appendingPathComponent(folderPath, isDirectory: true)
    }

    private static func value(_ key: String) -> String? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: key) as? String, !text.isEmpty else { return nil }
        return text
    }
}
