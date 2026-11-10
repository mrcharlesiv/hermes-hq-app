// The Artifacts index (docs/spec/1x-pages.md §5.3), a port of the web's `src/artifact-index.ts`: one entry per
// [profile, session] stamped with the row's message_count, last_active and title, so a visit reads only sessions that
// changed. Kept across launches in Application Support/pages/<account>/artifacts-index.json (≤ 4 MB), for this
// collector version only. Reads newest first, 3 at a time (a session with ≥ 1000 messages, or no count, takes all 3).

import Foundation

nonisolated struct ArtifactIndexEntry: Codable, Sendable, Hashable {
    var stamp: String
    var at: Double
    var artifacts: [ArtifactRecord]
    var failedAt: Int?
}

nonisolated struct ArtifactIndexFile: Codable, Sendable {
    var collector: String
    var entries: [String: ArtifactIndexEntry]
}

nonisolated struct ArtifactIndexFailure: Sendable {
    var session: ArtifactSessionRow
    var error: Error
}

nonisolated struct ArtifactIndexResult: Sendable {
    var artifacts: [ArtifactRecord]
    var failures: [ArtifactIndexFailure]
    /// Sessions whose transcripts were read this time (new, or changed).
    var read: [ArtifactSessionRow]
}

@MainActor
final class ArtifactIndex {
    /// Bump when the collector changes: a kept index from another collector is read again.
    /// native-4 (2026-11-02): no web artifacts from a shell's output, and email/social junk dropped everywhere.
    /// native-5 (2026-11-03): no files from a bot's own `state` / `…_state` folders unless handed over.
    /// native-6 (2026-11-03): a shell's pictures and a bot's own screenshots only when sent.
    /// native-7 (2026-11-03): no shell `MEDIA:`, compaction summaries, failed tools, saved email parts, web icons.
    nonisolated static let collectorVersion = "native-7"
    nonisolated static let maxFileBytes = 4 << 20
    static let slots = 3
    static let longSession = 1000

    private(set) var entries: [String: ArtifactIndexEntry] = [:]
    let fileURL: URL?
    private var unsaved = false
    private var lastSave = Date.distantPast
    /// Progress at most once a second; saves at most every 5 s while reading (tests shorten them).
    var progressInterval: TimeInterval = 1
    var saveInterval: TimeInterval = 5
    /// The kept index has been read (or there is none).
    private(set) var isLoaded = false
    private var loading: Task<Void, Never>?
    /// A file read off the main thread landed.
    var onLoaded: (() -> Void)?
    /// A kept index up to this size is read in the page's first frame; a bigger one (up to 4 MB, ~20k records) off the
    /// main thread, behind the page's skeleton.
    nonisolated static let inlineLoadBytes = 512 << 10

    /// Nothing is read here: the app builds the Artifacts store at launch (P-NAV-6); `prepare()` reads it when the
    /// page is about to draw.
    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    /// Reads the kept index once: at once when it is small, else off the main thread (`onLoaded` then fires).
    func prepare() {
        guard !isLoaded, loading == nil else { return }
        guard let fileURL else { isLoaded = true; return }
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size <= Self.inlineLoadBytes {
            entries = Self.read(fileURL) ?? [:]
            isLoaded = true
            return
        }
        loading = Task { [weak self] in
            let found = await Self.readOffMain(fileURL)
            guard let self else { return }
            self.loading = nil
            guard !self.isLoaded else { return }
            self.entries = found ?? [:]
            self.isLoaded = true
            self.onLoaded?()
        }
    }

    /// [pins] Starts from another index's entries, in memory only (an index with no file): Bot Info › Artifacts ›
    /// See All reads only the chats that changed since, and never writes the shared file.
    func seed(_ kept: [String: ArtifactIndexEntry]) {
        guard fileURL == nil else { return }
        entries = kept
        isLoaded = true
    }

