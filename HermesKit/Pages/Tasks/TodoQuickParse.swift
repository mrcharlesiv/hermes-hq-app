// [tasks-first] Step 4 (owner 2026-11-12, mockup 5-new-task: "Type one line; the date is read from your words"): what
// New Task reads from the line as you type it. "Plan the team offsite friday 9am" is the task "Plan the team offsite",
// due Friday at 9:00. It reads a day (today, tomorrow, a weekday, "next week", "in 3 days", "nov 20", "11/20"), a time
// ("9am", "9:30 pm", "at 5", "17:00", "noon"), how it repeats ("every day", "weekly", "every monday"), "#tags" and a
// priority ("!high", "p1"). What it read leaves the task's name. Nothing here guesses: a month needs its day ("may 3",
// not "may"), and "sun" alone is not Sunday ("buy sun cream").

import Foundation

nonisolated struct TodoQuickRead: Equatable, Sendable {
    /// The task's name: the line without the words that were read.
    var title = ""
    /// The day it's due (its moment when `hasTime`).
    var due: Date?
    var hasTime = false
    var repeatRule: String?
    var tags: [String] = []
    /// 1 high, 2 medium, 3 low.
    var priority: Int?
    /// The date words as typed ("friday 9am"), for the line that says what was read.
    var dateWords: String?
}

