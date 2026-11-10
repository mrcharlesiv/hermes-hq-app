// A history memo's waveform when the shape store has none (spec 1x-voice §6.3): the performance plugin's
// `media/waveform` route when the gateway advertises it, else the file is fetched into the playback cache and its
// peaks are computed off the main thread (W:ios/App/App/HermesVoice.swift:806-837). One computation at a time; a
// bubble that scrolls away cancels its own; a memo whose computation failed is never asked again this launch.

import AVFAudio
import Foundation
import Synchronization

nonisolated enum MemoWaveform {
    struct Failure: Error, CustomStringConvertible { var description: String }

    /// 48 peaks (0…1, normalised to the loudest) and the length. Refuses audio over 660 s. Bounded memory: 4,096
    /// frames per read, whatever the length. Honours cancellation.
    static func compute(_ url: URL) throws -> (peaks: [Double], seconds: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0, format.sampleRate > 0, format.channelCount > 0, format.channelCount <= 8,
              Double(file.length) / format.sampleRate <= 660,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw Failure(description: "Audio is empty or exceeds the memo limit.")
        }
        var peaks = [Double](repeating: 0, count: 48)
        var position: AVAudioFramePosition = 0
        while position < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, file.length - position)))
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { throw Failure(description: "Audio could not be decoded.") }
            for frame in 0..<Int(buffer.frameLength) {
                let bin = min(47, Int((position + Int64(frame)) * 48 / file.length))
                for channel in 0..<Int(format.channelCount) {
                    let sample = Double(abs(channels[channel][frame]))
                    if sample.isFinite { peaks[bin] = max(peaks[bin], sample) }
                }
            }
            position += Int64(buffer.frameLength)
        }
        let maximum = peaks.max() ?? 0
        let normalised = maximum > 0 ? peaks.map { ($0 / maximum * 1000).rounded() / 1000 } : peaks
        return (normalised, Double(file.length) / format.sampleRate)
    }

    /// The plugin's answer, or nil when the route is off or answered "not here" (it then stays off for the account
    /// until the next `replay_epoch`). Accepts only `{"schema":"media.waveform.v1","peaks":[48 in 0…1],"seconds":>0}`.
    static func fromPlugin(path: String, profile: String?, route: String, client: any GatewayClient,
                           epoch: String) async throws -> (peaks: [Double], seconds: Double)? {
        let account = client.account.id
        if WaveformRouteGate.shared.isDisabled(account: account, epoch: epoch) { return nil }
        var query = [URLQueryItem(name: "path", value: path)]
        if let profile, !profile.isEmpty { query.append(URLQueryItem(name: "profile", value: profile)) }
        do {
            let data = try await client.rest("GET", "/api/plugins/\(route)/media/waveform", query: query, body: nil)
            let answer = try JSONValue.parse(data)
            guard answer["schema"]?.string == "media.waveform.v1", let raw = answer["peaks"]?.array, raw.count == 48,
                  let seconds = answer["seconds"]?.double, seconds.isFinite, seconds > 0 else {
                throw Failure(description: "Waveform unavailable")
            }
            let peaks = raw.compactMap(\.double)
            guard peaks.count == 48, peaks.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { throw Failure(description: "Waveform unavailable") }
            return (peaks, seconds)
        } catch let error as HTTPError where error.status == 405 || error.status == 501 || (error.status == 404 && (error.body ?? "").contains("Not Found")) {
            WaveformRouteGate.shared.disable(account: account, epoch: epoch)
            return nil
        }
    }
}

/// Accounts whose waveform route was refused: off until the gateway restarts (a new replay epoch).
nonisolated final class WaveformRouteGate: Sendable {
    static let shared = WaveformRouteGate()
    private let disabled = Mutex<[String: String]>([:])
    func isDisabled(account: String, epoch: String) -> Bool { disabled.withLock { $0[account] == epoch } }
    func disable(account: String, epoch: String) { disabled.withLock { $0[account] = epoch } }
}

/// One waveform computation at a time (W:src/memo-waveform-queue.ts). Requests for one path share a flight; a
/// requester that goes away (its bubble scrolled off) cancels a flight nobody else waits for.
@MainActor final class MemoWaveformQueue {
    static let shared = MemoWaveformQueue()

    typealias Work = @Sendable () async throws -> (peaks: [Double], seconds: Double)

    private struct Entry {
        var task: Task<(peaks: [Double], seconds: Double), any Error>
        var users: Int
    }
    private var pending: [String: Entry] = [:]
    private var tail: Task<Void, Never>?

    /// Loads `path`'s shape with `work`, serialised behind the computation before it. Returns a token to `leave`.
    func load(_ path: String, work: @escaping Work) -> Task<(peaks: [Double], seconds: Double), any Error> {
        if var entry = pending[path] {
            entry.users += 1
            pending[path] = entry
            return entry.task
        }
        let previous = tail
        let task = Task<(peaks: [Double], seconds: Double), any Error> {
            await previous?.value
            try Task.checkCancellation()
            return try await work()
        }
        tail = Task { _ = try? await task.value }
        pending[path] = Entry(task: task, users: 1)
        Task { [weak self] in
            _ = try? await task.value
            self?.finished(path, task)
        }
        return task
    }

    /// The bubble that asked went away: cancel when nobody else waits.
    func leave(_ path: String) {
        guard var entry = pending[path] else { return }
        entry.users -= 1
        if entry.users <= 0 {
            entry.task.cancel()
            pending[path] = nil
        } else {
            pending[path] = entry
        }
    }

    private func finished(_ path: String, _ task: Task<(peaks: [Double], seconds: Double), any Error>) {
        if let entry = pending[path], entry.task == task { pending[path] = nil }
    }
}
