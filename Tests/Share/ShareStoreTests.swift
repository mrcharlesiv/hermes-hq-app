// [share] docs/spec/3x-share.md §5.1, §7.5 check 1, §7.11 check 1: the App Group folder's files.

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct ShareStoreTests {
    private func store() -> ShareStore { ShareStore(folder: ShareTemp.folder("store")) }
    private let png = Data([0x89, 0x50, 0x4e, 0x47, 1, 2, 3])
    private let faceA = "00112233445566778899aabbccddeeff.png"
    private let faceB = "ffeeddccbbaa99887766554433221100.png"

    @Test func rosterRoundTrip() throws {
        let store = store()
        #expect(store.roster == nil)
        let roster = ShareSamples.roster(bots: [ShareSamples.bot("ivy", lastActive: 1_790_000_000, avatar: faceA),
                                                ShareSamples.bot("default", name: "Hermes", session: "")])
        try store.save(roster, pictures: [faceA: png])
        #expect(store.roster == roster)
        #expect(store.roster?.version == 1)
        #expect(store.picture(faceA) != nil)
        let pictureA = try #require(store.picture(faceA))
        #expect(try Data(contentsOf: pictureA) == png)
    }

    @Test func rosterHoldsNamesAndRoutingIdsOnly() throws {
        // §7.5 check 6: no message text, no preview, no cookie, no token.
        let store = store()
        try store.save(ShareSamples.roster(bots: [ShareSamples.bot("ivy", lastActive: 5, avatar: faceA)]), pictures: [faceA: png])
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.rosterFile)) as? [String: Any])
        #expect(Set(object.keys) == ["version", "account", "url", "username", "limitBytes", "bots", "savedAt"])
        let bot = try #require((object["bots"] as? [[String: Any]])?.first)
        #expect(Set(bot.keys) == ["key", "name", "profile", "session", "color", "avatar", "lastActive"])
        let text = try String(contentsOf: store.rosterFile, encoding: .utf8).lowercased()
        for word in ["cookie", "token", "password", "preview", "hermes_session"] { #expect(!text.contains(word), "\(word)") }
    }

    @Test func facesAreKeptAndPruned() throws {
        let store = store()
        try store.save(ShareSamples.roster(bots: [ShareSamples.bot("ivy", avatar: faceA)]), pictures: [faceA: png])
        let first = try #require(store.picture(faceA))
        let stamp = try first.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        // The same picture again, not handed over: its file stays as it is.
        try store.save(ShareSamples.roster(bots: [ShareSamples.bot("ivy", avatar: faceA), ShareSamples.bot("default", avatar: faceB)]),
                       pictures: [faceB: png])
        #expect(store.hasPicture(faceA) && store.hasPicture(faceB))
        #expect(try first.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == stamp)
        // A changed head: the new face is there, the old file is gone.
        try store.save(ShareSamples.roster(bots: [ShareSamples.bot("ivy", avatar: faceB)]))
        #expect(!store.hasPicture(faceA) && store.hasPicture(faceB))
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.avatars.path) == [faceB])
    }

    @Test func pictureNamesNeverLeaveTheFolder() throws {
        let store = store()
        ShareTemp.file("x.png", bytes: 4, in: store.folder.deletingLastPathComponent())
        try store.save(ShareSamples.roster(bots: [ShareSamples.bot("ivy", avatar: "../../x.png")]), pictures: ["../evil.png": png, "evil.png": png])
        #expect(store.picture("../../x.png") == nil)
        #expect(store.picture("../x.png") == nil)
        #expect(store.picture(nil) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.folder.appendingPathComponent("evil.png").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.avatars.path).isEmpty)
    }

    @Test func clearLeavesTheFolderEmpty() throws {
        let store = store()
        try store.save(ShareSamples.roster(bots: [ShareSamples.bot("ivy", avatar: faceA)]), pictures: [faceA: png])
        store.remember(choice: "ios-direct::ivy", account: ShareSamples.key)
        store.record(ShareSent(id: "1", account: ShareSamples.key, session: "s1", profile: "ivy", botName: "Ivy", at: 10))
        store.clear()
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.folder.path).isEmpty)
        #expect(store.roster == nil && store.lastSent == nil && store.lastChoice(account: ShareSamples.key) == nil)
        store.clear()       // twice is fine
    }

    @Test func takeSentWindows() {
        // §7.11 check 1.
        let now = 1_800_000_000.0
        func note(_ age: Double, account: String = ShareSamples.key, session: String = "20260929_120000_aabbcc02") -> ShareSent {
            ShareSent(id: UUID().uuidString, account: account, session: session, profile: "ivy", botName: "Ivy", at: now - age)
        }
        let cases: [(ShareSent, Bool)] = [
            (note(0), true), (note(299), true), (note(-4), true), (note(300), true),
            (note(301), false), (note(-6), false), (note(0, account: "http://other\nme"), false), (note(0, session: "a/b"), false),
            (note(0, session: ""), false),
        ]
        for (sent, opens) in cases {
            let store = store()
            store.record(sent)
            #expect(store.hasSentNote)
            #expect((store.takeSent(account: ShareSamples.key, now: now) != nil) == opens, "age \(now - sent.at) \(sent.session)")
            #expect(!store.hasSentNote)                                       // the file goes whatever it holds
            #expect(store.takeSent(account: ShareSamples.key, now: now) == nil)   // once
        }
    }

    @Test func rememberedChoiceIsPerAccount() {
        let store = store()
        #expect(store.lastChoice(account: ShareSamples.key) == nil)
        store.remember(choice: "ios-direct::ivy", account: ShareSamples.key)
        #expect(store.lastChoice(account: ShareSamples.key) == "ios-direct::ivy")
        #expect(store.lastChoice(account: "http://other\nme") == nil)
        store.remember(choice: "ios-direct::default", account: "http://other\nme")
        #expect(store.lastChoice(account: ShareSamples.key) == nil)          // one choice, the latest account's
    }

    @Test func filesThatDoNotDecodeReadAsAbsent() throws {
        let store = store()
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        for bytes in [Data(), Data("not json".utf8), Data("[1,2,3]".utf8), Data("{\"account\":5}".utf8), Data([0xff, 0xfe, 0x00])] {
            for file in [store.rosterFile, store.sentFile, store.choiceFile] { try bytes.write(to: file) }
            #expect(store.roster == nil && store.lastSent == nil && store.lastChoice(account: ShareSamples.key) == nil)
        }
        // An unreadable note is still a note: the app removes it.
        #expect(store.hasSentNote)
        #expect(store.takeSent(account: ShareSamples.key) == nil)
        #expect(!store.hasSentNote)
        // A roster far larger than this app writes is not read.
        try Data(repeating: 0x20, count: ShareStore.maxFileBytes + 1).write(to: store.rosterFile)
        #expect(store.roster == nil)
    }

    @Test func build240RosterStillReads() throws {
        // The JSON build 240 wrote (its own limit, `legacy::` keys, a colour): read after the update.
        let store = store()
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        let json = """
        {"version":1,"account":"http://127.0.0.1:9911\\nshare-fixture","url":"http://127.0.0.1:9911","username":"share-fixture",
         "limitBytes":8388608,"savedAt":1790000000.5,
         "bots":[{"key":"legacy::ivy","name":"Ivy","profile":"ivy","session":"20260929_120000_aabbcc02","color":"#ff8800","avatar":null,"lastActive":1790000000},
                 {"key":"ios-direct::default","name":"Hermes","profile":"default","session":"","color":""}]}
        """
        try Data(json.utf8).write(to: store.rosterFile)
        let roster = try #require(store.roster)
        #expect(roster.limitBytes == 8_388_608 && roster.bots.count == 2)
        #expect(roster.bots[0].key == "legacy::ivy" && roster.bots[0].canReceive && roster.bots[0].color == "#ff8800")
        #expect(!roster.bots[1].canReceive && roster.bots[1].avatar == nil && roster.bots[1].lastActive == nil)
    }

    @Test func filesAreWrittenAtomicallyAndProtected() throws {
        #expect(ShareStore.writeOptions.contains(.atomic))
        #expect(ShareStore.writeOptions.contains(.completeFileProtectionUntilFirstUserAuthentication))
        let store = store()
        try store.save(ShareSamples.roster(bots: [ShareSamples.bot("ivy", avatar: faceA)]), pictures: [faceA: png])
        store.record(ShareSent(id: "1", account: ShareSamples.key, session: "s1", profile: "ivy", botName: "Ivy", at: 10))
        for file in [store.rosterFile, store.sentFile, store.avatars.appendingPathComponent(faceA)] {
            let protection = try FileManager.default.attributesOfItem(atPath: file.path)[.protectionKey] as? FileProtectionType
            // The Simulator's file system does not record a protection class; a device does.
            #expect(protection == nil || protection == .completeUntilFirstUserAuthentication, "\(file.lastPathComponent)")
        }
        // No temporary file of an atomic write is left beside the roster.
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.folder.path).sorted() == ["avatars", "last-sent.json", "roster.json"])
    }

    @Test func noGroupMeansNoStoreInTheNativeIdentity() {
        // The native identity has no App Group: every hook is a no-op there.
        if AppIdentity.current.appGroup == nil { #expect(ShareStore() == nil && ShareIdentity.folder() == nil) }
    }
}
