using Hermes.Core.Auth;
using Hermes.Core.Gateways;
using Hermes.Core.Model;
using Hermes.Core.Shell;
using HermesHQ.Services;

namespace Hermes.Core.Tests;

[Collection("Shutdown UI")]
public class GatewayNewsShutdownTests
{
    // No session or network: the real hub can only reach this manually released reader. Even a reader
    // that doesn't honor cancellation immediately must not start another chat read or publish a late result.
    private sealed class HeldReader(bool honorCancellation) : IParkedReader
    {
        public readonly TaskCompletionSource<ParkedAnswer> First = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public CancellationToken InFlight;
        public int Reads, Disposals;
        public Task<ParkedAnswer> ReadAsync(string id, string? profile, CancellationToken ct)
        {
            if (++Reads != 1) return Task.FromResult<ParkedAnswer>(new ParkedAnswer.Missing());
            InFlight = ct;
            return honorCancellation ? First.Task.WaitAsync(ct) : First.Task;
        }
        public void Dispose() => Disposals++;
    }

    [Theory]
    [InlineData("before quit")]
    [InlineData("during quit")]
    [InlineData("refused during quit")]
    [InlineData("honors cancellation")]
    [InlineData("after timeout")]
    public async Task AStartedNewsReadIsJoinedAndCannotStartAnotherRead(string delivery)
    {
        bool completeBeforeQuit = delivery == "before quit", timeout = delivery == "after timeout";
        var saved = new SavedAccounts();
        var parked = new StoredAccount("https://parked.example.com", "fixture", [new SavedCookie("fixture", "", "example.com", "/", null, false)]);
        var current = new StoredAccount("https://current.example.com", "fixture");
        saved.Upsert(parked); saved.Upsert(current);
        var store = new MemoryTokenStore(); store.Write(saved.ToJson());
        var rows = new MemoryParkedRosters();
        rows.Write(parked.Key, [new ParkedChat("ivy", "s1", null, 1), new ParkedChat("ivy", "s2", null, 1)]);
        var reader = new HeldReader(delivery == "honors cancellation");
        var hub = new GatewayHub(store, rows, _ => reader) { CurrentKey = current.Key };
        var changes = 0;
        hub.Changed += () => changes++;
        AppState.Gateways.Inner = hub;
        try
        {
            var pending = hub.CheckAsync(force: false);
            Assert.Equal(1, reader.Reads);
            Assert.False(pending.IsCompleted);
            if (completeBeforeQuit) { reader.First.SetResult(new ParkedAnswer.Missing()); await pending; }
            var changesAtQuit = changes;
            int? disposalsAtSocket = null;
            var plan = AppShutdown.Build();
            var quit = plan.RunAsync("window closing", _ => { }, stepLimit: timeout ? TimeSpan.FromMilliseconds(60) : null, milestone: (stage, progress) =>
            {
                if (stage == ShutdownStage.Gateway && progress == ShutdownProgress.Begin)
                    disposalsAtSocket = reader.Disposals;
            });
            var reachedSocketBeforeRelease = disposalsAtSocket.HasValue;
            var cancelledAtStop = reader.InFlight.IsCancellationRequested;
            if (timeout)
            {
                await quit.WaitAsync(TimeSpan.FromSeconds(10));
                Assert.False(pending.IsCompleted);
                Assert.Equal(0, reader.Disposals); // bounded quit must not label this disposed
            }
            reader.First.TrySetResult(delivery == "refused during quit" ? new ParkedAnswer.Refused() : new ParkedAnswer.Missing());
            await pending;
            var outcome = Assert.Single(await quit, r => r.Name == "gateway news timer").Outcome;
            if (timeout) Assert.StartsWith("still running after", outcome);
            else Assert.Equal("done", outcome);
            Assert.Empty(await plan.RunAsync("second quit", _ => { }));
            hub.CheckSoon(force: true);
            await hub.CheckAsync(force: true);
            if (delivery != "honors cancellation") Assert.Equal(completeBeforeQuit, reachedSocketBeforeRelease);
            Assert.Multiple(
                () => Assert.Equal(!completeBeforeQuit, cancelledAtStop),
                () => Assert.Equal(completeBeforeQuit ? 2 : 1, reader.Reads),
                () => Assert.Equal(timeout ? 0 : 1, disposalsAtSocket),
                () => Assert.Equal(1, reader.Disposals),
                () => Assert.Equal(changesAtQuit, changes),
                () => Assert.Equal(completeBeforeQuit, hub.LastCheckEnded.HasValue),
                () => Assert.True(hub.HasUsableSession(parked)));
        }
        finally { reader.First.TrySetResult(new ParkedAnswer.Missing()); AppState.Gateways.Inner = null; }
    }
}
