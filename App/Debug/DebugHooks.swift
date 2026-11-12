// DEBUG-only launch hooks for UI tests and screenshots (compiled out of Release). They never carry a password:
// a sign-in is typed into the form (UI tests) or comes from `SignInService.debugSignInFromEnvironment()`.
//
// - `-HQDebugAddress <url>`       prefill the sign-in address
// - `-HQDebugResetAccounts YES`   forget every saved sign-in and the local caches before launch (a clean first run)
// - `-HQDebugOpenBot <id>`        open that bot's chat once the app is up (screenshots)
// - `-HQDebugGatewaysPage YES`    open Settings › Gateways once the app is up; `-HQDebugCloudHost YES` makes every
//                                 gateway pass for a Nous-hosted one; `-HQDebugCloudPanel panel|panel-stopped|panel-busy|
//                                 panel-signin` fills its Hermes Cloud panel with made-up agents; `-HQDebugGatewaysScroll
//                                 gateways|bottom` scrolls the page to its gateway list or to Sign Out
// - `-HQDebugFocusComposer YES`   …and raise the keyboard in it
// - `-HQDebugSend <text>`         …and send that text once the chat is open
// - `-HQDebugDraft <text>`        …and leave that text in the field unsent (screenshots of Send)
// - `-HQDebugQueue <text>`        …and send this one 1.5 s later (it queues behind a running reply)
// - `-HQDebugScrollBots <points>` scroll the Bots list that far once it has drawn (rows under the bar)
// - `-HQDebugSessionsTab YES`     start on the Sessions tab
// - `-HQDebugOtherApps YES`       and open its Other Apps page once it has a row (screenshots)
// - `-HQDebugOutsideChats YES`    turn Filter › Show › Outside Chats on at launch (screenshots of Other Apps; AppModel)
// - `-HQDebugResetSessionsView YES`  [sessions-m9] Filter and Sort starts from its defaults and no lost send is kept
//                                 (AppModel, where the Sessions store is made)
// - `-HQDebugNoWarmer YES`        save no chat tails ahead of a tap (first-open probes; AppModel)
// - `-HQDebugTuckPrompts YES`     password/secret/vault sheets start tucked into their chip (ChatPromptsController)
// - `-HQDebugAppearance dark|light` force the window's appearance (screenshots)
// - `-HQDebugScrollChat <points>` scroll the opened chat toward older rows (screenshots)
// - `-HQDebugScrollMoreEnd YES` More opens scrolled to its foot (MoreViewController; the website / GitHub buttons)
// - `-HQDebugJumpApproval YES`   [desktop-frost] the jump button in its "Approval needed" state (ChatViewController)
// - `-HQDebugAttach "<abs path>,<abs path>"`  attach those files when a chat opens, through the pickers' own import code
//                                 (images go the photo path, others as files); once per launch
//                                 (App/Chat/Attachments/ChatAttachmentsController.swift `DebugAttach`;
//                                 `-HQDebugAttachDelay <s>` waits that long first)
// - `-HQDebugBotPhoto "<abs path>[,<abs path>…]"`  [photoheads] Edit Bot › Upload › Choose an image…: either menu item
//                                 takes the next of these files instead of opening the system picker (which runs in
//                                 another process); the file goes through the picker's own read, then Move and Scale
//                                 (App/BotInfo/BotPhotoPicker.swift `DebugBotPhoto`;
//                                 `-HQDebugBotPhotoDelay <s>` holds the read that long: the loading state)
// - `-HQDebugUploadTimeout <s>`   [photoheads] the wait for a bot picture's upload to answer, instead of the real 30 s
//                                 (HermesKit/Store/BotPhotoStore.swift `BotPhotoTiming.standard`; UI test S2)
// - voice memo hooks: App/Debug/VoiceDebugHooks.swift
// - [pins] `-HQDebugResetPins YES`        no pinned artifacts on any account, and pins as Cards
// - [provider-manager] `-HQDebugResetProviderPrefs YES`  no provider or model renamed, hidden or added on any account
// - [pins] `-HQDebugPinsTour <name>`      pin six artifacts and photograph Artifacts, Pinned (Grid, Cards, List) and each Bot Info tab (tmp/pins-tour)
// - [offline] `-HQDebugResetCaches`, `-HQDebugRestoreFailure`, `-HQDebugOfflineReason`, `-HQDebugStorageFailure`,
//   `-HQDebugPowerSaving`, `-HQDebugProcessClaim`: App/Offline/OfflineDebug.swift
// - [update-flow] `-HQDebugUpdateShot asking|waiting|installing|restarting|updated|unchanged|cant|uptodate|failed|cloud-asking|cloud-working|cloud-updated|cloud-unchanged|cloud-unconfirmed`
//                                the one Hermes update sheet in that state (App/Pages/More/CommandCenter/HermesUpdate.swift);
//                                `-HQDebugUpdateShotHidden YES` leaves it closed and files it under the gateway in use (its
//                                rows say "Updating …"); `-HQDebugUpdateRows YES` makes the gateway in use report 0.22.5
//                                with 0.23.0 available (Settings › Gateways, More's row); `-HQDebugUpdateName <name>` names the gateway in the
//                                sheet. Command Center: `-HQPagesMore`.
// - `-HQDebugCloudShot start|home|first|compose|gathering|working|waking|success|failed|agent|agent-stopped|agent-busy|resize|variables|delete`
//                                Hermes Cloud… in that state (or on an agent's page) with made-up agents
// - `-HQDebugTextOut <folder>`    MENUS: write what ⋯ › Share hands the share sheet (share.txt) and what a hold menu's
//                                 Copy left on the pasteboard (copy.txt) there, for UI checks (spec 1x §14.3 29, 30)

