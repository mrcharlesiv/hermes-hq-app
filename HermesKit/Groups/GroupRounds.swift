// [groups] The round engine of one account's rooms (docs/spec/3x-groups.md §6): your send, the drive queue, up to
// three rounds per thread, holds, Stop, resume and the late-reply harvest. A port of `HB/group-rounds.ts:574-720`,
// `HB/group-round-members.ts` and `sendToGroupChat` / `queueGroupChatDrive`. It lives with the account, not with a
// screen: a round goes on after you leave the room.

import Foundation

@MainActor final class GroupEngine {
    enum SendOutcome: Equatable, Sendable {
        case sent(entryId: String)
        case refused(RoomSendRefusal)
        case ignored
    }

    let store: GroupStore
    let client: any GatewayClient
    let signals = GroupSignals()
    let turn: GroupTurn
    /// The room is on screen (its replies are read as they arrive).
    var isFocused: (String) -> Bool = { _ in false }
    /// A member's reply was posted (notifications).
    var onReply: ((_ room: GroupRoom, _ entry: GroupMessage, _ seat: GroupSeat?) -> Void)?
    /// A member's hidden session is live for its turn: the room's questions and approvals come from it (D6).
    var onRuntime: ((_ roomKey: String, _ runtime: String, _ profile: String, _ stored: String?) -> Void)?
    /// Entry ids of sends being tried again (`Sending…` under the bubble).
    private(set) var retrying: Set<String> = []
    /// A retry ended undelivered again: entry id → reason (the "Couldn’t Deliver" alert).
    var onRetryFailed: ((_ roomKey: String, _ entryId: String, _ reason: String) -> Void)?

    private var pending: [UUID: [String]] = [:]
    private var drives: [UUID: Task<Void, Never>] = [:]
    private var failed: [UUID: Set<String>] = [:]
    private var harvests: [UUID: Task<Void, Never>] = [:]
    private var heldNoted: Set<String> = []
    /// The account was torn down (Sign Out, another gateway): no round is current any more and nothing is written.
    private var closed = false

    init(store: GroupStore, client: any GatewayClient, timing: GroupTiming = .standard) {
        self.store = store
        self.client = client
        turn = GroupTurn(client: client, signals: signals, timing: timing)
        signals.start(client)
    }

    /// The account is leaving (`handleSessionsGatewayTransition`): every round ends here. Each room's epoch moves on
    /// so a turn that is waiting sees it is no longer current; nothing is interrupted on the gateway.
    func shutdown() {
        closed = true
        for task in drives.values { task.cancel() }
        for task in harvests.values { task.cancel() }
        drives = [:]; harvests = [:]; pending = [:]; failed = [:]; retrying = []
        store.endAllRounds()
        signals.stop()
    }

    private func isCurrent(_ uid: UUID, _ epoch: Int) -> Bool {
        !closed && !Task.isCancelled && store.room(uid: uid)?.epoch == epoch
    }

    private static var nowMs: Double { (Date().timeIntervalSince1970 * 1000).rounded() }

    func isDriving(_ key: String) -> Bool { store.room(key).map { drives[$0.uid.value] != nil } ?? false }

    /// The app came back, or the socket did: read the waiting sessions now instead of at the next poll.
    func wake() {
        signals.wakeAll()
        collectLateReplies()
    }

    /// Rooms that still have a timed-out turn to collect (after a relaunch, or a round that ended first).
    func collectLateReplies() {
        for room in store.rooms where !room.stranded.isEmpty && !room.running && harvests[room.uid.value] == nil {
            startHarvest(room.uid.value)
        }
    }

    func roomRemoved(_ room: GroupRoom) {
        let uid = room.uid.value
        pending[uid] = nil
        failed[uid] = nil
        harvests.removeValue(forKey: uid)?.cancel()
        signals.wakeAll()          // its drive sees the room is gone and ends
    }

    // MARK: Your send (`sendToGroupChat`)

