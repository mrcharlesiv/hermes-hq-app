// [manual-order] Group By Project's and Group By Bot's Reorder page (Filter › Group By › Reorder Projects…, or a header's
// hold menu): the groups in the list's order, each with a drag handle (the list is always editing, as Tab Order). A
// project's star makes it a Favorite, which keeps it above the rest. A move takes effect on the list at once.

import SwiftUI
import UIKit

struct SessionGroupOrderPage: View {
    struct Item: Hashable, Identifiable {
        var key: String
        var title: String
        var id: String { key }
    }

    /// Projects (with stars) or bots.
    var bots: Bool
    @State var items: [Item]
    @State var favorites: Set<String>
    /// A hand-picked order is in place (Use Default Order shows).
    @State var custom: Bool
    var onOrder: ([String]) -> Void
    var onFavorite: (String, Bool) -> Void
    /// Drops the hand-picked order; returns the groups in the default order.
    var onDefault: () -> [Item]

    private var favoriteItems: [Item] { items.filter { favorites.contains($0.key) } }
    private var otherItems: [Item] { items.filter { !favorites.contains($0.key) } }

    var body: some View {
        List { Group {
            if !bots, !favoriteItems.isEmpty {
                Section {
                    rows(favoriteItems, favorite: true)
                } header: { HQSectionLabel { Text("Favorites") } }
            }
            Section {
                rows(bots ? items : otherItems, favorite: false)
            } header: {
                if !bots, !favoriteItems.isEmpty { HQSectionLabel { Text("Projects") } }
            } footer: { HQSectionFooter {
                Text(bots ? "Drag a bot by its handle to move its chats’ group."
                          : "Drag a project by its handle to move it. A starred project is a Favorite and stays on top.")
            } }
            if custom {
                Section {
                    Button("Use Default Order") {
                        Haptics.play(.selection)
                        custom = false
                        items = onDefault()
                    }
                    .accessibilityIdentifier("group-order.default")
                } footer: { HQSectionFooter {
                    Text(bots ? "The bot with the newest chat first." : "The project with the newest chat first, Home last. Favorites stay on top.")
                } }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList()
        .environment(\.editMode, .constant(.active))
    }

    @ViewBuilder
    private func rows(_ lane: [Item], favorite: Bool) -> some View {
        ForEach(lane) { item in
            HStack(spacing: 12) {
                Text(item.title).foregroundStyle(Color.hqLabel).lineLimit(2)
                Spacer(minLength: 0)
                if !bots {
                    Button {
                        Haptics.play(.selection)
                        let on = !favorites.contains(item.key)
                        if on { favorites.insert(item.key) } else { favorites.remove(item.key) }
                        onFavorite(item.key, on)
                    } label: {
                        Image(systemName: favorite ? "star.fill" : "star")
                            .foregroundStyle(favorite ? Color.hqTintText : Color.hqLabel3)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(favorite ? "Remove \(item.title) from Favorites" : "Add \(item.title) to Favorites")
                    .accessibilityIdentifier("group-order.star.\(item.title)")
                }
            }
            .accessibilityIdentifier("group-order.\(item.title)")
        }
        .onMove { from, to in move(lane, from: from, to: to) }
    }

    /// A move inside one lane (the favorites, or the rest), written back over the whole order.
    private func move(_ lane: [Item], from: IndexSet, to: Int) {
        var moved = lane
        moved.move(fromOffsets: from, toOffset: to)
        let laneKeys = Set(lane.map(\.key))
        var rest = moved.makeIterator()
        items = items.map { laneKeys.contains($0.key) ? (rest.next() ?? $0) : $0 }
        Haptics.play(.selection)
        custom = true
        onOrder(items.map(\.key))
    }
}

extension SessionGroupOrderPage {
    /// The page in a sheet (✕ on the phone, Done on the Mac).
    @MainActor static func sheet(bots: Bool, items: [Item], favorites: Set<String>, custom: Bool,
                                 onOrder: @escaping ([String]) -> Void, onFavorite: @escaping (String, Bool) -> Void,
                                 onDefault: @escaping () -> [Item]) -> UINavigationController {
        let page = SessionGroupOrderPage(bots: bots, items: items, favorites: favorites, custom: custom,
                                         onOrder: onOrder, onFavorite: onFavorite, onDefault: onDefault)
        return ChatSheet.wrap(UIHostingController(rootView: page), title: bots ? "Reorder Bots" : "Reorder Projects",
                              detents: [.large()])
    }
}
