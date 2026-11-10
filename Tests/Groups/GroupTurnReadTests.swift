// [groups] A member's turn reads its hidden session light (no transcript) while it works and in full once it is done
// (docs/spec/3x-groups.md §6.6–§6.7), and a turn-complete signal that lands between two waits is not lost.

import Foundation
import Testing
@testable import HermesHQNative

/// One member's hidden session: busy until `finish`, which adds the reply. `dropBusy`: light reads leave out the
/// busy fields (a gateway that strips them with `omit_messages`).
nonisolated final class GroupTurnFakeSession: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var rows: [JSONValue] = []
    var dropBusy = false
    /// Emit `message.complete` from inside the submit (the signal lands before the turn waits).
    var signalOnSubmit = false

    init(busy: Bool = false) { running = busy }

    func finish(_ reply: String) {
        lock.withLock {
            running = false
            rows.append(["role": "assistant", "content": .string(reply)])
        }
    }

    func install(on client: BotsFakeGatewayClient) {
        client.on("session.resume") { [self] params in
            let light = params["omit_messages"]?.bool == true
            return lock.withLock {
                var out: [String: JSONValue] = ["session_id": "run-ivy", "session_key": "st-ivy"]
                if !(light && dropBusy) { out["running"] = .bool(running) }
                out["messages"] = light ? .array([]) : .array(rows)
                return .object(out)
            }
        }
        client.on("prompt.submit") { [self] params in
            lock.withLock {
                running = true
                rows.append(["role": "user", "content": .string(params["text"]?.string ?? "")])
            }
            if signalOnSubmit {
                finish("done early")
                client.emit(GatewayEvent(type: "message.complete", sessionId: "run-ivy", seq: nil, payload: .null))
            }
            return ["status": "accepted"]
        }
    }
}

@Suite(.serialized) @MainActor struct GroupTurnReadTests {
    private func timing(poll: TimeInterval = 0.03) -> GroupTiming {
        var t = GroupTiming()
        t.base = 5
        t.hardCap = 10
        t.poll = poll
        t.settle = 0.01
        return t
    }

    private func run(_ client: BotsFakeGatewayClient, signals: GroupSignals, timing: GroupTiming) async throws -> String? {
        let turn = GroupTurn(client: client, signals: signals, timing: timing)
        return try await turn.run(room: GroupRoom(name: "R"), thread: "t1", seat: GroupsTest.seat("ivy"), prompt: "hello",
                                  isCurrent: { true }, save: { _ in }, onRuntime: { _, _ in }, onAccepted: { _, _ in }, onWaiting: { _ in })
    }

    /// The reads after the submit: true = light (`omit_messages`).
    private func readsAfterSubmit(_ client: BotsFakeGatewayClient) -> [Bool] {
        guard let submitted = client.calls("prompt.submit").first?.at else { return [] }
        return client.calls("session.resume").filter { $0.at > submitted }.map { $0.params["omit_messages"]?.bool == true }
    }

    @Test func aBusyMemberIsReadLightUntilItIsDoneThenOnceInFull() async throws {
        let client = BotsFakeGatewayClient()
        let session = GroupTurnFakeSession()
        session.install(on: client)
        let signals = GroupSignals()
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            session.finish("the answer")
        }
        let reply = try await run(client, signals: signals, timing: timing())
        #expect(reply == "the answer")
        let reads = readsAfterSubmit(client)
        #expect(reads.count >= 3)
        #expect(reads.dropLast().allSatisfy { $0 }, "every read while it works is light")
        #expect(reads.last == false, "one full read once it is done")
        #expect(reads.filter { !$0 }.count == 1)
    }

    @Test func aGatewayThatDropsTheBusyFieldsStillFindsTheReply() async throws {
        let client = BotsFakeGatewayClient()
        let session = GroupTurnFakeSession()
        session.dropBusy = true
        session.install(on: client)
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            session.finish("found it")
        }
        let reply = try await run(client, signals: GroupSignals(), timing: timing())
        #expect(reply == "found it")
        #expect(readsAfterSubmit(client).contains(false))
    }

    @Test func aSignalBeforeTheFirstWaitIsNotLost() async throws {
        let client = BotsFakeGatewayClient()
        let session = GroupTurnFakeSession()
        session.signalOnSubmit = true
        session.install(on: client)
        let signals = GroupSignals()
        signals.start(client)
        defer { signals.stop() }
        try? await Task.sleep(for: .milliseconds(50))      // the event subscription is up
        let started = ContinuousClock.now
        let reply = try await run(client, signals: signals, timing: timing(poll: 3))
        #expect(reply == "done early")
        #expect(ContinuousClock.now - started < .seconds(2), "no full poll's wait")
    }

    @Test func harvestReadsLightWhileBusyAndInFullOnceDone() async throws {
        let client = BotsFakeGatewayClient()
        let session = GroupTurnFakeSession(busy: true)
        session.install(on: client)
        let turn = GroupTurn(client: client, signals: GroupSignals(), timing: timing())
        let marker = GroupStranded(before: 0, thread: "t1", at: 0, stored: "st-ivy")
        #expect(await turn.harvest(marker, profile: "ivy") == .busy)
        #expect(client.calls("session.resume").allSatisfy { $0.params["omit_messages"]?.bool == true })
        session.finish("late reply")
        #expect(await turn.harvest(marker, profile: "ivy") == .reply("late reply"))
        #expect(client.calls("session.resume").filter { $0.params["omit_messages"]?.bool != true }.count == 1)
    }

    @Test func signalsLatchByRuntimeAndSince() async {
        let signals = GroupSignals()
        let earlier = Date().addingTimeInterval(-1)
        signals.fire("run-a")
        #expect(await signals.wait(runtime: "run-a", seconds: 2, since: earlier), "fired after since: at once")
        #expect(!(await signals.wait(runtime: "run-a", seconds: 0.05, since: Date())), "a fire before since is stale")
        #expect(!(await signals.wait(runtime: "run-b", seconds: 0.05, since: earlier)), "another runtime's fire never counts")
        for i in 0..<(GroupSignals.firedLimit + 10) { signals.fire("r\(i)") }
        #expect(signals.fired.count == GroupSignals.firedLimit)
        let waiting = Task { await signals.wait(runtime: "run-c", seconds: 5, since: Date()) }
        try? await Task.sleep(for: .milliseconds(50))
        signals.stop()
        #expect(await waiting.value == false)
        #expect(signals.fired.isEmpty)
    }
}
