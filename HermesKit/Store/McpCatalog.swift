// The Nous-approved MCP catalog Hermes ships (`optional-mcps/`, about 65 apps: Linear, Notion, Figma, Stripe…), read
// from `GET /api/mcp/catalog` and installed with `POST /api/mcp/catalog/install`, as the desktop's Connectors page does
// (`apps/desktop/src/api/mcp.ts` getMcpCatalog / installMcpCatalogEntry, `app/capabilities/mcp/install-catalog-entry.ts`).
// An install writes the bot's config.yaml (and its .env for declared keys) on the person's computer.

import Foundation

nonisolated struct McpCatalogEntry: Identifiable, Sendable, Hashable {
    struct EnvKey: Sendable, Hashable {
        var name: String
        var prompt: String
        var required: Bool
    }

    var name: String
    var description: String
    /// The hosted connector this entry is the same app as (`linear`, `stripe_mcp`…); nil for most.
    var connectorSlug: String?
    var source: String
    var transport: String
    /// "oauth", "none", "header"…: OAuth entries sign in in the browser after the install.
    var authType: String
    var requiredEnv: [EnvKey]
    var command: String?
    var args: [String]
    var url: String?
    /// A git repository cloned and built on the computer (the install runs in the background).
    var installURL: String?
    var postInstall: String
    var installed: Bool
    var enabled: Bool
    var id: String { name }

    var title: String { McpCatalog.title(connectorSlug: connectorSlug, name: name) }
    var needsSignIn: Bool { authType == "oauth" }
    var needsBuild: Bool { installURL != nil }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(q) || name.localizedCaseInsensitiveContains(q)
            || description.localizedCaseInsensitiveContains(q)
    }
}

