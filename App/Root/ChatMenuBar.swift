// [mac] Stress test 2026-10-28 #33, #35: the menu bar's Chat menu. What the ⋯ and a right-click offer for the chat on
// show (Info, Rename, Pin, Mark as Unread, Prompts, Usage & Limits, Model Prices, Files, Changes, Branch, Export,
// Delete), the composer's + (Attach Files,
// Record Memo, Talk), and Talk's own Mute and End, which act on the live conversation from any screen. Each item is
// the ⋯ row's own action and is dimmed when the ⋯ would not offer it (`AppDelegate.validateChat`). The iPad's menu bar
// shows the same menu.

import UIKit

@MainActor enum ChatMenuBar {
    static let identifier = UIMenu.Identifier("com.hermeshq.menu.chat")
    static let chatRow = #selector(AppDelegate.hqChatRow(_:))
    static let attach = #selector(AppDelegate.hqAttachFiles(_:))
    static let memo = #selector(AppDelegate.hqRecordMemo(_:))
    static let talk = #selector(AppDelegate.hqTalk(_:))
    /// [mac] The voice menu's Dictate with Hermes, with words in the field too: the Mac's message box has no Dictate
    /// button while typing (the iPhone's glass bar turns its mic into one), and the voice menu opens only while it's empty.
    static let dictate = #selector(AppDelegate.hqDictate(_:))
    static let muteTalk = #selector(AppDelegate.hqMuteTalk(_:))
    static let endTalk = #selector(AppDelegate.hqEndTalk(_:))
    // [mac] Stress test 2026-10-28 #79: the ⋯'s Read Replies Aloud, with its tick, where a Mac shows a switch's state.
    static let readReplies = #selector(AppDelegate.hqReadReplies(_:))
    // [mac] Stress test 2026-10-31: the ⋯'s Prompts, Usage & Limits and Model Prices (tester wishlist 2026-10-24).
    static let tool = #selector(AppDelegate.hqChatTool(_:))
    static let actions: Set<Selector> = [chatRow, attach, memo, dictate, talk, muteTalk, endTalk, readReplies, tool]

