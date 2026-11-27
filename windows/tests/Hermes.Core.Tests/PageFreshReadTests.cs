using System.Net;
using System.Text;
using Hermes.Core.Attachments;
using Hermes.Core.Auth;
using Hermes.Core.Net;
using Hermes.Core.Transcripts;
using Xunit;

namespace Hermes.Core.Tests;

// [page-fresh-read] A bot answers a page's button by rewriting the file at the same path, so a page is read again each
// time it opens and each time its picture is drawn after a turn ends (HermesKit/Media/MediaLoader.swift `file(fresh:
// keptOnFailure:)`, App/Chat/Viewer/FilePreviewPresenter.swift `fresh: page`, PageSnapshots.swift `read`, at
// 93f984bb1). Other files keep the media store's copy. The gateway is a stand-in handler; pages are synthetic.

public class PageFreshReadTests
{
    private static readonly TimeSpan Deadline = TimeSpan.FromSeconds(10);
    private const string Page = "/Users/me/work/followups.html";
    private const string Pdf = "/Users/me/work/report.pdf";

    /// A gateway's /api/fs/download over files it can rewrite; `Answer` forces a status for the next reads.
    private sealed class Files : HttpMessageHandler
    {
        public readonly Dictionary<string, byte[]> Disk = [];
        public HttpStatusCode? Answer;
        public int Reads;

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Interlocked.Increment(ref Reads);
            if (Answer is { } forced) return Task.FromResult(new HttpResponseMessage(forced) { Content = new StringContent("") });
            var query = request.RequestUri!.Query.TrimStart('?').Split('&')
                .Select(p => p.Split('=', 2)).ToDictionary(p => Uri.UnescapeDataString(p[0]), p => Uri.UnescapeDataString(p[1]));
            return Task.FromResult(Disk.TryGetValue(query["path"], out var bytes)
                ? new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) }
                : new HttpResponseMessage(HttpStatusCode.NotFound) { Content = new StringContent("") });
        }
    }

    private static (MediaStore Store, Files Gateway) Rig()
    {
        var gateway = new Files();
        var session = new GatewaySession(GatewayAddress.Validated("http://127.0.0.1:9"), new StoredAccount("http://127.0.0.1:9", "qa"),
            new MemoryTokenStore(), gateway);
        return (new MediaStore(session, Directory.CreateTempSubdirectory("hq-page-fresh-").FullName), gateway);
    }

    private static byte[] B(string s) => Encoding.UTF8.GetBytes(s);

    private static async Task<string> Text(Task<string> file) => File.ReadAllText(await file.WaitAsync(Deadline));

    [Fact]
    public async Task ARewrittenPageOpensAsItsNewCopy()
    {
        var (store, gateway) = Rig();
        gateway.Disk[Page] = B("<p>v1</p>");
        Assert.Equal("<p>v1</p>", await Text(store.GatewayFileAsync(Page, "followups.html", "otto", null, fresh: true)));
        gateway.Disk[Page] = B("<p>v2, after the button</p>");
        Assert.Equal("<p>v2, after the button</p>", await Text(store.GatewayFileAsync(Page, "followups.html", "otto", null, fresh: true)));
        Assert.Equal(2, gateway.Reads);
    }

    [Fact]
    public async Task OtherFilesAreStillServedFromTheKeptCopy()
    {
        var (store, gateway) = Rig();
        gateway.Disk[Pdf] = B("%PDF-1 first");
        Assert.Equal("%PDF-1 first", await Text(store.GatewayFileAsync(Pdf, "report.pdf", "otto", null)));
        gateway.Disk[Pdf] = B("%PDF-1 second");
        Assert.Equal("%PDF-1 first", await Text(store.GatewayFileAsync(Pdf, "report.pdf", "otto", null)));
        // A page read without `fresh` (Save, Share) keeps today's caching too.
        gateway.Disk[Page] = B("<p>v1</p>");
        await store.GatewayFileAsync(Page, "followups.html", "otto", null).WaitAsync(Deadline);
        gateway.Disk[Page] = B("<p>v2</p>");
        Assert.Equal("<p>v1</p>", await Text(store.GatewayFileAsync(Page, "followups.html", "otto", null)));
        Assert.Equal(2, gateway.Reads);
    }

    [Fact]
    public async Task AFreshReadThatFailsFallsBackToTheKeptCopyUnlessAskedNotTo()
    {
        var (store, gateway) = Rig();
        gateway.Disk[Page] = B("<p>v1</p>");
        await store.GatewayFileAsync(Page, "followups.html", "otto", null, fresh: true).WaitAsync(Deadline);
        gateway.Answer = HttpStatusCode.BadGateway;
        Assert.Equal("<p>v1</p>", await Text(store.GatewayFileAsync(Page, "followups.html", "otto", null, fresh: true)));
        var e = await Assert.ThrowsAsync<MediaLoadException>(() =>
            store.GatewayFileAsync(Page, "followups.html", "otto", null, fresh: true, keptOnFailure: false).WaitAsync(Deadline));
        Assert.Equal(MediaLoadException.Kinds.Unreachable, e.Kind);
        // The kept copy survived the failed reads.
        gateway.Answer = null;
        gateway.Disk.Remove(Page);
        Assert.NotNull(store.CachedFile("otto", Page, "followups.html"));
    }

    [Fact]
    public async Task APicturesReadIsFreshSaysGoneAndOtherwiseDrawsTheKeptCopy()
    {
        var (store, gateway) = Rig();
        gateway.Disk[Page] = B("<p>v1</p>");
        Assert.Equal("<p>v1</p>", File.ReadAllText((await store.PagePictureFileAsync(Page, "followups.html", "otto", null).WaitAsync(Deadline))!));
        gateway.Disk[Page] = B("<p>v2</p>");
        Assert.Equal("<p>v2</p>", File.ReadAllText((await store.PagePictureFileAsync(Page, "followups.html", "otto", null).WaitAsync(Deadline))!));
        gateway.Answer = HttpStatusCode.InternalServerError;   // unreachable: the kept copy is drawn
        Assert.Equal("<p>v2</p>", File.ReadAllText((await store.PagePictureFileAsync(Page, "followups.html", "otto", null).WaitAsync(Deadline))!));
        gateway.Answer = HttpStatusCode.NotFound;              // gone from the gateway: no picture
        Assert.Null(await store.PagePictureFileAsync(Page, "followups.html", "otto", null).WaitAsync(Deadline));
    }

    [Fact]
    public async Task APageCardsPictureRedrawsTheNewCopyAfterTheTurnEnds()
    {
        var (store, gateway) = Rig();
        var ctx = new PageContext("acct-1", "otto");
        var snapshots = new PageSnapshots<string>((p, n, c) => store.PagePictureFileAsync(p, n, c.Profile, null),
            (file, _, _) => Task.FromResult<string?>(File.ReadAllText(file)));
        Task<string?> Ask()
        {
            var done = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
            snapshots.Picture(Page, "followups.html", ctx, false, PageShape.Phone, done.SetResult);
            return done.Task.WaitAsync(Deadline);
        }
        gateway.Disk[Page] = B("<p>v1</p>");
        Assert.Equal("<p>v1</p>", await Ask());
        gateway.Disk[Page] = B("<p>v2</p>");
        Assert.Equal("<p>v1</p>", await Ask());   // same generation: the picture already drawn
        Assert.Equal(1, gateway.Reads);
        snapshots.NoteTurnEnded(ctx);
        Assert.Equal("<p>v2</p>", await Ask());
        Assert.Equal(2, gateway.Reads);
    }

    [Theory]
    [InlineData("followups.html", true, true)]
    [InlineData("FOLLOWUPS.HTM", true, true)]
    [InlineData("followups.html", false, false)]   // Save / Share: the kept copy
    [InlineData("report.pdf", true, false)]
    [InlineData("chart.png", true, false)]
    public void OnlyOpeningAPageReadsItAfresh(string name, bool opening, bool fresh) =>
        Assert.Equal(fresh, PageCards.ReadsFresh(name, opening));

    private static string Source(params string[] parts)
    {
        var dir = AppContext.BaseDirectory;
        while (dir != null && !File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir);
        return File.ReadAllText(Path.Combine([dir ?? throw new InvalidOperationException("no windows/ folder"), .. parts]))
            .Replace("\r\n", "\n");
    }

    /// The app's two page readers go through the fresh path: the page window (a page card's click and a file row's) and
    /// the page card's picture; both draw an undeclared UTF-8 page as UTF-8.
    [Fact]
    public void ThePageWindowAndThePageCardsPictureReadAfresh()
    {
        var rows = Source("src", "HermesHQ.Windows", "Features", "Attachments", "AttachmentRenderers.cs");
        Assert.Contains("fresh: PageCards.ReadsFresh(a.Name, opening ?? openIt));", rows);
        Assert.Contains("await DownloadAsync(opening: true) is { } path) await MediaActions.OpenAsync(PageEncoding.DrawableFile(path), _a.Name);", rows);
        Assert.Contains("if (openIt) await MediaActions.OpenAsync(PageEncoding.DrawableFile(file), a.Name);", rows);
        var pictures = Source("src", "HermesHQ.Windows", "Features", "Transcript", "PagePictures.cs");
        Assert.Contains("await m.Center.Media.PagePictureFileAsync(path, name, m.Profile, m.SessionId);", pictures);
        Assert.Contains("new Uri(PageEncoding.DrawableFile(file)).AbsoluteUri;", pictures);
        Assert.DoesNotContain("Media.GatewayFileAsync(path, name, m.Profile, m.SessionId)", pictures);
    }
}

