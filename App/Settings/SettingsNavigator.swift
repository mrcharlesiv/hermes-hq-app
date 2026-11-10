// Where each Settings row and search result goes, and the file actions (`src/settings-config-file.ts`):
// Export Settings… (the record with credentials left out, shared as "<Profile> settings <day>.json"), Import Settings…
// (a picked file; only what it changes is written, placeholders keep the gateway's values, emptying Enabled Toolsets
// asks first) and Reset to Defaults… (Hermes' defaults written over the record, after a confirm).

import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
enum SettingsNavigator {
    static func open(_ target: SettingsSearchEntry.Target, router: SettingsRouter, actions: SettingsFileActions) {
        switch target {
        case .root(let id): openRoot(id, router: router)
        case .page(let key): if let page = ConfigCatalog.page(key) { ConfigScreens.open(page: page, router: router) }
        case .field(let pageKey, let key):
            guard let page = ConfigCatalog.page(pageKey), let pageController = ConfigScreens.makePage(page, router: router) else { return }
            var controllers = [pageController]
            // [mac] Only the setting's page, scrolled to its row and marked, not a page holding only the setting over it
            // (Mac polish #39).
            if DeviceWord.isMac, !ConfigCatalog.customPages.contains(pageKey) { ConfigFieldReveal.shared.pending = key }
            if !DeviceWord.isMac, !ConfigCatalog.customPages.contains(pageKey), let store = router.gatewaySettings?.configStore,
               store.field(key)?.control != .toggle,
               let editor = ConfigScreens.makeField(key, store: store, router: router) {
                controllers.append(editor)
            }
            router.push(controllers)
        case .action(let id):
            switch id {
            case "export": actions.export()
            case "import": actions.pickImport()
            case "clear-models": actions.confirmClearModels()
            default: actions.confirmReset()
            }
        }
    }

    static func openRoot(_ id: String, router: SettingsRouter) {
        let services = router.services
        if id.hasPrefix("config:"), let section = ConfigCatalog.section(String(id.dropFirst("config:".count))) {
            ConfigScreens.open(section: section, router: router)
            return
        }
        switch id {
        case "gateway": router.push(GatewayPageController(services: services, router: router))
        case "notifications": router.push(NotificationsSettingsController(app: services as? AppModel))
        case "providers": router.push("Providers", ProvidersPageView(router: router))
        case "keys": router.push("Keys", KeysPageView(router: router))
        case "vault": router.push("Passwords & Logins", VaultPageView(router: router))
        case "billing": router.push("Billing", BillingPageView(router: router))
        case "sessions":
            guard let store = router.gatewaySettings?.configStore else { return }
            router.push(SettingsSearch.sessionsPageTitle, SessionsSettingsView(store: store, router: router))
        // [cap-pages] Capabilities, and each of its lists over it (Back goes to the four rows).
        case "capabilities": router.push(CapabilitiesHubController(services: services, settingsPage: true))
        case "skills", "connectors", "tools", "plugins":
            if let tab = CapabilitiesTab(rawValue: id) { router.push(CapabilitiesPages.pages(tab, services: services, settingsPage: true)) }
        case "auxiliary-models":   // [capabilities] 3x §17.5 g
            // Stress test 2026-10-28 #81, round 2 (both): Auxiliary Models has one home, Settings › Model › Auxiliary
            // Models. A link to it (Tools › Vision) opens it there, Model under it, so Back goes to Model, not the root.
            if let section = ConfigCatalog.section("model"), let page = ConfigCatalog.page("model.auxiliary"),
               let store = router.gatewaySettings?.configStore, let navigation = router.navigation,
               let auxiliary = ConfigScreens.makePage(page, router: router) {
                let model = SettingsPageController(title: section.title, ConfigSectionView(section: section, store: store, router: router))
                for page in [model, auxiliary] { page.navigationItem.largeTitleDisplayMode = .never }
                navigation.setViewControllers(navigation.viewControllers + [model, auxiliary], animated: true)
            } else {
                router.push("Auxiliary Models", AuxiliaryModelsView(router: router))
            }
        case "theme": router.push(ThemeSettingsController(services: services))   // [desktoplook]
        // [theme-pages] Pages of their own beside Theme (they were its tabs); a background's search result opens its
        // page over Backgrounds.
        case "chat-bubbles": router.push(ChatBubblesSettings.make())
        case "backgrounds": router.push(BackgroundsSettings.make())
        case "background:app": router.push(BackgroundsSettings.make(opening: .app))
        case "background:chats": router.push(BackgroundsSettings.make(opening: .chats))
        case "about": router.push(AboutController(services: services, router: router))
        case "diagnostics": router.push("Diagnostics", DiagnosticsView(services: services, router: router))
        case "tool-calls": if let screen = SettingsHooks.toolCallsScreen { router.push(screen()) }
        case "sound-picker": router.push("Sound", CompletionSoundPicker())
        case "attachment-limit":   // [settings]
            // [mac] Stress test 2026-10-28 #81, round 2: on the Mac it is a row of Chat Behavior › Attachments.
            if DeviceWord.isMac, router.gatewaySettings?.configStore != nil, let chat = ConfigCatalog.section("chat") {
                ConfigScreens.open(section: chat, router: router)
            } else {
                router.push("Largest Attachment", AttachmentLimitPage { _ in })
            }
        case "tab-order": router.push(SettingsWords.tabsPageTitle(), TabOrderPage(account: services.account))   // [taborder] Mac polish #131
        // [kanban-tab-one] The Kanban Tab picker's search result: Tabs, scrolled to the picker and marked.
        case SettingsSearch.kanbanTabTarget: router.push(SettingsWords.tabsPageTitle(), TabOrderPage(account: services.account, revealKanban: true))
        case "app-icon": router.push("App Icon", AppIconPage())   // [app-icons]
        default: break   // rows on the root itself ("row:…"): the root's list scrolls to them (SettingsRootView.open)
        }
    }
}

