using Hermes.Core.Notifications;
using HermesHQ.Services;

namespace ToastForeground.Tests;

public sealed partial class ForegroundTests
{
    // Independent oracle: the left side perturbs a raw getter; the right side is the only new wire text allowed.
    public static TheoryData<string, string> Clauses => new() {
        { "window", "WindowMissing" }, { "thread", "NotUiThread" }, { "sheet", "SheetShown" },
        { "content", "ContentNotElement" }, { "root", "RootMissing" }, { "shell", "ShellMissing" },
        { "shell-loaded", "ShellNotLoaded" }, { "shell-root", "ShellRootMismatch" },
        { "key-state", "ShellStateMissing" }, { "online", "ShellOffline" }, { "pane", "NotChatPane" },
        { "shell-id", "ShellChatMismatch" }, { "chat", "ChatMissing" }, { "chat-loaded", "ChatNotLoaded" },
        { "chat-id", "ChatIdMismatch" }, { "chat-root", "ChatRootMismatch" }, { "tracked", "ChatNotTracked" },
        { "popup-open", "OpenPopup" }, { "last-popup", "OpenPopup" }, { "composer", "ComposerNotTextBox" },
        { "enabled", "ComposerDisabled" }, { "visible", "ComposerNotVisible" }, { "focused", "ComposerNotFocused" },
        { "owned", "OwnedHandleMissing" }, { "foreground", "ForegroundNotOwned" },
    };
    private static string Detail(string clause, string phase = "entry") => $"fixture-foreground/v1 phase={phase} clause={clause}";

    [Theory, MemberData(nameof(Clauses))]
    public async Task FirstFailedClauseStopsAtThatRead(string step, string clause)
    {
        var w = new Walk(); w.Scene.Fail.Add(step);
        var stop = await Assert.ThrowsAsync<QuietWalkStopped>(w.Run);
        Assert.Equal(Through(step), w.Scene.Reads);
        Assert.Equal("toast-quiet-stop/v1 phase=entry gap=foreground-unverified", stop.StopLine);
        Assert.Equal(new[] { Sample(NotRead, "foreground-unverified"), Detail(clause) }, w.Lines);
        Assert.Equal((1, 1, 0), (w.Bindings, w.ContextReads, w.Actions));
        await w.AssertLatched(stop);
    }

    [Theory, MemberData(nameof(Clauses))]
    public async Task SecondForegroundSampleStopsAtTheSameClauseWithoutPublishingSettings(string step, string clause)
    {
        var w = new Walk(); w.Scene.AfterRead = s => { if (s == "app-setting") w.Scene.Fail.Add(step); };
        var stop = await Assert.ThrowsAsync<QuietWalkStopped>(w.Run);
        Assert.Equal(Full.Concat(Settings).Concat(Through(step)), w.Scene.Reads);
        Assert.Equal("toast-quiet-stop/v1 phase=entry gap=sample-context-lost", stop.StopLine);
        Assert.Equal(new[] { Sample(Discarded, "sample-context-lost"), Detail(clause) }, w.Lines);
        Assert.Equal((1, 2, 0), (w.Bindings, w.ContextReads, w.Actions));
        await w.AssertLatched(stop);
    }

    [Fact]
    public async Task MultipleSimultaneousMismatchesNameOnlyTheEarliest()
    {
        var w = new Walk(); w.Scene.Fail.UnionWith(["chat-id", "popup-open", "focused", "foreground"]);
        var stop = await Assert.ThrowsAsync<QuietWalkStopped>(w.Run);
        Assert.Equal(Through("chat-id"), w.Scene.Reads);
        Assert.Equal(new[] { Sample(NotRead, "foreground-unverified"), Detail("ChatIdMismatch") }, w.Lines);
        await w.AssertLatched(stop);
    }

    public static IEnumerable<object[]> ReadSteps => Full.Select(step => new object[] { step });

    [Theory, MemberData(nameof(ReadSteps))]
    public async Task AThrowingGetterDisclosesNeitherItsMessageNorAnAssumedMismatch(string step)
    {
        var w = new Walk(); w.Scene.ThrowAt = step;
        var stop = await Assert.ThrowsAsync<QuietWalkStopped>(w.Run);
        Assert.Equal(Through(step), w.Scene.Reads);
        Assert.Equal(new[] { Sample(NotRead, "foreground-unverified"), Detail("Unreadable") }, w.Lines);
        Assert.Equal("toast-quiet-stop/v1 phase=entry gap=foreground-unverified", stop.StopLine);
        Assert.Equal(0, w.Actions);
        await w.AssertLatched(stop);
    }

