// [offline] When a failed read is asked again (docs/spec/3x-offline.md §6.2), a port of the web app's
// `src/query-retry.ts`. A read that ran out its time, or one the gateway can't be reached for (the outage gate's fast
// failure, a 502/503 from its proxy), is not asked again: the page shows its error at once and its own Try Again asks.
// Any other failure gets one quick retry (1 s), which covers a dropped connection or a write landing at the same
// moment.

import Foundation

nonisolated enum QueryRetry {
    static let delay: Duration = .seconds(1)
    private static let neverCodes: Set<String> = ["timeout", "unreachable", "unavailable", "tailscale-off", "network", "paused"]
    private static let timeoutMessage = try! NSRegularExpression(pattern: #"^request timed out after \d+s\b"#)

    /// A read that ran out its time (URLError timeout, or a gateway RPC's own deadline).
    static func timedOut(_ error: any Error) -> Bool {
        if let rpc = error as? RPCError {
            if rpc.isTimeout { return true }
            let text = rpc.message
            return timeoutMessage.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        if let failure = error as? GatewayFailure { return failure.code == "timeout" }
        if let url = error as? URLError { return url.code == .timedOut }
        return false
    }

    /// The gateway can't be reached at all (the outage gate, a down answer from its proxy, no socket).
    /// **DECISION** (spec §6.2): "not connected" and "connection lost" count as unreachable: a retry one second later
    /// cannot do better than the reconnect's own re-read.
    static func unreachable(_ error: any Error) -> Bool {
        if let rpc = error as? RPCError { return rpc.isNotConnected || rpc.isConnectionLost }
        if let failure = error as? GatewayFailure { return failure.isHeld || neverCodes.contains(failure.code) }
        if error is RetryLater { return false }
        if let http = error as? HTTPError { return OutageGate.downStatuses.contains(http.status) }
        if error is URLError { return neverCodes.contains(GatewayFailure.from(error).code) }
        return false
    }

    static func cancelled(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// Never after a timeout, a cancel, or while the gateway is unreachable; else once.
    static func shouldRetry(failureCount: Int, error: any Error) -> Bool {
        if timedOut(error) || unreachable(error) || cancelled(error) { return false }
        return failureCount < 1
    }

    /// Runs `work`; on a retryable failure waits `delay` and runs it once more.
    @MainActor static func read<T>(delay: Duration = QueryRetry.delay, _ work: @MainActor () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch {
            guard shouldRetry(failureCount: 0, error: error) else {
                let reason = timedOut(error) ? "timed out" : unreachable(error) ? "gateway unreachable" : cancelled(error) ? "cancelled" : "?"
                AppLog.trace("net", "query retry: giving up (\(reason))")
                throw error
            }
            AppLog.trace("net", "query retry: retrying once after \(GatewayFailure.from(error).code)")
            try await Task.sleep(for: delay)
            return try await work()
        }
    }
}
