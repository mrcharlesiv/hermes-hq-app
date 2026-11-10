// The m9 transcript stream's finishing pass (docs/spec/3x-transcript.md §4.2, §6.2–§6.6, §3.4, §3.7, §9.2): the status
// grace and the waking words through a real `LiveChatSession`, the cards above the composer, the failed read of
// earlier messages, the turn duration mark, link chips, the Table sheet's text, and "Message actions" on every element.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@Suite("Transcript finishing pass: session", .serialized)
@MainActor
struct TranscriptSessionFinishTests {
    private func opened(_ h: ChatHarness) async throws -> LiveChatSession {
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        return s
    }

    private func timeout(_ method: String) -> RPCError {
        RPCError(code: RPCError.timeoutCode, message: "request timed out after 120s: \(method)", data: nil)
    }

    // MARK: §6.4 the grace, through the session

    @Test func aShortReconnectSaysNothingAndALongOneSaysReconnecting() async throws {
        let h = try ChatHarness()
        let s = try await opened(h)
        s.statusGraceDelay = StatusGrace.standard
        s.flushChanges()
        #expect(s.statusText == nil)

        // 400 ms without the link: nothing is ever shown.
        h.client.setConnection(.reconnecting(attempt: 1))
        var seen: [String?] = []
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(50))
            s.flushChanges()
            seen.append(s.statusText)
        }
        h.client.setConnection(.ready)
        try? await Task.sleep(for: .milliseconds(40))
        s.flushChanges()
        seen.append(s.statusText)
        #expect(seen.allSatisfy { $0 == nil }, "a 400 ms reconnect showed \(seen)")

        // Held past the grace: the word shows, by the session's own recheck, and clears at once.
        h.client.setConnection(.reconnecting(attempt: 1))
        try? await Task.sleep(for: .milliseconds(60))
        s.flushChanges()
        #expect(s.statusText == nil)
        #expect(s.statusRecheck != nil, "a recheck is owed while a waiting word is held back")
        #expect(await waitUntil(timeout: .seconds(4)) { s.flushChanges(); return s.statusText == "Reconnecting…" })
        h.client.setConnection(.ready)
        #expect(await waitUntil { s.flushChanges(); return s.statusText == nil })
    }

    @Test func noGraceIsTheDefaultForASessionMadeWithoutOne() async throws {
        let h = try ChatHarness()
        let s = try await opened(h)
        #expect(s.statusGraceDelay == .zero)
        h.client.setConnection(.reconnecting(attempt: 1))
        try? await Task.sleep(for: .milliseconds(30))
        s.flushChanges()
        #expect(s.statusText == "Reconnecting…")
    }

    // MARK: §6.5 waking

    @Test func aSlowFirstResumeReadsWakingUpThenStillWakingUp() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let resume = try ChatFixtures.json("perf-resume.json")["result"] ?? .null
        h.client.onCall { method, _ in
            if method == "session.resume" { try? await Task.sleep(for: .milliseconds(1400)); return resume }
            return method == "session.active_list" ? ["sessions": []] : [:]
        }
        let s = h.make()
        s.statusGraceDelay = .milliseconds(200)
        s.stillWakingAfter = .milliseconds(700)
        s.start()
        try? await Task.sleep(for: .milliseconds(80))
        s.flushChanges()
        #expect(s.statusText == nil, "inside the grace nothing shows")
        #expect(await waitUntil { s.flushChanges(); return s.statusText == "Waking up…" })
        #expect(await waitUntil(timeout: .seconds(2)) { s.flushChanges(); return s.statusText == "Still waking up…" })
        #expect(await waitUntil(timeout: .seconds(3)) { s.openSettled })
        #expect(await waitUntil { s.flushChanges(); return s.statusText == nil }, "gone when the bot answers")
        #expect(s.sessionProblem == nil)
    }

    @Test func aResumeOfAChatAlreadyOnItsRuntimeNeverReadsWakingUp() async throws {
        let h = try ChatHarness()
        let s = try await opened(h)
        #expect(s.runtimeSessionId != nil)
        let resume = try ChatFixtures.json("perf-resume.json")["result"] ?? .null
        h.client.onCall { method, _ in
            if method == "session.resume" { try? await Task.sleep(for: .milliseconds(500)); return resume }
            return [:]
        }
        let again = Task { _ = try? await s.resumeNow() }
        var seen: [String?] = []
        for _ in 0..<6 {
            try? await Task.sleep(for: .milliseconds(60))
            s.flushChanges()
            seen.append(s.statusText)
        }
        await again.value
        #expect(!seen.contains("Waking up…"), "an ordinary re-resume read \(seen)")
    }

    @Test func aResumeThatTimesOutTwiceSaysCouldntReopen() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let error = timeout("session.resume")
        h.client.onCall { method, _ in
            if method == "session.resume" { throw error }
            return method == "session.active_list" ? ["sessions": []] : [:]
        }
        let s = h.make()
        #expect(await h.open())
        #expect(h.client.calls("session.resume").count == 2, "one quiet retry, then words")
        let problem = try #require(s.sessionProblem)
        #expect(problem.title == "Couldn’t reopen this chat")
        #expect(problem.body == "This chat is still starting on the computer running Hermes.")
        #expect(problem.primary == .tryAgain)
        #expect(!s.messages.isEmpty, "the transcript read over REST stays on screen")

        // Try again, with the gateway answering now: the card goes and the chat is on its runtime.
        let resume = try ChatFixtures.json("perf-resume.json")["result"] ?? .null
        h.client.onCall { method, _ in method == "session.resume" ? resume : [:] }
        s.retryAfterProblem()
        #expect(await waitUntil { s.runtimeSessionId != nil })
        #expect(s.sessionProblem == nil)
    }

    // MARK: §6.2 the chat's problem card

    @Test func anErrorWithNoTurnRunningIsTheProblemCard() async throws {
        let h = try ChatHarness()
        let s = try await opened(h)
        let count = s.messages.count
        await h.emit([h.event("error", ["message": "Turn cancelled before the agent was ready"])])
        #expect(s.sessionProblem == nil, "the one the chat ignores")

        await h.emit([h.event("error", ["message": "model not configured"])])
        let plain = try #require(s.sessionProblem)
        #expect(plain.title == "Hermes reported a problem")
        #expect(plain.body == "model not configured")
        #expect(plain.primary == .tryAgain)
        #expect(s.messages.count == count, "no card in the transcript")
        #expect(h.notices.isEmpty, "and no toast")

        s.dismissSessionProblem()
        #expect(s.sessionProblem == nil)
        let start = "Could not start the model: failed to initialize agent for provider anthropic"
        await h.emit([h.event("error", ["message": .string(start)])])
        if let known = TurnErrors.copy(start), known.kind == .modelStart {
            #expect(s.sessionProblem?.title == "This chat’s model couldn’t start")
            #expect(s.sessionProblem?.primary == .chooseModel)
        } else {
            #expect(s.sessionProblem != nil)
        }
        // Sending answers the card.
        h.client.onCall { method, _ in method == "prompt.submit" ? ["status": "streaming"] : [:] }
        s.send("hello")
        #expect(s.sessionProblem == nil)
    }

    // MARK: §6.3 Couldn't Send

    @Test func aRefusedSendIsTheComposerCardAndNotATranscriptCard() async throws {
        let h = try ChatHarness()
        let s = try await opened(h)
        let before = s.messages.map(\.id)
        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw RPCError(code: 4012, message: "this profile has no model provider", data: nil) }
            return [:]
        }
        s.send("Draft the reply")
        #expect(await waitUntil { s.sendFailure != nil })
        s.flushChanges()
        let failure = try #require(s.sendFailure)
        #expect(SendFailure.title == "Couldn’t Send")
        #expect(failure.body == "Your message is still in the box below. This profile has no model provider.")
        #expect(s.messages.map(\.id) == before, "no bubble left behind and no error card: \(s.messages.suffix(2).map(\.id))")
        #expect(!s.messages.contains { $0.id.hasPrefix("local-error-") })
        #expect(h.drafts.last?.0 == "Draft the reply", "the words go back to the field")
        #expect(!s.isRunning)

        // The next send answers it.
        h.client.onCall { method, _ in method == "prompt.submit" ? ["status": "streaming"] : [:] }
        s.send("Draft the reply")
        #expect(s.sendFailure == nil)
    }

    @Test func aSendThatGetsNoAnswerInTimeSaysSo() {
        let failure = SendFailure.make(reason: "request timed out after 30s: prompt.submit")
        #expect(failure.body == "The computer running Hermes didn’t answer in time. Your message is still in the box below.")
        #expect(SendFailure.make(reason: "The Internet connection appears to be offline.").body
                == "You’re offline. Your message is still in the box below.")
        #expect(SendFailure.make(reason: "").body == "Your message is still in the box below.")
        #expect(SendFailure.make(reason: "The Internet connection appears to be offline.").copyText == nil)
    }

    @Test func aChatStillOwnedElsewhereSaysSoPlainlyAndKeepsItsDetailsForCopy() {
        // Build 320 feedback: the phone's own earlier connection holds the chat as "desktop"; never "your computer".
        let reason = "This chat is open in another Hermes window/terminal. Use it there, or start a new chat here.\n"
            + "Details: session 20261018_083300_aabbcc02 opened by desktop 42m ago."
        let failure = SendFailure.make(reason: reason)
        #expect(failure.body == "Your message is still in the box below. Hermes has this chat open somewhere else, like the Hermes "
                + "desktop app. Close it there and try again, or start a new chat.")
        #expect(failure.copyText == reason)
        #expect(!OwnerWait.otherWindow.cardBody.contains("your computer"))
        #expect(!OwnerWait.otherWindow.status.contains("your computer"))
    }

    @Test func aReplyStillRunningOnTheGatewaySaysSoPlainly() {
        // Build 337 feedback: 4090 SESSION_OWNER_BUSY's own words name "the gateway" twice and its internal queue.
        let reason = "The gateway is running a turn in this chat and the gateway refused it. Nothing was sent. "
            + "Send it again when the current turn ends."
        #expect(SendFailure.make(reason: reason).body
                == "Your message is still in the box below. Hermes is still running a reply in this chat. Send it again when that reply is done.")
        #expect(!OwnerWait.runningReply.cardBody.contains("gateway"))
        #expect(!OwnerWait.runningReply.status.contains("gateway"))
    }

    // MARK: §4.2 earlier messages

    @Test func aFailedReadOfEarlierMessagesWaitsForTryAgain() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        // No older page in the store: the background read that completes the first 120 rows fails (404).
        let s = h.make()
        #expect(await h.open())
        #expect(await waitUntil { s.olderFailed })
        #expect(s.hasOlder)
        let reads = h.client.restLog.count
        // No request loop while failed: the screen asking again reads nothing.
        s.loadOlder(); s.loadOlder()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(h.client.restLog.count == reads)

        try h.setPage("97@23", "perf-page-older.json")
        s.retryOlder()
        #expect(!s.olderFailed)
        #expect(await waitUntil { s.messages.count == 24 + 96 })
        #expect(!s.olderFailed)
    }

    // MARK: §6.6 turn duration

    @Test func aTurnThisDeviceSawKeepsItsDurationForThisChatOnly() async throws {
        let h = try ChatHarness()
        let s = try await opened(h)
        let store = TurnMarkStore(defaults: nil)
        s.turnMarks = store
        h.client.onCall { method, _ in method == "prompt.submit" ? ["status": "streaming"] : [:] }
        s.send("How long?")
        await h.emit([h.event("message.start")])
        try? await Task.sleep(for: .milliseconds(1100))
        await h.emit([h.event("message.complete", ["text": "About a second.", "status": "complete"])])
        let reply = try #require(h.assistant)
        let seconds = try #require(s.turnSeconds(reply.id))
        #expect(seconds >= 1 && seconds < 5, "\(seconds)")
        #expect(TurnDuration.short(seconds) == "1s")
        #expect(store.count == 1)

        // Another chat with the same message ids gets nothing.
        let other = try ChatHarness(stored: "20260929_130000_ddeeff02")
        try other.setPage("24", "perf-page-latest-24.json")
        let o = other.make()
        o.turnMarks = store
        #expect(await other.open())
        #expect(o.turnSeconds(reply.id) == nil)
        // A turn only read from history has no mark (unknown is nothing, never a guess).
        let old = try #require(s.messages.first { $0.role == .assistant && $0.id != reply.id })
        #expect(s.turnSeconds(old.id) == nil)
    }
}

