// [onboarding] The welcome, the connection guide and the sign-in form as one navigation stack (docs/spec/3x-onboarding.md
// §3.1, §5.2): the signed-out root (rooted at the welcome) and the Add Gateway sheet (rooted at the form, with Cancel).
// `go` is the web's (`W:src/connection-onboarding.ts:18-25`): the step on show is a no-op, a step already on the stack
// pops to it, anything else pushes; nothing moves while a sign-in runs.

import SwiftUI
import UIKit

/// One screen of the flow. It carries its step (the Mac and Linux screens share classes).
final class OnboardingStepController: UIHostingController<HQScaledRoot<AnyView>> {
    let step: OnboardingStep

    init<Content: View>(step: OnboardingStep, title: String = "", @ViewBuilder content: () -> Content) {
        self.step = step
        super.init(rootView: HQScaledRoot(AnyView(content())))
        view.backgroundColor = HQPalette.page
        // DECISION D4: the web's eyebrow is the small title on the bar row; the heading is content.
        navigationItem.title = title
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal
    }

    @available(*, unavailable) required dynamic init?(coder: NSCoder) { fatalError("not from a storyboard") }
}

/// The flow's stack. As a sheet it keeps its flow alive until the sheet is closed (nothing else holds it there).
final class OnboardingNavigationController: UINavigationController {
    fileprivate var owner: OnboardingFlow?
    /// The flow this sheet shows (nil for the signed-out root, whose flow the scene holds).
    var onboardingFlow: OnboardingFlow? { owner }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        releaseFlowIfGone()
    }

    /// The sheet was closed, or went with its presenter (the window's root was replaced under it): let the flow go.
    /// A browser or share sheet over it keeps it presented, so the flow lives through that.
    func releaseFlowIfGone() {
        if isBeingDismissed || presentingViewController == nil || (view.window == nil && presentedViewController == nil) {
            owner = nil
        }
    }
}

@MainActor final class OnboardingFlow {
    enum Mode {
        /// The signed-out root: the stack is rooted at the welcome.
        case root
        /// A sheet over the app (Add Gateway…, signing a saved gateway back in): rooted at the form, with Cancel.
        case sheet(title: String, cancelIdentifier: String)
    }

    let navigationController: UINavigationController
    let formModel: SignInModel
    private let mode: Mode
    private let actions: GuideActions
    /// "This iPhone already uses Tailscale", chosen on the first setup screen and kept for the ones after it.
    private let reach = SetupReach()
    private var form: OnboardingStepController?
    private let cancels = NSHashTable<UIBarButtonItem>.weakObjects()
    /// Tests turn the push and pop animations off.
    var animated = true
    /// Opens Hermes Cloud over this flow. Set before the guide is shown; nil hides the Hermes Cloud rows.
    var openCloud: (() -> Void)?

    /// Set while a sign-in or the version check after it runs: every step change is ignored, Back and Cancel are off.
    private(set) var isBusy = false { didSet { if isBusy != oldValue { applyBusy() } } }
    /// Set once a locked screen (the Update screen in the sheet) is on top: nothing pops it, busy or not.
    private(set) var isLocked = false

    /// - Parameters:
    ///   - entry: `.welcome` shows `[welcome]`; `.form` shows `[welcome, connect]` (the form, one Back from the welcome).
    ///   - actions: copy, share and links; nil for the real ones, presenting over this flow.
    init(mode: Mode, driver: any SignInDriving, entry: OnboardingEntry = .form, address: String = "", username: String = "",
         notice: String? = nil, actions: GuideActions? = nil, onOutcome: @escaping (SignInOutcome) -> Void) {
        self.mode = mode
        let navigation = OnboardingNavigationController()
        navigation.view.backgroundColor = HQPalette.page
        navigationController = navigation
        self.actions = actions ?? .live { [weak navigation] in navigation }
        formModel = SignInScreen.model(driver: driver, initialAddress: address, initialUsername: username, notice: notice,
                                       onOutcome: onOutcome)
        formModel.onHelp = { [weak self] in self?.go(.hermes) }
        // The headings: "Add another Hermes." when adding one (UX study #24; the web says "Add a gateway."), "Sign in to Hermes." everywhere else (D36).
        if case .sheet(let title, _) = mode, title == "Add Gateway" { formModel.heading = OnboardingCopy.addHeading }
        else { formModel.heading = OnboardingCopy.formHeading }
        formModel.onBusyChanged = { [weak self] busy in self?.isBusy = busy }
        switch mode {
        case .root:
            navigation.viewControllers = entry == .welcome ? [make(.welcome)] : [make(.welcome), make(.connect)]
        case .sheet:
            navigation.viewControllers = [make(.connect)]
            navigation.owner = self
        }
    }

