using System.Net;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Auth;

namespace Hermes.Core.Net;

public sealed record HttpAnswer(int Status, string Body, HttpResponseHeaders Headers)
{
    public JsonNode? Json => J.Parse(Body);
    public bool Ok => Status is >= 200 and < 300;
}

/// Process-wide Nous refresh single-flight and successor table (HermesKit/Net/NousProtocol.swift `NousRenewals`):
/// one rotation per `(accountKey, userId, refreshToken)` across every `GatewaySession` in this process, full-chain
/// successor walk with a cycle guard (no 16-hop cap), and `priorUnsaved` CAS retry when `ITokenStore` transiently
/// fails to persist.
public sealed class NousRenewals
{
    public static NousRenewals Shared { get; } = new();

    public abstract record Outcome
    {
        public sealed record Tokens(NousTokens Pair) : Outcome;
        public sealed record Refused : Outcome;
        public sealed record Unavailable(int Status, TimeSpan? RetryAfter = null, bool Pending = false) : Outcome;
        public sealed record Failed(Exception Error) : Outcome;
    }

    private readonly record struct FlightKey(string AccountKey, string UserId, string RefreshToken);
    private sealed record UnsavedRotation(NousTokens ExpectedInVault, NousTokens Renewed, Func<NousTokens, NousTokens, bool> Keep);

    private readonly object _gate = new();
    private readonly Dictionary<FlightKey, (Guid Id, Task<Outcome> Task)> _flights = [];
    private readonly Dictionary<string, NousTokens> _successors = [];
    private readonly Dictionary<string, UnsavedRotation> _unsaved = [];

    /// The newest pair this run has seen for `tokens`, walking the entire rotation chain with a cycle guard.
    /// Never cap by a small hop count: a long-lived session exceeds 16 rotations and stopping early replays a spent token.
    public NousTokens Latest(NousTokens tokens)
    {
        lock (_gate) return LatestLocked(tokens);
    }

    private NousTokens LatestLocked(NousTokens tokens)
    {
        var current = tokens;
        var seen = new HashSet<string>(StringComparer.Ordinal) { current.RefreshToken };
        while (_successors.TryGetValue(current.RefreshToken, out var next))
        {
            current = next;
            if (!seen.Add(current.RefreshToken)) break;
        }
        return current;
    }

    /// Whether this refresh token was already spent by a rotation in this run.
    public bool IsSpent(NousTokens tokens)
    {
        lock (_gate) return _successors.ContainsKey(tokens.RefreshToken);
    }

    /// Drops a pending unsaved rotation for `accountKey` (after explicit sign-out or fresh sign-in).
    public void ForgetUnsaved(string accountKey)
    {
        lock (_gate) _unsaved.Remove(accountKey);
    }

    /// Retries any rotated pairs that could not be written to `ITokenStore` when they landed.
    public void RetryUnsaved()
    {
        KeyValuePair<string, UnsavedRotation>[] snapshot;
        lock (_gate)
        {
            if (_unsaved.Count == 0) return;
            snapshot = [.. _unsaved];
        }
        foreach (var (key, entry) in snapshot)
        {
            bool saved;
            try { saved = entry.Keep(entry.ExpectedInVault, entry.Renewed); }
            catch (Exception) { saved = false; }
            if (!saved) continue;
            lock (_gate)
            {
                if (_unsaved.TryGetValue(key, out var cur) && ReferenceEquals(cur, entry))
                    _unsaved.Remove(key);
            }
        }
    }

    /// Renews `tokens` for `accountKey`. Concurrent callers sharing `(accountKey, userId, refreshToken)` join one
    /// flight; a caller holding a spent pair gets its live successor without a request unless that successor is itself
    /// due or expired (H10), in which case the unspent successor is renewed; a fresh sign-in with a different refresh
    /// token never joins an older session's in-flight renewal (H9).
    public Task<Outcome> RenewAsync(string accountKey, NousTokens tokens,
        Func<NousTokens, Task<Outcome>> post,
        Func<NousTokens, NousTokens, bool> keep,
        Func<DateTimeOffset>? now = null)
    {
        var clock = now ?? (() => DateTimeOffset.UtcNow);
        FlightKey flightKey;
        Guid flightId;
        NousTokens toSend;
        NousTokens? priorUnsaved;
        TaskCompletionSource<Outcome> tcs;

        lock (_gate)
        {
            var live = LatestLocked(tokens);
            if (!live.SamePair(tokens))
            {
                if (!live.IsDueOrExpired(clock()))
                    return Task.FromResult<Outcome>(new Outcome.Tokens(live));
                tokens = live;
            }

            flightKey = new FlightKey(accountKey, tokens.UserId, tokens.RefreshToken);
            if (_flights.TryGetValue(flightKey, out var existing))
                return existing.Task;

            // Hard guard: never post a refresh token this process already spent (even if a successor cycle existed).
            if (_successors.ContainsKey(tokens.RefreshToken))
                return Task.FromResult<Outcome>(new Outcome.Tokens(live));

            // If an earlier rotation could not reach storage, storage still holds `priorUnsaved`, not `tokens`.
            // Compare-and-swap against `priorUnsaved` so recovery writes the newest pair straight over it.
            priorUnsaved = _unsaved.TryGetValue(accountKey, out var u) && u.Renewed.SamePair(tokens)
                ? u.ExpectedInVault
                : null;
            toSend = tokens;
            flightId = Guid.NewGuid();
            tcs = new TaskCompletionSource<Outcome>(TaskCreationOptions.RunContinuationsAsynchronously);
            _flights[flightKey] = (flightId, tcs.Task);
        }

        _ = RunFlightAsync(accountKey, flightKey, flightId, toSend, priorUnsaved, post, keep, tcs);
        return tcs.Task;
    }

