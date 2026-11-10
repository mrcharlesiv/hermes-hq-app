// One managed app as the pages show it: the catalog row, the gateway's list row, the account and the member's rules
// joined (`joinHostedConnectors`, join.ts) and turned into a state, its words and the one thing to do next
// (`hostedWay`, derive.ts).

import Foundation

nonisolated enum ManagedState: String, Sendable {
    case available, broken, connected, connecting, expired, off, unknown
}

nonisolated enum ManagedVerb: String, Sendable {
    case connect, reconnect, tryAgain, stopWaiting, turnBackOn

    var title: String {
        switch self {
        case .connect: "Connect"
        case .reconnect: "Reconnect"
        case .tryAgain: "Try Again"
        case .stopWaiting: "Stop Waiting"
        case .turnBackOn: "Turn Back On"
        }
    }
}

nonisolated enum ManagedOffBy: Sendable { case me, org }

nonisolated struct ManagedApp: Sendable, Equatable, Identifiable {
    var slug: String
    var name: String
    var description: String
    var category: String
    var logoURL: String?
    var inCatalog: Bool
    var connected: Bool
    var connectionStatus: String?
    var statusReason: String?
    var accountLabel: String?
    var connectedAt: String?
    var disabledTools: [String]
    var enabled: Bool
    var orgLocked: Bool
    /// Every live account of this app, active first, then newest (`accountsFor`); retired ones apart (`retiredAccountsFor`).
    var accounts: [ConnectorAccountRow] = []
    var retired: [ConnectorAccountRow] = []
    var id: String { slug }

    var offBy: ManagedOffBy? { orgLocked ? .org : (!enabled ? .me : nil) }

    var state: ManagedState {
        if orgLocked || !enabled { return .off }
        guard connected else { return .available }
        switch connectionStatus ?? "active" {
        case "active": return .connected
        case "pending": return .connecting
        case "failed": return .broken
        case "expired", "inactive", "revoked": return .expired
        default: return .unknown
        }
    }

    var verb: ManagedVerb? {
        if orgLocked { return nil }
        if !enabled { return .turnBackOn }
        switch state {
        case .available: return .connect
        case .connecting: return .stopWaiting
        case .broken: return .tryAgain
        case .expired: return .reconnect
        default: return nil
        }
    }

    /// The badge words (`connectorsPage.card.state`).
    var stateWord: String {
        if orgLocked { return "Off by your organisation" }
        switch state {
        case .available: return "Available"
        case .broken: return "Couldn’t connect"
        case .connected: return disabledTools.isEmpty ? "Connected" : "Connected · \(disabledTools.count) tool\(disabledTools.count == 1 ? "" : "s") off"
        case .connecting: return "Connecting"
        case .expired: return "Access expired"
        case .off: return "Off for you"
        case .unknown: return "State unknown"
        }
    }

    /// The line under the state, when there is something to say.
    var reason: String? {
        switch state {
        case .connecting: return "Finish the sign-in in your browser."
        case .broken, .expired: return statusReason ?? "Reconnect to keep this app working."
        default: return nil
        }
    }

    /// Needs the person (shown first among the connected apps, red or orange).
    var needsAttention: Bool { state == .broken || state == .expired }
    /// Rules (the access switch, the tool list) apply once there is an account (`RULEABLE`).
    var ruleable: Bool { connected && state != .available && state != .connecting }
    /// Listed with the person's apps rather than the catalog's.
    var isMine: Bool { connected || !enabled }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return [name, slug, description, category].contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

nonisolated enum ManagedJoin {
    /// The newest active account for an app, else the newest at all (`pickAccount`). Never a retired one.
    static func account(_ accounts: [ConnectorAccountRow], _ slug: String) -> ConnectorAccountRow? {
        pick(accounts.filter { $0.connector == slug })
    }

    /// `account(_:_:)` over one app's accounts, already picked out.
    static func pick(_ accounts: [ConnectorAccountRow]) -> ConnectorAccountRow? { ordered(accounts).first }

    /// One app's live accounts, active first, then newest (`accountsFor`).
    static func ordered(_ accounts: [ConnectorAccountRow]) -> [ConnectorAccountRow] {
        accounts.filter { !$0.disabled }.sorted { a, b in
            a.active != b.active ? a.active : a.createdAt > b.createdAt
        }
    }

    static func apps(catalog: [ConnectorCatalogRow], list: [ConnectorListRow], accounts: [ConnectorAccountRow], policy: ConnectorPolicyView,
                     rulesReadable: Bool, abandoned: Set<String> = []) -> [ManagedApp] {
        // [perf] Looked up by slug, not searched per app: the join is linear in the catalog, not quadratic. The first
        // row of a slug wins, as `first` did.
        let catalogBySlug = Dictionary(catalog.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        let listBySlug = Dictionary(list.map { ($0.connector, $0) }, uniquingKeysWith: { first, _ in first })
        let accountsBySlug = Dictionary(grouping: accounts, by: \.connector)
        var slugs = catalog.map(\.slug)
        var seen = Set(slugs)
        for row in list where seen.insert(row.connector).inserted { slugs.append(row.connector) }
        return slugs.map { slug in
            let entry = catalogBySlug[slug]
            let row = listBySlug[slug]
            let mine = ordered(accountsBySlug[slug] ?? [])
            let account = mine.first
            let off = rulesReadable ? policy.memberDisabledTools(slug) : (row?.gatewayDisabledTools ?? [])
            var app = ManagedApp(slug: slug, name: entry?.name ?? ManagedWire.title(slug), description: entry?.description ?? "",
                                 category: entry?.category ?? "", logoURL: entry?.logoURL, inCatalog: entry != nil,
                                 connected: account != nil || row?.connected == true,
                                 connectionStatus: account?.status ?? row?.connectionStatus, statusReason: account?.statusReason ?? row?.statusReason,
                                 accountLabel: account?.label, connectedAt: account?.createdAt, disabledTools: off,
                                 enabled: policy.memberEnables(slug) && row?.enabled != false, orgLocked: policy.orgLocks(slug),
                                 accounts: mine, retired: (accountsBySlug[slug] ?? []).filter(\.disabled))
            // `forgetAbandoned`: a sign-in the person stopped waiting for reads as never started.
            if abandoned.contains(slug), app.connectionStatus == "pending" {
                app.connected = false; app.connectionStatus = nil; app.accountLabel = nil; app.connectedAt = nil
                app.accounts.removeAll { $0.status == "pending" }
            }
            return app
        }
    }

    /// The person's apps: broken first ("Broken connections first."), then by name.
    static func mine(_ apps: [ManagedApp]) -> [ManagedApp] {
        apps.filter(\.isMine).sorted { a, b in
            a.needsAttention != b.needsAttention ? a.needsAttention : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Catalog categories, most apps first, then A–Z.
    static func categories(_ apps: [ManagedApp]) -> [String] {
        var counts: [String: Int] = [:]
        for app in apps where !app.category.isEmpty { counts[app.category, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }
}

/// The tool list's words: facets and the save summary (`connectorsPage.vocabulary`, `tools`).
nonisolated enum ManagedToolWords {
    static func facet(_ facet: String) -> String {
        switch facet {
        case "read": "Read"
        case "write": "Write"
        case "destructive": "Destructive"
        default: "Unknown effect"
        }
    }

    static func facetLong(_ facet: String) -> String {
        switch facet {
        case "read": "Reads data out of this app. It changes nothing."
        case "write": "Creates or changes something in this app."
        case "destructive": "Can remove something in this app for good."
        default: "The app never said what this tool does."
        }
    }

    /// "2 tools off, 1 back on" (`footerDirty`).
    static func draft(off: Int, backOn: Int) -> String {
        "\(off) tool\(off == 1 ? "" : "s") off, \(backOn == 0 ? "none" : "\(backOn)") back on"
    }

    /// The conflict notice's second line (`conflictBody`).
    static func conflict(theyOff: Int, theyOn: Int) -> String {
        var they: [String] = []
        if theyOff > 0 { they.append("turned off \(theyOff) tool\(theyOff == 1 ? "" : "s") you have on") }
        if theyOn > 0 { they.append("left \(theyOn) tool\(theyOn == 1 ? "" : "s") on that you turned off") }
        return (they.isEmpty ? "" : "They \(they.joined(separator: ", and ")). ") + "Your edits stay on screen; nothing was written."
    }
}
