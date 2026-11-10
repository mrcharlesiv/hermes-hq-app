// Organising bots from the Bots list (spec 1x-settings §5): the row menu and swipes, Pin/Unpin, Hide/Show with the
// Undo pill, sections (new, rename, move up/down, delete with Undo, move a bot, drag a bot onto one), the bar's
// Compose menu. `BotsViewController` owns one and asks it; every write goes through `BotEditing`.

import SwiftUI
import UIKit

/// Menu items other streams own (`[x (hook)]` in §5.1). Left out when nobody registered them.
@MainActor enum BotMenuHooks {
    enum Slot: Hashable { case talk, memo, newChat, screen, mute, watchBrowser, addToGroup, duplicate, delete }
    /// slot → the item for a bot (nil: not for this bot). The view controller is the Bots list.
    static var providers: [Slot: (Bot, UIViewController) -> BotMenuNode?] = [:]
    /// The compose menu's "New Group Chat" (groups stream).
    static var newGroupChat: ((UIViewController) -> Void)?
    /// [groups] Why New Group Chat can't be picked right now ("Needs at least 2 bots"); nil = enabled.
    static var newGroupChatDisabledReason: (() -> String?)?
    /// [groups] The names of the group chats a bot sits in (Delete Bot's question names them).
    static var groupChats: ((Bot) -> [String])?
    /// [groups] A bot was deleted from this app: its seat leaves its group chats.
    static var botDeleted: ((Bot) -> Void)?

    static func item(_ slot: Slot, _ bot: Bot, _ host: UIViewController) -> BotMenuNode? { providers[slot]?(bot, host) }
}

@MainActor final class BotsOrganizer: NSObject {
    weak var host: BotsViewController?
    let services: any AppServices
    let settings: any SettingsServices
    /// The drop target block while a drag is over the list (its header highlights).
    private(set) var dropTarget: BotListSectionID?
    /// The slot a held tile would drop into (a selection tick each time it changes).
    var tileSlot: Int?
    /// [groups] A room row is being dragged: empty user sections show inside Group Chats as drop targets.
    private(set) var draggingRoom = false

    init(host: BotsViewController, services: any AppServices, settings: any SettingsServices) {
        self.host = host
        self.services = services
        self.settings = settings
    }

    var editing: (any BotEditing)? { settings.botEditing }

    // MARK: - Composition

    /// The sections by id with empty user sections (nil when there's no store yet: the old composer draws).
    func sections() -> [BotListSection]? {
        guard let layout = settings.botLayout, let editing else { return nil }
        return BotListLayout.compose(layout: layout, records: editing.sectionRecords,
                                     pinsAsRows: BotPinnedLook.saved == .rows, pinOrder: editing.pinOrder)
    }

    // MARK: - Bar

    /// The bar capsule's Compose menu (`S/ui-bots/roster-filters.ts` composeMenu), behind the bar's + and the Mac rail's +
    /// ([bots-plus]): New Bot, New Group Chat (once the groups stream registers it), New Section…. Settings lives in More,
    /// as on the web.
    func composeMenu() -> [UIMenuElement] {
        var first: [UIMenuElement] = [UIAction(title: "New Bot", image: UIImage(systemName: "plus")) { [weak self] _ in self?.newBot() }]
        if let group = BotMenuHooks.newGroupChat, let host {
            // [groups] `person.2`, and disabled with its reason (fewer than 2 bots, or offline).
            let reason = BotMenuHooks.newGroupChatDisabledReason?()
            let item = UIAction(title: "New Group Chat", subtitle: reason, image: UIImage(systemName: "person.2"),
                                attributes: reason == nil ? [] : .disabled) { [weak host] _ in
                if let host { group(host) }
            }
            item.accessibilityIdentifier = "compose.new-group"
            first.append(item)
        }
        let section = UIAction(title: "New Section…", image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in
            self?.newSection(filing: nil)
        }
        return first + [UIMenu(options: .displayInline, children: [section])]
    }

    func newBot() {
        guard let host else { return }
        NewBotFlow.present(from: host, services: services)
    }

    // MARK: - Row menu (§5.1)

