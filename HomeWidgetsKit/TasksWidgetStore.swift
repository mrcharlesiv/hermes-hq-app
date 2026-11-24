// [tasks-widget] What the Tasks widget shows (TalkActivityWidget/TasksWidget.swift, docs/tasks.md item 12): the Tasks
// page's first screen for each view the widget can show, already worded by the app (App/Widgets/TasksWidgetWriter.swift
// runs the page's own `TodoViews.groups`, `TodoViews.heading` and `TodoViews.row`), so the extension carries none of
// HermesKit's task rules and stays small. Each view holds frames: the screen now and at each later moment its words
// change by the clock (midnight, a task growing stale, a due time), so the widget's timeline is those frames.
// Kept in Keychain beside the Tile widget's (`WidgetVault`). Pure rules below are what the tests read.

import Foundation

/// The views the widget can show, and how to draw the quiet states.
nonisolated struct TasksWidgetIndex: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        /// Signed in, Tasks on, a list in hand.
        case live
        /// Settings › Tasks is off on this gateway.
        case off
        /// Nobody is signed in.
        case signedOut
        /// The add-on on the computer predates Tasks.
        case needsAddOn
        /// Signed in, but the list hasn't been read yet on this phone.
        case noList
    }

    /// One choice under the widget's Show: a view as the page's own pills name it.
    struct Choice: Codable, Equatable, Sendable, Hashable, Identifiable {
        /// `TodoView.key`: "today", "upcoming", "inbox", "bots", "list:<id>".
        var id: String
        var name: String
        /// A list's colour (`TodoListColor` raw value).
        var color: String?
    }

    var version = 1
    var state: State
    var scheme: String
    /// The signed-in account's key (`TileWidgetIndex.key` of its id).
    var account: String
    var views: [Choice] = []
    var writtenAt = Date(timeIntervalSince1970: 0)

    static let defaultView = "today"

    static func quiet(_ state: State, scheme: String, account: String = "") -> TasksWidgetIndex {
        TasksWidgetIndex(state: state, scheme: scheme, account: account)
    }
}

/// One task's row, worded as the page words it.
nonisolated struct TasksWidgetRow: Codable, Equatable, Sendable, Hashable, Identifiable {
    var id: String
    var title: String
    /// At the row's end: "5:00 PM", "Tomorrow" (`TodoRowWords.when`), red when `late`.
    var when: String?
    var late = false
    /// "2/4" with steps; a task that repeats has the mark.
    var steps: String?
    var repeats = false
    /// 0 none, 1 high, 2 medium, 3 low: the circle's colour.
    var priority = 0
    /// The second line when a bot has something for you, in `tone`'s colour.
    var note: String?
    /// `TodoTone` raw value: plain, ready, working, needsYou, overdue.
    var tone = "plain"
    /// Legacy list dot colour (no longer drawn since Nov 22 "Colour means act"; kept for Codable compatibility).
    var dot: String?
    /// Goal mark colour (`TodoListColor` raw value) when the task belongs to an active or paused goal.
    var goalColor: String? = nil
    /// Ticked on the widget, its save on the way: drawn ticked and struck where it stands.
    var done = false
}

/// A group of rows under its heading (none over a list's or Inbox's open tasks).
nonisolated struct TasksWidgetSection: Codable, Equatable, Sendable, Hashable {
    var title: String?
    var detail: String?
    /// Overdue's heading is red.
    var red = false
    var rows: [TasksWidgetRow]
    /// Tasks of this group the page doesn't list either ("4 more in Work"): counted in the "+N more" line.
    var more = 0
}

/// The view's first screen as it stands from `at`.
nonisolated struct TasksWidgetFrame: Codable, Equatable, Sendable {
    var at: Date
    /// The view's pill number (`TodoViews.openCount`).
    var count: Int
    /// Tasks in the view a bot has something on for you (status ready or needs you).
    var waiting: Int
    var sections: [TasksWidgetSection]
    /// The page's own line for the view with nothing in it ("Nothing due today.").
    var empty: String

    var rowCount: Int { sections.reduce(0) { $0 + $1.rows.count } }
    /// Every task the view lists, shown here or not.
    var total: Int { sections.reduce(0) { $0 + $1.rows.count + $1.more } }
}

