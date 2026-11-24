// [task-lists] A list on the Tasks page (owner 2026-11-14, six boards in hermes-hq-share/2026-11-14-tasks-lists, "All
// approved"): it has a colour, an icon and a bot that keeps it; a bot offers a list or a batch of tasks as one card
// instead of making it; a task says where a bot found it; a bot offers to close your task instead of closing it.
// Needs hermes-hq-push 0.9.55 (`lists: true` in `GET /tasks`); an older add-on keeps plain names and none of the rest.
//
// The owner's rule for the rows (2026-11-14, "that does feel busy to have two meanings of the face"): a bot's face on
// a task means one thing, that the bot is on it. A list's bot is said in words ("Kept by Otto"), never by a face.
// Plain data and rules, tested in Tests/Pages/TodoListsTests.

import Foundation
import Synchronization

/// A list's colour: the dot on its pill and on its tasks' rows in Today, Upcoming and search.
nonisolated enum TodoListColor: String, CaseIterable, Sendable {
    case blue, green, orange, red, purple, pink, teal, yellow, gray

    var name: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// The icons a list can take (SF Symbols), in the order the Edit List sheet shows them.
nonisolated enum TodoListIcons {
    static let all = ["list.bullet", "briefcase", "house", "cart", "heart", "star", "book", "airplane", "dollarsign.circle",
                      "person.2", "wrench.and.screwdriver", "leaf", "graduationcap", "gift", "pawprint", "flag"]
    static let fallback = "list.bullet"

    /// "briefcase" → "Briefcase": what VoiceOver says for an icon.
    static func spoken(_ icon: String) -> String {
        let words: [String: String] = ["list.bullet": "List", "house": "Home", "cart": "Shopping", "dollarsign.circle": "Money",
                                       "person.2": "People", "wrench.and.screwdriver": "Tools", "graduationcap": "School",
                                       "pawprint": "Pets"]
        return words[icon] ?? icon.split(separator: ".").first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Icon"
    }
}

/// A bot's offer to close a task that isn't its own (`tasks_update offer_done`): you tap Mark Done or Keep Open.
nonisolated struct TodoCloseOffer: Codable, Hashable, Sendable {
    /// The bot (profile).
    var by: String
    /// Why it looks settled: "Ivy confirmed by email Tuesday".
    var text: String
    var at: String?
    /// You chose Keep Open: the offer is off the row, and the bot isn't to ask again.
    var kept = false

    enum CodingKeys: String, CodingKey { case by, text, at, kept }

    init(by: String, text: String, at: String? = nil, kept: Bool = false) {
        self.by = by; self.text = text; self.at = at; self.kept = kept
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        by = (try? c.decodeIfPresent(String.self, forKey: .by)) ?? "default"
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        at = try? c.decodeIfPresent(String.self, forKey: .at)
        kept = (try? c.decodeIfPresent(Bool.self, forKey: .kept)) ?? false
    }
}

/// Where a bot found a task: the app, who it came from, when, and a link.
nonisolated struct TodoFrom: Codable, Hashable, Sendable {
    var app: String?
    var who: String?
    /// "2026-11-13".
    var at: String?
    var ref: String?
    var link: String?

    init(app: String? = nil, who: String? = nil, at: String? = nil, ref: String? = nil, link: String? = nil) {
        self.app = app; self.who = who; self.at = at; self.ref = ref; self.link = link
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? {
            ((try? c.decodeIfPresent(String.self, forKey: key)) ?? nil)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        app = text(.app); who = text(.who); at = text(.at); ref = text(.ref); link = text(.link)
    }

    var isEmpty: Bool { app == nil && who == nil && at == nil && link == nil }
}

/// One task on an offer's card.
nonisolated struct TodoOfferTask: Codable, Hashable, Sendable {
    var title: String
    var due: String?
    var notes: String?
    var source: TodoFrom?
    /// [goals step 3] On a goal's offer (0.9.66): "me" (yours) or "bot"; `bot` is the bot it goes to.
    var who: String?
    var bot: String?
    /// The goal's milestone id, or (on a goal or plan offer) one of the offer's own milestone titles.
    var milestone: String?

    init(title: String, due: String? = nil, notes: String? = nil, source: TodoFrom? = nil, who: String? = nil, bot: String? = nil,
         milestone: String? = nil) {
        self.title = title; self.due = due; self.notes = notes; self.source = source; self.who = who; self.bot = bot
        self.milestone = milestone
    }

    enum CodingKeys: String, CodingKey { case title, due, notes, source, who, bot, milestone }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        func text(_ key: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)).flatMap { $0?.isEmpty == true ? nil : $0 } }
        due = text(.due); notes = text(.notes); who = text(.who); bot = text(.bot); milestone = text(.milestone)
        source = (try? c.decodeIfPresent(TodoFrom.self, forKey: .source)).flatMap { $0 }
    }

    /// The bot it goes to, for a bot's task: its own `bot`, else the offering bot.
    func botFor(_ offer: TodoOffer) -> String? { who == "bot" ? (bot ?? offer.bot) : nil }
}

