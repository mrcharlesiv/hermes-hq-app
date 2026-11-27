using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Insights;
using Hermes.Core.Net;

namespace Hermes.Core.Tests;

/// The Tiles page against the More pages' stand-in (windows/ci/fixtures/morepages-gateway.py over
/// pages-fixture-gateway.py): a page tile's text and head, its job found and its health read, Pause and Resume, How
/// Often and Update Now written as Hermes takes them, a picture read, a gone file's words, and the pins' sync against a
/// gateway that doesn't keep `ui_meta`. Run through windows/scripts/e2e.sh (HQW_E2E_INSIGHTS_TILES); without it these
/// pass vacuously.
[Trait("Category", "E2E")]
public class InsightsTilesEndToEndTests
{
    private const string Home = "/home/hermes";

    private static async Task Until(Func<Task<bool>> condition, int seconds = 20)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (!await condition())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException("condition not met");
            await Task.Delay(200);
        }
    }

    /// A stand-in control. The More pages' wrapper reads a `/__fixture/*` body before the pages fixture reads it again
    /// (tile-job, tile-ran), so the body is written twice on a raw socket under one Content-Length: each read gets a
    /// copy. `body` null: no body at all. Answers whether it said 200.
    private static async Task Post(string url, string path, object? body)
    {
        var uri = new Uri(url);
        var json = body == null ? "" : System.Text.Json.JsonSerializer.Serialize(body);
        var length = System.Text.Encoding.UTF8.GetByteCount(json);
        var twice = path is "/__fixture/tile-job" or "/__fixture/tile-ran" ? json + json : json;
        var request = $"POST {path} HTTP/1.1\r\nHost: {uri.Host}:{uri.Port}\r\nContent-Type: application/json\r\n"
            + $"Content-Length: {length}\r\nConnection: close\r\n\r\n{twice}";
        using var tcp = new System.Net.Sockets.TcpClient();
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        await tcp.ConnectAsync(uri.Host, uri.Port, cts.Token);
        var stream = tcp.GetStream();
        await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes(request), cts.Token);
        var reader = new StreamReader(stream);
        var status = await reader.ReadLineAsync(cts.Token) ?? "";
        Assert.Contains(" 200 ", status + " ");
    }

    private static async Task<(HermesClient Client, string Url)?> SignInAsync()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_INSIGHTS_TILES");
        if (path == null || !File.Exists(path)) return null;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        var signIn = new SignIn(new MemoryTokenStore());
        var session = await signIn.PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(30)).Token);
        return (client, url);
    }

    private static TilePin Tile(string file, string profile = "deploys") =>
        TilePin.Make(TileKind.File, $"{Home}/site/{file}", "", profile);

    [Fact]
    public async Task APageTileReadsItsPageFindsItsJobAndChangesItsUpdates()
    {
        if (await SignInAsync() is not var (client, url)) return;
        await using var owned = client;
        var session = client.Session;
        await Post(url, "/__fixture/reset", new { });   // this gateway is the Tiles tests' own (its files stay as a run left them)

        // The page and what its head says.
        var tile = Tile("tile.html");
        var html = await TileFiles.TextAsync(session, tile);
        Assert.Matches(@"Revenue \$1[24]K", html);
        Assert.Contains("Updated Tue · 1:30 PM", html);   // UTF-8 read whole
        var head = TileNames.ReadHead(html);
        Assert.Equal("Revenue This Week", head.Title);
        Assert.False(head.Live);
        var live = TileNames.ReadHead(await TileFiles.TextAsync(session, Tile("live.html")));
        Assert.True(live.Live);
        Assert.Equal(30, live.RefreshSeconds);

        // Its job: none until the fixture adds one, then found by the path in its prompt.
        var updates = new TileUpdates(session);
        await Post(url, "/__fixture/tile-job", new { status = "ok" });
        TileCronJob? job = null;
        await Until(async () =>
        {
            updates.Forget("deploys");
            (job, _) = await updates.LookupAsync(tile, TimeSpan.Zero);
            return job != null;
        });
        Assert.Equal("j-tile", job!.Id);
        Assert.Equal("hourly", TileJobs.HowOften(job));
        Assert.StartsWith("Updated 5 min ago · hourly", TileJobs.Status(job, DateTimeOffset.Now));
        var (marks, ran) = await updates.RefreshAsync([tile], DateTimeOffset.Now);
        Assert.Contains(tile.Id, marks);
        Assert.Empty(ran);
        Assert.Equal(TileJobs.HealthKind.Fine, updates.Health(tile.Id).Kind);

        // A failed last run wears the red mark, with Hermes's words.
        await Post(url, "/__fixture/tile-job", new { status = "error", error = "The model refused.\nTraceback" });
        await Until(async () =>
        {
            await updates.RefreshAsync([tile], DateTimeOffset.Now);
            return updates.Health(tile.Id).Kind == TileJobs.HealthKind.Failed;
        });
        Assert.Equal("The model refused.", updates.Health(tile.Id).Why);

        // Pause, Resume, How Often, Update Now: Hermes's own routes.
        await updates.SetPausedAsync(job, pause: true);
        await Until(async () =>
        {
            var (j, _) = await updates.LookupAsync(tile, TimeSpan.Zero);
            return j != null && TileJobs.IsPaused(j);
        });
        await updates.SetPausedAsync(job, pause: false);
        await Until(async () =>
        {
            var (j, _) = await updates.LookupAsync(tile, TimeSpan.Zero);
            return j != null && !TileJobs.IsPaused(j);
        });
        await updates.SetFrequencyAsync(job, TileJobs.Frequencies[0]);
        await Until(async () =>
        {
            var (j, _) = await updates.LookupAsync(tile, TimeSpan.Zero);
            return j != null && TileJobs.FrequencyOf(j)?.Minutes == 15;
        });
        await updates.RunNowAsync(job);

        // The job runs and rewrites the page: the next read says it ran, and the page says $14K.
        await Post(url, "/__fixture/tile-ran", null);
        await Until(async () =>
        {
            var (_, newlyRan) = await updates.RefreshAsync([tile], DateTimeOffset.Now);
            return newlyRan.Contains(tile.Id);
        });
        Assert.Contains("Revenue $14K", await TileFiles.TextAsync(session, tile));
    }

    [Fact]
    public async Task PicturesAndFilesAreReadAndAGoneFileSaysSo()
    {
        if (await SignInAsync() is not var (client, _)) return;
        await using var c = client;
        var session = client.Session;
        var png = TilePin.Make(TileKind.Image, $"{Home}/results.png", "", "default");
        var bytes = await TileFiles.ImageAsync(session, png);
        Assert.True(bytes.Length > 100);
        Assert.Equal([0x89, (byte)'P', (byte)'N', (byte)'G'], bytes.Take(4));
        var pdf = TilePin.Make(TileKind.File, $"{Home}/report.pdf", "", "default");
        Assert.Equal("%PDF"u8.ToArray(), (await TileFiles.BytesAsync(session, pdf)).Take(4));
        var md = await TileFiles.TextAsync(session, TilePin.Make(TileKind.File, $"{Home}/release-notes.md", "", "default"));
        Assert.StartsWith("# Release 2.4", md);

        var gone = TilePin.Make(TileKind.File, $"{Home}/site/not-there.html", "", "default");
        var e = await Assert.ThrowsAsync<GatewayException>(() => TileFiles.TextAsync(session, gone));
        Assert.True(TileFiles.IsMissing(e));
        Assert.Equal("This file is no longer on the computer running Hermes. It may have been moved or deleted.", TileFiles.FailureText(e, false));
        // A page tile with no job: Not Kept Updated.
        var (job, known) = await new TileUpdates(session).LookupAsync(TilePin.Make(TileKind.File, $"{Home}/index.html", "", "default"));
        Assert.True(known);
        Assert.Null(job);
    }

    [Fact]
    public async Task TheSyncReadsTheDefaultBotsRowAndAGatewayThatCantKeepItIsLeftAlone()
    {
        if (await SignInAsync() is not var (client, _)) return;
        await using var c = client;
        var store = new TilePinStore(null);
        var hidden = new TileHidden(null);
        var sync = new TileSync((m, p, t, ct) => client.Rpc.RequestAsync(m, p, t, ct), store, hidden, null);
        store.Pin(Tile("tile.html"));
        var changed = await sync.SyncAsync();
        Assert.False(changed);
        Assert.Single(store.Pins);   // this PC's tiles stay whatever the gateway answers
        // This stand-in has no profiles.configure: one try, then nothing until the next change.
        Assert.True(sync.CantWrite || sync.Writes == 1);
    }
}
