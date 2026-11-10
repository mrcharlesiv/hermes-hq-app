// First-page reads started before a chat opens (spec 03 §4.1 finger-down warm, §4.4 "taken from the finger-down
// flight", §7.3): a read begun when a finger rests on a bot's row is taken over by the open that follows, instead of
// the open asking again. A flight is usable for 8 s after it started, and once landed for 1 s (later, its rows are in
// the transcript cache, which the chat paints from at once). Memory only; at most 32 flights.

import Foundation

final class HistoryFlights {
    static let shared = HistoryFlights()

    typealias Answer = (HistoryPage, HydratedPage, usedPlugin: Bool)

    struct Key: Hashable {
        var account: String
        var profile: String
        var storedId: String
    }

    private struct Flight {
        var started: ContinuousClock.Instant
        var landed: ContinuousClock.Instant?
        var task: Task<Answer, any Error>
    }

    private var flights: [Key: Flight] = [:]
    static let flightLife: Duration = .seconds(8)
    static let landedLife: Duration = .seconds(1)
    static let limit = 32

    /// The newest-24-rows read an open makes (03 §4.4), keyed for the open to find.
    static func openRead(client: any GatewayClient, storedId: String, profile: String) -> Task<Answer, any Error> {
        let request = HistoryRequest(storedSessionId: storedId, profile: profile.isEmpty ? nil : profile, limit: 24)
        let features = client.latestReady.flatMap { PerformanceFeatures(ready: $0) }
        return Task { try await HistoryAPI.fetchAndFold(client: client, request: request, features: features, cut: true) }
    }

    /// A usable flight for this chat, if one is out (or just landed).
    func take(_ key: Key) -> Task<Answer, any Error>? {
        prune()
        guard let flight = flights[key] else { return nil }
        AppLog.trace("history", "press read for \(AppLog.tag(key.storedId)) taken over by the open (\(flight.landed == nil ? "still out" : "landed"), started \(AppLog.ms(since: flight.started)) ms ago)")
        flights[key] = nil
        return flight.task
    }

    /// Whether a usable flight for this chat exists.
    func has(_ key: Key) -> Bool {
        prune()
        return flights[key] != nil
    }

    /// Starts a flight for this chat (none if one is already out). `landed` runs on the main actor with the answer.
    @discardableResult
    func start(_ key: Key, _ make: () -> Task<Answer, any Error>, landed: @escaping (Answer) -> Void) -> Bool {
        prune()
        guard flights[key] == nil else { return false }
        if flights.count >= Self.limit, let oldest = flights.min(by: { $0.value.started < $1.value.started })?.key {
            flights[oldest] = nil
        }
        let task = make()
        AppLog.trace("history", "press read started for \(AppLog.tag(key.storedId)) (profile \(key.profile))")
        flights[key] = Flight(started: .now, landed: nil, task: task)
        Task { [weak self] in
            let answer: Answer
            do { answer = try await task.value } catch {   // [diagnostics]
                AppLog.swallowed("history", "press read for \(AppLog.tag(key.storedId))", error)
                if self?.flights[key]?.task == task { self?.flights[key] = nil }
                return
            }
            if self?.flights[key]?.task == task { self?.flights[key]?.landed = .now }
            landed(answer)
        }
        return true
    }

    /// Forget everything (account change, background, memory pressure).
    func removeAll() { flights.removeAll() }

    private func prune() {
        let now = ContinuousClock.now
        flights = flights.filter { _, flight in
            if let landed = flight.landed { return now - landed < Self.landedLife }
            return now - flight.started < Self.flightLife
        }
    }
}
