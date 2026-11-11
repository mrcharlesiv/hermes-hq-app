// [botdm] One bot messaging another from its Bot Chat (owner, 2026-10-27: it read as plumbing). Hermes's
// `message_agent` tool (`tools/bot_mode_dm.py`) hands the message to a background runner; when the runner ends, the
// sender's chat gets "[IMPORTANT: Background process proc_… completed …] Command: …/bot_mode_dm.py --run-delivery …
// Output: {"reply": …, "status": "settled"}" on the user role. That note draws as the other bot speaking ("Hermes:
// <its reply>", its face), nothing when it holds no reply, and a plain line when the message didn't get through. The
// call itself draws as "To Hermes: <the message>" (ChatRowBuilder, `BotDMRows`).

import Foundation

nonisolated enum BotDMs {
    /// What the runner reported.
    enum Outcome: Equatable {
        case replied(String)
        /// Delivered (or queued for a live chat) with no reply to show.
        case delivered
        case noReply
        case failed(String)
    }

    /// The tool a bot messages another bot with.
    static let tool = "message_agent"

    /// A background-process note's words are a bot DM's runner finishing.
    static func isDelivery(_ words: String) -> Bool {
        words.contains("bot_mode_dm.py") && words.contains("--run-delivery")
    }

    /// Who the message went to, as written in the runner's command: `peer dm <target>`, else the `-p <profile>` after
    /// the hermes program (the sender's own `-p` comes first on a peer DM, so the peer form is read first).
    static func target(_ words: String) -> String? {
        guard let command = words.split(separator: "\n").first(where: { $0.hasPrefix("Command:") }).map(String.init) else { return nil }
        if let peer = peerTarget.groups(command)?[1] { return peer }
        return profileFlag.groups(command)?[1]
    }

    /// Hermes's placeholder when a turn ends without words ("⚠️ Processing completed but no response was generated…").
    static let emptyTurn = "Processing completed but no response was generated"
    private static let peerTarget = TRx(#"\bpeer\s+dm\s+'?([^\s']+)"#)
    private static let profileFlag = TRx(#"/hermes\s+-p\s+'?([^\s']+)'?\s*$"#)
    private static let replyFrom = TRx(#"(?m)^Reply from [^\n]*:\n([\s\S]+)$"#)
    private static let failedLine = TRx(#"(?m)^Delivery to [^\n]* failed[^:\n]*: *([^\n]*)"#)

    /// The runner's verdict from its output: its JSON line (`reply`, `error`), or the older printed lines.
    static func outcome(_ words: String) -> Outcome {
        guard let range = words.range(of: "\nOutput:") else { return .delivered }
        // The note closes with a "]" line, then the gateway's own footer: the output ends before them.
        var tail = words[range.upperBound...]
        if let close = tail.range(of: "\n]") { tail = tail[..<close.lowerBound] }
        let output = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = output.firstIndex(of: "{"), let close = output.lastIndex(of: "}"), open < close,
           let json = ChatJSON.parse(string: String(output[open...close]))?.object {
            if let reply = json["reply"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty {
                // Hermes's stand-in for a turn that wrote nothing is no reply, not words from the other bot; so is the
                // other bot choosing to say nothing ("[Notification processed; no additional user-facing response.]").
                // [exchange] Drawn, it read as one more message between the bots, after the answer to you.
                return reply.contains(emptyTurn) || Hydration.isSilentWords(reply) ? .delivered : .replied(reply)
            }
            if let error = json["error"]?.string, !error.isEmpty { return .failed(error) }
            if json["reason"]?.string != nil { return .failed(json["reason"]?.string ?? "") }
            return .delivered
        }
        if let reply = replyFrom.groups(output)?[1]?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty,
           reply != "(empty reply)" {
            return .replied(reply)
        }
        if let reason = failedLine.groups(output)?[1] { return .failed(reason) }
        if output.hasPrefix("No reply from ") { return .noReply }
        return .delivered
    }

    /// [exchange] The words open by speaking to one of these bots by name: "Thanks, Otto.", "Otto, your diagnosis…",
    /// "@otto: confirmed", "Got it, Home —". Only the first sentence counts, and the name must be set off as an address
    /// (a comma, a colon, a dash, a greeting before it): "Otto found the cause" and "Thanks to Otto, it works" are about
    /// the bot, not to it.
    static func speaksTo(_ names: [String], in text: String) -> Bool {
        var opening = String(text.drop(while: { $0.isWhitespace || "*_#>`".contains($0) }).prefix(160))
        if let line = opening.firstIndex(where: \.isNewline) { opening = String(opening[..<line]) }
        if let stop = opening.range(of: #"[.!?](\s|$)"#, options: .regularExpression) { opening = String(opening[..<stop.lowerBound]) }
        opening = opening.replacingOccurrences(of: #"[*_`]"#, with: "", options: .regularExpression)
        for name in Set(names.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).lowercased() }) where name.count > 1 {
            let bot = #"@?"# + NSRegularExpression.escapedPattern(for: name) + #"(?![\w-])"#
            let patterns = [
                #"^"# + bot + #"\s*([,:—–]|-\s|$)"#,
                #"^@"# + NSRegularExpression.escapedPattern(for: name) + #"(?![\w-])"#,
                #",\s*"# + bot + #"\s*([,:—–]|-\s|$)"#,
                #"^(hi|hey|hello|thanks|thank you|understood|got it|noted|ok|okay|confirmed|acknowledged|agreed|received|copy that|roger)[,\s]+"# + bot + #"\s*([,:—–]|-\s|$)"#,
            ]
            if patterns.contains(where: { opening.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }) { return true }
        }
        return false
    }

    /// The bot a target names, as the incoming deliveries find it (handle, then name, then `hermes` → default).
    static func sender(_ target: String, roster: [DeliveryMessages.Seat]) -> ChatSender {
        let bare = target.split(separator: "/").last.map(String.init) ?? target
        let handle = bare.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).lowercased()
        let found = roster.first { $0.profile.lowercased() == handle }
            ?? roster.first { RosterRules.handle(forProfile: $0.profile) == handle }
            ?? roster.first { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == handle }
            ?? (handle == "hermes" ? roster.first { $0.profile == "default" } : nil)
        if let found {
            return ChatSender(key: "delivery:" + found.profile, name: found.name, head: found.head, profile: found.profile,
                              colorHex: ChatSenderColors.hex(head: found.head, profile: found.profile))
        }
        return ChatSender(key: "delivery:?" + handle, name: bare, head: nil, profile: "default", colorHex: nil)
    }

    /// `messages` with each bot DM runner's note turned into the other bot's reply (a delivery from it), hidden when
    /// there is none to show, or a line when it failed. Runs before `TimelineNotes.resolve`, which would otherwise make
    /// it "Background task finished: python3". The same array comes back when there is none.
    static func resolve(_ messages: [ChatMessage], roster: [DeliveryMessages.Seat]) -> (messages: [ChatMessage], found: Bool) {
        var out: [ChatMessage]?
        for index in messages.indices {
            let m = messages[index]
            guard m.role == .user, m.sender == nil, m.parts.count == 1, case .text(let text) = m.parts[0],
                  text.hasPrefix("[IMPORTANT:"), let words = CronDeliveries.processNote(text), isDelivery(words) else { continue }
            if out == nil { out = messages }
            let who = target(words).map { sender($0, roster: roster) }
            switch outcome(words) {
            case .replied(let reply):
                out![index].sender = who ?? sender("hermes", roster: roster)
                out![index].parts = [.text(reply)]
            case .delivered:
                out![index].role = .system
                out![index].parts = [.text("")]
            case .noReply:
                out![index].role = .system
                out![index].parts = [.text(who.map { "No reply from \($0.name) yet" } ?? "No reply yet")]
            case .failed(let reason):
                out![index].role = .system
                let name = who?.name ?? "the other bot"
                let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                out![index].parts = [.text("Couldn’t reach \(name)" + (why.isEmpty ? "" : ": " + ChatText.clip(why, max: 200)))]
            }
        }
        return (out ?? messages, out != nil)
    }
}
