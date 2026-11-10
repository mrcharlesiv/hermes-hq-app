// [offline] Which unexpected errors stop startup (docs/spec/3x-offline.md §3.4), from the web app's `strayErrorIsFatal`
// (`src/connection-startup.ts`), and the check that this phone's saved app data can be opened for an account.

import Foundation

nonisolated enum StartupPhase: Sendable, Equatable {
    /// Until the restore decided what to show.
    case booting
    /// The sign-in form, up to the account being activated.
    case signingIn
    /// The app is on screen.
    case mounted
    /// The offline screen.
    case offline
}

/// This phone's saved app data can't be opened for the account (a folder can't be made or written).
nonisolated struct AccountStorageError: Error, Equatable, Sendable, LocalizedError {
    var path: String
    var errorDescription: String? { StartupProblems.storage }
}

nonisolated enum StartupProblems {
    /// Shown over the launch screen's Try Again, so it points at that button rather than at quitting the app.
    static let couldNotStart = "Hermes HQ couldn’t start. \(DeviceWord.Tap) Try Again."
    /// Also the reason in the gateway switcher's alert and on Settings › Gateway, so "try again" is not a button name.
    static let storage = "Hermes HQ couldn’t switch this \(DeviceWord.name)’s saved app data to this account. Your drafts are kept. "
        + "If \(DeviceWord.name) storage is almost full, free up some space, then try again."

    /// A storage failure is always shown unless the app is already on screen; any other unexpected error ends startup
    /// only while starting or signing in. A gateway or sign-in failure, or a cancel, is never "stray": their own screens
    /// word them.
    static func isFatal(phase: StartupPhase, error: any Error) -> Bool {
        if error is AccountStorageError { return phase != .mounted }
        if error is GatewayFailure || error is RPCError || error is HTTPError || error is CancellationError || error is RetryLater { return false }
        if let url = error as? URLError, url.code == .cancelled { return false }
        return phase == .booting || phase == .signingIn
    }

    static func message(for error: any Error) -> String {
        error is AccountStorageError ? storage : couldNotStart
    }
}

nonisolated enum AccountStorage {
    /// The folders an account's saved data lives in on this phone.
    static func roots(for account: GatewayAccount) -> [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return [support.appending(path: "lists", directoryHint: .isDirectory),          // roster and sessions lists
                TranscriptCache.shared.root,                                           // saved chats
                PagesCache.directory(for: account),                                    // Jobs, Kanban, Artifacts
                support.appending(path: "queues", directoryHint: .isDirectory)]        // messages kept queued
    }

    /// Makes each folder and writes and removes a one-byte probe file in it. Throws for the first that fails.
    static func check(roots: [URL], fileManager: FileManager = .default) throws(AccountStorageError) {
        for root in roots {
            let probe = root.appending(path: ".hq-probe-\(UUID().uuidString)")
            do {
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
                try Data([0]).write(to: probe)
                try fileManager.removeItem(at: probe)
            } catch {
                try? fileManager.removeItem(at: probe)
                throw AccountStorageError(path: root.lastPathComponent)
            }
        }
    }

    static func check(_ account: GatewayAccount) throws(AccountStorageError) {
        try check(roots: roots(for: account))
    }
}

/// The gateway the app last opened, so the offline screen can name it while the Keychain cannot be read (§3.5).
/// Nothing secret: an address, the account's display name and the name given on this phone.
nonisolated struct LastGatewayHint: Codable, Equatable, Sendable {
    var url: String
    var accountName: String
    var label: String?
    var username: String?

    static let key = "hqn.offline.lastGateway"

    static func load(_ defaults: UserDefaults = .standard) -> LastGatewayHint? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LastGatewayHint.self, from: data)
    }

    func save(_ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }

    static func clear(_ defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}

extension AccountStorage {
    /// The check off the main thread (launch, after a sign-in, before a gateway switch). In DEBUG
    /// `-HQDebugStorageFailure YES` makes it fail, and `-HQDebugStorageFailure switch` only before a gateway switch.
    static func checkOffMain(_ account: GatewayAccount, switching: Bool = false) async throws(AccountStorageError) {
        #if DEBUG
        let hook = UserDefaults.standard.string(forKey: "HQDebugStorageFailure")
        if hook == "YES" || (switching && hook == "switch") { throw AccountStorageError(path: "debug") }
        #endif
        let failure = await Task.detached(priority: .userInitiated) { () -> AccountStorageError? in
            do throws(AccountStorageError) {
                try check(account)
                return nil
            } catch {
                return error
            }
        }.value
        if let failure { throw failure }
    }
}
