import Foundation
import Testing
@testable import HermesHQNative

/// UX study 2026-10-19 #28, #36: the Sessions search names its scope, and a failed gateway search is not "No Results".
@Suite struct SessionsSearchWordsTests {
    @Test func thePlaceholderNamesThePickedBot() {
        #expect(SessionsSearchWords.placeholder(botName: nil) == "Search Chats")
        #expect(SessionsSearchWords.placeholder(botName: " ") == "Search Chats")
        #expect(SessionsSearchWords.placeholder(botName: "Ivy") == "Search Ivy’s Chats")
    }

    @Test func aSearchThatAnsweredEmptySaysNoResults() {
        let words = SessionsSearchWords.empty(query: "four teams", searching: false, failed: false)
        #expect(words.text == "No Results for “four teams”" && words.secondary == nil)
    }

    @Test func aFailedSearchSaysOnlyLoadedChatsWereSearched() {
        let words = SessionsSearchWords.empty(query: "four teams", searching: false, failed: true)
        #expect(words.text == "Couldn’t Search Your Gateway")
        #expect(words.secondary == "Showing loaded chats only, and none match “four teams”.")
    }

    @Test func aSearchStillOutSaysSearching() {
        #expect(SessionsSearchWords.empty(query: "x", searching: true, failed: true).text == "Searching…")
    }
}
