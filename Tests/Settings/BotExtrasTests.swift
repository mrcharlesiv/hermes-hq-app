// Bots row and Bot Info extras (docs/parity-240.md §3): mute durations, values and expiry, the mute store, the alert
// filter (local and in the notification extension), menu and swipe visibility rules, Duplicate's name and look, Delete's
// call and fence, and the recent chats Bot Info lists.

import Foundation
import Testing
import UserNotifications
@testable import HermesHQNative

private let utc = TimeZone(identifier: "UTC")!
private let us = Locale(identifier: "en_US")
/// 2026-10-11 12:00:00 UTC (a Sunday).
private let noon = Date(timeIntervalSince1970: 1_791_720_000)

@Suite struct BotMuteRuleTests {
    @Test func durationsMakeTheirMutes() {
        #expect(MuteChoice.off.mute(from: noon) == nil)
        #expect(MuteChoice.hour.mute(from: noon) == BotMute(always: false, until: noon.addingTimeInterval(3600)))
        #expect(MuteChoice.hours8.mute(from: noon) == BotMute(always: false, until: noon.addingTimeInterval(8 * 3600)))
        #expect(MuteChoice.week.mute(from: noon) == BotMute(always: false, until: noon.addingTimeInterval(7 * 24 * 3600)))
        #expect(MuteChoice.always.mute(from: noon) == .forever)
        #expect(MuteChoice.allCases.map(\.title) == ["Off", "For 1 Hour", "For 8 Hours", "For 1 Week", "Always"])
    }

    @Test func aTimedMuteEndsOnItsOwn() {
        let mute = MuteChoice.hour.mute(from: noon)!
        #expect(mute.live(noon.addingTimeInterval(3599)))
        #expect(!mute.live(noon.addingTimeInterval(3600)))
        #expect(BotMute.forever.live(.distantFuture))
        #expect(BotMutes.mute(["k": mute], "k", now: noon.addingTimeInterval(4000)) == nil)
    }

    @Test func valuesReadAsInfoShowsThem() {
        #expect(BotMutes.value(nil, now: noon) == "Off")
        #expect(BotMutes.value(.forever, now: noon) == "Always")
        let hour = MuteChoice.hour.mute(from: noon)
        #expect(BotMutes.value(hour, now: noon, locale: us, timeZone: utc) == "Until 1:00\u{202F}PM", "the system's own time format")
        let week = MuteChoice.week.mute(from: noon)
        #expect(BotMutes.value(week, now: noon, locale: us, timeZone: utc) == "Until Sun, Oct 18")
        #expect(BotMutes.value(hour, now: noon.addingTimeInterval(7200)) == "Off", "an ended mute reads Off")
    }

    @Test func infoChecksOffOrAlwaysButNotATimedMute() {
        #expect(BotMutes.choice(nil, now: noon) == .off)
        #expect(BotMutes.choice(.forever, now: noon) == .always)
        #expect(BotMutes.choice(MuteChoice.hours8.mute(from: noon), now: noon) == nil)
    }

    @Test func aMuteSilencesFinishedRepliesOnly() {
        let key = BotMutes.key(account: "acct", profile: "Ivy")
        let mutes = [key: BotMute.forever]
        #expect(key == "acct\nivy")
        for kind in ["message.complete", "turnDone", "backgroundDone"] {
            #expect(!BotMutes.allows(kind: kind, account: "acct", profile: "ivy", mutes: mutes), "\(kind) is silenced")
        }
        for kind in ["approval.request", "approval", "input", "turnError", "credits", "plugin", ""] {
            #expect(BotMutes.allows(kind: kind, account: "acct", profile: "ivy", mutes: mutes), "\(kind) still notifies")
        }
        #expect(BotMutes.allows(kind: "turnDone", account: "other", profile: "ivy", mutes: mutes), "another gateway's Ivy")
        #expect(BotMutes.allows(kind: "turnDone", account: "acct", profile: "research", mutes: mutes))
    }

