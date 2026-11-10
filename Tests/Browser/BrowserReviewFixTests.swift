// Review fixes (m5/browser): the chat card follows the chat's session ids and its turn, paste chunks fit the plugin's
// limit in code points, and a sign-out ends open viewers.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

private let browserId = "0123456789abcdef01234567"

/// A plugin that isn't there (every REST call 404s) and sockets that can't open.
nonisolated final class NoPluginSockets: GatewayPluginSockets, @unchecked Sendable {
    func pluginSocket(path: String, query: [URLQueryItem]) async throws -> URLSessionWebSocketTask {
        throw HTTPError(status: 404, body: nil)
    }
}

@MainActor final class CardSpySession: ChatSessionModel {
    var title = "Side chat"
    var profile = "wren"
    var head: JSONValue? = nil
    var messages: [ChatMessage] = []
    var isRunning = false
    var hasOlder = false
    var isLoadingOlder = false
    var connection: ConnectionState = .ready
    var statusText: String? = nil
    var onChange: ((ChatChange) -> Void)?
    func start() {}
    func stopObserving() {}
    func loadOlder() {}
    func send(_ text: String) {}
    func stop() {}
}

@MainActor
struct BrowserReviewFixTests {
    private func service() -> BrowserService {
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in throw HTTPError(status: 404, body: nil) }
        return BrowserService(rest: client, sockets: NoPluginSockets())
    }

    @Test func theCardFollowsTheChatsSessionIdsAndLeavesAfterTheTurn() {
        let service = service()
        let session = CardSpySession()
        let chat = ChatViewController(session: session)
        var ids: [String] = []
        BrowserChatCard.install(on: chat, service: service,
                                scope: { BrowserScope(profile: "wren", sessionIds: ids, title: "Wren", chatOnly: true) },
                                open: { _, _ in })
        chat.activity.onAttachedChange?(true)
        let row = BrowserRow(id: browserId, profile: "wren", sessionId: "s9", sessionIds: ["s9"], url: "https://example.test",
                             busy: 1, agentAt: Date().timeIntervalSince1970, active: true)
        service.activity.debugPublish([row])
        #expect(chat.activity.browserChip == nil, "a chat without session ids yet shows no other chat's browser")

        ids = ["s9"]                       // its first turn started: the session id is known
        session.isRunning = true
        chat.activity.onStateChange?()
        #expect(chat.activity.browserChip?.words == "Browsing example.test", "the scope is read again on the turn's start")

        var idle = row
        idle.active = false
        idle.busy = 0
        service.activity.debugPublish([idle])
        #expect(chat.activity.browserChip != nil, "kept while the turn runs")
        session.isRunning = false
        chat.activity.onStateChange?()
        #expect(chat.activity.browserChip == nil, "gone once the turn ended, with no list change needed")
        chat.activity.onAttachedChange?(false)
    }

    @Test func aBotsOwnChatScopeShowsAnyBrowserOfTheBot() {
        let row = BrowserRow(id: browserId, profile: "wren", sessionId: "other", active: true)
        #expect(BrowserScope(profile: "wren", title: "Wren").row(in: [row]) != nil)
        #expect(BrowserScope(profile: "wren", title: "Wren", chatOnly: true).row(in: [row]) == nil)
    }

    @Test func pasteChunksStayUnderThePluginsCodePointLimit() {
        let flag = "🇺🇸"                         // two scalars, one character
        let family = "👨‍👩‍👧‍👦"                     // seven scalars
        let text = String(repeating: "a", count: 1999) + flag + String(repeating: family, count: 700)
        let chunks = BrowserKeyboard.pasteChunks(text)
        #expect(chunks.allSatisfy { $0.unicodeScalars.count <= 2000 }, "\(chunks.map(\.unicodeScalars.count))")
        #expect(chunks[0] == String(repeating: "a", count: 1999), "a character is never split")
        #expect(chunks.joined() == text)
        #expect(BrowserKeyboard.pasteChunks(String(repeating: family, count: 50_000)).count == 50)
    }

    @Test func signingOutEndsOpenViewersAndTheyDontDialAgain() {
        let service = service()
        let watch = BrowserWatchSession(service: service, rowId: browserId, base: BrowserWire.plugin, profile: "wren", name: "Wren")
        var told = 0
        watch.onShutDown = { told += 1 }
        #expect(service.debugWatcherCount == 1)
        service.shutdown()
        #expect(watch.isStopped && told == 1)
        #expect(service.debugWatcherCount == 0)
        watch.setShown(true)
        #expect(watch.link == .idle, "a stopped viewer never dials")
        let later = BrowserWatchSession(service: service, rowId: browserId, base: BrowserWire.plugin, profile: "wren", name: "Wren")
        later.setShown(true)
        #expect(later.ended && later.link == .idle, "a viewer opened after sign-out ends at once")
    }
}
