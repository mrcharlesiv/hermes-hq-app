// [context-window] A bot's context window (owner 2026-11-01, after asking where max context was set: "If I have to ask
// you, then I'm sure others may not ever even find it"): its own page under Settings › Model, found by the words people
// use, offering only sizes Hermes will start a chat in.

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct ContextWindowTests {
    @Test func itHasItsOwnPageUnderModel() {
        #expect(ConfigCatalog.page(forField: ContextWindow.key, in: "model")?.key == "model.context")
        let model = ConfigCatalog.section("model")!
        #expect(model.pages.map(\.id) == ["main", "context", "fallbacks", "auxiliary", "moa"], "right under Main Model")
        #expect(ConfigCatalog.page("model.context")?.title == "Context Window")
        #expect(ConfigCatalog.page("model.main")?.contains(ContextWindow.key) == false, "no longer one field among Main Model's")
        #expect(ConfigCatalog.customPages.contains("model.context"))
        #expect(ConfigCopy.labels[ContextWindow.key] == "Context Window")
        #expect(SettingsRowLabel.tile(for: "viewfinder").colour != SettingsRowLabel.tile(for: "unknown.symbol").colour, "a tile of its own, not the grey fallback")
    }

    @Test func searchFindsItByTheWordsPeopleUse() {
        let index = SettingsSearch.index()
        for query in ["max context", "context length", "context window", "token limit", "context size", "num ctx"] {
            let first = SettingsSearch.results(query, in: index).first
            #expect(first?.target == .page("model.context"), "\(query): \(first?.label ?? "nothing")")
        }
    }

    @Test func sizesStayUnderTheModelsOwnAndAtLeastHermesMinimum() {
        #expect(ContextWindow.sizes(below: nil) == ContextWindow.sizes)
        #expect(ContextWindow.sizes(below: 1_000_000) == [400_000, 256_000, 200_000, 128_000, 64_000], "1M is Automatic there")
        #expect(ContextWindow.sizes(below: 200_000) == [128_000, 64_000])
        #expect(ContextWindow.sizes(below: 64_000).isEmpty)
        #expect(ContextWindow.sizes.allSatisfy { $0 >= ContextWindow.minimum })
        #expect(ContextWindow.sizes.map(ContextWindow.label) == ["1M", "400K", "256K", "200K", "128K", "64K"])
    }

    @Test func zeroIsAutomatic() {
        #expect(ContextWindow.override(.number(0)) == nil)
        #expect(ContextWindow.override(nil) == nil)
        #expect(ContextWindow.override(.string("256K")) == nil, "Hermes takes a plain number only")
        #expect(ContextWindow.override(.number(200_000)) == 200_000)
        #expect(ContextWindow.summary(.number(0)) == "Automatic")
        #expect(ContextWindow.summary(.number(300_000)) == "300K")
        #expect(ContextWindow.summary(.number(1_500_000)) == "1.5M")
    }

    @Test func aTypedSizeReadsAsPeopleWriteIt() {
        #expect(ContextWindow.parse("300000") == 300_000)
        #expect(ContextWindow.parse("300,000") == 300_000)
        #expect(ContextWindow.parse("300K") == 300_000)
        #expect(ContextWindow.parse(" 300 k tokens ") == 300_000)
        #expect(ContextWindow.parse("1M") == 1_000_000)
        #expect(ContextWindow.parse("1.5m") == 1_500_000)
        #expect(ContextWindow.parse("") == nil)
        #expect(ContextWindow.parse("lots") == nil)
        #expect(ContextWindow.parse("-5") == nil)
        #expect(ContextWindow.problem("300K") == nil)
        #expect(ContextWindow.problem("32K") == "Hermes needs at least 64K.")
        #expect(ContextWindow.problem("lots") == "Type a size, such as 300K.")
    }

    @Test func aSizeOverTheModelsOwnIsKeptWithAWord() {
        #expect(ContextWindow.caution(300_000, own: 200_000)?.hasPrefix("That’s more than the model’s own 200K.") == true)
        #expect(ContextWindow.caution(200_000, own: 200_000) == nil)
        #expect(ContextWindow.caution(128_000, own: 200_000) == nil)
        #expect(ContextWindow.caution(300_000, own: nil) == nil, "the model's own not known")
        #expect(ContextWindow.caution(nil, own: 200_000) == nil, "Automatic")
    }
}