    private async Task RunFlightAsync(string accountKey, FlightKey flightKey, Guid flightId,
        NousTokens sent, NousTokens? priorUnsaved,
        Func<NousTokens, Task<Outcome>> post,
        Func<NousTokens, NousTokens, bool> keep,
        TaskCompletionSource<Outcome> tcs)
    {
        Outcome outcome;
        try
        {
            outcome = await post(sent).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            outcome = new Outcome.Failed(e);
        }

        if (outcome is Outcome.Tokens { Pair: var renewed } && renewed.UserId == sent.UserId)
        {
            var expectedInVault = priorUnsaved ?? sent;
            bool saved;
            try { saved = keep(expectedInVault, renewed); }
            catch (Exception) { saved = false; }

            lock (_gate)
            {
                _successors[sent.RefreshToken] = renewed;
                if (saved)
                {
                    if (_unsaved.TryGetValue(accountKey, out var cur)
                        && (cur.ExpectedInVault.SamePair(expectedInVault) || cur.Renewed.SamePair(sent)))
                        _unsaved.Remove(accountKey);
                }
                else
                {
                    _unsaved[accountKey] = new UnsavedRotation(expectedInVault, renewed, keep);
                }
            }
        }

        lock (_gate)
        {
            if (_flights.TryGetValue(flightKey, out var cur) && cur.Id == flightId)
                _flights.Remove(flightKey);
        }
        tcs.TrySetResult(outcome);
    }

    internal void Reset()
    {
        lock (_gate)
        {
            _flights.Clear();
            _successors.Clear();
            _unsaved.Clear();
        }
    }
}

/// One signed-in account: its own cookie jar, the bearer for Nous accounts, refresh-once-on-401, and saving rotated
/// credentials before they are used (GatewayAuth.swift). Redirects are never followed (real Hermes answers
/// /auth/logout with a 302).
public sealed partial class GatewaySession : IDisposable, IAsyncDisposable
{
    public static readonly TimeSpan RefreshTimeout = TimeSpan.FromSeconds(30);
    public static readonly TimeSpan DefaultSettleLimit = TimeSpan.FromSeconds(35);
    public const int PendingMaxAttempts = 4;

    private static readonly ConditionalWeakTable<ITokenStore, object> StoreLocks = new();

    public GatewayAddress Address { get; }
    public StoredAccount Account { get; private set; }
    public CookieContainer Jar { get; } = new();

    private readonly ITokenStore _store;
    private readonly HttpClient _http;
    private readonly NousRenewals _renewals;
    private readonly Func<DateTimeOffset> _now;
    private readonly SemaphoreSlim _ticketGate = new(1, 1);
    private readonly object _flightLock = new();
    private readonly CancellationTokenSource _disposeCts = new();
    private Task<bool>? _activeRenewal;
    private int _closing;
    private int _transportDisposed;
    private string _savedCookieSignature = "";

    /// Floor applied to `503 refresh_pending` retry waits (1 s in production; tests may lower it).
    internal TimeSpan PendingRetryFloor { get; set; } = TimeSpan.FromSeconds(1);

    /// Raised when the session ended server-side (refresh refused); the UI shows "Sign in again".
    public event Action? Ended;

