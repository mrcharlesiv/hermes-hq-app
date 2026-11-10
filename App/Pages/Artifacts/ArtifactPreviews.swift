// Image previews for Artifacts (docs/spec/1x-pages.md §5.5–§5.6): bytes through `read-data-url` (or a data URL, or
// an https image from a public host fetched without gateway credentials, `RemoteImageFetch`), decoded with ImageIO at
// the tile's pixel size off the main thread, kept in `ArtifactThumbs`; full-size images for the viewer likewise. A session
// read again reads its previews again. Four reads at a time, newest request first; a tile scrolled away drops its queued read.
// Owner 2026-11-01 ("Every time I open the artifacts page, it seems like it has to like reload and repopulate
// everything"): each page made its own previews, so every visit read every picture again. They live in `ArtifactThumbs`
// now, shared by every Artifacts page and kept on disk; a chat read again keeps its pictures up while fresh ones load.

import CryptoKit
import ImageIO
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ArtifactPreviews {
    enum State { case loading, image(UIImage), failed(String, missing: Bool, hosted: Bool) }

    private let client: any GatewayClient
    private let account: GatewayAccount
    private let thumbs = ArtifactThumbs.shared
    private var failures: [String: (text: String, missing: Bool, hosted: Bool, transient: Bool)] = [:]
    private var inFlight: [String: Task<Void, Never>] = [:]
    private var waiting: [(String, () -> Void)] = []
    /// Disk reads started by this page (an id and size), so a miss goes to the gateway once.
    private var diskAsked: Set<String> = []
    private var running = 0
    private let slots = 4
    /// Called on the main actor when an artifact's preview landed or failed.
    var onUpdate: ((String) -> Void)?

    init(client: any GatewayClient, account: GatewayAccount) {
        self.client = client
        self.account = account
    }

    /// A kept picture shows (even one about to be read again, or a smaller one while a bigger one loads).
    func isTiny(_ record: ArtifactRecord) -> Bool { record.kind == .image && thumbs.isTiny(account, record.id) }

    func state(_ record: ArtifactRecord) -> State {
        if let image = thumbs.image(account, record.id) { return .image(image) }
        if let failure = failures[record.id] { return .failed(failure.text, missing: failure.missing, hosted: failure.hosted) }
        return .loading
    }

    /// Ask for a tile's preview (`pixels` on its long side): from disk when it was kept, else from the gateway.
    func request(_ record: ArtifactRecord, pixels: CGFloat) {
        let id = record.id, size = ArtifactThumbs.size(for: pixels)
        guard !thumbs.isFresh(account, id, size), failures[id] == nil, inFlight[id] == nil,
              !waiting.contains(where: { $0.0 == id }) else { return }
        if !thumbs.isStale(account, id), diskAsked.insert(id + "|" + size.rawValue).inserted {
            inFlight[id] = Task { [weak self, account, thumbs] in
                let kept = await thumbs.fromDisk(account, id, size)
                guard let self else { return }
                self.inFlight[id] = nil
                if kept != nil { self.onUpdate?(id) } else { self.request(record, pixels: pixels) }
            }
            return
        }
        let start = { [weak self] in self?.load(record, size: size) ?? () }
        if running < slots { start() } else { waiting.append((id, start)) }
    }

    /// A tile left the screen: its read, if still queued, is dropped (asked again when it shows).
    func drop(_ id: String) {
        waiting.removeAll { $0.0 == id }
    }

    private func load(_ record: ArtifactRecord, size: ArtifactThumbs.Size) {
        running += 1
        let client = self.client, started = Date()
        inFlight[record.id] = Task { [weak self] in
            do {
                let data = try await ArtifactFiles.imageData(client, record)
                let image = await Self.decode(data, maxPixels: ArtifactThumbs.pixels(size))
                guard let self else { return }
                // A failure is recorded even under a kept picture (`state` shows the picture first): it stops the
                // tile asking again each time it's drawn.
                if let image {
                    self.thumbs.keep(image, self.account, record.id, size, readAt: started)
                } else {
                    self.failures[record.id] = ("This image could not be decoded.", false, false, false)
                }
            } catch {
                guard let self else { return }
                // [offline] A link failure is still recorded (the tile shows it, and asking again at once would spin
                // while the outage gate fails reads instantly), marked so gateway.ready or the page's return retries it.
                self.failures[record.id] = (ArtifactFiles.failureText(error, image: true), ArtifactFiles.isMissing(error),
                                            ArtifactFiles.isHostedElsewhere(error), ArtifactFiles.isTransient(error))
                if ArtifactFiles.isMissing(error) { self.thumbs.remove(self.account, record.id) }
            }
            self?.finished(record.id)
        }
    }

    private func finished(_ id: String) {
        inFlight[id] = nil
        running -= 1
        onUpdate?(id)
        // Newest first: the tiles on screen now asked last.
        if !waiting.isEmpty { waiting.removeLast().1() }
    }

    /// Full size for the viewer (not cached beyond the tile's own).
    func fullImage(_ record: ArtifactRecord) async throws -> UIImage {
        let data = try await ArtifactFiles.imageData(client, record)
        guard let image = await Self.decode(data, maxPixels: 4096) else { throw PagesMessageError("This image could not be decoded.") }
        return image
    }

    /// Sessions read again: their previews kept from before `keptBefore` are read again (a file may have been rewritten
    /// in place); the kept ones stay up until the fresh ones land. A preview read since is fresh: the first pass read
    /// every tile's picture once more at its end, as each one came from a session that pass had read.
    func forget(sessions: [ArtifactSessionRow], in records: [ArtifactRecord], keptBefore: Date = .distantFuture) {
        let ids = Set(sessions.map(\.id))
        for record in records where ids.contains(record.sessionId) && !thumbs.keptSince(account, record.id, keptBefore) {
            thumbs.markStale(account, record.id)
            failures[record.id] = nil
        }
    }

    /// Pull to refresh clears preview failures.
    func clearFailures() { failures = [:] }

    func clearFailure(_ id: String) { failures[id] = nil }

    /// Forgets the failures the link caused (not a missing or refused file); true when there were any.
    func retryTransient() -> Bool {
        let before = failures.count
        failures = failures.filter { !$0.value.transient }
        return failures.count != before
    }

    @concurrent
    nonisolated static func decode(_ data: Data, maxPixels: CGFloat) async -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixels)),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// The Artifacts pictures kept beyond one page: image previews (two sizes: tiles, and the larger pinned cards) and the
