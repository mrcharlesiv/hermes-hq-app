// [goals] A goal's page (docs/goals.md "A goal's page", board 2's left and middle phones): a sheet over the Tasks page,
// as a task's is. The bar: back, a "Goal" capsule with the goal's mark, ⋯ (the hold menu's rows). The page itself is
// `GoalPlainView`, drawn from a task's page's rows. This file holds what the page does: its model (edits, ticks with
// the dust, the offers' answers, the sheets it opens) and the rows of ⋯ (`GoalMenu`, a card's hold menu too).

import SwiftUI
import UIKit

/// Where "Add a task" is open: under a milestone, or under No Milestone (or Tasks).
enum GoalAddSpot: Hashable {
    case milestone(String)
    case loose
}

@MainActor @Observable
final class GoalPageModel {
    let goalID: String
    let store: TasksStore
    let context: MorePages.Context
    @ObservationIgnored weak var controller: UIViewController?
    var notice: String?
    @ObservationIgnored private var noticeWork: DispatchWorkItem?
    /// Tasks ticked here: drawn ticked until they move (to done, under the milestone's count).
    var ticking: Set<String> = []
    /// Rows whose picture is in the air as dust (drawn empty until the list has closed behind them).
    var dusted: Set<String> = []
    /// Milestones a tap opened (true) or closed (false); the rest follow the rule (the current one open).
    var opened: [String: Bool] = [:]
    /// Not Yet answers on this device (`GoalNotYet`).
    var notYet = GoalNotYet.all
    var editingTitle = false
    var titleDraft = ""
    var editingWhy = false
    var whyDraft = ""
    var adding: GoalAddSpot?
    var newTask = ""
    var savingTask = false
    var addingMilestone = false
    var newMilestone = ""
    /// The rows' frames in the page's own coordinates (for the dust).
    @ObservationIgnored var rowFrames: [String: CGRect] = [:]
    @ObservationIgnored private var lastSeen: Goal?

    // [goals step 3] A goal with a lead: its own chat under the page (GoalChatPage), or beside it on the Mac.
    @ObservationIgnored var embedded = false
    /// [tasks-first] The chat's activity chips over the view's message box: the view leaves that much at its foot.
    var shelfRoom: CGFloat = 0
    @ObservationIgnored weak var chat: ChatViewController?
    /// The Mac's pane chat, kept by the page (`chat` is weak).
    @ObservationIgnored var keptChat: ChatViewController?
    var split = false
    /// The goal rolled up to its bar (you took up the chat).
    var tucked = false { didSet { if tucked != oldValue { syncComposer(); onTuckChange?() } } }
    @ObservationIgnored var onTuckChange: (() -> Void)?
    /// Keep Going on this device (an add-on before 0.9.66).
    var keptHere = GoalKeptHere.all
    /// Goal offers being answered here.
    var answering: Set<String> = []
    var pageLoading = false
    @ObservationIgnored private weak var pageSheet: HTMLPageSheet?
    @ObservationIgnored private var pageRev = 0

    #if DEBUG
    static weak var debugLast: GoalPageModel?
    #endif

    init(goalID: String, store: TasksStore, context: MorePages.Context) {
        self.goalID = goalID
        self.store = store
        self.context = context
        #if DEBUG
        Self.debugLast = self
        #endif
    }

    /// The goal (as it was last seen once deleted elsewhere, so the page stays readable until it closes).
    var goal: Goal? {
        if let goal = store.goal(goalID) { lastSeen = goal; return goal }
        return lastSeen
    }

    var gone: Bool { store.hasList && store.goal(goalID) == nil }
    var tasks: [TodoTask] { store.tasks }
    var readOnly: Bool { store.readOnlyGateway }

    func botName(_ profile: String?) -> String { PagesNames.botName(profile ?? "default", bots: context.bots) }
    func head(_ profile: String) -> JSONValue? { PagesNames.head(profile, bots: context.bots) }

