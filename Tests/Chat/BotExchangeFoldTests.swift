import Foundation
import Testing
@testable import HermesHQNative

/// [exchange] Once the bot starts talking with another bot after your message, its replies to you fold into the run's
/// line with the bots' messages while the talk goes on (owner, 2026-10-29: "the entire exchange needs to be in the
/// little expandable things … none of it mattered until the final message"). Its replies after the bots' last message
/// stay: the answer is one of them ("never got an actual response from Hermes regarding what I sent in the voice memo").
@MainActor
struct BotExchangeFoldTests {
    private static func head(_ color: String) -> JSONValue {
        .object(["v": .number(6), "theme": .string("shape"), "color": .string(color), "form": .string("round"), "tile": .string("none")])
    }
    private static let roster = [
        DeliveryMessages.Seat(profile: "default", name: "Hermes", head: head("butter")),
        DeliveryMessages.Seat(profile: "home", name: "Home", head: head("mint")),
        DeliveryMessages.Seat(profile: "app", name: "App", head: head("coral")),
    ]

    private func input(_ raw: [ChatMessage], expanded: Set<String> = [], style: ToolCallStyle = .bottom,
                       running: Bool = false) -> ChatRowBuilder.Input {
        var messages = DeliveryMessages.resolve(raw, roster: Self.roster).messages
        messages = BotDMs.resolve(messages, roster: Self.roster).messages
        messages = CronDeliveries.resolve(messages, roster: Self.roster, own: Self.roster[0]).messages
        messages = TimelineNotes.resolve(messages)
        var input = ChatRowBuilder.Input(messages: messages, isRunning: running, botName: "Hermes", expanded: expanded, scope: "t")
        input.bots = Self.roster
        input.ownFace = ChatSender(key: "default", name: "Hermes", head: Self.head("butter"), profile: "default", colorHex: nil)
        input.activity.style = style
        return input
    }

    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var flowers: [ChatMessage] { FakeChatSession.botExchangeThread(now: now) }
    /// The same chat until 1:23: Hermes's answer about the flowers, a job's report, your next message and its answer.
    private var afternoon: [ChatMessage] {
        FakeChatSession.botExchangeThread(now: now.addingTimeInterval(-35 * 60)) + FakeChatSession.botExchangeFollowUp(now: now)
    }

    private func lines(_ rows: [ChatRow]) -> [(id: String, row: BackgroundResultRow)] {
        rows.compactMap { if case .backgroundResult(let b) = $0.kind { return ($0.id, b) } else { return nil } }
    }

    private func members(_ rows: [ChatRow]) -> [(id: String, row: UpdateMemberRow, message: String)] {
        rows.compactMap { if case .updateMember(let m) = $0.kind { return ($0.id, m, $0.messageId) } else { return nil } }
    }

    private func bubbles(_ rows: [ChatRow]) -> [String] { rows.filter(\.isBubble).map(\.id) }

    private func faceNames(_ group: UpdatesGroup?) -> [String] {
        (group?.marks ?? []).compactMap { if case .face(let f) = $0 { return f.name } else { return nil } }
    }

    /// The owner's chat: your two messages, Hermes's answer before the flowers, one line for the whole exchange, and
    /// Hermes's last update. Nothing else.
    @Test func flowerWatchFoldsToOneLineAndTheLastReply() throws {
        for style in [ToolCallStyle.bottom, .line, .header] {
            let rows = ChatRowBuilder.build(input(flowers, style: style))
            #expect(bubbles(rows) == ["fx-u1|b0", "fx-a0|b0", "fx-u2|b0", "fx-a7|b1"], "\(style)")
            let found = lines(rows)
            #expect(found.map(\.id) == ["fx-a1|grp"], "\(style) \(rows.map(\.id))")
            let line = try #require(found.first)
            #expect(line.row.title == "With Home and App")
            // 6 replies of Hermes's, 6 of its messages to Home and App, 6 of theirs back.
            #expect(line.row.group?.count == 18 && line.row.group?.tail == "18 messages")
            // The bots it talked with lead; Hermes's own face isn't one of the marks.
            #expect(faceNames(line.row.group) == ["Home", "App"])
            // The line sits right under your message, the last update right under it.
            let at = try #require(rows.firstIndex { $0.id == line.id })
            #expect(rows[at - 1].id == "fx-u2|b0" && rows[at + 1].id == "fx-a7|b1")
        }
    }

