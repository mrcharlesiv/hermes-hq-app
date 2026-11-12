// [task-ideas] A bot's ideas for your list. [tasks-first] Owner 2026-11-12 (mockup 2-list-other-views): they no longer
// take half of a To Do | Ideas switch; they are short rows at the foot of Inbox under "Suggested by <Bot>": the idea,
// what the bot could do, Add and ×. A tap on one opens its card (why now, where it came from, Add & Let <Bot> Start).

import SwiftUI

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
        .accessibilityLabel("Add to Tasks")
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

/// "Suggested by Hermes 3" over the ideas, with when it last looked at its end: a menu with Look Now.
struct TaskIdeasHead: View {
    var botName: String
    var count: Int
    var at: String
    var ranAt: String?
    var looking: Bool
    var enabled: Bool
    var lookNow: () -> Void
    var settings: () -> Void

    static func time(_ at: String) -> String {
        TodoSettingsModel.time(at).formatted(date: .omitted, time: .shortened)
    }

    /// "Looked 3 h ago", "Looked just now"; "Looks at 7:30 AM" before its first look.
    private var looked: String {
        let ago = TodoWords.ago(ranAt, now: Date())
        guard !ago.isEmpty else { return "Looks at \(Self.time(at))" }
        return "Looked \(ago == "Just now" ? "just now" : ago)"
    }

    var body: some View {
        HStack(spacing: 6) {
            TodoGroupHeaderView.Words(title: "Suggested by \(botName)", detail: nil, count: count > 0 ? count : nil, red: false)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("tasks.ideas.status")
            Spacer(minLength: 8)
            if looking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Looking…").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                }
                .accessibilityIdentifier("tasks.ideas.looking")
            } else {
                Menu {
                    Button { lookNow() } label: { Label("Look Now", systemImage: "arrow.clockwise") }.disabled(!enabled)
                    Button { settings() } label: { Label("Ideas Settings…", systemImage: "gearshape") }
                } label: {
                    HStack(spacing: 3) {
                        Text(looked).font(Font.hq(.footnote))
                        Image(systemName: "chevron.down").font(Font.hq(.caption2).weight(.semibold))
                    }
                    .foregroundStyle(Color.hqLabel2)
                    .padding(.vertical, 8).padding(.leading, 12)
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .padding(.vertical, -8)
                .accessibilityLabel("\(looked). Options")
                .accessibilityIdentifier("tasks.ideas.look")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One idea as a row: a sparkle, the to-do, Add and ×; under it what the bot could do (else why now). A tap opens
/// its card.
struct TaskIdeaRow: View {
    var card: TaskIdeaCardModel
    var enabled: Bool
    var add: () -> Void
    var dismiss: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    private var idea: TaskIdea { card.idea }

    private var second: String {
        if idea.botHelps {
            let can = idea.who == "bot" ? "can do this" : "can help"
            return idea.help.isEmpty ? "\(card.botName) \(can)" : "\(card.botName) \(can): \(idea.help)"
        }
        return idea.why
    }

    var body: some View {
        let large = typeSize.isAccessibilitySize
        // Up to two lines each (owner 2026-11-12, a screenshot of six ideas all cut short, "Find affordable hourly
        // help for…": "allow a second line maybe so that they don't have an ellipsis"). A short one stays one line.
        // The grey line runs under Add and × to the row's edge, so two lines hold half as much again.
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "sparkle")
                    .font(Font.hq(.footnote).weight(.semibold))
                    .foregroundStyle(Color.hqTintText)
                    .frame(width: HQFont.scaled(22))
                    .accessibilityHidden(true)
                Text(idea.title.isEmpty ? "Untitled Idea" : idea.title)
                    .font(Font.hq(.callout))
                    .foregroundStyle(Color.hqLabel)
                    .lineLimit(large ? 4 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: add) {
                    HStack(spacing: 4) {
                        if card.busy { ProgressView().controlSize(.mini) }
                        Text("Add")
                    }
                    .font(Font.hq(.footnote).weight(.semibold))
                    .foregroundStyle(Color.hqTintText)
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(Capsule().fill(Color.hqTint.opacity(0.14)))
                    .contentShape(Rectangle().inset(by: -8))
                    // The pill counts as a line of text in the row's height, so the grey line sits as close under a
                    // one-line name as under a two-line one.
                    .padding(.vertical, -3)
                }
                .buttonStyle(.plain)
                .disabled(!enabled || card.busy)
                .accessibilityLabel("Add to Tasks")
                .accessibilityIdentifier("tasks.idea.add.\(idea.title)")
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(Font.hq(.footnote).weight(.semibold))
                        .foregroundStyle(Color.hqLabel3)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle().inset(by: -10))
                }
                .buttonStyle(.plain)
                .disabled(!enabled || card.busy)
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("tasks.idea.dismiss.\(idea.title)")
            }
            if !second.isEmpty {
                Text(second)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .lineLimit(large ? 4 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, HQFont.scaled(22) + 12)
            }
        }
        .padding(.vertical, Theme.isDesktop ? 10 : 8)
        .padding(.horizontal, 20)
        .frame(minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tasks.idea.\(idea.title)")
    }
}

/// The page's other rows.
nonisolated enum TaskIdeasNote: Hashable, Sendable {
    /// Ideas is off: one line at Inbox's foot, and Turn On.
    case off(looker: String)
    /// On, and nothing new: when it looks next.
    case quiet(String)
    /// No tasks at all: New Task, and Import from Reminders when `imports`.
    case noTasks(text: String, imports: Bool)
}

struct TaskIdeasNoteView: View {
    var note: TaskIdeasNote
    var enabled: Bool
    var primary: () -> Void
    var secondary: () -> Void

    var body: some View {
        switch note {
        case .off(let looker):
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "sparkle")
                    .font(Font.hq(.footnote).weight(.semibold))
                    .foregroundStyle(Color.hqLabel3)
                    .frame(width: HQFont.scaled(22))
                    .accessibilityHidden(true)
                Text("\(looker) can suggest tasks from your chats, once a day.")
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Turn On", action: primary)
                    .font(Font.hq(.footnote).weight(.semibold))
                    .foregroundStyle(Color.hqTintText)
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .disabled(!enabled)
                    .accessibilityIdentifier("tasks.ideas.turn-on")
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 12)
        case .quiet(let text):
            Text(text)
                .font(Font.hq(.footnote))
                .foregroundStyle(Color.hqLabel2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("tasks.ideas.empty")
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
}
