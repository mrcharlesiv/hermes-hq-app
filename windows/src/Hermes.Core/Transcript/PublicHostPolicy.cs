using System.Net;
using System.Net.Sockets;
using System.Text.RegularExpressions;

namespace Hermes.Core.Transcripts;

/// Which hosts a URL found in a transcript may be fetched from (HermesKit/Net/PublicHostPolicy.swift): a bot's reply can
/// be written by a prompt injection, so a link title or icon comes only from the public internet over https, never this
/// PC's LAN, the gateway's Tailscale network, loopback, or a name that resolves to one.
public static partial class PublicHostPolicy
{
    private static readonly string[] LocalSuffixes = [".local", ".localhost", ".internal", ".home.arpa", ".ts.net"];

    [GeneratedRegex("^(0x[0-9a-f]*|[0-9]+)$")]
    private static partial Regex NumericLabel();

    /// A public https URL by its spelling: https, no user info, a dotted name that is not a local, Tailscale or reserved
    /// suffix, and (for a numeric host) a plain public dotted quad. Names still need `ResolvesPublic`.
    public static bool PublicHttps(Uri? url)
    {
        if (url is null || !url.IsAbsoluteUri || !string.Equals(url.Scheme, "https", StringComparison.OrdinalIgnoreCase)
            || url.UserInfo.Length > 0) return false;
        var host = url.IdnHost.ToLowerInvariant();
        if (host.Length == 0 || !host.Contains('.') || host.Contains(':') || url.HostNameType == UriHostNameType.IPv6) return false;
        if (LocalSuffixes.Any(s => host.EndsWith(s, StringComparison.Ordinal))) return false;
        var labels = host.Split('.');
        // A numeric last label is an address, never a name (127.1, 0x7f.1, 10.0.1): only a plain dotted quad is read.
        if (!NumericLabel().IsMatch(labels[^1])) return true;
        var octets = labels
            .Where(l => l.Length <= 3 && !(l.Length > 1 && l.StartsWith('0')) && byte.TryParse(l, out _))
            .Select(byte.Parse).ToArray();
        return labels.Length == 4 && octets.Length == 4 && PublicAddress(octets);
    }

    /// A globally routable address (4 or 16 bytes): never loopback, private, CGNAT/Tailscale, link-local, ULA, multicast,
    /// documentation or reserved space. IPv4-mapped, NAT64 and 6to4 addresses are judged by their IPv4.
    public static bool PublicAddress(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length == 4)
        {
            var (a, b, c) = (bytes[0], bytes[1], bytes[2]);
            return !(a == 0 || a == 10 || a == 127 || a >= 224 || (a == 100 && b is >= 64 and <= 127) || (a == 169 && b == 254)
                     || (a == 172 && b is >= 16 and <= 31) || (a == 192 && b == 168) || (a == 192 && b == 0 && (c == 0 || c == 2))
                     || (a == 198 && b is >= 18 and <= 19) || (a == 198 && b == 51 && c == 100) || (a == 203 && b == 0 && c == 113));
        }
        if (bytes.Length != 16) return false;
        var v4 = bytes[12..];
        if (!bytes[..10].ContainsAnyExcept((byte)0) && ((bytes[10] == 0xff && bytes[11] == 0xff) || (bytes[10] == 0 && bytes[11] == 0)))
            return (bytes[10] == 0xff || v4[0] != 0) && PublicAddress(v4);   // ::ffff:a.b.c.d and ::a.b.c.d; :: and ::1 aren't
        if (bytes[..12].SequenceEqual(new byte[] { 0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0 })) return PublicAddress(v4);   // NAT64
        if (bytes[0] == 0x20 && bytes[1] == 0x02) return PublicAddress(bytes[2..6]);   // 6to4
        var (x, y) = (bytes[0], bytes[1]);
        return !((x & 0xfe) == 0xfc || (x == 0xfe && (y & 0x80) == 0x80) || x == 0xff
                 || (x == 0x20 && y == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8)
                 || (x == 0x01 && y == 0 && !bytes[2..8].ContainsAnyExcept((byte)0)));
    }

    public static bool PublicAddress(IPAddress address) => PublicAddress(address.GetAddressBytes());

    /// A public https URL whose host resolves, on this PC, only to public addresses (a LAN or split-horizon name is never
    /// fetched).
    public static async Task<bool> AllowedAsync(Uri? url, PublicHosts? hosts = null)
    {
        if (!PublicHttps(url)) return false;
        return await (hosts ?? PublicHosts.Shared).ResolvesPublicAsync(url!.IdnHost);
    }

    /// Host lookups with a small verdict cache (`resolve` is swappable for tests): a verdict is kept for a minute (a
    /// failed lookup for ten seconds), and a caller gives up after `timeout` (the answer is then no).
    public sealed class PublicHosts(Func<string, CancellationToken, Task<byte[][]>>? resolve = null, TimeSpan? timeout = null)
    {
        public static readonly PublicHosts Shared = new();
        private readonly Func<string, CancellationToken, Task<byte[][]>> _resolve = resolve ?? Lookup;
        private readonly TimeSpan _timeout = timeout ?? TimeSpan.FromSeconds(5);
        private readonly Lock _lock = new();
        private readonly Dictionary<string, (bool Public, DateTime Until)> _verdicts = [];
        private readonly Dictionary<string, Task<bool>> _waiting = [];

        public async Task<bool> ResolvesPublicAsync(string host)
        {
            var key = host.ToLowerInvariant();
            Task<bool> check;
            lock (_lock)
            {
                if (_verdicts.TryGetValue(key, out var known) && known.Until > DateTime.UtcNow) return known.Public;
                if (!_waiting.TryGetValue(key, out check!))
                {
                    check = Task.Run(() => Check(key));
                    _waiting[key] = check;
                }
            }
            var done = await Task.WhenAny(check, Task.Delay(_timeout));
            return done == check && await check;
        }

        private async Task<bool> Check(string key)
        {
            byte[][] addresses;
            try { addresses = await _resolve(key, CancellationToken.None); }
            catch (Exception) { addresses = []; }
            var verdict = addresses.Length > 0 && addresses.All(a => PublicAddress(a));
            lock (_lock)
            {
                _verdicts[key] = (verdict, DateTime.UtcNow + TimeSpan.FromSeconds(addresses.Length == 0 ? 10 : 60));
                if (_verdicts.Count > 256)
                    foreach (var stale in _verdicts.Where(v => v.Value.Until <= DateTime.UtcNow).Select(v => v.Key).ToList())
                        _verdicts.Remove(stale);
                _waiting.Remove(key);
            }
            return verdict;
        }

        public static async Task<byte[][]> Lookup(string host, CancellationToken ct)
        {
            try
            {
                var found = await Dns.GetHostAddressesAsync(host, ct);
                return [.. found.Where(a => a.AddressFamily is AddressFamily.InterNetwork or AddressFamily.InterNetworkV6)
                    .Select(a => a.GetAddressBytes())];
            }
            catch (SocketException) { return []; }
        }
    }
}
