using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text;
using Hermes.Core.Transcripts;
using Xunit;

namespace Hermes.Core.Tests;

// [transcript] Link chips and fetched link titles (docs/spec/3x-transcript.md §3.7; App/Chat/Cells/LinkChipView.swift,
// HermesKit/Net/LinkPreviewFetcher.swift, PublicHostPolicy.swift, MarkdownRenderer.loneWebAddress). Every page is served
// by a loopback stand-in in this file; nothing reaches the network.

public class LinkChipSelectionTests
{
    private static List<string> Shape(IReadOnlyList<ReplySegment> segments) =>
        [.. segments.Select(s => s switch { ChipSegment c => "chip:" + c.Raw, WordsSegment w => "words:" + w.Markdown, _ => "?" })];

    [Fact]
    public void LoneWebAddressRules()
    {
        Assert.Equal("https://example.com/docs", LinkChips.LoneWebAddress("  https://example.com/docs \n")?.OriginalString);
        Assert.Null(LinkChips.LoneWebAddress("http://example.com/"));          // https only
        Assert.Null(LinkChips.LoneWebAddress("HTTPS://example.com/"));         // as the Mac: the prefix is exact
        Assert.Null(LinkChips.LoneWebAddress("https://localhost/x"));          // a host without a dot
        Assert.Null(LinkChips.LoneWebAddress("see https://example.com"));      // words around it
        Assert.Null(LinkChips.LoneWebAddress("https://example.com/a b"));
        Assert.Null(LinkChips.LoneWebAddress("https://example.com/" + new string('a', 2048)));
    }

    [Fact]
    public void ALoneLinkParagraphOfASettledReplyBecomesAChip()
    {
        var reply = "Here is the page:\n\nhttps://example.com/docs\n\nAnything else?";
        Assert.Equal(["words:Here is the page:", "chip:https://example.com/docs", "words:Anything else?"],
            Shape(LinkChips.Split(reply, settled: true)));
        Assert.Equal(["chip:https://example.com/"], Shape(LinkChips.Split("https://example.com/", settled: true)));
        // Yours, or still arriving: no chip.
        Assert.False(LinkChips.Shows(mine: true, streaming: false));
        Assert.False(LinkChips.Shows(mine: false, streaming: true));
        Assert.True(LinkChips.Shows(mine: false, streaming: false));
        Assert.Equal(["words:" + reply], Shape(LinkChips.Split(reply, settled: false)));
    }

    [Fact]
    public void ALinkInsideWordsListsQuotesOrCodeKeepsItsText()
    {
        foreach (var reply in new[]
                 {
                     "Read https://example.com/docs first.",
                     "The page:\nhttps://example.com/docs",                 // the same paragraph as the line above
                     "https://example.com/docs\ncontinues here",            // and below
                     "- one\n- https://example.com/docs",
                     "- one\n\n  https://example.com/docs",                 // the list item's own paragraph
                     "> https://example.com/docs",
                     "```\nhttps://example.com/docs\n```",
                     "    https://example.com/docs",                       // indented code
                     "[Example](https://example.com/docs)",                 // words, not the address
                     "http://example.com/docs",
                     "https://example.com/docs\n---",                       // a setext heading
                 })
            Assert.Equal(["words:" + reply], Shape(LinkChips.Split(reply, settled: true)));
    }

    [Fact]
    public void TheParagraphsPlainTextDecidesAsOnTheMac()
    {
        Assert.Equal(["chip:https://example.com/a"], Shape(LinkChips.Split("<https://example.com/a>", true)));
        Assert.Equal(["chip:https://example.com/a"], Shape(LinkChips.Split("[https://example.com/a](https://example.com/a)", true)));
        Assert.Equal(["chip:https://example.com/a"], Shape(LinkChips.Split("**https://example.com/a**", true)));
        Assert.Equal(["chip:https://example.com/a"], Shape(LinkChips.Split("`https://example.com/a`", true)));
        // After a heading or a list (with a blank line), a lone link is its own paragraph again.
        Assert.Equal(["words:# Docs", "chip:https://example.com/a"], Shape(LinkChips.Split("# Docs\nhttps://example.com/a", true)));
        Assert.Equal(["words:- one", "chip:https://example.com/a"], Shape(LinkChips.Split("- one\n\nhttps://example.com/a", true)));
    }