    private static func item(_ title: String, _ action: Selector, _ input: String? = nil, _ flags: UIKeyModifierFlags = [],
                             row: ChatMenuItemID? = nil, attributes: UIMenuElement.Attributes = []) -> UICommand {
        let command: UICommand
        if let input {
            command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: flags, propertyList: row?.rawValue)
            (command as? UIKeyCommand)?.discoverabilityTitle = title
        } else {
            command = UICommand(title: title, action: action, propertyList: row?.rawValue)
        }
        command.attributes = attributes
        return command
    }

    static func menu() -> UIMenu {
        let compose: [UIMenuElement] = [
            item("Attach Files…", attach, "a", [.command, .shift]),
            item("Record Voice Memo", memo, "r", [.command, .shift]),
            item("Dictate with Hermes", dictate, "d", [.command, .shift]),
            item("Talk", talk, "t", [.command, .shift]),
        ]
        let talking: [UIMenuElement] = [
            item("Mute Talk", muteTalk, "m", [.command, .shift]),
            item("End Talk", endTalk, "e", [.command, .shift]),
            item("Read Replies Aloud", readReplies),
        ]
        let chat: [UIMenuElement] = [
            item(DeviceWord.isMac ? "Show Inspector" : "Chat Info", chatRow, "i", .command, row: .info),
            item("Rename…", chatRow, row: .rename),
            item("Pin", chatRow, "p", [.command, .shift], row: .pin),
            item("Mark as Unread", chatRow, "u", [.command, .shift], row: .unread),
        ]
        let tools: [UIMenuElement] = [
            UICommand(title: "Prompts…", action: tool, propertyList: ChatMenus.ToolRow.prompts.rawValue),
            UICommand(title: "Usage & Limits", action: tool, propertyList: ChatMenus.ToolRow.usage.rawValue),
            UICommand(title: "Model Prices", action: tool, propertyList: ChatMenus.ToolRow.prices.rawValue),
        ]
        let more: [UIMenuElement] = [
            item("Files", chatRow, row: .files),
            item("Changes", chatRow, row: .changes),
            item("Branch in New Chat", chatRow, row: .branch),
            item("Export Chat…", chatRow, row: .export),
        ]
        // [mac-audit K] Owner 2026-11-02: one name per action. "Delete Chat", as the ⋯ and the Sessions menus say it
        // (the kit puts no ellipsis on a destructive row).
        let danger: [UIMenuElement] = [item("Delete Chat", chatRow, row: .delete, attributes: .destructive)]
        #if targetEnvironment(macCatalyst)
        // [mac-audit K] Go to Message Field, Send and Message Actions act on this chat: first here, not in Edit.
        let groups = [KeyCommands.chatItems() as [UIMenuElement], compose, talking, chat, tools, more, danger]
        #else
        let groups = [compose, talking, chat, tools, more, danger]
        #endif
        return UIMenu(title: "Chat", identifier: identifier, children: groups.map {
            UIMenu(title: "", options: .displayInline, children: $0)
        })
    }

    static var chat: ChatViewController? {
        #if targetEnvironment(macCatalyst)
        if MacSettingsWindow.isKey || MacFileWindow.isKey { return nil }   // [mac] Mac polish #12: the chat is behind it
        #endif
        guard let root = KeyCommands.root, KeyCommands.presented(root) == nil else { return nil }
        return root.chatOnShow
    }

    static func canMemo(_ chat: ChatViewController) -> Bool {
        let composer = chat.composer
        return chat.voice.isAvailable && composer.micAvailable && composer.isEnabled && !composer.memoActive && !composer.dictating
    }

    static func canDictate(_ chat: ChatViewController) -> Bool {
        let composer = chat.composer
        return chat.voice.isAvailable && chat.voice.isOnScreen && composer.isEnabled && !composer.memoActive && !composer.dictating
            && TalkMenus.dictation(for: chat) == .on
    }

    static func canTalk(_ chat: ChatViewController) -> Bool {
        chat.voice.isAvailable && chat.voice.talk.allowsTalk && !chat.voice.talk.isLiveHere
    }
}

extension AppDelegate {
    /// The Chat menu's items; false for any other command (`validate` goes on with it).
    func validateChat(_ command: UICommand) -> Bool {
        guard ChatMenuBar.actions.contains(command.action) else { return false }
        let chat = ChatMenuBar.chat
        var enabled = false
        switch command.action {
        case ChatMenuBar.chatRow:
            #if targetEnvironment(macCatalyst)
            // [mac] Mac polish #128: ⌘I shows and hides the inspector beside the chat (`hqChatRow`), and says which,
            // with a chat on show or not; one pane, with no room for an inspector, it is Chat Info's sheet.
            if command.propertyList as? String == ChatMenuItemID.info.rawValue {
                let inspector = chat.flatMap { MacInspector.beside($0) }
                let visible = inspector?.isVisible ?? MacInspector.isShown
                command.title = chat != nil && inspector == nil ? "Chat Info" : visible ? "Hide Inspector" : "Show Inspector"
            }
            #endif
            if let id = (command.propertyList as? String).flatMap(ChatMenuItemID.init(rawValue:)),
               let row = chat?.menus?.menuBarRow(id) {
                enabled = true
                switch id {
                case .info: if !DeviceWord.isMac { command.title = "Chat Info" }
                case .export: command.title = "Export Chat…"
                case .delete: command.title = "Delete Chat"
                default: command.title = row.title
                }
            }
        case ChatMenuBar.attach:
            enabled = chat?.attachments?.canAttach == true && chat?.composer.isEnabled == true
        case ChatMenuBar.memo:
            enabled = chat.map(ChatMenuBar.canMemo) ?? false
        case ChatMenuBar.dictate:
            enabled = chat.map(ChatMenuBar.canDictate) ?? false
        case ChatMenuBar.talk:
            enabled = chat.map(ChatMenuBar.canTalk) ?? false
            command.title = chat.map { "Talk to \($0.voice.talk.name)" } ?? "Talk"
        case ChatMenuBar.muteTalk:
            enabled = TalkController.shared.isLive
            command.title = TalkController.shared.isMuted ? "Unmute Talk" : "Mute Talk"
        case ChatMenuBar.endTalk:
            enabled = TalkController.shared.isLive
        case ChatMenuBar.readReplies:
            enabled = chat?.voice.talkReadsAloud == true
            command.state = TalkController.readsRepliesAloud ? .on : .off
        case ChatMenuBar.tool:
            if let row = (command.propertyList as? String).flatMap(ChatMenus.ToolRow.init(rawValue:)) {
                enabled = chat?.menus?.canOpen(row) == true
            }
        default:
            break
        }
        command.attributes = enabled ? command.attributes.subtracting(.disabled) : command.attributes.union(.disabled)
        return true
    }

