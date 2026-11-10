import Foundation
import Testing
import UIKit
@testable import HermesHQNative

/// A finished subagent draws as one line that opens on its report (the desktop's BackgroundResult).
@MainActor
struct BackgroundResultRowTests {
    private let title = "Subagent Task Completed: Recover lost HermesHQ chosen logo actual bytes, don't ask user saved copy "
        + "they never saved it. Previous worker found old default session messages 'latest redraw' r1-white.png white sculpted "
        + "wing on black without blue; original paths missing. Need deeper recovery: attachment records, artifact metadata."

    private func note(_ text: String) -> ChatMessage {
        ChatMessage(id: "n1", role: .system, parts: [.text(text)], timestamp: Date(timeIntervalSince1970: 1_790_000_000), rowId: 4)
    }

    private func reply(_ id: String = "a1") -> ChatMessage {
        ChatMessage(id: id, role: .assistant, parts: [.text("Done.")], timestamp: Date(timeIntervalSince1970: 1_790_000_060), rowId: 5)
    }

    private func rows(expanded: Set<String> = [], results: [String: String], after: [ChatMessage] = [],
                      running: Bool = false) -> [ChatRow] {
        var input = ChatRowBuilder.Input(messages: [note(title)] + after, isRunning: running, botName: "App", expanded: expanded)
        input.backgroundResults = results
        return ChatRowBuilder.build(input)
    }

    private func result(_ rows: [ChatRow]) -> BackgroundResultRow? {
        for row in rows where row.id == "n1|bg" { if case .backgroundResult(let b) = row.kind { return b } }
        return nil
    }

    // [updates] No "Not read yet" on the newest result (owner, 2026-10-27: removed): the line names it, the card opens on it.
    @Test func theNewestResultSaysNothingAboutBeingRead() throws {
        let row = try #require(rows(expanded: ["n1|bg"], results: ["n1": "Found nothing."]).first { $0.id == "n1|bg" })
        let layout = TextLayout.layout(row, width: 390, style: ChatStyle.make(category: .large), keep: false)
        guard case .tool(let t) = layout.content else { Issue.record("expected a tool layout"); return }
        #expect(t.group?.tail == nil && t.meta == nil)
        let opened = t.thoughtText?.text.string ?? ""
        #expect(!opened.contains("next message") && opened.contains("Recover lost") && opened.hasSuffix("Found nothing."))
    }

    @Test func noteWithAReportIsOneToolLine() throws {
        let row = try #require(rows(results: ["n1": "Found nothing."]).first { $0.messageId == "n1" && !isDay($0) })
        guard case .backgroundResult(let b) = row.kind else { Issue.record("expected a background result row"); return }
        #expect(b.title.hasPrefix("Helper finished: Recover lost"))   // [updates] plain words
        guard case .tool(let line) = TextLayout.layout(row, width: 390, style: ChatStyle.make(category: .large), keep: false).content else {
            Issue.record("expected a tool layout"); return
        }
        #expect(line.title == "Helper finished", "[updates] only the words before the colon show")
        #expect(b.group?.count == 1, "a group of one: the centred line")
        #expect(!b.expanded)
        #expect(!b.process)
        let layout = TextLayout.layout(row, width: 390, style: ChatStyle.make(category: .large), keep: false)
        // One tool row high, not the paragraph the centred note was.
        #expect(layout.height < 60)
    }

    @Test func openedRowShowsTheReport() throws {
        let row = try #require(rows(expanded: ["n1|bg"], results: ["n1": "Found nothing."]).first { $0.id == "n1|bg" })
        guard case .backgroundResult(let b) = row.kind else { Issue.record("expected a background result row"); return }
        #expect(b.expanded)
        let layout = TextLayout.layout(row, width: 390, style: ChatStyle.make(category: .large), keep: false)
        guard case .tool(let t) = layout.content else { Issue.record("expected a tool layout"); return }
        #expect(t.thoughtText != nil)
        #expect(t.cardFrame.height > 0)
    }

