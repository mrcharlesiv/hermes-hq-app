// [WIN-SCREEN-SOCKET-STREAM] One attach's stream (Hermes.Core/Screen/ScreenStream.cs) over a fake socket, ported case
// for case from the Mac's Tests/Screen/ScreenStreamTests.swift at 93f984bb1: the pull model, decoding off the main
// thread, the stuck rule with a clock the test moves, how it ends, and how it is closed on purpose. The Mac's main actor
// is a TestMainThread; the CGImage is the framebuffer's BGRX snapshot. Waits poll for at least 10 s.

using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Text;
using Hermes.Core.Screen;
using static Hermes.Core.Tests.Screen.ScreenWaits;

namespace Hermes.Core.Tests.Screen;

public sealed class ScreenStreamTests : IDisposable
{
    private readonly TestMainThread _main = new();
    public void Dispose() => _main.Dispose();

    private (ScreenStream Stream, StreamProbe Probe) Make(FakeScreenSocket socket, FakeUptime? clock = null, double stuckAfter = 8,
        TimeSpan? pingEvery = null, TimeProvider? flushClock = null)
    {
        var probe = new StreamProbe();
        Func<double>? now = clock == null ? null : () => clock.Now;
        var stream = new ScreenStream(socket,
            onReady: (w, h) => probe.Ready.Add((w, h)),
            onFrame: (image, w, h, serial) =>
            {
                probe.LastImage = image;
                probe.LastImageWidth = w;
                probe.Frames.Add(new ProbeFrame(w, h, serial, socket.Requests.Count));
            },
            onEnd: end => probe.Ends.Add(end),
            stuckAfter: stuckAfter, pingEvery: pingEvery ?? TimeSpan.FromSeconds(20), now: now,
            onMain: _main.Run, isMain: () => _main.IsCurrent) { FlushClock = flushClock ?? TimeProvider.System };
        stream.Start();
        return (stream, probe);
    }

    private T P<T>(Func<T> read) => _main.Read(read);
    private List<ScreenStreamEnd> Ends(StreamProbe probe) => P(() => probe.Ends.ToList());

    private static readonly byte[] Fill = RfbBuild.Update([RfbBuild.TightFill(0, 0, 64, 48, r: 10, g: 20, b: 30)]);
    private static readonly ScreenStreamEnd Stuck = new ScreenStreamEnd.Stuck();
    private static readonly ScreenStreamEnd NoPicture = new ScreenStreamEnd.NoPicture();

    [Fact]
    public async Task HandshakeThenOneRequestAtATime()
    {
        var socket = new FakeScreenSocket();
        var (stream, probe) = Make(socket);
        socket.Push(RfbBuild.Preamble(64, 48));
        Assert.True(await ScreenWait(() => socket.Requests.Count == 1));
        Assert.True(P(() => probe.Ready.Count == 1 && probe.Ready[0] == (64, 48)));
        // version, security, ClientInit, format, encodings, request
        Assert.Equal(new byte[] { 82, 1, 1, 0, 2, 3 }, socket.Sent.Select(d => d[0]).ToArray());
        Assert.Equal(RfbMessage.UpdateRequest(incremental: false, width: 64, height: 48), socket.Requests[0]);
        // Nothing more is asked for until a frame has been handed over.
        await Task.Delay(150);
        Assert.Single(socket.Requests);
        for (var expected = 1; expected <= 5; expected++)
        {
            socket.Push(Fill);
            var e = expected;
            Assert.True(await ScreenWait(() => P(() => probe.Frames.Count) == e && socket.Requests.Count == e + 1));
            // the next request goes out only after the frame reached the main actor
            Assert.Equal(expected, P(() => probe.Frames[e - 1].RequestsSeen));
        }
        Assert.Equal(RfbMessage.UpdateRequest(incremental: true, width: 64, height: 48), socket.Requests[^1]);
        var pacing = stream.Pacing;
        Assert.True(pacing.Frames == 5 && pacing.Serial == 5 && pacing.MainThreadDecodes == 0);
        Assert.True(pacing.Width == 64 && pacing.Height == 48);
        Assert.Equal(string.Concat(Enumerable.Repeat("1e140a", 5)), pacing.Probe);
        Assert.StartsWith("frames=5 rects=5 size=64x48 mainDecodes=0 p50=", pacing.Summary);
        Assert.True(P(() => probe.LastImageWidth) == 64 && P(() => probe.LastImage?.Length) == 64 * 48 * 4 && stream.IsLive);
        stream.Stop(handBack: false);
    }

