import Foundation
import Testing
@testable import HermesHQNative

/// Decoding real captured payloads (Tests/Fixtures) and the spec's real-gateway shape.
@Suite struct RosterDecodeTests {
    @Test func demoRosterDecodes() throws {
        let snapshot = try RosterSnapshot.decode(BotsFixture.json("demo-profiles-list"))
        #expect(snapshot.profiles.count == 9)
        #expect(snapshot.botModeProtocol == true)
        let deploys = try #require(snapshot.profiles.first { $0.name == "deploys" })
        #expect(deploys.displayName == "Deploys")
        #expect(deploys.description == "Releases, builds and checks")
        #expect(deploys.canonicalSession?.id == "20261001_093800_aa000003")
        #expect(deploys.canonicalSession?.openId == "20261001_093800_aa000003")
        #expect(deploys.canonicalSession?.messageCount == 14)
        #expect(deploys.canonicalSession?.isBotChat == true)
        let meta = BotMeta(json: deploys.uiMeta["hermes-bots"])
        #expect(meta.pinned && meta.sectionId == "sec-work" && meta.sectionName == "Work" && meta.title == "Deploys")
        #expect(meta.created == 1790000000002)
        #expect(deploys.head?["theme"]?.string == "shape")
        #expect(deploys.head?["v"]?.int == 6)
        let primary = try #require(snapshot.profiles.first)
        #expect(primary.name == "default" && primary.isDefault && primary.handle == "hermes")
    }

    /// The performance fixture (action-voice shape): no resolved_id, a fake `display_name` inside hermes-bots meta that
    /// real gateways never send (§12.2) and must be ignored.
    @Test func performanceRosterDecodes() throws {
        let snapshot = try RosterSnapshot.decode(BotsFixture.json("perf-profiles-list"))
        #expect(snapshot.profiles.map(\.name) == ["default", "ivy"])
        let ivy = snapshot.profiles[1]
        #expect(ivy.canonicalSession?.id == "20260929_120000_aabbcc02")
        #expect(ivy.canonicalSession?.resolvedId == nil)
        #expect(ivy.canonicalSession?.openId == "20260929_120000_aabbcc02")
        let out = RosterBuilder.build(.init(profiles: snapshot.profiles))
        #expect(out.layout.flat.map(\.name).sorted() == ["Hermes", "Ivy"])
    }

    @Test func titleLookupRowsDecode() throws {
        let demo = try BotsFixture.json("demo-session-list-bot-chat")
        let rows = (demo["sessions"]?.array ?? []).compactMap { RosterSessionRef(json: $0) }
        #expect(rows.count > 1)
        // The demo gateway ignores `title`; only the Bot Chat row matches.
        let found = rows.first { $0.isBotChat }
        let match = try #require(found)
        #expect(match.id == "20261001_093800_aa000003")
        #expect(rows.filter(\.isBotChat).count == 1)
        let perf = try BotsFixture.json("perf-session-list-bot-chat")
        #expect((perf["sessions"]?.array ?? []).compactMap { RosterSessionRef(json: $0) }.first?.isBotChat == true)
    }

