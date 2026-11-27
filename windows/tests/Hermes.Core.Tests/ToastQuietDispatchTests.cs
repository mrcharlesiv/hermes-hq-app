using System.Text.Json.Nodes;
using Hermes.Core.Notifications;

namespace Hermes.Core.Tests;

public partial class ToastQuietProbeTests
{
    // The real extra dispatcher, with two counters in place of walk bodies. The binder must consume the
    // objects the dispatcher supplies, not silently substitute the original test plan, node or session.
    private sealed class DispatchFixture
    {
        internal readonly Fixture F = new();
        internal readonly Dictionary<string, Func<Func<string, Task>, Task>> Named = new(StringComparer.Ordinal);
        internal readonly Dictionary<string, Func<Func<string, Task>, ToastQuietProbe, Task>> Bound = new(StringComparer.Ordinal);
        internal readonly ReplyWalkDispatch Dispatch;
        internal int Bindings, Ordinary, Typed, Shots, OrdinaryShots;
        internal ToastQuietProbe? Observed;
        internal DispatchFixture(bool clonePlan = false)
        {
            Named.Add("quick-action-run", async shot => { Ordinary++; await shot("ordinary"); });
            Bound.Add("toasts", async (shot, quiet) =>
            {
                Typed++;
                Assert.Same(Observed, quiet);
                Assert.Contains("phase=entry", Assert.Single(F.Lines));
                quiet.RequireChat(QuietChat.B);
                await shot("toasts");
            });
            Dispatch = new(clonePlan ? F.Config.DeepClone() : F.Config, Named, Bound);
        }
        private ToastQuietProbe Bind(JsonNode? plan, JsonNode selected, string walk, object adopted)
        {
            Bindings++;
            return Observed = new(true, F.Env.GetValueOrDefault, trackA => (!trackA || F.TracksA)
                && ToastQuietProbe.IsReplyWalk(plan, selected, walk, F.LiveUrl, F.LiveUser, adopted, F.Current, F.Pending), F.Reader, F.Lines.Add);
        }
        internal Task Run(string tag = "toasts", string walk = "toasts", JsonNode? selected = null) =>
            Dispatch.RunAsync(selected ?? F.Extra, tag, walk, F.Bound!, Bind,
                _ => { OrdinaryShots++; return Task.CompletedTask; }, (_, q) => { Assert.Same(Observed, q); q.RecheckChat(); Shots++; return Task.CompletedTask; });
    }

    [Fact]
    public async Task OriginalPlanNodeAndAdoptedSessionEnterOnlyTheTypedHandlerOnce()
    {
        var d = new DispatchFixture(); d.F.RequirePlan(); d.Dispatch.RequireUnique();
        await d.Run();
        Assert.Equal((1, 1, 1, 0, 0), (d.Bindings, d.Typed, d.Shots, d.Ordinary, d.OrdinaryShots));
        Assert.Single(d.F.Reader.Calls, c => c == "focus");
        var twice = await Assert.ThrowsAsync<QuietWalkStopped>(() => d.Run());
        Assert.Equal("toast-quiet-stop/v1 phase=dispatch gap=route-not-unique", twice.StopLine);
        Assert.Equal((1, 1, 1), (d.Bindings, d.Typed, d.Shots));
    }