    @objc func hqChatRow(_ sender: Any?) {
        guard let id = ((sender as? UICommand)?.propertyList as? String).flatMap(ChatMenuItemID.init(rawValue:)),
              let menus = ChatMenuBar.chat?.menus, menus.menuBarRow(id) != nil else { return }
        AppLog.note("keys", "chat menu: \(id.rawValue)")
        #if targetEnvironment(macCatalyst)
        // [mac-layout] ⌘I shows and hides the inspector beside the chat, as Linear's and Keynote's do.
        if id == .info, let chat = ChatMenuBar.chat, let inspector = MacInspector.beside(chat) { inspector.toggle(); return }
        #endif
        menus.perform(id)
    }

    @objc func hqAttachFiles(_ sender: Any?) {
        guard let attachments = ChatMenuBar.chat?.attachments else { return }
        AppLog.note("keys", "attach files")
        attachments.presentFiles()
    }

    @objc func hqRecordMemo(_ sender: Any?) {
        guard let chat = ChatMenuBar.chat, ChatMenuBar.canMemo(chat) else { return }
        AppLog.note("keys", "record memo")
        chat.beginMemo(handsFree: true)
    }

    @objc func hqDictate(_ sender: Any?) {
        guard let chat = ChatMenuBar.chat, ChatMenuBar.canDictate(chat) else { return }
        AppLog.note("keys", "dictate")
        TalkMenus.dictate?(chat)
    }

    @objc func hqTalk(_ sender: Any?) {
        guard let chat = ChatMenuBar.chat, ChatMenuBar.canTalk(chat) else { return }
        AppLog.note("keys", "talk")
        chat.beginTalk()
    }

    @objc func hqMuteTalk(_ sender: Any?) {
        guard TalkController.shared.isLive else { return }
        AppLog.note("keys", "talk mute")
        TalkController.shared.toggleMute()
    }

    @objc func hqEndTalk(_ sender: Any?) {
        guard TalkController.shared.isLive else { return }
        AppLog.note("keys", "talk end")
        TalkController.shared.end()
    }

    @objc func hqChatTool(_ sender: Any?) {
        guard let row = ((sender as? UICommand)?.propertyList as? String).flatMap(ChatMenus.ToolRow.init(rawValue:)),
              let menus = ChatMenuBar.chat?.menus, menus.canOpen(row) else { return }
        AppLog.note("keys", "chat menu: \(row.rawValue)")
        menus.open(row)
    }

    @objc func hqReadReplies(_ sender: Any?) {
        guard let voice = ChatMenuBar.chat?.voice, voice.talkReadsAloud else { return }
        AppLog.note("keys", "read replies aloud")
        TalkController.readsRepliesAloud.toggle()
        voice.reader.saySwitch()
    }
}
