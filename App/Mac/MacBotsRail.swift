// [bots-rail] Owner 2026-11-02 (a mockup of a narrow bar of bot heads down the window's edge, the chat taking the
// rest): folded, the Mac's sidebar is that bar. Its top is the bots as heads, in the Bots list's own order (pinned,
// each section, the rest; hidden bots left out), a faint line between groups; its foot is the other places
// (Sessions, Kanban, Jobs, More…) as folded icons and the button that opens the sidebar and list again. A head opens
// that bot's chat beside the rail, as its row in the list does, with the same unread dot, working arc and badges
// (`BotAvatar`), the same right-click menu (`BotsOrganizer`) and its name under the pointer.
// [rail-more] Owner 2026-11-02 (Mac audit #25, the rail's "not yet"): a head drags to a new place, as a row does in the
// list (the same device-local order, `BotsOrganizer`), with the open sidebar's drop line where it would land; group
// chats are heads too (the list's group tile face), in the list's places for them; and with more than one gateway a
// small switcher sits at the rail's top (the Bots title that carries it is hidden while the rail is folded).

import SwiftUI
import UIKit

#if targetEnvironment(macCatalyst)
enum MacBotsRail {
    /// The face: 44 pt at 100 % (34 on the screen), the size the Desktop Look's tiles draw at the Mac's scale.
    static var face: CGFloat { (44 * MacSidebar.chrome).rounded() }
    /// One head's row: the face and its tile behind it.
    static var rowHeight: CGFloat { (56 * MacSidebar.chrome).rounded() }
    /// [rail-names] With the rail pulled out: the face and the bot's name under it.
    static var namedRowHeight: CGFloat { (80 * MacSidebar.chrome).rounded() }
    /// [rail-tile] The tile behind the open head: the face's own box (4 pt round it), Slack's rounded square.
    static var tileSide: CGFloat { face + 8 }
    /// [mac-layout] The open sidebar's bot row (owner 2026-11-03 "I like the bots in the sidebar"): a face and its name
    /// on one line, Slack's channel rows, at the places' own row height.
    /// [density] Theme › Density › Compact (the iOS look) makes them smaller, as it does the iPhone's Bots rows.
    /// [sidebar-size] Owner 2026-11-10: the bots and the chats under them were "so tiny and hard to read … make them
    /// the proper size". The bots are what the sidebar is for, so their rows take macOS's large sidebar size (15 pt
    /// names, 26 pt faces, 34 pt rows on the screen: 19.5 / 34 / 44 here at 77 %), and their chats the standard one
    /// (13 pt titles in 28 pt rows, what the places below use). Before: 13 pt names, and chat titles at 11.5 pt with
    /// 9.6 pt times, under the Mac's own body size. Compact keeps a step under each.
    static var rowFace: CGFloat { ((MacSidebar.tidy ? (Density.compact ? MacSidebar.scheme.faceCompact : MacSidebar.scheme.face) : (Density.compact ? 22 : 28)) * MacSidebar.chrome).rounded() }
    /// [sidebar-feel] 43.5, not 44: with the 2 pt between rows a bot row then takes 45.5 pt, which is a whole 35 px on
    /// the screen (the Mac draws this app at 77 %). At 46 pt the rows fell 35.4 px apart, so each row's face and name
    /// landed on a different part of a pixel and no two were drawn quite alike (`MacSidebar.openRowHeight`).
    static var sidebarRowHeight: CGFloat {
        MacSidebar.tidy ? MacSidebar.half((Density.compact ? MacSidebar.scheme.botRowCompact : MacSidebar.scheme.botRow) * MacSidebar.chrome) : ((Density.compact ? 32 : 40) * MacSidebar.chrome).rounded()
    }
    static var nameSize: CGFloat { MacSidebar.tidy ? (Density.compact ? MacSidebar.scheme.rowCompact : MacSidebar.scheme.row) : (Density.compact ? 15.5 : 17) }
    /// Where a bot's name and its chats' titles start: clear of the bigger face (which stays centred on the places'
    /// icon column), not the places' own label column, which the face now reaches.
    static var nameLeading: CGFloat {
        guard MacSidebar.tidy else { return MacSidebar.labelLeading }
        return max(MacSidebar.labelLeading, (MacSidebar.iconLeading + MacSidebar.iconColumn / 2 + (rowFace + 4) / 2 + 8).rounded())
    }

    /// [mac-layout] The groups with their list headings, for the open sidebar's section titles (the rail draws a line).
    /// An empty title: a group drawn with no heading (Group By › None's). `block`: the group's list block (a user section's
    /// heading has its menu, and an empty one takes a drop). `showHidden`: Show Hidden Bots, a Hidden group last.
    static func titledGroups(_ sections: [BotListSection], showHidden: Bool = false)
        -> [(title: String, block: BotListSectionID, items: [(block: BotListSectionID, item: Item)])] {
        let titles: [BotListSectionID: String] = Dictionary(sections.map { ($0.id, $0.title ?? "") }, uniquingKeysWith: { a, _ in a })
        return groups(sections, showHidden: showHidden).map { group in
            let block = group.block
            let title: String
            switch block {
            case .tiles: title = BotList.pinnedSectionName
            // [pinned-rows] Pinned Bots › Rows: the pins lead with no heading, as in the list.
            case .pinned: title = titles[block].flatMap { $0.isEmpty ? nil : $0 } == nil ? "" : BotList.pinnedSectionName
            case .groups, .groupSection: title = titles[block].flatMap { $0.isEmpty ? nil : $0 } ?? "Group Chats"
            case .unassigned: title = titles[block].flatMap { $0.isEmpty ? nil : $0 } ?? "Bots"
            // Mac polish #130: Group By › None's one block holds the group chats too: no "Bots" heading over them.
            case .everything: title = ""
            case .hidden: title = "Hidden"
            default: title = titles[block].flatMap { $0.isEmpty ? nil : $0 } ?? "Bots"
            }
            return (title, block, group.items)
        }
    }

    /// One head: a bot, or a group chat (`GroupRowModel`, the list's room).
    enum Item: Equatable {
        case bot(Bot)
        case room(GroupRowModel)

        /// Unique across both kinds: a room's key is not a bot's profile name.
        var key: String {
            switch self {
            case .bot(let bot): bot.id
            case .room(let room): Self.roomKey(room.id)
            }
        }
        static func roomKey(_ key: String) -> String { "room:" + key }
        var name: String {
            switch self {
            case .bot(let bot): bot.name
            case .room(let room): room.name
            }
        }
        var bot: Bot? { if case .bot(let bot) = self { bot } else { nil } }
        var room: GroupRowModel? { if case .room(let room) = self { room } else { nil } }
    }

