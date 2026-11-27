using Hermes.Core.Shell;
using Hermes.Core.Transcripts;
using Xunit;

namespace Hermes.Core.Tests;

// [page-cards] The page card's picture of the page (App/Chat/Viewer/PageSnapshots.swift and PageCardView.swift's picture
// handling at 93f984bb1): cache keys, generations, one draw at a time, limits, failure fallback. Synthetic paths and
// pages only; the reads and draws are stand-ins.

public class PageSnapshotsTests
{
    private static readonly PageContext Ctx = new("acct-1", "otto");
    private static readonly TimeSpan Deadline = TimeSpan.FromSeconds(10);

    private sealed record Pic(string File, bool Dark);

    private static async Task<T> Within<T>(Task<T> task) =>
        await task.WaitAsync(Deadline);

    private static Task<Pic?> Ask(PageSnapshots<Pic> s, string path, bool dark = false, PageShape? shape = null, PageContext? ctx = null)
    {
        var done = new TaskCompletionSource<Pic?>(TaskCreationOptions.RunContinuationsAsynchronously);
        s.Picture(path, PageCards.FileName(path), ctx ?? Ctx, dark, shape ?? PageShape.Phone, p => done.TrySetResult(p));
        return done.Task;
    }

    [Fact]
    public void KeyIsAccountProfilePathGenerationLook()
    {
        var s = new PageSnapshots<Pic>((_, _, _) => Task.FromResult<string?>(null), (_, _, _) => Task.FromResult<Pic?>(null));
        Assert.Equal("acct-1|otto|/home/me/site/a.html|0|l", s.Key("/home/me/site/a.html", Ctx, dark: false));
        Assert.Equal("acct-1|otto|/home/me/site/a.html|0|d", s.Key("/home/me/site/a.html", Ctx, dark: true));
        Assert.Equal("acct-1|otto|/home/me/site/a.html|0|l|box1.50", s.Key("/home/me/site/a.html", Ctx, false, PageShape.Tile(300, 200)));
        Assert.Equal("acct-1|otto|/a.html|0|d|frame160x80z130", s.Key("/a.html", Ctx, true, PageShape.FrameOf(158, 81, 1.3)));
        Assert.Equal("acct-1|otto|/a.html|0|d|frame160x80", s.Key("/a.html", Ctx, true, PageShape.FrameOf(158, 81)));
    }

    [Fact]
    public void ShapesMatchTheMacs()
    {
        Assert.Equal((390d, 844d), PageShape.Phone.Size);
        Assert.Equal("phone", PageShape.Phone.Key);
        Assert.Equal(PageShape.Box(1), PageShape.Tile(0, 10));
        Assert.Equal(PageShape.Box(3), PageShape.Tile(1000, 10));          // kept to 3
        Assert.Equal(PageShape.Box(0.4), PageShape.Tile(10, 1000));        // kept to 0.4
        Assert.Equal((390d, 260d), PageShape.Box(1.5).Size);
        Assert.Equal(PageShape.Frame(60, 1600, 50), PageShape.FrameOf(10, 5000, 0.1));   // sizes 60–1600, zoom 0.5–3
        Assert.Equal(1.3, PageShape.FrameOf(200, 200, 1.31).Zoom, 3);
        Assert.Equal(1d, PageShape.Phone.Zoom);
        Assert.Equal(390, PageSnapshotRules.DrawWidth);
        Assert.Equal(844, PageSnapshotRules.DrawHeight);
        Assert.Equal(300, PageSnapshotRules.PictureHeight);
        Assert.Equal(24, PageSnapshotRules.CountLimit);
        Assert.Equal(TimeSpan.FromMilliseconds(700), PageSnapshotRules.Settle);
        Assert.Equal(TimeSpan.FromSeconds(15), PageSnapshotRules.LoadLimit);
    }

    [Fact]
    public async Task APictureIsDrawnOnceThenServedFromTheCache()
    {
        var reads = 0;
        var draws = 0;
        var s = new PageSnapshots<Pic>((p, _, _) => { Interlocked.Increment(ref reads); return Task.FromResult<string?>("C:/cache" + p); },
            (file, dark, _) => { Interlocked.Increment(ref draws); return Task.FromResult<Pic?>(new Pic(file, dark)); });
        var first = await Within(Ask(s, "/site/a.html"));
        Assert.Equal(new Pic("C:/cache/site/a.html", false), first);
        Assert.Same(first, s.Cached("/site/a.html", Ctx, dark: false));
        var again = await Within(Ask(s, "/site/a.html"));
        Assert.Same(first, again);
        Assert.Equal((1, 1), (reads, draws));
        Assert.Null(s.Cached("/site/a.html", Ctx, dark: true));   // dark and light are pictures of their own
        var dark = await Within(Ask(s, "/site/a.html", dark: true));
        Assert.True(dark!.Dark);
        Assert.Equal((2, 2), (reads, draws));
    }

