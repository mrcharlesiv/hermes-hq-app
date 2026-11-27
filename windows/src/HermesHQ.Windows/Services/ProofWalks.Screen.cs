using Hermes.Core.Composer;
using Hermes.Core.Screen;
using Hermes.Core.Shell;
using HermesHQ.Features.Screen;

namespace HermesHQ.Services;

/// [WIN-SCREEN-PAGE] The CI's walk for a bot's Screen, backed by `Hermes.Core.Shell.ScreenWalkProof`. It needs no
/// fixture server of its own: the viewer runs over ScreenStandIn, an in-process synthetic gateway display side whose
/// socket speaks RFB 3.8 (one raw picture, 320 × 200), so any signed-in extra can run it (walks = @("bot-screen")).
///   bot-screen-connecting  The window opens on "Connecting to the screen…" (the stand-in holds display.status back).
///   bot-screen-live        The picture drawn from the framebuffer (the middle pixel is the stand-in's window colour),
///                          the label under the title, the bar with Take Control, the display kept on.
///   bot-screen-held        Another viewer takes control: the note and End Their Control.
///   bot-screen-fallback    The gateway stops offering a live screen: the latest-screenshots page in its place.
///
/// [WIN-SCREEN-WALK] bot-screen-wire: the same viewer over the REAL wire, the signed-in client against
/// windows/ci/fixtures/screen-gateway.py (windows.yml's "screen" extra), backed by ScreenWireWalkProof:
///   bot-screen-setup-card     No live screen for otto: the latest-screenshots page with its setup card.
///   bot-screen-control-sheet  A Mac screen whose control is not set up: the notes' Enable Control opens Screen Control.
///   bot-screen-viewer         Control set up: the picture drawn from the stand-in's socket, fitted to the stage.
///   bot-screen-zoomed         Zoomed in (the page's Zoom In, ZoomBy 2).
///   bot-screen-take-over      Take Control: the bar's Give Control, the stage in control. Then a tap (ScreenStageInput,
///                             a touch) and a key (ScreenKeyInput) are checked in the stand-in's record as the Mac's
///                             PointerEvent and KeyEvent bytes. No OS input is sent.
///   bot-screen-wire           The take-over state once both reached it (the walk's own name, as windows.yml asks).
internal static partial class ProofWalks
{
    private static void RegisterScreenWalks()
    {
        Automation.NamedWalks[ScreenWalkProof.Walk] = BotScreenAsync;
        Automation.NamedWalks["bot-screen-wire"] = BotScreenWireAsync;   // [WIN-SCREEN-WALK] ScreenWireWalkProof.Walk
    }

    private static async Task BotScreenAsync(Func<string, Task> shot)
    {
        var standIn = new ScreenStandIn();
        var service = new ScreenService(standIn, standIn.Dial, new ScreenHolds(new MemoryStore())) { Note = line => AppLog.Note("screen", line) };
        ScreenFeature.Stand = () => standIn;
        ScreenWindow? window = null;
        try
        {
            var page = ScreenFeature.Open(ScreenWalkProof.Bot, ScreenWalkProof.BotName, service, null)
                ?? throw new InvalidOperationException("the Screen didn't open (another one is open)");
            window = ScreenWindow.Showing ?? throw new InvalidOperationException("no Screen window");
            var connecting = await Until(() => page.Last is { Panel.Id: "screen.connecting" } s ? s : null, "the connecting state");
            if (ScreenWalkProof.Connecting(connecting) is { } c) throw new InvalidOperationException(c);
            await ShotOfAsync(window, () => shot("bot-screen-connecting"));

            standIn.Answer();
            var live = await Until(() => page.Last is { KeepAwake: true, Panel.Hidden: true } s && page.Stage.HasPicture ? s : null, "the live picture", 20);
            if (ScreenWalkProof.Live(live, page.Viewer.Stage.HasPicture, page.Viewer.Stage.Framebuffer) is { } l) throw new InvalidOperationException(l);
            if (page.Stage.PixelAt(ScreenWalkProof.Width / 2, ScreenWalkProof.Height / 2) is not { } middle) throw new InvalidOperationException("live: the page drew no picture");
            if (ScreenWalkProof.Pixel(middle) is { } wrongPixel) throw new InvalidOperationException(wrongPixel);
            if (!page.AwakeHeld) AppLog.Note("automation", "walk bot-screen: the display request wasn't granted (no interactive session?)");
            AppLog.Note("automation", $"walk bot-screen: live {page.Stage.Size.Width}×{page.Stage.Size.Height}, {page.Viewer.DebugSummary()}");
            await ShotOfAsync(window, () => shot("bot-screen-live"));

            standIn.Hold();
            var held = await Until(() => page.Last is { Bar.Force: true } s ? s : null, "another viewer holding control");
            if (ScreenWalkProof.Held(held) is { } h) throw new InvalidOperationException(h);
            await ShotOfAsync(window, () => shot("bot-screen-held"));

            standIn.Unsupported();
            var fallback = await Until(() => page.Last is { FallbackShown: true } s && page.Fallback != null ? s : null, "the latest-screenshots page", 20);
            if (ScreenWalkProof.Fallback(fallback) is { } f) throw new InvalidOperationException(f);
            await Task.Delay(800);
            await ShotOfAsync(window, () => shot("bot-screen-fallback"));
        }
        finally
        {
            window?.Close();
            ScreenFeature.Stand = null;
            service.Shutdown();
            await Task.Delay(300);
        }
    }

