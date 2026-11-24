// [asks] An ask card's "Something else…" strip over the message field (owner 2026-11-23: an "Answering: …" question
// that wrapped stood over the field's top edge).

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@MainActor @Suite("Composer · the Answering strip keeps clear of the field", .serialized)
struct AnsweringBannerFitTests {
    private func answering(_ question: String) -> ComposerEditBanner {
        ComposerEditBanner(title: "Answering: \(question)", symbol: "arrowshape.turn.up.left", note: nil, cancelLabel: "Cancel",
                           identifier: "composer.answeringAsk", cancelInWords: true)
    }

    /// The composer sized as the chat sizes it: to its own intrinsic height, read only when it reports a change
    /// (`onHeightChange`), never polled. Then layout passes until it settles.
    private func settle(_ composer: ComposerView, in window: UIWindow) {
        for _ in 0..<4 {
            window.layoutIfNeeded()
            composer.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))   // a report from layout rides the next turn
        }
    }

    private func make(width: CGFloat) -> (UIWindow, ComposerView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 800))
        let composer = ComposerView(frame: .zero)
        window.addSubview(composer)
        window.isHidden = false
        func fit() {
            let h = composer.intrinsicContentSize.height
            composer.frame = CGRect(x: 0, y: window.bounds.height - h - 34, width: width, height: h)
        }
        composer.onHeightChange = { fit() }
        fit()
        settle(composer, in: window)
        return (window, composer)
    }

    @Test(arguments: [320.0, 393.0, 402.0, 440.0])
    func aWrappedQuestionStandsAboveTheField(width: CGFloat) throws {
        let (window, composer) = make(width: width)
        let banner = answering("Send Isaac the short reply asking for times for the Salesforce scoping call?")
        composer.editBanner = banner
        settle(composer, in: window)
        #expect(banner.frame.height > 44, "the question wraps at this width")
        #expect(banner.frame.maxY <= composer.fieldFrame.minY, "strip \(banner.frame) over field \(composer.fieldFrame)")
        // Snug: the strip's own words fit it, with no empty line's worth under them.
        let fitted = banner.systemLayoutSizeFitting(CGSize(width: banner.bounds.width, height: UIView.layoutFittingCompressedSize.height),
                                                    withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        #expect(abs(banner.frame.height - max(44, ceil(fitted.height))) <= 1)
        withExtendedLifetime(window) {}
    }

    @Test func aShortQuestionTakesOneLine() throws {
        let (window, composer) = make(width: 402)
        let banner = answering("Start with the pilot group?")
        composer.editBanner = banner
        settle(composer, in: window)
        #expect(banner.frame.height == 44, "one line: \(banner.frame)")
        #expect(banner.frame.maxY <= composer.fieldFrame.minY)
        withExtendedLifetime(window) {}
    }
}
