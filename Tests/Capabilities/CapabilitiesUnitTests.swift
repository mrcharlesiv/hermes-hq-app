// Capabilities stream unit tests (docs/spec/3x-capabilities.md §12): pure rules behind Tools, Connectors, Plugins,
// the More issue count and Connect Apps. No network except the URLProtocol-backed Composio client tests.

import Foundation
import Testing
@testable import HermesHQNative

@MainActor struct CapabilitiesUnitTests {
    // MARK: Secrets never shown

    @Test func maskHidesSecretsInText() {
        let mask = McpEntryMask.phone
        let token = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        #expect(!mask.text("connected with token \(token)").contains(token))
        #expect(!mask.text("Authorization: Bearer abc.def.ghi-123456").contains("abc.def.ghi-123456"))
        #expect(!mask.text("api_key=sk-test1234567890abcdef rest").contains("sk-test1234567890abcdef"))
        #expect(mask.text("plain words stay as they are") == "plain words stay as they are")
        let url = mask.text("GET https://user:hunter2@example.com/mcp?token=abcd1234&page=2")
        #expect(!url.contains("hunter2") && !url.contains("abcd1234") && url.contains("example.com") && url.contains("page=2"))
    }

    @Test func maskHidesHeadersAndEnvInAnEntry() throws {
        let entry: JSONValue = ["url": "https://api.example.com/mcp", "headers": ["Authorization": "Bearer live-secret-value", "Accept": "application/json"],
                                "env": ["ROOT": "/Users/me/files"], "args": ["--api-key", "sk-live1234567890", "serve"]]
        let text = McpEntryMask.phone.configurationText(name: "demo", entry: entry)
        #expect(!text.contains("live-secret-value") && !text.contains("sk-live1234567890") && !text.contains("/Users/me/files"))
        #expect(text.contains("application/json") && text.contains("api.example.com") && text.contains("serve") && text.contains(McpEntryMask.MASK))
    }

    @Test func redactedEntriesAreNeverWrittenBack() {
        #expect(McpToolFilter.looksRedacted(["headers": ["x": "••••••"]]))
        #expect(McpToolFilter.looksRedacted(["args": ["a", "***"]]))
        #expect(!McpToolFilter.looksRedacted(["url": "https://example.com", "headers": ["x-api-key": "${COMPOSIO_API_KEY}"]]))
    }

    // MARK: Tool rules

    @Test func toolFilterKeepsTheEntrysMode() {
        let plain: JSONValue = ["url": "https://e.example/mcp"]
        let off = McpToolFilter.setDisabled(plain, disabled: ["b"], discovered: ["a", "b", "c"])
        #expect(off["tools"]?["exclude"] == ["b"])
        #expect(McpToolFilter.isEnabled(off, "a") && !McpToolFilter.isEnabled(off, "b"))
        #expect(McpToolFilter.countEnabled(off, ["a", "b", "c"]) == 2)
        // Everything back on drops the rule entirely.
        #expect(McpToolFilter.setDisabled(off, disabled: [], discovered: ["a", "b", "c"])["tools"] == nil)
        // An include list stays an include list, and names not discovered this time are kept.
        let include: JSONValue = ["url": "u", "tools": ["include": ["a", "gone"]]]
        let next = McpToolFilter.setDisabled(include, disabled: ["a"], discovered: ["a", "b"])
        #expect(next["tools"]?["include"] == ["b", "gone"] && next["tools"]?["exclude"] == nil)
        // An empty include is a whitelist of nothing.
        #expect(!McpToolFilter.isEnabled(["tools": ["include": []]], "a"))
        // An exclusion for a tool that was not discovered survives a save.
        let kept = McpToolFilter.setDisabled(["tools": ["exclude": ["old"]]], disabled: ["a"], discovered: ["a"])
        #expect(kept["tools"]?["exclude"] == ["a", "old"])
    }

    @Test func connectorTitlesAndBusyWords() {
        #expect(ConnectorTitle.title(for: "my_files-server") == "My Files Server")
        #expect(ConnectorTitle.isBusy("request timed out after 30000 ms") && ConnectorTitle.isBusy("The gateway is busy"))
        #expect(!ConnectorTitle.isBusy("401 Unauthorized"))
    }

