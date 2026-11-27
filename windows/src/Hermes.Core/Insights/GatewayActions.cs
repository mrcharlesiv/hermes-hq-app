using System.Diagnostics;
using System.Text.Json.Nodes;
using Hermes.Core.Net;

namespace Hermes.Core.Insights;

/// Long-running gateway actions (HermesKit/Pages/More/GatewayActions.swift; docs/spec/3x-morepages.md §12 (6), §15):
/// Restart Gateway, Update Hermes, the maintenance actions. Each POST answers an action record with a `name`; progress
/// is read from `GET /api/actions/<name>/status?lines=200`.
public sealed record GatewayActionStatus(string Name, bool Running, int? ExitCode, IReadOnlyList<string> Lines,
    HermesUpdateReceipt? Receipt = null)
{
    /// Lenient: a missing `running` reads as finished only when an exit code is there.
    public static GatewayActionStatus Parse(JsonNode? json, string fallbackName)
    {
        int? exit = json.Num("exit_code") is { } d ? (int)d : null;
        var running = json.Get("running") is JsonValue rv && rv.TryGetValue(out bool r) ? r : exit == null;
        var lines = (json.Arr("lines") ?? []).Select(J.AsString).OfType<string>().ToList();
        return new GatewayActionStatus(json.Str("name") ?? fallbackName, running, exit, lines, HermesUpdateReceipt.Parse(json.Get("receipt")));
    }

    public string? LastLine => Lines.LastOrDefault(l => l.Trim().Length > 0);
}

/// Where the action's routes are: the live session, or any REST endpoint (a saved gateway not in use).
public interface IGatewayRest
{
    Task<JsonNode?> JsonAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query, JsonNode? body,
        TimeSpan timeout, CancellationToken ct = default);
}

/// A gateway's REST through its session: errors as GatewayException("http", …) like GetJsonAsync.
public sealed class SessionRest(GatewaySession session) : IGatewayRest
{
    public async Task<JsonNode?> JsonAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query, JsonNode? body,
        TimeSpan timeout, CancellationToken ct = default)
    {
        var a = await session.SendAsync(method, path, query, body, timeout, ct: ct);
        if (!a.Ok) throw GatewaySession.HttpError(a);
        if (a.Body.Trim().Length == 0) return null;
        return a.Json ?? throw new GatewayException("not-hermes", "The gateway sent something that isn't JSON.", a.Status);
    }
}

public sealed class GatewayActionsApi(IGatewayRest rest)
{
    public GatewayActionsApi(GatewaySession session) : this(new SessionRest(session)) { }

    /// `POST /api/gateway/restart[?profile=]` → the action's name ("gateway-restart").
    public Task<string> RestartAsync(string? profile = null) =>
        StartAsync("/api/gateway/restart", InsightsWire.ProfileQuery(profile), "gateway-restart");

    public async Task<string> StartAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string fallback, JsonNode? body = null)
    {
        var answer = await rest.JsonAsync(HttpMethod.Post, path, query, body, TimeSpan.FromSeconds(30));
        if (answer.Bool("ok") == false)
            throw new PagesMessageException(answer.Str("message") ?? answer.Str("error") ?? "The gateway couldn’t start that.");
        return answer.Str("name") ?? fallback;
    }

    /// `GET /api/actions/<name>/status?lines=N`.
    public async Task<GatewayActionStatus> StatusAsync(string name, int lines = 200, CancellationToken ct = default)
    {
        var answer = await rest.JsonAsync(HttpMethod.Get, $"/api/actions/{Uri.EscapeDataString(name)}/status",
            [new("lines", lines.ToString(System.Globalization.CultureInfo.InvariantCulture))], null, TimeSpan.FromSeconds(10), ct);
        return GatewayActionStatus.Parse(answer, name);
    }
}

/// An action's phase (GatewayActionRun.Phase).
public abstract record ActionPhase
{
    public sealed record IdlePhase : ActionPhase;
    public sealed record RunningPhase : ActionPhase;
    /// Still no end after `Patience`: "Still restarting. This page updates when your gateway is back."
    public sealed record StalledPhase : ActionPhase;
    public sealed record Finished(bool Ok, string? LastLine) : ActionPhase;
    /// The status route answered 404: the action was sent, but its end can't be followed.
    public sealed record UntrackedPhase : ActionPhase;
    /// The action never started (the POST failed).
    public sealed record Failed(string Reason) : ActionPhase;

