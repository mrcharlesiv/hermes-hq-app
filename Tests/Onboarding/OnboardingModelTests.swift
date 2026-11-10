// [onboarding] The parts with rules but no screen: copy/share feedback, the version rule, the Name field, the check
// before the app shows, the Update screen's model, and the unreadable saved sign-in. docs/spec/3x-onboarding.md §9.1.

import Foundation
import SafariServices
import Testing
import UIKit
@testable import HermesHQNative

@MainActor final class ActionLog {
    var copied: [String] = [], shared: [String] = [], opened: [URL] = [], said: [String] = []
    var copyWorks = true, shareWorks = true, openWorks = true
    var actions: GuideActions {
        GuideActions(copy: { self.copied.append($0); return self.copyWorks }, share: { text, _ in self.shared.append(text); return self.shareWorks },
                     open: { self.opened.append($0); return self.openWorks }, announce: { self.said.append($0) })
    }
}

@MainActor struct GuideFeedbackTests {
    @Test func copyHandsOverTheExactTextAndSaysWhereToPasteIt() {
        for kind in OnboardingCopy.FeedbackKind.allCases {
            let log = ActionLog()
            let feedback = GuideFeedback(kind, actions: log.actions)
            #expect(feedback.status.isEmpty)
            feedback.copy()
            #expect(log.copied == [kind.text] && feedback.status == kind.copied && log.said == [kind.copied])
            log.copyWorks = false
            feedback.copy()
            #expect(feedback.status == kind.couldNotCopy && log.said.last == kind.couldNotCopy)
        }
    }

    @Test func aShareThatOpensLeavesTheLineEmpty() {
        let log = ActionLog()
        let feedback = GuideFeedback(.connect, actions: log.actions)
        feedback.copy()
        feedback.share()
        #expect(log.shared == [OnboardingCopy.connectCommand] && feedback.status.isEmpty, "a new tap clears the old line")
        log.shareWorks = false
        feedback.share()
        #expect(feedback.status == "Couldn’t open sharing. Tap Copy instead." && log.said.last == feedback.status)
    }

    /// "This iPhone already uses Tailscale": Copy and Send hand over the `--private` command and message, and only those
    /// two cards change.
    @Test func tailnetOnlyHandsOverThePrivateCommandAndMessage() {
        let log = ActionLog(), reach = SetupReach()
        let mac = GuideFeedback(.connect, actions: log.actions, reach: reach)
        let linux = GuideFeedback(.connectLinux, actions: log.actions, reach: reach)
        let agent = GuideFeedback(.agent, actions: log.actions, reach: reach)
        mac.copy()
        #expect(log.copied == [OnboardingCopy.connectCommand], "off by default")
        reach.tailnetOnly = true
        mac.copy(); linux.share(); agent.copy()
        #expect(log.copied == [OnboardingCopy.connectCommand, OnboardingCopy.Tailnet.command, OnboardingCopy.Tailnet.prompt])
        #expect(log.shared == [OnboardingCopy.Tailnet.command])
        #expect(mac.status == OnboardingCopy.FeedbackKind.connect.copied, "the same line under the card")
        for kind in [OnboardingCopy.FeedbackKind.prompt, .steps] { #expect(kind.text(tailnetOnly: true) == kind.text) }
    }

    @Test func eachCardKeepsItsOwnLine() {
        let log = ActionLog()
        let first = GuideFeedback(.agent, actions: log.actions), second = GuideFeedback(.prompt, actions: log.actions)
        first.copy()
        #expect(second.status.isEmpty)
        second.copy()
        #expect(first.status == OnboardingCopy.FeedbackKind.agent.copied && second.status == OnboardingCopy.FeedbackKind.prompt.copied)
    }

    @Test func aLinkThatCannotOpenSaysSoWithItsAddress() async {
        let log = ActionLog()
        let links = GuideLinkOpener(actions: log.actions)
        links.open(OnboardingCopy.Links.tailscaleApp)
        await links.task?.value
        #expect(links.error.isEmpty && log.opened.map(\.absoluteString) == [OnboardingCopy.Links.tailscaleApp])
        log.openWorks = false
        links.open(OnboardingCopy.Links.tailscaleApp)
        await links.task?.value
        #expect(links.error == "Couldn’t open it. Open this address in Safari: https://apps.apple.com/app/tailscale/id1470499037")
        #expect(log.said == [links.error])
        log.openWorks = true
        links.open(OnboardingCopy.Links.hermes)
        #expect(links.error.isEmpty, "the next tap clears the line")
        await links.task?.value
        let guide = GuideLinkOpener(actions: log.actions, failure: OnboardingCopy.couldNotOpenGuide)
        log.openWorks = false
        guide.open(OnboardingCopy.Links.hermes)
        await guide.task?.value
        #expect(guide.error == "Couldn’t open the guide. Open this address in Safari: https://hermes-agent.nousresearch.com/docs/")
    }

    /// A second tap while the browser is already up (the live `open` answers true: nothing to do) is not an error.
    @Test func aSecondTapWhileTheBrowserIsUpIsNoError() async {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }
        var said: [String] = []
        var live = GuideActions.live { root }
        live.announce = { said.append($0) }
        let links = GuideLinkOpener(actions: live)
        links.open(OnboardingCopy.Links.hermes)
        await links.task?.value
        #expect(root.presentedViewController is SFSafariViewController && links.error.isEmpty)
        let first = root.presentedViewController
        links.open(OnboardingCopy.Links.hermes)   // while it is still rising
        await links.task?.value
        links.open(OnboardingCopy.Links.dashboard)
        await links.task?.value
        #expect(links.error.isEmpty && said.isEmpty, "\(links.error)")
        #expect(root.presentedViewController === first, "and no second browser")
        root.dismiss(animated: false)
    }

