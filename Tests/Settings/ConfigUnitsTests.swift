// [mac] Stress test 2026-10-28 #95, #101: the Mac form's numbers read with grouping and units, a percent field writes
// the share the gateway keeps, and nothing else changes what is sent.

import Foundation
import Testing
@testable import HermesHQNative

struct ConfigUnitsTests {
    private let us = Locale(identifier: "en_US")

    @Test func numbersReadWithGroupingAndUnits() {
        #expect(ConfigUnits.display(key: "model_context_length", value: 100_000, locale: us) == "100,000 tokens")
        #expect(ConfigUnits.display(key: "approvals.timeout", value: 60, locale: us) == "60 seconds")
        #expect(ConfigUnits.display(key: "approvals.timeout", value: 1, locale: us) == "1 second")
        #expect(ConfigUnits.display(key: "compression.threshold", value: 0.5, locale: us) == "50%")
        #expect(ConfigUnits.display(key: "compression.target_ratio", value: 0.2, locale: us) == "20%")
        #expect(ConfigUnits.display(key: "some.unknown_number", value: 50_000, locale: us) == "50,000")
    }

    @Test func fieldsRoundTripTheSameValue() {
        #expect(ConfigUnits.fieldText(key: "compression.threshold", value: .number(0.5), locale: us) == "50")
        #expect(ConfigUnits.value(key: "compression.threshold", text: "50", locale: us) == .number(0.5))
        #expect(ConfigUnits.value(key: "compression.threshold", text: "20%", locale: us) == .number(0.2))
        #expect(ConfigUnits.fieldText(key: "tool_output.max_bytes", value: .number(50_000), locale: us) == "50,000")
        #expect(ConfigUnits.value(key: "tool_output.max_bytes", text: "50,000", locale: us) == .number(50_000))
        #expect(ConfigUnits.value(key: "agent.max_turns", text: "", locale: us) == .number(0))
        #expect(ConfigUnits.value(key: "agent.max_turns", text: "ninety", locale: us) == nil)
    }

    @Test func emptyValuesReadOneWay() {
        let empty = ConfigFieldModel(key: "terminal.cwd", label: "Folder", description: nil, control: .text, value: nil, defaultValue: nil)
        #expect(ConfigUnits.summary(empty, locale: us) == "None")
        let count = ConfigFieldModel(key: "agent.max_turns", label: "Max Agent Steps", description: nil, control: .number,
                                     value: .number(90), defaultValue: nil)
        #expect(ConfigUnits.summary(count, locale: us) == "90 steps")
        let automatic = ConfigFieldModel(key: "model_context_length", label: "Context", description: nil, control: .number,
                                         value: .number(0), defaultValue: nil)
        #expect(ConfigUnits.summary(automatic, locale: us) == "Automatic")
    }

    @Test func labelsAndSentences() {
        #expect(ConfigUnits.label("Compression Model Timeout (s)", key: "auxiliary.compression.timeout") == "Compression Model Timeout")
        #expect(ConfigUnits.label("Turn (s)", key: "unknown") == "Turn (s)")
        #expect(ConfigUnits.sentence("Ask before reloading connectors") == "Ask before reloading connectors.")
        #expect(ConfigUnits.sentence("Already ends.") == "Already ends.")
        #expect(ConfigUnits.sentence("Claude API access (Sonnet, Opus, Haiku)") == "Claude API access (Sonnet, Opus, Haiku).")
        #expect(ConfigUnits.sentence("Ends inside (like this.)") == "Ends inside (like this.)")
    }
}
