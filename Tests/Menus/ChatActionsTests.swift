// The rest of the chat menus (parity 240 §5, §8): which ⋯ rows and hold-menu items show when, Find's matching and
// stepping, the rewinds' wire params and rollback, Branch, Delete, the row writes, and Export JSON. No network.

import Foundation
import Testing
@testable import HermesHQNative

// MARK: - The ⋯ rows (S:phone-chat-menu-model.ts `chatMenuModel`)

@Suite("Chat menus · ⋯ rows")
struct ChatMenuModelTests {
    private func ids(_ rows: [ChatMenuRow]) -> [ChatMenuItemID] { rows.map(\.id) }

    @Test func sessionChatOffersEverything() {
        let s = ChatMenuState()
        #expect(ids(ChatMenuModel.tiles(s)) == [.share, .find, .info])
        #expect(ids(ChatMenuModel.rows(s)) == [.pin, .unread, .rename])
        #expect(ids(ChatMenuModel.more(s)) == [.files, .changes, .branch, .export])
        #expect(ids(ChatMenuModel.danger(s)) == [.archive, .delete])
        #expect(ChatMenuModel.danger(s).last?.destructive == true)
        #expect(ChatMenuModel.danger(s).last?.title == "Delete Chat")
    }

    /// [tasks] A task's own chat (Pinned Task step 2): nothing that would cut it from its task, or start another.
    @Test func taskChatKeepsOnlyWhatLeavesItWithTheTask() {
        let s = ChatMenuState(taskChat: true)
        let ids = Set(ChatMenuModel.all(s).map(\.id))
        #expect(!ids.contains(.pin) && !ids.contains(.unread) && !ids.contains(.rename))
        #expect(!ids.contains(.branch) && !ids.contains(.archive) && !ids.contains(.delete))
        #expect(ids.isSuperset(of: [.share, .find, .info, .files, .changes, .export]))
        #expect(!ChatMenuModel.all(ChatMenuState(taskChat: true, empty: true)).contains { $0.id == .export }, "nothing to export yet")
    }

    @Test func botChatHidesRenameArchiveDelete() {
        let s = ChatMenuState(botChat: true)
        #expect(ids(ChatMenuModel.rows(s)) == [.pin, .unread])
        #expect(ChatMenuModel.danger(s).isEmpty)
        #expect(ids(ChatMenuModel.more(s)) == [.files, .changes, .branch, .export])
        #expect(!ChatMenuModel.all(s).contains { $0.id == .rename })
    }

    @Test func emptyChatOffersNothingThatActsOnMessages() {
        let s = ChatMenuState(empty: true)
        #expect(ids(ChatMenuModel.tiles(s)) == [.info])
        #expect(ids(ChatMenuModel.rows(s)) == [.pin, .rename])
        #expect(ids(ChatMenuModel.more(s)) == [.files, .changes])
        // Mark as Read stays while it is unread.
        #expect(ids(ChatMenuModel.rows(ChatMenuState(unread: true, empty: true))) == [.pin, .unread, .rename])
    }

    @Test func labelsFollowState() {
        let rows = ChatMenuModel.rows(ChatMenuState(pinned: true, unread: true))
        #expect(rows.map(\.title) == ["Unpin", "Mark as Read", "Rename…"])
        #expect(rows.map(\.symbol) == ["pin.slash", "envelope.open", "pencil"])
        #expect(ChatMenuModel.rows(ChatMenuState()).map(\.title) == ["Pin", "Mark as Unread", "Rename…"])
        #expect(ChatMenuModel.danger(ChatMenuState(archived: true)).first?.title == "Unarchive")
    }

    @Test func offlineDisablesWritesOnly() {
        let all = ChatMenuModel.all(ChatMenuState(offline: true))
        let disabled = Set(all.filter(\.disabled).map(\.id))
        #expect(disabled == [.pin, .unread, .rename, .branch, .export, .archive, .delete])
        #expect(all.filter(\.disabled).allSatisfy { $0.subtitle == "Offline" })
        #expect(all.first { $0.id == .share }?.disabled == false)
        #expect(all.first { $0.id == .files }?.disabled == false)
    }
}

