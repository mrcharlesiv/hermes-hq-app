// [quick-actions] Quick Ask sheet (pop lightweight prompt input over Favorites) and Starter Presets picker.

import SwiftUI
import UIKit

// MARK: - Quick Ask Sheet

enum FavoriteQuickAskSheet {
    static func make(bot: String, botName: String, defaultOpen: Bool,
                     onSend: @escaping (String, Bool) -> Void) -> UINavigationController {
        let host = FavoriteQuickAskHost(bot: bot, botName: botName, defaultOpen: defaultOpen, onSend: onSend)
        let nav = ChatSheet.wrap(host, title: "Ask \(botName)", detents: [.medium(), .large()])
        nav.view.accessibilityIdentifier = "favorites.quick-ask-sheet"
        return nav
    }
}

private final class FavoriteQuickAskHost: UIHostingController<HQScaledRoot<FavoriteQuickAskView>> {
    private let state: QuickAskState
    private let onSend: (String, Bool) -> Void

    init(bot: String, botName: String, defaultOpen: Bool, onSend: @escaping (String, Bool) -> Void) {
        let state = QuickAskState(bot: bot, botName: botName, openChat: defaultOpen)
        self.state = state
        self.onSend = onSend
        weak var weakSelf: FavoriteQuickAskHost?
        let view = FavoriteQuickAskView(state: state) { weakSelf?.submit() }
        super.init(rootView: HQScaledRoot(view))
        weakSelf = self
        title = "Ask \(botName)"
        navigationItem.largeTitleDisplayMode = .never
        let close = UIBarButtonItem.hqClose(.cancel, action: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        navigationItem.hqPlaceFormClose(close)
        let send = UIBarButtonItem(title: "Send", primaryAction: UIAction { [weak self] _ in self?.submit() })
        send.style = .prominent
        send.accessibilityIdentifier = "favorites.quick-ask.send"
        navigationItem.rightBarButtonItem = send
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + [UIKeyCommand(title: "Send", action: #selector(submitFromKey), input: "\r", modifierFlags: .command)]
    }
    override var canBecomeFirstResponder: Bool { true }
    @objc private func submitFromKey() { submit() }

    private func submit() {
        let words = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        PagesHaptics.selection()
        let openChat = state.openChat
        dismiss(animated: true) { [onSend] in
            onSend(words, openChat)
        }
    }
}

@MainActor @Observable
private final class QuickAskState {
    let bot: String
    let botName: String
    var text = ""
    var openChat: Bool

    init(bot: String, botName: String, openChat: Bool) {
        self.bot = bot
        self.botName = botName
        self.openChat = openChat
    }
}

private struct FavoriteQuickAskView: View {
    @Bindable var state: QuickAskState
    var submit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let head = MainTabController.current?.services.bots.first { $0.id == state.bot }?.head
        Form {
            Section {
                HStack(spacing: 10) {
                    HeadImage(raw: head, profile: state.bot, size: HQFont.scaled(32))
                        .frame(width: HQFont.scaled(32), height: HQFont.scaled(32))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.botName).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                        Text(state.openChat ? "Opens chat after sending" : "Sends in background")
                            .font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2)
                    }
                }
                TextField("Ask \(state.botName) anything…", text: $state.text, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($focused)
                    .accessibilityIdentifier("favorites.quick-ask.field")
                Toggle("Open the Chat", isOn: $state.openChat)
            }
            .hqSheetRows()

            if !PromptLibrary.shared.prompts.isEmpty {
                Section {
                    ForEach(Array(PromptLibrary.shared.prompts.prefix(5))) { prompt in
                        Button {
                            PagesHaptics.selection()
                            state.text = prompt.text
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(prompt.displayTitle).font(Font.hq(.subheadline).weight(.medium)).foregroundStyle(Color.hqLabel).lineLimit(1)
                                if !prompt.preview.isEmpty {
                                    Text(prompt.preview).font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: { HQSectionLabel { Text("Saved Prompts") } }
                .hqSheetRows()
            }
        }
        .hqGroupedPage()
        .onAppear { focused = true }
    }
}

// MARK: - Starter Presets Sheet

enum FavoritePresetsSheet {
    static func make(pageId: String, onApply: @escaping ([QuickTile], Bool) -> Void) -> UINavigationController {
        let host = FavoritePresetsHost(pageId: pageId, onApply: onApply)
        let nav = ChatSheet.wrap(host, title: "Starter Layouts", detents: [.large()])
        nav.sheetPresentationController?.selectedDetentIdentifier = .large
        nav.view.accessibilityIdentifier = "favorites.presets-sheet"
        return nav
    }
}

private final class FavoritePresetsHost: UIHostingController<HQScaledRoot<FavoritePresetsView>> {
    init(pageId: String, onApply: @escaping ([QuickTile], Bool) -> Void) {
        weak var weakSelf: FavoritePresetsHost?
        let view = FavoritePresetsView { preset, replace in
            guard let self = weakSelf else { return }
            let bot = MainTabController.current?.services.bots.first.map { (profile: $0.id, name: $0.name) }
            let goal = TasksHub.current?.goals.first { $0.state == .active }.map { (id: $0.id, title: $0.title) }
            let tiles = preset.tiles(bot: bot, goal: goal, pageId: pageId)
            self.dismiss(animated: true) { onApply(tiles, replace) }
        }
        super.init(rootView: HQScaledRoot(view))
        weakSelf = self
        title = "Starter Layouts"
        navigationItem.largeTitleDisplayMode = .never
        let close = UIBarButtonItem.hqClose(.cancel, action: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.hqPlaceFormClose(close)
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

private struct FavoritePresetsView: View {
    var pick: (FavoritePreset, Bool) -> Void
    @State private var replace = true

    var body: some View {
        List {
            Section {
                Toggle("Replace Current Page", isOn: $replace)
            } footer: {
                Text(replace ? "Replaces the tiles on this Favorites page." : "Adds the layout’s tiles below your current ones.")
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
            }
            .hqSheetRows()

            Section {
                ForEach(FavoritePreset.allCases) { preset in
                    Button { pick(preset, replace) } label: {
                        HStack(spacing: 14) {
                            FavoritePresetThumbnail(preset: preset)
                                .frame(width: 74, height: 84)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(preset.title).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                                Text(preset.subtitle).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).lineLimit(3)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "plus.circle.fill")
                                .font(Font.hq(.title3))
                                .foregroundStyle(Color.hqTint)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("favorites.preset.\(preset.rawValue)")
                }
            } header: { HQSectionLabel { Text("Layouts") } }
            .hqSheetRows()
        }
        .hqGroupedPage()
    }
}

/// Miniature Bento wireframe thumbnail showing the actual structure of a `FavoritePreset` before applying it.
struct FavoritePresetThumbnail: View {
    var preset: FavoritePreset

    var body: some View {
        VStack(spacing: 4) {
            switch preset {
            case .commandCenter:
                // 4-up mini strip + Needs You + Today + Bot + 2-up Gateway/Usage
                HStack(spacing: 3) {
                    miniDot(Color.hqRed); miniDot(Color.hqGreen); miniDot(Color.hqTint); miniDot(Color(uiColor: QuickTileLook.color(.teal)))
                }
                wideBlock(accent: Color.hqOrange, height: 16)
                wideBlock(accent: Color.hqTint, height: 16)
                wideBlock(accent: Color.hqLabel3, height: 12)
                HStack(spacing: 3) {
                    smallBlock(accent: Color.hqGreen)
                    smallBlock(accent: Color.hqTint)
                }
            case .dailyFocus:
                // Large Today + Wide Goal + Wide Needs You + 2-up Actions
                wideBlock(accent: Color.hqOrange, height: 28)
                wideBlock(accent: Color.hqGreen, height: 16)
                wideBlock(accent: Color.hqTint, height: 14)
                HStack(spacing: 3) {
                    smallBlock(accent: Color(uiColor: QuickTileLook.color(.teal)))
                    smallBlock(accent: Color.hqRed)
                }
            case .voiceFirst:
                // 2-up Memo/Talk + Wide Ask + Wide Chat + Wide Bot
                HStack(spacing: 3) {
                    smallBlock(accent: Color.hqRed)
                    smallBlock(accent: Color.hqGreen)
                }
                wideBlock(accent: Color.hqTint, height: 16)
                wideBlock(accent: Color(uiColor: QuickTileLook.color(.indigo)), height: 16)
                wideBlock(accent: Color.hqLabel3, height: 16)
            case .builderOps:
                // 2-up Gateway/Usage + Wide Active + Wide Jobs + Wide Kanban
                HStack(spacing: 3) {
                    smallBlock(accent: Color.hqGreen)
                    smallBlock(accent: Color.hqTint)
                }
                wideBlock(accent: Color.hqTint, height: 15)
                wideBlock(accent: Color.hqOrange, height: 15)
                wideBlock(accent: Color(uiColor: QuickTileLook.color(.yellow)), height: 16)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.hqFill3)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.hqStroke, lineWidth: 1))
        )
        .accessibilityHidden(true)
    }

    private func miniDot(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(color.opacity(0.85))
            .frame(maxWidth: .infinity)
            .frame(height: 11)
    }

    private func wideBlock(accent: Color, height: CGFloat) -> some View {
        HStack(spacing: 4) {
            Circle().fill(accent).frame(width: 5, height: 5)
            RoundedRectangle(cornerRadius: 2).fill(Color.hqLabel3.opacity(0.45)).frame(height: 3)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(uiColor: HQPalette.card)))
    }

    private func smallBlock(accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Circle().fill(accent).frame(width: 5, height: 5)
            RoundedRectangle(cornerRadius: 2).fill(Color.hqLabel3.opacity(0.45)).frame(height: 3)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(uiColor: HQPalette.card)))
    }
}