    [Fact]
    public void FormulasAndReferenceLinksSurviveTheSplit()
    {
        var reply = "Where $x_1 = 2$:\n\n$$\na_b\n\nc_d\n$$\n\nhttps://example.com/a\n\nSee [the docs][d].\n\n[d]: https://example.com/d";
        var segments = LinkChips.Split(reply, true);
        // The formulas come back as written (blank lines around a display formula may grow; Markdown reads them the same).
        var first = Assert.IsType<WordsSegment>(segments[0]).Markdown;
        Assert.StartsWith("Where $x_1 = 2$:\n", first);
        Assert.Contains("\n$$\na_b\n\nc_d\n$$\n", first);
        Assert.EndsWith("\n\n[d]: https://example.com/d", first);
        Assert.Equal(2, MathText.Extract(first).Formulas.Count);
        Assert.Equal("chip:https://example.com/a", Shape(segments)[1]);
        Assert.Equal("words:See [the docs][d].\n\n[d]: https://example.com/d", Shape(segments)[2]);
        // A link inside a display formula is never a chip.
        Assert.Single(LinkChips.Split("$$\n\nhttps://example.com/a\n\n$$", true));
    }

    [Fact]
    public void ChipFaceBeforeAndAfterItsTitle()
    {
        var url = new Uri("https://www.example.com/docs/intro?tab=2");
        var before = LinkChips.Face(url.OriginalString, url, null);
        Assert.Equal("example.com/docs/intro…", before.Title);
        Assert.Equal("example.com", before.Host);
        Assert.False(before.HostShown);                       // the address already names its host
        Assert.Equal("Link, example.com/docs/intro…", before.AccessibleName);
        Assert.False(before.HasIcon);                         // the globe

        var after = LinkChips.Face(url.OriginalString, url, new LinkPreview("  Example Docs \n", [1, 2]));
        Assert.Equal("Example Docs", after.Title);
        Assert.True(after.HostShown);
        Assert.Equal("Link, Example Docs, example.com", after.AccessibleName);
        Assert.True(after.HasIcon);

        Assert.False(LinkChips.Face(url.OriginalString, url, new LinkPreview("Example.com — Docs", null)).HostShown);
        Assert.Equal("example.com/docs/intro…", LinkChips.Face(url.OriginalString, url, new LinkPreview("  ", [1])).Title);
    }
}

public class PublicHostPolicyTests
{
    [Fact]
    public void PublicHttpsBySpelling()
    {
        foreach (var ok in new[] { "https://example.com/", "https://sub.example.org/a?b", "https://93.184.216.34/" })
            Assert.True(PublicHostPolicy.PublicHttps(new Uri(ok)), ok);
        foreach (var no in new[]
                 {
                     "http://example.com/", "https://user:pw@example.com/", "https://localhost/", "https://printer.local/",
                     "https://box.tail1234.ts.net/", "https://db.internal/", "https://router.home.arpa/", "https://x.localhost/",
                     "https://127.0.0.1/", "https://10.0.0.5/", "https://192.168.1.2/", "https://100.64.0.1/", "https://169.254.1.1/",
                     "https://[::1]/", "https://[2606:2800:220:1::1]/", "https://0x7f.1/",
                 })
            Assert.False(PublicHostPolicy.PublicHttps(new Uri(no)), no);
    }

