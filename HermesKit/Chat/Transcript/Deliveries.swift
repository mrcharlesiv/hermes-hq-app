// [transcript] Cron deliveries (docs/spec/3x-transcript.md §2.1, row L302): a scheduled job's output mirrored into
// its chat arrives wrapped ("[Cron delivery: <job>]", "Cronjob Response: <job>", '[Cronjob "<job>" output …]'). The
// wrapper goes, the job's bot speaks (the roster bot the job's name starts with, else the chat's own), the job is
// named on the byline. Ported from `S/ui-chat/run.ts` (cronDelivery) and `S/ui-chat/chat-identity.ts` (cronJobBot).

import Foundation

/// A tiny wrapper so the ports read like the web's regular expressions.
nonisolated struct TRx: @unchecked Sendable {
    let re: NSRegularExpression

    init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        // Patterns are literals in this folder; a bad one is a programming error caught by the unit tests.
        re = (try? NSRegularExpression(pattern: pattern, options: options)) ?? NSRegularExpression()
    }

    func test(_ text: String) -> Bool {
        re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The groups of the first match (index 0 = the whole match); nil where a group did not take part.
    func groups(_ text: String) -> [String?]? {
        guard let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } }
    }

    func firstRange(_ text: String) -> Range<String.Index>? {
        guard let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return Range(m.range, in: text)
    }

    func replace(_ text: String, with template: String) -> String {
        re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    func allMatches(_ text: String) -> [String] {
        re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}

nonisolated enum CronDeliveries {
    struct Parsed: Hashable, Sendable {
        var job: String
        var body: String
    }

    private static let cron = TRx(#"^(?:\[Cron delivery: ([^\]\n]{1,160})\]|Cronjob Response: ([^\n]{1,160})|\[Cronjob "([^"\n]{1,160})" output\b[^\]\n]*\])[ \t]*(?:\n|$)"#)
    private static let jobId = TRx(#"^\(job_id: [^)\n]*\)[ \t]*\n"#)
    private static let rule = TRx(#"^-{3,}[ \t]*\n"#)
    private static let footer = TRx(#"\n+(?:To stop or manage this job, send me a new message[^\n]*|Note: The agent cannot see this message[^\n]*)\s*$"#)
    private static let importantNote = TRx(#"^\[IMPORTANT:\s*([\s\S]*?)\]?\s*$"#)

    /// A cron card's name line: "<bot> · <job>", the bot named once. A job titled after its bot ("Ivy morning brief")
    /// drops that leading name ("Ivy · Morning brief"); a job that is only the bot's name leaves the name alone.
    static func header(sender: String, job: String) -> String {
        let name = sender.trimmingCharacters(in: .whitespaces)
        var rest = job.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, rest.count > name.count,
           rest.prefix(name.count).compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            let after = rest.dropFirst(name.count)
            if let next = after.first, next == " " || next == ":" || next == "-" || next == "–" || next == "—" {
                rest = after.drop { $0 == " " || $0 == ":" || $0 == "-" || $0 == "–" || $0 == "—" }.description
                if let first = rest.first { rest = first.uppercased() + rest.dropFirst() }
            }
        } else if rest.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            rest = ""
        }
        return rest.isEmpty ? name : "\(name) · \(rest)"
    }

    /// A job's name as a chat line says it: the bot's own name off the front and a slug as words
    /// ("northwind-inbox-watch" from Northwind → "Inbox watch"). A job that is only the bot's name stays whole.
    static func jobName(_ job: String, bot: String) -> String {
        let name = bot.trimmingCharacters(in: .whitespaces)
        let whole = job.trimmingCharacters(in: .whitespaces)
        var rest = whole
        if !name.isEmpty, rest.count > name.count,
           rest.prefix(name.count).compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame,
           let next = rest.dropFirst(name.count).first, " :-–—_".contains(next) {
            rest = String(rest.dropFirst(name.count).drop { " :-–—_".contains($0) })
        }
        if rest.isEmpty { rest = whole }
        let words = RosterPreview.humanJobTitle(rest)
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// The report without a first line that only restates the job ("Northwind inbox watch: 1 new inbound email" for
    /// northwind-inbox-watch → "1 new inbound email"): letters and digits compared, case and punctuation ignored.
    static func withoutJobLead(_ body: String, job: String) -> String {
        let squash = { (s: Substring) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let key = squash(Substring(job))
        guard !key.isEmpty, let colon = body.firstIndex(of: ":"),
              !body[..<colon].contains("\n"), squash(body[..<colon]) == key else { return body }
        let rest = body[body.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? body : rest
    }

    /// Cheap test before the regular expression.
    static func mayBeCron(_ text: String) -> Bool {
        let head = text.drop { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }
        return head.hasPrefix("[Cron delivery: ") || head.hasPrefix("Cronjob Response: ") || head.hasPrefix("[Cronjob \"")
    }

    /// A cron delivery's job name and its text without the wrapper, or nil when the message isn't one.
    static func parse(_ text: String) -> Parsed? {
        guard mayBeCron(text) else { return nil }
        let start = String(text.drop { $0.isWhitespace })
        guard let groups = cron.groups(start), let whole = groups[0] else { return nil }
        var body = String(start.dropFirst(whole.count))
        // The wrapper's own lines: "(job_id: …)" and the rule under it. (A body that is only a footer has nothing left
        // before it, so the footer is tried with a leading newline added.)
        body = jobId.replace(body, with: "")
        body = rule.replace(body, with: "")
        body = footer.replace("\n" + body, with: "")
        let job = (groups[1] ?? groups[2] ?? groups[3] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !job.isEmpty else { return nil }
        return Parsed(job: job, body: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static let cronHead = TRx(#"^\s*(?:\[Cron delivery: ([^\]\n]{1,160})(\])?|Cronjob Response: ([^\n]{1,160})|\[Cronjob "([^"\n]{1,160})"(?: output\b[^\]\n]*(\]))?)"#)
    private static let previewLead = TRx(#"^\s*(?:\(job_id: [^)\n]*\)\s*)?(?:-{3,}\s*)?"#)

    /// A list preview's cron run: the job's name and the report's words, nil words when there are none. The gateway
    /// cuts previews at 80 characters (often inside the wrapper, which then has no closing bracket) and may put the
    /// report on the wrapper's line.
    static func preview(_ text: String) -> (job: String, body: String?)? {
        if let parsed = parse(text) { return (parsed.job, parsed.body.isEmpty ? nil : parsed.body) }
        guard mayBeCron(text), let groups = cronHead.groups(text), let whole = groups[0] else { return nil }
        let job = (groups[1] ?? groups[3] ?? groups[4] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !job.isEmpty else { return nil }
        guard groups[2] != nil || groups[3] != nil || groups[5] != nil else { return (job, nil) }
        let body = previewLead.replace(String(text.dropFirst(whole.count)), with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (job, body.isEmpty ? nil : body)
    }

    /// The roster bot a cron job's name starts with ("Scout morning brief" → Scout), longest name first.
    static func bot(job: String, roster: [DeliveryMessages.Seat]) -> DeliveryMessages.Seat? {
        let text = job.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var best: (seat: DeliveryMessages.Seat, length: Int)?
        let separators: Set<Character> = [" ", "\t", ":", "·", "–", "—", "-"]
        for seat in roster {
            for label in [seat.name, seat.profile, seat.profile == "default" ? "Hermes" : ""] {
                let value = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !value.isEmpty, text.hasPrefix(value) else { continue }
                let next = text.dropFirst(value.count).first
                guard next == nil || separators.contains(next!) else { continue }
                if value.count > (best?.length ?? 0) { best = (seat, value.count) }
            }
        }
        return best?.seat
    }

    static func sender(job: String, roster: [DeliveryMessages.Seat], own: DeliveryMessages.Seat) -> ChatSender {
        let seat = bot(job: job, roster: roster) ?? own
        return ChatSender(key: "cron:" + seat.profile, name: seat.name, head: seat.head, profile: seat.profile,
                          colorHex: ChatSenderColors.hex(head: seat.head, profile: seat.profile))
    }

    /// The text inside an "[IMPORTANT: …]" process note, or nil.
    static func processNote(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[IMPORTANT:"), let groups = importantNote.groups(trimmed), let inside = groups[1] else { return nil }
        let words = inside.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : words
    }

    /// `messages` with every cron delivery turned into its bot's message: the wrapper removed, the sender and job set.
    /// A wrapper around a silent body becomes the silent note, named by its job. Never touches a message that already
    /// has a sender (a delivery from another bot, a room member). The same array comes back when there is none.
    static func resolve(_ messages: [ChatMessage], roster: [DeliveryMessages.Seat], own: DeliveryMessages.Seat)
        -> (messages: [ChatMessage], found: Bool) {
        var out: [ChatMessage]?
        for index in messages.indices {
            let message = messages[index]
            guard message.role != .system, message.sender == nil, !message.isStreaming,
                  case .text(let text)? = message.parts.first, mayBeCron(text), let parsed = parse(text) else { continue }
            // An assistant turn that did more than speak (tool calls) is the bot's own reply, not a mirrored delivery.
            if message.role == .assistant, message.parts.count > 1 { continue }
            if out == nil { out = messages }
            if parsed.body == "[SILENT]" {
                out![index].role = .system
                out![index].parts = [.text("\(parsed.job): \(Hydration.silentRunText)")]
                continue
            }
            out![index].role = .user
            out![index].sender = sender(job: parsed.job, roster: roster, own: own)
            out![index].job = parsed.job
            out![index].parts[0] = .text(parsed.body)
        }
        return (out ?? messages, out != nil)
    }
}
