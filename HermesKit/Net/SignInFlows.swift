// The wire sequences of signing in (spec 01 §4.1, §5.1, §6.1 steps 2/9/10, §17): the public probe, the typed password
// sign-in, Nous's status check and code redemption, and the password logout. Each user action sends each request at
// most once: nothing here retries a sign-in on its own (spec 01 §15).

import Foundation

/// What `/api/status` says about the ways in (spec 01 §4.1).
nonisolated struct ProbeResult: Sendable, Equatable {
    var known: Bool
    var nous: Bool
    var password: Bool
    /// [own-login] The gateway's own browser login (self-hosted OIDC), offered when it has no Nous one. With it the
    /// browser way in is this login, not Nous.
    var ownLogin: BrowserLogin? = nil

    static let unknown = ProbeResult(known: false, nous: false, password: false)

    /// unknown → both; browser only → nous; password only → password; else both.
    var ways: SignInWays {
        guard known else { return .both }
        let browser = nous || ownLogin != nil
        if browser && !password { return .nous }
        if password && !browser { return .password }
        return .both
    }
}

/// Which ways in the sign-in form shows (`W:src/connection-ways.ts:16-31`). The screen builds it from `SignInOptions`
/// (App/SignIn/SignInDriving.swift); the Net module from a `ProbeResult`.
nonisolated enum SignInWays: String, Sendable, Equatable {
    /// Show "Sign in with Nous" first, then username + password.
    case both
    /// Only "Sign in with Nous" (Return in the address field signs in).
    case nous
    /// Only username + password.
    case password

    var showsNous: Bool { self != .password }
    var showsPassword: Bool { self != .nous }
}