/// One view's frames, earliest first.
nonisolated struct TasksWidgetView: Codable, Equatable, Sendable {
    var key: String
    var name: String
    var frames: [TasksWidgetFrame]

    /// The frame showing at `date`: the last that has begun (the first before any).
    func frame(at date: Date) -> TasksWidgetFrame? {
        frames.last { $0.at <= date } ?? frames.first
    }
}

// MARK: - What fits (pure)

/// The widget's sizes, as the layout names them.
nonisolated enum TasksFamily: String, Codable, CaseIterable, Sendable {
    case small, medium, large, extraLarge
}

nonisolated enum TasksWidgetLayout {
    /// Lines of rows under the widget's top line, measured on an iPhone 17 Pro (iOS 27.2) at the standard text size:
    /// a one-line row, a heading, a note and the "+N more" line each take one.
    static func lines(_ family: TasksFamily) -> Int {
        switch family {
        case .small: 4
        case .medium: 4
        case .large: 13
        case .extraLarge: 10
        }
    }

    /// Headings and bots' notes only where there is room for them.
    static func headings(_ family: TasksFamily) -> Bool { family == .large || family == .extraLarge }
    static func notes(_ family: TasksFamily) -> Bool { family != .small }

    /// The sections to draw in `lines` lines and how many tasks are left over for the "+N more" line (which takes a
    /// line of its own, kept for it whenever something is left). A heading is drawn only over a row that fits.
    static func pick(_ frame: TasksWidgetFrame, lines: Int, headings: Bool, notes: Bool) -> (sections: [TasksWidgetSection], hidden: Int) {
        func cost(_ row: TasksWidgetRow) -> Int { notes && row.note != nil ? 2 : 1 }
        func fit(_ budget: Int) -> [TasksWidgetSection] {
            var left = budget
            var out: [TasksWidgetSection] = []
            for section in frame.sections {
                let head = headings && section.title != nil ? 1 : 0
                var rows: [TasksWidgetRow] = []
                for row in section.rows {
                    let need = cost(row) + (rows.isEmpty ? head : 0)
                    guard need <= left else { break }
                    left -= need
                    rows.append(row)
                }
                if rows.isEmpty { break }
                var kept = section
                kept.rows = rows
                if !headings { kept.title = nil; kept.detail = nil }
                out.append(kept)
                if rows.count < section.rows.count { break }
            }
            return out
        }
        let all = fit(lines)
        var shown = all.reduce(0) { $0 + $1.rows.count }
        if shown == frame.total { return (all, 0) }
        let fewer = fit(max(0, lines - 1))   // room for "+N more"
        shown = fewer.reduce(0) { $0 + $1.rows.count }
        return (fewer, frame.total - shown)
    }

    /// "+3 more".
    static func moreLine(_ hidden: Int) -> String { "+\(hidden) more" }

    /// The count that matters, for Small and the Lock Screen: what a bot has waiting for you first, else the view's.
    static func headline(_ frame: TasksWidgetFrame, view: String) -> (number: Int, words: String, waiting: Bool) {
        if frame.waiting > 0 { return (frame.waiting, "Waiting on You", true) }
        return (frame.count, view, false)
    }
}

// MARK: - The Lock Screen: counts only (docs/tasks.md rule 6)

