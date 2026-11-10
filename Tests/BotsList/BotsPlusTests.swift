// [bots-plus] The pencil always means a new chat: Sessions' compose button keeps it, and the Bots bar's button that
// makes things (New Bot, New Group Chat, New Section…) is a + (owner 2026-11-03, menu review #3).

import Testing
import UIKit
@testable import HermesHQNative

@MainActor
@Suite(.serialized)
struct BotsPlusTests {
    /// One gateway, nothing to switch to: the Bots title stays plain.
    private final class OneGateway: GatewayAccounts {
        var accounts: [GatewayAccountRow] = []
        var otherNews = 0
        var switchingTo: String? { nil }
        func switchTo(_ id: String) async throws {}
        func rename(_ id: String, _ label: String?) throws {}
        func remove(_ id: String) async throws {}
        func checkSoon() {}
        func observe(_ change: @escaping @MainActor () -> Void) -> UUID { UUID() }
        func stopObserving(_ token: UUID) {}
    }

    /// Just enough of the app for the Bots page with its organizer (the settings stream), so the bar has its button.
    private final class Services: AppServices, SettingsServices {
        var account: GatewayAccount? = .botsTestAccount
        var bots: [Bot] = []
        var sessions: [SessionSummary] = []
        var connection: ConnectionState = .ready
        var onBotsChange: (() -> Void)?
        var onSessionsChange: (() -> Void)?
        var onConnectionChange: (() -> Void)?
        func refreshBots() {}
        func refreshSessions() {}
        func chat(for bot: Bot) -> ChatSessionModel { UnavailableChat(title: bot.name, profile: bot.id, head: nil) }
        func chat(for session: SessionSummary) -> ChatSessionModel { UnavailableChat(title: session.title, profile: session.profile, head: nil) }
        func markRead(_ bot: Bot) {}
        func signOut() {}

        let gatewayList = OneGateway()
        var botEditing: (any BotEditing)? { nil }
        var gateways: any GatewayAccounts { gatewayList }
        var capabilities: (any CapabilitiesService)? { nil }
        var botLayout: RosterLayout? { nil }
        var gatewayVersion: String? { nil }
        func refreshGatewayVersion(force: Bool) {}
        var rosterCount: Int { 0 }
        func adoptSignedInAccount(_ account: GatewayAccount) {}
        func makeSignInDriver() -> SignInServiceDriver { fatalError("not used") }
        func startIntro(in chat: any ChatSessionModel, result: NewBotResult) {}
        func markUnread(_ bot: Bot) {}
    }

    /// The same symbol drawn the same way (two `UIImage(systemName:)` are never the same object).
    private func draws(_ image: UIImage?, _ symbol: String, _ configuration: UIImage.SymbolConfiguration? = nil) -> Bool {
        guard let image, image.isSymbolImage, var want = UIImage(systemName: symbol) else { return false }
        if let configuration, let sized = want.applyingSymbolConfiguration(configuration) { want = sized }
        return image.pngData() == want.pngData()
    }

    private func look(_ on: Bool) -> ThemeSet {
        ThemeResolver.resolve(ThemeState(skinID: "midnight", desktopLook: on, highContrast: false, uiScalePercent: 100))
    }

    private func barItems(_ list: BotsViewController) throws -> (plus: UIBarButtonItem, search: UIBarButtonItem, all: [UIBarButtonItem]) {
        let items = list.navigationItem.rightBarButtonItems ?? []
        let plus = try #require(items.first { $0.accessibilityIdentifier == "bots.compose" })
        let search = try #require(items.first { $0.accessibilityIdentifier == "bots.search" })
        return (plus, search, items)
    }

    @Test func botsMakesThingsBehindAPlus() throws {
        let list = BotsViewController(services: Services()) { _ in UIViewController() }
        list.loadViewIfNeeded()
        let (plus, search, items) = try barItems(list)
        #expect(draws(plus.image, "plus"), "a +, not the pencil: \(String(describing: plus.image))")
        #expect(!draws(plus.image, "square.and.pencil"))
        #expect(plus.menu != nil && plus.primaryAction == nil, "it opens the create menu")
        #expect(plus.accessibilityLabel == "New Bot or Section", "VoiceOver names what it makes")
        #expect(list.createLabel == plus.accessibilityLabel, "the Mac rail's + takes the same words")
        // Where the pencil was: Filter · Search · + (the bar lays trailing items out from the edge inward).
        #expect(items.first === plus)
        #expect(items.dropFirst().first === search)
        #expect(items.dropFirst(2).first?.customView?.accessibilityIdentifier == "bots.filter")
    }

    /// The + is a plain bar item, as the magnifier beside it is, so each look draws the two alike: the bar's own glyph
    /// in the iOS look; the Desktop Look's small grey glyph without glass in it; and back again.
    @Test func thePlusIsDrawnLikeTheMagnifierInBothLooks() throws {
        DesktopBars.install()
        let list = BotsViewController(services: Services()) { _ in UIViewController() }
        list.loadViewIfNeeded()
        let (plus, search, _) = try barItems(list)
        #expect(plus.image?.symbolConfiguration == search.image?.symbolConfiguration, "iOS look: no size or weight of its own")
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        ThemeTable.$testSet.withValue(look(true)) {
            DesktopBars.flattenButtons(of: list.navigationItem, desktop: true, traits: traits)
            let small = UIImage.SymbolConfiguration(pointSize: DesktopBars.glyphSize, weight: .regular)
            #expect(draws(plus.image, "plus", small), "\(String(describing: plus.image))")
            #expect(draws(search.image, "magnifyingglass", small), "\(String(describing: search.image))")
            #expect(plus.tintColor === HQPalette.label2 && search.tintColor === HQPalette.label2, "the same grey")
            #expect(plus.hidesSharedBackground && search.hidesSharedBackground, "no glass")
        }
        ThemeTable.$testSet.withValue(look(false)) {
            DesktopBars.flattenButtons(of: list.navigationItem, desktop: false, traits: traits)
            #expect(draws(plus.image, "plus"), "the look off puts the bar's own + back")
            #expect(plus.tintColor == nil && !plus.hidesSharedBackground)
        }
    }

    @Test func thePencilStillStartsANewChat() {
        // Sessions' button is the capsule's default: the pencil, "New Chat", an action (no menu).
        let page = UIViewController()
        let capsule = PageBarCapsule(host: page, configuration: .init(page: "sessions", compose: .action({})))
        let pencil = capsule.composeItem
        #expect(draws(pencil?.image, "square.and.pencil"))
        #expect(pencil?.accessibilityLabel == "New Chat")
        #expect(pencil?.menu == nil)
    }
}
