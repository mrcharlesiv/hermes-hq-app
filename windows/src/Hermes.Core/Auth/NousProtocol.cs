using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Net;

namespace Hermes.Core.Auth;

/// [kept-session] Who wrote a refusal (ShareKit/GatewayRefusal.swift). A 400, 401 or 403 ends a saved sign-in only
/// when Hermes itself wrote it — never a reverse proxy, Cloudflare challenge, or captive portal page.
public static class GatewayRefusal
{
    /// True when `body` is a refusal Hermes writes: a JSON object with a string `error` (session gate, native refresh,
    /// Nous edge) or a non-null `detail` (FastAPI routes). Empty bodies, HTML, plain text, and Cloudflare JSON errors
    /// (`cloudflare_error`) return false.
    public static bool IsHermes(string? body)
    {
        if (string.IsNullOrWhiteSpace(body)) return false;
        if (J.Parse(body) is not JsonObject obj) return false;
        if (obj.ContainsKey("cloudflare_error")) return false;
        if (obj.TryGetPropertyValue("error", out var error)
            && error is JsonValue errVal && errVal.TryGetValue(out string? _))
            return true;
        return obj.TryGetPropertyValue("detail", out var detail) && detail != null;
    }

    public static bool IsHermes(byte[]? body) =>
        body is { Length: > 0 } && IsHermes(Encoding.UTF8.GetString(body));
}

/// Pure helpers on `NousTokens` matching HermesKit/Net/SavedAccounts.swift (`canRenew`, `samePair`, `needsKeepAlive`).
public static class NousTokensExtensions
{
    public static bool CanRenew(this NousTokens tokens) => !string.IsNullOrEmpty(tokens.RefreshToken);

    public static bool SamePair(this NousTokens tokens, NousTokens? other) =>
        other != null
        && tokens.AccessToken == other.AccessToken
        && tokens.RefreshToken == other.RefreshToken
        && tokens.UserId == other.UserId;

    public static bool IsExpired(this NousTokens tokens, DateTimeOffset now) =>
        double.IsFinite(tokens.ExpiresAt)
        && tokens.ExpiresAt > 0
        && now.ToUnixTimeMilliseconds() / 1000.0 >= tokens.ExpiresAt;

    /// True when the access token is in its renewal window (`NeedsRenewal`) or already past `ExpiresAt`.
    public static bool IsDueOrExpired(this NousTokens tokens, DateTimeOffset now) =>
        tokens.CanRenew() && (tokens.NeedsRenewal(now) || tokens.IsExpired(now));

    public static bool NeedsKeepAlive(this NousTokens tokens, TimeSpan? interval = null, DateTimeOffset? now = null) =>
        NousSessionKeepAlive.RefreshDue(tokens, interval, now);
}

/// RFC 8252 native PKCE through the gateway (HermesKit/Net/NousProtocol.swift). The gateway is the authorization
/// server; the app never talks to the Nous Portal directly.
public static class NousProtocol
{
    public sealed record Pkce(string Verifier, string Challenge, string State);

