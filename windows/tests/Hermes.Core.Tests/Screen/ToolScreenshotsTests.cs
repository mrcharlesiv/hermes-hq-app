// [WIN-SCREEN-SHOT-FEED] Ports of the web's `tool-screenshots.test.ts` and the screenshot cases of `image-zoom.test.ts`
// (docs/spec/3x-screen.md §5.3): the Mac's Tests/Screen/ToolScreenshotsTests.swift at 93f984bb1, case for case. Not
// ported: `theTranscriptCacheKeepsThePathAndTheExpiredMarkButNeverAnInlinePicture`, which tests the Mac's
// TranscriptEntry/ToolDetail cache encoding; Windows has no ToolDetail or TranscriptEntry yet (its transcript cache is
// a separate slice), so there is nothing here for it to run against.

using System.Text.Json.Nodes;
using Hermes.Core.Screen;

namespace Hermes.Core.Tests.Screen;

public sealed class ToolScreenshotsTests
{
    private const string Folder = "/h/.hermes/cache/images";

    private static JsonNode? N(string json) => JsonNode.Parse(json);
    private static JsonNode S(string text) => JsonValue.Create(text);

    /// The Swift `ListCounter` actor.
    private sealed class ListCounter(IReadOnlySet<string>? answer)
    {
        private readonly object _gate = new();
        private int _hits;
        private IReadOnlySet<string>? _answer = answer;
        public int Hits { get { lock (_gate) return _hits; } }
        public IReadOnlySet<string>? List() { lock (_gate) { _hits += 1; return _answer; } }
        public void Set(IReadOnlySet<string>? next) { lock (_gate) _answer = next; }
    }

    private static HashSet<string> Names(params string[] names) => new(names, StringComparer.Ordinal);

    [Fact]
    public void ReadsTheSavedPathOfScreenToolsOnly()
    {
        var text = $"capture mode=som 1920x1080\n  (shareable screenshot saved to {Folder}/computer_use_1.png)";
        Assert.Equal($"{Folder}/computer_use_1.png", ToolScreenshots.Restored("computer_use", S(text)));
        Assert.Equal($"{Folder}/b.png", ToolScreenshots.Restored("browser_vision", S($"ok. Screenshot path: {Folder}/b.png")));
        Assert.Equal("", ToolScreenshots.Restored("terminal", S(text)));
        Assert.True(ToolScreenshots.IsScreenshotTool("computer_use"));
        Assert.True(ToolScreenshots.IsScreenshotTool("computer_use_preview"));
        Assert.True(ToolScreenshots.IsScreenshotTool("browser_click"));
        Assert.False(ToolScreenshots.IsScreenshotTool("read_file"));
        Assert.False(ToolScreenshots.IsScreenshotTool(null));
    }

    [Fact]
    public void AMultimodalResultGivesItsInlineImageThenItsPath()
    {
        var inline = N("""{"_multimodal":true,"content":[{"type":"text","text":"clicked"},{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}]}""");
        Assert.Equal("data:image/png;base64,AAAA", ToolScreenshots.MultimodalToolImage(inline));
        Assert.Equal("DATA:image/jpeg;base64,BB", ToolScreenshots.MultimodalToolImage(N("""{"content":[{"image_url":"DATA:image/jpeg;base64,BB"}]}""")));
        Assert.Equal("/Users/x/.hermes/cache/images/computer_use_1.png",
            ToolScreenshots.MultimodalToolImage(N("""{"meta":{"screenshot_path":"/Users/x/.hermes/cache/images/computer_use_1.png"}}""")));
        Assert.Equal("/h/.hermes/cache/images/computer_use_2.jpg",
            ToolScreenshots.MultimodalToolImage(N("""{"text_summary":"Clicked OK; shareable screenshot saved to /h/.hermes/cache/images/computer_use_2.jpg"}""")));
        Assert.Equal("/h/.hermes/cache/screenshots/browser_screenshot_3.png",
            ToolScreenshots.MultimodalToolImage(N("""{"output":"Screenshot path: /h/.hermes/cache/screenshots/browser_screenshot_3.png"}""")));
        Assert.Equal("", ToolScreenshots.MultimodalToolImage(N("""{"content":[{"type":"text","text":"no image"}]}""")));
        Assert.Equal("", ToolScreenshots.MultimodalToolImage(null));
        Assert.Equal("", ToolScreenshots.MultimodalToolImage(N("null")));
        Assert.Equal("", ToolScreenshots.MultimodalToolImage(JsonValue.Create(42)));
    }

