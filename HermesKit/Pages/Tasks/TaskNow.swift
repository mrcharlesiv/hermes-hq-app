// [tasks] The task's one move (owner 2026-11-07, "I love all of that. Go." to the Pinned Task design, step 1): the
// brief's foot holds one button that moves the task on, chosen by its state, and Done beside it. The big button had
// been Mark Done even while your step ("Send the nudge") was still open, and Answer did nothing on a task's chat.
// Plain rules, tested in Tests/Pages/TasksTests (TaskNowTests): the first that fits wins.

import Foundation

nonisolated struct TaskNow: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case reopen
        /// A needs-you question: the chat's bar, keys up.
        case answer
        /// What the bot made, newest first: a note to share, a link or a file to open.
        case share(TodoMade)
        case openLink(TodoMade)
        case openFile(TodoMade)
        case call(String)
        /// Working: a visible "Where does this stand?" in the task's chat.
        case askUpdate
        /// A helper bot that hasn't started: a visible "Please start on this now."
        case askStart
        /// Your own task with no steps: the bot is asked to take its part.
        case askHelp
        case markDone
    }

    var primary: Action
    /// Exactly one button is tinted at a time; nil when the primary isn't (nothing waits on you, or Reopen).
    var tinted: Bool
    var secondary: Action?

    /// What the visible messages say.
    static let updateQuestion = "Where does this stand?"
    static let startRequest = "Please start on this now."

    /// The move for `task`; nil when it was deleted elsewhere (nothing to do but close). `phone`: a number found in the
    /// bot's line or the notes (the app finds it; Foundation's detector is not plain data).
    static func pick(_ task: TodoTask, phone: String?, deleted: Bool = false) -> TaskNow? {
        if deleted { return nil }
        let mine = task.steps.filter { $0.who != "bot" }
        let mineOpen = mine.contains { !$0.done }
        switch task.status {
        case "done":
            return TaskNow(primary: .reopen, tinted: false, secondary: nil)
        case "needs_you":
            return TaskNow(primary: .answer, tinted: true, secondary: .markDone)
        case "ready":
            guard let act = madeAction(task) ?? phone.map(Action.call) else {
                return TaskNow(primary: .markDone, tinted: true, secondary: nil)
            }
            // Every step of yours done: Done is the move, and what the bot made stays a tap away.
            if !mine.isEmpty, !mineOpen { return TaskNow(primary: .markDone, tinted: true, secondary: act) }
            return TaskNow(primary: act, tinted: true, secondary: .markDone)
        case "working":
            return TaskNow(primary: .askUpdate, tinted: false, secondary: .markDone)
        default:
            if task.whoKind != .me, untouched(task) {
                return TaskNow(primary: .askStart, tinted: true, secondary: .markDone)
            }
            let help: Action? = task.whoKind == .me && task.steps.isEmpty ? .askHelp : nil
            return TaskNow(primary: .markDone, tinted: !mineOpen, secondary: help)
        }
    }

    /// [tasks] Owner 2026-11-07 (a smart-home task's Ready card offered "Call … should def not say Call"): the
    /// detector reads IP addresses, device ids and plain runs of digits as phone numbers. A match `candidate` found in
    /// `text` counts only when it is written as a phone number ("(512) 555-0142", "+1 512 555 0142", "512-555-0142")
    /// or stands near a word that says it is one ("call", "phone", "office"…), and never when dots, colons or slashes
    /// sit in it or right beside it (addresses, versions, dates, paths).
    static func callable(_ candidate: String, in text: String) -> Bool {
        let digits = candidate.filter(\.isNumber).count
        guard (7...15).contains(digits), !candidate.contains(where: { ".:/_x".contains($0) }) else { return false }
        guard let range = text.range(of: candidate) else { return false }
        let before = text[..<range.lowerBound], after = text[range.upperBound...]
        if let c = before.last, ".:/_".contains(c) || c.isLetter || c.isNumber { return false }
        if let c = after.first, ".:/_".contains(c) && after.dropFirst().first?.isNumber == true { return false }
        if let c = after.first, c.isLetter || c.isNumber { return false }
        let trimmed = candidate.trimmingCharacters(in: .whitespaces)
        let formatted = trimmed.hasPrefix("+") || trimmed.contains("(")
            || trimmed.range(of: #"^\d{3}[- ]\d{3}[- ]\d{4}$"#, options: .regularExpression) != nil
            || trimmed.range(of: #"^\d{3}[- ]\d{4}$"#, options: .regularExpression) != nil
        let near = String(before.suffix(40) + " " + after.prefix(12)).lowercased()
        let said = ["call", "phone", "tel", "dial", "office", "mobile", "cell", "number", "text them", "reach"].contains { near.contains($0) }
        return formatted || said
    }

    /// The newest thing the bot made, as the move on it.
    static func madeAction(_ task: TodoTask) -> Action? {
        guard let made = task.made.last else { return nil }
        switch made.kind {
        case "link": return .openLink(made)
        case "file": return .openFile(made)
        default: return .share(made)
        }
    }

    /// A helper bot that hasn't done anything on the task yet: no step of its ticked, nothing made, no line written.
    static func untouched(_ task: TodoTask) -> Bool {
        task.made.isEmpty && task.statusNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !task.steps.contains { $0.who == "bot" && $0.done }
    }
}

extension TaskNow.Action {
    /// The button's words: a verb first, never cut. `secondary`: Mark Done beside another move reads "Done".
    func label(botName: String, secondary: Bool = false) -> String {
        switch self {
        case .reopen: return "Reopen"
        case .answer: return "Answer"
        case .share: return "Share Draft…"
        case .openLink: return "Open Link"
        case .openFile: return "Open File"
        case .call: return "Call"
        case .askUpdate: return "Ask for an Update"
        case .askStart: return "Ask \(botName) to Start"
        case .askHelp: return "Ask \(botName) to Help"
        case .markDone: return secondary ? "Done" : "Mark Done"
        }
    }

    /// The SF Symbol before the words.
    var symbol: String {
        switch self {
        case .reopen: return "arrow.uturn.backward"
        case .answer: return "arrowshape.turn.up.left"
        case .share: return "square.and.arrow.up"
        case .openLink: return "safari"
        case .openFile: return "doc"
        case .call: return "phone.fill"
        case .askUpdate: return "bubble.left"
        case .askStart, .askHelp: return "sparkles"
        case .markDone: return "checkmark"
        }
    }

    /// The UI tests' handle.
    var identifier: String {
        switch self {
        case .reopen: return "task.reopen"
        case .answer: return "task.answer"
        case .share: return "task.share-draft"
        case .openLink: return "task.open-link"
        case .openFile: return "task.open-file"
        case .call: return "task.call"
        case .askUpdate: return "task.ask-update"
        case .askStart: return "task.ask-start"
        case .askHelp: return "task.help"
        case .markDone: return "task.mark-done"
        }
    }
}
