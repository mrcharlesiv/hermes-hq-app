// [tasks] A task's history (owner 2026-11-07, Pinned Task step 1): ⋯ › History, or a tap on the brief's state line.
// The Activity that had stood on every task (three or five lines repeating its card and its chat) is here whole, newest
// first: what its bot watches for on top, where it came from at the foot.

import SwiftUI

struct TodoHistoryView: View {
    let task: TodoTask
    let origin: String
    let botName: (String?) -> String
    let head: (String) -> JSONValue?
    let open: (String) -> Void

    var body: some View {
        List {
            if let watching = TodoWords.watching(task) {
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "eye").font(Font.hq(.subheadline).weight(.semibold)).foregroundStyle(Color.hqLabel2)
                            .accessibilityHidden(true)
                        Text(watching).font(Font.hq(.body)).foregroundStyle(Color.hqLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("task.history.watch")
                }
                .hqSheetRows()
            }
            Section {
                if task.log.isEmpty {
                    Text("Nothing has happened yet.").font(Font.hq(.body)).foregroundStyle(Color.hqLabel2)
                }
                ForEach(Array(task.log.reversed().enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            if entry.by == "you" {
                                Image(systemName: "person.crop.circle.fill").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel3)
                            } else {
                                HeadImage(raw: head(entry.by), profile: entry.by, size: 18)
                            }
                            Text(entry.by == "you" ? "You" : botName(entry.by))
                                .font(Font.hq(.footnote).weight(.semibold)).foregroundStyle(Color.hqLabel)
                            Spacer(minLength: 8)
                            Text(TodoWords.ago(entry.at, now: Date())).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                        }
                        .accessibilityElement(children: .combine)
                        TodoRichTextView(text: TodoReadable.logText(entry.text), style: .subheadline, readable: false, open: open)
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                HQSectionFooter { Text(origin) }
            }
            .hqSheetRows()
        }
        .hqGroupedPage()
        .accessibilityIdentifier("task.history")
    }
}
