using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Hermes.Core.Attachments;
using Hermes.Core.Gateways;
using Hermes.Core.Net;

namespace Hermes.Core.Voice;

// The memo's wire pipeline before `prompt.submit` (spec 1x-voice §4.2, V1; HermesKit/Voice/MemoUploader.swift at
// 93f984bb1): the web shell's managed-files staging, never a `data_url` over the socket.
//   (e) GET  /api/config?profile=P                 stt.enabled (a failed read counts as on), in parallel with (a)
//   (a) GET  /api/files?profile=P                  the files root (cached per account and profile)
//   (b) POST /api/files/upload-stream?profile=P    multipart into <root>/.dispatch-attachments/<UUID>/voice-memo.m4a
//   (c) file.attach {session_id, profile, name, path}   (the caller's closure: resume once on 4001)
//   (d) DELETE /api/files?profile=P                the staging folder, when the gateway kept its own copy elsewhere
//   (f) POST /api/audio/transcribe?profile=P       once per recording, kept by memo file
// The result is the memo's reference text; the caller rewrites the bubble and submits it.

/// The gateway calls the memo files need (the Mac's `GatewayClient`). Non-2xx answers throw
/// `GatewayException("http", …, status, body)`; a lost link throws the client's own GatewayException.
public interface IMemoGateway
{
    /// The signed-in account's id (`client.account.id`).
    string AccountId { get; }

    /// Authenticated REST relative to the base URL; the answer's body.
    Task<byte[]> RestAsync(string method, string path, IReadOnlyList<KeyValuePair<string, string>> query, byte[]? body,
        CancellationToken ct);

    /// `GET /api/config` through the client's shared config read (`configData(_:maxAge:)`): `maxAge` zero shares a
    /// read in flight and keeps nothing.
    Task<byte[]> ConfigDataAsync(IReadOnlyList<KeyValuePair<string, string>> query, TimeSpan maxAge, CancellationToken ct);
}

/// REST with an explicit body type and a longer ceiling (multipart uploads, transcription: spec §2.2 R5; the Mac's
/// `GatewayTransfers`). `timeoutSeconds` is clamped to 1…600 by the implementation.
public interface IMemoTransfers : IMemoGateway
{
    Task<byte[]> TransferAsync(string method, string path, IReadOnlyList<KeyValuePair<string, string>> query, byte[]? body,
        string contentType, double timeoutSeconds, CancellationToken ct);
}

public sealed class MemoSendException(string reason) : Exception(reason)
{
    public string Reason { get; } = reason;
}

/// What staging produced: the text to submit for the memo, and what the gateway calls it.
/// `Reference`: `MEDIA:"<path>"\n\nVoice memo transcript: …`, or the gateway's `ref_text` when the path can't be
/// quoted. `GatewayPath`: the gateway's stored copy (null when only `ref_text` came back). `TranscriptFailure`: the
/// transcription call failed with this reason (the memo still goes, with "(unavailable)").
public sealed record StagedMemo(string Reference, string? GatewayPath, string? TranscriptFailure);

/// What the Mac keeps in `MemoUploader`'s statics for the app session: the files roots, the speech-to-text reads in
/// flight, one transcript per recording and the last 8 stagings. The app shares `Shared`; tests make their own.
public sealed class MemoUploadState
{
    public static readonly MemoUploadState Shared = new();

    internal readonly object Gate = new();
    internal readonly Dictionary<string, string> Roots = [];
    internal readonly Dictionary<string, Task<bool>> SttFlights = [];
    /// One paid transcription per recording: the words, by the memo's local path. Missing or failed ones aren't kept.
    internal readonly Dictionary<string, MemoSaid> Transcripts = [];
    internal readonly List<KeyValuePair<string, StagedMemo>> Staged = [];

    public void Reset()
    {
        lock (Gate)
        {
            Roots.Clear();
            SttFlights.Clear();
            Transcripts.Clear();
            Staged.Clear();
        }
    }
}

public sealed class MemoUploader(IMemoGateway client, MemoUploadState? state = null)
{
    public const string StagingFolder = AttachmentStager.StagingFolder;
    public static readonly IReadOnlySet<string> AttachKeys = new HashSet<string> { "session_id", "profile", "path", "data_url", "name" };
    /// Retries reuse what an earlier attempt staged into the same chat (up to 8, keyed by memo file and stored chat).
    public const int MaxKept = 8;
    /// Upload ceiling (seconds).
    public const double UploadTimeout = 120;
    /// The staging folder's delete (seconds).
    public const double CleanupTimeout = 30;

