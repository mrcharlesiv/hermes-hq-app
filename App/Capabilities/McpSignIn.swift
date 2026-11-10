// Signing in to a connector with OAuth (docs/spec/3x-capabilities.md §5.4, rows L718 and L996): the app listens on
// loopback (`LoopbackRelay`), the gateway starts the flow with that redirect, the provider's page opens in the system
// sign-in sheet (`WebAuthBrowser`, as Sign in with Nous does), the relay hands the callback to the gateway and the
// gateway's poll says when it is done. Nothing here imports AuthenticationServices or SafariServices.

import UIKit

@MainActor final class McpSignIn {
    enum Outcome: Equatable { case signedIn(tools: Int), cancelled, failed(String) }

    static var tooOld: String { "This gateway’s Hermes is too old to sign in to connectors from your \(DeviceWord.name). Update Hermes on \(HostWord.updateTarget), or sign in there." }
    /// Only one sign-in at a time app-wide.
    static private(set) var running = false
    /// Tests swap the system sheet for a URLSession driver.
    static var makeBrowser: (UIWindow?) -> any NousBrowser = { WebAuthBrowser(anchor: $0) }

    let store: CapabilitiesStore
    var lifetime: TimeInterval = 360
    var pollEvery: Duration = .seconds(1)
    private var task: Task<Outcome, Never>?

    init(store: CapabilitiesStore) { self.store = store }

    /// Leaving the page ends the flow (the gateway's session is cancelled on the way out).
    func cancel() { task?.cancel() }

    /// The redirect inside `auth_url` must be this phone's listener, and the page must be https (loopback http only
    /// in DEBUG, for the stand-in gateway).
    nonisolated static func accepts(authURL: String, redirect: String) -> URL? {
        guard let url = URL(string: authURL), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = url.scheme?.lowercased() else { return nil }
        var allowed = scheme == "https"
        #if DEBUG
        if scheme == "http", let host = url.host, host == "127.0.0.1" || host == "localhost" { allowed = true }
        #endif
        guard allowed, parts.queryItems?.first(where: { $0.name == "redirect_uri" })?.value == redirect else { return nil }
        return url
    }

    func run(server: String, profile: String, window: UIWindow?) async -> Outcome {
        guard !Self.running else {
            AppLog.note("connect", "connector \(server) sign-in refused: another sign-in is already open")
            return .failed("Another sign-in is still open. Finish or close it first.")
        }
        Self.running = true
        defer { Self.running = false }
        let work = Task { @MainActor in await flow(server: server, profile: profile, window: window) }
        task = work
        return await work.value
    }

    private func flow(server: String, profile: String, window: UIWindow?) async -> Outcome {
        let browser = Self.makeBrowser(window)
        let listener: (id: String, redirectURI: String)
        do {
            listener = try await LoopbackRelay.shared.listen(closeBrowser: { Task { @MainActor in browser.close() } }, lifetime: lifetime)
        } catch {
            return .failed("Couldn’t open the sign-in sheet. Try again.")
        }
        var session: String?
        var outcome = Outcome.cancelled
        do {
            let started = try await store.oauthStart(server, redirect: listener.redirectURI, profile: profile)
            session = started.sessionId
            guard let url = Self.accepts(authURL: started.authURL, redirect: listener.redirectURI) else { throw Stop.failed(Self.tooOld) }
            let closed = Flag()
            guard browser.open(url, userCancelled: { closed.set() }) else { throw Stop.failed("Couldn’t open the sign-in sheet. Try again.") }
            outcome = await wait(server: server, profile: profile, session: started.sessionId, listener: listener.id, closed: closed)
        } catch Stop.failed(let reason) {
            outcome = .failed(reason)
        } catch {
            outcome = .failed(CapabilitiesStore.detail(error))
        }
        browser.close()
        LoopbackRelay.shared.cancel(listener.id)
        if case .signedIn = outcome {} else if let session { await store.oauthCancel(server, session: session, profile: profile) }
        return outcome
    }

    private enum Stop: Error { case failed(String) }
    @MainActor private final class Flag { private(set) var isSet = false; func set() { isSet = true } }

    private func wait(server: String, profile: String, session: String, listener: String, closed: Flag) async -> Outcome {
        let lifetime = self.lifetime
        // The callback, relayed to the gateway as soon as it arrives.
        let caught = Flag()
        let relay = Task { @MainActor [store] in
            let callback = await LoopbackRelay.shared.wait(listener, timeout: lifetime)
            guard callback.code != nil || (callback.error != nil && callback.state != nil) else { return }
            caught.set()
            try? await store.oauthCallback(server, session: session, callback: callback, profile: profile)
        }
        defer { relay.cancel() }
        let deadline = Date().addingTimeInterval(lifetime)
        var failures = 0
        var closedAt: Date?
        while true {
            if Task.isCancelled { return .cancelled }
            if Date() >= deadline { return .failed("The sign-in took too long. Try again.") }
            do {
                let poll = try await store.oauthPoll(server, session: session, profile: profile)
                failures = 0
                if poll.status == "approved" { return .signedIn(tools: poll.tools) }
                if poll.status == "error" {
                    return .failed(poll.errorMessage.isEmpty ? "The sign-in didn’t finish. Try again." : McpEntryMask.phone.text(poll.errorMessage))
                }
            } catch {
                failures += 1
                if failures >= 3 {
                    AppLog.note("connect", "connector \(server) sign-in poll lost the gateway 3 times in a row")
                    return .failed("Lost the gateway while signing in. Try again.")
                }
            }
            // The person closed the sheet and no callback came: cancelled, quietly. (The relay closes the sheet itself on
            // a callback, which also reports "closed", so give the gateway a moment to say approved or error first.)
            if closed.isSet {
                if closedAt == nil { closedAt = Date() }
                if let closedAt, Date().timeIntervalSince(closedAt) > (caught.isSet ? 8 : 1.5) { return .cancelled }
            }
            try? await Task.sleep(for: pollEvery)
        }
    }
}
