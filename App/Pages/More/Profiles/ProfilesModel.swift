// More › Bot Profiles (docs/spec/3x-morepages.md §10): the list's model. One read of `GET /api/profiles`, the
// roster's names and heads beside it, Rename (validated here before it is sent) and Delete (the Bots list's own
// question and store call), and the pages it pushes.

import SwiftUI
import UIKit

@MainActor @Observable
final class ProfilesModel {
    enum Phase: Equatable {
        case loading
        case loaded
        /// Nothing to show: the reason in words.
        case failed(String)
    }

    @ObservationIgnored let context: MorePages.Context
    @ObservationIgnored let api: ProfilesAPI
    /// [tester batch 3] A profile's own Default Model (its chooser, and the save).
    let modelChange: BotDefaultModel
    /// The list page (pushes and alerts come from it or from whatever is on top of it).
    @ObservationIgnored weak var host: UIViewController?

    private(set) var rows: [ProfileRow] = []
    private(set) var phase: Phase = .loading
    var query = ""
    /// The roster and the link, read while a page of this model is on screen.
    private(set) var bots: [Bot]
    private(set) var online: Bool
    /// The profile a rename is out for.
    private(set) var renaming: String?
    /// A refresh failed while rows were showing ("Couldn’t refresh…").
    private(set) var staleReason: String?

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var pagesShown = 0

    init(context: MorePages.Context) {
        self.context = context
        api = ProfilesAPI(client: context.client)
        bots = context.bots
        online = context.isOnline
        modelChange = BotDefaultModel(services: context.services)
        // The page's Provider comes from this list: read it again once a new model is saved.
        modelChange.onSaved = { [weak self] in self?.load() }
    }

    // MARK: Reading

    func load() {
        loadTask?.cancel()
        if rows.isEmpty { phase = .loading }
        loadTask = Task { [weak self] in await self?.read() }
    }

    /// Pull to refresh.
    func refresh() async {
        loadTask?.cancel()
        await read()
    }

    private func read() async {
        do {
            let fresh = try await api.list()
            guard !Task.isCancelled else { return }
            MorePages.noteRead("profiles", error: nil)
            rows = fresh
            phase = .loaded
            staleReason = nil
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            let missing = MorePages.noteRead("profiles", error: error)
            let reason = missing ? MoreWire.olderHermes : PagesREST.reason(error)
            if rows.isEmpty { phase = .failed(reason) } else { staleReason = reason }
        }
    }

    // MARK: On screen