    @Test func onlySecureWebLinksOpen() {
        #expect(GuideActions.opens(URL(string: "https://tailscale.com/docs")!))
        for bad in ["http://tailscale.com", "javascript:alert(1)", "file:///etc/hosts", "tel:911", "hermeshq://connect?url=x", "https://"] {
            #expect(!GuideActions.opens(URL(string: bad)!), "\(bad)")
        }
        for address in [OnboardingCopy.Links.hermes, OnboardingCopy.Links.dashboard, OnboardingCopy.Links.tailscaleServe,
                        OnboardingCopy.Links.tailscaleApp, OnboardingCopy.Links.tailscaleAdmin] {
            #expect(GuideActions.opens(URL(string: address)!))
        }
    }
}

/// R11: the web lazy-loads the guide to keep it out of startup. Natively the guide is compiled in; this holds each
/// screen to building and laying out fast, so there is never a wait to cover with a loading state.
@MainActor struct GuideBuildTests {
    @Test func everyGuideScreenBuildsAndLaysOutFast() {
        let quiet = GuideActions(copy: { _ in true }, share: { _, _ in true }, open: { _ in true }, announce: { _ in })
        let flow = OnboardingFlow(mode: .root, driver: FlowDriver(), entry: .welcome, actions: quiet, onOutcome: { _ in })
        flow.animated = false
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = flow.navigationController
        window.isHidden = false
        window.layoutIfNeeded()
        flow.go(.hermes); window.layoutIfNeeded(); flow.back()          // warm SwiftUI itself, as the welcome already has
        var slowest: (OnboardingStep, Duration) = (.welcome, .zero)
        for step in OnboardingStep.guide {
            let started = ContinuousClock.now
            flow.go(step)
            window.layoutIfNeeded()
            let took = ContinuousClock.now - started
            if took > slowest.1 { slowest = (step, took) }
            #expect(flow.current == step)
            flow.go(.welcome)
        }
        #expect(slowest.1 < .milliseconds(250), "slowest: \(slowest.0) in \(slowest.1)")
        window.isHidden = true
    }
}

struct GatewayCompatibilityTests {
    func status(_ fields: [String: JSONValue]) -> JSONValue { .object(fields) }

