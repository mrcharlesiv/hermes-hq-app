using Hermes.Core.Gateways;

namespace Hermes.Core.Offline;

/// What the offline screen says, by the connection's reason: never an address in a sentence and never a raw code
/// (HermesKit/Offline/OfflineCopy.swift, docs/spec/3x-offline.md §3.5, §3.6). Pure.
public static class OfflineCopy
{
    public sealed record Screen(string Title, string Recovery);
    /// The card under the words: the gateway as people name it over "host:port · account".
    public sealed record Card(string Name, string Detail);

    public const string TryAgain = "Try Again";
    public const string DifferentGateway = "Change Address or Sign In";
    public const string SignInAgain = "Sign In Again";
    public static string SwitchTo(string name) => $"Switch to {name}";
    public const string Cancel = "Cancel";
    public const string Connecting = "Connecting…";
    public const string RetryingSpoken = "Trying again automatically";
    public const string UnreadableDetail = "Your saved sign-in could not be read.";
    public const string SignInAgainTitle = "Sign In Again?";
    public static readonly string SignInAgainMessage =
        $"Hermes HQ couldn’t read your saved sign-in. Drafts on this {DeviceWord.Name} are kept aside and won’t move to the account you sign in with.";

    public const string KeychainUnreadable = "keychain-unreadable";
    public const string KeychainLocked = "keychain-locked";
    public const string KeychainUnavailable = "keychain-unavailable";
    public static readonly HashSet<string> KeychainReasons = [KeychainLocked, KeychainUnavailable, KeychainUnreadable];

    private static readonly Dictionary<string, Screen> ByReason = new()
    {
        ["network"] = new("You’re Offline",
            $"{DeviceWord.SubjectCap} isn’t connected to the internet. Hermes HQ reconnects as soon as it is."),
        ["tailscale-off"] = new("Turn On Tailscale",
            $"Turn on Tailscale to reach {HostWord.Phrase}. Hermes HQ reconnects as soon as it’s on."),
        ["timeout"] = new("Hermes Isn’t Answering",
            "The computer running Hermes may be asleep or on another network. Hermes HQ keeps trying."),
        ["tls"] = new("Can’t Verify Hermes",
            $"{DeviceWord.SubjectCap} doesn’t trust the HTTPS certificate of {HostWord.Phrase}. Hermes HQ keeps trying; if this continues, sign in with a trusted address."),
        ["gateway-outdated"] = new("Update Hermes",
            $"{HostWord.Sentence} has a version of Hermes that’s too old for Hermes HQ. Update Hermes there; Hermes HQ keeps trying."),
        ["rate-limited"] = new("Hermes Is Busy", "It is limiting sign-ins right now. Hermes HQ will try again shortly."),
        ["host-rejected"] = new("Hermes Isn’t Accepting This Address",
            "Hermes no longer accepts connections at the saved address. On the computer running Hermes, check HERMES_DASHBOARD_PUBLIC_URL in ~/.hermes/.env; Hermes HQ keeps trying."),
        ["not-hermes"] = new("Can’t Reach Hermes",
            $"The saved address answered, but not as Hermes. Hermes HQ keeps trying; check {HostWord.Phrase}, or sign in with its current address."),
        ["blocked"] = new("Something Is Blocking Hermes",
            $"The saved address answered, but something in front of Hermes turned {DeviceWord.Subject} away: a proxy, a firewall or the network you’re on. You’re still signed in, and Hermes HQ keeps trying."),
        [KeychainLocked] = new($"Unlock Your {DeviceWord.Name}",
            $"Your saved sign-in is protected until {DeviceWord.Subject} is unlocked. Hermes HQ reconnects as soon as it is."),
        [KeychainUnavailable] = new("Can’t Open Your Saved Sign-In",
            $"{DeviceWord.SubjectCap} couldn’t open it just now. Hermes HQ keeps trying. Your local drafts are being kept."),
        [KeychainUnreadable] = new("Can’t Read Your Saved Sign-In",
            $"Sign in again to continue. Drafts on this {DeviceWord.Name} are kept aside, not moved to the account you sign in with."),
    };

    public const string DefaultTitle = "Can’t Reach Hermes";
    public const string DefaultRecovery = "The computer running Hermes may be asleep or on another network. Hermes HQ keeps trying.";
    public static readonly string NoAddressRecovery =
        $"{DeviceWord.TapCap} Try Again to recover your saved connection before changing sign-in. Your local drafts are being kept.";
    public const string NousRecovery =
        "Your Nous agent may be stopped or still starting. If it’s stopped, start it on Nous Portal. Hermes HQ keeps trying.";
    public const string WaitingForNetwork = "Waiting for a connection…";

    /// Title and recovery for a reason; any reason without its own words gets the default pair.
    public static Screen ScreenFor(string? reason, bool hasAddress, bool nous = false)
    {
        if (nous && hasAddress && reason == "timeout") return new(ByReason["timeout"].Title, NousRecovery);
        if (reason != null && ByReason.TryGetValue(reason, out var known)) return known;
        return new(DefaultTitle, !hasAddress ? NoAddressRecovery : nous ? NousRecovery : DefaultRecovery);
    }

    /// A gateway Nous hosts (`<name>.agents.nousresearch.com`).
    public static bool NousHosted(Uri? url) =>
        url?.Host.ToLowerInvariant().EndsWith(".agents.nousresearch.com", StringComparison.Ordinal) == true;

    /// The card's name for a gateway with no name of its own: the computer, not "Your Gateway".
    public const string UnnamedCard = HostWord.Sentence;

