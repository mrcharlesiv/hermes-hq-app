// Dictation's microphone (docs/spec/3x-talk.md §8, DECISION T32): an `AVAudioRecorder` with the memo recorder's proven
// settings (AAC, mono, 24 kHz, metering on), under the `.dictation` audio owner. It needs no voice processing and no
// end-of-speech detection: the person says when they are done. A take at the 600 s limit is about 2.5 MB.

import AVFoundation
import Synchronization
import UIKit

nonisolated enum DictationCaptureError: Error, Equatable {
    /// Microphone access is off for the app.
    case denied
    /// Stopped before it started (the person cancelled, the chat left).
    case cancelled
    /// Could not record; the words are for the person.
    case failed(String)
}

/// What a finished dictation hands over. The file is the caller's to delete.
nonisolated struct DictationTake: Equatable, Sendable {
    var url: URL
    var mime: String
    var seconds: Double
}

/// The four things dictation needs from a microphone.
@MainActor protocol DictationCapturing: AnyObject {
    /// Asks for the microphone when iOS has not asked yet, takes the audio session and records.
    func begin() async throws
    /// Stops. The take, or nil when nothing was recorded.
    func finish() async -> DictationTake?
    /// Stops and throws the audio away.
    func cancel()
    /// 0…1: how loud the microphone hears now (the mapping the memo waveform uses).
    var level: Double { get }
}

