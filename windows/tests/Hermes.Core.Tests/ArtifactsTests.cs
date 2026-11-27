using System.Text.Json.Nodes;
using Hermes.Core.Artifacts;
using Hermes.Core.Net;

namespace Hermes.Core.Tests;

/// The Artifacts core, ported from the Mac's tests (Tests/Pages/ArtifactCollectorTests.swift, ArtifactRepeatsTests.swift,
/// ArtifactLinksTests.swift, ArtifactHiddenTests.swift, PagesStoreTests.swift).
public class ArtifactCollectorTests
{
    internal static ArtifactSessionRow Session(string id = "session-1", double? lastActive = 1000, double? startedAt = 1000,
        string? cwd = null, bool cwdPresent = false) =>
        new() { Id = id, Title = "Session", MessageCount = 1, LastActive = lastActive, StartedAt = startedAt, Cwd = cwd, CwdPresent = cwdPresent };

    internal static JsonNode Assistant(string text, double? ts = 2000)
    {
        var o = new JsonObject { ["role"] = "assistant", ["content"] = text };
        if (ts != null) o["timestamp"] = ts;
        return o;
    }

    internal static JsonNode Tool(string name, JsonNode content, double ts = 1_781_774_001) =>
        new JsonObject { ["role"] = "tool", ["tool_name"] = name, ["content"] = content, ["timestamp"] = ts };

    private static JsonNode Json(JsonNode value) => JsonValue.Create(value.ToJsonString())!;

    private static List<string> Values(params JsonNode[] messages) => Values(Session(), messages);
    private static List<string> Values(ArtifactSessionRow s, params JsonNode[] messages) =>
        [.. ArtifactCollector.Collect(s, messages).Select(a => a.Value)];

    [Fact]
    public void IndexesPlainLinksAndStripsCodeDelimiters()
    {
        var a = ArtifactCollector.Collect(Session(), [Assistant("Reference: https://example.com/docs/getting-started")]);
        Assert.Single(a);
        Assert.Equal(ArtifactKind.Link, a[0].Kind);
        Assert.Equal("https://example.com/docs/getting-started", a[0].Value);
        Assert.Equal("Getting Started", a[0].Label);
        Assert.Equal(["https://voice.example.com"], Values(Assistant("Preview URL: `https://voice.example.com`")));
        Assert.Equal(["https://voice.example.com"], Values(Assistant("Deployed at `https://voice.example.com`, take a look.")));
    }

    [Fact]
    public void DoesNotIndexPassiveLinksAndPathsObservedInToolOutput()
    {
        var found = Values(Session("session-2"),
            Tool("web_search", Json(JsonNode.Parse("""{"results":[{"cache_path":"/home/example/.cache/node.v24.18.1/bin","source_url":"https://example.com/changelog/latest"}]}""")!)),
            Tool("discord_read_messages", Json(JsonNode.Parse("""{"attachments":[{"url":"https://cdn.example.com/passive/photo.png"}],"image":"https://cdn.example.com/passive/thumbnail.png"}""")!)),
            Tool("browser_snapshot", "External documentation example: MEDIA:/tmp/passive-example.png"));
        Assert.Empty(found);
    }

    [Fact]
    public void IndexesFilesFromTerminalOutput()
    {
        var found = Values(Tool("terminal", Json(new JsonObject { ["output"] = "wrote: /home/example/project/figure_variance.png and /home/example/project/report.pdf", ["exit_code"] = 0 })));
        Assert.DoesNotContain("/home/example/project/figure_variance.png", found);
        Assert.Contains("/home/example/project/report.pdf", found);
        Assert.Empty(Values(Tool("terminal", Json(new JsonObject { ["output"] = "done\nMEDIA:/tmp/plot.png", ["exit_code"] = 0 }))));
        Assert.Empty(Values(Tool("web_search", Json(new JsonObject { ["output"] = "see /tmp/generated/figure.png for details", ["query"] = "x" }))));
        Assert.Contains("/tmp/generated/results.csv", Values(Tool("terminal", Json(new JsonObject { ["path"] = "/tmp/generated/results.csv", ["exit_code"] = 0 }))));
    }

    [Fact]
    public void KeepsExplicitGeneratedArtifactsFromToolOutput()
    {
        var found = Values(Session("generated-session"),
            Tool("image_generate", Json(JsonNode.Parse("""{"image":"https://cdn.example.com/generated/cat.png","success":true}""")!), 1_781_774_001),
            Tool("document_export", Json(JsonNode.Parse("""{"output_path":"/tmp/generated/report.pdf","success":true}""")!), 1_781_774_002),
            Tool("write_file", Json(JsonNode.Parse("""{"files_modified":["/tmp/generated/notes.md"],"success":true}""")!), 1_781_774_003),
            Tool("data_export", Json(JsonNode.Parse("""{"artifacts":[{"url":"https://cdn.example.com/generated/data.csv"}]}""")!), 1_781_774_004),
            Tool("text_to_speech", Json(JsonNode.Parse("""{"file_path":"`/tmp/generated/transcript.md`","media_tag":"MEDIA:/tmp/generated/voice.ogg","success":true}""")!), 1_781_774_005));
        Assert.Equal(new HashSet<string> { "https://cdn.example.com/generated/cat.png", "/tmp/generated/report.pdf", "/tmp/generated/notes.md",
            "https://cdn.example.com/generated/data.csv", "/tmp/generated/voice.ogg", "/tmp/generated/transcript.md" }, found.ToHashSet());
        Assert.Equal(["https://cdn.example.com/generated/cat.png", "/tmp/generated/report.pdf", "/tmp/generated/notes.md",
            "https://cdn.example.com/generated/data.csv"], found.Take(4));
    }

    [Fact]
    public void TerminalOutputNamesNoWebPicturesOrPages()
    {
        var html = """<a href="http://www.example.org/"><img src="https://cdn.zapier.com/storage/photos/dafbfb5948ef.png"></a>"""
            + """ <img src="//cdn.example.com/social/in.png"> ![x](https://example.com/logo.jpg) see https://example.com/about""";
        var found = Values(Tool("terminal", Json(new JsonObject { ["output"] = html + "\nSaved /tmp/out/chart.pdf\nGet https://example.com/dl/tool-1.0.zip", ["exit_code"] = 0 })));
        Assert.Equal(["/tmp/out/chart.pdf"], found);
        Assert.Empty(Values(Tool("terminal", Json(new JsonObject { ["output"] = "MEDIA:https://example.com/made.png" }))));
        Assert.Equal(["https://example.com/made.png"], Values(Assistant("Here it is: https://example.com/made.png")));
    }

