using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Notifications;
using Hermes.Core.Settings;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Tests.Settings;

public sealed class ParentParityTests
{
    private sealed class MemPrefs : IPreferences
    {
        private readonly Dictionary<string, string> _map = [];
        public string? Get(string key) => _map.GetValueOrDefault(key);
        public void Set(string key, string? value) { if (value == null) _map.Remove(key); else _map[key] = value; }
    }

    [Fact]
    public void EveryStandaloneCardStandsOutFromThePage()
    {
        foreach (var skin in SkinCatalog.All)
        foreach (var desktop in new[] { false, true })
        foreach (var contrast in new[] { false, true })
        {
            if (!desktop && contrast) continue;
            var set = ThemeResolver.Resolve(new ThemeState { SkinId = skin.Id, DesktopLook = desktop, HighContrast = contrast });
            foreach (var dark in new[] { false, true })
            {
                var t = set.Tokens(dark);
                var ground = t.Page.Over(Rgba.White);
                var card = t.PromptCard.Over(ground);
                Assert.True(card.LabDistance(ground) >= 1.5, $"{skin.Id} desktop={desktop} contrast={contrast} dark={dark}: PromptCard too close to Page");
                Assert.True(t.PromptEdge.A > 0, $"{skin.Id} desktop={desktop} contrast={contrast} dark={dark}: PromptEdge transparent");
                Assert.True(t.Label.Over(card).Contrast(card) >= 4.5, $"{skin.Id} desktop={desktop} contrast={contrast} dark={dark}: Label contrast < 4.5 on PromptCard");
            }
        }
    }

    [Fact]
    public void StudioMatteSolidsAndCustomColorAdaptInOklabAndSkipBlur()
    {
        Assert.Equal(11, BackdropCatalog.Solids.Count); // 10 Mineral & Studio + Theme Tint
        Assert.Equal(10, BackdropCatalog.Classic.Count);

        var prefs = new BackdropPrefs(new MemPrefs());
        prefs.SetBlur(BackdropPlace.Chats, true);
        prefs.SetPreset(BackdropPlace.Chats, "solidCobalt");
        var solid = prefs.Load(BackdropPlace.Chats);
        Assert.True(solid.Blur); // stored for photos
        Assert.False(solid.EffectiveBlur(null)); // skipped for solids
        Assert.Equal("Cobalt", solid.Summary(null));

        prefs.SetCustomColor(BackdropPlace.Chats, 0xFF00AA);
        var custom = prefs.Load(BackdropPlace.Chats);
        Assert.True(custom.EffectiveIsSolid(null));
        Assert.False(custom.EffectiveBlur(null));
        Assert.Equal("#FF00AA", custom.Summary(null));

        var light = OkLabSolidAdapt.Adapt(Rgba.Hex(0xFF00AA), dark: false);
        var dark = OkLabSolidAdapt.Adapt(Rgba.Hex(0xFF00AA), dark: true);
        Assert.True(light.Oklab.L > 0.65);
        Assert.True(dark.Oklab.L < 0.45);
    }

    [Fact]
    public void ScheduledWakeParsesBracketedLoopAndSelfDeclaredPrompts()
    {
        var bracketed = TimelineNotes.ScheduledWake("[Scheduled wake: Morning check]\nCheck build logs.");
        Assert.NotNull(bracketed);
        Assert.Equal("Morning check", bracketed!.Value.Title);
        Assert.Equal("Check build logs.", bracketed.Value.Detail);

        var loop = TimelineNotes.ScheduledWake("[Loop wakeup #4]\nPoll deploy");
        Assert.NotNull(loop);
        Assert.Equal("Loop wakeup #4", loop!.Value.Title);

        var self = TimelineNotes.ScheduledWake("Scheduled triage (job_123). This is an automatic check for this session, not a message from the user.\nInspect queue.");
        Assert.NotNull(self);
        Assert.Equal("Triage", self!.Value.Title);
        Assert.Contains("Inspect queue.", self.Value.Detail);
        Assert.Contains("ID: job_123", self.Value.Detail);

        Assert.Null(TimelineNotes.ScheduledWake("Hey Hermes, please check the build logs."));
    }

