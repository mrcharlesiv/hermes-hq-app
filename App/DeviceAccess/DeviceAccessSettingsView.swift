// [device-access] Settings › Device Access: what the bots may use from this phone. The page lists every kind with
// what is on (all off at first: nothing is shared until the person turns it on); each kind's page has its switches,
// iOS's own permission is asked with the first one turned on, and a refusal is said there with the way back. Recent
// Requests lists what bots asked (on this phone only). The last card says whether the gateway's add-on takes these
// requests at all, and whether a bot can reach this phone while the app is closed (it needs notifications).

import Observation
import SwiftUI
import UIKit

@MainActor @Observable
final class DeviceAccessSettingsModel {
    enum Gateway: Equatable { case checking, ready, contactsOnly, needsUpdate, missing, unreachable, signedOut }

    var permissions: [DeviceAccess.Kind: DeviceAccessPermission] = [:]
    var gateway: Gateway = .checking
    /// [health-all-types] Whether the gateway's add-on takes every Health type (0.9.46); an older one hears only the
    /// four old switches.
    var healthTypesOnGateway = true
    var pushOn = PushRegistrar.shared.active
    /// Email & Text Drafts a bot wrote that wait on this phone, newest first.
    var drafts: [DeviceAccess.Draft] = DraftsStore.waiting
    @ObservationIgnored weak var navigation: UINavigationController?
    @ObservationIgnored private var draftsObserver: NSObjectProtocol?

