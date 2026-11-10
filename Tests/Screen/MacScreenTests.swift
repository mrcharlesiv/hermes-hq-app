// The Mac screen plugin's health (docs/spec/3x-screen.md §5.9, §5.10, §5.13): what it means for control, the route
// under its new and old names, and every line "Check setup" can show.

import Foundation
import Testing
@testable import HermesHQNative

nonisolated enum MacFixture {
    static func health(_ change: (inout [String: JSONValue]) -> Void = { _ in }) -> JSONValue {
        var value: [String: JSONValue] = [
            "installed": true, "ok": true, "platform": "darwin", "drift": .array([]), "enabled": true, "control": true,
            "helper": ["ok": true, "tcc": ["screen": true, "events": true], "locked": false, "secure_input": false, "paused": false],
        ]
        change(&value)
        return .object(value)
    }

    static func status(_ change: (inout ScreenStatus) -> Void = { _ in }) -> ScreenStatus {
        var status = ScreenStatus(profileKey: "default", supported: true, installed: true, running: true, missing: [], display: "This Mac",
                                  geometry: "1920x1080x24", installCommand: nil, blocker: nil, placement: nil, lease: ScreenLease())
        change(&status)
        return status
    }
}

@MainActor struct MacScreenTests {
    @Test func controlNeedsBothTheSettingAndAccessibility() {
        #expect(MacScreen.parse(MacFixture.health()) == MacScreen(control: true, inputReady: true, locked: false, secureInput: false))
        #expect(MacScreen.parse(MacFixture.health { $0["control"] = false }) == MacScreen(control: false, inputReady: false))
        #expect(MacScreen.parse(MacFixture.health { $0["helper"] = ["ok": true, "tcc": ["screen": true, "events": false]] })
            == MacScreen(control: true, inputReady: false))
        #expect(MacScreen.parse(MacFixture.health { $0["helper"] = ["ok": true, "tcc": ["screen": true, "events": true], "locked": true, "secure_input": true] })
            == MacScreen(control: true, inputReady: true, locked: true, secureInput: true))
        #expect(MacScreen.parse(MacFixture.health { $0["helper"] = .null }) == MacScreen(control: true, inputReady: false))
    }

    @Test func onlyAnInstalledPluginCounts() {
        #expect(MacScreen.parse(nil) == nil)
        #expect(MacScreen.parse(.null) == nil)
        #expect(MacScreen.parse(["installed": false, "control": true]) == nil)
        #expect(MacScreen.parse(["installed": "yes"]) == nil)
        #expect(MacScreen.parse(.array([])) == nil)
        #expect(MacScreen.parse(["installed": true]) == MacScreen())
    }

    @Test func theOldRouteIsTriedOnA404AndAskedFirstAfterwards() async throws {
        let client = FakeGatewayClient()
        client.onRest { path, _ in
            if path.contains("hermes-hq-screen") { throw HTTPError(status: 404, body: nil) }
            return Data(#"{"installed":true,"control":true}"#.utf8)
        }
        let reader = MacScreenHealthReader(rest: client)
        #expect(try await reader.read()?["installed"]?.bool == true)
        #expect(client.restLog.map(\.path) == ["/api/plugins/hermes-hq-screen/health", "/api/plugins/dispatch-screen/health"])
        _ = try await reader.read()
        #expect(client.restLog.map(\.path).suffix(1) == ["/api/plugins/dispatch-screen/health"])
        #expect(client.restLog.count == 3)
        #expect(await reader.remembered == .legacy)
    }

    @Test func bothMissingIsNoPluginAndForgetsTheRememberedRoute() async throws {
        let client = FakeGatewayClient()
        let legacyGone = Locked(false)
        client.onRest { path, _ in
            if path.contains("hermes-hq-screen") || legacyGone.value { throw HTTPError(status: 404, body: nil) }
            return Data(#"{"installed":true}"#.utf8)
        }
        let reader = MacScreenHealthReader(rest: client)
        _ = try await reader.read()
        legacyGone.set(true)
        #expect(try await reader.read() == nil)
        #expect(await reader.remembered == nil)
        // The plugin was updated: the new route answers and is asked first from then on.
        client.onRest { _, _ in Data(#"{"installed":true}"#.utf8) }
        _ = try await reader.read()
        _ = try await reader.read()
        #expect(client.restLog.map(\.path).suffix(2) == ["/api/plugins/hermes-hq-screen/health", "/api/plugins/hermes-hq-screen/health"])
    }

    @Test func anyOtherFailureIsThrownNotMistakenForMissing() async {
        let client = FakeGatewayClient()
        client.onRest { _, _ in throw HTTPError(status: 500, body: "boom") }
        let reader = MacScreenHealthReader(rest: client)
        await #expect(throws: HTTPError.self) { try await reader.read() }
        #expect(client.restLog.count == 1)                                   // no second route after a real failure
        client.onRest { _, _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: URLError.self) { try await reader.read() }
    }

    @Test func oneRequestAtATime() async throws {
        let client = SlowRestClient()
        let reader = MacScreenHealthReader(rest: client)
        async let first = reader.read()
        async let second = reader.read()
        async let third = reader.read()
        _ = try await (first, second, third)
        #expect(client.hits.value == 1)
        _ = try await reader.read()
        #expect(client.hits.value == 2)
    }

    @Test func aRouteThatNeverAnswersTimesOut() async {
        let started = ContinuousClock.now
        await #expect(throws: ScreenTimeout.Expired.self) {
            try await ScreenTimeout.run(.milliseconds(150)) { try await Task.sleep(for: .seconds(30)) }
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect((try? await ScreenTimeout.run(.seconds(5)) { 7 }) == 7)
    }
}

/// A REST client that takes a moment, to check that readers share one request.
nonisolated final class SlowRestClient: GatewayClient, Sendable {
    let account = GatewayAccount(id: "http://127.0.0.1:1|slow", baseURL: URL(string: "http://127.0.0.1:1")!, kind: .password, username: "slow", label: "slow")
    let hits = Locked(0)

    func rest(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async throws -> Data {
        hits.mutate { $0 += 1 }
        try await Task.sleep(for: .milliseconds(150))
        return Data(#"{"installed":true}"#.utf8)
    }

    func call(_ method: String, _ params: JSONValue, timeout: Duration) async throws -> JSONValue { .object([:]) }
    func events() -> AsyncStream<GatewayEvent> { AsyncStream { $0.finish() } }
    func connectionStates() -> AsyncStream<ConnectionState> { AsyncStream { $0.yield(.ready); $0.finish() } }
    var latestReady: JSONValue? { nil }
    func appDidBecomeActive() {}
    func appDidEnterBackground() {}
    func shutdown() {}
}

@MainActor struct MacScreenReadinessTests {
    private func message(_ health: JSONValue?, _ status: ScreenStatus? = MacFixture.status()) -> String {
        MacScreenReadiness.message(health: health, status: status)
    }

    private func says(_ expected: String, _ health: JSONValue?, _ status: ScreenStatus? = MacFixture.status(), line: Int = #line) {
        let said = message(health, status)
        #expect(said == expected, "line \(line)")
    }

    @Test func everyLineInItsOrder() {
        let helper: (inout [String: JSONValue], [String: JSONValue]) -> Void = { health, changes in
            var value = health["helper"]?.object ?? [:]
            for (key, change) in changes { value[key] = change }
            health["helper"] = .object(value)
        }
        // 1
        says("The Mac screen plugin is not loaded in this gateway yet.", nil)
        says("The Mac screen plugin is not loaded in this gateway yet.", MacFixture.health { $0["installed"] = false })
        // 2
        says("Live Mac screen sharing needs a Mac gateway.", MacFixture.health { $0["platform"] = "linux" })
        // 3
        let drifted = "The screen plugin could not verify compatibility with this Hermes version."
        says(drifted, MacFixture.health { $0["ok"] = false })
        says(drifted, MacFixture.health { $0["drift"] = ["runtime changed"] })
        says(drifted, MacFixture.health { $0["drift"] = nil })
        // 4
        says("Screen sharing is not enabled on the Mac yet.", MacFixture.health { $0["enabled"] = false })
        // 5
        says("Allow Screen Recording", MacFixture.health { $0["blocker"] = "  Allow Screen Recording  " })
        says("The Mac is asleep", MacFixture.health(), MacFixture.status { $0.blocker = "The Mac is asleep" })
        // 6
        says("This bot does not have access to the Mac’s screen.", MacFixture.health(), MacFixture.status { $0.supported = false })
        says("This bot does not have access to the Mac’s screen.", MacFixture.health(), nil)
        // 7
        let loading = "This gateway has not finished loading the Mac screen setup."
        says(loading, MacFixture.health(), MacFixture.status { $0.installed = false })
        says(loading, MacFixture.health(), MacFixture.status { $0.missing = ["helper"] })
        says(loading, MacFixture.health(), MacFixture.status { $0.display = ":99" })
        // 8
        says("The Mac screen helper has not answered yet. Open Screen to start it.", MacFixture.health { $0["helper"] = .null })
        says("The Mac screen helper has not answered yet. Open Screen to start it.", MacFixture.health { $0["helper"] = .object([:]) })
        // 9
        says("The Mac screen helper has not reported a healthy status yet.", MacFixture.health { helper(&$0, ["ok": false]) })
        // 10
        says("Allow Screen Recording for Hermes HQ Screen on the Mac.", MacFixture.health { $0["helper"] = ["ok": true, "tcc": ["screen": false]] })
        says("Allow Screen Recording for Hermes HQ Screen on the Mac.", MacFixture.health { $0["helper"] = ["ok": true, "tcc": .object([:])] })
        // 11
        says("Viewing is ready. Finish setup with Hermes to enable pointer, clicks, and typing.", MacFixture.health { $0["control"] = false })
        // 12
        says("Allow Accessibility for Hermes HQ Screen on the Mac to use control.", MacFixture.health { $0["helper"] = ["ok": true, "tcc": ["screen": true, "events": false]] })
        // 13
        says("Resume sharing from Hermes HQ Screen’s menu on the Mac.", MacFixture.health { helper(&$0, ["paused": true]) })
        // 14
        says("Display disconnected", MacFixture.health { helper(&$0, ["capture_error": "Display disconnected"]) })
        // 15
        says("The Mac screen helper is ready. Open Screen to start sharing.", MacFixture.health(), MacFixture.status { $0.running = false })
        // 16
        says("Viewing and control are ready. Open Screen, then tap Take Control to use the pointer and keyboard.", MacFixture.health())
        #expect(MacScreenReadiness.ready == message(MacFixture.health()))
    }

    @Test func earlierLinesWin() {
        // Not installed beats everything; a blocker beats the bot's own state; Screen Recording beats control.
        says("The Mac screen plugin is not loaded in this gateway yet.", MacFixture.health { $0["installed"] = false; $0["blocker"] = "x" })
        says("Allow Screen Recording", MacFixture.health { $0["blocker"] = "Allow Screen Recording" }, MacFixture.status { $0.supported = false })
        says("Allow Screen Recording for Hermes HQ Screen on the Mac.", MacFixture.health { $0["control"] = false; $0["helper"] = ["ok": true, "tcc": ["screen": false]] })
    }

    @Test func theGatewaysWordsNeverCarryTheOldName() {
        let said = message(MacFixture.health { $0["blocker"] = "Open Dispatch Screen and allow Screen Recording" })
        #expect(!said.lowercased().contains("dispatch"))
        #expect(said.contains("Hermes HQ Screen"))
        let capture = message(MacFixture.health {
            $0["helper"] = ["ok": true, "tcc": ["screen": true, "events": true], "capture_error": "dispatch-screen lost the display"]
        })
        #expect(!capture.lowercased().contains("dispatch"))
    }
}
