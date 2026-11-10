// Every sentence this feature can show (docs/spec/3x-intents.md §5–§10), in the web app's words
// (W:src/action-voice-runtime.ts, W:src/ui-voice/shortcuts.ts, W:ios/App/App/VoiceNoteIntent.swift,
// W:ios/App/App/HermesUIPages.swift). `<App>` is this build's name (AppIdentity): "Hermes HQ" in the shipping identity.

import Foundation

nonisolated enum IntentsText {
    static var app: String { AppIdentity.current.displayName }

    // MARK: The intents' own errors (§5.3, §6)

    static func refreshBots(app: String = IntentsText.app) -> String {
        "Open \(app) to refresh your bots, then choose a bot in this shortcut."
    }
    static func legacyUnavailable(app: String = IntentsText.app) -> String {
        "Open \(app) and choose the bot again. This shortcut is no longer available."
    }

    // MARK: A voice memo that could not start (§7.4)

    static let voiceNoteTitle = "Couldn’t Start the Voice Memo"
    static let ok = "OK"
    static let otherAccount = "This shortcut belongs to another account or to another computer running Hermes. Choose your bot again in Shortcuts."
    static func botUnavailable(_ bot: String) -> String { "“\(bot)” is unavailable. Reconnect to \(HostWord.phrase) and try again." }
    static let botChatDidNotOpen = "Couldn’t open the selected bot’s chat. Reconnect and try again."
    static let botChatChanged = "The selected bot’s chat changed before recording could start."
    static let finishCurrent = "Finish the current voice memo before starting another."
    static let canceledRunAgain = "Recording was canceled because the selected chat is no longer active. Run the shortcut again."
    static let canceled = "Recording was canceled because the selected chat is no longer active."
    static let fieldNotReady = "The message field isn’t ready, so the voice memo didn’t start. Wait for the chat to connect, then try again."
    static let couldNotStart = "The voice memo could not start. Run the shortcut again."

    // MARK: The saved older-build note (§8)

    static let savedNoteTitle = "Saved Voice Memo"      // UX study #147: title case, as every other alert title
    static func savedNoteWaiting(_ bot: String) -> String { "Your memo for \(bot) is waiting to be added to its chat." }
    static let openChat = "Open Chat"
    static let discardAndRecord = "Discard and Record"
    static let cancel = "Cancel"
    static let recoverRecording = "Recover Recording"
    static let discardRecording = "Discard Recording"
    static let noteOtherAccount = "A saved voice memo belongs to another account or to another computer running Hermes. Sign back in to recover it."
    static let noteStillSaved = "Your earlier recording is saved. Open its bot chat and \(DeviceWord.tap) Recover Recording to attach it."
    static let noteNotSaved = "Your earlier recording could not be saved to the draft. \(DeviceWord.Tap) Recover Recording to retry."

    // MARK: Home Screen quick actions (§9)

    static func newMemo(_ bot: String) -> String { "New Voice Memo for " + bot }
    static func open(_ name: String) -> String { "Open " + name }
    static let searchChats = "Search Chats"
    static let untitledChat = "Chat"
    static let shortcutTitle = "Shortcut Unavailable"
    static let shortcutUnknownTitle = "That shortcut is unavailable."
    static func openAppFirst(app: String = IntentsText.app) -> String { "Open \(app) to use this shortcut." }
    /// UX study #264: signed in, but the tabs never came up (offline, or a launch that stalled): not "open the app",
    /// which is already open. The shortcut is held and runs if they come up within 10 s more (`IntentsRuntime.replayCap`).
    static func notReady(app: String = IntentsText.app) -> String {
        "\(app) isn’t connected to \(HostWord.phrase) yet. This shortcut runs if it connects in the next few seconds; if not, try again once it’s connected."
    }
    static let previousSignIn = "This shortcut belongs to a previous sign-in."
    static func chatGone(app: String = IntentsText.app) -> String { "That chat is no longer available. Open \(app) and choose it again." }
    static let memoNeedsBot = "Voice memos need a bot chat."
    static let botNotOnRoster = "That bot is unavailable. Open its chat and try again."
    /// One sentence for a bot's chat and a listed chat alike (UX study #147: two near-identical ones before).
    static let chatDidNotOpen = "That chat didn’t open."
    /// The app's word for rooms is group chat (UX study #147).
    static let roomGone = "That group chat is no longer available."
    static func busy(app: String = IntentsText.app) -> String { "\(app) was busy. Try again." }

    /// Every sentence above, with stand-in names (a test checks the wording rules against this table).
    static func table(app: String = IntentsText.app, bot: String = "Ivy") -> [String] {
        [refreshBots(app: app), legacyUnavailable(app: app), voiceNoteTitle, ok, otherAccount, botUnavailable(bot), botChatDidNotOpen,
         botChatChanged, finishCurrent, canceledRunAgain, canceled, fieldNotReady, couldNotStart, savedNoteTitle, savedNoteWaiting(bot),
         openChat, discardAndRecord, cancel, recoverRecording, discardRecording, noteOtherAccount, noteStillSaved, noteNotSaved, newMemo(bot), open(bot),
         searchChats, untitledChat, shortcutTitle, shortcutUnknownTitle, openAppFirst(app: app), notReady(app: app), previousSignIn, chatGone(app: app),
         memoNeedsBot, botNotOnRoster, chatDidNotOpen, roomGone, busy(app: app)]
    }
}