    func show(_ text: String) {
        notice = text
        noticeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.notice = nil }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        HQAnnounce.say(text)
    }

    func isOpen(_ milestone: GoalMilestone, in goal: Goal) -> Bool {
        opened[milestone.id] ?? (milestone.id == GoalViews.current(goal)?.id)
    }

    func toggleOpen(_ milestone: GoalMilestone, in goal: Goal) {
        PagesHaptics.selection()
        let open = isOpen(milestone, in: goal)
        HQMotion.withAnimation(.snappy) { opened[milestone.id] = !open }
    }

    // MARK: Edits

    func patch(_ fields: [String: JSONValue]) {
        Task { if await !store.patchGoal(goalID, fields) { PagesHaptics.error() } }
    }

    func editTitle() {
        guard let goal, !gone, !readOnly else { return }
        titleDraft = goal.title
        editingTitle = true
    }

    func saveTitle() {
        guard editingTitle else { return }
        editingTitle = false
        let clean = String(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !clean.isEmpty, clean != goal?.title else { return }
        PagesHaptics.selection()
        patch(["title": .string(clean)])
    }

    func editWhy() {
        guard let goal, !gone, !readOnly else { return }
        whyDraft = goal.why
        editingWhy = true
    }

    func saveWhy() {
        guard editingWhy else { return }
        editingWhy = false
        let clean = String(whyDraft.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ").prefix(300))
        guard clean != goal?.why else { return }
        PagesHaptics.selection()
        patch(["why": .string(clean)])
    }

    func setDue(_ date: Date?) {
        PagesHaptics.selection()
        patch(["due": TodoWire.optional(date.map { TodoViews.dayKey(Calendar.current.startOfDay(for: $0), calendar: .current) })])
    }

    func setStatus(_ status: GoalState) {
        GoalMenu.setStatus(status, goalID: goalID, store: store)
    }

    /// The date row's "Choose Date…", and + Date.
    func pickDate() {
        guard let controller, let goal else { return }
        let picker = TodoDatePicker.make(date: goal.due.flatMap { TodoDates.day(String($0.prefix(10))) }, hasTime: false, dayOnly: true,
                                         title: "By", note: "The day you want this done by. Pace is measured against it.") { [weak self] date, _ in
            self?.setDue(date)
        }
        controller.present(picker, animated: true)
    }

    // MARK: Milestones

    private func saveMilestones(_ list: [GoalMilestone]) {
        patch(["milestones": GoalWire.milestones(list)])
    }

    func toggleMilestone(_ milestone: GoalMilestone) {
        guard let goal, !gone, !readOnly else { return }
        if milestone.done { PagesHaptics.selection() } else { PagesHaptics.success() }
        saveMilestones(goal.milestones.map { item in
            var item = item
            if item.id == milestone.id { item.done.toggle() }
            return item
        })
        if !milestone.done { HQAnnounce.say("Done: \(milestone.title)") }
    }

    func addMilestone() {
        let clean = String(newMilestone.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        newMilestone = ""
        guard let goal, !clean.isEmpty, goal.milestones.count < 30 else { return }
        PagesHaptics.selection()
        saveMilestones(goal.milestones + [GoalMilestone(id: TodoIDs.local(), title: clean, due: nil, done: false, doneAt: nil)])
    }

    func moveMilestone(_ milestone: GoalMilestone, by offset: Int) {
        guard var list = goal?.milestones, let at = list.firstIndex(where: { $0.id == milestone.id }) else { return }
        let to = at + offset
        guard list.indices.contains(to) else { return }
        PagesHaptics.selection()
        list.swapAt(at, to)
        saveMilestones(list)
    }

    func renameMilestone(_ milestone: GoalMilestone) {
        askName(title: "Rename Milestone", name: milestone.title, action: "Rename") { [weak self] name in
            guard let self, let goal = self.goal else { return }
            self.saveMilestones(goal.milestones.map { item in
                var item = item
                if item.id == milestone.id { item.title = String(name.prefix(120)) }
                return item
            })
        }
    }

    func setMilestoneDate(_ milestone: GoalMilestone) {
        guard let controller else { return }
        let picker = TodoDatePicker.make(date: milestone.due.flatMap { TodoDates.day(String($0.prefix(10))) }, hasTime: false, dayOnly: true,
                                         title: "Milestone Date", note: "When you want “\(milestone.title)” done.") { [weak self] date, _ in
            guard let self, let goal = self.goal else { return }
            PagesHaptics.selection()
            let day = TodoViews.dayKey(Calendar.current.startOfDay(for: date), calendar: .current)
            self.saveMilestones(goal.milestones.map { item in
                var item = item
                if item.id == milestone.id { item.due = day }
                return item
            })
        }
        controller.present(picker, animated: true)
    }

    func clearMilestoneDate(_ milestone: GoalMilestone) {
        guard let goal else { return }
        PagesHaptics.selection()
        saveMilestones(goal.milestones.map { item in
            var item = item
            if item.id == milestone.id { item.due = nil }
            return item
        })
    }

    /// Asks first; its tasks stay in the goal, under No Milestone.
    func deleteMilestone(_ milestone: GoalMilestone) {
        guard let controller else { return }
        let alert = UIAlertController(title: "Delete “\(milestone.title)”?", message: "Its tasks stay in this goal, under No Milestone.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete Milestone", style: .destructive) { [weak self] _ in
            guard let self, let goal = self.goal else { return }
            PagesHaptics.success()
            self.saveMilestones(goal.milestones.filter { $0.id != milestone.id })
        })
        controller.present(alert, animated: true)
    }

    // MARK: Tasks

    /// "Add a task" under a milestone (or none): an ordinary task of yours, in this goal.
    func addTask() {
        let draft = newTask
        let clean = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let spot = adding, !clean.isEmpty, !savingTask else { return }
        PagesHaptics.selection()
        var milestone: String?
        if case .milestone(let id) = spot { milestone = id }
        // Inline entry has no parsing preview: save the exact words rather than silently extracting fields.
        let body = TodoWire.newTask(title: clean, who: .me, bot: nil, due: nil, repeatRule: nil,
                                    prep: false, goal: goalID, milestone: milestone)
        savingTask = true
        Task {
            let made = await store.add(body)
            savingTask = false
            if made == nil { PagesHaptics.error(); return }
            if newTask == draft { newTask = "" }
        }
    }

    func openTask(_ id: String) {
        guard let controller else { return }
        PagesHaptics.selection()
        let sheet = TodoSheet.make(taskID: id, store: store, context: context)
        controller.present(sheet, animated: true)
    }

    /// Ticks a task (or opens it again). The circle fills and the row turns to dust over the page (not under Reduce
    /// Motion), then the save moves it.
    func toggleTask(_ id: String) {
        guard let task = store.task(id) else { return }
        if task.isDone {
            PagesHaptics.selection()
            Task { if await !store.setDone(id, false) { PagesHaptics.error() } }
            return
        }
        PagesHaptics.success()
        ticking.insert(id)
        HQAnnounce.say("Done: \(task.title)")
        DispatchQueue.main.asyncAfter(deadline: .now() + (HQMotion.reduced ? 0.1 : TaskCheckOff.tick)) { [weak self] in
            guard let self else { return }
            let blown = self.blowAway(id)
            Task {
                if blown { try? await Task.sleep(for: .seconds(TaskCheckOff.sweep * 0.8)) }
                if await !self.store.setDone(id, true) { PagesHaptics.error() }
                self.ticking.remove(id)
                try? await Task.sleep(for: .seconds(0.35))
                self.dusted.remove(id)
            }
        }
    }

    private func blowAway(_ id: String) -> Bool {
        // The row's frame was taken in the window's space (SwiftUI's global one).
        guard !HQMotion.reduced, let view = controller?.view, view.window != nil, let global = rowFrames[id] else { return false }
        let frame = view.convert(global, from: nil)
        guard view.bounds.intersects(frame), TaskDust.play(area: frame, of: view) else { return false }
        dusted.insert(id)
        return true
    }

    // MARK: Offers (rule 5)

    func offer(_ goal: Goal) -> GoalOffer? {
        GoalViews.offer(goal, tasks: tasks, notYet: notYet)
    }

    func answer(_ offer: GoalOffer, yes: Bool) {
        guard let goal else { return }
        guard yes else {
            PagesHaptics.selection()
            GoalNotYet.remember(offer, goal: goal, tasks: tasks)
            HQMotion.withAnimation(.snappy) { notYet = GoalNotYet.all }
            return
        }
        switch offer {
        case .milestone(let milestone): toggleMilestone(milestone)
        case .achieved: setStatus(.achieved)
        }
    }

    // MARK: Sheets

    func updateNumber() {
        guard let controller, let goal, let measure = goal.measure, !readOnly else { return }
        PagesHaptics.selection()
        // [goals step 3] A number a bot reads: setting it by hand makes the number yours, after asking.
        if let bot = measure.source.bot, store.goalBotsSupported {
            let alert = UIAlertController(title: "Set It Yourself?",
                                          message: "\(botName(bot)) reads this number\(measure.source.what.isEmpty ? "" : " from \(measure.source.what)"). If you set it, the number is yours from now on and \(botName(bot)) stops reading it.",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Set It Myself", style: .default) { [weak self] _ in
                guard let self, let controller = self.controller, let goal = self.goal else { return }
                controller.present(GoalUpdateSheet.make(goal: goal) { [weak self] value in
                    self?.patch(["measure": .object(["source": .string("you")]), "measure_now": .number(value)])
                }, animated: true)
            })
            controller.present(alert, animated: true)
            return
        }
        controller.present(GoalUpdateSheet.make(goal: goal) { [weak self] value in
            self?.patch(["measure_now": .number(value)])
        }, animated: true)
    }

    /// + Number, and the number row's Edit Number…: unit, from, to (and where it stands now).
    func editNumber() {
        guard let controller, let goal, !readOnly else { return }
        PagesHaptics.selection()
        controller.present(GoalNumberSheet.make(measure: goal.measure, title: goal.measure == nil ? "Add a Number" : "Edit Number") { [weak self] measure in
            self?.patch(["measure": GoalWire.measure(measure)])
        }, animated: true)
    }

    func removeNumber() {
        guard let controller else { return }
        let alert = UIAlertController(title: "Remove the Number?", message: "The ring follows the milestones, or the tasks, instead.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Remove Number", style: .destructive) { [weak self] _ in
            PagesHaptics.success()
            self?.patch(["measure": .null])
        })
        controller.present(alert, animated: true)
    }

    func editGoal() {
        guard let controller else { return }
        GoalMenu.edit(goalID: goalID, store: store, from: controller)
    }

    // MARK: [goals step 6] The Bots row and the plan ask

    /// Your bots (for the Bots row's Add Bots and the team sheet).
    var hasBots: Bool { !context.bots.isEmpty }

    /// The Bots row: the team sheet. It closes on a goal that just got its first lead and has no plan: the goal reopens
    /// on its chat and the lead is asked for one.
    func openTeam() {
        guard let top else { return }
        GoalTeamSheet.present(goalID: goalID, store: store, from: top)
    }

    /// "No plan yet" and "Ask <Bot> for a Plan" where the milestones would be: a lead, its chat here, and no plan.
    var showsPlanAsk: Bool {
        guard store.goalBotsSupported, let goal, !gone, chat != nil, embedded || split else { return false }
        return GoalPlanAsk.showsAsk(goal, tasks: tasks, offers: store.offers)
    }

    /// Ask <Bot> for a Plan: the goal's chat takes the screen and the lead is sent the plan request (your bubble the
    /// goal's name). Never twice in a minute (`GoalPlanAsks`).
    func askForPlan() {
        guard let goal, let chat, lead != nil else { return }
        PagesHaptics.selection()
        guard GoalPlanAsks.mayAsk(goalID) else {
            show("Already asked \(botName(goal.lead)) for a plan.")
            return
        }
        if embedded { tuck(.send) }
        sendHidden(GoalBots.planRequest(goal, typed: goal.title, now: Date()), display: goal.title, in: chat)
        AppLog.note("goals", "plan asked of the goal's lead from its page")
    }

    // MARK: [goals step 3] Bots on the goal

    /// Bot names and faces by id, for the cards.
    var botNames: [String: String] { Dictionary(context.bots.map { ($0.id, botName($0.id)) }, uniquingKeysWith: { a, _ in a }) }
    var botHeads: [String: JSONValue] {
        Dictionary(context.bots.compactMap { bot in bot.head.map { (bot.id, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    /// The goal's lead, while the add-on says goals have bots and the bot is one of yours.
    var lead: String? {
        guard store.goalBotsSupported, let lead = goal?.lead else { return nil }
        return lead
    }

    /// The goal's offers: what waits for it, and what you accepted (its card keeps Undo).
    var offers: [TodoOffer] { store.goalBotsSupported ? GoalOffers.onGoal(store.offers, goal: goalID) : [] }

    func offerCard(_ offer: TodoOffer) -> GoalOfferCardModel {
        let live = TodoOfferStates.live(offer.id)
        let shown = store.offers.first { $0.id == offer.id } ?? live.offer ?? offer
        return GoalOfferCardModel(offer: shown, goal: goal,
                                  kicker: shown.kind == "checkin" ? GoalOffers.checkinHead(shown, goal: goal, botName: botName) : nil,
                                  botName: botName(shown.bot), head: head(shown.bot), busy: answering.contains(offer.id),
                                  foot: GoalOffers.foot(shown, past: false), lead: goal?.lead, names: botNames, heads: botHeads)
    }

    func answerOffer(_ offer: TodoOffer, _ button: GoalOfferButton) {
        guard let action = button.action else { changeOffer(); return }
        answerOffer(offer.id, action, plan: button.plan, inGoal: button.inGoal)
    }

    func answerOffer(_ id: String, _ action: TodoOfferAction, plan: Bool = true, inGoal: Bool = true) {
        guard !answering.contains(id) else { return }
        PagesHaptics.selection()
        answering.insert(id)
        Task {
            let ok = await store.answerOffer(id, action, plan: plan, inGoal: inGoal)
            answering.remove(id)
            if ok { PagesHaptics.success() } else { PagesHaptics.error() }
        }
    }

    /// Change It / Change: the goal's chat takes the cursor.
    func changeOffer() {
        PagesHaptics.selection()
        if let chat, embedded || split {
            if embedded { tuck(.chat) }
            chat.focusComposer()
        }
    }

    func showWholeOffer(_ offer: TodoOffer) {
        guard let top else { return }
        PagesHaptics.selection()
        top.present(GoalOfferAllSheet.make(offer, goal: goal, botName: botName), animated: true)
    }

    /// The lead's "this looks done": Mark Done (or Mark Achieved) / Not Yet.
    func answerLooksDone(_ done: Bool) {
        if done { PagesHaptics.success() } else { PagesHaptics.selection() }
        Task { if await !store.answerLooksDone(goalID, done: done) { PagesHaptics.error() } }
        if done { HQAnnounce.say("Done") }
    }

    // MARK: [goals step 4] The stall question

    func stall(_ goal: Goal) -> GoalStall? {
        GoalViews.stalled(goal, tasks: tasks, now: Date(), keptHere: keptHere[goalID])
    }

    /// Smaller Step: with a lead, the bot is asked for one in the goal's chat; else New Task under the goal.
    func smallerStep(_ stall: GoalStall) {
        guard let goal else { return }
        PagesHaptics.selection()
        if lead != nil, let chat, embedded || split {
            if embedded { tuck(.send) }
            sendHidden(GoalBots.smallerStepRequest(goal, stall: stall), display: "A smaller first step, please", in: chat)
            return
        }
        // No bot: the goal's own "Add a task" opens where the next task stands (its milestone, or none).
        let spot: GoalAddSpot = stall.task?.milestone.flatMap { id in goal.milestone(id).map { _ in .milestone(id) } } ?? .loose
        if case .milestone(let id) = spot { opened[id] = true }
        HQMotion.withAnimation(.snappy) { adding = spot }
    }

    /// Keep Going: `keep: true` on 0.9.66; on this device only before it.
    func keepGoing() {
        PagesHaptics.selection()
        GoalKeptHere.remember(goalID)
        HQMotion.withAnimation(.snappy) { keptHere = GoalKeptHere.all }
        guard store.goalBotsSupported else { return }
        Task { if await !store.keepGoing(goalID) { PagesHaptics.error() } }
    }

    // MARK: [goals step 5] The Goal Page

    var offersGoalPage: Bool { store.goalPagesSupported && !TodoIDs.isLocal(goalID) }

    /// ⋯ › Goal Page and the stands card's Page ›: the add-on's page in the page sheet, drawn again when the goal moves.
    /// Its Ask for an Update asks the lead in the goal's chat (a hidden turn).
    func openGoalPage() {
        guard let goal, !pageLoading, offersGoalPage else { return }
        Haptics.play(.selection)
        pageLoading = true
        let id = goal.id, api = store.api
        let names = botNames
        let read: @MainActor () async throws -> URL = { [weak self] in
            let data = try await api.goalPage(id, names: names)
            return try TodoSheetModel.pageFile(id: id, title: self?.goal?.title ?? "", data: data)
        }
        Task { [weak self] in
            defer { self?.pageLoading = false }
            do {
                let url = try await read()
                guard let self, let top = self.top, top.view.window != nil else { return }
                let profile = self.goal?.lead ?? "default"
                let chat = self.lead != nil ? self.chat : nil
                let send: ((String) -> Void)? = chat.map { chat in { [weak self, weak chat] prompt in
                    guard let chat else { return }
                    self?.sendHidden(prompt, display: nil, in: chat)
                } }
                let context = chat?.mediaContext ?? MediaContext(accountId: self.context.account.id, profile: profile)
                let source = HTMLPageSheet.Source(path: "goal-page:" + id, context: context, send: send,
                                                  botName: self.botName(profile), read: read)
                self.pageRev = self.goal?.rev ?? 0
                self.pageSheet = HTMLPageSheet.present(url, source: source, title: "Goal Page", from: top)
                AppLog.note("goals", "goal page opened (talk-back \(send == nil ? "off" : "on"))")
            } catch {
                guard let self else { return }
                PagesHaptics.error()
                self.show("Couldn’t open the Goal Page. \(PagesREST.reason(error))")
                AppLog.note("goals", "goal page not read: \(PagesREST.reason(error))")
            }
        }
    }

    /// [goals set-up] The goal's chat is headed by the goal's name as it is now, its bot under it: a plan's name or Edit
    /// Goal renames it while the chat is open, and a reopened chat starts from it too.
    func syncChatName() {
        guard let chat, let goal else { return }
        chat.shownName = goal.title.isEmpty ? nil : goal.title
    }

    /// The goal moved while its page is open: the page is drawn again.
    func goalChanged(_ rev: Int) {
        guard let page = pageSheet, page.view.window != nil, rev != pageRev else { return }
        pageRev = rev
        page.readAgain(note: nil)
    }

    /// Ask for an Update from ⋯ (the Goal Page has its own): a hidden turn in the goal's chat.
    func askForUpdate() {
        guard let goal, let chat, lead != nil else { return }
        PagesHaptics.selection()
        sendHidden(GoalBots.updateRequest(goal), display: nil, in: chat)
        show("Asked \(botName(goal.lead)) for an update.")
    }

    /// A turn the bot reads and you don't see as a bubble (or see as `display`).
    func sendHidden(_ prompt: String, display: String?, in chat: ChatViewController) {
        if let display {
            // The stored turn holds the whole ask: the re-read at the reply's end keeps the bubble's words (as a titled
            // request's, SentTitles). A Plan With ask also carries them, so they come back after a relaunch
            // (`GoalBots.planBubble`).
            LiveChatSession.sentTitles.note(text: prompt, title: display)
            chat.sendFromCard(prompt, display: display)
        } else if let provider = chat.session as? ChatActivityProviding {
            provider.sendHidden(prompt, display: nil)
        }
    }

    // MARK: [goals step 3] The goal's chat under the page (as a task's, TaskPage)

    enum TuckReason { case drag, focus, send, find, chat }
    @ObservationIgnored private(set) var tuckReason: TuckReason?

    func syncComposer(animated: Bool = true) {
        guard embedded, let composer = chat?.composer else { return }
        let hidden = !tucked
        composer.isUserInteractionEnabled = !hidden
        composer.accessibilityElementsHidden = hidden
        guard (composer.alpha < 0.5) != hidden else { return }
        UIView.animate(withDuration: animated && !HQMotion.reduced ? 0.2 : 0) {   // motion-ok: a fade, none under Reduce Motion
            composer.alpha = hidden ? 0 : 1
        }
    }

    func tuck(_ reason: TuckReason) {
        guard embedded else { return }
        if tucked {
            if reason == .send || reason == .drag { tuckReason = reason }
            return
        }
        tuckReason = reason
        HQMotion.withAnimation(.snappy) { tucked = true }
    }

    func untuck() {
        guard tucked else { return }
        tuckReason = nil
        if let field = chat?.composer.textView, field.isFirstResponder { field.resignFirstResponder() }
        PagesHaptics.selection()
        HQMotion.withAnimation(.snappy) { tucked = false }
    }

    /// What waits in the chat's box, for the page's one line.
    var draft: String? {
        let words = chat?.composer.textView.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return words.isEmpty ? nil : words.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// The page's one-line message box, tapped: the chat takes the screen with its own box and the keys up.
    func writeMessage() {
        PagesHaptics.selection()
        if split { chat?.focusComposer(); return }
        chat?.focusComposer()   // the field taking the keys rolls the goal up to its bar (`GoalLeadHost.fieldBegan`)
    }

    var top: UIViewController? {
        var shown = controller
        while let next = shown?.presentedViewController, !next.isBeingDismissed { shown = next }
        return shown
    }

    #if DEBUG
    /// `-HQPagesGoalSheet update|edit|number`.
    func debugOpen(_ sheet: String) {
        switch sheet {
        case "update": updateNumber()
        case "edit": editGoal()
        case "number": editNumber()
        case "page": openGoalPage()
        case "chat": tuck(.chat)
        case "ask": askForUpdate()
        case "team": editGoal()
        case "bots": openTeam()   // [goals step 6] the team sheet
        default: break
        }
    }
    #endif

    private func askName(title: String, name: String, action: String, done: @escaping (String) -> Void) {
        guard let controller else { return }
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = name
            field.autocapitalizationType = .sentences
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: action, style: .default) { [weak alert] _ in
            let clean = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !clean.isEmpty, clean != name else { return }
            PagesHaptics.selection()
            done(clean)
        })
        controller.present(alert, animated: true)
    }
}

enum GoalPage {
    /// The goal's page as a sheet. [goals step 3] A goal with a lead is its own chat with the goal laid over it
    /// (`GoalChatPage`); `chat`: opened at the chat (Change, a check-in's push), the goal as its bar.
    static func make(goalID: String, store: TasksStore, context: MorePages.Context, chat: Bool = false) -> UINavigationController {
        let model = GoalPageModel(goalID: goalID, store: store, context: context)
        let root: UIViewController = GoalChatPage.make(model: model) ?? GoalPageHost(model: model)
        let nav = ChatSheet.wrap(root, title: "Goal", detents: [.large()])
        nav.sheetPresentationController?.selectedDetentIdentifier = .large
        if chat, model.embedded { model.tuck(.chat) }
        return nav
    }

    /// [goals step 5] The Mac's two panes: the goal's page in the centre, and with a lead its chat for the right pane
    /// (`MacInspector`'s follow, as a task's).
    static func page(goalID: String, store: TasksStore, context: MorePages.Context, beside: Bool) -> UIViewController {
        let model = GoalPageModel(goalID: goalID, store: store, context: context)
        if beside, GoalChatPage.makeBeside(model: model) != nil { return GoalPageHost(model: model) }
        return GoalChatPage.make(model: model) ?? GoalPageHost(model: model)
    }

    static func model(of page: UIViewController?) -> GoalPageModel? {
        if let host = page as? GoalPageHost { return host.model }
        return ((page as? ChatViewController)?.topAccessory as? GoalLeadHost)?.model
    }
}

final class GoalPageHost: UIHostingController<HQScaledRoot<GoalPlainView>> {
    let model: GoalPageModel
    /// The bar's title: "Goal" with the goal's mark in its colour (where a task's page names its list).
    private let goalTitle = ChatTitleView()
    private let mark = UIImageView()

    init(model: GoalPageModel) {
        self.model = model
        super.init(rootView: HQScaledRoot(GoalPlainView(model: model)))
        model.controller = self
        title = "Goal"
        goalTitle.title = "Goal"
        goalTitle.accessibilityIdentifier = "goal.title-bar"
        mark.contentMode = .scaleAspectFit
        mark.image = UIImage(systemName: "smallcircle.filled.circle",
                             withConfiguration: UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium))
        mark.isAccessibilityElement = false
        goalTitle.accessory = mark
        navigationItem.titleView = goalTitle
        watchGoal()
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                MainActor.assumeIsolated {
                    guard let self, !self.model.gone, !self.model.readOnly else { completion([]); return }
                    completion(GoalMenu.leadItems(model: self.model) + GoalMenu.items(goalID: self.model.goalID, store: self.model.store, from: self, source: nil))
                }
            },
        ]))
        more.accessibilityLabel = "More"
        more.accessibilityIdentifier = "goal.more"
        navigationItem.rightBarButtonItem = more
        #if targetEnvironment(macCatalyst)
        // [goals step 5] A goal with a lead: its chat is the pane beside the goal; ◨ closes it and brings it back.
        if model.split {
            let pane = UIBarButtonItem(image: UIImage(systemName: "sidebar.trailing"), primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                PagesHaptics.selection()
                MacInspector.beside(self)?.toggle()
            })
            pane.accessibilityLabel = "Conversation"
            pane.accessibilityIdentifier = "goal.pane"
            navigationItem.rightBarButtonItems = [pane, more]
        }
        #endif
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The mark follows the goal's colour (Edit Goal here or on another device).
    private func watchGoal() {
        let tint = withObservationTracking { model.goal?.tint ?? .blue } onChange: { [weak self] in
            DispatchQueue.main.async { self?.watchGoal() }
        }
        mark.tintColor = UIColor(tint.ink)
        // ChatTitleView places and sizes its accessory (a square, centred); sizing it here after a layout knocked a new
        // goal's mark into the capsule's corner.
        goalTitle.frame.size = goalTitle.intrinsicContentSize
        goalTitle.setNeedsLayout()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "goal.sheet"
    }
}

