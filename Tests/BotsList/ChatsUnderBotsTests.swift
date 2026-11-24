// [chats-under] Which of a bot's chats the Bots page lists under its row, and how the choice is kept.

import Foundation
import Testing
@testable import HermesHQNative

@MainActor
@Suite(.serialized)
struct ChatsUnderBotsTests {
    private func chat(_ id: String, _ bot: String = "default", hoursAgo: Double, pinned: Bool = false,
                      archived: Bool = false) -> SessionSummary {
        var session = SessionSummary(id: id, profile: bot, title: id, preview: nil,
                                     lastActive: Date().addingTimeInterval(-hoursAgo * 3600), source: "desktop",
                                     unread: false, isRunning: false)
        session.pinned = pinned
        session.archived = archived
        return session
    }

    private var list: [SessionSummary] {
        [chat("p1", hoursAgo: 90, pinned: true), chat("p2", hoursAgo: 200, pinned: true),
         chat("a", hoursAgo: 1), chat("b", hoursAgo: 3), chat("c", hoursAgo: 5), chat("d", hoursAgo: 8),
         chat("x", "otto", hoursAgo: 0.5), chat("old", hoursAgo: 0.1, archived: true)]
    }

    /// [Mac AAA rest 2026-11-17] A chat with no title under its bot is named by its first words, else "Untitled Chat",
    /// as its Sessions row and the Mac sidebar name it (it was a blank row with only its time).
    @Test func untitledChatIsNamed() {
        var session = chat("u", hoursAgo: 1)
        session.title = "  "
        session.preview = "Draft the weekly newsletter"
        #expect(BotChatRowView.label(session, time: "1h").hasPrefix("Draft the weekly newsletter, "))
        session.preview = nil
        #expect(BotChatRowView.label(session, time: "1h") == "Untitled Chat, 1h")
    }

    @Test func pinnedThenNewest() {
        let picked = BotChatsUnder.pick(list, bot: "default", choice: BotChatsChoice(mode: .recent, count: 2))
        #expect(picked.shown.map(\.id) == ["p1", "p2", "a", "b"])
        #expect(picked.more == 2, "c and d are left for Sessions")
    }

    @Test func pinnedOnly() {
        let picked = BotChatsUnder.pick(list, bot: "default", choice: BotChatsChoice(mode: .pinned, count: 3))
        #expect(picked.shown.map(\.id) == ["p1", "p2"])
        #expect(picked.more == 4)
    }

    @Test func pinIconCountsOnlyChatsShownUnderThisBot() {
        let pin = chat("pin", hoursAgo: 2, pinned: true), other = chat("other", hoursAgo: 1)
        let rows = [pin, other, chat("elsewhere", "otto", hoursAgo: 1, pinned: true)]
        let choice = BotChatsChoice(mode: .pinned, count: 2)
        let solo = BotChatsUnder.pick(rows, bot: "default", choice: choice)
        #expect(solo.shown == [pin] && solo.more == 1)
        #expect(!BotChatsUnder.showsPin(for: pin, among: solo.shown))
        #expect(BotChatRowView.label(pin, time: "") == "pin, Pinned")

        let withShortcut = BotChatsUnder.pick(rows, bot: "default", choice: choice, shortcuts: [other])
        #expect(withShortcut.shown.map { BotChatsUnder.showsPin(for: $0, among: withShortcut.shown) } == [false, true])
        let twoPins = BotChatsUnder.pick(list, bot: "default", choice: choice)
        #expect(twoPins.shown.map { BotChatsUnder.showsPin(for: $0, among: twoPins.shown) } == [true, true])
    }

    @Test func offListsNothing() {
        let picked = BotChatsUnder.pick(list, bot: "default", choice: BotChatsChoice(mode: .off, count: 2))
        #expect(picked.shown.isEmpty)
        #expect(picked.more == 0)
    }