    /// Spec 02 §2.1 Example B: the real gateway's row, field for field.
    @Test func realShapeDecodes() throws {
        let result = BotsFixture.parse(#"""
        {"profiles":[
          {"name":"default","path":"/Users/me/.hermes","is_default":true,"model":"claude-opus-5-5","provider":"anthropic",
           "description":"","display_name":"","skill_count":41,"previous_names":[],
           "last_session":{"id":"20260101_090000_aa0007","title":"Standup notes","preview":"Here are today's three items: ...",
             "started_at":1791972072.1,"last_active":1791975610.4,"message_count":14,"live_message_count":9},
           "worker_session":{"id":"20261009_101500_kb77aa","source":"kanban","title":"work kanban task t_522444de","last_active":1791980100.0},
           "canonical_session":{"id":"20260101_090000_aa0005","resolved_id":"20260101_090000_aa0006","root_title":"Bot Chat",
             "title":"Bot Chat","preview":"Done. I pushed the fix and opened PR #412.","started_at":1791266130.0,
             "last_active":1791981234.9,"message_count":388,"live_message_count":171},
           "ui_meta_revisions":{"hermes-bots":12,"dispatch-head":3},
           "ui_meta":{"hermes-bots":{"pinned":true,"sectionId":"hermes-hq-pinned","sectionName":"Pinned","pinnedFrom":null,"created":1757950000000},
                      "dispatch-head":{"v":6,"theme":"shape","color":"cobalt","seed":7,"form":"blob","look":"slits"}},
           "has_avatar":true},
          {"name":"ivy","path":"/Users/me/.hermes/profiles/ivy","is_default":false,"model":null,"provider":null,
           "description":"Research assistant","display_name":"","skill_count":12,"previous_names":[],
           "last_session":null,"worker_session":null,"canonical_session":null,"ui_meta_revisions":{},"has_avatar":false}],
         "bot_mode_protocol":true,"install_id":"c0ffee00"}
        """#)
        let snapshot = try RosterSnapshot.decode(result)
        #expect(snapshot.installId == "c0ffee00")
        let primary = snapshot.profiles[0]
        #expect(primary.canonicalSession?.openId == "20260101_090000_aa0006")
        #expect(primary.canonicalIds == ["20260101_090000_aa0005", "20260101_090000_aa0006"])
        #expect(primary.canonicalSession?.lastActive == 1791981234.9)
        #expect(primary.workerSession?.source == "kanban")
        #expect(primary.hasAvatar)
        let meta = BotMeta(json: primary.serverMeta.map(JSONValue.object))
        #expect(meta.pinned && meta.pinnedFrom == .noSection && meta.sectionId == RosterRules.pinnedSectionId)
        let ivy = snapshot.profiles[1]
        #expect(ivy.canonicalSession == nil && ivy.lastSession == nil && ivy.uiMeta.isEmpty)
        #expect(ivy.displayName == nil)                       // "" reads as none
        let out = RosterBuilder.build(.init(profiles: snapshot.profiles))
        let bots = Dictionary(uniqueKeysWithValues: out.layout.flat.map { ($0.id, $0) })
        #expect(bots["default"]?.name == "Hermes")
        #expect(bots["default"]?.canonicalSessionId == "20260101_090000_aa0006")
        #expect(bots["default"]?.preview == "Done. I pushed the fix and opened PR #412.")
        #expect(bots["ivy"]?.name == "Ivy")
        #expect(bots["ivy"]?.role == "Research assistant")
        #expect(bots["ivy"]?.preview == nil)
        #expect(bots["ivy"]?.lastActive == nil)
        #expect(out.details["ivy"]?.preview.text == "Research assistant")
    }

    /// Spec 02 §3 step 5: YAML numbers/bools become text, objects are dropped, a non-object ui_meta is dropped.
    @Test func textHygiene() throws {
        let result = BotsFixture.parse(#"""
        {"profiles":[
          {"name":2025,"display_name":{"x":1},"description":true,"ui_meta":{"hermes-bots":{"title":2026,"description":["a"]}}},
          {"name":"x","ui_meta":"broken"},
          {"display_name":"no name"}]}
        """#)
        let snapshot = try RosterSnapshot.decode(result)
        #expect(snapshot.profiles.map(\.name) == ["2025", "x"])
        let first = snapshot.profiles[0]
        #expect(first.displayName == nil)
        #expect(first.description == "true")
        let meta = BotMeta(json: first.uiMeta["hermes-bots"])
        #expect(meta.title == "2026" && meta.description == nil)
        #expect(snapshot.profiles[1].uiMeta.isEmpty)
        #expect(throws: RosterSnapshot.DecodeError.self) { try RosterSnapshot.decode(.object([:])) }
    }

    /// The slim answer keeps each bot's last known session fields until the full answer lands.
    @Test func slimMergeKeepsSessionFields() throws {
        let full = try BotsFixture.json("demo-profiles-list")
        let slim = BotsTest.slimmed(full)
        let merged = RosterSnapshot.mergeSlim(slim["profiles"]!.array!, over: full["profiles"]!.array!)
        let profiles = merged.compactMap { RosterProfile(json: $0) }
        #expect(profiles.allSatisfy { $0.canonicalSession != nil })
        // A bot the previous roster did not know keeps its slim row as it is.
        let fresh = RosterSnapshot.mergeSlim([BotsTest.row("new")], over: full["profiles"]!.array!)
        #expect(RosterProfile(json: fresh[0])?.canonicalSession == nil)
    }

    @Test func metaSnapshotMerge() {
        let local: [String: JSONValue] = ["ivy": ["title": "Old", "image": "data:image/png;base64,AA", "chat": "legacy", "group": "g1", "color": "red"]]
        let profile = RosterProfile(json: BotsTest.row("ivy", meta: ["title": "New", "groups": ["g2"]]))!
        let merged = BotMetaMerge.merge(local: local, roster: [profile])["ivy"]?.object ?? [:]
        #expect(merged["title"]?.string == "New")
        #expect(merged["color"]?.string == "red")                  // local-only keys stay ({...local, ...server})
        #expect(merged["image"]?.string == "data:image/png;base64,AA")
        #expect(merged["chat"] == nil)
        #expect(merged["group"] == nil)
        // A row with no server meta keeps the local meta.
        let bare = RosterProfile(json: BotsTest.row("ivy"))!
        #expect(BotMetaMerge.merge(local: local, roster: [bare])["ivy"] == local["ivy"])
    }
    /// A malformed or huge count never traps at decode.
    @Test func hugeCountsDecodeWithoutTrapping() throws {
        let row = BotsFixture.parse(#"{"id":"x","message_count":1e300,"live_message_count":-1e30,"last_active":12.5}"#)
        let ref = try #require(RosterSessionRef(json: row))
        #expect(ref.messageCount == nil && ref.liveMessageCount == nil)
        #expect(RosterSessionRef(json: BotsFixture.parse(#"{"id":"x","message_count":7.9}"#))?.messageCount == 7)
        let session = try #require(SidebarSessionRow(json: BotsFixture.parse(#"{"id":"s","profile":"ivy","message_count":9.3e18,"tool_call_count":3}"#)))
        #expect(session.messageCount == nil && session.toolCallCount == 3)
        let payload = try SidebarPayload.decode(BotsFixture.parse(#"{"recents":{"sessions":[],"total":1e40},"cron":{"sessions":[]},"messaging":{"sessions":[]}}"#))
        #expect(payload.recents.total == nil)
    }

    /// Cache pruning keeps the newest copies of one kind only: device state files of every account survive.
    @Test func pruningNeverTouchesStateFiles() throws {
        let dir = BotsTest.tempDirectory()
        let accounts = (0..<4).map { i in
            GatewayAccount(id: "http://127.0.0.1:97\(i)|u", baseURL: URL(string: "http://127.0.0.1:97\(i)")!, kind: .password,
                           username: "u", label: "fixture")
        }
        for account in accounts {
            RosterDisk.write(SessionsDeviceState(), to: RosterDisk.url(dir, RosterDisk.sessionStateKind, account))
            RosterDisk.write(BotDeviceState(), to: RosterDisk.url(dir, RosterDisk.botStateKind, account))
            // An older build's state file name, which a prefix match on "sessions-" used to count as a cache.
            RosterDisk.write(SessionsDeviceState(), to: dir.appendingPathComponent("sessions-state-\(RosterDisk.accountKey(account)).json"))
            RosterDiskWriter.shared.flush()
            Thread.sleep(forTimeInterval: 0.02)                           // distinct modification times
            RosterDisk.write(SessionsCacheFile(at: 0, recents: [], cron: [], messaging: []),
                             to: RosterDisk.url(dir, RosterDisk.sessionsKind, account), keepNewest: (RosterDisk.sessionsKind, 3))
            RosterDisk.write(RosterCacheFile(at: 0, profiles: []), to: RosterDisk.url(dir, RosterDisk.rosterKind, account),
                             keepNewest: (RosterDisk.rosterKind, 3))
            RosterDiskWriter.shared.flush()
            Thread.sleep(forTimeInterval: 0.02)
        }
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        for account in accounts {
            #expect(names.contains(RosterDisk.url(dir, RosterDisk.sessionStateKind, account).lastPathComponent))
            #expect(names.contains(RosterDisk.url(dir, RosterDisk.botStateKind, account).lastPathComponent))
            #expect(names.contains("sessions-state-\(RosterDisk.accountKey(account)).json"))
        }
        // Three caches of each kind: the oldest account's went.
        #expect(!names.contains(RosterDisk.url(dir, RosterDisk.sessionsKind, accounts[0]).lastPathComponent))
        #expect(!names.contains(RosterDisk.url(dir, RosterDisk.rosterKind, accounts[0]).lastPathComponent))
        for account in accounts.dropFirst() {
            #expect(names.contains(RosterDisk.url(dir, RosterDisk.sessionsKind, account).lastPathComponent))
            #expect(names.contains(RosterDisk.url(dir, RosterDisk.rosterKind, account).lastPathComponent))
        }
        #expect(RosterDisk.isFile("sessions-\(RosterDisk.accountKey(accounts[0])).json", ofKind: "sessions"))
        #expect(!RosterDisk.isFile("sessionstate-\(RosterDisk.accountKey(accounts[0])).json", ofKind: "sessions"))
    }

    /// The legacy per-slice answers assemble into the sidebar shape.
    @Test func legacySlicesAssemble() throws {
        let recents = BotsFixture.parse(#"{"sessions":[{"id":"a","profile":"ivy","message_count":2}],"errors":[{"profile":"x","error":"boom"}],"storage":{"x":"corrupt"}}"#)
        let cron = BotsFixture.parse(#"{"sessions":[]}"#)
        let messaging = BotsFixture.parse(#"{"failed":true,"retry":true}"#)
        let payload = try SidebarPayload.assembleLegacy(recents: recents, cron: cron, messaging: messaging)
        #expect(payload.recents.rows?.map(\.id) == ["a"])
        #expect(payload.cron.rows == [])
        #expect(payload.messaging.failed)
        #expect(payload.failedProfiles == ["x"])
        #expect(payload.fingerprint == nil)
    }
}