    public static readonly ActionPhase Idle = new IdlePhase(), Running = new RunningPhase(), Stalled = new StalledPhase(),
        Untracked = new UntrackedPhase();
}

/// One action from start to its end. The poll survives failed reads (a restarting gateway answers nothing for a moment):
/// after `Patience` it says so (`Stalled`) and keeps reading more slowly until an answer comes.
public sealed class GatewayActionRun
{
    private readonly Func<string, CancellationToken, Task<GatewayActionStatus>> _status;
    private CancellationTokenSource? _cts;

    public GatewayActionRun(Func<string, CancellationToken, Task<GatewayActionStatus>> status) => _status = status;
    public GatewayActionRun(GatewayActionsApi api) : this((n, ct) => api.StatusAsync(n, ct: ct)) { }

    public ActionPhase Phase { get; private set; } = ActionPhase.Idle;
    public IReadOnlyList<string> Lines { get; private set; } = [];
    public bool IsBusy => Phase is ActionPhase.RunningPhase or ActionPhase.StalledPhase;

    public TimeSpan Interval { get; set; } = TimeSpan.FromSeconds(2);
    public TimeSpan Patience { get; set; } = TimeSpan.FromSeconds(90);
    /// Raised after every change (phase or lines), on the poll's thread.
    public event Action? Changed;
    public Action<bool>? OnFinish { get; set; }
    /// Every poll: the answer, or null when the read got none. Called before the phase changes for that answer.
    public Action<GatewayActionStatus?>? OnRead { get; set; }
    public Action? OnUntracked { get; set; }

    /// Starts the action with `begin` (the POST) and polls it to its end. Nothing while one is already running.
    public void Start(Func<Task<string>> begin)
    {
        if (IsBusy) return;
        _cts?.Cancel();
        var cts = _cts = new CancellationTokenSource();
        Phase = ActionPhase.Running;
        Lines = [];
        Changed?.Invoke();
        _ = RunAsync(begin, cts.Token);
    }

    private async Task RunAsync(Func<Task<string>> begin, CancellationToken ct)
    {
        string name;
        try { name = await begin(); }
        catch (Exception e)
        {
            if (ct.IsCancellationRequested) return;
            Phase = new ActionPhase.Failed(InsightsWire.Reason(e));
            Changed?.Invoke();
            OnFinish?.Invoke(false);
            return;
        }
        await PollAsync(name, ct);
    }

    private async Task PollAsync(string name, CancellationToken ct)
    {
        var clock = Stopwatch.StartNew();
        var sawRunning = false;
        while (!ct.IsCancellationRequested)
        {
            try { await Task.Delay(Phase is ActionPhase.StalledPhase ? Interval * 2.5 : Interval, ct); }
            catch (OperationCanceledException) { return; }
            GatewayActionStatus? read;
            try { read = await _status(name, ct); }
            catch (Exception e)
            {
                if (ct.IsCancellationRequested) return;
                if (e is GatewayException { Code: "http", Status: 404 })
                {
                    Phase = ActionPhase.Untracked;
                    Changed?.Invoke();
                    OnUntracked?.Invoke();
                    return;
                }
                read = null;
            }
            if (ct.IsCancellationRequested) return;
            OnRead?.Invoke(read);
            if (read != null)
            {
                if (read.Lines.Count > 0) { Lines = read.Lines; Changed?.Invoke(); }
                if (read.Running) sawRunning = true;
                // Not running with no exit code, before the action was ever seen running: not registered yet (or an older
                // run's status). Keep reading.
                if (!read.Running && (read.ExitCode != null || sawRunning))
                {
                    var ok = (read.ExitCode ?? 0) == 0;
                    Phase = new ActionPhase.Finished(ok, read.LastLine);
                    Changed?.Invoke();
                    OnFinish?.Invoke(ok);
                    return;
                }
            }
            if (Phase is ActionPhase.RunningPhase && clock.Elapsed > Patience)
            {
                Phase = ActionPhase.Stalled;
                Changed?.Invoke();
            }
        }
    }

    public void Reset()
    {
        _cts?.Cancel();
        _cts = null;
        Phase = ActionPhase.Idle;
        Lines = [];
        Changed?.Invoke();
    }
}