    /// The card's two lines; null when it is hidden (no address and the store is the reason).
    public static Card? CardFor(string? reason, Uri? url, string? label, string? accountName)
    {
        if (url == null) return KeychainReasons.Contains(reason ?? "") ? null : new Card(UnnamedCard, UnreadableDetail);
        var given = label?.Trim() ?? "";
        var friendly = GatewayNaming.FriendlyName(url);
        var name = given.Length > 0 ? given : friendly == GatewayNaming.Unnamed ? UnnamedCard : friendly;
        var host = GatewayNaming.Host(url, port: true);
        if (host.Length == 0) host = Uri.UnescapeDataString(url.ToString());
        var detail = string.Join(" · ", new[] { host, accountName?.Trim() ?? "" }.Where(s => s.Length > 0));
        return new Card(name, detail);
    }

    public const int UnavailableReadsBeforeSignIn = 3;

    public static bool ShowsDifferentGateway(bool hasAddress) => hasAddress;

    public static bool ShowsSignInAgain(string? reason, int failedReads = 0) =>
        reason == KeychainUnreadable || (reason == KeychainUnavailable && failedReads >= UnavailableReadsBeforeSignIn);

    /// `Trying Again in N s`: a no-break space before `s`, N never below 1.
    public static string Countdown(TimeSpan left) => $"Trying Again in {Math.Max(1, (int)Math.Ceiling(left.TotalSeconds))} s";
}

/// The wait before each automatic retry while the app has never been connected: 3, 6, 12, 24, then 30 s for good
/// (HermesKit/Offline/RetryLadder.swift). RpcConnection's pre-ready back-off is this ladder.
public static class RetryLadder
{
    public static readonly double[] Steps = [3, 6, 12, 24, 30];
    public static readonly TimeSpan Ceiling = TimeSpan.FromSeconds(120);

    public static TimeSpan Wait(int attempt, TimeSpan? retryAfter = null)
    {
        var step = TimeSpan.FromSeconds(Steps[Math.Clamp(attempt, 0, Steps.Length - 1)]);
        if (retryAfter is not { } r || r <= TimeSpan.Zero) return step;
        return r > Ceiling ? Ceiling : r > step ? r : step;
    }

    public static TimeSpan Remaining(DateTimeOffset due, DateTimeOffset now) =>
        due > now ? due - now : TimeSpan.Zero;
}

/// The header's words for the gateway link (HermesKit/Offline/HeaderLink.swift): "Reconnecting…", then "Offline" once
/// it has been reconnecting 120 s; "Signed Out" once the gateway ended the session.
public static class HeaderLink
{
    public static readonly TimeSpan OfflineAfter = TimeSpan.FromSeconds(120);
    public const string Reconnecting = "Reconnecting…";
    public const string Offline = "Offline";
    public const string SignedOut = "Signed Out";

    /// `everOpen`: the connection has been open before (a first connection says nothing). `reconnectingFor`: how long
    /// this outage has lasted.
    public static string? Words(Rpc.ConnectionState state, bool everOpen, TimeSpan? reconnectingFor) => state switch
    {
        Rpc.ConnectionState.SignedOut => SignedOut,
        Rpc.ConnectionState.Offline or Rpc.ConnectionState.Connecting when everOpen =>
            (reconnectingFor ?? TimeSpan.Zero) >= OfflineAfter ? Offline : Reconnecting,
        Rpc.ConnectionState.Offline => Offline,
        _ => null,
    };
}

/// The reconnect notice's sentence (HermesKit/Offline/ReconnectBanner.swift `ReconnectNotice`).
public static class ReconnectNotice
{
    public const string NetworkDown = "Network unavailable. Check your network or VPN connection.";
    public static readonly string ReconnectingText = $"Reconnecting to {HostWord.Phrase}…";
    /// A socket that drops and comes straight back raises no notice.
    public static readonly TimeSpan Hold = TimeSpan.FromSeconds(4);

    /// `failed`: a reconnect attempt has failed in this outage (so its cause can be named). `offline`: the header reads
    /// "Offline".
    public static string Text(bool networkDown, string? reason = null, bool failed = true, bool offline = false)
    {
        if (networkDown) return NetworkDown;
        if (offline) return $"{OfflineCause(reason, failed)} Hermes HQ keeps trying.";
        if (!failed) return ReconnectingText;
        return reason switch
        {
            "tailscale-off" => $"Turn on Tailscale to reach {HostWord.Phrase}. Reconnecting…",
            "timeout" => $"{HostWord.Sentence} is slow to answer — still trying…",
            "rate-limited" => $"{HostWord.Sentence} is busy — still trying…",
            null or "" or "unreachable" => $"Can’t reach {HostWord.Phrase}. Check your network or VPN connection. Reconnecting…",
            _ => $"Can’t connect to {HostWord.Phrase} right now. Reconnecting…",
        };
    }

    private static string OfflineCause(string? reason, bool failed)
    {
        if (!failed) return $"{HostWord.Sentence} is out of reach.";
        return reason switch
        {
            "tailscale-off" => $"Turn on Tailscale to reach {HostWord.Phrase}.",
            "timeout" => $"{HostWord.Sentence} is slow to answer.",
            "rate-limited" => $"{HostWord.Sentence} is busy.",
            null or "" or "unreachable" => $"Can’t reach {HostWord.Phrase}. Check your network or VPN connection.",
            _ => $"Can’t connect to {HostWord.Phrase} right now.",
        };
    }
}

/// Which unexpected errors stop startup, and their words (HermesKit/Offline/StartupProblems.swift).
public static class StartupProblems
{
    public static readonly string CouldNotStart = $"Hermes HQ couldn’t start. {DeviceWord.TapCap} Try Again.";
    public static readonly string Storage =
        $"Hermes HQ couldn’t switch this {DeviceWord.Name}’s saved app data to this account. Your drafts are kept. "
        + $"If {DeviceWord.Name} storage is almost full, free up some space, then try again.";
}
