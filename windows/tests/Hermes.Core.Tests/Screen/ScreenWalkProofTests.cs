// [WIN-SCREEN-PAGE] The bot-screen walk, headless: the real ScreenViewerController and ScreenSession over the walk's
// in-process stand-in (Hermes.Core/Shell/ScreenWalkProof.cs), through each state the walk shoots (connecting, the live
// picture, another viewer holding control, the latest-screenshots fallback), with the walk's own checks. Also pins the
// page's wiring that only a Windows run executes: the walk is registered and shoots its four pictures, the bot menu
// offers the Screen entry after View Sessions (the Mac's BotsOrganizer.menuNodes), and the page leaves one gesture hook.

using Hermes.Core.Composer;
using Hermes.Core.Screen;
using Hermes.Core.Shell;
using static Hermes.Core.Tests.Screen.ScreenWaits;
using P = Hermes.Core.Screen.ScreenSession.Phase;

namespace Hermes.Core.Tests.Screen;

[Collection("ScreenSession")]
public sealed class ScreenWalkProofTests
{
    private sealed class Rig : IDisposable
    {
        public ScreenStandIn StandIn { get; } = new();
        public MainLoop Main { get; } = new();
        public FakeViewerHost Host { get; } = new();
        public ScreenService Service { get; private set; } = null!;
        public ScreenViewerController Viewer { get; private set; } = null!;

        public Rig()
        {
            var standIn = StandIn;
            Main.Run(() =>
            {
                Service = new ScreenService(standIn, standIn.Dial, new ScreenHolds(new MemoryStore()));
                Viewer = new ScreenViewerController(ScreenWalkProof.Bot, ScreenWalkProof.BotName, Service, Host, new FakeViewerTimers(), new FakeFrameTicks());
                Host.Viewer = Viewer;
                Viewer.Load();
                Viewer.Appeared();
            });
        }

        public ScreenViewerState State => Main.Read(() => Host.Last!);
        public T Get<T>(Func<ScreenViewerController, T> read) => Main.Read(() => read(Viewer));
        public Task<bool> Until(Func<ScreenViewerState, bool> done) => ScreenWait(() => Main.Read(() => Host.Last is { } s && done(s)));

        public void Dispose()
        {
            try { Main.Run(() => { Viewer.Left(); Service.Shutdown(); }); } catch (Exception) { }
            Main.Dispose();
            Assert.Empty(Main.Failures);
        }
    }

    [Fact]
    public async Task TheWalkSeesConnectingThenTheLivePictureThenAnotherViewerHoldingThenTheScreenshotsPage()
    {
        using var rig = new Rig();
        // Connecting: the stand-in holds display.status back.
        Assert.Null(ScreenWalkProof.Connecting(rig.State));

        rig.StandIn.Answer();
        Assert.True(await ScreenWait(() => rig.Get(v => v.Session.CurrentPhase is P.Live && v.Stage.HasPicture)));
        Assert.True(await rig.Until(s => s.KeepAwake));
        Assert.Null(ScreenWalkProof.Live(rig.State, rig.Get(v => v.Stage.HasPicture), rig.Get(v => v.Stage.Framebuffer)));
        Assert.Equal(1, rig.StandIn.Sockets);

        rig.StandIn.Hold();
        Assert.True(await rig.Until(s => s.Bar.Force));
        Assert.Null(ScreenWalkProof.Held(rig.State));

        rig.StandIn.Unsupported();
        Assert.True(await rig.Until(s => s.FallbackShown));
        Assert.Null(ScreenWalkProof.Fallback(rig.State));
    }

    [Fact]
    public void TheStandInsPictureIsRfb38WithOneRawUpdateOfTheWholeScreen()
    {
        var bytes = ScreenStandIn.Picture();
        Assert.Equal("RFB 003.008\n", System.Text.Encoding.ASCII.GetString(bytes, 0, 12));
        var name = ScreenWalkProof.Display.Length;
        // version 12 + security 2 + result 4 + ServerInit 24 + name, then the update header 4 + rect 12, then BGRX pixels.
        Assert.Equal(12 + 2 + 4 + 24 + name + 4 + 12 + ScreenWalkProof.Width * ScreenWalkProof.Height * 4, bytes.Length);
        Assert.Null(ScreenWalkProof.Pixel(ScreenStandIn.Pixel(ScreenWalkProof.Width / 2, ScreenWalkProof.Height / 2)));
        Assert.NotNull(ScreenWalkProof.Pixel((0, 0, 0)));
    }

