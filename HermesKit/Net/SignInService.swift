// The facade the sign-in screen and the app model use (spec 01 §4, §5, §6, §17). Every failure it throws is a
// `GatewayFailure` whose `message` is ready to show (empty for a cancelled Nous sheet).

import Foundation
import UIKit

@MainActor final class SignInService {
    enum RestoreState: Equatable {
        /// A saved session: show the app from cache at once; `client(for:)` checks the session as it connects.
        case signedIn(GatewayAccount)
        /// No usable session. `prefill` is the address (and username) of an account whose session ended.
        case signedOut(prefill: Prefill?)
        /// Keychain couldn't be read (locked before first unlock, unreadable…): say so and retry.
        case unavailable(GatewayFailure)

        /// For the diagnostic log (no address or name).
        var logLabel: String {
            switch self {
            case .signedIn(let account): "signed in (\(account.kind))"
            case .signedOut(let prefill): prefill == nil ? "signed out" : "session ended"
            case .unavailable(let failure): "keychain unavailable: \(failure.message)"
            }
        }
    }

    struct Prefill: Equatable, Sendable { var address: String; var username: String? }

    let store: AccountStore
    private var activeClient: LiveGatewayClient?
    private var signingIn = false

    init(store: AccountStore = AccountStore()) { self.store = store }

    var savedAccounts: [GatewayAccount] { store.accounts }
    var currentAccount: GatewayAccount? { store.current }

    // MARK: Probe

    /// Which sign-in buttons to show for the typed address (spec 01 §4.1). Never sends credentials.
    func probe(_ address: String) async -> ProbeResult {
        await SignInFlows.probe(address)
    }

    // MARK: Sign in

    /// Typed password sign-in: one attempt per call (never retried). Saves the account and makes it current.
    func signInWithPassword(address: String, username: String, password: String, label: String? = nil) async throws -> GatewayAccount {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !user.isEmpty, !password.isEmpty else {
            throw GatewayFailure.missingFields
        }
        let base = try GatewayAddress.validated(GatewayAddress.normalizeTyped(address))
        guard GatewayAddress.reachable(base) else { throw GatewayFailure.tailscaleOff }
        try beginSignIn()
        defer { signingIn = false }
        let transport = HTTPTransport()
        do {
            let (provider, cookies) = try await SignInFlows.passwordSignIn(base: base, username: user, password: password, transport: transport)
            let stored = StoredAccount(url: base.absoluteString, username: user, cookies: cookies, provider: provider,
                                       label: Self.accountLabel(label))   // [onboarding] the optional Name, kept on this phone only
            try await store.saveOffMain(stored)
            return adopt(store.storedCurrent ?? stored, transport: transport, verified: true)
        } catch {
            transport.invalidate()
            throw GatewayFailure.from(error)
        }
    }

    /// Sign in with Nous in the system sheet, presented over `anchor`.
    func signInWithNous(address: String, anchor: UIWindow?, label: String? = nil) async throws -> GatewayAccount {
        try await signInWithNous(address: address, browser: WebAuthBrowser(anchor: anchor, isPrivate: NousSheetLogin.isPrivate), label: label)
    }

