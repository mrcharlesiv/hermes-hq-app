// [WIN-MEMO-SEND-WIRE] The memo pipeline's REST over the real HermesClient/GatewaySession (HermesMemoGateway), against a
// loopback stand-in of scripts/fixtures/voice-gateway.py at 93f984bb1: GET /api/files, POST /api/files/upload-stream
// (parsed as multipart, as the fixture's email parser reads it), DELETE /api/files with a JSON body, GET /api/config with
// stt per profile, POST /api/audio/transcribe with Hermes' validation, GET /api/fs/download, and the /api/ws socket for
// file.attach and prompt.submit. Each request is recorded with its method, path, query, headers and body bytes.
// Synthetic data only: a made-up password account on 127.0.0.1, the /Users/owner root, a sine WAV.
//
// Ported case for case (Tests/Voice/VoiceLiveFixtureTests.swift, A-L1…A-L3): aMemoGoesEndToEndExactlyOnce,
// sttOffStoresTheOffWording, aSeededMemoDownloadsPlaysAndComputes (the download and the 404; the AVAudioPlayer
// duration and the waveform's compute need the Windows audio decoder, not here). (Tests/Offline/LoadCacheTests.swift,
// SharedConfigReads) readersJoinOneReadAndReuseItBriefly, aKeptAnswerExpires, aWriteDropsWhatIsKeptAndWhatIsInFlight,
// aFailedReadIsNotKept, theClientsDefaultReadsDirectly (here: the live adapter shares, the fake reads every time).
// Added per request shape and failure: the wire of each call (method, path, query, Content-Type, body bytes), the
// 64 KiB body cap, every status as an "http" failure (429 too, as the Mac's HTTPError), a 401 refreshing once with the
// same bytes, the clamps, an unreachable gateway, a cancelled call, and a write dropping the kept config.

using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Transcripts;
using Hermes.Core.Voice;

namespace Hermes.Core.Tests.Voice;

[Collection("memo-send")]
public sealed class MemoGatewayAdapterTests : IDisposable
{
    private readonly VoiceTestStores _stores = new();

    public void Dispose() => _stores.Dispose();

    private const string Root = "/Users/owner";
    private const string Rid = "5cc537d1";
    private static readonly KeyValuePair<string, string>[] Ivy = [new("profile", "ivy")];

    /// One request as the stand-in received it.
    public sealed record Seen(string Method, string Path, string Query, string? ContentType, long? ContentLength,
        string? Authorization, byte[] Body)
    {
        public string Kind => $"{Method} {Path}";
        public JsonNode? Json => JsonNode.Parse(Encoding.UTF8.GetString(Body));
    }

    /// The voice stand-in gateway (voice-gateway.py's REST, and the ws socket's file.attach and prompt.submit).
    private sealed class StandIn : IAsyncDisposable
    {
        private readonly HttpListener _http = new();
        private readonly CancellationTokenSource _life = new();
        private readonly object _gate = new();
        private readonly List<Seen> _seen = [];
        private readonly List<(string Method, JsonObject Params)> _rpc = [];
        /// The gateway's files: staged uploads and stored attachments, by path.
        public Dictionary<string, byte[]> Files { get; } = [];
        public string Url { get; }

        // Controls (voice-gateway.py's CONTROLS).
        public Dictionary<string, (int Status, string Body)> Fail { get; } = [];
        public Dictionary<string, TimeSpan> Delay { get; } = [];
        public bool SttEnabled { get; set; } = true;
        public int UnauthorizedOnce { get; set; }
        public string? Transcript { get; set; }

        public StandIn()
        {
            var probe = new TcpListener(IPAddress.Loopback, 0);
            probe.Start();
            var port = ((IPEndPoint)probe.LocalEndpoint).Port;
            probe.Stop();
            Url = $"http://127.0.0.1:{port}";
            _http.Prefixes.Add(Url + "/");
            _http.Start();
            _ = Task.Run(Serve);
        }

        public IReadOnlyList<Seen> Seen { get { lock (_gate) return [.. _seen]; } }
        public IReadOnlyList<Seen> Of(string kind) => Seen.Where(s => s.Kind == kind).ToList();
        public IReadOnlyList<JsonObject> Calls(string method) { lock (_gate) return [.. _rpc.Where(r => r.Method == method).Select(r => r.Params)]; }

        private async Task Serve()
        {
            while (!_life.IsCancellationRequested)
            {
                HttpListenerContext ctx;
                try { ctx = await _http.GetContextAsync(); } catch { return; }
                _ = Task.Run(() => Handle(ctx));
            }
        }

        private static async Task Reply(HttpListenerContext ctx, int status, byte[] body, string type = "application/json")
        {
            ctx.Response.StatusCode = status;
            ctx.Response.ContentType = type;
            ctx.Response.ContentLength64 = body.Length;
            try { await ctx.Response.OutputStream.WriteAsync(body); ctx.Response.Close(); }
            catch (Exception e) when (e is HttpListenerException or ObjectDisposedException or IOException) { }
        }

