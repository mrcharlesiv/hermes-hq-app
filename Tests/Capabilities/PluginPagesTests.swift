// [plugin-pages] Page plugins: reading the dashboard's plugin list, the asset paths, what a page may ask the app for
// (the bridge), a route Hermes hasn't mounted, the rescan for a list older than an install, and the catalog's words.

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct PluginPagesTests {
    private let list = """
    [
      {"name": "memory-wiki", "label": "Memory Wiki", "description": "Subject pages and daily logs.", "icon": "BookOpen", "version": "0.4.0",
       "tab": {"path": "/memory-wiki", "position": "after:skills"}, "slots": [], "entry": "dist/index.js", "css": "dist/style.css",
       "has_api": true, "source": "user"},
      {"name": "helper", "label": "Helper", "icon": "Puzzle", "tab": {"path": "/helper", "hidden": true}, "entry": "dist/index.js", "has_api": true},
      {"name": "my-sessions", "label": "Sessions+", "tab": {"path": "/sessions", "override": "/sessions"}, "entry": "dist/index.js"},
      {"name": "plain", "tab": {"path": "plain", "override": null}, "entry": "index.js"},
      {"name": "kanban", "label": "Kanban", "tab": {"path": "/kanban"}, "entry": "dist/index.js", "has_api": true},
      {"name": "no-entry", "label": "No Entry", "tab": {"path": "/x"}},
      {"name": "no-tab", "label": "No Tab", "entry": "dist/index.js"}
    ]
    """

    @Test func readsPagesOnly() throws {
        let pages = PluginDashboardPage.read(Data(list.utf8))
        #expect(pages.map(\.name) == ["memory-wiki", "plain"], "hidden tabs, overrides of a built-in page, pages HQ draws itself (Kanban) and rows without an entry or tab are not pages")
        let wiki = try #require(pages.first)
        #expect(wiki.label == "Memory Wiki")
        #expect(wiki.tabPath == "/memory-wiki")
        #expect(wiki.css == "dist/style.css")
        #expect(wiki.hasAPI)
        #expect(wiki.symbol == "book")
        let plain = pages[1]
        #expect(plain.label == "Plain", "no label: the name, titled")
        #expect(plain.tabPath == "/plain", "a path without its slash gets one")
        #expect(plain.css == nil)
        #expect(plain.symbol == "square.grid.2x2", "no icon: a grid")
        #expect(PluginDashboardPage.read(Data("{\"detail\":\"x\"}".utf8)).isEmpty)
    }

    @Test func lucideIcons() {
        #expect(PluginDashboardPage.symbol(forLucide: "NotebookPen") == "book.closed")
        #expect(PluginDashboardPage.symbol(forLucide: "bar-chart-3") == "chart.bar")
        #expect(PluginDashboardPage.symbol(forLucide: "SomethingNew") == "square.grid.2x2")
    }

    @Test func assetPaths() {
        #expect(PluginDashboardPage.assetPath(name: "memory-wiki", file: "dist/index.js", profile: "default") == "/dashboard-plugins/memory-wiki/dist/index.js")
        #expect(PluginDashboardPage.assetPath(name: "memory-wiki", file: "dist/index.js", profile: "") == "/dashboard-plugins/memory-wiki/dist/index.js")
        #expect(PluginDashboardPage.assetPath(name: "memory-wiki", file: "./dist/../index.js", profile: "ivy") == "/dashboard-plugins/@ivy/memory-wiki/dist/index.js",
                "dot segments are dropped, the bot named")
    }

    @Test func bridgeAllowsOnlyThePluginsOwnRoutes() {
        let allow = { (raw: String, profile: String) in PluginPageBridge.allowedPath(raw, plugin: "memory-wiki", profile: profile) }
        #expect(allow("/api/plugins/memory-wiki/overview", "default") == "/api/plugins/memory-wiki/overview")
        #expect(allow("/api/plugins/memory-wiki", "default") == "/api/plugins/memory-wiki")
        #expect(allow("/api/plugins/memory-wiki/subjects?q=lisbon", "default") == "/api/plugins/memory-wiki/subjects?q=lisbon")
        #expect(allow("/api/plugins/memory-wiki/overview", "ivy") == "/api/plugins/memory-wiki/overview?profile=ivy", "the bot is added, as the dashboard does")
        #expect(allow("/api/plugins/memory-wiki/x?a=1", "ivy") == "/api/plugins/memory-wiki/x?a=1&profile=ivy")
        #expect(allow("/api/plugins/memory-wiki/x?profile=research", "ivy") == "/api/plugins/memory-wiki/x?profile=research", "a bot the page named stays")
        #expect(allow("/api/plugins/memory-wiki/subject/caf%C3%A9", "default") == "/api/plugins/memory-wiki/subject/caf%C3%A9", "encoding kept")

        #expect(allow("/api/plugins/memory-wikix/overview", "default") == nil, "another plugin whose name starts the same")
        #expect(allow("/api/plugins/kanban/board", "default") == nil, "another plugin")
        #expect(allow("/api/env", "default") == nil, "the gateway's own API")
        #expect(allow("/api/plugins/memory-wiki/../../env", "default") == nil)
        #expect(allow("/api/plugins/memory-wiki/%2e%2e/%2e%2e/env", "default") == nil, "encoded dot segments")
        #expect(allow("/api/plugins/memory-wiki/./x", "default") == nil)
        #expect(allow("//evil.example/api/plugins/memory-wiki", "default") == nil)
        #expect(allow("https://evil.example/api/plugins/memory-wiki/x", "default") == nil)
        #expect(allow("api/plugins/memory-wiki/x", "default") == nil)
        #expect(allow("/api/plugins/memory-wiki/x\n", "default") == nil)
        #expect(allow("/api/plugins/memory-wiki\\..\\env", "default") == nil)
        #expect(PluginPageBridge.methods.contains("POST"))
        #expect(!PluginPageBridge.methods.contains("CONNECT"))
    }

    @Test func aRouteHermesHasNotMounted() {
        #expect(PluginPageBridge.routeMissing(status: 404, body: "{\"detail\":\"Not Found\"}"))
        #expect(PluginPageBridge.routeMissing(status: 404, body: ""))
        #expect(PluginPageBridge.routeMissing(status: 404, body: nil))
        #expect(!PluginPageBridge.routeMissing(status: 404, body: "{\"detail\":\"Subject not found\"}"), "the plugin's own 404")
        #expect(!PluginPageBridge.routeMissing(status: 404, body: "<html>nope</html>"))
        #expect(!PluginPageBridge.routeMissing(status: 500, body: "{\"detail\":\"Not Found\"}"))
    }

    @Test func rescansOnceWhenAnInstalledPluginIsMissing() async throws {
        let wiki: JSONValue = ["name": "memory-wiki", "label": "Memory Wiki", "tab": ["path": "/memory-wiki"], "entry": "dist/index.js"]
        let scanned = PagesFakeFlag()
        let client = PagesFakeClient { req in
            if req.path == "/api/dashboard/plugins/rescan" { scanned.set(); return ["ok": true] }
            return scanned.value ? .array([wiki]) : .array([])
        }
        var rescanned: Set<String> = []
        let first = try await DashboardPagesAPI.pages(client, profile: "ivy", installed: ["memory-wiki", "kanban"], rescanned: &rescanned)
        #expect(first.map(\.name) == ["memory-wiki"])
        #expect(client.logLines == ["GET /api/dashboard/plugins?profile=ivy", "GET /api/dashboard/plugins/rescan?profile=ivy", "GET /api/dashboard/plugins?profile=ivy"])
        #expect(rescanned == ["memory-wiki", "kanban"], "both were missing: remembered, so a plugin with no page (kanban) isn't rescanned for again")

        _ = try await DashboardPagesAPI.pages(client, profile: "ivy", installed: ["memory-wiki", "kanban"], rescanned: &rescanned)
        #expect(client.logLines.count == 4, "the next read: no rescan")

        let plain = PagesFakeClient { _ in .array([wiki]) }
        var none: Set<String> = []
        _ = try await DashboardPagesAPI.pages(plain, profile: "default", installed: ["memory-wiki"], rescanned: &none)
        #expect(plain.logLines == ["GET /api/dashboard/plugins"], "every installed plugin listed: no rescan; the default bot names no profile")
    }

    @Test func catalogWordsSayWhenAPluginAddsAPage() {
        func entry(_ words: String) -> PluginCatalogEntry {
            PluginCatalogEntry(name: "x", description: words, repo: "https://github.com/acme/x", sha: "", subdir: "", tier: "community", category: .general,
                               maintainer: "acme", version: "", requiresHermes: "", platforms: [], providesTools: [], requiresEnv: [], docsURL: nil,
                               image: nil, stars: nil, addedAt: nil, updatedAt: nil)
        }
        #expect(entry("Memory Wiki dashboard tab and opt-in native Desktop page: browsable subject pages and daily logs.").addsDashboardPage)
        #expect(entry("A Dashboard and Desktop plugin for budgets.").addsDashboardPage)
        #expect(!entry("Mem0 memory provider with semantic search.").addsDashboardPage)
        #expect(!entry("A pane for the desktop.").addsDashboardPage)
    }

    // [plugin-pages-more] More › Plugin Pages: one row per page, whoever has it.
    @Test func moreListsEachPageOnceWithItsBots() {
        let pages = PluginDashboardPage.read(Data(list.utf8))
        let wiki = pages[0], plain = pages[1]
        let listed = PluginPagesMore.merge(["finance": [wiki], "default": [wiki, plain], "travel": [plain]],
                                           bots: ["default", "finance", "travel", "gone"])
        #expect(listed.map(\.page.name) == ["memory-wiki", "plain"], "by label: Memory Wiki, then Plain")
        #expect(listed[0].profiles == ["default", "finance"], "the bots in the scope order (default first)")
        #expect(listed[1].profiles == ["default", "travel"])
        #expect(PluginPagesMore.merge(["finance": [wiki]], bots: ["default"]).isEmpty, "a bot that isn't listed (hidden, removed) adds nothing")
        #expect(PluginPagesMore.merge([:], bots: ["default"]).isEmpty, "no pages: no section")
    }
}

/// A flag the fake client's responder can set from its own task.
nonisolated final class PagesFakeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    func set() { lock.withLock { on = true } }
    var value: Bool { lock.withLock { on } }
}