    @Test func openedReportsLinksOpen() throws {
        let report = "Read [the doc](https://example.com/doc) or https://example.org/raw, not example.net."
        let row = try #require(rows(expanded: ["n1|bg"], results: ["n1": report], after: [reply()]).first { $0.id == "n1|bg" })
        let layout = TextLayout.layout(row, width: 390, style: ChatStyle.make(category: .large), keep: false)
        guard case .tool(let t) = layout.content, let text = t.thoughtText?.text else { Issue.record("expected the report"); return }
        #expect(text.string.hasSuffix("Read the doc or https://example.org/raw, not example.net."), "a Markdown link reads as its words")
        var urls: [URL] = []
        text.enumerateAttribute(.chatLink, in: NSRange(location: 0, length: text.length)) { v, _, _ in if let u = v as? URL { urls.append(u) } }
        #expect(urls.map(\.absoluteString) == ["https://example.com/doc", "https://example.org/raw"], "written-out addresses only")
    }

    @Test func noteWithoutAReportStaysANotice() {
        #expect(rows(results: [:]).contains { if case .notice = $0.kind { return true } else { return false } })
    }

    @Test func processNotesUseTheTerminalGlyph() {
        #expect(BackgroundResults.isProcess("Background Process Finished: npm test"))
        #expect(BackgroundResults.isProcess("2 Background Processes Finished"))
        #expect(!BackgroundResults.isProcess(title))
    }

    @Test func reportReadsAsPlainLines() {
        let shown = BackgroundResults.readable("## Summary\n- **found** `r1-white.png`\n* none in Trash")
        #expect(shown == "Summary\n• found r1-white.png\n• none in Trash")
        let long = BackgroundResults.readable(String(repeating: "a", count: 20_000))
        #expect(long.hasSuffix("…"))
        #expect(long.utf8.count < 12_100)
    }

    private func isDay(_ row: ChatRow) -> Bool { if case .day = row.kind { return true } else { return false } }

    // A background process's "[IMPORTANT: …]" user row (bot_mode_dm delivery): the first line, then its log behind it.
    @Test func processNoteIsItsFirstLineWithTheLogBehindIt() throws {
        let raw = "[IMPORTANT: Background process proc_74bb257e55f8 completed normally (exit code 0).\n"
            + "Command: /Users/x/python3 bot_mode_dm.py --run-delivery --author '{\"id\":\"bot:helper\"}'\n"
            + "Output:\n{\"reply\": \"@helper has your approval scope\"}]"
        let user = ChatMessage(id: "u1", role: .user, parts: [.text(raw)], timestamp: Date(timeIntervalSince1970: 1_790_000_000), rowId: 9)
        let resolved = TimelineNotes.resolve([user])
        #expect(resolved[0].role == .system)
        #expect(resolved[0].parts == [.text("Background task finished: bot_mode_dm.py --run-delivery --author…")])
        let report = try #require(resolved[0].report)
        // The gateway's own line (its id and exit code) opens first, then the command and output.
        #expect(report.hasPrefix("Background process proc_74bb257e55f8 completed normally (exit code 0).\nCommand: "))
        #expect(report.contains("approval scope"))
        let rows = ChatRowBuilder.build(.init(messages: resolved, isRunning: false, botName: "Sidehustle", expanded: []))
        let row = try #require(rows.first { $0.messageId == "u1" && !isDay($0) })
        guard case .backgroundResult(let b) = row.kind else { Issue.record("expected a background result row"); return }
        #expect(b.process)
        #expect(b.result.contains("--run-delivery"))
    }

    @Test func otherImportantNotesStayWhole() {
        let user = ChatMessage(id: "u2", role: .user, parts: [.text("[IMPORTANT: Remember the deadline.]")], timestamp: nil, rowId: 3)
        let resolved = TimelineNotes.resolve([user])
        #expect(resolved[0].parts == [.text("Remember the deadline.")])
        #expect(resolved[0].report == nil)
    }

    // MARK: Deliveries from another bot (§7.12): one line, like a finished subagent (owner, 2026-10-18)

    private func delivery(_ id: String, _ text: String, from name: String = "Inbox", at seconds: TimeInterval = 0) -> ChatMessage {
        var m = ChatMessage(id: id, role: .user, parts: [.text(text)], timestamp: Date(timeIntervalSince1970: 1_790_000_000 + seconds), rowId: nil)
        m.sender = ChatSender(key: name.lowercased(), name: name, head: nil, profile: name.lowercased())
        return m
    }

