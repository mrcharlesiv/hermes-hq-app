// [groups] The rooms of one signed-in account (docs/spec/3x-groups.md §3.3): the full log on the device, the marks
// that never leave it (unread, pin, section, order, tombstones), who is seated right now, and the membership writes.
// The gateway mirror is GroupSync's; the rounds are GroupRounds'.

import Foundation

/// A room as the Bots list draws it.
nonisolated struct GroupRowModel: Hashable, Sendable, Identifiable {
    struct Face: Hashable, Sendable {
        var profile: String
        var head: JSONValue?
    }
    var id: String
    var name: String
    var image: String?
    var faces: [Face]
    var line: String
    var tone: GroupRowWords.Tone
    var time: Date?
    var unread: Bool
    var pinned: Bool
    var muted: Bool
    var memberCount: Int
    var running: Bool
    var sectionId: String?
    var order: Int?
    var pinnedAt: Double?
    var lastAt: Double
    var search: String
    var online: Bool
    /// Hidden from the Bots list on this iPhone (UX study #254).
    var hidden = false
}

@MainActor final class GroupStore {
    /// What the account's marks file holds (kind "groupmarks").
    nonisolated struct Marks: Codable, Sendable, Equatable {
        var unread: [String] = []
        var tombstones: [String: Int] = [:]
        /// Names of rooms deleted here whose bots may still carry them in `groups` (never adopted back).
        var deletedNames: [String] = []
        /// Names whose Delete Group Chat was started on this device and whose `groups` writes are not known to be
        /// finished (optional: files written before this field have none). Finished after a relaunch (`resumeDeletes`).
        var owedDeletes: [String]?
    }

    static let roomsKind = "groups"
    static let marksKind = "groupmarks"

    let account: GatewayAccount
    private let roomsURL: URL
    private let marksURL: URL
    weak var bots: BotStore?
    var sync: GroupSync?
    var isOnline: () -> Bool = { true }
    /// The mute of a room (key `room:<roomKey>`), and its removal / move (App wires `BotMuteCenter`).
    var isMuted: (String) -> Bool = { _ in false }
    var moveMute: (_ from: String, _ to: String?) -> Void = { _, _ in }
    /// A room left this device (deleted here or by a tombstone).
    var onRoomRemoved: ((GroupRoom) -> Void)?

    private(set) var rooms: [GroupRoom] = []
    private(set) var marks = Marks()
    private(set) var activity: [String: [GroupActivityEvent]] = [:]
    private var observers: [UUID: () -> Void] = [:]
    private var saveTask: Task<Void, Never>?
    /// Names a create or rename is writing right now: the roster's `groups` must not adopt them as new rooms.
    private var pendingNames: Set<String> = []
    private var lastGroupsSignature: [String] = []
    /// The account left (`close()`): nothing is changed or written any more, whoever still holds this store.
    private(set) var isClosed = false
    /// Deletes this device started in an earlier run and never finished (read from the marks file at launch).
    private var resumable: Set<String> = []
    private var resuming = false
    private var resumeTries = 0
    static let maxResumeTries = 3

    init(account: GatewayAccount, directory: URL, bots: BotStore?) {
        self.account = account
        self.bots = bots
        roomsURL = RosterDisk.url(directory, Self.roomsKind, account)
        marksURL = RosterDisk.url(directory, Self.marksKind, account)
        rooms = RosterDisk.read([GroupRoom].self, from: roomsURL) ?? []
        marks = RosterDisk.read(Marks.self, from: marksURL) ?? Marks()
        resumable = Set(marks.owedDeletes ?? [])
        // A turn still open in the file was cut off by the app closing: its reply is collected as a late one.
        if rooms.contains(where: { !$0.asking.isEmpty }) {
            for index in rooms.indices { rooms[index].recoverInterruptedTurns() }
            save()
        }
    }

    static func removeFiles(directory: URL, account: GatewayAccount) {
        RosterDiskWriter.shared.remove(RosterDisk.url(directory, roomsKind, account))
        RosterDiskWriter.shared.remove(RosterDisk.url(directory, marksKind, account))
    }

    /// The account is leaving: the last state is queued for the disk, then this store never writes again. A round
    /// still unwinding (or anything else that kept a reference) cannot bring a signed-out account's file back.
    func close() {
        guard !isClosed else { return }
        saveNow()
        isClosed = true
        observers = [:]
    }

