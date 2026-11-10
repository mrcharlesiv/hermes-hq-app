import Foundation
import Testing
@testable import HermesHQNative

/// Session edits behind Hermes 0.22.3's revision fence (SessionWrite.swift): the snapshot read, the identity sent, a
/// conflict read again, a lost answer replayed with the same request id, and gateways older than the fence.
@Suite struct SessionWriteTests {
    /// A gateway with the fence: `revision` per chat, bumped by every accepted write; refuses an unfenced or stale one.
    nonisolated final class Fenced: @unchecked Sendable {
        let client = BotsFakeGatewayClient()
        let lock = NSLock()
        var revision = 7
        var applied: [String] = []        // request ids, in order
        var dropNextAnswer = false        // the write commits, the answer is lost
        var bumpBeforeNextWrite = false   // another client writes between our read and our write
        var exists = true

        init() {
            client.onREST { [unowned self] method, path, query, body in
                try self.lock.withLock {
                    if method == "GET", path.hasSuffix("/mutation-snapshot") {
                        return try (["session_id": "x", "exists": .bool(self.exists), "runtime_revision": .number(Double(self.revision)),
                                     "runtime_generation": self.exists ? 2 : .null] as JSONValue).encoded()
                    }
                    let identity: JSONValue = method == "DELETE"
                        ? .object(Dictionary(uniqueKeysWithValues: query.compactMap { item in
                            item.value.map { (item.name, item.name == "request_id" ? JSONValue.string($0) : .number(Double($0) ?? -1)) } }))
                        : (try body.map(JSONValue.parse) ?? .null)
                    guard let rid = identity["request_id"]?.string else {
                        throw HTTPError(status: 409, body: #"{"detail":"client_upgrade_required: this app is out of sync"}"#)
                    }
                    if self.applied.contains(rid) { return try (["ok": true, "replayed": true] as JSONValue).encoded() }
                    if self.bumpBeforeNextWrite { self.bumpBeforeNextWrite = false; self.revision += 1 }
                    guard identity["expected_revision"]?.int == self.revision, identity["expected_generation"]?.int == 2 else {
                        throw HTTPError(status: 409, body: #"{"detail":"revision_conflict"}"#)
                    }
                    self.applied.append(rid)
                    self.revision += 1
                    if self.dropNextAnswer { self.dropNextAnswer = false; throw URLError(.networkConnectionLost) }
                    return try (["ok": true, "title": "Done"] as JSONValue).encoded()
                }
            }
        }
        func writes(_ method: String) -> [BotsFakeGatewayClient.RESTCall] { client.restCalls.filter { $0.method == method } }
    }

    @Test func patchSendsTheSnapshotIdentityInTheBody() async throws {
        let gateway = Fenced()
        let data = try await SessionWrite.patch(gateway.client, id: "fence-a", profile: "ivy", ["title": "New"])
        #expect(try JSONValue.parse(data)["title"]?.string == "Done")
        let read = try #require(gateway.client.restCalls.first)
        #expect(read.method == "GET" && read.path == "/api/sessions/fence-a/mutation-snapshot")
        #expect(read.query == [URLQueryItem(name: "profile", value: "ivy")])
        let patch = try #require(gateway.writes("PATCH").first)
        let body = try JSONValue.parse(try #require(patch.body))
        #expect(body["title"]?.string == "New" && body["profile"]?.string == "ivy")
        #expect(body["expected_revision"]?.int == 7 && body["expected_generation"]?.int == 2)
        #expect(UUID(uuidString: body["request_id"]?.string ?? "") != nil)
        #expect(patch.query == [URLQueryItem(name: "profile", value: "ivy")])
        #expect(gateway.applied.count == 1)
    }

    @Test func deleteSendsTheIdentityInTheQuery() async throws {
        let gateway = Fenced()
        try await SessionWrite.delete(gateway.client, id: "fence-b", profile: "ivy")
        let delete = try #require(gateway.writes("DELETE").first)
        let names = delete.query.map(\.name)
        #expect(names == ["profile", "request_id", "expected_revision", "expected_generation"])
        #expect(delete.query.first { $0.name == "expected_revision" }?.value == "7")
        #expect(delete.body == nil && gateway.applied.count == 1)
    }

    @Test func aChatAlreadyGoneIsDeleted() async throws {
        let gateway = Fenced()
        gateway.exists = false
        let data = try await SessionWrite.delete(gateway.client, id: "fence-c", profile: nil)
        #expect(try JSONValue.parse(data)["already_absent"]?.bool == true)
        #expect(gateway.writes("DELETE").isEmpty)
        await #expect(throws: HTTPError.self) { try await SessionWrite.patch(gateway.client, id: "fence-c", profile: nil, ["pinned": true]) }
    }

    @Test func aConflictReadsAgainAndSendsOnce() async throws {
        let gateway = Fenced()
        gateway.bumpBeforeNextWrite = true
        try await SessionWrite.patch(gateway.client, id: "fence-d", profile: nil, ["pinned": true])
        let patches = gateway.writes("PATCH")
        #expect(patches.count == 2 && gateway.applied.count == 1)
        #expect(try JSONValue.parse(try #require(patches.last?.body))["expected_revision"]?.int == 8)
        #expect(gateway.client.restCalls.filter { $0.method == "GET" }.count == 2)
    }

    @Test func aLostAnswerIsReplayedWithTheSameRequestId() async throws {
        let gateway = Fenced()
        gateway.dropNextAnswer = true
        await #expect(throws: URLError.self) { try await SessionWrite.patch(gateway.client, id: "fence-e", profile: nil, ["archived": true]) }
        // Try Again: the same edit replays the kept identity (the gateway answers its receipt; nothing applies twice).
        let data = try await SessionWrite.patch(gateway.client, id: "fence-e", profile: nil, ["archived": true])
        #expect(try JSONValue.parse(data)["replayed"]?.bool == true)
        let ids = try gateway.writes("PATCH").map { try JSONValue.parse(try #require($0.body))["request_id"]?.string }
        #expect(ids.count == 2 && ids[0] == ids[1])
        #expect(gateway.applied.count == 1)
        #expect(gateway.client.restCalls.filter { $0.method == "GET" }.count == 1, "no second read")
        // Acknowledged: the next edit reads again.
        try await SessionWrite.patch(gateway.client, id: "fence-e", profile: nil, ["archived": false])
        #expect(gateway.client.restCalls.filter { $0.method == "GET" }.count == 2)
    }

    @Test func anOlderGatewayGetsThePlainWrite() async throws {
        for answer in [HTTPError(status: 404, body: #"{"detail":"Not Found"}"#), nil] {
            let client = BotsFakeGatewayClient()
            client.onREST { method, path, _, _ in
                if path.hasSuffix("/mutation-snapshot") {
                    if let answer { throw answer }
                    return Data("<!doctype html><title>Hermes</title>".utf8)      // a web fallback page, not the snapshot
                }
                return try (["ok": true] as JSONValue).encoded()
            }
            try await SessionWrite.patch(client, id: "old-a", profile: "ivy", ["unread": true])
            try await SessionWrite.delete(client, id: "old-a", profile: "ivy")
            let patch = try #require(client.restCalls.first { $0.method == "PATCH" })
            let body = try JSONValue.parse(try #require(patch.body))
            #expect(body == ["unread": true, "profile": "ivy"])
            #expect(client.restCalls.first { $0.method == "DELETE" }?.query == [URLQueryItem(name: "profile", value: "ivy")])
        }
    }

    @Test func aRefusalIsNotRetried() async throws {
        let client = BotsFakeGatewayClient()
        client.onREST { method, path, _, _ in
            if path.hasSuffix("/mutation-snapshot") {
                return try (["exists": true, "runtime_revision": 3, "runtime_generation": 1] as JSONValue).encoded()
            }
            throw HTTPError(status: 409, body: #"{"detail":"unknown_execution"}"#)
        }
        await #expect(throws: HTTPError.self) { try await SessionWrite.delete(client, id: "lost-a", profile: nil) }
        await #expect(throws: HTTPError.self) { try await SessionWrite.delete(client, id: "lost-a", profile: nil) }
        #expect(client.restCalls.filter { $0.method == "DELETE" }.count == 2)
        #expect(client.restCalls.filter { $0.method == "GET" }.count == 2, "a refused write keeps no identity")
        #expect(client.calls.isEmpty, "only a busy chat is stopped")
    }

    // MARK: - A chat still working (tester report 2026-11-07: "Couldn't delete chat (session_busy)")

    /// A gateway that refuses the delete `busyAnswers` times with `409 session_busy`, then deletes.
    nonisolated static func busy(_ busyAnswers: Int) -> BotsFakeGatewayClient {
        let client = BotsFakeGatewayClient()
        let refusals = Locked(busyAnswers)
        client.onREST { method, path, _, _ in
            if path.hasSuffix("/mutation-snapshot") {
                return try (["exists": true, "runtime_revision": 3, "runtime_generation": 1] as JSONValue).encoded()
            }
            let busy = refusals.value > 0
            refusals.mutate { $0 -= 1 }
            if busy { throw HTTPError(status: 409, body: #"{"detail":"session_busy"}"#) }
            return try (["ok": true] as JSONValue).encoded()
        }
        client.on("session.resume") { params in
            ["session_id": params["session_id"] ?? .null, "running": true, "execution_generation": 1,
             "pending": [["admission_id": "queued-1", "status": "queued"]]]
        }
        client.on("prompt.cancel") { _ in ["status": "terminal"] }
        client.on("session.interrupt") { _ in ["execution_state": "idle"] }
        return client
    }

    @Test func aBusyChatIsStoppedThenDeleted() async throws {
        let client = Self.busy(2)
        _ = try await SessionWrite.delete(client, id: "busy-a", profile: "ivy", busyWaits: [.milliseconds(1), .milliseconds(1), .milliseconds(1)])
        #expect(client.restCalls.filter { $0.method == "DELETE" }.count == 3, "sent again until the stop landed")
        #expect(client.calls.map(\.method) == ["session.resume", "prompt.cancel", "session.interrupt",
                                               "session.resume", "prompt.cancel", "session.interrupt"])
        let resume = try #require(client.calls("session.resume").first)
        #expect(resume.params["session_id"]?.string == "busy-a" && resume.params["profile"]?.string == "ivy")
        #expect(resume.params["omit_messages"]?.bool == true, "no transcript is read to stop it")
        #expect(client.calls("prompt.cancel").first?.params["admission_id"]?.string == "queued-1", "the waiting message goes too")
        #expect(client.calls("session.interrupt").first?.params["session_id"]?.string == "busy-a")
    }

    @Test func aChatThatStaysBusySaysSoInPlainWords() async throws {
        let client = Self.busy(.max)
        let error = await #expect(throws: HTTPError.self) {
            try await SessionWrite.delete(client, id: "busy-b", profile: nil, busyWaits: [.milliseconds(1)])
        }
        let refusal = try #require(error)
        #expect(client.restCalls.filter { $0.method == "DELETE" }.count == 2)
        #expect(SessionWrite.isBusy(refusal))
        #expect(MenusError.text(refusal) == SessionWrite.busyWords)
        #expect(SessionActionText.reason(refusal) == SessionWrite.busyWords)
        #expect(SessionWrite.isBusy(RPCError(code: 4001, message: "session_busy", data: ["reason": "session_busy"])))
        #expect(!SessionWrite.isBusy(HTTPError(status: 409, body: #"{"detail":"revision_conflict"}"#)))
    }

    // MARK: - A gateway that owns the profile (a dashboard started on its own, before 0.22.3's owner forward)

    nonisolated static let refusal = HTTPError(status: 409, body: #"{"detail":"Exclusive maintenance refused: Gateway runtime already owns profile /root/.hermes/profiles/ivy. Drain and stop the gateway, then retry."}"#)

    nonisolated static func owned() -> BotsFakeGatewayClient {
        let client = BotsFakeGatewayClient()
        client.onREST { method, _, _, _ in
            if method == "GET" { throw HTTPError(status: 404, body: nil) }
            throw refusal
        }
        return client
    }

    @Test func archiveGoesOverTheSocketWhenTheGatewayOwnsTheProfile() async throws {
        let client = Self.owned()
        client.on("session.archive") { _ in ["archived": true, "session_key": "x"] }
        _ = try await SessionWrite.patch(client, id: "owned-a", profile: "ivy", ["archived": true])
        let call = try #require(client.calls("session.archive").first)
        #expect(call.params["session_id"]?.string == "owned-a" && call.params["profile"]?.string == "ivy")
        #expect(call.params["archived"]?.bool == true)
    }

    @Test func hideGoesOverTheSocketWhenTheGatewayOwnsTheProfile() async throws {
        let client = Self.owned()
        client.on("session.set_hidden") { _ in ["hidden": true] }
        _ = try await SessionWrite.patch(client, id: "owned-h", profile: nil, ["hidden": true])
        let call = try #require(client.calls("session.set_hidden").first)
        #expect(call.params["hidden"]?.bool == true && call.params["profile"] == nil)
    }

    @Test func deleteGoesOverTheSocketAndAMissingChatCountsAsDeleted() async throws {
        let client = Self.owned()
        client.on("session.delete") { _ in ["deleted": "owned-d"] }
        _ = try await SessionWrite.delete(client, id: "owned-d", profile: "ivy")
        #expect(client.calls("session.delete").first?.params["session_id"]?.string == "owned-d")

        let gone = Self.owned()
        gone.on("session.delete") { _ in throw RPCError(code: 4007, message: "session not found", data: nil) }
        let data = try await SessionWrite.delete(gone, id: "owned-e", profile: "ivy")
        #expect(try JSONValue.parse(data)["already_absent"]?.bool == true)
    }

    @Test func renameResumesTheChatAndSetsTheTitleOverTheSocket() async throws {
        let client = Self.owned()
        client.on("session.resume") { _ in ["session_id": "rt-1"] }
        client.on("session.title") { params in ["title": params["title"] ?? .null, "pending": false] }
        let data = try await SessionWrite.patch(client, id: "owned-t", profile: "ivy", ["title": "New"])
        #expect(try JSONValue.parse(data)["title"]?.string == "New")
        let resume = try #require(client.calls("session.resume").first)
        #expect(resume.params["session_id"]?.string == "owned-t" && resume.params["profile"]?.string == "ivy")
        #expect(client.calls("session.title").first?.params["session_id"]?.string == "rt-1")
    }

    @Test func pinUnreadAndAClearedTitleKeepTheRefusal() async throws {
        let client = Self.owned()
        await #expect(throws: HTTPError.self) { try await SessionWrite.patch(client, id: "owned-p", profile: "ivy", ["pinned": true]) }
        await #expect(throws: HTTPError.self) { try await SessionWrite.patch(client, id: "owned-u", profile: "ivy", ["unread": false]) }
        await #expect(throws: HTTPError.self) { try await SessionWrite.patch(client, id: "owned-t", profile: "ivy", ["title": ""]) }
        #expect(client.calls.isEmpty)
    }

    @Test func aGatewayWithoutTheSocketCallKeepsTheRefusal() async throws {
        let client = Self.owned()  // no session.archive handler: -32601
        do {
            _ = try await SessionWrite.patch(client, id: "owned-o", profile: "ivy", ["archived": true])
            Issue.record("expected the refusal")
        } catch let error as HTTPError {
            #expect(SessionWrite.isMaintenanceRefusal(error))
        }
    }
}
