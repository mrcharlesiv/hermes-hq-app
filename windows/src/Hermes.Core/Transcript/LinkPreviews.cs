using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Security.Authentication;

namespace Hermes.Core.Transcripts;

// [transcript] Link titles and site icons (HermesKit/Net/LinkPreviewFetcher.swift; docs/spec/3x-transcript.md §3.7):
// this PC's own bounded, cookieless https read. No cookies, no cache, no credentials, no proxy, 5 s timeouts, two
// connections per host; public hosts only (`PublicHostPolicy`), every redirect checked again and never down to http,
// the connected peer's address checked public; 256 KiB of a page is read (the rest is dropped), an icon over 64 KiB is
// refused. Nothing about the gateway, the bot or the user is sent, and it never goes through the gateway.

/// What a link shows once its page was read. `Title` is "" when the page gave no usable title; `Icon` is the site's icon
/// bytes (PNG, JPEG, GIF, WebP or ICO), null for the globe.
public sealed record LinkPreview(string Title, byte[]? Icon);

public sealed record LinkFetchResult(Uri Url, string Type, byte[] Data);

public interface ILinkFetching
{
    Task<LinkFetchResult> PageAsync(Uri url);
    Task<LinkFetchResult> ImageAsync(Uri url);
}

/// The read was refused (not public, a bad status, too large, a redirect it may not follow): remembered for the run.
public sealed class LinkFetchRefusedException(string reason) : Exception(reason);

/// [link-retry] The read failed because the network was not there (unreachable, a blip, a timeout): asked again later.
public sealed class LinkFetchTransientException(string reason) : Exception(reason);

public sealed class LinkPreviewFetcher : ILinkFetching
{
    public const int MaxRedirects = 5;
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(5);
    private readonly HttpClient _client;
    private readonly PublicHostPolicy.PublicHosts _hosts;
    /// Tests only: where a checked https address is actually read (a loopback stand-in). The policy is applied to the
    /// address as written; the peer check (off with this) is what would refuse a loopback peer.
    private readonly Func<Uri, Uri>? _transport;

    public LinkPreviewFetcher() : this(null, checksPeer: true, transport: null) { }

    internal LinkPreviewFetcher(PublicHostPolicy.PublicHosts? hosts, bool checksPeer, Func<Uri, Uri>? transport)
    {
        _hosts = hosts ?? PublicHostPolicy.PublicHosts.Shared;
        _transport = transport;
        var handler = new SocketsHttpHandler
        {
            UseCookies = false,
            AllowAutoRedirect = false,
            UseProxy = false,
            Credentials = null,
            PreAuthenticate = false,
            MaxConnectionsPerServer = 2,
            ConnectTimeout = Timeout,
            AutomaticDecompression = DecompressionMethods.All,
        };
        if (checksPeer) handler.ConnectCallback = ConnectPublic;
        _client = new HttpClient(handler) { Timeout = System.Threading.Timeout.InfiniteTimeSpan };
    }

