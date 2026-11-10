import UIKit

/// The account's kept password, secret and vault sheets (spec 1x §4.5, §3.3 rule 9), by request id. A sheet lives
/// exactly as long as its request: tucked, or left behind when its chat closes, it keeps the typed text, and reopening
/// the chat re-presents the same instance. When the request goes (answered, withdrawn, pruned) or the account signs
/// out, its text is cleared and the sheet released (Q15, R6). Owned by AppModel beside the `ServerRequestCenter`
/// (`onRemoved` drops sheets); a chat screen without one (previews) makes its own and empties it when it goes.
@MainActor final class PromptSheetStore {
    private struct Kept {
        let sheet: PromptSheetController
        /// Holds the sheet; the sheet only points back weakly.
        let navigation: UINavigationController
        var tucked: Bool
    }

    private var kept: [String: Kept] = [:]

    init() {}

    /// The sheet of an open value prompt: the kept one, else a new one (`created`).
    func sheet(for prompt: ValuePrompt, botName: String? = nil) -> (sheet: PromptSheetController, created: Bool) {
        if let k = kept[prompt.id] { return (k.sheet, false) }
        let (sheet, navigation) = PromptSheetController.make(prompt, botName: botName)
        kept[prompt.id] = Kept(sheet: sheet, navigation: navigation, tucked: false)
        return (sheet, true)
    }

    func existing(_ id: String) -> PromptSheetController? { kept[id]?.sheet }
    func navigation(_ id: String) -> UINavigationController? { kept[id]?.navigation }
    func isTucked(_ id: String) -> Bool { kept[id]?.tucked ?? false }
    func setTucked(_ id: String, _ tucked: Bool) { kept[id]?.tucked = tucked }
    var ids: Set<String> { Set(kept.keys) }

    /// These requests went: their text is cleared, a sheet still up is dismissed (no chip), and they are released.
    func drop(_ ids: some Sequence<String>) {
        for id in ids {
            guard let k = kept.removeValue(forKey: id) else { continue }
            k.sheet.clear()
            Self.dismiss(k.navigation)
        }
    }

    /// Dismisses a sheet frame that is up, or coming up (after its presentation ends: a request withdrawn while its
    /// sheet slides in). Nothing to do when it is already down or going.
    static func dismiss(_ navigation: UINavigationController, then completion: (() -> Void)? = nil) {
        if navigation.isBeingPresented, let coordinator = navigation.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { _ in
                if navigation.presentingViewController != nil, !navigation.isBeingDismissed {
                    navigation.dismiss(animated: true, completion: completion)
                } else {
                    completion?()
                }
            }
        } else if navigation.presentingViewController != nil, !navigation.isBeingDismissed {
            navigation.dismiss(animated: true, completion: completion)
        } else {
            completion?()
        }
    }

    /// Sign-out, account switch, or the screen-owned store going.
    func removeAll() { drop(Array(kept.keys)) }
}
