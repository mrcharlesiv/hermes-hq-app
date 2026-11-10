// Loading chat media (docs/spec/1x-attachments.md §8.2–§8.4): gateway images over `GET /api/fs/download` with the
// account's auth (`session_id` only for relative paths, A8), at most 3 downloads per account at once, written to the
// media store (never buffered in memory) with a 32 MB ceiling; https images through `RemoteImageFetcher`; decoded
// `data:` parts from the inline store; your own sends from their phone copy. Decoding is ImageIO thumbnailing at the
// display size on a detached task — never `UIImage(contentsOfFile:)` on the main thread — and images over 100 MP are
// refused. File previews download the same way with a 512 MB ceiling.

import Foundation
import Synchronization
import UIKit

nonisolated enum MediaLoadError: Error, Equatable, Sendable {
    case notFound          // 404 "File not found"
    case forbidden         // 403 sensitive file
    case tooLarge          // past the ceiling, > 100 MP, or a known `.tooLarge` attachment
    case unreachable       // network / gateway error (retryable)
    case notImage
    case unavailable       // no client for the account (signed out)

    var fileMessage: String {
        switch self {
        case .notFound: return "This file isn’t on your gateway anymore."
        case .forbidden: return "Your gateway keeps this file private."
        case .tooLarge: return "This file is larger than 512 MB, the most \(AppIdentity.current.displayName) can open."
        default: return "Couldn’t reach your gateway. Try again."
        }
    }
}

/// A limit on concurrent work (downloads per account). Waiters are served newest first — the photo just scrolled
/// onto the screen goes before rows long gone (spec §8.2) — and a cancelled waiter leaves the line at once.
actor AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Bool, Never>)] = []
    private var nextId: UInt64 = 0

    init(limit: Int) { self.limit = limit }

    /// Takes a slot (waiting for one). Throws `CancellationError` when the caller is cancelled first; then no slot was
    /// taken and `release()` must not be called.
    func acquire() async throws {
        if running < limit { running += 1; return }
        nextId &+= 1
        let id = nextId
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled { continuation.resume(returning: false); return }
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        if !granted { throw CancellationError() }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    /// Hands the slot to the newest waiter, or frees it.
    func release() {
        if let next = waiters.popLast() { next.continuation.resume(returning: true) } else { running -= 1 }
    }

    var debugWaiting: Int { waiters.count }
}

@MainActor final class MediaLoader {
    static let shared = MediaLoader()

    /// Image downloads (inline display and the viewer).
    /// [settings] Never past Settings › Largest Attachment: a picture over it shows "Photo too large to load".
    nonisolated static var imageCeiling: Int64 { min(32 << 20, AttachmentLimit.bytes) }
    /// File preview / share downloads.
    nonisolated static let fileCeiling: Int64 = 512 << 20

    private var stores: [String: MediaStore] = [:]
    private var limiters: [String: AsyncLimiter] = [:]
    /// Image downloads in flight, by media key, with who waits for them: when the last waiter goes (its tile was
    /// reused or left the screen), the download is cancelled and its partial file deleted (spec §8.2). One already
    /// moving bytes is kept for `orphanGrace` first, so a tile that comes back (a scroll, the viewer closing, the Mac
    /// window shown again) picks it up instead of starting over. On a slow link a 1.7 MB screenshot restarted every
    /// few seconds and never arrived (owner, Mac, 2026-10-30).
    private final class Flight {
        let id = UUID()
        let task: Task<URL, Error>
        let started: FlightStarted
        var waiters: Set<UUID> = []
        /// Counts the times its last waiter went, so only the newest grace period can end it.
        var orphaned = 0
        init(task: Task<URL, Error>, started: FlightStarted) { self.task = task; self.started = started }
    }
    /// Set once a flight has its download slot (still waiting in line, it goes at once when nobody wants it).
    nonisolated final class FlightStarted: Sendable {
        private let flag = Mutex(false)
        func mark() { flag.withLock { $0 = true } }
        var value: Bool { flag.withLock { $0 } }
    }
    /// How long a started download nobody waits for keeps going.
    static var orphanGrace: Duration = .seconds(10)
    private var inflight: [String: Flight] = [:]
    private var fileFlights: [String: Task<URL, Error>] = [:]
    /// Gateway keys whose original was seeded from a phone copy this run (your sent photos).
    private var seeded: Set<String> = []

