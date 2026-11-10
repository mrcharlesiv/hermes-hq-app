// Settings stream unit tests (docs/spec/1x-settings.md §13): U2 write outcomes and rollback, U3 the write fence, U9 the
// params each call sends (exactly the contract's keys), plus the per-bot queue and the gateway-switcher check.

import Foundation
import Testing
@testable import HermesHQNative

/// A scripted gateway that keeps each profile's `ui_meta` and revisions, with Hermes' compare-and-swap.
nonisolated final class MetaGateway: @unchecked Sendable {
    let client = BotsFakeGatewayClient()
    private let lock = NSLock()
    var meta: [String: [String: JSONValue]] = [:]
    var revisions: [String: [String: Int]] = [:]
    var descriptions: [String: String] = [:]
    /// Next answers of profiles.configure (consumed in order before the real handling).
    var scripted: [@Sendable () throws -> JSONValue] = []

    init(_ rows: [String: [String: JSONValue]]) {
        meta = rows.mapValues { ["hermes-bots": .object($0)] }
        revisions = rows.mapValues { _ in ["hermes-bots": 1] }
        client.on("profiles.list") { [unowned self] params in self.list(slim: params["include_sessions"]?.bool == false) }
        client.on("profiles.configure") { [unowned self] params in try self.configure(params) }
        client.on("profiles.set_asset") { _ in ["ok": true, "asset": "avatar", "size": 10] }
        client.on("profiles.get_asset") { _ in ["found": false] }
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }

    func list(slim: Bool) -> JSONValue {
        withLock {
            let rows: [JSONValue] = meta.keys.sorted().map { name in
                var o: [String: JSONValue] = ["name": .string(name), "is_default": .bool(name == "default"),
                                              "ui_meta_revisions": .object((revisions[name] ?? [:]).mapValues { .number(Double($0)) })]
                if let m = meta[name], !m.isEmpty { o["ui_meta"] = .object(m) }
                if let d = descriptions[name] { o["description"] = .string(d) }
                if !slim {
                    o["canonical_session"] = BotsTest.session("s-\(name)", lastActive: 100)
                }
                return .object(o)
            }
            return BotsTest.profilesResult(rows)
        }
    }

    func configure(_ params: JSONValue) throws -> JSONValue {
        if let next = withLock({ scripted.isEmpty ? nil : scripted.removeFirst() }) { return try next() }
        return withLock {
            let name = params["name"]?.string ?? ""
            var applied: [String: JSONValue] = [:]
            if let incoming = params["ui_meta"]?.object {
                var revs = revisions[name] ?? [:]
                if let expected = params["ui_meta_expected_revisions"]?.object {
                    var conflicts: [String: JSONValue] = [:]
                    for key in incoming.keys where expected[key]?.int != (revs[key] ?? 0) {
                        conflicts[key] = ["expected": expected[key] ?? .null, "actual": .number(Double(revs[key] ?? 0))]
                    }
                    if !conflicts.isEmpty {
                        return ["ok": false, "applied": ["ui_meta": false, "ui_meta_conflicts": .object(conflicts)]]
                    }
                }
                var current = meta[name] ?? [:]
                for (key, value) in incoming {
                    if value.isNull { current[key] = nil } else { current[key] = value }
                    revs[key, default: 0] += 1
                }
                meta[name] = current
                revisions[name] = revs
                applied["ui_meta"] = true
                applied["ui_meta_revisions"] = .object(incoming.keys.reduce(into: [:]) { $0[$1] = .number(Double(revs[$1]!)) })
            }
            if let description = params["description"]?.string {
                descriptions[name] = description
                applied["description"] = true
            }
            return ["ok": true, "applied": .object(applied)]
        }
    }
}

@MainActor
private func makeStore(_ gateway: MetaGateway) async -> BotStore {
    let store = BotStore(client: gateway.client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: .fast)
    await BotsTest.waitUntil { store.phase == .full }
    return store
}

@MainActor @Suite(.serialized) struct BotWriteTests {
    // MARK: U2 outcomes

