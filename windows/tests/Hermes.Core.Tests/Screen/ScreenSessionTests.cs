// [WIN-SCREEN-SESSION] The Screen's state machine (docs/spec/3x-screen.md §4, §5.5, §5.8, §5.11, §5.12) against a gateway
// model with Hermes's lease rules and sockets the tests end by hand: the Mac's Tests/Screen/ScreenSessionTests.swift at
// 93f984bb1, case for case, plus the session cases of its ScreenServiceTests suite. The Mac runs these .serialized on
// its main actor; here they run one at a time (no parallel collection) on a MainLoop. Waits poll for at least 10 s.

using System.Diagnostics;
using System.Text.Json.Nodes;
using Hermes.Core.Screen;
using static Hermes.Core.Tests.Screen.ScreenWaits;
using P = Hermes.Core.Screen.ScreenSession.Phase;
using N = Hermes.Core.Screen.ScreenSession.Notice;

namespace Hermes.Core.Tests.Screen;

[CollectionDefinition("ScreenSession", DisableParallelization = true)]
public sealed class ScreenSessionCollection;

[Collection("ScreenSession")]
public sealed class ScreenSessionTests
{
    private static readonly TimeSpan TestLimit = TimeSpan.FromSeconds(10);
    private static List<string> Keys(FakeCall? call) => call?.Keys ?? ["<no call>"];
    private static bool IsNoAnswer(P p) => p is P.NoAnswer;
    private static bool IsEnded(P p) => p is P.Ended;
    private static P Ended(string title, string? detail = null) => new P.Ended(title, detail);
    private static P Fallback(ScreenSession.Fallback kind) => new P.FallbackTo(kind);

    // Opening (L516, S0–S4)

    [Fact]
    public async Task OpensToALivePictureAndOnlyWatches()
    {
        using var rig = new SessionRig();
        Assert.Equal(new P.Connecting(), rig.Phase);
        Assert.True(await rig.OpenLive());
        Assert.Equal(["display.status", "display.observe"], rig.Display.Methods);
        Assert.Equal(["profile"], Keys(rig.Display.Calls("display.status").FirstOrDefault()));
        Assert.Equal(["profile"], Keys(rig.Display.Calls("display.observe").FirstOrDefault()));      // no viewer id yet
        Assert.Equal("Hermes is in control", rig.Get(s => s.Caption));
        Assert.True(!rig.Get(s => s.Holding) && rig.Get(s => s.Viewer) != null);
        Assert.Equal("This Mac · 64×48", rig.Get(s => s.Label));
        Assert.True(rig.Frames >= 1 && rig.Notices.Contains(N.Live));
        // Watching sends nothing but the handshake and update requests, whatever the view asks for.
        rig.Do(s =>
        {
            s.SendPointer(1, 3, 3);
            s.SendKeys(ScreenKeys.Text("a"));
            s.Type("hello");
            s.Paste("clip");
        });
        await Task.Delay(150);
        Assert.Empty(rig.Socket!.Inputs);
        var kinds = rig.Socket!.Sent.Where(d => d.Length > 0).Select(d => d[0]).ToHashSet();
        byte[] allowed = [82, 1, 0, 2, 3];                                                // 82 = "R" of the version line
        Assert.Subset(allowed.ToHashSet(), kinds);
        rig.Do(s => s.Leave());
    }

    [Fact]
    public async Task TheStatusNeverArrivingSaysSoAndRetryWorks()
    {
        using var rig = new SessionRig();
        rig.Display.Set(s => s.Hang = ["display.status"]);
        Assert.Equal(new P.Connecting(), rig.Get(s => { s.Open(); return s.CurrentPhase; }));     // in the same turn, as on the main actor
        Assert.True(await ScreenWait(() => rig.Phase == new P.NoAnswer(null)));
        Assert.Empty(rig.Display.Calls("display.observe"));
        rig.Display.Set(s => s.Hang = []);
        Assert.Equal(new P.Connecting(), rig.Get(s => { s.Open(); return s.CurrentPhase; }));     // "Retry"
        Assert.True(await rig.Live());
        Assert.Equal(2, rig.Display.Calls("display.status").Count);
        rig.Do(s => s.Leave());
    }

    /// The request's own 20 s limit can beat the 20 s wait by a hair: the words are the same either way.
    [Fact]
    public async Task AStatusRequestThatTimesOutReadsAsNeverArrived()
    {
        using var rig = new SessionRig();
        rig.Display.Set(s => s.Fail["display.status"] = FakeDisplay.TimedOut());
        rig.Do(s => s.Open());
        Assert.True(await ScreenWait(() => rig.Phase == new P.NoAnswer(null)));
        rig.Do(s => s.Leave());
    }

    [Fact]
    public async Task AFailedStatusShowsTheGatewaysWordsAtOnce()
    {
        using var rig = new SessionRig();
        rig.Display.Set(s => s.Fail["display.status"] = FakeDisplay.Rpc(5300, "Bot Desktop state is unreadable."));
        rig.Do(s => s.Open());
        Assert.True(await ScreenWait(() => rig.Phase == new P.NoAnswer("Bot Desktop state is unreadable.")));
        // The app coming to the front asks again by itself.
        rig.Display.Set(s => s.Fail.Clear());
        rig.Do(s => s.ResumeSignal());
        Assert.True(await rig.Live());
        rig.Do(s => s.Leave());
    }

    [Fact]
    public async Task ASlowStatusIsNotAFailure()
    {
        using var rig = new SessionRig();
        rig.Display.Set(s => s.Delay["display.status"] = TimeSpan.FromMilliseconds(150));
        rig.Do(s => s.Open());
        Assert.True(await rig.Live());
        Assert.DoesNotContain(rig.Phases, IsNoAnswer);
        rig.Do(s => s.Leave());
    }

    [Fact]
    public async Task AnOlderAnswerNeverReplacesANewerOne()
    {
        using var rig = new SessionRig();
        rig.Display.Set(s => { s.Running = false; s.Delay["display.status"] = TimeSpan.FromMilliseconds(250); });
        rig.Do(s => s.Open());
        await Task.Delay(50);
        rig.Display.Set(s => { s.Delay.Clear(); s.Installed = false; });
        rig.Do(s => s.Open());
        Assert.True(await ScreenWait(() => rig.Phase is P.Missing));
        await Task.Delay(400);                                                            // the first, slower answer lands now
        Assert.IsType<P.Missing>(rig.Phase);
        rig.Do(s => s.Leave());
    }

    [Fact]
    public async Task EachStateOfABotWithoutALiveScreen()
    {
        using var rig = new SessionRig();
        rig.Display.Set(s => s.Fail["display.status"] = FakeDisplay.Rpc(-32601, "Method not found"));
        rig.Do(s => s.Open());
        Assert.True(await ScreenWait(() => rig.Phase == Fallback(ScreenSession.Fallback.Unavailable)));
        Assert.Equal(ScreenKind.Screenshots, rig.Main.Read(() => rig.Service.Kind("default")));
        rig.Display.Set(s => { s.Fail.Clear(); s.Supported = false; });
        rig.Do(s => s.Open());
        Assert.True(await ScreenWait(() => rig.Phase == Fallback(ScreenSession.Fallback.Unsupported)));
        rig.Display.Set(s => { s.Supported = true; s.Installed = false; s.InstallCommand = "sudo apt install tigervnc"; });
        rig.Do(s => s.Open());
        Assert.True(await ScreenWait(() => rig.Phase is P.Missing));
        Assert.Equal("sudo apt install tigervnc", rig.Get(s => s.Status?.InstallCommand));
        Assert.Equal(ScreenKind.Live, rig.Main.Read(() => rig.Service.Kind("default")));
        rig.Display.Set(s => { s.Installed = true; s.Running = false; s.Blocker = "Allow Screen Recording for Dispatch Screen on the Mac"; });
        rig.Do(s => s.Open());
        Assert.True(await ScreenWait(() => rig.Phase == Fallback(ScreenSession.Fallback.Blocked)));
        Assert.Equal("Allow Screen Recording for Hermes HQ Screen on the Mac", rig.Get(s => s.Status?.Blocker));
        rig.Display.Set(s => s.Blocker = null);
        rig.Do(s => s.Open());
        Assert.True(await ScreenWait(() => rig.Phase is P.Off));
        Assert.Empty(rig.Display.Calls("display.observe"));
        rig.Do(s => s.Leave());
    }

