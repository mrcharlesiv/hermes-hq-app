// [first-run] Puts the redrawn first run into today's flow (OnboardingFlow), only while `FirstRunArrival` is on and only
// in the signed-out root. It owns the stage, lays its three views over the flow's whole view (one under every screen,
// two over), builds the redrawn screens for welcome, start, hermes and connect, and changes between them with the mock's
// fade and rise (`.scr`, `.in`) instead of a sideways push. Screens it doesn't redraw open as today's, with the bar;
// the stage fades out there and comes back on the way back. The edge swipe back keeps working (the system's own slide).

import SwiftUI
import UIKit

@MainActor final class ArrivalHost: NSObject {
    let stage = ArrivalStage()
    let connect = ArrivalConnectState()
    let beats = ArrivalHereBeats()
    var kit: ArrivalKit { ArrivalKit(stage: stage) }
    private weak var navigation: OnboardingNavigationController?
    private var entrances: [OnboardingStep: ArrivalEntrance] = [:]
    /// Others came with it: the face sits higher (read once the roster is in, before Hermes is here shows).
    private var more = false
    /// The screens drawn over the stage.
    static let drawnSteps: Set<OnboardingStep> = [.welcome, .start, .hermes, .connect]

    init(navigation: OnboardingNavigationController) {
        self.navigation = navigation
        super.init()
        let view = navigation.view!
        view.insertSubview(stage.under, at: 0)
        view.addSubview(stage.over)
        view.addSubview(stage.touch)
        navigation.delegate = self
        navigation.onLayout = { [weak self] in self?.layout() }
        navigation.registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self, UITraitPreferredContentSizeCategory.self]) {
            (controller: OnboardingNavigationController, _) in
            controller.view.setNeedsLayout()
        }
        // With the bar hidden UIKit no longer starts the edge swipe on its own: this says when it may.
        navigation.interactivePopGestureRecognizer?.delegate = self
        connect.onChange = { [weak self] in self?.connectChanged() }
        stage.onFaceTap = { [weak self] in self?.stage.boop() }
    }

    /// Called once the stack has its first screens: the one on top comes on.
    func start() {
        guard let top = navigation?.topViewController else { return }
        apply(to: top, animated: false)
    }

    func entrance(_ step: OnboardingStep) -> ArrivalEntrance {
        if let made = entrances[step] { return made }
        let made = ArrivalEntrance()
        entrances[step] = made
        return made
    }

    /// A redrawn screen: today's step controller (so `go`, `steps` and the tests see the same step), see-through.
    func screen<Content: View>(_ step: OnboardingStep, @ViewBuilder content: () -> Content) -> OnboardingStepController {
        let controller = OnboardingStepController(step: step) { content().environment(stage.layout) }
        controller.view.backgroundColor = .clear
        return controller
    }

    /// Whether this controller shows over the stage now (the connect step only while it shows Found).
    func isDrawn(_ controller: UIViewController) -> Bool {
        if controller is ArrivalHereController { return true }
        guard let step = (controller as? OnboardingStepController)?.step, Self.drawnSteps.contains(step) else { return false }
        return step != .connect || !connect.full
    }

    // MARK: Layout

    private func layout() {
        guard let navigation, let view = navigation.view else { return }
        view.sendSubviewToBack(stage.under)
        view.bringSubviewToFront(stage.over)
        view.bringSubviewToFront(stage.touch)
        stage.fit(bounds: view.bounds, safeTop: view.safeAreaInsets.top, safeBottom: view.safeAreaInsets.bottom,
                  scale: view.window?.screen.scale ?? view.traitCollection.displayScale, traits: navigation.traitCollection)
    }

    // MARK: Screens coming on

    private func apply(to controller: UIViewController, animated: Bool) {
        let drawn = isDrawn(controller)
        if let navigation, navigation.isNavigationBarHidden != drawn {
            navigation.setNavigationBarHidden(drawn, animated: animated)
        }
        stage.setShown(drawn, animated: animated)
        guard drawn else { return }
        if controller is ArrivalHereController {
            stage.here(beats, more: more)
            return
        }
        guard let step = (controller as? OnboardingStepController)?.step else { return }
        entrance(step).count += 1
        switch step {
        case .welcome: stage.hello()
        case .start: stage.whereIs()
        case .hermes: stage.note()
        case .connect: stage.found()
        default: break
        }
    }

    /// Found ↔ today's form, in place on the connect step.
    private func connectChanged() {
        guard let navigation, let top = navigation.topViewController as? OnboardingStepController, top.step == .connect else { return }
        apply(to: top, animated: true)
        if connect.full { stage.scanning(false) }
    }

    // MARK: Hermes is here

    /// After the first sign-in: reads the bots (briefly: never a guess), then shows Hermes is here over the stage.
    /// `sayHello` gets the arriving bot's profile name.
    func arrive(client: LiveGatewayClient, flow: OnboardingFlow, sayHello: @escaping (String) -> Void) {
        connect.arriving = true
        Task { @MainActor [weak self, weak flow] in
            let roster = await Self.readRoster(client, budget: 2.5)
            guard let self, let flow else { return }
            AppLog.note("onboard", "first-run arrival: roster \(roster.known ? "in" : "not in"), others \(roster.others.count)")
            self.more = !roster.others.isEmpty
            // The colour the face itself is drawn in: a head's accent, or for an Ink head the ink (white on a dark page,
            // black on a light one), so the LEDs light in the colour they then become.
            let head = Head.resolve(roster.head, profile: roster.profile)
            let dark = self.navigation?.traitCollection.userInterfaceStyle == .dark
            self.stage.setAccent(head.color == .ink ? HeadRGB(dark ? 0xF4F4F2 : 0x0A0A0A) : HeadTones.accent(head.color))
            let profile = roster.profile
            // Say Hello: the face lifts off this screen and stays up while the app opens under it (ArrivalFlight).
            var lift: (() -> Void)?
            let here = ArrivalHereController(kit: self.kit, beats: self.beats, roster: roster) { lift?() }
            lift = { [weak here] in
                guard let here else { return sayHello(profile) }
                ArrivalFlight.takeOff(from: here.face, raw: roster.head, profile: profile) { sayHello(profile) }
            }
            flow.push(locked: here)
        }
    }

    /// The roster from `GET /api/profiles` (the socket isn't up before the app opens). The read's own timeout is the
    /// budget: past it nothing is known, and nothing is guessed. (No task group: `ChildTasksTests` keeps them out.)
    nonisolated static func readRoster(_ client: LiveGatewayClient, budget: Double) async -> ArrivalRoster {
        guard let data = try? await client.rest("GET", "/api/profiles", body: nil, timeout: budget),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return ArrivalRoster() }
        let rows = json["profiles"]?.array ?? json.array ?? []
        let profiles = rows.compactMap(RosterProfile.init(json:))
        guard let main = FirstRunArrival.arriving(profiles) else { return ArrivalRoster() }
        return ArrivalRoster(profile: main.name, head: main.head, known: true,
                             others: FirstRunArrival.others(profiles).map { ArrivalRoster.Other(name: $0.name, head: $0.head) })
    }

    /// Say Hello, once the app shows: the arriving bot's own chat, on the Bots tab, keyboard down.
    static func openChat(_ profile: String) {
        guard let root = MainTabController.current else { ArrivalFlight.current?.end(); return }
        root.select(.bots)
        root.botsViewController.navigationController?.popToRootViewController(animated: false)
        root.botsViewController.open(profile)
        // The face lands in the chat's header and the first words begin (ArrivalFirstWords), once the chat is on screen.
        ArrivalFlight.expect(chatOf: profile, in: root)
    }
}