/// Export / Import / Reset, presented from the Settings stack.
@MainActor
final class SettingsFileActions: NSObject, UIDocumentPickerDelegate {
    let router: SettingsRouter
    /// Says how an action went (the root shows it under the actions).
    var onStatus: ((String?) -> Void)?

    init(router: SettingsRouter) { self.router = router }

    private var store: GatewayConfigStore? { router.gatewaySettings?.configStore }

    private var profileName: String { "Hermes" }

    func export() {
        guard let store else { return }
        onStatus?(nil)
        Task {
            do {
                let record = try await store.fresh()
                let data = try SettingsFile.fileData(record)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(SettingsFile.exportFileName(profile: profileName))
                try data.write(to: url, options: .atomic)
                AppLog.note("settings", "settings exported")
                let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                if let presenter = router.presenter {
                    sheet.popoverPresentationController?.sourceView = presenter.view
                    presenter.present(sheet, animated: true)
                }
            } catch {
                AppLog.note("settings", "export failed: \(type(of: error))")
                FailureAlert.present(title: "Couldn’t Export Settings", reason: SettingsErrorText.load(error), from: router.presenter)
            }
        }
    }

    func pickImport() {
        onStatus?(nil)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        router.presenter?.present(picker, animated: true)
    }

    nonisolated func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let data = try? Data(contentsOf: url)
        MainActor.assumeIsolated { importFile(data) }
    }

    func importFile(_ data: Data?) {
        guard let store else { return }
        guard let data, let file = try? JSONValue.parse(data), file.object != nil else {
            FailureAlert.present(title: "Couldn’t Import Settings", reason: "That file isn’t a Hermes settings file.", from: router.presenter)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let current = try await store.fresh()
                let next = SettingsFile.keepSecrets(file, current: current) ?? .object([:])
                let patch = ConfigPath.diff(current, next)
                let changes = SettingsImportWords.changeCount(patch)
                if ConfigPath.clearsEnabledToolsets(current, next) {
                    TextPrompt.confirm(title: "Remove All Tool Groups?",
                                       message: "This file turns off memory, terminal, web search, subagents and most other tools.",
                                       action: "Import Anyway", from: router.presenter) { [weak self] in self?.applyImport(patch, store: store) }
                } else if changes == 0 {
                    onStatus?(SettingsImportWords.unchanged)
                    HQAnnounce.say(SettingsImportWords.unchanged)
                } else {
                    // Says how much changes before anything is written.
                    TextPrompt.confirm(title: SettingsImportWords.confirmTitle, message: SettingsImportWords.confirmMessage(changes: changes),
                                       action: SettingsImportWords.confirmAction, from: router.presenter) { [weak self] in
                        self?.applyImport(patch, store: store)
                    }
                }
            } catch {
                AppLog.note("settings", "import read failed: \(type(of: error))")
                FailureAlert.present(title: "Couldn’t Import Settings", reason: SettingsErrorText.load(error), from: router.presenter)
            }
        }
    }

    private func applyImport(_ patch: JSONValue, store: GatewayConfigStore) {
        Task {
            do {
                try await store.write(patch)
                Haptics.play(.success)
                AppLog.note("settings", "settings imported")
                let changes = SettingsImportWords.changeCount(patch)
                let words = SettingsImportWords.done(changes: changes)
                onStatus?(words)
                // The footer line alone was easy to miss: a HUD (which VoiceOver reads) says it too.
                if changes > 0, let presenter = router.presenter {
                    PagesHUD.show(SettingsImportWords.doneTitle, detail: "\(SettingsImportWords.settings(changes)) changed.",
                                  symbol: "checkmark.circle", from: presenter)
                }
            } catch {
                AppLog.note("settings", "import apply failed: \(type(of: error))")
                FailureAlert.present(title: "Couldn’t Import Settings", reason: SettingsErrorText.save(error), from: router.presenter)
            }
        }
    }

    /// [stale-stars] Tester 2026-11-09: a provider removed from the bot leaves its starred models in Switch Model
    /// with no list to unstar them from ("A nice little reset button for favorites and recently used ... above the reset to
    /// defaults button"). Clears this account's stars and recents, which live on this device, not on the gateway.
    func confirmClearModels() {
        guard let account = router.services.account else { return }
        onStatus?(nil)
        let prefs = ModelPrefs(accountId: account.id)
        let words = SettingsWords.clearModelsMessage(favorites: prefs.favorites.count, recents: prefs.recents.count)
        TextPrompt.confirm(title: "Clear Favorite & Recent Models?", message: words,
                           action: "Clear", from: router.presenter) { [weak self] in
            prefs.clearFavoritesAndRecents()
            Haptics.play(.success)
            AppLog.note("settings", "model favourites and recents cleared")
            self?.onStatus?("Favorite and recent models cleared.")
        }
    }

    func confirmReset() {
        guard !resetting else { return }
        onStatus?(nil)
        TextPrompt.confirm(title: "Reset All Settings to Defaults?",
                           message: "Every setting on \(HostWord.phrase) goes back to its Hermes default. Keys, bots and chats stay. Export Settings… first to keep a copy.",
                           action: "Reset to Defaults", from: router.presenter) { [weak self] in self?.reset() }
    }

    /// UX study 2026-10-21 #209: while the reset's two gateway calls run, the row says so and can't be tapped again.
    private(set) var resetting = false { didSet { onResetting?(resetting) } }
    var onResetting: ((Bool) -> Void)?

    private func reset() {
        guard let store, !resetting else { return }
        resetting = true
        onStatus?("Resetting…")
        Task {
            defer { resetting = false }
            do {
                let defaults = try await store.api.defaults()
                try await store.write(defaults)
                Haptics.play(.success)
                AppLog.note("settings", "settings reset")
                onStatus?("Settings reset to Hermes defaults.")
            } catch {
                AppLog.note("settings", "settings reset failed: \(type(of: error))")
                onStatus?(nil)
                FailureAlert.present(title: "Couldn’t Reset Settings", reason: SettingsErrorText.save(error), from: router.presenter)
            }
        }
    }
}

