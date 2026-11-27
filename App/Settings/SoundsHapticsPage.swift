// Settings › Sounds & Haptics (iPhone/iPad dedicated subpage; on Mac, Completion Sound & Sound live inside General).

import SwiftUI
import UIKit

enum SoundsHapticsRows {
    static let completionSound = "row:completion-sound"
    static let sound = "row:sound"
    static let haptics = "row:haptics"

    static func contains(_ row: String) -> Bool {
        row == completionSound || row == sound || row == haptics
    }
}

enum SoundsHapticsPage {
    static var title: String {
        !SettingsSearch.hasHaptics ? "Sounds" : SettingsHooks.completionCueWired ? "Sounds & Haptics" : "Haptics"
    }

    static func summary(model: SettingsRootModel) -> String {
        if SettingsHooks.completionCueWired, model.completionSound {
            return model.soundName
        }
        if SettingsSearch.hasHaptics, model.haptics {
            return "Haptics"
        }
        return "Off"
    }

    static func make(model: SettingsRootModel, router: SettingsRouter, reveal: String? = nil) -> UIViewController {
        let page = SettingsPageController(title: title, SoundsHapticsPageView(model: model, router: router, reveal: reveal))
        page.view.accessibilityIdentifier = "settings.sounds-page"
        page.view.backgroundColor = HQPalette.page
        return page
    }
}

struct SoundsHapticsPageView: View {
    @Bindable var model: SettingsRootModel
    let router: SettingsRouter
    var reveal: String?
    @State private var revealed: String?

    var body: some View {
        ScrollViewReader { proxy in
            List { Group {
                Section {
                    SoundsHapticsRowsContent(model: model, router: router, revealed: revealed)
                }
            }.hqMacSettingsRowInsets() }
            .hqMacForm(settings: true)
            .hqGroupedPage()
            .listStyle(.insetGrouped)
            .accessibilityIdentifier("settings.sounds-list")
            .onAppear { model.refresh() }
            .task {
                guard let reveal else { return }
                try? await Task.sleep(for: .milliseconds(350))
                HQMotion.withAnimation { proxy.scrollTo(reveal, anchor: .center) }
                revealed = reveal
                try? await Task.sleep(for: .seconds(1.4))
                revealed = nil
            }
        }
    }
}

/// Completion Sound, Sound picker, and (off Mac) Haptics. Used on iPhone's Sounds & Haptics page and in Mac's General category.
struct SoundsHapticsRowsContent: View {
    @Bindable var model: SettingsRootModel
    let router: SettingsRouter
    var revealed: String?

    var body: some View {
        if SettingsHooks.completionCueWired {
            Toggle(isOn: $model.completionSound) { SettingsRowLabel(title: "Completion Sound", systemImage: "speaker.wave.2") }
                .accessibilityIdentifier("settings.completion-sound")
                .onChange(of: model.completionSound) { _, value in
                    Haptics.play(.selection)
                    CompletionCue.isOn = value
                }
                .revealRow(SoundsHapticsRows.completionSound, revealed)
            if model.completionSound {
                if DeviceWord.isMac {
                    HStack(spacing: 12) {
                        SettingsRowLabel(title: "Sound", systemImage: "music.note")
                        Spacer(minLength: 16)
                        Button { CompletionCue.preview(CompletionCue.variant) } label: {
                            Image(systemName: "play.circle")
                                .font(MacIcon.rowFont)
                                .foregroundStyle(Color.hqLabel2)
                                .frame(width: MacIcon.rowColumn, height: MacIcon.rowColumn)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .help("Play \(model.soundName)")
                        .accessibilityLabel("Play \(model.soundName)")
                        MacPopUp(label: "Sound", selection: Binding(get: { CompletionSoundVariant.preset(CompletionCue.variant).id }, set: { id in
                            CompletionCue.variant = id
                            model.soundName = CompletionSoundVariant.preset(id).name
                            CompletionCue.preview(id)
                        }), options: CompletionSoundVariant.presets.map(\.id)) { CompletionSoundVariant.preset($0).name }
                            .accessibilityIdentifier("settings.sound")
                            .hqMacSettingsControl()
                    }
                    .revealRow(SoundsHapticsRows.sound, revealed)
                } else {
                    NavRow(title: "Sound", systemImage: "music.note", value: model.soundName) {
                        router.push("Sound", CompletionSoundPicker())
                    }
                    .accessibilityIdentifier("settings.sound")
                    .revealRow(SoundsHapticsRows.sound, revealed)
                }
            }
        }
        if SettingsSearch.hasHaptics {
            Toggle(isOn: Binding(get: { model.haptics }, set: { on in
                model.haptics = on
                Haptics.isOn = on
            })) {
                SettingsRowLabel(title: "Haptics", systemImage: "hand.tap")
            }
            .accessibilityIdentifier("settings.haptics")
            .revealRow(SoundsHapticsRows.haptics, revealed)
        }
    }
}