    [Fact]
    public void JunkLinksAreDroppedFromTheBotsOwnWordsToo()
    {
        Assert.Empty(Values(Assistant("Their profile is https://www.instagram.com/somebrand/ and you can opt out at https://somebrand.com/unsubscribe?id=9.")));
        Assert.Equal(["https://github.com/example/tool/pull/42", "https://developer.apple.com/documentation/swiftui/list"],
            Values(Assistant("The fix is in https://github.com/example/tool/pull/42 — see https://developer.apple.com/documentation/swiftui/list.")));
    }

    [Fact]
    public void ABotsOwnScreenshotsAndStateFilesStayOutUnlessSent()
    {
        var shot = "/Users/me/.hermes/profiles/app/cache/images/computer_use_f8a336f4e74048bc.png";
        Assert.Empty(Values(Tool("computer_use", Json(new JsonObject { ["screenshot_path"] = shot }))));
        Assert.Empty(Values(Assistant($"I looked at {shot}.")));
        Assert.Equal([shot], Values(Assistant($"Here's the screen:\nMEDIA:{shot}")));
        var saved = "/Users/me/.hermes/profiles/mail/state/attachments/gmail_1a13_cz2s/part-5.png";
        Assert.Empty(Values(Assistant($"Saved the evidence to {saved}")));
        Assert.Equal([saved], Values(Assistant($"Here it is:\nMEDIA:{saved}")));
        Assert.True(ArtifactCollector.IsBotStateFile("~/.hermes/profiles/inbox/inbox_state/x/part-4.png"));
        Assert.False(ArtifactCollector.IsBotStateFile("https://example.com/.hermes/inbox_state/a.png"));
    }

    [Fact]
    public void ProtocolRelativeAndEscapedAddressesAreNotPaths()
    {
        Assert.Empty(Values(Assistant("Icon: //cdn.weather.example/icons/sunny.png and ![w](//ssl.gstatic.com/w/rain.png)")));
        Assert.True(ArtifactCollector.IsSchemelessWebAddress(@"\\/\\/cdn.example.com\\/a.png"));
        Assert.True(ArtifactCollector.IsSchemelessWebAddress(@"\/\/cdn.example.com\/a.png"));
        Assert.False(ArtifactCollector.IsSchemelessWebAddress(@"\\server\share\chart.png"));
        Assert.Equal([@"\\server\share\chart.png"], Values(Assistant(@"Saved \\server\share\chart.png")));
        Assert.Equal(["/tmp/out/chart.png"], Values(Assistant("Done: /tmp/out/chart.png //cdn.example.com/icons/sun.png")));
    }

    [Fact]
    public void WebIconsAndSavedEmailPartsStayOut()
    {
        var reply = "Built the site. ![](https://cdn.weatherapi.com/weather/64x64/day/113.png) ![](https://openweathermap.org/img/wn/10d@2x.png)\n"
            + "Icons: /Users/me/site/public/favicon.svg /Users/me/site/public/apple-touch-icon-180x180.png\n"
            + "https://example.com/favicon-32x32.png https://cdn.worldweatheronline.com/images/wsymbols01_png_64/wsymbol_0001_sunny.png\n"
            + "Hero: /Users/me/site/public/hero.png";
        Assert.Equal(["/Users/me/site/public/hero.png"], Values(Assistant(reply)));
        Assert.True(ArtifactCollector.IsSavedEmailPart("/opt/data/profiles/mail/state/attachments/gmail_1a13_cz2s/part-5.png"));
        Assert.True(ArtifactCollector.IsSavedEmailPart("/Users/me/Downloads/message/image001.png"));
        Assert.False(ArtifactCollector.IsSavedEmailPart("/Users/me/out/report-part-2.png"));
    }

    [Fact]
    public void CompactionSummariesAndFailedToolsMakeNothing()
    {
        Assert.Empty(Values(Assistant("[CONTEXT COMPACTION — REFERENCE ONLY] Earlier.\nMEDIA:/Users/me/out/old.png"),
            Assistant("[CONTEXT SUMMARY]: wrote /tmp/a.png")));
        var marked = Assistant("Earlier: saved /tmp/out/b.png");
        marked["_compressed_summary"] = true;
        Assert.Empty(Values(marked));
        Assert.Equal(["/tmp/out/c.png"], Values(Assistant("After the context compaction I saved /tmp/out/c.png")));
        Assert.Empty(Values(Tool("image_generate", """{"success": false, "image": null, "error": "x /Users/me/a/wing.png"}""")));
    }

    [Fact]
    public void TheJunkTable()
    {
        Assert.False(ArtifactCollector.IsJunk("https://www.facebook.com/adsmanager/manage/ads?act=1&selected_ad_ids=2"));
        foreach (var junk in new[] { "https://instagram.com", "https://www.tiktok.com/@brand", "https://www.facebook.com/sharer/sharer.php?u=x",
                     "https://twitter.com/intent/tweet?text=hi", "https://youtube.com", "https://brand.us1.list-manage.com/track/click?u=1",
                     "https://ct.sendgrid.net/ls/click?upn=x", "https://ci4.googleusercontent.com/proxy/abc=s0",
                     "https://example.com/manage-subscription?id=1", "https://brand.com/e/o/pixel.gif", "https://brand.com/img/1x1.gif" })
            Assert.True(ArtifactCollector.IsJunk(junk), junk);
        foreach (var real in new[] { "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "https://x.com/someone/status/1234567890",
                     "https://www.instagram.com/p/Cxyz123/", "https://github.com/example/tool", "https://lh3.googleusercontent.com/a/photo.png",
                     "/tmp/unsubscribe.txt", "/Users/x/out/pixel.png" })
            Assert.False(ArtifactCollector.IsJunk(real), real);
    }

    [Fact]
    public void DoesNotIndexPipDownloads()
    {
        var mirror = "https://mirror.example.com/pypi/packages/7a/1b/0f3c";
        var output = string.Join("\n", $"  Downloading {mirror}/anthropic-0.46.0-py3-none-any.whl (223 kB)",
            @"  Saved C:\Users\Alice\AppData\Local\pip\Cache\http-v2\a\b\docstring_parser-0.16.tar.gz",
            "Wrote /home/example/project/report.pdf; upstream release: https://github.com/example/tool/archive/refs/tags/v1.0.tar.gz");
        Assert.Equal(["/home/example/project/report.pdf"], Values(Session("pip"), Tool("terminal", Json(new JsonObject { ["output"] = output }))));
    }

