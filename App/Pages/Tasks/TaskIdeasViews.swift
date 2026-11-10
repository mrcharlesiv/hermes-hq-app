// [task-ideas] The Tasks page's To Do | Ideas switch (in the place of the Add a task field, owner 2026-11-05) and the
// Ideas page's rows: who looks and when with Look Now, one card per idea (Add, Add & Let <Bot> Start, ×), the card
// that turns Ideas on, and a line on where ideas come from. The + in the bar still adds a task.

import SwiftUI

nonisolated enum TasksMode: Hashable, Sendable { case toDo, ideas }

/// To Do | Ideas, the page's first row. "Ideas 2" while two new ideas wait.
struct TasksModeSwitch: View {
    var ideas: Int
    var mode: TasksMode
    var select: (TasksMode) -> Void

    private func title(_ mode: TasksMode) -> String {
        switch mode {
        case .toDo: return "To Do"
        case .ideas: return ideas > 0 ? "Ideas \(ideas)" : "Ideas"
        }
    }

    var body: some View {
        WholeLabelTabs(tabs: [TasksMode.toDo, .ideas], title: title,
                       selection: Binding(get: { mode }, set: { if $0 != mode { select($0) } }), identifier: "tasks.mode")
            // The segmented control keeps the titles it was made with: a new count makes it again.
            .id(title(.ideas))
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 4)
    }
}

/// An idea card's words, with the bot's name and face.
struct TaskIdeaCardModel: Hashable {
    var idea: TaskIdea
    var botName: String
    var head: JSONValue?
    /// Being added (its buttons wait).
    var busy = false
}

/// The card's two moves, one size (owner 2026-11-05: "the Add and Add & Let X Help buttons need to be the same size, and
/// smaller than the larger one"; iOS's `.bordered` padded the second to ~44 pt beside Add's 30). Add is the tinted
/// capsule in the iOS look and the accent in the others; the bot starting is grey in the iOS look and outlined in the
/// others, each in its look's shape.
private struct IdeaButtonStyle: ButtonStyle {
    var prominent: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let _ = Theme.touch()
        let label = configuration.label
            .font(Font.hq(.footnote).weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .opacity(enabled ? 1 : 0.45)
        if DeviceWord.isMac || Theme.isDesktop {
            let shape = RoundedRectangle(cornerRadius: DeviceWord.isMac ? MacPush.radius : DesktopRows.radius, style: .continuous)
            let rest = DeviceWord.isMac ? MacPush.fillColor : Color.clear
            let edge = DeviceWord.isMac ? MacPush.strokeColor : Color.hqStroke
            label
                .foregroundStyle(prominent ? Color.hqOnTint : Color.hqLabel)
                .background(shape.fill(prominent ? Color.hqTint : rest))
                .overlay { if !prominent { shape.strokeBorder(edge, lineWidth: 1) } }
                .contentShape(shape)
        } else {
            label
                .foregroundStyle(Color.hqTintText)
                .background(Capsule().fill(prominent ? AnyShapeStyle(Color.hqTint.opacity(0.15)) : AnyShapeStyle(Color.hqFill3)))
                .contentShape(Capsule())
        }
    }
}

/// The card's fill, as the Add a task field had it: a faint wash in the iOS look, the look's outlined card otherwise.
private struct IdeaCardBackground: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.isDesktop ? DesktopRows.radius : 14, style: .continuous)
        content.background {
            if Theme.isDesktop {
                shape.fill(Color.hqGroupedCard).overlay { shape.strokeBorder(Color.hqStroke, lineWidth: 1) }
            } else {
                shape.fill(Color.hqLabel.opacity(0.06))
            }
        }
    }
}

/// One idea: the to-do, why now, who could help and how, where it came from; Add, Add & Let <Bot> Start, and ×.
struct TaskIdeaCard: View {
    var card: TaskIdeaCardModel
    var enabled: Bool
    var add: (_ start: Bool) -> Void
    var dismiss: () -> Void
    @ScaledMetric(relativeTo: .footnote) private var faceSize: CGFloat = 18

