// Tool setup on the tool page (docs/spec/3x-capabilities.md §4.3): what the tool runs on, its keys, a one-time
// install, a model, and for the terminal its execution backend. Computer Use permissions and the real browser profile
// stay on the gateway computer, each with one plain sentence (DECISION 4-c).

import SwiftUI
import UIKit

struct ToolsetSetupSections: View {
    @Bindable var page: ToolsetPageModel
    let toolset: Toolset
    let router: SettingsRouter
    @Binding var editing: ToolEnvVar?

    var body: some View {
        switch page.setup {
        case .loading:
            Section {
                HStack(spacing: 10) { ProgressView(); Text("Loading setup…").foregroundStyle(Color.hqLabel2) }
            }
        case .absent:
            if !toolset.configured {
                Section {
                    Button("Open Keys") { SettingsNavigator.openRoot("keys", router: router) }.accessibilityIdentifier("toolset-open-keys")
                }
            }
        case .failed:
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Couldn’t load this tool’s setup.").foregroundStyle(Color.hqLabel2)
                    Button("Try Again") { Task { await page.load() } }.hqBorderedButtonStyle()
                }
                .padding(.vertical, 3)
            }
        case .loaded(let config):
            runsOn(config)
            if let provider = page.expandedProvider {
                keys(provider)
                if let key = provider.postSetup { oneTime(provider, key: key) }
                if let models = page.models { modelSection(models, provider: provider) }
            }
        }
        if toolset.name == "terminal" { backends }
        if toolset.name == "vision" {
            // 3x §17.5 g (DECISION R3-d): the web's hint, then the way to the model (the web's link opens its Models
            // settings; here the row opens Auxiliary Models, where Vision is a row). Not shown when this gateway has
            // no vision helper job to set: never a control that does nothing.
            Section {
                if page.hasVisionTask {
                    Button {
                        // [model-scope] Another bot's Vision opens that bot's own Auxiliary Models (it opened the
                        // default bot's, whose pick would not reach this bot); the default bot's stays Settings' page.
                        if BotModelPages.isDefault(page.profile) {
                            SettingsNavigator.openRoot("auxiliary-models", router: router)
                        } else {
                            router.push("Auxiliary Models", AuxiliaryModelsView(router: router, profile: page.profile, botName: page.bot))
                        }
                    } label: {
                        HStack {
                            Text("Choose Vision Model").foregroundStyle(Color.hqLabel)
                            Spacer()
                            SettingsChevron()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("toolset-vision-model")
                }
            } footer: { HQSectionFooter {
                Text("Vision uses your auxiliary model configuration — the image-capable model is picked there, not per-provider here.")
            } }
            .task {
                guard !page.hasVisionTask, let shared = router.gatewaySettings?.settingsAPI else { return }
                // [model-scope] This bot's own helper jobs, as the page the row opens reads them.
                let api = BotModelPages.isDefault(page.profile) ? shared : GatewaySettingsAPI(client: shared.client, profile: page.profile)
                page.hasVisionTask = ((try? await api.auxiliary()) ?? []).contains { $0.task == "vision" }
            }
        }
        if toolset.name == "computer_use" {
            Section {} footer: { HQSectionFooter {
                Text("Computer Use needs permissions granted on the screen of \(HostWord.phrase). Set it up in Hermes there.")
            } }
        }
        if toolset.name == "browser" {
            Section {} footer: { HQSectionFooter {
                Text("To let \(page.bot) browse with your saved logins, turn on Use My Real Browser Profile in Hermes on \(HostWord.phrase).")
            } }
        }
    }

    // MARK: Runs On

    @ViewBuilder private func runsOn(_ config: ToolsetConfig) -> some View {
        if !config.hasCategory {
            Section {} footer: { HQSectionFooter { Text("This toolset has no provider options — enable it and it works with your current setup.") }}
        } else if config.providers.isEmpty {
            Section { Text("No providers are available for this toolset right now.").foregroundStyle(Color.hqLabel2) } header: { HQSectionLabel { Text("Runs On") } }
        } else {
            Section {
                ForEach(config.providers) { provider in
                    providerRow(provider, config: config)
                }
                if let name = page.needsNous {
                    NoticeRow(text: "Sign in with your Nous account. \(name) is saved but will only work once you sign in with your Nous account.",
                              symbol: "person.crop.circle.badge.exclamationmark", tint: .orange, action: "Open Gateway",
                              run: { SettingsNavigator.openRoot("gateway", router: router) })
                }
            } header: { HQSectionLabel {
                Text("Runs On")
            } } footer: { HQSectionFooter {
                if toolset.name == "web" {
                    Text("Search: \(config.searchBackend ?? "not set") · Extract: \(config.extractBackend ?? "not set")")
                        .accessibilityIdentifier("toolset-web-backends")
                }
            } }
        }
    }

    @ViewBuilder private func providerRow(_ provider: ToolProvider, config: ToolsetConfig) -> some View {
        let isWeb = toolset.name == "web"
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if isWeb || provider.isActive { page.expand(provider) } else { page.select(provider) }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(provider.name).font(Font.hq(.body).weight(.semibold)).foregroundStyle(Color.hqLabel)
                            if !provider.badge.isEmpty {
                                Text(provider.badge).font(Font.hq(.caption2).weight(.semibold)).foregroundStyle(Color.hqLabel2)
                                    .padding(.horizontal, 7).padding(.vertical, 2).background(Color.hqFill3, in: Capsule())
                            }
                        }
                        if !provider.tag.isEmpty {
                            Text(provider.tag).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
                        }
                        if let word = provider.statusWord {
                            Text(word).font(Font.hq(.caption)).foregroundStyle(provider.status == "ready" ? Color.hqGreen : Color.hqOrange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if page.selecting == provider.name {
                        ProgressView()
                    } else if !isWeb, provider.isActive {
                        Image(systemName: "checkmark").font(Font.hq(.body).weight(.semibold)).foregroundStyle(Color.hqTint).accessibilityLabel("In use")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(page.readOnly && !isWeb)
            .accessibilityIdentifier("toolset-provider-\(provider.name)")
            if isWeb {
                HStack(spacing: 10) {
                    if provider.capabilities.contains("search") {
                        capability(provider, "search", inUse: config.searchBackend != nil && config.searchBackend == provider.webBackend)
                    }
                    if provider.capabilities.contains("extract") {
                        capability(provider, "extract", inUse: config.extractBackend != nil && config.extractBackend == provider.webBackend)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private func capability(_ provider: ToolProvider, _ kind: String, inUse: Bool) -> some View {
        let word = kind == "search" ? "Search" : "Extract"
        if inUse {
            Label("\(word) backend", systemImage: "checkmark").font(Font.hq(.footnote).weight(.semibold)).foregroundStyle(Color.hqTint)
                .accessibilityIdentifier("toolset-in-\(kind)-\(provider.name)")
        } else if !page.readOnly {
            Button("Use for \(word)") { page.select(provider, capability: kind) }
                .hqRowActionButtonStyle().font(Font.hq(.footnote).weight(.semibold))
                .disabled(page.selecting != nil)
                .accessibilityIdentifier("toolset-use-\(kind)-\(provider.name)")
        }
    }

    // MARK: Keys

    @ViewBuilder private func keys(_ provider: ToolProvider) -> some View {
        Section {
            if provider.envVars.isEmpty {
                Text("No API key required.").foregroundStyle(Color.hqLabel2)
            }
            ForEach(provider.envVars) { variable in
                Button {
                    if !page.readOnly { editing = variable }
                } label: {
                    HStack {
                        Text(variable.prompt).foregroundStyle(Color.hqLabel).frame(maxWidth: .infinity, alignment: .leading)
                        if page.keyBusy == variable.key { ProgressView() }
                        else { Text(variable.isSet ? "Set" : "Not Set").foregroundStyle(variable.isSet ? Color.hqLabel2 : Color.hqOrange) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(page.readOnly)
                .accessibilityIdentifier("toolset-key-\(variable.key)")
                if let link = variable.url, let url = URL(string: link) {
                    Button("Get a Key") { LinkOpener.openOutside(url) }.accessibilityIdentifier("toolset-get-key-\(variable.key)")
                }
            }
        } header: { HQSectionLabel {
            Text(provider.envVars.isEmpty ? "Keys" : "Keys for \(provider.name)")
        } }
    }

    // MARK: One-time install

    @ViewBuilder private func oneTime(_ provider: ToolProvider, key: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                switch page.install {
                case .done:
                    Text("Setup complete. \(key) installed.").foregroundStyle(Color.hqLabel).accessibilityIdentifier("toolset-setup-done")
                case .failed:
                    Text("Setup finished with errors. Setting up \(key) did not finish. Run it again, or check \(HostWord.phrase).")
                        .foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("toolset-setup-failed")
                default:
                    Text(provider.status == "ready" ? "Installed. Run setup again only if something is broken."
                         : "This backend needs a one-time install (\(key)). It runs on \(HostWord.phrase) and may take a few minutes.")
                        .foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
                }
                if case .running(let line) = page.install {
                    HStack(spacing: 10) { ProgressView(); Text("Installing…").foregroundStyle(Color.hqLabel2) }
                    if !line.isEmpty { Text(line).font(Font.hq(.caption).monospaced()).foregroundStyle(Color.hqLabel2).lineLimit(1) }
                } else if !page.readOnly {
                    Button(page.install == .failed ? "Run Again" : (provider.status == "ready" || page.install == .done ? "Run Setup Again" : "Run Setup")) {
                        page.runSetup(key)
                    }
                    .hqBorderedButtonStyle()
                    .accessibilityIdentifier("toolset-post-setup")
                }
            }
            .padding(.vertical, 3)
        } header: { HQSectionLabel { Text("One-Time Install") } }
    }

    // MARK: Model

    @ViewBuilder private func modelSection(_ models: ToolModels, provider: ToolProvider) -> some View {
        Section {
            ForEach(models.models) { model in
                Button { page.setModel(model) } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.id == models.fallback ? "\(model.display) · default" : model.display).foregroundStyle(Color.hqLabel)
                            if !model.caption.isEmpty { Text(model.caption).font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if page.settingModel == model.id { ProgressView() }
                        else if models.current == model.id {
                            Image(systemName: "checkmark").font(Font.hq(.body).weight(.semibold)).foregroundStyle(Color.hqTint).accessibilityLabel("In use")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!provider.isActive || page.readOnly)
                .accessibilityIdentifier("toolset-model-\(model.id)")
            }
        } header: { HQSectionLabel {
            Text("Model · \(CapabilitiesModel.plural(models.models.count, "model", "models"))")
        } } footer: { HQSectionFooter {
            if !provider.isActive { Text("Select this backend first to change its model.") }
            // [model-scope] Owner 2026-11-03: whose it is (`setToolModel(profile:)`); the page's footer says new chats.
            else { Text(SettingsWords.toolModelScope(bot: page.bot)).accessibilityIdentifier("toolset-model-scope") }
        } }
    }

    // MARK: Terminal

    @ViewBuilder private var backends: some View {
        if let list = page.backends {
            let active = list.first(where: \.active)
            Section {
                ForEach(list) { backend in
                    Button { page.pick(backend) } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(backend.label).font(Font.hq(.body).weight(.semibold)).foregroundStyle(Color.hqLabel)
                                if !backend.description.isEmpty {
                                    Text(backend.description).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
                                }
                                Text(backend.isReady ? "Ready" : backend.status == "unavailable" ? "Unavailable" : "Needs setup")
                                    .font(Font.hq(.caption)).foregroundStyle(backend.isReady ? Color.hqGreen : backend.status == "unavailable" ? Color.hqRed : Color.hqOrange)
                                if !backend.isReady, !backend.detail.isEmpty {
                                    Text(backend.detail).font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if page.settingBackend == backend.name { ProgressView() }
                            else if backend.active {
                                Image(systemName: "checkmark").font(Font.hq(.body).weight(.semibold)).foregroundStyle(Color.hqTint).accessibilityLabel("In use")
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(page.readOnly)
                    .accessibilityIdentifier("terminal-backend-\(backend.name)")
                }
                if let active, !active.isReady, active.name != "local", !page.readOnly, let local = list.first(where: { $0.name == "local" }) {
                    Button("Use Local") { page.setBackend(local) }.accessibilityIdentifier("terminal-use-local")
                }
            } header: { HQSectionLabel {
                Text("Execution Backend")
            } } footer: { HQSectionFooter {
                if let active, !active.isReady {
                    Text("This backend is currently selected without full setup — commands will fail until setup is complete.").foregroundStyle(.red)
                }
            } }
        } else if page.backendsFailed {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Couldn’t load terminal backends").foregroundStyle(Color.hqLabel2)
                    Button("Try Again") { Task { await page.loadBackends() } }.hqBorderedButtonStyle()
                }
            } header: { HQSectionLabel { Text("Execution Backend") } }
        }
    }
}
