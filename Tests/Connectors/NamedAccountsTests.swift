// [accounts] More than one account per managed app (the desktop's AccountsSection): every account of an app with its
// name and status, Rename through `connectors.accounts.rename` with its refusals in words, Remove per account, Add
// Another Account through the usual connect with an `alias`, and an older Hermes keeping the one-account page.

import Foundation
import Testing
@testable import HermesHQNative

@Suite(.serialized) @MainActor struct NamedAccountsTests {
    nonisolated static func row(_ id: String, alias: String?, label: String, status: String = "active", created: String,
                                disabled: Bool = false) -> JSONValue {
        var row: [String: JSONValue] = ["connection_id": .string(id), "connector": "gmail", "status": .string(status), "label": .string(label),
                                        "alias": alias.map { .string($0) } ?? .null, "active": .bool(status == "active"),
                                        "created_at": .string(created), "updated_at": .string(created), "disabled": .bool(disabled)]
        if status != "active" { row["status_reason"] = "Sign in again." }
        return .object(row)
    }

    /// Gmail with two named accounts and one retired by a reconnect.
    func script(named: Bool = true) -> BotsFakeGatewayClient {
        let client = BotsFakeGatewayClient()
        client.on("connectors.list") { _ in ["available": true, "connectors": [["connector": "gmail", "connected": true, "connection_status": "active"]]] }
        client.on("connectors.catalog") { _ in ["connectors": [["slug": "gmail", "name": "Gmail"]]] }
        client.on("connectors.policy.get") { _ in ["layers": []] }
        client.on("connectors.accounts") { _ in
            if !named {
                return ["accounts": [["connection_id": "a", "connector": "gmail", "status": "active", "label": "me@example.com", "active": true,
                                      "created_at": "2026-10-01T00:00:00Z", "updated_at": "2026-10-01T00:00:00Z"]]]
            }
            return ["accounts": [Self.row("old", alias: nil, label: "old@example.com", status: "inactive", created: "2026-09-01T00:00:00Z", disabled: true),
                                 Self.row("home", alias: "home", label: "me.home@example.com", status: "expired", created: "2026-10-20T00:00:00Z"),
                                 Self.row("work", alias: "work", label: "me@example.com", created: "2026-10-01T00:00:00Z")]]
        }
        return client
    }

    @Test func everyAccountShowsWithItsNameAndStatus() async {
        let managed = ManagedAppsModel(client: script(), profile: "ivy")
        await managed.reload()
        #expect(managed.accountNames)
        let gmail = managed.app("gmail")
        // Active first, then newest; the retired one apart.
        #expect(gmail?.accounts.map(\.name) == ["work", "home"])
        #expect(gmail?.retired.map(\.connectionId) == ["old"])
        #expect(gmail?.accountLabel == "me@example.com", "the picked account is the active one, never the retired one")
        #expect(gmail?.accounts[0].statusWords == nil)
        #expect(gmail?.accounts[1].statusWords == "Access expired" && gmail?.accounts[1].needsReconnect == true)
        #expect(gmail?.retired[0].statusWords == "Replaced by a reconnect")
    }

    @Test func anOlderHermesKeepsTheOneAccountPage() async {
        let managed = ManagedAppsModel(client: script(named: false), profile: "ivy")
        await managed.reload()
        #expect(!managed.accountNames)
        #expect(managed.app("gmail")?.accounts.map(\.name) == ["me@example.com"])
    }

    @Test func aliasRulesFollowTheGateway() {
        let rows = [ConnectorAccountRow(connectionId: "w", connector: "gmail", status: "active", statusReason: nil, label: "x", alias: "work",
                                        active: true, createdAt: "", updatedAt: "")]
        #expect(ConnectorAccountRow.aliasValid("work") && ConnectorAccountRow.aliasValid("home-2") && ConnectorAccountRow.aliasValid("9"))
        #expect(!ConnectorAccountRow.aliasValid("") && !ConnectorAccountRow.aliasValid("-work") && !ConnectorAccountRow.aliasValid("Work"))
        #expect(!ConnectorAccountRow.aliasValid("my work") && !ConnectorAccountRow.aliasValid(String(repeating: "a", count: 33)))
        #expect(ConnectorAccountRow.aliasProblem("work", among: rows) == AccountWords.aliasTaken)
        #expect(ConnectorAccountRow.aliasProblem("work", among: rows, renaming: "w") == nil, "keeping its own name is no clash")
        #expect(ConnectorAccountRow.aliasProblem("Work!", among: rows) == AccountWords.aliasInvalid)
    }

