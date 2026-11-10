// Stream "questions" unit checks 4 and 5 (docs/spec/1x-questions.md §7.1): the centre's state rules (§3.3) and the
// answer table (§2.3), against a recording fake client.

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

/// A GatewayClient that also answers server requests, recording every frame and call.
nonisolated final class PromptFakeClient: GatewayClient, ServerRequestAnswering, Sendable {
    struct Answer: Sendable, Equatable { var id: String; var result: JSONValue?; var code: Int?; var message: String? }
    struct Call: Sendable { var method: String; var params: JSONValue }
    private struct State {
        var answers: [Answer] = []
        var calls: [Call] = []
        var declines = true
        var failNext: RPCError?
        var respondDelay: Duration = .zero
        var epoch = 1
        var call: @Sendable (String, JSONValue) async throws -> JSONValue = { _, _ in [:] }
        var rest: @Sendable (String, [URLQueryItem]) throws -> Data = { _, _ in Data("{}".utf8) }
        var events: [UUID: AsyncStream<GatewayEvent>.Continuation] = [:]
    }
    private let state = Mutex(State())
    let account = GatewayAccount(id: "test", baseURL: URL(string: "http://127.0.0.1:1")!, kind: .password, username: "t", label: "t")

    var answers: [Answer] { state.withLock { $0.answers } }
    var calls: [Call] { state.withLock { $0.calls } }
    func calls(_ method: String) -> [Call] { calls.filter { $0.method == method } }
    func setDeclines(_ on: Bool) { state.withLock { $0.declines = on } }
    func failNextAnswer(_ error: RPCError) { state.withLock { $0.failNext = error } }
    func setRespondDelay(_ delay: Duration) { state.withLock { $0.respondDelay = delay } }
    /// The socket epoch answers go out on.
    func setEpoch(_ epoch: Int) { state.withLock { $0.epoch = epoch } }
    func onCall(_ responder: @escaping @Sendable (String, JSONValue) async throws -> JSONValue) { state.withLock { $0.call = responder } }
    func onRest(_ responder: @escaping @Sendable (String, [URLQueryItem]) throws -> Data) { state.withLock { $0.rest = responder } }

    func respond(serverRequest id: String, result: JSONValue) async throws -> Int {
        let (fail, delay) = state.withLock { s -> (RPCError?, Duration) in defer { s.failNext = nil }; return (s.failNext, s.respondDelay) }
        if delay > .zero { try? await Task.sleep(for: delay) }
        if let fail { throw fail }
        return state.withLock { $0.answers.append(Answer(id: id, result: result)); return $0.epoch }
    }

    func fail(serverRequest id: String, code: Int, message: String) async throws -> Int {
        let fail = state.withLock { s -> RPCError? in defer { s.failNext = nil }; return s.failNext }
        if let fail { throw fail }
        return state.withLock { $0.answers.append(Answer(id: id, code: code, message: message)); return $0.epoch }
    }

    var declinesNotShown: Bool { state.withLock { $0.declines } }

    func rest(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async throws -> Data {
        let responder = state.withLock { $0.rest }
        return try responder(path, query)
    }

    func call(_ method: String, _ params: JSONValue, timeout: Duration) async throws -> JSONValue {
        let responder = state.withLock { s -> @Sendable (String, JSONValue) async throws -> JSONValue in
            s.calls.append(Call(method: method, params: params)); return s.call
        }
        return try await responder(method, params)
    }

    func events() -> AsyncStream<GatewayEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            state.withLock { $0.events[id] = continuation }
            continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.events.removeValue(forKey: id) } }
        }
    }

    func connectionStates() -> AsyncStream<ConnectionState> {
        AsyncStream { $0.yield(.ready) }
    }

    var latestReady: JSONValue? { nil }
    func appDidBecomeActive() {}
    func appDidEnterBackground() {}
    func shutdown() {}
}

@MainActor
@Suite("Questions: the centre")
final class ServerRequestCenterTests {
    let client = PromptFakeClient()
    let center: ServerRequestCenter
    let session = "5cc537d1"

    static var timing: ServerRequestCenter.Timing {
        var timing = ServerRequestCenter.Timing.standard
        timing.probeDebounce = .milliseconds(10)
        timing.leaving = .zero
        timing.staleDrop = .milliseconds(150)
        timing.undeliveredAfter = .milliseconds(50)
        return timing
    }

    init() {
        center = ServerRequestCenter(client: client, timing: Self.timing, autoStart: true, enabled: true)
    }

    // MARK: Helpers

    func deliver(_ id: String, _ method: String, _ params: JSONValue = [:], session: String? = nil, replayed: Bool = false, epoch: Int = 1) {
        var p = params.object ?? [:]
        p["session_id"] = .string(session ?? self.session)
        center.receive(GatewayEvent(type: LocalEvent.serverRequest, sessionId: session ?? self.session, seq: nil,
                                    payload: ["id": .string(id), "method": .string(method), "params": .object(p),
                                              "replayed": .bool(replayed), "epoch": .number(Double(epoch))]))
    }

    func openRequests(_ ids: [String], pending: JSONValue = .null, method: String = "session.activate", session: String? = nil) {
        center.receive(GatewayEvent(type: LocalEvent.openRequests, sessionId: session ?? self.session, seq: nil,
                                    payload: ["session_id": .string(session ?? self.session), "ids": .array(ids.map(JSONValue.string)),
                                              "pending_approval": pending, "method": .string(method)]))
    }

