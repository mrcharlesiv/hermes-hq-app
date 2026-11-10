// Managed apps (Capabilities › Connectors › Managed Apps): decoding the connector contract, joining the reads into
// one row per app, the operation's sequence rule, and the plain words for every ConnectorErrorReason.

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct ManagedConnectorsTests {
    func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

    // MARK: Error words

    @Test func everyReasonHasPlainWords() {
        #expect(ConnectorErrorReason.allCases.count == 24)
        for reason in ConnectorErrorReason.allCases {
            let words = reason.words
            #expect(!words.isEmpty, "\(reason)")
            #expect(words.hasSuffix(".") || words.hasSuffix("?"), "\(reason): \(words)")
            #expect(!words.contains(reason.rawValue), "no wire names: \(words)")
            #expect(!words.localizedCaseInsensitiveContains("dispatch"), "\(words)")
            #expect(!words.contains("_"), "\(words)")
        }
        #expect(ConnectorErrorReason.needsNousAuth.words == "Sign in to Nous to use managed apps.")
        #expect(ConnectorErrorReason.connectorsUnavailable.words == "Managed apps are not available for this account yet.")
        #expect(ConnectorErrorReason.policyConflict.words == "Someone changed this rule while you were editing.")
        #expect(ConnectorErrorReason.linkStillValid.words.contains("still open"))
    }

    @Test func failureReadsTheReasonFromTheErrorData() throws {
        let error = RPCError(code: 4090, message: "Select an organization to manage connector rules.", data: try json(#"{"reason":"ORG_REQUIRED"}"#))
        let failure = ConnectorFailure(error)
        #expect(failure.reason == .orgRequired)
        #expect(failure.code == 4090)
        #expect(failure.words() == ConnectorErrorReason.orgRequired.words)
        // An unknown reason or none falls back, never shows the gateway's own message.
        let bare = ConnectorFailure(RPCError(code: 5000, message: "Traceback: KeyError", data: try json(#"{"reason":"SOMETHING_NEW"}"#)))
        #expect(bare.reason == nil)
        #expect(bare.words(fallback: "Try again.") == "Try again.")
    }

    @Test func anOlderHermesIsSaidSo() {
        let failure = ConnectorFailure(RPCError(code: -32601, message: "unknown method: connectors.catalog", data: nil))
        #expect(failure.tooOld)
        #expect(failure.words() == ConnectorFailure.tooOldWords)
        #expect(!ConnectorFailure(RPCError(code: 4032, message: "x", data: nil)).tooOld)
    }

    // MARK: Decoding

    @Test func decodesListCatalogAccountsAndTools() throws {
        let list = ManagedWire.list(try json(#"""
        {"available": true, "connectors": [
          {"connector": "github", "enabled": true, "connected": true, "connection_status": "active", "status_reason": null, "gateway_disabled_tools": ["github_delete_repo"]},
          {"connector": "", "enabled": true}]}
        """#))
        #expect(list.available)
        #expect(list.connectors.count == 1, "a row without a slug is dropped")
        #expect(list.connectors[0].gatewayDisabledTools == ["github_delete_repo"])
        #expect(!ManagedWire.list(try json(#"{"available": false, "connectors": []}"#)).available)

        let catalog = ManagedWire.catalog(try json(#"{"connectors": [{"slug": "google_calendar", "name": "Google Calendar", "description": "Events.", "category": "Productivity", "logo_url": null}]}"#))
        #expect(catalog == [ConnectorCatalogRow(slug: "google_calendar", name: "Google Calendar", description: "Events.", category: "Productivity", logoURL: nil)])

        let accounts = ManagedWire.accounts(try json(#"""
        {"accounts": [{"connection_id": "conn_1", "connector": "gmail", "status": "active", "status_reason": null, "label": "me@example.com",
                       "alias": null, "active": true, "created_at": "2026-10-01T00:00:00Z", "updated_at": "2026-10-01T00:00:00Z"}]}
        """#))
        #expect(accounts.first?.connectionId == "conn_1")
        #expect(accounts.first?.label == "me@example.com")

        let tools = ManagedWire.tools(try json(#"""
        {"connector": "github", "stale": false, "tools": [
          {"slug": "github_list_issues", "name": "List issues", "description": "Lists.", "facet": "read", "hints": ["readOnly"], "categories": [], "deprecated": false},
          {"slug": "github_old", "name": "Old", "description": "", "facet": "mystery", "hints": [], "categories": [], "deprecated": true}]}
        """#))
        #expect(tools.tools.map(\.slug) == ["github_list_issues", "github_old"])
        #expect(tools.tools[1].deprecated)
        #expect(ManagedToolWords.facet(tools.tools[1].facet) == "Unknown effect")
    }

    @Test func decodesPolicyLayers() throws {
        let policy = ManagedWire.policy(try json(#"""
        {"layers": [
          {"kind": "org", "revision": "01ORG0000000000000000000000", "body": {"mode": "deny", "disabled_connectors": ["jira"], "tools": {"github": ["github_transfer_repo"]}}},
          {"kind": "member", "revision": "01MEMBER00000000000000000000", "body": {"mode": "deny", "disabled_connectors": ["slack"], "tools": {"github": ["github_delete_repo"]}}}],
         "effective": {}}
        """#))
        #expect(policy.memberRevision == "01MEMBER00000000000000000000")
        #expect(!policy.memberEnables("slack"))
        #expect(policy.memberEnables("github"))
        #expect(policy.orgLocks("jira"))
        #expect(!policy.orgLocks("github"))
        #expect(policy.memberDisabledTools("github") == ["github_delete_repo"])
        let allow = ManagedWire.rules(try json(#"{"kind": "member", "revision": "r", "body": {"mode": "allow", "connectors": ["gmail"]}}"#))
        #expect(allow.allows("gmail") && !allow.allows("github"))
        let none = ManagedWire.rules(try json(#"{"kind": "member", "revision": "r", "body": {"mode": "deny-all"}}"#))
        #expect(!none.allows("gmail"))
        let open = ManagedWire.rules(try json(#"{"kind": "member", "revision": "r", "body": {"mode": "unrestricted"}}"#))
        #expect(open.allows("anything"))
    }

    // MARK: The operation

    func operation(seq: Int, state: String, link: String? = nil, settled: Bool = false) throws -> ConnectionOperation {
        let url = link.map { #""connect_url": "\#($0)", "connection_id": "conn_1","# } ?? ""
        return try #require(ManagedWire.operation(try json(#"""
        {"op_id": "op_1", "seq": \#(seq), "deadline_at": 100, "settled": \#(settled), "settled_by": null,
         "targets": [{\#(url) "name": "notion", "state": "\#(state)", "detail": ""}]}
        """#)))
    }

    @Test func broadcastsMustBeNewerAndKeepTheLink() throws {
        let held = try operation(seq: 2, state: "initiated", link: "https://connect.example/a")
        #expect(held.link == "https://connect.example/a")
        // The same seq is refused as a broadcast and taken as a reply.
        #expect(held.applying(try operation(seq: 2, state: "connected"), broadcast: true) == nil)
        #expect(held.applying(try operation(seq: 2, state: "initiated"), broadcast: false) != nil)
        #expect(held.applying(try operation(seq: 1, state: "connected"), broadcast: false) == nil, "an older reply is ignored")
        // A broadcast carries no link or account id: both are kept.
        let moved = try #require(held.applying(try operation(seq: 3, state: "initiated"), broadcast: true))
        #expect(moved.link == "https://connect.example/a")
        #expect(moved.target("notion")?.connectionId == "conn_1")
        // Connected and settled: nothing more is asked.
        let done = try #require(moved.applying(try operation(seq: 4, state: "connected", settled: true), broadcast: true))
        #expect(done.settled && !done.stillOpen)
        #expect(done.link == nil, "the link is gone once the row left initiated")
    }

    @Test func aReissuedRowDropsTheDeadLink() throws {
        let expired = try operation(seq: 3, state: "expired", link: "https://connect.example/old")
        let reissued = try #require(expired.applying(try operation(seq: 4, state: "initiated"), broadcast: true))
        #expect(reissued.link == nil, "the old link is dead after a re-issue")
        let settledFailed = try operation(seq: 5, state: "failed", settled: true)
        #expect(settledFailed.stillOpen, "settled without the app connected still asks something")
    }

    // MARK: The join

    func catalog() -> [ConnectorCatalogRow] {
        [("github", "GitHub", "Developer tools"), ("gmail", "Gmail", "Communication"), ("slack", "Slack", "Communication"),
         ("jira", "Jira", "Developer tools"), ("notion", "Notion", "Productivity")]
            .map { ConnectorCatalogRow(slug: $0.0, name: $0.1, description: "", category: $0.2, logoURL: nil) }
    }

    @Test func joinsIntoOneRowPerAppWithDesktopWords() throws {
        let list = [ConnectorListRow(connector: "github", enabled: true, connected: true, connectionStatus: "active", statusReason: nil, gatewayDisabledTools: []),
                    ConnectorListRow(connector: "slack", enabled: true, connected: true, connectionStatus: "expired", statusReason: nil, gatewayDisabledTools: []),
                    ConnectorListRow(connector: "gmail", enabled: true, connected: true, connectionStatus: "failed", statusReason: "Gmail said no.", gatewayDisabledTools: [])]
        let policy = ManagedWire.policy(try json(#"""
        {"layers": [{"kind": "org", "revision": "o", "body": {"mode": "deny", "disabled_connectors": ["jira"]}},
                    {"kind": "member", "revision": "m", "body": {"mode": "deny", "disabled_connectors": [], "tools": {"github": ["a", "b"]}}}]}
        """#))
        let apps = ManagedJoin.apps(catalog: catalog(), list: list, accounts: [], policy: policy, rulesReadable: true)
        let by = Dictionary(uniqueKeysWithValues: apps.map { ($0.slug, $0) })
        #expect(by["github"]?.stateWord == "Connected · 2 tools off")
        #expect(by["slack"]?.stateWord == "Access expired")
        #expect(by["slack"]?.verb == .reconnect)
        #expect(by["slack"]?.reason == "Reconnect to keep this app working.")
        #expect(by["gmail"]?.stateWord == "Couldn’t connect")
        #expect(by["gmail"]?.reason == "Gmail said no.")
        #expect(by["jira"]?.stateWord == "Off by your organisation")
        #expect(by["jira"]?.verb == nil, "nothing to tap for an app the organisation turned off")
        #expect(by["notion"]?.stateWord == "Available")
        #expect(by["notion"]?.verb == .connect)
        // Broken first, then by name.
        #expect(ManagedJoin.mine(apps).map(\.slug) == ["gmail", "slack", "github"])
        #expect(ManagedJoin.categories(apps) == ["Communication", "Developer tools", "Productivity"])
        #expect(by["notion"]?.matches("product") == true)
        #expect(by["notion"]?.matches("calendar") == false)
    }

    @Test func aSignInGivenUpReadsAsNeverStarted() throws {
        let pending = ConnectorAccountRow(connectionId: "c", connector: "notion", status: "pending", statusReason: nil, label: "", alias: nil,
                                          active: false, createdAt: "", updatedAt: "")
        let policy = ConnectorPolicyView(member: nil, others: [])
        let waiting = ManagedJoin.apps(catalog: catalog(), list: [], accounts: [pending], policy: policy, rulesReadable: true)
        #expect(waiting.first { $0.slug == "notion" }?.state == .connecting)
        let abandoned = ManagedJoin.apps(catalog: catalog(), list: [], accounts: [pending], policy: policy, rulesReadable: true, abandoned: ["notion"])
        #expect(abandoned.first { $0.slug == "notion" }?.state == .available)
    }

    @Test func toolWords() {
        #expect(ManagedToolWords.draft(off: 1, backOn: 0) == "1 tool off, none back on")
        #expect(ManagedToolWords.draft(off: 2, backOn: 1) == "2 tools off, 1 back on")
        #expect(ManagedToolWords.conflict(theyOff: 1, theyOn: 0).hasPrefix("They turned off 1 tool you have on."))
        #expect(ManagedWire.title("google_calendar") == "Google Calendar")
    }
}
