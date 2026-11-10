// [talk] The seams of live voice, Read Aloud, dictation and the voice settings, joined once at launch (docs/spec/
// 3x-talk.md). Each piece exposes a hook and does not know the others; this file joins them, like `M2Wiring`.

import UIKit

@MainActor enum TalkWiring {
    private static var installed = false
    /// The newest main window's model, set every time one connects (the hooks below are joined once). Mac polish #3:
    /// kept from the first window, a window closed and opened again from the Dock lost the @ list's bots, an empty chat's
    /// role and Bot Info button, and the Voice settings shortcut.
    private(set) static weak var model: AppModel?
    /// Dictation and Voice Diagnostics give the microphone up through this (set by the features that own them).
    static var recordingPreempted: ((AudioSessionCoordinator.Owner) -> Void)?
    /// Settings › Voice, pushed on a Settings stack (set by the settings pages of this stream).
    static var voiceSettingsPage: ((AppModel, SettingsRouter) -> UIViewController?)?

    static func install(model: AppModel) {
        self.model = model
        guard !installed else { return }
        installed = true

        // Takes left by a launch that was killed mid-turn.
        TalkCaptureCore.emptyTakesFolder()

        // One microphone, one speaker (§2.3): what yields to what.
        let audio = AudioSessionCoordinator.shared
        audio.onConversationBorrowed = { _ in TalkController.shared.otherAudioStarted() }
        audio.endConversation = { await TalkController.shared.endForAnotherMicrophone() }
        audio.onSpeechPreempted = {
            TalkSpeaker.shared.stop()
            // Voice Diagnostics' playback of its test take is speech too (§9.4).
            VoiceDiagnosticsModel.current?.audioTaken(.speech)
        }
        audio.onRecordingPreempted = { owner in
            // A memo still recording when a conversation starts becomes its draft chip (§6.8).
            if owner == .memoRecording { MemoController.shared.input(.leave) }
            // A dictation is thrown away (§8).
            if owner == .dictation { DictationController.shared.cancel() }
            // Voice Diagnostics' test take ends (§9.4).
            if owner == .diagnostics { VoiceDiagnosticsModel.current?.audioTaken(.diagnostics) }
            recordingPreempted?(owner)
        }

        // "Voice Settings…" lands on Settings › Voice (§9.1).
        voiceSettingsPage = { _, router in VoiceSettingsScreens.makeSection(router: router) }

        // "Dictate with Hermes" in the voice options menu (§5.2, §8).
        TalkMenus.dictate = { screen in screen.voice.dictation.begin() }

        // Bots: the row menu's Talk tile, beside Memo (§5.5). Both are off while the gateway cannot be reached.
        BotMenuHooks.providers[.talk] = { bot, host in
            let reachable = TalkWiring.model?.connection == .ready
            var node = BotMenuNode.action("Talk", "waveform", disabled: !reachable) { [weak host] in
                guard let bots = host as? BotsViewController else { return }
                startTalking(with: bot, from: bots)
            }
            if !reachable { node.subtitle = unreachable }
            return node
        }
        if let memo = BotMenuHooks.providers[.memo] {
            BotMenuHooks.providers[.memo] = { bot, host in
                guard var node = memo(bot, host) else { return nil }
                if TalkWiring.model?.connection != .ready {
                    node.disabled = true
                    node.subtitle = unreachable
                }
                return node
            }
        }

        // A conversation that could not begin says why above the message field (§5.7).
        TalkController.shared.onStartFailure = { scope, failure, name in
            MemoController.shared.post(startNotice(failure, name: name), scope: scope)
        }
    }

    static let unreachable = "Can’t reach this bot"

    /// A bot's Talk tile: its chat opens, then the conversation starts there. A chat that never opened says so (a tile
    /// that silently did nothing would be a control that does nothing); a chat the person left starts nothing.
    static func startTalking(with bot: Bot, from bots: BotsViewController) {
        bots.open(bot.id)
        settle(on: bots.navigationController, attempts: 30, seen: false) { [weak bots] chat in
            if let chat { chat.beginTalk(); return }
            guard let bots else { return }
            showStartFailed(name: bot.name, over: bots.navigationController?.topViewController ?? bots)
        }
    }

