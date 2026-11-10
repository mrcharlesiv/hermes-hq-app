// docs/spec/3x-talk.md §14.1: level maths, end of speech, the barge-in trigger, pre-roll; keep awake; the report.

import Foundation
import Testing
@testable import HermesHQNative

@Suite("Talk VAD")
struct TalkVADTests {
    @Test("Level: silence is 0, a full-scale sine is 1, −32 dBFS is about the speech level")
    func level() {
        #expect(TalkLevel.level([Float](repeating: 0, count: 1024)) == 0)
        let sine = (0..<1600).map { Float(sin(Double($0) * 2 * .pi * 220 / 16_000)) }
        #expect(TalkLevel.level(sine) == 1)
        let quiet = sine.map { $0 * 0.0348 }                // rms ≈ 0.0246 → level ≈ 0.075
        #expect(abs(TalkLevel.level(quiet) - 0.075) < 0.003)
        #expect(TalkLevel.level(rms: .nan) == 0 && TalkLevel.level(rms: -1) == 0)
        let ints: [Int16] = sine.map { Int16($0 * 32767) }
        #expect(ints.withUnsafeBufferPointer { TalkLevel.level(rms: TalkLevel.rms($0)) } == 1)
        #expect(TalkLevel.level([]) == 0)
    }

    @Test("End of speech after 1.25 s of quiet, only once speech was heard")
    func endOfSpeech() {
        var take = TakeEndpoint()
        for _ in 0..<20 { #expect(take.feed(level: 0.3, ms: 50) == nil) }          // 1 s of speech
        for _ in 0..<24 { #expect(take.feed(level: 0.01, ms: 50) == nil) }         // 1.2 s quiet
        #expect(take.feed(level: 0.01, ms: 50) == .endOfSpeech)
        #expect(take.heardSpeech)
        var resumed = TakeEndpoint()
        _ = resumed.feed(level: 0.3, ms: 100)
        for _ in 0..<20 { _ = resumed.feed(level: 0, ms: 50) }
        #expect(resumed.feed(level: 0.2, ms: 50) == nil)                           // speaking again resets the window
        for _ in 0..<24 { #expect(resumed.feed(level: 0, ms: 50) == nil) }
        #expect(resumed.feed(level: 0, ms: 50) == .endOfSpeech)
        var custom = TakeEndpoint(silenceMs: 2000)
        _ = custom.feed(level: 0.3, ms: 100)
        for _ in 0..<39 { #expect(custom.feed(level: 0, ms: 50) == nil) }
        #expect(custom.feed(level: 0, ms: 50) == .endOfSpeech)
    }

    @Test("Idle after 12 s with no speech; the 60 s cap sends what was said")
    func idleAndCap() {
        var idle = TakeEndpoint()
        for _ in 0..<239 { #expect(idle.feed(level: 0.05, ms: 50) == nil) }
        #expect(idle.feed(level: 0.05, ms: 50) == .idle)
        #expect(!idle.heardSpeech)
        var cap = TakeEndpoint()
        for _ in 0..<1199 { #expect(cap.feed(level: 0.4, ms: 50) == nil) }
        #expect(cap.feed(level: 0.4, ms: 50) == .cap)
        var scaled = TakeEndpoint(clock: TalkClock(scale: 20))
        for _ in 0..<11 { #expect(scaled.feed(level: 0, ms: 50) == nil) }
        #expect(scaled.feed(level: 0, ms: 50) == .idle)                            // 600 ms
    }

    /// Feeds `ms` of one level in 20 ms steps; returns the first event and when it came.
    private func run(_ monitor: inout BargeMonitor, from start: Double, ms: Double, level: Double, playing: Bool) -> (BargeMonitor.Event?, Double) {
        var now = start
        while now < start + ms {
            if let event = monitor.feed(level: level, now: now, playing: playing) { return (event, now) }
            now += 20
        }
        return (nil, now)
    }

    @Test("Barge-in: calibration, then 300 ms with 80 % above the trigger")
    func bargeTrigger() {
        var monitor = BargeMonitor()
        #expect(run(&monitor, from: 0, ms: 380, level: 0.5, playing: false).0 == nil)      // still calibrating: never trips
        var quiet = BargeMonitor()
        #expect(run(&quiet, from: 0, ms: 600, level: 0.01, playing: false).0 == nil)
        let (event, at) = run(&quiet, from: 600, ms: 1000, level: 0.3, playing: false)
        #expect(event == .speech)
        #expect(at - 600 >= 240 && at - 600 <= 320)
        #expect(quiet.tripped)
        var blip = BargeMonitor()
        _ = run(&blip, from: 0, ms: 600, level: 0.01, playing: false)
        #expect(run(&blip, from: 600, ms: 120, level: 0.3, playing: false).0 == nil)        // a cough
        #expect(run(&blip, from: 720, ms: 600, level: 0.01, playing: false).0 == nil)
    }

    @Test("While the bot plays: at least 0.14, at most 0.37, and 500 ms of grace")
    func bargeWhilePlaying() {
        var monitor = BargeMonitor()
        _ = run(&monitor, from: 0, ms: 600, level: 0.01, playing: false)
        #expect(monitor.trigger(playing: false) == 0.075)
        #expect(monitor.trigger(playing: true) == 0.14)
        #expect(run(&monitor, from: 600, ms: 480, level: 0.5, playing: true).0 == nil)      // inside the grace
        var loud = BargeMonitor()
        _ = run(&loud, from: 0, ms: 600, level: 0.01, playing: false)
        #expect(run(&loud, from: 600, ms: 2000, level: 0.12, playing: true).0 == nil)       // the bot's own voice, under 0.14
        let (event, at) = run(&loud, from: 2600, ms: 1000, level: 0.2, playing: true)
        #expect(event == .speech && at - 2600 <= 320)
        var noisy = BargeMonitor()
        _ = run(&noisy, from: 0, ms: 600, level: 0.2, playing: false)                       // a loud room: floor 0.2 × 3.5 = 0.7
        #expect(noisy.trigger(playing: false) > 0.69)
        #expect(noisy.trigger(playing: true) == 0.37)                                       // capped while playing
    }

    @Test("The multiplier scales the trigger; an utterance ends on quiet or at 30 s")
    func bargeMultiplierAndUtterance() {
        var sensitive = BargeMonitor(multiplier: 1.5)
        _ = run(&sensitive, from: 0, ms: 600, level: 0.04, playing: false)
        #expect(abs(sensitive.trigger(playing: false) - 0.075) < 1e-9)                      // 0.04 × 1.75 = 0.07 → the floor
        #expect(abs(sensitive.trigger(playing: true) - 0.075) < 1e-9)
        var dull = BargeMonitor(multiplier: 6)
        _ = run(&dull, from: 0, ms: 600, level: 0.02, playing: false)
        #expect(abs(dull.trigger(playing: false) - 0.14) < 1e-9)                            // 0.02 × 7
        #expect(abs(dull.trigger(playing: true) - 0.28) < 1e-9)
        #expect(BargeMonitor(multiplier: 0).playbackMin == 0.14 && BargeMonitor(multiplier: .nan).playbackMin == 0.14)

        var monitor = BargeMonitor(silenceMs: 1250)
        _ = run(&monitor, from: 0, ms: 600, level: 0.01, playing: false)
        #expect(run(&monitor, from: 600, ms: 1000, level: 0.3, playing: false).0 == .speech)
        #expect(run(&monitor, from: 1000, ms: 2000, level: 0.3, playing: false).0 == nil)   // still talking
        let (event, at) = run(&monitor, from: 3000, ms: 3000, level: 0.01, playing: false)
        #expect(event == .utteranceEnded && at - 3000 >= 1250 && at - 3000 <= 1300)
        var endless = BargeMonitor()
        _ = run(&endless, from: 0, ms: 600, level: 0.01, playing: false)
        let tripped = run(&endless, from: 600, ms: 1000, level: 0.3, playing: false).1
        let (cap, when) = run(&endless, from: tripped + 20, ms: 40_000, level: 0.3, playing: false)
        #expect(cap == .utteranceEnded && abs(when - tripped - 30_000) <= 40)
    }

    @Test("Pre-roll keeps the newest second; a WAV is 16 kHz mono 16-bit")
    func preRollAndWave() {
        var roll = PreRoll()
        roll.append([Int16](repeating: 1, count: 10_000))
        roll.append([Int16](repeating: 2, count: 10_000))
        #expect(roll.count == 16_000)
        let frames = roll.take()
        #expect(frames.first == 1 && frames.last == 2 && frames.filter { $0 == 2 }.count == 10_000 && roll.count == 0)
        let wave = TalkWave.file([1, -2, 300])
        #expect(wave.count == 44 + 6)
        #expect(String(decoding: wave.prefix(4), as: UTF8.self) == "RIFF" && String(decoding: wave[8..<16], as: UTF8.self) == "WAVEfmt ")
        #expect(wave[22] == 1 && wave[23] == 0)                                             // mono
        #expect(wave[24] == 0x80 && wave[25] == 0x3E)                                       // 16000
        #expect(wave[34] == 16)
        #expect(wave[44] == 1 && wave[45] == 0 && wave[46] == 0xFE && wave[47] == 0xFF)
    }
}

@MainActor
@Suite("Keep awake", .serialized)
struct KeepAwakeTests {
    private func fresh() -> () -> [Bool] {
        KeepAwake.reset()
        var writes: [Bool] = []
        var value = false
        KeepAwake.apply = { writes.append($0); value = $0 }
        KeepAwake.read = { value }
        return { writes }
    }
    private func restore() {
        KeepAwake.reset()
        KeepAwake.apply = { _ in }
        KeepAwake.read = { false }
    }

    @Test("The idle timer is written only when the number of holds crosses zero")
    func counts() {
        let writes = fresh()
        defer { restore() }
        KeepAwake.hold(.conversation)
        KeepAwake.hold(.memo("a"))
        KeepAwake.hold(.memo("a"))
        KeepAwake.hold(.turn("a"), cap: 600)
        #expect(KeepAwake.count == 3 && writes() == [true])
        KeepAwake.release(.memo("a"))
        KeepAwake.release(.memo("b"))
        #expect(KeepAwake.count == 2 && writes() == [true])
        KeepAwake.release(.conversation)
        KeepAwake.release(.turn("a"))
        #expect(KeepAwake.count == 0 && writes() == [true, false])
        KeepAwake.release(.conversation)
        #expect(writes() == [true, false])
    }

    @Test("Leaving the screen ends capped holds only")
    func leftScreen() {
        let writes = fresh()
        defer { restore() }
        KeepAwake.hold(.turn("a"), cap: 600)
        KeepAwake.hold(.conversation)
        KeepAwake.appLeftScreen()
        #expect(KeepAwake.isHeld(.conversation) && !KeepAwake.isHeld(.turn("a")) && KeepAwake.count == 1)
        KeepAwake.release(.conversation)
        #expect(writes() == [true, false])
    }

    @Test("A cap releases by itself; holding again gives a fresh cap")
    func cap() async throws {
        let writes = fresh()
        defer { restore() }
        KeepAwake.hold(.turn("a"), cap: 0.15)
        try await Task.sleep(for: .milliseconds(80))
        KeepAwake.hold(.turn("a"), cap: 1.5)
        try await Task.sleep(for: .milliseconds(200))
        #expect(KeepAwake.isHeld(.turn("a")))                 // the first cap (150 ms) was replaced
        try await Task.sleep(for: .milliseconds(1800))
        #expect(!KeepAwake.isHeld(.turn("a")) && writes() == [true, false])
    }

    @Test("What was set before the first hold comes back")
    func before() {
        KeepAwake.reset()
        var value = true
        KeepAwake.apply = { value = $0 }
        KeepAwake.read = { value }
        defer { restore() }
        KeepAwake.hold(.dictation)
        KeepAwake.release(.dictation)
        #expect(value == true)
    }
}

@MainActor
@Suite("Voice report", .serialized)
struct VoiceReportTests {
    @Test("The report's exact shape")
    func report() throws {
        let zone = try #require(TimeZone(identifier: "UTC"))
        let now = Date(timeIntervalSince1970: 1_791_688_365)      // 2026-10-11T03:12:45Z
        let text = VoiceReport.text(appName: "Hermes HQ", version: "1.0", build: "251", device: "iPhone17,1", system: "iOS 27.0", now: now,
                                    rows: [.init(name: "Microphone permission", value: "allowed"), .init(name: "Audio session", value: "not active")],
                                    test: "Recorded 94 KB (audio/wav) from “iPhone Microphone”.",
                                    events: [VoiceEvent(at: now.addingTimeInterval(-4), text: "session taken by diagnostics"),
                                             VoiceEvent(at: now.addingTimeInterval(-1), text: "take ended 3000 ms")], zone: zone)
        #expect(text == """
        Hermes HQ voice diagnostics
        Time: 2026-10-11T03:12:45Z
        App: Hermes HQ 1.0 (251) · iPhone17,1 · iOS 27.0
        Microphone permission: allowed
        Audio session: not active
        Test: Recorded 94 KB (audio/wav) from “iPhone Microphone”.
        Recent audio events:
          03:12:41 session taken by diagnostics
          03:12:44 take ended 3000 ms
        """)
        let empty = VoiceReport.text(appName: "HQ Native", version: "1", build: "2", device: "d", system: "s", now: now, rows: [], test: nil, events: [], zone: zone)
        #expect(empty.hasPrefix("HQ Native voice diagnostics\n") && empty.hasSuffix("Recent audio events:\n  None yet."))
        #expect(VoiceReport.line(VoiceEvent(at: now, text: "x"), zone: zone) == "03:12:45  x")
    }

    @Test("Holds, sizes, and nothing private in an event")
    func pieces() {
        #expect(VoiceReport.holds(0) == "no" && VoiceReport.holds(1) == "yes (1 hold)" && VoiceReport.holds(2) == "yes (2 holds)")
        #expect(VoiceReport.size(96_044) == "94 KB" && VoiceReport.size(512) == "512 bytes" && VoiceReport.size(5 * 1024 * 1024) == "5.0 MB")
        #expect(VoiceReport.scrub("lease failed http://127.0.0.1:9900/api/audio/tts-lease now") == "lease failed (address) now")
        #expect(VoiceReport.scrub("token abcdefghijklmnopqrstuvwxyz0123456789ABCD end") == "token (hidden) end")
        #expect(VoiceReport.scrub(String(repeating: "word ", count: 80)).count == 160)
    }

    @Test("Only the last 30 events are kept, newest first")
    func events() {
        VoiceEvents.clear()
        for index in 0..<40 { VoiceEvents.note("event \(index)") }
        #expect(VoiceEvents.all.count == 30 && VoiceEvents.newestFirst.first?.text == "event 39" && VoiceEvents.all.first?.text == "event 10")
        VoiceEvents.clear()
        #expect(VoiceEvents.all.isEmpty)
    }
}