    public IMemoGateway Client { get; } = client;
    public MemoUploadState State { get; } = state ?? MemoUploadState.Shared;

    /// The fire-and-forget deletes this uploader started (tests wait for them).
    private readonly List<Task> _cleanups = [];
    public IReadOnlyList<Task> Cleanups { get { lock (_cleanups) return _cleanups.ToArray(); } }

    public static string StagedKey(string memoPath, string? storedId) => $"{memoPath}|{storedId ?? ""}";

    public StagedMemo? KeptStage(string memoPath, string? storedId)
    {
        var key = StagedKey(memoPath, storedId);
        lock (State.Gate) return State.Staged.LastOrDefault(p => p.Key == key).Value;
    }

    public void KeepStage(StagedMemo value, string memoPath, string? storedId)
    {
        var key = StagedKey(memoPath, storedId);
        lock (State.Gate)
        {
            State.Staged.RemoveAll(p => p.Key == key);
            State.Staged.Add(new(key, value));
            if (State.Staged.Count > MaxKept) State.Staged.RemoveRange(0, State.Staged.Count - MaxKept);
        }
    }

    public void ForgetStage(string memoPath, string? storedId)
    {
        var key = StagedKey(memoPath, storedId);
        lock (State.Gate) State.Staged.RemoveAll(p => p.Key == key);
    }

    private string AccountId => Client.AccountId;

    internal static List<KeyValuePair<string, string>> ProfileQuery(string? profile) =>
        string.IsNullOrEmpty(profile) ? [] : [new("profile", profile)];

    // MARK: Pipeline

    /// Steps (e), (a)–(d), (f). Throws `MemoSendException` when the memo can't reach the gateway (nothing was submitted;
    /// the memo returns as a draft). A retry into the same chat reuses what an earlier attempt staged, unless that
    /// attempt went without its transcript. A cancelled token (Stop) throws OperationCanceledException between steps and
    /// never pays for a transcription.
    public async Task<StagedMemo> StageAsync(MemoFile memo, string? profile, string? storedId,
        Func<JsonObject, CancellationToken, Task<JsonNode?>> attach, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        if (KeptStage(memo.Path, storedId) is { } kept && !MemoText.TranscriptMissing(kept.Reference)) return kept;
        var file = memo.Path;
        if (!File.Exists(file))
            throw new MemoSendException($"The voice memo’s recording is no longer on this {DeviceWord.Name}.");
        // [live words] Words this device heard while recording go as the transcript: no speech-to-text check, no paid call.
        var phoneWords = memo.Words is { } w && VoiceMemo.TrimWhitespaceAndNewlines(w) is { Length: > 0 } t ? t : null;
        // (e) in parallel with (a).
        var stt = phoneWords != null ? Task.FromResult(true) : SttEnabledAsync(profile);
        (string Path, string Folder) staging;
        try
        {
            var root = await FilesRootAsync(profile, ct);
            ct.ThrowIfCancellationRequested();
            staging = await UploadAsync(file, root, profile, ct);
        }
        catch (Exception error)
        {
            if (ct.IsCancellationRequested) throw new OperationCanceledException(ct);
            lock (State.Gate) State.Roots.Remove($"{AccountId}|{profile ?? ""}");
            throw new MemoSendException(Words(error, "upload the voice memo"));
        }
        if (ct.IsCancellationRequested)
        {
            Cleanup(staging.Folder, profile);
            throw new OperationCanceledException(ct);
        }
        // (c)
        var name = Path.GetFileName(memo.Path);
        var parameters = new JsonObject { ["name"] = name, ["path"] = staging.Path };
        if (!string.IsNullOrEmpty(profile)) parameters["profile"] = profile;
        JsonNode? result;
        try
        {
            result = await attach(parameters, ct);
        }
        catch (Exception error)
        {
            // Nothing keeps the uploaded copy for a retry (each one uploads into a new staging folder): it goes now, or
            // every failed attach would leave one behind on the gateway.
            Cleanup(staging.Folder, profile);
            if (ct.IsCancellationRequested || error is OperationCanceledException) throw new OperationCanceledException(ct);
            throw new MemoSendException(Words(error, "attach the voice memo"));
        }
        var stored = result.Str("path");
        // (d) The staged copy goes once the gateway stored its own copy elsewhere (fire-and-forget).
        if (StagedCopyReleased(result.Bool("uploaded"), stored, staging.Folder)) Cleanup(staging.Folder, profile);
        if (MemoText.GatewayMemoPath(stored) is not { } gatewayPath)
        {
            // The directive can't carry this path: the gateway's own ref goes, with no transcript and no STT call.
            var reference = result.Str("ref_text") ?? (stored != null ? $"@file:{stored}" : "");
            var value = new StagedMemo(reference, null, null);
            KeepStage(value, memo.Path, storedId);
            return value;
        }
        // (f) Never paid for once Stop cancelled the send.
        if (ct.IsCancellationRequested)
        {
            throw new OperationCanceledException(ct);
        }
        MemoSaid said;
        string? failure = null;
        MemoSaid? known;
        lock (State.Gate) known = State.Transcripts.GetValueOrDefault(memo.Path);
        if (phoneWords != null) said = MemoSaid.Words(phoneWords);
        else if (known != null) said = known;
        else if (!await stt) said = MemoSaid.Off;
        else if (ct.IsCancellationRequested) throw new OperationCanceledException(ct);
        else
        {
            var answer = await TranscribeAsync(file, memo.Mime, profile, ct);
            if (ct.IsCancellationRequested) throw new OperationCanceledException(ct);
            said = answer.Said;
            failure = answer.Failure;
            if (said.Kind != MemoSaidKind.Failed) lock (State.Gate) State.Transcripts[memo.Path] = said;
        }
        var staged = new StagedMemo(MemoText.Reference(gatewayPath, said), gatewayPath, failure);
        KeepStage(staged, memo.Path, storedId);
        return staged;
    }

