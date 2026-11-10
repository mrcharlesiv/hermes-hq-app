// The Bots list laid out by section id, in this device's order, with empty user sections (spec 1x-settings §5.4 "List
// composition change"): tiles → Pinned (only when pins overflow the tiles) → user sections, empty ones included while
// nothing narrows the list → unassigned → Hidden. Pure.

import Foundation

nonisolated enum BotListLayout {
    /// `layout` is `BotStore.layout` (`flat` is what `services.bots` holds); `records` the device's user sections.
    /// [pinned-rows] `pinsAsRows` (Pinned Bots › Rows): no tiles; every pin is a row of one Pinned block with no header,
    /// first in the list, in the pins' saved order (`pinOrder`, bot ids; pins never placed follow in the list's order).
    static func compose(layout: RosterLayout, records: [RosterSectionRecord], pinsAsRows: Bool = false,
                        pinOrder: [String] = []) -> [BotListSection] {
        var sections: [BotListSection] = []
        let overflow = layout.sections.first(where: \.isPinned)?.bots ?? []
        if pinsAsRows {
            let pins = pinnedRows(layout.tiles + overflow, order: pinOrder)
            if !pins.isEmpty { sections.append(BotListSection(id: .pinned, title: nil, bots: pins)) }
        } else {
            if !layout.tiles.isEmpty { sections.append(BotListSection(id: .tiles, title: nil, bots: layout.tiles)) }
            if !overflow.isEmpty { sections.append(BotListSection(id: .pinned, title: RosterRules.pinnedSectionName, bots: overflow)) }
        }
        var shown = Set<String>()
        for record in records where record.id != RosterRules.pinnedSectionId {
            let rows = layout.sections.first { $0.id == record.id }?.bots ?? []
            sections.append(BotListSection(id: .user(record.id), title: record.name, bots: rows))
            shown.insert(record.id)
        }
        // A section the layout drew that the records don't know (not expected): still shown.
        for section in layout.sections where !section.isPinned && !shown.contains(section.id) {
            sections.append(BotListSection(id: .user(section.id), title: section.name, bots: section.bots))
        }
        if !layout.unassigned.isEmpty { sections.append(BotListSection(id: .unassigned, title: nil, bots: layout.unassigned)) }
        if !layout.hidden.isEmpty { sections.append(BotListSection(id: .hidden, title: "Hidden", bots: layout.hidden)) }
        return sections
    }

    /// [pinned-rows] The pins in their saved order: placed ones first (by `order`), then the rest as they came.
    static func pinnedRows(_ pins: [Bot], order: [String]) -> [Bot] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return pins.enumerated()
            .sorted { (rank[$0.element.id] ?? Int.max, $0.offset) < (rank[$1.element.id] ?? Int.max, $1.offset) }
            .map(\.element)
    }

    /// [pinned-rows] The Pinned block drawn as plain rows (Pinned Bots › Rows): it has no header.
    static func isPinnedRows(_ section: BotListSection) -> Bool { section.id == .pinned && section.title == nil }

    /// [bots-groupby] Group chats join the bots' blocks once the list has a user section: each filed room goes into its
    /// section, the rest into Unassigned (a header now, so its rows don't read as part of the section above it), and
    /// there is no separate Group Chats block. Without user sections the list is as before (`nil`: keep Group Chats).
    static let unassignedName = "Unassigned"

    /// `pinned`: pinned rooms the tiles could not take; they go in the Pinned section with the bots' pins past the six
    /// (made after the tiles when only rooms overflow), not in Unassigned (audit 05-6).
    static func file(_ sections: [BotListSection], loose: [GroupRowModel], filed: [(id: String, rooms: [GroupRowModel])],
                     pinned: [GroupRowModel] = []) -> [BotListSection]? {
        guard sections.contains(where: { if case .user = $0.id { true } else { false } }) else { return nil }
        var out = sections
        if !pinned.isEmpty {
            if let index = out.firstIndex(where: { $0.id == .pinned }) { out[index].rooms += pinned }
            else {
                let at = out.firstIndex { $0.id == .tiles }.map { $0 + 1 } ?? 0
                out.insert(BotListSection(id: .pinned, title: RosterRules.pinnedSectionName, bots: [], rooms: pinned), at: at)
            }
        }
        for group in filed {
            if let index = out.firstIndex(where: { $0.id == .user(group.id) }) { out[index].rooms += group.rooms }
        }
        if let index = out.firstIndex(where: { $0.id == .unassigned }) {
            out[index].title = unassignedName
            out[index].rooms += loose
        } else if !loose.isEmpty {
            let at = out.firstIndex { $0.id == .hidden } ?? out.count
            out.insert(BotListSection(id: .unassigned, title: unassignedName, bots: [], rooms: loose), at: at)
        }
        return out
    }

    /// [bots-groupby] Group By › None: the tiles stay on top and Hidden at the bottom; every other bot and room is one
    /// block, newest activity first (pins past the six tiles too: Pinned is a section, and not first here). Under Pinned
    /// Bots › Rows the pins' block stays on top instead, as the tiles would.
    static func flat(_ sections: [BotListSection], loose: [GroupRowModel]) -> [BotListSection] {
        var bots: [Bot] = [], rooms: [GroupRowModel] = loose
        var out: [BotListSection] = []
        for section in sections {
            switch section.id {
            case .tiles, .hidden: out.append(section)
            // [pinned-rows] Pinned Bots › Rows: the pins stay on top as rows, in their own order.
            case .pinned where isPinnedRows(section): out.append(section)
            default: bots += section.bots; rooms += section.rooms
            }
        }
        // Activity alone (pins included): the point of None is everything by when it last moved.
        let byActivity = bots.enumerated().sorted { a, b in
            let ta = a.element.lastActive?.timeIntervalSince1970 ?? 0, tb = b.element.lastActive?.timeIntervalSince1970 ?? 0
            return ta != tb ? ta > tb : a.offset < b.offset
        }.map(\.element)
        let everything = BotListSection(id: .everything, title: nil, bots: byActivity,
                                        rooms: rooms.sorted { $0.lastAt != $1.lastAt ? $0.lastAt > $1.lastAt : $0.name < $1.name })
        guard !everything.bots.isEmpty || !everything.rooms.isEmpty else { return out }
        out.insert(everything, at: out.firstIndex { $0.id == .hidden } ?? out.count)
        return out
    }

    /// The empty section's one-line hint (`B/stress-a-gates.ts:113`). [header-menus] The Mac's row menu has Move to
    /// Section at its top level (no More ▸, [mac-menu]), so the Mac's hint names that path; the iPhone and iPad keep More.
    static let emptyHint = DeviceWord.isMac
        ? "Drag a bot or group chat here, or \(DeviceWord.hold) one and choose Move to Section."   // [mac] a mouse drags at once
        : "Hold a bot or group chat and drag it here, or choose Move to Section in its menu."
    /// Under the Pinned section's rows: why these pins are not tiles (it shows only past six pins).
    static let pinnedOverflowHint = "Only six pins fit at the top. The rest are listed here."

    /// Delete Section's question (`S/ui-bots/section-delete.ts:4-9`), its group chats named too (audit 05-2: a section
    /// holding only group chats went without asking, and a mixed one's question spoke of its bots alone). nil: nothing
    /// is filed there, so it goes at once (the Undo pill still offers the way back).
    static func deleteMessage(bots: Int, rooms: Int) -> String? {
        switch (bots, rooms) {
        case (0, 0): return nil
        case (1, 0): return "Its bot moves to Unassigned."
        case (_, 0): return "Its \(bots) bots move to Unassigned."
        case (0, 1): return "Its group chat moves to Unassigned."
        case (0, _): return "Its \(rooms) group chats move to Unassigned."
        default: return "Its \(bots) \(bots == 1 ? "bot" : "bots") and \(rooms) \(rooms == 1 ? "group chat" : "group chats") move to Unassigned."
        }
    }

    /// Names the Bots list uses for its own headings: a section called so would read as one of them (and a bot in a
    /// section named Unassigned showed two checkmarks in Bot Info's Section menu, audit 05-14).
    static let reservedSectionNames = [unassignedName, "Hidden", RosterRules.pinnedSectionName, "Group Chats"]

    /// Why New Section / Rename can't take `name` (shown in the prompt, its button off), or nil. `others`: the other
    /// sections' names (a rename leaves its own out, so only the case can change).
    static func sectionNameProblem(_ name: String, others: [String]) -> String? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        if let reserved = reservedSectionNames.first(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
            return "“\(reserved)” is already a heading in the Bots list. Choose another name."
        }
        if let taken = others.first(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(clean) == .orderedSame }) {
            return "There’s already a section named “\(taken)”."
        }
        return nil
    }
}

