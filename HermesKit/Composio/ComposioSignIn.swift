// Connect Apps: apps the owner can't connect (docs/spec/3x-capabilities.md §10.13). Some apps sign in only by OAuth
// and Composio provides no OAuth app for them (Twitter/X, Shopify, Xero…): making a Connect Link fails with "Composio
// does not manage auth for toolkit …". Those are left out of the lists unless the owner made their own auth config
// for the app (or it is connected already). Apps whose sign-in asks for a key or token on Composio's page still show.

import Foundation

nonisolated enum ComposioSignIn {
    /// The schemes that need an OAuth app of someone's; every other scheme (API_KEY, BEARER_TOKEN, BASIC…) is filled
    /// in by the owner on Composio's own connect page.
    static let oauthSchemes: Set<String> = ["OAUTH1", "OAUTH2"]

    /// A catalog row (`GET /api/v3/toolkits`: `auth_schemes`, `composio_managed_auth_schemes`, `no_auth`) for an app
    /// that signs in only by OAuth that Composio doesn't provide. Unknown schemes (an empty list) count as fine.
    static func needsOwnApp(_ row: JSONValue) -> Bool {
        if row["no_auth"]?.bool == true || row["is_no_auth"]?.bool == true { return false }
        let managed = (row["composio_managed_auth_schemes"]?.array ?? []).compactMap(\.string)
        guard managed.isEmpty else { return false }
        let schemes = (row["auth_schemes"]?.array ?? []).compactMap { $0.string?.uppercased() }
        return !schemes.isEmpty && schemes.allSatisfy { oauthSchemes.contains($0) }
    }

    /// Whether the lists leave this app out: it needs an OAuth app of the owner's (`needsOwnApp`), they made none
    /// (`configured`), and it isn't connected, no-auth, or given a managed sign-in by its own row.
    static func hidden(_ toolkit: ComposioToolkit, needsOwnApp: Set<String>, configured: Set<String>) -> Bool {
        let slug = toolkit.slug.lowercased()
        guard needsOwnApp.contains(slug), !configured.contains(slug) else { return false }
        return !toolkit.noAuth && !toolkit.connected && toolkit.account == nil && toolkit.managedSchemes.isEmpty
    }

    /// Composio's own words when a link fails for such an app ("Composio does not manage auth for toolkit twitter and
    /// no auth config … is available…").
    static func isOwnAppRefusal(_ error: ComposioError) -> Bool {
        error.message.lowercased().contains("does not manage auth")
    }

    static let dashboard = URL(string: "https://platform.composio.dev")!

    /// The plain words for that refusal.
    static func ownAppMessage(_ name: String) -> String {
        "Composio doesn’t provide a sign-in for \(name). To connect it, add your own \(name) developer app as an auth config in your Composio dashboard, then try again."
    }
}