// [utf8-pages] Tests/Pages/PageEncodingTests.swift at 93f984bb1, case for case: a page file that declares no charset is
// read as UTF-8 when its bytes are UTF-8 (a local file is otherwise read as Latin-1: "·" showed as "Â·").
public class PageEncodingTests
{
    private static byte[] Data(string s) => Encoding.UTF8.GetBytes(s);

    [Fact]
    public void UndeclaredUtf8IsReadAsUtf8() =>
        Assert.True(PageEncoding.NeedsUtf8(Data("<html><body>Revenue · $12K — up</body></html>")));

    [Fact]
    public void DeclaredOrPlainIsLeftAlone()
    {
        Assert.False(PageEncoding.NeedsUtf8(Data("<html><head><meta charset=\"utf-8\"></head><body>a · b</body></html>")));
        Assert.False(PageEncoding.NeedsUtf8(Data("<meta http-equiv=\"Content-Type\" content=\"text/html; CHARSET=windows-1252\">·")));
        Assert.False(PageEncoding.NeedsUtf8([0xEF, 0xBB, 0xBF, .. Data("<p>a · b</p>")]));
        Assert.False(PageEncoding.NeedsUtf8(Data("<p>plain ascii</p>")));
        Assert.False(PageEncoding.NeedsUtf8([.. Data("<p>caf"), 0xE9, .. Data("</p>")]));   // Latin-1 bytes, not UTF-8
    }