    @Test func theRule() {
        func verdict(_ date: String) -> GatewayCompatibility { GatewayCompatibility(status: status(["release_date": .string(date)])) }
        #expect(verdict("2026.9.21") == .compatible && verdict("2026.9.22") == .compatible && verdict("2027.1.1") == .compatible)
        #expect(verdict("2026.10.1") == .compatible, "compared as numbers, not as text")
        #expect(verdict("2026.9.20") == .outdated(OutdatedGateway(releaseDate: "2026.9.20")))
        #expect(verdict("2026.09.20").outdated?.releaseDate == "2026.09.20" && verdict("2025.12.31").outdated != nil)
        #expect(verdict("  2026.9.20\n").outdated?.releaseDate == "2026.9.20", "trimmed, shown as reported")
        for odd in ["", " ", "2026.9", "2026.9.20.1", "26.9.20", "2026.13.1", "2026.0.1", "2026.9.0", "2026.9.32", "2026-09-20", "v2026.9.20",
                    "2026.9.20 beta", "２０２６.９.２０", "2026.9.-1", "20260.9.20", "2026.123.1", "yesterday", "2026..20", "0x7EA.9.20"] {
            #expect(verdict(odd) == .unknown, "“\(odd)” is not a release date")
        }
    }

    @Test func whatIsNotTextNeverBlocks() {
        for value: JSONValue in [.null, .number(20260920), .bool(true), .array([.string("2026.9.20")]), .object(["a": .string("2026.9.20")])] {
            #expect(GatewayCompatibility(status: status(["release_date": value])) == .unknown)
        }
        #expect(GatewayCompatibility(status: status([:])) == .unknown && GatewayCompatibility(status: .null) == .unknown)
        #expect(GatewayCompatibility(status: .array([])) == .unknown && GatewayCompatibility(status: .string("2026.9.20")) == .unknown)
    }

    @Test func versionAndCanUpdate() {
        func outdated(_ extra: [String: JSONValue]) -> OutdatedGateway? {
            GatewayCompatibility(status: status(extra.merging(["release_date": .string("2026.9.20")]) { a, _ in a })).outdated
        }
        #expect(outdated([:]) == OutdatedGateway(version: "", releaseDate: "2026.9.20", canUpdate: true))
        #expect(outdated(["version": .string(" 0.13.0 ")])?.version == "0.13.0")
        #expect(outdated(["version": .number(13)])?.version == "" && outdated(["version": .null])?.version == "")
        #expect(outdated(["version": .string(String(repeating: "9", count: 4096))])?.version.count == 24)
        #expect(outdated(["can_update_hermes": .bool(false)])?.canUpdate == false)
        for other: JSONValue in [.bool(true), .null, .string("false"), .number(0)] {
            #expect(outdated(["can_update_hermes": other])?.canUpdate == true, "only a real false turns the update command off")
        }
    }

