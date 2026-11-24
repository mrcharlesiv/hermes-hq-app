// [1password-allow] Allow in 1Password: one click in the 1Password app on Hermes's computer instead of a master
// password, and the bots keep the access (OnePasswordAllowWire.swift says how). Two doors, one page:
//  - the unlock sheet a bot's turn waits on (PromptSheets.swift): Allow in 1Password leads, the master password stays
//    under it for anyone who'd rather;
//  - Passwords › Password Managers › 1Password: Allow in 1Password…, then Disconnect… once it's allowed.
// The page: 1Password is asking on the computer → which vaults → done. The key itself never reaches the app.

import Observation
import SwiftUI
import UIKit

@MainActor @Observable final class OnePasswordAllowModel {
    enum Phase: Equatable {
        case signIn(String?)                          // away from the computer: the 1Password password, once (why it failed)
        case asking                                   // sending the request
        case waiting                                  // the 1Password app shows Allow on Hermes's computer
        case choose([OnePasswordAllowWire.Vault])
        case making
        case moving(Int, Int)                         // the Private vault's logins on their way to Main
        case done(bots: Int, vaults: [String])
        case failed(String, code: String)
    }

    private(set) var phase: Phase = .asking

    /// `byPassword`: start on the 1Password password (nobody is at Hermes's computer to click Allow) instead of
    /// asking that computer's 1Password app.
    init(byPassword: Bool = false) {
        self.byPassword = byPassword
        if byPassword { phase = .signIn(nil) }
    }
    let byPassword: Bool
    var picked: Set<String> = []
    var makeNew = false

    @ObservationIgnored var call: PushRegistrar.Call? = PushRegistrar.shared.call
    /// Between looks at the job.
    @ObservationIgnored var pause: Duration = .milliseconds(1200)
    @ObservationIgnored private var job: String?
    @ObservationIgnored private var run: Task<Void, Never>?

    /// The last answer about this gateway, so the unlock sheet is drawn right the first time it shows.
    static var known = OnePasswordAllowWire.Status()