    /// The steps on the stack, bottom first.
    var steps: [OnboardingStep] {
        navigationController.viewControllers.compactMap { ($0 as? OnboardingStepController)?.step }
    }

    var current: OnboardingStep? { (navigationController.topViewController as? OnboardingStepController)?.step }

    func go(_ step: OnboardingStep) {
        guard !isBusy, step != current, navigationController.topViewController is OnboardingStepController else { return }
        let leavingForm = current == .connect
        AppLog.trace("onboard", "onboarding step reached: \(step)")
        if let existing = navigationController.viewControllers.first(where: { ($0 as? OnboardingStepController)?.step == step }) {
            // The form popped off for the guide keeps what was typed, except the password (DECISION D7).
            if leavingForm { formModel.leftForGuide() }
            navigationController.popToViewController(existing, animated: animated)
        } else {
            navigationController.pushViewController(make(step), animated: animated)
        }
    }

    func back() {
        guard !isBusy, navigationController.viewControllers.count > 1,
              navigationController.topViewController is OnboardingStepController else { return }   // never off a locked screen
        navigationController.popViewController(animated: animated)
    }

    /// The web's `showConnect`: the form, from wherever the flow is, with this address in the field (a connect link).
    /// False while busy (nothing changed).
    @discardableResult func showForm(address: String) -> Bool {
        // Not under a locked screen either: the form is hidden there, and a link must not rewrite it unseen.
        guard !isBusy, navigationController.topViewController is OnboardingStepController else { return false }
        navigationController.presentedViewController?.dismiss(animated: false)   // a share sheet or browser over the guide
        go(.connect)
        formModel.fill(address: address)
        return true
    }

    /// Another screen takes over the stack's top (the Update screen in the sheet): no Back, no Cancel, no swipe down.
    func push(locked controller: UIViewController) {
        controller.navigationItem.hidesBackButton = true
        controller.navigationItem.leftBarButtonItem = nil
        controller.navigationItem.rightBarButtonItem = nil
        isLocked = true
        navigationController.isModalInPresentation = true
        applyPopGestures()
        // The bar goes whole: a hosting controller on a stack can bring its Back button back whatever the item says.
        navigationController.setNavigationBarHidden(true, animated: animated)
        navigationController.pushViewController(controller, animated: animated)
    }

    /// Audit 06-13: the prefilled form after a gateway ended this phone's session, while other saved gateways still have
    /// theirs. The form's bar offers them ("Switch to <name>"), so that one gateway's sign-in never hides the rest.
    func offerOtherGateways(_ gateways: [(id: String, title: String)], switchTo: @escaping (String) -> Void) {
        guard !gateways.isEmpty else { return }
        let actions = gateways.map { gateway in
            UIAction(title: OfflineCopy.switchTo(gateway.title), image: UIImage(systemName: "arrow.left.arrow.right")) { [weak self] _ in
                guard let self, !self.isBusy else { return }
                switchTo(gateway.id)
            }
        }
        let item = UIBarButtonItem(title: "Gateways", image: UIImage(systemName: "server.rack"),
                                   menu: UIMenu(title: "Other Gateways", children: actions))
        item.accessibilityIdentifier = "sign-in.other-gateways"
        makeForm().navigationItem.rightBarButtonItem = item
    }

    // MARK: Screens

    private func make(_ step: OnboardingStep) -> UIViewController {
        let controller = build(step)
        // In the sheet, Cancel closes it from any depth: leading on the form, trailing beside Back on a guide screen.
        if case .sheet(_, let identifier) = mode, controller.navigationItem.leftBarButtonItem == nil,
           controller.navigationItem.rightBarButtonItem == nil {
            let item = UIBarButtonItem.hqClose(.cancel, action: UIAction { [weak self] _ in
                self?.navigationController.dismiss(animated: true)
            })
            item.accessibilityIdentifier = identifier
            item.isEnabled = !isBusy
            if step == .connect { controller.navigationItem.leftBarButtonItem = item } else { controller.navigationItem.rightBarButtonItem = item }
            cancels.add(item)
        }
        return controller
    }

