// [coding-pr-review] Owner 2026-11-21 (option B, the board's fourth column: artifacts/coding-pr-review/mock1.html): the
// PR card. A coding row's PR mark opens it (instead of the chat), and so do Session Info's pull request rows. What it
// shows is `PullRequestCard`'s (HermesKit/Model/PullRequestCard.swift); this draws it in the settings list's look, as
// the Repository page does: the state line, the name, one quiet line with the repository and branch, then Actions and
// the chat's other pull requests. Ask <bot> to Merge… shows its exact words first; Send posts them to that chat.
// [pr-card-detail] Opened, it asks for that one chat with `detail: true` and `fresh: true`, shows what it has at once
// and fills in Checks and Changes when the answer comes (a quiet progress mark in the head, never a spinner in place
// of content).

import SwiftUI
import UIKit

/// [pr-card-detail] What one card sheet shows, shared by its pushed pages: the chat's status, refreshed once by the
/// card's own `detail: true` ask, with explicit error/retry and manual refresh support.
@MainActor final class PullRequestCardModel: ObservableObject {
    @Published var status: SessionPRStatus
    @Published var loading = false
    @Published var error: String? = nil
    @Published var marking = false

    private let fetcher: ((Bool) async throws -> SessionPRStatus?)?

    init(status: SessionPRStatus, fetcher: ((Bool) async throws -> SessionPRStatus?)? = nil) {
        self.status = status
        self.fetcher = fetcher
    }

    /// Asks once (or again on explicit manual refresh). Keeps what the card already showed on error and surfaces
    /// a quiet retry banner instead of failing silently.
    func refresh(manual: Bool = false) {
        guard !loading, let fetcher else { return }
        loading = true
        if manual { error = nil }
        Task { [weak self] in
            defer { self?.loading = false }
            do {
                let fresh = try await fetcher(manual)
                guard let self else { return }
                self.status = PullRequestCard.refreshed(self.status, with: fresh)
                self.error = nil
            } catch SessionStore.PRDetailError.unsupported {
                guard let self else { return }
                self.error = "Checks and file diffs require the Hermes HQ add-on."
            } catch {
                guard let self else { return }
                self.error = "Couldn’t load latest checks and changes."
            }
        }
    }

    /// Legacy closure helper for callers without throwing detail refresh.
    func refresh(_ ask: @escaping () async -> SessionPRStatus?) {
        guard !loading else { return }
        loading = true
        Task { [weak self] in
            let fresh = await ask()
            guard let self else { return }
            self.status = PullRequestCard.refreshed(self.status, with: fresh)
            self.loading = false
        }
    }

    var canRefresh: Bool { fetcher != nil }
}

struct PullRequestCardView: View {
    @ObservedObject var model: PullRequestCardModel
    let focus: PullRequestCard.Focus
    let chatTitle: String
    let botName: String
    let chatWorking: Bool
    /// The card as it stood when the page opened: kept if a fresh answer drops the item (the chat's code is gone).
    let opened: PullRequestCard
    var onOpen: (URL) -> Void = { _ in }
    var onAsk: (String, String) -> Void = { _, _ in }
    var onOther: (PullRequestCard.Focus) -> Void = { _ in }
    var onRuns: ([SessionPRChecks.Run]) -> Void = { _ in }
    var onFile: (PullRequestCard.FileRow) -> Void = { _ in }
    var onOpenChat: (() -> Void)? = nil
    var onMarkClosed: ((Bool) -> Void)? = nil
    var onRepository: (() -> Void)? = nil

    private var card: PullRequestCard {
        PullRequestCard(status: model.status, focus: focus, chatTitle: chatTitle, botName: botName) ?? opened
    }

