// [WIN-SCREEN-SETUP-SEND] The chat's half of "Set up with Hermes" (HermesKit/Chat/LiveChatSession+ScreenSetup.swift at
// 93f984bb1) over a real socket to a loopback stand-in gateway: `file.attach` with the installer as a data URL, the
// stale-runtime retry, the gateway's own words on a refusal, the runtime wait, and the request going through the
// chat's own send (at once when idle, queued behind a running reply). The Mac has no unit test of these; its
// UITests/screen/ScreenEndToEndTests.swift test14 checks the same frames against its fixture gateway, and the asserts
// below hold this side to those (one attach named hermes-hq-screen-setup.zip, 550,200 bytes, the reviewed SHA-256, the
// prompt ending with the three installer lines). Synthetic data only.

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
using Hermes.Core.Screen;

namespace Hermes.Core.Tests.Screen;

public sealed class ScreenSetupChatTests
{
    /// A refusal the stand-in answers with (`{"error": {code, message}}`).
    private sealed class Refusal(long code, string message) : Exception(message)
    {
        public long Code { get; } = code;
    }

    /// The ws-ticket mint and one /api/ws socket that says gateway.ready and answers each request through `Answer`.
    private sealed class Stand : IAsyncDisposable
    {
        private readonly HttpListener _http = new();
        private readonly CancellationTokenSource _life = new();
        private readonly List<(string Method, JsonObject Params)> _calls = [];
        public string Url { get; }
        /// Null result: `{}`. Throw a Refusal for an error frame. Never-finishing task: no answer.
        public Func<string, JsonObject, Task<JsonNode?>> Answer { get; set; } = (_, _) => Task.FromResult<JsonNode?>(null);
        private int _resumes;

        public Stand()
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

        public IReadOnlyList<(string Method, JsonObject Params)> Calls { get { lock (_calls) return [.. _calls]; } }
        public IEnumerable<JsonObject> Of(string method) => Calls.Where(c => c.Method == method).Select(c => c.Params);