    [Fact]
    public async Task OrdinaryWalkKeepsItsOwnHandlerAndShotWithoutBindingAReader()
    {
        var d = new DispatchFixture();
        await d.Run("jobs", "quick-action-run", d.F.Extras[0]);
        Assert.Equal((1, 1, 0, 0, 0), (d.Ordinary, d.OrdinaryShots, d.Bindings, d.Typed, d.Shots));
        Assert.Empty(d.F.Reader.Calls); Assert.Empty(d.F.Lines);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ReplacingOrRenamingTheOriginalFinalExtraCannotChangeItsRoute(bool rename)
    {
        var d = new DispatchFixture(); d.F.RequirePlan(); d.Dispatch.RequireUnique();
        JsonNode selected = d.F.Extra;
        if (rename) { selected["tag"] = "jobs"; selected["walks"] = new JsonArray("quick-action-run"); }
        else { selected = selected.DeepClone(); d.F.Extras[^1] = selected; }
        var stop = await Assert.ThrowsAsync<QuietWalkStopped>(() => rename
            ? d.Run("jobs", "quick-action-run", selected) : d.Run(selected: selected));
        Assert.Same(stop, await Assert.ThrowsAsync<QuietWalkStopped>(() => d.Run("jobs", "quick-action-run", d.F.Extras[0])));
        Assert.Equal((0, 0, 0, 0), (d.Ordinary, d.Typed, d.Shots, d.OrdinaryShots));
        Assert.Empty(d.F.Reader.Calls);
    }

    [Theory]
    [InlineData("missing", "dispatch", "route-not-unique")]
    [InlineData("generic-only", "dispatch", "route-not-unique")]
    [InlineData("both", "dispatch", "route-not-unique")]
    [InlineData("wrong-tag", "dispatch", "route-not-unique")]
    [InlineData("wrong-name", "dispatch", "route-not-unique")]
    [InlineData("both-labels-wrong", "dispatch", "route-not-unique")]
    [InlineData("cloned-plan", "dispatch", "not-reply-walk")]
    [InlineData("cloned-node", "dispatch", "not-reply-walk")]
    [InlineData("other-tree", "dispatch", "not-reply-walk")]
    [InlineData("replaced-session", "entry", "not-reply-walk")]
    [InlineData("pending", "entry", "not-reply-walk")]
    [InlineData("revoked-runner", "entry", "runner-not-authorized")]
    [InlineData("no-composer", "entry", "foreground-unverified")]
    [InlineData("unknown-focus", "entry", "focus-unknown")]
    public async Task DispatchRefusalLatchesBeforeEitherHandlerOrShot(string change, string phase, string reason)
    {
        var d = new DispatchFixture(change == "cloned-plan"); d.F.RequirePlan();
        string tag = "toasts", name = "toasts"; JsonNode? selected = null;
        switch (change)
        {
            case "missing": d.Bound.Clear(); break;
            case "generic-only": d.Bound.Clear(); goto case "both";
            case "both": d.Named["toasts"] = d.Named["quick-action-run"]; break;
            case "wrong-tag": tag = "jobs"; break;
            case "wrong-name": name = "quick-action-run"; break;
            case "both-labels-wrong": tag = "jobs"; name = "quick-action-run"; break;
            case "cloned-node": selected = d.F.Extra.DeepClone(); break;
            case "other-tree": selected = d.F.Config.DeepClone()["extras"]![1]; break;
            case "replaced-session": d.F.Current = new object(); break;
            case "pending": d.F.Pending = 1; break;
            case "revoked-runner": d.F.Env.Remove("HQW_DESKTOP_PROOF"); break;
            case "no-composer": d.F.Reader.Foreground = false; break;
            case "unknown-focus": d.F.Reader.Profile = null; break;
        }
        var stop = await Assert.ThrowsAsync<QuietWalkStopped>(() => d.Run(tag, name, selected));
        Assert.Equal($"toast-quiet-stop/v1 phase={phase} gap={reason}", stop.StopLine);
        var counters = (d.Bindings, d.F.Reader.Calls.Count, d.F.Lines.Count);
        Assert.Equal(phase == "entry" ? 1 : 0, d.Bindings);
        d.F.Reader.Foreground = true; d.F.Reader.Profile = new(0, 4, 1, 0); d.F.Current = d.F.Bound;
        Assert.Same(stop, await Assert.ThrowsAsync<QuietWalkStopped>(() => d.Run()));
        Assert.Same(stop, await Assert.ThrowsAsync<QuietWalkStopped>(() => d.Run("jobs", "quick-action-run", d.F.Extras[0])));
        Assert.Equal(counters, (d.Bindings, d.F.Reader.Calls.Count, d.F.Lines.Count));
        Assert.Equal((0, 0, 0, 0), (d.Typed, d.Ordinary, d.Shots, d.OrdinaryShots));
    }

    [Fact]
    public async Task LosingTheExplicitSourceAcrossAYieldStopsTheReservedCaptureAndLaterDispatch()
    {
        var d = new DispatchFixture();
        d.Bound["toasts"] = async (shot, quiet) =>
        {
            d.Typed++;
            d.F.Reader.Chat = QuietChat.A; quiet.RequireChat(QuietChat.A);
            await Task.Yield(); d.F.Reader.Chat = QuietChat.B;
            await shot("reserved"); // capture rechecks A, never substitutes the focused B
        };
        var stop = await Assert.ThrowsAsync<QuietWalkStopped>(() => d.Run());
        Assert.Equal("toast-quiet-stop/v1 phase=guard-a gap=foreground-unverified", stop.StopLine);
        Assert.Same(stop, await Assert.ThrowsAsync<QuietWalkStopped>(() => d.Run()));
        Assert.Equal((1, 1, 0, 0, 0), (d.Bindings, d.Typed, d.Shots, d.Ordinary, d.OrdinaryShots));
    }

    [Fact]
    public async Task UnexpectedFailureInTheBoundBodyHasNoGenericFallbackAndNoPrivateOutput()
    {
        var d = new DispatchFixture();
        d.Bound["toasts"] = (_, _) => { d.Typed++; throw new TimeoutException("fixture-private-canary"); };
        var stop = await Assert.ThrowsAsync<QuietWalkStopped>(() => d.Run());
        Assert.Equal("toast-quiet-stop/v1 phase=walk gap=reply-walk-incomplete", stop.StopLine);
        Assert.Same(stop, await Assert.ThrowsAsync<QuietWalkStopped>(() => d.Run()));
        Assert.Equal((1, 0, 0, 0), (d.Typed, d.Shots, d.OrdinaryShots, d.Ordinary));
    }

    [Theory]
    [InlineData("scope", "not-reply-walk")]
    [InlineData("session", "not-reply-walk")]
    [InlineData("pending", "not-reply-walk")]
    [InlineData("runner", "runner-not-authorized")]
    public void LossWhileMinimizedVetoesTheNextActionWithoutInspectingTheForeground(string loss, string reason)
    {
        var f = new Fixture(); var q = f.Bind();
        q.Checkpoint(QuietPoint.Entry); q.Checkpoint(QuietPoint.BeforeFirst); q.Checkpoint(QuietPoint.BeforeAway);
        f.Reader.Foreground = false;
        int reads = f.Reader.Calls.Count;
        q.RequireAwayLifetime();
        switch (loss)
        {
            case "scope": f.Extra["walks"] = new JsonArray("other"); break;
            case "session": f.Current = new object(); break;
            case "pending": f.Pending = 1; break;
            case "runner": f.Env["GITHUB_RUN_ATTEMPT"] = "3"; break;
        }
        var stop = StopsBeforeAction(q.RequireAwayLifetime);
        Assert.Equal("toast-quiet-stop/v1 phase=walk gap=" + reason, stop.StopLine);
        Assert.Same(stop, StopsBeforeAction(() => q.Checkpoint(QuietPoint.AfterAway)));
        Assert.Equal(reads, f.Reader.Calls.Count);
    }

    [Fact]
    public void TheMinimizedIntervalCannotBeUsedBeforeAdmissionOrAfterRestore()
    {
        var f = new Fixture(); var q = f.Bind();
        Assert.Equal("checkpoint-out-of-order", StopsBeforeAction(q.RequireAwayLifetime).Message);
        Assert.Empty(f.Reader.Calls);
        var other = f.Bind();
        foreach (var p in new[] { QuietPoint.Entry, QuietPoint.BeforeFirst, QuietPoint.BeforeAway, QuietPoint.AfterAway }) other.Checkpoint(p);
        Assert.Equal("checkpoint-out-of-order", StopsBeforeAction(other.RequireAwayLifetime).Message);
    }

    [Theory]
    [InlineData("text-scale", "9863")]
    [InlineData("high-contrast", "9864")]
    public void OnlyTheTwoExistingSingleContrastPlansAreNotFullPlans(string tag, string port)
    {
        var cfg = JsonNode.Parse("""{"extrasOnly":true,"extras":[{"places":[]}]}""")!;
        var extra = cfg["extras"]![0]!; extra["tag"] = tag; extra["url"] = "http://127.0.0.1:" + port; extra["walks"] = new JsonArray(tag);
        Assert.True(ReplyWalkDispatch.IsContrastPass(cfg));
        foreach (var mutate in new Action<JsonNode>[] { n => n["url"] = "http://127.0.0.1:9711", n => n["extrasOnly"] = "true",
            n => n["extras"]![0]!["url"] = Url, n => n["extras"]![0]!["tag"] = "toasts", n => n["extras"]![0]!["walks"] = new JsonArray(tag, "toasts"),
            n => n["extras"]!.AsArray().Add(extra.DeepClone()), n => n["extras"]![0]!["places"] = new JsonArray("settings") })
        {
            var bad = cfg.DeepClone(); mutate(bad); Assert.False(ReplyWalkDispatch.IsContrastPass(bad));
        }
        Assert.False(ReplyWalkDispatch.IsContrastPass(null));
    }
}