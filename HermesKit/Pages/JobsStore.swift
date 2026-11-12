// The Jobs page's data (docs/spec/1x-pages.md §3): the scope's job list painted from its disk cache, then read
// (`GET /api/cron/jobs?profile=`); refreshed on `cron.changed` through a 2 s throttle, a 5 min backstop (30 s without
// change events, or while work is out), just after each job's start time (`nextDueRead`: only the gateway's own bot's
// jobs send change events), reconnects, foreground and pull to refresh. These run with Jobs off screen too
// (only the app being away stops them), so the Jobs tab's spinner (`workingCount`) appears and clears without the
// page open. Each read also asks the Hermes HQ add-on (0.9.2+, `cron/working`) which jobs a bot is still working on:
// a Bot Chat job's run ends when it hands its output over, and no change event says when the bot is done. Writes:
// Run Now (§3.6, `CronRunOnce`), Pause / Resume, Delete; each refused with a notice while the gateway is read-only.

import Foundation
import Observation

nonisolated struct JobsStoreTiming: Sendable {
    var changeGap: Duration = .seconds(2)
    var backstop: Duration = .seconds(300)
    var backstopWithoutEvents: Duration = .seconds(30)
    var runTimeout: TimeInterval = 120
    var stillRunningRecheck: Duration = .seconds(5)
    /// A run that outlived the wait and that no read has shown out is taken as over after this long (a Hermes that
    /// doesn't report its runs' state, a run killed before it stamped its time).
    var stillRunningGiveUp: TimeInterval = 1800
    /// A job's start: read this long after it (the scheduler's claim moves `next_run_at` and the run shows as out).
    var dueLead: TimeInterval = 3
    /// A start that passed with no claim yet (the scheduler ticks): read again after at least this long, each wait
    /// as long as the time since the start (about +3, +13, +26, +52, +104 s)…
    var dueRecheck: TimeInterval = 10
    /// …for this long after the start, then leave it (an overdue job the scheduler isn't coming for).
    var dueWindow: TimeInterval = 120
    /// [phone-logs] A read that started this recently covers the reconnect's read: a return from the background ran
    /// two whole-list reads in the same second (the foreground's and `gateway.ready`'s, 300 KB each).
    var freshRead: TimeInterval = 5
    static let standard = JobsStoreTiming()
}

@MainActor @Observable
final class JobsStore {
    nonisolated static let listPath = "/api/cron/jobs"
    nonisolated static let botWorkingPath = "/api/plugins/hermes-hq-push/cron/working"
    static let readOnlyNotice = "Changes are off for this gateway."

    let client: any GatewayClient
    let account: GatewayAccount
    let directory: URL?
    var readOnlyGateway = false
    let timing: JobsStoreTiming

    /// "all" or a profile name.
    private(set) var scope: String
    /// The scope's jobs, by human title.
    private(set) var jobs: [CronJob] = []
    /// The scope has an answer to show (from disk or the gateway).
    private(set) var hasList = false
    private(set) var loading = false
    /// The last read failed (nil after a read that worked).
    private(set) var loadError: String?
    /// Job key → the write that marked it busy (only that write clears it, §3.2).
    private(set) var busy: [String: Int] = [:]
    /// Jobs with a Run Now in flight (their row says "Running…").
    private(set) var runInFlight: Set<String> = []
    /// Jobs whose Run Now outlived the wait: the row says "Running…" until a read shows the run ended.
    private(set) var stillRunning: [String: String?] = [:]
    /// When each of those outlived the wait, and the ones a read has since shown out (running, or a bot on its output).
    @ObservationIgnored private var stillRunningSince: [String: Date] = [:]
    @ObservationIgnored private var stillRunningSeenOut: Set<String> = []
    /// Spelling of words other jobs' names use ("GBrain"), for `humanJobTitle`.
    private(set) var casing: [String: String] = [:]
    var changeEvents = true

    @ObservationIgnored var onChange: (() -> Void)?
    /// A refresh failed while a cached list shows.
    @ObservationIgnored var onRefreshFailed: ((String) -> Void)?
    /// A job vanished (404) — the detail pops with "Job Removed".
    @ObservationIgnored var onJobRemoved: ((String) -> Void)?
    /// [live] A list read landed: the Lock Screen's Running for a job run from Jobs ends when the read says it is over
    /// (App/Live/LiveActivityCenter.swift).
    @ObservationIgnored var onListRead: (() -> Void)?

