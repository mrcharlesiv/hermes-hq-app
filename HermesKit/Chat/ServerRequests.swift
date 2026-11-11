// The account's open server→client requests (spec 1x §3.2–§3.5): every approval, question and password prompt the
// gateway asked this phone, answered exactly once. One per account (AppModel); chats read their slice through a
// `PromptChatLink` (LiveChatSession+Prompts.swift). Main actor. Typed answers never leave memory (Q15): drafts are
// dropped on answer, cancel and sign-out, and nothing here is logged or cached.

import Foundation

@MainActor final class ServerRequestCenter {
    struct Timing {
        var probeDebounce: Duration = .milliseconds(750)
        /// Entries no resume/activate/replay named within this long of a new socket's ready are dropped (rule 7).
        var staleDrop: Duration = .seconds(15)
        /// A running clarify tool with no question this long after its `tool.start` is probed (§3.5).
        var undeliveredAfter: Duration = .seconds(4)
        /// An answered approval card fades out this long before it goes (§4.2).
        var leaving: Duration = .milliseconds(200)
        var approvalRespondTimeout: Duration = .seconds(330)
        var lockTimeout: Duration = .seconds(30)
        var recentlyAnsweredTTL: TimeInterval = 600
        var timeoutCacheTTL: TimeInterval = 300
        /// A save-login answer is held at most this long for a `request.cancel` saying Hermes dropped it (late logins).
        var sentLoginHold: Duration = .seconds(30)
        /// A pruned save-login is remembered this long for a replayed `request.cancel` saying the bot stopped waiting.
        var prunedLoginTTL: TimeInterval = 3600
        static let standard = Timing()
    }

    enum EntryState: Equatable { case open, answering, leaving }

    /// One open srq, or a queue-backed approval with no srq (`srqOpen == false`, id "queue:<request_id>").
    struct Entry {
        let id: String
        var kind: PromptKind
        var sessionId: String
        var params: JSONValue
        var srqOpen: Bool
        var queueRequestId: String?
        var deliveredSeq: Int
        var epoch: Int
        var firstSeen: Date
        var state: EntryState = .open
        var answering: ApprovalChoice?
        /// The `gateway.ready` generation that still has to confirm it (rule 7); nil = confirmed.
        var unconfirmedSince: Int?
        /// A `vault.save_login` the bot stopped waiting for (timed out, or the gateway shut down): Hermes drops a late
        /// answer and has told the bot the user declined. Kept, with no srq, so the login can still be given: it goes
        /// to the bot's Passwords & Logins (`vault.add`) and the chat tells the bot, which starts it again.
        var late = false
        /// A gateway-hosted Hermes's shared question (`clarify.request` event, id = its `prompt_id`; `srqOpen` false):
        /// answered with `clarify.respond`, never `clarify.lock` or a response frame.
        var prompt: SharedPrompt?
    }

    /// [authority] A session authority asks one question per `clarify.request` event, keyed by `prompt_id` and bound
    /// to the turn that asked it (HA:gateway/session_pending_controls.py `register_clarify`; Hermes Desktop delivers
    /// these as its question card too, HA:apps/desktop/src/api/client.ts `deliverCanonicalPrompt`).
    struct SharedPrompt: Equatable {
        let promptId: String
        let generation: Int
    }

    /// What a runtime id belongs to (fed by every chat's runtime bind).
    struct Runtime: Equatable {
        var profileParam: String?
        var profile: String
        var storedId: String?
    }

    static let windowOwned: Set<String> = ["terminal.read", "preview.read", "window.read", "preview.act", "tour"]
    /// `runtimes` keeps at most this many (least recently bound go first; a chat's own and any with an entry stay).
    static let runtimeCap = 256
    static let notShownCode = 4404
    static let notShownMessage = "This window is not showing the session."
    /// `request.cancel` reasons that mean the bot stopped waiting on its own, not a Stop: a login withdrawn for one of
    /// them stays as a late login.
    static let botStoppedWaiting: Set<String> = ["timeout", "shutdown"]

    let client: any GatewayClient
    var timing: Timing
    var now: () -> Date = Date.init
    /// False under the `HQNNoServerRequests` kill switch (R1): nothing is shown or answered (M1 behaviour).
    let enabled: Bool

    /// A session's needs-input changed (Bots row, spec 1x §3.6): profile, stored id, kind (nil = nothing waits).
    var onNeedsInput: ((_ profile: String, _ storedId: String?, _ kind: NeedsInput?) -> Void)?
    /// Requests that went (answered, withdrawn, pruned, signed out), after the chats heard of it: the account's kept
    /// password sheets drop theirs and clear their text (App, `PromptSheetStore`; Q15, R6).
    var onRemoved: ((Set<String>) -> Void)?
    /// [notifications] A request reached the phone for the first time (its chat may be off screen: a local alert).
    var onArrived: ((Entry, Runtime?) -> Void)?

    private(set) var entries: [Entry] = []
    private(set) var runtimes: [String: Runtime] = [:]
    /// `runtimes`' keys, least recently bound first.
    private var runtimeOrder: [String] = []
    private var seq = 0
    /// Answered ids (§2.3). `epoch` is the socket the answer frame went out on; nil while it is in flight, or when an RPC
    /// result confirmed it reached Hermes (every re-delivery is then ignored).
    private struct Answered { let id: String; let at: Date; var epoch: Int? }
    private var recentlyAnswered: [Answered] = []
    /// Every entry id the last change fan-out saw (`onRemoved` reports the ones that went).
    private var knownIds: Set<String> = []
    private var drafts: [String: ClarifyDraft] = [:]
    private var approvalSeen: [(key: String, at: Date)] = []
    private var stackSize: [String: Int] = [:]
    private var sent: [String: SentClarify] = [:]
    private var undelivered: Set<String> = []
    private var liveTurns: Set<String> = []
    private var approvalsRevision: [String: Int] = [:]
    private var lastNeeds: [String: NeedsInput] = [:]
    private var links: [ObjectIdentifier: WeakLink] = [:]
    private var probeTasks: [String: Task<Void, Never>] = [:]
    private var probing: Set<String> = []
    private var clarifyWatch: [String: Task<Void, Never>] = [:]
    private var readyGeneration = 0
    private var staleTask: Task<Void, Never>?
    private var leavingTasks: [String: Task<Void, Never>] = [:]
    private var timeouts: [String: (value: TimeInterval, at: Date)] = [:]
    private var eventsTask: Task<Void, Never>?
    private var statesTask: Task<Void, Never>?
    /// Late logins: open save-logins a resume or a new socket pruned, kept (metadata only) for a replayed
    /// `request.cancel` showing the bot stopped waiting — the ring replays after the prune.
    private var prunedLogins: [(entry: Entry, at: Date)] = []
    /// Save-login answers that went out, held until their tool completes (seconds): a `request.cancel` for one means
    /// Hermes stopped waiting first and dropped it, and it is saved the late way without asking again.
    private var sentLogins: [String: (entry: Entry, value: String, at: Date)] = [:]
    private(set) var connection: ConnectionState = .connecting
    private var shutDown = false

    private struct WeakLink { weak var link: PromptChatLink? }

    init(client: any GatewayClient, timing: Timing = .standard, autoStart: Bool = true,
         enabled: Bool = ServerRequestsSwitch.enabled) {
        self.client = client
        self.timing = timing
        self.enabled = enabled
        connection = (client as? LiveGatewayClient)?.state ?? .ready
        if autoStart { start() }
    }

    isolated deinit {
        eventsTask?.cancel()
        statesTask?.cancel()
    }

