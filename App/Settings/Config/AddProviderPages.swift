// [provider-add] Owner 2026-11-04: "i need to be able to more easily add them adn i need to remove them" (Settings ›
// Providers). Add Provider: one page that lists what can be added, opened from the Providers page's +, Your Providers'
// Add Provider… row, and the model list's Add Provider… (iPhone sheet and Mac pop-over). A pick opens the page that
// adds it, in the chooser's place, so saving lands back on Providers:
//   - Popular / On Your Network: presets (`ProviderPreset`) that fill in a new Your Providers entry's name and address,
//     or open Hermes' own key when the gateway has one for that service (OpenRouter, DeepSeek, Fireworks);
//   - Other: the empty Your Providers form, for any OpenAI-compatible service;
//   - Built Into Hermes: every provider the gateway lists a key for (the API Keys cards), opening that key's page.
// Removing is on the Providers page itself: swipe a row, or touch and hold / Control-click it.

import SwiftUI
import UIKit

struct AddProviderChooser: View {
    let env: EnvKeysModel
    let custom: CustomProvidersModel
    let router: SettingsRouter

    var body: some View {
        // Read here, not only inside the rows: a list row's own reads didn't redraw "Added" once the keys came in.
        let vars = env.vars
        let mine = custom.providers
        List { Group {
            Section {
                ForEach(ProviderPreset.online) { presetRow($0, vars: vars, mine: mine) }
            } header: { HQSectionLabel {
                Text("Popular")
            } } footer: { HQSectionFooter {
                Text(sentence("Fills in the name and address; you paste your key"))
            } }
            Section {
                ForEach(ProviderPreset.local) { presetRow($0, vars: vars, mine: mine) }
            } header: { HQSectionLabel {
                Text("On Your Network")
            } } footer: { HQSectionFooter {
                Text(sentence("127.0.0.1 is the computer Hermes runs on. If the model server is on another computer, change the address to that computer’s"))
            } }
            Section {
                choiceRow(title: "Other Service…", detail: "Any OpenAI-compatible address", added: false, id: "add-provider.other") {
                    open(.custom(CustomProviderDraft()), title: "New Provider")
                }
            } footer: { HQSectionFooter {
                Text(sentence("A company proxy, a self-hosted server or any service that speaks the OpenAI API"))
            } }
            builtInSection
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .task {
            // Opened from the model list, the Providers page under it may not have read the keys yet. Opened just as
            // Providers appeared, its read was cut off when this page covered it (a page's task ends when it
            // disappears) and "Added" and Built Into Hermes never filled in (Mac, 2026-11-04): read again once if so.
            for attempt in 0..<2 where !env.loaded || !custom.loaded {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(400)) }
                if !env.loaded { await env.load() }
                if !custom.loaded { await custom.load() }
            }
        }
        .accessibilityIdentifier("add-provider.page")
    }

    @ViewBuilder private var builtInSection: some View {
        if let error = env.loadError, !env.loaded {
            LoadFailureSection(title: "Couldn’t Load Hermes’s Providers", text: error) { Task { await env.load() } }
        } else if !env.loaded {
            LoadingSection()
        } else {
            let builtIns = ProviderAdding.builtIns(env.vars)
            if !builtIns.isEmpty {
                Section {
                    ForEach(builtIns) { choice in
                        choiceRow(title: choice.name, detail: choice.detail, added: choice.key.isSet, id: "add-provider.builtin.\(choice.key.key)") {
                            open(.key(choice.key), title: choice.name)
                        }
                    }
                } header: { HQSectionLabel {
                    Text("Built Into Hermes")
                } } footer: { HQSectionFooter {
                    Text(sentence("Hermes knows these services’ models already. Paste the key from your account with them"))
                } }
            }
        }
    }

    private func presetRow(_ preset: ProviderPreset, vars: [EnvVarInfo], mine: [CustomProvider]) -> some View {
        let route = ProviderAdding.route(preset, vars: vars)
        return choiceRow(title: preset.name, detail: preset.detail,
                         added: ProviderAdding.isAdded(preset, vars: vars, custom: mine),
                         id: "add-provider.preset.\(preset.id)") {
            open(route, title: preset.name)
        }
    }

    private func choiceRow(title: String, detail: String?, added: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.play(.selection)
            action()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if added {
                    // Already there: the pick still opens it (to change the key or add a second one).
                    Text("Added").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                }
                SettingsChevron()
            }
            .hqRowPadding(4)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    private func sentence(_ text: String) -> String { DeviceWord.isMac ? ConfigUnits.sentence(text) : text + "." }

    /// The page that adds it, in the chooser's place: Back (or saving) goes to Providers, not back here.
    private func open(_ route: ProviderAddRoute, title: String) {
        AppLog.note("settings", "add provider: \(route.logWord)")
        let page: UIViewController
        switch route {
        case .key(let info):
            let label = EnvKeys.title(info) == info.key ? title : EnvKeys.title(info)
            page = SettingsPageController(title: title, EnvKeyEditor(key: info.key, label: label, model: env))
        case .custom(let draft):
            page = SettingsPageController(title: title, CustomProviderEditor(model: custom, router: router, original: draft))
        }
        ProviderAdd.replaceChooser(with: page, router: router)
    }
}

private extension ProviderAddRoute {
    /// What the log says (never a key's value).
    var logWord: String {
        switch self {
        case .key(let info): "key \(info.key)"
        case .custom(let draft): draft.name.isEmpty ? "other" : "preset"
        }
    }
}

@MainActor enum ProviderAdd {
    static let title = "Add Provider"

    /// The chooser, pushed over the Providers page.
    static func openChooser(env: EnvKeysModel, custom: CustomProvidersModel, router: SettingsRouter) {
        // Never two choosers stacked (the page asked twice, from its first appearance and the model list).
        guard router.navigation?.topViewController?.title != title else { return }
        router.push(title, AddProviderChooser(env: env, custom: custom, router: router))
    }

    static func replaceChooser(with page: UIViewController, router: SettingsRouter) {
        guard let navigation = router.navigation else { return }
        page.navigationItem.largeTitleDisplayMode = .never
        var stack = navigation.viewControllers
        if stack.last?.title == title { stack.removeLast() }
        navigation.setViewControllers(stack + [page], animated: true)
    }

    /// The model list's Add Provider…: Settings › Providers with the chooser open over it. The Settings window on the
    /// Mac, a sheet over the chat on the iPhone.
    static func openFromChat(from presenter: UIViewController) {
        AppLog.note("settings", "add provider: from the model list")
        let push: (SettingsRouter) -> Void = { router in
            router.push("Providers", ProvidersPageView(router: router, startAdding: true))
        }
        #if targetEnvironment(macCatalyst)
        if MacSettingsWindow.open(category: .gateway, then: push) { return }
        #endif
        guard let services = MainTabController.current?.services else { return }
        var top = presenter
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        SettingsScreens.presentSettings(from: top, services: services) { navigation in
            guard let root = navigation.viewControllers.first as? SettingsRootController else { return }
            push(root.router)
        }
    }
}