@MainActor final class DictationRecorder: DictationCapturing {
    /// AAC, mono, 24 kHz at 48 kbps: the memo recorder's settings (`MemoRecorder.makeRecorder`).
    nonisolated static var settings: [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48000]
    }

    nonisolated static let mime = "audio/x-m4a"

    /// A new file in `Caches/talk` (emptied at every launch).
    nonisolated static func newFile() -> URL {
        TalkCaptureCore.takesFolder.appendingPathComponent("dictation-" + UUID().uuidString.lowercased() + ".m4a")
    }

    private var box: DictationRecorderBox?
    private var file: URL?
    private let meter = DictationMeter()
    private var poll: Timer?
    private var started: CFTimeInterval?
    private var closed = false

    var level: Double { started == nil || closed ? 0 : MemoPolicy.level(power: meter.get()) }

    func begin() async throws {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined:
            guard await AVAudioApplication.requestRecordPermission() else { throw DictationCaptureError.denied }
        case .denied:
            throw DictationCaptureError.denied
        default:
            break
        }
        guard !closed else { throw DictationCaptureError.cancelled }
        let coordinator = AudioSessionCoordinator.shared
        let url = Self.newFile()
        let made: DictationRecorderBox
        var grant: Int?
        do {
            grant = try await coordinator.acquire(.dictation)
            // Cancelled while the session came up: `cancel` released it already, so no recorder may start now.
            guard !closed else { throw DictationCaptureError.cancelled }
            // Made on the audio queue, and only ever touched there.
            made = try await AudioWork.run {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let recorder = try AVAudioRecorder(url: url, settings: DictationRecorder.settings)
                recorder.isMeteringEnabled = true
                guard recorder.record() else { throw DictationCaptureError.failed("The microphone did not start recording.") }
                return DictationRecorderBox(recorder)
            }
        } catch {
            // A failed activation leaves the owner set (no hold to compare): released as it is.
            if let grant { coordinator.releaseAbandoned(.dictation, grant: grant) } else { coordinator.release(.dictation) }
            AudioWork.later { try? FileManager.default.removeItem(at: url) }
            if let known = error as? DictationCaptureError { throw known }
            throw DictationCaptureError.failed("Couldn’t start recording: \(MemoRecorder.startReason(error)).")
        }
        guard !closed else {
            // `cancel` released the session before this recorder started, and starting turned it on again by itself:
            // given back here, after the recorder stops, so other apps' audio resumes.
            Self.discard(made, file: url)
            if let grant { coordinator.releaseAbandoned(.dictation, grant: grant) }
            throw DictationCaptureError.cancelled
        }
        box = made
        file = url
        started = CACurrentMediaTime()
        let meter = meter
        let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { _ in
            AudioWork.later {
                made.value.updateMeters()
                meter.set(made.value.averagePower(forChannel: 0))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    func finish() async -> DictationTake? {
        poll?.invalidate()
        poll = nil
        guard !closed, let box, let file, let started else { return nil }
        closed = true
        self.box = nil
        let seconds = CACurrentMediaTime() - started
        await AudioWork.perform { box.value.stop() }
        AudioSessionCoordinator.shared.release(.dictation)
        return DictationTake(url: file, mime: Self.mime, seconds: seconds)
    }

    func cancel() {
        poll?.invalidate()
        poll = nil
        guard !closed else { return }
        closed = true
        if let box, let file { Self.discard(box, file: file) }
        box = nil
        AudioSessionCoordinator.shared.release(.dictation)
    }

    private nonisolated static func discard(_ box: DictationRecorderBox, file: URL) {
        AudioWork.later {
            box.value.stop()
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// The recorder object, confined to the audio queue by convention (made, driven and stopped only there).
private nonisolated final class DictationRecorderBox: @unchecked Sendable {
    let value: AVAudioRecorder
    init(_ value: AVAudioRecorder) { self.value = value }
}

/// The recorder's latest average power (dBFS), written on the audio queue and read on the main actor.
private nonisolated final class DictationMeter: Sendable {
    private let power = Mutex<Float>(-160)
    func set(_ value: Float) { power.withLock { $0 = value } }
    func get() -> Float { power.withLock { $0 } }
}

#if DEBUG
/// The stand-in microphone for tests and the simulator: it records nothing and, at the end, writes a real AAC file of a
/// quiet tone as long as the take was (so the upload is what a phone would send).
@MainActor final class FixtureDictationRecorder: DictationCapturing {
    static var permission = "granted"
    static var startDelay: TimeInterval = 0.08
    /// The next `begin` fails with these words.
    static var failure: String?
    /// Seconds of audio written per second "recorded" (the stress runs' clock).
    static var scale: Double = 1
    /// Takes ever handed over, and the last one's length (tests and the probe read them).
    private(set) static var finished = 0
    private(set) static var lastSeconds = 0.0

    private var started: CFTimeInterval?
    private var closed = false

    var level: Double {
        guard let started, !closed else { return 0 }
        let t = CACurrentMediaTime() - started
        return 0.35 + 0.4 * abs(sin(t * 4.2)) * (0.6 + 0.4 * abs(sin(t * 1.3)))
    }

    func begin() async throws {
        if let reason = Self.failure {
            Self.failure = nil
            throw DictationCaptureError.failed(reason)
        }
        switch Self.permission {
        case "denied":
            throw DictationCaptureError.denied
        case "undetermined":
            try? await Task.sleep(for: .milliseconds(300))
            Self.permission = "granted"
        default:
            break
        }
        guard !closed else { throw DictationCaptureError.cancelled }
        let coordinator = AudioSessionCoordinator.shared
        coordinator.simulatedOwners.insert(.dictation)
        try? await coordinator.acquire(.dictation)
        try? await Task.sleep(for: .seconds(Self.startDelay))
        guard !closed else {
            coordinator.release(.dictation)
            throw DictationCaptureError.cancelled
        }
        started = CACurrentMediaTime()
    }

    func finish() async -> DictationTake? {
        guard !closed, let started else { return nil }
        closed = true
        let seconds = (CACurrentMediaTime() - started) * Self.scale
        let url = DictationRecorder.newFile()
        let wrote = await AudioWork.perform { Self.writeTone(url, seconds: seconds) }
        AudioSessionCoordinator.shared.release(.dictation)
        guard wrote else { return nil }
        Self.finished += 1
        Self.lastSeconds = seconds
        return DictationTake(url: url, mime: DictationRecorder.mime, seconds: seconds)
    }

    func cancel() {
        guard !closed else { return }
        closed = true
        AudioSessionCoordinator.shared.release(.dictation)
    }

    static func resetForTests() {
        permission = "granted"
        startDelay = 0.08
        failure = nil
        scale = 1
        finished = 0
        lastSeconds = 0
    }

    /// An AAC file with the recorder's own settings, `seconds` long (at least a tenth of a second).
    nonisolated static func writeTone(_ url: URL, seconds: Double) -> Bool {
        let rate = 24000.0
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let file = try? AVAudioFile(forWriting: url, settings: DictationRecorder.settings, commonFormat: .pcmFormatFloat32,
                                          interleaved: false) else { return false }
        let total = max(Int(rate / 10), Int(seconds * rate))
        var written = 0
        while written < total {
            let count = min(Int(rate), total - written)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let samples = buffer.floatChannelData?[0] else { return false }
            buffer.frameLength = AVAudioFrameCount(count)
            for index in 0..<count {
                let t = Double(written + index) / rate
                samples[index] = Float(0.12 * sin(2 * .pi * 220 * t) * (0.6 + 0.4 * sin(2 * .pi * 3 * t)))
            }
            do { try file.write(from: buffer) } catch { return false }
            written += count
        }
        return true
    }
}
#endif
