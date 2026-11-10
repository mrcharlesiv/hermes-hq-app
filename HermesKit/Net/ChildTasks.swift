// `withTaskGroup` without a TaskGroup. Build 3 (TestFlight) aborted on a cooperative thread with
// "libc++abi: Pure virtual function called!" from swift::AsyncTask::completeFuture: a group child finishing into a task
// group whose destructor had already run (the group's are the only vtables in libswift_Concurrency). Reproduced in the
// simulator with an optimized (-O) build: the Artifacts page's per-profile listing group
// (ArtifactsStore.listSessions) aborts within seconds of opening More › Artifacts; Debug builds never do. The app's
// groups now run their children as plain tasks feeding a mailbox, so there is no TaskGroup object to outlive. Same
// contract as the group they replace: `next()` hands back results in completion order and nil once nothing is
// pending, the caller's cancellation reaches every child, and `withChildTasks` returns only after every child has
// finished. The mailbox isn't an AsyncStream: a stream's `next()` gives up (nil) the moment the caller is cancelled,
// so a cancelled group returned with its children still running (ChildTasksTests.cancellingTheCallerCancelsTheChildren,
// 2026-11-09); a TaskGroup's `next()` keeps waiting, and so does this one.

import Foundation
import Synchronization

/// Children started by `addTask` and the results they hand back. Use it only from the task that runs `withChildTasks`
/// (like a `TaskGroup`); `cancelAll()` may be called from anywhere.
nonisolated final class ChildTasks<Output: Sendable>: @unchecked Sendable {
    private let mailbox = Mailbox<Output>()
    /// Owner-only (the task inside `withChildTasks`).
    private var pending = 0
    private let state = Mutex<(cancelled: Bool, tasks: [Int: Task<Void, Never>], nextId: Int)>((false, [:], 0))

    fileprivate init() {}

    /// Children not yet handed back by `next()`.
    var isEmpty: Bool { pending == 0 }

    /// Starts `operation` now (cancelled at once when the group already is).
    func addTask(_ operation: @escaping @Sendable () async -> Output) {
        pending += 1
        let mailbox = self.mailbox
        let (id, startCancelled) = state.withLock { s -> (Int, Bool) in s.nextId += 1; return (s.nextId, s.cancelled) }
        let task = Task { [weak self] in
            // Added after cancelAll: cancelled before its first line, not whenever `task.cancel()` below lands.
            if startCancelled { withUnsafeCurrentTask { $0?.cancel() } }
            mailbox.put(await operation())
            self?.state.withLock { _ = $0.tasks.removeValue(forKey: id) }
        }
        let cancelled = state.withLock { s -> Bool in
            if !s.cancelled { s.tasks[id] = task }
            return s.cancelled
        }
        if cancelled { task.cancel() }
    }

    /// The next child to finish, nil when none is pending.
    func next(isolation: isolated (any Actor)? = #isolation) async -> Output? {
        guard pending > 0 else { return nil }
        let value = await mailbox.take(isolation: isolation)
        pending -= 1
        return value
    }

    func cancelAll() {
        let tasks = state.withLock { s -> [Task<Void, Never>] in
            s.cancelled = true
            defer { s.tasks = [:] }
            return Array(s.tasks.values)
        }
        tasks.forEach { $0.cancel() }
    }
}

/// Finished children's results, handed to the one waiting `next()` (or kept until it asks), in completion order.
/// Waiting ignores the caller's cancellation, as a TaskGroup's `next()` does: a cancelled child still finishes and
/// still reports.
private nonisolated final class Mailbox<Output: Sendable>: Sendable {
    private let state = Mutex<(ready: [Output], waiter: CheckedContinuation<Output, Never>?)>(([], nil))

    func put(_ value: Output) {
        let waiter = state.withLock { s -> CheckedContinuation<Output, Never>? in
            if let waiter = s.waiter { s.waiter = nil; return waiter }
            s.ready.append(value)
            return nil
        }
        waiter?.resume(returning: value)
    }

    func take(isolation: isolated (any Actor)? = #isolation) async -> Output {
        await withCheckedContinuation(isolation: isolation) { (waiter: CheckedContinuation<Output, Never>) in
            let value = state.withLock { s -> Output? in
                if !s.ready.isEmpty { return s.ready.removeFirst() }
                s.waiter = waiter
                return nil
            }
            if let value { waiter.resume(returning: value) }
        }
    }
}

/// Runs `body` with a set of child tasks; returns once `body` has and every child it started has finished.
func withChildTasks<Output: Sendable, Result>(of: Output.Type, isolation: isolated (any Actor)? = #isolation,
                                                          _ body: (ChildTasks<Output>) async -> Result) async -> Result {
    let children = ChildTasks<Output>()
    return await withTaskCancellationHandler {
        let result = await body(children)
        while !children.isEmpty { _ = await children.next(isolation: isolation) }
        return result
    } onCancel: {
        children.cancelAll()
    }
}

nonisolated extension Result where Failure == any Error {
    /// `body`'s value or its error. A child that hands back a key with its outcome binds this first and then returns
    /// `(key, outcome)`. Never write `do { return (key, .success(try await …)) } catch { … }`: Swift 6.4 at -O can lose
    /// the key (seen with a passed-in closure and with a struct's method): it reads as garbage, or the whole answer as
    /// nil. Debug builds are fine. Build 569's Artifacts index kept one chat per pass this way and read all 369 again
    /// on every visit; Spawn Tree lost every bot's answer. scripts/check-tuple-try-await.py keeps the shape out.
    static func of(_ body: () async throws -> Success) async -> Self {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
}
