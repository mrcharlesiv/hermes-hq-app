// Settings › Chat, grouped by what each control changes (matching AppearancePage):
//   Conversation Display  Tool Calls, File Changes, Fewer Timestamps, Message Reactions, Greeting on Empty Chats
//   Toolbar & Navigation  Files Button in Chats, Other Chats at the Top, Open Links In
//   Sending & New Chats   Send While Replying, New Chat Asks for a Project, (offline Largest Attachment), (Mac ⌘N)
//   Startup & Models      (iOS: Reopen Last Chat on Launch, In-App Tips), Favorites Wait for Models, Clear Favorites
// On the Mac, the Chat category pane renders these groups directly (while Reopen Last Chat & In-App Tips live in General).
// On iPhone and iPad, they live on a dedicated page behind one Chat row on the Settings root.

import SwiftUI
import UIKit

/// Root-style row IDs rendered inside Chat (`row:<id>`).
enum ChatSettingsRows {
    static let fewerTimestamps = "row:fewer-timestamps"
    static let showFileChanges = "row:show-file-changes"
    static let newChatAsksProject = "row:new-chat-asks-project"
    static let waitForModels = "row:wait-for-models"
    static let attachmentLimit = "row:attachment-limit"
    static let sendWhileBusy = "row:send-while-busy"
    static let openLinksIn = "row:open-links-in"
    static let newChatMode = "row:new-chat-mode"
    static let newChatKey = "row:new-chat-key"
    static let newChatProject = "row:new-chat-project"
    static let shortcutDefaultBot = "row:shortcut-default-bot"
    static let resumeLastChat = "row:resume-last-chat"
    static let tips = "row:tips"
    static let introSplash = "row:intro-splash"
    static let fileBrowser = "row:file-browser"
    static let sessionStrip = "row:session-strip"
    static let messageReactions = "row:message-reactions"

    static func contains(_ row: String) -> Bool {
        switch row {
        case fewerTimestamps, showFileChanges, newChatAsksProject, waitForModels, attachmentLimit,
             sendWhileBusy, openLinksIn, newChatMode, newChatKey, newChatProject, shortcutDefaultBot,
             resumeLastChat, tips, introSplash, fileBrowser, sessionStrip, messageReactions:
            true
        default:
            false
        }
    }
}

enum ChatSettingsPage {
    static let title = "Chat"

    static func make(model: SettingsRootModel, router: SettingsRouter, actions: SettingsFileActions, reveal: String? = nil) -> UIViewController {
        let page = SettingsPageController(title: title, ChatSettingsPageView(model: model, router: router, actions: actions, reveal: reveal))
        page.view.accessibilityIdentifier = "settings.chat-page"
        page.view.backgroundColor = HQPalette.page
        return page
    }
}

struct ChatSettingsPageView: View {
    @Bindable var model: SettingsRootModel
    let router: SettingsRouter
    let actions: SettingsFileActions
    var reveal: String?
    @State private var revealed: String?