nonisolated enum McpCatalog {
    static func entries(_ value: JSONValue) -> [McpCatalogEntry] {
        (value["entries"]?.array ?? []).compactMap { row in
            guard let name = RosterText.trimmed(row["name"]) else { return nil }
            let env: [McpCatalogEntry.EnvKey] = (row["required_env"]?.array ?? []).compactMap { key in
                guard let keyName = RosterText.trimmed(key["name"]) else { return nil }
                return .init(name: keyName, prompt: RosterText.trimmed(key["prompt"]) ?? keyName, required: key["required"]?.bool ?? true)
            }
            return McpCatalogEntry(
                name: name, description: RosterText.text(row["description"]), connectorSlug: RosterText.trimmed(row["connector_slug"]),
                source: RosterText.text(row["source"]), transport: RosterText.trimmed(row["transport"]) ?? "stdio",
                authType: RosterText.trimmed(row["auth_type"]) ?? "none", requiredEnv: env,
                command: RosterText.trimmed(row["command"]), args: (row["args"]?.array ?? []).map { RosterText.text($0) },
                url: RosterText.trimmed(row["url"]), installURL: RosterText.trimmed(row["install_url"]),
                postInstall: RosterText.text(row["post_install"]), installed: row["installed"]?.bool ?? false,
                enabled: row["enabled"]?.bool ?? false)
        }
    }

    /// The desktop's names (`lib/connector-tools.ts` connectorTitle) plus the catalog's odd ones.
    private static let titles: [String: String] = [
        "github": "GitHub", "gitlab": "GitLab", "stripe_mcp": "Stripe", "sentry_mcp": "Sentry", "vercel_mcp": "Vercel",
        "hugging_face": "Hugging Face", "n8n-official": "n8n", "aws-knowledge": "AWS Knowledge", "deepwiki": "DeepWiki",
        "clickup": "ClickUp", "circleci": "CircleCI", "motherduck": "MotherDuck", "paypal": "PayPal", "wordpress-com": "WordPress.com",
        "betterstack": "Better Stack", "twelve-data": "Twelve Data", "twilio-docs": "Twilio Docs", "context7": "Context7",
        "microsoft-learn": "Microsoft Learn", "prisma-postgres": "Prisma Postgres", "comfy-cloud": "Comfy Cloud",
        "unreal-engine": "Unreal Engine", "alltrails": "AllTrails", "googlecalendar": "Google Calendar", "googledrive": "Google Drive",
        "googledocs": "Google Docs", "googlesheets": "Google Sheets",
    ]

    static func title(connectorSlug: String?, name: String) -> String {
        if let slug = connectorSlug, let known = titles[slug] { return known }
        if let known = titles[name] { return known }
        return name.replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
            .split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            .replacingOccurrences(of: "\\bMcp\\b", with: "MCP", options: .regularExpression)
    }

    /// A key that holds an address rather than a secret (`N8N_MCP_SERVER_URL`, `…_HOST`): typed in the open.
    static func isAddress(_ key: McpCatalogEntry.EnvKey) -> Bool {
        let parts = key.name.uppercased().split(separator: "_")
        return parts.contains("URL") || parts.contains("HOST") || parts.contains("ENDPOINT")
    }

    /// The apps the Popular grid leads with (the desktop's lead order, then the catalog's best known), the rest A–Z.
    static let leadOrder = ["notion", "linear", "figma", "todoist", "asana", "airtable", "dropbox", "atlassian", "canva", "stripe",
                            "supabase", "github", "gitlab", "miro", "monday", "clickup", "calendly", "sentry", "vercel", "netlify"]

    static func ordered(_ entries: [McpCatalogEntry]) -> [McpCatalogEntry] {
        let rank = Dictionary(leadOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return entries.sorted { a, b in
            let ra = rank[a.name] ?? Int.max, rb = rank[b.name] ?? Int.max
            return ra != rb ? ra < rb : a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    /// Slugs logos.composio.dev may know this app by, best first (51 of the 65 entries resolve; checked 2026-10-15).
    static func logoSlugs(_ entry: McpCatalogEntry) -> [String] {
        var out: [String] = []
        func add(_ s: String?) { if let s, !s.isEmpty, !out.contains(s) { out.append(s) } }
        add(entry.connectorSlug)
        add(entry.name)
        add(entry.name.replacingOccurrences(of: "[_-]", with: "", options: .regularExpression))
        add(entry.name.replacingOccurrences(of: "-", with: "_"))
        if let slug = entry.connectorSlug, slug.hasSuffix("_mcp") { add(String(slug.dropLast(4))) }
        return out
    }

    /// The product's own site for a favicon when no vendor logo exists: the registrable part of the source's host
    /// (`docs.comfy.org` → comfy.org), never a code host or a private address (the desktop's `connectorLogoSource`).
    static func site(_ entry: McpCatalogEntry) -> URL? {
        for candidate in [entry.source, entry.url ?? ""] {
            guard let host = URL(string: candidate)?.host?.lowercased(), host.contains(".") else { continue }
            if host.hasSuffix("github.com") || host.hasSuffix("github.io") || host.hasSuffix("gitlab.com") || host.hasSuffix("npmjs.com")
                || host.hasSuffix("pypi.org") || host == "localhost" || host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") { continue }
            let labels = host.split(separator: ".")
            let domain = labels.suffix(2).joined(separator: ".")
            return URL(string: "https://\(domain)")
        }
        return nil
    }
}

extension CapabilitiesStore {
    /// nil when the gateway predates the catalog route (404, or the web page instead of JSON): the page then shows no
    /// catalog rather than an error.
    func mcpCatalog(_ profile: String) async throws -> [McpCatalogEntry]? {
        let data: Data
        do {
            data = try await client.rest("GET", "/api/mcp/catalog", query: query(profile), body: nil)
        } catch let error as HTTPError where error.status == 404 && (error.body ?? "").contains("Not Found") {
            return nil
        }
        return await Self.decodeCatalog(data)
    }

    /// [perf] Parsed and mapped off the main thread.
    @concurrent nonisolated static func decodeCatalog(_ data: Data) async -> [McpCatalogEntry]? {
        guard let value = try? JSONValue.parseFast(data), value["entries"] != nil else { return nil }
        return McpCatalog.entries(value)
    }

    /// Installs one entry with the keys it declares; an entry built from a git repository runs as a background action
    /// polled until it ends. Returns when the server is in the bot's config.
    func installCatalog(_ name: String, env: [String: String], profile: String) async throws {
        if readOnlyGateway { throw BotWriteError(title: "Couldn’t Install", reason: BotWriteError.readOnlyReason) }
        let body = JSONValue.object(["name": .string(name), "env": .object(env.mapValues { .string($0) }), "enable": .bool(true)])
        let started = try json(try await client.rest("POST", "/api/mcp/catalog/install", query: query(profile), body: try? body.encoded()))
        guard started["background"]?.bool == true, let action = RosterText.trimmed(started["action"]) else {
            _ = try? await client.call("reload.mcp", ["confirm": true], timeout: .seconds(30))
            return
        }
        let deadline = Date().addingTimeInterval(10 * 60)
        while Date() < deadline {
            try await Task.sleep(for: pollInterval)
            let raw = try await client.rest("GET", "/api/actions/\(action)/status",
                                            query: [URLQueryItem(name: "lines", value: "1"), URLQueryItem(name: "profile", value: profile)], body: nil)
            let status = Self.status(try JSONValue.parse(raw), name: action)
            if !status.running {
                if status.exitCode != 0 { throw HTTPError(status: 500, body: #"{"detail":"The install didn’t finish. See why on the computer running Hermes."}"#) }
                _ = try? await client.call("reload.mcp", ["confirm": true], timeout: .seconds(30))
                return
            }
        }
        throw HTTPError(status: 504, body: #"{"detail":"The install is taking more than 10 minutes. It may still finish on the computer running Hermes."}"#)
    }
}