    public GatewaySession(GatewayAddress address, StoredAccount account, ITokenStore store,
        HttpMessageHandler? handler = null, NousRenewals? renewals = null, Func<DateTimeOffset>? now = null)
    {
        Address = address;
        Account = account;
        _store = store;
        _renewals = renewals ?? NousRenewals.Shared;
        _now = now ?? (() => DateTimeOffset.UtcNow);
        var h = handler ?? new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            UseCookies = true,
            CookieContainer = Jar,
            ConnectTimeout = TimeSpan.FromSeconds(15),
            PooledConnectionIdleTimeout = TimeSpan.FromSeconds(60),
        };
        _http = new HttpClient(h) { Timeout = Timeout.InfiniteTimeSpan };
        foreach (var c in account.Cookies ?? []) Jar.Add(ToCookie(c));
        _savedCookieSignature = CookieSignature();
    }

    public bool IsNous => Account.IsNous;

    /// Advances `Account.Nous` to the newest pair this process already rotated to in `NousRenewals`
    /// (GatewayAuth.swift `adoptLatestInProcess`).
    public void AdoptLatestInProcess()
    {
        if (Account.Nous is not { } tokens) return;
        var live = _renewals.Latest(tokens);
        if (!live.SamePair(tokens) && live.UserId == tokens.UserId)
            Account = Account with { Nous = live };
    }

    /// Waits (up to `limit`, default 35 s) for any in-flight Nous refresh or `503 refresh_pending` collection
    /// before closing/disposing the HTTP transport (GatewayAuth.swift `settleRenewal`). Does NOT cancel the
    /// underlying renewal if `limit` elapses.
    public async Task SettleRenewalAsync(TimeSpan? limit = null)
    {
        var budget = limit ?? DefaultSettleLimit;
        if (budget <= TimeSpan.Zero) return;
        var deadline = Environment.TickCount64 + (long)budget.TotalMilliseconds;
        while (true)
        {
            Task? flight;
            lock (_flightLock) flight = _activeRenewal is { IsCompleted: false } f ? f : null;
            if (flight == null) return;
            var remainingMs = deadline - Environment.TickCount64;
            if (remainingMs <= 0) return;
            using var delayCts = new CancellationTokenSource();
            var delay = Task.Delay(TimeSpan.FromMilliseconds(remainingMs), delayCts.Token);
            var winner = await Task.WhenAny(flight, delay).ConfigureAwait(false);
            if (winner == flight)
            {
                delayCts.Cancel();
                try { await flight.ConfigureAwait(false); } catch { }
            }
            else
            {
                return;
            }
        }
    }

    /// Renews an idle saved Nous session whose latest pair is at least `olderThan` (default 4 h) old before Portal's
    /// 24 h rotating refresh token expires (GatewayAuth.swift `keepAlive`). Returns true when a refresh succeeded;
    /// throws `GatewayException("session-ended")` if Hermes genuinely refused the session.
    public async Task<bool> KeepAliveAsync(TimeSpan? olderThan = null, DateTimeOffset? now = null, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        _renewals.RetryUnsaved();
        AdoptLatestInProcess();
        if (Account.Nous is not { } tokens || !tokens.CanRenew()) return false;
        if (RotatedElsewhere(tokens) is { } kept)
        {
            Account = Account with { Nous = kept };
            tokens = kept;
        }
        var checkTime = now ?? _now();
        if (!NousSessionKeepAlive.RefreshDue(tokens, olderThan, checkTime)) return false;
        var refreshed = await RefreshAsync(tokens, ct, force: true).ConfigureAwait(false);
        if (!refreshed && Account.Nous == null)
            throw new GatewayException("session-ended", "Sign in again.");
        return refreshed;
    }

    // ------------------------------------------------------------------ requests

    public async Task<HttpAnswer> SendAsync(HttpMethod method, string path,
        IEnumerable<KeyValuePair<string, string>>? query = null, JsonNode? body = null,
        TimeSpan? timeout = null, bool refreshOn401 = true, CancellationToken ct = default)
    {
        // [WIN-MEMO-SEND-WIRE] A write may change the config: the shared config reads drop what they kept, before it is
        // sent and once it is answered (LiveGatewayClient.send's `configReads.invalidate()`). The sign-in's own calls (the
        // socket's ticket, logout) go past `send` on the Mac (GatewayAuth) and drop nothing.
        ct.ThrowIfCancellationRequested();
        var write = !IsRead(method) && !IsControlPath(path);
        if (write) ConfigReads.Invalidate();
        try
        {
            AdoptLatestInProcess();
            if (refreshOn401 && Account.Nous is { } n)
            {
                var now = _now();
                if (n.IsDueOrExpired(now))
                {
                    try { await RefreshAsync(n, ct); }
                    catch (GatewayException) when (!n.IsExpired(_now()))
                    {
                        // Current token still has time left (renewal starts 60 s early): send with it rather than fail.
                    }
                }
                else if (n.RenewsAlongside(now))
                {
                    _ = RenewQuietly(n);
                }
            }

            var sentAccess = Account.Nous?.AccessToken;
            var answer = await RawAsync(method, path, query, body, timeout, ct);
            ct.ThrowIfCancellationRequested(); // a late response must not initiate a retry or a cookie-store write
            // [kept-session] Only a 401 Hermes wrote is worth a refresh: a proxy/Cloudflare wall says nothing about the session.
            if (answer.Status == 401 && refreshOn401 && path.Contains("/api/") && GatewayRefusal.IsHermes(answer.Body))
            {
                if (await RefreshAfter401Async(sentAccess, ct)) answer = await RawAsync(method, path, query, body, timeout, ct);
            }
            ct.ThrowIfCancellationRequested();
            SaveCookiesIfChanged();
            return answer;
        }
        finally
        {
            if (write) ConfigReads.Invalidate();
        }
    }

    public async Task<JsonNode> GetJsonAsync(string path, IEnumerable<KeyValuePair<string, string>>? query = null,
        TimeSpan? timeout = null, CancellationToken ct = default)
    {
        var a = await SendAsync(HttpMethod.Get, path, query, null, timeout, ct: ct);
        return Require(a);
    }

    public async Task<JsonNode> PostJsonAsync(string path, JsonNode body, TimeSpan? timeout = null,
        CancellationToken ct = default)
    {
        var a = await SendAsync(HttpMethod.Post, path, null, body, timeout, ct: ct);
        return Require(a);
    }

    internal static JsonNode Require(HttpAnswer a)
    {
        if (!a.Ok) throw HttpError(a);
        return a.Json ?? throw new GatewayException("not-hermes", "The gateway sent something that isn't JSON.", a.Status);
    }

    internal static GatewayException HttpError(HttpAnswer a)
    {
        if (a.Status == 400 && a.Body.Contains("Invalid Host header"))
            return new GatewayException("host-rejected",
                "The gateway turned this address away. Add it to Hermes's allowed hosts.", 400, a.Body);
        if (a.Status == 429)
            return new GatewayException("rate-limited", "Too many tries. Wait a minute, then try again.", 429, a.Body,
                a.Headers.RetryAfter?.Delta);
        var body = a.Body.Length > 65536 ? a.Body[..65536] : a.Body;
        return new GatewayException("http", $"The gateway answered {a.Status}.", a.Status, body);
    }

    private async Task<HttpAnswer> RawAsync(HttpMethod method, string path,
        IEnumerable<KeyValuePair<string, string>>? query, JsonNode? body, TimeSpan? timeout, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        AdoptLatestInProcess();
        using var req = new HttpRequestMessage(method, Address.Endpoint(path, query));
        // HermesKit sets Content-Type on every request, GET included; Accept only on auth and probe calls.
        req.Content = new StringContent(body?.ToJsonString() ?? (method == HttpMethod.Get ? "" : "{}"),
            Encoding.UTF8, "application/json");
        if (method == HttpMethod.Get && body == null) req.Content.Headers.ContentLength = 0;
        if (IsControlPath(path)) req.Headers.Accept.ParseAdd("application/json");
        if (Account.Nous is { } n) req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", n.AccessToken);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout ?? TimeSpan.FromSeconds(IsControlPath(path) ? 15 : 30));
        // Settings › About › Detailed Logging (HTTPTransport.swift `data`): every request's route, answer, size and time;
        // a failure's own words, redacted. Nothing is timed or built while it is off.
        var traced = Settings.DetailedLogging.Enabled;
        var began = traced ? System.Diagnostics.Stopwatch.GetTimestamp() : 0;
        var url = req.RequestUri!;
        var control = IsControlPath(path);
        long Ms() => (long)System.Diagnostics.Stopwatch.GetElapsedTime(began).TotalMilliseconds;
        try
        {
            using var res = await _http.SendAsync(req, HttpCompletionOption.ResponseContentRead, cts.Token);
            var text = await res.Content.ReadAsStringAsync(cts.Token);
            var answer = new HttpAnswer((int)res.StatusCode, text, res.Headers);
            if (traced)
                Settings.DetailedLogging.Trace("http", () => Settings.DetailedLogging.RequestLine(method.Method, url, control,
                    answer.Status, Encoding.UTF8.GetByteCount(text), Ms(), text));
            return answer;
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            if (traced) Settings.DetailedLogging.Trace("http", () => Settings.DetailedLogging.FailureLine(method.Method, url, control, Ms(), "timed out"));
            throw new GatewayException("timeout", "The gateway took too long to answer.");
        }
        catch (HttpRequestException e)
        {
            if (traced) Settings.DetailedLogging.Trace("http", () => Settings.DetailedLogging.FailureLine(method.Method, url, control, Ms(), e.Message));
            throw new GatewayException("offline", "Can't reach the gateway. " + e.Message);
        }
    }

    public static bool IsControlPath(string path) => path.StartsWith("/auth/") || path.StartsWith("/api/auth/");

    // ------------------------------------------------------------------ refresh

    private Task<bool> RefreshAfter401Async(CancellationToken ct) =>
        RefreshAfter401Async(Account.Nous?.AccessToken, ct);

    private async Task<bool> RefreshAfter401Async(string? sentAccess, CancellationToken ct)
    {
        AdoptLatestInProcess();
        if (Account.Nous is { } n)
        {
            // H10: only skip refresh when a different token is already in place AND is not expired/due.
            if (sentAccess != null && n.AccessToken != sentAccess && !n.IsDueOrExpired(_now()))
                return true;
            return await RefreshAsync(n, ct, force: true);
        }
        if (IsNous) return false;
        // Cookie session: the server renews by itself; ask /api/auth/me once (spec 01 §5.3).
        var me = await RawAsync(HttpMethod.Get, "/api/auth/me", null, null, TimeSpan.FromSeconds(15), ct);
        ct.ThrowIfCancellationRequested();
        if (me.Ok && me.Json is JsonObject) { SaveCookiesIfChanged(); return true; }
        if (me.Status is 401 or 403 && GatewayRefusal.IsHermes(me.Body)) EndSession();
        return false;
    }

    private async Task RenewQuietly(NousTokens sent)
    {
        try { await RefreshAsync(sent, CancellationToken.None).ConfigureAwait(false); }
        catch { /* the next request will try again */ }
    }

    /// Single flight per account (and process-wide across instances via `NousRenewals`). Returns true when a usable
    /// non-expired pair is now in place. Caller cancellation stops waiting without cutting off an in-flight POST.
    internal async Task<bool> RefreshAsync(NousTokens sent, CancellationToken ct, bool force = false)
    {
        ct.ThrowIfCancellationRequested();
        AdoptLatestInProcess();
        // H10: when another caller rotated the refresh token, verify it is NOT already expired/due before returning true.
        if (Account.Nous is { } current && !current.SamePair(sent) && !current.IsDueOrExpired(_now()))
            return true;

        while (true)
        {
            Task<bool> flight;
            bool startedByUs;
            lock (_flightLock)
            {
                if (_activeRenewal is { IsCompleted: false } running)
                {
                    flight = running;
                    startedByUs = false;
                }
                else
                {
                    if (Volatile.Read(ref _closing) != 0) return false;
                    flight = StartRefreshFlightLocked(sent, force);
                    startedByUs = true;
                }
            }

            var result = await flight.WaitAsync(ct).ConfigureAwait(false);
            if (startedByUs) return result;

            // Joined another flight: re-verify H10 before returning true.
            AdoptLatestInProcess();
            if (Account.Nous is not { } after) return false;
            if (!after.SamePair(sent))
            {
                if (!after.IsDueOrExpired(_now())) return true;
                sent = after;
                force = true;
                continue;
            }
            return result;
        }
    }

    private Task<bool> StartRefreshFlightLocked(NousTokens sent, bool force)
    {
        Task<bool>? task = null;
        task = RunAndClearAsync();
        if (!task.IsCompleted) _activeRenewal = task;
        return task;

        async Task<bool> RunAndClearAsync()
        {
            try { return await RunRefreshFlightAsync(sent, force).ConfigureAwait(false); }
            finally
            {
                lock (_flightLock)
                {
                    if (ReferenceEquals(_activeRenewal, task))
                        _activeRenewal = null;
                }
            }
        }
    }

    private async Task<bool> RunRefreshFlightAsync(NousTokens sent, bool force)
    {
        var ct = _disposeCts.Token;
        _renewals.RetryUnsaved();
        AdoptLatestInProcess();

        if (Account.Nous is not { } tokens || !tokens.CanRenew()) return false;

        var now = _now();
        // H10: if another caller rotated the refresh token, only skip refresh if the rotated pair is still fresh.
        if (!tokens.SamePair(sent))
        {
            if (!tokens.IsDueOrExpired(now)) return true;
            sent = tokens;
        }

        // Another client (or process) may have rotated it in storage.
        if (RotatedElsewhere(tokens) is { } kept)
        {
            Account = Account with { Nous = kept };
            tokens = kept;
            if (!kept.IsDueOrExpired(now)) return true;
        }

        if (!force && !tokens.IsDueOrExpired(now) && !tokens.RenewsAlongside(now))
            return true;

        // Up to 2 attempts for a refusal race (another process saved a successor while ours was out),
        // and bounded `503 refresh_pending` collection (`PendingMaxAttempts = 4`, honoring `retry_after`).
        for (var raceAttempt = 0; raceAttempt < 2; raceAttempt++)
        {
            var pendingAttempt = 0;
            while (true)
            {
                if (ct.IsCancellationRequested) return false;

                var outcome = await _renewals.RenewAsync(
                    Account.Key,
                    tokens,
                    post: pair => PostRefreshAsync(pair, ct),
                    keep: PersistNous,
                    now: _now).ConfigureAwait(false);

                switch (outcome)
                {
                    case NousRenewals.Outcome.Tokens { Pair: var renewed }:
                        if (renewed.UserId != tokens.UserId)
                        {
                            EndSession();
                            return false;
                        }
                        Account = Account with { Nous = renewed };
                        return true;

                    case NousRenewals.Outcome.Refused:
                        if (raceAttempt == 0 && RotatedElsewhere(tokens) is { } raced)
                        {
                            Account = Account with { Nous = raced };
                            tokens = raced;
                            if (!raced.IsDueOrExpired(_now())) return true;
                            goto NextRaceAttempt;
                        }
                        EndSession();
                        return false;

                    case NousRenewals.Outcome.Unavailable { Pending: true, RetryAfter: var after }:
                        if (pendingAttempt >= PendingMaxAttempts) return false;
                        pendingAttempt++;
                        var wait = ClampPendingDelay(after);
                        try { await Task.Delay(wait, ct).ConfigureAwait(false); }
                        catch (OperationCanceledException) { return false; }

                        AdoptLatestInProcess();
                        if (Account.Nous is not { } afterSleep) return false;
                        if (!afterSleep.SamePair(tokens))
                        {
                            if (!afterSleep.IsDueOrExpired(_now())) return true;
                            tokens = afterSleep;
                            continue;
                        }
                        if (RotatedElsewhere(tokens) is { } savedDuringWait)
                        {
                            Account = Account with { Nous = savedDuringWait };
                            tokens = savedDuringWait;
                            if (!savedDuringWait.IsDueOrExpired(_now())) return true;
                        }
                        continue;

                    case NousRenewals.Outcome.Unavailable:
                        // 429, 5xx, or non-Hermes proxy/Cloudflare 400/401/403: keep the session.
                        return false;

                    case NousRenewals.Outcome.Failed { Error: var err }:
                        if (err is GatewayException ge) throw ge;
                        if (err is OperationCanceledException && ct.IsCancellationRequested) return false;
                        throw new GatewayException("offline", "Can't reach the gateway. " + err.Message);
                }
            }
        NextRaceAttempt: ;
        }

        EndSession();
        return false;
    }

    private TimeSpan ClampPendingDelay(TimeSpan? after)
    {
        var raw = after ?? TimeSpan.FromSeconds(2);
        var min = PendingRetryFloor;
        var max = TimeSpan.FromSeconds(10);
        if (raw < min) return min;
        if (raw > max) return max;
        return raw;
    }

    /// POST /auth/native/refresh for one pair (GatewayAuth.swift `postRefresh`).
    private async Task<NousRenewals.Outcome> PostRefreshAsync(NousTokens sent, CancellationToken ct)
    {
        var url = Address.Endpoint("/auth/native/refresh");
        using var req = new HttpRequestMessage(HttpMethod.Post, url)
        {
            Content = new StringContent(
                new JsonObject { ["refresh_token"] = sent.RefreshToken, ["provider"] = "nous" }.ToJsonString(),
                Encoding.UTF8, "application/json"),
        };
        req.Headers.Accept.ParseAdd("application/json");
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(RefreshTimeout);
        var traced = Settings.DetailedLogging.Enabled;
        var began = traced ? System.Diagnostics.Stopwatch.GetTimestamp() : 0;
        long Ms() => (long)System.Diagnostics.Stopwatch.GetElapsedTime(began).TotalMilliseconds;
        try
        {
            using var res = await _http.SendAsync(req, HttpCompletionOption.ResponseContentRead, cts.Token).ConfigureAwait(false);
            var text = await res.Content.ReadAsStringAsync(cts.Token).ConfigureAwait(false);
            var answer = new HttpAnswer((int)res.StatusCode, text, res.Headers);
            if (traced)
                Settings.DetailedLogging.Trace("http", () => Settings.DetailedLogging.RequestLine("POST", url, control: true,
                    answer.Status, Encoding.UTF8.GetByteCount(text), Ms(), text));

            if (answer.Status == 200)
            {
                var fresh = NousProtocol.ParseTokens(answer, _now());
                if (fresh == null) return new NousRenewals.Outcome.Unavailable(502);
                return fresh.UserId == sent.UserId
                    ? new NousRenewals.Outcome.Tokens(fresh)
                    : new NousRenewals.Outcome.Refused();
            }
            if (answer.Status is 400 or 401 or 403)
            {
                // [kept-session] Only Hermes's own JSON refusal ends the session; proxy/Cloudflare HTML pages do not.
                return GatewayRefusal.IsHermes(answer.Body)
                    ? new NousRenewals.Outcome.Refused()
                    : new NousRenewals.Outcome.Unavailable(answer.Status);
            }
            var pending = NousProtocol.IsRefreshPending(answer);
            var retryAfter = NousProtocol.RetryAfter(answer, _now());
            return new NousRenewals.Outcome.Unavailable(answer.Status, retryAfter, pending);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            if (traced) Settings.DetailedLogging.Trace("http", () => Settings.DetailedLogging.FailureLine("POST", url, control: true, Ms(), "timed out"));
            return new NousRenewals.Outcome.Failed(new GatewayException("timeout", "The gateway took too long to answer."));
        }
        catch (OperationCanceledException e)
        {
            return new NousRenewals.Outcome.Failed(e);
        }
        catch (HttpRequestException e)
        {
            if (traced) Settings.DetailedLogging.Trace("http", () => Settings.DetailedLogging.FailureLine("POST", url, control: true, Ms(), e.Message));
            return new NousRenewals.Outcome.Failed(new GatewayException("offline", "Can't reach the gateway. " + e.Message));
        }
        catch (ObjectDisposedException e)
        {
            return new NousRenewals.Outcome.Failed(e);
        }
    }

    /// Storage's pair for this account when another client or process rotated `tokens` and saved a newer unspent pair.
    private NousTokens? RotatedElsewhere(NousTokens tokens)
    {
        string? json;
        try
        {
            lock (StoreLocks.GetOrCreateValue(_store)) json = _store.Read();
        }
        catch (Exception) { return null; }

        var kept = SavedAccounts.FromJson(json).Accounts.FirstOrDefault(a => a.Key == Account.Key)?.Nous;
        if (kept == null || kept.SamePair(tokens) || kept.UserId != tokens.UserId) return null;
        if (_renewals.IsSpent(kept)) return null;
        var live = _renewals.Latest(kept);
        return live.SamePair(tokens) ? null : live;
    }

    // ------------------------------------------------------------------ ws ticket

    /// Single use, 30 s life, minted immediately before each dial, one request in flight (spec 01 §9).
    public async Task<string> MintTicketAsync(TimeSpan timeout, CancellationToken ct)
    {
        await _ticketGate.WaitAsync(ct);
        try
        {
            var a = await SendAsync(HttpMethod.Post, "/api/auth/ws-ticket", null, new JsonObject(), timeout, ct: ct);
            if (a.Status is 401 or 403)
            {
                if (GatewayRefusal.IsHermes(a.Body))
                {
                    EndSession();
                    throw new GatewayException("session-ended", "Sign in again.", a.Status);
                }
                throw new GatewayException("blocked",
                    "Something in front of Hermes turned this PC away, such as a proxy or a firewall. You’re still signed in, and Hermes HQ keeps trying.",
                    a.Status);
            }
            if (a.Status is 404 or 405)
                throw new GatewayException("gateway-outdated", "This Hermes is too old for the app. Update Hermes.", a.Status);
            var json = Require(a);
            return json.Text("ticket") ?? throw new GatewayException("not-hermes", "The gateway sent no ticket.");
        }
        finally { _ticketGate.Release(); }
    }

    /// The cookie header for the WebSocket upgrade (password accounts).
    public string? CookieHeader(Uri socketUrl)
    {
        var http = new UriBuilder(socketUrl) { Scheme = socketUrl.Scheme == "wss" ? "https" : "http", Port = socketUrl.Port }.Uri;
        var h = Jar.GetCookieHeader(http);
        return h.Length > 0 ? h : null;
    }

    // ------------------------------------------------------------------ persistence

    private void SaveCookiesIfChanged()
    {
        if (IsNous) return;
        var sig = CookieSignature();
        if (sig == _savedCookieSignature) return;
        _savedCookieSignature = sig;
        Account = Account with { Cookies = Jar.GetAllCookies().Select(FromCookie).ToList() };
        PersistCookies();
    }

    private string CookieSignature() =>
        string.Join(";", Jar.GetAllCookies().OrderBy(c => c.Name).Select(c => c.Name + "=" + c.Value));

    private bool PersistNous(NousTokens expected, NousTokens renewed)
    {
        try
        {
            lock (StoreLocks.GetOrCreateValue(_store))
            {
                var saved = SavedAccounts.FromJson(_store.Read());
                var idx = saved.Accounts.FindIndex(a => a.Key == Account.Key);
                if (idx >= 0)
                {
                    var existing = saved.Accounts[idx];
                    // Never resurrect an explicitly signed-out entry or clobber a newer unrelated sign-in.
                    if (existing.Nous == null) return true;
                    if (!existing.Nous.SamePair(expected) && !_renewals.IsSpent(existing.Nous))
                        return true;
                    saved.Accounts[idx] = existing with { Nous = renewed };
                }
                else
                {
                    saved.Upsert(Account with { Nous = renewed });
                }
                _store.Write(saved.ToJson());
                return true;
            }
        }
        catch (Exception)
        {
            return false;
        }
    }

    private void PersistCookies()
    {
        lock (StoreLocks.GetOrCreateValue(_store))
        {
            var saved = SavedAccounts.FromJson(_store.Read());
            var existing = saved.Accounts.FirstOrDefault(a => a.Key == Account.Key);
            // The name given on this PC belongs to the store (Rename writes it there): a session's copy may be older.
            if (existing != null) saved.Accounts[saved.Accounts.IndexOf(existing)] = Account with { Label = existing.Label };
            else saved.Upsert(Account);
            _store.Write(saved.ToJson());
        }
    }

    private void PersistEndSession(NousTokens? expectedNous)
    {
        try
        {
            lock (StoreLocks.GetOrCreateValue(_store))
            {
                var saved = SavedAccounts.FromJson(_store.Read());
                var idx = saved.Accounts.FindIndex(a => a.Key == Account.Key);
                if (idx >= 0)
                {
                    var existing = saved.Accounts[idx];
                    // H9 CAS: a stale session must never wipe a newer sign-in's Nous pair in storage.
                    if (expectedNous != null && existing.Nous != null
                        && !existing.Nous.SamePair(expectedNous) && !_renewals.IsSpent(existing.Nous))
                        return;
                    saved.Accounts[idx] = existing.WithoutSession;
                }
                else
                {
                    saved.Upsert(Account);
                }
                _store.Write(saved.ToJson());
            }
        }
        catch (Exception) { }
    }

    /// After a sign-in: saved, first in the list and current. `label` is the form's Name (null keeps the saved one).
    public void Save(string? label = null)
    {
        if (!IsNous) Account = Account with { Cookies = Jar.GetAllCookies().Select(FromCookie).ToList() };
        _savedCookieSignature = CookieSignature();
        _renewals.ForgetUnsaved(Account.Key);
        lock (StoreLocks.GetOrCreateValue(_store))
        {
            var saved = SavedAccounts.FromJson(_store.Read());
            saved.Upsert(Account with { Label = label });
            Account = saved.Accounts[0];
            _store.Write(saved.ToJson());
        }
    }

    internal void UpdateAccount(StoredAccount account) => Account = account;

    private void EndSession()
    {
        var expectedNous = Account.Nous;
        foreach (Cookie c in Jar.GetAllCookies()) c.Expired = true;
        Account = Account with { Cookies = null, Nous = null };
        _renewals.ForgetUnsaved(Account.Key);
        PersistEndSession(expectedNous);
        Ended?.Invoke();
    }

    /// Sign out: password accounts tell the gateway (a 302 is fine); Nous accounts have no revocation.
    public async Task SignOutAsync()
    {
        if (!IsNous)
        {
            try { await RawAsync(HttpMethod.Post, "/auth/logout", null, new JsonObject(), TimeSpan.FromSeconds(5), default); }
            catch (GatewayException) { }
        }
        foreach (Cookie c in Jar.GetAllCookies()) c.Expired = true;
        _renewals.ForgetUnsaved(Account.Key);
        lock (StoreLocks.GetOrCreateValue(_store))
        {
            var saved = SavedAccounts.FromJson(_store.Read());
            var i = saved.Accounts.FindIndex(a => a.Key == Account.Key);
            if (i >= 0) saved.Accounts[i] = saved.Accounts[i].WithoutSession;
            _store.Write(saved.ToJson());
        }
    }

    /// Tells the gateway this session is over (password accounts; a 302 is fine), within `timeout`, without touching
    /// the saved accounts (Remove Gateway deletes the entry itself).
    public async Task LogoutAsync(TimeSpan timeout)
    {
        if (IsNous) return;
        try { await RawAsync(HttpMethod.Post, "/auth/logout", null, new JsonObject(), timeout, default); }
        catch (GatewayException) { }
        catch (OperationCanceledException) { }
    }

    private static Cookie ToCookie(SavedCookie c)
    {
        var k = new Cookie(c.Name, c.Value, c.Path, c.Domain) { Secure = c.Secure, HttpOnly = c.HttpOnly ?? false };
        if (c.Expires is { } e) k.Expires = DateTimeOffset.FromUnixTimeSeconds((long)e).UtcDateTime;
        return k;
    }

    private static SavedCookie FromCookie(Cookie c) => new(c.Name, c.Value, c.Domain, c.Path,
        c.Expires == DateTime.MinValue ? null : new DateTimeOffset(c.Expires.ToUniversalTime()).ToUnixTimeSeconds(),
        c.Secure, c.HttpOnly);

    private void DisposeTransportNow()
    {
        if (Interlocked.Exchange(ref _transportDisposed, 1) != 0) return;
        try { _disposeCts.Cancel(); } catch (ObjectDisposedException) { }
        _http.Dispose();
        _disposeCts.Dispose();
    }

    /// Synchronous disposal: disposes immediately when no Nous renewal is in flight; otherwise settles the active
    /// renewal in the background before closing the HTTP transport so a rotated refresh token is never lost.
    public void Dispose()
    {
        if (Interlocked.Exchange(ref _closing, 1) != 0) return;
        bool hasFlight;
        lock (_flightLock) hasFlight = _activeRenewal is { IsCompleted: false };
        if (!hasFlight)
        {
            DisposeTransportNow();
            return;
        }
        _ = Task.Run(async () =>
        {
            try { await SettleRenewalAsync().ConfigureAwait(false); }
            catch (Exception) { }
            finally { DisposeTransportNow(); }
        });
    }

    public async ValueTask DisposeAsync()
    {
        Interlocked.Exchange(ref _closing, 1);
        try { await SettleRenewalAsync().ConfigureAwait(false); }
        finally { DisposeTransportNow(); }
    }
}
