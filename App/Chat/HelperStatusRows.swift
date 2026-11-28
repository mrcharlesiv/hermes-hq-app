import Foundation

/// One disclosure for the helpers of one user request. This is separate from adjacent update grouping: replies,
/// background commands and bot conversations keep their positions. Missing ownership is never inferred by count.
nonisolated enum HelperStatusRows {
    struct Group {
        var requestID: String
        var anchor: Int
        var span: ClosedRange<Int>
        var helpers: [SubagentProgress] = []
        var members: [UpdateMemberRow] = []

        var title: String {
            let working = helpers.filter { $0.status == .running }.count
            let queued = helpers.filter { $0.status == .queued }.count
            let done = helpers.filter { $0.status == .completed }.count
            let failed = helpers.filter { $0.status == .failed }.count
            let stopped = helpers.filter { $0.status == .interrupted }.count
            let dispatched = helpers.filter { $0.status == .dispatched }.count
            var words: [String] = []
            func add(_ count: Int, _ state: String) {
                guard count > 0 else { return }
                let noun = words.isEmpty ? (count == 1 ? " helper" : " helpers") : ""
                words.append("\(count)\(noun) \(state)")
            }
            add(working, "working")
            add(queued, "queued")
            add(done, "done")
            add(failed, "failed")
            add(stopped, "stopped")
            add(dispatched, "dispatched")
            return words.joined(separator: " · ")
        }

        var fingerprint: Int {
            var h = Hasher()
            h.combine(requestID); h.combine(helpers)
            for member in members {
                h.combine(member.id); h.combine(member.title); h.combine(member.full)
                h.combine(member.steps); h.combine(member.time)
            }
            return h.finalize()
        }

        var opened: UpdatesOpened {
            UpdatesOpened(title: "Helper Reports & Steps", subtitle: title, members: members, fingerprint: fingerprint)
        }

        func row(input: ChatRowBuilder.Input) -> ChatRow {
            let message = input.messages[anchor]
            var result = BackgroundResultRow(title: title, result: "", process: false, expanded: false)
            // Reuse the existing compact disclosure geometry and accessibility, even for just one helper.
            result.group = UpdatesGroup(marks: [.glyph(.subagent)], tail: nil, count: 1, opens: true, titles: [title])
            result.group?.helperDetails = true
            result.helperRequestID = requestID
            result.helpersWorking = helpers.contains { $0.isLive }
            return ChatRow(id: "\(message.id)|helpers", messageId: message.id, scope: input.scope,
                           fingerprint: fingerprint, kind: .backgroundResult(result), gapAbove: ChatMetrics.turnGap, variant: 0)
        }
    }

    private struct Slot {
        var group: Int
        var helper: Int
        var message: Int
        var callID: String
        var goal: String
        var request: Int
        var requestStart: Date?
        var requestEnd: Date?
        var hasEnd: Bool
    }

    struct Plan {
        var groups: [Group] = []
        /// Every safely associated roster ID, including completed/failed helpers retained by the screen.
        var coveredLiveIDs: Set<String> = []
        private var calls: [Int: Set<String>] = [:]
        private var reports: Set<Int> = []

        init(_ input: ChatRowBuilder.Input) {
            guard input.room == nil else { return }
            let messages = input.messages
            var request: Int?
            var groupIndex: Int?
            var slots: [Slot] = []
            var snapshots = Dictionary(input.activity.retainedSubagents.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            for child in input.activity.subagents { snapshots[child.id] = child }
            let snapshotRows = Array(snapshots.values)
            let boundaries = messages.indices.filter { isBoundary(messages[$0]) }
            var nextBoundary: [Int: Int] = [:]
            for pair in zip(boundaries, boundaries.dropFirst()) { nextBoundary[pair.0] = pair.1 }
            var owners: [Int: Int] = [:]
            var allGoals: [(message: Int, goal: String)] = []
            for (index, message) in messages.enumerated() {
                if isBoundary(message) {
                    // Deliveries and scheduled runs start their own work, never a continuation of your request.
                    request = message.role == .user && message.sender == nil && message.job == nil ? index : nil
                    groupIndex = nil
                    continue
                }
                if let activeRequest = request,
                   endsRequestOwnership(message, at: index, request: activeRequest, slots: slots,
                                        allGoals: allGoals, snapshots: snapshotRows) {
                    // An old or unidentified helper's delivery can start an unrelated continuation. Keep it
                    // standalone and stop later native events from matching this request's preceding calls.
                    for s in slots.indices where slots[s].request == activeRequest {
                        slots[s].requestEnd = message.timestamp
                        slots[s].hasEnd = true
                    }
                    request = nil
                    groupIndex = nil
                }
                if let request { owners[index] = request }
                guard message.role == .assistant else { continue }
                for part in message.parts {
                    guard case .tool(let call) = part, call.name == "delegate_task", !call.id.isEmpty else { continue }
                    var goals = ToolCards.delegateGoals(.object(ToolArgs.parse(call.argsText)))
                    if goals.isEmpty, case .delegate(let saved, _, _, _)? = call.card { goals = saved }
                    allGoals += goals.map { (message: index, goal: normalized($0)) }
                    guard let request else { continue }
                    let base = ToolCards.rows(goals: goals, card: call.card, hasResult: call.card != nil, toolCallId: call.id)
                    // A malformed/empty call remains an ordinary step with its error/details.
                    guard !base.isEmpty else { continue }
                    if groupIndex == nil {
                        groupIndex = groups.count
                        groups.append(Group(requestID: messages[request].id, anchor: index, span: index...index))
                    }
                    let g = groupIndex!
                    calls[index, default: []].insert(call.id)
                    groups[g].span = groups[g].anchor...index
                    let end = nextBoundary[request].flatMap { messages[$0].timestamp }
                    // A background dispatch names its delegation: its report (maybe after you moved on) finds it by that.
                    var delegationID: String?
                    if case .delegate(_, _, _, let id)? = call.card { delegationID = id }
                    for (task, row) in base.enumerated() {
                        let state: SubagentStatus
                        if call.state == .failed { state = .failed }
                        else {
                            switch row.status {
                            case .running: state = message.isStreaming || input.isRunning && index == messages.count - 1 ? .running : .dispatched
                            case .queued: state = .queued
                            case .completed: state = .completed
                            case .failed: state = .failed
                            case .interrupted: state = .interrupted
                            case .dispatched: state = .dispatched
                            }
                        }
                        let start = message.timestamp?.timeIntervalSince1970 ?? 0
                        let helper = SubagentProgress(id: "delegate-tool:\(call.id):\(task)", goal: row.goal, delegationId: delegationID,
                                                      model: row.model,
                                                      status: state, taskCount: base.count, taskIndex: task,
                                                      startedAt: start, updatedAt: start, durationSeconds: row.durationSeconds,
                                                      summary: row.activity.isEmpty ? call.summary : row.activity.joined(separator: "\n"))
                        slots.append(Slot(group: g, helper: groups[g].helpers.count, message: index, callID: call.id,
                                          goal: normalized(row.goal), request: request, requestStart: messages[request].timestamp,
                                          requestEnd: end, hasEnd: nextBoundary[request] != nil))
                        groups[g].helpers.append(helper)
                    }
                    var member = UpdateMemberRow(id: "\(message.id)|helper-\(call.id)|in", messageId: message.id,
                                                 mark: .glyph(.subagent), title: "Helper batch", time: message.timestamp,
                                                 preview: goals.joined(separator: " · "), full: "")
                    member.steps = [call]
                    groups[g].members.append(member)
                }
            }

            // Claim each native helper once across ALL batches. Never use the old per-card task-count/index fallback.
            // Goal matching needs a known request time window; a matching explicit stand-in ID needs no clock.
            var nativeMatches: [Int: [SubagentProgress]] = [:]
            for child in snapshotRows {
                let exact = slots.indices.filter { groups[slots[$0].group].helpers[slots[$0].helper].id == child.id }
                let candidates: [Int]
                if !exact.isEmpty { candidates = exact }
                else if child.isDelegateStandIn { candidates = [] }
                else {
                    candidates = slots.indices.filter { matches(child, slot: slots[$0]) }
                }
                guard candidates.count == 1, let s = candidates.first else { continue }
                let slot = slots[s]
                if child.isDelegateStandIn {
                    coveredLiveIDs.insert(child.id)
                    // The legacy fallback can call a successful async dispatch "completed". The transcript's
                    // dispatched card has no terminal result, so that fallback must not manufacture one.
                    if !(groups[slot.group].helpers[slot.helper].status == .dispatched && child.status == .completed) {
                        groups[slot.group].helpers[slot.helper] = child
                    }
                } else { nativeMatches[s, default: []].append(child) }
            }
            for (s, children) in nativeMatches where children.count == 1 {
                let slot = slots[s], child = children[0]
                groups[slot.group].helpers[slot.helper] = child
                coveredLiveIDs.insert(child.id)
            }

            // Reports often have no delegation ID after hydration. Move only a full, unique goal match; an unlabelled
            // batch, a clipped goal, or repeated goals stays in the transcript with its original disclosure.
            for (index, message) in messages.enumerated() where message.role == .system {
                guard let result = input.backgroundResults[message.id] ?? message.report else { continue }
                let tasks = message.helperReport?.tasks ?? reportGoal(message.plainText).map {
                    [HelperReport.Task(goal: $0, status: reportStatus(message.plainText))]
                } ?? []
                var matched: [Int] = []
                if let id = message.helperReport?.delegationID {
                    matched = slots.indices.filter { s in
                        let slot = slots[s]
                        return slot.message < index && groups[slot.group].helpers[slot.helper].delegationId == id
                    }
                }
                if matched.isEmpty {
                    for task in tasks {
                        let goal = normalized(task.goal)
                        // Include unowned calls in ambiguity checks. A scheduled helper can have the same goal.
                        guard allGoals.filter({ $0.message < index && $0.goal == goal }).count == 1 else { matched = []; break }
                        let candidates = slots.indices.filter {
                            let slot = slots[$0]
                            let knownID = groups[slot.group].helpers[slot.helper].delegationId
                            let reportID = message.helperReport?.delegationID
                            guard knownID == nil || reportID == nil || knownID == reportID else { return false }
                            return slot.message < index && slot.goal == goal && owners[index] == slot.request
                        }
                        guard candidates.count == 1 else { matched = []; break }
                        matched += candidates
                    }
                }
                guard let first = matched.first, Set(matched).count == matched.count,
                      Set(matched.map { slots[$0].group }).count == 1 else { continue }
                let g = slots[first].group
                let title = BackgroundResults.plainTitle(message.plainText)
                let row = BackgroundResultRow(title: title, result: result, process: false, expanded: false)
                var member = UpdateMemberRow(id: "\(message.id)|bg|in", messageId: message.id, mark: .glyph(.subagent),
                                             title: title, time: message.timestamp, preview: tasks.map(\.goal).joined(separator: " · "),
                                             full: BackgroundResults.opened(title: title, result: result))
                member.result = row
                groups[g].members.append(member)
                groups[g].span = groups[g].anchor...max(index, groups[g].span.upperBound)
                reports.insert(index)
                let at = message.timestamp?.timeIntervalSince1970
                for s in matched {
                    let slot = slots[s]
                    let previous = groups[g].helpers[slot.helper]
                    if let status = tasks.first(where: { normalized($0.goal) == slot.goal })?.status,
                       previous.isDelegateStandIn || at.map({ $0 >= previous.updatedAt }) == true {
                        groups[g].helpers[slot.helper].status = status
                        if matched.count == 1 { groups[g].helpers[slot.helper].summary = result }
                        if let at { groups[g].helpers[slot.helper].updatedAt = at }
                    }
                }
            }
            let order = Dictionary(messages.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
            for g in groups.indices {
                groups[g].members.sort { (order[$0.messageId] ?? 0) < (order[$1.messageId] ?? 0) }
            }
        }

        func group(requestID: String) -> Group? { groups.first { $0.requestID == requestID } }

        func rows(at index: Int, input: ChatRowBuilder.Input, voiceFolded: Bool = false) -> [ChatRow] {
            var result: [ChatRow] = []
            if !reports.contains(index) {
                var scoped = input
                scoped.activity.consolidatedHelperCalls = calls[index] ?? []
                ChatRowBuilder.appendRows(for: input.messages[index], at: index, input: scoped,
                                          voiceFolded: voiceFolded, into: &result)
            }
            if let group = groups.first(where: { $0.anchor == index }) { result.insert(group.row(input: input), at: 0) }
            return result
        }

        /// Updating a later batch/report also rebuilds the earlier anchor. The same dependency applies when paging.
        func widen(_ range: ClosedRange<Int>) -> ClosedRange<Int> {
            var lo = range.lowerBound, hi = range.upperBound
            var changed = true
            while changed {
                changed = false
                for group in groups where group.span.overlaps(lo...hi) {
                    let nextLo = min(lo, group.span.lowerBound), nextHi = max(hi, group.span.upperBound)
                    if nextLo != lo || nextHi != hi { changed = true; lo = nextLo; hi = nextHi }
                }
            }
            return lo...hi
        }
    }

    private static func normalized(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func matches(_ child: SubagentProgress, slot: Slot) -> Bool {
        guard slot.goal == normalized(child.goal), let start = slot.requestStart,
              child.startedAt >= start.timeIntervalSince1970,
              !slot.hasEnd || slot.requestEnd != nil,
              slot.requestEnd.map({ child.startedAt < $0.timeIntervalSince1970 }) ?? true else { return false }
        return true
    }

    /// Keep a helper-triggered continuation only when its report positively belongs to the current request.
    /// Ambiguous or foreign reports stop ownership; they never assign the continuation to a guessed request.
    private static func endsRequestOwnership(_ message: ChatMessage, at index: Int, request: Int, slots: [Slot],
                                             allGoals: [(message: Int, goal: String)], snapshots: [SubagentProgress]) -> Bool {
        guard message.role == .system,
              message.helperReport != nil || helperReportTitle.test(message.plainText) else { return false }
        let reportID = message.helperReport?.delegationID
        if let reportID {
            let identified = snapshots.filter { !$0.isDelegateStandIn && $0.delegationId == reportID }
            if !identified.isEmpty {
                var owners: Set<Int> = []
                for child in identified {
                    let candidates = Set(slots.filter { $0.message < index && matches(child, slot: $0) }.map(\.request))
                    guard candidates.count == 1 else { return true }
                    owners.formUnion(candidates)
                }
                return owners != [request]
            }
        }
        let goals = message.helperReport?.tasks.map(\.goal) ?? reportGoal(message.plainText).map { [$0] } ?? []
        guard !goals.isEmpty else { return true }
        var owners: Set<Int> = []
        for text in goals {
            let goal = normalized(text)
            guard allGoals.filter({ $0.message < index && $0.goal == goal }).count == 1 else { return true }
            let candidates = slots.filter { $0.message < index && $0.goal == goal }
            guard candidates.count == 1, let slot = candidates.first else { return true }
            if let reportID, snapshots.contains(where: {
                !$0.isDelegateStandIn && $0.delegationId != nil && $0.delegationId != reportID && matches($0, slot: slot)
            }) { return true }
            owners.insert(slot.request)
        }
        return owners != [request]
    }

    private static let helperReportTitle = TRx(#"^(?:Subagent Tasks? (?:Completed|Finished(?: with Issues)?|Failed|Cancelled|Interrupted|Timed Out|Stalled|Incomplete|Unknown)(?::|$)|(?:\d+ )?background agents?(?: work)? finished\b)"#,
                                               [.caseInsensitive])

    private static func isBoundary(_ message: ChatMessage) -> Bool {
        message.role == .user || message.job != nil || message.role == .system &&
            (message.sender != nil || BackgroundResults.fromBot(message.report ?? message.plainText) != nil)
    }

    private static func reportGoal(_ text: String) -> String? {
        guard text.range(of: #"^Subagent Task (?:Completed|Finished|Failed|Cancelled|Interrupted|Timed Out|Stalled|Incomplete): "#,
                         options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        let goal = BackgroundResults.split(text).rest
        return goal.isEmpty || goal.hasSuffix("...") || goal.hasSuffix("…") ? nil : goal
    }

    private static func reportStatus(_ title: String) -> SubagentStatus {
        let head = BackgroundResults.split(title).head.lowercased()
        if head.contains("failed") || head.contains("timed out") || head.contains("stalled") { return .failed }
        if head.contains("cancelled") || head.contains("interrupted") || head.contains("incomplete") { return .interrupted }
        return .completed
    }
}
