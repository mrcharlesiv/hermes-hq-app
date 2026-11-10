// [model-panel] The composer's model panel as data (HermesKit/Chat/ModelPanelModel.swift) and the bubble's short
// effort words. No network.

import Foundation
import Testing
@testable import HermesHQNative

@Suite("Menus · model panel")
struct ModelPanelTests {
    private func choice(_ id: String, _ provider: String = "anthropic", _ name: String? = nil) -> ModelChoice {
        ModelChoice(id: id, name: name ?? id, provider: provider, providerName: provider == "anthropic" ? "Anthropic" : nil)
    }

    private func input(_ current: ModelChoice, favorites: [ModelChoice] = [], recents: [ModelChoice] = [],
                       levels: [String] = ModelNames.reasoningEfforts, effort: String = "high", canTurnOff: Bool = true,
                       offline: Bool = false) -> ModelMenuInput {
        ModelMenuInput(current: current, recents: recents, favorites: favorites, reasoningLevels: levels,
                       reasoningCurrent: effort, canTurnOff: canTurnOff, fastSupported: false, fastOn: false, offline: offline)
    }

    private typealias Fact = ModelPanelState.Fact

    @Test func approvalsPassThroughAndReadAsWords() {
        var raw = input(choice("x"))
        raw.approvalMode = "smart"
        let state = ModelPanelModel.build(raw)
        #expect(state.approvalMode == "smart" && !state.yolo)
        #expect(ModelPanelModel.approvalValue(mode: "manual") == "Manual")
        #expect(ModelPanelModel.approvalValue(mode: "off") == "Off")
        #expect(ModelPanelModel.approvalValue(mode: "") == nil)
        #expect(ModelPanelModel.approvalModes.map(\.mode) == ["manual", "smart", "off"])
    }

    @Test func theIdsWindowTagBecomesTheContextFactNotAPill() {
        let state = ModelPanelModel.build(input(choice("claude-opus-5-5[1m]")))
        #expect(state.tag == nil)
        #expect(state.facts.first == Fact(title: "Context window", value: "1M", caption: "Context"))
    }