    @ObservationIgnored private var appActive = true
    /// [phone-logs] The app has been active since this store began (its first activation is the launch's, a return).
    @ObservationIgnored private var activatedOnce = false
    @ObservationIgnored private var throttle: ChangeThrottle!
    @ObservationIgnored private var backstopTask: Task<Void, Never>?
    /// The read just after the soonest job start (`nextDueRead`).
    @ObservationIgnored private var dueTask: Task<Void, Never>?
    /// The last read had a job with work out (`JobWords.workIsOut`): the backstop is the short one until it ends.
    @ObservationIgnored private var runOut = false
    /// Job key → what a bot is doing with the output its latest run handed over ("queued", "claimed"), from the add-on.
    @ObservationIgnored private var botWorking: [String: String] = [:]
    /// The add-on answered 404 (not installed, or older than 0.9.2): not asked again until the gateway reconnects.
    @ObservationIgnored private var botWorkingMissing = false
    /// Its last read failed: one failure keeps what was known, a second clears it (no Running that never ends).
    @ObservationIgnored private var botWorkingFailed = false
    @ObservationIgnored private var readGeneration = 0
    @ObservationIgnored private var lastRead: Date?
    /// When the latest list read started (`freshRead`).
    @ObservationIgnored private var lastStart: Date?
    @ObservationIgnored private var nextToken = 0
    @ObservationIgnored let runs = SharedReads<[CronRun]>()
    // [jobs] Job templates by profile (docs/spec/3x-jobs.md §6.6): painted from disk, read with the list.
    var blueprintsByProfile: [String: [Blueprint]] = [:]
    @ObservationIgnored var blueprintsReadAt: [String: Date] = [:]
    /// Counts `cron.changed` events: a job page re-reads its runs on each (§6.4).
    private(set) var changeTick = 0
    /// Bumped by every list read that landed (a job page notices its job left the list, audit 863).
    private(set) var listReads = 0
    /// Jobs this app deleted (their page closes itself; a list read without them is no news).
    @ObservationIgnored private(set) var deletedHere: Set<String> = []
    /// At most this many jobs are kept on disk per scope (D-J10); the rest arrive with the network.
    nonisolated static let cachedJobsLimit = 500
    /// [offline] §6.7: list reads run one at a time, none while the app is away, one catch-up on return.
    @ObservationIgnored private var flight: ReadFlight!
    /// [offline] §6.10: a list whose JSON is longer than this is not saved (it is simply read fresh next time).
    nonisolated static let cacheLimit = 300_000

    init(client: any GatewayClient, account: GatewayAccount, directory: URL?, scope: String = "all", timing: JobsStoreTiming = .standard) {
        self.client = client
        self.account = account
        self.directory = directory
        self.scope = scope
        self.timing = timing
        throttle = ChangeThrottle(gap: { [timing] in timing.changeGap },
                                  allowed: { [weak self] in self?.appActive ?? false },
                                  action: { [weak self] in await self?.refresh(background: true) })
        flight = ReadFlight(isActive: { [weak self] in self?.appActive ?? false }, label: "jobs") { [weak self] in await self?.performRefresh() }
        paintFromCache()
    }

    // MARK: Cache

    private func cacheURL(_ scope: String) -> URL? {
        directory?.appending(path: "jobs-\(PagesCache.safeName(scope)).json")
    }

    private func paintFromCache() {
        paintBlueprintsFromCache()   // [jobs]
        guard let url = cacheURL(scope), let cached = PagesCache.read(PagesCached<[CronJob]>.self, url) else {
            jobs = []
            hasList = false
            return
        }
        setJobs(cached.value)
        hasList = true
    }

