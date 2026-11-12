// Settings › Notifications (the web app's notifications settings page, build 240): what iOS allows (with Open
// Settings when it's off), Enable Notifications, one switch per kind (all on by default), Show Previews, Bot Activity
// Banners (the in-app peek), whether the gateway can send alerts while the app is closed (with "Ask <bot> to Install
// It"), and Send Test Notification.

import Observation
import SwiftUI
import UIKit
import UserNotifications

@MainActor @Observable
final class NotificationsSettingsModel {
    var prefs = NotificationPrefs.load()
    var banners = NotificationPrefs.banners()
    /// [live] Show Progress on Lock Screen; offered only in a build with the widget extension.
    var liveActivities = LiveActivityCenter.isOn
    let liveOffered = LiveActivityCenter.shared.isOffered
    var status: UNAuthorizationStatus = .notDetermined
    var plugin = PushRegistrar.shared.lastPluginState
    var registered = PushRegistrar.shared.active
    var testNote: String?
    var opened = 0
    var unopened = 0
    var asking = false
    /// [manual-restart] After an add-on update the owner restarts Hermes themselves (this gateway's choice).
    var restartsByHand = false

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored weak var host: UIViewController?

    init(app: AppModel?) { self.app = app }

    var canPush: Bool { PushRegistrar.available }
    var denied: Bool { status == .denied }
    var mainBotName: String { app.flatMap { PushSetupOffer.setupBot($0.bots)?.name } ?? "Hermes" }
    /// [manual-restart] Offered where the owner can get to Hermes's computer (not on Hermes Cloud).
    var canChooseRestart: Bool { canPush && app?.account != nil && !CloudGatewayFlow.isCloud(app?.account?.baseURL) }
    func setRestartsByHand(_ on: Bool) {
        Haptics.play(.selection)
        restartsByHand = on
        AddOnUpdate.setRestartsByHand(on, account: app?.account?.id)
    }
    /// The add-on button: "Ask <bot> to…" where the bot restarts Hermes; plain where the owner does.
    var addOnButton: String {
        let byHand = restartsByHand && canChooseRestart
        if plugin == .missing { return byHand ? "Install the Add-on" : "Ask \(mainBotName) to Install It" }
        return byHand ? "Update the Add-on" : "Ask \(mainBotName) to Update It"
    }
    var testBlocker: String? { NotificationPrefs.testBlocker(denied: denied, prefs: prefs) }
    /// Sessions › Show › Outside Chats is on: its alerts get their own switch (prefs.kinds["outside"], on unless turned off).
    var outsideShown: Bool { app?.sessionStore?.showOutsideChats == true }

