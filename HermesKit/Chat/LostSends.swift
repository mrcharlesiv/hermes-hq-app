// [sessions-m9] Sends that may never have arrived, kept beyond the chat's screen (docs/spec/3x-sessions.md §9.4): a
// message whose `prompt.submit` got no answer is marked "Delivery unconfirmed" in its chat; this keeps its words per
// chat so the Sessions row can say "Not Delivered: <words>" (the web's `row-pending.ts`), and so the chat can put the
// marked bubble back when it opens again (the row must never point at a message the chat no longer shows).
// One per process, as `QueueStash`. On disk: one small JSON file per account,
// `{"v":1,"chats":{"<profile>\u{1F}<stored id>":[{id,text,at}]}}`, written 0.3 s after the last change, off the main
// thread. At most 20 entries per chat, 2,000 characters each.

import Foundation

@MainActor final class LostSends {
    static let shared = LostSends()

    /// `id`: the local message id of the marked bubble. `after`: the newest stored row the chat knew when it was sent
    /// (a row with the same words past it means the send did arrive).
    nonisolated struct Entry: Codable, Hashable, Sendable {
        var id: String
        var text: String
        var at: Date
        var after: Int? = nil
    }

    nonisolated static let maxEntries = 20
    nonisolated static let maxCharacters = 2_000

    /// A chat's entries changed (the Sessions rows read their pending lines again).
    var onChange: (() -> Void)?

    /// By account id, then chat key.
    private var accounts: [String: [String: [Entry]]] = [:]
    private var loaded: Set<String> = []
    private let base: URL?
    private let writer = DispatchQueue(label: "hq.lost-sends.write", qos: .utility)
    private var writeGeneration: [String: Int] = [:]

    /// Tests pass their own folder.
    init(base: URL? = nil) {
        self.base = base
    }

    nonisolated static func key(profile: String, chatId: String) -> String { profile + "\u{1F}" + chatId }

    // MARK: Entries

    /// A send was marked: kept (an entry with the same id is replaced; the oldest goes past twenty).
    func note(accountId: String, profile: String, chatId: String, entry: Entry) {
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chatId.isEmpty, !text.isEmpty else { return }
        loadIfNeeded(accountId)
        let key = Self.key(profile: profile, chatId: chatId)
        var list = accounts[accountId]?[key] ?? []
        list.removeAll { $0.id == entry.id }
        list.append(Entry(id: entry.id, text: String(text.prefix(Self.maxCharacters)), at: entry.at, after: entry.after))
        if list.count > Self.maxEntries { list.removeFirst(list.count - Self.maxEntries) }
        accounts[accountId, default: [:]][key] = list
        changed(accountId)
    }

    /// The mark cleared (delivered after all, sent again, deleted).
    func clear(accountId: String, profile: String, chatId: String, id: String) {
        loadIfNeeded(accountId)
        let key = Self.key(profile: profile, chatId: chatId)
        guard var list = accounts[accountId]?[key], list.contains(where: { $0.id == id }) else { return }
        list.removeAll { $0.id == id }
        accounts[accountId]?[key] = list.isEmpty ? nil : list
        changed(accountId)
    }

    /// The chat itself is gone (deleted): none of its entries stay behind, on disk either.
    func clear(accountId: String, profile: String, chatId: String) {
        loadIfNeeded(accountId)
        let key = Self.key(profile: profile, chatId: chatId)
        guard accounts[accountId]?[key] != nil else { return }
        accounts[accountId]?[key] = nil
        changed(accountId)
    }

    /// The chat put an entry's bubble back under a new message id.
    func rekey(accountId: String, profile: String, chatId: String, from old: String, to new: String) {
        loadIfNeeded(accountId)
        let key = Self.key(profile: profile, chatId: chatId)
        guard var list = accounts[accountId]?[key], let index = list.firstIndex(where: { $0.id == old }) else { return }
        list[index].id = new
        accounts[accountId]?[key] = list
        changed(accountId, tell: false)
    }

    /// The oldest lost send of a chat: what its row names.
    func first(accountId: String, profile: String, chatId: String) -> Entry? {
        entries(accountId: accountId, profile: profile, chatId: chatId).first
    }

