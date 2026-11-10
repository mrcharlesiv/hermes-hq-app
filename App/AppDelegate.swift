import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    // [screen] The iPhone app is portrait; only a bot's Screen rotates (docs/spec/3x-screen.md §5.7, DECISION D8).
    // [m9/ipad] An iPad turns every way, as Split View and Stage Manager need (docs/spec/3x-ipad.md D13).
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad { return .all }
        // [duo] An iPhone Duo's open screen turns every way, as an iPad does: sideways is its two panes. Folded, a phone.
        if AppRoot.foldable, let screen = window?.windowScene?.screen,
           PaneLayout.unfolded(screen: screen.bounds.size) { return .all }
        #if DEBUG
        if DuoDebugHooks.turning { return .all }       // [duo] -HQDebugDuoTurn
        #endif
        return ScreenViewerController.current != nil ? .allButUpsideDown : .portrait
    }

    #if targetEnvironment(macCatalyst)
    /// [mac-layout] The Mac's Settings window has a scene of its own (`MacSettingsWindow`), and [mac-files] so has each
    /// file window (`MacFileWindow`); every other is the app's.
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        MacSettingsWindow.configuration(for: connectingSceneSession, options: options)
            ?? MacFileWindow.configuration(for: connectingSceneSession, options: options)
            ?? UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
    }
    #endif

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Signposts.begin(.launch, "Launch")             // [diagnostics] §10: ends where the launch screen lets go
        DeviceWord.name = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"   // [m9/ipad] before any wording is read
        #if targetEnvironment(macCatalyst)
        DeviceWord.name = "Mac"                           // [mac] the iPad idiom, but not an iPad
        GatewayNaming.thisComputer = MacComputerName.current   // [mac-audit] #22: a 127.0.0.1 gateway is this Mac
        #endif
        CrashCapture.install()                         // Documents/Logs: the app log and crash records (DiagnosticLog.swift)
        #if targetEnvironment(macCatalyst)
        MacUpdater.start()                                // [mac] the website's download updates itself (logged: after the log)
        MacTrail.install()                                // [mac] sleep and wake in the log
        Task.detached(priority: .utility) {                // [mac] Mac polish #34: the voices read before a reply needs them
            try? await Task.sleep(for: .seconds(8))
            _ = await PhoneVoiceList.load()
        }
        MacSettingsWindow.forgetRestored(application)     // [mac-layout] Settings' own window isn't reopened at launch
        MacFileWindow.forgetRestored(application)         // [mac-files] nor are file windows
        #endif
        LaunchChatMemory.shared.launch()               // [restore] a chat on screen when the last run ended is not reopened
        // [notifications] Before launch finishes, or a tap (or Approve/Deny) that cold-launched the app is dropped.
        NotificationHub.shared.install()
        HQAccessibility.start()                        // [a11y] one source for the accessibility settings
        TalkActivity.shared.launched()                 // [talk-background] Lock Screen buttons; a killed run's activity goes
        LogUploader.shared.collectCrashRecords()       // …sent to the owner's computer once a gateway is there (LogUploader.swift)
        MemoryTrim.install()                           // [diagnostics] one path for giving memory back (warning, background)
        HangWatch.install()                            // [diagnostics] the performance log's stall source
        PowerLog.start()                               // [diagnostics] one `power` log event per real change
        FrameMeter.install()                           // [diagnostics] `frames` records: hitches while things move
        DesktopBars.hookBars()                         // 2026-10-30: a count's Back is fitted in the iOS look too
        DesktopBack.install()
        SkinListCards.install()                        // 2026-11-02: list rows take a coloured skin's card
        AppIcons.dropStaleLaunchPicture()              // 2026-11-02: no old Hermes head on the system launch screen
        #if DEBUG
        DiagnosticsDebug.applyAtLaunch()
        #endif
        #if DEBUG
        // Crash-capture check: `-HQCrashTest` raises an Objective-C exception inside background Swift async code, the
        // way build 3's crash died; 1 s in, or `-HQCrashTestDelay <s>` ([restore]: once a reopened chat is on screen).
        if ProcessInfo.processInfo.arguments.contains("-HQCrashTest") {
            let delay = max(1, UserDefaults.standard.double(forKey: "HQCrashTestDelay"))
            Task.detached { try? await Task.sleep(for: .seconds(delay)); NSException(name: .rangeException, reason: "HQCrashTest", userInfo: nil).raise() }
        }
        // [diagnostics] `-HQCrashTestSwift`: a Swift fatal error (a signal whose record should carry "Fatal error: …"),
        // and `-HQHangTest`: the main thread busy for 1.5 s (a `main.hang` that should carry its stack), both after the delay.
        if ProcessInfo.processInfo.arguments.contains("-HQCrashTestSwift") {
            let delay = max(1, UserDefaults.standard.double(forKey: "HQCrashTestDelay"))
            Task.detached { try? await Task.sleep(for: .seconds(delay)); preconditionFailure("HQCrashTestSwift") }
        }
        if ProcessInfo.processInfo.arguments.contains("-HQHangTest") {
            let delay = max(1, UserDefaults.standard.double(forKey: "HQCrashTestDelay"))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { DiagnosticsDebug.busyMainThread(for: 1.5) }
        }
        #endif
        // Launch timing (`-HQLaunchTime`): the wall clock when app code first runs, to measure the time before it.
        if ProcessInfo.processInfo.arguments.contains("-HQLaunchTime") {
            print(String(format: "[Launch] didFinishLaunching %.3f", Date().timeIntervalSince1970))
            // [intents] A5: the time before app code runs, from the kernel's own start time for this process.
            if let ms = LaunchClock.millisecondsSinceProcessStart() { print(String(format: "[Launch] preMain %.1f ms", ms)) }
        }
        // [diagnostics] §2.3 "App launch": the process's start to the end of this method.
        StartupTimings.shared.record("native.loaded", from: StartupTimings.shared.processStart)
        return true
    }

    /// [diagnostics] Quitting (⌘Q on the Mac; an iPhone app is rarely told): the last line, on disk before the process
    /// ends. What waits to be sent goes with the next launch.
    func applicationWillTerminate(_ application: UIApplication) {
        AppLog.note("app", "quit")
        DiagnosticLog.shared.flush()
    }

    // MARK: [notifications] APNs

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRegistrar.shared.received(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushRegistrar.shared.failed()
    }

    /// The plugin's silent update when an approval was answered elsewhere (sealed, as its alerts are), or a Device
    /// Access wake-up (kind "device").
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let opened = PushSeal.opened(userInfo, keys: PushSealKeys.all())
        // [device-access] A bot asked this phone for something it shares: answer within the background time.
        if let remote = opened["dispatch"] as? [String: Any], remote["kind"] as? String == "device" {
            let done = UnsafeTransfer(completionHandler)
            Task { @MainActor in
                await DeviceAccessCenter.shared.woke()
                done.value(.newData)
            }
            return
        }
        guard let remote = opened["dispatch"] as? [String: Any], remote["settled"] as? Bool == true,
              let request = remote["request"] as? String else { return completionHandler(.noData) }
        // Completed only once the saved answer is dropped (iOS may suspend a background launch right after), on main.
        let done = UnsafeTransfer(completionHandler)
        Task { @MainActor in
            await NotificationHub.shared.settle(request: request)
            done.value(.newData)
        }
    }
}

