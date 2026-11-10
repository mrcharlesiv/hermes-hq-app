// The sign-in screen's driver over the Net module's `SignInService`: the probe's answer as the form's options, and every
// failure as a `SignInError` with the stable code (spec 01 §18) and the module's plain words.

import UIKit

final class SignInServiceDriver: SignInDriving {
    let service: SignInService
    /// The account the last successful sign-in saved and made current.
    private(set) var signedIn: GatewayAccount?

    init(service: SignInService) { self.service = service }

    func probe(_ address: String) async -> SignInOptions {
        let result = await service.probe(address)
        // `.unknown` (unreachable, not Hermes, odd answer) shows both ways in; the attempt itself says what is wrong.
        return SignInOptions(reachable: result.known, offersNous: result.nous, offersPassword: result.password)
    }

    func signInWithPassword(address: String, username: String, password: String) async throws {
        try await signInWithPassword(address: address, username: username, password: password, label: nil)
    }

    func signInWithNous(address: String) async throws { try await signInWithNous(address: address, label: nil) }

    // [onboarding] The optional Name becomes the account's label on this phone (never sent to the gateway).
    func signInWithPassword(address: String, username: String, password: String, label: String?) async throws {
        do {
            signedIn = try await service.signInWithPassword(address: address, username: username, password: password, label: label)
        } catch {
            throw Self.signInError(error)
        }
    }

    func signInWithNous(address: String, label: String?) async throws {
        do {
            signedIn = try await service.signInWithNous(address: address, anchor: Self.keyWindow, label: label)
        } catch {
            throw Self.signInError(error)
        }
    }

    /// [onboarding] One read of the just-signed-in gateway's status (docs/spec/3x-onboarding.md §5.14).
    func compatibility() async -> GatewayCompatibility {
        guard let signedIn else { return .unknown }
        return await service.compatibility(for: signedIn)
    }

    /// [onboarding] The gateway's name for the Update screen's card: the Name just typed, else its computer's name.
    var signedInName: String {
        guard let signedIn else { return GatewayNaming.unnamed }
        return UpdateHermesScreen.name(url: signedIn.baseURL, label: service.store.stored(signedIn)?.label)
    }

    static func signInError(_ error: any Error) -> SignInError {
        let failure = GatewayFailure.from(error)
        return SignInError(failure.code, detail: failure.message)
    }

    /// The system sign-in sheet is presented over the key window.
    private static var keyWindow: UIWindow? {
        UIApplication.shared.hqKeyWindow   // [mac] the Settings window when it's in front (Mac polish #36)
    }
}