    func markSeeded(_ key: String) { seeded.insert(key) }

    func store(for accountId: String) -> MediaStore {
        if let known = stores[accountId] { return known }
        let made = MediaStore(accountId: accountId)
        stores[accountId] = made
        return made
    }

    private func limiter(for accountId: String) -> AsyncLimiter {
        if let known = limiters[accountId] { return known }
        let made = AsyncLimiter(limit: 3)
        limiters[accountId] = made
        return made
    }

    /// Sign-out: this account's media goes (originals, previews and decoded inline parts: they all live under its
    /// folder), and so does anything the older shared inline folder still holds.
    func purge(accountId: String) {
        for (_, flight) in inflight { flight.task.cancel() }
        inflight = [:]
        store(for: accountId).purge()
        stores[accountId] = nil
        InlineMediaStore.shared.purge()
        MediaMemoryCache.shared.removeAll()
    }

    /// Joins (or starts, with `make`) the flight for `key`; the caller's cancellation leaves it, and the last one to
    /// leave cancels it (after `orphanGrace` once it has started).
    private func join(_ key: String, make: (FlightStarted) -> Task<URL, Error>) async throws -> URL {
        let flight: Flight
        if let known = inflight[key] {
            flight = known
        } else {
            let started = FlightStarted()
            flight = Flight(task: make(started), started: started)
            inflight[key] = flight
            let task = flight.task, flightId = flight.id
            Task { [weak self] in
                _ = try? await task.value
                if self?.inflight[key]?.id == flightId { self?.inflight[key] = nil }
            }
        }
        let waiter = UUID()
        flight.waiters.insert(waiter)
        let task = flight.task
        defer { leave(key, flight: flight, waiter: waiter) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { @MainActor in MediaLoader.shared.leave(key, flight: flight, waiter: waiter) }
        }
    }