    func start() {
        guard eventsTask == nil, !shutDown else { return }
        let events = client.events()
        eventsTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.receive(event)
            }
        }
        let states = client.connectionStates()
        statesTask = Task { [weak self] in
            for await state in states { self?.connection = state }
        }
    }

    /// Sign-out / account switch (rule 9): everything goes, drafts and kept sheets included.
    func shutdown() {
        shutDown = true
        eventsTask?.cancel(); eventsTask = nil
        statesTask?.cancel(); statesTask = nil
        staleTask?.cancel(); staleTask = nil
        (Array(probeTasks.values) + Array(clarifyWatch.values) + Array(leavingTasks.values)).forEach { $0.cancel() }
        probeTasks = [:]; clarifyWatch = [:]; leavingTasks = [:]
        let sessions = Set(entries.map(\.sessionId)).union(sent.keys).union(undelivered)
        entries = []
        drafts = [:]
        sent = [:]
        undelivered = []
        recentlyAnswered = []
        prunedLogins = []
        sentLogins = [:]
        for session in sessions { changed(session) }
        if !knownIds.isEmpty {
            let gone = knownIds
            knownIds = []
            onRemoved?(gone)
        }
        links = [:]
        runtimes = [:]
        runtimeOrder = []
    }

    private var answerer: ServerRequestAnswering? { client as? ServerRequestAnswering }

    /// [preview-tab] Answers `preview.read` for a session (its runtime id) with the open Browser tab's page as JSON, or
    /// nil when no tab of that chat is open in this app. Set by the app (App/Browser/PreviewTab.swift).
    var previewReader: ((_ session: String, _ params: JSONValue) async -> String?)?

    // MARK: Chats

    func register(_ link: PromptChatLink) {
        links[ObjectIdentifier(link)] = WeakLink(link: link)
        links = links.filter { $0.value.link != nil }
    }

    func unregister(_ link: PromptChatLink) { links[ObjectIdentifier(link)] = nil }

    private func links(for session: String) -> [PromptChatLink] {
        links.values.compactMap(\.link).filter { $0.covers(session) }
    }

    /// A chat bound a runtime id (rule 8: entries under its previous runtime for the same stored id go).
    func bound(runtime: String, previous: String?, profile: String, profileParam: String?, storedId: String?) {
        runtimes[runtime] = Runtime(profileParam: profileParam, profile: profile, storedId: storedId)
        runtimeOrder.removeAll { $0 == runtime }
        runtimeOrder.append(runtime)
        evictRuntimes()
        if let previous, previous != runtime {
            // A late login belongs to the chat, not to a runtime: it moves to the new one.
            for i in entries.indices where entries[i].sessionId == previous && entries[i].late { entries[i].sessionId = runtime }
            for i in prunedLogins.indices where prunedLogins[i].entry.sessionId == previous { prunedLogins[i].entry.sessionId = runtime }
            let old = entries.filter { $0.sessionId == previous }
            if !old.isEmpty {
                entries.removeAll { $0.sessionId == previous }
                old.forEach { drafts[$0.id] = nil }
                bumpApprovals(previous)
                changed(previous)
            }
            if sent[previous] != nil || undelivered.contains(previous) {
                sent[previous] = nil
                undelivered.remove(previous)
                changed(previous)
            }
        }
        changed(runtime)
    }

    /// Over the cap, the least recently bound go, never one a chat covers now or one with an open entry (their
    /// `profile` routing and the Bots row's mapping must survive).
    private func evictRuntimes() {
        guard runtimes.count > Self.runtimeCap else { return }
        let live = Set(links.values.compactMap(\.link).flatMap(\.sessionIds)).union(entries.map(\.sessionId))
        var i = 0
        while runtimes.count > Self.runtimeCap, i < runtimeOrder.count {
            let id = runtimeOrder[i]
            if live.contains(id) { i += 1; continue }
            runtimes[id] = nil
            runtimeOrder.remove(at: i)
        }
    }

    // MARK: Reads

    /// One chat's view: the requests of its runtime ids (oldest first).
    func prompts(for sessions: [String]) -> ChatPrompts {
        var out = ChatPrompts()
        let set = Set(sessions)
        for entry in entries where set.contains(entry.sessionId) {
            switch entry.kind {
            case .approval:
                out.approvals.append(approvalPrompt(entry))
            case .clarify:
                guard out.clarify == nil else { continue }
                let questions = ClarifyText.normalize(entry.params["questions"])
                out.clarify = ClarifyPrompt(id: entry.id, questions: questions,
                                            lockedAnswers: ClarifyText.lockedAnswers(entry.params["answers"]),
                                            sending: entry.state == .answering)
            default:
                // An answer on its way keeps its sheet (with its text) until it is sent; a failure reopens it (§2.3).
                out.values.append(ValuePrompt(id: entry.id, kind: entry.kind, params: entry.params,
                                              sending: entry.state != .open, late: entry.late))
            }
        }
        for session in sessions {
            out.approvalStackTotal = max(out.approvalStackTotal, stackSize[session] ?? 0)
            if out.sentClarify == nil { out.sentClarify = sent[session] }
            if undelivered.contains(session) && out.clarify == nil { out.clarifyUndelivered = true }
        }
        out.approvalStackTotal = max(out.approvalStackTotal, out.approvals.count)
        return out
    }

    func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }

    func draft(_ requestId: String) -> ClarifyDraft? { drafts[requestId] }

    func saveDraft(_ requestId: String, _ draft: ClarifyDraft) {
        guard entries.contains(where: { $0.id == requestId }) else { return }
        drafts[requestId] = draft
    }

    private func approvalPrompt(_ entry: Entry) -> ApprovalPrompt {
        let p = entry.params
        let choices = p["choices"]?.array?.compactMap(\.string) ?? (p["smart_denied"]?.bool == true ? ["once", "deny"] : nil)
        let allowSession = choices?.contains("session") ?? true
        let allowAlways = choices?.contains("always") ?? (p["allow_permanent"]?.bool != false)
        return ApprovalPrompt(id: entry.id, command: p["command"]?.string ?? "", description: p["description"]?.string ?? "",
                              allowSession: allowSession, allowAlways: allowAlways, clockKey: clockKey(entry),
                              firstSeen: entry.firstSeen, answering: entry.answering, leaving: entry.state == .leaving)
    }

    private func clockKey(_ entry: Entry) -> String {
        if let request = entry.queueRequestId, !request.isEmpty { return request }
        return "rpc:\(entry.id)"
    }

    /// When an approval first reached the phone (a replay keeps the first time). Capped at 64 keys.
    private func seenAt(_ key: String) -> Date {
        if let known = approvalSeen.first(where: { $0.key == key }) { return known.at }
        let at = now()
        approvalSeen.append((key, at))
        if approvalSeen.count > 64 { approvalSeen.removeFirst() }
        return at
    }

    // MARK: Events

    func receive(_ event: GatewayEvent) {
        guard !shutDown else { return }
        seq += 1
        let session = event.sessionId
        switch event.type {
        case LocalEvent.serverRequest: if enabled { delivered(event) }
        case LocalEvent.openRequests: if enabled { authoritative(event) }
        case "gateway.ready": socketReady()
        case "request.cancel": withdrawn(event)
        case "clarify.request": if enabled { promptAsked(event) }
        case "clarify.settled": promptSettled(event)
        case "approval.cancelled": approvalsCancelled(event)
        case "message.start":
            liveTurns.insert(session)
            agentMovedOn(session)
        case "message.delta":
            liveTurns.insert(session)
        case "tool.start":
            liveTurns.insert(session)
            if event.payload["name"]?.string == "clarify" { watchClarify(session, toolId: event.payload["tool_id"]?.string) }
        case "tool.complete":
            if event.payload["name"]?.string == "clarify" { clarifySettled(session) }
            // The vault tool returned after our login answer: Hermes took it (a dropped one is cancelled first).
            if event.payload["name"]?.string?.hasPrefix("browser_vault") == true { forgetSentLogins(session) }
            agentMovedOn(session)
        case "message.complete", "error":
            guard !session.isEmpty else { return }
            if event.type == "message.complete" { forgetSentLogins(session); dropSharedPrompts(session) }
            turnEnded(session)
            clarifySettled(session)
            agentMovedOn(session)
        case "session.info":
            if event.payload["running"]?.bool == true { liveTurns.insert(session) }
            else if event.payload["running"]?.bool == false, liveTurns.contains(session) { turnEnded(session) }
            // Rule 3: the queue is replayed for a chat on screen (a queue-only approval has no srq to announce it).
            if entries.contains(where: { $0.sessionId == session && $0.kind == .approval })
                || links(for: session).contains(where: { $0.isObserving }) { replayApprovals(session) }
        default: break
        }
    }

    // Rule 1: a request (live, or re-delivered from `open_requests`).
    private func delivered(_ event: GatewayEvent) {
        let p = event.payload
        guard let id = p["id"]?.string, let method = p["method"]?.string else { return }
        let params = p["params"] ?? .object([:])
        let session = event.sessionId.isEmpty ? (params["session_id"]?.string ?? "") : event.sessionId
        let epoch = p["epoch"]?.int ?? 0
        let replayed = p["replayed"]?.bool == true
        guard !alreadyAnswered(id, deliveredOn: epoch) else { return }
        if method == "preview.read", let previewReader {
            // [preview-tab] The bot reads the Browser tab it opened in this chat (`desktop_preview` action=read): the
            // page's text as Hermes Desktop answers it (`{value: JSON}`). No tab here: declined as before.
            Task { [weak self] in
                let value = await previewReader(session, params)
                guard let self, !self.shutDown else { return }
                if let value {
                    self.sendResult(id, .object(["value": .string(value)]))
                } else if self.answerer?.declinesNotShown == true {
                    self.sendError(id, code: Self.notShownCode, message: Self.notShownMessage)
                }
            }
            return
        }
        if Self.windowOwned.contains(method) {
            // Q3: the phone shows no pane. A decline is one client's vote; with no decline support, stay silent.
            guard answerer?.declinesNotShown == true else { return }
            sendError(id, code: Self.notShownCode, message: Self.notShownMessage)
            return
        }
        guard let kind = PromptKind(rawValue: method) else {
            // Q4: setup_choose, display.install.sudo, anything new.
            AppLog.note("chat", "server request \(method) \(AppLog.tag(id)) for \(AppLog.tag(session)): no handler, refused")
            sendError(id, code: -32601, message: "no handler for server request: \(method)")
            return
        }
        if !entries.contains(where: { $0.id == id }), links(for: session).contains(where: { $0.turnInterrupted }) {
            // The user already stopped this turn: refuse rather than park a card for a dead turn (§2.3).
            AppLog.trace("chat", "server request \(kind.rawValue) \(AppLog.tag(id)) for \(AppLog.tag(session)): turn was stopped, refused")
            if kind == .clarify { sendResult(id, .object([:])) } else { sendError(id, code: -32603, message: "session interrupted") }
            return
        }
        if kind == .clarify, ClarifyText.normalize(params["questions"]).isEmpty {
            sendResult(id, .object([:]))
            return
        }
        let queueRequest = kind == .approval ? params["request_id"]?.string.flatMap { $0.isEmpty ? nil : $0 } : nil
        AppLog.trace("chat", "server request \(kind.rawValue) \(AppLog.tag(id)) for \(AppLog.tag(session)): \(entries.contains(where: { $0.id == id }) ? "again, params refreshed" : "shown"), replayed=\(replayed), epoch \(epoch)")
        if let i = entries.firstIndex(where: { $0.id == id }) {
            // Same request again: keep its UI state, take the new params (a replay may add clarify `answers`).
            entries[i].params = params
            entries[i].epoch = epoch
            entries[i].srqOpen = true
            entries[i].late = false
            entries[i].unconfirmedSince = nil
            entries[i].deliveredSeq = seq
        } else if let queueRequest, let i = entries.firstIndex(where: { !$0.srqOpen && $0.queueRequestId == queueRequest }) {
            // The live request replaces a restored queue-only copy (never the other way round).
            let old = entries[i]
            entries[i] = Entry(id: id, kind: kind, sessionId: session, params: params, srqOpen: true, queueRequestId: queueRequest,
                               deliveredSeq: seq, epoch: epoch, firstSeen: old.firstSeen, state: old.state, answering: old.answering)
        } else {
            var entry = Entry(id: id, kind: kind, sessionId: session, params: params, srqOpen: true, queueRequestId: queueRequest,
                              deliveredSeq: seq, epoch: epoch, firstSeen: now())
            if kind == .approval {
                entry.firstSeen = seenAt(clockKey(entry))
                stackSize[session, default: 0] += 1
                bumpApprovals(session)
            }
            if kind == .clarify {
                undelivered.remove(session)
                clarifyWatch.removeValue(forKey: session)?.cancel()
                sent[session] = nil
            }
            // The bot asks for a login again: the new sheet replaces a late one.
            if kind == .vaultSaveLogin { entries.removeAll { $0.sessionId == session && $0.late } }
            entries.append(entry)
            _ = replayed
            onArrived?(entry, runtimes[session])
        }
        changed(session)
    }

    // [authority] Rule 1 for a session authority's shared question: one `clarify.request` event per question (live, or
    // a resume's `prompts` through the connection's interception), shown in the same dock as a `clarify` server request.
    private func promptAsked(_ event: GatewayEvent) {
        let p = event.payload
        let session = event.sessionId
        guard let promptId = p["prompt_id"]?.string, !promptId.isEmpty, let generation = p["execution_generation"]?.int,
              !session.isEmpty, !alreadyAnswered(promptId, deliveredOn: 0) else { return }
        if let i = entries.firstIndex(where: { $0.id == promptId }) {
            entries[i].unconfirmedSince = nil
            return
        }
        let prompt = SharedPrompt(promptId: promptId, generation: generation)
        let question: JSONValue = ["qid": .string(promptId), "question": p["question"] ?? .null,
                                   "choices": p["choices"] ?? .array([]), "multi_select": p["multi_select"] ?? .bool(false)]
        let params: JSONValue = ["session_id": .string(session), "questions": .array([question])]
        if links(for: session).contains(where: { $0.turnInterrupted }) || ClarifyText.normalize(params["questions"]).isEmpty {
            // The user already stopped this turn, or there is nothing to ask: the empty answer the authority records as
            // skipped (§2.3).
            AppLog.trace("chat", "clarify \(AppLog.tag(promptId)) for \(AppLog.tag(session)): \(links(for: session).contains(where: { $0.turnInterrupted }) ? "turn was stopped" : "no question"), skipped")
            Task { try? await self.sharedRespond(promptId, session: session, prompt: prompt, answer: "") }
            return
        }
        AppLog.trace("chat", "clarify \(AppLog.tag(promptId)) for \(AppLog.tag(session)): shown (shared prompt, generation \(generation))")
        let entry = Entry(id: promptId, kind: .clarify, sessionId: session, params: params, srqOpen: false, queueRequestId: nil,
                          deliveredSeq: seq, epoch: 0, firstSeen: now(), prompt: prompt)
        undelivered.remove(session)
        clarifyWatch.removeValue(forKey: session)?.cancel()
        sent[session] = nil
        entries.append(entry)
        onArrived?(entry, runtimes[session])
        changed(session)
    }

    /// [authority] `clarify.settled`: answered here or elsewhere, timed out, or its turn moved on. An answer of ours on
    /// its way finishes the card itself.
    private func promptSettled(_ event: GatewayEvent) {
        guard let id = event.payload["prompt_id"]?.string,
              let i = entries.firstIndex(where: { $0.id == id && $0.prompt != nil }), entries[i].state == .open else { return }
        let entry = entries.remove(at: i)
        drafts[id] = nil
        AppLog.trace("chat", "clarify \(AppLog.tag(id)) settled by the gateway")
        changed(entry.sessionId)
    }

    /// [authority] The turn finished, so none of its shared questions waits any more (a missed `clarify.settled`).
    private func dropSharedPrompts(_ session: String) {
        let gone = entries.filter { $0.sessionId == session && $0.prompt != nil && $0.state == .open }
        guard !gone.isEmpty else { return }
        entries.removeAll { e in gone.contains { $0.id == e.id } }
        gone.forEach { drafts[$0.id] = nil }
        changed(session)
    }

    // Rule 2: the authoritative set for one session.
    private func authoritative(_ event: GatewayEvent) {
        let p = event.payload
        let session = p["session_id"]?.string ?? event.sessionId
        guard !session.isEmpty else { return }
        let ids = Set((p["ids"]?.array ?? []).compactMap(\.string))
        let method = p["method"]?.string ?? ""
        let pending = p["pending_approval"].flatMap { $0.object != nil ? $0 : nil }
        // [authority] A snapshot's `prompts` (resume only; `session.events.since` has none) names the shared questions.
        let promptIds = p["prompt_ids"]?.array.map { Set($0.compactMap(\.string)) }
        var changedAny = false
        var kept: [Entry] = []
        for var entry in entries {
            guard entry.sessionId == session, !entry.late else { kept.append(entry); continue }
            if entry.prompt != nil {
                if let promptIds {
                    guard promptIds.contains(entry.id) else {
                        drafts[entry.id] = nil
                        changedAny = true
                        continue
                    }
                    entry.unconfirmedSince = nil
                }
                kept.append(entry)
                continue
            }
            if entry.srqOpen {
                if ids.contains(entry.id) {
                    entry.unconfirmedSince = nil
                } else if entry.deliveredSeq < seq {
                    // Answered or withdrawn elsewhere (no event reaches us when another app answers first, §2.5).
                    drafts[entry.id] = nil
                    rememberPruned(entry)
                    if entry.kind == .approval { bumpApprovals(session) }
                    changedAny = true
                    continue
                }
            } else if method != "session.events.since" {
                // A queue-only approval: confirmed by `pending_approval`, else gone (resume/activate only).
                if let pending, pending["request_id"]?.string == entry.queueRequestId {
                    entry.unconfirmedSince = nil
                } else {
                    bumpApprovals(session)
                    changedAny = true
                    continue
                }
            }
            kept.append(entry)
        }
        entries = kept
        if let pending, let request = pending["request_id"]?.string, !request.isEmpty,
           !entries.contains(where: { $0.queueRequestId == request }) {
            addQueueOnly(session, pending)
            changedAny = true
        }
        if changedAny { changed(session) }
    }

    private func addQueueOnly(_ session: String, _ approval: JSONValue) {
        guard let request = approval["request_id"]?.string, !request.isEmpty else { return }
        let id = "queue:\(request)"
        guard !recentlyAnswered.contains(where: { $0.id == id }) else { return }
        var params = approval
        if case .object(var o) = params { o["session_id"] = .string(session); params = .object(o) }
        var entry = Entry(id: id, kind: .approval, sessionId: session, params: params, srqOpen: false, queueRequestId: request,
                          deliveredSeq: seq, epoch: 0, firstSeen: now())
        entry.firstSeen = seenAt(request)
        entries.append(entry)
        stackSize[session, default: 0] += 1
        bumpApprovals(session)
        onArrived?(entry, runtimes[session])
    }

    // Rule 7: a new socket. Older entries stay on screen until a resume/activate/replay confirms or prunes them; those
    // none names within 15 s go (they come back on that chat's next resume).
    private func socketReady() {
        readyGeneration += 1
        let generation = readyGeneration
        for i in entries.indices where entries[i].unconfirmedSince == nil && !entries[i].late { entries[i].unconfirmedSince = generation }
        staleTask?.cancel()
        let wait = timing.staleDrop
        staleTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.dropUnconfirmed(generation)
        }
        // Approvals of the chat on screen are replayed from the queue (rule 3) by that chat, once its reconnect's
        // `session.activate` / `session.resume` confirms the runtime: asking here, before it, asked for runtimes the
        // gateway had already reaped (168 rejected `approval.pending` in its errors.log, 2026-10-23/24).
    }

    private func dropUnconfirmed(_ generation: Int) {
        let stale = entries.filter { ($0.unconfirmedSince ?? .max) <= generation }
        guard !stale.isEmpty else { return }
        entries.removeAll { ($0.unconfirmedSince ?? .max) <= generation }
        stale.forEach { drafts[$0.id] = nil; rememberPruned($0) }
        for session in Set(stale.map(\.sessionId)) {
            bumpApprovals(session)
            changed(session)
        }
    }

    // Rule 4. A login the bot stopped waiting for (timeout, gateway shutdown) stays as a late login (`Entry.late`): a
    // pruned one comes back as one, and one whose answer had already gone out (Hermes dropped it) is saved that way.
    private func withdrawn(_ event: GatewayEvent) {
        guard let id = event.payload["id"]?.string else { return }
        let reason = event.payload["reason"]?.string ?? "-"
        let botStopped = Self.botStoppedWaiting.contains(reason)
        if let sentLogin = sentLogins.removeValue(forKey: id), botStopped {
            AppLog.note("chat", "vault.save_login \(AppLog.tag(id)) answered after the bot stopped waiting (\(reason)): saving it late")
            saveSentLoginLate(sentLogin.entry, value: sentLogin.value)
            return
        }
        guard let i = entries.firstIndex(where: { $0.id == id }) else {
            let cutoff = now().addingTimeInterval(-timing.prunedLoginTTL)
            guard botStopped, let k = prunedLogins.firstIndex(where: { $0.entry.id == id && $0.at >= cutoff }) else { return }
            var entry = prunedLogins.remove(at: k).entry
            makeLate(&entry)
            entry.deliveredSeq = seq
            entries.append(entry)
            AppLog.trace("chat", "server request vault.save_login \(AppLog.tag(id)) withdrawn by the gateway (\(reason)) after a prune: back as a late login")
            changed(entry.sessionId)
            return
        }
        if entries[i].kind == .vaultSaveLogin, botStopped {
            makeLate(&entries[i])
            AppLog.trace("chat", "server request vault.save_login \(AppLog.tag(id)) withdrawn by the gateway (\(reason)): kept as a late login")
            changed(entries[i].sessionId)
            return
        }
        let entry = entries.remove(at: i)
        AppLog.trace("chat", "server request \(entry.kind.rawValue) \(AppLog.tag(id)) withdrawn by the gateway (\(reason))")
        drafts[id] = nil
        if entry.kind == .approval {
            bumpApprovals(entry.sessionId)
            if event.payload["reason"]?.string == "timeout" {
                for link in links(for: entry.sessionId) { link.approvalTimedOut() }
            }
        }
        changed(entry.sessionId)
    }

    // Rule 5.
    private func approvalsCancelled(_ event: GatewayEvent) {
        let requests = Set((event.payload["request_ids"]?.array ?? []).compactMap(\.string))
        guard !requests.isEmpty else { return }
        let gone = entries.filter { $0.kind == .approval && $0.queueRequestId.map(requests.contains) == true }
        guard !gone.isEmpty else { return }
        AppLog.trace("chat", "approvals cancelled by the gateway: \(gone.count)")
        entries.removeAll { e in gone.contains { $0.id == e.id } }
        for session in Set(gone.map(\.sessionId)) {
            bumpApprovals(session)
            changed(session)
        }
    }

    // Rule 6: the turn ended. A queue-only approval goes now (and the queue is read again). A request with an open srq
    // stays until a probe's authoritative `open_requests` (rule 2) confirms or prunes it, the clarify as before
    // (#83319) and now approvals and value prompts too: a reconnect replays the missed ring *after* the re-delivered
    // requests (`replayOne`: the interception runs in `settle`), so an older turn's `message.complete` would drop a
    // newer turn's open request; and Hermes sends `error` frames that end nothing (another client's refused submit, a
    // model switch). A finished turn has no open srq unless its `request.cancel` was missed: one round trip.
    private func turnEnded(_ session: String) {
        liveTurns.remove(session)
        let queueOnly = entries.filter { $0.sessionId == session && $0.kind == .approval && !$0.srqOpen && $0.state == .open }
        if !queueOnly.isEmpty {
            entries.removeAll { e in queueOnly.contains { $0.id == e.id } }
            bumpApprovals(session)
            changed(session)
            replayApprovals(session)
        }
        if entries.contains(where: { $0.sessionId == session && $0.srqOpen }) { probeSoon(session) }
    }

    /// The tool, the reply or the turn moved on after a request was delivered: maybe it was answered elsewhere (§3.5).
    private func agentMovedOn(_ session: String) {
        guard entries.contains(where: { $0.sessionId == session && $0.srqOpen && $0.deliveredSeq < seq }) else { return }
        probeSoon(session)
        if entries.contains(where: { $0.sessionId == session && $0.kind == .approval }) { replayApprovals(session) }
    }

    private func clarifySettled(_ session: String) {
        clarifyWatch.removeValue(forKey: session)?.cancel()
        var any = false
        if sent.removeValue(forKey: session) != nil { any = true }
        if undelivered.remove(session) != nil { any = true }
        if any { changed(session) }
    }

    // MARK: Probe (§2.4, §3.5)

    /// `session.events.since` with the highest `last_seen`: no events, the authoritative `open_requests` (pruned by rule
    /// 2 through the connection's interception). Debounced, one in flight per session.
    func probeSoon(_ session: String) {
        guard !session.isEmpty, probeTasks[session] == nil else { return }
        let wait = timing.probeDebounce
        probeTasks[session] = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard let self, !Task.isCancelled else { return }
            self.probeTasks[session] = nil
            await self.probe(session)
        }
    }

    func probe(_ session: String) async {
        guard !probing.contains(session) else { return }
        probing.insert(session)
        defer { probing.remove(session) }
        var params: [String: JSONValue] = ["session_id": .string(session), "last_seen": 2_147_483_647]
        if let profile = runtimes[session]?.profileParam { params["profile"] = .string(profile) }
        _ = try? await client.call("session.events.since", .object(params), timeout: .seconds(10))
    }

    /// A clarify tool started: if no question reaches us within 4 s, probe; still none → "didn't reach the app".
    private func watchClarify(_ session: String, toolId: String?) {
        guard !entries.contains(where: { $0.sessionId == session && $0.kind == .clarify }) else { return }
        clarifyWatch[session]?.cancel()
        let wait = timing.undeliveredAfter
        clarifyWatch[session] = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard let self, !Task.isCancelled else { return }
            guard !self.entries.contains(where: { $0.sessionId == session && $0.kind == .clarify }) else { return }
            await self.probe(session)
            guard !Task.isCancelled, self.clarifyWatch[session] != nil,
                  !self.entries.contains(where: { $0.sessionId == session && $0.kind == .clarify }) else { return }
            self.clarifyWatch[session] = nil
            self.undelivered.insert(session)
            self.changed(session)
        }
    }

    // MARK: approval.pending (rule 3)

    func replayApprovals(_ session: String) {
        guard !session.isEmpty else { return }
        let revision = approvalsRevision[session, default: 0]
        var params: [String: JSONValue] = ["session_id": .string(session)]
        if let profile = runtimes[session]?.profileParam { params["profile"] = .string(profile) }
        let client = self.client
        Task { [weak self] in
            guard let result = try? await client.call("approval.pending", .object(params), timeout: .seconds(30)) else { return }
            guard let self, !self.shutDown, self.approvalsRevision[session, default: 0] == revision else { return }
            self.reconcileApprovals(session, result["approvals"]?.array ?? [])
        }
    }

    private func reconcileApprovals(_ session: String, _ listed: [JSONValue]) {
        let requests = Set(listed.compactMap { $0["request_id"]?.string })
        let gone = entries.filter { e in
            e.sessionId == session && e.kind == .approval && e.state == .open
                && (e.queueRequestId.map { !requests.contains($0) } ?? false)
        }
        var any = !gone.isEmpty
        entries.removeAll { e in gone.contains { $0.id == e.id } }
        for approval in listed {
            guard let request = approval["request_id"]?.string, !request.isEmpty,
                  !entries.contains(where: { $0.queueRequestId == request }) else { continue }
            addQueueOnly(session, approval)
            any = true
        }
        for i in entries.indices where entries[i].sessionId == session && entries[i].kind == .approval
            && entries[i].queueRequestId.map(requests.contains) == true {
            entries[i].unconfirmedSince = nil
        }
        if any {
            bumpApprovals(session)
            changed(session)
        }
    }

    private func bumpApprovals(_ session: String) {
        approvalsRevision[session, default: 0] += 1
        if !entries.contains(where: { $0.sessionId == session && $0.kind == .approval }) { stackSize[session] = 0 }
    }

    // MARK: Answers (§3.4)

    private func noteAnswered(_ id: String, epoch: Int? = nil) {
        pruneRecentlyAnswered()
        recentlyAnswered.removeAll { $0.id == id }
        recentlyAnswered.append(Answered(id: id, at: now(), epoch: epoch))
        if recentlyAnswered.count > 128 { recentlyAnswered.removeFirst(recentlyAnswered.count - 128) }
    }

    /// The answer frame went out on socket `epoch`.
    private func answeredOn(_ id: String, epoch: Int) {
        guard let i = recentlyAnswered.firstIndex(where: { $0.id == id }) else { return }
        recentlyAnswered[i].epoch = epoch
    }

    private func forgetAnswered(_ id: String) { recentlyAnswered.removeAll { $0.id == id } }

    /// A re-delivery of an id this phone answered. On the socket the answer went out on (or while it is in flight) it
    /// is a stale list built before Hermes read our frame — Hermes handles a socket's frames in order — so it is
    /// ignored. On a later socket Hermes never saw the answer (the frame left the phone, then the socket died: a
    /// lock, a Wi-Fi to cellular switch): the id is forgotten and the request counts as new (shown, or the automatic
    /// answer sent again).
    private func alreadyAnswered(_ id: String, deliveredOn epoch: Int) -> Bool {
        pruneRecentlyAnswered()
        guard let answered = recentlyAnswered.first(where: { $0.id == id }) else { return false }
        if let sentOn = answered.epoch, epoch > sentOn {
            forgetAnswered(id)
            return false
        }
        return true
    }

    private func pruneRecentlyAnswered() {
        let cutoff = now().addingTimeInterval(-timing.recentlyAnsweredTTL)
        recentlyAnswered.removeAll { $0.at < cutoff }
    }

    /// An automatic answer (a refusal, an empty clarify, a decline), fire and forget. A failed send forgets the id so
    /// its re-delivery is answered again.
    private func sendResult(_ id: String, _ result: JSONValue) {
        guard let answerer else { return }
        noteAnswered(id)
        Task { [weak self] in
            do {
                let epoch = try await answerer.respond(serverRequest: id, result: result)
                self?.answeredOn(id, epoch: epoch)
            } catch {
                self?.forgetAnswered(id)
            }
        }
    }

    private func sendError(_ id: String, code: Int, message: String) {
        guard let answerer else { return }
        noteAnswered(id)
        Task { [weak self] in
            do {
                let epoch = try await answerer.fail(serverRequest: id, code: code, message: message)
                self?.answeredOn(id, epoch: epoch)
            } catch {
                self?.forgetAnswered(id)
            }
        }
    }

    /// Hands one answer to the socket, exactly once: the id is marked answered first (a re-delivery or a second tap
    /// can't send again) and taken back if the send failed.
    private func respondOnce(_ id: String, _ result: JSONValue, offline: String, failed: String) async throws {
        guard let answerer else { throw PromptAnswerError(message: offline, offline: true) }
        noteAnswered(id)
        do {
            let epoch = try await answerer.respond(serverRequest: id, result: result)
            answeredOn(id, epoch: epoch)
        } catch {
            forgetAnswered(id)
            if let rpc = error as? RPCError, rpc.isNotConnected { throw PromptAnswerError(message: offline, offline: true) }
            throw PromptAnswerError(message: failed, offline: false)
        }
    }

    /// [authority] A shared question's answer: `clarify.respond` names the prompt and its turn; "" is the skip the
    /// authority records (HA:gateway/session_controls.py `respond_clarify`). Marked answered first, as `respondOnce`.
    private func sharedRespond(_ id: String, session: String, prompt: SharedPrompt, answer: String) async throws {
        var params: [String: JSONValue] = ["session_id": .string(session), "prompt_id": .string(prompt.promptId),
                                           "execution_generation": .number(Double(prompt.generation)), "answer": .string(answer)]
        if let profile = runtimes[session]?.profileParam { params["profile"] = .string(profile) }
        noteAnswered(id)
        do {
            _ = try await client.call("clarify.respond", .object(params), timeout: timing.lockTimeout)
        } catch {
            forgetAnswered(id)
            if let rpc = error as? RPCError, rpc.isNotConnected { throw PromptAnswerError(message: Self.offline, offline: true) }
            throw PromptAnswerError(message: Self.clarifyFailed, offline: false)
        }
    }

    static let approvalOffline = "Hermes is offline right now. The command is still waiting for your answer (until the approval timeout). Reconnect, then send it again."
    static let approvalFailed = "Couldn’t send your answer."
    static let offline = "Hermes is offline right now. Reconnect, then send it again."
    static let clarifyFailed = "Couldn’t send your answers."

    func answerApproval(_ id: String, _ choice: ApprovalChoice) async throws {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].kind == .approval, entries[i].state == .open else { return }
        let entry = entries[i]
        entries[i].state = .answering
        entries[i].answering = choice
        changed(entry.sessionId)
        do {
            if entry.srqOpen {
                try await respondOnce(id, ["choice": .string(choice.rawValue)], offline: Self.approvalOffline, failed: Self.approvalFailed)
            } else {
                try await approvalRespond(entry, choice)
            }
        } catch {
            AppLog.note("chat", "approval \(AppLog.tag(id)) \(choice.rawValue) not sent (\((error as? PromptAnswerError)?.offline == true ? "offline" : "failed")); card open again")
            if let j = entries.firstIndex(where: { $0.id == id }) {
                entries[j].state = .open
                entries[j].answering = nil
                changed(entry.sessionId)
            }
            throw error
        }
        AppLog.trace("chat", "approval \(AppLog.tag(id)) answered \(choice.rawValue) via \(entry.srqOpen ? "server request" : "approval.respond")")
        if let request = entry.queueRequestId { noteAnswered("queue:\(request)") }
        leave(id, session: entry.sessionId)
        replayApprovals(entry.sessionId)
    }

    /// What Approve / Deny on a local alert came to: sent, or the request is gone (answered elsewhere, expired, or it
    /// never reached the phone).
    enum AlertAnswer: Equatable { case sent, gone }

    /// Approve / Deny from a local alert (UX study #256). On a cold launch the request isn't here until the socket is up
    /// and the chat's approvals are replayed, so this waits for it to be open, up to `within`; a request that never
    /// shows (or was answered on this phone already) is `.gone`, said, never dropped in silence. Send failures throw
    /// as `answerApproval`'s do.
    func answerApprovalFromAlert(_ id: String, _ choice: ApprovalChoice, within: Duration = .seconds(6)) async throws -> AlertAnswer {
        let deadline = ContinuousClock.now + within
        while true {
            if recentlyAnswered.contains(where: { $0.id == id }) { AppLog.trace("chat", "approval \(AppLog.tag(id)) from alert: already answered"); return .gone }
            if entries.contains(where: { $0.id == id && $0.kind == .approval && $0.state == .open }) {
                try await answerApproval(id, choice)
                return .sent
            }
            guard ContinuousClock.now < deadline else { AppLog.note("chat", "approval \(AppLog.tag(id)) from alert: request never showed, gone"); return .gone }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// A queue-backed approval with no srq: `approval.respond` (330 s, retried once on a timeout only).
    private func approvalRespond(_ entry: Entry, _ choice: ApprovalChoice) async throws {
        guard connection == .ready else { throw PromptAnswerError(message: Self.approvalOffline, offline: true) }
        var params: [String: JSONValue] = ["session_id": .string(entry.sessionId), "choice": .string(choice.rawValue),
                                           "all": false]
        if let request = entry.queueRequestId { params["request_id"] = .string(request) }
        if let profile = runtimes[entry.sessionId]?.profileParam { params["profile"] = .string(profile) }
        noteAnswered(entry.id)
        var attempt = 0
        while true {
            attempt += 1
            do {
                _ = try await client.call("approval.respond", .object(params), timeout: timing.approvalRespondTimeout)
                return
            } catch let error as RPCError where error.isTimeout && attempt == 1 {
                continue
            } catch let error as RPCError {
                forgetAnswered(entry.id)
                throw PromptAnswerError(message: error.isNotConnected ? Self.approvalOffline : Self.approvalFailed,
                                        offline: error.isNotConnected)
            } catch {
                forgetAnswered(entry.id)
                throw PromptAnswerError(message: Self.approvalFailed, offline: false)
            }
        }
    }

    /// The expired card's Dismiss: it goes at once; the gateway is told no, best effort.
    func dismissExpiredApproval(_ id: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: i)
        AppLog.trace("chat", "expired approval \(AppLog.tag(id)) dismissed (deny sent best effort)")
        if let request = entry.queueRequestId { noteAnswered("queue:\(request)") }
        bumpApprovals(entry.sessionId)
        changed(entry.sessionId)
        if entry.srqOpen {
            sendResult(id, ["choice": "deny"])
        } else {
            noteAnswered(id)
            var params: [String: JSONValue] = ["session_id": .string(entry.sessionId), "choice": "deny", "all": false]
            if let request = entry.queueRequestId { params["request_id"] = .string(request) }
            if let profile = runtimes[entry.sessionId]?.profileParam { params["profile"] = .string(profile) }
            let client = self.client
            Task { _ = try? await client.call("approval.respond", .object(params), timeout: .seconds(30)) }
        }
    }

    /// The card fades out, then goes (§4.2).
    private func leave(_ id: String, session: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].state = .leaving
        changed(session)
        let wait = timing.leaving
        leavingTasks[id] = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard let self else { return }
            self.leavingTasks[id] = nil
            guard let j = self.entries.firstIndex(where: { $0.id == id }) else { return }
            self.entries.remove(at: j)
            self.bumpApprovals(session)
            self.changed(session)
        }
    }

    /// Dock Send: one `clarify.lock` per question, in order, the nulls too — the last lock resolves the wait.
    func sendClarify(_ requestId: String, answers: [(qid: String, answer: String?)]) async throws {
        guard let i = entries.firstIndex(where: { $0.id == requestId }), entries[i].kind == .clarify, entries[i].state == .open else { return }
        let entry = entries[i]
        guard connection == .ready else { throw PromptAnswerError(message: Self.offline, offline: true) }
        entries[i].state = .answering
        changed(entry.sessionId)
        let profile = runtimes[entry.sessionId]?.profileParam
        do {
            if let prompt = entry.prompt {
                // One question per shared prompt; a blank answer is a skip.
                let answer = answers.first(where: { $0.qid == prompt.promptId })?.answer ?? nil
                try await sharedRespond(requestId, session: entry.sessionId, prompt: prompt, answer: answer ?? "")
            } else {
                for (qid, answer) in answers {
                    var params: [String: JSONValue] = ["request_id": .string(requestId), "question_id": .string(qid),
                                                       "answer": answer.map(JSONValue.string) ?? .null]
                    if let profile { params["profile"] = .string(profile) }
                    let result = try await client.call("clarify.lock", .object(params), timeout: timing.lockTimeout)
                    if result["status"]?.string == "expired" { break }   // the wait already ended: done (web parity)
                }
            }
        } catch {
            AppLog.note("chat", "clarify \(AppLog.tag(requestId)) answers not sent: \(LiveChatSession.logError(error))")
            if let j = entries.firstIndex(where: { $0.id == requestId }) {
                entries[j].state = .open
                changed(entry.sessionId)
            }
            if let answerError = error as? PromptAnswerError { throw answerError }
            if let rpc = error as? RPCError, rpc.isNotConnected { throw PromptAnswerError(message: Self.offline, offline: true) }
            throw PromptAnswerError(message: Self.clarifyFailed, offline: false)
        }
        let questions = ClarifyText.normalize(entry.params["questions"])
        AppLog.trace("chat", "clarify \(AppLog.tag(requestId)) answered (\(answers.count) questions, \(answers.filter { $0.answer == nil }.count) left blank)")
        finishClarify(entry, rows: ClarifyStaging.sentRows(questions, drafts[requestId]?.stages ?? [:]))
    }

    /// Dock Skip: a response without answers is the gateway's cancel-all.
    func skipClarify(_ requestId: String) async throws {
        guard let i = entries.firstIndex(where: { $0.id == requestId }), entries[i].kind == .clarify, entries[i].state == .open else { return }
        let entry = entries[i]
        entries[i].state = .answering
        changed(entry.sessionId)
        do {
            if let prompt = entry.prompt {
                try await sharedRespond(requestId, session: entry.sessionId, prompt: prompt, answer: "")
            } else {
                try await respondOnce(requestId, .object([:]), offline: Self.offline, failed: Self.clarifyFailed)
            }
            AppLog.trace("chat", "clarify \(AppLog.tag(requestId)) skipped")
        } catch {
            AppLog.note("chat", "clarify \(AppLog.tag(requestId)) skip not sent")
            if let j = entries.firstIndex(where: { $0.id == requestId }) {
                entries[j].state = .open
                changed(entry.sessionId)
            }
            throw error
        }
        let questions = ClarifyText.normalize(entry.params["questions"])
        finishClarify(entry, rows: ClarifyStaging.sentRows(questions, [:], skipped: true))
    }

    private func finishClarify(_ entry: Entry, rows: [SentClarifyRow]) {
        // Skip's frame already noted its socket; the locks' RPC results confirm Send.
        if !recentlyAnswered.contains(where: { $0.id == entry.id }) { noteAnswered(entry.id) }
        entries.removeAll { $0.id == entry.id }
        drafts[entry.id] = nil
        sent[entry.sessionId] = SentClarify(requestId: entry.id, rows: rows)
        changed(entry.sessionId)
    }

    static func valueFailed(_ kind: PromptKind) -> String {
        switch kind {
        case .sudo: "Couldn’t send the sudo password."
        case .secret: "Couldn’t send the secret."
        case .vaultUnlock: "Couldn’t send the master password."
        case .vaultSaveLogin: "Couldn’t save the login."
        case .vaultCode: "Couldn’t send the code."
        default: approvalFailed
        }
    }

    /// Sheet primary or the red decline (""). A late login is saved to the bot's Passwords & Logins instead, and its
    /// chat tells the bot.
    func answerValue(_ requestId: String, _ value: String) async throws {
        guard let i = entries.firstIndex(where: { $0.id == requestId }), entries[i].kind.isValuePrompt, entries[i].state == .open else { return }
        let entry = entries[i]
        if entry.late {
            try await answerLateLogin(requestId, value)
            return
        }
        entries[i].state = .answering
        changed(entry.sessionId)
        do {
            try await respondOnce(requestId, ["value": .string(value)], offline: Self.offline, failed: Self.valueFailed(entry.kind))
            AppLog.trace("chat", "\(entry.kind.rawValue) \(AppLog.tag(requestId)) answered (\(value.isEmpty ? "declined" : "value sent"))")
        } catch {
            AppLog.note("chat", "\(entry.kind.rawValue) \(AppLog.tag(requestId)) answer not sent (\((error as? PromptAnswerError)?.offline == true ? "offline" : "failed"))")
            if let j = entries.firstIndex(where: { $0.id == requestId }) {
                entries[j].state = .open
                changed(entry.sessionId)
            }
            throw error
        }
        if let j = entries.firstIndex(where: { $0.id == requestId }), entries[j].late {
            // The bot stopped waiting while the answer was on its way, so Hermes dropped it: saved the late way.
            entries[j].state = .open
            try await answerLateLogin(requestId, value)
            return
        }
        if entry.kind == .vaultSaveLogin, !value.isEmpty { holdSentLogin(entry, value) }
        entries.removeAll { $0.id == requestId }
        changed(entry.sessionId)
    }

    // MARK: Late logins (`Entry.late`)

    private func makeLate(_ entry: inout Entry) {
        entry.late = true
        entry.srqOpen = false
        entry.unconfirmedSince = nil
    }

    /// An open save-login a prune dropped: a replayed `request.cancel` may yet show the bot stopped waiting.
    private func rememberPruned(_ entry: Entry) {
        guard entry.kind == .vaultSaveLogin, entry.state == .open, !entry.late else { return }
        let cutoff = now().addingTimeInterval(-timing.prunedLoginTTL)
        prunedLogins.removeAll { $0.at < cutoff || $0.entry.id == entry.id }
        prunedLogins.append((entry, now()))
        if prunedLogins.count > 16 { prunedLogins.removeFirst(prunedLogins.count - 16) }
    }

    private func holdSentLogin(_ entry: Entry, _ value: String) {
        let at = now()
        sentLogins[entry.id] = (entry, value, at)
        let wait = timing.sentLoginHold
        Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard let self, self.sentLogins[entry.id]?.at == at else { return }
            self.sentLogins[entry.id] = nil
        }
    }

    private func forgetSentLogins(_ session: String) {
        guard sentLogins.values.contains(where: { $0.entry.sessionId == session }) else { return }
        sentLogins = sentLogins.filter { $0.value.entry.sessionId != session }
    }

    /// The late sheet's Save ("" = Don't Save: nothing waits for it, so nothing goes on the wire).
    private func answerLateLogin(_ id: String, _ value: String) async throws {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries[i]
        guard !value.isEmpty else {
            AppLog.trace("chat", "late login \(AppLog.tag(id)) not saved")
            entries.remove(at: i)
            changed(entry.sessionId)
            return
        }
        entries[i].state = .answering
        changed(entry.sessionId)
        do {
            let site = try await storeLogin(entry, value)
            entries.removeAll { $0.id == id }
            changed(entry.sessionId)
            tellBot(entry.sessionId, site: site)
        } catch {
            AppLog.note("chat", "late login \(AppLog.tag(id)) not saved: \(LiveChatSession.logError(error))")
            if let j = entries.firstIndex(where: { $0.id == id }) {
                entries[j].state = .open
                changed(entry.sessionId)
            }
            if let rpc = error as? RPCError, rpc.isNotConnected { throw PromptAnswerError(message: Self.offline, offline: true) }
            throw PromptAnswerError(message: Self.valueFailed(.vaultSaveLogin), offline: false)
        }
    }

    /// An answer Hermes dropped: saved the late way with what was already typed. A failure brings the sheet back as a
    /// late login, to be typed again.
    private func saveSentLoginLate(_ entry: Entry, value: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let site = try await self.storeLogin(entry, value)
                self.tellBot(entry.sessionId, site: site)
            } catch {
                AppLog.note("chat", "late login \(AppLog.tag(entry.id)) not saved: \(LiveChatSession.logError(error)); sheet back")
                guard !self.shutDown, !self.entries.contains(where: { $0.id == entry.id }) else { return }
                var late = entry
                self.makeLate(&late)
                late.state = .open
                late.deliveredSeq = self.seq
                self.entries.append(late)
                self.changed(late.sessionId)
            }
        }
    }

    /// `vault.add` into the bot's own Passwords & Logins (a bot's vault is its profile's). Returns the site's name.
    private func storeLogin(_ entry: Entry, _ value: String) async throws -> String {
        guard let origin = entry.params["origin"]?.string, !origin.isEmpty, let secret = LateLogin.secret(value) else {
            throw PromptAnswerError(message: Self.valueFailed(.vaultSaveLogin), offline: false)
        }
        let site = LateLogin.site(entry.params)
        var params: [String: JSONValue] = ["kind": "login", "label": .string(site), "origin": .string(origin), "secret": .object(secret)]
        if let profile = runtimes[entry.sessionId]?.profileParam { params["profile"] = .string(profile) }
        _ = try await client.call("vault.add", .object(params), timeout: .seconds(30))
        AppLog.trace("chat", "late login \(AppLog.tag(entry.id)) saved to the bot's Passwords & Logins")
        return site
    }

    /// The chat of `session` sends the bot `LateLogin.message`: the bot reads its vault only while a turn runs.
    private func tellBot(_ session: String, site: String) {
        guard let link = links(for: session).first(where: { $0.onLoginSavedLate != nil }) else {
            AppLog.note("chat", "late login saved, but no chat of \(AppLog.tag(session)) is open to tell the bot")
            return
        }
        link.loginSavedLate(site)
    }

    // MARK: Approval timeout (§4.2 expiry)

    /// `approvals.timeout` of `profile` from `GET /api/config`, cached 5 min per profile; 300 when unset. A failed read
    /// keeps the cached value (or 300).
    func approvalTimeout(profile: String?, fresh: Bool) async -> TimeInterval {
        let key = profile ?? ""
        if !fresh, let cached = timeouts[key], now().timeIntervalSince(cached.at) < timing.timeoutCacheTTL { return cached.value }
        let query = profile.map { [URLQueryItem(name: "profile", value: $0)] } ?? []
        guard let data = try? await client.configData(query, maxAge: fresh ? 0 : SharedConfigReads.defaultMaxAge),   // [load-cache]
              let config = try? JSONValue.parseFast(data) else {
            return timeouts[key]?.value ?? ApprovalExpiry.defaultTimeout
        }
        let value = ApprovalExpiry.timeout(fromConfig: config)
        timeouts[key] = (value, now())
        return value
    }

    // MARK: Change fan-out

    private func changed(_ session: String) {
        for link in links(for: session) { link.promptsChanged() }
        let needs = prompts(for: [session]).needsInput
        if lastNeeds[session] != needs {
            lastNeeds[session] = needs
            if let runtime = runtimes[session] { onNeedsInput?(runtime.profile, runtime.storedId, needs) }
        }
        let ids = Set(entries.lazy.map(\.id))
        guard ids != knownIds else { return }
        let gone = knownIds.subtracting(ids)
        knownIds = ids
        if !gone.isEmpty { onRemoved?(gone) }
    }

    #if DEBUG
    var debugRecentlyAnswered: [String] { recentlyAnswered.map(\.id) }
    var debugUndelivered: Set<String> { undelivered }
    #endif
}