    private func build(_ step: OnboardingStep) -> UIViewController {
        let go: (OnboardingStep) -> Void = { [weak self] next in self?.go(next) }
        let actions = self.actions, reach = self.reach
        let cloud: (() -> Void)? = openCloud == nil ? nil : { [weak self] in
            guard let self, !self.isBusy else { return }
            self.openCloud?()
        }
        switch step {
        case .welcome:
            return OnboardingStepController(step: step) { WelcomeView(go: go) }
        case .hermes:
            return OnboardingStepController(step: step) { LetHermesView(actions: actions, reach: reach, go: go, cloud: cloud) }
        case .where:
            let fill: (String) -> Void = { [weak self] address in self?.showForm(address: address) }
            return OnboardingStepController(step: step, title: OnboardingCopy.Where.eyebrow) { WhereView(actions: actions, go: go, fill: fill, cloud: cloud) }
        case .mac1, .linux1:
            let kind: OnboardingCopy.QuickKind = step == .mac1 ? .mac : .linux
            return OnboardingStepController(step: step, title: OnboardingCopy.quick(kind).eyebrow1) {
                QuickSetupCommandView(kind: kind, actions: actions, reach: reach, go: go)
            }
        case .mac2, .linux2:
            let kind: OnboardingCopy.QuickKind = step == .mac2 ? .mac : .linux
            return OnboardingStepController(step: step, title: OnboardingCopy.quick(kind).eyebrow2) {
                QuickSetupRunView(kind: kind, actions: actions, reach: reach, go: go)
            }
        case .mac3, .linux3:
            let kind: OnboardingCopy.QuickKind = step == .mac3 ? .mac : .linux
            return OnboardingStepController(step: step, title: OnboardingCopy.quick(kind).eyebrow3) {
                QuickSetupScanView(kind: kind, reach: reach, go: go)
            }
        case .other1:
            return OnboardingStepController(step: step, title: OnboardingCopy.Windows.eyebrow1) { WindowsTailscaleView(actions: actions, go: go) }
        case .other2:
            return OnboardingStepController(step: step, title: OnboardingCopy.Windows.eyebrow2) { WindowsMessageView(actions: actions, go: go) }
        case .manual:
            return OnboardingStepController(step: step, title: OnboardingCopy.Manual.eyebrow) { ManualSetupView(actions: actions, go: go) }
        case .connect:
            return makeForm()
        }
    }

    /// The form is made once and kept: popped off for the guide and shown again, it still holds what was typed.
    private func makeForm() -> UIViewController {
        if let form { return form }
        let model = formModel
        // UX study #128: no bar title, in the sheet as on the root form. The heading under it ("Add another Hermes.",
        // "Sign in to Hermes.") names the sheet, and VoiceOver reads it as the screen's header; the bar keeps Cancel.
        let controller = OnboardingStepController(step: .connect) { SignInView(model: model) }
        form = controller
        return controller
    }

    private func applyBusy() {
        navigationController.topViewController?.navigationItem.hidesBackButton = isBusy
        applyPopGestures()
        for item in cancels.allObjects { item.isEnabled = !isBusy }
        if case .sheet = mode { navigationController.isModalInPresentation = isBusy || isLocked }
    }

    /// Both swipes back (from the edge, and iOS 26's from anywhere in the content) are off while busy or locked.
    private func applyPopGestures() {
        let enabled = !isBusy && !isLocked
        navigationController.interactivePopGestureRecognizer?.isEnabled = enabled
        navigationController.interactiveContentPopGestureRecognizer?.isEnabled = enabled
    }

    /// Whether a swipe back can start (tests read it).
    var popGesturesEnabled: Bool {
        navigationController.interactivePopGestureRecognizer?.isEnabled != false
            && navigationController.interactiveContentPopGestureRecognizer?.isEnabled != false
    }
}
