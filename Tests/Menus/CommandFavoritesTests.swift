// [favorite-commands] Starred commands (docs/spec/3x-composer.md §9.7): the store, the Favorites section the Commands
// sheet and the slash drawer lead with, and starred commands first as you type. No network.

import Foundation
import Testing
@testable import HermesHQNative

private typealias M = ComposerDrawerModel

@MainActor @Suite("Composer · favourite commands (spec 3x §9.7)")
struct CommandFavoritesTests {
    let catalog = MenusCommandsTests.fixtureCatalog()

    private func store(_ account: String = "acct-1") -> (CommandFavorites, UserDefaults) {
        let defaults = UserDefaults(suiteName: "hqn.tests.favorite-commands.\(UUID().uuidString)")!
        return (CommandFavorites(accountId: account, defaults: defaults), defaults)
    }

    private func titles(_ sections: [M.Section]?) -> [String] { (sections ?? []).flatMap(\.rows).map(\.title) }

    @Test func starredInOrderAndUnstarred() {
        let (favorites, defaults) = store()
        #expect(favorites.commands.isEmpty)
        favorites.toggle("/Status")
        favorites.toggle("usage now")       // as typed: "/usage"
        favorites.toggle("/plan")
        #expect(favorites.commands == ["/status", "/usage", "/plan"])
        #expect(favorites.contains("/STATUS"))
        favorites.toggle("/usage")
        #expect(favorites.commands == ["/status", "/plan"])
        favorites.toggle("/")               // nothing to star
        #expect(favorites.commands == ["/status", "/plan"])
        // Another account keeps its own; Sign Out forgets only the one leaving.
        let other = CommandFavorites(accountId: "acct-2", defaults: defaults)
        other.toggle("/retry")
        CommandFavorites.forget(accountId: "acct-1", defaults: defaults)
        #expect(favorites.commands.isEmpty)
        #expect(other.commands == ["/retry"])
        CommandFavorites.forgetAll(defaults: defaults)
        #expect(other.commands.isEmpty)
    }

    @Test func aLongListKeepsTheNewest() {
        let (favorites, _) = store()
        for i in 0..<(CommandFavorites.limit + 5) { favorites.toggle("/c\(i)") }
        #expect(favorites.commands.count == CommandFavorites.limit)
        #expect(favorites.commands.first == "/c5")
    }

    @Test func favoritesSectionIsInStarredOrderAndOnlyListedCommands() throws {
        let sections = SlashCatalog.sections(catalog)
        #expect(SlashCatalog.favoritesSection(sections, favorites: []) == nil)
        // /debug is hidden on the phone and /nope isn't in this chat's list: neither shows.
        let starred = try #require(SlashCatalog.favoritesSection(sections, favorites: ["/usage", "/debug", "/nope", "/status", "/release-notes"]))
        #expect(starred.title == "Favorites")
        #expect(starred.rows.map(\.command) == ["/usage", "/status", "/release-notes"])
        #expect(starred.rows.last?.skill == true, "a skill keeps what a pick does")
        #expect(SlashCatalog.favoritesSection(sections, favorites: ["/debug", "/nope"]) == nil)
        // The starred rows stay in their own sections too.
        #expect(sections.contains { $0.rows.contains { $0.command == "/usage" } })
    }

    @Test func bareSlashOpensOnFavorites() throws {
        let plain = M.slashSections(text: "/", catalog: catalog, catalogLoading: false, isBotChat: false, remote: nil, recent: [])
        #expect(plain?.first?.title != "Favorites")
        let s = try #require(M.slashSections(text: "/", catalog: catalog, catalogLoading: false, isBotChat: false, remote: nil, recent: [],
                                             favorites: ["/version", "/help", "/plan"]))
        #expect(s.first?.title == "Favorites")
        #expect(s.first?.rows.map(\.title) == ["/version", "/help", "/plan"], "/help is listed in the drawer, so it can be starred there")
        #expect(s.first?.rows.allSatisfy { $0.id.hasPrefix("fav.") } == true)
        // Each still shows in its own section, under its own id.
        #expect(titles(Array(s.dropFirst())).contains("/version"))
        #expect(Set(s.flatMap(\.rows).map(\.id)).count == s.flatMap(\.rows).count, "row ids stay unique")
    }

    @Test func typedStarredCommandsLead() {
        let words = M.slashSections(text: "/st", catalog: catalog, catalogLoading: false, isBotChat: false, remote: nil, recent: [])
        #expect(titles(words).prefix(2) == ["/stop", "/status"])
        let starred = M.slashSections(text: "/st", catalog: catalog, catalogLoading: false, isBotChat: false, remote: nil, recent: [],
                                      favorites: ["/plan", "/status"])
        #expect(titles(starred).prefix(2) == ["/status", "/stop"], "the starred match goes first")
        #expect(!titles(starred).contains("/plan"), "a starred command that doesn't match stays out")
        #expect(starred?.first?.title == "Commands", "typed, no Favorites section")
        // A starred command that only contains the words keeps its place after the ones that start with them.
        let inner = M.slashSections(text: "/a", catalog: catalog, catalogLoading: false, isBotChat: false, remote: nil, recent: [],
                                    favorites: ["/usage"])
        #expect(titles(inner).first == titles(M.slashSections(text: "/a", catalog: catalog, catalogLoading: false, isBotChat: false,
                                                              remote: nil, recent: [])).first)
    }

    @Test func theGatewaysAnswerToo() {
        let answer = M.answer(["items": [["text": "reasoning", "display": "/reasoning", "meta": "Set reasoning", "kind": "command"],
                                         ["text": "retry", "display": "/retry", "meta": "Retry", "kind": "command"],
                                         ["text": "release-notes", "display": "/release-notes", "meta": "x", "kind": "skill"]],
                               "replace_from": 1], asked: "/re")
        let s = M.slashSections(text: "/re", catalog: catalog, catalogLoading: false, isBotChat: false, remote: answer, recent: [],
                                favorites: ["/retry"])
        #expect(titles(s) == ["/retry", "/reasoning", "/release-notes"])
    }
}
