// More › Integrations › Import Sessions (docs/spec/3x-morepages.md §14): Claude Code and Codex conversations found on
// the gateway computer. The list (source segments, Import Into, search over the loaded rows, Load More Sessions) and
// the preview pushed from a row (the turns, Import / Open in Hermes). Rules, words and the calls are in
// `HermesKit/Pages/More/ForeignSessions.swift`.

import SwiftUI
import UIKit

extension MorePages {
    static func installImportSessions() {
        factories["import-sessions"] = { context in ImportSessionsScreens.makeList(context) }
        #if DEBUG
        // UI tests start from the default bot (`-HQImportForgetBot YES`).
        if UserDefaults.standard.bool(forKey: "HQImportForgetBot") {
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("pages.more.bot.import-sessions.") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        #endif
    }
}

@MainActor
enum ImportSessionsScreens {
    static let row = "import-sessions"

    static func makeList(_ context: MorePages.Context) -> UIViewController {
        let store = ForeignSessionsStore(client: context.client, profile: MoreBotChoice.read(row, context: context))
        let coordinator = ImportSessionsCoordinator(context: context, store: store)
        let page = MorePageController(title: "Import Sessions", identifier: "import-sessions.page",
                                      ImportSessionsView(store: store, coordinator: coordinator))
        coordinator.host = page
        store.onFirstRead = { error in MorePages.noteRead(row, error: error) }

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = coordinator
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = ForeignSessions.searchPrompt
        let capsule = PageBarCapsule(host: page, configuration: .init(page: "import-sessions", search: search))
        capsule.install()
        coordinator.capsule = capsule
        page.retained = [store, coordinator, capsule]
        store.reload()
        return page
    }
}

/// What the SwiftUI pages ask of UIKit: pushes, the chat hand-off, alerts, the search field's text.
@MainActor
final class ImportSessionsCoordinator: NSObject, UISearchResultsUpdating {
    let context: MorePages.Context
    let store: ForeignSessionsStore
    weak var host: UIViewController?
    weak var capsule: PageBarCapsule?

    init(context: MorePages.Context, store: ForeignSessionsStore) {
        self.context = context
        self.store = store
    }

    var bots: [Bot] { context.botChoices }
    var canImport: Bool { !context.readOnly }
    var isOnline: Bool { context.isOnline }

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        if store.query != text { store.query = text }
        capsule?.updateSearchState()
    }

    func chooseBot(_ profile: String) {
        MoreBotChoice.save(profile, page: ImportSessionsScreens.row, context: context)
        store.setProfile(profile)
    }

    func open(_ session: ForeignSession) {
        PagesHaptics.selection()
        let model = ImportPreviewModel(session: session, store: store, coordinator: self)
        let page = MorePageController(title: ForeignSessions.title(session), identifier: "import-sessions.preview",
                                      ImportPreviewView(model: model))
        page.retained = [model]
        model.host = page
        host?.navigationController?.pushViewController(page, animated: true)
        model.load()
    }

    /// The chat of an imported (or already imported) conversation, pushed over More as a notification opens a chat.
    func openChat(sessionId: String, title: String, from page: UIViewController?) {
        let navigation = page?.navigationController ?? host?.navigationController
        if let listed = context.services.sessions.first(where: { $0.id == sessionId }) {
            MorePages.openChat(listed, on: navigation)
        } else {
            MorePages.openChat(sessionId: sessionId, profile: store.profile, title: title, on: navigation)
        }
    }
}

// MARK: - The list

struct ImportSessionsView: View {
    @Bindable var store: ForeignSessionsStore
    let coordinator: ImportSessionsCoordinator

    private var sourcePicker: some View {
        HQSegmentedPicker("Source", options: ForeignSessionsStore.Source.allCases.map { ($0.title, $0) },
                          selection: Binding(get: { store.source }, set: { store.setSource($0) }))   // [desktoplook3]
        .accessibilityIdentifier("import-sessions.source")
        .hqSegmentRow(otherwise: EdgeInsets())
        .listRowSeparator(.hidden)
    }