    func menuNodes(for bot: Bot) -> [BotMenuNode] {
        guard let host, let editing else { return [] }
        var tiles: [BotMenuNode] = []
        if let talk = BotMenuHooks.item(.talk, bot, host) { tiles.append(talk) }
        if let memo = BotMenuHooks.item(.memo, bot, host) { tiles.append(memo) }
        // A hidden bot's pin would show nowhere (hidden bots are never tiles): it offers Show in Bots, not Pin.
        if !bot.hidden || bot.pinned {
            tiles.append(.action(bot.pinned ? "Unpin" : "Pin", bot.pinned ? "pin.slash" : "pin") { [weak self] in self?.pin(bot, !bot.pinned) })
        }

        // Owner 2026-11-08: changing a bot's face, one step from its menu (it sat under Edit Bot › Edit Head).
        var info: [BotMenuNode] = [.action("Bot Info", "info.circle") { [weak self] in self?.openInfo(bot) },
                                   .action("Change Face", "face.smiling") { [weak self] in self?.openInfo(bot, start: .face) }]
        if let item = BotMenuHooks.item(.newChat, bot, host) { info.append(item) }
        // [chats-under] Sessions with this bot's chip picked (tester, 2026-11-08). A hidden bot has no chip.
        if !bot.hidden {
            var view = BotMenuNode.action("View Sessions", "bubble.left.and.bubble.right") { [weak self] in self?.host?.openAllChats(of: bot.id) }
            view.identifier = "bot-menu.view-sessions"
            info.append(view)
        }
        if let item = BotMenuHooks.item(.screen, bot, host) { info.append(item) }

        let readToggle: BotMenuNode = bot.unread
            ? .action("Mark as Read", BotExtrasRules.readSymbol(unread: true)) { [weak self] in self?.services.markRead(bot) }
            : .action("Mark as Unread", BotExtrasRules.readSymbol(unread: false)) { [weak self] in
                Haptics.play(.selection)
                self?.settings.markUnread(bot)
            }
        var more: [BotMenuNode] = []
        if let item = BotMenuHooks.item(.watchBrowser, bot, host) { more.append(item) }
        more.append(.action("Edit Bot", "pencil") { [weak self] in self?.openInfo(bot, start: .editBot) })
        more.append(BotMenuNode(title: "Move to Section", image: "folder", kind: .submenu(moveNodes(for: bot, editing: editing))))
        // [a11y] A pinned tile's place, without the drag (VoiceOver, Switch Control, and the rows at accessibility sizes).
        more += pinMoves(for: bot).map { move in .action(move.title, move.image) { [weak self] in self?.movePin(bot, by: move.delta) } }
        // [manualorder] A row's place in its block without the drag; picks Sort By › Manual.
        more += rowMoves(for: bot).map { move in .action(move.title, move.image) { [weak self] in self?.moveRow(bot, by: move.delta) } }
        if let item = BotMenuHooks.item(.addToGroup, bot, host) { more.append(item) }
        if let item = BotMenuHooks.item(.duplicate, bot, host) { more.append(item) }
        var status: [BotMenuNode] = []
        if let mute = BotMenuHooks.item(.mute, bot, host) { status.append(mute) }
        if bot.hidden {
            status.append(.action("Show in Bots", "eye") { [weak self] in self?.hide(bot, false) })
            more.append(readToggle)
        } else {
            status.append(readToggle)
            more.append(.action("Hide from Bots", "eye.slash") { [weak self] in self?.hide(bot, true) })
        }
        // [chats-under] What this bot lists under its row (a hidden bot lists nothing).
        if !bot.hidden { status.append(chatsUnderNode(for: bot)) }
        #if targetEnvironment(macCatalyst)
        _ = more   // the iPhone's More ▸, laid out below instead
        // [mac-menu] Owner 2026-11-02 (Mac audit): a right click has room for the whole menu, so the iPhone's More ▸ is
        // laid out flat in separated groups: Edit Bot… beside Bot Info, then the bot's state, then where it sits (Move
        // to Section ▸, its moves, Add to Group, Duplicate), then Hide. The iPhone keeps More ▸ (its menu is a sheet).
        info.insert(.action("Edit Bot…", "pencil") { [weak self] in self?.openInfo(bot, start: .editBot) }, at: 1)
        if let item = BotMenuHooks.item(.watchBrowser, bot, host) { info.append(item) }
        var place: [BotMenuNode] = [BotMenuNode(title: "Move to Section", image: "folder", kind: .submenu(moveNodes(for: bot, editing: editing)))]
        place += pinMoves(for: bot).map { move in .action(move.title, move.image) { [weak self] in self?.movePin(bot, by: move.delta) } }
        place += rowMoves(for: bot).map { move in .action(move.title, move.image) { [weak self] in self?.moveRow(bot, by: move.delta) } }
        if let item = BotMenuHooks.item(.addToGroup, bot, host) { place.append(item) }
        if let item = BotMenuHooks.item(.duplicate, bot, host) { place.append(item) }
        var hide: [BotMenuNode] = []
        if bot.hidden { status.append(readToggle) } else {
            hide.append(.action("Hide from Bots", "eye.slash") { [weak self] in self?.hide(bot, true) })
        }
        var nodes: [BotMenuNode] = tiles.isEmpty ? [] : [BotMenuNode(title: "", kind: .tiles(tiles))]
        nodes += [info, status, place, hide].filter { !$0.isEmpty }.map { BotMenuNode(title: "", kind: .inline($0)) }
        #else
        status.append(BotMenuNode(title: "More", image: "ellipsis.circle", kind: .submenu(more)))

        var nodes: [BotMenuNode] = tiles.isEmpty ? [] : [BotMenuNode(title: "", kind: .tiles(tiles))]
        nodes += [
            BotMenuNode(title: "", kind: .inline(info)),
            BotMenuNode(title: "", kind: .inline(status)),
        ]
        #endif
        if let delete = BotMenuHooks.item(.delete, bot, host) {
            nodes.append(BotMenuNode(title: "", destructive: true, kind: .inline([delete])))
        }
        return nodes
    }

