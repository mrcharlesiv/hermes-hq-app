// docs/spec/3x-talk.md §14.1: the dock's words, stop phrases, the echo guard and speech text. Vectors are the web
// app's own (`src/ui-voice/dock-state.ts`, `vendor/.../lib/voice-stop-word.test.ts`, `voice-tts-echo.test.ts`,
// `speech-text.test.ts`), ported.

import Foundation
import Testing
@testable import HermesHQNative

@Suite("Talk dock state")
struct TalkDockStateTests {
    private func view(_ status: TalkStatus, muted: Bool = false, reconnecting: Bool = false, lost: Bool = false,
                      silence: TalkSilence = .ok, listened: Bool = true, bargeIn: Bool = true) -> TalkDockView {
        TalkDockState.view(status: status, muted: muted, reconnecting: reconnecting, lostSpeech: lost, silence: silence,
                           listened: listened, name: "Ivy", bargeIn: bargeIn)
    }

    @Test("§6.2: the ten rows, word for word, first match wins")
    func tenRows() {
        var v = view(.speaking, muted: true, reconnecting: true)
        #expect(v.title == "Muted" && v.hint == "Ivy can’t hear you. Tap Mute to talk again." && v.center == .sendNow && !v.centerEnabled && v.visual == .muted)
        v = view(.listening, reconnecting: true)
        #expect(v.title == "Reconnecting…" && v.hint == "Waiting for your gateway." && v.center == .sendNow && !v.centerEnabled && v.visual == .wait)
        v = view(.transcribing)
        #expect(v.title == "Transcribing…" && v.hint == "Turning your words into text." && v.center == .spinner && v.centerLabel == "Transcribing" && !v.centerEnabled)
        v = view(.thinking)
        #expect(v.title == "Thinking…" && v.hint == "Ivy is working on it. Talking now interrupts." && v.center == .stop && v.centerLabel == "Stop" && v.centerEnabled)
        v = view(.speaking)
        #expect(v.title == "Ivy is speaking" && v.hint == "Start talking or tap Interrupt to cut in." && v.center == .interrupt && v.centerLabel == "Interrupt" && v.centerEnabled && v.visual == .speak)
        v = view(.listening, lost: true, silence: .still)
        #expect(v.phase == .lostSpeech && v.title == "Listening" && v.hint == "Didn’t send what you said while reconnecting. Say it again." && v.centerEnabled)
        v = view(.listening, silence: .still)
        #expect(v.title == "Still Listening" && v.hint == "Talk when you’re ready, or tap End." && v.centerLabel == "Send Now" && v.centerEnabled)
        v = view(.listening)
        #expect(v.title == "Listening" && v.hint == "Go ahead. It sends when you pause." && v.center == .sendNow && v.centerEnabled && v.visual == .listen)
        v = view(.idle, listened: true)
        #expect(v.title == "Listening" && v.hint == "Go ahead. It sends when you pause." && !v.centerEnabled)
        v = view(.idle, listened: false)
        #expect(v.phase == .starting && v.title == "Starting…" && v.hint == "Getting the microphone ready." && !v.centerEnabled && v.visual == .wait)
    }

    @Test("Barge-in off: the hints stop promising it")
    func bargeOff() {
        #expect(view(.thinking, bargeIn: false).hint == "Ivy is working on it.")
        #expect(view(.speaking, bargeIn: false).hint == "Tap Interrupt to cut in.")
    }

    @Test("Centre symbols")
    func symbols() {
        #expect(TalkDockView.Center.sendNow.symbol == "arrow.up" && TalkDockView.Center.stop.symbol == "stop.fill")
        #expect(TalkDockView.Center.interrupt.symbol == "hand.raised.fill" && TalkDockView.Center.spinner.symbol == nil)
    }

    @Test("formatElapsed: 0:07, 2:14, 1:02:03")
    func elapsed() {
        #expect(TalkDockState.formatElapsed(7.9) == "0:07")
        #expect(TalkDockState.formatElapsed(134) == "2:14")
        #expect(TalkDockState.formatElapsed(3723) == "1:02:03")
        #expect(TalkDockState.formatElapsed(-4) == "0:00")
        #expect(TalkDockState.formatElapsed(.nan) == "0:00")
        #expect(TalkDockState.formatElapsed(600) == "10:00")
    }

