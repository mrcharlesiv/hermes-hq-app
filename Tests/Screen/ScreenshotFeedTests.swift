// Ports of the web's `bot-activity-model.test.ts` plus the feed's own rules (docs/spec/3x-screen.md §5.2, §5.14).

import Foundation
import Testing
@testable import HermesHQNative

nonisolated private func saved(_ name: String) -> String { "capture mode=som 1920x1080\n  (shareable screenshot saved to /h/.hermes/cache/images/\(name))" }
nonisolated private func toolRow(_ id: String, at: Double = 1) -> JSONValue {
    ["role": "tool", "name": "computer_use", "tool_call_id": .string(id), "timestamp": .number(at), "content": .string(saved("\(id).png"))]
}

private struct Offline: Error {}
nonisolated private func sessionsAnswer(_ active: Double) -> Data { Data(#"{"sessions":[{"id":"s1","last_active":\#(active),"cwd":"/Users/x/work"}]}"#.utf8) }
nonisolated private func rowsAnswer(_ ids: [(String, Double)]) -> Data {
    encodeJSON(["messages": .array(ids.map { toolRow($0.0, at: $0.1) })])
}

@MainActor struct ScreenshotRulesTests {
    @Test func findsTheNewestScreenshotWithWhatTheBotWasDoing() {
        // The gateway answers `order=latest` with its newest rows in chronological order (oldest of them first), as the
        // web app's latestShot reads them: the newest screenshot is the last one in the page.
        let rows: [JSONValue] = [
            ["role": "user", "content": "check the status page"],
            ["role": "assistant", "content": "", "tool_calls": [["id": "c1", "function": ["name": "computer_use", "arguments": #"{"action":"capture"}"#]]]],
            ["role": "tool", "name": "computer_use", "tool_call_id": "c1", "timestamp": 100, "content": .string(saved("computer_use_1.png"))],
            ["role": "assistant", "content": "", "tool_calls": [["id": "c2", "function": ["name": "computer_use", "arguments": #"{"action":"click","app":"Safari"}"#]]]],
            ["role": "tool", "name": "computer_use", "tool_call_id": "c2", "timestamp": 110, "content": .string(saved("computer_use_2.png"))],
            ["role": "assistant", "content": "", "tool_calls": [["id": "c3", "function": ["name": "terminal", "arguments": "{}"]]]],
            ["role": "tool", "name": "terminal", "tool_call_id": "c3", "timestamp": 120, "content": "screenshot saved to /tmp/not-a-screen-tool.png"],
        ]
        #expect(ScreenshotRules.latestShot(rows: rows) == ScreenShot(id: "c2", src: "/h/.hermes/cache/images/computer_use_2.png", caption: "Clicked in Safari", at: 110))
        #expect(ScreenshotRules.latestShot(rows: Array(rows.prefix(3)))?.id == "c1", "an older page ends with the older capture")
        #expect(ScreenshotRules.latestShot(rows: [rows[0]]) == nil)
        let browser: JSONValue = ["role": "tool", "tool_name": "browser_navigate", "tool_call_id": "b1",
                                  "args": ["url": "https://status.example.com/x"], "content": #"{"screenshot_path":"/h/s.png"}"#]
        let shot = ScreenshotRules.latestShot(rows: [browser])
        #expect(shot?.src == "/h/s.png")
        #expect(shot?.caption == "Opened status.example.com")
        #expect(shot?.at == nil)
        // No call id: the id is made of the tool and its time (or its place in the page).
        #expect(ScreenshotRules.latestShot(rows: [["role": "tool", "name": "computer_use", "timestamp": 1791700123, "content": .string(saved("a.png"))]])?.id == "computer_use-1791700123")
        #expect(ScreenshotRules.latestShot(rows: [["role": "user"], ["role": "tool", "name": "computer_use", "content": .string(saved("a.png"))]])?.id == "computer_use-1")
    }

    @Test func takesALiveCaptureStraightFromItsEnvelope() {
        let payload: JSONValue = ["name": "computer_use", "tool_id": "t9", "args": ["action": "type"],
                                  "result": ["_multimodal": true, "content": [["type": "image_url", "image_url": ["url": "data:image/png;base64,AAAA"]]]]]
        #expect(ScreenshotRules.liveShot(payload: payload, now: 500) == ScreenShot(id: "t9", src: "data:image/png;base64,AAAA", caption: "Typed", at: 500))
        #expect(ScreenshotRules.liveShot(payload: ["name": "computer_use", "tool_id": "t10", "summary": .string(saved("computer_use_9.png"))], now: 1)?.src
                == "/h/.hermes/cache/images/computer_use_9.png")
        #expect(ScreenshotRules.liveShot(payload: ["name": "terminal", "result": "x"], now: 1) == nil)
        #expect(ScreenshotRules.liveShot(payload: ["name": "computer_use", "result": "no image"], now: 1) == nil)
        #expect(ScreenshotRules.liveShot(payload: ["name": "browser_vision", "result_text": "Screenshot path: /h/b.png"], now: 77)?.id == "browser_vision-77")
    }

    @Test func captions() {
        #expect(ScreenshotRules.shotCaption(tool: "computer_use", args: #"{"action":"scroll"}"#) == "Scrolled")
        #expect(ScreenshotRules.shotCaption(tool: "computer_use", args: [:]) == "Used the computer")
        #expect(ScreenshotRules.shotCaption(tool: "computer_use", args: nil) == "Used the computer")
        #expect(ScreenshotRules.shotCaption(tool: "browser_vision", args: [:]) == "Looked at the page")
        #expect(ScreenshotRules.shotCaption(tool: "browser_frobnicate", args: [:]) == "Used the browser")
        #expect(ScreenshotRules.shotCaption(tool: "browser_navigate", args: ["url": "not a url"]) == "Opened a page")
        #expect(ScreenshotRules.shotCaption(tool: "browser_navigate", args: ["url": "http://localhost:8080/a"]) == "Opened localhost:8080")
        let table: [(String, String)] = [
            ("capture", "Looked at the screen"), ("screenshot", "Looked at the screen"), ("click", "Clicked"), ("left_click", "Clicked"),
            ("double_click", "Double-clicked"), ("right_click", "Right-clicked"), ("middle_click", "Clicked"), ("type", "Typed"),
            ("key", "Pressed keys"), ("hotkey", "Pressed keys"), ("press_key", "Pressed keys"), ("scroll", "Scrolled"),
            ("drag", "Dragged"), ("move", "Moved the pointer"), ("mouse_move", "Moved the pointer"), ("zoom", "Zoomed in"),
            ("wait", "Waited"), ("CLICK", "Clicked"), ("levitate", "Used the computer"),
        ]
        for (action, words) in table {
            #expect(ScreenshotRules.shotCaption(tool: "computer_use", args: ["action": .string(action)]) == words)
        }
        #expect(ScreenshotRules.shotCaption(tool: "computer_use_preview", args: ["action": "click", "app": "Safari"]) == "Clicked in Safari")
        #expect(ScreenshotRules.shotCaption(tool: "computer_use", args: ["action": "click", "app": ""]) == "Clicked")
        let browser: [(String, String)] = [
            ("browser_screenshot", "Looked at the page"), ("browser_click", "Clicked in the browser"), ("browser_type", "Typed in the browser"),
            ("browser_scroll", "Scrolled the page"), ("browser_snapshot", "Read the page"), ("browser_back", "Went back"),
        ]
        for (tool, words) in browser { #expect(ScreenshotRules.shotCaption(tool: tool, args: nil) == words) }
    }

    @Test func ages() {
        #expect(ScreenshotRules.shotAge(at: nil, now: 0) == "")
        #expect(ScreenshotRules.shotAge(at: 100, now: 105) == "just now")
        #expect(ScreenshotRules.shotAge(at: 100, now: 90) == "just now")
        #expect(ScreenshotRules.shotAge(at: 100, now: 142) == "42 s ago")
        #expect(ScreenshotRules.shotAge(at: 100, now: 100 + 7 * 60) == "7 min ago")
        #expect(ScreenshotRules.shotAge(at: 100, now: 100 + 5 * 3600) == "5 h ago")
        let old = ScreenshotRules.shotAge(at: 1_791_700_123, now: 1_791_700_123 + 3 * 86_400, locale: Locale(identifier: "en_US"),
                                          timeZone: TimeZone(identifier: "UTC") ?? .current)
        #expect(old == "Oct 11")
    }

    @Test func tellsAMacOrAWindowsGatewayFromThePathsItReports() {
        #expect(ScreenshotRules.hostKind(["/Users/x/.hermes/cache/images/c.png"]) == .mac)
        #expect(ScreenshotRules.hostKind([nil, #"C:\Users\x\hermes"#]) == .windows)
        #expect(ScreenshotRules.hostKind(["D:/work"]) == .windows)
        #expect(ScreenshotRules.hostKind(["data:image/png;base64,AA", "/home/x"]) == nil)
        #expect(ScreenshotRules.hostKind(["/opt/homebrew/bin"]) == .mac)
        #expect(ScreenshotRules.hostKind([]) == nil)
    }

    @Test func headingsNameTheBotAndEndTheBlockerWithOnePeriod() {
        let plain = ScreenshotRules.heading(.unsupported, name: "Hermes", host: nil, blocker: nil)
        #expect(plain.title == "Screen sharing isn’t set up on the computer running Hermes")
        #expect(plain.detail == "Instead, Hermes’s latest screenshot shows here and updates while the bot works.")
        #expect(ScreenshotRules.heading(.unsupported, name: "Hermes", host: .windows, blocker: nil).title
                == "Live screen sharing isn’t available on the computer running Hermes")
        let blocked = ScreenshotRules.heading(.blocked, name: "Ivy", host: .mac, blocker: "Screen sharing is off on this Mac.")
        #expect(blocked.title == "Screen sharing needs attention")
        #expect(blocked.detail == "Screen sharing is off on this Mac. Meanwhile, Ivy’s latest screenshot shows here.")
        #expect(ScreenshotRules.heading(.blocked, name: "Ivy", host: nil, blocker: "No display").detail == "No display. Meanwhile, Ivy’s latest screenshot shows here.")
        #expect(ScreenshotRules.heading(.blocked, name: "Ivy", host: nil, blocker: nil).detail == "Meanwhile, Ivy’s latest screenshot shows here.")
        let old = ScreenshotRules.heading(.unavailable, name: "Ivy", host: nil, blocker: nil)
        #expect(old.title == "Screen needs a newer Hermes")
        #expect(old.detail == "Update Hermes on the computer running Hermes to watch live. Meanwhile, Ivy’s latest screenshot shows here.")
        // A Hermes Cloud agent: Nous updates its Hermes, so no update instruction.
        let cloud = ScreenshotRules.heading(.unavailable, name: "Ivy", host: nil, blocker: nil, managed: true)
        #expect(cloud.title == "Screen isn’t on this Hermes Cloud release yet")
        #expect(!cloud.detail.contains("Update Hermes"))
        #expect(ScreenshotRules.heading(.blocked, name: "Ivy", host: nil, blocker: nil, managed: true).title == "Screen sharing needs attention")
    }

    @Test func sessionsAreReadNewestActivityFirst() throws {
        let data = Data(#"{"sessions":[{"id":"a","last_active":5,"cwd":"/Users/x"},{"id":"b","last_active":9},{"last_active":99}]}"#.utf8)
        let sessions = try ScreenshotRules.sessions(data)
        #expect(sessions.map(\.id) == ["b", "a"])
        #expect(sessions.last?.cwd == "/Users/x")
        #expect(try ScreenshotRules.rows(Data(#"{"messages":[{"role":"user"}]}"#.utf8)).count == 1)
    }

    // MARK: The poll

    @Test func thePollRetriesAFailedReadInsteadOfSettlingOnAFalseEmptyState() async {
        var states: [ScreenshotPoller.Empty] = [], shots: [String] = []
        var fail = true, reads = 0, limits: [Int] = []
        let poller = ScreenshotPoller(sessions: { [RecentScreenSession(id: "s1", active: 5)] }, messages: { _, limit in
            reads += 1
            limits.append(limit)
            if fail { throw Offline() }
            return [toolRow("c1")]
        })
        poller.shot = { shots.append($0.id) }
        poller.empty = { states.append($0) }
        await poller.poll()
        #expect(states.isEmpty)
        await poller.poll()
        #expect(states == [.unreachable])
        fail = false
        await poller.poll()
        #expect(shots == ["c1"])
        await poller.poll()
        #expect(reads == 3)                  // the same session, unmoved: no second fetch
        #expect(limits == [40, 40, 40])
    }

    @Test func thePollFetchesFewerRowsOnceAScreenshotWasFound() async {
        var active = 5.0, limits: [Int] = []
        let poller = ScreenshotPoller(sessions: { [RecentScreenSession(id: "s1", active: active)] }, messages: { _, limit in
            limits.append(limit)
            return [toolRow("c1")]
        })
        await poller.poll()
        active = 6
        await poller.poll()
        #expect(limits == [40, 8])
    }

    @Test func thePollSaysNoScreenshotsForABotWithNoSessionsEveryTime() async {
        var states: [ScreenshotPoller.Empty] = []
        let poller = ScreenshotPoller(sessions: { [] }, messages: { _, _ in [] })
        poller.empty = { states.append($0) }
        await poller.poll()
        await poller.poll()
        #expect(states == [.none, .none])
    }
}

@MainActor struct ScreenshotFeedTests {

    private func feed(_ client: FakeGatewayClient, now: Double = 1_000) -> ScreenshotFeed {
        let feed = ScreenshotFeed(client: client, profile: "default", name: "Hermes")
        feed.now = { now }
        feed.slow = { false }
        return feed
    }

    @Test func showsTheNewestStoredScreenshotAndPollsOnlyTheSessionsListWhileNothingMoves() async {
        let client = FakeGatewayClient()
        client.onRest { path, _ in path.hasSuffix("/messages") ? rowsAnswer([("c1", 900), ("c2", 990)]) : sessionsAnswer(5) }
        let feed = feed(client)
        #expect(feed.state == .searching)
        #expect(feed.emptyLine == "Looking for screenshots…")
        feed.setVisible(true)
        #expect(await waitUntil { feed.shot != nil })
        #expect(feed.shot?.id == "c2")
        #expect(feed.state == .loading)
        #expect(feed.emptyLine == "Loading the screenshot…")
        feed.loaded("c2", ok: true)
        #expect(feed.state == .shown)
        #expect(feed.caption() == "Used the computer · 10 s ago")
        #expect(feed.hostKind == .mac)
        await feed.tick()
        await feed.tick()
        #expect(client.restLog.filter { $0.path.hasSuffix("/messages") }.count == 1)
        #expect(client.restLog.filter { $0.path == "/api/profiles/sessions" }.count >= 3)
        let query = client.restLog.first { $0.path == "/api/profiles/sessions" }?.query ?? []
        let asked = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        #expect(asked == ["limit": "3", "offset": "0", "min_messages": "1", "archived": "exclude", "order": "recent", "profile": "default"])
        feed.stop()
    }

    /// Low Power Mode or a hot phone: half as often (DECISION D9, the web's power-aware interval).
    @Test func pollsHalfAsOftenWhileThePhoneIsSavingPower() async {
        let client = FakeGatewayClient()
        client.onRest { path, _ in path.hasSuffix("/messages") ? rowsAnswer([("c1", 900)]) : sessionsAnswer(5) }
        let feed = feed(client)
        feed.slow = { true }
        func polls() -> Int { client.restLog.filter { $0.path == "/api/profiles/sessions" }.count }
        feed.setVisible(true)
        #expect(await waitUntil { polls() == 1 })
        try? await Task.sleep(for: .seconds(4.5))
        #expect(polls() == 1, "a 3 s poll would have asked again by now")
        try? await Task.sleep(for: .seconds(3))
        #expect(polls() == 2, "the next one comes at 6 s")
        feed.stop()
    }

    @Test func hiddenItAsksNothing() async {
        let client = FakeGatewayClient()
        client.onRest { _, _ in sessionsAnswer(5) }
        let feed = feed(client)
        await feed.tick()
        #expect(client.restLog.isEmpty)
        feed.setVisible(true)
        #expect(await waitUntil { !client.restLog.isEmpty })
        feed.setVisible(false)
        let before = client.restLog.count
        await feed.tick()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(client.restLog.count == before)
        feed.stop()
    }

    @Test func aLiveToolShowsItsWorkingCaptionThenItsPictureWithoutABlank() async {
        let client = FakeGatewayClient()
        client.onRest { path, _ in path.hasSuffix("/messages") ? rowsAnswer([("c1", 900)]) : sessionsAnswer(5) }
        let feed = feed(client)
        var announced = 0
        feed.onNewShot = { announced += 1 }
        feed.isMine = { $0.sessionId == "ab12cd34" }
        feed.setVisible(true)
        #expect(await waitUntil { feed.shot != nil })
        feed.loaded("c1", ok: true)
        feed.handle(GatewayEvent(type: "tool.start", sessionId: "ab12cd34", seq: nil,
                                 payload: ["name": "computer_use", "args": ["action": "click", "app": "Safari"]]))
        #expect(feed.working == "Clicked in Safari")
        #expect(feed.caption() == "Clicked in Safari… · 1 min ago")
        // Somebody else's session: nothing.
        feed.handle(GatewayEvent(type: "tool.complete", sessionId: "ffff0000", seq: nil,
                                 payload: ["name": "computer_use", "tool_id": "x", "result": ["screenshot_path": "/h/x.png"]]))
        #expect(feed.shot?.id == "c1")
        feed.handle(GatewayEvent(type: "tool.complete", sessionId: "ab12cd34", seq: nil, payload: [
            "name": "computer_use", "tool_id": "c9", "args": ["action": "click", "app": "Safari"],
            "result": ["content": [["type": "image_url", "image_url": ["url": "data:image/png;base64,AAAA"]]]]]))
        #expect(feed.shot?.id == "c9")
        #expect(feed.state == .shown)              // the old picture stayed up; the inline one needs no load
        #expect(feed.working == "")
        #expect(feed.caption() == "Clicked in Safari · just now")
        #expect(announced == 1)
        // The same capture arriving by REST after its live event does not replace it; an older one neither.
        feed.handle(GatewayEvent(type: "tool.complete", sessionId: "ab12cd34", seq: nil,
                                 payload: ["name": "computer_use", "tool_id": "c9", "result": ["screenshot_path": "/h/c9.png"]]))
        #expect(feed.shot?.src == "data:image/png;base64,AAAA")
        #expect(announced == 1)
        feed.stop()
    }

    @Test func eventsArriveThroughTheClientAndStoredSessionsCount() async {
        let client = FakeGatewayClient()
        client.onRest { path, _ in path.hasSuffix("/messages") ? rowsAnswer([]) : sessionsAnswer(5) }
        let feed = feed(client)
        feed.setVisible(true)
        #expect(await waitUntil { feed.state == .none })
        #expect(feed.emptyLine == "No screenshots yet. When Hermes uses its computer or browser, the newest one appears here.")
        client.emit(GatewayEvent(type: "tool.complete", sessionId: "99990000", seq: nil, payload: [
            "name": "browser_vision", "tool_id": "b1", "stored_session_id": "s1", "result": ["screenshot_path": "/Users/x/b1.png"]]))
        #expect(await waitUntil { feed.shot?.id == "b1" })
        #expect(feed.state == .loading)
        feed.loaded("b1", ok: false)
        #expect(feed.state == .expired)
        #expect(feed.emptyLine == "This screenshot has expired: the gateway keeps only its 20 most recent screenshots.")
        feed.loaded("someone-else", ok: true)
        #expect(feed.state == .expired)
        feed.stop()
    }

    /// Review finding 5: a picture that could not be fetched is not an expired capture, and is tried again.
    @Test func aFailedDownloadIsRetriedAndOnlyAMissingFileIsExpired() async {
        #expect(!ScreenshotFeed.isGone(URLError(.networkConnectionLost)) && !ScreenshotFeed.isGone(URLError(.timedOut)))
        #expect(!ScreenshotFeed.isGone(HTTPError(status: 502, body: nil)) && !ScreenshotFeed.isGone(HTTPError(status: 500, body: nil)))
        #expect(ScreenshotFeed.isGone(HTTPError(status: 404, body: nil)) && ScreenshotFeed.isGone(HTTPError(status: 410, body: nil)))

        let client = FakeGatewayClient()
        client.onRest { path, _ in path.hasSuffix("/messages") ? rowsAnswer([]) : sessionsAnswer(5) }
        let feed = feed(client)
        feed.setVisible(true)
        #expect(await waitUntil { feed.state == .none })
        client.emit(GatewayEvent(type: "tool.complete", sessionId: "99990000", seq: nil, payload: [
            "name": "browser_vision", "tool_id": "b1", "stored_session_id": "s1", "result": ["screenshot_path": "/Users/x/b1.png"]]))
        #expect(await waitUntil { feed.shot?.id == "b1" && feed.state == .loading })
        feed.stop()                                                  // the poll loop is out of the way: every step below is the test's
        let attempt = feed.loadAttempt
        feed.loadFailed("b1")                                        // what the view reports for a thrown URLError
        #expect(feed.state == .unloadable)
        #expect(feed.emptyLine == "Can’t load the screenshot. Trying again…")
        feed.retryDue()                                              // after the next poll: the view is asked to fetch it again
        #expect(feed.loadAttempt == attempt + 1 && feed.state == .unloadable)
        feed.loadFailed("someone-else")
        #expect(feed.state == .unloadable)
        feed.loaded("b1", ok: true)                                  // the retry worked
        #expect(feed.state == .shown)
        let settled = feed.loadAttempt
        feed.retryDue()
        #expect(feed.loadAttempt == settled, "a shown picture is not fetched again")

        // After the quick tries, only every tenth poll asks again.
        for _ in 0...ScreenshotFeed.quickLoadTries { feed.loadFailed("b1") }
        let before = feed.loadAttempt
        for _ in 0..<9 { feed.retryDue() }
        #expect(feed.loadAttempt == before)
        feed.retryDue()
        #expect(feed.loadAttempt == before + 1)
        feed.loaded("b1", ok: false)                                 // the gateway answered 404: now it is expired
        #expect(feed.state == .expired)
    }

    @Test func unreachableShowsAfterTwoFailedPollsAndThePictureComesBackByItself() async {
        let client = FakeGatewayClient()
        let down = Locked(true)
        client.onRest { path, _ in
            if down.value { throw Offline() }
            return path.hasSuffix("/messages") ? rowsAnswer([("c1", 995)]) : sessionsAnswer(5)
        }
        let feed = feed(client)
        feed.setVisible(true)
        #expect(await waitUntil { client.restLog.count >= 1 })
        #expect(feed.state == .searching)
        for _ in 0..<40 where feed.state != .unreachable {
            await feed.tick()
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(feed.state == .unreachable)
        #expect(feed.emptyLine == "Can’t reach the gateway to look for screenshots. Trying again…")
        down.set(false)
        for _ in 0..<40 where feed.shot == nil {
            await feed.tick()
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(feed.shot?.id == "c1")
        feed.stop()
    }
}