    func entries(accountId: String, profile: String, chatId: String) -> [Entry] {
        loadIfNeeded(accountId)
        return accounts[accountId]?[Self.key(profile: profile, chatId: chatId)] ?? []
    }

    /// Every lost send the account's chats keep (Sign Out and Remove say how many they delete).
    func count(accountId: String) -> Int {
        loadIfNeeded(accountId)
        return accounts[accountId]?.values.reduce(0) { $0 + $1.count } ?? 0
    }

    // MARK: Account lifecycle

    /// Sign-out / gateway removal: the account's entries go, on disk too.
    func purge(accountId: String) {
        accounts[accountId] = nil
        loaded.insert(accountId)
        writeGeneration[accountId, default: 0] += 1
        let file = Self.file(accountId: accountId, base: base)
        writer.async { try? FileManager.default.removeItem(at: file) }
        onChange?()
    }

    /// Background (and tests): what is kept reaches the disk now.
    func flush() {
        for accountId in accounts.keys { save(accountId, delay: 0) }
        writer.sync {}
    }

    // MARK: Disk

    nonisolated private struct FileShape: Codable {
        var v: Int
        var chats: [String: [Entry]]
    }

    nonisolated static func file(accountId: String, base: URL?) -> URL {
        let support = base ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appending(path: "lost-sends", directoryHint: .isDirectory)
            .appending(path: AttachmentStaging.accountKey(accountId) + ".json")
    }

    /// Everything kept for an account. A file this build cannot read (a newer shape, a torn write) reads as nothing.
    nonisolated static func load(accountId: String, base: URL? = nil) -> [String: [Entry]] {
        guard let data = try? Data(contentsOf: file(accountId: accountId, base: base)),
              let shape = try? JSONDecoder().decode(FileShape.self, from: data), shape.v == 1 else { return [:] }
        return shape.chats.compactMapValues { list in
            let kept = list.filter { !$0.text.isEmpty }.suffix(maxEntries)
                .map { Entry(id: $0.id, text: String($0.text.prefix(maxCharacters)), at: $0.at, after: $0.after) }
            return kept.isEmpty ? nil : Array(kept)
        }
    }

    private func loadIfNeeded(_ accountId: String) {
        guard loaded.insert(accountId).inserted else { return }
        for (key, list) in Self.load(accountId: accountId, base: base) where accounts[accountId]?[key] == nil {
            accounts[accountId, default: [:]][key] = list
        }
    }

    private func changed(_ accountId: String, tell: Bool = true) {
        save(accountId)
        if tell { onChange?() }
    }

    private func save(_ accountId: String, delay: Double = 0.3) {
        writeGeneration[accountId, default: 0] += 1
        let generation = writeGeneration[accountId] ?? 0
        let chats = (accounts[accountId] ?? [:]).filter { !$0.value.isEmpty }
        let file = Self.file(accountId: accountId, base: base)
        let write = { [weak self] in
            guard let self, self.writeGeneration[accountId] == generation else { return }
            let data = chats.isEmpty ? nil : try? JSONEncoder().encode(FileShape(v: 1, chats: chats))
            self.writer.async {
                if let data {
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    do { try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) } catch {   // [diagnostics]
                        AppLog.swallowed("send", "lost sends file write" , error)
                    }
                } else {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        if delay <= 0 { write() } else { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { write() } } }
    }
}

// MARK: - The chat's side

extension LiveChatSession {
    /// The id the Sessions row knows this chat by.
    private var lostSendChatId: String? {
        guard let id = storedSessionId ?? readSessionId, !id.isEmpty else { return nil }
        return id
    }

    /// A visible text send was marked "Delivery unconfirmed": its row says "Not Delivered:". Hidden continuations have
    /// no bubble and voice memos keep their own drafts; neither is kept.
    func noteLostSend(_ localId: String, memo: Bool) {
        guard let lostSends, !memo, let chatId = lostSendChatId, let index = indexById[localId], messages[index].role == .user else { return }
        let text = ChatTranscript.messageText(messages[index])
        let numbered = messages[..<index].compactMap(\.rowId).max()
        // Earlier messages with no stored row number yet: "after row 0" would let any older message with the same words
        // (a "yes") pass for this one, so the send's own time is the test instead (`lostSendArrived`). A new chat has
        // nothing earlier, so row 0 holds there.
        let known: Int? = numbered ?? (index == 0 ? 0 : nil)
        AppLog.trace("send", "lost send kept \(AppLog.tag(localId)) for \(AppLog.tag(chatId)): after row \(known.map(String.init) ?? "- (none numbered, by time)"), Sessions row says Not Delivered")
        lostSends.note(accountId: account.id, profile: profile, chatId: chatId,
                       entry: LostSends.Entry(id: localId, text: text, at: messages[index].timestamp ?? Date(), after: known))
    }