    [Fact]
    public async Task AnUpdateSplitOverManyFramesIsOnePictureAndOneRequest()
    {
        var socket = new FakeScreenSocket();
        var (stream, probe) = Make(socket);
        var all = RfbBuild.Cat(RfbBuild.Preamble(64, 48), Fill);
        foreach (var b in all) socket.Push([b]);
        Assert.True(await ScreenWait(() => P(() => probe.Frames.Count) == 1 && socket.Requests.Count == 2));
        Assert.Equal(0, stream.Pacing.MainThreadDecodes);
        stream.Stop(handBack: false);
    }

    [Fact]
    public async Task AResizeAsksForTheWholeNewPicture()
    {
        var socket = new FakeScreenSocket();
        var (stream, probe) = Make(socket);
        socket.Push(RfbBuild.Cat(RfbBuild.Preamble(64, 48), Fill));
        Assert.True(await ScreenWait(() => socket.Requests.Count == 2));
        socket.Push(RfbBuild.Update([RfbBuild.ExtendedDesktopSize(96, 60)]));
        Assert.True(await ScreenWait(() => socket.Requests.Count == 3));
        Assert.Equal(RfbMessage.UpdateRequest(incremental: false, width: 96, height: 60), socket.Requests[2]);
        Assert.True(P(() => probe.Frames[^1].Width == 96 && probe.Frames[^1].Height == 60));
        stream.Stop(handBack: false);
    }

    [Fact]
    public async Task InputGoesOutInOrder()
    {
        var socket = new FakeScreenSocket();
        var (stream, _) = Make(socket);
        socket.Push(RfbBuild.Preamble(64, 48));
        Assert.True(await ScreenWait(() => socket.Requests.Count == 1));
        var keys = new List<byte[]>();
        for (var index = 0; index < 300; index++) keys.Add(RfbMessage.Key((uint)(0x20 + index % 90), down: index % 2 == 0));
        foreach (var key in keys) stream.Send(key);
        Assert.True(await ScreenWait(() => socket.Inputs.Count == 300));
        Assert.Equal(keys, socket.Inputs);
        stream.Stop(handBack: false);
    }

    // Stuck (DECISION D12)

    [Fact]
    public void TheStuckRuleCountsSilenceOnlyWhileBytesAreOwed()
    {
        var rule = new ScreenStuckRule(lastByte: 100, limit: 8, waiting: true);
        Assert.True(!rule.IsStuck(now: 107.9) && rule.IsStuck(now: 108));
        rule.Waiting = false;
        Assert.False(rule.IsStuck(now: 10_000));                     // silence between updates is a quiet desktop
        rule.DecodingSince = 200;
        Assert.True(!rule.IsStuck(now: 207) && rule.IsStuck(now: 208.5));   // a decode that never returns
    }

    [Fact]
    public async Task NoByteForEightSecondsMidUpdateEndsTheStream()
    {
        FakeScreenSocket socket = new(); FakeUptime clock = new();
        var (held1, probe) = Make(socket, clock);
        try
        {
            socket.Push(RfbBuild.Cat(RfbBuild.Preamble(64, 48), Fill));
            Assert.True(await ScreenWait(() => P(() => probe.Frames.Count) == 1));
            var raw = RfbBuild.Update([RfbBuild.Raw(0, 0, 64, 48, b: 1, g: 2, r: 3)]);
            socket.Push(raw[..500]);
            await Task.Delay(400);
            clock.Advance(7.5);
            await Task.Delay(600);
            Assert.Empty(Ends(probe));                                // 7.5 s is not stuck
            clock.Advance(1);
            Assert.True(await ScreenWait(() => Ends(probe).SequenceEqual([Stuck])));
            Assert.Equal([false], socket.Closes);                     // ended without a close frame: the lease is kept
        }
        finally { held1.Stop(handBack: false); }
    }

