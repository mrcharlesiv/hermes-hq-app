// [goals] The Goals view's rows (docs/goals.md "The Goals view", board 1's right-hand phone): a card per goal (the
// ring, the name, one grey line with the pace after it, and under a hairline the goal's next task with its circle),
// Someday's quieter cards, "+ New Goal", and what a goal is when there are none. The list itself is the Tasks page's
// (TasksViewController draws these in its own collection view, under the same views row).

import SwiftUI

/// What a goal's card draws.
struct GoalCardModel: Hashable {
    var id: String
    var title: String
    var color: TodoListColor
    var fraction: Double?
    /// "340 of 1,000 · by Jan 31"; Someday's "Paused Nov 30".
    var line: String
    var pace: GoalPace?
    /// The next task (id, name), for an active goal that has one.
    var next: (id: String, title: String)?
    var quiet: Bool
    /// The ring in grey: paused or let go. An achieved goal's ring stays full in its colour (a full grey ring reads as
    /// an empty one).
    var greyRing = false
    /// The next task was ticked here and is on its way.
    var ticking = false
    var spoken: String
    /// [goals step 3] The bots on the goal (lead first), the lead's orange dot, and their names and faces.
    var team: [String] = []
    var led = false
    var waits = false
    var look = GoalTeamLook()
    /// [goals step 4] "Nothing has moved in 16 days": an orange line under the grey one.
    var stall: String?
    /// [goals set-up] No next task and a plan offer waits: the next-step line reads "Plan to look at".
    var planWaits = false

    static func == (a: GoalCardModel, b: GoalCardModel) -> Bool {
        a.id == b.id && a.title == b.title && a.color == b.color && a.fraction == b.fraction && a.line == b.line && a.pace == b.pace
            && a.next?.id == b.next?.id && a.next?.title == b.next?.title && a.quiet == b.quiet && a.greyRing == b.greyRing && a.ticking == b.ticking && a.spoken == b.spoken
            && a.team == b.team && a.led == b.led && a.waits == b.waits && a.look == b.look && a.stall == b.stall && a.planWaits == b.planWaits
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(line); hasher.combine(next?.id) }

    /// `bots`: the add-on knows goals' bots (`goal_bots`). `keptHere`: Keep Going on this device (`GoalKeptHere`).
    static func make(_ goal: Goal, tasks: [TodoTask], now: Date, ticking: Set<String>, bots: Bool = false,
                     offers: [TodoOffer] = [], look: GoalTeamLook = GoalTeamLook(), keptHere: Date? = nil) -> GoalCardModel {
        let active = goal.state == .active
        let next = active ? GoalViews.nextTask(goal, tasks: tasks) : nil
        var card = GoalCardModel(id: goal.id, title: goal.title.isEmpty ? "Untitled Goal" : goal.title, color: goal.tint,
                             fraction: GoalViews.fraction(goal, tasks: tasks),
                             line: active ? GoalViews.line(goal, tasks: tasks, now: now) : (GoalViews.statusLine(goal, now: now) ?? ""),
                             pace: GoalViews.pace(goal, tasks: tasks, now: now),
                             next: next.map { ($0.id, $0.title) }, quiet: !active,
                             greyRing: goal.state == .paused || goal.state == .letGo,
                             ticking: next.map { ticking.contains($0.id) } ?? false,
                             spoken: GoalViews.spoken(goal, tasks: tasks, now: now))
        if bots {
            card.team = GoalBots.team(goal)
            card.led = goal.lead != nil
            card.waits = GoalBots.waitsForYou(goal, offers: offers)
            card.look = look
            if GoalShelfNext.of(goal, tasks: tasks, bots: true, offers: offers) == .planWaits {
                card.planWaits = true
                card.spoken += ", " + GoalShelfNext.planWords.lowercased()
            }
        }
        card.stall = GoalViews.stalled(goal, tasks: tasks, now: now, keptHere: keptHere).map(GoalViews.stallLine)
        return card
    }
}

