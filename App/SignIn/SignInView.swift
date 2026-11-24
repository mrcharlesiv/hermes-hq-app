// The sign-in screen (spec 01 §4): the Hermes address first; a quiet probe 600 ms after typing stops shows the ways
// in it offers — "Sign in with Nous" (the prominent glass button) and/or a username and password.

import Observation
import SwiftUI
import UIKit

enum SignInScreen {
    /// The sign-in screen as a view controller. `onSignedIn` runs once a sign-in succeeds (the host swaps the root).
    /// `notice`: why the form is back (an ended session), shown under the fields until the next attempt.
    static func make(driver: any SignInDriving, initialAddress: String = "", initialUsername: String = "",
                     notice: String? = nil, onSignedIn: @escaping () -> Void) -> UIViewController {
        let model = SignInModel(driver: driver, address: initialAddress, onSignedIn: onSignedIn)
        model.username = initialUsername
        if let notice { model.showNotice(notice) }
        let controller = SignInHostController(rootView: SignInView(model: model))
        controller.view.backgroundColor = HQPalette.page
        return controller
    }

    /// [onboarding] The form's model for `OnboardingFlow`, which hosts the form as one step of its stack.
    static func model(driver: any SignInDriving, initialAddress: String = "", initialUsername: String = "",
                      notice: String? = nil, onOutcome: @escaping (SignInOutcome) -> Void) -> SignInModel {
        let model = SignInModel(driver: driver, address: initialAddress, onOutcome: onOutcome)
        model.username = initialUsername
        if let notice { model.showNotice(notice) }
        return model
    }
}

@Observable
final class SignInModel {
    enum Busy: Equatable { case nous, password }
    enum Field: Hashable { case address, username, password, name, accessId, accessSecret }

    var address: String { didSet { if address != oldValue { addressChanged() } } }
    var username = ""
    var password = "" { didSet { if password != oldValue { passwordInvalid = false } } }
    // [cf-access] The address's Cloudflare Access service token (public issue #37): its two fields show once asked
    // for ("Behind Cloudflare Access?"), when the address answers with Access's own sign-in, or when a gateway saved
    // at this address already has one.
    var accessOpen = false
    var accessId = "" { didSet { if accessId != oldValue { accessChanged() } } }
    var accessSecret = "" { didSet { if accessSecret != oldValue { accessChanged() } } }
    /// The address answered with Cloudflare Access's sign-in (no token yet, or one it did not take).
    private(set) var behindAccess = false
    var access: CloudflareAccess? { CloudflareAccess(clientId: accessId, clientSecret: accessSecret) }
    @ObservationIgnored private var fillingAccess = false
    /// nil until the address has been asked about (only the field shows).
    private(set) var ways: SignInWays?
    /// [own-login] The browser button's words when this Hermes signs in with its own login provider (self-hosted
    /// OIDC), not Nous; nil for Nous.
    private(set) var ownLoginTitle: String?
    var browserTitle: String { ownLoginTitle ?? "Sign in with Nous" }
    private(set) var checking = false { didSet { if checking && !oldValue { HQAnnounce.say("Checking the address", priority: .low, coalesce: true) } } }   // [a11y]
    /// The probe could not reach the address: the form stays (the probe can be wrong) and this says so under the field.
    private(set) var note: String?
    /// [first-run] The latest probe found Hermes answering at the address (`SignInOptions.reachable`): the first run's
    /// "Found your Hermes." says "Reachable" beside the address only then. Nothing else reads it.
    private(set) var reachable = false
    /// Why the form is here (an ended session, a sign-in needed before a switch): information, not a failure, so it is
    /// drawn calmly and marks no field (UX study #127). Cleared by the next attempt.
    private(set) var notice: String? {
        didSet { if notice != oldValue, !viewMovesVoiceOverFocus { HQAnnounce.say(notice, priority: .high, coalesce: true) } }
    }
    /// [a11y] Spoken once when it appears or changes (the web's role="alert" line, main.ts:187). When the form is on
    /// screen it moves VoiceOver to the field at fault instead, whose hint carries the same words: announcing as well
    /// would say it twice, and the focus move would cut the announcement off.
    private(set) var error: String? {
        didSet { if error != oldValue, !viewMovesVoiceOverFocus { HQAnnounce.say(error, priority: .high, coalesce: true) } }
    }
    /// Set by `SignInView` while it is on screen.
    @ObservationIgnored var viewMovesVoiceOverFocus = false
    private(set) var addressInvalid = false
    /// The gateway turned the password down (`invalidField`, `connection-startup.ts:90-97`); cleared on typing.
    private(set) var passwordInvalid = false
    private(set) var busy: Busy? { didSet { if (busy != nil) != (oldValue != nil) { onBusyChanged?(busy != nil) } } }
    /// [onboarding] The optional Name (docs/spec/3x-onboarding.md §5.13): at most 60 characters, counted as people
    /// count them (an emoji is never cut in half). It names the gateway on this phone; it is never sent anywhere.
    var name = "" { didSet { if name.count > OnboardingCopy.nameLimit { name = String(name.prefix(OnboardingCopy.nameLimit)) } } }
    /// [onboarding] The form's heading where the onboarding flow hosts it: the web's "Sign in to Hermes." or
    /// "Add another Hermes." (`W:src/connection-onboarding.ts:97`, `W:src/main.ts:206`). nil: the app's name.
    @ObservationIgnored var heading: String?
    /// [onboarding] "Need help connecting?" (§5.12): shown only where there is a guide to open.
    @ObservationIgnored var onHelp: (() -> Void)?
    /// [onboarding] A sign-in (and the version check after it) started or ended: the flow holds navigation meanwhile.
    @ObservationIgnored var onBusyChanged: ((Bool) -> Void)?
    /// [onboarding] The cap on the version check after a sign-in (§5.14).
    @ObservationIgnored var compatibilityCap: Duration = CompatibilityCap.standard
    @ObservationIgnored var successHaptic: () -> Void = { Haptics.play(.success) }

