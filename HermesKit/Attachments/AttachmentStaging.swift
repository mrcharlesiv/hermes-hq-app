// The phone's own copies of picked photos and files (docs/spec/1x-attachments.md §5.4–§5.5, §6.6): one UUID folder
// per attachment under Application Support/HQNAttachments/<account key>/, backup-excluded, written so an upload keeps
// reading them while the phone is locked. Folders leave when their attachment does (removed, sent and seeded), and a
// launch sweep takes what nothing references any more. Thread-safe; file work never runs on the main thread except
// a removal the user asked for (small).

import Foundation
import CryptoKit
import Synchronization

nonisolated final class AttachmentStaging: Sendable {
    /// Per item, after preparation (spec §3.9, A12: fixed this round).
    /// [settings] Settings › Largest Attachment (1…100 MB, 100 unless the person lowered it).
    static var maxItemBytes: Int64 { AttachmentLimit.bytes }
    /// Per message (A11: Hermes expands at most 16 `@`-references).
    static let maxPerMessage = 16
    /// Per pick (Photos `selectionLimit`, the first Files URLs).
    static let maxPerPick = 8

    let root: URL
    private let pendingRemovals = Mutex<[String: Int]>([:])

    init(accountId: String, base: URL? = nil) {
        let support = base ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        root = support.appending(path: "HQNAttachments", directoryHint: .isDirectory)
            .appending(path: AttachmentStaging.accountKey(accountId), directoryHint: .isDirectory)
    }

    /// A short stable folder name for an account id (never the id itself: it holds the gateway's address).
    static func accountKey(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Folders

    /// A fresh folder for attachment `id` (a UUID string). Backup-excluded.
    func makeFolder(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        let folder = root.appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var marked = folder
        try? marked.setResourceValues(values)
        return folder
    }

    /// The file behind `localFile` ("<uuid>/<name>"), only ever inside this root and a UUID folder (spec §5.4).
    func url(forLocalFile localFile: String) -> URL? {
        let parts = localFile.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil, !parts[1].isEmpty, parts[1] != ".", parts[1] != "..",
              !parts[1].contains("\\") else { return nil }
        return root.appending(path: String(parts[0]), directoryHint: .isDirectory).appending(path: String(parts[1]))
    }

    func url(for attachment: DraftAttachment) -> URL? { url(forLocalFile: attachment.localFile) }

    func exists(_ attachment: DraftAttachment) -> Bool {
        if attachment.kind == .link { return true }       // a link has no file
        guard let url = url(for: attachment) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Deletes attachment `id`'s folder now.
    func remove(_ id: String) {
        guard UUID(uuidString: id) != nil else { return }
        try? FileManager.default.removeItem(at: root.appending(path: id, directoryHint: .isDirectory))
    }

    /// Deletes the folder after `delay` (the last owner let go, spec §6.6: 1 s), unless `keep` says it is wanted again.
    func removeLater(_ id: String, after delay: TimeInterval = 1, keep: @escaping @Sendable () -> Bool = { false }) {
        let token = pendingRemovals.withLock { pending -> Int in
            let next = (pending[id] ?? 0) + 1
            pending[id] = next
            return next
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let current = self.pendingRemovals.withLock { pending -> Bool in
                guard pending[id] == token else { return false }
                pending[id] = nil
                return true
            }
            if current && !keep() { self.remove(id) }
        }
    }

    /// Everything under this account (sign-out).
    func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Launch sweep (spec §6.6): folders nothing references and older than `age`. Returns the removed ids.
    @discardableResult
    func sweep(keeping referenced: Set<String>, olderThan age: TimeInterval = 600, now: Date = Date()) -> [String] {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isDirectoryKey]
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys)) ?? []
        var removed: [String] = []
        for folder in folders {
            let id = folder.lastPathComponent
            guard UUID(uuidString: id) != nil, !referenced.contains(id) else { continue }
            let values = try? folder.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true else { continue }
            let stamp = [values?.creationDate, values?.contentModificationDate].compactMap { $0 }.max() ?? now
            guard now.timeIntervalSince(stamp) >= age else { continue }
            if (try? FileManager.default.removeItem(at: folder)) != nil { removed.append(id) }
        }
        return removed
    }

    // MARK: Writing

    /// Copies `source` into attachment `id`'s folder as `name` (a picked file, a video), refusing one over the limit
    /// before copying. The copy is protected `.completeUnlessOpen` (an upload keeps reading it after the phone locks).
    func copyIn(_ source: URL, id: String, name: String, limit: Int64 = AttachmentStaging.maxItemBytes) throws -> URL {
        let size = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard size <= limit else { throw AttachmentPrepareError.tooLarge(name: name) }
        let folder = try makeFolder(id)
        let target = folder.appending(path: name)
        do {
            try FileManager.default.copyItem(at: source, to: target)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: target.path)
            return target
        } catch {
            remove(id)
            throw error
        }
    }

    /// Writes `data` as attachment `id`'s file `name`.
    func write(_ data: Data, id: String, name: String) throws -> URL {
        guard Int64(data.count) <= Self.maxItemBytes else { throw AttachmentPrepareError.tooLarge(name: name) }
        let folder = try makeFolder(id)
        let target = folder.appending(path: name)
        do {
            try data.write(to: target, options: [.atomic, .completeFileProtectionUnlessOpen])
            return target
        } catch {
            remove(id)
            throw error
        }
    }

    // MARK: Names (PickedFiles.safeName, R:ios/App/App/PickedFiles.swift:131-149)

    /// Last path component; control characters and `" \ / :` dropped; empty, `.` or `..` → `attachment`; at most
    /// 180 UTF-8 bytes, keeping an extension of ≤ 32 bytes; cut at whole Unicode scalars.
    static func safeName(_ raw: String) -> String {
        let name = (raw as NSString).lastPathComponent
        let filtered = String(String.UnicodeScalarView(name.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !"\"\\/:".unicodeScalars.contains($0)
        }))
        if filtered.isEmpty || filtered == "." || filtered == ".." { return "attachment" }
        if filtered.utf8.count <= 180 { return filtered }
        let ext = (filtered as NSString).pathExtension
        let suffix = !ext.isEmpty && ext.utf8.count <= 32 ? "." + ext : ""
        let stem = suffix.isEmpty ? filtered : String(filtered.dropLast(suffix.count))
        var cleaned = ""
        for scalar in stem.unicodeScalars {
            guard cleaned.utf8.count + scalar.utf8.count + suffix.utf8.count <= 180 else { break }
            cleaned.unicodeScalars.append(scalar)
        }
        return cleaned + suffix
    }

    /// A name's stem (no extension), for "<stem>.jpg".
    static func stem(_ name: String) -> String {
        let s = (name as NSString).deletingPathExtension
        return s.isEmpty ? "photo" : s
    }
}

/// Why a pick couldn't become an attachment (alert "Couldn't Attach", spec §4.6).
nonisolated enum AttachmentPrepareError: Error, Equatable, LocalizedError {
    case tooLarge(name: String)
    case unreadablePhoto
    case unreadableFile
    case locationNotRemoved
    case cameraNotSaved
    case limitReached
    case cancelled

    var errorDescription: String? {
        switch self {
        case .tooLarge(let name): return AttachmentLimit.refusal(name: name)   // [settings] the limit set in Settings, this build's name
        case .unreadablePhoto: return "Couldn’t read the selected photo or video."
        case .unreadableFile: return "Couldn’t read the selected file."
        case .locationNotRemoved: return "Couldn’t remove this video’s location, so it wasn’t attached."
        case .cameraNotSaved: return "Couldn’t save the camera photo."
        case .limitReached: return "You can attach up to 16 items to one message."
        case .cancelled: return nil
        }
    }
}
