import Foundation
import Testing
@testable import HermesHQNative

/// The context estimate, running commands and Tapback reactions (ChatGatewayExtras.swift, polish sweep 2026-10-24).
@Suite("Chat gateway extras", .serialized)
@MainActor
struct ChatGatewayExtrasTests {
    // MARK: Context estimate

    @Test func breakdownFillsTheContextRowAsAnEstimate() throws {
        let answer: JSONValue = ["categories": [], "context_max": 200000, "context_used": 41000, "context_percent": 21,
                                 "context_estimated": true, "estimated_total": 41000, "model": "claude"]
        let estimate = try #require(ContextEstimate.decode(answer))
        #expect(estimate.contextMax == 200000 && estimate.contextUsed == 41000 && estimate.contextEstimated == true)
        #expect(estimate.total == nil)
        // No context_max (an agent not built yet): no row.
        #expect(ContextEstimate.decode(["context_max": 0, "context_used": 0]) == nil)
        #expect(ContextEstimate.decode(.null) == nil)
        // The gateway's own flag wins; missing reads as an estimate.
        #expect(ContextEstimate.decode(["context_max": 100, "context_used": 5, "context_estimated": false])?.contextEstimated == false)
        #expect(ContextEstimate.decode(["context_max": 100, "context_used": 5])?.contextEstimated == true)

        // Reported usage without context: tokens stay, the context comes from the estimate, marked "~".
        let usage = SessionUsage(total: 900, input: 800, output: 100)
        let shown = try #require(SessionUsage.shown(usage, estimate: estimate))
        #expect(shown.total == 900 && shown.contextMax == 200000)
        let rows = UsageLimitsModel.chatRows(shown)
        #expect(rows.first { $0.label == "Context" }?.value == "~21%")
        #expect(rows.first { $0.label == "Context" }?.note == "41K of 200K · 159K left")
        var source = SessionInfoSource()
        source.usage = SessionUsage.shown(nil, estimate: estimate)
        #expect(SessionInfoRows.rows(source).first { $0.label == "Context" }?.value == "~21%")
        // A report with its own context is left alone.
        let reported = SessionUsage(contextUsed: 10, contextMax: 100, contextPercent: 10)
        #expect(SessionUsage.shown(reported, estimate: estimate) == reported)
        #expect(SessionUsage.shown(nil, estimate: nil) == nil)
    }

    @Test func sessionAsksTheBreakdownOnlyWithoutContextAndStopsOnAnOldGateway() async throws {
        let h = try ChatHarness()
        h.setPage("24", rows: [])
        h.make()
        #expect(await h.open())
        let asked = ExtrasCounter()
        h.client.onCall { method, _ in
            switch method {
            case "session.usage": return ["usage": ["total": 10, "input": 8, "output": 2]]
            case "session.context_breakdown":
                asked.bump()
                return ["context_max": 1000, "context_used": 250, "context_percent": 25, "context_estimated": true]
            default: return [:]
            }
        }
        await h.session.refreshUsage()
        #expect(h.session.shownUsage?.contextPercent == 25)
        #expect(h.session.shownUsage?.total == 10)
        #expect(asked.value == 1)
        // Usage that carries its own context: no breakdown asked.
        h.session.menus.usage = SessionUsage(contextUsed: 1, contextMax: 10)
        await h.session.refreshContextEstimate()
        #expect(asked.value == 1)
        // -32601: hidden and never asked again on this chat.
        h.session.menus.usage = nil
        h.client.onCall { method, _ in
            if method == "session.context_breakdown" { asked.bump(); throw RPCError(code: -32601, message: "unknown method") }
            return [:]
        }
        await h.session.refreshContextEstimate()
        await h.session.refreshContextEstimate()
        #expect(asked.value == 2)
        #expect(h.session.menus.contextBreakdownMissing)
    }

    // MARK: Running commands

