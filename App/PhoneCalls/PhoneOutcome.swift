// Phone Calls (Beta): how a call went, in plain words. Pure functions over what samplehost lets the app read without a
// server: the call's logged webhook events (list-call-events), retrieve-a-call-status, the transcript, and how the
// call ended here. The event log lags the call by 10 to 30 seconds, so the outcome is settled after the end.

import Foundation

// MARK: - Logged webhook events

/// One row of list-call-events with `filter[type]=webhook`: `name`, `occurred_at` and the webhook's own
/// `payload.payload` fields the app reads (`result`, `hangup_cause`, `hangup_source`, error/reason detail).
nonisolated struct PhoneCallEvent: Codable, Equatable, Sendable {
    let name: String
    let occurredAt: Date?
    var result: String? = nil
    var hangupCause: String? = nil
    var hangupSource: String? = nil
    var detail: String? = nil

    init(name: String, occurredAt: Date?, result: String? = nil, hangupCause: String? = nil,
         hangupSource: String? = nil, detail: String? = nil) {
        self.name = name; self.occurredAt = occurredAt; self.result = result
        self.hangupCause = hangupCause; self.hangupSource = hangupSource; self.detail = detail
    }

    private enum RowKeys: String, CodingKey { case name, occurred_at, payload, occurredAt, result, hangupCause, hangupSource, detail }
    private enum OuterKeys: String, CodingKey { case event_type, payload }
    private enum InnerKeys: String, CodingKey { case result, hangup_cause, hangup_source, error, reason, message }

    /// Reads the API's row and the app's own saved copy alike; a field of an unexpected type is left out.
    init(from decoder: Decoder) throws {
        let row = try decoder.container(keyedBy: RowKeys.self)
        if let saved = try? row.decodeIfPresent(Date.self, forKey: .occurredAt) {   // the history file
            name = try row.decode(String.self, forKey: .name)
            occurredAt = saved
            result = try? row.decodeIfPresent(String.self, forKey: .result)
            hangupCause = try? row.decodeIfPresent(String.self, forKey: .hangupCause)
            hangupSource = try? row.decodeIfPresent(String.self, forKey: .hangupSource)
            detail = try? row.decodeIfPresent(String.self, forKey: .detail)
            return
        }
        let outer = try? row.nestedContainer(keyedBy: OuterKeys.self, forKey: .payload)
        let inner = try? outer?.nestedContainer(keyedBy: InnerKeys.self, forKey: .payload)
        let named = (try? row.decodeIfPresent(String.self, forKey: .name)) ?? nil
        let typed = (try? outer?.decodeIfPresent(String.self, forKey: .event_type)) ?? nil
        name = named ?? typed ?? ""
        occurredAt = ((try? row.decodeIfPresent(String.self, forKey: .occurred_at)) ?? nil).flatMap(Self.date)
        result = (try? inner?.decodeIfPresent(String.self, forKey: .result)) ?? nil
        hangupCause = (try? inner?.decodeIfPresent(String.self, forKey: .hangup_cause)) ?? nil
        hangupSource = (try? inner?.decodeIfPresent(String.self, forKey: .hangup_source)) ?? nil
        let errText: String? = (try? inner?.decodeIfPresent(String.self, forKey: .error)) ?? nil
        let reasonText: String? = (try? inner?.decodeIfPresent(String.self, forKey: .reason)) ?? nil
        let msgText: String? = (try? inner?.decodeIfPresent(String.self, forKey: .message)) ?? nil
        detail = errText ?? reasonText ?? msgText
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: RowKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(occurredAt, forKey: .occurredAt)
        try c.encodeIfPresent(result, forKey: .result)
        try c.encodeIfPresent(hangupCause, forKey: .hangupCause)
        try c.encodeIfPresent(hangupSource, forKey: .hangupSource)
        try c.encodeIfPresent(detail, forKey: .detail)
    }

    /// `occurred_at` as samplehost writes it: "2026-11-21 12:36:49.554602" (a space, no `T`, no zone: UTC, microseconds).
    /// ISO 8601 with a `T` and a zone reads too.
    static func date(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.wholeMatch(of: /(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:?\d{2})?/) else { return nil }
        var parts = DateComponents()
        parts.calendar = Calendar(identifier: .gregorian)
        parts.timeZone = TimeZone(identifier: "UTC")
        parts.year = Int(match.1); parts.month = Int(match.2); parts.day = Int(match.3)
        parts.hour = Int(match.4); parts.minute = Int(match.5); parts.second = Int(match.6)
        guard var date = parts.date else { return nil }
        if let fraction = match.7, let value = Double("0." + fraction) { date.addTimeInterval(value) }
        if let zone = match.8, zone != "Z" {
            let digits = zone.filter(\.isNumber)
            let hours = Int(digits.prefix(2)) ?? 0, minutes = Int(digits.suffix(2)) ?? 0
            let offset = TimeInterval(hours * 3600 + minutes * 60)
            date.addTimeInterval(zone.hasPrefix("-") ? offset : -offset)
        }
        return date
    }

    /// The machine-detection events whose `result` says what answered.
    static let detectionNames: Set<String> = ["call.machine.premium.detection.ended", "call.machine.detection.ended"]
    /// Premium/Standard greeting-end events; samplehost sends `beep_detected` here even when a beep arrives before detection ends.
    static let greetingEndedNames: Set<String> = ["call.machine.premium.greeting.ended", "call.machine.greeting.ended"]

    var isMachineDetection: Bool {
        let lower = result?.lowercased() ?? ""
        if Self.detectionNames.contains(name) { return lower.hasPrefix("machine") }
        if Self.greetingEndedNames.contains(name) { return lower == "beep_detected" }
        return false
    }

    var isHumanDetection: Bool {
        Self.detectionNames.contains(name) && result?.lowercased().hasPrefix("human") == true
    }
}

