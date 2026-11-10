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