    @Test("SilenceClock: still at 30 s, pause at 120 s, and what resets it")
    func silenceClock() {
        var clock = SilenceClock(now: 0)
        #expect(clock.state(status: .listening, muted: false, now: 29.9) == .ok)
        #expect(clock.state(status: .listening, muted: false, now: 30) == .still)
        #expect(clock.state(status: .idle, muted: false, now: 119.9) == .still)
        #expect(clock.state(status: .transcribing, muted: false, now: 120) == .pause)
        #expect(clock.state(status: .listening, muted: true, now: 500) == .ok)
        #expect(clock.state(status: .thinking, muted: false, now: 500) == .ok)
        #expect(clock.state(status: .speaking, muted: false, now: 500) == .ok)
        clock.observe(status: .listening, level: 0.074, muted: false, now: 100)
        #expect(clock.state(status: .listening, muted: false, now: 100) == .still)
        clock.observe(status: .listening, level: 0.075, muted: false, now: 100)
        #expect(clock.state(status: .listening, muted: false, now: 129) == .ok)
        clock.observe(status: .thinking, level: 0, muted: false, now: 200)
        #expect(clock.state(status: .listening, muted: false, now: 229) == .ok)
        clock.observe(status: .listening, level: 0, muted: true, now: 300)
        #expect(clock.state(status: .listening, muted: false, now: 329) == .ok)
        clock.reset(now: 400)
        #expect(clock.state(status: .listening, muted: false, now: 431) == .still)
        let fast = SilenceClock(now: 0, clock: TalkClock(scale: 20))
        #expect(fast.state(status: .listening, muted: false, now: 1.5) == .still && fast.state(status: .listening, muted: false, now: 6) == .pause)
    }

    @Test("§6.4: the four paused notices")
    func paused() {
        let cases: [(TalkPauseCause, String)] = [
            (.interrupted, "A call or Siri took the microphone. Your chat with Ivy is saved."),
            (.background, "Voice stops when Hermes HQ leaves the screen. Your chat with Ivy is saved."),
            (.silence, "Paused after 2 minutes of silence. Your chat with Ivy is saved."),
            (.routeLost, "The headset or microphone disconnected. Your chat with Ivy is saved."),
        ]
        for (cause, message) in cases {
            let notice = TalkDockState.pausedNotice(cause, name: "Ivy", detail: nil, app: "Hermes HQ")
            #expect(notice.kind == .paused && notice.title == "Voice Paused" && notice.message == message && notice.action == .resume && notice.cause == cause)
            #expect(notice.action.title == "Resume")
        }
        #expect(TalkDockState.pausedNotice(.interrupted, name: "Ivy", detail: "interruption began", app: "Hermes HQ").detail == "interruption began")
    }

    @Test("stoppedNotice: the failure's title heads the card, the message only explains, and the microphone decides the button")
    func stopped() {
        var notice = TalkDockState.stoppedNotice(title: "Voice Transcription Failed", message: "No speech provider", detail: "400")
        #expect(notice.kind == .stopped && notice.title == "Voice Transcription Failed" && notice.message == "No speech provider")
        #expect(notice.action == .tryAgain && notice.detail == "400" && notice.action.title == "Try Again")
        notice = TalkDockState.stoppedNotice(title: "Microphone failed", message: "Microphone failed. Could not start microphone recording.")
        #expect(notice.title == "Microphone failed" && notice.message == "Could not start microphone recording." && notice.action == .tryAgain)
        notice = TalkDockState.stoppedNotice(title: "Microphone failed", message: "Microphone failed.")
        #expect(notice.message == "Microphone failed.", "a message that is only the title stays whole")
        notice = TalkDockState.stoppedNotice(title: "", message: "Hermes HQ can’t use the microphone. Allow Microphone for Hermes HQ in iOS Settings.")
        #expect(notice.title == "Voice Stopped" && notice.action == .openSettings && notice.action.title == "Open Settings")
        notice = TalkDockState.stoppedNotice(title: "Voice Stopped", message: "Something", detail: "Microphone access is off")
        #expect(notice.action == .openSettings)
        #expect(TalkDockState.stoppedNotice(title: "", message: "The microphone isn’t giving a level, so Hermes HQ can’t tell when you stop talking.").action == .tryAgain)
    }