/// [goals step 3] A milestone a goal or plan offer would add.
nonisolated struct GoalOfferMilestone: Codable, Hashable, Sendable {
    var title: String
    var due: String?
}

/// [goals step 3] The number a goal offer would give the new goal.
nonisolated struct GoalOfferMeasure: Codable, Hashable, Sendable {
    var unit: String
    var start: Double
    var target: Double

    init(unit: String = "", start: Double = 0, target: Double) { self.unit = unit; self.start = start; self.target = target }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unit = (try? c.decodeIfPresent(String.self, forKey: .unit)).flatMap { $0 } ?? ""
        start = (try? c.decodeIfPresent(Double.self, forKey: .start)).flatMap { $0 } ?? 0
        target = try c.decode(Double.self, forKey: .target)
    }
}

/// [goals set-up] What accepting a plan offer also sets on its goal (hermes-hq-push's `setup`): only the keys the add-on
/// kept (a name that differs from the goal's and no other goal has; a why, a date or a number the goal lacks). Nil on
/// the offer when it kept none.
nonisolated struct GoalPlanSetup: Codable, Hashable, Sendable {
    var name: String?
    var why: String?
    /// A day ("2027-01-31").
    var due: String?
    var measure: GoalOfferMeasure?

    init(name: String? = nil, why: String? = nil, due: String? = nil, measure: GoalOfferMeasure? = nil) {
        self.name = name; self.why = why; self.due = due; self.measure = measure
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? {
            (try? c.decodeIfPresent(String.self, forKey: key)).flatMap { $0 }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
        }
        name = text(.name); why = text(.why)
        due = text(.due).map { String($0.prefix(10)) }
        measure = (try? c.decodeIfPresent(GoalOfferMeasure.self, forKey: .measure)).flatMap { $0 }
    }

    /// Nothing kept: read as no set-up at all.
    var isEmpty: Bool { name == nil && why == nil && due == nil && measure == nil }
}

/// A task already on your page that an offer would move into the list.
nonisolated struct TodoOfferMove: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
}