    @discardableResult
    func send(_ raw: String, room key: String, thread replyThread: String? = nil, entryId: String? = nil) -> SendOutcome {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !closed, !text.isEmpty, store.room(key) != nil else { return .ignored }
        if GroupPrompt.isSlashCommand(text) { return .refused(.slashCommand) }
        store.refreshDescriptors(key)
        guard let room = store.room(key) else { return .ignored }
        let seats = store.seated(room)
        guard seats.contains(where: \.canDrive) else { return .refused(.noMembers(room: room.name)) }
        let thread = (replyThread?.isEmpty == false ? replyThread : nil) ?? GroupKeys.newThreadId()
        let entry = GroupMessage(id: entryId ?? GroupKeys.newEntryId(), at: Self.nowMs, from: .you,
                                 text: GroupPrompt.compact(text, limit: GroupLimits.historyLineChars).text, thread: thread, truncated: nil)
        let mentions = GroupMentions.parse(text, seats: seats)
        let stamp = GroupHold(at: entry.at, byMessageId: entry.id, thread: thread)
        store.update(key, now: true) { room in   // its write is queued at once, not after the usual 250 ms
            room.log.append(entry)
            let next = GroupHolds.apply(room.holds, mentions: mentions, text: text, stamp: stamp, allMemberKeys: seats.map(\.key))
            if room.holdDetection {
                room.holds = next
                // A released member's held messages stay listed until its next turn delivers them.
            } else if !room.holds.isEmpty {
                // Detection off (perhaps turned off on another device while the room was stopped): no new holds, but a
                // release still releases, so Resume (`@all resume`) is never a dead button (audit 14-9).
                room.holds = room.holds.filter { next[$0.key] != nil }
            }
        }
        // The drive first (a new one starts a new turn's Activity list), so "You sent a message" is that list's first line.
        queueDrive(room.uid.value, thread: thread)
        store.record(.queued, room: key, thread: thread)
        return .sent(entryId: entry.id ?? "")
    }

    /// The paused capsule's Resume (`@all resume`, §6.8), in the thread that was stopped.
    func resumeAll(_ key: String) {
        guard let room = store.room(key) else { return }
        let thread = room.holds.values.sorted { $0.at > $1.at }.compactMap(\.thread).first ?? room.log.last?.thread
        send("@all resume", room: key, thread: thread)
    }

    /// Try Again under an undelivered send: the same entry, asked again.
    func retry(_ entryId: String, room key: String) {
        guard !closed, let room = store.room(key), let entry = room.log.first(where: { $0.id == entryId }), !retrying.contains(entryId) else { return }
        retrying.insert(entryId)
        store.update(key, sync: false) { $0.undelivered[entryId] = nil }
        queueDrive(room.uid.value, thread: entry.threadKey)
        store.record(.queued, room: key, thread: entry.threadKey)
    }

    /// Delete on an undelivered send: the entry leaves the log (and, with the next publish, the mirror).
    func deleteEntry(_ entryId: String, room key: String) {
        store.update(key) { room in
            guard let index = room.log.firstIndex(where: { $0.id == entryId }) else { return }
            // Remembered, so the copy already in the mirror is not merged back in and the next publish drops it.
            room.removed = Array((room.removed + [GroupSnapshot.entryKey(room.log[index])]).suffix(GroupLimits.removedMax))
            room.log.remove(at: index)
            for (mark, value) in room.watermarks where value > index { room.watermarks[mark] = value - 1 }
            room.undelivered[entryId] = nil
            for (member, ids) in room.heldMessages { room.heldMessages[member] = ids.filter { $0 != entryId } }
            room.syncRevision += 1
        }
    }

    // MARK: The drive queue (`queueGroupChatDrive`)

    private func queueDrive(_ uid: UUID, thread: String) {
        failed[uid] = []
        if !(pending[uid] ?? []).contains(thread) { pending[uid, default: []].append(thread) }
        guard !closed, drives[uid] == nil, let key = store.key(uid) else { return }
        harvests.removeValue(forKey: uid)?.cancel()
        store.setRuntime(key) { $0.epoch += 1 }
        drives[uid] = Task { [weak self] in await self?.drive(uid) }
    }

    private func drive(_ uid: UUID) async {
        while !closed, let thread = pending[uid]?.first {
            pending[uid]?.removeFirst()
            guard let key = store.key(uid), let room = store.room(key) else { break }
            let epoch = room.epoch
            store.setRuntime(key) { $0.running = true }
            await rounds(uid, thread: thread, epoch: epoch)
        }
        guard !closed else { return }
        drives[uid] = nil
        if let key = store.key(uid), let room = store.room(key) {
            // A stopped drive leaves the room idle already; a finished one is idle now.
            if room.running, pending[uid]?.isEmpty != false { store.setRuntime(key) { $0.running = false; $0.turn = nil } }
            if !room.stranded.isEmpty { startHarvest(uid) }
        }
        // A send that arrived while this drive was ending.
        if pending[uid]?.isEmpty == false, let thread = pending[uid]?.first { queueDrive(uid, thread: thread) }
    }