    /// A staged copy can go once the gateway stored its own copy elsewhere; one it references in place (uploaded false,
    /// or its path still inside the staging folder) must stay.
    public static bool StagedCopyReleased(bool? uploaded, string? storedPath, string folder) =>
        AttachmentStager.StagedCopyReleased(uploaded, storedPath, folder);

    // MARK: (e) Speech-to-text switch

    /// `stt.enabled` from `/api/config` (`!== false` is on; any failure counts as on). Concurrent lookups for one
    /// profile share one request; nothing is kept across sends.
    public Task<bool> SttEnabledAsync(string? profile)
    {
        var key = $"{AccountId}|{profile ?? ""}";
        var flight = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (State.Gate)
        {
            if (State.SttFlights.TryGetValue(key, out var running)) return running;
            State.SttFlights[key] = flight.Task;
        }
        // Started here, so the read goes out before the files root's (the Mac's `Task {}` in parallel with (a)).
        _ = ReadSttAsync(profile, key, flight);
        return flight.Task;
    }

    private async Task ReadSttAsync(string? profile, string key, TaskCompletionSource<bool> flight)
    {
        var enabled = true;
        try
        {
            // [load-cache] maxAge 0: shares a read in flight, keeps nothing across sends.
            var data = await Client.ConfigDataAsync(ProfileQuery(profile), TimeSpan.Zero, CancellationToken.None);
            enabled = JsonNode.Parse(Encoding.UTF8.GetString(data)).Get("stt").Bool("enabled") != false;
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            enabled = true;
        }
        finally
        {
            lock (State.Gate) State.SttFlights.Remove(key);
            flight.TrySetResult(enabled);
        }
    }

    // MARK: (a) Files root

    public async Task<string> FilesRootAsync(string? profile, CancellationToken ct = default)
    {
        var key = $"{AccountId}|{profile ?? ""}";
        lock (State.Gate)
            if (State.Roots.TryGetValue(key, out var known)) return known;
        var data = await Client.RestAsync("GET", "/api/files", ProfileQuery(profile), null, ct);
        var root = ParseOrNull(data).Str("path");
        if (string.IsNullOrEmpty(root)) throw new MemoSendException("Your gateway didn’t say where to put uploads.");
        lock (State.Gate) State.Roots[key] = root;
        return root;
    }

    // MARK: (b) Upload