    @Test func outcomeMapping() {
        #expect(BotWriteOutcome.meta(["ok": true, "applied": ["ui_meta": true, "ui_meta_revisions": ["hermes-bots": 4]]]) == .persisted(revision: 4))
        #expect(BotWriteOutcome.meta(["ok": false, "applied": ["ui_meta": false]]) == .failed(BotWriteError.notSavedReason))
        #expect(BotWriteOutcome.meta(["ok": true]) == .failed(BotWriteError.unsupportedReason))
        #expect(BotWriteOutcome.meta(["ok": true, "applied": ["description": true]]) == .failed(BotWriteError.notSavedReason))
        #expect(BotWriteOutcome.reason(RPCError(code: -32601, message: "method not found: profiles.configure", data: nil)) == BotWriteError.unsupportedReason)
        #expect(BotWriteOutcome.reason(RPCError(code: 4000, message: "invalid params for profiles.configure: x", data: nil)) == BotWriteError.unsupportedReason)
        #expect(BotWriteOutcome.reason(RPCError(code: 5064, message: "disk full", data: nil)) == "disk full")
        let timeout = RPCError(code: -33001, message: "Your gateway didn’t answer in time.", data: ["reason": "timeout"])
        if timeout.isTimeout { #expect(BotWriteOutcome.reason(timeout) == NoticeWriteWords.noAnswer) }
        // Audit 10-2: the client's own transport line is never the alert's reason.
        #expect(BotWriteOutcome.reason(RPCError.timedOut("profiles.configure", after: .seconds(30))) == NoticeWriteWords.noAnswer)
        #expect(BotWriteOutcome.reason(RPCError.connectionLost("profiles.configure")) == NoticeWriteWords.dropped)
        #expect(BotWriteOutcome.reason(RPCError(code: -32603, message: "Internal error", data: nil)) == GatewayFailure.gatewayError(nil).message)
    }

    @Test func pinWritesTheWholeMergedObjectAndPersists() async throws {
        let gateway = MetaGateway(["ivy": ["sectionId": "sec-work", "sectionName": "Work", "created": 1790000000001]])
        let store = await makeStore(gateway)
        try await store.setPinned(name: "ivy", display: "Ivy", true)
        let configure = gateway.client.calls("profiles.configure")
        #expect(configure.count == 1)
        #expect(configure[0].params == ["name": "ivy", "ui_meta": ["hermes-bots": [
            "sectionId": "hermes-hq-pinned", "sectionName": "Pinned", "created": 1790000000001, "pinned": true,
            "pinnedFrom": ["id": "sec-work", "name": "Work"]]]])
        // A slim read went first (the fresh read, §2.2 step 3).
        let order = gateway.client.calls.map(\.method).filter { $0 == "profiles.list" || $0 == "profiles.configure" }
        #expect(order.suffix(2) == ["profiles.list", "profiles.configure"])
        #expect(gateway.client.calls("profiles.list").last?.params == ["include_sessions": false])
        #expect(store.bot(named: "ivy")?.pinned == true)
        #expect(gateway.withLock { gateway.revisions["ivy"]?["hermes-bots"] } == 2)
    }

    @Test func refusedWriteRollsBackAndSendsTheUndo() async throws {
        let gateway = MetaGateway(["ivy": ["sectionId": "sec-work", "sectionName": "Work"]])
        let store = await makeStore(gateway)
        gateway.withLock { gateway.scripted = [{ ["ok": false, "applied": ["ui_meta": false]] }] }
        await #expect(throws: BotWriteError.self) { try await store.setPinned(name: "ivy", display: "Ivy", true) }
        #expect(store.bot(named: "ivy")?.pinned == false)
        #expect(store.currentMeta("ivy")["sectionId"] == "sec-work")
        // The best-effort undo write follows (whole object, old values back).
        #expect(await BotsTest.waitUntil { gateway.client.calls("profiles.configure").count == 2 })
        let undo = gateway.client.calls("profiles.configure")[1].params["ui_meta"]?["hermes-bots"]
        #expect(undo?["pinned"] == .null && undo?["sectionId"] == "sec-work" && undo?["pinnedFrom"] == false)
    }

    @Test func unsupportedAndErrorsFail() async throws {
        let gateway = MetaGateway(["ivy": [:]])
        let store = await makeStore(gateway)
        gateway.withLock { gateway.scripted = [{ ["ok": true] }] }
        do { try await store.setHidden(name: "ivy", display: "Ivy", true); Issue.record("should fail") } catch let error as BotWriteError {
            #expect(error.title == "Couldn’t Hide Ivy" && error.reason == BotWriteError.unsupportedReason)
        }
        gateway.withLock { gateway.scripted = [{ throw RPCError(code: 5064, message: "disk full", data: nil) }] }
        do { try await store.setHidden(name: "ivy", display: "Ivy", true); Issue.record("should fail") } catch let error as BotWriteError {
            #expect(error.reason == "disk full")
        }
        #expect(store.bot(named: "ivy")?.hidden == false)
    }

    @Test func readOnlyRefusesBeforeAnythingIsSent() async throws {
        let gateway = MetaGateway(["ivy": [:]])
        let store = await makeStore(gateway)
        store.readOnlyGateway = true
        let before = gateway.client.calls.count
        await #expect(throws: BotWriteError.self) { try await store.setPinned(name: "ivy", display: "Ivy", true) }
        await #expect(throws: HeadSaveError.self) { _ = try await store.saveHead(name: "ivy", record: nil, revision: 0) }
        #expect(gateway.client.calls.count == before)
    }

    /// The fresh read merges another device's change (S5): the write keeps it.
    @Test func freshReadKeepsAnotherDevicesChange() async throws {
        let gateway = MetaGateway(["ivy": ["sectionId": "sec-work", "sectionName": "Work"]])
        let store = await makeStore(gateway)
        gateway.withLock { gateway.meta["ivy"]?["hermes-bots"] = ["sectionId": "sec-work", "sectionName": "Work", "title": "Desk"] }
        try await store.setPinned(name: "ivy", display: "Ivy", true)
        #expect(gateway.client.calls("profiles.configure").last?.params["ui_meta"]?["hermes-bots"]?["title"] == "Desk")
    }

    /// Same-bot writes run one after the other; the second carries the first's change (S6).
    @Test func sameBotWritesAreSequential() async throws {
        let gateway = MetaGateway(["ivy": [:], "notes": [:]])
        let store = await makeStore(gateway)
        async let pin: Void = store.setPinned(name: "ivy", display: "Ivy", true)
        async let hide: Void = store.setHidden(name: "ivy", display: "Ivy", true)
        _ = try await (pin, hide)
        let writes = gateway.client.calls("profiles.configure").map { $0.params["ui_meta"]?["hermes-bots"] }
        #expect(writes.count == 2)
        #expect(writes[1]?["pinned"] == true && writes[1]?["hidden"] == true)
    }

    /// A write that timed out may still have landed; its undo goes out before a write queued meanwhile reads the gateway,
    /// so that later write isn't overwritten by the undo (pin times out, hide queued during it: hidden stays).
    @Test func aFailedWritesUndoGoesBeforeTheNextWriteToThatBot() async throws {
        let gateway = MetaGateway(["ivy": ["sectionId": "sec-work", "sectionName": "Work"]])
        let store = await makeStore(gateway)
        let first = OnceFlag()
        gateway.client.on("profiles.configure") { [unowned gateway] params in
            let answer = try gateway.configure(params)           // it lands on the gateway…
            if first.take() {
                try await Task.sleep(for: .milliseconds(120))
                throw RPCError(code: RPCError.timeoutCode, message: "Your gateway didn’t answer in time.", data: nil)   // …the answer doesn't
            }
            return answer
        }
        let pin = Task { try await store.setPinned(name: "ivy", display: "Ivy", true) }
        #expect(await BotsTest.waitUntil { gateway.client.calls("profiles.configure").count == 1 })
        let hide = Task { try await store.setHidden(name: "ivy", display: "Ivy", true) }
        let pinned = await pin.result
        if case .success = pinned { Issue.record("the pin should fail") }
        try await hide.value
        let wire = gateway.client.calls("profiles.configure").map { $0.params["ui_meta"]?["hermes-bots"] }
        #expect(wire.count == 3)
        #expect(wire[1]?["pinned"] != true && wire[1]?["sectionId"] == "sec-work")          // the undo, second
        #expect(wire[2]?["hidden"] == true && wire[2]?["pinned"] != true)                   // the hide reads after it
        let final = gateway.withLock { gateway.meta["ivy"]?["hermes-bots"] }
        #expect(final?["hidden"] == true)
        #expect(final?["pinned"] != true && final?["sectionId"] == "sec-work")
        #expect(store.bot(named: "ivy")?.hidden == true && store.bot(named: "ivy")?.pinned == false)
        #expect(store.editing.inFlight.isEmpty)
    }

    // MARK: U3 fence

    /// A full roster sent before a write and applied after it (on the owner's gateway a full read takes 18–107 s) keeps
    /// the write: the fence is decided by order, not by a clock. A read sent after the write lifts it.
    @Test func aRosterSentBeforeAWriteDoesNotUndoItHoweverLateItLands() async throws {
        let gateway = MetaGateway(["ivy": ["sectionId": "sec-work", "sectionName": "Work"]])
        let store = await makeStore(gateway)
        let gate = TestGate()
        let block = OnceFlag()
        gateway.client.on("profiles.list") { [unowned gateway] params in
            let slim = params["include_sessions"]?.bool == false
            let answer = gateway.list(slim: slim)              // what the gateway held when the read was sent
            if !slim, block.take() { await gate.wait() }
            return answer
        }
        let fullsBefore = gateway.client.calls("profiles.list").filter { $0.params["include_sessions"]?.bool != false }.count
        let stale = Task { await store.refresh() }
        #expect(await BotsTest.waitUntil {
            gateway.client.calls("profiles.list").filter { $0.params["include_sessions"]?.bool != false }.count == fullsBefore + 1
        })
        try await store.setPinned(name: "ivy", display: "Ivy", true)
        _ = try await store.saveEdit(name: "ivy", title: nil, description: "Finds flights")
        #expect(store.fencedProfiles().contains("ivy"))
        gate.release()                                         // the pre-write snapshot lands now
        await stale.value
        #expect(store.bot(named: "ivy")?.pinned == true)
        #expect(store.currentMeta("ivy")["pinned"] == true && store.currentMeta("ivy")["pinnedFrom"]?["id"] == "sec-work")
        #expect(store.rowDescription("ivy") == "Finds flights")
        #expect(store.fencedProfiles().contains("ivy"))
        // A read sent after the write carries it: the stamp and the shown description go, the gateway's values show.
        await store.refresh()
        #expect(!store.fencedProfiles().contains("ivy"))
        #expect(store.editing.metaWriteAt["ivy"] == nil && store.editing.descriptions["ivy"] == nil)
        #expect(store.bot(named: "ivy")?.pinned == true)
        #expect(store.rowDescription("ivy") == "Finds flights")
    }

    /// A write still out keeps its bot fenced even from a read sent after its local patch.
    @Test func aWriteInFlightIsFencedFromAnyRead() async throws {
        let gateway = MetaGateway(["ivy": [:]])
        let store = await makeStore(gateway)
        let gate = TestGate()
        let block = OnceFlag()
        gateway.client.on("profiles.configure") { [unowned gateway] params in
            if block.take() { await gate.wait() }
            return try gateway.configure(params)
        }
        let pin = Task { try await store.setPinned(name: "ivy", display: "Ivy", true) }
        #expect(await BotsTest.waitUntil { gateway.client.calls("profiles.configure").count == 1 })
        await store.refresh()                                  // sent after the patch, answered before the write landed
        #expect(store.bot(named: "ivy")?.pinned == true)
        gate.release()
        try await pin.value
        #expect(store.bot(named: "ivy")?.pinned == true)
        #expect(store.editing.inFlight.isEmpty)
    }

    // MARK: Sections

    @Test func renameReStampsEveryMemberAndDeleteUnfilesThemWithUndo() async throws {
        let gateway = MetaGateway(["ivy": ["sectionId": "sec-work", "sectionName": "Work"],
                                   "research": ["sectionId": "sec-work", "sectionName": "Work"], "notes": [:]])
        let store = await makeStore(gateway)
        #expect(store.sectionRecords.map(\.name) == ["Work"])
        try await store.renameSection("sec-work", to: "Office") { $0 }
        let renames = gateway.client.calls("profiles.configure").map { ($0.params["name"]?.string, $0.params["ui_meta"]?["hermes-bots"]?["sectionName"]) }
        #expect(renames.map(\.0) == ["research", "ivy"] || renames.map(\.0) == ["ivy", "research"])
        #expect(renames.allSatisfy { $0.1 == "Office" })
        // Delete: the record goes at once (the Undo can show now), the writes follow.
        let deletion = try #require(try store.beginDeleteSection("sec-work"))
        #expect(store.sectionRecords.isEmpty)
        #expect(Set(deletion.members) == ["ivy", "research"])
        try await store.finishDeleteSection(deletion) { $0 }
        #expect(gateway.withLock { gateway.meta["ivy"]?["hermes-bots"]?["sectionId"] } == .null)
        #expect(!store.editing.pendingSectionDeletes.contains("sec-work"))
        store.undoDeleteSection(deletion) { $0 }
        #expect(store.sectionRecords.map(\.name) == ["Office"])
        #expect(await BotsTest.waitUntil { gateway.withLock { gateway.meta["research"]?["hermes-bots"]?["sectionId"] } == "sec-work" })
        #expect(await BotsTest.waitUntil { gateway.withLock { gateway.meta["ivy"]?["hermes-bots"]?["sectionId"] } == "sec-work" })
        let record = store.appendSection(named: "  Clients  ")
        #expect(record.name == "Clients" && record.id.hasPrefix("sec-"))
        #expect(store.sectionRecords.map(\.name) == ["Office", "Clients"])
        store.moveSection(record.id, by: -1)
        #expect(store.sectionRecords.map(\.name) == ["Clients", "Office"])
    }

    /// Delete Section counts hidden members too, and an Undo tapped while the writes run stops them and files back
    /// only the bots already moved.
    @Test func deleteCountsHiddenMembersAndAnEarlyUndoStopsTheWrites() async throws {
        let gateway = MetaGateway(["ivy": ["sectionId": "sec-work", "sectionName": "Work"],
                                   "deploys": ["sectionId": "sec-work", "sectionName": "Work", "hidden": true]])
        let store = await makeStore(gateway)
        #expect(Set(store.members(ofSection: "sec-work")) == ["ivy", "deploys"])
        let gate = TestGate()
        let block = OnceFlag()
        gateway.client.on("profiles.configure") { [unowned gateway] params in
            let answer = try gateway.configure(params)
            if block.take() { await gate.wait() }
            return answer
        }
        let deletion = try #require(try store.beginDeleteSection("sec-work"))
        let writes = Task { try await store.finishDeleteSection(deletion) { $0 } }
        #expect(await BotsTest.waitUntil { gateway.client.calls("profiles.configure").count == 1 })
        store.undoDeleteSection(deletion) { $0 }               // the first member's write is still out
        #expect(store.sectionRecords.map(\.id) == ["sec-work"])
        gate.release()
        try await writes.value
        #expect(await BotsTest.waitUntil {
            gateway.withLock { ["ivy", "deploys"].allSatisfy { gateway.meta[$0]?["hermes-bots"]?["sectionId"] == "sec-work" } }
        })
        // One unfile and its re-file: the second member was never moved.
        try await Task.sleep(for: .milliseconds(100))
        #expect(gateway.client.calls("profiles.configure").count == 2)
        #expect(!store.editing.pendingSectionDeletes.contains("sec-work"))
    }

    /// A member write that fails puts the record back where it was (the rest still filed there) and throws; Try Again
    /// deletes it again. A rename whose first write fails takes its old name back.
    @Test func partialFailuresPutTheSectionBack() async throws {
        let gateway = MetaGateway(["ivy": ["sectionId": "sec-work", "sectionName": "Work"],
                                   "research": ["sectionId": "sec-work", "sectionName": "Work"],
                                   "mail": ["sectionId": "sec-home", "sectionName": "Home"]])
        let store = await makeStore(gateway)
        #expect(store.sectionRecords.map(\.name) == ["Work", "Home"] || store.sectionRecords.map(\.name) == ["Home", "Work"])
        let order = store.sectionRecords.map(\.id)
        gateway.withLock { gateway.scripted = [{ ["ok": true, "applied": ["ui_meta": true, "ui_meta_revisions": ["hermes-bots": 2]]] },
                                                { throw RPCError(code: 5064, message: "disk full", data: nil) }] }
        let deletion = try #require(try store.beginDeleteSection("sec-work"))
        await #expect(throws: BotWriteError.self) { try await store.finishDeleteSection(deletion) { $0 } }
        #expect(store.sectionRecords.map(\.id) == order, "back at its index")
        #expect(!store.editing.pendingSectionDeletes.contains("sec-work"))
        #expect(store.members(ofSection: "sec-work").count == 1)
        // Try Again: the remaining member.
        let again = try #require(try store.beginDeleteSection("sec-work"))
        #expect(again.members.count == 1)
        try await store.finishDeleteSection(again) { $0 }
        #expect(!store.sectionRecords.contains { $0.id == "sec-work" })

        gateway.withLock { gateway.scripted = [{ throw RPCError(code: 5064, message: "disk full", data: nil) }] }
        await #expect(throws: BotWriteError.self) { try await store.renameSection("sec-home", to: "House") { $0 } }
        #expect(store.sectionName("sec-home") == "Home")
    }

    @Test func readOnlyRefusesSectionWritesBeforeAnythingChanges() async throws {
        let gateway = MetaGateway(["ivy": ["sectionId": "sec-work", "sectionName": "Work"]])
        let store = await makeStore(gateway)
        store.readOnlyGateway = true
        await #expect(throws: BotWriteError.self) { try await store.renameSection("sec-work", to: "Office") { $0 } }
        #expect(store.sectionName("sec-work") == "Work")
        #expect(throws: BotWriteError.self) { _ = try store.beginDeleteSection("sec-work") }
        #expect(store.sectionRecords.map(\.name) == ["Work"])
        #expect(gateway.client.calls("profiles.configure").isEmpty)
    }

    // MARK: Heads (§7.5)

    @Test func headSaveIsCompareAndSwapAndDrawsAtOnce() async throws {
        let gateway = MetaGateway(["ivy": [:]])
        let store = await makeStore(gateway)
        var record = HeadRecord.defaultMatrixRecord(profile: "ivy")
        record.form = "hex"; record.look = "ovals"
        let revision = try await store.saveHead(name: "ivy", record: record.stored, revision: 0)
        #expect(revision == 1)
        let call = gateway.client.calls("profiles.configure").last!
        #expect(call.params.object.map { Set($0.keys) } == ["name", "ui_meta", "ui_meta_expected_revisions"])
        #expect(call.params["ui_meta_expected_revisions"] == ["dispatch-head": 0])
        #expect(Head.resolve(store.bot(named: "ivy")?.head, profile: "ivy").silhouette == .hex)     // the overlay draws now
        // Another device saved meanwhile: a conflict, with its revision.
        gateway.withLock { gateway.revisions["ivy"]?["dispatch-head"] = 3 }
        await #expect(throws: HeadSaveError.conflict(actual: 3)) { _ = try await store.saveHead(name: "ivy", record: record.stored, revision: 1) }
        #expect(try await store.saveHead(name: "ivy", record: nil, revision: 3) == 4)
        #expect(store.headState(name: "ivy").saved == false)
    }

    /// `profiles.create` timed out after the gateway made the profile: New Bot carries on (meta, Bot Chat) instead of
    /// failing, and asked with a 90 s timeout.
    @Test func aCreateWhoseAnswerWasLostCarriesOn() async throws {
        let gateway = MetaGateway(["ivy": [:]])
        gateway.client.on("profiles.create") { [unowned gateway] params in
            gateway.withLock { gateway.meta[params["name"]?.string ?? ""] = [:] }
            throw RPCError(code: RPCError.timeoutCode, message: "request timed out after 90s: profiles.create", data: nil)
        }
        gateway.client.on("setup.runtime_check") { _ in ["ok": true] }
        gateway.client.on("session.list") { _ in ["sessions": []] }
        gateway.client.on("session.create") { _ in ["session_id": "abcd1234", "stored_session_id": "20261010_y"] }
        gateway.client.on("session.title") { _ in ["ok": true] }
        let store = await makeStore(gateway)
        let result = try await store.createBot(name: "Inbox Triage", title: "", description: "Sorts my email")
        #expect(result.bot.id == "inbox-triage")
        #expect(gateway.client.calls("profiles.create").last?.timeout == .seconds(90))
        #expect(gateway.client.calls("profiles.configure").contains { $0.params["name"] == "inbox-triage" })
        #expect(gateway.client.calls("session.create").count == 1)
        // Not made at all: the failure stands.
        gateway.client.on("profiles.create") { _ in throw RPCError(code: RPCError.timeoutCode, message: "timed out", data: nil) }
        await #expect(throws: BotWriteError.self) { _ = try await store.createBot(name: "Second", title: "", description: "") }
    }

    // MARK: U9 params

    @Test func everyCallSendsExactlyTheContractKeys() async throws {
        let gateway = MetaGateway(["ivy": [:]])
        gateway.client.on("profiles.create") { _ in ["ok": true, "name": "inbox-triage", "path": "/p", "soul_written": true, "model_set": false] }
        gateway.client.on("setup.runtime_check") { _ in ["ok": true] }
        gateway.client.on("session.list") { _ in ["sessions": []] }
        gateway.client.on("session.create") { _ in ["session_id": "abcd1234", "stored_session_id": "20261010_x"] }
        gateway.client.on("session.title") { _ in ["ok": true] }
        gateway.client.on("mcp.servers.list") { _ in ["servers": []] }
        gateway.client.on("reload.mcp") { _ in ["status": "reloaded"] }
        gateway.client.onREST { _, _, _, _ in Data("{}".utf8) }
        let store = await makeStore(gateway)
        _ = try await store.saveEdit(name: "ivy", title: "Ivy the Scout", description: "Finds flights")
        let edit = gateway.client.calls("profiles.configure").last!.params
        #expect(edit.object.map { Set($0.keys) } == ["name", "ui_meta", "description"])
        #expect(edit["description"] == "Finds flights" && edit["ui_meta"]?["hermes-bots"]?["title"] == "Ivy the Scout")

        let result = try await store.createBot(name: "Inbox Triage", title: "", description: "Sorts my email")
        #expect(result.bot.id == "inbox-triage" && !result.needsModel)
        let create = gateway.client.calls("profiles.create").last!.params
        #expect(create.object.map { Set($0.keys) } == ["name", "description", "clone_from", "no_skills", "share_auth", "soul"])
        #expect(create["clone_from"] == "default" && create["no_skills"] == false && create["share_auth"] == true)
        #expect(create["description"] == "Sorts my email")
        #expect(gateway.client.calls("setup.runtime_check").last?.params == ["profile": "inbox-triage"])
        #expect(gateway.client.calls("session.create").last?.params == ["profile": "inbox-triage", "title": "Bot Chat", "hidden": true, "follow_profile_config": true, "source": "desktop"])
        let meta = gateway.client.calls("profiles.configure").last { $0.params["name"] == "inbox-triage" }?.params["ui_meta"]?["hermes-bots"]
        #expect(meta?["shape"] == "blobatar" && meta?["imageKind"] == "shape" && meta?["title"] == "")

        await store.mirrorHead(name: "ivy", png: "data:image/png;base64,AAAA")
        #expect(gateway.client.calls("profiles.set_asset").last?.params == ["name": "ivy", "asset": "avatar", "data": "data:image/png;base64,AAAA"])
        await store.mirrorHead(name: "ivy", png: nil)
        #expect(gateway.client.calls("profiles.get_asset").last?.params == ["name": "ivy", "asset": "avatar"])

        let capabilities = CapabilitiesStore(client: gateway.client)
        _ = try await capabilities.mcpServers("ivy")
        #expect(gateway.client.calls("mcp.servers.list").last?.params == ["profile": "ivy"])
        try await capabilities.setMcp("files", enabled: true, profile: "ivy")
        #expect(gateway.client.calls("reload.mcp").last?.params == ["confirm": true])
        let put = gateway.client.restCalls.last { $0.method == "PUT" }
        #expect(put?.path == "/api/mcp/servers/files/enabled" && put?.query == [URLQueryItem(name: "profile", value: "ivy")])
        #expect(put.flatMap { try? JSONValue.parse($0.body ?? Data()) } == ["enabled": true])
    }
}