    /// Every room's round ends (the engine is shutting down): the epoch moves on, nobody is on turn.
    func endAllRounds() {
        for index in rooms.indices {
            rooms[index].epoch += 1
            rooms[index].running = false
            rooms[index].turn = nil
        }
    }

    // MARK: Reads

    func room(_ key: String) -> GroupRoom? { rooms.first { $0.key == key } }
    func room(uid: UUID) -> GroupRoom? { rooms.first { $0.uid.value == uid } }
    func key(_ uid: UUID) -> String? { room(uid: uid)?.key }
    func isUnread(_ key: String) -> Bool { marks.unread.contains(key) }
    var tombstones: [String: Int] { marks.tombstones }
    var roomNames: Set<String> { Set(rooms.map(\.name)) }

    @discardableResult func observe(_ block: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = block
        return id
    }

    func stopObserving(_ id: UUID) { observers[id] = nil }

    private func notify() { for block in observers.values { block() } }

    /// Who is in a room right now (`groupChatMemberBots`, §3.5): the roster's bots that name it, in roster order;
    /// the saved descriptors while the roster has not loaded; the saved members of another gateway.
    func seated(_ room: GroupRoom) -> [GroupSeat] {
        var seats: [GroupSeat] = []
        let saved = Dictionary(room.members.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let profiles = bots?.profiles ?? []
        let loaded = bots.map { $0.phase != .none } ?? false
        if loaded, let bots {
            for profile in profiles where GroupKeys.groups(of: bots.currentMeta(profile.name)).contains(room.name) {
                let bot = bots.bot(named: profile.name)
                let metaTitle = bots.currentMeta(profile.name)["title"]?.string.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                let handle = GroupMentions.handle(name: profile.name, saved: saved[profile.name]?.handle)
                var descriptor = saved[profile.name].flatMap { $0.sourceScoped ? nil : $0 } ?? GroupMember(name: profile.name, handle: handle)
                descriptor.handle = handle
                seats.append(GroupSeat(key: profile.name, name: profile.name,
                                       display: bot?.name ?? metaTitle ?? profile.displayName ?? profile.name, handle: handle,
                                       title: metaTitle ?? profile.displayName,
                                       friendly: [metaTitle, profile.title, profile.displayName].compactMap { $0 },
                                       previousNames: (profile.raw["previous_names"]?.array ?? []).compactMap(\.string),
                                       head: bot?.head ?? profile.uiMeta["dispatch-head"], descriptor: descriptor))
            }
        }
        let seatedNames = Set(seats.map(\.name))
        for member in room.members {
            if member.sourceScoped {
                seats.append(GroupSeat(key: member.key, name: member.name, display: member.title ?? member.name,
                                       handle: member.handle ?? member.name, title: member.title, remote: true,
                                       remoteLabel: member.connectionLabel, descriptor: member))
            } else if !seatedNames.contains(member.name), !loaded || profiles.first(where: { $0.name == member.name }) == nil {
                // Not loaded yet, or gone from the roster: shown, never driven.
                seats.append(GroupSeat(key: member.key, name: member.name, display: member.title ?? member.name,
                                       handle: GroupMentions.handle(name: member.name, saved: member.handle), title: member.title,
                                       missing: true, descriptor: member))
            }
        }
        return seats
    }

    /// Display names by profile name (for previews, the prompt's lines and Activity).
    func labels(_ seats: [GroupSeat]) -> [String: String] {
        var out = Dictionary(seats.map { ($0.name, $0.display) }, uniquingKeysWith: { a, _ in a })
        for bot in bots?.bots ?? [] where out[bot.id] == nil { out[bot.id] = bot.name }
        return out
    }

    func rows() -> [GroupRowModel] {
        let online = isOnline()
        return rooms.map { room in
            let seats = seated(room)
            let labels = labels(seats)
            let driven = seats.filter { !$0.remote }
            let replying = room.running ? (room.turn.map { turn in [labels[turn.name] ?? turn.name] } ?? []) : []
            let line = GroupRowWords.secondLine(waitingOnUser: room.running && room.turn?.waitingOnUser == true, replying: replying,
                                                available: driven.filter { !$0.missing }.count, driven: driven.count,
                                                offline: !online, last: room.log.last, labels: labels, memberCount: seats.count)
            return GroupRowModel(id: room.key, name: room.name, image: room.image,
                                 faces: seats.prefix(3).map { GroupRowModel.Face(profile: $0.name, head: $0.head) },
                                 line: line.text, tone: line.tone,
                                 time: room.log.last.map { Date(timeIntervalSince1970: $0.at / 1000) },
                                 unread: marks.unread.contains(room.key), pinned: room.pinned, muted: isMuted(GroupKeys.muteKey(room.key)),
                                 memberCount: seats.count, running: room.running, sectionId: room.sectionId, order: room.rosterOrder,
                                 pinnedAt: room.pinnedAt, lastAt: room.lastAt,
                                 search: ([room.name] + seats.map(\.display)).joined(separator: " ").lowercased(), online: online,
                                 hidden: room.hidden)
        }
    }

    /// The rooms a bot is in (Bot Info's Group Chats, Add to Group Chat…).
    func rooms(of profile: String) -> [GroupRoom] {
        guard let bots else { return [] }
        let names = Set(GroupKeys.groups(of: bots.currentMeta(profile)))
        return rooms.filter { names.contains($0.name) }
    }

    func activity(for key: String) -> [GroupActivityEvent] {
        guard let room = room(key) else { return [] }
        return (activity[key] ?? []).filter { $0.epoch == room.epoch }
    }

    // MARK: Mutations

    /// One write at most 250 ms after the first change it carries: a later change never pushes a waiting write further
    /// away (a round changes the room many times a second, and the app can be closed at any moment).
    private func save() {
        guard !isClosed, saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.saveNow()
        }
    }

