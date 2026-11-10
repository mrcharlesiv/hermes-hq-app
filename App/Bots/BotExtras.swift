// Bots row and Bot Info extras (docs/parity-240.md §3; the web app's src/ui-bots/bot-menu.ts, row-swipes.ts,
// bot-actions.ts, build 240): New Chat, Mute/Unmute, Duplicate and Delete Bot in the row menu; the swipes (Unread and Pin
// leading, More and Mute trailing); the first mute's tip; and the picks Bot Info shares with the row. Every write goes
// through `BotEditing`; Mute is this iPhone's own (BotMuteCenter).

import SwiftUI
import UIKit

/// A new chat with a bot and the chat screen for a model (AppModel).
@MainActor protocol BotChatStarting: AnyObject {
    func newChat(for bot: Bot, folder: String?) -> ChatSessionModel
    func makeChatScreen(_ model: any ChatSessionModel) -> UIViewController
}

extension AppModel: BotChatStarting {}

/// What the row and Bot Info offer, as pure rules (unit-tested).
nonisolated enum BotExtrasRules {
    /// Delete Bot: never for the primary profile ("Hermes").
    static func canDelete(isDefault: Bool) -> Bool { !isDefault }

    /// The row menu's and swipe's Mute item (one glyph family, filled, for both: UX study #249).
    static func muteItem(muted: Bool) -> (title: String, image: String) {
        muted ? ("Unmute", "bell.fill") : ("Mute", "bell.slash.fill")
    }

    /// The row menu's Mute durations, as Bot Info offers them (Off is the menu's Unmute). The full swipe stays Always.
    static let menuMuteChoices: [MuteChoice] = [.hour, .hours8, .week, .always]

    /// Mark as Read / Mark as Unread's symbol, the same for a bot and a group chat; a swipe draws the filled one.
    static func readSymbol(unread: Bool, filled: Bool = false) -> String {
        (unread ? "envelope.open" : "envelope.badge") + (filled ? ".fill" : "")
    }

    /// A pinned bot's Move Earlier (-1) and Move Later (+1), each only with a neighbour on that side (`index` of `count`).
    static func pinMoves(index: Int?, count: Int) -> [Int] {
        guard let index, (0..<count).contains(index) else { return [] }
        return [-1, 1].filter { (0..<count).contains(index + $0) }
    }

    static func pinMoveTitle(_ delta: Int) -> String { delta < 0 ? "Move Earlier" : "Move Later" }

    enum Swipe: String, Sendable { case read, unread, pin, unpin, more, mute, unmute }

    /// Leading, outermost first: Unread (full swipe; Read when unread; none for a bot with no chat yet), then Pin.
    static func leading(unread: Bool, hasChat: Bool, pinned: Bool) -> [Swipe] {
        var swipes: [Swipe] = []
        if unread { swipes.append(.read) } else if hasChat { swipes.append(.unread) }
        swipes.append(pinned ? .unpin : .pin)
        return swipes
    }

    /// Trailing, outermost first: Mute (full swipe), then More. Nothing destructive is a swipe here: Delete Bot is in the
    /// menu. [safer-deletes] The app's one rule (owner 2026-11-03): a swipe that deletes always asks first (Sessions,
    /// Kanban, Jobs and Artifacts have one; `PinActions.removeSwipe`).
    static func trailing(muted: Bool) -> [Swipe] { [muted ? .unmute : .mute, .more] }

    /// Bot Info › Conversations: Bot Chat, up to three recent chats, New Chat, then Mark Bot Chat as Read/Unread when
    /// there is a chat ([botinfo-chats] the words name the Bot Chat, owner 2026-11-03; the ids stay).
    static func conversationRows(hasChat: Bool, unread: Bool, recent: Int) -> [String] {
        var rows = ["open"] + (0..<min(3, recent)).map { "recent:\($0)" } + ["new-chat"]
        if hasChat || unread { rows.append(unread ? "read" : "unread") }
        return rows
    }

    /// The delete question (an action sheet; `deleteBotQuestion`).
    static func deleteTitle(_ name: String) -> String { "Delete “\(name)”?" }
    /// `groupChats`: the rooms it sits in, which it leaves (audit 05-16: the question didn't say so).
    static func deleteMessage(_ name: String, groupChats: [String] = []) -> String {
        let leaves: String
        switch groupChats.count {
        case 0: leaves = ""
        case 1: leaves = " It leaves the group chat “\(groupChats[0])”."
        default: leaves = " It leaves its \(groupChats.count) group chats."
        }
        return "\(name)’s memory, skills, settings and chats are deleted from \(HostWord.phrase).\(leaves) This can’t be undone."
    }
}

@MainActor enum BotExtras {
    private static var installed = false

