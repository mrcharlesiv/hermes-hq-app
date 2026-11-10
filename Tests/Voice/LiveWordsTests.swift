// Live Words (docs/spec/3x-live-words.md): what a listener is fed, which words go where, and that the gateway's speech to
// text isn't called when this device heard the words. Apple's engine doesn't run in simulators, so a stand-in listener
// plays its part; the engine itself is checked on a Mac with `-HQDebugLiveWordsFile` (spec §7).

import Foundation
import QuartzCore
import Synchronization
import Testing
import UIKit
@testable import HermesHQNative

/// A listener that counts what it's fed and settles on fixed words.
nonisolated final class CountingListener: LiveWordsListening, Sendable {
    private struct State {
        var samples: [Int16] = []
        var cancelled = false
        var finished = false
    }

    private let state = Mutex(State())
    let words: String

    init(words: String = "") { self.words = words }

    var samples: [Int16] { state.withLock { $0.samples } }
    var cancelled: Bool { state.withLock { $0.cancelled } }
    var finished: Bool { state.withLock { $0.finished } }

    func feed(_ samples: UnsafeBufferPointer<Int16>) { state.withLock { $0.samples.append(contentsOf: samples) } }
    func finish() async -> String {
        state.withLock { $0.finished = true }
        return words
    }
    func cancel() { state.withLock { $0.cancelled = true } }
}

@Suite struct LiveWordsTextTests {
    @Test func settledAndPendingWordsJoinWithOneSpace() {
        #expect(LiveWordsText(settled: "Hey Hermes,", pending: "can you").whole == "Hey Hermes, can you")
        #expect(LiveWordsText(settled: " Hey ", pending: "").whole == "Hey")
        #expect(LiveWordsText(settled: "", pending: "  ").isEmpty)
        #expect(LiveWordsText.join("one.", " two") == "one. two")
    }

    /// The switch's footer says what happens on this device, never two things at once.
    @MainActor @Test func theSettingsNoteSaysOneTrueThing() {
        let ready = VoiceSettingsCatalog.liveWordsNote(on: true, readiness: .unknown)
        #expect(ready.contains("turns your speech into text as you talk"))
        let cant = VoiceSettingsCatalog.liveWordsNote(on: true, readiness: .unavailable("device not supported"))
        #expect(cant.contains("can’t show your words as you speak") && !cant.contains("as you talk"))
        let fetching = VoiceSettingsCatalog.liveWordsNote(on: true, readiness: .downloading)
        #expect(fetching.contains("getting its speech model ready") && !fetching.contains("as you talk"))
        let off = VoiceSettingsCatalog.liveWordsNote(on: false, readiness: .unavailable("device not supported"))
        #expect(off.hasPrefix("Off: Hermes turns your speech into text after you stop."))
    }

    @Test func theDeadlineAnswersWhenTheWorkDoesNot() async {
        let started = CACurrentMediaTime()
        let value = await LiveWordsWait.first(within: 0.1, otherwise: { "so far" }) {
            try? await Task.sleep(for: .seconds(5))
            return "settled"
        }
        #expect(value == "so far")
        #expect(CACurrentMediaTime() - started < 2)
        #expect(await LiveWordsWait.first(within: 2, otherwise: { "so far" }) { "settled" } == "settled")
    }
}

@Suite struct LiveWordsCaptureTests {
    /// Every event but levels, in order.
    nonisolated private final class Events: Sendable {
        private let list = Mutex<[TalkCaptureCore.Event]>([])
        func append(_ event: TalkCaptureCore.Event) { list.withLock { $0.append(event) } }
        func withLock<T>(_ read: ([TalkCaptureCore.Event]) -> T) -> T { list.withLock { read($0) } }
    }

    private func make() -> (TalkCaptureCore, Events, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("talk-words-\(UUID().uuidString)", isDirectory: true)
        let events = Events()
        let core = TalkCaptureCore(folder: folder) { event in
            if case .level = event { return }
            events.append(event)
        }
        return (core, events, folder)
    }

    private func feed(_ core: TalkCaptureCore, value: Int16, buffers: Int, size: Int = 341) {
        let chunk = [Int16](repeating: value, count: size)
        for _ in 0..<buffers { chunk.withUnsafeBufferPointer { core.feed($0) } }
    }

