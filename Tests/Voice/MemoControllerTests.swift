// MemoController against a fake recorder (spec 1x-voice §3.2 effect handling): where a take goes when its chat is
// gone, what a system stop leaves behind, and the simulator fixture recorder's start latency (A-P1).

import Foundation
import QuartzCore
import Testing
import UIKit
@testable import HermesHQNative

@MainActor final class FakeCapture: MemoCapturing {
    var onEvent: ((MemoCaptureEvent) -> Void)?
    var accountKey: String?
    var isRecording = false
    var startLatencyMs: Double? = 4
    let file: MemoFile
    private(set) var ended: [MemoEndAction] = []

    init(file: MemoFile) { self.file = file }

    func begin() async throws -> (id: String, limit: Double) {
        isRecording = true
        return ("take-1", 600)
    }

    func end(id: String, action: MemoEndAction) async throws -> MemoFile? {
        isRecording = false
        ended.append(action)
        return action == .cancel ? nil : file
    }

    func nativeStop(_ reason: MemoStopReason) {
        isRecording = false
        onEvent?(.stopped(reason: reason, id: "take-1", seconds: 12.4, disposition: .draft(file)))
    }
}

@Suite("Memo controller", .serialized)
@MainActor
struct MemoControllerTests {
    private func setUp() throws -> (MemoController, FakeCapture, MemoTarget) {
        let accountId = "controller-\(UUID().uuidString)"
        VoiceTestStores.activate(accountId)
        let file = try VoiceTestStores.recording(accountId, seconds: 3)
        let capture = FakeCapture(file: file)
        let controller = MemoController(capture: capture)
        let target = MemoTarget(scope: "acct|ivy|\(UUID().uuidString)", host: nil, session: nil, botName: "Ivy",
                                accountKey: MemoPaths.accountKey(accountId))
        return (controller, capture, target)
    }

    @Test func aSendWhoseChatIsGoneBecomesADraftWithANotice() async throws {
        let (controller, capture, target) = try setUp()
        controller.memoDown(target, width: 402)
        #expect(await waitUntil { controller.state.phase == .holding })
        controller.input(.up(at: CACurrentMediaTime() * 1000 + 5000))
        #expect(await waitUntil { controller.state.phase == .idle })
        #expect(capture.ended == [.send])
        #expect(MemoAccountStores.shared.drafts?.draft(for: target.scope) == capture.file)
        let notice = try #require(controller.notice(for: target.scope))
        #expect(notice.title == "Memo Saved as a Draft")
        #expect(notice.message == "It didn’t send. It’s waiting in the message field of your chat with Ivy.")
    }

    @Test func aSystemStopLeavesADraftAndSaysWhy() async throws {
        let (controller, capture, target) = try setUp()
        controller.memoDown(target, width: 402)
        #expect(await waitUntil { controller.state.phase == .holding })
        capture.nativeStop(.interrupted)
        #expect(controller.state.phase == .idle)
        #expect(MemoAccountStores.shared.drafts?.draft(for: target.scope) == capture.file)
        let notice = try #require(controller.notice(for: target.scope))
        #expect(notice.title == "Recording Stopped")
        #expect(notice.message == "A call or Siri took the microphone. Your 0:12 memo is waiting in the message field.")
        controller.dismissNotice(scope: target.scope)
        #expect(controller.notice(for: target.scope) == nil)
    }

    @Test func leavingTurnsATakeIntoADraftAndCancelDeletesNothingKept() async throws {
        let (controller, capture, target) = try setUp()
        controller.memoDown(target, width: 402)
        #expect(await waitUntil { controller.state.phase == .holding })
        controller.input(.leave)
        #expect(await waitUntil { controller.state.phase == .idle })
        #expect(capture.ended == [.draft])
        #expect(MemoAccountStores.shared.drafts?.draft(for: target.scope) == capture.file)
        #expect(controller.notice(for: target.scope) == nil, "a draft from leaving says nothing")
        // Slide to cancel: nothing kept.
        controller.memoDown(target, width: 402)
        #expect(await waitUntil { controller.state.phase == .holding })
        controller.input(.move(dx: -200, dy: 0))
        controller.input(.up(at: CACurrentMediaTime() * 1000 + 5000))
        #expect(await waitUntil { controller.state.phase == .idle })
        #expect(capture.ended == [.draft, .cancel])
    }

