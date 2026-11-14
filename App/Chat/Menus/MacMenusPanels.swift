// [mac-popups] The Mac's ☰ Commands and Models pop-overs (MacPickPanel): the same lists, states and actions as the
// iPhone's sheets (CommandsSheetViewController, ModelSheetViewController), drawn as a Mac draws a pick-list hung off a
// button. Nothing here runs on the iPhone or iPad.

#if targetEnvironment(macCatalyst)
import UIKit

/// ☰ Commands: Favorites, the chat's commands by section, then Skills; search; a star per row. The cached list paints
/// at once, then the fresh answer replaces it. A pick closes the panel, then sends, opens Models, or fills the field.
@MainActor final class MacCommandsPanel {
    let panel: MacPickPanel
    private let loader: (_ fresh: Bool) async throws -> CommandsCatalog
    private let pick: (_ row: SlashCatalog.Row, _ action: SlashCatalog.PickAction) -> Void
    private let isBotChat: Bool
    private let favorites: CommandFavorites?
    private var catalog: CommandsCatalog?
    private var all: [SlashCatalog.Section] = []
    private var rows: [String: SlashCatalog.Row] = [:]
    private var loaded = false
    private var loadTask: Task<Void, Never>?

    init(anchor: UIView, clearOf: UIView? = nil, cached: CommandsCatalog?, isBotChat: Bool, favorites: CommandFavorites?,
         loader: @escaping (_ fresh: Bool) async throws -> CommandsCatalog,
         onPick: @escaping (_ row: SlashCatalog.Row, _ action: SlashCatalog.PickAction) -> Void,
         onCancel: @escaping () -> Void) {
        panel = MacPickPanel(placeholder: "Search Commands", anchor: anchor, clearOf: clearOf, width: 500, identifier: "commands.sheet")
        self.loader = loader
        self.pick = onPick
        self.isBotChat = isBotChat
        self.favorites = favorites
        panel.driver = self
        panel.onCancel = { [weak self] in self?.loadTask?.cancel(); onCancel() }
        panel.onQuery = { [weak self] _ in self?.refilter(markFirst: true) }
        panel.onPick = { [weak self] row in
            guard let self, let command = self.rows[row.key] else { return }
            self.loadTask?.cancel()
            self.pick(command, SlashCatalog.pickAction(command, catalog: self.catalog))
        }
        panel.onStar = { [weak self] row in self?.toggleStar(row) }
        if let cached { show(cached) } else { panel.show(.loading) }
        load(fresh: false)
    }

    private func load(fresh: Bool) {
        loadTask?.cancel()
        if !loaded { panel.show(.loading) }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let catalog = try await self.loader(fresh)
                guard !Task.isCancelled else { return }
                self.show(catalog)
            } catch is CancellationError {
                return
            } catch {
                // A list already showing stays (the cached one); only an empty panel says it failed.
                guard !Task.isCancelled, !self.loaded else { return }
                let reason = MenusError.text(error)
                let retry = UIAction(title: "Try Again") { [weak self] _ in self?.load(fresh: true) }
                let details = UIAction(title: "Show Details") { [weak self] _ in
                    self?.panel.present(ChatErrorDetailsSheet.make(details: reason), animated: true)
                }
                self.panel.show(.message(symbol: "exclamationmark.triangle", title: "Couldn’t Load Commands",
                                         text: "Hermes didn’t send its list of commands. Show Details has the reason.",
                                         actions: [retry, details]))
            }
        }
    }

    private func show(_ catalog: CommandsCatalog) {
        self.catalog = catalog
        let sections = SlashCatalog.sections(catalog, isBotChat: isBotChat)
        let changed = !loaded || sections != all
        all = sections
        loaded = true
        if changed { refilter(markFirst: !panel.query.isEmpty) }
    }

    /// Favorites leads while nothing is searched (a search finds the starred rows in their own sections).
    private func refilter(markFirst: Bool, holding: (section: String, key: String)? = nil) {
        guard loaded else { return }
        let query = panel.query
        // Mac polish #23: the best match first, as the slash drawer ranks it, so Return picks what was typed.
        var shown = SlashCatalog.ranked(SlashCatalog.filter(all, query: query), query: query, favorites: favorites?.commands ?? [])
        if query.isEmpty, !shown.isEmpty {
            shown = SlashCatalog.favoritesLeading(shown, all: all, favorites: favorites?.commands ?? [])   // [Mac UI check 2026-11-13] V22
        }
        if all.isEmpty {
            let retry = UIAction(title: "Check Again") { [weak self] _ in self?.load(fresh: true) }
            panel.show(.message(symbol: "command", title: CommandsSheetViewController.emptyTitle,
                                text: CommandsSheetViewController.emptyText, actions: [retry]))
            return
        }
        rows = [:]
        let sections = shown.enumerated().map { index, section in
            let inFavorites = index == 0 && query.isEmpty && favorites != nil && section.title == SlashCatalog.favoritesTitle
            return MacPickPanel.Section(title: section.title, rows: section.rows.map { row in
                rows[row.command] = row
                let id = "\(inFavorites ? "fav." : "")\(row.command)"
                return MacPickPanel.Row(key: row.command, title: row.command, detail: row.description,
                                        starred: favorites.map { $0.contains(row.command) }, identifier: "commands.row.\(id)",
                                        starIdentifier: "commands.star.\(id)",
                                        accessibilityLabel: row.description.isEmpty ? row.command : "\(row.command), \(row.description)")
            })
        }
        panel.show(.rows(sections), markFirst: markFirst && !query.isEmpty, holding: holding)
    }

    /// Stars or unstars without picking; the row stays under the pointer while Favorites grows or shrinks above it.
    private func toggleStar(_ row: MacPickPanel.Row) {
        guard let favorites, let command = rows[row.key] else { return }
        let section = all.first { $0.rows.contains(command) }?.title ?? ""
        favorites.toggle(command.command)
        refilter(markFirst: false, holding: (section, row.key))
    }
}