    var body: some View {
        ScrollViewReader { proxy in
            List { Group {
                ChatSections(model: model, router: router, actions: actions, revealed: revealed, includeAppStartup: true)
            }.hqMacSettingsRowInsets() }
            .hqMacForm(settings: true)
            .hqGroupedPage()
            .listStyle(.insetGrouped)
            .accessibilityIdentifier("settings.chat-list")
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

/// Chat's grouped sections, shared by iPhone's ChatSettingsPage and Mac's Chat category pane.
struct ChatSections: View {
    @Bindable var model: SettingsRootModel
    let router: SettingsRouter
    let actions: SettingsFileActions
    var revealed: String?
    /// True on iPhone/iPad (where Reopen Last Chat & In-App Tips live under Chat › Startup & Models);
    /// false in Mac two-column mode (where they live under General › App & Sharing).
    var includeAppStartup = true

    private var notes: Bool { DeviceWord.isMac }

    var body: some View {
        conversationDisplaySection
        toolbarAndNavigationSection
        sendingAndNewChatsSection
        startupAndModelsSection
    }

    // MARK: 1. Conversation Display

    private var conversationDisplaySection: some View {
        Section {
            if let screen = SettingsHooks.toolCallsScreen {
                NavRow(title: SettingsHooks.toolCallsTitle, systemImage: "wrench.and.screwdriver", value: model.toolCallsSummary) {
                    router.push(screen())
                }
            }
            let fileChanges = Binding(get: { model.fileChanges }, set: { (value: FileChangesLook) in
                Haptics.play(.selection)
                model.fileChanges = value
                ToolCallSettings.fileChanges = value
                AppLog.note("settings", "File Changes set to \(value.rawValue)")
            })
            if DeviceWord.isMac {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    SettingsRowLabel(title: "File Changes", systemImage: "doc.badge.ellipsis", subtitle: ChatRowNotes.showFileChanges)
                    Spacer(minLength: 16)
                    MacPopUp(label: "File Changes", selection: fileChanges, options: FileChangesLook.allCases) { $0.title }
                        .accessibilityIdentifier("settings.show-file-changes")
                        .hqMacSettingsControl()
                }
                .revealRow(ChatSettingsRows.showFileChanges, revealed)
            } else {
                SettingsMenuRowFace(label: SettingsRowLabel(title: "File Changes", systemImage: "doc.badge.ellipsis"),
                                    value: model.fileChanges.title)
                .overlay {
                    Menu {
                        Picker("File Changes", selection: fileChanges) {
                            ForEach(FileChangesLook.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .accessibilityLabel("File Changes")
                    .accessibilityValue(model.fileChanges.title)
                    .accessibilityIdentifier("settings.show-file-changes")
                }
                .revealRow(ChatSettingsRows.showFileChanges, revealed)
            }
            Toggle(isOn: Binding(get: { model.fewerTimestamps }, set: { on in
                model.fewerTimestamps = on
                ToolCallSettings.fewerTimestamps = on
            })) {
                SettingsRowLabel(title: "Fewer Timestamps", systemImage: "clock", subtitle: notes ? ChatRowNotes.fewerTimestamps : nil)
            }
            .accessibilityIdentifier("settings.fewer-timestamps")
            .revealRow(ChatSettingsRows.fewerTimestamps, revealed)
            Toggle(isOn: Binding(get: { model.messageReactions }, set: { on in
                model.messageReactions = on
                MessageReactionsPref.isOn = on
            })) {
                SettingsRowLabel(title: "Message Reactions", systemImage: "face.smiling", subtitle: notes ? ChatRowNotes.messageReactions : nil)
            }
            .accessibilityIdentifier("settings.message-reactions")
            .revealRow(ChatSettingsRows.messageReactions, revealed)
            Toggle(isOn: Binding(get: { model.introSplash }, set: { on in
                model.introSplash = on
                IntroSplash.isOn = on
            })) {
                SettingsRowLabel(title: SettingsSearch.introSplashLabel, systemImage: "hand.wave")
            }
            .accessibilityIdentifier("settings.intro-splash")
            .revealRow(ChatSettingsRows.introSplash, revealed)
        } header: { HQSectionLabel { Text("Conversation Display") } }
    }

    // MARK: 2. Toolbar & Navigation

    private var toolbarAndNavigationSection: some View {
        Section {
            Toggle(isOn: Binding(get: { model.fileBrowser }, set: { on in
                model.fileBrowser = on
                FileBrowserPref.isOn = on
            })) {
                SettingsRowLabel(title: SettingsSearch.fileBrowserLabel, systemImage: "folder")
            }
            .accessibilityIdentifier("settings.file-browser")
            .revealRow(ChatSettingsRows.fileBrowser, revealed)
            Toggle(isOn: Binding(get: { model.sessionStrip }, set: { on in
                model.sessionStrip = on
                SessionStripPref.isOn = on
            })) {
                SettingsRowLabel(title: "Other Chats at the Top", systemImage: "capsule")
            }
            .accessibilityIdentifier("settings.session-strip")
            .revealRow(ChatSettingsRows.sessionStrip, revealed)
            let linkChoice = Binding(get: { model.linkChoice }, set: { (value: LinkBrowserChoice) in
                Haptics.play(.selection)
                model.linkChoice = value
                LinkBrowserChoice.stored = value
                AppLog.note("settings", "Open Links In set to \(value.saved)")
            })
            let linkChoices = LinkOpener.choices(installed: model.linkBrowsers)
            if DeviceWord.isMac {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    SettingsRowLabel(title: SettingsSearch.openLinksInLabel, systemImage: "safari", subtitle: ChatRowNotes.openLinksIn)
                    Spacer(minLength: 16)
                    MacPopUp(label: SettingsSearch.openLinksInLabel, selection: linkChoice, options: linkChoices) {
                        $0.title(installed: model.linkBrowsers)
                    }
                    .accessibilityIdentifier("settings.open-links-in")
                    .hqMacSettingsControl()
                }
                .help("Web links without an installed app of their own open in this browser. Pages and files your bots make always open in the app.")
                .revealRow(ChatSettingsRows.openLinksIn, revealed)
            } else {
                SettingsMenuRowFace(label: SettingsRowLabel(title: SettingsSearch.openLinksInLabel, systemImage: "safari"),
                                    value: model.linkChoice.title(installed: model.linkBrowsers))
                .overlay {
                    Menu {
                        Picker(SettingsSearch.openLinksInLabel, selection: linkChoice) {
                            ForEach(linkChoices, id: \.self) { Text($0.title(installed: model.linkBrowsers)).tag($0) }
                        }
                    } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .accessibilityLabel(SettingsSearch.openLinksInLabel)
                    .accessibilityValue(model.linkChoice.title(installed: model.linkBrowsers))
                    .accessibilityIdentifier("settings.open-links-in")
                }
                .revealRow(ChatSettingsRows.openLinksIn, revealed)
            }
        } header: { HQSectionLabel { Text("Toolbar & Navigation") } }
    }

    // MARK: 3. Sending & New Chats

    private var sendingAndNewChatsSection: some View {
        Section {
            let sendWhileBusy = Binding(get: { model.sendWhileBusy }, set: { (value: SendWhileBusy) in
                Haptics.play(.selection)
                model.sendWhileBusy = value
                SendWhileBusy.chosen = value
            })
            if DeviceWord.isMac {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    SettingsRowLabel(title: SettingsSearch.sendWhileBusyLabel, systemImage: "text.line.last.and.arrowtriangle.forward",
                                     subtitle: ChatRowNotes.sendWhileBusy(mac: true))
                    Spacer(minLength: 16)
                    MacPopUp(label: SettingsSearch.sendWhileBusyLabel, selection: sendWhileBusy, options: SendWhileBusy.allCases) { $0.title }
                        .accessibilityIdentifier("settings.send-while-busy")
                        .hqMacSettingsControl()
                }
                .revealRow(ChatSettingsRows.sendWhileBusy, revealed)
            } else {
                SettingsMenuRowFace(label: SettingsRowLabel(title: SettingsSearch.sendWhileBusyLabel, systemImage: "text.line.last.and.arrowtriangle.forward"),
                                    value: model.sendWhileBusy.title)
                .overlay {
                    Menu {
                        Picker(SettingsSearch.sendWhileBusyLabel, selection: sendWhileBusy) {
                            ForEach(SendWhileBusy.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .accessibilityLabel(SettingsSearch.sendWhileBusyLabel)
                    .accessibilityValue(model.sendWhileBusy.title)
                    .accessibilityIdentifier("settings.send-while-busy")
                }
                .revealRow(ChatSettingsRows.sendWhileBusy, revealed)
            }
            Toggle(isOn: Binding(get: { model.newChatAsksProject }, set: { on in
                model.newChatAsksProject = on
                NewChatProjectChoice.isOn = on
            })) {
                SettingsRowLabel(title: "New Chat Asks for a Project", systemImage: "folder", subtitle: notes ? ChatRowNotes.newChatAsksProject : nil)
            }
            .accessibilityIdentifier("settings.new-chat-asks-project")
            .revealRow(ChatSettingsRows.newChatAsksProject, revealed)
            // With a gateway connected, Largest Attachment lives in Chat Behavior › Attachments on both iOS and Mac.
            if model.configStore == nil {
                if DeviceWord.isMac {
                    HStack(spacing: 12) {
                        SettingsRowLabel(title: "Largest Attachment", systemImage: "paperclip")
                        Spacer(minLength: 16)
                        MacIntField(value: Binding(get: { model.attachmentLimit }, set: { value in
                            AttachmentLimit.megabytes = value
                            model.attachmentLimit = value
                        }), range: AttachmentLimit.range, unit: "MB", label: "Largest Attachment")
                    }
                    .help(AttachmentLimit.footer())
                    .accessibilityIdentifier("settings.attachment-limit")
                    .revealRow(ChatSettingsRows.attachmentLimit, revealed)
                } else {
                    NavRow(title: "Largest Attachment", systemImage: "paperclip", value: "\(model.attachmentLimit) MB") {
                        router.push("Largest Attachment", AttachmentLimitPage { model.attachmentLimit = $0 })
                    }
                    .accessibilityIdentifier("settings.attachment-limit")
                    .revealRow(ChatSettingsRows.attachmentLimit, revealed)
                }
            }
            if DeviceWord.isMac {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    SettingsRowLabel(title: "⌘N Opens", systemImage: "command",
                                     subtitle: ChatRowNotes.newChatMode(botChat: model.newChatKeyMode == .botChat))
                    Spacer(minLength: 16)
                    MacPopUp(label: "⌘N Opens", selection: Binding(get: { model.newChatKeyMode }, set: { mode in
                        NewChatKeyBot.mode = mode
                        model.newChatKeyMode = mode
                    }), options: NewChatKeyBot.Mode.allCases) { $0.title }
                        .accessibilityIdentifier("settings.new-chat-mode")
                        .hqMacSettingsControl()
                }
                .revealRow(ChatSettingsRows.newChatMode, revealed)
                HStack(spacing: 12) {
                    SettingsRowLabel(title: "⌘N Bot", systemImage: "square.and.pencil")
                    Spacer(minLength: 16)
                    MacPopUp(label: "⌘N Bot", selection: Binding(get: { model.newChatKeyBot }, set: { id in
                        NewChatKeyBot.chosen = id
                        model.newChatKeyBot = id
                    }), options: model.newChatKeyOptions, title: model.newChatKeyTitle)
                        .accessibilityIdentifier("settings.new-chat-key")
                        .hqMacSettingsControl()
                }
                .revealRow(ChatSettingsRows.newChatKey, revealed)
                if model.newChatKeyMode == .session, model.newChatKeyProjects.count > 1 {
                    HStack(spacing: 12) {
                        SettingsRowLabel(title: "⌘N Project", systemImage: "folder.badge.plus")
                        Spacer(minLength: 16)
                        MacPopUp(label: "⌘N Project", selection: Binding(get: { model.newChatKeyProject }, set: { key in
                            NewChatKeyBot.project = key.isEmpty ? nil : key
                            model.newChatKeyProject = key
                        }), options: model.newChatKeyProjects, title: model.newChatKeyProjectTitle)
                            .accessibilityIdentifier("settings.new-chat-project")
                            .hqMacSettingsControl()
                    }
                    .revealRow(ChatSettingsRows.newChatProject, revealed)
                }
            } else {
                Picker(selection: Binding(get: { model.shortcutDefaultBot }, set: { id in
                    Haptics.play(.selection)
                    ShortcutDefaultBot.setProfile(id.isEmpty ? nil : id)
                    model.shortcutDefaultBot = id
                })) {
                    ForEach(model.shortcutDefaultBotOptions, id: \.self) { id in
                        Text(model.shortcutDefaultBotTitle(id)).tag(id)
                    }
                } label: {
                    SettingsRowLabel(title: "Side Button Bot", systemImage: "button.programmable",
                                     subtitle: notes ? "Default bot for Action Button and Shortcuts. Ask Every Time keeps the picker." : nil)
                }
                .accessibilityIdentifier("settings.shortcut-default-bot")
                .revealRow(ChatSettingsRows.shortcutDefaultBot, revealed)
            }
        } header: { HQSectionLabel { Text("Sending & New Chats") } }
    }

    // MARK: 4. Startup & Models

    private var startupAndModelsSection: some View {
        Section {
            if includeAppStartup {
                if model.configStore != nil {
                    Toggle(isOn: Binding(get: { model.resumeLastSession }, set: { model.setResumeLastSession($0) })) {
                        SettingsRowLabel(title: "Reopen Last Chat on Launch", systemImage: "arrow.counterclockwise", subtitle: notes ? ChatRowNotes.resumeLastChat : nil)
                    }
                    .accessibilityIdentifier("settings.resume-last-chat")
                    .revealRow(ChatSettingsRows.resumeLastChat, revealed)
                }
                Toggle(isOn: Binding(get: { model.inAppTips }, set: { on in
                    Haptics.play(.selection)
                    model.inAppTips = on
                    InAppTips.isOn = on
                })) {
                    SettingsRowLabel(title: "In-App Tips", systemImage: "lightbulb")
                }
                .accessibilityIdentifier("settings.tips")
                .revealRow(ChatSettingsRows.tips, revealed)
            }
            Toggle(isOn: Binding(get: { model.waitForModels }, set: { on in
                model.waitForModels = on
                ModelPrefs.waitForModels = on
            })) {
                SettingsRowLabel(title: "Favorites Wait for Models", systemImage: "star.slash")
            }
            .accessibilityIdentifier("settings.wait-for-models")
            .revealRow(ChatSettingsRows.waitForModels, revealed)
            if model.services.account != nil {
                if DeviceWord.isMac {
                    HStack(spacing: 12) {
                        SettingsRowLabel(title: "Favorite & Recent Models", systemImage: "star")
                        Spacer(minLength: 16)
                        Button("Clear Model Favorites…") { actions.confirmClearModels() }
                            .hqMacPushButton()
                            .fixedSize()
                            .accessibilityIdentifier("settings.clear-models")
                    }
                    .hqMacFormRowHeight()
                } else {
                    Button("Clear Favorite & Recent Models…") { actions.confirmClearModels() }
                        .accessibilityIdentifier("settings.clear-models")
                }
            }
        } header: { HQSectionLabel { Text(includeAppStartup ? "Startup & Models" : "Models") } }
    }
}
