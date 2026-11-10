// A chat and its messages as text (spec 1x §4.4, §9.2): the transcript for ⋯ › Share (`transcriptText`,
// S:fe-convo-r1.ts:347-357), Copy's Markdown (`messageText`, S:ui-chat/run.ts:55-61), Share and Select Text's readable
// text (`readableText`, S:ui-chat/message-actions.ts:11-21), the hold menu's title (`messageMenuTitle`,
// S:ui-chat/message-menu.ts:40-44), and the whole-chat read (`getAllSessionMessages`, V:api/sessions.ts:653-700).

import Foundation

nonisolated enum ChatTranscript {
    // MARK: Transcript

    /// The message's text blocks as the web joins them (`joinTextParts`): consecutive text parts run together, a tool
    /// call ends a block, reasoning is skipped; blocks trimmed and joined by a blank line.
    static func blocks(_ message: ChatMessage) -> String {
        var blocks: [String] = []
        var current: String?
        for part in message.parts {
            switch part {
            case .text(let t): current = (current ?? "") + t
            case .reasoning: continue
            case .tool:
                if let c = current { blocks.append(c); current = nil }
            }
        }
        if let current { blocks.append(current) }
        return blocks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static let manyNewlines = try! NSRegularExpression(pattern: #"\n{3,}"#)

    /// The chat as plain text for Messages or Notes: the title, a blank line, then "You:" / "<Bot>:" on its own line
    /// over each message. System notices, slash output and tool rows are left out. `userLine` rewrites your message
    /// (a voice memo's transcript line) when it returns non-nil.
    static func text(title: String?, botName: String, messages: [ChatMessage], userLine: (@Sendable (String) -> String?)? = nil) -> String {
        var lines: [String] = []
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { lines += [title, ""] }
        let bot = botName.trimmingCharacters(in: .whitespacesAndNewlines)
        for message in messages where message.role == .user || message.role == .assistant {
            var text = Rx.replace(manyNewlines, in: blocks(message), with: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if message.role == .user, let line = userLine?(text) { text = line }
            if message.role == .assistant { text = ReasoningTags.strip(text).trimmingCharacters(in: .whitespacesAndNewlines) }   // hidden thinking
            guard !text.isEmpty else { continue }
            lines += [message.role == .user ? "You:" : "\(bot.isEmpty ? "Hermes" : bot):", text, ""]
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: Copy and readable text

    /// What Copy puts on the pasteboard: the message's text parts joined by a line break, as Markdown.
    static func messageText(_ message: ChatMessage) -> String {
        message.parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: "\n")
    }

    private static let fence = try! NSRegularExpression(pattern: #"^\s*(```|~~~)"#)
    private static let listMarker = try! NSRegularExpression(pattern: #"^(\s*)[-*+]\s+(\[[ xX]\]\s+)?"#)
    private static let heading = try! NSRegularExpression(pattern: #"^\s*#{1,6}\s+"#)
    private static let quote = try! NSRegularExpression(pattern: #"^\s*>\s?"#)
    private static let image = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\([^)]*\)"#)
    private static let link = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)\s]+)[^)]*\)"#)
    private static let strong = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let starEm = try! NSRegularExpression(pattern: #"(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])"#)
    private static let underscoreEm = try! NSRegularExpression(pattern: #"(?<![\w])_(?=\S)([^_\n]+?)(?<=\S)_(?![\w])"#)
    private static let strike = try! NSRegularExpression(pattern: #"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let inlineCode = try! NSRegularExpression(pattern: "`([^`\\n]+)`")

    /// A reply as it reads on screen, for Share and Select Text: no `**`, `_` or backtick markers, "•" bullets, a
    /// heading's words, a link's words then its address; code blocks keep their text, only the fences go.
    static func readableText(_ markdown: String) -> String { readableText(markdown, linkAddresses: true) }

    /// `linkAddresses: false`: a link reads as its words alone, as the bubble draws it (Find searches what is drawn).
    static func readableText(_ markdown: String, linkAddresses: Bool) -> String {
        var fenced = false
        var out: [String] = []
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if Rx.matches(fence, raw) { fenced.toggle(); continue }
            if fenced { out.append(raw); continue }
            var line = Rx.replace(listMarker, in: raw, with: "$1• ")
            line = Rx.replace(heading, in: line, with: "")
            line = Rx.replace(quote, in: line, with: "")
            line = Rx.replace(image, in: line, with: "$1")
            line = Rx.replace(link, in: line) { _, groups in
                groups[1] == groups[2] || !linkAddresses ? groups[1] : "\(groups[1]) (\(groups[2]))"
            }
            line = Rx.replace(strong, in: line, with: "$2")
            line = Rx.replace(starEm, in: line, with: "$1")
            line = Rx.replace(underscoreEm, in: line, with: "$1")
            line = Rx.replace(strike, in: line, with: "$1")
            line = Rx.replace(inlineCode, in: line, with: "$1")
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    // MARK: Hold menu title

    /// "9:14 AM" today, "Yesterday 9:14 PM", "Sep 26, 9:14 PM" (the year added when it isn't this year) (`messageWhen`).
    static func when(_ date: Date?, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        guard let date else { return "" }
        let clock = DateFormatter()
        clock.locale = locale
        clock.calendar = calendar
        clock.timeZone = calendar.timeZone
        clock.setLocalizedDateFormatFromTemplate("jmm")
        let time = clock.string(from: date)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 0 { return time }
        if days == 1 { return "Yesterday \(time)" }
        let day = DateFormatter()
        day.locale = locale
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.setLocalizedDateFormatFromTemplate(calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "MMMd" : "yMMMd")
        return "\(day.string(from: date)), \(time)"
    }

    /// "<sender> · <when>" (`messageMenuTitle`); the sender alone without a time.
    static func menuTitle(sender: String, date: Date?, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent,
                          locale: Locale = .autoupdatingCurrent) -> String {
        [sender, when(date, now: now, calendar: calendar, locale: locale)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: Whole chat (spec 1x §3.9)

    static let pageLimit = 500
    /// The web stops when the JSON passes this many characters (`getAllSessionMessages`).
    static let characterCap = 32_000_000
    static let tooLong = "This chat is too long to share from \(DeviceWord.subject)."

    /// Every stored row, oldest first: `order=oldest&limit=500&offset=n` until a page is short, has no pagination, or
    /// is empty; an error past 32,000,000 characters. Folded like history (spec 03 §6).
    @concurrent
    static func fetchAll(client: any GatewayClient, storedSessionId: String, profile: String?) async throws -> [ChatMessage] {
        Hydration.fold(try await fetchAllRows(client: client, storedSessionId: storedSessionId, profile: profile)).messages
    }

    /// Every stored row as the gateway sent it, oldest first (Export JSON writes them as they are).
    @concurrent
    static func fetchAllRows(client: any GatewayClient, storedSessionId: String, profile: String?) async throws -> [JSONValue] {
        var rows: [JSONValue] = []
        var offset = 0
        var characters = 0
        while true {
            try Task.checkCancellation()
            let request = HistoryRequest(storedSessionId: storedSessionId, profile: profile, limit: pageLimit, offset: offset, order: "oldest")
            let path = request.core().path
            // The web's query, offset 0 included (`getAllSessionMessages`).
            var query: [URLQueryItem] = []
            if let profile { query.append(URLQueryItem(name: "profile", value: profile)) }
            query += [URLQueryItem(name: "limit", value: String(pageLimit)), URLQueryItem(name: "offset", value: String(offset)),
                      URLQueryItem(name: "order", value: "oldest"), URLQueryItem(name: "include_compacted", value: "true")]
            let data = try await client.rest("GET", path, query: query, body: nil)
            characters += data.count
            if characters > characterCap { throw MenusError(tooLong) }
            let page = try HistoryAPI.decodePage(data, request: request)
            rows += page.rows
            if page.rows.isEmpty || page.pagination == nil || page.rows.count < pageLimit { break }
            offset += page.rows.count
        }
        return rows
    }

    /// `text(...)` off the main actor.
    @concurrent
    static func formatText(title: String?, botName: String, messages: [ChatMessage],
                           userLine: (@Sendable (String) -> String?)?) async -> String {
        text(title: title, botName: botName, messages: messages, userLine: userLine)
    }

    /// Every page (`fetchAll`), folded and formatted as the shared transcript, all off the main actor.
    @concurrent
    static func fetchAllText(client: any GatewayClient, storedSessionId: String, profile: String?, title: String?,
                             botName: String, userLine: (@Sendable (String) -> String?)?) async throws -> String {
        let messages = try await fetchAll(client: client, storedSessionId: storedSessionId, profile: profile)
        try Task.checkCancellation()
        return text(title: title, botName: botName, messages: messages, userLine: userLine)
    }
}
