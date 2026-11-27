using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Net;

namespace Hermes.Core.Tests;

/// [authority] The app's calls on a gateway-hosted Hermes's session authority, over the real wire against
/// windows/ci/fixtures/questions-gateway.py with session_authority set (gateway.ready says session_authority: true;
/// the stand-in records every frame such a socket sends and refuses what the authority refuses). The plain sidecar's
/// frames stay as they were: it refuses prompt.submit's submission_id (4000). Run through windows/scripts/e2e.sh,
/// which sets HQW_E2E_QUESTIONS_CREDENTIALS; without it these tests pass vacuously. HermesKit/Net/AuthorityWire.swift,
/// GatewayConnection.swift send/noteGeneration, LiveChatSession.swift send (93f984bb1).
[Trait("Category", "E2E")]
[Collection(QuestionsStandIn.Name)]
public class AuthorityWireEndToEndTests
{
    private static (string Url, string User, string Password)? Credentials()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_QUESTIONS_CREDENTIALS");
        if (path == null || !File.Exists(path)) return null;
        var j = JsonNode.Parse(File.ReadAllText(path))!;
        return (j.Str("url")!, j.Str("username")!, j.Str("password")!);
    }

    private static async Task Until(Func<bool> condition, string what, int seconds = 20)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (!condition())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException($"{what} not met");
            await Task.Delay(50);
        }
    }

    private static async Task<JsonNode> Get(string url, string path)
    {
        using var http = new HttpClient();
        return JsonNode.Parse(await http.GetStringAsync(url + path))!;
    }

    private static async Task Post(string url, string path, object? body = null)
    {
        using var http = new HttpClient();
        var content = new StringContent(System.Text.Json.JsonSerializer.Serialize(body ?? new { }),
            System.Text.Encoding.UTF8, "application/json");
        (await http.PostAsync(url + path, content)).EnsureSuccessStatusCode();
    }

    private static async Task<(HermesClient Client, ChatSession Chat)> Open(string url, string user, string password)
    {
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), user, password);
        var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        var bot = (await client.BotsAsync()).First(b => b.Name == "default");
        var chat = client.OpenChat(bot.Name, await client.BotChatIdAsync(bot), bot.DisplayName);
        await chat.OpenAsync();
        return (client, chat);
    }

    /// The frames the newest authority socket sent, as recorded by the stand-in.
    private static async Task<List<JsonObject>> Wire(string url)
    {
        var sockets = (await Get(url, "/__fixture/requests")).Arr("sockets")!;
        var mine = sockets.LastOrDefault(s => s.Bool("authority") == true && s.Bool("connected") == true)
            ?? throw new Xunit.Sdk.XunitException("no authority socket recorded");
        return mine.Arr("wire")!.OfType<JsonObject>().ToList();
    }

    private static string[] Keys(JsonObject frame) => [.. frame.Obj("params")!.Select(kv => kv.Key).Order()];

    [Fact]
    public async Task TheAuthorityGetsItsOwnShapeAndTheSidecarItsOld()
    {
        if (Credentials() is not var (url, user, password)) return;
        await Post(url, "/__fixture/reset");
        // 4000s are kept for the stand-in's whole run: this test adds none.
        var refused = (await Get(url, "/__fixture/requests")).Arr("errors4000")!.Count;
        try
        {
            await Post(url, "/__fixture/config", new { session_authority = true });
            var (client, chat) = await Open(url, user, password);
            await using (client)
            await using (chat)
            {
                Assert.True(client.Rpc.SessionAuthority);
                var runtime = chat.RuntimeId!;
                // The open's activate went out as a resume (never served as session.activate), and its snapshot named
                // the turn.
                var opened = await Wire(url);
                Assert.DoesNotContain(opened, f => f.Str("method") == "session.activate");
                Assert.Contains(opened, f => f.Str("method") == "session.resume");
                Assert.Equal(1, client.Rpc.GenerationOf(runtime));

                // A typed send carries its own request id, "hq-" + its bubble's id.
                Assert.Equal(SendOutcome.Accepted, await chat.SendAsync("hello authority"));
                var bubble = chat.Messages.Last(m => m.Role == Role.User && m.Text == "hello authority");
                var submit = (await Wire(url)).Last(f => f.Str("method") == "prompt.submit");
                Assert.Equal(AuthorityWire.SubmissionId(bubble.Id), submit.Obj("params").Str("submission_id"));
                Assert.Equal(["profile", "session_id", "submission_id", "text"], Keys(submit));
                await Until(() => !chat.Busy, "the reply finished");

                // A retry replays the same admission: refused busy (4009) once, the send goes again under the same id.
                await Post(url, "/__fixture/plan", new { plans = new object[] { new { reject = "Session busy", code = 4009 } } });
                Assert.Equal(SendOutcome.Accepted, await chat.SendAsync("again please"));
                var again = chat.Messages.Last(m => m.Role == Role.User && m.Text == "again please");
                var tries = (await Wire(url)).Where(f => f.Str("method") == "prompt.submit" && f.Obj("params").Str("text") == "again please").ToList();
                Assert.Equal(2, tries.Count);
                Assert.All(tries, f => Assert.Equal(AuthorityWire.SubmissionId(again.Id), f.Obj("params").Str("submission_id")));
                Assert.NotEqual(bubble.Id, again.Id);
                await Until(() => !chat.Busy, "the second reply finished");

                // A frame that names a later turn moves the session's turn on; the turn controls name it.
                await Post(url, "/__fixture/event", new { profile = "default", type = "hq.authority.probe", payload = new { }, execution_generation = 7 });
                await Until(() => client.Rpc.GenerationOf(runtime) == 7, "the frame's turn noted");
                await client.Rpc.RequestAsync("session.redirect",
                    new JsonObject { ["session_id"] = runtime, ["profile"] = "default", ["text"] = "also this" }, TimeSpan.FromSeconds(15));
                await client.Rpc.RequestAsync("session.interrupt",
                    new JsonObject { ["session_id"] = runtime, ["profile"] = "default" }, TimeSpan.FromSeconds(15));
                var approval = await client.Rpc.RequestAsync("approval.respond", new JsonObject
                {
                    ["session_id"] = runtime, ["choice"] = "once", ["all"] = false, ["request_id"] = "p-9", ["profile"] = "default",
                }, TimeSpan.FromSeconds(15));
                Assert.Equal(0, approval.Int("resolved"));   // answered, not refused: nothing named p-9 was waiting
                // A plain activate from any caller is a resume too.
                await client.Rpc.RequestAsync("session.activate",
                    new JsonObject { ["session_id"] = runtime, ["profile"] = "default" }, TimeSpan.FromSeconds(15));
                // A create: the gui surface, its retry key as request_id, no terminal width.
                try
                {
                    await client.Rpc.RequestAsync("session.create", new JsonObject
                    {
                        ["profile"] = "default", ["source"] = "desktop", ["idempotency_key"] = "k-1", ["cols"] = 96,
                    }, TimeSpan.FromSeconds(15));
                }
                catch (GatewayException e) when (e.RpcCode != 4000) { /* the stand-in makes no chats; only the shape counts */ }

                var wire = await Wire(url);
                var redirect = wire.Last(f => f.Str("method") == "session.redirect");
                Assert.Equal(7, AuthorityWire.Generation(redirect.Obj("params")));
                var interrupt = wire.Last(f => f.Str("method") == "session.interrupt");
                Assert.Equal(["execution_generation", "profile", "session_id"], Keys(interrupt));
                Assert.Equal(7, AuthorityWire.Generation(interrupt.Obj("params")));
                var answer = wire.Last(f => f.Str("method") == "approval.respond");
                Assert.Equal(["choice", "execution_generation", "profile", "prompt_id", "session_id"], Keys(answer));
                Assert.Equal("p-9", answer.Obj("params").Str("prompt_id"));
                Assert.Equal(7, AuthorityWire.Generation(answer.Obj("params")));
                Assert.DoesNotContain(wire, f => f.Str("method") == "session.activate");
                var create = wire.Last(f => f.Str("method") == "session.create");
                Assert.Equal(["profile", "request_id", "source"], Keys(create));
                Assert.Equal("gui", create.Obj("params").Str("source"));
                Assert.Equal("k-1", create.Obj("params").Str("request_id"));
                Assert.Equal(refused, (await Get(url, "/__fixture/requests")).Arr("errors4000")!.Count);
            }

            // The plain sidecar: no session_authority, so the send goes out without its request id (the sidecar would
            // refuse it, 4000) and nothing is recorded as an authority frame.
            await Post(url, "/__fixture/config", new { session_authority = false });
            var (plainClient, plainChat) = await Open(url, user, password);
            await using (plainClient)
            await using (plainChat)
            {
                Assert.False(plainClient.Rpc.SessionAuthority);
                Assert.Equal(SendOutcome.Accepted, await plainChat.SendAsync("hello sidecar"));
                var state = await Get(url, "/__fixture/state");
                var sent = state.Arr("rpc")!.OfType<JsonObject>()
                    .Last(r => r.Str("method") == "prompt.submit" && r.Obj("params").Str("text") == "hello sidecar");
                Assert.Equal(["profile", "session_id", "text"], Keys(sent));
                Assert.Null(plainClient.Rpc.GenerationOf(plainChat.RuntimeId!));
                Assert.Equal(refused, (await Get(url, "/__fixture/requests")).Arr("errors4000")!.Count);
                await Until(() => !plainChat.Busy, "the sidecar's reply finished");
            }
        }
        finally { await Post(url, "/__fixture/reset"); }
    }
}
