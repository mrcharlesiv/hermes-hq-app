import SwiftUI

/// Uses the same marks as the project rows so the guide follows the current theme.
struct ProjectIconGuide: View {
    let coding: Bool

    var body: some View {
        List {
            if coding {
                Section {
                    ForEach([SessionPRStatus.State.none, .draft, .open, .merged, .closed, .unknown], id: \.self) { state in
                        entry(SessionPRStatus(state: state).label, explanation(state)) {
                            Image(uiImage: SessionPRGlyph.image(state)).renderingMode(.template)
                                .resizable().frame(width: 18, height: 18)
                                .foregroundStyle(Color(uiColor: SessionPRGlyph.color(state)))
                        }.accessibilityIdentifier("project.legend.\(state.rawValue)")
                    }
                } header: { HQSectionLabel { Text("Code changes") } }
                  footer: { HQSectionFooter { Text("Counts include only available PR statuses.") } }
            }
            Section {
                entry("Needs You", "The chat is waiting for your input.") { ProjectStateMark(state: .needsYou) }
                entry("New", "There’s an unread update in the chat.") { ProjectStateMark(state: .ready) }
                entry("Working", "The bot is working in the chat.") { ProjectStateMark(state: .working) }
            } header: { HQSectionLabel { Text("Chat activity") } }
        }.settingsList()
    }

    private func entry<Mark: View>(_ title: String, _ detail: String, @ViewBuilder mark: () -> Mark) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            mark().frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Font.hq(.body).weight(.semibold)).foregroundStyle(Color.hqLabel)
                Text(detail).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
            }
        }.accessibilityElement(children: .combine)
    }

    private func explanation(_ state: SessionPRStatus.State) -> String {
        switch state {
        case .none: "No branch or pull request from this chat yet."
        case .draft: "On a branch that isn’t merged yet, or a draft pull request."
        case .open: "A pull request is open for review."
        case .merged: "The changes are merged into main."
        case .closed: "Closed without merging, or marked closed by you."
        case .unknown: "Couldn’t be checked, or the chat’s branch isn’t in a linked repository."
        }
    }
}
