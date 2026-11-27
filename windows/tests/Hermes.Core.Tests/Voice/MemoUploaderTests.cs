// [WIN-VOICE-FILES-UPLOAD] Tests/Voice/MemoUploaderTests.swift at 93f984bb1, case for case at the uploader's level. The
// Mac drives each case through LiveChatSession (optimistic bubble → staging → rewrite → prompt.submit); Windows has no
// memo send in its chat session yet, so each port calls MemoUploader.StageAsync the way the session does (its attach
// closure adds the runtime session id) and checks everything the uploader owns: the call order, the wire params, the
// staging folder's delete, the transcript and the text the session would submit (`MemoText.Prompt`). The session's own
// half of a case (bubble, watchdog, draft chip, Couldn't Send card, queue, notices) is named in each test's comment.
// Not ported (session-only, nothing of the uploader in them): staleRuntimeResumesOnceWithoutASecondUpload (the 4001
// resume is the session's attach closure), aLinkClosedForTheBackgroundAttachesAgainOnTheReturn, aQueuedMemoWaitsWhileAReplyRuns,
// deletingAQueuedMemoThrowsItAway, aMemoSteersIntoTheRunningReply, aMemoSteerTurnedDownJoinsTheQueue, and from
// "Memo sends: Stop, leaving, new chats, account switches": leavingAnAppChatKeepsAQueuedMemoInTheQueue,
// leavingWithAQueuedMemoKeepsItAsADraft, aBrandNewChatKeepsItsStageUnderItsStoredId, anAccountSwitchMidSendWritesNothingIntoTheOtherAccount.

using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Net;
using Hermes.Core.Voice;

namespace Hermes.Core.Tests.Voice;

public sealed class MemoUploaderTests : IDisposable
{
    private const string Stored = "20260929_120000_aabbcc02";
    private readonly VoiceTestStores _t = new();
    public void Dispose() => _t.Dispose();

    private (VoiceFakeClient Client, MemoFile Memo, MemoUploader Uploader) SetUp()
    {
        var client = new VoiceFakeClient();
        _t.Activate(client.AccountId);
        return (client, _t.Recording(client.AccountId), new MemoUploader(client, new MemoUploadState()));
    }

    private static Task<StagedMemo> Stage(MemoUploader uploader, VoiceFakeClient client, MemoFile memo, string? stored = Stored,
        CancellationToken ct = default) => uploader.StageAsync(memo, "ivy", stored, client.Attach, ct);

    private static string Parent(string path) => path[..path.LastIndexOf('/')];