// MARK: - Navigation

extension ArrivalHost: UINavigationControllerDelegate {
    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        apply(to: viewController, animated: animated)
        // A swipe back that is let go of halfway: the screen it started from comes back on.
        if let coordinator = navigationController.transitionCoordinator, coordinator.isInteractive {
            coordinator.notifyWhenInteractionChanges { [weak self] context in
                guard context.isCancelled, let self, let from = context.viewController(forKey: .from) else { return }
                self.apply(to: from, animated: true)
            }
        }
    }

    func navigationController(_ navigationController: UINavigationController, animationControllerFor operation: UINavigationController.Operation,
                              from fromVC: UIViewController, to toVC: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        // The swipe back is the system's own slide, with the finger.
        let swiping: Set<UIGestureRecognizer.State> = [.began, .changed]
        if let edge = navigationController.interactivePopGestureRecognizer, swiping.contains(edge.state) { return nil }
        if let content = navigationController.interactiveContentPopGestureRecognizer, swiping.contains(content.state) { return nil }
        guard isDrawn(fromVC) || (fromVC as? OnboardingStepController).map({ Self.drawnSteps.contains($0.step) }) == true,
              isDrawn(toVC) else { return nil }
        return ArrivalFadeTransition()
    }
}

extension ArrivalHost: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let navigation, gesture === navigation.interactivePopGestureRecognizer else { return true }
        return navigation.viewControllers.count > 1 && navigation.transitionCoordinator == nil
            && navigation.topViewController is OnboardingStepController
    }
}

/// The mock's change of screen: the old words fade (0.22 s), the new ones fade in (0.4 s) and rise 14 pt (0.55 s,
/// cubic-bezier(.2,.85,.2,1)). Under Reduce Motion, a cross-fade.
final class ArrivalFadeTransition: NSObject, UIViewControllerAnimatedTransitioning {
    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval { HQMotion.reduced ? 0.25 : 0.55 }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        guard let toVC = context.viewController(forKey: .to), let to = context.view(forKey: .to) ?? toVC.view else {
            context.completeTransition(false)
            return
        }
        let from = context.view(forKey: .from) ?? context.viewController(forKey: .from)?.view
        let container = context.containerView
        to.frame = context.finalFrame(for: toVC)
        container.addSubview(to)
        to.alpha = 0
        let rise: CGFloat = HQMotion.reduced ? 0 : 14
        to.transform = CGAffineTransform(translationX: 0, y: rise)
        // motion-ok: opacity only (the old words fading).
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut]) { from?.alpha = 0 }
        // motion-ok: opacity only (the new words fading in).
        UIView.animate(withDuration: 0.4, delay: 0, options: [.curveEaseInOut]) { to.alpha = 1 }
        // HQMotion.reduced: `rise` is 0 there, so this moves nothing.
        let mover = UIViewPropertyAnimator(duration: 0.55, timingParameters: UICubicTimingParameters(
            controlPoint1: CGPoint(x: 0.2, y: 0.85), controlPoint2: CGPoint(x: 0.2, y: 1)))
        mover.addAnimations { to.transform = .identity }
        mover.addCompletion { _ in
            from?.alpha = 1
            to.alpha = 1
            to.transform = .identity
            context.completeTransition(!context.transitionWasCancelled)
        }
        mover.startAnimation()
    }
}
