// [groups] A group chat ("room") as the app keeps it (docs/spec/3x-groups.md §3.2). Field names are the web's
// (`HB/group-chat.ts`), so the gateway mirror and the device file read the same way. Pure value code.

import Foundation

nonisolated struct GroupAuthor: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case member, user }
    var kind: Kind
    /// A member's profile name ("ivy"), or "You".
    var name: String
    /// Another gateway's label, set by other devices only.
    var source: String?
    var gateway: String?

    static let you = GroupAuthor(kind: .user, name: "You", source: nil, gateway: nil)
}

nonisolated struct GroupMessage: Codable, Hashable, Sendable {
    /// A lowercase UUID on native writes; absent on old entries.
    var id: String?
    /// Milliseconds since 1970.
    var at: Double
    var from: GroupAuthor
    var text: String
    /// Absent = "legacy".
    var thread: String?
    /// The mirror cut this text.
    var truncated: Bool?

    var threadKey: String { GroupKeys.thread(thread) }
}

/// A saved member descriptor. Unknown keys are kept in `raw` and written back untouched.
nonisolated struct GroupMember: Codable, Hashable, Sendable {
    var name: String
    var handle: String?
    var title: String?
    var sourceScoped: Bool = false
    var connectionId: String?
    var connectionLabel: String?
    var raw: JSONValue = .object([:])

    init(name: String, handle: String? = nil, title: String? = nil) {
        self.name = name
        self.handle = handle
        self.title = title
        var object: [String: JSONValue] = ["name": .string(name)]
        if let handle { object["handle"] = .string(handle) }
        raw = .object(object)
    }

    /// A descriptor as the mirror carries it; nil without a usable name.
    init?(json: JSONValue?) {
        guard let object = json?.object, let name = object["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        self.name = name
        handle = object["handle"]?.string
        title = object["title"]?.string
        sourceScoped = object["sourceScoped"]?.bool == true
        connectionId = object["connectionId"]?.string
        connectionLabel = object["connectionLabel"]?.string
        raw = .object(object)
    }

    /// The descriptor for the mirror: its raw keys as read, the name (and handle) current.
    var json: JSONValue {
        var object = raw.object ?? [:]
        object["name"] = .string(name)
        if let handle, !handle.isEmpty { object["handle"] = .string(handle) }
        if sourceScoped { object["sourceScoped"] = .bool(true) }
        return .object(object)
    }

    var key: String { GroupKeys.memberKey(self) }
}

nonisolated struct GroupHold: Codable, Hashable, Sendable {
    var at: Double
    var byMessageId: String?
    var thread: String?
}

/// A turn that timed out and may still land (§6.7).
nonisolated struct GroupStranded: Codable, Hashable, Sendable {
    var before: Int
    var thread: String
    var at: Double
    var stored: String?
}

/// A turn a member was asked and has not answered yet, saved the moment its prompt is accepted. One still in the file
/// at launch means the app was closed mid-turn: it becomes a `GroupStranded` marker (the reply is collected later)
/// and the member's mark moves past what it was shown, so nothing is sent to it twice.
nonisolated struct GroupAsking: Codable, Hashable, Sendable {
    var before: Int
    var thread: String
    var at: Double
    var stored: String?
    /// The watermark's key, and the entry the member had read up to (its id, else how long the log was).
    var markKey: String
    var anchorId: String?
    var anchorCount: Int
}

nonisolated struct GroupTurnState: Hashable, Sendable {
    /// The member's key.
    var name: String
    var thread: String
    var waitingOnUser = false
}

/// A room's handle for this run of the app: it survives a rename and a new key. Never saved, never compared.
nonisolated struct GroupRuntimeID: Sendable, Equatable {
    let value = UUID()
    static func == (a: GroupRuntimeID, b: GroupRuntimeID) -> Bool { true }
}

/// [hosted] A group chat Hermes itself runs (`groups.*`, gateway/hosted_rooms.py): Hermes Desktop makes every new group
/// chat this way, so a tester's own group chat never showed here (2026-11-14). The gateway drives its rounds; this
/// device reads its log and sends into it. Never in the mirror.
nonisolated struct HostedRoomRef: Codable, Hashable, Sendable {
    /// The bot profile whose gateway owns the room: every `groups.*` call names it.
    var owner: String
    /// The gateway's room id.
    var roomId: String
    /// The newest log seq taken into `log`.
    var cursor = 0
    /// The newest seq the gateway last reported (`latest_seq`).
    var latest = 0
    /// The room's revision as last read (renames bump it).
    var revision = 0
    /// The gateway's authority epoch: a new one means the log was replaced, so it is read again from the start.
    var epoch: Int?
}

/// [hosted] Shared purpose, notes, and routing for a hosted group chat (`groups.context`, Hermes 0.23.2+).
nonisolated struct HostedRoomContext: Codable, Hashable, Sendable {
    var purpose: String = ""
    var notes: String = ""
    /// `"everyone"`, `"lead"`, or `"auto"`.
    var routing: String = "everyone"
    var leadMemberId: String = ""

    static let maxNotesBytes = 4096
    static let maxPurposeChars = 500

    static func notesUTF8Count(_ text: String) -> Int {
        text.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count
    }

    /// Collapses internal whitespace, trims, and caps purpose at 500 characters (matching upstream `groups.context`).
    static func normalizePurpose(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count <= maxPurposeChars ? collapsed : String(collapsed.prefix(maxPurposeChars))
    }

    init(purpose: String = "", notes: String = "", routing: String = "everyone", leadMemberId: String = "") {
        self.purpose = purpose
        self.notes = notes
        self.routing = routing.isEmpty ? "everyone" : routing
        self.leadMemberId = leadMemberId
    }

    init?(json: JSONValue?) {
        guard let object = json?.object else { return nil }
        self.init(
            purpose: object["purpose"]?.string ?? "",
            notes: object["notes"]?.string ?? "",
            routing: object["routing"]?.string ?? "everyone",
            leadMemberId: object["lead_member_id"]?.string ?? ""
        )
    }
}

/// [hosted] One pending decision from `driver_status.pending_actions` (`groups.approve` / retry / discard).
nonisolated struct HostedPendingAction: Hashable, Sendable, Identifiable {
    var kind: String
    var memberId: String
    var taskId: String
    var executionGeneration: Int
    var requestId: String?
    var command: String?
    var description: String?
    var choices: [String] = []

    var id: String { "\(kind):\(taskId):\(executionGeneration):\(requestId ?? "")" }
    var isApproval: Bool { kind == "approval" }
    /// Allow Once is only permitted when the gateway gave a reviewable preview and exact request id.
    var isReviewableApproval: Bool {
        guard isApproval, let req = requestId, !req.isEmpty else { return false }
        let cmd = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let desc = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !cmd.isEmpty || !desc.isEmpty
    }

    init(kind: String, memberId: String, taskId: String, executionGeneration: Int,
         requestId: String? = nil, command: String? = nil, description: String? = nil, choices: [String] = []) {
        self.kind = kind
        self.memberId = memberId
        self.taskId = taskId
        self.executionGeneration = executionGeneration
        self.requestId = requestId
        self.command = command
        self.description = description
        self.choices = choices
    }

    init?(json: JSONValue) {
        guard let kind = json["kind"]?.string, !kind.isEmpty,
              let memberId = json["member_id"]?.string, !memberId.isEmpty,
              let taskId = json["task_id"]?.string, !taskId.isEmpty,
              let generation = json["execution_generation"]?.int, generation >= 1 else { return nil }
        let approval = json["approval"]
        let reqId = json["request_id"]?.string
            ?? approval?["request_id"]?.string
            ?? approval?["prompt_id"]?.string
        let choices = (approval?["choices"]?.array ?? []).compactMap(\.string)
        let trimmedReqId = reqId?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            kind: kind,
            memberId: memberId,
            taskId: taskId,
            executionGeneration: generation,
            requestId: trimmedReqId?.isEmpty == false ? trimmedReqId : nil,
            command: approval?["command"]?.string,
            description: approval?["description"]?.string,
            choices: choices
        )
    }
}