/// One menu, drawn as a `UIMenu` (long press) or as SwiftUI `Menu` content (the row's ⋯ button).
struct BotMenuNode: Identifiable {
    enum Kind {
        case action(() -> Void)
        case submenu([BotMenuNode])
        case inline([BotMenuNode])
        /// The first row of small tiles (`preferredElementSize = .medium`).
        case tiles([BotMenuNode])
        /// A row of colour circles (`.displayAsPalette`; Sessions › More › Color). The node's title heads it.
        case palette([BotMenuNode])
        /// Children read when the menu opens (UIKit menus only: `UIDeferredMenuElement.uncached`).
        case deferred(@MainActor (@escaping @MainActor ([BotMenuNode]) -> Void) -> Void)
    }

    let id = UUID()
    var title: String
    var image: String?
    var destructive = false
    var disabled = false
    var checked = false
    /// Drawn as a filled circle of this colour instead of `image` (palette swatches).
    var color: UIColor? = nil
    /// The menu stays open when picked (UIKit menus only).
    var keepsOpen = false
    var identifier: String? = nil
    /// [talk] A second line under the title ("Can’t reach this bot", "Speech to Text is off").
    var subtitle: String? = nil
    var kind: Kind

    static func action(_ title: String, _ image: String?, destructive: Bool = false, disabled: Bool = false, checked: Bool = false,
                       _ run: @escaping () -> Void) -> BotMenuNode {
        BotMenuNode(title: title, image: image, destructive: destructive, disabled: disabled, checked: checked, kind: .action(run))
    }