@Suite("Transcript finishing pass: rows and views")
@MainActor
struct TranscriptViewFinishTests {
    private let style = ChatStyleCache.shared.style(for: .large)

    // MARK: §6.6 the action row is gone ([updates] owner, 2026-10-27: the time is on the Worked line, Copy in the hold menu)

    @Test func noActionRowEvenWithADuration() {
        let user = ChatMessage(id: "u1", role: .user, parts: [.text("hi")], timestamp: Date(), rowId: 1)
        let reply = ChatMessage(id: "a1", role: .assistant, parts: [.text("Hello there.")], timestamp: Date(), rowId: 2)
        var input = ChatRowBuilder.Input(messages: [user, reply], isRunning: false, botName: "Ivy", expanded: [])
        input.turnSeconds = ["a1": 72.4]
        #expect(!ChatRowBuilder.build(input).contains { if case .actions = $0.kind { true } else { false } })
    }

    // MARK: Cron byline (review): same words, different jobs

    @Test func twoCronDeliveriesWithTheSameWordsAndDifferentJobsAreDifferentRows() {
        func delivery(_ id: String, job: String) -> ChatMessage {
            var m = ChatMessage(id: id, role: .user, parts: [.text("All quiet.")], timestamp: Date(), rowId: nil)
            m.sender = ChatSender(key: "ivy", name: "Ivy", head: nil, profile: "ivy")
            m.job = job
            return m
        }
        // [updates] The two runs fold into one group; opened, it lists both.
        let rows = ChatRowBuilder.build(.init(messages: [delivery("c1", job: "Morning brief"), delivery("c2", job: "Evening brief")],
                                              isRunning: false, botName: "Ivy", expanded: ["c1|grp"]))
        let lines = rows.filter { $0.id.hasSuffix("|cr" + UpdateGroups.memberSuffix) }   // the card's member rows
        #expect(lines.count == 2)
        guard lines.count == 2 else { return }
        #expect(lines[0].fingerprint != lines[1].fingerprint, "the job's name is on the line")
    }

