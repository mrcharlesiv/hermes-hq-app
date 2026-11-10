// Contract additions for the settings stream (docs/spec/1x-settings.md §14). Kept out of Contracts.swift so the
// integrator merges one new file: `AppModel` adopts `SettingsServices` (App/Settings/AppModel+Settings.swift), and the
// screens reach it with `services as? SettingsServices`.

import Foundation

// MARK: - Failures every bot write reports the same way (§2.3)

/// A write that didn't land: the alert's title ("Couldn’t Pin Ivy"), its message (the reason, two lines at most) and
/// what Show Details shows.
nonisolated struct BotWriteError: Error, LocalizedError, Sendable, Equatable {
    var title: String
    var reason: String
    var detail: String?

    init(title: String, reason: String, detail: String? = nil) {
        self.title = title; self.reason = reason; self.detail = detail
    }

    var errorDescription: String? { reason }

    static let readOnlyReason = "Changes are turned off for this gateway in this build."
    static let notSavedReason = "Your gateway didn’t save the change."
    static var unsupportedReason: String { "This gateway can’t save bot settings yet. Update Hermes on \(HostWord.updateTarget), then try again." }
}

/// Edit Bot's two parts (§6.3): each is nil when it wasn't sent, else whether the gateway applied it.
nonisolated struct EditOutcome: Sendable, Equatable {
    var titleApplied: Bool?
    var descriptionApplied: Bool?
    /// The gateway's reason when a part failed.
    var reason: String?
    // [photoheads] A staged picture (docs/spec/3x-photoheads.md §8): whether the picture itself was stored or removed
    // (nil when none was sent), whether its kind was then written into `hermes-bots`, and why the picture was refused.
    var pictureApplied: Bool? = nil
    var pictureKindApplied: Bool? = nil
    var pictureReason: String? = nil
    var pictureDetail: String? = nil
    var succeeded: Bool { titleApplied != false && descriptionApplied != false && pictureApplied != false && pictureKindApplied != false }
}

/// A head save that another device beat (§7.5): save again to replace theirs from `actual`.
nonisolated enum HeadSaveError: Error, LocalizedError, Sendable, Equatable {
    case conflict(actual: Int)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .conflict: return "This bot’s head was changed on another device. Save again to replace it with yours."
        case .failed(let reason): return reason
        }
    }
}

/// A saved head as the editor opens it (§7.2).
nonisolated struct StoredHeadState: Sendable, Equatable {
    /// The raw record to start from (nil: the name's default head).
    var record: JSONValue?
    var revision: Int
    var saved: Bool
}

/// The head overlay entry (`$headOverlay`, §7.5): wins while its revision is greater than the roster row's.
nonisolated struct HeadOverlayEntry: Codable, Sendable, Hashable {
    var head: JSONValue?
    var revision: Int
}

// MARK: - Bot editing (§5–8)

@MainActor protocol BotEditing: AnyObject {
    /// User sections in this device's order (Pinned never listed).
    var sectionRecords: [RosterSectionRecord] { get }
    /// The section menus and Bot Info show for a bot (a pinned bot's home), nil for none.
    func shownSectionId(of bot: Bot) -> String?
    func botDescription(_ bot: Bot) -> String?
    func metaTitle(_ bot: Bot) -> String?
    /// The name the bot has with no custom title (what an empty Title in Edit Bot falls back to).
    func defaultName(_ bot: Bot) -> String
    func headState(_ bot: Bot) -> StoredHeadState
    func isTaken(profileName: String) -> Bool
    var isReadOnly: Bool { get }
    /// The bot as the list draws it now (observable: SwiftUI views reading it redraw when it changes).
    func bot(id: String) -> Bot?

