// More › Messaging (docs/spec/3x-morepages.md §12): the list of messaging apps with a status line each, and a
// platform's page (On, Keys, Test Connection, Who Can Message This Bot, Setup Guide, the restart notice).
// Wording: `V/i18n/en.ts` messaging, with the phone rewrites of `B/fe-pages-gates.ts`, in the app's Title Case.

import SwiftUI
import UIKit

extension MorePages {
    static func installMessaging() {
        factories["messaging"] = { context in MessagingPages.list(context) }
    }
}

/// The search field behind the bar's magnifier, for a SwiftUI list page (Messaging, Webhooks).
final class MessagingPageSearch: NSObject, UISearchResultsUpdating {
    let controller = UISearchController(searchResultsController: nil)
    var capsule: PageBarCapsule?
    private let changed: (String) -> Void

    init(page: String, placeholder: String, changed: @escaping (String) -> Void) {
        self.changed = changed
        super.init()
        controller.searchResultsUpdater = self
        controller.obscuresBackgroundDuringPresentation = false
        controller.searchBar.placeholder = placeholder
        controller.searchBar.searchTextField.accessibilityIdentifier = "\(page).search.field"
    }

    func updateSearchResults(for searchController: UISearchController) {
        changed(searchController.searchBar.text ?? "")
        capsule?.updateSearchState()
    }
}

@MainActor
enum MessagingPages {
    static func list(_ context: MorePages.Context) -> UIViewController {
        let model = MessagingModel(context: context)
        let page = MorePageController(title: "Messaging", identifier: "messaging.page", MessagingListView(model: model))
        model.host = page
        let search = MessagingPageSearch(page: "messaging", placeholder: "Search") { [weak model] in model?.query = $0 }
        let capsule = PageBarCapsule(host: page, configuration: .init(page: "messaging", search: search.controller))
        capsule.install()
        search.capsule = capsule
        if DeviceWord.isMac { hideSearchWhileUnavailable(model, capsule) }
        page.retained = [model, search, capsule]
        page.onAppear = { [weak model] in model?.front = nil; model?.appear() }
        page.onDisappear = { [weak model, weak page] in
            // Still on the stack under a platform's page: keep following the link.
            if page?.navigationController == nil { model?.disappear() }
        }
        return page
    }

    /// [mac-audit] Owner 2026-11-02 (#21): no search magnifier over "Not Available on This Hermes".
    private static func hideSearchWhileUnavailable(_ model: MessagingModel, _ capsule: PageBarCapsule) {
        withObservationTracking {
            capsule.searchItem?.isHidden = model.isUnavailable
        } onChange: { [weak model, weak capsule] in
            Task { @MainActor in
                guard let model, let capsule else { return }
                hideSearchWhileUnavailable(model, capsule)
            }
        }
    }

    static func open(_ platform: MessagingPlatform, model: MessagingModel) {
        guard let navigation = model.host?.navigationController else { return }
        let page = MorePageController(title: platform.name, identifier: "messaging.platform.page",
                                      MessagingPlatformView(model: model, platformId: platform.id))
        page.onAppear = { [weak model, weak page] in model?.front = page }
        navigation.pushViewController(page, animated: true)
    }

    /// The app's key page (Settings › Keys) over this platform's keys.
    /// `-HQPagesReadOnly YES` (DEBUG): these pages show no write control, as on a read-only gateway.
    static var debugReadOnly: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "HQPagesReadOnly")
        #else
        return false
        #endif
    }

    static func openKey(_ key: MessagingEnvVar, platform: MessagingPlatform, model: MessagingModel) {
        guard !model.readOnly, let navigation = model.host?.navigationController else { return }
        let keys = EnvKeysModel(api: nil, readOnly: model.readOnly)
        let id = platform.id, name = platform.name
        keys.store = EnvKeyStore(
            load: { [weak model] in model?.platform(id)?.envVars.map(\.info) ?? [] },
            save: { [weak model] key, value in try await model?.saveKey(id, key, value) },
            remove: { [weak model] key in try await model?.removeKey(id, key) },
            removeFooter: { "Removes \($0) from \(HostWord.phrase). \(name) may stop working until you add it again." })
        keys.vars = platform.envVars.map(\.info)
        keys.loaded = true
        let page = MorePageController(title: key.label, identifier: "messaging.key.page",
                                      EnvKeyEditor(key: key.key, label: key.label, model: keys))
        page.retained = [keys]
        navigation.pushViewController(page, animated: true)
    }

    static func openTelegram(model: MessagingModel) {
        guard model.canWrite, let host = model.front ?? model.host else { return }
        let setup = model.telegramSetup()
        let profile = model.profile
        let page = MorePageController(title: "Set Up with Telegram", identifier: "messaging.telegram.sheet", TelegramSetupView(setup: setup))
        page.retained = [setup]
        page.onDisappear = { [weak page] in
            // Closed (✕ or a swipe): before Finish the pairing is given back.
            if page?.navigationController?.presentingViewController == nil || page?.navigationController?.isBeingDismissed == true {
                setup.close()
            }
        }
        setup.onApplied = { [weak model, weak page] applied in
            page?.dismiss(animated: true)
            model?.telegramApplied(applied, for: profile)
        }
        let sheet = ChatSheet.wrap(page, title: "Set Up with Telegram", detents: [.large()])
        host.present(sheet, animated: true)
        setup.start()
    }
}

