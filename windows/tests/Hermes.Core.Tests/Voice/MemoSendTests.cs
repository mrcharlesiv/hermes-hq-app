// [WIN-MEMO-SEND-HOST] Tests/Voice/MemoUploaderTests.swift at 93f984bb1, the session half: each case drives a memo
// through the chat's session (optimistic bubble → staging → rewrite → prompt.submit) as the Mac's LiveChatSession cases
// do, on a real socket to a loopback stand-in gateway that answers every RPC and records it; the REST half goes through
// the recording VoiceFakeClient. Synthetic data only: a made-up account on 127.0.0.1, the /Users/owner root, a sine WAV.
//
// Ported case for case (MemoUploaderTests): callOrderParamsAndText, transcriptionErrorSendsUnavailableWithOneNotice,
// staleRuntimeResumesOnceWithoutASecondUpload, aLinkLostOnScreenIsStillRefused, aRefusalReturnsTheDraftAndARetryPaysOnce,
// aRetryIntoAnotherChatUploadsAgain, aFilesFailureRefusesBeforeSubmitting, aFailedAttachRemovesWhatItUploaded,
// aQueuedMemoWaitsWhileAReplyRuns, deletingAQueuedMemoThrowsItAway, aMemoSteersIntoTheRunningReply,
// aMemoSteerTurnedDownJoinsTheQueue; (MemoSendLifecycleTests) stopWhileStagingHandsTheMemoBackAtOnce,
// leavingWithAQueuedMemoKeepsItAsADraft, anAccountSwitchMidSendWritesNothingIntoTheOtherAccount.
// Adapted: aBrandNewChatKeepsItsStageUnderItsStoredId → aRetryReusesTheStageAndTheAckForgetsIt (a Windows chat always
// opens with its stored id; the stage is kept under it and forgotten on the ack all the same).
// Not ported: aLinkClosedForTheBackgroundAttachesAgainOnTheReturn (Windows' socket never closes for a background app:
// no `paused` link state), leavingAnAppChatKeepsAQueuedMemoInTheQueue (QueueStash and the away drain aren't in Core),
// and the watchdog lines (Windows' chat has no silence watchdog). Added per state: Stop of a steered memo while it
// stages, the composer's send half (focus hold, the draft chip's Send with the field's words).
// [WIN-MEMO-DROP-UNCONFIRMED] The stand-in's DropLink really cuts the TCP link (ws.Abort() then ctx.Response.Abort(), as
// RpcDropTests' Cut), so a lost link fails the pending call at once as connection lost. Added for the Mac's lost-link
// paths (LiveChatSession+Memo.swift, LiveChatSession.swift markUnconfirmed, GatewayFailure.swift connectionLost): under
// file.attach (refused with MemoUploader.words, the draft chip back) and under prompt.submit ("Delivery unconfirmed",
// never resent across the reconnect, the recording adopted into the playback cache).

using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Chat;
using Hermes.Core.Composer;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Rpc;
using Hermes.Core.Voice;

namespace Hermes.Core.Tests.Voice;

[Collection("memo-send")]
public sealed partial class MemoSendTests : IDisposable
{
    private readonly VoiceTestStores _stores = new();

    public void Dispose() => _stores.Dispose();

    private static Task<bool> Until(Func<bool> condition, double seconds = 10) => VoiceFixtures.WaitUntil(condition, seconds);

    /// The gateway turned a call down.
    private sealed class Refuse(long code, string message, JsonObject? data = null) : Exception(message)
    {
        public long Code { get; } = code;
        /// [WIN-OWNER-WAIT] The error's `data` (`{"reason": "SESSION_NOT_OWNED"}` …), when set.
        public JsonObject? Data { get; } = data;
    }

    /// The socket drops instead of answering (a lost link).
    private sealed class DropLink : Exception;

    /// A loopback stand-in: the ws-ticket mint and /api/ws sockets that say gateway.ready, answer each request through
    /// `Responder` (per-method attempt counts, optional delays), and record every request with its params.
    private sealed class Loopback : IAsyncDisposable
    {
        public delegate JsonNode Respond(string method, JsonObject parameters, int attempt);

        private readonly HttpListener _http = new();
        private readonly CancellationTokenSource _life = new();
        private readonly object _gate = new();
        private readonly List<(string Method, JsonObject Params)> _log = [];
        private readonly Dictionary<string, int> _attempts = [];
        private readonly Dictionary<string, TimeSpan> _delays = [];
        private readonly List<string> _order;
        private Respond _respond = Default;
        public string Url { get; }

        public Loopback(List<string> order)
        {
            _order = order;
            var probe = new TcpListener(IPAddress.Loopback, 0);
            probe.Start();
            var port = ((IPEndPoint)probe.LocalEndpoint).Port;
            probe.Stop();
            Url = $"http://127.0.0.1:{port}";
            _http.Prefixes.Add(Url + "/");
            _http.Start();
            _ = Task.Run(Serve);
        }

        public static JsonNode Default(string method, JsonObject parameters, int attempt) => method switch
        {
            "session.resume" => new JsonObject { ["session_id"] = VoiceFakeClient.Rid },
            "file.attach" => VoiceFakeClient.DefaultCall(method, parameters, attempt),
            "prompt.submit" => new JsonObject { ["user_row_id"] = 41 + attempt },
            "session.redirect" => new JsonObject { ["status"] = "redirected" },
            _ => new JsonObject(),
        };

        public void OnCall(Respond respond) { lock (_gate) _respond = respond; }

        /// [WIN-LOST-SEND-MARKER] What GET /api/sessions/<id>/messages answers (no rows until a test sets them).
        public JsonArray History { get { lock (_gate) return _history; } set { lock (_gate) _history = value; } }
        private JsonArray _history = [];
        /// [WIN-SENT-TITLES] Older stored rows: when set, the newest page says there are more, and a read with an
        /// `offset` answers these.
        public JsonArray? Older { get { lock (_gate) return _older; } set { lock (_gate) _older = value; } }
        private JsonArray? _older;

        /// [WIN-EXTERNAL-TURN] What GET /api/plugins/hermes-hq-push/sessions/working answers; null: 404 (no add-on).
        public volatile Func<JsonNode>? Ledger;
        private int _ledgerReads;
        /// Reads of the working ledger so far (404s included).
        public int LedgerReads => Volatile.Read(ref _ledgerReads);
        private const string ExternalTurnPath = "/api/plugins/hermes-hq-push/sessions/working";