// MARK: - Sounds › Sound

struct CompletionSoundPicker: View {
    @State private var selected = CompletionCue.variant

    var body: some View {
        List { Group {
            Section {
                ForEach(CompletionSoundVariant.presets) { preset in
                    Button {
                        Haptics.play(.selection)
                        selected = preset.id
                        CompletionCue.variant = preset.id
                        CompletionCue.preview(preset.id)
                    } label: {
                        // [mac] Stress test 2026-10-28 #51: a radio group on the Mac.
                        HQOptionRowLabel(title: preset.name, selected: selected == preset.id)
                    }
                    .accessibilityAddTraits(selected == preset.id ? .isSelected : [])
                    .accessibilityIdentifier("sound.\(preset.id)")
                    .hqRadioRow()   // [mac] Stress test 2026-10-28 #51 (round 6)
                    .overlay(alignment: .trailing) {
                        if DeviceWord.isMac {
                            // [mac] #51: the footer says "Click one to hear it"; a play button hears one without
                            // choosing it.
                            Button {
                                CompletionCue.preview(preset.id)
                            } label: {
                                Image(systemName: "play.circle")
                                    .font(MacIcon.rowFont)
                                    .foregroundStyle(Color.hqLabel2)
                                    .frame(width: MacIcon.rowColumn, height: MacIcon.rowColumn)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .help("Play \(preset.name)")
                            .accessibilityLabel("Play \(preset.name)")
                            .accessibilityIdentifier("sound.\(preset.id).play")
                        }
                    }
                }
            } footer: { HQSectionFooter {
                Text(DeviceWord.isMac ? "Plays when a bot’s reply finishes. Click one to choose and hear it, or its play button only to hear it."
                     : "Plays when a bot’s reply finishes. \(DeviceWord.Tap) one to hear it.")
            } }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
    }
}

/// [settings] Settings › Largest Attachment (docs/spec/3x-settings.md §4): 1…100 MB with a stepper (it cannot hold a
/// value out of range and needs no keyboard), and Use Default once it is not 100.
struct AttachmentLimitPage: View {
    var changed: (Int) -> Void
    @State private var megabytes = AttachmentLimit.megabytes

    var body: some View {
        List { Group {
            Section {
                Stepper(value: $megabytes, in: AttachmentLimit.range) {
                    HStack {
                        Text("Size").foregroundStyle(Color.hqLabel)
                        Spacer(minLength: 12)
                        Text("\(megabytes) MB").foregroundStyle(Color.hqLabel2).monospacedDigit()
                            .accessibilityIdentifier("attachment-limit.value")
                    }
                }
                .hqRowPadding(4)   // [mac] Stress test 2026-10-28 round 9: the list's one room on the Mac
                .accessibilityIdentifier("attachment-limit.stepper")
                if megabytes != AttachmentLimit.defaultMB {
                    Button("Use Default") {
                        Haptics.play(.selection)
                        megabytes = AttachmentLimit.defaultMB
                    }
                    .accessibilityIdentifier("attachment-limit.default")
                }
            } footer: { HQSectionFooter {
                Text(AttachmentLimit.footer())
            } }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .onChange(of: megabytes) { _, value in
            AttachmentLimit.megabytes = value
            changed(value)
        }
    }
}
