// [photoheads] The sheet holds while a page on it is saving (stress round 1: Edit Bot could be pulled down during a
// slow photo upload, and "Discard Changes" closed the page while the picture was still saved for every phone).

import Testing
import UIKit
@testable import HermesHQNative

@MainActor
struct EditingGuardTests {
    private final class Page: UIViewController, EditingPage {
        var hasChanges = false
        var isSaving = false
    }

    @Test func aSavingPageHoldsTheSheetAndIsNeverAskedToDiscard() {
        let root = UIViewController(), page = Page()
        let navigation = UINavigationController(rootViewController: root)
        navigation.pushViewController(page, animated: false)
        let guardian = SheetEditGuard(navigation: navigation)
        let presentation = UIPresentationController(presentedViewController: navigation, presenting: nil)

        // Nothing typed, nothing saving: free to close, nothing asked.
        page.updateModalLock()
        #expect(!navigation.isModalInPresentation)
        guardian.presentationControllerDidAttemptToDismiss(presentation)
        #expect(EditingGuard.question == nil)

        // Dirty and saving: held, and the pull down asks nothing.
        page.hasChanges = true
        page.isSaving = true
        page.updateModalLock()
        #expect(navigation.isModalInPresentation)
        #expect(EditingGuard.isSaving(in: navigation))
        guardian.presentationControllerDidAttemptToDismiss(presentation)
        #expect(EditingGuard.question == nil)
        var left = false
        page.confirmLeaving { left = true }
        #expect(!left && EditingGuard.question == nil)

        // The save's own change has landed but the answer is not handled yet: still held.
        page.hasChanges = false
        page.updateModalLock()
        #expect(navigation.isModalInPresentation)
        #expect(navigation.interactivePopGestureRecognizer?.isEnabled != true)

        // Dirty, not saving: held (the pull down then asks; the UI suite's testS8 sees the question).
        page.hasChanges = true
        page.isSaving = false
        page.updateModalLock()
        #expect(navigation.isModalInPresentation)
        #expect(!EditingGuard.isSaving(in: navigation))

        page.hasChanges = false
        page.isSaving = false
        page.updateModalLock()
        #expect(!navigation.isModalInPresentation)
    }
}
