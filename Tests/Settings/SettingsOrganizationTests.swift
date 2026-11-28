// More and Settings organization invariants: section order, row homes, Mac Settings categories, and search routing.

import Testing
@testable import HermesHQNative

@MainActor @Suite struct SettingsOrganizationTests {
    @Test func moreSectionsFollowTaskOrder() {
        #expect(PagesTabs.sectionOrder == ["community", "account", "settings", "workspace", "apps", "insights", "plugins", "system"])
        let byID = Dictionary(uniqueKeysWithValues: MorePages.pages.map { ($0.id, $0.section) })
        #expect(byID["tasks"] == "workspace")
        #expect(byID["files"] == "workspace")
        #expect(byID["review"] == "workspace")
        #expect(byID["terminal"] == "workspace")
        #expect(byID["messaging"] == "apps")
        #expect(byID["webhooks"] == "apps")
        #expect(byID["usage"] == "insights")
        #expect(byID["spawn-tree"] == "insights")
        #expect(byID["star-map"] == "insights")
        #expect(byID["profiles"] == "system")
        #expect(byID["command-center"] == "system")
        #expect(byID["import-sessions"] == "system")
    }

    @Test func macSettingsCategoriesAreBalanced() {
        #expect(SettingsCategory.allCases == [.general, .appearance, .chat, .gateway, .accounts, .tools, .about])
        #expect(SettingsCategory.accounts.title == "Accounts & Keys")
    }

    @Test func navigatorCategoriesMatchNewHomes() {
        for id in ["vault", "providers", "keys", "billing"] {
            #expect(SettingsNavigator.category(of: id) == .accounts, "\(id)")
        }
        for id in ["tile-model", "phone-calls", "browser-use-cloud", "sessions", "backup-reset", "attachment-limit"] {
            #expect(SettingsNavigator.category(of: id) == .gateway, "\(id)")
        }
        for id in ["notifications", "device-access", "sound-picker", "proactivity-beta"] {
            #expect(SettingsNavigator.category(of: id) == .general, "\(id)")
        }
        #expect(SettingsNavigator.category(of: "tool-calls") == .chat)
        #expect(SettingsNavigator.category(of: "capabilities") == .tools)
        #expect(SettingsNavigator.category(of: "about") == .about)
    }

    @Test func rootRowRoutingCoversAppearanceChatSoundsAndTasks() {
        #expect(AppearanceRows.contains(AppearanceRows.thinkingBar))
        #expect(SettingsRootModel.category(ofRow: AppearanceRows.thinkingBar) == .appearance)
        #expect(AppearanceRows.contains(AppearanceRows.windowTransparency) == DeviceWord.isMac)
        #expect(SettingsRootModel.category(ofRow: AppearanceRows.windowTransparency) == (DeviceWord.isMac ? .appearance : nil))
        #expect(SettingsRootModel.category(ofRow: SoundsHapticsRows.completionSound) == .general)
        #expect(SettingsRootModel.category(ofRow: SoundsHapticsRows.sound) == .general)
        #expect(SettingsRootModel.category(ofRow: ChatSettingsRows.resumeLastChat) == .general)
        #expect(SettingsRootModel.category(ofRow: ChatSettingsRows.tips) == .general)
        #expect(SettingsRootModel.category(ofRow: ChatSettingsRows.fewerTimestamps) == .chat)
        #expect(SettingsRootModel.category(ofRow: ChatSettingsRows.showFileChanges) == .chat)
        #expect(SettingsRootModel.category(ofRow: ChatSettingsRows.sendWhileBusy) == .chat)
        #expect(SettingsRootModel.category(ofRow: "row:tasks") == .gateway)
        #expect(SettingsRootModel.category(ofRow: "row:plugin-update-checks") == .tools)
        #expect(SettingsRootModel.category(ofRow: "row:check-plugin-updates") == .tools)
    }

    @Test func searchIndexReflectsReorganizedHomes() {
        let index = SettingsSearch.index()
        #expect(SettingsSearch.results("thinking bar", in: index).first?.context == "Appearance")
        #if targetEnvironment(macCatalyst)
        #expect(SettingsSearch.results("window transparency", in: index).first?.target == .root(AppearanceRows.windowTransparency))
        #expect(SettingsSearch.results("frosted", in: index).contains { $0.target == .root(AppearanceRows.windowTransparency) })
        #endif
        #expect(SettingsSearch.results("tasks", in: index).first?.context == "Workspace & Tasks")
        #expect(SettingsSearch.results("phone calls", in: index).first?.target == .root("phone-calls"))
        #expect(SettingsSearch.results("backup", in: index).contains { $0.target == .root("backup-reset") })
        #expect(SettingsSearch.results("export", in: index).first?.target == .action("export"))
    }
}