    public static Pkce NewPkce()
    {
        var verifier = Base64Url(RandomNumberGenerator.GetBytes(64)); // 86 characters
        var challenge = Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));
        return new Pkce(verifier, challenge, Base64Url(RandomNumberGenerator.GetBytes(32)));
    }

    public static string Base64Url(byte[] bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    public static bool SameState(string? a, string b) =>
        a != null && CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(a), Encoding.UTF8.GetBytes(b));

    public static Uri AuthorizeUrl(GatewayAddress gw, Pkce p, Uri redirect) => gw.Endpoint("/auth/native/authorize",
    [
        new("provider", "nous"),
        new("code_challenge", p.Challenge),
        new("code_challenge_method", "S256"),
        new("redirect_uri", redirect.ToString()),
        new("state", p.State),
    ]);

    /// /api/status says Nous is offered.
    public static bool Offered(JsonNode? status) =>
        (status.Arr("auth_providers")?.Any(p => J.AsString(p) == "nous") ?? false)
        && (status.Arr("auth_flows")?.Any(p => J.AsString(p) == "native_pkce") ?? false);

    /// Whether a `/auth/native/refresh` answer means Hermes is still rotating this refresh token upstream
    /// (`503 {"error":"refresh_pending", ...}`): the caller should retry the same pair after `RetryAfter`.
    public static bool IsRefreshPending(int status, string? body) =>
        status == 503
        && !string.IsNullOrWhiteSpace(body)
        && J.Parse(body) is JsonObject obj
        && obj.Str("error") == "refresh_pending";

    public static bool IsRefreshPending(HttpAnswer answer) => IsRefreshPending(answer.Status, answer.Body);

    /// Parses a `Retry-After` header (delta-seconds or HTTP-date); null when absent, unreadable, non-finite, or <= 0.
    /// Mirrors `RetryLater.parse` (HermesKit/Net/ConnectionSupport.swift).
    public static TimeSpan? ParseRetryAfterHeader(string? header, DateTimeOffset? now = null)
    {
        var text = header?.Trim();
        if (string.IsNullOrEmpty(text)) return null;
        if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds))
            return double.IsFinite(seconds) && seconds > 0 ? TimeSpan.FromSeconds(Math.Min(seconds, 86400)) : null;
        if (DateTimeOffset.TryParseExact(text, "r", CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var date)
            || DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out date))
        {
            var wait = date - (now ?? DateTimeOffset.UtcNow);
            return wait > TimeSpan.Zero ? wait : null;
        }
        return null;
    }

    /// Retry wait from a `Retry-After` header string, falling back to a JSON `"retry_after"` number in the body.
    /// Mirrors `NousGatewayProtocol.retryAfter` (HermesKit/Net/NousProtocol.swift).
    public static TimeSpan? RetryAfter(string? header, string? body, DateTimeOffset? now = null)
    {
        if (ParseRetryAfterHeader(header, now) is { } fromHeader) return fromHeader;
        if (string.IsNullOrWhiteSpace(body) || J.Parse(body) is not JsonObject obj) return null;
        var seconds = obj.Num("retry_after");
        if (seconds is not { } s || !double.IsFinite(s) || s <= 0) return null;
        return TimeSpan.FromSeconds(Math.Min(s, 86400));
    }

    /// Retry wait from an `HttpAnswer`'s `Retry-After` header or JSON `"retry_after"` body field.
    public static TimeSpan? RetryAfter(HttpAnswer answer, DateTimeOffset? now = null)
    {
        if (answer.Headers?.RetryAfter is { } ra)
        {
            if (ra.Delta is { } d && d > TimeSpan.Zero) return d;
            if (ra.Date is { } dt)
            {
                var wait = dt - (now ?? DateTimeOffset.UtcNow);
                if (wait > TimeSpan.Zero) return wait;
            }
        }
        string? rawHeader = null;
        if (answer.Headers != null && answer.Headers.TryGetValues("Retry-After", out var values))
            rawHeader = values.FirstOrDefault();
        return RetryAfter(rawHeader, answer.Body, now);
    }

    /// A 200 from /auth/native/token or /auth/native/refresh → tokens; null when it isn't a usable pair.
    internal static NousTokens? ParseTokens(HttpAnswer a, DateTimeOffset now)
    {
        var j = a.Json;
        if (a.Status != 200 || j == null) return null;
        var access = j.Text("access_token");
        var refresh = j.Text("refresh_token");
        var user = j.Text("user_id");
        if (access == null || refresh == null || user == null || j.Str("provider") != "nous") return null;
        var rawExpires = j.Num("expires_at") ?? 0;
        var expires = double.IsFinite(rawExpires) && rawExpires >= 0 && rawExpires <= 1e12 ? rawExpires : 0;
        return new NousTokens(access, refresh, expires, user, now.ToUnixTimeMilliseconds() / 1000.0);
    }

    /// Token-exchange failure → the plain-language error (spec 01 §6).
    internal static GatewayException ExchangeError(HttpAnswer a)
    {
        if (a.Status is 400 or 401 or 403 && !GatewayRefusal.IsHermes(a.Body))
            return new GatewayException("blocked",
                "Something in front of Hermes turned this PC away, such as a proxy or a firewall. Try again.", a.Status);
        var reason = a.Json.Text("error");
        return a.Status switch
        {
            400 or 401 => new GatewayException("nous-failed", "Nous sign-in didn't finish. Try again.", a.Status),
            403 when (reason ?? "not_authorized") == "not_authorized" =>
                new GatewayException("not-owner", "This Nous account isn't allowed on this gateway.", 403),
            403 => new GatewayException("nous-failed", "Nous sign-in was refused.", 403),
            429 => new GatewayException("rate-limited", "Too many tries. Wait a minute, then try again.", 429),
            _ => new GatewayException("nous-unavailable", "Nous sign-in isn't available right now.", a.Status),
        };
    }
}