    /// What a Talk tile says when its chat never opened.
    static func showStartFailed(name: String, over presenter: UIViewController, animated: Bool = true) {
        guard presenter.presentedViewController == nil, presenter.viewIfLoaded?.window != nil else { return }
        let alert = UIAlertController(title: "Couldn’t Start Talking", message: "\(name)’s chat didn’t open.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        alert.view.accessibilityIdentifier = "talk.start-failed"
        presenter.present(alert, animated: animated)
    }

    /// Hands over the chat at the top of `navigation` once its push has finished (100 ms × `attempts`); nil when no
    /// chat ever came up. Nothing is called when a chat came up and the person left it.
    static func settle(on navigation: UINavigationController?, attempts: Int, seen: Bool, _ done: @escaping (ChatViewController?) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let navigation else { return }
            let chat = navigation.paneChat
            if let chat, chat.view.window != nil, navigation.transitionCoordinator == nil {
                done(chat)
            } else if attempts > 0 {
                settle(on: navigation, attempts: attempts - 1, seen: seen || chat != nil, done)
            } else if chat != nil {
                done(chat)
            } else if !seen {
                done(nil)
            }
        }
    }

    /// The signed-in root came on screen: the away pill is hosted on it (§6.6).
    static func rootShown(_ root: MainTabController) {
        TalkAwayPill.attach(to: root)
        TalkAwayPill.current?.onOpen = { [weak root] in
            guard let root, let target = TalkController.shared.pillTarget else { return }
            openChat(target, root: root)
        }
    }

    /// Leads back to the chat a conversation or a notice lives in. The chat object is still held (`AppModel` keeps a
    /// chat with a live conversation), so the same conversation shows its dock again.
    static func openChat(_ target: TalkController.PillTarget, root: MainTabController) {
        if let live = target.chat as? LiveChatSession, live.menus.isBotChat {
            if let top = root.chatOnShow,
               (top.session as? LiveChatSession) === live { return }
            root.presentedViewController?.dismiss(animated: false)
            root.select(.bots)
            root.botsViewController.navigationController?.popToRootViewController(animated: false)
            root.botsViewController.open(live.profile)
            return
        }
        guard let stored = target.storedSessionId else { return }
        NotificationHub.shared.open(stored, profile: target.profile.isEmpty ? nil : target.profile)
    }

    /// Sign-out or a gateway switch: nothing of voice outlives its account.
    static func accountGone() {
        TalkController.shared.accountGone()
        TalkSpeaker.shared.stop()
        VoiceGateway.forgetConfig()
    }

    /// §5.7's table.
    static func startNotice(_ failure: TalkController.StartFailure, name: String, app: String = MemoNotice.appName) -> MemoNotice {
        switch failure {
        case .microphoneDenied:
            // [mac] Mac polish #11: the Mac's microphone switch is in System Settings, not Hermes HQ's own Settings.
            MemoNotice(tone: .warning, title: "Microphone Access Is Off",
                       message: "Turn on Microphone for \(app) in \(DeviceWord.isMac ? DeviceWord.settingsApp : "Settings") to talk with \(name).",
                       action: .openSettings)
        case .speechToTextOff:
            MemoNotice(tone: .warning, title: "Voice Unavailable",
                       message: "Speech to Text is off on your gateway. Turn it on in Settings › Voice › Speech to Text, then try again.",
                       action: .voiceSettings)
        case .engine(let detail):
            MemoNotice(tone: .error, title: "Voice Didn’t Start", message: "Couldn’t start microphone recording.", detail: detail, action: .retryTalk)
        case .noMicrophone:
            MemoNotice(tone: .error, title: "Voice Didn’t Start", message: "No microphone was found.")
        case .notOnScreen:
            // [talk-background] Only the start needs the app on screen; the conversation then goes on with it away.
            MemoNotice(tone: .info, title: "Voice Didn’t Start",
                       message: "Talk starts while \(app) is on screen, then keeps going when you leave. \(DeviceWord.Tap) Talk to start again.")
        }
    }
}