    /// [chats-under] "Chats Under <bot>": Same as All Bots, Off, Pinned Only, Pinned + Recent, and the recent count.
    func chatsUnderNode(for bot: Bot) -> BotMenuNode {
        let own = BotChatsPrefs.own(bot.id)
        let all = BotChatsPrefs.all
        let current = own ?? all
        let children = BotChatsChoice.menuNodes(current: current, own: own != nil, all: all) { [weak self] picked in
            self?.host?.setChatsUnder(picked, for: bot.id)
        }
        var node = BotMenuNode(title: "Chats Under \(bot.name)", image: "bubble.left.and.bubble.right", kind: .submenu(children))
        node.subtitle = current.summary
        node.identifier = "bot-menu.chats-under"
        return node
    }

    func moveNodes(for bot: Bot, editing: any BotEditing) -> [BotMenuNode] {
        let shown = editing.shownSectionId(of: bot)
        var nodes = editing.sectionRecords.map { record in
            BotMenuNode.action(record.name, shown == record.id ? nil : "folder", disabled: shown == record.id,
                               checked: shown == record.id) { [weak self] in self?.move(bot, to: record.id) }
        }
        var tail: [BotMenuNode] = [.action("New Section…", "folder.badge.plus") { [weak self] in self?.newSection(filing: bot) }]
        if shown != nil {
            tail.append(.action("Remove from Section", "tray") { [weak self] in self?.move(bot, to: nil) })
        }
        nodes.append(BotMenuNode(title: "", kind: .inline(tail)))
        return nodes
    }

    /// [bots-groupby] A group chat's Move to Section (filed on this device, as a drop files it). nil without sections.
    func roomMoveNode(for room: GroupRowModel) -> BotMenuNode? {
        guard let records = editing?.sectionRecords, !records.isEmpty,
              let store = (services as? GroupServices)?.groupStore else { return nil }
        let shown = records.contains { $0.id == room.sectionId } ? room.sectionId : nil
        var nodes = records.map { record in
            BotMenuNode.action(record.name, shown == record.id ? nil : "folder", disabled: shown == record.id,
                               checked: shown == record.id) {
                Haptics.play(.light)
                store.setSection(room.id, record.id)
            }
        }
        if shown != nil {
            nodes.append(BotMenuNode(title: "", kind: .inline([.action("Remove from Section", "tray") {
                Haptics.play(.light)
                store.setSection(room.id, nil)
            }])))
        }
        return BotMenuNode(title: "Move to Section", image: "folder", kind: .submenu(nodes))
    }

    func contextMenu(for bot: Bot) -> UIContextMenuConfiguration {
        UIContextMenuConfiguration(identifier: bot.id as NSString, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            return BotMenuNode.uiMenu(self.menuNodes(for: bot), title: bot.name).menu
        }
    }

    // MARK: - Swipes (§5.1; parity §3, `row-swipes.ts`)

    /// Leading: Unread (Read when unread; full swipe) and Pin.
    func leadingActions(for bot: Bot) -> UISwipeActionsConfiguration? {
        let swipes = BotExtrasRules.leading(unread: bot.unread, hasChat: bot.canonicalSessionId != nil, pinned: bot.pinned)
        let actions = swipes.compactMap { swipe -> UIContextualAction? in
            switch swipe {
            case .read, .unread:
                let read = swipe == .read
                let action = UIContextualAction(style: .normal, title: read ? "Read" : "Unread") { [weak self] _, _, done in
                    Haptics.play(.selection)
                    if read { self?.services.markRead(bot) } else { self?.settings.markUnread(bot) }
                    done(true)
                }
                action.image = UIImage(systemName: BotExtrasRules.readSymbol(unread: read, filled: true))
                action.backgroundColor = HQPalette.tint
                action.accessibilityLabel = read ? "Mark as Read" : "Mark as Unread"
                return action
            case .pin, .unpin:
                let pin = UIContextualAction(style: .normal, title: swipe == .pin ? "Pin" : "Unpin") { [weak self] _, _, done in
                    self?.pin(bot, swipe == .pin)
                    done(true)
                }
                pin.image = UIImage(systemName: swipe == .pin ? "pin.fill" : "pin.slash.fill")
                pin.backgroundColor = .systemOrange
                return pin
            default:
                return nil
            }
        }
        let configuration = UISwipeActionsConfiguration(actions: actions)
        configuration.performsFirstActionWithFullSwipe = swipes.first == .read || swipes.first == .unread
        return configuration
    }