/// [hosted] A discussion paused at its round limit (`room.activity` `status == "bounded"`, resumed by `groups.continue`).
nonisolated struct HostedRoomPause: Codable, Hashable, Sendable {
    var discussionEventId: String
    var threadId: String?
}

nonisolated struct GroupRoom: Codable, Sendable, Equatable {
    var name: String
    var roomId: String?
    /// [hosted] Set for a room Hermes runs on its gateway (see `HostedRoomRef`).
    var hosted: HostedRoomRef?
    /// [hosted] Shared room context (purpose, notes, routing) as last read from `groups.state` or saved via `groups.context`.
    var hostedContext: HostedRoomContext?
    var log: [GroupMessage] = []
    /// "<thread>::<memberKey>" → entries of the room log the member has seen (an index into `log`).
    var watermarks: [String: Int] = [:]
    var members: [GroupMember] = []
    var image: String?
    var holdDetection = true
    var holds: [String: GroupHold] = [:]
    var heldMessages: [String: [String]] = [:]
    /// "thread:<thread>::<memberKey>" → stored session id.
    var sessions: [String: String] = [:]
    var stranded: [String: GroupStranded] = [:]
    /// Member key → the turn it is on right now (see `GroupAsking`).
    var asking: [String: GroupAsking] = [:]
    var syncRevision = 0
    /// Entries the mirror said it left out (§7.13's notice).
    var omitted = 0
    /// Mirror keys this device does not know, written back untouched.
    var extra: [String: JSONValue] = [:]
    // This iPhone only (D9), never in the mirror:
    var pinned = false
    var sectionId: String?
    var rosterOrder: Int?
    /// When it was pinned here (room tiles keep that order).
    var pinnedAt: Double?
    /// Hidden from the Bots list here: it sits under Hidden, as a hidden bot does (UX study #254).
    var hidden = false
    /// Your sends no member took (`undeliveredSend`): entry id → the last failure's reason ("" = none known).
    var undelivered: [String: String] = [:]
    /// Entries deleted here (their mirror keys, newest last): a copy still in the mirror, or sent back by another
    /// device, is never taken in again, and the next publish leaves it out.
    var removed: [String] = []
    // Runtime only, never saved:
    var uid = GroupRuntimeID()
    var epoch = 0
    var running = false
    var turn: GroupTurnState?
    var stoppedEpoch: Int?
    /// [hosted] Pending approvals / retries / discards reported by `groups.state` (`driver_status.pending_actions`).
    var pendingActions: [HostedPendingAction] = []
    /// [hosted] Bounded discussion waiting on `groups.continue`.
    var pausedDiscussion: HostedRoomPause?
    /// [hosted] Routing modes offered by the room driver (`driver_status.routing_modes`).
    var routingModes: [String]?
    /// [hosted] Max continues offered by the room driver (`driver_status.max_continues`).
    var maxContinues: Int?
    /// [hosted] Whether the gateway broadcasts `groups.changed` for this room.
    var supportsChangeEvents = false

    enum CodingKeys: String, CodingKey {
        case name, roomId, log, watermarks, members, image, holdDetection, holds, heldMessages, sessions, stranded
        case syncRevision, omitted, extra, pinned, sectionId, rosterOrder, undelivered, pinnedAt, removed, asking, hidden, hosted, hostedContext, pausedDiscussion
    }

    init(name: String, roomId: String? = nil) {
        self.name = name
        self.roomId = roomId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        roomId = try c.decodeIfPresent(String.self, forKey: .roomId)
        log = (try? c.decodeIfPresent([GroupMessage].self, forKey: .log)) ?? []
        watermarks = (try? c.decodeIfPresent([String: Int].self, forKey: .watermarks)) ?? [:]
        members = (try? c.decodeIfPresent([GroupMember].self, forKey: .members)) ?? []
        image = try? c.decodeIfPresent(String.self, forKey: .image)
        holdDetection = (try? c.decodeIfPresent(Bool.self, forKey: .holdDetection)) ?? true
        holds = (try? c.decodeIfPresent([String: GroupHold].self, forKey: .holds)) ?? [:]
        heldMessages = (try? c.decodeIfPresent([String: [String]].self, forKey: .heldMessages)) ?? [:]
        sessions = (try? c.decodeIfPresent([String: String].self, forKey: .sessions)) ?? [:]
        stranded = (try? c.decodeIfPresent([String: GroupStranded].self, forKey: .stranded)) ?? [:]
        syncRevision = (try? c.decodeIfPresent(Int.self, forKey: .syncRevision)) ?? 0
        omitted = (try? c.decodeIfPresent(Int.self, forKey: .omitted)) ?? 0
        extra = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .extra)) ?? [:]
        pinned = (try? c.decodeIfPresent(Bool.self, forKey: .pinned)) ?? false
        sectionId = try? c.decodeIfPresent(String.self, forKey: .sectionId)
        rosterOrder = try? c.decodeIfPresent(Int.self, forKey: .rosterOrder)
        pinnedAt = try? c.decodeIfPresent(Double.self, forKey: .pinnedAt)
        hidden = (try? c.decodeIfPresent(Bool.self, forKey: .hidden)) ?? false
        undelivered = (try? c.decodeIfPresent([String: String].self, forKey: .undelivered)) ?? [:]
        removed = (try? c.decodeIfPresent([String].self, forKey: .removed)) ?? []
        asking = (try? c.decodeIfPresent([String: GroupAsking].self, forKey: .asking)) ?? [:]
        hosted = try? c.decodeIfPresent(HostedRoomRef.self, forKey: .hosted)
        hostedContext = try? c.decodeIfPresent(HostedRoomContext.self, forKey: .hostedContext)
        pausedDiscussion = try? c.decodeIfPresent(HostedRoomPause.self, forKey: .pausedDiscussion)
    }

    /// At launch: every turn the last run left unanswered becomes a late reply to collect (§6.7, stress R1).
    mutating func recoverInterruptedTurns() {
        for (member, turn) in asking {
            let anchor = turn.anchorId.flatMap { id in log.lastIndex { $0.id == id } } ?? (min(turn.anchorCount, log.count) - 1)
            watermarks[turn.markKey] = max(watermarks[turn.markKey] ?? 0, anchor + 1)
            if stranded[member] == nil { stranded[member] = GroupStranded(before: turn.before, thread: turn.thread, at: turn.at, stored: turn.stored) }
        }
        asking = [:]
    }

    var key: String { hosted.map { GroupKeys.hostedKey(owner: $0.owner, roomId: $0.roomId) } ?? GroupKeys.roomKey(roomId: roomId, name: name) }
    /// [hosted] Hermes runs this room on its gateway.
    var isHosted: Bool { hosted != nil }
    var lastAt: Double { log.last?.at ?? 0 }

    /// Stored log bounds (`HB/group-chat.ts:1410-1426`): each text at most 8,000 characters, the log trimmed from its
    /// head to 400 entries and 256,000 characters. Watermarks index the log, so they move with the trim.
    mutating func enforceBounds() {
        var dropped = 0
        if log.count > GroupLimits.logRetain { dropped = log.count - GroupLimits.logRetain }
        var chars = 0
        var keepFrom = log.count
        for index in stride(from: log.count - 1, through: dropped, by: -1) {
            chars += log[index].text.utf16.count
            if chars > GroupLimits.logRetainChars && index < log.count - 1 { break }
            keepFrom = index
        }
        dropped = max(dropped, min(keepFrom, max(0, log.count - 1)))
        guard dropped > 0 else { return }
        log.removeFirst(dropped)
        for (key, value) in watermarks { watermarks[key] = max(0, value - dropped) }
    }
}