/// One goal as a card. A tap opens its page (the cell's); a tap on the next task's circle ticks that task.
struct GoalCard: View {
    var model: GoalCardModel
    var tick: (String) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var textRing: CGFloat = 32
    private var ringSize: CGFloat { HQFont.scaled(textRing) }
    @ScaledMetric(relativeTo: .body) private var textFace: CGFloat = 22
    private var faceSize: CGFloat { HQFont.scaled(textFace) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.isDesktop ? DesktopRows.radius : 14, style: .continuous)
        // [goals step 2] At the accessibility sizes the ring stands over the words, so the name has the card's width
        // (beside the ring it ran to a word a line).
        let head = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        VStack(alignment: .leading, spacing: 0) {
            head {
                GoalRing(fraction: model.fraction, color: model.color, size: ringSize, quiet: model.greyRing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title)
                        .font(Font.hq(.body).weight(.semibold))
                        .foregroundStyle(model.quiet ? Color.hqLabel2 : Color.hqLabel)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    line
                    if let stall = model.stall {
                        Text(stall)
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqOrange)
                            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("goal.card.stall")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // [goals step 3] The bots on the goal at the card's end.
                if !model.team.isEmpty {
                    GoalTeamFaces(team: model.team, look: model.look, waits: model.waits, size: faceSize)
                }
            }
            .padding(.vertical, 12)
            if let next = model.next {
                TaskPlainHairline()
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Button { tick(next.id) } label: {
                        Image(systemName: model.ticking ? "checkmark.circle.fill" : "circle")
                            .font(Font.hq(.callout).weight(.light))
                            .foregroundStyle(model.ticking ? Color.hqTint : Color.hqLabel3)
                            .contentShape(Rectangle().inset(by: -10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Mark \(next.title) Done")   // the card speaks as one; this names the tick for UI tests and the Mac
                    .accessibilityIdentifier("goal.card.tick")
                    Text(next.title)
                        .font(Font.hq(.subheadline))
                        .foregroundStyle(model.ticking ? Color.hqLabel2 : Color.hqLabel)
                        .strikethrough(model.ticking, color: Color.hqLabel3)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 11)
            } else if model.planWaits {
                // [goals set-up] A plan waits for your answer (its card is on the goal's page and on Today).
                TaskPlainHairline()
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(Font.hq(.callout).weight(.light))
                        .foregroundStyle(Color.hqLabel3)
                        .accessibilityHidden(true)
                    Text(GoalShelfNext.planWords)
                        .font(Font.hq(.subheadline))
                        .foregroundStyle(Color.hqLabel)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("goal.card.plan-waits")
                }
                .padding(.vertical, 11)
            }
        }
        .padding(.horizontal, 14)
        .background {
            if model.quiet {
                shape.fill(Color.hqLabel.opacity(0.04))
                    .overlay { if Theme.isDesktop { shape.strokeBorder(Color.hqStroke, lineWidth: HQShape.hairline) } }
            } else {
                shape.fill(Color(uiColor: ProjectPageHeader.fill))
                    .overlay { if Theme.isDesktop { shape.strokeBorder(Color.hqStroke, lineWidth: HQShape.hairline) } }
            }
        }
        .hqPointerFill(shape)
        .contentShape(shape)
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        // One element: the ring and the line are words in its label, not stops of their own.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GoalCardWords.label(model.spoken, stall: model.stall,
                                                  team: model.look.spoken(team: model.team, led: model.led, waits: model.waits)))
        .accessibilityValue(model.fraction.map { "\(Int(($0 * 100).rounded(.down))) percent" } ?? "No plan yet")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the goal")
        .modifier(GoalCardTickAction(next: model.next, tick: tick))
        .accessibilityIdentifier("goal-card-\(model.title)")
    }

    /// The grey line, and the pace after it in its colour.
    private var line: some View {
        let grey = Text(model.line).foregroundStyle(Color.hqLabel2)
        let words: Text = {
            guard let pace = model.pace else { return grey }
            return Text("\(grey)\(Text(" · ").foregroundStyle(Color.hqLabel2))\(Text(pace.words).foregroundStyle(pace.tone.ink))")
        }()
        return words
            .font(Font.hq(.footnote))
            .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// VoiceOver ticks the next task from the card (the card is one element).
private struct GoalCardTickAction: ViewModifier {
    var next: (id: String, title: String)?
    var tick: (String) -> Void

    func body(content: Content) -> some View {
        if let next {
            content.accessibilityAction(named: "Mark “\(next.title)” Done") { tick(next.id) }
        } else {
            content
        }
    }
}

/// "+ New Goal", the view's last row, in the tint.
struct GoalNewRow: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "plus").font(Font.hq(.subheadline).weight(.medium)).accessibilityHidden(true)
            Text("New Goal")
        }
        .font(Font.hq(.subheadline))
        .foregroundStyle(Color.hqTintText)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("New Goal")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("goals.new")
    }
}

/// No goals at all: what a goal is, in two lines, with New Goal.
struct GoalsEmptyRow: View {
    var enabled: Bool
    var add: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text(GoalViews.emptyText)
                .font(Font.hq(.subheadline))
                .foregroundStyle(Color.hqLabel2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("goals.empty")
            Button { add() } label: { Text("New Goal").padding(.horizontal, 6) }
                .buttonStyle(TaskCardButtonStyle(main: true))
                .disabled(!enabled)
                .accessibilityIdentifier("goals.empty.new")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 36)
        .padding(.top, 48)
        .padding(.bottom, 16)
    }
}