    private struct Tally {
        var posted = 0
        var took = 0            // a member took the message (accepted, held)
        var attempted = 0
        var failures = 0        // a member was asked and its turn failed
        var reason = ""
    }

    private enum MemberResult { case spoke, silent, aborted }

    /// `resolveGroupResponders`: everyone, or only the members @-mentioned since the thread's last message of yours.
    static func responders(_ log: [GroupMessage], seats: [GroupSeat]) -> [GroupSeat] {
        var since: ArraySlice<GroupMessage> = []
        if let last = log.lastIndex(where: { $0.from.kind == .user }) { since = log[last...] }
        var mentioned: Set<String> = []
        var everyone = false
        for entry in since {
            let parsed = GroupMentions.parse(entry.text, seats: seats)
            if parsed.everyone { everyone = true }
            mentioned.formUnion(parsed.mentioned)
        }
        if everyone || mentioned.isEmpty { return seats }
        return seats.filter { mentioned.contains($0.key) }
    }

    static func rotate(_ seats: [GroupSeat], round: Int) -> [GroupSeat] {
        guard seats.count > 1 else { return seats }
        let shift = round % seats.count
        return Array(seats[shift...] + seats[..<shift])
    }

    /// `unaddressedGroupMentions`: members another member cited who have not posted since.
    static func unaddressed(_ log: [GroupMessage], seats: [GroupSeat]) -> [String] {
        var citedAt: [String: Int] = [:]
        var order: [String] = []
        var lastPost: [String: Int] = [:]
        for (index, entry) in log.enumerated() where entry.from.kind == .member {
            let speaker = seats.first { $0.name == entry.from.name }?.key
            for key in GroupMentions.parse(entry.text, seats: seats).mentioned {
                guard let speaker, speaker != key else { continue }
                if citedAt[key] == nil { order.append(key) }
                citedAt[key] = index
            }
            if let speaker { lastPost[speaker] = index }
        }
        return order.filter { key in
            guard let cited = citedAt[key] else { return false }
            guard let answered = lastPost[key] else { return true }
            return answered <= cited
        }
    }

    /// `runGroupChatRounds` for one thread.
    private func rounds(_ uid: UUID, thread: String, epoch: Int) async {
        var tally = Tally()
        var continuations = 0
        var exit: GroupActivityEvent.Kind = .settled
        var cancelled = false
        func current() -> Bool { isCurrent(uid, epoch) }

        roundLoop: for round in 0..<GroupLimits.maxRounds {
            guard current() else { cancelled = true; break }
            await harvestOnce(uid)
            guard current(), let room = store.room(uid: uid) else { cancelled = true; break }
            let all = store.seated(room)
            let log = room.log.filter { $0.threadKey == thread }
            let responders = Self.rotate(Self.responders(log, seats: all).filter(\.canDrive), round: round)
                .filter { room.stranded[$0.key] == nil }
            var spoke = 0
            for seat in responders {
                guard current() else { cancelled = true; break roundLoop }
                if tally.posted >= GroupLimits.maxMessages { exit = .capped; break roundLoop }
                switch await member(uid, thread: thread, seat: seat, epoch: epoch, tally: &tally) {
                case .spoke: tally.posted += 1; spoke += 1
                case .silent: break
                case .aborted: cancelled = true; break roundLoop
                }
            }
            if spoke == 0 {
                guard let room = store.room(uid: uid) else { cancelled = true; break }
                let seats = store.seated(room)
                let owed = Self.unaddressed(room.log.filter { $0.threadKey == thread }, seats: seats)
                continuations += 1
                if !owed.isEmpty, continuations <= GroupLimits.maxContinuations, tally.posted < GroupLimits.maxMessages {
                    for seat in seats where seat.canDrive && owed.contains(seat.key) && room.stranded[seat.key] == nil {
                        guard current(), tally.posted < GroupLimits.maxMessages else { break }
                        switch await member(uid, thread: thread, seat: seat, epoch: epoch, tally: &tally) {
                        case .spoke: tally.posted += 1; spoke += 1
                        case .silent: break
                        case .aborted: cancelled = true; break roundLoop
                        }
                    }
                }
                if spoke == 0 {
                    if !owed.isEmpty, continuations > GroupLimits.maxContinuations || tally.posted >= GroupLimits.maxMessages { exit = .capped }
                    break
                }
            }
            if round == GroupLimits.maxRounds - 1 { exit = .capped }
        }

        guard !closed, let key = store.key(uid) else { return }
        let sends = (store.room(key)?.log ?? []).filter { $0.threadKey == thread && $0.from.kind == .user }.compactMap(\.id)
        if cancelled || !current() {
            if store.room(key)?.stoppedEpoch != store.room(key)?.epoch { store.record(.cancelled, room: key, thread: thread) }
            retrying.subtract(sends)
            return
        }
        store.record(exit, room: key, thread: thread)
        // Your send no member took (`undeliveredSend`): the newest of yours in this thread says so.
        if let newest = sends.last {
            let wasRetry = retrying.contains(newest)
            // Only when a member was asked and failed (`undeliveredSend`, ref240 src/ui-chat/room-run.ts): a send whose
            // only addressee is still working on a late reply, or sits on another gateway, did not fail.
            if tally.took == 0, tally.failures > 0 {
                store.update(key, sync: false) { $0.undelivered[newest] = tally.reason }
                if wasRetry { onRetryFailed?(key, newest, tally.reason) }
            } else if tally.took == 0 {
                // Nobody was asked: nothing to say under the bubble (a late reply, if one is owed, still arrives).
            } else if store.room(key)?.undelivered.isEmpty == false {
                store.update(key, sync: false) { room in for id in sends { room.undelivered[id] = nil } }
            }
        }
        retrying.subtract(sends)
        if pending[uid]?.isEmpty != false { store.setRuntime(key) { $0.running = false; $0.turn = nil } }
    }