    [Fact]
    public void EachCheckSaysWhatIsWrong()
    {
        Assert.Contains("connecting", ScreenWalkProof.Connecting(new ScreenViewerState { Panel = new ScreenPanelModel { Hidden = true } }));
        Assert.Contains("no picture", ScreenWalkProof.Live(new ScreenViewerState(), false, (0, 0)));
        Assert.Contains("held", ScreenWalkProof.Held(new ScreenViewerState()));
        Assert.Contains("fallback", ScreenWalkProof.Fallback(new ScreenViewerState()));
    }

    private static string Source(params string[] parts)
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !Directory.Exists(Path.Combine(dir.FullName, "src", "HermesHQ.Windows"))) dir = dir.Parent;
        Assert.NotNull(dir);
        return File.ReadAllText(Path.Combine([dir!.FullName, "src", "HermesHQ.Windows", .. parts])).ReplaceLineEndings("\n");
    }

    [Fact]
    public void TheWalkIsRegisteredAndShootsEachState()
    {
        var walk = Source("Services", "ProofWalks.Screen.cs");
        Assert.Contains("Automation.NamedWalks[ScreenWalkProof.Walk] = BotScreenAsync;", walk);
        foreach (var shot in ScreenWalkProof.Shots) Assert.Contains($"\"{shot}\"", walk);
        Assert.Contains("RegisterScreenWalks();", Source("Services", "ProofWalks.cs"));
    }

    [Fact]
    public void TheBotMenuOffersTheScreenAfterViewSessionsAsTheMacDoes()
    {
        var menu = Source("Features", "Bots", "BotActions.cs");
        var sessions = menu.IndexOf("Item(\"View Sessions\"", StringComparison.Ordinal);
        var screen = menu.IndexOf("ScreenFeature.MenuItem(", StringComparison.Ordinal);
        Assert.True(sessions > 0 && screen > sessions, "the Screen entry follows View Sessions in the bot's info group");
        Assert.Equal("Watch Screen", ScreenKind.Live.MenuTitle());
        Assert.Equal("View Screen", ScreenKind.Unknown.MenuTitle());
        Assert.Equal("Latest Screenshots", ScreenKind.Screenshots.MenuTitle());
    }

    /// [WIN-SCREEN-INPUT-WIRE] The stage takes every WinUI pointer event through ScreenStageInput, lays the stage out
    /// on every size change, offers Narrator its patterns, and the page's key field feeds ScreenKeyInput.
    [Fact]
    public void TheStageAndTheKeyFieldAreWiredIntoHermesCore()
    {
        var stage = Source("Features", "Screen", "ScreenStageView.cs");
        foreach (var hook in new[] { "PointerPressed +=", "PointerMoved +=", "PointerReleased +=", "PointerCanceled +=",
                                     "PointerCaptureLost +=", "PointerWheelChanged +=" })
            Assert.Contains(hook, stage);
        Assert.Contains("new ScreenStageInput(_stage)", stage);
        Assert.Contains("_stage.Layout(new ScreenSize(", stage);
        Assert.Contains("OnCreateAutomationPeer", stage);
        Assert.Contains("ScreenStageAccess.Run(", stage);
        Assert.Contains("_stage.ZoomBy(factor)", stage);
        Assert.Contains("_stage.FitView", stage);
        Assert.Contains("ScreenStageMotion.ViewSeconds", stage);
        Assert.DoesNotContain("Gestures", stage);   // the placeholder hook is gone: the wiring is the view's own
        var page = Source("Features", "Screen", "ScreenViewerPage.cs");
        Assert.Contains("ScreenKeyFeed.KeyDown(Viewer.KeyInput", page);
        Assert.Contains("ScreenKeyFeed.Character(Viewer.KeyInput", page);
        Assert.Contains("Viewer?.KeyInput.FocusChanged(on)", page);
        Assert.Contains("RightAlt: Down(VirtualKey.RightMenu)", page);
    }
}