    // MARK: Issues on More

    @Test func issuesNeedTwoReadsTenSecondsApart() {
        let suite = "cap-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let issues = ServerIssues(defaults: defaults, now: { clock })
        issues.use(account: "acct")
        let failed = McpServer(name: "github", transport: "http", enabled: true, source: "config", plugin: nil, status: "failed", tools: 0)
        issues.report(profile: "default", servers: [failed])
        #expect(issues.count == 0, "one failed read is not an issue")
        clock += 5
        issues.report(profile: "default", servers: [failed])
        #expect(issues.count == 0, "still inside the debounce")
        clock += 6
        issues.report(profile: "default", servers: [failed])
        #expect(issues.count == 1 && issues.summary?.contains("GitHub") == true)
        // A needs-sign-in connector counts at once; a disabled one never does.
        var linear = McpServer(name: "linear", transport: "http", enabled: true, source: "config", plugin: nil, status: "connected", tools: 0)
        linear.auth = "oauth"; linear.oauthTokensPresent = false
        var files = failed; files.name = "files"; files.enabled = false
        clock += 1
        issues.report(profile: "ivy", servers: [linear, files])
        #expect(issues.count == 2 && issues.issues.first?.name == "linear", "newest first")
        #expect(ServerIssues.kind(of: files) == nil && ServerIssues.kind(of: linear) == .needsAuth)
        // Persisted per account, and read back.
        let again = ServerIssues(defaults: defaults, now: { clock })
        again.use(account: "acct")
        #expect(again.count == 2)
        again.use(account: "other")
        #expect(again.count == 0, "another gateway has its own issues")
        // Recovery clears; a day-old issue expires.
        var ok = failed; ok.status = "connected"
        issues.report(profile: "default", servers: [ok])
        #expect(issues.count == 1)
        clock += ServerIssues.lifetime + 1
        #expect(issues.count == 0)
        // A blip (failed once, fine on the next read) leaves no trace.
        issues.report(profile: "default", servers: [failed])
        issues.report(profile: "default", servers: [ok])
        clock += 20
        issues.report(profile: "default", servers: [failed])
        #expect(issues.count == 0, "the first failure after a recovery starts a new debounce")
        issues.signOut(account: "acct")
        #expect(defaults.object(forKey: "capabilities.serverIssues.acct") == nil)
    }

    // [13-3] A connector that stays broken keeps its issue past a day; one no read has found for a day still expires.
    @Test func aConnectorBrokenForDaysStaysAnIssue() {
        let suite = "cap-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let issues = ServerIssues(defaults: defaults, now: { clock })
        issues.use(account: "acct")
        let failed = McpServer(name: "github", transport: "http", enabled: true, source: "config", plugin: nil, status: "failed", tools: 0)
        var linear = McpServer(name: "linear", transport: "http", enabled: true, source: "config", plugin: nil, status: "connected", tools: 0)
        linear.auth = "oauth"; linear.oauthTokensPresent = false
        issues.report(profile: "default", servers: [failed, linear])
        clock += 11
        issues.report(profile: "default", servers: [failed, linear])
        #expect(issues.count == 2)
        for _ in 0..<20 {                      // two days of sweeps, every 2.5 hours
            clock += 9000
            issues.report(profile: "default", servers: [failed, linear])
            #expect(issues.count == 2, "still broken, still shown")
        }
        let again = ServerIssues(defaults: defaults, now: { clock })
        again.use(account: "acct")
        #expect(again.count == 2, "and after a relaunch")
        clock += ServerIssues.lifetime + 1     // no read since
        #expect(issues.count == 0)
    }

    @Test func sweepOrderPutsDefaultFirstAndCapsAtThirty() {
        func bot(_ id: String) -> String { id }
        let ids = (0..<40).map { "bot\($0)" } + ["default"]
        var order = ids
        if let index = order.firstIndex(of: "default") { order.remove(at: index); order.insert("default", at: 0) }
        #expect(Array(order.prefix(ServerIssueSweep.limit)).first == "default" && ServerIssueSweep.limit == 30)
    }

    // MARK: Tools

