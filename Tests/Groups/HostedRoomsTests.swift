// [hosted] Group chats Hermes runs on its gateway (`groups.*`): Hermes Desktop 0.23 makes every new group chat this way,
// so a tester's own group chat never showed in the app (2026-11-14). The log's shapes, your own send matched to the
// gateway's copy, and the list / read / send / rename / disband against a scripted gateway.

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

/// A stand-in gateway with one room "Otto & Ivy" owned by `default`, seated otto and ivy.
nonisolated final class HostedFakeGateway: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [JSONValue] = []
    private var name = "Otto & Ivy"
    private var gone = false
    var working = false

    static let members: JSONValue = [
        ["member_id": "otto", "profile": "otto", "handle": "otto", "target": ["kind": "local", "profile": "otto"]],
        ["member_id": "ivy", "profile": "ivy", "handle": "ivy", "display_name": "Ivy", "target": ["kind": "local", "profile": "ivy"]],
    ]

    func add(_ kind: String, actor: JSONValue, payload: JSONValue, id: String? = nil) {
        lock.withLock {
            let seq = events.count + 1
            events.append(["seq": .number(Double(seq)), "event_id": .string(id ?? "e\(seq)"), "kind": .string(kind), "actor": actor,
                           "payload": payload, "created_at": .number(1_800_000_000 + Double(seq))])
        }
    }

    private var room: JSONValue {
        ["room_id": "room-1", "name": .string(name), "members": Self.members, "revision": 1,
         "latest_seq": .number(Double(events.count))]
    }

    func install(on client: BotsFakeGatewayClient) {
        client.on("groups.list") { [self] params in
            lock.withLock { params["profile"]?.string == "default" && !gone ? ["rooms": [room]] : ["rooms": []] }
        }
        client.on("groups.log") { [self] params in
            lock.withLock {
                let since = params["since_seq"]?.int ?? 0
                let page = Array(events.dropFirst(since))
                return ["events": .array(page), "cursor": .number(Double(events.count)), "latest_seq": .number(Double(events.count)),
                        "has_more": false, "authority": ["gateway_id": "install:x", "epoch": 1]]
            }
        }
        client.on("groups.state") { [self] _ in
            lock.withLock {
                ["room": room, "driver_status": ["working": .bool(working), "member_activity": working
                    ? [["member_id": "ivy", "status": "running", "thread_id": "t"]] : [], "pending_actions": []]]
            }
        }
        client.on("groups.send") { [self] params in
            let client = params["event_id"]?.string ?? ""
            let text = params["payload"]?["text"] ?? ""
            let thread = params["payload"]?["thread_id"] ?? ""
            add("message.user", actor: ["kind": "user", "id": "desktop"], payload: ["text": text, "thread_id": thread],
                id: HostedRoomLog.userEventId(client))
            add("message.member", actor: ["kind": "member", "id": "ivy", "profile": "ivy"], payload: ["text": "Hi from Ivy", "thread_id": thread])
            return ["accepted": true, "driver_started": true, "client_event_id": .string(client)]
        }
        client.on("groups.rename") { [self] params in
            lock.withLock { name = params["name"]?.string ?? name; return ["room": room] }
        }
        client.on("groups.disband") { [self] _ in lock.withLock { gone = true; return ["room_id": "room-1"] } }
        client.on("groups.stop") { _ in ["cancelled": 1] }
    }
}

@Suite(.serialized) @MainActor struct HostedRoomsTests {
    // MARK: The pure half