    private var idea: TaskIdea { card.idea }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(idea.title.isEmpty ? "Untitled Idea" : idea.title)
                    .font(Font.hq(.callout).weight(.semibold))
                    .foregroundStyle(Color.hqLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(Font.hq(.footnote).weight(.semibold))
                        .foregroundStyle(Color.hqLabel3)
                        .frame(width: 28, height: 22)
                        .contentShape(Rectangle().inset(by: -8))
                }
                .buttonStyle(.plain)
                .disabled(!enabled || card.busy)
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("tasks.idea.dismiss.\(idea.title)")
            }
            if !idea.why.isEmpty {
                Text(idea.why)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if idea.botHelps {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    let size = min(26, faceSize).rounded()
                    HeadImage(raw: card.head, profile: idea.bot, size: size)
                        .frame(width: size, height: size)
                        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + HQFont.preferred(.footnote).capHeight / 2 }
                        .accessibilityHidden(true)
                    helpLine
                        .font(Font.hq(.footnote))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !idea.source.isEmpty {
                // Its own row, not a Label: at the largest sizes a Label ran the second line back under the icon.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "text.bubble")
                        .accessibilityHidden(true)
                    Text(idea.source)
                        .lineLimit(2)   // one line cut "Chat with Inbox, yesterday" short at the largest sizes
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Font.hq(.caption))
                .foregroundStyle(Color.hqLabel3)
            }
            buttons
                .padding(.top, 2)
        }
        .padding(14)
        .modifier(IdeaCardBackground())
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tasks.idea.\(idea.title)")
    }

    private var helpLine: Text {
        let name = Text(card.botName).fontWeight(.semibold).foregroundStyle(Color.hqLabel)
        let can = Text(idea.who == "bot" ? " can do this" : " can help").foregroundStyle(Color.hqLabel)
        guard !idea.help.isEmpty else { return Text("\(name)\(can)") }
        return Text("\(name)\(can)\(Text(" · \(idea.help)").foregroundStyle(Color.hqLabel2))")
    }

    @ViewBuilder private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { addButtons }
            VStack(alignment: .leading, spacing: 8) { addButtons }
        }
        .disabled(!enabled || card.busy)
    }

    @ViewBuilder private var addButtons: some View {
        Button { add(false) } label: {
            HStack(spacing: 5) {
                if card.busy { ProgressView().controlSize(.mini) } else { Image(systemName: "plus") }
                Text("Add")
            }
        }
        .buttonStyle(IdeaButtonStyle(prominent: true))
        .accessibilityLabel("Add to To Do")
        .accessibilityIdentifier("tasks.idea.add.\(idea.title)")
        if idea.botHelps {
            Button { add(true) } label: {
                Text("Add & Let \(card.botName) Start")
            }
            .buttonStyle(IdeaButtonStyle(prominent: false))
            .accessibilityIdentifier("tasks.idea.start.\(idea.title)")
        }
    }
}

/// The Ideas page's top line: who looks and when, when it last looked; Look Now (Looking… while it runs).
struct TaskIdeasStatusRow: View {
    var botName: String
    var head: JSONValue?
    var profile: String
    var at: String
    var ranAt: String?
    var looking: Bool
    var enabled: Bool
    var lookNow: () -> Void
    @ScaledMetric(relativeTo: .footnote) private var faceSize: CGFloat = 20
    @Environment(\.dynamicTypeSize) private var typeSize

    static func time(_ at: String) -> String {
        TodoSettingsModel.time(at).formatted(date: .omitted, time: .shortened)
    }

    // Owner 2026-11-08: one sentence with "· Looked nov 5" broke after the dot and lowercased the month. Now two
    // lines that each stand alone: when it looks, then when it last did.
    private var words: String {
        looking ? "\(botName) is looking at your recent chats…" : "\(botName) looks each day at \(Self.time(at))"
    }

    /// "Last looked Nov 5", "Last looked 2 h ago", "Last looked just now"; nil before the first look and while looking.
    private var lastLooked: String? {
        guard !looking else { return nil }
        let ago = TodoWords.ago(ranAt, now: Date())
        guard !ago.isEmpty else { return nil }
        return "Last looked \(ago == "Just now" ? "just now" : ago)"
    }

