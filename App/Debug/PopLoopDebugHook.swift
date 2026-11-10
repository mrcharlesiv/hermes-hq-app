// [perf] DEBUG-only: build 297 "Smooth back to Bots". Opens chats from the Bots list and goes back, over and over, with
// nothing driving the app from outside (an XCUITest's accessibility queries and its animation tracking cost the main
// thread more than the pop itself on the simulator). FrameMeter measures each pop as on a phone; the buckets are sent
// at the end (scripts/perf-botspop.sh `--loop` reads them from the fixture).
//
// - `-HQDebugPopLoop <n>`            n opens and pops once the list is up (after `-HQDebugOpenBot`'s chat, when given:
//                                    it is left with Back first, so `-HQDebugSend "slow: …"` keeps a bot working)
// - `-HQDebugPopBots <id,id,…>`      the chats it opens, in turn (default ivy,writer)
// - `-HQDebugPopGap <s>`             seconds between each push and pop (default 2)

#if DEBUG
import UIKit

@MainActor enum PopLoopDebugHook {
    private static let defaults = UserDefaults.standard

    static func start(_ root: MainTabController) {
        let count = defaults.integer(forKey: "HQDebugPopLoop")
        guard count > 0 else { return }
        let bots = (defaults.string(forKey: "HQDebugPopBots") ?? "ivy,writer").split(separator: ",").map(String.init)
        let gap = defaults.object(forKey: "HQDebugPopGap") != nil ? defaults.double(forKey: "HQDebugPopGap") : 2
        // With -HQDebugOpenBot the first chat opens (and sends) by itself: back from it once the send has gone.
        let first: Double = defaults.string(forKey: "HQDebugOpenBot") != nil ? 9 : 4
        DispatchQueue.main.asyncAfter(deadline: .now() + first) {
            if root.botsViewController.navigationController?.topViewController is ChatViewController { pop(root) }
            DispatchQueue.main.asyncAfter(deadline: .now() + gap) {
                FrameMeter.shared.leave()   // what came before the loop is its own bucket
                AppLog.note("perf", "pop loop: \(count) × \(bots.joined(separator: ","))")
                // A profiler waiting on the note starts now (the note reaches the outbox on the log's own queue).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { LogUploader.shared.kick("pop-loop") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { step(root, index: 0, count: count, bots: bots, gap: gap) }
            }
        }
    }

    private static func pop(_ root: MainTabController) {
        root.botsViewController.navigationController?.popViewController(animated: true)
    }

    private static func step(_ root: MainTabController, index: Int, count: Int, bots: [String], gap: Double) {
        guard index < count else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                FrameMeter.shared.leave()
                AppLog.note("perf", "pop loop done")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { LogUploader.shared.kick("pop-loop") }
            }
            return
        }
        root.botsViewController.open(bots[index % bots.count])
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) {
            pop(root)
            DispatchQueue.main.asyncAfter(deadline: .now() + gap) {
                step(root, index: index + 1, count: count, bots: bots, gap: gap)
            }
        }
    }
}
#endif