    private func setJobs(_ list: [CronJob]) {
        // [tasks-first] Tasks' own runners are plumbing, not jobs you made: they stay out of the list.
        let list = list.filter { !TodoRunnerJobs.isOne($0) }.map { job in
            var job = job
            job.botWorking = botWorking[job.key]
            return job
        }
        casing = JobWords.knownWordCasing(list.map(JobWords.jobTitle))
        let titled = list.map { ($0, JobWords.humanJobTitle(JobWords.jobTitle($0), casing: casing)) }
        jobs = titled.sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }.map(\.0)
    }

    func title(_ job: CronJob) -> String { JobWords.humanJobTitle(JobWords.jobTitle(job), casing: casing) }

    func job(key: String) -> CronJob? { jobs.first { $0.key == key } }

    // MARK: Scope and visibility

    func setScope(_ next: String) {
        guard next != scope else { return }
        scope = next
        readGeneration += 1   // an answer for the scope left is dropped
        loadError = nil
        paintFromCache()
        onChange?()
        // A scope the user just picked is its own read (it never waits behind the scope left).
        Task { await performRefresh() }
    }

    /// Jobs (list or detail) on screen: read now when the list is over 30 s old (or never read). The backstop runs off
    /// screen too (the tab's spinner has to clear when the work ends).
    func setVisible(_ shown: Bool) {
        guard shown else { return }
        if !throttle.dirty, lastRead.map({ Date().timeIntervalSince($0) > 30 }) ?? true { Task { await refresh() } }
        throttle.pump()
        startBackstop()
    }

    func appDidBecomeActive() {
        // [phone-logs] Pages hears every activation, a moment under Notification Center or Control Center included
        // (§6.8: not a return). The app never left, the timers and change events ran, so nothing is read then: build 916
        // read the whole list (300 KB) on 10 of those in under 2 hours. The first activation (a launch) still reads.
        let returned = !appActive || !activatedOnce
        appActive = true
        activatedOnce = true
        // [offline] §6.7: one read on return, never two. Change ticks that arrived while away are the throttle's pass
        // (pump below); otherwise one read, on screen or off (the tab's spinner may be out of date).
        if returned, !throttle.dirty { Task { await refresh() } }
        throttle.pump()
    }

    func appDidEnterBackground() {
        appActive = false
        dueTask?.cancel()   // the read on return arms it again
        dueTask = nil
    }

    /// `cron.changed`: read soon (2 s apart), Jobs on screen or not; while the app is away, once on return.
    func cronChanged() { changeTick += 1; throttle.mark() }

    /// `gateway.ready` after a (re)connect.
    func gatewayReady(changeEvents: Bool) {
        self.changeEvents = changeEvents
        botWorkingMissing = false   // the add-on may have been updated (that takes a restart)
        startBackstop()
        // [phone-logs] The list is a REST read, not the socket's: one that started a moment ago (the return's) is
        // already the fresh answer. The add-on's 404 is asked again on the next read.
        if let lastStart, Date().timeIntervalSince(lastStart) < timing.freshRead {
            AppLog.trace("pages", "jobs scope \(scope): gateway ready, the read started \(Int(Date().timeIntervalSince(lastStart) * 1000)) ms ago covers it")
            return
        }
        Task { await refresh() }
    }

    private func startBackstop() {
        backstopTask?.cancel()
        // A run that dies before Hermes marks the job writes no jobs.json, so no `cron.changed` says it ended.
        let gap = changeEvents && !runOut ? timing.backstop : timing.backstopWithoutEvents
        backstopTask = Task { [weak self] in
            while !Task.isCancelled {
                // [offline] §6.9: stretched in Low Power Mode or when the phone is hot; re-armed on a power change.
                await PowerPolls.wait(gap, floor: .zero)
                guard !Task.isCancelled, let self else { return }
                if self.appActive { await self.refresh(background: true) }
            }
        }
    }

    func stop() {
        backstopTask?.cancel()
        dueTask?.cancel()
        throttle.cancel()
        flight.cancel()
    }

    // MARK: Reads

    /// Reads the scope's list. [offline] §6.7: one read at a time; callers during a read share the one that follows it;
    /// nothing is asked while the app is away (one catch-up on return). `background`: a change tick or the backstop.
    func refresh(background: Bool = false) async {
        await flight.request(background: background)
    }

    /// Reads the scope's list (timeout 60 s). Drops an answer for a scope no longer shown.
    private func performRefresh() async {
        readGeneration += 1
        lastStart = Date()
        let generation = readGeneration, scope = self.scope
        Task { await loadBlueprintsIfStale(profile: listProfile) }   // [jobs] alongside the list, never blocking it
        loading = true
        onChange?()
        let start = ContinuousClock.now
        defer {
            if generation == readGeneration { loading = false; onChange?() }
        }
        do {
            // [offline] §6.2: one quick retry, none after a timeout or while the gateway cannot be reached.
            let client = self.client
            async let working = Self.readBotWorking(client, ask: !botWorkingMissing)
            let list = try await QueryRetry.read { try await Self.readList(client, scope: scope) }
            let answer = await working
            guard generation == readGeneration, scope == self.scope else { return }
            switch answer {
            case .jobs(let map): botWorking = map; botWorkingFailed = false
            case .missing: botWorkingMissing = true; botWorking = [:]
            case .failed:
                // One failed read keeps what was known (Running doesn't blink off); two in a row clear it.
                if botWorkingFailed { botWorking = [:] }
                botWorkingFailed = true
            }
            setJobs(list)
            let out = jobs.contains(where: JobWords.workIsOut)
            if out != runOut {
                AppLog.trace("pages", "jobs scope \(scope): work-is-out \(runOut) -> \(out), backstop re-armed")
                runOut = out
                startBackstop()
            }
            hasList = true
            loadError = nil
            lastRead = Date()
            throttle.noteRan()
            settleStillRunning()
            listReads += 1
            onListRead?()   // [live]
            armDueRead()
            if let url = cacheURL(scope) {
                // [jobs] D-J10 / D-J21: at most 500 jobs are kept, fewer (250, 125, 62, 31) when 500 are over the byte
                // limit; [offline] §6.10: nothing over the limit is ever written, and when even 31 do not fit the old
                // copy goes too, so a stale list never outlives a newer one. Encoded on the cache's own queue.
                PagesCache.writeJobs(list, at: Date().timeIntervalSince1970 * 1000, to: url, maxBytes: Self.cacheLimit)
            }
            let workingWord: String
            switch answer {
            case .jobs(let map): workingWord = "\(map.count) jobs reported working"
            case .missing: workingWord = "add-on missing"
            case .failed: workingWord = "add-on read failed"
            }
            AppLog.trace("pages", "jobs refresh #\(generation) scope \(scope) done in \(AppLog.ms(since: start)) ms: \(list.count) jobs, \(workingWord)")
        } catch {
            guard generation == readGeneration, scope == self.scope, !(error is CancellationError) else { return }
            let reason = PagesREST.reason(error)
            loadError = reason
            AppLog.note("pages", "jobs refresh #\(generation) scope \(scope) failed after \(AppLog.ms(since: start)) ms: \(reason)")
            if hasList { onRefreshFailed?(reason) }
        }
    }

    /// The Jobs tab's spinner has to start when a job does, and only the gateway's own bot's jobs send `cron.changed`
    /// (Hermes watches one jobs.json): every other bot's run would wait for the 5 min backstop. So a read is set for
    /// just after the soonest start, and every `dueRecheck` while a start has passed unclaimed.
    private func armDueRead() {
        dueTask?.cancel()
        dueTask = nil
        guard appActive, let delay = Self.nextDueRead(jobs, now: Date(), timing: timing) else { return }
        dueTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.appActive else { return }
            self.dueTask = nil   // the read re-arms it; never cancel the task doing the read
            AppLog.trace("pages", "jobs scope \(self.scope): read at a job's start time")
            await self.refresh(background: true)
        }
    }

    /// Seconds until the read for the soonest job start: `dueLead` after a start ahead (or just passed), `dueRecheck`
    /// while one passed less than `dueWindow` ago and its run isn't out yet; nil with none. Paused, completed and
    /// disabled jobs and jobs already running don't count.
    nonisolated static func nextDueRead(_ jobs: [CronJob], now: Date, timing: JobsStoreTiming = .standard) -> TimeInterval? {
        var soonest: TimeInterval?
        for job in jobs {
            guard job.enabled != false, !JobWords.workIsOut(job), !["paused", "completed", "disabled"].contains(JobWords.jobState(job)),
                  let next = PagesDate.parse(job.nextRunAt) else { continue }
            let ahead = next.timeIntervalSince(now)
            let delay: TimeInterval
            if ahead > -timing.dueLead { delay = ahead + timing.dueLead }
            else {
                // [phone-logs] Backing off: a re-read every 10 s for 2 min was 12 whole-list reads per start (94 jobs
                // across the bots, a start every few minutes), about 1.8 MB a minute.
                let passed = -ahead
                let wait = max(timing.dueRecheck, passed)
                guard passed + wait <= timing.dueWindow else { continue }
                delay = wait
            }
            soonest = min(soonest ?? delay, delay)
        }
        return soonest
    }

    /// [offline] §6.10: the saved list's JSON is at most `cacheLimit` characters (the web's jobs-list-cache rule). The
    /// store itself measures inside `PagesCache.write(_:to:maxBytes:)`; this is the same rule for the unit test.
    nonisolated static func fitsCache(_ saved: PagesCached<[CronJob]>) -> Bool {
        guard let data = try? JSONEncoder().encode(saved) else { return false }
        return data.count <= cacheLimit
    }

    /// One job, fresh (nil when the gateway no longer has it: the caller pops with "Job Removed").
    func reload(_ job: CronJob) async -> CronJob?? {
        do {
            let json = try await PagesREST.json(client, "GET", CronRunOnce.jobPath(job.id), query: [URLQueryItem(name: "profile", value: job.owner)])
            guard let fresh = CronJob(json: json) else { return .some(nil) }
            replace(fresh)
            return .some(fresh)
        } catch {
            if PagesREST.status(error) == 404 {
                remove(job.key)
                onJobRemoved?(job.key)
                return .some(nil)
            }
            return nil
        }
    }

    /// A job's runs, newest first (`?limit=20`), shared between callers of the same moment.
    func loadRuns(_ job: CronJob) async throws -> [CronRun] {
        let client = self.client, id = job.id, owner = job.owner
        return try await runs.read(job.key) { try await Self.readRuns(client, id: id, owner: owner) }
    }

    /// The scope's list, read and decoded off the main thread.
    @concurrent
    nonisolated static func readList(_ client: any GatewayClient, scope: String) async throws -> [CronJob] {
        let json = try await PagesREST.json(client, "GET", listPath, query: [URLQueryItem(name: "profile", value: scope)], timeout: 60)
        return CronJob.list(json)
    }

    nonisolated enum BotWorkingAnswer: Sendable, Equatable {
        /// Job key → "queued" (handed over, waiting its turn) or "claimed" (the bot is on it).
        case jobs([String: String])
        /// 404: no add-on, or one older than 0.9.2 (or not asked since).
        case missing
        case failed
    }

    /// Which jobs' output a bot is still working on, across every profile (the add-on's `GET cron/working`).
    @concurrent
    nonisolated static func readBotWorking(_ client: any GatewayClient, ask: Bool) async -> BotWorkingAnswer {
        guard ask else { return .missing }
        do {
            return .jobs(botWorkingMap(try await PagesREST.json(client, "GET", botWorkingPath, timeout: 60)))
        } catch {
            return PagesREST.status(error) == 404 ? .missing : .failed
        }
    }

    /// `{"jobs": [{"profile", "id", "status", …}]}` → job key → status.
    nonisolated static func botWorkingMap(_ json: JSONValue) -> [String: String] {
        var map: [String: String] = [:]
        for row in json["jobs"]?.array ?? [] {
            guard let id = row["id"]?.string, !id.isEmpty else { continue }
            let profile = row["profile"]?.string ?? ""
            map[(profile.isEmpty ? "default" : profile) + "|" + id] = row["status"]?.string ?? "claimed"
        }
        return map
    }

    /// A job's runs (the web measured ~365 KB), read and decoded off the main thread.
    @concurrent
    nonisolated static func readRuns(_ client: any GatewayClient, id: String, owner: String) async throws -> [CronRun] {
        let json = try await PagesREST.json(client, "GET", CronRunOnce.jobPath(id) + "/runs",
                                            query: [URLQueryItem(name: "limit", value: "20"), URLQueryItem(name: "profile", value: owner)])
        return CronRun.list(json)
    }

    // MARK: Writes

    enum WriteResult: Equatable {
        case done
        case refused            // read-only gateway
        case failed(String)
    }

    enum RunResult: Equatable {
        case started
        case stillRunning
        case refused
        case alreadyRunning(String)
        case restorePauseFailed
        case failed(String)
    }

    private func mark(_ key: String) -> Int {
        nextToken += 1
        busy[key] = nextToken
        onChange?()
        return nextToken
    }

    private func clear(_ key: String, _ token: Int) {
        if busy[key] == token { busy[key] = nil; onChange?() }
    }

    /// How many of the scope's jobs show Running (the row's rule): the Jobs tab's spinner.
    var workingCount: Int { jobs.count(where: { showsRunning($0) || JobWords.isRunning($0) }) }

    func isBusy(_ job: CronJob) -> Bool { busy[job.key] != nil }
    func isStillRunning(_ job: CronJob) -> Bool { stillRunning[job.key] != nil }
    /// The row says "Running…": a Run Now in flight, or one that outlived the wait.
    func showsRunning(_ job: CronJob) -> Bool { runInFlight.contains(job.key) || stillRunning[job.key] != nil }

    /// Jobs (list or detail) screens on screen, counted: a push from the list to a job's detail stays "shown".
    @ObservationIgnored private var showing = 0
    func noteAppear() { showing += 1; if showing == 1 { setVisible(true) } }
    func noteDisappear() { showing = max(0, showing - 1); if showing == 0 { setVisible(false) } }

    /// [jobs] §11.4: a write's own answer is newer than a list read that began before it. That read's answer is dropped
    /// (the old name, the paused state or the deleted row must not come back); every write asks for a fresh read
    /// straight after, which `ReadFlight` runs once the older one has ended.
    func supersedeListRead() {
        guard loading else { return }
        readGeneration += 1
        loading = false
    }

    func replace(_ job: CronJob) {
        guard let index = jobs.firstIndex(where: { $0.key == job.key }) else { return }
        var next = jobs
        next[index] = job
        setJobs(next)
        onChange?()
    }

    func remove(_ key: String) {
        jobs.removeAll { $0.key == key }
        onChange?()
    }

    /// Pause or Resume (no confirmation).
    func setPaused(_ job: CronJob, _ pause: Bool) async -> WriteResult {
        if readOnlyGateway {
            AppLog.note("pages", "job \(pause ? "pause" : "resume") \(AppLog.tag(job.id)) refused: gateway is read-only")
            return .refused
        }
        let token = mark(job.key)
        defer { clear(job.key, token) }
        let start = ContinuousClock.now
        do {
            let json = try await PagesREST.json(client, "POST", CronRunOnce.jobPath(job.id) + (pause ? "/pause" : "/resume"),
                                                query: [URLQueryItem(name: "profile", value: job.owner)])
            if var fresh = CronJob(json: json) {
                if fresh.profile == nil { fresh.profile = job.profile }
                supersedeListRead()   // [jobs]
                replace(fresh)
            }
            Task { await refresh() }
            AppLog.trace("pages", "job \(pause ? "pause" : "resume") \(AppLog.tag(job.id)) ok in \(AppLog.ms(since: start)) ms")
            return .done
        } catch {
            let reason = PagesREST.reason(error)
            AppLog.note("pages", "job \(pause ? "pause" : "resume") \(AppLog.tag(job.id)) failed after \(AppLog.ms(since: start)) ms: \(reason)")
            return .failed(reason)
        }
    }

    func delete(_ job: CronJob) async -> WriteResult {
        if readOnlyGateway {
            AppLog.note("pages", "job delete \(AppLog.tag(job.id)) refused: gateway is read-only")
            return .refused
        }
        let token = mark(job.key)
        defer { clear(job.key, token) }
        let start = ContinuousClock.now
        do {
            _ = try await PagesREST.send(client, "DELETE", CronRunOnce.jobPath(job.id), query: [URLQueryItem(name: "profile", value: job.owner)])
            deletedHere.insert(job.key)
            supersedeListRead()   // [jobs]
            remove(job.key)
            Task { await refresh() }
            AppLog.trace("pages", "job delete \(AppLog.tag(job.id)) ok in \(AppLog.ms(since: start)) ms")
            return .done
        } catch {
            if PagesREST.status(error) == 404 {
                AppLog.trace("pages", "job delete \(AppLog.tag(job.id)): already gone (404), removed locally")
                remove(job.key)
                return .done
            }
            let reason = PagesREST.reason(error)
            AppLog.note("pages", "job delete \(AppLog.tag(job.id)) failed after \(AppLog.ms(since: start)) ms: \(reason)")
            return .failed(reason)
        }
    }

    /// Run Now (after the caller asked). One run at a time per job.
    func runNow(_ job: CronJob) async -> RunResult {
        if readOnlyGateway {
            AppLog.note("pages", "job run now \(AppLog.tag(job.id)) refused: gateway is read-only")
            return .refused
        }
        guard busy[job.key] == nil else { return .alreadyRunning("Job is already running or was claimed by another scheduler") }
        let token = mark(job.key)
        runInFlight.insert(job.key)
        defer { runInFlight.remove(job.key); clear(job.key, token) }
        let start = ContinuousClock.now
        do {
            let answer = try await CronRunOnce.run(client: client, jobId: job.id, profile: job.owner, timeout: timing.runTimeout)
            if var fresh = answer {
                if fresh.profile == nil { fresh.profile = job.profile }
                supersedeListRead()   // [jobs]
                replace(fresh)
            }
            Task { await refresh() }
            AppLog.trace("pages", "job run now \(AppLog.tag(job.id)) started in \(AppLog.ms(since: start)) ms")
            return .started
        } catch is CronRestorePauseError {
            AppLog.note("pages", "job run now \(AppLog.tag(job.id)) restore-pause failed after \(AppLog.ms(since: start)) ms")
            Task { await refresh() }
            return .restorePauseFailed
        } catch {
            if PagesREST.isSlowAnswer(error) {
                AppLog.trace("pages", "job run now \(AppLog.tag(job.id)) still running after \(AppLog.ms(since: start)) ms, will recheck in \(timing.stillRunningRecheck)")
                stillRunning[job.key] = .some(job.lastRunAt)
                stillRunningSince[job.key] = Date()
                stillRunningSeenOut.remove(job.key)
                onChange?()
                let gap = timing.stillRunningRecheck
                Task { [weak self] in
                    try? await Task.sleep(for: gap)
                    _ = await self?.reload(job)
                    await self?.refresh()
                }
                return .stillRunning
            }
            if PagesREST.status(error) == 409 {
                let reason = PagesREST.reason(error)
                AppLog.trace("pages", "job run now \(AppLog.tag(job.id)) already running: \(reason)")
                return .alreadyRunning(reason)
            }
            let reason = PagesREST.reason(error)
            AppLog.note("pages", "job run now \(AppLog.tag(job.id)) failed after \(AppLog.ms(since: start)) ms: \(reason)")
            return .failed(reason)
        }
    }

    /// A run that outlived the wait ends when a read shows a newer last run; or, with no new run time (a gateway
    /// restart, a killed run), when a read that had shown it out shows it out no more, or `stillRunningGiveUp` after
    /// the wait (audit 863: it said Running… until the app restarted).
    func settleStillRunning(now: Date = Date()) {
        guard !stillRunning.isEmpty else { return }
        for (key, before) in stillRunning {
            let job = job(key: key)
            let ended: Bool
            if let job, job.lastRunAt == before {
                if JobWords.isRunning(job) {
                    stillRunningSeenOut.insert(key)
                    ended = false
                } else {
                    ended = stillRunningSeenOut.contains(key)
                        || now.timeIntervalSince(stillRunningSince[key] ?? now) >= timing.stillRunningGiveUp
                }
            } else {
                ended = true   // gone, or it ran
            }
            guard ended else { continue }
            stillRunning[key] = nil
            stillRunningSince[key] = nil
            stillRunningSeenOut.remove(key)
        }
    }

    /// Sign-out: forget what this store holds in memory (the files go with `PagesCache.purge`).
    func reset() {
        stop()
        readGeneration += 1     // [13-6] a read on its way (its bots-working half still out) neither shows nor writes the cache
        jobs = []
        botWorking = [:]
        hasList = false
    }
}
