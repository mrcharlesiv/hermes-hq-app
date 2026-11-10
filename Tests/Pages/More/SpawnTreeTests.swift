// Spawn Tree (docs/spec/3x-morepages.md §16 acceptance 1): the lenient decoder, tree building from flat records
// (orphans attach to the root, cycles are broken, repeated ids dropped), grouping by bot then chat, the words, and the
// one param the call may send.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

private nonisolated func json(_ text: String) -> JSONValue { try! JSONValue.parse(Data(text.utf8)) }
private nonisolated func record(_ id: String, _ parent: String? = nil, at: Double? = nil, owner: String? = "s1", status: SpawnStatus = .running) -> SpawnRecord {
    SpawnRecord(id: id, parentId: parent, startedAt: at, status: status, ownerSession: owner)
}

struct SpawnTreeDecoderTests {
    @Test func decodesTheGatewaysAnswer() {
        let status = DelegationStatus(json: json("""
        {"active": [{"subagent_id": "sa-r2", "parent_id": "sa-r1", "depth": 2, "goal": "Read the networking changes", "delegation_id": "d-r2",
                     "model": "claude-opus-5", "started_at": 1791900000.25, "status": "running", "tool_count": 7,
                     "owner_agent_session_id": "s-release", "missed_steer": false}],
         "paused": true, "max_spawn_depth": 3, "max_concurrent_children": 3}
        """))
        #expect(status.paused && status.maxDepth == 3 && status.maxChildren == 3)
        #expect(status.active == [SpawnRecord(id: "sa-r2", parentId: "sa-r1", depth: 2, goal: "Read the networking changes", model: "claude-opus-5",
                                              startedAt: 1791900000.25, status: .running, toolCount: 7, ownerSession: "s-release")])
    }

    @Test func oddRecordsAreReadOrSkipped() {
        let status = DelegationStatus(json: json("""
        {"active": [{"subagent_id": "a"}, {"subagent_id": 9, "goal": null, "depth": "2", "tool_count": "4", "started_at": "1791900000", "status": 7,
                     "parent_id": "", "owner_agent_session_id": ""},
                    {"goal": "no id"}, {"subagent_id": ""}, "text", null, 4, [],
                    {"subagent_id": "b", "goal": "  ", "tool_count": -3, "started_at": -1, "status": "FAILED", "model": ""}]}
        """))
        #expect(status.active.map(\.id) == ["a", "9", "b"])
        #expect(status.active[0] == SpawnRecord(id: "a"))
        #expect(status.active[1].depth == 2 && status.active[1].toolCount == 4 && status.active[1].startedAt == 1_791_900_000)
        #expect(status.active[1].parentId == nil && status.active[1].ownerSession == nil && status.active[1].status == .running)
        #expect(status.active[2].goal == nil && status.active[2].toolCount == 0 && status.active[2].startedAt == nil && status.active[2].status == .failed)
        #expect(!status.paused && status.maxDepth == nil)
        for bad in ["{}", "[]", "null", #"{"active": {}, "paused": "yes"}"#] {
            #expect(DelegationStatus(json: json(bad)) == DelegationStatus())
        }
    }

    @Test func statusWords() {
        #expect(SpawnStatus(raw: nil) == .running && SpawnStatus(raw: "active") == .running)
        #expect(SpawnStatus(raw: "queued") == .queued && SpawnStatus(raw: "pending") == .queued)
        #expect(SpawnStatus(raw: "completed") == .done && SpawnStatus(raw: "Done") == .done)
        #expect(SpawnStatus(raw: "error") == .failed && SpawnStatus(raw: "interrupted") == .failed)
        #expect([SpawnStatus.running, .failed, .done, .queued].map(\.word) == ["Running", "Failed", "Done", "Queued"])
    }

    @Test func theCallSendsOnlyTheProfile() async throws {
        let client = MoreFakeClient { _ in json(#"{"active": [], "paused": false, "max_spawn_depth": 3, "max_concurrent_children": 3}"#) }
        let api = SpawnTreeAPI(client: client)
        _ = try await api.status(profile: nil)
        _ = try await api.status(profile: "default")
        _ = try await api.status(profile: "deploys")
        #expect(client.logLines == ["RPC delegation.status", "RPC delegation.status", "RPC delegation.status"])
        #expect(client.log.map(\.body) == [.object([:]), .object([:]), .object(["profile": "deploys"])],
                "Hermes refuses unknown params with error 4000")
    }
}

struct SpawnTreeBuilderTests {
    private func shape(_ records: [SpawnRecord]) -> [String] { SpawnTree.flatten(records).map { "\($0.level):\($0.record.id)" } }

    @Test func aTreeFromFlatRecords() {
        let rows = shape([record("c2", "c1", at: 30), record("b", nil, at: 20), record("a", nil, at: 10), record("c1", "a", at: 12),
                          record("a2", "a", at: 11), record("c3", "c2", at: 31)])
        #expect(rows == ["0:a", "1:a2", "1:c1", "2:c2", "3:c3", "0:b"], "parents first, children by start time")
    }

