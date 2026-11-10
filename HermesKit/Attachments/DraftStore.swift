// Chat drafts on disk (docs/spec/1x-attachments.md §6.6, A14; R:src/attachment-drafts.ts:54-69): what is typed and
// attached in each chat, newest 50 chats, one small JSON file per account,
// `{"v":1,"chats":{scope:{text,attachments,updatedAt,profile}}}`. Read synchronously (it is small), written atomically
// 0.5 s after the last change, off the main thread. A restored draft's preparing/uploading attachments come back
// waiting, and one whose phone copy is gone is dropped.

import Foundation

nonisolated struct StoredDraft: Codable, Hashable, Sendable {
    var text: String
    var attachments: [DraftAttachment]
    var updatedAt: Double
    /// The bot's profile (the scope string can't be split reliably: account ids hold "|").
    var profile: String
}

nonisolated final class DraftStore: @unchecked Sendable {
    static let maxChats = 50

    let file: URL
    private let queue = DispatchQueue(label: "hq.drafts.write", qos: .utility)
    private let lock = NSLock()
    private var pending: [String: StoredDraft]?
    private var generation = 0

    init(accountId: String, base: URL? = nil) {
        let support = base ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        file = support.appending(path: "drafts", directoryHint: .isDirectory)
            .appending(path: AttachmentStaging.accountKey(accountId) + ".json")
    }

    private struct FileShape: Codable {
        var v: Int
        var chats: [String: StoredDraft]
    }

    /// Everything saved, restored (states settled, missing phone copies dropped by `exists`).
    func load(exists: (DraftAttachment) -> Bool) -> [String: StoredDraft] {
        guard let data = try? Data(contentsOf: file), let shape = try? JSONDecoder().decode(FileShape.self, from: data), shape.v == 1 else {
            return [:]
        }
        var out: [String: StoredDraft] = [:]
        for (scope, draft) in shape.chats {
            var d = draft
            d.attachments = d.attachments.compactMap { a in
                guard exists(a) else { return nil }
                var b = a
                switch b.upload {
                case .preparing, .uploading: b.upload = .waiting
                default: break
                }
                return b
            }
            if !d.text.isEmpty || !d.attachments.isEmpty { out[scope] = d }
        }
        return out
    }

    /// Saves `chats` (the newest 50 by `updatedAt`) 0.5 s after the last call.
    func save(_ chats: [String: StoredDraft]) {
        lock.lock()
        pending = Self.trimmed(chats)
        generation += 1
        let mine = generation
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.write(ifGeneration: mine) }
    }

    /// Writes what is pending now (background / tests).
    func flush() {
        queue.sync { write(ifGeneration: nil) }
    }

    func remove() {
        lock.lock()
        pending = nil
        generation += 1
        lock.unlock()
        queue.async { [file] in try? FileManager.default.removeItem(at: file) }
    }

    static func trimmed(_ chats: [String: StoredDraft]) -> [String: StoredDraft] {
        let kept = chats.filter { !$0.value.text.isEmpty || !$0.value.attachments.isEmpty }
        guard kept.count > maxChats else { return kept }
        let newest = kept.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(maxChats)
        return Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }

    private func write(ifGeneration wanted: Int?) {
        lock.lock()
        if let wanted, wanted != generation { lock.unlock(); return }
        guard let chats = pending else { lock.unlock(); return }
        pending = nil
        lock.unlock()
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if chats.isEmpty {
                try? FileManager.default.removeItem(at: file)
                return
            }
            let data = try JSONEncoder().encode(FileShape(v: 1, chats: chats))
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // A draft that couldn't be written stays in memory for this run.
        }
    }
}
