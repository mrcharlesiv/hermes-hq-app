// Regression tests ensuring BrowserWatchSession never sends `?profile=` on `/sessions/{id}/watch`,
// preventing HTTP 501 socket refusals on non-default bot profiles (HermesKit/Browser/BrowserWatchSession.swift).

using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using Hermes.Core.Browser;

namespace Hermes.Core.Tests.Browser;

public sealed class BrowserWatchQueryTests
{
    private const string RowId = "0123456789abcdef01234567";

    private static JsonNode ReadyHealth() =>
        JsonNode.Parse("""
            {
              "installed": true,
              "protocol": 3,
              "version": "3.10.0",
              "hosted": false,
              "features": { "control": true, "choice": true, "cloud": true, "cloud_all": true, "dialogs": true, "hosted": true }
            }
            """)!;

    [Theory]
    [InlineData("ivy", "Ivy")]
    [InlineData("work", "Work")]
    [InlineData("default", "Hermes")]
    public async Task WatchSocketOpensWithEmptyQueryForDefaultAndNonDefaultProfiles(string profile, string name)
    {
        var dialed = new ConcurrentQueue<(string Path, IReadOnlyList<KeyValuePair<string, string>> Query)>();
        var socket = new FakeBrowserSocket();
        var gw = new FakeBrowserGateway
        {
            OnJson = (_, _, _, _) => Task.FromResult(ReadyHealth()),
            OnSocket = (path, query) =>
            {
                dialed.Enqueue((path, query.ToArray()));
                return Task.FromResult<IBrowserSocket>(socket);
            },
        };

        var service = new BrowserService(gw, new FakeMemoryStore());
        var session = new BrowserWatchSession(service, RowId, BrowserWire.Plugin, profile, name);
        socket.Enqueue("""{"type":"state","tabs":[],"tab":null,"follow":true,"control":{"state":"bot","mine":false,"epoch":1}}""");

        session.SetShown(true);
        await WaitUntilAsync(() => session.Link == BrowserWatchLink.Live);

        Assert.True(dialed.TryDequeue(out var first));
        Assert.Equal($"{BrowserWire.Plugin}/sessions/{RowId}/watch", first.Path);
        Assert.Empty(first.Query);
        Assert.DoesNotContain(first.Query, kv => string.Equals(kv.Key, "profile", StringComparison.OrdinalIgnoreCase));

        session.Stop();
        service.Shutdown();
    }

    [Fact]
    public async Task WatchSocketReconnectsAndLegacyBaseStillSendEmptyQuery()
    {
        var dialed = new ConcurrentQueue<(string Path, IReadOnlyList<KeyValuePair<string, string>> Query)>();
        var socket1 = new FakeBrowserSocket();
        var socket2 = new FakeBrowserSocket();
        var calls = 0;
        var gw = new FakeBrowserGateway
        {
            OnJson = (_, _, _, _) => Task.FromResult(ReadyHealth()),
            OnSocket = (path, query) =>
            {
                dialed.Enqueue((path, query.ToArray()));
                return Task.FromResult<IBrowserSocket>(Interlocked.Increment(ref calls) == 1 ? socket1 : socket2);
            },
        };

        var service = new BrowserService(gw, new FakeMemoryStore());
        var session = new BrowserWatchSession(service, RowId, BrowserWire.LegacyPlugin, "finance", "Finance");
        socket1.Enqueue("""{"type":"state","tabs":[],"tab":null,"follow":true,"control":{"state":"bot","mine":false,"epoch":1}}""");

        session.SetShown(true);
        await WaitUntilAsync(() => session.Link == BrowserWatchLink.Live);

        socket1.Drop(1006);
        await WaitUntilAsync(() => session.Link == BrowserWatchLink.Reconnecting);

        socket2.Enqueue("""{"type":"state","tabs":[],"tab":null,"follow":true,"control":{"state":"bot","mine":false,"epoch":2}}""");
        session.LinkRestored();
        await WaitUntilAsync(() => session.Link == BrowserWatchLink.Live && calls == 2);

        var list = dialed.ToArray();
        Assert.Equal(2, list.Length);
        Assert.All(list, call =>
        {
            Assert.Equal($"{BrowserWire.LegacyPlugin}/sessions/{RowId}/watch", call.Path);
            Assert.Empty(call.Query);
        });

        session.Stop();
        service.Shutdown();
    }

    private static async Task WaitUntilAsync(Func<bool> predicate, int timeoutMs = 4000)
    {
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (!predicate() && DateTime.UtcNow < deadline)
            await Task.Delay(15);
        Assert.True(predicate());
    }
}
