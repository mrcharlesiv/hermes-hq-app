// [presence] Unit tests for "the viewer reconnects by itself when the link is back" (docs/spec/3x-presence.md §11, §13
// items 9–10) and the chat ⋯ item's offline state (§9). No real socket is opened: the fakes below throw or wait.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

/// Sockets that never open: each dial is counted, then fails with a connection error (not a 404, so the caller backs
/// off and retries) or, with `hang`, waits until it is cancelled (a dial in flight).
nonisolated final class CountingSockets: GatewayPluginSockets, @unchecked Sendable {
    private let lock = NSLock()
    private var dialled: [String] = []
    private var hanging: Bool

    init(hang: Bool = false) { hanging = hang }

    var paths: [String] { lock.withLock { dialled } }
    var count: Int { lock.withLock { dialled.count } }
    var hang: Bool {
        get { lock.withLock { hanging } }
        set { lock.withLock { hanging = newValue } }
    }

    func pluginSocket(path: String, query: [URLQueryItem]) async throws -> URLSessionWebSocketTask {
        let wait = lock.withLock { dialled.append(path); return hanging }
        if wait { try await Task.sleep(for: .seconds(600)) }
        throw URLError(.notConnectedToInternet)
    }
}

nonisolated private let readyHealth: JSONValue = ["installed": true, "protocol": 3, "features": ["control": true, "watch": true]]

@MainActor
private func service(sockets: any GatewayPluginSockets, plugin: @escaping @Sendable () -> Bool = { true }) -> (BrowserService, BotsFakeGatewayClient) {
    let client = BotsFakeGatewayClient()
    client.onREST { _, path, _, _ in
        guard plugin(), path.hasSuffix("/health") else { throw HTTPError(status: 404, body: nil) }
        return try readyHealth.encoded()
    }
    return (BrowserService(rest: client, sockets: sockets), client)
}