    /// Returns once the kept index is in memory (a pass starts from it).
    func ready() async {
        prepare()
        if let loading { await loading.value }
    }

    nonisolated static func read(_ fileURL: URL) -> [String: ArtifactIndexEntry]? {
        guard let data = try? Data(contentsOf: fileURL), data.count <= maxFileBytes,
              let file = try? JSONDecoder().decode(ArtifactIndexFile.self, from: data), file.collector == collectorVersion else { return nil }
        return file.entries
    }

    @concurrent
    nonisolated static func readOffMain(_ fileURL: URL) async -> [String: ArtifactIndexEntry]? { read(fileURL) }

    nonisolated static func key(profile: String?, id: String) -> String {
        let p = (profile ?? "").pgTrim
        return (p.isEmpty ? "default" : p) + "\u{1F}" + id
    }

    nonisolated static func key(_ session: ArtifactSessionRow) -> String { key(profile: session.profile, id: session.id) }

    private static func profileOf(_ key: String) -> String { String(key.split(separator: "\u{1F}", maxSplits: 1).first ?? "") }

    /// What changes when a session gains messages or a name; nil when the row has no counts (never cached).
    static func stamp(_ session: ArtifactSessionRow) -> String? {
        if session.messageCount == nil && session.lastActive == nil { return nil }
        func number(_ value: Double?) -> String {
            guard let value else { return "" }
            return value.rounded() == value && abs(value) < 9e15 ? String(Int64(value)) : String(value)
        }
        return "\(session.messageCount.map(String.init) ?? "")|\(number(session.lastActive))|\(session.title ?? "")"
    }