    /// The owner's afternoon, where build 464 showed neither answer: Hermes's answer about the flowers stays right under
    /// the exchange; the weekly review a job reported at 1:01 keeps its own replies; after your 1:21 message, Hermes's
    /// answer stays, with the short note it wrote after Home's runner ended.
    @Test func answersStayAfterTheTalk() throws {
        for style in [ToolCallStyle.bottom, .line, .header] {
            let rows = ChatRowBuilder.build(input(afternoon, style: style))
            #expect(bubbles(rows) == ["fx-u1|b0", "fx-a0|b0", "fx-u2|b0", "fx-a8|b0", "fx-a9|b2", "fx-a10|b0", "fx-u3|b0",
                                      "fx-a12|b0", "fx-a13|b0"], "\(style) \(rows.map(\.id))")
            let talks = lines(rows).filter { $0.row.title.hasPrefix("With ") }
            #expect(talks.map(\.id) == ["fx-a1|grp", "fx-a11|grp"], "\(style)")
            #expect(talks.map(\.row.title) == ["With Home and App", "With Home"])
            #expect(talks.map { $0.row.group?.count } == [20, 3])
            #expect(talks.map { $0.row.group?.tail } == ["20 messages", "3 messages"])
            let flowers = try #require(rows.firstIndex { $0.id == "fx-a1|grp" })
            #expect(rows[flowers + 1].id == "fx-a8|b0")
            let asked = try #require(rows.firstIndex { $0.id == "fx-a11|grp" })
            #expect(rows[asked - 1].id == "fx-u3|b0" && rows[asked + 1].id == "fx-a12|b0")
            // The job's report isn't part of the talk before it.
            let built = input(afternoon, style: style)
            let report = try #require(built.messages.firstIndex { $0.id == "fx-c1" })
            #expect(rows.contains { $0.id == "fx-c1|cr" } || UpdateGroups.opening(rowId: "fx-c1|cr", message: report, input: built) != nil)
            #expect(UpdateGroups.opening(rowId: "fx-c1|cr", message: report, input: built)?.line != "fx-a1|grp")
        }
    }

    /// A scheduled job's report ends a talk: the reply before it stays, and the turn it starts keeps its words even when
    /// the bot then messages another bot again.
    @Test func aJobsReportEndsTheTalk() {
        let at = now
        func you(_ id: String, _ text: String, _ s: Double) -> ChatMessage {
            ChatMessage(id: id, role: .user, parts: [.text(text)], timestamp: at.addingTimeInterval(s), rowId: nil)
        }
        func bot(_ id: String, _ parts: [ChatPart], _ s: Double) -> ChatMessage {
            ChatMessage(id: id, role: .assistant, parts: parts, timestamp: at.addingTimeInterval(s), rowId: nil)
        }
        func to(_ id: String, _ text: String) -> ChatPart {
            .tool(ToolCall(id: id, name: "message_agent", title: "message_agent", argsText: #"{"target":"home","message":"\#(text)"}"#,
                           summary: "Queued", state: .done, durationSeconds: 1))
        }
        let report = "[Cronjob \"weekly-check\" output — scheduled job, not the user. Review it, act on anything that needs action, "
            + "and summarize for the chat.]\n\nThe weekly review ran, but its delivery failed verification."
        let thread = [
            you("u", "Watch for the flowers", 0),
            bot("a", [to("t1", "Watch the door"), .text("Asked Home.")], 5),
            you("d", "Message from 🤖 Home (@home): Watching.", 60),
            bot("b", [.text("Home is watching; no flowers yet.")], 65),
            you("c", report, 120),
            bot("e", [.text("The weekly review is paused.")], 125),
            bot("f", [to("t2", "Is the camera up?"), .text("Asking Home about the camera.")], 130),
            you("d2", "Message from 🤖 Home (@home): Camera is up.", 180),
            bot("g", [.text("Home says the camera is up.")], 185),
        ]
        let rows = ChatRowBuilder.build(input(thread))
        #expect(bubbles(rows) == ["u|b0", "b|b0", "e|b0", "g|b0"], "\(rows.map(\.id))")
        // Without the report it was all one talk.
        let one = ChatRowBuilder.build(input(thread.filter { $0.id != "c" }))
        #expect(bubbles(one) == ["u|b0", "g|b0"], "\(one.map(\.id))")
    }

    /// The owner's chat, 2026-10-31 9:01: "Voice to text model still sucks…" got a long answer that also messaged two
    /// bots; their replies brought two shorter notes. The answer keeps its bubble, the notes after it fold, the last stays.
    @Test func aLongAnswerStaysWhenItStartsATalk() {
        func you(_ id: String, _ text: String, _ s: Double) -> ChatMessage {
            ChatMessage(id: id, role: .user, parts: [.text(text)], timestamp: now.addingTimeInterval(s), rowId: nil)
        }
        func bot(_ id: String, _ parts: [ChatPart], _ s: Double) -> ChatMessage {
            ChatMessage(id: id, role: .assistant, parts: parts, timestamp: now.addingTimeInterval(s), rowId: nil)
        }
        func to(_ id: String, _ bot: String, _ text: String) -> ChatPart {
            .tool(ToolCall(id: id, name: "message_agent", title: "message_agent", argsText: #"{"target":"\#(bot)","message":"\#(text)"}"#,
                           summary: "Queued", state: .done, durationSeconds: 1))
        }
        let answer = "My mistake: earlier I upgraded voice-to-text only for this chat. Every bot has its own setting. "
            + String(repeating: "Fixed across all bots, checked on your actual memo, and sent Home the corrected words. ", count: 8)
        let thread = [
            you("u", "Voice to text model still sucks. Tried to use it with Home and it failed big time", 0),
            bot("a", [to("t1", "home", "Here is what he actually said."), to("t2", "app", "Add a top-5 list."), .text(answer)], 60),
            you("d1", "Message from 🤖 App (@app): Top-5 list added.", 90),
            bot("b", [.text("Nothing has changed for you yet; the 9:15 run should be the first with the top 5.")], 95),
            you("d2", "Message from 🤖 Home (@home): Chart sent.", 120),
            bot("c", [.text("Home sent you the chart you asked for.")], 125),
        ]
        let rows = ChatRowBuilder.build(input(thread))
        let shown = bubbles(rows).map { $0.split(separator: "|")[0] }
        #expect(shown == ["u", "a", "c"], "\(rows.map(\.id))")
        // A short answer is a note that the bot asked another bot: it folds with the talk, as the flowers' does.
        let short = thread.map { $0.id == "a" ? bot("a", [to("t1", "home", "x"), to("t2", "app", "y"), .text("Asked Home and App.")], 60) : $0 }
        #expect(bubbles(ChatRowBuilder.build(input(short))).map { $0.split(separator: "|")[0] } == ["u", "c"])
    }

    /// A message to another bot that failed (Inbox, 2026-10-29 2:09 PM: Hermes's chat "not ready", nothing sent) draws no
    /// line: the call is a failed step of the turn, as any failed tool call is (owner: "what was the purpose of the
    /// notification there? Bad UX").
    /// Owner, 2026-11-11 (Hermes's chat): Otto wrote overnight and Hermes answered it, "Thanks, Otto. Your diagnosis was
    /// right…", a long reply that drew as a bubble under "From Otto". It is written to Otto: it folds with Otto's message.
    @Test func aReplyWrittenToTheOtherBotFolds() throws {
        func m(_ id: String, _ role: ChatMessage.Role, _ text: String, _ s: Double) -> ChatMessage {
            ChatMessage(id: id, role: role, parts: [.text(text)], timestamp: now.addingTimeInterval(s), rowId: nil)
        }
        let long = String(repeating: " The cleanup step now also treats the other installs as Hermes' own.", count: 12)
        let before = [m("u1", .user, "Is the account signed in?", -30_000), m("a1", .assistant, "The account is signed in and tested.", -29_990)]
        let otto = m("d1", .user, "Message from 🤖 Home (@home): Cron scripts inherit the gateway's own path after the update.", -100)
        let chat = before + [otto, m("a2", .assistant, "Thanks, Home. Your diagnosis was right, and the fix is now in Hermes' code." + long, -60)]
        let rows = ChatRowBuilder.build(input(chat))
        #expect(bubbles(rows) == ["u1|b0", "a1|b0"])
        let line = try #require(lines(rows).last)
        #expect(line.row.title == "With Home")
        #expect(line.row.group?.tail == "2 messages")
        let opened = members(ChatRowBuilder.build(input(chat, expanded: [line.id])))
        #expect(opened.map(\.row.title) == ["From Home", "Hermes"])
        #expect(opened.last?.row.full.hasPrefix("Thanks, Home.") == true)

        // News the other bot brought is for you: it keeps its bubble, also when it names the bot.
        let news = before + [otto, m("a2", .assistant, "Home found the cause: cron scripts inherit the gateway's own path.", -60)]
        #expect(bubbles(ChatRowBuilder.build(input(news))) == ["u1|b0", "a1|b0", "a2|b0"])
        // Still being written: a bubble until it ends.
        var live = chat
        live[3].isStreaming = true
        #expect(bubbles(ChatRowBuilder.build(input(live, running: true))).last == "a2|b0")
        // A region rebuild of the reply as it ends draws what a full build does.
        let ended = input(chat)
        let range = UpdateGroups.widen(3...3, input: ended)
        #expect(range.lowerBound <= 2)
    }

    @Test func speakingToABotByName() {
        let yes = ["Thanks, Otto. Your diagnosis was right.", "Otto, the fix is in.", "@otto confirmed, keep the unset.", "**Got it, Otto** — restarting.",
                   "Understood Otto: no restart.", "Thanks otto", "Good catch, Otto, that was it."]
        let no = ["Otto found the cause.", "Thanks to Otto, it works.", "The fix is in. Thanks, Otto.", "Otto's diagnosis was right.",
                  "Good news, Otto found it.", "Thanks, Ottoline."]
        for text in yes { #expect(BotDMs.speaksTo(["Otto", "otto"], in: text), "\(text)") }
        for text in no { #expect(!BotDMs.speaksTo(["Otto", "otto"], in: text), "\(text)") }
    }

    @Test func aMessageThatWasntSentDrawsNoLine() {
        let call = ToolCall(id: "c", name: "message_agent", title: "message_agent",
                            argsText: #"{"target":"hermes","message":"Need your browser runtime oversight."}"#,
                            summary: "canonical Bot Chat target is unavailable (profile authority is not ready)", state: .failed,
                            durationSeconds: 25)
        let thread = [
            ChatMessage(id: "u", role: .user, parts: [.text("Unsubscribe me from all of them")], timestamp: now, rowId: nil),
            ChatMessage(id: "a", role: .assistant, parts: [.text("Approved for all 36. I’m starting those unsubscribes now.")],
                        timestamp: now.addingTimeInterval(60), rowId: nil),
            ChatMessage(id: "b", role: .assistant, parts: [.tool(call)], timestamp: now.addingTimeInterval(180), rowId: nil),
        ]
        // The turn's work line (its steps, the failed one with them), the tool row in Rows, nothing with steps hidden.
        let want: [ToolCallStyle: [String]] = [.bottom: ["u|day", "u|b0", "a|b0", "b|line"], .line: ["u|day", "u|b0", "a|b0", "b|line"],
                                               .header: ["u|day", "u|b0", "a|b0"], .rows: ["u|day", "u|b0", "a|b0", "b|tc"]]
        for (style, ids) in want {
            let rows = ChatRowBuilder.build(input(thread, style: style))
            #expect(rows.map(\.id) == ids, "\(style)")
            #expect(!lines(rows).contains { $0.row.sentTo }, "\(style)")
        }
    }

    /// Opened, the card reads as the exchange did: who wrote, to whom, in order, Hermes's replies under its own name
    /// and face, each opening on its whole words.
    @Test func openedCardReadsAsTheExchange() throws {
        let rows = ChatRowBuilder.build(input(flowers, expanded: ["fx-a1|grp"]))
        let found = members(rows)
        #expect(found.map(\.row.title) == [
            "To Home", "Hermes", "From Home", "To Home", "Hermes", "From Home", "To App", "To Home", "Hermes",
            "From Home", "To Home", "Hermes", "From App", "Hermes", "From Home", "Hermes", "From Home", "To Home",
        ])
        let reply = try #require(found.first { $0.id == "fx-a4|b1|in" })
        #expect(reply.message == "fx-a4")
        #expect(reply.row.preview.hasPrefix("Correction: the watch’s first scheduled run didn’t actually check the camera"))
        #expect(reply.row.full.contains("**didn’t actually check the camera**"), "it opens formatted")
        #expect(reply.row.result?.result == reply.row.full, "Copy and Read Aloud read its words")
        if case .face(let f) = reply.row.mark { #expect(f.name == "Hermes") } else { Issue.record("expected Hermes's face") }
        // The last update stays below the card.
        let last = try #require(rows.firstIndex { $0.id == found.last?.id })
        #expect(rows[last + 1].id == "fx-a7|b1")

        let opened = ChatRowBuilder.build(input(flowers, expanded: ["fx-a1|grp", "fx-a4|b1|in"]))
        #expect(members(opened).first { $0.id == "fx-a4|b1|in" }?.row.expanded == true)
        #expect(Set(opened.map(\.id)).count == opened.count)
    }

    /// Find landing on a folded reply opens its line and its card row; the last reply needs nothing opened.
    @Test func findOpensAFoldedReply() throws {
        let rowsInput = input(flowers)
        let a4 = try #require(rowsInput.messages.firstIndex { $0.id == "fx-a4" })
        let a7 = try #require(rowsInput.messages.firstIndex { $0.id == "fx-a7" })
        let open = UpdateGroups.opening(rowId: "fx-a4|b1", message: a4, input: rowsInput)
        #expect(open?.line == "fx-a1|grp" && open?.member == "fx-a4|b1|in")
        #expect(UpdateGroups.opening(rowId: "fx-a7|b1", message: a7, input: rowsInput) == nil)
        // Every bubble Find counts is drawn, or opens to a card row that is.
        let opened = ChatRowBuilder.build(input(flowers, expanded: [open?.line ?? "", open?.member ?? ""]))
        #expect(opened.contains { $0.id == "fx-a4|b1|in" })
        for unit in ChatFind.units(rowsInput.messages) {
            guard let at = rowsInput.messages.firstIndex(where: { $0.id == unit.messageId }) else { continue }
            let drawn = ChatRowBuilder.build(rowsInput).contains { $0.id == unit.rowId }
            #expect(drawn || UpdateGroups.opening(rowId: unit.rowId, message: at, input: rowsInput) != nil, "\(unit.rowId)")
        }
    }

    /// While Hermes writes its next update, the one before it folds; until then it is the last and stays.
    @Test func eachNewReplyFoldsTheOneBefore() {
        let upTo = Array(flowers.prefix(5))                    // …, the voice memo, Hermes's first update, Home's answer
        #expect(bubbles(ChatRowBuilder.build(input(upTo))).last == "fx-a1|b1")
        var writing = flowers[5]
        writing.parts = writing.parts.map { if case .text = $0 { return .text("The Home bot can") } else { return $0 } }
        writing.isStreaming = true
        let rows = ChatRowBuilder.build(input(upTo + [writing], running: true))
        #expect(bubbles(rows).suffix(2) == ["fx-u2|b0", "fx-a2|b1"])
        #expect(members(ChatRowBuilder.build(input(upTo + [writing], expanded: ["fx-a1|grp"], running: true)))
            .map(\.id).contains("fx-a1|b1|in"))
    }

    /// What Hermes said before it began talking with another bot keeps its bubble, as does a reply to you after a
    /// bot wrote in unasked.
    @Test func repliesBeforeTheTalkStay() {
        let at = now
        func you(_ id: String, _ text: String, _ s: Double) -> ChatMessage {
            ChatMessage(id: id, role: .user, parts: [.text(text)], timestamp: at.addingTimeInterval(s), rowId: nil)
        }
        let draft = "Here's the draft:\n\nHi Ivy, the flowers should arrive this afternoon."
        let thread = [
            you("u", "Write Ivy a note about the flowers", 0),
            ChatMessage(id: "a", role: .assistant, parts: [.text(draft)], timestamp: at.addingTimeInterval(5), rowId: nil),
            you("d", "Message from 🤖 Home (@home): Front door camera is back online.", 60),
            ChatMessage(id: "b", role: .assistant, parts: [.text("Noted: Home's camera is back.")], timestamp: at.addingTimeInterval(65), rowId: nil),
        ]
        let rows = ChatRowBuilder.build(input(thread))
        #expect(bubbles(rows) == ["u|b0", "a|b0", "b|b0"])
        #expect(lines(rows).map { $0.row.group?.titles ?? [] } == [["From Home"]])

        // Words before the first message to Home in the same reply stay too; the ones after it fold.
        let call = ToolCall(id: "c", name: "message_agent", title: "message_agent", argsText: #"{"target":"home","message":"Watch the door"}"#,
                            summary: "Queued", state: .done, durationSeconds: 1)
        let mixed = [
            you("u", "Watch for the flowers", 0),
            ChatMessage(id: "a", role: .assistant, parts: [.text("On it."), .tool(call), .text("Asked Home.")],
                        timestamp: at.addingTimeInterval(5), rowId: nil),
            you("d", "Message from 🤖 Home (@home): Watching.", 60),
            ChatMessage(id: "b", role: .assistant, parts: [.text("Home is watching.")], timestamp: at.addingTimeInterval(65), rowId: nil),
        ]
        let rows2 = ChatRowBuilder.build(input(mixed))
        #expect(bubbles(rows2) == ["u|b0", "a|b0", "b|b0"], "\(rows2.map(\.id))")
        #expect(lines(rows2).first?.row.group?.titles == ["To Home", "Hermes", "From Home"])
    }

    /// Your message ends the exchange: Hermes's last reply before it stays, and the next exchange folds on its own.
    @Test func yourMessageEndsTheExchange() {
        var thread = flowers
        let reply = thread.removeLast()                         // fx-a7
        thread.append(ChatMessage(id: "fx-u3", role: .user, parts: [.text("Thanks")], timestamp: now.addingTimeInterval(-60), rowId: nil))
        thread.append(reply)
        let rows = ChatRowBuilder.build(input(thread))
        #expect(bubbles(rows) == ["fx-u1|b0", "fx-a0|b0", "fx-u2|b0", "fx-a6|b0", "fx-u3|b0", "fx-a7|b1"], "\(rows.map(\.id))")
    }

    /// The model's rebuilds draw what a full build draws: messages arriving one by one (each new reply folding the one
    /// before), any one message changing, and taps on the line and its members.
    @Test func incrementalEqualsFull() {
        func ids(_ rows: [ChatRow]) -> [String] { rows.map { "\($0.id)#\($0.fingerprint)#\($0.variant)#\($0.gapAbove)" } }
        for thread in [flowers, afternoon] {
        for style in [ToolCallStyle.bottom, .line, .header] {
            for open in [Set<String>(), ["fx-a1|grp", "fx-a3|b2|in"]] {
                let full = input(thread, expanded: open, style: style)
                let want = ids(ChatRowBuilder.build(full))
                for k in 0..<thread.count {
                    var model = ChatRowModel()
                    model.rebuildAll(input(Array(thread.prefix(k)), expanded: open, style: style), syncMessages: 100, oldestShown: nil)
                    model.rebuildNewest(full, fromMessage: k)
                    #expect(ids(model.allRows.reversed()) == want, "\(style) rebuildNewest from \(k)")
                }
                for k in 0..<thread.count {
                    var before = thread
                    before[k].parts = before[k].parts.map { if case .text(let t) = $0 { return .text(t + " (draft)") } else { return $0 } }
                    var model = ChatRowModel()
                    model.rebuildAll(input(before, expanded: open, style: style), syncMessages: 100, oldestShown: nil)
                    model.rebuildMessages(full, k...k)
                    #expect(ids(model.allRows.reversed()) == want, "\(style) rebuildMessages \(k)")
                }
            }
            var open = Set<String>()
            var model = ChatRowModel()
            model.rebuildAll(input(thread, style: style), syncMessages: 100, oldestShown: nil)
            for id in ["fx-a1|grp", "fx-a4|b1|in", "fx-d3|dl|in"] {
                open.insert(id)
                let full = input(thread, expanded: open, style: style)
                guard let row = model.allRows.first(where: { $0.id == id }),
                      let k = thread.firstIndex(where: { $0.id == row.messageId }) else {
                    Issue.record("\(style): no row \(id)"); continue
                }
                model.rebuildMessages(full, k...k)
                #expect(ids(model.allRows.reversed()) == ids(ChatRowBuilder.build(full)), "\(style) toggling \(id)")
            }
        }
        }
    }

    /// Older messages paged in under the exchange draw what a full build does.
    @Test func olderMessagesPagedIn() {
        func ids(_ rows: [ChatRow]) -> [String] { rows.map { "\($0.id)#\($0.fingerprint)#\($0.variant)#\($0.gapAbove)" } }
        for all in [flowers, afternoon] {
        for split in 1..<all.count {
            for open in [Set<String>(), ["fx-a1|grp"]] {
                var model = ChatRowModel()
                model.rebuildAll(input(Array(all[split...]), expanded: open), syncMessages: 100, oldestShown: nil)
                model.reveal(model.allRows.count)
                let full = input(all, expanded: open)
                model.rebuildOldest(full, added: split)
                while let chunk = model.nextChunk(size: 50) {
                    model.appendBuilt(ChatRowBuilder.build(full, range: chunk), range: chunk, generation: model.generation, measured: true)
                }
                #expect(ids(model.allRows.reversed()) == ids(ChatRowBuilder.build(full)), "split at \(split)")
            }
        }
        }
    }
}
