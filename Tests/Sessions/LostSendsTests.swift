import Foundation
import Testing
@testable import HermesHQNative

/// [sessions-m9] Sends that may never have arrived, kept for the Sessions row (docs/spec/3x-sessions.md §9.4).
@MainActor @Suite(.serialized) struct LostSendsTests {
    private func entry(_ id: String, _ text: String, at: Double = 1_791_000_000) -> LostSends.Entry {
        LostSends.Entry(id: id, text: text, at: Date(timeIntervalSince1970: at))
    }

    @Test func notesClearsAndTellsTheRows() {
        let store = LostSends(base: BotsTest.tempDirectory())
        var changes = 0
        store.onChange = { changes += 1 }
        store.note(accountId: "acct", profile: "default", chatId: "s1", entry: entry("local-1", "  send the quote  "))
        store.note(accountId: "acct", profile: "default", chatId: "s1", entry: entry("local-2", "second"))
        store.note(accountId: "acct", profile: "research", chatId: "s1", entry: entry("local-1", "the twin's"))      // a twin chat is its own
        #expect(store.first(accountId: "acct", profile: "default", chatId: "s1")?.text == "send the quote")
        #expect(store.entries(accountId: "acct", profile: "default", chatId: "s1").map(\.id) == ["local-1", "local-2"])
        #expect(store.first(accountId: "acct", profile: "research", chatId: "s1")?.text == "the twin's")
        #expect(store.first(accountId: "other", profile: "default", chatId: "s1") == nil)
        #expect(changes == 3)
        // The same message marked again replaces its entry; blank words and a chat without an id are not kept.
        store.note(accountId: "acct", profile: "default", chatId: "s1", entry: entry("local-1", "send the quote again"))
        #expect(store.entries(accountId: "acct", profile: "default", chatId: "s1").map(\.text) == ["second", "send the quote again"])
        store.note(accountId: "acct", profile: "default", chatId: "s1", entry: entry("local-3", " \n "))
        store.note(accountId: "acct", profile: "default", chatId: "", entry: entry("local-4", "words"))
        #expect(store.entries(accountId: "acct", profile: "default", chatId: "s1").count == 2)
        store.clear(accountId: "acct", profile: "default", chatId: "s1", id: "local-2")
        store.clear(accountId: "acct", profile: "default", chatId: "s1", id: "never-there")
        #expect(store.entries(accountId: "acct", profile: "default", chatId: "s1").map(\.id) == ["local-1"])
        store.rekey(accountId: "acct", profile: "default", chatId: "s1", from: "local-1", to: "local-user-lost-abc")
        #expect(store.first(accountId: "acct", profile: "default", chatId: "s1")?.id == "local-user-lost-abc")
        store.clear(accountId: "acct", profile: "default", chatId: "s1", id: "local-user-lost-abc")
        #expect(store.first(accountId: "acct", profile: "default", chatId: "s1") == nil)
    }

    /// Sign Out and Remove count what they delete (UX study #120): every chat's entries, per account.
    @Test func countsAnAccountsEntries() {
        let store = LostSends(base: BotsTest.tempDirectory())
        #expect(store.count(accountId: "acct") == 0)
        store.note(accountId: "acct", profile: "default", chatId: "s1", entry: entry("local-1", "one"))
        store.note(accountId: "acct", profile: "default", chatId: "s1", entry: entry("local-2", "two"))
        store.note(accountId: "acct", profile: "research", chatId: "s2", entry: entry("local-3", "three"))
        store.note(accountId: "other", profile: "default", chatId: "s1", entry: entry("local-4", "four"))
        #expect(store.count(accountId: "acct") == 3)
        store.purge(accountId: "acct")
        #expect(store.count(accountId: "acct") == 0)
    }

