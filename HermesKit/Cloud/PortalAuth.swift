// Hermes Cloud's sign-in: the phone's own login to Nous Portal, apart from any gateway's. Portal publishes OAuth for its
// agent-management API (`/.well-known/oauth-authorization-server`): a public client registers itself (RFC 7591, no
// secret), signs in with PKCE in the system browser, and gets a bearer + rotating refresh token with scope
// `mcp:manage_agents`. The redirect is the same loopback relay Sign in with Nous uses, so each sign-in registers a
// client for its own port (Portal matches redirect URIs exactly). The pair lives in its own Keychain item.

import Foundation
import Security

nonisolated enum Portal {
    static let base = URL(string: "https://portal.nousresearch.com")!
    static let scope = "mcp:manage_agents"
    /// The protected resource the token is for (RFC 8707 `resource`).
    static let resource = "https://portal.nousresearch.com/mcp"
    static let agentsPage = URL(string: "https://portal.nousresearch.com/agents")!
    /// Portal's New Agent page: its current sizes and prices.
    static let newAgentPage = URL(string: "https://portal.nousresearch.com/agents/new")!
    static let billingPage = URL(string: "https://portal.nousresearch.com/billing")!
}

nonisolated struct PortalError: Error, Equatable, Sendable {
    enum Kind: Sendable { case signedOut, network, server, refused, cancelled }
    var kind: Kind
    var message: String
    /// A network failure after the request went out (timed out, connection dropped): Portal may have acted on it.
    var mayHaveRun = false

    static let signedOut = PortalError(kind: .signedOut, message: "Sign in to Nous Portal again.")
    static let problem = PortalError(kind: .server, message: "Nous Portal had a problem. Try again.")
    static let cancelled = PortalError(kind: .cancelled, message: "")
}

/// The phone's Portal login: the client this sign-in registered, and its token pair.
nonisolated struct PortalCredentials: Codable, Sendable, Equatable {
    var clientId: String
    var accessToken: String
    var refreshToken: String?
    /// Seconds since 1970; 0 = Portal didn't say.
    var expiresAt: Double
    var obtainedAt: Double

    /// Renew a minute early; a pair with no expiry is used until Portal answers 401.
    func needsRenewal(now: Double = Date().timeIntervalSince1970) -> Bool {
        expiresAt > 0 && now >= expiresAt - 60
    }

    /// The token endpoint's answer. `previous` keeps the refresh token when a renewal doesn't send a new one.
    static func read(_ value: JSONValue, clientId: String, previous: PortalCredentials? = nil,
                     now: Double = Date().timeIntervalSince1970) -> PortalCredentials? {
        guard let access = RosterText.trimmed(value["access_token"]) else { return nil }
        let lifetime = value["expires_in"]?.double ?? 0
        return PortalCredentials(clientId: clientId, accessToken: access,
                                 refreshToken: RosterText.trimmed(value["refresh_token"]) ?? previous?.refreshToken,
                                 expiresAt: lifetime > 0 ? now + lifetime : 0, obtainedAt: now)
    }
}

