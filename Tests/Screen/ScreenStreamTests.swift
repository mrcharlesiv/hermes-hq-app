// One attach's stream (HermesKit/Screen/ScreenStream.swift) over a fake socket: the pull model, decoding off the main
// thread, the stuck rule with a clock the test moves, how it ends, and how it is closed on purpose.

import CoreGraphics
import Foundation
import Testing
@testable import HermesHQNative

@MainActor
final class StreamProbe {
    var ready: [(Int, Int)] = []
    var frames: [(width: Int, height: Int, serial: Int, requestsSeen: Int)] = []
    var ends: [ScreenStream.End] = []
    var lastImage: CGImage?
}

@MainActor
struct ScreenStreamTests {
    private func make(_ socket: FakeScreenSocket, clock: FakeUptime? = nil, stuckAfter: TimeInterval = 8, pingEvery: Duration = .seconds(20)) -> (ScreenStream, StreamProbe) {
        let probe = StreamProbe()
        let now: @Sendable () -> TimeInterval
        if let clock { now = { clock.now } } else { now = { ProcessInfo.processInfo.systemUptime } }
        let stream = ScreenStream(socket: socket, stuckAfter: stuckAfter, pingEvery: pingEvery, now: now,
                                  onReady: { w, h in probe.ready.append((w, h)) },
                                  onFrame: { image, w, h, serial in
                                      probe.lastImage = image
                                      probe.frames.append((w, h, serial, socket.requests.count))
                                  },
                                  onEnd: { probe.ends.append($0) })
        stream.start()
        return (stream, probe)
    }

    private let fill = RFBBuild.update([RFBBuild.tightFill(0, 0, 64, 48, r: 10, g: 20, b: 30)])

    @Test func handshakeThenOneRequestAtATime() async {
        let socket = FakeScreenSocket()
        let (stream, probe) = make(socket)
        socket.push(RFBBuild.preamble(width: 64, height: 48))
        #expect(await screenWait { socket.requests.count == 1 })
        #expect(probe.ready.count == 1 && probe.ready[0] == (64, 48))
        #expect(socket.sent.map { $0.first } == [82, 1, 1, 0, 2, 3], "version, security, ClientInit, format, encodings, request")
        #expect(socket.requests[0] == RFBMessage.updateRequest(incremental: false, width: 64, height: 48))
        // Nothing more is asked for until a frame has been handed over.
        try? await Task.sleep(for: .milliseconds(150))
        #expect(socket.requests.count == 1)
        for expected in 1...5 {
            socket.push(fill)
            #expect(await screenWait { probe.frames.count == expected && socket.requests.count == expected + 1 })
            #expect(probe.frames[expected - 1].requestsSeen == expected, "the next request goes out only after the frame reached the main actor")
        }
        #expect(socket.requests.last == RFBMessage.updateRequest(incremental: true, width: 64, height: 48))
        #expect(stream.pacing.frames == 5 && stream.pacing.serial == 5 && stream.pacing.mainThreadDecodes == 0)
        #expect(stream.pacing.width == 64 && stream.pacing.height == 48 && stream.pacing.probe == String(repeating: "1e140a", count: 5))
        #expect(stream.pacing.summary.hasPrefix("frames=5 rects=5 size=64x48 mainDecodes=0 p50="))
        #expect(probe.lastImage?.width == 64 && stream.isLive)
        stream.stop(handBack: false)
    }

    @Test func anUpdateSplitOverManyFramesIsOnePictureAndOneRequest() async {
        let socket = FakeScreenSocket()
        let (stream, probe) = make(socket)
        let all = RFBBuild.preamble(width: 64, height: 48) + fill
        for byte in all { socket.push(Data([byte])) }
        #expect(await screenWait { probe.frames.count == 1 && socket.requests.count == 2 })
        #expect(stream.pacing.mainThreadDecodes == 0)
        stream.stop(handBack: false)
    }

    @Test func aResizeAsksForTheWholeNewPicture() async {
        let socket = FakeScreenSocket()
        let (stream, probe) = make(socket)
        socket.push(RFBBuild.preamble(width: 64, height: 48) + fill)
        #expect(await screenWait { socket.requests.count == 2 })
        socket.push(RFBBuild.update([RFBBuild.extendedDesktopSize(96, 60)]))
        #expect(await screenWait { socket.requests.count == 3 })
        #expect(socket.requests[2] == RFBMessage.updateRequest(incremental: false, width: 96, height: 60))
        #expect(probe.frames.last?.width == 96 && probe.frames.last?.height == 60)
        stream.stop(handBack: false)
    }

