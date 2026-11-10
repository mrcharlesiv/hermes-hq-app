// More › Messaging (docs/spec/3x-morepages.md §12 acceptance 1): the status rule table, the request bodies with their
// exact keys, profile-in-body for approve / revoke / apply, the Telegram onboarding state machine, and the decoders
// fed bad data.

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

nonisolated private func platform(configured: Bool = true, enabled: Bool = true, running: Bool = true, state: String? = "connected",
                                  error: String? = nil, updated: String? = "2026-10-13T09:00:00Z") -> MessagingPlatform {
    MessagingPlatform(id: "chirp", name: "Chirp", configured: configured, enabled: enabled, gatewayRunning: running, state: state,
                      errorMessage: error, updatedAt: updated)
}

nonisolated private func keys(_ value: JSONValue?) -> [String] { (value?.object ?? [:]).keys.sorted() }

nonisolated private func http(_ status: Int, _ detail: String) -> HTTPError { HTTPError(status: status, body: "{\"detail\":\"\(detail)\"}") }

/// Waits (on the main actor's run of tasks) until `condition` holds.
@MainActor private func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let end = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

struct MessagingStatusTests {
    @Test func statusRuleTable() {
        typealias Row = (MessagingPlatform, String, MessagingStatus.Tone)
        let table: [Row] = [
            (platform(), "Connected", .good),
            (platform(configured: false, enabled: false, state: "disabled"), "Needs setup", .warn),
            (platform(configured: false, enabled: true, state: "not_configured"), "Needs setup", .warn),
            (platform(enabled: false, state: "disabled"), "Off", .muted),
            // Off wins over an old error: nothing is running to be wrong.
            (platform(enabled: false, state: "disabled", error: "Old failure"), "Off", .muted),
            (platform(state: "fatal", error: "Sign-in was refused. Check the bot token."), "Sign-in was refused. Check the bot token.", .bad),
            (platform(state: "connected", error: "   "), "Connected", .good),
            (platform(running: false, state: "gateway_stopped"), "Not running", .warn),
            (platform(running: false, state: nil), "Not running", .warn),
            (platform(running: false, state: "startup_failed"), "Startup failed", .bad),
            (platform(state: "connecting"), "Connecting…", .warn),
            (platform(state: "retrying"), "Retrying…", .warn),
            (platform(state: "fatal"), "Error", .bad),
            (platform(state: "pending_restart"), "Restart needed", .warn),
            // Running, never reported on: unknown, not "restart" (`S/messaging-state.ts`).
            (platform(state: "pending_restart", updated: nil), "Status unknown", .warn),
            (platform(state: nil), "Status unknown", .warn),
            (platform(state: "CONNECTED"), "Connected", .good),
            (platform(state: "half_open"), "Half Open", .warn),
        ]
        for (row, text, tone) in table {
            #expect(row.status.text == text, "\(row.state ?? "nil") configured \(row.configured) enabled \(row.enabled)")
            #expect(row.status.tone == tone, "\(text)")
        }
    }

    @Test func pairingAgeWords() {
        func age(_ minutes: Double?) -> String? { PairingPerson(platform: "chirp", userId: "1", ageMinutes: minutes).age }
        #expect(age(nil) == nil)
        #expect(age(0) == "Just now")
        #expect(age(0.4) == "Just now")
        #expect(age(12) == "12 min ago")
        #expect(age(59.9) == "59 min ago")
        #expect(age(125) == "2 hr ago")
        #expect(age(60 * 24 * 3) == "3 days ago")
        #expect(age(-5) == "Just now")
    }

    @Test func keyValueWords() {
        #expect(MessagingPlatformView.value(MessagingEnvVar(key: "A")) == "Not Set")
        #expect(MessagingPlatformView.value(MessagingEnvVar(key: "A", required: true)) == "Required")
        #expect(MessagingPlatformView.value(MessagingEnvVar(key: "A", isSet: true)).hasPrefix("Set"))
        #expect(MessagingEnvVar(key: "A_TOKEN", prompt: "  ").label == "A_TOKEN")
        #expect(MessagingEnvVar(key: "A_TOKEN", prompt: "Bot Token").label == "Bot Token")
    }