    @Test func theScreensWords() {
        #expect(OutdatedCopy.title == "Update Hermes")
        #expect(OutdatedCopy.recovery(canUpdate: true) == "Hermes HQ needs a newer version of Hermes than the computer running Hermes has, and parts of the app won’t work until it’s updated. On the computer running Hermes, run “hermes update”, then check again.")
        #expect(OutdatedCopy.recovery(canUpdate: false) == "Hermes HQ needs a newer version of Hermes than the computer running Hermes has, and parts of the app won’t work until it’s updated. Update Hermes on the computer running Hermes the way it was installed, then check again.")
        #expect(OutdatedCopy.release(OutdatedGateway(version: "0.13.0", releaseDate: "2026.9.20")) == "Hermes 0.13.0 · released 2026.9.20")
        #expect(OutdatedCopy.release(OutdatedGateway(releaseDate: "2026.9.20")) == "Hermes · released 2026.9.20")
        #expect(OutdatedCopy.checkAgain == "Check Again" && OutdatedCopy.continueAnyway == "Continue Anyway" && OutdatedCopy.checking == "Checking…")
        #expect(OutdatedCopy.stillOlder == "Still the older version. An update can take a few minutes.")
        #expect(UpdateHermesScreen.name(url: URL(string: "https://example-mac.tail1234.ts.net")!, label: "  Home Mac ") == "Home Mac")
        #expect(UpdateHermesScreen.name(url: URL(string: "http://127.0.0.1:9990")!, label: nil) == "Your Gateway")
        #expect(UpdateHermesScreen.name(url: URL(string: "https://studio-mac.tail1234.ts.net")!, label: " ")
                == GatewayNaming.friendlyName(URL(string: "https://studio-mac.tail1234.ts.net")!))
    }

    @Test func theCapAnswersUnknownAndDropsALateAnswer() async {
        let started = ContinuousClock.now
        let slow = await CompatibilityCap.run(.milliseconds(60)) {
            try? await Task.sleep(for: .seconds(2))
            return .outdated(OutdatedGateway(releaseDate: "2026.9.20"))
        }
        #expect(slow == .unknown && ContinuousClock.now - started < .seconds(1))
        // The cap winning cancels the read behind it (no read runs on beside the next Check Again).
        final class Flag: @unchecked Sendable { var cancelled = false }
        let flag = Flag()
        _ = await CompatibilityCap.run(.milliseconds(40)) {
            do { try await Task.sleep(for: .seconds(2)) } catch { flag.cancelled = true }
            return .compatible
        }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(flag.cancelled, "the capped read was cancelled")
        #expect(await CompatibilityCap.run(.seconds(5)) { .compatible } == .compatible)
        #expect(CompatibilityCap.standard == .seconds(4))
    }
}

@MainActor struct SignInNameTests {
    @Test func theLabelRule() {
        #expect(SignInService.accountLabel(nil) == nil && SignInService.accountLabel("") == nil && SignInService.accountLabel(" \n\t ") == nil)
        #expect(SignInService.accountLabel("  Home Mac ") == "Home Mac")
        #expect(SignInService.accountLabel(String(repeating: "a", count: 61))?.count == 60)
        #expect(SignInService.accountLabel(String(repeating: "👩‍👩‍👧‍👦", count: 61)) == String(repeating: "👩‍👩‍👧‍👦", count: 60), "never half a character")
        #expect(SignInService.accountLabel("<script>alert(1)</script>") == "<script>alert(1)</script>", "it is only ever shown as text")
        #expect(SignInService.accountLabel("مرحبا  بيت") == "مرحبا  بيت")
    }

    /// A connect link never carries a typed password to another address.
    @Test func aNewAddressDropsTheTypedPassword() {
        let model = SignInModel(driver: FlowDriver(), onSignedIn: {})
        model.delay = .seconds(600)
        model.address = "fleet.example.com"; model.username = "fleet"; model.password = "secret"
        model.fill(address: "https://fleet.example.com")
        #expect(model.password == "secret" && model.username == "fleet", "the same address, typed another way: kept")
        model.fill(address: "  HTTPS://fleet.example.com ")
        #expect(model.password == "secret")
        model.fill(address: "https://other-host.example.com")
        #expect(model.password.isEmpty && model.address == "https://other-host.example.com", "another host never gets it")
        #expect(model.username == "fleet", "the username is not a secret and stays")
    }

    /// [mac] The setup link its QR code holds, pasted into the field, leaves the address in it; anything else stays as typed.
    @Test func aPastedSetupLinkBecomesItsAddress() {
        let model = SignInModel(driver: FlowDriver(), onSignedIn: {})
        model.delay = .seconds(600)
        model.address = "hermes://connect?url=https%3A%2F%2FMy-Mac.tailnet-name.ts.net%3A10000"
        #expect(model.address == "https://my-mac.tailnet-name.ts.net:10000")
        model.address = " \(AppIdentity.current.urlScheme)://connect?url=https%3A%2F%2Fhome.example.com "
        #expect(model.address == "https://home.example.com")
        model.address = "hermes://connect?url=http%3A%2F%2Fhome.example.com"
        #expect(model.address == "hermes://connect?url=http%3A%2F%2Fhome.example.com", "not a plain https address: left alone")
        model.address = "hermes://session/abc"
        #expect(model.address == "hermes://session/abc")
    }