// MARK: - The outcome

nonisolated enum PhoneOutcome: Codable, Equatable, Sendable {
    case finished, voicemail, noAnswer, busy, declined, noSuchNumber
    case couldNotConnect(String)
    /// The call ended and the event log never said how (read for about a minute).
    case unknown
}

/// How the call ended here, if it did.
nonisolated enum PhoneLocalEnd: String, Codable, Sendable {
    case youHungUp, safetyStop
    var note: String { self == .youHungUp ? "You hung up" : PhoneLimits.safetyStopNote }
}

/// What the app knows about a call from everything it can read.
nonisolated struct PhoneVerdict: Equatable, Sendable {
    var answeredAt: Date?
    var endedAt: Date?
    var ringSeconds: Double?
    var duration: Int?
    var voicemail = false
    var outcome: PhoneOutcome?
    /// True once the outcome is final (the event log showed `call.hangup`, or it was read long enough).
    var settled = false

    /// The one place a call's outcome is decided.
    /// - `events`: the logged webhook events (any order).
    /// - `status`: retrieve-a-call-status after the end (`call_duration`).
    /// - `theirLines`: what the other side said (voicemail wording).
    /// - `ended`: the call is over (samplehost says not alive, or the app hung up).
    /// - `localEnd`: how it ended here.
    /// - `gaveUp`: the event log was read for long enough after the end without a `call.hangup`.
    static func derive(events: [PhoneCallEvent], status: samplehostCallStatus?, theirLines: [String], ended: Bool,
                       localEnd: PhoneLocalEnd?, gaveUp: Bool) -> PhoneVerdict {
        func first(_ name: String) -> PhoneCallEvent? {
            events.filter { $0.name == name }.min { ($0.occurredAt ?? .distantFuture) < ($1.occurredAt ?? .distantFuture) }
        }
        var verdict = PhoneVerdict()
        let initiated = first("call.initiated")
        let answered = first("call.answered")
        let hangup = first("call.hangup")
        let startFailed = first("call.conversation.start_failed")
        let machine = events.contains(where: \.isMachineDetection)
        let humanDetected = events.contains(where: \.isHumanDetection)
        let openingVoicemail = !(humanDetected && theirLines.count >= 3)
            && theirLines.prefix(2).contains(where: phoneSoundsLikeVoicemail)
        verdict.voicemail = machine || openingVoicemail
        verdict.answeredAt = answered?.occurredAt
        verdict.endedAt = hangup?.occurredAt
        if let start = initiated?.occurredAt, let pickup = answered?.occurredAt { verdict.ringSeconds = max(0, pickup.timeIntervalSince(start)) }
        let pickedUp = answered != nil || !theirLines.isEmpty
        if pickedUp {
            if let seconds = status?.call_duration { verdict.duration = seconds }
            else if let pickup = answered?.occurredAt, let end = hangup?.occurredAt { verdict.duration = max(0, Int(end.timeIntervalSince(pickup).rounded())) }
        }
        guard ended else { return verdict }
        let startFailureOutcome: PhoneOutcome? = startFailed.flatMap { failed in
            guard theirLines.isEmpty else { return nil }
            let detail = failed.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .couldNotConnect(detail.flatMap { $0.isEmpty ? nil : $0 } ?? "the voice assistant couldn't start")
        }
        if let hangup {
            verdict.settled = true
            verdict.outcome = startFailureOutcome ?? (pickedUp ? (verdict.voicemail ? .voicemail : .finished) : unanswered(hangup.hangupCause))
        } else if gaveUp {
            verdict.settled = true
            if let startFailureOutcome { verdict.outcome = startFailureOutcome }
            else if pickedUp { verdict.outcome = verdict.voicemail ? .voicemail : .finished }
            else if localEnd == .youHungUp { verdict.outcome = .noAnswer }
            else { verdict.outcome = .unknown }
        }
        return verdict
    }

    /// A call that ended before anyone picked up, by `hangup_cause`.
    static func unanswered(_ cause: String?) -> PhoneOutcome {
        switch (cause ?? "").lowercased() {
        case "no_answer", "timeout", "originator_cancel", "normal_clearing", "": return .noAnswer
        case "user_busy": return .busy
        case "call_rejected": return .declined
        case "unallocated_number", "invalid_number_format": return .noSuchNumber
        case let other: return .couldNotConnect(plainCause(other))
        }
    }

    /// A hangup cause in plain words.
    static func plainCause(_ cause: String) -> String {
        switch cause {
        case "destination_out_of_order": return "the other phone is out of service"
        case "normal_temporary_failure", "temporary_failure": return "a temporary network problem"
        case "network_out_of_order": return "the network is out of order"
        case "service_unavailable": return "the phone service was unavailable"
        case "incompatible_destination": return "the other side can't take this kind of call"
        case "recovery_on_timer_expire": return "the network timed out"
        case "call_awarded_delivered", "normal_unspecified": return "the network ended the call"
        default:
            let words = cause.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
            return words.isEmpty ? "unknown reason" : words
        }
    }
}