    // Session half not ported: the optimistic bubble, the watchdog, prompt.submit and the ack's adopt into the cache.
    [Fact]
    public async Task CallOrderParamsAndText()
    {
        var (client, memo, uploader) = SetUp();
        var staged = await Stage(uploader, client, memo);
        Assert.True(await VoiceFixtures.WaitUntil(() => client.Entries("DELETE /api/files").Count == 1));
        var kinds = client.Kinds;
        Assert.Equal(new HashSet<string> { "GET /api/config", "GET /api/files" }, kinds.Take(2).ToHashSet());
        int At(string kind) => kinds.ToList().IndexOf(kind);
        Assert.True(At("POST /api/files/upload-stream") > 1);
        Assert.True(At("rpc file.attach") > At("POST /api/files/upload-stream"));
        Assert.True(At("DELETE /api/files") > At("rpc file.attach"));
        Assert.True(At("POST /api/audio/transcribe") > At("rpc file.attach"));
        var attach = client.Entries("rpc file.attach")[0].Params!;
        Assert.Equal(new HashSet<string> { "session_id", "profile", "name", "path" }, attach.Select(p => p.Key).ToHashSet());
        Assert.Equal(VoiceFakeClient.Rid, attach.Str("session_id"));
        Assert.Equal("ivy", attach.Str("profile"));
        Assert.Equal("voice-memo.wav", attach.Str("name"));
        var stagedPath = attach.Str("path")!;
        Assert.StartsWith("/Users/owner/.dispatch-attachments/", stagedPath);
        Assert.EndsWith("/voice-memo.wav", stagedPath);
        var delete = client.Entries("DELETE /api/files")[0].BodyJson;
        Assert.Equal(Parent(stagedPath), delete.Str("path"));
        Assert.True(delete.Bool("recursive"));
        foreach (var entry in client.Log.Where(e => e.Kind.StartsWith("GET /api/files") || e.Kind.StartsWith("POST") || e.Kind.StartsWith("DELETE")))
            Assert.True(entry.Query.SequenceEqual([new KeyValuePair<string, string>("profile", "ivy")]), $"{entry.Kind} names the chat's profile");
        var transcribe = client.Entries("POST /api/audio/transcribe")[0].BodyJson;
        Assert.Equal("audio/wav", transcribe.Str("mime_type"));
        Assert.StartsWith("data:audio/wav;base64,UklGR", transcribe.Str("data_url"));
        const string gatewayPath = "/Users/owner/.hermes/profiles/ivy/attachments/voice-memo.wav";
        Assert.Equal(gatewayPath, staged.GatewayPath);
        Assert.Equal($"MEDIA:\"{gatewayPath}\"\n\nVoice memo transcript: Pick up milk on the way home.", MemoText.Prompt(staged.Reference, ""));
        Assert.Null(staged.TranscriptFailure);
        // The wire's content types and the transcription's ceiling.
        Assert.StartsWith("multipart/form-data; boundary=hermes-", client.Entries("POST /api/files/upload-stream")[0].ContentType);
        Assert.Equal("application/json", client.Entries("POST /api/audio/transcribe")[0].ContentType);
        Assert.Equal("application/json", client.Entries("DELETE /api/files")[0].ContentType);
    }

    [Fact]
    public async Task MultipartBodyIsByteExact()
    {
        var file = Path.Combine(Path.GetTempPath(), $"voice-memo-{Guid.NewGuid()}.m4a");
        File.WriteAllBytes(file, [0x00, 0x01, 0xFF]);
        try
        {
            var body = await MemoUploader.MultipartBodyAsync(file, "/r/.dispatch-attachments/U2/voice-memo.m4a", "voice-memo.m4a", "hermes-U1");
            var expected = new List<byte>();
            expected.AddRange(Encoding.UTF8.GetBytes("--hermes-U1\r\nContent-Disposition: form-data; name=\"path\"\r\n\r\n/r/.dispatch-attachments/U2/voice-memo.m4a\r\n"));
            expected.AddRange(Encoding.UTF8.GetBytes("--hermes-U1\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\nfalse\r\n"));
            expected.AddRange(Encoding.UTF8.GetBytes("--hermes-U1\r\nContent-Disposition: form-data; name=\"file\"; filename=\"voice-memo.m4a\"\r\nContent-Type: application/octet-stream\r\n\r\n"));
            expected.AddRange([0x00, 0x01, 0xFF]);
            expected.AddRange(Encoding.UTF8.GetBytes("\r\n--hermes-U1--\r\n"));
            Assert.Equal(expected.ToArray(), body);
        }
        finally { File.Delete(file); }
    }

