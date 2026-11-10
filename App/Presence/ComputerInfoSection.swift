// [presence] Bot Info › Computer (docs/spec/3x-presence.md §6, §7; R:src/ui-bots/info-state.ts:98-102): the Screen row
// (drawn by the screen stream through `BotComputerHooks.screenRow`), Watch Browser, the browser's Profile and Window
// page when the plugin offers it, and the switch "Alert When It Uses Its Computer" (the one control for the per-bot
// notice, stored as `screenAutoOpen` in the bot's ui_meta). Replaces the old "Browser" group.

import SwiftUI
import UIKit

struct ComputerInfoSection: View {
    let bot: Bot
    let service: BrowserService
    weak var host: UIViewController?
    /// The gateway link is ready (`AppModel.connection == .ready`).
    let online: () -> Bool
    /// `BotStore.screenNoticeOn(bot.id)`.
    let alertOn: () -> Bool
    /// `BotStore.setScreenNotice(name:_:)`.
    let setAlert: (Bool) async throws -> Void
    let open: (BrowserScope, UIViewController) -> Void

    @State private var offersChoice = false
    @State private var summary: String?
    @State private var isOnline: Bool
    @State private var alert: Bool
    @State private var pendingWrites = 0
    @Environment(\.dynamicTypeSize) private var typeSize

    init(bot: Bot, service: BrowserService, host: UIViewController?, online: @escaping () -> Bool, alertOn: @escaping () -> Bool,
         setAlert: @escaping (Bool) async throws -> Void, open: @escaping (BrowserScope, UIViewController) -> Void) {
        self.bot = bot
        self.service = service
        self.host = host
        self.online = online
        self.alertOn = alertOn
        self.setAlert = setAlert
        self.open = open
        _isOnline = State(initialValue: online())
        _alert = State(initialValue: alertOn())
    }

    var body: some View {
        Section {
            // The Screen row is the screen stream's: nothing is drawn until it sets the hook.
            if let host, let row = BotComputerHooks.screenRow?(bot, host) { row }
            Button {
                if let host { open(BrowserScope(profile: bot.id, title: bot.name), host) }
            } label: {
                HStack {
                    // An icon, a title and a line under it, as the Screen row above (UX study #5).
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Watch Browser").foregroundStyle(Color.hqLabel)
                            Text("See its browser live, or take it over").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                        }
                    } icon: {
                        Image(systemName: "safari").foregroundStyle(Color.hqLabel)
                    }
                    Spacer(minLength: 8)
                    chevron
                }
                .padding(.vertical, 4)
            }
            .accessibilityIdentifier("bot-info.browser.watch")
            .disabled(!isOnline)
            .opacity(isOnline ? 1 : 0.5)
            if let host, let row = BotComputerHooks.terminalRow?(bot, host) {   // [terminal]
                row.disabled(!isOnline).opacity(isOnline ? 1 : 0.5)
            }
            if offersChoice {
                Button {
                    host?.navigationController?.pushViewController(BrowserChoiceController(service: service, bot: bot), animated: true)
                } label: {
                    HStack {
                        if typeSize.isAccessibilitySize {
                            // Very large text: the value goes under the title instead of squeezing it into a column.
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Profile and Window").foregroundStyle(Color.hqLabel)
                                if let summary { Text(summary).foregroundStyle(Color.hqLabel2) }
                            }
                            Spacer(minLength: 8)
                        } else {
                            Text("Profile and Window").foregroundStyle(Color.hqLabel)
                            Spacer(minLength: 8)
                            if let summary { Text(summary).foregroundStyle(Color.hqLabel2) }
                        }
                        chevron
                    }
                }
                .accessibilityIdentifier("bot-info.browser.choice")
            }
            Toggle(isOn: Binding(get: { alert }, set: { flip($0) })) {
                Text("Alert When It Uses Its Computer").foregroundStyle(Color.hqLabel)
            }
            .accessibilityIdentifier("bot-info.computer.alert")
            .disabled(!isOnline)
            .opacity(isOnline ? 1 : 0.5)
        } header: { HQSectionLabel { Text("Computer") } }
        .task {
            guard let choice = try? await service.choice(profile: bot.id) else { return }
            offersChoice = true
            summary = BrowserChoiceModel.summary(choice)
        }
        .task {
            // Bot Info's own cadence (its timer ticks once a second): the link's state, and the flag as the roster has it
            // (a change made on another device shows without reopening the sheet).
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var chevron: some View {
        SettingsChevron()
    }

    private func refresh() {
        let now = online()
        if now != isOnline { isOnline = now }
        guard pendingWrites == 0 else { return }
        let stored = alertOn()
        if stored != alert { alert = stored }
    }

    /// The switch was flipped: it shows where it was put at once; a refused write puts it back and says why.
    private func flip(_ on: Bool) {
        guard on != alert, isOnline else { return }
        Haptics.play(.selection)
        alert = on
        pendingWrites += 1
        let host = host
        Task {
            do {
                try await setAlert(on)
                pendingWrites -= 1
                if pendingWrites == 0 { alert = alertOn() }
            } catch {
                pendingWrites -= 1
                if pendingWrites == 0 { alert = alertOn() }
                // Gone with its sheet (or its account): nothing to say it over.
                guard let host, host.viewIfLoaded?.window != nil else { return }
                let said: Error = (error as? BotWriteError).map(NoticeWriteWords.plain) ?? error
                FailureAlert.present(said, fallbackTitle: "Couldn’t Change the Alert", from: host) { flip(on) }
            }
        }
    }
}
