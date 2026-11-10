// [offline] What the window shows from launch until the app is worth showing (docs/spec/3x-offline.md §3): the launch
// screen while the saved sign-in is read and, with nothing saved to show, until the gateway is open and a first list
// has content (§3.1, §3.2); the offline screen when the saved sign-in cannot be opened, or nothing is saved and the
// gateway cannot be reached (§3.5–§3.7); the storage check and the "couldn't start" route (§3.4). The scene delegate
// keeps building the app and the sign-in form; this decides when.

import UIKit

@MainActor protocol LaunchHost: AnyObject {
    var window: UIWindow? { get }
    /// Builds the tabs for the (already active) account and puts them on screen.
    func showApp(_ account: GatewayAccount)
    func showSignIn(prefill: SignInService.Prefill?)
    /// Reads the saved sign-in again and routes from the start.
    func restore()
    /// `fade` nil = no animation.
    func setRoot(_ controller: UIViewController, fade: TimeInterval?)
}

@MainActor final class LaunchCoordinator {
    enum Stage: Equatable { case booting, waiting, offline, signIn, app }

    private let model: AppModel
    private weak var host: (any LaunchHost)?
    private(set) var stage: Stage = .booting
    private(set) var phase: StartupPhase = .booting

    private var gate: LaunchGate?
    private weak var launchScreen: LaunchViewController?
    private weak var offlineScreen: OfflineViewController?
    private var screenModel: OfflineScreenModel?
    /// The active account the launch or offline screen waits on (nil while the saved sign-in cannot be opened).
    private var account: GatewayAccount?
    private var generation = 0
    private var onShown: (() -> Void)?

    // The saved sign-in cannot be opened (§3.5 case A): this screen owns the retry ladder.
    private var keychainFailure: GatewayFailure?
    private var keychainAttempt = 0
    private var keychainTimer: Timer?
    private var keychainReading = false
    private var lastForcedRead = Date.distantPast

    private var retryWatch: Task<Void, Never>?
    private var statusRefresh: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    #if DEBUG
    private var heldOnce = false
    #endif

    /// The launch hand-over: 120 ms, 100 ms with Reduce Motion (§3.1).
    static var fade: TimeInterval { HQMotion.reduced ? 0.1 : LaunchGate.Timing.standard.leave }