    [Fact]
    public async Task StagingCopyStaysWhenTheGatewayKeptItInPlace()
    {
        Assert.True(MemoUploader.StagedCopyReleased(true, "/h/.hermes/attachments/v.m4a", "/h/.dispatch-attachments/U"));
        Assert.False(MemoUploader.StagedCopyReleased(false, "/h/.hermes/attachments/v.m4a", "/h/.dispatch-attachments/U"));
        Assert.False(MemoUploader.StagedCopyReleased(true, "/h/.dispatch-attachments/U/v.m4a", "/h/.dispatch-attachments/U"));
        Assert.False(MemoUploader.StagedCopyReleased(true, "/h/.dispatch-attachments/U", "/h/.dispatch-attachments/U"));
        Assert.False(MemoUploader.StagedCopyReleased(null, "/x.m4a", "/h/.dispatch-attachments/U"));

        var (client, memo, uploader) = SetUp();
        client.OnCall((method, parameters, attempt) => method == "file.attach"
            ? new JsonObject
            {
                ["attached"] = true, ["name"] = "voice-memo.wav", ["path"] = parameters.Str("path") ?? "",
                ["ref_text"] = "@file:x", ["uploaded"] = false,
            }
            : VoiceFakeClient.DefaultCall(method, parameters, attempt));
        await Stage(uploader, client, memo);
        await Task.Delay(150);
        await Task.WhenAll(uploader.Cleanups);
        Assert.Empty(client.Entries("DELETE /api/files")); // no delete when uploaded is false
    }

    [Fact]
    public async Task SttOffSendsTheOffWordingWithoutTranscribing()
    {
        var (client, memo, uploader) = SetUp();
        client.OnRest((method, path, body) => path == "/api/config"
            ? Encoding.UTF8.GetBytes("""{"stt":{"enabled":false}}""")
            : VoiceFakeClient.DefaultRest(method, path, body));
        var staged = await Stage(uploader, client, memo);
        Assert.Empty(client.Entries("POST /api/audio/transcribe"));
        Assert.EndsWith("Voice memo transcript: (unavailable: speech-to-text is off on the gateway)\n\ntyped too",
            MemoText.Prompt(staged.Reference, "typed too"));
    }

    [Fact]
    public async Task AFailedConfigReadCountsAsOn()
    {
        var (client, memo, uploader) = SetUp();
        client.OnRest((method, path, body) => path == "/api/config"
            ? throw new GatewayException("http", "HTTP 500", 500)
            : VoiceFakeClient.DefaultRest(method, path, body));
        await Stage(uploader, client, memo);
        Assert.Single(client.Entries("POST /api/audio/transcribe"));
    }

    // Session half not ported: the one transcription notice the chat posts (MemoSessionNotice).
    [Fact]
    public async Task TranscriptionErrorSendsUnavailableWithOneNotice()
    {
        var (client, memo, uploader) = SetUp();
        client.OnRest((method, path, body) => path == "/api/audio/transcribe"
            ? throw new GatewayException("http", "HTTP 500", 500, """{"detail":"Transcription failed"}""")
            : VoiceFakeClient.DefaultRest(method, path, body));
        var staged = await Stage(uploader, client, memo);
        Assert.EndsWith("Voice memo transcript: (unavailable)", MemoText.Prompt(staged.Reference, ""));
        Assert.Contains("Transcription failed", staged.TranscriptFailure);
        Assert.Equal("Couldn’t transcribe the voice memo: Transcription failed", staged.TranscriptFailure);
    }

    [Fact]
    public async Task AnUnquotablePathSendsTheGatewaysRef()
    {
        var (client, memo, uploader) = SetUp();
        client.OnCall((method, parameters, attempt) => method == "file.attach"
            ? new JsonObject
            {
                ["attached"] = true, ["name"] = "voice\"memo.wav", ["path"] = "/Users/owner/at\"tach/voice-memo.wav",
                ["ref_text"] = "@file:\"weird\"", ["uploaded"] = true,
            }
            : VoiceFakeClient.DefaultCall(method, parameters, attempt));
        var staged = await Stage(uploader, client, memo);
        Assert.Equal("@file:\"weird\"", MemoText.Prompt(staged.Reference, ""));
        Assert.Null(staged.GatewayPath);
        Assert.Empty(client.Entries("POST /api/audio/transcribe"));
    }