    /// Trailing: Mute (full swipe, Always) and More (the row menu as a pull-down from the row, Bot Info first).
    func trailingActions(for bot: Bot) -> UISwipeActionsConfiguration {
        let muted = BotMuteCenter.shared.isMuted(bot.id)
        let item = BotExtrasRules.muteItem(muted: muted)
        let mute = UIContextualAction(style: .normal, title: item.title) { [weak self] _, _, done in
            BotExtras.toggleMute(bot, list: self?.host)
            done(true)
        }
        mute.image = UIImage(systemName: item.image)
        mute.backgroundColor = .systemIndigo
        let more = UIContextualAction(style: .normal, title: "More") { [weak self] _, _, done in
            done(true)
            RowMoreMenu.afterSwipe { [weak self] in
                guard let self, let host = self.host else { return }
                BotMoreSheet.open(self.menuNodes(for: bot), title: bot.name, from: host, row: host.cellView(for: bot.id))
            }
        }
        more.image = UIImage(systemName: "ellipsis.circle.fill")
        more.backgroundColor = .systemGray
        let actions = UISwipeActionsConfiguration(actions: [mute, more])
        actions.performsFirstActionWithFullSwipe = true
        return actions
    }

    // MARK: - Actions

    /// Runs a write; a failure shows the "Couldn’t …" alert whose Try Again runs `retry` (default: the same write).
    /// `failed` runs as the alert shows (an Undo pill for the change goes then).
    func run(_ title: String, _ work: @escaping () async throws -> Void, done: (() -> Void)? = nil, failed: (() -> Void)? = nil,
             retry: (() -> Void)? = nil) {
        Task { [weak self] in
            do {
                try await work()
                done?()
            } catch is CancellationError {
            } catch {
                failed?()
                guard let self else { return }
                FailureAlert.present(error, fallbackTitle: title, from: self.host) { [weak self] in
                    if let retry { retry() } else { self?.run(title, work, done: done, failed: failed) }
                }
            }
        }
    }

    func pin(_ bot: Bot, _ pinned: Bool) {
        guard let editing else { return }
        Haptics.play(.selection)
        run(pinned ? "Couldn’t Pin \(bot.name)" : "Couldn’t Unpin \(bot.name)") { try await editing.setPinned(bot, pinned) }
    }

    /// [a11y] Move Earlier / Move Later for a bot among the pinned tiles (none for a pin in the Pinned section below them).
    func pinMoves(for bot: Bot) -> [(title: String, image: String, delta: Int)] {
        guard bot.pinned, !bot.hidden, let host else { return [] }
        let ids = host.pinnedTileIDs
        return BotExtrasRules.pinMoves(index: ids.firstIndex(of: bot.id), count: ids.count).map { delta in
            (BotExtrasRules.pinMoveTitle(delta), delta < 0 ? "arrow.backward" : "arrow.forward", delta)
        }
    }

    /// The drop's path without the drag: the tile trades places with its neighbour, the order kept on this device.
    func movePin(_ bot: Bot, by delta: Int) {
        guard let host, let editing else { return }
        let before = host.pinnedTileIDs
        guard let from = before.firstIndex(of: bot.id), before.indices.contains(from + delta) else { return }
        let after = PinOrder.moved(before, from: from, to: from + delta)
        host.showTiles(after)
        Haptics.play(.selection)
        editing.placeTiles(before: before, after: after)
        HQAnnounce.say("\(bot.name), \(from + delta + 1) of \(after.count)")
    }

    // MARK: - Manual order [manualorder]

    /// The blocks whose rows Sort By › Manual orders: Pinned, the user sections, the unassigned rows, Hidden (the tiles
    /// keep their own order; search results and group chats are not ordered here).
    static func isOrderedBlock(_ id: BotListSectionID) -> Bool {
        switch id {
        case .pinned, .user, .unassigned, .hidden: true
        case .tiles, .results, .groups, .groupSection, .everything: false
        }
    }

    /// Move Up / Move Down for a row within its block, each only with a neighbour on that side.
    func rowMoves(for bot: Bot) -> [(title: String, image: String, delta: Int)] {
        guard editing != nil, let block = host?.rowBlock(of: bot.id) else { return [] }
        let ids = block.bots.map(\.id)
        return BotRowOrder.moves(index: ids.firstIndex(of: bot.id), count: ids.count).map { delta in
            (BotRowOrder.moveTitle(delta), delta < 0 ? "arrow.up" : "arrow.down", delta)
        }
    }

    /// The row trades places with its neighbour and the list sorts Manual from now on, kept on this device.
    func moveRow(_ bot: Bot, by delta: Int) {
        guard let host, editing != nil, let block = host.rowBlock(of: bot.id) else { return }
        let before = block.bots.map(\.id)
        guard let from = before.firstIndex(of: bot.id), before.indices.contains(from + delta) else { return }
        let after = PinOrder.moved(before, from: from, to: from + delta)
        host.showRows(after, in: block.id, animated: true)
        Haptics.play(.selection)
        placeRows(after, in: block.id)
        host.setNeedsReload()   // the neighbours' Move Up / Move Down follow (Filter is always there: [filters-only])
        HQAnnounce.say("\(bot.name), \(from + delta + 1) of \(after.count)")
    }

    /// [pinned-rows] Pinned Bots › Rows: the pins' rows are in the pins' own order (the tiles' order, `PinOrder`), so
    /// moving one keeps that order and leaves Sort By as it is. Any other block's rows: Sort By › Manual's order.
    func placeRows(_ rows: [String], in block: BotListSectionID) {
        guard let editing else { return }
        if block == .pinned, pinsAsRows {
            editing.placeTiles(before: host?.sectionRows(.pinned) ?? rows, after: rows)
        } else {
            editing.placeRows(rows)
        }
    }

