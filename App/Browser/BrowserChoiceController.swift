import SwiftUI
import UIKit

// Bot Info › Browser (docs/browser-choice-decision.md): Watch Browser, and — when the computer's browser plugin offers
// it (hermes-hq-browser 3.6+) — the bot's browser profile (its own, or a copy of one of the person's Chrome profiles,
// with "Refresh Sign-ins from My Chrome") and "Show as Normal Chrome". An older plugin hides the choice.
// A bot whose browser the plugin doesn't run (Hermes's own "use real Chrome profile", a removed cdp_url, a Chrome the
// person runs…) says why at the top; where the plugin can take it over safely (3.6.2+), "Let Hermes HQ Run <Bot>'s
// Browser" does, after a plain-words confirm.

@MainActor @Observable final class BrowserChoiceModel {
    let service: BrowserService
    let bot: Bot
    var choice: BrowserChoice?
    var profiles: ChromeProfiles?
    var loading = true
    var working: String?
    var failure: String?
    /// Reading the bot's browser failed (offline, a timeout): the page says so with Try Again, no alert.
    var loadFailure: String?
    var confirming: ChromeProfile?
    var confirmingTakeOver = false
    /// "Show as Normal Chrome" while the bot is using its browser: the restart closes its page, so it asks first.
    var confirmingWindow: Bool?

    init(service: BrowserService, bot: Bot) {
        self.service = service
        self.bot = bot
    }

    func load() async {
        loading = true
        loadFailure = nil
        defer { loading = false }
        do {
            choice = try await service.choice(profile: bot.id)
            if choice != nil { profiles = try await service.chromeProfiles() }
        } catch {
            AppLog.swallowed("browser", "read this bot's browser choice", error)
            loadFailure = (error as? LocalizedError)?.errorDescription ?? "Couldn’t read this bot’s browser. Try again."
        }
    }

    /// The window toggle: restarting a browser the bot is using asks first.
    func setWindow(normal: Bool) {
        if service.activity.rows.contains(where: { $0.profile == bot.id && $0.inUse }) {
            confirmingWindow = normal
        } else {
            apply(.window(normal: normal))
        }
    }

    func apply(_ change: BrowserChoice.Change) {
        guard working == nil else { return }
        working = switch change {
        case .copy: "Copying your Chrome profile…"
        case .refresh: "Copying your sign-ins again…"
        case .own: "Switching back to its own profile…"
        case .window: "Restarting \(bot.name)’s browser…"
        case .takeOver: "Setting up \(bot.name)’s browser…"
        }
        Task {
            defer { working = nil }
            do {
                choice = try await service.setChoice(profile: bot.id, change: change)
                AppLog.note("browser", Self.outcome(change, status: nil))
                Haptics.play(.success)
                if change == .takeOver { await settle() }
            } catch let error as HTTPError {
                AppLog.note("browser", Self.outcome(change, status: error.status))
                failure = Self.detail(error.body) ?? "\(HostWord.sentence) didn’t make that change. Try again."
                Haptics.play(.warning)
            } catch {
                AppLog.note("browser", Self.outcome(change, status: 0))
                failure = (error as? LocalizedError)?.errorDescription ?? "\(HostWord.sentence) didn’t make that change. Try again."
                Haptics.play(.warning)
            }
        }
    }

    /// After a take-over: the profiles list (it may not have loaded for a blocked bot), then a few looks while the
    /// computer is still starting the bot's Chrome (the plugin waits up to 25 s itself).
    private func settle() async {
        if profiles == nil { profiles = try? await service.chromeProfiles() }
        for _ in 0..<10 where choice?.blocked == "starting" {
            try? await Task.sleep(for: .seconds(3))
            if let fresh = try? await service.choice(profile: bot.id) { choice = fresh }
        }
    }

    /// The diagnostic line for a change: its kind and how it went (HTTP status on failure; 0 when there was none).
    /// Never names, paths, accounts, addresses or message text.
    static func outcome(_ change: BrowserChoice.Change, status: Int?) -> String {
        let kind = switch change {
        case .own: "own"
        case .copy: "copy"
        case .refresh: "refresh"
        case .window(let normal): normal ? "normal window" : "hidden window"
        case .takeOver: "take over"
        }
        guard let status else { return "choice \(kind): ok" }
        return status > 0 ? "choice \(kind): failed (HTTP \(status))" : "choice \(kind): failed"
    }