    @Test func orphansAttachToTheRoot() {
        #expect(shape([record("x", "gone", at: 5), record("y", "x", at: 6), record("z", nil, at: 1)]) == ["0:z", "0:x", "1:y"])
    }

    @Test func cyclesAreBroken() {
        // a ⇄ b, with c under b; d is its own parent; e → f → g → e.
        let rows = shape([record("a", "b", at: 2), record("b", "a", at: 1), record("c", "b", at: 3), record("d", "d", at: 0),
                          record("e", "g", at: 12), record("f", "e", at: 11), record("g", "f", at: 10)])
        #expect(rows == ["0:d", "0:b", "1:a", "1:c", "0:g", "1:e", "2:f"], "every record shows once; a cycle is entered at its earliest member")
        #expect(Set(rows).count == 7)
    }

    @Test func repeatedIdsAreDropped() {
        #expect(shape([record("a", at: 1), record("a", at: 2), record("b", "a"), record("b", "a")]) == ["0:a", "1:b"])
        #expect(shape([]) == [])
    }

    @Test func recordsWithNoStartTimeKeepTheirOrder() {
        #expect(shape([record("p"), record("k2", "p"), record("k1", "p"), record("k0", "p", at: 9)]) == ["0:p", "1:k0", "1:k2", "1:k1"])
    }

    @Test func aDeepChainIndentsFourLevelsAtMost() {
        let chain = (0..<400).map { record("n\($0)", $0 == 0 ? nil : "n\($0 - 1)", at: Double($0)) }
        let tree = SpawnTree.build(answers: [("default", DelegationStatus(active: chain))], sessions: [:])
        let rows = tree.bots[0].chats[0].rows
        #expect(rows.count == 400)
        #expect(rows.map(\.level).last == 399)
        #expect(rows.prefix(7).map(\.indent) == [0, 1, 2, 3, 4, 4, 4])
        #expect(rows.allSatisfy { $0.indent <= SpawnTree.maxIndent })
        #expect(tree.header == "400 subagents · 400 active")
    }

    @Test func groupsByBotThenByOwningChat() {
        let deploys = DelegationStatus(active: [record("r1", owner: "s-release", status: .running), record("p1", owner: "s-report", status: .queued),
                                                record("r2", "r1", owner: "s-release", status: .failed), record("n1", owner: nil)])
        let research = DelegationStatus(active: [record("a1", owner: "s-reading", status: .done), record("u1", owner: "s-unknown")], paused: true)
        let sessions = ["s-release": SpawnTree.Session(profile: "deploys", title: "Ship the 2.4 release notes"),
                        "s-report": SpawnTree.Session(profile: "deploys", title: "  "),
                        "s-reading": SpawnTree.Session(profile: "research", title: "Anything worth reading?")]
        let tree = SpawnTree.build(answers: [("default", DelegationStatus()), ("deploys", deploys), ("research", research)], sessions: sessions)
        #expect(tree.bots.map(\.id) == ["deploys", "research"], "a bot with nothing running has no group")
        #expect(tree.bots[0].chats.map(\.title) == ["Ship the 2.4 release notes", "Chat", "Chat"], "a chat the app does not know is “Chat”")
        #expect(tree.bots[0].chats.map(\.sessionId) == ["s-release", "s-report", nil])
        #expect(tree.bots[0].chats[0].rows.map(\.id) == ["deploys|r1", "deploys|r2"])
        #expect(tree.bots[0].chats[0].rows.map(\.level) == [0, 1])
        #expect(tree.bots[1].chats.map(\.title) == ["Anything worth reading?", "Chat"])
        #expect(tree.total == 6 && tree.active == 3)
        #expect(tree.header == "6 subagents · 3 active")
        #expect(tree.paused, "paused when any bot's answer says so")
        #expect(!tree.isEmpty)
    }

