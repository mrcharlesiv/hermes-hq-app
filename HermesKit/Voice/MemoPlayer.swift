// One memo plays at a time, app-wide (spec 1x-voice §6.4, V3/V4): `AVAudioPlayer` on a local file (a gateway memo is
// downloaded whole first; no private API), rate 1×/1.5×/2× remembered app-wide (D3). The audio session is taken on
// Play and given back on pause, end, interruption, unplugged headphones, the screen leaving and the app leaving the
// screen, so other apps' audio resumes. No background playback (V14).

import AVFAudio
import Foundation
import Synchronization
import UIKit

/// Memo files that couldn't be fetched or played this launch ("Couldn’t load audio · Retry"); the row builder reads it
/// on any thread.
nonisolated enum MemoLoadFailures {
    private static let paths = Mutex<Set<String>>([])
    static func contains(_ path: String) -> Bool { paths.withLock { $0.contains(path) } }
    @discardableResult static func insert(_ path: String) -> Bool { paths.withLock { $0.insert(path).inserted } }
    @discardableResult static func remove(_ path: String) -> Bool { paths.withLock { $0.remove(path) != nil } }
}

@MainActor final class MemoPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = MemoPlayer()
    /// Posted when the playing memo, its state or the speed changed (userInfo `path` when one memo is concerned).
    static let didChange = Notification.Name("hq.memo.player.changed")
    static let pathKey = "path"
    static let speedKey = "hq.voice.memoSpeed"
    static let speeds: [Double] = [1, 1.5, 2]

    enum State: Equatable { case idle, loading, playing, paused }

    /// The memo the player holds (its message path: gateway or local).
    private(set) var path: String?
    private(set) var state: State = .idle
    private(set) var duration: Double = 0
    private var player: AVAudioPlayer?
    private var pausedAt: Double = 0
    private var loadTask: Task<Void, Never>?
    /// Bumped by every start and teardown: a session activation that lands late plays only for the start that asked.
    private var startGeneration = 0
    /// Memos that couldn't load this launch ("Couldn’t load audio · Retry").
    private(set) var failed = Set<String>()
    private var observing = false

    var speed: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: Self.speedKey)
            return Self.speeds.contains(stored) ? stored : 1
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.speedKey)
            player?.rate = Float(newValue)
            post(path)
        }
    }

    /// 1 → 1.5 → 2 → 1, saved at once (memo-player.ts:8-22).
    func cycleSpeed() {
        let index = Self.speeds.firstIndex(of: speed) ?? 0
        speed = Self.speeds[(index + 1) % Self.speeds.count]
    }

    func isCurrent(_ path: String) -> Bool { self.path == path }

    /// Seconds played of `path` (0 when it isn't the one held).
    func currentTime(_ path: String) -> Double {
        guard self.path == path else { return 0 }
        return player?.currentTime ?? pausedAt
    }

    func state(of path: String) -> State { self.path == path ? state : .idle }

    // MARK: Play / pause

    /// Play `path`, from `fraction` of it when given. `resolve` finds (or downloads) its local file.
    func play(_ path: String, from fraction: Double? = nil, resolve: @escaping @MainActor () async throws -> URL) {
        installObservers()
        if self.path == path, let player {
            if let fraction { player.currentTime = max(0, min(1, fraction)) * player.duration }
            start(player)
            return
        }
        // Starting a memo pauses the one playing (memo-player.ts:24-26).
        teardown(release: true)
        self.path = path
        failed.remove(path)
        state = .loading
        post(path)
        loadTask = Task { [weak self] in
            do {
                let url = try await resolve()
                guard let self, self.path == path, !Task.isCancelled else { return }
                let generation = self.startGeneration
                // [perf] Opening the file and priming its audio queue are media-server calls (A-P1): off the main thread.
                // play() stays on main in start(), so a pause() can never be overtaken by a queued play().
                let boxed = try await AudioWork.run {
                    let player = try AVAudioPlayer(contentsOf: url)
                    player.enableRate = true
                    _ = player.prepareToPlay()
                    return UncheckedPlayer(player)
                }
                // A stop, or another memo, while it was built: the player was never started, so it is just dropped.
                guard self.path == path, self.startGeneration == generation, !Task.isCancelled else { return }
                let player = boxed.value
                player.delegate = self
                // [talk] Silent in a DEBUG build on the Simulator unless asked (`-HQDebugTalkSpeaker audible`).
                if EngineSpeechOutput.silent.withLock({ $0 }) { player.volume = 0 }
                self.player = player
                self.duration = player.duration
                if let fraction { player.currentTime = max(0, min(1, fraction)) * player.duration }
                self.start(player)
            } catch {
                guard let self, self.path == path, !(error is CancellationError) else { return }
                self.failed.insert(path)
                MemoLoadFailures.insert(path)
                self.teardown(release: true)
                self.path = nil
                self.post(path)
            }
        }
    }

    /// Shows Pause at once; the sound starts once the session is active (activated off the main thread). A session
    /// that can't be had (a call, another app holding it) or a player that won't play is a load failure: the bubble
    /// says "Couldn’t load audio · Retry" instead of a Pause with no sound.
    private func start(_ player: AVAudioPlayer) {
        startGeneration += 1
        let generation = startGeneration
        AudioSessionCoordinator.shared.onPlaybackPreempted = { [weak self] in self?.pause() }
        state = .playing
        post(path)
        Task { [weak self] in
            var ready = true
            do { try await AudioSessionCoordinator.shared.acquire(.memoPlayback) } catch { ready = false }
            guard let self, self.startGeneration == generation, self.state == .playing, self.player === player else { return }
            player.rate = Float(self.speed)
            if !ready || !player.play() { self.startFailed() }
        }
    }

    private func startFailed() {
        guard let path else { return }
        failed.insert(path)
        MemoLoadFailures.insert(path)
        teardown(release: true)
        self.path = nil
        post(path)
    }

    func pause() {
        guard let player, state == .playing else {
            if state == .loading { stop() }
            return
        }
        player.pause()
        pausedAt = player.currentTime
        state = .paused
        AudioSessionCoordinator.shared.release(.memoPlayback)
        post(path)
    }

    func toggle(_ path: String, resolve: @escaping @MainActor () async throws -> URL) {
        if self.path == path && state == .playing { pause() } else { play(path, resolve: resolve) }
    }

    /// Moves `path` to `fraction` (scrubbing). A memo not loaded yet loads and starts there (Telegram's bubbles scrub at
    /// any time; the web only seeks a loaded memo).
    func seek(_ path: String, to fraction: Double, resolve: @escaping @MainActor () async throws -> URL) {
        if self.path == path, let player {
            player.currentTime = max(0, min(1, fraction)) * player.duration
            pausedAt = player.currentTime
            post(path)
            return
        }
        play(path, from: fraction, resolve: resolve)
    }

    /// Stops and lets go (the chat screen left, recording starts, sign-out).
    func stop() {
        let old = path
        teardown(release: true)
        path = nil
        if let old { post(old) }
    }

    func forgetFailure(_ path: String) {
        failed.remove(path)
        if MemoLoadFailures.remove(path) { post(path) }
    }

    /// The memo's file couldn't be fetched (a 404 while its waveform loaded): the bubble says so, with Retry.
    func markFailed(_ path: String) {
        MemoLoadFailures.insert(path)
        guard failed.insert(path).inserted else { return }
        post(path)
    }

    private func teardown(release: Bool) {
        startGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        pausedAt = 0
        duration = 0
        state = .idle
        if release { AudioSessionCoordinator.shared.release(.memoPlayback) }
    }

    // MARK: Ended

    // Only the player that is playing now may end or fail the memo: a callback already queued for memo A must not reset
    // memo B, started in the same instant.
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let box = UncheckedPlayer(player)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard box.value === MemoPlayer.shared.player else { return }
                MemoPlayer.shared.ended()
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let box = UncheckedPlayer(player)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let shared = MemoPlayer.shared
                guard box.value === shared.player else { return }
                shared.startFailed()
            }
        }
    }

    /// Back to the start, not playing, no progress (memo-player.ts:148); the session goes back.
    private func ended() {
        guard state == .playing else { return }
        player?.currentTime = 0
        pausedAt = 0
        state = .paused
        AudioSessionCoordinator.shared.release(.memoPlayback)
        post(path)
    }

    // MARK: System events

    private func installObservers() {
        guard !observing else { return }
        observing = true
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            // Pause on .began; never auto-resume on .ended.
            MainActor.assumeIsolated { if began { MemoPlayer.shared.pause() } }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            let lost = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            // Headphones out: pause, per Apple's guidance.
            MainActor.assumeIsolated { if lost { MemoPlayer.shared.pause() } }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                AudioSessionCoordinator.shared.reset()
                MemoPlayer.shared.stop()
            }
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MemoPlayer.shared.pause() }
        }
    }

    private func post(_ path: String?) {
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: path.map { [Self.pathKey: $0] })
    }
}

private nonisolated struct UncheckedPlayer: @unchecked Sendable {
    let value: AVAudioPlayer
    init(_ value: AVAudioPlayer) { self.value = value }
}