    func setPinned(_ bot: Bot, _ pinned: Bool) async throws
    /// A pinned-tile drop: the tiles shown as `before` (bot ids) now read `after`. Device-local, per account; no write.
    func placeTiles(before: [String], after: [String])
    /// The pins' saved order (bot ids, first first): the tiles', and under Pinned Bots › Rows the pinned rows'.
    var pinOrder: [String] { get }
    /// [manualorder] Filter › Sort By: true while the rows follow this device's order (Manual), false for Recent Activity.
    var rowsManual: Bool { get }
    /// Sort By › Manual (every row keeps its place as shown) or Recent Activity (the saved order goes). Device-local.
    func setRowsManual(_ manual: Bool)
    /// A row dropped in a new place or moved up or down: a block's rows (bot ids, top first) now read `rows`. Turns
    /// Manual on. Device-local, per account; no write.
    func placeRows(_ rows: [String])
    func setHidden(_ bot: Bot, _ hidden: Bool) async throws
    func move(_ bot: Bot, toSection id: String?) async throws
    /// A new, empty section at the end (device-local; no write). Filing a bot in it is a `move`, so a Try Again of that
    /// move never makes a second section.
    @discardableResult func appendSection(named: String) -> RosterSectionRecord
    func renameSection(_ id: String, to name: String) async throws
    func moveSection(_ id: String, by delta: Int)
    /// Bots filed in a section, hidden ones included (what Delete Section moves).
    func memberCount(ofSection id: String) -> Int
    /// Delete Section's local half: the record goes now; nil when there's no such section. Throws only when refused
    /// (read-only gateway) before anything changed.
    func beginDeleteSection(_ id: String) throws -> SectionDeletion?
    /// Its writes (members to Unassigned, in order). A failure puts the record back and throws; after an Undo, returns.
    func finishDeleteSection(_ deletion: SectionDeletion) async throws
    /// The Undo: the record back at its index, its members filed back (queued behind their writes still out).
    func undoDeleteSection(_ deletion: SectionDeletion)
    func saveEdit(_ bot: Bot, title: String?, description: String?) async throws -> EditOutcome
    /// Compare-and-swap save of `dispatch-head` (nil = Reset Head). Returns the new revision; throws `HeadSaveError`.
    func saveHead(_ bot: Bot, record: JSONValue?, revision: Int) async throws -> Int
    /// The desktop copy of a saved head (a 288 × 288 PNG data URL), or its removal after a reset. Best effort.
    func mirrorHead(_ bot: Bot, png dataURL: String?) async
    func createBot(name: String, title: String, description: String) async throws -> NewBotResult

    // Bots row and Bot Info extras (docs/parity-240.md §3)
    /// The primary profile ("Hermes"): never deleted.
    func isDefault(_ bot: Bot) -> Bool
    /// The bot's model and provider as the roster names them (nil when unknown).
    func modelInfo(_ bot: Bot) -> (model: String?, provider: String?)
    /// The bot's default model as Hermes stores it (the model id and provider slug, for the chooser's check mark).
    func defaultModel(_ bot: Bot) -> (model: String?, provider: String?)
    /// The bot's own default model (`POST /api/model/set?profile=`). Throws `ModelSetError.confirm` when the gateway asks
    /// first (send again with `confirm`), a `BotWriteError` otherwise.
    func setDefaultModel(_ bot: Bot, provider: String, model: String, baseURL: String?, confirm: Bool) async throws
    /// `profiles.create` with `clone_from` plus the original's look; returns the new profile's name.
    @discardableResult func duplicate(_ bot: Bot) async throws -> String
    /// `DELETE /api/profiles/<name>`; this phone forgets the bot at once.
    func delete(_ bot: Bot) async throws
    /// Up to three of the bot's own recent chats, newest first (its Bot Chat and background runs left out).
    func recentChats(_ bot: Bot) async -> [SessionSummary]
}

/// What New Bot needs after `profiles.create` (§8.2 steps 4–7).
nonisolated struct NewBotResult: Sendable, Equatable {
    var bot: Bot
    /// `setup.runtime_check` said `ok: false`: no intro turn; the chat shows the notice instead.
    var needsModel: Bool
    var displayName: String
}

// MARK: - Gateways (§4)

/// One saved gateway as the Gateway page and the title menu show it (§4.2).
nonisolated struct GatewayAccountRow: Identifiable, Sendable, Hashable {
    var id: String
    var account: GatewayAccount
    var title: String
    var subtitle: String
    /// The name given on this phone (nil when none): the rename field starts from it.
    var label: String?
    var hostAndPort: String
    var accountName: String
    var isCurrent: Bool
    var hasSession: Bool
    /// Other gateways' bots with news (0 for the current one).
    var news: Int
    /// Another gateway that didn't answer its last news check ("Can’t Reach"; never the current one).
    var unreachable = false
}

@MainActor protocol GatewayAccounts: AnyObject {
    var accounts: [GatewayAccountRow] { get }
    var otherNews: Int { get }
    /// The row being switched to, while the switch runs.
    var switchingTo: String? { get }
    func switchTo(_ id: String) async throws
    func rename(_ id: String, _ label: String?) throws
    func remove(_ id: String) async throws
    func checkSoon()
    /// Several listeners (Bots title, Sessions title, Settings); returns a token to remove one.
    @discardableResult func observe(_ change: @escaping @MainActor () -> Void) -> UUID
    func stopObserving(_ token: UUID)
}

// MARK: - Capabilities (§9)

nonisolated struct SkillInfo: Identifiable, Sendable, Hashable, Codable {   // Codable: [load-cache] CapabilitiesWarmCache
    var name: String
    var description: String
    var category: String?
    var enabled: Bool
    /// [capabilities] nil when the gateway sent no number (an older Hermes): "never used" is only a real 0 (spec 3x §3.2).
    var usage: Int?
    var provenance: String?
    var id: String { name }
}