/// A bot's offer (`tasks_offer`): a list to make with tasks for it, tasks for a list that asks first, or tasks to move
/// into a list. Nothing changes until you tap.
nonisolated struct TodoOffer: Codable, Hashable, Sendable, Identifiable {
    var id: String
    /// The bot (profile) that offers it.
    var bot: String
    /// The chat it was offered in; its card shows there.
    var sessionId: String?
    var at: String?
    /// The list's name.
    var list: String
    /// The list's id when it is one of yours already.
    var section: String?
    /// The list isn't there yet: accepting makes it, kept by `bot`.
    var isNew: Bool
    var why: String
    var tasks: [TodoOfferTask]
    var move: [TodoOfferMove]
    /// "new" | "accepted" | "declined" | "undone".
    var state: String
    /// "new" | "moved" | "left"; nil with nothing to move.
    var moveState: String?
    /// Accepted with the list (false: "Add, No List").
    var listed: Bool?
    /// The tasks accepting made.
    var added: [String]
    // [goals step 3] A goal's offer (hermes-hq-push 0.9.66). A list offer has no `kind` (read as "list").
    /// "list" | "goal" | "plan" | "checkin" | "tasks".
    var kind = "list"
    /// The goal it is for (nil for kind "goal", which makes one).
    var goal: String?
    /// The goal's name (always filled in on a goal offer).
    var title = ""
    /// A check-in's two sentences: what moved.
    var summary = ""
    /// A new goal's date (a day).
    var due: String?
    var measure: GoalOfferMeasure?
    /// The milestones a goal or plan offer would add.
    var milestones: [GoalOfferMilestone] = []
    var answeredAt: String?
    /// Accepting made this goal (kind "goal").
    var madeGoal: String?
    var madeMilestones: [String] = []
    /// Accepted with its plan (false: "Keep the Goal, No Plan").
    var plan: Bool?
    /// Accepted under the goal (false: "Just Tasks").
    var inGoal: Bool?
    /// What undo left in place because you had changed it.
    var kept: [String] = []
    /// Held for the lead's check-in (never sent as a card; kept for an app that is sent one anyway).
    var held = false
    /// [goals set-up] A plan offer: what accepting it also sets on the goal (only the kept keys), and up to three short
    /// lines on what the plan rests on ("Your course notes, 8 units"). Both absent before the add-on knew them.
    var setup: GoalPlanSetup?
    var builtOn: [String] = []

    enum CodingKeys: String, CodingKey {
        case id, bot, sessionId = "session_id", at, list, section, isNew = "new", why, tasks, move, state
        case moveState = "move_state", listed, added
        case kind, goal, title, summary, due, measure, milestones, held, kept, plan, setup
        case answeredAt = "answered_at", madeGoal = "made_goal", madeMilestones = "made_milestones", inGoal = "in_goal"
        case builtOn = "built_on"
    }

    init(id: String, bot: String, sessionId: String? = nil, at: String? = nil, list: String, section: String? = nil,
         isNew: Bool = true, why: String = "", tasks: [TodoOfferTask] = [], move: [TodoOfferMove] = [], state: String = "new",
         moveState: String? = nil, listed: Bool? = nil, added: [String] = []) {
        self.id = id; self.bot = bot; self.sessionId = sessionId; self.at = at; self.list = list; self.section = section
        self.isNew = isNew; self.why = why; self.tasks = tasks; self.move = move; self.state = state
        self.moveState = moveState; self.listed = listed; self.added = added
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        bot = (try? c.decodeIfPresent(String.self, forKey: .bot)) ?? "default"
        sessionId = (try? c.decodeIfPresent(String.self, forKey: .sessionId)).flatMap { $0?.isEmpty == true ? nil : $0 }
        at = try? c.decodeIfPresent(String.self, forKey: .at)
        list = (try? c.decodeIfPresent(String.self, forKey: .list)) ?? ""
        section = (try? c.decodeIfPresent(String.self, forKey: .section)).flatMap { $0?.isEmpty == true ? nil : $0 }
        isNew = (try? c.decodeIfPresent(Bool.self, forKey: .isNew)) ?? (section == nil)
        why = (try? c.decodeIfPresent(String.self, forKey: .why)) ?? ""
        tasks = (try? c.decodeIfPresent([TodoOfferTask].self, forKey: .tasks)) ?? []
        move = (try? c.decodeIfPresent([TodoOfferMove].self, forKey: .move)) ?? []
        state = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? "new"
        moveState = (try? c.decodeIfPresent(String.self, forKey: .moveState)).flatMap { $0 }
        listed = (try? c.decodeIfPresent(Bool.self, forKey: .listed)).flatMap { $0 }
        added = (try? c.decodeIfPresent([String].self, forKey: .added)) ?? []
        func text(_ key: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)).flatMap { $0?.isEmpty == true ? nil : $0 } }
        kind = text(.kind) ?? "list"
        goal = text(.goal)
        title = text(.title) ?? (kind == "list" ? "" : list)
        if list.isEmpty { list = title }
        summary = text(.summary) ?? ""
        due = text(.due)
        measure = (try? c.decodeIfPresent(GoalOfferMeasure.self, forKey: .measure)).flatMap { $0 }
        milestones = (try? c.decodeIfPresent([GoalOfferMilestone].self, forKey: .milestones)).flatMap { $0 } ?? []
        answeredAt = text(.answeredAt)
        madeGoal = text(.madeGoal)
        madeMilestones = (try? c.decodeIfPresent([String].self, forKey: .madeMilestones)).flatMap { $0 } ?? []
        plan = (try? c.decodeIfPresent(Bool.self, forKey: .plan)).flatMap { $0 }
        inGoal = (try? c.decodeIfPresent(Bool.self, forKey: .inGoal)).flatMap { $0 }
        kept = (try? c.decodeIfPresent([String].self, forKey: .kept)).flatMap { $0 } ?? []
        held = ((try? c.decodeIfPresent(Bool.self, forKey: .held)) ?? nil) ?? false
        setup = (try? c.decodeIfPresent(GoalPlanSetup.self, forKey: .setup)).flatMap { $0 }.flatMap { $0.isEmpty ? nil : $0 }
        // Each line on its own: one that isn't words is dropped, the others stay.
        if let raw = try? c.decodeIfPresent([JSONValue].self, forKey: .builtOn) {
            builtOn = raw.compactMap(\.string)
        }
    }

    /// [goals step 3] A goal's offer (a goal to make, a plan, a check-in, tasks for a goal), not a list's.
    var isGoal: Bool { kind != "list" }

    /// A chat's card keeps this many of its tasks (the gateway takes up to 20).
    static let cardTasks = 20

    /// It waits for your first answer.
    var isWaiting: Bool { state == "new" }
    /// The tasks went on, and the ones to move still wait for "Move 3 to Work" or "Leave Them".
    var asksMove: Bool { state == "accepted" && moveState == "new" && !move.isEmpty && listed != false }
}

