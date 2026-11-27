// Settings › Backup & Reset (Export Settings, Import Settings, Reset to Defaults — and on iPhone, Clear Model Favorites).
// On Mac, Backup & Reset lives as a section inside the Hermes category instead of under About.

import SwiftUI
import UIKit

enum BackupResetPage {
    static let title = "Backup & Reset"

    static func make(model: SettingsRootModel, actions: SettingsFileActions) -> UIViewController {
        let page = SettingsPageController(title: title, BackupResetPageView(model: model, actions: actions))
        page.view.accessibilityIdentifier = "settings.backup-reset-page"
        page.view.backgroundColor = HQPalette.page
        return page
    }
}

struct BackupResetPageView: View {
    @Bindable var model: SettingsRootModel
    let actions: SettingsFileActions

    var body: some View {
        List { Group {
            BackupResetSection(model: model, actions: actions, includeClearModels: true)
        }.hqMacSettingsRowInsets() }
        .hqMacForm(settings: true)
        .hqGroupedPage()
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("settings.backup-reset-list")
    }
}

/// Export, Import, and Reset to Defaults (shared by iPhone's BackupResetPage and Mac's Hermes category).
struct BackupResetSection: View {
    @Bindable var model: SettingsRootModel
    let actions: SettingsFileActions
    var headerTitle: String? = nil
    var includeClearModels = false

    var body: some View {
        Section {
            if DeviceWord.isMac {
                let fileButtons = HStack(spacing: 10) {
                    Button("Export Settings…") { actions.export() }
                        .accessibilityIdentifier("settings.export")
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { actions.exportAnchor = $0 }
                    Button("Import Settings…") { actions.pickImport() }
                        .accessibilityIdentifier("settings.import")
                }
                let resetButtons = HStack(spacing: 10) {
                    if includeClearModels {
                        Button("Clear Model Favorites…") { actions.confirmClearModels() }
                            .accessibilityIdentifier("settings.clear-models")
                    }
                    Button("Reset to Defaults…", role: .destructive) { actions.confirmReset() }
                        .disabled(model.resetting)
                        .accessibilityIdentifier("settings.reset")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { fileButtons; resetButtons }.fixedSize()
                    VStack(alignment: .leading, spacing: 8) { fileButtons; resetButtons }.fixedSize()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .hqMacBordered()
            } else {
                Button("Export Settings…") { actions.export() }
                    .accessibilityIdentifier("settings.export")
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { actions.exportAnchor = $0 }
                Button("Import Settings…") { actions.pickImport() }
                    .accessibilityIdentifier("settings.import")
                if includeClearModels {
                    Button("Clear Favorite & Recent Models…") { actions.confirmClearModels() }
                        .accessibilityIdentifier("settings.clear-models")
                }
                Button("Reset to Defaults…", role: .destructive) { actions.confirmReset() }
                    .disabled(model.resetting)
                    .accessibilityIdentifier("settings.reset")
            }
        } header: {
            if let headerTitle { HQSectionLabel { Text(headerTitle) } }
        } footer: { HQSectionFooter {
            VStack(alignment: .leading, spacing: 6) {
                if let status = model.fileStatus {
                    Text(status).foregroundStyle(Color.hqLabel).accessibilityIdentifier("settings.file-status")
                }
                Text("Exported files leave out keys, tokens and passwords.")
            }
        } }
    }
}
