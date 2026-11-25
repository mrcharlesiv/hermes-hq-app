// Unified Completed Logbook for Tasks: all completed work across lists, grouped by Today, Yesterday,
// This Week, Earlier This Month, and month headings, searchable with quick open or reopen.

import SwiftUI
import UIKit

enum TaskLogbookSheet {
    static func make(store: TasksStore, bots: [Bot], onOpen: @escaping (String) -> Void) -> UIViewController {
        let host = UIHostingController(rootView: HQScaledRoot(TaskLogbookView(store: store, bots: bots, onOpen: onOpen)))
        let nav = ChatSheet.wrap(host, title: "Completed Logbook", detents: [.large()])
        nav.sheetPresentationController?.selectedDetentIdentifier = .large
        return nav
    }
}

struct TaskLogbookView: View {
    let store: TasksStore
    let bots: [Bot]
    var onOpen: (String) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var groups: [TodoLogbookGroup] {
        TodoViews.logbook(store.tasks, query: query)
    }

    private func listName(_ id: String?) -> String? {
        id.flatMap { id in store.sections.first { $0.id == id }?.name }
    }

    private func botName(_ profile: String?) -> String {
        PagesNames.botName(profile ?? "default", bots: bots)
    }

    private func finishedLabel(_ task: TodoTask) -> String {
        let stamp = task.doneAt ?? task.updatedAt ?? task.createdAt
        guard let at = TodoDates.moment(stamp) else { return "" }
        let day = TodoWords.day(at, now: Date())
        if day == "Today" || day == "Yesterday" { return TodoWords.clock(at) }
        return day
    }

    var body: some View {
        List {
            if groups.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(Font.hq(.largeTitle))
                            .foregroundStyle(Color.hqLabel3)
                        Text(query.trimmingCharacters(in: .whitespaces).isEmpty ? "No Completed Tasks" : "No Matching Tasks")
                            .font(Font.hq(.headline))
                            .foregroundStyle(Color.hqLabel)
                        Text(query.trimmingCharacters(in: .whitespaces).isEmpty
                             ? "Tasks you and your bots finish show up here, grouped by when they were done."
                             : "Try a different word or clear your search.")
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqLabel2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.tasks) { task in
                            row(task)
                        }
                    } header: {
                        HQSectionLabel { Text("\(group.title)  \(group.tasks.count)") }
                    }
                    .hqSheetRows()
                }
            }
        }
        .hqGroupedPage()
        .searchable(text: $query, prompt: "Search Completed Tasks")
        .accessibilityIdentifier("tasks.logbook")
    }

    private func row(_ task: TodoTask) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                PagesHaptics.selection()
                Task { if await !store.setDone(task.id, false) { PagesHaptics.error() } }
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(Font.hq(.title3).weight(.light))
                    .foregroundStyle(Color.hqTint)
                    .contentShape(Rectangle().inset(by: -8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reopen \(task.title)")
            .accessibilityIdentifier("tasks.logbook.reopen.\(task.id)")

            Button {
                PagesHaptics.selection()
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { onOpen(task.id) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title.isEmpty ? "Untitled Task" : task.title)
                        .font(Font.hq(.callout))
                        .foregroundStyle(Color.hqLabel)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    let meta = metadataLine(task)
                    if !meta.isEmpty {
                        Text(meta)
                            .font(Font.hq(.caption))
                            .foregroundStyle(Color.hqLabel2)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            let when = finishedLabel(task)
            if !when.isEmpty {
                Text(when)
                    .font(Font.hq(.caption))
                    .monospacedDigit()
                    .foregroundStyle(Color.hqLabel2)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("tasks.logbook.row.\(task.id)")
    }

    private func metadataLine(_ task: TodoTask) -> String {
        var parts: [String] = []
        if let list = listName(task.section) { parts.append(list) }
        if let goalID = task.goal, let goal = store.goal(goalID), !goal.title.isEmpty { parts.append(goal.title) }
        if task.helper != nil { parts.append(TodoViews.who(task, botName: botName)) }
        return parts.joined(separator: " · ")
    }
}