    [Fact]
    public async Task ASlowLinkThatKeepsDeliveringIsNeverStuck()
    {
        FakeScreenSocket socket = new(); FakeUptime clock = new();
        var (stream, probe) = Make(socket, clock);
        socket.Push(RfbBuild.Cat(RfbBuild.Preamble(64, 48), Fill));
        Assert.True(await ScreenWait(() => P(() => probe.Frames.Count) == 1));
        var raw = RfbBuild.Update([RfbBuild.Raw(0, 0, 64, 48, b: 1, g: 2, r: 3)]);
        var at = 0;
        while (at < raw.Length)                                       // a minute of 6-second gaps
        {
            socket.Push(raw[at..Math.Min(raw.Length, at + 1200)]);
            at += 1200;
            await Task.Delay(300);
            clock.Advance(6);
            await Task.Delay(300);
        }
        Assert.True(await ScreenWait(() => P(() => probe.Frames.Count) == 2));
        Assert.Empty(Ends(probe));
        // A quiet desktop afterwards (no update owed) is not stuck either.
        clock.Advance(600);
        await Task.Delay(600);
        Assert.Empty(Ends(probe));
        stream.Stop(handBack: false);
    }

    [Fact]
    public async Task AHandshakeThatNeverFinishesIsStuck()
    {
        FakeScreenSocket socket = new(); FakeUptime clock = new();
        var (held2, probe) = Make(socket, clock);
        try
        {
            socket.Push(Encoding.UTF8.GetBytes("RFB 003.008\n"));
            await Task.Delay(300);
            clock.Advance(9);
            Assert.True(await ScreenWait(() => Ends(probe).SequenceEqual([Stuck])));
        }
        finally { held2.Stop(handBack: false); }
    }

    // The first picture (review finding 3)

    [Fact]
    public void TheFirstPictureGetsItsOwnLongerWait()
    {
        var rule = new ScreenStuckRule(lastByte: 100, limit: 8, firstLimit: 20, waiting: true);
        Assert.Equal(ScreenStuckVerdict.Stuck, rule.Verdict(now: 108));        // a handshake that stalls is stuck at 8 s
        rule.AwaitingFirst = true;                                              // ServerInit arrived; no byte of a picture yet
        Assert.True(rule.Verdict(now: 112) == null && rule.Verdict(now: 119.9) == null);
        Assert.Equal(ScreenStuckVerdict.NoPicture, rule.Verdict(now: 120));
        rule.AwaitingFirst = false;                                             // the first update began, then stalled
        Assert.Equal(ScreenStuckVerdict.Stuck, rule.Verdict(now: 108));
    }

    [Fact]
    public async Task APictureThatComesAfterTwelveSecondsIsShown()
    {
        FakeScreenSocket socket = new(); FakeUptime clock = new();
        var (stream, probe) = Make(socket, clock);
        try
        {
            socket.Push(RfbBuild.Preamble(64, 48));
            Assert.True(await ScreenWait(() => P(() => probe.Ready.Count) == 1));
            clock.Advance(12);
            await Task.Delay(700);
            // 12 s without a first picture is a Mac with nothing to send yet, not a stuck stream
            Assert.Empty(Ends(probe));
            Assert.Empty(socket.Closes);
            socket.Push(Fill);
            Assert.True(await ScreenWait(() => P(() => probe.Frames.Count) == 1));
            Assert.Empty(Ends(probe));
        }
        finally { stream.Stop(handBack: false); }
    }

    [Fact]
    public async Task APictureThatNeverComesEndsAsNoPicture()
    {
        FakeScreenSocket socket = new(); FakeUptime clock = new();
        var (stream, probe) = Make(socket, clock);
        try
        {
            socket.Push(RfbBuild.Preamble(64, 48));
            Assert.True(await ScreenWait(() => P(() => probe.Ready.Count) == 1));
            clock.Advance(19);
            await Task.Delay(600);
            Assert.Empty(Ends(probe));
            clock.Advance(2);
            Assert.True(await ScreenWait(() => Ends(probe).SequenceEqual([NoPicture])));
            Assert.Equal([false], socket.Closes);                     // no close frame: a hold is kept
        }
        finally { stream.Stop(handBack: false); }
    }

    [Fact]
    public async Task AFirstPictureThatBeginsAndStallsIsStuckAtEight()
    {
        FakeScreenSocket socket = new(); FakeUptime clock = new();
        var (stream, probe) = Make(socket, clock);
        try
        {
            socket.Push(RfbBuild.Preamble(64, 48));
            Assert.True(await ScreenWait(() => P(() => probe.Ready.Count) == 1));
            socket.Push(RfbBuild.Update([RfbBuild.Raw(0, 0, 64, 48, b: 1, g: 2, r: 3)])[..500]);
            await Task.Delay(400);
            clock.Advance(9);
            Assert.True(await ScreenWait(() => Ends(probe).SequenceEqual([Stuck])));
        }
        finally { stream.Stop(handBack: false); }
    }