    @ObservationIgnored private let driver: any SignInDriving
    @ObservationIgnored private let onOutcome: (SignInOutcome) -> Void
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var asked = ""
    /// The latest probe and sign-in attempt (tests await them instead of sleeping).
    @ObservationIgnored private(set) var probeTask: Task<Void, Never>?
    @ObservationIgnored private(set) var attemptTask: Task<Void, Never>?
    /// How long typing must pause before the address is asked about (`watchSignInWays`, 600 ms).
    @ObservationIgnored var delay: Duration = .milliseconds(600)

    convenience init(driver: any SignInDriving, address: String = "", onSignedIn: @escaping () -> Void) {
        self.init(driver: driver, address: address, onOutcome: { _ in onSignedIn() })
    }

    /// [onboarding] `onOutcome`: into the app, or to "Update Hermes on Your Gateway" first (§5.14).
    init(driver: any SignInDriving, address: String = "", onOutcome: @escaping (SignInOutcome) -> Void) {
        self.driver = driver
        self.address = address
        self.onOutcome = onOutcome
        if !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { ask() }
        #if DEBUG
        Self.debugLast = self
        #endif
    }

    #if DEBUG
    /// [Mac AAA 2026-11-16] The form made last, for the Mac tours (`SettingsWindowTour`, `SheetsTour`): they press Sign
    /// In through the same action the button runs (an accessibility press on the SwiftUI button did not land).
    static weak var debugLast: SignInModel?
    var debugError: String? { error }
    #endif

    /// [onboarding] An address handed to the form (a connect link, the guide's kept address): filled in and asked about.
    func fill(address new: String) {
        guard busy == nil else { return }
        // A typed password belongs to the address it was typed for: another address never inherits it.
        if SignInAddress.normalize(new) != SignInAddress.normalize(address) { password = ""; passwordInvalid = false }
        address = new
        ask()
    }

    /// [onboarding] The form left the screen for the guide: what was typed stays, except the password.
    func leftForGuide() { password = "" }

    /// [onboarding] Return in the Name field signs in the way the form offers (`enterkeyhint="go"`, `W:src/main.ts:254-258`).
    func submitFromName() {
        guard let ways else { return }
        if ways == .nous { signInWithNous() } else { signInWithPassword() }
    }

    private var label: String? { SignInService.accountLabel(name) }

    /// A message the form opens with (an ended session): shown as a notice, cleared by the next attempt.
    func showNotice(_ text: String) {
        notice = text
    }

    /// Whether `ways` answers the address in the field now (not an older one, nor one still being asked about).
    var waysAreCurrent: Bool {
        ways != nil && !checking && asked == address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// [cf-access] The token changed: the next probe and sign-in carry it, and the address is asked about again
    /// (after the same pause as typing an address), since what it offers shows only with the right token.
    private func accessChanged() {
        guard !fillingAccess else { return }
        driver.useAccess(access)
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, busy == nil else { return }
        debounce?.cancel()
        debounce = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.asked = ""
            self.ask()
        }
    }