    @Test func processListDecodes() {
        let answer: JSONValue = ["processes": [
            ["session_id": "proc_1", "command": "npm test\n--watch", "status": "running", "uptime_seconds": 185,
             "output_preview": "x", "output_tail": "\n  PASS a.test.js\n\nTests: 3 passed\n"],
            ["session_id": "proc_2", "command": "", "status": "exited", "exit_code": 1, "uptime_seconds": 4000],
            ["command": "no id"],
        ]]
        let list = BackgroundProcess.list(answer)
        #expect(list.map(\.id) == ["proc_1", "proc_2"])
        #expect(list[0].title == "npm test")
        #expect(list[0].detail == "Running · 3m")
        #expect(list[0].tailLines == "PASS a.test.js\nTests: 3 passed")
        #expect(list[1].title == "Background command")
        #expect(list[1].detail == "Exited (code 1)")
        #expect(!list[1].isRunning)
        #expect(BackgroundProcess.duration(42) == "42s")
        #expect(BackgroundProcess.duration(3600) == "1h")
        #expect(BackgroundProcess.duration(3720) == "1h 2m")
        #expect(BackgroundProcess.list(.null).isEmpty)
    }

    @Test func runningCommandsListsAndStopsOne() async throws {
        let h = try ChatHarness()
        h.setPage("24", rows: [])
        h.make()
        #expect(await h.open())
        h.client.onCall { method, _ in
            switch method {
            case "process.list": return ["processes": [["session_id": "p1", "command": "sleep 99", "status": "running"],
                                                       ["session_id": "p2", "command": "done", "status": "exited"]]]
            case "process.kill": return ["status": "killed", "session_id": "p1"]
            default: return [:]
            }
        }
        let list = try #require(await h.session.runningCommands())
        #expect(list.map(\.id) == ["p1"])            // only the running ones
        try await h.session.stopCommand("p1")
        let kill = try #require(h.client.calls("process.kill").last)
        #expect(kill.params["process_id"] == "p1")
        #expect(kill.params["session_id"]?.string == h.session.runtimeSessionId)
        // An older Hermes: an empty list, and the section is not offered again.
        h.client.onCall { method, _ in
            if method == "process.list" { throw RPCError(code: -32601, message: "unknown method") }
            return [:]
        }
        #expect(await h.session.runningCommands() == [])
        #expect(!h.session.offersRunningCommands)
        #expect(await h.session.runningCommands() == nil)
    }

    // MARK: Reactions

