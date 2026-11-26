// Regression coverage for Pillar #2 feel & trust fixes:
// Haptics caching + send cue, NotificationOpener expiry preservation, AudioSessionCoordinator.isHeld guards,
// TasksStore 409 offline retry & forget() race cancellation, AppModel signOut decision, BoundedLRU eviction,
// gateway event subscriber filtering, and SessionStore duplicate key tolerance.

import Foundation
import Synchronization
import Testing
import UIKit
import UserNotifications
@testable import HermesHQNative

@Suite("Feel and trust fixes", .serialized)
struct FeelAndTrustTests {
    // MARK: - Helpers

    nonisolated private static func makeTask(
        _ id: String,
        _ title: String = "Task",
        notes: String = "",
        rev: Int = 3
    ) -> TodoTask {
        let obj: [String: JSONValue] = [
            "id": .string(id),
            "rev": .number(Double(rev)),
            "title": .string(title),
            "notes": .string(notes),
            "who": .string("me"),
            "status": .string("open"),
            "priority": .number(0),
            "updated_at": .string("2026-11-04T08:00:00-06:00"),
            "created_at": .string("2026-11-03T08:00:00-06:00"),
        ]
        return try! JSONDecoder().decode(TodoTask.self, from: JSONValue.object(obj).encoded())
    }

    nonisolated private static func wire(_ task: TodoTask) -> JSONValue {
        try! JSONValue.parse(JSONEncoder().encode(task))
    }

    nonisolated private static func sessionRow(_ id: String, profile: String = "alpha", title: String = "Chat") -> JSONValue {
        [
            "id": .string(id),
            "profile": .string(profile),
            "title": .string(title),
            "preview": .string("hi"),
            "last_active": .number(1_791_000_000),
            "started_at": .number(1_790_999_940),
            "message_count": .number(2),
            "source": .string("desktop"),
            "pinned": .bool(false),
            "unread": .bool(false),
            "hidden": .bool(false),
            "is_active": .bool(false),
        ]
    }

    // MARK: - 1. Haptics caching & composer send haptic

    @MainActor @Test func hapticsCachesSwitchAndGeneratorsAndInvalidatesOnDefaultsChange() {
        let before = UserDefaults.standard.object(forKey: Haptics.key)
        let oldSink = Haptics.sink
        defer {
            Haptics.sink = oldSink
            if let before {
                UserDefaults.standard.set(before, forKey: Haptics.key)
            } else {
                UserDefaults.standard.removeObject(forKey: Haptics.key)
            }
        }

        // While turned off, prepare & play never allocate UIFeedbackGenerators.
        Haptics.sink = nil
        Haptics.isOn = false
        let offBaseline = Haptics.generatorsMade
        Haptics.prepare(.light)
        Haptics.prepare(.selection)
        Haptics.prepare(.success)
        for _ in 0..<25 {
            Haptics.play(.light)
            Haptics.play(.selection)
            Haptics.play(.success)
        }
        #expect(Haptics.generatorsMade == offBaseline)

        // When enabled, each generator kind is created at most once across repeated prepares/plays.
        Haptics.isOn = true
        #expect(Haptics.isOn == true)

        let startLight = Haptics.generatorsMade
        Haptics.prepare(.light)
        Haptics.play(.light)
        let warmedLight = Haptics.generatorsMade
        #expect(warmedLight - startLight <= 1)
        for _ in 0..<15 {
            Haptics.prepare(.light)
            Haptics.play(.light)
        }
        #expect(Haptics.generatorsMade == warmedLight)

        let startSelection = Haptics.generatorsMade
        Haptics.play(.selection)
        let warmedSelection = Haptics.generatorsMade
        #expect(warmedSelection - startSelection <= 1)
        for _ in 0..<15 {
            Haptics.prepare(.selection)
            Haptics.play(.selection)
        }
        #expect(Haptics.generatorsMade == warmedSelection)

        let startNotify = Haptics.generatorsMade
        Haptics.play(.success)
        Haptics.play(.warning)
        let warmedNotify = Haptics.generatorsMade
        #expect(warmedNotify - startNotify <= 1)
        for _ in 0..<15 {
            Haptics.prepare(.error)
            Haptics.play(.success)
            Haptics.play(.warning)
        }
        #expect(Haptics.generatorsMade == warmedNotify)

        // External write to UserDefaults.standard invalidates cached isOn immediately.
        UserDefaults.standard.set(false, forKey: Haptics.key)
        #expect(Haptics.isOn == false)
        UserDefaults.standard.set(true, forKey: Haptics.key)
        #expect(Haptics.isOn == true)
    }