    @Test("noticeText: title, message, detail, one per line")
    func noticeText() {
        let notice = TalkDockState.pausedNotice(.silence, name: "Ivy", detail: "detail line", app: "Hermes HQ")
        #expect(TalkDockState.noticeText(notice) == "Voice Paused\nPaused after 2 minutes of silence. Your chat with Ivy is saved.\ndetail line")
        #expect(TalkDockState.noticeText(TalkDockState.pausedNotice(.silence, name: "Ivy", app: "Hermes HQ")).split(separator: "\n").count == 2)
    }

    @Test("§6.6 and §6.7: the pill and the ended caption")
    func pill() {
        #expect(TalkDockState.pillLabel(name: "Ivy", status: .listening, muted: false, elapsed: 134) == "Ivy · Listening · 2:14")
        #expect(TalkDockState.pillLabel(name: "Ivy", status: .idle, muted: false, elapsed: 0) == "Ivy · Listening · 0:00")
        #expect(TalkDockState.pillLabel(name: "Ivy", status: .speaking, muted: true, elapsed: 5) == "Ivy · Muted · 0:05")
        #expect(TalkDockState.pillStatus(.transcribing, muted: false) == "Transcribing" && TalkDockState.pillStatus(.thinking, muted: false) == "Thinking")
        #expect(TalkDockState.pillStatus(.speaking, muted: false) == "Speaking")
        #expect(TalkDockState.pillLabel(name: "Ivy", status: .thinking, muted: false, elapsed: 1, problem: true) == "Ivy · Problem · 0:01")
        #expect(TalkDockState.pillLabel(notice: TalkDockState.pausedNotice(.silence, name: "Ivy", app: "Hermes HQ"), name: "Ivy")
                == "Ivy · Voice Paused · Tap for details")
        #expect(TalkDockState.pillLabel(notice: TalkDockState.stoppedNotice(title: "Voice Transcription Failed", message: "x"), name: "Ada")
                == "Ada · Voice Stopped · Tap for details")
        #expect(TalkDockState.endedCaption(elapsed: 134) == "Voice chat ended · 2:14")
    }
}

@Suite("Talk route name")
struct TalkRouteNameTests {
    @Test("§6.5: the web's mapping")
    func names() {
        #expect(TalkDockState.routeName(.receiver, portName: "Receiver", device: "iPhone") == "iPhone")
        #expect(TalkDockState.routeName(.speaker, portName: "Speaker", device: "iPad") == "Speaker")
        #expect(TalkDockState.routeName(.headphones, portName: "Headphones", device: "iPhone") == "Headphones")
        #expect(TalkDockState.routeName(.other, portName: "Alex’s AirPods Pro", device: "iPhone") == "Alex’s AirPods Pro")
        #expect(TalkDockState.routeName(.other, portName: "  ", device: "iPhone") == "iPhone")
        #expect(TalkDockState.routeName(.none, portName: nil, device: "iPhone") == "iPhone")
    }
}

@Suite("Talk stop words")
struct TalkStopWordTests {
    @Test("The built-in list, with address prefixes, punctuation and case")
    func defaults() {
        for said in ["stop", "Stop.", "STOP!", "hey hermes, stop", "Hermes stop", "ok stop", "okay, stop listening", "please stop",
                     "That's all.", "never mind", "Goodbye!", "hey, cancel", "  stop  ", "Stop… "] {
            #expect(TalkStopWord.isStop(said), "\(said)")
        }
        for said in ["stop the deploy", "how do I stop a running process", "hermes", "hey hermes", "", "   ", "stopwatch", "don't stop",
                     "ok", "bye for now"] {
            #expect(!TalkStopWord.isStop(said), "\(said)")
        }
    }

