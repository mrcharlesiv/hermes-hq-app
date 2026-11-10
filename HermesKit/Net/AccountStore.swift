// The saved gateway accounts as the UI sees them (spec 01 §2, §17): the current one, all of them (most recent first),
// restore on launch, switch, sign out, remove. Secrets stay inside the vault; this hands out `GatewayAccount`s.

import Foundation

@MainActor final class AccountStore {
    let vault: AccountVault
    private(set) var accounts: [GatewayAccount] = []
    private(set) var current: GatewayAccount?
    private var storedByID: [String: StoredAccount] = [:]
    private var currentStored: StoredAccount?

    init(vault: AccountVault = .app) { self.vault = vault }

    /// Re-reads the Keychain item on the calling thread (an XPC round trip, a few ms; it may also wait for a renewal
    /// being written elsewhere). Throws keychain failures (locked, unreadable…). Prefer `reloadOffMain()` on the main
    /// thread.
    @discardableResult func reload() throws(GatewayFailure) -> SavedAccounts {
        let saved = try vault.load() ?? SavedAccounts()
        apply(saved)
        return saved
    }

    /// `reload()` with the Keychain read off the main thread; the result is applied back on the main actor.
    @discardableResult func reloadOffMain() async throws(GatewayFailure) -> SavedAccounts {
        let saved = try await Self.load(vault).get() ?? SavedAccounts()
        apply(saved)
        return saved
    }

    /// `save(_:)` with the Keychain write and re-read off the main thread.
    func saveOffMain(_ stored: StoredAccount) async throws(GatewayFailure) {
        let vault = self.vault
        try await Self.offMain { () throws(GatewayFailure) in try vault.save(stored) }.get()
        try await reloadOffMain()
    }

    @concurrent private nonisolated static func load(_ vault: AccountVault) async -> Result<SavedAccounts?, GatewayFailure> {
        Result { () throws(GatewayFailure) in try vault.load() }
    }

    @concurrent private nonisolated static func offMain(_ work: @Sendable () throws(GatewayFailure) -> Void) async -> Result<Void, GatewayFailure> {
        Result { () throws(GatewayFailure) in try work() }
    }

    private func apply(_ saved: SavedAccounts) {
        storedByID = [:]
        accounts = saved.accounts.compactMap { stored in
            guard let account = stored.gatewayAccount else { return nil }
            storedByID[account.id] = stored
            return account
        }
        currentStored = saved.active
        current = saved.active?.gatewayAccount
    }

    /// The saved record behind an account (nil when it is no longer saved).
    func stored(_ account: GatewayAccount) -> StoredAccount? { storedByID[account.id] }

    /// The current account's record.
    var storedCurrent: StoredAccount? { currentStored }

    /// Saves a verified sign-in and makes it current.
    func save(_ stored: StoredAccount) throws(GatewayFailure) {
        try vault.save(stored)
        try reload()
    }

    /// Makes another saved account current (its session stays as it was).
    func select(_ account: GatewayAccount) throws(GatewayFailure) -> Bool {
        guard let stored = storedByID[account.id] else { return false }
        let done = try vault.select(stored.key)
        try reload()
        return done
    }

    /// Sign-out of the current account: it leaves the list; the most recently used other one becomes current.
    func signOutCurrent() throws(GatewayFailure) -> GatewayAccount? {
        defer { _ = try? reload() }
        return try vault.clearCurrent()?.gatewayAccount
    }

    /// Forgets an account that is not the current one.
    func remove(_ account: GatewayAccount) throws(GatewayFailure) {
        guard let stored = storedByID[account.id] else { throw .accountMissing }
        _ = try vault.remove(stored.key)
        try reload()
    }

    /// Renames an account on this phone (blank: the host again). False when it isn't saved.
    func rename(_ account: GatewayAccount, label: String?) throws(GatewayFailure) -> Bool {
        guard let stored = storedByID[account.id] else { return false }
        let name = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = name?.isEmpty == false ? String(name!.prefix(60)) : nil
        let done = try vault.update(stored.key) { $0.label = value }
        try reload()
        return done
    }

    /// The current account's address and username when its session ended (the prefilled sign-in form). Nous accounts
    /// have no username to show.
    func prefill() -> (address: String, username: String?)? {
        guard let stored = currentStored, !stored.hasSession else { return nil }
        return (stored.url, stored.isNous ? nil : stored.username)
    }
}