    @Test func theFieldStopsAtSixty() {
        let model = SignInModel(driver: FlowDriver(), onSignedIn: {})
        model.name = String(repeating: "x", count: 500)
        #expect(model.name.count == 60)
        model.name = String(repeating: "🤖", count: 80)
        #expect(model.name == String(repeating: "🤖", count: 60))
    }

    @Test func theNameGoesWithEitherWayOfSigningIn() async {
        let driver = FlowDriver()
        let model = SignInModel(driver: driver, onSignedIn: {})
        model.delay = .seconds(600)
        model.address = "fleet.example.com"; model.username = "fleet"; model.password = "secret"; model.name = "  Home Mac  "
        model.signInWithPassword()
        await model.attemptTask?.value
        #expect(driver.labels == ["Home Mac"])
        let second = SignInModel(driver: driver, onSignedIn: {})
        second.delay = .seconds(600)
        second.address = "fleet.example.com"; second.name = "   "
        second.signInWithNous()
        await second.attemptTask?.value
        #expect(driver.labels == ["Home Mac", nil], "a blank Name is no name")
    }
}

@MainActor struct SignInModelCompatTests {
    func model(_ driver: FlowDriver, _ outcomes: @escaping (SignInOutcome) -> Void) -> SignInModel {
        let model = SignInModel(driver: driver, onOutcome: outcomes)
        model.delay = .seconds(600)
        model.successHaptic = {}
        model.address = "fleet.example.com"; model.username = "fleet"; model.password = "secret"
        return model
    }

    @Test func theFormStaysBusyThroughTheCheck() async {
        let driver = FlowDriver()
        driver.holdCompat = true
        var outcomes: [SignInOutcome] = [], busy: [Bool] = []
        let model = model(driver) { outcomes.append($0) }
        model.onBusyChanged = { busy.append($0) }
        model.signInWithPassword()
        #expect(await eventually { driver.compatGate != nil })
        #expect(model.busy == .password && outcomes.isEmpty && busy == [true], "signed in, still checking: nothing shows yet")
        model.signInWithPassword(); model.signInWithNous()
        #expect(driver.labels.count == 1, "one attempt per tap")
        driver.compatGate?.resume()
        await model.attemptTask?.value
        #expect(outcomes == [.enter] && model.password.isEmpty && driver.compatReads == 1)
    }

    @Test func anOlderGatewayGoesToTheUpdateScreen() async {
        let driver = FlowDriver()
        let old = OutdatedGateway(version: "0.13.0", releaseDate: "2026.9.20", canUpdate: false)
        driver.compat = .outdated(old)
        var outcomes: [SignInOutcome] = [], taps = 0
        let model = model(driver) { outcomes.append($0) }
        model.successHaptic = { taps += 1 }
        model.signInWithPassword()
        await model.attemptTask?.value
        #expect(outcomes == [.update(old)] && taps == 0, "the success tap waits for the app")
    }

    @Test func unknownAndSlowNeverBlock() async {
        for (compat, hold) in [(GatewayCompatibility.unknown, false), (.compatible, false), (.outdated(OutdatedGateway(releaseDate: "2026.9.20")), true)] {
            let driver = FlowDriver()
            driver.compat = compat; driver.holdCompat = hold
            var outcomes: [SignInOutcome] = [], taps = 0
            let model = model(driver) { outcomes.append($0) }
            model.compatibilityCap = .milliseconds(80)
            model.successHaptic = { taps += 1 }
            model.signInWithPassword()
            await model.attemptTask?.value
            #expect(outcomes == [.enter] && taps == 1, "\(compat) hold \(hold)")
            driver.compatGate?.resume()
        }
    }