    /// The peer check: the name is resolved here and every address must be public before a socket opens to one.
    private static async ValueTask<Stream> ConnectPublic(SocketsHttpConnectionContext context, CancellationToken ct)
    {
        var host = context.DnsEndPoint.Host;
        var addresses = IPAddress.TryParse(host.Trim('[', ']'), out var literal) ? [literal] : await Dns.GetHostAddressesAsync(host, ct);
        if (addresses.Length == 0 || !addresses.All(PublicHostPolicy.PublicAddress))
            throw new LinkFetchRefusedException("peer is not public");
        var socket = new Socket(SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
        try
        {
            await socket.ConnectAsync(addresses, context.DnsEndPoint.Port, ct);
            return new NetworkStream(socket, ownsSocket: true);
        }
        catch { socket.Dispose(); throw; }
    }

    /// [WIN-36] The CI walk's reader (Services/ProofWalks.Transcript.cs, the composer stand-in's “Release review” chat):
    /// only `WalkLinkHost` counts as public, decided without a lookup, and every read the policy allows goes over http to
    /// `standIn`, which must be on loopback, at `StandInRoute`. Nothing reaches the network. Never used outside the walk.
    public static LinkPreviewFetcher LoopbackStandIn(Uri standIn)
    {
        if (!standIn.IsAbsoluteUri || !standIn.IsLoopback || standIn.Scheme != "http")
            throw new ArgumentException("the walk's link stand-in must be http on loopback", nameof(standIn));
        var hosts = new PublicHostPolicy.PublicHosts((host, _) =>
            Task.FromResult<byte[][]>(string.Equals(host, WalkLinkHost, StringComparison.OrdinalIgnoreCase) ? [[93, 184, 216, 34]] : []));
        return new LinkPreviewFetcher(hosts, checksPeer: false, url => StandInRoute(standIn, url));
    }

    /// The only host the walk's reader treats as public (the synthetic address in the walk's chat).
    public const string WalkLinkHost = "example.com";

    /// Where the walk's reader reads `url`: the stand-in's `/__extras/link/<host><path><query>`.
    public static Uri StandInRoute(Uri standIn, Uri url) =>
        new(standIn, "/__extras/link/" + url.IdnHost + url.AbsolutePath + url.Query);

    public Task<LinkFetchResult> PageAsync(Uri url) =>
        ReadAsync(url, "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1", LinkPreviewParsing.HtmlLimit, truncates: true);

    public Task<LinkFetchResult> ImageAsync(Uri url) =>
        ReadAsync(url, "image/*", LinkPreviewParsing.ImageLimit, truncates: false);

    private async Task<LinkFetchResult> ReadAsync(Uri url, string accept, int limit, bool truncates)
    {
        if (!await PublicHostPolicy.AllowedAsync(url, _hosts)) throw new LinkFetchRefusedException("not a public https host");
        using var timeout = new CancellationTokenSource(Timeout);
        var ct = timeout.Token;
        var current = url;
        try
        {
            for (var hop = 0; ; hop++)
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, _transport?.Invoke(current) ?? current);
                request.Headers.Accept.ParseAdd(accept);
                using var response = await _client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
                var status = (int)response.StatusCode;
                if (status is >= 300 and < 400 && response.Headers.Location is { } location)
                {
                    var next = location.IsAbsoluteUri ? location : new Uri(current, location);
                    if (hop + 1 > MaxRedirects || !string.Equals(next.Scheme, "https", StringComparison.OrdinalIgnoreCase)
                        || !await PublicHostPolicy.AllowedAsync(next, _hosts))
                        throw new LinkFetchRefusedException("redirect refused");
                    current = next;
                    continue;
                }
                if (status is < 200 or >= 300) throw new LinkFetchRefusedException($"status {status}");
                if (!truncates && response.Content.Headers.ContentLength > limit) throw new LinkFetchRefusedException("too large");
                var type = response.Content.Headers.ContentType?.ToString() ?? "";
                await using var input = await response.Content.ReadAsStreamAsync(ct);
                var body = new MemoryStream();
                var buffer = new byte[16 * 1024];
                int n;
                while ((n = await input.ReadAsync(buffer, ct)) > 0)
                {
                    if (body.Length + n > limit)
                    {
                        if (!truncates) throw new LinkFetchRefusedException("too large");
                        body.Write(buffer, 0, limit - (int)body.Length);   // what arrived is parsed
                        break;
                    }
                    body.Write(buffer, 0, n);
                    if (truncates && body.Length == limit) break;
                }
                return new LinkFetchResult(current, type, body.ToArray());
            }
        }
        catch (OperationCanceledException) when (timeout.IsCancellationRequested) { throw new LinkFetchTransientException("timed out"); }
        catch (HttpRequestException e) when (e.InnerException is LinkFetchRefusedException refused) { throw refused; }
        catch (HttpRequestException e) when (Transient(e)) { throw new LinkFetchTransientException(e.Message); }
        catch (HttpRequestException e) { throw new LinkFetchRefusedException(e.Message); }
        catch (IOException e) { throw new LinkFetchTransientException(e.Message); }
    }

    /// Unreachable, lost, timed out, no such host: worth asking again. TLS and certificate failures are not.
    private static bool Transient(HttpRequestException e)
    {
        if (e.InnerException is AuthenticationException) return false;
        if (e.HttpRequestError is HttpRequestError.NameResolutionError or HttpRequestError.ConnectionError) return true;
        for (Exception? x = e; x != null; x = x.InnerException)
            if (x is SocketException { SocketErrorCode: SocketError.NetworkUnreachable or SocketError.HostUnreachable or SocketError.NetworkDown
                    or SocketError.ConnectionRefused or SocketError.ConnectionReset or SocketError.ConnectionAborted or SocketError.TimedOut
                    or SocketError.HostNotFound or SocketError.TryAgain or SocketError.NoData })
                return true;
        return false;
    }
}

/// Titles and icons for the links on screen (HermesKit `LinkPreviews`): one read per URL per app run (a refusal is
/// remembered; a network failure only for `retryAfter`), at most three page reads in flight, 64 pages and 128 host icons
/// kept in memory, nothing on disk.
public sealed class LinkPreviews
{
    private static readonly Lazy<LinkPreviews> SharedLazy = new(FromEnvironment);
    private static LinkPreviews? _replaced;
    public static LinkPreviews Shared => Volatile.Read(ref _replaced) ?? SharedLazy.Value;