    [Fact]
    public void PublicAddresses()
    {
        Assert.True(PublicHostPolicy.PublicAddress(IPAddress.Parse("93.184.216.34")));
        Assert.True(PublicHostPolicy.PublicAddress(IPAddress.Parse("2606:2800:220:1::1")));
        foreach (var no in new[] { "127.0.0.1", "10.1.2.3", "172.16.0.1", "192.168.0.1", "100.100.1.1", "169.254.0.1", "0.0.0.0",
                     "224.0.0.1", "192.0.2.1", "198.51.100.1", "203.0.113.1", "198.18.0.1", "::1", "::", "fe80::1", "fd00::1",
                     "ff02::1", "2001:db8::1", "::ffff:10.0.0.1", "64:ff9b::a00:1", "2002:a00:1::1" })
            Assert.False(PublicHostPolicy.PublicAddress(IPAddress.Parse(no)), no);
        Assert.True(PublicHostPolicy.PublicAddress(IPAddress.Parse("::ffff:93.184.216.34")));
    }

    [Fact]
    public async Task ANameMustResolveOnlyToPublicAddresses()
    {
        var hosts = new PublicHostPolicy.PublicHosts((host, _) => Task.FromResult<byte[][]>(host switch
        {
            "example.com" => [[93, 184, 216, 34]],
            "split.example.com" => [[93, 184, 216, 34], [10, 0, 0, 5]],
            _ => [],
        }));
        Assert.True(await PublicHostPolicy.AllowedAsync(new Uri("https://example.com/"), hosts));
        Assert.False(await PublicHostPolicy.AllowedAsync(new Uri("https://split.example.com/"), hosts));
        Assert.False(await PublicHostPolicy.AllowedAsync(new Uri("https://nowhere.example.com/"), hosts));
        Assert.False(await PublicHostPolicy.AllowedAsync(new Uri("http://example.com/"), hosts));
        var slow = new PublicHostPolicy.PublicHosts(async (_, _) => { await Task.Delay(2000); return [[93, 184, 216, 34]]; },
            TimeSpan.FromMilliseconds(50));
        Assert.False(await PublicHostPolicy.AllowedAsync(new Uri("https://example.com/"), slow));   // gave up: no
    }
}

public class LinkPreviewsCacheTests
{
    private sealed class FakeFetcher : ILinkFetching
    {
        public readonly ConcurrentQueue<string> Pages = new(), Images = new();
        public Func<Uri, Task<LinkFetchResult>> Page = u =>
            Task.FromResult(new LinkFetchResult(u, "text/html", Encoding.UTF8.GetBytes("<title>T</title>")));
        public Func<Uri, Task<LinkFetchResult>> Image = _ => throw new LinkFetchRefusedException("none");
        public Task<LinkFetchResult> PageAsync(Uri url) { Pages.Enqueue(url.AbsoluteUri); return Page(url); }
        public Task<LinkFetchResult> ImageAsync(Uri url) { Images.Enqueue(url.AbsoluteUri); return Image(url); }
    }

    [Fact]
    public async Task IneligibleLinksNeverFetch()
    {
        var fetcher = new FakeFetcher();
        var previews = new LinkPreviews(fetcher);
        foreach (var raw in new[] { "http://example.com/", "https://10.0.0.5/", "https://printer.local/", "https://box.tail1234.ts.net/",
                     "https://user:pw@example.com/", "https://localhost/", "not a url", "file:///Users/me/x.html" })
        {
            Assert.Null(await previews.PreviewAsync(raw));
            Assert.True(previews.Settled(raw));
        }
        Assert.Empty(previews.Started);
        Assert.Empty(fetcher.Pages);
        Assert.Empty(fetcher.Images);
    }

    [Fact]
    public async Task OneReadPerUrlARefusalIsRemembered()
    {
        var fetcher = new FakeFetcher();
        var previews = new LinkPreviews(fetcher);
        var a = await previews.PreviewAsync("https://example.com/a");
        Assert.Equal("T", a?.Title);
        Assert.Equal("T", (await previews.PreviewAsync("https://example.com/a"))?.Title);
        Assert.Single(fetcher.Pages);

        fetcher.Page = _ => throw new LinkFetchRefusedException("status 404");
        Assert.Null(await previews.PreviewAsync("https://example.com/gone"));
        Assert.Null(await previews.PreviewAsync("https://example.com/gone"));
        Assert.Equal(2, fetcher.Pages.Count);
        Assert.Equal(["https://example.com/a", "https://example.com/gone"], previews.Started);
    }