    /// The list's blocks as the rail draws them (`BotsViewController.railSections`): Hidden left out, the tiles and
    /// the Pinned section's rows one group (all pins), each other block a group of its own, empty ones left out. Each
    /// head keeps its list block, which a drag reorders within (or files it into, `MacSidebar.railDrop`).
    /// [mac] An empty user section stays, with no items (the iPhone's list shows it with its drop hint). Show Hidden
    /// Bots (`showHidden`) keeps the Hidden block too.
    static func groups(_ sections: [BotListSection], showHidden: Bool = false) -> [(block: BotListSectionID, items: [(block: BotListSectionID, item: Item)])] {
        var groups: [(block: BotListSectionID, items: [(block: BotListSectionID, item: Item)])] = []
        for section in sections where section.id != .hidden || showHidden {
            // [bots-groupby] A section's bots and group chats in the list's own order (rooms among the bots by activity).
            let shown = { (hidden: Bool) in section.id == .hidden || !hidden }
            let bots = Dictionary(section.bots.filter { shown($0.hidden) }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let rooms = Dictionary(section.rooms.filter { shown($0.hidden) }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            // [macpass-sidebar] The pins hold the order the person set: the bots in their tile order, then the pinned
            // group chats in theirs (as the iPhone's tiles draw them), never merged by activity, which moved a pinned bot
            // up or down the Pinned group each time a pinned room had a message.
            let rows: [BotListRow] = section.id == .tiles || section.id == .pinned
                ? section.bots.map { .bot($0.id) } + section.rooms.map { .room($0.id) }
                : section.rows()
            let items = rows.compactMap { row -> (block: BotListSectionID, item: Item)? in
                switch row {
                case .bot(let id): bots[id].map { (block: section.id, item: Item.bot($0)) }
                case .room(let id): rooms[id].map { (block: section.id, item: Item.room($0)) }
                }
            }
            guard !items.isEmpty else {
                if case .user = section.id { groups.append((section.id, [])) }
                continue
            }
            if section.id == .pinned, groups.last?.block == .tiles {
                groups[groups.count - 1].items += items   // the pins past the six tiles follow them, no line between
            } else {
                groups.append((section.id, items))
            }
        }
        return groups
    }

    /// What a head's drag carries (only within this app, only onto the rail): its `Item.key`, a bot's or (Mac polish
    /// #31) a group chat's.
    final class DragBox {
        let key: String
        init(key: String) { self.key = key }
    }
}

/// One head in the rail (a bot's, or a group chat's): a button the width of the rail, the face centred, a ring round the
/// face while its chat is on show and a faint one under the pointer (`tile`).
/// [rail-tile] Owner 2026-11-03: not the row-wide box ("you just had a big square block"), not a ring ("I do not like the
/// circle over the bots"): a soft rounded tile fitted to the head, as Slack marks where you are ("feels more purposeful").
final class MacRailHead: UIControl {
    private(set) var item: MacBotsRail.Item
    /// The list block it is drawn from (`MacBotsRail.groups`): where a drag reorders it.
    var block: BotListSectionID = .unassigned
    private let face: UIView & UIContentView
    /// [rail-names] The bot's name under its face, with the rail pulled out (`MacSidebar.railNamed`).
    private let name = UILabel()
    private let named: Bool
    /// [mac-layout] In the open sidebar: face and name on one line, the row-wide mark the places have.
    private let inRow: Bool
    /// [mac-layout] The row's trailing word while the bot works: its running step, else "Working…" (as the Bots rows say).
    private let status = UILabel()
    private var hovered = false
    #if DEBUG
    /// [Mac AAA 2026-11-16] The frame tour: drawn as under the pointer.
    func debugHover(_ on: Bool = true) { hovered = on; recolor() }
    #endif
    /// [rail-tile] The soft tile behind the face: the open chat's mark, fainter under the pointer.
    private let tile = UIView()
    var isMarked = false { didSet { if isMarked != oldValue { recolor() } } }
    /// The bot, for a bot's head (nil for a group chat's).
    var bot: Bot? { item.bot }

    init(item: MacBotsRail.Item, named: Bool = false, inRow: Bool = false) {
        self.item = item
        self.named = named && !inRow
        self.inRow = inRow
        face = Self.configuration(item, size: inRow ? MacBotsRail.rowFace : MacBotsRail.face).makeContentView()
        super.init(frame: .zero)
        accessibilityIdentifier = "mac-rail.head.\(item.key)"
        // [bot-colour] The row's chosen mark follows its bot's colour: a pick in Bot Info, or Chat Bubbles' Bot's Face.
        if inRow {
            for name in [BotMessageColour.didChange, Theme.didChange] {
                NotificationCenter.default.addObserver(self, selector: #selector(botColourChanged), name: name, object: nil)
            }
        }
        isAccessibilityElement = true
        // [Mac AAA 2026-11-16] Its own tile or row fill is its hover: on the rail (72 pt wide) the window's hover scout
        // took it for an icon button and drew a capsule round the tile as well.
        MacHover.drawsOwnHover(self)
        layer.cornerCurve = .continuous
        face.translatesAutoresizingMaskIntoConstraints = false
        face.isUserInteractionEnabled = false
        face.backgroundColor = .clear
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.isUserInteractionEnabled = false
        tile.layer.cornerRadius = 10
        tile.layer.cornerCurve = .continuous
        addSubview(tile)
        addSubview(face)
        if inRow {
            let size = MacBotsRail.rowFace
            name.translatesAutoresizingMaskIntoConstraints = false
            name.isUserInteractionEnabled = false
            name.lineBreakMode = .byTruncatingTail
            addSubview(name)
            status.translatesAutoresizingMaskIntoConstraints = false
            status.isUserInteractionEnabled = false
            status.lineBreakMode = .byTruncatingTail
            // [mac-ui-issues] Owner 2026-11-09 ("when it is working, its tool calls are cut off … we never designed to
            // have those show there"): the step was a trailing word in 42 % of a narrow row ("termi…"). It is the row's
            // second line now, under the name at the row's whole width, and the row is taller while the bot works.
            addSubview(status)
            status.isHidden = true
            tile.isHidden = true   // the row itself carries the mark (`recolor`)
            NSLayoutConstraint.activate([
                // Mac polish #53: the face on the places' icon column, the name where theirs start.
                face.centerXAnchor.constraint(equalTo: leadingAnchor, constant: MacSidebar.iconLeading + MacSidebar.iconColumn / 2),
                face.centerYAnchor.constraint(equalTo: centerYAnchor),
                face.widthAnchor.constraint(equalToConstant: size + 4), face.heightAnchor.constraint(equalToConstant: size + 4),
                name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacBotsRail.nameLeading),
            ])
            // [sidebar-tidy] Owner 2026-11-10 ("I liked your changes you had before", the tidied mockup): "Working…"
            // on the name's own line, at the row's end, so every bot row keeps one height and the list doesn't jump
            // when a bot starts. Only ever that one word, which fits whole: the running step (the words that were cut
            // short there on 2026-11-09) is the row's tooltip.
            if MacSidebar.tidy {
                status.setContentCompressionResistancePriority(.required, for: .horizontal)
                status.setContentHuggingPriority(.required, for: .horizontal)
                NSLayoutConstraint.activate([
                    status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                    status.centerYAnchor.constraint(equalTo: centerYAnchor),
                    name.trailingAnchor.constraint(lessThanOrEqualTo: status.leadingAnchor, constant: -8),
                ])
            } else {
                NSLayoutConstraint.activate([
                    name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
                    status.leadingAnchor.constraint(equalTo: name.leadingAnchor),
                    status.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
                    status.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
                ])
            }
            nameCentre = name.centerYAnchor.constraint(equalTo: centerYAnchor)
            rowHeight = heightAnchor.constraint(equalToConstant: MacBotsRail.sidebarRowHeight)
            nameCentre?.isActive = true
            rowHeight?.isActive = true
            addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
            describe()
            recolor()
            return
        }
        let size = MacBotsRail.face
        NSLayoutConstraint.activate([
            face.centerXAnchor.constraint(equalTo: centerXAnchor),
            // [Mac UI check 2026-11-13] 3 pt above the tile, so the name below it gets room and the head's space to
            // the lines above and below it comes out even.
            named ? face.topAnchor.constraint(equalTo: topAnchor, constant: 3) : face.centerYAnchor.constraint(equalTo: centerYAnchor),
            face.widthAnchor.constraint(equalToConstant: size + 8), face.heightAnchor.constraint(equalToConstant: size + 8),
            tile.centerXAnchor.constraint(equalTo: face.centerXAnchor), tile.centerYAnchor.constraint(equalTo: face.centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: MacBotsRail.tileSide), tile.heightAnchor.constraint(equalToConstant: MacBotsRail.tileSide),
            heightAnchor.constraint(equalToConstant: named ? MacBotsRail.namedRowHeight : MacBotsRail.rowHeight),
        ])
        if named {
            name.translatesAutoresizingMaskIntoConstraints = false
            name.isUserInteractionEnabled = false
            name.textAlignment = .center
            name.lineBreakMode = .byTruncatingTail
            name.adjustsFontSizeToFitWidth = true   // a longer name shrinks a little before it is cut short (`recolor`)
            addSubview(name)
            NSLayoutConstraint.activate([
                // [rail-tile] Under the tile (the face's box), not across its edge. [Mac UI check 2026-11-13] 5 pt: at 2
                // the marked head's tile nearly touched its name.
                name.topAnchor.constraint(equalTo: face.bottomAnchor, constant: 5),
                name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            ])
        }
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
        describe()
        recolor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// [macpass-sidebar] Pressed through accessibility while scrolled out of view: its own action (`Row.accessibilityActivate`).
    override func accessibilityActivate() -> Bool { sendActions(for: .touchUpInside); return true }

    /// The roster changed: the face is drawn again only when this head's row did.
    func update(_ next: MacBotsRail.Item) {
        guard next != item else { return }
        item = next
        face.configuration = Self.configuration(next, size: inRow ? MacBotsRail.rowFace : MacBotsRail.face)
        describe()
        recolor()   // [mac-layout] unread turns the name bold
    }

    /// A pinned tile's face (`tile`: the waking spinner and attention badge; `faceArc`: the working arc), with the
    /// row's unread dot on its corner: the rail has no name beside it to carry a circle. [rail-more] A group chat: the
    /// list's group tile face (`GroupAvatar`), its running dots or unread dot on the same corner.
    private static func configuration(_ item: MacBotsRail.Item, size: CGFloat) -> UIHostingConfiguration<some View, EmptyView> {
        let view: AnyView
        switch item {
        case .bot(let bot):
            view = AnyView(BotAvatar(bot: bot, size: size, tile: true, faceArc: true, presence: true))
        case .room(let room):
            view = AnyView(GroupAvatar(image: room.image, faces: room.faces, size: size)
                .overlay(alignment: .bottomTrailing) {
                    if room.running {
                        WorkingBadge(height: BotAvatar.badgeSize(size)).offset(x: 2, y: 2)
                    } else if room.unread {
                        PresenceDot(height: BotAvatar.presenceSize(size)).offset(x: 1, y: 1)
                    }
                })
        }
        // Mac polish #55: the badges ringed in the sidebar panel's colour, not the page's.
        return UIHostingConfiguration { view.frame(maxWidth: .infinity, maxHeight: .infinity).environment(\.hqBadgeRing, Color(uiColor: MacSidebar.panelColor)) }
        .margins(.all, 0)
    }

    /// [mac-ui-issues] The open sidebar's row: the name's line (lifted while a step shows under it) and the row's height.
    private var nameCentre: NSLayoutConstraint?
    private var rowHeight: NSLayoutConstraint?
    /// The room the working line adds under the name.
    static var workingLine: CGFloat { (16 * MacSidebar.chrome).rounded() }

    private func describe() {
        // [rail-peek] On the rail the peek card names the head at once (with its last message): no system tooltip a
        // second later on top of it. The open sidebar's rows keep theirs (`layoutSubviews`).
        toolTip = nil
        if MacRailPeek.shared.anchor === self { MacRailPeek.shared.show(for: self) }   // a reply landed under the pointer
        name.text = item.name
        if inRow {
            switch item {
            // A bot that waits for you says so, ahead of "Working…": its turn is held on your answer, and the row showed
            // nothing of it (a tester, 2026-11-15: "a bot waiting for an action approval sometimes has no attention dot").
            case .bot(let bot):
                status.text = bot.needsInput?.statusText ?? (bot.isWorking ? (bot.step.flatMap { $0.isEmpty ? nil : $0 } ?? "Working…") : nil)
            case .room(let room): status.text = room.running ? "Working…" : nil
            }
            let working = status.text != nil
            toolTip = working ? status.text : nil   // the whole step, where the line is still too long for the row
            stepTip = toolTip
            setNeedsLayout()   // an idle row's tooltip follows whether its name fits (`layoutSubviews`)
            if MacSidebar.tidy {
                if working, !waits { status.text = "Working…" }   // [sidebar-tidy] the step itself is the tooltip above
                status.isHidden = !working
            } else if working == status.isHidden {
                status.isHidden = !working
                nameCentre?.constant = working ? -Self.workingLine / 2 : 0
                rowHeight?.constant = MacBotsRail.sidebarRowHeight + (working ? Self.workingLine - 4 : 0)
                if window != nil, !HQMotion.reduced {
                    UIView.animate(withDuration: HQMotion.fade, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                        self.superview?.layoutIfNeeded()
                    }
                }
            }
        }
        switch item {
        case .bot(let bot): accessibilityLabel = BotList.accessibilityLabel(bot, time: "")
        case .room(let room):
            accessibilityLabel = GroupRowWords.accessibilityLabel(name: room.name, line: room.line, time: "", unread: room.unread,
                                                                  pinned: room.pinned, muted: room.muted)
        }
    }

    /// The working step's tooltip (`describe`); nil while the bot is idle.
    private var stepTip: String?

    /// [Mac AAA 2026-11-16] A name cut short in the open sidebar ("Maple Revenue…" in a narrow sidebar) had no way to
    /// be read whole: an idle row names its bot under the pointer when its name doesn't fit, as Finder's and Mail's
    /// sidebars do (a place's row always has its tooltip, Mac polish #50). A working row keeps its step there.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard inRow, stepTip == nil else { return }
        let cut = name.bounds.width > 0 && name.intrinsicContentSize.width > name.bounds.width + 0.5
        let tip = cut ? item.name : nil
        if toolTip != tip { toolTip = tip }
    }

    @objc private func hover(_ recognizer: UIHoverGestureRecognizer) {
        hovered = recognizer.state == .began || recognizer.state == .changed
        recolor()
        guard !inRow else { return }
        if recognizer.state == .began, !isHighlighted { MacRailPeek.shared.show(for: self) }
        if !hovered { MacRailPeek.shared.hide(from: self) }
    }

    /// [rail-peek] The peek card's words: the face, the name, and what the row's second line says (the last message,
    /// or what the bot is doing / waiting on), as the Bots list writes it.
    var peekLine: (text: String, tone: BotList.Tone) {
        switch item {
        case .bot(let bot):
            let line = BotList.secondLine(bot)
            if BotList.rowStatus(bot) == .idle, let prefix = bot.previewPrefix?.trimmingCharacters(in: .whitespaces), !prefix.isEmpty,
               bot.preview?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, !line.text.hasPrefix(prefix) {
                return (prefix + " " + line.text, line.tone)
            }
            return line
        case .room(let room):
            let line = room.line.trimmingCharacters(in: .whitespacesAndNewlines)
            return (line.isEmpty ? "No messages yet" : line, .secondary)
        }
    }
    /// [rail-peek] When the line was said ("11:42 AM", "Yesterday"), as the Bots row's time; none while it works or waits.
    var peekTime: String {
        switch item {
        case .bot(let bot): BotList.rowStatus(bot) == .idle ? ListTime.string(bot.lastActive) : ""
        case .room(let room): room.running ? "" : ListTime.string(room.time)
        }
    }
    var peekFace: AnyView {
        let size = MacRailPeek.faceSize
        switch item {
        case .bot(let bot): return AnyView(BotAvatar(bot: bot, size: size, tile: true, faceArc: false, presence: true))
        case .room(let room): return AnyView(GroupAvatar(image: room.image, faces: room.faces, size: size))
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        // A roster redraw takes heads out of the stack and puts them back in the same turn: only a head still out of the
        // window on the next one takes the card away; one put back keeps it, moved to where the head now is.
        guard newWindow == nil, MacRailPeek.shared.anchor === self else { return }
        DispatchQueue.main.async { [weak self] in
            if let self, self.window != nil { MacRailPeek.shared.follow(); return }
            if MacRailPeek.shared.anchor == nil || MacRailPeek.shared.anchor === self { MacRailPeek.shared.hide() }
        }
    }

    // [Mac AAA 2026-11-16] A head's press is its tile in the sidebar's press grey, as a row's press is (the face dimmed
    // to 72 %, the one control on the rail that darkened under a click while the places beside it filled).
    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            recolor()
            if isHighlighted { MacRailPeek.shared.hide(from: self) }   // [rail-peek] a click opens the chat: the card goes
        }
    }

    /// [rail-tile] Neutral, a step lighter than the glass in dark and darker in light (Slack's), whatever the accent: the
    /// head's own colours stay the loudest thing in it.
    private static let tileFill = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.14) : UIColor(white: 0, alpha: 0.09) }
    private static var hoverFill: UIColor { MacHover.rowFill }   // [Mac AAA 2026-11-16] the shared hover (was 6 % / 4 % of its own)

    @objc private func botColourChanged() { recolor() }

    func recolor() {
        accessibilityTraits = isMarked ? [.button, .selected] : .button
        name.textColor = HQPalette.label
        if inRow {
            // [bot-colour] A bot's row is chosen in the colour its chat paints your messages with (owner 2026-11-11:
            // the chosen row follows the colour): the trait `MacSelection.accent` resolves with.
            var colour: MessageColour?
            if case .bot(let bot) = item { colour = BotChatColour.colour(profile: bot.id, head: bot.head) }
            _ = ChatColourTrait.set(colour, on: &traitOverrides)
            // The places' own mark (`MacSelection`): one kind of selection down the whole sidebar.
            backgroundColor = MacSelection.fill(selected: isMarked, pressed: isHighlighted, in: .sidebar) ?? (hovered ? MacSidebar.rowHover : .clear)
            layer.cornerRadius = MacSelection.radius
            name.font = MacSidebar.font(MacBotsRail.nameSize, weight: unread ? .semibold : isMarked ? MacSidebar.scheme.markedWeight : .regular)
            status.font = MacSidebar.font(MacSidebar.tidy ? MacSidebar.scheme.status : 13)
            // Mac polish #52: the accent word on the open row's accent mark read at about 3:1; there it takes the label's.
            status.textColor = isMarked ? HQPalette.label : waits ? HQPalette.orange : HQPalette.tint
            return
        }
        tile.backgroundColor = isMarked ? Self.tileFill : isHighlighted ? MacSelection.grey : hovered ? Self.hoverFill : .clear
        let type = MacSidebar.scheme
        name.font = MacSidebar.font(type.railHead, weight: isMarked ? type.markedWeight : .regular)
        name.minimumScaleFactor = MacSidebar.shrink(name.font, least: type.railHeadLeast / type.railHead)   // Mac polish #54
    }

    /// An unread chat's name is bold in the open sidebar, as Slack's and Mail's are. A bot's by the list's own rule
    /// (`BotList.showsUnread`): not while it works, when what moved its chat is the turn's own steps, not a reply.
    private var unread: Bool {
        switch item {
        case .bot(let bot): BotList.showsUnread(bot)
        case .room(let room): room.unread
        }
    }

    /// The bot waits for the person (an approval, a question): its line says so, in the attention colour.
    private var waits: Bool {
        if case .bot(let bot) = item { return bot.needsInput != nil }
        return false
    }
}