    static func status(profile: String? = nil, call: PushRegistrar.Call? = PushRegistrar.shared.call) async -> OnePasswordAllowWire.Status {
        guard let call else { return OnePasswordAllowWire.Status() }
        var path = OnePasswordAllowWire.route
        if let profile, !profile.isEmpty, let named = profile.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?profile=\(named)"
        }
        let answer = await call(path, "GET", nil)
        guard answer.status == 200 else {
            if answer.status == 404 { known = OnePasswordAllowWire.Status() }   // an add-on without it
            return answer.status == 404 ? OnePasswordAllowWire.Status() : known
        }
        known = OnePasswordAllowWire.status(answer.body)
        return known
    }

    static func disconnect(call: PushRegistrar.Call? = PushRegistrar.shared.call) async -> Bool {
        guard let call else { return false }
        let answer = await call(OnePasswordAllowWire.route, "DELETE", nil)
        if answer.status == 200 { known.connected = false; known.ours = false; known.vaults = [] }
        return answer.status == 200
    }

    var canGive: Bool { !picked.isEmpty || makeNew }

    /// Ask 1Password (again, after a failure). `password`: sign in with it on Hermes's computer, once; it is sent
    /// and dropped, never kept here.
    func start(password: String? = nil) {
        run?.cancel()
        phase = .asking
        job = nil
        let body: [String: Any] = password.map { ["password": $0] } ?? [:]
        run = Task { [weak self] in
            guard let self, let call = self.call else { self?.phase = .failed("Hermes’s add-on didn’t answer.", code: "failed"); return }
            let started = await call(OnePasswordAllowWire.route + "/allow", "POST", body)
            guard !Task.isCancelled else { return }
            guard started.status == 200, let first = OnePasswordAllowWire.job(started.body) else {
                AppLog.note("vault", "1Password allow didn't start (\(started.status))")
                self.phase = .failed(started.status == 0 ? "Hermes didn’t answer. Check your connection and try again."
                                                         : OnePasswordAllowWire.failure(started.body),
                                     code: started.body?["code"] as? String ?? "failed")
                return
            }
            self.job = first.id
            self.show(first.job)
            await self.follow(until: { if case .waiting = $0 { false } else { true } })
        }
    }

    /// The vaults are picked: make the key and save it.
    func give() {
        guard canGive, let job, case .choose = phase else { return }
        run?.cancel()
        let body: [String: Any] = ["vaults": Array(picked), "create": makeNew]   // never `move_private`: Private is left alone
        phase = .making
        run = Task { [weak self] in
            guard let self, let call = self.call else { return }
            let sent = await call(OnePasswordAllowWire.route + "/allow/" + job, "POST", body)
            guard !Task.isCancelled else { return }
            guard sent.status == 200 else {
                self.phase = .failed(sent.status == 0 ? "Hermes didn’t answer. Check your connection and try again."
                                                      : OnePasswordAllowWire.failure(sent.body),
                                     code: sent.body?["code"] as? String ?? "failed")
                return
            }
            await self.follow(until: Self.keyed, looks: 1500)   // a full vault takes minutes to move
        }
    }

    /// Done or failed: making and moving are still on their way.
    private static func keyed(_ job: OnePasswordAllowWire.Job) -> Bool {
        switch job {
        case .making, .moving: false
        default: true
        }
    }

    /// Back to the password box after a failure.
    func again() {
        run?.cancel()
        run = nil
        phase = .signIn(nil)
    }

    func stop() {
        run?.cancel()
        run = nil
    }

    /// The page is back on screen (a sheet tucked and opened again): pick the same request up where it was.
    func resume() {
        guard run == nil else { return }
        switch phase {
        case .asking: if byPassword { phase = .signIn(nil) } else { start() }
        case .waiting:
            run = Task { [weak self] in await self?.follow(until: { if case .waiting = $0 { false } else { true } }) }
        case .making, .moving:
            run = Task { [weak self] in await self?.follow(until: Self.keyed, looks: 1500) }
        case .signIn, .choose, .done, .failed: break
        }
    }

    /// Looks at the job until it moves on (four minutes of looking; a look that gets no answer is looked again).
    private func follow(until settled: (OnePasswordAllowWire.Job) -> Bool, looks limit: Int = 200) async {
        guard let job, let call else { return }
        var looks = 0
        while looks < limit, !Task.isCancelled {
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled else { return }
            let answer = await call(OnePasswordAllowWire.route + "/allow/" + job, "GET", nil)
            guard !Task.isCancelled else { return }
            if answer.status == 404 {
                phase = .failed("Hermes restarted before this finished. Try again.", code: "gone")
                return
            }
            guard answer.status == 200, let now = OnePasswordAllowWire.job(answer.body) else { continue }
            looks += 1
            if settled(now.job) { show(now.job); return }
            if case .moving = now.job { show(now.job) }   // how far it is
        }
        if !Task.isCancelled { phase = .failed("1Password didn’t answer in time. Try again.", code: "timeout") }
    }

    private func show(_ job: OnePasswordAllowWire.Job) {
        switch job {
        case .waiting: phase = .waiting
        case .choose(let vaults, _):
            picked = OnePasswordAllowWire.firstPick(vaults, connected: Self.known.ours ? Self.known.vaults : [])
            makeNew = vaults.isEmpty
            phase = .choose(vaults)
        case .making: phase = .making
        case .moving(let moved, let total): phase = .moving(moved, total)
        case .done(let bots, let vaults):
            Self.known.connected = true
            Self.known.ours = true
            Self.known.vaults = vaults
            Self.known.bots = bots
            AppLog.note("vault", "1Password allowed for \(bots) bots, \(vaults.count) vaults")
            phase = .done(bots: bots, vaults: vaults)
        case .failed(let why, let code):
            AppLog.note("vault", "1Password allow failed: \(code)")
            // A wrong password goes back to the box, with why.
            phase = byPassword && code == "password" ? .signIn(why) : .failed(why, code: code)
        }
    }
}

