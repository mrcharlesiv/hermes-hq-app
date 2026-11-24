// [goals step 6] Adding a bot, or a team of bots, to a goal is one obvious tap (docs/goals.md "Step 6"; the owner, after
// the build shipped: there was no easy way to add a bot or a team of bots to a goal). The team sheet: one small sheet in
// the quick add's shape (`QuickAddSheet`), every bot of yours as a row with its face, name and a tick. The first ticked
// leads ("Leads" at its row's end); any other ticked bot's row has Make Lead; unticking the lead hands it to the next.
// One line under the list, then the check-in's day and time (with a lead), and Done. Each change saves as you make it
// (`lead`, `helpers`). It opens from the goal page's Bots row, the goal card's hold menu (Add Bots… / Bots…) and Edit
// Goal's Bots row. When it closes on a goal that just got its first lead and has no plan, the goal reopens on its chat
// and the lead is asked for a plan (`GoalPlanAsks`), as New Goal with a lead does.

import SwiftUI
import UIKit

// MARK: - Asking a new lead for a plan

/// [goals step 6] A goal with a new first lead and no plan: it reopens on its chat with the lead asked
/// (`GoalBots.planRequest`, your bubble the goal's name). The same ask is never sent twice in a minute (`GoalPlanGuard`).
@MainActor
enum GoalPlanAsks {
    private static var guard_ = GoalPlanGuard()

    /// Whether the plan ask for this goal may go now (and notes it as sent).
    static func mayAsk(_ goalID: String, now: Date = Date()) -> Bool { guard_.mayAsk(goalID, now: now) }

    static func recentlyAsked(_ goalID: String, now: Date = Date()) -> Bool { guard_.recentlyAsked(goalID, now: now) }

    /// A sheet that can give a goal its lead closed (Edit Goal, the team sheet). `before`: the lead when it opened;
    /// `team`: the team as it stands now (the store may not have every change yet).
    static func sheetClosed(goalID: String, before: String?, team: GoalTeamPick? = nil, store: TasksStore) {
        guard store.goalBotsSupported, var goal = store.goal(goalID) else { return }
        if let team { goal.lead = team.lead; goal.helpers = team.helpers }
        guard GoalPlanAsk.asksNewLead(before: before, goal: goal, tasks: store.tasks, offers: store.offers) else { return }
        guard !recentlyAsked(goalID) else { return }
        AppLog.note("goals", "a new lead on a goal with no plan: its chat opens and the lead is asked")
        TasksHub.openGoal(goalID, chat: true, plan: goal.title)
    }
}

/// [goals step 6] New Goal's Who's helping? pick, remembered on this device: nothing the first time, "" for Just Me.
@MainActor
enum GoalPlanWithMemory {
    private static let key = "goals.planWith"

    static var remembered: [String]? { GoalPlanWith.read(UserDefaults.standard.string(forKey: key)) }

    static func remember(_ team: [String]) { UserDefaults.standard.set(GoalPlanWith.stored(team), forKey: key) }

    /// `-HQPagesForgetGoalPlanWith YES` (debug): the first time again.
    static func forget() { UserDefaults.standard.removeObject(forKey: key) }
}

// MARK: - The team sheet

@MainActor @Observable
final class GoalTeamModel {
    let store: TasksStore
    let goalID: String
    let bots: [(id: String, name: String, head: JSONValue?)]
    /// The ticks as they stand here (each one saved as you make it, one PATCH after another).
    var pick: GoalTeamPick
    /// The lead when the sheet opened: a first lead on a goal with no plan asks it for one when the sheet closes.
    @ObservationIgnored let leadAtOpen: String?
    /// Opened over Edit Goal: Edit Goal's own close asks, not this one.
    @ObservationIgnored let asksOnClose: Bool
    @ObservationIgnored private var saved: GoalTeamPick
    @ObservationIgnored private var sending = false
    @ObservationIgnored weak var controller: UIViewController?

    init(store: TasksStore, goalID: String, asksOnClose: Bool, bots: [Bot] = MorePages.context?.bots ?? []) {
        self.store = store
        self.goalID = goalID
        self.asksOnClose = asksOnClose
        self.bots = bots.map { ($0.id, PagesNames.botName($0.id, bots: bots), $0.head) }
        let now = store.goal(goalID).map(GoalTeamPick.init) ?? GoalTeamPick(lead: nil, helpers: [])
        pick = now
        saved = now
        leadAtOpen = now.lead
    }