    [Fact]
    public async Task AnUnansweredPingIsADroppedLink()
    {
        var socket = new FakeScreenSocket();
        socket.AnswerPings(false);
        var (held3, probe) = Make(socket, pingEvery: TimeSpan.FromMilliseconds(300));
        try
        {
            socket.Push(RfbBuild.Cat(RfbBuild.Preamble(64, 48), Fill));
            Assert.True(await ScreenWait(() => Ends(probe).SequenceEqual([Stuck])));
            Assert.True(socket.Pings >= 1);
        }
        finally { held3.Stop(handBack: false); }
    }

    [Fact]
    public async Task PingsAreOnlySentWhileLive()
    {
        var socket = new FakeScreenSocket();
        var (stream, probe) = Make(socket, pingEvery: TimeSpan.FromMilliseconds(200));
        await Task.Delay(700);
        Assert.Equal(0, socket.Pings);                               // no picture yet
        socket.Push(RfbBuild.Cat(RfbBuild.Preamble(64, 48), Fill));
        Assert.True(await ScreenWait(() => socket.Pings >= 2));
        Assert.Empty(Ends(probe));
        stream.Stop(handBack: false);
    }

    // Endings

    [Fact]
    public async Task TheGatewaysCloseCodeIsReported()
    {
        foreach (var (code, reason) in new (int, string?)[] { (4000, "control-taken"), (4001, null), (4401, null), (1003, null) })
        {
            var socket = new FakeScreenSocket();
            var (held4, probe) = Make(socket);
            try
            {
                socket.Push(RfbBuild.Cat(RfbBuild.Preamble(64, 48), Fill));
                Assert.True(await ScreenWait(() => P(() => probe.Frames.Count) == 1));
                socket.End(code, reason);
                var want = new ScreenStreamEnd.Closed(code, reason);
                Assert.True(await ScreenWait(() => Ends(probe).SequenceEqual([want])), $"{code}");
            }
            finally { held4.Stop(handBack: false); }
        }
        var dropped = new FakeScreenSocket();
        var (held5, dropProbe) = Make(dropped);
        try
        {
            dropped.End();
            Assert.True(await ScreenWait(() => Ends(dropProbe).SequenceEqual([new ScreenStreamEnd.Closed(null, null)])));
        }
        finally { held5.Stop(handBack: false); }
    }

    /// Audit 14-14: a send that fails ends the stream at once as a dropped link, not a frozen picture until a ping.
    [Fact]
    public async Task AFailedSendEndsTheStream()
    {
        var socket = new FakeScreenSocket();
        var (stream, probe) = Make(socket);
        try
        {
            socket.Push(RfbBuild.Preamble(64, 48));
            Assert.True(await ScreenWait(() => socket.Requests.Count == 1));
            socket.FailSends();
            socket.Push(Fill);   // its next request can't go out
            Assert.True(await ScreenWait(() => Ends(probe).SequenceEqual([new ScreenStreamEnd.Closed(null, null)])));
        }
        finally { stream.Stop(handBack: false); }
    }

    [Fact]
    public async Task BadDataAndTextFramesEndWithTheirName()
    {
        var held = new List<ScreenStream>();
        try
        {
            var text = new FakeScreenSocket();
            var (held6, first) = Make(text);
            held.Add(held6);
            text.PushText();
            Assert.True(await ScreenWait(() => Ends(first).SequenceEqual([new ScreenStreamEnd.Failed("text-frame")])));
            var bad = new FakeScreenSocket();
            var (held7, second) = Make(bad);
            held.Add(held7);
            bad.Push(RfbBuild.Cat(RfbBuild.Preamble(64, 48), [9, 9, 9]));
            Assert.True(await ScreenWait(() => Ends(second).SequenceEqual([new ScreenStreamEnd.Failed("unknown-message")])));
            Assert.Equal([false], bad.Closes);
            var huge = new FakeScreenSocket();
            var (held8, third) = Make(huge);
            held.Add(held8);
            huge.Push(RfbBuild.Cat(Encoding.UTF8.GetBytes("RFB 003.008\n"), [1, 1, 0, 0, 0, 0], RfbBuild.ServerInit(65535, 65535)));
            Assert.True(await ScreenWait(() => Ends(third).SequenceEqual([new ScreenStreamEnd.Failed("bad-size")])));
        }
        finally { foreach (var stream in held) stream.Stop(handBack: false); }
    }

