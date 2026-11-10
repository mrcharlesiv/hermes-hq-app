// [offline] The offline screen's controller (docs/spec/3x-offline.md §3.5) and "Change Address or Sign In"
// (§3.7): the sign-in form in a full-height sheet with Cancel, prefilled with the saved address and username so the
// common fix (a changed address) is an edit, not a retype. Cancel returns to the screen underneath, which never
// stopped retrying.

import SwiftUI
import UIKit

final class OfflineViewController: UIViewController {
    let screen: OfflineScreenModel
    var onTryAgain: (() -> Void)?
    var onDifferentGateway: (() -> Void)?
    var onSignInAgain: (() -> Void)?
    /// Another saved gateway, by id.
    var onSwitch: ((String) -> Void)?

    init(screen: OfflineScreenModel) {
        self.screen = screen
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.page
        view.accessibilityIdentifier = "offline"
        var exposes = false
        #if DEBUG
        exposes = OfflineDebug.exposesStatus
        #endif
        let content = OfflineView(model: screen,
                                  onTryAgain: { [weak self] in self?.onTryAgain?() },
                                  onDifferentGateway: { [weak self] in self?.onDifferentGateway?() },
                                  onSignInAgain: { [weak self] in self?.confirmSignInAgain() },
                                  onSwitch: { [weak self] id in self?.onSwitch?(id) },
                                  exposesStatus: exposes)
        let hosting = UIHostingController(rootView: content)
        hosting.view.backgroundColor = HQPalette.page
        addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        hosting.didMove(toParent: self)
        screen.announce = { words in HQAnnounce.say(words) }
    }

    /// An unreadable saved sign-in: ask before leaving it behind (§3.5).
    private func confirmSignInAgain() {
        let alert = UIAlertController(title: OfflineCopy.signInAgainTitle, message: OfflineCopy.signInAgainMessage, preferredStyle: .alert)
        let again = UIAlertAction(title: OfflineCopy.signInAgain, style: .default) { [weak self] _ in self?.onSignInAgain?() }
        alert.addAction(UIAlertAction(title: OfflineCopy.cancel, style: .cancel))
        alert.addAction(again)
        alert.preferredAction = again
        present(alert, animated: true)
    }
}

@MainActor enum DifferentGatewayFlow {
    /// The sign-in form over `presenter` with Cancel. `onSignedIn` runs after the sheet has gone, with the account the
    /// sign-in saved and made current. While a sign-in runs the sheet can't be closed (as Add Gateway's).
    ///
    /// [onboarding] The form is `OnboardingFlow` in sheet mode, as Add Gateway's (docs/spec/3x-onboarding.md §14.3 I1):
    /// "Need help connecting?" opens the guide inside the sheet, and an older Hermes shows "Update Hermes"
    /// locked in it, read once, before the app. `onSaved` runs the moment the sign-in is saved, before that
    /// version read: the screen underneath must stop reading and retrying from then on, or one of its own reads finds
    /// the new sign-in and enters the app under the busy form (D34).
    static func present(from presenter: UIViewController, model: AppModel, address: String, username: String,
                        onSaved: @escaping () -> Void = {}, onSignedIn: @escaping (GatewayAccount) -> Void) {
        guard let host = FailureAlert.topmost(presenter), !(host is UIAlertController) else { return }
        let driver = SheetSignInDriver(SignInServiceDriver(service: model.signIn))
        driver.onSaved = onSaved
        let flow = OnboardingFlow(mode: .sheet(title: "Sign In", cancelIdentifier: "offline.sign-in.cancel"),
                                  driver: driver, address: address, username: username) { [weak driver] outcome in
            // Held weakly: the form's model keeps this closure, the sheet keeps the form.
            guard let driver, let account = driver.signedIn else { return }
            let sheet = driver.sheet
            let enter = {
                if let sheet { sheet.dismiss(animated: true) { onSignedIn(account) } } else { onSignedIn(account) }
            }
            switch outcome {
            case .enter:
                enter()
            case .update(let info):
                let screen = UpdateHermesScreen.make(name: driver.signedInName, info: info, account: account, check: { [weak driver] in
                    await driver?.compatibility() ?? .unknown
                }, onEnter: enter)
                if let flow = driver.flow { flow.push(locked: screen) } else { enter() }
            }
        }
        let nav = flow.navigationController
        nav.modalPresentationStyle = .pageSheet
        nav.sheetPresentationController?.detents = [.large()]
        nav.view.accessibilityIdentifier = "offline.sign-in"
        driver.sheet = nav
        driver.flow = flow
        host.present(nav, animated: true)
    }
}