    /// Registers the row menu's New Chat, Mute, Duplicate and Delete Bot (M2Wiring calls it at launch).
    static func install() {
        guard !installed else { return }
        installed = true
        #if DEBUG
        // UI tests: no mutes and the first-mute tip not yet shown (`-HQDebugResetBotMutes YES`).
        if UserDefaults.standard.bool(forKey: "HQDebugResetBotMutes") { BotMuteCenter.shared.resetForTests() }
        #endif
        BotMenuHooks.providers[.newChat] = { bot, host in
            .action("New Chat", "square.and.pencil") { [weak host] in
                (host as? BotsViewController)?.openNewChat(bot)
            }
        }
        BotMenuHooks.providers[.mute] = { bot, host in
            let muted = BotMuteCenter.shared.isMuted(bot.id)
            let item = BotExtrasRules.muteItem(muted: muted)
            guard !muted else {
                return .action(item.title, item.image) { [weak host] in toggleMute(bot, list: host as? BotsViewController) }
            }
            // Mute offers For 1 Hour … Always, as Bot Info does (and Telegram's chat menu); Unmute stays one item.
            return muteMenu(item.title, item.image) { [weak host] choice in mute(bot, choice, list: host as? BotsViewController) }
        }
        BotMenuHooks.providers[.duplicate] = { bot, host in
            .action("Duplicate Bot", "plus.square.on.square") { [weak host] in
                guard let host else { return }
                duplicate(bot, services: (host as? BotsViewController)?.organizer?.services, from: host)
            }
        }
        BotMenuHooks.providers[.delete] = { bot, host in
            guard let editing = ((host as? BotsViewController)?.organizer?.settings)?.botEditing,
                  BotExtrasRules.canDelete(isDefault: editing.isDefault(bot)) else { return nil }
            return .action("Delete Bot", "trash", destructive: true) { [weak host] in
                guard let host else { return }
                let source = (host as? BotsViewController)?.anchorView(for: bot.id)
                #if targetEnvironment(macCatalyst)
                // [mac] Mac polish #32: beside the bot's sidebar row, asked from that row's window (the list may be out
                // of it while another place is on show).
                let presenter = source.flatMap { $0 is UICollectionViewCell ? nil : $0.window?.rootViewController } ?? host
                #else
                let presenter = host
                #endif
                confirmDelete(bot, editing: editing, from: presenter, source: source)
            }
        }
    }

    // MARK: - Picks shared by the row and Bot Info

    /// Mute (Always) or Unmute from a menu or a swipe; the first mute ever explains itself on the row's bell.
    static func toggleMute(_ bot: Bot, list: BotsViewController?) {
        Haptics.play(.selection)
        let first = BotMuteCenter.shared.toggle(bot.id)
        if first, let list { list.showMuteTip(for: bot.id) }
    }

    /// The row menu's Mute: a submenu with one item per duration.
    static func muteMenu(_ title: String, _ image: String, pick: @escaping (MuteChoice) -> Void) -> BotMenuNode {
        BotMenuNode(title: title, image: image, kind: .submenu(BotExtrasRules.menuMuteChoices.map { choice in
            .action(choice.title, nil) { pick(choice) }
        }))
    }

    /// A duration from the row menu; the first mute ever explains itself on the row's bell, as the swipe's does.
    static func mute(_ bot: Bot, _ choice: MuteChoice, list: BotsViewController?) {
        Haptics.play(.selection)
        let first = BotMuteCenter.shared.set(bot.id, choice.mute())
        if first, let list { list.showMuteTip(for: bot.id) }
    }

    /// Bot Info's Mute Notifications pick (its footer says what a mute covers, so no tip follows).
    static func setMute(_ bot: Bot, _ choice: MuteChoice) {
        Haptics.play(.selection)
        if BotMuteCenter.shared.set(bot.id, choice.mute()) { BotMuteCenter.shared.markTipSeen() }
    }

    static func duplicate(_ bot: Bot, services: (any AppServices)?, from host: UIViewController, done: (() -> Void)? = nil) {
        guard let editing = (services as? SettingsServices)?.botEditing else { return }
        let title = "Couldn’t Duplicate \(bot.name)"
        Task { [weak host] in
            do {
                let id = try await editing.duplicate(bot)
                Haptics.play(.success)
                // The copy is named and brought into view (it lands in the original's section, perhaps off screen).
                let name = services?.bots.first { $0.id == id }?.name
                MenusHUD.show(name.map { "Duplicated as “\($0)”" } ?? "Duplicated \(bot.name)", in: host?.view)
                MainTabController.current?.botsViewController.reveal(id)
                done?()
            } catch {
                FailureAlert.present(error, fallbackTitle: title, from: host) { [weak host] in
                    if let host { duplicate(bot, services: services, from: host, done: done) }
                }
            }
        }
    }

