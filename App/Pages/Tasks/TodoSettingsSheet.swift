// [tasks] Tasks settings (the page's ⋯ › Tasks Settings): how bots catch tasks in your chats (Automatic / Ask First /
// Off), how often they may work on getting tasks ready (runs a day, quiet hours), Ideas ([task-ideas] on or off, who
// looks, when, how many), and Import from Reminders. The
// settings live with the list on the computer (`/tasks/settings`), so every device and bot sees the same.

import EventKit
import SwiftUI
import UIKit

@MainActor @Observable
final class TodoSettingsModel {
    let store: TasksStore
    var draft: TodoSettings
    /// The bots that could look for ideas (id, name).
    let bots: [(id: String, name: String)]
    @ObservationIgnored weak var controller: UIViewController?
    /// [task-ideas] An Ideas setting was saved: the Ideas page reads again.
    @ObservationIgnored var ideasChanged: (() -> Void)?

    init(store: TasksStore, bots: [(id: String, name: String)] = []) {
        self.store = store
        self.bots = bots
        draft = store.settings
    }

    func save() {
        Task { await commit() }
    }

    /// Saves the draft. A save that didn't land puts the controls back to what the gateway keeps (unless another
    /// change has gone out since, which carries this one with it).
    func commit() async {
        guard draft != store.settings else { return }
        let next = draft, before = store.settings
        let ideas = next.ideas != before.ideas || next.ideasBot != before.ideasBot || next.ideasAt != before.ideasAt
            || next.ideasMax != before.ideasMax
        guard await store.saveSettings(next) else {
            PagesHaptics.error()   // the HUD says why
            if draft == next { draft = store.settings }
            return
        }
        if ideas { ideasChanged?() }
    }

    func botName(_ id: String) -> String { bots.first { $0.id == id }?.name ?? id }