// - [onboarding] `-HQDebugWelcome YES`  a clean first run starts on the welcome (DEBUG builds start on the form, one Back
//                                 from it, so suites that wait for the address field keep working; Release never does)
// - [onboarding] `-HQDebugGuideStep <step>`  a first run opens on that guide screen (start, getHermes, hermes, where, mac1…)
// - [onboarding] `-HQDebugCorruptSignIn YES`  simulator only: the saved sign-in is made unreadable before the first restore
// - [onboarding] `-HQDebugGuideOut <folder>`  write what the guide's Copy put on the pasteboard (copy.txt), what Send…
//                                 handed the share sheet (share.txt) and the last link asked to open (open.txt)
// - [onboarding] `-HQDebugGuideFail copy,share,open`  the named guide actions report failure (their error lines)

#if DEBUG
import PhotosUI
import UIKit

enum DebugHooks {
    private static var defaults: UserDefaults { .standard }

    static var address: String? { defaults.string(forKey: "HQDebugAddress").flatMap { $0.isEmpty ? nil : $0 } }
    static var resetSessionsView: Bool { defaults.bool(forKey: "HQDebugResetSessionsView") }       // [sessions-m9]
    /// [sessions-layout] UI tests: the device's unread marks and watermarks from scratch (chats and bots), so a chat
    /// one test marked unread is not in the next test's New for You (the fixture resets the server's side itself).
    static var resetUnread: Bool { defaults.bool(forKey: "HQDebugResetUnread") }
    static var outsideChats: Bool { defaults.bool(forKey: "HQDebugOutsideChats") }
    /// `-HQDebugSessionsGroupBy project`: Sessions grouped this way at launch (date, project, bot, status).
    static var sessionsGroupBy: SessionGroupBy? { defaults.string(forKey: "HQDebugSessionsGroupBy").flatMap(SessionGroupBy.init(rawValue:)) }
    /// `-HQDebugSessionsPreview YES|NO`: Group By Recent's Row Detail › Preview at launch (pictures).
    static var sessionsPreview: Bool? { defaults.object(forKey: "HQDebugSessionsPreview").map { _ in defaults.bool(forKey: "HQDebugSessionsPreview") } }
    /// [project-cards] `-HQDebugSessionsOpen /home/hermes/site,/home/hermes/app`: these projects open at launch (pictures).
    static var sessionsOpen: [String] {
        (defaults.string(forKey: "HQDebugSessionsOpen") ?? "").split(separator: ",").map(String.init)
    }
    /// [project-cards] `-HQDebugSessionsRunning e-12,e-09`: these chats show as running a turn (pictures).
    static var sessionsRunning: Set<String> {
        Set((defaults.string(forKey: "HQDebugSessionsRunning") ?? "").split(separator: ",").map(String.init))
    }
    /// [project-cards] `-HQDebugSessionsFold new,pinned`: these groups start closed (pictures of the projects).
    static var sessionsFold: [String] {
        (defaults.string(forKey: "HQDebugSessionsFold") ?? "").split(separator: ",").map(String.init)
    }