    @Test func noCheckAfterAFailedSignIn() async {
        let driver = FlowDriver()
        driver.failure = SignInError("auth-rejected")
        var outcomes: [SignInOutcome] = []
        let model = model(driver) { outcomes.append($0) }
        model.signInWithPassword()
        await model.attemptTask?.value
        #expect(driver.compatReads == 0 && outcomes.isEmpty && model.busy == nil && model.error != nil)
        #expect(model.password == "secret", "a failed attempt keeps what was typed")
    }

    @Test func returnInTheNameFieldSignsInTheWayTheFormOffers() async {
        let driver = FlowDriver()
        var outcomes: [SignInOutcome] = []
        let model = model(driver) { outcomes.append($0) }
        model.submitFromName()
        #expect(driver.labels.isEmpty, "nothing is offered until the address has been asked about")
        model.ask()
        await model.probeTask?.value
        model.name = "Home Mac"
        model.submitFromName()
        await model.attemptTask?.value
        #expect(driver.labels == ["Home Mac"] && outcomes == [.enter])
    }
}

@MainActor struct UpdateHermesModelTests {
    final class Gate {
        var answers: [GatewayCompatibility] = []
        var reads = 0
        var held: CheckedContinuation<Void, Never>?
        var hold = false
    }

    func model(_ gate: Gate, info: OutdatedGateway = OutdatedGateway(version: "0.13.0", releaseDate: "2026.9.20"),
               entered: @escaping () -> Void) -> UpdateHermesModel {
        let model = UpdateHermesModel(name: "Home Mac", info: info, check: {
            gate.reads += 1
            if gate.hold { await withCheckedContinuation { gate.held = $0 } }
            return gate.answers.isEmpty ? .unknown : gate.answers.removeFirst()
        }, onEnter: entered)
        model.announce = { _ in }
        model.successHaptic = {}
        return model
    }

    @Test func stillOlderSaysSoAndShowsWhatTheGatewayReportsNow() async {
        let gate = Gate()
        gate.answers = [.outdated(OutdatedGateway(version: "0.13.1", releaseDate: "2026.9.20", canUpdate: false))]
        var entered = 0, said: [String] = []
        let model = model(gate) { entered += 1 }
        model.announce = { said.append($0) }
        #expect(model.status.isEmpty && model.release == "Hermes 0.13.0 · released 2026.9.20" && model.recovery.contains("run “hermes update”"))
        model.checkAgain()
        #expect(model.busy && model.status == "Checking…")
        await model.checkTask?.value
        #expect(entered == 0 && model.phase == .stillOutdated && model.status == OutdatedCopy.stillOlder)
        #expect(model.release == "Hermes 0.13.1 · released 2026.9.20" && model.recovery.contains("the way it was installed"))
        #expect(said == ["Checking…", OutdatedCopy.stillOlder])
    }

    @Test func anythingElseEnters() async {
        for answer in [GatewayCompatibility.compatible, .unknown] {
            let gate = Gate()
            gate.answers = [answer]
            var entered = 0, taps = 0
            let model = model(gate) { entered += 1 }
            model.successHaptic = { taps += 1 }
            model.checkAgain()
            await model.checkTask?.value
            #expect(entered == 1 && taps == 1)
            model.checkAgain(); model.continueAnyway()
            #expect(entered == 1 && gate.reads == 1, "it has left: nothing fires twice")
        }
    }

    @Test func oneCheckAtATimeAndContinueWaitsForIt() async {
        let gate = Gate()
        gate.hold = true
        gate.answers = [.outdated(OutdatedGateway(releaseDate: "2026.9.20"))]
        var entered = 0
        let model = model(gate) { entered += 1 }
        for _ in 0..<50 { model.checkAgain() }
        #expect(await eventually { gate.held != nil })
        model.continueAnyway()
        #expect(gate.reads == 1 && entered == 0, "both buttons are off while checking")
        gate.hold = false
        gate.held?.resume()
        await model.checkTask?.value
        #expect(model.phase == .stillOutdated)
        model.continueAnyway(); model.continueAnyway()
        #expect(entered == 1)
    }

