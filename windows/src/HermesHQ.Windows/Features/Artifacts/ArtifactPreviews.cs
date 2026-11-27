using System.Runtime.InteropServices.WindowsRuntime;
using System.Security.Cryptography;
using System.Text;
using Hermes.Core.Artifacts;
using HermesHQ.Services;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace HermesHQ.Features.Artifacts;

/// Picture previews for Artifacts (App/Pages/Artifacts/ArtifactPreviews.swift; docs/spec/1x-pages.md §5.5–§5.6): bytes
/// through `read-data-url` (or a data URL, or an https picture from a public host fetched without gateway credentials),
/// kept on disk per account so a later visit shows them at once, decoded at the tile's size. Four reads at a time,
/// newest request first. A chat read again reads its pictures again, the kept one staying up meanwhile. An icon-sized
/// picture (under 64 px, or under 64×64 in all) leaves the grid. Use from the UI thread.
internal sealed class ArtifactPreviews(IArtifactSource source, string root)
{
    public abstract record State;
    public sealed record Loading : State;
    public sealed record Shown(BitmapImage Image) : State;
    public sealed record Failed(string Text, bool Missing, bool Hosted) : State;

    private const int Slots = 4;
    private readonly Dictionary<string, BitmapImage> _images = [];
    private readonly Dictionary<string, (string Text, bool Missing, bool Hosted, bool Transient)> _failures = [];
    private readonly HashSet<string> _tiny = [];
    private readonly HashSet<string> _inFlight = [];
    private readonly HashSet<string> _staleSessions = [];
    private readonly HashSet<string> _fresh = [];
    private readonly List<(string Id, Func<Task> Start)> _waiting = [];
    private int _running;

    /// An artifact's preview landed or failed.
    public event Action<string>? Updated;

    private static string Key(string id) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(id)))[..32];
    private string ThumbFile(string id) => Path.Combine(root, "thumbs", Key(id));
    public string FullFile(ArtifactRecord record) => ArtifactFiles.PreviewPath(Path.Combine(root, "pictures"), record);

    public bool IsTiny(ArtifactRecord record) => record.Kind == ArtifactKind.Image && _tiny.Contains(record.Id);

    public State StateOf(ArtifactRecord record)
    {
        if (_images.TryGetValue(record.Id, out var image)) return new Shown(image);
        if (_failures.TryGetValue(record.Id, out var f)) return new Failed(f.Text, f.Missing, f.Hosted);
        return new Loading();
    }

    /// Sessions read again: their pictures are read again on their next request.
    public void MarkStale(IEnumerable<string> sessionIds)
    {
        foreach (var id in sessionIds) _staleSessions.Add(id);
        _fresh.RemoveWhere(id => _staleSessions.Any(s => id.Contains("\u001F" + s + ":", StringComparison.Ordinal)));
    }

    /// Refresh: pictures that failed get another try.
    public void ClearFailures() => _failures.Clear();

    /// The page showed again: pictures that failed for the link (not the file) are asked again.
    public void RetryTransient()
    {
        foreach (var id in _failures.Where(f => f.Value.Transient).Select(f => f.Key).ToList()) _failures.Remove(id);
    }

    /// Ask for a tile's preview: from disk when it was kept, else from the gateway.
    public void Request(ArtifactRecord record, int pixels)
    {
        var id = record.Id;
        if (_fresh.Contains(id) || _failures.ContainsKey(id) || _inFlight.Contains(id) || _waiting.Any(w => w.Id == id)) return;
        _inFlight.Add(id);
        _ = LoadAsync(record, pixels);
    }

    private async Task LoadAsync(ArtifactRecord record, int pixels)
    {
        var id = record.Id;
        var file = ThumbFile(id);
        var stale = _staleSessions.Contains(record.SessionId);
        if (!stale && File.Exists(file) && await DecodeAsync(id, await File.ReadAllBytesAsync(file), pixels))
        {
            _inFlight.Remove(id);
            _fresh.Add(id);
            Updated?.Invoke(id);
            return;
        }
        _inFlight.Remove(id);
        Enqueue(id, async () =>
        {
            try
            {
                var bytes = await ArtifactReads.ImageAsync(source, record);
                Directory.CreateDirectory(Path.GetDirectoryName(file)!);
                await File.WriteAllBytesAsync(file, bytes);
                _staleSessions.Remove(record.SessionId);
                if (!await DecodeAsync(id, bytes, pixels)) throw new ArtifactReadException("This image could not be read.");
                _fresh.Add(id);
                _failures.Remove(id);
            }
            catch (Exception e)
            {
                // A kept picture stays up when a fresh read fails.
                if (!_images.ContainsKey(id))
                    _failures[id] = (ArtifactFiles.FailureText(e, image: true), ArtifactFiles.IsMissing(e), e is RemoteImageRefusedException,
                        ArtifactFiles.IsTransient(e));
                AppLog.Note("artifacts", $"picture failed: {e.GetType().Name}");
            }
            Updated?.Invoke(id);
        });
    }

    private void Enqueue(string id, Func<Task> start)
    {
        // Newest request first (a tile scrolled to just now before ones asked earlier).
        _waiting.Insert(0, (id, start));
        Pump();
    }

    private void Pump()
    {
        while (_running < Slots && _waiting.Count > 0)
        {
            var (id, start) = _waiting[0];
            _waiting.RemoveAt(0);
            _running++;
            _inFlight.Add(id);
            _ = Run(id, start);
        }
    }

    private async Task Run(string id, Func<Task> start)
    {
        try { await start(); }
        finally
        {
            _inFlight.Remove(id);
            _running--;
            Pump();
        }
    }

    private async Task<bool> DecodeAsync(string id, byte[] bytes, int pixels)
    {
        try
        {
            using var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(bytes.AsBuffer());
            stream.Seek(0);
            var decoder = await BitmapDecoder.CreateAsync(stream);
            var (w, h) = (decoder.OrientedPixelWidth, decoder.OrientedPixelHeight);
            if (Math.Max(w, h) < 64 || w * h < 64 * 64) _tiny.Add(id); else _tiny.Remove(id);
            stream.Seek(0);
            var image = new BitmapImage();
            if (pixels > 0 && w > pixels) image.DecodePixelWidth = pixels;
            await image.SetSourceAsync(stream);
            _images[id] = image;
            return true;
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            return false;
        }
    }

    /// The whole picture on disk, for the viewer, Share and Save As (read once, then kept).
    public async Task<string> FullAsync(ArtifactRecord record, CancellationToken ct = default)
    {
        var file = FullFile(record);
        if (File.Exists(file) && !_staleSessions.Contains(record.SessionId)) return file;
        var bytes = await ArtifactReads.ImageAsync(source, record, ct);
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        await File.WriteAllBytesAsync(file, bytes, ct);
        return file;
    }
}