/// Launch → restore the saved sign-in (off the main thread) → the Bots/Sessions tabs painted from cache, or the sign-in
/// form. Sign-out and an ended session come back here.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate, LaunchHost {
    var window: UIWindow?
    private var model: AppModel?
    /// [offline] The launch and offline screens, and when the app is worth showing (App/Offline/LaunchCoordinator.swift).
    private var launch: LaunchCoordinator?
    /// [offline] §6.8: a moment inside the app (Control Center, a permission alert) is not a return.
    private var returnGate = ReturnGate()
    private var driver: SignInServiceDriver?
    /// [onboarding] The welcome, guide and sign-in form while they are the root (App/Onboarding/OnboardingFlow.swift).
    private var onboarding: OnboardingFlow?
    /// [onboarding] "Update Hermes on Your Gateway" is the root: the sign-in is saved, the app not yet shown.
    private var updateShowing = false
    private var restoreGeneration = 0
    private var lastWindowSize: CGSize?   // [diagnostics] the window.resize trail mark
    #if DEBUG
    private var triedEnvironmentSignIn = false
    #endif

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        #if DEBUG
        let window: UIWindow = KeyLogWindow(windowScene: windowScene)   // [m9/ipad] notes Command presses, never text
        #else
        let window: UIWindow = MeteredWindow(windowScene: windowScene)   // [diagnostics] scrolls and sheets for FrameMeter
        #endif
        // [m9/ipad] A resizable iPad window never gets smaller than the phone layout's floor.
        if UIDevice.current.userInterfaceIdiom == .pad { windowScene.sizeRestrictions?.minimumSize = CGSize(width: 320, height: 480) }
        // [duo] Before any root is made: an iPhone that unfolds takes the two-pane root (AppRoot.make).
        if UIDevice.current.userInterfaceIdiom == .phone {
            AppRoot.foldable = PaneLayout.foldable(model: AppRoot.deviceModel, screen: windowScene.screen.bounds.size,
                                                   seenOpen: UserDefaults.standard.bool(forKey: AppRoot.seenOpenKey))
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "HQDebugFoldable") { AppRoot.foldable = true }
            #endif
            if AppRoot.foldable { AppLog.note("screen", "foldable iPhone (\(AppRoot.deviceModel)): two-pane root") }
        }
        #if targetEnvironment(macCatalyst)
        MacWindow.configure(windowScene)               // [mac]
        MacToolTips.install(on: window)                // [mac] icon buttons name themselves under the pointer
        MacSelection.install(on: window)               // [mac] stress test #54: the pane a click lands in has the focus
        #endif
        #if DEBUG
        ThemeDebugHooks.applyBeforeLaunch()            // [desktoplook] before anything reads the stored theme
        #endif
        #if !targetEnvironment(macCatalyst)
        DesktopSegments.macTitles(UISegmentedControl.appearance())   // [ui-sizing] segments at the UI Scale from launch
        #endif
        AppearanceSetting.apply(to: window)            // settings stream: System / Light / Dark before the first frame
        // [desktoplook] The stored skin and look are on the first frame (launch screen included).
        Theme.shared.adopt(window)
        // [backdrop] The first page and chat shown have their picture on their first frame.
        for backdrop in [Backdrop.app, Backdrop.chats] { backdrop.prepare(window.traitCollection) }
        self.window = window
        #if targetEnvironment(macCatalyst)
        MacHoverScout.start()   // [mac] hover reaches sheets, the right panel and late-made controls too
        #endif
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-HQDemoLists") || arguments.contains("-HQDemoSignIn") {
            window.rootViewController = arguments.contains("-HQDemoSignIn") ? ListsDemo.makeSignIn() : ListsDemo.makeRoot()
            window.makeKeyAndVisible()
            ThemeDebugHooks.openThemeOverDemo(window.rootViewController)   // [backdrop] Theme on a tab's stack
            #if targetEnvironment(macCatalyst)
            MacShots.startIfAsked(window)              // [mac] -HQDebugMacShots
            MacSettingsWindow.openIfAsked()            // [mac-layout] -HQDebugSettingsWindow
            #endif
            return
        }
        if arguments.contains("-HQDemoFaces") {        // [moods] every act a face plays, for a recording
            window.rootViewController = FaceMoodsDemo.makeRoot(dark: arguments.contains("-HQDemoFacesDark"),
                                                               theme: UserDefaults.standard.string(forKey: "HQDemoFacesTheme"))
            window.makeKeyAndVisible()
            return
        }
        if arguments.contains("-HQDebugPhoneVoice") {   // [phone-voice] Settings › Voice › Text to Speech › Voice alone
            let page = SettingsPageController(title: PhoneVoicePage.title, PhoneVoicePage())
            window.rootViewController = UINavigationController(rootViewController: page)
            window.makeKeyAndVisible()
            return
        }
        if arguments.contains("-HQDebugAppIcon") {   // [app-icons] Settings › App Icon alone, switching icons
            let page = SettingsPageController(title: "App Icon", AppIconPage())
            window.rootViewController = UINavigationController(rootViewController: page)
            window.makeKeyAndVisible()
            return
        }
        if let count = ChatDemo.argument("-HQDemoChat").flatMap(Int.init) {
            window.rootViewController = ChatDemo.makeRoot(count: count)
            window.makeKeyAndVisible()
            ThemeDebugHooks.openThemeOverDemo(window.rootViewController)   // [backdrop] Theme with no sign-in
            #if targetEnvironment(macCatalyst)
            MacShots.startIfAsked(window)              // [tinted-bubbles] -HQDebugMacShots <name> -HQDebugMacShotsWait <s>
            #endif
            return
        }
        DebugHooks.applyBeforeLaunch()
        #endif
        #if DEBUG
        // Settings stream (1x-settings S32): `-HQDebugReadOnly YES` turns every gateway write off for a check.
        let model = AppModel(readOnlyGateway: UserDefaults.standard.bool(forKey: "HQDebugReadOnly"))
        #else
        let model = AppModel()
        #endif
        self.model = model
        HermesUpdateCenter.app = model   // [update-flow] the onboarding screen's Update Hermes, before the tabs exist
        M2Wiring.install(model: model)                 // integration: the streams' hooks (App/Integration/M2Wiring.swift)
        TalkWiring.install(model: model)               // [talk] live voice's seams (App/Integration/TalkWiring.swift)
        model.onSignedOut = { [weak self] in self?.restore() }
        model.onSessionEnded = { [weak self] prefill in self?.showSignIn(prefill: prefill) }
        let launch = LaunchCoordinator(model: model, host: self)      // [offline]
        self.launch = launch
        window.rootViewController = launch.makeLaunchScreen()
        window.makeKeyAndVisible()
        #if DEBUG && targetEnvironment(macCatalyst)
        MacShots.startIfAsked(window)                  // [mac] -HQDebugMacShots, once signed in
        MacSettingsWindow.openIfAsked()                // [provider-add] -HQDebugSettingsWindow, signed in too
        MacFileWindow.tapIfAsked()                     // [mac-files] -HQDebugFileWindowTap
        #endif
        // [restore] A cold launch reopens the last chat, unless a tapped alert or a link launched the app to open another.
        MainTabController.launchRestorePending = connectionOptions.notificationResponse == nil
            && connectionOptions.urlContexts.isEmpty && connectionOptions.shortcutItem == nil
            && !IntentsLaunch.claims(connectionOptions)   // [intents] a shortcut, a quick action or a donated conversation
        restore()
        // [notifications] A hermes:// link that launched the app (a tapped alert arrives through NotificationHub).
        if let url = connectionOptions.urlContexts.first?.url { open(url) }
        IntentsLaunch.connected(connectionOptions, model: model)   // [intents] what launched the app, handed on
    }

    // [diagnostics] A window resize (the Mac's and the iPad's) relays out every pane: a span from the change to the
    // end of the frame that drew it (after Core Animation's commit), and an aged fact, so a stall during or just after
    // a resize names it instead of "nothing traced".
    // The previous geometry is not read: UIKit passes nil for the first one (the scene connecting), which the Swift
    // signature cannot say (it crashed the app at launch).
    func windowScene(_ windowScene: UIWindowScene, didUpdateEffectiveGeometry previousEffectiveGeometry: UIWindowScene.Geometry) {
        let size = windowScene.effectiveGeometry.coordinateSpace.bounds.size
        AppRoot.noteScreen(windowScene)
        guard let last = lastWindowSize, last != size else { lastWindowSize = size; return }
        lastWindowSize = size
        #if targetEnvironment(macCatalyst)
        MacTrail.windowResized(to: size)
        #endif
        MainTrail.set("resized", "\(Int(size.width))×\(Int(size.height))")
        let span = MainTrail.begin("window.resize")
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in
            MainTrail.end(span)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    // [intents] A Home Screen quick action on a running app (docs/spec/3x-intents.md §9.4).
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(QuickActions.perform(shortcutItem))
    }

    // [intents] A donated conversation the system hands back opens its chat (§10.3).
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        if let id = IntentsRouting.conversation(userActivity.interaction) { model?.continueConversation(id) }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        open(url)
    }

    /// hermes://session/<id> opens that chat; hermes://connect?url=… fills the sign-in (or Add Gateway) form.
    private func open(_ url: URL) {
        #if DEBUG
        if IntentsDebugHooks.handle(url, model: model) { return }   // [intents] <scheme>://debug-intent/<word>
        #endif
        // [live] <scheme>://job/<owner|id>: a job's Lock Screen progress opens its page in Jobs.
        // Signed out (no tabs): nothing to open, and it is not an unknown link, so no "isn't available" notice.
        if case .other(kind: "job", let key, _)? = DeepLink.parse(url, scheme: AppIdentity.current.urlScheme), !key.isEmpty {
            AppLog.note("link", "job")
            MainTabController.current?.openJob(key)
            return
        }
        // [marketplace] The Marketplace website's Install in Hermes: the plugin's or skill's page in a sheet, once signed in.
        if let target = MarketplaceLinks.target(DeepLink.parse(url, scheme: AppIdentity.current.urlScheme)) {
            if let model, let tabs = MainTabController.current, AppRoot.signedIn(window) {
                MarketplaceLinks.open(target, services: model, from: tabs)
            } else {
                pendingMarketplace = target
            }
            return
        }
        guard let link = NotificationRules.link(url, scheme: AppIdentity.current.urlScheme), let model else {
            // [transcript] A link of ours the app has no screen for says so (docs/spec/3x-transcript.md §7.4, L981).
            if case .other? = DeepLink.parse(url, scheme: AppIdentity.current.urlScheme), let top = window?.rootViewController {
                LinkOpener.notice(DeepLink.unavailable(device: DeviceWord.name), from: LinkOpener.noticeHost(root: top))
            }
            return
        }
        let signedIn = AppRoot.signedIn(window)   // [m9/ipad] either root
        if case .connect(let address) = link, window?.rootViewController is LaunchViewController {
            pendingConnect = address         // the restore decides: signed in → Add Gateway, else the sign-in form
            return
        }
        // [onboarding] The guide or the form is on show: the address goes into the form (the web's `showConnect`), never
        // a rebuilt root; nothing changes while a sign-in runs. On the Update screen it waits until the app shows.
        if case .connect(let address) = link {
            if let onboarding, window?.rootViewController === onboarding.navigationController {
                AppLog.note("link", "connect")
                onboarding.showForm(address: address)
                return
            }
            if updateShowing { pendingConnect = address; return }
            // [onboarding] The offline screen's sign-in sheet is up: its form takes the address (never a second form
            // or a rebuilt root under the sheet). On its locked Update screen the link waits until the app shows.
            if let root = window?.rootViewController, root is OfflineViewController,
               let top = FailureAlert.topmost(root), let flow = AddGatewayFlow.openFlow(under: top) {
                AppLog.note("link", "connect (offline sheet)")
                if !flow.showForm(address: address), flow.isLocked { pendingConnect = address }
                return
            }
        }
        model.handleLink(link, signedIn: signedIn) { [weak self] address in
            self?.pendingConnect = address
            self?.showSignIn(prefill: nil)
        }
    }

    /// A connect link that arrived while the saved sign-in was being restored.
    private var pendingConnect: String?
    /// [marketplace] An install link that arrived before the tabs did: opened once they show.
    private var pendingMarketplace: MarketplaceLinks.Target?

    func sceneDidBecomeActive(_ scene: UIScene) {
        // [offline] §6.8: only the first activation and one that follows the background is a return; an activation after
        // a mere resign-active (nobody was away, the socket and timers ran) refreshes nothing.
        let returned = returnGate.becameActive()
        let span = MainTrail.begin("app.active")          // [diagnostics] build 292
        defer { MainTrail.end(span) }
        if returned { MainTrail.set("return", "was") }    // HangWatch's context: "return was 8s ago"
        AppLog.note("app", returned ? "active" : "active (not a return)")
        #if targetEnvironment(macCatalyst)
        SystemLog.shared.start()                        // [diagnostics] the system's errors for the app, every 5 min
        #endif
        if returned {
            model?.client?.wakeReads()                  // [offline] §6.1: the next read may probe at once
            launch?.appBecameActive()                   // [offline] §3.7: the offline screen retries at once
        }
        // [offline] §6.8: a moment (Notification Center, Control Center, a permission alert) still reconciles what the
        // person may have done there (the badge, alerts acted on, questions answered); only the network refreshes wait
        // for a real return.
        model?.appDidBecomeActive(returned: returned)
        LiveActivityCenter.shared.appBecameActive()     // [live]
        TalkActivity.shared.appBecameActive()           // [talk-background] a paused conversation's card goes
        #if DEBUG
        OfflineDebug.noteActivation(returned: returned, in: window)
        Haptics.showProbe()   // [settings] -HQDebugHapticsProbe: "debug.haptics" is readable before the first cue
        OfflineDebug.notePower(in: window)   // [settings] "debug.power"
        #endif
        MainTabController.current?.noteLaunchScreen()   // [restore] a chat on show sets the "on screen" marker again
    }

    // [connect-fast] Dial back as the app comes forward, not a beat later when it is active: the socket's return is
    // idempotent, so `sceneDidBecomeActive`'s own call finds the dial already running and adds none.
    func sceneWillEnterForeground(_ scene: UIScene) {
        MainTrail.measure("app.foreground") { model?.appWillEnterForeground() }   // [diagnostics] build 292
    }

    func sceneWillResignActive(_ scene: UIScene) {
        returnGate.resignedActive()                     // [offline] §6.8
        LiveActivityCenter.shared.appLeaving()          // [live] a long turn goes on the Lock Screen (iOS starts one only now)
        AppLog.trace("app", "inactive")                 // [diagnostics] the Mac: another app came to the front
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        returnGate.enteredBackground()                  // [offline] §6.8
        AppLog.note("app", "background")
        #if targetEnvironment(macCatalyst)
        SystemLog.shared.stop()                         // [diagnostics] one last read of the system's errors
        #endif
        model?.appDidEnterBackground()
        // [restore] The screen on show is what the next cold launch reopens; leaving cleanly clears the marker.
        MainTabController.current?.noteLaunchScreen()
        LaunchChatMemory.shared.wentToBackground()
    }

    /// [diagnostics] The window closed (the Mac's ⇧⌘W, an iPad window swiped away): the app may run on without one.
    func sceneDidDisconnect(_ scene: UIScene) {
        AppLog.note("app", "window closed")
    }

    // MARK: - Routing

    /// What to show for the saved sign-in: the app (from cache, at once) or the sign-in form.
    func restore() {
        guard let model, let launch else { return }
        restoreGeneration += 1
        let generation = restoreGeneration
        launch.cover()                                // [offline] the launch screen covers the read (its timers start over)
        Task { [weak self] in
            let restoreBegan = Date()
            if generation == 1 { Signposts.begin(.session, "Restore") }
            let state = await launch.restoreState()   // [offline] the Keychain read (and OfflineDebug's hooks in DEBUG)
            guard let self, generation == self.restoreGeneration else { return }
            // [diagnostics] §2.3 "Saved sign-in restore", the launch's own (a later restore is not a startup step).
            if generation == 1 {
                StartupTimings.shared.record("native.restore", from: restoreBegan)
                Signposts.end(.session, "Restore", outcome: state.logLabel)
            }
            AppLog.note("launch", "restore: \(state.logLabel)")
            // [n20 B1] How old the saved Nous pair is: one already due right after the last run renewed was a stale copy.
            if case .signedIn = state, let tokens = model.signIn.store.storedCurrent?.nous {
                AppLog.note("launch", "restore: saved pair \(tokens.ageNote())")
            }
            switch state {
            case .signedIn(let account):
                // [offline] §3.2: the app at once from saved content; else the launch screen waits for a first list.
                launch.signedIn(account)
                #if DEBUG && (targetEnvironment(simulator) || targetEnvironment(macCatalyst))   // [mac] Debug Mac builds too
                // Screenshots: save a second gateway from SIMCTL_CHILD_HQN_ADD_* (the switcher shows from the next launch).
                let env = ProcessInfo.processInfo.environment
                if let url = env["HQN_ADD_URL"], let user = env["HQN_ADD_USERNAME"], let password = env["HQN_ADD_PASSWORD"] {
                    _ = try? await model.signIn.signInWithPassword(address: url, username: user, password: password, label: env["HQN_ADD_LABEL"])
                }
                #endif
            case .signedOut(let prefill):
                #if DEBUG && (targetEnvironment(simulator) || targetEnvironment(macCatalyst))   // [mac] Debug Mac builds too
                // Screenshots and probes: one sign-in from SIMCTL_CHILD_HQN_SIGNIN_* (process environment only), once.
                if !self.triedEnvironmentSignIn {
                    self.triedEnvironmentSignIn = true
                    if let account = try? await model.signIn.debugSignInFromEnvironment() {
                        launch.signedIn(account)
                        return
                    }
                }
                #endif
                model.shareLeaving()                  // [share] nobody is signed in: the sheet offers nobody
                self.showSignIn(prefill: prefill)
            case .unavailable(let failure):
                // [offline] §3.5: the offline screen names the cause, keeps trying and offers the ways out.
                launch.unavailable(failure)
            }
        }
    }

    /// [offline] Called by the launch coordinator once the account is active and worth showing.
    func showApp(_ account: GatewayAccount) {
        guard let model else { return }
        OnboardingGate.signedInBefore = true            // [onboarding] a later signed-out start opens on the form
        onboarding = nil; updateShowing = false
        model.activate(account)
        defer {
            model.openChatAwaitingTabs()               // [notifications] a tapped alert that waited out a slow launch
            if let address = pendingConnect {
                pendingConnect = nil
                model.handleLink(.connect(address), signedIn: true) { _ in }
            }
            if let target = pendingMarketplace {
                pendingMarketplace = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak model] in
                    guard let model, let tabs = MainTabController.current else { return }
                    MarketplaceLinks.open(target, services: model, from: tabs)
                }
            }
        }
        let root = MainTabController(services: model) { [weak model] chat in
            model?.makeChatScreen(chat) ?? ChatViewController(session: chat)
        }
        // [m9/ipad] iPad: the two-pane root around the tabs (App/Root/RootSplitController.swift); iPhone: the tabs.
        setRoot(AppRoot.make(root, window: window), animated: !(window?.rootViewController is LaunchViewController))
        TalkWiring.rootShown(root)                     // [talk] the away pill floats over this root
        ChatViewController.prewarm()
        #if DEBUG
        DebugHooks.applyAfterLaunch(root)
        ThemeDebugHooks.applyAfterLaunch(root)         // [desktoplook] -HQDebugOpenTheme
        DesktopLookTourHooks.applyAfterLaunch(root)    // [desktoplook2] -HQDebugTour (screenshot tour)
        #endif
    }

    func showSignIn(prefill: SignInService.Prefill?) {
        guard let model else { return }
        launch?.signInShown()                         // [offline] the launch and offline screens stand down
        #if targetEnvironment(macCatalyst)
        MacSettingsWindow.close()                     // [mac-ui-issues] signed out: Settings has no gateway to show
        #endif
        let driver = SignInServiceDriver(service: model.signIn)
        self.driver = driver
        var address = prefill?.address ?? ""
        if let connect = pendingConnect { address = connect; pendingConnect = nil }   // [notifications] hermes://connect
        #if DEBUG
        if address.isEmpty, let debug = DebugHooks.address { address = debug }
        #endif
        // A prefill means this account's saved session ended (refused after renewal, revoked, or the gateway forgot it):
        // say so, as the web does (spec 01 §5, `connection-startup.ts:312-314`), instead of a silent form.
        let notice: String? = prefill.map { $0.username == nil ? GatewayFailure.sessionEnded.message : SignInCopy.messages["session-ended"]! }
        // [onboarding] The welcome for a first run, the form (one Back from the welcome) for a returning one (§3.2).
        let entry = OnboardingGate.entry(
            linkAddress: nil, prefillAddress: address, notice: notice, signedInBefore: OnboardingGate.signedInBefore,
            startAtForm: OnboardingGate.startAtForm)
        updateShowing = false
        let flow = OnboardingFlow(mode: .root, driver: driver, entry: entry, address: address,
                                  username: prefill?.username ?? "", notice: notice) { [weak self, weak driver] outcome in
            guard let self, let account = driver?.signedIn ?? self.model?.signIn.currentAccount else { return }
            let name = driver?.signedInName ?? GatewayNaming.unnamed
            self.driver = nil
            // [offline] §3.2, §3.4: the storage check, then the launch screen covers until a first list has content.
            // [onboarding] The form has already read the gateway's version (§5.14): no second check once the app shows.
            switch outcome {
            case .enter: self.launch?.signedIn(account, typed: true)
            case .update(let info): self.showUpdate(info, account: account, name: name)
            }
        }
        // Audit 06-13: a gateway that ended this phone's session doesn't hide the other saved ones (the offline screen's
        // "Switch to <name>", on the form's bar).
        if prefill != nil {
            let others = model.settingsHub.accounts.filter { !$0.isCurrent && $0.hasSession }.map { (id: $0.id, title: $0.title) }
            flow.offerOtherGateways(others) { [weak self] id in self?.launch?.switchFromSignIn(id) }
        }
        // A Hermes that Nous hosts: Hermes Cloud signs in on its own, then the app opens as after the form.
        flow.openCloud = { [weak self, weak flow] in
            guard let self, let model = self.model, let flow else { return }
            CloudGatewayFlow.present(from: flow.navigationController, services: model) { [weak self] account, sheet in
                sheet.dismiss(animated: true) {
                    guard let self else { return }
                    self.driver = nil
                    self.launch?.signedIn(account, typed: true)
                }
            }
        }
        onboarding = flow
        setRoot(flow.navigationController, animated: !(window?.rootViewController is LaunchViewController))
    }

    /// [onboarding] After a typed sign-in to an older Hermes than this app needs (§5.15): the full screen, before the
    /// app shows. The sign-in is already saved, so closing the app here goes straight in next time.
    private func showUpdate(_ info: OutdatedGateway, account: GatewayAccount, name: String) {
        guard let model else { return }
        onboarding = nil
        updateShowing = true
        let screen = UpdateHermesScreen.make(name: name, info: info, account: account, check: { [weak model] in
            await model?.signIn.compatibility(for: account) ?? .unknown
        }, onEnter: { [weak self] in
            // [offline] §3.2, §3.4: the storage check, then the launch screen covers until a first list has content.
            self?.launch?.signedIn(account, typed: true)
        })
        setRoot(screen, animated: true)
    }

    private func setRoot(_ controller: UIViewController, animated: Bool) {
        // [offline] §3.1 DECISION: leaving the launch or offline screen is always the 120 ms fade (100 ms with Reduce
        // Motion), to the app and to sign-in alike; it replaces the hard cut and the 300 ms dissolve used elsewhere.
        let root = window?.rootViewController
        let leavingLaunch = root is LaunchViewController || root is OfflineViewController
        setRoot(controller, fade: leavingLaunch ? LaunchCoordinator.fade : (animated ? 0.3 : nil))
    }

    func setRoot(_ controller: UIViewController, fade: TimeInterval?) {
        guard let window else { return }
        guard let fade, window.rootViewController != nil else { window.rootViewController = controller; return }
        // [offline] §3.2: laid out before it is on screen, so the fade ends on drawn rows.
        UIView.performWithoutAnimation {
            controller.loadViewIfNeeded()
            controller.view.frame = window.bounds
            controller.view.layoutIfNeeded()
        }
        UIView.transition(with: window, duration: HQMotion.reduced ? min(fade, HQMotion.fade) : fade,   // [a11y] a short cross-fade under Reduce Motion
                          options: [.transitionCrossDissolve, .allowAnimatedContent]) {
            UIView.performWithoutAnimation { window.rootViewController = controller }
        }
    }
}