    @Test func aTakesListenerHearsEverySampleAndTheTakeCarriesIt() {
        let (core, events, folder) = make()
        defer { try? FileManager.default.removeItem(at: folder) }
        feed(core, value: 3, buffers: 4)   // before the take: not heard
        let listener = CountingListener()
        core.beginTake(silenceMs: 2_000, words: listener)
        feed(core, value: 8_000, buffers: 10)
        core.finishTake()
        feed(core, value: 9, buffers: 3)   // after it: not heard
        #expect(listener.samples.count == 10 * 341)
        #expect(listener.samples.allSatisfy { $0 == 8_000 })
        guard case .takeEnded(let take)? = events.withLock({ $0.last }) else {
            Issue.record("no take ended")
            return
        }
        #expect(take.words === listener)
        #expect(!listener.cancelled)
    }

    @Test func aCancelledTakeLetsItsListenerGo() {
        let (core, _, folder) = make()
        defer { try? FileManager.default.removeItem(at: folder) }
        let listener = CountingListener()
        core.beginTake(silenceMs: 2_000, words: listener)
        feed(core, value: 8_000, buffers: 2)
        core.cancelTake()
        #expect(listener.cancelled)
        // A new take replaces a listener the last one never handed over.
        let next = CountingListener(), after = CountingListener()
        core.beginTake(silenceMs: 2_000, words: next)
        core.beginTake(silenceMs: 2_000, words: after)
        #expect(next.cancelled)
        #expect(!after.cancelled)
    }

    @Test func aBargeInIsHeardFromItsPreRollOnAndTheUtteranceCarriesIt() {
        let (core, events, folder) = make()
        defer { try? FileManager.default.removeItem(at: folder) }
        core.armBarge(multiplier: nil, silenceMs: 250)
        feed(core, value: 0, buffers: 25)          // calibrates the quiet floor
        feed(core, value: 8_000, buffers: 30)      // sustained speech trips the monitor
        #expect(events.withLock { $0.contains(.bargeSpeech) })
        let listener = CountingListener()
        core.hearUtterance(listener)               // the controller hands one over after `.bargeSpeech`
        let backlog = listener.samples.count
        #expect(backlog > 0)
        feed(core, value: 7_000, buffers: 5)
        #expect(listener.samples.count == backlog + 5 * 341)
        var quiet = 0
        while !events.withLock({ $0.contains { if case .bargeUtterance = $0 { return true } else { return false } } }), quiet < 200 {
            feed(core, value: 0, buffers: 1)
            quiet += 1
        }
        guard case .bargeUtterance(let take?)? = events.withLock({ $0.last }) else {
            Issue.record("no utterance ended")
            return
        }
        #expect(take.words === listener)
        // Nothing being recorded: a late listener is let go at once.
        let late = CountingListener()
        core.hearUtterance(late)
        #expect(late.cancelled)
    }
}

@Suite("Live Words in Talk", .serialized)
@MainActor
struct LiveWordsTalkTests {
    @Test func theTakesOwnWordsGoOutWithoutTheGatewayAndShowWhileSpoken() async throws {
        AudioSessionCoordinator.shared.reset()
        KeepAwake.reset()
        FixtureTalkCapture.script = TalkFixtureStep.parse("say:0.6;hold")
        FixtureTalkCapture.permission = "granted"
        FixtureTalkCapture.startDelay = 0.02
        let talk = TalkController()
        var config = TalkConfig()
        config.silenceMs = 300
        var gatewayAsked = 0
        talk.makeCapture = { FixtureTalkCapture(clock: $0) }
        talk.speaker = FakeSpeaker()
        talk.loadConfig = { _ in config }
        talk.transcribe = { _, _ in
            gatewayAsked += 1
            return .success("from the gateway")
        }
        talk.makeWords = { ScriptedLiveWords(script: "What is on my calendar tomorrow", onText: $0) }
        talk.holdsLeases = false
        talk.isOnScreen = { true }
        talk.speaksReplies = { true }
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        // The words show while the person speaks…
        #expect(await waitUntil(timeout: .seconds(4)) { !talk.words(in: chat).isEmpty })
        // …go out as the turn, without the gateway's speech to text, and leave the card.
        #expect(await waitUntil(timeout: .seconds(6)) { chat.sent.count == 1 })
        #expect(chat.sent.first?.text == "What is on my calendar tomorrow")
        #expect(gatewayAsked == 0)
        #expect(talk.words(in: chat).isEmpty)
        talk.end()
        #expect(await waitUntil { !talk.isLive })
        await talk.resetForTests()
    }

