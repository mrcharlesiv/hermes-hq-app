// [onboarding] What `/api/status` says about this gateway's age (spec 01 §4.3, docs/spec/3x-onboarding.md §5.14):
// the web's rule (`W:src/gateway-compat.ts`), read after a typed sign-in and on each Check Again. Anything that can't
// be read as an older release is not outdated: a gateway is never turned away on a guess.

import Foundation

/// An older Hermes than this app needs, as the gateway reports itself.
nonisolated struct OutdatedGateway: Sendable, Equatable {
    /// `status.version` trimmed, its first 24 characters; "" when absent or not text. Never compared.
    var version: String
    /// `status.release_date` trimmed, as reported.
    var releaseDate: String
    /// `hermes update` works there (false for an install another tool manages).
    var canUpdate: Bool

    init(version: String = "", releaseDate: String, canUpdate: Bool = true) {
        self.version = version; self.releaseDate = releaseDate; self.canUpdate = canUpdate
    }
}

nonisolated enum GatewayCompatibility: Sendable, Equatable {
    case compatible
    /// Older than the contract this app needs: the "Update Hermes on Your Gateway" screen.
    case outdated(OutdatedGateway)
    /// Unreadable, slow, or not a release date: never blocks sign-in.
    case unknown

    /// `CONTRACT_RELEASES[8]` (gateway-compat.ts): the oldest Hermes release this client supports.
    static let minimumRelease = (2026, 9, 21)

    /// How long one read of the status may take (`STATUS_CHECK_MS`, `W:src/connection-startup.ts:25`).
    static let checkSeconds: Double = 4

    init(status: JSONValue) {
        guard let text = status["release_date"]?.string, let date = Self.parse(text) else { self = .unknown; return }
        guard date < Self.minimumRelease else { self = .compatible; return }
        let version = status["version"]?.string.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24)) } ?? ""
        self = .outdated(OutdatedGateway(version: version, releaseDate: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                         canUpdate: status["can_update_hermes"]?.bool != false))
    }

    var outdated: OutdatedGateway? {
        if case .outdated(let info) = self { return info }
        return nil
    }

    /// `YYYY.M.D` (trimmed; ASCII digits; four, then one or two, then one or two) → a comparable triple, nil when it
    /// isn't one: the web's `^(\d{4})\.(\d{1,2})\.(\d{1,2})$` with month 1…12 and day 1…31.
    static func parse(_ raw: String) -> (Int, Int, Int)? {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, (1...2).contains(parts[1].count), (1...2).contains(parts[2].count),
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        return (y, m, d)
    }
}

/// What the update screen says (`outdatedCopy`, `W:src/gateway-compat.ts:44-52`, `W:src/main.ts:396-398`). The release
/// is named as the gateway reports it.
nonisolated enum OutdatedCopy {
    static let title = "Update Hermes"
    static let checkAgain = "Check Again"
    static let continueAnyway = "Continue Anyway"
    static let checking = "Checking…"
    static let stillOlder = "Still the older version. An update can take a few minutes."

    static func recovery(canUpdate: Bool) -> String {
        "Hermes HQ needs a newer version of Hermes than \(HostWord.phrase) has, and parts of the app won’t work until it’s updated. "
            + (canUpdate ? "On \(HostWord.phrase), run “hermes update”, then check again."
                         : "Update Hermes on \(HostWord.updateTarget) the way it was installed, then check again.")
    }

    static func release(_ info: OutdatedGateway) -> String {
        (info.version.isEmpty ? "Hermes" : "Hermes \(info.version)") + " · released \(info.releaseDate)"
    }
}
