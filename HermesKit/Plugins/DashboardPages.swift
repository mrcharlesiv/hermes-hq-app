// [plugin-pages] Page plugins: Hermes plugins that add a page to the Hermes dashboard (a `dashboard/manifest.json`
// with a `tab`). Hermes HQ opens such a page in its own host (App/Capabilities/PluginPages), so a plugin like Memory
// Wiki has a place to be opened and used. Owner 2026-11-05: "Shouldn't there be a place that I can go open it and
// look at it?" … "Can we add a place for these things to be opened?"
//
// The upstream contract (hermes-agent):
// - `GET /api/dashboard/plugins[?profile=]` (public) lists the profile's dashboard plugins: name, label, description,
//   icon (a lucide name), tab {path, position, hidden?, override?}, entry, css, has_api, source. Hidden tabs (an
//   add-on's backend only) and overrides of a built-in page are not pages to open.
// - `GET /api/dashboard/plugins/rescan[?profile=]` (signed in) re-reads the plugin folders: the server keeps its list
//   from start-up, so a plugin installed since is missing until a rescan.
// - `GET /dashboard-plugins/[@<profile>/]<name>/<file>` serves the bundle and its stylesheet (web_routers/
//   dashboard_ui.py; the client builds the URL in web/src/plugins/usePlugins.ts).
// - The plugin's own API is mounted at `/api/plugins/<name>/` (web_server_dashboard.py); a `?profile=` names the bot.
//   A server too old to mount it after start answers its routes with FastAPI's bare `{"detail":"Not Found"}`.

import Foundation

nonisolated struct PluginDashboardPage: Sendable, Hashable, Identifiable {
    var name: String
    var label: String
    var description: String
    /// A lucide icon name ("Database"); `symbol` is the SF Symbol drawn for it.
    var icon: String
    var tabPath: String
    var entry: String
    var css: String?
    var hasAPI: Bool
    var source: String
    var version: String
    var id: String { name }

    var symbol: String { PluginDashboardPage.symbol(forLucide: icon) }

    /// The bundle's and stylesheet's URL path (`/dashboard-plugins/@<profile>/<name>/<file>`; the default bot's
    /// without the profile, as the dashboard does when it serves its own profile).
    static func assetPath(name: String, file: String, profile: String) -> String {
        let scope = profile.isEmpty || profile == "default" ? "" : "@\(Self.segment(profile))/"
        let clean = file.split(separator: "/").filter { $0 != "." && $0 != ".." && !$0.isEmpty }.map { Self.segment(String($0)) }
        return "/dashboard-plugins/\(scope)\(Self.segment(name))/\(clean.joined(separator: "/"))"
    }

    private static func segment(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? text
    }

    /// Plugins whose page Hermes HQ draws itself (Kanban has its own tab, which also does live updates and uploads):
    /// listing their web page too would give two of the same page, one half-working.
    static let shownNatively: Set<String> = ["kanban"]

    /// The list `GET /api/dashboard/plugins` answers, pages only: hidden tabs and built-in overrides are left out.
    static func read(_ data: Data) -> [PluginDashboardPage] {
        guard let rows = (try? JSONValue.parse(data))?.array else { return [] }
        return rows.compactMap(read)
    }

    static func read(_ row: JSONValue) -> PluginDashboardPage? {
        guard let name = RosterText.trimmed(row["name"]), let entry = RosterText.trimmed(row["entry"]) else { return nil }
        if shownNatively.contains(name) { return nil }
        let tab = row["tab"]
        if tab?["hidden"]?.bool == true { return nil }
        if let override = tab?["override"], !override.isNull, override.bool != false { return nil }
        guard let path = RosterText.trimmed(tab?["path"]) else { return nil }
        return PluginDashboardPage(name: name, label: RosterText.trimmed(row["label"]) ?? DisplayName.title(name),
                             description: RosterText.text(row["description"]), icon: RosterText.trimmed(row["icon"]) ?? "",
                             tabPath: path.hasPrefix("/") ? path : "/" + path, entry: entry,
                             css: RosterText.trimmed(row["css"]), hasAPI: row["has_api"]?.bool ?? false,
                             source: RosterText.trimmed(row["source"]) ?? "", version: RosterText.text(row["version"]))
    }

    /// The SF Symbol for a dashboard tab's lucide icon (the common ones; a grid for the rest).
    static func symbol(forLucide icon: String) -> String {
        let key = icon.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        let table: [String: String] = [
            "database": "cylinder.split.1x2", "brain": "brain", "book": "book", "bookopen": "book", "library": "books.vertical",
            "filetext": "doc.text", "file": "doc", "folder": "folder", "notebook": "book.closed", "notebookpen": "book.closed",
            "barchart": "chart.bar", "barchart3": "chart.bar", "chartbar": "chart.bar", "chartcolumn": "chart.bar",
            "linechart": "chart.xyaxis.line", "chartline": "chart.xyaxis.line", "piechart": "chart.pie", "activity": "waveform.path.ecg",
            "gauge": "gauge.with.dots.needle.33percent", "trophy": "trophy", "award": "rosette", "star": "star",
            "globe": "globe", "network": "point.3.connected.trianglepath.dotted", "share2": "point.3.connected.trianglepath.dotted",
            "calendar": "calendar", "clock": "clock", "history": "clock.arrow.circlepath", "timer": "timer",
            "kanban": "rectangle.split.3x1", "layoutdashboard": "square.grid.2x2", "layoutgrid": "square.grid.2x2",
            "listtodo": "checklist", "list": "list.bullet", "checksquare": "checkmark.square",
            "search": "magnifyingglass", "settings": "gearshape", "wrench": "wrench.and.screwdriver", "terminal": "terminal",
            "code": "chevron.left.forwardslash.chevron.right", "bot": "cpu", "cpu": "cpu", "sparkles": "sparkles",
            "messagesquare": "bubble.left", "messagecircle": "bubble.left", "mail": "envelope", "users": "person.2",
            "user": "person", "image": "photo", "camera": "camera", "music": "music.note", "mic": "mic",
            "shield": "shield", "lock": "lock", "key": "key", "smartphone": "iphone", "monitor": "display",
            "map": "map", "compass": "safari", "zap": "bolt", "flame": "flame", "heart": "heart", "dollarsign": "dollarsign.circle",
            "wallet": "wallet.bifold", "package": "shippingbox", "puzzle": "puzzlepiece.extension", "layers": "square.3.layers.3d",
        ]
        return table[key] ?? "square.grid.2x2"
    }
}