    /// [WIN-36] The CI walk's own reader in place of the shared one (LinkPreviewFetcher.LoopbackStandIn); chips drawn
    /// afterwards read through it; null gives the shared one back. Never called outside the walk.
    public static void ReplaceShared(LinkPreviews? previews) => Volatile.Write(ref _replaced, previews);
    public const int MaxPages = 64;
    public const int MaxIcons = 128;
    public const int MaxIconBytes = 1_500_000;
    public const int MaxInFlight = 3;
    public const int MaxCooling = 128;

    private enum Kind { Ok, Refused, Transient }
    private sealed record Outcome(Kind Kind, LinkPreview? Preview = null);

    private readonly ILinkFetching _fetcher;
    private readonly TimeSpan _retryAfter;
    private readonly Func<TimeSpan> _now;
    private readonly Lock _gate = new();
    private readonly Dictionary<string, LinkPreview> _pages = [];
    private readonly List<string> _pageOrder = [];
    private readonly HashSet<string> _failed = [];
    private readonly Dictionary<string, TimeSpan> _cooling = [];
    private readonly Dictionary<string, Task<Outcome>> _flights = [];
    private readonly Dictionary<string, byte[]?> _icons = [];
    private readonly List<string> _iconOrder = [];
    private int _iconBytes;
    private readonly SemaphoreSlim _inFlight = new(MaxInFlight, MaxInFlight);
    private readonly List<string> _started = [];
    private Dictionary<string, LinkPreview?>? _stub;

    public LinkPreviews(ILinkFetching fetcher, TimeSpan? retryAfter = null, Func<TimeSpan>? now = null)
    {
        _fetcher = fetcher;
        _retryAfter = retryAfter ?? TimeSpan.FromSeconds(60);
        var clock = Stopwatch.StartNew();
        _now = now ?? (() => clock.Elapsed);
    }

    /// `HQNLinkPreviewStub='https://example.com/=>Example Domain;https://bad.example/=>-'` (the Mac's DEBUG launch
    /// argument): titles come from this table instead of the network (screenshots and UI tests); a listed page also gets a
    /// small drawn icon.
    private static LinkPreviews FromEnvironment()
    {
        var previews = new LinkPreviews(new LinkPreviewFetcher());
        if (Environment.GetEnvironmentVariable("HQNLinkPreviewStub") is { Length: > 0 } text) previews.SetStub(ParseStub(text));
        return previews;
    }

    /// "url=>title;url=>-": a title of "-" is a page that can't be read.
    public static Dictionary<string, LinkPreview?> ParseStub(string text)
    {
        var entries = new Dictionary<string, LinkPreview?>();
        foreach (var entry in text.Split(';'))
        {
            var parts = entry.Split("=>");
            if (parts.Length != 2) continue;
            entries[parts[0]] = parts[1] == "-" ? null : new LinkPreview(parts[1], StubIcon);
        }
        return entries;
    }

    /// A 16×16 blue square PNG (the Mac's stub draws the same).
    internal static readonly byte[] StubIcon = Convert.FromBase64String(
        "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFUlEQVR42mNgqPpPGhrVMKph+GoAAG3QeRDihKnIAAAAAElFTkSuQmCC");

    public void SetStub(Dictionary<string, LinkPreview?> entries) { lock (_gate) _stub = entries; }

    /// Every URL a read was started for (the tests count them).
    public IReadOnlyList<string> Started { get { lock (_gate) return [.. _started]; } }

    /// What is already known, without starting a read.
    public LinkPreview? Known(string url) { lock (_gate) return _pages.GetValueOrDefault(url); }

    /// Whether a read for this URL is over (answered or failed) or was never needed. A read that failed for want of a
    /// network counts as over too (until it is asked again).
    public bool Settled(string url) { lock (_gate) return _pages.ContainsKey(url) || _failed.Contains(url) || _cooling.ContainsKey(url); }

    /// The link's title and icon; null when the read was refused (remembered for the run) or the network was not there
    /// (asked again on the next call after `retryAfter`).
    public async Task<LinkPreview?> PreviewAsync(string raw)
    {
        Task<Outcome> flight;
        var owner = false;
        lock (_gate)
        {
            if (_pages.TryGetValue(raw, out var hit)) { Touch(raw); return hit; }
            if (_failed.Contains(raw)) return null;
            if (!_flights.TryGetValue(raw, out flight!))
            {
                if (_cooling.TryGetValue(raw, out var until))
                {
                    if (_now() < until) return null;
                    _cooling.Remove(raw);
                }
                if (!Uri.TryCreate(raw, UriKind.Absolute, out var url) || !(_stub != null || PublicHostPolicy.PublicHttps(url)))
                {
                    _failed.Add(raw);
                    return null;
                }
                _started.Add(raw);
                var stub = _stub;
                flight = Task.Run(() => LoadAsync(raw, url, stub));
                _flights[raw] = flight;
                owner = true;
            }
        }
        var outcome = await flight;
        if (owner)
            lock (_gate)
            {
                _flights.Remove(raw);
                switch (outcome.Kind)
                {
                    case Kind.Ok: Store(raw, outcome.Preview!); break;
                    case Kind.Refused: _failed.Add(raw); break;
                    case Kind.Transient: Cool(raw); break;
                }
            }
        return outcome.Preview;
    }