    @Test func pruneAndExpiry() {
        let a = BotMute(always: false, until: noon.addingTimeInterval(60))
        let b = BotMute(always: false, until: noon.addingTimeInterval(-1))
        let pruned = BotMutes.pruned(["a": a, "b": b, "c": .forever], now: noon)
        #expect(Set(pruned.keys) == ["a", "c"])
        #expect(BotMutes.nextExpiry(pruned, now: noon) == a.until)
        #expect(BotMutes.decode(BotMutes.encode(pruned)) == pruned)
        #expect(BotMutes.decode(Data("junk".utf8)).isEmpty)
    }
}

@MainActor @Suite(.serialized) struct BotMuteCenterTests {
    final class Memory: @unchecked Sendable { var data: Data? }

    private func center(_ memory: Memory, account: String? = "acct", suite: String) -> BotMuteCenter {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let center = BotMuteCenter(storage: .init(load: { memory.data }, save: { memory.data = $0 }), defaults: defaults)
        center.account = { account }
        return center
    }

    @Test func toggleSetsAlwaysThenOffAndTheTipOnce() {
        let memory = Memory()
        let center = center(memory, suite: "hqn.tests.mute-toggle")
        var heard = 0
        center.observe { heard += 1 }
        #expect(center.toggle("ivy"), "the first mute ever asks for the tip")
        #expect(center.mute(of: "ivy") == .forever && center.isMuted("IVY"))
        #expect(!center.allows(kind: "message.complete", profile: "ivy"))
        #expect(center.allows(kind: "approval.request", profile: "ivy"))
        #expect(BotMutes.decode(memory.data)["acct\nivy"] == .forever, "saved where the extension reads it")
        #expect(!center.toggle("ivy") && !center.isMuted("ivy"))
        #expect(memory.data == nil, "an empty list leaves nothing behind")
        center.markTipSeen()
        #expect(!center.toggle("research"), "the tip shows once")
        #expect(heard == 3)
    }

    @Test func timedMutesAndDeleteClear() {
        let memory = Memory()
        let center = center(memory, suite: "hqn.tests.mute-timed")
        var clock = noon
        center.now = { clock }
        center.set("ivy", MuteChoice.hour.mute(from: noon))
        #expect(center.isMuted("ivy"))
        clock = noon.addingTimeInterval(3601)
        #expect(!center.isMuted("ivy"), "ended")
        clock = noon
        center.set("research", .forever)
        center.clear("research")
        #expect(!center.isMuted("research"), "a deleted bot's mute goes")
    }

    @Test func mutesBelongToTheirGateway() {
        let memory = Memory()
        let a = center(memory, account: "acct-a", suite: "hqn.tests.mute-a")
        a.set("ivy", .forever)
        let b = center(memory, account: "acct-b", suite: "hqn.tests.mute-b")
        #expect(!b.isMuted("ivy"), "the same name on another gateway")
        let none = center(memory, account: nil, suite: "hqn.tests.mute-none")
        #expect(none.allows(kind: "message.complete", profile: "ivy") && !none.set("ivy", .forever))
    }
}

@Suite struct BotExtrasRuleTests {
    @Test func deleteNeverForTheDefaultBot() {
        #expect(!BotExtrasRules.canDelete(isDefault: true))
        #expect(BotExtrasRules.canDelete(isDefault: false))
        #expect(BotExtrasRules.deleteTitle("Ivy") == "Delete “Ivy”?")
        #expect(BotExtrasRules.deleteMessage("Ivy").hasPrefix("Ivy’s memory, skills, settings and chats are deleted"))
        // Audit 05-16: the group chats it leaves are named.
        #expect(!BotExtrasRules.deleteMessage("Ivy").contains("group chat"))
        #expect(BotExtrasRules.deleteMessage("Ivy", groupChats: ["Launch"]).hasSuffix(" It leaves the group chat “Launch”. This can’t be undone."))
        #expect(BotExtrasRules.deleteMessage("Ivy", groupChats: ["Launch", "Ops"]).contains(" It leaves its 2 group chats. "))
    }