    [Fact]
    public async Task StartScreenStartsItAndAFailureIsShown()
    {
        using var rig = new SessionRig();
        rig.Display.Set(s => { s.Running = false; s.Fail["display.start"] = FakeDisplay.Rpc(5300, "Xvnc could not start"); });
        rig.Do(s => s.Open());
        Assert.True(await ScreenWait(() => rig.Phase is P.Off));
        Assert.Equal(ScreenSession.Busy.Start, rig.Get(s => { s.Start(); return s.BusyWith; }));
        Assert.True(await ScreenWait(() => rig.Get(s => s.ErrorLine == "Xvnc could not start" && s.BusyWith == null)));
        rig.Display.Set(s => s.Fail.Clear());
        rig.Do(s => s.Start());
        Assert.True(await rig.Live());
        Assert.Null(rig.Get(s => s.ErrorLine));
        Assert.Equal(["profile"], Keys(rig.Display.Calls("display.start").LastOrDefault()));
        rig.Do(s => s.Leave());
    }

    [Fact]
    public async Task AStatusEventOpensTheScreenThatWasOff()
    {
        using var rig = new SessionRig();
        rig.Display.Set(s => s.Running = false);
        rig.Do(s => s.Open());
        Assert.True(await ScreenWait(() => rig.Phase is P.Off));
        rig.Display.Set(s => s.Running = true);
        rig.Display.EmitStatus();
        Assert.True(await rig.Live());
        // And one that says it stopped closes the stream without a hand-back.
        rig.Display.Set(s => s.Running = false);
        rig.Display.EmitStatus();
        Assert.True(await ScreenWait(() => rig.Phase is P.Off));
        // ScreenStream.Stop hands the close to its sender (the C# stream closes off the UI thread), so it is waited for.
        Assert.True(await ScreenWait(() => rig.Socket!.Closes.Count > 0));
        Assert.Equal([false], rig.Socket!.Closes);
        rig.Do(s => s.Leave());
    }

    // Control (L509)

