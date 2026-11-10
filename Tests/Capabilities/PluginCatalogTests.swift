// [find-plugins] The Hermes plugin catalog as the docs site publishes it (/docs/api/plugins.json): reading, the words
// a row and a page show, search, and the install call.

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct PluginCatalogTests {
    private let sample = """
    [
      {"name": "mem0", "description": "Mem0 memory provider — server-side LLM fact extraction with semantic search. Maintained by Mem0. Disclosure — conversation turns go to api.mem0.ai in platform mode.",
       "repo": "https://github.com/mem0ai/mem0", "sha": "43849c6e9d4d773b83a8144b6373aedc67241a5d", "tier": "community", "category": "memory",
       "maintainer": "mem0ai", "subdir": "integrations/hermes-plugin-mem0", "requiresHermes": ">=0.22.3", "platforms": [],
       "capabilities": {"providesTools": [], "requiresEnv": ["MEM0_API_KEY"]}, "docsUrl": "https://github.com/mem0ai/mem0#readme",
       "version": "1.3.0", "image": "", "stars": 68262, "addedAt": "2026-10-06T04:17:19-07:00", "updatedAt": "2026-10-06T04:17:19-07:00"},
      {"name": "spotify", "description": "Spotify: play, queue and search music, e.g. by mood. Official.", "repo": "https://github.com/NousResearch/hermes-spotify",
       "sha": "1111111111111111111111111111111111111111", "tier": "official", "category": "tools", "maintainer": "NousResearch",
       "platforms": ["macos", "linux"], "capabilities": {"providesTools": ["spotify_play", "spotify_queue"]}, "stars": 1799},
      {"name": "panes", "description": "A pane for the desktop.", "repo": "https://github.com/acme/panes", "sha": "2222222222222222222222222222222222222222",
       "category": "desktop", "maintainer": "acme", "stars": "many"},
      {"name": "odd", "description": "Unknown shelf.", "repo": "https://github.com/acme/odd", "sha": "3333333333333333333333333333333333333333", "category": "nonsense", "maintainer": "acme"},
      {"name": "bad-repo", "description": "Not https.", "repo": "git@github.com:acme/x", "sha": "4444444444444444444444444444444444444444"},
      {"description": "no name"}
    ]
    """

    private func entries() throws -> [PluginCatalogEntry] { try PluginCatalogEntry.decode(Data(sample.utf8)) }

    @Test func readsThePublishedList() throws {
        let list = try entries()
        #expect(list.map(\.name) == ["mem0", "spotify", "panes", "odd"], "no name or a repo that isn't https is skipped; order kept")
        let mem0 = list[0]
        #expect(mem0.category == .memory)
        #expect(mem0.stars == 68262)
        #expect(mem0.requiresEnv == ["MEM0_API_KEY"])
        #expect(mem0.image == nil, "an empty image is none")
        #expect(mem0.addedAt != nil)
        #expect(mem0.installIdentifier == "https://github.com/mem0ai/mem0#integrations/hermes-plugin-mem0")
        #expect(list[1].installIdentifier == "https://github.com/NousResearch/hermes-spotify")
        #expect(list[2].stars == nil, "a field of the wrong type is missing, not a failed list")
        #expect(list[2].tier == "community", "no tier is community")
        #expect(list[3].category == .general, "an unknown shelf is General")
    }

    @Test func wordsForRowsAndPages() throws {
        let list = try entries()
        let mem0 = list[0], spotify = list[1]
        #expect(mem0.about == "Mem0 memory provider — server-side LLM fact extraction with semantic search. Maintained by Mem0.")
        #expect(mem0.disclosure == "Conversation turns go to api.mem0.ai in platform mode.")
        #expect(mem0.summary == "Mem0 memory provider — server-side LLM fact extraction with semantic search.")
        #expect(spotify.summary == "Play, queue and search music, e.g. by mood.", "the name it starts with is dropped; 'e.g.' doesn't end it")
        #expect(spotify.disclosure == nil)
        #expect(spotify.tierWord == "Official")
        #expect(mem0.tierWord == nil)
        #expect(spotify.platformWords == "macOS and Linux")
        #expect(mem0.platformWords == nil)
        #expect(mem0.hermesWords == "0.22.3 or newer")
        #expect(mem0.pageURL?.absoluteString == "https://hermes-agent.nousresearch.com/marketplace/mem0")
        #expect(PluginCatalogEntry.firstSentence(String(repeating: "word ", count: 60)).hasSuffix("…"))
        #expect(68262.starWords == "68k")
        #expect(1799.starWords == "1.8k")
        #expect(2000.starWords == "2k")
        #expect(412.starWords == "412")
    }

    @Test func searchRanksNamesFirstAndNeedsEveryWord() throws {
        let list = try entries()
        #expect(PluginCatalogEntry.search(list, "spot").map(\.name) == ["spotify"])
        #expect(PluginCatalogEntry.search(list, "memory").first?.name == "mem0", "the shelf and the words find it")
        #expect(PluginCatalogEntry.search(list, "music mood").map(\.name) == ["spotify"])
        #expect(PluginCatalogEntry.search(list, "music nothing-like-this").isEmpty, "every word has to be somewhere")
        #expect(PluginCatalogEntry.search(list, "acme").map(\.name) == ["panes", "odd"], "the maker finds theirs, list order kept")
        #expect(PluginCatalogEntry.search(list, "  ").count == list.count)
    }

    @Test func picksSpreadAcrossKinds() throws {
        let list = try entries()
        let memories = (0..<4).map { i in var e = list[0]; e.name = "memory-\(i)"; return e }
        let picks = PluginCatalogEntry.picks(memories + list.dropFirst(), count: 4)
        #expect(picks.map(\.name) == ["memory-0", "memory-1", "spotify", "panes"], "two of a kind, then the next kinds in order")
    }

    @Test func installsByCatalogName() {
        #expect(PluginAction.installCatalog(name: "mem0", enable: true).params(profile: "ivy")
                == ["profile": "ivy", "action": "install", "catalog_name": "mem0", "enable": true])
        #expect(PluginAction.installCatalog(name: "mem0", enable: true).timeout == .seconds(120))
        #expect(PluginCatalogEntryModel.predatesCatalogName(RPCError(code: 4019, message: "plugins.install requires 'identifier' or 'repo'")))
        #expect(!PluginCatalogEntryModel.predatesCatalogName(RPCError(code: 5026, message: "install failed")))
    }

    @Test func installedRowsCarryTheirCatalogName() throws {
        let row = try JSONValue.parse(Data(#"{"name": "mem0-plugin", "catalog_name": "mem0", "source": "catalog", "status": "enabled"}"#.utf8))
        #expect(PluginInfo.read(row)?.catalogName == "mem0")
    }

    @Test func settingsSearchFindsPlugins() {
        #expect(SettingsSearch.results("plugins", in: SettingsSearch.rootPages).first?.label == "Plugins")
        #expect(SettingsSearch.results("add-ons", in: SettingsSearch.rootPages).contains { $0.label == "Plugins" })
    }
}
