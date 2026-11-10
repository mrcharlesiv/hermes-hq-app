// [restore] The last chat reopened on launch (HermesKit/Store/LaunchChatMemory.swift): the web's nav-persistence.ts
// rules (`phoneChatRestorable`, `forgetCrashedScreen`, `display.resume_last_session !== false`) and the native
// "chat on screen" marker that stands in for the web's error-boundary crash flag.

import Foundation
import Testing
@testable import HermesHQNative

@MainActor
struct LaunchChatMemoryTests {
    private static let a = "http://127.0.0.1:9800|fixture"
    private static let b = "http://127.0.0.1:9801|fixture"

    private func memory() -> (LaunchChatMemory, UserDefaults) {
        let suite = "launch-chat-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (LaunchChatMemory(defaults: defaults), defaults)
    }

    private let botChat = RememberedChat(origin: .bots, profile: "ivy", storedId: "20261009_090000_bcaaaaaa", botChat: true)
    private let sessionChat = RememberedChat(origin: .sessions, profile: "research", storedId: "s-reading", botChat: false)
    private let jobChat = RememberedChat(origin: .page, profile: "inbox", storedId: "s-cron", botChat: false,
                                         pageTab: 2, pageKind: "tab-jobs")

    private func decide(_ chat: RememberedChat?, crashed: Bool = false, resume: Bool = true, bots: Set<String> = ["ivy"],
                        listed: Set<String> = ["research|s-reading", "inbox|s-cron"],
                        pages: Set<String> = ["2|tab-jobs"]) -> LaunchChatDecision {
        LaunchChatDecision.decide(chat, crashed: crashed, resume: resume, bot: { bots.contains($0) },
                                  listed: { listed.contains("\($0)|\($1)") }, page: { pages.contains("\($0)|\($1)") })
    }

    // MARK: Decision

    @Test func reopensABotsChatThroughItsBot() {
        #expect(decide(botChat) == .reopen(botChat))
        // Its Bot Chat may have changed since: the bot's current one opens, so the old id needn't be listed.
        #expect(decide(botChat, listed: []) == .reopen(botChat))
        var fresh = botChat
        fresh.storedId = nil
        #expect(decide(fresh) == .reopen(fresh), "a bot whose chat had no id yet reopens through the bot")
    }

    @Test func aRemovedBotIsNotReopened() {
        #expect(decide(botChat, bots: []) == .skip(.botGone))
    }

    @Test func reopensAListedSessionOnlyForItsOwnBot() {
        #expect(decide(sessionChat) == .reopen(sessionChat))
        #expect(decide(sessionChat, listed: []) == .skip(.sessionGone), "deleted or archived: no longer listed")
        // A cloned profile's chat keeps the original's stored id: the profile must match too (owner check).
        #expect(decide(sessionChat, listed: ["default|s-reading"]) == .skip(.sessionGone))
        var noId = sessionChat
        noId.storedId = nil
        #expect(decide(noId) == .skip(.sessionGone))
        noId.storedId = ""
        #expect(decide(noId) == .skip(.sessionGone))
    }

    @Test func aPageChatNeedsItsTabAndItsSession() {
        #expect(decide(jobChat) == .reopen(jobChat))
        #expect(decide(jobChat, pages: []) == .skip(.pageGone), "the tab is gone (Kanban took Artifacts' place, say)")
        #expect(decide(jobChat, pages: ["2|tab-artifacts"]) == .skip(.pageGone))
        #expect(decide(jobChat, listed: []) == .skip(.sessionGone))
        var noTab = jobChat
        noTab.pageTab = nil
        #expect(decide(noTab) == .skip(.pageGone))
    }

    @Test func crashAndPreferenceWinOverEverything() {
        #expect(decide(nil) == .skip(.nothing))
        #expect(decide(botChat, crashed: true) == .skip(.crashed))
        #expect(decide(sessionChat, resume: false) == .skip(.resumeOff))
        #expect(decide(botChat, crashed: true, resume: false) == .skip(.crashed))
    }

    // MARK: Memory

