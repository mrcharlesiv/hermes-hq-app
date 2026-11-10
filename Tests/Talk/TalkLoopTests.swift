// docs/spec/3x-talk.md §4.2 and §14.1: the conversation loop as a table of input sequences against effects.

import Foundation
import Testing
@testable import HermesHQNative

/// Drives the reducer with a clock the test owns.
struct LoopHarness {
    var state: TalkLoopState
    var now: TimeInterval = 1000
    var log: [TalkLoopEffect] = []
    let file = URL(fileURLWithPath: "/tmp/take.wav")
    let other = URL(fileURLWithPath: "/tmp/barge.wav")

    init(speaks: Bool = true, config: TalkConfig = TalkConfig(), clock: TalkClock = TalkClock()) {
        state = TalkLoopState(now: 1000, speaksReplies: speaks, config: config, clock: clock)
    }

    @discardableResult
    mutating func send(_ input: TalkLoopInput, after seconds: TimeInterval = 0) -> [TalkLoopEffect] {
        now += seconds
        let effects = TalkLoop.reduce(&state, input, now: now)
        log += effects
        return effects
    }

    /// Start, microphone ready: listening with a take open.
    mutating func listening() {
        send(.start)
        send(.micReady)
    }

    /// A take with speech, transcribed to `text`: the prompt is out and the turn runs.
    @discardableResult
    mutating func say(_ text: String) -> [TalkLoopEffect] {
        send(.takeEnded(file: file, heardSpeech: true, meterFailed: false, ms: 2000))
        let effects = send(.transcript(text))
        send(.turnRunning(true))
        return effects
    }

    func reply(_ text: String, pending: Bool, id: String = "m1") -> TalkLoopInput {
        .reply(SpokenReply(messageId: id, text: text, pending: pending))
    }

    var ends: [TalkEnd] { log.compactMap { if case .ended(let end) = $0 { end } else { nil } } }
    func count(_ effect: TalkLoopEffect) -> Int { log.filter { $0 == effect }.count }
}