    private static async Task ScreenPhaseAsync(string url, string phase)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        var answer = await http.PostAsync(url.TrimEnd('/') + ScreenWireWalkProof.StandIn,
            new StringContent(ScreenWireWalkProof.PhaseBody(phase), System.Text.Encoding.UTF8, "application/json"));
        answer.EnsureSuccessStatusCode();
    }

    private static async Task BotScreenWireAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var url = client.Session.Address.ToString();
        await ScreenPhaseAsync(url, "setup");
        ScreenWindow? window = null;
        try
        {
            var page = ScreenFeature.Open(ScreenWireWalkProof.Bot, ScreenWireWalkProof.BotName)
                ?? throw new InvalidOperationException("the Screen didn't open (no account service, or another one is open)");
            window = ScreenWindow.Showing ?? throw new InvalidOperationException("no Screen window");
            var viewer = page.Viewer;

            // 1. Not set up: the screenshots page and its setup card.
            var setup = await Until(() => page.Last is { FallbackShown: true } s && page.Fallback != null ? s : null, "the setup card", 20);
            if (ScreenWireWalkProof.SetupCard(setup) is { } a) throw new InvalidOperationException(a);
            if (page.Fallback!.Card.Visibility != Microsoft.UI.Xaml.Visibility.Visible) throw new InvalidOperationException("setup: the card is hidden");
            // [WIN-SCREEN-SETUP-LAYOUT] Set Up with Hermes in view at the window's first size (the empty frame no longer
            // runs past the fold), checked before the shot.
            var primary = FindIn(window.Content, "screen.setup.primary") ?? throw new InvalidOperationException("setup: Set Up with Hermes isn't showing");
            await ButtonInViewAsync(window, primary, page.Fallback!);
            await Task.Delay(600);
            await ShotOfAsync(window, () => shot("bot-screen-setup-card"));

            // 2. A Mac screen without control: the note, then Screen Control over it.
            await ScreenPhaseAsync(url, "mac");
            var note = await Until(() => page.Last is { Notes.EnableControl: true } s && page.Stage.HasPicture ? s : null, "the Enable Control note", 30);
            if (ScreenWireWalkProof.ControlNote(note) is { } b) throw new InvalidOperationException(b);
            viewer.EnableControl();
            await Until(() => ScreenSetupSheet.IsOpen && ScreenSetupSheet.Card != null ? ScreenSetupSheet.Card : null, "the Screen Control sheet");
            await Task.Delay(500);
            await ShotOfAsync(window, () => shot("bot-screen-control-sheet"));
            ScreenSetupSheet.CloseOpen();
            await Until(() => ScreenSetupSheet.IsOpen ? null : page, "the sheet closed");

            // 3. Control set up: the picture fitted, its middle the stand-in's window colour.
            await ScreenPhaseAsync(url, "ready");
            var live = await Until(() => page.Last is { Bar.TakeEnabled: true, Panel.Hidden: true } s && page.Stage.HasPicture ? s : null, "Take Control enabled", 30);
            viewer.Fit();
            await Task.Delay(500);
            if (ScreenWireWalkProof.Fitted(page.Last ?? live, page.Stage.HasPicture, viewer.Stage.Framebuffer, viewer.Stage.View, viewer.Stage.Drawn, viewer.Stage.Size) is { } c)
                throw new InvalidOperationException(c);
            var (mx, my) = (ScreenWireWalkProof.Width / 2, ScreenWireWalkProof.Height / 2 + 40);
            if (page.Stage.PixelAt(mx, my) is not { } drawn) throw new InvalidOperationException("viewer: the page drew no picture");
            if (ScreenWireWalkProof.PixelAt(drawn, mx, my) is { } wrong) throw new InvalidOperationException(wrong);
            AppLog.Note("automation", $"walk bot-screen-wire: live {page.Stage.Size.Width}×{page.Stage.Size.Height}, {viewer.DebugSummary()}");
            await ShotOfAsync(window, () => shot("bot-screen-viewer"));

            // 4. Zoomed in, then back to Fit.
            page.ZoomStage(2);
            await Until(() => viewer.Stage.View.Zoom > 1.5 && page.Last is { Bar.Fit: true } s ? s : null, "the zoomed view");
            await Task.Delay(500);
            if (ScreenWireWalkProof.Zoomed(page.Last!, viewer.Stage.View, viewer.Stage.Drawn, viewer.Stage.Size) is { } d) throw new InvalidOperationException(d);
            await ShotOfAsync(window, () => shot("bot-screen-zoomed"));
            page.FitStage();
            await Until(() => Math.Abs(viewer.Stage.View.Zoom - 1) < 0.001 ? page : null, "back to Fit");

            // 5. Take Control, then a tap and a key on the wire.
            var mark = ScreenWireWalkProof.Inputs(await StandIn(url, ScreenWireWalkProof.StandIn));
            viewer.Take();
            var held = await Until(() => page.Last is { StageControl: true, Bar.Give: true } s ? s : null, "control taken", 20);
            if (ScreenWireWalkProof.TakeOver(held) is { } t) throw new InvalidOperationException(t);
            if (ScreenWireWalkProof.Lease(await StandIn(url, ScreenWireWalkProof.StandIn)) is { } l) throw new InvalidOperationException(l);
            await Task.Delay(500);
            await ShotOfAsync(window, () => shot("bot-screen-take-over"));

            var input = new ScreenStageInput(viewer.Stage);
            var box = viewer.Stage.Drawn;
            var at = new ScreenPoint(box.X + box.Width / 2, box.Y + box.Height / 2);
            var (px, py) = viewer.Stage.PointerPixel;
            if (!input.Pressed(new ScreenPointerArgs(91, ScreenStageInput.Touch, at))) throw new InvalidOperationException("tap: the stage didn't take the touch");
            input.Released(new ScreenPointerArgs(91, ScreenStageInput.Touch, at));
            await UntilWire(url, r => ScreenWireWalkProof.Tap(r, mark, px, py), "the tap on the wire");

            // Logged, not masked: whether Take Control's RaiseKeyboard really focused the key field on this desktop.
            var focusedByTake = viewer.KeyInput.Focused;
            AppLog.Note("automation", $"walk bot-screen-wire: key field focused by Take Control: {(focusedByTake ? "yes" : "no, focused by the walk")}");
            if (!focusedByTake) viewer.KeyInput.FocusChanged(true);
            viewer.KeyInput.CharacterReceived(ScreenWireWalkProof.KeyChar, ScreenKeyInput.Mods());
            await UntilWire(url, r => ScreenWireWalkProof.Key(r, mark, ScreenWireWalkProof.KeySym), "the key on the wire");
            AppLog.Note("automation", $"walk bot-screen-wire: tap at {px},{py} and key {ScreenWireWalkProof.KeySym:x} reached the stand-in");
            await ShotOfAsync(window, () => shot("bot-screen-wire"));
        }
        finally
        {
            window?.Close();
            await Task.Delay(300);
            try { await ScreenPhaseAsync(url, "setup"); } catch (Exception e) { AppLog.Note("automation", $"walk bot-screen-wire: reset failed ({e.GetType().Name})"); }
        }
    }

    /// Polls the stand-in's record until `check` passes (null), for at least 10 s.
    private static async Task UntilWire(string url, Func<System.Text.Json.Nodes.JsonNode, string?> check, string what)
    {
        var until = DateTime.UtcNow.AddSeconds(15);
        string? last;
        do
        {
            last = check(await StandIn(url, ScreenWireWalkProof.StandIn));
            if (last == null) return;
            await Task.Delay(250);
        } while (DateTime.UtcNow < until);
        throw new InvalidOperationException($"{what}: {last}");
    }
}
