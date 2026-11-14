// More › Bot Profiles (docs/spec/3x-morepages.md §10): the list (the bot's head, its name, "`id` · model · N skills",
// search behind the bar's magnifier, pull to refresh, "N profiles") and a profile's page (facts, SOUL.md, Rename
// Bot…, Delete Bot…). New Profile is not offered here: Bots › New Bot is the one way to make a bot (D-M9).

import SwiftUI
import UIKit

extension MorePages {
    static func installProfiles() {
        ProfilesAccess.resetDraftsIfAsked()
        factories["profiles"] = { context in
            let model = ProfilesModel(context: context)
            let page = MorePageController(title: "Bot Profiles", identifier: "profiles.page", ProfilesListView(model: model))
            model.host = page
            let search = UISearchController(searchResultsController: nil)
            search.obscuresBackgroundDuringPresentation = false
            search.searchBar.placeholder = "Search Profiles"
            search.searchBar.autocapitalizationType = .none
            search.searchBar.autocorrectionType = .no
            let capsule = PageBarCapsule(host: page, configuration: .init(page: "profiles", search: search))
            let updater = ProfilesSearch(model: model, capsule: capsule)
            search.searchResultsUpdater = updater
            capsule.install()
            page.retained = [model, capsule, updater]
            page.keyRefresh = { [weak model] in Task { await model?.refresh() } }   // [Mac UI check 2026-11-13] ⌘R, as a pull (the Mac has no pull)
            page.onAppear = { [weak model] in model?.pageAppeared() }
            page.onDisappear = { [weak model] in model?.pageDisappeared() }
            model.load()
            return page
        }
    }
}

/// The search field's text → the model's query; the magnifier reads "on" while one is typed.
final class ProfilesSearch: NSObject, UISearchResultsUpdating {
    private weak var model: ProfilesModel?
    private weak var capsule: PageBarCapsule?

    init(model: ProfilesModel, capsule: PageBarCapsule) {
        self.model = model
        self.capsule = capsule
    }

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        if model?.query != text { model?.query = text }
        capsule?.updateSearchState()
    }
}

// MARK: - List

struct ProfilesListView: View {
    @Bindable var model: ProfilesModel

    var body: some View {
        switch model.phase {
        case .loading:
            MoreSkeleton(tile: true, label: "Loading profiles…") { model.load() }
        case .failed(let reason):
            MoreErrorState(title: "Couldn’t Load Profiles", reason: reason, page: "Bot Profiles") { model.load() }
        case .loaded:
            list
        }
    }

    @ViewBuilder private var list: some View {
        let rows = model.shown
        let searching = !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if rows.isEmpty && searching {
            ContentUnavailableView.search(text: model.query)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.hqGroupedPage)
                .accessibilityIdentifier("profiles.search-miss")
        } else {
            List { Group {
                Section {
                    ForEach(rows) { row in
                        ProfileRowView(model: model, row: row)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 6))
                    }
                } footer: { HQSectionFooter {
                    VStack(alignment: .leading, spacing: 6) {
                        if !searching {
                            Text(ProfileName.count(model.rows.count)).accessibilityIdentifier("profiles.count")
                        }
                        if let stale = model.staleReason {
                            Text("Couldn’t refresh. \(stale)").accessibilityIdentifier("profiles.stale")
                            // [Mac UI check 2026-11-13] The Mac has no pull: the failed refresh offers its own retry.
                            Button("Try Again") { model.load() }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.hqTintText)
                                .accessibilityIdentifier("profiles.stale.retry")
                        }
                    }
                    .font(Font.hq(.footnote))
                } }
            }.hqMacSettingsRowInsets() }
            .listStyle(.insetGrouped)
            .hqMacForm()   // [mac] Stress test 2026-10-28 #8, #53: the readable width, one inset, small switches
            .hqGroupedPage()
            // Item 9: the iPhone takes the shared top gap every pushed More page uses; the Mac keeps its own inset.
            .contentMargins(.top, MacInset.top(otherwise: MorePageMetrics.topGap), for: .scrollContent)   // [mac] Stress test 2026-10-28 #53
            .refreshable { await model.refresh() }
            .accessibilityIdentifier("profiles.list")
        }
    }
}