    init() {
        draftsObserver = NotificationCenter.default.addObserver(forName: DraftsStore.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.drafts = DraftsStore.waiting }
        }
    }

    isolated deinit {
        if let draftsObserver { NotificationCenter.default.removeObserver(draftsObserver) }
    }

    var center: DeviceAccessCenter { .shared }
    var kinds: [DeviceAccess.Kind] { DeviceAccess.Kind.allCases.filter(\.available) }

    func permission(_ kind: DeviceAccess.Kind) -> DeviceAccessPermission {
        permissions[kind] ?? DeviceAccessHandlers.handler(kind).permission
    }

    func refresh() async {
        for kind in kinds { permissions[kind] = DeviceAccessHandlers.handler(kind).permission }
        drafts = DraftsStore.waiting
        pushOn = PushRegistrar.shared.active
        guard let call = PushRegistrar.shared.call else { gateway = .signedOut; return }
        let status = await call(PushPolicy.route + "/status", "GET", nil)
        // Audit 09-15: a 404 is the old dispatch-push add-on (update it) or no add-on at all (install it).
        var legacy = false
        if status.status == 404 { legacy = await call(PushPolicy.legacyRoute + "/status", "GET", nil).status == 200 }
        if status.status == 200 { healthTypesOnGateway = DeviceAccess.supportsHealthTypes(status.body) }
        gateway = switch status.status {
        case 200 where DeviceAccess.supportsKinds(status.body): .ready
        case 200 where DeviceAccess.supported(status.body): .contactsOnly
        case 200: .needsUpdate
        case 404: legacy ? .needsUpdate : .missing
        default: .unreachable
        }
    }

    func set(_ kind: DeviceAccess.Kind, _ key: String, on: Bool) {
        Haptics.play(.selection)
        guard on else { return center.set(kind, key, on: false) }
        if let why = DeviceAccessHandlers.handler(kind).unsupported(key) { return say(why, about: kind, key) }
        // Guideline 5.1.2(i): before iOS's own permission, say where this kind goes once per kind; Cancel leaves
        // the switch off (DeviceAccessConsent.swift).
        guard DeviceAccessConsent.given(kind) else {
            DeviceAccessConsent.ask(kind, from: navigation) { [weak self] in self?.requestAndTurnOn(kind, key) }
            return
        }
        requestAndTurnOn(kind, key)
    }

    private func requestAndTurnOn(_ kind: DeviceAccess.Kind, _ key: String) {
        Task { @MainActor in
            let handler = DeviceAccessHandlers.handler(kind)
            let allowed = await handler.requestPermission(turningOn: key)
            permissions[kind] = handler.permission
            // Refused: the switch stays off and the page says where to allow it.
            guard allowed else { return }
            center.set(kind, key, on: true)
        }
    }

    /// [health-all-types] Several Health switches at once (a group's Turn On All, Turn Off All): one iOS sheet asks
    /// about every type being turned on, after the first-time question.
    func setHealth(_ keys: [String], on: Bool) {
        Haptics.play(.selection)
        guard on else { return center.set(.health, Set(keys), on: false) }
        guard DeviceAccessConsent.given(.health) else {
            DeviceAccessConsent.ask(.health, from: navigation) { [weak self] in self?.requestAndTurnOnHealth(keys) }
            return
        }
        requestAndTurnOnHealth(keys)
    }

    private func requestAndTurnOnHealth(_ keys: [String]) {
        Task { @MainActor in
            let allowed = await HealthAccess.requestPermission(turningOn: keys)
            permissions[.health] = HealthAccess.permission
            guard allowed else { return }
            center.set(.health, Set(keys), on: true)
        }
    }

    func openHealth(_ category: HealthCatalog.Category) {
        let page = DeviceAccessHealthCategoryController(category: category, model: self)
        page.navigationItem.largeTitleDisplayMode = .never
        navigation?.pushViewController(page, animated: true)
    }

    /// [health-all-types] Said under Health's groups while the gateway's add-on is older than 0.9.46.
    var healthGatewayNote: String? {
        guard gateway == .ready, !healthTypesOnGateway else { return nil }
        return "The add-on on your gateway is older than 0.9.46, so your bots can read only steps, sleep, workouts and heart rate until it’s updated."
    }

    /// A switch that can't be on here says why, and stays off.
    private func say(_ why: String, about kind: DeviceAccess.Kind, _ key: String) {
        guard let host = FailureAlert.topmost(navigation) else { return }
        let title = kind.scopes.first { $0.key == key }?.title ?? kind.title
        let alert = UIAlertController(title: "\(title) Isn’t Available", message: why, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        host.present(alert, animated: true)
    }

    func openDraft(_ id: String) {
        guard let host = FailureAlert.topmost(navigation) else { return }
        Haptics.play(.selection)
        DraftsStore.open(id, from: host)
    }

    func discardDraft(_ id: String) {
        Haptics.play(.selection)
        DraftsStore.discard(id)
    }

    func open(_ kind: DeviceAccess.Kind) {
        let page = DeviceAccessKindController(kind: kind, model: self)
        page.navigationItem.largeTitleDisplayMode = .never
        navigation?.pushViewController(page, animated: true)
    }

    func openRecent() {
        let page = DeviceAccessRecentController(model: self)
        page.navigationItem.largeTitleDisplayMode = .never
        navigation?.pushViewController(page, animated: true)
    }

    /// Where a refused kind is allowed again: [mac] Mac polish #11, its own pane of System Settings › Privacy & Security
    /// on the Mac (the iPhone's link opened nothing there); the app's page in iOS Settings elsewhere.
    func openSettings(_ kind: DeviceAccess.Kind) {
        PrivacySettingsLink.open(Self.pane(kind))
    }

    nonisolated static func pane(_ kind: DeviceAccess.Kind) -> PrivacySettingsLink.Pane {
        switch kind {
        case .contacts: .contacts
        case .location: .location
        case .reminders: .reminders
        case .calendar: .calendars
        case .photos: .photos
        case .alarms, .health, .motion, .music, .drafts: .privacy   // none of these is on the Mac
        }
    }

    func footer(_ kind: DeviceAccess.Kind) -> String {
        [kind.footer, DeviceAccessHandlers.handler(kind).permissionNote].compactMap { $0 }.joined(separator: " ")
    }

    var gatewayValue: String {
        switch gateway {
        case .checking: "Checking…"
        case .ready: center.settings.sharesAnything ? "On" : "Ready"
        case .contactsOnly: "Contacts Only"
        case .needsUpdate: "Update Needed"
        case .missing: "Not Installed"
        case .unreachable: "Can’t Check Now"
        case .signedOut: "Not Signed In"
        }
    }

    var gatewayFooter: String {
        let phone = "this \(DeviceWord.name)", app = AppIdentity.current.displayName
        switch gateway {
        case .checking, .signedOut:
            return "Bots on your gateway ask \(phone) when they need something you share."
        case .ready:
            // [mac] Mac polish #142: a Mac app that has quit isn't woken; a running one is reached in another app's shadow.
            if DeviceWord.isMac {
                return pushOn
                    ? "A bot’s request reaches \(app) whenever it’s running, even while you’re in another app. One that comes while it’s quit waits until you next open \(app)."
                    : "Turn on notifications so bots can reach \(phone) while you’re in another app. Until then, a request waits until you come back to \(app)."
            }
            return pushOn
                ? "A bot’s request wakes \(app) while it’s closed, when iOS allows. One it can’t reach waits until you next open \(app)."
                : "Turn on notifications so bots can reach \(phone) while \(app) is closed. Until then, a request waits until you open the app."
        case .contactsOnly:
            return "The Hermes HQ add-on on your server takes only Contacts. Everything else needs version 0.9.21 or later; until it’s updated, bots can’t ask \(phone) for it."
        case .needsUpdate:
            return "The Hermes HQ add-on on your server is out of date: Device Access needs version 0.9.21 or later. Until it’s updated, bots can’t ask \(phone) for anything."
        case .missing:
            return "Device Access needs the Hermes HQ add-on (version 0.9.21 or later) on your server, and it isn’t installed there. Until it is, bots can’t ask \(phone) for anything."
        case .unreachable:
            return "Couldn’t reach your gateway to check. Your switches are kept here and take effect once it’s back."
        }
    }

    /// Mac polish #38: "Update Needed" and "Not Installed" are a button, as the add-on row at the top of Settings is
    /// (only where the app can set the add-on up: the identity that gets pushes).
    var gatewayFixable: Bool { (gateway == .needsUpdate || gateway == .missing) && PushRegistrar.available }

    /// The same add-on update the Settings list's add-on row runs, in its sheet; the row reads the gateway again after.
    func updateAddOn() {
        guard gatewayFixable, let app = MainTabController.current?.services as? AppModel else { return }
        Haptics.play(.selection)
        let host = FailureAlert.topmost(navigation)
        Task { @MainActor in
            await PushSetupOffer.shared.check(model: app, fromSettings: true, from: host)
            await refresh()
        }
    }

    var recentValue: String {
        let count = center.recent.count
        return count == 0 ? "None" : "\(count)"
    }
}