    // MARK: Loopback spellings (review)

    @Test func everySpellingOfTheGatewayComputersOwnAddressIsLoopback() {
        for host in ["127.1", "2130706433", "0177.0.0.1", "0x7f.0.0.1", "127.000.000.001", "::ffff:127.0.0.1", "[::ffff:7f00:1]", "::",
                     "[::1]", "0", "::127.0.0.1", "LOCALHOST", "localhost.", "::1%lo0"] {
            #expect(LinkTargets.isLoopback(host: host), "\(host)")
        }
        for host in ["example.com", "127.example.com", "8.8.8.8", "128.0.0.1", "::ffff:8.8.8.8", "2001:db8::1", "1.127.0.0", "localhost.example.com"] {
            #expect(!LinkTargets.isLoopback(host: host), "\(host)")
        }
        for url in ["http://127.1:8080/", "http://2130706433/", "http://[::ffff:127.0.0.1]:3000/x", "http://[::ffff:7f00:1]/"] {
            #expect(LinkTargets.target(URL(string: url)!) == .loopback, "\(url)")
        }
        #expect(LinkTargets.loopbackNotice(device: "iPad") == "This page runs on the computer running Hermes, so it can’t open on your iPad.")
    }

    // MARK: L307 a flag in inline code stays whole (review: measured, and what Find sees)