/// One Keychain item for the Portal login. AfterFirstUnlock, so a renewal while the phone is locked is still saved
/// (a refresh token Portal rotated and the phone lost would sign it out).
nonisolated struct PortalKeychain: Sendable {
    var service = "\(AppIdentity.current.bundleId).portal"
    var account = "primary"
    /// Tests: stands in for a Keychain that refuses writes (before the phone's first unlock after a restart).
    var refusesSavesForTests: (@Sendable () -> Bool)? = nil

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func read() -> PortalCredentials? {
        var find = query
        find[kSecReturnData as String] = true
        find[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(find as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(PortalCredentials.self, from: data)
    }

    @discardableResult func save(_ credentials: PortalCredentials) -> Bool {
        if refusesSavesForTests?() == true { return false }
        guard let data = try? JSONEncoder().encode(credentials) else { return false }
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess { return true }
        var add = query
        add.merge(update) { $1 }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func clear() { SecItemDelete(query as CFDictionary) }
}

/// Portal's OAuth endpoints. No cookies, no redirects followed, nothing logged but status codes.
nonisolated struct PortalAuth: Sendable {
    let base: URL
    let session: URLSession

    init(base: URL = Portal.base, session: URLSession = PortalAuth.makeSession()) {
        self.base = base; self.session = session
    }

    /// `resourceTimeout`: the longest a whole exchange may take (agent create waits on provisioning).
    static func makeSession(protocols: [AnyClass]? = nil, resourceTimeout: TimeInterval = 60) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = resourceTimeout
        if let protocols { config.protocolClasses = protocols }
        return URLSession(configuration: config, delegate: PortalNoRedirects(), delegateQueue: nil)
    }

    /// RFC 7591: a public client for this one redirect.
    func register(redirect: String) async throws(PortalError) -> String {
        let body: JSONValue = ["client_name": "Hermes HQ", "redirect_uris": [.string(redirect)],
                               "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
                               "token_endpoint_auth_method": "none", "scope": .string(Portal.scope)]
        let value = try await post("/api/oauth/register", json: body)
        guard let id = RosterText.trimmed(value["client_id"]) else { throw PortalError.problem }
        return id
    }

    func authorizeURL(clientId: String, redirect: String, challenge: String, state: String) -> URL? {
        guard var parts = URLComponents(url: base.appendingPathComponent("oauth/authorize"), resolvingAgainstBaseURL: false) else { return nil }
        parts.queryItems = [URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "client_id", value: clientId),
                            URLQueryItem(name: "redirect_uri", value: redirect), URLQueryItem(name: "code_challenge", value: challenge),
                            URLQueryItem(name: "code_challenge_method", value: "S256"), URLQueryItem(name: "state", value: state),
                            URLQueryItem(name: "scope", value: Portal.scope), URLQueryItem(name: "resource", value: Portal.resource)]
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url
    }

    func redeem(code: String, verifier: String, redirect: String, clientId: String) async throws(PortalError) -> PortalCredentials {
        let value = try await post("/api/oauth/token", form: [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirect, "client_id": clientId,
            "code_verifier": verifier, "resource": Portal.resource])
        guard let credentials = PortalCredentials.read(value, clientId: clientId) else { throw PortalError.problem }
        return credentials
    }

    /// A spent or revoked refresh token answers 400/401: signed out.
    func renew(_ credentials: PortalCredentials) async throws(PortalError) -> PortalCredentials {
        guard let refresh = credentials.refreshToken else { throw PortalError.signedOut }
        let value: JSONValue
        do {
            value = try await post("/api/oauth/token", form: [
                "grant_type": "refresh_token", "refresh_token": refresh, "client_id": credentials.clientId,
                "resource": Portal.resource])
        } catch let error where error.kind == .refused {
            throw PortalError.signedOut
        }
        guard let renewed = PortalCredentials.read(value, clientId: credentials.clientId, previous: credentials) else { throw PortalError.problem }
        return renewed
    }

    // MARK: Plumbing

    private func post(_ path: String, json: JSONValue) async throws(PortalError) -> JSONValue {
        guard let data = try? json.encoded() else { throw PortalError.problem }
        return try await send(path, body: data, type: "application/json")
    }

    private func post(_ path: String, form: [String: String]) async throws(PortalError) -> JSONValue {
        var parts = URLComponents()
        parts.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let encoded = (parts.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        return try await send(path, body: Data(encoded.utf8), type: "application/x-www-form-urlencoded")
    }

    private func send(_ path: String, body: Data, type: String) async throws(PortalError) -> JSONValue {
        var request = URLRequest(url: base.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, status) = try await Self.fetch(request, session: session)
        let value = (try? JSONValue.parse(data)) ?? .null
        switch status {
        case 200..<300: return value
        case 400, 401, 403:
            AppLog.note("auth", "portal \(path) refused \(status) \(RosterText.text(value["error"]))")
            throw PortalError(kind: .refused, message: RosterText.trimmed(value["error_description"]) ?? "Nous Portal refused the sign-in.")
        default:
            AppLog.note("auth", "portal \(path) HTTP \(status)")
            throw PortalError.problem
        }
    }

    static func fetch(_ request: URLRequest, session: URLSession) async throws(PortalError) -> (Data, Int) {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw mapped(error) }
        guard let http = response as? HTTPURLResponse, data.count <= 4 * 1024 * 1024 else { throw PortalError.problem }
        return (data, http.statusCode)
    }

    /// A failed request in words. Never repeats the request: a create that timed out may have made an agent.
    static func mapped(_ error: any Error) -> PortalError {
        let code = (error as? URLError)?.code
        switch code {
        case .cancelled?: return .cancelled
        case .notConnectedToInternet?, .dataNotAllowed?:
            return PortalError(kind: .network, message: "This \(DeviceWord.name) is offline.")
        case .timedOut?:
            return PortalError(kind: .network, message: "Nous Portal took too long to answer.", mayHaveRun: true)
        case .networkConnectionLost?:
            return PortalError(kind: .network, message: "The connection to Nous Portal dropped.", mayHaveRun: true)
        default:
            return PortalError(kind: .network, message: "Couldn’t reach Nous Portal.")
        }
    }
}

nonisolated private final class PortalNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The phone's Portal login over time: one renewal at a time, every rotation saved before it's used.
actor PortalLogin {
    static let shared = PortalLogin()

    private let keychain: PortalKeychain
    private let auth: PortalAuth
    private var renewal: Task<PortalCredentials, Error>?
    /// A rotated pair the Keychain refused to take (before the phone's first unlock after a restart). Portal has
    /// already spent the refresh token the Keychain still holds, so this copy is the login: it is used, and written
    /// again on every later ask, until the Keychain takes it. Sending the spent one would end the Portal session.
    private var unsaved: PortalCredentials?

    init(keychain: PortalKeychain = PortalKeychain(), auth: PortalAuth = PortalAuth()) {
        self.keychain = keychain; self.auth = auth
    }

    var isSignedIn: Bool { unsaved != nil || keychain.read() != nil }

    func adopt(_ credentials: PortalCredentials) {
        renewal?.cancel(); renewal = nil
        unsaved = nil
        keychain.save(credentials)
    }

    func signOut() {
        renewal?.cancel(); renewal = nil
        unsaved = nil
        keychain.clear()
    }

    /// The login as it stands: a rotation the Keychain hasn't taken yet (tried again now), else the saved one.
    private func current() -> PortalCredentials? {
        guard let unsaved else { return keychain.read() }
        if keychain.save(unsaved) {
            self.unsaved = nil
            AppLog.note("auth", "portal: a renewed login is saved now")
        }
        return unsaved
    }

    /// A usable access token: the saved one, renewed first when it's about to lapse (or `force`d after a 401).
    /// `refused` is the token the 401 came back for: when the login has moved on since that request went out (another
    /// call renewed it meanwhile), the newer token is the answer and nothing is renewed again.
    func accessToken(force: Bool = false, refused: String? = nil) async throws -> String {
        guard let saved = current() else { throw PortalError.signedOut }
        if force, let refused, refused != saved.accessToken { return saved.accessToken }
        if !force && !saved.needsRenewal() { return saved.accessToken }
        if let renewal { return try await renewal.value.accessToken }
        let auth = self.auth, keychain = self.keychain
        let task = Task<PortalCredentials, Error> {
            do {
                let renewed = try await auth.renew(saved)
                // Signed out or replaced by a new sign-in meanwhile: this rotation is not the login any more.
                guard !Task.isCancelled else { return renewed }
                if !keychain.save(renewed) {
                    self.unsaved = renewed
                    AppLog.note("auth", "portal: a renewed login could not be saved yet; kept in memory")
                }
                return renewed
            } catch let error as PortalError where error.kind == .signedOut {
                if !Task.isCancelled { self.unsaved = nil; keychain.clear() }
                throw error
            }
        }
        renewal = task
        defer { renewal = nil }
        return try await task.value.accessToken
    }
}