    var body: some View {
        List { Group {
            // The bot first, then the source and its list, as Capabilities and Star Map order theirs (UX study #93).
            if coordinator.bots.count > 1 {
                Section {
                    MoreBotPicker(title: "Import Into", bots: coordinator.bots,
                                  selection: Binding(get: { store.profile }, set: { coordinator.chooseBot($0) }))
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(ForeignSessions.subtitle)
                        .font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "desktopcomputer").accessibilityHidden(true)
                        Text(ForeignSessions.readingFrom(store.host))
                            .accessibilityIdentifier("import-sessions.host")
                    }
                    .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
                // In from the card edge to the cards' text (UX study #93: flush, the first letter was clipped).
                // [mac] Stress test 2026-10-28 #53: at the page's side inset, where the cards' text starts.
                .listRowInsets(EdgeInsets(top: 0, leading: DeviceWord.isMac ? MacInset.side : 16, bottom: 10,
                                          trailing: DeviceWord.isMac ? MacInset.side : 16))
                // [mac] Stress test 2026-10-28 round 6: the intro is text standing on the page in both looks; the
                // Desktop Look outlined its section as a card (the iOS look draws none). On the Mac it is alone in its
                // section (the segments have their own), so the section is marked bare.
                .background { if DeviceWord.isMac && Theme.isDesktop { DesktopBareRowMarker() } }
                if !DeviceWord.isMac { sourcePicker }
            }
            .listRowSeparator(.hidden)
            // [mac] Stress test 2026-10-28 #55: the segments in a section of their own, as on Capabilities and Command
            // Center (they were fused to the text above).
            if DeviceWord.isMac { Section { sourcePicker } }
            content
        }.hqMacSettingsRowInsets() }
        .hqMacForm()   // [mac] Stress test 2026-10-28 #8: the segments and rows at a readable width
        .hqGroupedPage()
        .contentMargins(.top, MacInset.top(otherwise: 0), for: .scrollContent)   // the first card at Capabilities' height (UX study #174)   // [mac] Stress test 2026-10-28 #53
        .hqMacListHeight()   // [mac] Stress test 2026-10-28 round 7: its empty state centred in the room under the segments
        .refreshable {
            store.reload(keeping: true)
            await store.settle()
        }
    }

    @ViewBuilder private var content: some View {
        switch store.phase {
        case .loading:
            Section {
                MoreSkeleton(rows: 5, label: ForeignSessions.scanning) { store.reload() }
                    .frame(height: 360)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            } header: { HQSectionLabel {
                Text(ForeignSessions.scanning).textCase(nil)
            } }
        case .failed(let help, let reason):
            Section {
                MoreErrorState(title: ForeignSessions.scanErrorTitle, reason: help, page: "Import Sessions") { store.reload() }
                    .hqListedEmptyState(minHeight: 320, above: 250)   // [mac] Stress test 2026-10-28 #9: centred in the room left, no box
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .accessibilityHint(reason)
            }
        case .loaded:
            let rows = store.visible
            if rows.isEmpty {
                Section {
                    MoreEmptyState(symbol: store.searching ? "magnifyingglass" : "tray",
                                   title: store.searching ? ForeignSessions.noMatchesTitle : ForeignSessions.emptyTitle,
                                   text: store.searching ? ForeignSessions.noMatchesText : ForeignSessions.emptyText)
                        .hqListedEmptyState(minHeight: 280, above: 250)   // [mac] Stress test 2026-10-28 #9
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            } else {
                Section {
                    ForEach(rows) { session in
                        Button { coordinator.open(session) } label: {
                            ImportSessionRow(session: session, showSource: store.source == .all)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("import-sessions.row.\(session.id)")
                    }
                } footer: { HQSectionFooter {
                    if store.unreadable > 0 {
                        Text(ForeignSessions.skipped).accessibilityIdentifier("import-sessions.skipped")
                    }
                } }
            }
            if store.hasMore {
                Section {
                    Button { store.loadMore() } label: {
                        HStack(spacing: 10) {
                            Text(ForeignSessions.loadMore).foregroundStyle(Color.hqTintText)
                            Spacer(minLength: 8)
                            if store.loadingMore { ProgressView() }
                        }
                        .contentShape(Rectangle())
                    }
                    .disabled(store.loadingMore)
                    .accessibilityIdentifier("import-sessions.more")
                } footer: { HQSectionFooter {
                    if let reason = store.moreError {
                        Text("Couldn’t load more. \(reason)").foregroundStyle(Color.hqRed)
                            .accessibilityIdentifier("import-sessions.more-error")
                    } else {
                        Text(store.rows.count == 1 ? "1 session loaded." : "\(store.rows.count) sessions loaded.")
                            .accessibilityIdentifier("import-sessions.count")
                    }
                } }
            } else if !store.rows.isEmpty {
                Section {} footer: { HQSectionFooter {
                    Text(store.rows.count == 1 ? "1 session." : "\(store.rows.count) sessions.")
                        .accessibilityIdentifier("import-sessions.count")
                } }
            }
        }
    }
}

struct ImportSessionRow: View {
    var session: ForeignSession
    var showSource: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(ForeignSessions.title(session))
                    .font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                    .lineLimit(3)
                DotSeparatedText(pieces: detail)
                    .font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                if let excerpt = ForeignSessions.excerpt(session) {
                    Text(excerpt)
                        .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                        .lineLimit(2)
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 4)
            SettingsChevron()
                .padding(.top, 4)
        }
        // [mac-ten] Owner 2026-11-11 ("weird UI issues"; 2026-11-08: "too much wasted space"): the phone's 12 pt
        // above and under the words, on top of the list's own row insets, left about 35 pt of card between one
        // conversation's last line and the next one's title, so four and a half fitted a window. The list's insets
        // are the Mac's room.
        .padding(.vertical, DeviceWord.isMac ? 2 : 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ForeignSessions.spoken(session))
        .accessibilityAddTraits(.isButton)
    }

    private var detail: [String] {
        let words = ForeignSessions.detail(session).components(separatedBy: " · ")
        return showSource && !session.label.isEmpty ? [session.label] + words : words
    }
}