    /// The line each character of `text` falls on when laid out at `width`.
    private func lines(_ text: NSAttributedString, width: CGFloat) -> [NSRange] {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var out: [NSRange] = []
        var glyph = 0
        while glyph < manager.numberOfGlyphs {
            var range = NSRange()
            _ = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
            out.append(manager.characterRange(forGlyphRange: range, actualGlyphRange: nil))
            glyph = NSMaxRange(range)
        }
        return out
    }

    @Test func aLongLineWrapsBeforeTheFlagNotInsideIt() {
        let font = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        let lead = "Install it for one user with pip and the option "
        let flag = "--break-system-packages"
        func breaksInside(_ shown: String) -> Int {
            let text = NSAttributedString(string: lead + shown + " and then run it again.", attributes: [.font: font])
            let at = NSRange(location: (lead as NSString).length, length: (shown as NSString).length)
            let flagWidth = (shown as NSString).size(withAttributes: [.font: font]).width
            var broken = 0
            for width in stride(from: CGFloat(230), through: 420, by: 7) where width > flagWidth + 1 {
                let holding = lines(text, width: width).filter { NSIntersectionRange($0, at).length > 0 }
                if holding.count > 1 { broken += 1 }
            }
            return broken
        }
        #expect(breaksInside(flag) > 0, "the plain flag does break after a hyphen at some widths (the test has teeth)")
        #expect(breaksInside(InlineCodeText.display(flag)) == 0, "with the joiners it never breaks inside")
    }

