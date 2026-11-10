// Where chat media lives on the phone (docs/spec/1x-attachments.md §8.1): per account under
// Caches/HQNMedia/<account key>/ — `originals/<sha256(key)>` (images as the gateway sent them) and
// `files/<sha256(key)>/<name>` (file previews, named for Quick Look) — LRU by bytes, 256 MiB in all; decoded
// thumbnails in an `NSCache` (64 MB of cost, emptied on memory warnings). Decoded `data:` parts from history are kept
// by content hash in Caches/HQNMedia/<account key>/inline/ (`InlineMediaStore`), so a re-read of the same page writes
// nothing new; they count toward the account's 256 MiB and go with it on sign-out.
//
// Keys: gateway `"g|<account>|<profile>|<path>"`, remote `"r|<url>"`, inline `"i|<sha256>"`.

import Foundation
import CryptoKit
import Synchronization
import UIKit

nonisolated final class MediaStore: @unchecked Sendable {
    static let byteLimit: Int64 = 256 << 20
    /// Files bigger than this are not kept once their preview closes (spec §8.1).
    static let keepFileLimit: Int64 = 64 << 20

    let root: URL
    private let lock = NSLock()
    private var trimScheduled = false

    init(accountId: String, base: URL? = nil) {
        let caches = base ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        root = caches.appending(path: "HQNMedia", directoryHint: .isDirectory)
            .appending(path: AttachmentStaging.accountKey(accountId), directoryHint: .isDirectory)
    }

    // MARK: Keys

    static func gatewayKey(accountId: String, profile: String, path: String) -> String { "g|\(accountId)|\(profile)|\(path)" }
    static func remoteKey(_ url: URL) -> String { "r|\(url.absoluteString)" }

    static func hash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Originals (images)

    func originalURL(_ key: String) -> URL {
        root.appending(path: "originals", directoryHint: .isDirectory).appending(path: Self.hash(key))
    }

    /// The cached original, if present (its date is touched for the LRU).
    func cachedOriginal(_ key: String) -> URL? {
        let url = originalURL(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        touch(url)
        return url
    }

    /// Copies (or moves) a local file in as `key`'s original (your sent photo, spec §6.4 step 7).
    @discardableResult
    func seedOriginal(_ key: String, from source: URL, move: Bool = false) -> Bool {
        let target = originalURL(key)
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            if move { try FileManager.default.moveItem(at: source, to: target) } else { try FileManager.default.copyItem(at: source, to: target) }
            scheduleTrim()
            return true
        } catch {
            return false
        }
    }

    /// A temporary path next to the original for a download in flight (renamed into place when complete).
    func partialURL(_ key: String) -> URL {
        root.appending(path: "partial", directoryHint: .isDirectory).appending(path: Self.hash(key) + "-" + UUID().uuidString)
    }

    func adoptDownloaded(_ partial: URL, as key: String) -> URL? {
        let target = originalURL(key)
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: partial, to: target)
            scheduleTrim()
            return target
        } catch {
            try? FileManager.default.removeItem(at: partial)
            return nil
        }
    }

    // MARK: Files (Quick Look)

    func fileURL(_ key: String, name: String) -> URL {
        root.appending(path: "files", directoryHint: .isDirectory).appending(path: Self.hash(key), directoryHint: .isDirectory)
            .appending(path: AttachmentStaging.safeName(name))
    }

    func cachedFile(_ key: String, name: String) -> URL? {
        let url = fileURL(key, name: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        touch(url)
        return url
    }

    @discardableResult
    func seedFile(_ key: String, name: String, from source: URL) -> URL? {
        let target = fileURL(key, name: name)
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
            scheduleTrim()
            return target
        } catch {
            return nil
        }
    }

    func adoptDownloadedFile(_ partial: URL, as key: String, name: String) -> URL? {
        let target = fileURL(key, name: name)
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: partial, to: target)
            scheduleTrim()
            return target
        } catch {
            try? FileManager.default.removeItem(at: partial)
            return nil
        }
    }

    /// A big file preview closed: let it go (spec §8.1).
    func previewClosed(_ url: URL) {
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard size > Self.keepFileLimit, url.path.hasPrefix(root.path) else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: Housekeeping

    func purge() {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Something was written under the root by another writer (the inline store): trim soon.
    func noteWrite() { scheduleTrim() }

    private func scheduleTrim() {
        lock.lock()
        let schedule = !trimScheduled
        trimScheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.trimScheduled = false; self.lock.unlock()
            self.trim(to: Self.byteLimit)
        }
    }

    /// How long a big file preview counts as open: it isn't kept past its preview (`previewClosed`), so until then it
    /// stays out of the LRU.
    static let openPreviewSeconds: TimeInterval = 30 * 60

    /// Deletes the least recently used entries until the store holds at most `limit` bytes.
    /// Audit 14-5: a file preview over `keepFileLimit` used in the last `openPreviewSeconds` is open in Quick Look (it
    /// may be up to 512 MB, more than the whole store): it neither counts nor goes, so it isn't deleted under the preview,
    /// nor everything else with it. Its preview closing lets it go; one left behind (the app quit first) goes first.
    func trim(to limit: Int64, now: Date = Date()) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return }
        var entries: [(url: URL, size: Int64, date: Date, bigPreview: Bool)] = []
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            let date = values.contentModificationDate ?? .distantPast
            // files/<hash>/<name>
            let bigPreview = size > Self.keepFileLimit && url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "files"
            if bigPreview, now.timeIntervalSince(date) < Self.openPreviewSeconds { continue }
            total += size
            entries.append((url, size, date, bigPreview))
        }
        guard total > limit else { return }
        for entry in entries.sorted(by: { $0.bigPreview != $1.bigPreview ? $0.bigPreview : $0.date < $1.date }) {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
            if total <= limit { break }
        }
    }
}

