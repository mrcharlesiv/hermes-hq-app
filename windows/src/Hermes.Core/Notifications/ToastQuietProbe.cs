using System.Text.Json.Nodes;

namespace Hermes.Core.Notifications;

public enum QuietPoint { BeforeFirst, BeforeAway, AfterAway, Entry }
public enum QuietChat { A, B }
// A single read of the already-required predicate. Only Verified permits continuation. A throwing
// getter is unreadable, not evidence of a mismatch. Names are the fixed diagnostic vocabulary.
public enum QuietForeground
{
    Unreadable, ExpectedChatUnknown, WindowMissing, NotUiThread, SheetShown, ContentNotElement, RootMissing,
    ShellMissing, ShellNotLoaded, ShellRootMismatch, ShellStateMissing, ShellOffline, NotChatPane, ShellChatMismatch,
    ChatMissing, ChatNotLoaded, ChatIdMismatch, ChatRootMismatch, ChatNotTracked, OpenPopup,
    ComposerNotTextBox, ComposerDisabled, ComposerNotVisible, ComposerNotFocused, OwnedHandleMissing,
    ForegroundNotOwned, Verified,
}
public readonly record struct QuietProfileRead(int Status, uint Bytes, uint Stamp, uint Profile);
public delegate bool ReplyWalkBinding(bool requireTrackedA);

/// The entire desktop capability of this diagnostic: four getters. No setter, launcher or action callback.
public interface IQuietReader
{
    QuietForeground ReadFixtureForeground(QuietChat expected);
    int? ReadQuns();
    QuietProfileRead? ReadFocus();
    string? ReadAppSetting();
}

internal sealed record QuietReading(string Reason, string Line, (string Run, string Sha)? Push, QuietForeground? FailedForeground);

/// A terminal non-pass, not an ordinary failed screenshot to capture or retry. Both words are fixed by the probe.
public sealed class QuietWalkStopped : Exception
{
    internal QuietWalkStopped(string phase, string reason) : base(reason) => StopLine = $"toast-quiet-stop/v1 phase={phase} gap={reason}";
    public string StopLine { get; }
    public static QuietWalkStopped RouteNotUnique() => new("dispatch", "route-not-unique");
    public static QuietWalkStopped Incomplete() => new("walk", "reply-walk-incomplete");
    public static QuietWalkStopped UnreadablePlan() => new("plan", "plan-unreadable");
}