/// The + after the last head: New Bot (and Section or Group Chat), the Bots bar's + menu.
final class MacRailAdd: UIButton {
    private let titled: Bool
    /// [sidebar-feel] The open sidebar's row: the + on the icon column and "New Bot" in the name column, as every row
    /// above it (they sat 3 px right and 3 px left of those), with the rows' own hover and press (it had neither).
    private let plus = UIImageView()
    private let words = UILabel()
    private var pointerOver = false

    /// `titled`: the open sidebar's "+ New Bot" row, leading like the bot rows; else the rail's centred +.
    /// [bots-plus] `label`: the Bots bar's + words (`BotsViewController.createLabel`), so the two +s say the same; it
    /// said "New Bot or Section" while its menu had New Group Chat too.
    init(titled: Bool = false, label: String, menu: @escaping () -> [UIMenuElement]) {
        self.titled = titled
        super.init(frame: .zero)
        accessibilityIdentifier = "mac-rail.add"
        accessibilityLabel = label
        toolTip = titled ? nil : label
        isPointerInteractionEnabled = true
        showsMenuAsPrimaryAction = true
        self.menu = UIMenu(children: [UIDeferredMenuElement.uncached { done in done(menu()) }])
        heightAnchor.constraint(equalToConstant: titled ? MacSidebar.openRowHeight : MacBotsRail.rowHeight).isActive = true   // [sidebar-size] New Bot keeps the places' height
        if titled {
            MacHover.drawsOwnHover(self)
            layer.cornerCurve = .continuous
            plus.contentMode = .center
            words.text = "New Bot"
            words.lineBreakMode = .byTruncatingTail
            for view in [plus, words] as [UIView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                view.isUserInteractionEnabled = false
                addSubview(view)
            }
            NSLayoutConstraint.activate([
                plus.centerXAnchor.constraint(equalTo: leadingAnchor, constant: MacSidebar.iconLeading + MacSidebar.iconColumn / 2),
                plus.centerYAnchor.constraint(equalTo: centerYAnchor),
                words.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacBotsRail.nameLeading),
                words.centerYAnchor.constraint(equalTo: centerYAnchor),
                words.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -MacSidebar.edgeInset),
            ])
            addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
        }
        recolor()
    }

    @objc private func hover(_ recognizer: UIHoverGestureRecognizer) {
        pointerOver = recognizer.state == .began || recognizer.state == .changed
        fill()
    }

    override var isHighlighted: Bool { didSet { if titled { fill() } } }

    /// The rows' own marks: the sidebar's grey under a press (and while its menu is open), the faint fill under the pointer.
    private func fill() {
        backgroundColor = isHighlighted ? MacSelection.grey : pointerOver ? MacSidebar.rowHover : .clear
        layer.cornerRadius = MacSelection.radius
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func recolor() {
        if titled {
            plus.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14 * MacSidebar.chrome, weight: .regular))
            plus.tintColor = HQPalette.label2
            words.font = MacSidebar.font(MacSidebar.placeSize)
            words.textColor = HQPalette.label2
            fill()
            return
        }
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17 * MacSidebar.chrome, weight: .regular))
        config.baseForegroundColor = HQPalette.label2
        configuration = config
    }
}

