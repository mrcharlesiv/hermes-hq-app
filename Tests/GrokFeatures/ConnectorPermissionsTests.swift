// Per-tool connector levels: what is stored, what a tool comes back as, and what the page offers when the add-on
// on that computer can and can't enforce the asking levels.

import Testing
import Foundation
@testable import HermesHQNative

@MainActor @Suite(.serialized) struct ConnectorPermissionsTests {

    private let server = McpServer(name: "mail", transport: "http", enabled: true, source: "config", plugin: nil,
                                   status: "connected", tools: 150, auth: "oauth", url: "https://mcp.example.com",
                                   command: nil, hasHeaders: false)

    private func page(levels: Bool = true, entry: JSONValue = ["url": "https://mcp.example.com"],
                      tools: [String]) -> ConnectorPageModel {
        let parent = CapabilitiesModel(services: CapabilitiesFakeServices(CapabilitiesStore(client: BotsFakeGatewayClient())),
                                       profile: "otto", tab: .connectors)
        let model = ConnectorPageModel(parent: parent, server: server)
        model.levels = levels
        model.tools = tools.map { McpTool(name: $0, description: "Does \($0)") }
        model.entry = entry
        model.savedPermissions = McpToolFilter.permissions(entry, discovered: tools)
        model.draftPermissions = model.savedPermissions
        model.savedOff = Set(tools.filter { model.savedPermissions[$0] == .blocked })
        model.draftOff = model.savedOff
        return model
    }

    // MARK: What is stored

    /// A tool nobody set a level for runs without asking: that is what Hermes does with it, and the page must
    /// not say anything gentler.
    @Test func aToolWithNothingStoredRunsWithoutAsking() {
        let base: JSONValue = ["url": "https://mcp.example.com"]
        for name in ["read_mail", "send_email"] {
            #expect(McpToolFilter.permission(base, name) == .alwaysAllow)
            #expect(McpToolFilter.storedLevel(base, name) == .alwaysAllow)
        }
        #expect(McpToolPermission.alwaysAllow.subtitle == "Runs without asking")
    }