/// What a page may ask the app for, and how the app reads the answers (pure, so the tests can hold it).
nonisolated enum PluginPageBridge {
    /// The request path the app sends for a page's fetchJSON/authedFetch, or nil when the page may not ask for it:
    /// only the plugin's own `/api/plugins/<name>/` routes, with the bot's `?profile=` added (as the dashboard's
    /// fetchJSON does) unless the page named one itself.
    static func allowedPath(_ raw: String, plugin: String, profile: String) -> String? {
        guard raw.hasPrefix("/"), !raw.hasPrefix("//"), raw.count < 8192,
              !raw.unicodeScalars.contains(where: { $0 == "\\" || $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        guard let parts = URLComponents(string: "https://page.invalid" + raw) else { return nil }
        let path = parts.percentEncodedPath
        let decoded = parts.path
        if decoded.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) { return nil }
        let own = "/api/plugins/\(plugin)"
        guard decoded == own || decoded.hasPrefix(own + "/") else { return nil }
        var query = parts.percentEncodedQuery ?? ""
        let named = (parts.queryItems ?? []).contains { $0.name == "profile" }
        if !named, !profile.isEmpty, profile != "default" {
            let item = "profile=" + (profile.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_."))) ?? profile)
            query = query.isEmpty ? item : query + "&" + item
        }
        return query.isEmpty ? path : path + "?" + query
    }

    static let methods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]

    /// A 404 that means the server has no route for the plugin at all (FastAPI's bare "Not Found"), not a route of the
    /// plugin answering that something isn't there ("Subject not found").
    static func routeMissing(status: Int, body: String?) -> Bool {
        guard status == 404 else { return false }
        guard let body, let data = body.data(using: .utf8), let value = try? JSONValue.parse(data) else { return body?.isEmpty ?? true }
        return RosterText.trimmed(value["detail"]) == "Not Found"
    }
}

/// The calls the app makes for page plugins.
nonisolated enum DashboardPagesAPI {
    static func profileQuery(_ profile: String) -> [URLQueryItem] {
        profile.isEmpty || profile == "default" ? [] : [URLQueryItem(name: "profile", value: profile)]
    }

    static func list(_ client: any GatewayClient, profile: String) async throws -> [PluginDashboardPage] {
        PluginDashboardPage.read(try await client.rest("GET", "/api/dashboard/plugins", query: profileQuery(profile), body: nil))
    }

    /// Re-reads the plugin folders (a plugin installed since the server started is missing until then). Older servers
    /// have no rescan; that's not an error worth showing.
    static func rescan(_ client: any GatewayClient, profile: String) async {
        _ = try? await client.rest("GET", "/api/dashboard/plugins/rescan", query: profileQuery(profile), body: nil)
    }

    /// A list read after a rescan when an enabled plugin of the bot's isn't on it (installed after the server read its
    /// list at start-up). `installed`: the bot's enabled plugin names.
    static func pages(_ client: any GatewayClient, profile: String, installed: Set<String>, rescanned: inout Set<String>) async throws -> [PluginDashboardPage] {
        let first = try await list(client, profile: profile)
        let listed = Set(first.map(\.name))
        let unseen = installed.subtracting(listed).subtracting(rescanned)
        guard !unseen.isEmpty else { return first }
        rescanned.formUnion(unseen)
        await rescan(client, profile: profile)
        return (try? await list(client, profile: profile)) ?? first
    }
}