    // Session half not ported: the draft coming back (memoDraft) and the Couldn't Send card.
    [Fact]
    public async Task ALinkLostOnScreenIsStillRefused()
    {
        var (client, memo, uploader) = SetUp();
        client.OnCall((method, parameters, attempt) => method == "file.attach"
            ? throw GatewayException.ConnectionLost("file.attach")
            : VoiceFakeClient.DefaultCall(method, parameters, attempt));
        var error = await Assert.ThrowsAsync<MemoSendException>(() => Stage(uploader, client, memo));
        // [WIN-CONNLOST-WORDS] MemoUploader.words reads the RPCError's own message, the client's line.
        Assert.Equal("Couldn’t attach the voice memo: connection closed before the gateway answered: file.attach", error.Reason);
        Assert.Single(client.Entries("rpc file.attach"));
    }

    // Session half not ported: the refusal (prompt.submit 4000) handing the draft and its words back.
    [Fact]
    public async Task ARefusalReturnsTheDraftAndARetryPaysOnce()
    {
        var (client, memo, uploader) = SetUp();
        var first = await Stage(uploader, client, memo);
        Assert.True(File.Exists(memo.Path)); // the recording stays on the device
        // Retry into the same chat: nothing is uploaded, attached or transcribed again.
        var again = await Stage(uploader, client, memo);
        Assert.Equal(first, again);
        Assert.Single(client.Entries("POST /api/files/upload-stream"));
        Assert.Single(client.Entries("rpc file.attach"));
        Assert.Single(client.Entries("POST /api/audio/transcribe"));
    }

    [Fact]
    public async Task ARetryIntoAnotherChatUploadsAgain()
    {
        var (client, memo, uploader) = SetUp();
        await Stage(uploader, client, memo);
        await Stage(uploader, client, memo, stored: "20260929_120000_ffffff09");
        Assert.Equal(2, client.Entries("POST /api/files/upload-stream").Count);
        // The transcript is kept by memo file: still one paid call.
        Assert.Single(client.Entries("POST /api/audio/transcribe"));
    }

    // Session half not ported: the draft chip, isRunning and the pending bubble.
    [Fact]
    public async Task AFilesFailureRefusesBeforeSubmitting()
    {
        var (client, memo, uploader) = SetUp();
        client.OnRest((method, path, body) => path == "/api/files"
            ? throw new GatewayException("http", "HTTP 500", 500, """{"detail":"Synthetic files failure"}""")
            : VoiceFakeClient.DefaultRest(method, path, body));
        var error = await Assert.ThrowsAsync<MemoSendException>(() => Stage(uploader, client, memo));
        Assert.Empty(client.Entries("rpc file.attach"));
        // The gateway's own reason, not a bare status number (audit 10-3).
        Assert.Contains("upload the voice memo", error.Reason);
        Assert.Contains("Synthetic files failure", error.Reason);
    }

    [Fact]
    public async Task AFailedAttachRemovesWhatItUploaded()
    {
        var (client, memo, uploader) = SetUp();
        client.OnCall((method, parameters, attempt) => method == "file.attach"
            ? throw new GatewayException("rpc", "Attach refused.", rpcCode: 5000)
            : VoiceFakeClient.DefaultCall(method, parameters, attempt));
        var error = await Assert.ThrowsAsync<MemoSendException>(() => Stage(uploader, client, memo));
        Assert.Equal("Couldn’t attach the voice memo: Attach refused.", error.Reason);
        // The retry uploads again (nothing was kept), so the copy this attempt staged is deleted, not left behind.
        Assert.True(await VoiceFixtures.WaitUntil(() => client.Entries("DELETE /api/files").Count == 1));
        var staged = client.Entries("rpc file.attach")[0].Params.Str("path")!;
        Assert.Equal(Parent(staged), client.Entries("DELETE /api/files")[0].BodyJson.Str("path"));
        Assert.True(File.Exists(memo.Path)); // the recording stays on the device
    }

