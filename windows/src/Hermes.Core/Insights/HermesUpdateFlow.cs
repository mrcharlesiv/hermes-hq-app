using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Hermes.Core.Insights;

// The pure half of the one Update sheet (HermesKit/Pages/More/HermesUpdateFlow.swift): what the check and the action's
// receipt say, what an update's log lines say about where it is (the bot wait, the install, the restart), how a run of
// status answers turns into steps, and how it ends — "Updated to 0.23.0" only when the version really changed.

/// What an install method (or a refusal code) means, in plain words.
public static class HermesInstallWords
{
    public static string? Method(string? code) => (code ?? "").ToLowerInvariant() switch
    {
        "docker" or "image-marker" or "image-marker-invalid" or "docker_update_unsupported" => "Hermes runs in a Docker container here",
        "apt" or "apt_update_required" => "Hermes was installed with the system’s package manager (APT)",
        "nix" or "nixos" or "nix_update_unsupported" => "Hermes was installed with Nix",
        "commit-build" or "desktop-app" => "Hermes here is a fixed build that came with an app",
        "managed-runtime" or "dashboard_update_managed_externally" => "Hermes here is updated by whatever runs it",
        "update_not_in_place" => "Hermes here wasn’t installed in a way it can update itself",
        _ => null,
    };
}

/// The receipt summary (`receipt` on the action status, `summary` on `/api/hermes/update/receipt`).
public sealed record HermesUpdateReceipt
{
    public sealed record Followup(string Step, string Reason);

    /// running | success | partial | failed | refused | interrupted.
    public string? Outcome { get; init; }
    public string? ActionId { get; init; }
    public string? PreSha { get; init; }
    public string? PostSha { get; init; }
    public string? PostVersion { get; init; }
    public IReadOnlyList<Followup> Followups { get; init; } = [];
    public string? UserAction { get; init; }

    public static HermesUpdateReceipt? Parse(JsonNode? json)
    {
        if (json is not JsonObject) return null;
        var action = json.Get("user_action");
        var user = action is JsonObject ? action.Str("reason") : J.AsString(action);
        var post = json.Str("post_version") ?? json.Get("post_update").Str("version");
        return new HermesUpdateReceipt
        {
            Outcome = json.Str("outcome")?.ToLowerInvariant(),
            ActionId = json.Str("action_id"),
            PreSha = json.Str("pre_sha") ?? json.Get("pre_update").Str("sha"),
            PostSha = json.Str("post_sha") ?? json.Get("post_update").Str("sha"),
            PostVersion = string.IsNullOrEmpty(post) ? null : post,
            Followups = [.. (json.Arr("followups") ?? []).Select(i => i.Str("step") is { Length: > 0 } s ? new Followup(s, i.Str("reason") ?? "") : null).OfType<Followup>()],
            UserAction = string.IsNullOrEmpty(user) ? null : user,
        };
    }

    public bool Succeeded => Outcome is "success" or "partial";
    public bool Failed => Outcome is "failed" or "interrupted";
    public bool Refused => Outcome == "refused";

    /// What's still owed after a committed run, in one line: the person's own step first.
    public string? Owed => UserAction ?? (Followups.Count > 0 ? (Followups[0].Reason.Length == 0 ? Followups[0].Step : Followups[0].Reason) : null);
}

/// `POST /api/hermes/update` answered `ok:false`: the gateway won't update itself here.
public sealed class HermesUpdateRefusal(string code, string message, string? command) : Exception(message)
{
    public string Code { get; } = code;
    public string? Command { get; } = string.IsNullOrEmpty(command) ? null : command;

    public static HermesUpdateRefusal? Parse(JsonNode? json)
    {
        if (json.Bool("ok") != false) return null;
        return new HermesUpdateRefusal(json.Str("error") ?? "", json.Str("message") ?? json.Str("error") ?? "The gateway couldn’t start the update.",
            json.Str("update_command"));
    }
}

/// The bots an update is waiting on before it may stop their gateway.
public sealed record HermesUpdateDrain(IReadOnlyList<string> Profiles, int Budget, int? Left, int? Units, bool Over)
{
    public bool Same(HermesUpdateDrain? o) => o != null && o.Budget == Budget && o.Profiles.SequenceEqual(Profiles);
}

