// [share] Keeps the App Group's roster and faces up to date for the share sheet (docs/spec/3x-share.md §7.5).
// Port of build 240's src/share-roster.ts:74-113 (debounce, write only when changed) and DispatchShare.swift.
//
// `schedule` restarts a 0.8 s timer on the main actor and does nothing else there; everything that costs time (the
// Keychain peek, the rows, drawing faces, comparing with the file, writing) runs on one utility queue. A write for an
// account that is no longer the current one when the queue runs is dropped, and `clear()` wins over a write in flight.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os

/// [ship, m9: share + photoheads] A bot's own photo for the sheet: the kept file and the picture's fingerprint.
nonisolated struct SharePhoto: Sendable, Equatable {
    let fingerprint: String
    let url: URL
}

@MainActor
final class ShareRosterWriter {
    /// This build's writer; nil-store (the native identity has no App Group) makes every call a no-op.
    static let shared = ShareRosterWriter(store: ShareStore())

    static let debounce: TimeInterval = 0.8

    private let worker: Worker
    private let delay: TimeInterval
    private var timer: DispatchWorkItem?
    private var pending: (bots: [Bot], account: String, gateway: String?)?
    private let photo: @MainActor (Bot) -> SharePhoto?

    /// `current`: the account the Keychain names as signed in right now. `face`: a bot's head as PNG data. `photo`: the
    /// photo a bot wears instead of its head, if it wears one (asked on the main actor when the write starts).
    init(store: ShareStore?, current: @escaping @Sendable () -> StoredAccount? = { AccountVault.app.peek() },
         face: @escaping @Sendable (Bot) -> Data? = ShareRosterWriter.face(for:),
         photo: @escaping @MainActor (Bot) -> SharePhoto? = ShareRosterWriter.photo(for:), delay: TimeInterval = ShareRosterWriter.debounce,
         limit: @escaping @Sendable () -> Int = { Int(AttachmentStaging.maxItemBytes) }) {
        worker = Worker(store: store, current: current, face: face, limit: limit)
        self.photo = photo
        self.delay = delay
    }

    /// The photos of the bots that wear one, by profile.
    private func photos(_ bots: [Bot]) -> [String: SharePhoto] {
        var found: [String: SharePhoto] = [:]
        for bot in bots { if let picture = photo(bot) { found[bot.id] = picture } }
        return found
    }

    var enabled: Bool { worker.store != nil }

    /// The Bots list changed for `account` (`GatewayAccount.id`): write the roster once it has been quiet for 0.8 s.
    /// `gateway`: the gateway's name for the sheet's "Send to" header, nil when only one gateway is saved.
    func schedule(bots: [Bot], account: String, gateway: String? = nil) {
        guard enabled else { return }
        pending = (bots, account, gateway)
        timer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.fire() }
        timer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func fire() {
        timer = nil
        guard let job = pending else { return }
        pending = nil
        worker.write(bots: job.bots, account: job.account, gateway: job.gateway, photos: photos(job.bots), completion: nil)
    }

    /// Tests: whatever is scheduled is written now; answers whether a file was written.
    @discardableResult
    func writeNow() async -> Bool {
        timer?.cancel()
        timer = nil
        guard let job = pending else { return await worker.idle() }
        pending = nil
        let photos = photos(job.bots)
        return await withCheckedContinuation { continuation in
            worker.write(bots: job.bots, account: job.account, gateway: job.gateway, photos: photos) { continuation.resume(returning: $0) }
        }
    }

    /// Sign-out, a gateway switch, a launch with nobody signed in: the sheet offers nobody until the app has a
    /// signed-in roster again. Gone when this returns.
    func clear() {
        timer?.cancel()
        timer = nil
        pending = nil
        worker.clear()
    }

    /// The roster on disk belongs to another account than `key` (`StoredAccount.key`): it goes.
    func clear(unlessFor key: String) {
        guard enabled else { return }
        worker.clear(unlessFor: key)
    }

    /// A bot's face for the sheet: its head as the Bots list draws it, 120 px, light, PNG (spec D7). One function, so a
    /// later stream can return a chosen photo here. Drawn off the main thread (`HeadRenderer.picture` is the drawing
    /// `HeadImageCache` caches; same head, size, scale and appearance).
    nonisolated static func face(for bot: Bot) -> Data? {
        let head = Head.resolve(bot.head, profile: bot.id)
        guard let image = HeadRenderer.picture(head, side: 120, scale: 1, dark: false) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length > 0 else { return nil }
        return data as Data
    }

    /// [ship, m9: share + photoheads] The photo a bot wears in the app (Edit Bot › Upload), so the sheet shows the same
    /// face as the Bots list. nil for a bot that wears its head.
    static func photo(for bot: Bot) -> SharePhoto? { BotFaces.shared.sharePhoto(bot.id) }