struct ProfileRowView: View {
    var model: ProfilesModel
    var row: ProfileRow

    var body: some View {
        let title = model.title(row)
        let subtitle = model.subtitle(row)
        HStack(spacing: 0) {
            Button {
                model.open(row)
            } label: {
                // [profile-rows] Owner 2026-11-10 (design pick 28): one line a row, the model and skills at the trailing
                // edge, a 30 pt face, 8 pt above and below. A name and words too long to share the line (and every
                // row at the larger text sizes) keep the two-line row.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        HeadImage(raw: model.bot(row)?.head, profile: row.name, size: HQFont.scaled(30))
                            .accessibilityHidden(true)
                        Text(title).font(Font.hq(.body)).foregroundStyle(Color.hqLabel).lineLimit(1).fixedSize()
                        Spacer(minLength: 12)
                        Text(subtitle).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).lineLimit(1).fixedSize()
                    }
                    .padding(.vertical, 8)
                    HStack(spacing: 12) {
                        HeadImage(raw: model.bot(row)?.head, profile: row.name, size: 40)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title)
                                .font(Font.hq(.body))
                                .foregroundStyle(Color.hqLabel)
                                .lineLimit(3)
                            Text(subtitle)
                                .font(Font.hq(.footnote))
                                .foregroundStyle(Color.hqLabel2)
                                // [mac] Stress test 2026-10-28 #21: one line, cut at the end, in a narrow column.
                                .lineLimit(DeviceWord.isMac ? 1 : nil)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                    }
                    .padding(.vertical, 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(subtitle)")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("profiles.row.\(row.name)")

            // Item 3: every row opens its page by tapping, so every row ends in the same chevron, not a ⋯ on most
            // rows and a chevron only on the one bot that can't be renamed or deleted. Rename and Delete move to a
            // long press and a swipe, as on Bots and Sessions; the default bot's menu simply leaves them out.
            SettingsChevron()   // [mac] Stress test 2026-10-31: the Mac's one quiet chevron (it drew iOS's here)
                .frame(width: 44, height: 44)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if model.canChange(row) {
                Button(role: .destructive) { model.delete(row, from: model.host) } label: {
                    Label("Delete", systemImage: "trash")
                }
                .accessibilityIdentifier("profiles.swipe.delete.\(row.name)")
                Button { model.rename(row, from: model.host) } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(.blue)
                .accessibilityIdentifier("profiles.swipe.rename.\(row.name)")
            }
        }
        .contextMenu { if model.canChange(row) { actions } }
    }

    @ViewBuilder private var actions: some View {
        Button {
            model.rename(row, from: model.host)
        } label: {
            Label("Rename Bot…", systemImage: "pencil")
        }
        Button(role: .destructive) {
            model.delete(row, from: model.host)
        } label: {
            Label("Delete Bot…", systemImage: "trash")
        }
    }
}

// MARK: - Detail

struct ProfileDetailView: View {
    var model: ProfilesModel
    var state: ProfileDetailState

