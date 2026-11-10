// The Artifacts page's data (docs/spec/1x-pages.md §5): the index's kept artifacts painted at once, then a pass over
// each profile's 50 most recent sessions (3 profiles at a time when the scope is All Bots and there are ≥ 2 bots),
// reading only sessions that changed; older chats read before keep their artifacts (up to 300 chats). Never at launch
// or off screen: on the page's first show, on later shows when the last pass is > 60 s old, and on pull to refresh.
// Files the gateway can't find collect under Unavailable.

import Foundation
import Observation

@MainActor @Observable
final class ArtifactsStore {
    nonisolated static let sessionsPath = "/api/profiles/sessions"
    static let windowSize = 50   // [pins] was 30: a bot that runs jobs makes many chats a day
    static let retain = 300
    static let staleAfter: TimeInterval = 60

    let client: any GatewayClient
    let account: GatewayAccount
    let index: ArtifactIndex
    /// What the owner removed (`ArtifactHidden`): never listed.
    let hidden: ArtifactHidden

    /// "all" or a profile name.
    private(set) var scope: String
    /// Every profile name the roster knows (for the per-profile listing), read when a pass starts.
    @ObservationIgnored var profilesProvider: () -> [String] = { [] }
    var profiles: [String] { profilesProvider() }
    /// What the page lists, newest first, one per [profile, session, kind, value, href].
    private(set) var artifacts: [ArtifactRecord] = []
    /// Artifacts in hand (nil before the first pass when nothing was kept).
    private(set) var loaded: Int?
    private(set) var refreshing = false
    private(set) var loadError: String?
    private(set) var lastPass: Date?
    /// Files and images the gateway couldn't find or place this run (in memory; Refresh clears it).
    private(set) var unavailable: Set<String> = []

    @ObservationIgnored var onChange: (() -> Void)?
    /// A notice for `seconds` ("Skipped 2 of 30 recent sessions…", "Couldn’t list Ivy’s chats…").
    @ObservationIgnored var onNotice: ((String, TimeInterval) -> Void)?
    /// Sessions read again in a pass, and when their listing came: their image previews kept from before then are read
    /// again (one read while the pass ran is already fresh).
    @ObservationIgnored var onSessionsRead: (([ArtifactSessionRow], Date) -> Void)?
    /// gateway.ready (PagesTabs): the page on screen asks again for previews the link failed.
    @ObservationIgnored var onGatewayReady: (() -> Void)?
    /// A profile's display name ("default" → "Hermes").
    @ObservationIgnored var displayName: (String) -> String = { $0 == "default" ? "Hermes" : $0 }

    @ObservationIgnored private var passGeneration = 0
    /// Which store a pass ran on, for the log (a second store would start from its own index).
    @ObservationIgnored private lazy var storeTag = String(UInt(bitPattern: ObjectIdentifier(self).hashValue) & 0xFFFF, radix: 16)
    @ObservationIgnored private var pass: Task<Void, Never>?
    @ObservationIgnored private var prepared = false
    @ObservationIgnored private var hiddenObserver: NSObjectProtocol?

