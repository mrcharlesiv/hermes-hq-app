// [groups] A room as the chat screen sees it (docs/spec/3x-groups.md §7.13, D7): the room log mapped to `ChatMessage`s
// with their senders, the typing rows, the reply target, the paused and Stop state, and the members' questions.
// It only reads `GroupStore` and asks `GroupEngine`: a round belongs to the account, not to this screen.

import Foundation

@MainActor final class GroupRoomSession: ChatSessionModel, ChatSessionDetails, ChatRoomSurface, ChatPrompting, ChatChangeFlushing,
                                         ChatVoiceMemos {
    private let store: GroupStore
    private let engine: GroupEngine
    private let uid: UUID
    private let accountId: String
    private var observer: UUID?
    private var lastKey: String
    private var lastName: String
    private var observing = false
    private var revisions: [String: Int] = [:]
    private var chromeSignature = ""
    private var gone = false
    /// What `messages` was last built from: a store change that touched none of it (another room's round, this room's
    /// Activity line or typing state) does not build the rows again.
    private var builtLog: [GroupMessage] = []
    private var builtOmitted = 0
    private var builtSeats: [GroupSeat] = []
    private var builtLabels: [String: String] = [:]
    /// Times the rows were built (tests).
    private(set) var rebuilds = 0
    /// The connection as the app sees it.
    var connectionProvider: () -> ConnectionState = { .ready }
    var reconnect: (() -> Void)?
    /// The room came on screen or left it (AppModel: focus, unread, the lists' refresh cadence).
    var onObservingChange: ((Bool) -> Void)?

    static let earlierNotice = "Earlier messages are on the device that sent them."
    static let slashNotice = "Slash commands are not supported in group chats. Open an individual bot chat to use them."

    init?(key: String, store: GroupStore, engine: GroupEngine, accountId: String) {
        guard let room = store.room(key) else { return nil }
        self.store = store
        self.engine = engine
        self.accountId = accountId
        uid = room.uid.value
        lastKey = room.key
        lastName = room.name
        rebuild(room, seats: store.seated(room))
        chromeSignature = signature(room, seats: store.seated(room))
        observer = store.observe { [weak self] in self?.storeChanged() }
    }

    isolated deinit {
        if let observer { store.stopObserving(observer) }
    }

    private var room: GroupRoom? { store.room(uid: uid) }
    private var seats: [GroupSeat] { room.map(store.seated) ?? [] }

    // MARK: ChatSessionModel

    var title: String { room?.name ?? lastName }
    /// Rooms have no bot of their own; the header draws the group avatar instead of a head.
    var profile: String { "" }
    var head: JSONValue? { nil }
    private(set) var messages: [ChatMessage] = []
    /// Not a bot chat's turn; the composer's Stop square follows `roomRunning` (GroupRoomChrome).
    var isRunning: Bool { false }
    var hasOlder: Bool { false }
    var isLoadingOlder: Bool { false }
    var connection: ConnectionState { connectionProvider() }
    var statusText: String? {
        switch connection {
        case .reconnecting: return "Reconnecting…"
        case .offline: return "Offline"
        default: return prompts.needsInput?.statusText
        }
    }
    var onChange: ((ChatChange) -> Void)?

    func start() {
        guard !observing else { return }
        observing = true
        promptLink?.isObserving = true
        store.setUnread(roomKey, false)
        onObservingChange?(true)
        engine.collectLateReplies()
        promptsCameOnScreen()
    }

    func stopObserving() {
        guard observing else { return }
        observing = false
        promptLink?.isObserving = false
        onObservingChange?(false)
    }

    func loadOlder() {}

    func send(_ text: String) {
        guard refusal(for: text) == nil else { return }
        let thread = replyTarget?.thread
        if case .sent = engine.send(text, room: roomKey, thread: thread) {
            replyTarget = nil
        }
    }

    /// The composer never shows Stop in a room; the capsule calls `stopRoom()`.
    func stop() { Task { _ = await stopRoom() } }

    /// The store notifies synchronously, so a send's bubble is already in `messages`.
    func flushChanges() {}

    // MARK: ChatSessionDetails

    var layoutScope: String { "\(accountId)|room|\(uid.uuidString)" }
    /// The member whose question shows, else the room.
    var botName: String {
        if let turn = room?.turn, turn.waitingOnUser, let seat = seats.first(where: { $0.key == turn.name }) { return seat.display }
        return title
    }
    var modelName: String? { nil }
    var seenThrough: Date? { room?.log.last.map { Date(timeIntervalSince1970: $0.at / 1000) } }

    // MARK: ChatRoomSurface

    var roomKey: String { room?.key ?? lastKey }
    var roomName: String { title }
    var onRoomGone: ((String) -> Void)?
    var onChromeChange: (() -> Void)?
    var replyTarget: GroupMessage? { didSet { if replyTarget != oldValue { onChromeChange?() } } }
    var isEmptyRoom: Bool { room?.log.isEmpty ?? true }
    var memberNames: [String] { seats.map(\.display) }
    var roomRunning: Bool { room?.running ?? false }
    var undelivered: [String: String] {
        var out: [String: String] = [:]
        for (id, reason) in room?.undelivered ?? [:] { out[Self.messageId(entryId: id)] = reason }
        return out
    }
    var retrying: Set<String> { Set(engine.retrying.map(Self.messageId(entryId:))) }

    var paused: [String] {
        guard let room else { return [] }
        return seats.filter { room.holds[$0.key] != nil }.map(\.display)
    }

    var typing: [RoomTyping] {
        guard let room, room.running else { return [] }
        guard let turn = room.turn else { return [RoomTyping(sender: nil, label: "Replying…")] }
        guard let seat = seats.first(where: { $0.key == turn.name }) else { return [RoomTyping(sender: nil, label: "Replying…")] }
        return [RoomTyping(sender: sender(seat), label: turn.waitingOnUser ? "Waiting for your answer" : "\(seat.display) is replying…")]
    }

    var roomStatusLine: String {
        switch connection {
        case .offline, .signedOut: return "Offline"
        default: break
        }
        if let room, room.running, let turn = room.turn {
            if turn.waitingOnUser { return "Waiting for your reply" }
            if let seat = seats.first(where: { $0.key == turn.name }) { return GroupRowWords.replying([seat.display]) }
        }
        let names = memberNames
        if names.isEmpty { return "No bots yet" }
        let joined = names.joined(separator: ", ")
        return joined.count > 32 ? GroupRowWords.bots(names.count) : joined
    }

    var mentionChoices: [(tag: String, name: String, sender: ChatSender?)] {
        seats.map { (GroupMentions.tag(for: $0), $0.display, Optional(sender($0))) }
    }

    func refusal(for text: String) -> RoomSendRefusal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if GroupPrompt.isSlashCommand(trimmed) { return .slashCommand }
        if !seats.contains(where: \.canDrive) { return .noMembers(room: title) }
        return nil
    }

    func stopRoom() async -> Bool { await engine.stop(roomKey) }
    func resumeAll() { engine.resumeAll(roomKey) }

    func retry(_ messageId: String) {
        guard let entry = entry(for: messageId), let id = entry.id else { return }
        engine.retry(id, room: roomKey)
        emit(.updated(ids: [messageId]))
    }

    func deleteUndelivered(_ messageId: String) {
        guard let entry = entry(for: messageId), let id = entry.id else { return }
        engine.deleteEntry(id, room: roomKey)
    }

    func mentionTag(for messageId: String) -> String? {
        guard let entry = entry(for: messageId), entry.from.kind == .member,
              let seat = seats.first(where: { $0.name == entry.from.name }) else { return nil }
        return GroupMentions.tag(for: seat)
    }

    func entry(for messageId: String) -> GroupMessage? {
        room?.log.first { Self.messageId($0) == messageId }
    }

    func replyHeader(_ entry: GroupMessage) -> String {
        let who = entry.from.kind == .user ? "You" : (store.labels(seats)[entry.from.name] ?? entry.from.name)
        return "Replying in thread · \(who)"
    }

    // MARK: Messages

    static func messageId(entryId: String) -> String { "room-\(entryId)" }

    static func messageId(_ entry: GroupMessage) -> String {
        if let id = entry.id, !id.isEmpty { return messageId(entryId: id) }
        var hasher = FNV()
        hasher.add(GroupSnapshot.entryKey(entry))
        return "room-k\(String(hasher.value, radix: 36))"
    }

    /// A stable hash (Swift's own changes between launches; row ids must not).
    private struct FNV {
        var value: UInt64 = 0xcbf29ce484222325
        mutating func add(_ text: String) { for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 0x100000001b3 } }
    }

    func sender(_ seat: GroupSeat) -> ChatSender {
        ChatSender(key: seat.key, name: seat.display, head: seat.head, profile: seat.name,
                   colorHex: ChatSenderColors.hex(head: seat.head, profile: seat.name))
    }

    private func rebuild(_ room: GroupRoom, seats: [GroupSeat]) {
        rebuilds += 1
        builtLog = room.log
        builtOmitted = room.omitted
        builtSeats = seats
        let bySeat = Dictionary(seats.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let labels = store.labels(seats)
        builtLabels = labels
        var out: [ChatMessage] = []
        out.reserveCapacity(room.log.count + 1)
        if room.omitted > 0 {
            out.append(ChatMessage(id: "room-notice-earlier", role: .system, parts: [.text(Self.earlierNotice)], timestamp: nil, rowId: nil))
        }
        var seen: Set<String> = []
        for entry in room.log {
            let id = Self.messageId(entry)
            guard seen.insert(id).inserted else { continue }
            let at = Date(timeIntervalSince1970: entry.at / 1000)
            var message: ChatMessage
            if entry.from.kind == .user {
                message = ChatMessage(id: id, role: .user, parts: [.text(entry.text)], timestamp: at, rowId: nil)
            } else {
                message = ChatMessage(id: id, role: .assistant, parts: [.text(entry.text)], timestamp: at, rowId: nil)
                if let seat = bySeat[entry.from.name], (entry.from.source ?? "").isEmpty {
                    message.sender = sender(seat)
                } else {
                    // A member that left, or one on another gateway: its name as written, the default head.
                    let name = labels[entry.from.name] ?? entry.from.name
                    let label = (entry.from.source ?? "").isEmpty ? name : "\(name) · \(entry.from.source!)"
                    message.sender = ChatSender(key: "\(entry.from.source ?? "")::\(entry.from.name)", name: label, head: nil,
                                                profile: entry.from.name, colorHex: ChatSenderColors.hex(head: nil, profile: entry.from.name))
                }
            }
            out.append(message)
        }
        // A voice memo still uploading: its bubble at the newest end, under the id its room entry will have.
        for pending in memoSending where seen.insert(pending.rowId).inserted {
            out.append(ChatMessage(id: pending.rowId, role: .user, parts: [.text(pending.text)], timestamp: pending.at, rowId: nil))
        }
        // Revisions: a message whose content changed (a fuller twin from the mirror, a renamed member) draws again.
        let old = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in out.indices {
            let id = out[index].id
            var revision = revisions[id] ?? 0
            if let before = old[id] {
                var same = before
                same.revision = 0
                if same != out[index] { revision += 1 }
            }
            revisions[id] = revision
            out[index].revision = revision
        }
        if revisions.count > out.count * 2 + 64 { revisions = revisions.filter { key, _ in seen.contains(key) || key == "room-notice-earlier" } }
        messages = out
    }

    private func signature(_ room: GroupRoom, seats: [GroupSeat]) -> String {
        let turn = room.turn.map { "\($0.name)|\($0.thread)|\($0.waitingOnUser)" } ?? "-"
        return "\(room.name)|\(room.running)|\(turn)|\(room.holds.keys.sorted().joined(separator: ","))|\(seats.map(\.display).joined(separator: ","))"
            + "|\(room.undelivered.keys.sorted().joined(separator: ","))|\(engine.retrying.sorted().joined(separator: ","))"
    }

    private func emit(_ change: ChatChange) { onChange?(change) }

    private func storeChanged() {
        guard !gone else { return }
        guard let room else {
            gone = true
            onRoomGone?(lastName)
            return
        }
        lastKey = room.key
        lastName = room.name
        if observing, store.isUnread(room.key) { store.setUnread(room.key, false) }
        let seats = store.seated(room)
        // The store tells every room's session about every change of the account (several a second during a round).
        if room.log != builtLog || room.omitted != builtOmitted || seats != builtSeats || store.labels(seats) != builtLabels {
            let before = messages
            rebuild(room, seats: seats)
            let after = messages
            let oldIds = before.map(\.id), newIds = after.map(\.id)
            if oldIds == newIds {
                let changed = zip(before, after).filter { $0 != $1 }.map { $1.id }
                if !changed.isEmpty { emit(.updated(ids: changed)) }
            } else if newIds.count > oldIds.count, Array(newIds.prefix(oldIds.count)) == oldIds {
                let changed = zip(before, after).filter { $0 != $1 }.map { $1.id }
                if !changed.isEmpty { emit(.updated(ids: changed)) }
                emit(.appended(ids: Array(newIds.suffix(newIds.count - oldIds.count))))
            } else {
                // Merged in place (another device's messages) or one removed: the list is rebuilt, nothing reorders.
                emit(.reset)
            }
        }
        let signature = signature(room, seats: seats)
        if signature != chromeSignature {
            chromeSignature = signature
            emit(.state)
            onChromeChange?()
        }
    }

    /// The connection changed, or a retry started or ended: the header and the rows under your bubbles follow.
    func refreshState() {
        guard let room else { return }
        chromeSignature = signature(room, seats: seats)
        emit(.state)
        onChromeChange?()
    }

    // MARK: ChatPrompting (D6: a member's question or approval, through the account's centre)

    private(set) var promptLink: PromptChatLink?

    func attachPrompts(_ center: ServerRequestCenter) {
        guard promptLink == nil else { return }
        let link = PromptChatLink(center: center)
        link.interruptedProbe = { false }
        link.onChange = { [weak self] in
            self?.emit(.state)
            self?.promptLink?.screenOnChange?()
        }
        link.onTimedOut = { }
        link.isObserving = observing
        promptLink = link
    }

    /// The member on turn: its hidden session is the one whose requests this room shows.
    func bind(runtime: String, profile: String, stored: String?) {
        guard let link = promptLink else { return }
        link.bind(runtime: runtime, profile: profile, profileParam: profile.isEmpty ? nil : profile, storedId: stored)
        boundRuntime = runtime
        boundProfile = profile
        if observing { link.center?.replayApprovals(runtime) }
    }

    private var boundRuntime: String?
    private var boundProfile: String?

    var promptAsker: String? {
        guard let profile = boundProfile else { return nil }
        return seats.first { $0.name == profile }?.display
    }

    var prompts: ChatPrompts { promptLink?.prompts ?? ChatPrompts() }

    var onPromptsChange: (() -> Void)? {
        get { promptLink?.screenOnChange }
        set { promptLink?.screenOnChange = newValue }
    }

    func answerApproval(_ id: String, _ choice: ApprovalChoice) async throws {
        try await promptLink?.center?.answerApproval(id, choice)
        engine.wake()
    }

    func dismissExpiredApproval(_ id: String) { promptLink?.center?.dismissExpiredApproval(id) }

    func approvalTimeout(fresh: Bool) async -> TimeInterval {
        await promptLink?.center?.approvalTimeout(profile: boundProfile, fresh: fresh) ?? ApprovalExpiry.defaultTimeout
    }

    func clarifyDraft(_ requestId: String) -> ClarifyDraft? { promptLink?.center?.draft(requestId) }
    func saveClarifyDraft(_ requestId: String, _ draft: ClarifyDraft) { promptLink?.center?.saveDraft(requestId, draft) }

    func sendClarify(_ requestId: String, answers: [(qid: String, answer: String?)]) async throws {
        try await promptLink?.center?.sendClarify(requestId, answers: answers)
        engine.wake()
    }

    func skipClarify(_ requestId: String) async throws {
        try await promptLink?.center?.skipClarify(requestId)
        engine.wake()
    }

    func answerValue(_ requestId: String, _ value: String) async throws {
        try await promptLink?.center?.answerValue(requestId, value)
        engine.wake()
    }

    func promptsCameOnScreen() {
        guard let center = promptLink?.center, let runtime = boundRuntime else { return }
        let prompts = center.prompts(for: [runtime])
        if prompts.clarify != nil || !prompts.values.isEmpty || prompts.approvals.contains(where: { $0.id.hasPrefix("srq-") }) {
            center.probeSoon(runtime)
        }
        center.replayApprovals(runtime)
    }

    func reconnectNow() { reconnect?() }

    // MARK: ChatVoiceMemos (tester 2026-11-05: group chats had no voice memo; this reverses spec D5 for memos)

    /// A memo on its way: the bubble shows the local recording until the upload is done, then the room entry (same id)
    /// takes its place with the gateway's copy.
    struct PendingMemo {
        var rowId: String
        var entryId: String
        var text: String
        var at: Date
    }
    private(set) var memoSending: [PendingMemo] = []

    var memoScope: String { layoutScope }
    /// The gateway the room's memos are uploaded to and played from.
    var memoClient: any GatewayClient { engine.client }
    private var memoStoresAreMine: Bool { MemoAccountStores.shared.accountId == accountId }
    var memoDraft: MemoFile? { memoStoresAreMine ? MemoAccountStores.shared.drafts?.draft(for: memoScope) : nil }

    func setMemoDraft(_ memo: MemoFile?) {
        guard memoStoresAreMine else { return }
        MemoAccountStores.shared.drafts?.set(memo, for: memoScope)
    }

    /// The memo goes to the gateway's files folder first (the default profile's: a room has no bot of its own), then into
    /// the room as your message, `MEDIA:"<path>"` and its transcript, as a bot chat's memo reads. No `file.attach`: each
    /// member reads the words (`GroupPrompt.line`), so no member's session needs the file. A failed upload returns the
    /// memo (and the words typed beside it) as this room's draft.
    func sendMemo(_ memo: MemoFile, text: String) {
        let thread = replyTarget?.thread
        replyTarget = nil
        let entryId = GroupKeys.newEntryId()
        let pending = PendingMemo(rowId: Self.messageId(entryId: entryId), entryId: entryId,
                                  text: MemoText.optimistic(localPath: memo.path, typed: text), at: Date())
        memoSending.append(pending)
        if let room { rebuild(room, seats: store.seated(room)) }
        emit(.appended(ids: [pending.rowId]))
        AppLog.trace("send", "room memo \(AppLog.tag(entryId)) staging: \(Int(memo.seconds.rounded()))s, words \(memo.words == nil ? "none" : "from this device"), typed \(text.count) chars")
        let uploader = MemoUploader(client: engine.client)
        let storedId = "room|\(uid.uuidString)"
        // Held strongly: a memo sent just before leaving the room still reaches it (the round belongs to the account).
        Task { [self] in
            let staged: StagedMemo
            do {
                // The uploaded copy is the memo's home: nothing attaches it, and it isn't cleaned up.
                staged = try await uploader.stage(memo, profile: nil, storedId: storedId) { params in .object(["path": params["path"] ?? .null]) }
            } catch {
                memoFailed(pending, memo: memo, typed: text, reason: MemoUploader.words(error, doing: "send the voice memo"))
                return
            }
            memoStaged(pending, memo: memo, typed: text, staged: staged, thread: thread, storedId: storedId)
        }
    }

    private func memoStaged(_ pending: PendingMemo, memo: MemoFile, typed: String, staged: StagedMemo, thread: String?, storedId: String) {
        memoSending.removeAll { $0.entryId == pending.entryId }
        let prompt = MemoText.prompt(reference: staged.reference, typed: typed)
        let outcome = engine.send(prompt, room: roomKey, thread: thread, entryId: pending.entryId)
        guard case .sent = outcome else {
            AppLog.note("send", "room memo \(AppLog.tag(pending.entryId)) refused by the room: \(outcome)")
            memoFailed(pending, memo: memo, typed: typed, reason: Self.memoRefusal(outcome, room: roomName))
            return
        }
        AppLog.trace("send", "room memo \(AppLog.tag(pending.entryId)) sent")
        MemoUploader.forgetStage(memoPath: memo.path, storedId: storedId)
        guard memoStoresAreMine else { MemoPaths.remove(memo.path); return }
        if let gatewayPath = staged.gatewayPath {
            MemoAccountStores.shared.cache?.adopt(URL(fileURLWithPath: memo.path), as: gatewayPath)
            MemoAccountStores.shared.shapes?.link(memo.path, to: gatewayPath)
        }
        if let failure = staged.transcriptFailure {
            NotificationCenter.default.post(name: MemoSessionNotice.post, object: self,
                                            userInfo: [MemoSessionNotice.scopeKey: memoScope, MemoSessionNotice.detailKey: failure,
                                                       MemoSessionNotice.botKey: title,
                                                       MemoSessionNotice.kindKey: MemoSessionNotice.Kind.noTranscript.rawValue])
        }
    }

    /// Why the room didn't take a staged memo, in the card's words.
    static func memoRefusal(_ outcome: GroupEngine.SendOutcome, room: String) -> String {
        switch outcome {
        case .refused(.noMembers): "\(room) has no members to send to."
        case .refused(.slashCommand), .sent: "The group chat didn’t take it."
        case .ignored: "The group chat closed before it went."
        }
    }

    /// `reason` goes on the card (as a bot chat's failed bubble says why), not only in the log.
    private func memoFailed(_ pending: PendingMemo, memo: MemoFile, typed: String, reason: String) {
        AppLog.note("send", "room memo \(AppLog.tag(pending.entryId)) didn't go: \(AppLog.scrub(reason))")
        memoSending.removeAll { $0.entryId == pending.entryId }
        if messages.contains(where: { $0.id == pending.rowId }) {
            if let room { rebuild(room, seats: store.seated(room)) }
            emit(.removed(ids: [pending.rowId]))
        }
        guard memoStoresAreMine, let drafts = MemoAccountStores.shared.drafts else { MemoPaths.remove(memo.path); return }
        drafts.restore([MemoDraft(memo: memo, text: typed.isEmpty ? nil : typed)], for: memoScope)
        NotificationCenter.default.post(name: MemoSessionNotice.post, object: self,
                                        userInfo: [MemoSessionNotice.scopeKey: memoScope, MemoSessionNotice.botKey: title,
                                                   MemoSessionNotice.detailKey: reason,
                                                   MemoSessionNotice.kindKey: MemoSessionNotice.Kind.savedAsDraft.rawValue])
    }
}

/// A sender's colour before the contrast step: its head's accent (the colour the row's face uses).
nonisolated enum ChatSenderColors {
    static func hex(head raw: JSONValue?, profile: String) -> String {
        let head = Head.resolve(raw, profile: profile)
        return HeadTones.accent(head.color).description
    }
}