    [Theory]
    [InlineData(false, null)]
    [InlineData(false, 0)]
    [InlineData(false, 1)]
    [InlineData(true, null)]
    [InlineData(true, 0)]
    [InlineData(true, 1)]
    public Task StopHandsBackWithACloseFrameOnlyWhenAsked(bool handBack, int? cutAt) =>
        CheckStoppedFlush(handBack, [RfbMessage.Pointer(0, 5, 5), RfbMessage.Key(0xFFE3, down: false)], cutAt, collect: false);

    // What the session does on Close and on a pause: stop, then drop its only reference. The Swift deinit runs on the
    // last release; here the stream's finalizer does the same once the collector finds it unreachable.
    private sealed class Holder { public ScreenStream? Stream; }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private StreamProbe MakeHeld(FakeScreenSocket socket, Holder holder, TimeProvider? flushClock = null)
    {
        var (stream, probe) = Make(socket, flushClock: flushClock);
        holder.Stream = stream;
        return probe;
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static void StopHeld(Holder holder, bool handBack, byte[] up) => holder.Stream!.Stop(handBack, flush: [up]);

    private static bool Collected(Func<bool> done)
    {
        GC.Collect();
        GC.WaitForPendingFinalizers();
        return done();
    }

    [Fact]
    public async Task AStreamStoppedAndLetGoAtOnceStillFlushesAndClosesAsAsked()
    {
        foreach (var handBack in new[] { true, false })
        {
            var socket = new FakeScreenSocket();
            var made = new Holder();
            var probe = MakeHeld(socket, made);
            socket.Push(RfbBuild.Cat(RfbBuild.Preamble(64, 48), Fill));
            Assert.True(await ScreenWait(() => P(() => probe.Frames.Count) == 1));
            var up = RfbMessage.Pointer(0, 7, 9);
            StopHeld(made, handBack, up);
            made.Stream = null;
            Assert.True(await ScreenWait(() => Collected(() => socket.Closes.Count > 0)));
            // letting go of a stopped stream must not turn a hand-back into a cut link, or the reverse
            Assert.Equal([handBack], socket.Closes);
            Assert.Equal(up, socket.Inputs[^1]);                      // the button-up went out before the close
        }
        // A stream nobody stopped and nobody holds closes without a hand-back.
        var lone = new FakeScreenSocket();
        var held = new Holder();
        var loneProbe = MakeHeld(lone, held);
        lone.Push(RfbBuild.Cat(RfbBuild.Preamble(64, 48), Fill));
        Assert.True(await ScreenWait(() => P(() => loneProbe.Frames.Count) == 1));
        held.Stream = null;
        Assert.True(await ScreenWait(() => Collected(() => lone.Closes.SequenceEqual([false]))));
    }

    // Swift deinit leaves a stopped stream's close to the sender or the cutoff. Observe the Windows owner actually
    // becoming unreachable while SendAsync is still suspended on this button-up, not just while it might be queued.
    [Theory]
    [InlineData(false, false)]
    [InlineData(false, true)]
    [InlineData(true, false)]
    [InlineData(true, true)]
    public Task AStoppedStreamCollectedWhileItsFlushIsInFlightStillClosesAsAsked(bool handBack, bool expires) =>
        CheckStoppedFlush(handBack, [RfbMessage.Pointer(0, 3, 4)], cutAt: expires ? 0 : null, collect: true);

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static (WeakReference Owner, Task Closed) BeginFlush(Holder holder, bool handBack, byte[][] flush)
    {
        var stream = holder.Stream!;
        stream.Stop(handBack, flush);
        stream.Send(RfbMessage.Key(0x61, down: true)); // a post-stop key must never reach the socket
        return (new WeakReference(stream), stream.WritesEnded);
    }

