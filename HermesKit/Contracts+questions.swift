// Contract additions for stream "questions" (docs/spec/1x-questions.md): approvals, bot questions (clarify) and
// password prompts — the server→client requests HQ Native now answers. Kept out of Contracts.swift so the integrator
// can fold them in; the only Contracts.swift edit is `Bot.needsInput`.

import Foundation

// MARK: - Bots row (spec 1x §3.6)

/// A bot's chat waits for the user: "Waiting for your approval" (approvals, sudo, secret, vault prompts — Q11) or
/// "Waiting for your reply" (a clarify question). Ranks above "Working…" on the Bots row.
nonisolated enum NeedsInput: String, Sendable, Hashable {
    case approval, reply

    var statusText: String {
        switch self {
        case .approval: "Waiting for your approval"
        case .reply: "Waiting for your reply"
        }
    }
}

// MARK: - Answering server requests (spec 1x §3.1)

/// A client that can answer server→client requests on its current socket. `LiveGatewayClient` adopts it; fakes may.
/// (The spec puts these on `GatewayClient` itself; they live in their own protocol so Contracts.swift stays untouched
/// until integration. A client that doesn't adopt it never advertises, so nothing waits for it.)
nonisolated protocol ServerRequestAnswering: AnyObject, Sendable {
    /// Answer a server→client request on the current socket (spec 1x §2.3). Throws `RPCError.isNotConnected` when no
    /// socket is up, `isConnectionLost` when the send failed. Returns the epoch of the socket the frame went out on:
    /// a re-delivery on a later socket means Hermes never saw it (the centre shows it again).
    @discardableResult func respond(serverRequest id: String, result: JSONValue) async throws -> Int
    @discardableResult func fail(serverRequest id: String, code: Int, message: String) async throws -> Int
    /// The current socket's `client.capabilities` answer said `declines_not_shown` (spec 1x §2.1).
    var declinesNotShown: Bool { get }
}

nonisolated extension LocalEvent {
    /// The authoritative open requests of one session (spec 1x §2.4), yielded right after the `serverRequest` events
    /// of a `session.resume` / `session.activate` / `session.events.since` result, before its caller resumes.
    /// payload `{session_id, ids: [srq id], pending_approval: obj|null, method}`. A missing key in the result = none open.
    static let openRequests = "hq.open_requests"
}

// MARK: - What a chat shows (spec 1x §3.6)

nonisolated enum PromptKind: String, Sendable, Hashable, CaseIterable {
    case approval, clarify, sudo, secret
    case vaultUnlock = "vault.unlock_prompt"
    case vaultSaveLogin = "vault.save_login"
    case vaultCode = "vault.code"

    /// Value prompts answer `{value}` and show as a sheet (§4.5).
    var isValuePrompt: Bool { self != .approval && self != .clarify }
}

nonisolated enum ApprovalChoice: String, Sendable, Hashable { case once, session, always, deny }

