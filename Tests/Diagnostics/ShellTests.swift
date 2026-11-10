import Foundation
import Testing
import UIKit
@testable import HermesHQNative

/// Background modes (parity L1025, docs/spec/3x-diagnostics.md §14, acceptance G1). The unit tests are hosted by the
/// built app, so `Bundle.main` is the app's own bundle: run under both identities
/// (`scripts/diagnostics-unit.sh <udid>` and `HQ_IDENTITY=original scripts/diagnostics-unit.sh <udid>`).
@Suite struct BackgroundModesTests {
    /// [talk-background] `audio` keeps a live voice conversation going with the app away (docs/spec/3x-talk-background.md).
    @Test func theBackgroundModesAreAudioAndRemoteNotification() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        #expect(modes == ["audio", "remote-notification"])
    }

    @Test func noBackgroundTaskSchedulerIdentifiers() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") == nil)
    }

    @Test func theHostIsTheApp() {
        #expect(Bundle.main.bundleURL.pathExtension == "app")
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String != nil)
    }

    /// Every background task in the app goes through `BackgroundTime` or the socket's own holder: both end the task
    /// in the expiration handler. A bare `beginBackgroundTask` call anywhere else would be one that can outlive its time.
    @Test func everyBackgroundTaskHasAnOwnerThatEndsIt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var bare: [String] = []
        for folder in ["App", "HermesKit"] {
            let files = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            while let file = files?.nextObject() as? URL {
                guard file.pathExtension == "swift", let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for (index, line) in text.components(separatedBy: "\n").enumerated()
                where line.contains("beginBackgroundTask(") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                    bare.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        try #require(!bare.isEmpty, "the source tree was not found at \(root.path)")
        #expect(bare.allSatisfy { $0.hasPrefix("AttachmentCenter.swift:") || $0.hasPrefix("LiveGatewayClient.swift:") }, "\(bare)")
    }
}

/// Power saver (parity L974 / L1015, §11, acceptance P1).
@Suite struct PowerRuleTests {
    @Test func savingIsLowPowerOrAHotPhone() {
        for lowPower in [false, true] {
            for (thermal, hot) in [(ProcessInfo.ThermalState.nominal, false), (.fair, false), (.serious, true), (.critical, true)] {
                #expect(PowerState.saving(lowPower: lowPower, thermal: thermal) == (lowPower || hot))
            }
        }
    }

    @Test func thermalWords() {
        #expect(PowerState.thermalWord(.nominal) == "nominal")
        #expect(PowerState.thermalWord(.fair) == "fair")
        #expect(PowerState.thermalWord(.serious) == "serious")
        #expect(PowerState.thermalWord(.critical) == "critical")
    }

    @Test func oneEventPerRealChange() {
        nonisolated final class Seen: @unchecked Sendable { nonisolated(unsafe) var events: [(PowerState.PowerDetail, Bool)] = [] }
        let seen = Seen()
        let log = PowerLog { detail, saving in seen.events.append((detail, saving)) }
        let cool = PowerState.PowerDetail(lowPower: false, thermal: "nominal")
        #expect(log.note(cool, saving: false), "the launch's reading is recorded")
        #expect(!log.note(cool, saving: false), "a re-read that changed nothing records nothing")
        #expect(log.note(.init(lowPower: false, thermal: "fair"), saving: false), "fair is a change though saving is not")
        #expect(log.note(.init(lowPower: false, thermal: "serious"), saving: true))
        #expect(!log.note(.init(lowPower: false, thermal: "serious"), saving: true))
        #expect(log.note(.init(lowPower: true, thermal: "serious"), saving: true))
        #expect(log.note(cool, saving: true), "the DEBUG override flips saving with the readings unchanged")
        #expect(seen.events.count == 5 && log.events == 5)
        #expect(seen.events.map(\.1) == [false, false, true, true, true])
    }
}

/// Memory trim (parity L975, §12, acceptance M1).
@Suite(.serialized) struct MemoryTrimTests {
    @Test func everyRegisteredTrimRunsAndTheCountIsKept() {
        MemoryTrim.resetForTests()
        MemoryTrim.register("a") { reason in reason == .pressure ? 3 : 1 }
        MemoryTrim.register("b") { _ in 0 }
        MemoryTrim.register("c") { _ in 2 }
        #expect(MemoryTrim.runNow(.pressure) == 5)
        #expect(MemoryTrim.runNow(.background) == 3)
        #expect(MemoryTrim.runs == 2 && MemoryTrim.lastDropped == 3)
        MemoryTrim.register("a") { _ in 10 }
        #expect(MemoryTrim.runNow(.pressure) == 12, "a second registration under a name replaces the first")
        MemoryTrim.resetForTests()
    }

