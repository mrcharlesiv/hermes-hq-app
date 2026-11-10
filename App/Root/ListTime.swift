// How the lists say when (spec 02 §6.3, the web's `src/list-time.ts`): "9:05 AM" today, "Yesterday", a weekday
// within the week ("Mon"), else "Aug 7" ("Aug 7, 2025" in another year). A time a little ahead reads as today's.
// The web formats with a fixed 'en-US' locale, so this does too by default.

import Foundation

nonisolated enum ListTime {
    private static let defaultLocale = Locale(identifier: "en_US")

    // Built formatters are reused (building one costs far more than formatting with it). DateFormatter formats
    // safely from any thread; the cache itself is behind a lock.
    private nonisolated(unsafe) static var formatters: [String: DateFormatter] = [:]
    private static let lock = NSLock()

    static func formatter(_ format: String, calendar: Calendar, locale: Locale? = nil) -> DateFormatter {
        let locale = locale ?? defaultLocale
        let key = "\(format)|\(calendar.identifier)|\(calendar.timeZone.identifier)|\(locale.identifier)"
        lock.lock(); defer { lock.unlock() }
        if let hit = formatters[key] { return hit }
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = format
        formatters[key] = f
        return f
    }

    /// Calendar days from `now` to `date` (0 today, −1 yesterday, 1 tomorrow).
    static func days(from now: Date, to date: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }

    static func string(_ date: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale? = nil) -> String {
        guard let date, date.timeIntervalSince1970 > 0 else { return "" }
        let d = days(from: now, to: date, calendar: calendar)
        if d >= 0 {
            return d == 0 ? formatter("h:mm a", calendar: calendar, locale: locale).string(from: date)
                : dayMonth(date, now: now, calendar: calendar, locale: locale)
        }
        if d == -1 { return "Yesterday" }
        if d > -7 { return formatter("EEE", calendar: calendar, locale: locale).string(from: date) }
        return dayMonth(date, now: now, calendar: calendar, locale: locale)
    }

    /// Seconds-since-epoch convenience (0 → "").
    static func string(seconds: Double, now: Date = Date(), calendar: Calendar = .current, locale: Locale? = nil) -> String {
        seconds > 0 ? string(Date(timeIntervalSince1970: seconds), now: now, calendar: calendar, locale: locale) : ""
    }

    private static func dayMonth(_ date: Date, now: Date, calendar: Calendar, locale: Locale?) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return formatter(sameYear ? "MMM d" : "MMM d, y", calendar: calendar, locale: locale).string(from: date)
    }
}
