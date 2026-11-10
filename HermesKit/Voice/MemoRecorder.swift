// The inline recorder (spec 1x-voice §3.3, §3.4): a port of W:ios/App/App/HermesVoice.swift:282-551. One take at a
// time; `begin` resolves only once `record(forDuration:)` returned true, so the screen never shows red before the
// microphone is really recording. A call, Siri, leaving the app or a lost headset ends the take as a draft (a second or
// longer), never a send.
//
// Every AVAudioRecorder call (making it, `record`, metering, `stop`) runs on the audio queue (`AudioWork`), like the
// session's activation: they are blocking calls into the media server and never run on the main thread (A-P1). The
// take's state (token, clock, samples) stays on the main actor; the recorder object is only ever touched on that queue.
//
// DEBUG builds on the simulator can swap the microphone for a fixture (`-HQDebugMemoFixture`, spec §8.3): the
// simulator's microphone is not reliable, so the fixture writes a synthetic 16 kHz mono WAV with a real waveform.

import AVFAudio
import Foundation
import QuartzCore
import Synchronization
import UIKit
import os

/// What `MemoController` drives: the real recorder, or a test stand-in.
@MainActor protocol MemoCapturing: AnyObject {
    var onEvent: ((MemoCaptureEvent) -> Void)? { get set }
    /// Whose memo folder a saved take goes to (`MemoPaths.accountKey`).
    var accountKey: String? { get set }
    var isRecording: Bool { get }
    /// Milliseconds from `begin` to recording (A-P1), once started.
    var startLatencyMs: Double? { get }
    /// Starts recording. Throws `MemoBeginError`.
    func begin() async throws -> (id: String, limit: Double)
    /// Ends the take: `cancel` deletes it (nil), anything else saves it off the main thread.
    func end(id: String, action: MemoEndAction) async throws -> MemoFile?
    /// iOS or the app ended the take (`MemoPolicy.finish` decides).
    func nativeStop(_ reason: MemoStopReason)
}

@MainActor final class MemoRecorder: NSObject, MemoCapturing, AVAudioRecorderDelegate {
    static let shared = MemoRecorder()

    var onEvent: ((MemoCaptureEvent) -> Void)?
    var accountKey: String?
    private(set) var startLatencyMs: Double?

    private(set) var token: String?
    /// Touched only on the audio queue.
    private var recorder: RecorderBox?
    /// Finishes once the recorder's `stop` ran on the audio queue (the file is complete): the save waits for it.
    private var recorderStopped: AsyncStream<Void>?
    /// The latest average power, read on the audio queue at each tick.
    private let meter = Meter()
    private var url: URL?
    private var started: CFTimeInterval?
    private var elapsedAtStop: Double?
    private var limit: Double = 600
    private var ticker: Timer?
    private var samples: [Double] = []
    private var windowMax = 0.0
    private var observers: [NSObjectProtocol] = []
    private var mime = "audio/x-m4a"
    /// [talk] The chat whose memo is recording: the name of its keep-awake hold (docs/spec/3x-talk.md §10.2).
    var keepAwakeScope = ""
    private var keepAwakeHeld: KeepAwake.Owner?
    private static let log = Logger(subsystem: Signposts.subsystem, category: "memo")
    /// A-P1 on a device: "memo start" runs from the touch's `begin` to recording (Instruments › os_signpost).
    nonisolated static let signposts = OSSignposter(subsystem: Signposts.subsystem, category: "memo")
    private var startInterval: OSSignpostIntervalState?

    #if DEBUG && targetEnvironment(simulator)
    /// The simulator's stand-in microphone (`-HQDebugMemoFixture granted|undetermined|denied`).
    struct Fixture {
        var permission: String = "granted"
        var startDelay: Double = 0.08
        var limit: Double?
        var interruptAfter: Double?
        var interruptReason: MemoStopReason = .interrupted
    }
    var fixture: Fixture?
    private var fixtureTimers: [Timer] = []
    #endif

    var isRecording: Bool { token != nil && elapsedAtStop == nil }

    // MARK: Begin

