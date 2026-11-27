using Hermes.Core.Auth;

namespace Hermes.Core.Capabilities;

/// Signing in to a connector with OAuth (App/Capabilities/McpSignIn.swift, spec 3x §5.4): this PC listens on loopback
/// (`LoopbackRelay`, as Sign in with Nous does), the gateway starts the flow with that redirect, the provider's page
/// opens in the system browser, the relay hands the callback to the gateway and the gateway's poll says when it is done.
public sealed class McpSignIn(CapabilitiesApi api)
{
    public abstract record Outcome
    {
        public sealed record SignedIn(int Tools) : Outcome;
        public sealed record Cancelled : Outcome;
        public sealed record Failed(string Reason) : Outcome;
    }

    private static int _running;
    public TimeSpan Lifetime { get; set; } = TimeSpan.FromSeconds(360);
    public TimeSpan PollEvery { get; set; } = TimeSpan.FromSeconds(1);
    /// The stand-in gateway's sign-in page is loopback http.
    public bool AllowLoopbackHttp { get; set; }

    /// Only one sign-in at a time app-wide. `open` shows the page (the system browser); false: it couldn't.
    public async Task<Outcome> RunAsync(string server, string profile, Func<Uri, bool> open, CancellationToken ct = default)
    {
        if (Interlocked.CompareExchange(ref _running, 1, 0) != 0)
            return new Outcome.Failed("Another sign-in is still open. Finish or close it first.");
        try { return await FlowAsync(server, profile, open, ct); }
        finally { Interlocked.Exchange(ref _running, 0); }
    }

    private async Task<Outcome> FlowAsync(string server, string profile, Func<Uri, bool> open, CancellationToken ct)
    {
        LoopbackRelay relay;
        try { relay = new LoopbackRelay(); }
        catch (Exception) { return new Outcome.Failed("Couldn’t open the sign-in sheet. Try again."); }
        using var _ = relay;
        string? sessionId = null;
        Outcome outcome = new Outcome.Cancelled();
        try
        {
            var redirect = relay.RedirectUri.ToString();
            var started = await api.OAuthStartAsync(server, redirect, profile);
            sessionId = started.SessionId;
            if (McpSignInRules.Accepts(started.AuthUrl, redirect, AllowLoopbackHttp) is not { } url) return outcome = new Outcome.Failed(McpSignInRules.TooOld);
            using var life = CancellationTokenSource.CreateLinkedTokenSource(ct);
            var relayed = Task.Run(async () =>
            {
                var callback = await relay.WaitAsync(life.Token);
                if (callback.Code == null && (callback.Error == null || callback.State == null)) return;
                try { await api.OAuthCallbackAsync(server, started.SessionId, callback, profile); } catch (Exception) { }
            }, life.Token);
            if (!open(url)) return outcome = new Outcome.Failed("Couldn’t open the sign-in sheet. Try again.");
            outcome = await WaitAsync(server, profile, started.SessionId, ct);
            life.Cancel();
            try { await relayed; } catch (Exception) { }
            return outcome;
        }
        catch (Exception e)
        {
            return outcome = new Outcome.Failed(CapabilitiesWords.Detail(e));
        }
        finally
        {
            if (outcome is not Outcome.SignedIn && sessionId != null) await api.OAuthCancelAsync(server, sessionId, profile);
        }
    }

    private async Task<Outcome> WaitAsync(string server, string profile, string sessionId, CancellationToken ct)
    {
        var deadline = DateTimeOffset.UtcNow + Lifetime;
        var failures = 0;
        while (true)
        {
            if (ct.IsCancellationRequested) return new Outcome.Cancelled();
            if (DateTimeOffset.UtcNow >= deadline) return new Outcome.Failed("The sign-in took too long. Try again.");
            try
            {
                var poll = await api.OAuthPollAsync(server, sessionId, profile);
                failures = 0;
                if (poll.Status == "approved") return new Outcome.SignedIn(poll.Tools);
                if (poll.Status == "error")
                    return new Outcome.Failed(poll.ErrorMessage.Length == 0 ? "The sign-in didn’t finish. Try again." : McpEntryMask.Phone.Text(poll.ErrorMessage));
            }
            catch (Exception)
            {
                if (++failures >= 3) return new Outcome.Failed("Lost the gateway while signing in. Try again.");
            }
            try { await Task.Delay(PollEvery, ct); } catch (OperationCanceledException) { return new Outcome.Cancelled(); }
        }
    }
}
