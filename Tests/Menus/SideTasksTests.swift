// /btw and /bg (docs/spec/3x-composer.md §8.4) against a scripted gateway: the call, the start row, the result row, the
// rows the screen draws, and the chat listening off screen while a task is out.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@MainActor @Suite("Composer · /btw and /bg (spec 3x §8.4)", .serialized)
struct SideTasksTests {
    private func slashRows(_ f: MenusFixtureChat) -> [String] {
        f.session.messages.filter { SlashOutputRow.isSlashRow($0) }.map(\.plainText)
    }

    private func sideRows(_ f: MenusFixtureChat) -> [String] {
        f.session.messages.filter { SideTaskRow.isSideRow($0) }.map(\.plainText)
    }

    private func finished(_ type: String, _ f: MenusFixtureChat, task: String, text: String, question: String? = nil,
                          session: String? = nil) -> GatewayEvent {
        var payload: [String: JSONValue] = ["task_id": .string(task), "text": .string(text)]
        if let question { payload["question"] = .string(question) }
        return GatewayEvent(type: type, sessionId: session ?? f.rid1, seq: nil, payload: .object(payload))
    }

    @Test func usageWithNothingAfterTheCommand() async {
        let f = MenusFixtureChat()
        await f.session.performSlash("/btw", recordInput: true)
        await f.session.performSlash("/bg", recordInput: true)
        await f.session.performSlash("/background  ", recordInput: true)
        #expect(slashRows(f) == ["slash:/btw\n\(SideTaskKind.btw.usage)", "slash:/bg\n\(SideTaskKind.background.usage)",
                                 "slash:/background\n\(SideTaskKind.background.usage)"])
        #expect(f.client.calls("prompt.btw").isEmpty && f.client.calls("prompt.background").isEmpty)
    }

    @Test func btwAsksThenTheAnswerReplacesTheStartLine() async {
        let f = MenusFixtureChat()
        f.script.on("prompt.btw") { _, _ in ["task_id": "btw_0a1b2c"] }
        await f.session.performSlash("/btw what's the port?", recordInput: true)
        #expect(f.params("prompt.btw") == [["text": "what's the port?", "session_id": .string(f.rid1), "profile": "default"]])
        #expect(slashRows(f) == ["slash:/btw\n\(SideTaskKind.btw.started)"])
        #expect(f.client.calls("slash.exec").isEmpty)

        f.session.receive(finished("btw.complete", f, task: "btw_0a1b2c", text: "It listens on **8080**.", question: "what's the port?"))
        #expect(slashRows(f).isEmpty)
        #expect(sideRows(f) == ["side:btw\nBy the way: what's the port?\nIt listens on **8080**."])
        // A replay of the same frame adds nothing.
        f.session.receive(finished("btw.complete", f, task: "btw_0a1b2c", text: "It listens on **8080**."))
        #expect(sideRows(f).count == 1)
    }

    @Test func backgroundTaskFailureSaysSo() async {
        let f = MenusFixtureChat()
        f.script.on("prompt.background") { _, _ in ["task_id": "bg_9c0d11"] }
        await f.session.performSlash("/background run the tests", recordInput: true)
        #expect(f.params("prompt.background") == [["text": "run the tests", "session_id": .string(f.rid1), "profile": "default"]])
        #expect(slashRows(f) == ["slash:/background\n\(SideTaskKind.background.started)"])
        f.session.receive(finished("background.complete", f, task: "bg_9c0d11", text: "error: model unavailable"))
        #expect(sideRows(f) == ["side:bg\nBackground task failed: run the tests\nmodel unavailable"])
    }

    @Test func anotherChatsTaskIsLeftAlone() async {
        let f = MenusFixtureChat()
        f.script.on("prompt.btw") { _, _ in ["task_id": "btw_000001"] }
        await f.session.performSlash("/btw anything?", recordInput: true)
        f.session.receive(finished("btw.complete", f, task: "btw_999999", text: "Not yours.", session: "ffffffff"))
        #expect(sideRows(f).isEmpty)
        #expect(slashRows(f).count == 1)
        // One asked on this chat's runtime by an earlier screen of it is taken, with the question the frame names.
        f.session.receive(finished("btw.complete", f, task: "btw_888888", text: "Yes.", question: "earlier?"))
        #expect(sideRows(f) == ["side:btw\nBy the way: earlier?\nYes."])
    }

    @Test func answerBeforeTheCallReturnsLeavesNoStartLine() async {
        let f = MenusFixtureChat()
        let gate = MenusGate()
        f.script.on("prompt.btw") { _, _ in await gate.wait(); return ["task_id": "btw_fast01"] }
        let asking = Task { await f.session.performSlash("/btw quick?", recordInput: true) }
        #expect(await waitUntil { !f.client.calls("prompt.btw").isEmpty })
        f.session.receive(finished("btw.complete", f, task: "btw_fast01", text: "Done.", question: "quick?"))
        gate.release()
        await asking.value
        #expect(slashRows(f).isEmpty)
        #expect(sideRows(f) == ["side:btw\nBy the way: quick?\nDone."])
    }

    @Test func olderGatewayFallsBackToExecAndErrorsAreWords() async {
        let f = MenusFixtureChat()
        f.script.on("prompt.btw") { _, _ in throw RPCError(code: -32601, message: "unknown method: prompt.btw", data: nil) }
        f.script.on("slash.exec") { _, _ in ["output": "btw: answering…"] }
        f.script.on("prompt.background") { _, _ in throw RPCError(code: 5035, message: "backend is retiring; reconnect to continue", data: nil) }
        await f.session.performSlash("/btw old gateway?", recordInput: true)
        await f.session.performSlash("/bg tidy up", recordInput: true)
        #expect(f.params("slash.exec").first?["command"] == "btw old gateway?")
        #expect(slashRows(f) == ["slash:/btw\nbtw: answering…",
                                 "slash:/bg\nCouldn’t start the background task: backend is retiring; reconnect to continue"])
    }

    @Test func hermesRestartingEndsTheWait() async {
        let f = MenusFixtureChat()
        f.script.on("prompt.background") { _, _ in ["task_id": "bg_lost01"] }
        f.session.handleReady(["replay_epoch": "a"])
        await f.session.performSlash("/bg long job", recordInput: true)
        #expect(f.session.sideTasksOut())
        f.session.handleReady(["replay_epoch": "b"])
        #expect(!f.session.sideTasksOut())
        #expect(slashRows(f) == ["slash:/bg\n\(SideTaskKind.lost)"])
    }

    @Test func stoppedWaitingAfterTheLimitSaysSoAndALateResultStillLands() async {
        let f = MenusFixtureChat()
        f.script.on("prompt.background") { _, _ in ["task_id": "bg_slow01"] }
        await f.session.performSlash("/bg run the full suite", recordInput: true)
        #expect(f.session.sideTasksOut())
        #expect(!f.session.sideTasksOut(now: Date().addingTimeInterval(SideTasks.listenLimit + 1)))
        #expect(slashRows(f) == ["slash:/bg\n\(SideTaskKind.background.overdue)"])
        // The result comes after all (the chat open on another runtime): it replaces the start row.
        f.session.receive(finished("background.complete", f, task: "bg_slow01", text: "All green.", session: "ffffffff"))
        #expect(slashRows(f).isEmpty)
        #expect(sideRows(f) == ["side:bg\nBackground task finished: run the full suite\nAll green."])
    }

    @Test func leftChatKeepsListeningUntilTheResultLands() async {
        let f = MenusFixtureChat()
        f.script.on("prompt.btw") { _, _ in ["task_id": "btw_away01"] }
        var away: [Bool] = []
        f.session.onDrainingAwayChange = { away.append($0) }
        await f.session.performSlash("/btw still there?", recordInput: true)
        f.session.observing = true
        f.session.stopObserving()
        #expect(f.session.drainingAway)
        #expect(away == [true])
        f.session.receive(finished("btw.complete", f, task: "btw_away01", text: "Yes."))
        f.session.deliver()
        #expect(!f.session.drainingAway)
        #expect(away == [true, false])
        // The result is kept for this launch: the chat's next screen shows it.
        #expect(SideResultStash.shared.rows(scope: f.session.layoutScope).map(\.id) == [SideTaskRow.id(.btw, taskId: "btw_away01")])
    }

    @Test func aChatOpenedAgainShowsWhatLanded() async {
        let f = MenusFixtureChat()
        let at = Date()
        let earlier = ChatMessage(id: "stored-row-1-user", role: .user, parts: [.text("hi")], timestamp: at.addingTimeInterval(-60), rowId: 1)
        let later = ChatMessage(id: "stored-row-2-assistant", role: .assistant, parts: [.text("hello")], timestamp: at.addingTimeInterval(60),
                                rowId: 2)
        f.session.appendMessage(earlier)
        f.session.appendMessage(later)
        let kept = SideTaskRow.message(kind: .background, taskId: "bg_kept01", asked: "sum it up", text: "Three things.", at: at)
        SideResultStash.shared.add(kept, scope: f.session.layoutScope)
        f.session.restoreSideResults()
        f.session.restoreSideResults()
        #expect(f.session.messages.map(\.id) == ["stored-row-1-user", kept.id, "stored-row-2-assistant"])
        SideResultStash.shared.purge(accountId: f.session.account.id)
        #expect(SideResultStash.shared.rows(scope: f.session.layoutScope).isEmpty)
    }

    // MARK: Rows

    @Test func btwAnswerDrawsAsALineThatOpens() throws {
        let answer = SideTaskRow.message(kind: .btw, taskId: "btw_row001", asked: "what's\nthe port?", text: "It's **8080**.", at: Date())
        #expect(SideTaskRow.opensByItself(answer))
        let closed = ChatRowBuilder.build(.init(messages: [answer], isRunning: false, botName: "Ivy", expanded: []))
        let row = try #require(closed.first { $0.id == "\(answer.id)|bg" })
        guard case .backgroundResult(let b) = row.kind else { Issue.record("expected a background result row"); return }
        #expect(b.title == "By the way: what's the port?")
        #expect(b.result == "It's **8080**.", "its Markdown is kept: the opened card draws it (Mac polish #25)")
        #expect(b.aside && !b.process && !b.expanded)
        let open = ChatRowBuilder.build(.init(messages: [answer], isRunning: false, botName: "Ivy", expanded: ["\(answer.id)|bg"]))
        let opened = try #require(open.first { $0.id == "\(answer.id)|bg" })
        let layout = TextLayout.layout(opened, width: 390, style: ChatStyle.make(category: .large), keep: false)
        guard case .tool(let t) = layout.content else { Issue.record("expected a tool layout"); return }
        #expect(t.thoughtText != nil)
    }

    @Test func backgroundResultStaysOneLine() throws {
        let result = SideTaskRow.message(kind: .background, taskId: "bg_row001", asked: "run the tests", text: "", at: Date())
        #expect(!SideTaskRow.opensByItself(result))
        let row = try #require(ChatRowBuilder.build(.init(messages: [result], isRunning: false, botName: "Ivy", expanded: []))
            .first { $0.id == "\(result.id)|bg" })
        guard case .backgroundResult(let b) = row.kind else { Issue.record("expected a background result row"); return }
        #expect(b.title == "Background task finished: run the tests")
        #expect(b.result == SideTaskRow.noAnswer)
        #expect(!b.aside && !b.process)
    }

    @Test func commandsShowInTheSheetAgain() {
        #expect(!SlashCatalog.nativeUnsupported.contains("btw"))
        #expect(!SlashCatalog.nativeUnsupported.contains("bg"))
        #expect(!SlashCatalog.nativeUnsupported.contains("background"))
    }
}