    [Fact]
    public void AStoredResultIsReadAsJSONOrAsItsSummary()
    {
        var summary = "Clicked Save.\n(shareable screenshot saved to /Users/x/.hermes/profiles/ivy/cache/images/computer_use_ab12.png)";
        Assert.Equal("/Users/x/.hermes/profiles/ivy/cache/images/computer_use_ab12.png", ToolScreenshots.StoredScreenshot(S(summary)));
        var json = """{"mode":"ax","summary":"no image","screenshot_path":"/h/.hermes/cache/images/computer_use_c.png"}""";
        Assert.Equal("/h/.hermes/cache/images/computer_use_c.png", ToolScreenshots.StoredScreenshot(S(json)));
        Assert.Equal("/h/.hermes/cache/screenshots/browser_screenshot_9.png",
            ToolScreenshots.StoredScreenshot(S("Looked at the page. Screenshot path: /h/.hermes/cache/screenshots/browser_screenshot_9.png")));
        Assert.Equal("/h/c.jpg", ToolScreenshots.StoredScreenshot(N("""{"text_summary":"shareable screenshot saved to /h/c.jpg"}""")));
        Assert.Equal("", ToolScreenshots.StoredScreenshot(S("clicked element #4")));
        Assert.Equal("", ToolScreenshots.StoredScreenshot((JsonNode?)null));
        Assert.Equal("/h/x.webp", ToolScreenshots.StoredScreenshot(S("{not json screenshot saved to /h/x.webp")));
        Assert.Equal("/h/UP.JPEG", ToolScreenshots.SavedScreenshot("SCREENSHOT SAVED TO   /h/UP.JPEG now"));
        Assert.Equal("", ToolScreenshots.SavedScreenshot("screenshot saved to /h/x.gif"));
    }

    [Fact]
    public void ALiveResultPrefersItsOwnImageThenItsTextThenItsSummary()
    {
        var result = N("""{"content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}],"meta":{"screenshot_path":"/h/a.png"}}""");
        Assert.Equal("data:image/png;base64,AAAA", ToolScreenshots.LiveSource(result, "screenshot saved to /h/b.png", null));
        Assert.Equal("/h/b.png", ToolScreenshots.LiveSource(null, "screenshot saved to /h/b.png", "screenshot saved to /h/c.png"));
        Assert.Equal("/h/c.png", ToolScreenshots.LiveSource(S("nothing"), null, "screenshot saved to /h/c.png"));
        Assert.Equal("", ToolScreenshots.LiveSource(null, null, null));
    }

    [Fact]
    public void NamesAndKindsOfSources()
    {
        Assert.Equal("shot-0007.png", new ToolScreenshot("/h/.hermes/cache/shot-0007.png").FileName);
        Assert.Equal("a.png", new ToolScreenshot(@"C:\Users\x\shots\a.png").FileName);
        Assert.True(new ToolScreenshot("data:image/png;base64,AAAA").IsInline);
        Assert.False(new ToolScreenshot("/h/a.png").IsInline);
        Assert.True(ToolScreenshots.IsRemote("https://example.com/a.png"));
        Assert.True(ToolScreenshots.IsRemote("BLOB:abc"));
        Assert.False(ToolScreenshots.IsRemote("/h/a.png"));
        Assert.Equal("This screenshot has expired: the gateway keeps only its 20 most recent screenshots.\n\nClicked Save", ToolScreenshots.ExpiredOutput("Clicked Save"));
        Assert.Equal(ToolScreenshots.ExpiredNote, ToolScreenshots.ExpiredOutput(null));
    }

    [Fact]
    public void AListingAnswerIsReadAsNamesOrAsNothing()
    {
        Assert.Equal(Names("a.png", "b.png"), ToolScreenshots.NamesInListing("""{"entries":[{"name":"a.png"},{"name":"b.png"}]}"""));
        Assert.Equal(Names(), ToolScreenshots.NamesInListing("""{"entries":[]}"""));
        Assert.Null(ToolScreenshots.NamesInListing("""{"error":"No such folder","entries":[]}"""));
        Assert.Null(ToolScreenshots.NamesInListing("""{"ok":true}"""));
        Assert.Null(ToolScreenshots.NamesInListing("<html>"));
    }

    // The step's screenshot and the transcript cache