    [Fact]
    public async Task AskersOfOnePageWhileItDrawsShareOneDraw()
    {
        var gate = new TaskCompletionSource<Pic?>(TaskCreationOptions.RunContinuationsAsynchronously);
        var draws = 0;
        var s = new PageSnapshots<Pic>((p, _, _) => Task.FromResult<string?>(p), (_, _, _) => { Interlocked.Increment(ref draws); return gate.Task; });
        var a = Ask(s, "/a.html");
        var b = Ask(s, "/a.html");
        await WaitUntil(() => draws == 1);
        Assert.True(s.IsBusy);
        var pic = new Pic("/a.html", false);
        gate.SetResult(pic);
        Assert.Same(pic, await Within(a));
        Assert.Same(pic, await Within(b));
        Assert.Equal(1, draws);
        await WaitUntil(() => !s.IsBusy);
    }

    [Fact]
    public async Task OnePageDrawsAtATimeAndReadsGoSideBySide()
    {
        var reading = 0;
        var readGate = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var drawing = 0;
        var most = 0;
        var gates = new Dictionary<string, TaskCompletionSource<Pic?>>();
        var s = new PageSnapshots<Pic>(async (p, _, _) =>
            {
                Interlocked.Increment(ref reading);
                await readGate.Task;
                return p;
            },
            (file, _, _) =>
            {
                var now = Interlocked.Increment(ref drawing);
                lock (gates)
                {
                    most = Math.Max(most, now);
                    gates[file] = new TaskCompletionSource<Pic?>(TaskCreationOptions.RunContinuationsAsynchronously);
                    return gates[file].Task;
                }
            });
        var a = Ask(s, "/a.html");
        var b = Ask(s, "/b.html");
        var c = Ask(s, "/c.html");
        await WaitUntil(() => reading == 3);   // all three read at once, before any draws
        readGate.SetResult(true);
        foreach (var name in new[] { "/a.html", "/b.html", "/c.html" })
        {
            await WaitUntil(() => { lock (gates) return gates.Count(g => !g.Value.Task.IsCompleted) == 1; });
            Assert.Equal(1, most);
            TaskCompletionSource<Pic?> open;
            lock (gates) open = gates.Values.Single(g => !g.Task.IsCompleted);
            Interlocked.Decrement(ref drawing);
            open.SetResult(new Pic(name, false));
            if (name == "/c.html") break;
        }
        await Within(Task.WhenAll(a, b, c));
        Assert.Equal(1, most);
        Assert.Equal(3, gates.Count);
    }

    [Fact]
    public async Task AFailedReadOrDrawAnswersNothingAndIsNotKept()
    {
        var readOk = false;
        var drawOk = false;
        var reads = 0;
        var s = new PageSnapshots<Pic>((p, _, _) => { reads++; return Task.FromResult(readOk ? p : null); },
            (f, d, _) => Task.FromResult(drawOk ? new Pic(f, d) : null));
        Assert.Null(await Within(Ask(s, "/a.html")));      // not read: nothing to draw
        Assert.Null(s.Cached("/a.html", Ctx, false));
        readOk = true;
        Assert.Null(await Within(Ask(s, "/a.html")));      // read, not drawable
        Assert.Null(s.Cached("/a.html", Ctx, false));
        drawOk = true;
        Assert.NotNull(await Within(Ask(s, "/a.html")));   // asked again: read and drawn again
        Assert.Equal(3, reads);
    }

    [Fact]
    public async Task AThrowingDrawIsAFailureAndTheLineKeepsMoving()
    {
        var s = new PageSnapshots<Pic>((p, _, _) => Task.FromResult<string?>(p),
            (f, d, _) => f == "/bad.html" ? throw new InvalidOperationException("synthetic") : Task.FromResult<Pic?>(new Pic(f, d)));
        Assert.Null(await Within(Ask(s, "/bad.html")));
        Assert.NotNull(await Within(Ask(s, "/good.html")));
    }

