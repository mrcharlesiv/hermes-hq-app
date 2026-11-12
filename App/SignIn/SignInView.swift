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
        let controller = UIHostingController(rootView: SignInView(model: model))
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
    enum Field: Hashable { case address, username, password, name }

    var address: String { didSet { if address != oldValue { addressChanged() } } }
    var username = ""
    var password = "" { didSet { if password != oldValue { passwordInvalid = false } } }
    /// nil until the address has been asked about (only the field shows).
    private(set) var ways: SignInWays?
    private(set) var checking = false { didSet { if checking && !oldValue { HQAnnounce.say("Checking the address", priority: .low, coalesce: true) } } }   // [a11y]
    /// The probe could not reach the address: the form stays (the probe can be wrong) and this says so under the field.
    private(set) var note: String?
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
    }

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

    private func addressChanged() {
        addressInvalid = false
        debounce?.cancel()
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            asked = ""; ways = nil; note = nil; checking = false
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
            ways = .both; note = nil; checking = false
            return
        }
        checking = true
        let normalized = SignInAddress.normalize(text)
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
            self.note = options.reachable ? nil : (options.message ?? SignInCopy.unreachableNote)
            AppLog.trace("signin", "address probe settled: reachable=\(options.reachable)")
        }
    }

    /// Until the address has been asked about, the hosted form says the web's first lead (`connection-onboarding.ts:98`).
    var subtitle: String { ways == nil && heading != nil ? OnboardingCopy.formLead : SignInCopy.subtitle(ways) }
    var footnote: String { SignInCopy.footnote(ways) }

    func signInWithNous() {
        guard busy == nil else { return }
        error = nil; notice = nil; addressInvalid = false
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            addressInvalid = true
            error = "Enter the address, then \(DeviceWord.tap) Sign in with Nous."
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
                self.error = SignInCopy.message(for: error)
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
    @AccessibilityFocusState private var spoken: SignInModel.Field?   // [a11y]
    @AccessibilityFocusState private var errorSpoken: Bool
    @ScaledMetric(relativeTo: .body) private var fieldHeight: CGFloat = 50

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                    .padding(.top, 48)
                    .padding(.bottom, 28)
                VStack(alignment: .leading, spacing: 16) {
                    addressField
                    if let note = model.note {
                        // UX study #130: said where it is seen, before a password is typed for a host that isn't there.
                        Label { Text(note) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.hqOrange) }
                            .font(Font.hq(.callout))
                            .foregroundStyle(Color.hqLabel)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("sign-in-note")
                            .transition(.opacity)
                    }
                    if let ways = model.ways {
                        options(ways)
                            .transition(.hqMotion(.opacity.combined(with: .move(edge: .top))))
                    } else {
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
                    if let error = model.error, !error.isEmpty {
                        // Selectable: some errors name a setting to type on the computer running Hermes.
                        Label { Text(error).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.circle.fill") }
                            .font(Font.hq(.callout))
                            .foregroundStyle(Color.hqRed)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityElement(children: .combine)
                            .accessibilityFocused($errorSpoken)
                            .accessibilityIdentifier("sign-in-error")
                            .transition(.opacity)
                    }
                    if model.ways != nil {
                        Text(model.footnote)
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqLabel2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
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
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
            .animation(HQMotion.swiftUI(.smooth(duration: 0.3), fades: true), value: model.ways)
            .animation(HQMotion.swiftUI(.smooth(duration: 0.2), fades: true), value: model.error)
            .animation(HQMotion.swiftUI(.smooth(duration: 0.2), fades: true), value: model.note)
            .animation(HQMotion.swiftUI(.smooth(duration: 0.2), fades: true), value: model.notice)
        }
        .scrollDismissesKeyboard(.interactively)
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

    private var header: some View {
        VStack(spacing: 10) {
            WornAppIcon(side: 72)
            Text(model.heading ?? "Hermes HQ")
                .font(Font.hq(.largeTitle).weight(.bold))
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
                            if model.busy == .nous { ProgressView().tint(.white) }
                            Text(model.busy == .nous ? "Signing In…" : "Sign in with Nous").font(Font.hq(.headline))
                        }
                        .frame(maxWidth: .infinity, minHeight: fieldHeight - 16)
                    }
                    .hqGlassProminentButtonStyle()
                    .tint(Color.hqTint)
                    .controlSize(.large)
                    .disabled(model.busy != nil)
                    .accessibilityIdentifier("sign-in-nous")
                    NousOtherAccountLink(id: "sign-in-nous-other") { focus = nil; model.signInWithOtherNousAccount() }
                        .disabled(model.busy != nil)
                }
            }
            if ways == .both {
                HStack(spacing: 10) {
                    Rectangle().fill(Color(uiColor: HQPalette.separator)).frame(height: 0.5)
                    Text("or with a password").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).fixedSize()
                    Rectangle().fill(Color(uiColor: HQPalette.separator)).frame(height: 0.5)
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

    /// Return in the address: a Nous-only gateway signs in; otherwise move on to the username (or ask now).
    /// Ways from an older address (still being re-asked) never start a sign-in.
    private func addressSubmitted() {
        model.ask()
        switch model.ways {
        case .nous where model.waysAreCurrent: focus = nil; model.signInWithNous()
        case .nous, nil: focus = nil
        case .password, .both: focus = .username
        }
    }
}

private struct SignInButtonStyle: ViewModifier {
    var prominent: Bool
    func body(content: Content) -> some View {
        if prominent {
            content.hqGlassProminentButtonStyle().tint(Color.hqTint)
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

    var body: some View {
        Button(action: action) {
            Text(SignInCopy.otherNousAccount)
                .font(Font.hq(.subheadline))
                .frame(maxWidth: .infinity, minHeight: 44)   // [ui-sizing] iOS's 44 pt touch (was 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Color.hqTintText)
        .accessibilityHint("Signs in to Nous without the login your browser remembers.")
        .accessibilityIdentifier(id)
    }
}
