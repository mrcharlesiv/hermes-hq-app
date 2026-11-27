using System.Text.RegularExpressions;

namespace Hermes.Core.Gateways;

/// How a saved gateway is named on this PC (HermesKit/Model/GatewayNaming.swift, spec 1x-settings §4.2): a name given
/// here wins, else its computer's name when the address has one ("alexs-Mac-Studio.local" reads "Alex’s Mac
/// Studio"), else the address. Pure.
public static partial class GatewayNaming
{
    public const string Unnamed = "Your Gateway";
    public const string NousAccountName = "Nous account";

    [GeneratedRegex(@"\.(?:local|lan|home|localdomain)$", RegexOptions.IgnoreCase)] private static partial Regex LocalSuffix();
    [GeneratedRegex(@"^\d{1,3}(?:\.\d{1,3}){3}$")] private static partial Regex Ipv4();
    [GeneratedRegex(@"^(.+?)s-(Mac|MacBook|iMac|Mac-mini|Mac-Studio|Mac-Pro)\b", RegexOptions.IgnoreCase)] private static partial Regex OwnerMac();
    [GeneratedRegex(@"-+")] private static partial Regex Dashes();
    [GeneratedRegex(@"^localhost$", RegexOptions.IgnoreCase)] private static partial Regex Localhost();

    private static readonly Dictionary<string, string> MacWords = new(StringComparer.Ordinal)
    {
        ["mac"] = "Mac", ["macbook"] = "MacBook", ["imac"] = "iMac", ["studio"] = "Studio", ["pro"] = "Pro",
        ["air"] = "Air", ["mini"] = "mini",
    };

    /// This computer's own name (set once at launch): a gateway at a loopback address runs here, so that is its name.
    public static string? ThisComputer { get; set; }

    /// `friendlyHostName`: no local suffix, the first label of a dotted name, "<owner>s-Mac…" → "<owner>’s-Mac…", dashes
    /// as spaces.
    public static string FriendlyHostName(string host)
    {
        var name = LocalSuffix().Replace(host.Trim(), "", 1);
        if (name.Length == 0 || Ipv4().IsMatch(name)) return name;
        var shortName = name.Contains('.') && !name.Any(char.IsWhiteSpace) ? name.Split('.')[0] : name;
        return Dashes().Replace(OwnerMac().Replace(shortName, "$1’s-$2", 1), " ").Trim();
    }

    /// The host without port (brackets stripped), or with a non-default port ("host:port").
    public static string Host(Uri? url, bool port)
    {
        if (url == null) return "";
        var host = url.Host.ToLowerInvariant();
        if (host.Length == 0) return "";
        var bare = host.StartsWith('[') && host.EndsWith(']') ? host[1..^1] : host;
        if (!port) return bare;
        var shown = bare.Contains(':') ? $"[{bare}]" : bare;
        return url.IsDefaultPort ? shown : $"{shown}:{url.Port}";
    }

    public static bool IsLoopback(string host) =>
        Localhost().IsMatch(host) || host == "::1" || (Ipv4().IsMatch(host) && host.StartsWith("127."));

    /// The gateway as people name it (without a label): its computer's name, else "Your Gateway". Never an address.
    public static string FriendlyName(Uri? url)
    {
        var host = Host(url, port: false);
        if (ThisComputer?.Trim() is { Length: > 0 } mine && IsLoopback(host)) return mine;
        if (host.Length == 0 || Ipv4().IsMatch(host) || host.Contains(':') || Localhost().IsMatch(host)) return Unnamed;
        var name = string.Join(" ", FriendlyHostName(host).Split(' ')
            .Select(w => MacWords.TryGetValue(w.ToLowerInvariant(), out var m) ? m : w));
        if (name.Length == 0) return Unnamed;
        return char.ToUpperInvariant(name[0]) + name[1..];
    }

    /// "Nous account" for Sign in with Nous, else the username.
    public static string AccountName(string username) =>
        username.StartsWith("nous:", StringComparison.Ordinal) ? NousAccountName : username;

    /// `gatewayRows`: the row's title and subtitle. `label` is the name given on this PC (null when none).
    public static (string Title, string Subtitle) Row(Uri url, string? label, string accountName, bool hasSession)
    {
        var given = label?.Trim() ?? "";
        var friendly = given.Length == 0 ? FriendlyName(url) : given;
        var address = Host(url, port: true);
        if (address.Length == 0) address = url.ToString();
        var named = friendly != Unnamed;
        var subtitle = string.Join(" · ", new[] { named ? address : "", accountName, hasSession ? "" : "Signed Out" }
            .Where(s => s.Length > 0));
        return (named ? friendly : address, subtitle);
    }

    /// The title alone (menus, the sidebar's foot).
    public static string Title(Uri url, string? label) => Row(url, label, "", true).Title;

    /// The Update screen's card: the Name given on this PC, else its computer's name, else "Your Gateway".
    public static string UpdateName(Uri url, string? label) =>
        label?.Trim() is { Length: > 0 } given ? given : FriendlyName(url);
}