    /// Queues the write now (the writer encodes and writes off the main thread, at its own pace). Never waits: the
    /// app flushes the writer inside its background task when it leaves the screen (`AppModel.appDidEnterBackground`).
    func saveNow(urgent: Bool = false) {
        saveTask?.cancel()
        saveTask = nil
        guard !isClosed else { return }
        RosterDisk.write(rooms, to: roomsURL, urgent: urgent)
        RosterDisk.write(marks, to: marksURL, urgent: urgent)
    }

    /// The one mutation path: saves, notifies observers, and schedules a mirror publish unless `sync` is false.
    /// `now`: the write is queued at once instead of after the 250 ms wait (your own send, the turn a member is on),
    /// so the time in which closing the app could lose it is as short as the writer allows. It never blocks the caller.
    func update(_ key: String, sync publish: Bool = true, now: Bool = false, _ mutate: (inout GroupRoom) -> Void) {
        guard !isClosed, let index = rooms.firstIndex(where: { $0.key == key }) else { return }
        let before = rooms[index]
        mutate(&rooms[index])
        rooms[index].enforceBounds()
        guard rooms[index] != before else { return }
        let after = rooms[index].key
        if after != key { moveMarks(from: key, to: after) }
        if now { saveNow(urgent: true) } else { save() }
        notify()
        if publish { sync?.schedule(changed: after) }
    }

    /// Runtime fields only (running, turn): nothing to save or publish.
    func setRuntime(_ key: String, _ mutate: (inout GroupRoom) -> Void) {
        guard !isClosed, let index = rooms.firstIndex(where: { $0.key == key }) else { return }
        let before = rooms[index]
        mutate(&rooms[index])
        if rooms[index] != before { notify() }
    }

    func append(_ message: GroupMessage, to key: String) {
        var entry = message
        entry.text = GroupPrompt.compact(entry.text, limit: GroupLimits.historyLineChars).text
        update(key) { $0.log.append(entry) }
    }

    func record(_ kind: GroupActivityEvent.Kind, room key: String, member: String = "", detail: String? = nil, thread: String? = nil) {
        guard !isClosed, let room = room(key) else { return }
        var list = activity[key] ?? []
        list.append(GroupActivityEvent(kind: kind, member: member, detail: detail, at: Date().timeIntervalSince1970 * 1000,
                                       epoch: room.epoch, thread: thread))
        if list.count > GroupLimits.activityMax { list.removeFirst(list.count - GroupLimits.activityMax) }
        activity[key] = list
        notify()
    }

    func setPinned(_ key: String, _ on: Bool) {
        // DECISION: room tiles follow the bots' tiles, newest pin last; they do not join `BotDeviceState.pinOrder`
        // (every reader of that list expects profile names).
        AppLog.trace("groups", "\(on ? "pin" : "unpin") \(AppLog.tag(key))")
        update(key, sync: false) { room in
            room.pinned = on
            room.pinnedAt = on ? Date().timeIntervalSince1970 : nil
        }
    }

