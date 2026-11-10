// [share] docs/spec/3x-share.md §7.5 check 1 and 6: which bots the sheet is told about, and what about each.

import Foundation
import Testing
@testable import HermesHQNative

nonisolated func shareTestBot(_ id: String, name: String? = nil, session: String? = "20260929_120000_aabbcc02", active: Double? = nil,
                              hidden: Bool = false, head: JSONValue? = nil, preview: String? = "a secret preview") -> Bot {
    Bot(id: id, name: name ?? id.capitalized, role: "role", preview: preview, lastActive: active.map { Date(timeIntervalSince1970: $0) },
        isWorking: false, unread: true, pinned: false, pinOrder: nil, sectionName: nil, hidden: hidden, canonicalSessionId: session, head: head)
}

@Suite struct ShareRosterRowsTests {
    @Test func whichBotsAndWhatAboutEach() {
        let bots = [
            shareTestBot("default", name: "Hermes", session: "20260929_120000_aabbcc01", active: 1_790_000_100),
            shareTestBot("ivy", name: "  Ivy  ", active: 1_790_000_200),
            shareTestBot("ghost", hidden: true),
            shareTestBot("fresh", session: nil),                         // no Bot Chat yet: kept, cannot receive
            shareTestBot("slashed", session: "a/b"),                     // an id that could never be a route: kept, cannot receive
            shareTestBot("bad profile", name: "Bad"),                    // a profile no route could carry
            shareTestBot("empty", name: "   "),
            shareTestBot("long", name: String(repeating: "n", count: 81)),
            shareTestBot("never", active: 0),
        ]
        let rows = ShareRosterRows.rows(bots)
        #expect(rows.map(\.profile) == ["default", "ivy", "fresh", "slashed", "long", "never"])          // the Bots list's own order
        #expect(rows.map(\.key) == ["ios-direct::default", "ios-direct::ivy", "ios-direct::fresh", "ios-direct::slashed", "ios-direct::long", "ios-direct::never"])
        #expect(rows[0].name == "Hermes" && rows[1].name == "Ivy")
        #expect(rows[0].session == "20260929_120000_aabbcc01" && rows[0].lastActive == 1_790_000_100)
        #expect(rows[2].session == "" && rows[3].session == "")
        #expect(rows[4].name.count == 80)
        #expect(rows[5].lastActive == nil)
        let shared = ShareRosterRows.bots(rows, account: ShareSamples.key)
        #expect(shared.map(\.canReceive) == [true, true, false, false, true, true])
        #expect(shared.allSatisfy { $0.color == "" && ShareRules.validAvatarName($0.avatar ?? "") })
    }

    @Test func atMostTwoHundred() {
        let bots = (1...250).map { shareTestBot(String(format: "load-%03d", $0)) }
        let rows = ShareRosterRows.rows(bots)
        #expect(rows.count == 200)
        #expect(rows.first?.profile == "load-001" && rows.last?.profile == "load-200")
        // Hidden ones do not use up the 200.
        let mixed = (1...250).map { shareTestBot(String(format: "load-%03d", $0), hidden: $0 <= 50) }
        #expect(ShareRosterRows.rows(mixed).count == 200)
        #expect(ShareRosterRows.rows(mixed).first?.profile == "load-051")
        #expect(ShareRosterRows.rows([]).isEmpty)
    }

