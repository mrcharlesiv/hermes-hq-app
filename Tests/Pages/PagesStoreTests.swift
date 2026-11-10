// Stores and helpers of the pages: the Kanban tab rule (§4.2), the Jobs store's writes and caches, how files open and
// say why they can't (§5.6), a run document's answer first (§3.7), a prompt's placeholders kept (§3.5).

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

struct KanbanAvailabilityTests {
    @Test func boardsWithTasksTurnKanbanOn() async {
        let on = PagesFakeClient { _ in ["boards": [["slug": "a", "total": 0], ["slug": "b", "total": 3]], "current": "a"] }
        #expect(await KanbanAvailability.probe(on) == .on)
        let unused = PagesFakeClient { _ in ["boards": [["slug": "a", "total": 0]], "current": "a"] }
        #expect(await KanbanAvailability.probe(unused) == .unused)
        let absent = PagesFakeClient { _ in throw httpError(404, "Not Found") }
        #expect(await KanbanAvailability.probe(absent) == .absent)
        let gated = PagesFakeClient { _ in throw httpError(403, "plugin disabled") }
        #expect(await KanbanAvailability.probe(gated) == .absent)
        let offline = PagesFakeClient { _ in throw GatewayFailure.unreachable }
        #expect(await KanbanAvailability.probe(offline) == nil, "a transport failure keeps the last decision")
        #expect(on.logLines == ["GET /api/plugins/kanban/boards"])
    }
}

@MainActor
struct JobsStoreTests {
    nonisolated static func jobs(_ ids: [String]) -> JSONValue {
        .array(ids.map { ["id": .string($0), "name": .string("Job \($0)"), "profile": "inbox", "enabled": true, "state": "scheduled"] })
    }

