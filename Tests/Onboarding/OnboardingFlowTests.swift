// [onboarding] The start screen rule and the back stack (docs/spec/3x-onboarding.md §3.2, §5.2).

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

struct OnboardingGateTests {
    @Test func everyCombination() {
        for bits in 0..<32 {
            let link = bits & 1 != 0, prefill = bits & 2 != 0, notice = bits & 4 != 0, before = bits & 8 != 0, atForm = bits & 16 != 0
            let entry = OnboardingGate.entry(linkAddress: link ? "https://a.example" : nil, prefillAddress: prefill ? "https://b.example" : "",
                                             notice: notice ? "Your session ended." : nil, signedInBefore: before, startAtForm: atForm)
            #expect(entry == (bits == 0 ? .welcome : .form), "bits \(bits)")
        }
    }

    /// What a Release build's clean first run passes: nothing at all → the welcome.
    @Test func releaseFirstRunIsTheWelcome() {
        #expect(OnboardingGate.entry(linkAddress: nil, prefillAddress: nil, notice: nil, signedInBefore: false, startAtForm: false) == .welcome)
        #expect(OnboardingGate.entry(linkAddress: "  ", prefillAddress: "\n", notice: "", signedInBefore: false, startAtForm: false) == .welcome)
        #expect(OnboardingGate.entry(linkAddress: nil, prefillAddress: nil, notice: nil, signedInBefore: true, startAtForm: false) == .form)
    }
}

@MainActor final class FlowDriver: SignInDriving {
    var passwordGate: CheckedContinuation<Void, Never>?
    var labels: [String?] = []
    var compat: GatewayCompatibility = .compatible
    var compatGate: CheckedContinuation<Void, Never>?
    var holdCompat = false
    var compatReads = 0
    var hold = false
    var failure: Error?

    func probe(_ address: String) async -> SignInOptions { SignInOptions(reachable: true, offersNous: false, offersPassword: true) }
    func signInWithPassword(address: String, username: String, password: String) async throws {
        try await signInWithPassword(address: address, username: username, password: password, label: nil)
    }
    func signInWithNous(address: String) async throws { try await signInWithNous(address: address, label: nil) }
    func signInWithPassword(address: String, username: String, password: String, label: String?) async throws {
        labels.append(label)
        if hold { await withCheckedContinuation { passwordGate = $0 } }
        if let failure { throw failure }
    }
    func signInWithNous(address: String, label: String?) async throws {
        labels.append(label)
        if let failure { throw failure }
    }
    func compatibility() async -> GatewayCompatibility {
        compatReads += 1
        if holdCompat { await withCheckedContinuation { compatGate = $0 } }
        return compat
    }
}

@MainActor func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}

@MainActor struct OnboardingFlowTests {
    let quiet = GuideActions(copy: { _ in true }, share: { _, _ in true }, open: { _ in true }, announce: { _ in })

    func flow(_ mode: OnboardingFlow.Mode = .root, entry: OnboardingEntry = .welcome, driver: FlowDriver = FlowDriver(),
              onOutcome: @escaping (SignInOutcome) -> Void = { _ in }) -> OnboardingFlow {
        let flow = OnboardingFlow(mode: mode, driver: driver, entry: entry, actions: quiet, onOutcome: onOutcome)
        flow.animated = false
        flow.formModel.delay = .seconds(600)
        return flow
    }

    let sheet = OnboardingFlow.Mode.sheet(title: "Add Gateway", cancelIdentifier: "add-gateway.cancel")

    @Test func startStacks() {
        #expect(flow(entry: .welcome).steps == [.welcome])
        #expect(flow(entry: .form).steps == [.welcome, .connect], "a returning start: the form, one Back from the welcome")
        #expect(flow(sheet).steps == [.connect], "the sheet has no welcome")
        #expect(flow(sheet, entry: .welcome).steps == [.connect])
    }

    /// The loops of §5.2's table.
    @Test func goPushesPopsToExistingAndIgnoresTheCurrentStep() {
        let first = flow()
        first.go(.hermes); first.go(.connect)
        #expect(first.steps == [.welcome, .hermes, .connect])
        first.go(.connect)
        #expect(first.steps == [.welcome, .hermes, .connect], "the step on show is a no-op")
        first.go(.hermes)                                    // "Need help connecting?"
        #expect(first.steps == [.welcome, .hermes], "a step already on the stack pops to it")

        let returning = flow(entry: .form)
        returning.go(.hermes)
        #expect(returning.steps == [.welcome, .connect, .hermes], "help from a returning form pushes")
        returning.go(.connect)                               // "I Have the Address"
        #expect(returning.steps == [.welcome, .connect])

        let mac = flow()
        for step in [OnboardingStep.hermes, .where, .mac1, .mac2, .mac3] { mac.go(step) }
        mac.go(.connect)                                     // "Type the Address Instead"
        #expect(mac.steps == [.welcome, .hermes, .where, .mac1, .mac2, .mac3, .connect])
        mac.go(.hermes)
        #expect(mac.steps == [.welcome, .hermes])
        mac.back()
        #expect(mac.steps == [.welcome])
        mac.back()
        #expect(mac.steps == [.welcome], "Back on the first screen does nothing")

        let inSheet = flow(sheet)
        inSheet.go(.hermes); inSheet.go(.where)
        #expect(inSheet.steps == [.connect, .hermes, .where])
        inSheet.back(); inSheet.back()
        #expect(inSheet.steps == [.connect])
    }