// MARK: - The hold menu (S:ui-chat/message-menu.ts `messageMenuItems`)

@Suite("Chat menus · hold menu")
struct MessageMenuModelTests {
    private func ids(_ rows: [MessageMenuRow]) -> [MessageMenuItemID] { rows.map(\.id) }

    @Test func latestReply() {
        let ctx = MessageMenuContext(latest: true)
        #expect(ids(MessageMenuModel.tiles(.reply, ctx)) == [.copy, .share])
        #expect(ids(MessageMenuModel.rows(.reply, ctx)) == [.selectText, .regenerate, .branch])
    }

    @Test func olderReplyHasNoRegenerate() {
        #expect(ids(MessageMenuModel.rows(.reply, MessageMenuContext())) == [.selectText, .branch])
        #expect(ids(MessageMenuModel.rows(.reply, MessageMenuContext(steps: .show))) == [.selectText, .branch, .steps])
        #expect(MessageMenuModel.rows(.reply, MessageMenuContext(steps: .hide)).last?.title == "Hide Steps")
    }

    @Test func yourMessage() {
        let ctx = MessageMenuContext(canEdit: true, canRewind: true)
        #expect(ids(MessageMenuModel.tiles(.you, ctx)) == [.copy, .edit])
        #expect(ids(MessageMenuModel.rows(.you, ctx)) == [.selectText, .rewind])
        #expect(MessageMenuModel.rows(.you, ctx).last?.destructive == true)
        #expect(MessageMenuModel.rows(.you, ctx).last?.title == "Rewind to Here")
        #expect(ids(MessageMenuModel.tiles(.you, MessageMenuContext())) == [.copy])
        #expect(ids(MessageMenuModel.rows(.you, MessageMenuContext())) == [.selectText])
    }

    @Test func undeliveredSend() {
        let rows = MessageMenuModel.rows(.you, MessageMenuContext(undelivered: true))
        #expect(ids(rows) == [.selectText, .retry, .delete])
        #expect(rows.map(\.title) == ["Select Text", "Send Again", "Delete"])
        #expect(rows.last?.destructive == true)
    }

    @Test func streamingKeepsCopyAndSelectOnly() {
        let ctx = MessageMenuContext(latest: true, streaming: true)
        let all = MessageMenuModel.tiles(.reply, ctx) + MessageMenuModel.rows(.reply, ctx)
        #expect(all.filter { !$0.disabled }.map(\.id) == [.copy, .selectText])
        #expect(all.filter(\.disabled).allSatisfy { $0.subtitle == MessageMenuModel.stillReplying })
    }

    @Test func runningAndOfflineWait() {
        let running = MessageMenuModel.rows(.reply, MessageMenuContext(latest: true, running: true))
        #expect(running.first { $0.id == .regenerate }?.disabled == true)
        #expect(running.first { $0.id == .branch }?.subtitle == "Still Replying")
        let offline = MessageMenuModel.rows(.you, MessageMenuContext(canRewind: true, offline: true))
        #expect(offline.first { $0.id == .rewind }?.subtitle == "Offline")
        #expect(offline.first { $0.id == .selectText }?.disabled == false)
    }

    @Test func titleAndReplyMore() {
        #expect(MessageMenuModel.title(sender: "Hermes", model: nil, currentModel: nil, when: "9:14 AM") == "Hermes · 9:14 AM")
        #expect(MessageMenuModel.title(sender: "Hermes", model: "Opus 4.5", currentModel: "Sonnet 5", when: "9:14 AM") == "Hermes · Opus 4.5 · 9:14 AM")
        #expect(MessageMenuModel.title(sender: "You", model: "Sonnet 5", currentModel: "Sonnet 5", when: "") == "You")
        #expect(MessageMenuModel.replyMore(running: false, offline: false).map(\.id) == [.share, .selectText, .branch])
        #expect(MessageMenuModel.replyMore(running: true, offline: false).last?.disabled == true)
    }
}