/// A chat's tie to the centre: which runtime ids are its own (the current one, plus the retired one while a resume is
/// in flight), whether its turn was stopped, and its change callback. Owned by the chat (`LiveChatSession.promptLink`).
@MainActor final class PromptChatLink {
    weak var center: ServerRequestCenter?
    /// The chat's runtime ids, newest first.
    private(set) var sessionIds: [String] = []
    var isObserving = false
    var turnInterrupted: Bool { interruptedProbe?() ?? false }
    var interruptedProbe: (() -> Bool)?
    var onChange: (() -> Void)?
    var onTimedOut: (() -> Void)?
    /// A login the bot had stopped waiting for went to its Passwords & Logins: the chat tells the bot (the site's name).
    var onLoginSavedLate: ((String) -> Void)?
    /// The chat screen's own listener (`ChatPrompting.onPromptsChange`).
    var screenOnChange: (() -> Void)?

    init(center: ServerRequestCenter) {
        self.center = center
        center.register(self)
    }

    isolated deinit { center?.unregister(self) }

    func covers(_ session: String) -> Bool { sessionIds.contains(session) }

    func bind(runtime: String, profile: String, profileParam: String?, storedId: String?) {
        let previous = sessionIds.first
        guard previous != runtime else { return }
        sessionIds = [runtime]
        center?.bound(runtime: runtime, previous: previous, profile: profile, profileParam: profileParam, storedId: storedId)
    }