    [Fact]
    public void ProseRulesAndExplicitMedia()
    {
        Assert.Empty(Values(Assistant("Runtime discovered at /home/example/.cache/node.v24.18.1/bin")));
        Assert.Equal(["/tmp/generated/report.pdf", @"C:\Temp\generated-report.pdf"],
            Values(Assistant("Created: /tmp/generated/report.pdf", 1), Assistant(@"Created: C:\Temp\generated-report.pdf", 2)));
        Assert.Empty(Values(Assistant("State lives in /tmp/plumbing/state-dir and /tmp/notes.bin")));
        Assert.Equal(["/tmp/generated/demo.mp4", "/tmp/generated/demo clip.mp4", "/tmp/generated/quoted.mp4"],
            Values(Assistant("Finished rendering. **MEDIA: /tmp/generated/demo.mp4**", 1),
                Assistant("Second render. MEDIA: \"/tmp/generated/demo clip.mp4\"", 2),
                Assistant("Third render. \"MEDIA:/tmp/generated/quoted.mp4\"", 3)));
        var office = ArtifactCollector.Collect(Session("office"), [Assistant(@"Workbook ready. MEDIA:C:\Users\Example\Documents\report.xlsx", 1),
            Assistant("Notes compiled. MEDIA:\"/tmp/generated/contract draft.docx\"", 3)]);
        Assert.All(office, a => Assert.Equal(ArtifactKind.File, a.Kind));
        Assert.Equal([@"C:\Users\Example\Documents\report.xlsx", "/tmp/generated/contract draft.docx"], office.Select(a => a.Value));
    }

    [Fact]
    public void NormalizesTimestamps()
    {
        var a = ArtifactCollector.Collect(Session(), [Assistant("Created: /tmp/generated/report.pdf", 1_781_773_226.453548)]);
        Assert.True(Math.Abs(a[0].Timestamp - 1_781_773_226_453.548) < 0.01);
        var fromSession = ArtifactCollector.Collect(Session(lastActive: 1_781_774_001), [Assistant("Created: /tmp/generated/x.pdf", null)]);
        Assert.Equal(1_781_774_001_000, fromSession[0].Timestamp);
        var fromNow = ArtifactCollector.Collect(Session("now", 0, 0), [Assistant("Created: /tmp/generated/n.pdf", null)], 1_781_774_001_594);
        Assert.Equal(1_781_774_001_594, fromNow[0].Timestamp);
    }

    [Fact]
    public void CollectsMediaHrefsAndPreviewDirectives()
    {
        var a = ArtifactCollector.Collect(Session(), [Assistant("[Image: report](#media:C%3A%5CUsers%5CMorten%5CMy%20Report.png)")]);
        Assert.Equal(ArtifactKind.Image, Assert.Single(a).Kind);
        Assert.Equal(@"C:\Users\Morten\My Report.png", a[0].Value);
        var b = ArtifactCollector.Collect(Session(), [Assistant("[Audio: clip](#media:%2Ftmp%2Fgenerated%2Fmy%20clip.mp3)")]);
        Assert.Equal("/tmp/generated/my clip.mp3", Assert.Single(b).Value);
        Assert.Equal(["/home/hermes/site/page.html"], Values(Assistant("Here:\n::preview{file=\"/home/hermes/site/page.html\"}")));
    }

    [Fact]
    public void Candidates()
    {
        Assert.Equal(["https://shop.example.com/cdn/shop/files/03_a.png"], ArtifactCollector.ArtifactCandidates("//shop.example.com/cdn/shop/files/03_a.png", Session()));
        Assert.Equal("//Users/me/a.png", ArtifactCollector.HostedArtifactUrl("//Users/me/a.png"));
        Assert.Equal(["/tmp/a.png", "/tmp/b.png"], ArtifactCollector.SplitArtifactValue("/tmp/a.png\n/tmp/b.png\r\n"));
        Assert.Equal(["/tmp/a.png", "/tmp/b.png"], ArtifactCollector.SplitArtifactValue(@"/tmp/a.png\t/tmp/b.png"));
        Assert.Equal(["/Users/me/My Report.pdf"], ArtifactCollector.SplitArtifactValue("/Users/me/My Report.pdf"));
        Assert.Equal([@"C:\new\x.png"], ArtifactCollector.SplitArtifactValue(@"C:\new\x.png"));
        var none = Session(cwd: "", cwdPresent: true);
        Assert.Empty(ArtifactCollector.ArtifactCandidates("./out/a.png", none));
        Assert.Equal(["../artifacts/a.png"], ArtifactCollector.ArtifactCandidates("../artifacts/a.png", Session(cwd: "/Users/me/repo", cwdPresent: true)));
        foreach (var v in new[] { "/tmp/a.png", "~/a.png", "https://x.example/a.png", "file:///tmp/a.png" })
            Assert.Equal([v], ArtifactCollector.ArtifactCandidates(v, none));
        Assert.True(ArtifactCollector.RelativeArtifactPath("a.png"));
        Assert.False(ArtifactCollector.RelativeArtifactPath(@"D:\a.png"));
        Assert.False(ArtifactCollector.RelativeArtifactPath("sandbox:/mnt/a.png"));
    }

    [Fact]
    public void CutOffUrls()
    {
        Assert.True(ArtifactCollector.UrlCutOff("https://example.co…"));
        Assert.True(ArtifactCollector.UrlCutOff("https://example.zz"));
        Assert.True(ArtifactCollector.UrlCutOff("https://example.co..."));
        Assert.False(ArtifactCollector.UrlCutOff("https://example.org/papers/open-planning"));
        Assert.False(ArtifactCollector.UrlCutOff("https://github.com/a/b/compare/main...feature"));
        Assert.False(ArtifactCollector.UrlCutOff("http://127.0.0.1:9119/x"));
        Assert.Equal("CHANGELOG.md", ArtifactCollector.UrlFileLabel("https://example.com/a/CHANGELOG.md"));
    }

    /// §9.3's transcript table, end to end through the collector (the stand-in gateway's chats).
    [Fact]
    public void TheFixtureTranscriptsIndexToExactlyTheirRecords()
    {
        var s = Session("s-research", cwd: "/home/hermes/app", cwdPresent: true);
        var found = Values(s,
            Assistant("I put a one-page summary in /home/hermes/reading/summary.md and the chart in /home/hermes/reading/results.png. Sources: https://example.org/papers/open-planning and https://example.org/papers/long-memory"),
            Assistant("MEDIA:/home/hermes/out/report.pdf"),
            Assistant("Open [the page](#media:%2Fhome%2Fhermes%2Fsite%2Findex.html)"),
            Tool("write_file", Json(new JsonObject { ["path"] = "/home/hermes/app/release-notes.md" })),
            Tool("terminal", Json(new JsonObject { ["output"] = "Saved /home/hermes/data/export.csv\nDownloading https://files.pythonhosted.org/packages/x/y/pkg-1.0-py3-none-any.whl" })),
            Tool("read_file", Json(new JsonObject { ["path"] = "/home/hermes/app/CHANGELOG.md" })),
            Assistant("see https://example.co…"),
            Assistant("/home/hermes/gone/old.png"),
            Assistant("/home/hermes/big/log.txt"),
            Assistant("MEDIA:/home/hermes/app/Sources/App.swift"));
        Assert.DoesNotContain("/home/hermes/app/Sources/App.swift", Values(Assistant("/home/hermes/app/Sources/App.swift")));
        Assert.Equal(new HashSet<string> { "/home/hermes/reading/summary.md", "/home/hermes/reading/results.png", "https://example.org/papers/open-planning",
            "https://example.org/papers/long-memory", "/home/hermes/out/report.pdf", "/home/hermes/site/index.html",
            "/home/hermes/app/release-notes.md", "/home/hermes/data/export.csv", "/home/hermes/gone/old.png",
            "/home/hermes/big/log.txt", "/home/hermes/app/Sources/App.swift" }, found.ToHashSet());
        Assert.Empty(Values(Session("s-cron", cwd: "", cwdPresent: true), Assistant("wrote ./out/summary.md")));
    }