    /// Why the page can't change this bot's browser, in plain words; nil when it can.
    static func explanation(_ choice: BrowserChoice, name: String) -> String? {
        guard !choice.changeable else { return nil }
        return switch choice.blocked {
        case "real_profile": "\(name) is set to use your real Chrome profile through Hermes’s own setting, so Hermes HQ doesn’t run its browser."
        case "released": "\(name)’s browser was turned off in its Hermes settings."
        case "external", "fixed": "\(name) is connected to a Chrome you started yourself, so Hermes HQ doesn’t run its browser."
        case "remote": "\(name) uses a browser on another computer, so Hermes HQ leaves it alone."
        case "camofox": "\(name) browses through Camofox, so Hermes HQ leaves it alone."
        case "off": "Hermes HQ’s browser add\u{2011}on is switched off for \(name), so its browser can’t be changed here."
        case "no_browser": "\(name) doesn’t use a browser. Its browser tools are turned off in Hermes."
        case "starting": "Hermes HQ is still starting \(name)’s browser. This takes a moment."
        default: "Hermes HQ doesn’t run \(name)’s browser, so its profile and window can’t be changed here."
        }
    }

    /// Bot Info's one-word summary beside "Profile and Window".
    static func summary(_ choice: BrowserChoice) -> String {
        if choice.changeable { return choice.copy.map { "Copy of \($0.name)" } ?? "Its Own" }
        return switch choice.blocked {
        case "real_profile": "Real Chrome"
        case "released", "off": "Off"
        case "no_browser": "No Browser"
        case "external", "fixed": "Your Chrome"
        case "remote": "Another Computer"
        case "camofox": "Camofox"
        case "starting": "Starting"
        default: "Not Set Up"
        }
    }

    /// The take-over button's title, when the plugin offers it.
    static func takeOverTitle(_ choice: BrowserChoice, name: String) -> String? {
        choice.canTakeOver && !choice.changeable ? "Let Hermes HQ Run \(name)’s Browser" : nil
    }

    /// What taking over changes, for the confirm alert.
    static func takeOverMessage(_ choice: BrowserChoice, name: String) -> String {
        let change = switch choice.blocked {
        case "real_profile": "its “use real Chrome profile” setting in Hermes is turned off"
        case "released": "its browser setting in Hermes is turned back on"
        default: "it stops using the Chrome you started yourself"
        }
        return "Hermes HQ will run a Chrome just for \(name) on \(HostWord.phrase), and \(change). Then you can give it a copy of "
            + "your Chrome profile and watch it here. You can switch back in Hermes’s settings at any time."
    }

    /// FastAPI's `{"detail": "…"}`, the plugin's plain-words reason.
    static func detail(_ body: String?) -> String? {
        guard let body, let value = try? JSONValue.parse(Data(body.utf8)), let detail = value["detail"]?.string, !detail.isEmpty else { return nil }
        return String(detail.prefix(200))
    }

    static func unsupported(_ reason: String?, program: String? = nil) -> String {
        switch reason {
        case "no_chrome": "Google Chrome isn’t installed on \(HostWord.phrase)."
        case "no_access":
            "Your Mac is blocking Hermes from reading Chrome’s profiles. On the Mac, open System Settings › Privacy & Security › "
                + "Full Disk Access, click +, press Command-Shift-G and add "
                + (program.map { "“\($0)”" } ?? "Hermes’s Python") + ", then quit and reopen Hermes."
        default: "No Chrome profiles were found on \(HostWord.phrase). Open Chrome there once, then come back."
        }
    }
}

struct BrowserChoiceView: View {
    @Bindable var model: BrowserChoiceModel