/// The faint line between the rail's groups (and above its foot).
final class MacRailLine: UIView {
    private let line = UIView()

    /// `wide`: across the open sidebar (its rows' width, a little in), where a short centred dash read as a stray mark.
    init(wide: Bool = false) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        line.translatesAutoresizingMaskIntoConstraints = false
        recolor()
        addSubview(line)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 9),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: HQShape.hairline),
        ])
        // [sidebar-feel] Wide: from the faces' left edge to where the chevrons end, the lines the headings keep.
        NSLayoutConstraint.activate(wide
            ? [line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacSidebar.contentLeading),
               line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacSidebar.edgeInset)]
            : [line.centerXAnchor.constraint(equalTo: centerXAnchor),
               line.widthAnchor.constraint(equalToConstant: (28 * MacSidebar.chrome).rounded())])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func recolor() { line.backgroundColor = HQPalette.paneLine }
}
/// [mac-layout] A heading over a group of bots in the open sidebar (Pinned, a section's name, Bots): small and grey,
/// as Mail's and Slack's are; a click folds the group away or opens it (kept on this device).
final class MacSidebarHeading: UIControl {
    /// [Mac UI check 2026-11-13] The folded groups by a key that stays (`key(for:)`, "tools"), not by the heading's
    /// words: a renamed section opened again, and a section named "Pinned" or "Tools" folded with the built-in one.
    static let foldedKey = "HQMacSidebarFoldedGroupKeys"
    /// The old store, by title: each heading takes its fold from it once (`carryOver`).
    static let legacyFoldedKey = "HQMacSidebarFoldedGroups"
    /// [macpass-sidebar] Read once a launch and held (as `MacSidebar`'s own state): another copy of the app sharing the
    /// defaults file could fold a group under this one, its chevron and rows then disagreeing.
    static var folded: Set<String> {
        get { storedFolded }
        set { storedFolded = newValue; UserDefaults.standard.set(Array(newValue).sorted(), forKey: foldedKey) }
    }
    private static var storedFolded = Set(UserDefaults.standard.stringArray(forKey: foldedKey) ?? [])

    /// A bots' group's lasting key: its block (a user section by its id).
    static func key(for block: BotListSectionID) -> String {
        switch block {
        case .tiles, .pinned: "pinned"
        case .user(let id): "section:" + id
        case .unassigned: "unassigned"
        case .hidden: "hidden"
        case .results: "results"
        case .groups: "groups"
        case .groupSection(let id): "group-section:" + id
        case .everything: "everything"
        }
    }

    let title: String
    /// The fold's key (`foldedKey`).
    let key: String
    /// [mac] A user section's id: its heading has the list's section menu (Rename…, Move Up, Move Down, Delete Section).
    var sectionId: String?
    private let label = UILabel()
    private let chevron = UIImageView()
    private var hovered = false
    var isFolded: Bool { Self.folded.contains(key) }

