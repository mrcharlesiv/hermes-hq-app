using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using Hermes.Core.Artifacts;
using Hermes.Core.Auth;
using Hermes.Core.Jobs;
using Hermes.Core.Net;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-JOB-RUN-DOCUMENT] A script run's saved output opens in the app's read-only viewer, as the Mac's
/// JobDetailViewController `open(_:)` `.document` (93f984bb1): the path under the job's `hermes_home`, read for the
/// job's owner, UTF-8 only, its answer first, titled with the run's label and Back reading the job's name; a late
/// answer after another run or Back is dropped. Synthetic data only; headless (no WinUI, no real gateway).
public class JobRunDocumentTests
{
    private static readonly TimeZoneInfo C = Chicago.Zone;

    private static CronJob Job(string? home = "/Users/me/.hermes/profiles/otto") =>
        new("j7") { Name = "Morning brief", Profile = "otto", HermesHome = home };

    private static CronRun DocRun(string stem = "2026-06-01_10-17-00") =>
        new($"cron_output:j7:{stem}") { Source = "cron_output", Title = "COMPLETED · # Morning brief", StartedAt = Chicago.Parse("2026-06-01T15:17:00Z").ToUnixTimeSeconds(), Profile = "herald" };

    private const string Doc = "# Cron Job: Morning brief\n\n## Prompt\n\nSummarise the day.\n\n## Response\n\n## Café plan — 日本 ✅\n\n- first ünïcode item\n- second\n\n```sh\necho \"héllo\"\n```\n";

    // MARK: Opening: path, profile, label, Back

    [Fact]
    public void ADocumentRunOpensItsFileForTheJobsOwnerWithTheRunsLabelAndTheJobsNameOnBack()
    {
        var opening = JobRunDocument.Opening(Job(), DocRun(), "Morning brief", C)!;
        Assert.Equal("/Users/me/.hermes/profiles/otto/cron/output/j7/2026-06-01_10-17-00.md", opening.Path);
        Assert.Equal("otto", opening.Profile);   // the job's owner, not the run's own profile (the Mac's `job.owner`)
        Assert.Equal("Mon, Jun 1, 10:17 AM", opening.Title);
        Assert.Equal(JobWords.CronRunLabel(DocRun(), C).Title, opening.Title);
        Assert.Equal("Morning brief", opening.BackTitle);
    }

    [Fact]
    public void TheHomeLosesOneTrailingSlashAsOnTheMac()
    {
        Assert.Equal("/h/cron/output/j7/s.md", JobRunDocument.FilePath("/h/", "j7", "s"));
        Assert.Equal("/h/cron/output/j7/s.md", JobRunDocument.FilePath("/h", "j7", "s"));
        Assert.Equal("/h//cron/output/j7/s.md", JobRunDocument.FilePath("/h//", "j7", "s"));   // `dropLast()` once
    }

    [Fact]
    public void ChatsExecRunsAndAJobWithoutAHomeOpenNoDocument()
    {
        Assert.Null(JobRunDocument.Opening(Job(), new CronRun("s1") { Source = "cron" }, "Morning brief", C));
        Assert.Null(JobRunDocument.Opening(Job(), new CronRun("cron_output:j7:exec:2") { Source = "cron_output" }, "Morning brief", C));
        Assert.Null(JobRunDocument.Opening(Job(), new CronRun("cron_output:j7:latest") { Source = "cron_output" }, "Morning brief", C));
        Assert.Null(JobRunDocument.Opening(Job(home: null), DocRun(), "Morning brief", C));
        Assert.Null(JobRunDocument.Opening(Job(home: ""), DocRun(), "Morning brief", C));
    }

    // MARK: The text: UTF-8 Markdown vs plain text, unreadable vs missing

    [Fact]
    public void Utf8MarkdownKeepsItsHeadingsListAndCodeWithTheAnswerFirst()
    {
        var text = JobRunDocument.Text(Encoding.UTF8.GetBytes(Doc));
        Assert.StartsWith("# Cron Job: Morning brief\n\n## Response\n", text);
        Assert.True(text.IndexOf("## Response", StringComparison.Ordinal) < text.IndexOf("## Prompt", StringComparison.Ordinal));
        Assert.Contains("## Café plan — 日本 ✅", text);
        Assert.Contains("- first ünïcode item\n- second", text);
        Assert.Contains("```sh\necho \"héllo\"\n```", text);
        Assert.Equal(JobWords.RunDocumentFirst(Doc), text);
    }

    [Fact]
    public void PlainTextIsShownAsItIs()
    {
        const string plain = "just a line of output — ok\nsecond line";
        Assert.Equal(plain, JobRunDocument.Text(Encoding.UTF8.GetBytes(plain)));
    }

