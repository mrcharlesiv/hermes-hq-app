// Stream "questions" live checks 2 and 9–15 (docs/spec/1x-questions.md §7.2) against the questions fixture on
// 127.0.0.1:9720 (scripts/fixtures/questions-gateway.py, credentials build/fixtures/questions.json). Skipped when the
// port is closed. Start it with:
//   python3 scripts/fixtures/questions-gateway.py --port 9720 --credentials build/fixtures/questions.json

import Foundation
import Testing
@testable import HermesHQNative

nonisolated extension Fixtures {
    /// `HQ_QUESTIONS_PORT` (TEST_RUNNER_HQ_QUESTIONS_PORT) moves it (integration runs on its own ports).
    static let questionsPort: UInt16 = ProcessInfo.processInfo.environment["HQ_QUESTIONS_PORT"].flatMap(UInt16.init) ?? 9720
    /// Checked once: every test's trait is evaluated together, and seven connects at once can overflow the fixture's
    /// listen backlog (one refused connect skipped a test).
    static let questionsAvailable: Bool = portOpen(questionsPort) && credentials("questions.json") != nil

    @discardableResult
    static func questions(_ path: String, _ json: [String: Any]? = nil) async throws -> JSONValue {
        try await control(questionsPort, path, method: json == nil ? "GET" : "POST", json: json)
    }

    /// The fixture's ledger entries for one srq method, oldest first.
    static func ledger(_ method: String) async throws -> [JSONValue] {
        (try await questions("/__fixture/requests")["requests"]?.array ?? []).filter { $0["method"]?.string == method }
    }
}

@MainActor
@Suite("Questions: live fixture", .serialized, .enabled(if: Fixtures.questionsAvailable))
final class QuestionsLiveTests {
    let vault = Fixtures.testVault("questions")
    let stored = "20260929_120000_aabbcc01"
    let runtime = "5cc537d1"
    var client: LiveGatewayClient!
    var center: ServerRequestCenter!
    var chat: LiveChatSession!

    private func open() async throws {
        _ = try await Fixtures.questions("/__fixture/reset", [:])
        vault.removeAll()
        let creds = try #require(Fixtures.credentials("questions.json"))
        let service = SignInService(store: AccountStore(vault: vault))
        let account = try await service.signInWithPassword(address: creds.url, username: creds.username, password: creds.password)
        service.client(for: account).shutdown()
        let saved = try #require(vault.peek())
        let transport = HTTPTransport()
        transport.installCookies(saved.cookies ?? [])
        client = LiveGatewayClient(stored: saved, transport: transport, vault: vault, verified: true, watchNetwork: false)
        try await waitFor(client, .ready)
        var timing = ServerRequestCenter.Timing.standard
        timing.probeDebounce = .milliseconds(100)
        center = ServerRequestCenter(client: client, timing: timing)
        chat = LiveChatSession(client: client, account: client.account, profile: "default", storedSessionId: stored,
                               title: "Hermes", head: nil, cache: makeTempCache(), resolveSessionId: nil)
        chat.attachPrompts(center)
        chat.turnEndReadDelay = .milliseconds(200)
        chat.start()
        #expect(await waitUntil(timeout: .seconds(10)) { self.chat.openSettled })
    }

    /// Check 15 after every test: nothing this stream sent was refused with 4000 (strict params).
    private func expectNoStrictParamErrors() async throws {
        let state = try await Fixtures.questions("/__fixture/requests")
        #expect(state["errors4000"]?.array?.isEmpty == true, "4000: \(state["errors4000"] ?? .null)")
    }

    private func close() {
        chat?.stopObserving()
        center?.shutdown()
        client?.shutdown()
        vault.removeAll()
    }