    @MainActor @Test func composerSubmitPlaysLightHapticOnlyWhenSending() {
        let before = UserDefaults.standard.object(forKey: Haptics.key)
        let oldSink = Haptics.sink
        var played: [Haptics.Kind] = []
        defer {
            Haptics.sink = oldSink
            if let before {
                UserDefaults.standard.set(before, forKey: Haptics.key)
            } else {
                UserDefaults.standard.removeObject(forKey: Haptics.key)
            }
        }
        Haptics.isOn = true
        Haptics.sink = { played.append($0) }

        let composer = ComposerView(frame: CGRect(x: 0, y: 0, width: 390, height: 60))
        var sent: [String] = []
        composer.onSend = { sent.append($0) }

        composer.textView.text = "   "
        composer.submit()
        #expect(played.isEmpty && sent.isEmpty)

        composer.textView.text = "Ship it"
        composer.submit()
        #expect(played == [.light])
        #expect(sent == ["Ship it"])
    }

    // MARK: - 2. Notification extension expiration

    @Test func notificationOpenerPreservesOpenedContentOnExpiry() {
        let sealed = UNMutableNotificationContent()
        sealed.title = "Hermes HQ"
        sealed.body = "New notification"
        sealed.categoryIdentifier = NotificationHub.approvalCategory
        sealed.userInfo = ["seal": ["v": 1]]

        let decrypted = UNMutableNotificationContent()
        decrypted.title = "Scout"
        decrypted.body = "Wants to run tests"
        decrypted.categoryIdentifier = NotificationHub.approvalCategory

        var recorded: [String] = []
        let kept = NotificationOpener.expired(sealed, opened: decrypted) { recorded.append($0) }
        #expect(kept === decrypted)
        #expect(kept.title == "Scout")
        #expect(kept.categoryIdentifier == NotificationHub.approvalCategory)
        #expect(recorded == ["expired.opened"])

        var expiredRecorded: [String] = []
        let fallback = NotificationOpener.expired(sealed, opened: nil) { expiredRecorded.append($0) }
        #expect(fallback.categoryIdentifier.isEmpty)
        #expect(expiredRecorded == ["expired"])
    }

    // MARK: - 3. Audio session held guard

    @MainActor @Test func audioSessionIsHeldTracksOwnerAndGuardsCueAudio() async throws {
        let coordinator = AudioSessionCoordinator.shared
        let playback = coordinator.onPlaybackPreempted
        let speech = coordinator.onSpeechPreempted
        let recording = coordinator.onRecordingPreempted
        let borrowed = coordinator.onConversationBorrowed
        let ending = coordinator.endConversation
        let simulated = coordinator.simulatedOwners
        coordinator.reset()
        coordinator.simulatedOwners = [.memoRecording, .memoPlayback, .conversation, .dictation, .speech, .diagnostics]
        defer {
            coordinator.reset()
            coordinator.onPlaybackPreempted = playback
            coordinator.onSpeechPreempted = speech
            coordinator.onRecordingPreempted = recording
            coordinator.onConversationBorrowed = borrowed
            coordinator.endConversation = ending
            coordinator.simulatedOwners = simulated
        }

        #expect(AudioSessionCoordinator.isHeld == false)
        try await coordinator.acquire(.memoRecording)
        #expect(AudioSessionCoordinator.isHeld == true)

        // Dispatching onto AudioWork.queue while held returns cleanly without stomping AVAudioSession.
        let heldOnAudioQueue = await AudioWork.perform {
            let held = AudioSessionCoordinator.isHeld
            CueAudio.play(Data())
            ArrivalSoundPlayers.play(.wake)
            return held
        }
        #expect(heldOnAudioQueue == true)
        #expect(AudioSessionCoordinator.isHeld == true)

        coordinator.release(.memoRecording)
        #expect(AudioSessionCoordinator.isHeld == false)
    }

