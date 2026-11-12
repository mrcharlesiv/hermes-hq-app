// [transcript] The display pass and the helpers the screens use (docs/spec/3x-transcript.md §2, §5.1, §6, §7.1, §9).

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@Suite struct TranscriptWiringTests {
    static let ivy = DeliveryMessages.Seat(profile: "ivy", name: "Ivy", head: nil)
    static let own = DeliveryMessages.Seat(profile: "default", name: "Hermes", head: nil)

    static func rows(_ messages: [ChatMessage], running: Bool = false, expanded: Set<String> = []) -> [ChatRow] {
        let cron = CronDeliveries.resolve(messages, roster: [own, ivy], own: own)
        let shown = TurnErrors.withoutDuplicateTurnErrors(TimelineNotes.resolve(cron.messages))
        #expect(shown.count == messages.count, "the display pass keeps every position")
        return ChatRowBuilder.build(ChatRowBuilder.Input(messages: shown, isRunning: running, botName: "Hermes", expanded: expanded, scope: "t"))
    }

    static func bubbles(_ rows: [ChatRow]) -> [BubbleRow] {
        rows.compactMap { if case .bubble(let b) = $0.kind { return b } else { return nil } }
    }

    static func notices(_ rows: [ChatRow]) -> [String] {
        rows.compactMap { if case .notice(let t) = $0.kind { return t } else { return nil } }
    }

    @Test func cronJobNameAndLead() {
        #expect(CronDeliveries.jobName("northwind-inbox-watch", bot: "northwind") == "Inbox watch")
        #expect(CronDeliveries.jobName("Ivy morning brief", bot: "Ivy") == "Morning brief")
        #expect(CronDeliveries.jobName("Ivy", bot: "Ivy") == "Ivy")
        #expect(CronDeliveries.jobName("disk-watch", bot: "Ivy") == "Disk watch")
        #expect(CronDeliveries.withoutJobLead("Northwind inbox watch: 1 new inbound email\n\n1) From: a", job: "northwind-inbox-watch")
                == "1 new inbound email\n\n1) From: a")
        #expect(CronDeliveries.withoutJobLead("Subject: hi", job: "northwind-inbox-watch") == "Subject: hi")
    }

    @Test func cronPreviewOnTheBotsList() {
        let cut = "[Cronjob \"northwind-inbox-watch\" output — scheduled job, not the user. Review it, act on anything..."
        #expect(RosterPreview.botPreview(text: cut, fromBot: nil, role: "Ops", bot: "northwind").line == "Inbox watch ran")
        let whole = "[Cronjob \"northwind-inbox-watch\" output — scheduled job, not the user.]\nNorthwind inbox watch: 1 new inbound email"
        let parts = RosterPreview.botPreview(text: whole, fromBot: nil, role: "Ops", bot: "northwind")
        #expect(parts.prefix == "Inbox watch:")
        #expect(parts.text == "1 new inbound email")
        let oneLine = "[Cron delivery: Ivy morning brief] (job_id: 7) --- **Three** things"
        #expect(RosterPreview.botPreview(text: oneLine, fromBot: nil, role: nil, bot: "ivy").line == "Morning brief: Three things")
        let silent = RosterPreview.botPreview(text: "[Cron delivery: Disk watch]\n[SILENT]", fromBot: nil, role: "Ops", bot: "ivy")
        #expect(silent.text == "Ops" && silent.isFallback)
    }

    @Test func cronHeaderNamesTheBotOnce() {
        #expect(CronDeliveries.header(sender: "Ivy", job: "Ivy morning brief") == "Ivy · Morning brief")
        #expect(CronDeliveries.header(sender: "Ivy", job: "ivy: disk watch") == "Ivy · Disk watch")
        #expect(CronDeliveries.header(sender: "Ivy", job: "Disk watch") == "Ivy · Disk watch")
        #expect(CronDeliveries.header(sender: "Ivy", job: "Samantha's notes") == "Ivy · Samantha's notes", "only the whole name")
        #expect(CronDeliveries.header(sender: "Ivy", job: "Ivy") == "Ivy")
    }

    @Test func cronDeliveryIsTheJobsBotsMessage() {
        let rows = Self.rows([
            ChatMessage(id: "u", role: .user, parts: [.text("Good morning")]),
            ChatMessage(id: "c", role: .assistant, parts: [.text("[Cron delivery: Ivy morning brief]\n(job_id: 7)\n---\n**Three** things\n\nTo stop or manage this job, send me a new message.")]),
            ChatMessage(id: "s", role: .assistant, parts: [.text("[Cron delivery: Disk watch]\n[SILENT]")]),
            ChatMessage(id: "q", role: .assistant, parts: [.text("[SILENT]")]),
        ])
        // A cron run is one line that opens on its report (owner, 2026-10-23).
        let run = rows.first { $0.id == "c|cr" }
        guard case .backgroundResult(let line)? = run?.kind else { Issue.record("no cron line"); return }
        #expect(line.cron)
        #expect(line.title == "Morning brief: Three things")
        #expect(line.result == "Three things")
        #expect(!Self.bubbles(rows).contains { $0.job != nil })
        // [updates] Silent runs draw nothing, a job's or a bare one (owner, 2026-10-27).
        #expect(Self.notices(rows).isEmpty)
        #expect(!Self.bubbles(rows).contains { $0.text.contains("[SILENT]") || $0.text.contains("Cron delivery") })
    }

    @Test func silentRunKeepsItsSteps() {
        let call = ToolCall(id: "t1", name: "terminal", title: "Ran ls", argsText: "{\"command\":\"ls\"}", summary: "ok", state: .done, durationSeconds: 1)
        let rows = Self.rows([
            ChatMessage(id: "u", role: .user, parts: [.text("check")]),
            ChatMessage(id: "a", role: .assistant, parts: [.tool(call), .text("[SILENT]")]),
        ])
        #expect(rows.contains { if case .toolRun = $0.kind { return true } else { return false } }, "the steps stay")
        #expect(Self.notices(rows).isEmpty, "[updates] no \"Nothing to report\" note")
        #expect(Self.bubbles(rows).count == 1, "only your message is a bubble")
    }

    @Test func modelSwitchAndProcessNoteReadInWords() {
        let rows = Self.rows([
            ChatMessage(id: "m", role: .user, parts: [.text("[System: The active model for this chat has changed to zz-unknown-9 via provider x. From this point on, answer as it.]")]),
            ChatMessage(id: "p", role: .user, parts: [.text("[IMPORTANT: Background process 4412 finished with exit code 0]")]),
        ], expanded: ["m|grp"])   // [updates] the two fold into one group; opened, each is a row of its card
        let members = rows.compactMap { if case .updateMember(let m) = $0.kind { return m } else { return nil } }
        // The id is shown under the name the model picker gives it (`ModelNames.displayModelName`).
        #expect(members.filter(\.notice).map(\.title) == ["Model changed to \(ModelNames.displayModelName("zz-unknown-9"))"])
        // The process note is a row that opens on the gateway's line (its id and exit code).
        let process = members.compactMap(\.result)
        #expect(process.map(\.title) == ["Background task finished"])
        #expect(process.first?.result == "Background process 4412 finished with exit code 0")
        #expect(process.first?.process == true)
        #expect(Self.bubbles(rows).isEmpty)
    }

    @Test func knownFailuresReadInTheWebsWords() {
        let rows = Self.rows([
            ChatMessage(id: "u", role: .user, parts: [.text("hi")]),
            ChatMessage(id: "e", role: .assistant, parts: [], error: "HTTP 429: usage_limit reached for provider anthropic"),
        ])
        guard case .error(let card)? = rows.last?.kind else { Issue.record("no error card"); return }
        #expect(card.title.contains("sage limit reached"))
        #expect(card.reason == "Choose another model, or try again later.")
        #expect(card.details.contains("429"), "the raw error stays behind Details")
        #expect(card.chooseModel, "a usage limit offers Choose a model")
        #expect(!card.retry, "and not Retry")
    }

    @Test func cutOffCardWithoutRetryHasNoRetryWords() {
        // Not the newest turn: the card offers no Retry, so its words do not point at one.
        let rows = Self.rows([
            ChatMessage(id: "u", role: .user, parts: [.text("hi")]),
            ChatMessage(id: "e", role: .assistant, parts: [.text("Half a")], error: "The connection dropped before the reply finished."),
            ChatMessage(id: "u2", role: .user, parts: [.text("again")]),
            ChatMessage(id: "a2", role: .assistant, parts: [.text("ok")]),
        ])
        let card = rows.compactMap { row -> ErrorRow? in if case .error(let e) = row.kind { return e } else { return nil } }.first
        #expect(card != nil)
        #expect(card?.retry == false)
        #expect(card.map { !$0.reason.lowercased().contains("retry") } == true, "no retry words: \(card?.reason ?? "")")
    }

    @Test func oneCardPerFailedTurn() {
        let rows = Self.rows([
            ChatMessage(id: "u", role: .user, parts: [.text("hi")]),
            ChatMessage(id: "e1", role: .assistant, parts: [], error: "Provider returned 500: upstream unavailable"),
            ChatMessage(id: "e2", role: .assistant, parts: [], error: "Provider returned 500: upstream unavailable"),
        ])
        let cards = rows.filter { if case .error = $0.kind { return true } else { return false } }
        #expect(cards.count == 1)
    }

    @Test func toolRowsInPlainWords() {
        let describe = ToolCall(id: "1", name: "tool_describe", title: "tool_describe", argsText: "{\"names\":[\"web_search\"]}", summary: "ok", state: .done, durationSeconds: nil)
        #expect(ChatRunSummary.summarize([describe], live: false) == "Checked how to use web search")
        let script = ToolCall(id: "2", name: "terminal", title: "terminal",
                              argsText: "{\"command\":\"cd /app\\nexport CI=1\\npython3 - <<'PY'\\nimport json\\nprint(1)\\nPY\"}", summary: nil, state: .running, durationSeconds: nil)
        let live = ChatRunSummary.summarize([script], live: true)
        #expect(live.contains("python3"), "named by its command: \(live)")
        #expect(!live.contains("export") && !live.contains("import json"), "not by setup or the script's body: \(live)")
    }

    @Test func linkTargets() {
        #expect(LinkTargets.target(URL(string: "https://example.com/a")!) == .page(URL(string: "https://example.com/a")!))
        for loop in ["http://localhost:3000", "http://127.0.0.1:8080/x", "http://127.4.5.6/", "http://[::1]:9/", "http://0.0.0.0:80", "http://app.localhost/"] {
            #expect(LinkTargets.target(URL(string: loop)!) == .loopback, "\(loop)")
        }
        #expect(LinkTargets.target(URL(string: "http://127.example.com/")!) == .page(URL(string: "http://127.example.com/")!))
        #expect(LinkTargets.target(URL(string: "mailto:a@example.com")!) == .system(URL(string: "mailto:a@example.com")!))
        #expect(LinkTargets.target(URL(string: "file:///etc/hosts")!) == .file("/etc/hosts"))   // [links-browser] the app's viewer
        for bad in ["file://elsewhere.example.com/etc/hosts", "javascript:alert(1)", "ftp://example.com/x", "data:text/html,hi"] {
            #expect(LinkTargets.target(URL(string: bad)!) == .refused, "\(bad)")
        }
    }

    @Test func flagsStayWhole() {
        #expect(InlineCodeText.display("--user") == "-\u{2060}-\u{2060}user")
        #expect(InlineCodeText.display("-v") == "-\u{2060}v")
        #expect(InlineCodeText.display("--break-system-packages").filter { $0 != "\u{2060}" } == "--break-system-packages")
        for other in ["a - b", "x-y", "pip install --user", "-", "--", String(repeating: "-a", count: 30)] {
            #expect(InlineCodeText.display(other) == other, "\(other)")
        }
    }

    @Test func spokenTextHasNoMarkdown() {
        let said = SpokenMarkdown.plain("## Plan\n\nInstall with `--user`, **not** *globally*. See the [guide](https://example.com/a_b).\n\n- one\n- [x] two\n\n```sh\npip install x\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |")
        #expect(said == "Plan\n\nInstall with --user, not globally. See the guide.\n\none\ntwo\n\npip install x\n\n\nA, B\n1, 2" || !said.contains("|"))
        for mark in ["**", "`", "##", "](", "- ", "|"] { #expect(!said.contains(mark), "\(mark) in \(said)") }
        #expect(said.contains("Install with --user, not globally. See the guide."))
        #expect(SpokenMarkdown.plain("snake_case_name and 2 * 3 * 4") == "snake_case_name and 2 * 3 * 4", "words with marks in them are left alone")
        #expect(SpokenMarkdown.plain("plain words") == "plain words")
    }

    @Test @MainActor func messageActionsListTheHoldMenu() {
        var ran: [String] = []
        let menu = UIMenu(title: "Hermes", children: [
            UIAction(title: "Copy") { _ in ran.append("copy") },
            UIAction(title: "Off", attributes: .disabled) { _ in },
            UIMenu(title: "", options: .displayInline, children: [UIAction(title: "Share…") { _ in ran.append("share") }]),
            UIMenu(title: "More", children: [UIAction(title: "Delete", attributes: .destructive) { _ in ran.append("delete") }]),
        ])
        let items = MessageActionsSheet.actions(of: menu)
        #expect(items.map(\.title) == ["Copy", "Share…", "More › Delete"])
        #expect(items.map(\.destructive) == [false, false, true])
        items[2].action.performWithSender(nil, target: nil)
        #expect(ran == ["delete"], "an item runs the menu's own handler")
    }

    @Test func statusGraceLeavesWorkingWordsAlone() {
        var grace = StatusGrace()
        let t0 = ContinuousClock.now
        #expect(grace.next(raw: "Waking up…", now: t0).shown == nil)
        #expect(grace.next(raw: "Waking up…", now: t0 + .milliseconds(1001)).shown == "Waking up…")
        #expect(grace.next(raw: "Still waking up…", now: t0 + .seconds(21)).shown == "Still waking up…")
        #expect(grace.next(raw: nil, now: t0 + .seconds(22)).shown == nil)
        #expect(grace.next(raw: "Thinking…", now: t0 + .seconds(23)).shown == "Thinking…")
    }
}