struct OnePasswordAllowView: View {
    @State var model = OnePasswordAllowModel()
    /// The key is saved: the caller closes the page.
    let done: (_ bots: Int, _ vaults: [String]) -> Void
    /// Offered when 1Password couldn't be asked; nil where a master password field is already in reach.
    var useMasterPassword: (() -> Void)?
    @State private var password = ""
    @FocusState private var typing: Bool

    var body: some View {
        List { Group {
            switch model.phase {
            case .signIn(let why): signIn(why)
            case .asking: LoadingSection(text: model.byPassword ? "Signing in to 1Password…" : "Asking 1Password…")
            case .waiting: if model.byPassword { LoadingSection(text: "Signing in to 1Password…") } else { waiting }
            case .choose(let vaults): choose(vaults)
            case .making: LoadingSection(text: "Saving a key for your bots…")
            case .moving: LoadingSection(text: "Saving a key for your bots…")
            case .done(let bots, let vaults): finished(bots: bots, vaults: vaults)
            case .failed(let why, _): failed(why)
            }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .onAppear { model.resume() }
        .onDisappear { model.stop() }
        .onChange(of: model.phase) { _, phase in
            if case .done(let bots, let vaults) = phase {
                Haptics.play(.success)
                done(bots, vaults)
            } else if case .failed = phase {
                Haptics.play(.error)
            }
        }
        .accessibilityIdentifier("onepassword.allow")
    }

    /// Owner 2026-11-16: "It can't go to the computer. No one is ever on their computer." 1Password's own Allow only
    /// shows on that computer, so away from it the one-time step is the 1Password password, which 1Password on this
    /// device fills (the key above the keyboard, Face ID). 1Password's tool on Hermes's computer signs in with it,
    /// makes the bots' key, and the password is dropped. Nobody touches the computer.
    @ViewBuilder private func signIn(_ why: String?) -> some View {
        Section {
            SecureField("1Password Password", text: $password)
                .textContentType(.password)
                .focused($typing)
                .submitLabel(.continue)
                .onSubmit(sendPassword)
                .accessibilityIdentifier("onepassword.password")
            if let why {
                Text(why).font(Font.hq(.subheadline)).foregroundStyle(Color.hqRed).accessibilityIdentifier("onepassword.password-error")
            }
        } header: { HQSectionLabel {
            Text("Sign In to 1Password, Once")
        } } footer: { HQSectionFooter {
            #if targetEnvironment(macCatalyst)
            Text("Fill your 1Password password here. It’s used once on \(HostWord.phrase) to give your bots a read-only key, then dropped. After this, nothing is asked again.")
            #else
            Text("Tap the key above the keyboard to fill it from 1Password. It’s used once on \(HostWord.phrase) to give your bots a read-only key, then dropped. After this, nothing is asked again.")
            #endif
        } }
        Section {
            Button("Continue", action: sendPassword)
                .font(Font.hq(.body).weight(.semibold))
                .disabled(password.isEmpty)
                .accessibilityIdentifier("onepassword.continue")
        }
        .onAppear { typing = true }
    }

    private func sendPassword() {
        guard !password.isEmpty else { return }
        let sent = password
        password = ""
        typing = false
        model.start(password: sent)
    }

    private var waiting: some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 3) {
                    Text("Click Allow in 1Password").font(Font.hq(.body).weight(.semibold))
                    Text("1Password is asking on \(HostWord.phrase). Allow it there with a click or Touch ID.")
                        .font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("onepassword.waiting")
        } footer: { HQSectionFooter {
            Text("No master password is typed or sent. 1Password itself checks it’s you.")
        } }
    }