// MARK: - The preview

@MainActor @Observable
final class ImportPreviewModel {
    enum Phase: Equatable {
        case loading
        case loaded(ForeignPreview)
        case failed(String)
    }

    let session: ForeignSession
    private let store: ForeignSessionsStore
    private let coordinator: ImportSessionsCoordinator
    private(set) var phase: Phase = .loading
    private(set) var importing = false
    /// The Hermes chat this conversation is (set by the preview, or by an import made here).
    private(set) var importedId: String?
    @ObservationIgnored weak var host: UIViewController?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var linkTask: Task<Void, Never>?
    /// Audit 863 (08d-10): the link as it is now, followed while the preview shows (Import and the offline line had
    /// kept how it was when the preview loaded).
    private(set) var isOnline: Bool

    init(session: ForeignSession, store: ForeignSessionsStore, coordinator: ImportSessionsCoordinator) {
        self.session = session
        self.store = store
        self.coordinator = coordinator
        isOnline = coordinator.isOnline
    }

    isolated deinit { linkTask?.cancel() }

    var canImport: Bool { coordinator.canImport }
    var botName: String { coordinator.context.botName(store.profile) }
    var manyBots: Bool { coordinator.bots.count > 1 }

    /// The bar's one action: Import ("Importing…" while it runs), or Open in Hermes for a conversation already here.
    /// Nothing shows until the preview has answered, and a read-only gateway never gets Import.
    func refreshBarButton() {
        guard let host else { return }
        var title: String?
        var enabled = true
        if importedId != nil {
            title = "Open in Hermes"
        } else if case .loaded = phase, canImport {
            title = importing ? "Importing…" : "Import"
            enabled = !importing && isOnline
        }
        guard let title else { host.navigationItem.rightBarButtonItem = nil; return }
        let item = UIBarButtonItem(title: title, primaryAction: UIAction(title: title) { [weak self] _ in self?.act() })
        item.style = .prominent
        item.isEnabled = enabled
        item.accessibilityIdentifier = "import-sessions.import"
        host.navigationItem.rightBarButtonItem = item
    }

    /// Follows the link: Import and the offline line change with it.
    private func followLink() {
        guard linkTask == nil else { return }
        let client = coordinator.context.client
        linkTask = Task { [weak self] in
            for await state in client.connectionStates() {
                guard let self, !Task.isCancelled else { return }
                let ready = state == .ready
                guard ready != self.isOnline else { continue }
                self.isOnline = ready
                self.refreshBarButton()
            }
        }
    }

    func load() {
        followLink()
        task?.cancel()
        phase = .loading
        refreshBarButton()
        let session = self.session, store = self.store
        task = Task { [weak self] in
            do {
                let preview = try await store.preview(session)
                guard let self, !Task.isCancelled else { return }
                self.importedId = preview.alreadyImported ?? self.importedId
                self.phase = .loaded(preview)
            } catch {
                guard let self, !Task.isCancelled, !(error is CancellationError) else { return }
                self.phase = .failed(PagesREST.reason(error))
            }
            self?.refreshBarButton()
        }
    }