/// "Share Health With Your Bots?" before iOS's own permission, the first time any switch of a kind is turned on
/// (App Review 5.1.2(i), owner 2026-11-01): once said yes to, a kind doesn't ask again; Cancel leaves the switch off.
@MainActor enum DeviceAccessConsent {
    private static let prefix = "hq.deviceAccess.consented."

    static func given(_ kind: DeviceAccess.Kind, _ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: prefix + kind.rawValue)
    }

    /// Which way things go. Audit 09-14: drafts come to this device from the bots (nothing of the person's goes up),
    /// and with Alarms the bots set alarms here, and only those come back.
    static func message(_ kind: DeviceAccess.Kind) -> String {
        let provider = "the AI model provider your gateway uses (for example OpenAI or Anthropic)"
        let rest = "The makers of Hermes HQ never receive it. You can turn this off anytime."
        let here = "this \(DeviceWord.name)"
        switch kind {
        case .drafts:
            return "Your bots will be able to write emails and text messages that wait on \(here) as drafts. What they write comes "
                + "from your Hermes gateway and \(provider), and nothing is sent until you \(DeviceWord.tap) Send. The makers of Hermes HQ never "
                + "receive it. You can turn this off anytime."
        case .alarms:
            return "Your bots will be able to set alarms and timers on \(here). The ones they set, and only those, will be sent to "
                + "your Hermes gateway when a bot asks for them, and from there to \(provider). Your own alarms stay private. \(rest)"
        default:
            return "Your \(kind.title) will be sent to your Hermes gateway when a bot asks for it, and from there to \(provider). \(rest)"
        }
    }

    static func ask(_ kind: DeviceAccess.Kind, from navigation: UINavigationController?, then allow: @escaping () -> Void) {
        guard let host = FailureAlert.topmost(navigation) else { return }
        let alert = UIAlertController(title: "Share \(kind.title) With Your Bots?", message: message(kind), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Allow", style: .default) { _ in
            UserDefaults.standard.set(true, forKey: prefix + kind.rawValue)
            allow()
        })
        alert.view.accessibilityIdentifier = "device-access.consent"
        host.present(alert, animated: true)
    }
}