    [Fact]
    public void BytesThatArentUtf8AreUnreadableNotMissing()
    {
        var e = Assert.Throws<ArtifactReadException>(() => JobRunDocument.Text([0x23, 0x20, 0xC3, 0x28, 0xFF, 0xFE]));
        Assert.Equal("This file isn’t plain text.", ArtifactFiles.FailureText(e, image: false));
        Assert.False(ArtifactFiles.IsMissing(e));   // the Mac would offer Open in Quick Look here (left open on Windows)
    }

    [Fact]
    public void AMissingDocumentSaysItsGoneAndIsMissing()
    {
        var gone = new GatewayException("http", "The gateway answered 404.", 404, "{\"detail\":\"not found\"}");
        Assert.True(ArtifactFiles.IsMissing(gone));
        Assert.StartsWith("This file is no longer on ", ArtifactFiles.FailureText(gone, image: false));
    }

    // MARK: The reader: one reading on show, late answers dropped

    private sealed class Held : IJobRunDocumentSource
    {
        public readonly List<(string Path, string Profile, TaskCompletionSource<byte[]> Answer)> Asks = [];
        public Task<byte[]> ReadAsync(string path, string profile, CancellationToken ct)
        {
            var tcs = new TaskCompletionSource<byte[]>(TaskCreationOptions.RunContinuationsAsynchronously);
            Asks.Add((path, profile, tcs));
            return tcs.Task;   // ignores ct on purpose: a gateway that answers late anyway
        }
    }

    private static JobRunDocumentOpening Opening(string stem) => JobRunDocument.Opening(Job(), DocRun(stem), "Morning brief", C)!;

    [Fact]
    public async Task TheReadingOnShowGetsItsTextReadForTheJobsProfile()
    {
        var source = new Held();
        var reader = new JobRunReader(source);
        var reading = reader.Open(Opening("a"));
        var load = reading.LoadAsync(CancellationToken.None);
        Assert.Equal(("/Users/me/.hermes/profiles/otto/cron/output/j7/a.md", "otto"), (source.Asks[0].Path, source.Asks[0].Profile));
        source.Asks[0].Answer.SetResult(Encoding.UTF8.GetBytes(Doc));
        Assert.Equal(JobWords.RunDocumentFirst(Doc), await load);
        Assert.Same(reading, reader.Current);
    }