    @Test func onlyTheBotsOwnLiveChats() {
        let picked = BotChatsUnder.pick(list, bot: "otto", choice: .standard)
        #expect(picked.shown.map(\.id) == ["x"])
        #expect(picked.more == 0)
        let all = BotChatsUnder.pick(list, bot: "default", choice: BotChatsChoice(mode: .recent, count: 5))
        #expect(!all.shown.contains { $0.id == "old" }, "archived chats stay out")
    }

    @Test func shortcutsLeadEveryModeWithoutLeakingOrCountingTwice() {
        let kept = chat("kept", hoursAgo: 900)
        let chosen = [kept, list[0], kept, chat("kept", "otto", hoursAgo: 1), list.last!]
        for mode in BotChatsMode.allCases {
            let result = BotChatsUnder.pick(list, bot: "default", choice: .init(mode: mode, count: 1), shortcuts: chosen)
            #expect(result.shown.prefix(2).map(\.id) == ["kept", "p1"])
            #expect(Set(result.shown.map(\.id)).count == result.shown.count)
            #expect(result.shown.allSatisfy { $0.profile == "default" && !$0.archived })
            #expect(!result.shown[0].pinned)
            if mode == .off { #expect(result.shown.count == 2 && result.more == 0) }
            else { #expect(result.more + result.shown.count == 7, "six visible chats plus the one explicit exception") }
        }
        let other = BotChatsUnder.pick([], bot: "otto", choice: .initial, shortcuts: [kept])
        #expect(other.shown.isEmpty && other.more == 0, "same session id on another bot is not selected")
    }

    @Test func shortcutPersistsByAccountAndSyncsRemovalsWithoutResurrectingThem() throws {
        let dir = BotsTest.tempDirectory()
        func make(_ account: GatewayAccount) -> SessionStore {
            SessionStore(client: BotsFakeGatewayClient(), account: account, cacheDirectory: dir, timing: .fast, autoStart: false)
        }
        let first = make(.botsTestAccount), selected = chat("a", hoursAgo: 2), other = chat("a", "otto", hoursAgo: 1)
        first.setBotShortcut(selected, true)
        let base = first.syncValue()
        RosterDiskWriter.shared.flush()
        let again = make(.botsTestAccount)
        #expect(again.hasBotShortcut(selected) && !again.hasBotShortcut(other))
        var account = GatewayAccount.botsTestAccount; account.id += "-other"
        #expect(!make(account).hasBotShortcut(selected))
        first.setBotShortcut(selected, false)
        again.setBotShortcut(other, true)
        first.adoptSynced(again.syncValue(), merge: .rebase, base: base)
        #expect(first.hasBotShortcut(other) && !first.hasBotShortcut(selected))
        again.adoptSynced(first.syncValue(), merge: .replace, base: base)
        #expect(again.hasBotShortcut(other) && !again.hasBotShortcut(selected))
        again.adoptSynced(["sortBy": "updated"], merge: .replace, base: nil)
        #expect(again.hasBotShortcut(other), "older app versions don't erase the shortcut")
        #expect(try JSONDecoder().decode(SessionsDeviceState.self, from: Data("{}".utf8)).botChatShortcuts.isEmpty)
    }

    @Test func offPageShortcutReadsOnlyItsExactLiveChatAndNeverAddsItToRecents() async throws {
        let client = BotsFakeGatewayClient()
        let store = SessionStore(client: client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: .fast, autoStart: false)
        defer { store.stop() }
        let ids = ["old", "hidden", "archived", "prefix", "other-profile", "deleted"]
        for id in ids { store.setBotShortcut(chat(id, "otto", hoursAgo: 800), true) }
        let sidebar = SessionStore.sidebarPath
        client.onREST { _, path, query, _ in
            if path == sidebar { return SessionActionsTests.sidebar([]) }
            let id = String(path.split(separator: "/").last ?? "")
            guard ids.contains(id), query.contains(URLQueryItem(name: "profile", value: "otto")), id != "deleted" else {
                throw HTTPError(status: 404, body: nil)
            }
            let detail: JSONValue = ["id": .string(id == "prefix" ? "prefix-other" : id),
                "profile": .string(id == "other-profile" ? "ivy" : "otto"), "title": "Old thread", "source": "desktop",
                "hidden": .bool(id == "hidden"), "archived": .bool(id == "archived")]
            return try detail.encoded()
        }
        store.start()
        await store.refresh()
        await store.shortcutRead?.value
        #expect(store.botShortcutRows.map(\.id) == ["old"])
        #expect(store.sessions.isEmpty && store.sessionsOutsideKeptProjects().isEmpty)
        #expect(client.restCalls.filter { $0.path.hasPrefix("/api/sessions/") }.count == ids.count)
        store.refreshOffPageShortcuts()
        #expect(store.shortcutRead == nil, "redrawing or refreshing doesn't repeatedly look up an old chat")
        let old = try #require(store.botShortcutRows.first)
        store.forget(id: old.id, profile: old.profile)
        #expect(store.botShortcutRows.isEmpty && store.hasBotShortcut(old), "Archive hides the shortcut immediately")
        store.forget(id: old.id, profile: old.profile, deleting: true)
        #expect(!store.hasBotShortcut(old), "deleting the underlying chat also removes its saved shortcut")
    }

    @Test func shortcutFollowsCompactionButNotAForkOrAnotherProfile() throws {
        let store = SessionStore(client: BotsFakeGatewayClient(), account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: .fast, autoStart: false)
        let old = chat("root", "otto", hoursAgo: 6)
        store.setBotShortcut(old, true)
        // Another device selected the newer segment before it knew the two ids belonged to one chat.
        let newer = BotChatShortcut(profile: "otto", id: "next")
        store.adoptSynced(["botChatShortcuts": .array([newer.json])], merge: .firstContact, base: nil)
        var current = SidebarSessionRow(id: "next", profile: "otto", title: "Current segment", source: "desktop")
        current.lineageRootId = "root"
        var fork = SidebarSessionRow(id: "fork", profile: "otto", title: "Fork", source: "desktop")
        fork.parentSessionId = "root"
        var other = current; other.profile = "ivy"
        store.recents = [fork, current, other]; store.rebuild()
        #expect(store.botShortcutRows.map(\.id) == ["next"])
        let moved = try #require(store.botShortcutRows.first)
        #expect(moved.profile == "otto" && store.hasBotShortcut(moved))
        store.setBotShortcut(moved, false)
        #expect(store.botShortcutRows.isEmpty && !store.hasBotShortcut(old))
    }

    @Test func pinsAreCapped() {
        let pins = (0..<8).map { chat("p\($0)", hoursAgo: Double($0), pinned: true) }
        let picked = BotChatsUnder.pick(pins, bot: "default", choice: BotChatsChoice(mode: .pinned, count: 2))
        #expect(picked.shown.count == BotChatsUnder.maxPinned)
        #expect(picked.more == 8 - BotChatsUnder.maxPinned)
    }

    @Test func activeChats() {
        var waiting = chat("w", hoursAgo: 6); waiting.status = .needsInput
        var working = chat("r", hoursAgo: 2); working.isRunning = true
        var unread = chat("u", hoursAgo: 1); unread.unread = true
        let quiet = chat("q", hoursAgo: 0.5, pinned: true)
        let picked = BotChatsUnder.pick([quiet, unread, working, waiting], bot: "default", choice: BotChatsChoice(mode: .active, count: 2))
        #expect(picked.shown.map(\.id) == ["w", "r", "u"], "waiting first, then working, then unread; pins don't count")
        #expect(picked.more == 1)
    }

    @Test func offUntilChosen() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: BotChatsPrefs.key)
        defer { defaults.set(saved, forKey: BotChatsPrefs.key) }
        defaults.removeObject(forKey: BotChatsPrefs.key)
        #expect(BotChatsPrefs.all.mode == .off, "nobody's page changes until they choose")
    }