    func refresh() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        prefs = NotificationPrefs.load()
        banners = NotificationPrefs.banners()
        registered = PushRegistrar.shared.active
        restartsByHand = AddOnUpdate.restartsByHand(account: app?.account?.id)
        let counts = PushAlertDiagnostics.counts()
        opened = Int((counts["opened"] ?? 0) + (counts["noFace"] ?? 0))
        unopened = Int((counts["noKey"] ?? 0) + (counts["unreadable"] ?? 0) + (counts["locked"] ?? 0) + (counts["expired"] ?? 0))
        if canPush, app?.account != nil {
            plugin = await PushRegistrar.shared.pluginState().state
            registered = PushRegistrar.shared.active
        }
    }

    func setEnabled(_ on: Bool) {
        Haptics.play(.selection)
        prefs.enabled = on
        prefs.save()
        Task { @MainActor in
            if on, status == .notDetermined { _ = await AppModel.requestPermission() }
            PushRegistrar.shared.sync()
            app?.refreshBadge()
            await refresh()
            // Alerts on, but the gateway may lack the plugin that sends them while the app is closed: offer it again.
            if on, let app, canPush, plugin == .missing || plugin == .outdated {
                await PushSetupOffer.shared.check(model: app, fromSettings: true, from: host)
            }
        }
    }

    func setKind(_ kind: String, _ on: Bool) {
        Haptics.play(.selection)
        prefs.kinds[kind] = on
        prefs.save()
        PushRegistrar.shared.sync()
    }

    func setPreviews(_ on: Bool) {
        Haptics.play(.selection)
        prefs.previews = on
        prefs.save()
        PushRegistrar.shared.sync()
    }

    func setBanners(_ on: Bool) {
        Haptics.play(.selection)
        banners = on
        NotificationPrefs.setBanners(on)
    }

    func setLiveActivities(_ on: Bool) {
        Haptics.play(.selection)
        liveActivities = on
        LiveActivityCenter.shared.setOn(on)
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func askBot() {
        guard let app else { return }
        Task { @MainActor in
            asking = true
            // UX study #139: the button already asks for this, so no second "Turn On Notifications?" alert; the
            // section's footer says what that alert would have (the restart, the bot's chat).
            await PushSetupOffer.shared.check(model: app, fromSettings: true, confirm: false, from: host)
            asking = false
        }
    }

    func sendTest() {
        Haptics.play(.light)
        Task { @MainActor in
            if status == .notDetermined { _ = await AppModel.requestPermission(); await refresh() }
            guard testBlocker == nil else { return }
            let ok = await NotificationHub.shared.post(kind: "test", session: "", title: AppIdentity.current.displayName,
                                                       about: "Notifications are working.")
            if !ok { Haptics.play(.error) }   // a sent one shows itself
            testNote = ok ? "Test sent. If nothing appears, check Focus or Do Not Disturb." : "Couldn’t send a test notification."
        }
    }

    var pushTitle: String {
        guard canPush else { return "Only While the App Runs" }
        switch plugin {
        case .ready: return registered ? "On" : "Ready"
        case .missing: return "Add-on Needed"
        case .outdated: return "Update Needed"
        case .unknown: return "Can’t Check Now"
        }
    }

    var pushFooter: String {
        guard canPush else {
            // UX study #115: plain words, and the other app named as an app.
            return "\(AppIdentity.current.displayName) can alert you only while it’s open. To get alerts from your gateway while it’s closed, use the \(AppIdentity.original.displayName) app."
        }
        // UX study #139: Ask… goes ahead without the setup alert, so its words about the restart are here.
        let byHand = restartsByHand && canChooseRestart
        let restart = PushSetupOffer.restartNote(bot: mainBotName, byHand: byHand)
        // [manual-restart] The app installs it; the bot is only named where it does the restart.
        let who = byHand ? "The app" : mainBotName
        switch plugin {
        case .ready: return registered ? "Your gateway sends alerts here while the app is closed. They are sealed: only this \(DeviceWord.name) can read them."
            : "Your gateway can send alerts while the app is closed. Turn on notifications to get them."
        case .missing: return "To alert you while the app is closed, Hermes needs a small notification add-on. \(who) can set it up for you. \(restart)"
        // [addon-progress] One sentence on why, as in the update sheet (the long list was too much to read).
        case .outdated: return "This version of the app needs a newer add-on in Hermes, or some alerts and features won’t work. \(who) can update it for you. \(restart)"
        case .unknown: return "Couldn’t reach your gateway’s notification add-on. Alerts still come while the app runs."
        }
    }
}

final class NotificationsSettingsController: UIHostingController<HQScaledRoot<NotificationsSettingsView>> {
    let model: NotificationsSettingsModel

    init(app: AppModel?) {
        let model = NotificationsSettingsModel(app: app)
        self.model = model
        super.init(rootView: HQScaledRoot(NotificationsSettingsView(model: model)))
        title = "Notifications"
        navigationItem.largeTitleDisplayMode = .never
        model.host = self
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var observer: NSObjectProtocol?
    private var registeredObserver: NSObjectProtocol?

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { await model.refresh() }
        // Back from iOS Settings: what it allows may have changed.
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.model.refresh() } }
        }
        registeredObserver = NotificationCenter.default.addObserver(forName: PushRegistrar.didRegister, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.model.refresh() } }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        for o in [observer, registeredObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(o) }
        observer = nil
        registeredObserver = nil
    }
}

