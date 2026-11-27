using System.Text.Json.Nodes;
using Hermes.Core.Gateways;
using Hermes.Core.Net;

namespace Hermes.Core.Capabilities;

/// Signing Hermes on the computer in to Nous for managed apps (App/Capabilities/Managed/NousAccountSignIn.swift): the
/// same device-code sign-in the desktop starts (`/api/providers/oauth/nous/start`, then its poll), the Nous page in
/// the system browser. Raises `Changed` on the caller's thread of whichever step moved it.
public sealed class NousAccount(GatewaySession session)
{
    public abstract record States
    {
        public sealed record Unknown : States;
        public sealed record SignedOut : States;
        public sealed record Starting : States;
        public sealed record Waiting(string Code) : States;
        public sealed record SignedIn : States;
        public sealed record Failed(string Reason) : States;
    }

    public States State { get; private set; } = new States.Unknown();
    public bool DidRead { get; private set; }
    public event Action? Changed;
    /// The sign-in finished: the managed apps read again.
    public event Action? SignedIn;
    /// Opens the Nous page (the app's system browser; tests fetch it).
    public Func<Uri, bool>? Open { get; set; }
    /// Accepts the Nous page's address (https; loopback http only for the stand-in).
    public Func<string, Uri?> Accepts { get; set; } = link => Uri.TryCreate(link, UriKind.Absolute, out var u) && u.Scheme == "https" ? u : null;
    public TimeSpan MinimumPoll { get; set; } = TimeSpan.FromSeconds(2);

    private CancellationTokenSource? _polling;
    private string? _session;
    private string _profile = "default";

    private static KeyValuePair<string, string>[] Q(string profile) => [KeyValuePair.Create("profile", profile)];

    private void Set(States s) { State = s; Changed?.Invoke(); }

    /// Reads whether Hermes on the computer is signed in to Nous (for this bot's profile).
    public async Task RefreshAsync(string profile)
    {
        _profile = profile;
        if (State is States.Waiting or States.Starting) return;
        try
        {
            var a = await session.SendAsync(HttpMethod.Get, "/api/providers/oauth", Q(profile));
            var row = a.Ok ? (a.Json.Arr("providers") ?? []).FirstOrDefault(p => (p.Text("id") ?? p.Text("provider")) == "nous") : null;
            if (row == null) { DidRead = true; if (State is not States.SignedIn) Set(new States.Unknown()); return; }
            var connected = row.Bool("logged_in") ?? row.Bool("connected") ?? row.Obj("status").Bool("logged_in") ?? false;
            DidRead = true;
            Set(connected ? new States.SignedIn() : new States.SignedOut());
        }
        catch (Exception)
        {
            DidRead = true;
            if (State is not States.SignedIn) Set(new States.Unknown());
        }
    }

    public void Start()
    {
        if (_polling != null) return;
        Set(new States.Starting());
        var cts = new CancellationTokenSource();
        _polling = cts;
        var profile = _profile;
        _ = Task.Run(async () =>
        {
            try
            {
                var a = await session.SendAsync(HttpMethod.Post, "/api/providers/oauth/nous/start", Q(profile), new JsonObject(), ct: cts.Token);
                if (!a.Ok) throw GatewaySession.HttpError(a);
                var started = a.Json;
                if (started.Text("session_id") is not { } id || started.Text("verification_url") is not { } link || Accepts(link) is not { } url)
                    throw new CapabilityException("", "Hermes didn’t send a sign-in page.");
                _session = id;
                Set(new States.Waiting(started.Str("user_code") ?? ""));
                Open?.Invoke(url);
                var interval = TimeSpan.FromSeconds(Math.Max(MinimumPoll.TotalSeconds, started.Int("poll_interval") ?? 5));
                var deadline = DateTimeOffset.UtcNow.AddSeconds(started.Int("expires_in") ?? 900);
                while (!cts.IsCancellationRequested && DateTimeOffset.UtcNow < deadline)
                {
                    await Task.Delay(interval, cts.Token);
                    var p = await session.SendAsync(HttpMethod.Get, $"/api/providers/oauth/nous/poll/{Uri.EscapeDataString(id)}", Q(profile), ct: cts.Token);
                    if (!p.Ok) throw GatewaySession.HttpError(p);
                    switch (p.Json.Text("status") ?? "pending")
                    {
                        case "pending": continue;
                        case "approved":
                            _session = null;
                            Set(new States.SignedIn());
                            SignedIn?.Invoke();
                            return;
                        case "denied": throw new CapabilityException("", "The sign-in was turned down on the Nous page.");
                        case "expired": throw new CapabilityException("", "The sign-in timed out. Try again.");
                        default: throw new CapabilityException("", p.Json.Text("error_message") ?? "Nous didn’t finish the sign-in. Try again.");
                    }
                }
                if (!cts.IsCancellationRequested) throw new CapabilityException("", "The sign-in timed out. Try again.");
            }
            catch (OperationCanceledException) when (cts.IsCancellationRequested) { }
            catch (Exception e)
            {
                _session = null;
                Set(new States.Failed(CapabilitiesWords.Detail(e)));
            }
            finally { if (_polling == cts) _polling = null; }
        });
    }

    public void Cancel()
    {
        _polling?.Cancel(); _polling = null;
        if (_session is { } id)
        {
            var profile = _profile;
            _ = session.SendAsync(HttpMethod.Delete, $"/api/providers/oauth/sessions/{Uri.EscapeDataString(id)}", Q(profile));
        }
        _session = null;
        Set(new States.SignedOut());
    }

    /// The states where the box is only a quiet line, with nothing to click.
    public static bool IsQuiet(States state, bool unavailable, bool read) =>
        unavailable && (state is States.SignedIn || (state is States.Unknown && read));

    public static class Words
    {
        public const string NotTurnedOn = "Nous hasn’t turned on managed apps for your account yet. They appear here once it does.";
        public const string Approve = "Approve the sign-in on the Nous page.";
        public static string ApproveDetail(string code) => code.Length == 0
            ? "This updates by itself once you’ve approved."
            : $"Check the page shows the code {code}. This updates by itself once you’ve approved.";
        public const string NotAvailable = "Managed apps aren’t available for this account yet. Your other connectors are unaffected.";
        public const string Opening = "Opening Nous…";
        public const string SignInTitle = "Sign in to Nous to use managed apps.";
        public static string SignInDetail(string bot) =>
            $"Gmail, Google Calendar, Slack and more connect through a Nous account. This signs {HostWord.Phrase} in to Nous, for {bot} and your other bots.";
        public static string ReadOnly => $"This gateway is read-only. Sign in on {HostWord.Phrase}.";
        public const string Button = "Sign In to Nous";
    }
}
