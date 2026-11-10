// Stream "questions" review fixes on the screen side: kept password sheets (in flight, failure, release), the stopped
// turn's refusal window, the bounded command layout, the sudo command block and a replay's locks in an open dock.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

/// A chat screen's model that shows the centre's requests for one runtime (no transcript work).
@MainActor
final class PromptSpyChat: ChatSessionModel, ChatPrompting {
    let title = "Spy"
    let profile = "spy"
    let head: JSONValue? = nil
    var messages: [ChatMessage] = [ChatMessage(id: "u", role: .user, parts: [.text("hi")], timestamp: Date(), rowId: 1)]
    var isRunning = false
    var hasOlder = false
    var isLoadingOlder = false
    var connection: ConnectionState = .ready
    var statusText: String? = nil
    var onChange: ((ChatChange) -> Void)?
    func start() {}
    func stopObserving() {}
    func loadOlder() {}
    func send(_ text: String) {}
    func stop() {}

    let link: PromptChatLink
    var reconnects = 0

    init(center: ServerRequestCenter, runtime: String) {
        link = PromptChatLink(center: center)
        link.onChange = { [weak self] in self?.link.screenOnChange?() }
        link.bind(runtime: runtime, profile: "spy", profileParam: nil, storedId: "stored")
    }

    var prompts: ChatPrompts { link.prompts }
    var onPromptsChange: (() -> Void)? {
        get { link.screenOnChange }
        set { link.screenOnChange = newValue }
    }
    func answerApproval(_ id: String, _ choice: ApprovalChoice) async throws { try await link.center?.answerApproval(id, choice) }
    func dismissExpiredApproval(_ id: String) { link.center?.dismissExpiredApproval(id) }
    func approvalTimeout(fresh: Bool) async -> TimeInterval { ApprovalExpiry.defaultTimeout }
    func clarifyDraft(_ requestId: String) -> ClarifyDraft? { link.center?.draft(requestId) }
    func saveClarifyDraft(_ requestId: String, _ draft: ClarifyDraft) { link.center?.saveDraft(requestId, draft) }
    func sendClarify(_ requestId: String, answers: [(qid: String, answer: String?)]) async throws {
        try await link.center?.sendClarify(requestId, answers: answers)
    }
    func skipClarify(_ requestId: String) async throws { try await link.center?.skipClarify(requestId) }
    func answerValue(_ requestId: String, _ value: String) async throws { try await link.center?.answerValue(requestId, value) }
    func promptsCameOnScreen() {}
    func reconnectNow() { reconnects += 1 }
}

@MainActor
@Suite("Questions: kept sheets and the screen", .serialized)
final class QuestionsScreenTests {
    let client = PromptFakeClient()
    let center: ServerRequestCenter
    let runtime = "rt-screen"

    init() {
        center = ServerRequestCenter(client: client, timing: ServerRequestCenterTests.timing, autoStart: true, enabled: true)
    }

    func deliver(_ id: String, _ method: String, _ params: JSONValue = [:], session: String? = nil) {
        var p = params.object ?? [:]
        p["session_id"] = .string(session ?? runtime)
        center.receive(GatewayEvent(type: LocalEvent.serverRequest, sessionId: session ?? runtime, seq: nil,
                                    payload: ["id": .string(id), "method": .string(method), "params": .object(p), "epoch": 1]))
    }

