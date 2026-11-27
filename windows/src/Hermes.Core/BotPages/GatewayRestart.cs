using System.Text.Json.Nodes;

namespace Hermes.Core.BotPages;

/// `GET /api/actions/<name>/status` (HermesKit/Pages/More/GatewayActions.swift `GatewayActionStatus`).
public sealed record GatewayActionStatus(string Name, bool Running, int? ExitCode, IReadOnlyList<string> Lines)
{
    /// Lenient: a missing `running` reads as finished only when an exit code is there.
    public static GatewayActionStatus From(JsonNode? json, string fallbackName)
    {
        var exit = json.Num("exit_code") is { } d ? (int?)d : null;
        return new(json.Str("name") ?? fallbackName, json.Bool("running") ?? exit == null, exit,
            [.. (json.Arr("lines") ?? []).Select(PagesRest.PgString).OfType<string>()]);
    }

    public string? LastLine => Lines.LastOrDefault(l => l.Trim().Length > 0);
}

/// Restart Gateway: `POST /api/gateway/restart[?profile=]`, then its status (`GatewayActionsAPI`).
public sealed class GatewayActionsApi(IPagesGateway gw)
{
    public Task<string> RestartAsync(string? profile = null, CancellationToken ct = default) =>
        StartAsync("/api/gateway/restart", PagesRest.ProfileQuery(profile), "gateway-restart", ct);

    public async Task<string> StartAsync(string path, IEnumerable<KeyValuePair<string, string>> query, string fallback, CancellationToken ct = default)
    {
        var answer = await PagesRest.JsonAsync(gw, "POST", path, query, timeout: TimeSpan.FromSeconds(30), ct: ct);
        if (answer.Bool("ok") == false)
            throw new PagesMessageException(answer.Str("message") ?? answer.Str("error") ?? "The gateway couldn’t start that.");
        return answer.Str("name") ?? fallback;
    }

    public async Task<GatewayActionStatus> StatusAsync(string name, int lines = 200, CancellationToken ct = default) =>
        GatewayActionStatus.From(await PagesRest.JsonAsync(gw, "GET", $"/api/actions/{PagesRest.Segment(name)}/status",
            [new("lines", lines.ToString(System.Globalization.CultureInfo.InvariantCulture))], timeout: TimeSpan.FromSeconds(10), ct: ct), name);
}

/// One action from start to its end (`GatewayActionRun`). The poll survives failed reads (a restarting gateway answers
/// nothing for a moment): after `Patience` it says so (Stalled) and keeps reading more slowly until an answer comes.
public sealed class GatewayActionRun(Func<string, CancellationToken, Task<GatewayActionStatus>> status)
{
    public abstract record Phase
    {
        public sealed record Idle : Phase;
        public sealed record Running : Phase;
        public sealed record Stalled : Phase;
        public sealed record Finished(bool Ok, string? LastLine) : Phase;
        /// The status route answered "not found": the action was sent, but its end can't be followed.
        public sealed record Untracked : Phase;
        public sealed record Failed(string Reason) : Phase;
    }

    public Phase Current { get; private set; } = new Phase.Idle();
    public bool IsBusy => Current is Phase.Running or Phase.Stalled;
    public TimeSpan Interval { get; set; } = TimeSpan.FromSeconds(2);
    public TimeSpan Patience { get; set; } = TimeSpan.FromSeconds(90);
    public event Action? Changed;
    public event Action<bool>? Finished;
    private CancellationTokenSource? _cts;

    public GatewayActionRun(GatewayActionsApi api) : this((n, ct) => api.StatusAsync(n, ct: ct)) { }

    private void Set(Phase p) { Current = p; Changed?.Invoke(); }

    /// Starts the action with `begin` (the POST) and polls it to its end. Nothing while one is already running.
    public Task Start(Func<CancellationToken, Task<string>> begin)
    {
        if (IsBusy) return Task.CompletedTask;
        Set(new Phase.Running());
        var cts = _cts = new CancellationTokenSource();
        return Run(begin, cts.Token);
    }

    private async Task Run(Func<CancellationToken, Task<string>> begin, CancellationToken ct)
    {
        string name;
        try { name = await begin(ct); }
        catch (Exception e)
        {
            if (ct.IsCancellationRequested) return;
            Set(new Phase.Failed(PagesRest.Reason(e)));
            Finished?.Invoke(false);
            return;
        }
        var started = DateTimeOffset.UtcNow;
        var sawRunning = false;
        while (!ct.IsCancellationRequested)
        {
            try { await Task.Delay(Current is Phase.Stalled ? Interval * 2.5 : Interval, ct); } catch (OperationCanceledException) { return; }
            GatewayActionStatus? read;
            try { read = await status(name, ct); }
            catch (Exception e)
            {
                if (ct.IsCancellationRequested) return;
                if (PagesRest.Status(e) == 404) { Set(new Phase.Untracked()); return; }
                read = null;
            }
            if (read != null)
            {
                if (read.Running) sawRunning = true;
                if (!read.Running && (read.ExitCode != null || sawRunning))
                {
                    var ok = (read.ExitCode ?? 0) == 0;
                    Set(new Phase.Finished(ok, read.LastLine));
                    Finished?.Invoke(ok);
                    return;
                }
            }
            if (Current is Phase.Running && DateTimeOffset.UtcNow - started > Patience) Set(new Phase.Stalled());
        }
    }

    public void Reset()
    {
        _cts?.Cancel();
        _cts = null;
        Set(new Phase.Idle());
    }
}

/// "Restart your gateway to use this change." (App/Pages/More/Kit/GatewayRestartViews.swift `GatewayRestart`).
public static class GatewayRestartWords
{
    public const string ConfirmTitle = "Restart Your Gateway?";
    public const string ConfirmMessage = "Bots stop for a moment and running replies are interrupted.";
    public const string ConfirmAction = "Restart";
    public const string Notice = "Restart your gateway to use this change.";
    /// The Mac's push button: "Restart Gateway…".
    public const string Button = "Restart Gateway…";
    public const string Untracked = "Restart sent. This Hermes doesn’t report a restart’s progress, so it can’t be followed here.";

    /// What the row says for `phase`: null at rest.
    public static (string Text, bool IsError, bool IsBusy)? Words(GatewayActionRun.Phase phase) => phase switch
    {
        GatewayActionRun.Phase.Running => ("Restarting…", false, true),
        GatewayActionRun.Phase.Stalled => ("Still restarting. This page updates when your gateway is back.", false, true),
        GatewayActionRun.Phase.Untracked => (Untracked, false, false),
        GatewayActionRun.Phase.Finished { Ok: true } => ("Gateway Restarted", false, false),
        GatewayActionRun.Phase.Finished f => (f.LastLine ?? "The gateway didn’t restart.", true, false),
        GatewayActionRun.Phase.Failed f => (f.Reason, true, false),
        _ => null,
    };
}
