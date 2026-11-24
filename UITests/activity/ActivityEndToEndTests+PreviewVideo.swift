import XCTest

// [preview-tab] A bot opens a video on its computer with `desktop_preview` and a label ("Demo video"): it plays in
// Quick Look. Before, the copy was kept under the label with no type, so Quick Look refused it and the share sheet
// came up instead.
extension ActivityEndToEndTests {
    @MainActor func test27_PreviewOfALabelledVideoPlays() throws {
        let account = try FixtureAccount.load()
        guard let media = ProcessInfo.processInfo.environment["HQN_ACTIVITY_MEDIA"] else { throw XCTSkip("needs HQN_ACTIVITY_MEDIA") }
        guard FileManager.default.fileExists(atPath: media + "/demo.mov") else { throw XCTSkip("needs demo.mov in HQN_ACTIVITY_MEDIA") }
        try reset(account)
        let app = launch(account)
        openChat(app)
        try event(account, "preview.open", ["url": media + "/demo.mov", "label": "Demo video"])

        XCTAssertTrue(app.otherElements["QLPreviewControllerView"].waitForExistence(timeout: 15), "the video opens in Quick Look")
        XCTAssertTrue(app.otherElements["QLPreviewControllerView"].otherElements["Video"].waitForExistence(timeout: 10),
                      "Quick Look shows it as a video (not a blank file)")
        XCTAssertFalse(app.otherElements["ActivityListView"].exists, "not the share sheet")
        XCTAssertFalse(app.alerts["Couldn’t Open File"].exists, "no error")
        Thread.sleep(forTimeInterval: 1.5)
        shot("preview-labelled-video")
    }
}