    /// Review finding: deleting a chat takes its entries (and only its), on disk too.
    @Test func aDeletedChatsEntriesGo() {
        let base = BotsTest.tempDirectory()
        let store = LostSends(base: base)
        var changes = 0
        store.onChange = { changes += 1 }
        store.note(accountId: "acct", profile: "default", chatId: "s1", entry: entry("local-1", "one"))
        store.note(accountId: "acct", profile: "default", chatId: "s1", entry: entry("local-2", "two"))
        store.note(accountId: "acct", profile: "research", chatId: "s1", entry: entry("local-3", "the twin's"))
        store.note(accountId: "acct", profile: "default", chatId: "s2", entry: entry("local-4", "another chat's"))
        changes = 0
        store.clear(accountId: "acct", profile: "default", chatId: "s1")
        #expect(changes == 1)
        #expect(store.entries(accountId: "acct", profile: "default", chatId: "s1").isEmpty)
        #expect(store.first(accountId: "acct", profile: "research", chatId: "s1")?.text == "the twin's")
        #expect(store.first(accountId: "acct", profile: "default", chatId: "s2")?.text == "another chat's")
        store.clear(accountId: "acct", profile: "default", chatId: "never")
        #expect(changes == 1)                                                           // nothing to clear, nothing said
        store.flush()
        let again = LostSends(base: base)
        #expect(again.entries(accountId: "acct", profile: "default", chatId: "s1").isEmpty)
        #expect(again.first(accountId: "acct", profile: "default", chatId: "s2")?.text == "another chat's")
    }

    @Test func survivesARelaunchAndIsPurgedWithTheAccount() {
        let base = BotsTest.tempDirectory()
        let store = LostSends(base: base)
        store.note(accountId: "acct", profile: "default", chatId: "s1", entry: entry("local-1", "send the quote"))
        store.note(accountId: "b", profile: "default", chatId: "s9", entry: entry("local-1", "another account's"))
        store.flush()
        #expect(FileManager.default.fileExists(atPath: LostSends.file(accountId: "acct", base: base).path))
        let again = LostSends(base: base)
        #expect(again.first(accountId: "acct", profile: "default", chatId: "s1") == entry("local-1", "send the quote"))
        again.purge(accountId: "acct")
        again.flush()
        #expect(again.first(accountId: "acct", profile: "default", chatId: "s1") == nil)
        #expect(!FileManager.default.fileExists(atPath: LostSends.file(accountId: "acct", base: base).path))
        #expect(LostSends(base: base).first(accountId: "b", profile: "default", chatId: "s9")?.text == "another account's")
        // The last entry cleared removes the file.
        let last = LostSends(base: base)
        last.clear(accountId: "b", profile: "default", chatId: "s9", id: "local-1")
        last.flush()
        #expect(!FileManager.default.fileExists(atPath: LostSends.file(accountId: "b", base: base).path))
    }

    @Test func boundsAndBadFiles() throws {
        let base = BotsTest.tempDirectory()
        let store = LostSends(base: base)
        for i in 0..<30 { store.note(accountId: "acct", profile: "p", chatId: "s", entry: entry("m\(i)", "words \(i)", at: Double(i))) }
        store.note(accountId: "acct", profile: "p", chatId: "s", entry: entry("long", String(repeating: "x", count: 5_000)))
        let kept = store.entries(accountId: "acct", profile: "p", chatId: "s")
        #expect(kept.count == LostSends.maxEntries && kept.first?.id == "m11" && kept.last?.text.count == LostSends.maxCharacters)
        // A torn or newer file reads as nothing, and the next change writes a good one.
        let file = LostSends.file(accountId: "torn", base: base)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"v":2,"chats":{"p\#u{1F}s":"#.utf8).write(to: file)
        let torn = LostSends(base: base)
        #expect(torn.entries(accountId: "torn", profile: "p", chatId: "s").isEmpty)
        torn.note(accountId: "torn", profile: "p", chatId: "s", entry: entry("m", "fresh"))
        torn.flush()
        #expect(LostSends.load(accountId: "torn", base: base)[LostSends.key(profile: "p", chatId: "s")]?.map(\.text) == ["fresh"])
    }
}
