// One attach's picture stream (docs/spec/3x-screen.md §2.3, §3.2, §5.11): socket → parser → decoders → a finished
// CGImage on the main actor. Everything up to the image runs on the stream's own detached task; the main thread only
// sets a layer's contents. Pull model: the next FramebufferUpdateRequest goes out only after the frame was handed to
// the main actor, so there is never more than one request outstanding and a slow phone gets fewer frames, not a queue.

import CoreGraphics
import Foundation

/// The stuck rule (DECISION D12): the stream is waiting for bytes it was promised (the handshake, or an update that
/// has begun) and none came for `limit`, or one decode has run for `limit`. A slow link that keeps delivering is not
/// stuck, however long the frame takes; silence between updates is normal (nothing on the desktop changed).
///
/// The first picture is its own wait (review finding 3): once the handshake is done the server owes a picture but may
/// not have one yet (the Mac helper writes a frame only when it has captured one: sharing paused from its menu, the
/// display asleep, capture slow to start). That wait gets `firstLimit` (20 s, the same patience as the status), and
/// ends as `.noPicture`, not as a stuck stream. A first picture that has begun and then stalls is stuck at `limit`.
nonisolated struct ScreenStuckRule: Sendable, Equatable {
    enum Verdict: Sendable, Equatable { case stuck, noPicture }

    var limit: TimeInterval = 8
    var firstLimit: TimeInterval = 20
    var waiting = true                      // handshake not finished, first picture owed, or mid-update
    /// The handshake is done and no byte of the first picture has come yet.
    var awaitingFirst = false
    var lastByte: TimeInterval
    var decodingSince: TimeInterval?

    func verdict(now: TimeInterval) -> Verdict? {
        if let decodingSince, now - decodingSince >= limit { return .stuck }
        guard waiting else { return nil }
        if awaitingFirst { return now - lastByte >= max(limit, firstLimit) ? .noPicture : nil }
        return now - lastByte >= limit ? .stuck : nil
    }

    func isStuck(now: TimeInterval) -> Bool { verdict(now: now) != nil }
}

nonisolated struct ScreenPacing: Sendable, Equatable {
    var frames = 0
    var rects = 0
    var mainThreadDecodes = 0
    var p50Ms = 0.0
    var p95Ms = 0.0
    var serial = 0
    var width = 0
    var height = 0
    var probe = ""
    var failedJPEGs = 0

    /// The stage's debug value (UI tests and the stress tester read it).
    var summary: String {
        String(format: "frames=%d rects=%d size=%dx%d mainDecodes=%d p50=%.1f p95=%.1f serial=%d probe=%@",
               frames, rects, width, height, mainThreadDecodes, p50Ms, p95Ms, serial, probe)
    }
}