public static partial class HermesUpdateLog
{
    /// Where an update is, from its own lines.
    public enum Stage { Check, Drain, Install, Restart, Done }

    /// A gateway's label in a drain line → its profile name, null when the label names none.
    public static string? Profile(string label)
    {
        var name = label.Trim();
        foreach (var suffix in new[] { ".service", ".plist" })
            if (name.EndsWith(suffix, StringComparison.Ordinal)) name = name[..^suffix.Length];
        foreach (var prefix in new[] { "ai.hermes.gateway", "hermes-gateway" })
        {
            if (!name.StartsWith(prefix, StringComparison.Ordinal)) continue;
            var rest = name[prefix.Length..];
            if (rest.Length == 0) return "default";
            if (rest[0] is '-' or '@' or '.')
            {
                var profile = rest[1..];
                return profile.Length == 0 ? "default" : profile;
            }
        }
        return null;
    }

    private static bool IsDrainDetail(string line)
    {
        var text = line.Trim();
        return text.Length == 0 || text.StartsWith('•') || text.Contains("still draining") || text.StartsWith("waiting on ")
            || text.StartsWith("finish or kill") || text.Contains("draining (up to") || text.Contains("for in-flight turns on");
    }

    [GeneratedRegex(@"Waiting up to (\d+)s for in-flight turns on (.+?) to finish")] private static partial Regex WaitRx();
    [GeneratedRegex(@"→ (\S+): draining \(up to (\d+)s\)")] private static partial Regex FleetRx();
    [GeneratedRegex(@"still draining\D+(\d+)s left")] private static partial Regex LeftRx();
    [GeneratedRegex(@"waiting on (\d+) active work unit")] private static partial Regex UnitsRx();
    [GeneratedRegex(@"Update complete!\s*\(v?([^\s)]+)\s*→\s*v?([^\s)]+)\)")] private static partial Regex CompleteRx();

    private static int ToInt(string s) => int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var n) ? n : 0;

    /// The wait for bots, if one started.
    public static HermesUpdateDrain? Drain(IReadOnlyList<string> lines)
    {
        HermesUpdateDrain? drain = null;
        var last = -1;
        for (var i = 0; i < lines.Count; i++)
        {
            var line = lines[i];
            Match m;
            if ((m = WaitRx().Match(line)).Success)
            {
                var labels = m.Groups[2].Value.Split(',').Select(s => s.Trim()).Where(s => s.Length > 0);
                var profiles = labels.Select(l => Profile(l) ?? l).ToList();
                drain = new HermesUpdateDrain(Merge(drain is { Over: false } ? drain.Profiles : [], profiles), ToInt(m.Groups[1].Value), null, null, false);
                last = i;
            }
            else if ((m = FleetRx().Match(line)).Success)
            {
                var name = Profile(m.Groups[1].Value) ?? m.Groups[1].Value;
                var budget = ToInt(m.Groups[2].Value);
                drain = drain is { Over: false } open
                    ? open with { Profiles = Merge(open.Profiles, [name]), Budget = Math.Max(open.Budget, budget) }
                    : new HermesUpdateDrain([name], budget, null, null, false);
                last = i;
            }
            else if (drain != null && (m = LeftRx().Match(line)).Success)
            {
                drain = drain with { Left = ToInt(m.Groups[1].Value) };
                last = i;
            }
            else if (drain != null && (m = UnitsRx().Match(line)).Success)
            {
                drain = drain with { Units = ToInt(m.Groups[1].Value) };
                last = i;
            }
        }
        if (drain != null && lines.Skip(last + 1).Any(l => !IsDrainDetail(l))) drain = drain with { Over = true };
        return drain;
    }

    private static List<string> Merge(IEnumerable<string> a, IEnumerable<string> b)
    {
        var out_ = a.ToList();
        foreach (var n in b) if (!out_.Contains(n)) out_.Add(n);
        return out_;
    }

    private static readonly string[] InstallSigns = ["⏸ Paused", "Restoring local changes", "Preparing Node", "Building the", "Syncing bundled skills",
        "Checking configuration", "stale __pycache__", "Installing", "dependencies", "Refreshed installer", "Updating config format", "Model catalog cache"];
    private static readonly string[] RestartSigns = ["Restarted paused gateway", "Restarting gateway", "Restarted ", "⟲ Stopping",
        "=== hermes-update completed", "Update complete!", "Fleet version check", "Handed gateway profile"];

    /// The furthest stage the lines show.
    public static Stage StageOf(IReadOnlyList<string> lines)
    {
        var stage = Stage.Check;
        if (Drain(lines) is { } d) stage = d.Over ? Stage.Install : Stage.Drain;
        foreach (var line in lines)
        {
            if (RestartSigns.Any(line.Contains)) stage = Max(stage, Stage.Restart);
            else if (InstallSigns.Any(line.Contains)) stage = Max(stage, Stage.Install);
        }
        return stage;
    }

    public static Stage Max(Stage a, Stage b) => a > b ? a : b;

    /// "✓ Update complete! (v0.22.2 → v0.22.5)" → ("0.22.2", "0.22.5").
    public static (string From, string To)? Completed(IReadOnlyList<string> lines)
    {
        for (var i = lines.Count - 1; i >= 0; i--)
            if (CompleteRx().Match(lines[i]) is { Success: true } m) return (m.Groups[1].Value, m.Groups[2].Value);
        return null;
    }

    /// Why a run failed, in Hermes's own words: its last "✗" line, else its last line.
    public static string? Failure(IReadOnlyList<string> lines)
    {
        var trimmed = lines.Select(l => l.Trim()).Where(l => l.Length > 0 && !l.StartsWith("===", StringComparison.Ordinal)).ToList();
        var cross = trimmed.LastOrDefault(l => l.StartsWith('✗') || l.StartsWith('✘') || l.StartsWith("Error", StringComparison.Ordinal));
        if (cross != null) return cross.TrimStart('✗', '✘', ' ');
        return trimmed.LastOrDefault();
    }
}

