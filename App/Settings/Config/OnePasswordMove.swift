// [1password-allow] One login out of Private, when a bot needs it. Owner 2026-11-16, at the login sheet for a site
// whose login is only in his Private vault: "I want it to move my best buy password to a shared vault when I try to
// have it use it. A one time approval to move the login creds so that it now can use it."
//
// The bots' key can't read Private, so the move is his own: the 1Password password once (1Password on the phone
// fills it), the site's logins are shown, and one approval moves that one login into the vault the bots read. The
// page says exactly what moves, and where, before the button. The login sheet opens on this page where the add-on can
// do it (`move` in its status); Type It Instead goes to the fields.

import Observation
import SwiftUI
import UIKit

@MainActor @Observable final class OnePasswordMoveModel {
    enum Phase: Equatable {
        case signIn(String?)                    // the 1Password password, once (why the last try failed)
        case finding
        case found([OnePasswordAllowWire.Match])
        case moving
        case done(String)                       // the vault it went to
        case failed(String, code: String)
    }

    private(set) var phase: Phase = .signIn(nil)
    var picked: String?
    let origin: String
    /// The vault a moved login goes to, for the words before the answer names it.
    var vault: String { OnePasswordAllowModel.known.vaults.first { $0 == OnePasswordAllowWire.newVault } ?? OnePasswordAllowModel.known.vaults.first ?? OnePasswordAllowWire.newVault }

    @ObservationIgnored var call: PushRegistrar.Call? = PushRegistrar.shared.call
    @ObservationIgnored var pause: Duration = .milliseconds(1000)
    @ObservationIgnored private var job: String?
    @ObservationIgnored private var run: Task<Void, Never>?

    init(origin: String) { self.origin = origin }

    var site: String { OnePasswordAllowWire.site(origin) }

    /// Find this site's logins the bots can't read. The password is sent and dropped.
    func find(password: String) {
        run?.cancel()
        phase = .finding
        job = nil
        let body: [String: Any] = ["password": password, "origin": origin]
        run = Task { [weak self] in
            guard let self, let call = self.call else { return }
            let started = await call(OnePasswordAllowWire.route + "/move", "POST", body)
            guard !Task.isCancelled else { return }
            guard started.status == 200, let first = OnePasswordAllowWire.moveJob(started.body) else {
                self.fail(started.status == 0 ? "Hermes didn’t answer. Check your connection and try again."
                                              : OnePasswordAllowWire.failure(started.body), started.body?["code"] as? String ?? "failed")
                return
            }
            self.job = first.id
            await self.follow()
        }
    }

    /// The approval: move the picked login.
    func move() {
        guard let job, let picked, case .found = phase else { return }
        run?.cancel()
        phase = .moving
        run = Task { [weak self] in
            guard let self, let call = self.call else { return }
            let sent = await call(OnePasswordAllowWire.route + "/move/" + job, "POST", ["item": picked])
            guard !Task.isCancelled else { return }
            guard sent.status == 200 else {
                self.fail(sent.status == 0 ? "Hermes didn’t answer. Check your connection and try again."
                                           : OnePasswordAllowWire.failure(sent.body), sent.body?["code"] as? String ?? "failed")
                return
            }
            await self.follow()
        }
    }

    func again() {
        run?.cancel()
        phase = .signIn(nil)
    }

    func stop() { run?.cancel() }

    private func fail(_ why: String, _ code: String) {
        AppLog.note("vault", "1Password move failed: \(code)")
        phase = code == "password" ? .signIn(why) : .failed(why, code: code)
    }

    private func follow() async {
        guard let job, let call else { return }
        var looks = 0
        while looks < 240, !Task.isCancelled {
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled else { return }
            let answer = await call(OnePasswordAllowWire.route + "/move/" + job, "GET", nil)
            guard !Task.isCancelled else { return }
            if answer.status == 404 { phase = .failed("Hermes restarted before this finished. Try again.", code: "gone"); return }
            guard answer.status == 200, let now = OnePasswordAllowWire.moveJob(answer.body) else { continue }
            looks += 1
            switch now.job {
            case .waiting, .moving: continue
            case .found(let matches):
                picked = matches.count == 1 ? matches[0].id : nil   // one login: it is the one; several: the person says which
                phase = .found(matches)
                return
            case .done(let vault):
                AppLog.note("vault", "1Password: one login moved")
                phase = .done(vault)
                return
            case .failed(let why, let code):
                fail(why, code)
                return
            }
        }
        if !Task.isCancelled { phase = .failed("1Password didn’t answer in time. Try again.", code: "timeout") }
    }
}

struct OnePasswordMoveView: View {
    @State var model: OnePasswordMoveModel
    /// The login is in the bots' vault: the caller answers the card.
    let done: () -> Void
    /// The fields, for typing or filling the login here instead.
    let typeInstead: () -> Void
    @State private var password = ""
    @FocusState private var typing: Bool