    @Test func aStepIsOnTheStackAtMostOnce() {
        let flow = flow()
        let walk: [OnboardingStep] = [.hermes, .where, .mac1, .mac2, .mac3, .connect, .hermes, .where, .linux1, .linux2, .linux3,
                                      .connect, .hermes, .where, .other1, .other2, .manual, .connect, .hermes, .connect, .welcome]
        for _ in 0..<50 {
            for step in walk {
                flow.go(step)
                #expect(Set(flow.steps).count == flow.steps.count && flow.steps.count <= 7, "\(flow.steps)")
            }
        }
        #expect(flow.steps == [.welcome])
    }

    @Test func everyStepHasItsScreenAndBarTitle() {
        let titles: [OnboardingStep: String] = [.where: "Set it up yourself", .mac1: "Step 1 of 3", .mac2: "Step 2 of 3", .mac3: "Step 3 of 3",
                                                .linux1: "Step 1 of 3", .linux2: "Step 2 of 3", .linux3: "Step 3 of 3",
                                                .other1: "Step 1 of 2", .other2: "Step 2 of 2", .manual: "Without Hermes’s help"]
        for step in OnboardingStep.allCases where step != .welcome {
            let flow = flow()
            flow.go(step)
            #expect(flow.current == step)
            let top = flow.navigationController.topViewController
            #expect(top?.navigationItem.title == (titles[step] ?? ""), "\(step)")
            #expect(top?.navigationItem.largeTitleDisplayMode == .never, "pushed pages use the small title")
        }
    }

    @Test func nothingMovesWhileASignInRuns() async {
        let driver = FlowDriver()
        driver.hold = true
        var outcomes: [SignInOutcome] = []
        let flow = flow(entry: .form, driver: driver) { outcomes.append($0) }
        let model = flow.formModel
        model.address = "fleet.example.com"; model.username = "fleet"; model.password = "secret"
        model.signInWithPassword()
        #expect(await eventually { driver.passwordGate != nil })
        #expect(flow.isBusy)
        flow.go(.hermes); flow.back()
        #expect(!flow.showForm(address: "https://other.example"))
        #expect(flow.steps == [.welcome, .connect] && model.address == "fleet.example.com")
        #expect(flow.navigationController.topViewController?.navigationItem.hidesBackButton == true)
        #expect(flow.navigationController.interactivePopGestureRecognizer?.isEnabled == false)
        driver.failure = SignInError("auth-rejected")
        driver.passwordGate?.resume()
        await model.attemptTask?.value
        #expect(!flow.isBusy && outcomes.isEmpty)
        #expect(flow.navigationController.topViewController?.navigationItem.hidesBackButton == false)
        flow.go(.hermes)
        #expect(flow.steps == [.welcome, .connect, .hermes], "Back and the help link work again after a failure")
    }

    @Test func sheetCancelIsOffWhileBusyAndOnEveryPage() async {
        let driver = FlowDriver()
        driver.hold = true
        let flow = flow(sheet, driver: driver)
        let form = flow.navigationController.viewControllers[0]
        #expect(form.navigationItem.title?.isEmpty != false, "the heading under the bar names the sheet (UX study #128)")
        #expect(form.navigationItem.leftBarButtonItem?.accessibilityIdentifier == "add-gateway.cancel")
        flow.go(.hermes)
        #expect(flow.navigationController.topViewController?.navigationItem.rightBarButtonItem?.accessibilityIdentifier == "add-gateway.cancel")
        flow.back()
        let model = flow.formModel
        model.address = "fleet.example.com"; model.username = "fleet"; model.password = "secret"
        model.signInWithPassword()
        #expect(await eventually { driver.passwordGate != nil })
        #expect(form.navigationItem.leftBarButtonItem?.isEnabled == false && flow.navigationController.isModalInPresentation)
        driver.failure = SignInError("auth-rejected")
        driver.passwordGate?.resume()
        await model.attemptTask?.value
        #expect(form.navigationItem.leftBarButtonItem?.isEnabled == true && !flow.navigationController.isModalInPresentation)
    }