    @Test func inputGoesOutInOrder() async {
        let socket = FakeScreenSocket()
        let (stream, _) = make(socket)
        socket.push(RFBBuild.preamble(width: 64, height: 48))
        #expect(await screenWait { socket.requests.count == 1 })
        var keys: [Data] = []
        for index in 0..<300 { keys.append(RFBMessage.key(UInt32(0x20 + index % 90), down: index % 2 == 0)) }
        for key in keys { stream.send(key) }
        #expect(await screenWait { socket.inputs.count == 300 })
        #expect(socket.inputs == keys)
        stream.stop(handBack: false)
    }

    // MARK: Stuck (DECISION D12)

    @Test func theStuckRuleCountsSilenceOnlyWhileBytesAreOwed() {
        var rule = ScreenStuckRule(limit: 8, waiting: true, lastByte: 100)
        #expect(!rule.isStuck(now: 107.9) && rule.isStuck(now: 108))
        rule.waiting = false
        #expect(!rule.isStuck(now: 10_000), "silence between updates is a quiet desktop")
        rule.decodingSince = 200
        #expect(!rule.isStuck(now: 207) && rule.isStuck(now: 208.5), "a decode that never returns")
    }

    @Test func noByteForEightSecondsMidUpdateEndsTheStream() async {
        let socket = FakeScreenSocket(), clock = FakeUptime()
        let (held1, probe) = make(socket, clock: clock)
        defer { held1.stop(handBack: false) }
        socket.push(RFBBuild.preamble(width: 64, height: 48) + fill)
        #expect(await screenWait { probe.frames.count == 1 })
        let raw = RFBBuild.update([RFBBuild.raw(0, 0, 64, 48, b: 1, g: 2, r: 3)])
        socket.push(raw.prefix(500))
        try? await Task.sleep(for: .milliseconds(400))
        clock.advance(7.5)
        try? await Task.sleep(for: .milliseconds(600))
        #expect(probe.ends.isEmpty, "7.5 s is not stuck")
        clock.advance(1)
        #expect(await screenWait { probe.ends == [.stuck] })
        #expect(socket.closes == [false], "ended without a close frame: the lease is kept")
    }

    @Test func aSlowLinkThatKeepsDeliveringIsNeverStuck() async {
        let socket = FakeScreenSocket(), clock = FakeUptime()
        let (stream, probe) = make(socket, clock: clock)
        socket.push(RFBBuild.preamble(width: 64, height: 48) + fill)
        #expect(await screenWait { probe.frames.count == 1 })
        let raw = RFBBuild.update([RFBBuild.raw(0, 0, 64, 48, b: 1, g: 2, r: 3)])
        var at = 0
        while at < raw.count {                                  // a minute of 6-second gaps
            socket.push(raw.subdata(in: at..<min(raw.count, at + 1200)))
            at += 1200
            try? await Task.sleep(for: .milliseconds(300))
            clock.advance(6)
            try? await Task.sleep(for: .milliseconds(300))
        }
        #expect(await screenWait { probe.frames.count == 2 })
        #expect(probe.ends.isEmpty)
        // A quiet desktop afterwards (no update owed) is not stuck either.
        clock.advance(600)
        try? await Task.sleep(for: .milliseconds(600))
        #expect(probe.ends.isEmpty)
        stream.stop(handBack: false)
    }

    @Test func aHandshakeThatNeverFinishesIsStuck() async {
        let socket = FakeScreenSocket(), clock = FakeUptime()
        let (held2, probe) = make(socket, clock: clock)
        defer { held2.stop(handBack: false) }
        socket.push(Data("RFB 003.008\n".utf8))
        try? await Task.sleep(for: .milliseconds(300))
        clock.advance(9)
        #expect(await screenWait { probe.ends == [.stuck] })
    }

    // MARK: The first picture (review finding 3)

    @Test func theFirstPictureGetsItsOwnLongerWait() {
        var rule = ScreenStuckRule(limit: 8, firstLimit: 20, waiting: true, lastByte: 100)
        #expect(rule.verdict(now: 108) == .stuck, "a handshake that stalls is stuck at 8 s")
        rule.awaitingFirst = true                                   // ServerInit arrived; no byte of a picture yet
        #expect(rule.verdict(now: 112) == nil && rule.verdict(now: 119.9) == nil)
        #expect(rule.verdict(now: 120) == .noPicture)
        rule.awaitingFirst = false                                  // the first update began, then stalled
        #expect(rule.verdict(now: 108) == .stuck)
    }

