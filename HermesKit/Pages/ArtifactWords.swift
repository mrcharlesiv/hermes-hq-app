// The Artifacts page's words (docs/spec/1x-pages.md §5.5, §5.7): day headers and row subtitles
// (`S/ui-pages/artifact-list.tsx:22-63`) and the empty texts (`S/fe-pages-r6.ts:63-76`).

import Foundation

nonisolated enum ArtifactListWords {
    private static func daysAgo(_ date: Date, _ now: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
    }

    /// "Today", "Yesterday", the weekday within the week, else "September 10" ("September 10, 2025").
    static func day(_ timestamp: Double, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard timestamp.isFinite else { return "Earlier" }
        let date = Date(timeIntervalSince1970: timestamp / 1000)
        let days = daysAgo(date, now, calendar: calendar)
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days < 7 { return JobWords.days[JobWords.weekdayIndex(date, calendar: calendar)] }
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let base = "\(JobWords.months[(c.month ?? 1) - 1]) \(c.day ?? 1)"
        return JobWords.sameYear(date, now, calendar: calendar) ? base : "\(base), \(c.year ?? 0)"
    }

    private static let runStamp = RX(#" · (?:[A-Z][a-z]{2,8},? )?[A-Z][a-z]{2} \d{1,2}(?:, \d{4})?,? \d{1,2}:\d{2}(?:\s?[AP]M)?$"#)

    /// "Hermes Projects · 6:02 AM": where it came from and when (a run title's own stamp removed).
    static func subtitle(sessionTitle: String, timestamp: Double, now: Date = Date(), calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: timestamp / 1000)
        let when = daysAgo(date, now, calendar: calendar) < 7 ? JobWords.clock(date, calendar: calendar)
            : ListTime.string(date, now: now, calendar: calendar)
        let title = runStamp.replace(sessionTitle.pgTrim, with: "", all: false)
        return [title, when].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Rows grouped by day, in the order given (newest first).
    static func days(_ items: [ArtifactRecord], now: Date = Date(), calendar: Calendar = .current) -> [(day: String, items: [ArtifactRecord])] {
        KanbanModel.groupBy(items) { day($0.timestamp, now: now, calendar: calendar) }.map { ($0.heading, $0.items) }
    }

    /// What an empty list says (it looked only at recent chats).
    static func empty(filter: ArtifactRecord.Kind?, bot: String?, query: String) -> (title: String, description: String) {
        let words = query.pgTrim
        let kind: String
        switch filter {
        case .image: kind = "images"
        case .file: kind = "files"
        case .link: kind = "links"
        case nil: kind = "artifacts"
        }
        let Kind = kind.prefix(1).uppercased() + kind.dropFirst()
        if !words.isEmpty {
            return ("No Results for “\(words)”", filter != nil ? "No \(kind) match. Try All, or another word." : "Check the spelling, or try another word.")
        }
        let what: String
        switch filter {
        case .image: what = "Images your bots make or share"
        case .file: what = "Files your bots create or send"
        case .link: what = "Links from your chats"
        case nil: what = "Images, files and links from your chats"
        }
        if let bot {
            return ("No \(Kind) in \(bot)’s Recent Chats", "\(what) appear here. Artifacts looks through \(bot)’s 50 most recent chats.")
        }
        return ("No \(Kind) in Recent Chats", "\(what) appear here. Artifacts looks through the 50 most recent chats of each bot.")
    }
}