    var goal: Goal? { store.goal(goalID) }

    func name(_ id: String) -> String { bots.first { $0.id == id }?.name ?? PagesNames.botName(id, bots: []) }

    func toggle(_ id: String) {
        PagesHaptics.selection()
        let had = pick.has(id)
        HQMotion.withAnimation(.snappy) { pick.toggle(id) }
        HQAnnounce.say(had ? "\(name(id)) is off this goal" : (pick.lead == id ? "\(name(id)) leads" : "\(name(id)) is on this goal"))
        save()
    }

    func makeLead(_ id: String) {
        PagesHaptics.selection()
        HQMotion.withAnimation(.snappy) { pick.makeLead(id) }
        HQAnnounce.say("\(name(id)) leads")
        save()
    }

    func setReview(_ review: GoalReview?) {
        PagesHaptics.selection()
        Task { if await !store.patchGoal(goalID, ["review": review?.json ?? .null]) { PagesHaptics.error() } }
    }

    func done() {
        PagesHaptics.selection()
        controller?.dismiss(animated: true)
    }

    /// One PATCH at a time, each on the goal's latest rev (quick ticks sent together would meet a 409).
    private func save() {
        guard !sending else { return }
        let fields = pick.fields(from: saved)
        guard !fields.isEmpty else { return }
        sending = true
        let sent = pick
        Task {
            if await store.patchGoal(goalID, fields) {
                saved = sent
            } else {
                PagesHaptics.error()
                let now = store.goal(goalID).map(GoalTeamPick.init) ?? sent
                saved = now
                HQMotion.withAnimation(.snappy) { pick = now }
            }
            sending = false
            save()
        }
    }

    /// Waits (a few seconds at most) for the ticks still being saved.
    func settle() async {
        for _ in 0..<100 where sending || !pick.fields(from: saved).isEmpty {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @ObservationIgnored private var didClose = false

    func closed() {
        guard asksOnClose, !didClose else { return }
        didClose = true
        let goalID = goalID, before = leadAtOpen, store = store
        Task { @MainActor in
            await settle()
            GoalPlanAsks.sheetClosed(goalID: goalID, before: before, team: pick, store: store)
        }
    }
}

enum GoalTeamSheet {
    /// `asksOnClose`: false over Edit Goal (its own close asks).
    @MainActor
    static func make(goalID: String, store: TasksStore, asksOnClose: Bool = true) -> UIViewController {
        GoalTeamHost(model: GoalTeamModel(store: store, goalID: goalID, asksOnClose: asksOnClose))
    }

    /// From a goal card's hold menu, ⋯, the page's Bots row, or Edit Goal.
    @MainActor
    static func present(goalID: String, store: TasksStore, from presenter: UIViewController, asksOnClose: Bool = true) {
        guard store.goal(goalID) != nil else { return }
        PagesHaptics.selection()
        var top = presenter
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        top.present(make(goalID: goalID, store: store, asksOnClose: asksOnClose), animated: true)
    }
}

final class GoalTeamHost: UIHostingController<HQScaledRoot<GoalTeamView>> {
    let model: GoalTeamModel
    private var fitted: CGFloat = 320

    init(model: GoalTeamModel) {
        self.model = model
        super.init(rootView: HQScaledRoot(GoalTeamView(model: model)))
        model.controller = self
        rootView = HQScaledRoot(GoalTeamView(model: model, onHeight: { [weak self] in self?.fit($0) }))
        QuickAddSheet.configure(self, identifier: "goal.team") { [weak self] in self?.fitted ?? 320 }
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func fit(_ height: CGFloat) { QuickAddSheet.fit(self, height, fitted: fitted) { fitted = $0 } }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Closed (Done, a tap outside, a pull down), or gone with the page under it.
        if isBeingDismissed || presentingViewController == nil { model.closed() }
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        let close = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeFromKeyboard))
        close.wantsPriorityOverSystemBehavior = true
        commands.append(close)
        return commands
    }
    override var canBecomeFirstResponder: Bool { true }
    @objc private func closeFromKeyboard() { dismiss(animated: true) }
}