    /// The pressure source runs its handler on its own queue, not the main thread (build 315 crash: the handler was
    /// main-actor isolated and the first pressure signal stopped the app).
    @Test func pressureHandlerRunsOffTheMainThread() {
        MemoryTrim.resetForTests()
        MemoryTrim.register("a") { _ in 1 }
        DispatchQueue(label: "test.memory-pressure").sync { MemoryTrim.pressureHandler() }
        #expect(MemoryTrim.runs == 1 && MemoryTrim.lastDropped == 1)
        MemoryTrim.resetForTests()
    }

    /// [diagnostics] The memory warning and the pressure source report the same event: one trim, not two.
    @Test func onePressureEventTrimsOnce() {
        MemoryTrim.resetForTests()
        MemoryTrim.register("a") { _ in 1 }
        #expect(MemoryTrim.pressureSignal(now: 100))
        #expect(!MemoryTrim.pressureSignal(now: 100.2), "the second trigger of the same event")
        #expect(MemoryTrim.runs == 1)
        #expect(MemoryTrim.pressureSignal(now: 102), "a later event trims again")
        #expect(MemoryTrim.runs == 2)
        MemoryTrim.resetForTests()
    }

    /// [perf] The background trim waits; a return before it runs calls it off, and only the latest trip away counts.
    @Test func theBackgroundTrimWaitsAndAReturnCallsItOff() async throws {
        MemoryTrim.resetForTests()
        MemoryTrim.backgroundDelay = .milliseconds(50)
        MemoryTrim.register("a") { _ in 1 }
        MemoryTrim.scheduleBackground()
        #expect(MemoryTrim.runs == 0, "nothing at once")
        try await Task.sleep(for: .milliseconds(200))
        MemoryTrim.settle()
        #expect(MemoryTrim.runs == 1)

        MemoryTrim.scheduleBackground()
        MemoryTrim.cancelBackground()
        try await Task.sleep(for: .milliseconds(200))
        MemoryTrim.settle()
        #expect(MemoryTrim.runs == 1, "a return within the delay calls it off")

        MemoryTrim.scheduleBackground()
        MemoryTrim.scheduleBackground()
        try await Task.sleep(for: .milliseconds(200))
        MemoryTrim.settle()
        #expect(MemoryTrim.runs == 2, "two trips away in a row trim once")
        MemoryTrim.resetForTests()
    }

    /// A background trim that fires well after its time (the app was suspended and is thawing) does not run: the
    /// return is the moment it must not take, and willEnterForeground is not ordered ahead of it. Here the trim queue
    /// is held past the deadline instead.
    @Test func aBackgroundTrimThatFiresLateDoesNotRun() async throws {
        MemoryTrim.resetForTests()
        MemoryTrim.backgroundDelay = .milliseconds(50)
        MemoryTrim.register("a") { reason in
            if reason == .pressure { Thread.sleep(forTimeInterval: 2.6) }
            return 1
        }
        MemoryTrim.scheduleBackground()
        MemoryTrim.run(.pressure)   // holds the queue past the background trim's time
        try await Task.sleep(for: .seconds(3))
        MemoryTrim.settle()
        #expect(MemoryTrim.runs == 1, "only the pressure trim ran")
        MemoryTrim.resetForTests()
    }

    private func cache(_ name: String) -> TranscriptCache {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diag-trim-\(name)-\(UUID().uuidString)", isDirectory: true)
        return TranscriptCache(root: root)
    }

    private func fill(_ cache: TranscriptCache, chats: Int, characters: Int = 200) {
        for index in 0..<chats {
            let message = ChatMessage(id: "stored-row-\(index)-assistant", role: .assistant, parts: [.text(String(repeating: "x", count: characters))],
                                      timestamp: Date(), rowId: index + 1)
            cache.save([message], meta: [:], account: "acct", profile: "default", storedId: "chat-\(index)")
        }
        cache.flush()   // nothing is waiting to be written any more
    }