@Suite("Talk loop")
struct TalkLoopTests {
    @Test("Rule 1: Starting… until the microphone is ready, then a take")
    func start() {
        var loop = LoopHarness()
        #expect(loop.send(.start).isEmpty)
        #expect(loop.state.view(name: "Ivy").phase == .starting)
        #expect(loop.send(.micReady) == [.beginTake])
        #expect(loop.state.status == .listening && loop.state.view(name: "Ivy").title == "Listening")
        #expect(loop.send(.micReady).isEmpty)
        var failed = LoopHarness()
        failed.send(.start)
        #expect(failed.send(.micFailed(title: "Microphone failed", message: "Could not start microphone recording.", detail: "-50"))
                == [.ended(.stopped(title: "Microphone failed", message: "Could not start microphone recording.", detail: "-50"))])
        #expect(failed.send(.micReady).isEmpty)
    }

    @Test("Rule 2: a take with no speech starts again; two short meter failures stop")
    func listeningRule() {
        var loop = LoopHarness()
        loop.listening()
        #expect(loop.send(.takeEnded(file: loop.file, heardSpeech: false, meterFailed: false, ms: 12_000)) == [.discard(file: loop.file), .beginTake])
        #expect(loop.state.status == .listening)
        #expect(loop.send(.takeEnded(file: loop.file, heardSpeech: false, meterFailed: true, ms: 300)) == [.discard(file: loop.file), .beginTake])
        // A good take in between forgives the first failure.
        loop.send(.takeEnded(file: loop.file, heardSpeech: true, meterFailed: false, ms: 900))
        loop.send(.transcript(""))
        #expect(loop.send(.takeEnded(file: loop.file, heardSpeech: false, meterFailed: true, ms: 300)) == [.discard(file: loop.file), .beginTake])
        let effects = loop.send(.takeEnded(file: loop.file, heardSpeech: false, meterFailed: true, ms: 300))
        #expect(effects == [.discard(file: loop.file),
                            .ended(.stopped(title: "", message: "The microphone isn’t giving a level, so Hermes HQ can’t tell when you stop talking.", detail: nil))])
        // A long take whose meter failed is still sent.
        var long = LoopHarness()
        long.listening()
        #expect(long.send(.takeEnded(file: long.file, heardSpeech: true, meterFailed: true, ms: 5000)) == [.transcribe(file: long.file)])
    }

    @Test("Rule 3: words are sent; nothing heard listens again; a stop phrase ends")
    func transcribing() {
        var loop = LoopHarness()
        loop.listening()
        #expect(loop.send(.takeEnded(file: loop.file, heardSpeech: true, meterFailed: false, ms: 2000)) == [.transcribe(file: loop.file)])
        #expect(loop.state.status == .transcribing)
        #expect(loop.send(.transcript("  what's on my calendar \n")) == [.submit(text: "what's on my calendar", interrupted: false), .armBarge])
        #expect(loop.state.status == .thinking && loop.state.view(name: "Ivy").centerLabel == "Stop")

        var empty = LoopHarness()
        empty.listening()
        empty.send(.takeEnded(file: empty.file, heardSpeech: true, meterFailed: false, ms: 2000))
        #expect(empty.send(.transcript("   ")) == [.beginTake])
        #expect(empty.state.status == .listening)

        var stop = LoopHarness()
        stop.listening()
        stop.send(.takeEnded(file: stop.file, heardSpeech: true, meterFailed: false, ms: 900))
        #expect(stop.send(.transcript("Hey Hermes, stop.")) == [.ended(.said)])
        #expect(stop.count(.submit(text: "Hey Hermes, stop.", interrupted: false)) == 0)

        var sent = LoopHarness()
        sent.listening()
        sent.send(.takeEnded(file: sent.file, heardSpeech: true, meterFailed: false, ms: 900))
        #expect(sent.send(.transcript("stop the deploy")).first == .submit(text: "stop the deploy", interrupted: false))

        var off = LoopHarness(config: TalkConfig(config: .object(["voice": .object(["stop_phrases": .array([])])])))
        off.listening()
        off.send(.takeEnded(file: off.file, heardSpeech: true, meterFailed: false, ms: 900))
        #expect(off.send(.transcript("stop")).first == .submit(text: "stop", interrupted: false))
    }

    @Test("T15: one failed transcription shows the reason and listens; the third in a row stops")
    func transcribeFailures() {
        var loop = LoopHarness()
        loop.listening()
        for round in 1...2 {
            loop.send(.takeEnded(file: loop.file, heardSpeech: true, meterFailed: false, ms: 2000))
            #expect(loop.send(.transcribeFailed(reason: "No speech provider", detail: "400")) == [.haptic(.error), .beginTake], "round \(round)")
            #expect(loop.state.status == .listening && loop.state.problem == "Voice Transcription Failed. No speech provider")
        }
        loop.send(.takeEnded(file: loop.file, heardSpeech: true, meterFailed: false, ms: 2000))
        #expect(loop.state.problem == nil)                                    // cleared by the next state
        #expect(loop.send(.transcribeFailed(reason: "No speech provider", detail: "400"))
                == [.ended(.stopped(title: "Voice Transcription Failed", message: "No speech provider", detail: "400"))])

        var recovers = LoopHarness()
        recovers.listening()
        for _ in 1...2 {
            recovers.send(.takeEnded(file: recovers.file, heardSpeech: true, meterFailed: false, ms: 2000))
            recovers.send(.transcribeFailed(reason: "x", detail: nil))
        }
        recovers.say("hello")                                                 // a success resets the count
        recovers.send(.turnRunning(false))
        for _ in 1...2 {
            recovers.send(.takeEnded(file: recovers.file, heardSpeech: true, meterFailed: false, ms: 2000))
            recovers.send(.transcribeFailed(reason: "x", detail: nil))
        }
        #expect(recovers.ends.isEmpty)
    }

    @Test("Rule 4 and row L534: what was said while reconnecting is never sent")
    func lostSpeech() {
        var loop = LoopHarness()
        loop.listening()
        loop.send(.connection(open: false))
        #expect(loop.state.view(name: "Ivy").title == "Reconnecting…")
        loop.send(.connection(open: true))
        // The take overlapped the drop: thrown away, even though the socket is back.
        #expect(loop.send(.takeEnded(file: loop.file, heardSpeech: true, meterFailed: false, ms: 3000)) == [.discard(file: loop.file), .beginTake])
        #expect(loop.state.view(name: "Ivy").hint == "Didn’t send what you said while reconnecting. Say it again.")
        #expect(loop.count(.transcribe(file: loop.file)) == 0)
        // The next take reaches Transcribing: the hint clears, and it is sent.
        loop.send(.takeEnded(file: loop.file, heardSpeech: true, meterFailed: false, ms: 3000))
        #expect(!loop.state.lostSpeech)
        #expect(loop.send(.transcript("say it again")).first == .submit(text: "say it again", interrupted: false))

        // A take that began while the socket was down is tainted too; silence while down is not "lost speech".
        var down = LoopHarness()
        down.send(.start)
        down.send(.connection(open: false))
        down.send(.micReady)
        #expect(down.send(.takeEnded(file: down.file, heardSpeech: false, meterFailed: false, ms: 12_000)) == [.discard(file: down.file), .beginTake])
        #expect(!down.state.lostSpeech)
        down.send(.connection(open: true))
        down.send(.takeEnded(file: down.file, heardSpeech: true, meterFailed: false, ms: 2000))
        #expect(down.state.lostSpeech && down.state.status == .listening)

        // The words came back after the socket dropped: not sent.
        var late = LoopHarness()
        late.listening()
        late.send(.takeEnded(file: late.file, heardSpeech: true, meterFailed: false, ms: 2000))
        late.send(.connection(open: false))
        #expect(late.send(.transcript("hello")) == [.beginTake])
        #expect(late.state.lostSpeech)
    }

    @Test("Rules 5 and 6: the reply is spoken as it streams, then the microphone re-arms")
    func speaking() {
        var loop = LoopHarness()
        loop.listening()
        loop.say("what's on my calendar")
        #expect(loop.send(.reply(nil)).isEmpty)
        #expect(loop.send(loop.reply("Sure. ", pending: true)) == [.openSpeech(messageId: "m1"), .feedSpeech(text: "Sure. ")])
        #expect(loop.state.status == .thinking)
        #expect(loop.send(loop.reply("Sure. ", pending: true)).isEmpty)                     // nothing new: nothing fed
        #expect(loop.send(loop.reply("Sure. Your first meeting ", pending: true)) == [.feedSpeech(text: "Sure. Your first meeting ")])
        loop.send(.speechStarted)
        #expect(loop.state.status == .speaking && loop.state.view(name: "Ivy").title == "Ivy is speaking")
        #expect(loop.send(loop.reply("Sure. Your first meeting is at nine.", pending: false))
                == [.feedSpeech(text: "Sure. Your first meeting is at nine."), .finishSpeech])
        #expect(loop.send(.turnRunning(false)).isEmpty)                                    // still speaking
        #expect(loop.state.status == .speaking)
        #expect(loop.send(.speechFinished) == [.disarmBarge, .beginTake])
        #expect(loop.state.status == .listening && loop.count(.finishSpeech) == 1)
    }

    @Test("A reply with nothing speakable, or one that was already there, is not spoken")
    func unspeakable() {
        var loop = LoopHarness()
        loop.listening()
        loop.send(loop.reply("An older answer.", pending: false, id: "old"))
        loop.say("show me the code")
        #expect(loop.send(loop.reply("An older answer.", pending: false, id: "old")).isEmpty)
        #expect(loop.send(loop.reply("```swift\nlet a = 1\n```", pending: false, id: "m2")).isEmpty)
        #expect(loop.send(.turnRunning(false)) == [.disarmBarge, .beginTake])
        #expect(loop.count(.openSpeech(messageId: "m2")) == 0 && loop.state.status == .listening)
    }

    @Test("The turn ends before the speech was told to finish: it is finished once")
    func turnEndsFirst() {
        var loop = LoopHarness()
        loop.listening()
        loop.say("hi")
        loop.send(loop.reply("Hello there, how are you?", pending: true))
        #expect(loop.send(.turnRunning(false)) == [.finishSpeech])
        #expect(loop.send(loop.reply("Hello there, how are you?", pending: false)).isEmpty)
        loop.send(.speechStarted)
        #expect(loop.send(.speechFinished) == [.disarmBarge, .beginTake])
        #expect(loop.count(.finishSpeech) == 1)
    }

    @Test("Rule 7: with Read Replies Aloud off nothing is spoken and the microphone re-arms when the turn ends")
    func sttOnly() {
        var loop = LoopHarness(speaks: false)
        loop.listening()
        #expect(loop.say("hello") == [.submit(text: "hello", interrupted: false), .armBarge])
        #expect(loop.send(loop.reply("Hi! How can I help?", pending: true)).isEmpty)
        #expect(loop.send(loop.reply("Hi! How can I help?", pending: false)).isEmpty)
        #expect(loop.send(.turnRunning(false)) == [.disarmBarge, .beginTake])
        // Barge-in still stops a running turn.
        loop.say("and another thing")
        #expect(loop.send(.bargeSpeech) == [.stopTurn])
    }

    @Test("Rule 8: barge-in silences the bot, stops the turn, and sends what was said as interrupted")
    func bargeIn() {
        var loop = LoopHarness()
        loop.listening()
        loop.say("tell me a long story")
        loop.send(loop.reply("Once upon a time there was a small robot.", pending: true))
        loop.send(.speechStarted)
        #expect(loop.send(.bargeSpeech) == [.stopSpeech, .stopTurn])
        #expect(loop.state.status == .listening)
        #expect(loop.send(.speechFinished).isEmpty)                                         // the stopped speech reports in: ignored
        #expect(loop.send(.bargeUtterance(file: loop.other)) == [.transcribe(file: loop.other)])
        #expect(loop.state.status == .transcribing)
        // The stopped turn is still unwinding: the words wait for it.
        #expect(loop.send(.transcript("no, tomorrow")).isEmpty)
        #expect(loop.send(loop.reply("Once upon a time there was a small robot. It", pending: false)).isEmpty)
        #expect(loop.send(.turnRunning(false)) == [.submit(text: "no, tomorrow", interrupted: true), .armBarge])
        #expect(loop.state.status == .thinking)
        // The cut-off reply is never spoken again; the new one is.
        loop.send(.turnRunning(true))
        #expect(loop.send(loop.reply("Once upon a time there was a small robot. It", pending: false)).isEmpty)
        #expect(loop.send(loop.reply("Tomorrow then.", pending: true, id: "m2")).first == .openSpeech(messageId: "m2"))
        // The flag is used once.
        loop.send(.speechStarted)
        loop.send(loop.reply("Tomorrow then.", pending: false, id: "m2"))
        loop.send(.turnRunning(false))
        loop.send(.speechFinished)
        #expect(loop.say("thanks").first == .submit(text: "thanks", interrupted: false))
    }

    @Test("T16: a barged-in sentence is sent after 5 s even if the stopped turn never reports its end")
    func bargeSettles() {
        var loop = LoopHarness()
        loop.listening()
        loop.say("go")
        loop.send(.bargeSpeech)
        loop.send(.bargeUtterance(file: loop.other))
        loop.send(.transcript("wait"))
        #expect(loop.send(.tick, after: 4.9).isEmpty)
        #expect(loop.send(.tick, after: 0.2) == [.submit(text: "wait", interrupted: true), .armBarge])
    }

    @Test("Echo: the microphone heard the bot; nothing is sent and nothing is marked interrupted")
    func echo() {
        var loop = LoopHarness()
        loop.listening()
        loop.say("how did the deploy go")
        loop.send(loop.reply("The deployment finished successfully. All three services came up healthy, and the smoke tests passed without any errors.", pending: true))
        loop.send(.speechStarted)
        loop.send(.bargeSpeech)
        loop.send(.bargeUtterance(file: loop.other))
        #expect(loop.send(.transcript("the smoke tests passed without any errors")) == [.beginTake])
        #expect(loop.state.status == .listening)
        loop.send(.turnRunning(false))
        #expect(loop.say("ok thanks").first == .submit(text: "ok thanks", interrupted: false))

        var nothing = LoopHarness()
        nothing.listening()
        nothing.say("go")
        nothing.send(.bargeSpeech)
        #expect(nothing.send(.bargeUtterance(file: nil)) == [.beginTake])
    }

    @Test("Barge-in off: nothing is armed, and speech during the reply does nothing")
    func bargeOff() {
        var loop = LoopHarness(config: TalkConfig(config: .object(["voice": .object(["barge_in": .bool(false)])])))
        loop.listening()
        #expect(loop.say("hello") == [.submit(text: "hello", interrupted: false)])
        #expect(loop.send(.bargeSpeech).isEmpty)
        #expect(loop.state.view(name: "Ivy").hint == "Ivy is working on it.")
    }

    @Test("Rule 9: Send Now, Stop, Interrupt")
    func buttons() {
        var loop = LoopHarness()
        loop.listening()
        #expect(loop.send(.sendNow) == [.finishTake])
        // Sent even though the meter heard nothing.
        #expect(loop.send(.takeEnded(file: loop.file, heardSpeech: false, meterFailed: false, ms: 1500)) == [.transcribe(file: loop.file)])
        loop.send(.transcript("quiet words"))
        loop.send(.turnRunning(true))
        #expect(loop.send(.sendNow).isEmpty)                                                // not offered while thinking
        // Stop while thinking: the turn stops, the microphone re-arms, and nothing is marked interrupted.
        #expect(loop.send(.stopOrInterrupt) == [.stopTurn, .disarmBarge, .beginTake])
        #expect(loop.state.status == .listening)
        loop.send(.takeEnded(file: loop.file, heardSpeech: true, meterFailed: false, ms: 1500))
        loop.send(.transcript("next"))                                                      // waits for the stopped turn
        #expect(loop.send(.turnRunning(false)) == [.submit(text: "next", interrupted: false), .armBarge])
        // Interrupt while speaking marks the next prompt.
        loop.send(.turnRunning(true))
        loop.send(loop.reply("A long answer follows here.", pending: true, id: "m3"))
        loop.send(.speechStarted)
        #expect(loop.send(.stopOrInterrupt) == [.stopSpeech, .stopTurn, .disarmBarge, .beginTake])
        loop.send(.turnRunning(false))
        #expect(loop.say("shorter please").first == .submit(text: "shorter please", interrupted: true))
        #expect(loop.send(.stopOrInterrupt, after: 0) == [.stopTurn, .disarmBarge, .beginTake])
    }

    @Test("The interrupted flag lasts 120 s")
    func interruptedLifetime() {
        var loop = LoopHarness(clock: TalkClock(scale: 1000))     // the silence pause is not what is tested here
        loop.state.clock = TalkClock()
        loop.listening()
        loop.say("go")
        loop.send(loop.reply("A long answer follows here.", pending: true))
        loop.send(.speechStarted)
        loop.send(.stopOrInterrupt)
        loop.send(.turnRunning(false))
        loop.send(.level(0.5), after: 60)
        loop.send(.level(0.5), after: 61)
        #expect(loop.say("later").first == .submit(text: "later", interrupted: false))
    }

    @Test("Rule 9: Mute cancels the take and the barge listener; Unmute puts back the right one")
    func mute() {
        var loop = LoopHarness()
        loop.listening()
        #expect(loop.send(.muteToggled) == [.cancelTake])
        #expect(loop.state.view(name: "Ivy").title == "Muted" && !loop.state.view(name: "Ivy").centerEnabled)
        #expect(loop.send(.takeEnded(file: loop.file, heardSpeech: true, meterFailed: false, ms: 900)) == [.discard(file: loop.file)])
        #expect(loop.send(.sendNow).isEmpty)
        #expect(loop.send(.muteToggled) == [.beginTake])
        loop.say("hello")
        #expect(loop.send(.muteToggled) == [.disarmBarge])
        #expect(loop.send(.bargeSpeech).isEmpty)
        #expect(loop.send(.muteToggled) == [.armBarge])
        loop.send(.muteToggled)
        // The turn ends while muted: no take.
        #expect(loop.send(.turnRunning(false)).isEmpty)
        #expect(loop.state.status == .listening && loop.state.muted)
        #expect(loop.send(.muteToggled) == [.beginTake])
    }

    @Test("Rule 10: reconnecting shows on the dock; the take keeps recording")
    func reconnecting() {
        var loop = LoopHarness()
        loop.listening()
        #expect(loop.send(.connection(open: false)).isEmpty)
        #expect(loop.state.view(name: "Ivy").phase == .reconnecting && loop.state.takeOpen)
        #expect(loop.send(.sendNow).isEmpty)
        #expect(loop.send(.connection(open: true)).isEmpty)
        #expect(loop.state.view(name: "Ivy").phase == .listening)
    }

    @Test("Rule 11: Still Listening at 30 s, paused at 120 s; speech, thinking and mute reset the clock")
    func silence() {
        var loop = LoopHarness()
        loop.listening()
        #expect(loop.send(.tick, after: 29).isEmpty && loop.state.view(name: "Ivy").title == "Listening")
        loop.send(.tick, after: 1)
        #expect(loop.state.view(name: "Ivy").title == "Still Listening")
        loop.send(.level(0.2))
        #expect(loop.state.view(name: "Ivy").title == "Listening")
        loop.send(.tick, after: 100)
        #expect(loop.ends.isEmpty)
        #expect(loop.send(.tick, after: 20) == [.cancelTake, .ended(.paused(.silence, detail: nil))])

        var busy = LoopHarness()
        busy.listening()
        busy.say("hello")
        busy.send(.tick, after: 300)                                                         // a five-minute reply
        #expect(busy.ends.isEmpty)
        busy.send(.turnRunning(false))
        busy.send(.tick, after: 119)
        #expect(busy.ends.isEmpty)
        busy.send(.tick, after: 2)
        #expect(busy.ends == [.paused(.silence, detail: nil)])

        var muted = LoopHarness()
        muted.listening()
        muted.send(.muteToggled)
        muted.send(.tick, after: 500)
        #expect(muted.ends.isEmpty)

        var fast = LoopHarness(clock: TalkClock(scale: 20))
        fast.listening()
        fast.send(.tick, after: 1.6)
        #expect(fast.state.view(name: "Ivy").title == "Still Listening")
        fast.send(.tick, after: 4.5)
        #expect(fast.ends == [.paused(.silence, detail: nil)])
    }

    @Test("Rule 12: an interruption ends the conversation with its cause")
    func interruptions() {
        for cause in [TalkPauseCause.interrupted, .background, .routeLost] {
            var loop = LoopHarness()
            loop.listening()
            loop.say("hello")
            loop.send(loop.reply("An answer that is being spoken.", pending: true))
            loop.send(.speechStarted)
            #expect(loop.send(.interrupted(cause, detail: "why")) == [.stopSpeech, .disarmBarge, .ended(.paused(cause, detail: "why"))])
        }
    }

    @Test("Rule 13: a question mutes and un-mutes by itself; other audio leaves it muted; a manual mute is kept")
    func autoMute() {
        var loop = LoopHarness()
        loop.listening()
        #expect(loop.send(.questionWaiting(true)) == [.cancelTake])
        #expect(loop.state.muted && loop.state.autoMuted)
        #expect(loop.send(.questionWaiting(false)) == [.beginTake])
        #expect(!loop.state.muted)

        var manual = LoopHarness()
        manual.listening()
        manual.send(.muteToggled)
        #expect(manual.send(.questionWaiting(true)).isEmpty)
        #expect(manual.send(.questionWaiting(false)).isEmpty)
        #expect(manual.state.muted)

        var audio = LoopHarness()
        audio.listening()
        #expect(audio.send(.otherAudio(true)) == [.cancelTake])
        #expect(audio.send(.otherAudio(false)).isEmpty)
        #expect(audio.state.muted && !audio.state.autoMuted)
        #expect(audio.send(.muteToggled) == [.beginTake])

        // Other audio while a question holds the mute: the person has to un-mute.
        var both = LoopHarness()
        both.listening()
        both.send(.questionWaiting(true))
        both.send(.otherAudio(true))
        #expect(both.send(.questionWaiting(false)).isEmpty)
        #expect(both.state.muted)
    }

    @Test("A speech failure leaves the reply as text and listens; an unplayable voice stops")
    func speechFailures() {
        var loop = LoopHarness()
        loop.listening()
        loop.say("hello")
        loop.send(loop.reply("Here is the answer in words.", pending: false))
        loop.send(.turnRunning(false))
        #expect(loop.send(.speechFailed(reason: "The gateway didn’t answer.", fatal: false)) == [.haptic(.error), .disarmBarge, .beginTake])
        #expect(loop.state.problem == "Voice Playback Failed. The gateway didn’t answer." && loop.state.status == .listening)

        var fatal = LoopHarness()
        fatal.listening()
        fatal.say("hello")
        fatal.send(fatal.reply("Here is the answer in words.", pending: true))
        let reason = "Your gateway’s voice uses a format iPhone can’t play (audio/ogg). Pick another Text to Speech provider in Settings › Voice."
        #expect(fatal.send(.speechFailed(reason: reason, fatal: true))
                == [.stopSpeech, .disarmBarge, .ended(.stopped(title: "Voice Playback Failed", message: reason, detail: nil))])
    }

    @Test("Every ending releases everything exactly once, and nothing happens afterwards")
    func endings() {
        let endings: [(TalkLoopInput, TalkEnd)] = [
            (.end, .user),
            (.interrupted(.background, detail: nil), .paused(.background, detail: nil)),
            (.finish(.replaced), .replaced),
            (.finish(.gone), .gone),
            (.chatClosed(reason: "session not found"), .stopped(title: "Voice Transcription Failed", message: "This chat can’t send right now.", detail: "session not found")),
        ]
        for (input, expected) in endings {
            // While listening.
            var listening = LoopHarness()
            listening.listening()
            #expect(listening.send(input) == [.cancelTake, .ended(expected)])
            // While the bot speaks.
            var speaking = LoopHarness()
            speaking.listening()
            speaking.say("hello")
            speaking.send(speaking.reply("An answer that is being spoken.", pending: true))
            speaking.send(.speechStarted)
            #expect(speaking.send(input) == [.stopSpeech, .disarmBarge, .ended(expected)])
            // While waiting for a barge-in utterance.
            var barging = LoopHarness()
            barging.listening()
            barging.say("hello")
            barging.send(.bargeSpeech)
            #expect(barging.send(input) == [.cancelTake, .ended(expected)])
            for var loop in [listening, speaking, barging] {
                #expect(loop.ends == [expected])
                let after: [TalkLoopInput] = [.end, .micReady, .muteToggled, .sendNow, .stopOrInterrupt, .tick, .turnRunning(false), .speechFinished,
                                              .transcript("late words"), .bargeSpeech, .questionWaiting(false), .connection(open: true),
                                              .interrupted(.silence, detail: nil), .reply(nil)]
                for input in after { #expect(loop.send(input, after: 200).isEmpty) }
                // A take that was still being written is only cleaned up.
                #expect(loop.send(.takeEnded(file: loop.file, heardSpeech: true, meterFailed: false, ms: 900)) == [.discard(file: loop.file)])
                #expect(loop.send(.bargeUtterance(file: loop.other)) == [.discard(file: loop.other)])
                #expect(loop.ends == [expected])
            }
        }
        #expect(TalkEnd.user.showsEndedCaption && TalkEnd.said.showsEndedCaption && !TalkEnd.replaced.showsEndedCaption)
        #expect(!TalkEnd.paused(.silence, detail: nil).showsEndedCaption && !TalkEnd.gone.showsEndedCaption)
    }
}
