// [share] Whether a gateway may be contacted now (the tailnet rule), and what a transport failure says
// (docs/spec/3x-share.md §6.1, §7.8). Port of build 240's `HermesTransportPolicy` (HermesTransportShared.swift:166-262);
// the same rule as HermesKit's `GatewayAddress.tailnetOnly` / `tailscaleUp` (parity: Tests/Share/ShareReachTests.swift).

import Foundation
import Darwin

nonisolated enum ShareReach {
    struct Interface: Equatable, Sendable {
        let name: String
        let address: String
    }

    /// A plain-http gateway trusted as a Tailscale peer (a 100.64.0.0/10 or fd7a:115c:a1e0::/48 address, or a *.ts.net
    /// name) is reached through Tailscale or not at all: with Tailscale off its traffic would go to whoever answers
    /// that address on the current network.
    static func tailnetOnly(url raw: String) -> Bool {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "http",
              let host = url.host(percentEncoded: false)?.lowercased() else { return false }
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        return tailnetAddress(name) || name.hasSuffix(".ts.net")
    }

    /// Tailscale is up on this device: a tunnel (utun*) interface holds a tailnet address. A cellular interface's
    /// carrier-grade NAT address (pdp_ip*, also in 100.64.0.0/10) is not Tailscale.
    static func tailscaleUp(_ interfaces: [Interface]) -> Bool {
        interfaces.contains { $0.name.hasPrefix("utun") && tailnetAddress($0.address) }
    }

    /// Whether anything (a cookie, a token, a socket ticket) may be sent to this gateway now.
    static func reachable(url raw: String, interfaces: () -> [Interface] = systemInterfaces) -> Bool {
        !tailnetOnly(url: raw) || tailscaleUp(interfaces())
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
            found.append(Interface(name: String(cString: entry.pointee.ifa_name),
                                   address: String(text.split(separator: "%", maxSplits: 1).first ?? "")))
        }
        return found
    }

    /// Tailscale's own address ranges: 100.64.0.0/10 and fd7a:115c:a1e0::/48.
    static func tailnetAddress(_ raw: String) -> Bool {
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return UInt32(bigEndian: v4.s_addr) & 0xffc0_0000 == 0x6440_0000 }
        guard inet_pton(AF_INET6, host, &v6) == 1 else { return false }
        return withUnsafeBytes(of: &v6) { Array($0.prefix(6)) } == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
    }

    // MARK: Transport failures

    /// What a failed gateway call says. A timeout is a reached but busy gateway; only a host that can't be found or
    /// connected to, or a lost or absent network, gets the Tailscale/VPN advice. The number never goes in the sentence.
    static func failureMessage(domain: String, code: Int) -> String {
        guard domain == NSURLErrorDomain else { return "Your gateway couldn’t complete that request. Try again." }
        switch code {
        case -1001: return "Your gateway took too long to answer. It may be busy — try again."
        case -1003, -1004, -1005, -1009: return "Can’t reach the computer running Hermes. Check that you’re online and that Tailscale or your VPN is on, then try again."
        case -999: return "The connection changed before your gateway answered. Try again."
        case -1206 ... -1200: return "This device doesn’t trust your gateway’s HTTPS certificate."
        case -1022: return "This gateway address needs https://."
        case -1006, -1018, -1020: return "Can’t reach the computer running Hermes right now. Try again."   // UX study #24
        default: return "Your gateway couldn’t complete that request. Try again."
        }
    }

    /// The largest socket frame a share reads (a `session.resume` answer with `omit_messages` is small; events are not).
    static let maximumMessageSize = 16 * 1024 * 1024
}