    public async Task<(string Path, string Folder)> UploadAsync(string file, string root, string? profile, CancellationToken ct = default)
    {
        if (Client is not IMemoTransfers transfers) throw new MemoSendException("This gateway can’t take uploads.");
        var filename = Path.GetFileName(file);
        var trimmedRoot = root.EndsWith('/') ? root[..^1] : root;
        var folder = $"{trimmedRoot}/{StagingFolder}/{Guid.NewGuid().ToString().ToUpperInvariant()}";
        var destination = $"{folder}/{filename}";
        var boundary = "hermes-" + Guid.NewGuid().ToString().ToUpperInvariant();
        var body = await MultipartBodyAsync(file, destination, filename, boundary, ct);
        var data = await transfers.TransferAsync("POST", "/api/files/upload-stream", ProfileQuery(profile), body,
            $"multipart/form-data; boundary={boundary}", UploadTimeout, ct);
        var path = ParseOrNull(data).Str("path");
        if (string.IsNullOrEmpty(path)) throw new MemoSendException("The upload didn’t finish on your gateway.");
        return (path, folder);
    }

    /// The multipart body, byte-exact to W:ios/App/Shared/HermesTransportShared.swift:281-299 (built off the UI
    /// thread; a memo is at most a few MB, the attachment limit 32 MB).
    public static Task<byte[]> MultipartBodyAsync(string file, string destination, string filename, string boundary,
        CancellationToken ct = default) => Task.Run(async () =>
    {
        var bytes = await File.ReadAllBytesAsync(file, ct);
        if (bytes.Length > MemoPolicy.DefaultLimitBytes) throw new MemoSendException("The voice memo is too large to upload.");
        using var body = new MemoryStream();
        void Text(string s) => body.Write(Encoding.UTF8.GetBytes(s));
        Text($"--{boundary}\r\nContent-Disposition: form-data; name=\"path\"\r\n\r\n{destination}\r\n");
        Text($"--{boundary}\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\nfalse\r\n");
        Text($"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{filename}\"\r\nContent-Type: application/octet-stream\r\n\r\n");
        body.Write(bytes);
        Text($"\r\n--{boundary}--\r\n");
        return body.ToArray();
    }, ct);

    // MARK: (d) Cleanup

    /// Deletes a staging folder in the background (`DELETE /api/files` `{"path":…,"recursive":true}`), best effort.
    public void Cleanup(string folder, string? profile)
    {
        var task = Task.Run(() => CleanupAsync(folder, profile));
        lock (_cleanups) _cleanups.Add(task);
    }

    public async Task CleanupAsync(string folder, string? profile)
    {
        if (Client is not IMemoTransfers transfers) return;
        var body = JsonSerializer.SerializeToUtf8Bytes(new JsonObject { ["path"] = folder, ["recursive"] = true });
        try
        {
            await transfers.TransferAsync("DELETE", "/api/files", ProfileQuery(profile), body, "application/json", CleanupTimeout,
                CancellationToken.None);
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            // AppLog.swallowed("transfer", "clean up a voice memo's staging folder"): nothing for the person to do.
        }
    }

    // MARK: (f) Transcribe

    /// The transcription's ceiling: 180–600 s, 0.1 ms per byte of the data URL.
    public static double TranscribeTimeout(int dataUrlLength) => Math.Min(600, Math.Max(180, dataUrlLength * 0.0001));

    /// One call. `ok == false` or any error → `Failed` with the gateway's reason (the memo still goes).
    public async Task<(MemoSaid Said, string? Failure)> TranscribeAsync(string file, string mime, string? profile,
        CancellationToken ct = default)
    {
        if (Client is not IMemoTransfers transfers) return (MemoSaid.Failed, "This gateway can’t transcribe.");
        try
        {
            var (body, length) = await TranscribeBodyAsync(file, Mime(file, mime), ct);
            // Stop while the body was encoded: the paid call never goes out.
            if (ct.IsCancellationRequested) return (MemoSaid.Failed, null);
            var data = await transfers.TransferAsync("POST", "/api/audio/transcribe", ProfileQuery(profile), body,
                "application/json", TranscribeTimeout(length), ct);
            var answer = JsonNode.Parse(Encoding.UTF8.GetString(data));
            if (answer.Bool("ok") == false)
                return (MemoSaid.Failed, answer.Str("detail") ?? answer.Str("error") ?? "The gateway could not transcribe the memo.");
            var words = VoiceMemo.TrimWhitespaceAndNewlines(answer.Str("transcript") ?? "");
            return (words.Length == 0 ? MemoSaid.Empty : MemoSaid.Words(words), null);
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            if (error is OperationCanceledException && ct.IsCancellationRequested) return (MemoSaid.Failed, null);
            return (MemoSaid.Failed, Words(error, "transcribe the voice memo"));
        }
    }

