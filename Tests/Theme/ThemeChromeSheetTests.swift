// Owner report (2026-10-26, iPhone, Choose a Bot): the Desktop Look's 8 pt sheet radius put a floating sheet's bottom
// corners outside the screen's rounded ones, so they were cut off. The look keeps 8 pt on top; on a phone the bottom
// corners follow the screen's.

import Testing
import UIKit
@testable import HermesHQNative

@MainActor @Suite(.serialized) struct ThemeChromeSheetTests {
    @Test func aPhoneSheetKeeps8PointsOnTopAndFollowsTheScreenAtTheBottom() async throws {
        try #require(UIDevice.current.userInterfaceIdiom == .phone, "a phone simulator")
        let window = UIWindow(frame: UIScreen.main.bounds)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let navigation = UINavigationController(rootViewController: UIViewController())
        navigation.modalPresentationStyle = .pageSheet
        let sheet = try #require(navigation.sheetPresentationController)
        sheet.detents = [.medium(), .large()]
        ThemeChrome.styleSheet(sheet, of: navigation, desktop: true)
        #expect(sheet.preferredCornerRadius == 8, "the look's corners on top")
        root.present(navigation, animated: false)
        try await Task.sleep(for: .milliseconds(300))
        ThemeChrome.roundSheetBottom(sheet)
        let frame = try #require(sheet.presentedView)
        let expected = UICornerConfiguration.uniformTopRadius(.fixed(8), bottomLeftRadius: .containerConcentric(minimum: 8),
                                                              bottomRightRadius: .containerConcentric(minimum: 8))
        #expect(frame.cornerConfiguration == expected, "8 pt on top, the screen's curve at the bottom")
        navigation.dismiss(animated: false)
        ThemeChrome.styleSheet(sheet, of: navigation, desktop: false)
        #expect(sheet.preferredCornerRadius == nil, "the look off: the system's corners again")
    }
}