// MARK: - Find in chat

@Suite("Chat menus · Find in chat")
struct ChatFindTests {
    static func message(_ id: String, _ role: ChatMessage.Role, _ parts: [ChatPart]) -> ChatMessage {
        ChatMessage(id: id, role: role, parts: parts, timestamp: Date(), rowId: nil)
    }

    static let messages: [ChatMessage] = [
        message("u1", .user, [.text("Can you help me plan a long weekend in Lisbon?")]),
        message("a1", .assistant, [.text("Of course. When are you going, **and** what do you enjoy?")]),
        message("s1", .system, [.text("slash:/status\nand and and")]),
        message("a2", .assistant, [.text("First part and more"), .tool(ToolCall(id: "t", name: "terminal", title: "and", state: .done)),
                                   .text("Second part: AND café")]),
    ]

    @Test func unitsMirrorBubbles() {
        let units = ChatFind.units(Self.messages)
        #expect(units.map(\.rowId) == ["u1|b0", "a1|b0", "a2|b0", "a2|b2"])
        // A reply's words as they read: no ** markers.
        #expect(units[1].text == "Of course. When are you going, and what do you enjoy?")
    }

    @Test func matchesAreCaseAndDiacriticInsensitive() {
        let found = ChatFind.matches("and", in: Self.messages)
        #expect(found.map(\.rowId) == ["a1|b0", "a2|b0", "a2|b2"])
        #expect(ChatFind.matches("CAFE", in: Self.messages).map(\.rowId) == ["a2|b2"])
        #expect(ChatFind.matches("  lisbon ", in: Self.messages).count == 1)
        #expect(ChatFind.matches("", in: Self.messages).isEmpty)
        #expect(ChatFind.matches("status", in: Self.messages).isEmpty, "slash output isn't searched")
    }

    @Test func aFoldedDeliveryIsNotSearched() {
        var delivery = Self.message("d1", .user, [.text("Pelican report from the coast")])
        delivery.sender = ChatSender(key: "ivy", name: "Ivy", head: nil, profile: "ivy")
        var cron = Self.message("c1", .user, [.text("Pelican count this morning")])
        cron.sender = ChatSender(key: "ivy", name: "Ivy", head: nil, profile: "ivy")
        cron.job = "Morning brief"
        // Deliveries and cron runs draw as folded rows, so Find can't show a match there.
        #expect(ChatFind.matches("pelican", in: [delivery, cron]).isEmpty)
        #expect(ChatFind.matches("coast", in: [delivery]).isEmpty)
    }

    @Test func occurrencesCountWithinABubble() {
        let found = ChatFind.matches("a", in: [Self.message("x", .user, [.text("a banana")])])
        #expect(found.map(\.occurrence) == [0, 1, 2, 3])
        #expect(ChatFind.nsRanges(of: "an", in: "a banana") == [NSRange(location: 3, length: 2), NSRange(location: 5, length: 2)])
        #expect(ChatFind.ranges(of: "aa", in: "aaaa").count == 2, "never overlapping")
    }

    @Test func countsAndStepping() {
        #expect(ChatFind.countText(current: 1, total: 5, query: "x") == "2 of 5")
        #expect(ChatFind.countText(current: nil, total: 0, query: "x") == "No Results")
        #expect(ChatFind.countText(current: nil, total: 0, query: "  ") == "")
        #expect(ChatFind.countText(current: nil, total: 0, query: "x", hasOlder: true) == "No Results Yet", "earlier messages not searched")
        #expect(ChatFind.countText(current: 0, total: 2, query: "x", hasOlder: true) == "1 of 2")
        #expect(ChatFind.step(4, count: 5, forward: true) == 0)
        #expect(ChatFind.step(0, count: 5, forward: false) == 4)
        #expect(ChatFind.step(nil, count: 3, forward: false) == 2)
        #expect(ChatFind.step(nil, count: 0, forward: true) == nil)
    }