nonisolated final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    var on: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@MainActor @Suite(.serialized) struct BrowserLinkTests {
    // MARK: The rules

    @Test func theLinkIsBackWhenThePathReturnsOrTheSocketIsReadyAgain() {
        let offline = ConnectionState.offline(reason: "x")
        let retrying = ConnectionState.reconnecting(attempt: 2)
        // (old, new, restored)
        let table: [(ConnectionState, ConnectionState, Bool)] = [
            (offline, .connecting, true),             // the path came back
            (offline, retrying, true),
            (offline, .ready, true),
            (retrying, .ready, true),                 // after any drop (DECISION D13)
            (.connecting, .ready, true),              // the first connect: nothing waits yet, harmless
            (.ready, .ready, false),                  // nothing changed
            (.ready, retrying, false),                // the link just dropped
            (.ready, offline, false),
            (retrying, .reconnecting(attempt: 3), false),
            (.connecting, retrying, false),
            (retrying, offline, false),
            (offline, .offline(reason: "y"), false),
            (.ready, .signedOut(reason: "x"), false),
            (offline, .signedOut(reason: "x"), false),
        ]
        for (old, new, expected) in table {
            #expect(BrowserLinkRule.restored(from: old, to: new) == expected, "\(old) → \(new)")
        }
    }

    @Test func aViewerDialsNowOnlyWhileItWaitsToRetry() {
        #expect(BrowserLinkRule.watchDialsNow(shown: true, stopped: false, ended: false, hasSocket: false, retrying: true))
        // Live, or its socket open: left alone.
        #expect(!BrowserLinkRule.watchDialsNow(shown: true, stopped: false, ended: false, hasSocket: true, retrying: false))
        #expect(!BrowserLinkRule.watchDialsNow(shown: true, stopped: false, ended: false, hasSocket: true, retrying: true))
        // A dial already asking for its address (no socket, no retry): left alone, so two sockets never race.
        #expect(!BrowserLinkRule.watchDialsNow(shown: true, stopped: false, ended: false, hasSocket: false, retrying: false))
        // Hidden, closed by the person, or over.
        #expect(!BrowserLinkRule.watchDialsNow(shown: false, stopped: false, ended: false, hasSocket: false, retrying: true))
        #expect(!BrowserLinkRule.watchDialsNow(shown: true, stopped: true, ended: false, hasSocket: false, retrying: true))
        #expect(!BrowserLinkRule.watchDialsNow(shown: true, stopped: false, ended: true, hasSocket: false, retrying: true))
    }

    @Test func theChatMenuItemIsGreyWithOfflineUnderItWhileTheLinkIsDown() {
        #expect(BrowserMenuRule.title == "Watch Browser")
        let online = BrowserMenuRule.chatItem(offline: false)
        #expect(online.subtitle == nil && !online.disabled)
        let offline = BrowserMenuRule.chatItem(offline: true)
        #expect(offline.subtitle == "Offline" && offline.disabled)
    }

    // MARK: The viewer's session

    private func watch(_ sockets: any GatewayPluginSockets) -> BrowserWatchSession {
        let (service, _) = service(sockets: sockets)
        return BrowserWatchSession(service: service, rowId: "0123456789abcdef01234567", base: BrowserWire.plugin,
                                   profile: "default", name: "Hermes")
    }

    @Test func aViewerWaitingOutItsBackOffDialsAtOnceFromTheFirstStep() async {
        let sockets = CountingSockets()
        let session = watch(sockets)
        session.setShown(true)
        #expect(await BotsTest.waitUntil { session.debugRetrying })
        #expect(sockets.count == 1 && session.debugAttempt == 1 && session.link == .reconnecting)
        let dials = session.debugDials

        session.linkRestored()
        // At once: no wait for the timer, and the back-off starts over.
        #expect(!session.debugRetrying && session.debugAttempt == 0 && session.debugDials == dials + 1)
        #expect(await BotsTest.waitUntil { sockets.count == 2 })
        // That dial failed too: it waits again, one step in (not two).
        #expect(await BotsTest.waitUntil { session.debugRetrying })
        #expect(session.debugAttempt == 1)
        session.stop()
    }

    @Test func aViewerMidDialIsLeftAlone() async {
        let sockets = CountingSockets(hang: true)
        let session = watch(sockets)
        session.setShown(true)
        #expect(await BotsTest.waitUntil { sockets.count == 1 })
        let dials = session.debugDials
        for _ in 0..<20 { session.linkRestored() }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(sockets.count == 1 && session.debugDials == dials && !session.debugRetrying)
        session.stop()
    }

    @Test func aHiddenStoppedOrEndedViewerDoesNotDial() async {
        // Hidden (the app in the background, or the viewer covered).
        let sockets = CountingSockets()
        let hidden = watch(sockets)
        hidden.setShown(true)
        #expect(await BotsTest.waitUntil { hidden.debugRetrying })
        hidden.setShown(false)
        var dials = hidden.debugDials
        hidden.linkRestored()
        #expect(hidden.debugDials == dials && !hidden.debugRetrying)

        // Closed by the person.
        let stopped = watch(sockets)
        stopped.setShown(true)
        #expect(await BotsTest.waitUntil { stopped.debugRetrying })
        stopped.stop()
        dials = stopped.debugDials
        stopped.linkRestored()
        #expect(stopped.debugDials == dials && stopped.isStopped)

        // Over: the plugin said the browser is gone (404).
        let ended = watch(NoPluginSockets())
        ended.setShown(true)
        #expect(await BotsTest.waitUntil { ended.ended })
        dials = ended.debugDials
        ended.linkRestored()
        #expect(ended.debugDials == dials && ended.ended)

        let before = sockets.count
        try? await Task.sleep(for: .milliseconds(150))
        #expect(sockets.count == before)
    }

    @Test func theServiceTellsEveryOpenViewerAndNoneAfterSignOut() async {
        let sockets = CountingSockets()
        let (service, _) = service(sockets: sockets)
        let one = BrowserWatchSession(service: service, rowId: "0123456789abcdef01234567", base: BrowserWire.plugin, profile: "default", name: "Hermes")
        let two = BrowserWatchSession(service: service, rowId: "0123456789abcdef01234568", base: BrowserWire.plugin, profile: "ivy", name: "Ivy")
        one.setShown(true)
        two.setShown(true)
        #expect(await BotsTest.waitUntil { one.debugRetrying && two.debugRetrying })
        #expect(sockets.count == 2)
        service.linkRestored()
        #expect(!one.debugRetrying && !two.debugRetrying)
        #expect(await BotsTest.waitUntil { sockets.count == 4 })

        #expect(await BotsTest.waitUntil { one.debugRetrying && two.debugRetrying })
        service.shutdown()
        let dials = (one.debugDials, two.debugDials)
        service.linkRestored()
        #expect(one.debugDials == dials.0 && two.debugDials == dials.1)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(sockets.count == 4)
    }

    // MARK: The list socket (the Bots rows' "Browsing …" line)

    @Test func theListSocketWaitingOutItsBackOffDialsAtOnce() async {
        let sockets = CountingSockets()
        let (service, _) = service(sockets: sockets)
        let subscription = service.activity.subscribe {}
        #expect(await BotsTest.waitUntil { service.activity.debugRetrying })
        #expect(sockets.count == 1 && service.activity.debugAttempt == 1 && !service.activity.debugDialing)

        service.activity.linkRestored()
        #expect(!service.activity.debugRetrying && service.activity.debugDialing && service.activity.debugAttempt == 0)
        #expect(await BotsTest.waitUntil { sockets.count == 2 })
        #expect(sockets.paths.allSatisfy { $0.hasSuffix("/activity") })
        subscription.cancel()
    }

    /// A gateway without the plugin goes quiet (no retry). When the link comes back, it looks once more, so the rows'
    /// lines appear after the main bot installed the plugin and Hermes restarted (DECISION D14).
    @Test func aListThatWentQuietBecauseThePluginWasMissingLooksAgain() async {
        let sockets = CountingSockets(hang: true)
        let installed = Flag(false)
        let (service, client) = service(sockets: sockets, plugin: { installed.on })
        let subscription = service.activity.subscribe {}
        #expect(await BotsTest.waitUntil { client.restCalls.count >= 2 && !service.activity.debugDialing })
        #expect(!service.activity.debugRetrying && sockets.count == 0)

        // Still missing: one more look, quiet again.
        let looks = client.restCalls.count
        service.activity.linkRestored()
        #expect(service.activity.debugDialing)
        #expect(await BotsTest.waitUntil { client.restCalls.count > looks && !service.activity.debugDialing })
        #expect(sockets.count == 0 && !service.activity.debugRetrying)

        // Installed since: this time the socket is dialled.
        installed.on = true
        service.activity.linkRestored()
        #expect(await BotsTest.waitUntil { sockets.count == 1 })
        // A dial in flight is left alone.
        for _ in 0..<20 { service.activity.linkRestored() }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(sockets.count == 1)
        subscription.cancel()
    }

    @Test func aListNobodyReadsDoesNotDial() async {
        let sockets = CountingSockets()
        let (service, client) = service(sockets: sockets)
        service.activity.linkRestored()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sockets.count == 0 && client.restCalls.isEmpty && !service.activity.debugDialing)

        // After sign-out too.
        let subscription = service.activity.subscribe {}
        #expect(await BotsTest.waitUntil { service.activity.debugRetrying })
        service.shutdown()
        service.activity.linkRestored()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sockets.count == 1 && !service.activity.debugDialing)
        subscription.cancel()
    }

    /// The list left the screen while the socket was down and its back-off ran out with nobody listening. Coming back
    /// inside the 3 s linger dials (it used to stay silent until the list was left for longer).
    @Test func comingBackDuringTheLingerAfterABackOffRanOutDials() async {
        let sockets = CountingSockets()
        let (service, _) = service(sockets: sockets)
        let first = service.activity.subscribe {}
        #expect(await BotsTest.waitUntil { service.activity.debugRetrying })
        first.cancel()                                   // lingers 3 s; the 1 s back-off runs out meanwhile
        try? await Task.sleep(for: .milliseconds(1400))
        #expect(sockets.count == 1)
        let second = service.activity.subscribe {}
        #expect(service.activity.debugDialing)
        #expect(await BotsTest.waitUntil { sockets.count == 2 })
        second.cancel()
    }
}
