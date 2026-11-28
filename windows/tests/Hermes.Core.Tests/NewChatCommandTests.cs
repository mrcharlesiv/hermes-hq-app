using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Bots;
using Hermes.Core.Chat;
using Hermes.Core.Composer;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Sessions;

namespace Hermes.Core.Tests;

/// `/new` (3x-composer §8.2) through the composer's own dispatcher: a typed line goes `ChatComposer.Send` →
/// `RunSlashAsync` → `SlashHooks.NewChat` → `NewChatCommand.Start`, which makes the chat with the Sessions store's
/// `session.create` and hands the words after the command to the new chat's message box. The old chat sits on a real
/// socket to a loopback stand-in that records every frame, so "nothing was sent in the old chat" is observed, not assumed.
public class NewChatCommandTests
{
    /// A local stand-in gateway: the ws-ticket mint and one /api/ws socket that says gateway.ready, answers every request,
    /// and records each request's method.
    private sealed class LoopbackGateway : IAsyncDisposable
    {
        private readonly HttpListener _http = new();
        private readonly CancellationTokenSource _life = new();
        private readonly List<string> _methods = [];
        public string Url { get; }

        public LoopbackGateway()
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

        public IReadOnlyList<string> Methods { get { lock (_methods) return [.. _methods]; } }

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
            if (path == "/api/auth/ws-ticket")
            {
                var bytes = Encoding.UTF8.GetBytes("""{"ticket":"synthetic-ticket"}""");
                ctx.Response.ContentType = "application/json";
                ctx.Response.ContentLength64 = bytes.Length;
                await ctx.Response.OutputStream.WriteAsync(bytes);
                ctx.Response.Close();
                return;
            }
            if (path == "/api/ws" && ctx.Request.IsWebSocketRequest)
            {
                var ws = (await ctx.AcceptWebSocketAsync(null)).WebSocket;
                await Send(ws, new JsonObject
                {
                    ["jsonrpc"] = "2.0", ["method"] = "event",
                    ["params"] = new JsonObject { ["type"] = "gateway.ready", ["payload"] = new JsonObject { ["replay_epoch"] = "e1" } },
                });
                var buffer = new byte[64 * 1024];
                while (ws.State == WebSocketState.Open && !_life.IsCancellationRequested)
                {
                    using var frame = new MemoryStream();
                    WebSocketReceiveResult r;
                    try
                    {
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
                    lock (_methods) _methods.Add(method);
                    if (req["id"] is not { } id) continue;
                    JsonNode result = method switch
                    {
                        "session.resume" => new JsonObject { ["session_id"] = "rt-old" },
                        _ => new JsonObject(),
                    };
                    await Send(ws, new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id.DeepClone(), ["result"] = result });
                }
                return;
            }
            ctx.Response.StatusCode = 404;
            ctx.Response.Close();
        }

        private static Task Send(WebSocket ws, JsonNode n) =>
            ws.SendAsync(Encoding.UTF8.GetBytes(n.ToJsonString()), WebSocketMessageType.Text, true, CancellationToken.None);