    @Test func currentStaysOrStartsAtTheNewest() {
        let found = ChatFind.matches("and", in: Self.messages)
        #expect(ChatFind.keepCurrent(nil, in: found) == 2)
        #expect(ChatFind.keepCurrent(found[1], in: found) == 1)
        #expect(ChatFind.keepCurrent(ChatFindMatch(rowId: "gone|b0", messageId: "gone", occurrence: 0), in: found) == 2)
        #expect(ChatFind.keepCurrent(nil, in: []) == nil)
    }
}

// MARK: - Wire helpers

@Suite("Chat menus · rewind params, branch count, export")
struct ChatActionsWireTests {
    @Test func rewindParams() {
        let p = RewindParams.make(beforeRowId: 13, loadedRowIds: [11, 12, 13, 12, 14])
        #expect(p["truncate_before_row_id"] == 13)
        #expect(p["confirm_truncate"] == true)
        #expect(p["confirm_empty_truncate"] == true)
        #expect(p["rebind_survivor_row_ids"] == [11, 12, 13, 14])
        #expect(p["truncate_before_user_ordinal"] == nil && p["truncate_before_message_id"] == nil, "one address only (4030)")
    }

    @Test func survivorMap() {
        let map = RewindParams.survivorMap(["survivor_row_id_map": ["11": 21, "12": .null, "x": 3]])
        #expect(map.count == 2)
        #expect(map[11] == .some(21))
        #expect(map[12] == .some(nil))
        #expect(RewindParams.survivorMap(["status": "streaming"]).isEmpty)
    }

    @Test func branchCountsTextMessagesThroughTheTarget() {
        let messages = [ChatFindTests.message("u1", .user, [.text("hi")]),
                        ChatFindTests.message("n", .system, [.text("Model changed")]),
                        ChatFindTests.message("t", .assistant, [.tool(ToolCall(id: "1", name: "terminal", title: "ls", state: .done))]),
                        ChatFindTests.message("a1", .assistant, [.text("hello")]),
                        ChatFindTests.message("u2", .user, [.text("more")])]
        #expect(RewindParams.branchCount(upTo: "a1", in: messages) == 2)
        #expect(RewindParams.branchCount(upTo: "u2", in: messages) == 3)
        #expect(RewindParams.branchCount(upTo: "missing", in: messages) == nil)
    }

    @Test func exportFileName() {
        #expect(ChatExport.fileName(sessionId: "20261005_090000_menus001", title: "Trip planning!") == "trip-planning-20261005.json")
        #expect(ChatExport.fileName(sessionId: "abc", title: nil) == "session-abc.json")
        #expect(ChatExport.fileName(sessionId: "abc", title: "  ✈️  ") == "session-abc.json")
    }

    @Test func exportPayload() throws {
        let data = try ChatExport.payload(sessionId: "s1", title: "Trip", messages: [["role": "user", "content": "hi", "id": 3]],
                                          now: Date(timeIntervalSince1970: 0))
        let json = try ChatJSON.parse(data)
        #expect(json["session_id"] == "s1")
        #expect(json["title"] == "Trip")
        #expect(json["session"] == .null)
        #expect(json["message_count"] == 1)
        #expect(json["messages"]?[0]?["content"] == "hi")
        #expect(json["exported_at"]?.string?.hasPrefix("1970-01-01T00:00:00") == true)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("{\n  \"exported_at\""), "the web's key order, two-space indent")
        #expect(try ChatJSON.parse(ChatExport.payload(sessionId: "s", title: nil, messages: []))["title"] == .null)
    }

