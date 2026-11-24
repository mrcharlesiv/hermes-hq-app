// [goals] A goal's page, drawn from a task's page's rows (`TaskGridRow`, `TaskSectionHead`, `TaskBand`, the quiet
// words; docs/goals.md "A goal's page", board 2's left and middle phones), top to bottom: an offer when one waits (rule
// 5), the title led by the ring, where it stands (paused, achieved, let go), the number row with Update, the date row
// with what is left, the why, the bar with its even-pace tick and one line under it, quiet words for what is not set,
// then Milestones (the current one open with its tasks) and No Milestone (or Tasks). The tasks are the Tasks page's
// own rows (`TodoRowView`): a tick turns one to dust, a tap opens it, a hold has its choices.

import SwiftUI

struct GoalPlainView: View {
    @Bindable var model: GoalPageModel
    @FocusState private var focus: Field?
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title3) private var textRing: CGFloat = 24
    private var ringSize: CGFloat { HQFont.scaled(textRing) }
    /// [goals step 2] A row's words and what stands at its end ("48 days left", Update, a milestone's date): side by side,
    /// and at the accessibility sizes one under the other, so neither is cut ("By W…") or squeezed to a letter a line.
    private var rowLine: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                                     : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
    }
    enum Field: Hashable { case title, why, task, milestone }

    var body: some View {
        Group {
            if let goal = model.goal {
                content(goal)
            } else {
                HStack(spacing: 8) { ProgressView(); Text("Loading…").foregroundStyle(Color.hqLabel2) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(uiColor: TaskPanel.fill).ignoresSafeArea())
        .overlay(alignment: .top) {
            if let notice = model.notice {
                Text(notice)
                    .font(Font.hq(.footnote))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .hqGlassEffect(in: .capsule)
                    .padding(.top, 6)
                    .padding(.horizontal, 24)
                    .transition(.opacity)
                    .accessibilityIdentifier("goal.notice")
            }
        }
        .animation(.easeInOut(duration: HQMotion.fade), value: model.notice)   // motion-ok: the notice fades (opacity transition)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if focus != nil {
                    Spacer()
                    Button("Done") { PagesHaptics.selection(); focus = nil }
                        .font(Font.hq(.body).weight(.semibold))
                        .accessibilityIdentifier("goal.edit-done")
                }
            }
        }
    }

    private func content(_ goal: Goal) -> some View {
        let tasks = model.tasks
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    offer(goal)
                    looksDone(goal)
                    botOffers(goal)
                    titleRow(goal, tasks: tasks)
                    statusRow(goal)
                    numberRow(goal)
                    dateRow(goal)
                    whoRow(goal)
                    whyRow(goal)
                    progress(goal, tasks: tasks)
                    standsCard(goal)
                    stallCard(goal)
                    quietWords(goal)
                    if model.gone {
                        TaskGridRow(last: true, topLine: true) { Image(systemName: "trash") } text: {
                            Text("This goal was deleted.").foregroundStyle(Color.hqLabel2)
                        }
                    }
                    planAsk(goal)
                    milestones(goal, tasks: tasks, proxy: proxy)
                    loose(goal, tasks: tasks, proxy: proxy)
                }
                .padding(.trailing, ScrollBarLane.listTrailing)
                .padding(.bottom, 24 + (model.embedded && !model.tucked ? model.shelfRoom : 0))   // clear of the chat's chips
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await model.store.refresh(force: true) }
            .onChange(of: goal.rev) { _, rev in model.goalChanged(rev) }   // [goals step 5] an open Goal Page follows
            .onChange(of: goal.title) { model.syncChatName() }   // [goals set-up] its chat's pane on the Mac too
        }
    }

    // MARK: [goals step 3] Bots on the goal

    /// The goal's offer cards: a plan, a check-in, tasks (what waits, and what you accepted with its Undo).
    @ViewBuilder private func botOffers(_ goal: Goal) -> some View {
        let offers = model.gone ? [] : model.offers
        if !offers.isEmpty {
            VStack(spacing: 8) {
                ForEach(offers, id: \.id) { offer in
                    GoalOfferCard(model: model.offerCard(offer), enabled: !model.readOnly,
                                  tap: { model.answerOffer(offer, $0) },
                                  undo: { model.answerOffer(offer.id, .undo) },
                                  more: { model.showWholeOffer(offer) })
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .transition(.opacity)
        }
    }

    /// The lead thinks a milestone (or the goal) is done: Mark Done / Not Yet. It never ticks it itself.
    @ViewBuilder private func looksDone(_ goal: Goal) -> some View {
        if !model.gone, model.store.goalBotsSupported, let offer = GoalBots.looksDone(goal) {
            TaskCloseOfferCard(line: GoalBots.looksDoneText(offer, goal: goal, botName: model.botName), enabled: !model.readOnly,
                               yes: GoalBots.looksDoneYes(offer), no: "Not Yet", identifier: "goal.looks-done",
                               done: { model.answerLooksDone(true) }, keep: { model.answerLooksDone(false) })
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .transition(.opacity)
        }
    }

    /// [goals step 6] The Bots row, always there with the add-on's bots, right under the date: "Just Me" with Add Bots
    /// at its end in the accent colour, or "Led by Hermes" with the faces of the lead and helpers and the check-in's slot
    /// at its end. A tap opens the team sheet.
    @ViewBuilder private func whoRow(_ goal: Goal) -> some View {
        if model.store.goalBotsSupported, model.hasBots, GoalBots.whoLine(goal, botName: model.botName) == nil {
            Button { model.openTeam() } label: {
                TaskGridRow {
                    Image(systemName: "person").foregroundStyle(Color.hqLabel2)
                } text: {
                    rowLine {
                        Text(GoalBots.justMe).foregroundStyle(Color.hqLabel).lineLimit(1)
                        if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                        Text("Add Bots").font(Font.hq(.subheadline).weight(.medium)).foregroundStyle(Color.hqTintText).lineLimit(1)
                            .accessibilityIdentifier("goal.who.add")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.gone || model.readOnly)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(GoalBots.justMe)
            .accessibilityValue("Add Bots")
            .accessibilityHint("Adds bots to this goal")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("goal.who")
        } else if model.store.goalBotsSupported, let line = GoalBots.whoLine(goal, botName: model.botName) {
            Button { model.openTeam() } label: {
                TaskGridRow {
                    Image(systemName: "person").foregroundStyle(Color.hqLabel2)
                } text: {
                    rowLine {
                        HStack(spacing: 6) {
                            if let lead = goal.lead {
                                HeadImage(raw: model.head(lead), profile: lead, size: 20).frame(width: 20, height: 20).accessibilityHidden(true)
                            }
                            Text(line).foregroundStyle(Color.hqLabel).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                            ForEach(goal.lead == nil ? Array(goal.helpers.dropFirst()) : goal.helpers, id: \.self) { helper in
                                HeadImage(raw: model.head(helper), profile: helper, size: 20).frame(width: 20, height: 20).accessibilityHidden(true)
                            }
                        }
                        if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                        if goal.lead != nil, goal.review != nil {
                            Text(GoalBots.reviewWords(goal.review)).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).lineLimit(1)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.gone || model.readOnly)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel((GoalBots.whoSpoken(goal, botName: model.botName) ?? line)
                                + (goal.lead != nil && goal.review != nil ? ", check-in \(GoalBots.reviewWords(goal.review))" : ""))
            .accessibilityHint("Changes the bots on this goal")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("goal.who")
        }
    }

    /// Where it stands, in the lead's own words: its face and name, since when, Page ›, the words, then Next.
    @ViewBuilder private func standsCard(_ goal: Goal) -> some View {
        if model.store.goalBotsSupported, let stands = goal.stands, !stands.text.isEmpty {
            let by = stands.by ?? goal.lead
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let by {
                        HeadImage(raw: model.head(by), profile: by, size: 16).frame(width: 16, height: 16).accessibilityHidden(true)
                    }
                    (Text(model.botName(by)).fontWeight(.semibold).foregroundStyle(Color.hqLabel)
                     + Text(GoalBots.standsWhen(stands, now: Date()).map { " · \($0)" } ?? "").foregroundStyle(Color.hqLabel2))
                        .font(Font.hq(.footnote))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if model.offersGoalPage {
                        Button { model.openGoalPage() } label: {
                            HStack(spacing: 4) {
                                if model.pageLoading { ProgressView().controlSize(.mini) }
                                Text("Page ›")
                            }
                        }
                        .font(Font.hq(.footnote).weight(.semibold))
                        .foregroundStyle(Color.hqTintText)
                        .buttonStyle(.plain)
                        .frame(minHeight: 30)
                        .contentShape(Rectangle().inset(by: -8))
                        .accessibilityLabel("Goal Page")
                        .accessibilityHint("Opens the goal's whole page")
                        .accessibilityIdentifier("goal.stands.page")
                    }
                }
                Text(stands.text)
                    .font(Font.hq(.subheadline))
                    .foregroundStyle(Color.hqLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("goal.stands.text")
                if !stands.next.isEmpty {
                    (Text("Next: ").fontWeight(.semibold) + Text(stands.next))
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(TaskCardBackground())
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("goal.stands")
        }
    }

    /// [goals step 4] Nothing has moved in two weeks: one honest question. Smaller Step / Pause / Let It Go, and the
    /// quiet Keep Going.
    @ViewBuilder private func stallCard(_ goal: Goal) -> some View {
        if !model.gone, !model.readOnly, let stall = model.stall(goal) {
            GoalStallCard(stall: stall, question: GoalViews.stallQuestion(stall, now: Date()), enabled: !model.readOnly,
                          smaller: { model.smallerStep(stall) }, pause: { model.setStatus(.paused) },
                          letGo: { model.setStatus(.letGo) }, keep: { model.keepGoing() })
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 4)
                .transition(.opacity)
        }
    }

    // MARK: Top

    /// Rule 5: a milestone whose tasks are all done, or every milestone done. A question, never automatic.
    @ViewBuilder private func offer(_ goal: Goal) -> some View {
        if !model.gone, let offer = model.offer(goal) {
            TaskCloseOfferCard(line: offer.text, enabled: !model.readOnly, yes: offer.yes, no: "Not Yet", identifier: "goal.offer",
                               done: { model.answer(offer, yes: true) }, keep: { model.answer(offer, yes: false) })
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .transition(.opacity)
        }
    }

    /// The ring and the name. A tap on the name writes.
    private func titleRow(_ goal: Goal, tasks: [TodoTask]) -> some View {
        let fraction = GoalViews.fraction(goal, tasks: tasks)
        return TaskGridRow(last: true, minHeight: 46) {
            GoalRing(fraction: fraction, color: goal.tint, size: min(ringSize, 34), quiet: goal.state == .paused || goal.state == .letGo)
        } text: {
            if model.editingTitle {
                TextField("Goal", text: $model.titleDraft, axis: .vertical)
                    .font(Font.hqSystem(.title3, design: .default, weight: .semibold))
                    .lineLimit(1...4)
                    .focused($focus, equals: .title)
                    .submitLabel(.done)
                    .onSubmit { model.saveTitle() }
                    .onAppear { focus = .title }
                    .onChange(of: focus) { old, new in if old == .title, new != .title { model.saveTitle() } }
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("goal.title.field")
            } else {
                Text(goal.title.isEmpty ? "Untitled Goal" : goal.title)
                    .font(Font.hqSystem(.title3, design: .default, weight: .semibold))
                    .foregroundStyle(goal.state == .active ? Color.hqLabel : Color.hqLabel2)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { model.editTitle() }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(goal.title.isEmpty ? "Untitled Goal" : goal.title)
                    .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded(.down))) percent" } ?? "No plan yet")
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHint(model.readOnly ? "" : "Renames the goal")
                    .accessibilityAction(named: "Rename") { model.editTitle() }
                    .accessibilityIdentifier("goal.title")
            }
        }
    }

    /// "Paused Nov 30" with Resume; "Achieved Dec 20"; "Let go Dec 20".
    @ViewBuilder private func statusRow(_ goal: Goal) -> some View {
        if let line = GoalViews.statusLine(goal, now: Date()) {
            let symbol = switch goal.state { case .paused: "pause.circle"; case .achieved: "checkmark.seal"; default: "wind" }
            TaskGridRow {
                Image(systemName: symbol).foregroundStyle(goal.state == .achieved ? Color(uiColor: TodoInk.ready) : Color.hqLabel2)
            } text: {
                rowLine {
                    Text(line).foregroundStyle(Color.hqLabel2).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                        .accessibilityIdentifier("goal.status")
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                    if goal.state == .paused, !model.gone {
                        Button("Resume") { model.setStatus(.active) }
                            .font(Font.hq(.footnote).weight(.medium))
                            .foregroundStyle(Color.hqTintText)
                            .buttonStyle(.plain)
                            .frame(minHeight: 32)
                            .contentShape(Rectangle().inset(by: -8))
                            .disabled(model.readOnly)
                            .accessibilityIdentifier("goal.resume")
                    }
                }
            }
        }
    }

    /// "340 of 1,000 testers" with Update at its end. Its menu edits the number or removes it.
    @ViewBuilder private func numberRow(_ goal: Goal) -> some View {
        if let measure = goal.measure {
            let words = GoalViews.measureWords(measure, unit: true)
            TaskGridRow {
                Image(systemName: "flag").foregroundStyle(Color.hqLabel2)
            } text: {
                rowLine {
                    Menu {
                        Button("Update…", systemImage: "arrow.up.circle") { model.updateNumber() }
                        Button("Edit Number…", systemImage: "slider.horizontal.3") { model.editNumber() }
                        Button("Remove Number", systemImage: "minus.circle", role: .destructive) { model.removeNumber() }
                    } label: {
                        Text(words).foregroundStyle(Color.hqLabel).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                            .fixedSize(horizontal: false, vertical: typeSize.isAccessibilitySize)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.gone || model.readOnly)
                    .accessibilityLabel("Number: \(words). Change")
                    .accessibilityIdentifier("goal.number")
                    if model.store.goalBotsSupported, let source = GoalBots.sourceWords(measure, now: Date(), botName: model.botName) {
                        // [goals step 3] A bot reads it: where from and when, in place of Update (a tap still sets it).
                        Button(source) { model.updateNumber() }
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqLabel2)
                            .lineLimit(1)
                            .buttonStyle(.plain)
                            .frame(minHeight: 32)
                            .contentShape(Rectangle().inset(by: -8))
                            .disabled(model.gone || model.readOnly)
                            .accessibilityLabel("Read by \(model.botName(measure.source.bot)): \(source)")
                            .accessibilityHint("Sets the number yourself")
                            .accessibilityIdentifier("goal.number.source")
                    } else if goal.state == .active || goal.state == .paused {   // a finished goal's number is history
                        Button("Update") { model.updateNumber() }
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqLabel2)
                            .buttonStyle(.plain)
                            .frame(minHeight: 32)
                            .contentShape(Rectangle().inset(by: -8))
                            .disabled(model.gone || model.readOnly)
                            .accessibilityLabel("Update the Number")
                            .accessibilityIdentifier("goal.update")
                    }
                }
            }
        }
    }

    /// "By Sun, Jan 31" with what is left at its end (red once it is late).
    @ViewBuilder private func dateRow(_ goal: Goal) -> some View {
        if let words = GoalViews.dateRow(goal, now: Date()) {
            let left = GoalViews.left(goal, now: Date())
            let late = left?.hasSuffix("late") == true
            Menu {
                Button("Choose Date…", systemImage: "calendar") { model.pickDate() }
                Button("No Date", systemImage: "minus.circle", role: .destructive) { model.setDue(nil) }
            } label: {
                TaskGridRow {
                    Image(systemName: "calendar").foregroundStyle(late ? Color.hqRed : Color.hqLabel2)
                } text: {
                    rowLine {
                        Text(words).foregroundStyle(Color.hqLabel).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                            .fixedSize(horizontal: false, vertical: typeSize.isAccessibilitySize)
                        if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                        if let left {
                            Text(left).font(Font.hq(.footnote)).foregroundStyle(late ? Color.hqRed : Color.hqLabel2)
                                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                        }
                    }
                    .padding(.vertical, typeSize.isAccessibilitySize ? 6 : 0)
                }
            }
            .buttonStyle(.plain)
            .disabled(model.gone || model.readOnly)
            .accessibilityLabel("\(words)\(left.map { ", \($0)" } ?? ""). Change")
            .accessibilityIdentifier("goal.date")
        }
    }

    /// The why: one line of yours, the reason for the goal. A tap writes.
    @ViewBuilder private func whyRow(_ goal: Goal) -> some View {
        if model.editingWhy || !goal.why.isEmpty {
            TaskGridRow(last: true) {
                Image(systemName: "text.alignleft").foregroundStyle(Color.hqLabel2)
            } text: {
                if model.editingWhy {
                    TextField("Why it matters", text: $model.whyDraft, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($focus, equals: .why)
                        .submitLabel(.done)
                        .onSubmit { model.saveWhy() }
                        .onAppear { focus = .why }
                        .onChange(of: focus) { old, new in if old == .why, new != .why { model.saveWhy() } }
                        .padding(.vertical, 8)
                        .accessibilityIdentifier("goal.why.field")
                } else {
                    Text(goal.why)
                        .foregroundStyle(Color.hqLabel)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { model.editWhy() }
                        .accessibilityLabel("Why: \(goal.why)")
                        .accessibilityHint(model.readOnly ? "" : "Edits the why")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("goal.why")
                }
            }
        }
    }

    /// The bar in the goal's colour, the even-pace tick on it (with a date), and one line under it.
    private func progress(_ goal: Goal, tasks: [TodoTask]) -> some View {
        let now = Date()
        let fraction = GoalViews.fraction(goal, tasks: tasks)
        let even = goal.state == .active ? GoalViews.evenPace(goal, now: now) : nil
        let pace = GoalViews.pace(goal, tasks: tasks, now: now)
        let line = GoalViews.barLine(goal, tasks: tasks, now: now)
        return VStack(alignment: .leading, spacing: 6) {
            GoalProgressBar(fraction: fraction, even: even, color: goal.state == .active || goal.state == .achieved ? goal.tint : .gray)
            barWords(line, pace: pace)
                .font(Font.hq(.footnote))
                .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, TaskGrid.edge)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line)
        .accessibilityIdentifier("goal.bar")
    }

    /// The line's pace (when it is said as a word) in its colour; the rest grey.
    private func barWords(_ line: String, pace: GoalPace?) -> Text {
        guard let pace, case .behind = pace else {
            if let pace, line.hasSuffix(pace.words) {
                let head = String(line.dropLast(pace.words.count))
                return Text("\(Text(head).foregroundStyle(Color.hqLabel2))\(Text(pace.words).foregroundStyle(pace.tone.ink))")
            }
            return Text(line).foregroundStyle(Color.hqLabel2)
        }
        return Text(line).foregroundStyle(Color.hqLabel2)
    }

    /// What is not set yet, one line: + Number, + Date, + Why (and + Milestones on a goal with none: the way to its
    /// first, where a goal with some has + on their heading).
    @ViewBuilder private func quietWords(_ goal: Goal) -> some View {
        if !model.gone, !model.readOnly, goal.state != .achieved, goal.state != .letGo {
            let number = goal.measure == nil, date = goal.due == nil, why = goal.why.isEmpty && !model.editingWhy
            let steps = goal.milestones.isEmpty && !model.addingMilestone
            if number || date || why || steps {
                ViewThatFits(in: .horizontal) {
                    quietLine(number: number, date: date, why: why, steps: steps)
                    VStack(alignment: .leading, spacing: 0) {
                        quietLine(number: number, date: date, why: why, steps: false)
                        if steps { quietLine(number: false, date: false, why: false, steps: true) }
                    }
                }
                .padding(.horizontal, TaskGrid.edge)
                .padding(.vertical, 2)
            }
        }
    }

    private func quietLine(number: Bool, date: Bool, why: Bool, steps: Bool) -> some View {
        HStack(spacing: 18) {
            if number { quiet("+ Number", id: "goal.number.add") { model.editNumber() } }
            if date { quiet("+ Date", id: "goal.date.add") { model.pickDate() } }
            if why { quiet("+ Why", id: "goal.why.add") { model.editWhy() } }
            if steps { quiet("+ Milestones", id: "goal.milestones.first") { model.addingMilestone = true } }
        }
        .fixedSize()
    }

    private func quiet(_ words: String, id: String, action: @escaping () -> Void) -> some View {
        Button {
            PagesHaptics.selection()
            action()
        } label: {
            Text(words)
                .font(Font.hq(.footnote))
                .foregroundStyle(Color.hqLabel2)
                .lineLimit(1)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(words.dropFirst(2)))
        .accessibilityIdentifier(id)
    }

    // MARK: [goals step 6] No plan yet

    /// A goal with a lead and no plan, where the milestones would be: "No plan yet" and Ask <Bot> for a Plan. Hidden while
    /// a plan offer for the goal waits; gone once it has a milestone or a task. With no number the bar's line above
    /// already says "No plan yet", so it is not said twice.
    @ViewBuilder private func planAsk(_ goal: Goal) -> some View {
        if model.showsPlanAsk, let lead = goal.lead, !model.addingMilestone {
            let words = GoalPlanAsk.buttonWords(model.botName(lead))
            TaskBand()
            VStack(alignment: .leading, spacing: 10) {
                if GoalViews.barLine(goal, tasks: model.tasks, now: Date()) != "No plan yet" {
                    Text("No plan yet")
                        .font(Font.hq(.subheadline).weight(.semibold))
                        .foregroundStyle(Color.hqLabel2)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("goal.no-plan")
                }
                Button { model.askForPlan() } label: {
                    HStack(spacing: 8) {
                        HeadImage(raw: model.head(lead), profile: lead, size: 20).frame(width: 20, height: 20).accessibilityHidden(true)
                        Text(words).font(Font.hq(.subheadline).weight(.semibold)).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    }
                    .foregroundStyle(Color.hqOnTint)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 40)
                    .background(Capsule().fill(Color.hqTint))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.readOnly)
                .accessibilityLabel(words)
                .accessibilityHint("Opens the goal's chat and asks for milestones and a first week of tasks")
                .accessibilityIdentifier("goal.ask-plan")
            }
            .padding(.horizontal, TaskGrid.edge)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
        }
    }

    // MARK: Milestones

    @ViewBuilder private func milestones(_ goal: Goal, tasks: [TodoTask], proxy: ScrollViewProxy) -> some View {
        let list = goal.milestones
        let canAdd = !model.gone && !model.readOnly && list.count < 30
        if !list.isEmpty || model.addingMilestone {
            TaskBand()
            TaskSectionHead(title: "Milestones", count: list.isEmpty ? nil : "\(list.filter(\.done).count) of \(list.count)") {
                if canAdd { addMilestoneButton }
            }
            .accessibilityIdentifier("goal.milestones")
            ForEach(Array(list.enumerated()), id: \.element.id) { index, milestone in
                milestoneRow(milestone, goal: goal, tasks: tasks, index: index, count: list.count,
                             last: index == list.count - 1 && !model.addingMilestone, proxy: proxy)
            }
            if model.addingMilestone { milestoneField(proxy: proxy) }
        }
    }

    private var addMilestoneButton: some View {
        Button {
            PagesHaptics.selection()
            model.addingMilestone = true
        } label: {
            Image(systemName: "plus")
                .font(Font.hq(.callout))
                .foregroundStyle(Color.hqLabel2)
                .frame(minWidth: 32, minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add a Milestone")
        .accessibilityIdentifier("goal.milestones.add")
    }

    private func milestoneField(proxy: ScrollViewProxy) -> some View {
        TaskGridRow(last: true) {
            Image(systemName: "square").font(Font.hq(.title3).weight(.light)).foregroundStyle(Color.hqLabel3)
        } text: {
            TextField("Milestone", text: $model.newMilestone)
                .focused($focus, equals: .milestone)
                .submitLabel(.done)
                .onSubmit { model.addMilestone(); focus = .milestone }
                .onAppear { focus = .milestone }
                .onChange(of: focus) { old, new in if old == .milestone, new != .milestone { model.addMilestone(); model.addingMilestone = false } }
                .accessibilityIdentifier("goal.milestones.field")
        }
        .id("goal.milestones.field")
        .onAppear { DispatchQueue.main.async { HQMotion.withAnimation(.snappy) { proxy.scrollTo("goal.milestones.field", anchor: .bottom) } } }
    }

    /// One line: a square box (a task's is round), its name, and at the end its date and "1 of 4". The open one has its
    /// tasks under it, then "Add a task".
    @ViewBuilder private func milestoneRow(_ milestone: GoalMilestone, goal: Goal, tasks all: [TodoTask], index: Int, count: Int,
                                           last: Bool, proxy: ScrollViewProxy) -> some View {
        let under = GoalViews.tasks(of: goal, milestone: milestone.id, in: all)
        let open = model.isOpen(milestone, in: goal)
        let shown = open ? under.filter { !$0.isDone || model.ticking.contains($0.id) } : []
        let detail = [milestone.due.flatMap { TodoDates.day(String($0.prefix(10))) }.map { TodoWords.monthDay($0, now: Date()) },
                      GoalViews.count(under)].compactMap { $0 }.joined(separator: " · ")
        let canEdit = !model.gone && !model.readOnly
        TaskGridRow(last: last && !open) {
            Button { model.toggleMilestone(milestone) } label: {
                Image(systemName: milestone.done ? "checkmark.square.fill" : "square")
                    .font(Font.hq(.title3).weight(.light))
                    .foregroundStyle(milestone.done ? Color.hqLabel3 : Color.hqLabel2)
                    .contentShape(Rectangle().inset(by: -8))
            }
            .buttonStyle(.plain)
            .disabled(!canEdit)
            .accessibilityHidden(true)   // the row speaks for it, with Mark Done as its action
            .accessibilityLabel(milestone.done ? "Mark \(milestone.title) Not Done" : "Mark \(milestone.title) Done")
            .accessibilityIdentifier("goal.milestone.box.\(milestone.title)")
        } text: {
            (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                                          : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))) {
                Text(milestone.title)
                    .font(Font.hq(.callout).weight(milestone.done ? .regular : .semibold))
                    .foregroundStyle(milestone.done ? Color.hqLabel3 : Color.hqLabel)
                    .strikethrough(milestone.done, color: Color.hqLabel3)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !detail.isEmpty {
                    Text(detail).font(Font.hq(.footnote)).monospacedDigit().foregroundStyle(Color.hqLabel2)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                        .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: true)
                }
            }
            .padding(.vertical, 8)
        }
        .onTapGesture { model.toggleOpen(milestone, in: goal) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([milestone.title, detail.replacingOccurrences(of: " · ", with: ", ")].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityValue(milestone.done ? "Done" : (open ? "Open" : ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(open ? "Hides its tasks" : "Shows its tasks")
        .accessibilityAction { model.toggleOpen(milestone, in: goal) }
        .accessibilityAction(named: milestone.done ? "Mark Not Done" : "Mark Done") { if canEdit { model.toggleMilestone(milestone) } }
        .accessibilityIdentifier("goal.milestone.\(milestone.title)")
        .contextMenu {
            if canEdit {
                Button(milestone.done ? "Mark Not Done" : "Mark Done", systemImage: milestone.done ? "square" : "checkmark.square") { model.toggleMilestone(milestone) }
                Button("Rename…", systemImage: "pencil") { model.renameMilestone(milestone) }
                Button("Set Date…", systemImage: "calendar") { model.setMilestoneDate(milestone) }
                if milestone.due != nil { Button("No Date", systemImage: "minus.circle") { model.clearMilestoneDate(milestone) } }
                if index > 0 { Button("Move Up", systemImage: "arrow.up") { model.moveMilestone(milestone, by: -1) } }
                if index < count - 1 { Button("Move Down", systemImage: "arrow.down") { model.moveMilestone(milestone, by: 1) } }
                Button("Delete Milestone…", systemImage: "trash", role: .destructive) { model.deleteMilestone(milestone) }
            }
        }
        if open {
            ForEach(shown) { task in taskRow(task, goal: goal, indent: 20) }
            if canEdit, !milestone.done { addTaskRow(.milestone(milestone.id), indent: 20, last: last, proxy: proxy) }
        }
    }

    // MARK: No Milestone (or Tasks)

    /// The goal's tasks under no milestone, then "Add a task". With no milestones the heading is plain "Tasks n of m".
    @ViewBuilder private func loose(_ goal: Goal, tasks all: [TodoTask], proxy: ScrollViewProxy) -> some View {
        let under = GoalViews.looseTasks(of: goal, in: all)
        let canEdit = !model.gone && !model.readOnly
        let plain = goal.milestones.isEmpty
        if plain || !under.isEmpty || model.adding == .loose {
            let shown = under.filter { !$0.isDone || model.ticking.contains($0.id) }
            TaskBand()
            TaskSectionHead(title: plain ? "Tasks" : "No Milestone",
                            count: plain ? GoalViews.count(under) : "\(under.filter { !$0.isDone }.count)") { EmptyView() }
            .accessibilityIdentifier("goal.loose")
            ForEach(shown) { task in taskRow(task, goal: goal, indent: 0) }
            if canEdit { addTaskRow(.loose, indent: 0, last: true, proxy: proxy) }
        }
    }

    // MARK: Tasks

    /// A task: the Tasks page's own row (its tick, its words, a bot's face), a tap opens it, a hold has its choices.
    private func taskRow(_ task: TodoTask, goal: Goal, indent: CGFloat) -> some View {
        let row = TodoRowModel.make(task, kind: .open, now: Date(), botName: model.botName,
                                    head: task.helper.flatMap { model.head($0) }, ticking: model.ticking.contains(task.id))
        return TodoRowView(row: row, toggle: { model.toggleTask(task.id) }, open: { model.openTask(task.id) })
            .padding(.leading, indent)
            .overlay(alignment: .bottom) {
                TaskPlainHairline().padding(.leading, indent + 54).padding(.trailing, TaskGrid.edge)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.openTask(task.id) }
            .opacity(model.dusted.contains(task.id) ? 0 : 1)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.rowFrames[task.id] = $0 }
            .accessibilityIdentifier("goal.task.\(row.title)")
            .contextMenu { taskMenu(task, goal: goal) }
    }

    @ViewBuilder private func taskMenu(_ task: TodoTask, goal: Goal) -> some View {
        Button("Open Task", systemImage: "arrow.up.forward.square") { model.openTask(task.id) }
        Button(task.isDone ? "Mark Not Done" : "Mark Done", systemImage: task.isDone ? "circle" : "checkmark.circle") { model.toggleTask(task.id) }
        if !model.readOnly {
            if !goal.milestones.isEmpty {
                Menu("Milestone") {
                    Button { GoalChoices.set(task.id, goal: goal.id, milestone: nil, store: model.store) } label: {
                        if task.milestone == nil { Label("No Milestone", systemImage: "checkmark") } else { Text("No Milestone") }
                    }
                    ForEach(goal.milestones.filter { !$0.done || task.milestone == $0.id }) { milestone in
                        Button { GoalChoices.set(task.id, goal: goal.id, milestone: milestone.id, store: model.store) } label: {
                            if task.milestone == milestone.id { Label(milestone.title, systemImage: "checkmark") } else { Text(milestone.title) }
                        }
                    }
                }
            }
            Button("Remove from Goal", systemImage: "minus.circle") { GoalChoices.set(task.id, goal: nil, milestone: nil, store: model.store) }
        }
    }

    /// "Add a task": a line that becomes a field; each Return adds one and keeps the field for the next.
    @ViewBuilder private func addTaskRow(_ spot: GoalAddSpot, indent: CGFloat, last: Bool, proxy: ScrollViewProxy) -> some View {
        let id = "goal.add-task.\(spot)"
        Group {
            if model.adding == spot {
                TaskGridRow(last: last) {
                    Image(systemName: "circle").font(Font.hq(.title3).weight(.light)).foregroundStyle(Color.hqLabel3)
                } text: {
                    TextField("Add a task", text: $model.newTask)
                        .focused($focus, equals: .task)
                        .submitLabel(.done)
                        .onSubmit { model.addTask(); focus = .task }
                        .onAppear { focus = .task }
                        .disabled(model.savingTask)
                        .accessibilityIdentifier("goal.add-task.field")
                }
                .id(id)
                .onAppear { DispatchQueue.main.async { HQMotion.withAnimation(.snappy) { proxy.scrollTo(id, anchor: .bottom) } } }
            } else {
                Button {
                    PagesHaptics.selection()
                    model.adding = spot
                } label: {
                    TaskGridRow(last: last) {
                        Image(systemName: "plus").foregroundStyle(Color.hqTintText)
                    } text: {
                        Text("Add a task").foregroundStyle(Color.hqTintText)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a Task")
                .accessibilityIdentifier("goal.add-task")
            }
        }
        .padding(.leading, indent)
    }
}