/// pictures of pinned pages (one per look). One memory cache for every Artifacts page (the tab, More's page, Pinned,
/// Bot Info), with a copy in Caches/pages/preview/<account>/thumbs, so a page opened again, or after a relaunch, draws
/// them in its first moments instead of reading each one from the gateway. Sign-out removes the folder
/// (`PagesCache.purge`).
@MainActor
final class ArtifactThumbs {
    static let shared = ArtifactThumbs()

    enum Size: String, CaseIterable { case small = "s", large = "l" }
    /// Tiles and Bot Info's strip read the small size; pinned cards the large one.
    nonisolated static func size(for pixels: CGFloat) -> Size { pixels <= smallPixels ? .small : .large }
    nonisolated static func pixels(_ size: Size) -> CGFloat { size == .small ? smallPixels : 1600 }
    nonisolated static let smallPixels: CGFloat = 512
    /// The most pictures kept on disk per account (the oldest go first).
    nonisolated static let diskLimit = 800

    private let memory = NSCache<NSString, UIImage>()
    /// Pictures whose chat was read again: shown until a fresh copy lands (account|id).
    private var stale: Set<String> = []
    /// When each preview was last read from the gateway this run (account|id; one from disk has none).
    private var keptAt: [String: Date] = [:]
    /// Page pictures drawn this run, by the chat's generation (`PageSnapshots`) they were drawn at, and when.
    private var pagesDrawn: [String: (generation: Int, at: Date)] = [:]
    private var pruned: Set<String> = []