    /// The chat on screen in a real window, with the account's sheet store.
    func onScreen(_ store: PromptSheetStore) throws -> (ChatViewController, UIWindow, PromptSpyChat) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let spy = PromptSpyChat(center: center, runtime: runtime)
        let chat = ChatViewController(session: spy)
        chat.promptSheets = store
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UINavigationController(rootViewController: chat)
        window.makeKeyAndVisible()
        return (chat, window, spy)
    }

    func close(_ window: UIWindow) async {
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
        try? await Task.sleep(for: .milliseconds(50))
    }

    // Reviewer major 1: an offline Send kept the request but wiped the sheet (a new, empty one landed in the chip).
    @Test func anOfflineSendKeepsTheSameSheetUpWithItsText() async throws {
        let store = PromptSheetStore()
        center.onRemoved = { [weak store] ids in store?.drop(ids) }   // AppModel's wiring
        let (chat, window, spy) = try onScreen(store)
        #expect(await waitUntil(timeout: .seconds(5)) { chat.view.window != nil && chat.promptsUI != nil })
        try? await Task.sleep(for: .milliseconds(400))   // the window's first appearance settles
        deliver("srq-pw", "sudo", ["command": "apt-get install -y ffmpeg"])
        #expect(await waitUntil(timeout: .seconds(5)) {
            guard let nav = store.navigation("srq-pw") else { return false }
            return nav.presentingViewController != nil && !nav.isBeingPresented
        })
        let sheet = try #require(store.existing("srq-pw"))
        sheet.debugType(["hunter2"])
        client.failNextAnswer(RPCError.notSent(.socketDead))
        chat.promptsUI?.promptSheet(sheet, answer: "hunter2")
        #expect(sheet.debugSending)
        #expect(await waitUntil(timeout: .seconds(3)) { !sheet.debugSending })
        #expect(store.existing("srq-pw") === sheet, "the same sheet instance is kept")
        #expect(sheet.debugFieldTexts == ["hunter2"], "the typed password survives the failed send")
        let nav = try #require(store.navigation("srq-pw"))
        #expect(nav.presentingViewController != nil && !nav.isBeingDismissed, "the sheet is still up")
        #expect(chat.promptsUI?.debugPresented == "srq-pw")
        #expect(chat.promptsUI?.debugChipText == nil, "no chip: the sheet never went away")
        #expect(spy.prompts.values.first?.sending == false)

        // Online now: the answer goes, the sheet goes and its text is cleared.
        chat.promptsUI?.promptSheet(sheet, answer: "hunter2")
        #expect(await waitUntil(timeout: .seconds(3)) { store.existing("srq-pw") == nil })
        #expect(sheet.debugFieldTexts == [""])
        #expect(client.answers.map(\.result) == [["value": "hunter2"]])
        #expect(await waitUntil(timeout: .seconds(3)) { nav.presentingViewController == nil })
        await close(window)
    }

    // Reviewer major 2: the sheet and its frame held each other, and a kept sheet outlived its request.
    @Test func aDroppedSheetIsClearedAndReleased() {
        weak var weakSheet: PromptSheetController?
        weak var weakNav: UINavigationController?
        let store = PromptSheetStore()
        autoreleasepool {
            let (sheet, created) = store.sheet(for: ValuePrompt(id: "srq-x", kind: .vaultUnlock, params: [:]))
            #expect(created)
            #expect(store.sheet(for: ValuePrompt(id: "srq-x", kind: .vaultUnlock, params: [:])).sheet === sheet)
            weakSheet = sheet
            weakNav = store.navigation("srq-x")
            #expect(sheet.navigation === weakNav)
            sheet.debugType(["master"])
            store.setTucked("srq-x", true)
            store.drop(["srq-x"])
            #expect(sheet.debugFieldTexts == [""])
        }
        #expect(weakSheet == nil, "no retain cycle with its navigation controller")
        #expect(weakNav == nil)
    }

    // The account store follows the centre: answered elsewhere, withdrawn or signed out → dropped and cleared.
    @Test func theCentresRemovalsDropKeptSheets() {
        let store = PromptSheetStore()
        center.onRemoved = { [weak store] ids in store?.drop(ids) }
        deliver("srq-a", "secret", ["env_var": "KEY"])
        deliver("srq-b", "vault.code", ["site": "X"])
        let a = store.sheet(for: ValuePrompt(id: "srq-a", kind: .secret, params: [:])).sheet
        _ = store.sheet(for: ValuePrompt(id: "srq-b", kind: .vaultCode, params: [:]))
        a.debugType(["sk-123"])
        center.receive(GatewayEvent(type: "request.cancel", sessionId: "", seq: nil, payload: ["id": "srq-a", "reason": "timeout"]))
        #expect(store.ids == ["srq-b"])
        #expect(a.debugFieldTexts == [""])
        center.shutdown()
        #expect(store.ids.isEmpty)
    }

    // Leaving the chat keeps a tucked sheet (and its text) for the next screen; the old screen stops listening only
    // if no newer screen took over.
    @Test func aNewScreenReusesTheKeptSheetAndTheOldOneLetsGo() async throws {
        let store = PromptSheetStore()
        deliver("srq-pw", "sudo", ["command": "ls"])
        let spy = PromptSpyChat(center: center, runtime: runtime)
        let first = ChatViewController(session: spy)
        first.promptSheets = store
        first.loadViewIfNeeded()                        // off screen: the prompt waits in the chip
        let sheet = try #require(store.existing("srq-pw"))
        sheet.debugType(["pw"])
        let second = ChatViewController(session: spy)
        second.promptSheets = store
        second.loadViewIfNeeded()
        #expect(store.existing("srq-pw") === sheet)
        first.promptsUI?.uninstall()
        #expect(spy.onPromptsChange != nil, "the newer screen still listens")
        #expect(sheet.debugFieldTexts == ["pw"])
        second.promptsUI?.uninstall()
        #expect(spy.onPromptsChange == nil)
    }

    // Reviewer minor: `turn.interrupted` stays set until the next send; only the unwinding stopped turn refuses.
    @Test func aStopRefusesOnlyWhileTheStoppedTurnUnwinds() async {
        let chat = LiveChatSession(client: client, account: client.account, profile: "default", storedSessionId: "stored",
                                   title: "Hermes", head: nil, cache: makeTempCache(), resolveSessionId: nil)
        chat.attachPrompts(center)
        chat.bindRuntime(["session_id": .string(runtime)])
        chat.turn.interrupted = true
        chat.turn.stopTerminalPending = true
        deliver("srq-1", "approval", ["command": "ls", "description": "list", "request_id": "q1"])
        #expect(await waitUntil { self.client.answers.contains { $0.id == "srq-1" && $0.code == -32603 } })
        #expect(chat.prompts.approvals.isEmpty)
        // The stopped turn's terminal frame came; a later turn (another client, cron, a goal) asks: the card shows.
        chat.stopTerminalReached()
        deliver("srq-2", "approval", ["command": "ls", "description": "list", "request_id": "q2"])
        #expect(chat.prompts.approvals.map(\.id) == ["srq-2"])
        #expect(!client.answers.contains { $0.id == "srq-2" })
    }

    // 2026-10-23/24 gateway errors.log: 168 `approval.pending` for runtimes it had reaped. A new socket no longer asks for
    // the on-screen chat's runtime before its reconnect's `session.activate` confirms it; a reaped one resumes first.
    @Test func approvalsReplayOnlyOnceTheRuntimeIsConfirmed() async {
        let chat = LiveChatSession(client: client, account: client.account, profile: "default", storedSessionId: "stored",
                                   title: "Hermes", head: nil, cache: makeTempCache(), resolveSessionId: nil)
        chat.attachPrompts(center)
        chat.bindRuntime(["session_id": .string(runtime)])
        chat.observing = true
        let fresh = "rt-fresh"
        client.onCall { method, _ in
            switch method {
            case "session.activate": throw RPCError(code: 4001, message: "session not in memory", data: nil)
            case "session.resume": return ["session_id": .string(fresh)]
            default: return [:]
            }
        }
        let before = client.calls("approval.pending").count
        center.receive(GatewayEvent(type: "gateway.ready", sessionId: "", seq: nil, payload: [:]))
        await chat.reconnect(reason: "gateway.ready")
        #expect(await waitUntil { self.client.calls("approval.pending").count > before })
        try? await Task.sleep(for: .milliseconds(100))
        let asked = client.calls("approval.pending").dropFirst(before).compactMap { $0.params["session_id"]?.string }
        #expect(asked == [fresh])
        // A runtime the activate confirms is asked for once.
        client.onCall { _, _ in [:] }
        await chat.reconnect(reason: "gateway.ready")
        #expect(await waitUntil { self.client.calls("approval.pending").dropFirst(before).count == 2 })
        #expect(client.calls("approval.pending").last?.params["session_id"]?.string == fresh)
        chat.observing = false
    }

    // Reviewer minor: header words wired through computeStatus.
    @Test func theHeaderSaysItWaits() async {
        let chat = LiveChatSession(client: client, account: client.account, profile: "default", storedSessionId: "stored",
                                   title: "Hermes", head: nil, cache: makeTempCache(), resolveSessionId: nil)
        chat.attachPrompts(center)
        chat.bindRuntime(["session_id": .string(runtime)])
        deliver("srq-c", "clarify", ["questions": [["qid": "q0", "question": "Which?", "choices": ["a", "b"]]]])
        #expect(chat.computeStatus() == "Waiting for your reply")
        deliver("srq-v", "vault.unlock_prompt", ["backend": "bitwarden"])
        #expect(chat.computeStatus() == "Waiting for your approval")
    }
}