    @Test func noWordsHeardFallsBackToTheGateway() async throws {
        AudioSessionCoordinator.shared.reset()
        KeepAwake.reset()
        FixtureTalkCapture.script = TalkFixtureStep.parse("say:0.6;hold")
        FixtureTalkCapture.permission = "granted"
        FixtureTalkCapture.startDelay = 0.02
        let talk = TalkController()
        var config = TalkConfig()
        config.silenceMs = 300
        var gatewayAsked = 0
        talk.makeCapture = { FixtureTalkCapture(clock: $0) }
        talk.speaker = FakeSpeaker()
        talk.loadConfig = { _ in config }
        talk.transcribe = { _, _ in
            gatewayAsked += 1
            return .success("from the gateway")
        }
        talk.makeWords = { _ in CountingListener(words: "") }
        talk.holdsLeases = false
        talk.isOnScreen = { true }
        talk.speaksReplies = { true }
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil(timeout: .seconds(6)) { chat.sent.count == 1 })
        #expect(chat.sent.first?.text == "from the gateway")
        #expect(gatewayAsked == 1)
        talk.end()
        #expect(await waitUntil { !talk.isLive })
        await talk.resetForTests()
    }
}

@Suite("Live Words in memos", .serialized)
@MainActor
struct LiveWordsMemoTests {
    @Test func aMemoCarriesWhatWasHeardAndTheWordsShowWhileRecording() async throws {
        let accountId = "words-\(UUID().uuidString)"
        VoiceTestStores.activate(accountId)
        let file = try VoiceTestStores.recording(accountId, seconds: 3)
        let capture = FakeCapture(file: file)
        let controller = MemoController(capture: capture)
        controller.tapsMicrophone = false
        controller.makeWords = { ScriptedLiveWords(script: "Remind me to call the dentist", onText: $0) }
        let target = MemoTarget(scope: "acct|ivy|\(UUID().uuidString)", host: nil, session: nil, botName: "Ivy",
                                accountKey: MemoPaths.accountKey(accountId))
        controller.memoDown(target, width: 402)
        #expect(await waitUntil { controller.state.phase == .holding })
        #expect(await waitUntil(timeout: .seconds(3)) { !controller.words.isEmpty })
        controller.input(.up(at: CACurrentMediaTime() * 1000 + 5000))
        #expect(await waitUntil { controller.state.phase == .idle })
        // The chat is gone (no host), so the memo waits as a draft: with its words.
        let draft = try #require(MemoAccountStores.shared.drafts?.draft(for: target.scope))
        #expect(draft.words == "Remind me to call the dentist")
        #expect(controller.words.isEmpty)
    }

    @Test func aCancelledTakeLetsItsListenerGo() async throws {
        let accountId = "words-\(UUID().uuidString)"
        VoiceTestStores.activate(accountId)
        let capture = FakeCapture(file: try VoiceTestStores.recording(accountId, seconds: 3))
        let controller = MemoController(capture: capture)
        controller.tapsMicrophone = false
        let listener = CountingListener(words: "never sent")
        controller.makeWords = { _ in listener }
        let target = MemoTarget(scope: "acct|ivy|\(UUID().uuidString)", host: nil, session: nil, botName: "Ivy",
                                accountKey: MemoPaths.accountKey(accountId))
        controller.memoDown(target, width: 402)
        #expect(await waitUntil { controller.state.phase == .holding })
        controller.input(.move(dx: -200, dy: 0))   // slid to cancel
        controller.input(.up(at: CACurrentMediaTime() * 1000 + 5000))
        #expect(await waitUntil { controller.state.phase == .idle })
        #expect(listener.cancelled)
        #expect(!listener.finished)
    }
}

