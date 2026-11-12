import SwiftUI
import UIKit

// [screen] Bot Screen's hooks into the app (docs/spec/3x-screen.md §5.1, §5.13, §6.1): the Bots row menu's Screen
// entry, the Bot Info tile and Computer row, opening the viewer, and "Set up with Hermes".

/// The stream's public seam for other streams (presence's Computer group and Watch notices, groups' room menu).
@MainActor enum ScreenHooks {
    /// What a bot's Screen entry opens: the live Screen, the latest screenshots, or not known yet.
    static var kind: (Bot) -> ScreenKind = { _ in .unknown }
    /// The bot's screen is running and the bot itself is in control.
    static var isLive: (Bot) -> Bool = { _ in false }
    static var open: (Bot, UIViewController) -> Void = { _, _ in }
    /// The account's screenshot-expiry checker (the step sheet asks it).
    static var expiry: () -> ScreenshotExpiry? = { nil }
    /// This stream shows the Computer group by itself until presence's group is in: presence turns this off and calls
    /// `row` as its group's first row, so there is never a second "Computer" group.
    static var ownsComputerGroup = true

    /// The Computer group's Screen row: opens the Screen over Bot Info.
    static func row(_ bot: Bot, host: UIViewController) -> AnyView {
        AnyView(ScreenInfoRow(bot: bot, host: host))
    }
}

private struct ScreenInfoRow: View {
    let bot: Bot
    weak var host: UIViewController?
    /// Bot Info stays open under the Screen (#94): when the Screen closes, the row shows what it learned (Live).
    @State private var seen = 0

    var body: some View {
        let _ = seen
        let kind = ScreenHooks.kind(bot)
        Button {
            // Over Bot Info, as Watch Browser opens: closing the Screen comes back to the bot's page (UX study #94).
            if let host { ScreenHooks.open(bot, host) }
        } label: {
            HStack(spacing: 8) {
                // An icon, a title and a line under it, as Watch Browser below (UX study #5).
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.menuTitle).foregroundStyle(Color.hqLabel)
                        Text(Self.subtitle(kind)).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                    }
                } icon: {
                    Image(systemName: kind.symbol).foregroundStyle(Color.hqLabel)
                }
                Spacer(minLength: 8)
                if ScreenHooks.isLive(bot) { Text("Live").foregroundStyle(Color.hqLabel2) }
                SettingsChevron()
            }
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("bot-info.screen")
        .onReceive(NotificationCenter.default.publisher(for: ScreenService.knownChanged)) { _ in seen &+= 1 }
    }

    /// The line under the title: what the row shows.
    static func subtitle(_ kind: ScreenKind) -> String {
        kind == .screenshots ? "See what was on its screen last" : "See its desktop live"
    }
}

/// Which bots had setup requested in this run, and the request in flight per bot (a second tap joins the first).
@MainActor enum ScreenSetupLedger {
    static var submitted: Set<String> = []
    static var inFlight: [String: Task<ScreenSetupError?, Never>] = [:]
    static func key(_ accountId: String, _ profile: String) -> String { "\(accountId)|\(profile)" }
}

extension AppModel {
    func openScreen(_ bot: Bot, from presenter: UIViewController) {
        openScreen(profile: bot.id, name: bot.name, from: presenter)
    }

    /// The one entry to a bot's Screen (other streams: presence's Watch notices, groups' "View <name>'s Screen").
    func openScreen(profile: String, name: String, from presenter: UIViewController) {
        guard let screen else { return }
        // [ship, m9] The bot's "is using its screen" notice has nothing left to offer once its Screen is up.
        PresenceNotice.shared.dismiss(about: profile)
        let key = ScreenSetupLedger.key(screen.accountId, profile)
        ScreenViewerController.present(profile: profile, name: name, service: screen, from: presenter) { viewer in
            viewer.requestSetup = { [weak self] resume in
                guard let self else { return .notConnected }
                return await self.requestScreenSetup(profile: profile, resume: resume)
            }
            viewer.setupRequested = { ScreenSetupLedger.submitted.contains(key) || ScreenSetupLedger.inFlight[key] != nil }
            let base = screen.client.account.baseURL
            if CloudGatewayFlow.isCloud(base) {
                viewer.openCloudAgent = { [weak self, weak viewer] in
                    guard let self, let viewer else { return }
                    CloudGatewayFlow.present(from: viewer, services: self, agent: base)
                }
            }
            viewer.ownsSession = { [weak self] runtime in
                guard let self, !runtime.isEmpty else { return false }
                return self.screenOwnsSession(runtime, profile: profile)
            }
        }
    }

    private static var screenInfoInstalled = false