    /// The Jobs tab's spinner starts with a run: a read just after the soonest start, then again while that start has
    /// passed unclaimed, each wait as long as the time since the start (at least 10 s), for 2 min; paused jobs, jobs
    /// already running and long-overdue ones are left out.
    @Test func aReadIsSetForJustAfterTheSoonestStart() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func job(_ id: String, startsIn seconds: TimeInterval, _ extra: [String: JSONValue] = [:]) throws -> CronJob {
            var json: [String: JSONValue] = ["id": .string(id), "name": .string(id), "profile": "inbox", "enabled": true, "state": "scheduled",
                                             "next_run_at": .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(seconds)))]
            json.merge(extra) { $1 }
            return try #require(CronJob(json: .object(json)))
        }
        #expect(JobsStore.nextDueRead([], now: now) == nil)
        #expect(JobsStore.nextDueRead([try job("a", startsIn: 600), try job("b", startsIn: 60)], now: now) == 63)
        #expect(JobsStore.nextDueRead([try job("a", startsIn: -1)], now: now) == 2, "just passed: read at +3 s")
        #expect(JobsStore.nextDueRead([try job("a", startsIn: -5)], now: now) == 10, "passed, not claimed yet: at least 10 s")
        #expect(JobsStore.nextDueRead([try job("a", startsIn: -30)], now: now) == 30, "backing off: as long again as it has been")
        #expect(JobsStore.nextDueRead([try job("a", startsIn: -70)], now: now) == nil, "the next try would land past the 2 min window")
        // [phone-logs] One unclaimed start costs 5 reads (+3, +13, +26, +52, +104 s), not 12.
        var at: TimeInterval = 3, reads = 1
        while let wait = JobsStore.nextDueRead([try job("a", startsIn: -at)], now: now) { at += wait; reads += 1 }
        #expect(reads == 5 && at <= 120)
        #expect(JobsStore.nextDueRead([try job("a", startsIn: -600)], now: now) == nil, "long overdue")
        #expect(JobsStore.nextDueRead([try job("a", startsIn: 60, ["state": "paused"])], now: now) == nil)
        #expect(JobsStore.nextDueRead([try job("a", startsIn: 60, ["enabled": false])], now: now) == nil)
    }

    @Test func readOnlyRefusesEveryWriteBeforeSending() async {
        let client = PagesFakeClient { _ in Self.jobs(["a"]) }
        let store = JobsStore(client: client, account: client.account, directory: nil)
        store.readOnlyGateway = true
        await store.refresh()
        let job = store.jobs[0]
        #expect(await store.runNow(job) == .refused)
        #expect(await store.setPaused(job, true) == .refused)
        #expect(await store.delete(job) == .refused)
        #expect(client.log.allSatisfy { $0.method == "GET" })
    }

    @Test func aScopeSwitchDropsTheOldScopesAnswer() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let client = PagesFakeClient { request in
            if request.query["profile"] == "all" { for await _ in gate.stream { break } ; return Self.jobs(["old"]) }
            return Self.jobs(["new"])
        }
        let store = JobsStore(client: client, account: client.account, directory: nil)
        let slow = Task { await store.refresh() }
        try await Task.sleep(for: .milliseconds(50))
        store.setScope("inbox")
        try await Task.sleep(for: .milliseconds(100))
        gate.continuation.yield(())
        await slow.value
        #expect(store.jobs.map(\.id) == ["new"])
        #expect(store.scope == "inbox")
    }

    // [13-6] Signed out while the list had landed and the bots-working read was still out: the late answer writes no
    // cache back for the account that left.
    @Test func aReadLandingAfterSignOutWritesNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pages-jobs-\(UUID().uuidString)")
        let gate = AsyncStream<Void>.makeStream()
        let client = PagesFakeClient { request in
            if request.path == JobsStore.botWorkingPath { for await _ in gate.stream { break }; return ["jobs": []] }
            return Self.jobs(["a"])
        }
        let store = JobsStore(client: client, account: client.account, directory: dir)
        let slow = Task { await store.refresh() }
        try await Task.sleep(for: .milliseconds(80))
        store.reset()
        gate.continuation.yield(())
        await slow.value
        PagesCache.flush()
        #expect(store.jobs.isEmpty && !store.hasList)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "jobs-all.json").path), "no cache for the account that left")
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func listsPaintFromTheDiskCacheFirst() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pages-jobs-\(UUID().uuidString)")
        let client = PagesFakeClient { _ in Self.jobs(["b", "a"]) }
        let store = JobsStore(client: client, account: client.account, directory: dir)
        await store.refresh()
        #expect(store.jobs.map(\.id) == ["a", "b"], "by title")
        PagesCache.flush()
        let again = JobsStore(client: PagesFakeClient { _ in throw GatewayFailure.offline }, account: client.account, directory: dir)
        #expect(again.hasList && again.jobs.map(\.id) == ["a", "b"], "the cached list, before any read")
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func pauseReplacesTheJobWithTheAnswer() async throws {
        let client = PagesFakeClient { request in
            if request.method == "POST" { return ["id": "a", "name": "Job a", "profile": "inbox", "enabled": false, "state": "paused"] }
            return Self.jobs(["a"])
        }
        let store = JobsStore(client: client, account: client.account, directory: nil)
        await store.refresh()
        #expect(await store.setPaused(store.jobs[0], true) == .done)
        #expect(JobWords.jobState(store.jobs[0]) == "paused")
        #expect(client.log.contains { $0.description == "POST /api/cron/jobs/a/pause?profile=inbox" })
    }

    @Test func aBotStillOnTheOutputKeepsTheJobRunning() async throws {
        let working = Mutex<JSONValue>(["jobs": [["profile": "inbox", "id": "a", "run": "r1", "status": "claimed"],
                                                 ["profile": "ivy", "id": "b", "status": "queued"]]])
        let client = PagesFakeClient { request in
            if request.path == JobsStore.botWorkingPath { return working.withLock { $0 } }
            if request.method == "POST" { return ["id": "a", "name": "Job a", "profile": "inbox", "enabled": true, "state": "scheduled"] }
            return Self.jobs(["a", "b"])
        }
        let store = JobsStore(client: client, account: client.account, directory: nil)
        await store.refresh()
        #expect(store.jobs.map(\.botWorking) == ["claimed", nil], "b is another profile's job of the same id")
        #expect(JobWords.jobState(store.jobs[0]) == "running" && JobWords.section(store.jobs[0]) == .running)
        #expect(!JobWords.isRunning(store.jobs[1]))
        #expect(client.log.contains { $0.description == "GET \(JobsStore.botWorkingPath)" })
        // A write's answer says nothing about the bot: the job stays Running.
        #expect(await store.setPaused(store.jobs[0], false) == .done)
        #expect(store.jobs[0].botWorking == "claimed")
        working.withLock { $0 = ["jobs": []] }
        await store.refresh()
        #expect(store.jobs.allSatisfy { $0.botWorking == nil && !JobWords.isRunning($0) }, "the bot is done")
    }

    @Test func anAddOnWithoutTheRouteIsAskedOncePerConnection() async throws {
        let client = PagesFakeClient { request in
            if request.path == JobsStore.botWorkingPath { throw httpError(404, "Not Found") }
            return Self.jobs(["a"])
        }
        let asked = { client.log.filter { $0.path == JobsStore.botWorkingPath }.count }
        let store = JobsStore(client: client, account: client.account, directory: nil)
        await store.refresh()
        await store.refresh()
        #expect(asked() == 1)
        #expect(store.jobs[0].botWorking == nil)
        store.gatewayReady(changeEvents: true)   // a reconnect: the add-on may have been updated
        await store.refresh()
        #expect(asked() == 2)
    }

    /// [phone-logs] A return from the background read the whole list twice in the same second: the foreground's read
    /// and `gateway.ready`'s. A read that started a moment ago covers the reconnect.
    @Test func aReconnectRightAfterAReadDoesNotReadTheListAgain() async throws {
        let client = PagesFakeClient { _ in Self.jobs(["a"]) }
        let lists = { client.log.filter { $0.path == JobsStore.listPath }.count }
        let store = JobsStore(client: client, account: client.account, directory: nil)
        await store.refresh()
        store.gatewayReady(changeEvents: true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(lists() == 1)
        let stale = JobsStore(client: client, account: client.account, directory: nil, timing: JobsStoreTiming(freshRead: 0))
        await stale.refresh()
        stale.gatewayReady(changeEvents: true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(lists() == 3, "with no fresh read the reconnect reads")
    }

    /// [phone-logs] Only a launch or a return from the background reads the list: becoming active after a moment under
    /// Notification Center or Control Center (the app never left) reads nothing.
    @Test func becomingActiveWithoutLeavingDoesNotReadTheList() async throws {
        let client = PagesFakeClient { _ in Self.jobs(["a"]) }
        let lists = { client.log.filter { $0.path == JobsStore.listPath }.count }
        let store = JobsStore(client: client, account: client.account, directory: nil)
        store.appDidBecomeActive()                                   // the launch
        #expect(await waitUntil(timeout: .seconds(2)) { lists() == 1 })
        store.appDidBecomeActive()                                   // Control Center closed: not a return
        try await Task.sleep(for: .milliseconds(300))
        #expect(lists() == 1)
        store.appDidEnterBackground()
        store.appDidBecomeActive()                                   // a real return
        #expect(await waitUntil(timeout: .seconds(2)) { lists() == 2 })
        store.stop()
    }

    @Test func aFailedAddOnReadKeepsWhatWasKnown() async throws {
        let fail = Mutex(false)
        let client = PagesFakeClient { request in
            if request.path == JobsStore.botWorkingPath {
                if fail.withLock({ $0 }) { throw GatewayFailure.timeout }
                return ["jobs": [["profile": "inbox", "id": "a", "status": "queued"]]]
            }
            return Self.jobs(["a"])
        }
        let store = JobsStore(client: client, account: client.account, directory: nil)
        await store.refresh()
        #expect(store.jobs[0].botWorking == "queued")
        fail.withLock { $0 = true }
        await store.refresh()
        #expect(store.jobs[0].botWorking == "queued", "Running doesn't blink off for one failed read")
        await store.refresh()
        #expect(store.jobs[0].botWorking == nil, "nor stays on when the add-on keeps failing")
    }

    /// Audit 863 (08c-1): a run that outlived the wait and ended with no new run time (a gateway restart, a killed run)
    /// stops saying Running… once a read that showed it out shows it out no more, or after the give-up time.
    @Test func aStillRunningRunEndsWithoutANewRunTime() async throws {
        let status = Mutex<JSONValue?>("running")
        let client = PagesFakeClient { request in
            if request.path.hasSuffix("/trigger") { throw GatewayFailure.timeout }
            var job: JSONValue = ["id": "a", "name": "Job a", "profile": "inbox", "enabled": true, "state": "scheduled"]
            if let value = status.withLock({ $0 }), case .object(var fields) = job {
                fields["latest_execution"] = ["status": value]
                job = .object(fields)
            }
            if request.path == "/api/cron/jobs" { return .array([job]) }
            return job
        }
        let store = JobsStore(client: client, account: client.account, directory: nil,
                              timing: JobsStoreTiming(stillRunningRecheck: .seconds(30), stillRunningGiveUp: 600))
        await store.refresh()
        #expect(await store.runNow(store.jobs[0]) == .stillRunning)
        await store.refresh()
        #expect(store.showsRunning(store.jobs[0]), "the gateway says it runs")
        status.withLock { $0 = "failed" }
        await store.refresh()
        #expect(!store.showsRunning(store.jobs[0]), "out, then not out: over")

        // A Hermes that never says a run is out: over after the give-up time.
        status.withLock { $0 = nil }
        #expect(await store.runNow(store.jobs[0]) == .stillRunning)
        await store.refresh()
        #expect(store.showsRunning(store.jobs[0]))
        store.settleStillRunning(now: Date().addingTimeInterval(601))
        #expect(!store.showsRunning(store.jobs[0]))
    }

    @Test func aSlowTriggerIsStillRunningNotAFailure() async throws {
        let client = PagesFakeClient { request in
            if request.path.hasSuffix("/trigger") { throw GatewayFailure.timeout }
            if request.path == "/api/cron/jobs" { return Self.jobs(["a"]) }
            return ["id": "a", "enabled": true, "state": "scheduled", "profile": "inbox"]
        }
        let store = JobsStore(client: client, account: client.account, directory: nil, timing: JobsStoreTiming(stillRunningRecheck: .seconds(30)))
        await store.refresh()
        let job = store.jobs[0]
        #expect(await store.runNow(job) == .stillRunning)
        #expect(store.showsRunning(job))
        let busy = PagesFakeClient { request in
            if request.path.hasSuffix("/trigger") { throw httpError(409, "Job is already running or was claimed by another scheduler") }
            if request.path == "/api/cron/jobs" { return Self.jobs(["a"]) }
            return ["id": "a", "enabled": true, "profile": "inbox"]
        }
        let other = JobsStore(client: busy, account: busy.account, directory: nil)
        await other.refresh()
        #expect(await other.runNow(other.jobs[0]) == .alreadyRunning("Job is already running or was claimed by another scheduler"))
    }
}

struct ArtifactFilesTests {
    private func record(_ value: String, _ kind: ArtifactRecord.Kind = .file) -> ArtifactRecord {
        ArtifactRecord(id: "s:\(value)", kind: kind, value: value, href: value, label: ArtifactCollector.label(value, kind: kind),
                       sessionId: "s", profile: "research", sessionTitle: "t", timestamp: 0)
    }

    @Test func eachKindOpensInItsViewer() {
        #expect(ArtifactFiles.opening(record("https://example.org/x", .link)) == .link)
        #expect(ArtifactFiles.opening(record("/a/b.png", .image)) == .image)
        #expect(ArtifactFiles.opening(record("/a/summary.md")) == .text(markdown: true, language: nil))
        #expect(ArtifactFiles.opening(record("/a/App.swift")) == .text(markdown: false, language: "swift"))
        #expect(ArtifactFiles.opening(record("/a/log.txt")) == .text(markdown: false, language: nil))
        #expect(ArtifactFiles.opening(record("/a/index.html")) == .html)
        #expect(ArtifactFiles.opening(record("/a/report.pdf")) == .quickLook)
        #expect(ArtifactFiles.opening(record("/a/export.csv")) == .quickLook)
        #expect(ArtifactFiles.query(record("/a/report.pdf")).map(\.name) == ["path", "session_id", "profile"])
        let log = ArtifactFiles.opening(record("/a/log.txt"))
        #expect(ArtifactFiles.opensAsText(log, bytes: 40_000))
        #expect(!ArtifactFiles.opensAsText(log, bytes: 3 << 20), "a 3 MiB log opens in Quick Look")
        #expect(!ArtifactFiles.opensAsText(.quickLook, bytes: 10))
    }

    @Test func failuresSayWhyInWords() {
        #expect(ArtifactFiles.failureText(httpError(404, "File not found"), image: false)
                == "This file is no longer on the computer running Hermes. It may have been moved or deleted.")
        #expect(ArtifactFiles.failureText(httpError(403, "no"), image: false) == "The computer running Hermes does not allow reading this file.")
        #expect(ArtifactFiles.failureText(httpError(413, "big"), image: true) == "This image is too large to preview.")
        #expect(ArtifactFiles.failureText(GatewayFailure.responseTooLarge, image: false) == "This file is too large to open on this iPhone.")
        #expect(ArtifactFiles.failureText(httpError(400, "Session working directory is unavailable"), image: false)
                == "From an older session whose folder is unknown.")
        #expect(ArtifactFiles.failureText(httpError(400, "bad"), image: false) == "The gateway can't open this file path.")
        #expect(ArtifactFiles.failureText(GatewayFailure.timeout, image: false) == "The computer running Hermes took too long to answer. Try again in a moment.")
        #expect(ArtifactFiles.isMissing(httpError(404, "x")) && ArtifactFiles.isMissing(httpError(400, "x")))
        #expect(!ArtifactFiles.isMissing(httpError(403, "x")))
    }

    @Test func linkFailuresAreAskedAgainAndRefusalsAreNot() {
        let transient: [any Error] = [URLError(.notConnectedToInternet), GatewayFailure.heldUnreachable, GatewayFailure.timeout,
                                      GatewayFailure.tailscaleOff, httpError(503, "down"), httpError(429, "slow"), CancellationError()]
        for error in transient { #expect(ArtifactFiles.isTransient(error), "\(error)") }
        let permanent: [any Error] = [httpError(404, "x"), httpError(400, "x"), httpError(403, "x"), httpError(413, "x"),
                                      RemoteImageFetch.Refused(reason: "http"), GatewayFailure.responseTooLarge,
                                      PagesMessageError("This image could not be read."), URLError(.cancelled)]
        for error in permanent { #expect(!ArtifactFiles.isTransient(error), "\(error)") }
    }

    @Test func aRunDocumentReadsItsAnswerFirst() {
        let doc = "# Cron Job: Disk space check\n\n**Job ID:** j-script\n\n## Prompt\n\nRun check_disk.sh.\n\n## Response\n\nDisk 71% used.\n"
        let shown = ArtifactFiles.runDocumentFirst(doc)
        #expect(shown == "# Cron Job: Disk space check\n\n**Job ID:** j-script\n\n## Response\n\nDisk 71% used.\n\n## Prompt\n\nRun check_disk.sh.\n")
        let already = "# Head\n\n## Response\n\nok\n"
        #expect(ArtifactFiles.runDocumentFirst(already) == already, "an answer already first is left as it is")
        #expect(ArtifactFiles.runDocumentFirst("no sections") == "no sections")
    }

    @Test func dataURLsDecode() throws {
        #expect(try ArtifactFiles.decodeDataURL("data:image/png;base64,YQ==") == Data("a".utf8))
        #expect(throws: PagesMessageError.self) { try ArtifactFiles.decodeDataURL("nonsense") }
    }

    @Test func aPromptKeepsItsPlaceholders() {
        #expect(PagesMarkdown.promptMarkdown("Open <cwd> & read `a <b>`") == "Open &lt;cwd> &amp; read `a <b>`")
        #expect(PagesMarkdown.promptMarkdown("```\n<x>\n```\n<y>") == "```\n<x>\n```\n&lt;y>")
    }

    /// [preview-tables] A file's Preview keeps one card place per table (the card is laid over it); other pages read a
    /// table as lines.
    @Test func previewTablesAreCardPlaces() async {
        let text = "Intro\n\n| Sender | Date | Note |\n|---|---|---|\n| MailPrefs (most junk) | 2026-10-18 | active to 2036 |\n\nEnd\n"
        func cards(_ attributed: NSAttributedString) -> [PreviewTableAttachment] {
            var found: [PreviewTableAttachment] = []
            attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
                if let card = value as? PreviewTableAttachment { found.append(card) }
            }
            return found
        }
        let preview = await ArtifactTextViewController.renderPreview(text, category: .large, label: .label, label2: .secondaryLabel).value
        let placed = cards(preview)
        #expect(placed.count == 1)
        #expect(placed.first?.table.rows.count == 1)
        #expect((placed.first?.height ?? 0) > (placed.first?.grid.size.height ?? 0), "the footer is part of the place")
        #expect(preview.string.contains("Intro") && preview.string.contains("End"))
        let lined = PagesMarkdown.attributed(text, category: .large)
        #expect(cards(lined).isEmpty)
        #expect(lined.string.contains("MailPrefs"))
    }

    @Test func frontMatterReadsAsFacts() {
        let (facts, body) = ArtifactTextViewController.frontMatter("---\ntitle: Morning reading\ntags:\n- agents\n- memory\n---\n\n# Body\n")
        #expect(facts.map(\.0) == ["Title", "Tags"])
        #expect(facts.map(\.1) == ["Morning reading", "agents, memory"])
        #expect(body == "\n# Body\n")
    }
}