    [Fact]
    public void AStepKeepsThePathWhenTheResultCarriesBothAndTheInlinePictureOnlyWithoutOne()
    {
        var both = N("""{"content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}],"meta":{"screenshot_path":"/Users/x/.hermes/screenshots/shot-0008.png"}}""");
        Assert.Equal(new ToolScreenshot("/Users/x/.hermes/screenshots/shot-0008.png"), ToolScreenshots.StepScreenshot(both, null, null));
        var inlineOnly = N("""{"content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}]}""");
        Assert.True(ToolScreenshots.StepScreenshot(inlineOnly, null, null)?.IsInline == true);
        Assert.Equal("/h/s.png", ToolScreenshots.StepScreenshot(inlineOnly, null, "Clicked. Screenshot saved to /h/s.png")?.Source);
        var huge = new JsonObject { ["content"] = new JsonArray(new JsonObject { ["image_url"] = "data:image/png;base64," + new string('A', ToolScreenshots.MaxInlineStep) }) };
        Assert.Null(ToolScreenshots.StepScreenshot(huge, null, null));
        // A stored row: the summary text, or the JSON text of the envelope.
        Assert.Equal("/Users/x/.hermes/screenshots/shot-0007.png",
            ToolScreenshots.StepScreenshot(S("Clicked Save. Shareable screenshot saved to /Users/x/.hermes/screenshots/shot-0007.png"), null, null)?.Source);
        Assert.Equal("/h/m.png", ToolScreenshots.StepScreenshot(S("""{"summary":"ok","meta":{"screenshot_path":"/h/m.png"}}"""), null, null)?.Source);
        Assert.Null(ToolScreenshots.StepScreenshot(S("clicked element #4"), null, null));
    }

    // Expiry

    [Fact]
    public async Task APrunedCaptureIsExpiredOnceWithOneListingPerFolder()
    {
        var counter = new ListCounter(Names("computer_use_2.png"));
        var expiry = new ScreenshotExpiry(_ => Task.FromResult(counter.List()));
        const double now = 2_000_000.0;
        Assert.True(await expiry.CheckAsync("call-1", $"{Folder}/computer_use_1.png", 1_000, now));
        Assert.False(await expiry.CheckAsync("call-2", $"{Folder}/computer_use_2.png", 1_000, now));
        // Native keeps the answer (the web keeps it in the card's own state): asking again costs no listing.
        Assert.True(await expiry.CheckAsync("call-1", $"{Folder}/computer_use_1.png", 1_000, now));
        Assert.True(expiry.Settled("call-1") == true);
        Assert.True(expiry.Settled("call-2") == false);
        Assert.Null(expiry.Settled("call-3"));
        Assert.Equal(1, counter.Hits);
    }

    [Fact]
    public async Task ANewCaptureIsNeverExpiredFromAnOlderListingNorFromAnUnreadableFolder()
    {
        var first = new ListCounter(Names("computer_use_old.png"));
        var expiry = new ScreenshotExpiry(directory =>
        {
            if (directory == "/elsewhere") return Task.FromResult<IReadOnlySet<string>?>(null);
            if (directory == "/empty") return Task.FromResult<IReadOnlySet<string>?>(Names());
            return Task.FromResult(first.List());
        });
        const double now = 3_000_000.0;
        Assert.False(await expiry.CheckAsync("a", $"{Folder}/computer_use_old.png", now - 100, now));
        Assert.Equal(1, first.Hits);
        // The capture happened after that listing: the folder is listed again, and the file is there now.
        first.Set(Names("computer_use_old.png", "computer_use_new.png"));
        Assert.False(await expiry.CheckAsync("b", $"{Folder}/computer_use_new.png", (now + 5) * 1000, now + 6));
        Assert.Equal(2, first.Hits);
        Assert.False(await expiry.CheckAsync("c", "/elsewhere/computer_use_x.png", 1, now));
        Assert.False(await expiry.CheckAsync("d", "/empty/computer_use_x.png", 1, now));
        Assert.False(await expiry.CheckAsync("e", "data:image/png;base64,AAAA", 1, now));
        Assert.False(await expiry.CheckAsync(null, $"{Folder}/x.png", 1, now));
        Assert.False(await expiry.CheckAsync("f", "no-folder.png", 1, now));
        Assert.Null(expiry.Settled("c"));
        Assert.Null(expiry.Settled("d"));
        Assert.Equal(2, first.Hits);
    }

    [Fact]
    public async Task AnUnreadableListingAsksAgainLaterAndThenSettles()
    {
        var counter = new ListCounter(null);
        var expiry = new ScreenshotExpiry(_ => Task.FromResult(counter.List()));
        Assert.False(await expiry.CheckAsync("t1", $"{Folder}/gone.png", 1, 1_000));
        Assert.False(await expiry.CheckAsync("t1", $"{Folder}/gone.png", 1, 1_010));
        Assert.Equal(1, counter.Hits);                      // at most one listing per 30 s for one step
        counter.Set(Names("other.png"));
        Assert.True(await expiry.CheckAsync("t1", $"{Folder}/gone.png", 1, 1_040));
        Assert.True(await expiry.CheckAsync("t1", $"{Folder}/gone.png", 1, 1_100));
        Assert.Equal(2, counter.Hits);
    }