    /// A connect link (the setup's QR code) while the guide is up lands on the form with its address; DECISION D7:
    /// what was typed survives a trip to the guide, except the password.
    @Test func showFormAndTheKeptAddress() {
        let flow = flow()
        for step in [OnboardingStep.hermes, .where, .mac1, .mac2, .mac3] { flow.go(step) }
        #expect(flow.showForm(address: "https://example-mac.tail1234.ts.net"))
        #expect(flow.current == .connect && flow.formModel.address == "https://example-mac.tail1234.ts.net")
        for n in 1...20 { flow.showForm(address: "https://mac-\(n).tail1234.ts.net") }
        #expect(flow.steps.filter { $0 == .connect }.count == 1 && flow.formModel.address == "https://mac-20.tail1234.ts.net")
        flow.formModel.username = "fleet"; flow.formModel.password = "secret"; flow.formModel.name = "Home Mac"
        flow.go(.hermes)                                     // pops the form off
        #expect(flow.steps == [.welcome, .hermes])
        flow.go(.connect)
        #expect(flow.formModel.address == "https://mac-20.tail1234.ts.net" && flow.formModel.name == "Home Mac")
        #expect(flow.formModel.password.isEmpty, "the password is never kept")
    }

    @Test func helpLinkGoesToLetHermes() {
        let flow = flow(entry: .form)
        flow.formModel.onHelp?()
        #expect(flow.current == .hermes)
        let demo = SignInModel(driver: FlowDriver(), onSignedIn: {})
        #expect(demo.onHelp == nil, "a form with no guide shows no help link")
    }

    @Test func lockedPushHasNoWayBack() {
        let flow = flow(sheet)
        let screen = UIViewController()
        flow.push(locked: screen)
        #expect(screen.navigationItem.hidesBackButton && screen.navigationItem.leftBarButtonItem == nil)
        #expect(flow.navigationController.isModalInPresentation && flow.navigationController.isNavigationBarHidden)
        flow.go(.hermes); flow.back()
        #expect(flow.navigationController.topViewController === screen, "nothing in the flow moves off it")
        #expect(!flow.popGesturesEnabled, "neither swipe back (edge, or iOS 26's from the content) can start")
        #expect(flow.navigationController.interactiveContentPopGestureRecognizer?.isEnabled != true)
        // A connect link under the locked screen changes nothing: the hidden form is not rewritten.
        flow.formModel.address = "https://kept.example.com"
        #expect(!flow.showForm(address: "https://other.example.com"))
        #expect(flow.formModel.address == "https://kept.example.com" && flow.navigationController.topViewController === screen)
    }

    /// The sign-in that leads to the locked screen ends after it is pushed: the end of busy must not unlock it.
    @Test func theEndOfBusyNeverUnlocksALockedScreen() async {
        let driver = FlowDriver()
        driver.hold = true
        let flow = flow(sheet, driver: driver)
        let model = flow.formModel
        #expect(flow.popGesturesEnabled)
        model.address = "fleet.example.com"; model.username = "fleet"; model.password = "secret"
        model.signInWithPassword()
        #expect(await eventually { driver.passwordGate != nil })
        #expect(flow.isBusy && !flow.popGesturesEnabled && flow.navigationController.isModalInPresentation, "busy: no swipe back")
        flow.push(locked: UIViewController())
        driver.failure = SignInError("auth-rejected")   // the attempt ends, so busy ends
        driver.passwordGate?.resume()
        await model.attemptTask?.value
        #expect(!flow.isBusy, "busy is over")
        #expect(!flow.popGesturesEnabled && flow.navigationController.isModalInPresentation, "…and the screen is still locked")
    }

    @Test func swipesComeBackWhenASignInFails() async {
        let driver = FlowDriver()
        driver.failure = SignInError("auth-rejected")
        let flow = flow(sheet, driver: driver)
        let model = flow.formModel
        model.address = "fleet.example.com"; model.username = "fleet"; model.password = "secret"
        model.signInWithPassword()
        await model.attemptTask?.value
        #expect(!flow.isBusy && flow.popGesturesEnabled && !flow.navigationController.isModalInPresentation)
    }

    /// The Add Gateway sheet is found under its own share sheet or browser (a connect link goes into its form, not
    /// into a second sheet), and its flow is let go when the sheet goes with its presenter.
    @Test func theSheetIsFoundUnderWhatItPresentsAndFreedWithItsPresenter() async {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }
        weak var gone: OnboardingFlow?
        weak var goneModel: SignInModel?
        do {
            let flow = flow(sheet)
            gone = flow; goneModel = flow.formModel
            let nav = flow.navigationController
            root.present(nav, animated: false)
            #expect(await eventually { nav.view.window != nil })
            #expect(AddGatewayFlow.openFlow(under: nav) === flow)
            let over = UIViewController()
            nav.present(over, animated: false)
            #expect(await eventually { nav.presentedViewController === over })
            #expect(AddGatewayFlow.openFlow(under: over) === flow, "under a share sheet or browser")
            #expect(AddGatewayFlow.openFlow(under: root) == nil)
            flow.go(.hermes)
            #expect(flow.showForm(address: "https://linked.example.com"))
            #expect(flow.current == .connect && flow.formModel.address == "https://linked.example.com")
            #expect(await eventually { nav.presentedViewController == nil }, "what was over the sheet is closed")
        }
        #expect(gone != nil, "the sheet keeps its flow while it is up")
        // The session under the sheet ends: the window's root is replaced, and the sheet goes with it.
        window.rootViewController = UIViewController()
        #expect(await eventually { gone == nil && goneModel == nil }, "the flow went with the sheet")
    }
}
