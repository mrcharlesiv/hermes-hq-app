// [a11y] DEBUG only, and only when a UI test asks for it with `-HQUITestCleanQuit YES`: the app ends itself with an
// ordinary exit when the test says it is finished, and turns the test harness's own SIGTERM into an ordinary exit.
//
// Why (stress round 3, read from the simulator's log): every time the a11y UI suite failed with "Critical process
// HermesHQNative crashed in (null)", the app had not crashed. launchd recorded "exited due to SIGTERM | sent by
// xcodebuild": the next test's launch asked the harness to end the previous instance, as it does between every two
// tests, and on a badly loaded Mac the harness then booked its own signal as a crash of the test that had just
// finished. A process that leaves through exit(0) did not die of a signal, so there is nothing to misread.
// Nothing here is compiled into a release build.

#if DEBUG
import Foundation

nonisolated enum HQTestQuit {
    /// The Darwin notification a UI test posts from its tear-down (the Darwin notify center); it never leaves the simulator.
    nonisolated static let notification = "ai.hermes.hqnative.uitest.quit"
    nonisolated(unsafe) private static var source: DispatchSourceSignal?

    /// Both handlers run off the main actor (the signal source on a background queue), so nothing here may be
    /// main-actor isolated: an isolated closure traps when it is called from another queue.
    nonisolated static func installIfAsked() {
        guard UserDefaults.standard.bool(forKey: "HQUITestCleanQuit"), source == nil else { return }
        let queue = DispatchQueue.global(qos: .userInitiated)
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in _exit(0) },
                                        notification as CFString, nil, .deliverImmediately)
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        term.setEventHandler(handler: DispatchWorkItem { @Sendable in _exit(0) })
        term.resume()
        source = term
    }
}
#endif
