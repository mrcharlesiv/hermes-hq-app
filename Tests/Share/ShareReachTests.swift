// [share] docs/spec/3x-share.md §6.1: which gateways are reached through Tailscale or not at all, pinned to the app's
// own rule.

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct ShareReachTests {
    private let addresses = [
        "http://100.64.0.1:8642", "http://100.101.102.103:8642", "http://100.127.255.255", "http://100.128.0.1", "http://100.63.255.255",
        "http://[fd7a:115c:a1e0::1]:8642", "http://[fd7a:115c:a1e0:ab12::5]", "http://[fd7a:115c:a1e1::1]", "http://[::1]:9910",
        "http://studio.tail1234.ts.net:8642", "http://STUDIO.TAIL1234.TS.NET", "http://studio.tail1234.ts.net.", "http://ts.net", "http://nots.net",
        "https://100.64.0.1:8642", "https://studio.tail1234.ts.net", "http://127.0.0.1:9910", "http://192.168.1.4:8642", "http://hq.example",
        "http://10.0.0.1", "HTTP://100.64.0.1", "ftp://100.64.0.1", "http://100.64.0.1.example.com", "http://evil.example/?x=.ts.net",
    ]

    @Test func tailnetOnlyAddresses() {
        for raw in ["http://100.64.0.1:8642", "http://100.127.255.255", "http://[fd7a:115c:a1e0::1]:8642", "http://studio.tail1234.ts.net:8642",
                    "http://STUDIO.TAIL1234.TS.NET", "HTTP://100.64.0.1", "http://studio.tail1234.ts.net."] {
            #expect(ShareReach.tailnetOnly(url: raw), "\(raw)")
        }
        for raw in ["https://100.64.0.1:8642", "https://studio.tail1234.ts.net", "http://127.0.0.1:9910", "http://192.168.1.4:8642", "http://100.128.0.1",
                    "http://100.63.255.255", "http://[fd7a:115c:a1e1::1]", "http://nots.net", "http://100.64.0.1.example.com",
                    "http://evil.example/?x=.ts.net", "not a url", ""] {
            #expect(!ShareReach.tailnetOnly(url: raw), "\(raw)")
        }
    }

    @Test func tailnetOnlyMatchesTheApp() throws {
        #expect(addresses.count == 24)
        for raw in addresses {
            let url = try #require(URL(string: raw))
            #expect(ShareReach.tailnetOnly(url: raw) == GatewayAddress.tailnetOnly(url), "\(raw)")
        }
    }

    @Test func tunnelVersusCellular() {
        let sets: [[(String, String)]] = [
            [], [("en0", "192.168.1.20")], [("utun3", "100.101.102.103")], [("utun0", "fe80::1"), ("utun4", "fd7a:115c:a1e0::9")],
            [("pdp_ip0", "100.64.12.9")],                       // carrier-grade NAT on cellular is not Tailscale
            [("en0", "100.64.0.4")], [("utun2", "10.8.0.2")], [("utun9", "100.128.0.1")], [("pdp_ip0", "100.64.12.9"), ("utun1", "100.64.0.2")],
            [("ipsec0", "100.64.0.2")], [("utun5", "fd7a:115c:a1e1::9")],
        ]
        let expected = [false, false, true, true, false, false, false, false, true, false, false]
        for (set, up) in zip(sets, expected) {
            #expect(ShareReach.tailscaleUp(set.map { ShareReach.Interface(name: $0.0, address: $0.1) }) == up, "\(set)")
            #expect(GatewayAddress.tailscaleUp(set.map { GatewayAddress.Interface(name: $0.0, address: $0.1) }) == up, "\(set)")
        }
    }

    @Test func reachableAsksTheInterfacesOnlyForATailnetGateway() {
        var asked = 0
        let none: () -> [ShareReach.Interface] = { asked += 1; return [] }
        #expect(ShareReach.reachable(url: "http://127.0.0.1:9910", interfaces: none))
        #expect(ShareReach.reachable(url: "https://studio.tail1234.ts.net", interfaces: none))
        #expect(asked == 0)
        #expect(!ShareReach.reachable(url: "http://100.64.0.1:8642", interfaces: none))
        #expect(asked == 1)
        #expect(ShareReach.reachable(url: "http://100.64.0.1:8642", interfaces: { [ShareReach.Interface(name: "utun3", address: "100.64.0.9")] }))
        #expect(!ShareReach.reachable(url: "http://studio.tail1234.ts.net", interfaces: { [ShareReach.Interface(name: "pdp_ip0", address: "100.64.0.9")] }))
    }

    @Test func thisMachinesInterfacesAreRead() {
        let found = ShareReach.systemInterfaces()
        #expect(found.contains { $0.address == "127.0.0.1" || $0.address == "::1" })
        #expect(found.allSatisfy { !$0.name.isEmpty && !$0.address.contains("%") })
    }
}