    @Test func yourSendsIdIsTheGatewaysOwn() {
        // H:gateway/hosted_rooms.py user_event_id("5f0c2a7e-1111-4222-8333-944455556666"), computed by Hermes v0.23.1.
        #expect(HostedRoomLog.userEventId("5f0c2a7e-1111-4222-8333-944455556666")
                == "user:5b145d05e5701560f4539c1bd36e5ecd034a444cc407fe320f87a4d58358bf29")
    }

    @Test func aListedRoomBecomesARecordWithItsRoster() throws {
        let raw: JSONValue = ["room_id": "room-1", "name": "Launch", "latest_seq": 7, "revision": 3, "members": [
            ["member_id": "otto", "profile": "otto", "handle": "otto", "target": ["kind": "local", "profile": "otto"]],
            ["member_id": "wren-laptop", "profile": "wren", "handle": "wren-laptop", "display_name": "Wren · Laptop",
             "target": ["kind": "peer", "peer_id": "p1", "installation_id": "inst-1", "profile": "wren", "capability_digest": "x"]],
        ]]
        let room = try #require(HostedRoomLog.room(raw, owner: "default"))
        #expect(room.key == "gw:default/room-1" && room.isHosted && room.name == "Launch")
        #expect(room.hosted == HostedRoomRef(owner: "default", roomId: "room-1", cursor: 0, latest: 7, revision: 3, epoch: nil))
        #expect(room.members.map(\.name) == ["otto", "wren"])
        #expect(room.members[1].sourceScoped && HostedRoomLog.memberId(room.members[1]) == "wren-laptop")
        #expect(HostedRoomLog.room(["room_id": "r", "name": "x", "disbanded_at": 5], owner: "default") == nil, "a disbanded room is not listed")
        // Never in the mirror.
        #expect(GroupSnapshot.local(rooms: [room.withLog()], tombstones: [:]).rooms.isEmpty)
    }

    @Test func theLogReadsAsMessagesAndActivity() {
        let members = HostedRoomLog.members(HostedFakeGateway.members)
        let events: [JSONValue] = [
            ["seq": 1, "event_id": "user:a", "kind": "message.user", "actor": ["kind": "user", "id": "desktop"],
             "payload": ["text": "Plan the trip", "thread_id": "t1"], "created_at": 1_800_000_000],
            ["seq": 2, "event_id": "dmessage:b", "kind": "message.member", "actor": ["kind": "member", "id": "ivy", "profile": "ivy"],
             "payload": ["text": "On it.", "thread_id": "t1", "member_id": "ivy"], "created_at": 1_800_000_001],
            ["seq": 3, "event_id": "x", "kind": "turn.settled", "actor": ["kind": "gateway"], "payload": ["member_id": "ivy", "thread_id": "t1"]],
            ["seq": 4, "event_id": "y", "kind": "turn.failed", "actor": ["kind": "gateway"], "payload": ["member_id": "otto", "error": "model_unavailable"]],
            ["seq": 5, "event_id": "z", "kind": "message.user", "actor": ["kind": "user", "id": "cron:job-1"], "payload": ["text": "Daily post", "thread_id": "t2"]],
            ["seq": 6, "event_id": "r", "kind": "room.renamed", "actor": ["kind": "system"], "payload": ["name": "Trip"]],
        ]
        let applied = HostedRoomLog.read(events, members: members)
        #expect(applied.entries.map(\.text) == ["Plan the trip", "On it.", "Daily post"])
        #expect(applied.entries[0].from == .you && applied.entries[0].at == 1_800_000_000_000 && applied.entries[0].thread == "t1")
        #expect(applied.entries[1].from == GroupAuthor(kind: .member, name: "ivy", source: nil, gateway: nil))
        #expect(applied.entries[2].from.source == "cron", "a scheduled post is not yours")
        #expect(applied.activity.map(\.kind) == [.replied, .failed])
        #expect(applied.activity[1].member == "otto" && applied.activity[1].detail == "model unavailable")
        #expect(applied.renamed == "Trip" && !applied.disbanded)
    }

    @Test func yourOwnSendIsNotAddedTwice() {
        let mine = GroupMessage(id: "client-1", at: 1, from: .you, text: "hi", thread: "client-1", truncated: nil)
        let copy = GroupMessage(id: HostedRoomLog.userEventId("client-1"), at: 2, from: .you, text: "hi", thread: "client-1", truncated: nil)
        let reply = GroupMessage(id: "dmessage:1", at: 3, from: GroupAuthor(kind: .member, name: "ivy", source: nil, gateway: nil),
                                 text: "hello", thread: "client-1", truncated: nil)
        let merged = HostedRoomLog.merge([mine], adding: [copy, reply, reply])
        #expect(merged.map(\.id) == ["client-1", "dmessage:1"], "the bubble keeps its id; the reply comes once")
    }

    // MARK: Against a scripted gateway

    private struct World {
        let client: BotsFakeGatewayClient
        let gateway: HostedFakeGateway
        let bots: BotStore
        let store: GroupStore
        let engine: GroupEngine
        let hosted: HostedRooms
    }

    private func world() async throws -> World {
        let directory = BotsTest.tempDirectory()
        let account = GatewayAccount(id: "http://127.0.0.1:9961|hosted-\(UUID().uuidString)", baseURL: URL(string: "http://127.0.0.1:9961")!,
                                     kind: .password, username: "t", label: "t")
        let client = BotsFakeGatewayClient(account: account)
        let roster = BotsTest.profilesResult(["default", "otto", "ivy"].map { BotsTest.row($0, display: $0 == "default" ? "Hermes" : $0.capitalized, meta: [:]) })
        client.on("profiles.list") { _ in roster }
        let gateway = HostedFakeGateway()
        gateway.install(on: client)
        let bots = BotStore(client: client, account: account, cacheDirectory: directory, timing: .fast)
        #expect(await BotsTest.waitUntil { bots.phase == .full })
        let store = GroupStore(account: account, directory: directory, bots: bots)
        let engine = GroupEngine(store: store, client: client)
        let hosted = HostedRooms(store: store, client: client)
        hosted.pollEvery = 0.05
        store.hostedRooms = hosted
        return World(client: client, gateway: gateway, bots: bots, store: store, engine: engine, hosted: hosted)
    }

    @Test func aRoomMadeInHermesDesktopIsListedAndRead() async throws {
        let w = try await world()
        w.gateway.add("message.user", actor: ["kind": "user", "id": "desktop"], payload: ["text": "From the desktop", "thread_id": "t0"])
        w.gateway.add("message.member", actor: ["kind": "member", "id": "otto", "profile": "otto"], payload: ["text": "Otto here", "thread_id": "t0"])
        w.hosted.refresh(force: true)
        #expect(await BotsTest.waitUntil { w.store.room("gw:default/room-1")?.log.count == 2 })
        let room = try #require(w.store.room("gw:default/room-1"))
        #expect(room.name == "Otto & Ivy" && room.hosted?.cursor == 2)
        #expect(w.store.seated(room).map(\.display) == ["Otto", "Ivy"] && w.store.seated(room).allSatisfy(\.canDrive))
        #expect(!w.store.isUnread(room.key), "the first read of a room is not news")
        #expect(w.store.rows().first { $0.id == room.key }?.line.contains("Otto here") == true)
        #expect(w.store.rooms(of: "ivy").map(\.key) == [room.key])
        // Listed by the owner only; the other bots' gateways are asked too.
        #expect(Set(w.client.calls("groups.list").compactMap { $0.params["profile"]?.string }) == ["default", "otto", "ivy"])
        #expect(w.client.calls("profiles.configure").isEmpty, "nothing is written to the bots for a gateway room")
    }

    @Test func aSendGoesToTheGatewayAndTheReplyArrivesOnce() async throws {
        let w = try await world()
        w.hosted.refresh(force: true)
        #expect(await BotsTest.waitUntil { w.store.room("gw:default/room-1") != nil })
        let key = "gw:default/room-1"
        w.hosted.roomShown(key, true)
        guard case .sent(let id) = w.engine.send("Hello both", room: key) else { Issue.record("not sent"); return }
        #expect(await BotsTest.waitUntil { w.store.room(key)?.log.contains { $0.text == "Hi from Ivy" } == true })
        let log = try #require(w.store.room(key)?.log)
        #expect(log.map(\.text) == ["Hello both", "Hi from Ivy"], "your bubble once, the reply once")
        #expect(log[0].id == id)
        let send = try #require(w.client.calls("groups.send").first)
        #expect(send.params["profile"] == "default" && send.params["room_id"] == "room-1" && send.params["event_id"]?.string == id)
        #expect(send.params["payload"] == ["text": "Hello both", "thread_id": .string(id)])
        #expect(w.client.calls("session.create").isEmpty && w.client.calls("prompt.submit").isEmpty, "the gateway runs the round")
        w.hosted.roomShown(key, false)
        w.hosted.shutdown()
    }

    @Test func aRefusedSendIsUndeliveredAndTryAgainUsesTheSameId() async throws {
        let w = try await world()
        w.hosted.refresh(force: true)
        #expect(await BotsTest.waitUntil { w.store.room("gw:default/room-1") != nil })
        let key = "gw:default/room-1"
        let refuse = Mutex(true)
        w.client.on("groups.send") { params in
            if refuse.withLock({ $0 }) { throw RPCError(code: 4001, message: "This host has too many active Group Chats.", data: ["admitted": false]) }
            return ["accepted": true, "client_event_id": params["event_id"] ?? ""]
        }
        guard case .sent(let id) = w.engine.send("Hello", room: key) else { Issue.record("not sent"); return }
        #expect(await BotsTest.waitUntil { w.store.room(key)?.undelivered[id] != nil })
        #expect(w.store.room(key)?.undelivered[id] == "This host has too many active Group Chats.")
        refuse.withLock { $0 = false }
        w.engine.retry(id, room: key)
        #expect(await BotsTest.waitUntil { w.client.calls("groups.send").count == 2 && w.store.room(key)?.undelivered.isEmpty == true })
        #expect(w.client.calls("groups.send").map { $0.params["event_id"]?.string } == [id, id])
        w.hosted.shutdown()
    }

    @Test func renameStopAndDeleteGoToTheGateway() async throws {
        let w = try await world()
        w.hosted.refresh(force: true)
        #expect(await BotsTest.waitUntil { w.store.room("gw:default/room-1") != nil })
        let key = "gw:default/room-1"
        try await w.store.rename(key, to: "Trip Planning")
        #expect(w.store.room(key)?.name == "Trip Planning")
        #expect(w.client.calls("groups.rename").first?.params["name"] == "Trip Planning")
        #expect(await w.engine.stop(key))
        #expect(w.client.calls("groups.stop").count == 1)
        await #expect(throws: BotWriteError.self) { try await w.store.setMembers(key, ["otto"]) }
        try await w.store.delete(key)
        #expect(w.store.room(key) == nil && w.client.calls("groups.disband").count == 1)
        #expect(w.client.calls("profiles.configure").isEmpty)
        // Gone elsewhere: the next listing drops it (and does not bring a deleted one back).
        w.hosted.refresh(force: true)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(w.store.room(key) == nil)
    }

    @Test func whoIsWorkingComesFromTheGatewaysState() async throws {
        let w = try await world()
        w.hosted.refresh(force: true)
        #expect(await BotsTest.waitUntil { w.store.room("gw:default/room-1") != nil })
        let key = "gw:default/room-1"
        w.gateway.working = true
        w.hosted.roomShown(key, true)
        #expect(await BotsTest.waitUntil { w.store.room(key)?.running == true && w.store.room(key)?.turn?.name == "ivy" })
        w.gateway.working = false
        #expect(await BotsTest.waitUntil { w.store.room(key)?.running == false })
        w.hosted.shutdown()
    }

    @Test func anOlderHermesWithoutGroupMethodsIsNotAskedAgain() async throws {
        let w = try await world()
        w.client.on("groups.list") { _ in throw RPCError(code: -32601, message: "unknown method groups.list", data: nil) }
        w.hosted.refresh(force: true)
        #expect(await BotsTest.waitUntil { w.client.calls("groups.list").count == 3 })
        try? await Task.sleep(for: .milliseconds(100))
        w.hosted.refresh(force: true)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(w.client.calls("groups.list").count == 3)
        #expect(w.store.rooms.isEmpty)
    }
}

private extension GroupRoom {
    func withLog() -> GroupRoom {
        var room = self
        room.log = [GroupMessage(id: "a", at: 1, from: .you, text: "hi", thread: "t", truncated: nil)]
        return room
    }
}
