using System.Globalization;
using System.Text.Json.Nodes;
using Hermes.Core.Net;

namespace Hermes.Core.Auth;

/// The sign-in flows (HermesKit/Auth/SignInFlows.swift, spec 01 §4–§7).
public sealed class SignIn(ITokenStore store, Func<HttpMessageHandler>? handlerFactory = null)
{
    /// `Known`: the address answered as Hermes and listed its ways in. `Answered`: it answered, without listing them.
    public sealed record Probe(bool Nous, bool Password, JsonNode? Status, bool Known = true, bool Answered = false)
    {
        public static readonly Probe Unknown = new(true, true, null, Known: false);
    }

    /// Chooses which buttons to show. Anything but a 200 JSON object with auth_providers is "unknown": show both.
    public async Task<Probe> ProbeAsync(GatewayAddress gw, CancellationToken ct = default)
    {
        using var s = Session(gw, new StoredAccount(gw.ToString(), ""));
        try
        {
            var a = await s.SendAsync(HttpMethod.Get, "/api/status", timeout: TimeSpan.FromSeconds(5), refreshOn401: false, ct: ct);
            var j = a.Json;
            if (a.Status != 200 || j?.Arr("auth_providers") is not { } providers) return Probe.Unknown with { Answered = true };
            return new Probe(NousProtocol.Offered(j), providers.Any(p => J.AsString(p) == "basic"), j);
        }
        catch (GatewayException) { return Probe.Unknown; }
    }

    /// Exactly one login attempt per user action; the server allows 10 per minute per IP.
    /// `label`: the form's optional Name, kept on this PC as the account's label, never sent to the gateway.
    public async Task<GatewaySession> PasswordAsync(GatewayAddress gw, string username, string password,
        CancellationToken ct = default, string? label = null)
    {
        ct.ThrowIfCancellationRequested();
        var s = Session(gw, new StoredAccount(gw.ToString(), username.Trim()));
        try
        {
            var providers = await s.SendAsync(HttpMethod.Get, "/api/auth/providers", refreshOn401: false, ct: ct);
            ct.ThrowIfCancellationRequested();
            if (providers.Status == 404) throw await OutdatedOrNotHermes(s, ct);
            var list = GatewaySession.Require(providers).Arr("providers");
            var provider = list?.FirstOrDefault(p => p.Bool("supports_password") == true)?.Text("name")
                ?? throw new GatewayException("no-password", "This gateway doesn't take a password. Use Sign in with Nous.");

            var login = await s.SendAsync(HttpMethod.Post, "/auth/password-login", body: new JsonObject
            {
                ["provider"] = provider, ["username"] = username.Trim(), ["password"] = password,
            }, refreshOn401: false, ct: ct);
            ct.ThrowIfCancellationRequested();
            if (login.Status == 401)
                throw new GatewayException("bad-password", "That username or password isn't right.", 401);
            if (GatewaySession.Require(login) is not JsonObject)
                throw new GatewayException("not-hermes", "The gateway's answer wasn't what Hermes sends.");

            await VerifyAsync(s, ct);
            ct.ThrowIfCancellationRequested(); // a verification reply can already be posted to the closing window
            s.UpdateAccount(s.Account with { Provider = provider });
            s.Save(AccountLabel(label));
            return s;
        }
        catch { s.Dispose(); throw; }
    }

