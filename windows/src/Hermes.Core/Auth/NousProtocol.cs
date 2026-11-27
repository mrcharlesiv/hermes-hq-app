using System.Security.Cryptography;
using System.Text;
using Hermes.Core.Net;

namespace Hermes.Core.Auth;

/// RFC 8252 native PKCE through the gateway (HermesKit/Auth/NousProtocol.swift). The gateway is the authorization
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
    public static bool Offered(System.Text.Json.Nodes.JsonNode? status) =>
        (status.Arr("auth_providers")?.Any(p => J.AsString(p) == "nous") ?? false)
        && (status.Arr("auth_flows")?.Any(p => J.AsString(p) == "native_pkce") ?? false);

    /// A 200 from /auth/native/token or /auth/native/refresh → tokens; null when it isn't a usable pair.
    internal static NousTokens? ParseTokens(HttpAnswer a, DateTimeOffset now)
    {
        var j = a.Json;
        if (a.Status != 200 || j == null) return null;
        var access = j.Text("access_token");
        var refresh = j.Text("refresh_token");
        var user = j.Text("user_id");
        if (access == null || refresh == null || user == null || j.Str("provider") != "nous") return null;
        return new NousTokens(access, refresh, j.Num("expires_at") ?? 0, user, now.ToUnixTimeMilliseconds() / 1000.0);
    }

    /// Token-exchange failure → the plain-language error (spec 01 §6).
    internal static GatewayException ExchangeError(HttpAnswer a)
    {
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