/// Models: the catalog by provider with Favorites first, the current model checked and marked as it opens (a Mac
/// pop-up opens on its current item), search, a star per row, Refresh beside the field. Offline, the rows grey out and
/// the note under the field says why; the stars still work.
@MainActor final class MacModelsPanel {
    let panel: MacPickPanel
    private let context: ModelMenuContext
    private let pick: (ModelChoice) -> Void
    private var models: [ModelChoice] = []
    private var byKey: [String: ModelChoice] = [:]
    private var loading = true
    private var failure: (reason: String, words: String?)?
    private var loadTask: Task<Void, Never>?
    private var offlineWatch: Timer?
    private var shownOffline = false
    private var positioned = false
    /// [model-scope] What a pick changes (`ModelPanelModel.switchScope`), as the iPhone's sheet says it.
    private let scope: String

    init(anchor: UIView, clearOf: UIView? = nil, context: ModelMenuContext, query: String?, bot: String? = nil,
         onPick: @escaping (ModelChoice) -> Void, onCancel: @escaping () -> Void) {
        panel = MacPickPanel(placeholder: "Search Models", anchor: anchor, clearOf: clearOf, width: 400, showsChecks: true, identifier: "models.sheet")
        self.context = context
        self.scope = ModelPanelModel.switchScope(bot: bot)
        self.pick = onPick
        panel.driver = self
        let initial = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        panel.setQuery(initial)
        panel.setAccessory(symbol: "arrow.clockwise", label: "Refresh Models", identifier: "models.refresh") { [weak self] in
            self?.load(refresh: true)
        }
        panel.onQuery = { [weak self] _ in self?.rebuild(markFirst: true) }
        panel.onPick = { [weak self, weak anchor] row in
            guard let self else { return }
            if row.key == Self.addProviderKey {   // [provider-add] the panel has closed: Settings › Providers › Add Provider
                self.stop()
                if let host = anchor?.window?.rootViewController { ProviderAdd.openFromChat(from: host) }
                return
            }
            guard let model = self.byKey[row.key] else { return }
            self.stop()
            self.pick(model)
        }
        panel.onCancel = { [weak self] in self?.stop(); onCancel() }
        panel.onStar = { [weak self] row in self?.toggleStar(row) }
        // [model-fold] A provider's heading folds its models, kept per account as on the iPhone (`ModelPrefs.foldedProviders`).
        panel.onFold = { [weak self] provider in
            guard let self else { return }
            var next = self.context.prefs.foldedProviders
            if !next.insert(provider).inserted { next.remove(provider) }
            self.setFolds(next)
        }
        panel.onFoldAll = { [weak self] fold in
            guard let self else { return }
            let providers = Set(self.models.map(\.provider).filter { !$0.isEmpty })
            let folded = self.context.prefs.foldedProviders
            self.panel.fitNextRows()   // [mac-ten] no blank glass under five folded headings
            self.setFolds(fold ? folded.union(providers) : folded.subtracting(providers))
        }
        shownOffline = context.offline
        if context.hasCatalog {
            models = context.models()
            loading = false
            rebuild(markFirst: !initial.isEmpty)
        } else {
            rebuild(markFirst: false)
        }
        load(refresh: false)
        // A gone driver ends its timer (the closure is the timer's only link to it).
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.connectionChanged() }
        }
        RunLoop.main.add(timer, forMode: .common)
        offlineWatch = timer
    }

    private func stop() {
        offlineWatch?.invalidate()
        offlineWatch = nil
        loadTask?.cancel()
    }

    private func connectionChanged() {
        guard panel.presentingViewController != nil || !panel.isViewLoaded else { stop(); return }
        let offline = context.offline
        guard offline != shownOffline else { return }
        shownOffline = offline
        rebuild(markFirst: false)
    }

    private func load(refresh: Bool) {
        loadTask?.cancel()
        if models.isEmpty || refresh {
            if models.isEmpty { loading = true; failure = nil }
            rebuild(markFirst: false)
        }
        panel.accessoryEnabled = false
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let rows = try await self.context.load(refresh: refresh)
                guard !Task.isCancelled else { return }
                self.models = rows
                self.loading = false
                self.failure = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.loading = false
                // With rows already shown, a failed refresh keeps them.
                if self.models.isEmpty { self.failure = (MenusError.details(error), ModelLoad.words(for: error, offline: self.context.offline)) }
            }
            self.rebuild(markFirst: !self.panel.query.isEmpty)
        }
    }

    private func rebuild(markFirst: Bool, holding: (section: String, key: String)? = nil) {
        let offline = context.offline
        panel.accessoryEnabled = !loading && !offline
        let status = offline ? ModelSheetViewController.offlineWords : loading ? ModelLoad.loadingWords : nil
        panel.setNote([status, scope].compactMap { $0 }.joined(separator: "\n"))
        if loading && models.isEmpty { panel.show(.loading); return }
        if let failure, models.isEmpty {
            let retry = UIAction(title: "Try Again") { [weak self] _ in self?.load(refresh: true) }
            let details = UIAction(title: "Show Details") { [weak self] _ in
                self?.panel.present(ChatErrorDetailsSheet.make(details: failure.reason), animated: true)
            }
            panel.show(.message(symbol: "exclamationmark.triangle", title: ModelLoad.failureTitle, text: failure.words, actions: [retry, details]))
            return
        }
        if models.isEmpty {
            panel.show(.message(symbol: "cpu", title: "No Models Available",
                                text: "Hermes sent no models for this chat. Try Again asks it once more.",
                                actions: [UIAction(title: "Try Again") { [weak self] _ in self?.load(refresh: true) }]))
            return
        }
        let query = panel.query
        let current = context.current()
        var out = ModelSheetModel.sections(models, query: query, current: (current.id, current.provider))
        let favorites = query.isEmpty ? ModelSheetModel.favoriteRows(models, keys: context.prefs.favorites) : []
        if !out.isEmpty, !favorites.isEmpty { out.insert(ModelSection(provider: "", title: "Favorites", models: favorites), at: 0) }
        byKey = [:]
        // [model-fold] Never while searching, never Favorites (as the iPhone's sheet).
        let folded = query.isEmpty ? context.prefs.foldedProviders : []
        let sections = out.map { section in
            let fold = query.isEmpty && !section.provider.isEmpty
                ? MacPickPanel.Fold(key: section.provider, count: section.models.count, folded: folded.contains(section.provider)) : nil
            return MacPickPanel.Section(title: section.title, rows: fold?.folded == true ? [] : section.models.map { model in
                byKey[model.key] = model
                let detail = section.provider.isEmpty ? (model.providerName ?? model.provider) : ""
                let checked = model.id == current.id && model.provider == current.provider
                return MacPickPanel.Row(key: model.key, title: model.name, detail: detail, checked: checked,
                                        starred: context.prefs.isFavorite(model), enabled: !offline,
                                        identifier: "models.row.\(model.provider)::\(model.id)",
                                        starIdentifier: "models.star.\(model.provider)::\(model.id)",
                                        accessibilityLabel: model.name + (detail.isEmpty ? "" : ", \(detail)"))
            }, fold: fold)
        }
        // [provider-add] Owner 2026-11-04 ("more easily add them"): the last row, under every provider's models (not
        // while searching), opens Settings › Providers with Add Provider over it.
        let add = MacPickPanel.Section(title: "", rows: [MacPickPanel.Row(key: Self.addProviderKey, title: "Add Provider…",
                                                                          identifier: "models.add-provider", accessibilityLabel: "Add Provider")])
        panel.show(.rows(query.isEmpty && !sections.isEmpty ? sections + [add] : sections), markFirst: markFirst && !query.isEmpty, holding: holding)
        // As it opens, the current model is marked and in view (a Mac pop-up opens on its current item).
        if !positioned, query.isEmpty, !sections.isEmpty {
            positioned = true
            panel.mark(key: ModelPrefs.key(provider: current.provider, model: current.id))
        }
    }

    static let addProviderKey = "hq.add-provider"

    private func setFolds(_ next: Set<String>) {
        context.prefs.setFoldedProviders(next)
        AppLog.note("chatui", "models: \(next.count) provider(s) folded")
        rebuild(markFirst: false)
    }

    private func toggleStar(_ row: MacPickPanel.Row) {
        guard let model = byKey[row.key] else { return }
        let section = ModelSheetModel.sections(models, query: "", current: nil).first { $0.provider == model.provider }?.title ?? ""
        context.prefs.toggleFavorite(provider: model.provider, model: model.id)
        rebuild(markFirst: false, holding: (section, row.key))
    }
}
#endif
