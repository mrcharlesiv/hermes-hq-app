// [hosted] Group chats Hermes runs on its gateway (`groups.*`, H:gateway/session_group_controls.py,
// H:gateway/hosted_rooms.py). Hermes Desktop 0.23 makes every new group chat this way ("Every new group chat runs on a
// gateway", apps/desktop/src/plugins/hermes-bots/create-dialog.tsx), so a tester's own group chat never showed in the
// app (2026-11-14). Here the gateway drives the rounds; the app lists the rooms (`groups.list` per bot profile: a room
// belongs to the profile that made it), reads each one's append-only log (`groups.log` since a cursor), shows who is
// working (`groups.state`), and sends, stops, renames and disbands. Hermes Desktop polls an open room every 2 s
// (canonical-group-workspace.tsx); so does this. The rooms live in `GroupStore` beside the app's own, keyed
// `gw:<owner>/<room id>`, never in the mirror.

import CryptoKit
import Foundation

/// The pure half: the gateway's room and log shapes as `GroupRoom` fields.
nonisolated enum HostedRoomLog {
    /// A room object of `groups.list` / `groups.state` / `groups.create` as a room record (owner = the profile asked).
    static func room(_ raw: JSONValue?, owner: String) -> GroupRoom? {
        guard let object = raw?.object, let roomId = object["room_id"]?.string, !roomId.isEmpty,
              object["disbanded_at"]?.double == nil else { return nil }
        let name = object["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var room = GroupRoom(name: name.isEmpty ? "Group Chat" : name, roomId: roomId)
        room.members = members(object["members"])
        room.hosted = HostedRoomRef(owner: owner, roomId: roomId, cursor: 0, latest: object["latest_seq"]?.int ?? 0,
                                    revision: object["revision"]?.int ?? 0, epoch: nil)
        return room
    }

    /// The room's roster: each member as a descriptor named by its profile, its gateway `member_id` kept in `raw`.
    static func members(_ raw: JSONValue?) -> [GroupMember] {
        (raw?.array ?? []).compactMap { value in
            guard let object = value.object, let profile = object["profile"]?.string, !profile.isEmpty else { return nil }
            let handle = object["handle"]?.string
            let display = object["display_name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            var member = GroupMember(name: profile, handle: handle, title: display?.isEmpty == false ? display : nil)
            var rawObject = member.raw.object ?? [:]
            rawObject["member_id"] = object["member_id"] ?? .string(profile)
            if object["target"]?["kind"]?.string == "peer" {
                // Lent by another computer's gateway: shown, never driven here.
                member.sourceScoped = true
                member.connectionId = object["target"]?["installation_id"]?.string ?? object["target"]?["peer_id"]?.string ?? "peer"
                member.connectionLabel = member.title
                rawObject["sourceScoped"] = true
            }
            member.raw = .object(rawObject)
            return member
        }
    }

    static func memberId(_ member: GroupMember) -> String { member.raw["member_id"]?.string ?? member.name }

    /// The members `groups.create` takes for these bots of this gateway (each its own profile under its handle, as
    /// Hermes Desktop's `rosterEntry`), or nil when the gateway would refuse them: 2 to 6, each profile and handle a
    /// gateway identifier, handles distinct, `all` and `everyone` reserved (H:gateway/hosted_room_discussion.py
    /// `validate_roster`).
    static func roster(_ members: [GroupMember]) -> [JSONValue]? {
        guard (GroupLimits.minMembers...GroupLimits.maxMembers).contains(members.count) else { return nil }
        var profiles: Set<String> = [], handles: Set<String> = ["all", "everyone"]
        var out: [JSONValue] = []
        for member in members {
            let profile = member.name.trimmingCharacters(in: .whitespaces)
            let handle = GroupMentions.handle(name: profile, saved: member.handle)
            guard !member.sourceScoped, isIdentifier(profile), isIdentifier(handle),
                  profiles.insert(profile.lowercased()).inserted, handles.insert(handle.lowercased()).inserted else { return nil }
            out.append(["member_id": .string(profile), "profile": .string(profile), "handle": .string(handle),
                        "target": ["kind": "local", "profile": .string(profile)]])
        }
        return out
    }

    /// H:gateway/hosted_rooms_common.py `IDENTIFIER_RE`, 128 characters at most.
    static func isIdentifier(_ value: String) -> Bool {
        value.count <= 128 && value.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]*$", options: .regularExpression) != nil
    }

    /// Whether a `groups.capabilities` answer says this gateway runs a new room with these bots: its room driver is
    /// up (Hermes Desktop's `groupExecutionMode`: without one a made room never answers), it lists `groups.create`
    /// when it lists methods, and it can seat every bot when it says whom it seats (`seatable_profiles`).
    static func canHost(_ capabilities: JSONValue, profiles: [String]) -> Bool {
        guard capabilities["driver"]?.bool == true else { return false }
        if let methods = capabilities["methods"]?.array, !methods.contains(.string("groups.create")) { return false }
        if let seatable = capabilities["seatable_profiles"]?.array {
            let names = Set(seatable.compactMap(\.string))
            guard profiles.allSatisfy(names.contains) else { return false }
        }
        return true
    }

    /// The id the gateway gives your send: `user:` + sha256 of the client's event id (`user_event_id`,
    /// H:gateway/hosted_rooms.py). Your bubble carries the client id until the log shows the gateway's copy.
    static func userEventId(_ clientEventId: String) -> String {
        let digest = SHA256.hash(data: Data(clientEventId.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        return "user:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// What one page of the log adds.
    struct Applied: Equatable, Sendable {
        var entries: [GroupMessage] = []
        /// (kind, member key, detail, thread) for the room's Activity page.
        var activity: [Activity] = []
        var renamed: String?
        var disbanded = false
        /// Set when a `room.activity` event paused the discussion at its cap (`status == "bounded"`).
        var boundedPause: HostedRoomPause?
        /// True when a later log event supersedes any prior bounded pause (new send, continue, stop, or settle).
        var clearsBoundedPause = false
        /// Updated room context carried in a `room.context_set` event.
        var updatedContext: HostedRoomContext?

        struct Activity: Equatable, Sendable {
            var kind: GroupActivityEvent.Kind
            var member: String
            var detail: String?
            var thread: String?
        }
    }

    /// One page of `groups.log` events (in seq order) read against the room's roster.
    static func read(_ events: [JSONValue], members: [GroupMember]) -> Applied {
        var byId: [String: GroupMember] = [:]
        for member in members { byId[memberId(member)] = member }
        func member(_ id: String?, profile: String?) -> GroupMember? {
            if let id, let found = byId[id] { return found }
            if let profile { return members.first { $0.name == profile && !$0.sourceScoped } }
            return nil
        }
        var out = Applied()
        for event in events {
            guard let kind = event["kind"]?.string else { continue }
            let payload = event["payload"]
            let actor = event["actor"]
            let thread = payload?["thread_id"]?.string
            let at = ((event["created_at"]?.double ?? Date().timeIntervalSince1970) * 1000).rounded()
            let id = event["event_id"]?.string
            switch kind {
            case "message.user":
                out.boundedPause = nil
                out.clearsBoundedPause = true
                var text = (payload?["text"]?.string ?? payload?["content"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let files = payload?["attachments"]?.array?.count ?? 0
                if files > 0 { text += (text.isEmpty ? "" : "\n\n") + (files == 1 ? "(1 attachment)" : "(\(files) attachments)") }
                // A post the gateway's scheduler made (`cron:` actor) is not yours: it says so in its name.
                let scheduled = actor?["id"]?.string?.hasPrefix("cron") == true
                let from = scheduled ? GroupAuthor(kind: .user, name: "Scheduled", source: "cron", gateway: nil) : .you
                out.entries.append(GroupMessage(id: id, at: at, from: from, text: text, thread: thread, truncated: nil))
            case "message.member":
                let speaker = member(actor?["id"]?.string ?? payload?["member_id"]?.string, profile: actor?["profile"]?.string)
                let name = speaker?.name ?? actor?["profile"]?.string ?? actor?["id"]?.string ?? "bot"
                let text = (payload?["text"]?.string ?? payload?["content"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                out.entries.append(GroupMessage(id: id, at: at, from: GroupAuthor(kind: .member, name: name, source: nil, gateway: nil),
                                                text: text, thread: thread, truncated: nil))
            case "turn.settled":
                let key = member(payload?["member_id"]?.string, profile: nil).map(GroupKeys.memberKey) ?? ""
                out.activity.append(.init(kind: payload?["passed"]?.bool == true ? .passed : .replied, member: key, detail: nil, thread: thread))
            case "turn.failed", "member.unavailable":
                let key = member(payload?["member_id"]?.string, profile: nil).map(GroupKeys.memberKey) ?? ""
                let reason = payload?["error"]?.string ?? payload?["reason"]?.string ?? payload?["reason_code"]?.string
                out.activity.append(.init(kind: .failed, member: key, detail: reason.map(plainReason), thread: thread))
            case "turn.cancelled":
                let key = member(payload?["member_id"]?.string, profile: nil).map(GroupKeys.memberKey) ?? ""
                out.activity.append(.init(kind: .cancelled, member: key, detail: nil, thread: thread))
            case "room.stop_requested":
                out.boundedPause = nil
                out.clearsBoundedPause = true
                out.activity.append(.init(kind: .stopped, member: "", detail: nil, thread: thread))
            case "room.continued", "discussion.continued":
                out.boundedPause = nil
                out.clearsBoundedPause = true
            case "room.context_set", "room.context", "room.context_updated":
                if let context = HostedRoomContext(json: payload) { out.updatedContext = context }
            case "room.activity":
                if payload?["status"]?.string == "bounded" {
                    let discussionId = payload?["discussion_event_id"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !discussionId.isEmpty {
                        out.boundedPause = HostedRoomPause(discussionEventId: discussionId, threadId: thread)
                        out.clearsBoundedPause = false
                    }
                    out.activity.append(.init(kind: .capped, member: "", detail: nil, thread: thread))
                } else if payload?["status"]?.string == "settled" {
                    out.boundedPause = nil
                    out.clearsBoundedPause = true
                    out.activity.append(.init(kind: .settled, member: "", detail: nil, thread: thread))
                }
            case "room.renamed":
                if let name = payload?["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { out.renamed = name }
            case "room.disbanded":
                out.disbanded = true
            default:
                continue
            }
        }
        return out
    }

    /// A gateway reason code as words (`snake_case` → "snake case").
    static func plainReason(_ code: String) -> String {
        code.contains(" ") ? code : code.replacingOccurrences(of: "_", with: " ")
    }

    /// The log with a page merged in: entries by id. Your own send keeps the id its bubble was drawn with: the
    /// gateway's copy of it (`user:` + sha256 of that id) is the same message, so it is not added again.
    static func merge(_ log: [GroupMessage], adding entries: [GroupMessage]) -> [GroupMessage] {
        var out = log
        var known = Set(out.compactMap(\.id))
        for entry in out where entry.from == .you { if let id = entry.id, !id.hasPrefix("user:") { known.insert(userEventId(id)) } }
        for entry in entries {
            guard let id = entry.id else { out.append(entry); continue }
            guard !known.contains(id) else { continue }
            out.append(entry)
            known.insert(id)
        }
        return out
    }
}

/// The working half: one account's gateway rooms.
@MainActor final class HostedRooms {
    let store: GroupStore
    let client: any GatewayClient
    /// The room is on screen (no unread mark, no alert for its replies).
    var isFocused: (String) -> Bool = { _ in false }
    /// A member's reply arrived (the hub's alert, as for the app's own rooms).
    var onReply: ((_ room: GroupRoom, _ entry: GroupMessage, _ seat: GroupSeat?) -> Void)?
    /// How often an open (or working) room is read.
    var pollEvery: TimeInterval = 2
    /// The shortest gap between two full listings.
    /// (Was 20 s: every roster change asks for it, and each listing is one call per bot. The owner's logs, 2026-11-18:
    /// about 4,800 `groups.list` calls a day for one room.)
    var listEvery: TimeInterval = 60

    /// Profiles whose gateway has no `groups.*` (an older Hermes): not asked again this connection.
    private var unsupported: Set<String> = []
    private var listing: Task<Void, Never>?
    private var lastListed: Date?
    private var pulls: [String: Task<Void, Never>] = [:]
    private var watchers: [String: Task<Void, Never>] = [:]
    private var shown: Set<String> = []
    private var sending: Set<String> = []
    private(set) var retrying: Set<String> = []
    private var eventsTask: Task<Void, Never>?
    private var seenBroadcasts: [String] = []
    private var closed = false

    init(store: GroupStore, client: any GatewayClient) {
        self.store = store
        self.client = client
        startChangeEvents()
    }

    func shutdown() {
        closed = true
        eventsTask?.cancel()
        eventsTask = nil
        listing?.cancel()
        for task in pulls.values { task.cancel() }
        for task in watchers.values { task.cancel() }
        listing = nil; pulls = [:]; watchers = [:]; shown = []; seenBroadcasts = []
    }

    /// Subscribes to `groups.changed` WebSocket broadcasts (Hermes 0.23.4+), deduping by `broadcast_id`.
    private func startChangeEvents() {
        guard !closed, eventsTask == nil else { return }
        let stream: AsyncStream<GatewayEvent> = (client as? LiveGatewayClient)?.events(matching: ["groups.changed"]) ?? client.events()
        eventsTask = Task { [weak self] in
            for await event in stream {
                guard let self, !self.closed else { return }
                guard event.type == "groups.changed" else { continue }
                self.handleGroupsChanged(event.payload)
            }
        }
    }

    func handleGroupsChanged(_ payload: JSONValue) {
        guard !closed else { return }
        if let bid = payload["broadcast_id"]?.string, !bid.isEmpty {
            if seenBroadcasts.contains(bid) { return }
            seenBroadcasts.append(bid)
            if seenBroadcasts.count > 128 { seenBroadcasts.removeFirst(seenBroadcasts.count - 128) }
        }
        if let roomIds = payload["room_ids"]?.array?.compactMap(\.string), !roomIds.isEmpty {
            let wanted = Set(roomIds)
            for room in store.rooms where room.isHosted {
                guard let roomId = room.hosted?.roomId, wanted.contains(roomId) else { continue }
                let key = room.key
                pull(key)
                if shown.contains(key) || room.running {
                    Task { [weak self] in _ = await self?.readState(key) }
                }
            }
            // Ignore broadcasts naming only rooms this device does not hold (avoids hammering `groups.list`).
        } else {
            for key in shown {
                pull(key)
                Task { [weak self] in _ = await self?.readState(key) }
            }
            refresh(force: false)
        }
    }

    /// A new socket: a gateway that said "no such method" may have been updated since.
    func connectionReady() {
        unsupported = []
        refresh(force: true)
        for key in shown { watch(key) }
    }

    private static func cancelId() -> String { UUID().uuidString.lowercased() }

    // MARK: The list

    /// Lists every bot profile's rooms (at most once per `listEvery` unless forced). Rooms that are new or have news
    /// are read; a room its owner no longer lists is gone.
    func refresh(force: Bool = false) {
        guard !closed, listing == nil else { return }
        if !force, let lastListed, Date().timeIntervalSince(lastListed) < listEvery { return }
        guard let bots = store.bots, bots.phase != .none else { return }
        let owners = bots.profiles.map(\.name).filter { !unsupported.contains($0) }
        guard !owners.isEmpty else { return }
        lastListed = Date()
        listing = Task { [weak self] in
            await self?.list(owners)
            self?.listing = nil
        }
    }

    private func list(_ owners: [String]) async {
        let started = Date()
        var listed: [String: [GroupRoom]] = [:]
        for owner in owners {
            guard !closed, !Task.isCancelled else { return }
            do {
                let result = try await client.call("groups.list", ["profile": .string(owner), "limit": 100], timeout: .seconds(15))
                listed[owner] = (result["rooms"]?.array ?? []).compactMap { HostedRoomLog.room($0, owner: owner) }
            } catch let error as RPCError where error.code == -32601 || error.code == -32602 {
                unsupported.insert(owner)          // an older Hermes: no gateway rooms there
            } catch {
                AppLog.swallowed("groups", "groups.list \(AppLog.tag(owner))", error)
            }
        }
        guard !closed else { return }
        var found = 0
        for (owner, rooms) in listed {
            let keys = Set(rooms.map(\.key))
            // A room made here after this listing was asked for is not in its answer: it is not gone.
            for room in store.rooms where room.hosted?.owner == owner && !keys.contains(room.key) && (made[room.key] ?? .distantPast) < started {
                AppLog.trace("groups", "hosted room \(AppLog.tag(room.key)) no longer listed: removed")
                store.removeHosted(room.key)
            }
            for room in rooms {
                store.upsertHosted(room)
                found += 1
                if let saved = store.room(room.key), let ref = saved.hosted, ref.latest > ref.cursor || saved.log.isEmpty && ref.latest > 0 {
                    pull(room.key)
                }
            }
        }
        if found > 0 { AppLog.trace("groups", "hosted rooms listed: \(found) on \(listed.count) profile(s)") }
    }

    // MARK: Making a room

    /// A New Group Chat whose answer was lost keeps its room id (by name and bots): Try Again asks for the same room,
    /// so a create that did reach the gateway is opened, not made twice (`groups.create` is idempotent by room id).
    private var pendingCreates: [String: String] = [:]
    /// When each room made here was made (see `list`).
    private var made: [String: Date] = [:]

    /// New Group Chat on the gateway (`groups.create`), as Hermes Desktop makes every new group chat: the room shows
    /// on every device and its rounds run with the app closed. Returns the new room's key, or nil when this gateway
    /// cannot run it (an older Hermes, no room driver, a bot it cannot seat, a refusal): the app then makes the room
    /// it runs itself. Throws when no answer came: the room may exist, and Try Again asks for the same one.
    func create(name: String, members: [GroupMember]) async throws -> String? {
        guard !closed, let bots = store.bots,
              let owner = (bots.profiles.first { $0.name == "default" } ?? bots.profiles.first(where: \.isDefault))?.name,
              let roster = HostedRoomLog.roster(members) else { return nil }
        let capabilities: JSONValue
        do {
            capabilities = try await client.call("groups.capabilities", ["profile": .string(owner)], timeout: .seconds(15))
        } catch let error as RPCError where !Self.unanswered(error) {
            AppLog.trace("groups", "hosted create: no groups.capabilities on \(AppLog.tag(owner)) (\(error.code)), the app runs the room")
            return nil
        }
        guard HostedRoomLog.canHost(capabilities, profiles: members.map(\.name)) else {
            AppLog.trace("groups", "hosted create: \(AppLog.tag(owner)) cannot run this room, the app runs it")
            return nil
        }
        let intent = name + "\n" + members.map(\.name).joined(separator: ",")
        let roomId = pendingCreates[intent] ?? GroupKeys.newRoomId()
        pendingCreates[intent] = roomId
        let result: JSONValue
        do {
            result = try await client.call("groups.create", ["profile": .string(owner), "room_id": .string(roomId), "name": .string(name),
                                                             "members": .array(roster)], timeout: .seconds(30))
        } catch let error as RPCError where !Self.unanswered(error) {
            // The gateway said no: nothing was made under this id.
            pendingCreates[intent] = nil
            AppLog.note("groups", "hosted create refused on \(AppLog.tag(owner)): \(Self.words(error)), the app runs the room")
            return nil
        }
        pendingCreates[intent] = nil
        guard let room = HostedRoomLog.room(result["room"], owner: owner) else {
            refresh(force: true)
            throw BotWriteError(title: "Couldn’t Open \(name)", reason: "Hermes made the group chat, but the app couldn’t read its answer. It will show in your list shortly.")
        }
        made[room.key] = Date()
        store.upsertHosted(room)
        AppLog.trace("groups", "hosted create \(AppLog.tag(room.key)): made on \(AppLog.tag(owner)), \(roster.count) members")
        return room.key
    }

    /// No gateway answer (never sent, the socket closed first, or no answer in time): nothing is known of the request.
    private static func unanswered(_ error: RPCError) -> Bool { error.isTimeout || error.isConnectionLost || error.isNotConnected }

    // MARK: Reading a room

    /// Reads what is new in the room's log (and nothing when a read is already going).
    func pull(_ key: String) {
        guard !closed, pulls[key] == nil else { return }
        pulls[key] = Task { [weak self] in
            await self?.readLog(key)
            self?.pulls[key] = nil
        }
    }

    private func readLog(_ key: String) async {
        for _ in 0..<20 {
            guard !closed, !Task.isCancelled, let room = store.room(key), let ref = room.hosted else { return }
            let first = ref.cursor == 0 && !room.log.contains { $0.from != .you || $0.id?.hasPrefix("user:") == true }
            let result: JSONValue
            do {
                result = try await client.call("groups.log", ["profile": .string(ref.owner), "room_id": .string(ref.roomId),
                                                             "since_seq": .number(Double(ref.cursor)), "limit": 200], timeout: .seconds(20))
            } catch let error as RPCError {
                if error.message.contains("ahead of the hosted room log") {
                    // The gateway's log restarted (a new authority): read it again from the start.
                    store.setHostedCursor(key, cursor: 0, epoch: nil, resetLog: true)
                    continue
                }
                if error.message == "not_found" || error.data?["reason"]?.string == "not_found" || error.message.contains("not found") {
                    store.removeHosted(key)
                }
                AppLog.swallowed("groups", "groups.log \(AppLog.tag(key))", error)
                return
            } catch {
                AppLog.swallowed("groups", "groups.log \(AppLog.tag(key))", error)
                return
            }
            let epoch = result["authority"]?["epoch"]?.int
            if let known = ref.epoch, let epoch, known != epoch, ref.cursor > 0 {
                store.setHostedCursor(key, cursor: 0, epoch: epoch, resetLog: true)
                continue
            }
            let events = result["events"]?.array ?? []
            let applied = HostedRoomLog.read(events, members: room.members)
            if applied.disbanded { store.removeHosted(key); return }
            let cursor = result["cursor"]?.int ?? ref.cursor
            var arrived: [GroupMessage] = []
            store.update(key, sync: false) { room in
                let before = Set(room.log.compactMap(\.id))
                room.log = HostedRoomLog.merge(room.log, adding: applied.entries)
                if let name = applied.renamed { room.name = name }
                if let context = applied.updatedContext { room.hostedContext = context }
                if let pause = applied.boundedPause {
                    room.pausedDiscussion = pause
                } else if applied.clearsBoundedPause {
                    room.pausedDiscussion = nil
                }
                if var ref = room.hosted {
                    ref.cursor = max(cursor, ref.cursor)
                    ref.latest = max(result["latest_seq"]?.int ?? cursor, ref.latest)
                    ref.epoch = epoch ?? ref.epoch
                    room.hosted = ref
                }
                arrived = room.log.filter { $0.from.kind == .member && !before.contains($0.id ?? "") }
            }
            for line in applied.activity { store.record(line.kind, room: key, member: line.member, detail: line.detail, thread: line.thread) }
            // News from a room that is not on screen: its mark and alert, as the app's own rooms (never for the first read).
            if !first, !arrived.isEmpty, let room = store.room(key) {
                let seats = store.seated(room)
                if !isFocused(key) { store.setUnread(key, true) }
                for entry in arrived { onReply?(room, entry, seats.first { $0.name == entry.from.name }) }
            }
            guard result["has_more"]?.bool == true, cursor > ref.cursor else { return }
        }
    }

    /// Who is working right now (`groups.state`): the room's running state and the member on turn.
    private func readState(_ key: String) async -> Bool {
        guard let room = store.room(key), let ref = room.hosted else { return false }
        guard let result = try? await client.call("groups.state", ["profile": .string(ref.owner), "room_id": .string(ref.roomId)],
                                                  timeout: .seconds(15)) else { return room.running }
        let driver = result["driver_status"]
        let activity = driver?["member_activity"]?.array ?? []
        let working = driver?["working"]?.bool == true || !activity.isEmpty
        let busy = activity.first { ["running", "queued", "waiting"].contains($0["status"]?.string ?? "running") } ?? activity.first
        let member = busy?["member_id"]?.string.flatMap { id in room.members.first { HostedRoomLog.memberId($0) == id } }
        let pendingActions = (driver?["pending_actions"]?.array ?? []).compactMap(HostedPendingAction.init(json:))
        let waiting = !pendingActions.isEmpty
        let routingModes = driver?["routing_modes"]?.array?.compactMap(\.string)
        let maxContinues = driver?["max_continues"]?.int
        let changeEvents = result["change_events"]?.bool == true
        let parsedContext = HostedRoomContext(json: result["context"])
        let statePause: HostedRoomPause? = {
            if let raw = driver?["paused_discussion"],
               let discId = raw["discussion_event_id"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               !discId.isEmpty {
                return HostedRoomPause(discussionEventId: discId, threadId: raw["thread_id"]?.string)
            }
            if let discId = driver?["bounded_discussion_event_id"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               !discId.isEmpty {
                return HostedRoomPause(discussionEventId: discId, threadId: driver?["bounded_thread_id"]?.string)
            }
            return nil
        }()
        store.setRuntime(key) { room in
            room.running = working
            room.turn = working ? member.map { GroupTurnState(name: GroupKeys.memberKey($0), thread: busy?["thread_id"]?.string ?? "",
                                                              waitingOnUser: waiting) } : nil
            room.pendingActions = pendingActions
            room.routingModes = routingModes
            room.maxContinues = maxContinues
            room.supportsChangeEvents = changeEvents
            if working {
                room.pausedDiscussion = nil
            } else if let statePause {
                room.pausedDiscussion = statePause
            }
        }
        if let latest = result["room"]?["latest_seq"]?.int, latest > (store.room(key)?.hosted?.cursor ?? 0) { await readLog(key) }
        if var fresh = HostedRoomLog.room(result["room"], owner: ref.owner) {
            fresh.hostedContext = parsedContext
            store.upsertHosted(fresh)
        } else if let parsedContext {
            store.update(key, sync: false) { $0.hostedContext = parsedContext }
        }
        return working
    }

    /// The room came on screen or left it: an open room is read every `pollEvery` seconds (or backstop when `groups.changed` is active).
    func roomShown(_ key: String, _ on: Bool) {
        if on { shown.insert(key); watch(key) } else { shown.remove(key) }
    }

    /// Reads the room while it is on screen or working; ends one read after both are over.
    private func watch(_ key: String) {
        guard !closed, watchers[key] == nil, store.room(key)?.isHosted == true else { return }
        watchers[key] = Task { [weak self] in
            var quiet = 0
            while let self, !self.closed, !Task.isCancelled {
                let working = await self.readState(key)
                await self.readLog(key)
                quiet = working || self.shown.contains(key) ? 0 : quiet + 1
                if quiet >= 2 || self.store.room(key) == nil { break }
                let supportsPush = self.store.room(key)?.supportsChangeEvents == true
                let interval = supportsPush ? max(self.pollEvery, 15) : self.pollEvery
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            self?.watchers[key] = nil
        }
    }

    // MARK: Your send, Stop, rename, disband

    /// Your send into a gateway room: the bubble at once (under its client id), then `groups.send`.
    func send(_ text: String, room key: String, thread replyThread: String?, entryId: String?) -> GroupEngine.SendOutcome {
        guard !closed, let room = store.room(key), room.isHosted else { return .ignored }
        if GroupPrompt.isSlashCommand(text) { return .refused(.slashCommand) }
        guard store.seated(room).contains(where: \.canDrive) || room.members.isEmpty == false else { return .refused(.noMembers(room: room.name)) }
        let clientId = entryId ?? UUID().uuidString.lowercased()
        let thread = (replyThread?.isEmpty == false ? replyThread : nil) ?? clientId
        let entry = GroupMessage(id: clientId, at: (Date().timeIntervalSince1970 * 1000).rounded(), from: .you,
                                 text: GroupPrompt.compact(text, limit: GroupLimits.historyLineChars).text, thread: thread, truncated: nil)
        store.update(key, sync: false, now: true) { $0.log.append(entry) }
        store.record(.queued, room: key, thread: thread)
        deliver(clientId, text: text, thread: thread, key: key)
        return .sent(entryId: clientId)
    }

    /// Try Again under an undelivered send: the same event id, so a send that did reach the room is not posted twice.
    func retry(_ entryId: String, room key: String) {
        guard let room = store.room(key), let entry = room.log.first(where: { $0.id == entryId }), !retrying.contains(entryId) else { return }
        retrying.insert(entryId)
        store.update(key, sync: false) { $0.undelivered[entryId] = nil }
        deliver(entryId, text: entry.text, thread: entry.threadKey, key: key)
    }

    private func deliver(_ clientId: String, text: String, thread: String, key: String) {
        guard let ref = store.room(key)?.hosted, !sending.contains(clientId) else { return }
        sending.insert(clientId)
        store.setRuntime(key) { $0.running = true }
        Task { [weak self] in
            let params: JSONValue = ["profile": .string(ref.owner), "room_id": .string(ref.roomId), "event_id": .string(clientId),
                                     "payload": ["text": .string(text), "thread_id": .string(thread)]]
            var reason: String?
            do {
                let result = try await self?.client.call("groups.send", params, timeout: .seconds(30))
                if result?["accepted"]?.bool == false { reason = "Hermes didn’t take the message." }
            } catch let error as RPCError {
                reason = Self.words(error)
            } catch {
                reason = (error as? LocalizedError)?.errorDescription ?? "Couldn’t reach Hermes."
            }
            guard let self else { return }
            self.sending.remove(clientId)
            self.retrying.remove(clientId)
            if let reason {
                AppLog.note("groups", "hosted send \(AppLog.tag(key)) refused: \(reason)")
                self.store.update(key, sync: false) { $0.undelivered[clientId] = reason }
                self.store.setRuntime(key) { $0.running = false }
                self.store.record(.failed, room: key, detail: reason, thread: thread)
            } else {
                self.store.record(.delivered, room: key, thread: thread)
            }
            self.watch(key)
        }
    }

    /// Delete on an undelivered send: it leaves this device's log (the gateway never took it).
    func deleteEntry(_ entryId: String, room key: String) {
        store.update(key, sync: false) { room in
            room.log.removeAll { $0.id == entryId }
            room.undelivered[entryId] = nil
        }
    }

    /// Stop: the gateway cancels the room's work in flight.
    func stop(_ key: String) async -> Bool {
        guard let ref = store.room(key)?.hosted else { return true }
        store.setRuntime(key) { $0.running = false; $0.turn = nil }
        store.record(.stopped, room: key)
        do {
            _ = try await client.call("groups.stop", ["profile": .string(ref.owner), "room_id": .string(ref.roomId),
                                                      "cancel_id": .string(Self.cancelId())], timeout: .seconds(20))
            watch(key)
            return true
        } catch {
            AppLog.swallowed("groups", "groups.stop \(AppLog.tag(key))", error)
            return false
        }
    }

    func rename(_ key: String, to name: String) async throws {
        guard let room = store.room(key), let ref = room.hosted else { return }
        do {
            let result = try await client.call("groups.rename", ["profile": .string(ref.owner), "room_id": .string(ref.roomId),
                                                                 "event_id": .string(Self.cancelId()), "name": .string(name)], timeout: .seconds(20))
            store.update(key, sync: false) { $0.name = result["room"]?["name"]?.string ?? name }
        } catch let error as RPCError {
            throw BotWriteError(title: "Couldn’t Rename \(room.name)", reason: Self.words(error))
        }
    }

    func disband(_ key: String) async throws {
        guard let room = store.room(key), let ref = room.hosted else { return }
        do {
            _ = try await client.call("groups.disband", ["profile": .string(ref.owner), "room_id": .string(ref.roomId),
                                                         "cancel_id": .string(Self.cancelId())], timeout: .seconds(30))
        } catch let error as RPCError where !(error.message == "not_found" || error.data?["reason"]?.string == "not_found") {
            throw BotWriteError(title: "Couldn’t Delete \(room.name)", reason: Self.words(error))
        }
        watchers.removeValue(forKey: key)?.cancel()
        store.removeHosted(key)
    }

    // MARK: Approvals, Continue Discussion, Context, Per-Profile Approval Mode (v0.23.2–v0.23.5)

    /// Answers a member's pending approval inside a hosted group chat (`groups.approve`).
    func approve(_ key: String, action: HostedPendingAction, choice: ApprovalChoice) async throws {
        guard let room = store.room(key), let ref = room.hosted else { return }
        guard action.isApproval, action.executionGeneration >= 1,
              let requestId = action.requestId, !requestId.isEmpty else {
            throw BotWriteError(title: "Couldn’t Answer Approval", reason: "This group chat approval is no longer available.")
        }
        guard choice == .once || choice == .deny else {
            throw BotWriteError(title: "Couldn’t Answer Approval", reason: "Group approvals only support Allow Once or Deny.")
        }
        if !action.choices.isEmpty, !action.choices.contains(choice.rawValue) {
            throw BotWriteError(title: "Couldn’t Answer Approval", reason: "That choice is not offered for this approval.")
        }
        if choice == .once, !action.isReviewableApproval {
            throw BotWriteError(title: "Couldn’t Answer Approval", reason: "Allow once requires a reviewable command or description.")
        }
        let params: JSONValue = [
            "profile": .string(ref.owner),
            "room_id": .string(ref.roomId),
            "member_id": .string(action.memberId),
            "task_id": .string(action.taskId),
            "execution_generation": .number(Double(action.executionGeneration)),
            "choice": .string(choice.rawValue),
            "request_id": .string(requestId),
        ]
        do {
            _ = try await client.call("groups.approve", params, timeout: .seconds(20))
            _ = await readState(key)
            pull(key)
        } catch let error as RPCError {
            throw BotWriteError(title: "Couldn’t Answer Approval", reason: Self.words(error))
        }
    }

    /// Resumes a hosted group discussion paused at its round limit (`groups.continue`).
    func continueDiscussion(_ key: String, discussionEventId: String) async throws {
        guard let room = store.room(key), let ref = room.hosted, !discussionEventId.isEmpty else { return }
        do {
            _ = try await client.call("groups.continue", [
                "profile": .string(ref.owner),
                "room_id": .string(ref.roomId),
                "discussion_event_id": .string(discussionEventId),
            ], timeout: .seconds(20))
            store.setRuntime(key) {
                $0.pausedDiscussion = nil
                $0.running = true
            }
            watch(key)
        } catch let error as RPCError {
            throw BotWriteError(title: "Couldn’t Continue Discussion", reason: Self.words(error))
        }
    }

    /// Saves a hosted room's purpose, shared notes (max 4,096 UTF-8 bytes), and routing (`groups.context`).
    func setContext(_ key: String, purpose: String, notes: String, routing: String? = nil, leadMemberId: String? = nil) async throws {
        guard let room = store.room(key), let ref = room.hosted else { return }
        guard HostedRoomContext.notesUTF8Count(notes) <= HostedRoomContext.maxNotesBytes else {
            throw BotWriteError(title: "Notes Too Long", reason: "Shared notes can be at most \(HostedRoomContext.maxNotesBytes) bytes.")
        }
        let normalizedPurpose = HostedRoomContext.normalizePurpose(purpose)
        var params: [String: JSONValue] = [
            "profile": .string(ref.owner),
            "room_id": .string(ref.roomId),
            "event_id": .string(Self.cancelId()),
            "purpose": .string(normalizedPurpose),
            "notes": .string(notes),
        ]
        if let routing, !routing.isEmpty { params["routing"] = .string(routing) }
        if let leadMemberId { params["lead_member_id"] = .string(leadMemberId) }
        do {
            let result = try await client.call("groups.context", .object(params), timeout: .seconds(20))
            let saved = HostedRoomContext(json: result["context"])
                ?? HostedRoomContext(purpose: normalizedPurpose, notes: notes, routing: routing ?? "everyone", leadMemberId: leadMemberId ?? "")
            store.update(key, sync: false) { $0.hostedContext = saved }
        } catch let error as RPCError {
            throw BotWriteError(title: "Couldn’t Save Context", reason: Self.words(error))
        }
    }

    /// Reads one member profile's `approvals.mode` (`config.get`, scoped to `profile` per Hermes 0.23.5 #125969).
    func approvalMode(forProfile profile: String) async throws -> String {
        let trimmed = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        var params: [String: JSONValue] = ["key": .string("approvals.mode")]
        if !trimmed.isEmpty { params["profile"] = .string(trimmed) }
        let result = try await client.call("config.get", .object(params), timeout: .seconds(15))
        let mode = result["value"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return ["manual", "smart", "off"].contains(mode) ? mode : "manual"
    }

    /// Sets one member profile's `approvals.mode` (`config.set`, scoped to `profile` per Hermes 0.23.5 #125969).
    @discardableResult
    func setApprovalMode(_ mode: String, forProfile profile: String) async throws -> String {
        let normalized = mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmed = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        var params: [String: JSONValue] = ["key": .string("approvals.mode"), "value": .string(normalized)]
        if !trimmed.isEmpty { params["profile"] = .string(trimmed) }
        let result = try await client.call("config.set", .object(params), timeout: .seconds(15))
        let kept = result["value"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? normalized
        return ["manual", "smart", "off"].contains(kept) ? kept : normalized
    }

    /// A refusal in plain words: the gateway's own sentence when it has one, else what the code means.
    static func words(_ error: RPCError) -> String {
        switch error.message {
        case "invalid_params": return "Hermes didn’t accept that."
        case "permission_denied": return "This sign-in can’t change this group chat."
        case "not_found": return "This group chat is gone from Hermes."
        case "runtime_draining": return "Hermes is restarting. Try again in a moment."
        case "": return "Couldn’t reach Hermes."
        default: return error.message.contains("_") && !error.message.contains(" ") ? HostedRoomLog.plainReason(error.message) : error.message
        }
    }
}
