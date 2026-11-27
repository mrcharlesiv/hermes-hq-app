using System.Text.Json.Nodes;

namespace Hermes.Core.Activity;

// The goal snapshot (docs/spec/1x-activity.md §6), port of HermesKit/Activity/ControlRules.swift: a strict parse of
// `SessionControlSnapshot` in the web's `hasExactFields` discipline — a missing or mistyped required field, or an unknown
// key, drops the whole snapshot — and the chip / card words. One leniency: an optional key present with `null` reads as
// absent.

public enum GoalTone { Blocked, Done, Active, Waiting }

public sealed record GoalDetailSection(string Label, string Text, bool Mono);

public static class ControlRules
{
    private static bool Exact(JsonObject o, string[] required, string[]? optional = null)
    {
        var allowed = new HashSet<string>(required.Concat(optional ?? []), StringComparer.Ordinal);
        return required.All(o.ContainsKey) && o.Select(kv => kv.Key).All(allowed.Contains);
    }

    /// Optional key: absent or null → (true, null); present and a string → (true, value); else (false, _).
    private static (bool Ok, string? Value) OptionalString(JsonObject o, string key) =>
        o[key] is null ? (true, null) : ActivityJson.StrOrNull(o[key]) is { } s ? (true, s) : (false, null);

    private static (bool Ok, double? Value) OptionalNumber(JsonObject o, string key) =>
        o[key] is null ? (true, null) : ActivityJson.Num(o[key]) is { } n ? (true, n) : (false, null);

    public static ControlSnapshot? ParseSnapshot(JsonNode? value)
    {
        if (value is not JsonObject o || !Exact(o, ["goal", "loop", "heartbeat", "revision", "updated_at"])
            || ActivityJson.StrOrNull(o["revision"]) is not { } revision || ActivityJson.Num(o["updated_at"]) is not { } updatedAt)
            return null;
        GoalSnapshot? goal = null;
        if (o["goal"] is not null)
        {
            if (ParseGoal(o["goal"]) is not { } parsed) return null;
            goal = parsed;
        }
        // loop / heartbeat: shape-checked only as objects (they are out of scope, kept raw).
        var loop = o["loop"];
        var heartbeat = o["heartbeat"];
        if (loop is not null and not JsonObject) return null;
        if (heartbeat is not null and not JsonObject) return null;
        return new ControlSnapshot(goal, loop?.DeepClone(), heartbeat?.DeepClone(), revision, updatedAt);
    }

    public static GoalSnapshot? ParseGoal(JsonNode? value)
    {
        string[] required = ["title", "status", "turns_used", "max_turns", "contract", "subgoals", "gates"];
        string[] optional = ["created_at", "updated_at", "paused_reason", "last_verdict", "last_reason", "wait_barrier"];
        if (value is not JsonObject o || !Exact(o, required, optional)
            || ActivityJson.StrOrNull(o["title"]) is not { } title
            || ParseGoalStatus(ActivityJson.StrOrNull(o["status"])) is not { } status
            || ActivityJson.Int(o["turns_used"]) is not { } turnsUsed || ActivityJson.Int(o["max_turns"]) is not { } maxTurns
            || o["subgoals"] is not JsonArray subgoalValues || o["gates"] is not JsonArray gateValues
            || ParseContract(o["contract"]) is not { } contract)
            return null;
        var paused = OptionalString(o, "paused_reason");
        var lastReason = OptionalString(o, "last_reason");
        var created = OptionalNumber(o, "created_at");
        var updated = OptionalNumber(o, "updated_at");
        var verdictText = OptionalString(o, "last_verdict");
        if (!paused.Ok || !lastReason.Ok || !created.Ok || !updated.Ok || !verdictText.Ok) return null;
        var subgoals = new List<string>();
        foreach (var v in subgoalValues)
        {
            if (ActivityJson.StrOrNull(v) is not { } s) return null;
            subgoals.Add(s);
        }
        var gates = new List<GoalGate>();
        foreach (var v in gateValues)
        {
            if (ParseGate(v) is not { } gate) return null;
            gates.Add(gate);
        }
        GoalVerdict? verdict = null;
        if (verdictText.Value is { } vt)
        {
            if (ParseVerdict(vt) is not { } parsedVerdict) return null;
            verdict = parsedVerdict;
        }
        WaitBarrier? barrier = null;
        if (o["wait_barrier"] is { } raw)
        {
            if (ParseWaitBarrier(raw) is not { } parsedBarrier) return null;
            barrier = parsedBarrier;
        }
        return new GoalSnapshot
        {
            Title = title, Status = status, TurnsUsed = turnsUsed, MaxTurns = maxTurns, Contract = contract,
            Subgoals = new(subgoals), Gates = new(gates), CreatedAt = created.Value, UpdatedAt = updated.Value,
            PausedReason = paused.Value, LastVerdict = verdict, LastReason = lastReason.Value, WaitBarrier = barrier,
        };
    }