    /// Delete Bot, confirmed by an action sheet (no haptic as it shows). Its mute goes with it.
    static func confirmDelete(_ bot: Bot, editing: any BotEditing, from host: UIViewController, source: UIView?,
                              done: (() -> Void)? = nil) {
        guard BotExtrasRules.canDelete(isDefault: editing.isDefault(bot)) else { return }
        TextPrompt.confirm(title: BotExtrasRules.deleteTitle(bot.name),
                           message: BotExtrasRules.deleteMessage(bot.name, groupChats: BotMenuHooks.groupChats?(bot) ?? []),
                           action: "Delete Bot", style: .actionSheet, from: host, sourceView: source) { [weak host] in
            performDelete(bot, editing: editing, from: host, done: done)
        }
    }

    private static func performDelete(_ bot: Bot, editing: any BotEditing, from host: UIViewController?, done: (() -> Void)?) {
        let title = "Couldn’t Delete \(bot.name)"
        Task { [weak host] in
            do {
                try await editing.delete(bot)
                BotMuteCenter.shared.clear(bot.id)
                BotMenuHooks.botDeleted?(bot)   // [groups] its seat leaves its group chats
                Haptics.play(.success)
                MainTabController.current?.leaveDetailChat(profile: bot.id, sessionId: nil)   // [m9/ipad]
                done?()
            } catch {
                FailureAlert.present(error, fallbackTitle: title, from: host) { [weak host] in
                    performDelete(bot, editing: editing, from: host, done: done)
                }
            }
        }
    }

    // MARK: - The Bots list from elsewhere (Bot Info's opens)

    /// The Bots tab's list, its tab selected and anything pushed over it closed (a pick that opens a chat closes the list).
    static func botsList() -> BotsViewController? {
        guard let root = MainTabController.current else { return nil }
        root.select(.bots)
        let list = root.botsViewController
        list.navigationController?.popToRootViewController(animated: false)
        list.endSearchForPick()      // [botslist] no stale search left under the chat
        return list
    }
}

// MARK: - The More swipe: the row menu as an action sheet (as Mail's More)

@MainActor enum BotMoreSheet {
    /// A row's More swipe: the hold menu as a pull-down from the row (`RowMoreMenu`); the sheet only for a row that
    /// isn't on screen.
    static func open(_ nodes: [BotMenuNode], title: String, from host: UIViewController, row: UIView?) {
        if RowMoreMenu.open(BotMenuNode.uiMenu(nodes, title: title).menu, from: row) { return }
        present(nodes, title: title, from: host, source: row)
    }

    static func present(_ nodes: [BotMenuNode], title: String, from host: UIViewController, source: UIView?) {
        let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        add(nodes, to: sheet, host: host, source: source)
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        anchor(sheet, host: host, source: source)
        host.present(sheet, animated: true)
    }

    /// Flattens the menu: tiles, inline groups and More's items become rows; a submenu (Move to Section) opens its own sheet.
    private static func add(_ nodes: [BotMenuNode], to sheet: UIAlertController, host: UIViewController, source: UIView?) {
        for node in nodes {
            switch node.kind {
            case .action(let run):
                guard !node.disabled else { continue }
                sheet.addAction(UIAlertAction(title: node.title, style: node.destructive ? .destructive : .default) { _ in run() })
            case .inline(let children), .tiles(let children), .palette(let children):
                add(children, to: sheet, host: host, source: source)
            case .deferred(let load):
                sheet.addAction(UIAlertAction(title: node.title + "…", style: .default) { [weak host] _ in
                    load { children in
                        guard let host else { return }
                        present(children, title: node.title, from: host, source: source)
                    }
                })
            case .submenu(let children):
                if node.title == "More" {
                    add(children, to: sheet, host: host, source: source)
                } else {
                    sheet.addAction(UIAlertAction(title: node.title + "…", style: .default) { [weak host] _ in
                        guard let host else { return }
                        present(children, title: node.title, from: host, source: source)
                    })
                }
            }
        }
    }

    private static func anchor(_ sheet: UIAlertController, host: UIViewController, source: UIView?) {
        guard let popover = sheet.popoverPresentationController else { return }
        popover.sourceView = source ?? host.view
        if source == nil { popover.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.maxY, width: 0, height: 0) }
    }
}

// MARK: - The first mute's tip ("Muted on This iPhone")

final class MuteTipController: UIViewController, UIPopoverPresentationControllerDelegate {
    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .popover
        popoverPresentationController?.delegate = self
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: MuteTipView())
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        let width: CGFloat = 300
        let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        preferredContentSize = CGSize(width: width, height: ceil(size.height))
        view.accessibilityIdentifier = "mute-tip"
        // [desktoplook3] A solid panel in the Desktop Look, not the popover's glass.
        if Theme.isDesktop { popoverPresentationController?.backgroundColor = ChatPalette.editor }
    }

    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }
}

struct MuteTipView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bell.slash.fill")
                .font(Font.hq(.title3))
                .foregroundStyle(Color.hqTint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Muted on This \(DeviceWord.name)").font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                Text(BotMutes.scope).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .accessibilityElement(children: .combine)
    }
}