@MainActor
@Suite("Questions: bounded command layout and replayed locks")
struct QuestionsLayoutFixTests {
    @Test func boundedKeepsEightLinesOfAtMost300Characters() {
        for (input, lines, text, cut) in [("a\nb", 8, "a\nb", false), ("a\nb\n", 2, "a\nb", false), ("a\nb\nc", 2, "a\nb", true)] {
            let out = PromptLayout.bounded(input, maxLines: lines)
            #expect(out.text == text && out.cut == cut, "\(input.debugDescription)")
        }
        let wide = String(repeating: "x", count: 50_000)
        let (head, cut) = PromptLayout.bounded(wide, maxLines: 8)
        #expect(head.count == PromptLayout.boundedLineChars && cut)
        let heredoc = "python - <<'EOF'\n" + (1...5_000).map { "print(\($0))" }.joined(separator: "\n") + "\nEOF"
        let (lines, cutLines) = PromptLayout.bounded(heredoc, maxLines: 8)
        #expect(lines.split(separator: "\n").count == 8 && cutLines)
    }

    @Test func aHugeCommandLaysOutOnlyItsHeadWithShowAll() throws {
        let heredoc = "python - <<'EOF'\n" + (1...5_000).map { "print('step \($0) of a long generated script')" }.joined(separator: "\n") + "\nEOF"
        let card = ApprovalCardRow(id: "srq-a", stackExpired: false, command: heredoc, description: "python", showsDescription: false,
                                   position: 1, total: 1, allowSession: true, allowAlways: true, expired: false, answering: nil,
                                   leaving: false, clockKey: "k", firstSeen: Date())
        let start = CACurrentMediaTime()
        let layout = PromptLayout.approval(card, gap: 6, width: 402, category: .large)
        #expect(CACurrentMediaTime() - start < 0.1, "bounded: no full layout of a 200 KB command")
        guard case .prompt(let row) = layout.content else { Issue.record("layout"); return }
        #expect(row.approval?.showAllFrame != nil)
        // Eight short lines and nothing more: no Show All. Eight lines with a ninth after: Show All.
        let eight = (1...8).map { "echo \($0)" }.joined(separator: "\n")
        let fits = PromptLayout.approval(ApprovalCardRow(id: "a", stackExpired: false, command: eight, description: "", showsDescription: false,
                                                         position: 1, total: 1, allowSession: true, allowAlways: true, expired: false,
                                                         answering: nil, leaving: false, clockKey: "k", firstSeen: Date()),
                                         gap: 6, width: 402, category: .large)
        guard case .prompt(let f) = fits.content else { Issue.record("layout"); return }
        #expect(f.approval?.showAllFrame == nil)
        let (_, cut) = PromptLayout.clamped(NSAttributedString(string: eight + "\necho 9"), width: 360, maxLines: 8)
        #expect(cut)
    }