        private Func<JsonNode, Task>? _current;

        /// A stream event on the open socket for the chat's runtime session.
        public Task Emit(string type, JsonObject payload) => EmitAs(VoiceFakeClient.Rid, type, payload);

        /// [WIN-LIVE-STEPS] A stream event on the open socket for another runtime session (a side chat's).
        public Task EmitAs(string runtime, string type, JsonObject payload)
        {
            Func<JsonNode, Task>? send;
            lock (_gate) send = _current;
            return send?.Invoke(new JsonObject
            {
                ["jsonrpc"] = "2.0", ["method"] = "event",
                ["params"] = new JsonObject { ["type"] = type, ["session_id"] = runtime, ["payload"] = payload },
            }) ?? Task.CompletedTask;
        }
        /// [WIN-OWNER-WAIT] ws-ticket answers 401 from now on (the client's next dial is a sign-out).
        public volatile bool RefuseTickets;
        /// [WIN-PROBLEM-CARD-REST] The chat's history read answers 500 from now on.
        public volatile bool FailHistory;
        /// [WIN-SEND-NOTSENT-REFUSE] The gateway is away for now: every dial (ticket and socket) answers 503, so no socket
        /// comes up until it is cleared.
        public volatile bool DownForNow;

        private Action? _cut;
        /// [WIN-OWNER-WAIT] Closes the open socket between calls (nothing in flight), as a gateway that went away.
        public void Cut() { Action? cut; lock (_gate) cut = _cut; cut?.Invoke(); }

        public void Delay(string method, TimeSpan wait) { lock (_gate) _delays[method] = wait; }

        public IReadOnlyList<JsonObject> Calls(string method) { lock (_gate) return [.. _log.Where(e => e.Method == method).Select(e => e.Params)]; }

        private int _sockets;
        /// /api/ws sockets accepted so far (a second one is the client's reconnect after a drop).
        public int Sockets => Volatile.Read(ref _sockets);

        private async Task Serve()
        {
            while (!_life.IsCancellationRequested)
            {
                HttpListenerContext ctx;
                try { ctx = await _http.GetContextAsync(); } catch { return; }
                _ = Task.Run(() => Handle(ctx));
            }
        }

        private async Task Handle(HttpListenerContext ctx)
        {
            var path = ctx.Request.Url!.AbsolutePath;
            if ((path == "/api/auth/ws-ticket" || path == "/api/ws") && DownForNow)
            {
                ctx.Response.StatusCode = 503;   // [WIN-SEND-NOTSENT-REFUSE] away for now: the dial fails, no socket
                ctx.Response.Close();
                return;
            }
            if (path == "/api/auth/ws-ticket" && RefuseTickets)
            {
                // [WIN-OWNER-WAIT] The account signed out elsewhere: the next dial's ticket is refused (a sign-out).
                ctx.Response.StatusCode = 401;
                ctx.Response.Close();
                return;
            }
            if (path == "/api/auth/ws-ticket")
            {
                var bytes = Encoding.UTF8.GetBytes("""{"ticket":"synthetic-ticket"}""");
                ctx.Response.ContentType = "application/json";
                ctx.Response.ContentLength64 = bytes.Length;
                await ctx.Response.OutputStream.WriteAsync(bytes);
                ctx.Response.Close();
                return;
            }
            if (path.StartsWith("/api/sessions/", StringComparison.Ordinal) && path.EndsWith("/messages", StringComparison.Ordinal)
                && FailHistory)
            {
                // [WIN-PROBLEM-CARD-REST] The history read fails (the page's "Couldn't load this chat").
                ctx.Response.StatusCode = 500;
                ctx.Response.Close();
                return;
            }
            if (path.StartsWith("/api/sessions/", StringComparison.Ordinal) && path.EndsWith("/messages", StringComparison.Ordinal))
            {
                // [WIN-LOST-SEND-MARKER] The chat's stored rows (the history read), as the test set them.
                string page;
                lock (_gate)
                    page = ctx.Request.QueryString["offset"] != null && _older != null
                        ? new JsonObject { ["messages"] = _older.DeepClone(), ["has_more"] = false }.ToJsonString()
                        : new JsonObject { ["messages"] = History.DeepClone(), ["has_more"] = _older != null }.ToJsonString();
                var rows = Encoding.UTF8.GetBytes(page);
                ctx.Response.ContentType = "application/json";
                ctx.Response.ContentLength64 = rows.Length;
                await ctx.Response.OutputStream.WriteAsync(rows);
                ctx.Response.Close();
                return;
            }
            if (path == ExternalTurnPath && Ledger is { } ledger)
            {
                // [WIN-EXTERNAL-TURN] The add-on's working ledger (GET sessions/working), when a test serves one; else
                // a 404 below, as a gateway without the add-on route.
                Interlocked.Increment(ref _ledgerReads);
                var bytes = Encoding.UTF8.GetBytes(ledger().ToJsonString());
                ctx.Response.ContentType = "application/json";
                ctx.Response.ContentLength64 = bytes.Length;
                await ctx.Response.OutputStream.WriteAsync(bytes);
                ctx.Response.Close();
                return;
            }
            if (path == ExternalTurnPath) Interlocked.Increment(ref _ledgerReads);
            if (path != "/api/ws" || !ctx.Request.IsWebSocketRequest)
            {
                ctx.Response.StatusCode = 404;
                ctx.Response.Close();
                return;
            }
            var ws = (await ctx.AcceptWebSocketAsync(null)).WebSocket;
            Interlocked.Increment(ref _sockets);
            var sendGate = new SemaphoreSlim(1, 1);
            async Task Send(JsonNode n)
            {
                await sendGate.WaitAsync();
                try { await ws.SendAsync(Encoding.UTF8.GetBytes(n.ToJsonString()), WebSocketMessageType.Text, true, CancellationToken.None); }
                catch (Exception e) when (e is WebSocketException or ObjectDisposedException) { }
                finally { sendGate.Release(); }
            }
            lock (_gate)
            {
                _current = Send;
                _cut = () => { ws.Abort(); try { ctx.Response.Abort(); } catch (Exception) { } };
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
                if (JsonNode.Parse(Encoding.UTF8.GetString(frame.ToArray())) is not JsonObject req) continue;
                var method = req["method"]?.GetValue<string>() ?? "";
                var parameters = req["params"] as JsonObject ?? [];
                int attempt;
                Respond respond;
                TimeSpan? wait;
                lock (_gate)
                {
                    _log.Add((method, (JsonObject)parameters.DeepClone()));
                    _attempts[method] = _attempts.GetValueOrDefault(method) + 1;
                    attempt = _attempts[method];
                    respond = _respond;
                    wait = _delays.TryGetValue(method, out var d) ? d : null;
                }
                lock (_order) _order.Add($"rpc {method}");
                if (req["id"] is not { } id) continue;
                var answerId = id.DeepClone();
                _ = Task.Run(async () =>
                {
                    if (wait is { } w) await Task.Delay(w);
                    try
                    {
                        var result = respond(method, parameters, attempt);
                        await Send(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = answerId, ["result"] = result });
                    }
                    catch (Refuse no)
                    {
                        await Send(new JsonObject
                        {
                            ["jsonrpc"] = "2.0", ["id"] = answerId,
                            ["error"] = no.Data is { } data
                                ? new JsonObject { ["code"] = no.Code, ["message"] = no.Message, ["data"] = data.DeepClone() }
                                : new JsonObject { ["code"] = no.Code, ["message"] = no.Message },
                        });
                    }
                    catch (DropLink)
                    {
                        // On macOS and Linux the managed HttpListener's WebSocket.Abort() alone leaves the TCP link
                        // open (RpcDropTests' Cut): aborting the response closes the connection's own stream, as a
                        // gateway process dying does.
                        ws.Abort();
                        try { ctx.Response.Abort(); } catch (Exception) { }
                    }
                });
            }
        }