    @Test func connectedWords() {
        #expect(TelegramSetupView.connectedText("demo_bot") == "Connected to @demo_bot")
        #expect(TelegramSetupView.connectedText("@demo_bot") == "Connected to @demo_bot")
        #expect(TelegramSetupView.connectedText(nil) == "Connected to Telegram")
        #expect(TelegramSetupView.connectedText("  ") == "Connected to Telegram")
    }
}

struct MessagingBodyTests {
    @Test func bodiesCarryExactlyTheirKeys() throws {
        #expect(MessagingBodies.enabled(false) == .object(["enabled": false]))
        #expect(MessagingBodies.enabled(true) == .object(["enabled": true]))
        #expect(MessagingBodies.env("CHIRP_BOT_TOKEN", "v") == .object(["env": .object(["CHIRP_BOT_TOKEN": "v"])]))
        #expect(MessagingBodies.clear("CHIRP_PROXY") == .object(["clear_env": ["CHIRP_PROXY"]]))
        #expect(MessagingBodies.telegramStart(botName: nil) == .object([:]))
        #expect(MessagingBodies.telegramStart(botName: "  ") == .object([:]))
        #expect(MessagingBodies.telegramStart(botName: "Hermes") == .object(["bot_name": "Hermes"]))
    }

    @Test func profileGoesInTheBody() {
        let approve = MessagingBodies.approve(platform: "chirp", requestId: "req-1", profile: "inbox")
        #expect(approve == .object(["platform": "chirp", "request_id": "req-1", "profile": "inbox"]))
        #expect(keys(MessagingBodies.approve(platform: "chirp", requestId: "req-1", profile: nil)) == ["platform", "request_id"])
        #expect(keys(MessagingBodies.approve(platform: "chirp", requestId: "req-1", profile: "default")) == ["platform", "request_id"])
        let revoke = MessagingBodies.revoke(platform: "chirp", userId: "1001", profile: "inbox")
        #expect(revoke == .object(["platform": "chirp", "user_id": "1001", "profile": "inbox"]))
        #expect(keys(MessagingBodies.revoke(platform: "chirp", userId: "1001", profile: "")) == ["platform", "user_id"])
        let apply = MessagingBodies.telegramApply(allowed: ["42"], profile: "inbox")
        #expect(apply == .object(["allowed_user_ids": ["42"], "profile": "inbox"]))
        #expect(keys(MessagingBodies.telegramApply(allowed: ["42"], profile: nil)) == ["allowed_user_ids"])
    }

    @Test func callsGoWhereTheSpecSays() async throws {
        let client = MoreFakeClient { request in
            switch request.path {
            case "/api/messaging/platforms": return ["platforms": []]
            case "/api/messaging/telegram/onboarding/start":
                return ["pairing_id": "p 1", "deep_link": "https://t.me/x?start=1", "qr_payload": "https://t.me/x?start=1", "expires_at": "2099-01-01T00:00:00Z"]
            default: return ["ok": true, "hot_served": true, "message": "Chirp is connected.", "status": "waiting"]
            }
        }
        let api = MessagingAPI(client: client)
        _ = try await api.platforms(profile: "inbox")
        #expect(try await api.update("chi/rp", body: MessagingBodies.enabled(false), profile: "inbox") == true)
        #expect(try await api.test("chirp", profile: nil).message == "Chirp is connected.")
        _ = try await api.pairing(profile: "default")
        try await api.approve(platform: "chirp", requestId: "req-1", profile: "inbox")
        try await api.revoke(platform: "chirp", userId: "1001", profile: "inbox")
        let start = try await api.telegramStart(botName: nil, profile: "inbox")
        _ = try await api.telegramStatus(start.pairingId, profile: "inbox")
        _ = try await api.telegramApply(start.pairingId, allowed: ["42"], profile: "inbox")
        try await api.telegramCancel(start.pairingId, profile: "inbox")
        #expect(client.logLines == [
            "GET /api/messaging/platforms?profile=inbox",
            "PUT /api/messaging/platforms/chi%2Frp?profile=inbox",
            "POST /api/messaging/platforms/chirp/test",
            "GET /api/pairing",
            // Approve and revoke read the profile off the body: no query.
            "POST /api/pairing/approve",
            "POST /api/pairing/revoke",
            "POST /api/messaging/telegram/onboarding/start?profile=inbox",
            "GET /api/messaging/telegram/onboarding/p%201?profile=inbox",
            "POST /api/messaging/telegram/onboarding/p%201/apply?profile=inbox",
            "DELETE /api/messaging/telegram/onboarding/p%201?profile=inbox",
        ])
        let log = client.log
        #expect(log[1].body == .object(["enabled": false]))
        #expect(log[2].body == nil)
        #expect(log[4].body?["profile"] == "inbox" && keys(log[4].body) == ["platform", "profile", "request_id"])
        #expect(log[5].body?["profile"] == "inbox" && keys(log[5].body) == ["platform", "profile", "user_id"])
        #expect(log[6].body == .object([:]))
        #expect(log[8].body == .object(["allowed_user_ids": ["42"], "profile": "inbox"]))
    }

    /// A key's value is in the PUT body and nowhere else: not the path, not the query.
    @Test func aKeyValueNeverRidesInTheURL() async throws {
        let client = MoreFakeClient { _ in ["ok": true] }
        let secret = "chp-live-SECRET-value-123"
        _ = try await MessagingAPI(client: client).update("chirp", body: MessagingBodies.env("CHIRP_BOT_TOKEN", secret), profile: "inbox")
        let sent = try #require(client.log.first)
        #expect(!sent.description.contains(secret))
        #expect(!sent.path.contains(secret) && !sent.query.values.contains { $0.contains(secret) })
        #expect(sent.body == .object(["env": .object(["CHIRP_BOT_TOKEN": .string(secret)])]))
    }
}