    private void Cool(string key)
    {
        _cooling[key] = _now() + _retryAfter;
        while (_cooling.Count > MaxCooling) _cooling.Remove(_cooling.MinBy(kv => kv.Value).Key);
    }

    private void Touch(string key)
    {
        if (_pageOrder.Count > 0 && _pageOrder[^1] == key) return;
        _pageOrder.Remove(key);
        _pageOrder.Add(key);
    }

    private void Store(string key, LinkPreview value)
    {
        if (!_pages.ContainsKey(key)) _pageOrder.Add(key);
        _pages[key] = value;
        while (_pageOrder.Count > MaxPages) { _pages.Remove(_pageOrder[0]); _pageOrder.RemoveAt(0); }
    }

    private async Task<Outcome> LoadAsync(string raw, Uri url, Dictionary<string, LinkPreview?>? stub)
    {
        if (stub != null)
            return stub.TryGetValue(raw, out var entry) && entry != null ? new Outcome(Kind.Ok, entry) : new Outcome(Kind.Refused);
        await _inFlight.WaitAsync();
        try
        {
            LinkFetchResult result;
            try { result = await _fetcher.PageAsync(url); }
            catch (LinkFetchTransientException) { return new Outcome(Kind.Transient); }
            catch (Exception) { return new Outcome(Kind.Refused); }
            var lower = result.Type.ToLowerInvariant();
            var title = "";
            var candidates = LinkPreviewParsing.IconCandidates("", result.Url.AbsoluteUri);
            if (lower.Contains("html") || lower.Contains("xml"))
            {
                var html = LinkPreviewParsing.Decode(result.Data, result.Type);
                title = LinkPreviewParsing.IsSignInArrival(result.Url) ? "" : LinkPreviewParsing.TitleFromHtml(html);
                candidates = LinkPreviewParsing.IconCandidates(html, result.Url.AbsoluteUri);
            }
            var (icon, iconTransient) = await IconAsync(result.Url.Host.Length > 0 ? result.Url.Host : url.Host, candidates);
            if (title.Length == 0 && icon == null) return new Outcome(iconTransient ? Kind.Transient : Kind.Refused);
            return new Outcome(Kind.Ok, new LinkPreview(title, icon));
        }
        finally { _inFlight.Release(); }
    }

    /// The host's icon, and whether a read for it failed for want of a network (then a miss is not remembered).
    private async Task<(byte[]? Icon, bool Transient)> IconAsync(string host, IReadOnlyList<string> candidates)
    {
        var key = host.ToLowerInvariant();
        lock (_gate) if (_icons.TryGetValue(key, out var known)) return (known, false);
        byte[]? found = null;
        var transient = false;
        foreach (var candidate in candidates)
        {
            if (!Uri.TryCreate(candidate, UriKind.Absolute, out var url) || !PublicHostPolicy.PublicHttps(url)) continue;
            LinkFetchResult result;
            try { result = await _fetcher.ImageAsync(url); }
            catch (LinkFetchTransientException) { transient = true; continue; }
            catch (Exception) { continue; }
            var mime = LinkPreviewParsing.ImageMime(result.Data, result.Type);
            // No SVG rasteriser here either: a scalable icon is skipped for the next candidate.
            if (mime.Length == 0 || mime == "image/svg+xml") continue;
            found = result.Data;
            break;
        }
        if (found == null && transient) return (null, true);
        lock (_gate)
        {
            if (!_icons.ContainsKey(key)) _iconOrder.Add(key); else _iconBytes -= _icons[key]?.Length ?? 0;
            _icons[key] = found;
            _iconBytes += found?.Length ?? 0;
            while ((_iconOrder.Count > MaxIcons || _iconBytes > MaxIconBytes) && _iconOrder.Count > 1)
            {
                var gone = _iconOrder[0];
                _iconOrder.RemoveAt(0);
                if (_icons.Remove(gone, out var data)) _iconBytes -= data?.Length ?? 0;
            }
        }
        return (found, false);
    }
}