    var body: some View {
        // At the accessibility sizes Look Now goes under the words (beside them, the words ran to four short lines).
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                                                  : AnyLayout(HStackLayout(spacing: 10))
        layout {
            HStack(spacing: 10) {
                let size = min(28, faceSize).rounded()
                HeadImage(raw: head, profile: profile, size: size)
                    .frame(width: size, height: size)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(words)
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("tasks.ideas.status")
                    if let lastLooked {
                        Text(lastLooked)
                            .font(Font.hq(.caption))
                            .foregroundStyle(Color.hqLabel2)
                            .lineLimit(1)
                            .accessibilityIdentifier("tasks.ideas.last-looked")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if looking {
                ProgressView().controlSize(.small)
            } else {
                Button("Look Now", action: lookNow)
                    .font(Font.hq(.footnote).weight(.semibold))
                    .fixedSize()
                    .foregroundStyle(Color.hqTintText)
                    .buttonStyle(.borderless)
                    .disabled(!enabled)
                    .accessibilityIdentifier("tasks.ideas.look-now")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .frame(minHeight: 44)
    }
}

/// The Ideas page's other rows.
nonisolated enum TaskIdeasNote: Hashable, Sendable {
    /// Ideas is off: what it does, and Turn On.
    case intro(looker: String)
    /// The add-on on the computer has no Ideas yet.
    case update(asked: Bool)
    /// On, and nothing new.
    case empty(String)
    /// Ideas couldn't be read and none are saved: the reason, and Try Again.
    case failed(String)
    /// Under the cards: where ideas come from.
    case footer
    /// To Do with nothing to show: no tasks at all, or none with the bot picked in the pills (under the switch, so
    /// Ideas stays a tap away). `imports`: Import from Reminders is offered (it adds your own tasks).
    case noTasks(text: String, imports: Bool)

    /// Mac polish #139: the add-on by the name its update sheet uses, on the computer that runs it (on a Mac, "your
    /// computer" read as this Mac).
    static let updateText = "Ideas needs \(AddOnUpdate.pushName) 0.9.39 or later on \(HostWord.phrase)."
}

struct TaskIdeasNoteView: View {
    var note: TaskIdeasNote
    var enabled: Bool
    var primary: () -> Void
    var secondary: () -> Void

    var body: some View {
        switch note {
        case .intro(let looker):
            card(symbol: "lightbulb.max", title: "Ideas for Your List",
                 text: "Once a day, \(looker) looks through your recent chats and whatever else it can reach, like your calendar or email, and suggests a few tasks you may want. Nothing goes on your list or starts until you choose.",
                 button: "Turn On Ideas", id: "tasks.ideas.turn-on",
                 small: "Choose who looks and when in Tasks Settings.")
        case .update(let asked):
            card(symbol: "puzzlepiece.extension", title: "Update the Add-on",
                 text: TaskIdeasNote.updateText,
                 button: asked ? "Updating…" : "Update Add-on", id: "tasks.ideas.update", small: nil)
        case .failed(let reason):
            // Reading again is no change: Try Again works on a read-only gateway too.
            card(symbol: "exclamationmark.triangle", title: "Couldn’t Load Ideas", text: reason.isEmpty ? "Ideas couldn’t be read." : reason,
                 button: "Try Again", id: "tasks.ideas.retry", small: nil, enabled: true)
        case .empty(let text):
            VStack(spacing: 6) {
                Image(systemName: "lightbulb")
                    .font(Font.hq(.title2))
                    .foregroundStyle(Color.hqLabel3)
                Text("No New Ideas").font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                Text(text)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.vertical, 36)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("tasks.ideas.empty")
        case .footer:
            Text("Ideas come from your recent chats and whatever else your bot can reach. Nothing happens until you add one.")
                .font(Font.hq(.footnote))
                .foregroundStyle(Color.hqLabel3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("tasks.ideas.footer")
        case .noTasks(let text, let imports):
            VStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(Font.hq(.largeTitle))
                    .foregroundStyle(Color.hqLabel3)
                    .padding(.bottom, 4)
                Text("No Tasks").font(Font.hq(.title3).weight(.semibold)).foregroundStyle(Color.hqLabel)
                Text(text)
                    .font(Font.hq(.subheadline))
                    .foregroundStyle(Color.hqLabel2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("tasks.empty.text")
                // [mac] Mac polish #107: the Mac's empty-state push buttons, as Tasks' other states and every Mac empty
                // state have (New Task was the blue default button, Import a bare link).
                if DeviceWord.isMac {
                    Button("New Task", action: primary)
                        .hqMacPushOnly()
                        .disabled(!enabled)
                        .padding(.top, 8)
                        .accessibilityIdentifier("tasks.empty.new")
                    if imports {
                        Button("Import from Reminders", action: secondary).hqMacPushOnly().disabled(!enabled)
                    }
                } else {
                    Button(action: primary) { Text("New Task").font(Font.hq(.body).weight(.semibold)).padding(.horizontal, 6) }
                        .hqProminentButtonStyle()
                        .buttonBorderShape(.capsule)
                        .disabled(!enabled)
                        .padding(.top, 8)
                        .accessibilityIdentifier("tasks.empty.new")
                    if imports {
                        Button("Import from Reminders", action: secondary)
                            .font(Font.hq(.subheadline))
                            .foregroundStyle(Color.hqTintText)
                            .buttonStyle(.borderless)
                            .disabled(!enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.top, 56)
            .padding(.bottom, 24)
        }
    }

    private func card(symbol: String, title: String, text: String, button: String, id: String, small: String?,
                      enabled: Bool? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(Font.hq(.title3).weight(.semibold))
                    .foregroundStyle(Color.hqTintText)
                    .accessibilityHidden(true)
                Text(title).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
            }
            Text(text)
                .font(Font.hq(.subheadline))
                .foregroundStyle(Color.hqLabel2)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: primary) {
                Text(button).font(Font.hq(.subheadline).weight(.semibold)).frame(minHeight: 30).padding(.horizontal, 4)
            }
            .hqProminentButtonStyle()
            .buttonBorderShape(.capsule)
            .disabled(!(enabled ?? self.enabled))
            .padding(.top, 2)
            .accessibilityIdentifier(id)
            if let small {
                // Mac polish #68: the card's last line in its note grey (label 2 in the iOS look; label 3 read 2.2:1).
                Text(small).font(Font.hq(.caption)).foregroundStyle(Color(uiColor: HQPalette.cardNote))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .modifier(IdeaCardBackground())
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}