    /// A photo as the sheet's 120 px square PNG (aspect fill, centred; the sheet cuts the corners itself). Read and
    /// drawn with ImageIO and CoreGraphics only, off the main thread. nil when the file cannot be read or drawn (it may
    /// still be on its way to disk): the bot then keeps its head until the faces change again.
    nonisolated static func photoPNG(at url: URL, side: Int = 120) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let wide = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let high = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              wide >= 1, high >= 1 else { return nil }
        // The short edge must cover the square; a very long strip is still decoded small.
        let longest = max(wide, high), shortest = min(wide, high)
        let pixels = min(longest, (Double(side) * longest / shortest).rounded(.up))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(1, Int(pixels))]
        guard let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              small.width >= 1, small.height >= 1,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        let scale = max(Double(side) / Double(small.width), Double(side) / Double(small.height))
        let width = Double(small.width) * scale, height = Double(small.height) * scale
        context.draw(small, in: CGRect(x: (Double(side) - width) / 2, y: (Double(side) - height) / 2, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length > 0 else { return nil }
        return data as Data
    }

    // MARK: The queue's side

    private nonisolated final class Worker: @unchecked Sendable {
        let store: ShareStore?
        private let current: @Sendable () -> StoredAccount?
        private let face: @Sendable (Bot) -> Data?
        /// [settings] Settings › Largest Attachment, in bytes, asked at each write.
        private let limit: @Sendable () -> Int
        private let queue = DispatchQueue(label: "hq.share.roster", qos: .utility)
        /// Bumped by `clear()`: a write that started before it stops at its next step.
        private let generation = OSAllocatedUnfairLock(initialState: 0)

        init(store: ShareStore?, current: @escaping @Sendable () -> StoredAccount?, face: @escaping @Sendable (Bot) -> Data?,
             limit: @escaping @Sendable () -> Int) {
            self.store = store; self.current = current; self.face = face; self.limit = limit
        }

        func write(bots: [Bot], account: String, gateway: String? = nil, photos: [String: SharePhoto] = [:],
                   completion: (@Sendable (Bool) -> Void)?) {
            guard let store else { completion?(false); return }
            let started = generation.withLock { $0 }
            queue.async { [self] in
                // The write happens whether or not anyone waits for its answer (`completion?(run(…))` would skip it).
                let wrote = run(bots: bots, account: account, gateway: gateway, photos: photos, store: store, started: started)
                completion?(wrote)
            }
        }

        /// Waits for the queue to be empty (tests).
        func idle() async -> Bool {
            await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: false) } }
        }

        private func live(_ started: Int) -> Bool { generation.withLock { $0 == started } }

        private func run(bots: [Bot], account: String, gateway: String?, photos: [String: SharePhoto], store: ShareStore,
                         started: Int) -> Bool {
            // The bots are `account`'s; they are written only while the Keychain still names it as signed in.
            guard live(started), let stored = current(), stored.hasSession, stored.gatewayAccount?.id == account else { return false }
            let key = stored.key
            var rows = ShareRosterRows.rows(bots)
            var pictures: [String: Data] = [:]
            // [ship, m9: share + photoheads] A bot that wears a photo is listed under the photo's name, with the photo as
            // its picture. One that cannot be drawn right now keeps its head's name and picture: a head is never kept
            // under a photo's name.
            for index in rows.indices {
                guard live(started) else { return false }
                guard let photo = photos[rows[index].profile] else { continue }
                let imageKey = "photo:" + photo.fingerprint
                let name = ShareRosterRows.avatarName(account: key, profile: rows[index].profile, imageKey: imageKey)
                if store.hasPicture(name) {
                    rows[index].imageKey = imageKey
                } else if let data = autoreleasepool(invoking: { ShareRosterWriter.photoPNG(at: photo.url) }) {
                    rows[index].imageKey = imageKey
                    pictures[name] = data
                }
            }
            let shared = ShareRosterRows.bots(rows, account: key)
            var drawn: [String: Bot] = [:]
            for bot in bots { drawn[bot.id] = bot }
            for row in shared {
                guard live(started) else { return false }
                guard let name = row.avatar, !store.hasPicture(name), pictures[name] == nil, let bot = drawn[row.profile] else { continue }
                if let data = autoreleasepool(invoking: { face(bot) }) { pictures[name] = data }
            }
            // A bot whose face could not be drawn gets its initial in the sheet, not a name for a file that is not there.
            let listed = shared.map { bot -> ShareBot in
                guard let name = bot.avatar, pictures[name] == nil, !store.hasPicture(name) else { return bot }
                return ShareBot(key: bot.key, name: bot.name, profile: bot.profile, session: bot.session, color: bot.color,
                                avatar: nil, lastActive: bot.lastActive)
            }
            let limit = self.limit()
            if pictures.isEmpty, let old = store.roster, old.account == key, old.bots == listed, old.limitBytes == limit,
               old.url == stored.url, old.username == stored.username, old.gateway == gateway { return false }
            let roster = ShareRoster(account: key, url: stored.url, username: stored.username, limitBytes: limit, bots: listed,
                                     savedAt: Date().timeIntervalSince1970, gateway: gateway)
            guard live(started), current()?.key == key else { return false }
            do { try store.save(roster, pictures: pictures) } catch { return false }
            // A sign-out or a switch that began while the file was being written wins.
            if !live(started) { store.clear(); return false }
            return true
        }

        func clear() {
            guard let store else { return }
            generation.withLock { $0 += 1 }
            queue.sync { store.clear() }
        }

        func clear(unlessFor key: String) {
            guard let store else { return }
            // In line with the writes: one enqueued before this has finished, one enqueued after is the new account's.
            queue.async {
                guard let roster = store.roster, roster.account != key else { return }
                store.clear()
            }
        }
    }
}