public enum HermesUpdateStepId { Check, Drain, Install, Restart, Confirm }

public enum HermesUpdateStepState { Waiting, Active, Done, Skipped, Failed }

/// How a run of status answers turns into the gateway update's steps.
public sealed class HermesUpdateProgress
{
    public HermesUpdateLog.Stage Stage { get; private set; } = HermesUpdateLog.Stage.Check;
    public HermesUpdateDrain? Drain { get; private set; }
    public DateTimeOffset? DrainSeenAt { get; private set; }
    public DateTimeOffset? DrainDeadline { get; private set; }
    public bool SawGap { get; private set; }
    public int? ExitCode { get; private set; }
    public bool Finished { get; private set; }
    public HermesUpdateReceipt? Receipt { get; private set; }
    public IReadOnlyList<string> Lines { get; private set; } = [];

    public void Read(GatewayActionStatus status, DateTimeOffset? at = null)
    {
        var now = at ?? DateTimeOffset.Now;
        if (status.Lines.Count > 0) Lines = status.Lines;
        if (status.Receipt != null) Receipt = status.Receipt;
        var next = HermesUpdateLog.StageOf(Lines);
        if (HermesUpdateLog.Drain(Lines) is { } found)
        {
            if (Drain == null || !found.Same(Drain)) { DrainSeenAt = now; DrainDeadline = now.AddSeconds(found.Budget); }
            if (found.Left is { } left && left != Drain?.Left) DrainDeadline = now.AddSeconds(left);
            Drain = found;
        }
        // Back after a gap the install had started: the restart happened.
        if (SawGap && (next >= HermesUpdateLog.Stage.Install || Stage >= HermesUpdateLog.Stage.Install))
            next = HermesUpdateLog.Max(next, HermesUpdateLog.Stage.Restart);
        if (!status.Running && (status.ExitCode != null || (status.Receipt?.Outcome is { } o && o != "running")))
        {
            Finished = true;
            ExitCode = status.ExitCode ?? (status.Receipt?.Succeeded == true ? 0 : 1);
            // A failed run stays on the step it stopped on.
            if (ExitCode == 0 && Receipt?.Failed != true) next = HermesUpdateLog.Stage.Done;
        }
        Stage = HermesUpdateLog.Max(Stage, next);
    }