    [Fact]
    public async Task ATurnEndingStartsANewGenerationForThatChatAlone()
    {
        var draws = 0;
        var s = new PageSnapshots<Pic>((p, _, _) => Task.FromResult<string?>(p), (f, d, _) => { draws++; return Task.FromResult<Pic?>(new Pic(f, d)); });
        var other = new PageContext("acct-1", "herald");
        await Within(Ask(s, "/a.html"));
        await Within(Ask(s, "/a.html", ctx: other));
        PageContext? told = null;
        s.TurnEnded += c => told = c;
        s.NoteTurnEnded(Ctx);
        Assert.Equal(Ctx, told);
        Assert.Equal(1, s.Generation(Ctx));
        Assert.Equal(0, s.Generation(other));
        Assert.Equal("acct-1|otto|/a.html|1|l", s.Key("/a.html", Ctx, false));
        Assert.Null(s.Cached("/a.html", Ctx, false));          // the old picture is not this generation's
        Assert.NotNull(s.Cached("/a.html", other, false));     // another chat's stays
        await Within(Ask(s, "/a.html"));
        Assert.Equal(3, draws);
        s.Freshen(Ctx);   // told to nobody
        Assert.Equal(2, s.Generation(Ctx));
        Assert.Equal(Ctx, told);
    }

    [Fact]
    public async Task AtMost24PicturesAreKeptTheOldestUnusedGoingFirst()
    {
        var s = new PageSnapshots<Pic>((p, _, _) => Task.FromResult<string?>(p), (f, d, _) => Task.FromResult<Pic?>(new Pic(f, d)));
        for (var i = 0; i < 24; i++) await Within(Ask(s, $"/p{i}.html"));
        Assert.NotNull(s.Cached("/p0.html", Ctx, false));   // used: p1 is now the oldest
        await Within(Ask(s, "/p24.html"));
        Assert.Equal(24, s.Count);
        Assert.NotNull(s.Cached("/p0.html", Ctx, false));
        Assert.Null(s.Cached("/p1.html", Ctx, false));
        Assert.NotNull(s.Cached("/p24.html", Ctx, false));
    }

    [Fact]
    public async Task TheReadLearnsThePagesTitleOnce()
    {
        var dir = Directory.CreateTempSubdirectory("hq-page-pictures-");
        try
        {
            var file = Path.Combine(dir.FullName, "chart.html");
            await File.WriteAllTextAsync(file, "<!doctype html><title>Replies per 100 follow-ups</title><p>synthetic</p>");
            var s = new PageSnapshots<Pic>((_, _, _) => Task.FromResult<string?>(file), (f, d, _) => Task.FromResult<Pic?>(new Pic(f, d)));
            var learnt = 0;
            s.HeadLearnt += () => learnt++;
            Assert.Null(s.Head("/site/chart.html", Ctx));
            await Within(Ask(s, "/site/chart.html"));
            Assert.Equal("Replies per 100 follow-ups", s.Head("/site/chart.html", Ctx)?.Title);
            Assert.Equal(1, learnt);
            await Within(Ask(s, "/site/chart.html", dark: true));   // read again, same title: nobody told
            Assert.Equal(1, learnt);
        }
        finally { dir.Delete(recursive: true); }
    }

    [Fact]
    public void TheCaptureRectFollowsTheProbe()
    {
        // A chart found at (12, 40), 300×200, on a page laid out 390 wide, in a 390-wide view.
        Assert.Equal(new PageRect(12, 40, 300, 200), PageSnapshotRules.CaptureRect([390, 12, 40, 300, 200], 390));
        // Kept to twice the picture's height, and to the view's width.
        Assert.Equal(new PageRect(100, 0, 290, 600), PageSnapshotRules.CaptureRect([390, 100, 0, 380, 900], 390));
        // Page pixels to view points: a page laid out 780 wide in a 390 view halves.
        Assert.Equal(new PageRect(5, 10, 100, 50), PageSnapshotRules.CaptureRect([780, 10, 20, 200, 100], 390));
        Assert.Null(PageSnapshotRules.CaptureRect([0, 1, 2, 3, 4], 390));
        Assert.Null(PageSnapshotRules.CaptureRect([390, 1, 2], 390));
        Assert.Contains("querySelectorAll('svg,canvas,img,table')", PageSnapshotRules.ProbeScript);
        Assert.Contains("Math.min(h,260)", PageSnapshotRules.ProbeScript);
        Assert.DoesNotContain("\n", PageSnapshotRules.ProbeScript);
        Assert.StartsWith("(function(){var d=document.documentElement;return d.scrollHeight<=", PageSnapshotRules.FitsScript);
    }