    func setSection(_ key: String, _ sectionId: String?) { update(key, sync: false) { $0.sectionId = sectionId } }

    /// UX study #254: Hide (this iPhone only, as pins and sections): the room leaves the list for Hidden; a hidden room
    /// is never a tile, so its pin goes too. Undo hands the pin's place back (`restoringPin`, the old `pinnedAt`).
    func setHidden(_ key: String, _ on: Bool, restoringPin pinnedAt: Double? = nil) {
        AppLog.trace("groups", "\(on ? "hide" : "unhide") \(AppLog.tag(key))")
        update(key, sync: false) { room in
            room.hidden = on
            if on { room.pinned = false; room.pinnedAt = nil }
            else if let pinnedAt { room.pinned = true; room.pinnedAt = pinnedAt }
        }
    }

    func setUnread(_ key: String, _ on: Bool) {
        guard !isClosed, marks.unread.contains(key) != on, room(key) != nil else { return }
        if on { marks.unread.append(key) } else { marks.unread.removeAll { $0 == key } }
        AppLog.trace("groups", "mark \(AppLog.tag(key)) \(on ? "unread" : "read")")
        save()
        notify()
    }

    func setImage(_ key: String, _ image: String?) { update(key) { $0.image = image } }
    func setHoldDetection(_ key: String, _ on: Bool) { update(key) { $0.holdDetection = on } }

    private func moveMarks(from old: String, to new: String?) {
        if let at = marks.unread.firstIndex(of: old) {
            marks.unread.remove(at: at)
            if let new, !marks.unread.contains(new) { marks.unread.append(new) }
        }
        moveMute(GroupKeys.muteKey(old), new.map(GroupKeys.muteKey))
        if let list = activity.removeValue(forKey: old), let new { activity[new] = list }
    }

    // MARK: The gateway's side

    /// A fresh roster arrived: rooms known only from a bot's `groups` become records, then the mirror is merged in.
    func rosterChanged() {
        guard !isClosed, let bots, bots.phase != .none else { return }
        // The mirror first: a room renamed elsewhere must take its new name before `groups` is read for new rooms.
        sync?.pulled()
        var names: [String] = []
        for profile in bots.profiles {
            for name in GroupKeys.groups(of: bots.currentMeta(profile.name)) where !names.contains(name) { names.append(name) }
        }
        var changed = false
        var added = 0
        if names != lastGroupsSignature {
            lastGroupsSignature = names
            let known = roomNames
            for name in names where !known.contains(name) && !pendingNames.contains(name) && !marks.deletedNames.contains(name) {
                let clean = GroupKeys.cleanName(name)
                guard clean == name, !clean.isEmpty, marks.tombstones["name:\(name)"] == nil else { continue }
                rooms.append(GroupRoom(name: name))
                changed = true
                added += 1
            }
            // A name no bot carries any more has finished its deletion.
            let before = marks.deletedNames
            marks.deletedNames.removeAll { !names.contains($0) }
            if marks.deletedNames != before { changed = true }
        }
        // An owed delete no bot carries any more is finished (checked on every roster, not only a changed one).
        if let owed = marks.owedDeletes, owed.contains(where: { !names.contains($0) }) {
            let left = owed.filter(names.contains)
            marks.owedDeletes = left.isEmpty ? nil : left
            changed = true
        }
        if changed {
            AppLog.trace("groups", "roster changed: \(added) rooms discovered from bots' groups, \(rooms.count) known")
            save(); notify()
        }
        resumeDeletes(carried: names)
    }

    /// A Delete Group Chat cut off by the app closing (§7.1, stress R2): its bots still name the room. The `groups`
    /// writes are made now, quietly; a failure is tried again on a later roster, three times a launch at most.
    private func resumeDeletes(carried names: [String]) {
        resumable.formIntersection(marks.owedDeletes ?? [])
        let owed = resumable.filter { names.contains($0) && !roomNames.contains($0) }.sorted()
        guard !owed.isEmpty, !resuming, resumeTries < Self.maxResumeTries, isOnline(), let bots, bots.phase >= .slim else { return }
        resuming = true
        resumeTries += 1
        AppLog.trace("groups", "resuming \(owed.count) delete(s) cut off by a close, attempt \(resumeTries)")
        Task { [weak self] in
            for name in owed {
                guard let self, !self.isClosed else { return }
                try? await self.finishDelete(name: name)
            }
            self?.resuming = false
        }
    }