/// One approval as the card shows it (the oldest of the stack is drawn).
nonisolated struct ApprovalPrompt: Equatable, Sendable, Identifiable {
    var id: String                 // entry id (srq id, or "queue:<request_id>")
    var command: String
    var description: String
    var allowSession: Bool
    var allowAlways: Bool
    /// The expiry clock's key (queue request id, else "rpc:<srq id>") and when it first reached the phone.
    var clockKey: String
    var firstSeen: Date
    /// The choice being sent (the tapped button shows a spinner; every button is disabled).
    var answering: ApprovalChoice?
    /// Answered: the card fades out (200 ms) before it goes.
    var leaving = false

    /// A plugin rule's synthetic label (`<tool> (…`) or no command at all: the card shows the description (§4.2).
    var showsDescription: Bool {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return c.isEmpty || c.range(of: #"^<[^>]+> \("#, options: .regularExpression) != nil
    }
}

nonisolated struct ClarifyQuestion: Equatable, Sendable, Hashable {
    var qid: String
    var question: String
    var choices: [String]?         // nil = an open question
    var multiSelect: Bool
}

/// The open clarify request of a session (one at a time).
nonisolated struct ClarifyPrompt: Equatable, Sendable {
    var id: String                 // srq id = the request id `clarify.lock` names
    var questions: [ClarifyQuestion]
    /// Answers the gateway already holds (a reconnect replay's `answers`): qid → answer (nil = skipped).
    var lockedAnswers: [String: String?] = [:]
    var sending = false
}

/// One question's picks and typed text (web `Stage`).
nonisolated struct ClarifyStage: Equatable, Sendable, Hashable {
    var choices: [String] = []
    var draft = ""
    var other = false
}

/// The dock's page and picks for one request, kept in memory by request id until Send / Skip (Q15).
nonisolated struct ClarifyDraft: Equatable, Sendable {
    var page = 0
    var stages: [String: ClarifyStage] = [:]
}

/// One row of the sent-answers note: the question and the answer ("" = Skipped, nil = No answer).
nonisolated struct SentClarifyRow: Equatable, Sendable, Hashable {
    var question: String
    var answer: String?
}

nonisolated struct SentClarify: Equatable, Sendable {
    var requestId: String
    var rows: [SentClarifyRow]
}

/// A sudo / secret / vault prompt (§4.5). `params` are the request's own (env_var, prompt, backend, site…).
nonisolated struct ValuePrompt: Equatable, Sendable, Identifiable {
    var id: String
    var kind: PromptKind
    var params: JSONValue
    /// The answer is on its way: the sheet stays up with its text, primary disabled (a failure puts it back, §2.3).
    var sending = false
    /// A login the bot stopped waiting for (`ServerRequestCenter.Entry.late`): saving it stores it and tells the bot.
    var late = false
}

/// Everything one chat shows for its open requests.
nonisolated struct ChatPrompts: Equatable, Sendable {
    /// Oldest first; the card draws the first.
    var approvals: [ApprovalPrompt] = []
    /// How many approvals this stack has held since it was last empty ("1 / 2").
    var approvalStackTotal = 0
    var clarify: ClarifyPrompt?
    /// What the dock last sent for this session, until the clarify tool's settled card arrives.
    var sentClarify: SentClarify?
    /// A clarify tool runs but its question never reached the phone (§3.5).
    var clarifyUndelivered = false
    /// The question of the running clarify (for the "asked" note while undelivered: none).
    var values: [ValuePrompt] = []

    var isEmpty: Bool { approvals.isEmpty && clarify == nil && sentClarify == nil && !clarifyUndelivered && values.isEmpty }

    /// The header and Bots-row words (§3.6, Q11): any approval or value prompt → approval; a clarify → reply. A late
    /// login doesn't count: nothing waits for it any more.
    var needsInput: NeedsInput? {
        if approvals.contains(where: { !$0.leaving }) || values.contains(where: { !$0.late }) { return .approval }
        if clarify != nil { return .reply }
        return nil
    }
}

/// Why an answer didn't go out, in the user's words (§4.7). The entry stays open.
nonisolated struct PromptAnswerError: Error, Sendable, Equatable, LocalizedError {
    var message: String
    /// No socket: offer Reconnect.
    var offline: Bool
    var errorDescription: String? { message }
}

/// A chat that shows server requests (spec 1x §3.6). `LiveChatSession` adopts it through the account's
/// `ServerRequestCenter`; the chat screen draws the card, the dock, the note and the sheets from it.
protocol ChatPrompting: AnyObject {
    var prompts: ChatPrompts { get }
    /// Called on the main actor whenever `prompts` changed.
    var onPromptsChange: (() -> Void)? { get set }
    func answerApproval(_ id: String, _ choice: ApprovalChoice) async throws
    func dismissExpiredApproval(_ id: String)
    /// `approvals.timeout` of the chat's profile in seconds (cached 5 min; 300 when unset). `fresh` reads it again.
    func approvalTimeout(fresh: Bool) async -> TimeInterval
    func clarifyDraft(_ requestId: String) -> ClarifyDraft?
    func saveClarifyDraft(_ requestId: String, _ draft: ClarifyDraft)
    func sendClarify(_ requestId: String, answers: [(qid: String, answer: String?)]) async throws
    func skipClarify(_ requestId: String) async throws
    /// "" declines.
    func answerValue(_ requestId: String, _ value: String) async throws
    /// The chat came on screen / the app came back with it open: confirm what is still open (§3.5).
    func promptsCameOnScreen()
    /// The offline toasts' "Reconnect" (§4.7): dial now.
    func reconnectNow()
}