    [Fact]
    public async Task ReadsPagesOldestFirstAndKeepsTheFirstDuplicate()
    {
        var duplicate = "https://example.com/shared.pdf";
        var offsets = new List<int>();
        var found = await ArtifactCollector.LoadSessionAsync(Session(), (_, limit, offset, _) =>
        {
            lock (offsets) offsets.Add(offset);
            var messages = offset == 0
                ? new JsonArray(Assistant(duplicate, 1000), Assistant("https://example.com/first.png", 1500))
                : new JsonArray(Assistant($"{duplicate} https://example.com/last.pdf", 3000));
            return Task.FromResult(new JsonObject { ["messages"] = messages, ["pagination"] = new JsonObject { ["limit"] = 2, ["offset"] = offset } }.ToJsonString());
        }, maxPageJsonChars: 10_000);
        Assert.Equal([0, 2], offsets);
        Assert.Equal([duplicate, "https://example.com/first.png", "https://example.com/last.pdf"], found.Select(a => a.Value));
        Assert.Equal(1_000_000, found.First(a => a.Value == duplicate).Timestamp);
        await Assert.ThrowsAsync<ArtifactSafeLoadException>(() => ArtifactCollector.LoadSessionAsync(Session(), (_, _, _, _) =>
            Task.FromResult(new JsonObject { ["messages"] = new JsonArray(Assistant(new string('x', 500))) }.ToJsonString()), maxPageJsonChars: 200));
    }
}

public class ArtifactRepeatsTests
{
    private static JsonNode Said(string text) => ArtifactCollectorTests.Assistant(text);

    [Fact]
    public void AChatNamingAFileThreeTimesIsOneRowCountingThree()
    {
        var found = ArtifactCollector.Collect(ArtifactCollectorTests.Session("s1"), [
            Said("Wrote /tmp/notes/plan.md and see https://example.com/a"), Said("Updated /tmp/notes/plan.md. Again https://example.com/a"),
            Said("Final: /tmp/notes/plan.md"),
        ]);
        var plan = Assert.Single(found, a => a.Value == "/tmp/notes/plan.md");
        Assert.Equal(3, plan.Repeats);
        Assert.Equal("×3", plan.RepeatBadge);
        Assert.Equal("Mentioned 3 times", plan.RepeatSpoken);
        Assert.Equal(2, Assert.Single(found, a => a.Value == "https://example.com/a").Repeats);
    }

    [Fact]
    public void OnceHasNoBadgeAndAnImageNeverHasOne()
    {
        var found = ArtifactCollector.Collect(ArtifactCollectorTests.Session(), [Said("Wrote /tmp/a.md. MEDIA:/tmp/chart.png"), Said("MEDIA:/tmp/chart.png")]);
        Assert.Null(found.First(a => a.Value == "/tmp/a.md").RepeatBadge);
        Assert.Null(found.First(a => a.Kind == ArtifactKind.Image).RepeatBadge);
    }

    [Fact]
    public void AnotherChatJoinsTheRowForAFullPathAndARereadDoesNotDouble()
    {
        var a = ArtifactCollector.Collect(ArtifactCollectorTests.Session("a"), [Said("/tmp/plan.md"), Said("/tmp/plan.md")]);
        var b = ArtifactCollector.Collect(ArtifactCollectorTests.Session("b"), [Said("/tmp/plan.md")]);
        Assert.Equal(3, Assert.Single(ArtifactCollector.Unique([.. a, .. b])).Repeats);
        Assert.Equal(3, ArtifactCollector.Unique([.. a, .. b, .. a])[0].Repeats);
        Assert.Equal(2, Assert.Single(ArtifactCollector.Unique([.. a, .. a])).Repeats);
    }

    [Fact]
    public void AnIndexKeptByAnOlderBuildReadsAsOnce()
    {
        var old = """{"id":"x","kind":"file","value":"/tmp/a.md","href":"/tmp/a.md","label":"a.md","sessionId":"s","sessionTitle":"T","timestamp":1}""";
        Assert.Equal(1, ArtifactRecord.FromJson(JsonNode.Parse(old))!.Repeats);
        Assert.Equal(1, ArtifactRecord.FromJson(JsonNode.Parse(old.Replace("}", ",\"repeats\":\"many\"}")))!.Repeats);
        Assert.Equal(1, ArtifactRecord.FromJson(JsonNode.Parse(old.Replace("}", ",\"repeats\":0}")))!.Repeats);
        var kept = ArtifactRecord.FromJson(JsonNode.Parse(old))! with { Repeats = 4 };
        Assert.Equal(4, ArtifactRecord.FromJson(kept.ToJson())!.Repeats);
    }
}

public class ArtifactListWordsTests
{
    private static readonly TimeZoneInfo Chicago = TimeZoneInfo.FindSystemTimeZoneById("America/Chicago");
    private static DateTimeOffset At(int y, int mo, int d, int h, int mi) =>
        new(new DateTime(y, mo, d, h, mi, 0), Chicago.GetUtcOffset(new DateTime(y, mo, d, h, mi, 0)));
    private static double Ms(DateTimeOffset d) => d.ToUnixTimeMilliseconds();
    private static readonly DateTimeOffset Now = At(2026, 9, 29, 9, 0);

    [Fact]
    public void HeadsDaysAsPhotosDoes()
    {
        Assert.Equal("Today", ArtifactListWords.Day(Ms(At(2026, 9, 29, 6, 2)), Now, Chicago));
        Assert.Equal("Yesterday", ArtifactListWords.Day(Ms(At(2026, 9, 28, 6, 2)), Now, Chicago));
        Assert.Equal("Friday", ArtifactListWords.Day(Ms(At(2026, 9, 25, 6, 2)), Now, Chicago));
        Assert.Equal("September 10", ArtifactListWords.Day(Ms(At(2026, 9, 10, 6, 2)), Now, Chicago));
        Assert.Equal("September 10, 2025", ArtifactListWords.Day(Ms(At(2025, 9, 10, 6, 2)), Now, Chicago));
    }