    /// `below`: room added under the words (Tools' heading over the shorter place rows, `MacSidebar.addTools`).
    init(title: String, key: String, below: CGFloat = 0, toggled: @escaping () -> Void) {
        self.title = title
        self.key = key
        super.init(frame: .zero)
        Self.carryOver(title: title, key: key)
        accessibilityIdentifier = "mac-sidebar.heading.\(title)"
        isAccessibilityElement = true
        MacHover.drawsOwnHover(self)   // [Mac AAA 2026-11-16] its words brighten under the pointer: no fill of the scout's
        accessibilityTraits = [.header, .button]
        label.text = title
        label.translatesAutoresizingMaskIntoConstraints = false
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.contentMode = .center
        for view in [label, chevron] { view.isUserInteractionEnabled = false; addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: MacSidebar.headingHeight + below),
            // [sidebar-feel] On the faces' left edge: at 10 the name started 2 px in from the faces under it.
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacSidebar.contentLeading),
            // 3 under it where it was 5: the name sat exactly midway between the group above and its own (9 px
            // each way); it now leans to its own.
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3 - below),
            label.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -6),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacSidebar.edgeInset),
            chevron.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ])
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        // [sidebar-feel] It is a button and said nothing: the name and chevron brighten under the pointer and dim
        // under a press.
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
        addAction(UIAction { [weak self] _ in
            guard let self else { return }
            var set = Self.folded
            if set.contains(self.key) { set.remove(self.key) } else { set.insert(self.key) }
            Self.folded = set
            AppLog.note("mac", "sidebar group \(self.key) \(set.contains(self.key) ? "folded" : "opened")")
            toggled()
        }, for: .touchUpInside)
        recolor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// [macpass-sidebar] Pressed through accessibility while scrolled out of view: its own action (`Row.accessibilityActivate`).
    override func accessibilityActivate() -> Bool { sendActions(for: .touchUpInside); return true }

    /// A heading folded under the old store (by its title) stays folded under its key; the title is then dropped
    /// from the old store, so it is carried over once.
    private static func carryOver(title: String, key: String) {
        let defaults = UserDefaults.standard
        guard var legacy = defaults.stringArray(forKey: legacyFoldedKey), let at = legacy.firstIndex(of: title) else { return }
        folded = folded.union([key])
        legacy.remove(at: at)
        if legacy.isEmpty { defaults.removeObject(forKey: legacyFoldedKey) } else { defaults.set(legacy, forKey: legacyFoldedKey) }
    }

    @objc private func hover(_ recognizer: UIHoverGestureRecognizer) {
        hovered = recognizer.state == .began || recognizer.state == .changed
        tint()
    }

    override var isHighlighted: Bool { didSet { tint() } }

    private func tint() {
        label.textColor = hovered ? HQPalette.label : HQPalette.label2
        chevron.tintColor = hovered ? HQPalette.label2 : MacSidebar.quietInk   // [Mac AAA 2026-11-16] label 3 was 2.1:1
        let dim: CGFloat = isHighlighted ? 0.55 : 1
        label.alpha = dim
        chevron.alpha = dim
    }

    func recolor() {
        label.font = MacSidebar.font(MacSidebar.sized(13.5, MacSidebar.scheme.heading), weight: .semibold)
        // One drawing, turned: down while the group is open, to the side folded (`showFold` turns it in a click).
        chevron.image = UIImage(systemName: "chevron.down",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 10 * MacSidebar.chrome, weight: .semibold))
        tint()
        showFold(animated: false)
        accessibilityLabel = title
    }

    /// The chevron and the spoken state follow the fold; `animated` turns the chevron (a click on the heading).
    func showFold(animated: Bool) {
        let folded = isFolded
        accessibilityValue = folded ? "Folded" : "Open"
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let turn: CGAffineTransform = folded ? CGAffineTransform(rotationAngle: rightToLeft ? .pi / 2 : -.pi / 2) : .identity
        guard chevron.transform != turn else { return }
        guard animated, window != nil, !HQMotion.reduced else { chevron.transform = turn; return }
        UIView.animate(withDuration: MacSidebar.glide, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
            self.chevron.transform = turn
        }
    }
}

/// [mac-layout] The sidebar's top: Search (⌘K, Open Quickly) and New Chat (⌘N), where Slack, Mail, ChatGPT and Claude
/// put them (owner 2026-11-03, the layout study: "things are where people would expect for them to be"). Open, a
/// field-like button beside a compose button; folded, the two as icons one above the other.
final class MacSidebarTools: UIView {
    private let search = UIButton(type: .system)
    private let compose = UIButton(type: .system)
    private let folded: Bool
    /// [Mac AAA 2026-11-16] How much taller the open sidebar's Search row is than at 100 %: the sidebar starts it that
    /// much higher, so its foot stays level with the chat's bar and the inspector's rule beside it at every UI Scale
    /// (at 150 % it ended 17 pt under them).
    private(set) var levelShift: CGFloat = 0

    /// `named`: the folded rail wide enough for names puts Search and New Chat side by side, one line instead of two.
    init(folded: Bool, named: Bool = false) {
        self.folded = folded
        super.init(frame: .zero)
        accessibilityIdentifier = "mac-sidebar.tools"
        search.accessibilityIdentifier = "mac-sidebar.search"
        search.accessibilityLabel = "Search"
        search.toolTip = "Search or jump to… (⌘K)"
        compose.accessibilityIdentifier = "mac-sidebar.compose"
        compose.accessibilityLabel = "New Chat"
        compose.toolTip = "New Chat (⌘N)"
        // To the app itself, not the first responder: just after a click in the sidebar nothing holds the keys, and an
        // action sent to nobody went nowhere (owner 2026-11-08: "The new chat button … doesn't do anything").
        search.addAction(UIAction { _ in UIApplication.shared.sendAction(KeyCommands.openQuickly, to: UIApplication.shared.delegate, from: nil, for: nil) }, for: .touchUpInside)
        compose.addAction(UIAction { _ in UIApplication.shared.sendAction(KeyCommands.newChat, to: UIApplication.shared.delegate, from: nil, for: nil) }, for: .touchUpInside)
        for button in [search, compose] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.isPointerInteractionEnabled = true
            addSubview(button)
            // [sidebar-feel] Open, each is a well, and the well lightens under the pointer (Search was too wide for the
            // app's own hover and showed nothing; New Chat got a disc inside its rounded square).
            if !folded {
                MacHover.drawsOwnHover(button)
                button.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
            }
        }
        // [rail-actions] Owner 2026-11-19: folded, Search and New Chat read as two more places. They are actions, so
        // they sit small and quiet side by side on one line, a hairline under them before the places (owner, after
        // trying the shared box: "side by side with like the line underneath it").
        let side = ((folded ? 24 : 34) * MacSidebar.chrome).rounded()
        levelShift = folded ? 0 : side - 34
        if folded {
            rule.translatesAutoresizingMaskIntoConstraints = false
            rule.isUserInteractionEnabled = false
            addSubview(rule)
            NSLayoutConstraint.activate([
                search.topAnchor.constraint(equalTo: topAnchor),
                search.trailingAnchor.constraint(equalTo: centerXAnchor, constant: -1),
                compose.leadingAnchor.constraint(equalTo: centerXAnchor, constant: 1),
                compose.centerYAnchor.constraint(equalTo: search.centerYAnchor),
                search.widthAnchor.constraint(equalToConstant: side), search.heightAnchor.constraint(equalToConstant: side),
                compose.widthAnchor.constraint(equalToConstant: side), compose.heightAnchor.constraint(equalToConstant: side),
                rule.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 7),
                rule.leadingAnchor.constraint(equalTo: search.leadingAnchor, constant: 2),
                rule.trailingAnchor.constraint(equalTo: compose.trailingAnchor, constant: -2),
                rule.heightAnchor.constraint(equalToConstant: 1 / max(UIScreen.main.scale, 1)),
                rule.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            ])
        } else {
            NSLayoutConstraint.activate([
                search.topAnchor.constraint(equalTo: topAnchor, constant: 2), search.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
                search.leadingAnchor.constraint(equalTo: leadingAnchor),
                compose.leadingAnchor.constraint(equalTo: search.trailingAnchor, constant: 6),
                compose.trailingAnchor.constraint(equalTo: trailingAnchor),
                compose.centerYAnchor.constraint(equalTo: search.centerYAnchor),
                search.heightAnchor.constraint(equalToConstant: side),
                compose.widthAnchor.constraint(equalToConstant: side), compose.heightAnchor.constraint(equalToConstant: side),
            ])
        }
        recolor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static let well = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.08) : UIColor(white: 0, alpha: 0.06) }
    private static let wellHover = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.13) : UIColor(white: 0, alpha: 0.1) }

    @objc private func hover(_ recognizer: UIHoverGestureRecognizer) {
        guard let button = recognizer.view as? UIButton else { return }
        let over = recognizer.state == .began || recognizer.state == .changed
        button.configuration?.background.backgroundColor = over ? Self.wellHover : Self.well
    }

    func recolor() {
        let well = Self.well
        var find = UIButton.Configuration.plain()
        let glassIcon = UIImage(systemName: "magnifyingglass", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13 * MacSidebar.chrome, weight: .medium))
        if folded { rule.backgroundColor = Self.ruleInk }
        find.baseForegroundColor = HQPalette.label2
        if !folded {
            // [sidebar-intent] The glass and "Search" are views of this box's own, on the sidebar's two columns: the
            // glass in the icon column, the word where every name under it starts. As the button's own image and
            // title they sat 3 px and 10 px short of them, a third and a fourth left edge down the one sidebar.
            find.background.backgroundColor = well
            find.background.cornerRadius = 9
            search.configuration = find
            // At the size the button drew its own image (a button's symbols are a scale up).
            glass.image = glassIcon?.applyingSymbolConfiguration(UIImage.SymbolConfiguration(scale: .large))
            glass.tintColor = HQPalette.label2
            glass.contentMode = .center
            word.text = "Search"
            word.font = MacSidebar.font(MacSidebar.sized(15.5, MacSidebar.scheme.search))
            word.textColor = HQPalette.label2
            shortcut.text = "⌘K"
            shortcut.font = MacSidebar.font(MacSidebar.sized(13, MacSidebar.scheme.shortcut))
            shortcut.textColor = MacSidebar.quietInk   // [Mac AAA 2026-11-16] label 3 was 2.1:1 in light
            if shortcut.superview == nil {
                for view in [glass, word, shortcut] as [UIView] {
                    view.translatesAutoresizingMaskIntoConstraints = false
                    view.isUserInteractionEnabled = false
                    search.addSubview(view)
                }
                wordLeading = word.leadingAnchor.constraint(equalTo: search.leadingAnchor)
                NSLayoutConstraint.activate([
                    glass.centerXAnchor.constraint(equalTo: search.leadingAnchor, constant: MacSidebar.iconLeading + MacSidebar.iconColumn / 2),
                    glass.centerYAnchor.constraint(equalTo: search.centerYAnchor),
                    wordLeading!, word.centerYAnchor.constraint(equalTo: search.centerYAnchor),
                    shortcut.leadingAnchor.constraint(greaterThanOrEqualTo: word.trailingAnchor, constant: 6),
                    shortcut.trailingAnchor.constraint(equalTo: search.trailingAnchor, constant: -10),
                    shortcut.centerYAnchor.constraint(equalTo: search.centerYAnchor),
                ])
                shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)
                // A press dims them, as it dimmed the button's own image and title.
                search.configurationUpdateHandler = { [weak self] button in
                    let ink: CGFloat = button.isHighlighted ? 0.5 : 1
                    self?.glass.alpha = ink
                    self?.word.alpha = ink
                    self?.shortcut.alpha = ink   // [Mac AAA 2026-11-16] the ⌘K stayed lit while the rest dimmed
                }
            }
            wordLeading?.constant = MacBotsRail.nameLeading   // UI Scale moves the column
        } else {
            find.image = glassIcon
            search.configuration = find
        }
        var write = UIButton.Configuration.plain()
        write.image = UIImage(systemName: "square.and.pencil", withConfiguration: UIImage.SymbolConfiguration(pointSize: (folded ? 13 : 15) * MacSidebar.chrome, weight: .medium))
        write.baseForegroundColor = folded ? HQPalette.label2 : HQPalette.label   // [rail-actions] quieter than the places
        if !folded { write.background.backgroundColor = well; write.background.cornerRadius = 9 }
        compose.configuration = write
    }

    /// [rail-actions] Folded: the hairline under Search and New Chat.
    private let rule = UIView()
    private static let ruleInk = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.14) : UIColor(white: 0, alpha: 0.12) }

    private let shortcut = UILabel()
    private let glass = UIImageView()
    private let word = UILabel()
    private var wordLeading: NSLayoutConstraint?
}
/// [chats-under] [mac] One of a bot's chats under its row in the open sidebar (Filter › Chats Under Bots, which the Mac
/// offers on the sidebar's right click, or the bot's own choice), or the "N more" after them, which opens Sessions with
/// the bot picked. The iPhone's Bots rows drawn at the sidebar's sizes: the title where the bot's name starts, the line
/// in the bot's colour down from its face in the chosen style (Settings › Appearance › Chats Under Bots).
final class MacSidebarChat: UIControl {
    enum Kind: Hashable {
        case chat(SessionSummary)
        case more(Int)
    }

