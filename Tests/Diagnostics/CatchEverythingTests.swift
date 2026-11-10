// The log's Oct 29 gaps (owner: "i want to be able to catch everything so that we can fix everything"): the Mac's own
// frames kept in crash records and the crash's message sent with them, the main thread's stack sampled during a
// stall, the system's errors folded into lines, sheets and alerts named.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@Suite struct CrashRecordEventTests {
    private func decoded(_ lines: [String]) -> [[String: Any]] {
        lines.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }

    /// [mac] backtrace_symbols pads the binary's name, which on the Mac has a space in it.
    @Test func aMacSignalRecordKeepsTheAppsFramesItsBuildAndItsMessage() {
        let text = """
        Fatal signal in Hermes HQ 1.0 (447)
        App image header 0x10447c000, slide 0x447c000
        Backtrace of the thread that died:
        signal
        0   libsystem_platform.dylib            0x0000000181c497a4 _sigtramp + 56
        1   Hermes HQ                           0x0000000104a8c123 $s14HermesHQNative4ChatC4openyyF + 40
        2   UIKitCore                           0x00000001ba4fb634 -[UICollectionView _setNeedsVisibleCellsUpdate:withLayoutAttributes:] + 400
        Crash message (libswiftCore.dylib): Swift/ContiguousArrayBuffer.swift:690: Fatal error: Index out of range |
        """
        let events = decoded(LogUploader.recordEvents(text, exception: false, rec: "20261029-073055", date: Date()))
        #expect(events.first?["k"] as? String == "crash.sig" && events.first?["bld"] as? String == "447")
        let frames = events.filter { $0["k"] as? String == "crash.frame" }.compactMap { $0["f"] as? String }
        #expect(frames.count == 3)
        #expect(frames.contains { $0.hasPrefix("1 Hermes HQ 0x0000000104a8c123") })
        let why = events.first { $0["k"] as? String == "crash.why" }
        #expect(why?["lib"] as? String == "libswiftCore.dylib")
        #expect(why?["why"] as? String == "Swift/ContiguousArrayBuffer.swift:690: Fatal error: Index out of range")
    }

    @Test func anExceptionRecordCarriesItsBuild() {
        let text = "Uncaught exception\nName: NSRangeException\nReason: HQCrashTest\nThread: background\nBuild: 455\n\nStack:\n0   CoreFoundation                      0x00000001804e8ba4 __exceptionPreprocess + 176\n"
        let events = decoded(LogUploader.recordEvents(text, exception: true, rec: "r", date: Date()))
        #expect(events.first?["k"] as? String == "crash.exc" && events.first?["bld"] as? String == "455")
        #expect(events.contains { $0["k"] as? String == "crash.frame" })
    }

    /// The crash-info sections are found at launch (the test host's own CrashCapture.install ran them), and none
    /// holds a message while nothing is crashing.
    @Test func theCrashMessageSectionsAreFound() {
        CrashMessages.install()
        #expect(CrashMessages.libraries.contains("libswiftCore.dylib"))
        #expect(CrashMessages.current().isEmpty, "\(CrashMessages.current())")
    }

    @Test func whereTheMacAppRunsFromNamesNoFolder() {
        #expect(CrashCapture.location("/Applications/Hermes HQ.app") == "from Applications")
        #expect(CrashCapture.location("/private/var/folders/x/AppTranslocation/ABC/d/Hermes HQ.app").hasPrefix("translocated"))
        #expect(CrashCapture.location("/Volumes/Hermes HQ/Hermes HQ.app") == "from a disk image")
        #expect(CrashCapture.location("/Users/someone/Applications/Hermes HQ.app") == "from your own Applications folder")
        #expect(CrashCapture.location("/Users/someone/p/build/dd-mac/Build/Products/Debug-maccatalyst/Hermes HQ.app") == "a development build")
        #expect(!CrashCapture.location("/Users/someone/Downloads/Hermes HQ.app").contains("someone"))
    }
}

@Suite struct HangStackTests {
    nonisolated final class Seen: @unchecked Sendable {
        nonisolated(unsafe) var reports: [HangJudge.Report] = []
        nonisolated(unsafe) var samples = 0
    }

    @Test func theSampleRule() {
        #expect(!HangJudge.sampleDue(0.3, taken: 0))
        #expect(HangJudge.sampleDue(0.35, taken: 0))
        #expect(!HangJudge.sampleDue(1.4, taken: 1))
        #expect(HangJudge.sampleDue(1.5, taken: 1))
        #expect(!HangJudge.sampleDue(3, taken: 2))
    }

    @Test func aStallCarriesTheStackSampledWhileItLasted() {
        let seen = Seen()
        let watch = HangWatch(record: { seen.reports.append($0) }, sample: { seen.samples += 1; return [0x1000, 0x2000] })
        let start = Date(timeIntervalSinceReferenceDate: 0)
        watch.tick(now: start) { _ in }
        for step in 1...5 { watch.tick(now: start.addingTimeInterval(Double(step) * 0.1)) { _ in } }
        #expect(seen.samples == 1, "one sample past 0.35 s, none again before 1.5 s")
        watch.answered(asked: start, now: start.addingTimeInterval(0.6))
        #expect(seen.reports == [.init(ms: 600, ongoing: false, stacks: [[0x1000, 0x2000]])])

        // A prompt answer samples nothing.
        let next = start.addingTimeInterval(1)
        watch.tick(now: next) { _ in }
        watch.answered(asked: next, now: next.addingTimeInterval(0.05))
        #expect(seen.samples == 1 && seen.reports.count == 1)
    }

