// [quick-actions] Cross-device sync for the Favorites page (`GatewaySync` document "favorites").
// Carries tiles and pages between iPhone, iPad, and Mac while keeping device-local view state (current page, filter)
// on each device, matching `ArtifactPins` ("pins") three-way merge semantics.

import Foundation

@MainActor
final class FavoritesSync: GatewaySynced {
    let syncName = "favorites"
    private let defaults: UserDefaults
    var syncChanged: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var syncStartedEmpty: Bool {
        defaults.data(forKey: QuickTileStore.key) == nil
    }

    nonisolated struct SyncedFavorites: Codable, Equatable {
        var tiles: [QuickTile]
        var pages: [FavoritePage]
    }

    func syncValue() -> JSONValue {
        let list = QuickTileStore.load(defaults)
        let doc = SyncedFavorites(tiles: list.tiles, pages: list.pages)
        return (try? JSONEncoder().encode(doc)).flatMap { try? JSONValue.parse($0) } ?? .null
    }

    func adoptSynced(_ value: JSONValue, merge: GatewaySyncMerge, base: JSONValue?) {
        guard let remote = Self.decodeSynced(value) else { return }
        var local = QuickTileStore.load(defaults)
        let remotePages = Self.normalizedPages(remote.pages)

        switch merge {
        case .replace:
            local.tiles = remote.tiles
            local.pages = remotePages
        case .firstContact:
            if local.tiles.isEmpty || (QuickTileStore.isUneditedStarter(local) && !remote.tiles.isEmpty) {
                local.tiles = remote.tiles
                local.pages = remotePages
            } else {
                let remoteIDs = Set(remote.tiles.map(\.id))
                local.tiles = remote.tiles + local.tiles.filter { !remoteIDs.contains($0.id) }
                let pageIDs = Set(remotePages.map(\.id))
                local.pages = Self.normalizedPages(remotePages + local.pages.filter { !pageIDs.contains($0.id) })
            }
        case .rebase:
            let was = base.flatMap(Self.decodeSynced) ?? SyncedFavorites(tiles: [], pages: [])
            local.tiles = ArtifactPins.merged(remote.tiles, local: local.tiles, base: was.tiles)
            local.pages = Self.normalizedPages(ArtifactPins.merged(remotePages, local: local.pages, base: was.pages))
        }

        local.seeded = true
        QuickTileStore.save(local, defaults, notifySync: false)
    }

    func localChanged() {
        syncChanged?()
    }

    private static func decodeSynced(_ value: JSONValue) -> SyncedFavorites? {
        guard let data = try? value.encoded() else { return nil }
        return try? JSONDecoder().decode(SyncedFavorites.self, from: data)
    }

    private static func normalizedPages(_ pages: [FavoritePage]) -> [FavoritePage] {
        guard !pages.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [FavoritePage] = []
        let main = pages.first { $0.id == FavoritePage.mainId } ?? .main
        seen.insert(main.id)
        out.append(main)
        for page in pages where seen.insert(page.id).inserted {
            out.append(page)
        }
        return out.count <= 1 && out.first == .main ? [] : out
    }
}
