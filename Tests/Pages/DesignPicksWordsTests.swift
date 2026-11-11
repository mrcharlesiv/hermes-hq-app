// Owner 2026-11-10 (design picks 14, 23, 24): the short points and lines that replaced paragraphs.

import Testing
@testable import HermesHQNative

@MainActor @Suite struct DesignPicksWordsTests {
    /// [screen-points] Three points, the sharing warning last and the only one marked as a warning.
    @Test func screenControlIsThreePointsWithOneWarning() {
        let points = ScreenSetupCopy.points
        #expect(points.count == 3)
        #expect(points.filter(\.warning).count == 1)
        #expect(points.last?.warning == true)
        #expect(points.last?.lead == "Your whole screen is shared,")
        #expect(points.allSatisfy { !$0.lead.isEmpty && !$0.rest.isEmpty })
    }

    /// [terminal-points] The risk leads; the unlock line is there only when an unlock is asked.
    @Test func theTerminalsRiskLeadsAndTheUnlockLineIsOptional() {
        let locked = TerminalConsentWords.points(unlock: "Face ID")
        #expect(locked.count == 3)
        #expect(locked.first?.warning == true)
        #expect(locked.last?.lead == "Face ID is asked")
        #expect(TerminalConsentWords.points(unlock: nil).count == 2)
    }

    /// [bubbles-note] One line for each style.
    @Test func theBubbleNoteFollowsTheStyle() {
        #expect(ChatBubblesSettingsView.styleLine(.solid).hasPrefix("Solid:"))
        #expect(ChatBubblesSettingsView.styleLine(.glass).hasPrefix("Glass:"))
        #expect(ChatBubblesSettingsView.styleLine(.tinted).hasPrefix("Tinted:"))
    }
}