    init(client: any GatewayClient, account: GatewayAccount, directory: URL?, scope: String = "all", hidden: ArtifactHidden? = nil) {
        self.client = client
        self.account = account
        self.scope = scope
        self.hidden = hidden ?? ArtifactHidden.of(accountId: account.id)
        index = ArtifactIndex(fileURL: directory?.appending(path: "artifacts-index.json"))
        index.onLoaded = { [weak self] in
            guard let self else { return }
            self.paintFromIndex()
            self.onChange?()
        }
        // A Remove anywhere (Artifacts, or See All in Bot Info on the same account) leaves every list at once.
        hiddenObserver = NotificationCenter.default.addObserver(forName: ArtifactHidden.didChange, object: self.hidden, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let before = self.artifacts.count
                self.artifacts = self.hidden.visible(self.artifacts)
                if self.artifacts.count != before { self.onChange?() }
            }
        }
    }

    isolated deinit {
        if let hiddenObserver { NotificationCenter.default.removeObserver(hiddenObserver) }
    }

    /// The page is about to draw (its view loads): paint from the kept index, read now when small, else off the main
    /// thread behind the skeleton. Nothing is read before (P-NAV-6: the store exists from launch).
    func prepare() {
        guard !prepared else { return }
        prepared = true
        index.prepare()
        if index.isLoaded { paintFromIndex() }
    }

    // MARK: Painting

    private func inScope(_ record: ArtifactRecord) -> Bool {
        scope == "all" || (record.profile ?? "default") == scope
    }

    private func paintFromIndex() {
        guard index.isLoaded else { artifacts = []; loaded = nil; return }
        let kept = index.entries.values.flatMap(\.artifacts).filter(inScope)
        artifacts = hidden.visible(ArtifactCollector.unique(kept))
        loaded = index.entries.isEmpty ? nil : artifacts.count
    }

    /// A scope change repaints from the index; a pass for the new scope starts only from `pageShown()` (the page is on
    /// screen) or a pull to refresh: never off screen (§5.3).
    func setScope(_ next: String) {
        guard next != scope else { return }
        AppLog.trace("pages", "artifacts scope \(scope) -> \(next)")
        scope = next
        passGeneration += 1
        pass?.cancel()
        refreshing = false
        loadError = nil
        lastPass = nil
        paintFromIndex()
        onChange?()
    }

    /// [offline] §6.2: the wait before a failed listing is asked once more (tests shorten it).
    @ObservationIgnored var retryDelay: Duration = QueryRetry.delay

    // MARK: Passes

    /// The page came on screen: a pass on its first show, then when the last one is over a minute old.
    func pageShown() {
        prepare()
        guard !refreshing else { return }
        if let lastPass, Date().timeIntervalSince(lastPass) < Self.staleAfter { return }
        refresh(explicit: false)
    }

    /// `explicit`: a pull to refresh (clears Unavailable, so missing files get another try).
    func refresh(explicit: Bool) {
        if explicit { unavailable = [] }
        guard !refreshing || explicit else { return }
        pass?.cancel()
        passGeneration += 1
        let generation = passGeneration
        refreshing = true
        onChange?()
        AppLog.trace("pages", "artifacts pass #\(generation) start, scope \(scope), explicit \(explicit), store \(storeTag)")
        pass = Task { [weak self] in
            await self?.runPass(generation)
        }
    }

    private func runPass(_ generation: Int) async {
        let scope = self.scope, client = self.client
        let start = ContinuousClock.now
        do {
            // [offline] §6.2: one quick retry, none after a timeout or while the gateway cannot be reached.
            let listing = try await QueryRetry.read(delay: retryDelay) { try await self.listSessions(scope: scope) }
            let listedAt = Date()
            guard generation == passGeneration else { return }
            if !listing.failedNames.isEmpty {
                onNotice?("Couldn’t list \(listing.failedNames.joined(separator: ", "))’s chats, so their artifacts are missing.", 10)
            }
            let result = await index.run(
                sessions: listing.sessions, listedProfiles: listing.listed, retainedProfiles: listing.failed, retain: Self.retain,
                window: listing.perProfile ? Self.windowSize : 0,
                load: { session in
                    try await ArtifactCollector.loadSession(session) { session, limit, offset in
                        try await PagesREST.send(client, "GET", "/api/sessions/\(PagesREST.segment(session.id))/messages",
                                                 query: [URLQueryItem(name: "profile", value: session.profile ?? "default"),
                                                         URLQueryItem(name: "limit", value: String(limit)),
                                                         URLQueryItem(name: "offset", value: String(offset)),
                                                         URLQueryItem(name: "order", value: "oldest"),
                                                         URLQueryItem(name: "include_compacted", value: "true")],
                                                 timeout: 60)
                    }
                },
                onProgress: { [weak self] found in
                    guard let self, generation == self.passGeneration else { return }
                    self.show(found)
                },
                onRead: nil)
            guard generation == passGeneration else { return }
            show(result.artifacts)
            loaded = artifacts.count
            loadError = nil
            if !result.read.isEmpty { onSessionsRead?(result.read, listedAt) }
            if !result.failures.isEmpty {
                onNotice?("Skipped \(result.failures.count) of \(listing.sessions.count) recent sessions while indexing artifacts.", 10)
            }
            AppLog.trace("pages", "artifacts pass #\(generation) done in \(AppLog.ms(since: start)) ms: \(listing.sessions.count) sessions, \(result.read.count) read, \(result.failures.count) failed, \(artifacts.count) shown")
        } catch {
            guard generation == passGeneration, !(error is CancellationError) else { return }
            loadError = PagesREST.reason(error)
            AppLog.note("pages", "artifacts pass #\(generation) failed after \(AppLog.ms(since: start)) ms: \(loadError ?? "?")")
            if !artifacts.isEmpty { onNotice?("Couldn’t refresh. Showing what was saved.", 3) }
        }
        guard generation == passGeneration else { return }
        refreshing = false
        lastPass = Date()
        onChange?()
    }

    private func show(_ found: [ArtifactRecord]) {
        artifacts = hidden.visible(ArtifactCollector.unique(found.filter(inScope)))
        if loaded == nil && !artifacts.isEmpty { loaded = artifacts.count }
        onChange?()
    }

    struct Listing: Sendable {
        var sessions: [ArtifactSessionRow]
        /// Profiles whose window was listed (even empty).
        var listed: [String]
        /// Profiles whose listing failed (their cached sessions are kept).
        var failed: [String]
        var failedNames: [String]
        /// Each bot was listed on its own (a bot with fewer chats than the window has no others).
        var perProfile = false
    }

    /// Each profile's recent window (scope All with ≥ 2 bots), merged newest first; otherwise the scope's one listing.
    func listSessions(scope: String) async throws -> Listing {
        let client = self.client
        let names = Array(Set(profiles.map { $0.isEmpty ? "default" : $0 })).sorted()
        @Sendable func list(_ profile: String) async throws -> [ArtifactSessionRow] {
            let json = try await PagesREST.json(client, "GET", Self.sessionsPath, query: [
                URLQueryItem(name: "limit", value: String(Self.windowSize)), URLQueryItem(name: "offset", value: "0"),
                URLQueryItem(name: "min_messages", value: "1"), URLQueryItem(name: "archived", value: "exclude"),
                URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "profile", value: profile),
            ], timeout: 60)
            let listed = profile == "all" ? nil : profile
            return (json["sessions"]?.array ?? json.array ?? []).compactMap { ArtifactSessionRow(json: $0, listedProfile: listed) }
        }
        if scope != "all" || names.count < 2 {
            let rows = try await list(scope)
            return Listing(sessions: rows, listed: scope == "all" ? names : [scope], failed: [], failedNames: [], perProfile: scope != "all")
        }
        var pages: [String: [ArtifactSessionRow]] = [:]
        var errors: [Error] = []
        await withChildTasks(of: (String, Result<[ArtifactSessionRow], Error>).self) { group in
            var queue = names[...]
            var running = 0
            while true {
                while running < 3, let name = queue.first {
                    queue.removeFirst()
                    running += 1
                    group.addTask {
                        let outcome = await Result.of { try await list(name) }
                        return (name, outcome)
                    }
                }
                guard let (name, outcome) = await group.next() else { break }
                running -= 1
                switch outcome {
                case .success(let rows): pages[name] = rows
                case .failure(let error): errors.append(error)
                }
            }
        }
        if pages.isEmpty {
            AppLog.note("pages", "artifacts listing: all \(names.count) profiles failed")
            throw errors.first ?? PagesMessageError("No bot’s chats could be listed.")
        }
        var seen = Set<String>()
        var rows: [ArtifactSessionRow] = []
        for name in names {
            for var row in pages[name] ?? [] {
                if (row.profile ?? "").pgTrim.isEmpty { row.profile = name }
                if seen.insert(ArtifactIndex.key(row)).inserted { rows.append(row) }
            }
        }
        rows.sort { $0.recency > $1.recency }
        let failed = names.filter { pages[$0] == nil }
        return Listing(sessions: rows, listed: names.filter { pages[$0] != nil }, failed: failed,
                       failedNames: failed.map(displayName), perProfile: true)
    }

    // MARK: Unavailable

    func markUnavailable(_ id: String) {
        guard unavailable.insert(id).inserted else { return }
        onChange?()
    }

    func markAvailable(_ id: String) {
        guard unavailable.remove(id) != nil else { return }
        onChange?()
    }

    func reset() {
        passGeneration += 1
        pass?.cancel()
        index.cancel()
        artifacts = []
    }
}