        private static Task Reply(HttpListenerContext ctx, int status, JsonNode body) =>
            Reply(ctx, status, Encoding.UTF8.GetBytes(body.ToJsonString()));

        private async Task Handle(HttpListenerContext ctx)
        {
            var req = ctx.Request;
            var path = req.Url!.AbsolutePath;
            if (path == "/api/ws" && req.IsWebSocketRequest) { await Socket(ctx); return; }
            using var buffer = new MemoryStream();
            await req.InputStream.CopyToAsync(buffer);
            var body = buffer.ToArray();
            var seen = new Seen(req.HttpMethod, path, req.Url.Query, req.Headers["Content-Type"],
                req.Headers["Content-Length"] is { } n ? long.Parse(n) : null, req.Headers["Authorization"], body);
            var kind = seen.Kind;
            TimeSpan wait;
            (int Status, string Body) fail;
            bool failing, unauthorized;
            lock (_gate)
            {
                _seen.Add(seen);
                failing = Fail.TryGetValue(kind, out fail);
                wait = Delay.GetValueOrDefault(kind);
                unauthorized = UnauthorizedOnce > 0 && path.StartsWith("/api/files");
                if (unauthorized) UnauthorizedOnce--;
            }
            if (wait > TimeSpan.Zero) await Task.Delay(wait);
            if (path == "/api/auth/ws-ticket") { await Reply(ctx, 200, new JsonObject { ["ticket"] = "synthetic-ticket" }); return; }
            if (path == "/api/auth/me") { await Reply(ctx, 200, new JsonObject { ["user"] = "synthetic" }); return; }
            if (unauthorized) { await Reply(ctx, 401, new JsonObject { ["detail"] = "Unauthorized" }); return; }
            if (failing) { await Reply(ctx, fail.Status, Encoding.UTF8.GetBytes(fail.Body)); return; }
            switch (kind)
            {
                case "GET /api/files":
                    await Reply(ctx, 200, new JsonObject { ["path"] = Root, ["parent"] = null, ["entries"] = new JsonArray() });
                    return;
                case "GET /api/config":
                    await Reply(ctx, 200, SttEnabled ? new JsonObject { ["stt"] = new JsonObject { ["enabled"] = true, ["provider"] = "local" } }
                        : new JsonObject { ["stt"] = new JsonObject { ["enabled"] = false } });
                    return;
                case "POST /api/files/upload-stream":
                {
                    var fields = Multipart(seen.ContentType ?? "", body);
                    var target = fields.TryGetValue("path", out var p) ? Encoding.UTF8.GetString(p) : "";
                    var data = fields.GetValueOrDefault("file") ?? [];
                    if (!target.StartsWith($"{Root}/.dispatch-attachments/") || data.Length == 0)
                    {
                        await Reply(ctx, 400, new JsonObject { ["detail"] = "Invalid synthetic upload" });
                        return;
                    }
                    lock (_gate)
                    {
                        if (Files.ContainsKey(target) && Encoding.UTF8.GetString(fields.GetValueOrDefault("overwrite") ?? []) != "true")
                        {
                            _ = Reply(ctx, 409, new JsonObject { ["detail"] = "File exists" });
                            return;
                        }
                        Files[target] = data;
                    }
                    await Reply(ctx, 200, new JsonObject { ["ok"] = true, ["path"] = target, ["entry"] = new JsonObject { ["size"] = data.Length } });
                    return;
                }
                case "DELETE /api/files":
                {
                    var folder = seen.Json?["path"]?.GetValue<string>() ?? "";
                    int removed;
                    lock (_gate)
                    {
                        var keys = Files.Keys.Where(k => k.StartsWith(folder + "/")).ToList();
                        foreach (var k in keys) Files.Remove(k);
                        removed = keys.Count;
                    }
                    if (!folder.StartsWith($"{Root}/.dispatch-attachments/") || removed == 0)
                        await Reply(ctx, 404, new JsonObject { ["detail"] = "Not found" });
                    else await Reply(ctx, 200, new JsonObject { ["ok"] = true });
                    return;
                }
                case "POST /api/audio/transcribe":
                {
                    var payload = seen.Json;
                    var url = payload?["data_url"]?.GetValue<string>() ?? "";
                    var comma = url.IndexOf(',');
                    if (!url.StartsWith("data:") || comma < 0 || !url[..comma].Contains(";base64"))
                    {
                        await Reply(ctx, 400, new JsonObject { ["detail"] = "Invalid audio payload" });
                        return;
                    }
                    var audio = Convert.FromBase64String(url[(comma + 1)..]);
                    var rate = BitConverter.ToInt32(audio, 24);
                    var channels = BitConverter.ToInt16(audio, 22);
                    var seconds = (audio.Length - 44) / (double)(rate * channels * 2);
                    await Reply(ctx, 200, new JsonObject
                    {
                        ["ok"] = true, ["provider"] = "fixture",
                        ["transcript"] = Transcript ?? $"Synthetic transcript of a {(int)Math.Round(seconds)} s voice memo.",
                    });
                    return;
                }
                case "GET /api/fs/download":
                {
                    var want = System.Web.HttpUtility.ParseQueryString(req.Url.Query)["path"] ?? "";
                    byte[]? file;
                    lock (_gate) file = Files.GetValueOrDefault(want);
                    if (file == null) await Reply(ctx, 404, new JsonObject { ["detail"] = "Not found" });
                    else await Reply(ctx, 200, file, "audio/wav");
                    return;
                }
            }
            await Reply(ctx, 404, new JsonObject { ["detail"] = "Not found" });
        }