    /// [pinned-rows] The pins are rows of a block with no header at the top (Pinned Bots › Rows).
    var pinsAsRows: Bool { BotPinnedLook.saved == .rows }

    /// [pinned-rows] A pinned row under Pinned Bots › Rows moves only among the pins: the block has no header to show
    /// where it ends, so a drag a little too far down must not file the bot elsewhere.
    func staysAmongPins(_ bot: Bot) -> Bool { pinsAsRows && bot.pinned && !bot.hidden }

    /// Where a row dragged over the list lands among a block's rows, when it will show there: its own block (a new
    /// place), or a block it is filed into (Move to Section, or Pinned = pin) by the drop. nil: the drop files it as
    /// before, or is no drop at all (a pinned or hidden bot filed into a section stays in Pinned or Hidden).
    func rowLanding(_ bot: Bot, at destination: IndexPath?, over point: CGPoint) -> (block: BotListSectionID, rows: [String])? {
        guard let host, let destination, editing != nil, !host.isHeader(at: point),
              let place = host.rowPlace(at: destination, dragging: bot.id) else { return nil }
        let source = host.rowBlock(of: bot.id)?.id
        if place.block != source {
            guard !bot.hidden, !bot.pinned, editing?.isReadOnly == false, target(for: place.block) != nil else { return nil }
        }
        var rows = host.sectionRows(place.block).filter { $0 != bot.id }
        rows.insert(bot.id, at: min(place.index, rows.count))
        return (place.block, rows)
    }

    /// Hide shows its Undo pill with the change (the row moves to Hidden in this frame), not after the gateway answered.
    func hide(_ bot: Bot, _ hidden: Bool) {
        guard let editing else { return }
        Haptics.play(.selection)
        let pill = hidden && !editing.isReadOnly
            ? UndoPill.show(label: "Hidden", wayBack: "Find it under Hidden, below your bots.", in: host) { [weak self] in
                self?.hide(bot, false)
            }
            : nil
        // Show in Bots: the row leaves Hidden for its section or the tiles, often off screen; the list brings it into view.
        if !hidden { host?.reveal(bot.id, leaving: .hidden) }
        run(hidden ? "Couldn’t Hide \(bot.name)" : "Couldn’t Show \(bot.name)", { try await editing.setHidden(bot, hidden) },
            failed: { pill?.dismiss(animated: true) }, retry: { [weak self] in self?.hide(bot, hidden) })
    }

    func move(_ bot: Bot, to section: String?) {
        guard let editing else { return }
        run("Couldn’t Move \(bot.name)", { try await editing.move(bot, toSection: section) }) {
            Haptics.play(.success)
        }
    }

    /// New Section… (from + with no bot, or from a bot's menu, which files it there). The section is made once; only
    /// the filing is a write (its Try Again moves the bot again, never makes a second section).
    func newSection(filing bot: Bot?) {
        guard let host, let editing else { return }
        let others = editing.sectionRecords.map(\.name)
        TextPrompt.present(title: "New Section", placeholder: "e.g. Clients", action: "Create", maxLength: 40,
                           identifier: "section.name", problem: { BotListLayout.sectionNameProblem($0, others: others) },
                           from: host) { [weak self] name in
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, BotListLayout.sectionNameProblem(clean, others: others) == nil, let self else { return }
            if let bot, editing.isReadOnly {
                FailureAlert.present(title: "Couldn’t Move \(bot.name)", reason: BotWriteError.readOnlyReason, from: self.host)
                return
            }
            Haptics.play(.selection)
            let record = editing.appendSection(named: clean)
            self.host?.reload(animated: true)
            if let bot { self.move(bot, to: record.id) }
        }
    }

    func renameSection(_ id: String) {
        guard let host, let editing, let record = editing.sectionRecords.first(where: { $0.id == id }) else { return }
        let others = editing.sectionRecords.filter { $0.id != id }.map(\.name)
        TextPrompt.present(title: "Rename Section", text: record.name, placeholder: record.name, action: "Save", maxLength: 40,
                           requireChange: true, identifier: "section.rename",
                           problem: { BotListLayout.sectionNameProblem($0, others: others) }, from: host) { [weak self] name in
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean != record.name, BotListLayout.sectionNameProblem(clean, others: others) == nil else { return }
            self?.run("Couldn’t Rename \(record.name)") { try await editing.renameSection(id, to: clean) }
        }
    }

    func moveSection(_ id: String, by delta: Int) {
        Haptics.play(.selection)
        editing?.moveSection(id, by: delta)
        host?.reload(animated: true)
    }

