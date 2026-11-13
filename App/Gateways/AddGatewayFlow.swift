// Add Gateway… (spec 1x-settings §4.3) and signing a saved-but-signed-out gateway back in before switching to it
// (§4.4 step 2, DECISION: the current gateway stays until that sign-in succeeds). The sign-in form in a full-height
// sheet with Cancel; success saves the account first and current, then the app switches to it. While a sign-in runs
// the sheet can't be closed (Cancel off, no swipe down): `SignInService` saves the new account as current and ends the
// active client when it succeeds, so "Cancel → nothing changes" holds only before or after an attempt.
//
// [onboarding] The form is `OnboardingFlow` in sheet mode (docs/spec/3x-onboarding.md §3.1): "Need help connecting?"
// pushes the guide inside the sheet, and an older Hermes shows "Update Hermes on Your Gateway" in it (§5.15).

import SwiftUI
import UIKit

@MainActor enum AddGatewayFlow {
    /// `address`: a gateway address to fill in (the hermes://connect QR), when there is no saved account to prefill.
    static func present(from presenter: UIViewController?, services: any AppServices, prefill: GatewayAccount? = nil,
                        address typed: String? = nil) {
        guard let settings = services as? SettingsServices, let host = FailureAlert.topmost(presenter) else { return }
        // A connect link while the sheet is already up goes into its form (the web's `showConnect`).
        // The sheet may be under its own share sheet or browser: look down from the top for it.
        if let flow = openFlow(under: host) {
            if let typed, prefill == nil { flow.showForm(address: typed) }
            return
        }
        let driver = SheetSignInDriver(settings.makeSignInDriver())
        let address = prefill?.baseURL.absoluteString ?? typed ?? ""
        let username = prefill?.kind == .password ? (prefill?.username ?? "") : ""
        let notice = prefill.map { _ in "Sign in again to switch to this gateway." }
        let flow = OnboardingFlow(mode: .sheet(title: prefill == nil ? "Add Gateway" : "Sign In", cancelIdentifier: "add-gateway.cancel"),
                                  driver: driver, address: address, username: username, notice: notice) { [weak driver] outcome in
            // Held weakly: the form's model keeps this closure, the sheet keeps the form.
            guard let driver, let account = driver.signedIn else { return }
            let sheet = driver.sheet
            settings.adoptSignedInAccount(account)
            switch outcome {
            case .enter:
                sheet?.dismiss(animated: true)
            case .update(let info):
                // DECISION D12: the app underneath is already on the new gateway (its old client ended with the sign-in).
                let screen = UpdateHermesScreen.make(name: driver.signedInName, info: info, account: account, check: { [weak driver] in
                    await driver?.compatibility() ?? .unknown
                }, onEnter: { [weak sheet] in
                    sheet?.dismiss(animated: true)
                })
                driver.flow?.push(locked: screen)
            }
        }
        let nav = flow.navigationController
        // Its guide offers Hermes Cloud too: this sheet makes way for that one (the switch was already confirmed).
        if prefill == nil {
            flow.openCloud = { [weak nav, weak host] in
                nav?.dismiss(animated: true) { CloudGatewayFlow.present(from: host, services: services) }
            }
        }
        SheetStyle.apply(nav, from: host)   // UX study #161: a form sheet in two panes
        nav.sheetPresentationController?.detents = [.large()]
        driver.sheet = nav
        driver.flow = flow
        host.present(nav, animated: true)
    }
}

extension AddGatewayFlow {
    /// The Add Gateway sheet's flow when the sheet is `top` or somewhere under it.
    static func openFlow(under top: UIViewController) -> OnboardingFlow? {
        var controller: UIViewController? = top
        while let current = controller {
            if let flow = (current as? OnboardingNavigationController)?.onboardingFlow { return flow }
            controller = current.presentingViewController
        }
        return nil
    }
}

/// The form's driver for the sheet: forwards to `SignInServiceDriver`. Owned by the form's model (the only strong
/// reference), so the sheet frees with it. The sheet is held closed-proof by the flow while the form is busy.
final class SheetSignInDriver: SignInDriving {
    private let base: SignInServiceDriver
    weak var sheet: UIViewController?
    weak var flow: OnboardingFlow?
    /// Runs the moment a sign-in is saved and current, before the version read the form then waits on (the offline
    /// screen stands down here: docs/spec/3x-onboarding.md D34).
    var onSaved: (() -> Void)?

    init(_ base: SignInServiceDriver) { self.base = base }

    var signedIn: GatewayAccount? { base.signedIn }
    var signedInName: String { base.signedInName }

    func probe(_ address: String) async -> SignInOptions { await base.probe(address) }

    func signInWithPassword(address: String, username: String, password: String) async throws {
        try await signInWithPassword(address: address, username: username, password: password, label: nil)
    }

    func signInWithNous(address: String) async throws {
        try await signInWithNous(address: address, label: nil)
    }

    func signInWithPassword(address: String, username: String, password: String, label: String?) async throws {
        try await base.signInWithPassword(address: address, username: username, password: password, label: label)
        onSaved?()
    }

    func signInWithNous(address: String, label: String?) async throws {
        try await base.signInWithNous(address: address, label: label)
        onSaved?()
    }

    func compatibility() async -> GatewayCompatibility { await base.compatibility() }
    func useAccess(_ access: CloudflareAccess?) { base.useAccess(access) }                                  // [cf-access]
    func savedAccess(for address: String) -> CloudflareAccess? { base.savedAccess(for: address) }
}