        /// The multipart body's fields by name (the fixture's BytesParser): a byte-level split on the boundary.
        public static Dictionary<string, byte[]> Multipart(string contentType, byte[] body)
        {
            var fields = new Dictionary<string, byte[]>();
            var at = contentType.IndexOf("boundary=", StringComparison.Ordinal);
            if (at < 0) return fields;
            var delimiter = Encoding.ASCII.GetBytes("--" + contentType[(at + 9)..]);
            var span = body.AsSpan();
            var starts = new List<int>();
            for (var i = span.IndexOf(delimiter); i >= 0;)
            {
                starts.Add(i);
                var next = span[(i + delimiter.Length)..].IndexOf(delimiter);
                i = next < 0 ? -1 : i + delimiter.Length + next;
            }
            for (var k = 0; k + 1 < starts.Count; k++)
            {
                var part = span[(starts[k] + delimiter.Length + 2)..(starts[k + 1] - 2)];   // after CRLF, before CRLF
                var split = part.IndexOf("\r\n\r\n"u8);
                var head = Encoding.UTF8.GetString(part[..split]);
                var name = head.Split("name=\"")[1].Split('"')[0];
                fields[name] = part[(split + 4)..].ToArray();
            }
            return fields;
        }

        private async Task Socket(HttpListenerContext ctx)
        {
            var ws = (await ctx.AcceptWebSocketAsync(null)).WebSocket;
            var sendGate = new SemaphoreSlim(1, 1);
            async Task Send(JsonNode n)
            {
                await sendGate.WaitAsync();
                try { await ws.SendAsync(Encoding.UTF8.GetBytes(n.ToJsonString()), WebSocketMessageType.Text, true, CancellationToken.None); }
                catch (Exception e) when (e is WebSocketException or ObjectDisposedException) { }
                finally { sendGate.Release(); }
            }
            await Send(new JsonObject
            {
                ["jsonrpc"] = "2.0", ["method"] = "event",
                ["params"] = new JsonObject { ["type"] = "gateway.ready", ["payload"] = new JsonObject { ["replay_epoch"] = "e1" } },
            });
            var buffer = new byte[256 * 1024];
            while (ws.State == WebSocketState.Open && !_life.IsCancellationRequested)
            {
                using var frame = new MemoryStream();
                try
                {
                    WebSocketReceiveResult r;
                    do
                    {
                        r = await ws.ReceiveAsync(buffer, _life.Token);
                        if (r.MessageType == WebSocketMessageType.Close) return;
                        frame.Write(buffer, 0, r.Count);
                    } while (!r.EndOfMessage);
                }
                catch { return; }
                if (JsonNode.Parse(Encoding.UTF8.GetString(frame.ToArray())) is not JsonObject req || req["id"] is not { } id) continue;
                var method = req["method"]?.GetValue<string>() ?? "";
                var parameters = req["params"] as JsonObject ?? [];
                lock (_gate) _rpc.Add((method, (JsonObject)parameters.DeepClone()));
                JsonNode result = method switch
                {
                    "session.resume" => new JsonObject { ["session_id"] = Rid },
                    "file.attach" => Attach(parameters),
                    "prompt.submit" => new JsonObject { ["user_row_id"] = 42 },
                    _ => new JsonObject(),
                };
                await Send(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id.DeepClone(), ["result"] = result });
            }
        }

        /// file.attach as the fixture's: the staged file copied into the profile's attachments.
        private JsonObject Attach(JsonObject parameters)
        {
            var source = parameters["path"]?.GetValue<string>() ?? "";
            var name = source[(source.LastIndexOf('/') + 1)..];
            var stored = $"{Root}/.hermes/profiles/ivy/attachments/{name}";
            lock (_gate) if (Files.TryGetValue(source, out var data)) Files[stored] = data;
            return new JsonObject
            {
                ["attached"] = true, ["name"] = name, ["path"] = stored, ["ref_path"] = $".hermes/profiles/ivy/attachments/{name}",
                ["ref_text"] = $"@file:.hermes/profiles/ivy/attachments/{name}", ["uploaded"] = true,
            };
        }