/// Reloads its model when it shows and when the app comes back (iOS Settings may have changed a permission).
class DeviceAccessPageController<Page: View>: UIHostingController<HQScaledRoot<Page>> {
    let model: DeviceAccessSettingsModel
    private var observer: NSObjectProtocol?

    init(model: DeviceAccessSettingsModel, title: String, page: Page) {
        self.model = model
        super.init(rootView: HQScaledRoot(page))
        self.title = title
        navigationItem.largeTitleDisplayMode = .never
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let navigationController { model.navigation = navigationController }
        Task { await model.refresh() }
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.model.refresh() } }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

final class DeviceAccessSettingsController: DeviceAccessPageController<DeviceAccessSettingsView> {
    init() {
        let model = DeviceAccessSettingsModel()
        super.init(model: model, title: "Device Access", page: DeviceAccessSettingsView(model: model))
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

final class DeviceAccessKindController: DeviceAccessPageController<DeviceAccessKindView> {
    init(kind: DeviceAccess.Kind, model: DeviceAccessSettingsModel) {
        super.init(model: model, title: kind.title, page: DeviceAccessKindView(model: model, kind: kind))
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// [health-all-types] One Health group's page: Turn On All, then a switch per type.
final class DeviceAccessHealthCategoryController: DeviceAccessPageController<DeviceAccessHealthCategoryView> {
    init(category: HealthCatalog.Category, model: DeviceAccessSettingsModel) {
        super.init(model: model, title: category.title, page: DeviceAccessHealthCategoryView(model: model, category: category))
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

final class DeviceAccessRecentController: DeviceAccessPageController<DeviceAccessRecentView> {
    init(model: DeviceAccessSettingsModel) {
        super.init(model: model, title: "Recent Requests", page: DeviceAccessRecentView(model: model))
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

// MARK: - The page

struct DeviceAccessSettingsView: View {
    @Bindable var model: DeviceAccessSettingsModel

    var body: some View {
        List { Group {
            Section {
                ForEach(model.kinds, id: \.self) { kind in
                    NavRow(title: kind.title, systemImage: kind.systemImage, value: model.center.settings.summary(kind)) {
                        model.open(kind)
                    }
                    .accessibilityIdentifier("device-access.kind.\(kind.rawValue)")
                }
            } footer: { HQSectionFooter {
                Text("What you turn on here goes to your Hermes gateway, and from there to the AI model provider it uses, only when a bot asks; the makers of Hermes HQ never receive it, and you can turn it off anytime.")
            } }

            Section {
                NavRow(title: "Recent Requests", systemImage: "clock.arrow.circlepath", value: model.recentValue) { model.openRecent() }
                    .accessibilityIdentifier("device-access.recent")
            }

            Section {
                if model.gatewayFixable {
                    Button { model.updateAddOn() } label: { DeviceAccessGatewayRow(value: model.gatewayValue, opens: true) }
                        .accessibilityAddTraits(.isButton)
                } else {
                    DeviceAccessGatewayRow(value: model.gatewayValue)
                }
            } footer: { HQSectionFooter {
                Text(model.gatewayFooter)
            } }
        }.hqMacSettingsRowInsets() }
        .hqMacForm(settings: true)
        .hqGroupedPage()
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("device-access.list")
    }
}

private struct DeviceAccessGatewayRow: View {
    var value: String
    /// Mac polish #38: the row runs the add-on update; it says so with the chevron the Settings add-on row has.
    var opens = false

    var body: some View {
        HStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Text("On Your Gateway").foregroundStyle(Color.hqLabel).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(value).foregroundStyle(Color.hqLabel2).lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("On Your Gateway").foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                    Text(value).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if opens { SettingsChevron() }
        }
        .contentShape(Rectangle())
        .hqRowPadding(4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("device-access.gateway")
    }
}

// MARK: - One kind's page

struct DeviceAccessKindView: View {
    @Bindable var model: DeviceAccessSettingsModel
    let kind: DeviceAccess.Kind

    private var settings: DeviceAccess.Settings { model.center.settings }
    private var denied: Bool { model.permission(kind) == .denied }

    var body: some View {
        List { Group {
            if kind == .location {
                locationSections
            } else if kind == .health {
                healthSections
            } else {
                Section {
                    ForEach(kind.scopes, id: \.key) { scope in
                        Toggle(isOn: Binding(get: { settings.has(kind, scope.key) }, set: { model.set(kind, scope.key, on: $0) })) {
                            SettingsRowLabel(title: scope.title, systemImage: scope.systemImage)
                        }
                        // Audit 09-3: one left on when iOS Settings took the permission away can still be turned off.
                        .disabled(denied && !settings.has(kind, scope.key))
                        .accessibilityIdentifier("device-access.\(kind.rawValue).\(scope.key)")
                    }
                } footer: { HQSectionFooter { Text(model.footer(kind)) } }
            }

            if kind == .drafts, !model.drafts.isEmpty {
                Section {
                    ForEach(model.drafts) { draft in
                        Button { model.openDraft(draft.id) } label: { DeviceAccessDraftRow(draft: draft) }
                            .swipeActions {
                                Button("Delete", role: .destructive) { model.discardDraft(draft.id) }
                            }
                            .contextMenu {
                                Button("Open", systemImage: draft.kind == "text" ? "message" : "envelope") { model.openDraft(draft.id) }
                                Button("Delete", systemImage: "trash", role: .destructive) { model.discardDraft(draft.id) }
                            }
                            .accessibilityIdentifier("device-access.draft.\(draft.id)")
                    }
                } header: { HQSectionLabel { Text("Waiting for You") } } footer: { HQSectionFooter {
                    Text("\(DeviceWord.Tap) one to check it and send it. A draft you don’t send is cleared after a day.")
                } }
            }

            if denied {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(kind.title) is off for \(AppIdentity.current.displayName) in \(DeviceWord.settingsApp)")
                            .font(Font.hq(.headline))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Allow it there for your bots to use it.")
                            .font(Font.hq(.subheadline))
                            .foregroundStyle(Color.hqLabel2)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open \(DeviceWord.settingsApp)") { model.openSettings(kind) }
                            .hqProminentButtonStyle()
                            .padding(.top, 6)
                            .accessibilityIdentifier("device-access.open-settings")
                    }
                    .padding(.vertical, 12)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("device-access.denied")
                }
            }
        }.hqMacSettingsRowInsets() }
        .hqMacForm(settings: true)
        .hqGroupedPage()
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("device-access.\(kind.rawValue).list")
    }

    /// [health-all-types] Health: the Health app's groups, each opening its own page of switches, and a way to turn
    /// everything off at once.
    @ViewBuilder private var healthSections: some View {
        Section {
            ForEach(HealthCatalog.Category.allCases.filter { !DeviceAccess.Settings.healthKeys($0).isEmpty }, id: \.self) { category in
                NavRow(title: category.title, systemImage: category.systemImage, value: settings.healthSummary(category)) {
                    model.openHealth(category)
                }
                .accessibilityIdentifier("device-access.health.\(category.rawValue)")
            }
        } footer: { HQSectionFooter {
            Text([model.footer(kind), model.healthGatewayNote].compactMap { $0 }.joined(separator: " "))
        } }

        if settings.shares(.health) {
            Section {
                Button("Turn Off All Health Data", role: .destructive) {
                    model.setHealth(Array(settings.scopes(.health)), on: false)
                }
                .hqMacFormButton(destructive: true)
                .accessibilityIdentifier("device-access.health.off-all")
            }
        }
    }

    /// Location: one choice of how precisely (or Off), then While Locked.
    @ViewBuilder private var locationSections: some View {
        let levels = kind.scopes.filter { DeviceAccess.locationLevels.contains($0.key) }
        Section {
            precisionRow(title: "Off", detail: "Bots can’t ask where you are.", key: nil)
            ForEach(levels, id: \.key) { scope in
                precisionRow(title: scope.title, detail: Self.precisionDetail(scope.key), key: scope.key)
            }
        } header: { HQSectionLabel { Text("Share") } } footer: { HQSectionFooter { Text(model.footer(kind)) } }

        Section {
            Toggle(isOn: Binding(get: { settings.has(.location, "locked") }, set: { model.set(.location, "locked", on: $0) })) {
                SettingsRowLabel(title: "While Locked", systemImage: "lock")
            }
            .disabled((denied && !settings.has(.location, "locked")) || settings.precision == nil)
            .accessibilityIdentifier("device-access.location.locked")
        } footer: { HQSectionFooter {
            Text(Self.lockedFooter)
        } }
    }

    /// [mac] Mac polish #142: on the Mac, While Locked covers a minimized or hidden window and a locked Mac (a Mac app
    /// that has quit isn't woken), and macOS has no "Always" prompt or background reminder to speak of.
    static var lockedFooter: String {
        let app = AppIdentity.current.displayName
        if DeviceWord.isMac {
            return "With While Locked on, a bot can also ask while \(app) is minimized or hidden, or \(DeviceWord.subject) is locked, as long as \(app) is running."
        }
        return "With While Locked on, a bot can ask while \(app) is closed or this \(DeviceWord.name) is locked. iOS asks you to allow Location “Always”, and now and then reminds you that \(app) used it in the background."
    }

    private static func precisionDetail(_ key: String) -> String {
        switch key {
        case "city": "The city or town, nothing closer."
        case "address": "The nearest street address."
        default: "Your exact position, as Maps shows it."
        }
    }

    private func precisionRow(title: String, detail: String, key: String?) -> some View {
        let selected = settings.precision == key
        return Button {
            guard !selected else { return }
            if let key { model.set(.location, key, on: true) } else if let current = settings.precision { model.set(.location, current, on: false) }
        } label: {
            HStack(alignment: DeviceWord.isMac ? .firstTextBaseline : .center, spacing: DeviceWord.isMac ? MacForm.radioGap : 12) {
                HQRadioMark(selected: selected)
                VStack(alignment: .leading, spacing: 3) {
                    // Not `.primary`: inside a list button that resolves to the tint, and the choices read as links.
                    Text(title).foregroundStyle(Color.hqLabel)
                        .font(Font.hq(.body))
                    Text(detail).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if !DeviceWord.isMac, selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .hqRowPadding(4)
            .frame(minHeight: DeviceWord.isMac ? nil : 44)
            .contentShape(Rectangle())
        }
        .disabled(denied && key != nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("device-access.location.\(key ?? "off")")
        .hqRadioRow()
    }
}

// MARK: - One Health group

struct DeviceAccessHealthCategoryView: View {
    @Bindable var model: DeviceAccessSettingsModel
    let category: HealthCatalog.Category

    private var settings: DeviceAccess.Settings { model.center.settings }
    private var denied: Bool { model.permission(.health) == .denied }
    private var keys: [String] { DeviceAccess.Settings.healthKeys(category) }
    private var allOn: Bool { keys.allSatisfy { settings.has(.health, $0) } }

    var body: some View {
        List { Group {
            Section {
                Button(allOn ? "Turn Off All" : "Turn On All") {
                    model.setHealth(keys, on: !allOn)
                }
                .hqMacFormButton()
                .disabled(denied && !allOn)
                .accessibilityIdentifier("device-access.health.\(category.rawValue).all")
            } footer: { HQSectionFooter {
                Text(allOn ? "Your bots can read every kind of \(category.title) data below."
                     : "Turn On All asks iOS about every kind below at once.")
            } }

            Section {
                ForEach(keys, id: \.self) { key in
                    SwitchRow(title: HealthCatalog.name(key),
                              isOn: Binding(get: { settings.has(.health, key) }, set: { model.set(.health, key, on: $0) }),
                              disabled: denied && !settings.has(.health, key))
                        .accessibilityIdentifier("device-access.health.\(key)")
                }
            } footer: { HQSectionFooter {
                Text("Your bots can read summaries of what’s switched on, never change it.")
            } }
        }.hqMacSettingsRowInsets() }
        .hqMacForm(settings: true)
        .hqGroupedPage()
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("device-access.health.\(category.rawValue).list")
    }
}

// MARK: - Recent Requests

struct DeviceAccessRecentView: View {
    @Bindable var model: DeviceAccessSettingsModel

    var body: some View {
        List { Group {
            if model.center.recent.isEmpty {
                Section {
                    Text("No requests yet. When a bot uses something you share, it shows here.")
                        .foregroundStyle(Color.hqLabel2)
                        .fixedSize(horizontal: false, vertical: true)
                        .hqRowPadding(4)
                        .accessibilityIdentifier("device-access.recent.empty")
                }
            } else {
                Section {
                    ForEach(model.center.recent) { entry in
                        DeviceAccessRecentRow(entry: entry)
                    }
                } footer: { HQSectionFooter {
                    Text("Kept on this \(DeviceWord.name) only: the last 50 requests.")
                } }

                Section {
                    Button("Clear Recent Requests", role: .destructive) {
                        Haptics.play(.selection)
                        model.center.clearRecent()
                    }
                    .accessibilityIdentifier("device-access.recent.clear")
                }
            }
        }.hqMacSettingsRowInsets() }
        .hqMacForm(settings: true)
        .hqGroupedPage()
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("device-access.recent.list")
    }
}

private struct DeviceAccessDraftRow: View {
    let draft: DeviceAccess.Draft

    private var line: String {
        let who = draft.bot.isEmpty ? "Hermes" : draft.bot
        return [who, draft.createdAt.formatted(.relative(presentation: .named))].joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: draft.kind == "text" ? "message" : "envelope")
                .font(Font.hq(.body))
                .foregroundStyle(Color.hqTint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text("To \(draft.to.joined(separator: ", "))")
                    .foregroundStyle(Color.hqLabel)
                    .lineLimit(1)
                Text(draft.subject.flatMap { $0.isEmpty ? nil : $0 } ?? draft.body)
                    .font(Font.hq(.subheadline))
                    .foregroundStyle(Color.hqLabel2)
                    .lineLimit(2)
                Text(line).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .hqRowPadding(4)
        .accessibilityElement(children: .combine)
    }
}

private struct DeviceAccessRecentRow: View {
    let entry: DeviceAccess.LogEntry

    private var kind: DeviceAccess.Kind? { DeviceAccess.operations[entry.op]?.kind }

    private var outcome: String {
        switch entry.status {
        case "done": entry.count.map { "Answered (\($0))" } ?? "Answered"
        // Audit 09-13: also the app closed, the device locked, or something this device can't do, not only a switch off.
        case "unavailable": "Unavailable"
        case DeviceAccess.LogEntry.undelivered: "Answer Not Sent"
        default: "Failed"
        }
    }

    private var line: String {
        let bot = entry.bot.isEmpty ? nil : entry.bot
        let what = kind?.title
        let time = entry.date.formatted(Calendar.current.isDateInToday(entry.date) ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day().hour().minute())
        return [what, bot, time, outcome].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.summary).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
            Text(line).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hqRowPadding(4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("device-access.recent.\(entry.id)")
    }
}
