#if DEBUG
import Foundation

/// [mac-layout] `-HQDemoHelpers YES` (with -HQDemoRealChat): the demo chat has three helpers this turn (one running,
/// one done, one failed), so the shelf's Subagents card and the Mac inspector's Helpers tab can be looked at without a
/// gateway. Steer and Stop do nothing here (no store).
final class DemoHelpersSession: FakeChatSession, ChatActivityProviding {
    var onActivityChange: (() -> Void)?
    var liveStep: ToolLine? { nil }
    var statusIsWorking: Bool { true }
    func sendHidden(_ text: String, display: String?) {}
    var providerWait: String? { nil }
    var displayFlags: DisplayFlags { DisplayFlags() }
    func reasoningSeconds(messageId: String) -> [Int: Double] { [:] }
    var activityStore: ActivityStore? { nil }
    var activityRuntimeId: String? { nil }
    func setActivityVisible(_ visible: Bool, openSubagent: String?) {}
    var hiddenTurnAnchor: String? { nil }
    var revealedSteps: Set<String> = []

    let activity: ChatActivity = {
        let now = Date().timeIntervalSince1970
        func step(_ ago: Double, _ kind: SubagentStreamEntry.Kind, _ text: String, error: Bool = false) -> SubagentStreamEntry {
            SubagentStreamEntry(at: now - ago, isError: error, kind: kind, text: text)
        }
        var a = ChatActivity()
        a.nativeSubagentEvents = true
        a.subagents = [
            SubagentProgress(id: "sa-1", goal: "Read the upload tests and find why the flaky one fails", model: "claude-sonnet-4-5",
                             status: .running, taskCount: 3, taskIndex: 0, startedAt: now - 74, updatedAt: now - 2, toolCount: 6,
                             filesRead: ["Tests/UploadTests.swift", "App/Upload/Uploader.swift"],
                             stream: [step(70, .thinking, "Looking at the test's timers"), step(52, .tool, "read_file Tests/UploadTests.swift"),
                                      step(30, .tool, "search_files \"waitForExpectations\""), step(4, .tool, "terminal swift test --filter Upload")],
                             currentTool: "terminal"),
            SubagentProgress(id: "sa-2", goal: "Summarise yesterday's crash reports", model: "claude-haiku-4-5",
                             status: .completed, taskCount: 3, taskIndex: 1, startedAt: now - 140, updatedAt: now - 40,
                             durationSeconds: 61, toolCount: 3, filesRead: ["logs/crashes-2026-11-02.json"],
                             stream: [step(130, .tool, "read_file logs/crashes-2026-11-02.json"), step(45, .summary, "Two crashes, both in the photo viewer")],
                             summary: "Two crashes, both in the photo viewer's zoom (build 713). Same stack: a weak reference read after the sheet closed."),
            SubagentProgress(id: "sa-3", goal: "Check the price page for broken links", model: "claude-haiku-4-5",
                             status: .failed, taskCount: 3, taskIndex: 2, startedAt: now - 120, updatedAt: now - 90,
                             durationSeconds: 28, toolCount: 1,
                             stream: [step(110, .tool, "web_fetch https://example.com/pricing"), step(92, .progress, "The site didn't answer", error: true)],
                             summary: "The site didn't answer (timed out after 25 s)."),
        ]
        return a
    }()
}
#endif