// MARK: - List

struct MessagingListView: View {
    let model: MessagingModel

    var body: some View {
        switch model.phase {
        case .loading:
            MoreSkeleton(tile: true, label: "Loading messaging apps…") { model.reload() }
        case .failed(let reason):
            if DeviceWord.isMac, model.isUnavailable {
                // [mac-audit] Owner 2026-11-02 (#21): the state alone, with no Bot picker over it.
                MoreErrorState(title: "Couldn’t Load Messaging", reason: reason) { model.reload() }
            } else if model.showsBotPicker, DeviceWord.isMac {
                // [mac] Stress test 2026-10-28 #9: centred under the picker, no card, in both looks.
                MoreStateUnderPicker(bots: model.context.botChoices, selection: profile) {
                    MoreErrorState(title: "Couldn’t Load Messaging", reason: reason) { model.reload() }
                }
            } else if model.showsBotPicker {
                List { Group {
                    picker
                    Section {
                        MoreErrorState(title: "Couldn’t Load Messaging", reason: reason) { model.reload() }
                            .hqListedEmptyState(minHeight: 380)   // [mac] Stress test 2026-10-28 #9
                            .listRowBackground(Color.clear)
                    }
                }.hqMacSettingsRowInsets() }
                .settingsList()
                .contentMargins(.top, MacInset.top(otherwise: 0), for: .scrollContent)   // the first card at Capabilities' height (UX study #174)   // [mac] Stress test 2026-10-28 #53
            } else {
                MoreErrorState(title: "Couldn’t Load Messaging", reason: reason) { model.reload() }
            }
        case .loaded:
            list
        }
    }

    private var profile: Binding<String> { Binding(get: { model.profile }, set: { model.profile = $0 }) }

    @ViewBuilder private var picker: some View {
        if model.showsBotPicker {
            Section {
                MoreBotPicker(bots: model.context.botChoices, selection: profile)
            }
        }
    }

    @ViewBuilder private var list: some View {
        let rows = model.shown
        if model.platforms.isEmpty, !model.showsBotPicker {
            MoreEmptyState(symbol: "bubble.left.and.bubble.right", title: "No Messaging Apps",
                           text: "This gateway has no messaging apps to set up.")
        } else if model.platforms.isEmpty, DeviceWord.isMac {
            // [mac] Stress test 2026-10-28 #9: centred under the picker, no card, in both looks.
            MoreStateUnderPicker(bots: model.context.botChoices, selection: profile) {
                MoreEmptyState(symbol: "bubble.left.and.bubble.right", title: "No Messaging Apps",
                               text: "This gateway has no messaging apps to set up.")
            }
        } else {
            List { Group {
                picker
                if model.platforms.isEmpty {
                    Section {
                        MoreEmptyState(symbol: "bubble.left.and.bubble.right", title: "No Messaging Apps",
                                       text: "This gateway has no messaging apps to set up.")
                            .hqListedEmptyState(minHeight: 320)   // [mac] Stress test 2026-10-28 #9
                            .listRowBackground(Color.clear)
                    }
                } else if rows.isEmpty {
                    Section {
                        ContentUnavailableView.search(text: model.query)
                            .hqListedEmptyState(minHeight: 280)   // [mac] Stress test 2026-10-28 #9
                            .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        ForEach(rows) { platform in
                            Button { MessagingPages.open(platform, model: model) } label: { MessagingRow(platform: platform) }
                                .accessibilityIdentifier("messaging.row.\(platform.id)")
                        }
                    } header: { HQSectionLabel {
                        // The scope: these are this bot's apps (Status & Maintenance lists the whole gateway's).
                        Text("For \(model.context.botName(model.profile))")
                    } } footer: { HQSectionFooter {
                        if !model.online, !model.readOnly { Text(MorePages.offlineFooter) }
                    } }
                }
            }.hqMacSettingsRowInsets() }
            .settingsList()
            .contentMargins(.top, MacInset.top(otherwise: 0), for: .scrollContent)   // the first card at Capabilities' height (UX study #174)   // [mac] Stress test 2026-10-28 #53
            .refreshable { await model.refresh() }
            .accessibilityIdentifier("messaging.list")
        }
    }
}