    [Fact]
    public async Task AListingIsReusedForAMinuteThenReadAgain()
    {
        var counter = new ListCounter(Names("a.png", "b.png", "c.png"));
        var expiry = new ScreenshotExpiry(_ => Task.FromResult(counter.List()));
        string[] names = ["a.png", "b.png", "c.png"];
        for (var index = 0; index < names.Length; index++)
            Assert.False(await expiry.CheckAsync($"s{index}", $"{Folder}/{names[index]}", 10, 5_000 + index));
        Assert.Equal(1, counter.Hits);
        Assert.False(await expiry.CheckAsync("late", $"{Folder}/a.png", 10, 5_061));
        Assert.Equal(2, counter.Hits);
    }

    /// The step carries its own capture time (the stored row's, or the live result's arrival), so a listing read
    /// before the capture is never reused for it, and one read after it costs no second request.
    [Fact]
    public async Task AStepCarriesItsCaptureTimeSoAnOlderListingIsNotReusedForIt()
    {
        var stored = ToolScreenshots.StepScreenshot(S($"screenshot saved to {Folder}/new.png"), null, null, at: 5_030);
        Assert.Equal(new ToolScreenshot($"{Folder}/new.png", CapturedAt: 5_030), stored);
        var counter = new ListCounter(Names("old.png"));
        var expiry = new ScreenshotExpiry(_ => Task.FromResult(counter.List()));
        Assert.False(await expiry.CheckAsync("old", $"{Folder}/old.png", 4_000, 5_000));
        counter.Set(Names("old.png", "new.png"));
        // Captured at 5,030: the listing of 5,000 predates it, so the folder is read again and the file is there.
        Assert.False(await expiry.CheckAsync("new", $"{Folder}/new.png", stored?.CapturedAt, 5_040));
        Assert.Equal(2, counter.Hits);
        // A step from before that listing reuses it: one request per folder per minute, however many steps are opened.
        for (var index = 0; index < 30; index++)
            _ = await expiry.CheckAsync($"gone-{index}", $"{Folder}/gone-{index}.png", 4_000, 5_041);
        Assert.Equal(2, counter.Hits);
        Assert.True(expiry.Settled("gone-7") == true);
    }

    [Fact]
    public async Task WhatItRemembersIsBounded()
    {
        var expiry = new ScreenshotExpiry(_ => Task.FromResult<IReadOnlySet<string>?>(Names("kept.png")));
        for (var index = 0; index < 2_300; index++)
            _ = await expiry.CheckAsync($"call-{index}", $"/dir-{index % 90}/kept.png", 1, 10_000 + index * 0.001);
        var held = expiry.Held;
        Assert.True(held.Listings <= 64);
        Assert.True(held.Noted <= 2_000);
        Assert.Equal(0, held.Asked);
    }

    // Beyond the Swift cases: the C# wiring the Swift gets from its client (`ScreenshotExpiry(client:profile:)`, the
    // service's `expiry`).

    private sealed class ListingRest(Func<string, string> answer) : IScreenshotRest
    {
        public List<(string Path, List<KeyValuePair<string, string>> Query)> Log { get; } = [];
        public Task<string> RestAsync(string method, string path, IReadOnlyList<KeyValuePair<string, string>> query, CancellationToken ct = default)
        {
            lock (Log) Log.Add((path, query.ToList()));
            try { return Task.FromResult(answer(query[0].Value)); }
            catch (Exception e) { return Task.FromException<string>(e); }
        }
    }

    [Fact]
    public async Task TheClientListsTheFolderByPathAndProfileAndAFailedAnswerProvesNothing()
    {
        var rest = new ListingRest(dir => dir == "/down" ? throw new IOException("offline") : """{"entries":[{"name":"kept.png"}]}""");
        var expiry = new ScreenshotExpiry(rest, "writer");
        Assert.True(await expiry.CheckAsync("a", $"{Folder}/gone.png", 1, 100));
        Assert.False(await expiry.CheckAsync("b", $"{Folder}/kept.png", 1, 100));
        Assert.False(await expiry.CheckAsync("c", "/down/x.png", 1, 100));
        Assert.Null(expiry.Settled("c"));
        Assert.Equal("/api/fs/list", rest.Log[0].Path);
        Assert.Equal([new("path", Folder), new("profile", "writer")], rest.Log[0].Query);
        Assert.Equal(2, rest.Log.Count);
        // The service's own: no profile, as the Swift `lazy var expiry` makes it.
        var unnamed = new ListingRest(_ => """{"entries":[]}""");
        _ = await new ScreenshotExpiry(unnamed, null).CheckAsync("x", $"{Folder}/x.png", 1, 100);
        Assert.Equal([new("path", Folder)], unnamed.Log.Single().Query);
    }
}
