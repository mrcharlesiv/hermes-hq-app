// [WIN-ATTACH-REFUSE-CARD] A refused send with photos and files is the one "Couldn’t Send" card (ChatSession.SendFailure),
// never a transcript error row as well (93f984bb1 HermesKit/Chat/LiveChatSession.swift `refuseSend`:
// `sendFailure = SendFailure.make(reason:)` then `returnAttachments(…, refused: true)`; §6.3 "one failure, one place").
// The words and attachments still go back to the draft, uploaded, and SendReturned still says why. Driven through
// ChatSession.SendAsync(text, attachments, center) on a real socket to a loopback stand-in gateway (ws-ticket, /api/ws,
// GET /api/files, POST /api/files/upload-stream, DELETE /api/files) that answers every RPC and records it. Synthetic
// data only: a made-up account on 127.0.0.1, the /Users/me root, generated PNGs and text.
//
// Ported case for case (Tests/Attachments/AttachmentPipelineTests.swift, the two cases that read `sendFailure`):
// refusalReturnsUploadedAttachments (image.attach answers {} → "Your gateway didn’t accept “<name>”.", nothing
// submitted, the draft back uploaded) and ownerBusyWithPhotosHandsThemBackAtOnce (4090 SESSION_OWNER_BUSY on
// prompt.submit: one submit, no owner wait (`ownerWaitNotice == nil`), the card's owner-busy body, every attachment back).
// [WIN-OWNER-WAIT] Added: an owned chat's send with attachments waits for the owner and then goes, attachments and all.
// Added per state: a Stop before prompt.submit hands the draft back with no card (`withdrawStoppedSend`); a fresh send
// with attachments answers the card about the last one (`send`'s `sendFailure = nil`).

using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Attachments;
using Hermes.Core.Auth;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Tests;

[Collection("attachment-refusal")]
public sealed partial class AttachmentRefusalTests
{
    private const string Rid = "rt-attach-0001";
    private const string Root = "/Users/me/uploads";