extension MessagingStatus.Tone {
    var color: Color {
        switch self {
        case .good: return .green
        case .muted: return Color.hqLabel2
        case .warn: return Color.hqOrange
        case .bad: return Color.hqRed
        }
    }
}

/// A status dot and its words; an error is written in red.
struct MessagingStatusLine: View {
    var status: MessagingStatus
    var lines = 2

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(status.tone.color).frame(width: 8, height: 8).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                .accessibilityHidden(true)
            Text(status.text)
                .font(Font.hq(.subheadline))
                .foregroundStyle(status.tone == .bad ? Color.hqRed : Color.hqLabel2)
                .lineLimit(lines)
                .multilineTextAlignment(.leading)
        }
    }
}

struct MessagingRow: View {
    var platform: MessagingPlatform

    var body: some View {
        HStack(spacing: 12) {
            // The label-colour outline glyph Settings' rows use, not the tint, which read as a link (UX study #173).
            Image(systemName: platform.symbol)
                .font(Font.hq(.body))
                .foregroundStyle(Color.hqLabel)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(platform.name).font(Font.hq(.body)).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                MessagingStatusLine(status: platform.status)
            }
            Spacer(minLength: 8)
            SettingsChevron()
                .accessibilityHidden(true)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(platform.name), \(platform.status.text)")
    }
}

// MARK: - A platform's page

