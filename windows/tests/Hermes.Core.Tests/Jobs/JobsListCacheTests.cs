using System.Text.Json.Nodes;
using Hermes.Core.Jobs;
using Hermes.Core.Net;
using Xunit;

namespace Hermes.Core.Tests.Jobs;

public class JobsListCacheTests
{
    private static Task<JsonNode?> Body(string text) => Task.FromResult<JsonNode?>(JsonNode.Parse(text));

    /// Two callers arriving while a read is out share it: one fetch, one answer (BUG-3's overlapping reads).
    [Fact]
    public async Task OneFlightSharesTheRead()
    {
        var cache = new JobsListCache();
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var calls = 0;
        var mine = Task.WhenAll(
            cache.ReadAsync("k", async () => { Interlocked.Increment(ref calls); started.SetResult(); await release.Task; return Body("""{"a":1}""").Result; }),
            Task.Run(async () =>
            {
                await started.Task;
                return await cache.ReadAsync("k", () => throw new Exception("the read already out is shared; this must not run"));
            }));
        release.SetResult();
        var answers = await mine;
        Assert.Equal(1, calls);
        Assert.All(answers, a => Assert.Equal(1, a!["a"]!.GetValue<int>()));
    }

    /// A landed answer is reused for ListFresh, and a Forget makes the next read real again.
    [Fact]
    public async Task FreshUntilForgotten()
    {
        var cache = new JobsListCache();
        var calls = 0;
        Task<JsonNode?> Fetch() { Interlocked.Increment(ref calls); return Body("""{"n":1}"""); }
        var first = await cache.ReadAsync("k", Fetch);
        var second = await cache.ReadAsync("k", Fetch);   // fresh: reused
        Assert.Equal(1, calls);
        Assert.Same(first, second);
        cache.Forget("k");
        await cache.ReadAsync("k", Fetch);
        Assert.Equal(2, calls);
    }

    /// A failed read is kept by nobody: the next caller reads again.
    [Fact]
    public async Task AFailingReadIsNotKept()
    {
        var cache = new JobsListCache();
        var calls = 0;
        Task<JsonNode?> Fetch()
        {
            var n = ++calls;
            return n == 1 ? throw new GatewayException("http", "The gateway answered 500.", 500) : Body("""{"ok":true}""");
        }
        await Assert.ThrowsAnyAsync<GatewayException>(() => cache.ReadAsync("k", Fetch));
        var answer = await cache.ReadAsync("k", Fetch);
        Assert.True(answer!["ok"]!.GetValue<bool>());
        Assert.Equal(2, calls);
    }
}