    init(model: AppModel, host: any LaunchHost) {
        self.model = model
        self.host = host
        model.offlineHub.onLaunchStateChange = { [weak self] in self?.stateChanged() }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            // "Hermes HQ reconnects as soon as it is": the phone was unlocked.
            MainActor.assumeIsolated { self?.readSavedSignInAgain(forced: true) }
        })
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        keychainTimer?.invalidate()
        retryWatch?.cancel()
        statusRefresh?.cancel()
    }

    // MARK: Launch screen

    /// A launch screen with a fresh gate (its timers start now).
    func makeLaunchScreen() -> LaunchViewController {
        let screen = LaunchViewController()
        screen.onTryAgain = { [weak self] in self?.launchTryAgain() }
        screen.onDifferentGateway = { [weak self] in self?.differentGateway() }
        screen.offersDifferentGateway = knownGateway != nil
        launchScreen = screen
        gate = LaunchGate(blocker: { [weak self] in
            // Not `?? .cover`: nil is an answer here (content is on show).
            guard let self else { return .cover }
            return self.model.launchBlocker
        }, throughTailscale: { [weak self] in
            guard let url = self?.knownGateway.flatMap({ URL(string: $0.url) }) else { return false }
            return GatewayAddress.throughTailscale(url)
        }, nousHosted: { [weak self] in
            OfflineCopy.nousHosted(self?.knownGateway.flatMap { URL(string: $0.url) })
        }, render: { [weak self, weak screen] view in self?.rendered(view, on: screen) })
        return screen
    }

    private func rendered(_ view: LaunchGate.View, on screen: LaunchViewController?) {
        screen?.render(view)
        // An older gate winding down says nothing about the screen on show.
        guard let screen, screen === launchScreen else { return }
        if view.phase == .leaving, stage == .waiting, let account { handOver(account) }
    }

    private var launchScreenIsUp: Bool {
        guard let screen = launchScreen, let gate else { return false }
        return host?.window?.rootViewController === screen && gate.phase == .shown
    }

    private func ensureLaunchScreen(fade: TimeInterval) {
        guard !launchScreenIsUp else { return }
        host?.setRoot(makeLaunchScreen(), fade: fade)
    }

    /// The launch screen covers while the saved sign-in is read (launch, sign-out, Try Again).
    func cover() {
        generation += 1
        stopOffline()
        stage = .booting
        phase = .booting
        account = nil
        model.offlineHub.setAppShown(false)
        ensureLaunchScreen(fade: 0.3)
    }

    /// The saved sign-in, read off the main thread.
    func restoreState() async -> SignInService.RestoreState {
        #if DEBUG
        let hold = OfflineDebug.launchHold
        if hold > 0, !heldOnce {
            heldOnce = true
            try? await Task.sleep(for: .seconds(hold))
        }
        if let failure = OfflineDebug.restoreFailure() { return .unavailable(failure) }
        #endif
        return await model.signIn.restoreState()
    }

    private func launchTryAgain() {
        if stage == .waiting, let client = model.client, gate?.hasFailed == false {
            // Still connecting: the dial in flight is dropped and made again; the 12 s start over.
            client.reconnectNow()
            gate?.retry()
        } else {
            gate?.retry()
            host?.restore()
        }
    }

    // MARK: Signed in

    /// An account with a saved session (launch restore, a typed sign-in, a sign-in from the offline screen). The app
    /// shows at once when something saved is on show; otherwise the launch screen waits for a first list.
    /// `adopting`: the app model holds another gateway's stores (a sign-in to a different gateway).
    func signedIn(_ account: GatewayAccount, typed: Bool = false, adopting: Bool = false, then shown: (() -> Void)? = nil) {
        generation += 1
        let run = generation
        stopOffline()
        if typed { phase = .signingIn }
        onShown = shown
        Task { [weak self] in
            // §3.4: this phone's saved app data must open for the account before the stores are made.
            let failure = await Self.storageFailure(account)
            guard let self, run == self.generation else { return }
            if let failure { return self.startupFailed(failure) }
            if adopting, self.model.account != nil, self.model.account?.id != account.id {
                self.model.adoptSignedInAccount(account)
            } else {
                self.model.activate(account)
                if typed { self.model.settingsHub.accountsChanged() }
            }
            self.account = account
            // §3.2 DECISION: content at the first frame skips the wait entirely.
            if self.model.launchBlocker == nil { return self.handOver(account) }
            self.stage = .waiting
            AppLog.note("launch", "waiting for a first list (\(self.model.launchBlocker == .loading ? "loading" : "not connected"))")
            self.ensureLaunchScreen(fade: typed ? 0.3 : Self.fade)
            self.gate?.mount()
            self.stateChanged()
        }
    }

    private static func storageFailure(_ account: GatewayAccount) async -> AccountStorageError? {
        do throws(AccountStorageError) {
            try await AccountStorage.checkOffMain(account)
            return nil
        } catch {
            return error
        }
    }

    /// §3.4: an unexpected error ends startup only while starting or signing in; later it is only logged.
    func startupFailed(_ error: any Error) {
        guard StartupProblems.isFatal(phase: phase, error: error) else {
            AppLog.note("stray", "\(type(of: error)) after start: not shown")
            return
        }
        AppLog.note("launch", "startup stopped: \(type(of: error))")
        stage = .booting
        ensureLaunchScreen(fade: 0.3)
        launchScreen?.offersDifferentGateway = knownGateway != nil
        gate?.fail(StartupProblems.message(for: error))
    }

    private func handOver(_ account: GatewayAccount) {
        stage = .app
        phase = .mounted
        Signposts.end(.launch, "Launch", outcome: "tabs")
        StartupTimings.shared.markOnce("launch.ready")   // [diagnostics] §2.3 "App ready": the launch screen let go
        stopOffline()
        gate?.hide()
        AppLog.note("launch", "app shown")
        host?.showApp(account)
        model.offlineHub.setAppShown(true)
        let shown = onShown
        onShown = nil
        shown?()
    }

    /// The sign-in form owns the window (no saved sign-in, or the gateway ended the session before the app showed).
    func signInShown() {
        generation += 1
        stopOffline()
        stage = .signIn
        phase = .signingIn
        Signposts.end(.launch, "Launch", outcome: "sign-in")
        StartupTimings.shared.markOnce("launch.ready")   // [diagnostics] §2.3 "App ready": the launch screen let go
        account = nil
        gate?.hide()
        model.offlineHub.setAppShown(false)
    }

    // MARK: Changes while waiting

    private func stateChanged() {
        switch stage {
        case .waiting:
            // §3.2 step 4: nothing saved to show and the gateway can't be reached → the offline screen.
            if model.launchBlocker == .cover, case .offline(let reason) = model.connection, reason != GatewayFailure.paused.code {
                showOffline()
            } else {
                gate?.check()
            }
        case .offline:
            guard let account else { return }
            if model.connection == .ready {
                // §3.7: a connection that opens while the form is up dismisses the form and shows the app.
                if let sheet = host?.window?.rootViewController?.presentedViewController, !sheet.isModalInPresentation {
                    sheet.dismiss(animated: false)
                }
                if model.launchBlocker == nil { handOver(account) } else { enterWaiting() }
            } else {
                refreshOffline()
            }
        case .booting, .signIn, .app:
            break
        }
    }

    /// Connected from the offline screen with a first list still out: the launch screen covers the load (§3.2).
    private func enterWaiting() {
        stopOffline()
        stage = .waiting
        phase = .booting
        host?.setRoot(makeLaunchScreen(), fade: Self.fade)
        gate?.mount()
    }

    // MARK: Offline screen

    /// The saved sign-in cannot be opened (§3.5 case A).
    func unavailable(_ failure: GatewayFailure) {
        generation += 1
        account = nil
        keychainFailure = failure
        if stage == .offline, offlineScreen != nil, let screenModel {
            fill(screenModel)
        } else {
            keychainAttempt = 0
            screenModel?.keychainReads = 0
            // The scene becoming active as the app starts is not a return: the first read just failed.
            lastForcedRead = Date()
            showOffline()
        }
        scheduleKeychainRetry()
    }

    private func showOffline() {
        stage = .offline
        phase = .offline
        Signposts.end(.launch, "Launch", outcome: "offline")
        StartupTimings.shared.markOnce("launch.ready")   // [diagnostics] §2.3 "App ready": the launch screen let go
        gate?.hide()
        model.offlineHub.setAppShown(false)
        let screen = OfflineScreenModel()
        screenModel = screen
        fill(screen)
        let controller = OfflineViewController(screen: screen)
        controller.onTryAgain = { [weak self] in self?.offlineTryAgain() }
        controller.onDifferentGateway = { [weak self] in self?.differentGateway() }
        controller.onSignInAgain = { [weak self] in self?.differentGateway() }
        controller.onSwitch = { [weak self] id in self?.switchGateway(id) }
        offlineScreen = controller
        host?.setRoot(controller, fade: Self.fade)
        watchRetries()
        AppLog.note("launch", "offline screen: \(screen.reason ?? "-")")
    }

    /// The gateway to name, and to start "Change Address or Sign In" from: the active account, else the last one
    /// the app opened (kept where it can be read while the Keychain cannot).
    private var knownGateway: LastGatewayHint? {
        if let account = model.account ?? account {
            return LastGatewayHint(url: account.baseURL.absoluteString, accountName: GatewayNaming.accountName(account),
                                   label: model.signIn.store.stored(account)?.label,
                                   username: account.kind == .password ? account.username : nil)
        }
        return LastGatewayHint.load()
    }

    private func fill(_ screen: OfflineScreenModel) {
        let gateway = knownGateway
        screen.url = gateway.flatMap { URL(string: $0.url) }
        screen.label = gateway?.label
        screen.accountName = gateway?.accountName
        // UX study #125: the other saved gateways, only once the saved sign-in was read (an unreadable one is never
        // left behind without the Sign In Again confirmation).
        if let current = account {
            screen.otherGateways = model.settingsHub.accounts.filter { !$0.isCurrent && $0.id != current.id }
                .map { OfflineScreenModel.OtherGateway(id: $0.id, title: $0.title) }
        } else {
            screen.otherGateways = []
        }
        var reason: String?
        if account != nil {
            if case .offline(let why) = model.connection { reason = why } else { reason = screen.reason }
        } else {
            reason = keychainFailure?.code
        }
        #if DEBUG
        if let forced = OfflineDebug.offlineReason { reason = forced }
        #endif
        screen.reason = reason
    }

    private func refreshOffline() {
        guard stage == .offline, let screenModel else { return }
        fill(screenModel)
        refreshStatusSoon()
    }

    /// The connection's states and its retry clock arrive on two streams: read both once they have settled, so the
    /// line never flickers to "Connecting…" between a failed dial and its countdown.
    private func refreshStatusSoon(after delay: Duration = .milliseconds(60)) {
        statusRefresh?.cancel()
        statusRefresh = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.refreshStatus()
        }
    }

    private func refreshStatus() {
        guard stage == .offline, let screenModel else { return }
        guard account != nil, let client = model.client else { return }   // case A sets its own
        let due = client.nextRetry
        var dialing = false
        if due == nil {
            switch client.state {
            case .connecting, .reconnecting: dialing = true
            case .offline(let reason): dialing = reason != GatewayFailure.offline.code && reason != GatewayFailure.paused.code
            case .ready: dialing = true          // open: the first list is on its way
            case .signedOut: dialing = false
            }
        }
        screenModel.setStatus(due: due, connecting: dialing)
    }

    /// §3.6: the countdown is the connection's own retry timer.
    private func watchRetries() {
        retryWatch?.cancel()
        guard account != nil, let client = model.client else { return }
        let changes = client.retryChanges()
        retryWatch = Task { [weak self] in
            for await _ in changes {
                guard let self, !Task.isCancelled else { return }
                self.refreshStatusSoon()
            }
        }
    }

    private func stopOffline() {
        keychainTimer?.invalidate(); keychainTimer = nil
        keychainReading = false
        retryWatch?.cancel(); retryWatch = nil
        statusRefresh?.cancel(); statusRefresh = nil
        screenModel = nil
    }

    private func offlineTryAgain() {
        guard stage == .offline, let screenModel, screenModel.tryAgainEnabled else { return }
        screenModel.problem = nil
        screenModel.focusStatus()
        if account != nil, let client = model.client {
            // One dial of the saved session now; the ladder keeps its place.
            screenModel.setStatus(due: nil, connecting: true)
            client.reconnectNow()
            refreshStatusSoon(after: .milliseconds(1500))
        } else {
            readSavedSignInAgain(forced: false)
        }
    }

    // MARK: Case A: the Keychain

    private func scheduleKeychainRetry() {
        keychainTimer?.invalidate()
        let wait = RetryLadder.wait(attempt: keychainAttempt)
        keychainAttempt += 1
        screenModel?.keychainReads = keychainAttempt
        let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.readSavedSignInAgain(forced: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        keychainTimer = timer
        screenModel?.setStatus(due: Date().addingTimeInterval(wait), connecting: false)
    }

    /// One more Keychain read (no network). `forced`: a return to the app or the phone unlocking, at most one a second.
    private func readSavedSignInAgain(forced: Bool) {
        guard stage == .offline, account == nil, !keychainReading else { return }
        if forced {
            guard Date().timeIntervalSince(lastForcedRead) >= 1 else { return }
            lastForcedRead = Date()
        }
        keychainTimer?.invalidate(); keychainTimer = nil
        keychainReading = true
        screenModel?.setStatus(due: nil, connecting: true)
        let run = generation
        Task { [weak self] in
            guard let self else { return }
            let began = ContinuousClock.now
            let state = await self.restoreState()
            // "Connecting…" stays long enough to be read.
            let shown = began.duration(to: .now)
            if shown < .milliseconds(600) { try? await Task.sleep(for: .milliseconds(600) - shown) }
            guard run == self.generation, self.stage == .offline else { return }
            self.keychainReading = false
            AppLog.note("launch", "restore again: \(state.logLabel)")
            switch state {
            case .signedIn(let account): self.signedIn(account)
            case .signedOut(let prefill): self.host?.showSignIn(prefill: prefill)
            case .unavailable(let failure): self.unavailable(failure)
            }
        }
    }

    /// Back in the app (a real return): the offline screen retries at once (§3.7). With an account the connection's
    /// own return does it.
    func appBecameActive() {
        if stage == .offline, account == nil { readSavedSignInAgain(forced: true) }
        if stage == .offline, account != nil { refreshStatusSoon(after: .milliseconds(300)) }
    }

    // MARK: A different gateway (§3.7)

    private func differentGateway() {
        let gateway = knownGateway
        signInSheet(address: gateway?.url ?? "", username: gateway?.username ?? "")
    }

    /// UX study #125: another saved gateway from the offline screen, as the title menu switches. Its saved session is
    /// made current and the launch takes over from there (the app, or the launch screen while a first list loads); a
    /// gateway whose session ended opens the sign-in sheet prefilled with it.
    private func switchGateway(_ id: String) {
        guard stage == .offline, let current = account, id != current.id,
              let other = model.signIn.store.accounts.first(where: { $0.id == id }) else { return }
        guard model.settingsHub.switcher.hasUsableSession(other) else {
            return signInSheet(address: other.baseURL.absoluteString, username: other.kind == .password ? (other.username ?? "") : "")
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                // [offline] §3.4, as Settings switches: this phone's saved app data must open first, or nothing changes
                // (review: the saved current gateway moved before the check, so a failed switch relaunched on it).
                try await AccountStorage.checkOffMain(other, switching: true)
                guard self.stage == .offline else { return }
                guard try self.model.signIn.switchTo(other) else { throw GatewayFailure.accountMissing }
            } catch {
                AppLog.note("launch", "offline switch failed: \(type(of: error))")
                let title = self.model.settingsHub.accounts.first(where: { $0.id == id })?.title ?? GatewayNaming.unnamed
                FailureAlert.present(error, fallbackTitle: "Couldn’t Switch to \(title)", from: self.host?.window?.rootViewController)
                return
            }
            AppLog.note("launch", "offline screen: switched gateway")
            self.signedIn(other, adopting: true)
        }
    }

    /// Audit 06-13: the prefilled sign-in form (a gateway ended this phone's session) switches to another saved gateway
    /// that still has its session, as the offline screen's "Switch to <name>" does. Never a sign-in.
    func switchFromSignIn(_ id: String) {
        guard stage == .signIn, let other = model.signIn.store.accounts.first(where: { $0.id == id }),
              model.settingsHub.switcher.hasUsableSession(other) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await AccountStorage.checkOffMain(other, switching: true)
                guard self.stage == .signIn else { return }
                guard try self.model.signIn.switchTo(other) else { throw GatewayFailure.accountMissing }
            } catch {
                AppLog.note("launch", "sign-in form switch failed: \(type(of: error))")
                let title = self.model.settingsHub.accounts.first(where: { $0.id == id })?.title ?? GatewayNaming.unnamed
                FailureAlert.present(error, fallbackTitle: "Couldn’t Switch to \(title)", from: self.host?.window?.rootViewController)
                return
            }
            AppLog.note("launch", "sign-in form: switched gateway")
            self.signedIn(other, adopting: true)
        }
    }

    private func signInSheet(address: String, username: String) {
        guard let root = host?.window?.rootViewController else { return }
        // [onboarding] One version check, inside the sheet, before the app (docs/spec/3x-onboarding.md D28, I1).
        DifferentGatewayFlow.present(from: root, model: model, address: address, username: username, onSaved: {
            [weak self] in
            // The sign-in is saved; the form now reads the version and may lock the sheet on "Update Hermes": this
            // screen stops reading and retrying under it from here (D34), so the sheet alone decides what shows next.
            guard let self, self.stage == .offline else { return }
            self.signInShown()
        }) { [weak self] account in
            guard let self else { return }
            // A retry underneath may have found the new sign-in while the sheet was still closing: once is enough.
            if self.stage == .app, self.account?.id == account.id { return }
            self.signedIn(account, typed: true, adopting: true)
        }
    }
}