    private func settleOwed(_ name: String) {
        guard let owed = marks.owedDeletes, owed.contains(name) else { return }
        let left = owed.filter { $0 != name }
        marks.owedDeletes = left.isEmpty ? nil : left
        resumable.remove(name)
        save()
    }

    /// The mirror merged into the device's rooms (GroupSync, after a pull or a confirmed publish).
    func adopt(_ applied: GroupSnapshot.Applied) {
        guard !isClosed, applied.changed else { return }
        AppLog.trace("groups", "mirror adopted: \(applied.rooms.count) rooms, \(applied.removed.count) removed, \(applied.rekeyed.count) rekeyed")
        for (old, new) in applied.rekeyed { moveMarks(from: old, to: new) }
        var next = applied.rooms
        // Runtime fields ride along (apply keeps the struct), nothing to restore.
        for removed in applied.removed {
            moveMarks(from: removed.key, to: nil)
            activity[removed.key] = nil
            if !marks.deletedNames.contains(removed.name) { marks.deletedNames.append(removed.name) }
        }
        // A deleted name that the mirror brought back as a live room is live again.
        let live = Set(next.map(\.name))
        marks.deletedNames.removeAll { live.contains($0) && !applied.removed.map(\.name).contains($0) }
        for index in next.indices { next[index].enforceBounds() }
        rooms = next
        save()
        notify()
        for removed in applied.removed { onRoomRemoved?(removed) }
    }

    func stamp(revision: Int, for keys: Set<String>) {
        guard !isClosed else { return }
        for index in rooms.indices where keys.contains(rooms[index].key) { rooms[index].syncRevision = max(rooms[index].syncRevision, revision) }
        save()
    }