    /// A stamp for the log: the count and time as they are, the title as its length.
    static func redacted(_ stamp: String) -> String {
        let parts = stamp.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return "?" }
        return "\(parts[0])|\(parts[1])|t\(parts[2].count)"
    }

    static func isPermanentFailure(_ error: Error) -> Bool {
        if case ArtifactLoadError.safeLoadLimit = error { return true }
        return String(describing: error).range(of: "safe-load limit", options: .caseInsensitive) != nil
            || (error as? LocalizedError)?.errorDescription?.range(of: "safe-load limit", options: .caseInsensitive) != nil
    }

    private var generation = 0

    /// One pass over the listed sessions (§5.3). `load` reads one session's artifacts (off the main thread);
    /// `onProgress` gets what there is to show as reads land (at most once a second); `onRead` each session read.
    /// `window`: the most chats a bot's listing returns (0: unknown); a shorter listing holds every chat it has.
    func run(sessions: [ArtifactSessionRow], listedProfiles: [String] = [], retainedProfiles: [String] = [], retain: Int = 0,
             window: Int = 0,
             load: @escaping @Sendable (ArtifactSessionRow) async throws -> [ArtifactRecord],
             onProgress: (([ArtifactRecord]) -> Void)? = nil,
             onRead: ((ArtifactSessionRow) -> Void)? = nil) async -> ArtifactIndexResult {
        await ready()
        generation += 1
        let mine = generation
        let listed = Set(sessions.map(Self.key))
        let failedProfiles = Set(retainedProfiles.map { $0.isEmpty ? "default" : $0 })
        let completedProfiles = Set(listedProfiles.map { $0.isEmpty ? "default" : $0 }.filter { !failedProfiles.contains($0) })
        // [pins] Tester, 2026-10-31: "Not all of my artifacts are showing up". Only each bot's recent chats are
        // listed, and every job run is a chat, so a busy bot's older chats left the window within a day and their
        // artifacts were forgotten with them. A chat that only fell out of the window stays now (the `retain` newest).
        // One that is gone (deleted or archived) still goes: it was newer than the oldest chat listed, so it would be
        // listed, or the listing was shorter than the window, so every chat was.
        var oldestListed: [String: Double] = [:], listedCount: [String: Int] = [:]
        for session in sessions {
            let profile = Self.profileOf(Self.key(session))
            listedCount[profile, default: 0] += 1
            if let active = session.lastActive { oldestListed[profile] = min(oldestListed[profile] ?? active, active) }
        }
        func gone(_ key: String, _ entry: ArtifactIndexEntry) -> Bool {
            let profile = Self.profileOf(key)
            guard completedProfiles.contains(profile) else { return false }
            let count = listedCount[profile] ?? 0
            if count == 0 || (window > 0 && count < window) { return true }
            return oldestListed[profile].map { entry.at > $0 } ?? false
        }
        for (key, entry) in entries where !listed.contains(key) && gone(key, entry) {
            entries[key] = nil
            unsaved = true
        }
        let covered = completedProfiles.union(failedProfiles)
        let retained = entries.filter { !listed.contains($0.key) && !$0.value.artifacts.isEmpty && covered.contains(Self.profileOf($0.key)) }
            .sorted { $0.value.at > $1.value.at }.prefix(max(0, retain))
        let retainedKeys = Set(retained.map(\.key))
        var kept: [ArtifactRecord] = retained.flatMap(\.value.artifacts)
        var stale: [ArtifactSessionRow] = []
        // Owner 2026-11-01: the phone read all 369 chats on every visit, a few minutes apart, with the same listings.
        // Why each one is read goes in the log: never kept, kept under another stamp (a sample), or no stamp at all.
        var unknown = 0, unstamped = 0, changed: [String] = []
        for session in sessions {
            let entry = entries[Self.key(session)], stamp = Self.stamp(session)
            let tooLarge = entry?.failedAt.map { (session.messageCount ?? -1) >= $0 } ?? false
            if let entry, let stamp, entry.stamp == stamp || tooLarge { kept += entry.artifacts; continue }
            stale.append(session)
            if stamp == nil { unstamped += 1 } else if let entry { changed.append(Self.redacted(entry.stamp) + " → " + Self.redacted(stamp ?? "")) } else { unknown += 1 }
        }
        if !stale.isEmpty {
            AppLog.trace("pages", "artifacts index #\(mine) (\(entries.count) kept chats, file \(fileURL == nil ? "none" : "yes")): "
                + "\(sessions.count - stale.count) unchanged, \(unknown) new, \(changed.count) changed, \(unstamped) unstamped"
                + (changed.isEmpty ? "" : "; e.g. " + changed.prefix(2).joined(separator: ", ")))
        }
        let previous = stale.map { entries[Self.key($0)]?.artifacts ?? [] }
        var results: [Result<[ArtifactRecord], Error>?] = Array(repeating: nil, count: stale.count)
        func found(_ at: Int) -> [ArtifactRecord] {
            if case .success(let artifacts)? = results[at] { return artifacts }
            return previous[at]
        }
        var shownAt = Date.distantPast, shown = false
        let show = { (now: Bool) in
            guard let onProgress, mine == self.generation, now || Date().timeIntervalSince(shownAt) >= self.progressInterval else { return }
            let all = kept + stale.indices.flatMap(found)
            guard !all.isEmpty else { return }
            shownAt = Date(); shown = true
            onProgress(all)
        }
        if !stale.isEmpty { show(true) }

        let order = stale.indices.sorted { stale[$0].recency > stale[$1].recency }
        let weight = { (i: Int) -> Int in (stale[i].messageCount ?? Self.longSession) >= Self.longSession ? Self.slots : 1 }
        await withChildTasks(of: (Int, Result<[ArtifactRecord], Error>).self) { group in
            var used = 0
            var queue = order[...]
            while true {
                while let i = queue.first, used + weight(i) <= Self.slots {
                    queue.removeFirst()
                    used += weight(i)
                    let session = stale[i]
                    group.addTask {
                        let outcome = await Result.of { try await load(session) }
                        return (i, outcome)
                    }
                }
                guard let (i, outcome) = await group.next() else { break }
                used -= weight(i)
                results[i] = outcome
                guard mine == generation else { continue }
                settle(stale[i], outcome)
                onRead?(stale[i])
                show(!shown)
                if Date().timeIntervalSince(lastSave) >= saveInterval { save() }
            }
        }
        let failures: [ArtifactIndexFailure] = stale.indices.compactMap { i in
            if case .failure(let error)? = results[i] { return ArtifactIndexFailure(session: stale[i], error: error) }
            return nil
        }
        let loaded = stale.indices.flatMap(found)
        guard mine == generation else { return ArtifactIndexResult(artifacts: kept + loaded, failures: failures, read: stale) }
        // Sessions that left the window are forgotten beyond the `retain` kept.
        var outside = entries.keys.filter { !listed.contains($0) }.count
        for key in entries.keys.sorted(by: { (entries[$0]?.at ?? 0) < (entries[$1]?.at ?? 0) })
        where outside > retain && !listed.contains(key) && !retainedKeys.contains(key) {
            entries[key] = nil
            outside -= 1
            unsaved = true
        }
        save()
        return ArtifactIndexResult(artifacts: kept + loaded, failures: failures, read: stale)
    }

    private func settle(_ session: ArtifactSessionRow, _ outcome: Result<[ArtifactRecord], Error>) {
        let stamp = Self.stamp(session), key = Self.key(session)
        unsaved = true
        switch outcome {
        case .failure(let error):
            if let stamp, let count = session.messageCount, Self.isPermanentFailure(error) {
                entries[key] = ArtifactIndexEntry(stamp: stamp, at: session.lastActive ?? 0, artifacts: entries[key]?.artifacts ?? [],
                                                  failedAt: count)
            }
            // Any other failure keeps the previous artifacts and the old stamp: the next pass retries.
        case .success(let artifacts):
            guard let stamp else { entries[key] = nil; return }
            entries[key] = ArtifactIndexEntry(stamp: stamp, at: session.lastActive ?? 0,
                                              artifacts: artifacts.filter { Self.key(profile: $0.profile, id: $0.sessionId) == key })
        }
    }

    /// Writes the index off the main thread (newest sessions first while they fit in 4 MB).
    func save() {
        guard unsaved, let fileURL else { return }
        unsaved = false
        lastSave = Date()
        let snapshot = entries
        PagesCache.writer.async {
            var file = ArtifactIndexFile(collector: Self.collectorVersion, entries: snapshot)
            guard var data = try? JSONEncoder().encode(file) else { return }
            if data.count > Self.maxFileBytes {
                var kept: [String: ArtifactIndexEntry] = [:]
                var total = 0
                for (key, entry) in snapshot.sorted(by: { $0.value.at > $1.value.at }) {
                    let size = (try? JSONEncoder().encode(entry).count) ?? 0
                    if total + size > Self.maxFileBytes * 9 / 10 { continue }
                    kept[key] = entry
                    total += size
                }
                file.entries = kept
                guard let smaller = try? JSONEncoder().encode(file) else { return }
                data = smaller
            }
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: [.atomic])
        }
    }

    /// Ends any pass in flight's claim on the index (sign-out; a new account starts from nothing).
    func cancel() {
        generation += 1
        loading?.cancel()
        loading = nil
        entries = [:]
        isLoaded = true
    }

    /// What the page shows (`artifactsView`): found artifacts win; none loaded and a pass in flight is loading, a
    /// failed pass is the error, only a pass that worked and found nothing is empty.
    enum View: Equatable { case loading, error, empty, list }
    nonisolated static func view(loaded: Int?, visible: Int, refreshing: Bool, error: String?) -> View {
        if visible > 0 { return .list }
        if let loaded, loaded > 0 { return .empty }
        if refreshing || (loaded == nil && error == nil) { return .loading }
        return error != nil ? .error : .empty
    }
}