    public static GoalStatus? ParseGoalStatus(string? raw) => raw switch
    {
        "active" => GoalStatus.Active,
        "paused" => GoalStatus.Paused,
        "done" => GoalStatus.Done,
        _ => null,
    };

    public static GoalVerdict? ParseVerdict(string? raw) => raw switch
    {
        "blocked" => GoalVerdict.Blocked,
        "continue" => GoalVerdict.Continue,
        "done" => GoalVerdict.Done,
        "skipped" => GoalVerdict.Skipped,
        "wait" => GoalVerdict.Wait,
        _ => null,
    };

    public static GoalContract? ParseContract(JsonNode? value)
    {
        string[] keys = ["outcome", "verification", "constraints", "boundaries", "stop_when"];
        if (value is not JsonObject o || !Exact(o, keys)) return null;
        var strings = new List<string>();
        foreach (var key in keys)
        {
            if (ActivityJson.StrOrNull(o[key]) is not { } s) return null;
            strings.Add(s);
        }
        return new GoalContract(strings[0], strings[1], strings[2], strings[3], strings[4]);
    }

    public static GoalGate? ParseGate(JsonNode? value)
    {
        if (value is not JsonObject o || !Exact(o, ["command", "timeout_seconds", "max_retries", "attempts", "last_exit_code"])
            || ActivityJson.StrOrNull(o["command"]) is not { } command || ActivityJson.Int(o["timeout_seconds"]) is not { } timeout
            || ActivityJson.Int(o["max_retries"]) is not { } retries || ActivityJson.Int(o["attempts"]) is not { } attempts)
            return null;
        int? exit = null;
        if (o["last_exit_code"] is not null)
        {
            if (ActivityJson.Int(o["last_exit_code"]) is not { } code) return null;
            exit = code;
        }
        return new GoalGate(command, timeout, retries, attempts, exit);
    }

    public static WaitBarrier? ParseWaitBarrier(JsonNode? value)
    {
        if (value is not JsonObject o || ActivityJson.StrOrNull(o["type"]) is not { } type) return null;
        switch (type)
        {
            case "until":
                if (!Exact(o, ["type", "until_at", "reason"]) || ActivityJson.Num(o["until_at"]) is not { } at
                    || ActivityJson.StrOrNull(o["reason"]) is not { } r1) return null;
                return new WaitUntil(at, r1);
            case "session":
                if (!Exact(o, ["type", "target", "reason"]) || ActivityJson.StrOrNull(o["target"]) is not { } target
                    || ActivityJson.StrOrNull(o["reason"]) is not { } r2) return null;
                return new WaitSession(target, r2);
            case "pid":
                if (!Exact(o, ["type", "target", "reason"]) || ActivityJson.Int(o["target"]) is not { } pid
                    || ActivityJson.StrOrNull(o["reason"]) is not { } r3) return null;
                return new WaitPid(pid, r3);
            default:
                return null;
        }
    }

    /// `dispatch`: every key present (null allowed).
    public static ControlDispatch ParseDispatch(JsonNode? value)
    {
        string? S(string key) => ActivityJson.StrOrNull(value.Get(key));
        return new ControlDispatch(S("type"), S("output"), S("notice"), S("message"), S("display"));
    }

