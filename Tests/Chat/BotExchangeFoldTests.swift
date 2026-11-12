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

        // News the other bot brought back, when this bot had asked it, is for you: it keeps its bubble, also when it
        // names the bot.
        let ask = ChatMessage(id: "a0", role: .assistant, parts: [
            .tool(ToolCall(id: "t1", name: "message_agent", title: "message_agent", argsText: #"{"target":"home","message":"Why do the scripts fail?"}"#,
                           summary: "Queued", state: .done, durationSeconds: 1)),
            .text("I've asked Home why the scripts fail."),
        ], timestamp: now.addingTimeInterval(-200), rowId: nil)
        let news = before + [m("u2", .user, "Why do the scripts fail?", -210), ask, otto,
                             m("a2", .assistant, "Home found the cause: cron scripts inherit the gateway's own path.", -60)]
        #expect(bubbles(ChatRowBuilder.build(input(news))) == ["u1|b0", "a1|b0", "u2|b0", "a2|b0"])
        // Still being written: a bubble until it ends.
        var live = chat
        live[3].isStreaming = true
        #expect(bubbles(ChatRowBuilder.build(input(live, running: true))).last == "a2|b0")
        // A region rebuild of the reply as it ends draws what a full build does.
        let ended = input(chat)
        let range = UpdateGroups.widen(3...3, input: ended)
        #expect(range.lowerBound <= 2)
    }

    /// Owner, 2026-11-11 (a bot's chat): another bot asked it for a status on its own, and the long answer, which never
    /// named that bot, drew as a bubble ("Still getting messages meant for a bot in the chat instead of in a pill"). A
    /// reply to a bot that wrote first is written to that bot: it folds with its message. Your next message's answer
    /// keeps its bubble.
    @Test func aReplyToAnotherBotsOwnRequestFolds() throws {
        func m(_ id: String, _ role: ChatMessage.Role, _ text: String, _ s: Double) -> ChatMessage {
            ChatMessage(id: id, role: role, parts: [.text(text)], timestamp: now.addingTimeInterval(s), rowId: nil)
        }
        let answer = "The image has no route, so it stays at a credential gate. The scan is still a real hold."
            + String(repeating: " The cleanup target is already archived and read; no mailbox writes were made.", count: 10)
        let chat = [
            m("u1", .user, "Are you sending anything out?", -30_000),
            m("a1", .assistant, "No. Nothing is sent without you.", -29_990),
            m("c1", .user, "[Cronjob \"daily-update\" output — scheduled job, not the user. Review it, act on anything that needs action, "
                + "and summarize for the chat.]\n\nTwo new messages.", -20_000),
            m("a2", .assistant, "Two new messages came in; neither needs you.", -19_990),
            m("d1", .user, "Message from 🤖 Home (@home): Return the image route or the exact credential gate. No user-facing progress bubble.", -100),
            m("a3", .assistant, answer, -60),
        ]
        let rows = ChatRowBuilder.build(input(chat))
        #expect(bubbles(rows) == ["u1|b0", "a1|b0", "a2|b0"], "\(rows.map(\.id))")
        let line = try #require(lines(rows).last)
        #expect(line.row.title == "With Home")
        #expect(line.row.group?.tail == "2 messages")
        let opened = members(ChatRowBuilder.build(input(chat, expanded: [line.id])))
        #expect(opened.map(\.row.title) == ["From Home", "Hermes"])

        // A short answer folds too, and your next message's answer stays.
        let short = chat.map { $0.id == "a3" ? m("a3", .assistant, "Still on hold; no route to the image.", -60) : $0 }
            + [m("u2", .user, "What is all of this for?", 0), m("a4", .assistant, "That reply was for Home, not you.", 5)]
        #expect(bubbles(ChatRowBuilder.build(input(short))) == ["u1|b0", "a1|b0", "a2|b0", "u2|b0", "a4|b0"])
    }

    /// Owner, 2026-11-11 (a bot's chat): "Is the browser blocked?" got two short answers, the first with a message to
    /// another bot. The next day that bot wrote in on its own and this bot answered it by name. Both answers sat inside
    /// "With … · 7 messages" and nothing stood under the question ("Why didn't I get a response here?"). A reply written
    /// to the other bot doesn't fold the ones before it: the last reply to you stays.
    @Test func aReplyToTheOtherBotLeavesYourAnswer() throws {
        func m(_ id: String, _ role: ChatMessage.Role, _ text: String, _ s: Double) -> ChatMessage {
            ChatMessage(id: id, role: role, parts: [.text(text)], timestamp: now.addingTimeInterval(s), rowId: nil)
        }
        let ask = ChatMessage(id: "a1", role: .assistant, parts: [
            .tool(ToolCall(id: "t1", name: "message_agent", title: "message_agent", argsText: #"{"target":"home","message":"What blocked the batch?"}"#,
                           summary: "Queued", state: .done, durationSeconds: 1)),
            .text("The site let me in; the browser tool refused the next batch. I've asked Home to find out why."),
        ], timestamp: now.addingTimeInterval(-90_000), rowId: nil)
        let report = "Home — the work is done: all 44 records are checked and matched."
            + String(repeating: " The parsing now runs apart from the browser steps, so nothing is refused.", count: 10)
        let chat = [
            m("u1", .user, "Is the browser blocked?", -90_010),
            ask,
            m("d1", .user, "Message from 🤖 Home (@home): I couldn't run that check; my model turned the request down.", -89_990),
            m("a2", .assistant, "Home couldn't run the check, so the refusal is still unexplained. I haven't retried.", -89_980),
            m("d2", .user, "Message from 🤖 Home (@home): A continuation, not a request from the owner. Finish the comparison now.", -4_000),
            m("a3", .assistant, report, -2_000),
        ]
        for style in [ToolCallStyle.bottom, .line, .header] {
            let rows = ChatRowBuilder.build(input(chat, style: style))
            #expect(bubbles(rows) == ["u1|b0", "a2|b0"], "\(style) \(rows.map(\.id))")
            let talks = lines(rows).filter { $0.row.title == "With Home" }
            #expect(talks.map { $0.row.group?.titles ?? [] } == [["To Home", "Hermes", "From Home"], ["From Home", "Hermes"]], "\(style)")
            // Your answer sits between the two lines, right under the first.
            let at = try #require(rows.firstIndex { $0.id == "a2|b0" })
            #expect(rows[at - 1].id == talks.first?.id && rows[at + 1 ..< rows.count].contains { $0.id == talks.last?.id })
        }
        // A later reply that is to you folds the earlier ones, as before.
        let news = chat.map { $0.id == "a3" ? m("a3", .assistant, "Home finished the comparison: all 44 records match.", -2_000) : $0 }
        #expect(bubbles(ChatRowBuilder.build(input(news))) == ["u1|b0", "a3|b0"])
        // While the reply to Home is being written it is a bubble; as it ends, a rebuild of it alone draws what a full
        // build does (your answer comes back out of the line).
        func ids(_ rows: [ChatRow]) -> [String] { rows.map { "\($0.id)#\($0.fingerprint)#\($0.variant)#\($0.gapAbove)" } }
        var live = chat
        live[5].isStreaming = true
        var model = ChatRowModel()
        model.rebuildAll(input(live, running: true), syncMessages: 100, oldestShown: nil)
        #expect(model.allRows.contains { $0.id == "a3|b0" } && !model.allRows.contains { $0.id == "a2|b0" })
        model.rebuildMessages(input(chat), 5...5)
        #expect(ids(model.allRows.reversed()) == ids(ChatRowBuilder.build(input(chat))))
        // Two replies to the other bot in a row: the reply to you before them both still comes back.
        let more = chat + [m("d3", .user, "Message from 🤖 Home (@home): Send me the counts too.", -1_000),
                           m("a4", .assistant, "Home, the counts: 22 and 22." + String(repeating: " None are left open.", count: 40), -900)]
        var liveMore = more
        liveMore[7].isStreaming = true
        var second = ChatRowModel()
        second.rebuildAll(input(liveMore, running: true), syncMessages: 100, oldestShown: nil)
        second.rebuildMessages(input(more), 7...7)
        #expect(ids(second.allRows.reversed()) == ids(ChatRowBuilder.build(input(more))))
        #expect(bubbles(ChatRowBuilder.build(input(more))) == ["u1|b0", "a2|b0"])
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

    /// What Hermes said before it began talking with another bot keeps its bubble. Its reply to a bot that wrote in
    /// unasked is written to that bot: it folds with that bot's message (owner, 2026-11-11: "Still getting messages
    /// meant for a bot in the chat instead of in a pill").
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
        #expect(bubbles(rows) == ["u|b0", "a|b0"])
        #expect(lines(rows).map { $0.row.group?.titles ?? [] } == [["From Home", "Hermes"]])

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

    /// Your message's turn failed, and the next day another bot wrote in and was answered: the failure's note is the
    /// only answer your message got, so it stays under it; only the bots' talk folds (owner, 2026-11-12).
    @Test func aFailedTurnsNoteStaysUnderYourMessage() throws {
        let day = 86_400.0, t0 = 1_790_000_000.0
        let stored: [JSONValue] = [
            ["id": 1, "role": "user", "content": "Add the new ceiling light.", "timestamp": .number(t0)],
            ["id": 2, "role": "assistant", "display_kind": "failed_turn", "timestamp": .number(t0 + 10),
             "content": "Your request was not processed. Send it again if you still want me to carry it out."],
            ["id": 3, "role": "user", "display_kind": "internal_notification", "timestamp": .number(t0 + 4 * day),
             "content": "Message from 🤖 Home (@home): Please check the side door."],
            ["id": 4, "role": "assistant", "content": "The side door is open.", "timestamp": .number(t0 + 4 * day + 20)],
            ["id": 5, "role": "user", "display_kind": "internal_notification", "timestamp": .number(t0 + 4 * day + 40),
             "content": "Message from 🤖 Home (@home): Please close it."],
            ["id": 6, "role": "assistant", "content": "The side door is closed.", "timestamp": .number(t0 + 4 * day + 60)],
        ]
        for style in [ToolCallStyle.bottom, .line, .header] {
            let rows = ChatRowBuilder.build(input(Hydration.fold(stored).messages, style: style))
            let notes = rows.compactMap { if case .notice(let words) = $0.kind { return words } else { return nil } }
            #expect(notes.count == 1 && notes[0].hasPrefix("Your request was not processed."), "\(style) \(rows.map(\.id))")
            let found = lines(rows)
            #expect(found.count == 1 && found[0].row.title == "With Home" && found[0].row.group?.count == 4, "\(style) \(found.map(\.row.title))")
            let note = try #require(rows.firstIndex { if case .notice = $0.kind { return true } else { return false } })
            #expect(rows[..<note].contains { $0.isBubble } && rows[note...].filter(\.isBubble).isEmpty)
        }
    }
}