    @Test func findLooksPastTheJoinersInDrawnText() {
        let drawn = "Use " + InlineCodeText.display("--user") + " here, or " + InlineCodeText.display("--user-site") + "."
        let ranges = InlineCodeText.findRanges(of: "--user", in: drawn)
        #expect(ranges.count == 2)
        let ns = drawn as NSString
        #expect(ranges.map { InlineCodeText.plain(ns.substring(with: $0)) } == ["--user", "--user"])
        #expect(InlineCodeText.findRanges(of: "user", in: "no flags, user") == [NSRange(location: 10, length: 4)])
        #expect(InlineCodeText.plain(drawn) == "Use --user here, or --user-site.")
        // The same count as the search over the message's own text.
        #expect(ChatFind.ranges(of: "--user", in: InlineCodeText.plain(drawn)).count == ranges.count)
    }

    // MARK: §3.7 link chips

    @Test func aBareAddressAloneOnItsParagraphGetsAChip() {
        func chips(_ markdown: String, on: Bool = true) -> [URL] {
            MarkdownRenderer.render(markdown, style: style, linkChips: on).blocks.compactMap {
                if case .linkChip(let url) = $0 { return url } else { return nil }
            }
        }
        #expect(chips("Here it is:\n\nhttps://example.com/install?x=1\n\nDone.") == [URL(string: "https://example.com/install?x=1")!])
        #expect(chips("https://example.com/") == [URL(string: "https://example.com/")!])
        #expect(chips("See https://example.com/ for more.").isEmpty, "a link inside a sentence gets none")
        #expect(chips("[the page](https://example.com/)").isEmpty, "a link the author gave words to keeps them")
        #expect(chips("http://example.com/").isEmpty, "https only")
        #expect(chips("https://localhost/").isEmpty)
        #expect(chips("- https://example.com/").isEmpty, "not inside a list")
        #expect(chips("https://example.com/", on: false).isEmpty, "only where the chat asks for them")
        #expect(LinkPreviewParsing.bareLinkLabel(title: nil, target: "https://www.example.com/install?x=1") == "example.com/install…")
    }

    @Test func aChipHasItsSizeFromTheStart() {
        let h = LinkChipView.height(style: style)
        #expect(h >= 52 && h <= 64, "\(h)")
        let chip = LinkChipView(frame: CGRect(x: 0, y: 0, width: 280, height: h))
        chip.configure(URL(string: "https://www.example.com/install?x=1")!, style: style)
        // [mac-audit] With no page title the address already names the host: it is said (and shown) once.
        #expect(chip.accessibilityLabel == "Link, example.com/install…")
        #expect(chip.accessibilityTraits.contains(.link))
        chip.reset()
    }