    private func act() {
        let title = ForeignSessions.title(session)
        if let importedId {
            // Already in Hermes: its chat opens, with no second import.
            coordinator.openChat(sessionId: importedId, title: title, from: host)
            return
        }
        guard !importing, canImport else { return }
        importing = true
        refreshBarButton()
        let session = self.session, store = self.store
        Task { [weak self] in
            do {
                let result = try await store.importSession(session)
                guard let self else { return }
                self.importing = false
                self.importedId = result.sessionId
                self.refreshBarButton()
                PagesHaptics.success()
                self.coordinator.context.services.refreshSessions()
                self.coordinator.openChat(sessionId: result.sessionId, title: title, from: self.host)
            } catch {
                guard let self else { return }
                self.importing = false
                self.refreshBarButton()
                FailureAlert.present(title: ForeignSessions.importErrorTitle, reason: PagesREST.reason(error), from: self.host) { [weak self] in
                    self?.act()
                }
            }
        }
    }
}

struct ImportPreviewView: View {
    @Bindable var model: ImportPreviewModel

    var body: some View {
        switch model.phase {
        case .loading:
            MoreSkeleton(rows: 6, label: "Opening Preview…")
        case .failed(let reason):
            MoreErrorState(title: ForeignSessions.previewErrorTitle, reason: "\(ForeignSessions.previewErrorText)\n\(reason)") { model.load() }
        case .loaded(let preview):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    header(preview)
                    if preview.messages.isEmpty {
                        Text(ForeignSessions.emptyPreview)
                            .font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                            .accessibilityIdentifier("import-sessions.preview.empty")
                    }
                    ForEach(Array(preview.messages.enumerated()), id: \.offset) { _, turn in
                        ImportTurnBubble(turn: turn, label: model.session.label)
                    }
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(Color.hqGroupedPage)
            .accessibilityIdentifier("import-sessions.preview.scroll")
        }
    }

    @ViewBuilder private func header(_ preview: ForeignPreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ForeignSessions.title(model.session))
                .font(Font.hq(.title3).weight(.semibold)).foregroundStyle(Color.hqLabel)
                .accessibilityAddTraits(.isHeader)
            Text("\(model.session.label) · \(ForeignSessions.messages(max(preview.total, model.session.turnCount)))")
                .font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
            if model.importedId != nil {
                notice(ForeignSessions.alreadyHere, symbol: "checkmark.circle.fill", identifier: "import-sessions.preview.already")
            }
            if preview.truncated {
                notice(ForeignSessions.previewLimit, symbol: "text.badge.minus", identifier: "import-sessions.preview.shortened")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func notice(_ text: String, symbol: String, identifier: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(Color.hqLabel2).accessibilityHidden(true)
            Text(text).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: HQPalette.lifted), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.importedId == nil {
                Text(ForeignSessions.copyNotice)
                    .accessibilityIdentifier("import-sessions.preview.footnote")
                if model.canImport && model.manyBots {
                    Text("Imports into \(model.botName).")
                }
                if !model.canImport {
                    Text("This gateway is read-only, so nothing can be imported from here.")
                } else if !model.isOnline {
                    Text(MorePages.offlineFooter)
                }
            }
        }
        .font(Font.hq(.footnote))
        .foregroundStyle(Color.hqLabel2)
        .padding(.top, 6)
    }
}

/// One turn as a plain bubble: yours trailing on the tint's wash, the assistant's leading on the card colour.
struct ImportTurnBubble: View {
    var turn: ForeignTurn
    var label: String

    var body: some View {
        let mine = turn.isUser
        VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            Text(ForeignSessions.speaker(turn, label: label))
                .font(Font.hq(.caption).weight(.semibold)).foregroundStyle(Color.hqLabel2)
                .padding(.horizontal, 6)
            Text(Self.styled(turn))
                .font(Font.hq(.body)).foregroundStyle(Color.hqLabel)
                .textSelection(.enabled)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(mine ? Color.hqTint.opacity(0.16) : Color(uiColor: HQPalette.lifted),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(mine ? .leading : .trailing, 36)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(mine ? "import-sessions.turn.user" : "import-sessions.turn.assistant")
    }

    /// The assistant's words with inline Markdown (bold, code, links); yours exactly as typed.
    static func styled(_ turn: ForeignTurn) -> AttributedString {
        if turn.isUser { return AttributedString(turn.content) }
        let text = ForeignSessions.previewText(turn.content)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
