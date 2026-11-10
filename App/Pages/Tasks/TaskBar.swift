// [tasks] The pinned task rolled up (owner 2026-11-07, Pinned Task step 3): once you take up the chat, the task becomes
// one glass bar under the chat's bar; a tap brings the whole task back. Plain since 2026-11-09 (TaskPlainView).

import SwiftUI

struct TaskBarView: View {
    @Bindable var model: TodoSheetModel
    let task: TodoTask

    // Owner 2026-11-09 (the plain task view): over its chat the task is one quiet line, a dot in its state's colour and
    // the bot's latest word (its question while it needs you), or your next step; a tap brings the task back. The
    // progress marks, the state line and the move button it had are gone: the task's view has them, once.
    var body: some View {
        let color = TodoSheetView.statusColor(task.status)
        HStack(alignment: .center, spacing: 10) {
            if task.isDone {
                Image(systemName: "checkmark.circle.fill").font(Font.hq(.subheadline)).foregroundStyle(color)
                    .accessibilityHidden(true)
                Text(Self.completed(task)).font(Font.hq(.subheadline)).foregroundStyle(color).lineLimit(1)
                    .accessibilityIdentifier("task.bar.completed")
            } else {
                Circle().fill(task.status == "open" ? Color.hqLabel3 : color).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(line)
                    .font(Font.hq(.subheadline))
                    .foregroundStyle(Color.hqLabel)
                    .lineLimit(2)
                    .accessibilityIdentifier("task.bar.words")
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.down").font(Font.hq(.caption).weight(.semibold)).foregroundStyle(Color.hqLabel3)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture { model.untuck() }
        .hqGlassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 8).padding(.vertical, 6)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.onLeadHeight?($0) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows the whole task")
        .accessibilityIdentifier("task.bar")
    }

    /// Its question while it needs you; else the bot's latest word; else your next step; else the title.
    private var line: String {
        let note = task.statusNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if task.status == "needs_you", !note.isEmpty { return note }
        if let words = TodoWords.botWords(task) { return words }
        if let next = task.steps.first(where: { !$0.done && $0.who != "bot" }) { return next.title }
        return task.title
    }

    /// "Completed today, 11:40 AM", "Completed Nov 5, 9:02 AM"; "Completed" when it doesn't say when.
    static func completed(_ task: TodoTask, now: Date = Date()) -> String {
        guard let date = TodoDates.moment(TodoWords.stateSince(task)) else { return "Completed" }
        let day = TodoWords.day(date, now: now)
        return "Completed \(day == "Today" || day == "Yesterday" ? day.lowercased() : day), \(TodoWords.clock(date))"
    }
}
