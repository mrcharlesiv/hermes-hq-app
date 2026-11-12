// [island-fit] DEBUG only: `-HQDebugIsland "<what>:<seconds ago it began>,…"` puts Live Activities in the Dynamic
// Island two seconds after the app is in front, with no gateway and no sign-in, so every shape of the island's small
// views can be looked at (scripts/island-shots.sh). What: `turn` (a reply, running), `job`, `done` and `failed` (a reply, over),
// `talk` (a voice conversation), `talkended`. "turn:970,talk:30" asks for two at once.

#if DEBUG && canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation
import UIKit

@MainActor enum IslandDebugHook {
    static func start() {
        guard let spec = UserDefaults.standard.string(forKey: "HQDebugIsland"), !spec.isEmpty else { return }
        Task { @MainActor in
            for activity in Activity<HQLiveAttributes>.activities { await activity.end(nil, dismissalPolicy: .immediate) }
            for activity in Activity<TalkActivityAttributes>.activities { await activity.end(nil, dismissalPolicy: .immediate) }
            // iOS starts one only for an app in front: a first launch can take a while to get there.
            for _ in 0..<40 where UIApplication.shared.applicationState != .active { try? await Task.sleep(for: .seconds(0.5)) }
            try? await Task.sleep(for: .seconds(2))
            for (index, part) in spec.split(separator: ",").enumerated() {
                let pieces = part.split(separator: ":")
                guard let what = pieces.first.map(String.init) else { continue }
                let began = Date().addingTimeInterval(-(pieces.count > 1 ? Double(pieces[1]) ?? 0 : 0))
                show(what, began: began, index: index)
            }
        }
    }

    private static func show(_ what: String, began: Date, index: Int) {
        do {
            switch what {
            case "twin": break   // another app's, started by the tour itself (UITests/live/IslandFitTests.swift)
            case "talk", "talkended":
                let ended = what == "talkended"
                let state = TalkActivityAttributes.ContentState(phase: ended ? "ended" : "listening", title: ended ? "Ended" : "Listening",
                                                                muted: false, endedAt: ended ? Date() : nil)
                _ = try Activity.request(attributes: TalkActivityAttributes(name: "Ivy", startedAt: began, link: nil),
                                         content: ActivityContent(state: state, staleDate: nil), pushType: nil)
            default:
                var content = LiveActivityContent(phase: what == "job" ? .running : .working, startedAt: began)
                if what == "done" || what == "failed" {
                    content.phase = what == "done" ? .done : .failed
                    content.endedAt = Date()
                }
                if what != "job" { content.trail = LiveStepTrail(step: "running npm test", recent: ["reading package.json"], steps: 2) }
                let subject = LiveActivitySubject(kind: what == "job" ? .job : .turn, id: "island-\(index)")
                let attributes = HQLiveAttributes(subject: subject, botName: "Otto", detail: what == "job" ? "Morning brief" : nil, link: nil)
                _ = try Activity.request(attributes: attributes, content: ActivityContent(state: content, staleDate: nil), pushType: nil)
            }
        } catch {
            AppLog.note("live", "island demo \(what) refused: \(error.localizedDescription)")
        }
    }
}
#endif
