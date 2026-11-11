// App-side preferences Settings controls on this iPhone (not the gateway): In-App Tips (`vendor/.../store/tips.ts`,
// default on; it gates the app's tips, today the voice memo tips) and the completion sound picker
// (`CompletionCue.variant`). Rows the web has but this app has no behaviour for are left out (see SettingsRootView).

import Foundation

enum InAppTips {
    static let key = "hqn.inAppTips"

    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set {
            guard newValue != isOn else { return }
            UserDefaults.standard.set(newValue, forKey: key)
            AppLog.note("settings", "In-App Tips set to \(newValue)")
        }
    }
}

/// [settings] Intro Splash (`vendor/.../store/intro-splash.ts`, default on): the bot's face and greeting on an empty
/// chat. Off: an empty chat is blank above the message bar (docs/spec/3x-settings.md §7).
enum IntroSplash {
    static let key = "hqn.introSplash"
    static let didChange = Notification.Name("hqn.introSplash.changed")

    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set {
            guard newValue != isOn else { return }
            UserDefaults.standard.set(newValue, forKey: key)
            AppLog.note("settings", "Intro Splash set to \(newValue)")
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}

/// [settings] File Browser (`vendor/.../store/layout.ts` `$fileBrowserOpen`, default off). A phone has no "beside the
/// chat": on, a chat that has a project folder gets a Files button in its top bar; off, Files stays under ⋯ › More
/// (docs/spec/3x-settings.md §12).
enum FileBrowserPref {
    static let key = "hqn.fileBrowser"
    static let didChange = Notification.Name("hqn.fileBrowser.changed")

    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? false }
        set {
            guard newValue != isOn else { return }
            UserDefaults.standard.set(newValue, forKey: key)
            AppLog.note("settings", "File Browser set to \(newValue)")
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// Whether a chat shows the bar button: the switch is on and the chat has a folder to list.
    nonisolated static func showsButton(on: Bool, directory: String?) -> Bool {
        on && !(directory ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Tester 2026-11-10: with a bot's pill picked, Sessions' New Chat started in no project at once; a chat in a
/// project (or a new project) sat behind the Filter menu. Compose now always opens the one New Chat sheet (the bot,
/// then the project). Off: with a pill picked, a chat in no project straight away, as before.
enum NewChatProjectChoice {
    static let key = "hqn.newChatAsksProject"

    static var isOn: Bool {
        // On by default: only "off" is stored. `bool(forKey:)`, so a launch argument's "NO" reads as off too.
        get { UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key) }
        set {
            if newValue { UserDefaults.standard.removeObject(forKey: key) } else { UserDefaults.standard.set(false, forKey: key) }
            AppLog.note("settings", "New Chat asks for a project: \(newValue)")
        }
    }
}

/// What the New Chat sheet last started: the bot (lit under All next time) and, per bot, the project (its row carries
/// "Last used"). On this device only.
enum NewChatLast {
    static let botKey = "hqn.newChat.lastBot"
    static let projectsKey = "hqn.newChat.lastProjects"
    /// The stored word for No Project (a project's key is a folder path, never empty).
    nonisolated static let none = ""

    static var bot: String? { UserDefaults.standard.string(forKey: botKey) }

    /// The project `bot` last started in: a key, `none`, or nil when it has started nothing from the sheet.
    static func project(for bot: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: projectsKey) as? [String: String])?[bot]
    }

    static func note(bot: String, project: String?) {
        UserDefaults.standard.set(bot, forKey: botKey)
        var all = (UserDefaults.standard.dictionary(forKey: projectsKey) as? [String: String]) ?? [:]
        all[bot] = project ?? none
        UserDefaults.standard.set(all, forKey: projectsKey)
    }

    /// Whether the row for `row` (nil: No Project) carries "Last used", given what is stored for the bot.
    nonisolated static func marks(stored: String?, row: String?) -> Bool {
        guard let stored else { return false }
        return stored == none ? row == nil : row == stored
    }

    /// The bot lit when the sheet opens: the picked pill's, else the one used last while it is still offered, else
    /// Hermes, else the first.
    nonisolated static func opensOn(picked: String?, last: String?, among ids: [String]) -> String {
        if let picked, ids.contains(picked) { return picked }
        if let last, ids.contains(last) { return last }
        return ids.contains("default") ? "default" : (ids.first ?? "default")
    }
}

/// [cmd-n] Tester 2026-11-02 (Mac): ⌘N asked for a bot (and a project) every time. It now starts a chat with one bot at
/// once, Hermes (the default profile) unless Settings › Chat › New Chat (⌘N) names another; ⇧⌘N (New Chat With…) keeps
/// the chooser. `ask` puts the chooser back on ⌘N.
enum NewChatKeyBot {
    static let key = "hqn.newChatKeyBot"
    static let ask = "ask"

