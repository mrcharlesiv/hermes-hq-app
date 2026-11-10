// [main-e2e] Tabs are found by their item's id ("tab-more"): the system bar's button, or the Desktop Look's own bar's.
// A tab put in while the system bar is on screen (Kanban Tab › Off makes tab 3 Artifacts; a gateway switch makes the
// tabs again) shows there without its item's id (iOS 26; setting the id again doesn't reach the button), so there it is
// found by its label.

import XCTest

extension XCUIApplication {
    @MainActor func tabButton(id: String, label: String) -> XCUIElement {
        let byID = buttons[id].firstMatch
        if !byID.waitForExistence(timeout: 2), tabBars.buttons[label].exists { return tabBars.buttons[label].firstMatch }
        return byID
    }
}