    /// The mime as the web reads it (`UTType(filenameExtension:)?.preferredMIMEType`), else `audio/mp4`. The kinds
    /// Hermes names in its own table come first: UTType says `audio/vnd.wave` for a WAV, which Hermes would save as
    /// `.webm` before transcribing (hermes_cli/web_routers/audio.py `_AUDIO_MIME_EXTENSIONS`). The rest is what UTType
    /// answers on the Mac (macOS 27) for the audio extensions a memo can have; Windows' registry differs, so the table
    /// is fixed here rather than read from the OS.
    public static string Mime(string file, string fallback)
    {
        var ext = MemoPlaybackCache.PathExtension(file.Replace('\\', '/')).ToLowerInvariant();
        return ext switch
        {
            "m4a" => "audio/x-m4a",
            "wav" => "audio/wav",
            "mp3" => "audio/mpeg",
            _ => UtTypeMime.GetValueOrDefault(ext) ?? (fallback.Length == 0 ? "audio/mp4" : fallback),
        };
    }

    private static readonly Dictionary<string, string> UtTypeMime = new()
    {
        ["aac"] = "audio/aac",
        ["ogg"] = "audio/ogg",
        ["opus"] = "audio/ogg",
        ["flac"] = "audio/flac",
        ["aiff"] = "audio/aiff",
        ["aif"] = "audio/aiff",
        ["amr"] = "audio/amr",
        ["webm"] = "video/webm",
        ["mp4"] = "video/mp4",
        ["3gp"] = "video/3gpp",
    };

    /// `{"data_url":"data:<mime>;base64,…","mime_type":"<mime>"}`, encoded off the UI thread; with the data URL's length.
    public static Task<(byte[] Body, int Length)> TranscribeBodyAsync(string file, string mime, CancellationToken ct = default) =>
        Task.Run(async () =>
        {
            var bytes = await File.ReadAllBytesAsync(file, ct);
            var dataUrl = $"data:{mime};base64," + Convert.ToBase64String(bytes);
            var body = JsonSerializer.SerializeToUtf8Bytes(new JsonObject { ["data_url"] = dataUrl, ["mime_type"] = mime });
            return (body, Encoding.UTF8.GetByteCount(dataUrl));
        }, ct);

    // MARK: Words

    /// A failure in words the owner can read (spec §1 "Readable errors").
    public static string Words(Exception error, string what)
    {
        if (error is MemoSendException memo) return memo.Reason;
        if (error is GatewayException { Code: "http" } http)
        {
            var detail = http.Body is { } b ? ParseOrNull(Encoding.UTF8.GetBytes(b)) is { } j ? j.Str("detail") ?? j.Str("error") : null : null;
            return http.Status switch
            {
                403 => $"Couldn’t {what}: your gateway’s files folder isn’t writable{(detail != null ? $" ({detail})" : "")}.",
                413 => $"Couldn’t {what}: it’s too large for your gateway.",
                _ when detail != null => $"Couldn’t {what}: {detail}",
                _ => $"Couldn’t {what}. {PlainWords(http.Status)}",
            };
        }
        if (error is GatewayException { Code: "rpc" } rpc) return $"Couldn’t {what}: {rpc.Message}";
        // The Mac's LocalizedError branch (a URLError's description): the client's own words for a lost link or a
        // timeout.
        if (error is GatewayException other && other.Message.Length > 0) return $"Couldn’t {what}: {other.Message}";
        return $"Couldn’t {what}. Try again.";
    }

    /// HTTPError.plainWords (HermesKit/Net/GatewayFailure.swift at 93f984bb1).
    public static string PlainWords(int status) => status switch
    {
        400 or 422 => "Your gateway didn’t accept that request.",
        401 or 403 => "Your gateway didn’t allow that.",
        404 => "Your gateway doesn’t have that.",
        408 or 504 or 524 => "Your gateway took too long to answer. Try again in a moment.",
        409 => "Something changed on your gateway at the same time. Try again.",
        413 => "That’s too large for your gateway.",
        429 => "Your gateway is busy right now. Wait a minute, then try again.",
        502 or 503 or (>= 520 and <= 523) or 525 or 526 or 530 => "Hermes isn’t answering right now. It may be restarting — try again in a moment.",
        _ => $"Your gateway ran into a problem (error {status}). Try again.",
    };

    private static JsonNode? ParseOrNull(byte[] data)
    {
        try { return JsonNode.Parse(Encoding.UTF8.GetString(data)); }
        catch (JsonException) { return null; }
    }
}