    @Test func remembersPerAccount() {
        let (memory, _) = memory()
        #expect(memory.recall(account: Self.a) == nil)
        memory.remember(botChat, account: Self.a, foreground: true)
        memory.remember(sessionChat, account: Self.b, foreground: true)
        #expect(memory.recall(account: Self.a) == botChat)
        #expect(memory.recall(account: Self.b) == sessionChat)
        // Back on a list: nothing for that account to reopen; the other keeps its chat.
        memory.remember(nil, account: Self.a, foreground: true)
        #expect(memory.recall(account: Self.a) == nil)
        #expect(memory.recall(account: Self.b) == sessionChat)
        memory.remember(jobChat, account: Self.a, foreground: false)
        #expect(memory.recall(account: Self.a) == jobChat, "page origin and tab survive the round trip")
    }

    @Test func aRunThatEndedWithTheChatOnScreenDropsIt() {
        let (first, defaults) = memory()
        first.remember(sessionChat, account: Self.b, foreground: false)   // an earlier gateway, left in the background
        first.remember(botChat, account: Self.a, foreground: true)
        // The process dies here: no trip to the background.
        let next = LaunchChatMemory(defaults: defaults)
        next.launch()
        #expect(next.crashed(account: Self.a))
        #expect(next.recall(account: Self.a) == nil, "the crashed screen is not reopened")
        #expect(!next.crashed(account: Self.b))
        #expect(next.recall(account: Self.b) == sessionChat, "one screen is on show: only its account's chat goes")
        // …and only once: the launch after that is a normal one.
        let third = LaunchChatMemory(defaults: defaults)
        third.launch()
        #expect(!third.crashed(account: Self.a))
    }

    @Test func leavingCleanlyKeepsTheChat() {
        let (first, defaults) = memory()
        first.remember(botChat, account: Self.a, foreground: true)
        first.wentToBackground()
        let next = LaunchChatMemory(defaults: defaults)
        next.launch()
        #expect(!next.crashed(account: Self.a))
        #expect(next.recall(account: Self.a) == botChat)
    }

    @Test func aListOnShowClearsTheMarker() {
        let (first, defaults) = memory()
        first.remember(botChat, account: Self.a, foreground: true)
        first.remember(nil, account: Self.a, foreground: true)
        first.remember(sessionChat, account: Self.b, foreground: false)   // written while in the background
        let next = LaunchChatMemory(defaults: defaults)
        next.launch()
        #expect(!next.crashed(account: Self.a))
        #expect(next.recall(account: Self.b) == sessionChat)
    }

    @Test func launchReadsTheMarkerOnce() {
        let (memory, defaults) = memory()
        memory.launch()
        memory.remember(botChat, account: Self.a, foreground: true)
        memory.launch()   // a second call in the same run never treats this run's own screen as crashed
        #expect(!memory.crashed(account: Self.a))
        #expect(memory.recall(account: Self.a) == botChat)
        _ = defaults
    }

    @Test func resumePreferenceIsOnUntilReadOff() {
        let (memory, _) = memory()
        #expect(memory.resume(account: Self.a))
        memory.setResume(false, account: Self.a)
        #expect(!memory.resume(account: Self.a))
        #expect(memory.resume(account: Self.b), "per account")
        memory.setResume(true, account: Self.a)
        #expect(memory.resume(account: Self.a))
    }

    @Test func resumeFromConfigIsOffOnlyForFalse() throws {
        func read(_ json: String) throws -> Bool { LaunchChatMemory.resume(config: try JSONValue.parse(Data(json.utf8))) }
        #expect(try read(#"{"display":{"resume_last_session":true}}"#))
        #expect(try !read(#"{"display":{"resume_last_session":false}}"#))
        #expect(try read(#"{"display":{}}"#))
        #expect(try read(#"{"model":"fixture"}"#))
        #expect(try read(#"{"display":{"resume_last_session":"false"}}"#), "the web's `!== false`: only the boolean")
        #expect(try read(#"{"display":{"resume_last_session":0}}"#))
        #expect(LaunchChatMemory.resume(config: nil))
    }

    @Test func signOutForgetsTheAccountOnly() {
        let (memory, defaults) = memory()
        memory.remember(botChat, account: Self.a, foreground: true)
        memory.setResume(false, account: Self.a)
        memory.remember(sessionChat, account: Self.b, foreground: false)
        memory.forget(account: Self.a)
        #expect(memory.recall(account: Self.a) == nil)
        #expect(memory.resume(account: Self.a))
        #expect(memory.recall(account: Self.b) == sessionChat)
        let next = LaunchChatMemory(defaults: defaults)
        next.launch()
        #expect(!next.crashed(account: Self.a), "the marker went with it")
        next.forgetAll()
        #expect(next.recall(account: Self.b) == nil)
    }
}
