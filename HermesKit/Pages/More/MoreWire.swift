// Shared by the More pages (docs/spec/3x-morepages.md §0.4, §19): the profile scope on REST and JSON-RPC, "this route
// is not on this gateway", and the per-account memory of rows a gateway lacks (D-M16).

import Foundation

nonisolated enum MoreWire {
    /// REST profile scope: the query item `profile=<id>`, left out for the default bot (`V/api/client.ts:49-80`).
    static func profileQuery(_ profile: String?) -> [URLQueryItem] {
        guard let profile, !profile.isEmpty, profile != "default" else { return [] }
        return [URLQueryItem(name: "profile", value: profile)]
    }

    /// JSON-RPC `ProfileParams`: `{"profile": id}` for a named bot, nothing for the default one. Hermes answers error
    /// 4000 for a key it does not know, so callers add only the keys their method lists.
    static func profileParams(_ profile: String?, _ more: [String: JSONValue] = [:]) -> JSONValue {
        var out = more
        if let profile, !profile.isEmpty, profile != "default" { out["profile"] = .string(profile) }
        return .object(out)
    }

    /// The gateway has no such route or method (an older Hermes): HTTP 404 / 405, or JSON-RPC -32601.
    static func isMissingRoute(_ error: Error) -> Bool {
        if let http = error as? HTTPError { return http.status == 404 || http.status == 405 }
        if let rpc = error as? RPCError { return rpc.code == -32601 }
        return false
    }

    /// [mac-audit] Owner 2026-11-02 (#21): what a page itself shows as "Not Available on This Hermes": a missing route,
    /// or an empty answer (`{}`, `[]`, nothing), as a Hermes without the route may send (`PagesREST.unreadable`). The
    /// More rows' probes counted only the first, so Messaging, Star Map and Webhooks were listed as working on a gateway
    /// whose pages said they weren't there.
    static func isNotAvailable(_ error: Error) -> Bool {
        isMissingRoute(error) || (error as? PagesMessageError)?.message == olderHermes
    }

    /// An answer with nothing in it: no bytes, or JSON `{}`, `[]` or `null`.
    static func isEmptyAnswer(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        guard let value = try? JSONValue.parse(data) else { return false }
        switch value {
        case .null: return true
        case .object(let fields): return fields.isEmpty
        case .array(let rows): return rows.isEmpty
        default: return false
        }
    }

    /// A page or action the connected Hermes doesn't have (a 404 for the route, or an empty answer): not a failure, so
    /// it never says "couldn't" (Mac UX stress test #10).
    static let olderHermes = "Not available on this Hermes. Updating Hermes may add it."
    /// The title over `olderHermes` where a page would otherwise say "Couldn't Load …".
    static let notAvailableTitle = "Not Available on This Hermes"

    /// [mac] Stress test 2026-10-28 #10: the line under `notAvailableTitle` on a page's own state. It names the page so it
    /// doesn't repeat the title ("This Hermes doesn't have Messaging. Updating Hermes may add it.").
    static func notAvailableBody(_ page: String?) -> String {
        guard let page, !page.isEmpty else { return olderHermes }
        return "This Hermes doesn’t have \(page). Updating Hermes may add it."
    }

    /// The page a "Couldn't Load <Page>" title names, for `notAvailableBody` ("Couldn't Load Star Map" → "Star Map").
    static func pageName(fromFailureTitle title: String) -> String? {
        for prefix in ["Couldn’t Load the ", "Couldn’t Load ", "Couldn't Load the ", "Couldn't Load "] where title.hasPrefix(prefix) {
            let rest = String(title.dropFirst(prefix.count))
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    /// `title`, or `notAvailableTitle` when `reason` is the not-available words.
    static func failureTitle(_ title: String, reason: String) -> String { reason == olderHermes ? notAvailableTitle : title }
}

/// Rows of More a gateway answered 404 / -32601 for, per account (`pages.more.unavailable.<account>`). A hidden row is
/// probed again on every `gateway.ready` and comes back when its route answers.
nonisolated enum MoreAvailability {
    static func key(_ account: GatewayAccount) -> String { "pages.more.unavailable.\(account.id)" }

    static func unavailable(_ account: GatewayAccount, defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: key(account)) ?? [])
    }

    /// Returns true when the set changed.
    @discardableResult
    static func set(_ row: String, available: Bool, account: GatewayAccount, defaults: UserDefaults = .standard) -> Bool {
        var rows = unavailable(account, defaults: defaults)
        let changed = available ? rows.remove(row) != nil : rows.insert(row).inserted
        if changed { defaults.set(rows.sorted(), forKey: key(account)) }
        return changed
    }

    static func forget(_ account: GatewayAccount, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(account))
    }
}