    /// A page of this model shows: the roster and the link are followed (AppModel is not observable).
    func pageAppeared() {
        pagesShown += 1
        sync()
        guard watch == nil else { return }
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.sync()
            }
        }
    }

    func pageDisappeared() {
        pagesShown = max(0, pagesShown - 1)
        guard pagesShown == 0 else { return }
        watch?.cancel()
        watch = nil
    }

    private func sync() {
        let nowOnline = context.isOnline
        if nowOnline != online {
            online = nowOnline
            // The link is back: a list that failed, or went stale, reads again by itself.
            if nowOnline, phase != .loaded || staleReason != nil { load() }
        }
        let roster = context.bots
        if roster != bots { bots = roster }
    }

    // MARK: Rows

    var readOnly: Bool { ProfilesAccess.readOnly(context) }
    var canWrite: Bool { !readOnly && online }

    func bot(_ row: ProfileRow) -> Bot? { bots.first { $0.id == row.name } }

    /// The bot's display name: the roster's, else the gateway's `display_name`, else the id in Title Case.
    func title(_ row: ProfileRow) -> String {
        if let bot = bot(row) { return bot.name }
        return row.displayName ?? SessionsViewController.readableProfileName(row.name)
    }

    func modelName(_ row: ProfileRow) -> String? {
        if let bot = bot(row), let editing, let label = editing.modelInfo(bot).model, !label.isEmpty { return label }
        return row.model
    }

    /// "12 skills": says what the number counts (UX study #50: Star Map counts every skill on its map). Item 4: no
    /// internal profile name in the subtitle (the title already names the bot), so this stays short enough not to
    /// break across lines at larger text ("12 / skills installed" did).
    static func skills(_ count: Int) -> String { count == 0 ? "No skills" : count == 1 ? "1 skill" : "\(count) skills" }

    /// "`<model>` · `N skills`", without the internal profile name (item 4, Mac UX stress test #59: the id isn't a
    /// name; it stays on the detail page as Bot ID).
    func subtitle(_ row: ProfileRow) -> String {
        ([modelName(row)].compactMap { $0 } + [Self.skills(row.skillCount)]).joined(separator: " · ")
    }

    var shown: [ProfileRow] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !words.isEmpty else { return rows }
        return rows.filter { row in
            [row.name, title(row), row.model ?? "", modelName(row) ?? "", row.provider ?? ""].contains { $0.lowercased().contains(words) }
        }
    }

    func row(named name: String) -> ProfileRow? { rows.first { $0.name == name } }

    /// Rename and Delete: never for the default profile, a read-only gateway, or offline.
    func canChange(_ row: ProfileRow) -> Bool { canWrite && !row.isDefault && renaming == nil }

    /// [tester batch 3] Default Model is a row that opens its chooser while changes can be made (the default profile's
    /// too); otherwise it is a fact.
    func canChangeModel(_ row: ProfileRow) -> Bool { canWrite && bot(row) != nil && modelChange.available }

    func modelValue(_ row: ProfileRow) -> String {
        modelChange.switching == row.name ? "Switching…" : modelName(row) ?? "Not Set"
    }

    func openDefaultModel(_ row: ProfileRow, from page: UIViewController?) {
        guard canChangeModel(row), let bot = bot(row) else { return }
        modelChange.open(bot, on: (page ?? host)?.navigationController)
    }

    /// Tester 2026-10-30: the profile's own Fallback Models and Auxiliary Models (Settings' are the default's).
    func openFallbacks(_ row: ProfileRow, from page: UIViewController?) {
        guard let bot = bot(row) else { return }
        BotModelPages.openFallbacks(bot, services: context.services, on: (page ?? host)?.navigationController)
    }

    func openAuxiliary(_ row: ProfileRow, from page: UIViewController?) {
        guard let bot = bot(row) else { return }
        BotModelPages.openAuxiliary(bot, services: context.services, on: (page ?? host)?.navigationController)
    }

    /// [context-window] The profile's own context window.
    func openContextWindow(_ row: ProfileRow, from page: UIViewController?) {
        guard let bot = bot(row) else { return }
        BotModelPages.openContextWindow(bot, services: context.services, on: (page ?? host)?.navigationController)
    }

    private var editing: (any BotEditing)? { (context.services as? SettingsServices)?.botEditing }

    // MARK: Pages

    func open(_ row: ProfileRow) {
        PagesHaptics.selection()
        let state = ProfileDetailState(row: row)
        let page = MorePageController(title: title(row), identifier: "profiles.detail", ProfileDetailView(model: self, state: state))
        page.onAppear = { [weak self] in self?.pageAppeared() }
        page.onDisappear = { [weak self] in self?.pageDisappeared() }
        state.host = page
        host?.navigationController?.pushViewController(page, animated: true)
    }

    func openSoul(_ row: ProfileRow, from page: UIViewController?) {
        PagesHaptics.selection()
        let editor = SoulEditorViewController(context: context, profile: row.name, botName: title(row))
        (page ?? host)?.navigationController?.pushViewController(editor, animated: true)
    }

    // MARK: Rename

    func rename(_ row: ProfileRow, state: ProfileDetailState? = nil, from presenter: UIViewController?) {
        guard canChange(row) else { return }
        ProfileRenamePrompt.present(current: row.name, existing: rows.map(\.name), from: presenter ?? host) { [weak self] name in
            self?.sendRename(row, to: name, state: state, from: presenter)
        }
    }

    private func sendRename(_ row: ProfileRow, to name: String, state: ProfileDetailState?, from presenter: UIViewController?) {
        guard renaming == nil else { return }
        switch ProfileName.check(name, current: row.name, existing: rows.map(\.name)) {
        case .unchanged, .invalid: return
        case .taken:
            // The prompt is still leaving the screen when its button's action runs: the words follow it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                FailureAlert.present(title: "Couldn’t Rename", reason: ProfileName.taken, from: presenter ?? self?.host, whole: true)
            }
            return
        case .ok: break
        }
        renaming = row.name
        Task { [weak self] in
            guard let self else { return }
            do {
                let renamed = try await self.api.rename(row.name, to: name)
                self.renaming = nil
                PagesHaptics.success()
                if let index = self.rows.firstIndex(where: { $0.name == row.name }) {
                    self.rows[index].name = renamed.name
                    if let path = renamed.path, !path.isEmpty { self.rows[index].path = path }
                    state?.row = self.rows[index]
                }
                // A draft of the old id's SOUL.md has no file to go back to.
                SoulDraftStore.standard.remove(account: self.context.account.id, profile: row.name)
                // The bot's id changed: the roster is read again, then this list.
                self.context.services.refreshBots()
                await self.refresh()
                if let fresh = self.row(named: renamed.name) { state?.row = fresh }
            } catch {
                self.renaming = nil
                let refused = (error as? HTTPError).map { $0.status == 400 || $0.status == 409 || $0.status == 422 } ?? false
                FailureAlert.present(title: "Couldn’t Rename", reason: ProfileName.renameReason(error), detail: "\(error)",
                                     from: presenter ?? self.host, whole: refused,
                                     retry: refused ? nil : { [weak self] in self?.sendRename(row, to: name, state: state, from: presenter) })
            }
        }
    }

    // MARK: Delete

    /// The Bots list's own question and store call (`BotExtras.confirmDelete`, `BotStore.deleteBot`).
    func delete(_ row: ProfileRow, state: ProfileDetailState? = nil, from presenter: UIViewController?, source: UIView? = nil) {
        guard canChange(row), let editing, let from = presenter ?? host else { return }
        let bot = bot(row) ?? Bot(id: row.name, name: title(row), role: nil, preview: nil, lastActive: nil, isWorking: false,
                                  unread: false, pinned: false, pinOrder: nil, sectionName: nil, hidden: false,
                                  canonicalSessionId: nil, head: nil)
        BotExtras.confirmDelete(bot, editing: editing, from: from, source: source) { [weak self] in
            guard let self else { return }
            self.rows.removeAll { $0.name == row.name }
            SoulDraftStore.standard.remove(account: self.context.account.id, profile: row.name)
            // The detail of a deleted profile goes back to the list.
            if let page = state?.host, let navigation = page.navigationController, let index = navigation.viewControllers.firstIndex(of: page), index > 0 {
                navigation.popToViewController(navigation.viewControllers[index - 1], animated: true)
            }
            self.load()
        }
    }
}

