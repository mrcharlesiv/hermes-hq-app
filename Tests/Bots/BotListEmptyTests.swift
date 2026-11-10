// 3x-morepages §6 (U5): what the Bots list says when it has no rows.

import Testing
@testable import HermesHQNative

struct BotListEmptyTests {
    @Test func theTable() {
        func state(bots: Int, hidden: Int, rooms: Int = 0, query: String = "", filtered: Bool = false, shown: Bool = false,
                   matches: Int = 0, offline: String? = nil) -> BotListEmpty {
            BotList.emptyState(bots: bots, hidden: hidden, rooms: rooms, query: query, filtered: filtered, hiddenShown: shown,
                               matches: matches, offline: offline)
        }
        #expect(state(bots: 0, hidden: 0) == .noBots)
        #expect(state(bots: 0, hidden: 0, offline: "Offline") == .offline("Offline"))
        #expect(state(bots: 2, hidden: 2) == .allHidden)
        #expect(state(bots: 2, hidden: 2, shown: true) == .none, "Hidden is open: its rows are the list")
        #expect(state(bots: 2, hidden: 1) == .none)
        #expect(state(bots: 2, hidden: 2, rooms: 1) == .none, "a group chat is still listed")
        // A search or a filter wins: its own miss, never All Bots Are Hidden.
        #expect(state(bots: 2, hidden: 2, query: "ivy") == .search)
        #expect(state(bots: 2, hidden: 2, query: "ivy", matches: 1) == .none)
        #expect(state(bots: 2, hidden: 2, filtered: true) == .filtered)
        #expect(state(bots: 2, hidden: 0, filtered: true, matches: 2) == .none)
    }

    @Test func theWordsAreTheWebs() {
        #expect(BotListEmpty.allHiddenTitle == "All Bots Are Hidden")
        #expect(BotListEmpty.allHiddenText == "Hidden bots keep working; they just aren’t listed.")
        #expect(BotListEmpty.allHiddenButton == "Show Hidden Bots")
        #expect(BotListEmpty.allHiddenSymbol == "eye.slash")
    }
}
