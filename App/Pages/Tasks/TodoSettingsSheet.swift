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
    /// Auto-discovered connectors across all bot profiles (`GET /tasks/ideas/sources`).
    var availableSources: TaskIdeasAvailableSources?
    var loadingSources = false
    @ObservationIgnored weak var controller: UIViewController?
    /// [task-ideas] An Ideas setting was saved: the Ideas page reads again.
    @ObservationIgnored var ideasChanged: (() -> Void)?

    init(store: TasksStore, bots: [(id: String, name: String)] = [], initialSources: TaskIdeasAvailableSources? = nil) {
        self.store = store
        self.bots = bots
        self.availableSources = initialSources
        draft = store.settings
    }

    var supportsSources: Bool { draft.ideasSources != nil || availableSources != nil }

    var sources: TodoIdeasSources { draft.ideasSources ?? TodoIdeasSources() }

    var activeBots: [String] { draft.activeIdeasBots }

    var connectors: [TaskIdeasConnector] { availableSources?.connectors ?? [] }

    var sourcesSummary: String {
        TaskIdeasSummary.activeSourcesLabel(sources: sources, available: connectors)
    }

    var botsSummary: String {
        TaskIdeasSummary.activeBotsLabel(active: activeBots, bots: bots)
    }

    func loadSources() async {
        guard !loadingSources else { return }
        loadingSources = true
        defer { loadingSources = false }
        if let fetched = try? await store.api.ideasSources() {
            availableSources = fetched
        }
    }

    func updateSources(_ mutate: (inout TodoIdeasSources) -> Void) {
        var next = sources
        mutate(&next)
        draft.ideasSources = next
        save()
    }

    func setActiveBot(_ id: String, on: Bool) {
        var next = activeBots
        if on {
            if !next.contains(id) { next.append(id) }
        } else {
            guard next.count > 1 else { return }   // at least one bot must stay selected
            next.removeAll { $0 == id }
        }
        PagesHaptics.selection()
        draft.ideasBots = next
        draft.ideasBot = next.first ?? "default"
        save()
    }

    func isChatBotIncluded(_ id: String) -> Bool {
        let picked = sources.chatBots
        return picked.isEmpty || picked.contains(id)
    }

    func setChatBot(_ id: String, on: Bool) {
        let allIDs = bots.map(\.id)
        var picked = sources.chatBots.isEmpty ? allIDs : sources.chatBots.filter { allIDs.contains($0) }
        if on {
            if !picked.contains(id) { picked.append(id) }
        } else {
            guard picked.count > 1 else { return }   // to scan zero chats, toggle Recent Chats off
            picked.removeAll { $0 == id }
        }
        PagesHaptics.selection()
        updateSources { s in
            s.chatBots = Set(picked) == Set(allIDs) ? [] : picked
        }
    }

    func setConnector(_ connector: TaskIdeasConnector, on: Bool) {
        PagesHaptics.selection()
        var nextSources = sources
        var nextBots = activeBots
        TaskIdeasSummary.toggleConnector(connector.id, on: on, connector: connector,
                                         sources: &nextSources, activeBots: &nextBots)
        draft.ideasSources = nextSources
        if nextBots != activeBots {
            draft.ideasBots = nextBots
            draft.ideasBot = nextBots.first ?? "default"
        }
        save()
    }

    func setNote(_ text: String) {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(800))
        guard trimmed != (draft.ideasNote ?? "") else { return }
        draft.ideasNote = trimmed
        save()
    }

    func save() {
        Task { await commit() }
    }

    /// Saves the draft. A save that didn't land puts the controls back to what the gateway keeps (unless another
    /// change has gone out since, which carries this one with it).
    func commit() async {
        guard draft != store.settings else { return }
        let next = draft, before = store.settings
        let ideas = next.ideas != before.ideas || next.ideasBot != before.ideasBot || next.ideasBots != before.ideasBots
            || next.ideasAt != before.ideasAt || next.ideasMax != before.ideasMax
            || next.ideasSources != before.ideasSources || next.ideasNote != before.ideasNote
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
    static func make(store: TasksStore, bots: [Bot] = [], initialSources: TaskIdeasAvailableSources? = nil,
                     ideasChanged: (() -> Void)? = nil) -> UIViewController {
        let model = TodoSettingsModel(store: store, bots: bots.map { ($0.id, PagesNames.botName($0.id, bots: bots)) },
                                      initialSources: initialSources)
        model.ideasChanged = ideasChanged
        let host = UIHostingController(rootView: HQScaledRoot(TodoSettingsView(model: model)))
        model.controller = host
        let nav = ChatSheet.wrap(host, title: "Tasks Settings")
        // Half height cut off the quiet hours' footer and Import from Reminders.
        nav.sheetPresentationController?.selectedDetentIdentifier = .large
        return nav
    }
}

