// [offline] What the app model hands the offline stream (docs/spec/3x-offline.md §3.2, §5): the launch screen's
// "something changed" signal, the reconnect notice fed from the connection's states, the "Sign in again" notice when
// the gateway ends the session while the app is on screen, and the "Message too large" notice. One per `AppModel`.

import UIKit

@MainActor final class OfflineHub {
    weak var model: AppModel?
    /// The roster or the connection changed: the launch screen asks again whether the app is worth showing.
    var onLaunchStateChange: (() -> Void)?

    /// The tabs are on screen: notices may show (never over the launch, offline or sign-in screens).
    private(set) var appShown = false
    private var machine: ReconnectBanner?
    private let banner = ConnectionBanner()
    private var state: ConnectionState = .connecting
    private var offlineTurn: Timer?

    private var endedSession: SignInService.Prefill?
    private(set) var sessionNotice = NoticeSlot()
    private(set) var tooLargeNotice = NoticeSlot()
    private weak var sessionAlert: UIAlertController?
    private weak var tooLargeAlert: UIAlertController?
    private var retryPresent: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    /// §6.10: the Capabilities page's data read ahead of its first open, once per activation, one read at a time.
    private var pageWarm: PageDataWarm?
    private var capabilitiesFlight: ReadFlight?

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.banner.relayout() }
        })
        // §6.9: Low Power Mode or heat changed: the roster and sessions polls are armed again with the new period.
        observers.append(center.addObserver(forName: PowerState.changed, object: PowerState.shared, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model?.botStore?.powerChanged()
                self?.model?.sessionStore?.powerChanged()
            }
        })
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        offlineTurn?.invalidate()
        retryPresent?.cancel()
    }

    /// The sentence the reconnect notice shows now ("" = none).
    var bannerText: String { machine?.shown ?? "" }
    /// The gateway ended this phone's session and signing in again was put off.
    var sessionEnded: Bool { endedSession != nil }

    private var window: UIWindow? { MainTabController.current?.viewIfLoaded?.window }
    private var active: Bool { UIApplication.shared.applicationState == .active }

    // MARK: Account lifecycle

    func activated(_ account: GatewayAccount, label: String?) {
        // §3.5: the offline screen can name the gateway while the Keychain cannot be read. Nothing secret.
        LastGatewayHint(url: account.baseURL.absoluteString, accountName: GatewayNaming.accountName(account), label: label,
                        username: account.kind == .password ? account.username : nil).save()
        state = .connecting
        OutageClock.shared.reset()
        endedSession = nil
        sessionNotice.reset()
        machine = ReconnectBanner(offline: { [weak self] in
            guard let self else { return false }
            return OutageClock.shared.isOffline(self.state)
        }, show: { [weak self] text in
            guard let self else { return }
            self.banner.show(text, in: self.appShown ? self.window : nil)
        }, clear: { [weak self] in
            self?.banner.clear()
        })
        startPageWarm()
        #if DEBUG
        banner.stayOverride = OfflineDebug.noticeStay
        banner.onShown = { [weak self] sentence, frame in OfflineDebug.noticeShown(sentence, frame: frame, in: self?.window) }
        banner.onGone = { OfflineDebug.noticeGone() }
        // `-HQDebugProcessClaim <stored id>:<process id>`: a running background-process claim to check (§6.6); the
        // real claims come from the composer stream's capsule (L461).
        if let claim = OfflineDebug.processClaim {
            model?.activityStore?.setProcessClaims(runtimeId: claim.stored, profile: "default", storedId: claim.stored,
                                                   [ProcessClaim(id: claim.process, running: true)])
        }
        #endif
    }

    func tornDown() {
        pageWarm?.stop(); pageWarm = nil
        capabilitiesFlight?.cancel(); capabilitiesFlight = nil
        machine?.stop()
        machine = nil
        banner.clear()
        offlineTurn?.invalidate(); offlineTurn = nil
        OutageClock.shared.reset()
        endedSession = nil
        sessionNotice.reset()
        retryPresent?.cancel(); retryPresent = nil
        if let alert = sessionAlert { alert.dismiss(animated: false) }
        state = .connecting
    }

    // MARK: Warm-ups (§6.10)

    /// The roster changed: the launch screen asks again, and the first rows start the Capabilities warm-up's 600 ms.
    func rosterChanged() {
        onLaunchStateChange?()
        if !(model?.bots.isEmpty ?? true) { pageWarm?.rosterHasRows() }
    }

    private func startPageWarm() {
        pageWarm?.stop()
        capabilitiesFlight = ReadFlight(isActive: { [weak self] in self?.active ?? false }, label: "capabilities warm") { [weak self] in
            await self?.warmCapabilities()
        }
        let warm = PageDataWarm(ready: { [weak self] in
            guard let self, let model = self.model else { return false }
            return model.connection == .ready && self.active
        }, moving: {
            (MainTabController.current?.selectedViewController as? UINavigationController)?.transitionCoordinator != nil
        }, warm: { [weak self] in
            await self?.capabilitiesFlight?.request(background: true)
        })
        pageWarm = warm
        warm.activated()
        if !(model?.bots.isEmpty ?? true) { warm.rosterHasRows() }
    }

    /// What the Capabilities page reads first when it opens (`CapabilitiesModel.reloadSkills`), through the same store
    /// functions, kept for its first frame.
    private func warmCapabilities() async {
        guard let model, let account = model.account, let service = model.capabilities else { return }
        let profile = model.focusedProfile ?? "default"
        // [load-cache] An answer under 30 minutes old (often the last launch's, from disk) is what this would read.
        await CapabilitiesWarmCache.shared.preload(account: account.id, profile: profile)
        if CapabilitiesWarmCache.shared.entry(account: account.id, profile: profile) != nil {
            AppLog.trace("warm", "capabilities for \(profile): kept answer is fresh, not read")
            return
        }
        let officialRead = Task { try? await service.officialSkills(profile) }   // [perf] both reads at once
        guard let skills = try? await service.skills(profile) else { officialRead.cancel(); return }
        let official = await officialRead.value
        guard model.account?.id == account.id else { return }
        CapabilitiesWarmCache.shared.store(skills: skills, official: official, account: account.id, profile: profile)
        AppLog.note("warm", "capabilities for \(profile): \(skills.count) skills")
    }

    /// The last saved gateway was signed out of: nothing is left for the offline screen to name.
    func signedOutOfLast() { LastGatewayHint.clear() }

    func setAppShown(_ shown: Bool) {
        guard shown != appShown else { return }
        appShown = shown
        if shown {
            if let text = machine?.shown, !text.isEmpty { banner.show(text, in: window) }
            resumeNotices()
        } else {
            banner.suspend()
        }
    }

    // MARK: Connection (§5.1)

    func connectionChanged(_ next: ConnectionState, failure: GatewayFailure?) {
        let before = state
        state = next
        if OutageClock.shared.note(next) { armOfflineTurn() }
        if case .reconnecting = next {} else { offlineTurn?.invalidate(); offlineTurn = nil }
        if let machine {
            if case .offline(let reason) = before, reason == GatewayFailure.offline.code, next != before {
                machine.network(reachable: true)
            }
            switch next {
            case .ready:
                pageWarm?.conditionsChanged()                 // §6.10: a warm-up held while not connected runs now
                machine.open()
            case .reconnecting(let attempt):
                // The first `.reconnecting` is the open socket dropping; from the second on, a reconnect has failed.
                machine.socketError(attempt: attempt >= 2 ? 1 : 0)
                if attempt >= 2 { machine.failure(reason: failure?.code) }
            case .offline(let reason):
                if reason == GatewayFailure.offline.code {
                    machine.network(reachable: false)
                } else if reason == GatewayFailure.paused.code {
                    machine.failure(reason: reason)
                } else {
                    machine.socketError(attempt: 1)
                    machine.failure(reason: reason)
                }
            case .signedOut:
                AppLog.note("offline", "connection banner stopped: signed out")
                machine.stop()
            case .connecting:
                break
            }
            machine.refresh()
        }
        onLaunchStateChange?()
    }

    /// Reconnecting for 120 s turns the header to "Offline": the headers and the notice read it again then.
    private func armOfflineTurn() {
        offlineTurn?.invalidate()
        let timer = Timer(timeInterval: HeaderLink.offlineAfter + 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.offlineTurn = nil
                AppLog.note("offline", "header turned to Offline after \(Int(HeaderLink.offlineAfter))s reconnecting")
                self.machine?.refresh()
                self.model?.onConnectionChange?()
                self.model?.settingsHub.notify()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        offlineTurn = timer
    }

    /// [connect-fast] The app is coming forward: the socket is about to dial back, so a "paused" reason goes now.
    func willEnterForeground() { machine?.foreground() }

    func becameActive() {
        pageWarm?.conditionsChanged()
        machine?.foreground()
        // §5.2: a session ended and put off ("Not Now") is said again each time the app is opened.
        if endedSession != nil, appShown, !sessionNotice.pending, !sessionNotice.showing {
            if sessionNotice.request(canShow: canPresent) { presentSessionAlert() }
        }
        resumeNotices()
    }

    // MARK: Sign in again (§5.2)

    /// The gateway ended the session. True = the app is on screen, so the user is told first (drafts kept) and decides
    /// when to sign in again; false = the launch or offline screen is up and the prefilled form shows directly.
    func holdSessionEnd(_ prefill: SignInService.Prefill) -> Bool {
        guard appShown else { return false }
        endedSession = prefill
        if sessionNotice.request(canShow: canPresent) {
            AppLog.note("offline", "session ended: sign-in-again notice shown")
            presentSessionAlert()
        } else {
            AppLog.note("offline", "session ended: sign-in-again notice deferred")
            retryLater()
        }
        return true
    }

    /// The user acted on a signed-out app (Try Again on the Bots list): say again why nothing loads.
    func remindSessionEnded() {
        guard endedSession != nil, appShown else { return }
        if sessionNotice.request(canShow: canPresent) { presentSessionAlert() } else { retryLater() }
    }

    /// The Gateway page's "Sign In Again" after Not Now (UX study #121): what the notice's "Sign in again" does.
    func signInAgain() {
        guard let prefill = endedSession else { return }
        AppLog.note("offline", "signing in again after a session end")
        sessionNotice.dismissed()
        endedSession = nil
        model?.endSession(prefill)
    }

    private var host: UIViewController? { FailureAlert.topmost(MainTabController.current) }
    private var canPresent: Bool {
        guard appShown, active, let host else { return false }
        return !(host is UIAlertController) && !host.isBeingPresented && !host.isBeingDismissed
    }

    private func presentSessionAlert() {
        guard let prefill = endedSession, let host else { sessionNotice.dismissed(again: true); return }
        let name = model?.settingsHub.accounts.first(where: \.isCurrent)?.title
        let alert = UIAlertController(title: OfflineNotices.signInAgainTitle, message: OfflineNotices.signInAgainMessage(gateway: name),
                                      preferredStyle: .alert)
        let signIn = UIAlertAction(title: OfflineNotices.signInAgainAction, style: .default) { [weak self] _ in
            guard let self else { return }
            self.sessionNotice.dismissed()
            self.endedSession = nil
            self.model?.endSession(prefill)
        }
        alert.addAction(UIAlertAction(title: OfflineNotices.notNow, style: .cancel) { [weak self] _ in
            // Put off: the app stays on its saved screens; the notice returns when the app is next opened.
            self?.sessionNotice.dismissed()
            self?.resumeNotices()
        })
        alert.addAction(signIn)
        alert.preferredAction = signIn
        alert.view.accessibilityIdentifier = "offline.sign-in-again"
        host.present(alert, animated: true)
        sessionAlert = alert
    }

    // MARK: Message too large (§5.3)

    func messageTooLarge() {
        if tooLargeNotice.request(canShow: canPresent) {
            AppLog.note("offline", "message too large: notice shown")
            presentTooLarge()
        } else if !tooLargeNotice.showing {
            AppLog.note("offline", "message too large: notice deferred")
            retryLater()
        }
    }

    private func presentTooLarge() {
        guard let host else { tooLargeNotice.dismissed(again: true); return }
        let alert = UIAlertController(title: OfflineNotices.tooLargeTitle, message: OfflineNotices.tooLargeMessage, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: OfflineNotices.ok, style: .default) { [weak self] _ in
            self?.tooLargeNotice.dismissed()
            self?.resumeNotices()                 // a notice that waited behind this one shows now
        })
        alert.view.accessibilityIdentifier = "offline.too-large"
        host.present(alert, animated: true)
        tooLargeAlert = alert
    }

    // MARK: Held notices

    /// Shows what waited, if it can be shown now; what still cannot be is looked at again until it can (stress round
    /// 1: a session that ended under another alert left up for half a minute was never said).
    private func resumeNotices() {
        guard appShown else { return }
        if endedSession != nil, sessionNotice.resume(canShow: canPresent) { presentSessionAlert() }
        if tooLargeNotice.resume(canShow: canPresent) { presentTooLarge() }
        if owed { retryLater() }
    }

    /// A notice is owed and not on show.
    private var owed: Bool { (endedSession != nil && sessionNotice.pending) || tooLargeNotice.pending }

    /// Something else is on top (another alert, a sheet mid-flight, the app not active): look again shortly, for as
    /// long as a notice is owed and the app is on screen. It never gives up: an alert the user leaves up for minutes
    /// must not swallow the notice behind it. The look is a few comparisons, every 0.7 s at first, then every 2 s.
    private func retryLater() {
        guard retryPresent == nil else { return }
        retryPresent = Task { [weak self] in
            var looks = 0
            while true {
                try? await Task.sleep(for: .milliseconds(looks < 20 ? 700 : 2000))
                looks += 1
                guard let self, !Task.isCancelled else { return }
                guard self.appShown, self.owed else { break }
                if self.endedSession != nil, self.sessionNotice.resume(canShow: self.canPresent) { self.presentSessionAlert() }
                if self.tooLargeNotice.resume(canShow: self.canPresent) { self.presentTooLarge() }
            }
            self?.retryPresent = nil
        }
    }
}
