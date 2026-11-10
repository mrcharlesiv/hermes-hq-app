// Contract additions of the activity stream (docs/spec/1x-activity.md §3.4). `ToolCall.card` is the one field that had
// to go into Contracts.swift itself (a stored property); everything else lives here.

import Foundation

/// A chat that shows its activity: the shelf above the composer, the delegate card's live rows, reasoning timing, the
/// In Header live step and hidden goal continuations. The live session adopts it (the queue precedent: `ChatQueueing`).
protocol ChatActivityProviding: AnyObject {
    /// The chat's subagents, task lists and goal (a value snapshot).
    var activity: ChatActivity { get }
    /// Called on the main actor when `activity` changed (at most once per display frame), and when the display flags
    /// or the provider wait changed.
    var onActivityChange: (() -> Void)? { get set }
    /// In Header (§10.4): the step running now, nil while writing or idle.
    var liveStep: ToolLine? { get }
    /// The status words are a working state (not Offline / Reconnecting / Waiting for your approval…).
    var statusIsWorking: Bool { get }
    /// Submits a goal continuation with no bubble (`display_kind: "hidden"`), queued behind a running reply.
    func sendHidden(_ text: String, display: String?)

    /// The explained provider wait the waiting capsule shows instead of "Waiting for <model>" (§8.2).
    var providerWait: String? { get }
    /// The bot's `display.show_reasoning` / `display.tool_progress` (§2.3).
    var displayFlags: DisplayFlags { get }
    /// Measured "Thought for Ns" seconds by reasoning part index (memory only, §9.2).
    func reasoningSeconds(messageId: String) -> [Int: Double]
    /// The store and runtime id behind the shelf's actions (steer, stop a child, goal actions); nil until bound.
    var activityStore: ActivityStore? { get }
    var activityRuntimeId: String? { get }
    /// The screen shows this chat (true) or left it; `openSubagent` is the child whose detail is open (gates polls).
    func setActivityVisible(_ visible: Bool, openSubagent: String?)
    /// The newest message when a hidden goal continuation went out (that turn has no prompt row): nothing up to it is
    /// the running turn's (`StepRules.isWorking`).
    var hiddenTurnAnchor: String? { get }
    /// Replies whose hidden steps were brought back with Show Steps, kept while the app runs (§10.5).
    var revealedSteps: Set<String> { get set }
}
