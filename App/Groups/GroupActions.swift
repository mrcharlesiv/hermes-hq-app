// [groups] What a room's row, tile, swipes and menus do (docs/spec/3x-groups.md §7.1, §7.3, §7.6): Group Info, Pin,
// Mute, Mark as Unread, Delete Group Chat with its question, and the hooks other screens call (New Group Chat in the
// Compose menu, Add to Group Chat… in a bot's menu, Bot Info's Group Chats).

import SwiftUI
import UIKit

@MainActor enum GroupActions {
    /// Rooms being deleted from this iPhone right now (their open screen pops without the "was deleted" notice).
    static var deletingHere: Set<String> = []
    private static var installed = false
    private static weak var model: AppModel?

    // MARK: Row menu and swipes

    /// Group Info · Pin · Mute · Mark as Unread · Hide (Show in Bots) · Delete Group Chat, in that order.
    static func menuNodes(for room: GroupRowModel, services: any GroupServices, host: UIViewController, source: @escaping () -> UIView?) -> [BotMenuNode] {
        let key = room.id
        var nodes: [BotMenuNode] = [
            .action("Group Info", "info.circle") { [weak host] in
                if let host { GroupInfoSheet.present(roomKey: key, from: host, services: services) }
            },
        ]
        // A hidden room offers no Pin, as a hidden bot's menu doesn't: it would never show as a tile (review of #254).
        if !room.hidden || room.pinned {
            nodes.append(.action(room.pinned ? "Unpin" : "Pin", room.pinned ? "pin.slash" : "pin") { togglePin(key, services: services) })
        }
        nodes += [
            // Mute offers its durations as a bot's does; Unmute is one item (the bot's filled glyphs).
            room.muted
                ? .action("Unmute", BotExtrasRules.muteItem(muted: true).image) { [weak host] in toggleMute(key, list: host as? BotsViewController) }
                : BotExtras.muteMenu("Mute", BotExtrasRules.muteItem(muted: false).image) { [weak host] choice in
                    mute(key, choice, list: host as? BotsViewController)
                },
            .action(room.unread ? "Mark as Read" : "Mark as Unread", BotExtrasRules.readSymbol(unread: room.unread)) {
                toggleUnread(key, services: services)
            },
            // UX study #254: Hide, as a bot's (this iPhone only); a hidden room offers Show in Bots.
            .action(room.hidden ? "Show in Bots" : "Hide", room.hidden ? "eye" : "eye.slash") { [weak host] in
                hide(key, !room.hidden, services: services, host: host)
            },
        ]
        var delete = BotMenuNode.action("Delete Group Chat", "trash", destructive: true, disabled: !services.groupsWritable) { [weak host] in
            if let host { confirmDelete(key, services: services, from: host, source: source()) }
        }
        delete.identifier = "room.delete"
        if !services.groupsWritable { delete.subtitle = "Your gateway is offline" }   // the reason, as New Group Chat gives it
        nodes.append(BotMenuNode(title: "", destructive: true, kind: .inline([delete])))
        return nodes
    }

    static func leadingSwipes(for room: GroupRowModel, services: any GroupServices) -> UISwipeActionsConfiguration {
        let key = room.id
        let unread = UIContextualAction(style: .normal, title: room.unread ? "Read" : "Unread") { _, _, done in
            toggleUnread(key, services: services)
            done(true)
        }
        unread.image = UIImage(systemName: BotExtrasRules.readSymbol(unread: room.unread, filled: true))
        unread.backgroundColor = HQPalette.tint
        unread.accessibilityLabel = room.unread ? "Mark as Read" : "Mark as Unread"
        let pin = UIContextualAction(style: .normal, title: room.pinned ? "Unpin" : "Pin") { _, _, done in
            togglePin(key, services: services)
            done(true)
        }
        pin.image = UIImage(systemName: room.pinned ? "pin.slash.fill" : "pin.fill")
        pin.backgroundColor = .systemOrange
        let actions = UISwipeActionsConfiguration(actions: !room.hidden || room.pinned ? [unread, pin] : [unread])
        actions.performsFirstActionWithFullSwipe = true
        return actions
    }

    static func trailingSwipes(for room: GroupRowModel, services: any GroupServices, list: BotsViewController) -> UISwipeActionsConfiguration {
        let key = room.id
        let mute = UIContextualAction(style: .normal, title: room.muted ? "Unmute" : "Mute") { [weak list] _, _, done in
            toggleMute(key, list: list)
            done(true)
        }
        mute.image = UIImage(systemName: room.muted ? "bell.fill" : "bell.slash.fill")
        mute.backgroundColor = .systemIndigo
        let more = UIContextualAction(style: .normal, title: "More") { [weak list] _, _, done in
            done(true)
            RowMoreMenu.afterSwipe { [weak list] in
                guard let list else { return }
                let source = list.cellView(for: key)
                BotMoreSheet.open(list.roomMenuNodes(room, services: services, source: { [weak source] in source }),
                                  title: room.name, from: list, row: source)
            }
        }
        more.image = UIImage(systemName: "ellipsis.circle.fill")
        more.backgroundColor = .systemGray
        let actions = UISwipeActionsConfiguration(actions: [mute, more])
        actions.performsFirstActionWithFullSwipe = true
        return actions
    }

