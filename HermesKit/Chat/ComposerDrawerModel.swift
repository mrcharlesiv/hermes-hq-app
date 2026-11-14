// [composer-drawers] The slash drawer and the @ drawer that open above the composer as you type
// (docs/spec/3x-composer.md §9, §10; web `V/hooks/use-slash-completions.ts`, `use-at-completions.ts`,
// `S/fe-convo-r4.ts` r4-99, `S/fe-convo-r5.ts` r5-96). Pure: what opens for a text and caret, which rows show for a
// catalog and a gateway answer, what a pick does to the field, and which gateway answer is still wanted. The drawer's
// view and its calls live in App/Chat/ComposerDrawer.swift.

import Foundation

nonisolated enum ComposerDrawerModel {
    // MARK: - Triggers

    /// What the text before the caret asks for. Ranges are UTF-16 (the text view's own offsets).
    enum Mode: Equatable, Sendable {
        case closed
        /// The whole field is a command being typed (caret at the end): `text` is the field ("/mo", "/reasoning h").
        case slash(text: String)
        /// A "/word" typed after a space mid-text: skills only. `range` is the "/word" before the caret.
        case skill(word: String, range: NSRange)
        /// An "@word" before the caret: `word` is what follows the "@" ("file:src/"). `range` covers "@word".
        case at(word: String, range: NSRange)

        var isOpen: Bool { self != .closed }
        var isSlash: Bool { if case .slash = self { return true } else { return false } }
    }

    private static func isLetter(_ u: UInt16) -> Bool { (u >= 65 && u <= 90) || (u >= 97 && u <= 122) }
    private static func isWord(_ u: UInt16) -> Bool { isLetter(u) || (u >= 48 && u <= 57) || u == 95 }
    private static func isSpace(_ u: UInt16) -> Bool {
        // JavaScript's \s, in UTF-16 units.
        switch u {
        case 9, 10, 11, 12, 13, 32, 160, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
        case 0x2000...0x200A: return true
        default: return false
        }
    }

    /// The drawer's trigger for `text` with the caret at `caret` (UTF-16 offset). Groups' rooms never call this.
    /// The @ trigger wins when the word under the caret starts with "@" (a ref typed into a command's argument).
    static func mode(text: String, caret: Int) -> Mode {
        let units = Array(text.utf16)
        let caret = max(0, min(caret, units.count))
        let before = Array(units[..<caret])
        if let at = atTrigger(before) { return at }
        if caret == units.count, wholeFieldSlash(before) { return .slash(text: text) }
        if let skill = inlineSkill(before) { return skill }
        return .closed
    }

    /// `^(\/)((?:[a-zA-Z][\w-]*(?:\s+\S*)*)?)$`: "/" alone, or "/name" then anything after white space.
    static func wholeFieldSlash(_ units: [UInt16]) -> Bool {
        guard units.first == 47 else { return false }
        if units.count == 1 { return true }
        guard isLetter(units[1]) else { return false }
        var i = 2
        while i < units.count, isWord(units[i]) || units[i] == 45 { i += 1 }
        return i == units.count || isSpace(units[i])
    }

    /// `[\s](\/)([a-zA-Z][\w-]*)?$`: a "/word" after white space, at the caret.
    private static func inlineSkill(_ units: [UInt16]) -> Mode? {
        var start = units.count
        while start > 0, isWord(units[start - 1]) || units[start - 1] == 45 { start -= 1 }
        guard start > 0, units[start - 1] == 47 else { return nil }
        let slash = start - 1
        guard slash > 0, isSpace(units[slash - 1]) else { return nil }
        if start < units.count, !isLetter(units[start]) { return nil }
        let word = String(utf16CodeUnits: Array(units[slash...]), count: units.count - slash)
        return .skill(word: word, range: NSRange(location: slash, length: units.count - slash))
    }

    /// `(?:^|[\s])(@)([^\s@]*)$`: an "@word" at the start or after white space (never inside an e-mail address).
    private static func atTrigger(_ units: [UInt16]) -> Mode? {
        var start = units.count
        while start > 0, !isSpace(units[start - 1]), units[start - 1] != 64 { start -= 1 }
        guard start > 0, units[start - 1] == 64 else { return nil }
        let at = start - 1
        guard at == 0 || isSpace(units[at - 1]) else { return nil }
        let word = String(utf16CodeUnits: Array(units[start...]), count: units.count - start)
        return .at(word: word, range: NSRange(location: at, length: units.count - at))
    }

    // MARK: - Rows

    nonisolated struct Row: Hashable, Sendable {
        enum Action: Hashable, Sendable {
            /// A command row (whole field): what `SlashCatalog.pickAction` says, applied by the drawer.
            case command(String, skill: Bool)
            /// An argument completion: the field becomes `prefix + text`.
            case option(prefix: String, text: String)
            /// A skill typed mid-text: the "/word" becomes "/skill ".
            case skill(String, range: NSRange)
            /// "/resume <q>": open that chat.
            case openChat(String)
            /// An @ row: the "@word" becomes `text` (plus a space unless it ends in ":" or "/").
            case mention(String, range: NSRange)
            /// [mac-audit] The empty catalog's Check Again: reads the commands list fresh from Hermes.
            case checkAgain
            /// A loading, empty or folder-missing line: not tappable.
            case none
        }

        var id: String
        /// What the row says first: the command, the ref, the chat's title.
        var title: String
        /// Its plain-words description ("" for none).
        var detail: String
        var action: Action
        /// File and folder refs: the part before the last "/" (drawn quieter than the leaf). nil otherwise.
        var parent: String? = nil
        /// A bot row's profile (its robot head leads the row).
        var bot: String? = nil
        /// The loading row's spinner.
        var spinner = false

        var tappable: Bool { action != .none }
        /// VoiceOver: "<command>, <description>".
        var spokenLabel: String { detail.isEmpty ? title : "\(title), \(detail)" }
    }

    nonisolated struct Section: Hashable, Sendable {
        var title: String?
        var rows: [Row]
    }

    /// How a row's first line is set. A command reads as the Commands sheet's rows do, in the app's Body face, semibold
    /// (owner 2026-10-27, "the font size of all / commands in the pop up are oddly large": the monospaced face's wide,
    /// tall letters at Body's point size outsized every other list). An @ ref (a path, a folder, an @kind:) keeps a
    /// monospaced face; a bot, a chat, an option or a note is plain Body.
    enum TitleFace: Hashable, Sendable { case command, ref, plain }

    static func titleFace(_ row: Row) -> TitleFace {
        if row.bot != nil { return .plain }
        switch row.action {
        case .command, .skill: return .command
        case .mention: return .ref
        case .openChat, .checkAgain: return .plain
        case .option, .none:
            if row.parent != nil || row.title.hasPrefix("@") { return .ref }
            return row.title.hasPrefix("/") ? .command : .plain
        }
    }

    /// The command a row stars or unstars from the drawer ("/name", as the Commands sheet's star keeps it); nil for a
    /// row that is not a whole command (an option, a ref, a bot, a chat, a note). Spec 3x-composer §9.7.
    static func favoriteCommand(_ row: Row) -> String? {
        guard case .command(let command, _) = row.action else { return nil }
        let name = SlashCatalog.normalize(command)
        return name.count > 1 ? name : nil
    }

    /// The hold and right-click menus' wording for a command row (title, SF Symbol), as Sessions' project headers say
    /// it (owner 2026-10-31: "Need to be able to favorite the / commands"). `short` is the swipe button's word.
    static func favoriteAction(favorited: Bool) -> (title: String, image: String, short: String) {
        favorited ? ("Remove from Favorites", "star.slash", "Unfavorite") : ("Add to Favorites", "star", "Favorite")
    }

    static let loadingCommands = "Loading commands…"
    static let commandsFailed = "Couldn’t load commands. Type / again to retry."
    static let looking = "Looking…"
    static let noMatches = "No matches."
    static let noCommands = "No Commands Available"   // [mac-ui-issues] the Commands pop-up's own words (`CommandsSheetViewController.emptyTitle`)
    static let noCommandsText = "Hermes sent no commands or skills for this chat. Skills added on \(HostWord.phrase) show up here."
    static let checkAgain = "Check Again"
    static let folderMissing = "This chat’s folder isn’t on \(HostWord.phrase)."

    static func note(_ text: String, spinner: Bool = false) -> [Section] {
        [Section(title: nil, rows: [Row(id: "note", title: text, detail: "", action: .none, spinner: spinner)])]
    }

    /// [mac-audit] Owner 2026-11-02 (Mac audit #24): "/" with an empty catalog said only "No matches.", as if the typing
    /// were wrong. Hermes sent no commands at all, so it says that, as the Commands sheet's empty state does, with its
    /// Check Again (a fresh read) as the one row to pick.
    static func noCommandsNote() -> [Section] {
        [Section(title: nil, rows: [Row(id: "note", title: noCommands, detail: noCommandsText, action: .none),
                                    Row(id: "check-again", title: checkAgain, detail: "", action: .checkAgain)])]
    }

    // MARK: - Gateway answers

    /// One `complete.slash` / `complete.path` item (`{text, display?, meta?, kind?}`); items without a string `text`
    /// are dropped.
    nonisolated struct Item: Hashable, Sendable {
        var text: String
        var display: String?
        var meta: String
        var kind: String?
    }

    nonisolated struct Answer: Hashable, Sendable {
        var items: [Item]
        /// Python code-point offset into the asked text; nil when absent or not a usable number.
        var replaceFrom: Int?
    }

    static let maxItems = 200

    static func answer(_ json: JSONValue?, asked: String) -> Answer {
        let items = (json?["items"]?.array ?? []).prefix(maxItems).compactMap { item -> Item? in
            guard let text = item["text"]?.string?.replacingOccurrences(of: "\n", with: " "), !text.isEmpty, text.count <= 1_000 else { return nil }
            let display = item["display"]?.string.flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
            return Item(text: text, display: display?.replacingOccurrences(of: "\n", with: " "),
                        meta: String((item["meta"]?.string ?? "").prefix(300)).replacingOccurrences(of: "\n", with: " "),
                        kind: item["kind"]?.string)
        }
        var replaceFrom: Int?
        if case .number(let n)? = json?["replace_from"], n.isFinite, n == n.rounded(), n >= 0, Int(n) <= asked.unicodeScalars.count {
            replaceFrom = Int(n)
        }
        return Answer(items: items, replaceFrom: replaceFrom)
    }

    // MARK: - The slash drawer (§9.2)

    /// Chats `/resume <q>` offers (newest first, the bot's own).
    nonisolated struct RecentChat: Hashable, Sendable {
        var id: String
        var title: String
    }

    static let chatCommands: Set<String> = ["resume", "sessions", "switch"]

    /// What the slash drawer shows. nil = the drawer stays closed (no catalog and none coming, an argument stage with
    /// no options). `remote`: the gateway's answer for exactly `text` (nil while it is out, failed or unsupported).
    /// `catalogFailed`: the catalog's load failed, said in one line (the next "/" tries again).
    /// `favorites`: starred commands ("/name", in starred order): a bare "/" opens on them, and typed, the ones the
    /// words start lead (§9.7).
    /// `starredOnce`: a bare "/" lists a starred command under Favorites only, not again in its own section (the Mac).
    static func slashSections(text: String, catalog: CommandsCatalog?, catalogLoading: Bool, catalogFailed: Bool = false,
                              isBotChat: Bool, remote: Answer?, recent: [RecentChat], favorites: [String] = [],
                              starredOnce: Bool = false) -> [Section]? {
        let afterSlash = String(text.dropFirst())
        if let space = afterSlash.firstIndex(where: { $0.isWhitespace }) {
            let name = afterSlash[..<space].lowercased()
            if chatCommands.contains(name) {
                let query = afterSlash[space...].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let rows = recent.filter { query.isEmpty || $0.title.lowercased().contains(query) }.prefix(8)
                    .map { Row(id: "chat.\($0.id)", title: $0.title, detail: "", action: .openChat($0.id)) }
                return rows.isEmpty ? nil : [Section(title: "Chats", rows: Array(rows))]
            }
            return optionSections(text: text, remote: remote)
        }
        guard let catalog else {
            if catalogLoading { return note(loadingCommands, spinner: true) }
            return catalogFailed ? note(commandsFailed) : nil
        }
        let all = SlashCatalog.sections(catalog, isBotChat: isBotChat, forDrawer: true)
        let noneListed = all.allSatisfy(\.rows.isEmpty)
        let query = afterSlash.lowercased()
        if query.isEmpty {
            var shown = all.map { Section(title: $0.title, rows: $0.rows.map(commandRow)) }.filter { !$0.rows.isEmpty }
            if starredOnce {
                // [Mac UI check 2026-11-13] V22: a starred command is listed once, under Favorites (`favoritesLeading`).
                let hasStarred = SlashCatalog.favoritesSection(all, favorites: favorites) != nil
                let led = SlashCatalog.favoritesLeading(all, all: all, favorites: favorites)
                shown = led.enumerated().map { index, section in
                    let starred = hasStarred && index == 0
                    return Section(title: section.title, rows: section.rows.map { starred ? favoriteRow(commandRow($0)) : commandRow($0) })
                }.filter { !$0.rows.isEmpty }
            } else if let starred = SlashCatalog.favoritesSection(all, favorites: favorites) {
                shown.insert(Section(title: starred.title, rows: starred.rows.map { favoriteRow(commandRow($0)) }), at: 0)
            }
            return shown.isEmpty ? (noneListed ? noCommandsNote() : note(noMatches)) : shown
        }
        var sections: [Section] = []
        if let remote {
            sections = remoteCommandSections(remote, catalog: catalog, isBotChat: isBotChat)
        }
        // [Mac UI check 2026-11-13] V2: a gateway answer with nothing usable (no items, or only ones the filters drop)
        // said "No matches." for "/s" while the catalog held /status and /stop; the commands already held are ranked.
        if sections.isEmpty {
            sections = grouped(rank(all.flatMap(\.rows), query: query))
        }
        sections = favoritesFirst(sections, query: query, favorites: favorites)
        return sections.isEmpty ? (noneListed ? noCommandsNote() : note(noMatches)) : sections
    }

    /// A row in Favorites: its own id (the same command is listed again in its section below).
    private static func favoriteRow(_ row: Row) -> Row {
        var row = row
        row.id = "fav." + row.id
        return row
    }

    /// Typed: in each section, the starred commands whose names start with the words go first, in starred order;
    /// the rest keep their order.
    static func favoritesFirst(_ sections: [Section], query: String, favorites: [String]) -> [Section] {
        guard !favorites.isEmpty else { return sections }
        let q = query.lowercased()
        let order = Dictionary(favorites.enumerated().map { (SlashCatalog.normalize($0.element), $0.offset) }, uniquingKeysWith: { a, _ in a })
        func rank(_ row: Row) -> Int? {
            guard case .command(let command, _) = row.action, SlashCatalog.bareName(command).hasPrefix(q) else { return nil }
            return order[SlashCatalog.normalize(command)]
        }
        return sections.map { section in
            let starred = section.rows.compactMap { row in rank(row).map { (row, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
            guard !starred.isEmpty else { return section }
            let ids = Set(starred.map(\.id))
            return Section(title: section.title, rows: starred + section.rows.filter { !ids.contains($0.id) })
        }
    }

    /// Prefix matches first, then names that contain the query; within each, catalog order.
    static func rank(_ rows: [SlashCatalog.Row], query: String) -> [SlashCatalog.Row] {
        let q = query.lowercased()
        func name(_ row: SlashCatalog.Row) -> String { String(row.command.dropFirst()).lowercased() }
        let prefix = rows.filter { name($0).hasPrefix(q) }
        let contains = rows.filter { !name($0).hasPrefix(q) && name($0).contains(q) }
        return prefix + contains
    }

    private static func commandRow(_ row: SlashCatalog.Row) -> Row {
        Row(id: "cmd.\(row.command)", title: row.command, detail: row.description, action: .command(row.command, skill: row.skill))
    }

    /// Commands, then Skills (each de-duplicated by name).
    private static func grouped(_ rows: [SlashCatalog.Row]) -> [Section] {
        var seen = Set<String>()
        let unique = rows.filter { seen.insert($0.command.lowercased()).inserted }
        let commands = unique.filter { !$0.skill }.map(commandRow)
        let skills = unique.filter(\.skill).map(commandRow)
        return [Section(title: "Commands", rows: commands), Section(title: "Skills", rows: skills)].filter { !$0.rows.isEmpty }
    }

    /// A `complete.slash` item's command: its display when that is "/name", else "/" + its text.
    static func commandName(_ item: Item) -> String {
        if let display = item.display?.trimmingCharacters(in: .whitespaces), display.hasPrefix("/"),
           !display.contains(" ") { return display }
        let bare = item.text.trimmingCharacters(in: .whitespaces)
        return bare.hasPrefix("/") ? bare : "/" + bare
    }

    /// The gateway's command-stage items as rows: the phone's filters (desktop-only, not on a phone, no native
    /// answer), plain descriptions.
    static func remoteCommandSections(_ answer: Answer, catalog: CommandsCatalog?, isBotChat: Bool) -> [Section] {
        let rows = answer.items.compactMap { item -> SlashCatalog.Row? in
            let command = commandName(item)
            guard command.count > 1, !command.dropFirst().contains("/") else { return nil }
            let skill = item.kind == "skill"
            if !skill {
                let name = SlashCatalog.bareName(command)
                if SlashCatalog.phoneHidden.contains(name) || SlashCatalog.nativeUnsupported.contains(name) { return nil }
                if let catalog, !SlashCatalog.isListed(command, catalog: catalog, isBotChat: isBotChat, forDrawer: true) { return nil }
            }
            let described = SlashCatalog.desktopDescription(command, fallback: item.meta, catalog: catalog)
            return SlashCatalog.Row(command: command, description: SlashCatalog.plainDescription(command, described), skill: skill)
        }
        return grouped(rows)
    }

    /// The argument stage: the gateway's options only (none = closed).
    static func optionSections(text: String, remote: Answer?) -> [Section]? {
        guard let remote, !remote.items.isEmpty else { return nil }
        let prefix = optionPrefix(text: text, replaceFrom: remote.replaceFrom)
        var seen = Set<String>()
        let rows = remote.items.filter { seen.insert($0.text).inserted }.map { item in
            Row(id: "opt.\(item.text)", title: item.display ?? item.text, detail: item.meta, action: .option(prefix: prefix, text: item.text))
        }
        return [Section(title: "Options", rows: rows)]
    }

    /// The field up to `replace_from` (code points, as Python counts); without a usable offset, up to the last space.
    static func optionPrefix(text: String, replaceFrom: Int?) -> String {
        let scalars = Array(text.unicodeScalars)
        if let replaceFrom, replaceFrom >= 1, replaceFrom <= scalars.count {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[..<replaceFrom])
            return String(view)
        }
        guard let space = text.lastIndex(where: { $0 == " " }) else { return text }
        return String(text[...space])
    }

    /// Skills for a "/word" typed mid-text (nil = closed: prose with a slash in it shows nothing).
    static func skillSections(word: String, range: NSRange, catalog: CommandsCatalog?, isBotChat: Bool) -> [Section]? {
        guard let catalog else { return nil }
        let skills = SlashCatalog.sections(catalog, isBotChat: isBotChat, forDrawer: true).flatMap(\.rows).filter(\.skill)
        let ranked = rank(skills, query: String(word.dropFirst()))
        guard !ranked.isEmpty else { return nil }
        return [Section(title: "Skills", rows: ranked.map {
            Row(id: "skill.\($0.command)", title: $0.command, detail: $0.description, action: .skill($0.command, range: range))
        })]
    }

    // MARK: - The @ drawer (§10.2)

    nonisolated struct BotEntry: Hashable, Sendable {
        var profile: String          // "default", "claude"
        var name: String             // display name
    }

    static let starters: [(text: String, detail: String)] = [
        ("@file:", "Attach a file from the chat’s folder"), ("@folder:", "Attach a folder from the chat’s folder"),
        ("@url:", "Attach a web page"), ("@diff", "Changes not yet committed"), ("@staged", "Changes staged for commit"),
    ]

    static let metaWords: [String: String] = [
        "git diff": "Changes not yet committed", "staged diff": "Changes staged for commit",
        "attach file": "Attach a file from the chat’s folder", "attach folder": "Attach a folder from the chat’s folder",
        "fetch url": "Attach a web page", "git log": "Recent commits", "dir": "Folder",
    ]

    static let mainBot = "Your main bot"
    static let anotherBot = "Another bot"

    /// A gateway meta in plain words (`atDescription`); profile metas are named by `profileRow` instead.
    static func plainMeta(_ meta: String) -> String { metaWords[meta.trimmingCharacters(in: .whitespaces).lowercased()] ?? meta }

    static func isProfileMeta(_ meta: String) -> Bool { meta.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("agent profile") }

    /// The handle a bot is mentioned by: its profile, and the main bot (`default`) as "hermes", as the gateway offers it.
    static func handle(_ bot: BotEntry, among bots: [BotEntry]) -> String {
        bot.profile == "default" && !bots.contains(where: { $0.profile.lowercased() == "hermes" }) ? "hermes" : bot.profile
    }

    /// The bot a handle names (the main bot for "default" and for "hermes" when no bot is called that).
    static func profile(forHandle handle: String, among bots: [BotEntry]) -> String {
        let h = handle.lowercased()
        if h == "hermes", !bots.contains(where: { $0.profile.lowercased() == "hermes" }) { return "default" }
        return h
    }

    static func botDetail(_ profile: String, bots: [BotEntry]) -> String {
        if profile == "default" { return mainBot }
        return bots.first(where: { $0.profile.lowercased() == profile.lowercased() })?.name ?? anotherBot
    }

    /// The last path segment of a file or folder ref ("@file:src/.env" → ".env"); nil for other refs.
    static func refLeaf(_ text: String) -> String? {
        guard let colon = text.firstIndex(of: ":"), text.hasPrefix("@file:") || text.hasPrefix("@folder:") else { return nil }
        let path = text[text.index(after: colon)...]
        let trimmed = path.hasSuffix("/") ? path.dropLast() : path
        return trimmed.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    }

    /// The typed part after the last "/" (or after "file:").
    static func typedSegment(_ word: String) -> String {
        var q = Substring(word)
        for prefix in ["file:", "folder:"] where q.hasPrefix(prefix) { q = q.dropFirst(prefix.count) }
        return q.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    }

    /// A listing of the chat's own folder (`@file:…`, `@folder:…`).
    static func isFolderQuery(_ word: String) -> Bool { word.hasPrefix("file:") || word.hasPrefix("folder:") }

    /// The local Bots rows for `word` (empty or a plain word): every bot but this chat's, by handle or name prefix.
    static func botRows(word: String, bots: [BotEntry], own: String, range: NSRange) -> [Row] {
        let q = word.lowercased()
        let self_ = (own.isEmpty ? "default" : own).lowercased()
        return bots.filter { $0.profile.lowercased() != self_ }.compactMap { bot in
            let handle = handle(bot, among: bots)
            guard q.isEmpty || handle.lowercased().hasPrefix(q) || bot.name.lowercased().hasPrefix(q) else { return nil }
            return Row(id: "bot.\(handle)", title: "@" + handle, detail: botDetail(bot.profile, bots: bots),
                       action: .mention("@" + handle, range: range), bot: bot.profile)
        }
    }

    /// What the @ drawer shows (never nil: starters and Bots are local). `remote`: the answer for exactly `word`;
    /// `waiting`: a call for it is out or due; `failed`: it failed, the method is unsupported, or the phone is offline.
    static func atSections(word: String, range: NSRange, bots: [BotEntry], own: String, remote: Answer?, waiting: Bool,
                           failed: Bool, folderMissing: Bool, previous: [Section]?) -> [Section] {
        if word.isEmpty {
            let starts = starters.map { Row(id: "start.\($0.text)", title: $0.text, detail: $0.detail, action: .mention($0.text, range: range)) }
            var out = [Section(title: nil, rows: starts)]
            let botRows = botRows(word: "", bots: bots, own: own, range: range)
            if !botRows.isEmpty { out.append(Section(title: "Bots", rows: botRows)) }
            return out
        }
        if isFolderQuery(word), folderMissing { return note(Self.folderMissing) }
        let plainWord = !word.contains(":") && !word.contains("/")
        var botRows = plainWord ? botRows(word: word, bots: bots, own: own, range: range) : []
        var other: [Row] = []
        if let remote {
            let self_ = (own.isEmpty ? "default" : own).lowercased()
            let showDots = typedSegment(word).hasPrefix(".")
            var seen = Set(botRows.map(\.title))
            for item in remote.items {
                if !showDots, let leaf = refLeaf(item.text), leaf.hasPrefix(".") { continue }
                guard seen.insert(item.text).inserted else { continue }
                let isMention = item.text.range(of: #"^@[\w.-]+$"#, options: .regularExpression) != nil
                if isMention, isProfileMeta(item.meta) {
                    let handle = String(item.text.dropFirst())
                    let primary = item.meta.lowercased().contains("primary")
                    let profile = primary ? "default" : profile(forHandle: handle, among: bots)
                    if profile.lowercased() == self_ { continue }
                    if botRows.contains(where: { $0.bot?.lowercased() == profile.lowercased() }) { continue }
                    botRows.append(Row(id: "bot.\(handle)", title: item.text, detail: botDetail(profile, bots: bots),
                                       action: .mention(item.text, range: range), bot: profile))
                    continue
                }
                var row = Row(id: "item.\(item.text)", title: item.display ?? item.text, detail: plainMeta(item.meta),
                              action: .mention(item.text, range: range))
                if let leaf = refLeaf(item.text), let colon = item.text.firstIndex(of: ":") {
                    let path = String(item.text[item.text.index(after: colon)...])
                    let shownLeaf = leaf + (path.hasSuffix("/") ? "/" : "")
                    let parent = String(path.dropLast(shownLeaf.count))
                    row.title = shownLeaf.isEmpty ? (item.display ?? item.text) : shownLeaf
                    row.parent = parent.isEmpty ? nil : parent
                }
                other.append(row)
            }
        }
        var out: [Section] = []
        if !botRows.isEmpty { out.append(Section(title: "Bots", rows: botRows)) }
        if !other.isEmpty { out.append(Section(title: nil, rows: other)) }
        if !out.isEmpty { return out }
        if remote == nil, waiting, !failed { return previous.flatMap { $0.isEmpty ? nil : $0 } ?? note(looking, spinner: true) }
        return note(noMatches)
    }

    // MARK: - Picks

    nonisolated struct Edit: Equatable, Sendable {
        var text: String
        /// UTF-16 caret.
        var caret: Int
    }

    /// The field after an @ pick: the "@word" replaced, a space after unless the ref goes on (":" or "/").
    static func applyMention(_ ref: String, range: NSRange, in text: String) -> Edit {
        let whole = text as NSString
        let safe = NSRange(location: min(range.location, whole.length), length: max(0, min(range.length, whole.length - min(range.location, whole.length))))
        let insert = ref.hasSuffix(":") || ref.hasSuffix("/") ? ref : ref + " "
        let out = whole.replacingCharacters(in: safe, with: insert)
        return Edit(text: out, caret: safe.location + (insert as NSString).length)
    }

    /// The field after a skill picked mid-text: "/word" → "/skill ".
    static func applySkill(_ command: String, range: NSRange, in text: String) -> Edit {
        applyMention(command, range: range, in: text)
    }

    /// The field after an option pick, and whether the drawer stays (the option leads to more).
    static func applyOption(prefix: String, text: String) -> (edit: Edit, keepOpen: Bool) {
        let out = prefix + text
        return (Edit(text: out, caret: (out as NSString).length), text.hasSuffix(" "))
    }
}

// MARK: - One call in flight

/// The drawer's gateway calls: one at a time; a newer query waits for the one out, and an answer for a query no longer
/// wanted is dropped (`finished` says so) — the slow answer for "/r" can't overwrite the rows for "/reasoning h".
nonisolated struct CompletionGate: Equatable, Sendable {
    private(set) var inFlight: String?
    private(set) var wanted: String?

    /// The query the field asks for now (nil: none).
    mutating func want(_ key: String?) { wanted = key }

    /// The query to send now, if nothing is out and one is wanted (it is then out).
    mutating func next(skip: (String) -> Bool = { _ in false }) -> String? {
        guard inFlight == nil, let wanted, !skip(wanted) else { return nil }
        inFlight = wanted
        return wanted
    }

    /// The call for `key` ended: whether its answer is for what is wanted now.
    mutating func finished(_ key: String) -> Bool {
        if inFlight == key { inFlight = nil }
        guard key == wanted else { return false }
        wanted = nil   // answered: never asked again until the field asks for it again
        return true
    }

    /// Nothing is wanted any more (the drawer closed). A call still out stays counted until it ends.
    mutating func clear() { wanted = nil }
}

// MARK: - What the drawer remembers

/// The drawer's gateway answers and failures, by query ("slash|/mo", "path|@src/"). A slash answer is kept while the
/// chat is open (the commands don't change under it); an @ answer lists files, which the bot may add meanwhile, so it
/// is asked again after `pathAnswerFor` (the old rows show until the new ones come). A failed query (a timeout on a
/// slow link) is asked again after `failureFor`, never left dead for the rest of the chat.
nonisolated struct CompletionMemory: Sendable {
    static let pathAnswerFor: TimeInterval = 30
    static let failureFor: TimeInterval = 5
    static let maxAnswers = 100

    private var answers: [String: (answer: ComposerDrawerModel.Answer, at: Date)] = [:]
    private var failures: [String: Date] = [:]

    /// The newest answer for `key`, fresh or not (shown while a fresh one is asked for).
    func answer(_ key: String) -> ComposerDrawerModel.Answer? { answers[key]?.answer }

    /// Whether `key` failed lately (the drawer says so instead of waiting).
    func failed(_ key: String, now: Date = Date()) -> Bool {
        failures[key].map { now.timeIntervalSince($0) < Self.failureFor } ?? false
    }

    /// Whether the gateway should be asked for `key` now.
    func wantsAsk(_ key: String, now: Date = Date()) -> Bool {
        if failed(key, now: now) { return false }
        guard let kept = answers[key] else { return true }
        return key.hasPrefix("path|") && now.timeIntervalSince(kept.at) >= Self.pathAnswerFor
    }

    mutating func remember(_ key: String, _ answer: ComposerDrawerModel.Answer, now: Date = Date()) {
        if answers[key] == nil, answers.count >= Self.maxAnswers { answers.removeAll() }
        answers[key] = (answer, now)
        failures[key] = nil
    }

    mutating func fail(_ key: String, now: Date = Date()) { failures[key] = now }
}
