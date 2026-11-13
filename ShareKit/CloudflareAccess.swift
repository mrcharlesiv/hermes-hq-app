// [cf-access] A Cloudflare Access service token for one saved gateway (public issue #37). A Hermes published through
// a Cloudflare Tunnel with an Access policy in front answers only requests that carry the token's two headers; with
// them the app reaches it without Tailscale or a VPN. The pair is saved with the gateway in the sign-in's Keychain
// item (`StoredAccount.access`), outlives an ended session, and goes with the gateway when it is removed. It is sent
// to the gateway's own address only: on every request of its URLSessions (REST, uploads, downloads, sockets), by the
// app and the Share extension. Compiled into both.

import Foundation

nonisolated struct CloudflareAccess: Codable, Sendable, Hashable {
    var clientId: String
    var clientSecret: String

    static let idHeader = "CF-Access-Client-Id", secretHeader = "CF-Access-Client-Secret"

    /// The typed pair, trimmed; nil unless both are there (half a token opens nothing).
    init?(clientId: String?, clientSecret: String?) {
        let id = (clientId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = (clientSecret ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty else { return nil }
        self.clientId = id
        self.clientSecret = secret
    }

    /// The two headers Access reads on a request.
    var headers: [String: String] { [Self.idHeader: clientId, Self.secretHeader: clientSecret] }

    /// The pair in one saved account's Keychain entry (`{"access": {"clientId": …, "clientSecret": …}}`), as the Share
    /// extension reads it.
    init?(entry: [String: Any]) {
        guard let saved = entry["access"] as? [String: Any] else { return nil }
        self.init(clientId: saved["clientId"] as? String, clientSecret: saved["clientSecret"] as? String)
    }

    /// Whether an answer is Cloudflare Access asking for a sign-in: its redirect to the team's login page (never
    /// followed here), which is what a request without a token gets.
    static func asksForSignIn(status: Int, location: String?) -> Bool {
        guard (300..<400).contains(status), let location = location?.lowercased() else { return false }
        return location.contains(".cloudflareaccess.com/") || location.contains("/cdn-cgi/access/")
    }
}