/// A one-shot flag the scripted handlers take (thread-safe).
nonisolated final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = true
    func take() -> Bool { lock.withLock { defer { armed = false }; return armed } }
}

/// Holds handlers until the test releases them.
nonisolated final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if open { return true }
                waiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }
    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            open = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in waiting { waiter.resume() }
    }
}

// MARK: - The news check against parked files

nonisolated final class FakeParkedReader: ParkedAccountReading, @unchecked Sendable {
    var answers: [String: AccountProbe.Answer]
    var reads: [String] = []
    var unreachable = false
    init(_ answers: [String: AccountProbe.Answer]) { self.answers = answers }
    func read(id: String, profile: String?) async throws -> AccountProbe.Answer {
        reads.append(id)
        if unreachable { throw URLError(.cannotConnectToHost) }
        return answers[id] ?? .missing
    }
    func finish() {}
}

@MainActor @Suite(.serialized) struct GatewaySwitcherTests {
    @Test func countsNewsFromTheParkedRosterAndKeepsTheLastWhenUnreachable() async throws {
        let vault = AccountVault(service: "hqn.tests.switcher.\(UUID().uuidString)", signedOutKey: "hqn.tests.switcher.signedOut")
        defer { vault.removeAll() }
        let store = AccountStore(vault: vault)
        let other = StoredAccount(url: "http://127.0.0.1:9739", username: "qa", cookies: [SavedCookie(name: "s", value: "1", domain: "127.0.0.1")])
        let current = StoredAccount(url: "http://127.0.0.1:9738", username: "qa", cookies: [SavedCookie(name: "s", value: "2", domain: "127.0.0.1")])
        try store.save(other)
        try store.save(current)
        let directory = BotsTest.tempDirectory()
        let parked = try #require(other.gatewayAccount)
        let roster = RosterCacheFile(at: 0, profiles: [
            ["name": "ivy", "canonical_session": ["id": "s-ivy", "last_active": 100, "message_count": 6]],
            ["name": "mail", "canonical_session": ["id": "s-mail", "last_active": 100, "message_count": 6]],
        ])
        var state = BotDeviceState()
        state.unread.baselines = ["ivy": 100, "mail": 100]
        try JSONEncoder().encode(roster).write(to: RosterDisk.url(directory, RosterDisk.rosterKind, parked))
        try JSONEncoder().encode(state).write(to: RosterDisk.url(directory, RosterDisk.botStateKind, parked))

        let model = GatewaySwitcherModel(store: store, directory: directory)
        model.currentId = { current.gatewayAccount?.id }
        let reader = FakeParkedReader(["s-ivy": .session(["id": "s-ivy", "last_active": 200, "message_count": 8]),
                                       "s-mail": .session(["id": "s-mail", "last_active": 100, "message_count": 6])])
        model.makeProbe = { _ in reader }
        await model.check()
        #expect(model.counts[parked.id] == 1)
        #expect(model.otherNews == 1)
        reader.unreachable = true
        await model.check()
        #expect(model.counts[parked.id] == 1)               // unreachable keeps the last count
        #expect(model.unreachable.contains(parked.id))      // …and the title menu says "Can’t Reach"
        reader.unreachable = false
        reader.answers["s-ivy"] = .refused
        await model.check()
        #expect(!model.unreachable.contains(parked.id))     // it answered
        #expect(model.counts[parked.id] == 0)               // refused: none, and "Signed Out" here…
        #expect(!model.hasUsableSession(parked))
        #expect(store.stored(parked)?.hasSession == true)   // …but the Keychain session stays (a 403 may pass)
        reader.answers["s-ivy"] = .session(["id": "s-ivy", "last_active": 200, "message_count": 8])
        await model.check()
        #expect(model.hasUsableSession(parked))             // a later good read clears the mark
        #expect(model.counts[parked.id] == 1)
    }