    /// Bots › a bot's menu › Watch Screen / View Screen / Latest Screenshots, Bot Info's Screen tile and Computer row.
    func registerScreenMenu() {
        ScreenHooks.kind = { [weak self] bot in self?.screen?.kind(for: bot.id) ?? .unknown }
        ScreenHooks.isLive = { [weak self] bot in self?.screen?.tone(for: bot.id) == .live }
        ScreenHooks.open = { [weak self] bot, host in self?.openScreen(bot, from: host) }
        ScreenHooks.expiry = { [weak self] in self?.screen?.expiry }
        if !Self.screenInfoInstalled {
            Self.screenInfoInstalled = true
            BotInfoHooks.sections.append { [weak self] bot, host in
                guard ScreenHooks.ownsComputerGroup, self?.screen != nil else { return nil }
                return AnyView(Section { ScreenHooks.row(bot, host: host) } header: { HQSectionLabel { Text("Computer") } })
            }
        }
        BotMenuHooks.providers[.screen] = { [weak self] bot, host in
            guard let screen = self?.screen else { return nil }
            // Read when the menu is built: the label cannot change under the finger. No request is made here.
            let kind = screen.kind(for: bot.id)
            return .action(kind.menuTitle, kind.symbol) { [weak self, weak host] in
                guard let self, let host else { return }
                self.openScreen(bot, from: host)
            }
        }
        joinComputerHooks()
    }

    /// [ship, m9] The join between this stream and presence (neither branch could name the other's types): Bot Info has
    /// ONE Computer group, presence's, with the Screen row first; the "is using its screen" notice's Watch opens the
    /// real Screen; and no notice shows while a Screen is up. UI tests that need presence's stand-in opener (an alert
    /// they can leave on screen) pass `-HQDebugScreenRow YES`, and then the stand-in is left in place.
    private func joinComputerHooks() {
        ScreenHooks.ownsComputerGroup = false
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HQDebugScreenRow") { return }
        #endif
        BotComputerHooks.screenRow = { bot, host in ScreenHooks.row(bot, host: host) }
        BotComputerHooks.openScreen = { bot, host in ScreenHooks.open(bot, host) }
        BotComputerHooks.screenIsOpen = { ScreenViewerController.current != nil }
    }

    // MARK: Set up with Hermes (§5.13)

    /// One request at a time per bot. Returns a failure only when it happened before the Screen closed; later ones
    /// show as an alert on the chat.
    func requestScreenSetup(profile: String, resume: Bool) async -> ScreenSetupError? {
        guard let account, client != nil else { return .notConnected }
        let key = ScreenSetupLedger.key(account.id, profile)
        if let pending = ScreenSetupLedger.inFlight[key] { return await pending.value }
        let task = Task { [weak self] () -> ScreenSetupError? in
            guard let self else { return .notConnected }
            return await self.runScreenSetup(profile: profile, key: key, resume: resume)
        }
        ScreenSetupLedger.inFlight[key] = task
        let result = await task.value
        ScreenSetupLedger.inFlight[key] = nil
        return result
    }

    private func runScreenSetup(profile: String, key: String, resume: Bool) async -> ScreenSetupError? {
        guard let root = MainTabController.current, client != nil else { return .notConnected }
        // The Screen (and Bot Info under it, when it opened from there) covers the chat:
        // everything above the tabs closes first, then the bot's own chat opens.
        if root.presentedViewController != nil {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                root.dismiss(animated: true) { done.resume() }
            }
        }
        root.select(.bots)
        let bots = root.botsViewController
        func botChat() -> (ChatViewController, LiveChatSession)? {
            guard let chat = bots.navigationController?.paneChat, chat.view.window != nil,
                  let live = chat.session as? LiveChatSession, live.profile == profile, live.isBotChat else { return nil }
            return (chat, live)
        }
        if botChat() == nil {
            bots.navigationController?.popToRootViewController(animated: false)
            bots.open(profile)
        }
        var found = botChat()
        for _ in 0..<80 where found == nil {
            try? await Task.sleep(for: .milliseconds(50))
            found = botChat()
        }
        guard let (chat, live) = found else {
            Self.screenSetupFailed(.chatDidNotOpen, on: bots)
            return nil
        }
        // Already there: a queued request, or one made this run that is not being continued.
        if live.hasQueuedScreenSetup || (ScreenSetupLedger.submitted.contains(key) && !resume) {
            ScreenSetupLedger.submitted.insert(key)
            return nil
        }
        let hud = MenusHUD.show(ScreenSetupCopy.opening, symbol: nil, in: chat.view, seconds: nil)
        defer { hud?.removeFromSuperview() }
        do {
            let bundle = try await ScreenSetupBundle.load()
            let attached = try await live.attachScreenSetup(name: bundle.filename, dataURL: bundle.dataURL)
            guard let now = botChat(), now.1 === live, live.runtimeSessionId == attached.runtime else { throw ScreenSetupError.changedBeforeStart }
            try live.sendScreenSetup(refText: attached.refText, bundle: bundle)
            ScreenSetupLedger.submitted.insert(key)
            AppLog.note("screen", "setup requested")
        } catch let failure as ScreenSetupError {
            hud?.removeFromSuperview()
            Self.screenSetupFailed(failure, on: chat)
        } catch {
            hud?.removeFromSuperview()
            Self.screenSetupFailed(.installer(nil), on: chat)
        }
        return nil
    }

    private static func screenSetupFailed(_ failure: ScreenSetupError, on host: UIViewController) {
        AppLog.note("screen", "setup failed")
        Haptics.play(.error)   // as `FailureAlert`
        let alert = UIAlertController(title: ScreenSetupError.alertTitle, message: ScreenWire.plain(failure.message), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        var top = host
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        top.present(alert, animated: true)
    }
}