    // MemoSendLifecycleTests.stopWhileStagingHandsTheMemoBackAtOnce, the uploader's half: Stop while the memo uploads
    // ends the staging with a cancellation; it never attaches, transcribes or submits. Session half not ported: the
    // draft back at once, no bubble, the turn settled, "Stopped before sending", the next text's watchdog.
    [Fact]
    public async Task StopWhileStagingHandsTheMemoBackAtOnce()
    {
        var (client, memo, uploader) = SetUp();
        client.Delay("POST /api/files/upload-stream", TimeSpan.FromMilliseconds(600));
        using var stop = new CancellationTokenSource();
        var staging = Stage(uploader, client, memo, ct: stop.Token);
        Assert.True(await VoiceFixtures.WaitUntil(() => client.Entries("POST /api/files/upload-stream").Count == 1));
        stop.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => staging);
        await Task.Delay(1200);
        Assert.Empty(client.Entries("rpc file.attach"));
        Assert.Empty(client.Entries("POST /api/audio/transcribe"));
        Assert.True(File.Exists(memo.Path));
    }

    // Windows additions: the uploader's own rules the Mac covers through the session.
    [Fact]
    public void WordsAndMimeAreTheMacs()
    {
        Assert.Equal("Couldn’t upload the voice memo: your gateway’s files folder isn’t writable (read-only).",
            MemoUploader.Words(new GatewayException("http", "HTTP 403", 403, """{"detail":"read-only"}"""), "upload the voice memo"));
        Assert.Equal("Couldn’t upload the voice memo: your gateway’s files folder isn’t writable.",
            MemoUploader.Words(new GatewayException("http", "HTTP 403", 403), "upload the voice memo"));
        Assert.Equal("Couldn’t upload the voice memo: it’s too large for your gateway.",
            MemoUploader.Words(new GatewayException("http", "HTTP 413", 413), "upload the voice memo"));
        Assert.Equal("Couldn’t upload the voice memo. Your gateway ran into a problem (error 500). Try again.",
            MemoUploader.Words(new GatewayException("http", "HTTP 500", 500), "upload the voice memo"));
        Assert.Equal("Couldn’t upload the voice memo. Try again.", MemoUploader.Words(new InvalidOperationException(), "upload the voice memo"));
        Assert.Equal("The upload didn’t finish on your gateway.", MemoUploader.Words(new MemoSendException("The upload didn’t finish on your gateway."), "x"));
        Assert.Equal("audio/x-m4a", MemoUploader.Mime("/m/voice-memo.m4a", ""));
        Assert.Equal("audio/wav", MemoUploader.Mime("/m/voice-memo.WAV", ""));
        Assert.Equal("audio/mpeg", MemoUploader.Mime("/m/a.mp3", ""));
        Assert.Equal("audio/ogg", MemoUploader.Mime("/m/a.opus", ""));
        Assert.Equal("audio/x-caf", MemoUploader.Mime("/m/a.caf", "audio/x-caf"));
        Assert.Equal("audio/mp4", MemoUploader.Mime("/m/a.caf", ""));
        Assert.Equal(180, MemoUploader.TranscribeTimeout(1000));
        Assert.Equal(600, MemoUploader.TranscribeTimeout(100_000_000));
        Assert.Equal(250, MemoUploader.TranscribeTimeout(2_500_000));
    }

    [Fact]
    public async Task MissingRecordingAndRootAreRefusedInWords()
    {
        var (client, memo, uploader) = SetUp();
        File.Delete(memo.Path);
        var gone = await Assert.ThrowsAsync<MemoSendException>(() => Stage(uploader, client, memo));
        Assert.Equal("The voice memo’s recording is no longer on this PC.", gone.Reason);
        var memo2 = _t.Recording(client.AccountId);
        client.OnRest((method, path, body) => path == "/api/files" && method == "GET"
            ? Encoding.UTF8.GetBytes("{}") : VoiceFakeClient.DefaultRest(method, path, body));
        var noRoot = await Assert.ThrowsAsync<MemoSendException>(() => Stage(uploader, client, memo2));
        Assert.Equal("Your gateway didn’t say where to put uploads.", noRoot.Reason);
    }
}