    @Test func aPictureThatComesAfterTwelveSecondsIsShown() async {
        let socket = FakeScreenSocket(), clock = FakeUptime()
        let (stream, probe) = make(socket, clock: clock)
        defer { stream.stop(handBack: false) }
        socket.push(RFBBuild.preamble(width: 64, height: 48))
        #expect(await screenWait { probe.ready.count == 1 })
        clock.advance(12)
        try? await Task.sleep(for: .milliseconds(700))
        #expect(probe.ends.isEmpty, "12 s without a first picture is a Mac with nothing to send yet, not a stuck stream")
        #expect(socket.closes.isEmpty)
        socket.push(fill)
        #expect(await screenWait { probe.frames.count == 1 })
        #expect(probe.ends.isEmpty)
    }

    @Test func aPictureThatNeverComesEndsAsNoPicture() async {
        let socket = FakeScreenSocket(), clock = FakeUptime()
        let (stream, probe) = make(socket, clock: clock)
        defer { stream.stop(handBack: false) }
        socket.push(RFBBuild.preamble(width: 64, height: 48))
        #expect(await screenWait { probe.ready.count == 1 })
        clock.advance(19)
        try? await Task.sleep(for: .milliseconds(600))
        #expect(probe.ends.isEmpty)
        clock.advance(2)
        #expect(await screenWait { probe.ends == [.noPicture] })
        #expect(socket.closes == [false], "no close frame: a hold is kept")
    }

    @Test func aFirstPictureThatBeginsAndStallsIsStuckAtEight() async {
        let socket = FakeScreenSocket(), clock = FakeUptime()
        let (stream, probe) = make(socket, clock: clock)
        defer { stream.stop(handBack: false) }
        socket.push(RFBBuild.preamble(width: 64, height: 48))
        #expect(await screenWait { probe.ready.count == 1 })
        socket.push(RFBBuild.update([RFBBuild.raw(0, 0, 64, 48, b: 1, g: 2, r: 3)]).prefix(500))
        try? await Task.sleep(for: .milliseconds(400))
        clock.advance(9)
        #expect(await screenWait { probe.ends == [.stuck] })
    }

    @Test func anUnansweredPingIsADroppedLink() async {
        let socket = FakeScreenSocket()
        socket.answerPings(false)
        let (held3, probe) = make(socket, pingEvery: .milliseconds(300))
        defer { held3.stop(handBack: false) }
        socket.push(RFBBuild.preamble(width: 64, height: 48) + fill)
        #expect(await screenWait { probe.ends == [.stuck] })
        #expect(socket.pings >= 1)
    }

    @Test func pingsAreOnlySentWhileLive() async {
        let socket = FakeScreenSocket()
        let (stream, probe) = make(socket, pingEvery: .milliseconds(200))
        try? await Task.sleep(for: .milliseconds(700))
        #expect(socket.pings == 0, "no picture yet")
        socket.push(RFBBuild.preamble(width: 64, height: 48) + fill)
        #expect(await screenWait { socket.pings >= 2 })
        #expect(probe.ends.isEmpty)
        stream.stop(handBack: false)
    }

    // MARK: Endings

    @Test func theGatewaysCloseCodeIsReported() async {
        for (code, reason) in [(4000, "control-taken"), (4001, nil), (4401, nil), (1003, nil)] as [(Int, String?)] {
            let socket = FakeScreenSocket()
            let (held4, probe) = make(socket)
            defer { held4.stop(handBack: false) }
            socket.push(RFBBuild.preamble(width: 64, height: 48) + fill)
            #expect(await screenWait { probe.frames.count == 1 })
            socket.end(code: code, reason: reason)
            #expect(await screenWait { probe.ends == [.closed(code: code, reason: reason)] }, "\(code)")
        }
        let dropped = FakeScreenSocket()
        let (held5, probe) = make(dropped)
        defer { held5.stop(handBack: false) }
        dropped.end()
        #expect(await screenWait { probe.ends == [.closed(code: nil, reason: nil)] })
    }