    @Test func workspaceChangesSkipDependencyFolders() {
        #expect(ChatWorkspace.excluded("node_modules/left-pad/index.js"))
        #expect(ChatWorkspace.excluded("app/build/out.o"))
        #expect(!ChatWorkspace.excluded("notes/build.md"))
        let sorted = ChatWorkspace.sorted([WorkspaceEntry(name: "b.txt", path: "/b.txt", isDirectory: false),
                                           WorkspaceEntry(name: "z", path: "/z", isDirectory: true),
                                           WorkspaceEntry(name: "a.txt", path: "/a.txt", isDirectory: false)])
        #expect(sorted.map(\.name) == ["z", "a.txt", "b.txt"])
    }
}

// MARK: - The live chat's actions against a scripted gateway

@MainActor @Suite("Chat menus · live chat actions", .serialized)
struct ChatActionsSessionTests {
    static func turn(_ f: MenusFixtureChat) {
        var u1 = ChatMessage(id: "stored-row-11-user", role: .user, parts: [.text("Hello")], timestamp: Date(), rowId: 11)
        u1.isPending = false
        let a1 = ChatMessage(id: "stored-row-12-assistant", role: .assistant, parts: [.text("Hi there")], timestamp: Date(), rowId: 12)
        let u2 = ChatMessage(id: "stored-row-13-user", role: .user, parts: [.text("Again")], timestamp: Date(), rowId: 13)
        let a2 = ChatMessage(id: "stored-row-14-assistant", role: .assistant, parts: [.text("Sure")], timestamp: Date(), rowId: 14)
        f.session.messages = [u1, a1, u2, a2]
        f.session.rebuildIndex()
    }

    @Test func rewindSendsTruncatingSubmitAndRebinds() async {
        let f = MenusFixtureChat()
        Self.turn(f)
        f.script.on("prompt.submit") { _, _ in
            ["status": "streaming", "user_row_id": 30, "survivor_row_id_map": ["11": 21, "12": 22, "13": .null, "14": .null]]
        }
        var failed: String?
        #expect(f.session.rewind(to: "stored-row-13-user") { failed = $0 })
        #expect(f.session.messages.map(\.id).prefix(2) == ["stored-row-11-user", "stored-row-12-assistant"])
        #expect(f.session.messages.count == 3)
        #expect(f.session.messages.last?.plainText == "Again" && f.session.messages.last?.isPending == true)
        #expect(await waitUntil { f.params("prompt.submit").count == 1 })
        let sent = f.params("prompt.submit")[0]
        #expect(sent["text"] == "Again")
        #expect(sent["session_id"] == .string(f.rid1))
        #expect(sent["truncate_before_row_id"] == 13)
        #expect(sent["confirm_truncate"] == true)
        #expect(sent["rebind_survivor_row_ids"] == [11, 12, 13, 14])
        #expect(await waitUntil { f.session.messages.first?.rowId == 21 })
        #expect(f.session.messages[1].rowId == 22)
        #expect(f.session.menus.wholeReloadOwed)
        #expect(f.session.menus.rewinds.isEmpty)
        #expect(failed == nil)
    }

    @Test func refusedRewindPutsTheChatBack() async {
        let f = MenusFixtureChat()
        Self.turn(f)
        f.script.on("prompt.submit") { _, _ in throw RPCError(code: 4018, message: "message no longer in session history", data: nil) }
        var failed: String?
        #expect(f.session.edit("stored-row-13-user", to: "Again, edited") { failed = $0 })
        #expect(await waitUntil { failed != nil })
        #expect(failed == "message no longer in session history")
        #expect(f.session.messages.map(\.id) == ["stored-row-11-user", "stored-row-12-assistant", "stored-row-13-user", "stored-row-14-assistant"])
        #expect(f.params("prompt.submit").first?["text"] == "Again, edited")
        #expect(!f.session.isRunning)
        #expect(!f.session.messages.contains { $0.error != nil }, "no error card for a refused rewind")
    }