struct NotificationsSettingsView: View {
    @Bindable var model: NotificationsSettingsModel

    /// Enable Notifications: live, or (system notifications off) held with a line saying it isn't in effect.
    private var enabledSwitch: some View {
        SwitchRow(title: "Enable Notifications",
                  subtitle: model.denied ? "Not in effect until notifications are allowed in \(DeviceWord.settingsApp)." : nil,
                  isOn: Binding(get: { model.prefs.enabled }, set: { model.setEnabled($0) }),
                  disabled: model.denied)
            .opacity(model.denied && !DeviceWord.isMac ? 0.6 : 1)   // [mac] Stress test 2026-10-28 #51 (round 6): the Mac switch row dims itself (MacSwitchLabel)
            .accessibilityIdentifier("notifications.enabled")
    }

    var body: some View {
        List { Group {
            if model.denied {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notifications are off for \(AppIdentity.current.displayName) in \(DeviceWord.settingsApp)")
                            .font(Font.hq(.headline))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Turn on Allow Notifications there to get alerts when a reply is ready or a request needs you.")
                            .font(Font.hq(.subheadline))
                            .foregroundStyle(Color.hqLabel2)
                            .fixedSize(horizontal: false, vertical: true)
                        // Stress test 2026-10-28 #82 (both): the button names where it goes ("Open System Settings" on the Mac).
                        Button("Open \(DeviceWord.settingsApp)") { model.openSettings() }
                            .hqProminentButtonStyle()
                            .padding(.top, 6)
                            .accessibilityIdentifier("notifications.open-settings")
                    }
                    .padding(.vertical, 12)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("notifications.ios-off")
                    // Stress test 2026-10-28 #82, round 2 (both): the master switch stayed on and live while the system's
                    // was off. It sits here, beside the button that fixes it, held and saying it isn't in effect.
                    enabledSwitch
                }
            }

            Section {
                if !model.denied { enabledSwitch }
                ForEach(NotificationPrefs.shown, id: \.self) { kind in
                    Toggle(isOn: Binding(get: { model.prefs.enabled && model.prefs.kinds[kind] != false }, set: { model.setKind(kind, $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NotificationPrefs.label(kind))
                            Text(NotificationPrefs.detail(kind)).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .hqRowPadding(4)   // [mac] Stress test 2026-10-28 round 9: the list's one room on the Mac
                    }
                    .disabled(!model.prefs.enabled || model.denied)
                    .accessibilityIdentifier("notifications.kind.\(kind)")
                }
            } footer: { HQSectionFooter {
                // Stress test 2026-10-28 #82 (both): with the system's switch off these switches did nothing yet all drew
                // on and live; they are dimmed and the footer says why.
                if model.denied {
                    Text("Not in effect while notifications are off in \(DeviceWord.settingsApp).")
                } else {
                    Text(model.outsideShown ? "Off silences everything above, and Outside Chats below." : "Off silences everything above.")
                }
            } }

            if model.outsideShown {
                Section {
                    Toggle(isOn: Binding(get: { model.prefs.enabled && model.prefs.kinds["outside"] != false }, set: { model.setKind("outside", $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Outside Chats")
                            Text("Replies and approvals in Telegram, Discord and other apps.").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .hqRowPadding(4)   // [mac] Stress test 2026-10-28 round 9: the list's one room on the Mac
                    }
                    .disabled(!model.prefs.enabled || model.denied)   // #82
                    .accessibilityIdentifier("notifications.outside")
                } footer: { HQSectionFooter {
                    Text("Off, these chats still show in Sessions without alerting. Approve or deny them in their own app. Needs the latest Hermes HQ add-on on your gateway.")
                } }
            }

            Section {
                Toggle(isOn: Binding(get: { model.prefs.enabled && model.prefs.previews }, set: { model.setPreviews($0) })) {
                    Text("Show Previews")
                }
                .disabled(!model.prefs.enabled || model.denied)   // #82
                .accessibilityIdentifier("notifications.previews")
            } footer: { HQSectionFooter {
                Text("Show what a reply, question or request says. Off, alerts only say who needs you. \(DeviceWord.settingsApp) can also hide previews while \(DeviceWord.subject) is locked.")
            } }

            Section {
                Toggle("Bot Activity Banners", isOn: Binding(get: { model.banners }, set: { model.setBanners($0) }))
                    .accessibilityIdentifier("notifications.banners")
            } footer: { HQSectionFooter {
                Text("A banner at the top of \(AppIdentity.current.displayName) when a bot you aren’t looking at finishes a reply.")
            } }

            // [live] Only in a build that carries the widget extension (never the Mac).
            if model.liveOffered {
                Section {
                    Toggle(SettingsSearch.liveActivitiesLabel, isOn: Binding(get: { model.liveActivities }, set: { model.setLiveActivities($0) }))
                        .accessibilityIdentifier("notifications.live-activities")
                } footer: { HQSectionFooter {
                    Text(LiveActivityWords.footer(island: UIDevice.current.userInterfaceIdiom == .phone))
                } }
            }

            Section {
                StackingValueRow(label: "While the App Is Closed", value: model.pushTitle, valueID: "notifications.push")
                    .hqRowPadding(4)   // [mac] Stress test 2026-10-28 round 9: the list's one room on the Mac
                if model.canPush, model.plugin == .missing || model.plugin == .outdated {
                    Button(model.addOnButton) {
                        model.askBot()
                    }
                    .disabled(model.asking)
                    .accessibilityIdentifier("notifications.ask-bot")
                }
                if model.canChooseRestart {
                    // [manual-restart] Who restarts Hermes after an add-on goes in (a Hermes that needs sudo for it).
                    SwitchRow(title: AddOnUpdate.byHandToggle, subtitle: AddOnUpdate.byHandNote(model.mainBotName, on: model.restartsByHand),
                              isOn: Binding(get: { model.restartsByHand }, set: { model.setRestartsByHand($0) }))
                        .accessibilityIdentifier("notifications.restart-choice")
                }
                if model.canPush, model.opened + model.unopened > 0 {
                    // UX study #92: the count alone; alerts that couldn't be opened get their own sentence and a hint.
                    StackingValueRow(label: "Alerts Opened", value: "\(model.opened)")
                        .accessibilityElement(children: .combine)
                    if let unopened = SettingsWords.unopenedAlerts(model.unopened) {
                        Text(unopened).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("notifications.unopened")
                    }
                }
            } footer: { HQSectionFooter {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.pushFooter)
                    if model.canPush, model.unopened > 0 { Text(SettingsWords.unopenedHint) }
                }
            } }

            Section {
                Button("Send Test Notification") { model.sendTest() }
                    .disabled(model.testBlocker != nil && !(model.status == .notDetermined && model.prefs.enabled))
                    .accessibilityIdentifier("notifications.test")
            } footer: { HQSectionFooter {
                if let blocker = model.testBlocker, model.status != .notDetermined || !model.prefs.enabled {
                    Text(blocker)
                } else if let note = model.testNote {
                    Text(note).accessibilityIdentifier("notifications.test-note")
                }
            } }
        }.hqMacSettingsRowInsets() }
        .hqMacForm(settings: true)   // [mac] Stress test 2026-10-28 #8, #53: the readable width, one inset, small switches
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("notifications.list")
    }
}

/// A label and its value side by side while both fit on one line, the value under the label when they don't (UX study
/// #92: at Extra Large and the accessibility sizes the two squeezed into narrow wrapping columns).
private struct StackingValueRow: View {
    var label: String
    var value: String
    var valueID: String? = nil

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text(label).lineLimit(1)
                Spacer(minLength: 12)
                valueText.lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).fixedSize(horizontal: false, vertical: true)
                valueText.fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var valueText: some View {
        Text(value).foregroundStyle(Color.hqLabel2).accessibilityIdentifier(valueID ?? "")
    }
}
