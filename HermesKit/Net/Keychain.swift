// The sign-in's Keychain item (spec 01 §2.4.1, decision D3): service `ai.hermes.hqnative.gateway` (the `original`
// identity: the web app's own `ai.hermes.ios.gateway`, so an update from it keeps people signed in), account `primary`, the app's default access group, `AfterFirstUnlockThisDeviceOnly` (was `WhenUnlocked…`: a renewal in the background while locked could not be saved, and the next launch, an update, was signed out with the spent token; the first write after an update moves an old item over), the `SavedAccounts` JSON. Every
// read-modify-write runs in one lane, so a renewal written off the main thread never loses a sign-in's write.

import Foundation
import Security

nonisolated struct AccountVault: Sendable {
    let service: String
    let account: String
    /// UserDefaults key of the "sign-out not yet written" mark (spec 01 §2.4 "Failed sign-out").
    let signedOutKey: String
    /// Tests: stands in for the phone's lock state (`isLocked`).
    var lockedForTests: (@Sendable () -> Bool)?

    /// This build's item (AppIdentity: HQ Native's own, or the web app's in the original record).
    static let app = AccountVault(service: AppIdentity.current.keychainService, account: "primary",
                                  signedOutKey: AppIdentity.current.signedOutKey)

    init(service: String, account: String = "primary", signedOutKey: String) {
        self.service = service; self.account = account; self.signedOutKey = signedOutKey
    }

    /// One lane for every vault (re-entrant, so a rule may call another rule inside it).
    private static let lane = NSRecursiveLock()
    private func serialized<T, E: Error>(_ work: () throws(E) -> T) throws(E) -> T {
        Self.lane.lock(); defer { Self.lane.unlock() }
        return try work()
    }
    /// Writes that need not hold up their caller (a cookie renewal on a response) go out on this queue, in order.
    private static let laterQueue = DispatchQueue(label: "ai.hermes.hqnative.vault", qos: .utility)

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    // MARK: Reads

    /// Every saved account. A sign-out whose Keychain write failed is retried first: its account is never restored.
    func load() throws(GatewayFailure) -> SavedAccounts? {
        try serialized { () throws(GatewayFailure) -> SavedAccounts? in
            if signedOutPending { _ = try? clearCurrentLocked(); if signedOutPending { return nil } }
            return try raw()
        }
    }

    /// The current account without writing anything; a pending sign-out reads as nobody.
    func peek() -> StoredAccount? {
        serialized {
            guard !signedOutPending else { return nil }
            return (try? raw())?.active
        }
    }

    /// One saved account by key, without writing anything.
    func peek(_ key: String) -> StoredAccount? {
        serialized { (try? raw())?.account(key) }
    }

    /// True while the phone is locked and the item can't be read (`errSecInteractionNotAllowed`). With the sign-in
    /// item's access level `AfterFirstUnlockThisDeviceOnly` (not `WhenUnlocked…`), this only fires between a restart
    /// and the device's first unlock; a renewal later in a locked session still reads and writes fine.
    /// [n20 B1] A Nous renewal must not spend its refresh token while this is true: Portal revokes the whole session
    /// when a spent one comes back, and a successor that can't be written anywhere is lost if iOS ends the app before
    /// the next unlock (an update).
    var isLocked: Bool {
        if let lockedForTests { return lockedForTests() }
        return serialized {
            do throws(GatewayFailure) { _ = try raw(); return false }
            catch { return error == .keychainLocked }
        }
    }

    // MARK: Writes

    /// Saves an account (a sign-in) and makes it current; the others stay. Lifts a pending sign-out mark.
    func save(_ stored: StoredAccount) throws(GatewayFailure) {
        try serialized { () throws(GatewayFailure) in
            var list = try editable()
            list.save(stored)
            try store(list)
            markSignedOut(false)
        }
    }

    /// Changes one account in place (a cookie renewal); order and the current account are untouched.
    @discardableResult func update(_ key: String, _ change: @Sendable (inout StoredAccount) -> Void) throws(GatewayFailure) -> Bool {
        try serialized { () throws(GatewayFailure) -> Bool in
            var list = try editable()
            guard list.update(key, change) else { return false }
            try store(list)
            return true
        }
    }

    /// `update`, off the caller's thread, best effort.
    func updateLater(_ key: String, _ change: @escaping @Sendable (inout StoredAccount) -> Void) {
        let vault = self
        Self.laterQueue.async { _ = try? vault.update(key, change) }
    }

    /// Runs `work` on the vault's write queue, after every write queued before it.
    func later(_ work: @escaping @Sendable () -> Void) { Self.laterQueue.async(execute: work) }

    /// Compare-and-swap for a renewed cookie session (spec 01 §5.3): written only while the account still holds
    /// `expected` (by name and value). A session refused, signed out or replaced by a new sign-in in the meantime is
    /// never written back. False when nothing was written (no match, or Keychain refused the write).
    func swapCookies(_ key: String, expected: [SavedCookie], new: [SavedCookie]) -> Bool {
        do {
            return try serialized { () throws(GatewayFailure) -> Bool in
                var list = try editable()
                guard let held = list.account(key)?.cookies, !held.isEmpty, SavedCookie.same(held, expected) else { return false }
                list.update(key) { $0.cookies = new }
                try store(list)
                return true
            }
        } catch { return false }
    }

    /// Makes a saved account current (a switch).
    func select(_ key: String) throws(GatewayFailure) -> Bool {
        try serialized { () throws(GatewayFailure) -> Bool in
            var list = try editable()
            guard list.select(key) else { return false }
            try store(list)
            return true
        }
    }

    /// Compare-and-swap for a rotated Nous pair (spec 01 §7.3 rule 4). False when Keychain refused the write (locked);
    /// true when written or when the account no longer holds `sent` (a newer sign-in wins; nothing to write).
    func renewNous(_ key: String, sent: NousTokens, renewed: NousTokens) -> Bool {
        do {
            return try serialized { () throws(GatewayFailure) -> Bool in
                var list = try editable()
                guard list.renewNous(key, sent: sent, renewed: renewed) else {
                    // [n20 B1] Content-free: the saved sign-in holds neither the pair that was sent nor its successor
                    // (another copy of the app wrote it, or it is gone). The next launch reads that copy, not this run's.
                    if let note = Self.skippedRenewalNote(held: list.account(key)?.nous, sent: sent, renewed: renewed) {
                        AppLog.note("net", note)
                    }
                    return true
                }
                try store(list)
                return true
            }
        } catch { return false }
    }

    /// [n20 B1] Why a rotated pair was not written, for the log (nil when there is nothing odd: the successor is
    /// already saved). Never a token.
    static func skippedRenewalNote(held: NousTokens?, sent: NousTokens, renewed: NousTokens) -> String? {
        guard let held else { return "auth: a renewed sign-in was not saved: no saved sign-in holds it any more" }
        if held.samePair(renewed) || held.samePair(sent) { return nil }
        return "auth: a renewed sign-in was not saved: the saved one is another pair (\(held.ageNote()))"
    }

    /// A refused session: its cookies or tokens go; the address, username and label stay (the prefilled form).
    func forgetSession(_ key: String) {
        _ = try? update(key) { $0 = $0.withoutSession }
    }

    /// Forgets one account that is not the current one.
    func remove(_ key: String) throws(GatewayFailure) -> StoredAccount? {
        try serialized { () throws(GatewayFailure) -> StoredAccount? in
            var list = try editable()
            guard list.current != key else { throw .accountCurrent }
            guard let removed = list.remove(key) else { return nil }
            try store(list)
            return removed
        }
    }

    /// Sign-out: the current account goes; the most recently used other one becomes current (returned). With none left
    /// the item goes. If Keychain can't take it now, the mark keeps the account from being restored and retries later.
    @discardableResult func clearCurrent() throws(GatewayFailure) -> StoredAccount? {
        try serialized { () throws(GatewayFailure) -> StoredAccount? in
            do { return try clearCurrentLocked() }
            catch { markSignedOut(true); throw .keychainClearFailed }
        }
    }

    /// Deletes the whole item (tests, "forget everything").
    func removeAll() {
        serialized {
            _ = SecItemDelete(query as CFDictionary)
            markSignedOut(false)
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    /// [onboarding] Simulator checks only (`-HQDebugCorruptSignIn`): the item's bytes become something that is not a
    /// saved-accounts record, so the next read fails as unreadable.
    func debugMakeUnreadable() {
        serialized {
            let changes: [String: Any] = [kSecValueData as String: Data("not a saved sign-in".utf8),
                                          kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
            if SecItemUpdate(query as CFDictionary, changes as CFDictionary) == errSecItemNotFound {
                _ = SecItemAdd(query.merging(changes) { _, new in new } as CFDictionary, nil)
            }
            markSignedOut(false)
        }
    }
    #endif

    // MARK: Lane internals

    private var signedOutPending: Bool { UserDefaults.standard.bool(forKey: signedOutKey) }
    private func markSignedOut(_ value: Bool) {
        if value { UserDefaults.standard.set(true, forKey: signedOutKey) } else { UserDefaults.standard.removeObject(forKey: signedOutKey) }
    }

    @discardableResult private func clearCurrentLocked() throws(GatewayFailure) -> StoredAccount? {
        var next: StoredAccount?
        do throws(GatewayFailure) {
            if var list = try raw() {
                if let current = list.current { list.remove(current) } else { list = SavedAccounts() }
                try store(list)
                next = list.active
            }
        } catch .keychainUnreadable {
            // Nobody's sign-in can be read from it: it goes whole.
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw .keychainClearFailed }
        }
        markSignedOut(false)
        return next
    }

    private func raw() throws(GatewayFailure) -> SavedAccounts? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if status == errSecInteractionNotAllowed { throw .keychainLocked }
        guard status == errSecSuccess, let data = result as? Data else { throw .keychainUnavailable }
        guard let value = SavedAccounts.decode(data) else { throw .keychainUnreadable }
        return value
    }

    /// The list a write starts from: an unreadable item is replaced, a locked one is not touched, and an account whose
    /// sign-out never reached Keychain is dropped now.
    private func editable() throws(GatewayFailure) -> SavedAccounts {
        var list: SavedAccounts
        do throws(GatewayFailure) { list = try raw() ?? SavedAccounts() }
        catch .keychainUnreadable { list = SavedAccounts() }
        if signedOutPending, let current = list.current { list.remove(current) }
        return list
    }

    /// Every list written here already lacks the account a pending sign-out was for (`editable` drops it,
    /// `clearCurrentLocked` removes it), so a write that lands settles the mark. Left set, the mark would mean "remove
    /// whoever is current" at the next launch, and after this write that is another gateway (a switch, or a renewal
    /// written while the next one became current).
    private func store(_ list: SavedAccounts) throws(GatewayFailure) {
        if list.accounts.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw .keychainUnavailable }
            if signedOutPending { markSignedOut(false) }
            return
        }
        guard let data = try? list.encoded() else { throw .keychainUnavailable }
        let changes: [String: Any] = [kSecValueData as String: data,
                                      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(changes) { _, new in new } as CFDictionary, nil)
        }
        if status == errSecInteractionNotAllowed { throw .keychainLocked }
        guard status == errSecSuccess else { throw .keychainUnavailable }
        if signedOutPending { markSignedOut(false) }
    }
}