    [Fact]
    public void SaysWhereAndWhenWithoutARunTitlesOwnStamp()
    {
        Assert.Equal("Hermes Projects · 6:20 PM", ArtifactListWords.Subtitle("Hermes Projects", Ms(At(2026, 9, 28, 18, 20)), Now, Chicago));
        Assert.Equal("KPI Weekly Reports Generator · 6:02 AM",
            ArtifactListWords.Subtitle("KPI Weekly Reports Generator · Sep 28 06:01", Ms(At(2026, 9, 28, 6, 2)), Now, Chicago));
        Assert.Equal("Old chat · Aug 2", ArtifactListWords.Subtitle("Old chat", Ms(At(2026, 8, 2, 6, 2)), Now, Chicago));
    }

    [Fact]
    public void EmptyTexts()
    {
        var research = ArtifactListWords.Empty(ArtifactKind.Link, "Research", "");
        Assert.Equal("No Links in Research’s Recent Chats", research.Title);
        Assert.Equal("Links from your chats appear here. Artifacts looks through Research’s 50 most recent chats.", research.Description);
        Assert.Equal("No Artifacts in Recent Chats", ArtifactListWords.Empty(null, null, "").Title);
        Assert.Equal("No Results for “x”", ArtifactListWords.Empty(null, null, "x").Title);
    }
}

public class ArtifactIndexTests
{
    private static ArtifactSessionRow Row(string id, double last, string profile = "default", long? count = 1) =>
        new() { Id = id, Profile = profile, MessageCount = count, LastActive = last };

    private sealed class Calls
    {
        public readonly List<string> List = [];
        public int Count { get { lock (List) return List.Count; } }
    }

    private static Func<ArtifactSessionRow, CancellationToken, Task<List<ArtifactRecord>>> Loader(Calls calls, HashSet<string>? fail = null,
        HashSet<string>? tooLarge = null, Func<ArtifactSessionRow, string[]>? produce = null) => (s, _) =>
    {
        lock (calls.List) calls.List.Add(s.Id);
        if (tooLarge?.Contains(s.Id) == true) throw new ArtifactSafeLoadException();
        if (fail?.Contains(s.Id) == true) throw new GatewayException("offline", "x");
        return Task.FromResult((produce?.Invoke(s) ?? [$"{s.Id}.png"]).Select(v => new ArtifactRecord
        {
            Id = $"{s.Id}:{v}", Kind = ArtifactKind.Image, Value = v, Href = v, Label = v, SessionId = s.Id, Profile = s.Profile,
            SessionTitle = "t", Timestamp = 1,
        }).ToList());
    };

    [Fact]
    public async Task ReadsATranscriptAgainOnlyWhenItsSessionChanged()
    {
        var index = new ArtifactIndex(null);
        var calls = new Calls();
        var sessions = new[] { Row("a", 10), Row("b", 20, "ivy", 5) };
        var first = await index.RunAsync(sessions, Loader(calls));
        Assert.Equal(["a:a.png", "b:b.png"], first.Artifacts.Select(a => a.Id).Order());
        var second = await index.RunAsync(sessions, Loader(calls));
        Assert.Equal(["a:a.png", "b:b.png"], second.Artifacts.Select(a => a.Id).Order());
        Assert.Equal(2, calls.Count);
        var changed = sessions[1] with { MessageCount = 6, LastActive = 21 };
        var third = await index.RunAsync([sessions[0], changed], Loader(calls));
        Assert.Equal(["b", "a", "b"], calls.List);
        Assert.Equal(["b"], third.Read.Select(r => r.Id));
    }

    [Fact]
    public async Task OnePassKeepsEveryChatItRead()
    {
        var index = new ArtifactIndex(null);
        var calls = new Calls();
        var sessions = Enumerable.Range(0, 40).Select(i => Row($"c{i}", i, i % 3 == 0 ? "ivy" : "default", i % 9 == 0 ? ArtifactIndex.LongSession : i + 1)).ToList();
        var first = await index.RunAsync(sessions, Loader(calls));
        Assert.Equal(sessions.Select(s => $"{s.Id}:{s.Id}.png").ToHashSet(), first.Artifacts.Select(a => a.Id).ToHashSet());
        Assert.Equal(sessions.Count, index.Entries.Count);
        var second = await index.RunAsync(sessions, Loader(calls));
        Assert.Empty(second.Read);
        Assert.Equal(sessions.Count, second.Artifacts.Count);
        Assert.Equal(sessions.Count, calls.Count);
    }

    [Fact]
    public async Task NeverCachesFailedReadsOrRowsWithoutAStamp()
    {
        var index = new ArtifactIndex(null);
        var calls = new Calls();
        var first = await index.RunAsync([Row("a", 1)], Loader(calls, fail: ["a"]));
        Assert.Single(first.Failures);
        await index.RunAsync([Row("a", 1)], Loader(calls));
        Assert.Equal(2, calls.Count);
        var bare = new[] { new ArtifactSessionRow { Id = "b" } };
        await index.RunAsync(bare, Loader(calls));
        await index.RunAsync(bare, Loader(calls));
        Assert.Equal(4, calls.Count);
        Assert.Null(ArtifactIndex.Stamp(new ArtifactSessionRow { Id = "b" }));
    }

    [Fact]
    public async Task KeepsATranscriptOverTheSafeLoadLimitAsFailedUntilItGrows()
    {
        var index = new ArtifactIndex(null);
        var calls = new Calls();
        var big = Row("big", 5, count: 900);
        var small = Row("small", 5, count: 2);
        var first = await index.RunAsync([big, small], Loader(calls, tooLarge: ["big"]));
        Assert.Equal(["big"], first.Failures.Select(f => f.Session.Id));
        var second = await index.RunAsync([big, small], Loader(calls, tooLarge: ["big"]));
        var third = await index.RunAsync([big with { MessageCount = 950, LastActive = 9 }, small], Loader(calls, tooLarge: ["big"]));
        Assert.Equal(2, calls.Count);
        Assert.Empty(second.Failures);
        Assert.Empty(third.Failures);
        Assert.Equal(["small:small.png"], third.Artifacts.Select(a => a.Id));
    }

    [Fact]
    public async Task KeepsChatsThatLeftTheWindowAndDropsChatsThatAreGone()
    {
        var index = new ArtifactIndex(null);
        var calls = new Calls();
        Task<ArtifactIndexResult> Run(params ArtifactSessionRow[] rows) => index.RunAsync(rows, Loader(calls), ["default"], retain: 300, window: 3);
        await Run(Row("a", 10), Row("b", 20), Row("c", 30));
        var slid = await Run(Row("c", 30), Row("d", 40), Row("e", 50));
        Assert.Equal(["a:a.png", "b:b.png", "c:c.png", "d:d.png", "e:e.png"], slid.Artifacts.Select(a => a.Id).Order());
        Assert.Equal(5, calls.Count);
        var deleted = await Run(Row("c", 30), Row("d", 40), Row("f", 60));
        Assert.Equal(["a:a.png", "b:b.png", "c:c.png", "d:d.png", "f:f.png"], deleted.Artifacts.Select(a => a.Id).Order());
        var shortList = await Run(Row("f", 60));
        Assert.Equal(["f:f.png"], shortList.Artifacts.Select(a => a.Id));
    }