    // cutAt is the index of the write still held at 250 ms; null lets every write finish at 249 ms.
    private async Task CheckStoppedFlush(bool handBack, byte[][] flush, int? cutAt, bool collect)
    {
        var limit = TimeSpan.FromSeconds(10); // test deadlock guard, never the stream's clock
        var socket = new FakeScreenSocket();
        var clock = new Voice.ManualTime();
        var holder = new Holder();
        var probe = MakeHeld(socket, holder, clock);
        socket.Push(RfbBuild.Cat(RfbBuild.Preamble(64, 48), Fill));
        // The frame callback returns *before* the next-picture request is even queued. Wait for its actual write.
        Assert.True(await ScreenWait(() => socket.Requests.Count == 2));
        Assert.Equal(RfbMessage.UpdateRequest(incremental: true, width: 64, height: 48), socket.Requests[1]);
        Assert.Equal(1, P(() => probe.Frames.Count));
        var expected = flush.Select(bytes => bytes.ToArray()).ToArray();
        var held = socket.HoldWrite(flush[0]);
        var (owner, closed) = BeginFlush(holder, handBack, flush);
        async Task<Task> Started(FakeScreenSocket.HeldWrite gate)
        {
            await Task.WhenAny(gate.Started.Task, closed).WaitAsync(limit);
            Assert.True(gate.Started.Task.IsCompletedSuccessfully, "the socket closed before the expected flush write started");
            return await gate.Started.Task;
        }
        try
        {
            var write = await Started(held);
            Assert.False(write.IsCompleted);
            if (collect)
            {
                holder.Stream = null;
                Assert.True(await ScreenWait(() => Collected(() => !owner.IsAlive)), "the pending write kept the stopped stream alive");
            }

            clock.Advance(TimeSpan.FromMilliseconds(249));
            for (var i = 0; i < flush.Length; i++)
            {
                Assert.Equal(1, clock.Pending); // not even a fired cutoff awaiting its continuation
                Assert.Empty(socket.Closes);
                Assert.False(write.IsCompleted);
                Assert.Equal(expected[..i], socket.Inputs);
                if (cutAt == i)
                {
                    clock.Advance(TimeSpan.FromMilliseconds(1)); // same deadline, including any preceding write
                    await closed.WaitAsync(limit);              // still no permission to finish
                    await Assert.ThrowsAnyAsync<OperationCanceledException>(() => write.WaitAsync(limit));
                    Assert.True(write.IsCanceled);
                    held.Allow.SetResult();                     // cannot resurrect this write
                    break;
                }

                // Arm the next gate before releasing this one so even two timely writes are observed in FIFO order.
                var next = i + 1 < flush.Length ? socket.HoldWrite(flush[i + 1]) : null;
                held.Allow.SetResult();
                await write.WaitAsync(limit);
                if (next == null) break;
                held = next;
                write = await Started(held);
            }
            await closed.WaitAsync(limit); // a timely sender must close without another clock tick
            var prefix = expected[..(cutAt ?? expected.Length)];
            if (!collect)
            {
                Assert.Equal([handBack], socket.Closes);
                Assert.Equal(prefix, socket.Inputs);
                holder.Stream!.Send(RfbMessage.Key(0x61, down: true)); // ignored even after the socket has closed
            }
            if (cutAt == null) clock.Advance(TimeSpan.FromMilliseconds(1));
            Assert.Equal([handBack], socket.Closes);
            Assert.Equal(prefix, socket.Inputs);
            Assert.Empty(Ends(probe));
        }
        finally
        {
            held.Allow.TrySetResult();
            clock.Advance(ScreenStream.StopCut);
            GC.KeepAlive(holder); // only the collection cases drop the last strong reference
        }
    }

    [Fact]
    public async Task StopIsBoundedWhenTheLinkCannotSend()
    {
        var socket = new FakeScreenSocket();
        var (stream, probe) = Make(socket);
        socket.Push(RfbBuild.Cat(RfbBuild.Preamble(64, 48), Fill));
        Assert.True(await ScreenWait(() => P(() => probe.Frames.Count) == 1));
        socket.SlowSends(TimeSpan.FromSeconds(5));
        var began = Stopwatch.StartNew();
        stream.Stop(handBack: true, flush: [RfbMessage.Pointer(0, 1, 1)]);
        Assert.True(await ScreenWait(() => socket.Closes.Count > 0));
        Assert.True(began.Elapsed < TimeSpan.FromSeconds(1), "cut after 250 ms whatever is still queued");
        Assert.True(socket.Closes[0]);
    }
}