nonisolated enum TodoQuickParse {
    private static let weekdays: [String: Int] = [
        "sunday": 1, "monday": 2, "mon": 2, "tuesday": 3, "tue": 3, "tues": 3, "wednesday": 4, "wed": 4, "weds": 4,
        "thursday": 5, "thu": 5, "thur": 5, "thurs": 5, "friday": 6, "fri": 6, "saturday": 7, "sat": 7,
    ]
    private static let months: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3, "april": 4, "apr": 4, "may": 5, "june": 6,
        "jun": 6, "july": 7, "jul": 7, "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9, "october": 10, "oct": 10,
        "november": 11, "nov": 11, "december": 12, "dec": 12,
    ]
    private static let counts: [String: Int] = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6]

    /// `dates: false` leaves every date word in the name (the date was picked by hand).
    static func read(_ text: String, now: Date, calendar: Calendar = .current, dates: Bool = true) -> TodoQuickRead {
        let raw = text.split(whereSeparator: { $0 == " " || $0.isNewline }).map(String.init)
        // A word as it is matched: lower case, without the comma or full stop after it.
        let words = raw.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.;")) }
        var used = Set<Int>()
        var dateUsed = Set<Int>()
        var out = TodoQuickRead()
        let today = calendar.startOfDay(for: now)
        var day: Date?
        var clock: (hour: Int, minute: Int)?

        func take(_ range: ClosedRange<Int>, date: Bool = true) {
            for i in range { used.insert(i); if date { dateUsed.insert(i) } }
        }
        func coming(_ weekday: Int, includingToday: Bool = false) -> Date {
            let current = calendar.component(.weekday, from: today)
            var ahead = (weekday - current + 7) % 7
            if ahead == 0, !includingToday { ahead = 7 }
            return calendar.date(byAdding: .day, value: ahead, to: today) ?? today
        }
        func dayNumber(_ word: String) -> Int? {
            var digits = word
            for suffix in ["st", "nd", "rd", "th"] where digits.hasSuffix(suffix) && digits.count > suffix.count { digits.removeLast(2); break }
            guard let n = Int(digits), (1...31).contains(n), digits.allSatisfy(\.isNumber) else { return nil }
            return n
        }
        func monthDay(_ month: Int, _ dayOfMonth: Int, year: Int? = nil) -> Date? {
            var parts = DateComponents(year: year ?? calendar.component(.year, from: today), month: month, day: dayOfMonth)
            guard var date = calendar.date(from: parts), calendar.component(.month, from: date) == month else { return nil }
            if year == nil, date < today { parts.year = (parts.year ?? 0) + 1; date = calendar.date(from: parts) ?? date }
            return date
        }
        /// "9am", "9:30pm", "17:00"; with `bare`, "5" and "5:30" too (after "at").
        func time(_ word: String, bare: Bool = false) -> (hour: Int, minute: Int)? {
            var body = word
            var half: String?
            for mark in ["am", "pm", "a", "p"] where body.hasSuffix(mark) && body.count > mark.count && body.dropLast(mark.count).last?.isNumber == true {
                half = String(mark.prefix(1)); body.removeLast(mark.count); break
            }
            let pieces = body.split(separator: ":", omittingEmptySubsequences: false)
            guard (1...2).contains(pieces.count), let hour = Int(pieces[0]), pieces[0].allSatisfy(\.isNumber) else { return nil }
            var minute = 0
            if pieces.count == 2 {
                guard pieces[1].count == 2, let m = Int(pieces[1]), (0..<60).contains(m) else { return nil }
                minute = m
            }
            if let half {
                guard (1...12).contains(hour) else { return nil }
                return ((hour % 12) + (half == "p" ? 12 : 0), minute)
            }
            if pieces.count == 2, (0...23).contains(hour), !bare || hour > 12 || hour == 0 { return (hour, minute) }
            guard bare, (1...12).contains(hour) else { return nil }
            // "at 5" is the afternoon; "at 9" the morning; "at 12" noon.
            return (hour == 12 ? 12 : (hour <= 7 ? hour + 12 : hour), minute)
        }

        var i = 0
        while i < words.count {
            let word = words[i]
            let next = i + 1 < words.count ? words[i + 1] : nil
            let after = i + 2 < words.count ? words[i + 2] : nil
            defer { i += 1 }
            guard !used.contains(i) else { continue }

            // Tags and priority: no date in them, read whatever `dates` says.
            if word.hasPrefix("#"), word.count > 1 {
                let tag = String(raw[i].dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: ",.;")).prefix(30))
                if !tag.isEmpty, !out.tags.contains(where: { $0.lowercased() == tag.lowercased() }) { out.tags.append(tag) }
                take(i...i, date: false); continue
            }
            if let level = ["!high": 1, "!1": 1, "p1": 1, "!medium": 2, "!med": 2, "!2": 2, "p2": 2, "!low": 3, "!3": 3, "p3": 3][word] {
                out.priority = level; take(i...i, date: false); continue
            }
            guard dates else { continue }

            // How it repeats.
            if word == "every", let next {
                if let weekday = weekdays[next] ?? (next == "sun" ? 1 : nil) {
                    out.repeatRule = "weekly"; day = day ?? coming(weekday, includingToday: true); take(i...i + 1); continue
                }
                if let rule = ["day": "daily", "weekday": "weekdays", "week": "weekly", "month": "monthly", "year": "yearly"][next] {
                    out.repeatRule = rule; take(i...i + 1); continue
                }
            }
            if let rule = ["daily": "daily", "weekdays": "weekdays", "weekly": "weekly", "monthly": "monthly", "yearly": "yearly",
                           "annually": "yearly"][word] {
                out.repeatRule = rule; take(i...i); continue
            }

            // A day.
            if word == "today" { day = today; take(i...i); continue }
            if word == "tonight" { day = today; clock = clock ?? (20, 0); take(i...i); continue }
            if word == "tomorrow" || word == "tmrw" { day = calendar.date(byAdding: .day, value: 1, to: today); take(i...i); continue }
            if word == "next", let next {
                if next == "week" { day = calendar.date(byAdding: .day, value: 7, to: today); take(i...i + 1); continue }
                if next == "month" { day = calendar.date(byAdding: .month, value: 1, to: today); take(i...i + 1); continue }
                if let weekday = weekdays[next] {
                    day = calendar.date(byAdding: .day, value: 7, to: coming(weekday)); take(i...i + 1); continue
                }
            }
            if word == "in", let next, let after, let count = Int(next) ?? counts[next], (1...366).contains(count) {
                let unit: Calendar.Component? = ["day": .day, "days": .day, "week": .weekOfYear, "weeks": .weekOfYear,
                                                 "month": .month, "months": .month][after]
                if let unit { day = calendar.date(byAdding: unit, value: count, to: today); take(i...i + 2); continue }
            }
            if (word == "on" || word == "this"), let next, let weekday = weekdays[next] { day = coming(weekday); take(i...i + 1); continue }
            if let weekday = weekdays[word] { day = coming(weekday); take(i...i); continue }
            if let month = months[word], let next, let number = dayNumber(next), let date = monthDay(month, number) {
                day = date; take(i...i + 1); continue
            }
            if let number = dayNumber(word), let next, let month = months[next], let date = monthDay(month, number) {
                day = date; take(i...i + 1); continue
            }
            // 11/20, 11/20/26, 11/20/2026 (month first).
            let slash = word.split(separator: "/", omittingEmptySubsequences: false)
            if (2...3).contains(slash.count), slash.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
               let month = Int(slash[0]), (1...12).contains(month), let number = Int(slash[1]), (1...31).contains(number) {
                let year = slash.count == 3 ? Int(slash[2]).map { $0 < 100 ? 2000 + $0 : $0 } : nil
                if let date = monthDay(month, number, year: year) { day = date; take(i...i); continue }
            }

            // A time.
            if word == "noon" { clock = (12, 0); take(i...i); continue }
            if word == "at", let next {
                if next == "noon" { clock = (12, 0); take(i...i + 1); continue }
                if let after, ["am", "pm"].contains(after), let found = time(next + after) { clock = found; take(i...i + 2); continue }
                if let found = time(next, bare: true) { clock = found; take(i...i + 1); continue }
            }
            if let next, ["am", "pm"].contains(next), let found = time(word + next) { clock = found; take(i...i + 1); continue }
            if let found = time(word) { clock = found; take(i...i); continue }
        }

        // A time with no day is today while that time is still ahead, else tomorrow.
        if let clock {
            let base = day ?? today
            var moment = calendar.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: base) ?? base
            if day == nil, moment <= now { moment = calendar.date(byAdding: .day, value: 1, to: moment) ?? moment }
            out.due = moment
            out.hasTime = true
        } else if let day {
            out.due = day
        } else if out.repeatRule != nil {
            out.due = today   // "water the plants every day" starts today
        }
        let kept = raw.indices.filter { !used.contains($0) }.map { raw[$0] }.joined(separator: " ")
        // A line that is nothing but a date ("tomorrow") keeps its words as the name.
        if kept.trimmingCharacters(in: .whitespaces).isEmpty {
            var plain = TodoQuickRead()
            plain.title = raw.joined(separator: " ")
            return plain
        }
        out.title = kept
        if !dateUsed.isEmpty { out.dateWords = dateUsed.sorted().map { raw[$0] }.joined(separator: " ") }
        return out
    }
}