    /// `runGroupRoundMember`: one member's turn. `.aborted` ends the drive.
    private func member(_ uid: UUID, thread: String, seat: GroupSeat, epoch: Int, tally: inout Tally) async -> MemberResult {
        guard let key = store.key(uid), let room = store.room(key) else { return .aborted }
        if failed[uid]?.contains(seat.key) == true { return .silent }
        let markKey = GroupKeys.watermarkKey(thread: thread, memberKey: seat.key)
        let seen = max(0, min(room.watermarks[markKey] ?? 0, room.log.count))
        let delta = room.log[seen...].filter { $0.threadKey == thread }
        guard !delta.isEmpty else { return .silent }

        if room.holds[seat.key] != nil {
            let ids = delta.compactMap(\.id)
            store.update(key, sync: false) { room in
                room.watermarks[markKey] = room.log.count
                var list = room.heldMessages[seat.key] ?? []
                for id in ids where !list.contains(id) { list.append(id) }
                if list.count > 200 { list.removeFirst(list.count - 200) }
                room.heldMessages[seat.key] = list
            }
            let note = "\(uid)|\(epoch)|\(seat.key)"
            if heldNoted.insert(note).inserted {
                if heldNoted.count > 512 { heldNoted = [note] }
                store.record(.held, room: key, member: seat.key, thread: thread)
            }
            tally.took += 1
            return .silent
        }

        // What it reads: the messages held back for it, then the new ones, oldest first.
        let heldIds = Set(room.heldMessages[seat.key] ?? [])
        let held = room.log[..<seen].filter { entry in entry.threadKey == thread && entry.id.map(heldIds.contains) == true }
        let visible = (held + delta).enumerated().sorted { $0.element.at != $1.element.at ? $0.element.at < $1.element.at : $0.offset < $1.offset }
            .map(\.element)
        let seats = store.seated(room)
        let labels = store.labels(seats)
        let prompt = GroupPrompt.build(room: room.name, seats: seats, viewer: seat,
                                       deltaLines: GroupPrompt.deltaLines(visible, viewer: seat.name, labels: labels))
        // Sent only if this turn makes the member's session for the thread (each main-composer send is a new thread).
        let freshContext = GroupPrompt.freshThreadContext(room.log, viewer: seat.name, labels: labels, activeThread: thread)
        let anchorId = room.log.last?.id
        let anchorCount = room.log.count
        let sessionKey = GroupKeys.sessionKey(thread: thread, memberKey: seat.key)
        store.setRuntime(key) { $0.turn = GroupTurnState(name: seat.key, thread: thread) }
        store.record(.working, room: key, member: seat.key, thread: thread)
        tally.attempted += 1

        var reply: String?
        var accepted = false
        var strandedBefore: (before: Int, stored: String?)?
        do {
            reply = try await turn.run(
                room: room, thread: thread, seat: seat, prompt: prompt, freshContext: freshContext,
                isCurrent: { [weak self] in self?.isCurrent(uid, epoch) ?? false },
                save: { [store] stored in
                    guard let key = store.key(uid) else { return }
                    store.update(key, sync: false) { $0.sessions[sessionKey] = stored }
                },
                onRuntime: { [weak self] runtime, stored in
                    guard let self, let key = self.store.key(uid) else { return }
                    self.onRuntime?(key, runtime, seat.name, stored)
                },
                onAccepted: { [store] before, stored in
                    accepted = true
                    // Saved while the member answers: a turn cut off by the app closing is collected at the next launch.
                    guard let key = store.key(uid) else { return }
                    store.update(key, sync: false, now: true) {
                        $0.asking[seat.key] = GroupAsking(before: before, thread: thread, at: Self.nowMs, stored: stored, markKey: markKey,
                                                          anchorId: anchorId, anchorCount: anchorCount)
                    }
                },
                onWaiting: { [store] waiting in
                    guard let key = store.key(uid) else { return }
                    store.setRuntime(key) { room in if room.turn?.name == seat.key { room.turn?.waitingOnUser = waiting } }
                })
        } catch GroupTurnError.cancelled {
            if let key = store.key(uid) { store.update(key, sync: false) { $0.asking[seat.key] = nil } }
            return .aborted
        } catch GroupTurnError.timedOut(let before, let stored) {
            accepted = true
            strandedBefore = (before, stored)
        } catch {
            let reason = GroupTurn.reason(error)
            if let key = store.key(uid) { store.record(.failed, room: key, member: seat.key, detail: reason, thread: thread) }
            failed[uid, default: []].insert(seat.key)
            tally.reason = reason
            tally.failures += 1
            if case GroupTurnError.failed = error { accepted = true }
        }

        guard !closed, let key = store.key(uid), let now = store.room(key) else { return .aborted }
        if !now.asking.isEmpty { store.update(key, sync: false) { $0.asking[seat.key] = nil } }   // the turn is over, however it ended
        if now.epoch != epoch { return .aborted }
        if now.turn?.name == seat.key { store.setRuntime(key) { $0.turn = nil } }
        guard accepted else { return .silent }
        tally.took += 1

        let text = (reply ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let spoke = !text.isEmpty && !GroupPrompt.isPass(text)
        let delivered = Set(visible.compactMap(\.id))
        var posted: GroupMessage?
        store.update(key, sync: spoke) { room in
            let anchor = anchorId.flatMap { id in room.log.lastIndex { $0.id == id } } ?? (min(anchorCount, room.log.count) - 1)
            room.watermarks[markKey] = max(room.watermarks[markKey] ?? 0, anchor + 1)
            if var list = room.heldMessages[seat.key] {
                list.removeAll { delivered.contains($0) }
                room.heldMessages[seat.key] = list.isEmpty ? nil : list
            }
            if let stranded = strandedBefore {
                room.stranded[seat.key] = GroupStranded(before: stranded.before, thread: thread, at: Self.nowMs, stored: stranded.stored)
            }
            guard spoke else { return }
            let entry = GroupMessage(id: GroupKeys.newEntryId(), at: max(Self.nowMs, (room.log.last?.at ?? 0) + 1),
                                     from: GroupAuthor(kind: .member, name: seat.name, source: nil, gateway: nil),
                                     text: GroupPrompt.compact(text, limit: GroupLimits.historyLineChars).text, thread: thread, truncated: nil)
            if !Self.isDuplicate(entry, in: room.log) {
                room.log.append(entry)
                posted = entry
            }
            // Its own lines are never news to it.
            var mark = room.watermarks[markKey] ?? 0
            while mark < room.log.count, room.log[mark].from.kind == .member, room.log[mark].from.name == seat.name,
                  room.log[mark].threadKey == thread { mark += 1 }
            room.watermarks[markKey] = mark
        }
        if strandedBefore != nil {
            store.record(.timedOut, room: key, member: seat.key, thread: thread)
            return .silent
        }
        if let posted {
            store.record(.replied, room: key, member: seat.key, thread: thread)
            arrived(posted, key: key, seat: seat)
            return .spoke
        }
        if !failed[uid, default: []].contains(seat.key) { store.record(.passed, room: key, member: seat.key, thread: thread) }
        return .silent
    }

    /// The same member saying the same thing in the same thread within 10 minutes is one message.
    static func isDuplicate(_ entry: GroupMessage, in log: [GroupMessage]) -> Bool {
        guard let last = log.last else { return false }
        return last.from.kind == .member && last.from.name == entry.from.name && last.threadKey == entry.threadKey
            && last.text == entry.text && entry.at - last.at < 600_000
    }

    private func arrived(_ entry: GroupMessage, key: String, seat: GroupSeat?) {
        guard let room = store.room(key) else { return }
        if !isFocused(key) { store.setUnread(key, true) }
        onReply?(room, entry, seat)
    }

    // MARK: Stop (`stopGroupThread`, row L467)

    /// Stops the round here at once; then asks the gateway to stop the reply in flight. false = stopped here, the
    /// gateway did not confirm.
    func stop(_ key: String) async -> Bool {
        guard let room = store.room(key) else { return true }
        let uid = room.uid.value
        let onTurn = room.turn
        let thread = onTurn?.thread ?? room.log.last?.thread
        pending[uid] = []
        let seats = store.seated(room)
        let stamp = GroupHold(at: Self.nowMs, byMessageId: nil, thread: thread)
        store.update(key, sync: false) { room in
            room.epoch += 1
            room.stoppedEpoch = room.epoch
            room.running = false
            room.turn = nil
            guard room.holdDetection else { return }
            for seat in seats where room.holds[seat.key] == nil { room.holds[seat.key] = stamp }
        }
        store.record(.stopped, room: key, thread: thread)
        signals.wakeAll()
        guard let onTurn, let seat = seats.first(where: { $0.key == onTurn.name }) else { return true }
        let scoped = room.sessions.keys.contains { $0.hasPrefix("thread:") && $0.hasSuffix("::\(onTurn.name)") }
        guard let stored = room.sessions[GroupKeys.sessionKey(thread: onTurn.thread, memberKey: onTurn.name)]
                ?? (scoped ? nil : room.sessions[onTurn.name]) else {
            // Its session was still being found: the turn sees the stop before it sends anything.
            return true
        }
        return await GroupInterrupt.interrupt(client: client, profile: seat.name, storedId: stored)
    }

    // MARK: Late replies (§6.7)

    private func startHarvest(_ uid: UUID) {
        guard harvests[uid] == nil else { return }
        let every = turn.timing.harvestEvery
        let tries = Int(((turn.timing.hardCap + 60) / max(1, every)).rounded(.up))
        harvests[uid] = Task { [weak self] in
            for _ in 0..<tries {
                try? await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
                guard let self, !Task.isCancelled, !self.closed, let room = self.store.room(uid: uid), !room.running else { break }
                await self.harvestOnce(uid)
                if self.store.room(uid: uid)?.stranded.isEmpty != false { break }
            }
            self?.harvests[uid] = nil
        }
    }

    /// `harvestStrandedGroupReply` for every member with a marker.
    private func harvestOnce(_ uid: UUID) async {
        guard let room = store.room(uid: uid), !room.stranded.isEmpty else { return }
        let seats = store.seated(room)
        let expiry = (turn.timing.hardCap + 60) * 1000
        for (memberKey, marker) in room.stranded.sorted(by: { $0.value.at < $1.value.at }) {
            guard let seat = seats.first(where: { $0.key == memberKey }), seat.canDrive, Self.nowMs - marker.at < expiry else {
                if let key = store.key(uid) { store.update(key, sync: false) { $0.stranded[memberKey] = nil } }
                continue
            }
            let result = await turn.harvest(marker, profile: seat.name)
            guard !closed, let key = store.key(uid) else { return }
            switch result {
            case .busy:
                continue
            case .nothing:
                store.update(key, sync: false) { if $0.stranded[memberKey] == marker { $0.stranded[memberKey] = nil } }
            case .reply(let text):
                var posted: GroupMessage?
                store.update(key) { room in
                    // Another collection (the timer's, or a new round's) read the same marker meanwhile and posted the
                    // reply first: the marker is gone, so this one is not posted again (audit 14-13).
                    guard room.stranded[memberKey] == marker else { return }
                    room.stranded[memberKey] = nil
                    let entry = GroupMessage(id: GroupKeys.newEntryId(), at: max(Self.nowMs, (room.log.last?.at ?? 0) + 1),
                                             from: GroupAuthor(kind: .member, name: seat.name, source: nil, gateway: nil),
                                             text: GroupPrompt.compact(text, limit: GroupLimits.historyLineChars).text,
                                             thread: marker.thread, truncated: nil)
                    guard !Self.isDuplicate(entry, in: room.log) else { return }
                    room.log.append(entry)
                    posted = entry
                }
                if let posted {
                    store.record(.delivered, room: key, member: memberKey, thread: marker.thread)
                    arrived(posted, key: key, seat: seat)
                }
            }
        }
    }
}