    @Test("A custom list replaces the English one; an empty list turns it off")
    func custom() {
        let custom = TalkStopWord.Config.custom(["отбой", "fin"])
        #expect(TalkStopWord.isStop("Отбой!", config: custom) && TalkStopWord.isStop("«отбой»", config: custom) && TalkStopWord.isStop("hermes, fin", config: custom))
        #expect(!TalkStopWord.isStop("stop", config: custom))
        #expect(!TalkStopWord.isStop("stop", config: .disabled))
        #expect(!TalkStopWord.isStop("stop", config: .custom(["  "])))
    }

    @Test("voice.stop_phrases: default, changed, empty, malformed")
    func config() {
        #expect(TalkStopWord.config(from: nil) == .standard)
        #expect(TalkStopWord.config(from: .array([.string("stop")])) == .standard)
        #expect(TalkStopWord.config(from: .array([.string("STOP")])) == .standard)
        #expect(TalkStopWord.config(from: .array([])) == .disabled)
        #expect(TalkStopWord.config(from: .array([.string("fin"), .number(7), .bool(true), .string(" ")])) == .custom(["fin", "7"]))
        #expect(TalkStopWord.config(from: .string("halt")) == .custom(["halt"]))
        #expect(TalkStopWord.config(from: .object([:])) == .standard)
        #expect(TalkStopWord.config(from: .array([.string("fin")]), defaults: .array([.string("fin")])) == .standard)
    }

    @Test("A typed bare stop ends a live conversation; anything else is sent")
    func typed() {
        #expect(TalkStopWord.interceptsTyped(active: true, text: "stop"))
        #expect(!TalkStopWord.interceptsTyped(active: false, text: "stop"))
        #expect(!TalkStopWord.interceptsTyped(active: true, text: "stop", attachments: 1))
        #expect(!TalkStopWord.interceptsTyped(active: true, text: "stop the deploy"))
    }

    @Test("TalkConfig reads the gateway record and survives wrong types")
    func talkConfig() {
        let usual = TalkConfig(config: .object(["stt": .object(["enabled": .bool(true)]), "voice": .object([
            "silence_duration": .number(3.0), "barge_in": .bool(true), "barge_in_threshold_multiplier": .number(3),
            "stop_phrases": .array([.string("stop")]), "max_recording_seconds": .number(120)])]))
        #expect(usual.sttEnabled && usual.silenceMs == 1250 && usual.bargeIn && usual.bargeMultiplier == 3)
        #expect(usual.stopPhrases == .standard && usual.maxRecordingSeconds == 120)
        let changed = TalkConfig(config: .object(["stt": .object(["enabled": .bool(false)]), "voice": .object([
            "silence_duration": .number(2), "barge_in": .bool(false), "barge_in_threshold_multiplier": .number(6),
            "stop_phrases": .array([]), "max_recording_seconds": .number(99999)])]))
        #expect(!changed.sttEnabled && changed.silenceMs == 2000 && !changed.bargeIn && changed.bargeMultiplier == 6)
        #expect(changed.stopPhrases == .disabled && changed.maxRecordingSeconds == 600)
        let wrong = TalkConfig(config: .object(["voice": .object([
            "max_recording_seconds": .string("abc"), "stop_phrases": .object([:]), "silence_duration": .number(0),
            "barge_in": .string("no"), "barge_in_threshold_multiplier": .number(0)])]))
        #expect(wrong.sttEnabled && wrong.silenceMs == 1250 && wrong.bargeIn && wrong.bargeMultiplier == nil)
        #expect(wrong.stopPhrases == .standard && wrong.maxRecordingSeconds == 120)
        #expect(TalkConfig(config: .object(["voice": .object(["stop_phrases": .string("stop")])])).stopPhrases == .standard)
        #expect(TalkConfig(config: .object(["voice": .object(["silence_duration": .number(3), "max_recording_seconds": .number(0)])])).maxRecordingSeconds == 1)
        #expect(TalkConfig(config: .object(["voice": .object(["max_recording_seconds": .number(-5)])])).maxRecordingSeconds == 1)
        #expect(TalkConfig(config: nil) == TalkConfig())
        #expect(TalkConfig(config: .object(["voice": .object(["silence_duration": .number(600)])])).silenceMs == 60_000)
    }
}