    [Fact]
    public async Task TakeOverThenHandBack()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        var viewer = rig.Get(s => s.Viewer);
        Assert.True(await rig.TakeOver());
        var acquire = rig.Display.Calls("display.lease.acquire").FirstOrDefault();
        Assert.Equal(["profile", "viewer_id"], Keys(acquire));
        Assert.Equal(viewer?.Id, acquire?.Str("viewer_id"));
        Assert.True(rig.Get(s => s.Caption) == "You are in control" && rig.Notices.Contains(N.ControlStarted));
        Assert.True(rig.Display.Lease.Holder == "human" && rig.Display.Lease.Hash == viewer?.Hash);
        // DECISION D14: the first input after control starts releases any button a dropped link left down.
        rig.Do(s =>
        {
            s.SendPointer(0, 10, 12);
            s.SendPointer(1, 10, 12);
            s.SendPointer(0, 10, 12);
            s.SendKeys(ScreenKeys.Text("a"));
        });
        Assert.True(await ScreenWait(() => SessionRig.Inputs(rig.Socket).Count == 6));
        Assert.Equal(["pointer 0 32,24", "pointer 0 10,12", "pointer 1 10,12", "pointer 0 10,12", "key 61 down", "key 61 up"], SessionRig.Inputs(rig.Socket));
        rig.Do(s => s.HandBack());
        Assert.True(await ScreenWait(() => rig.Get(s => !s.Holding && s.BusyWith == null)));
        var release = rig.Display.Calls("display.lease.release").FirstOrDefault();
        Assert.Equal(["profile", "viewer_id"], Keys(release));
        Assert.Equal(viewer?.Id, release?.Str("viewer_id"));
        Assert.True(rig.Get(s => s.Caption) == "Hermes is in control" && rig.Notices.Contains(N.ControlEnded));
        rig.Do(s => s.SendPointer(1, 1, 1));
        await Task.Delay(100);
        Assert.Equal(6, SessionRig.Inputs(rig.Socket).Count);
        Assert.Empty(rig.Socket!.Closes);                                                   // the stream stays up to watch
        rig.Do(s => s.Leave());
    }

    [Fact]
    public async Task AHeldButtonIsReleasedBeforeControlIsGivenAway()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        Assert.True(await rig.TakeOver());
        rig.Do(s => s.SendPointer(1, 20, 20));                                              // a drag in progress
        rig.Do(s => s.HandBack());
        Assert.True(await ScreenWait(() => !rig.Get(s => s.Holding)));
        Assert.Equal(["pointer 1 20,20", "pointer 0 20,20"], SessionRig.Inputs(rig.Socket).TakeLast(2));
        // The same before a pause.
        Assert.True(await rig.TakeOver());
        rig.Do(s => s.SendPointer(1, 30, 30));
        rig.Do(s => s.SetOnView(false, immediately: true));
        Assert.True(await ScreenWait(() => rig.Socket!.Closes.SequenceEqual([false])));
        Assert.True(await ScreenWait(() => SessionRig.Inputs(rig.Socket).LastOrDefault() == "pointer 0 30,30"),
            string.Join(", ", SessionRig.Inputs(rig.Socket)));
        rig.Do(s => s.Leave());
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task HandBackWaitsForTheButtonUpWriteThenForTheLeaseReply(bool upAlreadyQueued)
    {
        using var rig = new SessionRig(flushClock: new Voice.ManualTime());
        Assert.True(await rig.OpenLive());
        Assert.True(await rig.TakeOver());
        var socket = rig.Socket!;
        var up = socket.HoldWrite(RfbMessage.Pointer(0, 20, 20));
        var writtenAtRpc = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var reply = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        rig.Display.Set(d => d.AtCall["display.lease.release"] = ct =>
        {
            writtenAtRpc.SetResult(up.Written);
            return reply.Task.WaitAsync(ct);
        });
        try
        {
            rig.Do(s =>
            {
                s.SendPointer(1, 20, 20);
                if (upAlreadyQueued) s.SendPointer(0, 20, 20);
                s.Type("pending"); // posted typing is invalidated in the same turn
                s.HandBack();
            });
            var write = await up.Started.Task.WaitAsync(TestLimit);
            rig.Do(_ => { }); // the session's posted lease work has had its turn, independently of the sender
            Assert.False(write.IsCompleted);
            Assert.Equal(["pointer 0 32,24", "pointer 1 20,20"], SessionRig.Inputs(socket));
            Assert.Empty(rig.Display.Calls("display.lease.release"));
            Assert.True(rig.Get(s => s.Holding && !s.CanSendInput && s.BusyWith == ScreenSession.Busy.Give));
            rig.Do(s => { s.HandBack(); s.SendPointer(1, 3, 3); s.SendKeys(ScreenKeys.Text("z")); s.Type("z"); });
            up.Allow.SetResult();
            Assert.True(await writtenAtRpc.Task.WaitAsync(TestLimit), "release RPC entered before the button-up write finished");
            Assert.True(rig.Get(s => s.Holding && !s.CanSendInput)); // writing the button-up did not release the lease
            Assert.Equal("human", rig.Display.Lease.Holder);
            reply.SetResult();
            Assert.True(await ScreenWait(() => rig.Get(s => !s.Holding && s.BusyWith == null)));
            Assert.Equal("agent", rig.Display.Lease.Holder);
            var call = Assert.Single(rig.Display.Calls("display.lease.release"));
            Assert.Equal(["profile", "viewer_id"], Keys(call));
            Assert.Equal(rig.Get(s => s.Viewer!.Id), call.Str("viewer_id"));
            Assert.Empty(socket.Closes); // hand-back keeps the picture for watching
            rig.Do(s => s.Leave());
            Assert.True(await ScreenWait(() => socket.Closes.SequenceEqual([false]))); // past anything the view could have queued
            Assert.Equal(["pointer 0 32,24", "pointer 1 20,20", "pointer 0 20,20"], SessionRig.Inputs(socket));
        }
        finally { up.Allow.TrySetResult(); reply.TrySetResult(); }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task PausingWithAHeldButtonClosesWithoutGivingAwayTheLease(bool giveWhilePausing)
    {
        using var rig = new SessionRig(flushClock: new Voice.ManualTime());
        Assert.True(await rig.OpenLive());
        Assert.True(await rig.TakeOver());
        var socket = rig.Socket!;
        var up = socket.HoldWrite(RfbMessage.Pointer(0, 30, 30));
        rig.Do(s => { s.SendPointer(1, 30, 30); s.SetOnView(false, immediately: true); });
        var write = await up.Started.Task.WaitAsync(TestLimit);
        Assert.True(rig.Get(s => s.Holding && !s.OnView && !s.CanSendInput));
        if (giveWhilePausing) rig.Do(s => s.HandBack());
        rig.Do(s => s.SendPointer(1, 2, 2));
        Assert.Empty(socket.Closes);
        Assert.Empty(rig.Display.Calls("display.lease.release"));
        up.Allow.SetResult();
        Assert.True(await ScreenWait(() => socket.Closes.SequenceEqual([false])));
        Assert.True(write.IsCompletedSuccessfully);
        Assert.Equal(["pointer 0 32,24", "pointer 1 30,30", "pointer 0 30,30"], SessionRig.Inputs(socket));
        Assert.True(await ScreenWait(() => rig.Get(s => s.BusyWith == null)));
        Assert.Equal(!giveWhilePausing, rig.Get(s => s.Holding));
        Assert.Equal(giveWhilePausing ? 1 : 0, rig.Display.Calls("display.lease.release").Count);
    }

    [Theory]
    [InlineData("error")]
    [InlineData("cancel")]
    [InlineData("deadline")]
    public async Task AnUnwrittenButtonUpDoesNotStrandControl(string ending)
    {
        var clock = new Voice.ManualTime();
        using var rig = new SessionRig(flushClock: clock);
        Assert.True(await rig.OpenLive());
        Assert.True(await rig.TakeOver());
        var socket = rig.Socket!;
        var up = socket.HoldWrite(RfbMessage.Pointer(0, 20, 20));
        var cutAtRpc = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        rig.Display.Set(d => d.AtCall["display.lease.release"] = _ =>
        {
            cutAtRpc.SetResult(!up.Written && socket.Closes.SequenceEqual([false]));
            return Task.CompletedTask;
        });
        rig.Do(s => { s.SendPointer(1, 20, 20); s.HandBack(); });
        var write = await up.Started.Task.WaitAsync(TestLimit);
        rig.Do(_ => { });
        Assert.Empty(rig.Display.Calls("display.lease.release"));
        if (ending == "error") up.Allow.SetException(new IOException("fixture write failed"));
        else if (ending == "cancel") up.Allow.SetCanceled();
        else
        {
            clock.Advance(TimeSpan.FromMilliseconds(249));
            Assert.Empty(socket.Closes);
            Assert.Empty(rig.Display.Calls("display.lease.release"));
            clock.Advance(TimeSpan.FromMilliseconds(1));
        }
        Assert.True(await cutAtRpc.Task.WaitAsync(TestLimit), "abandon the old transport before returning the lease by id");
        if (ending == "error") await Assert.ThrowsAsync<IOException>(() => write.WaitAsync(TestLimit));
        else await Assert.ThrowsAnyAsync<OperationCanceledException>(() => write.WaitAsync(TestLimit));
        up.Allow.TrySetResult(); // even unlocking a timed-out transport cannot write into the next lease
        Assert.True(await ScreenWait(() => rig.Get(s => !s.Holding && s.BusyWith == null)));
        Assert.Equal("agent", rig.Display.Lease.Holder);
        var call = Assert.Single(rig.Display.Calls("display.lease.release"));
        Assert.Equal(["profile", "viewer_id"], Keys(call));
        Assert.Equal(["pointer 0 32,24", "pointer 1 20,20"], SessionRig.Inputs(socket));
    }

    [Fact]
    public async Task ACompletedButtonUpButRefusedReleaseKeepsOurHold()
    {
        using var rig = new SessionRig(flushClock: new Voice.ManualTime());
        Assert.True(await rig.OpenLive());
        Assert.True(await rig.TakeOver());
        rig.Display.Set(d => d.Fail["display.lease.release"] = FakeDisplay.Rpc(5300, "fixture refusal"));
        rig.Do(s => { s.SendPointer(1, 20, 20); s.HandBack(); });
        Assert.True(await ScreenWait(() => rig.Get(s => s.BusyWith == null && s.ErrorLine == "fixture refusal")));
        Assert.Equal("pointer 0 20,20", SessionRig.Inputs(rig.Socket)[^1]);
        Assert.True(rig.Get(s => s.Holding && s.CanSendInput));
        Assert.Equal(rig.Get(s => s.Viewer!.Id), rig.Main.Read(() => rig.Holds.Saved(rig.Account, "default")?.Id));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task AWatcherCannotHandBackOrSendAButtonUp(bool anotherViewer)
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        if (anotherViewer) rig.Display.OtherTakes();
        var lease = rig.Display.Lease;
        Assert.Equal(anotherViewer, rig.Get(s => s.OtherHolds));
        rig.Do(s => { s.SendPointer(1, 20, 20); s.HandBack(); s.Leave(); });
        Assert.True(await ScreenWait(() => rig.Socket!.Closes.SequenceEqual([false])));
        Assert.Empty(rig.Display.Calls("display.lease.release"));
        Assert.Empty(rig.Socket!.Inputs);
        Assert.Equal(lease, rig.Display.Lease);
    }

    [Fact]
    public async Task AnAuthoritativeOwnerChangeDuringTheDrainCancelsOurRelease()
    {
        using var rig = new SessionRig(flushClock: new Voice.ManualTime());
        Assert.True(await rig.OpenLive());
        Assert.True(await rig.TakeOver());
        var socket = rig.Socket!;
        var up = socket.HoldWrite(RfbMessage.Pointer(0, 20, 20));
        rig.Do(s => { s.SendPointer(1, 20, 20); s.HandBack(); });
        var write = await up.Started.Task.WaitAsync(TestLimit);
        // Deliver the new authoritative status first, then the old transport's cancellation.
        rig.Display.Set(d => { d.Hash = ScreenWire.ViewerHash("other-viewer"); d.Epoch++; });
        rig.Display.EmitStatus();
        Assert.True(rig.Get(s => s.OtherHolds && !s.Holding));
        var lease = rig.Display.Lease;
        up.Allow.SetCanceled();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => write.WaitAsync(TestLimit));
        Assert.True(await ScreenWait(() => rig.Get(s => s.BusyWith == null)));
        Assert.Empty(rig.Display.Calls("display.lease.release"));
        Assert.Equal(lease, rig.Display.Lease);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task LeavingAsAPauseDrainsWaitsBeforeReleasingById(bool confirm)
    {
        using var rig = new SessionRig(flushClock: new Voice.ManualTime());
        Assert.True(await rig.OpenLive());
        Assert.True(await rig.TakeOver());
        var socket = rig.Socket!;
        var up = socket.HoldWrite(RfbMessage.Pointer(0, 20, 20));
        rig.Do(s => { s.SendPointer(1, 20, 20); s.SetOnView(false, immediately: true); });
        await up.Started.Task.WaitAsync(TestLimit);
        var writtenAtRpc = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        rig.Display.Set(d => d.AtCall["display.lease.release"] = _ =>
        {
            writtenAtRpc.SetResult(up.Written);
            return Task.CompletedTask;
        });
        try
        {
            Task leaving = confirm ? rig.Main.RunAsync(() => rig.Session.LeaveConfirming()) : Task.CompletedTask;
            if (!confirm) rig.Do(s => s.Leave());
            Assert.True(rig.Get(s => s.Left));
            Assert.Empty(rig.Display.Calls("display.lease.release"));
            up.Allow.SetResult();
            Assert.True(await writtenAtRpc.Task.WaitAsync(TestLimit));
            await leaving.WaitAsync(TestLimit);
            var call = Assert.Single(rig.Display.Calls("display.lease.release"));
            Assert.Equal(rig.Get(s => s.Viewer!.Id), call.Str("viewer_id"));
            Assert.True(call.Bool("force"));
            Assert.Equal([false], socket.Closes);
        }
        finally { up.Allow.TrySetResult(); }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task PauseOrLeaveDuringHandBackDoesNotRestartTheFlushBudget(bool leave)
    {
        var clock = new Voice.ManualTime();
        using var rig = new SessionRig(flushClock: clock);
        Assert.True(await rig.OpenLive());
        Assert.True(await rig.TakeOver());
        var socket = rig.Socket!;
        var up = socket.HoldWrite(RfbMessage.Pointer(0, 20, 20));
        rig.Do(s => { s.SendPointer(1, 20, 20); s.HandBack(); });
        var write = await up.Started.Task.WaitAsync(TestLimit);
        try
        {
            clock.Advance(TimeSpan.FromMilliseconds(200));
            rig.Do(s => { if (leave) s.Leave(); else s.SetOnView(false, immediately: true); });
            Assert.Empty(socket.Closes);
            clock.Advance(TimeSpan.FromMilliseconds(50)); // the original hand-back deadline
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => write.WaitAsync(TestLimit));
            Assert.Equal([leave], socket.Closes);
            if (leave) Assert.Empty(rig.Display.Calls("display.lease.release")); // Leave already claimed the 1000 close
            else Assert.True(await ScreenWait(() => !rig.Get(s => s.Holding)));
        }
        finally { up.Allow.TrySetResult(); clock.Advance(ScreenStream.StopCut); }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task HandingBackASavedIdWaitsForItsDetachedWrite(bool anotherTookOver)
    {
        using var rig = new SessionRig(flushClock: new Voice.ManualTime());
        Assert.True(await rig.OpenLive());
        Assert.True(await rig.TakeOver());
        var old = rig.Get(s => s.Viewer!);
        var socket = rig.Socket!;
        var up = socket.HoldWrite(RfbMessage.Pointer(0, 20, 20));
        // Re-observe mints a new viewer. Without a successful recheck it cannot reclaim the old id.
        rig.Display.Set(d => d.Fail["display.status"] = FakeDisplay.Rpc(5300, "unavailable"));
        rig.Do(s => s.SendPointer(1, 20, 20));
        rig.Display.ReconnectGateway();
        await up.Started.Task.WaitAsync(TestLimit);
        try
        {
            Assert.True(await ScreenWait(() => rig.Get(s => s.CurrentPhase is P.Live && s.Held?.Id == old.Id && !s.Holding)));
            rig.Do(s => s.HandBack());
            rig.Do(_ => { });
            Assert.Empty(rig.Display.Calls("display.lease.release"));
            if (anotherTookOver)
            {
                rig.Display.OtherTakes();
                Assert.True(rig.Get(s => s.OtherHolds)); // the new authority is known before the drain finishes
            }
            up.Allow.SetResult();
            Assert.True(await ScreenWait(() => rig.Get(s => s.BusyWith == null)));
            Assert.True(up.Written);
            if (anotherTookOver)
            {
                Assert.Empty(rig.Display.Calls("display.lease.release"));
                Assert.True(rig.Get(s => s.OtherHolds));
            }
            else
            {
                var call = Assert.Single(rig.Display.Calls("display.lease.release"));
                Assert.Equal(old.Id, call.Str("viewer_id"));
                Assert.True(call.Bool("force"));
                Assert.Equal("agent", rig.Display.Lease.Holder);
            }
        }
        finally { up.Allow.TrySetResult(); }
    }

    [Fact]
    public async Task ARefusedTakeOverReadsInFullUntilDismissedOrUntilOneWorks()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        rig.Display.Set(s => s.Fail["display.lease.acquire"] = FakeDisplay.Rpc(5300, "Lease store is busy"));
        rig.Do(s => s.TakeOver());
        Assert.True(await ScreenWait(() => rig.Get(s => s.ErrorLine) == "Lease store is busy"));
        Assert.True(rig.Get(s => !s.Holding && s.BusyWith == null));
        rig.Do(s => s.DismissError());
        Assert.Null(rig.Get(s => s.ErrorLine));
        rig.Do(s => s.TakeOver());
        Assert.True(await ScreenWait(() => rig.Get(s => s.ErrorLine) != null));
        rig.Display.Set(s => s.Fail.Clear());
        Assert.True(await rig.TakeOver());
        Assert.Null(rig.Get(s => s.ErrorLine));
        rig.Do(s => s.Leave());
    }

    [Fact]
    public async Task AnotherViewerHoldsAndForceReturnsItToTheBot()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        rig.Display.OtherTakes();
        Assert.True(await ScreenWait(() => rig.Get(s => s.OtherHolds)));
        Assert.True(rig.Get(s => s.Caption) == "Another viewer is in control" && rig.Get(s => s.Tone) == ScreenTone.Other);
        rig.Do(s => s.ForceHandBack());
        Assert.True(await ScreenWait(() => rig.Get(s => !s.OtherHolds && s.BusyWith == null)));
        var release = rig.Display.Calls("display.lease.release").FirstOrDefault();
        Assert.Equal(["force", "profile"], Keys(release));
        Assert.True(release?.Bool("force"));
        Assert.Equal("agent", rig.Display.Lease.Holder);
        rig.Do(s => s.Leave());
    }

    [Fact]
    public async Task AStaleLeaseEventIsIgnored()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        Assert.True(await rig.TakeOver());
        var epoch = rig.Get(s => s.Lease?.Epoch ?? 0);
        rig.Display.Emit("display.lease", new JsonObject
        {
            ["profile_key"] = FakeDisplay.HomeKey, ["lease"] = new JsonObject { ["holder"] = "agent", ["viewer_hash"] = null, ["epoch"] = epoch - 1 },
        });
        rig.Display.Emit("display.lease", new JsonObject
        {
            ["profile_key"] = "/fixture/home/profiles/someone-else", ["lease"] = new JsonObject { ["holder"] = "agent", ["viewer_hash"] = null, ["epoch"] = epoch + 5 },
        });
        await Task.Delay(100);
        Assert.True(rig.Get(s => s.Holding));
        rig.Do(s => s.Leave());
    }

    [Fact]
    public async Task TypedTextGoesOutInSlicesAndStopsWhenControlEnds()
    {
        using var rig = new SessionRig();
        rig.Display.Set(s => s.Display = ":7");                                             // a Linux screen: paste is typed
        Assert.True(await rig.OpenLive());
        Assert.True(await rig.TakeOver());
        Assert.True(rig.Main.Read(() =>
        {
            var pasted = rig.Session.Paste(new string('x', 5_000));
            return pasted && rig.Session.TypingBacklog > 0;                                // not all at once
        }));
        Assert.True(await ScreenWait(() => SessionRig.Inputs(rig.Socket).Count(i => i.StartsWith("key", StringComparison.Ordinal)) == 10_000));
        Assert.Equal(0, rig.Get(s => s.TypingBacklog));
        // A long paste, then the bot takes control back: the rest is never sent.
        Assert.True(rig.Get(s => s.Paste(new string('y', 200_000))));
        rig.Display.AgentTakes();
        Assert.True(await ScreenWait(() => !rig.Get(s => s.Holding)));
        Assert.Equal(0, rig.Get(s => s.TypingBacklog));
        await Task.Delay(200);
        var typed = SessionRig.Inputs(rig.Socket).Count(i => i.StartsWith("key 79", StringComparison.Ordinal));
        Assert.True(typed < 400_000 && typed % 2 == 0, $"{typed}");                         // whole key presses only
        rig.Do(s => s.Leave());
    }

    [Fact]
    public async Task PasteOnAMacSetsTheClipboardThenCommandV()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        Assert.True(await rig.TakeOver());
        Assert.True(rig.Get(s => s.Paste("héllo")));
        Assert.True(await ScreenWait(() => SessionRig.Inputs(rig.Socket).Count == 6));
        Assert.Equal(["cut 5", "key ffeb down", "key 76 down", "key 76 up", "key ffeb up"], SessionRig.Inputs(rig.Socket).TakeLast(5));
        Assert.True(!rig.Get(s => s.Paste(null)) && !rig.Get(s => s.Paste("")));
        rig.Do(s => s.Leave());
    }

    // Eviction and stream endings (L512, L515)

    [Fact]
    public async Task EvictionWatchesAgainAndAFourthInARowAsksForATap()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        Assert.True(await rig.TakeOver());
        rig.Display.OtherTakes();                                                          // closes our socket with 4000
        Assert.True(await ScreenWait(() => rig.Notices.Contains(N.ControlTaken)));
        Assert.True(await ScreenWait(() => rig.Display.Sockets.Count == 2 && rig.Phase is P.Live));
        Assert.True(!rig.Get(s => s.Holding) && rig.Get(s => s.OtherHolds));
        Assert.Single(rig.Display.Calls("display.lease.acquire"));                         // no reclaim: the lease is theirs
        rig.Do(s => s.SendPointer(1, 1, 1));
        await Task.Delay(80);
        Assert.Empty(rig.Display.Sockets[1].Inputs);
        // A gateway that evicts every fresh attach: three are followed, the fourth stops.
        for (var round = 2; round <= 3; round++)
        {
            rig.Socket!.End(4000, "control-taken");
            var want = round + 1;
            Assert.True(await ScreenWait(() => rig.Display.Sockets.Count == want && rig.Phase is P.Live));
        }
        rig.Socket!.End(4000);
        Assert.True(await ScreenWait(() => rig.Phase == Ended("Another viewer took control. Watching only.")));
        Assert.Equal(4, rig.Display.Sockets.Count);
        rig.Do(s => s.Reconnect());
        Assert.True(await rig.Live());
        rig.Do(s => s.Leave());
    }

    [Fact]
    public async Task EvictionsFarApartAreEachFollowed()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        for (var round = 1; round <= 5; round++)
        {
            rig.Clock.Advance(11);
            rig.Socket!.End(4000);
            var want = round + 1;
            Assert.True(await ScreenWait(() => rig.Display.Sockets.Count == want && rig.Phase is P.Live));
        }
        rig.Do(s => s.Leave());
    }

    [Fact]
    public async Task ADroppedStreamReattachesOnceThenAsks()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        rig.Socket!.End();                                                                  // the link dropped: no close frame
        Assert.True(await ScreenWait(() => rig.Display.Sockets.Count == 2 && rig.Phase is P.Live));
        Assert.DoesNotContain(rig.Phases, IsEnded);
        rig.Socket!.End();                                                                  // again inside the window
        Assert.True(await ScreenWait(() => rig.Phase == Ended("Screen Stopped")));
        await Task.Delay(200);
        Assert.Equal(2, rig.Display.Sockets.Count);                                         // no loop
        rig.Do(s => s.Reconnect());
        Assert.True(await rig.Live());
        // A drop long after the last one gets its own quiet retry.
        rig.Clock.Advance(60);
        rig.Socket!.End(1011);
        Assert.True(await ScreenWait(() => rig.Display.Sockets.Count == 4 && rig.Phase is P.Live));
        rig.Do(s => s.Leave());
    }

    [Fact]
    public async Task ARetryThatCannotAttachAsksForATap()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        rig.Display.Set(s => s.DialFails = true);
        rig.Socket!.End();
        Assert.True(await ScreenWait(() => rig.Phase == Ended("Screen Stopped")));
        rig.Display.Set(s => s.DialFails = false);
        rig.Do(s => s.Reconnect());
        Assert.True(await rig.Live());
        rig.Do(s => s.Leave());
    }

    [Fact]
    public async Task AFirstAttachThatFailsSaysWhy()
    {
        using var rig = new SessionRig();
        rig.Display.Set(s => s.Fail["display.observe"] = FakeDisplay.Rpc(5300, "Too many viewers"));
        rig.Do(s => s.Open());
        Assert.True(await ScreenWait(() => rig.Phase == Ended("Screen Stopped", "Too many viewers.")));
        rig.Do(s => s.Leave());
    }

    [Fact]
    public async Task ASpentTicketObservesAgainOnce()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        rig.Socket!.End(4401);
        Assert.True(await ScreenWait(() => rig.Display.Sockets.Count == 2 && rig.Phase is P.Live));
        Assert.Equal(2, rig.Display.Calls("display.observe").Count);
        rig.Do(s => s.Leave());
    }

    /// Spec §2.4: 4401 → observe again once, then "Screen Stopped". Never a third try by itself.
    [Fact]
    public async Task ASecondRefusedTicketEndsTheStreamInWords()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        rig.Display.Set(s => s.Pictures = false);                     // the next socket is refused before any picture
        rig.Socket!.End(4401);
        Assert.True(await ScreenWait(() => rig.Display.Sockets.Count == 2));
        rig.Socket!.End(4401);
        Assert.True(await ScreenWait(() => rig.Phase == Ended("Screen Stopped")));
        rig.Do(s => s.SetOnView(true));                               // the viewer finishing its appearance is not a resume
        await Task.Delay(400);                                        // well past the automatic retry's 40 ms
        Assert.Equal(2, rig.Display.Calls("display.observe").Count);
        Assert.Equal(2, rig.Display.Sockets.Count);
        // "Reconnect" starts over, with its own second try.
        rig.Do(s => s.Reconnect());
        Assert.True(await ScreenWait(() => rig.Display.Sockets.Count == 3));
        rig.Display.Set(s => s.Pictures = true);
        rig.Socket!.End(4401);
        Assert.True(await ScreenWait(() => rig.Display.Sockets.Count == 4 && rig.Phase is P.Live));
        Assert.Equal(4, rig.Display.Calls("display.observe").Count);
        // A ticket that worked resets the count: the next spent ticket is retried again.
        rig.Socket!.End(4401);
        Assert.True(await ScreenWait(() => rig.Display.Sockets.Count == 5 && rig.Phase is P.Live));
        rig.Do(s => s.Leave());
    }

    [Fact]
    public async Task NotRunningReadsTheStatusAndShowsOff()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        rig.Display.Set(s => s.Running = false);
        rig.Socket!.End(4001);
        Assert.True(await ScreenWait(() => rig.Phase is P.Off));
        Assert.Single(rig.Display.Sockets);
        rig.Do(s => s.Leave());
    }

    [Fact]
    public async Task BadDataFromTheGatewayEndsTheStreamInWords()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        rig.Socket!.Push([99, 0, 0, 0]);                                                    // an unknown server message
        Assert.True(await ScreenWait(() => rig.Display.Sockets.Count == 2 && rig.Phase is P.Live));
        rig.Socket!.PushText();
        Assert.True(await ScreenWait(() => rig.Phase == Ended("Screen Stopped")));
        rig.Do(s => s.Leave());
    }

    // Out of view (L515)

    [Fact]
    public async Task OutOfViewClosesWithoutHandingBackAndBackOnViewHoldsAgain()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        Assert.True(await rig.TakeOver());
        var viewer = rig.Get(s => s.Viewer);
        rig.Do(s => s.SetOnView(false, immediately: true));
        Assert.True(await ScreenWait(() => rig.Socket!.Closes.SequenceEqual([false])));
        Assert.Equal("human", rig.Display.Lease.Holder);                                    // a person's control survives it
        Assert.Empty(rig.Display.Calls("display.lease.release"));
        Assert.True(rig.Phase is P.Attaching && !rig.Get(s => s.OnView));
        await Task.Delay(200);
        Assert.Single(rig.Display.Sockets);                                                 // nothing re-attaches while away
        rig.Do(s => s.SetOnView(true));
        Assert.True(await ScreenWait(() => rig.Display.Sockets.Count == 2 && rig.Phase is P.Live));
        // The same /api/ws connection honours the id again: still in control, no second acquire.
        Assert.Equal(viewer?.Id, rig.Display.Calls("display.observe").Last().Str("viewer_id"));
        Assert.True(rig.Get(s => s.Viewer) == viewer && rig.Get(s => s.Holding));
        Assert.Single(rig.Display.Calls("display.lease.acquire"));
        rig.Do(s => s.Leave());
    }

    [Fact]
    public async Task AShortLookAwayDoesNotCloseTheStream()
    {
        // Against the shipping one-second pause, not the rig's 150 ms: on a loaded Mac a 40 ms wait (Task.Delay and
        // Thread.Sleep alike) came back after 159-191 ms (measured, timer slack), so against 150 ms the "short"
        // look-away was a long one and the stream rightly paused (1 run in 5). The look-away and the assertion are the
        // Swift test's; only the pause it must stay under is the app's own.
        using var rig = new SessionRig(pauseDelay: TimeSpan.FromSeconds(1));
        Assert.True(await rig.OpenLive());
        rig.Do(s => s.SetOnView(false));                                                    // Action Center, a call banner
        await Task.Delay(40);
        rig.Do(s => s.SetOnView(true));
        await Task.Delay(300);
        Assert.True(rig.Socket!.Closes.Count == 0 && rig.Display.Sockets.Count == 1);
        rig.Do(s => s.SetOnView(false));                                                    // and a long one does
        Assert.True(await ScreenWait(() => rig.Socket!.Closes.SequenceEqual([false])));
        rig.Do(s => s.Leave());
    }

    [Fact]
    public async Task ResumeSignalsOnlyTouchAStreamThatIsNotLive()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        rig.Do(s => s.ResumeSignal());
        await Task.Delay(100);
        Assert.Single(rig.Display.Sockets);
        rig.Display.Set(s => s.DialFails = true);
        rig.Socket!.End();
        Assert.True(await ScreenWait(() => rig.Phase == Ended("Screen Stopped")));
        rig.Display.Set(s => s.DialFails = false);
        rig.Do(s => s.ResumeSignal());                                                      // the network came back
        Assert.True(await rig.Live());
        rig.Do(s => s.Leave());
    }

    // Holds (L512)

    [Fact]
    public async Task ControlSurvivesANewGatewayConnection()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        Assert.True(await rig.TakeOver());
        var old = rig.Get(s => s.Viewer);
        var before = rig.Display.Methods.Count;
        rig.Display.ReconnectGateway();
        Assert.True(await ScreenWait(() => rig.Get(s => s.Viewer != old && s.Holding) && rig.Phase is P.Live));
        Assert.Equal(["display.observe", "display.status", "display.lease.acquire"], rig.Display.Methods.Skip(before).Take(3));
        Assert.Equal(old?.Id, rig.Display.Calls("display.observe").Last().Str("viewer_id"));
        Assert.Equal(rig.Get(s => s.Viewer?.Id), rig.Display.Calls("display.lease.acquire").Last().Str("viewer_id"));
        Assert.True(rig.Display.Lease.Hash == rig.Get(s => s.Viewer?.Hash) && rig.Display.Lease.Holder == "human");
        Assert.Equal(rig.Get(s => s.Viewer?.Id), rig.Main.Read(() => rig.Holds.Saved(rig.Account, "default")?.Id));
        // And the new stream takes input.
        rig.Do(s => s.SendPointer(0, 5, 5));
        Assert.True(await ScreenWait(() => SessionRig.Inputs(rig.Socket).LastOrDefault() == "pointer 0 5,5"));
        rig.Do(s => s.Leave());
    }

    [Fact]
    public async Task NoReclaimWhenSomeoneElseTookControlMeanwhile()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        Assert.True(await rig.TakeOver());
        // Between the observe and the recheck another person takes it.
        rig.Display.Set(s => s.Before["display.status"] = w =>
        {
            w.Holder = "human";
            w.Hash = ScreenWire.ViewerHash("a-stranger");
            w.Epoch += 1;
        });
        rig.Display.ReconnectGateway();
        Assert.True(await ScreenWait(() => rig.Phase is P.Live && rig.Display.Sockets.Count == 2));
        Assert.Single(rig.Display.Calls("display.lease.acquire"));                          // only the first Take over
        Assert.True(!rig.Get(s => s.Holding) && rig.Get(s => s.OtherHolds));
        rig.Do(s => s.Leave());
    }

    [Fact]
    public async Task AFailedRecheckAcquiresNothing()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        Assert.True(await rig.TakeOver());
        rig.Display.Set(s => s.Fail["display.status"] = FakeDisplay.Rpc(5300, "busy"));
        rig.Display.ReconnectGateway();
        Assert.True(await ScreenWait(() => rig.Display.Sockets.Count == 2 && rig.Phase is P.Live));
        Assert.Single(rig.Display.Calls("display.lease.acquire"));
        Assert.False(rig.Get(s => s.Holding));
        rig.Do(s => s.Leave());
    }

    [Fact]
    public async Task ClosingWhileInControlHandsBackThroughTheClose()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        Assert.True(await rig.TakeOver());
        Assert.NotNull(rig.Main.Read(() => rig.Holds.Saved(rig.Account, "default")));
        rig.Do(s => s.SendPointer(1, 8, 8));
        rig.Do(s => s.Leave());
        Assert.True(await ScreenWait(() => rig.Socket!.Closes.FirstOrDefault()));          // close frame 1000
        Assert.Equal("pointer 0 8,8", SessionRig.Inputs(rig.Socket).LastOrDefault());       // the button went up first
        Assert.Empty(rig.Display.Calls("display.lease.release"));
        // Not forgotten on faith (review finding 2): the hold stays saved until the gateway says the bot has control.
        Assert.True(rig.Main.Read(() => rig.Holds.Saved(rig.Account, "default") != null && rig.Holds.Own(rig.Account, "default") == null));
        rig.Do(s => s.Leave());                                                             // idempotent
        Assert.Single(rig.Socket!.Closes);
        rig.Display.AgentTakes();                                                           // what the close frame makes Hermes send
        Assert.True(await ScreenWait(() => rig.Main.Read(() => rig.Holds.Saved(rig.Account, "default")) == null));
    }

    /// Sign-out and gateway switch: the hand-back is finished, and answered, before the caller ends the client.
    [Fact]
    public async Task LeavingBeforeSignOutWaitsForTheGatewaysWord()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        Assert.True(await rig.TakeOver());
        var id = rig.Get(s => s.Viewer?.Id);
        rig.Do(s => s.SendPointer(1, 8, 8));
        await rig.HandBackBeforeLeaving();
        // All of it is true the moment the call returns: no waiting here.
        Assert.True(rig.Get(s => s.Left));
        Assert.Equal([true], rig.Socket!.Closes);                                           // close frame 1000, sent by the sender itself
        Assert.Equal("pointer 0 8,8", SessionRig.Inputs(rig.Socket).LastOrDefault());
        var release = rig.Display.Calls("display.lease.release").LastOrDefault();
        Assert.True(release?.Str("viewer_id") == id && release?.Bool("force") == true);
        Assert.Equal("agent", rig.Display.Lease.Holder);
        Assert.True(rig.Main.Read(() => rig.Holds.Saved(rig.Account, "default") == null && rig.Holds.Own(rig.Account, "default") == null));
        rig.Main.Run(rig.Service.Shutdown);                                                 // what tearDown does next: nothing left to do
        Assert.True(rig.Socket!.Closes.Count == 1 && rig.Display.Calls("display.lease.release").Count == 1);
    }

    [Fact]
    public async Task AHandBackTheGatewayNeverAnsweredKeepsTheHold()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        Assert.True(await rig.TakeOver());
        rig.Display.Set(s => s.Fail["display.lease.release"] = new Hermes.Core.Net.GatewayException("rpc", "not connected", rpcCode: -32000));
        await rig.HandBackBeforeLeaving();
        Assert.True(rig.Get(s => s.Left) && rig.Socket!.Closes.SequenceEqual([true]));
        Assert.NotNull(rig.Main.Read(() => rig.Holds.Saved(rig.Account, "default")));     // the next launch offers Resume / Hand back
        Assert.Null(rig.Main.Read(() => rig.Holds.Own(rig.Account, "default")));          // and nothing takes it back silently
    }

    [Fact]
    public async Task AGatewayThatHangsDoesNotHoldSignOutUp()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        Assert.True(await rig.TakeOver());
        rig.Display.Set(s => s.Hang.Add("display.lease.release"));
        var began = Stopwatch.StartNew();
        await rig.HandBackBeforeLeaving(TimeSpan.FromMilliseconds(600));
        Assert.True(began.Elapsed < TimeSpan.FromSeconds(3), $"{began.Elapsed}");
        Assert.NotNull(rig.Main.Read(() => rig.Holds.Saved(rig.Account, "default")));
    }

    [Fact]
    public async Task LeavingBeforeSignOutWithNoScreenOpenDoesNotWait()
    {
        using var rig = new SessionRig();
        rig.Do(s => s.Leave());
        var began = Stopwatch.StartNew();
        await rig.HandBackBeforeLeaving();
        Assert.True(began.Elapsed < TimeSpan.FromMilliseconds(200), $"{began.Elapsed}");
        Assert.Empty(rig.Display.Methods);
    }

    [Fact]
    public async Task AHoldSavedByAnEarlierRunIsReleasedAndAnsweredBeforeSignOut()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        Assert.True(await rig.TakeOver());
        rig.Do(s => s.SetOnView(false, immediately: true));                                // holding, the stream down
        Assert.True(await ScreenWait(() => rig.Socket!.Closes.SequenceEqual([false])));
        await rig.HandBackBeforeLeaving();
        Assert.True(rig.Display.Lease.Holder == "agent" && rig.Main.Read(() => rig.Holds.Saved(rig.Account, "default")) == null);
    }

    [Fact]
    public async Task ClosingWithTheStreamDownReleasesById()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        Assert.True(await rig.TakeOver());
        var viewer = rig.Get(s => s.Viewer);
        rig.Do(s => s.SetOnView(false, immediately: true));                                // the stream is down, the lease is still ours
        rig.Do(s => s.Leave());
        Assert.True(await ScreenWait(() => rig.Display.Calls("display.lease.release").Count == 1));
        var release = rig.Display.Calls("display.lease.release").First();
        Assert.Equal(["force", "profile", "viewer_id"], Keys(release));
        Assert.True(release.Str("viewer_id") == viewer?.Id && release.Bool("force") == true);
        Assert.True(await ScreenWait(() => rig.Main.Read(() => rig.Holds.Saved(rig.Account, "default")) == null));
        Assert.Equal("agent", rig.Display.Lease.Holder);
    }

    [Fact]
    public async Task ClosingWhileWatchingReleasesNothing()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        rig.Do(s => s.Leave());
        Assert.True(await ScreenWait(() => rig.Socket!.Closes.SequenceEqual([false])));
        await Task.Delay(100);
        Assert.Empty(rig.Display.Calls("display.lease.release"));
    }

    [Fact]
    public async Task OfflineNothingIsForgotten()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        Assert.True(await rig.TakeOver());
        rig.Do(s => s.SetOnView(false, immediately: true));
        rig.Display.Set(s => s.Fail["display.lease.release"] = new Hermes.Core.Net.GatewayException("rpc", "not connected", rpcCode: -32000));
        rig.Do(s => s.Leave());
        Assert.True(await ScreenWait(() => rig.Display.Calls("display.lease.release").Count == 1));
        await Task.Delay(100);
        Assert.NotNull(rig.Main.Read(() => rig.Holds.Saved(rig.Account, "default")));     // the next launch offers it again
    }

    [Fact]
    public async Task AHoldFromAnEarlierRunIsOfferedNotTaken()
    {
        // An earlier run of the app took control and was killed.
        using var first = new SessionRig();
        Assert.True(await first.OpenLive());
        Assert.True(await first.TakeOver());
        var old = first.Get(s => s.Viewer);
        // The relaunch: a new service and connection, the same settings store, the gateway's lease untouched.
        using var rig = new SessionRig(first.Defaults);
        rig.Display.Set(s => { s.Holder = "human"; s.Hash = old?.Hash; s.Epoch = 9; });
        Assert.True(await rig.OpenLive());
        Assert.True(rig.Get(s => s.Held?.Id == old?.Id && !s.Holding && !s.OtherHolds));
        Assert.Equal("You were in control", rig.Get(s => s.Caption));
        Assert.Empty(rig.Display.Calls("display.lease.acquire"));                          // nothing is reclaimed silently
        // "Hand back" releases the saved id with force.
        rig.Do(s => s.HandBack());
        Assert.True(await ScreenWait(() => rig.Get(s => s.Held == null && s.BusyWith == null)));
        var release = rig.Display.Calls("display.lease.release").FirstOrDefault();
        Assert.Equal(["force", "profile", "viewer_id"], Keys(release));
        Assert.Equal(old?.Id, release?.Str("viewer_id"));
        Assert.True(rig.Display.Lease.Holder == "agent" && rig.Main.Read(() => rig.Holds.Saved(rig.Account, "default")) == null);
        rig.Do(s => s.Leave());
        first.Do(s => s.Leave());
    }

    [Fact]
    public async Task ResumeControlTakesItWithTheNewId()
    {
        using var first = new SessionRig();
        Assert.True(await first.OpenLive());
        Assert.True(await first.TakeOver());
        var old = first.Get(s => s.Viewer);
        using var rig = new SessionRig(first.Defaults);
        rig.Display.Set(s => { s.Holder = "human"; s.Hash = old?.Hash; s.Epoch = 9; });
        Assert.True(await rig.OpenLive());
        Assert.NotNull(rig.Get(s => s.Held));
        Assert.True(await rig.TakeOver());                                                  // "Resume control"
        Assert.True(rig.Get(s => s.Caption == "You are in control" && s.Held == null));
        Assert.Equal(rig.Get(s => s.Viewer?.Id), rig.Main.Read(() => rig.Holds.Saved(rig.Account, "default")?.Id));
        // Closing a Screen that only offered an old hold still hands that hold back.
        using var third = new SessionRig(first.Defaults);
        var hash = rig.Get(s => s.Viewer?.Hash);
        third.Display.Set(s => { s.Holder = "human"; s.Hash = hash; s.Epoch = 12; });
        Assert.True(await third.OpenLive());
        var saved = third.Get(s => s.Held);
        Assert.NotNull(saved);
        third.Do(s => s.Leave());
        Assert.True(await ScreenWait(() => third.Display.Calls("display.lease.release").Count == 1));
        Assert.Equal(saved?.Id, third.Display.Calls("display.lease.release").First().Str("viewer_id"));
        rig.Do(s => s.Leave());
        first.Do(s => s.Leave());
    }

    [Fact]
    public async Task ClosedWhileAReclaimWasInFlightTheNewIdIsReleased()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        Assert.True(await rig.TakeOver());
        rig.Display.Set(s => s.Delay["display.lease.acquire"] = TimeSpan.FromMilliseconds(250));
        rig.Display.ReconnectGateway();
        Assert.True(await ScreenWait(() => rig.Display.Calls("display.lease.acquire").Count == 2));
        rig.Do(s => s.Leave());                                                             // Close before the acquire answers
        Assert.True(await ScreenWait(() => rig.Display.Calls("display.lease.release").Any(c => c.Bool("force") == true)));
        Assert.True(await ScreenWait(() => rig.Display.Lease.Holder == "agent"));
    }

    // Mac health (L514)

    [Fact]
    public async Task AMacScreenPollsItsHealthAndALinuxOneNeverDoes()
    {
        using (var rig = new SessionRig())
        {
            Assert.True(await rig.OpenLive());
            Assert.True(await ScreenWait(() => rig.Get(s => s.Mac?.InputReady == true)));
            Assert.True(rig.Get(s => s.CanTake));
            Assert.True(await ScreenWait(() => rig.Display.RestLog.Count >= 3));            // at once, then on the interval
            Assert.All(rig.Display.RestLog, path => Assert.Equal("/api/plugins/hermes-hq-screen/health", path));
            // Out of view: no more reads. Back: one at once.
            rig.Do(s => s.SetOnView(false, immediately: true));
            await Task.Delay(100);
            var paused = rig.Display.RestLog.Count;
            await Task.Delay(600);
            Assert.Equal(paused, rig.Display.RestLog.Count);
            rig.Do(s => s.SetOnView(true));
            Assert.True(await ScreenWait(() => rig.Display.RestLog.Count > paused));
            rig.Do(s => s.Leave());
        }

        using var linux = new SessionRig();
        linux.Display.Set(s => s.Display = ":7");
        Assert.True(await linux.OpenLive());
        await Task.Delay(400);
        Assert.Empty(linux.Display.RestLog);
        Assert.True(linux.Get(s => s.CanTake && s.Mac == null));
        linux.Do(s => s.Leave());
    }

    [Fact]
    public async Task OnAMacTakeOverWaitsForInputToBeReady()
    {
        using var rig = new SessionRig();
        var answer = """{"installed":true,"control":false,"helper":{"ok":true,"tcc":{"screen":true,"events":false}}}""";
        rig.Display.OnRest(() => Volatile.Read(ref answer));
        Assert.True(await rig.OpenLive());
        Assert.True(await ScreenWait(() => rig.Get(s => s.Mac) != null));
        Assert.True(!rig.Get(s => s.CanTake) && rig.Get(s => s.Mac?.Control) == false);
        rig.Do(s => s.TakeOver());
        await Task.Delay(100);
        Assert.Empty(rig.Display.Calls("display.lease.acquire"));
        // The helper changes and says so with a status event: read at once, not at the next poll.
        Volatile.Write(ref answer, """{"installed":true,"control":true,"helper":{"ok":true,"locked":true,"tcc":{"screen":true,"events":true}}}""");
        rig.Display.EmitStatus();
        Assert.True(await ScreenWait(() => rig.Get(s => s.Mac?.Locked == true && s.CanTake)));
        // No plugin at all on a Mac: readiness is unknown, so no Take over.
        rig.Display.OnRest(() => null);
        Assert.True(await ScreenWait(() => rig.Get(s => s.Mac) == null));
        Assert.False(rig.Get(s => s.CanTake));
        rig.Do(s => s.Leave());
    }

    // The session cases of the Mac's ScreenServiceTests suite (the rest are ScreenService's own: the next slice).

    /// Found by UI test02 once the stand-in sent home paths: a Screen still waiting for its first status must take
    /// the gateway's status event (it names the bot), though the event's key is a path it has never seen.
    [Fact]
    public async Task AScreenWithNoStatusYetTakesTheGatewaysStatusEvent()
    {
        using var rig = new SessionRig();
        rig.Display.Set(s => s.Hang.Add("display.status"));
        rig.Do(s => s.Open());
        await Task.Delay(100);
        Assert.Null(rig.Get(s => s.Status));
        rig.Display.EmitStatus();                                     // profile "default", profile_key "/fixture/home"
        Assert.True(await rig.Live(), "the late status opened the Screen without a click");
        // And another bot's status event is not taken for this one.
        var before = rig.Get(s => s.Status);
        rig.Display.Emit("display.status", new JsonObject { ["profile"] = "ivy", ["profile_key"] = "/fixture/home/profiles/ivy", ["supported"] = false });
        await Task.Delay(80);
        Assert.Equal(before, rig.Get(s => s.Status));
        rig.Do(s => s.Leave());
    }

    /// A screen the service already knows is running opens straight to observe: its answer carries the status.
    [Fact]
    public async Task AKnownRunningScreenOpensWithoutAStatusRead()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        rig.Do(s => s.Leave());
        var before = rig.Display.Methods.Count;
        rig.Reopen();
        Assert.True(rig.Get(s => { s.Open(); return s.CurrentPhase; }) is P.Attaching, "the known status shows at once");
        Assert.True(await rig.Live());
        Assert.Equal(["display.observe"], rig.Display.Methods.Skip(before));
        rig.Do(s => s.Leave());
    }

    /// The known status was stale (the screen was turned off since): the status is read as on any open, and no
    /// "stream ended" page shows on the way.
    [Fact]
    public async Task AStaleKnownStatusFallsBackToTheStatusRead()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        rig.Do(s => s.Leave());
        rig.Display.Set(s => s.Running = false);
        var before = rig.Display.Methods.Count;
        rig.Reopen();
        rig.Do(s => s.Open());
        Assert.True(await ScreenWait(() => rig.Phase is P.Off));
        Assert.Equal(["display.observe", "display.status"], rig.Display.Methods.Skip(before));
        Assert.DoesNotContain(rig.Phases, IsEnded);
        rig.Do(s => s.Leave());
    }

    /// Review finding 3: a Mac that answers but has no picture ends in words that say why, not "Screen Stopped".
    [Fact]
    public async Task AMacWithNoPictureSaysWhy()
    {
        using var rig = new SessionRig();
        rig.Display.Set(s => s.Pictures = false);
        rig.Display.OnRest(() => FakeDisplay.Healthy.Replace("\"helper\":{", "\"helper\":{\"paused\":true,", StringComparison.Ordinal));
        rig.Do(s => s.Open());
        Assert.True(await ScreenWait(() => rig.Socket != null));
        rig.Socket!.Push(RfbBuild.Preamble(64, 48));
        // The handshake is done once the stream has asked for its first picture.
        Assert.True(await ScreenWait(() => rig.Socket!.Requests.Count > 0, 20));
        await Task.Delay(300);
        rig.Clock.Advance(12);
        await Task.Delay(600);
        Assert.True(rig.Phase is P.Attaching, "12 s: still waiting, the socket open");
        rig.Clock.Advance(9);
        // The title comes with the stream's end; the reason follows the helper's health (read again at that moment).
        Assert.True(await ScreenWait(() => rig.Phase == Ended("The Mac hasn’t sent a picture yet", "Resume sharing from Hermes HQ Screen’s menu on the Mac."), 20),
            $"{rig.Phase} phases {string.Join(", ", rig.Phases)} sockets {rig.Display.Sockets.Count} clock {rig.Clock.Now}");
        await Task.Delay(200);
        Assert.True(rig.Display.Sockets.Count == 1 && rig.Display.Calls("display.observe").Count == 1, "no retry by itself");
        // Reconnect, and this time the picture comes.
        rig.Display.Set(s => s.Pictures = true);
        rig.Do(s => s.Reconnect());
        Assert.True(await rig.Live());
        rig.Do(s => s.Leave());
    }

    [Fact]
    public void TheReasonForNoPictureFollowsTheHelpersHealth()
    {
        static JsonNode Helper(JsonObject helper) => new JsonObject { ["helper"] = helper };
        Assert.Equal("Resume sharing from Hermes HQ Screen’s menu on the Mac.", ScreenSession.NoPictureReason(Helper(new() { ["paused"] = true })));
        Assert.Equal("The display is off.", ScreenSession.NoPictureReason(Helper(new() { ["capture_error"] = "The display is off" })));
        Assert.Equal("Allow Screen Recording for Hermes HQ Screen on the Mac.",
            ScreenSession.NoPictureReason(Helper(new() { ["tcc"] = new JsonObject { ["screen"] = false } })));
        Assert.StartsWith("The Mac is locked", ScreenSession.NoPictureReason(Helper(new() { ["locked"] = true })));
        // The Mac's "tap" is this app's DeviceWord.Tap ("click").
        Assert.Equal("Its display may be asleep. Wake the Mac, then click Reconnect.", ScreenSession.NoPictureReason(null));
    }

    [Fact]
    public async Task SignOutLeavesEveryOpenScreenByTheRules()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        Assert.True(await rig.TakeOver());
        Assert.True(rig.Main.Read(() => rig.Service.HasOpenSession));
        rig.Main.Run(rig.Service.Shutdown);
        Assert.True(rig.Get(s => s.Left));
        Assert.True(await ScreenWait(() => rig.Socket!.Closes.FirstOrDefault()));          // handed back through the close
        rig.Display.EmitStatus();
        rig.Display.ReconnectGateway();
        await Task.Delay(150);
        Assert.True(rig.Display.Sockets.Count == 1 && rig.Display.Calls("display.observe").Count == 1);
    }
}