    // MARK: - 4. TasksStore 409 offline retry & forget() race

    @MainActor @Test func tasksStorePreserves409ConflictResolutionAcrossOfflineRetry() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "feel-trust-tasks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let base = Self.makeTask("t_1", "Original", notes: "", rev: 3)
        let client = PagesFakeClient { _ in
            .object(["rev": 1, "tasks": .array([Self.wire(base)])])
        }
        let store = TasksStore(api: TasksAPI(client: client), account: client.account, directory: dir)
        await store.refresh()
        #expect(store.task("t_1")?.rev == 3)

        // Queue a note edit offline.
        client.respond { _ in throw URLError(.notConnectedToInternet) }
        #expect(await store.patch("t_1", ["notes": .string("Keep this note")]))
        #expect(store.pendingCount == 1)

        // On flush: first PATCH returns 409 with title updated elsewhere (no field conflict with notes);
        // the immediate conflict-resolved retry fails offline. The resolved edit must remain queued.
        let latest = Self.makeTask("t_1", "Renamed elsewhere", notes: "", rev: 4)
        let conflictBody = try String(decoding: Self.wire(latest).encoded(), as: UTF8.self)
        let patchAttempt = Mutex(0)
        client.respond { request in
            guard request.method == "PATCH" else {
                return .object(["rev": 4, "tasks": .array([Self.wire(latest)])])
            }
            let n = patchAttempt.withLock { $0 += 1; return $0 }
            if n == 1 {
                throw HTTPError(status: 409, body: conflictBody)
            }
            throw URLError(.notConnectedToInternet)
        }
        await store.flushPending()
        #expect(store.pendingCount == 1)
        #expect(store.task("t_1")?.title == "Renamed elsewhere")
        #expect(store.task("t_1")?.rev == 4)