struct MessagingDecoderTests {
    @Test func platformsDecodeLeniently() throws {
        let json = try JSONValue.parse(Data("""
        {"platforms":[
          {"id":"chirp","name":"Chirp","enabled":true,"configured":true,"gateway_running":true,"state":"connected",
           "env_vars":[{"key":"A","prompt":"Token","is_password":true,"is_set":true,"redacted_value":"abc…wxyz","required":true,"url":"https://example.com"},
                       {"key":"A"},{"prompt":"no key"},null,7,{"key":"B","advanced":true}]},
          {"id":"chirp","name":"A repeat"},
          {"name":"no id"}, null, "text", 12, [],
          {"id":77,"name":null,"enabled":"yes","env_vars":"none","docs_url":17,"error_message":null},
          {"id":"   "}
        ]}
        """.utf8))
        let rows = MessagingPlatform.list(json)
        #expect(rows.map(\.id) == ["chirp", "77"])
        #expect(rows[0].envVars.map(\.key) == ["A", "B"])
        #expect(rows[0].keys.map(\.key) == ["A"] && rows[0].advancedKeys.map(\.key) == ["B"])
        #expect(rows[0].envVars[0].info.isPassword && rows[0].envVars[0].info.isSet && rows[0].envVars[0].info.url == "https://example.com")
        #expect(rows[1].name == "77" && rows[1].enabled == false && rows[1].envVars.isEmpty && rows[1].guide == nil)
        #expect(rows[1].status.text == "Needs setup")
        for bad in ["{}", "[]", "null", "7", "\"x\"", "{\"platforms\":{}}", "{\"platforms\":null}"] {
            #expect(MessagingPlatform.list(try JSONValue.parse(Data(bad.utf8))).isEmpty, "\(bad)")
        }
    }

    @Test func anUnreadableListIsAnErrorNotAnEmptyPage() async {
        let client = MoreFakeClient { _ in ["oops": true] }
        await #expect(throws: PagesMessageError.self) { _ = try await MessagingAPI(client: client).platforms(profile: nil) }
    }

    @Test func setupGuideIsOnlyAWebLink() {
        func guide(_ url: String?) -> URL? { MessagingPlatform(id: "x", docsURL: url).guide }
        #expect(guide("https://example.com/docs") != nil)
        #expect(guide("http://example.com/docs") != nil)
        #expect(guide("javascript:alert(1)") == nil)
        #expect(guide("file:///etc/passwd") == nil)
        #expect(guide("") == nil && guide(nil) == nil)
    }

