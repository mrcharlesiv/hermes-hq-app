import Foundation

/// One off-screen turn attached to a new socket again (AppModel.reattachUnheardTurns): what `session.activate` said.
/// Each turn asks on its own, so one slow or hung gateway answer no longer holds every later bot's Working….
nonisolated enum UnheardTurns {
    enum Outcome: Sendable, Equatable {
        /// Still running; `movedTo` is the runtime id it runs by now when the gateway re-bound it.
        case running(movedTo: String?)
        /// The gateway no longer runs it (or no longer holds the session): it ended in the gap.
        case ended
        /// No answer (a timeout, the link changed, an error answer): asked again while the link stays up.
        case failed
        /// Nothing asked: a chat hears it again, its turn ended meanwhile, or the attempt was cancelled.
        case skipped
    }

    /// Waits out the connection's replay of `runtime` (a turn end it brings lands first), then, unless `stillUnheard`
    /// says otherwise by then, activates it on this socket.
    static func reattach(_ runtime: String, profile: String, client: any GatewayClient,
                         stillUnheard: @escaping @MainActor @Sendable () -> Bool) async -> Outcome {
        await client.replayDone(session: runtime)
        guard !Task.isCancelled, await stillUnheard() else { return .skipped }
        var params: [String: JSONValue] = ["session_id": .string(runtime), "omit_messages": true]
        if !profile.isEmpty { params["profile"] = .string(profile) }
        do {
            let snapshot = try await client.call("session.activate", .object(params), timeout: .seconds(30))
            guard snapshot["running"]?.bool ?? true else { return .ended }
            let moved = snapshot["session_id"]?.nonEmptyString
            return .running(movedTo: moved == runtime ? nil : moved)
        } catch let error as RPCError where error.code == 4001 || error.code == 4007 {
            return .ended
        } catch is CancellationError {
            return .skipped
        } catch {
            return Task.isCancelled ? .skipped : .failed
        }
    }

    /// Every turn in `unheard` (runtime id → profile) asks at once; one that got no answer asks again `retryDelay` later
    /// while `linkUp` holds (twice at most), instead of waiting for the next `ready`. Each answer goes to `outcome`,
    /// and `roundOver` follows every round, so what a round ended shows before any retry (or a cancel) of the rest.
    @MainActor static func reattachAll(client: any GatewayClient, retryDelay: Duration,
                                       unheard: @escaping @MainActor @Sendable () -> [String: String],
                                       linkUp: () -> Bool, outcome: (String, Outcome) -> Void,
                                       roundOver: () -> Void) async {
        var pending: Set<String>?
        for attempt in 0...2 {
            if attempt > 0 {
                guard pending?.isEmpty == false, linkUp() else { return }
                try? await Task.sleep(for: retryDelay)
                guard !Task.isCancelled, linkUp() else { return }
            }
            guard !Task.isCancelled else { return }
            let work = unheard().filter { pending?.contains($0.key) ?? true }
            pending = []
            // Not `withTaskGroup`: optimized builds abort when a child finishes into a destroyed group (ChildTasks.swift).
            await withChildTasks(of: (String, Outcome).self) { group in
                for (runtime, profile) in work {
                    group.addTask {
                        (runtime, await reattach(runtime, profile: profile, client: client) { unheard()[runtime] != nil })
                    }
                }
                while let (runtime, answer) = await group.next() {
                    guard !Task.isCancelled else { continue }
                    if answer == .failed { pending?.insert(runtime) }
                    outcome(runtime, answer)
                }
            }
            roundOver()
        }
    }
}