    @Test func theSudoCommandClampsWithShowAll() {
        func block(_ command: String) -> PromptCommandBlock {
            let b = PromptCommandBlock(command: command)
            b.frame = CGRect(x: 0, y: 0, width: 360, height: 400)
            b.setNeedsLayout()
            b.layoutIfNeeded()
            b.layoutIfNeeded()
            return b
        }
        #expect(!block("apt-get install -y ffmpeg").debugShowsAll)
        let long = (1...40).map { "echo \"step \($0)\"" }.joined(separator: "\n")
        let clamped = block(long)
        #expect(clamped.debugShowsAll)
        #expect(clamped.debugText.split(separator: "\n").count == PromptCommandBlock.maxLines)
        #expect(block(String(repeating: "a", count: 2_000)).debugShowsAll)
    }

    @Test func replayedLocksFillOnlyUntouchedQuestions() {
        let prompt = ClarifyPrompt(id: "srq-c", questions: [
            ClarifyQuestion(qid: "q0", question: "Branch?", choices: ["main (Recommended)", "staging"], multiSelect: false),
            ClarifyQuestion(qid: "q1", question: "Checks?", choices: ["Tests", "Lint"], multiSelect: true),
            ClarifyQuestion(qid: "q2", question: "Name?", choices: nil, multiSelect: false),
        ])
        let dock = QuestionDockView(prompt: prompt, draft: ClarifyDraft(page: 1, stages: ["q1": ClarifyStage(choices: ["Tests"])]))
        #expect(dock.mergeReplayed(["q0": "staging", "q1": #"["Lint"]"#, "q2": "v2"]))
        #expect(dock.draft.stages["q0"]?.choices == ["staging"])
        #expect(dock.draft.stages["q1"]?.choices == ["Tests"], "the user's own pick wins")
        #expect(dock.draft.stages["q2"]?.draft == "v2")
        #expect(dock.draft.page == 1)
        #expect(!dock.mergeReplayed(["q0": "main"]), "nothing left untouched")
        #expect(dock.answers.map(\.answer) == ["staging", #"["Tests"]"#, "v2"])
    }
}