    @Test func allFourLevelsRoundTripAndOnlyTheAskingOnesAreStored() {
        let base: JSONValue = ["url": "https://mcp.example.com"]
        let discovered = ["read_mail", "search_mail", "send_email", "delete_email"]
        let desired: [String: McpToolPermission] = [
            "read_mail": .alwaysAllow, "search_mail": .autoReview, "send_email": .needsApproval, "delete_email": .blocked,
        ]
        let updated = McpToolFilter.setPermissions(base, permissions: desired, discovered: discovered)

        // Blocked is Hermes's own `tools.exclude`, so a Hermes without the add-on still hides the tool.
        #expect(updated["tools"]?["exclude"]?.array?.compactMap(\.string) == ["delete_email"])
        for (name, level) in desired { #expect(McpToolFilter.permission(updated, name) == level) }

        let stored = updated["tools"]?["permissions"]?.object
        #expect(stored == ["search_mail": "auto_review", "send_email": "needs_approval"])

        // Everything back to "runs without asking" leaves no `tools` key behind.
        let reset = McpToolFilter.setPermissions(updated, permissions: Dictionary(uniqueKeysWithValues: discovered.map { ($0, .alwaysAllow) }),
                                                 discovered: discovered)
        #expect(reset == base)
    }

    /// The bug this guards: a tool that needed approval was blocked and saved, then unblocked and saved. It must
    /// come back needing approval, not running unasked.
    @Test func aBlockedToolKeepsTheLevelItHad() {
        let base: JSONValue = ["url": "https://mcp.example.com"]
        let discovered = ["send_email", "read_mail"]
        let asking = McpToolFilter.setPermissions(base, permissions: ["send_email": .needsApproval, "read_mail": .alwaysAllow], discovered: discovered)
        let blocked = McpToolFilter.setPermissions(asking, permissions: ["send_email": .blocked, "read_mail": .alwaysAllow], discovered: discovered)
        #expect(McpToolFilter.permission(blocked, "send_email") == .blocked)
        #expect(McpToolFilter.storedLevel(blocked, "send_email") == .needsApproval)

        // The plain on/off save (a page without levels) leaves the stored level alone too.
        let backOn = McpToolFilter.setDisabled(blocked, disabled: [], discovered: discovered)
        #expect(McpToolFilter.permission(backOn, "send_email") == .needsApproval)

        let model = page(entry: blocked, tools: discovered)
        #expect(model.permission(for: "send_email") == .blocked)
        model.setTool("send_email", on: true)
        #expect(model.permission(for: "send_email") == .needsApproval)
    }

    @Test func includeModeUndiscoveredToolsAndJunkValuesSurvive() {
        let server: JSONValue = [
            "url": "https://mcp.example.com",
            "tools": [
                "include": ["a", "b", "hidden_tool"],
                "permissions": ["hidden_tool": "needs_approval", "a": "nonsense", "b": 7, "old": "always_allow", "gone": "blocked"],
            ],
        ]
        // Junk reads as nothing stored.
        #expect(McpToolFilter.permission(server, "a") == .alwaysAllow)
        #expect(McpToolFilter.permission(server, "b") == .alwaysAllow)
        #expect(McpToolFilter.storedLevel(server, "gone") == .alwaysAllow)

        let updated = McpToolFilter.setPermissions(server, permissions: ["a": .autoReview, "b": .blocked], discovered: ["a", "b"])
        #expect(updated["tools"]?["include"]?.array?.compactMap(\.string) == ["a", "hidden_tool"])
        #expect(updated["tools"]?["permissions"]?.object == ["a": "auto_review", "hidden_tool": "needs_approval"])
        #expect(McpToolFilter.permission(updated, "hidden_tool") == .needsApproval)
        #expect(updated["url"] == "https://mcp.example.com")

        // Not an object at all: handed back untouched, no crash.
        #expect(McpToolFilter.setPermissions("oops", permissions: ["a": .blocked], discovered: ["a"]) == "oops")
        #expect(McpToolFilter.permission(nil, "a") == .alwaysAllow)
    }

    @Test func toolNamesWithOddCharactersAndDuplicatesAreHandled() {
        let names = ["send.email", "tool with space", "émoji_🔧", "a/b", "", "dup", "dup"]
        let base: JSONValue = ["command": "npx"]
        var wanted: [String: McpToolPermission] = [:]
        for (i, name) in names.enumerated() { wanted[name] = McpToolPermission.allCases[i % 4] }
        let updated = McpToolFilter.setPermissions(base, permissions: wanted, discovered: names)
        for name in Set(names) { #expect(McpToolFilter.permission(updated, name) == wanted[name]) }
    }

    /// 2,000 random edits against a plain model of what should happen.
    @Test func randomEditsNeverLoseOrInventALevel() {
        var rng = SystemRandomNumberGenerator()
        let tools = (0..<40).map { "tool_\($0)" }
        var server: JSONValue = ["url": "https://mcp.example.com", "headers": ["x-api-key": "${KEY}"]]
        var level: [String: McpToolPermission] = [:]      // what each tool is when on
        var off: Set<String> = []
        for _ in 0..<2_000 {
            let name = tools.randomElement(using: &rng)!
            let pick = McpToolPermission.allCases.randomElement(using: &rng)!
            if pick == .blocked { off.insert(name) } else { off.remove(name); level[name] = pick }
            var wanted: [String: McpToolPermission] = [:]
            for tool in tools { wanted[tool] = off.contains(tool) ? .blocked : (level[tool] ?? .alwaysAllow) }
            server = McpToolFilter.setPermissions(server, permissions: wanted, discovered: tools)
        }
        for tool in tools {
            #expect(McpToolFilter.permission(server, tool) == (off.contains(tool) ? .blocked : (level[tool] ?? .alwaysAllow)))
            #expect(McpToolFilter.storedLevel(server, tool) == (level[tool] ?? .alwaysAllow))
        }
        #expect(server["headers"]?["x-api-key"] == "${KEY}")
    }

    // MARK: The page's draft

    @Test func draftTracksLevelsRestoresThemAndFiltersAtScale() {
        let names = (0..<150).map { "tool_\($0)" }
        let model = page(tools: names)
        #expect(!model.dirty)
        #expect(model.count(for: .alwaysAllow) == 150)

        model.setPermission(.needsApproval, for: "tool_0")
        #expect(model.dirty && model.changedCount == 1)
        model.setTool("tool_0", on: false)
        #expect(model.permission(for: "tool_0") == .blocked && model.draftOff == ["tool_0"])
        model.setTool("tool_0", on: true)
        #expect(model.permission(for: "tool_0") == .needsApproval && model.draftOff.isEmpty)

        model.setAllPermissions(.autoReview)
        #expect(model.count(for: .autoReview) == 150)
        model.setPermission(.blocked, for: "tool_10")
        model.setPermission(.needsApproval, for: "tool_11")
        model.permissionFilter = .blocked
        #expect(model.shownTools.map(\.name) == ["tool_10"])
        model.permissionFilter = .needsApproval
        #expect(model.shownTools.map(\.name) == ["tool_11"])
        model.search = "tool_11"
        #expect(model.shownTools.map(\.name) == ["tool_11"])
        model.search = "tool_12"
        #expect(model.shownTools.isEmpty)
        #expect(model.draftSummary == "150 changes · 1 asks every time, 148 auto-review, 1 blocked")

        model.discard()
        #expect(!model.dirty && model.draftOff.isEmpty && model.changedCount == 0)
        #expect(model.permission(for: "tool_0") == .alwaysAllow)
        // Nothing remembered from the thrown-away draft.
        model.setTool("tool_0", on: false)
        model.setTool("tool_0", on: true)
        #expect(model.permission(for: "tool_0") == .alwaysAllow)
        #expect(!model.dirty)
    }

    /// The All Tools switch brings back what was off. It used to set every tool to one level, wiping the rest.
    @Test func allToolsSwitchKeepsEveryToolsOwnLevel() {
        let model = page(tools: ["read", "send", "delete", "search"])
        model.setPermission(.needsApproval, for: "send")
        model.setPermission(.autoReview, for: "search")
        model.setPermission(.blocked, for: "delete")

        model.setAll(false)
        #expect(model.draftOff.count == 4)
        #expect(model.count(for: .blocked) == 4)
        model.setAll(true)
        #expect(model.draftOff.isEmpty)
        #expect(model.permission(for: "read") == .alwaysAllow)
        #expect(model.permission(for: "send") == .needsApproval)
        #expect(model.permission(for: "search") == .autoReview)
        #expect(model.permission(for: "delete") == .alwaysAllow)

        // Fast repeated flips land where they should.
        for i in 0..<101 { model.setAll(i % 2 == 1) }
        #expect(model.draftOff.count == 4)
        model.setAll(true)
        #expect(model.permission(for: "send") == .needsApproval)
    }

    /// Without an add-on that enforces them, the page is the plain on/off page it always was, and saving from it
    /// leaves any stored level where it is.
    @Test func withoutEnforcementThePageIsOnAndOffOnly() async throws {
        let stored: JSONValue = ["url": "https://mcp.example.com", "tools": ["permissions": ["send": "needs_approval"]]]
        let model = page(levels: false, entry: stored, tools: ["read", "send"])
        model.setTool("read", on: false)
        #expect(model.draftSummary == "1 tool off, none back on")
        model.setTool("send", on: false)
        model.setTool("send", on: true)
        #expect(model.permission(for: "send") == .needsApproval)

        let script = ConnectorScript(["mail": stored])
        let store = CapabilitiesStore(client: script.client)
        var wanted: [String: McpToolPermission] = [:]
        for name in ["read", "send"] { wanted[name] = model.permission(for: name) }
        guard case .saved = try await store.saveToolPolicies("mail", permissions: wanted, discovered: ["read", "send"], profile: "otto") else {
            Issue.record("expected a save"); return
        }
        let entry = script.entry("mail")
        #expect(entry?["tools"]?["exclude"]?.array?.compactMap(\.string) == ["read"])
        #expect(entry?["tools"]?["permissions"]?.object == ["send": "needs_approval"])
    }

    @Test func aSaveOnItsWayHoldsTheDraftStill() {
        let model = page(tools: ["read", "send"])
        model.setPermission(.needsApproval, for: "send")
        model.saving = true
        model.setPermission(.blocked, for: "read")
        model.setAllPermissions(.autoReview)
        model.setAll(false)
        model.setTool("send", on: false)
        #expect(model.permission(for: "read") == .alwaysAllow)
        #expect(model.permission(for: "send") == .needsApproval)
    }

    // MARK: Saving, and whether the levels are offered

    @Test func savesAtomicallyAndRollsBackOnFailure() async throws {
        let script = ConnectorScript(["mail": ["url": "https://mcp.example.com"]])
        let store = CapabilitiesStore(client: script.client)
        let vault = MemoryToolRuleVault()
        store.toolRuleVault = vault

        let outcome = try await store.saveToolPolicies("mail", permissions: ["read": .alwaysAllow, "send": .needsApproval, "delete": .blocked],
                                                       discovered: ["read", "send", "delete"], profile: "otto")
        guard case .saved = outcome else { Issue.record("Expected saved, got \(outcome)"); return }
        #expect(vault.all().isEmpty)
        let saved = script.entry("mail")
        #expect(McpToolFilter.permission(saved, "read") == .alwaysAllow)
        #expect(McpToolFilter.permission(saved, "send") == .needsApproval)
        #expect(McpToolFilter.permission(saved, "delete") == .blocked)

        // Same again: nothing to write, the gateway isn't touched.
        let calls = script.client.calls.count
        let again = try await store.saveToolPolicies("mail", permissions: ["read": .alwaysAllow, "send": .needsApproval, "delete": .blocked],
                                                     discovered: ["read", "send", "delete"], profile: "otto")
        guard case .unchanged = again else { Issue.record("Expected unchanged, got \(again)"); return }
        #expect(script.client.calls.count == calls)

        script.failAdds = 1
        let failed = try await store.saveToolPolicies("mail", permissions: ["read": .blocked, "send": .blocked, "delete": .blocked],
                                                      discovered: ["read", "send", "delete"], profile: "otto")
        guard case .rolledBack = failed else { Issue.record("Expected rolledBack, got \(failed)"); return }
        #expect(script.entry("mail") == saved)
        #expect(vault.all().isEmpty)
    }

    @Test func levelsAreOfferedOnlyWhenTheAddOnSaysItEnforcesThem() async {
        #expect(PushPolicy.toolPermissions(["toolPermissions": true]))
        #expect(!PushPolicy.toolPermissions(["toolPermissions": false]))
        #expect(!PushPolicy.toolPermissions(["toolPermissions": "yes"]))
        #expect(!PushPolicy.toolPermissions(["version": "0.9.85"]))
        #expect(!PushPolicy.toolPermissions(nil))
        // An add-on that enforces but can't ask (an old Hermes there): said only when it says so itself.
        #expect(PushPolicy.toolPermissionsAsk(["toolPermissions": true]))
        #expect(PushPolicy.toolPermissionsAsk(["toolPermissionsAsk": true]))
        #expect(!PushPolicy.toolPermissionsAsk(["toolPermissions": true, "toolPermissionsAsk": false]))

        func enforced(_ answer: @escaping @Sendable () throws -> Data) async -> Bool {
            let client = BotsFakeGatewayClient()
            client.onREST { _, path, _, _ in
                guard path == PushPolicy.route + "/status" else { throw HTTPError(status: 404, body: nil) }
                return try answer()
            }
            return await CapabilitiesStore(client: client).addOnEnforcesToolLevels()
        }
        #expect(await enforced { Data(#"{"version":"0.9.86","toolPermissions":true}"#.utf8) })
        #expect(await enforced { Data(#"{"version":"0.9.85"}"#.utf8) } == false)
        #expect(await enforced { Data("not json".utf8) } == false)
        #expect(await enforced { throw HTTPError(status: 404, body: nil) } == false)
        #expect(await enforced { throw URLError(.timedOut) } == false)
    }
}