    /// Sign in with Nous: opens the system browser through openBrowser and waits for the loopback callback.
    public async Task<GatewaySession> NousAsync(GatewayAddress gw, Func<Uri, Task> openBrowser,
        CancellationToken ct = default, string? label = null)
    {
        var s = Session(gw, new StoredAccount(gw.ToString(), ""));
        try
        {
            var status = await s.SendAsync(HttpMethod.Get, "/api/status", refreshOn401: false, ct: ct);
            if (status.Status == 429) throw GatewaySession.HttpError(status);
            if (status.Status == 400 && status.Body.Contains("Invalid Host header")) throw GatewaySession.HttpError(status);
            if (status.Status != 200 || status.Json is not JsonObject sj || !sj.ContainsKey("auth_required"))
                throw new GatewayException("not-hermes", "That address doesn't answer like a Hermes gateway.");
            if (!NousProtocol.Offered(sj))
                throw new GatewayException("nous-unavailable", "This gateway doesn't offer Sign in with Nous.");

            ct.ThrowIfCancellationRequested();
            var pkce = NousProtocol.NewPkce();
            using var relay = new LoopbackRelay();
            var wait = relay.WaitAsync(ct);
            await openBrowser(NousProtocol.AuthorizeUrl(gw, pkce, relay.RedirectUri));
            LoopbackRelay.Callback cb;
            try { cb = await wait; }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            { throw new GatewayException("timeout", "Sign-in took too long. Try again."); }
            if (cb.Error == "cancelled") throw new GatewayException("nous-cancelled", "Sign-in was cancelled.");
            if (cb.Code == null || !NousProtocol.SameState(cb.State, pkce.State))
                throw new GatewayException("nous-failed", "Nous sign-in didn't finish. Try again.");

            ct.ThrowIfCancellationRequested();
            var token = await s.SendAsync(HttpMethod.Post, "/auth/native/token", body: new JsonObject
            {
                ["code"] = cb.Code, ["code_verifier"] = pkce.Verifier,
            }, refreshOn401: false, ct: ct);
            if (token.Status != 200) throw NousProtocol.ExchangeError(token);
            var tokens = NousProtocol.ParseTokens(token, DateTimeOffset.UtcNow)
                ?? throw new GatewayException("nous-unavailable", "Nous sign-in isn't available right now.", 502);

            var account = new StoredAccount(gw.ToString(), "nous:" + tokens.UserId, Nous: tokens);
            s.Dispose();
            s = Session(gw, account);
            await VerifyAsync(s, ct);
            ct.ThrowIfCancellationRequested();
            s.Save(AccountLabel(label));
            return s;
        }
        catch { s.Dispose(); throw; }
    }

    /// The form's Name as a label: trimmed, at most 60 characters, null when empty.
    public static string? AccountLabel(string? name)
    {
        var t = name?.Trim() ?? "";
        if (t.Length == 0) return null;
        var e = System.Globalization.StringInfo.GetTextElementEnumerator(t);
        var sb = new System.Text.StringBuilder();
        var n = 0;
        while (e.MoveNext() && n++ < 60) sb.Append(e.GetTextElement());
        return sb.ToString();
    }

    /// What a launch finds (HermesKit `SignInService.RestoreState`): a session to resume, nothing (the form, prefilled
    /// with the saved gateway when there is one), or a store that can't be read right now (the offline screen).
    public abstract record RestoreState
    {
        public sealed record SignedIn(GatewaySession Session) : RestoreState;
        public sealed record SignedOut(StoredAccount? Prefill, bool Ended) : RestoreState;
        public sealed record Unavailable(string Reason) : RestoreState;
    }

    /// At launch: the current account with a session goes straight in, whatever the network says (the app shows the
    /// launch screen and reconnects); none, the sign-in form prefilled with the last gateway. Nothing is sent here.
    public RestoreState Restore()
    {
        string? json;
        try { json = store.Read(); }
        catch (TokenStoreUnavailableException) { return new RestoreState.Unavailable("keychain-unavailable"); }
        if (!SavedAccounts.TryFromJson(json, out var saved)) return new RestoreState.Unavailable("keychain-unreadable");
        if (saved.CurrentAccount is not { } account) return new RestoreState.SignedOut(null, false);
        if (!account.IsSignedIn) return new RestoreState.SignedOut(account, false);
        try { return new RestoreState.SignedIn(Session(GatewayAddress.Validated(account.Url), account)); }
        catch (GatewayException) { return new RestoreState.SignedOut(account, false); }
    }