    @Test func regenerateResendsTheLatestPrompt() async {
        let f = MenusFixtureChat()
        Self.turn(f)
        f.script.on("prompt.submit") { _, _ in ["status": "streaming", "user_row_id": 31] }
        #expect(f.session.regenerate { _ in })
        #expect(await waitUntil { f.params("prompt.submit").count == 1 })
        #expect(f.params("prompt.submit")[0]["text"] == "Again")
        #expect(f.params("prompt.submit")[0]["truncate_before_row_id"] == 13)
        // An unchanged edit sends nothing.
        let g = MenusFixtureChat()
        Self.turn(g)
        #expect(g.session.edit("stored-row-11-user", to: " Hello ") { _ in })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(g.params("prompt.submit").isEmpty)
    }

    @Test func whatCanBeRewound() {
        let f = MenusFixtureChat()
        Self.turn(f)
        #expect(f.session.canRewind("stored-row-11-user"))
        #expect(!f.session.canRewind("stored-row-12-assistant"))
        var memo = ChatMessage(id: "stored-row-15-user", role: .user, parts: [.text("MEDIA:/tmp/voice-memo.m4a")], timestamp: Date(), rowId: 15)
        var local = ChatMessage(id: "local-user-1", role: .user, parts: [.text("Typed")], timestamp: Date(), rowId: nil)
        local.isPending = true
        memo.isPending = false
        f.session.messages += [memo, local]
        f.session.rebuildIndex()
        #expect(!f.session.canRewind("local-user-1"), "not stored yet")
    }