    [Fact]
    public void AppearanceExtrasRoundTrip()
    {
        var store = new MemPrefs();
        ThinkingBarRow.Store = store;
        ChatsUnderBotsRow.Store = store;
        Assert.True(ThinkingBarRow.IsOn);
        ThinkingBarRow.IsOn = false;
        Assert.False(ThinkingBarRow.IsOn);
        Assert.Equal(ChatsUnderBotsChoice.Three, ChatsUnderBotsRow.Current);
        ChatsUnderBotsRow.Current = ChatsUnderBotsChoice.Five;
        Assert.Equal(5, ChatsUnderBotsRow.Current.Limit());
        ChatsUnderBotsRow.Current = ChatsUnderBotsChoice.All;
        Assert.Null(ChatsUnderBotsRow.Current.Limit());
    }

    [Fact]
    public void AutoThreadsSeedAndContextNoteRoundTrip()
    {
        var msgs = new List<ChatMessage>
        {
            new("u1", Role.User, [new TextPart("Build the app")], RowId: 10),
            new("a1", Role.Assistant, [new TextPart("Starting build")], RowId: 11),
        };
        var seed = ThreadSeed.Rows(msgs, running: false, anchorRow: 11);
        Assert.Equal(2, seed.Count);
        Assert.Equal(11, ThreadSeed.AnchorRow(seed[^1].Text));
        Assert.True(ThreadSeed.IsClosingNote(seed[^1].Text));

        var note = ThreadContextNote.Format([("Side question", msgs)]);
        Assert.NotNull(note);
        var wrapped = ThreadContextNote.Appended("Continue deploy", note!);
        Assert.True(ThreadContextNote.HasNote(wrapped));
        Assert.Equal("Continue deploy", ThreadContextNote.Stripped(wrapped));

        var banner = ThreadRules.ProactiveBanner(null, null, BusyReasonKind.BackgroundTask);
        Assert.Equal("Sending to Thread", banner.Title);
        Assert.Equal("Busy with a background task", banner.Note);
    }

    [Fact]
    public void PushPolicyChecksOwnerCapabilitiesAndVersions()
    {
        var h1 = PushPolicy.Owner("https://EXAMPLE.com/gateway/", "alice");
        var h2 = PushPolicy.Owner("https://example.com/gateway", "alice");
        Assert.Equal(h1, h2);
        Assert.Equal(64, h1.Length);

        var status = JsonNode.Parse("""{"seal":true,"tasks":true,"goal_pages":3,"pluginVersion":"0.9.74","kinds":["turnDone","approval","input"]}""") as JsonObject;
        Assert.True(PushPolicy.Seals(status));
        Assert.True(PushPolicy.Tasks(status));
        Assert.True(PushPolicy.Goals(status));
        Assert.True(PushPolicy.VersionAtLeast(PushPolicy.PluginVersion(status), "0.9.57"));
        Assert.True(PushPolicy.Delivers("message.complete", PushPolicy.Kinds(status)));
    }

    private sealed class NotSentQueueHost : Hermes.Core.Composer.IQueueHost
    {
        public bool Busy { get; set; }
        public bool CanSteerNow => false;
        public SendOutcome Outcome { get; set; } = SendOutcome.NotSent;
        public Task<SendOutcome> SendAsync(Hermes.Core.Composer.QueuedMessage message, bool queued) => Task.FromResult(Outcome);
        public void Stop() { }
        public string BeginSteer(string shown) => "s1";
        public Task<(Hermes.Core.Composer.SteerOutcome Outcome, bool Unsupported)> FinishSteerAsync(string localId, string text) =>
            Task.FromResult((Hermes.Core.Composer.SteerOutcome.Failed, false));
    }

    [Fact]
    public async Task QueuedDrainNotSentRequeuesAtHeadAndParks()
    {
        var host = new NotSentQueueHost { Busy = true, Outcome = SendOutcome.NotSent };
        var q = new Hermes.Core.Composer.ComposerQueue(host);
        q.QueuesNextSend = true;
        q.Send("first");
        q.QueuesNextSend = true;
        q.Send("second");
        host.Busy = false;
        q.TurnEnded(true);
        for (var i = 0; i < 40 && !q.Parked; i++) await Task.Delay(15);
        Assert.True(q.Parked);
        Assert.Equal(["first", "second"], q.Items.Select(i => i.Text));
    }
}