    /// The mark cleared: Check found it, the gateway holds it, Send Again, Delete.
    func clearLostSend(_ messageId: String) {
        guard let lostSends, let chatId = lostSendChatId else { return }
        AppLog.trace("send", "lost send cleared \(AppLog.tag(messageId)) for \(AppLog.tag(chatId))")
        lostSends.clear(accountId: account.id, profile: profile, chatId: chatId, id: messageId)
    }

    /// A page was merged into the transcript: an entry whose bubble lost its mark, or whose words are now a stored row
    /// past the rows the chat knew when it was sent, did arrive; it goes quietly. The same test as the bubble's own
    /// Check (`checkDelivery`): stored row numbers, never the two clocks.
    func settleLostSends() {
        guard let lostSends, let chatId = lostSendChatId else { return }
        for entry in lostSends.entries(accountId: account.id, profile: profile, chatId: chatId) {
            let settled = indexById[entry.id].map { messages[$0].error == nil } ?? lostSendArrived(entry)
            if settled {
                AppLog.trace("send", "lost send \(AppLog.tag(entry.id)) arrived after all (\(indexById[entry.id] != nil ? "its bubble lost the mark" : "a stored row past \(entry.after.map(String.init) ?? "-") holds its words")); cleared")
                lostSends.clear(accountId: account.id, profile: profile, chatId: chatId, id: entry.id)
            }
        }
    }

    /// Where a lost send's bubble goes back: where it was said, not at the end. Before the first stored row past the
    /// rows the chat knew when it was sent (row numbers, never the two clocks); without that, before the first message
    /// stamped later than it; else at the end.
    func lostSendPlace(_ entry: LostSends.Entry) -> Int {
        if let after = entry.after, after > 0 {
            return messages.firstIndex { ($0.rowId ?? 0) > after } ?? messages.count
        }
        return messages.firstIndex { message in message.timestamp.map { $0 > entry.at } ?? false } ?? messages.count
    }

    private func lostSendArrived(_ entry: LostSends.Entry) -> Bool {
        let words = Hydration.userDisplayKey(entry.text)
        return messages.contains { message in
            guard message.role == .user, let row = message.rowId, Hydration.userDisplayKey(message.plainText) == words else { return false }
            if let after = entry.after { return row > after }
            return message.timestamp.map { $0 >= entry.at.addingTimeInterval(-5) } ?? false
        }
    }

    /// The first history page landed: every lost send this screen does not show (the chat was left, or the app was
    /// closed, since) comes back as the user's bubble with its mark, unless the page shows it arrived.
    func restoreLostSends() {
        guard let lostSends, let chatId = lostSendChatId else { return }
        settleLostSends()
        var restored = false
        for entry in lostSends.entries(accountId: account.id, profile: profile, chatId: chatId) where indexById[entry.id] == nil {
            let id = "local-user-lost-" + UUID().uuidString.prefix(8).lowercased()
            AppLog.trace("send", "lost send \(AppLog.tag(entry.id)) restored as \(AppLog.tag(id)) at \(lostSendPlace(entry)) of \(messages.count) in \(AppLog.tag(chatId)) (after row \(entry.after.map(String.init) ?? "-"))")
            var message = ChatMessage(id: id, role: .user, parts: [.text(entry.text)], timestamp: entry.at, rowId: nil)
            message.error = LiveChatSession.unconfirmedMark
            insertMessage(message, at: lostSendPlace(entry))
            lostSends.rekey(accountId: account.id, profile: profile, chatId: chatId, from: entry.id, to: id)
            restored = true
        }
        if restored {
            changes.markState()
            scheduleFlush()
        }
    }
}