    /// What the row draws; it is drawn again only when this changes.
    struct Look: Hashable {
        var kind: Kind
        var botName: String
        var tint: Color
        var last: Bool
        var style: BotChatsStyle
    }

    /// The bot whose chats these are.
    let bot: String
    private(set) var look: Look
    var session: SessionSummary? { if case .chat(let session) = look.kind { session } else { nil } }
    private let content: UIView & UIContentView
    /// The selection and hover mark, from the title's column: the line down the bot's chats stays whole beside it.
    private let backing = UIView()
    private var height: NSLayoutConstraint!
    private var hovered = false
    var isMarked = false { didSet { if isMarked != oldValue { recolor() } } }

    static var rowHeight: CGFloat { ((MacSidebar.tidy ? (Density.compact ? 32 : 36) : (Density.compact ? 28 : 32)) * MacSidebar.chrome).rounded() }   // with the 2 pt the stack no longer puts between chat rows; [sidebar-size]
    static var titleSize: CGFloat { MacSidebar.tidy ? (Density.compact ? MacSidebar.scheme.chatTitleCompact : MacSidebar.scheme.chatTitle) : (Density.compact ? 14 : 15) }
    /// [macpass-sidebar] Type pass: 14.5 (11.2 pt on the screen), the size of a bot's own step line beside its name; at
    /// 14 a chat's time was 10.8 pt, under the sidebar's 11 pt floor and a size of its own.
    static var timeSize: CGFloat { MacSidebar.tidy ? MacSidebar.scheme.time : 12.5 }
    static var lineX: CGFloat { MacSidebar.iconLeading + MacSidebar.iconColumn / 2 }

    init(bot: String, look: Look) {
        self.bot = bot
        self.look = look
        content = Self.configuration(look).makeContentView()
        super.init(frame: .zero)
        isAccessibilityElement = true
        MacHover.drawsOwnHover(self)   // [Mac AAA 2026-11-16] its backing is its hover
        backing.translatesAutoresizingMaskIntoConstraints = false
        backing.isUserInteractionEnabled = false
        backing.layer.cornerCurve = .continuous
        content.translatesAutoresizingMaskIntoConstraints = false
        content.isUserInteractionEnabled = false
        content.backgroundColor = .clear
        addSubview(backing)
        addSubview(content)
        height = heightAnchor.constraint(equalToConstant: Self.height(look))
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor),
            backing.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacBotsRail.nameLeading - 6),
            backing.trailingAnchor.constraint(equalTo: trailingAnchor),
            backing.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            backing.heightAnchor.constraint(equalToConstant: Self.rowHeight - 2),
            height,
        ])
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
        describe()
        recolor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// [macpass-sidebar] Pressed through accessibility while scrolled out of view: its own action (`Row.accessibilityActivate`).
    override func accessibilityActivate() -> Bool { sendActions(for: .touchUpInside); return true }

    /// The sessions or the roster changed: drawn again only when this row's look did.
    func update(_ next: Look) {
        guard next != look else { return }
        look = next
        content.configuration = Self.configuration(next)
        height.constant = Self.height(next)
        describe()
        recolor()
    }

    private static func height(_ look: Look) -> CGFloat { rowHeight + (look.last ? BotChatsMetrics.tail : 0) }

    private static func configuration(_ look: Look) -> UIHostingConfiguration<some View, EmptyView> {
        UIHostingConfiguration { MacSidebarChatContent(look: look) }.margins(.all, 0)
    }

    private func describe() {
        switch look.kind {
        case .chat(let session):
            accessibilityIdentifier = "mac-rail.chat.\(session.id)"
            // [Mac AAA 2026-11-16] A chat with no title yet said nothing (its row was a bare time): it is named as
            // its Sessions row names it (`SessionRowView.title`: the title, else the preview, else "Untitled Chat").
            var shown = session
            shown.title = SessionRowView.title(session)
            accessibilityLabel = BotChatRowView.label(shown, time: ListTime.string(session.lastActive))
            accessibilityHint = nil
            toolTip = shown.title
        case .more(let count):
            accessibilityIdentifier = "mac-rail.more.\(bot)"
            accessibilityLabel = "\(count) more chats with \(look.botName)"
            accessibilityHint = "Opens Sessions with \(look.botName) picked"
            toolTip = nil
        }
    }

    @objc private func hover(_ recognizer: UIHoverGestureRecognizer) {
        hovered = recognizer.state == .began || recognizer.state == .changed
        recolor()
    }

    override var isHighlighted: Bool { didSet { recolor() } }

    func recolor() {
        accessibilityTraits = isMarked ? [.button, .selected] : .button
        // The places' own mark (`MacSelection`), as the bot rows take it.
        backing.backgroundColor = MacSelection.fill(selected: isMarked, pressed: isHighlighted, in: .sidebar) ?? (hovered ? MacSidebar.rowHover : .clear)
        backing.layer.cornerRadius = MacSelection.radius
    }
}