    /// Audit 14-14: a send that fails ends the stream at once as a dropped link, not a frozen picture until a ping.
    @Test func aFailedSendEndsTheStream() async {
        let socket = FakeScreenSocket()
        let (stream, probe) = make(socket)
        defer { stream.stop(handBack: false) }
        socket.push(RFBBuild.preamble(width: 64, height: 48))
        #expect(await screenWait { socket.requests.count == 1 })
        socket.failSends()
        socket.push(fill)   // its next request can't go out
        #expect(await screenWait(2) { probe.ends == [.closed(code: nil, reason: nil)] })
    }

    @Test func badDataAndTextFramesEndWithTheirName() async {
        let text = FakeScreenSocket()
        let (held6, first) = make(text)
        defer { held6.stop(handBack: false) }
        text.pushText()
        #expect(await screenWait { first.ends == [.failed("text-frame")] })
        let bad = FakeScreenSocket()
        let (held7, second) = make(bad)
        defer { held7.stop(handBack: false) }
        bad.push(RFBBuild.preamble(width: 64, height: 48) + Data([9, 9, 9]))
        #expect(await screenWait { second.ends == [.failed("unknown-message")] })
        #expect(bad.closes == [false])
        let huge = FakeScreenSocket()
        let (held8, third) = make(huge)
        defer { held8.stop(handBack: false) }
        huge.push(Data("RFB 003.008\n".utf8) + Data([1, 1, 0, 0, 0, 0]) + RFBBuild.serverInit(width: 65535, height: 65535))
        #expect(await screenWait { third.ends == [.failed("bad-size")] })
    }

    @Test func stopHandsBackWithACloseFrameOnlyWhenAsked() async {
        for handBack in [true, false] {
            let socket = FakeScreenSocket()
            let (stream, probe) = make(socket)
            socket.push(RFBBuild.preamble(width: 64, height: 48) + fill)
            #expect(await screenWait { probe.frames.count == 1 })
            let up = RFBMessage.pointer(mask: 0, x: 5, y: 5), release = RFBMessage.key(0xFFE3, down: false)
            stream.stop(handBack: handBack, flush: [up, release])
            #expect(await screenWait { !socket.closes.isEmpty })
            #expect(socket.closes.first == handBack)
            #expect(Array(socket.inputs.suffix(2)) == [up, release], "buttons and keys are released before the socket closes (D14)")
            stream.send(RFBMessage.key(0x61, down: true))
            try? await Task.sleep(for: .milliseconds(400))
            #expect(probe.ends.isEmpty, "a stream ended on purpose reports nothing")
            #expect(socket.inputs.last == release, "nothing is sent after stop")
        }
    }

    @Test func aStreamStoppedAndLetGoAtOnceStillFlushesAndClosesAsAsked() async {
        // What the session does on Close and on a pause: stop, then drop its only reference.
        for handBack in [true, false] {
            let socket = FakeScreenSocket()
            var made: (stream: ScreenStream, probe: StreamProbe)? = make(socket)
            let probe = made?.probe
            socket.push(RFBBuild.preamble(width: 64, height: 48) + fill)
            #expect(await screenWait { probe?.frames.count == 1 })
            let up = RFBMessage.pointer(mask: 0, x: 7, y: 9)
            made?.stream.stop(handBack: handBack, flush: [up])
            made = nil
            #expect(await screenWait { !socket.closes.isEmpty })
            #expect(socket.closes == [handBack], "letting go of a stopped stream must not turn a hand-back into a cut link, or the reverse")
            #expect(socket.inputs.last == up, "the button-up went out before the close")
        }
        // A stream nobody stopped and nobody holds closes without a hand-back.
        let socket = FakeScreenSocket()
        var made: (stream: ScreenStream, probe: StreamProbe)? = make(socket)
        socket.push(RFBBuild.preamble(width: 64, height: 48) + fill)
        #expect(await screenWait { made?.probe.frames.count == 1 })
        made = nil
        #expect(await screenWait { socket.closes == [false] })
    }

    @Test func stopIsBoundedWhenTheLinkCannotSend() async {
        let socket = FakeScreenSocket()
        let (stream, probe) = make(socket)
        socket.push(RFBBuild.preamble(width: 64, height: 48) + fill)
        #expect(await screenWait { probe.frames.count == 1 })
        socket.slowSends(.seconds(5))
        let began = ContinuousClock.now
        stream.stop(handBack: true, flush: [RFBMessage.pointer(mask: 0, x: 1, y: 1)])
        #expect(await screenWait(2) { !socket.closes.isEmpty })
        #expect(ContinuousClock.now - began < .seconds(1), "cut after 250 ms whatever is still queued")
        #expect(socket.closes.first == true)
    }
}
