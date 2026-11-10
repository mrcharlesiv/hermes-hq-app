// Which hosts a URL found in a transcript may be fetched from (r1-10 in the reference app): a bot's reply can be written
// by a prompt injection, so an image it names comes only from the public internet over https, never the phone's LAN,
// the gateway's Tailscale network, loopback, or a name that resolves to one. Ported from the reference's
// `DispatchPlatformPolicy.publicHTTPS` / `publicAddress` / `resolvesPublic` (ios/App/App/HermesPlatformExtras.swift).

import Darwin
import Foundation

nonisolated enum PublicHostPolicy {
    /// A public https URL by its spelling: https, no user info, a dotted name that is not a local, Tailscale or
    /// reserved suffix, and (for a numeric host) a plain public dotted quad. Names still need `resolvesPublic`.
    static func publicHTTPS(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), host.contains("."), !host.contains(":") else { return false }
        if [".local", ".localhost", ".internal", ".home.arpa", ".ts.net"].contains(where: host.hasSuffix) { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        // A numeric last label is an address, never a name (127.1, 0x7f.1, 10.0.1): only a plain dotted quad is read.
        guard let last = labels.last, last.range(of: "^(0x[0-9a-f]*|[0-9]+)$", options: .regularExpression) != nil else { return true }
        let octets = labels.compactMap { $0.count <= 3 && !($0.count > 1 && $0.hasPrefix("0")) ? UInt8($0) : nil }
        return labels.count == 4 && octets.count == 4 && publicAddress(octets)
    }

    /// A globally routable address (4 or 16 bytes): never loopback, private, CGNAT/Tailscale, link-local, ULA,
    /// multicast, documentation or reserved space. IPv4-mapped, NAT64 and 6to4 addresses are judged by their IPv4.
    static func publicAddress(_ bytes: [UInt8]) -> Bool {
        if bytes.count == 4 {
            let (a, b, c) = (bytes[0], bytes[1], bytes[2])
            return !(a == 0 || a == 10 || a == 127 || a >= 224 || (a == 100 && (64...127).contains(b)) || (a == 169 && b == 254)
                     || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 192 && b == 0 && (c == 0 || c == 2))
                     || (a == 198 && (18...19).contains(b)) || (a == 198 && b == 51 && c == 100) || (a == 203 && b == 0 && c == 113))
        }
        guard bytes.count == 16 else { return false }
        let v4 = Array(bytes[12...])
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && (bytes[10..<12] == [0xff, 0xff] || bytes[10..<12] == [0, 0]) {
            return (bytes[10] == 0xff || v4[0] != 0) && publicAddress(v4)  // ::ffff:a.b.c.d and ::a.b.c.d; :: and ::1 aren't
        }
        if bytes[0..<12] == [0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0] { return publicAddress(v4) }  // NAT64
        if bytes[0] == 0x20 && bytes[1] == 0x02 { return publicAddress(Array(bytes[2..<6])) }  // 6to4
        let (x, y) = (bytes[0], bytes[1])
        return !((x & 0xfe) == 0xfc || (x == 0xfe && (y & 0x80) == 0x80) || x == 0xff
                 || (x == 0x20 && y == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8)
                 || (x == 0x01 && y == 0 && bytes[2..<8].allSatisfy { $0 == 0 }))
    }

    /// A public https URL whose host resolves, on this phone, only to public addresses (a LAN or split-horizon name is
    /// never fetched).
    static func allowed(_ url: URL?, hosts: PublicHosts = .shared) async -> Bool {
        guard publicHTTPS(url), let host = url?.host else { return false }
        return await resolvesPublic(host, hosts: hosts)
    }

    /// Every address the name resolves to is public. getaddrinfo blocks its thread for as long as the resolver does,
    /// so lookups run on a few threads of their own, one per host at a time whoever asks; a verdict is kept for a
    /// minute (a failed lookup for ten seconds), and a caller gives up after `timeout` (the answer is then no).
    static func resolvesPublic(_ host: String, timeout: TimeInterval = 5, hosts: PublicHosts = .shared) async -> Bool {
        let once = PagesOnce()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: false) }
            }
            hosts.check(host) { verdict in if once.claim() { continuation.resume(returning: verdict) } }
        }
    }

    /// Host lookups with a small verdict cache (`resolve` is swappable for tests).
    final class PublicHosts: @unchecked Sendable {
        static let shared = PublicHosts()
        private let lock = NSLock()
        private var verdicts: [String: (public: Bool, until: Date)] = [:]
        private var waiting: [String: [(Bool) -> Void]] = [:]
        private let queue: OperationQueue = {
            let queue = OperationQueue()
            queue.name = "hermeshq.public-hosts"
            queue.maxConcurrentOperationCount = 3
            queue.qualityOfService = .utility
            return queue
        }()
        let resolve: @Sendable (String) -> [[UInt8]]

        init(resolve: @escaping @Sendable (String) -> [[UInt8]] = PublicHosts.lookup) { self.resolve = resolve }

        func check(_ host: String, _ answer: @escaping (Bool) -> Void) {
            let key = host.lowercased()
            lock.lock()
            if let known = verdicts[key], known.until > Date() { lock.unlock(); return answer(known.public) }
            let first = waiting[key] == nil
            waiting[key, default: []].append(answer)
            lock.unlock()
            guard first else { return }
            let resolve = self.resolve
            queue.addOperation { [self] in
                let addresses = resolve(host)
                let verdict = !addresses.isEmpty && addresses.allSatisfy(PublicHostPolicy.publicAddress)
                lock.lock()
                verdicts[key] = (verdict, Date().addingTimeInterval(addresses.isEmpty ? 10 : 60))
                if verdicts.count > 256 { verdicts = verdicts.filter { $0.value.until > Date() } }
                let answers = waiting.removeValue(forKey: key) ?? []
                lock.unlock()
                answers.forEach { $0(verdict) }
            }
        }

        static func lookup(_ host: String) -> [[UInt8]] {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var list: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, "443", &hints, &list) == 0, let list else { return [] }
            defer { freeaddrinfo(list) }
            var addresses: [[UInt8]] = []
            for info in sequence(first: list, next: { $0.pointee.ai_next }) {
                guard let address = info.pointee.ai_addr else { continue }
                if info.pointee.ai_family == AF_INET {
                    addresses.append(address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } })
                } else if info.pointee.ai_family == AF_INET6 {
                    addresses.append(address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } })
                }
            }
            return addresses
        }
    }
}

/// A one-shot claim (the first caller wins), thread-safe.
nonisolated final class PagesOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