    static func time(_ text: String) -> Date {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: parts.first ?? 0, minute: parts.count > 1 ? parts[1] : 0, second: 0, of: Date()) ?? Date()
    }

    static func text(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

enum TodoSettingsSheet {
    static func make(store: TasksStore, bots: [Bot] = [], ideasChanged: (() -> Void)? = nil) -> UIViewController {
        let model = TodoSettingsModel(store: store, bots: bots.map { ($0.id, PagesNames.botName($0.id, bots: bots)) })
        model.ideasChanged = ideasChanged
        let host = UIHostingController(rootView: HQScaledRoot(TodoSettingsView(model: model)))
        model.controller = host
        let nav = ChatSheet.wrap(host, title: "Tasks Settings")
        // Half height cut off the quiet hours' footer and Import from Reminders.
        nav.sheetPresentationController?.selectedDetentIdentifier = .large
        return nav
    }
}

struct TodoSettingsView: View {
    @Bindable var model: TodoSettingsModel

    var body: some View {
        Form {
            Section {
                HQSegmentedPicker("Catch Tasks in Chats", options: [("Ask First", "ask"), ("Automatic", "auto"), ("Off", "off")],
                                  selection: Binding(get: { model.draft.capture }, set: { PagesHaptics.selection(); model.draft.capture = $0; model.save() }), ticks: false)
                    .accessibilityIdentifier("tasks.settings.capture")
            } header: { HQSectionLabel { Text("Catch Tasks in Chats") } } footer: { HQSectionFooter {
                switch model.draft.capture {
                case "auto": Text("When you say you need to do something, a bot adds it to Tasks, takes the part it can do, and tells you. Undo takes it back.")
                case "off": Text("Bots add tasks only when you ask them to.")
                default: Text("When you say you need to do something, a bot asks what it could do for it first. Pick what it should do, or just add it; skip, and nothing goes on your list.")
                }
            } }
            .hqSheetRows()

            Section {
                Stepper(value: Binding(get: { model.draft.prepPerDay }, set: { PagesHaptics.selection(); model.draft.prepPerDay = $0; model.save() }), in: 0...24) {
                    LabeledContent("Times a Day") {
                        Text(model.draft.prepPerDay == 0 ? "Never" : "\(model.draft.prepPerDay)").monospacedDigit().foregroundStyle(Color.hqLabel2)
                    }
                }
                .accessibilityIdentifier("tasks.settings.per-day")
                HQDatePicker("Quiet From", selection: Binding(get: { TodoSettingsModel.time(model.draft.quietStart) },
                                                           set: { model.draft.quietStart = TodoSettingsModel.text($0); model.save() }),
                           displayedComponents: .hourAndMinute)
                HQDatePicker("Quiet Until", selection: Binding(get: { TodoSettingsModel.time(model.draft.quietEnd) },
                                                            set: { model.draft.quietEnd = TodoSettingsModel.text($0); model.save() }),
                           displayedComponents: .hourAndMinute)
            } header: { HQSectionLabel { Text("Getting Tasks Ready") } } footer: { HQSectionFooter {
                Text("How often your bots may work on tasks set to get ready, across every bot. Nothing runs in the quiet hours.")
            } }
            .hqSheetRows()

            if model.draft.ideas != nil { ideasSection }

            Section {
                Button {
                    guard let controller = model.controller else { return }
                    PagesHaptics.selection()
                    TodoRemindersImport.run(store: model.store, from: controller) { text, ok in
                        PagesHUD.show(text, symbol: ok ? "checkmark" : "exclamationmark.triangle", from: controller, duration: ok ? nil : 4)
                    }
                } label: {
                    Label("Import from Reminders", systemImage: "square.and.arrow.down").foregroundStyle(Color.hqTint)
                }
                .accessibilityIdentifier("tasks.settings.import")
            } footer: { HQSectionFooter { Text("Adds your open reminders as your own tasks. Reminders keeps them too.") } }
            .hqSheetRows()
        }
        .hqGroupedPage()
    }

    /// [task-ideas] Shown when the add-on keeps Ideas (0.9.39+).
    @ViewBuilder private var ideasSection: some View {
        let on = model.draft.ideas == true
        let looker = model.draft.ideasBot ?? "default"
        Section {
            Toggle(isOn: Binding(get: { on }, set: { model.draft.ideas = $0; model.save() })) {
                Text("Suggest Tasks")
            }
            .accessibilityIdentifier("tasks.settings.ideas")
            if on {
                if model.bots.count > 1 {
                    Picker("Who Looks", selection: Binding(get: { looker }, set: { PagesHaptics.selection(); model.draft.ideasBot = $0; model.save() })) {
                        ForEach(model.bots, id: \.id) { bot in Text(bot.name).tag(bot.id) }
                    }
                    .accessibilityIdentifier("tasks.settings.ideas-bot")
                }
                HQDatePicker("Each Day At", selection: Binding(get: { TodoSettingsModel.time(model.draft.ideasAt ?? "07:30") },
                                                            set: { model.draft.ideasAt = TodoSettingsModel.text($0); model.save() }),
                           displayedComponents: .hourAndMinute)
                    .accessibilityIdentifier("tasks.settings.ideas-at")
                Stepper(value: Binding(get: { model.draft.ideasMax ?? 3 }, set: { PagesHaptics.selection(); model.draft.ideasMax = $0; model.save() }), in: 1...5) {
                    LabeledContent("Ideas a Day") {
                        Text("Up to \(model.draft.ideasMax ?? 3)").monospacedDigit().foregroundStyle(Color.hqLabel2)
                    }
                }
                .accessibilityIdentifier("tasks.settings.ideas-max")
            }
        } header: { HQSectionLabel { Text("Ideas") } } footer: { HQSectionFooter {
            Text("Once a day, \(model.botName(looker)) looks through your recent chats and whatever else it can reach, like your calendar or email, and suggests a few tasks under Ideas. It can’t put anything on your list itself: nothing goes there until you add it.")
        } }
        .hqSheetRows()
    }
}

// MARK: - Import from Reminders

/// Your open reminders, added as `me` tasks (title, notes, due, repeat) with `source: reminders` so a second import
/// skips them. `done`: the words for the result, and whether anything went in.
@MainActor
enum TodoRemindersImport {
    static func run(store: TasksStore, from host: UIViewController, done: @escaping (String, Bool) -> Void) {
        Task {
            guard await EventKitAccess.requestReminders(),
                  EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                let alert = UIAlertController(title: "Reminders Is Off for Hermes HQ",
                                              message: "Allow Full Access to Reminders in \(DeviceWord.settingsApp), then try again.",
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Open \(DeviceWord.settingsApp)", style: .default) { _ in
                    PagesHaptics.selection()
                    if let url = URL(string: Self.remindersSettingsLink) { UIApplication.shared.open(url) }
                })
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                host.present(alert, animated: true)
                return
            }
            let reminders = await fetchOpen()
            let known = Set(store.tasks.compactMap { $0.source?.reminderId })
            let fresh = reminders.filter { !known.contains($0.id) && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !fresh.isEmpty else { done(reminders.isEmpty ? "No open reminders" : "Already imported", true); return }
            let alert = UIAlertController(title: "Import \(fresh.count) Reminder\(fresh.count == 1 ? "" : "s")?",
                                          message: "They’re added as your own tasks. Reminders keeps them too.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Import", style: .default) { _ in
                PagesHaptics.selection()
                // A long import says it's under way (each reminder is its own add).
                let progress = PagesHUD.show("Importing \(fresh.count) Reminder\(fresh.count == 1 ? "" : "s")…", from: host, duration: 600)
                Task {
                    var added = 0
                    var reason: String?
                    for reminder in fresh {
                        let fields = TodoWire.newTask(title: reminder.title, who: .me, bot: nil,
                                                      due: reminder.due.map { TodoDates.wire($0.date, hasTime: $0.hasTime) },
                                                      repeatRule: reminder.repeatRule, prep: false, notes: reminder.notes,
                                                      source: TodoSource(kind: "reminders", reminderId: reminder.id))
                        // Quiet: one notice for the whole import, not one per reminder.
                        if await store.add(fields, quiet: true) != nil { added += 1 } else { reason = reason ?? store.addFailure }
                    }
                    progress?.dismiss(animated: false)
                    AppLog.note("tasks", "imported \(added) of \(fresh.count) reminders")
                    let words = importResult(added: added, of: fresh.count, reason: reason)
                    if added > 0 { PagesHaptics.success() } else { PagesHaptics.error() }
                    done(words, added > 0)
                }
            })
            host.present(alert, animated: true)
        }
    }

    /// Where Open System Settings goes: the app's own page in iOS Settings. [mac] Mac polish #11: on the Mac that link
    /// opens nothing; System Settings › Privacy & Security › Reminders is where the switch is.
    #if targetEnvironment(macCatalyst)
    static let remindersSettingsLink = "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
    #else
    static let remindersSettingsLink = UIApplication.openSettingsURLString
    #endif

    /// What an import says when it's over.
    nonisolated static func importResult(added: Int, of count: Int, reason: String?) -> String {
        if added == 0 { return "Couldn’t import your reminders. \(reason ?? "Check your connection, then try again.")" }
        let done = added == 1 ? "Imported 1 reminder" : "Imported \(added) reminders"
        let left = count - added
        guard left > 0 else { return done }
        return "\(done). \(left) couldn’t be added."
    }

    /// A reminder's repeat as a task's (`TodoWords.repeatRules`): only the plain ones (every day, weekday, week, month or
    /// year); anything else comes in without a repeat.
    nonisolated static func repeatRule(_ rules: [EKRecurrenceRule]?) -> String? {
        guard let rules, rules.count == 1, let rule = rules.first, rule.interval == 1 else { return nil }
        let days = Set((rule.daysOfTheWeek ?? []).map(\.dayOfTheWeek.rawValue))
        switch rule.frequency {
        case .daily: return days.isEmpty ? "daily" : nil
        case .weekly:
            if days.isEmpty || days.count == 1 { return "weekly" }
            return days == Set([2, 3, 4, 5, 6]) ? "weekdays" : nil   // EKWeekday: Sunday is 1
        case .monthly: return days.isEmpty ? "monthly" : nil
        case .yearly: return days.isEmpty ? "yearly" : nil
        @unknown default: return nil
        }
    }

    nonisolated struct Reminder: Sendable {
        var id: String
        var title: String
        var notes: String
        var due: (date: Date, hasTime: Bool)?
        var repeatRule: String?
    }

    /// Nonisolated: EventKit calls back on its own queue, and a closure written in this main-actor enum checks it's
    /// on the main thread when it runs. That check stopped the app on every import (build 755 and Mac 756).
    nonisolated private static func fetchOpen() async -> [Reminder] {
        let store = EventKitAccess.store
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let box: SendableBox<[Reminder]> = await withCheckedContinuation { continuation in
            _ = store.fetchReminders(matching: predicate) { reminders in
                let rows = (reminders ?? []).map { reminder in
                    Reminder(id: reminder.calendarItemIdentifier, title: reminder.title ?? "", notes: reminder.notes ?? "",
                             due: DeviceAccess.reminderDue(reminder.dueDateComponents),
                             repeatRule: repeatRule(reminder.recurrenceRules))
                }
                continuation.resume(returning: SendableBox(rows))
            }
        }
        return box.value
    }
}

#if DEBUG
extension TodoRemindersImport {
    /// `-HQPagesImportReminders N` (PagesDebug): N open reminders in the default list, one with a due day, so the
    /// import has something to read.
    nonisolated static func seedForDebug(_ count: Int) async {
        guard count > 0, await EventKitAccess.requestReminders() else { return }
        let store = EventKitAccess.store
        guard let list = store.defaultCalendarForNewReminders() else { return }
        for index in 1...count {
            let reminder = EKReminder(eventStore: store)
            reminder.calendar = list
            reminder.title = "Debug reminder \(index)"
            if index == 1 { reminder.dueDateComponents = DateComponents(year: 2026, month: 11, day: 20) }
            try? store.save(reminder, commit: false)
        }
        try? store.commit()
    }
}
#endif