    @Test func muteItemFollowsTheState() {
        #expect(BotExtrasRules.muteItem(muted: false) == ("Mute", "bell.slash.fill"))
        #expect(BotExtrasRules.muteItem(muted: true) == ("Unmute", "bell.fill"))
        #expect(BotExtrasRules.menuMuteChoices.map(\.title) == ["For 1 Hour", "For 8 Hours", "For 1 Week", "Always"],
                "the row menu's Mute offers Bot Info's durations; Off is its Unmute")
    }

    @Test func readSymbolIsOnePairForBotsAndGroupChats() {
        #expect(BotExtrasRules.readSymbol(unread: true) == "envelope.open")
        #expect(BotExtrasRules.readSymbol(unread: false) == "envelope.badge")
        #expect(BotExtrasRules.readSymbol(unread: true, filled: true) == "envelope.open.fill", "a swipe's is filled")
        #expect(BotExtrasRules.readSymbol(unread: false, filled: true) == "envelope.badge.fill")
    }

    @Test func pinMovesNeedANeighbour() {
        #expect(BotExtrasRules.pinMoves(index: 0, count: 3) == [1], "the first tile only moves later")
        #expect(BotExtrasRules.pinMoves(index: 1, count: 3) == [-1, 1])
        #expect(BotExtrasRules.pinMoves(index: 2, count: 3) == [-1], "the last only earlier")
        #expect(BotExtrasRules.pinMoves(index: 0, count: 1).isEmpty, "a lone tile has nowhere to go")
        #expect(BotExtrasRules.pinMoves(index: nil, count: 4).isEmpty, "not a tile (the Pinned section below)")
        #expect(BotExtrasRules.pinMoveTitle(-1) == "Move Earlier" && BotExtrasRules.pinMoveTitle(1) == "Move Later")
    }

    @Test func swipes() {
        #expect(BotExtrasRules.leading(unread: true, hasChat: true, pinned: false) == [.read, .pin])
        #expect(BotExtrasRules.leading(unread: false, hasChat: true, pinned: true) == [.unread, .unpin])
        #expect(BotExtrasRules.leading(unread: false, hasChat: false, pinned: false) == [.pin], "no chat yet: nothing to mark")
        #expect(BotExtrasRules.trailing(muted: false) == [.mute, .more], "Mute is the full swipe")
        #expect(BotExtrasRules.trailing(muted: true) == [.unmute, .more])
    }

    @Test func conversationRows() {
        #expect(BotExtrasRules.conversationRows(hasChat: true, unread: false, recent: 5) == ["open", "recent:0", "recent:1", "recent:2", "new-chat", "unread"])
        #expect(BotExtrasRules.conversationRows(hasChat: false, unread: false, recent: 0) == ["open", "new-chat"])
        #expect(BotExtrasRules.conversationRows(hasChat: true, unread: true, recent: 1).last == "read")
    }
}

@MainActor @Suite(.serialized) struct BotDuplicateDeleteTests {
    @Test func duplicateNames() {
        #expect(BotStore.duplicateName(of: "ivy", taken: ["ivy"]) == "ivy-2")
        #expect(BotStore.duplicateName(of: "ivy", taken: ["ivy", "ivy-2", "ivy-3"]) == "ivy-4")
        let long = String(repeating: "a", count: 64)
        let name = BotStore.duplicateName(of: long, taken: [long])
        #expect(name == String(repeating: "a", count: 62) + "-2" && name?.count == 64, "the base is cut, never the suffix")
        let full = Set((2..<100).map { "x-\($0)" })
        #expect(BotStore.duplicateName(of: "x", taken: full) == nil)
    }

    @Test func duplicateLooksLikeTheOriginalWithACopyTitle() {
        let meta: PinnedSection.Meta = ["title": "Trips", "shape": "blobatar", "chat": "s-1", "created": 17, "sectionId": "sec-work"]
        let look = BotStore.duplicateMeta(meta)
        #expect(look["title"] == "Trips (copy)" && look["shape"] == "blobatar" && look["sectionId"] == "sec-work")
        #expect(look["chat"] == nil && look["created"] == nil)
        #expect(BotStore.duplicateMeta([:])["title"] == "")
    }

