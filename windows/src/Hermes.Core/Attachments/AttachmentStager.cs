using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using Hermes.Core.Net;

namespace Hermes.Core.Attachments;

/// A file on the gateway: its stored path and the staging folder it sits in.
public sealed record StagedFile(string Path, string Folder);

/// Managed-files staging on the gateway (HermesKit/Attachments/AttachmentStager.swift; spec §3.2, §3.3, §3.6): read
/// the upload root once per profile, send one file as multipart (built on disk) to
/// `<root>/.dispatch-attachments/<UUID>/<name>`, and delete a staging folder once its copy is no longer needed.
public sealed class AttachmentStager(GatewaySession session, string tempDirectory)
{
    public const string StagingFolder = ".dispatch-attachments";

    private readonly ConcurrentDictionary<string, string> _roots = new();

    /// HermesTransportPolicy.stagedCopyReleased: a staging copy can go once the gateway stored its own copy elsewhere.
    public static bool StagedCopyReleased(bool? uploaded, string? storedPath, string folder)
    {
        if (uploaded != true || string.IsNullOrEmpty(storedPath)) return false;
        var stored = Slashed(storedPath);
        var f = Slashed(folder);
        return !(stored == f || stored.StartsWith(f + "/"));
    }

    /// A gateway path with / only: a Windows gateway answers C:\Users\…
    public static string Slashed(string path) => path.Replace('\\', '/');

    public static List<KeyValuePair<string, string>> ProfileQuery(string profile) =>
        profile.Length == 0 ? [] : [new("profile", profile)];

    /// The upload root for `profile` (GET /api/files, only `path` is read; cached for the app run).
    public async Task<string> RootAsync(string profile, CancellationToken ct = default)
    {
        if (_roots.TryGetValue(profile, out var known)) return known;
        JsonNode json;
        try { json = await session.GetJsonAsync("/api/files", ProfileQuery(profile), ct: ct); }
        catch (GatewayException e) { throw Map(e, "", reading: true); }
        var path = json.Str("path");
        if (string.IsNullOrEmpty(path)) throw AttachmentUploadException.NoFolder();
        _roots[profile] = path;
        return path;
    }

    public void ForgetRoots() => _roots.Clear();

    /// Uploads `file` as `name` (already a safe name) and returns where the gateway stored it.
    public async Task<StagedFile> StageAsync(string file, string name, string profile, Action<long, long>? progress = null,
        CancellationToken ct = default)
    {
        var folderId = Guid.NewGuid().ToString().ToUpperInvariant();
        bool rootRetried = false, conflictRetried = false;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var root = await RootAsync(profile, ct);
            var folder = root + "/" + StagingFolder + "/" + folderId;
            var destination = folder + "/" + name;
            MultipartBody.Built built;
            try
            {
                built = await Task.Run(() => MultipartBody.Build(file, destination, name, MultipartBody.NewBoundary(), tempDirectory,
                    AttachmentLimit.Bytes, ct), ct);
            }
            catch (MultipartBody.BuildException e) when (e.Failure == MultipartBody.Failure.UnsafeName)
            { throw AttachmentUploadException.BadName(); }
            catch (MultipartBody.BuildException e) when (e.Failure == MultipartBody.Failure.TooLarge)
            { throw new AttachmentUploadException(AttachmentUploadException.Kinds.Final, AttachmentLimit.Refusal(name)); }
            catch (Exception e) when (e is MultipartBody.BuildException or IOException or UnauthorizedAccessException)
            { throw new AttachmentUploadException(AttachmentUploadException.Kinds.Final, $"Couldn’t read “{name}” on this PC."); }
            string answer;
            try
            {
                answer = await session.UploadFileAsync("/api/files/upload-stream", ProfileQuery(profile), built.ContentType,
                    built.FilePath, TimeSpan.FromSeconds(60), progress, ct);
            }
            catch (GatewayException e) when (e.Code == "http" && e.Status is 403 or 404 && !rootRetried)
            {
                // The cached root went stale (moved, permissions): read it again once.
                rootRetried = true;
                _roots.TryRemove(profile, out _);
                continue;
            }
            catch (GatewayException e) when (e.Code == "http" && e.Status == 409 && !conflictRetried)
            {
                conflictRetried = true;
                folderId = Guid.NewGuid().ToString().ToUpperInvariant();
                continue;
            }
            catch (GatewayException e) { throw Map(e, name, reading: false); }
            finally
            {
                try { File.Delete(built.FilePath); } catch (IOException) { }
            }
            var path = J.Parse(answer).Str("path");
            if (string.IsNullOrEmpty(path)) throw AttachmentUploadException.NotStored(name);
            var parent = Slashed(path);
            parent = parent.Contains('/') ? parent[..parent.LastIndexOf('/')] : parent;
            var stagedFolder = parent.EndsWith("/" + folderId) ? parent : folder;
            return new StagedFile(path, stagedFolder);
        }
    }

    /// Deletes a staging folder, best effort, once (no retry loop; spec §3.6).
    public async Task ReleaseAsync(string folder, string profile)
    {
        if (!Slashed(folder).Contains("/" + StagingFolder + "/")) return;
        try
        {
            await session.SendAsync(HttpMethod.Delete, "/api/files", ProfileQuery(profile),
                new JsonObject { ["path"] = folder, ["recursive"] = true }, TimeSpan.FromSeconds(30));
        }
        catch (GatewayException) { }
    }

    /// Gateway failures in the tray's words (AttachmentStager.map).
    public static AttachmentUploadException Map(GatewayException e, string name, bool reading)
    {
        switch (e.Code)
        {
            case "http" when reading:
                return e.Status switch
                {
                    400 or 403 or 404 => AttachmentUploadException.NoFolder(),
                    401 => AttachmentUploadException.Ended(),
                    _ => new(AttachmentUploadException.Kinds.Retryable,
                        $"Couldn’t reach your gateway’s upload folder (gateway error {e.Status}). Try again."),
                };
            case "http":
                return e.Status switch
                {
                    400 => AttachmentUploadException.Refused(name, e.Body),
                    401 => AttachmentUploadException.Ended(),
                    403 or 404 => AttachmentUploadException.NoFolder(),
                    413 => AttachmentUploadException.TooBig(name),
                    _ => AttachmentUploadException.Status(name, e.Status),
                };
            case "offline":
                return AttachmentUploadException.WaitingForConnection();
            case "session-ended":
                return AttachmentUploadException.Ended();
            case "too-large":
                return reading ? AttachmentUploadException.NoFolder() : AttachmentUploadException.NotStored(name);
            default:
                return reading
                    ? new(AttachmentUploadException.Kinds.Retryable, "Couldn’t reach your gateway. Try again.")
                    : AttachmentUploadException.Connection(name);
        }
    }
}
