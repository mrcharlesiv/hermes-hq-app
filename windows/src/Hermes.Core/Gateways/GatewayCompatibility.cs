using System.Text.Json.Nodes;

namespace Hermes.Core.Gateways;

/// An older Hermes than this app needs, as the gateway reports itself (HermesKit/Net/GatewayCompatibility.swift).
/// `Version` is never compared: only the release date is.
public sealed record OutdatedGateway(string Version, string ReleaseDate, bool CanUpdate = true);

public enum CompatibilityKind { Compatible, Outdated, Unknown }

/// What `/api/status` says about this gateway's age (spec 01 §4.3, docs/spec/3x-onboarding.md §5.14): read after a
/// typed sign-in and on each Check Again. Anything that can't be read as an older release is not outdated: a gateway is
/// never turned away on a guess.
public sealed record GatewayCompatibility(CompatibilityKind Kind, OutdatedGateway? Outdated = null)
{
    public static readonly GatewayCompatibility Compatible = new(CompatibilityKind.Compatible);
    public static readonly GatewayCompatibility Unknown = new(CompatibilityKind.Unknown);

    /// `CONTRACT_RELEASES[8]`: the oldest Hermes release this client supports.
    public static readonly (int Y, int M, int D) MinimumRelease = (2026, 9, 21);

    /// How long one read of the status may take (`STATUS_CHECK_MS`).
    public static readonly TimeSpan CheckTime = TimeSpan.FromSeconds(4);

    public static GatewayCompatibility From(JsonNode? status)
    {
        if (status.Get("release_date") is not JsonValue rv || !rv.TryGetValue(out string? text)
            || Parse(text) is not { } date) return Unknown;
        if (date.CompareTo(MinimumRelease) >= 0) return Compatible;
        // Text only, trimmed, its first 24 characters; "" when absent or not text.
        var version = status.Get("version") is JsonValue v && v.TryGetValue(out string? s) ? s.Trim() : "";
        if (version.Length > 24) version = version[..24];
        var canUpdate = !(status.Get("can_update_hermes") is JsonValue c && c.TryGetValue(out bool b) && !b);
        return new GatewayCompatibility(CompatibilityKind.Outdated, new OutdatedGateway(version, text.Trim(), canUpdate));
    }

    /// `YYYY.M.D` (trimmed; ASCII digits; four, then one or two, then one or two) → a comparable triple, null when it
    /// isn't one: month 1…12 and day 1…31.
    public static (int, int, int)? Parse(string raw)
    {
        var parts = raw.Trim().Split('.');
        if (parts.Length != 3 || parts[0].Length != 4 || parts[1].Length is < 1 or > 2 || parts[2].Length is < 1 or > 2)
            return null;
        if (!parts.All(p => p.All(c => c is >= '0' and <= '9'))) return null;
        int y = int.Parse(parts[0]), m = int.Parse(parts[1]), d = int.Parse(parts[2]);
        if (m is < 1 or > 12 || d is < 1 or > 31) return null;
        return (y, m, d);
    }

    /// The hard cap on one read (App/SignIn/CompatibilityCap.swift): whatever the transport does, the answer is Unknown
    /// once the cap passes, and Unknown never blocks. A late answer is dropped and the read behind it cancelled.
    public static async Task<GatewayCompatibility> CappedAsync(Func<CancellationToken, Task<GatewayCompatibility>> read,
        TimeSpan? cap = null, CancellationToken stop = default)
    {
        if (stop.IsCancellationRequested) return Unknown;
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(stop);
        var token = cts.Token;
        var reading = Task.Run(async () =>
        {
            try { stop.ThrowIfCancellationRequested(); return await read(token); }
            catch (Exception) { return Unknown; }
        });
        var timer = Task.Delay(cap ?? CheckTime, stop);
        var first = await Task.WhenAny(reading, timer);
        if (first == reading) return stop.IsCancellationRequested ? Unknown : await reading;
        await cts.CancelAsync();
        return Unknown;
    }
}

/// How a successful sign-in goes on: into the app, or to "Update Hermes" first (App/SignIn/CompatibilityCap.swift).
public sealed record SignInOutcome(OutdatedGateway? Update)
{
    public static readonly SignInOutcome Enter = new((OutdatedGateway?)null);
}