/// The row's words and line (`MacSidebarChat`).
private struct MacSidebarChatContent: View {
    var look: MacSidebarChat.Look

    var body: some View {
        HStack(spacing: 6) {
            switch look.kind {
            case .chat(let session):
                if session.pinned {
                    Image(systemName: "pin.fill").font(Font(MacSidebar.font(MacSidebar.tidy ? 12 : 10.5) as CTFont)).foregroundStyle(Color.hqLabel3)
                }
                Text(SessionRowView.title(session))   // [Mac AAA 2026-11-16] never a blank title
                    .font(Font(MacSidebar.font(MacSidebarChat.titleSize, weight: session.unread ? .semibold : .regular) as CTFont))
                    .foregroundStyle(Color.hqLabel)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // A chat that waits for you is in the middle of its turn: the orange dot outranks the spinner, which
                // hid it every time (a tester, 2026-11-15).
                if session.isRunning, session.status != .needsInput {
                    ProgressView().controlSize(.mini)
                } else if session.unread || session.status == .needsInput {
                    // Orange when it waits for an answer, as the Sessions page marks it.
                    Circle().fill(session.status == .needsInput ? Color.hqOrange : Color.hqTint)
                        .frame(width: 7 * MacSidebar.chrome, height: 7 * MacSidebar.chrome)
                }
                Text(ListTime.string(session.lastActive))
                    .font(Font(MacSidebar.font(MacSidebarChat.timeSize) as CTFont))
                    .monospacedDigit()
                    .foregroundStyle(Color.hqLabel2)
                    .lineLimit(1)
                    .fixedSize()
            case .more(let count):
                Text("\(count) more").font(Font(MacSidebar.font(MacSidebar.tidy ? MacSidebar.scheme.more : 14, weight: MacSidebar.tidy ? MacSidebar.scheme.moreWeight : .medium) as CTFont))
                Image(systemName: "chevron.right").font(Font(MacSidebar.font(11, weight: .semibold) as CTFont))
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(Color.hqTintText)
        .padding(.leading, MacBotsRail.nameLeading)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, minHeight: MacSidebarChat.rowHeight, maxHeight: MacSidebarChat.rowHeight)
        .overlay(alignment: .bottom) {
            if look.style == .dividers, !look.last, case .chat = look.kind {
                Rectangle().fill(Color.hqStroke).frame(height: HQShape.line(0.5)).padding(.leading, MacBotsRail.nameLeading)
            }
        }
        .padding(.bottom, look.last ? BotChatsMetrics.tail : 0)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(alignment: .leading) {
            BotChatsLine(last: look.last, tint: look.tint, lineX: MacSidebarChat.lineX, style: look.style,
                         more: { if case .more = look.kind { true } else { false } }())
        }
        .accessibilityHidden(true)   // the control speaks for it
    }
}
/// [mac] An empty section's one line under its heading (the iPhone's list shows the same hint), where a dragged bot can
/// be dropped to file it there.
final class MacSidebarEmptyHint: UIView {
    let sectionId: String
    private let label = UILabel()

    init(sectionId: String) {
        self.sectionId = sectionId
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = BotListLayout.emptyHint
        label.numberOfLines = 0
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacSidebar.contentLeading),   // [sidebar-feel] under its heading
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacSidebar.edgeInset),
        ])
        recolor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func recolor() {
        label.font = MacSidebar.font(MacSidebar.sized(12.5, MacSidebar.scheme.hint))
        label.textColor = MacSidebar.quietInk   // [Mac AAA 2026-11-16] label 3 was 2.1:1 in light
    }
}

/// [rail-peek] Owner 2026-11-18 (a Grok picture: a card beside a head reading "Grok Bot / Want to grab 25 minutes later
/// today?"): the pointer on a head of the folded rail shows, at once, a card beside it with the bot's face, its name and
/// its last message (or what it's doing / waiting on, in the row's colour), so a glance down the rail reads each chat
/// without opening it. One card for the window: it follows the pointer from head to head, stays with its head as the
/// rail scrolls, and goes when the pointer leaves, a click opens the chat, or the head leaves the window. It takes no
/// clicks (the pointer is on the head, never on it). VoiceOver already reads the same words from the head's label.
@MainActor final class MacRailPeek {
    static let shared = MacRailPeek()
    /// The head it is beside (weak: a roster redraw can drop the head under the pointer).
    private(set) weak var anchor: MacRailHead?
    private var card: Card?

    /// The face in the card's title line.
    static var faceSize: CGFloat { (32 * MacSidebar.chrome).rounded() }

    func show(for head: MacRailHead) {
        guard let window = head.window else { return }
        let card: Card
        if let existing = self.card, existing.window === window {
            card = existing
        } else {
            self.card?.removeFromSuperview()
            card = Card()
            window.addSubview(card)
            self.card = card
        }
        let moving = anchor != nil && anchor !== head && !card.isHidden && card.alpha > 0.5
        anchor = head
        card.fill(name: head.item.name, time: head.peekTime, line: head.peekLine, face: head.peekFace)
        window.bringSubviewToFront(card)
        let from = card.center
        place()
        guard anchor === head else { return }   // its head is scrolled out of sight
        if moving {
            // Head to head down the rail it stays up and glides to the next one, its words already swapped.
            let to = card.center
            card.center = from
            HQMotion.spring(duration: 0.3, damping: 0.86, changes: { card.center = to; card.alpha = 1; card.transform = .identity },
                            reduced: { card.center = to; card.alpha = 1; card.transform = .identity })
            return
        }
        if card.isHidden || card.alpha < 0.05 {
            // At once, never a wait (the system tooltip's wait is what it replaces): it rises from the rail's side,
            // a few points in and a touch small, as a macOS popover settles. Reduce Motion: a fade alone.
            card.isHidden = false
            card.alpha = 0
            card.transform = HQMotion.reduced ? .identity : CGAffineTransform(translationX: -6, y: 0).scaledBy(x: 0.97, y: 0.97)
        }
        HQMotion.spring(duration: 0.32, damping: 0.84, changes: {
            card.alpha = 1
            card.transform = .identity
        }, reduced: { card.alpha = 1 })
    }

    /// The rail scrolled under the pointer: the card keeps to its head.
    func follow() { if anchor != nil { place() } }

    /// The pointer left `head` (or it was clicked or removed): the card goes, unless it has moved to another head.
    func hide(from head: MacRailHead) {
        guard anchor === head || anchor == nil else { return }
        hide()
    }

