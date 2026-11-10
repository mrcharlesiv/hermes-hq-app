import Testing
import UIKit
@testable import HermesHQNative

/// Owner 2026-11-01: every Settings row has a symbol, and each symbol has its own tile (colour and filled glyph), not
/// a colour hashed from its name.
@MainActor @Suite struct SettingsTileTests {
    @Test func everyTileGlyphIsARealSymbol() {
        for (symbol, tile) in SettingsRowLabel.tiles {
            #expect(UIImage(systemName: symbol) != nil, "\(symbol)")
            #expect(UIImage(systemName: tile.glyph) != nil, "\(symbol) → \(tile.glyph)")
        }
    }

    @Test func everyGatewayPageAndDeviceAccessRowHasItsTile() {
        let sections = ConfigCatalog.sections + [VoiceSettingsCatalog.section]
        var symbols = sections.flatMap { [$0.symbol] + $0.pages.map(\.symbol) }
        for kind in DeviceAccess.Kind.allCases { symbols += [kind.systemImage] + kind.scopes.map(\.systemImage) }
        for symbol in Set(symbols) { #expect(SettingsRowLabel.tiles[symbol] != nil, "\(symbol)") }
    }
}
