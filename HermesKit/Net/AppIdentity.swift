// Which App Store identity this build is (project.yml `HQ_IDENTITY`, docs/parity-240.md "Moving HQ Native into the same
// App Store record"): `native` = HQ Native's own record (com.charlesmcdowell.hermeshq.native), `original` = the Hermes HQ
// record the web app shipped in (com.charlesmcdowell.dispatch). The build writes the values into Info.plist (HQIdentity…);
// everything that differs between the two reads them here: the Keychain item of the sign-in, the pending sign-out mark,
// the URL scheme, the App Group and whether push can work at all (the relay and the hermes-hq-push plugin accept only the
// original topic).

import Foundation

nonisolated struct AppIdentity: Sendable, Equatable {
    enum Kind: String, Sendable { case native, original }

    var kind: Kind
    var bundleId: String
    var keychainService: String
    var signedOutKey: String
    var urlScheme: String
    var appGroup: String?
    var displayName: String

    /// The APNs topic the push relay (push.getdispatchapp.com) and the hermes-hq-push plugin accept (plugin TOPIC).
    static let pushTopic = "com.charlesmcdowell.dispatch"

    static let native = AppIdentity(kind: .native, bundleId: "com.charlesmcdowell.hermeshq.native",
                                    keychainService: "ai.hermes.hqnative.gateway", signedOutKey: "hqnative.vault.signedOut",
                                    urlScheme: "hermeshq-native", appGroup: nil, displayName: "Hermes HQ")
    /// The web app's own values (build 240): an update keeps people signed in and registered for push.
    static let original = AppIdentity(kind: .original, bundleId: "com.charlesmcdowell.dispatch",
                                      keychainService: "ai.hermes.ios.gateway", signedOutKey: "dispatch.vault.signedOut",
                                      urlScheme: "hermes", appGroup: "group.com.charlesmcdowell.dispatch", displayName: "Hermes HQ")

    /// This build's identity, from Info.plist (a test host without the keys reads as `native`).
    static let current: AppIdentity = from(Bundle.main.infoDictionary ?? [:], bundleId: Bundle.main.bundleIdentifier)

    static func from(_ info: [String: Any], bundleId: String?) -> AppIdentity {
        let kind = Kind(rawValue: info["HQIdentity"] as? String ?? "") ?? .native
        var identity = kind == .original ? Self.original : Self.native
        if let bundleId, !bundleId.isEmpty { identity.bundleId = bundleId }
        if let service = info["HQKeychainService"] as? String, !service.isEmpty { identity.keychainService = service }
        if let key = info["HQSignedOutKey"] as? String, !key.isEmpty { identity.signedOutKey = key }
        if let group = info["HQAppGroup"] as? String { identity.appGroup = group.isEmpty ? nil : group }
        if let name = info["CFBundleDisplayName"] as? String, !name.isEmpty { identity.displayName = name }
        if let types = info["CFBundleURLTypes"] as? [[String: Any]],
           let scheme = (types.first?["CFBundleURLSchemes"] as? [String])?.first, !scheme.isEmpty { identity.urlScheme = scheme }
        return identity
    }

    /// Pushed alerts can reach this build: only the original topic is accepted by the relay and the plugin.
    var canPush: Bool { bundleId == Self.pushTopic }
}