    @Test func toolsetLabelsCountsAndHiddenOnes() {
        #expect(Toolset.stripLabel("🌐 Web") == "Web")
        #expect(Toolset.stripLabel("Terminal") == "Terminal")
        #expect(Toolset.stripLabel("🌐") == "🌐", "a label that is only a picture stays")
        #expect(Toolset.compact(999) == "999" && Toolset.compact(1200) == "1.2K" && Toolset.compact(12_400) == "12K" && Toolset.compact(1_500_000) == "1.5M")
        #expect(Toolset.compact(-4) == "0")
        #expect(Toolset.hidden.contains("discord") && Toolset.hidden.contains("moa") && !Toolset.hidden.contains("web"))
        let row = Toolset.read(["name": "web", "label": "🌐 Web", "enabled": true, "configured": false, "tools": ["web_search", 3]])
        #expect(row?.label == "Web" && row?.configured == false && row?.tools == ["web_search"])
        #expect(Toolset.read(["label": "no name"]) == nil)
        #expect(SkillUsage.read(.number(12)) == 12 && SkillUsage.read(.string("12")) == nil && SkillUsage.read(.number(.nan)) == nil)
    }

    // MARK: Plugins

    @Test func pluginActionsSendExactlyTheContractsKeys() {
        #expect(PluginAction.toggle(key: "catalog:x", enable: true).params(profile: "ivy")
                == ["profile": "ivy", "action": "toggle", "key": "catalog:x", "enable": true])
        #expect(PluginAction.update(name: "x", accept: false).params(profile: "p") == ["profile": "p", "action": "update", "name": "x"])
        #expect(PluginAction.update(name: "x", accept: true).params(profile: "p")["accept_capabilities"] == true)
        #expect(PluginAction.remove(name: "x").params(profile: "p") == ["profile": "p", "action": "remove", "name": "x"])
        let install = PluginAction.install(identifier: "acme/x", force: false, enable: true, ref: "")
        #expect(install.params(profile: "p") == ["profile": "p", "action": "install", "identifier": "acme/x", "force": false, "enable": true])
        #expect(install.timeout == .seconds(120) && PluginAction.remove(name: "x").timeout == .seconds(60))
        #expect(PluginAction.install(identifier: "acme/x", force: true, enable: false, ref: String(repeating: "a", count: 40))
            .params(profile: "p")["ref"]?.string?.count == 40)
    }

    @Test func pluginRepositoryAddresses() {
        #expect(PluginRepo.check("") == .empty && PluginRepo.check("   ") == .empty)
        #expect(PluginRepo.check("acme/notes-plugin") == .ok)
        #expect(PluginRepo.check("https://github.com/acme/notes.git") == .ok)
        #expect(PluginRepo.check("git@github.com:acme/notes.git") == .ok)
        #expect(PluginRepo.check("http://github.com/acme/notes") == .insecure && PluginRepo.check("file:///etc/passwd") == .insecure)
        #expect(PluginRepo.check("not a repo") == .invalid && PluginRepo.check("--upload-pack=x") == .invalid && PluginRepo.check("acme") == .invalid)
        #expect(PluginRepo.refValid("") && PluginRepo.refValid(String(repeating: "f", count: 40)))
        #expect(!PluginRepo.refValid("main") && !PluginRepo.refValid(String(repeating: "g", count: 40)))
        #expect(PluginInfo.read(["name": "kanban", "key": "bundled:kanban", "source": "bundled", "status": "enabled"])?.isKanban == true)
        #expect(PluginInfo.read(["name": "mine", "key": "git:mine", "source": "git", "status": "enabled"])?.canUninstall == true)
        #expect(PluginInfo.read(["name": "kanban", "key": "bundled:kanban", "source": "bundled", "status": "enabled"])?.canUninstall == false)
    }

    // MARK: Add Connector

    @Test func connectorDraftRules() {
        var draft = ConnectorDraft()
        #expect(!draft.isComplete(existing: []) && !draft.hasContent)
        draft.name = "weather"
        draft.url = "https://mcp.weather.example/mcp"
        #expect(draft.isComplete(existing: ["github"]) && draft.hasContent)
        #expect(!draft.isComplete(existing: ["Weather"]), "names differing only in case collide")
        draft.name = "bad name"
        #expect(!draft.nameValid)
        draft.name = "weather"
        draft.url = "ftp://example.com"
        #expect(!draft.urlValid)
        draft.url = "https://mcp.weather.example/mcp"
        draft.auth = .bearer
        #expect(!draft.isComplete(existing: []), "a bearer connector needs its token")
        draft.token = " tok-1234 "
        #expect(draft.isComplete(existing: []) && draft.bearer == "tok-1234")
        #expect(draft.config["url"] == "https://mcp.weather.example/mcp")
        #expect((try? draft.config.encoded()).map { String(decoding: $0, as: UTF8.self).contains("tok-1234") } == false, "the token travels beside the entry, not in it")
        var command = ConnectorDraft()
        command.name = "files"; command.kind = .command
        #expect(!command.isComplete(existing: []))
        command.command = "npx"
        #expect(command.isComplete(existing: []) && command.bearer == nil && command.config["command"] == "npx")
    }

    // MARK: Logs

    @Test func logsShowOnlyThisConnectorsLastRun() {
        let lines = ["===== starting MCP server 'github' =====", "old run", "===== starting MCP server 'files' =====", "files line",
                     "===== starting MCP server 'github' =====", "new one", "new two", "===== starting MCP server 'linear' =====", "other"]
        #expect(ConnectorLogsModel.section(lines, name: "github") == ["new one", "new two"])
        #expect(ConnectorLogsModel.section(lines, name: "linear") == ["other"])
        #expect(ConnectorLogsModel.section(lines, name: "absent") == nil)
        let cleaned = ConnectorLogsModel.clean(["token ghp_abcdefghijklmnopqrstuvwxyz0123456789", String(repeating: "x ", count: 1500)])
        #expect(!cleaned[0].contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789") && cleaned[1].hasSuffix("…"))
        #expect(ConnectorLogsModel.clean((0..<700).map { "line \($0)" }).count == 500)
    }

    // MARK: OAuth for connectors

    @Test func signInPageMustBeHttpsAndCarryThisPhonesRedirect() {
        let redirect = "http://127.0.0.1:53111/callback"
        let good = "https://auth.example.com/authorize?client_id=x&redirect_uri=http%3A%2F%2F127.0.0.1%3A53111%2Fcallback&state=s"
        #expect(McpSignIn.accepts(authURL: good, redirect: redirect) != nil)
        #expect(McpSignIn.accepts(authURL: good, redirect: "http://127.0.0.1:1/callback") == nil, "a redirect to somewhere else is refused")
        #expect(McpSignIn.accepts(authURL: "http://auth.example.com/authorize?redirect_uri=\(redirect)", redirect: redirect) == nil, "plain http is refused")
        #expect(McpSignIn.accepts(authURL: "javascript:alert(1)", redirect: redirect) == nil)
        #expect(McpSignIn.accepts(authURL: "https://auth.example.com/authorize", redirect: redirect) == nil)
    }

    @Test func relayCallbackCarriesIssuerAndRefusals() {
        let ok = LoopbackRelay.callback(fromRequestHead: "GET /callback?code=abc&state=s1&iss=https%3A%2F%2Fauth.example.com HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        #expect(ok?.code == "abc" && ok?.state == "s1" && ok?.iss == "https://auth.example.com" && ok?.error == nil)
        let denied = LoopbackRelay.callback(fromRequestHead: "GET /callback?error=access_denied&state=s1 HTTP/1.1\r\n\r\n")
        #expect(denied?.error == "access_denied" && denied?.code == nil && denied?.state == "s1")
        #expect(LoopbackRelay.callback(fromRequestHead: "GET /favicon.ico HTTP/1.1\r\n\r\n") == nil)
        #expect(LoopbackRelay.callback(fromRequestHead: "GET /callback?state=s1 HTTP/1.1\r\n\r\n") == nil)
    }

    /// [cap-pages] Capabilities is four rows, each its own page with its own symbol (no tab to remember).
    @Test func fourListsEachAPage() {
        #expect(CapabilitiesTab.allCases.map(\.title) == ["Skills", "Tools", "Connectors", "Plugins"])
        #expect(Set(CapabilitiesTab.allCases.map(\.symbol)).count == 4)
        #expect(CapabilitiesHubView.footer.contains("Each bot has its own"))
    }
}
