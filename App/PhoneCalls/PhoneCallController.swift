// Phone Calls (Beta): one HQ account's calls and the one watcher per call. The controller (not the call sheet) polls
// each call from dial until its outcome is settled and its result has gone to the chat, whether the sheet is open or
// not. App-only: every read goes straight to samplehost (samplehostClient.swift) with the owner's key from this device's
// Keychain. Calls are kept per account on this device (PhoneHistory.swift).

import Foundation
import UIKit

// A retry must replay the exact approved intent, not reuse its id for edited fields.
struct PhoneStartIntent: Equatable {
    let session: String, destination: String, goal: String
    var voicemail: PhoneVoicemailChoice = .hangUp
    var name: String?
    var callingOwner: Bool = false
    var greeting: String? = nil
    var chatContext: String? = nil
}
struct PhoneStartRetry {
    private(set) var pending: (intent: PhoneStartIntent, id: String)?
    mutating func id(for intent: PhoneStartIntent) -> String {
        if let pending, pending.intent == intent { return pending.id }
        let id = UUID().uuidString
        pending = (intent, id)
        return id
    }
    mutating func completed() { pending = nil }
}

/// `+` and 7 to 15 digits, the first not 0.
nonisolated func phoneIsE164(_ value: String) -> Bool {
    value.wholeMatch(of: /\+[1-9][0-9]{6,14}/) != nil
}

/// What the To field means as a dialable number. Spaces, dashes, dots and brackets are dropped. Calling from a +1
/// (North American) number, a plain 10-digit number, or 11 digits starting with 1, is a +1 number (owner 2026-11-21:
/// a 10-digit number left Review Call greyed out). Anything else must be typed with its `+` country code.
nonisolated func phoneDestination(_ typed: String, from: String?) -> String {
    let kept = typed.filter { !$0.isWhitespace && !"-().".contains($0) }
    guard !kept.hasPrefix("+"), (from ?? "").hasPrefix("+1"), kept.allSatisfy({ ("0"..."9").contains($0) }) else { return kept }
    if kept.count == 10, kept.first != "0", kept.first != "1" { return "+1" + kept }
    if kept.count == 11, kept.first == "1" { return "+" + kept }
    return kept
}

/// When the app hangs up itself if samplehost's `time_limit_secs` somehow didn't: ring time + 30 minutes after dialing.
nonisolated func phoneHangupDeadline(placedAt: Date) -> Date {
    placedAt.addingTimeInterval(TimeInterval(PhoneLimits.ringSeconds + PhoneLimits.callSeconds))
}

// MARK: - A call

/// A question the assistant asked and the owner's answer (nil until answered).
nonisolated struct PhoneQA: Codable, Equatable, Sendable {
    let question: String
    var answer: String?
}

/// Item 9: whether the call's result went into its chat. `pending`: waiting for that chat to be open.
nonisolated enum PhoneResultState: String, Codable, Sendable { case none, pending, sent, off }

