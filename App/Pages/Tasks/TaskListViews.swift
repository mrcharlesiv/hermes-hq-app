// [task-lists] What a list looks like on the Tasks page (owner 2026-11-14, six boards in
// hermes-hq-share/2026-11-14-tasks-lists, "All approved"): its colour as a small dot, the quiet line that names the
// bot keeping it, "4 more in Work" under Today's next few, a bot's offer as a card (nothing changes until you tap),
// a bot's offer to close your task, and the Edit List sheet (name, colour, icon, who keeps it, how it adds, Today).
// The rules are HermesKit's `TodoLists`; this file only draws.
//
// A bot's face on a task's row means one thing, that the bot is on it. So nothing here draws a face for the list's
// bot: it is named in words.

import SwiftUI
import UIKit

extension TodoListColor {
    /// The colour as drawn: the system's own, so it follows light, dark and Increase Contrast.
    var ink: Color {
        switch self {
        case .blue: return Color(uiColor: .systemBlue)
        case .green: return Color(uiColor: .systemGreen)
        case .orange: return Color(uiColor: .systemOrange)
        case .red: return Color(uiColor: .systemRed)
        case .purple: return Color(uiColor: .systemPurple)
        case .pink: return Color(uiColor: .systemPink)
        case .teal: return Color(uiColor: .systemTeal)
        case .yellow: return Color(uiColor: .systemYellow)
        case .gray: return Color(uiColor: .systemGray)
        }
    }
}

/// A list's dot: before a row's date outside the list, and on the list's pill.
struct TaskListDot: View {
    var color: TodoListColor
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(color.ink).frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// On a list's pill: its icon in grey ([tasks-colour] its colour shows where you choose it, in Edit List: `inColour`),
/// or the plain list icon for a list with none. White on the picked pill's tint.
struct TaskListPillMark: View {
    var color: TodoListColor?
    var icon: String?
    var picked: Bool
    /// Edit List's preview: the icon in the list's colour, or the colour's dot.
    var inColour = false

    var body: some View {
        let ink = picked ? Color.hqOnTint : (inColour ? (color?.ink ?? Color.hqLabel2) : Color.hqLabel2)
        if let icon = icon ?? (inColour ? nil : TodoListIcons.fallback) {
            Image(systemName: icon)
                .font(Font.hq(Theme.isDesktop ? .caption : .footnote).weight(.medium))
                .foregroundStyle(ink)
                .accessibilityHidden(true)
        } else {
            Circle().fill(ink).frame(width: 8, height: 8).accessibilityHidden(true)
        }
    }
}

/// Under the pills on a list a bot keeps: "Kept by Otto · checked 8:02 AM".
struct TaskKeeperRow: View {
    var text: String
    var onCard = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.shield").accessibilityHidden(true)
            Text(text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .font(Font.hq(.footnote))
        .foregroundStyle(Color.hqLabel2)
        .padding(.horizontal, ListGutter.side)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tasks.keeper")
    }
}

/// Under a list's next few on Today: "4 more in Work ›". A tap shows the list.
struct TaskMoreRow: View {
    var text: String

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
            Image(systemName: "chevron.right").font(Font.hq(.caption2).weight(.semibold)).accessibilityHidden(true)
        }
        .font(Font.hq(.footnote))
        .foregroundStyle(Color.hqTintText)
        // In line with the tasks' names (the circle's 22 pt and its 12 pt gap).
        .padding(.leading, ListGutter.side + 22 + 12)
        .padding(.trailing, ListGutter.side)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("tasks.more")
    }
}