    [Fact]
    public async Task AValidButDifferentTrackedFixtureChatCannotReplaceTheExpectedOne()
    {
        var w = new Walk(); w.Scene.Chat = Scene.A;
        var stop = await Assert.ThrowsAsync<QuietWalkStopped>(w.Run); // Entry explicitly requires B.
        Assert.Equal(new[] { Sample(NotRead, "foreground-unverified"), Detail("ShellChatMismatch") }, w.Lines);
        Assert.Equal(Through("shell-id"), w.Scene.Reads); Assert.Equal(0, w.Actions);
        await w.AssertLatched(stop);
    }

    [Fact]
    public async Task FailedCanonicalWriteDoesNotProduceAnOrphanClass()
    {
        var w = new Walk(); w.Scene.Fail.Add("shell"); w.AfterNote = _ => throw new IOException(Scene.Canary);
        var stop = await Assert.ThrowsAsync<QuietWalkStopped>(w.Run);
        Assert.Equal("toast-quiet-stop/v1 phase=entry gap=readback-unrecorded", stop.StopLine);
        Assert.Equal(new[] { Sample(NotRead, "foreground-unverified") }, w.Lines);
        Assert.Equal(Through("shell"), w.Scene.Reads); Assert.Equal(0, w.Actions);
        await w.AssertLatched(stop);
    }

    [Theory]
    [InlineData("runner", false)]
    [InlineData("plan", false)]
    [InlineData("session", false)]
    [InlineData("runner", true)]
    [InlineData("plan", true)]
    [InlineData("session", true)]
    public async Task BindingLossDoesNotConsultOrBlameTheForeground(string binding, bool afterGetters)
    {
        var w = new Walk();
        void Revoke()
        {
            if (binding == "runner") w.Env.Remove("HQW_QUIET_PUSH");
            if (binding == "plan") w.Extra["username"] = Scene.Canary;
            if (binding == "session") w.Live = new();
            w.Scene.Fail.Add("window");
        }
        if (afterGetters) w.Scene.AfterRead = s => { if (s == "app-setting") Revoke(); }; else Revoke();
        var stop = await Assert.ThrowsAsync<QuietWalkStopped>(w.Run);
        var gap = afterGetters ? "sample-context-lost" : binding == "runner" ? "runner-not-authorized" : "not-reply-walk";
        Assert.Equal("toast-quiet-stop/v1 phase=entry gap=" + gap, stop.StopLine);
        Assert.DoesNotContain("fixture-foreground", Assert.Single(w.Lines));
        Assert.DoesNotContain(Scene.Canary, w.Lines[0]);
        Assert.Equal(afterGetters ? Full.Concat(Settings) : [], w.Scene.Reads);
        Assert.Equal(0, w.Actions);
        await w.AssertLatched(stop);
    }

    [Fact]
    public async Task LossInTheCanonicalLogStillStopsThePostLogGuardBeforeDispatch()
    {
        var w = new Walk(); w.AfterNote = _ => w.Scene.Fail.Add("focused");
        var stop = await Assert.ThrowsAsync<QuietWalkStopped>(w.Run);
        Assert.Equal("toast-quiet-stop/v1 phase=guard-b gap=foreground-unverified", stop.StopLine);
        Assert.Equal(new[] { Sample(Clear, "banner-not-observed"), Sample(NotRead, "foreground-unverified", "guard-b"), Detail("ComposerNotFocused", "guard-b") }, w.Lines);
        Assert.Equal(Full.Concat(Settings).Concat(Full).Concat(Through("focused")), w.Scene.Reads);
        Assert.Equal(0, w.Actions);
        await w.AssertLatched(stop);
    }

    [Fact]
    public async Task DiagnosticLoggingCannotReenterTheReaderOrChangeTheStop()
    {
        var w = new Walk(); w.Scene.Fail.Add("sheet");
        var reentries = new List<QuietWalkStopped>();
        w.AfterNote = line => {
            // Try re-entry after the original sample AND while writing its optional detail.
            reentries.Add(Assert.Throws<QuietWalkStopped>(() => w.Probe!.RecheckChat()));
            if (line.StartsWith("fixture-foreground", StringComparison.Ordinal)) throw new IOException(Scene.Canary);
        };
        var stop = await Assert.ThrowsAsync<QuietWalkStopped>(w.Run);
        Assert.Equal(new[] { stop, stop }, reentries);
        Assert.Equal(new[] { Sample(NotRead, "foreground-unverified"), Detail("SheetShown") }, w.Lines);
        Assert.Equal("toast-quiet-stop/v1 phase=entry gap=foreground-unverified", stop.StopLine);
        Assert.Equal(Through("sheet"), w.Scene.Reads); Assert.Equal(0, w.Actions);
        await w.AssertLatched(stop);
    }
}
