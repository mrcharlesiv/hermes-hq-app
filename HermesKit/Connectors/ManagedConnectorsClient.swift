// The connector RPCs (`capabilities/connectors/data/rpc.ts`), with exactly the params the gateway's contracts name:
// Hermes refuses any other key (4000). Every call is scoped to one bot with `profile`; the connection operation is
// always the account's (`owner: {type: "account"}`), never a chat's. Failures come back as `ConnectorFailure`.

import Foundation

nonisolated struct ManagedConnectorsClient: Sendable {
    let client: any GatewayClient
    /// The desktop's 45 s: a connect waits for the connector service to mint a link.
    var timeout: Duration = .seconds(45)

    static let owner: JSONValue = ["type": "account"]

    private func call(_ method: String, _ params: [String: JSONValue], profile: String) async throws -> JSONValue {
        var params = params
        params["profile"] = .string(profile)
        do {
            return try await client.call(method, .object(params), timeout: timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ConnectorFailure(error)
        }
    }

    func list(profile: String) async throws -> ConnectorListResult {
        ManagedWire.list(try await call("connectors.list", ["owner": Self.owner], profile: profile))
    }

    func catalog(profile: String) async throws -> [ConnectorCatalogRow] {
        ManagedWire.catalog(try await call("connectors.catalog", [:], profile: profile))
    }

    func accounts(profile: String) async throws -> [ConnectorAccountRow] {
        try await namedAccounts(profile: profile).rows
    }

    /// The accounts, and whether this Hermes names them (`ManagedWire.accountsNamed`).
    func namedAccounts(profile: String) async throws -> (rows: [ConnectorAccountRow], named: Bool?) {
        let value = try await call("connectors.accounts", [:], profile: profile)
        return (ManagedWire.accounts(value), ManagedWire.accountsNamed(value))
    }

    /// `connectors.accounts.rename`: answers the renamed row.
    @discardableResult
    func rename(_ connectionId: String, alias: String, profile: String) async throws -> ConnectorAccountRow? {
        let value = try await call("connectors.accounts.rename", ["connection_id": .string(connectionId), "alias": .string(alias)], profile: profile)
        return ManagedWire.accounts(["accounts": [value]]).first
    }

    func policy(profile: String) async throws -> ConnectorPolicyView {
        ManagedWire.policy(try await call("connectors.policy.get", [:], profile: profile))
    }

    func tools(_ slug: String, refresh: Bool = false, profile: String) async throws -> ConnectorToolsResult {
        ManagedWire.tools(try await call("connectors.tools", ["slug": .string(slug), "refresh": .bool(refresh)], profile: profile))
    }

    /// `alias` connects (or repairs) the account of that name; `connectionId` repairs an unnamed one (with `reconnect`).
    /// Neither key is sent when nil: a Hermes from before account names refuses them.
    func connect(_ slug: String, reconnect: Bool, alias: String? = nil, connectionId: String? = nil, profile: String) async throws -> ConnectionOperation {
        var params: [String: JSONValue] = ["owner": Self.owner, "connectors": [.string(slug)], "reconnect": .bool(reconnect)]
        if let alias { params["alias"] = .string(alias) }
        else if reconnect, let connectionId { params["connection_id"] = .string(connectionId) }
        let value = try await call("connectors.connect", params, profile: profile)
        guard let operation = ManagedWire.operation(value, connectors: [slug]) else {
            throw ConnectorFailure(reason: .invalidConnectorResponse, code: nil, message: "no operation")
        }
        return operation
    }

    func status(_ opId: String, connectors: [String], profile: String) async throws -> ConnectionOperation {
        let value = try await call("connectors.operation.status", ["op_id": .string(opId), "owner": Self.owner], profile: profile)
        guard let operation = ManagedWire.operation(value, connectors: connectors) else {
            throw ConnectorFailure(reason: .invalidConnectorResponse, code: nil, message: "no operation")
        }
        return operation
    }

    /// The browser leg came back: Hermes reads the account now instead of at its next tick.
    func wake(_ opId: String, profile: String) async throws {
        _ = try await call("connectors.operation.wake", ["op_id": .string(opId), "owner": Self.owner], profile: profile)
    }

    /// Stop waiting (`giveUp`): the operation settles with Continue.
    func giveUp(_ opId: String, profile: String) async throws {
        _ = try await call("connection.respond", ["op_id": .string(opId), "owner": Self.owner, "result": ["settled_by": "continue"]], profile: profile)
    }

    func remove(_ connectionId: String, profile: String) async throws {
        _ = try await call("connectors.accounts.remove", ["connection_id": .string(connectionId)], profile: profile)
    }

    /// `{type: "connector", connector, enabled}`; answers the member layer's new revision.
    @discardableResult
    func setEnabled(_ slug: String, enabled: Bool, revision: String, profile: String) async throws -> String? {
        let change: JSONValue = ["type": "connector", "connector": .string(slug), "enabled": .bool(enabled)]
        let value = try await call("connectors.policy.set", ["change": change, "expected_revision": .string(revision)], profile: profile)
        return ManagedWire.text(value["revision"])
    }

    /// `{type: "tools", connector, disabled_tools}`.
    @discardableResult
    func setDisabledTools(_ slug: String, disabled: [String], revision: String, profile: String) async throws -> String? {
        let change: JSONValue = ["type": "tools", "connector": .string(slug), "disabled_tools": .array(disabled.map { .string($0) })]
        let value = try await call("connectors.policy.set", ["change": change, "expected_revision": .string(revision)], profile: profile)
        return ManagedWire.text(value["revision"])
    }
}