    @Test func duplicateSendsCreateWithCloneFromThenTheLook() async throws {
        let gateway = MetaGateway(["default": [:], "ivy": ["title": "Trips", "sectionId": "sec-work", "sectionName": "Work", "created": 5]])
        gateway.client.on("profiles.create") { params in
            let name = params["name"]?.string ?? ""
            gateway.withLock { gateway.meta[name] = [:]; gateway.revisions[name] = [:] }
            return ["ok": true, "name": .string(name)]
        }
        let store = BotStore(client: gateway.client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: .fast)
        await BotsTest.waitUntil { store.phase == .full }
        let name = try await store.duplicateBot(name: "ivy", display: "Ivy")
        #expect(name == "ivy-2")
        let create = try #require(gateway.client.calls("profiles.create").first?.params.object)
        #expect(Set(create.keys) == ["name", "clone_from", "description"], "the contract's keys only")
        #expect(create["clone_from"] == "ivy" && create["name"] == "ivy-2")
        let written = gateway.withLock { gateway.meta["ivy-2"]?["hermes-bots"]?.object ?? [:] }
        #expect(written["title"] == "Trips (copy)" && written["sectionId"] == "sec-work" && written["created"] == nil)
        #expect(store.bots.contains { $0.id == "ivy-2" }, "the row shows at once")
    }

