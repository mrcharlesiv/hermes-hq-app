using System.Text.RegularExpressions;
using Hermes.Core.Gateways;
using Hermes.Core.Net;

namespace Hermes.Core.Onboarding;

/// Which ways in the form shows (HermesKit/Net/SignInFlows.swift `SignInWays`).
public enum SignInWays { Both, Nous, Password }

public static class SignInWaysExtensions
{
    public static bool ShowsNous(this SignInWays w) => w != SignInWays.Password;
    public static bool ShowsPassword(this SignInWays w) => w != SignInWays.Nous;

    /// unknown → both; Nous only → nous; password only → password; both or neither → both.
    public static SignInWays From(Auth.SignIn.Probe? probe)
    {
        if (probe is not { Known: true } p) return SignInWays.Both;
        if (p.Nous && !p.Password) return SignInWays.Nous;
        if (p.Password && !p.Nous) return SignInWays.Password;
        return SignInWays.Both;
    }
}

/// The form's words (App/SignIn/SignInDriving.swift `SignInCopy`).
public static class SignInCopy
{
    public static readonly Dictionary<string, string> Messages = new()
    {
        ["auth-rejected"] = "Hermes didn’t accept that username or password.",
        ["no-password"] = "No password sign-in here: try Sign in with Nous, or add HERMES_DASHBOARD_BASIC_AUTH_USERNAME and HERMES_DASHBOARD_BASIC_AUTH_PASSWORD to ~/.hermes/.env on the computer running Hermes and restart the Hermes dashboard.",
        ["signed-out"] = "Sign in to Hermes to continue.",
        ["session-ended"] = "Your session on this Hermes ended. Enter your password to sign in again.",
        ["insecure-url"] = "Use an https:// address. Plain http:// works only for private addresses: your local network, a VPN such as Tailscale or WireGuard, and names ending in .local, .lan, .internal or .home.arpa.",
        ["invalid-url"] = "Enter the full address, like https://my-mac.tail1234.ts.net.",
        ["missing-fields"] = "Enter the address, username and password.",
        ["unreachable"] = "Can’t reach that address. Check that it’s typed right and that the computer running Hermes is on. If you use Tailscale, check that it’s on here too.",
        ["timeout"] = "Hermes didn’t answer in time. Check that the computer running it is on and awake, and that Tailscale is on if you use it.",
        ["tls"] = $"{DeviceWord.Name} doesn’t trust the HTTPS certificate at this address. Use a certificate from a public authority, such as Tailscale HTTPS.",
        ["not-hermes"] = "That address answered, but it isn’t Hermes. Check the address, including any :port at the end.",
        ["rate-limited"] = "Hermes is limiting sign-in attempts. Wait a minute, then try again.",
        ["keychain-locked"] = $"Unlock your {DeviceWord.Name}, then try again.",
        ["keychain-unreadable"] = "Your saved sign-in couldn’t be read. Sign in again.",
        ["keychain-unavailable"] = $"{DeviceWord.Name} couldn’t open your saved sign-in. Try again.",
        ["gateway-error"] = "Couldn’t sign in. Check the Hermes address and try again.",
        ["tailscale-off"] = "Turn on Tailscale to reach your Hermes, then try again.",
        ["gateway-outdated"] = $"{HostWord.Sentence} runs a version of Hermes that’s too old for Hermes HQ. Update Hermes on it, then try again.",
        ["host-rejected"] = "Hermes doesn’t accept connections at this address yet. On the computer running Hermes, set HERMES_DASHBOARD_PUBLIC_URL in ~/.hermes/.env to this exact address, restart the Hermes dashboard, then try again.",
        ["nous-unavailable"] = $"This Hermes doesn’t offer Sign in with Nous yet. Sign in with its username and password, or finish the Mac setup: {DeviceWord.Tap} Need help connecting? below.",
        ["nous-cancelled"] = "",
        ["nous-failed"] = "Nous sign-in didn’t finish. Try again.",
        // The Mac's "Use Another Nous Account" opens a private sheet; a PC signs in through the web browser, whose own
        // Nous sign-in is what has to change.
        ["not-owner"] = "This Nous account isn’t allowed in. Sign out of Nous in your web browser, then sign in with the one this Hermes was set up with.",
    };

    public const string UnreachableNote = "Can’t reach this address right now. Check that it’s typed right, or sign in anyway.";
    public const string UnansweredWaysNote = "This address answered, but didn’t say how to sign in. Check the address, including any :port at the end, or sign in anyway.";

    /// The calm note under the address once the probe settled (null: none).
    public static string? ProbeNote(Auth.SignIn.Probe p) => p.Known ? null : p.Answered ? UnansweredWaysNote : UnreachableNote;

    /// The stable code (spec 01 §18) for anything the core's sign-in throws.
    public static string Code(Exception error)
    {
        switch (error)
        {
            case OperationCanceledException: return "nous-cancelled";
            case GatewayException g:
                switch (g.Code)
                {
                    case "bad-password": return "auth-rejected";
                    case "offline":
                        return g.Message.Contains("SSL", StringComparison.OrdinalIgnoreCase)
                            || g.Message.Contains("certificate", StringComparison.OrdinalIgnoreCase) ? "tls" : "unreachable";
                    case "http":
                        return g.Status switch { 401 or 403 => "auth-rejected", 429 => "rate-limited", _ => "gateway-error" };
                    default:
                        return Messages.ContainsKey(g.Code) ? g.Code : "gateway-error";
                }
            default: return "gateway-error";
        }
    }

    /// What the form says for a failure ("" for a cancelled Nous sign-in).
    public static string Message(Exception error) => Messages[Code(error)];