nonisolated struct PhoneCallRecord: Identifiable, Equatable, Codable, Sendable {
    nonisolated enum State: String, Codable, Sendable { case calling, live, ending, ended }
    let id: String              // samplehost call_control_id
    /// The chat it was placed from (its stored id where known; migrated once a new chat gets its stored id).
    var sessionID: String
    var profile: String? = nil
    let to: String
    let purpose: String
    let placedAt: Date
    let hangupCommandID: String
    var legID: String? = nil
    var samplehostSessionID: String? = nil
    var recorded = false
    var voicemailChoice: PhoneVoicemailChoice = .hangUp
    var suggested = false
    var state: State = .calling
    var conversationID: String? = nil
    var liveAt: Date? = nil
    var answeredAt: Date? = nil
    var endedAt: Date? = nil
    /// When the app first knew the call was over (the event log is read for a minute after this).
    var overAt: Date? = nil
    var duration: Int? = nil
    var ringSeconds: Double? = nil
    var voicemail = false
    var outcome: PhoneOutcome? = nil
    var settled = false
    var settledAt: Date? = nil
    var localEnd: PhoneLocalEnd? = nil
    var endNote: String? = nil
    var seenAlive = false
    var events: [PhoneCallEvent] = []
    var lines: [PhoneTranscript.Line] = []
    var transcriptChangedAt: Date? = nil
    var question: PhoneTranscript.Question? = nil
    var answered: Set<String> = []
    var asked: [PhoneQA] = []
    var result: PhoneResultState = .none
    var resultFingerprint: String? = nil
    // While the app runs only.
    var answerCommandIDs: [String: String] = [:]
    var sendingAnswer: String? = nil
    var lastAnswer: String? = nil
    var issue: String? = nil
    /// What the owner sent that the conversation hasn't returned yet (shown at once as "You" lines).
    var pendingYou: [String] = []
    var pendingAnswers: [Int]? = nil
    var name: String? = nil
    var botName: String? = nil
    var callingOwner: Bool? = nil
    var openingGreeting: String? = nil
    var summary: String? = nil
    var summaryFinished: Bool? = nil
    var messageLeft: Bool {
        voicemailChoice == .leaveMessage && lines.contains { $0.speaker == .assistant && $0.followsVoicemail == true }
    }
    var watchIssue: String? = nil
    var sendingMessage = false

    nonisolated enum CodingKeys: String, CodingKey {
        case id, sessionID, profile, to, purpose, placedAt, hangupCommandID, legID, samplehostSessionID, recorded,
             voicemailChoice, suggested, state, conversationID, liveAt, answeredAt, endedAt, overAt, duration, ringSeconds,
             voicemail, outcome, settled, settledAt, localEnd, endNote, seenAlive, events, lines, transcriptChangedAt,
             question, answered, asked, result, resultFingerprint, pendingYou, pendingAnswers, name, botName,
             callingOwner, openingGreeting, summary, summaryFinished
    }

    var active: Bool { state != .ended }
    var statusText: String {
        switch state {
        case .calling: return "Ringing…"
        case .live: return voicemail ? "Voicemail answered" : "On the call"
        case .ending: return "Ending…"
        case .ended: return outcome.map { phoneOutcomeTitle($0, duration: duration) } ?? "Ended"
        }
    }
    /// Item 12, under a voicemail call that picked up within 3 seconds.
    var straightToVoicemailNote: String? { phoneStraightToVoicemailNote(voicemail: voicemail, ringSeconds: ringSeconds) }
    /// The transcript as shown: what the conversation returned, then what the owner just sent.
    var shownLines: [PhoneTranscript.Line] {
        lines + pendingYou.enumerated().map { PhoneTranscript.Line(id: "pending|\($0.offset)", speaker: .you, text: $0.element, isAnswer: pendingAnswers?.contains($0.offset) == true ? true : nil) }
    }
    var theirLines: [String] { lines.filter { $0.speaker == .them }.map(\.text) }
    /// Watched until the outcome is settled and the result handled.
    var done: Bool { state == .ended && settled && result != .none && summaryFinished != false }
}

// MARK: - The controller

/// One HQ account's calls.
@MainActor @Observable final class PhoneCallController {
    private static var byAccount: [String: PhoneCallController] = [:]
    static func shared(for accountID: String) -> PhoneCallController {
        if let existing = byAccount[accountID] { return existing }
        let made = PhoneCallController(accountID: accountID)
        byAccount[accountID] = made
        made.resume()
        return made
    }
    /// The controllers made this run.
    static var all: [PhoneCallController] { Array(byAccount.values) }

    let accountID: String
    let store: PhoneKeyStore
    let history: PhoneHistoryStore?
    /// The client for a key (tests swap in a stubbed URLSession).
    var makeAPI: (String) -> samplehostAPI = { samplehostAPI(key: $0) }
    var now: () -> Date = { Date() }
    var pollInterval: Duration = .milliseconds(1500)
    var afterEndInterval: Duration = .seconds(3)
    /// The controller watches each call by itself (tests drive `refresh` by hand instead).
    var autoPoll = true
    /// How often the lagging event log is read while the call is on, and after it ended.
    var eventsEvery: TimeInterval = 5
    var eventsAfterEndEvery: TimeInterval = 3
    /// After the end the event log is read until `call.hangup` shows, at most this long.
    var eventsGiveUp: TimeInterval = 60
    /// Item 9: the result waits for the transcript to stop changing this long, or at most `resultDeadline`.
    var resultQuiet: TimeInterval = 6
    var resultDeadline: TimeInterval = 30
    var summaryResultWait: TimeInterval = 20
    var summaryDeadline: TimeInterval = 45
    private var placing = false
    /// The chat a result goes into, when it is open now: a sender for it (PhoneChatDelivery).
    var chatSender: (_ call: PhoneCallRecord) -> ((PhoneResultMessage) -> Void)? = { _ in nil }
    /// Posts a local alert (PhoneAlerts).
    var alert: (PhoneAlert) -> Void = { PhoneAlerts.post($0) }
    var appActive: () -> Bool = { UIApplication.shared.applicationState == .active }
    private(set) var calls: [PhoneCallRecord] = []
    private var dialRetry = PhoneStartRetry()
    @ObservationIgnored private var watchdogs: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pollers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var refreshing: Set<String> = []
    @ObservationIgnored private var eventsReadAt: [String: Date] = [:]
    @ObservationIgnored private var alerted: Set<String> = []
    @ObservationIgnored private var quietlyAnswered: Set<String> = []
    @ObservationIgnored private var sheets: [String: Int] = [:]