/// The rows of a goal's ⋯ and of its card's hold menu: [goals step 6] Add Bots… / Bots… (with the add-on's bots), Edit
/// Goal…, Pause or Resume, Mark Achieved, Let It Go, Delete Goal… (asks first; its tasks are kept). An achieved or
/// let-go goal can be made active again.
@MainActor
enum GoalMenu {
    static func items(goalID: String, store: TasksStore, from presenter: UIViewController, source: UIView?) -> [UIMenuElement] {
        guard let goal = store.goal(goalID) else { return [] }
        // [goals step 6] First: the goal's bots, one tap (the team sheet). "Add Bots…" with none, "Bots…" with some.
        var bots: [UIMenuElement] = []
        if store.goalBotsSupported, !(MorePages.context?.bots ?? []).isEmpty {
            bots.append(UIMenu(options: .displayInline, children: [
                UIAction(title: goal.team.isEmpty ? "Add Bots…" : "Bots…", image: UIImage(systemName: "person.2")) { [weak presenter] _ in
                    guard let presenter else { return }
                    GoalTeamSheet.present(goalID: goalID, store: store, from: presenter)
                },
            ]))
        }
        var states: [UIMenuElement] = []
        switch goal.state {
        case .active:
            states.append(UIAction(title: "Pause", image: UIImage(systemName: "pause.circle")) { _ in setStatus(.paused, goalID: goalID, store: store) })
        case .paused:
            states.append(UIAction(title: "Resume", image: UIImage(systemName: "play.circle")) { _ in setStatus(.active, goalID: goalID, store: store) })
        case .achieved, .letGo:
            states.append(UIAction(title: "Make Active Again", image: UIImage(systemName: "arrow.uturn.backward.circle")) { _ in
                setStatus(.active, goalID: goalID, store: store)
            })
        }
        if goal.state != .achieved {
            states.append(UIAction(title: "Mark Achieved", image: UIImage(systemName: "checkmark.seal")) { _ in setStatus(.achieved, goalID: goalID, store: store) })
        }
        if goal.state != .letGo {
            states.append(UIAction(title: "Let It Go", image: UIImage(systemName: "wind")) { _ in setStatus(.letGo, goalID: goalID, store: store) })
        }
        return bots + [
            UIMenu(options: .displayInline, children: [
                UIAction(title: "Edit Goal…", image: UIImage(systemName: "pencil")) { [weak presenter] _ in
                    guard let presenter else { return }
                    edit(goalID: goalID, store: store, from: presenter)
                },
            ]),
            UIMenu(options: .displayInline, children: states),
            UIAction(title: "Delete Goal…", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak presenter, weak source] _ in
                guard let presenter else { return }
                confirmDelete(goalID: goalID, store: store, from: presenter, source: source)
            },
        ]
    }

    /// [goals step 3/5] With a lead (and the add-on's pages): Goal Page and Ask for an Update, first in ⋯.
    static func leadItems(model: GoalPageModel) -> [UIMenuElement] {
        var rows: [UIMenuElement] = []
        if model.offersGoalPage {
            rows.append(UIAction(title: "Goal Page", image: UIImage(systemName: "doc.richtext")) { [weak model] _ in model?.openGoalPage() })
        }
        if model.lead != nil, model.chat != nil {
            rows.append(UIAction(title: "Ask for an Update", image: UIImage(systemName: "arrow.clockwise.circle")) { [weak model] _ in
                model?.askForUpdate()
            })
        }
        return rows.isEmpty ? [] : [UIMenu(options: .displayInline, children: rows)]
    }

    /// A status change, with its own cue: success for Mark Achieved, a tap for the rest.
    static func setStatus(_ status: GoalState, goalID: String, store: TasksStore) {
        if status == .achieved { PagesHaptics.success() } else { PagesHaptics.selection() }
        Task { if await !store.patchGoal(goalID, ["status": .string(status.rawValue)]) { PagesHaptics.error() } }
        let words: String? = switch status {
        case .achieved: "Achieved"
        case .paused: "Paused. It waits under Someday."
        case .letGo: "Let go. It stays under Let Go."
        case .active: nil
        }
        if let words { HQAnnounce.say(words) }
    }

    static func edit(goalID: String, store: TasksStore, from presenter: UIViewController) {
        guard store.goal(goalID) != nil else { return }
        PagesHaptics.selection()
        presenter.present(GoalEditSheet.make(goalID: goalID, store: store) { [weak presenter] in
            guard let presenter else { return }
            confirmDelete(goalID: goalID, store: store, from: presenter, source: nil)
        }, animated: true)
    }

    /// "Delete “…”?" first. Its tasks stay on your list, with no goal. A goal's page closes once it is gone.
    static func confirmDelete(goalID: String, store: TasksStore, from presenter: UIViewController, source: UIView?) {
        guard let goal = store.goal(goalID) else { return }
        // Asked over whatever is on top (Edit Goal, or the page itself).
        var top = presenter
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        let sheet = UIAlertController(title: "Delete “\(goal.title)”?", message: "Its tasks stay on your list, with no goal.",
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Delete Goal", style: .destructive) { [weak presenter] _ in
            Task {
                if await store.deleteGoal(goalID) {
                    PagesHaptics.success()
                    // Close the goal's page (and Edit Goal over it) once the goal is gone.
                    if let page = presenter?.navigationController?.viewControllers.first as? GoalPageHost ?? presenter as? GoalPageHost {
                        // From the sheet's presenter: the page and anything over it (Edit Goal) go together.
                        (page.navigationController?.presentingViewController ?? page.presentingViewController)?.dismiss(animated: true)
                    } else if presenter?.presentedViewController != nil {
                        presenter?.dismiss(animated: true)
                    }
                } else {
                    PagesHaptics.error()
                }
            }
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = source ?? top.view
            popover.sourceRect = source?.bounds ?? CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
        }
        top.present(sheet, animated: true)
    }
}
