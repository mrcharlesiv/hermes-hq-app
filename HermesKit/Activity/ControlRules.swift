// The goal snapshot (docs/spec/1x-activity.md §6): a strict parse of `SessionControlSnapshot` in the web's
// `hasExactFields` discipline (V:store/session-control.ts:150-447) — a missing or mistyped required field drops the
// whole snapshot — and the chip / card words (V:app/chat/composer/status-stack/session-control-goal.tsx).
//
// One leniency: an optional key that is present with `null` reads as absent. Hermes omits empty optionals
// (H:tui_gateway/methods_session_control.py:48-82), so this only matters for stand-ins that write `null`.

import Foundation

nonisolated enum ControlRules {
    private typealias Obj = [String: JSONValue]

    private static func exact(_ o: Obj, required: [String], optional: [String] = []) -> Bool {
        let allowed = Set(required + optional)
        return required.allSatisfy { o[$0] != nil } && o.keys.allSatisfy { allowed.contains($0) }
    }

    /// Optional key: absent or null → .some(nil) (fine), present and valid → value, present and invalid → nil.
    private static func optionalString(_ o: Obj, _ key: String) -> String?? {
        switch o[key] {
        case nil, .null?: return .some(nil)
        case .string(let s)?: return .some(s)
        default: return nil
        }
    }

    private static func optionalNumber(_ o: Obj, _ key: String) -> Double?? {
        switch o[key] {
        case nil, .null?: return .some(nil)
        case .number(let n)? where n.isFinite: return .some(n)
        default: return nil
        }
    }

    static func parseSnapshot(_ value: JSONValue?) -> ControlSnapshot? {
        guard case .object(let o)? = value, exact(o, required: ["goal", "loop", "heartbeat", "revision", "updated_at"]),
              case .string(let revision)? = o["revision"], let updatedAt = ActivityJSON.num(o["updated_at"]) else { return nil }
        var goal: GoalSnapshot?
        if o["goal"] != .null {
            guard let parsed = parseGoal(o["goal"]) else { return nil }
            goal = parsed
        }
        func raw(_ key: String) -> JSONValue? { o[key] == .null ? nil : o[key] }
        // loop / heartbeat: shape-checked only as objects (they are out of scope, kept raw).
        if let loop = raw("loop"), loop.object == nil { return nil }
        if let heartbeat = raw("heartbeat"), heartbeat.object == nil { return nil }
        return ControlSnapshot(goal: goal, loop: raw("loop"), heartbeat: raw("heartbeat"), revision: revision, updatedAt: updatedAt)
    }

    static func parseGoal(_ value: JSONValue?) -> GoalSnapshot? {
        let required = ["title", "status", "turns_used", "max_turns", "contract", "subgoals", "gates"]
        let optional = ["created_at", "updated_at", "paused_reason", "last_verdict", "last_reason", "wait_barrier"]
        guard case .object(let o)? = value, exact(o, required: required, optional: optional),
              case .string(let title)? = o["title"], case .string(let statusText)? = o["status"],
              let status = GoalStatus(rawValue: statusText),
              let turnsUsed = ActivityJSON.int(o["turns_used"]), let maxTurns = ActivityJSON.int(o["max_turns"]),
              case .array(let subgoalValues)? = o["subgoals"], case .array(let gateValues)? = o["gates"],
              let contract = parseContract(o["contract"]),
              let paused = optionalString(o, "paused_reason"), let lastReason = optionalString(o, "last_reason"),
              let created = optionalNumber(o, "created_at"), let updated = optionalNumber(o, "updated_at"),
              let verdictText = optionalString(o, "last_verdict") else { return nil }
        var subgoals: [String] = []
        for value in subgoalValues {
            guard case .string(let s) = value else { return nil }
            subgoals.append(s)
        }
        var gates: [GoalGate] = []
        for value in gateValues {
            guard let gate = parseGate(value) else { return nil }
            gates.append(gate)
        }
        var verdict: GoalVerdict?
        if let verdictText {
            guard let v = GoalVerdict(rawValue: verdictText) else { return nil }
            verdict = v
        }
        var barrier: WaitBarrier?
        if let raw = o["wait_barrier"], raw != .null {
            guard let parsed = parseWaitBarrier(raw) else { return nil }
            barrier = parsed
        }
        return GoalSnapshot(title: title, status: status, turnsUsed: turnsUsed, maxTurns: maxTurns, contract: contract,
                            subgoals: subgoals, gates: gates, createdAt: created, updatedAt: updated, pausedReason: paused,
                            lastVerdict: verdict, lastReason: lastReason, waitBarrier: barrier)
    }

    static func parseContract(_ value: JSONValue?) -> GoalContract? {
        let keys = ["outcome", "verification", "constraints", "boundaries", "stop_when"]
        guard case .object(let o)? = value, exact(o, required: keys) else { return nil }
        var strings: [String] = []
        for key in keys {
            guard case .string(let s)? = o[key] else { return nil }
            strings.append(s)
        }
        return GoalContract(outcome: strings[0], verification: strings[1], constraints: strings[2], boundaries: strings[3], stopWhen: strings[4])
    }

    static func parseGate(_ value: JSONValue) -> GoalGate? {
        guard case .object(let o) = value,
              exact(o, required: ["command", "timeout_seconds", "max_retries", "attempts", "last_exit_code"]),
              case .string(let command)? = o["command"], let timeout = ActivityJSON.int(o["timeout_seconds"]),
              let retries = ActivityJSON.int(o["max_retries"]), let attempts = ActivityJSON.int(o["attempts"]) else { return nil }
        var exit: Int?
        if o["last_exit_code"] != .null {
            guard let code = ActivityJSON.int(o["last_exit_code"]) else { return nil }
            exit = code
        }
        return GoalGate(command: command, timeoutSeconds: timeout, maxRetries: retries, attempts: attempts, lastExitCode: exit)
    }

    static func parseWaitBarrier(_ value: JSONValue) -> WaitBarrier? {
        guard case .object(let o) = value, case .string(let type)? = o["type"] else { return nil }
        switch type {
        case "until":
            guard exact(o, required: ["type", "until_at", "reason"]), let at = ActivityJSON.num(o["until_at"]),
                  case .string(let reason)? = o["reason"] else { return nil }
            return .until(at: at, reason: reason)
        case "session":
            guard exact(o, required: ["type", "target", "reason"]), case .string(let target)? = o["target"],
                  case .string(let reason)? = o["reason"] else { return nil }
            return .session(target: target, reason: reason)
        case "pid":
            guard exact(o, required: ["type", "target", "reason"]), let target = ActivityJSON.int(o["target"]),
                  case .string(let reason)? = o["reason"] else { return nil }
            return .pid(target: target, reason: reason)
        default:
            return nil
        }
    }

    /// `dispatch`: every key present (null allowed).
    static func parseDispatch(_ value: JSONValue?) -> ControlDispatch {
        func s(_ key: String) -> String? { value?[key]?.string }
        return ControlDispatch(type: s("type"), output: s("output"), notice: s("notice"), message: s("message"), display: s("display"))
    }

    // MARK: Words (V:i18n/en.ts:4044-4096)

    enum Tone: Hashable, Sendable { case blocked, done, active, waiting }

    static func tone(_ goal: GoalSnapshot) -> Tone {
        if goal.lastVerdict == .blocked { return .blocked }
        if goal.waitBarrier != nil { return .waiting }
        switch goal.status {
        case .done: return .done
        case .paused: return .waiting
        case .active: return .active
        }
    }

    /// "Goal active · Turn 3/20", "Goal paused · Turn 3", "Goal done · 5 turns", "Goal blocked · Turn 14/20".
    static func chipWords(_ goal: GoalSnapshot) -> String {
        let state: String
        if goal.lastVerdict == .blocked { state = "Goal blocked" }
        else if goal.waitBarrier != nil { state = "Goal waiting" }
        else if goal.status == .paused { state = "Goal paused" }
        else if goal.status == .done { state = "Goal done" }
        else { state = "Goal active" }
        let suffix: String
        if goal.status == .done {
            suffix = " · \(goal.turnsUsed) turn\(goal.turnsUsed == 1 ? "" : "s")"
        } else if goal.maxTurns > 0 {
            suffix = " · Turn \(goal.turnsUsed)/\(goal.maxTurns)"
        } else if goal.turnsUsed > 0 {
            suffix = " · Turn \(goal.turnsUsed)"
        } else {
            suffix = ""
        }
        return state + suffix
    }

    /// The card's reason line: the wait condition, else why it paused, else the judge's last reason.
    static func reason(_ goal: GoalSnapshot) -> String? {
        if let barrier = goal.waitBarrier {
            return barrier.reason.isEmpty ? "Wait condition" : "Wait condition: \(barrier.reason)"
        }
        if let paused = goal.pausedReason, !paused.isEmpty { return paused }
        if let last = goal.lastReason, !last.isEmpty { return last }
        return nil
    }

    static func hasDetails(_ goal: GoalSnapshot) -> Bool {
        !goal.contract.isEmpty || goal.waitBarrier != nil || !goal.gates.isEmpty
    }

    /// The Goal Details sheet's sections, in order (label, body, monospace).
    static func detailSections(_ goal: GoalSnapshot, formatDate: (Double) -> String) -> [(label: String, text: String, mono: Bool)] {
        var out: [(String, String, Bool)] = [("Objective", goal.title, false)]
        let c = goal.contract
        for (label, text) in [("Outcome", c.outcome), ("Verification", c.verification), ("Constraints", c.constraints),
                              ("Boundaries", c.boundaries), ("Stop when", c.stopWhen)] where !text.isEmpty {
            out.append((label, text, false))
        }
        if let barrier = goal.waitBarrier {
            var line: String
            switch barrier {
            case .until(let at, _): line = "Waiting until \(formatDate(at))"
            case .session(let target, _): line = "Waiting on session \(target)"
            case .pid(let target, _): line = "Waiting on process \(target)"
            }
            if !barrier.reason.isEmpty { line += "\n\(barrier.reason)" }
            out.append(("Wait condition", line, false))
        }
        for gate in goal.gates {
            var lines = [gate.command, "\(gate.attempts)/\(gate.maxRetries) attempts", "\(gate.timeoutSeconds)s timeout"]
            lines.append(gate.lastExitCode.map { "Exit code: \($0)" } ?? "Pending")
            out.append(("Quality gates", lines.joined(separator: "\n"), true))
        }
        return out.map { (label: $0.0, text: $0.1, mono: $0.2) }
    }

    /// "Action failed: <message ≤ 240 characters>".
    static func actionFailure(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = trimmed.count > 240 ? String(trimmed.prefix(239)) + "…" : trimmed
        return "Action failed: \(clipped.isEmpty ? "unknown error" : clipped)"
    }
}