    @Test func theChatsOwnWindowWinsAndSaysHowMuchIsUsed() {
        let state = ModelPanelModel.build(input(choice("claude-opus-5-5[1m]")), contextMax: 200_000, contextUsed: 50_000,
                                          listedContext: 1_000_000)
        #expect(Array(state.facts.prefix(2)) == [Fact(title: "Context window", value: "200K", caption: "Context"),
                                                 Fact(title: "Context used", value: "25%", caption: "Used")])
        let fresh = ModelPanelModel.build(input(choice("x")), contextMax: 200_000, contextUsed: 0)
        #expect(!fresh.facts.contains { $0.caption == "Used" })
    }

    @Test func modelsDevsWindowFillsInWhenTheIdHasNone() {
        let state = ModelPanelModel.build(input(choice("gpt-5.5", "openai")), listedContext: 400_000)
        #expect(state.facts.first?.value == "400K")
    }

    @Test func priceAndPlanReadAsAValueOverACaption() {
        let state = ModelPanelModel.build(input(choice("gpt-5.5", "openai")), price: "$5 in · $25 out", limit: "Weekly · 62% left")
        #expect(state.facts.contains(Fact(title: "Price", value: "$5 · $25", caption: "In · out per 1M", spoken: "$5 in · $25 out per 1M")))
        #expect(state.facts.contains(Fact(title: "Plan", value: "62% left", caption: "Weekly", spoken: "Weekly · 62% left")))
        #expect(!state.facts.contains { $0.title == "Status" })
        #expect(ModelPanelModel.priceFact("Included") == Fact(title: "Price", value: "Included", caption: "Price"))
        #expect(ModelPanelModel.priceFact("$3 in").caption == "In per 1M")
        #expect(ModelPanelModel.planFact("Rate limited · back in 2h") == Fact(title: "Plan", value: "Rate limited", caption: "Back in 2h",
                                                                               spoken: "Rate limited · back in 2h"))
        #expect(ModelPanelModel.planFact("Rate limited") == Fact(title: "Plan", value: "Rate limited", caption: "Plan"))
    }

    @Test func withoutAPlanItSaysAvailableOrOffline() {
        #expect(ModelPanelModel.build(input(choice("x"))).facts.last?.value == "Available")
        #expect(ModelPanelModel.build(input(choice("x"), offline: true)).facts.last?.value == "Offline")
    }

    @Test func theScaleStartsAtOffOnlyWhenTheModelCanTurnItOff() {
        #expect(ModelPanelModel.build(input(choice("x"))).efforts.first == "none")
        #expect(ModelPanelModel.build(input(choice("x"), canTurnOff: false)).efforts.first == "minimal")
        #expect(ModelPanelModel.build(input(choice("x"), levels: [])).efforts.isEmpty)
    }

    @Test func anEffortOffTheScaleLandsOnMedium() {
        #expect(ModelPanelModel.build(input(choice("x"), effort: "turbo")).effort == "medium")
    }

    @Test func rowsAreUniqueCappedAndMarkTheCurrentModel() {
        let current = choice("claude-opus-5-5")
        let favorites = [current] + (1...9).map { choice("m\($0)", "openai") }
        let state = ModelPanelModel.build(input(current, favorites: favorites, recents: [current, choice("r1", "xai")]))
        // Every favourite (owner 2026-10-31: a few "a limitation"), the current one checked among them.
        #expect(state.favorites.count == favorites.count)
        #expect(state.favorites.filter(\.current).count == 1)
        #expect(state.recents.map(\.model.id) == ["r1"])
    }

    @Test func recentsLeaveOutFavouritesAndTheCurrentModel() {
        let current = choice("claude-opus-5-5")
        let state = ModelPanelModel.build(input(current, favorites: [choice("gpt-5.5", "openai")],
                                                recents: [current, choice("gpt-5.5", "openai")] + (1...8).map { choice("r\($0)", "xai") }))
        #expect(state.recents.map(\.model.id) == ["r1", "r2", "r3", "r4", "r5"])
    }

    @Test func theMenuListsTheWholeCatalogByProvider() {
        let current = choice("claude-opus-5-5")
        let catalog = [current, choice("claude-sonnet-5"), choice("gpt-5.5", "openai"), choice("o3", "openai"), choice("grok-5", "xai")]
        let groups = ModelPanelModel.groups(catalog, current: current)
        #expect(groups.map(\.rows.count) == [2, 2, 1])
        #expect(groups.flatMap(\.rows).filter(\.current).map(\.model.id) == ["claude-opus-5-5"])
        #expect(!groups.map(\.title).contains("openai"))
    }

    /// [model-scope] Owner 2026-11-03: Switch Model and the Models sheet say a pick is this chat's, and where the bot's
    /// own default is changed.
    @Test func aChatsSwitchSaysWhatItAppliesTo() {
        #expect(ModelPanelModel.switchScope(bot: "Hermes") == "Applies to this chat only. Change Hermes’s default in Bot Info › Brain.")
        #expect(ModelPanelModel.switchScope(bot: nil) == "Applies to this chat only.", "no Bot Info to point at")
        #expect(ModelPanelModel.switchScope(bot: " ") == "Applies to this chat only.")
        #expect(ModelPanelModel.switchMenuTitle(bot: "Hermes", largeText: false) == ModelPanelModel.switchScope(bot: "Hermes"))
        #expect(ModelPanelModel.switchMenuTitle(bot: "Hermes", largeText: true) == "", "no title over the picks at AX sizes")
    }

    @Test func everyLevelHasALine() {
        for level in ModelNames.reasoningEffortValues { #expect(!ModelPanelModel.effortLine(level).hasPrefix("Thinks at")) }
        #expect(ModelPanelModel.effortLine("extra_deep") == "Thinks at Extra Deep")
    }

    @Test func theBubblesShortEffortWords() {
        #expect(ModelNames.effortShortLabel("medium") == "Med")
        #expect(ModelNames.effortShortLabel("xhigh") == "XHigh")
        #expect(ModelNames.effortShortLabel("none") == "Off")
        #expect(ModelNames.effortShortLabel("extra_deep") == "Extra Deep")
    }

    @Test func modelsDevContextWindowsAreKeptAndMatched() throws {
        let json = #"{"anthropic":{"models":{"claude-opus-5-5":{"cost":{"input":5,"output":25},"limit":{"context":1000000}}}},"#
            + #""openai":{"models":{"gpt-5.5":{"limit":{"context":400000}}}}}"#
        let prices = try #require(ModelsDevPrices(data: Data(json.utf8)))
        #expect(prices.hasContextWindows)
        #expect(prices.contextWindow(provider: "anthropic", model: "claude-opus-5-5[1m]") == 1_000_000)
        #expect(prices.contextWindow(provider: "nous", model: "anthropic/claude-opus-5-5") == 1_000_000)
        #expect(prices.contextWindow(provider: "openai", model: "gpt-5.5") == 400_000)
        #expect(prices.prices(provider: "openai", models: ["gpt-5.5"]).isEmpty)
        let encoded = try #require(prices.encoded())
        let stored = try #require(ModelsDevPrices.decodeStored(encoded))
        #expect(stored.contextWindow(provider: "openai", model: "gpt-5.5") == 400_000)
    }
}