    @Test func pressureKeepsOnlyTheChatOnShow() {
        let cache = cache("pressure")
        fill(cache, chats: 8)
        #expect(cache.memoryCount == 8)
        cache.setVisible(TranscriptCache.key(account: "acct", profile: "default", storedId: "chat-2"))
        #expect(cache.trimMemory() == 7)
        #expect(cache.memoryCount == 1)
        #expect(cache.load(account: "acct", profile: "default", storedId: "chat-5")?.count == 1, "a trimmed chat still opens from disk")
    }

    @Test func backgroundKeepsTheFourNewestBesideTheChatOnShow() {
        let cache = cache("background")
        fill(cache, chats: 8)
        cache.setVisible(TranscriptCache.key(account: "acct", profile: "default", storedId: "chat-0"))
        #expect(cache.trimMemory(keeping: 4, bytes: 4 << 20) == 3)
        #expect(cache.memoryCount == 5, "the chat on show is outside the four")
        #expect(cache.trimMemory(keeping: 4, bytes: 4 << 20) == 0, "a second trim finds nothing more")
    }

    @Test func backgroundAlsoHoldsToTheByteLimit() {
        let cache = cache("bytes")
        fill(cache, chats: 6, characters: 20_000)
        // Each file is a little over 20 KB, taken as three times that decoded: 150 KB holds two of them.
        #expect(cache.trimMemory(keeping: 4, bytes: 150_000) == 4)
        #expect(cache.memoryCount == 2)
    }

    @Test func whatIsWaitingToBeWrittenIsNeverDropped() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diag-trim-pending-\(UUID().uuidString)", isDirectory: true)
        var limits = TranscriptCache.Limits()
        limits.writeDelay = .seconds(30)
        let cache = TranscriptCache(root: root, limits: limits)
        let message = ChatMessage(id: "stored-row-1-assistant", role: .assistant, parts: [.text("hi")], timestamp: Date(), rowId: 1)
        cache.save([message], meta: [:], account: "acct", profile: "default", storedId: "chat-a")
        #expect(cache.trimMemory() == 0)
        #expect(cache.trimMemory(keeping: 0, bytes: 0) == 0)
        #expect(cache.memoryCount == 1)
    }
}

/// §10: intervals are begun and ended by name, and an end with nothing open does nothing.
@Suite(.serialized) struct SignpostTests {
    @Test func theSubsystemIsTheRunningAppsBundleId() {
        #expect(Signposts.subsystem == Bundle.main.bundleIdentifier)
        #expect(!Signposts.subsystem.isEmpty)
    }

    @Test func anIntervalEndsOnceAndOnlyWhenOpen() {
        let before = Signposts.posted()
        #expect(!Signposts.end(.session, "TestStep"), "nothing open: nothing ends")
        Signposts.begin(.session, "TestStep", detail: "unit")
        #expect(Signposts.isOpen(.session, "TestStep"))
        #expect(Signposts.end(.session, "TestStep", outcome: "ok"))
        #expect(!Signposts.end(.session, "TestStep"))
        #expect(!Signposts.isOpen(.session, "TestStep"))
        let after = Signposts.posted()
        #expect((after["begin Session.TestStep"] ?? 0) - (before["begin Session.TestStep"] ?? 0) == 1)
        #expect((after["end Session.TestStep"] ?? 0) - (before["end Session.TestStep"] ?? 0) == 1)
    }

    @Test func theHostAppPostedItsLaunchInterval() {
        // The unit tests run inside the app: its own launch began the interval before any test ran.
        #expect((Signposts.posted()["begin Launch.Launch"] ?? 0) == 1)
    }

    @Test func voiceSignpostsUseTheAppsOwnSubsystem() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["HermesKit/Voice/MemoRecorder.swift", "HermesKit/Voice/TalkCapture.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            #expect(!source.contains("subsystem: \"com.charlesmcdowell"), "\(path) names no fixed bundle id")
        }
    }
}

/// §8.4 `main.hang`: a late answer is a stall; an unanswered question is reported once, at two seconds.
@Suite struct HangWatchTests {
    nonisolated final class Seen: @unchecked Sendable {
        nonisolated(unsafe) var reports: [HangJudge.Report] = []
        nonisolated(unsafe) var pending: [@Sendable () -> Void] = []
    }