    var body: some View {
        let row = state.row
        List { Group {
            Section {
                HStack(spacing: 14) {
                    HeadImage(raw: model.bot(row)?.head, profile: row.name, size: 56)
                        .accessibilityHidden(true)
                    Text(model.title(row))
                        .font(Font.hq(.title3).weight(.semibold))
                        .foregroundStyle(Color.hqLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            Section {
                fact("Bot ID", row.name, id: "id")
                // Tester batch 3: the profile's own default model, changed here (Settings › Model is the default's).
                if model.canChangeModel(row) {
                    ValueRow(title: "Default Model", value: model.modelValue(row)) { model.openDefaultModel(row, from: state.host) }
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("profiles.detail.model")
                        .disabled(model.modelChange.switching != nil)
                    // Tester 2026-10-30: this profile's own, not only the default's under Settings › Model.
                    link("Context Window", id: "profiles.detail.context-window") { model.openContextWindow(row, from: state.host) }   // [context-window]
                        .padding(.vertical, 6)
                    link("Fallback Models", id: "profiles.detail.fallbacks") { model.openFallbacks(row, from: state.host) }
                        .padding(.vertical, 6)
                    link("Auxiliary Models", id: "profiles.detail.auxiliary") { model.openAuxiliary(row, from: state.host) }
                        .padding(.vertical, 6)
                } else if let name = model.modelName(row) {
                    fact("Default Model", name, id: "model")
                }
                if let provider = row.provider { fact("Provider", provider, id: "provider") }
                fact("Skills Installed", String(row.skillCount), id: "skills")
                if let path = row.path { folder(path) }
            } footer: { HQSectionFooter {
                // [model-scope] Owner 2026-11-03: whose models these rows change, as Bot Info › Brain says.
                if model.canChangeModel(row) {
                    Text(SettingsWords.botModelScope(bot: model.title(row), isDefault: row.isDefault))
                        .accessibilityIdentifier("profiles.detail.model-scope")
                }
            } }
            Section {
                link("Instructions", id: "profiles.detail.soul") { model.openSoul(row, from: state.host) }
            } footer: { HQSectionFooter {
                Text(BotInfoWords.instructionsFooter(botName: model.title(row)))
            } }
            changes(row)
        }.hqMacSettingsRowInsets() }
        .listStyle(.insetGrouped)
        .hqMacForm()   // [mac] Stress test 2026-10-28 #8, #53: the readable width, one inset, small switches
        .hqGroupedPage()
        .accessibilityIdentifier("profiles.detail.list")
    }

    @ViewBuilder private func changes(_ row: ProfileRow) -> some View {
        if row.isDefault {
            Section {} footer: { HQSectionFooter {
                Text("The default profile can’t be renamed or deleted.").accessibilityIdentifier("profiles.detail.default-footer")
            } }
        } else if model.readOnly {
            EmptyView()
        } else if !model.online {
            Section {} footer: { HQSectionFooter {
                Text(MorePages.offlineFooter).accessibilityIdentifier("profiles.detail.offline-footer")
            } }
        } else {
            let renaming = model.renaming == row.name
            Section {
                Button {
                    model.rename(row, state: state, from: state.host)
                } label: {
                    HStack {
                        Text(renaming ? "Renaming…" : "Rename Bot…")
                        Spacer()
                        if renaming { ProgressView() }
                    }
                }
                .disabled(model.renaming != nil)
                .accessibilityIdentifier("profiles.detail.rename")
                Button("Delete Bot…", role: .destructive) {
                    model.delete(row, state: state, from: state.host)
                }
                .disabled(model.renaming != nil)
                .accessibilityIdentifier("profiles.detail.delete")
            }
        }
    }

    /// A row that pushes a page.
    private func link(_ title: String, id: String, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack {
                Text(title).foregroundStyle(Color.hqLabel)
                Spacer()
                SettingsChevron()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func fact(_ label: String, _ value: String, id: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label).foregroundStyle(Color.hqLabel)
                Spacer(minLength: 12)
                Text(value).foregroundStyle(Color.hqLabel2).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(label).foregroundStyle(Color.hqLabel)
                Text(value).foregroundStyle(Color.hqLabel2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Font.hq(.body))
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)")
        .accessibilityIdentifier("profiles.detail.fact.\(id)")
        .contextMenu {
            Button {
                UIPasteboard.general.string = value
                PagesHaptics.success()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }

    /// The folder: its path under the label, wrapping (a large text size must not cut the profile's own name); hold to copy.
    private func folder(_ path: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Folder").foregroundStyle(Color.hqLabel)
            Text(path)
                .font(Font.hq(.footnote).monospaced())
                .foregroundStyle(Color.hqLabel2)
                .lineLimit(4)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Font.hq(.body))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Folder, \(path)")
        .accessibilityIdentifier("profiles.detail.fact.folder")
        .contextMenu {
            Button {
                UIPasteboard.general.string = path
                PagesHaptics.success()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }
}