    @Test func aDeliveryIsOneLineThatOpensOnTheWholeMessage() throws {
        let long = "Three new emails need a reply.\n\nThe first is from Northwind about the overdue invoice, " + String(repeating: "more words ", count: 80)
        let messages = [delivery("d1", long)]
        let closed = ChatRowBuilder.build(.init(messages: messages, isRunning: false, botName: "Hermes", expanded: []))
        let row = try #require(closed.first { $0.messageId == "d1" && !isDay($0) })
        guard case .backgroundResult(let b) = row.kind else { Issue.record("expected a one-line row"); return }
        #expect(b.delivery && !b.process && !b.expanded)
        #expect(b.title.hasPrefix("From Inbox: Three new emails need a reply."))
        #expect(!b.title.contains("\n"))
        let style = ChatStyle.make(category: .large)
        #expect(TextLayout.layout(row, width: 390, style: style, keep: false).height < 60, "one tool row high, not a bubble")
        guard case .tool(let t) = TextLayout.layout(row, width: 390, style: style, keep: false).content else { Issue.record("tool layout"); return }
        #expect(t.glyph == .message)
        #expect(t.title == "From Inbox", "[updates] only the bot's name shows: the words before the colon")

        let opened = ChatRowBuilder.build(.init(messages: messages, isRunning: false, botName: "Hermes", expanded: [row.id]))
        let open = try #require(opened.first { $0.id == row.id })
        guard case .backgroundResult(let ob) = open.kind else { Issue.record("expected the row"); return }
        #expect(ob.expanded && ob.result.hasPrefix("Three new emails need a reply.\n\nThe first"))
        #expect(open.variant != row.variant)
    }

    @Test func theBotsOwnRepliesAfterADeliveryStayPlainBubbles() {
        let reply = ChatMessage(id: "a1", role: .assistant, parts: [.text("Thanks, I will reply first.")],
                                timestamp: Date(timeIntervalSince1970: 1_790_000_060), rowId: nil)
        let rows = ChatRowBuilder.build(.init(messages: [delivery("d1", "Lunch moved to 1 pm."), reply], isRunning: false,
                                              botName: "Hermes", expanded: []))
        let bubbles = rows.compactMap { if case .bubble(let b) = $0.kind { return b } else { return nil } }
        #expect(bubbles.count == 1)
        #expect(bubbles[0].text == "Thanks, I will reply first.")
        #expect(!bubbles[0].senderInset && bubbles[0].byline == nil, "no face column or byline for a chat whose only other sender is collapsed")
    }

    @Test func cronRunsFoldToOneLine() {
        var cron = delivery("c1", "All quiet.", from: "Ivy")
        cron.job = "Morning brief"
        let rows = ChatRowBuilder.build(.init(messages: [cron], isRunning: false, botName: "Ivy", expanded: []))
        #expect(!rows.contains { if case .bubble = $0.kind { return true } else { return false } })
        #expect(rows.contains { if case .backgroundResult(let b) = $0.kind { return b.cron && b.title == "Morning brief: All quiet." } else { return false } })
    }

    // MARK: A bot quietly taking note of a delivery or a background note has no "Nothing to report" line (owner, 2026-10-18)

