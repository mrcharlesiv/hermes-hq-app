using System.Text.Json.Nodes;
using Hermes.Core.Notifications;
using HermesHQ.Services;
using static Hermes.Core.Tests.ToastQuietRunner;

namespace ToastForeground.Tests;

// Execute the selected reply route. Only the last callbacks (body and shots) are counters.
public sealed partial class ForegroundTests
{
    private const string Url = "http://127.0.0.1:9736", User = "toast-fixture";
    private const string NotRead = "quns=not-read focus=not-read app=not-read";
    private const string Discarded = "quns=discarded focus=discarded app=discarded";
    private const string Clear = "quns=QUNS_ACCEPTS_NOTIFICATIONS focus=off app=Enabled";
    private static string Sample(string states, string gap, string phase = "entry") => $"toast-quiet/v1 run=28.2 sha={Sha} phase={phase} {states} writes=0 restore=not-needed banner=unverified gap={gap}";
    private static readonly string[] Full = "window queue thread sheet content root shell shell-loaded shell-root key-state online pane shell-id chat chat-loaded chat-id chat-root tracked popups popup-open last-popup composer enabled visible focused owned foreground".Split(' ');
    private static readonly string[] Settings = ["quns", "focus-profile", "app-setting"];
    private static IEnumerable<string> Through(string step) => Full[..(1 + Array.IndexOf(Full, step))];

    private sealed class Walk
    {
        internal readonly Scene Scene = new();
        internal readonly List<string> Lines = [];
        internal readonly Dictionary<string, string?> Env = Push();
        internal readonly JsonObject Extra = new() { ["url"]=Url, ["username"]=User, ["tag"]="toasts", ["places"]=new JsonArray(), ["walks"]=new JsonArray("toasts") };
        internal readonly JsonObject Plan;
        internal readonly object Session = new();
        internal object? Live;
        internal int Bindings, ContextReads, Actions;
        internal ToastQuietProbe? Probe;
        internal Action<string>? AfterNote;
        private readonly ReplyWalkDispatch dispatch;
        internal Walk()
        {
            Scene.Now = Scene;
            Live = Session;
            Plan = new JsonObject { ["url"]="http://127.0.0.1:9711", ["extras"]=new JsonArray(Extra) };
            dispatch = new(Plan, new Dictionary<string, Func<Func<string, Task>, Task>>(),
                new Dictionary<string, Func<Func<string, Task>, ToastQuietProbe, Task>> { ["toasts"] = (shot, _) => { Actions++; return shot("fixture"); } });
        }
        internal Task Run() => dispatch.RunAsync(Extra, "toasts", "toasts", Session, (cfg, extra, walk, adopted) => {
            Bindings++;
            return Probe = new(true, Env.GetValueOrDefault, _ => {
                ContextReads++;
                return ToastQuietProbe.IsReplyWalk(cfg, extra, walk, Url, User, adopted, Live, 0);
            }, ReplyQuietReadback.Reader(), line => { Lines.Add(line); AfterNote?.Invoke(line); });
        }, _ => { Actions++; return Task.CompletedTask; }, (_, _) => { Actions++; return Task.CompletedTask; });

        internal async Task AssertLatched(QuietWalkStopped first)
        {
            var before = (Bindings, ContextReads, Scene.Reads.Count, Lines.Count, Actions);
            Assert.Same(first, await Assert.ThrowsAsync<QuietWalkStopped>(Run));
            Assert.Same(first, Assert.Throws<QuietWalkStopped>(() => Probe!.Checkpoint(QuietPoint.Entry)));
            Assert.Same(first, Assert.Throws<QuietWalkStopped>(() => Probe!.RecheckChat()));
            Assert.Same(first, Assert.Throws<QuietWalkStopped>(() => Probe!.RequireAwayLifetime()));
            Assert.Equal(before, (Bindings, ContextReads, Scene.Reads.Count, Lines.Count, Actions));
        }
    }

    // Common to the parent and candidate: the original wire record and first failed read do not change.
    [Theory]
    [InlineData("shell")]
    [InlineData("chat-id")]
    [InlineData("popup-open")]
    [InlineData("focused")]
    [InlineData("foreground")]
    public async Task DistinctInertConditionsHaveTheSameLegacyRefusal(string bad)
    {
        var w = new Walk(); w.Scene.Fail.Add(bad);
        var stop = await Assert.ThrowsAsync<QuietWalkStopped>(w.Run);
        Assert.Equal("toast-quiet-stop/v1 phase=entry gap=foreground-unverified", stop.StopLine);
        Assert.Equal(Sample(NotRead, "foreground-unverified"), Assert.Single(w.Lines, l => l.StartsWith("toast-quiet", StringComparison.Ordinal)));
        Assert.Equal(Through(bad), w.Scene.Reads);
        Assert.Equal((1, 1, 0), (w.Bindings, w.ContextReads, w.Actions));
        await w.AssertLatched(stop);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task OwningBothKindsOfChatKeepsTheOriginalSilentRechecks(bool bot)
    {
        var w = new Walk(); w.Scene.Pane = bot ? Hermes.Core.Shell.OpenPane.BotChat : Hermes.Core.Shell.OpenPane.Chat;
        await w.Run();
        Assert.Equal(new[] { Sample(Clear, "banner-not-observed") }, w.Lines);
        Assert.Equal(Full.Concat(Settings).Concat(Full).Concat(Full).Concat(Full), w.Scene.Reads);
        Assert.Equal((1, 4, 2), (w.Bindings, w.ContextReads, w.Actions));
        w.Scene.Chat = Scene.A; w.Scene.Reads.Clear(); w.Probe!.RequireChat(QuietChat.A);
        Assert.Equal(Full, w.Scene.Reads); Assert.Single(w.Lines);
    }
}