    // MARK: §3.4 the Table sheet

    @Test func theTableSheetCopiesTabSeparatedRows() throws {
        let markdown = "| Name | Qty |\n|---|---:|\n| Tea\tbags | 3 |\n| Milk | 12 |"
        let table = try #require(MarkdownRenderer.render(markdown, style: style).blocks.compactMap { block -> MarkdownTable? in
            if case .table(let t) = block { return t } else { return nil }
        }.first)
        let page = TableSheetController(table: table)
        #expect(page.rows.count == 3 && page.rows[0] == ["Name", "Qty"])
        let text = try #require(TableText.copyable(page.rows))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0.filter { $0 == "\t" }.count == 1 }, "one tab between two columns on every line: \(text.debugDescription)")
        #expect(table.plain == text, "Copy in the bubble and Copy as Text in the sheet give the same text")
        #expect(TableText.copyable([[" ", ""]]) == nil)
        let navigation = TableSheetController.make(table)
        #expect(navigation.viewControllers.first?.title == "Table")
        navigation.loadViewIfNeeded()
        navigation.viewControllers.first?.loadViewIfNeeded()
        #expect(navigation.viewControllers.first?.toolbarItems?.contains { $0.title == "Copy as Text" } == true)
    }

    @Test func aTableInAReplyHasItsFooterUnderTheGrid() throws {
        let markdown = "| a | b |\n|---|---|\n| 1 | 2 |"
        var bubble = BubbleRow(mine: false, text: markdown, markdown: true, partIndex: 0, joinsAbove: false, joinsBelow: false, tail: true,
                               time: nil, pending: false, streaming: false, speaker: "Ivy", expanded: true)
        bubble.senderInset = false
        let row = ChatRow(id: "t|b0", messageId: "t", scope: "", fingerprint: 1, kind: .bubble(bubble), gapAbove: 0, variant: 0)
        let layout = TextLayout.make(row, width: 390, style: style)
        guard case .bubble(let b) = layout.content else { Issue.record("not a bubble"); return }
        let placed = try #require(b.blocks.first { if case .table = $0.block { return true } else { return false } })
        let grid = try #require(placed.grid)
        #expect(placed.textFrame.minY == 0, "no strip saying only \"Table\": the grid starts at the card's top")
        // Owner 2026-10-29: the Expand glyph sat on the header's words. It is in a footer under the grid now.
        #expect(placed.textFrame.height == grid.size.height)
        #expect(placed.frame.height == grid.size.height + ChatMetrics.tableFooter(style))
        #expect(ChatMetrics.tableFooter(style) >= 36)
        // A narrow table's card is wide enough for the footer; its last column takes the room, so the grid's lines
        // and header band reach the card's edge.
        #expect(placed.frame.width >= ChatMetrics.tableStripMinWidth)
        #expect(grid.size.width == placed.frame.width)
    }

    /// [wide-tables] Tester 2026-11-06: a table wider than the reply's words reaches the column's edges (the Mac's
    /// 1280 where the words stop at 728); the words beside it keep their own width.
    @Test func aWideTableTakesTheColumnAndTheWordsKeepTheirWidth() throws {
        let cells = (1...6).map { "column \($0) with quite a long heading" }
        let markdown = "Some words before the table, long enough to wrap the line across the reply's width and more.\n\n"
            + "| " + cells.joined(separator: " | ") + " |\n|" + String(repeating: "---|", count: 6) + "\n| "
            + cells.joined(separator: " | ") + " |"
        var bubble = BubbleRow(mine: false, text: markdown, markdown: true, partIndex: 0, joinsAbove: false, joinsBelow: false, tail: true,
                               time: nil, pending: false, streaming: false, speaker: "Ivy", expanded: true)
        bubble.senderInset = false
        let row = ChatRow(id: "w|b0", messageId: "w", scope: "", fingerprint: 1, kind: .bubble(bubble), gapAbove: 0, variant: 0)
        let width: CGFloat = 1280
        guard case .bubble(let b) = TextLayout.make(row, width: width, style: style).content else { Issue.record("not a bubble"); return }
        let padH = TextLayout.sidePad(mine: false)
        let table = try #require(b.blocks.first { if case .table = $0.block { return true } else { return false } })
        let words = try #require(b.blocks.first { $0.block.isProse })
        #expect(table.frame.width == TextLayout.tableReplyWidth(width) - 2 * padH, "the table reaches the column's edges")
        #expect(b.frame.width == TextLayout.tableReplyWidth(width))
        #expect(words.frame.width <= TextLayout.replyWidth(width) - 2 * padH, "the words wrap where a reply's words always do")
        #expect(table.contentWidth > table.frame.width, "wider still, the grid scrolls sideways in it")
    }

    @Test func theTableFooterSaysItsSizeAndOpensThePage() throws {
        let table = try #require(MarkdownRenderer.render("Plans:\n\n| Plan | Price |\n|---|---|\n| Starter | $5 |\n| Team | $20 |",
                                                         style: style).blocks.compactMap { block -> MarkdownTable? in
            if case .table(let t) = block { return t } else { return nil }
        }.first)
        let block = BlockView()
        var opened: MarkdownTable?
        block.onExpandTable = { opened = $0 }
        let markdownRow = ChatRow(id: "f|b0", messageId: "f", scope: "", fingerprint: 1,
                                  kind: .bubble(BubbleRow(mine: false, text: "| Plan | Price |\n|---|---|\n| Starter | $5 |\n| Team | $20 |",
                                                          markdown: true, partIndex: 0, joinsAbove: false, joinsBelow: false,
                                                          tail: false, time: nil, pending: false, streaming: false, speaker: nil)),
                                  gapAbove: 0, variant: 0)
        guard case .bubble(let b) = TextLayout.make(markdownRow, width: 390, style: style).content,
              let placed = b.blocks.first(where: { if case .table = $0.block { return true } else { return false } }) else {
            Issue.record("expected a table"); return
        }
        block.configure(placed, mine: false)
        let footer = try #require(block.accessibleControls.first as? TableFooterControl)
        #expect(footer.accessibilityLabel == "Expand table")
        #expect(footer.accessibilityValue == "2 rows, 2 columns")
        #expect(footer.accessibilityIdentifier == "chat.table.expand")
        #expect(footer.frame.minY == placed.textFrame.maxY, "under the grid, over no cell")
        #expect(footer.frame.height >= 44)
        footer.sendActions(for: .primaryActionTriggered)
        #expect(opened?.rows.count == 2)
        // A tap on the cells opens it too.
        opened = nil
        #expect(block.expandTableIfHit(CGPoint(x: 10, y: 10)))
        #expect(opened != nil)
        #expect(table.caption == "Plans")
    }

    /// A touch on a table's footer reaches it (and VoiceOver's touch finds it) when words and another table follow.
    @Test func aTouchOnATableFooterReachesItWithMoreBelow() throws {
        let rows = (1...7).map { "| Person \($0) | \(20 - $0).\($0)% | Other person \($0) | \($0).1% |" }.joined(separator: "\n")
        let text = "Rep by rep:\n\n| Strong at follow-up | Reply rate | Weak at follow-up | Reply rate |\n|---|---|---|---|\n" + rows
            + "\n\n**How much it matters:** some.\n\n### Pipeline\n\n| Source | Leads |\n|---|---|\n| Ads | 2,410 |\n| Mail | 640 |"
        let row = ChatRow(id: "f2|b0", messageId: "f2", scope: "", fingerprint: 2,
                          kind: .bubble(BubbleRow(mine: false, text: text, markdown: true, partIndex: 0, joinsAbove: false,
                                                  joinsBelow: false, tail: false, time: nil, pending: false, streaming: false,
                                                  speaker: nil)),
                          gapAbove: 0, variant: 0)
        let layout = TextLayout.layout(row, width: 402, style: style)
        let cell = ChatBubbleCell(style: .default, reuseIdentifier: ChatBubbleCell.reuse)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: max(900, layout.height)))
        window.isHidden = false
        window.addSubview(cell)
        cell.frame = CGRect(x: 0, y: 0, width: 402, height: layout.height)
        cell.configure(row, layout: layout)
        cell.layoutIfNeeded()
        let footers = cell.contentView.subviews.first.map { bubble in
            bubble.subviews.compactMap { $0 as? BlockView }.filter { !$0.isHidden }.flatMap(\.accessibleControls)
        } ?? []
        #expect(footers.count == 2)
        for footer in footers {
            let center = footer.convert(CGPoint(x: footer.bounds.midX, y: footer.bounds.midY), to: window)
            let hit = window.hitTest(center, with: nil)
            #expect(hit === footer || hit?.isDescendant(of: footer) == true,
                    "hit \(String(describing: hit)) at \(center); footer \(footer.frame) in \(String(describing: footer.superview?.frame))")
        }
    }

    // MARK: §9.2 "Message actions" on every element VoiceOver can land on (L366)

    @Test func messageActionsOnATextBubbleAndOnAPhotoBubble() throws {
        let message = ChatMessage(id: "stored-row-9-user", role: .user, parts: [.text("Look at this")], timestamp: Date(), rowId: 9)
        func bubbleRow(photo: Bool) throws -> ChatRow {
            var input = ChatRowBuilder.Input(messages: [message], isRunning: false, botName: "Ivy", expanded: [], scope: "t|ivy|s")
            if photo {
                let shot = MessageAttachment(kind: .image, source: .gateway(path: "/g/chart.png"), name: "chart.png", pixelWidth: 800, pixelHeight: 600)
                input.media = ChatMediaSnapshot(attachments: [message.id: [shot]], generated: [:],
                                                context: MediaContext(accountId: "a", profile: "ivy"))
            }
            return try #require(ChatRowBuilder.build(input).first(where: { $0.isBubble }))
        }
        let cell = ChatBubbleCell(style: .default, reuseIdentifier: nil)
        for photo in [false, true, false] {      // the last pass: a reused cell that held a photo
            let row = try bubbleRow(photo: photo)
            let layout = TextLayout.make(row, width: 402, style: style)
            cell.frame = CGRect(x: 0, y: 0, width: 402, height: layout.height)
            cell.configure(row, layout: layout)
            let names = cell.accessibilityActionNamesByElement
            #expect(names.count == (photo ? 2 : 1), "photo \(photo): \(names)")
            #expect(names.allSatisfy { $0.filter { $0 == "Message actions" }.count == 1 },
                    "every element VoiceOver can land on offers Message actions once (photo \(photo)): \(names)")
        }
    }
}