nonisolated enum TasksWidgetLock {
    /// What the Lock Screen's three families say: numbers and the view's name, never a task's words.
    struct Words: Equatable, Sendable {
        /// Circular: the number, and the word under it.
        var number: String
        var label: String
        /// Rectangular: three short lines.
        var lines: [String]
        /// Inline: one line beside the clock.
        var inline: String
    }

    static func words(_ frame: TasksWidgetFrame?, view: String, state: TasksWidgetIndex.State) -> Words {
        guard state == .live, let frame else {
            let word = state == .off ? "Tasks off" : "Open Hermes HQ"
            return Words(number: "–", label: "Tasks", lines: ["Tasks", word], inline: "Tasks · \(word)")
        }
        let viewWord = "\(frame.count) \(view)"
        var lines = ["Tasks", frame.count == 0 ? "All Done" : viewWord]
        if frame.waiting > 0 { lines.append("\(frame.waiting) Waiting on You") }
        let inline = frame.waiting > 0 ? "\(viewWord) · \(frame.waiting) Waiting" : (frame.count == 0 ? "Tasks · All Done" : "Tasks · \(viewWord)")
        let label = frame.waiting > 0 ? "Waiting" : view
        return Words(number: "\(frame.waiting > 0 ? frame.waiting : frame.count)", label: label, lines: lines, inline: inline)
    }
}

// MARK: - Keychain

nonisolated enum TasksWidgetStore {
    static var indexService: String { WidgetVault.service("tasks.index") }
    static var viewService: String { WidgetVault.service("tasks.view") }

    static let maxIndexBytes = 32 * 1024
    /// One view's frames: at most `TasksWidgetWriter.maxFrames` frames of `maxRows` rows, about 3 KB a frame.
    static let maxViewBytes = 192 * 1024

    static func saveIndex(_ index: TasksWidgetIndex) -> Bool {
        WidgetVault.save(index, service: indexService, account: "index", maxBytes: maxIndexBytes)
    }

    static func loadIndex() -> TasksWidgetIndex? {
        WidgetVault.load(TasksWidgetIndex.self, service: indexService, account: "index", maxBytes: maxIndexBytes)
    }

    /// Saves a view. `.unchanged` when the same view is there (nothing written, nothing to reload). The first
    /// frame is stamped with the moment of writing, so a kept view that differs only there still shows the same
    /// thing (the widget shows a past frame from now): before, every write rewrote every view and reloaded the
    /// widget, a keychain write on main every few seconds.
    static func saveView(_ view: TasksWidgetView) -> TileWidgetStore.SaveResult {
        if let kept = loadView(view.key), sameButFirstStamp(kept, view) { return .unchanged }
        return WidgetVault.save(view, service: viewService, account: view.key, maxBytes: maxViewBytes) ? .written : .refused
    }

    /// Alike but for the first frame's stamp, when the kept one is no later (it has already begun).
    static func sameButFirstStamp(_ kept: TasksWidgetView, _ new: TasksWidgetView) -> Bool {
        guard let keptFirst = kept.frames.first, let newFirst = new.frames.first, keptFirst.at <= newFirst.at else {
            return kept == new
        }
        var aligned = kept
        aligned.frames[0].at = newFirst.at
        return aligned == new
    }

    static func loadView(_ key: String) -> TasksWidgetView? {
        WidgetVault.load(TasksWidgetView.self, service: viewService, account: key, maxBytes: maxViewBytes)
    }

    /// Keeps only the views of `keys` (a list deleted, Bots gone). Returns whether any went.
    @discardableResult
    static func keepViews(_ keys: Set<String>) -> Bool {
        var removed = false
        for account in WidgetVault.accounts(service: viewService) where !keys.contains(account) {
            WidgetVault.delete(service: viewService, account: account)
            removed = true
        }
        return removed
    }

    /// A quiet state (signed out, Tasks off, the add-on to update): every view goes, the index says which state.
    static func quiet(_ state: TasksWidgetIndex.State, scheme: String, account: String = "") -> Bool {
        let removed = keepViews([])
        let index = TasksWidgetIndex.quiet(state, scheme: scheme, account: account)
        let before = loadIndex()
        _ = saveIndex(index)
        return removed || before?.state != index.state || before?.account != index.account
    }

    static func removeAll() {
        WidgetVault.deleteAll(service: indexService)
        WidgetVault.deleteAll(service: viewService)
    }
}