struct MessagingPlatformView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let model: MessagingModel
    let platformId: String
    @State private var advancedOpen = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let platform = model.platform(platformId) {
            page(platform)
        } else {
            MoreEmptyState(symbol: "bubble.left.and.bubble.right", title: "No Longer Listed",
                           text: "Your gateway no longer lists this messaging app.")
        }
    }

    private func page(_ platform: MessagingPlatform) -> some View {
        List { Group {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    if !platform.description.isEmpty {
                        Text(platform.description).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    MessagingStatusLine(status: platform.status, lines: 6)
                        .accessibilityIdentifier("messaging.platform.status")
                }
                .padding(.vertical, 6)
            }
            if platform.id == "telegram", !platform.configured, !model.readOnly {
                Section {
                    Button("Set Up with Telegram") { MessagingPages.openTelegram(model: model) }
                        .fontWeight(.semibold)
                        .disabled(!model.canWrite)
                        .accessibilityIdentifier("messaging.telegram.setup")
                } footer: { HQSectionFooter {
                    Text("Hermes creates the bot and finds your Telegram user ID for you. You confirm it in Telegram.")
                } }
            }
            if model.showsRestartNotice {
                if case .finished(ok: true, _) = model.restart.phase, !model.restartNeeded {
                    Section { GatewayRestartProgress(run: model.restart).padding(.vertical, 6) }
                } else {
                    GatewayRestartNotice(run: model.restart, canWrite: model.canWrite) { model.askRestart() }
                }
            }
            Section {
                if model.readOnly {
                    LabeledContent("On", value: platform.enabled ? "Yes" : "No")
                } else {
                    Toggle("On", isOn: Binding(get: { platform.enabled }, set: { model.setEnabled(platform.id, $0) }))
                        .disabled(!model.canWrite || model.isBusy("platform:\(platform.id)"))
                        .accessibilityIdentifier("messaging.platform.on")
                }
            } footer: { HQSectionFooter {
                if !model.online, !model.readOnly { Text(MorePages.offlineFooter) }
            } }
            Section {
                if platform.envVars.isEmpty {
                    Text(model.readOnly ? "This messaging app has no keys." : "Nothing to paste for this messaging app. Turn it on with the switch above.")
                        .foregroundStyle(Color.hqLabel2)
                        .padding(.vertical, 6)
                } else if platform.keys.isEmpty {
                    Text("Every key of this messaging app is under Advanced.").foregroundStyle(Color.hqLabel2).padding(.vertical, 6)
                }
                ForEach(platform.keys) { key in keyRow(key, platform) }
            } header: { HQSectionLabel { Text("Keys") } }
            if !platform.advancedKeys.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $advancedOpen) {
                        ForEach(platform.advancedKeys) { key in keyRow(key, platform) }
                    } label: {
                        Text("Advanced").foregroundStyle(Color.hqLabel)
                    }
                    .accessibilityIdentifier("messaging.advanced")
                }
            }
            if !model.readOnly {
                Section {
                    Button {
                        model.test(platform.id)
                    } label: {
                        HStack {
                            Text("Test Connection")
                            Spacer()
                            if model.tests[platform.id] == .running { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(!model.online || model.tests[platform.id] == .running)
                    .accessibilityIdentifier("messaging.test")
                    if case .done(let result) = model.tests[platform.id] {
                        Label {
                            Text(result.message).foregroundStyle(result.ok ? Color.green : Color.hqRed)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(result.ok ? Color.green : Color.hqRed)
                        }
                        .font(Font.hq(.subheadline))
                        .padding(.vertical, 6)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("messaging.test.result")
                    }
                }
            }
            people(platform)
            if let guide = platform.guide {
                Section {
                    Button("Setup Guide") { openURL(guide) }
                        .accessibilityIdentifier("messaging.guide")
                }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList()
        .refreshable { await model.refresh() }
        .environment(\.openURL, OpenURLAction { url in .systemAction(url, prefersInApp: true) })
        .accessibilityIdentifier("messaging.platform.list")
    }

    @ViewBuilder
    private func keyRow(_ key: MessagingEnvVar, _ platform: MessagingPlatform) -> some View {
        let value = Text(Self.value(key)).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
        let content = HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(key.label).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                if !key.description.isEmpty {
                    Text(key.description).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // At the largest text sizes the value goes under the words instead of squeezing them.
                if typeSize.isAccessibilitySize { value.fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            if !typeSize.isAccessibilitySize { value.lineLimit(1).layoutPriority(1) }
            if !model.readOnly {
                SettingsChevron()
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        if model.readOnly {
            content.accessibilityElement(children: .combine).accessibilityIdentifier("messaging.key.\(key.key)")
        } else {
            Button { MessagingPages.openKey(key, platform: platform, model: model) } label: { content }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("messaging.key.\(key.key)")
        }
    }

    /// "Set" (with the gateway's redacted preview when it gives one), "Not Set", or "Required".
    static func value(_ key: MessagingEnvVar) -> String {
        guard key.isSet else { return key.required ? "Required" : "Not Set" }
        // A preview that is all dots or stars says nothing: plain "Set".
        guard let preview = EnvKeys.preview(key.redactedValue), preview.contains(where: { $0.isLetter || $0.isNumber }) else { return "Set" }
        return "Set · \(preview)"
    }

    @ViewBuilder
    private func people(_ platform: MessagingPlatform) -> some View {
        let waiting = model.pairing.pending(for: platform.id)
        let approved = model.pairing.approved(for: platform.id)
        Section {
            if waiting.isEmpty, approved.isEmpty {
                Text("No one has asked to message this bot here.").foregroundStyle(Color.hqLabel2).padding(.vertical, 6)
            }
            ForEach(waiting) { person in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(person.name).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                        Text(["Waiting", person.age].compactMap { $0 }.joined(separator: " · "))
                            .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    }
                    Spacer(minLength: 8)
                    if !model.readOnly {
                        Button(model.isBusy("person:\(person.id)") ? "Approving…" : "Approve") { model.approve(person) }
                            .hqRowActionButtonStyle()
                            .disabled(!model.canWrite || model.isBusy("person:\(person.id)"))
                            .accessibilityIdentifier("messaging.approve.\(person.userId)")
                    }
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("messaging.waiting.\(person.userId)")
            }
            ForEach(approved) { person in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(person.name).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                        Text("Approved").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    }
                    Spacer(minLength: 8)
                    if model.isBusy("person:\(person.id)") { ProgressView().controlSize(.small) }
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("messaging.approved.\(person.userId)")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if model.canWrite {
                        // Asks first, so the row stays put until the answer.
                        Button("Remove") { model.askRemove(person) }
                            .tint(.red)
                            .accessibilityIdentifier("messaging.remove.\(person.userId)")
                    }
                }
                .contextMenu {
                    if model.canWrite {
                        Button("Remove", systemImage: "person.fill.xmark", role: .destructive) { model.askRemove(person) }
                    }
                }
            }
        } header: { HQSectionLabel {
            Text("Who Can Message This Bot")
        } } footer: { HQSectionFooter {
            if !approved.isEmpty, model.canWrite { Text(DeviceWord.isMac ? "Control\u{2011}click a person to remove them." : "Swipe a person to remove them.") }
        } }
    }
}