    // MARK: Words (V:i18n/en.ts:4044-4096)

    public static GoalTone Tone(GoalSnapshot goal)
    {
        if (goal.LastVerdict == GoalVerdict.Blocked) return GoalTone.Blocked;
        if (goal.WaitBarrier is not null) return GoalTone.Waiting;
        return goal.Status switch
        {
            GoalStatus.Done => GoalTone.Done,
            GoalStatus.Paused => GoalTone.Waiting,
            _ => GoalTone.Active,
        };
    }

    /// "Goal active · Turn 3/20", "Goal paused · Turn 3", "Goal done · 5 turns", "Goal blocked · Turn 14/20".
    public static string ChipWords(GoalSnapshot goal)
    {
        string state;
        if (goal.LastVerdict == GoalVerdict.Blocked) state = "Goal blocked";
        else if (goal.WaitBarrier is not null) state = "Goal waiting";
        else if (goal.Status == GoalStatus.Paused) state = "Goal paused";
        else if (goal.Status == GoalStatus.Done) state = "Goal done";
        else state = "Goal active";
        string suffix;
        if (goal.Status == GoalStatus.Done) suffix = $" · {goal.TurnsUsed} turn{(goal.TurnsUsed == 1 ? "" : "s")}";
        else if (goal.MaxTurns > 0) suffix = $" · Turn {goal.TurnsUsed}/{goal.MaxTurns}";
        else if (goal.TurnsUsed > 0) suffix = $" · Turn {goal.TurnsUsed}";
        else suffix = "";
        return state + suffix;
    }

    /// The card's reason line: the wait condition, else why it paused, else the judge's last reason.
    public static string? Reason(GoalSnapshot goal)
    {
        if (goal.WaitBarrier is { } barrier)
            return barrier.Reason.Length == 0 ? "Wait condition" : $"Wait condition: {barrier.Reason}";
        if (!string.IsNullOrEmpty(goal.PausedReason)) return goal.PausedReason;
        if (!string.IsNullOrEmpty(goal.LastReason)) return goal.LastReason;
        return null;
    }

    public static bool HasDetails(GoalSnapshot goal) => !goal.Contract.IsEmpty || goal.WaitBarrier is not null || goal.Gates.Count > 0;

    /// The Goal Details sheet's sections, in order.
    public static List<GoalDetailSection> DetailSections(GoalSnapshot goal, Func<double, string> formatDate)
    {
        var output = new List<GoalDetailSection> { new("Objective", goal.Title, false) };
        var c = goal.Contract;
        foreach (var (label, text) in new[] { ("Outcome", c.Outcome), ("Verification", c.Verification), ("Constraints", c.Constraints),
                     ("Boundaries", c.Boundaries), ("Stop when", c.StopWhen) })
            if (text.Length > 0) output.Add(new(label, text, false));
        if (goal.WaitBarrier is { } barrier)
        {
            var line = barrier switch
            {
                WaitUntil u => $"Waiting until {formatDate(u.At)}",
                WaitSession s => $"Waiting on session {s.Target}",
                WaitPid p => $"Waiting on process {p.Target}",
                _ => "",
            };
            if (barrier.Reason.Length > 0) line += "\n" + barrier.Reason;
            output.Add(new("Wait condition", line, false));
        }
        foreach (var gate in goal.Gates)
        {
            var lines = new List<string> { gate.Command, $"{gate.Attempts}/{gate.MaxRetries} attempts", $"{gate.TimeoutSeconds}s timeout" };
            lines.Add(gate.LastExitCode is { } code ? $"Exit code: {code}" : "Pending");
            output.Add(new("Quality gates", string.Join("\n", lines), true));
        }
        return output;
    }

    /// "Action failed: &lt;message ≤ 240 characters&gt;".
    public static string ActionFailure(string message)
    {
        var trimmed = message.Trim();
        var clipped = ActivityJson.Length(trimmed) > 240 ? ActivityJson.Prefix(trimmed, 239) + "…" : trimmed;
        return $"Action failed: {(clipped.Length == 0 ? "unknown error" : clipped)}";
    }
}