    func deleteSection(_ id: String) {
        guard let host, let editing, let record = editing.sectionRecords.first(where: { $0.id == id }) else { return }
        // Every bot filed there, hidden ones too, and every group chat filed there: they all move to Unassigned.
        let rooms = (services as? GroupServices)?.groupStore?.rooms.filter { $0.sectionId == id }.count ?? 0
        guard let message = BotListLayout.deleteMessage(bots: editing.memberCount(ofSection: id), rooms: rooms) else {
            performDelete(id)
            return
        }
        // [botslist] The question is an action sheet anchored on the section's name (`S/ui-bots/section-delete.ts:4-9`), as
        // Delete Bot's is anchored on its row; Cancel is its escape (parity §3 L152).
        let header = host.headerCell(forSection: id)
        let anchor = header.map { CGRect(x: 20, y: $0.bounds.midY - 4, width: 120, height: 28) }
        TextPrompt.confirm(title: "Delete “\(record.name)”?",
                           message: message,
                           action: "Delete Section", style: header == nil ? .alert : .actionSheet, from: host,
                           sourceView: header, sourceRect: anchor) { [weak self] in self?.performDelete(id) }
    }

    /// The section goes and "Deleted “Name” · Undo" shows at once (8 s); the members' writes follow. A failed write puts
    /// the section back, takes the pill away and offers Try Again (which deletes it again, without asking).
    private func performDelete(_ id: String) {
        guard let editing, let record = editing.sectionRecords.first(where: { $0.id == id }) else { return }
        let title = "Couldn’t Delete “\(record.name)”"
        let deletion: SectionDeletion
        do {
            guard let made = try editing.beginDeleteSection(id) else { return }
            deletion = made
        } catch {
            FailureAlert.present(error, fallbackTitle: title, from: host)
            return
        }
        host?.reload(animated: true)
        let pill = UndoPill.show(label: "Deleted “\(record.name)”", duration: 8, in: host) { [weak self] in
            editing.undoDeleteSection(deletion)
            self?.host?.reload(animated: true)
        }
        run(title, { try await editing.finishDeleteSection(deletion) },
            failed: { [weak self] in pill?.dismiss(animated: true); self?.host?.reload(animated: true) },
            retry: { [weak self] in self?.performDelete(id) })
    }

    /// [botsminimal] A user section's menu, held on its name: Rename…, Move Up, Move Down, Delete Section (the ⋯ that
    /// carried it is gone; owner, 2026-10-27).
    func sectionNodes(_ id: String) -> [BotMenuNode] {
        let moves = sectionMenu(id)
        return [
            .action("Rename…", "pencil") { [weak self] in self?.renameSection(id) },
            BotMenuNode(title: "", kind: .inline([
                .action("Move Up", "arrow.up", disabled: !moves.canUp) { [weak self] in self?.moveSection(id, by: -1) },
                .action("Move Down", "arrow.down", disabled: !moves.canDown) { [weak self] in self?.moveSection(id, by: 1) },
            ])),
            BotMenuNode(title: "", kind: .inline([
                .action("Delete Section", "trash", destructive: true) { [weak self] in self?.deleteSection(id) },
            ])),
        ]
    }

    func sectionContextMenu(_ id: String) -> UIContextMenuConfiguration {
        UIContextMenuConfiguration(identifier: "section:\(id)" as NSString, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            let name = self.editing?.sectionRecords.first { $0.id == id }?.name ?? ""
            return BotMenuNode.uiMenu(self.sectionNodes(id), title: name).menu
        }
    }

    func sectionMenu(_ id: String) -> (canUp: Bool, canDown: Bool) {
        let records = editing?.sectionRecords ?? []
        let index = records.firstIndex { $0.id == id } ?? 0
        return (index > 0, index < records.count - 1)
    }

    func openInfo(_ bot: Bot, start: BotInfoStart = .info) {
        guard let host else { return }
        BotInfoSheet.present(bot: bot, from: host, services: services, start: start)
    }

    // MARK: - Drag a bot onto a section (§5.5)

    var canDrag: Bool { !(editing?.sectionRecords.isEmpty ?? true) }

    /// Where a drop on `section` sends a bot: a user section, no section, Pinned (= pin), or the tiles (= pin, and a pin
    /// from the Pinned section below takes the last tile's place). nil: not a target.
    enum DropTarget: Equatable { case section(String), none, pinned, tiles }

    /// [pinned-rows] Under Pinned Bots › Rows the pins' block is no target: with no header, a drop meant for the rows
    /// under it would pin the bot unseen (Pin is in the row's menu and swipe).
    func target(for section: BotListSectionID?) -> DropTarget? {
        switch section {
        case .user(let id)?: .section(id)
        case .unassigned?: DropTarget.none
        case .pinned?: pinsAsRows ? nil : .pinned
        case .tiles?: .tiles
        default: nil
        }
    }