    private static async Task<bool> Until(Func<bool> condition, double seconds = 15)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (!condition())
        {
            if (DateTime.UtcNow > until) return false;
            await Task.Delay(25);
        }
        return true;
    }

    /// The gateway turned a call down.
    private sealed class Refuse(long code, string message, JsonObject? data = null) : Exception(message)
    {
        public long Code { get; } = code;
        public JsonObject? Extra { get; } = data;
    }

    private sealed class Loopback : IAsyncDisposable
    {
        public delegate JsonNode Respond(string method, JsonObject parameters, int attempt);

        private readonly HttpListener _http = new();
        private readonly CancellationTokenSource _life = new();
        private readonly object _gate = new();
        private readonly List<(string Method, JsonObject Params)> _log = [];
        private readonly Dictionary<string, int> _attempts = [];
        private readonly List<string> _rest = [];
        private Respond _respond = Default;
        private readonly SemaphoreSlim _hold = new(0);
        private string? _holdMethod;
        public string Url { get; }
        /// [authority] gateway.ready says session_authority: true (set before the client connects).
        public bool Authority { get; init; }

        public Loopback()
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

        public static JsonNode Default(string method, JsonObject p, int attempt) => method switch
        {
            "session.resume" => new JsonObject { ["session_id"] = Rid },
            "image.attach" => new JsonObject { ["attached"] = true, ["path"] = p.Str("path") },
            // [authority] a photo's bytes, staged where the submit's attachments name it
            "image.attach_bytes" => new JsonObject { ["attached"] = true, ["path"] = "/Users/me/uploads/" + p.Str("filename"), ["mime"] = "image/png" },
            "file.attach" => new JsonObject { ["attached"] = true, ["path"] = p.Str("path"), ["ref_text"] = "@file:" + p.Str("path") },
            "prompt.submit" => new JsonObject { ["user_row_id"] = 41 + attempt },
            _ => new JsonObject(),
        };

        public void OnCall(Respond respond) { lock (_gate) _respond = respond; }

        /// The next calls of `method` wait until Release.
        public void HoldCalls(string method) { lock (_gate) _holdMethod = method; }
        public void Release() { lock (_gate) _holdMethod = null; _hold.Release(100); }

        public IReadOnlyList<JsonObject> Calls(string method) { lock (_gate) return [.. _log.Where(e => e.Method == method).Select(e => e.Params)]; }
        public IReadOnlyList<string> Rest { get { lock (_gate) return [.. _rest]; } }

        private Func<JsonNode, Task>? _current;

        /// [WIN-PROBLEM-CARD-REST] A stream event on the open socket for the chat's runtime session.
        public Task Emit(string type, JsonObject payload)
        {
            Func<JsonNode, Task>? send;
            lock (_gate) send = _current;
            return send?.Invoke(new JsonObject
            {
                ["jsonrpc"] = "2.0", ["method"] = "event",
                ["params"] = new JsonObject { ["type"] = type, ["session_id"] = Rid, ["payload"] = payload },
            }) ?? Task.CompletedTask;
        }

        private async Task Serve()
        {
            while (!_life.IsCancellationRequested)
            {
                HttpListenerContext ctx;
                try { ctx = await _http.GetContextAsync(); } catch { return; }
                _ = Task.Run(() => Handle(ctx));
            }
        }

        private static async Task Json(HttpListenerContext ctx, string body)
        {
            var bytes = Encoding.UTF8.GetBytes(body);
            ctx.Response.ContentType = "application/json";
            ctx.Response.ContentLength64 = bytes.Length;
            await ctx.Response.OutputStream.WriteAsync(bytes);
            ctx.Response.Close();
        }

        private async Task Handle(HttpListenerContext ctx)
        {
            var path = ctx.Request.Url!.AbsolutePath;
            var method = ctx.Request.HttpMethod;
            if (path == "/api/auth/ws-ticket") { await Json(ctx, """{"ticket":"synthetic-ticket"}"""); return; }
            if (path == "/api/files" && method == "GET")
            {
                lock (_gate) _rest.Add("GET /api/files");
                await Json(ctx, new JsonObject { ["path"] = Root }.ToJsonString());
                return;
            }
            if (path == "/api/files/upload-stream" && method == "POST")
            {
                using var read = new MemoryStream();
                await ctx.Request.InputStream.CopyToAsync(read);
                var body = Encoding.UTF8.GetString(read.ToArray());
                var name = Regex.Match(body, "filename=\"([^\"]+)\"").Groups[1].Value;
                var folder = Guid.NewGuid().ToString().ToUpperInvariant();
                lock (_gate) _rest.Add($"POST upload {name}");
                await Json(ctx, new JsonObject { ["path"] = $"{Root}/{AttachmentStager.StagingFolder}/{folder}/{name}" }.ToJsonString());
                return;
            }
            if (path == "/api/files" && method == "DELETE")
            {
                lock (_gate) _rest.Add("DELETE /api/files");
                await Json(ctx, "{}");
                return;
            }
            if (path != "/api/ws" || !ctx.Request.IsWebSocketRequest)
            {
                ctx.Response.StatusCode = 404;
                ctx.Response.Close();
                return;
            }
            var ws = (await ctx.AcceptWebSocketAsync(null)).WebSocket;
            var sendGate = new SemaphoreSlim(1, 1);
            async Task Send(JsonNode n)
            {
                await sendGate.WaitAsync();
                try { await ws.SendAsync(Encoding.UTF8.GetBytes(n.ToJsonString()), WebSocketMessageType.Text, true, CancellationToken.None); }
                catch (Exception e) when (e is WebSocketException or ObjectDisposedException) { }
                finally { sendGate.Release(); }
            }
            lock (_gate) _current = Send;
            await Send(new JsonObject
            {
                ["jsonrpc"] = "2.0", ["method"] = "event",
                ["params"] = new JsonObject { ["type"] = "gateway.ready", ["payload"] = Authority
                    ? new JsonObject { ["replay_epoch"] = "e1", ["session_authority"] = true }
                    : new JsonObject { ["replay_epoch"] = "e1" } },
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
                if (JsonNode.Parse(Encoding.UTF8.GetString(frame.ToArray())) is not JsonObject req) continue;
                var rpc = req["method"]?.GetValue<string>() ?? "";
                var parameters = req["params"] as JsonObject ?? [];
                int attempt;
                Respond respond;
                bool hold;
                lock (_gate)
                {
                    _log.Add((rpc, (JsonObject)parameters.DeepClone()));
                    _attempts[rpc] = _attempts.GetValueOrDefault(rpc) + 1;
                    attempt = _attempts[rpc];
                    respond = _respond;
                    hold = _holdMethod == rpc;
                }
                if (req["id"] is not { } id) continue;
                var answerId = id.DeepClone();
                _ = Task.Run(async () =>
                {
                    if (hold) await _hold.WaitAsync(TimeSpan.FromSeconds(30));
                    try
                    {
                        var result = respond(rpc, parameters, attempt);   // first: a refusal must leave the id unparented
                        await Send(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = answerId, ["result"] = result });
                    }
                    catch (Refuse no)
                    {
                        var error = new JsonObject { ["code"] = no.Code, ["message"] = no.Message };
                        if (no.Extra != null) error["data"] = no.Extra.DeepClone();
                        await Send(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = answerId, ["error"] = error });
                    }
                });
            }
        }

        public ValueTask DisposeAsync()
        {
            Release();
            _life.Cancel();
            try { _http.Close(); } catch (ObjectDisposedException) { }
            return ValueTask.CompletedTask;
        }
    }

    /// One open chat with "ivy" on the loopback socket, its attachment center, and a tray holding a photo and a file,
    /// both uploaded (AttachmentPipelineTests' `setup`).
    private sealed class Rig : IAsyncDisposable
    {
        public Loopback Socket { get; }
        public HermesClient Client { get; }
        public ChatSession Chat { get; }
        public AttachmentCenter Center { get; }
        public string Folder { get; } = Directory.CreateTempSubdirectory("hq-attach-refuse-").FullName;
        public List<string?> Returned { get; } = [];
        public string Scope => Chat.DraftScope;

        public Rig(bool authority = false)
        {
            Socket = new Loopback { Authority = authority };
            var account = new StoredAccount(Socket.Url, "synthetic");
            Client = new HermesClient(new GatewaySession(GatewayAddress.Validated(Socket.Url), account, new MemoryTokenStore()));
            Chat = Client.OpenChat("ivy", "20260929_120000_aabbcc03", "Ivy");
            Chat.SendReturned += why => { lock (Returned) Returned.Add(why); };
            Center = new AttachmentCenter(Client, Path.Combine(Folder, "account")) { AutoRetryDelay = TimeSpan.FromMilliseconds(200) };
        }

        private string MakeFile(string name, byte[] bytes)
        {
            var path = Path.Combine(Folder, "picked", name);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllBytes(path, bytes);
            return path;
        }

        /// Ready socket and runtime, then a photo and a file in the tray, uploaded.
        public async Task Ready()
        {
            await Client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
            await Chat.EnsureRuntimeAsync();
            await Center.AddPicksAsync(Scope, Chat.Profile,
            [
                new PickedItem(MakeFile("photo.png", Pictures.Png(8, 6)), "photo.png", PickSource.Photo),
                new PickedItem(MakeFile("report.txt", "synthetic report"u8.ToArray()), "report.txt", PickSource.File),
            ]);
            Assert.True(await Until(() => Center.GetDraft(Scope).Attachments is { Count: 2 } all && all.All(a => a.IsUploaded)),
                "the tray's photo and file uploaded");
        }

        public DraftAttachment Photo => Center.GetDraft(Scope).Attachments.First(a => a.Kind == DraftKind.Image);

        public async ValueTask DisposeAsync()
        {
            Center.Dispose();
            await Chat.DisposeAsync();
            await Client.DisposeAsync();
            await Socket.DisposeAsync();
            try { Directory.Delete(Folder, recursive: true); } catch (IOException) { }
        }
    }

    private static void NoErrorRow(ChatSession chat) =>
        Assert.DoesNotContain(chat.Messages, m => m.Role == Role.System && m.Error != null);

    // MARK: AttachmentPipelineTests

    [Fact]
    public async Task RefusalReturnsUploadedAttachments()
    {
        await using var rig = new Rig();
        await rig.Ready();
        var photoName = rig.Photo.Name;
        rig.Socket.OnCall((method, p, attempt) => method == "image.attach" ? new JsonObject() : Loopback.Default(method, p, attempt));
        rig.Center.SetText(rig.Scope, rig.Chat.Profile, "look");
        var (text, taken) = rig.Center.TakeForSend(rig.Scope);
        await rig.Chat.SendAsync(text, taken, rig.Center);

        var reason = $"Your gateway didn’t accept “{photoName}”.";
        Assert.Equal([reason], rig.Returned);                                       // h.drafts.first?.1
        Assert.Equal(reason, rig.Chat.SendFailure?.Reason);                          // the one card
        Assert.Empty(rig.Socket.Calls("prompt.submit"));
        var back = rig.Center.GetDraft(rig.Scope);
        Assert.Equal(taken.Select(a => a.Id), back.Attachments.Select(a => a.Id));
        Assert.All(back.Attachments, a => Assert.True(a.IsUploaded));               // a resend skips the uploads
        Assert.Equal("look", back.Text);
        // One failure, one place: no error row in the transcript, and the withdrawn bubble is gone.
        NoErrorRow(rig.Chat);
        Assert.DoesNotContain(rig.Chat.Messages, m => m.Id.StartsWith("local-user"));
        Assert.False(rig.Chat.Busy);
    }

    /// Build 337: `4090 SESSION_OWNER_BUSY` with photos (the gateway unstages them with the refusal, so a later try would
    /// go without them): no wait, the words and every attachment come back at once.
    [Fact]
    public async Task OwnerBusyWithPhotosHandsThemBackAtOnce()
    {
        await using var rig = new Rig();
        await rig.Ready();
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit"
            ? throw new Refuse(4090, "The gateway is running a turn in this chat and an image cannot join its queue, "
                + "so it was removed from this message. Nothing was sent. Send it again when the current turn ends.",
                new JsonObject { ["reason"] = "SESSION_OWNER_BUSY" })
            : Loopback.Default(method, p, attempt));
        rig.Center.SetText(rig.Scope, rig.Chat.Profile, "look");
        var (text, taken) = rig.Center.TakeForSend(rig.Scope);
        await rig.Chat.SendAsync(text, taken, rig.Center);

        Assert.Single(rig.Returned);
        Assert.Single(rig.Socket.Calls("prompt.submit"));
        Assert.Contains("Hermes is still running a reply in this chat", rig.Chat.SendFailure?.Body);
        Assert.Equal(taken.Select(a => a.Id), rig.Center.GetDraft(rig.Scope).Attachments.Select(a => a.Id));
        Assert.Null(rig.Chat.OwnerWaitNotice);                                      // photos can't wait: no wait at all
        Assert.Null(rig.Chat.WaitingForOwner);
        NoErrorRow(rig.Chat);
    }

    // MARK: Added per state

    /// [authority] A send with photos and files carries its own request id ("hq-" + its bubble's id) on a session
    /// authority, the same through every retry of that send, as the typed send's (LiveChatSession.swift send: one submit
    /// for both); on the plain sidecar the key never goes out (it refuses it 4000).
    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task AnAttachmentSendKeepsOneSubmissionIdThroughItsRetries(bool authority)
    {
        await using var rig = new Rig(authority);
        await rig.Ready();
        Assert.Equal(authority, rig.Client.Rpc.SessionAuthority);
        rig.Chat.OwnerRetryInterval = TimeSpan.FromMilliseconds(20);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" && attempt <= 2
            ? throw new Refuse(4090, "This chat is open in another Hermes window/terminal. Use it there, or start a new chat here.\n"
                + "Details: session 20260101_090000_aa0001 opened by cli 0m ago.", new JsonObject { ["reason"] = "SESSION_NOT_OWNED" })
            : Loopback.Default(method, p, attempt));
        rig.Center.SetText(rig.Scope, rig.Chat.Profile, "look");
        var (text, taken) = rig.Center.TakeForSend(rig.Scope);
        await rig.Chat.SendAsync(text, taken, rig.Center).WaitAsync(TimeSpan.FromSeconds(15));
        var submits = rig.Socket.Calls("prompt.submit");
        Assert.Equal(3, submits.Count);
        var bubble = rig.Chat.Messages.Last(m => m.Role == Role.User);
        if (authority)
            Assert.All(submits, p => Assert.Equal(AuthorityWire.SubmissionId(bubble.Id), p.Str("submission_id")));
        else
            Assert.All(submits, p => Assert.False(p.ContainsKey("submission_id")));
    }

    /// [WIN-OWNER-WAIT] A one-shot run holds the chat (`SESSION_NOT_OWNED`): the send with photos and files waits for it
    /// (the card and the status say so, nothing handed back), then goes on the same runtime with its attachments.
    [Fact]
    public async Task AnOwnedChatWaitsThenSendsWithItsAttachments()
    {
        await using var rig = new Rig();
        await rig.Ready();
        rig.Chat.OwnerRetryInterval = TimeSpan.FromMilliseconds(20);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" && attempt <= 3
            ? throw new Refuse(4090, "This chat is open in another Hermes window/terminal. Use it there, or start a new chat here.\n"
                + "Details: session 20260101_090000_aa0001 opened by cli 0m ago.", new JsonObject { ["reason"] = "SESSION_NOT_OWNED" })
            : Loopback.Default(method, p, attempt));
        rig.Center.SetText(rig.Scope, rig.Chat.Profile, "look");
        var (text, taken) = rig.Center.TakeForSend(rig.Scope);
        var sending = rig.Chat.SendAsync(text, taken, rig.Center);
        Assert.True(await Until(() => rig.Chat.OwnerWaitNotice == OwnerWait.BackgroundTask), "the waiting card");
        Assert.Equal(OwnerWait.BackgroundTask.Status, rig.Chat.Status);
        await sending.WaitAsync(TimeSpan.FromSeconds(15));
        Assert.Equal(4, rig.Socket.Calls("prompt.submit").Count);
        Assert.Empty(rig.Returned);
        Assert.Null(rig.Chat.SendFailure);
        Assert.Null(rig.Chat.OwnerWaitNotice);
        Assert.Contains(rig.Chat.Messages, m => m.Role == Role.User && !m.IsPending && m.Error == null);
        NoErrorRow(rig.Chat);
    }

    [Fact]
    public async Task AStopBeforeSubmitHandsTheDraftBackWithNoCard()
    {
        await using var rig = new Rig();
        await rig.Ready();
        rig.Socket.HoldCalls("file.attach");
        var (_, taken) = rig.Center.TakeForSend(rig.Scope);
        var sending = rig.Chat.SendAsync("wait for it", taken, rig.Center);
        Assert.True(await Until(() => rig.Socket.Calls("file.attach").Count == 1), "file.attach sent");
        await rig.Chat.StopAsync();
        rig.Socket.Release();
        await sending;

        Assert.Equal([null], rig.Returned);                                          // stopped, not refused
        Assert.Null(rig.Chat.SendFailure);
        NoErrorRow(rig.Chat);
        Assert.Empty(rig.Socket.Calls("prompt.submit"));
        Assert.Equal([rig.Socket.Calls("image.attach").Single().Str("path")],
            rig.Socket.Calls("image.detach").Select(p => p.Str("path")));            // the attached photo detached
        var back = rig.Center.GetDraft(rig.Scope);
        Assert.Equal("wait for it", back.Text);
        Assert.Equal(taken.Select(a => a.Id), back.Attachments.Select(a => a.Id));
    }

    [Fact]
    public async Task AFreshSendWithAttachmentsAnswersTheCard()
    {
        await using var rig = new Rig();
        await rig.Ready();
        rig.Socket.OnCall((method, p, attempt) => method == "image.attach" ? new JsonObject() : Loopback.Default(method, p, attempt));
        var (_, taken) = rig.Center.TakeForSend(rig.Scope);
        await rig.Chat.SendAsync("look", taken, rig.Center);
        Assert.NotNull(rig.Chat.SendFailure);

        rig.Socket.OnCall(Loopback.Default);
        var (text, again) = rig.Center.TakeForSend(rig.Scope);
        Assert.Equal("look", text);
        var next = rig.Chat.SendAsync(text, again, rig.Center);
        Assert.Null(rig.Chat.SendFailure);                                           // at once, as the Mac's `send`
        await next;
        Assert.Null(rig.Chat.SendFailure);
        Assert.Single(rig.Socket.Calls("prompt.submit"));
        Assert.Equal("@file:" + rig.Socket.Calls("file.attach").Last().Str("path") + "\n\nlook",
            rig.Socket.Calls("prompt.submit").Single().Str("text"));
        NoErrorRow(rig.Chat);
    }
}