    @Test func aGatewayThatAnswersEveryBotWithTheWholeListShowsEachOnce() {
        let all = DelegationStatus(active: [record("r1", owner: "s-release"), record("a1", owner: "s-reading"), record("x1", owner: "s-unknown")])
        let sessions = ["s-release": SpawnTree.Session(profile: "deploys", title: "Release"), "s-reading": SpawnTree.Session(profile: "research", title: "Reading")]
        let tree = SpawnTree.build(answers: [("default", all), ("deploys", all), ("research", all)], sessions: sessions)
        #expect(tree.total == 3)
        #expect(tree.bots.map(\.id) == ["default", "deploys", "research"])
        #expect(tree.bots.map { $0.chats.flatMap { $0.rows.map(\.record.id) } } == [["x1"], ["r1"], ["a1"]],
                "under the bot that owns the chat when the app knows it, else under the first bot that listed it")
        // The owning bot is not among the bots asked (hidden from the roster): it still gets its group.
        let hidden = SpawnTree.build(answers: [("default", all)], sessions: sessions)
        #expect(hidden.bots.map(\.id) == ["default", "deploys", "research"])
        #expect(Set(hidden.bots.flatMap { $0.chats.flatMap { $0.rows.map(\.id) } }).count == 3, "row ids are unique: no list ever traps")
    }

    @Test func emptyAndSingular() {
        let empty = SpawnTree.build(answers: [("default", DelegationStatus())], sessions: [:])
        #expect(empty.isEmpty && empty.header == "0 subagents · 0 active" && !empty.paused)
        let one = SpawnTree.build(answers: [("default", DelegationStatus(active: [record("a", status: .queued)]))], sessions: [:])
        #expect(one.header == "1 subagent · 0 active")
        #expect(SpawnTree.build(answers: [], sessions: [:]).isEmpty)
    }
}

struct SpawnTreeWordsTests {
    @Test func durations() {
        #expect(SpawnTree.duration(0) == "0s")
        #expect(SpawnTree.duration(45.9) == "45s")
        #expect(SpawnTree.duration(60) == "1m 0s")
        #expect(SpawnTree.duration(130) == "2m 10s")
        #expect(SpawnTree.duration(3599) == "59m 59s")
        #expect(SpawnTree.duration(3900) == "1h 5m")
        #expect(SpawnTree.duration(93_600) == "1d 2h")
        #expect(SpawnTree.duration(-3) == nil, "a clock that disagrees says nothing")
        #expect(SpawnTree.duration(nil) == nil)
        #expect(SpawnTree.duration(.infinity) == nil && SpawnTree.duration(.nan) == nil)
    }

    @Test func theRowText() {
        let now = 1_791_900_130.0
        let running = SpawnRecord(id: "a", model: "hermes-4", startedAt: 1_791_900_000, status: .running, toolCount: 3)
        #expect(SpawnTree.detail(running, now: now) == "\(ModelNames.displayModelName("hermes-4")) · 3 tools · running 2m 10s")   // the name, not the slug
        #expect(SpawnTree.detail(SpawnRecord(id: "a", status: .running, toolCount: 1), now: now) == "1 tool · running")
        #expect(SpawnTree.detail(SpawnRecord(id: "a", model: "m", startedAt: now + 50, status: .running), now: now) == "\(ModelNames.displayModelName("m")) · running")
        #expect(SpawnTree.detail(SpawnRecord(id: "a", model: "m", startedAt: 5, status: .queued, toolCount: 0), now: now) == "\(ModelNames.displayModelName("m")) · 0 tools · queued")
        #expect(SpawnTree.detail(SpawnRecord(id: "a", status: .done), now: now) == "done")
        #expect(SpawnTree.detail(SpawnRecord(id: "a", status: .failed, toolCount: 12), now: now) == "12 tools · failed")
        let spoken = SpawnTree.spoken(SpawnTree.Row(id: "p|a", record: running, level: 1), now: now)
        #expect(spoken == "Subagent, Running, \(ModelNames.displayModelName("hermes-4")), 3 tools, for 2 minutes, 10 seconds, level 2")
    }
}

// MARK: - The model's reads

@MainActor private final class SpawnPages: PagesServices {
    let client: MoreFakeClient
    init(_ client: MoreFakeClient) { self.client = client }
    var account: GatewayAccount? { client.account }
    var gateway: (any GatewayClient)? { client }
    var bots: [Bot] { [] }
    var readOnlyGateway: Bool { false }
    func chat(for session: SessionSummary) -> ChatSessionModel { fatalError("not opened here") }
    var onSignOutPages: (() -> Void)?
}

@MainActor @Suite(.serialized) struct SpawnTreeModelTests {
    @Test func anEventDuringAReadQueuesExactlyOneMore() async {
        let client = MoreFakeClient { request in
            if request.path == "delegation.status" { try await Task.sleep(for: .milliseconds(150)) }
            return ["active": [], "paused": false]
        }
        let pages = SpawnPages(client)
        let context = MorePages.Context(services: FakeAppServices(), pages: pages, client: client, account: client.account,
                                        makeChat: { _ in UIViewController() })
        let model = SpawnTreeModel(context: context)
        let first = Task { await model.read() }
        for _ in 0..<100 where client.log.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(client.log.count == 1)
        // Two events while the first read is on its way: neither is lost, and they make one more read, not two.
        await model.read()
        await model.read()
        await first.value
        #expect(client.log.filter { $0.path == "delegation.status" }.count == 2, "\(client.logLines)")
        #expect(model.load == .ready)
        // Nothing queued: the next read is a fresh one.
        await model.read()
        #expect(client.log.filter { $0.path == "delegation.status" }.count == 3)
    }
}
