// n20 revisit, stream `transcript` (docs/briefs/n20-transcript-report.md item F17, originally commit 6652ce9d on
// fix/n20-transcript, never merged): formulas drawn as maths. An extension of TranscriptEndToEndTests, so
// scripts/e2e-transcript.sh runs it (light, then dark) against the transcript fixture.

import XCTest

extension TranscriptEndToEndTests {
    /// The four looks every visible change is checked in: Desktop Look off and on, default and Extra Large text.
    /// "Extra Large" is the accessibility range's XXXL (as the rest of the suite uses it, e.g.
    /// `ActivityEndToEndTests`, `SessionsTests+Row`, `ComposerUITests+Drawers`) — the standard range's plain "XL"
    /// step is barely bigger than the default and does not stress the formula's own scaling.
    static let n20Looks: [(name: String, args: [String])] = [
        ("ios", ["-hqn.theme.desktopLook", "<false/>"]),
        ("ios-xl", ["-hqn.theme.desktopLook", "<false/>", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]),
        ("desktop", ["-hqn.theme.desktopLook", "<true/>"]),
        ("desktop-xl", ["-hqn.theme.desktopLook", "<true/>", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]),
    ]

    // MARK: T18 Formulas drawn as maths (F17, L310)

    @MainActor func testT18_Formulas() throws {
        let account = try FixtureAccount.load()
        try preset(account, "math")
        for look in Self.n20Looks {
            let app = launch(account, args: look.args)
            // VoiceOver reads a formula as "Formula: " and its source (the bubble's label); the drawn text is the maths.
            XCTAssertTrue(labelled(app, containing: "Formula: E = mc^2").waitForExistence(timeout: 15), "the inline formula (\(look.name))")
            XCTAssertTrue(labelled(app, containing: "Formula: \\frac{a}{b} \\leq \\sqrt{x^2 + y^2}").exists, "the display formula")
            XCTAssertTrue(labelled(app, containing: "it costs $5 and $10").exists, "prices stay words")
            XCTAssertFalse(labelled(app, containing: "$E = mc^2$").exists, "no formula is read with its dollar signs")
            // The formula outside the subset shows as its source, in a code card.
            XCTAssertTrue(labelled(app, containing: "begin{aligned}").exists, "the source of what the phone can't draw")
            shot("n20-math-\(look.name)")
            app.terminate()
        }
    }
}