    private func silent(_ id: String, at seconds: TimeInterval, tools: [ToolCall] = []) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, parts: tools.map { .tool($0) } + [.text("[SILENT]")],
                    timestamp: Date(timeIntervalSince1970: 1_790_000_000 + seconds), rowId: nil)
    }

    private func notices(_ messages: [ChatMessage], results: [String: String] = [:]) -> [ChatRow] {
        var input = ChatRowBuilder.Input(messages: TimelineNotes.resolve(messages), isRunning: false, botName: "Hermes", expanded: [])
        input.backgroundResults = results
        return ChatRowBuilder.build(input).filter { if case .notice = $0.kind { return true } else { return false } }
    }

    @Test func aSilentReplyToADeliveryDrawsNothing() {
        #expect(notices([delivery("d1", "Store is live."), silent("a1", at: 30)]).isEmpty)
        let call = ToolCall(id: "t1", name: "terminal", title: "Ran ls", argsText: "{}", summary: "ok", state: .done, durationSeconds: 1)
        let messages = [delivery("d1", "Store is live."), silent("a1", at: 30, tools: [call])]
        #expect(notices(messages).isEmpty, "nor after the steps it took")
        let input = ChatRowBuilder.Input(messages: TimelineNotes.resolve(messages), isRunning: false, botName: "Hermes", expanded: [])
        #expect(ChatRowBuilder.build(input).contains { if case .toolRun = $0.kind { return true } else { return false } }, "the steps stay")
    }

    @Test func processNotesReadInPlainWords() {
        #expect(TimelineNotes.processWords("Background process 7 finished with exit code 0.", detail: "") == "Background task finished")
        #expect(TimelineNotes.processWords("Background process 7 finished with exit code 2.", detail: "Command: npm test") == "Background task failed: npm test")
        #expect(TimelineNotes.processWords("Background process 7 was killed.", detail: "") == "Background task failed")
        #expect(TimelineNotes.processWords("Background process 7 completed.", detail: "Command: /usr/bin/make all\nOutput: ok") == "Background task finished: make all")
        #expect(TimelineNotes.processWords("Background process 7 heartbeat #3", detail: "") == nil, "no outcome: left as it is")
        // A one-line note opens on the gateway's line.
        let split = TimelineNotes.processHeadline("Background process 4412 finished with exit code 0")
        #expect(split?.headline == "Background task finished")
        #expect(split?.detail == "Background process 4412 finished with exit code 0")
        #expect(BackgroundResults.isProcess("Background task failed: npm test"))
    }

    // Owner, 2026-10-28: a background task's line read "Users/alex/.hermes/tools/python-3.14.9+…".
    @Test func commandsReadWithoutTheirFolders() {
        let python = "Command: /Users/x/.hermes/tools/python-3.14.9+2026-darwin-arm64/bin/python3 /Users/x/.hermes/scripts/report.py --week"
        #expect(TimelineNotes.shortCommand(python) == "report.py --week")
        #expect(TimelineNotes.shortCommand("Command: node ./build/serve.mjs --port 3000") == "serve.mjs --port 3000")
        #expect(TimelineNotes.shortCommand("Command: python3 -u ~/jobs/sync.py") == "sync.py")
        #expect(TimelineNotes.shortCommand("Command: python3 -c print(1)") == "python3 -c print(1)")
        #expect(TimelineNotes.shortCommand("Command: /bin/bash -c 'cd /tmp && make'") == "bash -c 'cd tmp && make'")
        #expect(TimelineNotes.shortCommand("Command: npm test") == "npm test")

        // From history: Hermes's own title is the path cut short; the note's words give the short one.
        let raw = "[IMPORTANT: Background process proc_1 completed normally (exit code 0).\n" + python + "\nOutput:\nok\n]"
        let meta: JSONValue = ["display_text": "Background Process Finished: /Users/x/.hermes/tools/python-3.14.9+2026-darwin-arm64/bin/pytho..."]
        let folded = Hydration.fold([["role": "user", "content": .string(raw), "display_kind": "process_complete",
                                      "display_metadata": meta, "id": 5, "timestamp": 1]], pageSeq: 1).messages
        #expect(folded.first?.parts == [.text("Background task finished: report.py --week")])
        #expect(BackgroundResults.plainTitle("Background task finished: report.py --week") == "report.py --week finished")
    }

    @Test func aSilentReplyToABackgroundNoteDrawsNothing() {
        let process = ChatMessage(id: "p1", role: .user,
                                  parts: [.text("[IMPORTANT: Background process proc_1 completed normally (exit code 0).\nCommand: ls\nOutput: ok]")],
                                  timestamp: Date(timeIntervalSince1970: 1_790_000_000), rowId: nil)
        #expect(notices([process, silent("a1", at: 30)]).isEmpty)
        #expect(notices([note(title), silent("a1", at: 30)], results: ["n1": "Found nothing."]).isEmpty, "a finished subagent too")
    }

    @Test func aSilentReplyToAJobCardDrawsNothing() {
        var cron = delivery("c1", "#1398 · Kenny asks for a flyer.", from: "Inbox")
        cron.job = "Inbox urgent check"
        #expect(notices([cron, silent("a1", at: 30)]).isEmpty)
    }

    @Test func aSilentRunAfterASubagentsResultOrNothingDrawsNothing() {
        let done = ChatMessage(id: "s1", role: .system, parts: [.text("Execute bounded read-only review")],
                               timestamp: Date(timeIntervalSince1970: 1_790_000_000), rowId: nil)
        #expect(notices([done, silent("a1", at: 30)]).filter { if case .notice(let t) = $0.kind { return t == Hydration.silentRunText } else { return false } }.isEmpty)
        #expect(notices([silent("a1", at: 30)]).isEmpty, "a silent run with nothing before it")
    }

    @Test func aSilentReplyToYouSaysNothing() {
        let mine = ChatMessage(id: "u1", role: .user, parts: [.text("Anything new?")],
                               timestamp: Date(timeIntervalSince1970: 1_790_000_000), rowId: nil)
        // [updates] A silent run says nothing, even when it answers you (owner, 2026-10-27).
        #expect(notices([mine, silent("a1", at: 30)]).isEmpty)
    }

    @Test func linesInARowAreOneGroup() throws {
        // [updates] Two deliveries in a row: one centred line for both.
        let rows = ChatRowBuilder.build(.init(messages: [delivery("d1", "One."), delivery("d2", "Two.", at: 30)], isRunning: false,
                                              botName: "Hermes", expanded: []))
        let line = try #require(rows.first { $0.id == "d1|grp" })
        guard case .backgroundResult(let b) = line.kind else { Issue.record("expected the group's line"); return }
        #expect(b.group?.count == 2)
        #expect(!rows.contains { $0.messageId == "d2" })

        // A silent reply between them keeps them one group.
        let quiet = TimelineNotes.resolve([delivery("d1", "One."), silent("a1", at: 10), delivery("d2", "Two.", at: 30), silent("a2", at: 40)])
        let quietRows = ChatRowBuilder.build(.init(messages: quiet, isRunning: false, botName: "Hermes", expanded: []))
        #expect(quietRows.filter { !isDay($0) }.map(\.id) == ["d1|grp"], "\(quietRows.map { "\($0.id) \($0.kind)" })")
    }

    @Test func aStandInForSilentDrawsNothingAfterADelivery() {
        // Owner, 2026-10-28: Hermes answered each Inbox delivery with "[Notification processed; no additional
        // user-facing response.]" instead of [SILENT]; three grey bubbles drew.
        let standIn = "[Notification processed; no additional user-facing response.]"
        let reply = { (id: String, at: TimeInterval) in
            ChatMessage(id: id, role: .assistant, parts: [.text(standIn)],
                        timestamp: Date(timeIntervalSince1970: 1_790_000_000 + at), rowId: nil)
        }
        let quiet = TimelineNotes.resolve([delivery("d1", "One."), reply("a1", 10), delivery("d2", "Two.", at: 30), reply("a2", 40)])
        let rows = ChatRowBuilder.build(.init(messages: quiet, isRunning: false, botName: "Hermes", expanded: []))
        #expect(!rows.contains { if case .bubble = $0.kind { return true } else { return false } }, "\(rows.map { "\($0.id) \($0.kind)" })")

        // Owner, 2026-10-28 later: "(no user-facing response)" after Herald and Inbox deliveries, round brackets this time.
        for words in [standIn, "[SILENT]", " [No reply needed] ", "[Nothing to report.]", "[no response required]",
                      "(no user-facing response)", "(No user‑facing reply.)", "*(no reply needed)*", "_[Nothing further to add.]_",
                      // Owner, 2026-11-09: a bare "NO_REPLY" under a message From Otto; the gateway's markers, as it reads them.
                      "NO_REPLY", " no_reply\n", "NO_REPLY.", "*NO_REPLY*", "No Reply", "SILENT", "[静默]"] {
            #expect(Hydration.isSilentWords(words), "\(words)")
        }
        for words in ["No additional user-facing response.", "[No response from the server] — I'll retry at 9.",
                      "[Inbox] no reply yet", "[No response from the server]", "[No reply from Ivy yet; I'll chase it [tomorrow]]",
                      "I got no response from the API.", "[Done]", "(no reply from Ivy yet)", "(Ivy: no reply needed) — sent anyway.",
                      "(no reply needed (yet))", "*(no reply needed)", "**",
                      "NO_REPLY needed? I'll check.", "Paris.\n\nNO_REPLY", "[SILENT", "NO_REPLY_YET"] {
            #expect(!Hydration.isSilentWords(words), "\(words)")
        }
    }

    @Test func storedSilentRepliesBetweenDeliveriesLeaveNoSpace() throws {
        let stored: [JSONValue] = [
            ["role": "user", "content": "Message from Inbox (@inbox): Lunch moved to 1 pm.", "timestamp": 1_789_999_300],
            ["role": "assistant", "content": "Thanks, I will reply first.", "timestamp": 1_789_999_400],
            ["role": "user", "content": "[Message from agent 'research'] Findings are in the doc.", "timestamp": 1_790_000_000],
            ["role": "assistant", "content": "[SILENT]", "timestamp": 1_790_000_010],
            ["role": "user", "content": "Message from Billing Bot: Invoice sent.", "timestamp": 1_790_000_060],
            ["role": "assistant", "content": "[SILENT]", "timestamp": 1_790_000_070],
        ]
        let seats = [DeliveryMessages.Seat(profile: "research", name: "Research", head: nil)]
        let own = DeliveryMessages.Seat(profile: "default", name: "Hermes", head: nil)
        var messages = DeliveryMessages.resolve(Hydration.fold(stored, pageSeq: 1).messages, roster: seats).messages
        messages = TimelineNotes.resolve(CronDeliveries.resolve(messages, roster: seats, own: own).messages)
        let rows = ChatRowBuilder.build(.init(messages: messages, isRunning: false, botName: "Hermes", expanded: []))
        let dump = rows.map { "\($0.id) gap \($0.gapAbove) \($0.kind)" }
        #expect(!rows.contains { if case .notice = $0.kind { return true } else { return false } }, "\(dump)")
        // [updates] Inbox's line on its own (the reply ends its run), then Research and Billing Bot as one group.
        let lines = rows.filter { if case .backgroundResult = $0.kind { return true } else { return false } }
        #expect(lines.count == 2, "\(dump)")
        let group = try #require(lines.last)
        guard case .backgroundResult(let b) = group.kind else { return }
        #expect(b.group?.count == 2, "\(dump)")

        // The screen rebuilds from the message before a change: a region at Billing Bot's message widens to the group.
        let billing = try #require(messages.firstIndex { m in m.parts.contains { if case .text(let t) = $0 { t.contains("Invoice sent") } else { false } } })
        let research = try #require(messages.firstIndex { $0.id == group.messageId })
        let input = ChatRowBuilder.Input(messages: messages, isRunning: false, botName: "Hermes", expanded: [])
        #expect(UpdateGroups.widen(billing...billing, input: input).lowerBound == research)
    }

    @Test func deliveryTitleReadsAsOneLine() {
        #expect(DeliveryRows.title(sender: "Research", text: "  Findings\n\n  are in   the doc. ") == "Research: Findings are in the doc.")
        #expect(DeliveryRows.title(sender: "Research", text: "  ") == "Research")
    }

    @Test func deliveryTitleDropsMarkdown() {
        let text = "## Summary\n**3 new** emails in [the thread](https://mail.example.com/t/1) and `inbox`"
        #expect(DeliveryRows.title(sender: "Inbox", text: text) == "Inbox: Summary 3 new emails in the thread and inbox")
        #expect(BackgroundResults.linkWords("see ![chart](https://x.io/a.png) and [docs](https://x.io)") == "see chart and docs")
    }

    @Test func gatewayProcessTitlesReadAsTheTimelines() {
        // [updates] What finished leads, in plain words (owner, 2026-10-27).
        #expect(BackgroundResults.plainTitle("Background Process Finished: npm test") == "npm test finished")
        #expect(BackgroundResults.plainTitle("2 Background Processes Finished") == "2 background tasks finished")
        #expect(BackgroundResults.plainTitle("background process finished") == "Background task finished")
        #expect(BackgroundResults.plainTitle("Background Process Failed: make") == "make failed")
        #expect(BackgroundResults.plainTitle("Background task finished: npm test") == "npm test finished")
        #expect(BackgroundResults.plainTitle("Subagent Task Completed: Index the docs") == "Helper finished: Index the docs")
        #expect(BackgroundResults.plainTitle("Some other title") == "Some other title")
    }
}