/// Standalone sheet opening directly on "Where to Look" (from the Suggested page's Sources pill).
enum TodoIdeasSourcesSheet {
    static func make(store: TasksStore, bots: [Bot] = [], initialSources: TaskIdeasAvailableSources? = nil,
                     ideasChanged: (() -> Void)? = nil) -> UIViewController {
        let model = TodoSettingsModel(store: store, bots: bots.map { ($0.id, PagesNames.botName($0.id, bots: bots)) },
                                      initialSources: initialSources)
        model.ideasChanged = ideasChanged
        let host = UIHostingController(rootView: HQScaledRoot(TodoIdeasSourcesView(model: model)))
        model.controller = host
        let nav = ChatSheet.wrap(host, title: "Where to Look")
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
                    Label("Import from Reminders…", systemImage: "square.and.arrow.down").foregroundStyle(Color.hqTint)
                }
                .accessibilityIdentifier("tasks.settings.import")
            } footer: { HQSectionFooter { Text("Adds your open reminders as your own tasks. Reminders keeps them too.") } }
            .hqSheetRows()
        }
        .hqGroupedPage()
    }

    /// [task-ideas] Shown when the add-on keeps Ideas (0.9.39+); Where to Look & multi-bot controls appear on 0.9.86+.
    @ViewBuilder private var ideasSection: some View {
        let on = model.draft.ideas == true
        let looker = model.draft.ideasBot ?? "default"
        Section {
            Toggle(isOn: Binding(get: { on }, set: { model.draft.ideas = $0; model.save() })) {
                Text("Suggest Tasks")
            }
            .accessibilityIdentifier("tasks.settings.ideas")
            if on {
                if model.supportsSources {
                    NavigationLink {
                        TodoIdeasSourcesView(model: model)
                    } label: {
                        LabeledContent("Where to Look") {
                            Text(model.sourcesSummary)
                                .foregroundStyle(Color.hqLabel2)
                                .lineLimit(1)
                        }
                    }
                    .accessibilityIdentifier("tasks.settings.ideas-sources")

                    if model.bots.count > 1 {
                        NavigationLink {
                            TodoIdeasBotsView(model: model)
                        } label: {
                            LabeledContent("Who Looks") {
                                Text(model.botsSummary)
                                    .foregroundStyle(Color.hqLabel2)
                                    .lineLimit(1)
                            }
                        }
                        .accessibilityIdentifier("tasks.settings.ideas-bot")
                    }
                } else if model.bots.count > 1 {
                    Picker("Who Looks", selection: Binding(get: { looker }, set: { PagesHaptics.selection(); model.draft.ideasBot = $0; model.save() })) {
                        ForEach(model.bots, id: \.id) { bot in Text(bot.name).tag(bot.id) }
                    }
                    .hqMenuPicker()
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
        } header: { HQSectionLabel { Text("Suggested Tasks") } } footer: { HQSectionFooter {
            if model.supportsSources {
                Text("Once a day, \(model.botsSummary) checks only the sources you switch on and suggests a few tasks. Disabled sources and write actions are blocked during runs, and nothing goes on your list until you tap Add.")
            } else {
                Text("Once a day, \(model.botName(looker)) looks through your recent chats and whatever else it can reach, like your calendar or email, and suggests a few tasks. It can’t put anything on your list itself: nothing goes there until you add it.")
            }
        } }
        .hqSheetRows()
        .task { if model.draft.ideas != nil && model.availableSources == nil { await model.loadSources() } }
    }
}

// MARK: - Where to Look (Sources, Connected Apps, Multi-Bot Sweep, Focus & Skip)

struct TodoIdeasSourcesView: View {
    @Bindable var model: TodoSettingsModel
    @State private var noteText: String = ""
    @FocusState private var noteFocused: Bool

    var body: some View {
        let src = model.sources
        Form {
            Section {
                Toggle(isOn: Binding(get: { src.chats }, set: { on in
                    PagesHaptics.selection()
                    model.updateSources { $0.chats = on }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recent Chats")
                        Text(TaskIdeasSummary.chatBotsSubtitle(sources: src, bots: model.bots))
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqLabel2)
                    }
                }
                .accessibilityIdentifier("tasks.ideas.source.chats")

                if src.chats && model.bots.count > 1 {
                    NavigationLink {
                        TodoIdeasChatBotsView(model: model)
                    } label: {
                        LabeledContent("Chats From") {
                            let picked = src.chatBots
                            Text(picked.isEmpty || picked.count >= model.bots.count ? "All Bots" : "\(picked.count) of \(model.bots.count) Bots")
                                .foregroundStyle(Color.hqLabel2)
                        }
                    }
                    .accessibilityIdentifier("tasks.ideas.source.chat-bots")
                }

                Toggle(isOn: Binding(get: { src.memory }, set: { on in
                    PagesHaptics.selection()
                    model.updateSources { $0.memory = on }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Memory")
                        Text(src.memory ? "Ongoing projects and preferences" : "Off · blocked during runs")
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqLabel2)
                    }
                }
                .accessibilityIdentifier("tasks.ideas.source.memory")

                Toggle(isOn: Binding(get: { src.files }, set: { on in
                    PagesHaptics.selection()
                    model.updateSources { $0.files = on }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local Files & Notes")
                        Text(src.files ? "Read-only sweep of workspace files" : "Off · blocked during runs")
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqLabel2)
                    }
                }
                .accessibilityIdentifier("tasks.ideas.source.files")

                Toggle(isOn: Binding(get: { src.web }, set: { on in
                    PagesHaptics.selection()
                    model.updateSources { $0.web = on }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Web Search")
                        Text(src.web ? "Search the web while vetting ideas" : "Off · blocked during runs")
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqLabel2)
                    }
                }
                .accessibilityIdentifier("tasks.ideas.source.web")
            } header: { HQSectionLabel { Text("Built-in Sources") } }
            .hqSheetRows()

            Section {
                if model.loadingSources && model.connectors.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Checking connected apps…")
                            .font(Font.hq(.subheadline))
                            .foregroundStyle(Color.hqLabel2)
                    }
                } else if model.connectors.isEmpty {
                    Text("No connected apps found yet. Connect Gmail, Google Calendar, Notion, or other apps in Connectors to include them here.")
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                } else {
                    ForEach(model.connectors) { connector in
                        let enabled = src.connectors.contains(connector.id)
                        let owners = connector.bots.map { model.botName($0) }.joined(separator: ", ")
                        Toggle(isOn: Binding(get: { enabled }, set: { on in
                            model.setConnector(connector, on: on)
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(connector.name)
                                Text(enabled ? "Read-only sweep · \(owners)" : "Off · on \(owners)")
                                    .font(Font.hq(.footnote))
                                    .foregroundStyle(Color.hqLabel2)
                            }
                        }
                        .accessibilityIdentifier("tasks.ideas.connector.\(connector.id)")
                    }
                }
            } header: { HQSectionLabel { Text("Connected Apps") } } footer: { HQSectionFooter {
                Text("Newly connected apps start off. Turning an app on checks it on each run (and includes its bot in Who Looks automatically); turning it off blocks it during runs.")
            } }
            .hqSheetRows()

            if model.bots.count > 1 {
                Section {
                    NavigationLink {
                        TodoIdeasBotsView(model: model)
                    } label: {
                        LabeledContent("Who Looks") {
                            Text(model.botsSummary)
                                .foregroundStyle(Color.hqLabel2)
                                .lineLimit(1)
                        }
                    }
                    .accessibilityIdentifier("tasks.ideas.sources.who-looks")
                } header: { HQSectionLabel { Text("Participating Bots") } } footer: { HQSectionFooter {
                    Text("Pick one or more bots to run the daily sweep. Each bot checks its own enabled apps and merges into one Suggested list.")
                } }
                .hqSheetRows()
            }

            Section {
                TextField("e.g. Check my Notion Inbox and unread client emails. Ignore newsletters and receipts.",
                          text: $noteText, axis: .vertical)
                    .lineLimit(3...6)
                    .focused($noteFocused)
                    .onSubmit { model.setNote(noteText) }
                    .onChange(of: noteFocused) { _, focused in if !focused { model.setNote(noteText) } }
                    .accessibilityIdentifier("tasks.ideas.note")
            } header: { HQSectionLabel { Text("Focus & Skip") } } footer: { HQSectionFooter {
                Text("Always read-only: during a Suggested Tasks run, bots cannot add tasks directly or send, edit, book, buy, or delete anything.")
            } }
            .hqSheetRows()
        }
        .hqGroupedPage()
        .navigationTitle("Where to Look")
        .onAppear { noteText = model.draft.ideasNote ?? "" }
        .onDisappear { model.setNote(noteText) }
        .task { await model.loadSources() }
    }
}