        /// One Close(), never Stop() then Close(): on the managed (macOS/Linux) HttpListener, Stop() already lets go of
        /// the port, and a following Close() binds that port again just to drop the prefix, so it throws
        /// HttpListenerException "Address already in use" whenever another socket took the port in between.
        public ValueTask DisposeAsync()
        {
            _life.Cancel();
            try { _http.Close(); } catch (ObjectDisposedException) { }
            return ValueTask.CompletedTask;
        }
    }

    /// One open chat with "ivy", its composer wired as the Windows chat wires `/new`, and the Sessions store whose
    /// gateway makes the new chat.
    private sealed class Rig : IAsyncDisposable
    {
        public LoopbackGateway Socket { get; } = new();
        public FakeGateway Lists { get; } = new();
        public HermesClient Client { get; }
        public ChatSession Chat { get; }
        public ChatComposer Composer { get; }
        public SessionStore Sessions { get; }
        public List<NewChatOpening> Opened { get; } = [];
        public List<Exception> Failures { get; } = [];
        public Task? Making { get; private set; }

        public Rig(string profile = "ivy", params string[] roster)
        {
            var account = new StoredAccount(Socket.Url, "synthetic");
            Client = new HermesClient(new GatewaySession(GatewayAddress.Validated(Socket.Url), account, new MemoryTokenStore()));
            Chat = Client.OpenChat(profile, "st-old", "Old chat");
            Composer = new ChatComposer(Chat, new ModelPrefs(Client.AccountId, new MemoryStore()));
            Lists.OnCall = (m, _) => m == "session.create"
                ? JsonNode.Parse("""{"session_id":"rt-new","stored_session_id":"st-new"}""") : null;
            Sessions = new SessionStore(Lists, new MemoryDeviceStore());
            var known = roster.Length == 0 ? ["ivy"] : roster;
            Composer.Hooks.NewChat = arg =>
            {
                Making = NewChatCommand.Start(Chat.Profile, arg, p => known.Contains(p), p => Sessions.NewChatAsync(p),
                    o => { lock (Opened) Opened.Add(o); }, e => { lock (Failures) Failures.Add(e); });
                return Making != null;
            };
        }

        /// What the old chat's socket carried before the command: the handshake and the open chat's own bind
        /// (`session.resume` after gateway.ready), which every open chat does.
        public IReadOnlyList<string> Before { get; private set; } = [];

        /// The snapshot waits for the bind itself, not for a fixed while: the chat sends `session.resume` from its
        /// Reconnected handler on the thread pool, so on a loaded machine it can land after any fixed sleep and then
        /// look like something the command sent.
        public async Task Ready()
        {
            await Client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
            await Until(() => Socket.Methods.Contains("session.resume"));
            Before = Socket.Methods;
            Assert.Equal(["client.capabilities", "client.capabilities", "session.resume"], Before);
        }

        public int Creates => Lists.Calls.Count(c => c.Method == "session.create");
        public IEnumerable<SlashOutputPart> OutputRows => Chat.Messages.SelectMany(m => m.Parts).OfType<SlashOutputPart>();

        public async ValueTask DisposeAsync()
        {
            Composer.Dispose();
            await Chat.DisposeAsync();
            await Client.DisposeAsync();
            await Socket.DisposeAsync();
        }
    }

    private static async Task Until(Func<bool> condition, int seconds = 10)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (!condition())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException("condition not met");
            await Task.Delay(20);
        }
    }

    /// The old chat's socket carried nothing after the command: no prompt.submit, no slash.exec or command.dispatch.
    private static void NothingSentInTheOldChat(Rig rig) => Assert.Equal(rig.Before, rig.Socket.Methods);

    [Fact]
    public async Task NewWithWordsOpensAFreshChatWithThemInItsBoxAndSendsNothingInTheOldOne()
    {
        await using var rig = new Rig();
        await rig.Ready();

        rig.Composer.Send("/new   draft the release notes  ");
        await Until(() => rig.Making != null);
        await rig.Making!;

        var opened = Assert.Single(rig.Opened);
        Assert.Equal(new NewChatOpening("ivy", "st-new", "draft the release notes"), opened);
        Assert.Equal(1, rig.Creates);
        var create = rig.Lists.Calls.Single(c => c.Method == "session.create").Params;
        Assert.Equal("ivy", create["profile"]!.GetValue<string>());
        Assert.True(create["follow_profile_config"]!.GetValue<bool>());
        Assert.Null(create["text"]);   // the words ride in the new chat's box, never in the make
        Assert.DoesNotContain(rig.Lists.Calls, c => c.Method is "prompt.submit" or "session.resume");
        Assert.Empty(rig.OutputRows);   // no output row in the old chat
        Assert.Empty(rig.Chat.Messages);
        Assert.Empty(rig.Failures);
        await Task.Delay(300);
        NothingSentInTheOldChat(rig);

        // The recorder sees a real send: plain words in the old chat do go out as prompt.submit.
        rig.Composer.Send("still here");
        await Until(() => rig.Socket.Methods.Contains("prompt.submit"));
        Assert.Equal("still here", rig.Chat.Messages.Single(m => m.Role == Role.User).Text);
    }

    [Fact]
    public async Task BareNewAndItsAliasesOpenAnEmptyBox()
    {
        foreach (var line in new[] { "/new", "/new   ", "/reset", "/clear" })
        {
            await using var rig = new Rig();
            await rig.Ready();
            rig.Composer.Send(line);
            await Until(() => rig.Making != null);
            await rig.Making!;
            Assert.Equal(new NewChatOpening("ivy", "st-new", ""), Assert.Single(rig.Opened));
            Assert.Empty(rig.OutputRows);
            await Task.Delay(200);
            NothingSentInTheOldChat(rig);
        }
    }

    [Fact]
    public async Task AnUnknownBotOpensNothingAndSaysSoInTheOldChat()
    {
        await using var rig = new Rig("ghost", "ivy");
        await rig.Ready();
        rig.Composer.Send("/new hello");
        await Until(() => rig.OutputRows.Any());
        var row = Assert.Single(rig.OutputRows);
        Assert.Equal(("/new", SlashResults.NewChatFailed), (row.Command, row.Output));
        Assert.Equal("Couldn’t start a new chat with this bot.", row.Output);
        Assert.Null(rig.Making);
        Assert.Empty(rig.Opened);
        Assert.Equal(0, rig.Creates);
        await Task.Delay(200);
        NothingSentInTheOldChat(rig);
    }

    [Fact]
    public async Task AFailedMakeOpensNothingAndReportsTheError()
    {
        await using var rig = new Rig();
        rig.Lists.OnCall = (_, _) => null;   // session.create unanswered: -32601
        await rig.Ready();
        rig.Composer.Send("/new keep this");
        await Until(() => rig.Making != null);
        await rig.Making!;
        Assert.Empty(rig.Opened);
        var failure = Assert.Single(rig.Failures);
        Assert.IsType<GatewayException>(failure);
        Assert.Empty(rig.OutputRows);
        await Task.Delay(200);
        NothingSentInTheOldChat(rig);
    }

    [Fact]
    public void StartTrimsTheDraftAndRefusesAnEmptyOrUnknownProfile()
    {
        NewChatOpening? got = null;
        Assert.Null(NewChatCommand.Start("", "x", _ => true, _ => Task.FromResult("id"), o => got = o, _ => { }));
        Assert.Null(NewChatCommand.Start("otto", "x", _ => false, _ => Task.FromResult("id"), o => got = o, _ => { }));
        Assert.Null(got);
        var run = NewChatCommand.Start("otto", "  two\nlines \n", p => p == "otto", _ => Task.FromResult("id7"), o => got = o, _ => { });
        Assert.NotNull(run);
        Assert.True(run!.IsCompletedSuccessfully);
        Assert.Equal(new NewChatOpening("otto", "id7", "two\nlines"), got);
        Assert.Equal("New Chat", NewChatCommand.Title);
    }
}
