// A REST-only client for a saved gateway that isn't in use (spec 1x-settings §4.7): reads one stored chat at a time
// with that account's own session, so the title switcher can say which other gateways have news. No socket. A Nous
// account renews through the shared single flight and writes the rotated pair back with compare-and-swap
// (`GatewayAuth`, spec 01 §7.3); a refused session ends that account's sign-in on this phone ("Signed Out").

import Foundation

nonisolated final class AccountProbe: Sendable {
    let account: GatewayAccount
    private let auth: GatewayAuth
    private let transport: HTTPTransport

    init(stored: StoredAccount, vault: AccountVault = .app, renewals: NousRenewals = .shared) {
        let base = URL(string: stored.url) ?? URL(string: "https://invalid.invalid")!
        account = stored.gatewayAccount ?? GatewayAccount(id: stored.url + "|" + stored.username, baseURL: base,
                                                          kind: stored.isNous ? .nous : .password, username: nil, label: stored.url)
        let transport = HTTPTransport(cookies: !stored.isNous, headers: stored.accessHeaders)
        if !stored.isNous { transport.installCookies(stored.cookies ?? []) }
        self.transport = transport
        // Verified: the saved session is the one this phone signed in with; a renewal it causes is written back.
        auth = GatewayAuth(stored: stored, base: base, transport: transport, vault: vault, verified: true,
                           renewals: renewals, logContext: "another gateway")
    }

    enum Answer: Sendable, Equatable {
        case session(JSONValue)
        /// The gateway refused the session (after one renewal): this account is signed out here.
        case refused
        /// Not found / not readable: no answer about this chat.
        case missing
    }

    /// `GET /api/sessions/<id>[?profile=<p>]`, 8 s. Throws only for transport failures (unreachable, timeout).
    func session(id: String, profile: String?) async throws -> Answer {
        guard GatewayNews.sessionIdPattern.test(id) else { return .missing }
        var query: [URLQueryItem] = []
        if let profile, profile != "default" { query.append(URLQueryItem(name: "profile", value: profile)) }
        let url = try GatewayAddress.endpoint(base: account.baseURL, path: "/api/sessions/" + id, query: query)
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let began = ContinuousClock.now
        do {
            let (data, response) = try await auth.send(request)
            switch response.statusCode {
            case 200..<300:
                let parsed = try? JSONValue.parse(data)
                AppLog.trace("net", "probe \(AppLog.tag(id)): \(parsed == nil ? "unreadable" : "ok"), \(AppLog.ms(since: began))ms")
                return parsed.map(Answer.session) ?? .missing
            case 401, 403:
                // [kept-session] Not Hermes's own refusal: the chat is neither refused nor gone, the gateway is blocked.
                guard GatewayRefusal.isHermes(data) else { throw GatewayFailure.blocked }
                AppLog.note("net", "probe \(AppLog.tag(id)): refused, \(AppLog.ms(since: began))ms")
                return .refused
            default:
                AppLog.trace("net", "probe \(AppLog.tag(id)): missing (HTTP \(response.statusCode)), \(AppLog.ms(since: began))ms")
                return .missing
            }
        } catch let failure as GatewayFailure where failure.isRejection {
            AppLog.note("net", "probe \(AppLog.tag(id)): refused (\(failure.code)), \(AppLog.ms(since: began))ms")
            return .refused
        } catch {
            AppLog.swallowed("net", "probe \(AppLog.tag(id))", error)
            throw error
        }
    }

    /// [update-flow] Any REST call with this account's session (the Update sheet on a gateway that isn't in use): the
    /// answer parsed, `HTTPError` for a non-2xx (its body kept, so the gateway's own reason shows).
    func json(_ method: String, _ path: String, query: [URLQueryItem], body: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        let url = try GatewayAddress.endpoint(base: account.baseURL, path: path, query: query)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try body.encoded()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await auth.send(request)
        guard (200..<300).contains(response.statusCode) else {
            AppLog.trace("net", "probe \(method) \(path): HTTP \(response.statusCode)")
            throw HTTPError(status: response.statusCode, body: String(data: data.prefix(2000), encoding: .utf8))
        }
        return data.isEmpty ? .null : try JSONValue.parse(data)
    }

    /// Renews a Nous session whose refresh token has sat untouched long enough to risk Portal's 24 h idle expiry
    /// (e.g. a parked gateway with no cached chats, or a background refresh wake-up).
    func keepAlive(olderThan age: TimeInterval = NousSessionKeepAlive.defaultInterval) async throws -> Answer {
        let began = ContinuousClock.now
        do {
            let renewed = try await auth.keepAlive(olderThan: age)
            if renewed { AppLog.trace("net", "probe keepalive \(AppLog.tag(account.id)): renewed in \(AppLog.ms(since: began))ms") }
            return .session(.null)
        } catch let failure as GatewayFailure where failure.isRejection {
            AppLog.note("net", "probe keepalive \(AppLog.tag(account.id)): refused (\(failure.code)), \(AppLog.ms(since: began))ms")
            return .refused
        } catch {
            AppLog.swallowed("net", "probe keepalive \(AppLog.tag(account.id))", error)
            throw error
        }
    }

    /// A renewal the read started alongside finishes first (`GatewayAuth.settleRenewal`): cancelling it can lose the
    /// rotated pair and sign the account out.
    func close() {
        let auth = self.auth, transport = self.transport
        Task {
            await auth.settleRenewal()
            await auth.close()
            transport.invalidate()
        }
    }
}

/// Keeps saved Nous sessions alive before Portal's 24 h rotating refresh token expires (during iOS `BGAppRefreshTask`
/// wakes or while the Mac app sits in the background). Only touches accounts whose latest known pair is at least
/// `interval` old, and never touches Keychain while locked.
nonisolated enum NousSessionKeepAlive {
    static let defaultInterval: TimeInterval = 4 * 3600

    @discardableResult
    static func refreshDue(vault: AccountVault = .app, renewals: NousRenewals = .shared,
                           olderThan interval: TimeInterval = defaultInterval,
                           now: Double = Date().timeIntervalSince1970,
                           makeProbe: ((StoredAccount) -> AccountProbe)? = nil) async -> Int {
        guard !vault.isLocked else { return 0 }
        guard let saved = try? vault.load() else { return 0 }
        var refreshed = 0
        for stored in saved.accounts {
            if Task.isCancelled { break }
            guard stored.isNous, let tokens = stored.nous, tokens.canRenew else { continue }
            let live = await renewals.latest(tokens)
            guard live.needsKeepAlive(after: interval, now: now) else { continue }
            guard let base = URL(string: stored.url), GatewayAddress.reachable(base) else { continue }
            let probe = makeProbe?(stored) ?? AccountProbe(stored: stored, vault: vault, renewals: renewals)
            if let answer = try? await probe.keepAlive(olderThan: interval), case .session = answer { refreshed += 1 }
            probe.close()
        }
        return refreshed
    }
}