    [Fact]
    public async Task ANetworkFailureIsAskedAgainAfterItCools()
    {
        var now = TimeSpan.Zero;
        var fetcher = new FakeFetcher { Page = _ => throw new LinkFetchTransientException("offline") };
        var previews = new LinkPreviews(fetcher, TimeSpan.FromSeconds(60), () => now);
        Assert.Null(await previews.PreviewAsync("https://example.com/a"));
        Assert.True(previews.Settled("https://example.com/a"));
        now = TimeSpan.FromSeconds(30);
        Assert.Null(await previews.PreviewAsync("https://example.com/a"));
        Assert.Single(fetcher.Pages);
        now = TimeSpan.FromSeconds(61);
        fetcher.Page = u => Task.FromResult(new LinkFetchResult(u, "text/html", Encoding.UTF8.GetBytes("<title>Back</title>")));
        Assert.Equal("Back", (await previews.PreviewAsync("https://example.com/a"))?.Title);
        Assert.Equal(2, fetcher.Pages.Count);
    }

    [Fact]
    public async Task ConcurrentAsksShareOneReadAtMostThreeInFlight()
    {
        var gate = new TaskCompletionSource();
        var active = 0; var peak = 0;
        var fetcher = new FakeFetcher();
        fetcher.Page = async u =>
        {
            var n = Interlocked.Increment(ref active);
            lock (fetcher) peak = Math.Max(peak, n);
            await gate.Task;
            Interlocked.Decrement(ref active);
            return new LinkFetchResult(u, "text/html", Encoding.UTF8.GetBytes("<title>P</title>"));
        };
        var previews = new LinkPreviews(fetcher);
        var asks = Enumerable.Range(0, 6).Select(i => previews.PreviewAsync($"https://example.com/{i}"))
            .Concat(Enumerable.Range(0, 4).Select(_ => previews.PreviewAsync("https://example.com/0"))).ToList();
        await Task.Delay(200);
        Assert.Equal(3, peak);
        gate.SetResult();
        var results = await Task.WhenAll(asks);
        Assert.All(results, r => Assert.Equal("P", r?.Title));
        Assert.Equal(6, fetcher.Pages.Count);
        Assert.Equal(3, peak);
    }

    [Fact]
    public async Task SixtyFourPagesAreKept()
    {
        var fetcher = new FakeFetcher();
        var previews = new LinkPreviews(fetcher);
        for (var i = 0; i <= LinkPreviews.MaxPages; i++) await previews.PreviewAsync($"https://example.com/{i}");
        Assert.Null(previews.Known("https://example.com/0"));
        Assert.NotNull(previews.Known("https://example.com/1"));
        Assert.NotNull(previews.Known($"https://example.com/{LinkPreviews.MaxPages}"));
    }

    [Fact]
    public async Task TheStubAnswersWithoutTheNetwork()
    {
        var fetcher = new FakeFetcher();
        var previews = new LinkPreviews(fetcher);
        previews.SetStub(LinkPreviews.ParseStub("https://example.com/=>Example Domain;https://bad.example/=>-"));
        var hit = await previews.PreviewAsync("https://example.com/");
        Assert.Equal("Example Domain", hit?.Title);
        Assert.Equal("image/png", LinkPreviewParsing.ImageMime(hit!.Icon!));
        Assert.Null(await previews.PreviewAsync("https://bad.example/"));
        Assert.Empty(fetcher.Pages);
    }
}

/// The real fetcher against a loopback stand-in: the policy sees the address as written ("https://example.com/…", which
/// a test resolver says is public); the request itself goes to 127.0.0.1 over http.
public class LinkPreviewFetcherLoopbackTests : IDisposable
{
    private sealed record Reply(int Status, string Type, byte[] Body, string? Location = null);

    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly ConcurrentDictionary<string, Reply> _routes = new();
    private readonly ConcurrentQueue<string> _hits = new();
    private readonly CancellationTokenSource _stop = new();
    private int Port => ((IPEndPoint)_listener.LocalEndpoint).Port;