    @Test func pairingDecodesLeniently() throws {
        let json = try JSONValue.parse(Data("""
        {"pending":[{"platform":"Chirp","user_id":2001,"user_name":"Ada","request_id":"r1","age_minutes":"12"},
                    {"platform":"chirp","user_id":"2001","request_id":"r1-again"},
                    {"platform":"chirp","user_id":"2002"},
                    {"platform":"","user_id":"x","request_id":"r"}, {"user_id":"y"}, null, 4,
                    {"platform":"pigeon","user_id":"9","request_id":"r9","age_minutes":null}],
         "approved":[{"platform":"chirp","user_id":"1001","user_name":""},{"platform":"chirp","user_id":"1001"},"x"]}
        """.utf8))
        let pairing = MessagingPairing(json: json)
        #expect(pairing.pending.map(\.id) == ["chirp:2001", "pigeon:9"])
        #expect(pairing.pending[0].age == "12 min ago" && pairing.pending[0].name == "Ada")
        #expect(pairing.approved.map(\.id) == ["chirp:1001"] && pairing.approved[0].name == "1001")
        #expect(pairing.pending(for: "CHIRP").count == 1 && pairing.approved(for: "pigeon").isEmpty)
        for bad in ["{}", "[]", "null", "{\"pending\":7,\"approved\":{}}"] {
            let empty = MessagingPairing(json: try JSONValue.parse(Data(bad.utf8)))
            #expect(empty.pending.isEmpty && empty.approved.isEmpty)
        }
    }

    @Test func telegramShapesDecodeLeniently() throws {
        #expect(TelegramSetupStart(json: [:]) == nil)
        #expect(TelegramSetupStart(json: ["pairing_id": "p"]) == nil)
        let start = try #require(TelegramSetupStart(json: ["pairing_id": 12, "qr_payload": "https://t.me/x", "expires_at": "2026-10-14T00:35:03+00:00"]))
        #expect(start.pairingId == "12" && start.deepLink == "https://t.me/x" && start.openURL != nil)
        #expect(start.expiresAt == Date(timeIntervalSince1970: 1_791_938_103))
        #expect(TelegramSetupStart(pairingId: "p", deepLink: "javascript:alert(1)", qrPayload: "x").openURL == nil)
        #expect(TelegramSetupStart(pairingId: "p", deepLink: "tg://resolve?domain=x", qrPayload: "x").openURL != nil)
        #expect(TelegramSetupStatus(json: ["status": "waiting"]) == .waiting)
        #expect(TelegramSetupStatus(json: [:]) == .waiting)
        #expect(TelegramSetupStatus(json: ["status": "ready", "bot_username": "demo_bot", "owner_user_id": 42]) == .ready(botUsername: "demo_bot", ownerUserId: "42"))
        #expect(TelegramSetupStatus(json: ["status": "ready", "owner_user_id": "not a number"]) == .ready(botUsername: nil, ownerUserId: nil))
        #expect(TelegramSetupApplied(json: ["needs_restart": true]) == TelegramSetupApplied(needsRestart: true))
        #expect(TelegramSetupApplied(json: .null) == TelegramSetupApplied())
        #expect(MessagingTestResult(json: ["ok": true, "message": "Chirp is connected."]) == MessagingTestResult(ok: true, message: "Chirp is connected."))
        #expect(MessagingTestResult(json: .null).ok == false && !MessagingTestResult(json: .null).message.isEmpty)
    }

    @Test func datesParse() {
        let expected = Date(timeIntervalSince1970: 1_791_938_103)
        #expect(MessagingDates.parse("2026-10-14T00:35:03Z") == expected)
        #expect(MessagingDates.parse("2026-10-14T00:35:03+00:00") == expected)
        #expect(MessagingDates.parse("2026-10-14T00:35:03") == expected)
        #expect(MessagingDates.parse("2026-10-14T00:35:03.250Z") == expected.addingTimeInterval(0.25))
        #expect(MessagingDates.parse(.number(1_791_938_103)) == expected)
        #expect(MessagingDates.parse("1791938103") == expected)
        #expect(MessagingDates.parse("soon") == nil && MessagingDates.parse(nil) == nil && MessagingDates.parse(.null) == nil)
    }

