// P-U3: Run Now's paused-job dance and the shared run-history reads (`S/cron-run-once.test.ts`), against a fake client.

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

struct RunOnceTests {
    @Test func pausesAsSoonAsActivationIsObservedWhileTheWorkerIsStillRunning() async throws {
        let finish = AsyncStream<Void>.makeStream()
        let reads = Mutex(0)
        let client = PagesFakeClient { request in
            switch (request.method, request.path) {
            case ("GET", "/api/cron/jobs/1"):
                let n = reads.withLock { $0 += 1; return $0 }
                return n == 1 ? ["enabled": false, "profile": "qa", "id": "1"] : ["enabled": true, "state": "scheduled", "id": "1"]
            case ("POST", "/api/cron/jobs/1/trigger"):
                for await _ in finish.stream { break }
                return ["enabled": false, "id": "1"]
            default:
                return ["enabled": false, "state": "paused", "id": "1"]
            }
        }
        let run = Task { try await CronRunOnce.run(client: client, jobId: "1", profile: nil, timeout: 5, pollInterval: .milliseconds(50)) }
        // Wait for the first pause (on activation) while the trigger is still out.
        for _ in 0..<100 where !client.log.contains(where: { $0.path.hasSuffix("/pause") }) { try await Task.sleep(for: .milliseconds(20)) }
        let firstPause = try #require(client.log.first { $0.path.hasSuffix("/pause") })
        #expect(firstPause.method == "POST" && firstPause.query["profile"] == "qa")
        finish.continuation.yield(())
        _ = try await run.value
        #expect(client.log.filter { $0.path.hasSuffix("/pause") }.count == 2)
    }

    @Test func preservesAPausedJobOnItsCapturedOwner() async throws {
        let client = PagesFakeClient { request in
            switch (request.method, request.path) {
            case ("GET", _): return ["enabled": false, "profile_name": "owner", "id": "job/1"]
            case ("POST", let p) where p.hasSuffix("/trigger"): return ["enabled": true, "id": "job/1"]
            default: return ["enabled": false, "id": "job/1"]
            }
        }
        _ = try await CronRunOnce.run(client: client, jobId: "job/1", profile: "first", timeout: 5, pollInterval: .milliseconds(250))
        #expect(client.logLines == [
            "GET /api/cron/jobs/job%2F1?profile=first",
            "POST /api/cron/jobs/job%2F1/trigger?profile=owner",
            "POST /api/cron/jobs/job%2F1/pause?profile=owner",
        ])
    }

    @Test func restoresPauseEvenIfTheTriggerFails() async throws {
        let client = PagesFakeClient { request in
            if request.path.hasSuffix("/trigger") { throw httpError(500, "run failed") }
            if request.method == "GET" { return ["state": "paused", "id": "1"] }
            return [:]
        }
        await #expect(throws: HTTPError.self) {
            _ = try await CronRunOnce.run(client: client, jobId: "1", profile: nil, timeout: 5)
        }
        #expect(client.log.last?.path == "/api/cron/jobs/1/pause")
        #expect(client.log.last?.method == "POST")
    }

    @Test func keepsScheduledJobsScheduledAndDoesNotRunIfTheStateCannotBeRead() async throws {
        let client = PagesFakeClient { _ in ["enabled": true, "id": "1"] }
        _ = try await CronRunOnce.run(client: client, jobId: "1", profile: nil, timeout: 5)
        #expect(client.log.count == 2)
        let offline = PagesFakeClient { _ in throw GatewayFailure.offline }
        await #expect(throws: GatewayFailure.self) {
            _ = try await CronRunOnce.run(client: offline, jobId: "1", profile: nil, timeout: 5)
        }
        #expect(offline.log.count == 1)
    }

    @Test func reportsRestorationFailureButToleratesARemovedOneShot() async throws {
        let failing = PagesFakeClient { request in
            if request.method == "GET" { return ["enabled": false, "id": "1"] }
            if request.path.hasSuffix("/pause") { throw GatewayFailure.offline }
            return [:]
        }
        await #expect(throws: CronRestorePauseError.self) {
            _ = try await CronRunOnce.run(client: failing, jobId: "1", profile: nil, timeout: 5)
        }
        let removed = PagesFakeClient { request in
            if request.method == "GET" { return ["enabled": false, "id": "1"] }
            if request.path.hasSuffix("/pause") { throw httpError(404, "Job not found") }
            return [:]
        }
        let answer = try await CronRunOnce.run(client: removed, jobId: "1", profile: nil, timeout: 5)
        #expect(answer == nil)
    }
}

@MainActor
struct SharedReadsTests {
    @Test func sharesOneReadBetweenCallersInTheSameMomentAndReadsAgainOnceItIsDone() async throws {
        let reads = SharedReads<[String]>()
        let count = Mutex(0)
        let load: @Sendable () async throws -> [String] = { count.withLock { $0 += 1 }; try await Task.sleep(for: .milliseconds(30)); return ["run"] }
        async let a = reads.read("job-1", load)
        async let b = reads.read("job-1", load)
        let (x, y) = try await (a, b)
        #expect(x == y)
        #expect(count.withLock { $0 } == 1)
        _ = try await reads.read("job-1", load)
        _ = try await reads.read("job-2", load)
        #expect(count.withLock { $0 } == 3)
    }

    @Test func givesACallerThatArrivesMidReadAReadThatStartsAfterIt() async throws {
        let reads = SharedReads<[String]>(joinWithin: .milliseconds(50))
        let count = Mutex(0)
        let load: @Sendable () async throws -> [String] = {
            let n = count.withLock { $0 += 1; return $0 }
            try await Task.sleep(for: .milliseconds(200))
            return n == 1 ? ["before"] : ["before", "after"]
        }
        let first = Task { try await reads.read("job-4", load) }
        try await Task.sleep(for: .milliseconds(100))
        let tick = Task { try await reads.read("job-4", load) }
        let lastRun = Task { try await reads.read("job-4", load) }
        #expect(try await first.value == ["before"])
        #expect(try await tick.value == ["before", "after"])
        #expect(try await lastRun.value == ["before", "after"])
        #expect(count.withLock { $0 } == 2)
    }

    @Test func doesNotKeepAFailedRead() async throws {
        let reads = SharedReads<[String]>()
        let count = Mutex(0)
        let load: @Sendable () async throws -> [String] = {
            let n = count.withLock { $0 += 1; return $0 }
            if n == 1 { throw GatewayFailure.offline }
            return ["run"]
        }
        await #expect(throws: GatewayFailure.self) { _ = try await reads.read("job-3", load) }
        #expect(try await reads.read("job-3", load) == ["run"])
        #expect(count.withLock { $0 } == 2)
    }
}