@Suite("Live Words on the wire", .serialized)
@MainActor
struct LiveWordsUploadTests {
    @Test func wordsHeardHereAreTheTranscriptAndNothingIsTranscribed() async throws {
        let client = VoiceFakeClient()
        VoiceTestStores.activate(client.account.id)
        var memo = try VoiceTestStores.recording(client.account.id)
        memo.words = "  Remind me to call the dentist "
        let s = LiveChatSession(client: client, account: client.account, profile: "ivy", storedSessionId: "20260929_120000_aabbcc07",
                                title: "Ivy", head: nil, cache: makeTempCache(), resolveSessionId: nil, frameMode: .manual)
        s.start()
        _ = await waitUntil(timeout: .seconds(5)) { s.openSettled }
        s.sendMemo(memo, text: "")
        #expect(await waitUntil(timeout: .seconds(5)) { client.entries("rpc prompt.submit").count == 1 })
        #expect(client.entries("POST /api/audio/transcribe").isEmpty)
        let text = try #require(client.entries("rpc prompt.submit").first?.params?["text"]?.string)
        #expect(text.hasSuffix("Voice memo transcript: Remind me to call the dentist"))
    }

    @Test func aDraftSavedBeforeLiveWordsStillDecodes() throws {
        let old = #"{"path":"/a/b.m4a","seconds":2.5,"peaks":[0.1],"mime":"audio/x-m4a"}"#
        let decoded = try JSONDecoder().decode(MemoFile.self, from: Data(old.utf8))
        #expect(decoded.words == nil)
        #expect(decoded.seconds == 2.5)
    }
}

@Suite("Live Words: where they're drawn")
@MainActor
struct LiveWordsViewTests {
    private func label(_ view: UIView) -> UILabel? {
        if let label = view as? UILabel { return label }
        for sub in view.subviews { if let found = label(sub) { return found } }
        return nil
    }

    private func laidOut(_ view: LiveWordsView, width: CGFloat) {
        view.frame = CGRect(x: 0, y: 0, width: width, height: view.height(for: width))
        view.layoutIfNeeded()
    }

    /// Every line it holds is drawn: a box sized to lines × `font.lineHeight` is a little short and drops its last line
    /// (the first screenshots showed one line of three).
    @Test func theNewestWordsFillWholeLines() throws {
        let view = LiveWordsView()
        view.maxLines = 3
        view.update(LiveWordsText(settled: "Remind me to call the dentist tomorrow morning and book the car in for its service before Friday, then ask Ivy to move my",
                                  pending: "three o’clock"), listening: true)
        laidOut(view, width: 228)
        let height = view.bounds.height
        let label = try #require(label(view))
        let text = try #require(label.attributedText)
        let needs = label.textRect(forBounds: CGRect(x: 0, y: 0, width: label.bounds.width, height: 1_000), limitedToNumberOfLines: 0)
        #expect(needs.height <= view.bounds.height + 0.5, "every line fits: \(needs.height) in \(view.bounds.height)")
        #expect(needs.height > label.font.lineHeight * 2.5, "three lines, not fewer")
        #expect(text.string.contains("… "))
        #expect(text.string.hasSuffix("ask Ivy to move my three o’clock"))
        // Apple's engine keeps a whole sentence unsettled until a pause: the newest words still show.
        view.update(LiveWordsText(settled: "", pending: "Remind me to call the dentist tomorrow morning and book the car in for its service before Friday, then ask Ivy to move my three o’clock"), listening: true)
        laidOut(view, width: 228)
        let unsure = try #require(label.attributedText)
        #expect(unsure.string.contains("… "))
        #expect(unsure.string.hasSuffix("move my three o’clock"))
        // Only the newest two words are lighter.
        let lighter = unsure.attribute(.foregroundColor, at: unsure.length - 1, effectiveRange: nil) as? UIColor
        let ellipsis = (unsure.string as NSString).range(of: "…").location
        let firm = unsure.attribute(.foregroundColor, at: ellipsis, effectiveRange: nil) as? UIColor
        #expect(lighter == ChatPalette.label2 && firm == ChatPalette.label)
        #expect(unsure.attribute(.foregroundColor, at: (unsure.string as NSString).range(of: "my").location, effectiveRange: nil) as? UIColor == ChatPalette.label)
        // A few words: one line, whole.
        view.update(LiveWordsText(settled: "Remind me", pending: "to"), listening: true)
        #expect(view.height(for: 228) < height - label.font.lineHeight * 1.5)
    }

