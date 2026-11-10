import Foundation
import Testing
@testable import HermesHQNative

/// The vault against the real Keychain (a test-only service name, never the app's item).
@Suite(.serialized) struct KeychainVaultTests {
    let vault = Fixtures.testVault("vault")

    func nous(_ n: Int) -> NousTokens {
        NousTokens(accessToken: "at\(n)", refreshToken: "rt\(n)", expiresAt: 2_000_000_000, userId: "u1", obtainedAt: 1_999_000_000)
    }

    @Test func roundTripCompareAndSwapAndSignOut() throws {
        vault.removeAll()
        defer { vault.removeAll() }
        #expect(try vault.load() == nil && vault.peek() == nil)

        let password = StoredAccount(url: "http://127.0.0.1:9", username: "fleet", cookies: [SavedCookie(name: "s", value: "1", domain: "127.0.0.1")], provider: "basic")
        let bearer = StoredAccount(url: "https://g.example.com", username: "nous:u1", label: "Studio", nous: nous(1))
        try vault.save(password)
        try vault.save(bearer)
        #expect(vault.peek()?.key == bearer.key)
        #expect(try vault.load()?.accounts.map(\.key) == [bearer.key, password.key])

        // A rotation lands only on the pair it started from.
        #expect(vault.renewNous(bearer.key, sent: nous(1), renewed: nous(2)))
        #expect(vault.peek()?.nous?.accessToken == "at2")
        #expect(vault.renewNous(bearer.key, sent: nous(1), renewed: nous(3))) // stale: nothing written, not a failure
        #expect(vault.peek()?.nous?.accessToken == "at2")

        // In-place updates keep order and the current account.
        #expect(try vault.update(password.key) { $0.cookies = [SavedCookie(name: "s", value: "2", domain: "127.0.0.1")] })
        #expect(vault.peek()?.key == bearer.key)
        #expect(vault.peek(password.key)?.cookies?.first?.value == "2")

        // Removing the current one is refused; switching then removing works.
        #expect(throws: GatewayFailure.accountCurrent) { _ = try vault.remove(bearer.key) }
        #expect(try vault.select(password.key))
        #expect(try vault.remove(bearer.key)?.key == bearer.key)

        // A refused session keeps only what the sign-in form needs.
        vault.forgetSession(password.key)
        let forgotten = try #require(vault.peek())
        #expect(forgotten.cookies == nil && forgotten.username == "fleet" && forgotten.provider == "basic")

        // Sign-out of the last account deletes the item.
        #expect(try vault.clearCurrent() == nil)
        #expect(try vault.load() == nil)
    }

    @Test func signOutPicksTheNextMostRecent() throws {
        vault.removeAll()
        defer { vault.removeAll() }
        let a = StoredAccount(url: "https://a.example.com", username: "one", cookies: [SavedCookie(name: "s", value: "1", domain: "a.example.com")])
        let b = StoredAccount(url: "https://b.example.com", username: "two", cookies: [SavedCookie(name: "s", value: "1", domain: "b.example.com")])
        try vault.save(a)
        try vault.save(b)
        #expect(try vault.clearCurrent()?.key == a.key)
        #expect(vault.peek()?.key == a.key)
    }

    @MainActor @Test func accountStoreMapsSavedAccounts() async throws {
        vault.removeAll()
        defer { vault.removeAll() }
        let store = AccountStore(vault: vault)
        try store.save(StoredAccount(url: "https://g.example.com", username: "nous:u1", nous: nous(1)))
        try store.save(StoredAccount(url: "http://studio.local:9119", username: "fleet", cookies: [SavedCookie(name: "s", value: "1", domain: "studio.local")]))
        #expect(store.accounts.count == 2)
        #expect(store.current?.username == "fleet" && store.current?.label == "studio.local")
        let nousAccount = try #require(store.accounts.first { $0.kind == .nous })
        #expect(try store.rename(nousAccount, label: "  Studio  "))
        #expect(store.accounts.first { $0.kind == .nous }?.label == "Studio")
        #expect(try store.select(nousAccount) && store.current?.kind == .nous)
        let service = SignInService(store: store)
        #expect(await service.restore()?.kind == .nous)
        #expect(service.signOut()?.username == "fleet")
        #expect(store.accounts.count == 1)
    }
}