    /// Build 408: a saved gateway that was off timed out every 3 minutes. It is asked again after 6, 12, 24, then
    /// every 30 minutes; the title menu (a forced check) asks at once, and an answer ends the backoff.
    @Test func anUnreachableGatewayIsAskedLessOften() async throws {
        #expect(GatewaySwitcherModel.backoff(misses: 1) == 360)
        #expect(GatewaySwitcherModel.backoff(misses: 3) == 1440)
        #expect(GatewaySwitcherModel.backoff(misses: 9) == 1800)
        let vault = AccountVault(service: "hqn.tests.switcher.\(UUID().uuidString)", signedOutKey: "hqn.tests.switcher.signedOut")
        defer { vault.removeAll() }
        let store = AccountStore(vault: vault)
        let other = StoredAccount(url: "http://127.0.0.1:9741", username: "qa", cookies: [SavedCookie(name: "s", value: "1", domain: "127.0.0.1")])
        let current = StoredAccount(url: "http://127.0.0.1:9740", username: "qa", cookies: [SavedCookie(name: "s", value: "2", domain: "127.0.0.1")])
        try store.save(other)
        try store.save(current)
        let directory = BotsTest.tempDirectory()
        let parked = try #require(other.gatewayAccount)
        let roster = RosterCacheFile(at: 0, profiles: [["name": "ivy", "canonical_session": ["id": "s-ivy", "last_active": 100, "message_count": 6]]])
        try JSONEncoder().encode(roster).write(to: RosterDisk.url(directory, RosterDisk.rosterKind, parked))
        let model = GatewaySwitcherModel(store: store, directory: directory)
        model.currentId = { current.gatewayAccount?.id }
        var clock = Date(timeIntervalSince1970: 1_000_000)
        model.now = { clock }
        let reader = FakeParkedReader([:])
        reader.unreachable = true
        model.makeProbe = { _ in reader }
        await model.check(force: false)
        #expect(reader.reads.count == 1)
        clock += 180
        await model.check(force: false)
        #expect(reader.reads.count == 1)                    // waiting out the first 6 minutes
        #expect(model.unreachable.contains(parked.id))      // still "Can’t Reach"
        clock += 181
        await model.check(force: false)
        #expect(reader.reads.count == 2)                    // 6 minutes on: asked again, missed again (12 next)
        clock += 360
        await model.check(force: false)
        #expect(reader.reads.count == 2)
        await model.check()                                 // the title menu asks at once
        #expect(reader.reads.count == 3)
        reader.unreachable = false
        await model.check()
        #expect(!model.unreachable.contains(parked.id))
        await model.check(force: false)
        #expect(reader.reads.count == 5)                    // answered: back to every check
    }

