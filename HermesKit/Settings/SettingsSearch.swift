// Settings search (`src/settings-ios-list.tsx` searchResults, pageEntries, DISPATCH_ROWS): one index over every page
// the list shows, every gateway config field (from the catalog, plus whatever the gateway's schema adds), the rows the
// app adds (Diagnostics, Sign Out, Saved Sign-In…) and the file actions. Every word typed must match; pages come first;
// one row per label and place; at most 60.

import Foundation

nonisolated struct SettingsSearchEntry: Sendable, Hashable, Identifiable {
    enum Target: Sendable, Hashable {
        /// A root row by its id ("model", "keys", "about"…). "row:<id>" is a row on the root itself (a switch or
        /// picker): the list scrolls to it and marks it (UX study 2026-10-21 #108).
        case root(String)
        /// A config page ("safety.approvals").
        case page(String)
        /// A config field on its page ("safety.approvals", "approvals.mode").
        case field(page: String, key: String)
        /// One of the file actions ("export", "import", "reset").
        case action(String)
    }

    var id: String
    var label: String
    var context: String
    var keywords: [String] = []
    var target: Target
    var isPage = false
}

nonisolated enum SettingsSearch {
    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func results(_ query: String, in entries: [SettingsSearchEntry], limit: Int = 60) -> [SettingsSearchEntry] {
        let terms = normalize(query).split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }
        func matches(_ entry: SettingsSearchEntry) -> Bool {
            let haystack = normalize(([entry.label, entry.context] + entry.keywords).joined(separator: " "))
            return terms.allSatisfy { haystack.contains($0) }
        }
        var seen = Set<String>()
        var out: [SettingsSearchEntry] = []
        for entry in entries.filter(\.isPage) + entries.filter({ !$0.isPage }) where matches(entry) {
            let key = normalize(entry.context) + "\u{0}" + normalize(entry.label)
            guard seen.insert(key).inserted else { continue }
            out.append(entry)
            if out.count == limit { break }
        }
        return out
    }

    /// [desktoplook] The Theme row's search words: what its page shows. [theme-pages] Chat Bubbles' and the
    /// backgrounds' words are their own rows', which open their own pages: a search never leads to a page without what
    /// was typed. The Desktop Look's row is only there where its controls are shown.
    /// [macpass-settings2] And each skin's own name ("rose pine", "midnight" found nothing).
    static let themeKeywords = ["theme", "skin", "colours", "colors", "desktop themes", "accent", "accent color", "rose pine", "high contrast"]
        + SkinCatalog.all.map { $0.label.lowercased() }

    /// Row names the pages and this index share (UX study #68, #69, #71: they say what the row does, and the old names
    /// stay searchable as keywords).
    static let introSplashLabel = "Greeting on Empty Chats"
    static let fileBrowserLabel = "Files Button in Chats"
    /// [working-ring] Theme › Working Ring: the ring that travels round a working bot or chat.
    static let workingRingLabel = "Working Ring"
    static let workingRingNote = "Working Ring is the moving line around a bot or chat while it works. Off, its working dots and “Working…” still show."
    static let sendWhileBusyLabel = "Send While Replying"   // [send-while-busy]
    static let openLinksInLabel = "Open Links In"   // [links-browser]
    static let sessionsPageTitle = "Archiving & Project Folder"   // UX study 2026-10-21 #117: the page's two sections
    static let markLabel = "Mark a Slow Moment"
    static let liveActivitiesLabel = "Show Progress on Lock Screen"   // [live]
    static let autoPluginUpdateChecksLabel = "Automatic Plugin Update Checks"
    static let checkPluginUpdatesLabel = "Check for Plugin Updates"
    // [mac] No Haptics switch on the Mac: Completion Sound lives in General there, and Sounds & Haptics is its own page on iOS.
    #if targetEnvironment(macCatalyst)
    static let hasHaptics = false, soundsSection = "General"
    #else
    static let hasHaptics = true, soundsSection = "Sounds & Haptics"
    #endif
    /// [kanban-tab-one] The Kanban Tab picker's result: Settings › Appearance › Tabs, scrolled to the picker and marked.
    static let kanbanTabTarget = "tab-order:kanban"
    /// [macpass-settings2] Status & Maintenance, found from Settings ("version", "update", "restart"): the page the
    /// Gateway page links to for the Hermes version, Restart Gateway and Update Hermes. Listed only while the gateway
    /// can open it (`SettingsRootModel.searchResults`).
    static let statusTarget = "status-maintenance"
    static let statusEntry = SettingsSearchEntry(id: "page:status-maintenance", label: CommandCenterNames.page, context: "Gateway",
        keywords: ["version", "hermes version", "update", "update hermes", "upgrade", "restart", "restart gateway", "doctor",
                   "recent logs", "maintenance", "status"],
        target: .root(statusTarget), isPage: true)
    /// [live] Show Progress on Lock Screen is a row only in a build that carries the widget extension.
    static var liveActivities: Bool { LiveActivityBuild.extensionEmbedded }

    /// Rows the app adds (they aren't in the gateway's catalog).
    static let appRows: [SettingsSearchEntry] = appRowsAlways + (ThemeFeature.desktopLook ? [
        // [appearance-groups] A row of Appearance's Look group (it headed Theme).
        .init(id: "app:desktop-look", label: "Hermes Look", context: "Appearance", keywords: ["native", "look", "desktop look", "desktop app", "square corners", "flat"], target: .root("row:desktop-look")),
        .init(id: "app:high-contrast", label: "High Contrast", context: "Appearance", keywords: ["contrast", "borders", "crisp", "hermes look", "desktop look"], target: .root("row:high-contrast")),
    ] : [])

    private static let appRowsAlways: [SettingsSearchEntry] = [
        .init(id: "app:diagnostics", label: "Diagnostics", context: "About", keywords: ["errors", "bug report", "debug", "logs", "connection details", "copy"], target: .root("diagnostics")),
        // [macpass-settings2] About opens with the row itself scrolled to and marked ("about:<row>").
        .init(id: "app:perf-log", label: "Send Performance Logs to Hermes", context: "About", keywords: ["performance", "logs", "timings"], target: .root("about:perf-log")),
        .init(id: "app:detailed-log", label: "Detailed Logging", context: "About", keywords: ["logs", "debug", "diagnostics", "verbose"], target: .root("about:detailed-log")),
        .init(id: "app:mark", label: markLabel, context: "About", keywords: ["janky", "lag", "slow", "stutter", "marker"], target: .root("about:mark")),
        .init(id: "app:share-logs", label: "Share Logs", context: "Diagnostics", keywords: ["crash", "logs", "zip"], target: .root("diagnostics")),
        // [desktoplook]
        .init(id: "app:theme", label: "Theme", context: "Appearance", keywords: themeKeywords, target: .root("theme")),
        // [density] On Theme, with UI Scale (both looks).
        // [working-ring] On Theme, beside Density (both looks).
        .init(id: "app:working-ring", label: workingRingLabel, context: "Appearance", keywords: ["working animation", "ring", "arc", "outline", "glow", "spinner", "busy", "running", "motion"], target: .root("row:working-ring")),
        .init(id: "app:density", label: "Density", context: "Appearance", keywords: ["compact", "dense", "smaller rows", "fit more", "ui scale", "zoom", "smaller text"], target: .root("row:density")),
        // [macpass-settings] The control's own name: "scale" found only Density and Desktop Look.
        .init(id: "app:ui-scale", label: "UI Scale", context: "Theme", keywords: ["text size", "bigger text", "smaller text", "larger", "zoom", "make text bigger", "font", "font size", "type size"], target: .root("row:ui-scale")),
        // [theme-pages] Rows of their own beside Theme (they were its tabs); a background opens its own page.
        .init(id: "app:chat-bubbles", label: "Chat Bubbles", context: "Appearance", keywords: ["bubble corners", "rounded corners", "message corners", "glass bubbles", "tinted bubbles", "reply bubbles", "plain replies"], target: .root("chat-bubbles")),
        // [message-colour] On Chat Bubbles; "color" as most people type it.
        .init(id: "app:message-colour", label: "Message Color", context: "Chat Bubbles", keywords: ["color", "message color", "bubble colour", "bubble color", "my messages", "blue", "graphite", "custom colour"], target: .root("chat-bubbles")),
        .init(id: "app:app-background", label: "App Background", context: "Backgrounds", keywords: ["wallpaper", "background picture", "page picture"], target: .root("background:app")),
        .init(id: "app:chat-background", label: "Chat Background", context: "Backgrounds", keywords: ["wallpaper", "background picture", "chat picture"], target: .root("background:chats")),
        .init(id: "app:backgrounds", label: "Backgrounds", context: "Appearance", keywords: ["wallpapers", "pictures"], target: .root("backgrounds")),   // [theme-pages] after its rows: "app background" finds the row first
        // [status-page] Said "Gateway", the page these open (its title, and its row in Settings and More), not a fourth
        // name for it ("Gateway Connection"); "connection" still finds them (owner 2026-11-03: one home per page).
        .init(id: "app:gateways", label: "Gateways", context: "Gateway", keywords: ["switch gateway", "add gateway", "another gateway", "accounts", "servers", "connection"], target: .root("gateway")),
        .init(id: "app:sign-out", label: "Sign Out", context: "Gateway", keywords: ["log out", "logout", "signout", "account", "disconnect", "connection"], target: .root("gateway")),
        .init(id: "app:keychain", label: "Saved Sign-In (\(DeviceWord.system) Keychain)", context: "Gateway", keywords: ["keychain", "password", "credentials", "remember me", "login", "connection"], target: .root("gateway")),
        .init(id: "app:test-notification", label: "Send Test Notification", context: "Notifications", keywords: ["test notification", "alert", "push", "notify"], target: .root("notifications")),
        // UX study 2026-10-21 #113: the switches on the root and on Notifications are found too.
        .init(id: "app:tasks", label: "Tasks", context: "Workspace & Tasks", keywords: ["tasks", "to do", "todo", "turn off tasks", "disable tasks", "task list"], target: .root("row:tasks")),
        .init(id: "app:show-file-changes", label: "File Changes", context: "Chat", keywords: ["show file changes", "folded", "collapse", "files changed", "file changed", "changes", "edits", "review", "card", "diff", ChatRowNotes.showFileChanges], target: .root("row:show-file-changes")),
        .init(id: "app:new-chat-asks-project", label: "New Chat Asks for a Project", context: "Chat", keywords: ["new chat", "project", "no project", "ask", "choose project", "folder", ChatRowNotes.newChatAsksProject], target: .root("row:new-chat-asks-project")),
        .init(id: "app:wait-for-models", label: "Favorites Wait for Models", context: "Chat", keywords: ["favorites", "favourites", "hide favorites", "starred models", "ghost", "removed provider", "model list"], target: .root("row:wait-for-models")),
        .init(id: "app:fewer-timestamps", label: "Fewer Timestamps", context: "Chat", keywords: ["timestamps", "times", "dates", "day line", "clock", ChatRowNotes.fewerTimestamps], target: .root("row:fewer-timestamps")),
        .init(id: "app:enable-notifications", label: "Enable Notifications", context: "Notifications", keywords: ["notifications", "alerts", "push", "turn off", "notify"], target: .root("notifications")),
        .init(id: "app:previews", label: "Show Previews", context: "Notifications", keywords: ["previews", "alerts", "message text", "lock screen"], target: .root("notifications")),
        .init(id: "app:banners", label: "Bot Activity Banners", context: "Notifications", keywords: ["banners", "alerts", "peek", "in-app"], target: .root("notifications")),
        // [live] Only in a build with the widget extension (`liveActivities`, filtered in `index`).
        .init(id: "app:live-activities", label: liveActivitiesLabel, context: "Notifications", keywords: ["live activity", "live activities", "lock screen", "dynamic island", "progress", "running"], target: .root("notifications")),
        .init(id: "app:tool-call-style", label: "Tool Call Style", context: "Chat", keywords: ["tool calls", "steps", "bubbles", "rows", "telegram", "commands"], target: .root("tool-calls")),
        .init(id: "app:tool-calls", label: "Tool Calls After Reply", context: "Chat", keywords: ["tool calls", "steps", "hide steps", "keep"], target: .root("tool-calls")),
        .init(id: "app:send-while-busy", label: sendWhileBusyLabel, context: "Chat", keywords: ["steer", "queue", "send mode", "busy", "while running", "interrupt", "busy input mode", "command return", "default send", ChatRowNotes.sendWhileBusy()], target: .root("row:send-while-busy")),   // [send-while-busy]
        .init(id: "app:open-links-in", label: openLinksInLabel, context: "Chat", keywords: ["browser", "links", "urls", "web", "safari", "chrome", "firefox", "edge", "brave", "external browser", "default browser", "in-app browser", ChatRowNotes.openLinksIn], target: .root("row:open-links-in")),   // [links-browser]
        .init(id: "app:new-chat-mode", label: "⌘N Opens", context: "Chat", keywords: ["command n", "cmd n", "shortcut", "keyboard", "bot chat", "new session", "persistent", "existing chat", "focus", ChatRowNotes.newChatMode(botChat: true), ChatRowNotes.newChatMode(botChat: false)], target: .root("row:new-chat-mode")),
        .init(id: "app:new-chat-key", label: "⌘N Bot", context: "Chat", keywords: ["command n", "cmd n", "shortcut", "keyboard", "new chat", "new session", "default bot", "default profile", "new chat here"], target: .root("row:new-chat-key")),
        .init(id: "app:new-chat-project", label: "⌘N Project", context: "Chat", keywords: ["command n", "cmd n", "shortcut", "default project", "folder", "workspace"], target: .root("row:new-chat-project")),   // [cmd-n] Mac only (filtered in `index`)
        .init(id: "app:resume", label: "Reopen Last Chat on Launch", context: DeviceWord.isMac ? "General" : "Chat", keywords: ["resume", "restore", "last session", "startup", "launch", ChatRowNotes.resumeLastChat], target: .root("row:resume-last-chat")),
        .init(id: "app:tips", label: "In-App Tips", context: DeviceWord.isMac ? "General" : "Chat", keywords: ["tips", "hints", "help"], target: .root("row:tips")),
        .init(id: "app:appearance", label: "Light or Dark", context: "Appearance", keywords: ["appearance", "dark", "light", "theme", "mode"], target: .root("row:appearance")),
        // [mac] Mac polish #131: the page is Sidebar on the Mac, and its Kanban Tab control Kanban.
        .init(id: "app:tab-order", label: SettingsWords.tabsPageTitle(), context: "Appearance", keywords: ["tabs", "tab bar", "tab order", "reorder", "rearrange", "organize", "move tabs", "sessions first", "sidebar", "hide tabs", "hide bots", "custom tabs", "add a tab", "files tab"], target: .root("tab-order")),   // [taborder]
        // [kanban-tab-one] Owner 2026-11-03 (one home per page): the one Kanban Tab picker is on Tabs, with the other tab
        // choices (listed after Tabs, which "tabs" finds first). It chooses whether Kanban or Artifacts has the tab, so
        // "artifacts tab" finds it too.
        .init(id: "app:kanban", label: DeviceWord.isMac ? "Kanban" : "Kanban Tab", context: SettingsWords.tabsPageTitle(), keywords: ["kanban", "board", "tab", "tasks", "artifacts", "kanban or artifacts"], target: .root(kanbanTabTarget)),
        // [settings]
        // [app-icons] App Icon: the Home Screen's on the iPhone and iPad, the Dock's on the Mac (`MacDockIcon`).
        .init(id: "app:app-icon", label: "App Icon", context: "Appearance", keywords: ["icon", "home screen", "dock", "alternate icon", "feather", "original", "pearl", "black and white", "hermes", "winged", "god", "shapes", "matrix", "robot", "change icon"], target: .root("app-icon")),
        .init(id: "app:haptics", label: "Haptics", context: soundsSection, keywords: ["vibration", "taptic", "taps", "buzz", "feedback"], target: .root("row:haptics")),
        .init(id: "app:attachment-limit", label: "Largest Attachment", context: "Chat Behavior", keywords: ["megabytes", "size", "file size", "limit", "mb", "upload"], target: .root("attachment-limit")),
        .init(id: "app:file-browser", label: fileBrowserLabel, context: "Chat", keywords: ["file browser", "files", "folder", "project folder", "workspace"], target: .root("row:file-browser")),
        // [session-strip]
        .init(id: "app:session-strip", label: "Other Chats at the Top", context: "Chat", keywords: ["session strip", "sessions", "chats", "switch chats", "pills", "top bar", "move between chats", "other sessions"], target: .root("row:session-strip")),
        .init(id: "app:message-reactions", label: "Message Reactions", context: "Chat", keywords: ["reactions", "tapback", "tapbacks", "emoji", "react", "like", ChatRowNotes.messageReactions], target: .root("row:message-reactions")),
        .init(id: "app:intro-splash", label: introSplashLabel, context: "Chat", keywords: ["intro splash", "intro", "greeting", "empty chat", "face", "welcome"], target: .root("row:intro-splash")),
        .init(id: "app:completion-sound", label: "Completion Sound", context: soundsSection, keywords: ["sound", "chime", "cue", "reply finished"], target: .root("row:completion-sound")),
        .init(id: "app:sound", label: "Sound", context: soundsSection, keywords: ["chime", "preset", "preview", "tone"], target: .root("sound-picker")),
        .init(id: "app:thinking-drive", label: "Thinking Bar", context: "Appearance", keywords: ["lightspeed", "afterburner", "calm", "hyperspace", "warp", "thinking", "effort", "reasoning", "slider", "model panel", "animation"], target: .root("row:thinking-drive")),   // [thinking-drive]
        .init(id: "app:licenses", label: "Open-Source Licenses", context: "About", keywords: ["licence", "license", "open source"], target: .root("licenses")),
        .init(id: "app:default-folder", label: "Default Project Folder", context: sessionsPageTitle, keywords: ["folder", "directory", "project", "workspace", "cwd", "new chat"], target: .root("sessions")),
        .init(id: "app:auto-archive", label: "Auto-Archive Stale Chats", context: sessionsPageTitle, keywords: ["archive", "old chats", "retention", "inactive"], target: .root("sessions")),
        .init(id: "app:plugin-update-checks", label: autoPluginUpdateChecksLabel, context: "Bots & Tools", keywords: ["plugin", "plugins", "updates", "automatic", "background", "manual", "slow", "check"], target: .root("row:plugin-update-checks")),
        .init(id: "app:check-plugin-updates", label: checkPluginUpdatesLabel, context: "Bots & Tools", keywords: ["plugin", "plugins", "updates", "check", "manual"], target: .root("row:check-plugin-updates")),
    ] + shareMenuRow + VoiceSettingsCatalog.searchRows

    /// [macpass-settings2] The Mac's Share Menu row (General): "share" found only Share Logs.
    #if targetEnvironment(macCatalyst)
    private static let shareMenuRow: [SettingsSearchEntry] = [
        .init(id: "app:share-menu", label: "Share Menu", context: "General", keywords: ["share", "share sheet", "share extension", "send to bot", "other apps"], target: .root("row:share-menu")),
    ]
    #else
    private static let shareMenuRow: [SettingsSearchEntry] = []
    #endif   // [talk] Read Replies Aloud, Voice Diagnostics, Send Memo on Release, How Voice Works

    /// The root's own pages.
    static let rootPages: [SettingsSearchEntry] = [
        ("gateway", "Gateway", ["gateways", "connection", "address"]), ("notifications", "Notifications", ["alerts", "push", "notify"]),
        ("providers", "Providers", ["api keys", "accounts", "sign in", "openai", "anthropic", "openrouter",
                                    // [provider-manager] What its pages do: rename a provider or a model, show or hide models.
                                    "models", "rename model", "hide model", "show model", "model names", "custom provider"]),
        ("keys", "Keys", ["api keys", "tools", "tokens", "environment", "env"]),
        ("vault", "Passwords", ["vault", "passwords", "logins", "cards", "addresses", "keychain", "1password", "bitwarden"]),
        ("billing", "Billing", ["balance", "credits", "plan", "nous portal", "usage"]),
        ("browser-use-cloud", "Browser Use Cloud", ["browser use", "cloud browser", "api key", "all bots", "watch", "take over"]),
        ("phone-calls", "Phone Calls (Beta)", ["phone", "calls", "samplehost", "voicemail", "voice calls"]),
        ("sessions", sessionsPageTitle, ["sessions", "archive", "chats", "project folder", "chat folder", "retention"]),
        ("capabilities", "Capabilities", ["abilities", "what bots can do"]),   // [cap-pages]
        // [tile-models] The model the tiles' jobs run, and their fallback.
        ("tile-model", "Tile Model", ["tiles", "tile model", "dashboard", "fallback", "jobs model", "cron model"]),
        ("composio", "Composio", ["connect apps", "api key", "gmail", "slack", "apps"]),   // [composio-row]
        ("about", "About", ["version", "support", "privacy", "build", "app version"]),
        ("backup-reset", "Backup & Reset", ["backup", "factory"]),
        // [macpass-settings2] Device Access was not found at all ("contacts", "location", "health" found nothing).
        ("device-access", "Device Access", ["device", "contacts", "calendar", "calendars", "reminders", "location", "health",
                                            "photos", "permissions", "what bots can use"]),
        ("proactivity-beta", "Proactivity (Beta)", ["proactive", "proactivity", "beta", "open loops", "daily brief", "follow up",
                                                    "anticipation", "calibration", "hermes-hq-proactive"]),
    ].map { SettingsSearchEntry(id: "page:\($0.0)", label: $0.1, context: "", keywords: $0.2, target: .root($0.0), isPage: true) }
        + capabilitiesPages

    /// [cap-pages] Capabilities' four lists, each a page of its own under it (a result opens it over Capabilities).
    static let capabilitiesPages: [SettingsSearchEntry] = [
        ("skills", "Skills", ["skills"]), ("tools", "Tools", ["toolsets", "tools", "web search", "terminal"]),
        ("connectors", "Connectors", ["mcp", "connectors", "servers"]),
        ("plugins", "Plugins", ["plugins", "add-ons", "addons", "extensions", "find plugins", "install plugin", "catalog"]),   // [find-plugins]
    ].map { SettingsSearchEntry(id: "page:\($0.0)", label: $0.1, context: "Capabilities", keywords: $0.2, target: .root($0.0), isPage: true) }

    /// Backup & Reset lives under Hermes on Mac and its own page on iPhone; Clear Model Favorites lives under Chat.
    private static var actionsContext: String { DeviceWord.isMac ? "Hermes" : "Backup & Reset" }

    static let actions: [SettingsSearchEntry] = [
        .init(id: "action:export", label: "Export Settings…", context: actionsContext, keywords: ["export", "backup", "save settings", "download"], target: .action("export")),
        .init(id: "action:import", label: "Import Settings…", context: actionsContext, keywords: ["import", "restore", "load settings", "upload"], target: .action("import")),
        .init(id: "action:clear-models", label: DeviceWord.isMac ? "Clear Model Favorites…" : "Clear Favorite & Recent Models…", context: "Chat", keywords: ["favorites", "favourites", "starred models", "recent models", "unstar", "clear"], target: .action("clear-models")),
        .init(id: "action:reset", label: "Reset to Defaults…", context: actionsContext, keywords: ["reset", "defaults", "factory", "restore defaults"], target: .action("reset")),
    ]

    /// [context-window] The words people use for a page that its title doesn't have (owner 2026-11-01 had to ask where
    /// max context was).
    /// [macpass-settings2] Fields' everyday words their labels lack: "thinking" found only the Thinking Bar, not
    /// the reasoning settings that make a model think.
    static let fieldKeywords: [String: [String]] = [
        "agent.reasoning_effort": ["thinking", "think", "thinking level", "effort"],
        "delegation.reasoning_effort": ["thinking", "think", "thinking level", "effort"],
        "display.show_reasoning": ["thinking", "thoughts", "show thinking"],
    ]

    static let pageKeywords: [String: [String]] = [
        // [macpass-settings2] "default model" found Fallback Models only, not the page that sets it.
        "model.main": ["default model", "change model", "which model"],
        "model.context": ["max context", "maximum context", "context length", "context size", "context limit", "token limit",
                          "tokens", "window", "num ctx"],
    ]

    /// Config sections and pages, and every field the catalog (and the schema, when read) knows.
    static func configEntries(schema: [String: ConfigFieldSchema] = [:]) -> [SettingsSearchEntry] {
        var out: [SettingsSearchEntry] = []
        for section in ConfigCatalog.sections {
            out.append(.init(id: "section:\(section.id)", label: section.title, context: "", target: .root("config:\(section.id)"), isPage: true))
            for page in section.pages {
                out.append(.init(id: "page:\(page.key)", label: page.title, context: section.title, keywords: pageKeywords[page.key] ?? [],
                                 target: .page(page.key), isPage: true))
            }
            for key in section.keys where !VoiceSettingsCatalog.isHidden(key) {   // [talk] row L546
                guard let page = ConfigCatalog.page(forField: key, in: section.id) else { continue }
                let label = ConfigCopy.labels[key] ?? ConfigText.pretty(String(key.split(separator: ".").last ?? Substring(key)))
                let description = ConfigCopy.descriptions[key] ?? schema[key]?.description ?? ""
                out.append(.init(id: "field:\(key)", label: label, context: page.title,
                                 keywords: [key.replacingOccurrences(of: "_", with: " "), description] + (fieldKeywords[key] ?? []), target: .field(page: page.key, key: key)))
            }
        }
        return out
    }

    static func index(schema: [String: ConfigFieldSchema] = [:]) -> [SettingsSearchEntry] {
        rootPages + configEntries(schema: schema) + appRows.filter { (hasHaptics || $0.id != "app:haptics") && (liveActivities || $0.id != "app:live-activities") && (!hasHaptics || !$0.id.hasPrefix("app:new-chat-")) } + actions
    }
}