// MARK: - Words

/// "23s", "1m 32s", "1h 2m".
nonisolated func phoneDuration(_ seconds: Int) -> String {
    let s = max(0, seconds)
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    return "\(s / 3600)h \((s % 3600) / 60)m"
}

/// The outcome as the call sheet says it ("Finished · 1m 32s").
nonisolated func phoneOutcomeTitle(_ outcome: PhoneOutcome, duration: Int?) -> String {
    switch outcome {
    case .finished: return duration.map { "Finished · \(phoneDuration($0))" } ?? "Finished"
    case .voicemail: return duration.map { "Went to voicemail · \(phoneDuration($0))" } ?? "Went to voicemail"
    case .noAnswer: return "No answer"
    case .busy: return "Busy"
    case .declined: return "Declined"
    case .noSuchNumber: return "Couldn't connect: that number doesn't exist"
    case .couldNotConnect(let reason): return "Couldn't connect: \(reason)"
    case .unknown: return "Ended"
    }
}

/// The outcome as the result message says it ("finished, 1m 32s").
nonisolated func phoneOutcomeWords(_ outcome: PhoneOutcome?, duration: Int?) -> String {
    switch outcome {
    case .finished?: return duration.map { "finished, \(phoneDuration($0))" } ?? "finished"
    case .voicemail?: return duration.map { "went to voicemail, \(phoneDuration($0))" } ?? "went to voicemail"
    case .noAnswer?: return "no answer"
    case .busy?: return "busy"
    case .declined?: return "declined"
    case .noSuchNumber?: return "couldn't connect: that number doesn't exist"
    case .couldNotConnect(let reason)?: return "couldn't connect: \(reason)"
    case .unknown?, nil: return "ended"
    }
}

/// Item 12: a voicemail that answered within 3 seconds most likely never rang the phone.
nonisolated func phoneStraightToVoicemailNote(voicemail: Bool, ringSeconds: Double?) -> String? {
    guard voicemail, let ring = ringSeconds, ring < 3 else { return nil }
    let n = max(1, Int(ring.rounded()))
    return "Voicemail picked up in \(n) second\(n == 1 ? "" : "s"), so the phone probably never rang. That is the other "
        + "phone or its carrier (Do Not Disturb or a Focus, Silence Unknown Callers, a spam filter), not your samplehost setup."
}

/// "+1 212 555 0142" for a North American number; others as dialed.
nonisolated func phoneShown(_ number: String) -> String {
    guard number.hasPrefix("+1"), number.count == 12, number.dropFirst().allSatisfy(\.isNumber) else { return number }
    let digits = Array(number.dropFirst(2))
    return "+1 \(String(digits[0..<3])) \(String(digits[3..<6])) \(String(digits[6..<10]))"
}