/// Keeps saved Nous sessions alive before Portal's 24 h rotating refresh token expires
/// (HermesKit/Net/AccountProbe.swift `NousSessionKeepAlive`).
public static class NousSessionKeepAlive
{
    public static readonly TimeSpan DefaultInterval = TimeSpan.FromHours(4);

    /// Whether `tokens` has sat untouched long enough (>= `olderThan`, default 4 h) to warrant a proactive keep-alive.
    /// Mirrors `NousTokens.needsKeepAlive(after:now:)` (HermesKit/Net/SavedAccounts.swift).
    public static bool RefreshDue(NousTokens tokens, TimeSpan? olderThan = null, DateTimeOffset? now = null)
    {
        if (!tokens.CanRenew()) return false;
        var interval = (olderThan ?? DefaultInterval).TotalSeconds;
        var t = (now ?? DateTimeOffset.UtcNow).ToUnixTimeMilliseconds() / 1000.0;
        if (tokens.ObtainedAt is { } got && double.IsFinite(got))
            return t - got >= interval;
        return double.IsFinite(tokens.ExpiresAt) && tokens.ExpiresAt > 0 && t >= tokens.ExpiresAt;
    }

    /// Refreshes all saved Nous accounts in `store` whose latest known pair is at least `olderThan` (default 4 h) old.
    /// Skips fresh accounts, non-Nous accounts, and locked/unavailable token stores. Returns how many refreshed.
    public static async Task<int> RefreshDueAsync(ITokenStore store, TimeSpan? olderThan = null,
        Func<DateTimeOffset>? now = null, NousRenewals? renewals = null,
        Func<StoredAccount, GatewaySession?>? makeSession = null, CancellationToken ct = default)
    {
        string? json;
        try { json = store.Read(); }
        catch (TokenStoreUnavailableException) { return 0; }
        catch (Exception) { return 0; }

        var saved = SavedAccounts.FromJson(json);
        var interval = olderThan ?? DefaultInterval;
        var clock = now ?? (() => DateTimeOffset.UtcNow);
        var coordinator = renewals ?? NousRenewals.Shared;
        var refreshed = 0;

        foreach (var stored in saved.Accounts)
        {
            if (ct.IsCancellationRequested) break;
            if (!stored.IsNous || stored.Nous is not { } tokens || !tokens.CanRenew()) continue;
            var live = coordinator.Latest(tokens);
            if (!RefreshDue(live, interval, clock())) continue;

            GatewaySession? session;
            if (makeSession != null)
            {
                session = makeSession(stored);
            }
            else
            {
                GatewayAddress gw;
                try { gw = GatewayAddress.Validated(stored.Url); }
                catch (GatewayException) { continue; }
                session = new GatewaySession(gw, stored, store, renewals: coordinator, now: clock);
            }
            if (session == null) continue;

            await using (session)
            {
                try
                {
                    if (await session.KeepAliveAsync(interval, clock(), ct).ConfigureAwait(false))
                        refreshed++;
                }
                catch (Exception e) when (e is GatewayException or HttpRequestException or OperationCanceledException)
                {
                }
            }
        }
        return refreshed;
    }
}
