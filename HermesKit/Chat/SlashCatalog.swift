// The slash commands as the phone knows them (spec 1x §7.2, §8.2): the `commands.catalog` answer, the desktop's local
// command table (V:lib/desktop-slash-commands.ts:179-304), resolution of a command's surface, the Commands sheet's
// sections and descriptions (S:ui-chat/commands.ts, S:fe-convo-r5.ts:197-228, V:i18n/en.ts:3845-3918), what a pick
// does, and the slash regex and parse (SH:slash.ts:9-39). Pure, except the 1 h catalog cache at the end.

import Foundation

// MARK: - The catalog

nonisolated struct CommandCatalogMeta: Hashable, Sendable {
    var argumentMode: String?       // "options" | "text" | "mixed" | nil
    var desktop: String?            // nil offered · "hidden" · terminal | messaging | settings | advanced | composer-voice
}

nonisolated struct SkillCatalogEntry: Hashable, Sendable {
    var usage: Int?
    var origin: String?             // bundled | hub | local
}

/// `CommandsCatalogResult` (H:tui_gateway/contracts/tools_commands.py:217-226), only the fields the phone reads.
nonisolated struct CommandsCatalog: Sendable {
    var categories: [(name: String, pairs: [(String, String)])]?
    var pairs: [(String, String)]?
    /// Absent (nil) when the gateway sent no metadata or a value of the wrong type (`{"commands": []}`).
    var commands: [String: CommandCatalogMeta]?
    var canon: [String: String]?
    var skills: [String: SkillCatalogEntry]?
    var warning: String?

    init(categories: [(name: String, pairs: [(String, String)])]? = nil, pairs: [(String, String)]? = nil,
         commands: [String: CommandCatalogMeta]? = nil, canon: [String: String]? = nil,
         skills: [String: SkillCatalogEntry]? = nil, warning: String? = nil) {
        self.categories = categories; self.pairs = pairs; self.commands = commands; self.canon = canon
        self.skills = skills; self.warning = warning
    }

    init(json: JSONValue) {
        func pairList(_ value: JSONValue?) -> [(String, String)]? {
            guard let rows = value?.array else { return nil }
            return rows.compactMap { row in
                guard let a = row.array, let command = a.first?.string else { return nil }
                return (command, a.count > 1 ? (a[1].string ?? "") : "")
            }
        }
        if let cats = json["categories"]?.array {
            categories = cats.compactMap { c in
                guard c.object != nil else { return nil }
                return (c["name"]?.string ?? "", pairList(c["pairs"]) ?? [])
            }
        }
        pairs = pairList(json["pairs"])
        if let object = json["commands"]?.object {
            var out: [String: CommandCatalogMeta] = [:]
            for (name, meta) in object {
                out[name] = CommandCatalogMeta(argumentMode: meta["argument_mode"]?.string, desktop: meta["desktop"]?.string)
            }
            commands = out
        }
        if let object = json["canon"]?.object {
            var out: [String: String] = [:]
            for (k, v) in object { if let s = v.string { out[k] = s } }
            canon = out
        }
        if let object = json["skills"]?.object {
            var out: [String: SkillCatalogEntry] = [:]
            for (k, v) in object { out[k] = SkillCatalogEntry(usage: v["usage"]?.int, origin: v["origin"]?.string) }
            skills = out
        }
        warning = json["warning"]?.nonEmptyString
    }
}

// MARK: - The local command table

/// How the phone fulfils a command (`DesktopCommandSurface`).
nonisolated enum SlashSurface: Hashable, Sendable {
    case action(String)                      // stop, title, reasoning, yolo, help, new, …
    case picker(String)                      // model | session
    case rpc(String)                         // session.status, session.save
    case exec
    case unavailable(String)                 // terminal | messaging | settings | advanced | composer-voice
}

nonisolated struct SlashSpec: Hashable, Sendable {
    var name: String
    var description: String?
    var aliases: [String] = []
    var surface: SlashSurface
    var hidden = false
    var argumentMode: String?
}