    @Test func aCheckThatNeverAnswersEntersAtTheCap() async {
        let gate = Gate()
        gate.hold = true
        var entered = 0
        let model = model(gate) { entered += 1 }
        model.cap = .milliseconds(80)
        let started = ContinuousClock.now
        model.checkAgain()
        await model.checkTask?.value
        #expect(entered == 1 && ContinuousClock.now - started < .seconds(2))
        gate.held?.resume()
    }

    @Test func fiftyChecksAgainstAnOlderGatewayNeverEnter() async {
        let gate = Gate()
        var entered = 0
        let model = model(gate) { entered += 1 }
        for n in 1...50 {
            gate.answers = [.outdated(OutdatedGateway(version: "0.13.\(n)", releaseDate: "2026.9.20"))]
            model.checkAgain()
            await model.checkTask?.value
            #expect(model.release == "Hermes 0.13.\(n) · released 2026.9.20")
        }
        #expect(entered == 0 && gate.reads == 50 && model.phase == .stillOutdated)
    }
}

@MainActor struct UnreadableSignInTests {
    #if targetEnvironment(simulator)
    /// DECISION D27: nothing discards the unreadable item; the next sign-in's save replaces it whole.
    @Test func aSignInSavesOverAnUnreadableItem() throws {
        let vault = Fixtures.testVault("onboarding-unreadable")
        vault.removeAll()
        defer { vault.removeAll() }
        let cookies = [SavedCookie(name: "s", value: "1", domain: "a.example.com")]
        let stored = StoredAccount(url: "https://a.example.com", username: "fleet", cookies: cookies)
        try vault.save(stored)
        let service = SignInService(store: AccountStore(vault: vault))
        if case .signedIn = service.restoreStateNow() {} else { Issue.record("expected the saved sign-in") }

        vault.debugMakeUnreadable()
        #expect(service.restoreStateNow() == .unavailable(.keychainUnreadable))
        #expect(service.restoreStateNow() == .unavailable(.keychainUnreadable), "reading it again changes nothing")

        try service.store.save(StoredAccount(url: "https://b.example.com", username: "fleet", cookies: cookies))
        guard case .signedIn(let account) = service.restoreStateNow() else { Issue.record("expected the new sign-in"); return }
        #expect(account.baseURL.host == "b.example.com")
        // A fresh reader (the next launch) finds it too.
        if case .signedIn = SignInService(store: AccountStore(vault: vault)).restoreStateNow() {} else { Issue.record("next launch is not clean") }
    }

    /// DECISION D35: reading another account's version never makes or ends a client (Check Again under a locked sheet
    /// while the app underneath moved to another gateway).
    @Test func aVersionReadForAnotherAccountLeavesTheActiveClientAlone() async throws {
        let vault = Fixtures.testVault("onboarding-compat-read")
        vault.removeAll()
        defer { vault.removeAll() }
        let cookies = [SavedCookie(name: "s", value: "1", domain: "a.example.com")]
        try vault.save(StoredAccount(url: "https://a.example.com", username: "fleet", cookies: cookies))
        try vault.save(StoredAccount(url: "https://b.example.com", username: "fleet", cookies: cookies))
        let service = SignInService(store: AccountStore(vault: vault))
        _ = service.restoreStateNow()
        let accounts = service.savedAccounts
        let a = try #require(accounts.first { $0.baseURL.host == "a.example.com" })
        let b = try #require(accounts.first { $0.baseURL.host == "b.example.com" })
        #expect(await service.compatibility(for: a) == .unknown, "no client yet: nothing is made for the read")
        #expect(service.activeAccountID == nil)
        let client = service.client(for: b)
        defer { client.shutdown() }
        #expect(await service.compatibility(for: a) == .unknown)
        #expect(service.activeAccountID == b.id && !client.isShutDown, "the other gateway's live client is untouched")
        #expect(service.client(for: b) === client)
    }