/// Decoded `data:` image parts from history, by content hash (spec §7.1 rule 6): written during the off-main fold, so
/// no message text, part or cache entry ever holds the bytes. Per account (spec §6.6, §8.1): under the account's media
/// folder, inside its 256 MiB LRU and purged with it. The fold names the account through `InlineMediaStore.accountId`
/// (a task-local the history reads set); without one (tests) the shared, account-less folder is used.
nonisolated final class InlineMediaStore: @unchecked Sendable {
    /// The account whose history is being folded on this task.
    @TaskLocal static var accountId: String?

    /// The account-less folder (Caches/HQNMedia/inline): tests, and parts decoded before folders were per account.
    static let shared = InlineMediaStore()
    /// Decoded size limit for one part (spec §3.9).
    static let maxBytes = 32 << 20

    private static let perAccount = Mutex<[String: InlineMediaStore]>([:])

    /// The store for `accountId` (the shared one for nil).
    static func forAccount(_ accountId: String?) -> InlineMediaStore {
        guard let accountId, !accountId.isEmpty else { return shared }
        return perAccount.withLock { stores in
            if let known = stores[accountId] { return known }
            let made = InlineMediaStore(accountId: accountId)
            stores[accountId] = made
            return made
        }
    }

    /// The store the running fold writes to.
    static var current: InlineMediaStore { forAccount(accountId) }

    let root: URL
    /// The account's media store (its LRU trim covers this folder).
    private let media: MediaStore?

    init(base: URL? = nil) {
        let caches = base ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        root = caches.appending(path: "HQNMedia", directoryHint: .isDirectory).appending(path: "inline", directoryHint: .isDirectory)
        media = nil
    }

    init(accountId: String, base: URL? = nil) {
        let store = MediaStore(accountId: accountId, base: base)
        media = store
        root = store.root.appending(path: "inline", directoryHint: .isDirectory)
    }

    /// The decoded part behind `key` when it is on the phone (its date touched for the LRU).
    func cachedURL(forKey key: String) -> URL? {
        guard let url = url(forKey: key), FileManager.default.fileExists(atPath: url.path) else { return nil }
        if media != nil { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path) }
        return url
    }

    func url(forKey key: String) -> URL? {
        guard key.hasPrefix("i|") else { return nil }
        let hash = String(key.dropFirst(2))
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return nil }
        return root.appending(path: hash)
    }

    /// Stores decoded bytes; returns their key (`"i|<sha256>"`).
    func store(_ data: Data) -> String {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let target = root.appending(path: hash)
        if !FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? data.write(to: target, options: .atomic)
            media?.noteWrite()
        }
        return "i|" + hash
    }

    func purge() { try? FileManager.default.removeItem(at: root) }
}

/// Decoded images for display, by key and pixel bucket (spec §8.1: 64 MB of cost, emptied on memory warnings).
@MainActor final class MediaMemoryCache {
    static let shared = MediaMemoryCache()
    private let cache = NSCache<NSString, UIImage>()
    private var observer: NSObjectProtocol?

    init() {
        cache.totalCostLimit = 64 << 20
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cache.removeAllObjects() }
        }
    }

    static let buckets = [256, 512, 1024, 2048, 4096]

    static func bucket(_ pixels: Int) -> Int { buckets.first { $0 >= pixels } ?? 4096 }

    private static func cacheKey(_ key: String, _ bucket: Int) -> NSString { "\(key)#\(bucket)" as NSString }

    /// The best cached image for `key` at `bucket` or larger (a smaller one is better than a placeholder: `fallback`).
    func image(_ key: String, bucket: Int, fallback: Bool = true) -> UIImage? {
        for b in Self.buckets where b >= bucket {
            if let hit = cache.object(forKey: Self.cacheKey(key, b)) { return hit }
        }
        guard fallback else { return nil }
        for b in Self.buckets.reversed() where b < bucket {
            if let hit = cache.object(forKey: Self.cacheKey(key, b)) { return hit }
        }
        return nil
    }

    func exact(_ key: String, bucket: Int) -> UIImage? { cache.object(forKey: Self.cacheKey(key, bucket)) }

    func set(_ image: UIImage, key: String, bucket: Int) {
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        cache.setObject(image, forKey: Self.cacheKey(key, bucket), cost: cost)
    }

    func removeAll() { cache.removeAllObjects() }
}