    /// Each answer is keyed by the id asked for: the gateway may answer for a resolved id (prefix or lineage).
    @Test func newsKeysAnswersByTheRequestedId() {
        let live = ParkedChatLive(json: ["id": "20261010_resolved", "last_active": 300, "message_count": 4], id: "s-ivy")
        #expect(live?.id == "s-ivy")
        let chat = ParkedChat(owner: "ivy", id: "s-ivy", ids: ["s-ivy"], profile: "ivy", baseline: 100, marked: false)
        #expect(GatewayNews.unreadCount([chat], live: [live!]) == 1)
    }
}

@MainActor @Suite(.serialized) struct GatewayPurgeTests {
    /// S27: removing a gateway deletes this phone's four list files for it (and its transcripts).
    @Test func purgeDeletesTheFourListFiles() throws {
        let account = GatewayAccount(id: "http://127.0.0.1:65000|purge-\(UUID().uuidString)", baseURL: URL(string: "http://127.0.0.1:65000")!,
                                     kind: .password, username: "qa", label: "x")
        let directory = AppModel.listsCacheDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let kinds = [RosterDisk.rosterKind, RosterDisk.botStateKind, RosterDisk.sessionsKind, RosterDisk.sessionStateKind]
        for kind in kinds { try Data("{}".utf8).write(to: RosterDisk.url(directory, kind, account)) }
        SettingsHub.purge(account)
        RosterDiskWriter.shared.flush()
        for kind in kinds { #expect(!FileManager.default.fileExists(atPath: RosterDisk.url(directory, kind, account).path)) }
    }

    // [13-1] [13-12] [13-19] Removing a gateway also forgets what this phone synced of its lists, and its unsaved SOUL.md text.
    @Test func purgeForgetsTheListsSyncAndSoulDrafts() throws {
        let account = GatewayAccount(id: "http://127.0.0.1:65000|purge-\(UUID().uuidString)", baseURL: URL(string: "http://127.0.0.1:65000")!,
                                     kind: .password, username: "qa", label: "x")
        let drafts = SoulDraftStore.standard
        drafts.write(SoulDraft(text: "who I am", baseHash: SoulDraft.hash("")), account: account.id, profile: "inbox")
        drafts.write(SoulDraft(text: "kept", baseHash: SoulDraft.hash("")), account: "someone-else", profile: "inbox")
        defer { drafts.remove(account: "someone-else", profile: "inbox") }
        for name in ["bots", "sessions", "pins"] { UserDefaults.standard.set(Data("{}".utf8), forKey: "hq.gatewaySync.\(name)|\(account.id)") }
        defer { UserDefaults.standard.removeObject(forKey: "hq.gatewaySync.pins|\(account.id)") }
        UserDefaults.standard.set(Data("[]".utf8), forKey: "capabilities.serverIssues.\(account.id)")
        SettingsHub.purge(account)
        #expect(UserDefaults.standard.object(forKey: "capabilities.serverIssues.\(account.id)") == nil, "[13-19] its connector issues")
        #expect(drafts.read(account: account.id, profile: "inbox") == nil)
        #expect(drafts.read(account: "someone-else", profile: "inbox") != nil)
        #expect(UserDefaults.standard.object(forKey: "hq.gatewaySync.bots|\(account.id)") == nil)
        #expect(UserDefaults.standard.object(forKey: "hq.gatewaySync.sessions|\(account.id)") == nil)
        #expect(UserDefaults.standard.object(forKey: "hq.gatewaySync.pins|\(account.id)") != nil, "pins stay on the device, so their sync does too")
    }
}
