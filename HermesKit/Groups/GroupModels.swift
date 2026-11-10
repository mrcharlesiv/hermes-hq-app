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

nonisolated struct GroupRoom: Codable, Sendable, Equatable {
    var name: String
    var roomId: String?
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

    enum CodingKeys: String, CodingKey {
        case name, roomId, log, watermarks, members, image, holdDetection, holds, heldMessages, sessions, stranded
        case syncRevision, omitted, extra, pinned, sectionId, rosterOrder, undelivered, pinnedAt, removed, asking, hidden
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

    var key: String { GroupKeys.roomKey(roomId: roomId, name: name) }
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