    init(accountID: String, store: PhoneKeyStore = .app, history: PhoneHistoryStore? = .app) {
        self.accountID = accountID; self.store = store; self.history = history
        calls = history?.load(for: accountID) ?? []
        chatSender = { [weak self] call in
            guard let self else { return nil }
            return PhoneChatDelivery.sender(account: self.accountID, call: call)
        }
        PhoneBackgroundWatch.install()
    }

    var setup: PhoneSetup? { store.load(for: accountID) }
    var ready: Bool { setup?.ready == true }
    var hasActiveCall: Bool { placing || calls.contains(where: \.active) }
    /// Any call still watched (on, or its outcome or result not done yet).
    var watching: Bool { calls.contains { !$0.done } }
    func calls(for sessionID: String) -> [PhoneCallRecord] { calls.filter { $0.sessionID == sessionID } }
    func call(_ id: String) -> PhoneCallRecord? { calls.first { $0.id == id } }

    private var api: samplehostAPI? { setup.map { makeAPI($0.apiKey) } }
    private func index(_ id: String) -> Int? { calls.firstIndex { $0.id == id } }
    private func save() { history?.save(calls, for: accountID) }

    /// Calls left from an earlier run: one still going (or not settled) is checked again and watched to its end.
    func resume() {
        for call in calls where !call.done {
            if call.active { startWatchdog(call.id) }
            startPolling(call.id)
        }
    }

    /// Re-keys calls filed under a temporary runtime session id once the chat receives its durable `storedSessionId`.
    func migrateSession(from oldIDs: [String], to storedID: String) {
        let targets = Set(oldIDs)
        var changed = false
        for i in calls.indices where targets.contains(calls[i].sessionID) && calls[i].sessionID != storedID {
            calls[i].sessionID = storedID
            changed = true
        }
        if changed { save() }
    }

    // MARK: Dial

    /// Dials after the owner confirmed. First makes the assistant's recording match Settings (and auto-tunes suboptimal
    /// voice settings; a recording mismatch blocks the call). Throws a readable failure; a retry of the same intent
    /// reuses its command_id.
    @discardableResult
    func place(sessionID: String, profile: String? = nil, to: String, purpose: String,
               voicemail: PhoneVoicemailChoice = .hangUp, suggested: Bool = false, name: String? = nil,
               botName: String? = nil, callingOwner: Bool = false, greeting: String? = nil,
               chatContext: String? = nil) async throws -> String {
        guard let setup, setup.ready, let from = setup.fromNumber, let connection = setup.connectionID,
              let assistant = setup.assistantID else {
            throw samplehostError.provider("Phone Calls isn't set up. Connect samplehost in Settings first.")
        }
        let api = makeAPI(setup.apiKey)
        guard !hasActiveCall else { throw samplehostError.provider("Another call is still going. Hang it up first.") }
        placing = true
        defer { placing = false }
        let prepared = await Result.of { try await api.prepareAssistantForCall(assistantID: assistant, recording: setup.records) }
        if case .failure(let error) = prepared {
            throw samplehostError.refused("The call wasn't placed: couldn't make the assistant's recording match Settings. " + phoneMessage(error))
        }
        let effectiveSelf = callingOwner
            || PhoneAskOwner.infersCallingOwner(ownerName: setup.name, calleeName: name ?? "", purpose: purpose)
        let commandID = dialRetry.id(for: PhoneStartIntent(session: sessionID, destination: to, goal: purpose,
                                                           voicemail: voicemail, name: name, callingOwner: effectiveSelf,
                                                           greeting: greeting, chatContext: chatContext))
        let request = PhoneDialRequest(to: to, from: from, connectionID: connection, assistantID: assistant,
                                       purpose: purpose, commandID: commandID, ownerName: setup.name,
                                       calleeName: name ?? "", botName: botName ?? "", callingOwner: effectiveSelf,
                                       greeting: greeting ?? "", chatContext: chatContext ?? "",
                                       recorded: setup.records, voicemail: voicemail)
        let spokenGreeting = PhoneAskOwner.greeting(for: request)
        let dialed = try await api.dial(request, now: now())
        dialRetry.completed()
        let id = dialed.call_control_id
        if index(id) == nil {
            var record = PhoneCallRecord(id: id, sessionID: sessionID, profile: profile, to: to, purpose: purpose,
                                         placedAt: now(), hangupCommandID: UUID().uuidString)
            record.legID = dialed.call_leg_id
            record.samplehostSessionID = dialed.call_session_id
            record.recorded = setup.records
            record.name = name
            record.botName = botName.flatMap { let t = $0.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t }
            record.callingOwner = effectiveSelf
            record.openingGreeting = spokenGreeting
            record.voicemailChoice = voicemail
            record.suggested = suggested
            calls.append(record)
            save()
        }
        startWatchdog(id)
        startPolling(id)
        return id
    }