/// The profile a detail page shows (a rename gives it a new id while the page stays).
@MainActor @Observable
final class ProfileDetailState {
    var row: ProfileRow
    @ObservationIgnored weak var host: UIViewController?
    init(row: ProfileRow) { self.row = row }
}

/// "Rename Bot": a one-field alert like `TextPrompt`, with the name rule checked as it is typed: an invalid name
/// turns red and Rename stays off (a system alert's message can't be coloured, so the typed name is).
@MainActor
enum ProfileRenamePrompt {
    static func present(current: String, existing: [String], from presenter: UIViewController?, done: @escaping (String) -> Void) {
        guard let host = FailureAlert.topmost(presenter) else { return }
        let alert = UIAlertController(title: "Rename Bot", message: ProfileName.hint, preferredStyle: .alert)
        let confirm = UIAlertAction(title: "Rename", style: .default) { [weak alert] _ in
            done(alert?.textFields?.first?.text ?? "")
        }
        func check(_ field: UITextField) {
            let result = ProfileName.check(field.text ?? "", current: current, existing: existing)
            confirm.isEnabled = result == .ok || result == .taken
            let invalid = result == .invalid && !(field.text ?? "").isEmpty
            field.textColor = invalid ? HQPalette.red : HQPalette.label
            field.accessibilityValue = invalid ? "\(field.text ?? ""), not a valid name" : nil
        }
        alert.addTextField { field in
            field.text = current
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.smartDashesType = .no
            field.smartQuotesType = .no
            field.keyboardType = .asciiCapable
            field.clearButtonMode = .whileEditing
            field.returnKeyType = .done
            field.accessibilityIdentifier = "profiles.rename.field"
            field.addAction(UIAction { [weak field] _ in
                guard let field else { return }
                if (field.text ?? "").count > ProfileName.maxLength { field.text = String((field.text ?? "").prefix(ProfileName.maxLength)) }
                check(field)
            }, for: .editingChanged)
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(confirm)
        alert.preferredAction = confirm
        if let field = alert.textFields?.first { check(field) }
        host.present(alert, animated: true)
    }
}

/// A read-only gateway hides every write control. `-HQPagesReadOnly YES` (DEBUG) is the pages' own switch for it,
/// which `MorePages.Context.readOnly` does not carry.
@MainActor
enum ProfilesAccess {
    static func readOnly(_ context: MorePages.Context) -> Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HQPagesReadOnly") { return true }
        #endif
        return context.readOnly
    }

    /// `-HQSoulDraftsReset YES` (DEBUG, UI tests): a launch starts with no kept SOUL.md drafts.
    static func resetDraftsIfAsked() {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "HQSoulDraftsReset") else { return }
        let directory = SoulDraftStore.standard.directory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasPrefix("soul-draft-") {
            try? FileManager.default.removeItem(at: directory.appending(path: name, directoryHint: .notDirectory))
        }
        #endif
    }
}