nonisolated enum SlashCatalog {
    /// `DESKTOP_COMMAND_SPECS` (V:lib/desktop-slash-commands.ts:179-304).
    static let localSpecs: [SlashSpec] = [
        SlashSpec(name: "/new", description: "Start a new chat", aliases: ["/reset", "/clear"], surface: .action("new")),
        SlashSpec(name: "/stop", description: "Stop the active turn and background processes", surface: .action("stop")),
        SlashSpec(name: "/branch", description: "Branch the latest message into a new chat", aliases: ["/fork"], surface: .action("branch")),
        SlashSpec(name: "/yolo", description: "Toggle YOLO — auto-approve dangerous commands", surface: .action("yolo")),
        SlashSpec(name: "/reasoning", description: "Reasoning effort or display [<level> [--global]|show|hide|full|clamp]",
                  surface: .action("reasoning"), argumentMode: "options"),
        SlashSpec(name: "/wake", description: "Control the desktop wake-word listener [on|off|status]", surface: .action("wake"),
                  argumentMode: "options"),
        SlashSpec(name: "/handoff", description: "Hand off this session to a messaging platform", surface: .action("handoff"),
                  argumentMode: "options"),
        SlashSpec(name: "/profile", description: "Switch the active Hermes profile", surface: .action("profile")),
        SlashSpec(name: "/skin", description: "Switch desktop theme or cycle to the next one", surface: .action("skin"), argumentMode: "options"),
        SlashSpec(name: "/title", description: "Rename the current session", surface: .action("title"), argumentMode: "text"),
        SlashSpec(name: "/help", description: "Show desktop slash commands", aliases: ["/commands"], surface: .action("help")),
        SlashSpec(name: "/browser", description: "Manage browser CDP connection [connect|disconnect|status] (local gateway only)",
                  surface: .action("browser"), argumentMode: "options"),
        SlashSpec(name: "/journey", description: "Open the memory graph — skills + memories over time", aliases: ["/learning", "/memory-graph"],
                  surface: .action("journey")),
        SlashSpec(name: "/model", description: "Switch the model for this session", surface: .picker("model"), hidden: true),
        SlashSpec(name: "/resume", description: "Resume a saved session", aliases: ["/sessions", "/switch"], surface: .picker("session"),
                  argumentMode: "mixed"),
        SlashSpec(name: "/compress", description: "Compress this conversation context", aliases: ["/compact"], surface: .action("compress"),
                  argumentMode: "text"),
        SlashSpec(name: "/btw", description: "Ask a side question about this conversation without interrupting it", surface: .action("btw"),
                  argumentMode: "text"),
        SlashSpec(name: "/bg", description: "Run a prompt in a background session", aliases: ["/background"], surface: .action("background"),
                  argumentMode: "text"),
        SlashSpec(name: "/pet", description: "Toggle or adopt a petdex mascot (/pet, /pet list, /pet boba)", surface: .action("pet"),
                  argumentMode: "options"),
        SlashSpec(name: "/hatch", description: "Generate a new pet (opens the pet generator)", aliases: ["/generate-pet"],
                  surface: .action("hatch")),
        SlashSpec(name: "/save", description: "Save the current transcript to JSON", surface: .rpc("session.save")),
        SlashSpec(name: "/status", description: "Show current session status", surface: .rpc("session.status")),
    ]

    static let specByName: [String: SlashSpec] = Dictionary(localSpecs.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    static let aliasToCanonical: [String: String] = {
        var out: [String: String] = [:]
        for spec in localSpecs { for alias in spec.aliases { out[alias] = spec.name } }
        return out
    }()

    /// Desktop actions the phone can't do yet (spec 1x §8.2 ⚑ DECISION): hidden from the sheet; typed, they answer
    /// "/<name> isn't available in HQ Native yet." and never reach `slash.exec`. /new and /compress have their own
    /// answers (docs/spec/3x-composer.md §8.2, §8.3; SlashRunner.swift).
    static let nativeUnsupported: Set<String> = ["branch", "fork", "resume",
        "sessions", "switch", "profile", "skin", "wake", "handoff", "browser", "journey", "learning", "memory-graph", "pet",
        "hatch", "generate-pet"]

    /// Commands with nothing to show on a phone (S:fe-convo-r4.ts:80-85).
    static let phoneHidden: Set<String> = ["timestamps", "ts", "focus", "egress", "codex-runtime", "codex_runtime", "debug", "worktree"]

    // MARK: Resolution (`resolveDesktopCommand`)

    /// "/Name args" → "/name".
    static func normalize(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let slashed = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        return (slashed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? "").lowercased()
    }

    /// "Name args" → "name" (no slash).
    static func bareName(_ command: String) -> String { String(normalize(command).dropFirst()) }

    static func canonical(_ command: String, catalog: CommandsCatalog?) -> String {
        let n = normalize(command)
        return aliasToCanonical[n] ?? catalogCanonical(n, catalog) ?? n
    }

    private static func catalogCanonical(_ normalized: String, _ catalog: CommandsCatalog?) -> String? {
        guard let canon = catalog?.canon else { return nil }
        return canon[normalized] ?? canon[normalized.lowercased()]
    }

    static func catalogMeta(_ command: String, catalog: CommandsCatalog?) -> CommandCatalogMeta? {
        guard let commands = catalog?.commands else { return nil }
        let n = normalize(command)
        let c = aliasToCanonical[n] ?? catalogCanonical(n, catalog) ?? n
        return commands[c] ?? commands[n]
    }

    private static let unavailableReasons: Set<String> = ["advanced", "composer-voice", "messaging", "settings", "terminal"]
    private static let argumentModes: Set<String> = ["options", "text", "mixed"]

    private static func specFromCatalog(_ command: String, catalog: CommandsCatalog?) -> SlashSpec? {
        guard let meta = catalogMeta(command, catalog: catalog) else { return nil }
        let name = canonical(command, catalog: catalog)
        if let reason = meta.desktop, unavailableReasons.contains(reason) { return SlashSpec(name: name, surface: .unavailable(reason)) }
        return SlashSpec(name: name, surface: .exec, hidden: meta.desktop == "hidden",
                         argumentMode: meta.argumentMode.flatMap { argumentModes.contains($0) ? $0 : nil })
    }

    /// A command's surface: the local table wins, else the catalog's metadata; nil = an extension (skill, quick, plugin).
    static func resolve(_ command: String, catalog: CommandsCatalog?) -> SlashSpec? {
        specByName[canonical(command, catalog: catalog)] ?? specFromCatalog(command, catalog: catalog)
    }

    static func isAlias(_ command: String, catalog: CommandsCatalog?) -> Bool {
        let n = normalize(command)
        if aliasToCanonical[n] != nil { return true }
        guard let resolved = catalogCanonical(n, catalog) else { return false }
        return resolved.lowercased() != n
    }

    private static func isKnown(_ command: String, catalog: CommandsCatalog?) -> Bool {
        let n = normalize(command)
        if specByName[n] != nil || aliasToCanonical[n] != nil { return true }
        return catalogMeta(n, catalog: catalog) != nil
    }

    /// Not one of Hermes' built-in commands: a skill, a quick command, a plugin command.
    static func isExtension(_ command: String, catalog: CommandsCatalog?) -> Bool {
        let n = normalize(command)
        guard !n.isEmpty, n != "/" else { return false }
        return !isKnown(n, catalog: catalog)
    }

    /// Offered in the list (`isDesktopSlashSuggestion`): not an alias, not unavailable, not hidden — or an extension.
    static func isSuggestion(_ command: String, catalog: CommandsCatalog?) -> Bool {
        let n = normalize(command)
        if isAlias(n, catalog: catalog) { return false }
        if let spec = resolve(n, catalog: catalog) {
            if case .unavailable = spec.surface { return false }
            return !spec.hidden
        }
        return isExtension(n, catalog: catalog)
    }

    static func argumentMode(_ command: String, catalog: CommandsCatalog?) -> String? {
        if let mode = resolve(command, catalog: catalog)?.argumentMode { return mode }
        return catalogMeta(command, catalog: catalog)?.argumentMode.flatMap { argumentModes.contains($0) ? $0 : nil }
    }

    /// The web's line for a known command with no desktop surface (V:lib/desktop-slash-commands.ts:475-482).
    static func unavailableMessage(_ reason: String, command: String) -> String {
        switch reason {
        case "advanced":
            return "\(command) is not shown in the desktop slash palette. Use the relevant desktop control or terminal interface instead."
        case "composer-voice":
            return "Voice chat lives in the composer here: click the microphone button and choose \"Start voice chat\", or use the voice shortcut from Settings → Keyboard Shortcuts."
        case "messaging": return "\(command) is only used from messaging platforms."
        case "settings": return "\(command) is managed from the desktop sidebar."
        default: return "\(command) is only available in the terminal interface."
        }
    }

    // MARK: Descriptions

    /// `composer.commandDescs` (V:i18n/en.ts:3845-3918), keyed by canonical command.
    static let commandDescriptions: [String: String] = [
        "/help": "Show desktop slash commands", "/clear": "start a new session", "/resume": "Resume a saved session",
        "/details": "control transcript detail level", "/copy": "copy selection or last assistant message", "/quit": "exit hermes",
        "/start": "Acknowledge platform start pings without a reply", "/new": "Start a new chat",
        "/topic": "Enable or inspect Telegram DM topic sessions", "/save": "Save the current transcript to JSON",
        "/retry": "Retry the last message (resend to agent)", "/prompt": "Compose your next prompt in $EDITOR (markdown), then send it",
        "/undo": "Back up N user turns and re-prompt (default 1)", "/title": "Rename the current session",
        "/handoff": "Hand off this session to a messaging platform", "/branch": "Branch the latest message into a new chat",
        "/worktree": "Show, list, create, or prune isolated git worktrees", "/compress": "Compress this conversation context",
        "/rollback": "List or restore filesystem checkpoints (restores keep your hand-edits; --all overrides)",
        "/export": "Export a profile (config, skills, theme) to a shareable archive",
        "/import": "Import a shared profile archive as a new profile", "/stop": "Stop the active turn and background processes",
        "/pause": "Pause new work globally (emergency stop); '/pause off' resumes",
        "/bg": "Run a prompt in a separate background session",
        "/btw": "Ask a side question about this conversation without interrupting it",
        "/agents": "Show active agents and running tasks", "/journey": "Open the memory graph — skills + memories over time",
        "/queue": "Queue a prompt for the next turn, or list/edit/rm/move/clear queued prompts",
        "/steer": "Inject a message after the next tool call without interrupting",
        "/goal": "Set a standing goal Hermes works on across turns until achieved",
        "/heartbeat": "Set a recurring prompt that re-enters this session when idle",
        "/refine": "Review this conversation now and save lessons to memory/skills",
        "/review": "Spawn an independent subagent to review the work just discussed (PR, code, docs)",
        "/loop": "Re-run a prompt on a recurring interval in this session",
        "/plan": "Write a markdown implementation plan to .hermes/plans/ without executing anything",
        "/moa": "Run one prompt through the default Mixture of Agents preset, then restore your model",
        "/subgoal": "Add or manage extra criteria on the active goal", "/status": "Show current session status",
        "/egress": "Show Docker egress proxy status",
        "/context": "Show detailed context window view with usage gauge, category breakdown, compression stats, and throughput",
        "/whoami": "Show your slash command access (admin / user)", "/profile": "Switch the active Hermes profile",
        "/codex-runtime": "Toggle codex app-server runtime for OpenAI/Codex models", "/personality": "Set a predefined personality",
        "/battery": "Toggle a color-coded battery indicator in the status bar",
        "/timestamps": "Toggle [HH:MM] timestamps on messages and /history", "/diff": "Show git changes in the working directory",
        "/focus": "Toggle focus view — show only your prompt and the final response",
        "/yolo": "Toggle YOLO — auto-approve dangerous commands",
        "/approvals": "Show or set the persistent dangerous-command approval mode",
        "/reasoning": "Reasoning effort or display [<level> [--global]|show|hide|full|clamp]",
        "/skin": "Switch desktop theme or cycle to the next one", "/wake": "Control the desktop wake-word listener [on|off|status]",
        "/tools": "Manage tools: /tools [list|disable|enable] [name...]", "/memory": "Review pending memory writes / toggle the approval gate",
        "/bundles": "List skill bundles (aliases /<name> for multiple skills)",
        "/pet": "Toggle or adopt a petdex mascot (/pet, /pet list, /pet boba)", "/hatch": "Generate a new pet (opens the pet generator)",
        "/learn": "Learn a reusable skill from anything you describe (dirs, URLs, this chat, notes)",
        "/init": "Generate or update AGENTS.md project instructions from a repo scan",
        "/suggestions": "Review suggested automations (accept/dismiss)", "/blueprint": "Set up an automation from a blueprint template",
        "/browser": "Manage browser CDP connection [connect|disconnect|status] (local gateway only)",
        "/palette": "Open the fuzzy command palette (also Ctrl+P)",
        "/usage": "Show token usage and rate limits; `reset` redeems a banked Codex limit reset",
        "/subscription": "View your Nous plan and change it in the browser",
        "/topup": "Show your Nous balance and manage billing on the portal",
        "/platform": "Pause, resume, or list a failing gateway platform", "/version": "Show Hermes Agent version",
        "/debug": "Upload debug report (system info + logs) and get shareable links", "/model": "Switch the model for this session",
    ]

    /// Native's /help opens this sheet (spec 1x §7.2 ⚑ DECISION).
    static let helpDescription = "Show the commands list"

    private static let usageSuffix = try! NSRegularExpression(pattern: #"\s+\(usage:\s+(.+)\)$"#, options: [.dotMatchesLineSeparators])

    /// `desktopSlashDescription`: the English override, else the local spec's, else the catalog's text; a catalog
    /// " (usage: …)" suffix is kept.
    static func desktopDescription(_ command: String, fallback: String, catalog: CommandsCatalog?) -> String {
        let c = canonical(command, catalog: catalog)
        let description = appStoreDescriptionOverride(c) ?? commandDescriptions[c] ?? specByName[c]?.description
        guard let description else { return fallback }
        let usage = Rx.firstMatch(usageSuffix, fallback)?.whole ?? ""
        return description + usage
    }

    /// [app-store-review] Guideline 3.1.1: /subscription and /topup must not point at a portal or browser to pay, in
    /// the App Store build.
    private static func appStoreDescriptionOverride(_ command: String) -> String? {
        #if APP_STORE
        switch command {
        case "/subscription": return "Show your Nous plan"
        case "/topup": return "Show your Nous balance"
        default: return nil
        }
        #else
        return nil
        #endif
    }

    /// Known commands in plain words (S:fe-convo-r5.ts:200-206).
    static let plainWords: [String: String] = [
        "reasoning": "Reasoning effort, or show or hide the reasoning", "usage": "Token usage and rate limits",
        "tools": "Turn tools on or off", "rollback": "List or restore file checkpoints", "bundles": "List skill bundles",
        "pet": "Show or adopt a pet mascot", "browser": "Connect the gateway’s browser", "pause": "Pause all new work (emergency stop)",
        "undo": "Go back and re-prompt", "queue": "Queue a prompt for the next turn",
        "platform": "Pause, resume or list a messaging platform", "prompt": "Compose your next prompt, then send it",
        "clear": "Start a new session", "details": "Transcript detail level", "copy": "Copy the last reply", "quit": "Exit Hermes",
    ]

    private static let backticks = try! NSRegularExpression(pattern: "`([^`]*)`")
    private static let commandParens = try! NSRegularExpression(
        pattern: #"\s*\((?:[^()]*?(?:\/\w|--\w|\baliases?\b|\be\.g\.)[^()]*)\)"#, options: [.caseInsensitive])
    private static let colonCommandTail = try! NSRegularExpression(pattern: #":\s*\/\w[\s\S]*$"#)
    private static let semicolonTail = try! NSRegularExpression(
        pattern: #";\s*(?:['"]?\/\w|\w+\s+(?:redeems|resets|resumes))[\s\S]*$"#, options: [.caseInsensitive])
    private static let flags = try! NSRegularExpression(pattern: #"\s--?[\w-]+"#)
    private static let pipes = try! NSRegularExpression(pattern: #"\s*\|\s*"#)
    private static let spaces = try! NSRegularExpression(pattern: #"\s+"#)
    private static let trailing = try! NSRegularExpression(pattern: #"[\s;:,.|]+$"#)

    /// A description without its terminal syntax (`slashDescription`, S:fe-convo-r5.ts:207-228).
    static func plainDescription(_ command: String, _ text: String?) -> String {
        let name = bareName(command)
        if name == "help" { return helpDescription }
        if let plain = plainWords[name] { return plain }
        var out = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return out }
        out = Rx.replace(backticks, in: out, with: "$1")
        out = Rx.replace(commandParens, in: out, with: "")
        out = Rx.replace(colonCommandTail, in: out, with: "")
        out = Rx.replace(semicolonTail, in: out, with: "")
        var depth = 0
        var kept = ""
        for ch in out {
            if ch == "[" || ch == "<" { depth += 1; continue }
            if (ch == "]" || ch == ">") && depth > 0 { depth -= 1; continue }
            if depth == 0 { kept.append(ch) }
        }
        out = Rx.replace(flags, in: kept, with: "")
        out = Rx.replace(pipes, in: out, with: " ")
        out = Rx.replace(spaces, in: out, with: " ")
        out = Rx.replace(trailing, in: out, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = out.first else { return out }
        return first.uppercased() + out.dropFirst()
    }

    // MARK: Sections (`commandSections`, `filterSections`)

    nonisolated struct Row: Hashable, Sendable {
        var command: String          // "/status"
        var description: String
        var skill: Bool
    }

    nonisolated struct Section: Hashable, Sendable {
        var title: String
        var rows: [Row]
    }

    private static func withSlash(_ command: String) -> String { command.hasPrefix("/") ? command : "/" + command }

    /// Listed nowhere in the sheet itself: /help (and /commands) only reopen this same sheet, a dead end from inside it
    /// (owner: hide dead controls, MEM/glitch-sweep.md). Typed, they still open it.
    static let sheetOnly: Set<String> = ["help", "commands"]

    /// [composer-drawers] Commands the desktop leaves to its own picker (hidden from its suggestions) that the slash
    /// drawer still lists, because a pick opens the phone's picker (docs/spec/3x-composer.md §9.6 check 2: "/mo" → /model).
    static let drawerPickers: Set<String> = ["model"]

    /// Shown on the phone: the desktop filter, then the phone-hidden and native-unsupported names (spec 1x §7.2 step 3),
    /// /help, and /title in a bot's own chat (it only ever answers that the chat keeps its name).
    /// `forDrawer`: the slash drawer (docs/spec/3x-composer.md §9.2) lists /help too: from the drawer it opens this
    /// sheet, which is no dead end.
    static func isListed(_ command: String, catalog: CommandsCatalog, isBotChat: Bool = false, forDrawer: Bool = false) -> Bool {
        let name = bareName(command)
        if (!forDrawer && sheetOnly.contains(name)) || (isBotChat && name == "title") { return false }
        if forDrawer, drawerPickers.contains(name), catalog.commands?[withSlash(name)] != nil || resolve(withSlash(name), catalog: catalog) != nil {
            return true
        }
        return isSuggestion(command, catalog: catalog) && !phoneHidden.contains(name) && !nativeUnsupported.contains(name)
    }

    /// The catalog as the Commands sheet's sections: its own categories, then "Skills" (ranked by use, never-used
    /// bundled skills dropped). `isBotChat`: the bot's own chat (no /title).
    static func sections(_ catalog: CommandsCatalog, isBotChat: Bool = false, forDrawer: Bool = false) -> [Section] {
        var seen = Set<String>()
        func row(_ command: String, _ meta: String, skill: Bool) -> Row {
            seen.insert(withSlash(command).lowercased())
            let described = desktopDescription(command, fallback: meta, catalog: catalog)
            return Row(command: withSlash(command), description: plainDescription(command, described), skill: skill)
        }
        let groups: [(name: String, pairs: [(String, String)])] = (catalog.categories?.isEmpty == false)
            ? catalog.categories! : [("Commands", catalog.pairs ?? [])]
        var out: [Section] = groups.map { group in
            Section(title: group.name.isEmpty ? "Commands" : group.name,
                    rows: group.pairs.filter { isListed($0.0, catalog: catalog, isBotChat: isBotChat, forDrawer: forDrawer) }.map { row($0.0, $0.1, skill: false) })
        }
        let extensions = (catalog.pairs ?? []).filter { command, _ in
            !seen.contains(withSlash(command).lowercased()) && isExtension(command, catalog: catalog)
                && isListed(command, catalog: catalog, isBotChat: isBotChat, forDrawer: forDrawer)
        }
        let skills = rankSkills(extensions, skills: catalog.skills, catalog: catalog, pruneUnusedBuiltins: true)
        if !skills.isEmpty { out.append(Section(title: "Skills", rows: skills.map { row($0.0, $0.1, skill: true) })) }
        return out.filter { !$0.rows.isEmpty }
    }

    /// Most-used first, A–Z within a tie (`rankSkillCommands`); `pruneUnusedBuiltins` drops bundled skills never used.
    static func rankSkills(_ rows: [(String, String)], skills: [String: SkillCatalogEntry]?, catalog: CommandsCatalog?,
                           pruneUnusedBuiltins: Bool) -> [(String, String)] {
        guard let skills else { return rows }
        func entry(_ row: (String, String)) -> SkillCatalogEntry? { skills[canonical(row.0, catalog: catalog)] }
        func usage(_ row: (String, String)) -> Int { entry(row)?.usage ?? 0 }
        let kept = pruneUnusedBuiltins ? rows.filter { row in
            guard let e = entry(row) else { return true }
            return e.origin != "bundled" || (e.usage ?? 0) > 0
        } : rows
        return kept.enumerated().sorted { a, b in
            let ua = usage(a.element), ub = usage(b.element)
            if ua != ub { return ua > ub }
            let order = a.element.0.localizedCompare(b.element.0)
            if order != .orderedSame { return order == .orderedAscending }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// [favorite-commands] The section starred commands lead both lists with (docs/spec/3x-composer.md §9.7).
    static let favoritesTitle = "Favorites"

    /// The starred rows in starred order, taken from `sections` (a starred command this chat doesn't list isn't
    /// shown); nil when none is listed. The rows stay in their own sections too, as starred models do.
    static func favoritesSection(_ sections: [Section], favorites: [String]) -> Section? {
        guard !favorites.isEmpty else { return nil }
        var byName: [String: Row] = [:]
        for row in sections.flatMap(\.rows) where byName[normalize(row.command)] == nil { byName[normalize(row.command)] = row }
        let rows = favorites.compactMap { byName[normalize($0)] }
        return rows.isEmpty ? nil : Section(title: favoritesTitle, rows: rows)
    }

    /// Rows whose command or description holds every typed word (a leading "/" ignored).
    static func filter(_ sections: [Section], query: String) -> [Section] {
        var q = query.lowercased()
        if q.hasPrefix("/") { q.removeFirst() }
        let words = q.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return sections }
        return sections.map { section in
            Section(title: section.title, rows: section.rows.filter { row in
                let text = "\(row.command) \(row.description)".lowercased()
                return words.allSatisfy { text.contains($0) }
            })
        }.filter { !$0.rows.isEmpty }
    }

    /// [mac-popups] Mac polish #23: the ☰ Commands pop-up's order for a search (after `filter`), the slash drawer's
    /// (`ComposerDrawerModel.rank`, `favoritesFirst`): names that start with the typing (starred ones first, in starred
    /// order), then names that hold it, then rows found only by their description; a section led by a better match goes
    /// first, so the row the pop-up marks for Return is the best one ("st" marked /new, "Start a new chat", over /stop).
    static func ranked(_ sections: [Section], query: String, favorites: [String] = []) -> [Section] {
        var q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.hasPrefix("/") { q.removeFirst() }
        guard !q.isEmpty else { return sections }
        let starred = Dictionary(favorites.enumerated().map { (normalize($0.element), $0.offset) }, uniquingKeysWith: { a, _ in a })
        /// (tier, place among the starred, place in the list): smaller goes first.
        func rank(_ row: Row?, _ offset: Int) -> (Int, Int, Int) {
            guard let row else { return (4, 0, offset) }
            let name = bareName(row.command)
            if name.hasPrefix(q) { return starred[normalize(row.command)].map { (0, $0, offset) } ?? (1, 0, offset) }
            return (name.contains(q) ? 2 : 3, 0, offset)
        }
        let ordered = sections.map { section in
            Section(title: section.title, rows: section.rows.enumerated()
                .sorted { rank($0.element, $0.offset) < rank($1.element, $1.offset) }.map(\.element))
        }
        return ordered.enumerated()
            .sorted { rank($0.element.rows.first, $0.offset) < rank($1.element.rows.first, $1.offset) }
            .map(\.element)
    }

    nonisolated enum PickAction: Equatable, Sendable { case send, models, insert }

    /// What a pick does (`pickAction`, S:ui-chat/commands.ts:52-56): a skill or a command that takes more inserts
    /// "/cmd "; /model opens the Models sheet; anything else sends.
    static func pickAction(_ row: Row, catalog: CommandsCatalog?) -> PickAction {
        if row.skill { return .insert }
        let surface = resolve(row.command, catalog: catalog)?.surface
        if surface == .picker("model") { return .models }
        if case .picker = surface { return .insert }
        return argumentMode(row.command, catalog: catalog) == nil ? .send : .insert
    }

    /// The words of a pick that asks first.
    nonisolated struct PickConfirmation: Equatable, Sendable {
        var title: String
        var message: String
        var button: String
    }

    /// A pick sends (owner: Telegram's behaviour), but the few that change the session at once and are hard to take
    /// back ask first: /yolo turning approvals off (turning it back on doesn't ask), /pause, /undo. Nil: it just sends.
    static func confirmation(_ command: String, yoloOn: Bool) -> PickConfirmation? {
        switch bareName(command) {
        case "yolo":
            yoloOn ? nil : PickConfirmation(title: "Turn On YOLO?",
                                            message: "Dangerous commands will run without asking you first, until you run /yolo again.",
                                            button: "Turn On")
        case "pause":
            PickConfirmation(title: "Pause All Work?", message: "New work stops until it’s resumed.", button: "Pause")
        case "undo":
            PickConfirmation(title: "Undo the Last Turn?", message: "Your last message and its reply are taken back, so you can prompt again.",
                             button: "Undo")
        default: nil
        }
    }
}

// MARK: - Slash text (SH:slash.ts:9-39)

nonisolated enum SlashCommand {
    private static let commandPattern = try! NSRegularExpression(pattern: #"^/[^\s/]*(?:\s|$)"#)

    /// `/usage`, `/plan do it` are commands; `/usr/local/bin` and `run /x` are prose. Tested on the trimmed text.
    static func matches(_ text: String) -> Bool {
        Rx.matches(commandPattern, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Name (lower-cased, no slash; "" for "/", "/ words") and the argument with only its outer whitespace trimmed.
    static func parse(_ command: String) -> (name: String, arg: String) {
        var s = Substring(command)
        while s.first == "/" { s = s.dropFirst() }
        guard let first = s.first, !first.isWhitespace else { return ("", "") }
        let end = s.firstIndex(where: { $0.isWhitespace }) ?? s.endIndex
        let name = String(s[..<end]).lowercased()
        let arg = String(s[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (name, arg)
    }
}

// MARK: - Cache (spec 1x §3.5: 1 hour per key)

final class CommandsCatalogCache {
    static let shared = CommandsCatalogCache()
    static let freshFor: Duration = .seconds(3600)

    struct Key: Hashable {
        var account: String
        /// "session:<runtime>" or "profile:<p>".
        var scope: String
    }

    private var entries: [Key: (catalog: CommandsCatalog, at: ContinuousClock.Instant)] = [:]
    /// The newest catalog per account and profile, whatever its scope: typed commands resolve against it.
    private var latest: [String: CommandsCatalog] = [:]

    func fresh(_ key: Key, now: ContinuousClock.Instant = .now) -> CommandsCatalog? {
        guard let e = entries[key], now - e.at < Self.freshFor else { return nil }
        return e.catalog
    }

    func cached(_ key: Key) -> CommandsCatalog? { entries[key]?.catalog }

    func store(_ catalog: CommandsCatalog, for key: Key, profile: String) {
        entries[key] = (catalog, .now)
        latest[key.account + "|" + profile] = catalog
    }

    func latest(account: String, profile: String) -> CommandsCatalog? { latest[account + "|" + profile] }

    func forget(account: String) {
        entries = entries.filter { $0.key.account != account }
        latest = latest.filter { !$0.key.hasPrefix(account + "|") }
    }
}