/// A tap on an offer's card.
nonisolated enum TodoOfferAction: String, Codable, Sendable {
    case accept, decline, move, leave, undo
}

/// A button on an offer's card.
nonisolated struct TodoOfferButton: Hashable, Sendable {
    var title: String
    var action: TodoOfferAction
    /// `accept` only: false is "Add, No List".
    var makesList = true
    /// The filled button.
    var main = false
}

nonisolated enum TodoLists {
    // MARK: A list's look

    static func color(_ section: TodoUserSection?) -> TodoListColor? { section?.color.flatMap(TodoListColor.init(rawValue:)) }

    /// The colour of the dot before a row's date, outside the task's own list: nil for a task in no list, or in a
    /// list with no colour yet.
    static func dot(_ task: TodoTask, in view: TodoView, sections: [TodoUserSection]) -> TodoListColor? {
        if case .list = view { return nil }       // every row there is that list's
        if view == .bots { return nil }
        guard let id = task.section else { return nil }
        return color(sections.first { $0.id == id })
    }

    /// [tasks-colour] The icon before a row's date, outside the task's own list: the list's own, or the plain list
    /// icon for a list with none. Nil for a task in no list (or in one that is gone).
    static func mark(_ task: TodoTask, in view: TodoView, sections: [TodoUserSection]) -> String? {
        if case .list = view { return nil }       // every row there is that list's
        if view == .bots { return nil }
        guard let id = task.section, let section = sections.first(where: { $0.id == id }) else { return nil }
        return section.icon ?? TodoListIcons.fallback
    }

    /// The first colour no list has yet (a new list's), else the first.
    static func nextColor(_ sections: [TodoUserSection]) -> TodoListColor {
        let used = Set(sections.compactMap(\.color))
        return TodoListColor.allCases.first { !used.contains($0.rawValue) } ?? .blue
    }

    // MARK: The keeper

    /// Under the pills on a list a bot keeps: "Kept by Otto · checked 8:02 AM" ("checked Nov 13" on another day).
    static func keeperLine(_ section: TodoUserSection, now: Date, calendar: Calendar = .current,
                           botName: (String?) -> String) -> String? {
        guard let bot = section.bot else { return nil }
        var line = "Kept by \(botName(bot))"
        if let checked = TodoDates.moment(section.checkedAt) {
            let when = calendar.isDate(checked, inSameDayAs: now) ? TodoWords.clock(checked, calendar: calendar)
                : TodoWords.day(checked, now: now, calendar: calendar)
            line += " · checked \(when)"
        }
        return line
    }

    /// On a task's who row, in words: the list's bot looks after a task of yours it has no part of. Nil when the bot
    /// is already on the task (its face says so), for a bot's own task, and for a finished one.
    static func watchedBy(_ task: TodoTask, sections: [TodoUserSection], botName: (String?) -> String) -> String? {
        guard !task.isDone, task.whoKind == .me, let id = task.section,
              let bot = sections.first(where: { $0.id == id })?.bot else { return nil }
        return "watched by \(botName(bot))"
    }

    // MARK: Where a task came from

    /// "Email · Ivy · Nov 13": the source row on a task a bot added. Nil when the bot gave none.
    static func sourceLine(_ task: TodoTask, now: Date, calendar: Calendar = .current) -> String? {
        guard let from = task.source?.from, !from.isEmpty else { return nil }
        var parts = [from.app, from.who].compactMap { $0 }
        if let at = from.at, let day = TodoDates.day(String(at.prefix(10)), calendar: calendar) {
            parts.append(TodoWords.day(day, now: now, calendar: calendar))
        }
        if parts.isEmpty, from.link != nil { parts.append("Link") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The source's link, when it is one the app can open.
    static func sourceURL(_ task: TodoTask) -> URL? {
        guard let link = task.source?.from?.link, let url = URL(string: link),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    // MARK: A bot offers to close a task

    /// The offer that still waits for you: not once you kept the task open, and not on a finished task.
    static func closeOffer(_ task: TodoTask) -> TodoCloseOffer? {
        guard !task.isDone, let offer = task.offer, !offer.kept else { return nil }
        return offer
    }

    /// The row's second line: "Otto: looks done · Ivy confirmed by email".
    static func closeLine(_ offer: TodoCloseOffer, botName: (String?) -> String) -> String {
        let why = offer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return why.isEmpty ? "\(botName(offer.by)) thinks this is done" : "\(botName(offer.by)): looks done · \(why)"
    }

    // MARK: A bot offers a list or a batch of tasks

    /// The offers a chat shows as cards: the ones made in it, oldest first.
    static func offers(_ all: [TodoOffer], inChat session: String?) -> [TodoOffer] {
        guard let session, !session.isEmpty else { return [] }
        return all.filter { $0.sessionId == session && $0.state != "undone" && $0.state != "declined" }
    }

    /// The offers the Tasks page shows above its rows: every list offer that still waits for an answer. [goals step 3] A
    /// goal's offer has its own place (`GoalOffers.today`).
    static func waiting(_ all: [TodoOffer]) -> [TodoOffer] { all.filter { !$0.isGoal && ($0.isWaiting || $0.asksMove) } }

    /// "3 tasks", "1 task".
    static func count(_ n: Int) -> String { n == 1 ? "1 task" : "\(n) tasks" }

    /// The card's title: "Otto suggests a Work list", "Otto has 3 tasks for Work", "Move 2 tasks to Work?".
    static func offerTitle(_ offer: TodoOffer, botName: (String?) -> String) -> String {
        let name = botName(offer.bot)
        if offer.asksMove { return "Move \(count(offer.move.count)) to \(offer.list)?" }
        if offer.isNew { return "\(name) suggests a \(offer.list) list" }
        if offer.tasks.isEmpty { return "\(name) would move \(count(offer.move.count)) to \(offer.list)" }
        return "\(name) has \(count(offer.tasks.count)) for \(offer.list)"
    }

    /// The card's buttons, the main one first; empty once it is fully answered.
    static func offerButtons(_ offer: TodoOffer) -> [TodoOfferButton] {
        if offer.asksMove {
            return [TodoOfferButton(title: "Move \(offer.move.count) to \(offer.list)", action: .move, main: true),
                    TodoOfferButton(title: "Leave Them", action: .leave)]
        }
        guard offer.isWaiting else { return [] }
        let n = offer.tasks.count
        if offer.isNew {
            let make = n > 0 ? "Make \(offer.list) & Add \(n)" : "Make \(offer.list)"
            var out = [TodoOfferButton(title: make, action: .accept, main: true)]
            if n > 0 { out.append(TodoOfferButton(title: "Add, No List", action: .accept, makesList: false)) }
            out.append(TodoOfferButton(title: "Not Now", action: .decline))
            return out
        }
        if n == 0 {
            // Only tasks to move: accepting is the move.
            return [TodoOfferButton(title: "Move \(offer.move.count) to \(offer.list)", action: .accept, main: true),
                    TodoOfferButton(title: "Leave Them", action: .decline)]
        }
        return [TodoOfferButton(title: "Add \(n) to \(offer.list)", action: .accept, main: true),
                TodoOfferButton(title: "Not Now", action: .decline)]
    }

    /// What an answered card says in place of its buttons: "Made Work and added 9 tasks", "Added 9 tasks", "Moved 3
    /// tasks to Work". Nil while it waits.
    static func offerDone(_ offer: TodoOffer) -> String? {
        switch offer.state {
        case "accepted":
            let n = offer.added.count
            var parts: [String] = []
            if offer.isNew, offer.listed != false {
                parts.append(n > 0 ? "Made \(offer.list) and added \(count(n))" : "Made \(offer.list)")
            } else if n > 0 {
                parts.append(offer.listed == false ? "Added \(count(n)), no list" : "Added \(count(n)) to \(offer.list)")
            }
            if offer.moveState == "moved" { parts.append("\(parts.isEmpty ? "Moved" : "moved") \(count(offer.move.count))\(parts.isEmpty ? " to \(offer.list)" : "")") }
            return parts.isEmpty ? "Done" : parts.joined(separator: ", ")
        case "declined": return "Not now"
        case "undone": return "Undone"
        default: return nil
        }
    }

    /// Undo shows on a card you accepted, until the day's end (the gateway drops it from the list after a day).
    static func canUndo(_ offer: TodoOffer) -> Bool { offer.state == "accepted" }

    /// The chat card's title: what the bot offered, whatever became of it (the card's foot says that).
    static func chatTitle(_ offer: TodoOffer, botName: (String?) -> String) -> String {
        var first = offer
        first.state = "new"; first.moveState = offer.move.isEmpty ? nil : "new"
        return offerTitle(first, botName: botName)
    }

    /// The chat card's foot. It is the same height in every state, so the card never jumps as you answer: a filled
    /// button or one line of words, then a row of quiet buttons.
    static func chatFoot(_ offer: TodoOffer, past: Bool) -> TodoOfferFoot {
        // Answered more than a day ago (the gateway has let it go): it says so, and offers nothing.
        if past { return TodoOfferFoot(line: "Answered", opensTasks: true) }
        let buttons = offerButtons(offer)
        if let main = buttons.first {
            return TodoOfferFoot(main: main, others: Array(buttons.dropFirst().prefix(2)), undo: offer.asksMove)
        }
        return TodoOfferFoot(line: offerDone(offer) ?? "Answered", good: offer.state == "accepted",
                             undo: canUndo(offer), opensTasks: true)
    }
}

/// The foot of an offer's chat card.
nonisolated struct TodoOfferFoot: Hashable, Sendable {
    /// The filled button; nil once it is answered (`line` says what happened).
    var main: TodoOfferButton?
    var line: String?
    /// `line` in green with a tick (accepted).
    var good = false
    /// The quiet buttons beside it, at most two.
    var others: [TodoOfferButton] = []
    var undo = false
    /// "Open Tasks" at the row's start.
    var opensTasks = false
}

/// Each offer as the app last saw it, so a chat's card (made from the bot's tool result, which only ever says
/// "offered") shows what became of it: answered on the Tasks page, on another device, or a day ago.
nonisolated enum TodoOfferStates {
    static let changed = Notification.Name("hq.tasks.offers.changed")
    private static let box = Mutex<(read: Bool, offers: [String: TodoOffer], latest: Set<String>)>((false, [:], []))

    /// The gateway's list (`whole`: every offer it still shows), or the one saved on disk.
    static func note(_ offers: [TodoOffer], whole: Bool) -> Bool {
        box.withLock { box in
            var moved = whole && !box.read
            if whole {
                box.read = true
                let ids = Set(offers.map(\.id))
                if ids != box.latest { box.latest = ids; moved = true }
            }
            for offer in offers where box.offers[offer.id] != offer { box.offers[offer.id] = offer; moved = true }
            return moved
        }
    }

    /// The offer as it stands now. `past`: the gateway's list was read and no longer has it.
    static func shown(_ offer: TodoOffer) -> (offer: TodoOffer, past: Bool) {
        box.withLock { box in
            if let live = box.offers[offer.id] { return (live, false) }
            return (offer, box.read)
        }
    }

    static func forget() {
        box.withLock { $0 = (false, [:], []) }
        goalBox.withLock { $0 = [:] }
        asked.withLock { $0 = [] }
    }

    // MARK: [goals step 3] The goals the cards name, and offers a chat names before the app has read them

    /// Posted when a chat names an offer the app hasn't read (the store reads the list again).
    static let wanted = Notification.Name("hq.tasks.offers.wanted")
    private static let goalBox = Mutex<[String: Goal]>([:])
    private static let asked = Mutex<Set<String>>([])

    /// The store's goals, for the chat's cards (their name, colour, lead and check-in day).
    static func noteGoals(_ goals: [Goal]) {
        goalBox.withLock { $0 = Dictionary(goals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
    }

    static func goal(_ id: String?) -> Goal? { id.flatMap { id in goalBox.withLock { $0[id] } } }

    /// A chat's card names an offer the app hasn't read: asked once per offer.
    static func want(_ id: String) {
        guard asked.withLock({ $0.insert(id).inserted }) else { return }
        DispatchQueue.main.async { NotificationCenter.default.post(name: wanted, object: id) }
    }

    /// [goals step 3] The offer by its id, as the app last saw it; nil before the gateway's list said it (a goal's offer
    /// comes to the chat as its id alone, `goals_offer`'s answer).
    static func live(_ id: String) -> (offer: TodoOffer?, past: Bool) {
        box.withLock { box in (box.offers[id], box.read && !box.latest.contains(id)) }
    }
}
