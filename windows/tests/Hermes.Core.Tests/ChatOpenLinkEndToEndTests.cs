using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Net;
using Hermes.Core.Rpc;

namespace Hermes.Core.Tests;

/// Opening the other bot's chat from Open Quickly never drops the account's gateway link (WIN-29). The open-quickly walk
/// opens Sam's Bot Chat on the composer stand-in (the bot that isn't on show), as the app does: REST history, then
/// `session.resume`, then the composer's reads of that chat (`session.info`, `model.options`, `config.get reasoning`) and
/// the replay a reconnect sends (`session.events.since`). The menus stand-in kept model state for the main bot and Ivy
/// only, so Sam's resume raised KeyError inside its socket loop: the loop ended, the app logged "[rpc] link dropped:
/// WebSocketException", and every redial resumed Sam again and dropped again. Run through windows/scripts/e2e.sh;
/// without the credentials it passes vacuously.
[Collection(ComposerStandIn.Name)]
[Trait("Category", "E2E")]
public class ChatOpenLinkEndToEndTests
{
    [Fact]
    public async Task OpeningTheOtherBotsChatKeepsTheGatewayLinkOpen()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_COMPOSER_CREDENTIALS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        var epoch = client.Rpc.SocketEpoch;
        var dropped = new ConcurrentQueue<string>();
        var changes = new ConcurrentQueue<ConnectionState>();
        client.Rpc.Dropped += dropped.Enqueue;
        client.Rpc.StateChanged += changes.Enqueue;

        // The walk's pick: the bot whose chat isn't on show (ProofWalks.OpenQuicklyAsync), and its Bot Chat.
        var bots = await client.BotsAsync();
        var bot = bots.First(b => b.Name != "default");
        var stored = await client.BotChatIdAsync(bot);
        var chat = client.OpenChat(bot.Name, stored, bot.DisplayName);
        await chat.OpenAsync();
        var runtime = await chat.EnsureRuntimeAsync();
        Assert.False(string.IsNullOrEmpty(runtime));

        // What the open chat reads next, and a reconnect's replay of it: each answers on the same socket.
        var info = await client.Rpc.RequestAsync("session.info", new JsonObject { ["session_id"] = runtime, ["profile"] = bot.Name }, TimeSpan.FromSeconds(10));
        Assert.False(string.IsNullOrEmpty(info.Str("model")));
        var options = await client.Rpc.RequestAsync("model.options", new JsonObject { ["profile"] = bot.Name, ["session_id"] = runtime }, TimeSpan.FromSeconds(10));
        Assert.NotNull(options.Arr("providers"));
        await client.Rpc.RequestAsync("config.get", new JsonObject { ["profile"] = bot.Name, ["key"] = "reasoning", ["session_id"] = runtime }, TimeSpan.FromSeconds(10));
        await client.Rpc.RequestAsync("session.events.since", new JsonObject { ["session_id"] = runtime, ["last_seen"] = 0 }, TimeSpan.FromSeconds(10));

        // No drop for 10 s after the chat opened (the CI walk saw the first within a second, then one after each redial).
        var until = DateTime.UtcNow.AddSeconds(10);
        while (DateTime.UtcNow < until)
        {
            Assert.Empty(dropped);
            Assert.Equal(ConnectionState.Open, client.Rpc.State);
            await Task.Delay(100);
        }
        Assert.Empty(changes);
        Assert.Equal(epoch, client.Rpc.SocketEpoch);
        await chat.DisposeAsync();
        await client.Rpc.RequestAsync("commands.catalog", new JsonObject { ["profile"] = bot.Name }, TimeSpan.FromSeconds(10));
    }
}
