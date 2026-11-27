// [WIN-SCREEN-WALK] The bot-screen-wire walk's Core checks (Hermes.Core/Shell/ScreenWalkProof.cs ScreenWireWalkProof)
// against windows/ci/fixtures/screen-gateway.py over the real wire: a signed-in HermesClient, ScreenService.For (the
// app's own JSON-RPC calls and display socket dial), the real ScreenViewerController on a main loop with a fake page.
// The setup card's state, the control note and Enable Control's sheet, the fitted and zoomed picture, Take Control, and
// a tap (ScreenStageInput, a touch) and a key (ScreenKeyInput) checked in the stand-in's record as the Mac's PointerEvent
// and KeyEvent bytes. Run through windows/scripts/e2e.sh (HQW_E2E_SCREEN_CREDENTIALS); without it this passes vacuously.

using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Composer;
using Hermes.Core.Net;
using Hermes.Core.Screen;
using Hermes.Core.Shell;
using static Hermes.Core.Tests.Screen.ScreenWaits;
using P = Hermes.Core.Screen.ScreenSession.Phase;

namespace Hermes.Core.Tests.Screen;

[Trait("Category", "E2E")]
[Collection("ScreenSession")]
public sealed class ScreenWireEndToEndTests
{
    private static async Task<JsonNode> Record(string url)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        return JsonNode.Parse(await http.GetStringAsync(url.TrimEnd('/') + ScreenWireWalkProof.StandIn))!;
    }

    private static async Task Phase(string url, string phase)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        (await http.PostAsync(url.TrimEnd('/') + ScreenWireWalkProof.StandIn,
            new StringContent(ScreenWireWalkProof.PhaseBody(phase), Encoding.UTF8, "application/json"))).EnsureSuccessStatusCode();
    }

    private static async Task<string?> UntilWire(string url, Func<JsonNode, string?> check)
    {
        var until = DateTime.UtcNow.AddSeconds(15);
        string? last;
        do
        {
            last = check(await Record(url));
            if (last == null) return null;
            await Task.Delay(200);
        } while (DateTime.UtcNow < until);
        return last;
    }

    [Fact]
    public async Task TheWalksChecksPassOverTheRealWireAndTheTapAndKeyReachTheStandInAsTheMacsBytes()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_SCREEN_CREDENTIALS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        await Phase(url, "setup");
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(30)).Token);

        using var main = new MainLoop();
        var host = new FakeViewerHost();
        ScreenService service = null!;
        ScreenViewerController viewer = null!;
        main.Run(() =>
        {
            service = ScreenService.For(client, new ScreenHolds(new MemoryStore()));
            viewer = new ScreenViewerController(ScreenWireWalkProof.Bot, ScreenWireWalkProof.BotName, service, host, new FakeViewerTimers(), new FakeFrameTicks());
            host.Viewer = viewer;
            viewer.Stage.OnView = (view, committed) => viewer.StageViewChanged(view, committed);
            viewer.Load();
            viewer.Appeared();
        });
        ScreenViewerState State() => main.Read(() => host.Last!);
        Task<bool> Until(Func<ScreenViewerState, bool> done, double seconds = 15) =>
            ScreenWait(() => main.Read(() => host.Last is { } s && done(s)), seconds);
        try
        {
            // Not set up: the screenshots page with its setup card.
            Assert.True(await Until(s => s.FallbackShown, 20));
            Assert.Null(ScreenWireWalkProof.SetupCard(State()));

            // A Mac screen whose control is not set up: the note, Enable Control's sheet, the stream back after it.
            await Phase(url, "mac");
            Assert.True(await Until(s => s.Notes.EnableControl && !s.StageHidden, 30), main.Read(() => viewer.DebugSummary()));
            Assert.True(await ScreenWait(() => main.Read(() => viewer.Stage.HasPicture), 15));
            Assert.Null(ScreenWireWalkProof.ControlNote(State()));
            main.Run(viewer.EnableControl);
            Assert.NotNull(main.Read(() => host.SheetGone));
            main.Run(() => host.SheetGone!());

            // Control set up: Take Control enabled; the picture fitted to a laid-out stage; its pixels the stand-in's.
            await Phase(url, "ready");
            Assert.True(await Until(s => s.Bar.TakeEnabled && !s.StageHidden, 30), main.Read(() => viewer.DebugSummary()));
            Assert.True(await ScreenWait(() => main.Read(() => viewer.Stage.HasPicture), 15));
            main.Run(() => viewer.Stage.Layout(new ScreenSize(800, 600)));
            main.Run(() => viewer.Stage.FitView());
            Assert.Null(main.Read(() => ScreenWireWalkProof.Fitted(host.Last!, viewer.Stage.HasPicture, viewer.Stage.Framebuffer, viewer.Stage.View, viewer.Stage.Drawn, viewer.Stage.Size)));

            main.Run(() => viewer.Stage.ZoomBy(2));
            Assert.True(await Until(s => s.Bar.Fit));
            Assert.Null(main.Read(() => ScreenWireWalkProof.Zoomed(host.Last!, viewer.Stage.View, viewer.Stage.Drawn, viewer.Stage.Size)));
            main.Run(() => viewer.Stage.FitView());

            // Take Control: the lease as the Mac asks it, then a tap and a key on the socket.
            var mark = ScreenWireWalkProof.Inputs(await Record(url));
            main.Run(viewer.Take);
            Assert.True(await Until(s => s.StageControl && s.Bar.Give, 20), main.Read(() => viewer.DebugSummary()));
            Assert.Null(ScreenWireWalkProof.TakeOver(State()));
            Assert.Null(ScreenWireWalkProof.Lease(await Record(url)));
            Assert.True(main.Read(() => viewer.Session.CurrentPhase is P.Live));

            var (px, py) = main.Read(() => viewer.Stage.PointerPixel);
            Assert.Equal((ScreenWireWalkProof.Width / 2, ScreenWireWalkProof.Height / 2), (px, py));
            main.Run(() =>
            {
                var input = new ScreenStageInput(viewer.Stage);
                var box = viewer.Stage.Drawn;
                var at = new ScreenPoint(box.X + box.Width / 2, box.Y + box.Height / 2);
                Assert.True(input.Pressed(new ScreenPointerArgs(91, ScreenStageInput.Touch, at)));
                input.Released(new ScreenPointerArgs(91, ScreenStageInput.Touch, at));
            });
            Assert.Null(await UntilWire(url, r => ScreenWireWalkProof.Tap(r, mark, px, py)));

            main.Run(() =>
            {
                if (!viewer.KeyInput.Focused) viewer.KeyInput.FocusChanged(true);
                viewer.KeyInput.CharacterReceived(ScreenWireWalkProof.KeyChar, ScreenKeyInput.Mods());
            });
            Assert.Null(await UntilWire(url, r => ScreenWireWalkProof.Key(r, mark, ScreenWireWalkProof.KeySym)));

            // The checks are not vacuous: another key or another place is not in the record.
            var record = await Record(url);
            Assert.NotNull(ScreenWireWalkProof.Key(record, mark, 0x71));
            Assert.NotNull(ScreenWireWalkProof.Tap(record, mark, px + 1, py));
            Assert.NotNull(ScreenWireWalkProof.Tap(record, ScreenWireWalkProof.Inputs(record), px, py));
        }
        finally
        {
            try { main.Run(() => { viewer.Left(); service.Shutdown(); }); } catch (Exception) { }
            await Phase(url, "setup");
        }
        Assert.Empty(main.Failures);
    }
}
