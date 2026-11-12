// [bot-colour] A bot's own message colour (owner 2026-11-11: "options to change the chat bubble colors based on the
// color of your bot face, or a manual color per bot"; then: your own messages take it, in that bot's chat). Bot Info ›
// Settings › Colour: what Chat Bubbles says (the default), the bot's face, a named colour or any other. Kept per
// gateway account and bot, and it travels with the other settings (`SyncedSettingKeys.accountPrefixes`).

import Foundation

nonisolated enum BotMessageColour {
    enum Choice: Sendable, Hashable {
        /// What Settings › Chat Bubbles › Colour says.
        case app
        /// The colour of the bot's face.
        case face
        /// A named colour or a custom one.
        case colour(MessageColour)

        /// Anything but "face", a known name or `#RRGGBB` is what Chat Bubbles says.
        init(stored: Any?) {
            guard let text = stored as? String else { self = .app; return }
            if text == "face" { self = .face; return }
            let colour = MessageColour(stored: text)
            switch colour {
            case .preset, .custom: self = .colour(colour)
            case .theme, .botFace: self = .app
            }
        }

        /// What is stored: nothing for the default.
        var stored: String? {
            switch self {
            case .app: nil
            case .face: "face"
            case .colour(let colour): colour.stored
            }
        }
    }

    /// Posted when a bot's choice changes, so its open chat repaints.
    static let didChange = Notification.Name("hqn.botMessageColour.didChange")

    static func key(account: String, profile: String) -> String {
        "hqn.botMessageColour.\(account).\(profile.isEmpty ? "default" : profile)"
    }

    #if DEBUG
    /// `-HQDebugBotMessageColour sam=face,default=green`: choices by bot for screenshots, ahead of the stored ones.
    nonisolated(unsafe) static var debugChoices: [String: Choice] = [:]
    #endif

    static func choice(account: String?, profile: String, defaults: UserDefaults = .standard) -> Choice {
        #if DEBUG
        if let forced = debugChoices[profile.isEmpty ? "default" : profile] { return forced }
        #endif
        guard let account, !account.isEmpty else { return .app }
        return Choice(stored: defaults.object(forKey: key(account: account, profile: profile)))
    }

    static func set(_ choice: Choice, account: String?, profile: String, defaults: UserDefaults = .standard) {
        guard let account, !account.isEmpty else { return }
        let key = key(account: account, profile: profile)
        if let stored = choice.stored { defaults.set(stored, forKey: key) } else { defaults.removeObject(forKey: key) }
        NotificationCenter.default.post(name: didChange, object: nil, userInfo: ["profile": profile])
    }

    /// The colour a bot's chat is painted with over the app's own, nil for none: the bot's pick, else its face where
    /// Chat Bubbles says Bot's Face.
    static func effective(app: MessageColour, bot: Choice, face: MessageColour?) -> MessageColour? {
        switch bot {
        case .colour(let colour): colour
        case .face: face
        case .app: app == .botFace ? face : nil
        }
    }
}
