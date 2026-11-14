// [groups] The gateway mirror of rooms (docs/spec/3x-groups.md §5): `ui_meta["hermes-bots-groups"]` on the default
// profile, a version-3 envelope. A port of `HB/group-chat.ts:160-800` (build, size, normalise, merge). Pure.

import Foundation

/// A room as the mirror carries it.
nonisolated struct MirrorRoom: Equatable, Sendable {
    var name: String
    var roomId: String?
    var holdDetection = true
    var revision = 0
    var omitted = 0
    var members: [GroupMember] = []
    var image: String?
    var log: [GroupMessage] = []
    /// Keys this app does not know, written back as read.
    var extra: [String: JSONValue] = [:]

    var key: String { GroupKeys.roomKey(roomId: roomId, name: name) }
    var lastAt: Double { log.last?.at ?? 0 }
}

nonisolated struct GroupMirror: Equatable, Sendable {
    var rooms: [String: MirrorRoom] = [:]
    /// Tombstones: room key → revision.
    var deleted: [String: Int] = [:]
    var updatedAt: Double = 0
    /// The version read (the next write is always 3).
    var version = 3
}

nonisolated enum GroupSnapshot {
    static let metaKey = "hermes-bots-groups"
    private static let knownRoomKeys: Set<String> = ["name", "roomId", "holdDetection", "revision", "omitted", "members", "image", "log"]

    // MARK: Entry keys

    /// `id:<id>`, else the JSON of `[at, kind, name, source, thread or "legacy", text]`.
    static func entryKey(_ entry: GroupMessage) -> String {
        if let id = entry.id, !id.isEmpty { return "id:\(id)" }
        var thread = entry.threadKey
        if thread.hasPrefix("legacy-") { thread = "legacy" }
        return "[\(number(entry.at)),\"\(entry.from.kind.rawValue)\",\"\(entry.from.name)\",\"\(entry.from.source ?? "")\",\"\(thread)\",\"\(entry.text)\"]"
    }

    private static func number(_ n: Double) -> String {
        n.rounded() == n && abs(n) < 9.007e15 ? String(Int64(n)) : "\(n)"
    }

    // MARK: Reading

    private static func entry(_ raw: JSONValue) -> GroupMessage? {
        guard let object = raw.object, let text = object["text"]?.string, let from = object["from"]?.object,
              let kind = from["kind"]?.string.flatMap(GroupAuthor.Kind.init(rawValue:)) else { return nil }
        guard case .number(let at)? = object["at"], at.isFinite else { return nil }
        let name = from["name"]?.string ?? (kind == .user ? "You" : "")
        if kind == .member && name.isEmpty { return nil }
        return GroupMessage(id: object["id"]?.string.flatMap { $0.isEmpty ? nil : String($0.prefix(160)) }, at: at,
                            from: GroupAuthor(kind: kind, name: String(name.prefix(128)), source: from["source"]?.string,
                                              gateway: from["gateway"]?.string),
                            text: text, thread: object["thread"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                            truncated: object["truncated"]?.bool == true ? true : nil)
    }

    private static func room(_ raw: JSONValue, fallbackName: String?) -> MirrorRoom? {
        guard let object = raw.object else { return nil }
        let name = GroupKeys.cleanName(object["name"]?.string ?? fallbackName ?? "")
        guard !name.isEmpty else { return nil }
        // A log that is not a list is a broken room: skipped whole, never half-read (stress D1).
        if let log = object["log"], !log.isNull, log.array == nil { return nil }
        var room = MirrorRoom(name: name)
        room.roomId = object["roomId"]?.string.flatMap { $0.isEmpty ? nil : String($0.prefix(128)) }
        room.holdDetection = object["holdDetection"]?.bool ?? true
        room.revision = max(0, object["revision"]?.int ?? 0)
        room.omitted = max(0, object["omitted"]?.int ?? 0)
        room.members = (object["members"]?.array ?? []).compactMap { GroupMember(json: $0) }
        if let image = object["image"]?.string, !image.isEmpty, image.utf16.count <= GroupLimits.syncImage { room.image = image }
        var seen = Set<String>()
        room.log = (object["log"]?.array ?? []).compactMap(entry).filter { seen.insert(entryKey($0)).inserted }
        room.log = sorted(room.log)
        room.extra = object.filter { !knownRoomKeys.contains($0.key) }
        return room
    }

    /// `normalizeGroupChatSyncSnapshot`: any stored value → a version-3 view. Bad rooms and entries are skipped.
    static func parse(_ raw: JSONValue?) -> GroupMirror {
        var mirror = GroupMirror()
        guard let object = raw?.object else { return mirror }
        mirror.version = object["version"]?.int ?? 1
        mirror.updatedAt = object["updatedAt"]?.double ?? 0
        let legacy = mirror.version < 3
        for (key, value) in object["rooms"]?.object ?? [:] {
            guard var made = room(value, fallbackName: legacy ? key : nil) else { continue }
            if legacy { made.name = GroupKeys.cleanName(key); if made.name.isEmpty { continue } }
            mirror.rooms[made.key] = made
        }
        switch object["deleted"] {
        case .object(let deleted)?:
            for (key, value) in deleted {
                let revision = max(0, value.int ?? 0)
                mirror.deleted[legacy ? "name:\(key)" : key] = mirror.version == 1 ? 0 : revision
            }
        case .array(let names)?:
            for name in names.compactMap(\.string) { mirror.deleted["name:\(name)"] = 0 }
        default: break
        }
        return mirror
    }

    // MARK: Building

    static func sorted(_ log: [GroupMessage]) -> [GroupMessage] {
        log.enumerated().sorted { a, b in
            if a.element.at != b.element.at { return a.element.at < b.element.at }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// One room for the mirror: its last 16 entries, each text cut to 1,200.
    static func compact(_ room: GroupRoom) -> MirrorRoom {
        var out = MirrorRoom(name: room.name, roomId: room.roomId)
        out.holdDetection = room.holdDetection
        out.revision = room.syncRevision
        out.members = Array(room.members.prefix(GroupLimits.maxMembers))
        if let image = room.image, image.utf16.count <= GroupLimits.syncImage { out.image = image }
        out.log = room.log.suffix(GroupLimits.syncLog).map { entry in
            var copy = entry
            let cut = GroupPrompt.compact(entry.text, limit: GroupLimits.syncText)
            copy.text = cut.text
            if cut.truncated { copy.truncated = true }
            copy.from.gateway = nil
            return copy
        }
        out.omitted = max(room.omitted, room.log.count - out.log.count)
        out.extra = room.extra
        return out
    }

    /// `groupChatSyncSnapshot`: this device's rooms as a mirror (rooms with an empty log are left out).
    static func local(rooms: [GroupRoom], tombstones: [String: Int]) -> GroupMirror {
        var mirror = GroupMirror()
        // [hosted] A room Hermes runs lives on its gateway: never in the mirror.
        for room in rooms where !room.log.isEmpty && !room.isHosted { mirror.rooms[room.key] = compact(room) }
        mirror.deleted = tombstones
        return mirror
    }

    private static func json(_ entry: GroupMessage) -> JSONValue {
        var from: [String: JSONValue] = ["kind": .string(entry.from.kind.rawValue), "name": .string(String(entry.from.name.prefix(128)))]
        if let source = entry.from.source, !source.isEmpty { from["source"] = .string(source) }
        var object: [String: JSONValue] = ["from": .object(from), "text": .string(entry.text), "at": .number(entry.at)]
        if let id = entry.id, !id.isEmpty { object["id"] = .string(String(id.prefix(160))) }
        if let thread = entry.thread, !thread.isEmpty { object["thread"] = .string(thread) }
        if entry.truncated == true { object["truncated"] = .bool(true) }
        return .object(object)
    }

    static func json(_ room: MirrorRoom) -> JSONValue {
        var object = room.extra
        object["name"] = .string(String(room.name.prefix(GroupLimits.nameMax)))
        if let roomId = room.roomId, !roomId.isEmpty { object["roomId"] = .string(String(roomId.prefix(128))) }
        object["holdDetection"] = .bool(room.holdDetection)
        object["revision"] = .number(Double(room.revision))
        object["members"] = .array(room.members.prefix(GroupLimits.maxMembers).map(\.json))
        if let image = room.image, image.utf16.count <= GroupLimits.syncImage { object["image"] = .string(image) }
        object["log"] = .array(room.log.map(json))
        object["omitted"] = .number(Double(room.omitted))
        return .object(object)
    }

    /// A room's bytes without its log's entries (its `log` counted as an empty list).
    private static func frame(_ room: MirrorRoom) -> Int {
        var bare = room
        bare.log = []
        return pythonSize(json(bare))
    }

    /// Bytes the way Python's `json.dumps` writes it (ASCII-escaped, ", " and ": " separators), counted as the web
    /// does (`HB/group-chat.ts:194-214`): never lower than Python's own count.
    static func pythonSize(_ value: JSONValue) -> Int {
        switch value {
        case .null: return 4
        case .bool(let b): return b ? 4 : 5
        case .number(let n): return number(n).utf8.count
        case .string(let s): return stringSize(s)
        case .array(let a): return 2 + a.reduce(0) { $0 + pythonSize($1) } + max(0, a.count - 1) * 2
        case .object(let o):
            return 2 + o.reduce(0) { $0 + stringSize($1.key) + 2 + pythonSize($1.value) } + max(0, o.count - 1) * 2
        }
    }

    private static func stringSize(_ s: String) -> Int {
        var total = 2
        for unit in s.utf16 {
            switch unit {
            case 0x08, 0x09, 0x0A, 0x0C, 0x0D, 0x22, 0x5C, 0x2C, 0x3A: total += 2
            case 0..<0x20: total += 6
            case 0x20...0x7F: total += 1
            default: total += 6
            }
        }
        return total
    }

    /// `groupChatSyncEnvelope`: the version-3 envelope, at most 48,000 bytes. Rooms go in newest first; a room that
    /// does not fit loses its oldest entries (down to one), then its image, then its place.
    static func envelope(_ mirror: GroupMirror, now: Double, limit: Int = GroupLimits.syncBytes) -> (json: JSONValue, kept: GroupMirror, bytes: Int) {
        let tombstones = mirror.deleted.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(GroupLimits.syncTombstones)
        var deleted: [String: JSONValue] = [:]
        for (key, revision) in tombstones { deleted[key] = .number(Double(revision)) }
        var base: [String: JSONValue] = ["version": 3, "updatedAt": .number(now), "rooms": .object([:])]
        if !deleted.isEmpty { base["deleted"] = .object(deleted) }
        var total = pythonSize(.object(base))
        var rooms: [String: JSONValue] = [:]
        var kept = GroupMirror(rooms: [:], deleted: Dictionary(uniqueKeysWithValues: tombstones.map { ($0.key, $0.value) }), updatedAt: now, version: 3)
        let ranked = mirror.rooms.values.filter { !$0.log.isEmpty }.sorted { $0.lastAt != $1.lastAt ? $0.lastAt > $1.lastAt : $0.key < $1.key }
        for var room in ranked {
            if room.log.count > GroupLimits.syncLog {
                room.omitted += room.log.count - GroupLimits.syncLog
                room.log = Array(room.log.suffix(GroupLimits.syncLog))
            }
            let keySize = stringSize(room.key) + 2 + 2
            // A room's size is its frame (everything but the log's entries) plus its entries. Each is measured once and
            // the rest is arithmetic as entries go: writing the room again for every entry dropped cost 25 ms for 40 rooms.
            var sizes = room.log.map { pythonSize(json($0)) }
            var logSize = sizes.reduce(0, +) + max(0, sizes.count - 1) * 2
            var frameSize = frame(room)
            var size = frameSize + logSize + keySize
            var fits = total + size <= limit
            while !fits {
                if room.log.count > 1 {
                    let digits = number(Double(room.omitted)).utf8.count
                    room.log.removeFirst()
                    room.omitted += 1
                    logSize -= sizes.removeFirst() + 2
                    frameSize += number(Double(room.omitted)).utf8.count - digits
                } else if room.image != nil {
                    room.image = nil
                    frameSize = frame(room)
                } else { break }
                size = frameSize + logSize + keySize
                fits = total + size <= limit
            }
            guard fits else { continue }
            rooms[room.key] = json(room)
            kept.rooms[room.key] = room
            total += size
        }
        base["rooms"] = .object(rooms)
        return (.object(base), kept, total)
    }

    // MARK: Merging

    /// `mergeGroupChatSyncSnapshots`: the gateway's mirror and this device's, with the rooms this write changes or
    /// deletes stamped `writeRevision`. A room missing from one side is never deleted; only a tombstone deletes.
    static func merge(remote: GroupMirror, local: GroupMirror, changed: Set<String> = [], deleted: Set<String> = [],
                      removed: [String: Set<String>] = [:], writeRevision: Int) -> GroupMirror {
        var out = GroupMirror()
        for (key, revision) in remote.deleted { out.deleted[key] = max(out.deleted[key] ?? 0, revision) }
        for (key, revision) in local.deleted { out.deleted[key] = max(out.deleted[key] ?? 0, revision) }
        for key in deleted where !changed.contains(key) { out.deleted[key] = writeRevision }
        for key in Set(remote.rooms.keys).union(local.rooms.keys) {
            let theirs = remote.rooms[key], mine = local.rooms[key]
            guard var room = theirs ?? mine else { continue }
            if let theirs, let mine {
                var byKey: [String: GroupMessage] = [:]
                var order: [String] = []
                let gone = removed[key] ?? []
                for entry in theirs.log + mine.log {
                    let entryKey = entryKey(entry)
                    if gone.contains(entryKey) { continue }   // deleted on this device: not written back
                    if byKey[entryKey] == nil { order.append(entryKey) }
                    // The later (local) twin wins, unless it is the cut one and the other is whole.
                    if let held = byKey[entryKey], held.truncated != true, entry.truncated == true { continue }
                    byKey[entryKey] = entry
                }
                let localRevision = changed.contains(key) ? writeRevision : mine.revision
                let identity = localRevision >= theirs.revision ? mine : theirs
                room = identity
                if localRevision == theirs.revision {
                    var members = mine.members
                    let have = Set(members.map(\.key))
                    members += theirs.members.filter { !have.contains($0.key) }
                    room.members = members
                    room.image = mine.image ?? theirs.image
                }
                room.extra = theirs.extra.merging(mine.extra) { _, new in new }
                room.log = sorted(order.compactMap { byKey[$0] }.sorted { $0.at != $1.at ? $0.at < $1.at : entryKey($0) < entryKey($1) })
                room.revision = max(localRevision, theirs.revision)
                room.omitted = max(theirs.omitted, mine.omitted)
            } else if mine != nil, changed.contains(key) {
                room.revision = writeRevision
            }
            out.rooms[key] = room
        }
        for (key, revision) in out.deleted {
            guard let room = out.rooms[key] else { continue }
            if key.hasPrefix("id:") || revision >= room.revision { out.rooms[key] = nil } else { out.deleted[key] = nil }
        }
        return out
    }

    // MARK: Into this device's rooms

    struct Applied: Sendable {
        var rooms: [GroupRoom]
        /// Keys (before the merge) of rooms a tombstone removed.
        var removed: [GroupRoom] = []
        /// Old key → new key for rooms that were re-keyed (a `name:` room gained its `roomId`).
        var rekeyed: [String: String] = [:]
        var changed = false
    }

    /// The mirror merged into the device's full records: logs unioned in place (a whole local entry wins over its cut
    /// twin), identity by revision, tombstones applied. Rooms the mirror does not carry are left alone.
    static func apply(_ mirror: GroupMirror, to rooms: [GroupRoom], tombstones: [String: Int] = [:],
                      protect: Set<String> = []) -> Applied {
        var out = Applied(rooms: rooms)
        var deleted = mirror.deleted
        for (key, revision) in tombstones { deleted[key] = max(deleted[key] ?? 0, revision) }
        for (key, theirs) in mirror.rooms.sorted(by: { $0.key < $1.key }) {
            if let tombstone = deleted[key], key.hasPrefix("id:") || tombstone >= theirs.revision { continue }
            var index = out.rooms.firstIndex { $0.key == key }
            if index == nil, theirs.roomId != nil,
               let named = out.rooms.firstIndex(where: { $0.roomId == nil && $0.name == theirs.name }) {
                // The same room gained a roomId elsewhere: re-key it here, never show it twice.
                out.rekeyed[out.rooms[named].key] = key
                out.rooms[named].roomId = theirs.roomId
                index = named
                out.changed = true
            }
            guard let at = index else {
                var room = GroupRoom(name: theirs.name, roomId: theirs.roomId)
                room.log = theirs.log
                room.members = theirs.members
                room.image = theirs.image
                room.holdDetection = theirs.holdDetection
                room.syncRevision = theirs.revision
                room.omitted = theirs.omitted
                room.extra = theirs.extra
                out.rooms.append(room)
                out.changed = true
                continue
            }
            var room = out.rooms[at]
            let before = room
            // A room with a change of its own waiting to be published keeps its identity until that write.
            if theirs.revision > room.syncRevision, !protect.contains(key) {
                room.name = theirs.name
                if !theirs.members.isEmpty { room.members = theirs.members }
                room.image = theirs.image
                room.holdDetection = theirs.holdDetection
                room.syncRevision = theirs.revision
            }
            room.extra = room.extra.merging(theirs.extra) { old, _ in old }
            var known = Set<String>()
            for entry in room.log {
                known.insert(entryKey(entry))
                if entry.id == nil || entry.id?.isEmpty == true {
                    var cut = entry
                    cut.text = GroupPrompt.compact(entry.text, limit: GroupLimits.syncText).text
                    known.insert(entryKey(cut))
                }
            }
            known.formUnion(room.removed)   // deleted here: the mirror's copy is not taken in again
            let fresh = theirs.log.filter { known.insert(entryKey($0)).inserted }
            if !fresh.isEmpty {
                // In place: new entries go where their time puts them; nothing already on screen is reordered.
                if let last = room.log.last, fresh.allSatisfy({ $0.at >= last.at }) {
                    room.log += sorted(fresh)
                } else {
                    let merged = sorted(room.log + fresh)
                    // Watermarks index the log: an entry merged in before a mark moves the mark past it.
                    for (markKey, mark) in room.watermarks {
                        let seen = Set(room.log.prefix(mark).map(entryKey))
                        var next = 0
                        for (offset, entry) in merged.enumerated() where seen.contains(entryKey(entry)) { next = offset + 1 }
                        room.watermarks[markKey] = next
                    }
                    room.log = merged
                }
            }
            // `omitted` here = entries missing before this device's first one: only a log that came from the mirror has any.
            if before.log.isEmpty { room.omitted = theirs.omitted }
            room.enforceBounds()
            if room != before { out.rooms[at] = room; out.changed = true }
        }
        var keep: [GroupRoom] = []
        for room in out.rooms {
            if let tombstone = deleted[room.key], room.key.hasPrefix("id:") || tombstone >= room.syncRevision {
                out.removed.append(room)
                out.changed = true
            } else {
                keep.append(room)
            }
        }
        out.rooms = keep
        return out
    }
}