    private init() {
        memory.totalCostLimit = 64 << 20
    }

    private func key(_ account: GatewayAccount, _ id: String) -> String { account.id + "\u{1F}" + id }
    private func memoryKey(_ account: GatewayAccount, _ id: String, _ size: Size) -> NSString { (key(account, id) + "|" + size.rawValue) as NSString }

    nonisolated static func folder(_ account: GatewayAccount) -> URL {
        PagesCache.directory(for: account, root: PagesCache.previewRoot).appending(path: "thumbs", directoryHint: .isDirectory)
    }

    nonisolated static func fileURL(_ account: GatewayAccount, _ id: String, _ tag: String) -> URL {
        let hash = SHA256.hash(data: Data(id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return folder(account).appending(path: "\(hash)-\(tag)")
    }

    // MARK: Image previews

    /// The kept preview in memory, the larger first.
    func image(_ account: GatewayAccount, _ id: String) -> UIImage? {
        memory.object(forKey: memoryKey(account, id, .large)) ?? memory.object(forKey: memoryKey(account, id, .small))
    }

    /// Owner 2026-11-03 ("Why am I flooded with these artifacts?"): an email footer's icons and logos (20×20, 133×23)
    /// are nobody's artifact. A picture this small in its own pixels (previews are never drawn larger than the file) is
    /// left out of the Artifacts pictures once it has loaded; a pin of one still shows.
    nonisolated static func isTiny(_ image: UIImage) -> Bool {
        let width = image.size.width * image.scale, height = image.size.height * image.scale
        return max(width, height) < 64 || width * height < 64 * 64
    }

    /// The kept preview is an icon-sized picture (false while none is kept).
    func isTiny(_ account: GatewayAccount, _ id: String) -> Bool { image(account, id).map(Self.isTiny) ?? false }

    /// In memory at this size or larger, and its chat not read again since.
    func isFresh(_ account: GatewayAccount, _ id: String, _ size: Size) -> Bool {
        guard !stale.contains(key(account, id)) else { return false }
        return memory.object(forKey: memoryKey(account, id, .large)) != nil
            || (size == .small && memory.object(forKey: memoryKey(account, id, .small)) != nil)
    }

    func isStale(_ account: GatewayAccount, _ id: String) -> Bool { stale.contains(key(account, id)) }

    /// Read from the gateway at or after `date` (this run), and not stale since.
    func keptSince(_ account: GatewayAccount, _ id: String, _ date: Date) -> Bool {
        !stale.contains(key(account, id)) && (keptAt[key(account, id)].map { $0 >= date } ?? false)
    }

    /// `readAt`: when its read began (a file rewritten after then isn't in it).
    func keep(_ image: UIImage, _ account: GatewayAccount, _ id: String, _ size: Size, readAt: Date = Date()) {
        stale.remove(key(account, id))
        keptAt[key(account, id)] = readAt
        put(image, memoryKey(account, id, size))
        save(image, to: Self.fileURL(account, id, size.rawValue), account: account)
    }

    /// The disk copy at this size, into memory (nil when there is none).
    func fromDisk(_ account: GatewayAccount, _ id: String, _ size: Size) async -> UIImage? {
        let url = Self.fileURL(account, id, size.rawValue)
        guard let image = await Self.read(url, maxPixels: Self.pixels(size)) else { return nil }
        // A fresh read may have landed meanwhile (or the chat was read again): it wins.
        guard memory.object(forKey: memoryKey(account, id, size)) == nil, !stale.contains(key(account, id)) else {
            return memory.object(forKey: memoryKey(account, id, size))
        }
        put(image, memoryKey(account, id, size))
        return image
    }

    /// The chat was read again: the picture stays up, the next ask reads the gateway, and the disk copy goes (a run
    /// that ends first reads it afresh next time).
    func markStale(_ account: GatewayAccount, _ id: String) {
        stale.insert(key(account, id))
        let urls = Size.allCases.map { Self.fileURL(account, id, $0.rawValue) }
        PagesCache.writer.async { for url in urls { try? FileManager.default.removeItem(at: url) } }
    }

    /// The file is gone from the gateway.
    func remove(_ account: GatewayAccount, _ id: String) {
        for size in Size.allCases { memory.removeObject(forKey: memoryKey(account, id, size)) }
        markStale(account, id)
    }

    // MARK: Page pictures

    /// A pinned page's last picture (`look`: "d" or "l"), from memory.
    func page(_ account: GatewayAccount, _ pinKey: String) -> UIImage? {
        memory.object(forKey: memoryKey(account, "page:" + pinKey, .large))
    }

    /// The disk copy of a page's last picture, into memory.
    func pageFromDisk(_ account: GatewayAccount, _ pinKey: String) async -> UIImage? {
        if let known = page(account, pinKey) { return known }
        let id = "page:" + pinKey
        guard let image = await Self.read(Self.fileURL(account, id, "p"), maxPixels: 4096) else { return nil }
        if let known = page(account, pinKey) { return known }
        put(image, memoryKey(account, id, .large))
        return image
    }

    /// Whether the page was drawn this run at the chat's current generation (else it is drawn again, the last picture
    /// staying up meanwhile).
    func pageIsCurrent(_ account: GatewayAccount, _ pinKey: String, generation: Int) -> Bool {
        pagesDrawn[key(account, pinKey)]?.generation == generation
    }

    /// Drawn this run at or after `date`.
    func pageDrawnSince(_ account: GatewayAccount, _ pinKey: String, _ date: Date) -> Bool {
        pagesDrawn[key(account, pinKey)].map { $0.at >= date } ?? false
    }

    /// `image` nil: the page couldn't be drawn (the last picture, if any, stays). `askedAt`: when the draw was asked
    /// (its file is read after then).
    func keepPage(_ image: UIImage?, _ account: GatewayAccount, _ pinKey: String, generation: Int, askedAt: Date) {
        let id = "page:" + pinKey
        pagesDrawn[key(account, pinKey)] = (generation, askedAt)
        guard let image else { return }
        put(image, memoryKey(account, id, .large))
        save(image, to: Self.fileURL(account, id, "p"), account: account)
    }

    // MARK: Memory and disk

    private func put(_ image: UIImage, _ key: NSString) {
        let pixels = image.size.width * image.size.height * image.scale * image.scale
        memory.setObject(image, forKey: key, cost: Int(pixels * 4))
    }

    /// Written off the main thread: JPEG, or PNG for a picture with see-through parts. Once a run, the folder is cut
    /// back to `diskLimit` (the least recently written go).
    private func save(_ image: UIImage, to url: URL, account: GatewayAccount) {
        guard let cg = image.cgImage else { return }
        let prune = pruned.insert(account.id).inserted
        PagesCache.writer.async {
            guard let data = Self.encode(cg) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic])
            if prune { Self.prune(url.deletingLastPathComponent(), keep: Self.diskLimit) }
        }
    }

    nonisolated static func encode(_ cg: CGImage) -> Data? {
        let alpha: Bool = switch cg.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
        let data = NSMutableData()
        let type = (alpha ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cg, alpha ? nil : [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    nonisolated static func prune(_ folder: URL, keep: Int) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys),
              files.count > keep else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - keep) { try? FileManager.default.removeItem(at: url) }
    }

    @concurrent
    nonisolated static func read(_ url: URL, maxPixels: CGFloat) async -> UIImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return await ArtifactPreviews.decode(data, maxPixels: maxPixels)
    }

    /// Tests: memory and this run's marks go (the disk copies stay).
    func forgetMemory() {
        memory.removeAllObjects()
        stale = []
        keptAt = [:]
        pagesDrawn = [:]
    }
}