    static func uiMenu(_ nodes: [BotMenuNode], title: String = "") -> UIMenuBuilderResult {
        UIMenuBuilderResult(nodes: nodes, title: title)
    }
}

import SwiftUI
import UIKit

extension BotMenuNode {
    /// The node's picture: its colour as a filled circle, else its symbol.
    var uiImage: UIImage? {
        if let color {
            return UIImage(systemName: "circle.fill")?.withTintColor(color, renderingMode: .alwaysOriginal)
        }
        return image.flatMap { UIImage(systemName: $0) }
    }
}

/// Builds the UIKit menu (kept apart so the node type stays plain).
struct UIMenuBuilderResult {
    var nodes: [BotMenuNode]
    var title: String

    var menu: UIMenu { UIMenu(title: title, children: Self.elements(nodes)) }

    static func elements(_ nodes: [BotMenuNode]) -> [UIMenuElement] {
        nodes.map { node -> UIMenuElement in
            let image = node.uiImage
            switch node.kind {
            case .action(let run):
                var attributes: UIMenuElement.Attributes = []
                if node.destructive { attributes.insert(.destructive) }
                if node.disabled { attributes.insert(.disabled) }
                if node.keepsOpen { attributes.insert(.keepsMenuPresented) }
                let action = UIAction(title: node.title, image: image, attributes: attributes, state: node.checked ? .on : .off) { _ in run() }
                if let identifier = node.identifier { action.accessibilityIdentifier = identifier }
                if let subtitle = node.subtitle { action.subtitle = subtitle }   // [talk]
                return action
            case .submenu(let children):
                let menu = UIMenu(title: node.title, image: image, children: elements(children))
                if let subtitle = node.subtitle { menu.subtitle = subtitle }   // [chats-under] what it's set to
                return menu
            case .inline(let children):
                return UIMenu(title: "", options: node.destructive ? [.displayInline, .destructive] : .displayInline, children: elements(children))
            case .tiles(let children):
                let menu = UIMenu(title: "", options: .displayInline, children: elements(children))
                menu.preferredElementSize = .medium
                return menu
            case .palette(let children):
                return UIMenu(title: node.title, options: [.displayInline, .displayAsPalette], children: elements(children))
            case .deferred(let load):
                return UIDeferredMenuElement.uncached { completion in
                    load { nodes in completion(elements(nodes)) }
                }
            }
        }
    }
}

/// The same menu as SwiftUI `Menu` content.
struct BotMenuContent: View {
    let nodes: [BotMenuNode]

    var body: some View {
        ForEach(nodes) { node in
            switch node.kind {
            case .action(let run):
                Button(role: node.destructive ? .destructive : nil, action: run) {
                    if let subtitle = node.subtitle {   // [talk] the system draws the second Text as the subtitle
                        Label { Text(node.title); Text(subtitle) } icon: { Image(systemName: node.image ?? "circle") }
                    } else if node.checked {
                        Label(node.title, systemImage: "checkmark")
                    } else if let image = node.image {
                        Label(node.title, systemImage: image)
                    } else {
                        Text(node.title)
                    }
                }
                .disabled(node.disabled)
            case .submenu(let children):
                Menu {
                    BotMenuContent(nodes: children)
                } label: {
                    if let image = node.image { Label(node.title, systemImage: image) } else { Text(node.title) }
                }
            case .inline(let children):
                Section { BotMenuContent(nodes: children) }
            case .tiles(let children):
                ControlGroup { BotMenuContent(nodes: children) }
                    .controlGroupStyle(.menu)
            case .palette(let children):
                Section(node.title) { BotMenuContent(nodes: children) }
            case .deferred:
                EmptyView()
            }
        }
    }
}