/// A card's two kinds of button: the filled one, and the quiet ones beside it.
struct TaskCardButtonStyle: ButtonStyle {
    var main: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let _ = Theme.touch()
        let label = configuration.label
            .font(Font.hq(.footnote).weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .opacity(enabled ? 1 : 0.45)
        if DeviceWord.isMac || Theme.isDesktop {
            let shape = RoundedRectangle(cornerRadius: DeviceWord.isMac ? MacPush.radius : DesktopRows.radius, style: .continuous)
            label
                .foregroundStyle(main ? Color.hqOnTint : Color.hqLabel)
                .background(shape.fill(main ? Color.hqTint : (DeviceWord.isMac ? MacPush.fillColor : Color.clear)))
                .overlay { if !main { shape.strokeBorder(DeviceWord.isMac ? MacPush.strokeColor : Color.hqStroke, lineWidth: HQShape.hairline) } }
                .contentShape(shape)
        } else {
            label
                .foregroundStyle(main ? Color.hqOnTint : Color.hqTintText)
                .background(Capsule().fill(main ? AnyShapeStyle(Color.hqTint) : AnyShapeStyle(Color.hqFill3)))
                .contentShape(Capsule())
        }
    }
}

/// A card's fill on the Tasks page: a faint wash in the iOS look, the look's outlined card otherwise.
struct TaskCardBackground: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.isDesktop ? DesktopRows.radius : 14, style: .continuous)
        content.background {
            if Theme.isDesktop {
                shape.fill(Color.hqGroupedCard).overlay { shape.strokeBorder(Color.hqStroke, lineWidth: HQShape.hairline) }
            } else {
                shape.fill(Color.hqLabel.opacity(0.06))
            }
        }
    }
}

/// What an offer's card draws.
struct TaskOfferCardModel: Hashable {
    var offer: TodoOffer
    var title: String
    var buttons: [TodoOfferButton]
    /// Your tap is on its way.
    var busy = false
    /// The dot of the list it is for, when the list is one of yours.
    var color: TodoListColor?

    /// The card shows this many tasks, then "+4 more".
    static let shown = 5
}

/// A bot's offer above the Tasks page's rows: what it would make, the tasks, and the buttons. Nothing has changed
/// until one is tapped.
struct TaskOfferCard: View {
    var model: TaskOfferCardModel
    var enabled: Bool
    var tap: (TodoOfferButton) -> Void

    var body: some View {
        let offer = model.offer
        let lines = offer.asksMove || offer.tasks.isEmpty ? offer.move.map { ($0.title, String?.none) } : offer.tasks.map { ($0.title, $0.due) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if let color = model.color {
                    TaskListDot(color: color, size: 8)
                        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + HQFont.preferred(.subheadline).capHeight / 2 }
                } else {
                    Image(systemName: "tray.and.arrow.down")
                        .font(Font.hq(.footnote).weight(.semibold))
                        .foregroundStyle(Color.hqTintText)
                        .accessibilityHidden(true)
                }
                Text(model.title)
                    .font(Font.hq(.subheadline).weight(.semibold))
                    .foregroundStyle(Color.hqLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            if !offer.why.isEmpty, !offer.asksMove {
                Text(offer.why)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(lines.prefix(TaskOfferCardModel.shown).enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "circle")
                            .font(Font.hq(.caption))
                            .foregroundStyle(Color.hqLabel3)
                            .accessibilityHidden(true)
                        Text(line.0)
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqLabel)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let due = line.1, let day = TodoDates.due(due) {
                            Text(TodoWords.day(day.date, now: Date()))
                                .font(Font.hq(.caption)).monospacedDigit()
                                .foregroundStyle(Color.hqLabel2)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                }
                if lines.count > TaskOfferCardModel.shown {
                    Text("+\(lines.count - TaskOfferCardModel.shown) more")
                        .font(Font.hq(.caption))
                        .foregroundStyle(Color.hqLabel2)
                        .padding(.leading, 22)
                }
            }
            PagesFlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(model.buttons, id: \.self) { button in
                    Button { tap(button) } label: {
                        HStack(spacing: 5) {
                            if model.busy, button.main { ProgressView().controlSize(.mini) }
                            Text(button.title)
                        }
                    }
                    .buttonStyle(TaskCardButtonStyle(main: button.main))
                    .accessibilityIdentifier("tasks.offer.\(button.title)")
                }
            }
            .disabled(!enabled || model.busy)
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(TaskCardBackground())
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tasks.offer.\(offer.list)")
    }
}

