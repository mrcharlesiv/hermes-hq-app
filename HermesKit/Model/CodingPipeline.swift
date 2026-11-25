import Foundation

/// The four decision-first buckets on a coding project page, replacing stacked chat + GitHub status counters.
nonisolated enum CodingPipelineBucket: String, CaseIterable, Hashable, Sendable {
    /// Open pull requests ready to review and merge (not working, checks not failing or running).
    case ready
    /// Chats needing the owner's attention: waiting for input, failing CI checks, or unread replies.
    case needsYou
    /// Active work in progress: running bots, drafts, branches without PRs, checks running, or plain project chats.
    case inFlight
    /// Completed work: merged/closed PRs (quiet) and archived/auto-done chats. Collapsed by default.
    case shipped

    var label: String {
        switch self {
        case .ready: "Ready"
        case .needsYou: "Needs You"
        case .inFlight: "Active"
        case .shipped: "Shipped"
        }
    }

    var sectionTitle: String {
        switch self {
        case .ready: "Ready to Ship"
        case .needsYou: "Needs You"
        case .inFlight: "Active"
        case .shipped: "Shipped"
        }
    }

    var sectionId: String {
        switch self {
        case .ready: SessionListPipeline.pipelineReady
        case .needsYou: SessionListPipeline.pipelineNeeds
        case .inFlight: SessionListPipeline.pipelineInFlight
        case .shipped: SessionListPipeline.pipelineShipped
        }
    }
}

/// Pure classifier mapping coding-project chats into `CodingPipelineBucket` so header counts and list sections match 1-to-1.
nonisolated enum CodingPipeline {
    static func bucket(for session: SessionSummary, isDone: Bool = false) -> CodingPipelineBucket {
        let working = session.isRunning || session.status == .working
        let needsInput = session.status == .needsInput
        let pr = session.pullRequest

        if needsInput { return .needsYou }
        if isDone || (session.archived && !working) { return .shipped }
        if let pr, (pr.state == .open || pr.state == .draft), pr.checks?.state == .failed { return .needsYou }
        if let pr, pr.state == .open, !working, pr.checks?.state != .running { return .ready }
        if session.unread && !working { return .needsYou }
        if let pr, (pr.state == .merged || pr.state == .closed), !working { return .shipped }
        return .inFlight
    }

    static func counts(_ rows: [SessionSummary], isDone: (SessionSummary) -> Bool = { $0.archived }) -> [CodingPipelineBucket: Int] {
        var out: [CodingPipelineBucket: Int] = [:]
        for row in rows {
            out[bucket(for: row, isDone: isDone(row)), default: 0] += 1
        }
        return out
    }

    static func isReadyToMerge(_ session: SessionSummary) -> Bool {
        bucket(for: session) == .ready && session.pullRequest?.state == .open
    }

    static func hasFailingChecks(_ session: SessionSummary) -> Bool {
        guard let pr = session.pullRequest, !session.archived else { return false }
        return (pr.state == .open || pr.state == .draft) && pr.checks?.state == .failed
    }

    /// Sort priority within a bucket: pinned first, then most urgent sub-state, then recency.
    static func subRank(_ session: SessionSummary, in bucket: CodingPipelineBucket) -> Int {
        let pinBonus = (session.pinned || session.projectPinned) ? 0 : 10
        switch bucket {
        case .ready:
            return pinBonus + (session.pullRequest?.checks?.state == .passed ? 0 : 1)
        case .needsYou:
            if session.status == .needsInput { return pinBonus + 0 }
            if hasFailingChecks(session) { return pinBonus + 1 }
            return pinBonus + 2
        case .inFlight:
            if session.isRunning || session.status == .working { return pinBonus + 0 }
            if session.pullRequest?.checks?.state == .running { return pinBonus + 1 }
            if session.pullRequest?.state == .draft || session.pullRequest?.state == .open { return pinBonus + 2 }
            return pinBonus + 3
        case .shipped:
            return pinBonus
        }
    }
}