@Suite("Talk echo guard")
struct TalkEchoTests {
    @Test("difflib's ratio, CPython's reference values")
    func ratio() {
        #expect(abs(TalkEcho.ratio(Array("abcd"), Array("bcde")) - 0.75) < 1e-12)
        #expect(abs(TalkEcho.ratio(Array("This is a rather different sentence about coding."),
                                   Array("This is a moderately similar sentence about testing.")) - 0.693069306930693) < 1e-12)
        #expect(TalkEcho.ratio([], []) == 1)
        let a = Array("the smoke tests passed without any errors")
        let b = Array(String(repeating: "The deployment finished successfully. ", count: 6).lowercased())
        #expect(abs(TalkEcho.ratio(a, b) - 0.02973977695167286) < 1e-12)
    }

    @Test("The vendor's vectors")
    func vectors() {
        let reply = "Sure, I can help with that right away."
        #expect(TalkEcho.isEcho(reply, of: reply))
        #expect(TalkEcho.isEcho("네 방금 네 방금도 제 답변이 그대로 다시 입력됐어요.", of: "네, 방금도 제 답변이 그대로 다시 입력됐어요."))
        #expect(!TalkEcho.isEcho("actually can you also check my calendar for tomorrow", of: "The weather today is sunny with a light breeze from the west."))
        #expect(!TalkEcho.isEcho("stop", of: "I've finished summarizing the document you shared earlier."))
        let long = "Sure, here's a summary of what we found. The build failed because of a missing dependency in the "
            + "lockfile. I've already gone ahead and regenerated it, and the tests are passing again locally. Let "
            + "me know if you'd like me to open a PR for this or if you want to review the diff first before I do anything else."
        #expect(TalkEcho.isEcho("Sure, here's a summary of what we found.", of: long))
        #expect(TalkEcho.isEcho("the smoke tests passed without any errors",
                                of: "The deployment finished successfully. All three services came up healthy, and the smoke tests passed without any errors."))
        #expect(!TalkEcho.isEcho("yes", of: "Yes, I can help with that -- let me pull up the details for you."))
        #expect(!TalkEcho.isEcho("", of: "hello") && !TalkEcho.isEcho("hello", of: "") && !TalkEcho.isEcho("", of: ""))
        #expect(TalkEcho.isEcho("  SURE,   I can help with that   right away.  ", of: reply))
        let spoken = "This is a moderately similar sentence about testing.", transcript = "This is a rather different sentence about coding."
        #expect(TalkEcho.isEcho(transcript, of: spoken, threshold: 0.5) && !TalkEcho.isEcho(transcript, of: spoken, threshold: 0.95))
    }

    @Test("A fragment of a very long reply is still found, quickly")
    func longReply() {
        let filler = (0..<400).map { "Sentence number \($0) talks about item \($0 * 7) in the list." }.joined(separator: " ")
        let spoken = filler + " The smoke tests passed without any errors at all today. " + filler
        let started = Date()
        #expect(TalkEcho.isEcho("the smoke tests passed without any errors at all today", of: spoken))
        #expect(!TalkEcho.isEcho("please book a table for four at eight tonight", of: spoken))
        #expect(Date().timeIntervalSince(started) < 3)
    }
}