    // Checks 2 and 9: advertised on every socket, delivered, answered once; approval.pending with session_id[,profile].
    @Test func approvalRunAnswersOnceAndReplaysPending() async throws {
        try await open()
        defer { close() }
        chat.send("please approve")
        #expect(await waitUntil(timeout: .seconds(10)) { self.chat.prompts.approvals.count == 1 })
        #expect(await waitUntil(timeout: .seconds(3)) { self.chat.statusText == "Waiting for your approval" })
        let approval = try #require(chat.prompts.approvals.first)
        #expect(approval.command == "git push --force origin main")
        #expect(approval.allowSession && approval.allowAlways)

        let state = try await Fixtures.questions("/__fixture/requests")
        let sockets = state["sockets"]?.array ?? []
        #expect(sockets.allSatisfy { $0["frames"]?.array?.first?.string == "client.capabilities" })
        #expect(sockets.contains { $0["advertised"]?.bool == true && $0["connected"]?.bool == true })
        let request = try #require(try await Fixtures.ledger("approval").last)
        #expect(request["delivered"]?.array?.isEmpty == false)

        try await chat.answerApproval(approval.id, .once)
        #expect(await waitUntil(timeout: .seconds(5)) { self.chat.prompts.approvals.isEmpty })
        #expect(await waitUntil(timeout: .seconds(10)) { !self.chat.isRunning })
        let answered = try #require(try await Fixtures.ledger("approval").last)
        let answers = answered["answers"]?.array ?? []
        #expect(answers.count == 1)
        #expect(answers.first?["result"] == ["choice": "once"])
        #expect(answered["outcome"]?.string == "answered")
        let rpc = try await Fixtures.questions("/__fixture/requests")["rpc"]?.array ?? []
        let pending = rpc.filter { $0["method"]?.string == "approval.pending" }
        #expect(!pending.isEmpty)
        #expect(pending.allSatisfy { Set($0["params"]?.object?.keys.map { $0 } ?? []).isSubset(of: ["session_id", "profile"]) })
        #expect(pending.last?["params"]?["session_id"]?.string == runtime)
        try await expectNoStrictParamErrors()
    }

    // Check 10: three locks in order with no session_id, outcome submitted, the reply streams, history shows the card.
    @Test func askLocksInOrderAndTheSettledCardSurvivesAReload() async throws {
        try await open()
        defer { close() }
        chat.send("ask me")
        #expect(await waitUntil(timeout: .seconds(10)) { self.chat.prompts.clarify != nil })
        let clarify = try #require(chat.prompts.clarify)
        #expect(clarify.questions.map(\.qid) == ["q0", "q1", "q2"])
        #expect(chat.prompts.needsInput == .reply)
        #expect(await waitUntil(timeout: .seconds(3)) { self.chat.statusText == "Waiting for your reply" })
        chat.saveClarifyDraft(clarify.id, ClarifyDraft(page: 2, stages: [
            "q0": ClarifyStage(choices: ["main (Recommended)"]), "q1": ClarifyStage(choices: ["Lint"], draft: "changelog", other: true),
        ]))
        let draft = try #require(chat.clarifyDraft(clarify.id))
        let answers = clarify.questions.map { (qid: $0.qid, answer: ClarifyStaging.stagedAnswer($0, draft.stages[$0.qid] ?? ClarifyStage())) }
        try await chat.sendClarify(clarify.id, answers: answers)
        #expect(chat.prompts.clarify == nil)
        #expect(chat.prompts.sentClarify?.rows.map(\.answer) == ["main", "Lint, changelog", nil])

        let rpc = try await Fixtures.questions("/__fixture/requests")["rpc"]?.array ?? []
        let locks = rpc.filter { $0["method"]?.string == "clarify.lock" }
        #expect(locks.map { $0["params"]?["question_id"]?.string } == ["q0", "q1", "q2"])
        #expect(locks.allSatisfy { $0["params"]?["session_id"] == nil })
        #expect(locks[1]["params"]?["answer"]?.string == #"["Lint","changelog"]"#)
        #expect(locks[2]["params"]?["answer"]?.isNull == true)
        #expect(try await Fixtures.ledger("clarify").last?["outcome"]?.string == "submitted")

        #expect(await waitUntil(timeout: .seconds(10)) { !self.chat.isRunning })
        #expect(chat.messages.last?.plainText.contains("Thanks") == true)
        // The live tool part carries the settled rows, and a fresh history read folds the same card.
        #expect(await waitUntil(timeout: .seconds(5)) { self.chat.prompts.sentClarify == nil })
        chat.stopObserving()
        let reread = LiveChatSession(client: client, account: client.account, profile: "default", storedSessionId: stored,
                                     title: "Hermes", head: nil, cache: makeTempCache(), resolveSessionId: nil)
        reread.start()
        #expect(await waitUntil(timeout: .seconds(10)) { reread.openSettled })
        let calls = reread.messages.flatMap(\.parts).compactMap { part -> ToolCall? in
            if case .tool(let c) = part, c.name == "clarify" { return c } else { return nil }
        }
        let rows = try #require(ClarifySettled.rows(fromSummary: calls.last?.summary))
        #expect(rows.map(\.answer) == ["main", "Lint, changelog", ""])
        // A null lock is in the answers map: Hermes reports it "skipped" (only a qid never locked is "unanswered").
        #expect(rows.last?.unanswered == false)
        reread.stopObserving()
        try await expectNoStrictParamErrors()
    }