    @Test func faceKeysAreStableAndChangeWithTheHead() {
        let robot: JSONValue = ["theme": "robot", "color": "#ff8800", "eyes": 2]
        let reordered: JSONValue = ["eyes": 2, "color": "#ff8800", "theme": "robot"]
        let other: JSONValue = ["theme": "robot", "color": "#0088ff", "eyes": 2]
        let key = ShareRosterRows.imageKey(head: robot, profile: "ivy")
        #expect(key.hasPrefix("head:") && key.count == 5 + 64)
        #expect(key == ShareRosterRows.imageKey(head: reordered, profile: "ivy"))                // sorted keys
        #expect(key == ShareRosterRows.imageKey(head: robot, profile: "another"))                // the head, not the bot
        #expect(key != ShareRosterRows.imageKey(head: other, profile: "ivy"))
        // A default head is the profile's own.
        #expect(ShareRosterRows.imageKey(head: nil, profile: "ivy") == ShareRosterRows.imageKey(head: .null, profile: "ivy"))
        #expect(ShareRosterRows.imageKey(head: nil, profile: "ivy") != ShareRosterRows.imageKey(head: nil, profile: "default"))
        // Stable across launches: a value worked out by hand, not `Hasher`'s.
        #expect(ShareRosterRows.imageKey(head: nil, profile: "ivy") == "head:f4a0aa3222ecba534590e3460c96c67a1feadef9e8a495d982c2b6d7e7a5cc28")     // SHA-256("default-matrix-4:ivy")
        // A dot-matrix record is drawn 20 LEDs across now: its pictures from builds 378 to 390 aren't reused.
        let matrix: JSONValue = ["theme": "matrix", "form": "leaf"]
        #expect(ShareRosterRows.imageKey(head: matrix, profile: "ivy") == "head:b91c58ccce83f48d2632c0021b7b6e9b4d20d5eef1c6d8b494a2e1c9ea95de83")     // SHA-256("matrix-4:" + its JSON)
        // A face file: 32 hex and .png; different for every account, bot and picture.
        let name = ShareRosterRows.avatarName(account: ShareSamples.key, profile: "ivy", imageKey: key)
        #expect(name.range(of: "^[a-f0-9]{32}\\.png$", options: .regularExpression) != nil)
        #expect(name == ShareRosterRows.avatarName(account: ShareSamples.key, profile: "ivy", imageKey: key))
        #expect(name != ShareRosterRows.avatarName(account: "http://other\nme", profile: "ivy", imageKey: key))
        #expect(name != ShareRosterRows.avatarName(account: ShareSamples.key, profile: "default", imageKey: key))
        #expect(name != ShareRosterRows.avatarName(account: ShareSamples.key, profile: "ivy", imageKey: key + "x"))
    }

    @Test func theRosterCarriesNoMessageNoPreviewNoSecret() throws {
        // §7.5 check 6, over the encoded JSON.
        let bots = [shareTestBot("ivy", active: 5, head: ["theme": "robot"], preview: "the launch code is 0000")]
        let roster = ShareRoster(account: ShareSamples.key, url: ShareSamples.url, username: ShareSamples.username, limitBytes: 33_554_432,
                                 bots: ShareRosterRows.bots(ShareRosterRows.rows(bots), account: ShareSamples.key), savedAt: 1)
        let json = try JSONEncoder().encode(roster)
        let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(Set(object.keys) == ["version", "account", "url", "username", "limitBytes", "bots", "savedAt"])
        let bot = try #require((object["bots"] as? [[String: Any]])?.first)
        #expect(Set(bot.keys).isSubset(of: ["key", "name", "profile", "session", "color", "avatar", "lastActive"]))
        let text = String(decoding: json, as: UTF8.self)
        for word in ["launch code", "preview", "role", "cookie", "token", "password", "theme", "robot"] { #expect(!text.contains(word), "\(word)") }
    }

    @Test func theGatewayNameIsOptionalOnDisk() throws {
        // A roster an older build wrote has no gateway name and still reads; one with several gateways saved keeps it.
        let old = #"{"version":1,"account":"a","url":"https://x","username":"u","limitBytes":1,"bots":[],"savedAt":1}"#
        #expect(try JSONDecoder().decode(ShareRoster.self, from: Data(old.utf8)).gateway == nil)
        let named = ShareRoster(account: "a", url: "https://x", username: "u", limitBytes: 1, bots: [], savedAt: 1, gateway: "Office Mac")
        #expect(try JSONDecoder().decode(ShareRoster.self, from: JSONEncoder().encode(named)).gateway == "Office Mac")
    }
}