    @Test func reactionsDecodeLeniently() {
        let list = MessageReactions.decode([
            ["emoji": "👍", "author": "agent", "at": 10],
            ["emoji": "", "author": "user"],
            ["author": "user"],
            "junk",
            ["emoji": "❤️", "author": "user", "at": 5],
            ["emoji": "😂", "author": "agent", "at": 20],     // the bot's newer one replaces its 👍
        ])
        #expect(list == [MessageReaction(emoji: "😂", author: "agent", at: 20), MessageReaction(emoji: "❤️", author: "user", at: 5)])
        #expect(MessageReactions.decode(.null).isEmpty)
        #expect(MessageReactions.decode(["emoji": "👍"]).isEmpty)
        let many = JSONValue.array((0..<500).map { i in ["emoji": "👍", "author": .string("a\(i)")] })
        #expect(MessageReactions.decode(many).count == 64)
        // On the row, in display_metadata (an object, or the JSON string an older backend sends).
        let object: [String: JSONValue] = ["display_metadata": ["reactions": [["emoji": "👍", "author": "agent"]]]]
        #expect(MessageReactions.fromRow(object).map(\.emoji) == ["👍"])
        let string: [String: JSONValue] = ["display_metadata": .string(#"{"reactions":[{"emoji":"❓","author":"user"}]}"#)]
        #expect(MessageReactions.fromRow(string).first?.isMine == true)
        #expect(MessageReactions.fromRow(["reactions": [["emoji": "‼️", "author": "agent"]]]).map(\.emoji) == ["‼️"])
        #expect(MessageReactions.fromRow([:]).isEmpty)
    }

    @Test func tapbackRules() {
        let bot = MessageReaction(emoji: "👍", author: "agent", at: 1)
        var list = MessageReactions.applying([bot], emoji: "❤️", at: 2)
        #expect(list.map(\.emoji) == ["👍", "❤️"])
        list = MessageReactions.applying(list, emoji: "😂", at: 3)                 // replaces yours
        #expect(list.map(\.emoji) == ["👍", "😂"])
        list = MessageReactions.applying(list, emoji: "😂")                         // the same again takes it off
        #expect(list == [bot])
        #expect(MessageReactions.applying([bot], emoji: nil) == [bot])            // nil: yours off, the bot's stays
        let chips = MessageReactions.chips([MessageReaction(emoji: "👍", author: "agent"), MessageReaction(emoji: "👍", author: "user"),
                                           MessageReaction(emoji: "❓", author: "other")])
        #expect(chips == [ReactionChip(emoji: "👍", count: 2, mine: true), ReactionChip(emoji: "❓", count: 1, mine: false)])
        #expect(MessageReactions.spoken([bot, MessageReaction(emoji: "❤️", author: "user")], bot: "Ivy")
                == "Reactions: Thumbs Up from Ivy, Heart from you")
        #expect(MessageReactions.quick.map(MessageReactions.name) == ["Heart", "Thumbs Up", "Thumbs Down", "Ha Ha", "Exclamation Marks", "Question Mark"])
    }

    @Test func historyRowsCarryReactionsOntoTheirMessage() throws {
        let rows: [JSONValue] = [
            ["role": "user", "content": "Ship it?", "row_id": 11, "timestamp": 100,
             "display_metadata": ["reactions": [["emoji": "👍", "author": "agent", "at": 101]]]],
            ["role": "assistant", "content": "", "row_id": 12, "timestamp": 102,
             "tool_calls": [["id": "c1", "function": ["name": "terminal", "arguments": #"{"command":"ls"}"#]]]],
            ["role": "tool", "tool_call_id": "c1", "content": "ok", "row_id": 13, "timestamp": 103],
            ["role": "assistant", "content": "Shipped.", "row_id": 14, "timestamp": 104,
             "display_metadata": .string(#"{"reactions":[{"emoji":"❤️","author":"user","at":105}]}"#)],
        ]
        let page = Hydration.fold(rows, pageSeq: 1)
        let user = try #require(page.messages.first { $0.role == .user })
        #expect(user.reactions.map(\.emoji) == ["👍"])
        #expect(user.reactionTarget == 11)
        let reply = try #require(page.messages.first { $0.role == .assistant })
        #expect(reply.reactions.map(\.emoji) == ["❤️"])
        #expect(reply.reactionTarget == 14)            // the row holding its words, like a live turn's final row
    }

    @Test func aReplyFoldedFromSeveralRowsReactsOnItsLastWords() throws {
        let rows: [JSONValue] = [
            ["role": "user", "content": "Go", "row_id": 1, "timestamp": 100],
            ["role": "assistant", "content": "Looking.", "row_id": 2, "timestamp": 101,
             "tool_calls": [["id": "c1", "function": ["name": "terminal", "arguments": #"{"command":"ls"}"#]]],
             "display_metadata": ["reactions": [["emoji": "👍", "author": "user", "at": 1]]]],
            ["role": "tool", "tool_call_id": "c1", "content": "ok", "row_id": 3, "timestamp": 102],
            ["role": "assistant", "content": "Found it.", "row_id": 4, "timestamp": 103],
        ]
        let reply = try #require(Hydration.fold(rows, pageSeq: 1).messages.first { $0.role == .assistant })
        #expect(reply.rowId == 2)
        #expect(reply.reactions.map(\.emoji) == ["👍"])
        #expect(reply.reactionTarget == 2)             // your reaction's own row, so taking it off reaches it
        let plain = rows.map { row -> JSONValue in
            guard var o = row.object else { return row }
            o["display_metadata"] = nil
            return .object(o)
        }
        #expect(Hydration.fold(plain, pageSeq: 2).messages.first { $0.role == .assistant }?.reactionTarget == 4)   // else its last words
    }

    @Test func cacheKeepsReactionsAndReadsTheOlderFormat() throws {
        var m = ChatMessage(id: "stored-row-11-user", role: .user, parts: [.text("hi")], timestamp: nil, rowId: 11)
        m.reactions = [MessageReaction(emoji: "👍", author: "agent", at: 1.5)]
        m.reactionRow = 12
        let plain = ChatMessage(id: "stored-row-13-assistant", role: .assistant, parts: [.text("yo")], timestamp: nil, rowId: 13)
        let data = TranscriptEntry(messages: [m, plain], meta: [:], savedAt: Date(timeIntervalSince1970: 9)).encoded()
        #expect(Array(data.prefix(4)) == Array("HQT5".utf8))
        let back = try TranscriptEntry.decode(data)
        #expect(back.messages[0].reactions == m.reactions && back.messages[0].reactionRow == 12)
        #expect(back.messages[1].reactions.isEmpty && back.messages[1].reactionRow == nil)
        // An HQT3 file (no message sets the reactions bit) still reads.
        var old = TranscriptEntry(messages: [plain], meta: [:], savedAt: Date(timeIntervalSince1970: 9)).encoded()
        old.replaceSubrange(0..<4, with: Array("HQT3".utf8))
        #expect(try TranscriptEntry.decode(old).messages.first?.parts == plain.parts)
    }

    @Test func reactingPaintsAtOnceAndTakesTheGatewaysList() async throws {
        let h = try ChatHarness()
        h.setPage("24", rows: [["role": "user", "content": "Ship it?", "row_id": 21, "timestamp": 100],
                               ["role": "assistant", "content": "Done.", "row_id": 22, "timestamp": 101,
                                "display_metadata": ["reactions": [["emoji": "👍", "author": "agent", "at": 1]]]]])
        h.make()
        #expect(await h.open())
        let reply = try #require(h.assistant)
        #expect(reply.reactions.map(\.emoji) == ["👍"])
        h.client.onCall { method, params in
            guard method == "message.react" else { return [:] }
            let emoji = params["emoji"]
            let list: JSONValue = emoji == .null ? [["emoji": "👍", "author": "agent", "at": 1]]
                : [["emoji": "👍", "author": "agent", "at": 1], ["emoji": emoji ?? .null, "author": "user", "at": 2]]
            return ["row_id": 22, "reactions": list]
        }
        try await h.session.react(to: reply.id, emoji: "❤️")
        let call = try #require(h.client.calls("message.react").last)
        #expect(call.params["row_id"] == .number(22))
        #expect(call.params["emoji"] == "❤️")
        #expect(call.params["author"] == "user")
        #expect(call.params["newest_role"] == nil)
        #expect(h.assistant?.reactions.map(\.emoji) == ["👍", "❤️"])
        // The same one again goes out as null (a clear), never as the emoji a second time.
        try await h.session.react(to: reply.id, emoji: "❤️")
        #expect(h.client.calls("message.react").last?.params["emoji"] == .null)
        #expect(h.assistant?.reactions.map(\.emoji) == ["👍"])
        // A refusal puts the old list back; an older Hermes hides the menu.
        h.client.onCall { method, _ in
            if method == "message.react" { throw RPCError(code: -32601, message: "unknown method") }
            return [:]
        }
        await #expect(throws: LiveChatSession.ReactError.self) { try await h.session.react(to: reply.id, emoji: "😂") }
        #expect(h.assistant?.reactions.map(\.emoji) == ["👍"])
        #expect(h.session.menus.reactionsMissing)
        #expect(!h.session.canReact(to: reply.id))
    }

    @Test func aMessageNotStoredYetReactsAsTheNewestOfItsRole() async throws {
        let h = try ChatHarness()
        h.setPage("24", rows: [])
        h.make()
        #expect(await h.open())
        let local = ChatMessage(id: "local-user-1", role: .user, parts: [.text("hi")], timestamp: Date(), rowId: nil)
        h.session.appendMessage(local)
        h.client.onCall { method, _ in
            method == "message.react" ? ["row_id": 30, "reactions": [["emoji": "❓", "author": "user", "at": 1]]] : [:]
        }
        try await h.session.react(to: local.id, emoji: "❓")
        let call = try #require(h.client.calls("message.react").last)
        #expect(call.params["newest_role"] == "user")
        #expect(call.params["row_id"] == nil)
        #expect(h.session.messages.last?.reactionTarget == 30)     // later changes address the row directly
    }

    @Test func switchGatesTheMenuAndIsWrittenToTheBotOnlyOnceTouched() async throws {
        let defaults = UserDefaults.standard
        let saved = (defaults.object(forKey: MessageReactionsPref.key), defaults.object(forKey: MessageReactionsPref.touchedKey),
                     defaults.object(forKey: MessageReactionsPref.writtenKey))
        defer {
            defaults.set(saved.0, forKey: MessageReactionsPref.key)
            defaults.set(saved.1, forKey: MessageReactionsPref.touchedKey)
            defaults.set(saved.2, forKey: MessageReactionsPref.writtenKey)
        }
        defaults.removeObject(forKey: MessageReactionsPref.key)
        defaults.removeObject(forKey: MessageReactionsPref.touchedKey)
        defaults.removeObject(forKey: MessageReactionsPref.writtenKey)
        #expect(!MessageReactionsPref.isOn)                     // default Off
        let h = try ChatHarness()
        h.setPage("24", rows: [["role": "user", "content": "Ship it?", "row_id": 21, "timestamp": 100]])
        h.make()
        #expect(await h.open())
        let id = try #require(h.lastUser?.id)
        #expect(!h.session.canReact(to: id))
        h.session.mirrorReactionsSwitch()
        #expect(h.client.calls("config.set").isEmpty)           // untouched: the gateway's own setting stands
        MessageReactionsPref.isOn = true
        #expect(MessageReactionsPref.touched)
        if h.session.connection == .ready { #expect(h.session.canReact(to: id)) }
        h.session.mirrorReactionsSwitch()
        h.session.mirrorReactionsSwitch()                       // once per value
        try? await Task.sleep(for: .milliseconds(50))
        let set = h.client.calls("config.set")
        #expect(set.count == 1)
        #expect(set.first?.params["key"] == "display.message_reactions")
        #expect(set.first?.params["value"] == "true")
        // Another chat with the same bot: written already, not again (it was every chat open, 188 a day).
        let other = try ChatHarness()
        other.setPage("24", rows: [["role": "user", "content": "Again", "row_id": 31, "timestamp": 200]])
        other.make()
        #expect(await other.open())
        other.session.mirrorReactionsSwitch()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(other.client.calls("config.set").isEmpty)
    }

    @Test func badgesFollowTheirMessageAndEndItsRun() throws {
        var mine = ChatMessage(id: "u1", role: .user, parts: [.text("one")], timestamp: Date(timeIntervalSince1970: 1000), rowId: 1)
        mine.reactions = [MessageReaction(emoji: "👍", author: "agent", at: 1)]
        let next = ChatMessage(id: "u2", role: .user, parts: [.text("two")], timestamp: Date(timeIntervalSince1970: 1010), rowId: 2)
        let input = ChatRowBuilder.Input(messages: [mine, next], isRunning: false, botName: "Ivy", expanded: [], scope: "t|d|s")
        let rows = ChatRowBuilder.build(input).filter { if case .day = $0.kind { return false }; return true }
        #expect(rows.map(\.id) == ["u1|b0", "u1|react", "u2|b0"])
        guard case .reactions(let r) = rows[1].kind, case .bubble(let first) = rows[0].kind else { Issue.record("rows"); return }
        #expect(r.mine && r.chips == [ReactionChip(emoji: "👍", count: 1, mine: false)])
        #expect(r.spoken == "Reactions: Thumbs Up from Ivy")
        #expect(!first.joinsBelow)                              // the badge ends the run: its bubble keeps its tail
        let layout = TextLayout.make(rows[1], width: 390, style: ChatStyle.make(category: .large), keep: false)
        guard case .reactions(let l) = layout.content else { Issue.record("layout"); return }
        #expect(l.chips.count == 1 && l.mineTap == nil)
        #expect(l.chips[0].frame.maxX <= 390 - ChatMetrics.sideInset)     // yours hug the trailing edge
        #expect(layout.height >= l.chips[0].frame.maxY)
    }
}

/// A count the scripted client's closures can bump.
nonisolated final class ExtrasCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func bump() { lock.withLock { n += 1 } }
}