    /// Heard words look heard, not typed: they are in italics (more than a colour), with nothing before them (owner,
    /// 2026-11-01: no waveform).
    @Test func heardWordsAreInItalics() throws {
        let view = LiveWordsView()
        view.baseFont = UIFont.systemFont(ofSize: 17)
        view.update(LiveWordsText(settled: "Book the car in"), listening: false)
        laidOut(view, width: 300)
        let text = try #require(label(view)?.attributedText)
        #expect(text.string == "Book the car in", "the words alone, nothing before them")
        let word = (text.string as NSString).range(of: "Book").location
        let font = try #require(text.attribute(.font, at: word, effectiveRange: nil) as? UIFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.traitItalic))
        #expect(view.accessibilityValue == "Book the car in")
    }

    /// Before the first word, "Listening…" holds the words' place; once nothing listens, an empty view draws nothing.
    @Test func listeningHoldsThePlace() throws {
        let view = LiveWordsView()
        view.update(LiveWordsText(), listening: true)
        laidOut(view, width: 300)
        let label = try #require(label(view))
        #expect(label.attributedText?.string.hasSuffix("Listening…") == true)
        #expect(view.accessibilityValue == "Listening")
        view.update(LiveWordsText(), listening: false)
        laidOut(view, width: 300)
        #expect(label.attributedText?.length ?? 0 == 0)
    }
}

@Suite("Live Words in the composer", .serialized)
@MainActor
struct LiveWordsComposerTests {
    private func hosted(width: CGFloat = 402) -> (UIWindow, ComposerView)? {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return nil }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 874)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        let composer = ComposerView(frame: .zero)
        composer.showsCommands = true
        composer.leadingAccessories = [UIView()]
        root.view.addSubview(composer)
        composer.frame = CGRect(x: 0, y: 700, width: width, height: composer.intrinsicContentSize.height)
        composer.layoutIfNeeded()
        return (window, composer)
    }

    private func settle(_ composer: ComposerView) {
        composer.frame.size.height = composer.intrinsicContentSize.height
        composer.layoutIfNeeded()
    }

    /// The owner, 2026-11-01: while recording the bar grows to the two rows it has for typing, the words where typed
    /// words go. The recorder's row keeps its height and its place at the bottom; the words row goes with the recorder.
    @Test func recordingWithWordsGrowsTheBarToTwoRows() throws {
        guard let (window, composer) = hosted() else { Issue.record("no window scene"); return }
        settle(composer)
        let twoRows = composer.intrinsicContentSize.height   // the iOS look's bar at rest (owner 2026-11-01: always two rows)
        let recorder = UIView()
        composer.recorderContent = recorder
        settle(composer)
        let oneRow = composer.intrinsicContentSize.height
        #expect(abs(oneRow - ChatMetrics.control) < 0.5, "the recorder alone keeps one row")
        #expect(twoRows > oneRow + 20, "the bar was two rows before the recorder took it: \(twoRows)")

        composer.heard = ComposerView.Heard(words: LiveWordsText(), listening: true)
        settle(composer)
        let listening = composer.intrinsicContentSize.height
        #expect(listening > oneRow + 20, "\"Listening…\" opens the words row at once: \(listening)")
        #expect(!composer.heardView.isHidden)
        #expect(abs(recorder.frame.height - ChatMetrics.control) < 0.5, "the recorder's row keeps its height")
        #expect(abs(recorder.frame.maxY - recorder.superview!.bounds.height) < 0.5, "and sits at the bottom")
        #expect(composer.heardView.frame.maxY <= recorder.frame.minY + 0.5, "the words sit above it")

        composer.heard = ComposerView.Heard(words: LiveWordsText(settled: "Remind me to call the dentist tomorrow morning and book the car in for its service before Friday, then ask Ivy to move my three o’clock to Thursday afternoon"), listening: true)
        settle(composer)
        let long = composer.intrinsicContentSize.height
        #expect(long > listening + 20, "more words, more lines")
        let line = composer.textView.font?.lineHeight ?? 20
        #expect(long < listening + line * 3 + 8, "four lines at most")

        // Held: the words keep clear of the lock and the circle, so they wrap sooner.
        let held = composer.heardView.frame
        composer.heardLimitX = composer.bounds.width - 120
        composer.layoutIfNeeded()
        settle(composer)
        #expect(composer.heardView.frame.width < held.width)

        composer.recorderContent = nil
        settle(composer)
        #expect(abs(composer.intrinsicContentSize.height - twoRows) < 0.5, "the recorder gone, the two rows again")
        composer.heard = nil
        _ = window
    }
}