    private func addressChanged() {
        addressInvalid = false
        debounce?.cancel()
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            asked = ""; ways = nil; ownLoginTitle = nil; note = nil; checking = false; behindAccess = false; reachable = false
            return
        }
        // [mac] A pasted setup link (hermes://connect?url=…, what the setup's QR code holds) becomes the address in it.
        if let url = URL(string: text), case .connect(let inner)? = NotificationRules.link(url, scheme: AppIdentity.current.urlScheme) {
            address = inner
            return
        }
        debounce = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.ask()
        }
    }

    /// Asks about the address now (after the pause, on Return, or when the field is left). An answer is applied only
    /// while the field still holds the text it was asked about.
    func ask() {
        debounce?.cancel()
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != asked else { return }
        asked = text
        guard SignInAddress.looksLikeAddress(text) else {
            ways = .both; ownLoginTitle = nil; note = nil; checking = false; behindAccess = false; reachable = false
            return
        }
        checking = true
        reachable = false
        let normalized = SignInAddress.normalize(text)
        // [cf-access] A gateway saved at this address already has a token: the form starts from it.
        if accessId.isEmpty, accessSecret.isEmpty, let saved = driver.savedAccess(for: normalized) {
            fillingAccess = true
            accessId = saved.clientId; accessSecret = saved.clientSecret; accessOpen = true
            fillingAccess = false
        }
        driver.useAccess(access)
        probeTask = Task { [weak self, driver] in
            let options = await driver.probe(normalized)
            // A newer ask is in flight: it owns `checking`.
            guard let self, self.asked == text else { return }
            // The field moved on while this was asked: drop the answer and forget the ask, so the pending pause asks
            // about the field's text afresh (even when it is back to this one) instead of leaving the spinner on.
            guard self.address.trimmingCharacters(in: .whitespacesAndNewlines) == text else {
                self.asked = ""
                return
            }
            self.checking = false
            self.ways = SignInWays(options)
            self.reachable = options.reachable
            self.ownLoginTitle = options.reachable && !options.offersNous ? options.ownLoginTitle : nil
            // [cf-access] Cloudflare Access answered instead of Hermes: the token's fields open and the note says why.
            self.behindAccess = options.behindAccess
            if options.behindAccess { self.accessOpen = true }
            self.note = SignInCopy.probeNote(options, hasAccess: self.access != nil)
            AppLog.trace("signin", "address probe settled: reachable=\(options.reachable) answered=\(options.answered)")
        }
    }

    /// Until the address has been asked about, the hosted form says the web's first lead (`connection-onboarding.ts:98`).
    var subtitle: String { ways == nil && heading != nil ? OnboardingCopy.formLead : SignInCopy.subtitle(ways, ownLogin: ownLoginTitle != nil) }
    var footnote: String { SignInCopy.footnote(ways, ownLogin: ownLoginTitle != nil) }

    func signInWithNous() {
        guard busy == nil else { return }
        error = nil; notice = nil; addressInvalid = false
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            addressInvalid = true
            error = "Enter the address, then \(DeviceWord.tap) \(browserTitle)."
            return
        }
        busy = .nous
        run(method: "nous") { [driver, label] in try await driver.signInWithNous(address: SignInAddress.normalize(text), label: label) }
    }

    /// [nous-different-account] Sign in with Nous in a private sheet: Safari's saved Nous login can't pick the account.
    func signInWithOtherNousAccount() {
        guard busy == nil else { return }
        NousSheetLogin.chooseAccount()
        signInWithNous()
    }

    func signInWithPassword() {
        guard busy == nil else { return }
        error = nil; notice = nil; addressInvalid = false; passwordInvalid = false
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !user.isEmpty, !password.isEmpty else {
            addressInvalid = text.isEmpty
            error = SignInCopy.messages["missing-fields"]
            return
        }
        busy = .password
        let secret = password
        run(method: "password") { [driver, label] in
            try await driver.signInWithPassword(address: SignInAddress.normalize(text), username: user, password: secret, label: label)
        }
    }

    /// One attempt per tap; never retried in a loop (the gateway rate-limits sign-ins per address).
    private func run(method: String, _ attempt: @escaping () async throws -> Void) {
        let start = ContinuousClock.now
        AppLog.trace("signin", "sign-in started: method=\(method)")
        attemptTask = Task { [weak self] in
            do {
                try await attempt()
                guard let self else { return }
                // [onboarding] The form stays busy while the gateway's version is read (one capped read; DECISION D10).
                let driver = self.driver
                let answer = await CompatibilityCap.run(self.compatibilityCap) { await driver.compatibility() }
                self.password = ""
                if let outdated = answer.outdated {
                    AppLog.note("signin", "sign-in (\(method)) ok in \(AppLog.ms(since: start)) ms, gateway needs an update")
                    self.onOutcome(.update(outdated))      // no success tap: the web taps only when the app starts
                } else {
                    AppLog.trace("signin", "sign-in (\(method)) ok in \(AppLog.ms(since: start)) ms")
                    self.successHaptic()
                    self.onOutcome(.enter)
                }
            } catch {
                guard let self else { return }
                let code = SignInCopy.code(for: error)
                self.busy = nil
                if code == "nous-cancelled" {
                    AppLog.trace("signin", "sign-in (\(method)) cancelled by the user")
                    return
                }
                AppLog.note("signin", "sign-in (\(method)) failed after \(AppLog.ms(since: start)) ms: \(code)")
                Haptics.play(.error)
                self.error = SignInCopy.message(for: error, ownLogin: self.ownLoginTitle != nil)
                self.addressInvalid = SignInCopy.marksAddress(code)
                self.passwordInvalid = SignInCopy.marksPassword(code)
            }
        }
    }
}