nonisolated final class ScreenStream: Sendable {
    enum End: Sendable, Equatable {
        /// The socket ended: the gateway's close code and reason when it sent a close frame.
        case closed(code: Int?, reason: String?)
        /// Bad data (the parser's typed error) or a text frame.
        case failed(String)
        /// The stuck rule fired, or a ping went unanswered.
        case stuck
        /// The handshake finished and no picture came for the first-picture limit (the socket itself was fine).
        case noPicture
    }

    private struct Shared: Sendable {
        var rule: ScreenStuckRule
        var pacing = ScreenPacing()
        var samples: [Double] = []
        var ended = false
        var stopped = false
        var live = false
        /// The sender wrote everything queued and closed the socket itself (not the 250 ms cut).
        var senderClosed = false
    }

    private enum Out: Sendable { case data(Data), close(handBack: Bool) }

    private let socket: any ScreenSocketing
    private let shared: Locked<Shared>
    private let outbox: AsyncStream<Out>
    private let post: AsyncStream<Out>.Continuation
    private let tasks = Locked<[Task<Void, Never>]>([])
    private let now: @Sendable () -> TimeInterval
    private let pingEvery: Duration
    private let onReady: @MainActor @Sendable (Int, Int) -> Void
    private let onFrame: @MainActor @Sendable (CGImage, Int, Int, Int) -> Void
    private let onEnd: @MainActor @Sendable (End) -> Void

    /// `onFrame(image, width, height, serial)` runs on the main actor; the next request is sent after it returns.
    /// `onEnd` is called once, and never after `stop`.
    init(socket: any ScreenSocketing, stuckAfter: TimeInterval = 8, firstPictureWait: TimeInterval = 20, pingEvery: Duration = .seconds(20),
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         onReady: @escaping @MainActor @Sendable (Int, Int) -> Void,
         onFrame: @escaping @MainActor @Sendable (CGImage, Int, Int, Int) -> Void,
         onEnd: @escaping @MainActor @Sendable (End) -> Void) {
        self.socket = socket
        self.now = now
        self.pingEvery = pingEvery
        self.onReady = onReady
        self.onFrame = onFrame
        self.onEnd = onEnd
        shared = Locked(Shared(rule: ScreenStuckRule(limit: stuckAfter, firstLimit: firstPictureWait, lastByte: now())))
        (outbox, post) = AsyncStream<Out>.makeStream(bufferingPolicy: .unbounded)
    }

    deinit {
        // After `stop` the close is already arranged (the flush, then the close frame asked for): cutting the socket
        // here would lose a button-up, or turn a hand-back into a dropped link.
        guard !shared.value.stopped else { return }
        post.finish()
        tasks.value.forEach { $0.cancel() }
        socket.close(handBack: false)
    }

    var pacing: ScreenPacing { shared.value.pacing }
    var isLive: Bool { shared.value.live }

    func start() {
        let socket = self.socket, outbox = self.outbox, shared = self.shared
        let sender = Task.detached(priority: .userInitiated) { [weak self] in
            for await item in outbox {
                switch item {
                case .data(let data):
                    do { try await socket.send(data) } catch {
                        // Audit 14-14: a send that fails ends the stream now, as a dropped link (it reconnects), rather
                        // than the picture freezing until the receive loop or the next ping notices.
                        guard !Task.isCancelled else { return }
                        AppLog.note("screen", "send failed")
                        self?.finish(.closed(code: socket.closeCode, reason: socket.closeReason))
                        return
                    }
                case .close(let handBack):
                    socket.close(handBack: handBack)
                    shared.mutate { $0.senderClosed = true }
                    return
                }
            }
        }
        let receiver = Task.detached(priority: .userInitiated) { [weak self] in await ScreenStream.receive({ [weak self] in self }, socket) }
        let watchdog = Task.detached(priority: .utility) { [weak self] in
            var sincePing = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                let state = self.shared.value
                if state.ended || state.stopped { return }
                if let verdict = state.rule.verdict(now: self.now()) {
                    AppLog.note("screen", verdict == .noPicture ? "no first picture" : "stream stuck")
                    self.finish(verdict == .noPicture ? .noPicture : .stuck)
                    return
                }
                if state.live, ContinuousClock.now - sincePing >= self.pingEvery {
                    sincePing = .now
                    if await !self.socket.ping(timeout: .seconds(10)) {
                        let later = self.shared.value
                        if later.ended || later.stopped { return }
                        AppLog.note("screen", "ping unanswered")
                        self.finish(.stuck)
                        return
                    }
                }
            }
        }
        tasks.set([sender, receiver, watchdog])
    }

    /// An input or request message, sent in order after everything queued before it.
    func send(_ data: Data) {
        guard !shared.value.stopped else { return }
        post.yield(.data(data))
    }

    /// Ends the stream on purpose: `flush` (button-up, key-up) goes out first, then the socket closes — with a 1000
    /// close frame when `handBack`, else with none. Bounded: after 250 ms the socket is cut whatever is still queued.
    /// `onEnd` is not called.
    func stop(handBack: Bool, flush: [Data] = []) {
        let first = shared.mutate { state -> Bool in
            if state.stopped { return false }
            state.stopped = true
            return true
        }
        guard first else { return }
        for data in flush { post.yield(.data(data)) }
        post.yield(.close(handBack: handBack))
        let socket = self.socket, tasks = self.tasks, post = self.post
        Task.detached {
            try? await Task.sleep(for: .milliseconds(250))
            socket.close(handBack: handBack)        // a no-op when the sender already closed it
            post.finish()
            tasks.value.forEach { $0.cancel() }
        }
    }

    /// `stop`, then waits (at most `limit`) until the sender has written the flush and closed the socket as asked.
    /// true: the close the caller asked for went out in order. false: the socket was cut by the clock, or the stream
    /// had already been stopped or had ended, so nothing can be said about a hand-back.
    @discardableResult func stopAndWait(handBack: Bool, flush: [Data] = [], limit: Duration = .milliseconds(400)) async -> Bool {
        let before = shared.value
        guard !before.stopped, !before.ended else {
            stop(handBack: handBack, flush: flush)
            return false
        }
        stop(handBack: handBack, flush: flush)
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if shared.value.senderClosed { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return shared.value.senderClosed
    }

    private func finish(_ end: End) {
        let first = shared.mutate { state -> Bool in
            if state.ended || state.stopped { return false }
            state.ended = true
            state.live = false
            return true
        }
        guard first else { return }
        socket.close(handBack: false)
        post.finish()
        let onEnd = self.onEnd
        Task { @MainActor in onEnd(end) }
        tasks.value.forEach { $0.cancel() }
    }

    // MARK: The receive loop (off the main thread)

    /// `owner` is asked for the stream each time something arrives, so a stream nobody holds any more is not kept
    /// alive by its own loop.
    private static func receive(_ owner: @Sendable () -> ScreenStream?, _ socket: any ScreenSocketing) async {
        let parser = RFBParser()
        var serial = 0
        var decodeTime = 0.0
        var handshaken = false
        while !Task.isCancelled {
            let frame: ScreenSocketFrame
            do { frame = try await socket.receive() } catch {
                owner()?.finish(.closed(code: socket.closeCode, reason: socket.closeReason))
                return
            }
            guard let stream = owner(), !Task.isCancelled else { return }
            guard case .binary(let data) = frame else {
                AppLog.note("screen", "text frame")
                stream.finish(.failed("text-frame"))
                return
            }
            let began = stream.now()
            let onMain = pthread_main_np() != 0
            stream.shared.mutate { state in
                state.rule.lastByte = began
                state.rule.decodingSince = began
                if onMain { state.pacing.mainThreadDecodes += 1 }
            }
            let out: RFBParser.Output
            do { out = try parser.feed(data) } catch {
                AppLog.note("screen", "bad data \(error.logName)")
                stream.finish(.failed(error.logName))
                return
            }
            for reply in out.send { stream.post.yield(.data(reply)) }
            let image = out.updates > 0 ? parser.framebuffer?.makeImage() : nil
            let size = (parser.framebuffer?.width ?? 0, parser.framebuffer?.height ?? 0)
            let probe = out.updates > 0 ? parser.framebuffer?.probe() ?? "" : ""
            let ended = stream.now()
            decodeTime += ended - began
            let spent = decodeTime
            let pictured = serial > 0 || out.updates > 0
            if out.ready { handshaken = true }
            let awaitingFirst = handshaken && !pictured && !parser.midUpdate
            stream.shared.mutate { state in
                state.rule.decodingSince = nil
                state.rule.waiting = !pictured || parser.midUpdate
                state.rule.awaitingFirst = awaitingFirst
                state.rule.lastByte = ended
                state.pacing.rects += out.rects
                state.pacing.failedJPEGs = parser.failedJPEGs
                if out.updates > 0 {
                    state.samples.append(spent)
                    if state.samples.count > 120 { state.samples.removeFirst(state.samples.count - 120) }
                    let sorted = state.samples.sorted()
                    state.pacing.p50Ms = sorted[(sorted.count - 1) / 2] * 1000
                    state.pacing.p95Ms = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))] * 1000
                    state.pacing.width = size.0
                    state.pacing.height = size.1
                    state.pacing.probe = probe
                }
            }
            if out.ready {
                AppLog.note("screen", "live \(size.0)x\(size.1)")
                let onReady = stream.onReady
                await MainActor.run { onReady(size.0, size.1) }
            }
            guard out.updates > 0 else { continue }
            decodeTime = 0
            serial += 1
            if let image {
                let onFrame = stream.onFrame, number = serial
                await MainActor.run { onFrame(image, size.0, size.1, number) }
            }
            stream.shared.mutate { state in
                state.pacing.frames += 1
                state.pacing.serial = serial
                state.live = true
            }
            // Only now that the frame is on the main actor: ask for the next one (the whole picture after a resize).
            stream.send(RFBMessage.updateRequest(incremental: !out.resized, width: size.0, height: size.1))
        }
    }
}