    func event(_ type: String, _ payload: JSONValue = [:], session: String? = nil) {
        center.receive(GatewayEvent(type: type, sessionId: session ?? self.session, seq: nil, payload: payload))
    }

    var prompts: ChatPrompts { center.prompts(for: [session]) }

    static let approval: JSONValue = ["command": "git push --force origin main", "description": "git force push",
                                      "request_id": "9b1d6f0e2c4a4e83a1d2c3b4e5f60718", "choices": ["once", "session", "always", "deny"]]
    static let clarify: JSONValue = ["questions": [["qid": "q0", "question": "Which branch?", "choices": ["main (Recommended)", "staging"], "multi_select": false],
                                                   ["qid": "q1", "question": "Name?", "choices": .null, "multi_select": false]]]

    // MARK: Rule 1 and the answer table

    @Test func windowOwnedRequestsAreDeclinedOnlyWhenTheBackendSupportsIt() async {
        for method in ServerRequestCenter.windowOwned { deliver("srq-\(method)", method) }
        #expect(await waitUntil { self.client.answers.count == 5 })
        #expect(client.answers.allSatisfy { $0.code == 4404 && $0.message == "This window is not showing the session." })
        // A re-delivery is not declined twice.
        deliver("srq-tour", "tour", replayed: true)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(client.answers.count == 5)

        client.setDeclines(false)
        deliver("srq-terminal-2", "terminal.read")
        try? await Task.sleep(for: .milliseconds(30))
        #expect(client.answers.count == 5)        // silent: no frame
        #expect(prompts.isEmpty)
    }

    @Test func unknownMethodsGetNoHandler() async {
        deliver("srq-setup", "setup_choose", ["kind": "provider", "question": "?", "multi_select": false])
        deliver("srq-install", "display.install.sudo")
        deliver("srq-new", "something.new")
        #expect(await waitUntil { self.client.answers.count == 3 })
        #expect(client.answers.allSatisfy { $0.code == -32601 })
        #expect(client.answers.map(\.message).contains("no handler for server request: setup_choose"))
    }

    @Test func aClarifyWithNoUsableQuestionIsAnsweredEmpty() async {
        deliver("srq-c", "clarify", ["questions": [["qid": "", "question": "x"]]])
        #expect(await waitUntil { self.client.answers.count == 1 })
        #expect(client.answers[0].result == .object([:]))
        #expect(prompts.clarify == nil)
    }

    @Test func approvalAnswersOnceUnderConcurrentTaps() async throws {
        deliver("srq-a", "approval", Self.approval)
        #expect(prompts.approvals.count == 1)
        #expect(prompts.needsInput == .approval)
        client.setRespondDelay(.milliseconds(50))
        async let first: Void = center.answerApproval("srq-a", .once)
        // Two async lets start in no set order, so the second tap waits until the first is on its way.
        for _ in 0..<1000 where prompts.approvals.first?.answering == nil { await Task.yield() }
        async let second: Void = center.answerApproval("srq-a", .deny)
        _ = try await (first, second)
        #expect(client.answers == [PromptFakeClient.Answer(id: "srq-a", result: ["choice": "once"])])
        #expect(await waitUntil { self.prompts.approvals.isEmpty })
        // approval.pending runs after the answer, with session_id only (no profile bound in this test).
        #expect(await waitUntil { !self.client.calls("approval.pending").isEmpty })
        #expect(client.calls("approval.pending").last?.params == ["session_id": .string(session)])
        // A late re-delivery of the answered id is ignored.
        deliver("srq-a", "approval", Self.approval, replayed: true)
        #expect(prompts.approvals.isEmpty)
    }

