import Foundation
import Testing
@testable import HermesHQNative

struct ListTimeTests {
    /// Thursday 9 Oct 2026, 15:30 in a fixed zone, so the tests don't depend on the Mac's clock or zone.
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()
    static func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    static let now = at(2026, 10, 9, 15, 30)

    @Test func listTimeWords() {
        let c = Self.calendar, now = Self.now
        #expect(ListTime.string(Self.at(2026, 10, 9, 9, 5), now: now, calendar: c) == "9:05 AM")
        #expect(ListTime.string(Self.at(2026, 10, 9, 0, 1), now: now, calendar: c) == "12:01 AM")
        #expect(ListTime.string(Self.at(2026, 10, 9, 15, 40), now: now, calendar: c) == "3:40 PM")   // a little ahead
        #expect(ListTime.string(Self.at(2026, 10, 8, 23, 59), now: now, calendar: c) == "Yesterday")
        #expect(ListTime.string(Self.at(2026, 10, 5), now: now, calendar: c) == "Mon")
        #expect(ListTime.string(Self.at(2026, 10, 3), now: now, calendar: c) == "Sat")
        #expect(ListTime.string(Self.at(2026, 10, 2), now: now, calendar: c) == "Oct 2")
        #expect(ListTime.string(Self.at(2026, 8, 7), now: now, calendar: c) == "Aug 7")
        #expect(ListTime.string(Self.at(2025, 8, 7), now: now, calendar: c) == "Aug 7, 2025")
        #expect(ListTime.string(nil, now: now, calendar: c) == "")
        #expect(ListTime.string(Date(timeIntervalSince1970: 0), now: now, calendar: c) == "")
    }
}

struct SessionGroupingTests {
    private func session(_ id: String, _ date: Date?, source: String? = nil, unread: Bool = false) -> SessionSummary {
        SessionSummary(id: id, profile: "default", title: id, preview: nil, lastActive: date, source: source,
                       unread: unread, isRunning: false)
    }

    /// Thursday 22 Oct 2026, 15:30 (Chicago): far enough into the month for every bucket.
    static let now = ListTimeTests.at(2026, 10, 22, 15, 30)
    static func calendar(firstWeekday: Int) -> Calendar {
        var c = ListTimeTests.calendar
        c.firstWeekday = firstWeekday
        return c
    }
    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date { ListTimeTests.at(y, m, d, h, min) }

    private var sample: [SessionSummary] {
        [
            session("old", at(2025, 12, 31)),
            session("small-hours", at(2026, 10, 22, 1, 30)),   // before 4 AM: still yesterday's
            session("aug", at(2026, 8, 7)),
            session("yesterday", at(2026, 10, 21, 22)),
            session("none", nil),
            session("monday", at(2026, 10, 19, 9)),
            session("today", at(2026, 10, 22, 15)),
            session("future", at(2026, 10, 22, 16)),            // a little ahead of this clock
            session("sunday", at(2026, 10, 18, 10)),
            session("sunday-small", at(2026, 10, 18, 2)),       // Saturday's day
            session("last-week", at(2026, 10, 13)),
            session("this-month", at(2026, 10, 5)),
            session("sep", at(2026, 9, 30)),
        ]
    }

    /// The web's `calendarBucket` with every group labelled (phone), weeks starting Sunday (en-US).
    @Test func groupsByCalendarBucket() {
        let groups = SessionGrouping.groups(sample, now: Self.now, calendar: Self.calendar(firstWeekday: 1))
        #expect(groups.map(\.title) == ["Earlier today", "Yesterday", "Earlier this week", "Last week", "Earlier this month",
                                        "September", "August", "December 2025", "Earlier"])
        #expect(groups.map(\.id) == ["today", "yesterday", "this-week", "last-week", "this-month", "m-2026-9", "m-2026-8",
                                     "my-2025-12", "none"])
        #expect(groups[0].sessions.map(\.id) == ["future", "today"])
        #expect(groups[1].sessions.map(\.id) == ["small-hours", "yesterday"])
        #expect(groups[2].sessions.map(\.id) == ["monday", "sunday"])
        #expect(groups[3].sessions.map(\.id) == ["sunday-small", "last-week"])
        #expect(groups.last?.sessions.map(\.id) == ["none"])
    }

    /// A Monday-start locale moves Sunday into last week.
    @Test func weekStartFollowsTheLocale() {
        let groups = SessionGrouping.groups(sample, now: Self.now, calendar: Self.calendar(firstWeekday: 2))
        #expect(groups[2].title == "Earlier this week" && groups[2].sessions.map(\.id) == ["monday"])
        #expect(groups[3].title == "Last week" && groups[3].sessions.map(\.id) == ["sunday", "sunday-small", "last-week"])
    }

    /// The day rolls over at 4 AM: at 2 AM, last evening is still "today".
    @Test func dayRollsOverAtFour() {
        let c = Self.calendar(firstWeekday: 1)
        let smallHours = at(2026, 10, 22, 2)
        #expect(SessionGrouping.label(at(2026, 10, 21, 23), now: smallHours, calendar: c).title == "Earlier today")
        #expect(SessionGrouping.label(at(2026, 10, 21, 3), now: smallHours, calendar: c).title == "Yesterday")
        #expect(SessionGrouping.label(at(2026, 10, 22, 4, 1), now: at(2026, 10, 22, 5), calendar: c).title == "Earlier today")
        #expect(SessionGrouping.nextRollover(after: smallHours, calendar: c) == at(2026, 10, 22, 4))
        #expect(SessionGrouping.nextRollover(after: at(2026, 10, 22, 5), calendar: c) == at(2026, 10, 23, 4))
    }

    /// Early in a month and a year, the coarse buckets still read right.
    @Test func earlyInTheYear() {
        let c = Self.calendar(firstWeekday: 1)
        let now = at(2027, 1, 2, 12)                   // a Saturday
        #expect(SessionGrouping.label(at(2026, 12, 28), now: now, calendar: c).title == "Earlier this week")
        #expect(SessionGrouping.label(at(2026, 12, 20), now: now, calendar: c).title == "Last week")
        #expect(SessionGrouping.label(at(2026, 12, 1), now: now, calendar: c).title == "December 2026")
    }

    @Test func emptyList() {
        #expect(SessionGrouping.groups([], now: Self.now, calendar: ListTimeTests.calendar).isEmpty)
    }

    @Test func tiesKeepGatewayOrder() {
        let t = at(2026, 10, 22, 10)
        let groups = SessionGrouping.groups([session("a", t), session("b", t), session("c", t)],
                                            now: Self.now, calendar: ListTimeTests.calendar)
        #expect(groups.first?.sessions.map(\.id) == ["a", "b", "c"])
    }

    /// Spec 02 §9.2: background runs (and cron runs, which belong in a folder M1 lacks) are not listed, nor counted.
    @Test func backgroundRunsAreHidden() {
        let t = at(2026, 10, 22, 10)
        let rows = [session("chat", t, source: "desktop", unread: true), session("tool", t, source: "tool", unread: true),
                    session("oneshot", t, source: "oneshot"), session("sub", t, source: "subagent", unread: true),
                    session("kanban", t, source: "kanban"), session("cron", t, source: "cron", unread: true),
                    session("cron_42_x", t, source: nil), session("tg", t, source: "telegram"),
                    session("plain", t, source: nil, unread: true)]
        #expect(SessionList.visible(rows).map(\.id) == ["chat", "tg", "plain"])
        #expect(SessionList.unreadCount(rows) == 2)
    }
}
