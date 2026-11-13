// [tasks-first] Step 4: what New Task reads from the line you type ("Plan the team offsite friday 9am").

import Foundation
import Testing
@testable import HermesHQNative

struct TodoQuickParseTests {
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        c.locale = Locale(identifier: "en_US")
        return c
    }()
    /// Wednesday 2026-11-04, 09:41 in Chicago.
    private static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 9, minute: 41))!

    private func read(_ text: String, dates: Bool = true) -> TodoQuickRead {
        TodoQuickParse.read(text, now: Self.now, calendar: Self.calendar, dates: dates)
    }
    /// "11-06" or "11-06 09:00".
    private func when(_ read: TodoQuickRead) -> String? {
        guard let due = read.due else { return nil }
        let p = Self.calendar.dateComponents([.month, .day, .hour, .minute], from: due)
        let day = String(format: "%02d-%02d", p.month!, p.day!)
        return read.hasTime ? day + String(format: " %02d:%02d", p.hour!, p.minute!) : day
    }

    @Test func aDayAndATimeLeaveTheName() {
        let it = read("Plan the team offsite friday 9am")
        #expect(it.title == "Plan the team offsite" && when(it) == "11-06 09:00" && it.dateWords == "friday 9am")
        #expect(when(read("Call mom tomorrow")) == "11-05" && read("Call mom tomorrow").title == "Call mom")
        #expect(when(read("Pay rent today")) == "11-04")
        #expect(when(read("Dinner tonight")) == "11-04 20:00")
        #expect(when(read("Ship it next week")) == "11-11")
        #expect(when(read("Review in 3 days")) == "11-07" && when(read("Review in a week")) == "11-11")
        #expect(when(read("Dentist on Monday at 2:30pm")) == "11-09 14:30" && read("Dentist on Monday at 2:30pm").title == "Dentist")
        #expect(when(read("Standup wed")) == "11-11", "today's weekday means next week's")
        #expect(when(read("Trip next friday")) == "11-13")
        #expect(when(read("Taxes nov 20")) == "11-20" && when(read("Taxes 20th november")) == "11-20")
        #expect(when(read("Gift 11/20")) == "11-20" && when(read("Renew jan 5")) == "01-05")
    }

    @Test func timesAreRead() {
        #expect(when(read("Call Sam at 5")) == "11-04 17:00", "at 5 is the afternoon")
        #expect(when(read("Call Sam at 9")) == "11-05 09:00", "9:00 has passed today, so tomorrow")
        #expect(when(read("Lunch noon")) == "11-04 12:00")
        #expect(when(read("Sync 17:00")) == "11-04 17:00" && when(read("Sync 9 pm")) == "11-04 21:00")
        #expect(when(read("Sync tomorrow 9:30a")) == "11-05 09:30")
    }

    @Test func repeatsTagsAndPriorityAreRead() {
        let plants = read("Water the plants every day")
        #expect(plants.title == "Water the plants" && plants.repeatRule == "daily" && when(plants) == "11-04")
        let bins = read("Bins out every thursday 7am")
        #expect(bins.repeatRule == "weekly" && when(bins) == "11-05 07:00" && bins.title == "Bins out")
        #expect(read("Report weekly").repeatRule == "weekly" && read("Rent every month").repeatRule == "monthly")
        let tagged = read("Review resumes #hiring #q4 !high friday")
        #expect(tagged.title == "Review resumes" && tagged.tags == ["hiring", "q4"] && tagged.priority == 1 && when(tagged) == "11-06")
        #expect(read("Tidy desk p3").priority == 3)
    }

    /// Nothing guesses: a month needs its day, "sun" is not Sunday, a plain number is not a time.
    @Test func ordinaryWordsStayInTheName() {
        for line in ["Buy sun cream", "Ask May about the venue", "Order 5 chairs", "March to the store", "Read chapter 12",
                     "Call the 800 number", "Version 2:1 notes"] {
            let it = read(line)
            #expect(it.title == line && it.due == nil, "\(line) → \(it)")
        }
        #expect(read("tomorrow").title == "tomorrow" && read("tomorrow").due == nil, "a line that is only a date is its name")
    }

    /// With the date picked by hand, the date words stay in the name; tags and priority are still read.
    @Test func aDatePickedByHandKeepsTheWords() {
        let it = read("Plan the offsite friday 9am #work", dates: false)
        #expect(it.title == "Plan the offsite friday 9am" && it.due == nil && it.tags == ["work"])
    }
}