    @Test func aLongStallSamplesTwiceAndTheOngoingReportTakesBoth() {
        let seen = Seen()
        let watch = HangWatch(record: { seen.reports.append($0) }, sample: { seen.samples += 1; return [UInt(seen.samples)] })
        let start = Date(timeIntervalSinceReferenceDate: 0)
        watch.tick(now: start) { _ in }
        for step in 1...21 { watch.tick(now: start.addingTimeInterval(Double(step) * 0.1)) { _ in } }
        #expect(seen.samples == 2)
        #expect(seen.reports == [.init(ms: 2000, ongoing: true, stacks: [[1], [2]])])
        watch.answered(asked: start, now: start.addingTimeInterval(2.2))
        #expect(seen.reports.last == .init(ms: 2200, ongoing: false), "its stacks went with the ongoing report")
    }

    /// The real sampler, from another thread, while the main thread waits in its run loop.
    @MainActor @Test func theMainThreadsStackCanBeRead() async {
        MainStack.install()
        let addresses = await Task.detached { MainStack.sample() }.value
        let frames = MainStack.frames(addresses ?? [])
        #expect(frames.count >= 4)
        #expect(frames.contains { $0.binary == "CoreFoundation" || $0.binary.hasPrefix("libsystem_kernel") })
        #expect(MainStack.sample() == nil, "the main thread never stops itself")
    }
}

@Suite struct SystemLogLinesTests {
    @Test func repeatsFoldAndTheReadIsCapped() {
        let entry = SystemLog.Entry(subsystem: "com.apple.UIKit", category: "Presentation", fault: false,
                                    message: "Attempt to present <X: 0x1> which is already presenting")
        let fault = SystemLog.Entry(subsystem: "", category: "", fault: true, message: "line one\nline two")
        let lines = SystemLog.lines([entry, fault, entry, entry])
        #expect(lines == ["com.apple.UIKit/Presentation error: Attempt to present <X: 0x1> which is already presenting (×3)",
                          "(no subsystem) fault: line one ⏎ line two"])
        let many = (0..<50).map { SystemLog.Entry(subsystem: "s", category: "c", fault: false, message: "m" + String(repeating: "x", count: $0)) }
        let capped = SystemLog.lines(many)
        #expect(capped.count == SystemLog.perRead + 1 && capped.last == "10 more different system errors in this read")
    }

    @Test func numbersAsideOneMessageIsOneLineAndEchoesAreLeftOut() {
        let refused = (1...4).map { SystemLog.Entry(subsystem: "com.apple.CFNetwork", category: "Default", fault: false,
                                                     message: "Connection \($0): failed to connect 1:61, reason -1") }
        let echo = SystemLog.Entry(subsystem: "com.apple.network", category: "connection", fault: false,
                                   message: "nw_connection_copy_connected_local_endpoint_block_invoke [C3] Client called nw_connection_copy_connected_local_endpoint on unconnected nw_connection")
        let accessibility = SystemLog.Entry(subsystem: "com.apple.Accessibility", category: "AXLoading", fault: false, message: "Failed to load item")
        #expect(SystemLog.lines(refused + [echo, accessibility]) == ["com.apple.CFNetwork/Default error: Connection 1: failed to connect 1:61, reason -1 (×4)"])
        let tagged = ["0x600001a2c000", "0x600001b3d100"].map { SystemLog.Entry(subsystem: "com.apple.CFNetwork", category: "Default", fault: false,
                                                                                 message: "Task finished with error UserInfo={NSUnderlyingError=\($0)}") }
        #expect(SystemLog.lines(tagged).count == 1 && SystemLog.lines(tagged)[0].hasSuffix("(×2)"))
    }

    @Test func aMessageIsScrubbed() {
        let entry = SystemLog.Entry(subsystem: "com.apple.network", category: "connection", fault: false,
                                    message: "failed https://my-mac.tail1234.ts.net/api/sessions/20251027_101010_ab12cd")
        let line = SystemLog.lines([entry]).first ?? ""
        #expect(!line.contains("tail1234") && !line.contains("20251027_101010_ab12cd"))
    }
}

final class ChatInfoProbe: UIViewController {}

@MainActor @Suite struct PresentationTrailTests {
    @Test func anAlertSaysWhatThePersonWasShown() {
        let alert = UIAlertController(title: "Couldn't Send", message: "The gateway refused it.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Try Again", style: .default))
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addTextField { $0.text = "secret words" }
        let line = PresentationTrail.describe(alert)
        #expect(line == "alert 'Couldn't Send': The gateway refused it. [Try Again / Cancel] with 1 field(s)")
        #expect(!line.contains("secret"))
    }

    @Test func aSheetIsNamedByItsFirstPage() {
        let navigation = UINavigationController(rootViewController: ChatInfoProbe())
        navigation.modalPresentationStyle = .formSheet
        #expect(PresentationTrail.describe(navigation) == "sheet (form) ChatInfoProbe")
        #expect(PresentationTrail.name(navigation) == "ChatInfoProbe")
    }

    /// Swiping the app away frees the scene's window, which removes its subviews on the way out. The trail used to take
    /// a weak reference to that dying window, which the runtime kills the app for (builds 460-515, 2026-10-30).
    @Test func aWindowBeingFreedDoesNotKillTheApp() async {
        var window: MeteredWindow? = MeteredWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        weak var freed = window
        window?.addSubview(UIView())
        window?.addSubview(UIView())
        // The look the additions queued runs first, as in the app: the removals below then queue a new one.
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        autoreleasepool { window = nil }
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(freed == nil)
        #expect(PresentationTrail.liveWindow(ObjectIdentifier(NSObject())) == nil)
    }
}