    var body: some View {
        List { Group {
            switch model.phase {
            case .signIn(let why): signIn(why)
            case .finding: LoadingSection(text: "Looking in 1Password…")
            case .found(let matches): found(matches)
            case .moving: LoadingSection(text: "Moving it…")
            case .done(let vault):
                Section { Label("Moved to \(vault)", systemImage: "checkmark.circle.fill").foregroundStyle(Color.hqLabel) }
            case .failed(let why, _): failed(why)
            }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .onDisappear { model.stop() }
        .onChange(of: model.phase) { _, phase in
            if case .done = phase {
                Haptics.play(.success)
                done()
            } else if case .failed = phase {
                Haptics.play(.error)
            }
        }
        .accessibilityIdentifier("onepassword.move")
    }

    /// What will happen is the first thing on the page, above the box and never under the keyboard (owner
    /// 2026-11-16: "You need to do a better job explaining what is going to happen before you start moving
    /// passwords"). The keyboard waits for a tap in the box.
    @ViewBuilder private func signIn(_ why: String?) -> some View {
        Section {
            Text("Your bots can’t read your \(model.site) login where it is in 1Password. Sign in below to find it. You’ll see the login and approve before anything moves, and only that one login moves, into your \(model.vault) vault.")
                .foregroundStyle(Color.hqLabel)
                .accessibilityIdentifier("onepassword.move.words")
        } header: { HQSectionLabel {
            Text("\(model.site) Login")
        } }
        Section {
            SecureField("1Password Password", text: $password)
                .textContentType(.password)
                .focused($typing)
                .submitLabel(.continue)
                .onSubmit(send)
                .accessibilityIdentifier("onepassword.move.password")
            if let why {
                Text(why).font(Font.hq(.subheadline)).foregroundStyle(Color.hqRed)
            }
        } footer: { HQSectionFooter {
            #if targetEnvironment(macCatalyst)
            Text("Click the box and fill it from 1Password, or type your password.")
            #else
            Text("Tap the box, then the key above the keyboard to fill it from 1Password.")
            #endif
        } }
        Section {
            Button("Find My Login", action: send)
                .font(Font.hq(.body).weight(.semibold))
                .disabled(password.isEmpty)
                .accessibilityIdentifier("onepassword.move.find")
            Button("Type It Instead", action: typeInstead)
                .accessibilityIdentifier("onepassword.move.type")
        }
    }

    private func send() {
        guard !password.isEmpty else { return }
        let sent = password
        password = ""
        typing = false
        model.find(password: sent)
    }

    @ViewBuilder private func found(_ matches: [OnePasswordAllowWire.Match]) -> some View {
        Section {
            ForEach(matches) { match in
                Button {
                    Haptics.play(.selection)
                    model.picked = match.id
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(match.title).foregroundStyle(Color.hqLabel).lineLimit(1)
                            if !match.user.isEmpty {
                                Text(match.user).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(match.vault).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).lineLimit(1)
                        Image(systemName: "checkmark").font(Font.hq(.body).weight(.semibold))
                            .opacity(model.picked == match.id ? 1 : 0).accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("onepassword.move.item.\(match.title)")
                .accessibilityAddTraits(model.picked == match.id ? .isSelected : [])
            }
        } header: { HQSectionLabel {
            Text(matches.count == 1 ? "Your \(model.site) Login" : "Your \(model.site) Logins")
        } } footer: { HQSectionFooter {
            if let match = matches.first(where: { $0.id == model.picked }) {
                Text(OnePasswordAllowWire.moveLine(match, to: model.vault))
            } else {
                Text("Pick the one your bots should use.")
            }
        } }
        Section {
            Button("Move to \(model.vault)") { model.move() }
                .font(Font.hq(.body).weight(.semibold))
                .disabled(model.picked == nil)
                .accessibilityIdentifier("onepassword.move.approve")
            Button("Type It Instead", action: typeInstead)
        }
    }

    @ViewBuilder private func failed(_ why: String) -> some View {
        Section {
            Text(why).foregroundStyle(Color.hqLabel).accessibilityIdentifier("onepassword.move.failure")
            Button("Try Again") { model.again() }
            Button("Type It Instead", action: typeInstead)
        }
    }
}

extension OnePasswordMoveView {
    @MainActor static func controller(model: OnePasswordMoveModel, done: @escaping () -> Void,
                                      typeInstead: @escaping () -> Void) -> UIViewController {
        let host = UIHostingController(rootView: OnePasswordMoveView(model: model, done: done, typeInstead: typeInstead))
        host.view.backgroundColor = .clear
        return host
    }
}