    [Fact]
    public async Task RoundTripsThroughItsFile()
    {
        var dir = Path.Combine(Path.GetTempPath(), "artifacts-index-" + Guid.NewGuid());
        var file = Path.Combine(dir, "artifacts-index.json");
        try
        {
            var index = new ArtifactIndex(file);
            var calls = new Calls();
            await index.RunAsync([Row("a", 10)], Loader(calls));
            await index.FlushAsync();
            var again = new ArtifactIndex(file);
            Assert.Empty(again.Entries);
            again.Prepare();
            Assert.Single(again.Entries);
            var result = await again.RunAsync([Row("a", 10)], Loader(calls));
            Assert.Empty(result.Read);
            Assert.Equal(["a:a.png"], result.Artifacts.Select(a => a.Id));
            Assert.Equal(1, calls.Count);
        }
        finally { try { Directory.Delete(dir, true); } catch (IOException) { } }
    }

    [Fact]
    public void ViewRule()
    {
        Assert.Equal(ArtifactsView.List, ArtifactIndex.View(3, 2, true, null));
        Assert.Equal(ArtifactsView.Empty, ArtifactIndex.View(3, 0, false, null));
        Assert.Equal(ArtifactsView.Loading, ArtifactIndex.View(null, 0, false, null));
        Assert.Equal(ArtifactsView.Loading, ArtifactIndex.View(null, 0, true, "x"));
        Assert.Equal(ArtifactsView.Error, ArtifactIndex.View(null, 0, false, "x"));
        Assert.Equal(ArtifactsView.Empty, ArtifactIndex.View(0, 0, false, null));
    }
}

public class ArtifactLinksTests
{
    [Fact]
    public void ALinkedNoteResolvesInTheLinkingNotesFolder()
    {
        Assert.Equal("notes.md", ArtifactLinks.LinkedNotePath("report.md", "notes.md"));
        Assert.Equal("docs/notes.md", ArtifactLinks.LinkedNotePath("docs/report.md", "./notes.md"));
        Assert.Equal("README.md", ArtifactLinks.LinkedNotePath("docs/report.md", "../README.md"));
        Assert.Equal("../up.md", ArtifactLinks.LinkedNotePath("report.md", "../up.md"));
        Assert.Equal("/Users/ivy/work/briefs/a.md", ArtifactLinks.LinkedNotePath("/Users/ivy/work/report.md", "briefs/a.md"));
        Assert.Equal("/Users/x.md", ArtifactLinks.LinkedNotePath("/Users/ivy/work/report.md", "../../x.md"));
        Assert.Equal("/etc/hosts", ArtifactLinks.LinkedNotePath("/Users/ivy/work/report.md", "/etc/hosts"));
        Assert.Equal("~/notes/a.md", ArtifactLinks.LinkedNotePath("report.md", "~/notes/a.md"));
        Assert.Equal("/Users/ivy/a.md", ArtifactLinks.LinkedNotePath("report.md", "file:///Users/ivy/a.md"));
        Assert.Equal("/x.md", ArtifactLinks.LinkedNotePath("/a.md", "../../../x.md"));
        Assert.Equal("../../x.md", ArtifactLinks.LinkedNotePath("a/b/c.md", "../../../../x.md"));
    }

    [Fact]
    public void WhatALinkIs()
    {
        Assert.Equal(new Uri("https://example.com/a"), ArtifactLinks.Classify("https://example.com/a").Url);
        Assert.Equal(new Uri("https://example.com/a"), ArtifactLinks.Classify("//example.com/a").Url);
        Assert.Equal(new Uri("https://www.example.com"), ArtifactLinks.Classify("www.example.com").Url);
        Assert.Equal(new ArtifactLink(ArtifactLinkKind.File, Target: "plan.md"), ArtifactLinks.Classify("plan.md"));
        Assert.Equal(new ArtifactLink(ArtifactLinkKind.File, Target: "../My Notes/plan.md", Fragment: "next-steps"),
            ArtifactLinks.Classify("../My%20Notes/plan.md#next-steps"));
        Assert.Equal(new ArtifactLink(ArtifactLinkKind.File, Target: "file:///Users/ivy/a.md"), ArtifactLinks.Classify("file:///Users/ivy/a.md"));
        Assert.Equal(new ArtifactLink(ArtifactLinkKind.File, Target: @"C:\notes\a.md"), ArtifactLinks.Classify(@"C:\notes\a.md"));
        Assert.Equal(new ArtifactLink(ArtifactLinkKind.Hash, Fragment: "usage"), ArtifactLinks.Classify("#usage"));
        foreach (var inert in new[] { "#", "", "   ", "javascript:alert(1)", "data:text/html,hi", "mailto:ivy@example.com", "hq-note://link?d=x" })
            Assert.Equal(ArtifactLinkKind.Inert, ArtifactLinks.Classify(inert).Kind);
    }

    [Fact]
    public void AHeadingsSlug()
    {
        Assert.Equal("getting-started", ArtifactLinks.HeadingSlug("  Getting Started!  "));
        Assert.Equal("whats-new-in-24", ArtifactLinks.HeadingSlug("What's new in 2.4?"));
        Assert.Equal("snake_case-and-kebab-case", ArtifactLinks.HeadingSlug("snake_case and kebab-case"));
        Assert.Equal("a-b", ArtifactLinks.HeadingSlug("a  --  b"));
        Assert.Equal(ArtifactLinks.HeadingSlug("Caf\u00E9"), ArtifactLinks.HeadingSlug("Cafe\u0301"));
        Assert.Equal("日本語-の-見出し", ArtifactLinks.HeadingSlug("日本語 の 見出し"));
        Assert.Equal("", ArtifactLinks.HeadingSlug("!!!"));
    }

    [Fact]
    public void HeadingsAreNumberedAndCodeIsSkipped()
    {
        var found = ArtifactLinks.Headings("# Usage\n\ntext\n\n```\n# not a heading\n```\n\n## Usage\n### `Code` and **bold** [link](x.md) ##\n#nospace\n");
        Assert.Equal(["usage", "usage-1", "code-and-bold-link"], found.Select(h => h.Id));
        Assert.Equal(["Usage", "Usage", "Code and bold link"], found.Select(h => h.Text));
    }

