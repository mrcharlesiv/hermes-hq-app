using System.Text;
using Hermes.Core.Artifacts;
using Hermes.Core.Net;

namespace Hermes.Core.Jobs;

/// A script run's saved output, opened in the app's own read-only text viewer (App/Pages/Jobs/JobDetailViewController.swift
/// `open(_:)` `.document`, at 93f984bb1): the file `<hermes_home>/cron/output/<job id>/<stem>.md`, read through
/// `GET /api/fs/download?path=&profile=<the job's owner>`, as Markdown (Preview | Source), its answer first
/// (`ArtifactFiles.runDocumentFirst`). The viewer's title is the run's label; Back reads the job's name.
public sealed record JobRunDocumentOpening(string Path, string Profile, string Title, string BackTitle);

public static class JobRunDocument
{
    /// The Mac's read timeout for this download (`ArtifactFiles.download(path:profile:)`, 120 s).
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(120);

    /// The document's place: the home loses one trailing "/" as on the Mac (`home.dropLast()`).
    public static string FilePath(string home, string jobId, string stem) =>
        $"{(home.EndsWith('/') ? home[..^1] : home)}/cron/output/{jobId}/{stem}.md";

    /// What a run row opens as a document, or null: a chat or nothing opens otherwise, and a job without its
    /// `hermes_home` has no place to read from (the Mac's `guard let home, !home.isEmpty`).
    public static JobRunDocumentOpening? Opening(CronJob job, CronRun run, string backTitle, TimeZoneInfo? zone = null)
    {
        if (run.Opens is not RunOpens.Document doc) return null;
        if (job.HermesHome is not { Length: > 0 } home) return null;
        return new JobRunDocumentOpening(FilePath(home, job.Id, doc.Stem), job.Owner, JobWords.CronRunLabel(run, zone).Title, backTitle);
    }

    /// The bytes as the viewer shows them: UTF-8 only (anything else "This file isn’t plain text."), answer first.
    public static string Text(byte[] data)
    {
        string text;
        try { text = new UTF8Encoding(false, true).GetString(data); }
        catch (DecoderFallbackException) { throw new ArtifactReadException(ArtifactPageWords.NotPlainText); }
        return JobWords.RunDocumentFirst(text);
    }
}

/// Where the run document's bytes come from. Tests give a stand-in; the app reads the gateway.
public interface IJobRunDocumentSource
{
    Task<byte[]> ReadAsync(string path, string profile, CancellationToken ct);
}

/// The gateway's `/api/fs/download` for the job's own profile, the bytes kept exact (the session's string read would
/// turn bytes that aren't UTF-8 into U+FFFD and show a broken file as text). Streams to a scratch file under the REST
/// ceiling, reads it back and removes it.
public sealed class GatewayJobRunDocumentSource(GatewaySession session, string? scratch = null) : IJobRunDocumentSource
{
    public async Task<byte[]> ReadAsync(string path, string profile, CancellationToken ct)
    {
        var folder = scratch ?? System.IO.Path.Combine(System.IO.Path.GetTempPath(), "HermesHQ-job-runs");
        Directory.CreateDirectory(folder);
        var file = System.IO.Path.Combine(folder, Guid.NewGuid().ToString("N") + ".md");
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(JobRunDocument.Timeout);
        try
        {
            await session.DownloadToFileAsync("/api/fs/download", [new("path", path), new("profile", profile)], file,
                ArtifactFiles.FileLimit, ct: cts.Token).ConfigureAwait(false);
            return await File.ReadAllBytesAsync(file, ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new GatewayException("timeout", "The gateway took too long to answer.");
        }
        finally
        {
            try { File.Delete(file); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }
}

/// The one run document the job pane is showing. Opening another run, a chat, another job, or Back ends the reading
/// on show; an answer that arrives for an ended reading is dropped (never shown, never a failure).
public sealed class JobRunReader(IJobRunDocumentSource source)
{
    private int _generation;
    private CancellationTokenSource? _life;

    /// The reading now on show, or null.
    public JobRunReading? Current { get; private set; }

    public JobRunReading Open(JobRunDocumentOpening opening)
    {
        Leave();
        _life = new CancellationTokenSource();
        Current = new JobRunReading(this, opening, ++_generation, _life.Token);
        return Current;
    }

    /// Back, another run or job: whatever was being read is no longer wanted.
    public void Leave()
    {
        _generation++;
        Current = null;
        _life?.Cancel();   // not disposed: a read in flight still holds its token
        _life = null;
    }

    internal bool IsCurrent(JobRunReading reading) => Current == reading && reading.Generation == _generation;

    internal async Task<string> LoadAsync(JobRunReading reading, CancellationToken ct)
    {
        if (!IsCurrent(reading)) throw new OperationCanceledException();
        using var both = CancellationTokenSource.CreateLinkedTokenSource(ct, reading.Life);
        var data = await source.ReadAsync(reading.Opening.Path, reading.Opening.Profile, both.Token).ConfigureAwait(true);
        // A late answer for a reading that ended (Back, another run) is dropped, not shown or called a failure.
        if (!IsCurrent(reading) || ct.IsCancellationRequested) throw new OperationCanceledException();
        return JobRunDocument.Text(data);
    }
}

/// One opened run document: its viewer loads through `LoadAsync` (each Try Again reads again).
public sealed class JobRunReading
{
    private readonly JobRunReader _reader;
    internal JobRunReading(JobRunReader reader, JobRunDocumentOpening opening, int generation, CancellationToken life)
    {
        _reader = reader;
        Opening = opening;
        Generation = generation;
        Life = life;
    }

    public JobRunDocumentOpening Opening { get; }
    internal int Generation { get; }
    internal CancellationToken Life { get; }
    public bool IsCurrent => _reader.IsCurrent(this);

    public Task<string> LoadAsync(CancellationToken ct) => _reader.LoadAsync(this, ct);
}