@Suite("Speech text")
struct SpeechTextTests {
    @Test("The vendor's vectors")
    func vectors() {
        let cases: [(String, String)] = [
            ("Here is code:\n```ts\nconst x = 1\n```\nDone.", "Here is code. Done."),
            ("Use `git status` after the change.", "Use git status after the change."),
            ("Here is the quick takeaway: the totals remain unchanged.\n\n| Item | Value | Notes |\n| --- | ---: | --- |\n| Example A | 10 | first row |\n| Example B | 20 | second row |\n\nFull detail stays visible on screen.",
             "Here is the quick takeaway: the totals remain unchanged. Item, Value, Notes. Full detail stays visible on screen."),
            ("Before the table.\n\n|   |   |\n| --- | --- |\n| a | b |\n\nAfter the table.", "Before the table. After the table."),
            ("Use the summary first | keep the table on screen when it matters.", "Use the summary first | keep the table on screen when it matters."),
            ("First sentence.\n\nSecond sentence.", "First sentence. Second sentence."),
            ("The files are below.\nMEDIA:/Users/ivy/Documents/inference-server-shopping-list.xlsx\nBye.", "The files are below. Bye."),
            ("See MEDIA:/tmp/report-2026-q3.xlsx. Then reply.", "See. Then reply."),
            ("See https://example.com/a-huge-page for details", "See for details"),
            ("This ~~is~~ old.", "This is old."),
            ("The file is below: MEDIA:/tmp/x.py", "The file is below."),
            ("The regex list:", "The regex list."),
            ("**First sentence.**\n\nSecond sentence.", "First sentence. Second sentence."),
            ("“First sentence.”\n\nSecond sentence.", "“First sentence.” Second sentence."),
            ("(First sentence.)\n\nSecond sentence.", "(First sentence.) Second sentence."),
            ("Main takeaway: total is unchanged.\n\nItem | Value\n--- | ---:\nExample A | 10\nExample B | 20\n\nDone.", "Main takeaway: total is unchanged. Item, Value. Done."),
            ("Before the table.\n\n> | Item | Value |\n> | --- | ---: |\n> | Example A | 10 |\n> | Example B | 20 |\n\nAfter the table.", "Before the table. Item, Value. After the table."),
            ("Before the table.\n\n| Item |\n| --- |\n| A |\n\nAfter the table.", "Before the table. Item. After the table."),
            ("Before the table.\n\n| Item \\| detail | Value |\n| --- | --- |\n| A | 1 |\n\nAfter the table.", "Before the table. Item detail, Value. After the table."),
            ("# Heading\n\n- one\n- two", "Heading. - one - two"),
            ("- one thing", "one thing"),
            ("[the docs](https://example.com/docs) say so", "the docs say so"),
            ("Done 🎉 and 👍🏽 ok", "Done and ok"),
        ]
        for (text, spoken) in cases { #expect(SpeechText.sanitizeForSpeech(text) == spoken, "\(text)") }
    }

    @Test("Nothing speakable gives an empty string")
    func unspeakable() {
        for text in ["```swift\nlet a = 1\n```", "🎉🎉", "https://example.com/page", "MEDIA:/tmp/a.png", "", "   \n ", "***", "> #"] {
            #expect(SpeechText.sanitizeForSpeech(text).isEmpty, "\(text)")
        }
        #expect(SpeechText.sanitizeForSpeech("Heading | Detail\n--- | --- | ---\nA | B").contains("Heading | Detail"))
        #expect(SpeechText.sanitizeForSpeech("    Item | Value\n    --- | ---").contains("Item | Value"))
    }

    @Test("cutSentences and SentenceBuffer")
    func sentences() {
        var cut = SpeechText.cutSentences("This is the first full sentence. And then it keeps goi", flush: false)
        #expect(cut.sentences == ["This is the first full sentence."] && cut.rest == "And then it keeps goi")
        cut = SpeechText.cutSentences("e.g. it continues", flush: false)
        #expect(cut.sentences.isEmpty && cut.rest == "e.g. it continues")
        cut = SpeechText.cutSentences("First complete sentence right here. tail bit", flush: true)
        #expect(cut.sentences == ["First complete sentence right here.", "tail bit"] && cut.rest.isEmpty)
        cut = SpeechText.cutSentences("这是一个完整的中文句子，它的长度足够超过最小句子门槛，所以会被切分出来。 下一句", flush: true)
        #expect(cut.sentences.count == 2 && cut.sentences[0].contains("。"))
        let text = "记得，叫团团。 然后我们再说第二句话，这一句要长一些才行。 "
        #expect(SpeechText.cutSentences(text, flush: false).sentences == ["记得，叫团团。 然后我们再说第二句话，这一句要长一些才行。"])
        #expect(SpeechText.cutSentences(text, flush: false, minimum: 6).sentences == ["记得，叫团团。", "然后我们再说第二句话，这一句要长一些才行。"])
        var buffer = SentenceBuffer()
        #expect(buffer.append("Wrap the plan in a <thinking> tag first. ") == ["Wrap the plan in a <thinking> tag first."])
        #expect(buffer.append("Then the answer follows here in prose. And a tail") == ["Then the answer follows here in prose."])
        #expect(buffer.flush() == ["And a tail"])
        #expect(buffer.flush().isEmpty)
    }
}