nonisolated struct OfficialSkill: Identifiable, Sendable, Hashable, Codable {
    var name: String
    var description: String
    var identifier: String
    var category: String?
    var installed: Bool
    var id: String { identifier }
}

/// [hub] One Skills Hub search result (`GET /api/skills/hub/search`, `_skill_meta_to_payload`): where it comes from and
/// how far Hermes trusts that source, so a community skill is clearly marked.
nonisolated struct HubSkill: Identifiable, Sendable, Hashable {
    var name: String
    var description: String
    var identifier: String
    var source: String
    /// `builtin`, `trusted` or `community`.
    var trust: String
    var repo: String?
    var id: String { identifier }

    var isCommunity: Bool { trust != "builtin" && trust != "trusted" }

    /// The desktop's trust badge (`hub.trust`), in Title Case.
    var trustWord: String {
        switch trust {
        case "builtin": "Built-in"
        case "trusted": "Trusted"
        default: "Community"
        }
    }

    /// The hub source's label (`_SKILL_HUB_SOURCE_LABELS`), else the source id.
    var sourceWord: String {
        switch source {
        case "official": "Official (Nous)"
        case "hermes-index": "Hermes Index"
        case "skills-sh": "skills.sh"
        case "well-known": "Well-Known"
        case "url": "Direct URL"
        case "github": "GitHub"
        case "clawhub": "ClawHub"
        case "lobehub": "LobeHub"
        case "browse-sh": "browse.sh"
        default: source
        }
    }

    /// "Community · GitHub · owner/repo"
    var provenance: String { ([trustWord, sourceWord] + (repo.map { [$0] } ?? [])).filter { !$0.isEmpty }.joined(separator: " · ") }
}

nonisolated struct HubSearchResult: Sendable, Equatable {
    var results: [HubSkill]
    /// Hub identifiers already installed for this bot.
    var installed: Set<String>
}

nonisolated struct ActionStatus: Sendable, Equatable {
    var name: String
    var running: Bool
    var exitCode: Int?
    var lines: [String]
}

nonisolated struct McpServer: Identifiable, Sendable, Hashable {
    var name: String
    var transport: String
    var enabled: Bool
    var source: String
    var plugin: String?
    /// From `mcp.servers.status` (nil until it answers).
    var status: String?
    var tools: Int?
    // [capabilities] from `mcp.servers.list` (spec 3x §5, §8): what the connector page and the issue count need.
    var auth: String? = nil
    var oauthTokensPresent: Bool? = nil
    var url: String? = nil
    var command: String? = nil
    var hasHeaders: Bool = false
    var id: String { name }
}

@MainActor protocol CapabilitiesService: AnyObject {
    func skills(_ profile: String) async throws -> [SkillInfo]
    func officialSkills(_ profile: String) async throws -> [OfficialSkill]
    func searchHub(_ query: String, profile: String) async throws -> HubSearchResult
    func skillContent(_ name: String, profile: String) async throws -> String
    func setSkill(_ name: String, enabled: Bool, profile: String) async throws
    func install(_ identifier: String, profile: String) -> AsyncThrowingStream<ActionStatus, Error>
    func uninstall(_ name: String, profile: String) -> AsyncThrowingStream<ActionStatus, Error>
    func mcpServers(_ profile: String) async throws -> [McpServer]
    func mcpStatus(_ profile: String) async throws -> [String: (status: String, tools: Int)]
    func setMcp(_ name: String, enabled: Bool, profile: String) async throws
}

// MARK: - What the settings screens need from the app model

@MainActor protocol SettingsServices: AnyObject {
    var botEditing: (any BotEditing)? { get }
    var gateways: any GatewayAccounts { get }
    var capabilities: (any CapabilitiesService)? { get }
    /// The Bots list laid out by section id in this device's order (nil before a store exists).
    var botLayout: RosterLayout? { get }
    /// "Hermes 0.21.5" as `/api/status` says (nil until read, or unknown).
    var gatewayVersion: String? { get }
    func refreshGatewayVersion(force: Bool)
    /// Number of profiles in the last roster (hidden ones included).
    var rosterCount: Int { get }
    /// Add Gateway… succeeded (the account is saved and current): switch the app to it.
    func adoptSignedInAccount(_ account: GatewayAccount)
    /// The sign-in driver for Add Gateway… and for a signed-out row's sign-in.
    func makeSignInDriver() -> SignInServiceDriver
    /// New Bot opened this chat: send the intro or show the no-model notice once it is on screen (§8.2 step 7).
    func startIntro(in chat: any ChatSessionModel, result: NewBotResult)
    /// Mark as Unread from the row menu (device-local).
    func markUnread(_ bot: Bot)
}