struct SignInView: View {
    @Bindable var model: SignInModel
    @FocusState private var focus: SignInModel.Field?
    @State private var nameText = ""
    /// Return in the address before its answer came: the answer moves on to the username (`addressSubmitted`).
    @State private var awaitingWays = false
    @AccessibilityFocusState private var spoken: SignInModel.Field?   // [a11y]
    @AccessibilityFocusState private var errorSpoken: Bool
    @ScaledMetric(relativeTo: .body) private var fieldHeight: CGFloat = 50
    @Environment(FirstRunLayout.self) private var layout: FirstRunLayout?

    var body: some View {
        // [Mac calls 2026-11-17] In the Mac's first-run window the form sits in the middle of the window (owner's call
        // Q19); elsewhere (Add Gateway, the iPhone) as before.
        let centred = layout?.centred == true
        FirstRunScroll {
            VStack(spacing: 0) {
                header
                    .padding(.top, centred ? 0 : 48)
                    .padding(.bottom, 28)
                VStack(alignment: .leading, spacing: 16) {
                    addressField
                    // [Mac AAA 2026-11-16] Not under the red line that says the same about the address (the Mac's
                    // failure at the field): "Can't reach this address" twice, in two colours.
                    if let note = model.note, !(errorAtField && model.addressInvalid) {
                        // UX study #130: said where it is seen, before a password is typed for a host that isn't there.
                        Label { Text(note) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.hqOrange) }
                            .font(Font.hq(.callout))
                            .foregroundStyle(Color.hqLabel)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("sign-in-note")
                            .transition(.opacity)
                    }
                    if model.accessOpen {
                        accessFields
                            .transition(.hqMotion(.opacity.combined(with: .move(edge: .top))))
                    }
                    // [cf-access] Until Cloudflare Access lets the address through there is nothing to sign in to yet.
                    if let ways = model.ways, !model.behindAccess {
                        options(ways)
                            .transition(.hqMotion(.opacity.combined(with: .move(edge: .top))))
                    } else if model.ways == nil {
                        continueButton
                    }
                    if let notice = model.notice, !notice.isEmpty {
                        Label { Text(notice) } icon: { Image(systemName: "info.circle") }
                            .font(Font.hq(.callout))
                            .foregroundStyle(Color.hqLabel2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("sign-in-notice")
                            .transition(.opacity)
                    }
                    if let error = model.error, !error.isEmpty, !errorAtField {
                        errorLine(error)
                    }
                    if model.ways != nil, !model.behindAccess {
                        Text(model.footnote)
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqLabel2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                    if model.ways != nil, !model.accessOpen {
                        // [cf-access] Quiet, and only once there is an address: most gateways have no Access in front.
                        Button(SignInCopy.Access.open) { model.accessOpen = true; focus = .accessId }
                            .font(Font.hq(.subheadline))
                            .foregroundStyle(Color.hqTintText)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .disabled(model.busy != nil)
                            .accessibilityIdentifier("sign-in-access-open")
                    }
                    if let help = model.onHelp {
                        // [onboarding] §5.12: always there, also before the address has been asked about.
                        Button(OnboardingCopy.needHelp) { focus = nil; help() }
                            .font(Font.hq(.body))
                            .foregroundStyle(Color.hqTint)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .disabled(model.busy != nil)
                            .accessibilityIdentifier("sign-in-help")
                    }
                }
                .frame(maxWidth: 440)
                #if targetEnvironment(macCatalyst)
                // [macpass-settings r2] Tab and Shift-Tab go down and up the form's fields in order. The Mac's own Tab
                // went from Username back to the address (and selected it, so the password typed next replaced it).
                .onKeyPress(keys: [.tab], phases: .down) { press in
                    guard let next = tabTarget(back: press.modifiers.contains(.shift)) else { return .ignored }
                    focus = next
                    return .handled
                }
                // [macpass-settings2] The handler above never hears Tab from inside a field (the field's own key loop
                // takes it first, and went from Username back to the address): the controller's Tab key does it.
                .onAppear {
                    SignInTabKeys.mover = { back in
                        if let next = tabTarget(back: back, from: SignInTabKeys.currentField()) { focus = next }
                    }
                    // [macpass-settings2] Add Gateway… and the first run opened with no field focused: typing the
                    // address went nowhere until the field was clicked. A Mac form starts in its first field.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        if focus == nil, model.ways == nil { focus = .address }
                    }
                }
                #endif
            }
            .padding(.horizontal, 24)
            .firstRunVerticalPadding(top: 0, bottom: 32, centred: centred)
            .frame(maxWidth: .infinity)
            .animation(HQMotion.swiftUI(.smooth(duration: HQMotion.move), fades: true), value: model.ways)
            .animation(HQMotion.swiftUI(.smooth(duration: HQMotion.move), fades: true), value: model.accessOpen)
            .animation(HQMotion.swiftUI(.smooth(duration: HQMotion.fade), fades: true), value: model.error)
            .animation(HQMotion.swiftUI(.smooth(duration: HQMotion.fade), fades: true), value: model.note)
            .animation(HQMotion.swiftUI(.smooth(duration: HQMotion.fade), fades: true), value: model.notice)
        }
        .scrollDismissesKeyboard(.interactively)
        // [macpass-settings2] Return in the address before the address had been asked about left no field focused when
        // the answer came: the username typed next went nowhere, and Tab then selected the address.
        .onChange(of: model.ways) { _, ways in
            guard awaitingWays, ways != nil else { return }
            awaitingWays = false
            if ways?.showsPassword == true, model.username.isEmpty { focus = .username }
        }
        // [a11y] After a failure VoiceOver lands on the field at fault, or on the message when no field is.
        .onChange(of: model.error) { _, error in
            guard let error, !error.isEmpty else { return }
            if model.addressInvalid { spoken = .address }
            else if model.passwordInvalid { spoken = .password }
            else { errorSpoken = true }
            // The focused element speaks the message. If the move did not take (the element is not on screen yet, or
            // no assistive technology took it), say it instead: once either way.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                guard model.error == error else { return }
                if spoken != nil || errorSpoken { HQAnnounce.noteFocusSpoke(error) }
                else { HQAnnounce.say(error, priority: .high, coalesce: true) }
            }
        }
        .onAppear { model.viewMovesVoiceOverFocus = true }
        .onDisappear { model.viewMovesVoiceOverFocus = false }
        .background(Color.hqPage.ignoresSafeArea())
        .onChange(of: focus) { old, new in
            if old == .address, new != .address { model.ask() }
        }
    }

    /// [Mac AAA 2026-11-16] On the Mac a failure that marks a field (a wrong password, an address that isn't Hermes)
    /// is said right under that field: under the form's foot it was below the window's edge in Add Gateway…, so a
    /// wrong password showed only as a red edge.
    private var errorAtField: Bool { DeviceWord.isMac && (model.addressInvalid || model.passwordInvalid) }

    private func errorLine(_ error: String) -> some View {
        // Selectable: some errors name a setting to type on the computer running Hermes.
        Label { Text(error).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.circle.fill") }
            .font(Font.hq(.callout))
            .foregroundStyle(Color.hqRed)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)   // the field's width (it wrapped at two-thirds of it)
            .accessibilityElement(children: .combine)
            .accessibilityFocused($errorSpoken)
            .accessibilityIdentifier("sign-in-error")
            .transition(.opacity)
    }

    private var header: some View {
        VStack(spacing: 10) {
            WornAppIcon(side: 72)
            Text(model.heading ?? "Hermes HQ")
                .font(Font.hq(.largeTitle).weight(.hqBold))
                .foregroundStyle(Color.hqLabel)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("sign-in-heading")
            Text(model.subtitle)
                .font(Font.hq(.subheadline))
                .foregroundStyle(Color.hqLabel2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .frame(maxWidth: 360)
        }
    }

    private var addressField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hermes address").font(Font.hq(.footnote).weight(.medium)).foregroundStyle(Color.hqLabel2)
            HStack(spacing: 8) {
                TextField("my-mac.tail1234.ts.net", text: $model.address)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(model.ways == .nous && model.waysAreCurrent ? .go : .next)
                    .focused($focus, equals: .address)
                    .onSubmit(addressSubmitted)
                    .accessibilityLabel("Hermes address")
                    .hqFieldValidity(invalid: model.addressInvalid, message: model.error)
                    .accessibilityFocused($spoken, equals: .address)
                    .accessibilityIdentifier("sign-in-address")
                if model.checking {
                    ProgressView().controlSize(.small).accessibilityLabel("Checking the address")
                } else if model.address.isEmpty {
                    // One tap for the address Hermes (or the setup) sent: the system's own Paste, so nothing asks for
                    // permission, and a whole pasted message gives up the address in it.
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        Task { @MainActor in
                            focus = nil
                            model.fill(address: SignInAddress.pasted(text))
                        }
                    }
                    .labelStyle(.titleOnly)
                    .buttonBorderShape(.capsule)
                    .tint(Color.hqTint)
                    .accessibilityIdentifier("sign-in-paste")
                }
            }
            .fieldStyle(height: fieldHeight, invalid: model.addressInvalid)
            if errorAtField, model.addressInvalid, let error = model.error, !error.isEmpty { errorLine(error).padding(.top, 4) }
        }
        .disabled(model.busy != nil)
    }

    /// [cf-access] The Cloudflare Access service token for this address, right under it (public issue #37).
    private var accessFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(SignInCopy.Access.title) \(SignInCopy.Access.clientId)").font(Font.hq(.footnote).weight(.medium)).foregroundStyle(Color.hqLabel2)
                TextField(SignInCopy.Access.clientId, text: $model.accessId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .accessId)
                    .onSubmit { focus = .accessSecret }
                    .fieldStyle(height: fieldHeight, invalid: false)
                    .accessibilityIdentifier("sign-in-access-id")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(SignInCopy.Access.clientSecret).font(Font.hq(.footnote).weight(.medium)).foregroundStyle(Color.hqLabel2)
                SecureField(SignInCopy.Access.clientSecret, text: $model.accessSecret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .accessSecret)
                    // [Mac UI check 2026-11-13] Return goes on, as Return in the address does (it only left the field).
                    .onSubmit(addressSubmitted)
                    .fieldStyle(height: fieldHeight, invalid: false)
                    .accessibilityIdentifier("sign-in-access-secret")
            }
            Text(SignInCopy.Access.footnote)
                .font(Font.hq(.footnote))
                .foregroundStyle(Color.hqLabel2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(model.busy != nil)
    }

    /// UX study #73: a next step from the start. It asks about the address now (as Return does) and shows the check;
    /// the sign-in controls take its place when the answer comes.
    private var continueButton: some View {
        let empty = model.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button(action: { focus = nil; model.ask() }) {
            // The field's own spinner shows the check; the button only says so.
            Text(model.checking ? "Checking…" : "Continue").font(Font.hq(.headline))
                .frame(maxWidth: .infinity, minHeight: fieldHeight - 16)
        }
        .hqGlassProminentButtonStyle()
        .tint(Color.hqTint)
        .controlSize(.large)
        .disabled(empty || model.checking || model.busy != nil)
        .accessibilityIdentifier("sign-in-continue")
    }

    @ViewBuilder private func options(_ ways: SignInWays) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if ways == .nous { nameField }
            if ways.showsNous {
                VStack(spacing: 4) {
                    Button(action: { focus = nil; model.signInWithNous() }) {
                        HStack(spacing: 8) {
                            if model.busy == .nous { ProgressView().tint(Color.hqOnTint) }
                            Text(model.busy == .nous ? "Signing In…" : model.browserTitle).font(Font.hq(.headline))
                        }
                        .frame(maxWidth: .infinity, minHeight: fieldHeight - 16)
                    }
                    .hqGlassProminentButtonStyle()
                    .tint(Color.hqTint)
                    .controlSize(.large)
                    .disabled(model.busy != nil)
                    .accessibilityIdentifier("sign-in-nous")
                    if model.ownLoginTitle == nil {   // [own-login] a Nous matter: their own sign-in page picks the account
                        NousOtherAccountLink(id: "sign-in-nous-other") { focus = nil; model.signInWithOtherNousAccount() }
                            .disabled(model.busy != nil)
                    }
                }
            }
            if ways == .both {
                HStack(spacing: 10) {
                    Rectangle().fill(Color(uiColor: HQPalette.separator)).frame(height: HQShape.line(0.5))
                    Text("or with a password").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).fixedSize()
                    Rectangle().fill(Color(uiColor: HQPalette.separator)).frame(height: HQShape.line(0.5))
                }
                .padding(.vertical, 2)
                .accessibilityHidden(true)
            }
            if ways.showsPassword {
                passwordFields
                nameField
                Button(action: { focus = nil; model.signInWithPassword() }) {
                    HStack(spacing: 8) {
                        if model.busy == .password { ProgressView() }
                        Text(model.busy == .password ? "Signing In…" : "Sign In").font(Font.hq(.headline))
                    }
                    .frame(maxWidth: .infinity, minHeight: fieldHeight - 16)
                }
                .modifier(SignInButtonStyle(prominent: ways == .password))
                .controlSize(.large)
                .disabled(model.busy != nil)
                .accessibilityIdentifier("sign-in-password-button")
            }
        }
    }

    private var passwordFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Username").font(Font.hq(.footnote).weight(.medium)).foregroundStyle(Color.hqLabel2)
                TextField("Username", text: $model.username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .username)
                    .onSubmit { focus = .password }
                    .fieldStyle(height: fieldHeight, invalid: false)
                    .accessibilityIdentifier("sign-in-username")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Password").font(Font.hq(.footnote).weight(.medium)).foregroundStyle(Color.hqLabel2)
                SecureField("Password", text: $model.password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focus, equals: .password)
                    .onSubmit { focus = nil; model.signInWithPassword() }
                    .fieldStyle(height: fieldHeight, invalid: model.passwordInvalid)
                    .hqFieldValidity(invalid: model.passwordInvalid, message: model.error)
                    .accessibilityFocused($spoken, equals: .password)
                    .accessibilityIdentifier("sign-in-password")
                if errorAtField, model.passwordInvalid, !model.addressInvalid, let error = model.error, !error.isEmpty {
                    errorLine(error).padding(.top, 4)
                }
            }
        }
        .disabled(model.busy != nil)
    }

    /// [onboarding] The optional Name (§5.13; `W:src/main.ts:187`): under Password, or under the address for Nous only.
    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(OnboardingCopy.nameLabel).font(Font.hq(.footnote).weight(.medium)).foregroundStyle(Color.hqLabel2)
            // The field keeps its own text: a binding that shortens what was just typed leaves the extra characters on
            // show, so the cap is applied here, a turn later, and the model gets the capped text.
            TextField(OnboardingCopy.namePlaceholder, text: $nameText)
                .onChange(of: nameText) { _, typed in
                    let capped = String(typed.prefix(OnboardingCopy.nameLimit))
                    if capped != typed { nameText = capped }
                    if model.name != capped { model.name = capped }
                }
                .onChange(of: model.name, initial: true) { _, kept in if nameText != kept { nameText = kept } }
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($focus, equals: .name)
                .onSubmit { focus = nil; model.submitFromName() }
                .fieldStyle(height: fieldHeight, invalid: false)
                .accessibilityIdentifier("sign-in-name")
        }
        .disabled(model.busy != nil)
    }

    /// [macpass-settings r2] The fields on show, top to bottom: where Tab (Shift-Tab: `back`) goes from the focused one.
    /// `from`: the field being typed in, when known (`SignInTabKeys.currentField`); else the form’s focus.
    private func tabTarget(back: Bool, from: SignInModel.Field? = nil) -> SignInModel.Field? {
        var order: [SignInModel.Field] = [.address]
        if model.accessOpen { order += [.accessId, .accessSecret] }
        if let ways = model.ways, !model.behindAccess {
            if ways == .nous { order.append(.name) }
            if ways.showsPassword { order += [.username, .password, .name] }
        }
        // Not knowing where Tab came from, it goes nowhere: going to the address selected it, so what was typed next
        // (a password) replaced the address, on show.
        guard let current = from ?? focus, let index = order.firstIndex(of: current) else { return nil }
        let next = back ? index - 1 : index + 1
        return order.indices.contains(next) ? order[next] : order[back ? order.count - 1 : 0]
    }

    /// Return in the address: a Nous-only gateway signs in; otherwise move on to the username (or ask now).
    /// Ways from an older address (still being re-asked) never start a sign-in.
    private func addressSubmitted() {
        model.ask()
        switch model.ways {
        case .nous where model.waysAreCurrent: focus = nil; model.signInWithNous()
        case .nous: focus = nil
        case nil: focus = nil; awaitingWays = true
        case .password, .both: focus = .username
        }
    }
}