    /// Failures that mark the address field.
    public static bool MarksAddress(string code) =>
        code is "insecure-url" or "tailscale-ip" or "invalid-url" or "unreachable" or "timeout" or "tls" or "not-hermes";

    /// Failures that mark the password field: the gateway turned the password down.
    public static bool MarksPassword(string code) => code is "auth-rejected" or "session-ended";

    public static string Subtitle(SignInWays? ways) => ways switch
    {
        SignInWays.Password => $"This Hermes uses a username and password. To sign in with your Nous account instead, it needs a one-time setup on its computer: {DeviceWord.Tap} Need help connecting? below.",
        SignInWays.Nous => "This Hermes uses Nous sign-in. Use the Nous account it was set up with.",
        _ => "Paste or type the address of your Hermes, then sign in.",
    };

    public static string Footnote(SignInWays? ways) => ways == SignInWays.Nous
        ? $"Nous handles the sign-in in your web browser; Hermes HQ never sees your Nous password. Your session stays in {DeviceWord.Keychain} to reconnect."
        : $"Hermes HQ keeps your session in {DeviceWord.Keychain} to reconnect. Your password is never stored.";

    public const string SignInWithNous = "Sign in with Nous";
    public const string SigningIn = "Signing In…";
    public const string SignInButton = "Sign In";
    public const string Continue = "Continue";
    public const string Checking = "Checking…";
    public const string OrWithPassword = "or with a password";
    public const string AddressLabel = "Hermes address";
    public const string AddressPlaceholder = "my-mac.tail1234.ts.net";
    public const string Username = "Username";
    public const string Password = "Password";
    public const string Paste = "Paste";
    public const string OtherNousAccount = "Use Another Nous Account";
    public static string EnterAddressThen(string button) => $"Enter the address, then {DeviceWord.Tap} {button}.";
    /// The notice when a saved gateway must sign in again before the app switches to it.
    public const string SignInToSwitch = "Sign in again to switch to this gateway.";
}

/// The address as typed → what is probed and signed in to (App/SignIn/SignInDriving.swift `SignInAddress`).
public static partial class SignInAddress
{
    [GeneratedRegex(@"[A-Za-z][A-Za-z0-9+.-]*://[^\s<>""“”]+")] private static partial Regex Link();
    [GeneratedRegex(@"[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.ts\.net(:[0-9]+)?")] private static partial Regex TsNet();
    [GeneratedRegex(@"^(https?://)?[^\s/]+\.[^\s/]+", RegexOptions.IgnoreCase)] private static partial Regex LooksLike();

    /// The address in pasted text: the first link in it (people copy Hermes's whole reply); a line with no link is
    /// taken as typed.
    public static string Pasted(string raw)
    {
        var text = raw.Trim();
        if (!text.Any(char.IsWhiteSpace)) return text;
        foreach (var pattern in new[] { Link(), TsNet() })
        {
            var m = pattern.Match(text);
            if (!m.Success) continue;
            var found = m.Value.TrimEnd('.', ',', ';', ':', '!', '?', ')', ']', '}', '\'', '’', '*', '_', '`');
            if (found.Length > 0) return found;
        }
        return text;
    }

    /// Whether the probe should be asked at all: text that looks like `host.tld`.
    public static bool LooksLikeAddress(string raw) => LooksLike().IsMatch(raw.Trim());

    /// A pasted setup link (hermes://connect?url=…, what the setup's QR code holds) → the address in it.
    public static string? FromConnectLink(string text)
    {
        if (!Uri.TryCreate(text.Trim(), UriKind.Absolute, out var u) || u.Scheme is not ("hermes" or "hermeshq")) return null;
        if (u.Host != "connect") return null;
        foreach (var part in u.Query.TrimStart('?').Split('&'))
        {
            var kv = part.Split('=', 2);
            if (kv.Length == 2 && kv[0] == "url" && Uri.UnescapeDataString(kv[1]) is { Length: > 0 } v) return v;
        }
        return null;
    }
}

/// Spans of the guide's small markup: `**bold**`, `[[key cap]]`, `` `code` `` and `<<link text|address>>`
/// (App/Onboarding/OnboardingKit.swift `GuideText`).
public static partial class GuideText
{
    public enum Kind { Plain, Bold, Key, Code, Link }
    public sealed record Span(Kind Kind, string Text, string? Address = null);

    [GeneratedRegex(@"\*\*(.+?)\*\*|\[\[(.+?)\]\]|`(.+?)`|<<(.+?)\|(.+?)>>")] private static partial Regex Markup();

    public static IReadOnlyList<Span> Parse(string text)
    {
        var spans = new List<Span>();
        var at = 0;
        foreach (Match m in Markup().Matches(text))
        {
            if (m.Index > at) spans.Add(new Span(Kind.Plain, text[at..m.Index]));
            if (m.Groups[1].Success) spans.Add(new Span(Kind.Bold, m.Groups[1].Value));
            else if (m.Groups[2].Success) spans.Add(new Span(Kind.Key, m.Groups[2].Value));
            else if (m.Groups[3].Success) spans.Add(new Span(Kind.Code, m.Groups[3].Value));
            else spans.Add(new Span(Kind.Link, m.Groups[4].Value, m.Groups[5].Value));
            at = m.Index + m.Length;
        }
        if (at < text.Length) spans.Add(new Span(Kind.Plain, text[at..]));
        return spans;
    }

    /// The words alone (what the web shows and what Narrator reads).
    public static string Plain(string text) => string.Concat(Parse(text).Select(s => s.Text));
}