        public ValueTask DisposeAsync()
        {
            _life.Cancel();
            try { _http.Close(); } catch (ObjectDisposedException) { }
            return ValueTask.CompletedTask;
        }
    }

    /// One open chat with "ivy" on a loopback socket, its memo seams set (the test's stores, a recording REST fake, its
    /// own uploader state), and its composer.
    private sealed class Rig : IAsyncDisposable
    {
        public List<string> Order { get; } = [];
        public Loopback Socket { get; }
        public VoiceFakeClient Rest { get; }
        public HermesClient Client { get; }
        public ChatSession Chat { get; }
        public ChatComposer Composer { get; }
        public MemoUploadState Uploads { get; } = new();
        public List<(string Text, string Why)> Returned { get; } = [];
        /// [WIN-SEND-REFUSE-WITHDRAW] A typed send's words handed back (`onDraftReturned` from `refuseSend`).
        public List<(string Text, string Why)> Drafts { get; } = [];
        public List<MemoSessionNoticeInfo> Notices { get; } = [];

        public Rig(VoiceTestStores stores, string stored = "20260929_120000_aabbcc02", Loopback? socket = null, VoiceFakeClient? rest = null,
            string profile = "ivy", ITranscriptCache? cache = null)
        {
            Socket = socket ?? new Loopback(Order);
            var account = new StoredAccount(Socket.Url, "synthetic");
            Client = new HermesClient(new GatewaySession(GatewayAddress.Validated(Socket.Url), account, new MemoryTokenStore()), cache);
            Rest = rest ?? new VoiceFakeClient(Client.AccountId);
            if (rest == null)
                Rest.OnRest((method, path, body) =>
                {
                    lock (Order) Order.Add($"{method} {path}");
                    return RestAnswer(method, path, body);
                });
            stores.Activate(Client.AccountId);
            Chat = Client.OpenChat(profile, stored, "Ivy");
            Chat.MemoStores = stores.Stores;
            Chat.MemoGateway = Rest;
            Chat.MemoUploads = Uploads;
            Chat.MemoDraftReturned += (text, why) => { lock (Returned) Returned.Add((text, why)); };
            Chat.DraftReturned += (text, why) => { lock (Drafts) Drafts.Add((text, why)); };
            MemoSessionNotice.Posted += Noticed;
            Composer = new ChatComposer(Chat, new ModelPrefs(Client.AccountId, new MemoryStore()));
        }

        public VoiceFakeClient.Rest RestAnswer { get; set; } = VoiceFakeClient.DefaultRest;

        private void Noticed(MemoSessionNoticeInfo info)
        {
            if (info.Scope != Chat.DraftScope) return;
            lock (Notices) Notices.Add(info);
        }

        public async Task Ready()
        {
            await Client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
            await Chat.EnsureRuntimeAsync();
        }

        public string[] Kinds { get { lock (Order) return [.. Order]; } }
        public int Count(string kind) => Kinds.Count(k => k == kind);

        public async ValueTask DisposeAsync()
        {
            MemoSessionNotice.Posted -= Noticed;
            Composer.Dispose();
            await Chat.DisposeAsync();
            await Client.DisposeAsync();
            await Socket.DisposeAsync();
        }
    }

    private static string? MemoPathOf(ChatMessage m) => VoiceMemo.Parse(m.Text)?.Path;

    // MARK: MemoUploaderTests (the session half)

    [Fact]
    public async Task CallOrderParamsAndText()
    {
        await using var rig = new Rig(_stores);
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        var before = rig.Kinds.Length;
        var sending = rig.Chat.SendMemoAsync(memo, "");
        // The optimistic bubble shows at once with the local recording.
        var bubble = rig.Chat.Messages[^1];
        Assert.True(bubble.IsPending);
        Assert.Equal(memo.Path, MemoPathOf(bubble));
        Assert.True(rig.Chat.Busy);
        Assert.True(rig.Chat.MemoStaging);
        Assert.Equal(SendOutcome.Accepted, await sending);
        Assert.True(await Until(() => rig.Count("DELETE /api/files") == 1));
        var kinds = rig.Kinds.Skip(before).Where(k => k is not ("rpc session.resume" or "rpc session.activate" or "rpc client.capabilities")).ToList();
        Assert.Equal(new HashSet<string> { "GET /api/config", "GET /api/files" }, kinds.Take(2).ToHashSet());
        int At(string kind) => kinds.IndexOf(kind);
        Assert.True(At("POST /api/files/upload-stream") > 1);
        Assert.True(At("rpc file.attach") > At("POST /api/files/upload-stream"));
        Assert.True(At("DELETE /api/files") > At("rpc file.attach"));
        Assert.True(At("POST /api/audio/transcribe") > At("rpc file.attach"));
        Assert.True(At("rpc prompt.submit") > At("POST /api/audio/transcribe"));
        var attach = Assert.Single(rig.Socket.Calls("file.attach"));
        Assert.Equal(new HashSet<string> { "session_id", "profile", "name", "path" }, attach.Select(p => p.Key).ToHashSet());
        Assert.Equal(VoiceFakeClient.Rid, attach.Str("session_id"));
        Assert.Equal("ivy", attach.Str("profile"));
        Assert.Equal("voice-memo.wav", attach.Str("name"));
        var staged = attach.Str("path")!;
        Assert.StartsWith("/Users/owner/.dispatch-attachments/", staged);
        Assert.EndsWith("/voice-memo.wav", staged);
        var delete = rig.Rest.Entries("DELETE /api/files")[0].BodyJson!;
        Assert.Equal(staged[..staged.LastIndexOf('/')], delete.Str("path"));
        Assert.True(delete.Bool("recursive"));
        foreach (var entry in rig.Rest.Log.Where(e => e.Kind.StartsWith("GET /api/files") || e.Kind.StartsWith("POST") || e.Kind.StartsWith("DELETE")))
            Assert.Equal([new("profile", "ivy")], entry.Query);
        var transcribe = rig.Rest.Entries("POST /api/audio/transcribe")[0].BodyJson!;
        Assert.Equal("audio/wav", transcribe.Str("mime_type"));
        Assert.StartsWith("data:audio/wav;base64,UklGR", transcribe.Str("data_url"));
        var submit = Assert.Single(rig.Socket.Calls("prompt.submit"));
        const string gatewayPath = "/Users/owner/.hermes/profiles/ivy/attachments/voice-memo.wav";
        Assert.Equal($"MEDIA:\"{gatewayPath}\"\n\nVoice memo transcript: Pick up milk on the way home.", submit.Str("text"));
        Assert.Null(submit["queued"]);
        Assert.Equal("ivy", submit.Str("profile"));
        // Rewritten at once; on the ack the recording moves into the playback cache under its gateway path (V9).
        Assert.Contains(rig.Chat.Messages, m => m.Text.Contains("Pick up milk") && !m.IsPending && m.RowId == 42);
        Assert.NotNull(_stores.Stores.Cache!.Local(gatewayPath));
        Assert.False(File.Exists(memo.Path));
        Assert.Empty(rig.Chat.MemoSendIds);
        Assert.Null(rig.Chat.MemoDraft);
    }

    [Fact]
    public async Task TranscriptionErrorSendsUnavailableWithOneNotice()
    {
        await using var rig = new Rig(_stores);
        rig.RestAnswer = (method, path, body) => path == "/api/audio/transcribe"
            ? throw new GatewayException("http", "The gateway answered 500.", 500, """{"detail":"Transcription failed"}""")
            : VoiceFakeClient.DefaultRest(method, path, body);
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        Assert.Equal(SendOutcome.Accepted, await rig.Chat.SendMemoAsync(memo, ""));
        Assert.EndsWith("Voice memo transcript: (unavailable)", rig.Socket.Calls("prompt.submit")[0].Str("text"));
        var notice = Assert.Single(rig.Notices);
        Assert.Equal(MemoSessionNoticeKind.NoTranscript, notice.Kind);
        Assert.Contains("Transcription failed", notice.Detail);
        Assert.Equal("Ivy", notice.Bot);
    }

    [Fact]
    public async Task StaleRuntimeResumesOnceWithoutASecondUpload()
    {
        await using var rig = new Rig(_stores);
        rig.Socket.OnCall((method, p, attempt) => method == "file.attach" && attempt == 1
            ? throw new Refuse(4001, "session not found") : Loopback.Default(method, p, attempt));
        await rig.Ready();
        var resumes = rig.Socket.Calls("session.resume").Count;
        var memo = _stores.Recording(rig.Client.AccountId);
        Assert.Equal(SendOutcome.Accepted, await rig.Chat.SendMemoAsync(memo, ""));
        Assert.Equal(2, rig.Socket.Calls("file.attach").Count);
        Assert.Equal(resumes + 1, rig.Socket.Calls("session.resume").Count);
        Assert.Equal(1, rig.Count("POST /api/files/upload-stream"));
        var paths = rig.Socket.Calls("file.attach").Select(p => p.Str("path")).ToList();
        Assert.Equal(paths[0], paths[1]);
    }

    /// A link lost while the memo attaches is refused (the draft comes back), never resent.
    [Fact]
    public async Task ALinkLostOnScreenIsStillRefused()
    {
        await using var rig = new Rig(_stores);
        rig.Socket.OnCall((method, p, attempt) => method == "file.attach" ? throw new DropLink() : Loopback.Default(method, p, attempt));
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        // The socket really drops, so the pending file.attach fails at once as connection lost, not at its 30 s timeout.
        var clock = Stopwatch.StartNew();
        Assert.Equal(SendOutcome.Refused, await rig.Chat.SendMemoAsync(memo, "").WaitAsync(TimeSpan.FromSeconds(15)));
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(5), $"settled after {clock.Elapsed}");
        Assert.Equal(memo, rig.Chat.MemoDraft);
        Assert.NotNull(rig.Chat.SendFailure);
        Assert.Single(rig.Socket.Calls("file.attach"));
        Assert.Empty(rig.Socket.Calls("prompt.submit"));
    }

    // MARK: Added: a link that really drops (93f984bb1 GatewayFailure.swift RPCError.connectionLost; the Mac's cases
    // throw it from the fake client, here the stand-in cuts the socket)

    /// Under file.attach: refused with the Mac's words (MemoUploader.words over RPCError.connectionLost: "Couldn’t
    /// attach the voice memo: connection closed before the gateway answered: file.attach"), the memo back as the draft
    /// chip, the words typed beside it back in the field, the uploaded copy removed; never attached again or submitted,
    /// not after the reconnect either.
    [Fact]
    public async Task ALinkLostUnderFileAttachIsRefusedWithTheMacsWordsAndTheDraftChip()
    {
        await using var rig = new Rig(_stores);
        rig.Socket.OnCall((method, p, attempt) => method == "file.attach" ? throw new DropLink() : Loopback.Default(method, p, attempt));
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        var clock = Stopwatch.StartNew();
        Assert.Equal(SendOutcome.Refused, await rig.Chat.SendMemoAsync(memo, "beside it").WaitAsync(TimeSpan.FromSeconds(15)));
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(5), $"settled after {clock.Elapsed}");
        const string reason = "Couldn’t attach the voice memo: connection closed before the gateway answered: file.attach";
        Assert.Equal(reason, rig.Chat.SendFailure!.Reason);
        // SendFailure.body's oneSentence ends the reason with a period (TurnErrorCopy.swift at 93f984bb1).
        Assert.Equal($"Your message is still in the box below. {reason}.", rig.Chat.SendFailure.Body);
        Assert.Equal(memo, rig.Chat.MemoDraft);   // the draft chip
        Assert.Equal([("beside it", reason)], rig.Returned);
        Assert.True(File.Exists(memo.Path));
        Assert.DoesNotContain(rig.Chat.Messages, m => m.IsPending || MemoPathOf(m) != null);
        Assert.False(rig.Chat.Busy);
        Assert.Empty(rig.Chat.MemoSendIds);
        Assert.True(await Until(() => rig.Count("DELETE /api/files") == 1));   // the staged copy goes
        Assert.True(await Until(() => rig.Socket.Sockets == 2 && rig.Client.Rpc.State == ConnectionState.Open, 15));
        await Task.Delay(300);
        Assert.Single(rig.Socket.Calls("file.attach"));
        Assert.Empty(rig.Socket.Calls("prompt.submit"));
        Assert.Equal(1, rig.Count("POST /api/files/upload-stream"));
    }

    /// Under prompt.submit (LiveChatSession.swift's isConnectionLost branch → markUnconfirmed → memoSendFinished
    /// .unconfirmed): "Delivery unconfirmed" at once, the bubble keeps the transcript, no Couldn't Send card, nothing
    /// back as a draft; the recording is adopted into the playback cache under its gateway path; the memo is never
    /// resent, not after the reconnect either; its staging stays kept (only an ack forgets it).
    [Fact]
    public async Task ALinkLostUnderPromptSubmitIsDeliveryUnconfirmedAndNeverResent()
    {
        await using var rig = new Rig(_stores);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" ? throw new DropLink() : Loopback.Default(method, p, attempt));
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        var clock = Stopwatch.StartNew();
        Assert.Equal(SendOutcome.Unconfirmed, await rig.Chat.SendMemoAsync(memo, "beside it").WaitAsync(TimeSpan.FromSeconds(15)));
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(5), $"settled after {clock.Elapsed}");
        const string gatewayPath = "/Users/owner/.hermes/profiles/ivy/attachments/voice-memo.wav";
        var bubble = rig.Chat.Messages.Last(m => m.Role == Role.User);
        Assert.Equal($"MEDIA:\"{gatewayPath}\"\n\nVoice memo transcript: Pick up milk on the way home.\n\nbeside it", bubble.Text);
        Assert.Equal(ChatSession.UnconfirmedMark, bubble.Error);
        Assert.Equal("Delivery unconfirmed", bubble.Error);
        Assert.False(bubble.IsPending);
        Assert.False(rig.Chat.Busy);
        Assert.Null(rig.Chat.SendFailure);   // no Couldn't Send card
        Assert.Null(rig.Chat.MemoDraft);   // never handed back for a resend
        Assert.Empty(rig.Returned);
        Assert.Empty(rig.Chat.MemoSendIds);
        // Adopted into the playback cache as unconfirmed: the recording moved under its gateway path.
        var cached = _stores.Stores.Cache!.Local(gatewayPath);
        Assert.NotNull(cached);
        Assert.NotEqual(memo.Path, cached);
        Assert.False(File.Exists(memo.Path));
        Assert.NotNull(new MemoUploader(rig.Rest, rig.Uploads).KeptStage(memo.Path, "20260929_120000_aabbcc02"));
        Assert.Single(rig.Socket.Calls("prompt.submit"));
        Assert.True(await Until(() => rig.Socket.Sockets == 2 && rig.Client.Rpc.State == ConnectionState.Open, 15));
        await Task.Delay(300);
        Assert.Single(rig.Socket.Calls("prompt.submit"));   // never resent across the reconnect
        Assert.Single(rig.Socket.Calls("file.attach"));
        Assert.Equal(1, rig.Count("POST /api/files/upload-stream"));
        Assert.Equal(1, rig.Count("POST /api/audio/transcribe"));
    }

    [Fact]
    public async Task ARefusalReturnsTheDraftAndARetryPaysOnce()
    {
        await using var rig = new Rig(_stores);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" && attempt == 1
            ? throw new Refuse(4000, "Model provider is out of credits.") : Loopback.Default(method, p, attempt));
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        Assert.Equal(SendOutcome.Refused, await rig.Chat.SendMemoAsync(memo, "with words"));
        Assert.Equal(memo.Path, rig.Chat.MemoDraft?.Path);   // the memo is back as this chat's draft
        Assert.Equal([("with words", "Model provider is out of credits.")], rig.Returned);   // the typed words go back to the field
        var failure = Assert.IsType<Hermes.Core.Transcripts.SendFailure>(rig.Chat.SendFailure);   // the Couldn't Send card says why
        Assert.Equal("Couldn’t Send", Hermes.Core.Transcripts.SendFailure.Title);
        Assert.Equal("Your message is still in the box below. Model provider is out of credits.", failure.Body);
        Assert.True(File.Exists(memo.Path));   // the recording stays on this PC
        Assert.DoesNotContain(rig.Chat.Messages, m => m.IsPending || MemoPathOf(m) != null);
        Assert.False(rig.Chat.Busy);
        // Retry into the same chat: nothing is uploaded, attached or transcribed again.
        var draft = _stores.Stores.Drafts!.Take(rig.Chat.DraftScope)!;
        Assert.Equal(SendOutcome.Accepted, await rig.Chat.SendMemoAsync(draft, "with words"));
        // [WIN-SEND-FAILURE-ONE-CARD] A memo send never clears the card (93f984bb1 `sendFailure` is cleared only by its ✕
        // and a typed send); the Mac's test checks nothing here, so this pins that it stays.
        Assert.NotNull(rig.Chat.SendFailure);
        Assert.Equal(2, rig.Socket.Calls("prompt.submit").Count);
        Assert.Equal(1, rig.Count("POST /api/files/upload-stream"));
        Assert.Single(rig.Socket.Calls("file.attach"));
        Assert.Equal(1, rig.Count("POST /api/audio/transcribe"));
        Assert.EndsWith("\n\nwith words", rig.Socket.Calls("prompt.submit")[1].Str("text"));
    }

    [Fact]
    public async Task ARetryIntoAnotherChatUploadsAgain()
    {
        await using var rig = new Rig(_stores);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" && attempt == 1
            ? throw new Refuse(4000, "Refused.") : Loopback.Default(method, p, attempt));
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        Assert.Equal(SendOutcome.Refused, await rig.Chat.SendMemoAsync(memo, ""));
        _stores.Stores.Drafts!.Take(rig.Chat.DraftScope);
        await using var other = rig.Client.OpenChat("ivy", "20260929_120000_ffffff09", "Ivy");
        other.MemoStores = _stores.Stores;
        other.MemoGateway = rig.Rest;
        other.MemoUploads = rig.Uploads;
        Assert.Equal(SendOutcome.Accepted, await other.SendMemoAsync(memo, ""));
        Assert.Equal(2, rig.Socket.Calls("prompt.submit").Count);
        Assert.Equal(2, rig.Count("POST /api/files/upload-stream"));
        // The transcript is kept by memo file: still one paid call.
        Assert.Equal(1, rig.Count("POST /api/audio/transcribe"));
    }

    [Fact]
    public async Task AFilesFailureRefusesBeforeSubmitting()
    {
        await using var rig = new Rig(_stores);
        rig.RestAnswer = (method, path, body) => path == "/api/files" && method == "GET"
            ? throw new GatewayException("http", "The gateway answered 500.", 500, """{"detail":"Synthetic files failure"}""")
            : VoiceFakeClient.DefaultRest(method, path, body);
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        Assert.Equal(SendOutcome.Refused, await rig.Chat.SendMemoAsync(memo, ""));
        Assert.NotNull(rig.Chat.MemoDraft);
        Assert.Empty(rig.Socket.Calls("prompt.submit"));
        Assert.Empty(rig.Socket.Calls("file.attach"));
        // The gateway's own reason, not a bare status number (audit 10-3).
        var reason = rig.Chat.SendFailure!.Reason;
        Assert.Equal("Couldn’t upload the voice memo: Synthetic files failure", reason);
        Assert.False(rig.Chat.Busy);
        Assert.DoesNotContain(rig.Chat.Messages, m => m.IsPending);
    }

    [Fact]
    public async Task AFailedAttachRemovesWhatItUploaded()
    {
        await using var rig = new Rig(_stores);
        rig.Socket.OnCall((method, p, attempt) => method == "file.attach" ? throw new Refuse(5000, "Attach refused.") : Loopback.Default(method, p, attempt));
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        Assert.Equal(SendOutcome.Refused, await rig.Chat.SendMemoAsync(memo, ""));
        Assert.NotNull(rig.Chat.MemoDraft);
        Assert.Empty(rig.Socket.Calls("prompt.submit"));
        Assert.Equal("Couldn’t attach the voice memo: Attach refused.", rig.Chat.SendFailure!.Reason);
        // The retry uploads again (nothing was kept), so the copy this attempt staged is deleted, not left behind.
        Assert.True(await Until(() => rig.Count("DELETE /api/files") == 1));
        var staged = rig.Socket.Calls("file.attach")[0].Str("path")!;
        Assert.Equal(staged[..staged.LastIndexOf('/')], rig.Rest.Entries("DELETE /api/files")[0].BodyJson.Str("path"));
        Assert.True(File.Exists(memo.Path));
    }

    /// Send While Replying set to Queue (or Ctrl+Enter): the memo waits behind the reply (V13).
    [Fact]
    public async Task AQueuedMemoWaitsWhileAReplyRuns()
    {
        await using var rig = new Rig(_stores);
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        await rig.Chat.SendAsync("first");
        Assert.True(rig.Chat.Busy);
        rig.Composer.Queue.QueuesNextSend = true;
        rig.Composer.SendMemo(memo, "after");
        var row = Assert.Single(rig.Composer.Queue.Items);
        Assert.Equal(memo, row.Payload);
        Assert.Equal("after", row.Text);
        Assert.DoesNotContain(rig.Chat.Messages, m => MemoPathOf(m) != null);
        // Remove: the memo returns as the draft chip, the words to the field.
        Assert.Equal("after", rig.Composer.Queue.Remove(row.Id));
        Assert.Equal(memo, rig.Chat.MemoDraft);
    }

    [Fact]
    public async Task DeletingAQueuedMemoThrowsItAway()
    {
        await using var rig = new Rig(_stores);
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        await rig.Chat.SendAsync("first");
        rig.Composer.Queue.QueuesNextSend = true;
        rig.Composer.SendMemo(memo, "after");
        var id = rig.Composer.Queue.Items[0].Id;
        // Delete (audit 863 02-1): nothing comes back, neither the draft chip nor the words; the recording goes.
        rig.Composer.Queue.Discard(id);
        Assert.Empty(rig.Composer.Queue.Items);
        Assert.Null(rig.Chat.MemoDraft);
        Assert.False(File.Exists(memo.Path));
    }

    /// Owner 2026-11-18: with Send While Replying on Steer (the default) a memo goes into the running reply as typed
    /// words do.
    [Fact]
    public async Task AMemoSteersIntoTheRunningReply()
    {
        await using var rig = new Rig(_stores);
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        await rig.Chat.SendAsync("first");
        Assert.True(rig.Chat.Busy);
        Assert.True(rig.Chat.MemoSteers("", redirectUnsupported: false));
        var steering = rig.Composer.SteerMemo(memo, "");
        // Its bubble shows at once, playing the recording; nothing waits in the queue.
        var bubble = rig.Chat.Messages[^1];
        Assert.Equal(Role.User, bubble.Role);
        Assert.Equal(memo.Path, MemoPathOf(bubble));
        Assert.Empty(rig.Composer.Queue.Items);
        await steering;
        var redirect = Assert.Single(rig.Socket.Calls("session.redirect"));
        Assert.Contains("Pick up milk on the way home.", redirect.Str("text"));   // the steer carries the transcript
        Assert.Contains("voice-memo.wav", redirect.Str("text"));   // and the staged memo's reference
        Assert.False(rig.Chat.Messages.Last(m => m.Role == Role.User).IsPending);
        Assert.Single(rig.Socket.Calls("prompt.submit"));   // the memo never went out as a turn of its own
        Assert.Empty(rig.Composer.Queue.Items);
        Assert.Null(rig.Chat.MemoDraft);
        Assert.True(rig.Chat.Busy);   // the reply runs on
        Assert.Empty(rig.Chat.MemoSendIds);
    }

    /// A steer the gateway turns down (the reply ended first): the memo joins the queue as a memo row, never lost.
    [Fact]
    public async Task AMemoSteerTurnedDownJoinsTheQueue()
    {
        await using var rig = new Rig(_stores);
        rig.Socket.OnCall((method, p, attempt) => method == "session.redirect" ? new JsonObject { ["status"] = "rejected" } : Loopback.Default(method, p, attempt));
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        await rig.Chat.SendAsync("first");
        rig.Composer.SendMemo(memo, "after");
        Assert.True(await Until(() => rig.Composer.Queue.Items.Count == 1));
        Assert.Equal(memo, rig.Composer.Queue.Items[0].Payload);
        Assert.Equal("after", rig.Composer.Queue.Items[0].Text);
        Assert.DoesNotContain(rig.Chat.Messages, m => MemoPathOf(m) == memo.Path);   // its bubble went; the queue card holds it
        Assert.True(File.Exists(memo.Path));
        Assert.Null(rig.Chat.MemoDraft);
    }

    // MARK: MemoSendLifecycleTests

    /// Stop while the memo uploads: it comes back as the draft at once, its bubble gone, the turn settled with no
    /// interrupt (nothing reached the gateway); the cancelled staging never attaches, transcribes or submits.
    [Fact]
    public async Task StopWhileStagingHandsTheMemoBackAtOnce()
    {
        await using var rig = new Rig(_stores);
        rig.Rest.Delay("POST /api/files/upload-stream", TimeSpan.FromMilliseconds(600));
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        var sending = rig.Chat.SendMemoAsync(memo, "");
        Assert.True(await Until(() => rig.Rest.Entries("POST /api/files/upload-stream").Count == 1));
        Assert.True(rig.Chat.Busy);
        await rig.Chat.StopAsync();
        Assert.Equal(memo, rig.Chat.MemoDraft);   // the memo is the chat's draft at once
        Assert.False(rig.Chat.Busy);   // the turn settled
        Assert.DoesNotContain(rig.Chat.Messages, m => m.IsPending || m.Interrupted || m.Text.Contains("MEDIA:"));
        Assert.Empty(rig.Chat.MemoSendIds);
        Assert.Equal([("", ChatSession.StoppedBeforeSending)], rig.Returned);
        Assert.Equal(SendOutcome.Refused, await sending);
        await Task.Delay(1200);
        Assert.Empty(rig.Socket.Calls("file.attach"));
        Assert.Equal(0, rig.Count("POST /api/audio/transcribe"));
        Assert.Empty(rig.Socket.Calls("prompt.submit"));
        Assert.Empty(rig.Socket.Calls("session.interrupt"));   // nothing reached the gateway: no interrupt
        Assert.Single(rig.Returned);   // handed back once
        Assert.True(File.Exists(memo.Path));
        Assert.Null(rig.Chat.SendFailure);   // no Couldn't Send card for a Stop
    }

    /// A chat that keeps no queue is left while a memo waits behind a reply: the memo comes back as the chat's draft with
    /// its words, and the chat says so when it opens next.
    [Fact]
    public async Task LeavingWithAQueuedMemoKeepsItAsADraft()
    {
        await using var rig = new Rig(_stores);
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        await rig.Chat.SendAsync("A slow one please");
        Assert.True(rig.Chat.Busy);
        rig.Composer.Queue.QueuesNextSend = true;
        rig.Composer.SendMemo(memo, "and the eggs");
        Assert.Single(rig.Composer.Queue.Items);
        rig.Composer.MemoQueueLeaving();
        Assert.Empty(rig.Composer.Queue.Items);
        Assert.Equal(memo, rig.Chat.MemoDraft);
        Assert.Equal("and the eggs", _stores.Stores.Drafts!.Text(rig.Chat.DraftScope));
        Assert.True(File.Exists(memo.Path));
        var posted = Assert.Single(rig.Notices);
        Assert.Equal(MemoSessionNoticeKind.SavedAsDraft, posted.Kind);
        var notice = MemoNotice.SavedAsDraft(posted.Bot!, posted.Detail);
        Assert.Equal("Memo Saved as a Draft", notice.Title);
        Assert.Equal("It didn’t send. It’s waiting in the message field of your chat with Ivy.", notice.Message);
        Assert.Equal(0, rig.Count("POST /api/files/upload-stream"));
    }

    /// The stage is kept under the chat's stored id, so a retry after a refusal reuses it, and the ack forgets it.
    [Fact]
    public async Task ARetryReusesTheStageAndTheAckForgetsIt()
    {
        await using var rig = new Rig(_stores, stored: "20261010_090000_newchat1");
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" && attempt == 1
            ? throw new Refuse(5000, "Refused.") : Loopback.Default(method, p, attempt));
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        Assert.Equal(SendOutcome.Refused, await rig.Chat.SendMemoAsync(memo, ""));
        var uploader = new MemoUploader(rig.Rest, rig.Uploads);
        Assert.NotNull(uploader.KeptStage(memo.Path, "20261010_090000_newchat1"));
        Assert.EndsWith("|20261010_090000_newchat1", rig.Chat.MemoScope);
        var draft = _stores.Stores.Drafts!.Take(rig.Chat.DraftScope)!;
        Assert.Equal(SendOutcome.Accepted, await rig.Chat.SendMemoAsync(draft, ""));
        Assert.Equal(1, rig.Count("POST /api/files/upload-stream"));   // the retry reused the staging
        Assert.Empty(rig.Chat.MemoSendIds);
        Assert.Null(uploader.KeptStage(memo.Path, "20261010_090000_newchat1"));   // the ack forgot it
    }

    /// Another account signs in while a memo is in flight: its refusal writes nothing into that account's stores (the
    /// recording is deleted instead).
    [Fact]
    public async Task AnAccountSwitchMidSendWritesNothingIntoTheOtherAccount()
    {
        await using var rig = new Rig(_stores);
        rig.Socket.Delay("prompt.submit", TimeSpan.FromMilliseconds(500));
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" ? throw new Refuse(5000, "Refused.") : Loopback.Default(method, p, attempt));
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        var sending = rig.Chat.SendMemoAsync(memo, "");
        Assert.True(await Until(() => rig.Socket.Calls("prompt.submit").Count == 1));
        _stores.Activate($"other-{Guid.NewGuid()}");
        Assert.Equal(SendOutcome.Refused, await sending);
        Assert.Empty(rig.Chat.MemoSendIds);
        Assert.Null(_stores.Stores.Drafts!.Draft(rig.Chat.DraftScope));   // nothing in the other account's drafts
        Assert.Empty(_stores.Stores.Drafts.All);
        Assert.False(File.Exists(memo.Path));   // the recording is deleted
    }

    // MARK: Added: one test per state the Mac's cases don't single out

    /// Stop while a steered memo stages: the memo comes back as the draft, its bubble goes, and the stop goes on to the
    /// running reply (its interrupt goes out); nothing joins the queue.
    [Fact]
    public async Task StopWhileASteeredMemoStagesHandsItBackAndStopsTheReply()
    {
        await using var rig = new Rig(_stores);
        rig.Rest.Delay("POST /api/files/upload-stream", TimeSpan.FromMilliseconds(600));
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        await rig.Chat.SendAsync("first");
        var steering = rig.Composer.SteerMemo(memo, "beside");
        Assert.True(await Until(() => rig.Rest.Entries("POST /api/files/upload-stream").Count == 1));
        await rig.Chat.StopAsync();
        await steering;
        Assert.Equal(memo, rig.Chat.MemoDraft);
        Assert.Equal([("beside", ChatSession.StoppedBeforeSending)], rig.Returned);
        Assert.DoesNotContain(rig.Chat.Messages, m => MemoPathOf(m) == memo.Path);
        Assert.Empty(rig.Composer.Queue.Items);
        Assert.Empty(rig.Socket.Calls("session.redirect"));
        Assert.True(await Until(() => rig.Socket.Calls("session.interrupt").Count == 1));
    }

    /// A queued memo drains with `queued:true` once the turn ends and goes as any memo does.
    [Fact]
    public async Task AQueuedMemoDrainsQueuedWhenTheReplyEnds()
    {
        await using var rig = new Rig(_stores);
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        await rig.Chat.SendAsync("first");
        rig.Composer.Queue.QueuesNextSend = true;
        rig.Composer.SendMemo(memo, "after");
        Assert.Single(rig.Composer.Queue.Items);
        // The reply ends (its message.complete settles the turn); the queue's head goes out queued.
        await rig.Socket.Emit("message.start", new JsonObject());
        await rig.Socket.Emit("message.complete", new JsonObject { ["text"] = "Done." });
        Assert.True(await Until(() => !rig.Chat.Busy || rig.Socket.Calls("prompt.submit").Count == 2));
        Assert.True(await Until(() => rig.Socket.Calls("prompt.submit").Count == 2));
        var submit = rig.Socket.Calls("prompt.submit")[1];
        Assert.True(submit.Bool("queued"));
        Assert.EndsWith("\n\nafter", submit.Str("text"));
        Assert.True(await Until(() => rig.Chat.MemoSendIds.Count == 0));
    }

    // MARK: The composer's send half (ChatVoiceHost.memoSend, primarySend)

    private sealed class Host : IMemoChatHost
    {
        public bool IsOnScreen => true;
        public bool CanSendMemo => true;
        public void MemoSend(MemoFile file, bool keyboardWasUp) { }
        public void MemoStateChanged() { }
        public void MemoLevelChanged() { }
        public void MemoWordsChanged() { }
        public void MemoFocusStatus() { }
        public void MemoConfirmDelete(double seconds, bool recording, Action<bool> answer) => answer(false);
        public void MemoShowTip(MemoTip tip) { }
        public void MemoDismissTip() { }
    }

    /// A held memo sent with the keyboard down keeps programmatic focus off the field for 1.5 s; with it up, nothing
    /// waits. Either way the memo goes with no words.
    [Fact]
    public async Task AHeldMemoSentWithTheKeyboardDownHoldsFocusForASecondAndAHalf()
    {
        await using var rig = new Rig(_stores);
        await rig.Ready();
        var now = 100.0;
        using var controller = new MemoController(new FakeCapture(_stores.Recording(rig.Client.AccountId)), _stores.Stores, new MemoryPrefs());
        var send = new ChatMemoSend(rig.Composer, controller, new Host(), _stores.Stores, nowSeconds: () => now);
        Assert.True(send.MayFocusField);
        send.MemoSend(_stores.Recording(rig.Client.AccountId), keyboardWasUp: false);
        Assert.Equal(101.5, send.FocusSuppressedUntil);
        Assert.False(send.MayFocusField);
        now = 101.49;
        Assert.False(send.MayFocusField);
        now = 101.5;
        Assert.True(send.MayFocusField);
        Assert.True(await Until(() => rig.Socket.Calls("prompt.submit").Count == 1));
        Assert.Equal("MEDIA:\"/Users/owner/.hermes/profiles/ivy/attachments/voice-memo.wav\"\n\nVoice memo transcript: Pick up milk on the way home.",
            rig.Socket.Calls("prompt.submit")[0].Str("text"));
        send.MemoSend(_stores.Recording(rig.Client.AccountId), keyboardWasUp: true);
        Assert.Equal(101.5, send.FocusSuppressedUntil);
    }

    /// The composer's Send with a draft chip: the chip's memo goes with the field's words (trimmed), the field empties,
    /// and the chip is gone. With no chip and no take, Send isn't the memo's.
    [Fact]
    public async Task TheDraftChipsSendTakesTheFieldsWords()
    {
        await using var rig = new Rig(_stores);
        await rig.Ready();
        using var controller = new MemoController(new FakeCapture(_stores.Recording(rig.Client.AccountId)), _stores.Stores, new MemoryPrefs());
        var send = new ChatMemoSend(rig.Composer, controller, new Host(), _stores.Stores);
        var field = "  call me back  ";
        Assert.False(send.PrimarySend(() => field, () => field = ""));
        Assert.Equal("  call me back  ", field);
        var memo = _stores.Recording(rig.Client.AccountId);
        rig.Chat.SetMemoDraft(memo);
        Assert.True(send.PrimarySend(() => field, () => field = ""));
        Assert.Equal("", field);
        Assert.Null(rig.Chat.MemoDraft);
        Assert.True(await Until(() => rig.Socket.Calls("prompt.submit").Count == 1));
        Assert.EndsWith("\n\ncall me back", rig.Socket.Calls("prompt.submit")[0].Str("text"));
    }
}
