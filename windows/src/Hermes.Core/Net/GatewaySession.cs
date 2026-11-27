using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Auth;

namespace Hermes.Core.Net;

public sealed record HttpAnswer(int Status, string Body, HttpResponseHeaders Headers)
{
    public JsonNode? Json => J.Parse(Body);
    public bool Ok => Status is >= 200 and < 300;
}

/// One signed-in account: its own cookie jar, the bearer for Nous accounts, refresh-once-on-401, and saving rotated
/// credentials before they are used (GatewayAuth.swift). Redirects are never followed (real Hermes answers
/// /auth/logout with a 302).
public sealed partial class GatewaySession : IDisposable
{
    public GatewayAddress Address { get; }
    public StoredAccount Account { get; private set; }
    public CookieContainer Jar { get; } = new();

    private readonly ITokenStore _store;
    private readonly HttpClient _http;
    private readonly SemaphoreSlim _refreshGate = new(1, 1);
    private readonly SemaphoreSlim _ticketGate = new(1, 1);
    // Spent refresh token → the pair that replaced it, so a caller holding an old pair never replays a spent token
    // (replay revokes the whole family). Chains of up to 16.
    private readonly Dictionary<string, NousTokens> _successors = [];
    private string _savedCookieSignature = "";

    /// Raised when the session ended server-side (refresh refused); the UI shows "Sign in again".
    public event Action? Ended;

    public GatewaySession(GatewayAddress address, StoredAccount account, ITokenStore store, HttpMessageHandler? handler = null)
    {
        Address = address;
        Account = account;
        _store = store;
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

    public bool IsNous => Account.Nous != null;

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
            if (Account.Nous is { } n && n.NeedsRenewal(DateTimeOffset.UtcNow)) await RefreshAsync(n, ct);
            else if (Account.Nous is { } m && m.RenewsAlongside(DateTimeOffset.UtcNow)) _ = RenewQuietly(m);

            var answer = await RawAsync(method, path, query, body, timeout, ct);
            ct.ThrowIfCancellationRequested(); // a late response must not initiate a retry or a cookie-store write
            if (answer.Status == 401 && refreshOn401 && path.Contains("/api/"))
            {
                if (await RefreshAfter401Async(ct)) answer = await RawAsync(method, path, query, body, timeout, ct);
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

    private async Task<bool> RefreshAfter401Async(CancellationToken ct)
    {
        if (Account.Nous is { } n) return await RefreshAsync(n, ct, force: true);
        // Cookie session: the server renews by itself; ask /api/auth/me once (spec 01 §5.3).
        var me = await RawAsync(HttpMethod.Get, "/api/auth/me", null, null, TimeSpan.FromSeconds(15), ct);
        ct.ThrowIfCancellationRequested();
        if (me.Ok && me.Json is JsonObject) { SaveCookiesIfChanged(); return true; }
        EndSession();
        return false;
    }

    private async Task RenewQuietly(NousTokens sent)
    {
        try { await RefreshAsync(sent, CancellationToken.None); } catch { /* the next request will try again */ }
    }

    /// Single flight per account. Returns true when a usable pair is now in place.
    internal async Task<bool> RefreshAsync(NousTokens sent, CancellationToken ct, bool force = false)
    {
        await _refreshGate.WaitAsync(ct);
        try
        {
            // Another caller already rotated this pair while we waited: use the successor, never replay a spent token.
            if (_successors.ContainsKey(sent.RefreshToken)
                || (Account.Nous is { } now && now.RefreshToken != sent.RefreshToken)) return true;
            // Another client (or process) may have rotated it in storage.
            var stored = SavedAccounts.FromJson(_store.Read()).Accounts.FirstOrDefault(a => a.Key == Account.Key)?.Nous;
            if (stored != null && stored.RefreshToken != sent.RefreshToken && stored.UserId == sent.UserId
                && !_successors.ContainsKey(stored.RefreshToken))
            {
                Account = Account with { Nous = stored };
                return true;
            }
            if (!force && !sent.NeedsRenewal(DateTimeOffset.UtcNow) && !sent.RenewsAlongside(DateTimeOffset.UtcNow))
                return true;

            var a = await RawAsync(HttpMethod.Post, "/auth/native/refresh", null,
                new JsonObject { ["refresh_token"] = sent.RefreshToken, ["provider"] = "nous" },
                TimeSpan.FromSeconds(15), ct);
            if (a.Status is 400 or 401 or 403) { EndSession(); return false; }
            if (!a.Ok) return false; // 429, 5xx: keep the session, this request fails
            var fresh = NousProtocol.ParseTokens(a, DateTimeOffset.UtcNow);
            if (fresh == null || fresh.UserId != sent.UserId) { EndSession(); return false; }
            _successors[sent.RefreshToken] = fresh;
            // Save before use, compare-and-swap against what we sent.
            Account = Account with { Nous = fresh };
            Persist(expected: sent);
            return true;
        }
        finally { _refreshGate.Release(); }
    }

    // ------------------------------------------------------------------ ws ticket

    /// Single use, 30 s life, minted immediately before each dial, one request in flight (spec 01 §9).
    public async Task<string> MintTicketAsync(TimeSpan timeout, CancellationToken ct)
    {
        await _ticketGate.WaitAsync(ct);
        try
        {
            var a = await SendAsync(HttpMethod.Post, "/api/auth/ws-ticket", null, new JsonObject(), timeout, ct: ct);
            if (a.Status is 401 or 403) { EndSession(); throw new GatewayException("session-ended", "Sign in again.", a.Status); }
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
        Persist(expected: null);
    }

    private string CookieSignature() =>
        string.Join(";", Jar.GetAllCookies().OrderBy(c => c.Name).Select(c => c.Name + "=" + c.Value));

    private void Persist(NousTokens? expected)
    {
        var saved = SavedAccounts.FromJson(_store.Read());
        var existing = saved.Accounts.FirstOrDefault(a => a.Key == Account.Key);
        if (expected != null && existing?.Nous != null && existing.Nous.RefreshToken != expected.RefreshToken
            && !_successors.ContainsKey(existing.Nous.RefreshToken))
            return; // someone else wrote a newer pair; don't clobber it
        // The name given on this PC belongs to the store (Rename writes it there): a session's copy may be older.
        if (existing != null) saved.Accounts[saved.Accounts.IndexOf(existing)] = Account with { Label = existing.Label };
        else saved.Upsert(Account);
        _store.Write(saved.ToJson());
    }

    /// After a sign-in: saved, first in the list and current. `label` is the form's Name (null keeps the saved one).
    public void Save(string? label = null)
    {
        if (!IsNous) Account = Account with { Cookies = Jar.GetAllCookies().Select(FromCookie).ToList() };
        _savedCookieSignature = CookieSignature();
        var saved = SavedAccounts.FromJson(_store.Read());
        saved.Upsert(Account with { Label = label });
        Account = saved.Accounts[0];
        _store.Write(saved.ToJson());
    }

    internal void UpdateAccount(StoredAccount account) => Account = account;

    private void EndSession()
    {
        foreach (Cookie c in Jar.GetAllCookies()) c.Expired = true;
        Account = Account with { Cookies = null, Nous = null };
        Persist(null);
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
        var saved = SavedAccounts.FromJson(_store.Read());
        var i = saved.Accounts.FindIndex(a => a.Key == Account.Key);
        if (i >= 0) saved.Accounts[i] = saved.Accounts[i].WithoutSession;
        _store.Write(saved.ToJson());
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

    public void Dispose() => _http.Dispose();
}