    func hide() {
        anchor = nil
        guard let card, !card.isHidden else { return }
        UIView.animate(withDuration: HQMotion.quick, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseIn]) {   // motion-ok: opacity only
            card.alpha = 0
        } completion: { _ in
            if self.anchor == nil { card.isHidden = true; card.transform = .identity }
        }
    }

    /// Beside its head: 8 pt past the head's tile, centred on it, kept inside the window. A head scrolled out of the
    /// rail's view takes the card with it.
    func place() {
        guard let head = anchor, let card, let window = card.window, head.window === window else { hide(); return }
        let tile = head.convert(head.bounds, to: window)
        if !Self.visible(head, in: window) { hide(); return }
        let size = card.fit(maxWidth: min(Card.maxWidth, window.bounds.width - tile.maxX - 24))
        let tileRight = head.convert(CGPoint(x: head.bounds.midX + MacBotsRail.tileSide / 2, y: 0), to: window).x
        var y = tile.midY - size.height / 2
        y = min(max(y, window.safeAreaInsets.top + 6), window.bounds.height - size.height - 6)
        // Clear of the rail's own edge, so it reads as lifted over the chat rather than tucked half under the rail.
        var rail: UIView? = head.superview
        while let view = rail, !(view is MacSidebar) { rail = view.superview }
        let railRight = rail.map { $0.convert($0.bounds, to: window).maxX } ?? tileRight
        let frame = CGRect(x: (max(tileRight + 10, railRight + 10)).rounded(), y: y.rounded(), width: size.width, height: size.height)
        card.bounds = CGRect(origin: .zero, size: frame.size)
        card.center = CGPoint(x: frame.midX, y: frame.midY)
    }

    /// The head's middle is inside every clipping view between it and the window (the rail's scroll view).
    private static func visible(_ head: UIView, in window: UIWindow) -> Bool {
        let middle = CGPoint(x: head.bounds.midX, y: head.bounds.midY)
        var view = head.superview
        while let next = view, next !== window {
            if next.clipsToBounds, !next.bounds.contains(head.convert(middle, to: next)) { return false }
            view = next.superview
        }
        return true
    }

    #if DEBUG
    /// The card's frame and words, for the rail tour's log.
    var debugState: String {
        guard let card, !card.isHidden, card.alpha > 0 else { return "peek: none" }
        return "peek: \(card.debugWords) frame \(card.frame.integral)"
    }
    #endif

    /// The card: a raised panel beside the rail. Two shadows (a wide soft one for its lift, a tight one where it meets
    /// the window), a hairline edge, and a faint light along its top edge in dark so it reads as a surface, not a hole.
    /// The face, the name and the time on one line, the message under it (three lines at most).
    final class Card: UIView {
        static var maxWidth: CGFloat { (420 * MacSidebar.chrome).rounded() }
        static var minWidth: CGFloat { (250 * MacSidebar.chrome).rounded() }
        private let panel = UIView()
        private let contact = UIView()
        private let sheen = CAGradientLayer()
        private let face = UIView()
        private var faceHost: (UIView & UIContentView)?
        private let name = UILabel()
        private let time = UILabel()
        private let line = UILabel()
        private var inset: CGFloat { (18 * MacSidebar.chrome).rounded() }
        private var gap: CGFloat { (10 * MacSidebar.chrome).rounded() }
        private var lead: CGFloat { (10 * MacSidebar.chrome).rounded() }
        private var radius: CGFloat { (20 * MacSidebar.chrome).rounded() }

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            accessibilityElementsHidden = true   // the head's own label already reads these words
            accessibilityIdentifier = "mac-rail.peek"
            backgroundColor = .clear
            // The lift: wide and soft, below the card.
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOffset = CGSize(width: 0, height: 10)
            layer.shadowRadius = 24
            // Where it meets the window: tight.
            contact.layer.shadowColor = UIColor.black.cgColor
            contact.layer.shadowOffset = CGSize(width: 0, height: 1)
            contact.layer.shadowRadius = 2
            contact.layer.cornerCurve = .continuous
            contact.backgroundColor = .clear
            addSubview(contact)
            panel.layer.cornerCurve = .continuous
            panel.layer.borderWidth = 1 / max(UIScreen.main.scale, 1)
            panel.clipsToBounds = true
            addSubview(panel)
            sheen.startPoint = CGPoint(x: 0.5, y: 0)
            sheen.endPoint = CGPoint(x: 0.5, y: 1)
            panel.layer.addSublayer(sheen)
            name.numberOfLines = 1
            name.lineBreakMode = .byTruncatingTail
            time.numberOfLines = 1
            time.setContentCompressionResistancePriority(.required, for: .horizontal)
            line.numberOfLines = 3
            line.lineBreakMode = .byTruncatingTail
            for view in [face, name, time, line] as [UIView] { panel.addSubview(view) }
            registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (card: Card, _: UITraitCollection) in card.recolor() }
            recolor()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        /// White in light; in dark a raised grey a step over the window's own, as macOS draws a popover.
        private static let fill = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.19, alpha: 1) : .white }
        private static let edge = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.14) : UIColor(white: 0, alpha: 0.09) }

        private func recolor() {
            let dark = traitCollection.userInterfaceStyle == .dark
            panel.backgroundColor = Self.fill
            panel.layer.borderColor = Self.edge.resolvedColor(with: traitCollection).cgColor
            layer.shadowOpacity = dark ? 0.45 : 0.14
            contact.layer.shadowOpacity = dark ? 0.5 : 0.1
            // The top's faint light: dark only (white on white is nothing).
            sheen.colors = [UIColor(white: 1, alpha: dark ? 0.06 : 0).cgColor, UIColor(white: 1, alpha: 0).cgColor]
            time.textColor = HQPalette.label3
        }

        private var tone: BotList.Tone = .secondary

        func fill(name text: String, time stamp: String, line words: (text: String, tone: BotList.Tone), face view: AnyView) {
            name.text = text
            name.font = MacSidebar.font(18, weight: .semibold)
            name.textColor = HQPalette.label
            time.text = stamp
            time.font = MacSidebar.font(14)
            time.isHidden = stamp.isEmpty
            // Hermes previews are one line already (the gateway's cut); breaks in a status read as spaces.
            let style = NSMutableParagraphStyle()
            style.lineSpacing = (3 * MacSidebar.chrome).rounded()
            style.lineBreakMode = .byTruncatingTail
            tone = words.tone
            let colour: UIColor = switch words.tone {
            case .secondary: HQPalette.label2
            case .tint: HQPalette.tint
            case .attention: HQPalette.orange
            }
            line.attributedText = NSAttributedString(string: words.text.replacingOccurrences(of: "\n", with: " "), attributes: [
                .font: MacSidebar.font(17), .foregroundColor: colour, .paragraphStyle: style,
            ])
            let configuration = UIHostingConfiguration { view.frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.hqBadgeRing, Color(uiColor: Self.fill)) }.margins(.all, 0)
            if let faceHost {
                faceHost.configuration = configuration
            } else {
                let host = configuration.makeContentView()
                host.backgroundColor = .clear
                host.isUserInteractionEnabled = false
                face.addSubview(host)
                faceHost = host
            }
            recolor()
            setNeedsLayout()
        }

        /// Its size for words up to `maxWidth` wide (as narrow as they let it be, never under `minWidth`).
        func fit(maxWidth: CGFloat) -> CGSize {
            let side = MacRailPeek.faceSize
            let inner = max(Self.minWidth - inset * 2, maxWidth - inset * 2)
            let timeWidth = time.isHidden ? 0 : time.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: side)).width.rounded(.up) + gap
            let nameWidth = name.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: side)).width.rounded(.up)
            let lineSize = line.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude))
            let width = min(inner, max(Self.minWidth - inset * 2, side + gap + nameWidth + timeWidth, lineSize.width.rounded(.up)))
            let lineHeight = line.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height.rounded(.up)
            let height = inset + side + (line.attributedText?.length ?? 0 > 0 ? lead + lineHeight : 0) + inset
            let size = CGSize(width: width + inset * 2, height: height)
            bounds.size = size
            layoutSubviews()
            return size
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            panel.frame = bounds
            panel.layer.cornerRadius = radius
            contact.frame = bounds
            contact.layer.cornerRadius = radius
            let path = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
            layer.shadowPath = path
            contact.layer.shadowPath = path
            sheen.frame = CGRect(x: 0, y: 0, width: bounds.width, height: min(bounds.height, 28))
            let side = MacRailPeek.faceSize
            face.frame = CGRect(x: inset, y: inset, width: side, height: side)
            faceHost?.frame = face.bounds
            let nameHeight = name.font.lineHeight.rounded(.up)
            var right = bounds.width - inset
            if !time.isHidden {
                let width = time.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: side)).width.rounded(.up)
                let height = (time.font?.lineHeight ?? 16).rounded(.up)
                // On the name's baseline, not its middle: the smaller time sits on the same line of type.
                let baseline = inset + (side - nameHeight) / 2 + name.font.ascender
                time.frame = CGRect(x: right - width, y: (baseline - (time.font?.ascender ?? 12)).rounded(), width: width, height: height)
                right -= width + gap
            }
            name.frame = CGRect(x: inset + side + gap, y: inset + (side - nameHeight) / 2, width: max(0, right - inset - side - gap), height: nameHeight)
            let top = inset + side + lead
            line.frame = CGRect(x: inset, y: top, width: bounds.width - inset * 2, height: max(0, bounds.height - top - inset))
        }

        #if DEBUG
        var debugWords: String { "\"\(name.text ?? "")\" \(time.text ?? "") / \"\(line.text ?? "")\" (\(tone))" }
        #endif
    }
}
#endif