    [Fact]
    public void BackUsesTheNameUpToTwelveCharacters()
    {
        Assert.True(ArtifactLinks.BackUsesName("index.md"));
        Assert.True(ArtifactLinks.BackUsesName("123456789.md"));
        Assert.False(ArtifactLinks.BackUsesName("a-long-name.md"));
        Assert.Equal("plan.md", ArtifactLinks.Name("notes/plan.md"));
        Assert.Equal("b", ArtifactLinks.Name("/a/b/"));
    }
}

public class ArtifactFilesTests
{
    private static ArtifactRecord Record(string value, ArtifactKind kind = ArtifactKind.File) => new()
    {
        Id = "x", Kind = kind, Value = value, Href = value, Label = ArtifactCollector.Label(value, kind), SessionId = "s",
        SessionTitle = "T", Timestamp = 1,
    };

    [Fact]
    public void HowEachKindOpens()
    {
        Assert.Equal(ArtifactOpening.Link, ArtifactFiles.Opening(Record("https://example.org/x", ArtifactKind.Link)));
        Assert.Equal(ArtifactOpening.Image, ArtifactFiles.Opening(Record("/a/b.png", ArtifactKind.Image)));
        Assert.Equal(new ArtifactOpening(ArtifactOpeningKind.Text, true, null), ArtifactFiles.Opening(Record("/a/summary.md")));
        Assert.Equal(new ArtifactOpening(ArtifactOpeningKind.Text, false, "swift"), ArtifactFiles.Opening(Record("/a/App.swift")));
        Assert.Equal(new ArtifactOpening(ArtifactOpeningKind.Text, false, null), ArtifactFiles.Opening(Record("/a/log.txt")));
        Assert.Equal(ArtifactOpening.Html, ArtifactFiles.Opening(Record("/a/index.html")));
        Assert.Equal(ArtifactOpening.Pdf, ArtifactFiles.Opening(Record("/a/report.pdf")));
        Assert.Equal(ArtifactOpening.Other, ArtifactFiles.Opening(Record("/a/export.csv")));
        Assert.False(ArtifactFiles.OpensAsText(ArtifactFiles.Opening(Record("/a/log.txt")), 3 << 20));
        Assert.True(ArtifactFiles.OpensAsText(ArtifactFiles.Opening(Record("/a/log.txt")), 300));
        Assert.Equal("cpp", ArtifactFiles.Language("h"));
        Assert.Equal("doc.richtext", ArtifactPageWords.Glyph(Record("/a/report.pdf")));
        Assert.Equal("tablecells", ArtifactPageWords.Glyph(Record("/a/export.csv")));
        Assert.Equal("safari", ArtifactPageWords.Glyph(Record("/a/index.html")));
    }

    [Fact]
    public void FailureWords()
    {
        Assert.Equal("This file is no longer on the computer running Hermes. It may have been moved or deleted.",
            ArtifactFiles.FailureText(new GatewayException("http", "x", 404, """{"detail":"File not found"}"""), false));
        Assert.Equal("From an older session whose folder is unknown.",
            ArtifactFiles.FailureText(new GatewayException("http", "x", 400, """{"detail":"Session working directory is unavailable"}"""), false));
        Assert.Equal("This image is too large to preview.", ArtifactFiles.FailureText(new GatewayException("http", "x", 413), true));
        Assert.Equal("This file is too large to open on this PC.", ArtifactFiles.FailureText(new GatewayException("too-large", "x"), false));
        Assert.Equal("This image is on another site and couldn’t be shown here. Click Open to view it.",
            ArtifactFiles.FailureText(new RemoteImageRefusedException("not https"), true));
        Assert.True(ArtifactFiles.IsMissing(new GatewayException("http", "x", 404)));
        Assert.True(ArtifactFiles.IsTransient(new GatewayException("http", "x", 503)));
        Assert.False(ArtifactFiles.IsTransient(new GatewayException("http", "x", 404)));
        Assert.Equal("Not available on this Hermes. Updating Hermes may add it.", ArtifactFiles.Reason(new GatewayException("http", "x", 404, """{"detail":"Not Found"}""")));
    }

    [Fact]
    public void PreviewHtmlGetsAViewportOnce()
    {
        var made = System.Text.Encoding.UTF8.GetString(ArtifactFiles.PreviewHtml("<html><head><title>x</title></head><body>hi</body></html>"u8.ToArray())!);
        Assert.StartsWith("""<html><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>""", made);
        Assert.Null(ArtifactFiles.PreviewHtml("""<head><meta name="viewport" content="width=600"></head>"""u8.ToArray()));
        Assert.StartsWith("""<html><head><meta name="viewport""", System.Text.Encoding.UTF8.GetString(ArtifactFiles.PreviewHtml("<html><body>x</body></html>"u8.ToArray())!));
        Assert.Equal("hi", System.Text.Encoding.UTF8.GetString(ArtifactFiles.DecodeDataUrl("data:text/plain;base64,aGk=")));
    }

    [Fact]
    public void AKeptFileHasAStablePlace()
    {
        var a = ArtifactFiles.PreviewPath("/root", Record("/a/report.pdf"));
        Assert.Equal(a, ArtifactFiles.PreviewPath("/root", Record("/a/report.pdf")));
        Assert.NotEqual(a, ArtifactFiles.PreviewPath("/root", Record("/b/report.pdf")));
        Assert.EndsWith("report.pdf", a);
        Assert.EndsWith("preview-report.pdf", ArtifactFiles.PreviewCopyPath(a));
    }
}

public class ArtifactHiddenTests
{
    private static ArtifactRecord Record(string value, string? profile) => new()
    {
        Id = $"{profile}:{value}", Kind = ArtifactKind.File, Value = value, Href = value, Label = value, SessionId = "s", Profile = profile,
        SessionTitle = "T", Timestamp = 1,
    };

    [Fact]
    public void ARemovedArtifactLeavesEveryChatAndIsKept()
    {
        var dir = Path.Combine(Path.GetTempPath(), "artifacts-hidden-" + Guid.NewGuid());
        try
        {
            var hidden = new ArtifactHidden(ArtifactHidden.FileOf("acct", dir));
            var changed = 0;
            hidden.Changed += () => changed++;
            hidden.Hide(Record("/tmp/junk.png", null));
            hidden.Hide(Record("/tmp/junk.png", "default"));   // the same key: no second change
            Assert.Equal(1, changed);
            Assert.True(hidden.IsHidden("default", "/tmp/junk.png"));
            Assert.False(hidden.IsHidden("ivy", "/tmp/junk.png"));
            var visible = hidden.Visible([Record("/tmp/junk.png", "default"), Record("/tmp/junk.png", "ivy"), Record("/tmp/ok.png", null)]);
            Assert.Equal(["ivy", null], visible.Select(r => r.Profile));
            var again = new ArtifactHidden(ArtifactHidden.FileOf("acct", dir));
            Assert.True(again.IsHidden(null, "/tmp/junk.png"));
        }
        finally { try { Directory.Delete(dir, true); } catch (IOException) { } }
    }
}