    @ViewBuilder private func choose(_ vaults: [OnePasswordAllowWire.Vault]) -> some View {
        Section {
            ForEach(vaults) { vault in
                let on = model.picked.contains(vault.id)
                Button {
                    Haptics.play(.selection)
                    if on { model.picked.remove(vault.id) } else { model.picked.insert(vault.id) }
                } label: {
                    row(vault.name, detail: OnePasswordAllowWire.vaultDetail(vault), on: on)
                }
                .accessibilityIdentifier("onepassword.vault.\(vault.name)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            if OnePasswordAllowWire.offersNewVault(vaults) {
                Button {
                    Haptics.play(.selection)
                    model.makeNew.toggle()
                } label: {
                    row("New “\(OnePasswordAllowWire.newVault)” Vault", detail: "Empty", on: model.makeNew)
                }
                .accessibilityIdentifier("onepassword.vault.new")
                .accessibilityAddTraits(model.makeNew ? .isSelected : [])
            }
        } header: { HQSectionLabel {
            Text("Vaults Your Bots May Fill From")
        } } footer: { HQSectionFooter {
            // Owner 2026-11-16, after a Private row that would have moved every login to a new vault: "I thought it
            // was just going to let you move one password at a time when the agent needed one. I'd prefer that." So
            // nothing here touches Private: a login that's only there is given one at a time, on the login sheet,
            // from 1Password on the phone.
            Text("Your bots get a key that only reads these vaults, and keep it: nobody is asked again. Nothing in 1Password is moved or changed. Your Private vault stays private: when a bot needs a login that’s only there, it asks, and you fill that one login from 1Password on your \(DeviceWord.name).")
        } }
        Section {
            Button("Give Access") { model.give() }
                .font(Font.hq(.body).weight(.semibold))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canGive)
                .accessibilityIdentifier("onepassword.give")
        }
    }

    private func row(_ title: String, detail: String?, on: Bool) -> some View {
        HStack(spacing: 10) {
            Text(title).foregroundStyle(Color.hqLabel).lineLimit(1)
            Spacer(minLength: 8)
            if let detail { Text(detail).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).lineLimit(1) }
            Image(systemName: "checkmark").font(Font.hq(.body).weight(.semibold)).opacity(on ? 1 : 0).accessibilityHidden(true)
        }
        .hqMacFormRowHeight()
        .contentShape(Rectangle())
    }

    private func finished(bots: Int, vaults: [String]) -> some View {
        Section {
            Label("1Password Is Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(Color.hqLabel)
        } footer: { HQSectionFooter {
            Text(OnePasswordAllowWire.doneLine(bots: bots, vaults: vaults))
        } }
    }

    @ViewBuilder private func failed(_ why: String) -> some View {
        Section {
            Text(why).foregroundStyle(Color.hqLabel).accessibilityIdentifier("onepassword.failure")
            Button("Try Again") { if model.byPassword { model.again() } else { model.start() } }.accessibilityIdentifier("onepassword.retry")
            if let useMasterPassword {
                Button("Use Master Password Instead…") { useMasterPassword() }.accessibilityIdentifier("onepassword.master")
            }
        } header: { HQSectionLabel {
            Text("1Password Wasn’t Allowed")
        } }
    }
}

extension OnePasswordAllowView {
    /// The page as a controller, for a UIKit navigation stack (the unlock sheet's).
    @MainActor static func controller(model: OnePasswordAllowModel = OnePasswordAllowModel(),
                                      done: @escaping (_ bots: Int, _ vaults: [String]) -> Void,
                                      useMasterPassword: (() -> Void)? = nil) -> UIViewController {
        let host = UIHostingController(rootView: OnePasswordAllowView(model: model, done: done, useMasterPassword: useMasterPassword))
        host.title = "Allow in 1Password"
        host.view.backgroundColor = .clear
        return host
    }
}