nonisolated enum GroupLimits {
    static let maxMembers = 6, minMembers = 2
    static let maxRounds = 3, maxMessages = 10, maxContinuations = 2
    static let historyLimit = 200, historyChars = 32_000, historyLineChars = 8_000
    static let logRetain = 400, logRetainChars = 256_000
    static let nameMax = 64
    static let syncLog = 16, syncText = 1_200, syncBytes = 48_000, syncImage = 24_000, syncTombstones = 64
    static let activityMax = 50
    /// Deleted entries remembered per room (the mirror itself carries at most `syncLog` entries).
    static let removedMax = 64
    static let truncationMark = "… [truncated]"
}

/// One line of a room's Activity page (`HB/group-activity.ts`); runtime only.
nonisolated struct GroupActivityEvent: Hashable, Sendable {
    enum Kind: String, Sendable {
        case queued, working, replied, passed, timedOut = "timed-out", failed, cancelled, settled, capped, delivered, held, stopped
    }
    var kind: Kind
    /// The member's key ("" for "You" and the member-less lines).
    var member: String
    var detail: String?
    var at: Double
    var epoch: Int
    var thread: String?
}

/// A seated member as the engine and the screens use it: the roster's bot when it is there, else the saved descriptor.
nonisolated struct GroupSeat: Hashable, Sendable {
    var key: String
    /// Profile name.
    var name: String
    /// What the user reads ("Ivy").
    var display: String
    var handle: String
    var title: String?
    var friendly: [String] = []
    var previousNames: [String] = []
    var head: JSONValue?
    /// Lives on another gateway (D2): shown, never driven.
    var remote = false
    var remoteLabel: String?
    /// Missing from the roster (deleted, or the roster has not loaded).
    var missing = false
    var descriptor: GroupMember

    var canDrive: Bool { !remote && !missing }
}
