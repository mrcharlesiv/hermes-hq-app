// Connect Apps' Composio side (docs/spec/3x-capabilities.md §10.2, §10.3; rows L725, L997): the Keychain item holding
// the owner's own Composio key, and the only requests the app can make to Composio. The key is read from the Keychain
// per request, sent as `x-api-key` to Composio's base only, never follows a redirect, and is never logged, stored in a
// property or put in an error.

import Foundation
import Security

nonisolated struct ComposioError: Error, Equatable, Sendable {
    enum Kind: Sendable { case badKey, notFound, rateLimited, server, rejected, noKey, network }
    var kind: Kind
    var message: String

    static let noKey = ComposioError(kind: .noKey, message: "Add your Composio API key first.")
    static let problem = ComposioError(kind: .server, message: "Composio had a problem. Try again.")
}

nonisolated struct ComposioKeychain: Sendable {
    var service = "\(AppIdentity.current.bundleId).composio"
    var account = "api-key"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    /// 8 to 256 characters of `[A-Za-z0-9_.-]`.
    static func plausible(_ key: String) -> Bool { JSRegex(#"^[A-Za-z0-9_.\-]{8,256}$"#).test(key) }

    /// `hint` = the last 4 characters.
    func status() -> (saved: Bool, hint: String) {
        guard let key = read() else { return (false, "") }
        return (true, String(key.suffix(4)))
    }

    func save(_ key: String) throws {
        guard Self.plausible(key), let data = key.data(using: .utf8) else { throw ComposioError(kind: .badKey, message: "That doesn’t look like a Composio key.") }
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw ComposioError(kind: .rejected, message: "This \(DeviceWord.name) couldn’t save the key.") }
    }

    func clear() { SecItemDelete(query as CFDictionary) }

    /// Only `ComposioClient` and the gateway step that gives a bot the key call this.
    func read() -> String? {
        var find = query
        find[kSecReturnData as String] = true
        find[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(find as CFDictionary, &out) == errSecSuccess, let data = out as? Data, let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }
}

// MARK: - Types

nonisolated struct ComposioSession: Sendable, Equatable {
    var id: String
    var mcpURL: String
    var userID: String
    /// `config.multi_account.enable` when Composio says; nil when the answer doesn't carry it.
    var multiAccount: Bool? = nil

    /// The web's pattern `/tool_router/(v<n>/)?<id>/mcp`.
    static func id(fromMcpURL url: String) -> String? {
        JSRegex(#"/tool_router/(?:v\d+/)?([^/?#]+)/mcp"#).exec(url)?.groups[1]
    }

    static func read(_ value: JSONValue) -> ComposioSession? {
        guard let id = RosterText.trimmed(value["session_id"]) ?? RosterText.trimmed(value["id"]) else { return nil }
        return ComposioSession(id: id, mcpURL: RosterText.text(value["mcp"]?["url"]),
                               userID: RosterText.trimmed(value["config"]?["user_id"]) ?? RosterText.text(value["user_id"]),
                               multiAccount: value["config"]?["multi_account"]?["enable"]?.bool ?? value["multi_account"]?["enable"]?.bool)
    }

    /// Sessions are made multi-account (docs.composio.dev "Managing multiple connected accounts"): one session uses one
    /// account per app unless this is on, and the newest account would quietly become the one the bots use. A call that
    /// names no account gets the default one (`require_explicit_selection` off), so bots written for one account keep
    /// working; Hermes tells them to name it when an app has several. Matches what Hermes's own migration sets.
    static let multiAccountConfig: JSONValue = ["enable": true, "max_accounts_per_toolkit": 5, "require_explicit_selection": false]

    /// Whether this session can hold a second account of an app: what Composio said, else whether this app made it
    /// multi-account (`known`, sessions created here whose answer didn't say). Unknown and not ours = no.
    static func isMultiAccount(_ session: ComposioSession, known: Set<String>) -> Bool {
        session.multiAccount ?? known.contains(session.id)
    }
}

nonisolated struct ComposioAccount: Sendable, Equatable, Hashable {
    var id: String
    var status: String
    var reason: String
    var createdAt: String
    /// The owner's own name for the account ("work"), set when it was linked or later.
    var alias: String = ""
    /// Composio's short code for the account (`word_id`, "googledrive_ab12"); read, not shown.
    var wordID: String = ""

    var isActive: Bool { status == "ACTIVE" }
    /// ACTIVE, EXPIRED or INACTIVE: the app was connected at some point.
    var wasConnected: Bool { ["ACTIVE", "EXPIRED", "INACTIVE"].contains(status) }
    var needsSignIn: Bool { status == "EXPIRED" || status == "INACTIVE" }

    static func read(_ value: JSONValue?) -> ComposioAccount? {
        guard let value, let id = RosterText.trimmed(value["id"]) ?? RosterText.trimmed(value["nanoid"]) else { return nil }
        return ComposioAccount(id: id, status: (RosterText.trimmed(value["status"]) ?? "").uppercased(),
                               reason: RosterText.trimmed(value["status_reason"]) ?? RosterText.text(value["statusReason"]),
                               createdAt: RosterText.trimmed(value["created_at"]) ?? RosterText.text(value["createdAt"]),
                               alias: RosterText.trimmed(value["alias"]) ?? "", wordID: RosterText.trimmed(value["word_id"]) ?? "")
    }

    /// The account's name on the app page: its alias ("work-drive" → "Work Drive"), else "Account <n>" (n counts from
    /// 1 in connect order). Composio's own `word_id` ("googledrive_ab12") reads as a code, so it isn't shown.
    func title(number: Int) -> String { alias.isEmpty ? "Account \(number)" : ComposioAlias.shown(alias) }
}

/// An account's short name. Composio's rule: lowercase letters, digits and "-", unique per app for the user.
nonisolated enum ComposioAlias {
    static let maxLength = 32

    /// What the owner typed, as Composio takes it: "Work" → "work", "Work Drive" → "work-drive". nil when nothing
    /// usable is left.
    static func normalized(_ typed: String) -> String? {
        var out = "", dash = false
        for ch in typed.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber { out.append(ch); dash = false }
            else if (ch == "-" || ch == "_" || ch.isWhitespace), !out.isEmpty, !dash { out.append("-"); dash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        out = String(out.prefix(maxLength))
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? nil : out
    }

    /// "work-drive" → "Work Drive".
    static func shown(_ alias: String) -> String {
        alias.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

nonisolated struct ComposioToolkit: Sendable, Equatable, Hashable, Identifiable {
    var slug: String
    var name: String
    var logo: String
    var description: String
    var noAuth: Bool
    var account: ComposioAccount?
    /// `composio_managed_auth_schemes` when the row carries it (session rows do): a sign-in Composio provides.
    var managedSchemes: [String] = []
    var id: String { slug }

    var connected: Bool { account?.wasConnected ?? false }
    var needsSignIn: Bool { account?.needsSignIn ?? false }

    static func read(_ row: JSONValue) -> ComposioToolkit? {
        guard let slug = RosterText.trimmed(row["slug"]) else { return nil }
        let meta = row["meta"]
        return ComposioToolkit(slug: slug, name: RosterText.trimmed(row["name"]) ?? slug, logo: RosterText.text(meta?["logo"]),
                               description: RosterText.text(meta?["description"]),
                               noAuth: row["is_no_auth"]?.bool ?? meta?["isNoAuth"]?.bool ?? false,
                               account: ComposioAccount.read(row["connected_account"]),
                               managedSchemes: (row["composio_managed_auth_schemes"]?.array ?? []).compactMap(\.string))
    }
}

nonisolated struct ToolkitPage: Sendable, Equatable {
    var items: [ComposioToolkit]
    var next: String
}

nonisolated struct ConnectLink: Sendable, Equatable {
    var redirectURL: String
    var accountID: String
}

nonisolated struct ComposioTool: Sendable, Equatable, Hashable, Identifiable {
    var slug: String
    var name: String
    var description: String
    var id: String { slug }
}

// MARK: - Client

/// Refuses every redirect, so the key header can never follow one to another host.
nonisolated private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor ComposioClient {
    static let productionBase = URL(string: "https://backend.composio.dev")!

    /// `https://backend.composio.dev`; a DEBUG build honours `HQN_COMPOSIO_BASE` when it is a loopback http URL (the
    /// stand-in). Release builds do not contain the read.
    nonisolated static var base: URL {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["HQN_COMPOSIO_BASE"], let url = loopback(raw) { return url }
        #endif
        return productionBase
    }

    nonisolated static func loopback(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "http", let host = url.host, ["127.0.0.1", "localhost", "::1"].contains(host),
              url.user == nil else { return nil }
        return url
    }

    private let keys: ComposioKeychain
    private let session: URLSession
    private let base: URL

    static func makeSession(protocols: [AnyClass]? = nil) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 20
        if let protocols { config.protocolClasses = protocols }
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    init(keys: ComposioKeychain = ComposioKeychain(), session: URLSession? = nil, base: URL = ComposioClient.base) {
        self.keys = keys
        self.session = session ?? Self.makeSession()
        self.base = base
    }

    // The route table: the only requests this client can make.
    private enum Route {
        case createSession(userID: String)
        case readSession(String)
        case toolkits(session: String, query: [URLQueryItem])
        case link(session: String, toolkit: String, callback: String?)
        /// A named link (v3.1: the route that takes `alias`), used for a second account of an app.
        case namedLink(session: String, toolkit: String, alias: String, callback: String?)
        case accounts(user: String, toolkit: String)
        case rename(account: String, alias: String)
        case account(String)
        case disconnect(String)
        case tools(toolkit: String, important: Bool)
        /// One app's read-only who-am-I tool (§10.12, `ComposioWhoAmI.table` only), run against one account.
        case whoAmI(tool: String, account: String, user: String, arguments: JSONValue)
        /// Composio's whole app catalog, a page at a time (§10.13: which apps have a sign-in Composio provides).
        case catalog(cursor: String)
        /// The owner's own auth configs (§10.13): apps they set up a sign-in for themselves.
        case authConfigs

        var method: String {
            switch self {
            case .createSession, .link, .namedLink, .whoAmI: "POST"
            case .rename: "PATCH"
            case .disconnect: "DELETE"
            default: "GET"
            }
        }

        static func segment(_ value: String) -> String {
            // "." and ".." would be walked as folders; nothing real is named that.
            guard value != ".", value != ".." else { return "_" }
            return value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~"))) ?? ""
        }

        var path: String {
            switch self {
            case .createSession: "/api/v3.1/tool_router/session"
            case .readSession(let id): "/api/v3.1/tool_router/session/\(Self.segment(id))"
            case .toolkits(let session, _): "/api/v3.1/tool_router/session/\(Self.segment(session))/toolkits"
            case .link(let session, _, _): "/api/v3/tool_router/session/\(Self.segment(session))/link"
            case .namedLink(let session, _, _, _): "/api/v3.1/tool_router/session/\(Self.segment(session))/link"
            case .accounts: "/api/v3.1/connected_accounts"
            case .rename(let id, _): "/api/v3.1/connected_accounts/\(Self.segment(id))"
            case .account(let id), .disconnect(let id): "/api/v3/connected_accounts/\(Self.segment(id))"
            case .tools: "/api/v3/tools"
            case .whoAmI(let tool, _, _, _): "/api/v3/tools/execute/\(Self.segment(tool))"
            case .catalog: "/api/v3/toolkits"
            case .authConfigs: "/api/v3/auth_configs"
            }
        }

        var query: [URLQueryItem] {
            switch self {
            case .toolkits(_, let query): query
            case .accounts(let user, let toolkit):
                [URLQueryItem(name: "user_ids", value: user), URLQueryItem(name: "toolkit_slugs", value: toolkit),
                 URLQueryItem(name: "order_by", value: "created_at"), URLQueryItem(name: "order_direction", value: "asc"),
                 URLQueryItem(name: "limit", value: "50")]
            case .catalog(let cursor):
                [URLQueryItem(name: "limit", value: "1000")] + (cursor.isEmpty ? [] : [URLQueryItem(name: "cursor", value: cursor)])
            case .authConfigs: [URLQueryItem(name: "limit", value: "200")]
            case .tools(let toolkit, let important):
                [URLQueryItem(name: "toolkit_slug", value: toolkit), URLQueryItem(name: "limit", value: "50")]
                    + (important ? [URLQueryItem(name: "important", value: "true")] : [])
            default: []
            }
        }

        var body: JSONValue? {
            switch self {
            case .createSession(let userID):
                ["user_id": .string(userID), "manage_connections": ["enable": true], "multi_account": ComposioSession.multiAccountConfig]
            case .link(_, let toolkit, let callback):
                .object(["toolkit": .string(toolkit)].merging(callback.map { ["callback_url": .string($0)] } ?? [:]) { a, _ in a })
            case .namedLink(_, let toolkit, let alias, let callback):
                .object(["toolkit": .string(toolkit), "alias": .string(alias)].merging(callback.map { ["callback_url": .string($0)] } ?? [:]) { a, _ in a })
            case .rename(_, let alias): ["alias": .string(alias)]
            case .whoAmI(_, let account, let user, let arguments):
                ["connected_account_id": .string(account), "user_id": .string(user), "arguments": arguments]
            default: nil
            }
        }
    }

    private func send(_ route: Route, key override: String? = nil) async throws(ComposioError) -> JSONValue {
        guard let key = override ?? keys.read() else { throw ComposioError.noKey }
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw ComposioError.problem }
        parts.percentEncodedPath = route.path
        if !route.query.isEmpty { parts.queryItems = route.query }
        guard let url = parts.url, url.host == base.host, url.scheme == base.scheme else { throw ComposioError.problem }
        var request = URLRequest(url: url)
        request.httpMethod = route.method
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = route.body {
            request.httpBody = try? body.encoded()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            let code = (error as? URLError)?.code
            if code == .notConnectedToInternet || code == .dataNotAllowed { throw ComposioError(kind: .network, message: "This \(DeviceWord.name) is offline") }   // Mac polish #143
            if code == .timedOut { throw ComposioError(kind: .network, message: "Composio took too long to answer") }
            throw ComposioError(kind: .network, message: "Couldn’t reach Composio")
        }
        guard let http = response as? HTTPURLResponse, data.count <= 2 * 1024 * 1024 else { throw ComposioError.problem }
        let value = (try? JSONValue.parse(data)) ?? .null
        if (200..<300).contains(http.statusCode) { return value }
        throw Self.error(status: http.statusCode, body: value, key: key)
    }

    /// Composio's own `error.message`, capped at 300 characters with anything shaped like the key masked.
    nonisolated static func message(_ body: JSONValue, key: String) -> String? {
        guard let raw = RosterText.trimmed(body["error"]?["message"]) ?? RosterText.trimmed(body["message"]) else { return nil }
        let masked = McpEntryMask.phone.text(key.isEmpty ? raw : raw.replacingOccurrences(of: key, with: McpEntryMask.MASK))
        return String(masked.prefix(300))
    }

    nonisolated static func error(status: Int, body: JSONValue, key: String = "") -> ComposioError {
        let own = message(body, key: key)
        switch status {
        case 401: return ComposioError(kind: .badKey, message: "Composio didn’t accept this API key.")
        case 403: return ComposioError(kind: .badKey, message: own ?? "This API key can’t use that Composio project.")
        case 404: return ComposioError(kind: .notFound, message: own ?? "Composio couldn’t find that.")
        case 429: return ComposioError(kind: .rateLimited, message: "Composio is rate-limiting requests. Try again in a minute.")
        case 408, 500...: return .problem
        case 300..<400: return .problem   // a refused redirect
        default: return ComposioError(kind: .rejected, message: own ?? "Composio refused the request (\(status)).")
        }
    }

    private func session(from value: JSONValue) throws(ComposioError) -> ComposioSession {
        guard let session = ComposioSession.read(value) else { throw ComposioError.problem }
        return session
    }

    func createSession(userID: String) async throws(ComposioError) -> ComposioSession { try session(from: try await send(.createSession(userID: userID))) }
    func readSession(_ id: String) async throws(ComposioError) -> ComposioSession { try session(from: try await send(.readSession(id))) }

    /// Setup: checks a key that is not saved yet by creating (or re-reading) the session with it.
    func check(key: String, userID: String, session id: String?) async throws(ComposioError) -> ComposioSession {
        if let id, !id.isEmpty {
            do { return try session(from: try await send(.readSession(id), key: key)) }
            catch let error where error.kind == .notFound {}
        }
        return try session(from: try await send(.createSession(userID: userID), key: key))
    }

    func toolkits(session: String, search: String = "", slugs: [String] = [], cursor: String = "", limit: Int = 30,
                  connectedOnly: Bool = false) async throws(ComposioError) -> ToolkitPage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if !search.isEmpty { query.append(URLQueryItem(name: "search", value: search)) }
        if !slugs.isEmpty { query.append(URLQueryItem(name: "toolkits", value: slugs.joined(separator: ","))) }
        if !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        if connectedOnly { query.append(URLQueryItem(name: "is_connected", value: "true")) }
        let value = try await send(.toolkits(session: session, query: query))
        return ToolkitPage(items: (value["items"]?.array ?? []).compactMap(ComposioToolkit.read),
                           next: RosterText.trimmed(value["next_cursor"]) ?? value["next_cursor"]?.int.map(String.init) ?? "")
    }

    /// With an `alias`, the link is for another account of the app under that name (v3.1 route).
    func link(session: String, toolkit: String, alias: String? = nil, callback: String?) async throws(ComposioError) -> ConnectLink {
        let value = try await send(alias.map { .namedLink(session: session, toolkit: toolkit, alias: $0, callback: callback) }
                                   ?? .link(session: session, toolkit: toolkit, callback: callback))
        guard let url = RosterText.trimmed(value["redirect_url"]) else { throw ComposioError.problem }
        return ConnectLink(redirectURL: url, accountID: RosterText.text(value["connected_account_id"]))
    }

    func account(_ id: String) async throws(ComposioError) -> ComposioAccount {
        guard let account = ComposioAccount.read(try await send(.account(id))) else { throw ComposioError.problem }
        return account
    }

    func disconnect(_ id: String) async throws(ComposioError) { _ = try await send(.disconnect(id)) }

    /// Every account of one app for this user, oldest first, that was connected at some point (ACTIVE, EXPIRED or
    /// INACTIVE; a sign-in never finished is left out).
    func accounts(user: String, toolkit: String) async throws(ComposioError) -> [ComposioAccount] {
        let value = try await send(.accounts(user: user, toolkit: toolkit))
        let all = (value["items"]?.array ?? []).compactMap { ComposioAccount.read($0) }.filter(\.wasConnected)
        return all.enumerated().sorted { a, b in
            let (x, y) = (ComposioCatalog.date(a.element.createdAt), ComposioCatalog.date(b.element.createdAt))
            if let x, let y, x != y { return x < y }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Names (or renames) an account; "" clears the name.
    func rename(_ id: String, alias: String) async throws(ComposioError) { _ = try await send(.rename(account: id, alias: alias)) }

    /// Who an account is signed in as (§10.12): the app's who-am-I tool run against this one account. nil when the
    /// app has no such tool in the table or its answer names nobody; a refused or failed run throws.
    func identity(account: String, toolkit: String, user: String) async throws(ComposioError) -> ComposioIdentity? {
        guard let entry = ComposioWhoAmI.entry(toolkit), !account.isEmpty, !user.isEmpty else { return nil }
        let answer = try await send(.whoAmI(tool: entry.tool, account: account, user: user, arguments: entry.arguments))
        return ComposioWhoAmI.read(answer, entry: entry)
    }

    /// Apps whose only sign-ins are OAuth ones Composio doesn't provide (§10.13), from every page of the catalog
    /// (about 1,700 apps in two pages today; at most 5 pages read).
    func appsNeedingOwnSignIn() async throws(ComposioError) -> Set<String> {
        var out = Set<String>(), cursor = ""
        for _ in 0..<5 {
            let value = try await send(.catalog(cursor: cursor))
            for row in value["items"]?.array ?? [] where ComposioSignIn.needsOwnApp(row) {
                if let slug = RosterText.trimmed(row["slug"]) { out.insert(slug.lowercased()) }
            }
            cursor = RosterText.trimmed(value["next_cursor"]) ?? ""
            if cursor.isEmpty { break }
        }
        return out
    }

    /// The apps the owner made their own auth config for (any not disabled).
    func appsWithOwnAuthConfig() async throws(ComposioError) -> Set<String> {
        let value = try await send(.authConfigs)
        return Set((value["items"]?.array ?? []).compactMap { row -> String? in
            guard (RosterText.trimmed(row["status"]) ?? "").uppercased() != "DISABLED" else { return nil }
            return RosterText.trimmed(row["toolkit"]?["slug"])?.lowercased()
        })
    }

    /// `important=true` first and, when that answer is empty, once more without it.
    func tools(toolkit: String) async throws(ComposioError) -> [ComposioTool] {
        func read(_ value: JSONValue) -> [ComposioTool] {
            (value["items"]?.array ?? []).compactMap { row in
                RosterText.trimmed(row["slug"]).map { ComposioTool(slug: $0, name: RosterText.trimmed(row["name"]) ?? $0, description: RosterText.text(row["description"])) }
            }
        }
        let important = read(try await send(.tools(toolkit: toolkit, important: true)))
        return important.isEmpty ? read(try await send(.tools(toolkit: toolkit, important: false))) : important
    }

    /// A Connect Link must be https on composio.dev or a subdomain with no userinfo (DEBUG: or the loopback base).
    nonisolated static func connectLink(_ raw: String, base: URL = ComposioClient.base) -> URL? {
        guard let url = URL(string: raw), let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return nil }
        if url.scheme == "https", host == "composio.dev" || host.hasSuffix(".composio.dev") { return url }
        #if DEBUG
        if base != productionBase, url.scheme == base.scheme, host == base.host, url.port == base.port { return url }
        #endif
        return nil
    }
}

// MARK: - Catalog and words (ref:src/composio/catalog.ts, words.ts)

nonisolated enum ComposioCatalog {
    static let popular = ["gmail", "googlecalendar", "googledrive", "slack", "github", "notion", "outlook", "googlesheets",
                          "linear", "dropbox", "hubspot", "googledocs", "jira", "asana", "trello", "zoom"]
    static let popularShown = 8
    static let hero = ["gmail", "googlecalendar", "github", "slack", "notion"]

    struct Category: Identifiable, Sendable, Hashable {
        var id: String
        var title: String
        var symbol: String
        var color: UInt32
        var slugs: [String]
    }

    static let categories: [Category] = [
        Category(id: "email", title: "Email & Calendar", symbol: "envelope.fill", color: 0xD93025,
                 slugs: ["gmail", "googlecalendar", "outlook", "calendly", "cal", "mailchimp", "sendgrid"]),
        Category(id: "docs", title: "Docs & Files", symbol: "doc.fill", color: 0x1A5FD0,
                 slugs: ["googledrive", "googledocs", "googlesheets", "notion", "dropbox", "box", "one_drive", "airtable", "confluence"]),
        Category(id: "chat", title: "Chat & Meetings", symbol: "bubble.left.fill", color: 0x248A3D,
                 slugs: ["slack", "discord", "microsoft_teams", "zoom", "telegram", "whatsapp"]),
        Category(id: "dev", title: "Developer Tools", symbol: "chevron.left.forwardslash.chevron.right", color: 0x3A3A3C,
                 slugs: ["github", "gitlab", "linear", "jira", "sentry", "vercel", "supabase", "bitbucket"]),
        Category(id: "sales", title: "Sales & CRM", symbol: "briefcase.fill", color: 0xB45309,
                 slugs: ["hubspot", "salesforce", "pipedrive", "attio", "apollo", "zoho"]),
        Category(id: "tasks", title: "Tasks & Projects", symbol: "checklist", color: 0x6D28D9,
                 slugs: ["asana", "trello", "todoist", "clickup", "monday", "linear", "notion"]),
    ]

    private static let prompts: [String: [String]] = [
        "gmail": ["What’s new in my inbox today?", "Draft a reply to my latest email"],
        "outlook": ["What’s new in my inbox today?", "Draft a reply to my latest email"],
        "googlecalendar": ["What’s on my calendar tomorrow?", "Find a free hour this week"],
        "googledrive": ["Find my most recent documents", "What’s in my shared folders?"],
        "googledocs": ["Summarize my latest document", "Start a new doc with meeting notes"],
        "googlesheets": ["What’s in my most recent spreadsheet?", "Add a row to my latest sheet"],
        "slack": ["What did I miss in Slack today?", "Draft a message to my team"],
        "github": ["What pull requests need my review?", "Summarize my open issues"],
        "notion": ["Find my most recent Notion pages", "Add a to-do to my Notion"],
        "linear": ["What issues are assigned to me?", "Create an issue for a bug I found"],
        "jira": ["What issues are assigned to me?", "Summarize this sprint"],
        "hubspot": ["Show my newest contacts", "Which deals closed this month?"],
    ]

    static func tryIt(slug: String, name: String) -> [String] { prompts[slug] ?? ["What can you do with \(name)?"] }

    /// "Hermes", "Hermes and Inbox", "Hermes, Inbox and Ivy", "Hermes, Inbox and 3 more".
    static func nameList(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        case 3: return "\(names[0]), \(names[1]) and \(names[2])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }

    static func date(_ iso: String) -> Date? {
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return full.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    /// "Sep 29, 2026" in the user's locale, or "" when Composio sent no time.
    static func connectedDate(_ iso: String, short: Bool = false, locale: Locale = .current) -> String {
        guard let date = date(iso) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(short ? "MMMd" : "MMMdyyyy")
        return formatter.string(from: date)
    }
}