    @Test func theRule() {
        #expect(HangJudge.answered(after: 0.01) == nil)
        #expect(HangJudge.answered(after: 0.249) == nil)
        #expect(HangJudge.answered(after: 0.25) == .init(ms: 250, ongoing: false))
        #expect(HangJudge.answered(after: 3.2) == .init(ms: 3200, ongoing: false))
        #expect(HangJudge.waiting(1.9, reported: false) == nil)
        #expect(HangJudge.waiting(2.0, reported: false) == .init(ms: 2000, ongoing: true))
        #expect(HangJudge.waiting(5, reported: true) == nil)
    }

    @Test func aPromptAnswerIsNoStallAndALateOneIsOne() {
        let seen = Seen()
        let watch = HangWatch { seen.reports.append($0) }
        let start = Date(timeIntervalSince1970: 100)
        watch.tick(now: start) { seen.pending.append($0) }
        #expect(seen.pending.count == 1)
        watch.answered(asked: start, now: start.addingTimeInterval(0.02))
        #expect(seen.reports.isEmpty && watch.stalls == 0)

        let second = start.addingTimeInterval(0.1)
        watch.tick(now: second) { seen.pending.append($0) }
        for step in 1...5 { watch.tick(now: second.addingTimeInterval(Double(step) * 0.1)) { seen.pending.append($0) } }   // still waiting: no second question
        #expect(seen.pending.count == 2)
        watch.answered(asked: second, now: second.addingTimeInterval(0.6))
        #expect(seen.reports == [.init(ms: 600, ongoing: false)] && watch.stalls == 1 && watch.hangs == 0)
        watch.answered(asked: second, now: second.addingTimeInterval(0.9))
        #expect(seen.reports.count == 1, "an answer counts once")
    }

    @Test func anUnansweredQuestionIsReportedOnceThenItsFullLength() {
        let seen = Seen()
        let watch = HangWatch { seen.reports.append($0) }
        let start = Date(timeIntervalSince1970: 500)
        watch.tick(now: start) { seen.pending.append($0) }
        for step in 1...42 { watch.tick(now: start.addingTimeInterval(Double(step) * 0.1)) { seen.pending.append($0) } }
        #expect(seen.reports == [.init(ms: 2000, ongoing: true)] && watch.hangs == 1)
        #expect(seen.pending.count == 1)
        watch.answered(asked: start, now: start.addingTimeInterval(4.3))
        #expect(seen.reports == [.init(ms: 2000, ongoing: true), .init(ms: 4300, ongoing: false)])
        watch.tick(now: start.addingTimeInterval(4.4)) { seen.pending.append($0) }
        #expect(seen.pending.count == 2, "it asks again afterwards")
    }

    /// [mac] A late answer while the timer itself was held back (App Nap, a hidden window) is no stall: the timer
    /// turns every 0.1 s through a real main-thread stall.
    @Test func aLateAnswerWhileTheTimerWasThrottledIsNoStall() {
        let seen = Seen()
        let watch = HangWatch { seen.reports.append($0) }
        let start = Date(timeIntervalSince1970: 900)
        watch.tick(now: start) { seen.pending.append($0) }
        watch.answered(asked: start, now: start.addingTimeInterval(1.3))      // no turn of the timer in between
        #expect(seen.reports.isEmpty && watch.stalls == 0 && watch.throttled == 1)

        let later = start.addingTimeInterval(1.4)
        watch.tick(now: later) { seen.pending.append($0) }
        watch.tick(now: later.addingTimeInterval(1.6)) { seen.pending.append($0) }   // the timer came 1.6 s late
        #expect(watch.throttled == 2 && seen.reports.isEmpty)
        watch.answered(asked: later, now: later.addingTimeInterval(1.61))
        #expect(seen.reports.isEmpty, "the question it dropped counts nothing")
        #expect(seen.pending.count == 3, "and it asks afresh")
    }

    @Test func theScreenNameIsItsFixedWordsOnly() {
        let timeline = DiagnosticsTimeline(processStart: Date(), kept: nil)
        #expect(timeline.screenName == "")
        timeline.record(category: "screen", message: "open chat (3 messages)")
        #expect(timeline.screenName == "open chat")
        timeline.record(category: "screen", message: "tab 0: SessionsViewController")
        #expect(timeline.screenName == "tab 0")
    }
}