/// On a task's page: a bot thinks your task is done and says why. It never ticks it itself.
/// [goals] The goal's page asks its two questions with the same card ("That was the last task in Launch week. Mark it
/// done?" Mark Done / Not Yet): its button words and identifier are the caller's.
struct TaskCloseOfferCard: View {
    var line: String
    var enabled: Bool
    var yes = "Mark Done"
    var no = "Keep Open"
    var identifier = "task.close-offer"
    var done: () -> Void
    var keep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "checkmark.circle")
                    .font(Font.hq(.footnote).weight(.semibold))
                    .foregroundStyle(TodoInk.color(.ready))
                    .accessibilityHidden(true)
                Text(line)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(yes, action: done)
                    .buttonStyle(TaskCardButtonStyle(main: true))
                    .accessibilityIdentifier(identifier + ".done")
                Button(no, action: keep)
                    .buttonStyle(TaskCardButtonStyle(main: false))
                    .accessibilityIdentifier(identifier + ".keep")
            }
            .disabled(!enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(TaskCardBackground())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Edit List

@MainActor @Observable
final class TaskListEditModel {
    let store: TasksStore
    let id: String
    /// The bots that could keep the list (id, name).
    let bots: [(id: String, name: String)]
    var draft: TodoUserSection
    var name: String
    @ObservationIgnored weak var controller: UIViewController?
    @ObservationIgnored var onDelete: (() -> Void)?

    init(store: TasksStore, section: TodoUserSection, bots: [(id: String, name: String)]) {
        self.store = store
        id = section.id
        self.bots = bots
        draft = section
        name = section.name
    }

    func botName(_ id: String) -> String { bots.first { $0.id == id }?.name ?? id }

    /// The name as typed, once it is one (a blank field keeps the old name).
    func commitName() {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !clean.isEmpty else { name = draft.name; return }
        name = clean
        guard clean != draft.name else { return }
        draft.name = clean
        save()
    }

    /// Saves the draft. A save that didn't land puts the controls back to what the gateway keeps.
    func save() {
        let next = draft
        Task {
            guard store.sections.first(where: { $0.id == id }) != next else { return }
            if await !store.saveSection(next) {
                PagesHaptics.error()
                if draft == next, let kept = store.sections.first(where: { $0.id == id }) { draft = kept; name = kept.name }
            }
        }
    }
}

enum TaskListEditSheet {
    static func make(store: TasksStore, section: TodoUserSection, bots: [Bot], onDelete: @escaping () -> Void) -> UIViewController {
        let model = TaskListEditModel(store: store, section: section, bots: bots.map { ($0.id, PagesNames.botName($0.id, bots: bots)) })
        model.onDelete = onDelete
        let host = UIHostingController(rootView: HQScaledRoot(TaskListEditView(model: model)))
        model.controller = host
        let nav = ChatSheet.wrap(host, title: "Edit List")
        nav.sheetPresentationController?.selectedDetentIdentifier = .large
        return nav
    }
}

struct TaskListEditView: View {
    @Bindable var model: TaskListEditModel
    @FocusState private var naming: Bool

    private var color: TodoListColor? { TodoLists.color(model.draft) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    TaskListPillMark(color: color, icon: model.draft.icon ?? TodoListIcons.fallback, picked: false, inColour: true)
                        .frame(width: 24)
                    TextField("List Name", text: $model.name)
                        .focused($naming)
                        .submitLabel(.done)
                        .textInputAutocapitalization(.words)
                        .onSubmit { model.commitName() }
                        .onChange(of: naming) { _, focused in if !focused { model.commitName() } }
                        .accessibilityIdentifier("tasks.list-edit.name")
                }
            }
            .hqSheetRows()

            if model.store.listsSupported {
                Section {
                    swatches
                } header: { HQSectionLabel { Text("Colour") } } footer: { HQSectionFooter {
                    Text("Sets the colour of this list’s icon.")
                } }
                .hqSheetRows()

                Section {
                    icons
                } header: { HQSectionLabel { Text("Icon") } }
                .hqSheetRows()

                Section {
                    Picker("Kept By", selection: Binding(get: { model.draft.bot ?? "" }, set: {
                        PagesHaptics.selection(); model.draft.bot = $0.isEmpty ? nil : $0; model.save()
                    })) {
                        Text("No One").tag("")
                        ForEach(model.bots, id: \.id) { bot in Text(bot.name).tag(bot.id) }
                    }
                    .accessibilityIdentifier("tasks.list-edit.bot")
                    if model.draft.bot != nil {
                        Picker("New Tasks", selection: Binding(get: { model.draft.asksFirst }, set: {
                            PagesHaptics.selection(); model.draft.asksFirst = $0; model.save()
                        })) {
                            Text("Add Without Asking").tag(false)
                            Text("Ask First").tag(true)
                        }
                        .accessibilityIdentifier("tasks.list-edit.adds")
                    }
                } header: { HQSectionLabel { Text("Bot") } } footer: { HQSectionFooter {
                    if let bot = model.draft.bot {
                        let name = model.botName(bot)
                        Text(model.draft.asksFirst
                             ? "\(name) files what belongs here, and shows you new tasks as a card before they go on. It never marks your task done or rewords it: it offers, and you decide."
                             : "\(name) files what belongs here and adds new tasks as it finds them. It never marks your task done or rewords it: it offers, and you decide.")
                    } else {
                        Text("A bot that keeps a list files what belongs there and tells you when a task looks settled.")
                    }
                } }
                .hqSheetRows()

                Section {
                    Toggle(isOn: Binding(get: { model.draft.inToday }, set: { model.draft.inToday = $0; model.save() })) {
                        Text("Show in Today")
                    }
                    .accessibilityIdentifier("tasks.list-edit.today")
                } footer: { HQSectionFooter {
                    Text("Today shows this list’s next \(TodoViews.nextCount) tasks under the ones that are due, in the order you keep them.")
                } }
                .hqSheetRows()
            }

            Section {
                Button(role: .destructive) { model.onDelete?() } label: {
                    Label("Delete List…", systemImage: "trash").foregroundStyle(Color.hqRed)
                }
                .accessibilityIdentifier("tasks.list-edit.delete")
            }
            .hqSheetRows()
        }
        .hqGroupedPage()
        .onDisappear { model.commitName() }
    }

    private var swatches: some View {
        TaskColorSwatches(picked: color, identifier: "tasks.list-edit.color") { choice in
            model.draft.color = choice?.rawValue
            model.save()
        }
    }

    private var icons: some View {
        PagesFlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(TodoListIcons.all, id: \.self) { icon in
                let picked = (model.draft.icon ?? "") == icon
                Button {
                    PagesHaptics.selection()
                    model.draft.icon = picked ? nil : icon
                    model.save()
                } label: {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))   // a11y-font-ok: an icon inside a fixed tile
                        .foregroundStyle(picked ? Color.hqOnTint : Color.hqLabel)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(picked ? (color?.ink ?? Color.hqTint) : Color.hqFill3))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(TodoListIcons.spoken(icon))
                .accessibilityAddTraits(picked ? .isSelected : [])
                .accessibilityIdentifier("tasks.list-edit.icon.\(icon)")
            }
        }
        .padding(.vertical, 4)
    }
}

/// [goals] A list's colours to pick from (Edit List, and Edit Goal: a goal takes a list's colours). A tap on the picked
/// one clears it when `clears`; otherwise it stays.
struct TaskColorSwatches: View {
    var picked: TodoListColor?
    var identifier: String
    var clears = true
    var pick: (TodoListColor?) -> Void

    var body: some View {
        PagesFlowLayout(spacing: 12, lineSpacing: 10) {
            ForEach(TodoListColor.allCases, id: \.self) { choice in
                let isPicked = picked == choice
                Button {
                    PagesHaptics.selection()
                    if isPicked { if clears { pick(nil) } } else { pick(choice) }
                } label: {
                    Circle().fill(choice.ink)
                        .frame(width: 28, height: 28)
                        .overlay {
                            if isPicked { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white) }   // a11y-font-ok: a tick inside a fixed 28 pt swatch
                        }
                        .padding(4)
                        .overlay { if isPicked { Circle().strokeBorder(choice.ink, lineWidth: 2) } }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.name)
                .accessibilityAddTraits(isPicked ? .isSelected : [])
                .accessibilityIdentifier("\(identifier).\(choice.rawValue)")
            }
        }
        .padding(.vertical, 4)
    }
}