    /// A saved account's session (a switch, a news check), or null when it has none.
    public GatewaySession? Resume(StoredAccount account)
    {
        if (!account.IsSignedIn) return null;
        try { return Session(GatewayAddress.Validated(account.Url), account); }
        catch (GatewayException) { return null; }
    }

    /// One read of the gateway's status with the account's session (docs/spec/3x-onboarding.md §5.14). Unknown on any
    /// failure: it never blocks.
    public static async Task<Gateways.GatewayCompatibility> CompatibilityAsync(GatewaySession s, CancellationToken ct)
    {
        try
        {
            var a = await s.SendAsync(HttpMethod.Get, "/api/status", timeout: Gateways.GatewayCompatibility.CheckTime, ct: ct);
            return a.Ok ? Gateways.GatewayCompatibility.From(a.Json) : Gateways.GatewayCompatibility.Unknown;
        }
        catch (Exception e) when (e is GatewayException or OperationCanceledException or HttpRequestException)
        {
            return Gateways.GatewayCompatibility.Unknown;
        }
    }

    /// At launch: the saved current account, verified by one /api/auth/me within 7 s. A slow or offline gateway still
    /// restores (the app shows cached bots and reconnects); only a refusal ends it.
    public async Task<GatewaySession?> RestoreAsync(CancellationToken ct = default)
    {
        var saved = SavedAccounts.FromJson(store.Read());
        if (saved.CurrentAccount is not { IsSignedIn: true } account) return null;
        GatewayAddress gw;
        try { gw = GatewayAddress.Validated(account.Url); } catch (GatewayException) { return null; }
        var s = Session(gw, account);
        try
        {
            using var t = CancellationTokenSource.CreateLinkedTokenSource(ct);
            t.CancelAfter(TimeSpan.FromSeconds(7));
            var me = await s.SendAsync(HttpMethod.Get, "/api/auth/me", timeout: TimeSpan.FromSeconds(7), ct: t.Token);
            if (me.Status is 401 or 403 && !s.Account.IsSignedIn) { s.Dispose(); return null; }
        }
        catch (Exception e) when (e is GatewayException or OperationCanceledException) { }
        return s;
    }

    public SavedAccounts Saved() => SavedAccounts.FromJson(store.Read());

    /// Typed sign-ins only: release_date earlier than 2026.9.21 means "Update Hermes". Never compare version strings.
    public static bool IsOutdated(JsonNode? status)
    {
        var parts = status.Str("release_date")?.Split('.');
        if (parts is not { Length: 3 }) return false;
        if (!int.TryParse(parts[0], NumberStyles.None, CultureInfo.InvariantCulture, out var y)
            || !int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out var m)
            || !int.TryParse(parts[2], NumberStyles.None, CultureInfo.InvariantCulture, out var d)) return false;
        return (y, m, d).CompareTo((2026, 9, 21)) < 0;
    }

    private static async Task VerifyAsync(GatewaySession s, CancellationToken ct)
    {
        var me = await s.SendAsync(HttpMethod.Get, "/api/auth/me", refreshOn401: false, ct: ct);
        if (!me.Ok || me.Json is not JsonObject)
            throw new GatewayException("not-hermes", "Signed in, but the gateway didn't confirm who you are.", me.Status);
    }

    private static async Task<GatewayException> OutdatedOrNotHermes(GatewaySession s, CancellationToken ct)
    {
        try
        {
            var st = await s.SendAsync(HttpMethod.Get, "/api/status", refreshOn401: false, ct: ct);
            if (st.Json.Str("version") != null)
                return new GatewayException("gateway-outdated", "This Hermes is too old for the app. Update Hermes.");
        }
        catch (GatewayException) { }
        return new GatewayException("not-hermes", "That address doesn't answer like a Hermes gateway.");
    }

    private GatewaySession Session(GatewayAddress gw, StoredAccount account) =>
        new(gw, account, store, handlerFactory?.Invoke());
}