/// §7: the web app's renderer-crash-report.test.ts cases in native words.
@Suite struct ScreenFaultTests {
    @Test func oneBoundedRedactedLine() {
        #expect(ScreenFault.entry(screen: "jobs", message: "list did not decode:\n  missing  key", path: ["JobsViewController", "JobRowView"])
                == "Screen problem in jobs: list did not decode: missing key · at JobsViewController › JobRowView")
        #expect(ScreenFault.entry(screen: "  ", message: "", path: []) == "Screen problem in unlabeled: Unknown error")
        #expect(ScreenFault.entry(screen: nil, message: nil) == "Screen problem in unlabeled: Unknown error")
        let long = ScreenFault.entry(screen: String(repeating: "s", count: 90), message: String(repeating: "m", count: 900))
        #expect(long == "Screen problem in " + String(repeating: "s", count: 60) + ": " + String(repeating: "m", count: 400))
        let secret = ScreenFault.entry(screen: "chat", message: "GET https://h.example/x?ticket=FAKE-private-value failed password=FAKE-private-value")
        #expect(!secret.contains("FAKE-private-value") && secret.contains("[redacted]"))
    }

    @Test func thePathIsNamesOnlyAtMostSix() {
        #expect(ScreenFault.path(["A", "B.C", "has space", "http://x/y.swift:12", "", "_d", "$e", "F", "G", "H"]) == "A › B.C › _d › $e › F › G")
        #expect(ScreenFault.path([]) == "")
    }

    @Test func theSameProblemWithinFiveSecondsIsOneEntryWhateverTheScreen() {
        let recent = ScreenFault.Recent()
        let start = Date(timeIntervalSince1970: 1000)
        let a = ScreenFault.entry(screen: "jobs", message: "boom", path: ["A"])
        let b = ScreenFault.entry(screen: "unlabeled", message: "boom", path: ["A"])
        #expect(ScreenFault.key(a) == "boom · at A" && ScreenFault.key(a) == ScreenFault.key(b))
        #expect(recent.admit(a, now: start))
        #expect(!recent.admit(b, now: start.addingTimeInterval(1)))
        #expect(!recent.admit(a, now: start.addingTimeInterval(4.9)))
        #expect(recent.admit(a, now: start.addingTimeInterval(5.1)), "a later one is a new entry")
        #expect(recent.admit(ScreenFault.entry(screen: "jobs", message: "other"), now: start.addingTimeInterval(5.2)))
    }

    @Test func oldKeysArePrunedPastFifty() {
        let recent = ScreenFault.Recent()
        let start = Date(timeIntervalSince1970: 2000)
        for index in 0..<50 { _ = recent.admit("Screen problem in x: e\(index)", now: start) }
        #expect(recent.count == 50)
        _ = recent.admit("Screen problem in x: late", now: start.addingTimeInterval(6))
        #expect(recent.count == 1, "everything older than the window goes once there are more than fifty")
    }

    @Test func aSavedChatThatCannotBeReadIsReportedAndStillOpensEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diag-fault-\(UUID().uuidString)", isDirectory: true)
        let cache = TranscriptCache(root: root)
        let message = ChatMessage(id: "stored-row-1-assistant", role: .assistant, parts: [.text("hello")], timestamp: Date(), rowId: 1)
        cache.save([message], meta: [:], account: "acct", profile: "default", storedId: "chat-x")
        cache.flush()
        _ = cache.trimMemory(keeping: 0, bytes: 0)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath && $0.lastPathComponent != "index.json" } ?? []
        let file = try #require(files.first { ((try? Data(contentsOf: $0))?.count ?? 0) > 12 })
        try Data(repeating: 0x7b, count: 64).write(to: file)
        let before = DiagnosticsTimeline.shared.recentErrors(limit: 50).first { $0.message.hasPrefix("Screen problem in chat: saved chat could not be read") }?.count ?? 0
        #expect(cache.load(account: "acct", profile: "default", storedId: "chat-x") == nil)
        let after = DiagnosticsTimeline.shared.recentErrors(limit: 50).first { $0.message.hasPrefix("Screen problem in chat: saved chat could not be read") }
        #expect(after?.message == "Screen problem in chat: saved chat could not be read (64 bytes) · at TranscriptCache")
        #expect((after?.count ?? 0) - before <= 1)
    }
}