        /// session.resume answers a fresh runtime id each time (rt-1, rt-2, …).
        public JsonNode Resumed() => new JsonObject { ["session_id"] = $"rt-{Interlocked.Increment(ref _resumes)}" };

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
            if (path != "/api/ws" || !ctx.Request.IsWebSocketRequest)
            {
                ctx.Response.StatusCode = 404;
                ctx.Response.Close();
                return;
            }
            var ws = (await ctx.AcceptWebSocketAsync(null)).WebSocket;
            var gate = new SemaphoreSlim(1, 1);
            async Task Send(JsonNode n)
            {
                await gate.WaitAsync();
                try { await ws.SendAsync(Encoding.UTF8.GetBytes(n.ToJsonString()), WebSocketMessageType.Text, true, CancellationToken.None); }
                catch { }
                finally { gate.Release(); }
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
                var p = req["params"] as JsonObject ?? [];
                lock (_calls) _calls.Add((method, (JsonObject)p.DeepClone()));
                if (req["id"] is not { } id) continue;
                var reqId = id.DeepClone();
                _ = Task.Run(async () =>
                {
                    JsonObject reply;
                    try
                    {
                        var result = await Answer(method, p);
                        reply = new JsonObject { ["jsonrpc"] = "2.0", ["id"] = reqId, ["result"] = result ?? new JsonObject() };
                    }
                    catch (Refusal e)
                    {
                        reply = new JsonObject
                        {
                            ["jsonrpc"] = "2.0", ["id"] = reqId,
                            ["error"] = new JsonObject { ["code"] = e.Code, ["message"] = e.Message },
                        };
                    }
                    catch (Exception) { return; }
                    await Send(reply);
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

    /// One open bot chat with "otto" and its composer, as the Windows chat page wires them.
    private sealed class Rig : IAsyncDisposable
    {
        public Stand Gateway { get; } = new();
        public HermesClient Client { get; }
        public ChatSession Chat { get; }
        public ChatComposer Composer { get; }
        public ScreenSetupChat Setup { get; }

        public Rig()
        {
            Gateway.Answer = (m, _) => Task.FromResult<JsonNode?>(m == "session.resume" ? Gateway.Resumed() : null);
            var account = new StoredAccount(Gateway.Url, "synthetic");
            Client = new HermesClient(new GatewaySession(GatewayAddress.Validated(Gateway.Url), account, new MemoryTokenStore()));
            Chat = Client.OpenChat("otto", "st-otto", "Otto");
            Composer = new ChatComposer(Chat, new ModelPrefs(Client.AccountId, new MemoryStore()));
            Setup = new ScreenSetupChat(Composer, isBotChat: true);
        }

        public async Task Ready()
        {
            await Client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
            await Until(() => Chat.RuntimeId != null);
        }

        public async ValueTask DisposeAsync()
        {
            Composer.Dispose();
            await Chat.DisposeAsync();
            await Client.DisposeAsync();
            await Gateway.DisposeAsync();
        }
    }

    private static async Task Until(Func<bool> condition, int seconds = 15)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (!condition())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException("condition not met");
            await Task.Delay(20);
        }
    }

    /// A synthetic bundle (its data URL is small; the reviewed installer's own bytes are ScreenSetupTests').
    private static readonly ScreenSetupBundle Bundle =
        new(ScreenSetupBundle.Filename, "data:application/zip;base64,UEsFBgAAAAAAAAAAAAAAAAAAAAAAAA==", ScreenSetupBundle.ExpectedSha256, ScreenSetupBundle.HelperAppPath);

    [Fact]
    public async Task TheInstallerIsAttachedToThisChatsRuntimeAndItsRefTextComesBack()
    {
        await using var rig = new Rig();
        await rig.Ready();
        rig.Gateway.Answer = (m, _) => Task.FromResult<JsonNode?>(m == "file.attach"
            ? JsonNode.Parse("""{"attached":true,"ref_text":"@file:/tmp/fixture/hermes-hq-screen-setup.zip"}""") : null);

        var (refText, runtime) = await rig.Setup.AttachAsync(Bundle.File, Bundle.DataUrl);

        Assert.Equal("@file:/tmp/fixture/hermes-hq-screen-setup.zip", refText);
        Assert.Equal("rt-1", runtime);
        var attach = Assert.Single(rig.Gateway.Of("file.attach"));
        Assert.Equal("rt-1", attach["session_id"]!.GetValue<string>());
        Assert.Equal("otto", attach["profile"]!.GetValue<string>());
        Assert.Equal("hermes-hq-screen-setup.zip", attach["name"]!.GetValue<string>());
        Assert.Equal(Bundle.DataUrl, attach["data_url"]!.GetValue<string>());
        Assert.Null(attach["path"]);   // the bytes ride in the frame: nothing on this PC is named
    }

    [Fact]
    public async Task AStaleRuntimeResumesOnceAndAttachesAgain()
    {
        await using var rig = new Rig();
        await rig.Ready();
        var attaches = 0;
        rig.Gateway.Answer = (m, _) => m switch
        {
            "session.resume" => Task.FromResult<JsonNode?>(rig.Gateway.Resumed()),
            "file.attach" when Interlocked.Increment(ref attaches) == 1 => throw new Refusal(4001, "session not found"),
            "file.attach" => Task.FromResult<JsonNode?>(JsonNode.Parse("""{"attached":true,"ref_text":"@file:/h/x.zip"}""")),
            _ => Task.FromResult<JsonNode?>(null),
        };

        var (refText, runtime) = await rig.Setup.AttachAsync(Bundle.File, Bundle.DataUrl);

        Assert.Equal("@file:/h/x.zip", refText);
        Assert.Equal("rt-2", runtime);
        Assert.Equal(["rt-1", "rt-2"], rig.Gateway.Of("file.attach").Select(p => p["session_id"]!.GetValue<string>()));
        Assert.Equal("rt-2", rig.Chat.RuntimeId);
    }

    [Fact]
    public async Task ASecondStaleRuntimeIsRefusedWithTheGatewaysWords()
    {
        await using var rig = new Rig();
        await rig.Ready();
        rig.Gateway.Answer = (m, _) => m switch
        {
            "session.resume" => Task.FromResult<JsonNode?>(rig.Gateway.Resumed()),
            "file.attach" => throw new Refusal(4001, "session not found"),
            _ => Task.FromResult<JsonNode?>(null),
        };
        var failure = await Assert.ThrowsAsync<ScreenSetupError>(() => rig.Setup.AttachAsync(Bundle.File, Bundle.DataUrl));
        Assert.Equal(new ScreenSetupError(ScreenSetupFailure.Installer, "session not found"), failure);
        Assert.Equal(2, rig.Gateway.Of("file.attach").Count());
    }

    [Fact]
    public async Task ARefusalSaysTheGatewaysOwnWordsAndAnAnswerWithoutTheFileIsTheInstallerLine()
    {
        await using var rig = new Rig();
        await rig.Ready();
        // test14's refused attach: "No space left on the gateway".
        rig.Gateway.Answer = (m, _) => m == "file.attach" ? throw new Refusal(5000, "No space left on the gateway") : Task.FromResult<JsonNode?>(null);
        var refused = await Assert.ThrowsAsync<ScreenSetupError>(() => rig.Setup.AttachAsync(Bundle.File, Bundle.DataUrl));
        Assert.Equal("No space left on the gateway", refused.Message);

        rig.Gateway.Answer = (m, _) => Task.FromResult<JsonNode?>(m == "file.attach" ? JsonNode.Parse("""{"attached":false,"message":"Too large"}""") : null);
        Assert.Equal(new ScreenSetupError(ScreenSetupFailure.Installer, "Too large"),
            await Assert.ThrowsAsync<ScreenSetupError>(() => rig.Setup.AttachAsync(Bundle.File, Bundle.DataUrl)));

        rig.Gateway.Answer = (m, _) => Task.FromResult<JsonNode?>(m == "file.attach" ? JsonNode.Parse("""{"attached":true}""") : null);
        var bare = await Assert.ThrowsAsync<ScreenSetupError>(() => rig.Setup.AttachAsync(Bundle.File, Bundle.DataUrl));
        Assert.Equal("Hermes could not receive the Mac screen installer. Try again.", bare.Message);
    }

    [Fact]
    public async Task ADroppedSocketIsTheInstallerLineNotTheSocketsWords()
    {
        await using var rig = new Rig();
        await rig.Ready();
        var asked = new TaskCompletionSource();
        rig.Gateway.Answer = (m, _) =>
        {
            if (m != "file.attach") return Task.FromResult<JsonNode?>(null);
            asked.TrySetResult();
            return new TaskCompletionSource<JsonNode?>().Task;   // never answered
        };
        var attach = rig.Setup.AttachAsync(Bundle.File, Bundle.DataUrl);
        await asked.Task.WaitAsync(TimeSpan.FromSeconds(15));
        await rig.Gateway.DisposeAsync();   // the socket goes away under the attach
        var failure = await Assert.ThrowsAsync<ScreenSetupError>(() => attach.WaitAsync(TimeSpan.FromSeconds(30)));
        Assert.Equal(new ScreenSetupError(ScreenSetupFailure.Installer), failure);
    }

    [Fact]
    public async Task AChatThatNeverBindsIsNotReady()
    {
        await using var rig = new Rig();
        rig.Gateway.Answer = (m, _) => m == "session.resume" ? new TaskCompletionSource<JsonNode?>().Task : Task.FromResult<JsonNode?>(null);
        await rig.Client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        Assert.Equal(TimeSpan.FromSeconds(10), rig.Chat.ScreenSetupRuntimeWait);   // the app's wait
        rig.Chat.ScreenSetupRuntimeWait = TimeSpan.FromMilliseconds(400);   // a failure is expected: no need to sit it out
        var failure = await Assert.ThrowsAsync<ScreenSetupError>(() => rig.Setup.AttachAsync(Bundle.File, Bundle.DataUrl));
        Assert.Equal(new ScreenSetupError(ScreenSetupFailure.NotReady), failure);
        Assert.Equal("This bot’s chat did not become ready for setup. Try again.", failure.Message);
        Assert.Empty(rig.Gateway.Of("file.attach"));
    }

    [Fact]
    public async Task AnIdleChatSendsTheRequestAtOnceUnderItsShortTitle()
    {
        await using var rig = new Rig();
        await rig.Ready();
        Assert.False(rig.Setup.HasQueuedSetup);

        rig.Setup.Send("@file:/tmp/fixture/hermes-hq-screen-setup.zip", Bundle);

        await Until(() => rig.Gateway.Of("prompt.submit").Any());
        var text = Assert.Single(rig.Gateway.Of("prompt.submit"))["text"]!.GetValue<string>();
        Assert.StartsWith(ScreenSetupPrompt.Text, text, StringComparison.Ordinal);
        Assert.EndsWith("\n\nInstaller source: @file:/tmp/fixture/hermes-hq-screen-setup.zip\nSHA-256: 71ff241d0a3e803b8a457a9df5f91c14df48c1f227893d785974837af0c8de09\nSigned helper inside the bundle: hermes-hq-screen-setup/Hermes HQ Screen.app", text, StringComparison.Ordinal);
        Assert.DoesNotContain("dispatch", text, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(ScreenSetupPrompt.QueueTitle, Assert.Single(rig.Chat.Messages, m => m.Role == Role.User).Text);
        Assert.Empty(rig.Composer.Queue.Items);
        Assert.False(rig.Setup.HasQueuedSetup);
    }

    [Fact]
    public async Task ABusyChatQueuesTheRequestBehindTheRunningReply()
    {
        await using var rig = new Rig();
        await rig.Ready();
        // A reply is running: the first send is out and its prompt.submit not answered yet.
        rig.Gateway.Answer = (m, _) => m == "prompt.submit" ? new TaskCompletionSource<JsonNode?>().Task : Task.FromResult<JsonNode?>(null);
        rig.Composer.Send("summarise the notes");
        await Until(() => rig.Chat.Busy);

        rig.Setup.Send("@file:/h/x.zip", Bundle);

        var queued = Assert.Single(rig.Composer.Queue.Items);
        Assert.Equal(ScreenSetupPrompt.Message("@file:/h/x.zip", Bundle.Sha256, Bundle.HelperApp), queued.Text);
        Assert.Equal(ScreenSetupPrompt.QueueTitle, queued.Display);
        Assert.True(rig.Setup.HasQueuedSetup);
        await Task.Delay(200);
        Assert.Single(rig.Gateway.Of("prompt.submit"));   // only the running reply's
    }
}