    /// DECISION D13 and spec §5.16 acceptance 4: drafts typed under the sign-in that can no longer be read stay on the
    /// phone under that account's id. Signing in again to the same address and username gives the same id, so the
    /// draft is back; another username (or address) gives another id and sees none.
    @Test func draftsComeBackToTheSameAccountOnly() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-drafts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let vault = Fixtures.testVault("onboarding-unreadable-drafts")
        vault.removeAll()
        defer { vault.removeAll() }
        let cookies = [SavedCookie(name: "s", value: "1", domain: "a.example.com")]
        let service = SignInService(store: AccountStore(vault: vault))
        try service.store.save(StoredAccount(url: "https://a.example.com", username: "fleet", cookies: cookies))
        guard case .signedIn(let before) = service.restoreStateNow() else { Issue.record("expected the saved sign-in"); return }

        let old = DraftStore(accountId: before.id, base: base)
        old.save(["chat-1": StoredDraft(text: "half a thought", attachments: [], updatedAt: 1, profile: "default")])
        old.flush()

        vault.debugMakeUnreadable()
        #expect(service.restoreStateNow() == .unavailable(.keychainUnreadable))

        // Someone else signs in on this phone first: none of the old drafts are theirs.
        try service.store.save(StoredAccount(url: "https://a.example.com", username: "someone-else", cookies: cookies))
        guard case .signedIn(let other) = service.restoreStateNow() else { Issue.record("expected the other sign-in"); return }
        #expect(other.id != before.id)
        #expect(DraftStore(accountId: other.id, base: base).load(exists: { _ in true }).isEmpty, "not moved")
        try service.store.save(StoredAccount(url: "https://b.example.com", username: "fleet", cookies: cookies))
        guard case .signedIn(let elsewhere) = service.restoreStateNow() else { Issue.record("expected the third sign-in"); return }
        #expect(elsewhere.id != before.id && DraftStore(accountId: elsewhere.id, base: base).load(exists: { _ in true }).isEmpty)

        // The same address and username again: the same account, and its draft.
        try service.store.save(StoredAccount(url: "https://a.example.com", username: "fleet", cookies: cookies, label: "Renamed"))
        guard case .signedIn(let again) = service.restoreStateNow() else { Issue.record("expected the sign-in back"); return }
        #expect(again.id == before.id)
        #expect(DraftStore(accountId: again.id, base: base).load(exists: { _ in true })["chat-1"]?.text == "half a thought", "kept")
    }
    #endif
}

/// The stand-in gateway's own controls (scripts/fixtures/onboarding-gateway.py). It resets the fixture, so it never
/// runs against the two the UI suite uses (9990, 9991): it runs only when `HQN_ONBOARDING_UNIT_PORT` names a fixture
/// started for it (`TEST_RUNNER_HQN_ONBOARDING_UNIT_PORT=9994 scripts/build.sh test <SIM>`).
struct OnboardingFixtureTests {
    nonisolated static let port: UInt16? = ProcessInfo.processInfo.environment["HQN_ONBOARDING_UNIT_PORT"].flatMap { UInt16($0) }

    @Test(.enabled(if: OnboardingFixtureTests.port.map(Fixtures.portOpen) ?? false)) func itsControlsDoWhatTheSuiteNeeds() async throws {
        let port = try #require(Self.port)
        _ = try await Fixtures.control(port, "/__onboarding/reset", json: [:])
        let state = try await Fixtures.control(port, "/__onboarding/state", method: "GET")
        #expect(state["status"]?["release_date"]?.string != nil, "\(state)")
        _ = try await Fixtures.control(port, "/__onboarding/status",
                                       json: ["release_date": "2026.9.20", "version": "0.13.0", "can_update_hermes": false])
        let after = try await Fixtures.control(port, "/__onboarding/state", method: "GET")
        #expect(after["status"]?["release_date"]?.string == "2026.9.20" && after["status"]?["can_update_hermes"]?.bool == false, "\(after)")
        _ = try await Fixtures.control(port, "/__onboarding/reset", json: [:])
    }
}