/// Multi-select picker for which bots run the daily Task ideas sweep.
struct TodoIdeasBotsView: View {
    @Bindable var model: TodoSettingsModel

    var body: some View {
        let active = Set(model.activeBots)
        let enabledConnectors = Set(model.sources.connectors)
        Form {
            Section {
                ForEach(model.bots, id: \.id) { bot in
                    let on = active.contains(bot.id)
                    let apps = model.connectors.filter { $0.bots.contains(bot.id) && enabledConnectors.contains($0.id) }.map(\.name)
                    Button {
                        model.setActiveBot(bot.id, on: !on)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bot.name)
                                    .foregroundStyle(Color.hqLabel)
                                if !apps.isEmpty {
                                    Text("Checks \(apps.joined(separator: ", "))")
                                        .font(Font.hq(.footnote))
                                        .foregroundStyle(Color.hqLabel2)
                                } else if model.activeBots.first == bot.id && model.sources.chats {
                                    Text("Primary · scans recent chats")
                                        .font(Font.hq(.footnote))
                                        .foregroundStyle(Color.hqLabel2)
                                }
                            }
                            Spacer(minLength: 8)
                            if on {
                                Image(systemName: "checkmark")
                                    .font(Font.hq(.footnote).weight(.semibold))
                                    .foregroundStyle(Color.hqTintText)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tasks.ideas.bot.\(bot.id)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            } footer: { HQSectionFooter {
                Text("At least one bot stays selected. When multiple bots look, the primary bot covers recent chats and each bot sweeps its own enabled apps.")
            } }
            .hqSheetRows()
        }
        .hqGroupedPage()
        .navigationTitle("Who Looks")
    }
}

/// Multi-select picker for which bots' recent chats are included when Recent Chats is enabled.
struct TodoIdeasChatBotsView: View {
    @Bindable var model: TodoSettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(model.bots, id: \.id) { bot in
                    let on = model.isChatBotIncluded(bot.id)
                    Button {
                        model.setChatBot(bot.id, on: !on)
                    } label: {
                        HStack(spacing: 12) {
                            Text(bot.name)
                                .foregroundStyle(Color.hqLabel)
                            Spacer(minLength: 8)
                            if on {
                                Image(systemName: "checkmark")
                                    .font(Font.hq(.footnote).weight(.semibold))
                                    .foregroundStyle(Color.hqTintText)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tasks.ideas.chat-bot.\(bot.id)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            } footer: { HQSectionFooter {
                Text("Uncheck any bot whose chats you don’t want Suggested Tasks to scan.")
            } }
            .hqSheetRows()
        }
        .hqGroupedPage()
        .navigationTitle("Chats From")
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
                var cancelled = false
                let progressAlert = UIAlertController(
                    title: "Importing \(fresh.count) Reminder\(fresh.count == 1 ? "" : "s")…",
                    message: "0 of \(fresh.count)",
                    preferredStyle: .alert
                )
                let importTask = Task {
                    var added = 0
                    var processed = 0
                    var reason: String?
                    let batchSize = 4
                    for start in stride(from: 0, to: fresh.count, by: batchSize) {
                        guard !cancelled, !Task.isCancelled else { break }
                        let slice = Array(fresh[start..<min(start + batchSize, fresh.count)])
                        let outcomes = await withChildTasks(of: (Bool, String?).self) { group in
                            for reminder in slice {
                                let fields = TodoWire.newTask(
                                    title: reminder.title, who: .me, bot: nil,
                                    due: reminder.due.map { TodoDates.wire($0.date, hasTime: $0.hasTime) },
                                    repeatRule: reminder.repeatRule, prep: false, notes: reminder.notes,
                                    source: TodoSource(kind: "reminders", reminderId: reminder.id)
                                )
                                group.addTask { @MainActor in
                                    let made = await store.add(fields, quiet: true)
                                    return (made != nil, made == nil ? store.addFailure : nil)
                                }
                            }
                            var results: [(Bool, String?)] = []
                            while let one = await group.next() { results.append(one) }
                            return results
                        }
                        for (ok, fail) in outcomes {
                            processed += 1
                            if ok { added += 1 } else { reason = reason ?? fail }
                        }
                        progressAlert.message = "\(processed) of \(fresh.count)"
                    }
                    progressAlert.dismiss(animated: false)
                    AppLog.note("tasks", "imported \(added) of \(fresh.count) reminders\(cancelled ? " (cancelled)" : "")")
                    let words = cancelled && added > 0
                        ? "Imported \(added) reminder\(added == 1 ? "" : "s") before cancelling."
                        : importResult(added: added, of: fresh.count, reason: reason)
                    if added > 0 { PagesHaptics.success() } else if !cancelled { PagesHaptics.error() }
                    done(words, added > 0)
                }
                progressAlert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                    cancelled = true
                    importTask.cancel()
                })
                host.present(progressAlert, animated: true)
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