public class ArtifactsStoreTests
{
    /// A stand-in source: two bots' listings, transcripts by id.
    private sealed class FakeSource : IArtifactSource
    {
        public Dictionary<string, List<(ArtifactSessionRow Row, JsonArray Messages)>> Bots { get; } = [];
        public List<string> Listed { get; } = [];
        public HashSet<string> FailingProfiles { get; } = [];

        public Task<JsonNode> ListSessionsAsync(string profile, int limit, CancellationToken ct)
        {
            lock (Listed) Listed.Add(profile);
            if (FailingProfiles.Contains(profile)) throw new GatewayException("http", "x", 500, "boom");
            var rows = Bots.Where(b => profile == "all" || b.Key == profile).SelectMany(b => b.Value).Select(s => (JsonNode)new JsonObject
            {
                ["id"] = s.Row.Id, ["profile"] = s.Row.Profile, ["title"] = s.Row.Title, ["message_count"] = s.Row.MessageCount,
                ["last_active"] = s.Row.LastActive,
            });
            return Task.FromResult<JsonNode>(new JsonObject { ["sessions"] = new JsonArray([.. rows]) });
        }

        public Task<string> TranscriptPageAsync(ArtifactSessionRow session, int limit, int offset, CancellationToken ct)
        {
            var messages = Bots.Values.SelectMany(v => v).First(s => s.Row.Id == session.Id).Messages;
            return Task.FromResult(new JsonObject { ["messages"] = JsonNode.Parse(messages.ToJsonString()) }.ToJsonString());
        }

        public Task<string> DataUrlAsync(ArtifactRecord record, CancellationToken ct) => throw new NotSupportedException();
        public Task DownloadAsync(ArtifactRecord record, string file, CancellationToken ct) => throw new NotSupportedException();
    }

    private static (ArtifactSessionRow, JsonArray) Chat(string id, string profile, string title, double last, params string[] said) =>
        (new ArtifactSessionRow { Id = id, Profile = profile, Title = title, MessageCount = said.Length, LastActive = last },
         new JsonArray([.. said.Select(t => ArtifactCollectorTests.Assistant(t, last))]));

    [Fact]
    public async Task APassListsEachBotAndScopesNarrowIt()
    {
        var source = new FakeSource();
        source.Bots["default"] = [Chat("s1", "default", "Release", 2000, "Wrote /tmp/notes.md", "Again /tmp/notes.md")];
        source.Bots["ivy"] = [Chat("s2", "ivy", "Reading", 3000, "See https://example.org/papers/open-planning")];
        var dir = Path.Combine(Path.GetTempPath(), "artifacts-store-" + Guid.NewGuid());
        try
        {
            var store = new ArtifactsStore(source, Path.Combine(dir, "index.json"), new ArtifactHidden(null))
            { ProfilesProvider = () => ["default", "ivy"] };
            Assert.Equal(ArtifactsView.Loading, ArtifactIndex.View(store.Loaded, 0, store.Refreshing, store.LoadError));
            await store.RefreshAsync(explicit_: true);
            Assert.Equal(["default", "ivy"], source.Listed.Order());
            Assert.Equal(["https://example.org/papers/open-planning", "/tmp/notes.md"], store.Artifacts.Select(a => a.Value));
            Assert.Equal(2, store.Artifacts[1].Repeats);
            store.SetScope("ivy");
            Assert.Equal(["https://example.org/papers/open-planning"], store.Artifacts.Select(a => a.Value));
            store.Hidden.Hide(store.Artifacts[0]);
            Assert.Empty(store.Artifacts);
            store.MarkUnavailable("x");
            Assert.Contains("x", store.Unavailable);
            await store.RefreshAsync(explicit_: true);
            Assert.Empty(store.Unavailable);
        }
        finally { try { Directory.Delete(dir, true); } catch (IOException) { } }
    }

    [Fact]
    public async Task ABotThatCantBeListedIsNamedAndTheOthersStay()
    {
        var source = new FakeSource();
        source.Bots["default"] = [Chat("s1", "default", "Release", 2000, "Wrote /tmp/notes.md")];
        source.FailingProfiles.Add("ivy");
        var notices = new List<string>();
        var store = new ArtifactsStore(source, null, new ArtifactHidden(null))
        { ProfilesProvider = () => ["default", "ivy"], DisplayName = p => p == "ivy" ? "Ivy" : "Hermes" };
        store.Notice += (text, _) => notices.Add(text);
        await store.RefreshAsync(explicit_: true);
        Assert.Equal(["/tmp/notes.md"], store.Artifacts.Select(a => a.Value));
        Assert.Contains("Couldn’t list Ivy’s chats, so their artifacts are missing.", notices);
        Assert.Null(store.LoadError);
    }

    [Fact]
    public async Task AFailedListingIsTheErrorAfterOneRetry()
    {
        var source = new FakeSource();
        source.FailingProfiles.Add("all");
        var store = new ArtifactsStore(source, null, new ArtifactHidden(null)) { RetryDelay = TimeSpan.FromMilliseconds(10) };
        await store.RefreshAsync(explicit_: true);
        Assert.Equal(2, source.Listed.Count);
        Assert.Equal("boom", store.LoadError);
        Assert.Equal(ArtifactsView.Error, ArtifactIndex.View(store.Loaded, 0, store.Refreshing, store.LoadError));
    }
}

public class ArtifactNoteTests
{
    [Fact]
    public void FrontMatterBecomesFacts()
    {
        var (facts, body) = ArtifactLinks.FrontMatter("---\ntitle: Morning reading\ntags:\n- agents\n- memory\n---\n\n# Morning reading\n");
        Assert.Equal([("Title", "Morning reading"), ("Tags", "agents, memory")], facts);
        Assert.Equal("\n# Morning reading\n", body);
        Assert.Equal("# Plain\n", ArtifactLinks.FrontMatter("# Plain\n").Body);
    }

    [Fact]
    public void TheViewersInfoSaysWhen()
    {
        var zone = TimeZoneInfo.Utc;
        var now = new DateTimeOffset(2026, 11, 21, 12, 0, 0, TimeSpan.Zero);
        Assert.Equal("Today at 9:05 AM", ArtifactListWords.RelativeDateTime(now.AddMinutes(-175).ToUnixTimeMilliseconds(), now, zone));
        Assert.Equal("Yesterday at 12:00 PM", ArtifactListWords.RelativeDateTime(now.AddDays(-1).ToUnixTimeMilliseconds(), now, zone));
        Assert.Equal("Sep 30 at 12:00 PM", ArtifactListWords.RelativeDateTime(new DateTimeOffset(2026, 9, 30, 12, 0, 0, TimeSpan.Zero).ToUnixTimeMilliseconds(), now, zone));
    }
}