struct GoalTeamView: View {
    @Bindable var model: GoalTeamModel
    var onHeight: (CGFloat) -> Void = { _ in }
    @ScaledMetric(relativeTo: .body) private var faceSize: CGFloat = 28

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Bots")
                        .font(Font.hq(.subheadline).weight(.semibold))
                        .foregroundStyle(Color.hqLabel2)
                        .accessibilityAddTraits(.isHeader)
                    if let title = model.goal?.title {
                        Text(title).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel3).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if DeviceWord.isMac {
                        Button { model.done() } label: {
                            Image(systemName: "xmark").font(Font.hq(.footnote).weight(.semibold)).foregroundStyle(Color.hqLabel2)
                                .frame(width: 24, height: 24).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hqIconLabel("Close")
                        .accessibilityIdentifier("sheet.close")
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 6)

                ForEach(model.bots, id: \.id) { bot in row(bot) }

                Text(GoalBots.teamNote)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .accessibilityIdentifier("goal.team.note")

                HStack(spacing: 8) {
                    if model.pick.lead != nil { reviewMenu }
                    Spacer(minLength: 8)
                    Button { model.done() } label: {
                        Text("Done")
                            .font(Font.hq(.subheadline).weight(.semibold))
                            .foregroundStyle(Color.hqOnTint)
                            .padding(.horizontal, 18)
                            .frame(minHeight: 36)
                            .background(Capsule().fill(Color.hqTint))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("goal.team.done")
                }
                .padding(.top, 12)
                .padding(.bottom, 14)
            }
            .padding(.leading, 18)
            .padding(.trailing, 18 + ScrollBarLane.listTrailing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func row(_ bot: (id: String, name: String, head: JSONValue?)) -> some View {
        let on = model.pick.has(bot.id)
        let leads = model.pick.lead == bot.id
        return HStack(spacing: 10) {
            Button { model.toggle(bot.id) } label: {
                HStack(spacing: 10) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(Font.hq(.title3))
                        .foregroundStyle(on ? Color.hqTint : Color.hqLabel3)
                        .accessibilityHidden(true)
                    HeadImage(raw: bot.head, profile: bot.id, size: faceSize).frame(width: faceSize, height: faceSize).accessibilityHidden(true)
                    Text(bot.name).font(Font.hq(.body)).foregroundStyle(Color.hqLabel).lineLimit(1)
                    Spacer(minLength: 8)
                    if leads {
                        Text("Leads").font(Font.hq(.footnote).weight(.medium)).foregroundStyle(Color.hqLabel2)
                            .accessibilityIdentifier("goal.team.leads.\(bot.id)")
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.pick.spoken(bot.id, name: bot.name))
            .accessibilityHint(on ? "Takes it off this goal" : "Puts it on this goal")
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(on ? .isSelected : [])
            .accessibilityAction(named: "Make Lead") { if on && !leads { model.makeLead(bot.id) } }
            .accessibilityIdentifier("goal.team.row.\(bot.id)")
            if on && !leads {
                Button { model.makeLead(bot.id) } label: {
                    Text("Make Lead")
                        .font(Font.hq(.footnote).weight(.medium))
                        .foregroundStyle(Color.hqTintText)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 30)
                        .background(Capsule().fill(Color.hqFill3))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Make \(bot.name) the Lead")
                .accessibilityIdentifier("goal.team.make-lead.\(bot.id)")
                .transition(.opacity)
            }
        }
    }

    /// The check-in's day and time, with a lead (the add-on's first slot comes with the lead).
    private var reviewMenu: some View {
        let words = GoalBots.reviewWords(model.goal?.review)
        return Menu {
            Button("Off") { model.setReview(nil) }
            ForEach(Array(GoalBots.weekdays.enumerated()), id: \.offset) { day, name in
                Menu(name + "s") {
                    ForEach(GoalBots.reviewTimes, id: \.self) { time in
                        Button(GoalBots.time(time)) { model.setReview(GoalReview(day: day, time: time)) }
                    }
                }
            }
        } label: {
            QuickAddChip(words: words == "Off" ? "Check-in Off" : "Check-in " + words, symbol: "calendar.badge.clock", set: words != "Off")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Check-in, \(words)")
        .accessibilityHint("When the lead checks in each week")
        .accessibilityIdentifier("goal.team.review")
    }
}