    var body: some View {
        List {
            if model.loading && model.choice == nil {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            } else if model.choice == nil, let reason = model.loadFailure {
                Section {
                    ContentUnavailableView {
                        UnavailableTitle("Couldn’t Load \(model.bot.name)’s Browser", systemImage: "exclamationmark.triangle")   // [mac] Stress test 2026-10-28 #52
                    } description: {
                        Text(reason).hqMacFont(MacType.emptyBodyFont)
                    } actions: {
                        Button("Try Again") { Task { await model.load() } }
                            .hqProminentButtonStyle()
                            .buttonBorderShape(.capsule)
                            .accessibilityIdentifier("browser.choice.retry")
                    }
                }
            } else if let choice = model.choice {
                if let explanation = BrowserChoiceModel.explanation(choice, name: model.bot.name) {
                    blockedSection(choice, explanation: explanation)
                }
                profileSection(choice)
                windowSection(choice)
            } else {
                Section {
                    Text("The browser add\u{2011}on on \(HostWord.phrase) doesn’t offer this yet. Once it’s updated you can choose a browser profile for each bot here.")
                        .foregroundStyle(Color.hqLabel2)
                }
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
        .disabled(model.working != nil)
        .overlay(alignment: .bottom) {
            if let working = model.working {
                HStack(spacing: 10) { ProgressView(); Text(working).font(Font.hq(.subheadline)) }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .hqGlassEffect(in: .capsule)
                    .padding(.bottom, 24)
                    .accessibilityIdentifier("browser.choice.working")
            }
        }
        .alert("Couldn’t Change the Browser", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.failure ?? "") }
        .alert(model.confirming.map { "Use a copy of “\($0.name)”?" } ?? "",
               isPresented: Binding(get: { model.confirming != nil }, set: { if !$0 { model.confirming = nil } }),
               presenting: model.confirming) { profile in
            Button("Use a Copy") { model.apply(.copy(profile.dir)) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("\(model.bot.name) will be signed in as you on the sites this profile is signed in to. Your saved passwords, cards and extensions aren’t copied, and your own Chrome isn’t opened or changed.")
        }
        .alert("Restart \(model.bot.name)’s Browser?",
               isPresented: Binding(get: { model.confirmingWindow != nil }, set: { if !$0 { model.confirmingWindow = nil } }),
               presenting: model.confirmingWindow) { normal in
            Button("Restart") { model.apply(.window(normal: normal)) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("\(model.bot.name) is using its browser now. Restarting it closes the page it’s on.")
        }
        .alert("Let Hermes HQ Run \(model.bot.name)’s Browser?", isPresented: $model.confirmingTakeOver,
               presenting: model.choice) { _ in
            Button("Let Hermes HQ Run It") { model.apply(.takeOver) }
            Button("Cancel", role: .cancel) {}
        } message: { choice in
            Text(BrowserChoiceModel.takeOverMessage(choice, name: model.bot.name))
        }
        .task { await model.load() }
    }

    @ViewBuilder private func blockedSection(_ choice: BrowserChoice, explanation: String) -> some View {
        Section {
            Label {
                Text(explanation).padding(.vertical, 4)
            } icon: {
                Image(systemName: choice.blocked == "starting" ? "hourglass" : "info.circle").foregroundStyle(Color.hqLabel2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("browser.choice.blocked")
            if let title = BrowserChoiceModel.takeOverTitle(choice, name: model.bot.name) {
                Button(title) { model.confirmingTakeOver = true }
                    .accessibilityIdentifier("browser.choice.takeOver")
            }
        }
    }

    @ViewBuilder private func profileSection(_ choice: BrowserChoice) -> some View {
        Section {
            row(title: "Its Own Profile", subtitle: "Signed in only where \(model.bot.name) signed in", selected: choice.copy == nil,
                enabled: choice.changeable, id: "browser.choice.own") { if choice.copy != nil { model.apply(.own) } }
            if let profiles = model.profiles, profiles.supported {
                ForEach(profiles.profiles) { profile in
                    row(title: "Copy of \(profile.name)", subtitle: profile.account, selected: choice.copy?.dir == profile.dir,
                        enabled: choice.changeable, id: "browser.choice.profile.\(profile.dir)") {
                        if choice.copy?.dir != profile.dir { model.confirming = profile }
                    }
                }
            }
            if choice.copy != nil {
                Button("Refresh Sign-ins from My Chrome") { model.apply(.refresh) }
                    .accessibilityIdentifier("browser.choice.refresh")
            }
        } header: { HQSectionLabel {
            Text("Profile")
        } } footer: { HQSectionFooter {
            if let profiles = model.profiles, !profiles.supported {
                Text(BrowserChoiceModel.unsupported(profiles.reason, program: profiles.program))
                    .textSelection(.enabled)
            } else if let copy = choice.copy {
                Text("\(model.bot.name) browses with a copy of your “\(copy.name)” profile\(choice.copiedAt.map { ", copied \($0.formatted(.relative(presentation: .named)))" } ?? ""). Sign-ins you add in Chrome on \(HostWord.phrase) later reach it when you refresh. Saved passwords, cards, extensions, passkeys and Chrome Sync don’t come along.")
            } else {
                Text("A copy of one of your Chrome profiles opens sites already signed in, as you. Your own Chrome is never opened or changed.")
            }
        } }
        .disabled(!choice.changeable)
    }

    @ViewBuilder private func windowSection(_ choice: BrowserChoice) -> some View {
        Section {
            Toggle("Show as Normal Chrome", isOn: Binding(get: { choice.normalWindow }, set: { model.setWindow(normal: $0) }))
                .accessibilityIdentifier("browser.choice.window")
        } footer: { HQSectionFooter {
            Text("Fewer “are you human?” checks: \(model.bot.name)’s Chrome runs as a regular Chrome window on \(HostWord.phrase) instead of a hidden one (it may come to the front once as it starts). You can still watch and take it over here.")
        } }
        .disabled(!choice.changeable)
    }

    /// `enabled` false greys the title (an explicit primary colour wouldn't dim with the section's `.disabled`).
    private func row(title: String, subtitle: String?, selected: Bool, enabled: Bool, id: String,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(enabled ? Color.hqLabel : Color.hqLabel2)
                    if let subtitle, !subtitle.isEmpty { Text(subtitle).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2) }
                }
                .padding(.vertical, 4)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold) }
            }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

final class BrowserChoiceController: UIHostingController<HQScaledRoot<BrowserChoiceView>> {
    init(service: BrowserService, bot: Bot) {
        super.init(rootView: HQScaledRoot(BrowserChoiceView(model: BrowserChoiceModel(service: service, bot: bot))))
        title = "Browser"
        navigationItem.largeTitleDisplayMode = .never
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
