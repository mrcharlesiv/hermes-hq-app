// How a saved gateway is named on this phone (spec 1x-settings §4.2): a name given here wins, else its computer's name
// when the address has one ("alexs-Mac-Studio.local" reads "Alex’s Mac Studio"), else the address. Ported from
// `S/connection-offline.ts` (friendlyHostName, gatewayFriendlyName, gatewayHost) and `S/gateway-accounts.tsx`
// (gatewayRows). Pure.

import Foundation

nonisolated enum GatewayNaming {
    static let unnamed = "Your Gateway"
    static let nousAccountName = "Nous account"
    /// [own-login] Signed in on the gateway's own sign-in page (self-hosted OIDC), not with Nous.
    static let ownLoginAccountName = "Single sign-on"

    private static let localSuffix = JSRegex(#"\.(?:local|lan|home|localdomain)$"#, "i")
    private static let ipv4 = JSRegex(#"^\d{1,3}(?:\.\d{1,3}){3}$"#)
    private static let ownerMac = JSRegex(#"^(.+?)s-(Mac|MacBook|iMac|Mac-mini|Mac-Studio|Mac-Pro)\b"#, "i")
    private static let dashes = JSRegex(#"-+"#)
    private static let localhost = JSRegex(#"^localhost$"#, "i")
    private static let macWords: [String: String] = ["mac": "Mac", "macbook": "MacBook", "imac": "iMac", "studio": "Studio",
                                                     "pro": "Pro", "air": "Air", "mini": "mini"]

    /// `friendlyHostName`: no local suffix, the first label of a dotted name, "<owner>s-Mac…" → "<owner>’s-Mac…", dashes
    /// as spaces.
    static func friendlyHostName(_ host: String) -> String {
        let name = localSuffix.replace(host.trimmingCharacters(in: .whitespacesAndNewlines), "")
        if name.isEmpty || ipv4.test(name) { return name }
        let short = name.contains(".") && !name.contains(where: \.isWhitespace) ? String(name.split(separator: ".", omittingEmptySubsequences: false)[0]) : name
        return dashes.replaceAll(ownerMac.replace(short, "$1’s-$2"), " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The host without port (brackets stripped), or with port ("host:port") — `new URL(url).hostname` / `.host`.
    static func host(_ url: URL?, port: Bool) -> String {
        guard let url, let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return "" }
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        guard port else { return bare }
        let shown = bare.contains(":") ? "[\(bare)]" : bare
        if let value = url.port, !isDefaultPort(value, scheme: url.scheme) { return "\(shown):\(value)" }
        return shown
    }

    private static func isDefaultPort(_ port: Int, scheme: String?) -> Bool {
        (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
    }

    /// [mac-audit] Owner 2026-11-02 (#22): this computer's own name ("alex’s Mac Studio"), set once at launch on
    /// the Mac. A gateway at a loopback address (127.0.0.1, localhost, ::1) runs on this computer, so that is its name;
    /// More's card read "127.0.0.1:9881". Nil on the iPhone, whose loopback is never a gateway.
    nonisolated(unsafe) static var thisComputer: String?

    /// 127.0.0.0/8, localhost, ::1.
    static func isLoopback(_ host: String) -> Bool {
        localhost.test(host) || host == "::1" || (ipv4.test(host) && host.hasPrefix("127."))
    }

    /// The gateway as people name it (without a label): its computer's name, else "Your Gateway". Never an address.
    static func friendlyName(_ url: URL?) -> String {
        let host = host(url, port: false)
        if let mine = thisComputer?.trimmingCharacters(in: .whitespacesAndNewlines), !mine.isEmpty, isLoopback(host) { return mine }
        if host.isEmpty || ipv4.test(host) || host.contains(":") || localhost.test(host) { return unnamed }
        let name = friendlyHostName(host).split(separator: " ", omittingEmptySubsequences: false)
            .map { macWords[$0.lowercased()] ?? String($0) }.joined(separator: " ")
        guard let first = name.first else { return unnamed }
        return first.uppercased() + name.dropFirst()
    }

    /// The account's name in a row: "Nous account" for Sign in with Nous, else the username.
    static func accountName(_ account: GatewayAccount) -> String {
        account.kind == .nous ? (account.usesOwnLogin ? ownLoginAccountName : nousAccountName) : (account.username ?? "")
    }

    /// `gatewayRows`: the row's title and subtitle. `label` is the name given on this phone (nil when none).
    static func row(url: URL, label: String?, accountName: String, hasSession: Bool) -> (title: String, subtitle: String) {
        let given = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let friendly = given.isEmpty ? friendlyName(url) : given
        var address = host(url, port: true)
        if address.isEmpty { address = url.absoluteString }
        let named = friendly != unnamed
        let subtitle = [named ? address : "", accountName, hasSession ? "" : "Signed Out"].filter { !$0.isEmpty }
            .joined(separator: " · ")
        return (named ? friendly : address, subtitle)
    }

    /// The title alone (menus, the Bots subtitle).
    static func title(url: URL, label: String?) -> String {
        row(url: url, label: label, accountName: "", hasSession: true).title
    }
}
