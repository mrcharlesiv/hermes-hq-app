// What the pages (Jobs, Kanban, Artifacts) need from the app (docs/spec/1x-pages.md §2.1). AppModel adopts it here;
// tests use fakes. Integration may move the protocol into Contracts.swift.

import UIKit

protocol PagesServices: AnyObject {
    var account: GatewayAccount? { get }
    /// AppModel: `client`.
    var gateway: (any GatewayClient)? { get }
    /// Scope pill, faces, profile names.
    var bots: [Bot] { get }
    var readOnlyGateway: Bool { get }
    /// Opening a run or an artifact's chat.
    func chat(for session: SessionSummary) -> ChatSessionModel
    /// [dashboard] A fresh chat with a bot (New Tile asks for its tile there).
    func newChat(for bot: Bot, folder: String?) -> ChatSessionModel
    /// [tasks] A task's own chat, born hidden from every list (AppModel.taskChat).
    func taskChat(for bot: Bot, sessionTitle: String, shownTitle: String,
                  created: @escaping @MainActor (String) -> Void) -> ChatSessionModel
    /// [tiles] A bot's own model's name ("Sonnet 5"), for a tile's job that names none; nil when unknown.
    func botModelName(_ profile: String) -> String?
    /// Called by `signOut()` before caches are forgotten.
    var onSignOutPages: (() -> Void)? { get set }
}

extension PagesServices {
    /// Services with no gateway chats (demos, tests): a chat that says so.
    func newChat(for bot: Bot, folder: String?) -> ChatSessionModel { UnavailableChat(title: "New Chat", profile: bot.id, head: bot.head) }
    func botModelName(_ profile: String) -> String? { nil }
    func taskChat(for bot: Bot, sessionTitle: String, shownTitle: String,
                  created: @escaping @MainActor (String) -> Void) -> ChatSessionModel {
        UnavailableChat(title: shownTitle, profile: bot.id, head: bot.head)
    }
}

extension AppModel: PagesServices {
    var gateway: (any GatewayClient)? { client }
    func botModelName(_ profile: String) -> String? {
        botStore?.profile(named: profile)?.model.map { ModelNames.displayModelName($0) }
    }
}

/// The scope Jobs and Artifacts share (D-P4): All Bots or one bot, per account, device-local; All by default.
@MainActor
final class PagesScope {
    static let all = "all"
    /// [bot-pills] Tasks only: your own tasks, the ones no bot helps with. Not a profile name ("@" can't be in one).
    nonisolated static let me = "@me"
    private let key: String
    private(set) var value: String
    private var observers: [UUID: (String) -> Void] = [:]

    nonisolated static func defaultsKey(_ account: GatewayAccount) -> String { "pages.scope.\(account.id)" }

    /// `key`: a page with a scope of its own ([tasks] Tasks keeps its bot apart from Jobs and Artifacts').
    init(account: GatewayAccount, key: String? = nil) {
        self.key = key ?? Self.defaultsKey(account)
        value = UserDefaults.standard.string(forKey: self.key) ?? Self.all
    }

    /// The stored scope, read as All when its bot left the roster.
    func effective(bots: [Bot]) -> String {
        // [bot-pills] Me is picked from the pills or the menu, which show with two bots or more; with one, every task.
        if value == Self.me { return bots.count == 1 ? Self.all : value }
        return value == Self.all || bots.contains(where: { $0.id == value }) || bots.isEmpty ? value : Self.all
    }

    func set(_ next: String) {
        guard next != value else { return }
        value = next
        UserDefaults.standard.set(next, forKey: key)
        for observer in observers.values { observer(next) }
    }

    @discardableResult
    func observe(_ observer: @escaping (String) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func stopObserving(_ id: UUID) { observers[id] = nil }
}

/// Display names the pages show for a profile ("default" → "Hermes").
@MainActor
enum PagesNames {
    static func botName(_ profile: String?, bots: [Bot]) -> String {
        guard let profile, !profile.isEmpty else { return "No One" }
        if let bot = bots.first(where: { $0.id == profile }) { return bot.name }
        return SessionsViewController.readableProfileName(profile)
    }

    static func head(_ profile: String, bots: [Bot]) -> JSONValue? { bots.first { $0.id == profile }?.head }

    /// All Bots, then the default bot, then roster order (`S/phone-profile-scope.tsx:40-41`).
    static func scopeChoices(_ bots: [Bot]) -> [Bot] {
        bots.filter { $0.id == "default" } + bots.filter { $0.id != "default" }
    }
}