nonisolated enum SignInFlows {
    static let signInTimeout: TimeInterval = 15

    // MARK: Probe

    /// Unauthenticated `GET /api/status` (no query), 5 s, cookieless, 1 MiB; anything odd is `.unknown` (show both).
    static func probe(_ address: String) async -> ProbeResult {
        guard let base = try? GatewayAddress.validated(GatewayAddress.normalizeTyped(address)), GatewayAddress.reachable(base),
              let url = try? GatewayAddress.endpoint(base: base, path: "/api/status") else { return .unknown }
        let plain = HTTPTransport(cookies: false)
        defer { plain.invalidate() }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await plain.data(for: request, pool: .bulk, ceiling: 1 << 20), response.statusCode == 200,
              let status = try? JSONValue.parseFast(data), let providers = status["auth_providers"]?.array?.compactMap(\.string)
        else { return .unknown }
        var result = ProbeResult(known: true, nous: NousGatewayProtocol.offersNous(status: status), password: providers.contains("basic"))
        // [own-login] No Nous, but a browser sign-in and a provider that isn't the password one: ask what it is.
        if !result.nous, NousGatewayProtocol.offersBrowserSignIn(status: status), providers.contains(where: { $0 != "basic" }),
           let listURL = try? GatewayAddress.endpoint(base: base, path: "/api/auth/providers") {
            var list = URLRequest(url: listURL, timeoutInterval: 5)
            list.httpShouldHandleCookies = false
            list.setValue("application/json", forHTTPHeaderField: "Accept")
            if let (body, answer) = try? await plain.data(for: list, pool: .bulk, ceiling: 1 << 20), answer.statusCode == 200,
               let parsed = try? JSONValue.parseFast(body) {
                result.ownLogin = NousGatewayProtocol.ownLogin(providers: parsed)
            }
        }
        return result
    }

    // MARK: Password (spec 01 §5.1)

    /// providers → password-login → auth/me, on `transport`'s fresh jar. Returns the provider and the session cookies.
    static func passwordSignIn(base: URL, username: String, password: String, transport: HTTPTransport) async throws -> (provider: String, cookies: [SavedCookie]) {
        // 1. The first provider that takes a password.
        let (providersStatus, providersBody) = try await control(base, "/api/auth/providers", transport: transport)
        if providersStatus == 404 {
            // A Hermes from before gateway sign-in still answers its public status.
            if let (code, body) = try? await control(base, "/api/status", transport: transport), code == 200,
               (try? JSONValue.parseFast(body))?["version"]?.string != nil { throw GatewayFailure.gatewayOutdated }
            throw GatewayFailure.notHermes
        }
        try requireSuccess(providersStatus, providersBody, refusal: .gatewayError("providers refused"))
        let providers = try object(providersBody)["providers"]?.array ?? []
        guard let provider = providers.first(where: { $0["supports_password"]?.bool == true })?["name"]?.string else {
            throw GatewayFailure.noPassword
        }
        // 2. One login (never retried).
        let body = try JSONSerialization.data(withJSONObject: ["provider": provider, "username": username, "password": password])
        let (loginStatus, loginBody) = try await control(base, "/auth/password-login", method: "POST", body: body, transport: transport)
        try requireSuccess(loginStatus, loginBody, refusal: .authRejected)
        _ = try object(loginBody)
        // 3. Verify the session (D4).
        let (meStatus, meBody) = try await control(base, "/api/auth/me", transport: transport)
        try requireSuccess(meStatus, meBody, refusal: .authRejected)
        try GatewayAuth.requireObject(meBody)
        return (provider, transport.cookies(for: base))
    }

    /// Best-effort `POST /auth/logout {}` (5 s). Real Hermes answers 302 (not followed), fixtures 200; true only for 2xx.
    static func logout(base: URL, transport: HTTPTransport) async -> Bool {
        guard let (status, _) = try? await control(base, "/auth/logout", method: "POST", body: Data("{}".utf8), timeout: 5, transport: transport)
        else { return false }
        return (200..<300).contains(status)
    }

    // MARK: Nous (spec 01 §6.1)

    /// Step 2: 200 JSON with an `auth_required` key, else not Hermes; must offer a browser sign-in to native apps.
    /// Answers the provider to sign in with: "nous", or [own-login] the gateway's own login when it has no Nous one.
    @discardableResult static func nousStatus(base: URL, transport: HTTPTransport) async throws -> String {
        let (status, body) = try await control(base, "/api/status", transport: transport)
        guard status == 200, let value = try? JSONValue.parseFast(body), value["auth_required"] != nil else {
            if status == 429 { throw GatewayFailure.rateLimited }
            if status == 400, String(decoding: body.prefix(512), as: UTF8.self).contains("Invalid Host header") { throw GatewayFailure.hostRejected }
            throw GatewayFailure.notHermes
        }
        if NousGatewayProtocol.offersNous(status: value) { return NousGatewayProtocol.nous }
        guard NousGatewayProtocol.offersBrowserSignIn(status: value),
              let (code, list) = try? await control(base, "/api/auth/providers", transport: transport), code == 200,
              let parsed = try? JSONValue.parseFast(list), let own = NousGatewayProtocol.ownLogin(providers: parsed)
        else { throw GatewayFailure.nousUnavailable }
        AppLog.note("auth", "browser sign-in with the gateway's own login provider")
        return own.provider
    }

    /// Steps 9–10: redeem the one-time code with this sign-in's verifier (the code is consumed on every path).
    static func redeemNous(base: URL, code: String, verifier: String, provider: String = NousGatewayProtocol.nous,
                           transport: HTTPTransport) async throws -> NousTokens {
        let body = try JSONSerialization.data(withJSONObject: ["code": code, "code_verifier": verifier])
        let (status, data) = try await control(base, "/auth/native/token", method: "POST", body: body, transport: transport)
        switch NousGatewayProtocol.answer(status: status, body: data, provider: provider) {
        case .tokens(let tokens):
            if let lifetime = tokens.lifetime { AppLog.note("auth", "nous access token lifetime \(Int(lifetime)) s (sign-in)") }
            return tokens
        case .refused(let reason): throw reason == "not_authorized" ? GatewayFailure.notOwner : GatewayFailure.nousFailed
        case .unavailable(let code): throw code == 429 ? GatewayFailure.rateLimited : GatewayFailure.gatewayError("token HTTP \(code)")
        }
    }

    // MARK: Plumbing

    /// One control-pool request with `Accept: application/json` (no auto-refresh, no retry).
    static func control(_ base: URL, _ path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval = signInTimeout,
                        transport: HTTPTransport) async throws -> (Int, Data) {
        guard GatewayAddress.reachable(base) else { throw GatewayFailure.tailscaleOff }
        var request = URLRequest(url: try GatewayAddress.endpoint(base: base, path: path), timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await transport.data(for: request, pool: .control, ceiling: 1 << 20)
            return (response.statusCode, data)
        } catch {
            throw GatewayFailure.from(error)
        }
    }

    private static func requireSuccess(_ status: Int, _ body: Data, refusal: GatewayFailure) throws {
        guard !(200..<300).contains(status) else { return }
        let text = String(decoding: body.prefix(512), as: UTF8.self)
        switch status {
        case 401, 403: throw refusal
        case 429: throw GatewayFailure.rateLimited
        case 400 where text.contains("Invalid Host header"): throw GatewayFailure.hostRejected
        default: throw GatewayFailure.from(status: status, body: text)
        }
    }

    private static func object(_ data: Data) throws -> JSONValue {
        guard let value = try? JSONValue.parseFast(data) else { throw GatewayFailure.notHermes }
        guard case .object = value else { throw GatewayFailure.gatewayError("invalid gateway response") }
        return value
    }
}