    @Test func deleteCallsRESTForgetsTheBotAndRefusesTheDefault() async throws {
        let gateway = MetaGateway(["default": [:], "ivy": [:], "research": [:]])
        gateway.client.onREST { method, path, _, _ in
            if method == "DELETE", path == "/api/profiles/research" {
                gateway.withLock { gateway.meta["research"] = nil; gateway.revisions["research"] = nil }
                return Data(#"{"ok":true}"#.utf8)
            }
            throw HTTPError(status: 409, body: #"{"detail":"Profile is busy"}"#)
        }
        let store = BotStore(client: gateway.client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: .fast)
        await BotsTest.waitUntil { store.phase == .full }
        #expect(store.isDefaultBot("default") && !store.isDefaultBot("ivy"))
        await #expect(throws: BotWriteError.self) { try await store.deleteBot(name: "default", display: "Hermes") }
        #expect(gateway.client.restCalls.isEmpty, "the default bot is never sent")
        try await store.deleteBot(name: "research", display: "Research")
        #expect(gateway.client.restCalls.map { "\($0.method) \($0.path)" } == ["DELETE /api/profiles/research"])
        #expect(!store.bots.contains { $0.id == "research" }, "gone at once")
        do {
            try await store.deleteBot(name: "ivy", display: "Ivy")
            Issue.record("a refused delete throws")
        } catch let error as BotWriteError {
            #expect(error.title == "Couldn’t Delete Ivy" && error.reason == "Profile is busy")
        }
        #expect(store.bots.contains { $0.id == "ivy" }, "a refused delete keeps the bot")
    }

    @Test func aRosterSentBeforeTheDeleteDoesNotBringItBack() async throws {
        let gateway = MetaGateway(["default": [:], "research": [:]])
        let store = BotStore(client: gateway.client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: .fast)
        await BotsTest.waitUntil { store.phase == .full }
        let before = Date()
        store.forgetDeleted("research")
        #expect(!store.bots.contains { $0.id == "research" })
        // An older read that still lists it (sent before the delete) is held off…
        store.profiles = (gateway.list(slim: false)["profiles"]?.array ?? []).compactMap { RosterProfile(json: $0) }
        store.rowsArrived(issuedAt: before)
        store.rebuild(force: true)
        #expect(!store.bots.contains { $0.id == "research" }, "an older read doesn't bring it back")
        // …a read sent afterwards says what is true now.
        store.rowsArrived(issuedAt: Date())
        store.rebuild(force: true)
        #expect(store.bots.contains { $0.id == "research" })
    }

    @Test func recentRowsLeaveOutTheBotChatRunsAndOtherProfiles() {
        let rows = [
            SidebarSessionRow(id: "a", profile: "ivy", title: "Old", source: "desktop", lastActive: 10),
            SidebarSessionRow(id: "bot", profile: "ivy", title: "Bot Chat", source: "desktop", lastActive: 50),
            SidebarSessionRow(id: "run", profile: "ivy", title: "Probe", source: "oneshot", lastActive: 60),
            SidebarSessionRow(id: "cron", profile: "ivy", title: "Daily", source: "cron", lastActive: 40),
            SidebarSessionRow(id: "x", profile: "research", title: "Other", source: "desktop", lastActive: 70),
            SidebarSessionRow(id: "b", profile: "Ivy", title: "New", source: "telegram", lastActive: 30),
            SidebarSessionRow(id: "c", profile: "ivy", title: "Newest", source: "desktop", lastActive: 45),
            // UX study 2026-10-19 #1: a "Bot Chat" the roster doesn't list as the bot's own is not listed twice.
            SidebarSessionRow(id: "bot2", profile: "ivy", title: " Bot Chat ", source: "desktop", lastActive: 80),
        ]
        let shown = BotStore.recentRows(rows, profile: "ivy", exclude: ["bot"], limit: 3).map(\.id)
        #expect(shown == ["c", "cron", "b"])
    }

    /// A script's "Reply with exactly ROUTE_OK" check sent as a plain terminal chat is a run, not a conversation
    /// (Alex 2026-11-08: "Reply RESUMED_ROUTE_OK" under Hermes on the Bots page).
    @Test func gatewayChecksSentAsChatsAreRuns() {
        func row(_ first: String, source: String? = "cli", messages: Int = 4, tools: Int = 0) -> SidebarSessionRow {
            var row = SidebarSessionRow(id: "r", profile: "hermes", preview: first, source: source, messageCount: messages)
            row.toolCallCount = tools
            return row
        }
        for probe in ["Do not use tools. Reply with exactly RESUMED_ROUTE_OK.", "Return ROUTE_OK", "Reply with exactly OK",
                      "Don't call tools: reply with only PONG", "say exactly: READY", "Respond with exactly the word ok."] {
            #expect(SessionRules.isBackgroundRun(row(probe)), "\(probe)")
        }
        #expect(SessionRules.isBackgroundRun(row("Reply with exactly OK", source: nil)))
        for chat in [row("Say hello to the team for me"), row("Reply to Robin's email"), row("Return the package to Amazon"),
                     row("Reply with exactly OK", source: "desktop"), row("Reply with exactly OK", source: "telegram"),
                     row("Reply with exactly OK", tools: 1), row("Reply with exactly OK", messages: 12)] {
            #expect(!SessionRules.isBackgroundRun(chat), "\(chat.preview ?? "")")
        }
        let rows = [row("Do not use tools. Reply with exactly RESUMED_ROUTE_OK."),
                    SidebarSessionRow(id: "real", profile: "hermes", preview: "Plan the trip", source: "cli", lastActive: 1)]
        #expect(BotStore.recentRows(rows, profile: "hermes", exclude: [], limit: 3).map(\.id) == ["real"])
    }
}

@Suite struct MutedPushTests {
    private static func content(_ name: String) -> UNNotificationContent {
        let data = (try? Data(contentsOf: PushFixtures.url("seal-vectors.json"))) ?? Data()
        let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let outer = ((doc["cases"] as? [[String: Any]])?.first { $0["name"] as? String == name }?["outer"] as? [String: Any]) ?? [:]
        let content = UNMutableNotificationContent()
        content.sound = .default
        content.userInfo = outer
        return content
    }

    private static var key: Data {
        let data = (try? Data(contentsOf: PushFixtures.url("seal-vectors.json"))) ?? Data()
        let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return Data(base64Encoded: doc["key"] as? String ?? "") ?? Data()
    }

    private static func process(_ name: String, mutes: [String: BotMute]) -> UNNotificationContent {
        let env = NotificationOpener.Environment(keys: { [key] }, face: { _, _ in nil }, locked: { false }, record: { _ in }, mutes: { mutes })
        return NotificationOpener.process(content(name), environment: env)
    }

    @Test func aMutedBotsReplyArrivesQuietlyAndApprovalsStillAlert() throws {
        let open = Self.process("turnDone", mutes: [:])
        let remote = try #require(open.userInfo["dispatch"] as? [String: Any])
        let account = remote["account"] as? String ?? "", profile = remote["profile"] as? String ?? ""
        #expect(open.interruptionLevel != .passive && open.sound != nil)
        let mutes = [BotMutes.key(account: account, profile: profile): BotMute.forever]
        let quiet = Self.process("turnDone", mutes: mutes)
        #expect(quiet.interruptionLevel == .passive && quiet.sound == nil, "no sound, no banner")
        #expect(quiet.body == open.body, "its words are kept for Notification Center")
        let approval = Self.process("approval", mutes: mutes)
        #expect(approval.interruptionLevel != .passive && approval.categoryIdentifier == NotificationHub.approvalCategory)
    }
}