    func adoptTombstones(_ deleted: [String: Int]) {
        guard !isClosed else { return }
        var changed = false
        for (key, revision) in deleted where (marks.tombstones[key] ?? -1) < revision { marks.tombstones[key] = revision; changed = true }
        if marks.tombstones.count > GroupLimits.syncTombstones * 2 {
            let keep = marks.tombstones.sorted { $0.value > $1.value }.prefix(GroupLimits.syncTombstones)
            marks.tombstones = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if changed { save() }
    }

    // MARK: Membership writes (§4.3)

    private func write(_ profile: String, title: String, _ change: @escaping @Sendable ([String: JSONValue]) -> [String]?) async throws {
        guard let bots else { throw BotWriteError(title: title, reason: "Not signed in.") }
        _ = try await bots.writeBotMeta(profile, failureTitle: title, patch: { meta in change(meta).map(GroupKeys.patch) })
    }

    private func failure(_ error: Error, title: String) -> BotWriteError {
        if var known = error as? BotWriteError { known.title = title; return known }
        return BotWriteError(title: title, reason: BotWriteOutcome.reason(error), detail: "\(error)")
    }

    private func profilesNaming(_ name: String) -> [String] {
        guard let bots else { return [] }
        return bots.profiles.map(\.name).filter { GroupKeys.groups(of: bots.currentMeta($0)).contains(name) }
    }

    private func descriptors(_ names: [String], keeping saved: [GroupMember]) -> [GroupMember] {
        let old = Dictionary(saved.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let order = bots?.profiles.map(\.name) ?? names
        let local = order.filter(names.contains).map { name -> GroupMember in
            var member = old[name].flatMap { $0.sourceScoped ? nil : $0 } ?? GroupMember(name: name)
            member.handle = GroupMentions.handle(name: name, saved: member.handle)
            return member
        }
        return local + saved.filter(\.sourceScoped)
    }

    /// New Group Chat (§7.5): the name made unique, a new room id, `groups` written on each bot in roster order.
    /// A failed write undoes the ones already made and throws `Couldn’t Create <name>`.
    func create(name raw: String, members: [String], image: String?) async throws -> String {
        guard let bots else { throw BotWriteError(title: "Couldn’t Create Group Chat", reason: "Not signed in.") }
        var taken = roomNames
        for profile in bots.profiles { taken.formUnion(GroupKeys.groups(of: bots.currentMeta(profile.name))) }
        let name = GroupKeys.uniqueName(raw, taken: taken)
        let title = "Couldn’t Create \(name)"
        var room = GroupRoom(name: name, roomId: GroupKeys.newRoomId())
        let ordered = bots.profiles.map(\.name).filter(members.contains)
        room.members = descriptors(ordered, keeping: [])
        room.image = image
        pendingNames.insert(name)
        defer { pendingNames.remove(name) }
        AppLog.trace("groups", "create \(AppLog.tag(room.key)): started, \(ordered.count) members")
        var done: [String] = []
        do {
            for profile in ordered {
                try await write(profile, title: title) { GroupKeys.membership($0, adding: name) }
                done.append(profile)
            }
        } catch {
            AppLog.note("groups", "create \(AppLog.tag(room.key)): failed after \(done.count) of \(ordered.count) members, \(SessionActionText.reason(error))")
            for profile in done { try? await write(profile, title: title) { GroupKeys.membership($0, removing: name) } }
            throw failure(error, title: title)
        }
        marks.deletedNames.removeAll { $0 == name }
        settleOwed(name)
        rooms.removeAll { $0.name == name && $0.roomId == nil }
        rooms.append(room)
        saveNow()
        notify()
        AppLog.trace("groups", "create \(AppLog.tag(room.key)): succeeded")
        return room.key
    }

    /// Rename (§7.2): the name rewritten in every seated bot's `groups`, the room re-keyed only when it had no id.
    func rename(_ key: String, to raw: String) async throws {
        guard let room = room(key) else { return }
        let name = GroupKeys.cleanName(raw)
        guard !name.isEmpty, name != room.name else { return }
        var taken = roomNames
        if let bots { for profile in bots.profiles { taken.formUnion(GroupKeys.groups(of: bots.currentMeta(profile.name))) } }
        if taken.contains(name) { throw GroupNameTaken(name: name) }
        let title = "Couldn’t Rename \(room.name)"
        let old = room.name
        pendingNames.insert(name)
        defer { pendingNames.remove(name) }
        AppLog.trace("groups", "rename \(AppLog.tag(key)): started")
        var done: [String] = []
        do {
            for profile in profilesNaming(old) {
                try await write(profile, title: title) { GroupKeys.membership($0, renaming: old, to: name) }
                done.append(profile)
            }
        } catch {
            AppLog.note("groups", "rename \(AppLog.tag(key)): failed after \(done.count) members, \(SessionActionText.reason(error))")
            for profile in done { try? await write(profile, title: title) { GroupKeys.membership($0, renaming: name, to: old) } }
            throw failure(error, title: title)
        }
        AppLog.trace("groups", "rename \(AppLog.tag(key)): succeeded")
        let hadId = room.roomId != nil
        update(key) { room in
            room.name = name
            // A room without an id gets one on its first rename here, so it is not read elsewhere as delete-and-create.
            if room.roomId == nil { room.roomId = GroupKeys.newRoomId() }
            room.syncRevision += 1
        }
        if !hadId {
            marks.tombstones[key] = (sync?.remoteRevision ?? 0) + 1
            save()
            sync?.schedule(deleted: key)
        }
    }

    /// Add or Remove Bots… (§7.5 edit mode): the `groups` change of each bot added or removed, then the descriptors.
    func setMembers(_ key: String, _ names: [String]) async throws {
        guard let room = room(key) else { return }
        let title = "Couldn’t Change \(room.name)’s Bots"
        let current = Set(profilesNaming(room.name))
        let wanted = Set(names)
        let roomName = room.name
        AppLog.trace("groups", "set members \(AppLog.tag(key)): started, \(current.count) -> \(wanted.count)")
        do {
            for profile in (bots?.profiles.map(\.name) ?? []) {
                if wanted.contains(profile), !current.contains(profile) {
                    try await write(profile, title: title) { GroupKeys.membership($0, adding: roomName) }
                } else if !wanted.contains(profile), current.contains(profile) {
                    try await write(profile, title: title) { GroupKeys.membership($0, removing: roomName) }
                }
            }
        } catch {
            AppLog.note("groups", "set members \(AppLog.tag(key)): failed, \(SessionActionText.reason(error))")
            refreshDescriptors(key)
            throw failure(error, title: title)
        }
        update(key) { room in
            room.members = self.descriptors(names, keeping: room.members)
            room.syncRevision += 1
        }
        AppLog.trace("groups", "set members \(AppLog.tag(key)): succeeded")
    }

    /// One bot joins or leaves one room (Add to Group Chat…, §7.7).
    func setMembership(profile: String, room key: String, member: Bool, botName: String) async throws {
        guard let room = room(key) else { return }
        let title = "Couldn’t Change \(botName)’s Group Chats"
        let roomName = room.name
        do {
            try await write(profile, title: title) { meta in
                member ? GroupKeys.membership(meta, adding: roomName) : GroupKeys.membership(meta, removing: roomName)
            }
        } catch {
            AppLog.note("groups", "set membership \(AppLog.tag(key)) (\(member ? "add" : "remove")): failed, \(SessionActionText.reason(error))")
            throw failure(error, title: title)
        }
        AppLog.trace("groups", "set membership \(AppLog.tag(key)) (\(member ? "add" : "remove")): succeeded")
        refreshDescriptors(key, bump: true)
    }

    /// Delete Bot made here: the bot's saved seat leaves every room it was in, and the rooms are published, as Remove
    /// Bots does (its `groups` went with its profile). Without this the room kept an empty seat and its row read
    /// "1 of 2 available" in orange (audit 05-16). Rooms of another gateway's members are not touched.
    func forgetMember(_ profile: String) {
        for room in rooms where room.members.contains(where: { $0.name == profile && !$0.sourceScoped }) {
            AppLog.trace("groups", "forget deleted member in \(AppLog.tag(room.key))")
            update(room.key) { room in
                room.members.removeAll { $0.name == profile && !$0.sourceScoped }
                room.syncRevision += 1
            }
        }
    }

    /// Create & join (§7.7): a room named so with this bot alone.
    func createSolo(name raw: String, profile: String, botName: String) async throws -> String {
        let name = GroupKeys.cleanName(raw)
        var taken = roomNames
        if let bots { for row in bots.profiles { taken.formUnion(GroupKeys.groups(of: bots.currentMeta(row.name))) } }
        if name.isEmpty || taken.contains(name) { throw GroupNameTaken(name: name) }
        do { return try await create(name: name, members: [profile], image: nil) }
        catch { throw failure(error, title: "Couldn’t Change \(botName)’s Group Chats") }
    }

    /// The saved descriptors follow who is seated (after a membership change, and on every send).
    func refreshDescriptors(_ key: String, bump: Bool = false) {
        guard let room = room(key), let bots, bots.phase != .none else { return }
        let names = profilesNaming(room.name)
        let next = descriptors(names, keeping: room.members)
        guard next != room.members || bump else { return }
        update(key, sync: bump || !room.log.isEmpty) { room in
            room.members = next
            if bump { room.syncRevision += 1 }
        }
    }

    /// Delete Group Chat (§7.1): the tombstone first, the room and its marks gone at once, then the gateway writes.
    /// Throws `Couldn’t Delete <name>` when a write failed; the room stays gone and `finishDelete` retries the writes.
    func delete(_ key: String) async throws {
        guard let room = room(key) else { return }
        AppLog.trace("groups", "delete \(AppLog.tag(key)): started")
        marks.tombstones[key] = max(room.syncRevision, (sync?.remoteRevision ?? 0) + 1)
        if !marks.deletedNames.contains(room.name) { marks.deletedNames.append(room.name) }
        if !profilesNaming(room.name).isEmpty, marks.owedDeletes?.contains(room.name) != true {
            marks.owedDeletes = (marks.owedDeletes ?? []) + [room.name]
        }
        rooms.removeAll { $0.key == key }
        moveMarks(from: key, to: nil)
        activity[key] = nil
        // At once: the app can be closed before the gateway writes below are made, and the next launch finishes them.
        saveNow(urgent: true)
        notify()
        onRoomRemoved?(room)
        sync?.schedule(deleted: key)
        try await finishDelete(name: room.name)
    }

    func finishDelete(name: String) async throws {
        let title = "Couldn’t Delete \(name)"
        var first: Error?
        var members = 0
        for profile in profilesNaming(name) {
            do { try await write(profile, title: title) { GroupKeys.membership($0, removing: name) }; members += 1 }
            catch { if first == nil { first = error } }
        }
        if let first {
            AppLog.note("groups", "finish delete (\(members) members cleared): failed, \(SessionActionText.reason(first))")
            throw failure(first, title: title)
        }
        AppLog.trace("groups", "finish delete: \(members) members cleared")
        guard !isClosed else { return }
        settleOwed(name)
    }
}