    // MARK: Picks

    /// UX study #254: Hide moves the room under Hidden with an Undo pill (a bot's words); Show in Bots brings it back.
    static func hide(_ key: String, _ on: Bool, services: any GroupServices, host: UIViewController?) {
        guard let store = services.groupStore, let room = store.room(key) else { return }
        Haptics.play(.selection)
        // Hiding drops a pin (a hidden room is never a tile); Undo puts it back in its place (review of #254).
        let pinnedAt = room.pinned ? (room.pinnedAt ?? Date().timeIntervalSince1970) : nil
        store.setHidden(key, on)
        guard on else { return }
        _ = UndoPill.show(label: "Hidden", wayBack: "Find it under Hidden, below your bots.", in: host) {
            store.setHidden(key, false, restoringPin: pinnedAt)
        }
    }

    static func togglePin(_ key: String, services: any GroupServices) {
        guard let store = services.groupStore, let room = store.room(key) else { return }
        Haptics.play(.selection)
        store.setPinned(key, !room.pinned)
    }

    /// Always / off; the first mute ever explains itself on the row's bell.
    static func toggleMute(_ key: String, list: BotsViewController?) {
        Haptics.play(.selection)
        let first = BotMuteCenter.shared.toggle(GroupKeys.muteKey(key))
        if first, let list { list.showMuteTip(for: key) }
    }

    /// A duration from the row menu; the first mute ever explains itself on the row's bell, as the swipe's does.
    static func mute(_ key: String, _ choice: MuteChoice, list: BotsViewController?) {
        Haptics.play(.selection)
        let first = BotMuteCenter.shared.set(GroupKeys.muteKey(key), choice.mute())
        if first, let list { list.showMuteTip(for: key) }
    }

    static func setMute(_ key: String, _ choice: MuteChoice) {
        Haptics.play(.selection)
        if BotMuteCenter.shared.set(GroupKeys.muteKey(key), choice.mute()) { BotMuteCenter.shared.markTipSeen() }
    }

    /// This iPhone's own mark: no network call.
    static func toggleUnread(_ key: String, services: any GroupServices) {
        guard let store = services.groupStore else { return }
        Haptics.play(.selection)
        store.setUnread(key, !store.isUnread(key))
    }

    // MARK: Delete Group Chat

    static let deleteMessage = "The group chat and its messages are removed. The bots and their own chats are kept. This can’t be undone."
    static func deleteTitle(_ name: String) -> String { "Delete “\(name)”?" }

