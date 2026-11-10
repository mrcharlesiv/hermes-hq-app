// Run Now and run history reads (docs/spec/1x-pages.md §3.6, §3.7): the web's `src/cron-run-once.ts` ported.
// The gateway's trigger enables a paused job and answers only when the run finishes; a paused job is paused again as
// soon as its activation is seen (the claim keeps the run), and once more when the trigger settles.

import Foundation

nonisolated struct CronRestorePauseError: Error, LocalizedError, Sendable {
    var underlying: String
    var errorDescription: String? { "Couldn’t restore the job’s paused state after running. Check its schedule." }
}

nonisolated enum CronRunOnce {
    static func jobPath(_ id: String) -> String { "/api/cron/jobs/" + PagesREST.segment(id) }

    /// Runs a job once on its owner profile. Throws the read error when the state can't be read first (nothing runs),
    /// `CronRestorePauseError` when a paused job could not be paused again, else the trigger's own error.
    /// Returns the job the trigger answered with (nil when it answered no job).
    static func run(client: any GatewayClient, jobId: String, profile: String?, timeout: TimeInterval = 120,
                    pollInterval: Duration = .milliseconds(250)) async throws -> CronJob? {
        let path = jobPath(jobId)
        let tag = AppLog.tag(jobId)
        func query(_ owner: String?) -> [URLQueryItem] { owner.map { [URLQueryItem(name: "profile", value: $0)] } ?? [] }
        let beforeJSON = try await PagesREST.json(client, "GET", path, query: query(profile))
        let before = CronJob(json: beforeJSON)
        let ownerName = beforeJSON["profile_name"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            ?? beforeJSON["profile"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? profile
        let owner = query(ownerName)
        let paused = before?.enabled == false || before?.state == "paused"
        if paused { AppLog.trace("pages", "run now will un-pause job \(tag) for the run, then restore it") }
        let settled = PagesFlag()
        let trigger = Task { () throws -> JSONValue in
            defer { settled.set() }
            return try await PagesREST.json(client, "POST", path + "/trigger", query: owner, timeout: timeout)
        }
        if paused {
            while !settled.value {
                try? await Task.sleep(for: pollInterval)
                if settled.value { break }
                do {
                    let current = try await PagesREST.json(client, "GET", path, query: owner, timeout: 2)
                    if current["enabled"]?.bool == true && current["state"]?.string != "paused" {
                        _ = try? await PagesREST.json(client, "POST", path + "/pause", query: owner)
                        AppLog.trace("pages", "run now paused job \(tag) again once its run was seen to start")
                        break
                    }
                } catch {
                    // A read failure can't cancel the remote run; the restore below reports a pause error.
                }
            }
        }
        let result = await trigger.result
        if paused {
            do {
                _ = try await PagesREST.json(client, "POST", path + "/pause", query: owner)
            } catch {
                // A finished one-shot can remove itself (404); anything else must be said.
                let gone = PagesREST.status(error) == 404 || String(describing: error).range(of: "not found", options: .caseInsensitive) != nil
                if !gone {
                    AppLog.note("pages", "run now couldn't restore job \(tag) to paused: \(PagesREST.reason(error))")
                    throw CronRestorePauseError(underlying: PagesREST.reason(error))
                }
            }
        }
        let answer = try result.get()
        return CronJob(json: answer)
    }
}

/// Callers in the same moment (within `joinWithin` of a read starting) share that read; a later caller gets one read
/// that starts after the one in flight, shared by every such caller; a finished read is never reused
/// (`sharedRead`, `src/cron-run-once.ts:59-79`).
@MainActor
final class SharedReads<Value: Sendable> {
    private struct Entry {
        var token: Int
        var task: Task<Value, Error>
        var started: ContinuousClock.Instant
        var trailing: Task<Value, Error>?
    }
    private var entries: [String: Entry] = [:]
    private var nextToken = 0
    let joinWithin: Duration

    init(joinWithin: Duration = .milliseconds(250)) { self.joinWithin = joinWithin }

    func read(_ key: String, _ load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if var entry = entries[key] {
            if ContinuousClock.now - entry.started <= joinWithin { return try await entry.task.value }
            if entry.trailing == nil {
                let first = entry.task
                entry.trailing = Task { [weak self] in
                    _ = try? await first.value
                    guard let self else { throw CancellationError() }
                    return try await self.read(key, load)
                }
                entries[key] = entry
            }
            return try await entry.trailing!.value
        }
        nextToken += 1
        let token = nextToken
        let task = Task { [weak self] () throws -> Value in
            defer { self?.finished(key, token) }
            return try await load()
        }
        entries[key] = Entry(token: token, task: task, started: .now)
        return try await task.value
    }

    private func finished(_ key: String, _ token: Int) {
        if entries[key]?.token == token { entries[key] = nil }
    }
}

/// A thread-safe one-way flag.
nonisolated final class PagesFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return raised }
    func set() { lock.lock(); raised = true; lock.unlock() }
}