private struct SignInButtonStyle: ViewModifier {
    var prominent: Bool
    func body(content: Content) -> some View {
        if prominent {
            content.hqGlassProminentButtonStyle().tint(Color.hqTint)
        } else if DeviceWord.isMac {
            // [macpass-settings2] The Mac's plain push button, the same height as Sign in with Nous above it (iOS's
            // glass capsule stood 48 pt tall under the 32 pt prominent button).
            content.hqBorderedButtonStyle()
        } else {
            content.hqGlassButtonStyle()
        }
    }
}

private extension View {
    /// A calm, native field: the search-fill rounded rectangle, a red edge only on a wrong address.
    func fieldStyle(height: CGFloat, invalid: Bool) -> some View {
        self
            .font(Font.hq(.body))
            .padding(.horizontal, 14)
            .frame(minHeight: height)
            .background(RoundedRectangle(cornerRadius: HQShape.radius(12, .card), style: .continuous).fill(Color(uiColor: HQPalette.searchFill)))
            .overlay(RoundedRectangle(cornerRadius: HQShape.radius(12, .card), style: .continuous)
                .strokeBorder(Color.hqRed, lineWidth: invalid ? 1.5 : 0))
    }
}

/// [nous-different-account] Use Another Nous Account, under a Sign in with Nous button: the sheet opens private, so the
/// Nous login Safari remembers can't pick the account (`NousSheetLogin`).
struct NousOtherAccountLink: View {
    let id: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(SignInCopy.otherNousAccount)
                .font(Font.hq(.subheadline))
                .frame(maxWidth: .infinity, minHeight: 44)   // [ui-sizing] iOS's 44 pt touch (was 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        // [Mac AAA 2026-11-16] Dimmed with the button above it while a sign-in runs (it stayed full blue, looking live).
        .foregroundStyle(isEnabled ? Color.hqTintText : Color.hqLabel3)
        .accessibilityHint("Signs in to Nous without the login your browser remembers.")
        .accessibilityIdentifier(id)
    }
}

