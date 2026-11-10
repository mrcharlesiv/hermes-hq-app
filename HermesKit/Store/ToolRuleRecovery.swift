// A connector's tool list is saved as remove-then-add (spec 3x §5.5-b: this Hermes has no update call, and an add
// over an existing name answers 4090). If the app is closed or the network drops between the two, the connector would
// be gone. Before the remove, the entry is kept here; the next Connectors read puts a missing one back.
//
// The entry can hold header values, so it lives in the Keychain (this device only, never synced), not UserDefaults.

import Foundation
import Security

nonisolated struct ToolRuleMarker: Sendable, Equatable {
    var profile: String
    var name: String
    var entry: JSONValue
    var at: Date
}

nonisolated protocol ToolRuleVault: Sendable {
    func all() -> [ToolRuleMarker]
    func put(_ marker: ToolRuleMarker)
    func remove(profile: String, name: String)
}

/// One Keychain item per gateway account, holding that account's pending markers as JSON.
nonisolated struct KeychainToolRuleVault: ToolRuleVault {
    var service = "\(AppIdentity.current.bundleId).toolrules"
    var account: String
    /// DECISION: a marker older than this is dropped unread; a connector missing for that long was more likely
    /// removed on purpose somewhere else.
    static let keep: TimeInterval = 30 * 24 * 3600

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func all() -> [ToolRuleMarker] {
        var find = query
        find[kSecReturnData as String] = true
        find[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(find as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let rows = (try? JSONValue.parse(data))?.array else { return [] }
        return rows.compactMap { row in
            guard let profile = row["profile"]?.string, let name = row["name"]?.string, let entry = row["entry"], entry.object != nil,
                  let at = row["at"]?.double else { return nil }
            return ToolRuleMarker(profile: profile, name: name, entry: entry, at: Date(timeIntervalSince1970: at))
        }
    }

    private func write(_ markers: [ToolRuleMarker]) {
        SecItemDelete(query as CFDictionary)
        guard !markers.isEmpty else { return }
        let rows = JSONValue.array(markers.map { ["profile": .string($0.profile), "name": .string($0.name), "entry": $0.entry,
                                                  "at": .number($0.at.timeIntervalSince1970)] })
        guard let data = try? rows.encoded() else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    func put(_ marker: ToolRuleMarker) {
        write(all().filter { !($0.profile == marker.profile && $0.name == marker.name) } + [marker])
    }

    func remove(profile: String, name: String) {
        let now = all()
        let next = now.filter { !($0.profile == profile && $0.name == name) }
        if next.count != now.count { write(next) }
    }

    /// [13-13] Sign Out / Remove Gateway: the account's markers go (they can hold a connector's header values).
    func removeAll() {
        SecItemDelete(query as CFDictionary)
    }
}

extension CapabilitiesStore {
    /// Puts back any connector of `profile` that a tool-list save removed and never re-added. Returns the names put
    /// back. Runs in the bot's serial queue, so it waits behind a save still in flight. Quiet: a failure keeps the
    /// marker for the next read.
    @discardableResult
    func recoverConnectors(_ profile: String, now: Date = Date()) async -> [String] {
        guard let vault = toolRuleVault, !readOnlyGateway else { return [] }
        guard await Self.hasMarkers(vault, profile) else { return [] }
        return (try? await serial(profile) { [self, client] in
            var back: [String] = []
            for marker in vault.all() where marker.profile == profile {
                if now.timeIntervalSince(marker.at) > KeychainToolRuleVault.keep { vault.remove(profile: profile, name: marker.name); continue }
                guard let present = try? await mcpEntry(marker.name, profile: profile) != nil else { continue }   // unread: try later
                if present { vault.remove(profile: profile, name: marker.name); continue }
                do {
                    _ = try await client.call("mcp.servers.add", ["profile": .string(profile), "name": .string(marker.name), "config": marker.entry],
                                              timeout: .seconds(30))
                    back.append(marker.name)
                    vault.remove(profile: profile, name: marker.name)
                } catch let error as RPCError where error.code == 4090 {
                    vault.remove(profile: profile, name: marker.name)   // it is there after all
                } catch {}
            }
            if !back.isEmpty { await reloadMcp() }
            return back
        }) ?? []
    }

    /// [perf] The Keychain read off the main thread: it runs on every Connectors read, and almost always finds nothing.
    @concurrent nonisolated static func hasMarkers(_ vault: any ToolRuleVault, _ profile: String) async -> Bool {
        vault.all().contains { $0.profile == profile }
    }
}