    public void Unanswered()
    {
        if (Stage >= HermesUpdateLog.Stage.Install || Drain?.Over == true) SawGap = true;
    }

    /// The drain didn't happen: skipped once the install is under way without one.
    public bool DrainSkipped => Drain == null && Stage >= HermesUpdateLog.Stage.Install;

    public HermesUpdateStepState State(HermesUpdateStepId step)
    {
        var mine = step switch
        {
            HermesUpdateStepId.Check => HermesUpdateLog.Stage.Check,
            HermesUpdateStepId.Drain => HermesUpdateLog.Stage.Drain,
            HermesUpdateStepId.Install => HermesUpdateLog.Stage.Install,
            HermesUpdateStepId.Restart => HermesUpdateLog.Stage.Restart,
            _ => HermesUpdateLog.Stage.Done,
        };
        if (step == HermesUpdateStepId.Drain && DrainSkipped) return HermesUpdateStepState.Skipped;
        if (step == HermesUpdateStepId.Confirm) return Finished ? HermesUpdateStepState.Active : HermesUpdateStepState.Waiting;
        if (Stage > mine) return HermesUpdateStepState.Done;
        if (step == HermesUpdateStepId.Check) return HermesUpdateStepState.Done;
        return Stage == mine ? HermesUpdateStepState.Active : HermesUpdateStepState.Waiting;
    }

    /// The drain step's line: "Finishing replies on Finance and Gym · up to 32 min".
    public string? DrainDetail(Func<string, string> names, DateTimeOffset? now = null)
    {
        if (Drain is not { Over: false } drain) return null;
        var who = HermesUpdateWords.List([.. drain.Profiles.Select(names)]);
        var line = who.Length == 0 ? "Finishing replies" : $"Finishing replies on {who}";
        if (DrainDeadline is { } deadline)
            line += " · up to " + HermesUpdateWords.Minutes(Math.Max(0, (deadline - (now ?? DateTimeOffset.Now)).TotalSeconds));
        return line;
    }
}

/// How an update ended.
public abstract record HermesUpdateEnd
{
    /// The version really changed (read back from `/api/status`).
    public sealed record Updated(string To) : HermesUpdateEnd;
    public sealed record UpToDate(string? Version) : HermesUpdateEnd;
    /// This gateway can't update itself: what it is, and what to run instead (null: nothing there can).
    public sealed record CantUpdateHere(string Method, string? Command) : HermesUpdateEnd;
    public sealed record Unchanged(string? Version) : HermesUpdateEnd;
    public sealed record Unconfirmed : HermesUpdateEnd;
    public sealed record Failed(string Reason) : HermesUpdateEnd;

    /// How a finished gateway update ended. `before`: the version before; `after`: `/api/status` now (null: no answer).
    public static HermesUpdateEnd Gateway(int? exitCode, HermesUpdateReceipt? receipt, string? before, string? after, IReadOnlyList<string> lines)
    {
        if (after != null && before != null && !VersionsMatch(after, before)) return new Updated(after);
        var ok = receipt?.Succeeded ?? exitCode == 0;
        if (ok && receipt?.Failed != true)
        {
            if (after == null) return new Unconfirmed();
            if (before == null)
            {
                if (receipt is { PreSha: { } pre, PostSha: { } post } && pre != post && receipt.PostVersion is { } pv && VersionsMatch(pv, after))
                    return new Updated(after);
                return new Unconfirmed();
            }
            return new Unchanged(after);
        }
        var reason = receipt?.Owed ?? HermesUpdateLog.Failure(lines) ?? (exitCode is { } x ? $"Hermes stopped with an error (exit {x})." : null);
        return new Failed(reason ?? "The update didn’t finish.");
    }

    /// Reading the version after the run ended, still the old one: give up early only when Hermes said it failed.
    public static bool StopsReading(int attempt, int? exitCode) => exitCode is { } x && attempt >= 3 && x != 0;