    func begin() async throws -> (id: String, limit: Double) {
        let asked = CACurrentMediaTime()
        guard token == nil else { throw MemoBeginError.busy }
        guard UIApplication.shared.applicationState == .active else { throw MemoBeginError.background }
        switch permission() {
        case .undetermined:
            // The touch that raised the prompt records nothing: the next touch records (C1).
            let granted = await requestPermission()
            throw MemoBeginError.permissionPending(granted: granted)
        case .denied:
            throw MemoBeginError.permissionDenied
        default:
            break
        }
        let seconds = fixtureLimit() ?? MemoPolicy.limitSeconds()
        guard seconds >= MemoPolicy.minimumLimit else { throw MemoBeginError.tooSmall }
        let id = UUID().uuidString
        token = id
        limit = seconds
        samples = []
        windowMax = 0
        elapsedAtStop = nil
        started = nil
        startLatencyMs = nil
        meter.set(-160)
        startInterval = Self.signposts.beginInterval("memo start")

        #if DEBUG && targetEnvironment(simulator)
        if let fixture {
            AudioSessionCoordinator.shared.simulated = true
            try? await AudioSessionCoordinator.shared.acquire(.memoRecording)
            try? await Task.sleep(for: .seconds(fixture.startDelay))
            guard token == id, elapsedAtStop == nil else {
                if token == id { token = nil }
                AudioSessionCoordinator.shared.release(.memoRecording)
                endStartInterval()
                throw MemoBeginError.canceled
            }
            url = FileManager.default.temporaryDirectory.appending(path: id + ".wav")
            mime = "audio/wav"
            didStart(asked: asked)
            return (id, seconds)
        }
        #endif

        let coordinator = AudioSessionCoordinator.shared
        let file = FileManager.default.temporaryDirectory.appending(path: id + ".m4a")
        let box: RecorderBox
        do {
            try await coordinator.acquire(.memoRecording)
            // Speech: AAC mono 24 kHz at 48 kbps (V2). Made on the audio queue, and only ever touched there.
            box = try await AudioWork.run { [self] in try MemoRecorder.makeRecorder(file, delegate: self) }
        } catch {
            if token == id { token = nil }
            coordinator.release(.memoRecording)
            endStartInterval()
            throw MemoBeginError.startFailed(Self.startReason(error))
        }
        mime = "audio/x-m4a"
        if await AudioWork.perform({ box.value.record(forDuration: seconds) }) {
            return try finishStart(box, file: file, id: id, seconds: seconds, asked: asked)
        }
        // A capture that was just released (a call's, another app's) can leave the input busy for a moment: one fresh
        // activation and a second try. The pause suspends; it never blocks the main thread (touches keep flowing).
        coordinator.release(.memoRecording)
        let backgrounded = RetryFlag()
        let watch = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                                           queue: .main) { _ in backgrounded.raised = true }
        try? await Task.sleep(for: .milliseconds(150))
        NotificationCenter.default.removeObserver(watch)
        guard MemoPolicy.mayRetry(sameTake: token == id, stopped: elapsedAtStop != nil,
                                  active: UIApplication.shared.applicationState == .active, backgrounded: backgrounded.raised) else {
            if token == id { token = nil }
            Self.discardRecorder(box, file: file)
            endStartInterval()
            throw MemoBeginError.canceled
        }
        var again = false
        if (try? await coordinator.acquire(.memoRecording)) != nil {
            again = await AudioWork.perform { box.value.prepareToRecord() && box.value.record(forDuration: seconds) }
        }
        guard again else {
            if token == id { token = nil }
            Self.discardRecorder(box, file: file)
            coordinator.release(.memoRecording)
            endStartInterval()
            throw MemoBeginError.startFailed("the microphone did not start recording")
        }
        return try finishStart(box, file: file, id: id, seconds: seconds, asked: asked)
    }

    /// The recorder runs: unless the take was dropped, or the app left the screen, while it started.
    private func finishStart(_ box: RecorderBox, file: URL, id: String, seconds: Double, asked: CFTimeInterval) throws -> (id: String, limit: Double) {
        guard token == id, elapsedAtStop == nil, UIApplication.shared.applicationState == .active else {
            let background = UIApplication.shared.applicationState != .active
            if token == id { token = nil }
            Self.discardRecorder(box, file: file)
            AudioSessionCoordinator.shared.release(.memoRecording)
            endStartInterval()
            throw background ? MemoBeginError.background : MemoBeginError.canceled
        }
        recorder = box
        url = file
        didStart(asked: asked)
        return (id, seconds)
    }

    private nonisolated static func makeRecorder(_ file: URL, delegate: any AVAudioRecorderDelegate & Sendable) throws -> RecorderBox {
        let recorder = try AVAudioRecorder(url: file, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24000,
                                                                 AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48000])
        recorder.delegate = delegate
        recorder.isMeteringEnabled = true
        return RecorderBox(recorder)
    }

    /// Stops a recorder that won't be used and deletes its file (on the audio queue).
    private nonisolated static func discardRecorder(_ box: RecorderBox, file: URL) {
        AudioWork.later {
            box.value.delegate = nil
            box.value.stop()
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func endStartInterval() {
        if let startInterval { Self.signposts.endInterval("memo start", startInterval) }
        startInterval = nil
    }

    private func didStart(asked: CFTimeInterval) {
        startLatencyMs = (CACurrentMediaTime() - asked) * 1000
        endStartInterval()
        // [talk] One reference-counted hold among voice's (it was a direct write of the idle timer).
        let hold = KeepAwake.Owner.memo(keepAwakeScope)
        keepAwakeHeld = hold
        KeepAwake.hold(hold)
        startClock()
        observe()
        Self.log.debug("memo started in \(self.startLatencyMs ?? -1, format: .fixed(precision: 1)) ms")
    }

    // MARK: End

    func end(id: String, action: MemoEndAction) async throws -> MemoFile? {
        guard token == id else { throw Self.saveError("that voice memo already ended") }
        let elapsed = stop()
        guard action != .cancel else {
            discard()
            token = nil
            return nil
        }
        let saving = saveTask(elapsed: elapsed)
        token = nil
        return try await saving.value
    }

    func nativeStop(_ reason: MemoStopReason) {
        guard let id = token, elapsedAtStop == nil else { return }
        let elapsed = stop()
        switch MemoPolicy.finish(reason: reason, elapsed: elapsed) {
        case .await:
            // The length limit: the release rule decides; the take stays open for `end`.
            onEvent?(.stopped(reason: reason, id: id, seconds: elapsed, disposition: .await))
        case .draft:
            let saving = saveTask(elapsed: elapsed)
            token = nil
            Task { @MainActor [weak self] in
                do {
                    let file = try await saving.value
                    self?.onEvent?(.stopped(reason: reason, id: id, seconds: elapsed, disposition: .draft(file)))
                } catch {
                    self?.onEvent?(.stopped(reason: reason, id: id, seconds: elapsed, disposition: .failed(Self.reason(error))))
                }
            }
        case .discard:
            discard()
            token = nil
            onEvent?(.stopped(reason: reason, id: id, seconds: elapsed, disposition: .discard))
        }
    }

    // MARK: Recording

    private func permission() -> AVAudioApplication.recordPermission {
        #if DEBUG && targetEnvironment(simulator)
        if let fixture {
            return fixture.permission == "undetermined" ? .undetermined : fixture.permission == "denied" ? .denied : .granted
        }
        #endif
        return AVAudioApplication.shared.recordPermission
    }

    private func requestPermission() async -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        if fixture != nil {
            try? await Task.sleep(for: .milliseconds(300))
            fixture?.permission = "granted"
            return true
        }
        #endif
        return await AVAudioApplication.requestRecordPermission()
    }

    private func fixtureLimit() -> Double? {
        #if DEBUG && targetEnvironment(simulator)
        return fixture?.limit
        #else
        return nil
        #endif
    }

    private func elapsed() -> Double {
        elapsedAtStop ?? started.map { min(limit, CACurrentMediaTime() - $0) } ?? 0
    }

    /// Levels at 15 Hz, one waveform sample per 100 ms of elapsed time.
    private func startClock() {
        started = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        #if DEBUG && targetEnvironment(simulator)
        if let fixture {
            let id = token
            let limitTimer = Timer(timeInterval: limit, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { if let self, self.token == id { self.nativeStop(.limit) } }
            }
            RunLoop.main.add(limitTimer, forMode: .common)
            fixtureTimers.append(limitTimer)
            if let after = fixture.interruptAfter {
                let reason = fixture.interruptReason
                let interrupt = Timer(timeInterval: after, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { if let self, self.token == id { self.nativeStop(reason) } }
                }
                RunLoop.main.add(interrupt, forMode: .common)
                fixtureTimers.append(interrupt)
            }
        }
        #endif
    }

    private func tick() {
        let seconds = elapsed()
        var level = 0.0
        if let recorder {
            // Metered on the audio queue; this tick shows the reading the last one asked for (66 ms old at most).
            let meter = self.meter
            AudioWork.later {
                recorder.value.updateMeters()
                meter.set(recorder.value.averagePower(forChannel: 0))
            }
            level = MemoPolicy.level(power: meter.get())
        } else {
            // The fixture's voice: a phrase-like rise and fall, so every state has a real waveform.
            level = max(0.04, 0.42 + 0.3 * sin(seconds * 4.1) * sin(seconds * 0.9 + 1) + 0.12 * sin(seconds * 17))
        }
        windowMax = max(windowMax, level)
        while samples.count < min(6000, Int(seconds * 10)) {
            samples.append(windowMax)
            windowMax = 0
        }
        onEvent?(.level((level * 1000).rounded() / 1000, seconds: MemoPolicy.twoDecimals(seconds)))
    }

    /// Stops recording (idempotent) and returns the take's length.
    @discardableResult
    private func stop() -> Double {
        if let done = elapsedAtStop { return done }
        let seconds = elapsed()
        elapsedAtStop = seconds
        if let recorder {
            self.recorder = nil
            // The recorder finishes its file on the audio queue; the session's release is queued right behind it.
            let (stopped, done) = AsyncStream<Void>.makeStream()
            AudioWork.later {
                recorder.value.delegate = nil
                recorder.value.stop()
                done.finish()
            }
            recorderStopped = stopped
        }
        teardown()
        AudioSessionCoordinator.shared.release(.memoRecording)
        if let hold = keepAwakeHeld { KeepAwake.release(hold) }   // [talk]
        keepAwakeHeld = nil
        return seconds
    }

    private func teardown() {
        ticker?.invalidate()
        ticker = nil
        #if DEBUG && targetEnvironment(simulator)
        fixtureTimers.forEach { $0.invalidate() }
        fixtureTimers = []
        #endif
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    /// Saves the take off the main thread into memos/<account>/<uuid>/voice-memo.<ext>. The temporary recording is
    /// deleted only once it is saved.
    private func saveTask(elapsed: Double) -> Task<MemoFile, any Error> {
        let source = url
        url = nil
        let stopped = recorderStopped
        recorderStopped = nil
        let peaks = MemoPolicy.peaks(samples)
        let key = accountKey ?? "local"
        let mime = self.mime
        #if DEBUG && targetEnvironment(simulator)
        let fixtureWave: Data? = fixture != nil ? Self.fixtureWave(seconds: elapsed, levels: samples) : nil
        #else
        let fixtureWave: Data? = nil
        #endif
        return Task.detached(priority: .userInitiated) {
            // The recorder's file is complete once its stop ran on the audio queue.
            if let stopped { for await _ in stopped {} }
            let target = MemoPaths.newRecording(key, ext: mime == "audio/wav" ? "wav" : "m4a")
            MemoPaths.ensure(target.deletingLastPathComponent())
            if let fixtureWave {
                try fixtureWave.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                if let source { try? FileManager.default.removeItem(at: source) }
            } else {
                guard let source else { throw MemoRecorder.saveError("the recording is empty") }
                let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size > 0 else { throw MemoRecorder.saveError("the recording is empty") }
                try FileManager.default.moveItem(at: source, to: target)
                try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                       ofItemAtPath: target.path)
            }
            return MemoFile(path: target.path, seconds: MemoPolicy.twoDecimals(elapsed), peaks: peaks, mime: mime)
        }
    }

    nonisolated static func saveError(_ reason: String) -> NSError {
        NSError(domain: "HQMemo", code: 3, userInfo: [NSLocalizedDescriptionKey: reason])
    }

    /// Why a take couldn't be saved, in words; "" when there are none (the card then says it couldn't be saved on this
    /// phone). A bare code ("iOS error 2003334207") goes to the log, never the card.
    nonisolated static func reason(_ error: any Error) -> String {
        let failure = error as NSError
        if failure.domain == "HQMemo" { return failure.localizedDescription }
        AppLog.note("talk", "memo save failed: \(failure.domain) \(failure.code)")
        return ""
    }

    /// Why the microphone didn't start (a memo or a dictation), in words. The audio session's codes mean something: the
    /// card said "iOS error 561017449" when a call held the microphone. The code itself goes to the log.
    nonisolated static func startReason(_ error: any Error) -> String {
        let failure = error as NSError
        if failure.domain == "HQMemo" { return failure.localizedDescription }
        AppLog.note("talk", "microphone didn't start: \(failure.domain) \(failure.code)")
        return microphoneWords(code: failure.code)
    }

    nonisolated static func microphoneWords(code: Int) -> String {
        switch code {
        // '!pri' (insufficient priority), '!int' (can't interrupt others), '!rec' (can't start recording): a call, Siri
        // or another app holds the microphone.
        case 561_017_449, 560_557_684, 561_145_187: "a call or another app is using the microphone"
        default: "the microphone didn’t start"
        }
    }

    /// Deletes the take's file, on the audio queue behind the recorder's stop (it may still be finishing the file).
    private func discard() {
        recorderStopped = nil
        if let url { AudioWork.later { try? FileManager.default.removeItem(at: url) } }
        url = nil
    }

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            MainActor.assumeIsolated { if began { self?.nativeStop(.interrupted) } }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let lost = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            MainActor.assumeIsolated { if lost { self?.nativeStop(.routeLost) } }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                AudioSessionCoordinator.shared.reset()
                self?.nativeStop(.reset)
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.nativeStop(.background) }
        })
    }

    // AVFoundation calls these on its own thread: every piece of the memo's state lives on the main thread.
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let box = UncheckedRecorder(recorder)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard box.value === MemoRecorder.shared.recorder?.value else { return }
                MemoRecorder.shared.nativeStop(flag ? .limit : .error)
            }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        let box = UncheckedRecorder(recorder)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard box.value === MemoRecorder.shared.recorder?.value else { return }
                MemoRecorder.shared.nativeStop(.error)
            }
        }
    }

    // MARK: Fixture

    /// A 16 kHz mono WAV whose loudness follows the take's levels: it plays, has a length and a waveform
    /// (W:ios/App/App/HermesVoice.swift:553-572).
    nonisolated static func fixtureWave(seconds: Double, levels: [Double]) -> Data {
        let rate = 16000, count = max(1, Int(seconds * Double(rate)))
        var pcm = Data(capacity: count * 2)
        for index in 0..<count {
            let t = Double(index) / Double(rate)
            let level = levels.isEmpty ? 0.3 : levels[min(levels.count - 1, Int(t * 10))]
            let value = Int16(max(-32767, min(32767, level * 9000 * sin(2 * .pi * 220 * t) * (0.6 + 0.4 * sin(2 * .pi * 3 * t)))))
            withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var header = Data()
        func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { header.append(contentsOf: $0) } }
        func u16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { header.append(contentsOf: $0) } }
        header.append(contentsOf: Array("RIFF".utf8)); u32(36 + pcm.count); header.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        header.append(contentsOf: Array("data".utf8)); u32(pcm.count)
        return header + pcm
    }
}

/// Set on the main queue by a notification during the busy-input pause.
private nonisolated final class RetryFlag: @unchecked Sendable { var raised = false }

/// The recorder object, confined to the audio queue by convention (made, driven and stopped only there).
private nonisolated final class RecorderBox: @unchecked Sendable {
    let value: AVAudioRecorder
    init(_ value: AVAudioRecorder) { self.value = value }
}

/// The recorder's latest average power (dBFS), written on the audio queue and read on the main actor.
private nonisolated final class Meter: Sendable {
    private let power = Mutex<Float>(-160)
    func set(_ value: Float) { power.withLock { $0 = value } }
    func get() -> Float { power.withLock { $0 } }
}

private nonisolated struct UncheckedRecorder: @unchecked Sendable {
    let value: AVAudioRecorder
    init(_ value: AVAudioRecorder) { self.value = value }
}