        public ValueTask DisposeAsync()
        {
            _life.Cancel();
            try { _http.Close(); } catch (ObjectDisposedException) { }
            return ValueTask.CompletedTask;
        }
    }

    /// A signed-in password account on the stand-in, its HermesClient and the memo gateway the app's chats get.
    private sealed class Rig : IAsyncDisposable
    {
        public StandIn Gateway { get; } = new();
        public HermesClient Client { get; }
        public HermesMemoGateway Memo => Client.MemoGateway;
        public MemoUploadState Uploads { get; } = new();

        public Rig()
        {
            var account = new StoredAccount(Gateway.Url, "synthetic");
            Client = new HermesClient(new GatewaySession(GatewayAddress.Validated(Gateway.Url), account, new MemoryTokenStore()));
        }

        public MemoUploader Uploader() => new(Memo, Uploads);

        public async ValueTask DisposeAsync()
        {
            await Client.DisposeAsync();
            await Gateway.DisposeAsync();
        }
    }

    private static string Text(byte[] data) => Encoding.UTF8.GetString(data);

    // MARK: The wire of each call

    [Fact]
    public async Task TheFilesRootIsAJsonGetWithTheProfileAndNoBody()
    {
        await using var rig = new Rig();
        Assert.Equal(Root, await rig.Uploader().FilesRootAsync("ivy"));
        var get = Assert.Single(rig.Gateway.Of("GET /api/files"));
        Assert.Equal("?profile=ivy", get.Query);
        Assert.Equal("application/json", get.ContentType?.Split(';')[0]);
        Assert.Empty(get.Body);
        Assert.Null(get.Authorization);   // a password account: cookies, no bearer
        // Kept per account and profile: a second ask doesn't read again.
        await rig.Uploader().FilesRootAsync("ivy");
        Assert.Single(rig.Gateway.Of("GET /api/files"));
    }

    [Fact]
    public async Task TheUploadSendsTheMultipartBytesAsBuiltWithItsBoundary()
    {
        await using var rig = new Rig();
        var memo = _stores.Recording(rig.Client.AccountId);
        var wav = await File.ReadAllBytesAsync(memo.Path);
        var (path, folder) = await rig.Uploader().UploadAsync(memo.Path, Root, "ivy");
        var post = Assert.Single(rig.Gateway.Of("POST /api/files/upload-stream"));
        Assert.Equal("?profile=ivy", post.Query);
        Assert.Matches("^multipart/form-data; boundary=hermes-[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$", post.ContentType);
        var boundary = post.ContentType!["multipart/form-data; boundary=".Length..];
        // Byte for byte what MemoUploader built (W:HermesTransportShared.swift:281-299), and its length declared.
        Assert.Equal(await MemoUploader.MultipartBodyAsync(memo.Path, path, "voice-memo.wav", boundary), post.Body);
        Assert.Equal(post.Body.LongLength, post.ContentLength);
        var fields = StandIn.Multipart(post.ContentType, post.Body);
        Assert.Equal(path, Text(fields["path"]));
        Assert.Equal("false", Text(fields["overwrite"]));
        Assert.Equal(wav, fields["file"]);
        Assert.StartsWith($"{Root}/.dispatch-attachments/", folder);
        Assert.Equal($"{folder}/voice-memo.wav", path);
        Assert.Equal(wav, rig.Gateway.Files[path]);
    }

    [Fact]
    public async Task TheStagingFolderGoesWithADeleteWhoseBodyIsJson()
    {
        await using var rig = new Rig();
        var memo = _stores.Recording(rig.Client.AccountId);
        var (_, folder) = await rig.Uploader().UploadAsync(memo.Path, Root, "ivy");
        await rig.Uploader().CleanupAsync(folder, "ivy");
        var delete = Assert.Single(rig.Gateway.Of("DELETE /api/files"));
        Assert.Equal("?profile=ivy", delete.Query);
        Assert.Equal("application/json", delete.ContentType);
        Assert.Equal($"{{\"path\":\"{folder}\",\"recursive\":true}}", Text(delete.Body));
        Assert.Equal(delete.Body.LongLength, delete.ContentLength);
        Assert.Empty(rig.Gateway.Files);
        // Best effort: a folder already gone (404) is swallowed.
        await rig.Uploader().CleanupAsync(folder, "ivy");
        Assert.Equal(2, rig.Gateway.Of("DELETE /api/files").Count);
    }

    [Fact]
    public async Task TranscriptionPostsTheDataUrlAsJson()
    {
        await using var rig = new Rig();
        var memo = _stores.Recording(rig.Client.AccountId, seconds: 3);
        var answer = await rig.Uploader().TranscribeAsync(memo.Path, memo.Mime, "ivy");
        Assert.Equal(MemoSaid.Words("Synthetic transcript of a 3 s voice memo."), answer.Said);
        Assert.Null(answer.Failure);
        var post = Assert.Single(rig.Gateway.Of("POST /api/audio/transcribe"));
        Assert.Equal("?profile=ivy", post.Query);
        Assert.Equal("application/json", post.ContentType);
        var (expected, _) = await MemoUploader.TranscribeBodyAsync(memo.Path, "audio/wav");
        Assert.Equal(expected, post.Body);
        Assert.Equal("audio/wav", post.Json!["mime_type"]!.GetValue<string>());
        Assert.Equal("data:audio/wav;base64," + Convert.ToBase64String(await File.ReadAllBytesAsync(memo.Path)),
            post.Json["data_url"]!.GetValue<string>());
    }

    [Fact]
    public async Task ADownloadComesBackAsItsBytes()
    {
        // aSeededMemoDownloadsPlaysAndComputes: fetched through the client, once; the missing one is a 404.
        await using var rig = new Rig();
        _stores.Activate(rig.Client.AccountId);
        var seeded = $"{Root}/.hermes/profiles/ivy/attachments/voice-memo-seeded.wav";
        var bytes = VoiceFixtures.FixtureWave(4, [0.9]);
        bytes[^1] = 0xFF;   // not text: a decode through a string would mangle it
        bytes[^2] = 0xFE;
        rig.Gateway.Files[seeded] = bytes;
        var cache = _stores.Stores.Cache!;
        var local = await cache.FetchAsync(seeded, "ivy", rig.Memo);
        Assert.Equal(bytes, await File.ReadAllBytesAsync(local));
        var get = Assert.Single(rig.Gateway.Of("GET /api/fs/download"));
        var query = System.Web.HttpUtility.ParseQueryString(get.Query);
        Assert.Equal(seeded, query["path"]);
        Assert.Equal("ivy", query["profile"]);
        Assert.Equal(2, query.Count);
        Assert.Equal(local, await cache.FetchAsync(seeded, "ivy", rig.Memo));
        Assert.Single(rig.Gateway.Of("GET /api/fs/download"));
        var missing = await Assert.ThrowsAsync<GatewayException>(() =>
            cache.FetchAsync($"{Root}/.hermes/profiles/ivy/attachments/voice-memo-missing.wav", "ivy", rig.Memo));
        Assert.Equal("http", missing.Code);
        Assert.Equal(404, missing.Status);
    }

    // MARK: Failures

    [Theory]
    [InlineData(403, """{"detail":"read-only"}""", "Couldn’t upload the voice memo: your gateway’s files folder isn’t writable (read-only).")]
    [InlineData(413, """{"detail":"too big"}""", "Couldn’t upload the voice memo: it’s too large for your gateway.")]
    [InlineData(500, """{"detail":"Synthetic upload failure"}""", "Couldn’t upload the voice memo: Synthetic upload failure")]
    [InlineData(409, """{"error":"File exists"}""", "Couldn’t upload the voice memo: File exists")]
    [InlineData(429, "slow down", "Couldn’t upload the voice memo. Your gateway is busy right now. Wait a minute, then try again.")]
    [InlineData(502, "<html>bad gateway</html>", "Couldn’t upload the voice memo. Hermes isn’t answering right now. It may be restarting — try again in a moment.")]
    public async Task AnUploadRefusalIsAnHttpFailureInWords(int status, string body, string words)
    {
        await using var rig = new Rig();
        rig.Gateway.Fail["POST /api/files/upload-stream"] = (status, body);
        var memo = _stores.Recording(rig.Client.AccountId);
        var error = await Assert.ThrowsAsync<GatewayException>(() => rig.Uploader().UploadAsync(memo.Path, Root, "ivy"));
        Assert.Equal("http", error.Code);   // 429 too: the Mac's HTTPError, not the session's "rate-limited"
        Assert.Equal(status, error.Status);
        Assert.Equal(body, error.Body);
        Assert.Equal(words, MemoUploader.Words(error, "upload the voice memo"));
    }

    [Fact]
    public async Task ARefusalKeepsTheFirst64KiBOfItsBody()
    {
        await using var rig = new Rig();
        rig.Gateway.Fail["GET /api/files"] = (500, new string('x', 70_000));
        var error = await Assert.ThrowsAsync<GatewayException>(() => rig.Memo.RestAsync("GET", "/api/files", Ivy, null, default));
        Assert.Equal(64 * 1024, error.Body!.Length);
    }

    [Fact]
    public async Task AFailedTranscriptionLetsTheMemoGoWithItsReason()
    {
        await using var rig = new Rig();
        rig.Gateway.Fail["POST /api/audio/transcribe"] = (500, """{"detail":"Transcription failed"}""");
        var memo = _stores.Recording(rig.Client.AccountId);
        var answer = await rig.Uploader().TranscribeAsync(memo.Path, memo.Mime, "ivy");
        Assert.Equal(MemoSaidKind.Failed, answer.Said.Kind);
        Assert.Equal("Couldn’t transcribe the voice memo: Transcription failed", answer.Failure);
    }

    [Fact]
    public async Task A401RefreshesOnceAndSendsTheSameBytesAgain()
    {
        await using var rig = new Rig();
        rig.Gateway.UnauthorizedOnce = 1;
        var memo = _stores.Recording(rig.Client.AccountId);
        var (path, _) = await rig.Uploader().UploadAsync(memo.Path, Root, "ivy");
        var posts = rig.Gateway.Of("POST /api/files/upload-stream");
        Assert.Equal(2, posts.Count);
        Assert.Equal(posts[0].Body, posts[1].Body);
        Assert.Equal(posts[0].ContentType, posts[1].ContentType);
        Assert.Single(rig.Gateway.Of("GET /api/auth/me"));
        Assert.True(rig.Gateway.Files.ContainsKey(path));
    }

    [Fact]
    public async Task AnUnreachableGatewayIsOfflineInWords()
    {
        var probe = new TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        var port = ((IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        var url = $"http://127.0.0.1:{port}";
        var session = new GatewaySession(GatewayAddress.Validated(url), new StoredAccount(url, "synthetic"), new MemoryTokenStore());
        using var _ = session;
        var memo = new HermesMemoGateway(session, () => "offline-account");
        var error = await Assert.ThrowsAsync<GatewayException>(() =>
            memo.TransferAsync("POST", "/api/files/upload-stream", Ivy, [1, 2, 3], "multipart/form-data; boundary=x", 120, default));
        Assert.Equal("offline", error.Code);
        Assert.StartsWith("Couldn’t upload the voice memo: Can't reach the gateway.", MemoUploader.Words(error, "upload the voice memo"));
    }

    [Fact]
    public async Task TheTransferCeilingIsClampedToAtLeastOneSecond()
    {
        await using var rig = new Rig();
        // 10 ms asked: clamped to 1 s, so a 300 ms answer arrives…
        rig.Gateway.Delay["DELETE /api/files"] = TimeSpan.FromMilliseconds(300);
        rig.Gateway.Fail["DELETE /api/files"] = (200, """{"ok":true}""");
        Assert.Equal("""{"ok":true}""", Text(await rig.Memo.TransferAsync("DELETE", "/api/files", Ivy, "{}"u8.ToArray(), "application/json", 0.01, default)));
        // …and a 1.6 s one doesn't.
        rig.Gateway.Delay["DELETE /api/files"] = TimeSpan.FromMilliseconds(1600);
        var error = await Assert.ThrowsAsync<GatewayException>(() =>
            rig.Memo.TransferAsync("DELETE", "/api/files", Ivy, "{}"u8.ToArray(), "application/json", 0.01, default));
        Assert.Equal("timeout", error.Code);
    }

    [Fact]
    public async Task ACancelledCallIsCancelledNotAFailure()
    {
        await using var rig = new Rig();
        rig.Gateway.Delay["POST /api/audio/transcribe"] = TimeSpan.FromSeconds(2);
        using var stop = new CancellationTokenSource(TimeSpan.FromMilliseconds(150));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            rig.Memo.TransferAsync("POST", "/api/audio/transcribe", Ivy, "{}"u8.ToArray(), "application/json", 180, stop.Token));
    }

    // MARK: The shared config read

    [Fact]
    public async Task TheSpeechToTextCheckReadsTheConfigThroughTheSharedRead()
    {
        await using var rig = new Rig();
        rig.Gateway.Delay["GET /api/config"] = TimeSpan.FromMilliseconds(200);
        // maxAge zero: two checks at once share one read; nothing is kept for the next.
        var one = rig.Memo.ConfigDataAsync(Ivy, TimeSpan.Zero, default);
        var two = rig.Memo.ConfigDataAsync(Ivy, TimeSpan.Zero, default);
        Assert.Equal(Text(await one), Text(await two));
        var get = Assert.Single(rig.Gateway.Of("GET /api/config"));
        Assert.Equal("?profile=ivy", get.Query);
        Assert.Equal("application/json", get.ContentType?.Split(';')[0]);
        Assert.True(await rig.Uploader().SttEnabledAsync("ivy"));
        Assert.Equal(2, rig.Gateway.Of("GET /api/config").Count);
        rig.Gateway.SttEnabled = false;
        Assert.False(await rig.Uploader().SttEnabledAsync("ivy"));
        // A failed read counts as on.
        rig.Gateway.Fail["GET /api/config"] = (500, "{}");
        Assert.True(await rig.Uploader().SttEnabledAsync("ivy"));
    }

    [Fact]
    public async Task AWriteThroughTheSessionDropsTheKeptConfig()
    {
        await using var rig = new Rig();
        await rig.Memo.ConfigDataAsync([], TimeSpan.FromSeconds(30), default);
        await rig.Memo.ConfigDataAsync([], TimeSpan.FromSeconds(30), default);
        Assert.Single(rig.Gateway.Of("GET /api/config"));
        // A byte write (the staging folder's delete) and a JSON write each let the next reader read afresh.
        await rig.Uploader().CleanupAsync($"{Root}/.dispatch-attachments/NONE", "ivy");
        await rig.Memo.ConfigDataAsync([], TimeSpan.FromSeconds(30), default);
        Assert.Equal(2, rig.Gateway.Of("GET /api/config").Count);
        await rig.Client.Session.SendAsync(HttpMethod.Put, "/api/config", null, new JsonObject());
        await rig.Memo.ConfigDataAsync([], TimeSpan.FromSeconds(30), default);
        Assert.Equal(3, rig.Gateway.Of("GET /api/config").Count);
    }

    // MARK: SharedConfigReads (LoadCacheTests)

    private sealed class Gate
    {
        private readonly TaskCompletionSource _open = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Task Wait() => _open.Task;
        public void Release() => _open.TrySetResult();
    }

    [Fact]
    public async Task ReadersJoinOneReadAndReuseItBriefly()
    {
        var reads = new SharedConfigReads();
        var gate = new Gate();
        var count = 0;
        async Task<byte[]> Read()
        {
            var n = Interlocked.Increment(ref count);
            await gate.Wait();
            return Encoding.UTF8.GetBytes($"config {n}");
        }
        var one = reads.DataAsync([], null, Read);
        var two = reads.DataAsync([], null, Read);
        var three = reads.DataAsync([], TimeSpan.Zero, Read);   // joins too: only a kept answer is refused
        Assert.True(await VoiceFixtures.WaitUntil(() => Volatile.Read(ref count) > 0));
        await Task.Delay(20);
        gate.Release();
        Assert.Equal(["config 1"], new[] { Text(await one), Text(await two), Text(await three) }.ToHashSet());
        Assert.Equal(1, reads.ReadsStarted);
        // Kept for the next reader within its age; a reader who wants it fresh reads again.
        Assert.Equal("config 1", Text(await reads.DataAsync([], null, Read)));
        Assert.Equal(1, reads.ReadsStarted);
        Assert.Equal("config 2", Text(await reads.DataAsync([], TimeSpan.Zero, Read)));
        Assert.Equal(2, reads.ReadsStarted);
        // Another query is its own read.
        Assert.Equal("config 3", Text(await reads.DataAsync([new("profile", "inbox")], null, Read)));
        Assert.Equal(3, reads.ReadsStarted);
    }

    [Fact]
    public async Task AKeptAnswerExpires()
    {
        var reads = new SharedConfigReads();
        var count = 0;
        Task<byte[]> Read() => Task.FromResult(Encoding.UTF8.GetBytes($"{Interlocked.Increment(ref count)}"));
        await reads.DataAsync([], TimeSpan.FromMilliseconds(50), Read);
        await reads.DataAsync([], TimeSpan.FromMilliseconds(50), Read);
        Assert.Equal(1, reads.ReadsStarted);
        await Task.Delay(80);
        await reads.DataAsync([], TimeSpan.FromMilliseconds(50), Read);
        Assert.Equal(2, reads.ReadsStarted);
    }

    [Fact]
    public async Task AWriteDropsWhatIsKeptAndWhatIsInFlight()
    {
        var reads = new SharedConfigReads();
        var gate = new Gate();
        var count = 0;
        async Task<byte[]> Read()
        {
            var n = Interlocked.Increment(ref count);
            if (n == 1) await gate.Wait();
            return Encoding.UTF8.GetBytes($"config {n}");
        }
        // A read is out when the write is made: its caller still gets it, but nobody after the write does.
        var before = reads.DataAsync([], null, Read);
        Assert.True(await VoiceFixtures.WaitUntil(() => Volatile.Read(ref count) == 1));
        reads.Invalidate();
        Assert.Equal("config 2", Text(await reads.DataAsync([], null, Read)));   // doesn't join the old read
        gate.Release();
        Assert.Equal("config 1", Text(await before));
        Assert.Equal("config 2", Text(await reads.DataAsync([], null, Read)));   // the old read's late answer isn't kept
        reads.Invalidate();
        Assert.Equal("config 3", Text(await reads.DataAsync([], null, Read)));
        Assert.True(SharedConfigReads.Writes("config.set"));
        Assert.False(SharedConfigReads.Writes("session.resume"));
    }

    [Fact]
    public async Task AFailedReadIsNotKept()
    {
        var reads = new SharedConfigReads();
        var count = 0;
        Task<byte[]> Read() => Interlocked.Increment(ref count) == 1
            ? Task.FromException<byte[]>(new GatewayException("timeout", "The gateway took too long to answer."))
            : Task.FromResult("ok"u8.ToArray());
        await Assert.ThrowsAsync<GatewayException>(() => reads.DataAsync([], null, Read));
        Assert.Equal("ok", Text(await reads.DataAsync([], null, Read)));
        Assert.Equal(2, reads.ReadsStarted);
    }

    [Fact]
    public async Task TheFakesDefaultReadsDirectly()
    {
        var fake = new VoiceFakeClient();
        await fake.ConfigDataAsync([], SharedConfigReads.DefaultMaxAge, default);
        await fake.ConfigDataAsync([], SharedConfigReads.DefaultMaxAge, default);
        Assert.Equal(2, fake.Entries("GET /api/config").Count);   // fakes and stand-ins keep reading every time
    }

    // MARK: A chat's memo end to end (VoiceLiveFixtureTests)

    /// A chat with ivy on the stand-in, as the app opens one: the client's own memo gateway.
    private async Task<(Rig Rig, ChatSession Chat)> OpenAsync()
    {
        var rig = new Rig();
        _stores.Activate(rig.Client.AccountId);
        var chat = rig.Client.OpenChat("ivy", "20260929_120000_aabbcc02", "Ivy");
        Assert.Same(rig.Client.MemoGateway, chat.MemoGateway);
        chat.MemoStores = _stores.Stores;
        chat.MemoUploads = rig.Uploads;
        await rig.Client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        await chat.EnsureRuntimeAsync();
        return (rig, chat);
    }

    [Fact]
    public async Task AMemoGoesEndToEndExactlyOnce()
    {
        var (rig, chat) = await OpenAsync();
        await using var _ = rig;
        await using var __ = chat;
        var memo = _stores.Recording(rig.Client.AccountId, seconds: 3);
        var wav = await File.ReadAllBytesAsync(memo.Path);   // on the ack the recording moves into the playback cache
        Assert.Equal(SendOutcome.Accepted, await chat.SendMemoAsync(memo, ""));
        Assert.True(await VoiceFixtures.WaitUntil(() => rig.Gateway.Of("DELETE /api/files").Count == 1, 15));
        Assert.Single(rig.Gateway.Of("GET /api/files"));
        Assert.Single(rig.Gateway.Of("POST /api/files/upload-stream"));
        Assert.Single(rig.Gateway.Calls("file.attach"));
        Assert.Single(rig.Gateway.Of("POST /api/audio/transcribe"));
        const string stored = $"{Root}/.hermes/profiles/ivy/attachments/voice-memo.wav";
        Assert.Equal(wav, rig.Gateway.Files[stored]);
        var prompt = Assert.Single(rig.Gateway.Calls("prompt.submit"));
        var expected = MemoText.Reference(stored, MemoSaid.Words("Synthetic transcript of a 3 s voice memo."));
        Assert.Equal(expected, prompt["text"]!.GetValue<string>());
        // The bubble reads back as a memo with that transcript.
        var parsed = VoiceMemo.Parse(chat.Messages.Last(m => m.Role == Role.User).Text);
        Assert.NotNull(parsed);
        Assert.Equal(stored, parsed!.Path);
        // Only the staging folder went; the gateway's copy stays.
        Assert.Equal([stored], rig.Gateway.Files.Keys);
        Assert.Null(chat.SendFailure);
    }

    [Fact]
    public async Task SttOffStoresTheOffWording()
    {
        var (rig, chat) = await OpenAsync();
        await using var _ = rig;
        await using var __ = chat;
        rig.Gateway.SttEnabled = false;
        var memo = _stores.Recording(rig.Client.AccountId);
        Assert.Equal(SendOutcome.Accepted, await chat.SendMemoAsync(memo, ""));
        Assert.Empty(rig.Gateway.Of("POST /api/audio/transcribe"));
        var prompt = Assert.Single(rig.Gateway.Calls("prompt.submit"));
        Assert.EndsWith("Voice memo transcript: (unavailable: speech-to-text is off on the gateway)", prompt["text"]!.GetValue<string>());
    }

    [Fact]
    public async Task AnUploadRefusedByTheGatewayComesBackToTheChatInWords()
    {
        var (rig, chat) = await OpenAsync();
        await using var _ = rig;
        await using var __ = chat;
        rig.Gateway.Fail["POST /api/files/upload-stream"] = (403, """{"detail":"read-only"}""");
        var memo = _stores.Recording(rig.Client.AccountId);
        Assert.Equal(SendOutcome.Refused, await chat.SendMemoAsync(memo, "and the eggs"));
        Assert.Empty(rig.Gateway.Calls("file.attach"));
        Assert.Empty(rig.Gateway.Calls("prompt.submit"));
        Assert.Equal("Couldn’t upload the voice memo: your gateway’s files folder isn’t writable (read-only).", chat.SendFailure?.Reason);
        Assert.Equal(SendFailure.Title, "Couldn’t Send");
        Assert.Equal(memo.Path, _stores.Stores.Drafts!.Draft(chat.DraftScope)?.Path);
    }
}