    @Test func styleStartsAsBranches() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: BotChatsStyle.key)
        defer { defaults.set(saved, forKey: BotChatsStyle.key) }
        defaults.removeObject(forKey: BotChatsStyle.key)
        #expect(BotChatsStyle.saved == .branch)
        BotChatsStyle.saved = .dots
        #expect(BotChatsStyle.saved == .dots)
        #expect(BotChatsStyle.allCases.map(\.title) == ["Branches", "Dots", "Line", "Dividers", "No Line"])
    }

    @Test func choicesRoundTrip() {
        for choice in [BotChatsChoice(mode: .off, count: 2), BotChatsChoice(mode: .active, count: 2), BotChatsChoice(mode: .pinned, count: 2),
                       BotChatsChoice(mode: .recent, count: 5)] {
            #expect(BotChatsChoice(stored: choice.stored)?.mode == choice.mode)
        }
        #expect(BotChatsChoice(stored: "recent:3")?.count == 3)
        #expect(BotChatsChoice(stored: "recent:4")?.count == 2, "an odd count falls back")
        #expect(BotChatsChoice(stored: "nonsense") == nil)
        #expect(BotChatsChoice.standard.summary == "Pinned + 2 recent")
    }

    @Test func aBotsOwnChoiceWins() {
        let defaults = UserDefaults.standard
        let saved = (defaults.object(forKey: BotChatsPrefs.key), defaults.object(forKey: BotChatsPrefs.botsKey))
        defer {
            defaults.set(saved.0, forKey: BotChatsPrefs.key)
            defaults.set(saved.1, forKey: BotChatsPrefs.botsKey)
        }
        BotChatsPrefs.all = BotChatsChoice(mode: .recent, count: 3)
        BotChatsPrefs.setOwn(BotChatsChoice(mode: .off, count: 2), for: "otto")
        #expect(BotChatsPrefs.choice(for: "otto").mode == .off)
        #expect(BotChatsPrefs.choice(for: "default") == BotChatsChoice(mode: .recent, count: 3))
        BotChatsPrefs.setOwn(nil, for: "otto")
        #expect(BotChatsPrefs.own("otto") == nil, "Same as All Bots clears it")
    }

    /// [mac] The Mac's sidebar lists chats only while some bot does, and hears each change of choice.
    @Test func inUseAndChanges() {
        let defaults = UserDefaults.standard
        let saved = (defaults.object(forKey: BotChatsPrefs.key), defaults.object(forKey: BotChatsPrefs.botsKey))
        defer {
            defaults.set(saved.0, forKey: BotChatsPrefs.key)
            defaults.set(saved.1, forKey: BotChatsPrefs.botsKey)
        }
        final class Heard: @unchecked Sendable { var count = 0 }
        let heard = Heard()
        let token = NotificationCenter.default.addObserver(forName: BotChatsPrefs.changed, object: nil, queue: nil) { _ in heard.count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        defaults.removeObject(forKey: BotChatsPrefs.botsKey)
        BotChatsPrefs.all = .initial
        #expect(!BotChatsPrefs.inUse, "off for every bot")
        BotChatsPrefs.setOwn(BotChatsChoice(mode: .off, count: 2), for: "otto")
        #expect(!BotChatsPrefs.inUse, "a bot's own Off lists nothing either")
        BotChatsPrefs.setOwn(BotChatsChoice(mode: .pinned, count: 2), for: "otto")
        #expect(BotChatsPrefs.inUse, "one bot's own choice")
        BotChatsPrefs.setOwn(nil, for: "otto")
        BotChatsPrefs.all = .standard
        #expect(BotChatsPrefs.inUse)
        #expect(heard.count == 5)
    }
}