    var body: some View {
        let card = self.card
        List { Group {
            Section { head(card) }
                .listRowBackground(Color.clear)
                // The words start where the section labels under them do, and clear of the cell's rounded corner
                // (at 4 pt the corner cut the first letter of the last line).
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 8, trailing: 20))
                .hqDesktopBareRow()
            if let notice = card.unknownNotice {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(notice)
                            .font(Font.hq(.subheadline))
                            .foregroundStyle(Color.hqLabel2)
                            .accessibilityIdentifier("prcard.unknownNotice")
                        HStack(spacing: 16) {
                            if model.canRefresh {
                                Button("Try Again") { model.refresh(manual: true) }
                                    .font(Font.hq(.subheadline).weight(.semibold))
                                    .foregroundStyle(Color.hqTintText)
                                    .disabled(model.loading)
                                    .accessibilityIdentifier("prcard.retry")
                            }
                            if model.status.unknownReason == .unmatched, let onRepository {
                                Button("Link Repository…", action: onRepository)
                                    .font(Font.hq(.subheadline).weight(.semibold))
                                    .foregroundStyle(Color.hqTintText)
                                    .accessibilityIdentifier("prcard.linkRepository")
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            if let error = model.error, card.unknownNotice == nil {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Color.hqOrange)
                            .accessibilityHidden(true)
                        Text(error)
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqLabel2)
                        Spacer(minLength: 8)
                        if model.canRefresh {
                            Button("Retry") { model.refresh(manual: true) }
                                .font(Font.hq(.footnote).weight(.semibold))
                                .foregroundStyle(Color.hqTintText)
                                .disabled(model.loading)
                                .accessibilityIdentifier("prcard.retry")
                        }
                    }
                    .accessibilityIdentifier("prcard.error")
                }
            }
            if let checks = card.checksRow {
                Section {
                    checksRow(checks)
                } header: { HQSectionLabel { Text("Checks") } }
            }
            let files = card.fileRows
            if let label = card.changesLabel {
                Section {
                    ForEach(Array(files.enumerated()), id: \.offset) { place, file in
                        fileRow(file).accessibilityIdentifier("prcard.file.\(place)")
                    }
                    if let more = card.moreFilesWords {
                        Text(more)
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqLabel2)
                            .accessibilityIdentifier("prcard.moreFiles")
                    }
                } header: { HQSectionLabel { Text(verbatim: label) }.accessibilityIdentifier("prcard.changes") }
            }
            let actions = card.actions
            let pinnedPrimary = primaryPinnedAction(for: card)
            let listActions = actions.filter { action in
                switch (pinnedPrimary, action) {
                case (.fixChecks, .askToFixChecks): return false
                case (.merge, .askToMerge): return false
                default: return true
                }
            }
            let showOpenChatInList = pinnedPrimary == nil && onOpenChat != nil
            let markToggle = onMarkClosed != nil ? card.markClosedToggle : nil
            if !listActions.isEmpty || showOpenChatInList || markToggle != nil {
                Section {
                    ForEach(listActions, id: \.self) { action in
                        switch action {
                        case .openOnGitHub(let url):
                            Button("Open on GitHub") { onOpen(url) }
                                .foregroundStyle(Color.hqTintText)
                                .accessibilityIdentifier("prcard.openOnGitHub")
                        case .askToFixChecks(let words):
                            Button(card.fixChecksTitle) { onAsk(words, card.fixChecksTitle) }
                                .foregroundStyle(Color.hqTintText)
                                .accessibilityIdentifier("prcard.askToFixChecks")
                        case .askToMerge(let words):
                            Button(card.mergeTitle) { onAsk(words, card.mergeConfirmTitle(chatWorking: chatWorking)) }
                                .foregroundStyle(Color.hqTintText)
                                .accessibilityIdentifier("prcard.askToMerge")
                        }
                    }
                    if showOpenChatInList, let onOpenChat {
                        Button("Open Chat", action: onOpenChat)
                            .foregroundStyle(Color.hqTintText)
                            .accessibilityIdentifier("prcard.openChat")
                    }
                    if let markToggle, let onMarkClosed {
                        Button(markToggle ? "Mark as Closed" : "Reopen") { onMarkClosed(markToggle) }
                            .foregroundStyle(markToggle ? Color.hqLabel : Color.hqTintText)
                            .disabled(model.marking)
                            .accessibilityIdentifier(markToggle ? "prcard.markClosed" : "prcard.reopen")
                    }
                } header: { HQSectionLabel { Text("Actions") } }
            }
            let others = card.others
            if !others.isEmpty {
                Section {
                    ForEach(Array(others.enumerated()), id: \.offset) { place, other in
                        Button { onOther(other.focus) } label: {
                            HStack(spacing: 10) {
                                PullRequestGlyph(state: other.state, size: 16)
                                Text(other.label).foregroundStyle(Color.hqLabel).lineLimit(1)
                                Spacer(minLength: 8)
                                SettingsChevron()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("prcard.other.\(place)")
                    }
                } header: { HQSectionLabel { Text("Also in This Chat") } }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList()
        .accessibilityIdentifier("prcard")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let pinnedPrimary = primaryPinnedAction(for: card) {
                pinnedActionBar(pinnedPrimary, card: card)
            }
        }
        .toolbar {
            if model.canRefresh {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.refresh(manual: true) } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.loading)
                    .accessibilityLabel("Refresh Pull Request")
                    .accessibilityIdentifier("prcard.refresh")
                }
            }
        }
    }

    private enum PinnedPrimaryAction {
        case merge(words: String, isReady: Bool)
        case fixChecks(words: String)
    }

    private func primaryPinnedAction(for card: PullRequestCard) -> PinnedPrimaryAction? {
        if let words = card.actions.compactMap({ if case .askToFixChecks(let w) = $0 { return w }; return nil }).first {
            return .fixChecks(words: words)
        }
        if let words = card.actions.compactMap({ if case .askToMerge(let w) = $0 { return w }; return nil }).first {
            let ready = card.markState == .open && card.checksRow?.state != .failed && card.checksRow?.state != .running
            return .merge(words: words, isReady: ready)
        }
        return nil
    }

    private func pinnedActionBar(_ primary: PinnedPrimaryAction, card: PullRequestCard) -> some View {
        HStack(spacing: 10) {
            switch primary {
            case .merge(let words, let isReady):
                Button {
                    onAsk(words, card.mergeConfirmTitle(chatWorking: chatWorking))
                } label: {
                    Text(card.mergeTitle)
                        .font(Font.hq(.subheadline).weight(.semibold))
                        .foregroundStyle(isReady ? Color.white : Color.hqOnTint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(isReady ? Color.hqGreen : Color.hqTint, in: RoundedRectangle(cornerRadius: HQShape.radius(12, .control), style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("prcard.askToMerge")
            case .fixChecks(let words):
                Button {
                    onAsk(words, card.fixChecksTitle)
                } label: {
                    Text(card.fixChecksTitle)
                        .font(Font.hq(.subheadline).weight(.semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.hqRed, in: RoundedRectangle(cornerRadius: HQShape.radius(12, .control), style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("prcard.askToFixChecks")
            }
            if let onOpenChat {
                Button(action: onOpenChat) {
                    Text("Open Chat")
                        .font(Font.hq(.subheadline).weight(.semibold))
                        .foregroundStyle(Color.hqLabel)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Color.hqGroupedCard, in: RoundedRectangle(cornerRadius: HQShape.radius(12, .control), style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: HQShape.radius(12, .control), style: .continuous).strokeBorder(Color.hqStroke, lineWidth: 0.75))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("prcard.openChat")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    /// The Checks row: its mark as on the row (red only when failing), its words; with runs, a chevron to them.
    @ViewBuilder private func checksRow(_ checks: PullRequestCard.ChecksRow) -> some View {
        let line = HStack(spacing: 10) {
            PullRequestCheckMark(state: checks.state)
                .frame(width: HQFont.scaled(14))
            Text(checks.words)
                .font(Font.hq(.body))
                .foregroundStyle(checks.state == .failed ? Color.hqRed : Color.hqLabel)
            Spacer(minLength: 8)
            if checks.runs != nil { SettingsChevron() }
        }
        .contentShape(Rectangle())
        if let runs = checks.runs {
            Button { onRuns(runs) } label: { line }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(checks.words)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("prcard.checks")
        } else {
            line
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(checks.words)
                .accessibilityIdentifier("prcard.checks")
        }
    }

    /// One file: its name in monospace, its folder quiet under it (or what stands in for its diff), "+96 −8" trailing;
    /// a patch pushes the diff.
    @ViewBuilder private func fileRow(_ file: PullRequestCard.FileRow) -> some View {
        let line = HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: file.name)
                    .font(Font.hq(.subheadline).monospaced())
                    .foregroundStyle(Color.hqLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let second = [file.folder, file.note].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                    Text(verbatim: second)
                        .font(Font.hq(.caption))
                        .foregroundStyle(Color.hqLabel2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let counts = file.counts {
                Text(verbatim: counts)
                    .font(Font.hq(.footnote))
                    .monospacedDigit()
                    .foregroundStyle(Color.hqLabel2)
                    .fixedSize()
            }
            if case .patch = file.body { SettingsChevron() }
        }
        .contentShape(Rectangle())
        let spoken = ([file.path] + [file.counts.map { _ in Self.spokenCounts(file) }, file.note].compactMap { $0 }).joined(separator: ", ")
        if case .patch = file.body {
            Button { onFile(file) } label: { line }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
                .accessibilityAddTraits(.isButton)
        } else {
            line
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
        }
    }

    private static func spokenCounts(_ file: PullRequestCard.FileRow) -> String {
        let parts = (file.counts ?? "").split(separator: " ")
        let added = parts.first.map { String($0.dropFirst()) } ?? "0", removed = parts.dropFirst().first.map { String($0.dropFirst()) } ?? "0"
        return "\(added) added, \(removed) removed"
    }

    /// The state line, the name and the place, on the page (no card), as the board draws them.
    private func head(_ card: PullRequestCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                PullRequestGlyph(state: card.markState, size: 16)
                Text(card.stateWords)
                    .font(Font.hq(.subheadline).weight(.semibold))
                    .foregroundStyle(Color(uiColor: PullRequestInk.text(card.markState)))
                if model.loading {
                    // [pr-card-detail] Asking for the checks and files: a quiet mark, the content stays.
                    ProgressView().controlSize(.mini).tint(Color.hqLabel3)
                        .accessibilityLabel("Loading")
                        .accessibilityIdentifier("prcard.loading")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("prcard.state")
            Text(card.name)
                .font(Font.hq(.title3).weight(.bold))
                .foregroundStyle(Color.hqLabel)
                .lineLimit(2)
                .accessibilityIdentifier("prcard.name")
            if let place = card.place {
                Text(place)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("prcard.place")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A pull request state's glyph in its mark's colour (the row's mark, without its number).
struct PullRequestGlyph: View {
    var state: SessionPRStatus.State
    var size: CGFloat = 14
    var body: some View {
        Image(uiImage: SessionPRGlyph.image(state)).renderingMode(.template)
            .resizable().scaledToFit()
            .frame(width: HQFont.scaled(size), height: HQFont.scaled(size))
            .foregroundStyle(Color(uiColor: SessionPRGlyph.color(state)))
            .accessibilityHidden(true)
    }
}

/// [coding-pr-review] Words in a state's colour on the card: the mark's colour moved toward the theme's ink until it
/// reads at 4.5:1 on the list's card (the system green read at about 2:1 on white). The glyph keeps the mark's colour.
@MainActor enum PullRequestInk {
    private static var cache: [SessionPRStatus.State: UIColor] = [:]
    static func text(_ state: SessionPRStatus.State) -> UIColor {
        if let colour = cache[state] { return colour }
        let mark = SessionPRGlyph.color(state), ink = HQPalette.label, card = HQPalette.groupedCard
        let colour = UIColor { traits in
            ThemeMath.readable(rgba(mark.resolvedColor(with: traits)), text: rgba(ink.resolvedColor(with: traits)),
                               on: rgba(card.resolvedColor(with: traits))).uiColor
        }
        cache[state] = colour
        return colour
    }

    nonisolated private static func rgba(_ colour: UIColor) -> RGBA {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        colour.getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGBA(unit: Double(r), Double(g), Double(b), Double(a))
    }
}

/// [coding-pr-review] The PR card as a sheet: built from a chat's status, its own pages pushed inside it (another of
/// the chat's pull requests), Ask to Merge confirmed in an alert, then handed to `send` once the sheet is gone.
@MainActor enum PullRequestCardSheet {
    struct Chat {
        var profile: String
        var id: String
        var title: String
        var botName: String
        var isWorking: Bool = false
    }

    /// The card's sheet, or nil where there is no card (no mark). `send`: the confirmed words, after the sheet closed.
    /// `refreshResult`: the card's own ask for this chat (`detail: true`, `fresh: true`), surfacing errors for retry.
    static func make(status: SessionPRStatus?, chat: Chat, focus: PullRequestCard.Focus = .lead,
                     refresh: (() async -> SessionPRStatus?)? = nil,
                     refreshResult: ((Bool) async throws -> SessionPRStatus?)? = nil,
                     onOpenChat: (() -> Void)? = nil,
                     onMarkClosed: ((Bool) async throws -> SessionPRStatus?)? = nil,
                     onRepository: (() -> Void)? = nil,
                     send: @escaping (String) -> Void) -> UINavigationController? {
        guard let status, let card = PullRequestCard(status: status, focus: focus, chatTitle: chat.title, botName: chat.botName) else { return nil }
        let fetcher: ((Bool) async throws -> SessionPRStatus?)? = refreshResult ?? refresh.map { ask in { _ in await ask() } }
        let model = PullRequestCardModel(status: status, fetcher: fetcher)
        weak var sheet: UINavigationController?
        let page = self.page(card, chatWorking: chat.isWorking, model: model, sheet: { sheet },
                             onOpenChat: onOpenChat, onMarkClosed: onMarkClosed, onRepository: onRepository, send: send)
        let wrapped = ChatSheet.wrap(page, title: card.title, detents: [.medium(), .large()])
        sheet = wrapped
        if fetcher != nil { model.refresh(manual: false) }
        return wrapped
    }

    private static func page(_ card: PullRequestCard, chatWorking: Bool, model: PullRequestCardModel,
                             sheet: @escaping () -> UINavigationController?,
                             onOpenChat: (() -> Void)?,
                             onMarkClosed: ((Bool) async throws -> SessionPRStatus?)?,
                             onRepository: (() -> Void)?,
                             send: @escaping (String) -> Void) -> UIViewController {
        weak var host: UIViewController?
        let openChatAction: (() -> Void)? = onOpenChat.map { open in
            {
                let nav = sheet()
                nav?.presentingViewController?.dismiss(animated: true) { open() } ?? open()
            }
        }
        let repoAction: (() -> Void)? = onRepository.map { openRepo in
            {
                let nav = sheet()
                nav?.presentingViewController?.dismiss(animated: true) { openRepo() } ?? openRepo()
            }
        }
        let markAction: ((Bool) -> Void)? = onMarkClosed.map { mark in
            { closed in
                guard !model.marking else { return }
                model.marking = true
                Task { @MainActor in
                    defer { model.marking = false }
                    do {
                        if let updated = try await mark(closed) {
                            model.status = updated
                            model.error = nil
                        }
                        Haptics.play(.success)
                    } catch {
                        guard let host else { return }
                        FailureAlert.present(title: closed ? "Couldn’t Mark as Closed" : "Couldn’t Reopen",
                                             reason: SessionActionText.reason(error), from: host)
                    }
                }
            }
        }
        let view = PullRequestCardView(model: model, focus: card.focus, chatTitle: card.chatTitle, botName: card.botName,
                                       chatWorking: chatWorking, opened: card,
                                       onOpen: { url in
            UIApplication.shared.open(url)
        }, onAsk: { words, title in
            guard let host else { return }
            confirm(words, title: title, from: host) {
                let nav = sheet()
                nav?.presentingViewController?.dismiss(animated: true) { send(words) } ?? send(words)
            }
        }, onOther: { focus in
            guard let next = PullRequestCard(status: model.status, focus: focus, chatTitle: card.chatTitle, botName: card.botName) else { return }
            let pushed = page(next, chatWorking: chatWorking, model: model, sheet: sheet,
                              onOpenChat: onOpenChat, onMarkClosed: onMarkClosed, onRepository: onRepository, send: send)
            pushed.title = next.title
            pushed.navigationItem.largeTitleDisplayMode = .never
            sheet()?.pushViewController(pushed, animated: true)
        }, onRuns: { runs in
            expandDetent(sheet())
            let pushed = UIHostingController(rootView: PullRequestRunsPage(runs: runs, onOpen: { url in
                UIApplication.shared.open(url)
            }))
            pushed.title = "Checks"
            pushed.navigationItem.largeTitleDisplayMode = .never
            sheet()?.pushViewController(pushed, animated: true)
        }, onFile: { file in
            guard case .patch(let patch) = file.body else { return }
            expandDetent(sheet())
            let onComment: (String) -> Void = { message in
                let nav = sheet()
                nav?.presentingViewController?.dismiss(animated: true) { send(message) } ?? send(message)
            }
            sheet()?.pushViewController(PullRequestDiffPage(name: file.name, path: file.path, patch: patch,
                                                            botName: card.botName, onComment: onComment), animated: true)
        }, onOpenChat: openChatAction, onMarkClosed: markAction, onRepository: repoAction)
        let controller = UIHostingController(rootView: view)
        host = controller
        return controller
    }

    private static func expandDetent(_ sheet: UINavigationController?) {
        guard let presentation = sheet?.sheetPresentationController,
              presentation.selectedDetentIdentifier != .large else { return }
        presentation.animateChanges { presentation.selectedDetentIdentifier = .large }
    }

    /// The exact words, then Cancel or Send. Nothing is sent without Send.
    static func confirm(_ words: String, title: String, from host: UIViewController, send: @escaping () -> Void) {
        let alert = UIAlertController(title: title.replacingOccurrences(of: "…", with: ""), message: words, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Send", style: .default) { _ in send() })
        alert.view.accessibilityIdentifier = "prcard.confirm"
        host.present(alert, animated: true)
    }

    /// Posts `words` to the chat as a normal message, opening it first when it isn't on show (`open`): the Shortcuts'
    /// first-message road (`NewChatRouter.deliver`, `ChatViewController.sendFromCard`). If delivery times out, tells
    /// the user explicitly and lets them copy the message instead of failing silently.
    static func deliver(_ words: String, to chat: Chat, open: @escaping () -> Void) {
        guard let root = MainTabController.current else { return }
        let profile = chat.profile, id = chat.id
        // Not while the card (or anything else) still covers the chat: the words would go out under a closing sheet.
        // The Shortcuts' own first message keeps its rule: this wait is the card's alone.
        func wanted(_ controller: ChatViewController) -> Bool {
            controller.session.profile == profile && (controller.session as? LiveChatSession)?.storedSessionId == id
                && controller.presentedViewController == nil
        }
        if !(root.chatOnShow.map(wanted) ?? false) { open() }
        Task {
            let sent = await NewChatRouter.deliver(words, send: true, root: root, wanted: wanted)
            AppLog.note("sessions", "pr card: ask \(sent ? "sent" : "not sent, the chat never came up") (\(words.count) chars)")
            guard !sent else { return }
            var top: UIViewController = root
            while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
            let alert = UIAlertController(
                title: "Couldn’t Send Message",
                message: "The chat didn’t open in time, so nothing was sent:\n\n\(words)",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Copy Message", style: .default) { _ in
                UIPasteboard.general.string = words
                Haptics.play(.success)
            })
            alert.addAction(UIAlertAction(title: "Open Chat", style: .default) { _ in open() })
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            top.present(alert, animated: true)
        }
    }
}
