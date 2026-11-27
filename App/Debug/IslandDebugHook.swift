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
            for activity in Activity<HQGroupedLiveAttributes>.activities { await activity.end(nil, dismissalPolicy: .immediate) }
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
            case "grouped", "grouped1", "groupedmany", "groupeddone", "groupedfailed", "groupedstale":
                let now = Date()
                let scheme = AppIdentity.current.urlScheme
                let items: [LiveGroupedItem] = switch what {
                case "grouped1":
                    [
                        LiveGroupedItem(subject: LiveActivitySubject(kind: .turn, id: "otto"), title: "Otto",
                                        subtitle: "Running npm test…", phase: .working, startedAt: began, endedAt: nil,
                                        link: "\(scheme)://session/s-otto", session: "s-otto"),
                    ]
                case "groupeddone":
                    [
                        LiveGroupedItem(subject: LiveActivitySubject(kind: .turn, id: "ivy/s-audit"), title: "Landing page audit",
                                        subtitle: "Ivy", phase: .done, startedAt: began, endedAt: now,
                                        link: "\(scheme)://session/s-audit", session: "s-audit"),
                        LiveGroupedItem(subject: LiveActivitySubject(kind: .job, id: "deploys|j1"), title: "Morning brief",
                                        subtitle: "Deploys", phase: .done, startedAt: began, endedAt: now.addingTimeInterval(-30),
                                        link: "\(scheme)://job/deploys%7Cj1"),
                    ]
                case "groupedfailed":
                    [
                        LiveGroupedItem(subject: LiveActivitySubject(kind: .job, id: "ops|j2"), title: "Weekly deploy check",
                                        subtitle: "Ops", phase: .failed, startedAt: began, endedAt: now,
                                        link: "\(scheme)://job/ops%7Cj2"),
                        LiveGroupedItem(subject: LiveActivitySubject(kind: .turn, id: "ivy/s-audit"), title: "Landing page audit",
                                        subtitle: "Ivy", phase: .done, startedAt: began, endedAt: now.addingTimeInterval(-45),
                                        link: "\(scheme)://session/s-audit", session: "s-audit"),
                    ]
                case "groupedmany":
                    [
                        LiveGroupedItem(subject: LiveActivitySubject(kind: .turn, id: "orch/s-1"), title: "Update hermes plugins and scanner rules",
                                        subtitle: "Orchestrator", phase: .working, startedAt: began, endedAt: nil,
                                        link: "\(scheme)://session/s-1", session: "s-1"),
                        LiveGroupedItem(subject: LiveActivitySubject(kind: .turn, id: "otto"), title: "Otto",
                                        subtitle: "Running swift test…", phase: .working, startedAt: began.addingTimeInterval(30), endedAt: nil,
                                        link: "\(scheme)://session/s-otto", session: "s-otto"),
                        LiveGroupedItem(subject: LiveActivitySubject(kind: .job, id: "deploys|j1"), title: "Morning brief",
                                        subtitle: "Deploys", phase: .running, startedAt: began.addingTimeInterval(60), endedAt: nil,
                                        link: "\(scheme)://job/deploys%7Cj1"),
                        LiveGroupedItem(subject: LiveActivitySubject(kind: .turn, id: "ivy/s-2"), title: "Refactor sidebar navigation layout",
                                        subtitle: "Ivy", phase: .working, startedAt: began.addingTimeInterval(90), endedAt: nil,
                                        link: "\(scheme)://session/s-2", session: "s-2"),
                        LiveGroupedItem(subject: LiveActivitySubject(kind: .turn, id: "ops/s-3"), title: "Check staging cluster metrics",
                                        subtitle: "Ops", phase: .working, startedAt: began.addingTimeInterval(120), endedAt: nil,
                                        link: "\(scheme)://session/s-3", session: "s-3"),
                        LiveGroupedItem(subject: LiveActivitySubject(kind: .turn, id: "ivy/s-4"), title: "Landing page audit",
                                        subtitle: "Ivy", phase: .done, startedAt: began, endedAt: now.addingTimeInterval(-20),
                                        link: "\(scheme)://session/s-4", session: "s-4"),
                        LiveGroupedItem(subject: LiveActivitySubject(kind: .job, id: "ops|j2"), title: "Weekly deploy check",
                                        subtitle: "Ops", phase: .failed, startedAt: began, endedAt: now.addingTimeInterval(-60),
                                        link: "\(scheme)://job/ops%7Cj2"),
                    ]
                default:
                    [
                        LiveGroupedItem(subject: LiveActivitySubject(kind: .turn, id: "orch/s-1"), title: "Update hermes plugins and scanner rules",
                                        subtitle: "Orchestrator", phase: .working, startedAt: began, endedAt: nil,
                                        link: "\(scheme)://session/s-1", session: "s-1"),
                        LiveGroupedItem(subject: LiveActivitySubject(kind: .turn, id: "otto"), title: "Otto",
                                        subtitle: "Running npm test…", phase: .working, startedAt: began.addingTimeInterval(40), endedAt: nil,
                                        link: "\(scheme)://session/s-otto", session: "s-otto"),
                        LiveGroupedItem(subject: LiveActivitySubject(kind: .job, id: "deploys|j1"), title: "Morning brief",
                                        subtitle: "Deploys", phase: .running, startedAt: began.addingTimeInterval(80), endedAt: nil,
                                        link: "\(scheme)://job/deploys%7Cj1"),
                        LiveGroupedItem(subject: LiveActivitySubject(kind: .turn, id: "ivy/s-audit"), title: "Landing page audit",
                                        subtitle: "Ivy", phase: .done, startedAt: began, endedAt: now.addingTimeInterval(-25),
                                        link: "\(scheme)://session/s-audit", session: "s-audit"),
                        LiveGroupedItem(subject: LiveActivitySubject(kind: .job, id: "ops|j2"), title: "Weekly deploy check",
                                        subtitle: "Ops", phase: .failed, startedAt: began, endedAt: now.addingTimeInterval(-60),
                                        link: "\(scheme)://job/ops%7Cj2"),
                    ]
                }
                let state = LiveGroupedContent(items: LiveGroupedContent.sorted(items))
                let staleDate: Date? = what == "groupedstale" ? Date().addingTimeInterval(3) : nil
                let attributes = HQGroupedLiveAttributes(appName: AppIdentity.current.displayName,
                                                         link: "\(scheme)://",
                                                         accent: HQPalette.cardAccent)
                _ = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: staleDate), pushType: nil)
            case "talk", "talkended", "talklong", "talkmuted", "talkpaused":
                let ended = what == "talkended" || what == "talkpaused"
                let muted = what == "talkmuted"
                let name = (what == "talklong" || what == "talkpaused") ? "Orchestrator" : "Ivy"
                let title: String = switch what {
                case "talkended": "Ended"
                case "talkpaused": "Paused after 2 minutes of silence"
                case "talklong": "Reconnecting…"
                default: "Listening"
                }
                let phase = ended ? "ended" : (what == "talklong" ? "reconnecting" : "listening")
                let state = TalkActivityAttributes.ContentState(phase: phase, title: title, muted: muted, endedAt: ended ? Date() : nil)
                _ = try Activity.request(attributes: TalkActivityAttributes(name: name, startedAt: began, link: nil),
                                         content: ActivityContent(state: state, staleDate: nil), pushType: nil)
            default:
                let isJob = what == "job" || what == "longjob"
                let isDone = what == "done" || what == "sidedone"
                let isFailed = what == "failed"
                let isSide = what == "side" || what == "sidedone"
                let isStale = what == "stale"
                var content = LiveActivityContent(phase: isJob ? .running : .working, startedAt: began)
                if isDone || isFailed {
                    content.phase = isDone ? .done : .failed
                    content.endedAt = Date()
                }
                if !isJob {
                    if isSide {
                        content.trail = LiveStepTrail(
                            step: isDone ? nil : "running swift test --filter LiveActivityTurnRulesTests",
                            recent: ["editing ReplyActivityWidget.swift", "reading LiveActivityContent.swift"],
                            steps: 8
                        )
                    } else {
                        content.trail = LiveStepTrail(step: "running npm test", recent: ["reading package.json"], steps: 2)
                    }
                }
                let subject = LiveActivitySubject(kind: isJob ? .job : .turn, id: "island-\(index)")
                let botName = isSide ? "Orchestrator" : (what == "longjob" ? "Deploys" : "Otto")
                let detail: String? = switch what {
                case "job": "Morning brief"
                case "longjob": "Weekly production deploy health check and audit"
                case "side", "sidedone": "Update hermes plugins and validate every scanner rule"
                default: nil
                }
                let staleDate: Date? = isStale ? Date().addingTimeInterval(3) : nil
                let attributes = HQLiveAttributes(subject: subject, botName: botName, detail: detail, link: nil)
                _ = try Activity.request(attributes: attributes, content: ActivityContent(state: content, staleDate: staleDate), pushType: nil)
            }
        } catch {
            AppLog.note("live", "island demo \(what) refused: \(error.localizedDescription)")
        }
    }
}
#endif
