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
    static var rowFace: CGFloat { ((MacSidebar.tidy ? (Density.compact ? 28 : 34) : (Density.compact ? 22 : 28)) * MacSidebar.chrome).rounded() }
    /// [sidebar-feel] 43.5, not 44: with the 2 pt between rows a bot row then takes 45.5 pt, which is a whole 35 px on
    /// the screen (the Mac draws this app at 77 %). At 46 pt the rows fell 35.4 px apart, so each row's face and name
    /// landed on a different part of a pixel and no two were drawn quite alike (`MacSidebar.openRowHeight`).
    static var sidebarRowHeight: CGFloat {
        MacSidebar.tidy ? MacSidebar.half((Density.compact ? 38 : 43.5) * MacSidebar.chrome) : ((Density.compact ? 32 : 40) * MacSidebar.chrome).rounded()
    }
    static var nameSize: CGFloat { MacSidebar.tidy ? (Density.compact ? 18 : 19.5) : (Density.compact ? 15.5 : 17) }
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
            let items = section.rows().compactMap { row -> (block: BotListSectionID, item: Item)? in
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
        toolTip = named || inRow ? nil : item.name   // [rail-names] the name is on show already
        name.text = item.name
        if inRow {
            switch item {
            case .bot(let bot): status.text = bot.isWorking ? (bot.step.flatMap { $0.isEmpty ? nil : $0 } ?? "Working…") : nil
            case .room(let room): status.text = room.running ? "Working…" : nil
            }
            let working = status.text != nil
            toolTip = working ? status.text : nil   // the whole step, where the line is still too long for the row
            if MacSidebar.tidy {
                if working { status.text = "Working…" }   // [sidebar-tidy] the step itself is the tooltip above
                status.isHidden = !working
            } else if working == status.isHidden {
                status.isHidden = !working
                nameCentre?.constant = working ? -Self.workingLine / 2 : 0
                rowHeight?.constant = MacBotsRail.sidebarRowHeight + (working ? Self.workingLine - 4 : 0)
                if window != nil, !HQMotion.reduced {
                    UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
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

    @objc private func hover(_ recognizer: UIHoverGestureRecognizer) {
        hovered = recognizer.state == .began || recognizer.state == .changed
        recolor()
    }

    override var isHighlighted: Bool { didSet { face.alpha = isHighlighted && !inRow ? 0.72 : 1; if inRow { recolor() } } }   // a tile's press

    /// [rail-tile] Neutral, a step lighter than the glass in dark and darker in light (Slack's), whatever the accent: the
    /// head's own colours stay the loudest thing in it.
    private static let tileFill = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.14) : UIColor(white: 0, alpha: 0.09) }
    private static let hoverFill = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.06) : UIColor(white: 0, alpha: 0.04) }

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
            backgroundColor = MacSelection.fill(selected: isMarked, pressed: isHighlighted, in: .sidebar) ?? (hovered ? Self.rowHover : .clear)
            layer.cornerRadius = MacSelection.radius
            name.font = MacSidebar.font(MacBotsRail.nameSize, weight: isMarked || unread ? .semibold : .regular)
            status.font = MacSidebar.font(MacSidebar.tidy ? 14.5 : 13)
            // Mac polish #52: the accent word on the open row's accent mark read at about 3:1; there it takes the label's.
            status.textColor = isMarked ? HQPalette.label : HQPalette.tint
            return
        }
        tile.backgroundColor = isMarked ? Self.tileFill : hovered ? Self.hoverFill : .clear
        name.font = MacSidebar.font(14.5, weight: isMarked ? .semibold : .regular)
        name.minimumScaleFactor = MacSidebar.shrink(name.font, least: 0.85)   // Mac polish #54
    }

    private static let rowHover = UIColor { traits in UIColor.label.resolvedColor(with: traits).withAlphaComponent(0.05) }

    /// An unread chat's name is bold in the open sidebar, as Slack's and Mail's are.
    private var unread: Bool {
        switch item {
        case .bot(let bot): bot.unread
        case .room(let room): room.unread
        }
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

/// [rail-more] With more than one gateway, the rail's top: the Bots title's gateway menu (`GatewayTitleSwitcher`), its
/// gateways with "In Use" / "N New", Add Gateway… and Manage Gateways…. Faces alone it is the network symbol (the
/// Settings › Gateway icon) with a news dot when another gateway has news, named under the pointer; with the names it
/// is the gateway's name and a chevron, as the title's subtitle reads.
final class MacRailGateway: UIButton {
    private let dot = UIView()
    private let named: Bool
    var isNamed: Bool { named }
    // [gateway-row] Owner 2026-11-09 on Mac 915: the switcher "looks super cheap" (it was a line of small grey words
    // and a chevron). With the names it is a row of the sidebar now, as the account switchers of Mac apps are: a tinted
    // tile with the network symbol, the gateway's name in the rows' own size and weight, and the up-down chevrons of a
    // pop-up at its end. The whole row lights under the pointer and opens the menu.
    private let tile = UIView()
    private let glyph = UIImageView()
    private let name = UILabel()
    private let arrows = UIImageView()
    private let backing = UIView()

    init(named: Bool, menu: @escaping () -> UIMenu?) {
        self.named = named
        super.init(frame: .zero)
        accessibilityIdentifier = "mac-rail.gateway"
        accessibilityHint = "Shows your gateways."
        isPointerInteractionEnabled = true
        showsMenuAsPrimaryAction = true
        self.menu = UIMenu(title: "Gateways", children: [UIDeferredMenuElement.uncached { done in done(menu()?.children ?? []) }])
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4)
        if named {
            buildRow()
        } else {
            config.image = UIImage(systemName: "network", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17 * MacSidebar.chrome, weight: .regular))
        }
        configuration = config
        dot.layer.cornerRadius = Self.dotSize / 2
        dot.isUserInteractionEnabled = false
        addSubview(dot)
        heightAnchor.constraint(equalToConstant: ((named ? 40 : 36) * MacSidebar.chrome).rounded()).isActive = true
        recolor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildRow() {
        let chrome = MacSidebar.chrome
        backing.layer.cornerRadius = (8 * chrome).rounded()
        backing.layer.cornerCurve = .continuous
        backing.alpha = 0
        tile.layer.cornerRadius = (7 * chrome).rounded()
        tile.layer.cornerCurve = .continuous
        glyph.image = UIImage(systemName: "network", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13 * chrome, weight: .semibold))
        glyph.contentMode = .center
        name.font = MacSidebar.font(MacSidebar.placeSize, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.adjustsFontSizeToFitWidth = true
        name.minimumScaleFactor = MacSidebar.shrink(name.font, least: 0.85)
        arrows.image = UIImage(systemName: "chevron.up.chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11 * chrome, weight: .semibold))
        arrows.contentMode = .center
        arrows.setContentHuggingPriority(.required, for: .horizontal)
        arrows.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [backing, tile, glyph, name, arrows] {
            view.isUserInteractionEnabled = false
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let side = (26 * chrome).rounded()
        NSLayoutConstraint.activate([
            backing.leadingAnchor.constraint(equalTo: leadingAnchor), backing.trailingAnchor.constraint(equalTo: trailingAnchor),
            backing.topAnchor.constraint(equalTo: topAnchor, constant: 2), backing.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: (6 * chrome).rounded()),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: side), tile.heightAnchor.constraint(equalToConstant: side),
            glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor), glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            name.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: (9 * chrome).rounded()),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: arrows.leadingAnchor, constant: -6),
            arrows.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(8 * chrome).rounded()),
            arrows.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
    }

    @objc private func hovered(_ hover: UIHoverGestureRecognizer) {
        let over = (hover.state == .began || hover.state == .changed) && isEnabled
        guard (backing.alpha > 0.5) != over else { return }
        UIView.animate(withDuration: over ? 0 : 0.06, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {   // motion-ok: hover fill fades opacity only
            self.backing.alpha = over ? 1 : 0
        }
    }

    /// `title`: the gateway in use (or "Switching to X…"); `news`: another gateway has news; `busy`: a switch runs.
    func show(title: String, news: Bool, busy: Bool) {
        if named {
            name.text = title
            name.alpha = busy ? 0.6 : 1
        }
        toolTip = named ? nil : title
        accessibilityLabel = news ? "Gateway, \(title), news on another gateway" : "Gateway, \(title)"
        dot.isHidden = !news
        setNeedsLayout()
        isEnabled = !busy
        recolor()
    }

    private static var dotSize: CGFloat { (7 * MacSidebar.chrome).rounded() }

    /// The news dot: on the symbol's top corner (the tile's, with the names), as a folded place's count dot sits.
    override func layoutSubviews() {
        super.layoutSubviews()
        let symbol = named ? tile.frame : (imageView?.frame ?? CGRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16))
        dot.frame = CGRect(x: symbol.maxX - Self.dotSize / 2 - 1, y: symbol.minY - 1, width: Self.dotSize, height: Self.dotSize)
        bringSubviewToFront(dot)
    }

    func recolor() {
        var config = configuration ?? .plain()
        config.baseForegroundColor = HQPalette.label2
        configuration = config
        dot.backgroundColor = HQPalette.tint
        tile.backgroundColor = HQPalette.tint.withAlphaComponent(0.18)
        glyph.tintColor = HQPalette.tint
        name.textColor = HQPalette.label
        arrows.tintColor = HQPalette.label2
        backing.backgroundColor = UIColor.label.withAlphaComponent(0.06)
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
            line.heightAnchor.constraint(equalToConstant: 1),
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
    static var folded: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: foldedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: foldedKey) }
    }

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

    init(title: String, key: String, toggled: @escaping () -> Void) {
        self.title = title
        self.key = key
        super.init(frame: .zero)
        Self.carryOver(title: title, key: key)
        accessibilityIdentifier = "mac-sidebar.heading.\(title)"
        isAccessibilityElement = true
        accessibilityTraits = [.header, .button]
        label.text = title
        label.translatesAutoresizingMaskIntoConstraints = false
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.contentMode = .center
        for view in [label, chevron] { view.isUserInteractionEnabled = false; addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: MacSidebar.headingHeight),
            // [sidebar-feel] On the faces' left edge: at 10 the name started 2 px in from the faces under it.
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacSidebar.contentLeading),
            // 3 under it where it was 5: the name sat exactly midway between the group above and its own (9 px
            // each way); it now leans to its own.
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
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
        chevron.tintColor = hovered ? HQPalette.label2 : HQPalette.label3
        let dim: CGFloat = isHighlighted ? 0.55 : 1
        label.alpha = dim
        chevron.alpha = dim
    }

    func recolor() {
        label.font = MacSidebar.font(MacSidebar.sized(13.5, 14.5), weight: .semibold)
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
        let side = ((folded ? 38 : 34) * MacSidebar.chrome).rounded()
        if folded, named {
            NSLayoutConstraint.activate([
                search.topAnchor.constraint(equalTo: topAnchor), search.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
                search.trailingAnchor.constraint(equalTo: centerXAnchor, constant: -2),
                compose.leadingAnchor.constraint(equalTo: centerXAnchor, constant: 2),
                compose.centerYAnchor.constraint(equalTo: search.centerYAnchor),
                search.widthAnchor.constraint(equalToConstant: side), search.heightAnchor.constraint(equalToConstant: side),
                compose.widthAnchor.constraint(equalToConstant: side), compose.heightAnchor.constraint(equalToConstant: side),
            ])
        } else if folded {
            NSLayoutConstraint.activate([
                search.topAnchor.constraint(equalTo: topAnchor), search.centerXAnchor.constraint(equalTo: centerXAnchor),
                compose.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 2), compose.centerXAnchor.constraint(equalTo: centerXAnchor),
                compose.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
                search.widthAnchor.constraint(equalToConstant: side), search.heightAnchor.constraint(equalToConstant: side),
                compose.widthAnchor.constraint(equalToConstant: side), compose.heightAnchor.constraint(equalToConstant: side),
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
        let glassIcon = UIImage(systemName: "magnifyingglass", withConfiguration: UIImage.SymbolConfiguration(pointSize: (folded ? 17 : 13) * MacSidebar.chrome, weight: .medium))
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
            word.font = MacSidebar.font(MacSidebar.sized(15.5, 17))
            word.textColor = HQPalette.label2
            shortcut.text = "⌘K"
            shortcut.font = MacSidebar.font(MacSidebar.sized(13, 14.5))
            shortcut.textColor = HQPalette.label3
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
                }
            }
            wordLeading?.constant = MacBotsRail.nameLeading   // UI Scale moves the column
        } else {
            find.image = glassIcon
            search.configuration = find
        }
        var write = UIButton.Configuration.plain()
        write.image = UIImage(systemName: "square.and.pencil", withConfiguration: UIImage.SymbolConfiguration(pointSize: (folded ? 17 : 15) * MacSidebar.chrome, weight: .medium))
        write.baseForegroundColor = HQPalette.label
        if !folded { write.background.backgroundColor = well; write.background.cornerRadius = 9 }
        compose.configuration = write
    }

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
    static var titleSize: CGFloat { MacSidebar.tidy ? (Density.compact ? 15.5 : 17) : (Density.compact ? 14 : 15) }
    static var timeSize: CGFloat { MacSidebar.tidy ? 14 : 12.5 }
    static var lineX: CGFloat { MacSidebar.iconLeading + MacSidebar.iconColumn / 2 }

    init(bot: String, look: Look) {
        self.bot = bot
        self.look = look
        content = Self.configuration(look).makeContentView()
        super.init(frame: .zero)
        isAccessibilityElement = true
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
            accessibilityLabel = BotChatRowView.label(session, time: ListTime.string(session.lastActive))
            accessibilityHint = nil
            toolTip = session.title
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

    private static let rowHover = UIColor { traits in UIColor.label.resolvedColor(with: traits).withAlphaComponent(0.05) }

    func recolor() {
        accessibilityTraits = isMarked ? [.button, .selected] : .button
        // The places' own mark (`MacSelection`), as the bot rows take it.
        backing.backgroundColor = MacSelection.fill(selected: isMarked, pressed: isHighlighted, in: .sidebar) ?? (hovered ? Self.rowHover : .clear)
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
                Text(session.title)
                    .font(Font(MacSidebar.font(MacSidebarChat.titleSize, weight: session.unread ? .semibold : .regular) as CTFont))
                    .foregroundStyle(Color.hqLabel)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if session.isRunning {
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
                Text("\(count) more").font(Font(MacSidebar.font(MacSidebar.tidy ? 15.5 : 14, weight: .medium) as CTFont))
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
                Rectangle().fill(Color.hqStroke).frame(height: 0.5).padding(.leading, MacBotsRail.nameLeading)
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
        label.font = MacSidebar.font(MacSidebar.sized(12.5, 15))
        label.textColor = HQPalette.label3
    }
}
#endif