    /// A locked take past 60 s keeps a live waveform: one new sample per 100 ms, never the whole 600-sample window
    /// refilled with the current level (it went flat, then solid, after about 66 s).
    @Test func longTakeLevelsKeepTheirShape() async throws {
        let (controller, capture, target) = try setUp()
        controller.memoDown(target, width: 402)
        #expect(await waitUntil { controller.state.phase == .holding })
        controller.input(.move(dx: 0, dy: -100))
        #expect(controller.state.phase == .locked)
        var maxGrowth = 0
        for tick in 0...(120 * 15) {
            let seconds = Double(tick) / 15
            let level = 0.5 + 0.4 * sin(seconds * 3.1)
            let before = controller.levels.count
            capture.onEvent?(.level(level, seconds: seconds))
            maxGrowth = max(maxGrowth, controller.levels.count - before)
        }
        #expect(controller.levels.count == 600, "the newest 600 samples (60 s) are kept")
        #expect(maxGrowth <= 2, "a 15 Hz tick adds one or two samples, not a window (\(maxGrowth))")
        let shown = Array(controller.levels.suffix(64))
        #expect(Set(shown.map { ($0 * 100).rounded() }).count > 10, "the visible bars still vary at 2:00")
        // The newest bar is the newest level.
        #expect(abs((controller.levels.last ?? 0) - (0.5 + 0.4 * sin(120 * 3.1))) < 0.001)
        controller.reset()
        #expect(controller.state.phase == .idle)
        #expect(controller.levels.isEmpty)
    }

    @Test func failureNoticesSayWhatHappened() {
        let denied = MemoNotice.failure(code: "permission-denied", message: nil)
        #expect(denied.title == "Microphone Access Is Off")
        #expect(denied.message == "Turn on Microphone for \(MemoNotice.appName) in Settings to record voice memos.")
        #expect(denied.actionTitle == "Open Settings")
        #expect(!denied.copies, "a permission notice has nothing technical to copy")
        #expect(MemoNotice.failure(code: "background", message: nil).message == "Voice memos record while \(MemoNotice.appName) is on screen.")
        let other = MemoNotice.failure(code: "start-failed", message: nil)
        #expect(other.message == "The microphone didn’t start. Try again." && other.actionTitle == "Try Again")
        #expect(other.copies, "a failure offers Copy")
        #expect(MemoNotice.why(.routeLost) == "The headset or microphone disconnected.")
        // An audio session's code is said in words, never shown bare ("iOS error 561017449").
        let held = NSError(domain: NSOSStatusErrorDomain, code: 561_017_449)
        #expect(MemoRecorder.startReason(held) == "a call or another app is using the microphone")
        #expect(MemoBeginError.startFailed(MemoRecorder.startReason(held)).message
                == "Couldn’t start the voice memo: a call or another app is using the microphone.")
        #expect(MemoRecorder.startReason(NSError(domain: NSOSStatusErrorDomain, code: -50)) == "the microphone didn’t start")
        #expect(MemoRecorder.reason(NSError(domain: NSOSStatusErrorDomain, code: 2_003_334_207)) == "")
        #expect(MemoRecorder.reason(MemoRecorder.saveError("the file is empty")) == "the file is empty")
        // A group chat's memo that didn't send says why (a bot chat's failed bubble does).
        let draft = MemoNotice.savedAsDraft(bot: "Team", detail: "Couldn’t send the voice memo. Your gateway ran into a problem (error 500). Try again.")
        #expect(draft.detail == "Couldn’t send the voice memo. Your gateway ran into a problem (error 500). Try again." && draft.draft)
        #expect(MemoNotice.savedAsDraft(bot: "Ivy").detail == nil)
        #expect(GroupRoomSession.memoRefusal(.refused(.noMembers(room: "Team")), room: "Team") == "Team has no members to send to.")
        #expect(GroupRoomSession.memoRefusal(.ignored, room: "Team") == "The group chat closed before it went.")
        #expect(MemoNotice.appName == AppIdentity.current.displayName)   // "Hermes HQ" on every identity
    }

    #if targetEnvironment(simulator)
    /// The simulator fixture records within 120 ms of the touch (start delay 0.08 s) and saves a WAV. Fixture only: it
    /// times the fixture's own path (no microphone, no audio session), so it is not the A-P1 device proof; that is the
    /// "memo start" signpost on a device.
    @Test func fixtureRecorderStartsQuicklyAndSavesAWav() async throws {
        try #require(UIApplication.shared.applicationState == .active, "the test host must be in front for the recorder to start")
        let recorder = MemoRecorder()
        recorder.fixture = MemoRecorder.Fixture(permission: "granted")
        recorder.accountKey = MemoPaths.accountKey("recorder-test")
        _ = VoiceTestStores.base
        let started = try await recorder.begin()
        #expect(started.limit == 600)
        #expect((recorder.startLatencyMs ?? 999) <= 120, "start latency \(recorder.startLatencyMs ?? -1) ms")
        print(String(format: "[MemoTest] fixture recorder start latency %.1f ms", recorder.startLatencyMs ?? -1))
        try await Task.sleep(for: .milliseconds(1200))
        let file = try #require(try await recorder.end(id: started.id, action: .send))
        #expect(file.mime == "audio/wav")
        #expect(file.path.hasSuffix("/voice-memo.wav"))
        #expect(file.peaks.count == 48)
        #expect(file.seconds >= 1.1 && file.seconds < 2)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!recorder.isRecording)
    }
    #endif
}