    static var chosen: String {
        get { UserDefaults.standard.string(forKey: key) ?? "default" }
        set {
            guard newValue != chosen else { return }
            UserDefaults.standard.set(newValue, forKey: key)
            AppLog.note("settings", "New Chat (⌘N) set to \(newValue)")
        }
    }

    /// What ⌘N opens. A tester 2026-11-02 (Discord): "Since bot chats are intended to be persistent and compact rather
    /// than reset … there should be an option for cmd+n to open an existing bot chat and focus the composer, rather than
    /// start a new session." `session` (the default) starts a new chat; `botChat` opens the bot's own chat (its Bots row)
    /// with the caret in the message field.
    enum Mode: String, CaseIterable, Identifiable {
        case session, botChat
        var id: String { rawValue }
        var title: String { self == .session ? "New Chat" : "Bot Chat" }
    }

    static let modeKey = "hqn.newChatKeyMode"

    static var mode: Mode {
        get { UserDefaults.standard.string(forKey: modeKey).flatMap(Mode.init(rawValue:)) ?? .session }
        set {
            guard newValue != mode else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: modeKey)
            AppLog.note("settings", "⌘N opens \(newValue.rawValue)")
        }
    }

    /// The project ⌘N starts the chat in: a project's key (its folder, `SessionProjects.key`); nil, none (Home, or the
    /// one project Filter › Project narrows Sessions to). Owner 2026-11-02: "have the session default to a certain project".
    static let projectKey = "hqn.newChatKeyProject"

    static var project: String? {
        get { UserDefaults.standard.string(forKey: projectKey).flatMap { $0.isEmpty ? nil : $0 } }
        set {
            guard newValue != project else { return }
            UserDefaults.standard.set(newValue ?? "", forKey: projectKey)
            AppLog.note("settings", "New Chat (⌘N) project set to \(newValue ?? "none")")
        }
    }

    /// The project ⌘N starts in among the gateway's project `keys`: the chosen one while a bot still has it, else none.
    static func project(chosen: String? = project, among keys: [String]) -> String? {
        guard let chosen, keys.contains(chosen) else { return nil }
        return chosen
    }

    /// The bot ⌘N starts with among the gateway's `bots`: the chosen one while the gateway still has it, else Hermes;
    /// nil asks (Ask Every Time). With the roster not read yet the chosen one is tried as it is.
    static func profile(chosen: String = chosen, among bots: [String]) -> String? {
        if chosen == ask { return nil }
        if bots.isEmpty || bots.contains(chosen) { return chosen }
        return bots.contains("default") ? "default" : bots.first
    }
}

/// [send-while-busy] Tester 2026-11-08 (Discord): "How do I make the default chat send mode queue and not steer".
/// What Send (and Return) does with typed words while a reply runs: Steer (the default) adds them to that reply, Queue
/// sends them when it finishes. Send's hold menu offers both either way, and ⌘Return does the other one. The gateway's
/// own `display.busy_input_mode` doesn't reach this app: it asks for the steer or the queue itself.
enum SendWhileBusy: String, CaseIterable, Identifiable {
    case steer, queue
    var id: String { rawValue }
    var title: String { self == .steer ? "Steer" : "Queue" }

    static let key = "hqn.sendWhileBusy"

    static var chosen: SendWhileBusy {
        get { UserDefaults.standard.string(forKey: key).flatMap(SendWhileBusy.init(rawValue:)) ?? .steer }
        set {
            guard newValue != chosen else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            AppLog.note("settings", "Send While Replying set to \(newValue.rawValue)")
        }
    }

    /// Whether a send while a reply runs waits in the queue: `picked` from Send's hold menu (nil: a tap on Send or
    /// Return); `command`, ⌘Return, the one not chosen.
    nonisolated static func queues(picked: SendWhileBusy? = nil, command: Bool = false, chosen: SendWhileBusy) -> Bool {
        if let picked { return picked == .queue }
        return command ? chosen == .steer : chosen == .queue
    }
}
