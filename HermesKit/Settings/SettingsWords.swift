// Words the Settings pages choose from state (UX study 2026-10-19 #62, #64, #92, #110): the Kanban Tab footer, tip and
// How Kanban Works line, the gateway card's VoiceOver label, the Tool Calls and Notifications rows' values, the On Your
// Gateway footer, the Notifications page's unopened-alerts line, and whose Default Model a page changes (tester batch
// 3). Pure, so each choice is unit-tested without SwiftUI.

import Foundation

nonisolated enum SettingsWords {
    // MARK: Kanban Tab footer (#62)

    static let kanbanLead = "A task board your bots work from."

    /// [kanban-tab-one] Where the one Kanban Tab control lives (owner 2026-11-03: one home per page; it was also a
    /// Settings › Bots & Tools row). [mac] Mac polish #131: on the Mac the page is called Sidebar (Sidebar Settings…
    /// opens it) and the control Kanban.
    static func kanbanTabPath(mac: Bool = DeviceWord.isMac) -> String {
        mac ? "Settings › Appearance › \(tabsPageTitle(mac: true))" : "Settings › Appearance › Tabs"
    }

    /// [mac] Mac polish #131: Settings › Appearance › Tabs is the sidebar's page on the Mac, where there is no tab bar;
    /// its row and its bar say Sidebar there.
    static func tabsPageTitle(mac: Bool = DeviceWord.isMac) -> String { mac ? "Sidebar" : "Tabs" }

    /// The footer under the Kanban Tab picker (Settings › Appearance › Tabs). On and Off start with the web's words;
    /// Automatic says what it chose and why. [kanban-tab-one] Each says where Artifacts goes, so a tab that changes by
    /// itself on Automatic is explained where it is chosen, not only by the one-time tip. `automatic`: the picker is on
    /// Automatic. `showsTab`: the tab is there (the choice, or Automatic's answer). `tabHidden`: the tab they share is
    /// turned off in the list above ([customtabs]), so both open from More. `mac`: the tab is a sidebar place, and More
    /// is the sidebar's Tools (Mac polish #131: the Mac shows no More).
    static func kanbanFooter(automatic: Bool, showsTab: Bool, tabHidden: Bool = false, mac: Bool = DeviceWord.isMac) -> String {
        if tabHidden {
            if mac {
                return !automatic && !showsTab ? "\(kanbanLead) Off: Kanban isn’t shown, and \(artifactsInMore(mac: true))."
                    : "\(kanbanLead) Its place in the sidebar is turned off above, so Kanban and Artifacts are \(underTools)."
            }
            return !automatic && !showsTab ? "\(kanbanLead) Off: Kanban isn’t shown, and Artifacts opens from More."
                : "\(kanbanLead) Its tab is turned off above, so Kanban and Artifacts open from More."
        }
        if mac { return macKanbanFooter(automatic: automatic, showsTab: showsTab) }
        return switch (automatic, showsTab) {
        case (false, true): "\(kanbanLead) It’s the Kanban tab, and \(artifactsInMore())."
        case (false, false): "\(kanbanLead) Turn it on to add a Kanban tab in Artifacts’ place."
        case (true, true): "\(kanbanLead) It’s the Kanban tab (Automatic: on), and \(artifactsInMore())."
        case (true, false): "\(kanbanLead) Automatic: your board has no tasks yet, so Kanban is in More. It takes Artifacts’ tab once the board has tasks. Choose On to give it the tab now."
        }
    }

    /// Where the page that lost the place goes: More's Workspace, or [mac] (Mac polish #131) the sidebar's Tools, where
    /// the Mac lists More's working pages.
    private static func artifactsInMore(mac: Bool = false) -> String {
        mac ? "Artifacts is \(underTools)" : "Artifacts is in More › Workspace"
    }

    private static let underTools = "under Tools in the sidebar"

    private static func macKanbanFooter(automatic: Bool, showsTab: Bool) -> String {
        switch (automatic, showsTab) {
        case (false, true): "\(kanbanLead) It’s in the sidebar, and \(artifactsInMore(mac: true))."
        case (false, false): "\(kanbanLead) Turn it on to put Kanban in the sidebar in Artifacts’ place."
        case (true, true): "\(kanbanLead) It’s in the sidebar (Automatic: on), and \(artifactsInMore(mac: true))."
        case (true, false): "\(kanbanLead) Automatic: your board has no tasks yet, so Kanban is \(underTools). It takes Artifacts’ place once the board has tasks. Choose On to give it that place now."
        }
    }

    /// [kanban-tab-one] The one-time tip when Automatic gives Kanban the tab Artifacts had (UX study #194). It named
    /// "Settings › Kanban Tab", a path that never was; now the real one. The Mac's tabs are sidebar places.
    static func kanbanTookTab(mac: Bool = DeviceWord.isMac) -> (label: String, detail: String) {
        (mac ? "Kanban Took Artifacts’ Place" : "Kanban Took Artifacts’ Tab",
         "\(artifactsInMore(mac: mac)). Change this in \(kanbanTabPath(mac: mac)).")
    }

    /// [kanban-tab-one] How Kanban Works' last line (UX study #121): where the tab is chosen.
    static func kanbanAboutTab(mac: Bool = DeviceWord.isMac) -> String {
        (mac ? "Kanban can have Artifacts’ place in the sidebar, and Artifacts then moves under Tools. To choose, use Kanban in \(kanbanTabPath(mac: true))."
             : "Kanban can have its own tab in place of Artifacts, which then moves to More. To choose, use Kanban Tab in \(kanbanTabPath(mac: false)).")
    }

    // MARK: Gateway card (#64)

    static let gatewayCardHint = "Opens gateway settings"

    /// The card's VoiceOver label: the name and status, then the address only when it says something the name doesn't.
    static func gatewayCardLabel(name: String, status: String, host: String) -> String {
        let same = host.isEmpty || host.caseInsensitiveCompare(name) == .orderedSame
        return same ? "\(name), \(status)" : "\(name), \(status), \(host)"
    }

    // MARK: Tool Calls row (#110)

    /// The Settings row's value: the style alone, so it fits on one line. "Hidden after reply" wrapped the row to two
    /// lines (owner 2026-11-02); the Tool Calls page still shows After Reply.
    static func toolCallsSummary(style: String, hidesAfterReply: Bool) -> String { style }

    // MARK: Notifications › alerts that couldn't be opened (#92)

    /// A sentence for the alerts this device received but couldn't read; nil when there were none.
    static func unopenedAlerts(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 alert couldn’t be opened." : "\(count) alerts couldn’t be opened."
    }

    static let unopenedHint = "An alert that couldn’t be opened shows without its words. About › Diagnostics has the details."

    // MARK: Notifications row (UX study 2026-10-21 #119)

    /// The Settings row's value, as the rows beside it show theirs. `denied`: iOS Settings has them off. `undetermined`:
    /// iOS hasn't asked yet (no word: the page asks). `plugin`: the gateway add-on's last known state, nil when this
    /// build can't receive alerts from it.
    static func notificationsSummary(enabled: Bool, denied: Bool, undetermined: Bool, plugin: PushPolicy.PluginState?) -> String? {
        if !enabled { return "Off" }
        if denied { return "Off in \(DeviceWord.settingsApp)" }
        if undetermined { return nil }
        switch plugin {
        case .missing: return "Add-on Needed"
        case .outdated: return "Update Needed"
        default: return "On"
        }
    }

    // MARK: On Your Gateway footer (UX study 2026-10-21 #50, #117, #186)

    /// Whose settings these are (the gateway's default profile, the main bot) and the few rows in the group kept on this
    /// device instead. `defaultBot`: the main bot's name when known; `otherBots`: the roster has more than it.
    static func gatewayFooter(defaultBot: String?, otherBots: Bool) -> String {
        var text = "Saved on \(HostWord.phrase), so they apply wherever you use Hermes."
        if let defaultBot, !defaultBot.isEmpty {
            text = "\(defaultBot)’s settings, saved on \(HostWord.phrase) so they apply wherever you use Hermes."
            if otherBots { text += " Other bots keep their own." }
        }
        return text + " Voice’s Read Replies Aloud and Send Memo on Release, and the default project folder, are kept on this \(DeviceWord.name)."
    }

    // MARK: Default Model (tester batch 3: "Changing the model in Settings only changes it for default.")

    /// Settings › Model › Main Model's section header: whose default model it is. `defaultBot`: the main bot's name.
    static func mainModelHeader(defaultBot: String?) -> String {
        guard let defaultBot = named(defaultBot) else { return "Default Profile’s Model" }
        return "\(defaultBot)’s Default Model"
    }

    /// Its footer: whose model it is, where each other bot's own is changed (`otherBots`: the roster has more), and that
    /// a chat can still switch its own (a chat's switch is `config.set model` on that session, not saved for the bot).
    static func mainModelFooter(defaultBot: String?, otherBots: Bool) -> String {
        "\(defaultScope(defaultBot: defaultBot, otherBots: otherBots)) \(chatSwitchHint)"
    }

    // MARK: Model scope ([model-scope] owner 2026-11-03: "Applies to <Bot> only" / "Applies to new chats" wherever a
    // model is picked; Settings › Model › Main Model and Bot Info › Brain › Default Model read as the same setting)

    /// Whose a pick is: "Applies to Hermes only." Nil or blank: the default profile's bot, unnamed.
    static func appliesOnly(to bot: String?) -> String {
        "Applies to \(named(bot) ?? "the default bot") only."
    }

    /// Where every other bot's own models are changed.
    static let otherBotsHint = "Other bots keep their own in Bot Info › Brain."

    /// A chat's own model switch (the model panel, the Models sheet: `config.set model` on that chat) still wins there.
    static let chatSwitchHint = "A chat can still switch its own model."

    /// Settings' own model pages (the default profile's): the default bot only, and where the others' are changed.
    static func defaultScope(defaultBot: String?, otherBots: Bool) -> String {
        let text = appliesOnly(to: defaultBot)
        return otherBots ? "\(text) \(otherBotsHint)" : text
    }

    /// Settings › Model › Main Model's Defaults (Reasoning Effort, Fast Mode: the default profile's `agent.*`); a chat's
    /// own thinking and Fast tiles change only that chat.
    static func mainDefaultsFooter(defaultBot: String?) -> String {
        "How hard the model thinks before answering, and the faster (pricier) service tier where the provider offers one. "
            + "\(appliesOnly(to: defaultBot)) A chat can still change its own."
    }

    /// Settings › Model's footer: each other bot's own default, fallback and auxiliary models (tester 2026-10-30).
    static let otherBotsModelsHint = "Other bots keep their own models, fallbacks and auxiliary models: change them in each bot’s Bot Info › Brain."

    /// Settings › Model's footer (it said "The models your bots use", which read as every bot's). Mac polish #134: it
    /// said Hermes three times ("…saved on the computer running Hermes so they apply wherever you use Hermes").
    static func modelSectionFooter(defaultBot: String?, otherBots: Bool) -> String {
        let whose = named(defaultBot).map { "\($0)’s models" } ?? "The default profile’s models"
        let text = "\(whose). They’re kept on \(HostWord.phrase), so every device uses them."
        return otherBots ? "\(text) \(otherBotsModelsHint)" : text
    }

    /// A bot's own Default Model (Bot Info › Brain, More › Bot Profiles, and its chooser): that bot alone, and a chat's
    /// own switch. The default bot's is the very setting Settings › Model › Main Model changes, so it says so.
    static func botModelScope(bot: String, isDefault: Bool) -> String {
        let only = appliesOnly(to: bot)
        return isDefault ? "\(only.dropLast()), the same as Settings › Model. \(chatSwitchHint)" : "\(only) \(chatSwitchHint)"
    }

    static func botModelFailureTitle(_ bot: String) -> String { "Couldn’t Change \(bot)’s Model" }

    /// A model page's footer, then whose models it changes. `bot`: a bot's own page (its Fallback Models, its Auxiliary
    /// Models, from its Bot Info). Nil or blank: Settings' own page, the default bot's (`defaultBot`, and `otherBots`
    /// for where the others' are).
    static func botScoped(_ footer: String, bot: String?, defaultBot: String? = nil, otherBots: Bool = false) -> String {
        guard let bot = named(bot) else { return "\(footer) \(defaultScope(defaultBot: defaultBot, otherBots: otherBots))" }
        return "\(footer) \(appliesOnly(to: bot))"
    }

    /// Settings › Model › Mixture of Agents (`/api/model/moa`: the default profile's presets; no other bot has the page).
    static func moaFooter(defaultBot: String?) -> String {
        "Several models answer each turn, and an aggregator model writes the reply from their answers. \(appliesOnly(to: defaultBot))"
    }

    /// A custom provider's Make Default: it becomes the default bot's model (`/api/providers/custom-endpoints/<id>/activate`
    /// writes the default profile's config).
    static func customProviderDefaultFooter(model: String?, provider: String, defaultBot: String?) -> String {
        let makes = named(model).map { "Makes \($0) from \(provider) the default model." } ?? "Makes \(provider) the default provider."
        return "\(makes) \(appliesOnly(to: defaultBot)) \(chatSwitchHint)"
    }

    /// The custom provider that is the default bot's now.
    static func customProviderIsDefault(defaultBot: String?) -> String {
        let chats = named(defaultBot).map { "New chats with \($0)" } ?? "New chats with the default bot"
        return "\(chats) use this provider’s default model."
    }

    /// A tool's own model on a bot's Capabilities (`setToolModel(profile:)`): that bot's alone. The page's own footer
    /// already says "Changes apply to new chats.", so this line says only whose it is.
    static func toolModelScope(bot: String?) -> String {
        "Applies to \(named(bot) ?? "this bot") only."
    }

    // MARK: Clear Favorite & Recent Models (tester 2026-11-09)

    /// [stale-stars] The confirm's message: what goes, counted, and what stays.
    static func clearModelsMessage(favorites: Int, recents: Int) -> String {
        func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }
        let what: String
        switch (favorites, recents) {
        case (0, 0): what = "No models are starred or recent on this device."
        case (_, 0): what = "Unstars \(count(favorites, "model", "models"))."
        case (0, _): what = "Forgets \(count(recents, "recent model", "recent models"))."
        default: what = "Unstars \(count(favorites, "model", "models")) and forgets \(count(recents, "recent model", "recent models"))."
        }
        return what + " Bots, chats and each bot’s default model stay."
    }

    private static func named(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }
}
