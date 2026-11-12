// Gateway addresses: typed-text normalisation, validation, request URLs and the transport policy every request obeys
// (spec 01 §2.2, §2.5). Pure functions, usable from any context.

import Foundation
import Darwin

nonisolated enum GatewayAddress {
    // MARK: Typed text → address

    /// What the address field holds → a full address (spec 01 §2.2, renderer side): trimmed; a typed scheme is
    /// lowercased; with no scheme, `http://` for a local or Tailscale host, else `https://`.
    static func normalizeTyped(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return value }
        if let range = value.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) {
            return value[range].lowercased() + value[range.upperBound...]
        }
        let host: String
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            host = String(value[...close])
        } else {
            host = String(value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        }
        let bare = host.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? host
        return (cleartextAllowed(host: bare) ? "http://" : "https://") + value
    }

    /// Whether text looks like `host.tld` (the probe is skipped before that, spec 01 §4.1).
    static func looksProbeable(_ raw: String) -> Bool {
        raw.range(of: #"^(https?://)?[^\s/]+\.[^\s/]+"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Native validation applied to every sign-in and probe (spec 01 §2.2, `HermesNative.validated`): parses; no
    /// userinfo, query or fragment; non-empty host; http or https; http only for hosts the user controls. Returns the
    /// address as stored: lowercase scheme and host, no trailing `/`.
    static func validated(_ raw: String) throws(GatewayFailure) -> URL {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let host = url.host(percentEncoded: false), !host.isEmpty,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              text.lowercased().hasPrefix(scheme + "://") else { throw .invalidURL }
        guard scheme == "https" || cleartextAllowed(host: host) else { throw .insecureURL }
        // scheme://authority[/path] with the scheme and authority lowercased; trailing slashes trimmed.
        let rest = text.dropFirst(scheme.count + 3)
        let authorityEnd = rest.firstIndex(of: "/") ?? rest.endIndex
        var stored = scheme + "://" + rest[..<authorityEnd].lowercased() + rest[authorityEnd...]
        while stored.hasSuffix("/") { stored.removeLast() }
        guard let normalized = URL(string: stored), normalized.host(percentEncoded: false)?.isEmpty == false else { throw .invalidURL }
        return normalized
    }

    /// The account key the Keychain list uses (spec 01 §2.1): `scheme://host[:port][path]` lowercased scheme and host,
    /// trailing `/` removed, then a newline, then the username.
    static func accountKey(url: String, username: String) -> String {
        var normalized = url
        if var parts = URLComponents(string: url) {
            parts.scheme = parts.scheme?.lowercased()
            if let host = parts.percentEncodedHost { parts.percentEncodedHost = host.lowercased() }
            normalized = parts.string ?? url
        }
        while normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized + "\n" + username
    }

    // MARK: Request URLs

    /// `base + path` under the gateway's own host, port and path prefix (spec 01 §2.2 `endpoint`). `path` may carry its
    /// own query; `query` items are appended after it (a literal `+` is sent as `%2B`, the gateway reads `+` as space).
    static func endpoint(base: URL, path: String, query: [URLQueryItem] = []) throws(GatewayFailure) -> URL {
        // Scalars, not Characters: "\r\n" is one Character and would slip past a Character search.
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              !path.unicodeScalars.contains(where: { $0 == "\\" || $0 == "\r" || $0 == "\n" || $0.value < 0x20 }),
              let url = URL(string: base.absoluteString + path),
              url.host(percentEncoded: false) == base.host(percentEncoded: false), url.port == base.port,
              url.user == nil, url.password == nil else { throw .invalidDestination }
        let basePath = base.path(percentEncoded: false)
        let prefix = (basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath) + "/"
        guard url.standardized.path(percentEncoded: false).hasPrefix(prefix) else { throw .invalidDestination }
        guard !query.isEmpty else { return url }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw .invalidDestination }
        parts.queryItems = (parts.queryItems ?? []) + query
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let full = parts.url else { throw .invalidDestination }
        return full
    }

    /// `ws(s)://…/api/ws?profile=<p>&ticket=<t>` (spec 01 §10.1): wss iff the base is https; ticket last.
    static func socketURL(base: URL, profile: String, ticket: String) throws(GatewayFailure) -> URL {
        let http = try endpoint(base: base, path: "/api/ws")
        guard var parts = URLComponents(url: http, resolvingAgainstBaseURL: false) else { throw .invalidDestination }
        parts.scheme = base.scheme?.lowercased() == "https" ? "wss" : "ws"
        parts.queryItems = [URLQueryItem(name: "profile", value: profile), URLQueryItem(name: "ticket", value: ticket)]
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url else { throw .invalidDestination }
        return url
    }

    // MARK: Transport policy (HermesTransportShared.swift)

    /// Plain http:// only on networks the user controls: loopback, RFC 1918, link-local, Tailscale (100.64/10,
    /// fd7a:115c:a1e0::/48, *.ts.net), unique-local IPv6, .local, single-label and private-use names. A WireGuard or
    /// other VPN's 10.x / 172.16–31.x / 192.168.x / fd… addresses are RFC 1918 or unique-local, so they are in.
    static func cleartextAllowed(host raw: String) -> Bool {
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        guard !host.isEmpty else { return false }
        if host.contains(":") {
            if host == "::1" { return true }
            let head = host.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            guard let first = UInt16(head.isEmpty ? "0" : head, radix: 16) else { return false }
            return first & 0xffc0 == 0xfe80 || first & 0xfe00 == 0xfc00
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4, octets.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            let n = octets.compactMap { UInt8($0) }
            guard n.count == 4 else { return false }
            return n[0] == 127 || n[0] == 10 || (n[0] == 172 && n[1] & 0xf0 == 16) || (n[0] == 192 && n[1] == 168)
                || (n[0] == 169 && n[1] == 254) || (n[0] == 100 && n[1] & 0xc0 == 64)
        }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) { return false }
        return host == "localhost" || !host.contains(".") || host.hasSuffix(".local") || host.hasSuffix(".ts.net")
            || privateNameSuffixes.contains(where: host.hasSuffix)
    }

    /// [own-vpn] Names that exist only on a network someone runs themselves (a home router's or a WireGuard VPN's own
    /// DNS; tester Papy 2026-11-12, "old school WireGuard user"): `.home.arpa` (RFC 8375) and `.internal` are reserved
    /// for private use, and `.lan` is what home routers hand out and is not a public domain. None resolves on the
    /// internet, so plain http:// to one stays on that network, as with `.local`.
    static let privateNameSuffixes = [".home.arpa", ".internal", ".lan"]

    /// A plain-http gateway reached only through Tailscale (a tailnet address or a *.ts.net name, spec 01 §2.5).
    static func tailnetOnly(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "http" && throughTailscale(url)
    }

    /// A gateway this phone reaches through Tailscale, over http or https: a tailnet address or a *.ts.net name.
    /// Sign in with Nous and public addresses are not, so their words never send people looking for Tailscale.
    static func throughTailscale(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return false }
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        return tailnetAddress(name) || name.hasSuffix(".ts.net")
    }

    struct Interface: Equatable, Sendable { let name: String; let address: String }

    /// Tailscale is up: a tunnel (utun*) interface holds a tailnet address. Cellular CGNAT (pdp_ip*) does not count.
    static func tailscaleUp(_ interfaces: [Interface]) -> Bool {
        interfaces.contains { $0.name.hasPrefix("utun") && tailnetAddress($0.address) }
    }

    /// Whether anything (a cookie, a password, a ticket) may be sent to this gateway now.
    static func reachable(_ url: URL, interfaces: () -> [Interface] = systemInterfaces) -> Bool {
        !tailnetOnly(url) || tailscaleUp(interfaces())
    }

    /// The addresses of every interface that is up (numeric, no zone).
    static func systemInterfaces() -> [Interface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(first) }
        var found: [Interface] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)),
                  Int32(entry.pointee.ifa_flags) & IFF_UP != 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            found.append(Interface(name: String(cString: entry.pointee.ifa_name), address: String(text.split(separator: "%", maxSplits: 1).first ?? "")))
        }
        return found
    }

    /// Loopback: 127.0.0.0/8 and ::1.
    static func loopbackAddress(_ raw: String) -> Bool {
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return UInt32(bigEndian: v4.s_addr) >> 24 == 127 }
        guard inet_pton(AF_INET6, host, &v6) == 1 else { return false }
        return withUnsafeBytes(of: &v6) { Array($0) } == [UInt8](repeating: 0, count: 15) + [1]
    }

    /// Tailscale's own ranges: 100.64.0.0/10 and fd7a:115c:a1e0::/48.
    static func tailnetAddress(_ raw: String) -> Bool {
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return UInt32(bigEndian: v4.s_addr) & 0xffc0_0000 == 0x6440_0000 }
        guard inet_pton(AF_INET6, host, &v6) == 1 else { return false }
        return withUnsafeBytes(of: &v6) { Array($0.prefix(6)) } == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
    }

    // MARK: Request classes (HermesTransportPolicy)

    /// Sign-in, session checks, renewals, the socket ticket and sign-out ride their own pool (spec 01 §8.2).
    static func isControlPath(_ path: String) -> Bool {
        let route = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return route.hasPrefix("/api/auth/") || route.hasPrefix("/auth/")
    }

    /// Body ceiling: 1 MiB for auth routes and the ticket, 32 MiB otherwise (spec 01 §8.2).
    static func responseLimit(path: String) -> Int {
        if path.hasPrefix("/api/auth/") || path.hasPrefix("/auth/") || path.contains("ws-ticket") { return 1 << 20 }
        return 32 << 20
    }
}