    var prompts: ChatPrompts { center?.prompts(for: sessionIds) ?? ChatPrompts() }

    func promptsChanged() { onChange?() }
    func approvalTimedOut() { onTimedOut?() }
    func loginSavedLate(_ site: String) { onLoginSavedLate?(site) }
}

/// A login the bot stopped waiting for (`ServerRequestCenter.Entry.late`): what is stored, and what the bot is told.
nonisolated enum LateLogin {
    /// The site's name as the sheet shows it: `site`, else the origin's host.
    static func site(_ params: JSONValue) -> String {
        if let site = params["site"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !site.isEmpty { return site }
        let origin = params["origin"]?.string ?? ""
        return URL(string: origin)?.host() ?? (origin.isEmpty ? "the site" : origin)
    }

    /// The sheet's `{"identifier","password"}` as a vault login, with the vault tool's own identifier types.
    static func secret(_ value: String) -> [String: JSONValue]? {
        guard let answer = try? JSONValue.parseFast(Data(value.utf8)),
              let identifier = answer["identifier"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty,
              let password = answer["password"]?.string, !password.isEmpty else { return nil }
        let digits = identifier.hasPrefix("+") ? identifier.dropFirst() : Substring(identifier)
        let type = identifier.contains("@") ? "email" : (!digits.isEmpty && digits.allSatisfy(\.isNumber) ? "phone" : "username")
        return ["identifier_type": .string(type), "identifier": .string(identifier), "password": .string(password)]
    }

    /// What the chat sends: it starts a turn, and the bot finds the login under Passwords & Logins.
    static func message(site: String) -> String {
        "I saved my \(site) login in Passwords & Logins. Sign in with it and carry on."
    }
}
