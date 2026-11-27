using System.Net;
using System.Net.Sockets;
using System.Text;

namespace Hermes.Core.Net;

/// A validated gateway base URL, the twin of HermesKit's GatewayAddress (HermesKit/Net/GatewayAddress.swift):
/// lowercase scheme and host, an optional reverse-proxy base path, no trailing slash, no userinfo/query/fragment,
/// and clear-text http only for private, Tailscale or .local hosts.
public sealed class GatewayAddress : IEquatable<GatewayAddress>
{
    public Uri Base { get; }
    public string BasePath { get; }

    private GatewayAddress(Uri b, string basePath) { Base = b; BasePath = basePath; }

    public override string ToString() => Base.GetLeftPart(UriPartial.Authority) + BasePath;

    /// Typed text → address. With no scheme, local/Tailscale hosts get http://, everything else https://.
    public static GatewayAddress FromTyped(string typed)
    {
        var text = typed.Trim();
        if (text.Length == 0) throw new GatewayException("invalid-url", "Enter your gateway's address.");
        if (!text.Contains("://"))
        {
            var host = text.Split('/', 2)[0];
            if (host.StartsWith('[') && host.Contains(']')) host = host[1..host.IndexOf(']')];
            else if (host.Count(c => c == ':') == 1) host = host.Split(':')[0];
            text = (IsLocalHost(host) ? "http://" : "https://") + text;
        }
        return Validated(text);
    }

    public static GatewayAddress Validated(string text)
    {
        if (!Uri.TryCreate(text, UriKind.Absolute, out var uri)
            || uri.Scheme is not ("http" or "https")
            || uri.Host.Length == 0
            || uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0)
            throw new GatewayException("invalid-url", "That doesn't look like a gateway address.");
        if (uri.Scheme == "http" && !IsLocalHost(uri.IdnHost))
            throw new GatewayException("insecure-url",
                "Use https:// for this address. Plain http:// only works on your own network or Tailscale.");
        var path = uri.AbsolutePath.TrimEnd('/');
        var origin = $"{uri.Scheme}://{HostForUri(uri)}{(uri.IsDefaultPort ? "" : ":" + uri.Port)}";
        return new GatewayAddress(new Uri(origin + path + "/"), path);
    }

    private static string HostForUri(Uri uri) =>
        uri.HostNameType == UriHostNameType.IPv6 ? "[" + uri.IdnHost.Trim('[', ']').ToLowerInvariant() + "]"
            : uri.IdnHost.ToLowerInvariant();

    /// base + path (+ query). The path must start with a single "/" and stay under the base path; a literal "+" in the
    /// query is sent as %2B because the gateway form-decodes "+" as a space.
    public Uri Endpoint(string path, IEnumerable<KeyValuePair<string, string>>? query = null)
    {
        if (!path.StartsWith('/') || path.StartsWith("//") || path.Any(c => c == '\\' || char.IsControl(c)))
            throw new ArgumentException($"Bad gateway path {path}", nameof(path));
        var sb = new StringBuilder(Base.GetLeftPart(UriPartial.Authority)).Append(BasePath).Append(path);
        if (query != null)
        {
            var first = true;
            foreach (var (k, v) in query)
            {
                sb.Append(first ? '?' : '&').Append(Uri.EscapeDataString(k)).Append('=').Append(Uri.EscapeDataString(v));
                first = false;
            }
        }
        var url = new Uri(sb.ToString());
        if (url.Host != Base.Host || url.Port != Base.Port || !url.AbsolutePath.StartsWith(BasePath + "/"))
            throw new ArgumentException($"Path escapes the gateway: {path}", nameof(path));
        return url;
    }

    /// ws(s)://host[:port][basePath]/api/ws?profile=…&ticket=… (ticket last).
    public Uri SocketUrl(string ticket, string profile = "default")
    {
        var http = Endpoint("/api/ws", [new("profile", profile), new("ticket", ticket)]);
        var b = new UriBuilder(http) { Scheme = http.Scheme == "https" ? "wss" : "ws" };
        if (http.IsDefaultPort) b.Port = -1;
        return b.Uri;
    }

    /// The account key HermesKit uses: origin + base path, then "\n", then the username.
    public string AccountKey(string username) => ToString() + "\n" + username;

    public static bool IsLocalHost(string host)
    {
        host = host.Trim('[', ']').ToLowerInvariant().TrimEnd('.');
        // [own-vpn] Names that exist only on a network someone runs themselves (.home.arpa, .internal, .lan).
        if (host is "localhost" || host.EndsWith(".local") || host.EndsWith(".ts.net") || host.EndsWith(".localhost")
            || host.EndsWith(".home.arpa") || host.EndsWith(".internal") || host.EndsWith(".lan"))
            return true;
        if (IPAddress.TryParse(host, out var ip))
        {
            if (IPAddress.IsLoopback(ip)) return true;
            if (ip.AddressFamily == AddressFamily.InterNetwork)
            {
                var b = ip.GetAddressBytes();
                return b[0] == 10
                    || (b[0] == 172 && b[1] is >= 16 and <= 31)
                    || (b[0] == 192 && b[1] == 168)
                    || (b[0] == 169 && b[1] == 254)
                    || (b[0] == 100 && b[1] is >= 64 and <= 127);
            }
            var v6 = ip.GetAddressBytes();
            return ip.IsIPv6LinkLocal || (v6[0] & 0xFE) == 0xFC;
        }
        return !host.Contains('.'); // single-label names (a Mac's or PC's name on the LAN)
    }

    public bool Equals(GatewayAddress? other) => other != null && ToString() == other.ToString();
    public override bool Equals(object? obj) => Equals(obj as GatewayAddress);
    public override int GetHashCode() => ToString().GetHashCode();
}