    @Test func branchWholeChatAndOlderGatewayFallback() async throws {
        let f = MenusFixtureChat()
        f.session.menus.cwd = "/fixture"
        f.script.on("session.branch_stored") { _, _ in ["session_id": "beefcafe", "stored_session_id": "20261011_branch01"] }
        let result = try await f.session.branch(fromMessage: nil)
        #expect(result == ChatBranchResult(storedId: "20261011_branch01", runtimeId: "beefcafe"))
        #expect(f.params("session.branch_stored").first == ["cols": 96, "source": "desktop", "parent_session_id": "20261005_090000_menus001",
                                                             "cwd": "/fixture", "profile": "default"])
        let g = MenusFixtureChat()
        g.script.on("session.branch_stored") { _, _ in throw RPCError(code: -32601, message: "unknown method: session.branch_stored", data: nil) }
        g.script.on("session.create") { _, _ in ["session_id": "0badf00d"] }
        g.client.onRest { _, _ in Data(#"{"messages":[{"id":1,"role":"user","content":"Plan a trip"},{"id":2,"role":"assistant","content":"Sure."}],"pagination":{"limit":500,"offset":0,"returned":2}}"#.utf8) }
        let fallback = try await g.session.branch(fromMessage: nil)
        #expect(fallback.storedId == "0badf00d")
        #expect(g.params("session.create").first?["messages"] == [["role": "user", "content": "Plan a trip"], ["role": "assistant", "content": "Sure."]])
    }

    @Test func branchFromAMessageCountsThroughIt() async throws {
        let f = MenusFixtureChat()
        Self.turn(f)
        f.session.hasOlder = false
        f.client.onRest { _, _ in Data(#"{"messages":[{"id":11,"role":"user","content":"Hello"},{"id":12,"role":"assistant","content":"Hi there"},{"id":13,"role":"user","content":"Again"},{"id":14,"role":"assistant","content":"Sure"}],"pagination":{"limit":500,"offset":0,"returned":4}}"#.utf8) }
        f.script.on("session.branch") { _, _ in ["session_id": "feedface", "stored_session_id": "20261011_branch02"] }
        _ = try await f.session.branch(fromMessage: "stored-row-12-assistant")
        let sent = try #require(f.params("session.branch").first)
        #expect(sent["count"] == 2)
        #expect(sent["session_id"] == .string(f.rid1))
    }

    @Test func deleteClosesTheRuntimeThenDeletesWithTheProfile() async throws {
        let f = MenusFixtureChat()
        f.client.onRest { _, _ in Data(#"{"ok":true}"#.utf8) }
        try await f.session.deleteChat()
        #expect(f.client.calls("session.interrupt").isEmpty, "nothing running: no interrupt")
        #expect(f.params("session.close").first == ["session_id": .string(f.rid1), "profile": "default"])
        let rest = try #require(f.client.restLog.last)
        #expect(rest.path == "/api/sessions/20261005_090000_menus001")
        #expect(rest.query == [URLQueryItem(name: "profile", value: "default")])
    }

    @Test func rowWritesPatchTheSession() async throws {
        let f = MenusFixtureChat()
        f.client.onRest { path, _ in
            path.hasSuffix("/mutation-snapshot") ? Data(#"{"session_id":"20261005_090000_menus001","exists":true,"runtime_revision":4,"runtime_generation":1}"#.utf8) : Data(#"{"ok":true}"#.utf8)
        }
        try await f.session.setPinned(true)
        try await f.session.setUnread(true)
        try await f.session.setArchived(true)
        // Each write reads the revision fence first (Hermes 0.22.3+), then patches.
        #expect(f.client.restLog.map(\.path) == Array(repeating: ["/api/sessions/20261005_090000_menus001/mutation-snapshot",
                                                                   "/api/sessions/20261005_090000_menus001"], count: 3).flatMap { $0 })
        #expect(f.client.restLog.allSatisfy { $0.query == [URLQueryItem(name: "profile", value: "default")] })
    }

    @Test func exportWritesEveryRow() async throws {
        let f = MenusFixtureChat()
        f.client.onRest { _, _ in Data(#"{"messages":[{"id":1,"role":"user","content":"Plan a trip"}],"pagination":{"limit":500,"offset":0,"returned":1}}"#.utf8) }
        let (data, name) = try await f.session.exportJSON()
        #expect(name == "trip-planning-20261005.json")
        let json = try ChatJSON.parse(data)
        #expect(json["message_count"] == 1)
        #expect(json["messages"]?[0]?["content"] == "Plan a trip")
        #expect(f.client.restLog.first?.query.contains(URLQueryItem(name: "order", value: "oldest")) == true)
    }
}

@MainActor @Suite("Chat menus · unconfirmed sends", .serialized)
struct ChatUndeliveredTests {
    @Test func deleteAndSendAgain() async {
        let f = MenusFixtureChat()
        var lost = ChatMessage(id: "local-user-9", role: .user, parts: [.text("Lost on the way")], timestamp: Date(), rowId: nil)
        lost.error = LiveChatSession.unconfirmedMark
        let other = ChatMessage(id: "local-user-10", role: .user, parts: [.text("Fine")], timestamp: Date(), rowId: nil)
        f.session.messages = [lost, other]
        f.session.rebuildIndex()
        f.session.deleteUndelivered("local-user-10")
        #expect(f.session.messages.count == 2, "only an unconfirmed send can be deleted")
        f.session.deleteUndelivered("local-user-9")
        #expect(f.session.messages.map(\.id) == ["local-user-10"])
        f.session.messages = [lost]
        f.session.rebuildIndex()
        f.script.on("prompt.submit") { _, _ in ["status": "streaming", "user_row_id": 40] }
        f.session.sendAgain("local-user-9")
        #expect(!f.session.messages.contains { $0.id == "local-user-9" })
        #expect(f.session.messages.last?.plainText == "Lost on the way")
        #expect(await waitUntil { f.params("prompt.submit").first?["text"] == "Lost on the way" })
        #expect(f.params("prompt.submit").first?["truncate_before_row_id"] == nil, "a plain send")
    }
}