    @Test func userIds() {
        #expect(TelegramSetup.userIds("42") == ["42"])
        #expect(TelegramSetup.userIds(" 42, 43 42\n") == ["42", "43"])
        #expect(TelegramSetup.userIds("") == nil && TelegramSetup.userIds("42, me") == nil && TelegramSetup.userIds("-42") == nil)
        #expect(TelegramSetup.userIds("٤٢") == nil)
    }
}

/// A scripted gateway for the onboarding state machine.
nonisolated private final class TelegramScript: Sendable {
    struct State {
        var statuses: [Result<TelegramSetupStatus, HTTPError>] = []
        var statusCalls = 0
        var applied: [(String, [String])] = []
        var cancelled: [String] = []
        var starts = 0
        var applyError: HTTPError?
        var startError: HTTPError?
        var expiresAt: Date? = Date().addingTimeInterval(600)
    }
    let state = Mutex(State())

    var calls: TelegramSetup.Calls {
        .init(
            start: { [self] in
                let (count, error, expires) = state.withLock { s -> (Int, HTTPError?, Date?) in s.starts += 1; return (s.starts, s.startError, s.expiresAt) }
                if let error { throw error }
                return TelegramSetupStart(pairingId: "pair-\(count)", deepLink: "https://t.me/x", qrPayload: "https://t.me/x", expiresAt: expires)
            },
            status: { [self] _ in
                let next = state.withLock { s -> Result<TelegramSetupStatus, HTTPError> in
                    s.statusCalls += 1
                    return s.statuses.isEmpty ? .success(.waiting) : s.statuses.removeFirst()
                }
                return try next.get()
            },
            apply: { [self] id, allowed in
                let error = state.withLock { s -> HTTPError? in s.applied.append((id, allowed)); return s.applyError }
                if let error { throw error }
                return TelegramSetupApplied(botUsername: "demo_bot", needsRestart: true)
            },
            cancel: { [self] id in state.withLock { $0.cancelled.append(id) } })
    }
}

@MainActor
struct TelegramSetupTests {
    private func machine(_ script: TelegramScript) -> TelegramSetup {
        let setup = TelegramSetup(calls: script.calls)
        setup.interval = .milliseconds(15)
        return setup
    }

    @Test func waitingThenReadyThenApplied() async {
        let script = TelegramScript()
        script.state.withLock { $0.statuses = [.success(.waiting), .success(.waiting), .success(.ready(botUsername: "demo_bot", ownerUserId: "42"))] }
        let setup = machine(script)
        var applied: TelegramSetupApplied?
        setup.onApplied = { applied = $0 }
        #expect(setup.phase == .idle)
        setup.start()
        #expect(setup.phase == .starting)
        #expect(await eventually { if case .waiting = setup.phase { return true }; return false })
        #expect(await eventually { setup.phase == .ready(botUsername: "demo_bot", ownerUserId: "42") })
        #expect(script.state.withLock { $0.statusCalls } == 3)
        setup.finish(allowed: ["42"])
        #expect(setup.phase == .applying)
        #expect(await eventually { applied != nil })
        #expect(setup.phase == .applied(TelegramSetupApplied(botUsername: "demo_bot", needsRestart: true)))
        #expect(script.state.withLock { $0.applied.map(\.0) } == ["pair-1"])
        #expect(script.state.withLock { $0.applied.first?.1 } == ["42"])
        // Closing after Finish gives nothing back.
        setup.close()
        await setup.cancelTask?.value
        #expect(script.state.withLock { $0.cancelled }.isEmpty)
        #expect(setup.phase == .applied(TelegramSetupApplied(botUsername: "demo_bot", needsRestart: true)))
    }

    @Test func closingBeforeFinishSendsTheDelete() async {
        let script = TelegramScript()
        let setup = machine(script)
        setup.start()
        #expect(await eventually { if case .waiting = setup.phase { return true }; return false })
        setup.close()
        await setup.cancelTask?.value
        #expect(script.state.withLock { $0.cancelled } == ["pair-1"])
        #expect(setup.phase == .idle)
        // The poll stopped with the sheet.
        let calls = script.state.withLock { $0.statusCalls }
        try? await Task.sleep(for: .milliseconds(80))
        #expect(script.state.withLock { $0.statusCalls } == calls)
    }

