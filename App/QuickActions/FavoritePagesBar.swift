// [quick-actions] Favorites pages pill strip (matching `DashboardPagesBand` on Tiles): lets users organize Favorites
// into multiple named spaces (Home, Work, Daily, Ops…) with optional SF Symbols, drag-to-reorder, and a ⋯ menu.
// Hidden while only the default Home page exists so simple setups stay uncluttered.

import SwiftUI
import UIKit

@MainActor @Observable
final class FavoritePagesModel {
    var pages: [FavoritePage] = []
    var current: String = FavoritePage.mainId
    var counts: [String: Int] = [:]
    var dimmed = false
}

struct FavoritePageActions {
    var select: (String) -> Void
    var add: () -> Void
    var rename: (FavoritePage) -> Void
    var setSymbol: (FavoritePage, String?) -> Void
    var move: (FavoritePage, Int) -> Void
    var reorder: (String, String) -> Void
    var delete: (FavoritePage) -> Void
}

struct FavoritePagesBand: View {
    var model: FavoritePagesModel
    var actions: FavoritePageActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if model.pages.count > 1 { rail }
        }
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: DesktopPillBand.color))
    }

    @ViewBuilder private var pills: some View {
        ForEach(model.pages) { page in
            let picked = model.current == page.id
            let quiet = picked && model.dimmed && !Theme.isDesktop
            let count = model.counts[page.id] ?? 0
            let hasIcon = page.symbol.map { !$0.isEmpty } ?? false
            let pill = SessionPill(caption: page.name, name: page.name, picked: picked && !quiet,
                                   identifier: "favorites.page.\(page.id == FavoritePage.mainId ? "main" : page.name)",
                                   hasFace: hasIcon, lead: hasIcon ? 10 : nil) {
                actions.select(page.id)
            } face: {
                if let symbol = page.symbol, !symbol.isEmpty {
                    Image(systemName: QuickTileLook.symbol(symbol))
                        .font(Font.hq(Theme.isDesktop ? .caption : .footnote).weight(.semibold))
                        .foregroundStyle(picked && !quiet ? Theme.pickedPillInk : Color.hqLabel2)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .overlay {
                if quiet {
                    Capsule().strokeBorder(Color.hqLabel2, lineWidth: 1.5)
                        .frame(height: SessionPill<EmptyView>.height)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityAddTraits(quiet ? .isSelected : [])
            .accessibilityValue(count == 1 ? "1 item" : "\(count) items")
            .contextMenu { menu(for: page) }
            .id(page.id)

            if page.id != FavoritePage.mainId {
                pill
                    .draggable("hq-fav-page:" + page.id)
                    .dropDestination(for: String.self) { items, _ in
                        guard let raw = items.first, raw.hasPrefix("hq-fav-page:") else { return false }
                        let source = String(raw.dropFirst("hq-fav-page:".count))
                        guard source != page.id else { return false }
                        actions.reorder(source, page.id)
                        return true
                    }
            } else {
                pill
            }
        }

        SessionPill(caption: "", name: "New Page", picked: false, identifier: "favorites.page.add", hasFace: true, lead: 10) {
            actions.add()
        } face: {
            DashboardPagesBand.mark("plus")
        }

        if let current = model.pages.first(where: { $0.id == model.current }) {
            Menu {
                Section(current.name) { menu(for: current) }
            } label: {
                FavoriteMorePill()
            }
            .menuIndicator(.hidden)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Actions for \(current.name)")
            .accessibilityIdentifier("favorites.page.menu")
        }
    }

    @ViewBuilder private func menu(for page: FavoritePage) -> some View {
        Button { actions.rename(page) } label: { Label("Rename…", systemImage: "pencil") }
        Menu {
            Button { actions.setSymbol(page, nil) } label: {
                Label("No Icon", systemImage: page.symbol == nil ? "checkmark" : "nosign")
            }
            ForEach(FavoritePage.symbolChoices, id: \.symbol) { choice in
                Button { actions.setSymbol(page, choice.symbol) } label: {
                    Label(choice.label, systemImage: choice.symbol)
                }
            }
        } label: {
            Label("Icon", systemImage: page.symbol ?? "sparkles")
        }
        if page.id != FavoritePage.mainId, let index = model.pages.firstIndex(of: page) {
            if index > 1 || index < model.pages.count - 1 {
                Section {
                    if index > 1 {
                        Button { actions.move(page, -1) } label: { Label("Move Left", systemImage: "arrow.left") }
                    }
                    if index < model.pages.count - 1 {
                        Button { actions.move(page, 1) } label: { Label("Move Right", systemImage: "arrow.right") }
                    }
                }
            }
            Section {
                Button(role: .destructive) { actions.delete(page) } label: { Label("Delete Page", systemImage: "trash") }
            }
        }
    }

    @ViewBuilder private var rail: some View {
        if DeviceWord.isMac {
            PagesFlowLayout(spacing: 8, lineSpacing: 0) { pills }
                .padding(.horizontal, Theme.isDesktop ? DesktopRows.gutter : 16)
                .padding(.top, DesktopRows.underBar)
                .padding(.bottom, Theme.isDesktop ? 2 : 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hqPickGlassRow()
                .hqFlatPicks()
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Pages")
                .accessibilityIdentifier("favorites.pages")
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 8) { pills }
                        .padding(.horizontal, Theme.isDesktop ? DesktopRows.gutter : 16)
                        .padding(.top, DesktopRows.underBar)
                        .padding(.bottom, Theme.isDesktop ? 2 : 4)
                        .hqPickGlassRow()
                }
                .scrollIndicators(.never)
                .hqScrollEdgeFade(width: 20, preservesGlass: true)
                .onAppear { proxy.scrollTo(model.current) }
                .onChange(of: model.current) { _, current in
                    if reduceMotion {
                        proxy.scrollTo(current)
                    } else {
                        withAnimation(.easeInOut(duration: HQMotion.pane)) { proxy.scrollTo(current) }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pages")
            .accessibilityIdentifier("favorites.pages")
        }
    }
}

private struct FavoriteMorePill: View {
    var body: some View {
        let height = SessionPill<EmptyView>.height
        HStack(spacing: 6) {
            DashboardPagesBand.mark("ellipsis")
            Text("").font(Font.hq(Theme.isDesktop ? .footnote : .subheadline).weight(.medium))
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .frame(minHeight: height)
        .background {
            if Theme.isDesktop {
                RoundedRectangle(cornerRadius: DesktopRows.radius, style: .continuous).fill(Color.hqFill3)
            } else {
                Capsule().fill(Color.hqFill3)
            }
        }
    }
}