@Suite("Transcript tool row notes")
struct ToolRowNoteTests {
    @Test func aBigResultSaysItsSizeAndAShortLineStays() {
        let big = JSONValue.object(["content": .string(String(repeating: "x", count: 12_000))])
        #expect(ToolWords.resultBytes(big) == 12_000)
        #expect(ToolWords.rowNote(name: "read_file", stdout: nil, stderr: nil, detail: nil, bytes: 12_000, failed: false) == "12 KB output")
        #expect(ToolWords.rowNote(name: "terminal", stdout: "done", stderr: nil, detail: nil, bytes: 4, failed: false) == "done")
        #expect(ToolWords.rowNote(name: "terminal", stdout: "a line that is much too long for the row", stderr: nil, detail: nil, bytes: 41, failed: false) == nil)
        #expect(ToolWords.rowNote(name: "read_file", stdout: nil, stderr: nil, detail: nil, bytes: 12_000, failed: true) == nil)
        // JSON is machine output: no note, or the size note when it is big.
        #expect(ToolWords.rowNote(name: "terminal", stdout: "{\"ok\": true}", stderr: nil, detail: nil, bytes: 12, failed: false) == nil)
        #expect(ToolWords.rowNote(name: "terminal", stdout: " [1, 2]", stderr: nil, detail: nil, bytes: 6, failed: false) == nil)
    }
}