    @Test func closingWhenReadySendsTheDelete() async {
        let script = TelegramScript()
        script.state.withLock { $0.statuses = [.success(.ready(botUsername: "demo_bot", ownerUserId: nil))] }
        let setup = machine(script)
        setup.start()
        #expect(await eventually { setup.phase == .ready(botUsername: "demo_bot", ownerUserId: nil) })
        // Finish needs someone allowed.
        setup.finish(allowed: [])
        #expect(setup.notice == "Add at least one Telegram user ID.")
        #expect(script.state.withLock { $0.applied.isEmpty })
        setup.close()
        await setup.cancelTask?.value
        #expect(script.state.withLock { $0.cancelled } == ["pair-1"])
    }

    @Test func theLinkExpiresByTheClock() async {
        let script = TelegramScript()
        script.state.withLock { $0.expiresAt = Date().addingTimeInterval(0.06) }
        let setup = machine(script)
        setup.start()
        #expect(await eventually { setup.phase == .expired })
        // Expired: the gateway drops it itself, nothing to give back.
        setup.close()
        await setup.cancelTask?.value
        #expect(script.state.withLock { $0.cancelled }.isEmpty)
        // Start Again makes a new pairing.
        script.state.withLock { $0.expiresAt = Date().addingTimeInterval(600) }
        setup.start()
        #expect(await eventually { if case .waiting(let start) = setup.phase { return start.pairingId == "pair-2" }; return false })
        setup.close()
    }

    @Test func aGoneOrForgottenPairingReadsAsExpired() async {
        for status in [404, 410] {
            let script = TelegramScript()
            script.state.withLock { $0.statuses = [.failure(http(status, "gone"))] }
            let setup = machine(script)
            setup.start()
            #expect(await eventually { setup.phase == .expired }, "HTTP \(status)")
        }
    }

    @Test func aFailedReadKeepsWaiting() async {
        let script = TelegramScript()
        script.state.withLock { $0.statuses = [.failure(http(502, "Telegram is slow")), .success(.waiting), .success(.ready(botUsername: nil, ownerUserId: "7"))] }
        let setup = machine(script)
        setup.start()
        #expect(await eventually { setup.notice?.hasPrefix("Still waiting for Telegram.") == true })
        #expect(await eventually { setup.phase == .ready(botUsername: nil, ownerUserId: "7") })
        #expect(setup.notice == nil)
        setup.close()
    }

    @Test func aRefusedFinishStaysReadyWithTheReason() async {
        let script = TelegramScript()
        script.state.withLock { $0.statuses = [.success(.ready(botUsername: "demo_bot", ownerUserId: "42"))]; $0.applyError = http(400, "Allowed Telegram user IDs must be numeric.") }
        let setup = machine(script)
        setup.start()
        #expect(await eventually { setup.phase == .ready(botUsername: "demo_bot", ownerUserId: "42") })
        setup.finish(allowed: ["42"])
        #expect(await eventually { setup.notice == "Allowed Telegram user IDs must be numeric." })
        #expect(setup.phase == .ready(botUsername: "demo_bot", ownerUserId: "42"))
        setup.close()
        await setup.cancelTask?.value
        #expect(script.state.withLock { $0.cancelled } == ["pair-1"])
    }

    @Test func aStartThatFailsSaysWhyAndCanBeTriedAgain() async {
        let script = TelegramScript()
        script.state.withLock { $0.startError = http(502, "Telegram setup service is unavailable.") }
        let setup = machine(script)
        setup.start()
        #expect(await eventually { setup.phase == .failed("Telegram setup service is unavailable.") })
        script.state.withLock { $0.startError = nil }
        setup.start()
        #expect(await eventually { if case .waiting = setup.phase { return true }; return false })
        setup.close()
    }

    @Test func remainingTime() {
        let setup = TelegramSetup(calls: TelegramScript().calls)
        #expect(setup.remaining(at: Date()) == nil)
    }

    @Test func qrCodeDraws() {
        let image = TelegramQR.image("https://t.me/hermes_setup_demo_bot?start=abc")
        #expect(image != nil && (image?.size.width ?? 0) >= 150)
        #expect(TelegramQR.image("") == nil)
    }
}
