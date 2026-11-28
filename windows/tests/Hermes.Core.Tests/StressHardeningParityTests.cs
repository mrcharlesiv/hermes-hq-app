using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Channels;
using Hermes.Core.Attachments;
using Hermes.Core.Auth;
using Hermes.Core.Chat;
using Hermes.Core.Composer;
using Hermes.Core.Diagnostics;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Rpc;
using Hermes.Core.Screen;
using Hermes.Core.Terminal;
using Hermes.Core.Tests.Screen;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Tests;

/// Wave 1D parity tests for Swift stress-testing hardening (8639ca961) and unsent new-session drafts across bot
/// switches (363ae6c33): H1, H2, H4, H5, C10, H11, H16, H17, M20, L6, H21, H25, H27, RunawayGuard, MemoryTrim.
public sealed class StressHardeningParityTests
{
    private static async Task<bool> Until(Func<bool> condition, double seconds = 10)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (!condition())
        {
            if (DateTime.UtcNow > until) return false;
            await Task.Delay(20);
        }
        return true;
    }

    // ------------------------------------------------------------------ H2: Json.UnixTime & Json.Int

    [Fact]
    public void H2_JsonUnixTimeAndIntGuardNonFiniteAndOutOfRangeValues()
    {
        var obj = new JsonObject
        {
            ["nan"] = double.NaN,
            ["posInf"] = double.PositiveInfinity,
            ["negInf"] = double.NegativeInfinity,
            ["strNan"] = "NaN",
            ["strInf"] = "Infinity",
            ["strHuge"] = "1e309",
            ["huge"] = 1e25,
            ["negHuge"] = -1e25,
            ["zero"] = 0,
            ["neg"] = -5,
            ["valid"] = 1730000000.5,
            ["maxLong"] = long.MaxValue,
        };

        Assert.Null(obj.UnixTime("nan"));
        Assert.Null(obj.UnixTime("posInf"));
        Assert.Null(obj.UnixTime("negInf"));
        Assert.Null(obj.UnixTime("strNan"));
        Assert.Null(obj.UnixTime("strInf"));
        Assert.Null(obj.UnixTime("strHuge"));
        Assert.Null(obj.UnixTime("huge"));
        Assert.Null(obj.UnixTime("negHuge"));
        Assert.Null(obj.UnixTime("zero"));
        Assert.Null(obj.UnixTime("neg"));

        var valid = obj.UnixTime("valid");
        Assert.NotNull(valid);
        Assert.Equal(DateTimeOffset.FromUnixTimeMilliseconds(1730000000500), valid.Value);

        Assert.Null(obj.Int("nan"));
        Assert.Null(obj.Int("posInf"));
        Assert.Null(obj.Int("strInf"));
        Assert.Null(obj.Int("huge"));
        Assert.Equal(long.MaxValue, obj.Int("maxLong"));
    }

    // ------------------------------------------------------------------ H4: MathText linear-time parsing

    [Fact]
    public void H4_MathTextUnclosedDelimitersRunInLinearTime()
    {
        var parens = string.Concat(Enumerable.Repeat("\\( ", 30_000));
        var brackets = string.Concat(Enumerable.Repeat("\\[ ", 30_000));
        var begins = string.Concat(Enumerable.Repeat("\\begin{", 15_000));
        var aligns = string.Concat(Enumerable.Repeat("\\begin{align}", 15_000)) + "\\end{align}";
        var dollars = string.Concat(Enumerable.Repeat("$$ ", 20_000));
        var ticks = string.Concat(Enumerable.Repeat("`x ", 20_000)) + "$a^2$";

        var sw = Stopwatch.StartNew();
        Assert.Empty(MathText.Spans(parens));
        Assert.Empty(MathText.Spans(brackets));
        Assert.Empty(MathText.Spans(begins));
        Assert.True(MathText.Spans(aligns).Count <= 1);
        Assert.Empty(MathText.Spans(dollars));
        var extracted = MathText.Extract(ticks);
        sw.Stop();

        Assert.Single(extracted.Formulas);
        Assert.Equal("a^2", extracted.Formulas[0].Source);
        Assert.True(sw.Elapsed < TimeSpan.FromSeconds(5), $"Expected linear time, took {sw.Elapsed}");
    }

    // ------------------------------------------------------------------ C10: MathText PUA stripping & limit nesting

    [Fact]
    public void C10_MathTextStripsUntrustedPuaAndGuardsLimitScriptNesting()
    {
        var spoofed = $"before {MathText.InlineOpen}0{MathText.Close} {MathText.BlockOpen}1{MathText.Close} "
            + $"{MathText.LimitBelowOpen}sub{MathText.LimitClose}{MathText.LimitAboveOpen}sup{MathText.LimitClose} after";
        var plain = MathText.Extract(spoofed);
        Assert.Empty(plain.Formulas);
        Assert.Equal("before 0 1 subsup after", plain.Text);

        var mixed = $"tag {MathText.InlineOpen}0{MathText.Close} and $x^2$";
        var extracted = MathText.Extract(mixed);
        Assert.Single(extracted.Formulas);
        Assert.Equal("tag 0 and $x^2$", MathText.Restore(extracted.Text, extracted.Formulas));

        var rawLimitTex = $"x{MathText.LimitBelowOpen}i{MathText.LimitClose}";
        var readable = MathText.Readable(rawLimitTex);
        Assert.Equal("xi", readable);

        var nested = MathText.Readable(@"\sum_{\sum_{i=1}^{n}}^{m}");
        Assert.NotNull(nested);
        Assert.True(nested!.Contains(MathText.LimitAboveOpen));
        Assert.True(nested.Contains(MathText.LimitBelowOpen));

        var deepLimits = string.Concat(Enumerable.Repeat(@"\sum_{", 30)) + "1" + new string('}', 30);
        Assert.Null(MathText.Readable(deepLimits));
    }

    // ------------------------------------------------------------------ H5: ReasoningTags & MarkdownComplexity

    [Fact]
    public void H5_ReasoningTagsUnclosedRunsInLinearTimeAndPreservesCode()
    {
        var pathological = "lead " + string.Concat(Enumerable.Repeat("<think>", 20_000));
        var sw = Stopwatch.StartNew();
        var kept = ReasoningTags.Strip(pathological);
        sw.Stop();

        Assert.Equal(pathological, kept);
        Assert.True(sw.Elapsed < TimeSpan.FromSeconds(5), $"Expected linear time, took {sw.Elapsed}");

        Assert.Equal("answer", ReasoningTags.Strip("<think>hidden</think>\r\nanswer"));
        Assert.Equal("", ReasoningTags.Strip("  <think>unclosed at start"));
        Assert.Equal("before\n", ReasoningTags.Strip("before\n  <think>streaming line", streaming: true));
        Assert.Equal("use `<think>not hidden</think>` ok", ReasoningTags.Strip("use `<think>not hidden</think>` ok"));
        var fenced = "```\n<think>code</think>\n```\n<think>prose</think>\nshown";
        Assert.Equal("```\n<think>code</think>\n```\nshown", ReasoningTags.Strip(fenced));
    }

    [Fact]
    public void H5_MarkdownComplexityGuardsPathologicalInputsAndOversizedReplies()
    {
        Assert.Equal(MarkdownComplexity.Verdict.Simple, MarkdownComplexity.Evaluate("# Title\n\n- a\n- b\n\n| c1 | c2 |\n|---|---|\n| 1 | 2 |"));
        Assert.Equal(MarkdownComplexity.Verdict.Deep, MarkdownComplexity.Evaluate(new string('>', 15) + " nested"));
        Assert.True(MarkdownComplexity.IsTooComplex(new string('>', 40) + " too deep"));
        Assert.True(MarkdownComplexity.IsTooComplex(new string(' ', 140) + "- indented"));
        Assert.True(MarkdownComplexity.IsTooComplex(string.Concat(Enumerable.Repeat("*a ", 510))));
        Assert.True(MarkdownComplexity.IsTooComplex(new string('[', 1005)));
        Assert.True(MarkdownComplexity.IsTooComplex(new string('*', 260)));
        Assert.False(MarkdownComplexity.IsTooComplex("```\n" + new string('*', 260) + "\n```"));
        Assert.True(MarkdownComplexity.IsTooComplex(new string(' ', 1005)));

        var huge = new string('a', MarkdownComplexity.PlainTextLimit + 1);
        Assert.True(MarkdownComplexity.ExceedsPlainTextLimit(huge));
        Assert.True(MarkdownComplexity.ShouldRenderPlainText(huge));
    }

    // ------------------------------------------------------------------ H11 & H1: ReplayBook & RpcConnection

    [Fact]
    public void H1_ReplayBookGuardsMaxInt64SeqOverflowAndIsolatesParkedSessions()
    {
        var book = new ReplayBook();
        _ = book.Ready("ep-1");

        var maxEv = new RpcEvent("message.delta", "s1", null, long.MaxValue);
        var (first, over1) = book.Live(maxEv, 64);
        Assert.False(over1);
        Assert.Equal(long.MaxValue, first?.Seq);

        Assert.False(book.HasGap(new RpcEvent("message.delta", "s1", null, long.MaxValue)));
        Assert.False(book.HasGap(new RpcEvent("message.delta", "s1", null, 1)));
        var (dup, _) = book.Live(new RpcEvent("message.delta", "s1", null, long.MaxValue), 64);
        Assert.Null(dup);

        // Per-session parking isolation
        Assert.True(book.Park("s1"));
        Assert.True(book.Park("s2"));
        var (parked1, over2) = book.Live(new RpcEvent("message.delta", "s1", null, null), 16);
        Assert.Null(parked1);
        Assert.False(over2);
        var (parked2, over3) = book.Live(new RpcEvent("message.delta", "s2", null, 5), 16);
        Assert.Null(parked2);
        Assert.False(over3);
        Assert.True(book.IsParked("s1"));
        Assert.True(book.IsParked("s2"));

        var drained1 = book.Release("s1");
        Assert.Single(drained1);
        Assert.False(book.IsParked("s1"));
        Assert.True(book.IsParked("s2"));

        var drained2 = book.Release("s2");
        Assert.Single(drained2);
        Assert.Equal(5, drained2[0].Seq);
        Assert.False(book.IsParked("s2"));
    }

    [Fact]
    public async Task H11_RpcConnectionParksLiveEventsDuringReplayAndIsolatesConcurrentGapRepair()
    {
        await using var gw = new ReplayStandin();
        var session = new GatewaySession(GatewayAddress.Validated(gw.Url), new StoredAccount(gw.Url, "tester"), new MemoryTokenStore());
        await using var rpc = new RpcConnection(session);

        var s1Seqs = new List<long>();
        var s2Seqs = new List<long>();
        rpc.Event += ev =>
        {
            if (ev.Seq is not { } seq) return;
            if (ev.SessionId == "s1") lock (s1Seqs) s1Seqs.Add(seq);
            if (ev.SessionId == "s2") lock (s2Seqs) s2Seqs.Add(seq);
        };

        rpc.Start();
        await rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(10)).Token);

        // Initial live frames on socket 1: s1=1, s2=1
        await gw.EmitEventAsync("s1", 1);
        await gw.EmitEventAsync("s2", 1);
        Assert.True(await Until(() => { lock (s1Seqs) lock (s2Seqs) return s1Seqs.Count == 1 && s2Seqs.Count == 1; }));

        // On reconnect (socket 2, same epoch): hold s1 reconnect replay; complete s2 reconnect replay with seq 2 so
        // s2 deterministically unparks, then trigger a live gap on s2 (seq 4) and hold s2's gap-repair replay until
        // AFTER s1's reconnect replay ends (proving H11 per-session isolation).
        var s1ReplayStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseS1Replay = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var s2GapStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseS2Gap = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var s2ReplayCalls = 0;

        gw.OnEventsSince = async (sid, lastSeen) =>
        {
            if (sid == "s1")
            {
                s1ReplayStarted.TrySetResult();
                await releaseS1Replay.Task;
                return new JsonObject
                {
                    ["epoch"] = "ep-1",
                    ["events"] = new JsonArray { ReplayStandin.EventJson("s1", 2) },
                };
            }
            if (sid == "s2")
            {
                var call = Interlocked.Increment(ref s2ReplayCalls);
                if (call == 1)
                {
                    return new JsonObject
                    {
                        ["epoch"] = "ep-1",
                        ["events"] = new JsonArray { ReplayStandin.EventJson("s2", 2) },
                    };
                }
                s2GapStarted.TrySetResult();
                await releaseS2Gap.Task;
                return new JsonObject
                {
                    ["epoch"] = "ep-1",
                    ["events"] = new JsonArray { ReplayStandin.EventJson("s2", 3) },
                };
            }
            return new JsonObject { ["epoch"] = "ep-1", ["events"] = new JsonArray() };
        };

        // Drop socket 1 to force reconnect with the same epoch.
        gw.CutCurrentSocket();
        await s1ReplayStarted.Task.WaitAsync(TimeSpan.FromSeconds(10));
        // Wait until s2's reconnect replay has delivered seq 2 and unparked s2.
        Assert.True(await Until(() => { lock (s2Seqs) return s2Seqs.Count == 2; }));

        // While s1 reconnect replay is still in flight: live s1 seq 3 must park; live s2 seq 4 opens isolated gap repair.
        await gw.EmitEventAsync("s1", 3);
        await gw.EmitEventAsync("s2", 4);
        await s2GapStarted.Task.WaitAsync(TimeSpan.FromSeconds(10));

        // Finish s1 reconnect replay: s1 must receive 1, 2, 3 in strict order, while s2 MUST stay parked (still [1, 2]).
        releaseS1Replay.TrySetResult();
        Assert.True(await Until(() => { lock (s1Seqs) return s1Seqs.Count == 3; }));
        lock (s1Seqs) Assert.Equal(new List<long> { 1, 2, 3 }, s1Seqs);

        await Task.Delay(120);
        lock (s2Seqs) Assert.Equal(new List<long> { 1, 2 }, s2Seqs);

        // Now complete s2's gap repair: s2 receives missed seq 3 followed by parked seq 4.
        releaseS2Gap.TrySetResult();
        Assert.True(await Until(() => { lock (s2Seqs) return s2Seqs.Count == 4; }));
        lock (s2Seqs) Assert.Equal(new List<long> { 1, 2, 3, 4 }, s2Seqs);
    }

    // ------------------------------------------------------------------ H16: FileTranscriptCache

    [Fact]
    public void H16_FileTranscriptCacheRenamesProfileAndAvoidsDotFilenames()
    {
        var dir = Directory.CreateTempSubdirectory("hq-cache-h16-").FullName;
        try
        {
            var cache = new FileTranscriptCache(dir);
            IReadOnlyList<ChatMessage> msgs = [new ChatMessage("m1", Role.User, [new TextPart("hello")], null, 1)];

            cache.Write("acct-1", "ivy", "s1", msgs);
            Assert.NotNull(cache.Read("acct-1", "ivy", "s1"));

            cache.RenameProfile("ivy", "otto");
            Assert.Null(cache.Read("acct-1", "ivy", "s1"));
            var moved = cache.Read("acct-1", "otto", "s1");
            Assert.NotNull(moved);
            Assert.Equal("hello", moved![0].Text);

            // Safe(".") / Safe("..") / Safe("") never empty, ".", "..", or ".json"
            var safeDot = FileTranscriptCache.Safe(".");
            var safeDotDot = FileTranscriptCache.Safe("..");
            var safeEmpty = FileTranscriptCache.Safe("");
            Assert.False(string.IsNullOrEmpty(safeDot));
            Assert.False(string.IsNullOrEmpty(safeDotDot));
            Assert.False(string.IsNullOrEmpty(safeEmpty));
            Assert.DoesNotContain(safeDot, new[] { ".", ".." });
            Assert.DoesNotContain(safeDotDot, new[] { ".", ".." });
            Assert.False(safeDot.StartsWith('.'));
            Assert.False(safeDotDot.StartsWith('.'));
            Assert.NotEqual(safeDot, safeDotDot);

            IReadOnlyList<ChatMessage> dotMsgs = [new ChatMessage("m-dot", Role.User, [new TextPart("dot")], null, 2)];
            IReadOnlyList<ChatMessage> dotDotMsgs = [new ChatMessage("m-dotdot", Role.User, [new TextPart("dotdot")], null, 3)];
            cache.Write("acct-1", "..", ".", dotMsgs);
            cache.Write("acct-1", "..", "..", dotDotMsgs);

            Assert.Equal("dot", cache.Read("acct-1", "..", ".")![0].Text);
            Assert.Equal("dotdot", cache.Read("acct-1", "..", "..")![0].Text);
            Assert.DoesNotContain(Directory.EnumerateFiles(dir, "*.json", SearchOption.AllDirectories),
                f => Path.GetFileName(f) == ".json");
        }
        finally
        {
            try { Directory.Delete(dir, recursive: true); } catch (IOException) { }
        }
    }

    // ------------------------------------------------------------------ H17: ChatSession LoadOlder generation & cancel

    [Fact]
    public async Task H17_ChatSessionRefreshCancelsInFlightLoadOlderAndDropsStalePage()
    {
        await using var gw = new ChatStandin();
        var olderStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseOlder = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var refreshed = false;

        gw.OnHistory = async (offset, ct) =>
        {
            if (offset > 0)
            {
                olderStarted.TrySetResult();
                try { await releaseOlder.Task.WaitAsync(ct); }
                catch (OperationCanceledException) { throw; }
                return new JsonObject
                {
                    ["messages"] = new JsonArray
                    {
                        new JsonObject { ["id"] = 1, ["role"] = "user", ["content"] = "stale-older-row" },
                    },
                    ["has_more"] = true,
                    ["next_offset"] = 99,
                };
            }
            if (!refreshed)
            {
                return new JsonObject
                {
                    ["messages"] = new JsonArray
                    {
                        new JsonObject { ["id"] = 10, ["role"] = "user", ["content"] = "initial-row" },
                    },
                    ["has_more"] = true,
                    ["next_offset"] = 1,
                };
            }
            return new JsonObject
            {
                ["messages"] = new JsonArray
                {
                    new JsonObject { ["id"] = 20, ["role"] = "user", ["content"] = "refreshed-row" },
                },
                ["has_more"] = false,
                ["next_offset"] = 1,
            };
        };

        await using var client = new HermesClient(new GatewaySession(
            GatewayAddress.Validated(gw.Url), new StoredAccount(gw.Url, "tester"), new MemoryTokenStore()));
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(10)).Token);
        await using var chat = client.OpenChat("ivy", "s-h17", "Ivy");

        await chat.OpenAsync();
        Assert.True(chat.HasOlder);
        Assert.Single(chat.Messages);

        var olderTask = chat.LoadOlderAsync();
        await olderStarted.Task.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.True(chat.IsLoadingOlder);

        refreshed = true;
        await chat.RefreshAsync();
        releaseOlder.TrySetResult();
        await olderTask;

        Assert.False(chat.HasOlder);
        Assert.False(chat.OlderFailed);
        Assert.False(chat.IsLoadingOlder);
        Assert.Single(chat.Messages);
        Assert.Equal("refreshed-row", chat.Messages[0].Text);
    }

    // ------------------------------------------------------------------ M20: Stop timeout, waiter isolation & redirect epoch

    [Fact]
    public async Task M20_ChatSessionStopIsolatesWaitersAndStaleTimeoutsAndStopsRedirect()
    {
        await using var gw = new ChatStandin();
        await using var client = new HermesClient(new GatewaySession(
            GatewayAddress.Validated(gw.Url), new StoredAccount(gw.Url, "tester"), new MemoryTokenStore()));
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(10)).Token);
        await using var chat = client.OpenChat("ivy", "s-m20", "Ivy");
        await chat.EnsureRuntimeAsync();

        // 1. Waiter 1's cancelled short timeout must never wake Waiter 2.
        await chat.StopAsync();
        Assert.True(chat.StopTerminalPending);
        var waiter1 = chat.WaitForStopTerminalAsync(TimeSpan.FromMilliseconds(80));
        chat.StopTerminalReached();
        Assert.True(await waiter1);

        await chat.StopAsync();
        var waiter2 = chat.WaitForStopTerminalAsync(TimeSpan.FromMilliseconds(500));
        await Task.Delay(130);
        Assert.False(waiter2.IsCompleted);
        await gw.EmitEventAsync("message.complete", new JsonObject());
        Assert.True(await waiter2.WaitAsync(TimeSpan.FromSeconds(5)));

        // 2. A timed-out StopAsync from an earlier turn must not arm _stopPending against a newer turn.
        chat.InterruptTimeout = TimeSpan.FromMilliseconds(150);
        var holdInterrupt = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var interrupts = 0;
        gw.OnRpc = async (method, p) =>
        {
            if (method == "session.interrupt")
            {
                if (Interlocked.Increment(ref interrupts) == 1)
                    await holdInterrupt.Task;
                return new JsonObject { ["ok"] = true };
            }
            if (method == "prompt.submit") return new JsonObject { ["user_row_id"] = 55 };
            return null;
        };

        var staleStop = chat.StopAsync();
        Assert.True(await Until(() => Volatile.Read(ref interrupts) == 1));
        var outcome = await chat.SendAsync("new turn after slow stop");
        Assert.Equal(SendOutcome.Accepted, outcome);
        await staleStop; // finishes timing out AFTER the new turn started
        holdInterrupt.TrySetResult();

        await gw.EmitEventAsync("message.start", new JsonObject());
        await Task.Delay(120);
        Assert.Equal(1, Volatile.Read(ref interrupts)); // no stray interrupt fired on the new turn

        // 3. RedirectAsync checks _stopEpoch / TurnInterrupted and skips session.redirect when stopped.
        var redirects = 0;
        gw.OnRpc = (method, p) =>
        {
            if (method == "session.redirect") Interlocked.Increment(ref redirects);
            return Task.FromResult<JsonNode?>(new JsonObject { ["status"] = "redirected" });
        };
        await chat.StopAsync();
        var steerId = chat.BeginSteer("steer after stop");
        var (steerOutcome, _) = await chat.RedirectAsync(steerId, "steer after stop");
        Assert.Equal(SteerOutcome.Failed, steerOutcome);
        Assert.Equal(0, Volatile.Read(ref redirects));
    }

    // ------------------------------------------------------------------ 363ae6c33: PendingScope & draft migration

    [Fact]
    public async Task PendingScopePreservesUnsentDraftAcrossBotSwitchesAndMigratesOnFirstSend()
    {
        Assert.Equal("new", ChatSession.MakePendingScope(null));
        Assert.Equal("new", ChatSession.MakePendingScope("   "));
        Assert.Equal("new|/work/demo", ChatSession.MakePendingScope(" /work/demo "));

        await using var gw = new ChatStandin { ResolvedStoredId = "ephem-resolved" };
        var tempDir = Directory.CreateTempSubdirectory("hq-draft-scope-").FullName;
        await using var client = new HermesClient(new GatewaySession(
            GatewayAddress.Validated(gw.Url), new StoredAccount(gw.Url, "tester"), new MemoryTokenStore()));
        using var center = new AttachmentCenter(client, tempDir);
        AttachmentCenter.RegisterForTests(center);
        try
        {
            await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(10)).Token);

            // Newly started listed chat keeps deterministic PendingScope even when ephemeral StoredId resolves.
            await using var first = client.OpenChat("ivy", "ephem-1", "New Chat");
            first.StartsNew = true;
            first.ListsWhenStarted = true;
            first.PendingScope = ChatSession.MakePendingScope(null);

            var pendingScope = first.DraftScope;
            Assert.Equal(AttachmentCenter.Scope(client.AccountId, "ivy", "new"), pendingScope);
            center.SetText(pendingScope, "ivy", "unsent draft words");

            await first.EnsureRuntimeAsync();
            Assert.Equal("ephem-resolved", first.StoredId);
            Assert.Equal(pendingScope, first.DraftScope);
            Assert.Equal("unsent draft words", center.GetDraft(first.DraftScope).Text);

            // Switching to another bot and returning to a fresh new session on ivy recovers the exact same draft.
            await using var returned = client.OpenChat("ivy", "ephem-2", "New Chat");
            returned.StartsNew = true;
            returned.ListsWhenStarted = true;
            returned.PendingScope = ChatSession.MakePendingScope(null);
            Assert.Equal(pendingScope, returned.DraftScope);
            Assert.Equal("unsent draft words", center.GetDraft(returned.DraftScope).Text);

            // First send migrates the draft off PendingScope onto the real session scope so the next new chat starts clean.
            gw.ResolvedStoredId = null;
            Assert.Equal(SendOutcome.Accepted, await returned.SendAsync("hello ivy"));
            Assert.Equal(AttachmentCenter.Scope(client.AccountId, "ivy", "ephem-2"), returned.DraftScope);
            Assert.Equal("", center.GetDraft(pendingScope).Text);
            Assert.Equal("unsent draft words", center.GetDraft(returned.DraftScope).Text);
        }
        finally
        {
            AttachmentCenter.UnregisterForTests(client.AccountId, center);
            try { Directory.Delete(tempDir, recursive: true); } catch (IOException) { }
        }
    }

    // ------------------------------------------------------------------ L6: AttachmentCenter.ReturnToDraft

    [Fact]
    public async Task L6_ReturnToDraftPreservesActiveUploadWhileResettingStaleUploadingItem()
    {
        await using var gw = new ChatStandin();
        var uploadStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseUpload = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        gw.OnUpload = async ct =>
        {
            uploadStarted.TrySetResult();
            await releaseUpload.Task.WaitAsync(ct);
        };

        var dir = Directory.CreateTempSubdirectory("hq-l6-").FullName;
        await using var client = new HermesClient(new GatewaySession(
            GatewayAddress.Validated(gw.Url), new StoredAccount(gw.Url, "tester"), new MemoryTokenStore()));
        using var center = new AttachmentCenter(client, Path.Combine(dir, "center"));
        try
        {
            await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(10)).Token);
            var scope = AttachmentCenter.Scope(client.AccountId, "ivy", "s-l6");

            var localFile = Path.Combine(dir, "note.txt");
            File.WriteAllText(localFile, "synthetic payload");
            var active = new DraftAttachment("active-1", DraftKind.File, "note.txt", localFile, 17, null, null, UploadState.Ready);
            center.Add(active, scope, "ivy");

            await uploadStarted.Task.WaitAsync(TimeSpan.FromSeconds(10));
            Assert.IsType<UploadState.Uploading>(center.Item(active.Id)!.Upload);

            var stale = new DraftAttachment("stale-2", DraftKind.File, "stale.txt", localFile, 17, null, null,
                new UploadState.Uploading(4, 17));
            center.ReturnToDraft(scope, "ivy", "kept text", [center.Item(active.Id)!, stale], setTextIfEmpty: true);

            // L6: active upload stays Uploading; stale non-current Uploading resets to Waiting.
            Assert.IsType<UploadState.Uploading>(center.Item(active.Id)!.Upload);
            Assert.IsType<UploadState.Waiting>(center.Item(stale.Id)!.Upload);
        }
        finally
        {
            releaseUpload.TrySetResult();
            try { Directory.Delete(dir, recursive: true); } catch (IOException) { }
        }
    }

    // ------------------------------------------------------------------ H21: MediaStore.Purge cancels in-flight downloads

    [Fact]
    public async Task H21_MediaStorePurgeCancelsInFlightDownload()
    {
        await using var gw = new ChatStandin();
        var downloadStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseDownload = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        gw.OnDownload = async ct =>
        {
            downloadStarted.TrySetResult();
            await releaseDownload.Task.WaitAsync(ct);
        };

        var dir = Directory.CreateTempSubdirectory("hq-media-h21-").FullName;
        using var session = new GatewaySession(
            GatewayAddress.Validated(gw.Url), new StoredAccount(gw.Url, "tester"), new MemoryTokenStore());
        var store = new MediaStore(session, dir);
        try
        {
            var downloadTask = store.GatewayImageAsync("photos/demo.png", "demo.png", "ivy", "s1");
            await downloadStarted.Task.WaitAsync(TimeSpan.FromSeconds(10));
            Assert.Equal(1, store.InFlightCount);

            store.Purge();

            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => downloadTask.WaitAsync(TimeSpan.FromSeconds(10)));
            Assert.Equal(0, store.InFlightCount);
            Assert.Null(store.CachedImage("ivy", "photos/demo.png"));
        }
        finally
        {
            releaseDownload.TrySetResult();
            try { Directory.Delete(dir, recursive: true); } catch (IOException) { }
        }
    }

    // ------------------------------------------------------------------ H25: ScreenStream PendingResized

    [Fact]
    public async Task H25_ScreenStreamPreservesPendingResizeAcrossZeroUpdateFrame()
    {
        using var main = new TestMainThread();
        var socket = new FakeScreenSocket();
        var frames = 0;
        var stream = new ScreenStream(
            socket,
            onReady: (_, _) => { },
            onFrame: (_, _, _, _) => frames++,
            onEnd: _ => { },
            onMain: main.Run,
            isMain: () => main.IsCurrent);
        stream.Start();
        try
        {
            var initialFill = RfbBuild.Update([RfbBuild.TightFill(0, 0, 64, 48, r: 10, g: 20, b: 30)]);
            socket.Push(RfbBuild.Cat(RfbBuild.Preamble(64, 48), initialFill));
            Assert.True(await ScreenWaits.ScreenWait(() => main.Read(() => frames) == 1 && socket.Requests.Count == 2));
            Assert.Equal(RfbMessage.UpdateRequest(incremental: true, width: 64, height: 48), socket.Requests[1]);

            // Split a 2-rect update across two binary frames:
            // Frame 1 carries DesktopSize (Updates == 0, Resized == true); Frame 2 carries the pixel rect (Updates == 1, Resized == false).
            socket.Push(RfbBuild.Update([RfbBuild.DesktopSize(96, 60)], count: 2));
            await Task.Delay(50);
            socket.Push(RfbBuild.TightFill(0, 0, 96, 60, r: 1, g: 2, b: 3));

            Assert.True(await ScreenWaits.ScreenWait(() => main.Read(() => frames) == 2 && socket.Requests.Count == 3));
            Assert.Equal(RfbMessage.UpdateRequest(incremental: false, width: 96, height: 60), socket.Requests[2]);

            // Subsequent normal frame resets PendingResized back to incremental: true.
            socket.Push(RfbBuild.Update([RfbBuild.TightFill(0, 0, 96, 60, r: 4, g: 5, b: 6)]));
            Assert.True(await ScreenWaits.ScreenWait(() => main.Read(() => frames) == 3 && socket.Requests.Count == 4));
            Assert.Equal(RfbMessage.UpdateRequest(incremental: true, width: 96, height: 60), socket.Requests[3]);
        }
        finally
        {
            stream.Stop(handBack: false);
        }
    }

    // ------------------------------------------------------------------ H27: TerminalConnection resize during dial

    [Fact]
    public async Task H27_TerminalConnectionResizeDuringDialSendsFollowUpResizeAfterReady()
    {
        var dialStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var allowDial = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var socket = new FakeTerminalSocket();
        Dictionary<string, string>? dialQuery = null;

        var connection = new TerminalConnection(TerminalWire.NewSession(), async (q, ct) =>
        {
            dialQuery = q.ToDictionary(k => k.Key, k => k.Value);
            dialStarted.TrySetResult();
            await allowDial.Task.WaitAsync(ct);
            return socket;
        });

        try
        {
            connection.Start(80, 24);
            await dialStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Assert.Equal("80", dialQuery!["cols"]);
            Assert.Equal("24", dialQuery!["rows"]);

            // Resize while dial is still in flight.
            connection.Resize(120, 40);
            allowDial.TrySetResult();

            socket.Push(new TerminalFrame.Text("""{"type":"ready","offset":0,"shell":"zsh"}"""));
            Assert.True(await Until(() => connection.CurrentPhase is TerminalConnection.Phase.Live));
            Assert.True(await Until(() => socket.SentTexts().Any(v => v.Contains("\"cols\":120") && v.Contains("\"rows\":40"))));
        }
        finally
        {
            connection.Stop();
        }
    }

    // ------------------------------------------------------------------ RunawayGuard & MemoryTrim

    [Fact]
    public void RunawayGuardFiresOnlyOnSustainedHangWithMemoryGrowthAndResetsAfterSleep()
    {
        Assert.False(RunawayJudge.Stops(TimeSpan.FromSeconds(29), 200, 2500));
        Assert.False(RunawayJudge.Stops(TimeSpan.FromSeconds(30), 200, 200 + RunawayJudge.GrowthMb - 1));
        Assert.True(RunawayJudge.Stops(TimeSpan.FromSeconds(30), 200, 200 + RunawayJudge.GrowthMb));

        long memMb = 250;
        var stops = new List<(TimeSpan Waited, long From, long Now)>();
        using var guard = new RunawayGuard(
            footprintMb: () => memMb,
            stop: (w, from, now) => stops.Add((w, from, now)));

        var t0 = new DateTimeOffset(2026, 11, 28, 12, 0, 0, TimeSpan.Zero);

        // Answering normally never fires.
        guard.Tick(t0, ask: cb => cb());
        memMb = 3000;
        guard.Tick(t0.AddSeconds(1), ask: cb => cb());
        Assert.False(guard.Fired);

        // Stuck with steady memory never fires.
        memMb = 300;
        guard.Tick(t0.AddSeconds(2), ask: _ => { });
        for (var s = 3; s <= 40; s++)
            guard.Tick(t0.AddSeconds(s), ask: _ => { });
        Assert.False(guard.Fired);

        // A late tick (>= 5 s jump = process sleep) resets the pending wait.
        memMb = 2500;
        guard.Tick(t0.AddSeconds(50), ask: _ => { });
        Assert.False(guard.Fired);

        // Now stuck for 30 s with +1600 MB growth -> fires once.
        memMb = 400;
        guard.Tick(t0.AddSeconds(60), ask: _ => { }); // late jump resets and asks at t=60 with from=400
        for (var s = 61; s < 90; s++)
        {
            memMb = 2100;
            guard.Tick(t0.AddSeconds(s), ask: _ => { });
            Assert.False(guard.Fired);
        }
        guard.Tick(t0.AddSeconds(90), ask: _ => { });
        Assert.True(guard.Fired);
        Assert.Single(stops);
        Assert.Equal((TimeSpan.FromSeconds(30), 400L, 2100L), stops[0]);

        // Subsequent ticks do not fire again.
        guard.Tick(t0.AddSeconds(91), ask: _ => { });
        Assert.Single(stops);
    }

    [Fact]
    public async Task MemoryTrimRegistersDeduplicatesPressureAndCancelsBackground()
    {
        MemoryTrim.ResetForTests();
        try
        {
            var seen = new List<MemoryTrimReason>();
            MemoryTrim.Register("cache", _ => 99);
            MemoryTrim.Register("cache", r => { seen.Add(r); return 3; }); // replaces first
            MemoryTrim.Register("layout", r => { seen.Add(r); return 2; });

            Assert.Equal(5, MemoryTrim.RunNow(MemoryTrimReason.Pressure));
            Assert.Equal(1, MemoryTrim.Runs);
            Assert.Equal(5, MemoryTrim.LastDropped);

            // Pressure deduplication within PressureWindow (1 s).
            Assert.True(MemoryTrim.PressureSignal(TimeSpan.FromSeconds(10.0)));
            Assert.False(MemoryTrim.PressureSignal(TimeSpan.FromSeconds(10.4)));
            Assert.True(MemoryTrim.PressureSignal(TimeSpan.FromSeconds(11.1)));
            Assert.Equal(3, MemoryTrim.Runs);

            // Cancelled background trim does not run.
            MemoryTrim.BackgroundDelay = TimeSpan.FromMilliseconds(80);
            MemoryTrim.ScheduleBackground();
            MemoryTrim.CancelBackground();
            await Task.Delay(160);
            Assert.Equal(3, MemoryTrim.Runs);

            // Active background trim runs with MemoryTrimReason.Background.
            MemoryTrim.BackgroundDelay = TimeSpan.FromMilliseconds(30);
            MemoryTrim.ScheduleBackground();
            Assert.True(await Until(() => MemoryTrim.Runs == 4));
            await MemoryTrim.SettleAsync();
            Assert.Contains(MemoryTrimReason.Background, seen);
        }
        finally
        {
            MemoryTrim.ResetForTests();
        }
    }

    // ------------------------------------------------------------------ Test helpers

    private sealed class FakeTerminalSocket : ITerminalSocket
    {
        private readonly Channel<TerminalFrame?> _in = Channel.CreateUnbounded<TerminalFrame?>();
        private readonly List<TerminalFrame> _sent = [];
        public int? CloseCode { get; set; }
        public string? CloseReason { get; set; }
        public int? RefusedStatus { get; set; }
        public void Push(TerminalFrame frame) => _in.Writer.TryWrite(frame);
        public async Task<TerminalFrame> ReceiveAsync(CancellationToken ct) =>
            await _in.Reader.ReadAsync(ct) ?? throw new IOException("closed");
        public void Send(TerminalFrame frame) { lock (_sent) _sent.Add(frame); }
        public IReadOnlyList<string> SentTexts() { lock (_sent) return [.. _sent.OfType<TerminalFrame.Text>().Select(t => t.Value)]; }
        public void Close() => _in.Writer.TryWrite(null);
    }

    private sealed class ReplayStandin : IAsyncDisposable
    {
        private readonly HttpListener _http = new();
        private readonly CancellationTokenSource _life = new();
        private readonly object _gate = new();
        private Func<JsonNode, Task>? _send;
        private Action? _cut;

        public string Url { get; }
        public Func<string, long, Task<JsonObject>> OnEventsSince { get; set; } =
            (_, _) => Task.FromResult(new JsonObject { ["epoch"] = "ep-1", ["events"] = new JsonArray() });

        public ReplayStandin()
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

        public static JsonObject EventJson(string sessionId, long seq) => new()
        {
            ["type"] = "message.delta",
            ["session_id"] = sessionId,
            ["seq"] = seq,
            ["payload"] = new JsonObject { ["delta"] = $"chunk-{seq}" },
        };

        public Task EmitEventAsync(string sessionId, long seq)
        {
            Func<JsonNode, Task>? send;
            lock (_gate) send = _send;
            return send?.Invoke(new JsonObject
            {
                ["jsonrpc"] = "2.0",
                ["method"] = "event",
                ["params"] = EventJson(sessionId, seq),
            }) ?? Task.CompletedTask;
        }

        public void CutCurrentSocket()
        {
            Action? cut;
            lock (_gate) cut = _cut;
            cut?.Invoke();
        }

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
            var sendGate = new SemaphoreSlim(1, 1);
            async Task Send(JsonNode n)
            {
                await sendGate.WaitAsync();
                try { await ws.SendAsync(Encoding.UTF8.GetBytes(n.ToJsonString()), WebSocketMessageType.Text, true, CancellationToken.None); }
                catch (Exception e) when (e is WebSocketException or ObjectDisposedException or InvalidOperationException) { }
                finally { sendGate.Release(); }
            }
            void Cut()
            {
                ws.Abort();
                try { ctx.Response.Abort(); } catch { }
            }
            lock (_gate) { _send = Send; _cut = Cut; }
            await Send(new JsonObject
            {
                ["jsonrpc"] = "2.0",
                ["method"] = "event",
                ["params"] = new JsonObject
                {
                    ["type"] = "gateway.ready",
                    ["payload"] = new JsonObject { ["replay_epoch"] = "ep-1" },
                },
            });
            var buffer = new byte[64 * 1024];
            while (ws.State == WebSocketState.Open && !_life.IsCancellationRequested)
            {
                using var frame = new MemoryStream();
                try
                {
                    WebSocketReceiveResult r;
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
                if (method == "client.capabilities" || req["id"] is not { } id) continue;
                var answerId = id.DeepClone();
                var p = req["params"] as JsonObject ?? [];
                _ = Task.Run(async () =>
                {
                    JsonNode result = method == "session.events.since"
                        ? await OnEventsSince(p.Str("session_id") ?? "", p.Int("last_seen") ?? 0)
                        : new JsonObject { ["ok"] = true };
                    await Send(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = answerId, ["result"] = result });
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

    private sealed class ChatStandin : IAsyncDisposable
    {
        private const string RuntimeId = "rt-stress-01";
        private readonly HttpListener _http = new();
        private readonly CancellationTokenSource _life = new();
        private readonly object _gate = new();
        private Func<JsonNode, Task>? _send;

        public string Url { get; }
        public string? ResolvedStoredId { get; set; }
        public Func<long, CancellationToken, Task<JsonObject>>? OnHistory { get; set; }
        public Func<string, JsonObject, Task<JsonNode?>>? OnRpc { get; set; }
        public Func<CancellationToken, Task>? OnUpload { get; set; }
        public Func<CancellationToken, Task>? OnDownload { get; set; }

        public ChatStandin()
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

        public Task EmitEventAsync(string type, JsonObject payload)
        {
            Func<JsonNode, Task>? send;
            lock (_gate) send = _send;
            return send?.Invoke(new JsonObject
            {
                ["jsonrpc"] = "2.0",
                ["method"] = "event",
                ["params"] = new JsonObject
                {
                    ["type"] = type,
                    ["session_id"] = RuntimeId,
                    ["payload"] = payload,
                },
            }) ?? Task.CompletedTask;
        }

        private async Task Serve()
        {
            while (!_life.IsCancellationRequested)
            {
                HttpListenerContext ctx;
                try { ctx = await _http.GetContextAsync(); } catch { return; }
                _ = Task.Run(() => Handle(ctx));
            }
        }

        private static async Task WriteJson(HttpListenerContext ctx, string body)
        {
            var bytes = Encoding.UTF8.GetBytes(body);
            ctx.Response.ContentType = "application/json";
            ctx.Response.ContentLength64 = bytes.Length;
            await ctx.Response.OutputStream.WriteAsync(bytes);
            ctx.Response.Close();
        }

        private async Task Handle(HttpListenerContext ctx)
        {
            var path = ctx.Request.Url!.AbsolutePath;
            var method = ctx.Request.HttpMethod;
            try
            {
                if (path == "/api/auth/ws-ticket")
                {
                    await WriteJson(ctx, """{"ticket":"synthetic-ticket"}""");
                    return;
                }
                if (path == "/api/files" && method == "GET")
                {
                    await WriteJson(ctx, """{"path":"/Users/me/uploads"}""");
                    return;
                }
                if (path == "/api/files/upload-stream" && method == "POST")
                {
                    if (OnUpload != null) await OnUpload(_life.Token);
                    await WriteJson(ctx, """{"path":"/Users/me/uploads/staging/id/file.txt"}""");
                    return;
                }
                if (path == "/api/fs/download" && method == "GET")
                {
                    if (OnDownload != null) await OnDownload(_life.Token);
                    var data = "synthetic-png"u8.ToArray();
                    ctx.Response.ContentType = "image/png";
                    ctx.Response.ContentLength64 = data.Length;
                    await ctx.Response.OutputStream.WriteAsync(data);
                    ctx.Response.Close();
                    return;
                }
                if (path.StartsWith("/api/sessions/", StringComparison.Ordinal) && path.EndsWith("/messages", StringComparison.Ordinal))
                {
                    long offset = 0;
                    var rawOffset = ctx.Request.QueryString["offset"];
                    if (!string.IsNullOrEmpty(rawOffset)) long.TryParse(rawOffset, out offset);
                    var body = OnHistory != null
                        ? await OnHistory(offset, _life.Token)
                        : new JsonObject { ["messages"] = new JsonArray(), ["has_more"] = false, ["next_offset"] = 0 };
                    await WriteJson(ctx, body.ToJsonString());
                    return;
                }
                if (path != "/api/ws" || !ctx.Request.IsWebSocketRequest)
                {
                    ctx.Response.StatusCode = 404;
                    ctx.Response.Close();
                    return;
                }
                var ws = (await ctx.AcceptWebSocketAsync(null)).WebSocket;
                var sendGate = new SemaphoreSlim(1, 1);
                async Task Send(JsonNode n)
                {
                    await sendGate.WaitAsync();
                    try { await ws.SendAsync(Encoding.UTF8.GetBytes(n.ToJsonString()), WebSocketMessageType.Text, true, CancellationToken.None); }
                    catch (Exception e) when (e is WebSocketException or ObjectDisposedException or InvalidOperationException) { }
                    finally { sendGate.Release(); }
                }
                lock (_gate) _send = Send;
                await Send(new JsonObject
                {
                    ["jsonrpc"] = "2.0",
                    ["method"] = "event",
                    ["params"] = new JsonObject
                    {
                        ["type"] = "gateway.ready",
                        ["payload"] = new JsonObject { ["replay_epoch"] = "ep-1" },
                    },
                });
                var buffer = new byte[64 * 1024];
                while (ws.State == WebSocketState.Open && !_life.IsCancellationRequested)
                {
                    using var frame = new MemoryStream();
                    try
                    {
                        WebSocketReceiveResult r;
                        do
                        {
                            r = await ws.ReceiveAsync(buffer, _life.Token);
                            if (r.MessageType == WebSocketMessageType.Close) return;
                            frame.Write(buffer, 0, r.Count);
                        } while (!r.EndOfMessage);
                    }
                    catch { return; }
                    if (JsonNode.Parse(Encoding.UTF8.GetString(frame.ToArray())) is not JsonObject req) continue;
                    var rpc = req["method"]?.GetValue<string>() ?? "";
                    if (rpc == "client.capabilities" || req["id"] is not { } id) continue;
                    var answerId = id.DeepClone();
                    var p = req["params"] as JsonObject ?? [];
                    _ = Task.Run(async () =>
                    {
                        JsonNode? custom = OnRpc != null ? await OnRpc(rpc, p) : null;
                        JsonNode result = custom ?? rpc switch
                        {
                            "session.resume" => ResolvedStoredId is { } resId
                                ? new JsonObject { ["session_id"] = RuntimeId, ["session_key"] = resId }
                                : new JsonObject { ["session_id"] = RuntimeId },
                            "prompt.submit" => new JsonObject { ["user_row_id"] = 42 },
                            "session.interrupt" => new JsonObject { ["ok"] = true },
                            _ => new JsonObject { ["ok"] = true },
                        };
                        await Send(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = answerId, ["result"] = result });
                    });
                }
            }
            catch { try { ctx.Response.Abort(); } catch { } }
        }

        public ValueTask DisposeAsync()
        {
            _life.Cancel();
            try { _http.Close(); } catch (ObjectDisposedException) { }
            return ValueTask.CompletedTask;
        }
    }
}