    /// "v0.22.5" and "0.22.5" are the same.
    public static bool VersionsMatch(string a, string b) => Normalized(a) == Normalized(b);

    public static string Normalized(string version)
    {
        var text = version.Trim().ToLowerInvariant();
        if (text.StartsWith("hermes ", StringComparison.Ordinal)) text = text[7..];
        if (text.StartsWith('v')) text = text[1..];
        return text;
    }
}

public static class HermesUpdateWords
{
    /// "Finance", "Finance and Gym", "Finance, Gym and Home".
    public static string List(IReadOnlyList<string> names) => names.Count switch
    {
        0 => "",
        1 => names[0],
        _ => string.Join(", ", names.Take(names.Count - 1)) + " and " + names[^1],
    };

    /// "32 min", "1 hr 5 min", "under a minute".
    public static string Minutes(double seconds)
    {
        var total = (int)Math.Ceiling(seconds / 60);
        if (total < 1) return "under a minute";
        if (total < 60) return $"{total} min";
        int hours = total / 60, rest = total % 60;
        return rest == 0 ? $"{hours} hr" : $"{hours} hr {rest} min";
    }

    /// "0.22.5 → 0.23.0" (either side may be missing).
    public static string? Versions(string? from, string? to)
    {
        var a = from == null ? null : HermesUpdateEnd.Normalized(from);
        var b = to == null ? null : HermesUpdateEnd.Normalized(to);
        if (a != null && b != null && a != b) return $"{a} → {b}";
        if (a != null) return a;
        if (b != null) return $"→ {b}";
        return null;
    }

    /// "0:42", "1:02:03" (CloudCopy.elapsed).
    public static string Elapsed(int seconds)
    {
        seconds = Math.Max(0, seconds);
        if (seconds < 3600) return $"{seconds / 60}:{seconds % 60:00}";
        return $"{seconds / 3600}:{seconds / 60 % 60:00}:{seconds % 60:00}";
    }
}

/// The update's routes, on any gateway REST.
public sealed class HermesUpdateApi(IGatewayRest rest)
{
    public IGatewayRest Rest { get; } = rest;

    public async Task<HermesUpdateCheck> CheckAsync(bool force) =>
        HermesUpdateCheck.Parse(await Rest.JsonAsync(HttpMethod.Get, "/api/hermes/update/check", force ? [new("force", "true")] : null, null, TimeSpan.FromSeconds(45)));

    /// `POST /api/hermes/update` → the action's name; throws HermesUpdateRefusal for `ok:false`.
    public async Task<string> StartAsync()
    {
        var answer = await Rest.JsonAsync(HttpMethod.Post, "/api/hermes/update", null, null, TimeSpan.FromSeconds(30));
        if (HermesUpdateRefusal.Parse(answer) is { } refusal) throw refusal;
        return answer.Str("name") ?? "hermes-update";
    }

    public async Task<GatewayActionStatus> StatusAsync(string name = "hermes-update", CancellationToken ct = default) =>
        GatewayActionStatus.Parse(await Rest.JsonAsync(HttpMethod.Get, $"/api/actions/{Uri.EscapeDataString(name)}/status", [new("lines", "200")], null,
            TimeSpan.FromSeconds(10), ct), name);

    /// `GET /api/hermes/update/receipt` → its summary (null: none yet, or an older Hermes).
    public async Task<HermesUpdateReceipt?> ReceiptAsync()
    {
        try
        {
            var answer = await Rest.JsonAsync(HttpMethod.Get, "/api/hermes/update/receipt", null, null, TimeSpan.FromSeconds(10));
            return HermesUpdateReceipt.Parse(answer.Get("summary")) ?? HermesUpdateReceipt.Parse(answer.Get("receipt"));
        }
        catch (Exception) { return null; }
    }

    /// `GET /api/status`'s version (null: no answer).
    public async Task<string?> VersionAsync()
    {
        try
        {
            var answer = await Rest.JsonAsync(HttpMethod.Get, "/api/status", null, null, TimeSpan.FromSeconds(10));
            return answer.Str("version") is { Length: > 0 } v ? v : null;
        }
        catch (Exception) { return null; }
    }
}