    [Fact]
    public void OnlyHtmlFilesAreRead()
    {
        var folder = Directory.CreateTempSubdirectory("page-encoding-").FullName;
        try
        {
            var page = Path.Combine(folder, "tile.html");
            var text = Path.Combine(folder, "notes.txt");
            File.WriteAllBytes(page, Data("<p>a · b</p>"));
            File.WriteAllBytes(text, Data("a · b"));
            Assert.NotNull(PageEncoding.Utf8Undeclared(page));
            Assert.Null(PageEncoding.Utf8Undeclared(text));
        }
        finally { Directory.Delete(folder, true); }
    }

    // Windows-only: WebView2 has no `load(_:characterEncodingName:baseURL:)`, so the page is drawn from a copy that
    // says so (a UTF-8 BOM, the strongest signal a browser reads) beside the file; the file itself keeps its bytes.
    [Fact]
    public void AnUndeclaredUtf8PageIsDrawnFromACopyThatSaysUtf8()
    {
        var folder = Directory.CreateTempSubdirectory("page-encoding-").FullName;
        try
        {
            var page = Path.Combine(folder, "tile.html");
            var original = Data("<p>a · b</p>");
            File.WriteAllBytes(page, original);
            var drawn = PageEncoding.DrawableFile(page);
            Assert.NotEqual(page, drawn);
            Assert.Equal(folder, Path.GetDirectoryName(drawn));   // beside it: its pictures and scripts still load
            Assert.Equal(".html", Path.GetExtension(drawn));
            Assert.Equal([0xEF, 0xBB, 0xBF, .. original], File.ReadAllBytes(drawn));
            Assert.Equal(original, File.ReadAllBytes(page));

            // Rewritten, the copy follows; declared or plain, the file is drawn as it is.
            var again = Data("<p>c · d</p>");
            File.WriteAllBytes(page, again);
            Assert.Equal([0xEF, 0xBB, 0xBF, .. again], File.ReadAllBytes(PageEncoding.DrawableFile(page)));
            File.WriteAllBytes(page, Data("<meta charset=\"utf-8\"><p>a · b</p>"));
            Assert.Equal(page, PageEncoding.DrawableFile(page));
            var plain = Path.Combine(folder, "notes.txt");
            File.WriteAllBytes(plain, Data("a · b"));
            Assert.Equal(plain, PageEncoding.DrawableFile(plain));
        }
        finally { Directory.Delete(folder, true); }
    }
}