        // Next online flush sends the preserved note edit on rev 4 and succeeds.
        let mergedServer = Self.makeTask("t_1", "Renamed elsewhere", notes: "Keep this note", rev: 5)
        let retryRevSeen = Mutex<Int?>(nil)
        let retryNoteSeen = Mutex<String?>(nil)
        client.respond { request in
            if request.method == "PATCH" {
                retryRevSeen.withLock { $0 = ActivityJSON.int(request.body?["rev"]) }
                retryNoteSeen.withLock { $0 = request.body?["notes"]?.string }
                return Self.wire(mergedServer)
            }
            return .object(["rev": 5, "tasks": .array([Self.wire(mergedServer)])])
        }
        await store.flushPending()
        #expect(store.pendingCount == 0)
        #expect(retryRevSeen.withLock { $0 } == 4)
        #expect(retryNoteSeen.withLock { $0 } == "Keep this note")
        #expect(store.task("t_1")?.notes == "Keep this note")
        #expect(store.task("t_1")?.title == "Renamed elsewhere")
    }

    @MainActor @Test func tasksStoreForgetMidFlightPreventsLateCompletionStateResurrection() async throws {
        let base = Self.makeTask("t_1", "Original", notes: "", rev: 3)
        let (enteredStream, enteredCont) = AsyncStream<Void>.makeStream()
        let (releaseStream, releaseCont) = AsyncStream<Void>.makeStream()

        let client = PagesFakeClient { request in
            if request.method == "PATCH" {
                enteredCont.yield()
                for await _ in releaseStream { break }
                return Self.wire(Self.makeTask("t_1", "Updated too late", notes: "", rev: 4))
            }
            return .object(["rev": 1, "tasks": .array([Self.wire(base)])])
        }
        let store = TasksStore(api: TasksAPI(client: client), account: client.account, directory: nil)
        await store.refresh()
        #expect(store.hasList == true)

        let patchTask = Task { await store.patch("t_1", ["title": .string("Updated too late")]) }
        for await _ in enteredStream { break }

        store.forget()
        releaseCont.yield()
        releaseCont.finish()

        let applied = await patchTask.value
        #expect(applied == false)
        #expect(store.tasks.isEmpty)
        #expect(store.hasList == false)
        #expect(store.pendingCount == 0)
    }

    // MARK: - 5. AppModel sign-out race decision

    @Test func appModelSignOutDecisionProtectsSwitchedAccount() {
        let accountA = GatewayAccount(
            id: "https://example.invalid|alpha",
            baseURL: URL(string: "https://example.invalid")!,
            kind: .password,
            username: "alpha",
            label: "Example A"
        )
        let accountB = GatewayAccount(
            id: "https://other.example.invalid|beta",
            baseURL: URL(string: "https://other.example.invalid")!,
            kind: .password,
            username: "beta",
            label: "Example B"
        )

        #expect(AppModel.signOutDecision(asked: accountA, current: nil) == .fullSignOut(account: accountA))
        #expect(AppModel.signOutDecision(asked: accountA, current: accountA) == .fullSignOut(account: accountA))
        #expect(AppModel.signOutDecision(asked: accountA, current: accountB) == .purgeOnly(previousAccount: accountA))
    }

    // MARK: - 6. BoundedLRU eviction

    @Test func boundedLRUPromotesActiveEntriesAndEvictsOnlyOldest() {
        var small = BoundedLRU<String, Int>(limit: 3)
        small.set(1, for: "a")
        small.set(2, for: "b")
        small.set(3, for: "c")
        // Promote "a" so "b" becomes the least recently used entry.
        #expect(small.value(for: "a") == 1)
        small.set(4, for: "d")

        #expect(small.count == 3)
        #expect(small.peek("b") == nil)
        #expect(small.peek("a") == 1)
        #expect(small.peek("c") == 3)
        #expect(small.peek("d") == 4)

        var full = BoundedLRU<String, Int>(limit: 256)
        for i in 0..<260 {
            full.set(i, for: "k\(i)")
        }
        #expect(full.count == 256)
        #expect(full.peek("k0") == nil)
        #expect(full.peek("k3") == nil)
        #expect(full.peek("k4") == 4)
        #expect(full.peek("k259") == 259)
    }

    // MARK: - 7. Gateway event filters

    @Test func serverRequestEventFilterGatesDeltasPerSessionAndDropsUnrelatedEvents() {
        let filter = ServerRequestCenter.makeEventFilter()

        #expect(filter(GatewayEvent(type: "memory.updated", sessionId: "s1", seq: nil, payload: .null)) == false)
        #expect(filter(GatewayEvent(type: "thinking.delta", sessionId: "s1", seq: nil, payload: .null)) == false)
        #expect(filter(GatewayEvent(type: LocalEvent.serverRequest, sessionId: "s1", seq: nil, payload: .null)) == true)

        // First message.delta passes for s1; repeated deltas do not; s2 passes independently.
        #expect(filter(GatewayEvent(type: "message.delta", sessionId: "s1", seq: 1, payload: .null)) == true)
        #expect(filter(GatewayEvent(type: "message.delta", sessionId: "s1", seq: 2, payload: .null)) == false)
        #expect(filter(GatewayEvent(type: "message.delta", sessionId: "s2", seq: 1, payload: .null)) == true)

        // Completion re-arms s1 without resetting s2.
        #expect(filter(GatewayEvent(type: "message.complete", sessionId: "s1", seq: 3, payload: .null)) == true)
        #expect(filter(GatewayEvent(type: "message.delta", sessionId: "s1", seq: 4, payload: .null)) == true)
        #expect(filter(GatewayEvent(type: "message.delta", sessionId: "s2", seq: 2, payload: .null)) == false)

        // gateway.ready clears delta tracking across all sessions.
        #expect(filter(GatewayEvent(type: "gateway.ready", sessionId: "", seq: nil, payload: .null)) == true)
        #expect(filter(GatewayEvent(type: "message.delta", sessionId: "s2", seq: 3, payload: .null)) == true)
    }

    @Test func appModelEventFilterTracksPhaseEdgesAndResetsOnCompletionOrTools() {
        let filter = AppModel.makeGatewayEventFilter()

        // First thinking.delta enters thinking phase; subsequent thinking.delta is dropped.
        #expect(filter(GatewayEvent(type: "thinking.delta", sessionId: "s1", seq: 1, payload: .null)) == true)
        #expect(filter(GatewayEvent(type: "reasoning.delta", sessionId: "s1", seq: 2, payload: .null)) == false)

        // Transition to replying with blank text passes once, then drops further blank deltas.
        #expect(filter(GatewayEvent(type: "message.delta", sessionId: "s1", seq: 3, payload: .object(["text": .string("   ")]))) == true)
        #expect(filter(GatewayEvent(type: "message.delta", sessionId: "s1", seq: 4, payload: .object(["text": .string("\n")]))) == false)

        // Transition to non-blank message.delta passes once, then drops subsequent token deltas.
        #expect(filter(GatewayEvent(type: "message.delta", sessionId: "s1", seq: 5, payload: .object(["text": .string("Hello")]))) == true)
        #expect(filter(GatewayEvent(type: "message.delta", sessionId: "s1", seq: 6, payload: .object(["text": .string(" world")]))) == false)

        // Tool start resets phase so a subsequent thinking/message edge is forwarded.
        #expect(filter(GatewayEvent(type: "tool.start", sessionId: "s1", seq: 7, payload: .null)) == true)
        #expect(filter(GatewayEvent(type: "message.delta", sessionId: "s1", seq: 8, payload: .object(["text": .string("After tool")]))) == true)

        // Completion clears phase for next turn; gateway.ready clears all sessions without forwarding.
        #expect(filter(GatewayEvent(type: "message.complete", sessionId: "s1", seq: 9, payload: .null)) == true)
        #expect(filter(GatewayEvent(type: "thinking.delta", sessionId: "s1", seq: 10, payload: .null)) == true)
        #expect(filter(GatewayEvent(type: "gateway.ready", sessionId: "", seq: nil, payload: .null)) == false)
        #expect(filter(GatewayEvent(type: "thinking.delta", sessionId: "s1", seq: 11, payload: .null)) == true)
    }

    // MARK: - 8. SessionStore duplicate key tolerance

    @Test func sessionStoreToleratesDuplicateSessionProfileRowsAcrossRefreshes() async throws {
        let client = BotsFakeGatewayClient()
        let firstSidebar: JSONValue = [
            "recents": ["sessions": .array([Self.sessionRow("dup", title: "First"), Self.sessionRow("dup", title: "Second")])],
            "cron": ["sessions": .array([])],
            "messaging": ["sessions": .array([])],
        ]
        let secondSidebar: JSONValue = [
            "recents": ["sessions": .array([Self.sessionRow("dup", title: "Updated"), Self.sessionRow("other", title: "Other")])],
            "cron": ["sessions": .array([])],
            "messaging": ["sessions": .array([])],
        ]
        let responses = Mutex([try firstSidebar.encoded(), try secondSidebar.encoded()])
        client.onREST { method, _, _, _ in
            guard method == "GET" else { return Data("{}".utf8) }
            return responses.withLock { list in
                if list.count > 1 { return list.removeFirst() }
                return list[0]
            }
        }

        let store = SessionStore(client: client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(),
                                 timing: .fast, autoStart: false)
        store.start()
        defer { store.stop() }
        #expect(await BotsTest.waitUntil { store.loadState == .ready })

        // Second refresh exercises `earlier` and `diff` with duplicate `(id, profile)` rows in `prior`.
        await store.refresh()
        #expect(store.loadState == .ready)
        #expect(store.sessions.contains(where: { $0.id == "dup" }))
    }
}