    private func leave(_ key: String, flight: Flight, waiter: UUID) {
        guard flight.waiters.remove(waiter) != nil, flight.waiters.isEmpty else { return }
        guard flight.started.value else { return drop(key, flight) }
        flight.orphaned += 1
        let grace = Self.orphanGrace, turn = flight.orphaned
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: grace)
            guard flight.waiters.isEmpty, flight.orphaned == turn else { return }   // a tile came back for it
            self?.drop(key, flight)
        }
    }

    private func drop(_ key: String, _ flight: Flight) {
        flight.task.cancel()
        if inflight[key]?.id == flight.id { inflight[key] = nil }
    }

    var debugInflight: Int { inflight.count }

    // MARK: Keys

    /// The media key for an attachment in a chat (nil for one with no bytes to show).
    func key(_ a: MessageAttachment, _ context: MediaContext) -> String? {
        switch a.source {
        case .gateway(let path): return MediaStore.gatewayKey(accountId: context.accountId, profile: context.profile, path: path)
        case .inline(let key): return key
        case .remote(let url): return MediaStore.remoteKey(url)
        case .local(let draftId):
            // Seeded under its gateway path once known; until then the phone copy.
            if let path = a.uploadedPath {
                let gateway = MediaStore.gatewayKey(accountId: context.accountId, profile: context.profile, path: path)
                if seeded.contains(gateway) { return gateway }
            }
            return "l|" + draftId
        case .tooLarge: return nil
        }
    }

    /// A decoded image already in memory (no flash on reuse).
    func cachedImage(_ a: MessageAttachment, context: MediaContext, maxPixel: Int) -> UIImage? {
        guard let key = key(a, context) else { return nil }
        if let hit = MediaMemoryCache.shared.image(key, bucket: MediaMemoryCache.bucket(maxPixel)) { return hit }
        // Your sent photo: its tile thumbnail was seeded under the gateway key, or still sits under the draft id.
        if case .local(let id) = a.source { return MediaMemoryCache.shared.image("l|" + id, bucket: 256) }
        return nil
    }

    struct Loaded {
        var image: UIImage
        /// The original's displayed pixel size (for write-back, spec §8.3).
        var pixelWidth: Int
        var pixelHeight: Int
    }

    /// Loads and decodes `a` at `maxPixel` (display points × scale). Throws `MediaLoadError`.
    /// `visible`: a tile on screen (or the viewer) — its download goes at high priority; a look-ahead goes low.
    /// `cache`: false for the viewer's big decodes, which its page keeps itself (one 4096 bitmap would evict the chat's tiles).
    func image(_ a: MessageAttachment, context: MediaContext, maxPixel: Int, priority: TaskPriority = .userInitiated,
               visible: Bool = true, cache: Bool = true) async throws -> Loaded {
        guard let key = key(a, context) else { throw MediaLoadError.tooLarge }
        let bucket = MediaMemoryCache.bucket(maxPixel)
        let url = try await original(a, context: context, visible: visible)
        try Task.checkCancellation()
        let decoded = await Task.detached(priority: priority) { () -> (CGImage, Int, Int)? in
            guard let (w, h) = PhotoNormalizer.pixelSize(of: url), w * h <= RemoteImagePolicy.maxPixels,
                  let image = PhotoNormalizer.thumbnail(url, maxPixel: bucket) else { return nil }
            return (image, w, h)
        }.value
        guard let (cg, w, h) = decoded else {
            if let (w, h) = PhotoNormalizer.pixelSize(of: url), w * h > RemoteImagePolicy.maxPixels { throw MediaLoadError.tooLarge }
            throw MediaLoadError.notImage
        }
        let image = UIImage(cgImage: cg)
        if cache { MediaMemoryCache.shared.set(image, key: key, bucket: bucket) }
        return Loaded(image: image, pixelWidth: w, pixelHeight: h)
    }

    /// The full original on the phone (the viewer, Save, Share): from the store, the phone copy, or downloaded.
    func original(_ a: MessageAttachment, context: MediaContext, visible: Bool = true) async throws -> URL {
        switch a.source {
        case .tooLarge:
            throw MediaLoadError.tooLarge
        case .inline(let key):
            // The account's own folder; the older shared one for parts decoded before it existed.
            for store in [InlineMediaStore.forAccount(context.accountId), InlineMediaStore.shared] {
                if let url = store.cachedURL(forKey: key) { return url }
            }
            throw MediaLoadError.notFound
        case .local(let draftId):
            if let path = a.uploadedPath,
               let seeded = store(for: context.accountId).cachedOriginal(MediaStore.gatewayKey(accountId: context.accountId, profile: context.profile, path: path)) {
                return seeded
            }
            if let center = AttachmentCenter.existing(context.accountId), let item = center.items[draftId],
               let url = center.staging.url(for: item), FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            if let path = a.uploadedPath { return try await gatewayOriginal(path: path, context: context, visible: visible) }
            throw MediaLoadError.notFound
        case .gateway(let path):
            return try await gatewayOriginal(path: path, context: context, visible: visible)
        case .remote(let url):
            let store = store(for: context.accountId)
            let key = MediaStore.remoteKey(url)
            if let hit = store.cachedOriginal(key) { return hit }
            return try await join(key) { started in
                started.mark()
                let target = store.partialURL(key)
                return Task.detached(priority: visible ? .userInitiated : .utility) { () async throws -> URL in
                    do {
                        let got = try await RemoteImageFetcher.shared.fetch(url, to: target)
                        guard let adopted = store.adoptDownloaded(got, as: key) else { throw MediaLoadError.unreachable }
                        return adopted
                    } catch let error as RemoteImageError {
                        try? FileManager.default.removeItem(at: target)
                        AppLog.note("media", "remote image fetch refused: \(error)")
                        switch error {
                        case .tooLarge: throw MediaLoadError.tooLarge
                        case .notImage: throw MediaLoadError.notImage
                        case .refused: throw MediaLoadError.forbidden
                        case .failed: throw MediaLoadError.unreachable
                        }
                    } catch {
                        try? FileManager.default.removeItem(at: target)
                        if !(error is CancellationError) { AppLog.swallowed("media", "fetch a remote image", error) }
                        throw error
                    }
                }
            }
        }
    }

    /// The download query (spec §8.2): `session_id` only for a relative path.
    nonisolated static func downloadQuery(path: String, profile: String, sessionId: String?) -> [URLQueryItem] {
        var query = [URLQueryItem(name: "path", value: path)]
        if !profile.isEmpty { query.append(URLQueryItem(name: "profile", value: profile)) }
        if let sessionId, !sessionId.isEmpty, isRelative(path) { query.append(URLQueryItem(name: "session_id", value: sessionId)) }
        return query
    }

    /// Doesn't start with `/`, `~`, `file:` or a drive letter.
    nonisolated static func isRelative(_ path: String) -> Bool {
        if path.hasPrefix("/") || path.hasPrefix("~") || path.lowercased().hasPrefix("file:") || path.hasPrefix("\\\\") { return false }
        if path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil { return false }
        return true
    }

    private func gatewayOriginal(path: String, context: MediaContext, visible: Bool) async throws -> URL {
        let store = store(for: context.accountId)
        let key = MediaStore.gatewayKey(accountId: context.accountId, profile: context.profile, path: path)
        if let hit = store.cachedOriginal(key) { return hit }
        if inflight[key] == nil, !(AttachmentCenter.existing(context.accountId)?.client is GatewayFileTransfers) {
            throw MediaLoadError.unavailable
        }
        return try await join(key) { started in
            let client = AttachmentCenter.existing(context.accountId)?.client as? GatewayFileTransfers
            let limiter = limiter(for: context.accountId)
            let query = Self.downloadQuery(path: path, profile: context.profile, sessionId: context.storedSessionId)
            let partial = store.partialURL(key)
            let priority = visible ? URLSessionTask.highPriority : URLSessionTask.lowPriority
            // Off the main thread (the store's moves are file work); cancelled by its flight, never by the caller.
            return Task.detached(priority: visible ? .userInitiated : .utility) { () async throws -> URL in
                guard let client else { throw MediaLoadError.unavailable }
                // Waiting for one of the account's 3 slots; a load nobody wants any more leaves the line.
                try await limiter.acquire()
                defer { Task { await limiter.release() } }
                started.mark()
                var retried = false
                while true {
                    do {
                        try Task.checkCancellation()
                        _ = try await client.download("/api/fs/download", query: query, to: partial, ceiling: MediaLoader.imageCeiling,
                                                      priority: priority, progress: nil)
                        break
                    } catch {
                        try? FileManager.default.removeItem(at: partial)     // a cancelled partial file never stays
                        if Task.isCancelled { throw CancellationError() }
                        // [reconnect] Right after app-active the network may not be up yet: the bulk session fails at once
                        // (no waitsForConnectivity). One retry ~400 ms later usually lands; server errors never retry.
                        if !retried, MediaLoader.retriesOnce(error) {
                            retried = true
                            AppLog.trace("media", "image download not ready yet; retrying once")
                            try await Task.sleep(for: MediaLoader.notReadyRetryDelay)
                            continue
                        }
                        let mapped = MediaLoader.map(error)
                        if mapped == .unreachable { AppLog.swallowed("media", "download a gateway image", error) }
                        throw mapped
                    }
                }
                guard let adopted = store.adoptDownloaded(partial, as: key) else { throw MediaLoadError.unreachable }
                return adopted
            }
        }
    }

    // MARK: Files (Quick Look, spec §10)

    /// The file behind a path, downloaded (512 MB ceiling) into the media store, with progress under `progressKey`.
    /// `fresh` downloads again even when a copy is kept (a page a bot rewrites in place), and falls back to the copy
    /// when the download fails.
    func file(path: String, name: String, context: MediaContext, progressKey: String, fresh: Bool = false) async throws -> URL {
        #if DEBUG
        if context.accountId == MediaContext.demoAccount {   // -HQDemoPage: this Mac's file, or a local server's (the Mac app's sandbox)
            guard path.hasPrefix("http"), let remote = URL(string: path) else { return URL(fileURLWithPath: path) }
            let (data, _) = try await URLSession.shared.data(from: remote)
            let local = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: remote.lastPathComponent)
            try data.write(to: local)
            return local
        }
        #endif
        let store = store(for: context.accountId)
        let key = MediaStore.gatewayKey(accountId: context.accountId, profile: context.profile, path: path)
        if fresh, let kept = store.cachedFile(key, name: name) {
            do {
                return try await download(path: path, name: name, context: context, progressKey: progressKey, key: key, store: store)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLog.swallowed("media", "fresh download of a kept file, using the kept copy", error)
                return kept
            }
        }
        if let hit = store.cachedFile(key, name: name) { return hit }
        return try await download(path: path, name: name, context: context, progressKey: progressKey, key: key, store: store)
    }

    private func download(path: String, name: String, context: MediaContext, progressKey: String, key: String,
                          store: MediaStore) async throws -> URL {
        if let flight = fileFlights[key] { return try await flight.value }
        guard let client = AttachmentCenter.existing(context.accountId)?.client as? GatewayFileTransfers else { throw MediaLoadError.unavailable }
        let query = Self.downloadQuery(path: path, profile: context.profile, sessionId: context.storedSessionId)
        let partial = store.partialURL(key)
        let task = Task<URL, Error> {
            defer { TransferProgressCenter.finish(progressKey) }
            do {
                _ = try await client.download("/api/fs/download", query: query, to: partial, ceiling: Self.fileCeiling,
                                              priority: URLSessionTask.highPriority,
                                              progress: { got, expected in TransferProgressCenter.report(progressKey, sent: got, total: expected) })
            } catch {
                try? FileManager.default.removeItem(at: partial)
                let mapped = Self.map(error)
                if mapped == .unreachable { AppLog.swallowed("media", "download a gateway file", error) }
                throw mapped
            }
            guard let adopted = store.adoptDownloadedFile(partial, as: key, name: name) else { throw MediaLoadError.unreachable }
            return adopted
        }
        fileFlights[key] = task
        defer { fileFlights[key] = nil }
        return try await task.value
    }

    func cancelFile(path: String, context: MediaContext) {
        let key = MediaStore.gatewayKey(accountId: context.accountId, profile: context.profile, path: path)
        fileFlights[key]?.cancel()
        fileFlights[key] = nil
    }

    /// The wait before the one retry of a download that failed because the network wasn't up.
    nonisolated static let notReadyRetryDelay: Duration = .milliseconds(400)

    /// A raw "no network yet" failure, worth one quick retry. Gated on the URLError, never on the mapped
    /// `.unreachable`: HTTP 5xx maps there too and must not double requests.
    nonisolated static func retriesOnce(_ error: any Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .dataNotAllowed].contains(code)
    }

    nonisolated static func map(_ error: any Error) -> MediaLoadError {
        if let mapped = error as? MediaLoadError { return mapped }
        if let http = error as? HTTPError {
            switch http.status {
            case 404: return .notFound
            case 403: return .forbidden
            case 400, 409: return .notFound
            default: return .unreachable
            }
        }
        if let failure = error as? GatewayFailure, failure == .responseTooLarge { return .tooLarge }
        return .unreachable
    }

    // MARK: Seam for other streams (spec §13.4: activity cards)

    /// A gateway image at `maxPixel`: `sessionId` is used only for relative paths.
    static func image(path: String, profile: String, sessionId: String?, accountId: String, maxPixel: Int) async throws -> UIImage {
        let attachment = MessageAttachment(kind: .image, source: .gateway(path: path), name: MediaKinds.name(ofPath: path, image: true))
        return try await shared.image(attachment, context: MediaContext(accountId: accountId, profile: profile, storedSessionId: sessionId),
                                      maxPixel: maxPixel).image
    }

    /// [load-cache] The same picture's original on the phone (kept in the store, else downloaded): the activity cards'
    /// full-size viewer.
    static func original(path: String, profile: String, sessionId: String?, accountId: String) async throws -> URL {
        let attachment = MessageAttachment(kind: .image, source: .gateway(path: path), name: MediaKinds.name(ofPath: path, image: true))
        return try await shared.original(attachment, context: MediaContext(accountId: accountId, profile: profile, storedSessionId: sessionId))
    }
}