    /// `slot`: the tile under the finger when the drop landed on one.
    func drop(_ bot: Bot, on target: DropTarget, slot: Int? = nil) {
        guard let editing else { return }
        let shown = editing.shownSectionId(of: bot)
        switch target {
        case .tiles where bot.pinned && !bot.hidden:   // a hidden pin is never a tile: it can't take one's place
            // A pin beyond the six tiles swaps in for the tile it was dropped on (UX study #245; the last one when it
            // landed between tiles), which goes to the Pinned section.
            guard let host else { return }
            let before = host.pinnedTileIDs
            guard !before.contains(bot.id), !before.isEmpty else { return }
            Haptics.play(.light)
            var after = before
            after[slot.map { min(max(0, $0), before.count - 1) } ?? before.count - 1] = bot.id
            editing.placeTiles(before: before, after: after)
        case .pinned, .tiles:
            guard !bot.pinned else { return }
            Haptics.play(.light)
            pin(bot, true)
        case .none:
            guard shown != nil else { return }
            Haptics.play(.light)
            move(bot, to: nil)
        case .section(let id):
            guard shown != id else { return }
            Haptics.play(.light)
            move(bot, to: id)
        }
    }

    func setDropTarget(_ section: BotListSectionID?) {
        guard section != dropTarget else { return }
        dropTarget = section
        if section != nil { Haptics.play(.selection) }
        host?.dropTargetChanged()
    }
}

/// What a drag carries: a list row (filed onto a section) or a pinned tile (moved among the tiles).
private let tileDrag = "bots.tile-drag"
/// [groups] A room row being filed among the group chats.
private let roomDrag = "bots.room-drag"