    /// #256: a local alert's answer waits for its request (a cold launch replays it late), and one that never comes,
    /// or was answered already, is `.gone` rather than dropped in silence.
    @Test func anAlertsAnswerWaitsForItsRequestOrSaysItIsGone() async throws {
        #expect(try await center.answerApprovalFromAlert("srq-none", .once, within: .milliseconds(300)) == .gone)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            self.deliver("srq-late", "approval", Self.approval)
        }
        #expect(try await center.answerApprovalFromAlert("srq-late", .deny, within: .seconds(3)) == .sent)
        #expect(client.answers == [PromptFakeClient.Answer(id: "srq-late", result: ["choice": "deny"])])
        #expect(try await center.answerApprovalFromAlert("srq-late", .once, within: .milliseconds(300)) == .gone)
        #expect(client.answers.count == 1)
    }

    @Test func aFailedSendPutsTheRequestBack() async {
        deliver("srq-a", "approval", Self.approval)
        client.failNextAnswer(RPCError.connectionLost("answer"))
        await #expect(throws: PromptAnswerError.self) { try await self.center.answerApproval("srq-a", .once) }
        #expect(prompts.approvals.first?.answering == nil)
        #expect(!(center.debugRecentlyAnswered.contains("srq-a")))
        // Its re-delivery shows again, and a second try goes out once.
        deliver("srq-a", "approval", Self.approval, replayed: true)
        try? await center.answerApproval("srq-a", .session)
        #expect(client.answers == [PromptFakeClient.Answer(id: "srq-a", result: ["choice": "session"])])
    }

    @Test func notConnectedIsTheOfflineCopy() async {
        deliver("srq-v", "sudo", ["command": "apt-get install -y ffmpeg"])
        client.failNextAnswer(RPCError.notSent(.socketDead))
        do {
            try await center.answerValue("srq-v", "x")
            Issue.record("expected offline")
        } catch let error as PromptAnswerError {
            #expect(error.offline)
            #expect(error.message == "Hermes is offline right now. Reconnect, then send it again.")
        } catch { Issue.record("\(error)") }
        #expect(prompts.values.count == 1)
    }

    @Test func valuePromptsAnswerValueAndDeclineWithEmpty() async throws {
        deliver("srq-s", "sudo", ["command": "ls"])
        deliver("srq-l", "vault.save_login", ["origin": "https://x", "site": "X"])
        #expect(prompts.values.map(\.kind) == [.sudo, .vaultSaveLogin])
        try await center.answerValue("srq-s", "")
        try await center.answerValue("srq-l", #"{"identifier":"me@example.com","password":"p"}"#)
        #expect(client.answers.map(\.result) == [["value": ""], ["value": #"{"identifier":"me@example.com","password":"p"}"#]])
        #expect(prompts.values.isEmpty)
    }

    @Test func aStoppedTurnRefusesNewRequests() async {
        let link = PromptChatLink(center: center)
        link.interruptedProbe = { true }
        link.bind(runtime: session, profile: "default", profileParam: "default", storedId: "stored")
        deliver("srq-a", "approval", Self.approval)
        deliver("srq-c", "clarify", Self.clarify)
        #expect(await waitUntil { self.client.answers.count == 2 })
        #expect(client.answers.contains(PromptFakeClient.Answer(id: "srq-a", code: -32603, message: "session interrupted")))
        #expect(client.answers.contains(PromptFakeClient.Answer(id: "srq-c", result: .object([:]))))
        #expect(prompts.isEmpty)
        _ = link
    }

    // MARK: Rules 1–2: upsert, drafts, pruning

    @Test func upsertKeepsTheDraftAndTakesTheReplayedAnswers() {
        deliver("srq-c", "clarify", Self.clarify)
        center.saveDraft("srq-c", ClarifyDraft(page: 1, stages: ["q1": ClarifyStage(draft: "v2")]))
        var replay = Self.clarify.object!
        replay["answers"] = ["q0": "main"]
        deliver("srq-c", "clarify", .object(replay), replayed: true, epoch: 2)
        #expect(center.draft("srq-c")?.page == 1)
        #expect(prompts.clarify?.lockedAnswers["q0"] == .some("main"))
        #expect(center.entry("srq-c")?.epoch == 2)
        #expect(prompts.needsInput == .reply)
    }

    @Test func pruningSparesRequestsDeliveredAfterTheSnapshot() {
        deliver("srq-old", "sudo", ["command": "a"])
        deliver("srq-kept", "sudo", ["command": "b"])
        // The snapshot names only "srq-kept": "srq-old" was answered elsewhere.
        openRequests(["srq-kept"])
        #expect(prompts.values.map(\.id) == ["srq-kept"])
        // A request that arrives after a snapshot built before it (the frame follows the result on the socket) is
        // never pruned by that snapshot.
        deliver("srq-new", "sudo", ["command": "c"])
        #expect(prompts.values.map(\.id) == ["srq-kept", "srq-new"])
    }

    @Test func pendingApprovalAddsAQueueOnlyCardAndResumeDropsIt() {
        openRequests([], pending: ["request_id": "abc", "command": "ls", "description": "list", "choices": ["once", "deny"]])
        #expect(prompts.approvals.map(\.id) == ["queue:abc"])
        #expect(prompts.approvals[0].allowSession == false)
        // The live request for the same queue id replaces the restored copy.
        deliver("srq-live", "approval", ["command": "ls", "description": "list", "request_id": "abc", "choices": ["once", "deny"]])
        #expect(prompts.approvals.map(\.id) == ["srq-live"])
        // A resume with no pending approval drops queue-only ones (the srq stays while named).
        openRequests([], pending: ["request_id": "zzz", "command": "pwd", "description": "", "choices": ["once"]])
        #expect(prompts.approvals.map(\.id) == ["queue:zzz"])
        openRequests([], method: "session.resume")
        #expect(prompts.approvals.isEmpty)
    }

    @Test func queueOnlyApprovalsAnswerThroughApprovalRespond() async throws {
        client.onCall { method, _ in method == "approval.respond" ? ["resolved": 1] : ["approvals": []] }
        openRequests([], pending: ["request_id": "abc", "command": "ls", "description": "list"])
        try await center.answerApproval("queue:abc", .session)
        let respond = try #require(client.calls("approval.respond").first)
        #expect(respond.params == ["session_id": .string(session), "choice": "session", "all": false, "request_id": "abc"])
        #expect(await waitUntil { self.prompts.approvals.isEmpty })
    }

    // MARK: Rules 4–6

    @Test func requestCancelRemovesByIdAcrossSessionsAndTimeoutLeavesANotice() async {
        let link = PromptChatLink(center: center)
        link.bind(runtime: session, profile: "default", profileParam: nil, storedId: "s")
        var timedOut = 0
        link.onTimedOut = { timedOut += 1 }
        deliver("srq-a", "approval", Self.approval)
        deliver("srq-b", "sudo", ["command": "x"], session: "other")
        center.saveDraft("srq-a", ClarifyDraft())
        event("request.cancel", ["id": "srq-b", "method": "sudo", "reason": "interrupted"], session: "")
        #expect(center.prompts(for: ["other"]).values.isEmpty)
        event("request.cancel", ["id": "srq-a", "method": "approval", "reason": "timeout"])
        #expect(prompts.approvals.isEmpty)
        #expect(timedOut == 1)
        _ = link
    }

    @Test func approvalCancelledRemovesQueuedApprovals() {
        deliver("srq-a", "approval", Self.approval)
        event("approval.cancelled", ["session_id": .string(session), "reason": "interrupted", "cancelled_count": 1,
                                     "request_ids": ["9b1d6f0e2c4a4e83a1d2c3b4e5f60718"]], session: "")
        #expect(prompts.approvals.isEmpty)
    }

    @Test func turnEndProbesOpenRequestsAndThePruneDropsWhatHermesClosed() async {
        deliver("srq-a", "approval", Self.approval)
        deliver("srq-s", "secret", ["env_var": "KEY", "prompt": "Paste"])
        deliver("srq-c", "clarify", Self.clarify)
        event("message.complete", ["text": "done"])
        // Nothing goes on the turn end itself: a probe asks Hermes (pure read: last_seen 2147483647).
        #expect(prompts.approvals.count == 1 && prompts.values.count == 1 && prompts.clarify?.id == "srq-c")
        #expect(await waitUntil { !self.client.calls("session.events.since").isEmpty })
        #expect(client.calls("session.events.since").first?.params == ["session_id": .string(session), "last_seen": 2_147_483_647])
        // Its open_requests (the interception) names only the question: the cancels we missed are applied.
        openRequests(["srq-c"], method: "session.events.since")
        #expect(prompts.approvals.isEmpty && prompts.values.isEmpty)
        #expect(prompts.clarify?.id == "srq-c")
    }

    // Reviewer: a reconnect's replay yields the open_requests first, then the missed ring — an older turn's
    // message.complete must not drop the newer turn's request.
    @Test func aReplayedOlderTurnEndKeepsTheNewerTurnsRequest() async {
        let listed = Self.approval
        client.onCall { method, _ in method == "approval.pending" ? ["approvals": [listed]] : [:] }
        deliver("srq-new", "approval", Self.approval, replayed: true, epoch: 2)
        deliver("srq-pw", "vault.unlock_prompt", ["backend": "bitwarden"], replayed: true, epoch: 2)
        openRequests(["srq-new", "srq-pw"], method: "session.events.since")
        event("message.complete", ["text": "the turn that ended while away"])
        event("error", ["message": "another client's submit was refused"])
        #expect(prompts.approvals.map(\.id) == ["srq-new"])
        #expect(prompts.values.map(\.id) == ["srq-pw"])
        #expect(prompts.needsInput == .approval)
        #expect(await waitUntil { !self.client.calls("session.events.since").isEmpty })
        // The probe's answer still names both: they stay.
        openRequests(["srq-new", "srq-pw"], method: "session.events.since")
        #expect(prompts.approvals.count == 1 && prompts.values.count == 1)
    }

    @Test func aTurnEndDropsAQueueOnlyApprovalAndReadsTheQueueAgain() async {
        client.onCall { method, _ in method == "approval.pending" ? ["approvals": []] : [:] }
        openRequests([], pending: ["request_id": "abc", "command": "ls", "description": "list"])
        #expect(prompts.approvals.map(\.id) == ["queue:abc"])
        event("message.complete", ["text": "done"])
        #expect(prompts.approvals.isEmpty)
        #expect(await waitUntil { !self.client.calls("approval.pending").isEmpty })
        #expect(client.calls("session.events.since").isEmpty)    // no srq open: nothing to probe
    }

    @Test func runningFalseEndsOnlyATurnTheCentreKnewWasLive() async {
        deliver("srq-s", "sudo", ["command": "x"])
        event("session.info", ["running": false])
        try? await Task.sleep(for: .milliseconds(60))
        #expect(client.calls("session.events.since").isEmpty)   // never saw the turn live: a reconnect's stale running:false
        event("message.delta", ["text": "…"])
        event("session.info", ["running": false])
        #expect(await waitUntil { !self.client.calls("session.events.since").isEmpty })
        openRequests([], method: "session.events.since")
        #expect(prompts.values.isEmpty)
    }

    // MARK: Exactly once across sockets (§2.3)

    @Test func aReDeliveryOnTheAnswersSocketIsIgnoredOnALaterOneItShowsAgain() async throws {
        deliver("srq-v", "sudo", ["command": "ls"], epoch: 1)
        try await center.answerValue("srq-v", "pw")
        #expect(prompts.values.isEmpty)
        // A resume answer built before Hermes read our frame (same socket): ignored.
        deliver("srq-v", "sudo", ["command": "ls"], replayed: true, epoch: 1)
        #expect(prompts.values.isEmpty)
        // The socket died after the frame left the phone: the next socket lists it again, so Hermes never got it.
        deliver("srq-v", "sudo", ["command": "ls"], replayed: true, epoch: 2)
        #expect(prompts.values.map(\.id) == ["srq-v"])
        #expect(!center.debugRecentlyAnswered.contains("srq-v"))
        client.setEpoch(2)
        try await center.answerValue("srq-v", "pw")
        #expect(client.answers.filter { $0.id == "srq-v" }.count == 2)
    }

    @Test func automaticAnswersAreSentAgainOnALaterSocketAndForgottenWhenTheyFail() async {
        deliver("srq-setup", "setup_choose", [:], epoch: 1)
        #expect(await waitUntil { self.client.answers.count == 1 })
        deliver("srq-setup", "setup_choose", [:], replayed: true, epoch: 1)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(client.answers.count == 1)
        client.setEpoch(2)
        deliver("srq-setup", "setup_choose", [:], replayed: true, epoch: 2)
        #expect(await waitUntil { self.client.answers.count == 2 })
        // A send that failed is forgotten: its re-delivery (same socket number) is answered again.
        client.failNextAnswer(RPCError.connectionLost("answer"))
        deliver("srq-tour", "tour", [:], epoch: 2)
        #expect(await waitUntil { !self.center.debugRecentlyAnswered.contains("srq-tour") })
        deliver("srq-tour", "tour", [:], replayed: true, epoch: 2)
        #expect(await waitUntil { self.client.answers.contains { $0.id == "srq-tour" && $0.code == 4404 } })
    }

    // MARK: Value prompts in flight (§2.3 "keep the sheet with its input")

    @Test func aValueAnswerOnItsWayKeepsThePromptAndAFailureReopensIt() async {
        deliver("srq-v", "vault.unlock_prompt", ["display_name": "1Password"])
        client.setRespondDelay(.milliseconds(80))
        client.failNextAnswer(RPCError.notSent(.socketDead))
        let center = self.center
        let sent = Task { () -> Bool in
            do { try await center.answerValue("srq-v", "master"); return false } catch { return error is PromptAnswerError }
        }
        #expect(await waitUntil { self.prompts.values.first?.sending == true })
        #expect(prompts.values.map(\.id) == ["srq-v"])          // still listed: its sheet stays up
        #expect(prompts.needsInput == .approval)
        #expect(await sent.value, "the offline answer throws")
        #expect(prompts.values.first?.sending == false)
        #expect(prompts.values.map(\.id) == ["srq-v"])
    }

    // MARK: Late logins (the bot stopped waiting for a save-login)

    static let adp: JSONValue = ["origin": "https://workforcenow.adp.com", "site": "ADP"]
    static let login = #"{"identifier":"me@example.com","password":"p"}"#

    /// A chat on `session` in the "deploys" bot that records what it was told to send.
    func loginLink() -> (PromptChatLink, () -> [String]) {
        let link = PromptChatLink(center: center)
        link.bind(runtime: session, profile: "deploys", profileParam: "deploys", storedId: "s")
        var told: [String] = []
        link.onLoginSavedLate = { told.append($0) }
        return (link, { told })
    }

    @Test func aTimedOutLoginStaysAndSavingItStoresItAndTellsTheBot() async throws {
        let (link, told) = loginLink()
        deliver("srq-l", "vault.save_login", Self.adp)
        event("request.cancel", ["id": "srq-l", "method": "vault.save_login", "reason": "timeout"])
        #expect(prompts.values.map(\.late) == [true])
        #expect(prompts.needsInput == nil, "nothing waits for a late login")
        try await center.answerValue("srq-l", Self.login)
        #expect(client.answers.isEmpty, "Hermes drops an answer to a cancelled request")
        #expect(client.calls("vault.add").map(\.params) == [[
            "kind": "login", "label": "ADP", "origin": "https://workforcenow.adp.com", "profile": "deploys",
            "secret": ["identifier_type": "email", "identifier": "me@example.com", "password": "p"]]])
        #expect(told() == ["ADP"])
        #expect(prompts.values.isEmpty)
        _ = link
    }

    @Test func aStoppedTurnStillDropsTheLoginAndDontSaveSendsNothing() async throws {
        let (link, told) = loginLink()
        deliver("srq-a", "vault.save_login", Self.adp)
        event("request.cancel", ["id": "srq-a", "method": "vault.save_login", "reason": "interrupted"])
        #expect(prompts.values.isEmpty)
        deliver("srq-b", "vault.save_login", Self.adp)
        event("request.cancel", ["id": "srq-b", "method": "vault.save_login", "reason": "shutdown"])
        #expect(prompts.values.map(\.late) == [true])
        try await center.answerValue("srq-b", "")
        #expect(prompts.values.isEmpty)
        #expect(client.calls("vault.add").isEmpty && client.answers.isEmpty && told().isEmpty)
        _ = link
    }

    @Test func anAnswerHermesDroppedIsSavedLate() async {
        let (link, told) = loginLink()
        deliver("srq-l", "vault.save_login", Self.adp)
        try? await center.answerValue("srq-l", Self.login)
        #expect(client.answers.count == 1 && prompts.values.isEmpty)
        // The cancel came after the answer went out: Hermes had already stopped waiting.
        event("request.cancel", ["id": "srq-l", "method": "vault.save_login", "reason": "timeout"])
        #expect(await waitUntil { told() == ["ADP"] })
        #expect(client.calls("vault.add").count == 1)
        #expect(prompts.values.isEmpty)

        // Taken in time: the vault tool returns, and a later cancel saves nothing twice.
        deliver("srq-m", "vault.save_login", Self.adp)
        try? await center.answerValue("srq-m", Self.login)
        event("tool.complete", ["name": "browser_vault", "tool_id": "t1"])
        event("request.cancel", ["id": "srq-m", "method": "vault.save_login", "reason": "timeout"])
        try? await Task.sleep(for: .milliseconds(30))
        #expect(client.calls("vault.add").count == 1 && told() == ["ADP"])
        _ = link
    }

    @Test func anAnswerCrossingTheTimeoutIsSavedLate() async throws {
        let (link, told) = loginLink()
        deliver("srq-l", "vault.save_login", Self.adp)
        client.setRespondDelay(.milliseconds(80))
        let center = self.center
        let answer = Task { try await center.answerValue("srq-l", Self.login) }
        #expect(await waitUntil { self.prompts.values.first?.sending == true })
        event("request.cancel", ["id": "srq-l", "method": "vault.save_login", "reason": "timeout"])
        try await answer.value
        #expect(client.calls("vault.add").count == 1)
        #expect(told() == ["ADP"])
        #expect(prompts.values.isEmpty)
        _ = link
    }

    @Test func aPrunedLoginComesBackLateAndOutlivesPrunesAndNewSockets() async {
        deliver("srq-l", "vault.save_login", Self.adp)
        openRequests([], method: "session.resume")      // the app was away: Hermes no longer has it open
        #expect(prompts.values.isEmpty)
        // The replayed ring says why: the bot stopped waiting.
        event("request.cancel", ["id": "srq-l", "method": "vault.save_login", "reason": "timeout"])
        #expect(prompts.values.map(\.id) == ["srq-l"] && prompts.values.map(\.late) == [true])
        openRequests([], method: "session.events.since")
        event("gateway.ready", [:], session: "")
        try? await Task.sleep(for: .milliseconds(250))  // past staleDrop
        #expect(prompts.values.map(\.id) == ["srq-l"])
        // A pruned login a later cancel calls interrupted stays gone.
        deliver("srq-x", "vault.save_login", Self.adp, session: "other")
        openRequests([], session: "other")
        event("request.cancel", ["id": "srq-x", "method": "vault.save_login", "reason": "interrupted"], session: "")
        #expect(center.prompts(for: ["other"]).values.isEmpty)
    }

    @Test func aNewLoginRequestReplacesTheLateOne() {
        deliver("srq-1", "vault.save_login", Self.adp)
        event("request.cancel", ["id": "srq-1", "method": "vault.save_login", "reason": "timeout"])
        deliver("srq-2", "vault.save_login", Self.adp)
        #expect(prompts.values.map(\.id) == ["srq-2"])
        #expect(prompts.values.map(\.late) == [false])
        #expect(prompts.needsInput == .approval)
    }

    @Test func aFailedVaultSaveKeepsTheLateSheet() async {
        let (link, told) = loginLink()
        client.onCall { method, _ in
            if method == "vault.add" { throw RPCError(code: 5095, message: "vault locked", data: nil) }
            return [:]
        }
        deliver("srq-l", "vault.save_login", Self.adp)
        event("request.cancel", ["id": "srq-l", "method": "vault.save_login", "reason": "timeout"])
        await #expect(throws: PromptAnswerError.self) { try await self.center.answerValue("srq-l", Self.login) }
        #expect(prompts.values.map(\.late) == [true])
        #expect(prompts.values.first?.sending == false)
        #expect(told().isEmpty)
        _ = link
    }

    @Test func lateLoginSecretsUseTheVaultToolsIdentifierTypes() {
        #expect(LateLogin.secret(#"{"identifier":"+1 555","password":"p"}"#)?["identifier_type"] == "username")
        #expect(LateLogin.secret(#"{"identifier":"+15551234567","password":"p"}"#)?["identifier_type"] == "phone")
        #expect(LateLogin.secret(#"{"identifier":"jdoe","password":"p"}"#)?["identifier_type"] == "username")
        #expect(LateLogin.secret(#"{"identifier":"jdoe","password":""}"#) == nil)
        #expect(LateLogin.site(["origin": "https://login.example.com/x"]) == "login.example.com")
    }

    // MARK: R1 kill switch

    @Test func withTheKillSwitchNothingIsShownOrAnswered() async {
        let off = ServerRequestCenter(client: client, timing: Self.timing, autoStart: false, enabled: false)
        let link = PromptChatLink(center: off)
        link.interruptedProbe = { true }
        link.bind(runtime: session, profile: "default", profileParam: nil, storedId: "s")
        for (id, method) in [("srq-setup", "setup_choose"), ("srq-a", "approval"), ("srq-t", "terminal.read")] {
            off.receive(GatewayEvent(type: LocalEvent.serverRequest, sessionId: session, seq: nil,
                                     payload: ["id": .string(id), "method": .string(method),
                                               "params": ["session_id": .string(session)], "epoch": 1]))
        }
        off.receive(GatewayEvent(type: LocalEvent.serverRequest, sessionId: session, seq: nil,
                                 payload: ["id": "srq-c", "method": "clarify", "params": ["session_id": .string(session), "questions": []], "epoch": 1]))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(client.answers.isEmpty)
        #expect(off.prompts(for: [session]).isEmpty)
        _ = link
    }

    // MARK: Bookkeeping

    @Test func runtimeEvictionSparesChatsOnScreenAndOpenRequests() {
        let link = PromptChatLink(center: center)
        link.bind(runtime: "chat-rt", profile: "deploys", profileParam: "deploys", storedId: "s1")
        center.bound(runtime: "open-rt", previous: nil, profile: "ops", profileParam: "ops", storedId: "s2")
        deliver("srq-o", "sudo", ["command": "x"], session: "open-rt")
        for i in 0..<300 { center.bound(runtime: "rt\(i)", previous: nil, profile: "p", profileParam: "p", storedId: nil) }
        #expect(center.runtimes.count == ServerRequestCenter.runtimeCap)
        #expect(center.runtimes["chat-rt"]?.profileParam == "deploys")
        #expect(center.runtimes["open-rt"]?.profileParam == "ops")
        #expect(center.runtimes["rt299"] != nil && center.runtimes["rt0"] == nil)
        _ = link
    }

    @Test func removalsAreReportedOnceForTheSheets() async throws {
        var gone: [Set<String>] = []
        center.onRemoved = { gone.append($0) }
        deliver("srq-s", "sudo", ["command": "x"])
        deliver("srq-t", "secret", ["env_var": "K"])
        try await center.answerValue("srq-s", "pw")
        event("request.cancel", ["id": "srq-t", "method": "secret", "reason": "interrupted"], session: "")
        #expect(gone == [["srq-s"], ["srq-t"]])
        deliver("srq-u", "sudo", ["command": "y"])
        center.shutdown()
        #expect(gone.last == ["srq-u"])
    }

    // MARK: Rules 7–9

    @Test func aNewSocketDropsWhatNoResumeConfirmsWithin15s() async {
        deliver("srq-a", "sudo", ["command": "a"])
        deliver("srq-b", "sudo", ["command": "b"], session: "other")
        event("gateway.ready", [:], session: "")
        #expect(prompts.values.count == 1)          // still on screen: no flicker
        openRequests(["srq-a"])                     // this chat's activate names it
        #expect(await waitUntil { self.center.prompts(for: ["other"]).values.isEmpty })
        #expect(prompts.values.map(\.id) == ["srq-a"])
    }

    @Test func runtimeRotationDropsTheOldRuntimesEntries() {
        let link = PromptChatLink(center: center)
        link.bind(runtime: session, profile: "default", profileParam: "default", storedId: "s")
        deliver("srq-a", "sudo", ["command": "a"])
        #expect(link.prompts.values.count == 1)
        link.bind(runtime: "newrt001", profile: "default", profileParam: "default", storedId: "s")
        #expect(center.prompts(for: [session]).values.isEmpty)
        #expect(link.prompts.isEmpty)
    }

    @Test func signOutDropsEverything() {
        deliver("srq-c", "clarify", Self.clarify)
        center.saveDraft("srq-c", ClarifyDraft(page: 1))
        center.shutdown()
        #expect(prompts.isEmpty)
        #expect(center.draft("srq-c") == nil)
    }

    // MARK: Clarify answers

    @Test func sendLocksInQuestionOrderNullsIncludedWithoutSessionId() async throws {
        let link = PromptChatLink(center: center)
        link.bind(runtime: session, profile: "deploys", profileParam: "deploys", storedId: "s")
        client.onCall { method, params in
            method == "clarify.lock" ? ["status": "ok", "remaining": []] : [:]
        }
        deliver("srq-c", "clarify", Self.clarify)
        center.saveDraft("srq-c", ClarifyDraft(page: 1, stages: ["q0": ClarifyStage(choices: ["main (Recommended)"])]))
        try await center.sendClarify("srq-c", answers: [(qid: "q0", answer: "main"), (qid: "q1", answer: nil)])
        let locks = client.calls("clarify.lock")
        #expect(locks.map(\.params) == [
            ["request_id": "srq-c", "question_id": "q0", "answer": "main", "profile": "deploys"],
            ["request_id": "srq-c", "question_id": "q1", "answer": .null, "profile": "deploys"],
        ])
        #expect(link.prompts.clarify == nil)
        #expect(link.prompts.sentClarify?.rows == [SentClarifyRow(question: "Which branch?", answer: "main"),
                                                   SentClarifyRow(question: "Name?", answer: nil)])
        // The settled card replaces the sent note.
        event("tool.complete", ["name": "clarify", "tool_id": "c1"])
        #expect(link.prompts.sentClarify == nil)
        _ = link
    }

    @Test func aFailedLockKeepsTheDock() async {
        client.onCall { method, _ in
            if method == "clarify.lock" { throw RPCError(code: 4002, message: "unknown question_id 'q9'", data: nil) }
            return [:]
        }
        deliver("srq-c", "clarify", Self.clarify)
        do {
            try await center.sendClarify("srq-c", answers: [(qid: "q9", answer: "x")])
            Issue.record("expected a failure")
        } catch let error as PromptAnswerError {
            #expect(error.message == "Couldn’t send your answers.")
        } catch { Issue.record("\(error)") }
        #expect(prompts.clarify?.id == "srq-c")
        #expect(prompts.clarify?.sending == false)
    }

    @Test func skipRespondsEmptyAndNotesSkipped() async throws {
        deliver("srq-c", "clarify", Self.clarify)
        try await center.skipClarify("srq-c")
        #expect(client.answers == [PromptFakeClient.Answer(id: "srq-c", result: .object([:]))])
        #expect(prompts.sentClarify?.rows.map(\.answer) == ["", ""])
    }

    @Test func anUndeliveredQuestionIsNotedAfterAProbe() async {
        event("tool.start", ["name": "clarify", "tool_id": "c1"])
        #expect(await waitUntil { self.prompts.clarifyUndelivered })
        #expect(!client.calls("session.events.since").isEmpty)
        deliver("srq-c", "clarify", Self.clarify)
        #expect(!prompts.clarifyUndelivered)
    }

    // MARK: A gateway-hosted Hermes's shared questions ([authority], tester report 2026-11-08: "Asking" with no options)

    static let sharedQuestion: JSONValue = ["kind": "clarify", "prompt_id": "c-7f3a", "execution_generation": 4,
                                            "question": "Campaign untuk batch ini?",
                                            "choices": ["dracin — semua video di batch ini (Recommended)", "Campur — saya sebut campaign per video",
                                                        "Campaign baru — saya kasih nama + hashtag wajibnya"],
                                            "multi_select": false, "timeout_s": 3600]

    @Test func aSharedQuestionShowsInTheDockAndAnswersThroughClarifyRespond() async throws {
        center.bound(runtime: session, previous: nil, profile: "work", profileParam: "work", storedId: session)
        event("tool.start", ["name": "clarify", "tool_id": "c1"])
        event("clarify.request", Self.sharedQuestion)
        let clarify = try #require(prompts.clarify)
        #expect(clarify.id == "c-7f3a")
        #expect(clarify.questions.map(\.question) == ["Campaign untuk batch ini?"])
        #expect(clarify.questions.first?.choices?.count == 3)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(!prompts.clarifyUndelivered)

        center.saveDraft("c-7f3a", ClarifyDraft(page: 0, stages: ["c-7f3a": ClarifyStage(choices: ["dracin — semua video di batch ini (Recommended)"])]))
        try await center.sendClarify("c-7f3a", answers: [(qid: "c-7f3a", answer: "dracin — semua video di batch ini")])
        let respond = try #require(client.calls("clarify.respond").first)
        #expect(respond.params == ["session_id": .string(session), "prompt_id": "c-7f3a", "execution_generation": 4,
                                   "answer": "dracin — semua video di batch ini", "profile": "work"])
        #expect(client.calls("clarify.lock").isEmpty && client.answers.isEmpty)
        #expect(prompts.clarify == nil)
        #expect(prompts.sentClarify?.rows.map(\.answer) == ["dracin — semua video di batch ini"])
        // The settle that follows, and a resume that still lists it in flight, don't bring it back.
        event("clarify.settled", ["prompt_id": "c-7f3a", "execution_generation": 4])
        event("clarify.request", Self.sharedQuestion)
        #expect(prompts.clarify == nil)
    }

    @Test func aSharedQuestionSkipsWithAnEmptyAnswer() async throws {
        event("clarify.request", Self.sharedQuestion)
        try await center.skipClarify("c-7f3a")
        #expect(client.calls("clarify.respond").first?.params["answer"] == "")
        #expect(client.answers.isEmpty)
    }

    @Test func aSharedQuestionGoesWhenSettledElsewhereOrItsTurnEnds() {
        event("clarify.request", Self.sharedQuestion)
        event("clarify.settled", ["prompt_id": "c-7f3a", "execution_generation": 4])
        #expect(prompts.clarify == nil)
        var next = Self.sharedQuestion.object!
        next["prompt_id"] = "c-8b21"
        event("clarify.request", .object(next))
        #expect(prompts.clarify?.id == "c-8b21")
        event("message.complete", [:])
        #expect(prompts.clarify == nil)
    }

    @Test func onlyAResumesPromptsPruneASharedQuestion() {
        event("clarify.request", Self.sharedQuestion)
        // The probe (`session.events.since`) can't see shared questions: it stays.
        openRequests([], method: "session.events.since")
        #expect(prompts.clarify?.id == "c-7f3a")
        center.receive(GatewayEvent(type: LocalEvent.openRequests, sessionId: session, seq: nil,
                                    payload: ["session_id": .string(session), "ids": [], "prompt_ids": ["c-7f3a"],
                                              "pending_approval": .null, "method": "session.activate"]))
        #expect(prompts.clarify?.id == "c-7f3a")
        center.receive(GatewayEvent(type: LocalEvent.openRequests, sessionId: session, seq: nil,
                                    payload: ["session_id": .string(session), "ids": [], "prompt_ids": [],
                                              "pending_approval": .null, "method": "session.activate"]))
        #expect(prompts.clarify == nil)
    }

    @Test func aFailedSharedAnswerKeepsTheQuestion() async {
        client.onCall { method, _ in
            if method == "clarify.respond" { throw RPCError(code: 4001, message: "invalid_params", data: nil) }
            return [:]
        }
        event("clarify.request", Self.sharedQuestion)
        await #expect(throws: PromptAnswerError.self) {
            try await self.center.sendClarify("c-7f3a", answers: [(qid: "c-7f3a", answer: "Campur")])
        }
        #expect(prompts.clarify?.id == "c-7f3a")
        #expect(prompts.clarify?.sending == false)
    }

    @Test func approvalTimeoutReadsTheProfilesConfigAndCaches() async {
        client.onRest { path, query in
            #expect(path == "/api/config")
            return Data(#"{"approvals":{"timeout":20}}"#.utf8)
        }
        #expect(await center.approvalTimeout(profile: "default", fresh: false) == 20)
        client.onRest { _, _ in Data("{}".utf8) }
        #expect(await center.approvalTimeout(profile: "default", fresh: false) == 20)   // cached
        #expect(await center.approvalTimeout(profile: "default", fresh: true) == 300)   // fresh read: unset → 300
    }
}
