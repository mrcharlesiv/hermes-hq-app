// [context-window] Context Window (owner 2026-11-01: "If I have to ask you, then I'm sure others may not ever even find
// it"): one bot's window as Automatic (the model's own) or a size, and a way on to when Hermes compresses. Settings ›
// Model › Context Window is the default bot's (Settings' own store); Bot Info › Brain, More › Bot Profiles and the model
// panel's Context fact open the chat's bot's (`?profile=`). The rules are `ContextWindow`'s.

import SwiftUI
import UIKit

struct ContextWindowView: View {
    let store: GatewayConfigStore
    let router: SettingsRouter
    /// A bot's own (`store` reads its `?profile=`); nil: the default bot's, Settings' own.
    var botName: String? = nil
    /// The bot's default model as Hermes names it, and that model's own window (`GET /api/model/info`).
    @State private var modelName: String?
    @State private var own: Int?
    @State private var customText = ""
    @State private var problem: String?
    /// The typed size, all chosen as the field is entered, so typing replaces it (a tap left of right-aligned text puts
    /// the caret before it: "300K" after a refused "32K" read "300K32K").
    @State private var chosen: TextSelection?
    @FocusState private var typing: Bool

    private var current: Int? { ContextWindow.override(store.value(ContextWindow.key)) }
    private var sizes: [Int] { ContextWindow.sizes(below: own) }
    /// A size that isn't one of the offered ones: the Custom row holds it.
    private var custom: Int? { current.flatMap { sizes.contains($0) ? nil : $0 } }
    private var whose: String { botName ?? router.services.bots.first { $0.id == "default" }?.name ?? "Hermes" }