    /// `sourceItem`: a bar button the sheet points at on iPad (the room's ⋯), ahead of `source`.
    static func confirmDelete(_ key: String, services: any GroupServices, from host: UIViewController, source: UIView?,
                              sourceItem: UIBarButtonItem? = nil, done: (() -> Void)? = nil) {
        guard let room = services.groupStore?.room(key) else { return }
        // [Mac UI check 2026-11-13] With nothing to point at (Group Info's row is SwiftUI's), a popover hung off the middle
        // of the sheet: on the Mac and the iPad that question is a centred alert instead (C3). The iPhone keeps its sheet.
        let unanchored = source == nil && sourceItem == nil && (DeviceWord.isMac || host.traitCollection.horizontalSizeClass == .regular)
        let sheet = UIAlertController(title: deleteTitle(room.name), message: deleteMessage, preferredStyle: unanchored ? .alert : .actionSheet)
        sheet.addAction(UIAlertAction(title: "Delete Group Chat", style: .destructive) { [weak host] _ in
            delete(key, name: room.name, services: services, from: host, done: done)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            if let sourceItem {
                popover.sourceItem = sourceItem
            } else {
                popover.sourceView = source ?? host.view
                popover.sourceRect = (source ?? host.view).bounds
            }
        }
        host.present(sheet, animated: true)
    }

    private static func delete(_ key: String, name: String, services: any GroupServices, from host: UIViewController?, done: (() -> Void)?) {
        guard let store = services.groupStore else { return }
        deletingHere.insert(name)
        Task {
            defer { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { deletingHere.remove(name) } }
            do {
                try await store.delete(key)
                Haptics.play(.success)
                done?()
            } catch {
                // The room is already gone from this iPhone and stays gone: only the gateway writes are retried.
                done?()
                finishDelete(name: name, error: error, services: services)
            }
        }
    }

    private static func finishDelete(name: String, error: Error, services: any GroupServices) {
        FailureAlert.present(error, fallbackTitle: "Couldn’t Delete \(name)", from: MainTabController.current) {
            Task {
                do { try await services.groupStore?.finishDelete(name: name) }
                catch { finishDelete(name: name, error: error, services: services) }
            }
        }
    }

    // MARK: Hooks

    /// Registers the Compose menu's New Group Chat, a bot's Add to Group Chat… and Bot Info's Group Chats (M2Wiring).
    /// Every time a main window connects: the hooks are set once and read the newest window's model when they run (Mac
    /// polish #3: held from the first, New Group Chat and Add to Group Chat… did nothing after the window was closed and
    /// opened again from the Dock).
    static func install(model: AppModel) {
        self.model = model
        guard !installed else { return }
        installed = true
        BotMenuHooks.newGroupChat = { host in
            guard let model = GroupActions.model else { return }
            GroupBotsPicker.presentNew(from: host, services: model)
        }
        BotMenuHooks.newGroupChatDisabledReason = {
            guard let model = GroupActions.model else { return nil }
            return newGroupDisabledReason(bots: model.bots, online: model.groupsWritable)
        }
        BotMenuHooks.providers[.addToGroup] = { bot, host in
            guard let model = GroupActions.model else { return nil }
            var node = BotMenuNode.action("Add to Group Chat…", "person.2", disabled: !model.groupsWritable) { [weak host, weak model] in
                guard let host, let model else { return }
                AddToGroupController.present(bot: bot, from: host, services: model)
            }
            node.identifier = "bot.add-to-group"
            return node
        }
        BotMenuHooks.groupChats = { bot in GroupActions.model?.groupStore?.rooms(of: bot.id).map(\.name) ?? [] }
        BotMenuHooks.botDeleted = { bot in GroupActions.model?.groupStore?.forgetMember(bot.id) }
        BotInfoHooks.afterConversations.append { bot, host in
            guard let model = GroupActions.model else { return nil }
            return AnyView(BotInfoGroupsSection(bot: bot, services: model, host: host))
        }
    }

    /// The Compose menu's item is disabled with a reason: fewer than 2 bots, or the gateway is offline.
    nonisolated static func newGroupDisabledReason(bots: [Bot], online: Bool) -> String? {
        if !online { return "Your gateway is offline" }
        return bots.filter { !$0.hidden }.count < 2 ? "Needs at least 2 bots" : nil
    }
}

/// Redraws a SwiftUI view when the account's rooms or memberships change (the store is not observable by itself).
@MainActor @Observable final class GroupStoreWatch {
    var version = 0
    @ObservationIgnored private weak var store: GroupStore?
    @ObservationIgnored private var observer: UUID?

    init(_ store: GroupStore?) {
        self.store = store
        observer = store?.observe { [weak self] in self?.version += 1 }
    }

    isolated deinit {
        if let observer { store?.stopObserving(observer) }
    }
}

/// Bot Info › Group Chats: one row per room the bot is in, then Add to Group Chat… (§7.8).
struct BotInfoGroupsSection: View {
    var bot: Bot
    var services: AppModel
    weak var host: UIViewController?
    /// The rows follow a join or a leave made on the pushed Add to Group Chat page (or anywhere else).
    @State private var watch: GroupStoreWatch

    init(bot: Bot, services: AppModel, host: UIViewController?) {
        self.bot = bot
        self.services = services
        self.host = host
        _watch = State(initialValue: GroupStoreWatch(services.groupStore))
    }

    var body: some View {
        let _ = watch.version
        let rooms = services.groupStore?.rooms(of: bot.id) ?? []
        let online = services.groupsWritable
        Section {
            ForEach(rooms, id: \.key) { room in
                Button {
                    let key = room.key
                    services.openRoom(key, from: host)
                } label: {
                    // [botinfo-chats] No chevron: a room row closes Bot Info and opens the group chat, and a chevron
                    // says a page opens inside the sheet (owner 2026-11-03, menu/nav review). Add to Group Chat… below
                    // keeps its chevron: it does push a page here.
                    HStack(spacing: 12) {
                        GroupAvatar(image: room.image, faces: faces(room), size: 28)
                        Text(room.name).foregroundStyle(Color.hqLabel)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                }
                .accessibilityIdentifier("bot-info.group.\(room.name)")
            }
            Button {
                guard let navigation = host?.navigationController else { return }
                navigation.pushViewController(AddToGroupController(bot: bot, services: services, inSheet: true), animated: true)
            } label: {
                HStack {
                    Text("Add to Group Chat…").foregroundStyle(online ? Color.hqLabel : Color.hqLabel3)
                    Spacer(minLength: 0)
                    SettingsChevron()
                }
            }
            .disabled(!online)
            .accessibilityIdentifier("bot-info.add-to-group")
        } header: { HQSectionLabel { Text("Group Chats") } }
    }

    private func faces(_ room: GroupRoom) -> [GroupRowModel.Face] {
        (services.groupStore?.seated(room) ?? []).prefix(3).map { GroupRowModel.Face(profile: $0.name, head: $0.head) }
    }
}
