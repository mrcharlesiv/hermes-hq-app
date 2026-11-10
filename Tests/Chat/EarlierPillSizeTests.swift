import Testing
import UIKit
@testable import HermesHQNative

/// [transcript] §4.2: "Show earlier messages" alone is one button tall. Build 434 left the hidden words' 40 pt row in
/// the pill, so the button sat under an empty band twice its height (owner screenshot, 2026-10-28).
@MainActor
struct EarlierPillSizeTests {
    private func height(_ state: ChatEarlierPill.State) -> CGFloat {
        let pill = ChatEarlierPill()
        pill.set(state)
        pill.layoutIfNeeded()
        return pill.systemLayoutSizeFitting(CGSize(width: 320, height: 0), withHorizontalFittingPriority: .fittingSizeLevel,
                                            verticalFittingPriority: .fittingSizeLevel).height
    }

    @Test func showEarlierMessagesIsOneButtonTall() {
        #expect(height(.idle) == 48)   // the 44 pt button and 2 pt above and below
    }

    @Test func loadingIsTheSameHeightSoTappingDoesNotJump() {
        #expect(height(.loading) == height(.idle))
    }

    @Test func theFailureStillHasRoomForItsWordsAndTryAgain() {
        #expect(height(.failed) >= 2 + 44 + 44 + 2)
    }
}