#if targetEnvironment(macCatalyst)
/// [macpass-settings2] Tab and Shift-Tab in the sign-in form on the Mac. The fields' own key loop went from Username back
/// to the address and selected it, so the password typed next replaced the address, on show. The controller hosting
/// the form takes Tab first (`wantsPriorityOverSystemBehavior`) and the form moves its focus down or up its fields.
@MainActor enum SignInTabKeys {
    /// Set by the form on show: moves the focus from the field being typed in.
    static var mover: ((_ back: Bool) -> Void)?

    static let commands: [UIKeyCommand] = [false, true].map { back in
        let command = UIKeyCommand(input: "\t", modifierFlags: back ? .shift : [],
                                   action: back ? #selector(OnboardingStepController.hqSignInTabBack)
                                                : #selector(OnboardingStepController.hqSignInTab))
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    static func move(back: Bool) { mover?(back) }

    /// The field being typed in, from the first responder's placeholder (the fields' words are all different).
    static func currentField() -> SignInModel.Field? {
        FirstResponderFinder.found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.hqSignInFindFirstResponder), to: nil, from: nil, for: nil)
        guard let field = FirstResponderFinder.found as? UITextField, let placeholder = field.placeholder else { return nil }
        switch placeholder {
        case SignInCopy.Access.clientId: return .accessId
        case SignInCopy.Access.clientSecret: return .accessSecret
        case "Username": return .username
        case "Password": return .password
        case OnboardingCopy.namePlaceholder: return .name
        case "my-mac.tail1234.ts.net": return .address
        default: return nil
        }
    }
}

@MainActor private enum FirstResponderFinder { static weak var found: UIResponder? }

extension UIResponder {
    @objc fileprivate func hqSignInFindFirstResponder() { FirstResponderFinder.found = self }
}

/// The standalone sign-in screen's host, with the form's Tab keys.
final class SignInHostController<Content: View>: UIHostingController<Content> {
    override var keyCommands: [UIKeyCommand]? { SignInTabKeys.commands }
    @objc func hqSignInTab() { SignInTabKeys.move(back: false) }
    @objc func hqSignInTabBack() { SignInTabKeys.move(back: true) }
}
#else
final class SignInHostController<Content: View>: UIHostingController<Content> {}
#endif
