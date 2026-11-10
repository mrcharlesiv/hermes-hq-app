// The Share extension's content-free note of each Nous rotation, read by the app at its next refresh
// (ShareKit/ShareAuthTrail.swift).

import Foundation
import Testing
@testable import HermesHQNative

struct ShareAuthTrailTests {
    @Test func linesAreKeptInOrderAndDrainedOnce() throws {
        let suite = "hq.tests.share-auth-trail.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let at = Date(timeIntervalSince1970: 1_792_811_284)   // 2026-10-24 03:08:04 UTC
        ShareAuthTrail.record("rotated the pair", at: at, defaults: defaults)
        ShareAuthTrail.record("had its pair refused (401)", at: at, defaults: defaults)
        #expect(ShareAuthTrail.drain(defaults: defaults) == ["rotated the pair at 2026-10-24 03:08:04 UTC",
                                                             "had its pair refused (401) at 2026-10-24 03:08:04 UTC"])
        #expect(ShareAuthTrail.drain(defaults: defaults).isEmpty)
        for i in 0..<30 { ShareAuthTrail.record("rotated \(i)", at: at, defaults: defaults) }
        let kept = ShareAuthTrail.drain(defaults: defaults)
        #expect(kept.count == ShareAuthTrail.keep && kept.first?.hasPrefix("rotated 10 ") == true)
    }
}