    // Checks 2 and 11: a kick with an open clarify (one answer locked, a draft) comes back with the same page and picks;
    // nothing is answered twice; the new socket advertises first.
    @Test func aReconnectRestoresTheDockFromOpenRequests() async throws {
        try await open()
        defer { close() }
        chat.send("ask again")
        #expect(await waitUntil(timeout: .seconds(10)) { self.chat.prompts.clarify != nil })
        let id = try #require(chat.prompts.clarify?.id)
        _ = try await client.call("clarify.lock", ["request_id": .string(id), "question_id": "q0", "answer": "staging", "profile": "default"])
        chat.saveClarifyDraft(id, ClarifyDraft(page: 1, stages: ["q1": ClarifyStage(choices: ["Docs"])]))
        let sockets = try await Fixtures.questions("/__fixture/requests")["sockets"]?.array?.count ?? 0
        _ = try await Fixtures.questions("/__fixture/kick", [:])
        #expect(await waitUntil(timeout: .seconds(15)) {
            self.center.entry(id)?.params["answers"]?["q0"]?.string == "staging"
        })
        #expect(chat.prompts.clarify?.id == id)
        #expect(chat.prompts.clarify?.lockedAnswers["q0"] == .some("staging"))
        #expect(chat.clarifyDraft(id)?.page == 1)
        #expect(chat.clarifyDraft(id)?.stages["q1"]?.choices == ["Docs"])
        let state = try await Fixtures.questions("/__fixture/requests")
        let all = state["sockets"]?.array ?? []
        #expect(all.count > sockets)
        #expect(all.allSatisfy { $0["frames"]?.array?.first?.string == "client.capabilities" })
        let request = try #require(try await Fixtures.ledger("clarify").last)
        let responses = (request["answers"]?.array ?? []).filter { $0["kind"]?.string != "lock" }
        #expect(responses.isEmpty)
        try await chat.skipClarify(id)
        #expect(await waitUntil(timeout: .seconds(10)) { !self.chat.isRunning })
        try await expectNoStrictParamErrors()
    }

    // Check 12: another client answers first — no event reaches us; the card goes after the next tool event's probe.
    @Test func anAnswerElsewhereIsNoticedWithoutAToast() async throws {
        try await open()
        defer { close() }
        chat.send("please approve")
        #expect(await waitUntil(timeout: .seconds(10)) { self.chat.prompts.approvals.count == 1 })
        let id = try #require(chat.prompts.approvals.first?.id)
        _ = try await Fixtures.questions("/__fixture/answer", ["id": id, "result": ["choice": "once"]])
        #expect(await waitUntil(timeout: .seconds(4)) { self.chat.prompts.approvals.isEmpty })
        let request = try #require(try await Fixtures.ledger("approval").last)
        #expect(request["outcome"]?.string == "answered-elsewhere")
        let ours = (request["answers"]?.array ?? []).filter { $0["socket"]?.string != "other-client" }
        #expect(ours.isEmpty)
        #expect(await waitUntil(timeout: .seconds(10)) { !self.chat.isRunning })
        try await expectNoStrictParamErrors()
    }

    // Check 13: approvals.timeout 20 → "Expires within 0:20"; the fixture's timeout withdraws it and leaves the notice.
    @Test func theTimeoutIsReadAndTheWithdrawalLeavesANotice() async throws {
        try await open()
        defer { close() }
        _ = try await Fixtures.questions("/__fixture/config", ["approvals_timeout": 20])
        chat.send("please approve")
        #expect(await waitUntil(timeout: .seconds(10)) { self.chat.prompts.approvals.count == 1 })
        let approval = try #require(chat.prompts.approvals.first)
        let timeout = await chat.approvalTimeout(fresh: false)
        #expect(timeout == 20)
        #expect(ApprovalExpiry.label(seenAt: approval.firstSeen, timeout: timeout, now: approval.firstSeen) == "Expires within 0:20")
        #expect(await waitUntil(timeout: .seconds(26)) { self.chat.prompts.approvals.isEmpty })
        #expect(chat.messages.contains { $0.id.hasPrefix("local-notice-approval") })
        #expect(try await Fixtures.ledger("approval").last?["outcome"]?.string == "timeout")
        try await expectNoStrictParamErrors()
    }

    // Check 14: desktop panes and setup cards.
    @Test func panesAreDeclinedOnlyWithDeclineSupportAndSetupGetsNoHandler() async throws {
        try await open()
        defer { close() }
        chat.send("terminal please")
        #expect(await waitUntilAsync(timeout: .seconds(10)) { (try? await Fixtures.ledger("terminal.read").last?["answers"]?.array?.count) == 1 })
        let declined = try #require(try await Fixtures.ledger("terminal.read").last)
        #expect(declined["answers"]?[0]?["code"]?.int == 4404)
        #expect(await waitUntil(timeout: .seconds(10)) { !self.chat.isRunning })

        chat.send("setup please")
        #expect(await waitUntilAsync(timeout: .seconds(10)) { (try? await Fixtures.ledger("setup_choose").last?["answers"]?.array?.count) == 1 })
        #expect(try await Fixtures.ledger("setup_choose").last?["answers"]?[0]?["code"]?.int == -32601)
        #expect(await waitUntil(timeout: .seconds(10)) { !self.chat.isRunning })

        // An older backend: no capabilities answer, no declines → silence (the request times out on the gateway).
        _ = try await Fixtures.questions("/__fixture/config", ["capabilities": "-32601", "declines_not_shown": false, "pane_timeout": 3])
        _ = try await Fixtures.questions("/__fixture/kick", [:])
        #expect(await waitUntil(timeout: .seconds(15)) { self.client.state == .ready && self.chat.connection == .ready })
        try? await Task.sleep(for: .milliseconds(500))
        #expect(!client.declinesNotShown)
        chat.send("terminal again")
        #expect(await waitUntilAsync(timeout: .seconds(15)) { (try? await Fixtures.ledger("terminal.read").last?["outcome"]?.string) == "timeout" })
        #expect(try await Fixtures.ledger("terminal.read").last?["answers"]?.array?.isEmpty == true)
        #expect(await waitUntil(timeout: .seconds(10)) { !self.chat.isRunning })
        try await expectNoStrictParamErrors()
    }

    // Value prompts over the wire: redacted ledger, {value} answers, "" declines.
    @Test func valuePromptsAnswerAndDecline() async throws {
        try await open()
        defer { close() }
        chat.send("sudo now")
        #expect(await waitUntil(timeout: .seconds(10)) { self.chat.prompts.values.first?.kind == .sudo })
        try await chat.answerValue(try #require(chat.prompts.values.first?.id), "")
        #expect(await waitUntil(timeout: .seconds(10)) { !self.chat.isRunning })
        #expect(try await Fixtures.ledger("sudo").last?["answers"]?[0]?["result"] == ["value": "<0 chars>"])

        chat.send("login please")
        #expect(await waitUntil(timeout: .seconds(10)) { self.chat.prompts.values.first?.kind == .vaultSaveLogin })
        let login = try #require(chat.prompts.values.first)
        #expect(login.params["site"]?.string == "Example Shop")
        try await chat.answerValue(login.id, #"{"identifier":"me@example.com","password":"x1"}"#)
        #expect(await waitUntil(timeout: .seconds(10)) { !self.chat.isRunning })
        let answer = try #require(try await Fixtures.ledger("vault.save_login").last?["answers"]?[0]?["result"])
        #expect(answer["value_keys"] == ["identifier", "password"])
        try await expectNoStrictParamErrors()
    }

}

/// `waitUntil` for conditions that read the fixture.
@MainActor
func waitUntilAsync(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return await condition()
}