extension BotsOrganizer: UICollectionViewDragDelegate, UICollectionViewDropDelegate {
    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession,
                        at indexPath: IndexPath) -> [UIDragItem] {
        guard let host else { return [] }
        // Rearranging the pinned tiles (`S/ui-bots/pinned-drag.ts`): hold a tile until its menu shows, then move the
        // finger; the menu closes and the tile follows, the other tiles slide out of the way.
        if let bot = host.tileBot(at: indexPath) {
            guard host.tileIDs.count > 1 else { return [] }
            session.localContext = tileDrag
            tileSlot = indexPath.item
            let item = UIDragItem(itemProvider: NSItemProvider())
            item.localObject = bot.id
            return [item]
        }
        // [groups] A room row lifts under the same rule; it is told apart by its drag context.
        if canDrag, let room = host.rowRoom(at: indexPath) {
            session.localContext = roomDrag
            let item = UIDragItem(itemProvider: NSItemProvider(object: room.name as NSString))
            item.localObject = room.id
            draggingRoom = true
            host.setNeedsReload()
            return [item]
        }
        // [manualorder] A row lifts to be filed in a section or, with a neighbour in its block, to take a new place.
        guard let bot = host.rowBot(at: indexPath), canDrag || (host.rowBlock(of: bot.id)?.bots.count ?? 0) > 1 else { return [] }
        let provider = NSItemProvider(object: bot.name as NSString)
        let item = UIDragItem(itemProvider: provider)
        item.localObject = bot.id
        return [item]
    }

    func collectionView(_ collectionView: UICollectionView, dragSessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool {
        session.localContext as? String == tileDrag
    }

    func collectionView(_ collectionView: UICollectionView, dragPreviewParametersForItemAt indexPath: IndexPath) -> UIDragPreviewParameters? {
        guard let cell = collectionView.cellForItem(at: indexPath) else { return nil }
        let parameters = UIDragPreviewParameters()
        if host?.tileBot(at: indexPath) != nil {
            parameters.visiblePath = UIBezierPath(roundedRect: cell.bounds, cornerRadius: 22)
            parameters.backgroundColor = HQPalette.lifted
        } else {
            parameters.visiblePath = UIBezierPath(roundedRect: cell.bounds.insetBy(dx: 6, dy: 2), cornerRadius: 14)
        }
        return parameters
    }

    func collectionView(_ collectionView: UICollectionView, dragSessionDidEnd session: UIDragSession) {
        tileSlot = nil
        if draggingRoom { draggingRoom = false; host?.setNeedsReload() }   // [groups] the empty drop targets go
    }

    func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
        session.localDragSession != nil
    }

    private func isTileDrag(_ session: UIDropSession) -> Bool {
        session.localDragSession?.localContext as? String == tileDrag
    }

    private func isRoomDrag(_ session: UIDropSession) -> Bool {   // [groups]
        session.localDragSession?.localContext as? String == roomDrag
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
                        withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
        if isTileDrag(session) {
            // Only among the tiles; a tick each time the others slide to make room in a new slot.
            guard let destination = destinationIndexPath, host?.isTileSlot(destination) == true else {
                return UICollectionViewDropProposal(operation: .cancel)
            }
            if destination.item != tileSlot {
                tileSlot = destination.item
                Haptics.play(.selection)
            }
            return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
        }
        // The block under the finger (a proposal's destination index path is an insertion point, not what is under it).
        let section = host?.listSectionID(near: session.location(in: collectionView))
        // [groups] A room drops only among group chats; a bot never into them (docs/spec/3x-groups.md §7.11).
        if isRoomDrag(session) {
            let drop = GroupList.drop(room: true, over: section)
            setDropTarget(drop == nil ? nil : section)
            return UICollectionViewDropProposal(operation: drop == nil ? .forbidden : .move, intent: .unspecified)
        }
        // [manualorder] Among a block's rows the others slide apart where it will land; filed into another block, that
        // block's header lights too.
        let location = session.location(in: collectionView)
        let dragged = draggedBot(session.localDragSession?.items.first)
        if let bot = dragged, let landing = rowLanding(bot, at: destinationIndexPath, over: location) {
            setDropTarget(landing.block == host?.rowBlock(of: bot.id)?.id ? nil : landing.block)
            return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
        }
        if let bot = dragged, staysAmongPins(bot) {   // [pinned-rows]
            setDropTarget(nil)
            return UICollectionViewDropProposal(operation: .forbidden, intent: .unspecified)
        }
        let target = target(for: section)
        setDropTarget(target == nil ? nil : section)
        return UICollectionViewDropProposal(operation: target == nil ? .forbidden : .move, intent: .unspecified)
    }

    private func draggedBot(_ item: UIDragItem?) -> Bot? {
        guard let id = item?.localObject as? String else { return nil }
        return services.bots.first { $0.id == id }
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidExit session: UIDropSession) { setDropTarget(nil) }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidEnd session: UIDropSession) { setDropTarget(nil) }

    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        if isTileDrag(coordinator.session) {
            dropTile(coordinator)
            return
        }
        let section = host?.listSectionID(near: coordinator.session.location(in: collectionView)) ?? dropTarget
        setDropTarget(nil)
        if isRoomDrag(coordinator.session) {   // [groups] filed on this iPhone only, no network
            guard case .section(let id)? = GroupList.drop(room: true, over: section),
                  let key = coordinator.items.first?.dragItem.localObject as? String,
                  let store = (services as? GroupServices)?.groupStore, let room = store.room(key), room.sectionId != id else { return }
            Haptics.play(.light)
            store.setSection(key, id)
            return
        }
        // [manualorder] Dropped among a block's rows: it takes that place (Sort By turns Manual), and is filed there first
        // when the block is another one. On a header, or where it can't show, the drop files it as before.
        if let item = coordinator.items.first, let bot = draggedBot(item.dragItem),
           let landing = rowLanding(bot, at: coordinator.destinationIndexPath, over: coordinator.session.location(in: collectionView)) {
            dropRow(bot, landing, item: item, coordinator: coordinator)
            return
        }
        if let bot = draggedBot(coordinator.items.first?.dragItem), staysAmongPins(bot) { return }   // [pinned-rows]
        guard let target = target(for: section),
              let id = coordinator.items.first?.dragItem.localObject as? String,
              let bot = services.bots.first(where: { $0.id == id }) else { return }
        // UX study #245: a pin dropped on a tile takes that tile's place.
        let under = collectionView.indexPathForItem(at: coordinator.session.location(in: collectionView))
            .flatMap { path in host?.isTileSlot(path) == true ? (host?.tileBot(at: path) ?? host?.rowBot(at: path)) : nil }
        drop(bot, on: target, slot: under.flatMap { host?.pinnedTileIDs.firstIndex(of: $0.id) })
    }

    /// [manualorder] A row in its new place: within its block it settles there at once; into another block the filing
    /// write goes out (as a drop on that block always did) and the saved order already has it at the drop's place.
    private func dropRow(_ bot: Bot, _ landing: (block: BotListSectionID, rows: [String]), item: UICollectionViewDropItem,
                         coordinator: UICollectionViewDropCoordinator) {
        guard let host, editing != nil else { return }
        if landing.block == host.rowBlock(of: bot.id)?.id {
            guard landing.rows != host.sectionRows(landing.block) else { return }
            host.showRows(landing.rows, in: landing.block, animated: false)
            if let path = host.indexPath(forRow: bot.id) { coordinator.drop(item.dragItem, toItemAt: path) }
            Haptics.play(.light)
        } else if let target = target(for: landing.block) {
            drop(bot, on: target)
        }
        placeRows(landing.rows, in: landing.block)
        host.setNeedsReload()
    }

    /// The tile settles into its new slot, the order is kept on this device (`S/ui-bots/pinned-order.ts`).
    private func dropTile(_ coordinator: UICollectionViewDropCoordinator) {
        guard let host, let item = coordinator.items.first, let source = item.sourceIndexPath,
              let destination = coordinator.destinationIndexPath, host.isTileSlot(destination) else { return }
        let before = host.tileIDs
        let to = min(destination.item, before.count - 1)
        guard source.item != to, before.indices.contains(source.item) else { return }
        let after = PinOrder.moved(before, from: source.item, to: to)
        host.showTiles(after)
        coordinator.drop(item.dragItem, toItemAt: IndexPath(item: to, section: destination.section))
        Haptics.play(.light)
        editing?.placeTiles(before: before, after: after)
    }
}

/// An empty section's hint row (and the Pinned section's note under its rows).
struct BotSectionHintView: View {
    var text = BotListLayout.emptyHint
    var identifier = "section-hint"

    var body: some View {
        Text(text)
            .font(Font.hq(.footnote))
            .foregroundStyle(Color.hqLabel2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .accessibilityIdentifier(identifier)
    }
}