    var body: some View {
        List { Group {
            ConfigFailureSection(store: store)
            if store.config == nil {
                LoadingSection(text: "Loading settings…")
            } else {
                Section {
                    choice("Automatic", detail: own.map { "\(ContextWindow.label($0)), the model’s own" } ?? "The model’s own size",
                           selected: current == nil, id: "automatic") { set(nil) }
                    if gridded {
                        sizeGrid
                    } else {
                        ForEach(sizes, id: \.self) { size in
                            choice(ContextWindow.label(size), detail: nil, selected: current == size, id: String(size)) { set(size) }
                        }
                    }
                    customRow
                } header: { HQSectionLabel {
                    Text(modelName.map { "\(whose)’s Default Model, \($0)" } ?? "\(whose)’s Default Model")
                } } footer: { HQSectionFooter {
                    VStack(alignment: .leading, spacing: 6) {
                        if let problem { Text(problem).foregroundStyle(Color.hqRed).accessibilityIdentifier("context-window.problem") }
                        else if let caution = ContextWindow.caution(current, own: own) {
                            Text(caution).foregroundStyle(Color.hqOrange).accessibilityIdentifier("context-window.caution")
                        }
                        Text("How much of a chat the model reads at once. A smaller window costs less per message, as Hermes sums up older messages sooner. Hermes needs at least \(ContextWindow.label(ContextWindow.minimum)).")
                        Text("A chat on another model uses that model’s own. New chats use the size you pick.")
                    }
                } }
                Section {
                    ValueRow(title: "Compression", value: compressionSummary) { openCompression() }
                        .accessibilityIdentifier("context-window.compression")
                } footer: { HQSectionFooter {
                    Text("When a chat nears its window, Hermes sums up its older messages to make room.")
                } }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .saveFailureFeedback(store.failure?.text)
        .task {
            await store.load()
            await loadModel()
        }
        .refreshable {
            await store.load(force: true)
            await loadModel()
        }
        .onAppear { customText = custom.map(ContextWindow.label) ?? "" }
        .onChange(of: store.epoch) { _, _ in customText = custom.map(ContextWindow.label) ?? "" }
        .accessibilityIdentifier("context-window.list")
    }

    /// [context-grid] Owner 2026-11-10 (design pick 11): on the iPhone and iPad the sizes are a grid of buttons in one
    /// row of the list (three across), so Automatic, the sizes, Custom and the explanation fit on one screen; five
    /// full-width rows pushed the explanation under the fold. The Mac keeps its radio list, and the accessibility text
    /// sizes keep the rows (a size's words need the row's width there).
    @Environment(\.dynamicTypeSize) private var typeSize
    private var gridded: Bool { !DeviceWord.isMac && !typeSize.isAccessibilitySize && !sizes.isEmpty }

    private var sizeGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(sizes, id: \.self) { size in
                let selected = current == size
                Button {
                    typing = false
                    set(size)
                } label: {
                    Text(ContextWindow.label(size))
                        .font(Font.hq(.callout).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(selected ? Color.hqTintText : Color.hqLabel)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(RoundedRectangle(cornerRadius: HQShape.radius(12, .card), style: .continuous)
                            .fill(selected ? Color.hqTint.opacity(0.16) : Color.hqFill3))
                        .overlay(RoundedRectangle(cornerRadius: HQShape.radius(12, .card), style: .continuous)
                            .strokeBorder(selected ? Color.hqTint : Color.clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(store.readOnly)
                .accessibilityLabel(ContextWindow.label(size))
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("context-window.\(size)")
            }
        }
        .padding(.vertical, 4)
    }

    /// One size: on the Mac a radio leads it, elsewhere a ✓ ends it (as every Settings choice list).
    private func choice(_ title: String, detail: String?, selected: Bool, id: String, pick: @escaping () -> Void) -> some View {
        Button {
            typing = false
            pick()
        } label: {
            HStack(alignment: DeviceWord.isMac ? .firstTextBaseline : .center, spacing: DeviceWord.isMac ? MacForm.radioGap : 12) {
                HQRadioMark(selected: selected)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundStyle(Color.hqLabel)
                        .font(Font.hq(.body))
                    if let detail {
                        Text(detail).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                HQCheckMark(selected: selected)
            }
            .hqRowPadding(detail == nil ? 0 : 4)
            .frame(minHeight: DeviceWord.isMac ? nil : 44)
            .contentShape(Rectangle())
        }
        .modifier(OneLineRadio(oneLine: detail == nil))
        .hqRadioRow()
        .disabled(store.readOnly)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint(detail ?? "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("context-window.\(id)")
    }

    /// Any other size, typed ("300K", "300,000"); saved on Return or when the field is left.
    private var customRow: some View {
        HStack(alignment: .center, spacing: DeviceWord.isMac ? MacForm.radioGap : 12) {
            HQRadioMark(selected: custom != nil)
            Text("Custom").foregroundStyle(Color.hqLabel)
                .font(Font.hq(.body))
                .fixedSize()
            Spacer(minLength: 8)
            TextField("Size", text: $customText, selection: $chosen, prompt: Text("e.g. 300K"))
                .multilineTextAlignment(DeviceWord.isMac ? .leading : .trailing)
                .monospacedDigit()
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($typing)
                .onSubmit(saveCustom)
                .modifier(MacNumberBox())
                .disabled(store.readOnly)
                .accessibilityLabel("Custom size")
                .accessibilityIdentifier("context-window.custom")
            HQCheckMark(selected: custom != nil)
        }
        .frame(minHeight: DeviceWord.isMac ? nil : 44)
        .hqRadioRow()
        .onChange(of: typing) { _, now in
            guard now else { return saveCustom() }
            // After the tap has placed its caret.
            DispatchQueue.main.async { chosen = TextSelection(range: customText.startIndex..<customText.endIndex) }
        }
    }

    private func set(_ tokens: Int?) {
        guard tokens != current else { return }
        Haptics.play(.selection)
        problem = nil
        store.set(ContextWindow.key, .number(Double(tokens ?? 0)))
        customText = tokens.flatMap { sizes.contains($0) ? nil : ContextWindow.label($0) } ?? ""
    }

    private func saveCustom() {
        let typed = customText.trimmingCharacters(in: .whitespaces)
        // Emptied: what's set stays (a size is picked above, not by clearing the field).
        guard !typed.isEmpty else { problem = nil; customText = custom.map(ContextWindow.label) ?? ""; return }
        if let why = ContextWindow.problem(typed) { problem = why; return }
        guard let tokens = ContextWindow.parse(typed) else { return }
        set(tokens)
        customText = sizes.contains(tokens) ? "" : ContextWindow.label(tokens)
    }

    /// "At 50%" (of the window), "Off", or nothing while it isn't known.
    private var compressionSummary: String? {
        if store.value("compression.enabled")?.bool == false { return "Off" }
        guard let share = store.value("compression.threshold")?.double, share > 0, share <= 1 else { return nil }
        return "At \(Int((share * 100).rounded()))%"
    }

    private func openCompression() {
        guard let page = ConfigCatalog.page("memory.context") else { return }
        router.push(page.title, ConfigPageView(page: page, store: store, router: router), onDisappear: { [store] in store.flush() })
    }

    private func loadModel() async {
        guard let info = try? await store.api.modelInfo() else { return }
        if let id = info["model"]?.string, !id.isEmpty { modelName = ModelNames.modelDisplayParts(id).name }
        if let auto = info["auto_context_length"]?.double, auto > 0 { own = Int(auto) } else { own = nil }
    }
}

/// [mac] A one-line choice is the form's one-line row, as Tool Calls' are; one with a line under it keeps the list's room.
private struct OneLineRadio: ViewModifier {
    var oneLine: Bool
    func body(content: Content) -> some View {
        if oneLine { content.hqMacFormRowHeight() } else { content }
    }
}

/// [mac] The custom size in the form's number box; elsewhere the plain field at the row's end.
private struct MacNumberBox: ViewModifier {
    func body(content: Content) -> some View {
        if DeviceWord.isMac {
            content.hqMacFieldBox().frame(width: MacForm.numberWidth)
        } else {
            content
        }
    }
}

// MARK: - Opening it for a bot

extension BotModelPages {
    /// The bot's own config (`?profile=`), the default bot's on Settings' shared store (so both show a change).
    static func contextWindowStore(for bot: Bot, services: any AppServices) -> GatewayConfigStore? {
        guard let settings = services as? GatewaySettingsServices, let api = settings.settingsAPI else { return nil }
        return isDefault(bot.id) ? settings.configStore
            : GatewayConfigStore(api: GatewaySettingsAPI(client: api.client, profile: bot.id), readOnly: settings.isReadOnlyGateway)
    }

    /// Bot Info › Brain and More › Bot Profiles: pushed on their stack (on `store` when the row already read it).
    static func openContextWindow(_ bot: Bot, services: any AppServices, store: GatewayConfigStore? = nil,
                                  on navigation: UINavigationController?) {
        guard let navigation, let store = store ?? contextWindowStore(for: bot, services: services) else { return }
        Haptics.play(.selection)
        let router = SettingsRouter(services: services, navigation: navigation)
        let page = SettingsPageController(title: "Context Window",
                                          ContextWindowView(store: store, router: router, botName: isDefault(bot.id) ? nil : bot.name))
        page.onDisappear = { store.flush() }
        router.push(page)
    }

    /// The model panel's Context fact: a sheet over the chat, with its own stack for Compression.
    static func contextWindowSheet(_ bot: Bot, services: any AppServices) -> UINavigationController? {
        guard let store = contextWindowStore(for: bot, services: services) else { return nil }
        let router = SettingsRouter(services: services, navigation: nil)
        let page = SettingsPageController(title: "Context Window",
                                          ContextWindowView(store: store, router: router, botName: isDefault(bot.id) ? nil : bot.name))
        page.onDisappear = { store.flush() }
        let navigation = ChatSheet.wrap(page, title: "Context Window", detents: [.large()])
        router.navigation = navigation
        return navigation
    }
}