    public LinkPreviewFetcherLoopbackTests()
    {
        _listener.Start();
        _ = Task.Run(Serve);
    }

    public void Dispose() { _stop.Cancel(); _listener.Stop(); }

    private async Task Serve()
    {
        while (!_stop.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await _listener.AcceptTcpClientAsync(_stop.Token); } catch { return; }
            _ = Task.Run(async () =>
            {
                using (client)
                {
                    var stream = client.GetStream();
                    var reader = new StreamReader(stream, Encoding.ASCII);
                    while (await reader.ReadLineAsync() is { Length: > 0 } requestLine)
                    {
                        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                        while (await reader.ReadLineAsync() is { Length: > 0 } h)
                            if (h.IndexOf(':') is var c and > 0) headers[h[..c]] = h[(c + 1)..].Trim();
                        var path = requestLine.Split(' ')[1];
                        _hits.Enqueue(path + (headers.ContainsKey("Cookie") ? " cookie" : "") + (headers.ContainsKey("Authorization") ? " auth" : ""));
                        var reply = _routes.GetValueOrDefault(path) ?? new Reply(404, "text/plain", "missing"u8.ToArray());
                        var head = $"HTTP/1.1 {reply.Status} X\r\nContent-Type: {reply.Type}\r\nContent-Length: {reply.Body.Length}\r\n"
                                   + (reply.Location is { } l ? $"Location: {l}\r\n" : "") + "\r\n";
                        try
                        {
                            await stream.WriteAsync(Encoding.ASCII.GetBytes(head));
                            await stream.WriteAsync(reply.Body);
                            await stream.FlushAsync();
                        }
                        catch (IOException) { return; }
                    }
                }
            });
        }
    }

    private static readonly PublicHostPolicy.PublicHosts Resolver = new((host, _) => Task.FromResult<byte[][]>(host switch
    {
        "example.com" or "www.example.com" or "cdn.example.net" => [[93, 184, 216, 34]],
        "intranet.example.com" => [[10, 0, 0, 5]],
        _ => [],
    }));

    private LinkPreviewFetcher Fetcher(bool checksPeer = false) => new(Resolver, checksPeer,
        u => new UriBuilder(u) { Scheme = "http", Host = "127.0.0.1", Port = Port }.Uri);

    private void Html(string path, string html, string type = "text/html; charset=utf-8") =>
        _routes[path] = new Reply(200, type, Encoding.UTF8.GetBytes(html));

    private static byte[] Png(int size)
    {
        var bytes = new byte[size];
        new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }.CopyTo(bytes, 0);
        return bytes;
    }

    [Fact]
    public async Task ReadsTheTitleAndTheSitesIcon()
    {
        Html("/docs", "<html><head><title>Synthetic &amp; Docs</title><link rel=\"icon\" href=\"/i.png\" sizes=\"192x192\"></head></html>");
        _routes["/i.png"] = new Reply(200, "image/png", Png(200));
        var previews = new LinkPreviews(Fetcher());
        var preview = await previews.PreviewAsync("https://example.com/docs");
        Assert.Equal("Synthetic & Docs", preview?.Title);
        Assert.Equal(200, preview?.Icon?.Length);
        Assert.Equal(["/docs", "/i.png"], _hits);   // no cookie, no auth on either
        // The host's icon is kept: a second page on the host reads only the page.
        Html("/other", "<title>Other</title><link rel=icon href=/i.png sizes=192x192>");
        Assert.Equal("Other", (await previews.PreviewAsync("https://example.com/other"))?.Title);
        Assert.Equal(["/docs", "/i.png", "/other"], _hits);
        var face = LinkChips.Face("https://example.com/docs", new Uri("https://example.com/docs"), preview);
        Assert.Equal("Link, Synthetic & Docs, example.com", face.AccessibleName);
    }

    [Fact]
    public async Task FollowsAPublicHttpsRedirectButNeverDownToHttpOrIntoTheLan()
    {
        _routes["/moved"] = new Reply(301, "text/plain", [], "https://www.example.com/landing");
        Html("/landing", "<title>Landed</title>");
        _routes["/to-http"] = new Reply(302, "text/plain", [], "http://example.com/plain");
        _routes["/to-lan"] = new Reply(302, "text/plain", [], "https://intranet.example.com/secret");
        Html("/plain", "<title>Plain</title>");
        Html("/secret", "<title>Secret</title>");
        var fetcher = Fetcher();
        var landed = await fetcher.PageAsync(new Uri("https://example.com/moved"));
        Assert.Equal("https://www.example.com/landing", landed.Url.AbsoluteUri);
        await Assert.ThrowsAsync<LinkFetchRefusedException>(() => fetcher.PageAsync(new Uri("https://example.com/to-http")));
        await Assert.ThrowsAsync<LinkFetchRefusedException>(() => fetcher.PageAsync(new Uri("https://example.com/to-lan")));
        Assert.DoesNotContain("/plain", _hits);
        Assert.DoesNotContain("/secret", _hits);
        for (var i = 0; i < 7; i++) _routes[$"/loop{i}"] = new Reply(302, "text/plain", [], $"https://example.com/loop{i + 1}");
        await Assert.ThrowsAsync<LinkFetchRefusedException>(() => fetcher.PageAsync(new Uri("https://example.com/loop0")));
        Assert.DoesNotContain("/loop6", _hits);   // five redirects at most
    }

    [Fact]
    public async Task ANonPublicHostIsNeverRequested()
    {
        var fetcher = Fetcher();
        await Assert.ThrowsAsync<LinkFetchRefusedException>(() => fetcher.PageAsync(new Uri("https://intranet.example.com/x")));
        await Assert.ThrowsAsync<LinkFetchRefusedException>(() => fetcher.PageAsync(new Uri("https://unknown.example.org/x")));
        Assert.Empty(_hits);
        // The peer check: a public-looking address that connects to loopback is refused before a byte is sent.
        Html("/docs", "<title>Docs</title>");
        await Assert.ThrowsAsync<LinkFetchRefusedException>(() => Fetcher(checksPeer: true).PageAsync(new Uri("https://example.com/docs")));
        Assert.Empty(_hits);
    }

    [Fact]
    public async Task BoundsAndRefusals()
    {
        // 256 KiB of a page is read: a title after that is not seen.
        Html("/long", new string(' ', LinkPreviewParsing.HtmlLimit + 10) + "<title>Too late</title>");
        var page = await Fetcher().PageAsync(new Uri("https://example.com/long"));
        Assert.Equal(LinkPreviewParsing.HtmlLimit, page.Data.Length);
        // An icon over 64 KiB is refused; a bad status is refused.
        _routes["/big.png"] = new Reply(200, "image/png", Png(LinkPreviewParsing.ImageLimit + 1));
        await Assert.ThrowsAsync<LinkFetchRefusedException>(() => Fetcher().ImageAsync(new Uri("https://example.com/big.png")));
        await Assert.ThrowsAsync<LinkFetchRefusedException>(() => Fetcher().PageAsync(new Uri("https://example.com/nothing")));
        // A sign-in page's title is not the document's; an error page's neither: no title and no icon is a refusal.
        _routes["/gate"] = new Reply(302, "text/plain", [], "https://example.com/login");
        Html("/login", "<title>Example Docs</title>");
        Html("/blocked", "<title>Just a moment...</title>");
        var previews = new LinkPreviews(Fetcher());
        Assert.Null(await previews.PreviewAsync("https://example.com/gate"));
        Assert.Null(await previews.PreviewAsync("https://example.com/blocked"));
        // Latin-1 by its header.
        _routes["/latin"] = new Reply(200, "text/html; charset=iso-8859-1", Encoding.Latin1.GetBytes("<title>Caf\u00e9</title>"));
        Assert.Equal("Caf\u00e9", (await previews.PreviewAsync("https://example.com/latin"))?.Title);
    }
}
