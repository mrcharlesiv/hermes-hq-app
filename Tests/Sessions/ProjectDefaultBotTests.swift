// [project-default-bot] The bot a project's New Chat starts with.

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct ProjectDefaultBotTests {
    private let bots = ["default", "research", "deploys"]

    @Test func theChosenBotStartsTheChat() {
        #expect(ProjectDefaultBot.resolve(stored: "research", own: ["default"], bots: bots) == "research")
        #expect(ProjectDefaultBot.resolve(stored: "research", own: ["default", "deploys"], bots: bots) == "research")
    }

    @Test func askEveryTimeAsksEvenWithOneBot() {
        #expect(ProjectDefaultBot.resolve(stored: ProjectDefaultBot.ask, own: ["default"], bots: bots) == nil)
    }

    @Test func nothingChosenUsesTheProjectsOnlyBot() {
        #expect(ProjectDefaultBot.resolve(stored: nil, own: ["research"], bots: bots) == "research")
    }

    @Test func nothingChosenAsksWhenSeveralBotsShareTheProjectOrNoneHasIt() {
        #expect(ProjectDefaultBot.resolve(stored: nil, own: ["default", "research"], bots: bots) == nil)
        #expect(ProjectDefaultBot.resolve(stored: nil, own: [], bots: bots) == nil)
    }

    @Test func aChosenBotThatIsGoneFallsBack() {
        #expect(ProjectDefaultBot.resolve(stored: "gone", own: ["default"], bots: bots) == "default")
        #expect(ProjectDefaultBot.resolve(stored: "gone", own: ["default", "research"], bots: bots) == nil)
    }

    @Test @MainActor func projectPRCountsUseVerifiedProjectRowsAndDeduplicate() {
        let projects = ["default": [SessionProject(id: "a", label: "A", root: "/a", paths: ["/a"]),
                                     SessionProject(id: "b", label: "B", root: "/b", paths: ["/b"])]]
        func row(_ id: String, _ cwd: String, _ state: SessionPRStatus.State?) -> SessionSummary {
            var row = SessionSummary(id: id, profile: "default", title: id, preview: nil, lastActive: nil,
                                     source: nil, unread: false, isRunning: false)
            row.cwd = cwd
            row.pullRequest = state.map { SessionPRStatus(state: $0) }
            return row
        }
        var archived = row("merged", "/a", .merged); archived.archived = true
        var checking = row("checking", "/a", .unknown)
        checking.pullRequest?.unknownReason = .checking
        let rows = [row("none", "/a", SessionPRStatus.State.none), row("open", "/a/sub", .open), archived, archived,
                    row("other", "/b", .open), row("unknown", "/a", .unknown), checking, row("unqueried", "/a", nil),
                    row("draft", "/a", .draft), row("closed", "/a", .closed)]
        let counts = ProjectPageHeader.pullRequestCounts(rows, project: "/a", projects: projects)
        for state in [SessionPRStatus.State.none, .draft, .open, .merged, .closed, .unknown] { #expect(counts[state] == 1) }
        #expect(ProjectPageHeader.pullRequestCounts(rows, project: "/b", projects: projects)[.open] == 1)
    }

    @Test func codingProjectPreferencesDecodeOlderAndRetainExplicitOff() throws {
        let old = try JSONDecoder().decode(SessionsDeviceState.self, from: Data("{}".utf8))
        #expect(old.codingProjects.isEmpty)
        var state = SessionsDeviceState()
        state.codingProjects = ["/a": true, "/b": false]
        let saved = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(SessionsDeviceState.self, from: saved).codingProjects == state.codingProjects)
    }

    @Test @MainActor func codingPreferenceIsScopedAndSyncsExplicitOff() {
        let dir = BotsTest.tempDirectory()
        func store(_ account: GatewayAccount) -> SessionStore {
            SessionStore(client: BotsFakeGatewayClient(), account: account, cacheDirectory: dir, timing: .fast, autoStart: false)
        }
        let first = store(.botsTestAccount)
        first.setCodingProject("/a", true)
        RosterDiskWriter.shared.flush()
        #expect(first.isCodingProject("/a") && !first.isCodingProject("/b"))
        #expect(store(.botsTestAccount).isCodingProject("/a"))
        var otherAccount = GatewayAccount.botsTestAccount
        otherAccount.id += "-other"
        #expect(!store(otherAccount).isCodingProject("/a"))
        let synced = first.syncValue()
        #expect(synced["codingProjects"]?["/a"]?.bool == true)
        first.setCodingProject("/a", false)
        first.adoptSynced(synced, merge: .rebase, base: nil)
        #expect(!first.isCodingProject("/a"))
        #expect(first.syncValue()["codingProjects"]?["/a"]?.bool == false)
        first.adoptSynced(synced, merge: .replace, base: nil)
        #expect(first.isCodingProject("/a"))
        first.adoptSynced(["sortBy": "updated"], merge: .replace, base: nil)
        #expect(first.isCodingProject("/a"), "old sync documents do not erase the setting")
    }

    /// [project-pins] Pins Stay in Project and its pins: kept per account, synced, and an old document erases neither.
    @Test @MainActor func projectOnlyPinsPersistAndSync() throws {
        let dir = BotsTest.tempDirectory()
        func store() -> SessionStore {
            SessionStore(client: BotsFakeGatewayClient(), account: .botsTestAccount, cacheDirectory: dir, timing: .fast, autoStart: false)
        }
        let chat = SessionSummary(id: "c1", profile: "default", title: "c1", preview: nil, lastActive: nil,
                                  source: nil, unread: false, isRunning: false)
        let first = store()
        #expect(!first.isProjectPinsLocal("/a"))
        first.setProjectPinsLocal("/a", true)
        first.setProjectPinned(chat, project: "/a", true)
        RosterDiskWriter.shared.flush()
        let again = store()
        #expect(again.isProjectPinsLocal("/a") && !again.isProjectPinsLocal("/b"))
        #expect(again.projectPinKeys == ["/a": ["default\u{1F}c1"]])
        let synced = first.syncValue()
        #expect(synced["projectPinsLocal"]?["/a"]?.bool == true)
        #expect(synced["projectPins"]?["/a"]?.array?.compactMap(\.string) == ["default\u{1F}c1"])
        first.setProjectPinned(chat, project: "/a", false)
        first.setProjectPinsLocal("/a", false)
        #expect(first.projectPinKeys.isEmpty)
        #expect(first.syncValue()["projectPinsLocal"]?["/a"]?.bool == false, "turning it off is carried")
        first.adoptSynced(synced, merge: .replace, base: nil)
        #expect(first.isProjectPinsLocal("/a") && first.projectPinKeys["/a"] == ["default\u{1F}c1"])
        first.adoptSynced(["sortBy": "updated"], merge: .replace, base: nil)
        #expect(first.isProjectPinsLocal("/a") && first.projectPinKeys["/a"] != nil, "old sync documents erase nothing")
        let old = try JSONDecoder().decode(SessionsDeviceState.self, from: Data("{}".utf8))
        #expect(old.projectPins.isEmpty && old.projectPinsLocal.isEmpty && old.projectSorts.isEmpty)
        // [project-sort] Sort: kept, synced, an old document erases it not.
        #expect(first.projectSort("/a") == .needsMeFirst)
        first.setProjectSort("/a", .newest)
        RosterDiskWriter.shared.flush()
        #expect(store().projectSort("/a") == .newest)
        let sorted = first.syncValue()
        #expect(sorted["projectSorts"]?["/a"]?.string == "newest")
        first.setProjectSort("/a", .needsMeFirst)
        first.adoptSynced(sorted, merge: .replace, base: nil)
        #expect(first.projectSort("/a") == .newest)
        first.adoptSynced(["sortBy": "updated"], merge: .replace, base: nil)
        #expect(first.projectSort("/a") == .newest)
    }

    /// [project-settings] Each of a project's settings: kept per account, carried by the "sessions" document (turning one
    /// off too), filled in by a rebase only where this device has set nothing, and erased by no older document.
    @Test @MainActor func projectSettingsPersistAndSync() throws {
        let dir = BotsTest.tempDirectory()
        func store() -> SessionStore {
            SessionStore(client: BotsFakeGatewayClient(), account: .botsTestAccount, cacheDirectory: dir, timing: .fast, autoStart: false)
        }
        let first = store()
        #expect(!first.isProjectKept("/a") && first.projectAutoDone("/a").isOff && first.projectNotify("/a") == .all)
        #expect(first.projectNewChat("/a").isEmpty && first.projectLook("/a").isEmpty && !first.isProjectBranchRows("/a"))
        var changes = 0
        first.onChange = { changes += 1 }
        first.setProjectKept("/a", true)
        first.setProjectAutoDone("/a", ProjectAutoDone(days: 7, onMerge: true))
        first.setProjectNotify("/a", .needsMe)
        first.setProjectNewChat("/a", ProjectNewChat(provider: "anthropic", model: "claude-sonnet-5-5", reasoning: "high"))
        first.setProjectLook("/a", ProjectLook(emoji: "🚀", color: 4))
        first.setProjectBranchRows("/a", true)
        #expect(changes == 6, "each change redraws")
        first.setProjectKept("/a", true)
        #expect(changes == 6, "the same value again changes nothing")
        first.setProjectKept(SessionProjects.homeKey, true)
        #expect(!first.isProjectKept(SessionProjects.homeKey), "Home is no project to keep chats in")
        RosterDiskWriter.shared.flush()

        let again = store()
        #expect(again.isProjectKept("/a") && !again.isProjectKept("/b") && again.keptProjects == ["/a"])
        #expect(again.projectAutoDone("/a") == ProjectAutoDone(days: 7, onMerge: true))
        #expect(again.projectNotify("/a") == .needsMe)
        #expect(again.projectNewChat("/a") == ProjectNewChat(provider: "anthropic", model: "claude-sonnet-5-5", reasoning: "high"))
        #expect(again.projectLook("/a") == ProjectLook(emoji: "🚀", color: 4) && again.projectLooks.keys.sorted() == ["/a"])
        #expect(again.isProjectBranchRows("/a"))

        let synced = first.syncValue()
        #expect(synced["projectKeep"]?["/a"]?.bool == true)
        #expect(synced["projectAutoDone"]?["/a"]?.string == "7+merged")
        #expect(synced["projectNotify"]?["/a"]?.string == "needsMe")
        #expect(synced["projectNewChat"]?["/a"]?["model"]?.string == "claude-sonnet-5-5")
        #expect(synced["projectNewChat"]?["/a"]?["provider"]?.string == "anthropic")
        #expect(synced["projectNewChat"]?["/a"]?["reasoning"]?.string == "high")
        #expect(synced["projectLooks"]?["/a"]?["emoji"]?.string == "🚀" && synced["projectLooks"]?["/a"]?["color"]?.int == 4)
        #expect(synced["projectBranchRows"]?["/a"]?.bool == true)

        // Turned off here: the document carries it, and a rebase over the older copy keeps this device's change.
        first.setProjectKept("/a", false)
        first.setProjectAutoDone("/a", ProjectAutoDone())
        first.setProjectNotify("/a", .all)
        first.setProjectNewChat("/a", ProjectNewChat())
        first.setProjectLook("/a", ProjectLook())
        first.setProjectBranchRows("/a", false)
        let off = first.syncValue()
        #expect(off["projectKeep"]?["/a"]?.bool == false && off["projectAutoDone"]?["/a"]?.string == "never")
        #expect(off["projectNotify"]?["/a"]?.string == "all" && off["projectBranchRows"]?["/a"]?.bool == false)
        #expect(off["projectNewChat"]?["/a"]?.object?.isEmpty == true && off["projectLooks"]?["/a"]?.object?.isEmpty == true)
        var parts = synced.object ?? [:]
        parts["projectKeep"] = ["/a": true, "/b": true]
        parts["projectNotify"] = ["/a": "mute", "/b": "mute"]
        parts["projectLooks"] = ["/a": ["emoji": "🚀"], "/b": ["color": 2]]
        first.adoptSynced(.object(parts), merge: .rebase, base: nil)
        #expect(!first.isProjectKept("/a") && first.isProjectKept("/b"), "a rebase only fills what this device has not set")
        #expect(first.projectNotify("/a") == .all && first.projectNotify("/b") == .mute)
        #expect(first.projectLook("/a").isEmpty && first.projectLook("/b") == ProjectLook(color: 2))
        #expect(first.projectAutoDone("/a").isOff && first.projectNewChat("/a").isEmpty && !first.isProjectBranchRows("/a"))

        // The gateway's copy replaces this one; a document from before these settings erases none of them.
        first.adoptSynced(synced, merge: .replace, base: nil)
        func whole() -> Bool {
            first.isProjectKept("/a") && first.projectAutoDone("/a") == ProjectAutoDone(days: 7, onMerge: true)
                && first.projectNotify("/a") == .needsMe && first.projectNewChat("/a").model == "claude-sonnet-5-5"
                && first.projectLook("/a") == ProjectLook(emoji: "🚀", color: 4) && first.isProjectBranchRows("/a")
        }
        #expect(whole() && !first.isProjectKept("/b"))
        first.adoptSynced(["sortBy": "updated"], merge: .replace, base: nil)
        #expect(whole(), "old sync documents erase nothing")
        let old = try JSONDecoder().decode(SessionsDeviceState.self, from: Data("{}".utf8))
        #expect(old.projectKeep.isEmpty && old.projectAutoDone.isEmpty && old.projectNotify.isEmpty && old.projectNewChat.isEmpty
                && old.projectLooks.isEmpty && old.projectBranchRows.isEmpty)

        // The merge switch counts in a coding project only.
        #expect(first.projectAutoDoneRules["/a"] == ProjectAutoDone(days: 7))
        first.setCodingProject("/a", true)
        #expect(first.projectAutoDoneRules["/a"] == ProjectAutoDone(days: 7, onMerge: true))
    }

    /// [project-branch-rows] A long branch is cut in its middle by characters (no width cap, so no gap before the dot).
    @Test func aLongBranchIsCutInItsMiddle() {
        #expect(SessionRowView.branchShown("feat/homepage-copy") == "feat/homepage-copy")
        #expect(SessionRowView.branchShown("feat/a-very-long-branch-name-for-the-pricing-page-rewrite") == "feat/a-very…age-rewrite")
    }

    /// [project-look] One emoji or validated SF Symbol (mutually exclusive), palette colour, summaries, and JSON/Codable round-trips.
    @Test func aProjectsLookHoldsOneEmojiAndAPaletteColour() throws {
        #expect(ProjectLook.oneEmoji("🚀") == "🚀" && ProjectLook.oneEmoji("🚀🌊") == "🌊" && ProjectLook.oneEmoji("  ") == nil)
        #expect(ProjectLook.oneEmoji("👩‍🚀") == "👩‍🚀", "one grapheme, however many scalars")
        #expect(ProjectLook.oneEmoji("🌊🚀", replacing: "🚀") == "🌊", "typed before the old one, the new one stands")
        #expect(ProjectLook.oneEmoji("🚀🌊", replacing: "🚀") == "🌊" && ProjectLook.oneEmoji("🚀🚀", replacing: "🚀") == "🚀")
        #expect(ProjectLook.oneEmoji("", replacing: "🚀") == nil)
        #expect(ProjectLook(emoji: "ab", color: 99) == ProjectLook(emoji: "b", color: nil))
        #expect(ProjectLook(json: ["emoji": "", "color": 3]) == ProjectLook(color: 3))
        #expect(ProjectLook(json: ProjectLook(emoji: "🌊", color: 7).json) == ProjectLook(emoji: "🌊", color: 7))

        // SF Symbol support, mutual exclusivity, validation, and sync round-trip.
        let sym = ProjectLook(symbol: "hammer.fill", color: 8)
        #expect(!sym.isEmpty && sym.emoji == nil && sym.symbol == "hammer.fill" && sym.color == 8)
        #expect(ProjectLook(json: sym.json) == sym)
        #expect(sym.json["symbol"]?.string == "hammer.fill" && sym.json["emoji"] == nil && sym.json["color"]?.int == 8)
        let both = ProjectLook(emoji: "🚀", symbol: "hammer.fill", color: 2)
        #expect(both.emoji == "🚀" && both.symbol == nil, "emoji and symbol are mutually exclusive")
        #expect(ProjectLook.cleanSymbol("  globe  ") == "globe")
        #expect(ProjectLook.cleanSymbol("bad name!") == nil && ProjectLook.cleanSymbol("") == nil)
        #expect(ProjectLook().summaryLabel == "Default Folder")
        #expect(ProjectLook(color: 6).summaryLabel == "Teal Folder")
        #expect(ProjectLook(emoji: "🚀", color: 6).summaryLabel == "🚀 · Teal")
        #expect(ProjectLook(symbol: "hammer.fill", color: 8).summaryLabel == "Tools · Blue")
        #expect(!ProjectLook.emojis.isEmpty && !ProjectLook.symbols.isEmpty)
        let legacy = try JSONDecoder().decode(ProjectLook.self, from: Data(#"{"emoji":"🌊","color":5}"#.utf8))
        #expect(legacy == ProjectLook(emoji: "🌊", color: 5))
    }

    /// [project-new-chat-model] What a project's New Chat adds to `session.create`: nothing when nothing was chosen (the
    /// call is today's exactly), the model with its provider, the reasoning level on its own.
    @Test func aProjectsNewChatChoiceShapesSessionCreate() {
        #expect(ProjectNewChat().createParams.isEmpty)
        #expect(ProjectNewChat(provider: "anthropic", model: "claude-sonnet-5-5").createParams
                == ["model": "claude-sonnet-5-5", "provider": "anthropic"])
        #expect(ProjectNewChat(reasoning: "high").createParams == ["reasoning_effort": "high"])
        #expect(ProjectNewChat(provider: "anthropic", model: nil, reasoning: nil).createParams.isEmpty, "a provider alone names nothing")
        let base: [String: JSONValue] = ["profile": "default", "follow_profile_config": true]
        let plain = SessionCreate.params(base, profile: "default", folder: "/a")
        #expect(SessionCreate.params(base.merging(ProjectNewChat().createParams) { _, new in new }, profile: "default", folder: "/a") == plain)
        let chosen = SessionCreate.params(base.merging(ProjectNewChat(provider: "anthropic", model: "claude-sonnet-5-5", reasoning: "low").createParams) { _, new in new },
                                          profile: "default", folder: "/a")
        #expect(chosen["model"]?.string == "claude-sonnet-5-5" && chosen["provider"]?.string == "anthropic")
        #expect(chosen["reasoning_effort"]?.string == "low" && chosen["cwd"]?.string == "/a" && chosen["follow_profile_config"]?.bool == true)
        #expect(ProjectNewChat(json: ["provider": "anthropic"]).isEmpty && ProjectNewChat(json: ["model": "m", "provider": "p"]).provider == "p")
    }
}