    /// Sign in with Nous with any browser (tests drive the fixture's pages with URLSession).
    func signInWithNous(address: String, browser: NousBrowser, relay: LoopbackRelay = .shared, label: String? = nil) async throws -> GatewayAccount {
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GatewayFailure.missingFields }
        let base = try GatewayAddress.validated(GatewayAddress.normalizeTyped(address))
        guard GatewayAddress.reachable(base) else { throw GatewayFailure.tailscaleOff }
        try beginSignIn()
        defer { signingIn = false }
        let transport = HTTPTransport(cookies: false)
        do {
            // [own-login] "nous", or the gateway's own login provider (self-hosted OIDC) when it has no Nous one.
            let provider = try await SignInFlows.nousStatus(base: base, transport: transport)
            let outcome = try await NousSignIn.run(gateway: base, provider: provider, browser: browser, relay: relay)
            let tokens = try await SignInFlows.redeemNous(base: base, code: outcome.code, verifier: outcome.verifier,
                                                          provider: provider, transport: transport)
            let candidate = StoredAccount(url: base.absoluteString, username: StoredAccount.nousUsername(userId: tokens.userId),
                                          label: Self.accountLabel(label), nous: tokens)   // [onboarding] the optional Name
            // Check the bearer (renewing first if it is already due), then save the pair the gateway now honours.
            // `persisted: false`: a refused check must not touch a saved session of the same Nous account.
            let check = GatewayAuth(stored: candidate, base: base, transport: transport, vault: store.vault, verified: false,
                                    persisted: false)
            do { try await check.verify(budget: nil) }
            catch let failure as GatewayFailure where failure.isRejection { throw GatewayFailure.nousFailed }
            await check.close()
            try await store.saveOffMain(await check.stored)
            NousSheetLogin.finished()
            return adopt(store.storedCurrent ?? candidate, transport: transport, verified: true)
        } catch {
            transport.invalidate()
            throw GatewayFailure.from(error)
        }
    }

    /// [onboarding] The form's optional Name as an account label (`W:ios/App/App/HermesNative.swift:2011,2023`): trimmed,
    /// its first 60 characters; nil when blank, which keeps a label this phone already has for the account.
    nonisolated static func accountLabel(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return String(name.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func beginSignIn() throws {
        // One tap, one attempt: a second sign-in while one runs is refused, never queued.
        guard !signingIn else { throw GatewayFailure.gatewayError("sign-in already in progress") }
        signingIn = true
    }

    /// The new account's client replaces the previous one (whose session stays saved).
    private func adopt(_ stored: StoredAccount, transport: HTTPTransport, verified: Bool) -> GatewayAccount {
        activeClient?.shutdown()
        let client = LiveGatewayClient(stored: stored, transport: transport, vault: store.vault, verified: verified)
        activeClient = client
        return client.account
    }

    // MARK: Launch

    /// The current saved account with a session, read from Keychain off the main thread (no network; spec 01 §5.2).
    /// nil → show sign-in.
    func restore() async -> GatewayAccount? {
        if case .signedIn(let account) = await restoreState() { return account }
        return nil
    }

    /// Launch: what to show first. The Keychain read runs off the main thread (spec 01 §5.2).
    func restoreState() async -> RestoreState {
        do throws(GatewayFailure) {
            try await store.reloadOffMain()
        } catch {
            return .unavailable(error)
        }
        return currentRestoreState()
    }

    /// `restore()` reading Keychain on the calling (main) thread: tests and places that cannot wait.
    func restoreNow() -> GatewayAccount? {
        if case .signedIn(let account) = restoreStateNow() { return account }
        return nil
    }

    /// `restoreState()` reading Keychain on the calling (main) thread.
    func restoreStateNow() -> RestoreState {
        do throws(GatewayFailure) {
            try store.reload()
        } catch {
            return .unavailable(error)
        }
        return currentRestoreState()
    }

    private func currentRestoreState() -> RestoreState {
        guard let stored = store.storedCurrent, stored.hasSession, let account = stored.gatewayAccount else {
            return .signedOut(prefill: store.prefill().map { Prefill(address: $0.address, username: $0.username) })
        }
        return .signedIn(account)
    }

    /// The client for a saved account (made once; a restored one verifies its session as it first connects).
    func client(for account: GatewayAccount) -> LiveGatewayClient {
        if let activeClient, activeClient.account.id == account.id, !activeClient.isShutDown { return activeClient }
        activeClient?.shutdown()
        let stored = store.stored(account)
            ?? StoredAccount(url: account.baseURL.absoluteString, username: account.username ?? "", label: account.label)
        let client = LiveGatewayClient(stored: stored, transport: HTTPTransport(cookies: !stored.isNous), vault: store.vault, verified: false)
        activeClient = client
        return client
    }

    /// After a typed sign-in only: is this Hermes new enough (spec 01 §4.3)? `.unknown` never blocks.
    /// [onboarding] A read only: it asks the active client when that is this account's, and never makes or ends a
    /// client (Check Again under a locked sheet must not end another gateway's live client; D35).
    func compatibility(for account: GatewayAccount) async -> GatewayCompatibility {
        guard let activeClient, activeClient.account.id == account.id, !activeClient.isShutDown else { return .unknown }
        return await activeClient.compatibility()
    }

    /// The account the active client belongs to (tests).
    var activeAccountID: String? { activeClient.flatMap { $0.isShutDown ? nil : $0.account.id } }

    // MARK: Sign out, switch, remove (spec 01 §17)

    /// Signs out of the current account at once: socket closed, Keychain entry gone (the next most recent account
    /// becomes current and is returned). A password session is also ended on the gateway in the background (≤ 6 s,
    /// best effort); a Nous session ends on the phone (Portal has no revocation).
    @discardableResult func signOut() -> GatewayAccount? {
        let leaving = store.current
        let stored = store.storedCurrent
        let client = activeClient
        activeClient = nil
        client?.endClient()
        let next = try? store.signOutCurrent()
        if let leaving, let stored, leaving.kind == .password {
            let transport: HTTPTransport
            if let client { transport = client.httpTransport } else {
                transport = HTTPTransport()
                transport.installCookies(stored.cookies ?? [])
            }
            let base = leaving.baseURL
            Task.detached {
                _ = await withSignOutBudget { await SignInFlows.logout(base: base, transport: transport) }
                transport.invalidate()
            }
        } else {
            client?.httpTransport.invalidate()
        }
        return next
    }

    /// Makes another saved account current; the caller then asks `client(for:)`. Its session stays as it was.
    func switchTo(_ account: GatewayAccount) throws -> Bool {
        guard try store.select(account) else { return false }
        if let activeClient, activeClient.account.id != account.id {
            activeClient.shutdown()
            self.activeClient = nil
        }
        return true
    }

    /// Forgets another saved account (not the current one); a password session is ended on its gateway first.
    func remove(_ account: GatewayAccount) async throws {
        guard account.id != store.current?.id else { throw GatewayFailure.accountCurrent }
        guard let stored = store.stored(account) else { throw GatewayFailure.accountMissing }
        if account.kind == .password, let cookies = stored.cookies, !cookies.isEmpty {
            let transport = HTTPTransport()
            transport.installCookies(cookies)
            _ = await withSignOutBudget { await SignInFlows.logout(base: account.baseURL, transport: transport) }
            transport.invalidate()
        }
        try store.remove(account)
    }

    #if DEBUG && (targetEnvironment(simulator) || targetEnvironment(macCatalyst))
    /// Simulator (and [mac] Debug Mac builds) only: sign in from `HQN_SIGNIN_URL` / `HQN_SIGNIN_USERNAME` /
    /// `HQN_SIGNIN_PASSWORD` in the process environment (pass them as SIMCTL_CHILD_HQN_SIGNIN_* to `simctl launch`, or
    /// to the Mac app's executable). Never arguments or files.
    func debugSignInFromEnvironment() async throws -> GatewayAccount? {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HQN_SIGNIN_URL"], let user = env["HQN_SIGNIN_USERNAME"], let password = env["HQN_SIGNIN_PASSWORD"] else { return nil }
        return try await signInWithPassword(address: url, username: user, password: password)
    }
    #endif
}

/// Sign-out cleanup waits at most 6 s (spec 01 §17); whatever is still in flight is abandoned.
nonisolated func withSignOutBudget<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T? {
    await withChildTasks(of: T?.self) { group in
        group.addTask { await work() }
        group.addTask { try? await Task.sleep(for: .seconds(6)); return nil }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
