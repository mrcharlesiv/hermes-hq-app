import Foundation

nonisolated enum PhoneMark: Equatable, Sendable {
    case phone, warning, success, voicemail, missed, failed, ended, proposal

    var symbol: String {
        switch self {
        case .phone, .proposal: "phone.fill"
        case .warning: "exclamationmark"
        case .success: "checkmark"
        case .voicemail: "recordingtape"
        case .missed: "phone.arrow.down.left"
        case .failed: "xmark"
        case .ended: "phone.down.fill"
        }
    }

    static func outcome(_ outcome: PhoneOutcome?) -> Self {
        switch outcome {
        case .finished: .success
        case .voicemail: .voicemail
        case .noAnswer, .busy, .declined: .missed
        case .couldNotConnect, .noSuchNumber: .failed
        case .unknown, nil: .ended
        }
    }
}

nonisolated enum PhoneCallPresentation {
    enum Action: String, Equatable, Sendable {
        case again = "Call again"
        case leave = "Leave a message"
        case transcript = "Transcript"
        case share = "Share"
    }

    struct Fact: Identifiable, Equatable, Sendable {
        let id: String
        let value: String
        init(_ id: String, _ value: String) { self.id = id; self.value = value }
    }

    static func timer(from: Date, to: Date) -> String {
        let seconds = max(0, Int(to.timeIntervalSince(from)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func duration(_ seconds: Int) -> String {
        guard (60..<3600).contains(seconds) else { return phoneDuration(seconds) }
        return String(format: "%dm %02ds", seconds / 60, seconds % 60)
    }

    static func title(_ outcome: PhoneOutcome?, duration: Int?) -> String {
        switch outcome {
        case .finished: duration.map { "Finished · " + Self.duration($0) } ?? "Finished"
        case .voicemail: "Went to voicemail"
        case .couldNotConnect, .noSuchNumber: "Couldn't connect"
        case let outcome?: phoneOutcomeTitle(outcome, duration: nil)
        case nil: "Wrapping up…"
        }
    }

    static func reason(_ call: PhoneCallRecord) -> String {
        switch call.outcome {
        case .finished: "The call finished."
        case .voicemail: call.straightToVoicemailNote ?? (call.messageLeft ? "The assistant left a voicemail message." : "Voicemail answered the call.")
        case .noAnswer: call.localEnd == .youHungUp ? "You hung up before anyone answered." : "Nobody answered the call."
        case .busy: "The other line was busy."
        case .declined: "The other side declined the call."
        case .noSuchNumber: "The phone number couldn't be reached because it doesn't exist."
        case .couldNotConnect(let reason):
            if reason.hasPrefix("the ") { reason.prefix(1).uppercased() + reason.dropFirst() + "." }
            else { "The call couldn't connect because of \(reason)." }
        case .unknown: "The call ended before its outcome could be confirmed."
        case nil: "Checking how the call ended."
        }
    }

    static func whatHappened(_ call: PhoneCallRecord) -> String {
        let answers = call.asked.compactMap { $0.answer.map { "“\($0)”" } }
        let fallback = reason(call) + (answers.isEmpty ? "" : " You answered " + answers.joined(separator: ", ") + ".")
        return call.summary ?? fallback
    }

    static func pickup(_ call: PhoneCallRecord) -> String? {
        guard call.outcome == .voicemail, let ring = call.ringSeconds else { return nil }
        let seconds = max(1, Int(ring.rounded()))
        return "picked up in \(seconds) second\(seconds == 1 ? "" : "s")"
    }

    static func facts(_ call: PhoneCallRecord, sendsResults: Bool) -> [Fact] {
        var facts: [Fact] = []
        if call.outcome == .voicemail {
            if let seconds = call.duration { facts.append(Fact("Duration", duration(seconds))) }
            facts.append(Fact("Message left", call.messageLeft ? "Yes" : "No"))
        }
        let initiated = call.events.first { $0.name == "call.initiated" }?.occurredAt
        let unansweredRing = call.outcome == .noAnswer ? initiated.flatMap { start in
            call.endedAt.map { $0.timeIntervalSince(start) }
        } : nil
        if let ring = call.ringSeconds ?? unansweredRing {
            facts.append(Fact("Rang for", duration(Int(ring.rounded()))))
        }
        facts.append(Fact("Recording", call.recorded ? "On" : "Off"))
        let delivery: String
        switch call.result {
        case .sent: delivery = "Yes"
        case .pending: delivery = "Waiting for the chat to open"
        case .off: delivery = "Off"
        case .none: delivery = sendsResults ? "Waiting to send" : "Off"
        }
        facts.append(Fact("Sent to chat", delivery))
        return facts
    }

    static func actions(_ call: PhoneCallRecord) -> [Action] {
        if call.outcome == .voicemail && call.voicemailChoice == .hangUp { return [.again, .leave] }
        return [.again, .transcript, .share]
    }

    static func speaker(_ line: PhoneTranscript.Line) -> String {
        speaker(line, botName: nil, calleeName: nil, callingOwner: false)
    }

    static func speaker(_ line: PhoneTranscript.Line, botName: String?, calleeName: String?, callingOwner: Bool) -> String {
        switch line.speaker {
        case .assistant:
            let named = botName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return named.isEmpty ? "Assistant" : named
        case .them:
            if callingOwner { return "You (phone)" }
            let named = calleeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return named.isEmpty ? "Them" : named
        case .you:
            return line.isAnswer == true ? "You answered" : "You told it"
        }
    }

    static func share(_ call: PhoneCallRecord, redacting key: String?) -> String {
        let outcome = title(call.outcome, duration: call.duration)
        let who = [call.name, phoneShown(call.to)].compactMap { $0 }.joined(separator: " · ")
        let questions = call.asked.map { "\($0.question) → \($0.answer ?? "Unanswered")" }
        let transcript = call.shownLines.map { "\(speaker($0)): \($0.text)" }
        let text = ([outcome, who, "", "Goal", call.purpose, "", "What happened", whatHappened(call)]
            + (questions.isEmpty ? [] : ["", "You were asked"] + questions)
            + ["", "Transcript"] + transcript).joined(separator: "\n")
        guard let key, !key.isEmpty else { return text }
        return text.replacingOccurrences(of: key, with: "•••")
    }

    static func followsNewest(distanceFromBottom: CGFloat) -> Bool { distanceFromBottom <= 32 }
}