/// The OS decides whether to draw a banner (NotificationHub.swift, present). This is a diagnostic for a single
/// synthetic Windows walk, not a change to that decision. Even a completely clear sample is NOT a banner witness.
public sealed class ToastQuietProbe(bool windows, Func<string, string?> env, ReplyWalkBinding currentWalk,
    IQuietReader reader, Action<string> note)
{
    private const string Mirror = "mrcharlesiv/hermes-hq-windows", Ref = "refs/heads/feat/windows";
    private const string Fixture = "http://127.0.0.1:9736", FixtureUser = "toast-fixture";
    private (string Run, string Sha)? boundPush;
    private QuietPoint? next = QuietPoint.Entry;
    private QuietWalkStopped? stopped;
    private QuietChat expectedSource = QuietChat.B; // Entry requires B; never inferred from the window.

    private static (string Run, string Sha)? Runner(Func<string, string?> env)
    {
        if (env("GITHUB_ACTIONS") != "true" || env("RUNNER_OS") != "Windows" || env("RUNNER_ENVIRONMENT") != "github-hosted"
            || env("GITHUB_SERVER_URL") != "https://github.com" || env("GITHUB_REPOSITORY") != Mirror
            || env("GITHUB_EVENT_NAME") != "push" || env("GITHUB_REF") != Ref || env("GITHUB_WORKFLOW") != "windows"
            || env("GITHUB_WORKFLOW_REF") != Mirror + "/.github/workflows/windows.yml@" + Ref || env("GITHUB_JOB") != "build"
            || env("HQW_PRIVATE_MIRROR") != "true" || env("HQW_DESKTOP_PROOF") != "1" || env("HQW_APP_PROOF") != null) return null;
        // Cross-check the push event (six non-secret fields projected by the reviewed workflow; no event file,
        // credentials or network). Neither a private marker nor the name of the mirror alone is sufficient.
        var sha = env("GITHUB_SHA");
        if (sha is not { Length: 40 } || !sha.All(c => char.IsAsciiDigit(c) || c is >= 'a' and <= 'f') || sha.All(c => c == '0')
            || sha != env("GITHUB_WORKFLOW_SHA") || env("HQW_QUIET_PUSH") != $"{Mirror}|true|false|{Ref}|{sha}|false") return null;
        var run = env("GITHUB_RUN_ID"); var attempt = env("GITHUB_RUN_ATTEMPT");
        static bool Number(string? s) => s is { Length: > 0 and <= 20 } && s[0] != '0' && s.All(char.IsAsciiDigit);
        return Number(run) && Number(attempt) ? ($"{run}.{attempt}", sha) : null;
    }

    private static string? Text(JsonNode? n) => n is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;

    /// Pure pre-launch check for the existing full-run supervisor guard. Does not read a plan, a window or settings.
    public static void RequireRunner(bool windows, Func<string, string?> env)
    {
        if (!windows) throw new QuietWalkStopped("runner", "non-windows");
        if (Or(() => Runner(env), null) == null) throw new QuietWalkStopped("runner", "runner-not-authorized");
    }

    /// Before the full run touches its desktop or adopts any fixture. Not a substitute for checking the live selection.
    public static void RequirePlan(bool windows, Func<string, string?> env, JsonNode? config)
    {
        RequireRunner(windows, env);
        if (!Or(() => config is JsonObject obj && obj["extras"] is JsonArray { Count: > 0 and <= 128 } extras
            && IsReplySelection(extras[^1], "toasts"), false)) throw new QuietWalkStopped("plan", "not-reply-walk");
    }

    /// Check the dispatcher's actual selected node AND live session, not an invented receipt or just a loopback port.
    public static bool IsReplyWalk<T>(JsonNode? config, JsonNode? extra, string? walk, string? liveUrl, string? liveUser,
        T? boundSession, T? currentSession, int? pendingRequests) where T : class =>
        boundSession != null && ReferenceEquals(boundSession, currentSession) && pendingRequests == 0
        && liveUrl == Fixture && liveUser == FixtureUser && config != null && ReferenceEquals(config, extra?.Parent?.Parent)
        && IsReplySelection(extra, walk);

    private static bool IsReplySelection(JsonNode? extra, string? walk)
    {
        if (walk != "toasts"
            || extra is not JsonObject { Parent: JsonArray { Count: > 0 and <= 128 } extras } selected
            || extras.Parent is not JsonObject { Parent: null } config || !ReferenceEquals(config["extras"], extras)
            || !ReferenceEquals(extras[^1], selected) || Text(config["url"]) != "http://127.0.0.1:9711"
            || (config.ContainsKey("extrasOnly") && !(config["extrasOnly"] is JsonValue v && v.TryGetValue<bool>(out var b) && !b))
            || Text(selected["url"]) != Fixture || Text(selected["username"]) != FixtureUser || Text(selected["tag"]) != "toasts"
            || selected["places"] is not JsonArray { Count: 0 } || selected["walks"] is not JsonArray { Count: 1 } names
            || Text(names[0]) != walk) return false;
        // No alternate spelling of this endpoint elsewhere in the plan. The full desktop walk's other fixtures
        // have literal loopback origins at ports 9700..9899; never normalize paths, aliases, userinfo or queries.
        for (int i = 0; i < extras.Count - 1; i++)
        {
            if (extras[i] is not JsonObject other || Text(other["tag"]) is not { Length: > 0 } tag || tag == "toasts"
                || Text(other["url"]) is not { } url || url == Fixture || !OtherFixtureOrigin(url)
                || other["walks"] is not JsonArray { Count: <= 128 } walks || walks.Any(n => Text(n) is not { } name || name == walk)) return false;
        }
        return true;
    }

    private static bool OtherFixtureOrigin(string s)
    {
        const string prefix = "http://127.0.0.1:";
        return s.StartsWith(prefix, StringComparison.Ordinal) && s.AsSpan(prefix.Length) is ['9', '7' or '8', >= '0' and <= '9', >= '0' and <= '9'];
    }

    private static string Name(QuietPoint point) => point switch { QuietPoint.Entry => "entry", QuietPoint.BeforeFirst => "before-first",
        QuietPoint.BeforeAway => "before-away", QuietPoint.AfterAway => "after-away", _ => "invalid" };

    /// Call on the UI thread. Never returns a log-only refusal to the dispatcher. One instance per selected walk.
    public void Checkpoint(QuietPoint point)
    {
        if (stopped != null) throw stopped;
        var phase = Name(point);
        var reading = Read(point, inOrder: point == next);
        RecordOrStop(phase, reading, log: true);
        boundPush ??= reading.Push;
        next = point switch { QuietPoint.Entry => QuietPoint.BeforeFirst, QuietPoint.BeforeFirst => QuietPoint.BeforeAway,
            QuietPoint.BeforeAway => QuietPoint.AfterAway, _ => null };
        // AppLog notifies listeners synchronously. Do not carry a pre-log foreground/session into the next action.
        RequireChat(QuietChat.B);
    }

    /// A checkpoint is not a permit across an await. Recheck the bound runner, session and the exact expected
    /// foreground composer immediately before the walk's next action. No notification getters on this path.
    public void RequireChat(QuietChat expected)
    {
        if (stopped != null) throw stopped;
        var phase = expected switch { QuietChat.A => "guard-a", QuietChat.B => "guard-b", _ => "invalid" };
        var reading = Inspect(phase, expected, requireA: expected == QuietChat.A || next != QuietPoint.BeforeFirst,
            sample: false, refusal: boundPush == null ? "entry-required" : null);
        RecordOrStop(phase, reading, log: false);
        expectedSource = expected;
    }

    // Capturing a frame yields while settling/rendering. Recheck the walk's explicitly required source,
    // not the chat which happens to have focus now. This cannot skip Entry or clear a latched stop.
    public void RecheckChat() => RequireChat(expectedSource);

    // The already authorized away interval must stop if the same runner, plan or adopted account goes
    // away. This is only a veto while minimized, never a substitute for the presenter's own lifetime
    // check or a foreground check. Do not ask what other window is now in front, or read any settings.
    public void RequireAwayLifetime()
    {
        if (stopped != null) throw stopped;
        string? reason = next != QuietPoint.AfterAway || boundPush == null ? "checkpoint-out-of-order"
            : Or(() => Runner(env), null) != boundPush ? "runner-not-authorized"
            : !Or(() => currentWalk(true), false) ? "not-reply-walk" : null;
        if (reason != null) throw stopped = new QuietWalkStopped("walk", reason);
    }

    private void RecordOrStop(string phase, QuietReading reading, bool log)
    {
        // Positive list only. Missing/unknown measurements never inherit an earlier known quiet value.
        if (reading.Reason is not ("context-verified" or "banner-not-observed" or "focus-quiet" or "shell-not-accepting" or "app-not-enabled"))
            stopped = new QuietWalkStopped(phase, reading.Reason);
        if (log || stopped != null)
        {
            try { note(reading.Line); }
            catch (Exception e) when (e is not OutOfMemoryException) { throw stopped = new QuietWalkStopped(phase, "readback-unrecorded"); }
            // Already latched. A class from this evaluation only; not another sample or a cold-checker record.
            if (stopped != null && reading.FailedForeground is { } clause)
            {
                try { note($"fixture-foreground/v1 phase={phase} clause={Enum.GetName(clause) ?? nameof(QuietForeground.Unreadable)}"); }
                catch (Exception e) when (e is not OutOfMemoryException) { /* optional detail never replaces the canonical stop */ }
            }
        }
        if (stopped != null) throw stopped;
    }

    // Raw observations are internal (portable decoder tests); the Windows caller can only use the throwing gate.
    internal QuietReading Read(QuietPoint point, bool inOrder = true) =>
        Inspect(Name(point), QuietChat.B, requireA: point != QuietPoint.Entry, sample: true, inOrder ? null : "checkpoint-out-of-order");

    private QuietReading Inspect(string phase, QuietChat chat, bool requireA, bool sample, string? refusal)
    {
        string run = "unbound", sha = "unbound", quns = "not-read", focus = "not-read", app = "not-read";
        (string Run, string Sha)? push = null;
        QuietForeground? failedForeground = null;
        QuietReading Gap(string reason) => new(reason, $"toast-quiet/v1 run={run} sha={sha} phase={phase} quns={quns} focus={focus} app={app} writes=0 restore=not-needed banner=unverified gap={reason}", push, failedForeground);
        if (!windows) return Gap("non-windows");
        if (phase == "invalid") return Gap("invalid-phase");
        if (Or(() => Runner(env), null) is not { } actual || (boundPush != null && actual != boundPush)) return Gap("runner-not-authorized");
        push = actual;
        (run, sha) = actual;
        if (refusal != null) return Gap(refusal);
        bool Bound() => currentWalk(requireA);
        bool Foreground()
        {
            var check = Or(() => reader.ReadFixtureForeground(chat), QuietForeground.Unreadable);
            if (check == QuietForeground.Verified) return true;
            failedForeground = check;
            return false;
        }
        if (!Or(Bound, false)) return Gap("not-reply-walk");
        if (!Foreground()) return Gap("foreground-unverified");
        if (!sample) return Gap("context-verified");

        quns = Or(reader.ReadQuns, null) switch
        {
            1 => "QUNS_NOT_PRESENT", 2 => "QUNS_BUSY", 3 => "QUNS_RUNNING_D3D_FULL_SCREEN", 4 => "QUNS_PRESENTATION_MODE",
            5 => "QUNS_ACCEPTS_NOTIFICATIONS", 6 => "QUNS_QUIET_TIME", 7 => "QUNS_APP", _ => "unknown",
        };
        focus = Or(reader.ReadFocus, null) switch
        {
            null or { Status: not 0 } => "unreadable", { Bytes: 0 } or { Stamp: 0 } => "unpublished", { Bytes: not 4 } => "invalid-size",
            { Profile: 0 } => "off", { Profile: 1 } => "priority-only", { Profile: 2 } => "alarms-only", _ => "unknown-profile",
        };
        var setting = Or(reader.ReadAppSetting, null);
        app = setting is "Enabled" or "DisabledByManifest" or "DisabledByGroupPolicy" or "DisabledForUser" or "DisabledForApplication"
            or "Unsupported" or "Unregistered" ? setting : "unknown";
        // The shell/COM reads are not atomic with a focus or account switch. Discard a mixed sample rather than
        // attributing it to the old chat. No retry, reacquisition of focus or cached permit.
        if (Or(() => Runner(env), null) != actual || !Or(Bound, false) || !Foreground())
        {
            quns = focus = app = "discarded";
            return Gap("sample-context-lost");
        }
        if (focus is not ("off" or "priority-only" or "alarms-only")) return Gap("focus-unknown");
        if (quns == "unknown") return Gap("shell-state-unknown");
        if (app == "unknown") return Gap("app-setting-unknown");
        if (focus != "off") return Gap("focus-quiet");
        if (quns != "QUNS_ACCEPTS_NOTIFICATIONS") return Gap("shell-not-accepting");
        return Gap(app == "Enabled" ? "banner-not-observed" : "app-not-enabled");
    }

    // Missing API, COM failure, malformed plan, etc.: bounded output, never exception text or a supplied value.
    private static T Or<T>(Func<T> read, T fallback)
    {
        try { return read(); }
        catch (Exception e) when (e is not OutOfMemoryException) { return fallback; }
    }
}