    @Test func renameSendsTheContractAndShowsTheNewName() async throws {
        let client = script()
        client.on("connectors.accounts.rename") { params in
            Self.row("work", alias: params["alias"]?.string, label: "me@example.com", created: "2026-10-01T00:00:00Z")
        }
        let managed = ManagedAppsModel(client: client, profile: "ivy")
        await managed.reload()
        let work = try #require(managed.app("gmail")?.accounts.first)
        #expect(await managed.rename(work, to: "office") == nil)
        let sent = try #require(client.calls("connectors.accounts.rename").first?.params)
        #expect(sent == ["connection_id": "work", "alias": "office", "profile": "ivy"])
        #expect(managed.app("gmail")?.accounts.first?.name == "office")
    }

    @Test func aRefusedRenamePutsTheOldNameBackAndSaysWhy() async throws {
        let client = script()
        client.on("connectors.accounts.rename") { _ in
            throw RPCError(code: 4090, message: "That name is already used.", data: ["reason": "ALIAS_TAKEN"])
        }
        let managed = ManagedAppsModel(client: client, profile: "ivy")
        await managed.reload()
        let work = try #require(managed.app("gmail")?.accounts.first)
        #expect(await managed.rename(work, to: "home2") == "That name is already used.")
        #expect(managed.app("gmail")?.accounts.first?.name == "work")

        client.on("connectors.accounts.rename") { _ in throw RPCError(code: 4000, message: "That name is invalid.", data: ["reason": "INVALID_PARAMS"]) }
        #expect(await managed.rename(work, to: "x") == AccountWords.aliasInvalid)
        client.on("connectors.accounts.rename") { _ in throw RPCError(code: 4041, message: "Connector account not found.", data: ["reason": "CONNECTION_NOT_FOUND"]) }
        #expect(await managed.rename(work, to: "y") == AccountWords.renameGone)
        // A Hermes that doesn't know the method: the named layout goes away.
        client.on("connectors.accounts.rename") { _ in throw RPCError(code: -32601, message: "unknown method: connectors.accounts.rename", data: nil) }
        #expect(await managed.rename(work, to: "z") == ConnectorFailure.tooOldWords)
        #expect(!managed.accountNames)
    }

    @Test func removeTakesOnlyThatAccount() async throws {
        let client = script()
        client.on("connectors.accounts.remove") { _ in ["connection_id": "home", "connector": "gmail", "status": "removed"] }
        let managed = ManagedAppsModel(client: client, profile: "ivy")
        await managed.reload()
        let home = try #require(managed.app("gmail")?.accounts.last)
        managed.remove(home)
        #expect(await eventually { client.calls("connectors.accounts.remove").count == 1 })
        #expect(client.calls("connectors.accounts.remove").first?.params == ["connection_id": "home", "profile": "ivy"])
    }

    @Test func addAnotherAndReconnectNameTheAccount() async throws {
        let client = script()
        client.on("connectors.connect") { _ in
            ["op_id": "op1", "seq": 1, "settled": true, "targets": [["name": "gmail", "state": "connected"]]]
        }
        let managed = ManagedAppsModel(client: client, profile: "ivy")
        await managed.reload()
        managed.connect("gmail", alias: "side")
        #expect(await eventually { client.calls("connectors.connect").count == 1 })
        let add = try #require(client.calls("connectors.connect").first?.params)
        #expect(add["alias"] == "side" && add["reconnect"] == false && add["connection_id"] == nil)

        let home = try #require(managed.app("gmail")?.accounts.last)
        #expect(await eventually { !managed.busy.contains("gmail") })
        managed.reconnect(home)
        #expect(await eventually { client.calls("connectors.connect").count == 2 })
        let repair = try #require(client.calls("connectors.connect").last?.params)
        #expect(repair["alias"] == "home" && repair["reconnect"] == true && repair["connection_id"] == nil)

        // An unnamed account is repaired by its id; an older Hermes never gets the key.
        let unnamed = ConnectorAccountRow(connectionId: "u1", connector: "gmail", status: "expired", statusReason: nil, label: "u@example.com",
                                          alias: nil, active: false, createdAt: "", updatedAt: "")
        #expect(await eventually { !managed.busy.contains("gmail") })
        managed.reconnect(unnamed)
        #expect(await eventually { client.calls("connectors.connect").count == 3 })
        #expect(client.calls("connectors.connect").last?.params["connection_id"] == "u1")
        managed.accountNames = false
        #expect(await eventually { !managed.busy.contains("gmail") })
        managed.reconnect(unnamed)
        #expect(await eventually { client.calls("connectors.connect").count == 4 })
        #expect(client.calls("connectors.connect").last?.params["connection_id"] == nil)
    }
}
