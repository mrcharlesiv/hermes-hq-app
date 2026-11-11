// [model-facts] Owner 2026-11-10 (design pick 3): a model's row in the Models sheet says its context and price.

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct ModelRowFactTests {
    @Test func aPriceShortensToInSlashOut() {
        #expect(ModelPanelModel.shortPrice("$5.00 in · $25.00 out") == "$5 / $25")
        #expect(ModelPanelModel.shortPrice("$0.30 in · $1.25 out") == "$0.30 / $1.25")
        #expect(ModelPanelModel.shortPrice("$3.00 in") == "$3")
        #expect(ModelPanelModel.shortPrice("Included") == "Included")
        #expect(ModelPanelModel.shortPrice("Free") == "Free")
    }

    @Test func theLegendNamesBothFigures() {
        #expect(ModelPanelModel.rowFactLegend == "Prices are in / out per 1M tokens.")
    }
}