    [Fact]
    public void ThePicturesCornerIsThePagesColour()
    {
        var px = new byte[4 * 2 * 2];
        for (var i = 0; i < 4; i++) { px[i * 4] = 0x30; px[i * 4 + 1] = 0x20; px[i * 4 + 2] = 0x10; px[i * 4 + 3] = 255; }
        Assert.Equal(((byte)0x10, (byte)0x20, (byte)0x30), new PagePixels(2, 2, px).CornerColor());
        px[3] = 100;   // see-through: no page colour
        Assert.Null(new PagePixels(2, 2, px).CornerColor());
        Assert.Null(new PagePixels(0, 0, []).CornerColor());
    }

    [Fact]
    public void ACardPicturesNothingWhileItsReplyIsBuilding()
    {
        Assert.Equal(PageCardPictureStep.Wait, PageCardPictures.Begin(building: true, hasPicture: false, cached: false));
        Assert.Equal(PageCardPictureStep.Load, PageCardPictures.Begin(building: true, hasPicture: true, cached: false));
        Assert.Equal(PageCardPictureStep.ShowCached, PageCardPictures.Begin(building: false, hasPicture: false, cached: true));
        Assert.Equal(PageCardPictureStep.Load, PageCardPictures.Begin(building: false, hasPicture: false, cached: false));
    }

    [Fact]
    public void AnArrivingPictureShowsOnlyIfStillWanted()
    {
        Assert.Equal(PageCardArrival.Ignore, PageCardPictures.Arrived(stillWanted: false, got: true, hadPicture: false));
        Assert.Equal(PageCardArrival.Show, PageCardPictures.Arrived(stillWanted: true, got: true, hadPicture: true));
        Assert.Equal(PageCardArrival.Failed, PageCardPictures.Arrived(stillWanted: true, got: false, hadPicture: false));
        Assert.Equal(PageCardArrival.KeepOld, PageCardPictures.Arrived(stillWanted: true, got: false, hadPicture: true));
    }

    [Fact]
    public void ATurnEndsOnceAfterTheChatRan()
    {
        var edge = new PageTurnEdge();
        Assert.False(edge.Ended());          // idle news with no turn run: nothing changed
        edge.Saw(busy: false);
        Assert.False(edge.Ended());
        edge.Saw(busy: true);
        edge.Saw(busy: false);
        Assert.True(edge.Ended());
        Assert.False(edge.Ended());          // message.complete then session.info idle: one turn
    }

    private static async Task WaitUntil(Func<bool> ok)
    {
        var until = DateTime.UtcNow + Deadline;
        while (!ok())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException("condition not met in 10 s");
            await Task.Delay(10);
        }
    }
}

public class PageCardPictureWalkProofTests
{
    private static PagePixels Flat(int w, int h, byte v)
    {
        var px = new byte[w * h * 4];
        for (var i = 0; i < w * h; i++) { px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v; px[i * 4 + 3] = 255; }
        return new PagePixels(w, h, px);
    }

    [Fact]
    public void APictureMustHaveArrivedWithoutTheCardGrowing()
    {
        var varied = Flat(40, 30, 255);
        for (var x = 5; x < 35; x++) for (var y = 10; y < 14; y++) { var i = (y * 40 + x) * 4; varied.Bgra[i] = varied.Bgra[i + 1] = varied.Bgra[i + 2] = 20; }
        Assert.Null(PageCardsWalkProof.Pictured(varied, TimeSpan.FromSeconds(3), heightBefore: 316, heightAfter: 316, fullHeight: 316));
        Assert.Contains("no picture", PageCardsWalkProof.Pictured(null, TimeSpan.FromSeconds(3), 316, 316, 316));
        Assert.Contains("one colour", PageCardsWalkProof.Pictured(Flat(40, 30, 255), TimeSpan.FromSeconds(3), 316, 316, 316));
        Assert.Contains("tall", PageCardsWalkProof.Pictured(varied, TimeSpan.FromSeconds(3), 316, 330, 316));
        Assert.Contains("tall", PageCardsWalkProof.Pictured(varied, TimeSpan.FromSeconds(3), 300, 300, 316));
        Assert.Contains("took", PageCardsWalkProof.Pictured(varied, PageCardsWalkProof.PictureWait + TimeSpan.FromSeconds(1), 316, 316, 316));
        Assert.True(PageCardsWalkProof.PictureWait >= TimeSpan.FromSeconds(10));
    }

    [Fact]
    public void TheCardSaysBuildingPageUntilItsPictureLands()
    {
        Assert.Equal("Building page…", PageCards.Face("index.html", null, folded: false, building: true, pictured: false).Hint);
        Assert.Equal("Interactive page", PageCards.Face("index.html", null, folded: false, building: true, pictured: true).Hint);
    }
}