/// What the update screen says (`OutdatedCopy`).
public static class OutdatedCopy
{
    public const string Title = "Update Hermes";
    public const string CheckAgain = "Check Again";
    public const string ContinueAnyway = "Continue Anyway";
    public const string Checking = "Checking…";
    public const string StillOlder = "Still the older version. An update can take a few minutes.";

    public static string Recovery(bool canUpdate) =>
        $"Hermes HQ needs a newer version of Hermes than {HostWord.Phrase} has, and parts of the app won’t work until it’s updated. "
        + (canUpdate ? $"On {HostWord.Phrase}, run “hermes update”, then check again."
                     : $"Update Hermes on {HostWord.UpdateTarget} the way it was installed, then check again.");

    public static string Release(OutdatedGateway info) =>
        (info.Version.Length == 0 ? "Hermes" : $"Hermes {info.Version}") + $" · released {info.ReleaseDate}";
}

/// The Update Hermes screen's model (App/Onboarding/UpdateHermesView.swift `UpdateHermesModel`): Check Again enters
/// once the gateway is new enough (or the answer is slow or unreadable: DECISION D11); Continue Anyway is the person's
/// call. One check at a time; nothing more once it has left.
public sealed class UpdateHermesModel(string name, OutdatedGateway info,
    Func<CancellationToken, Task<GatewayCompatibility>> check, Action onEnter)
{
    public enum Phase { Idle, Checking, StillOutdated }

    private bool _left;

    public string Name { get; } = name;
    public OutdatedGateway Info { get; private set; } = info;
    public Phase State { get; private set; } = Phase.Idle;
    public TimeSpan Cap { get; set; } = GatewayCompatibility.CheckTime;
    /// Raised after every change of phase or info.
    public event Action? Changed;

    public string Recovery => OutdatedCopy.Recovery(Info.CanUpdate);
    public string Release => OutdatedCopy.Release(Info);
    public string Status => State switch
    {
        Phase.Checking => OutdatedCopy.Checking,
        Phase.StillOutdated => OutdatedCopy.StillOlder,
        _ => "",
    };
    public bool Busy => State == Phase.Checking;

    public async Task CheckAgainAsync()
    {
        if (Busy || _left) return;
        State = Phase.Checking;
        Changed?.Invoke();
        var answer = await GatewayCompatibility.CappedAsync(check, Cap);
        if (_left) return;
        if (answer.Outdated is { } newer)
        {
            Info = newer;
            State = Phase.StillOutdated;
            Changed?.Invoke();
        }
        else
        {
            _left = true;
            onEnter();
        }
    }

    public void ContinueAnyway()
    {
        if (Busy || _left) return;
        _left = true;
        onEnter();
    }
}

/// Hermes Cloud `/api/status` webapp readiness (Hermes 0.23.5+: `webapp_state`, `webapp_url`).
public enum CloudWebappState { Ready, Starting, Down, NotAvailable }

public sealed record CloudWebappStatus(CloudWebappState State, Uri? WebappUrl)
{
    public static CloudWebappStatus? From(JsonNode? status, Uri? gatewayUrl = null)
    {
        var rawState = status.Str("webapp_state")?.Trim().ToLowerInvariant();
        CloudWebappState? state = rawState switch
        {
            "ready" => CloudWebappState.Ready,
            "starting" => CloudWebappState.Starting,
            "down" => CloudWebappState.Down,
            "not_available" => CloudWebappState.NotAvailable,
            _ => null,
        };
        if (state is null) return null;
        var validUrl = ValidateUrl(status.Str("webapp_url")?.Trim(), gatewayUrl);
        return new CloudWebappStatus(state.Value, validUrl);
    }

    /// Accepts only HTTPS URLs matching the agent's host or a `.nousresearch.com` subdomain.
    public static Uri? ValidateUrl(string? raw, Uri? gatewayUrl)
    {
        if (string.IsNullOrWhiteSpace(raw) || !Uri.TryCreate(raw.Trim(), UriKind.Absolute, out var uri)) return null;
        if (!string.Equals(uri.Scheme, "https", StringComparison.OrdinalIgnoreCase)) return null;
        var host = uri.Host.ToLowerInvariant();
        if (string.IsNullOrEmpty(host)) return null;
        if (gatewayUrl is not null && string.Equals(host, gatewayUrl.Host, StringComparison.OrdinalIgnoreCase)) return uri;
        if (host == "nousresearch.com" || host.EndsWith(".nousresearch.com", StringComparison.Ordinal)) return uri;
        return null;
    }
}