    [Fact]
    public async Task ALateAnswerAfterAnotherRunIsDroppedAndTheNewRunShowsItsOwn()
    {
        var source = new Held();
        var reader = new JobRunReader(source);
        var first = reader.Open(Opening("a"));
        var firstLoad = first.LoadAsync(CancellationToken.None);
        var second = reader.Open(Opening("b"));
        var secondLoad = second.LoadAsync(CancellationToken.None);
        Assert.False(first.IsCurrent);
        source.Asks[1].Answer.SetResult(Encoding.UTF8.GetBytes("B output"));
        Assert.Equal("B output", await secondLoad);
        source.Asks[0].Answer.SetResult(Encoding.UTF8.GetBytes("A output, late"));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => firstLoad);
        Assert.Same(second, reader.Current);
    }

    [Fact]
    public async Task ALateAnswerAfterBackIsDroppedNotAFailure()
    {
        var source = new Held();
        var reader = new JobRunReader(source);
        var reading = reader.Open(Opening("a"));
        var load = reading.LoadAsync(CancellationToken.None);
        reader.Leave();   // Back
        Assert.Null(reader.Current);
        source.Asks[0].Answer.SetResult([0xFF, 0xFE]);   // even an unreadable answer is dropped, not shown as a failure
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => load);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => reading.LoadAsync(CancellationToken.None));
        Assert.Single(source.Asks);   // an ended reading never asks again
    }

    [Fact]
    public async Task AFailureOnShowReachesTheViewerAndTryAgainReadsAgain()
    {
        var source = new Held();
        var reader = new JobRunReader(source);
        var reading = reader.Open(Opening("a"));
        var load = reading.LoadAsync(CancellationToken.None);
        source.Asks[0].Answer.SetException(new GatewayException("http", "The gateway answered 404.", 404, ""));
        var e = await Assert.ThrowsAsync<GatewayException>(() => load);
        Assert.True(ArtifactFiles.IsMissing(e));
        var again = reading.LoadAsync(CancellationToken.None);
        Assert.Equal(2, source.Asks.Count);
        source.Asks[1].Answer.SetResult([0xC3, 0x28]);
        Assert.IsType<ArtifactReadException>(await Assert.ThrowsAnyAsync<Exception>(() => again));
    }

    // MARK: The gateway source: exact bytes, the profile-scoped query, the scratch file removed

    private sealed class Download(HttpStatusCode status, byte[] body) : HttpMessageHandler
    {
        public Uri? Asked;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Asked = request.RequestUri;
            return Task.FromResult(new HttpResponseMessage(status) { Content = new ByteArrayContent(body) });
        }
    }

    private static GatewaySession Session(HttpMessageHandler handler) =>
        new(GatewayAddress.Validated("http://127.0.0.1:9"), new StoredAccount("http://127.0.0.1:9", "qa"), new MemoryTokenStore(), handler);

    private static string Scratch() => Directory.CreateTempSubdirectory("job-run-doc-test-").FullName;

    [Fact]
    public async Task TheGatewaySourceKeepsTheBytesExactAndAsksForTheJobsProfile()
    {
        var bytes = new byte[] { 0x23, 0x20, 0xC3, 0x28, 0xFF };
        var handler = new Download(HttpStatusCode.OK, bytes);
        var scratch = Scratch();
        var source = new GatewayJobRunDocumentSource(Session(handler), scratch);
        var data = await source.ReadAsync("/Users/me/.hermes/profiles/otto/cron/output/j7/a.md", "otto", CancellationToken.None);
        Assert.Equal(bytes, data);   // the session's string read would have turned these into U+FFFD
        Assert.Equal("/api/fs/download", handler.Asked!.AbsolutePath);
        var query = Uri.UnescapeDataString(handler.Asked.Query);
        Assert.Contains("path=/Users/me/.hermes/profiles/otto/cron/output/j7/a.md", query);
        Assert.Contains("profile=otto", query);
        Assert.Empty(Directory.GetFiles(scratch));
        Assert.Throws<ArtifactReadException>(() => JobRunDocument.Text(data));
        Directory.Delete(scratch, true);
    }

    [Fact]
    public async Task TheGatewaySourceReportsAMissingFileAsA404()
    {
        var scratch = Scratch();
        var source = new GatewayJobRunDocumentSource(Session(new Download(HttpStatusCode.NotFound, Encoding.UTF8.GetBytes("{\"detail\":\"File not found\"}"))), scratch);
        var e = await Assert.ThrowsAsync<GatewayException>(() => source.ReadAsync("/x/cron/output/j7/a.md", "otto", CancellationToken.None));
        Assert.True(ArtifactFiles.IsMissing(e));
        Assert.Empty(Directory.GetFiles(scratch));
        Directory.Delete(scratch, true);
    }

    // MARK: The WinUI side, held to the tested objects (source proof only; not a run on Windows)

    private static string PageSource()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine(dir, "src", "HermesHQ.Windows", "Features", "Jobs", "JobsPage.cs"));
    }

    private static string Body(string source, string signature)
    {
        var m = Regex.Match(source, Regex.Escape(signature) + @"[^\n]*\n    \{(?<body>.*?)\n    \}", RegexOptions.Singleline);
        Assert.True(m.Success, signature + " not found");
        return m.Groups["body"].Value;
    }

    [Fact]
    public void JobsPageOpensTheRunDocumentInTheReadOnlyViewerNotAMonospaceTextBlock()
    {
        var source = PageSource();
        var open = Body(source, "private void OpenRun(CronJob job, CronRun run)");
        Assert.Contains("JobRunDocument.Opening(job, run, title)", open);
        Assert.Contains("RunReader(store).Open(opening)", open);
        Assert.Contains("new ArtifactTextView(markdown: true, reading.LoadAsync)", open);
        Assert.Contains("Title = opening.Title", open);
        Assert.Contains("ShowPushed(opening.BackTitle, viewer, viewer)", open);
        Assert.Contains("_runReader?.Leave();", open);   // another run or a chat ends the reading on show
        // The chat branch is as it was: the run's own profile, else the job's owner, Back reading the job's name.
        Assert.Contains("new ChatPage.Args(run.Profile ?? job.Owner, run.Id, title)", open);
        Assert.Contains("ShowPushed(title, frame)", open);
        Assert.DoesNotContain("DownloadTextAsync", source);
        Assert.DoesNotContain("LoadDocumentAsync", source);
        Assert.DoesNotContain("CodeFont", open);
        // Nothing outside the app: the viewer is given no Open in Default App (the Mac's Quick Look stays open).
        Assert.DoesNotContain("OpenElsewhere", source);
        Assert.DoesNotContain("Launcher", source);
    }

    [Fact]
    public void BackAndAnotherJobEndTheReading()
    {
        var source = PageSource();
        var pushed = Body(source, "private void ShowPushed(string backTitle, UIElement content, ArtifactViewer? viewer = null)");
        Assert.Matches(@"back\.Click \+= \(_, _\) =>\s*\{\s*//[^\n]*\n\s*_runReader\?\.Leave\(\);", pushed);
        Assert.Contains("viewer.Title", pushed);
        Assert.Contains("Look.Modes(viewer.Mode, viewer.SetMode)", pushed);
        Assert.Contains("viewer.HasModes", pushed);
        Assert.Contains("_runReader?.Leave();", Body(source, "private void Select(string? key)"));
        Assert.Contains("_runReader?.Leave();", Body(source, "protected override void OnNavigatedFrom(NavigationEventArgs e)"));
    }
}
