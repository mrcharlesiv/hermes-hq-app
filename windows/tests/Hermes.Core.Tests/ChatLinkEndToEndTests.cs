using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Chat;
using Hermes.Core.Net;
using Hermes.Core.Rpc;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// Opening and closing a chat never drops the account's gateway link (the Mac's one GatewayConnection per account,
/// HermesKit/Net/GatewayConnection.swift; App/Chat lets a closed chat go without touching it). Against the composer
/// stand-in: Trip planning opens (cache, REST tail, `session.resume`), is closed (ChatSession disposed, as Close Chat's
/// ChatPage.OnNavigatedFrom does), opens again, and the one socket stays Open throughout: no state change, no second
/// ticket. Run through windows/scripts/e2e.sh; without the credentials it passes vacuously.
[Collection(ComposerStandIn.Name)]
[Trait("Category", "E2E")]
public class ChatLinkEndToEndTests
{
    [Fact]
    public async Task ClosingAndReopeningAChatKeepsTheGatewayLinkOpen()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_COMPOSER_CREDENTIALS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        Assert.Equal(ConnectionState.Open, client.Rpc.State);
        var epoch = client.Rpc.SocketEpoch;
        var changes = new ConcurrentQueue<ConnectionState>();
        client.Rpc.StateChanged += changes.Enqueue;

        for (var round = 0; round < 2; round++)
        {
            var chat = client.OpenChat("default", WalkProof.TripStoredId, WalkProof.TripTitle);
            await chat.OpenAsync();
            Assert.NotEmpty(chat.Messages);
            await chat.EnsureRuntimeAsync();
            await chat.DisposeAsync();   // Close Chat: the page lets go of its chat
        }

        // The link stays as it was for 3 s after the last close (the CI walk saw it redial within 1 s).
        var until = DateTime.UtcNow.AddSeconds(3);
        while (DateTime.UtcNow < until)
        {
            Assert.Equal(ConnectionState.Open, client.Rpc.State);
            await Task.Delay(100);
        }
        Assert.Empty(changes);
        Assert.Equal(epoch, client.Rpc.SocketEpoch);
        // And a call on it still answers.
        await client.Rpc.RequestAsync("commands.catalog", new JsonObject { ["profile"] = "default" }, TimeSpan.FromSeconds(10));
    }

    /// A chat's listener that throws (a WinUI one touching a page off its thread, or one left behind by a closed chat)
    /// is that listener's problem: the socket's read loop goes on, the link stays Open on the same socket, the other
    /// listeners still hear every event, and the app is told which one failed. The Mac's listeners read an AsyncStream
    /// (GatewayConnection.swift `out.events.yield`), so none of them can end its socket.
    [Fact]
    public async Task AThrowingListenerNeverDropsTheGatewayLink()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_COMPOSER_CREDENTIALS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        var epoch = client.Rpc.SocketEpoch;
        var changes = new ConcurrentQueue<ConnectionState>();
        var failures = new ConcurrentQueue<string>();
        var heard = 0;
        client.Rpc.StateChanged += changes.Enqueue;
        client.Rpc.ListenerFailed += (name, _) => failures.Enqueue(name);
        client.Rpc.Event += _ => throw new InvalidOperationException("a page touched off its thread (test)");
        client.Rpc.Event += _ => Interlocked.Increment(ref heard);

        var chat = client.OpenChat("default", WalkProof.TripStoredId, WalkProof.TripTitle);
        await chat.OpenAsync();
        await chat.EnsureRuntimeAsync();
        // A turn on the chat: its events come over the socket to the throwing listeners.
        Assert.Equal(SendOutcome.Accepted, await chat.SendAsync("Hello from the link test"));
        var until = DateTime.UtcNow.AddSeconds(15);
        while (Volatile.Read(ref heard) == 0 && DateTime.UtcNow < until) await Task.Delay(100);
        Assert.True(Volatile.Read(ref heard) > 0, "no event reached the listener after the throwing one");
        await chat.DisposeAsync();

        var settle = DateTime.UtcNow.AddSeconds(3);
        while (DateTime.UtcNow < settle)
        {
            Assert.Equal(ConnectionState.Open, client.Rpc.State);
            await Task.Delay(100);
        }
        Assert.Empty(changes);
        Assert.Equal(epoch, client.Rpc.SocketEpoch);
        Assert.Contains("Event", failures);
        await client.Rpc.RequestAsync("commands.catalog", new JsonObject { ["profile"] = "default" }, TimeSpan.FromSeconds(10));
    }
}