    // MARK: Watching

    private func startPolling(_ id: String) {
        guard autoPoll, pollers[id] == nil else { return }
        pollers[id] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let call = self.call(id), !call.done else { break }
                await self.refresh(id)
                guard let after = self.call(id), !after.done else { break }
                try? await Task.sleep(for: after.active ? self.pollInterval : self.afterEndInterval)
            }
            self?.pollers[id] = nil
            PhoneBackgroundWatch.update()
        }
    }

    /// One look at a call: its conversation (found by call_control_id) and messages, whether it is alive, and the
    /// lagging event log; then what the app can say about it (PhoneVerdict) and, once settled, its result.
    func refresh(_ id: String) async {
        guard let api, let start = call(id), !start.done, refreshing.insert(id).inserted else { return }
        defer { refreshing.remove(id) }
        if !(start.state == .ended && start.settled) || (start.summaryFinished == false && start.conversationID == nil) {
            await readConversation(id, api)
        }
        guard let afterTranscript = call(id) else { return }
        var justOver = false
        if afterTranscript.active {
            let status = await Result.of { try await api.callStatus(callControlID: id) }
            guard let i = index(id) else { return }
            switch status {
            case .success(let found):
                if found?.is_alive == true {
                    calls[i].seenAlive = true
                } else {
                    let ringOver = now().timeIntervalSince(calls[i].placedAt) > TimeInterval(PhoneLimits.ringSeconds + 10)
                    if calls[i].seenAlive || calls[i].conversationID != nil || ringOver { markOver(id, local: nil); justOver = true }
                }
            case .failure(let error):
                calls[i].watchIssue = phoneMessage(error)
            }
        }
        guard let current = call(id) else { return }
        if let leg = current.legID, !current.settled {
            let every = current.active ? eventsEvery : eventsAfterEndEvery
            let due = justOver || eventsReadAt[id].map { now().timeIntervalSince($0) >= every } ?? true
            if due {
                eventsReadAt[id] = now()
                if case .success(let events) = await Result.of({ try await api.callEvents(legID: leg) }), let i = index(id) {
                    calls[i].events = events
                }
                // Read every time the event log is, until samplehost gives the call's length.
                if let i = index(id), calls[i].state == .ended, calls[i].duration == nil,
                   case .success(let status) = await Result.of({ try await api.callStatus(callControlID: id) }),
                   let j = index(id), let status, status.call_duration != nil {
                    calls[j].endedStatus = status
                }
            }
        }
        judge(id)
        await hangupOrphanedAssistant(id, api)
        if let overAt = call(id)?.overAt, now().timeIntervalSince(overAt) >= summaryResultWait {
            await finishResult(id)
        }
        await readSummary(id, api)
        await finishResult(id)
    }

    /// On Call Control, `call.conversation.start_failed` or `call.conversation.ended` stops the AI assistant without
    /// hanging up the underlying phone leg, leaving dead air billing until hung up. Close any orphaned leg cleanly.
    private func hangupOrphanedAssistant(_ id: String, _ api: samplehostAPI) async {
        guard let i = index(id), calls[i].active, calls[i].state != .ending,
              !calls[i].events.contains(where: { $0.name == "call.hangup" }) else { return }
        let startFailed = calls[i].events.contains { $0.name == "call.conversation.start_failed" }
        let staleConversationEnded = calls[i].events.first(where: { $0.name == "call.conversation.ended" })
            .flatMap(\.occurredAt).map { now().timeIntervalSince($0) >= 15 } ?? false
        guard startFailed || staleConversationEnded else { return }
        let commandID = calls[i].hangupCommandID
        _ = await Result.of { try await api.hangup(callControlID: id, commandID: commandID) }
        guard let j = index(id) else { return }
        if startFailed, calls[j].endNote == nil { calls[j].endNote = "Voice assistant couldn't start" }
        markOver(id, local: nil)
        judge(id)
    }

    private func readSummary(_ id: String, _ api: samplehostAPI) async {
        guard let call = call(id), call.state == .ended, call.summaryFinished == false else { return }
        let elapsed = now().timeIntervalSince(call.overAt ?? call.placedAt)
        if elapsed >= summaryDeadline {
            if let i = index(id) { calls[i].summaryFinished = true; save() }
            return
        }
        guard let conversation = call.conversationID,
              case .success(let summary?) = await Result.of({ try await api.conversationSummary(conversationID: conversation) }),
              let i = index(id) else { return }
        calls[i].summary = summary
        calls[i].summaryFinished = true
        save()
    }

    /// The conversation and its messages. They trail the call, and keep arriving for a while after it ended.
    private func readConversation(_ id: String, _ api: samplehostAPI) async {
        guard let call = call(id) else { return }
        let found: Result<String?, Error>
        if let known = call.conversationID { found = .success(known) } else {
            found = await Result.of { try await api.conversationID(callControlID: id) }
        }
        guard case .success(let conversation?) = found else {
            if case .failure(let error) = found, let i = index(id) { calls[i].watchIssue = phoneMessage(error) }
            else if let i = index(id) { calls[i].watchIssue = nil }
            return
        }
        let read = await Result.of { try await api.messages(conversationID: conversation) }
        guard let i = index(id) else { return }
        var stateChanged = false
        if calls[i].conversationID == nil { calls[i].conversationID = conversation; stateChanged = true }
        if calls[i].liveAt == nil { calls[i].liveAt = now(); stateChanged = true }
        if calls[i].state == .calling { calls[i].state = .live; stateChanged = true }
        if stateChanged { save() }
        switch read {
        case .failure(let error): calls[i].watchIssue = phoneMessage(error)
        case .success(let messages):
            calls[i].watchIssue = nil
            apply(PhoneTranscript.read(messages, answered: calls[i].answered), to: id)
            await answerRepeat(id, api)
        }
    }

    private func apply(_ transcript: PhoneTranscript, to id: String) {
        guard let i = index(id) else { return }
        var call = calls[i]
        // What the owner sent and the conversation now returns stops being "pending" (each new You line takes one).
        var fresh: [PhoneTranscript.OwnerWords: Int] = [:]
        for line in transcript.lines where line.speaker == .you { fresh[.init(text: line.text, isAnswer: line.isAnswer == true), default: 0] += 1 }
        for line in call.lines where line.speaker == .you { fresh[.init(text: line.text, isAnswer: line.isAnswer == true), default: 0] -= 1 }
        var remainingAnswers: [Int] = []
        var remainingCount = 0
        call.pendingYou = call.pendingYou.enumerated().compactMap { offset, text in
            let isAnswer = call.pendingAnswers?.contains(offset) == true
            let words = PhoneTranscript.OwnerWords(text: text, isAnswer: isAnswer)
            if (fresh[words] ?? 0) > 0 {
                fresh[words]! -= 1
                return nil
            }
            if isAnswer { remainingAnswers.append(remainingCount) }
            remainingCount += 1
            return text
        }
        if call.pendingAnswers != nil { call.pendingAnswers = remainingAnswers }
        if transcript.lines != call.lines { call.lines = transcript.lines; call.transcriptChangedAt = now() }
        call.answered.formUnion(transcript.answeredInConversation)
        if call.sendingAnswer == nil, call.active { call.question = transcript.question }
        for asked in transcript.asked where !call.asked.contains(where: { PhoneTranscript.normalized($0.question) == PhoneTranscript.normalized(asked.text) }) {
            call.asked.append(PhoneQA(question: asked.text, answer: nil))
        }
        // An answer read back from the conversation (sent before a relaunch) fills its question's answer.
        for (toolCallID, text) in transcript.answers {
            guard let asked = transcript.asked.first(where: { $0.id == toolCallID }),
                  let k = call.asked.firstIndex(where: { PhoneTranscript.normalized($0.question) == PhoneTranscript.normalized(asked.text) }),
                  call.asked[k].answer == nil else { continue }
            call.asked[k].answer = text
        }
        if call.state == .calling, !call.lines.isEmpty { call.state = .live }
        let humanDetected = call.events.contains(where: \.isHumanDetection)
        if !call.voicemail, !(humanDetected && call.theirLines.count >= 3),
           call.theirLines.prefix(2).contains(where: phoneSoundsLikeVoicemail) {
            call.voicemail = true
        }
        let changed = call != calls[i]
        calls[i] = call
        if changed { save() }
        alertIfUnseen(id)
    }

    /// A question asked again after the owner already answered it (the model repeated itself, or the repeat arrived in
    /// a later batch): it is not shown again; the same answer goes back quietly to its tool call.
    private func answerRepeat(_ id: String, _ api: samplehostAPI) async {
        guard let i = index(id), calls[i].active, calls[i].state != .ending, let question = calls[i].question,
              calls[i].sendingAnswer == nil,
              let answer = calls[i].asked.first(where: { PhoneTranscript.normalized($0.question) == PhoneTranscript.normalized(question.text) })?.answer
        else { return }
        let ids = question.ids.filter { !calls[i].answered.contains($0) && !quietlyAnswered.contains($0) }
        calls[i].question = nil
        guard !ids.isEmpty else { return }
        quietlyAnswered.formUnion(ids)
        let sent = await Result.of {
            try await api.deliverAnswer(callControlID: id, toolCallIDs: ids, question: question.text, answer: answer,
                                        commandID: UUID().uuidString, quiet: true)
        }
        guard let j = index(id) else { return }
        if case .success = sent { calls[j].answered.formUnion(ids); save() }
    }

    /// What the reads say about the call (PhoneVerdict.derive), applied to it.
    private func judge(_ id: String) {
        guard let i = index(id) else { return }
        if calls[i].active, calls[i].events.contains(where: { $0.name == "call.hangup" }) {
            markOver(id, local: nil)
        }
        guard let idx = index(id) else { return }
        var call = calls[idx]
        let over = call.state == .ended
        let gaveUp = over && (call.overAt.map { now().timeIntervalSince($0) >= eventsGiveUp } ?? true)
        let verdict = PhoneVerdict.derive(events: call.events, status: call.endedStatus, theirLines: call.theirLines,
                                          ended: over, localEnd: call.localEnd, gaveUp: gaveUp)
        if let answered = verdict.answeredAt { call.answeredAt = answered }
        if let ended = verdict.endedAt { call.endedAt = ended }
        if let ring = verdict.ringSeconds { call.ringSeconds = ring }
        if let duration = verdict.duration { call.duration = duration }
        if verdict.voicemail { call.voicemail = true }
        if call.state == .calling, verdict.answeredAt != nil { call.state = .live }
        if verdict.settled, !call.settled {
            call.settled = true
            call.settledAt = now()
            call.outcome = verdict.outcome
            AppLog.note("phone", "call settled")
        }
        let changed = call != calls[idx]
        calls[idx] = call
        if changed { save() }
    }

    /// Item 9: once settled and the transcript is quiet (or 30 s passed), the result goes into the call's chat: now if
    /// that chat is open, else the next time it opens (`deliverPending`). Marked before it is sent, so it is sent at
    /// most once, also across relaunches.
    func finishResult(_ id: String) async {
        guard let i = index(id), calls[i].state == .ended, calls[i].settled, calls[i].result == .none else { return }
        guard setup?.sendsResults != false else { calls[i].result = .off; save(); return }
        let settledAt = calls[i].settledAt ?? now()
        let quietSince = max(calls[i].transcriptChangedAt ?? settledAt, settledAt)
        guard now().timeIntervalSince(quietSince) >= resultQuiet || now().timeIntervalSince(settledAt) >= resultDeadline else { return }
        let overAt = calls[i].overAt ?? settledAt
        if calls[i].summaryFinished == false, calls[i].conversationID != nil,
           now().timeIntervalSince(overAt) < summaryResultWait { return }
        let message = PhoneResultMessage(calls[i])
        if let send = chatSender(calls[i]) {
            calls[i].result = .sent
            calls[i].resultFingerprint = PhoneResultCard.fingerprint(message.text)
            save()
            AppLog.note("phone", "call result sent to its chat")
            send(message)
        } else {
            calls[i].result = .pending
            save()
            AppLog.note("phone", "call result waits for its chat to open")
        }
    }

    /// A chat came on screen (its open settled): results waiting for it go in now.
    func deliverPending(matching matches: (PhoneCallRecord) -> Bool, send: (PhoneResultMessage) -> Void) {
        for i in calls.indices where calls[i].result == .pending && matches(calls[i]) {
            let message = PhoneResultMessage(calls[i])
            calls[i].result = .sent
            calls[i].resultFingerprint = PhoneResultCard.fingerprint(message.text)
            save()
            AppLog.note("phone", "waiting call result sent to its chat")
            send(message)
        }
    }

    // MARK: The sheet and alerts

    func sheetAppeared(_ sessionID: String) {
        sheets[sessionID, default: 0] += 1
        for call in calls(for: sessionID) { if let q = call.question { alerted.formUnion(q.ids) } }
    }
    func sheetDisappeared(_ sessionID: String) { sheets[sessionID] = max(0, (sheets[sessionID] ?? 0) - 1) }
    func sheetOnScreen(_ sessionID: String) -> Bool { (sheets[sessionID] ?? 0) > 0 && appActive() }

    /// A new question while that call's sheet isn't on screen: a local alert (PhoneAlerts), once per question.
    private func alertIfUnseen(_ id: String) {
        guard let call = call(id), let question = call.question, !question.ids.allSatisfy(alerted.contains) else { return }
        alerted.formUnion(question.ids)
        // A repeat of a question already answered goes back on its own (answerRepeat): nothing to ask.
        let key = PhoneTranscript.normalized(question.text)
        guard !call.asked.contains(where: { PhoneTranscript.normalized($0.question) == key && $0.answer != nil }) else { return }
        guard !sheetOnScreen(call.sessionID) else { return }
        alert(.question(account: accountID, session: call.sessionID, profile: call.profile, call: id, text: question.text))
    }

    // MARK: Talking to the assistant

    /// Sends the owner's answer to the assistant on the call: one tool result per tool call that asked this question,
    /// and one system note, with trigger_response.
    func answer(_ id: String, question: PhoneTranscript.Question, with text: String) async {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let api, let i = index(id), calls[i].active, calls[i].state != .ending, !answer.isEmpty,
              calls[i].sendingAnswer == nil, calls[i].question?.id == question.id,
              !calls[i].answered.contains(question.id) else { return }
        let ids = (calls[i].question?.ids ?? question.ids).filter { !calls[i].answered.contains($0) }
        let commandID = calls[i].answerCommandIDs[question.id] ?? UUID().uuidString
        calls[i].answerCommandIDs[question.id] = commandID
        calls[i].sendingAnswer = question.id
        let sent = await Result.of {
            try await api.deliverAnswer(callControlID: id, toolCallIDs: ids, question: question.text, answer: answer, commandID: commandID)
        }
        guard let j = index(id) else { return }
        calls[j].sendingAnswer = nil
        switch sent {
        case .success:
            calls[j].answered.formUnion(ids)
            calls[j].question = nil
            calls[j].lastAnswer = answer
            calls[j].issue = nil
            calls[j].pendingAnswers = (calls[j].pendingAnswers ?? []) + [calls[j].pendingYou.count]
            calls[j].pendingYou.append(answer)
            let key = PhoneTranscript.normalized(question.text)
            if let k = calls[j].asked.firstIndex(where: { PhoneTranscript.normalized($0.question) == key }) {
                calls[j].asked[k].answer = answer
            } else {
                calls[j].asked.append(PhoneQA(question: question.text, answer: answer))
            }
            save()
        case .failure(let error):
            if case samplehostError.callEnded = error { markOver(id, local: nil) } else { calls[j].issue = phoneMessage(error) }
        }
    }

    /// Item 6: "Tell the assistant". Shows the words as a "You" line at once; answers whether they went.
    @discardableResult
    func tell(_ id: String, _ text: String) async -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let api, let i = index(id), calls[i].active, calls[i].state != .ending, !words.isEmpty,
              !calls[i].sendingMessage else { return false }
        calls[i].sendingMessage = true
        calls[i].issue = nil
        calls[i].pendingYou.append(words)
        let sent = await Result.of { try await api.sendOwnerMessage(callControlID: id, text: words, commandID: UUID().uuidString) }
        guard let j = index(id) else { return false }
        calls[j].sendingMessage = false
        switch sent {
        case .success:
            calls[j].transcriptChangedAt = now()
            save()
            return true
        case .failure(let error):
            if let k = calls[j].pendingYou.indices.last(where: {
                calls[j].pendingYou[$0] == words && calls[j].pendingAnswers?.contains($0) != true
            }) {
                calls[j].pendingYou.remove(at: k)
                calls[j].pendingAnswers = calls[j].pendingAnswers?.map { $0 > k ? $0 - 1 : $0 }
            }
            if case samplehostError.callEnded = error { markOver(id, local: nil) } else { calls[j].issue = phoneMessage(error) }
            return false
        }
    }

    /// Hangs up once. Repeated taps while it's ending and taps after it ended send nothing.
    func hangup(_ id: String, automatic: Bool = false) async {
        guard let api, let i = index(id), calls[i].active, calls[i].state != .ending else { return }
        let before = calls[i].state
        calls[i].state = .ending
        let command = calls[i].hangupCommandID
        let done = await Result.of { try await api.hangup(callControlID: id, commandID: command) }
        guard let j = index(id) else { return }
        switch done {
        case .success: markOver(id, local: automatic ? .safetyStop : .youHungUp)
        case .failure(let error):
            guard calls[j].state == .ending else { return }
            calls[j].state = before
            calls[j].issue = phoneMessage(error)
        }
    }

    /// Hangs up every live call (Disconnect), then forgets them.
    func endAll() async {
        for call in calls where call.active { await hangup(call.id) }
        for task in watchdogs.values { task.cancel() }
        for task in pollers.values { task.cancel() }
        watchdogs = [:]; pollers = [:]
        calls = []
    }

    /// Settings › Clear call history: every ended call goes (one still on stays).
    func clearHistory() {
        for call in calls where !call.active { pollers.removeValue(forKey: call.id)?.cancel() }
        calls.removeAll { !$0.active }
        if calls.isEmpty { history?.delete(for: accountID) } else { save() }
    }

    func deleteCall(_ id: String) {
        guard let i = index(id), !calls[i].active else { return }
        pollers.removeValue(forKey: id)?.cancel()
        eventsReadAt[id] = nil
        calls.remove(at: i)
        if calls.isEmpty { history?.delete(for: accountID) } else { save() }
    }

    /// Settings › Disconnect: the account's saved calls go with its key.
    func forgetHistory() {
        history?.delete(for: accountID)
    }

    /// The call is over: as samplehost says (`local` nil) or because the app hung up. Its outcome is read after this.
    private func markOver(_ id: String, local: PhoneLocalEnd?) {
        guard let i = index(id) else { return }
        calls[i].state = .ended
        if calls[i].overAt == nil {
            calls[i].overAt = now()
            calls[i].summaryFinished = false
        }
        if let local, calls[i].localEnd == nil { calls[i].localEnd = local; calls[i].endNote = local.note }
        calls[i].question = nil
        watchdogs.removeValue(forKey: id)?.cancel()
        save()
        startPolling(id)
    }

    /// The app-side backup for `time_limit_secs`: hangs up at `phoneHangupDeadline` while the app runs.
    private func startWatchdog(_ id: String) {
        watchdogs[id]?.cancel()
        watchdogs[id] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let call = self.calls.first(where: { $0.id == id }), call.active else { return }
                if self.now() >= phoneHangupDeadline(placedAt: call.placedAt) {
                    await self.hangup(id, automatic: true)
                    if self.calls.first(where: { $0.id == id })?.active != true { return }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

extension PhoneCallRecord {
    /// retrieve-a-call-status after the end (its `call_duration`), kept for the verdict.
    var endedStatus: samplehostCallStatus? {
        get { duration.map { samplehostCallStatus(call_duration: $0) } }
        set { if let seconds = newValue?.call_duration { duration = seconds } }
    }
}

// MARK: - In the background

/// With a call on, the app asks iOS for background time and keeps polling for as long as it allows. Honest limit:
/// once iOS suspends the app nothing is polled (no server can do it for us); the owner gets one alert when the time
/// runs out, and the watch resumes when the app is opened again.
@MainActor enum PhoneBackgroundWatch {
    private static var installed = false
    /// `BackgroundTime` always ends the task: here, or when iOS takes the time back (it stays set until the app
    /// is opened again, so one stretch in the background asks once).
    private static var time: BackgroundTime?

    static func install() {
        guard !installed else { return }
        installed = true
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { begin() }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { end() }
        }
    }

    private static func begin() {
        guard time == nil, PhoneCallController.all.contains(where: \.watching) else { return }
        AppLog.note("phone", "background watch began")
        time = BackgroundTime.begin("hq.phone-call") {
            AppLog.note("phone", "background time ran out")
            for controller in PhoneCallController.all {
                guard let call = controller.calls.first(where: \.active) else { continue }
                controller.alert(.stillGoing(account: controller.accountID, session: call.sessionID,
                                             profile: call.profile, call: call.id))
            }
        }
    }

    /// Ends the background time once nothing is watched any more.
    static func update() {
        guard time != nil, !PhoneCallController.all.contains(where: \.watching) else { return }
        end()
    }

    private static func end() {
        time?.end()
        time = nil
    }
}