    /// `-HQDebugTextOut`: writes `text` as `name` in that folder (nothing without the argument).
    static func recordText(_ text: String, as name: String) {
        guard let folder = defaults.string(forKey: "HQDebugTextOut"), !folder.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? text.write(toFile: (folder as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    static func applyBeforeLaunch() {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        IslandDebugHook.start()               // [island-fit] -HQDebugIsland (App/Debug/IslandDebugHook.swift)
        #endif
        VoiceDebugHooks.applyBeforeLaunch()   // VOICE: -HQDebugMemo…, -HQDebugSendOnRelease, -HQDebugResetVoice
        WordsBenchHook.applyBeforeLaunch()    // [more accurate words] -HQDebugWordsBench <speed>
        CapabilitiesDebugHooks.applyBeforeLaunch() // [capabilities] -HQDebugResetConnectApps, HQN_CAP_AUTH (App/Debug/CapabilitiesDebugHooks.swift)
        TalkDebugHooks.applyBeforeLaunch()    // [talk] -HQDebugTalk…, -HQDebugReadRepliesAloud (App/Debug/TalkDebugHooks.swift)
        IntentsDebugHooks.applyBeforeLaunch() // [intents] -HQDebugResetIntents, -HQDebugIntentsOut (App/Intents/IntentsDebugHooks.swift)
        OfflineDebug.applyBeforeLaunch()      // [offline] -HQDebugResetCaches, -HQDebugPowerSaving
        Haptics.installProbeIfAsked()         // [settings] -HQDebugHapticsProbe
        if defaults.bool(forKey: "HQDebugResetPins") { ArtifactPins.debugReset(); ArtifactHidden.debugReset() }   // [pins] no pins, Cards, nothing removed
        if defaults.bool(forKey: "HQDebugResetProviderPrefs") { ProviderPrefsStore.debugReset() }   // [provider-manager]
        // `-HQDebugResetSwipePeek YES`: the Sessions and Bots swipe peeks play again (`-HQDebugNoSwipePeek YES` skips them).
        if defaults.bool(forKey: "HQDebugResetSwipePeek") {
            defaults.removeObject(forKey: SwipePeek.sessionsKey)
            defaults.removeObject(forKey: SwipePeek.botsKey)
        }
        #if targetEnvironment(simulator)
        // [onboarding] An unreadable saved sign-in on purpose (docs/spec/3x-onboarding.md §5.16).
        if defaults.bool(forKey: "HQDebugCorruptSignIn") { AccountVault.app.debugMakeUnreadable() }
        #endif
        guard defaults.bool(forKey: "HQDebugResetAccounts") else { return }
        #if targetEnvironment(macCatalyst)
        // [mac] The Hermes HQ identity's Debug build shares its data folder with the website's download on the same Mac
        // (same bundle ID): a reset here deleted the owner's chats, drafts, favourites and prompts. Its sign-in is kept
        // apart (project.yml `.debug`), the rest can't be; test with the native identity, whose folder is its own.
        if AppIdentity.current.bundleId == AppIdentity.pushTopic {
            AppLog.note("debug", "reset refused: this Mac build shares the download's data folder")
            return
        }
        #endif
        AccountVault.app.removeAll()
        OnboardingGate.signedInBefore = false   // [onboarding] a clean first run has never signed in
        TranscriptCache.shared.purgeAll()
        try? FileManager.default.removeItem(at: AppModel.listsCacheDirectory)
        // [main-e2e] Kept page answers (Capabilities' warm-up, under 30 minutes old, stood in for its read in the next
        // test) and the synced documents' state go too.
        try? FileManager.default.removeItem(at: PagesCache.root)
        if let sync = GatewaySync.defaultDirectory { try? FileManager.default.removeItem(at: sync) }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("hq.gatewaySync.") { defaults.removeObject(forKey: key) }
        // [attachments] drafts, phone copies and media of every account
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        for url in [support?.appending(path: "HQNAttachments"), support?.appending(path: "drafts"), caches?.appending(path: "HQNMedia")] {
            if let url { try? FileManager.default.removeItem(at: url) }
        }
        ModelPrefs.forgetAll()                  // MENUS: favourites, recents, presets of every account
        CommandFavorites.forgetAll()            // starred commands of every account
        defaults.removeObject(forKey: PromptLibrary.defaultsKey)            // ⋯ › Prompts starts empty
        // [m2/pages] integration: a clean first run starts on Bots — no restored tab, Kanban decision or scope (the
        // keys are per account, and a reset signs the same fixture account in again).
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("pages.") { defaults.removeObject(forKey: key) }
        LaunchChatMemory.shared.forgetAll()     // [restore] no chat reopens on a clean first run
        // [screen] a clean first run: no remembered screen kind, saved hold or seen rotate hint
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("hq.screen.") { defaults.removeObject(forKey: key) }
        defaults.removeObject(forKey: SessionsViewController.peekKey)       // the Sessions swipe peek plays again
        defaults.removeObject(forKey: BrowserHealth.popupsOfferKey)        // Watch Browser offers the popups update again
        // [botslist] The Bots peek moves a row under every suite's first press: a test's clean run has seen it already,
        // unless the test asks for it (`-HQDebugResetSwipePeek YES`).
        if !defaults.bool(forKey: "HQDebugResetSwipePeek") { defaults.set(true, forKey: SwipePeek.botsKey) }
    }

    static func applyAfterLaunch(_ root: MainTabController) {
        GlassCensus.start()                     // [glass-census] -HQDebugGlassCensus
        AnimationWatch.start()                  // [perf] -HQDebugAnimationWatch (App/Debug/AnimationWatch.swift)
        TalkDebugHooks.applyAfterLaunch(root)   // [talk] -HQDebugTalkProbe
        PopLoopDebugHook.start(root)            // [perf] -HQDebugPopLoop (App/Debug/PopLoopDebugHook.swift)
        DuoDebugHooks.applyAfterLaunch(root)    // [duo] -HQDebugDuoTurn (App/Debug/DuoDebugHooks.swift)
        if let state = defaults.string(forKey: "HQDebugAddOnUpdate") {
            // [addon-progress] The add-on update sheet in one state (AddOnUpdate.demo), over whatever the other hooks
            // opened; `-HQDebugAddOnUpdateHidden YES` leaves it closed (Settings' row while it runs), and `notoutrow`
            // is the reminder after an update found the add-on not out yet.
            Task { @MainActor in
                for _ in 0..<40 {
                    if let app = root.services as? AppModel, app.botsLoaded, !app.bots.isEmpty { break }
                    try? await Task.sleep(for: .seconds(0.5))
                }
                try? await Task.sleep(for: .seconds(defaults.object(forKey: "HQDebugAddOnUpdateDelay") != nil ? defaults.double(forKey: "HQDebugAddOnUpdateDelay") : 1.5))
                let app = root.services as? AppModel
                if state == "notoutrow" {
                    guard let id = app?.account?.id else { return }
                    AddOnReminder.shared.report(account: id, state: .outdated, without: [])
                    AddOnReminder.shared.noteNotOut(account: id, want: PushSetupOffer.neededVersion(main: true))
                    return
                }
                // [plugin-updates] `pluginrow`, `pluginsrow`: the reminder for one plugin with an update, or three.
                if state == "pluginrow" || state == "pluginsrow", let id = app?.account?.id {
                    func plugin(_ name: String, _ from: String, _ to: String) -> PluginInfo {
                        PluginInfo(name: name, key: name, version: from, description: "", source: "catalog", enabled: true, hasDesktopHalf: false,
                                   servers: [], updateAvailable: true, catalogVersion: to, catalogSha: nil, schema: [])
                    }
                    var list = [plugin("web-clipper", "1.4.2", "1.5.0")]
                    if state == "pluginsrow" { list += [plugin("field-notes", "0.8.0", "0.9.1"), plugin("spotify", "2.1.0", "2.2.0")] }
                    PluginUpdateReminder.shared.report(account: id, profile: "default", list: list)
                    return
                }
                if state == "row", let id = app?.account?.id { AddOnReminder.shared.report(account: id, state: .outdated, without: []); return }
                // [browser-update] `browserrow`: the reminder for a browser add-on that switched itself off; `browseroff`:
                // Watch Browser on the main bot showing that add-on's "Is Off" page with its Update button.
                if state == "browserrow", let id = app?.account?.id {
                    AddOnReminder.shared.report(account: id, state: .ready, without: [])
                    AddOnReminder.shared.reportBrowser(account: id, need: .off)
                    return
                }
                if state == "browseroff", let app {
                    BrowserViewerController.debugOff = true
                    let main = app.bots.first { $0.id == "default" } ?? app.bots.first
                    guard let main, let host = FailureAlert.topmost(root) else { return }
                    app.openBrowser(BrowserScope(profile: main.id, title: main.name), from: host)
                    return
                }
                let bot = app?.bots.first { $0.id == "default" }?.name ?? "Hermes"
                guard AddOnUpdate.shared.demo(state, bot: bot, model: app) else { return }
                if !defaults.bool(forKey: "HQDebugAddOnUpdateHidden") { AddOnUpdate.shared.show(from: nil) }
            }
        }
        if defaults.string(forKey: "HQDebugUpdateShot") != nil || defaults.bool(forKey: "HQDebugUpdateRows") {
            // [update-flow] The Hermes update sheet in one state, and/or a made-up "0.23.0 available" for the rows.
            let state = defaults.string(forKey: "HQDebugUpdateShot")
            Task { @MainActor in
                for _ in 0..<40 {
                    if let app = root.services as? AppModel, app.botsLoaded, !app.bots.isEmpty { break }
                    try? await Task.sleep(for: .seconds(0.5))
                }
                try? await Task.sleep(for: .seconds(1.5))
                guard let app = root.services as? AppModel, let account = app.account else { return }
                let center = HermesUpdateCenter.shared
                if defaults.bool(forKey: "HQDebugUpdateRows") {
                    center.note(HermesUpdateCheck(json: .object([
                        "behind": .number(6), "update_available": .bool(true), "can_apply": .bool(true),
                        "current_version": .string("0.22.5"), "source_version": .string("0.23.0"), "install_method": .string("git"),
                    ])), for: account.id)
                }
                guard let state, let run = center.demo(state, name: defaults.string(forKey: "HQDebugUpdateName") ?? HermesUpdateCenter.name(account), place: HermesUpdate.place(account)) else { return }
                if defaults.bool(forKey: "HQDebugUpdateShotHidden") { center.adopt(run, as: account.id); return }
                run.show(from: nil)
            }
        }
        // [attachments] screenshots in dark or light whatever the simulator's setting (`-HQDebugAppearance dark|light`)
        if let mode = defaults.string(forKey: "HQDebugAppearance") {
            root.view.window?.overrideUserInterfaceStyle = Theme.shared.style(for: mode == "dark" ? .dark : .light)   // [desktoplook2] a one-look skin still wins
        }
        if defaults.object(forKey: "HQDebugScrollBots") != nil {
            // Screenshots of rows under the bar: scroll the Bots list by that many points once it has drawn.
            let points = CGFloat(defaults.double(forKey: "HQDebugScrollBots"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                guard let list = root.botsViewController.collectionView else { return }
                list.setContentOffset(CGPoint(x: 0, y: list.contentOffset.y + points), animated: true)
            }
        }
        if defaults.bool(forKey: "HQDebugSessionsTab") { root.select(.sessions) }
        if let name = defaults.string(forKey: "HQDebugPinsTour") {
            // [pins] The Mac's pins tour on the iPhone (any text size, no UI test steps): pictures of the window in the
            // app's tmp/pins-tour (`xcrun simctl get_app_container <udid> <bundle> data`).
            Task { @MainActor in
                for _ in 0..<40 where root.pages?.more == nil { try? await Task.sleep(for: .seconds(0.5)) }
                try? await Task.sleep(for: .seconds(2))
                let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "pins-tour")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                await root.pages?.debugPinsTour(root: root) { label in
                    guard let window = root.view.window else { return }
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    try? image.pngData()?.write(to: folder.appending(path: "\(name)-\(label).png"))
                }
            }
        }
        if let state = defaults.string(forKey: "HQDebugCloudShot") {
            // Screenshots of Hermes Cloud… in one state, with made-up agents (App/Gateways/CloudGatewayFlow.swift).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { CloudGatewayFlow.present(from: root, services: root.services, demo: state) }
        }
        if let address = defaults.string(forKey: "HQDebugCloudDesktop"), let url = URL(string: address) {
            // [cloud-desktop] A Hermes Cloud agent's Hermes Desktop, opened at once (App/Gateways/CloudDesktopWeb.swift).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { CloudDesktopWeb.present(gateway: url, name: "Hermes", from: root) }
        }
        if defaults.bool(forKey: "HQDebugGatewaysPage") {
            // Screenshots of Settings › Gateways (with `-HQDebugCloudHost YES`, its Manage on Hermes Cloud… entries).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { SettingsScreens.presentGateways(from: root, services: root.services) }
        }
        guard let bot = defaults.string(forKey: "HQDebugOpenBot") else { return }
        openWhenListed(bot, root: root, attempts: 40)
    }

    private static func openWhenListed(_ id: String, root: MainTabController, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard root.services.bots.contains(where: { $0.id == id }) else {
                if attempts > 0 { openWhenListed(id, root: root, attempts: attempts - 1) }
                return
            }
            root.botsViewController.open(id)
            whenChatShows(root: root, attempts: 20)
        }
    }

    /// The push waits for the chat's first rows (at most 0.35 s): look for it on top, then run the chat hooks.
    private static var debugSent = false

    private static func whenChatShows(root: MainTabController, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let chat = root.botsViewController.navigationController?.paneChat else {
                if attempts > 0 { whenChatShows(root: root, attempts: attempts - 1) }
                return
            }
            if defaults.object(forKey: "HQDebugScrollChat") != nil {
                // [attachments] screenshots of older rows: scroll the chat toward older messages by that many points.
                let points = CGFloat(defaults.double(forKey: "HQDebugScrollChat"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { chat.debugScroll(by: points) }
            }
            if let action = defaults.string(forKey: "HQDebugCensusAction") {   // [glass-census]
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    switch action {
                    case "commands": chat.presentCommandsSheet()
                    case "model": chat.presentModelSheet()
                    case "modelpanel": chat.menus?.presentModelPanel()   // [model-panel]
                    case "context-window":   // [context-window] the model panel's Context fact tapped: its sheet
                        chat.menus?.presentModelPanel()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { chat.menus?.debugOpenModelPanelFact(ModelPanelState.Fact.contextTitle) }
                    case "modelpanel-drag":   // [model-panel] mid-drag on the thinking scale, held there
                        chat.menus?.presentModelPanel()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { chat.menus?.debugHoldModelPanelDial(at: 0.66) }
                    // [keys-return] With -HQDebugFocusComposer YES: a pop-up opens over the keys and closes 3 s later.
                    case "keys-commands":
                        chat.presentCommandsSheet()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { chat.presentedViewController?.dismiss(animated: true) }
                    case "keys-picker":
                        var config = PHPickerConfiguration()
                        config.selectionLimit = 1
                        chat.present(PHPickerViewController(configuration: config), animated: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { chat.presentedViewController?.dismiss(animated: true) }
                    case "keys-panel":
                        chat.menus?.presentModelPanel()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { chat.menus?.debugCloseModelPanel() }
                    case "keys-all-models":
                        chat.menus?.presentModelPanel()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { chat.menus?.debugModelPanelAllModels() }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { chat.presentedViewController?.dismiss(animated: true) }
                    case "modelpanel-menu":   // [model-panel] Switch Model's menu open (-HQDebugModelPanelSample YES for its catalog)
                        chat.menus?.presentModelPanel()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { chat.menus?.debugOpenModelPanelMenu() }
                    case "modelpanel-approvals":   // [model-panel] the Approvals menu open
                        chat.menus?.presentModelPanel()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { chat.menus?.debugOpenModelPanelApprovals() }
                    case "modelpanel-sweep":   // [model-panel] a finger turning the ring up, down and back (screen recordings)
                        chat.menus?.presentModelPanel()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { chat.menus?.debugSweepModelPanelDial() }
                    case "modelpanel-warp":   // [thinking-drive] the drive from Off to the top and back to High (screen recordings)
                        chat.menus?.presentModelPanel()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { chat.menus?.debugWarpModelPanelDial() }
                    case "undo": UndoPill.show(label: "Chat deleted", duration: 30, in: chat) {}
                    default: break
                    }
                }
            }
            VoiceDebugHooks.chatShown(chat)   // VOICE: -HQDebugMemoShot / -HQDebugMemoShotNotice / -HQDebugMemoShotTip
            TalkDebugHooks.chatShown(chat)    // [talk] -HQDebugTalkShot
            if defaults.bool(forKey: "HQDebugFocusComposer") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { chat.focusComposer() }
            }
            if let text = defaults.string(forKey: "HQDebugDraft") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { chat.composer.text = text }
            }
            if let text = defaults.string(forKey: "HQDebugSend"), !debugSent {
                // The words sit in the field for a moment first, as typed ones would (the send lift starts from them).
                // Once per launch: the main screen can be made again (sign-in, then the accounts load), and each made
                // one opened the chat and sent the words again ([tasks] Mac shots 2026-11-04: four of the same).
                debugSent = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { chat.composer.text = text }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) { chat.composer.submit() }
            }
            if let text = defaults.string(forKey: "HQDebugQueue") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    chat.composer.text = text
                    chat.composer.submit()
                }
            }
        }
    }
}
#endif
