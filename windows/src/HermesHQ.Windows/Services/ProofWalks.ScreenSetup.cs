using Hermes.Core.Shell;
using HermesHQ.Features.Composer;
using HermesHQ.Features.Screen;
using HermesHQ.Pages;
using Microsoft.UI.Xaml;

namespace HermesHQ.Services;

/// [WIN-SCREEN-SETUP-SEND-WALK] bot-screen-setup-send: Set Up with Hermes pressed for real, over the real wire against
/// windows/ci/fixtures/screen-gateway.py (windows.yml's "screen" extra), backed by Hermes.Core ScreenSetupWalkProof. The
/// Mac's runScreenSetup (93f984bb1 App/Screen/AppModel+Screen.swift): the Screen closes, the bot's own chat opens, the
/// installer goes with `file.attach` and the prompt through the chat's send. Here:
///   otto's Screen opens on its setup card (no live screen); the card's own Set Up with Hermes button is invoked through
///   its automation peer (the button's Click: no OS input); then the Screen's window and viewer are gone, otto's bot
///   chat is the pane's, its one bubble says the short title, and the stand-in recorded file.attach then prompt.submit
///   with the Mac's params and words (the reviewed installer's size and SHA-256, the exact prompt with its three
///   installer lines, the same runtime). Nothing in either frame is run.
///   bot-screen-setup-sent   The chat right after the send (the request's bubble).
///   bot-screen-setup-send   The chat once the stand-in's synthetic reply came in (the walk's own name); by then the chat
///                           has read its history back, where the request is the whole stored prompt (D26).
internal static partial class ProofWalks
{
    private static void RegisterScreenSetupWalks() =>
        Automation.NamedWalks["bot-screen-setup-send"] = BotScreenSetupSendAsync;   // ScreenSetupWalkProof.Walk

    private static async Task BotScreenSetupSendAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var url = client.Session.Address.ToString();
        if (ScreenSetupWalkProof.Roster(await client.Rpc.RequestAsync("profiles.list", new System.Text.Json.Nodes.JsonObject(), TimeSpan.FromSeconds(15))) is { } r)
            throw new InvalidOperationException(r);
        await ScreenPhaseAsync(url, "setup");
        ScreenWindow? window = null;
        try
        {
            var page = ScreenFeature.Open(ScreenSetupWalkProof.Bot, ScreenSetupWalkProof.BotName)
                ?? throw new InvalidOperationException("the Screen didn't open (no account service, or another one is open)");
            window = ScreenWindow.Showing ?? throw new InvalidOperationException("no Screen window");

            // 1. The setup card, with Set Up with Hermes.
            var setup = await Until(() => page.Last is { FallbackShown: true } s && page.Fallback != null ? s : null, "the setup card", 20);
            if (ScreenWireWalkProof.SetupCard(setup) is { } a) throw new InvalidOperationException(a);
            var card = page.Fallback!.Card;
            if (card.Visibility != Visibility.Visible) throw new InvalidOperationException("setup: the card is hidden");
            if (ScreenSetupWalkProof.Card(card.State.Look) is { } b) throw new InvalidOperationException(b);
            var button = FindIn(window.Content, "screen.setup.primary") ?? throw new InvalidOperationException("setup: Set Up with Hermes isn't showing");
            // [WIN-SCREEN-SETUP-LAYOUT] Where the owner can see it, inside the window and the page, before it is pressed.
            await ButtonInViewAsync(window, button, page.Fallback!);

            // 2. Pressed through the button's own command (its automation peer raises Click: State.SetupAsync). The
            //    stand-in holds its synthetic reply back a little, so the sent shot is the request alone.
            using (var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) })
                (await http.PostAsync(url.TrimEnd('/') + ScreenSetupWalkProof.Plan,
                    new StringContent(ScreenSetupWalkProof.PlanBody(), System.Text.Encoding.UTF8, "application/json"))).EnsureSuccessStatusCode();
            var mark = ScreenSetupWalkProof.Chat(await StandIn(url, ScreenSetupWalkProof.StandIn));
            Invoke(button);
            AppLog.Note("automation", "walk bot-screen-setup-send: Set Up with Hermes invoked");

            // 3. The Screen closes and otto's own chat is the pane's.
            await Until(() => ScreenWindow.Showing == null && Hermes.Core.Screen.ScreenViewerController.Current == null ? page : null, "the Screen closed", 15);
            window = null;
            if (ScreenSetupWalkProof.Closed(ScreenWindow.Showing != null, Hermes.Core.Screen.ScreenViewerController.Current != null) is { } c)
                throw new InvalidOperationException(c);
            var composer = await Until(() => ChatPage.Current is { XamlRoot: not null } chat && ComposerController.For(chat) is { } cc
                && cc.Composer.Session.Profile == ScreenSetupWalkProof.Bot ? cc : null, "otto's chat", 20);
            var pane = ShellPage.Current?.KeyState() ?? throw new InvalidOperationException("the shell isn't showing");
            if (ScreenSetupWalkProof.ChatOpen(pane.Pane, pane.Profile, composer.Composer.Session.Profile) is { } d) throw new InvalidOperationException(d);

            // 4. The installer then the prompt reached the stand-in, as the Mac sends them; the bubble says the short title.
            await UntilWire(url, rec => ScreenSetupWalkProof.Sent(rec, mark), "the setup on the wire");
            var session = composer.Composer.Session;
            await Until(() => ScreenSetupWalkProof.Bubble(session.Messages) == null ? session : null, "the request's bubble");
            AppLog.Note("automation", "walk bot-screen-setup-send: file.attach then prompt.submit reached the stand-in from otto's chat");
            await Task.Delay(400);
            await shot("bot-screen-setup-sent");   // ScreenSetupWalkProof.Shot

            // 5. The stand-in's synthetic reply under it (the chat settled), the walk's own shot.
            await Until(() => !session.Busy && ScreenSetupWalkProof.Replied(session.Messages) ? session : null, "the stand-in's reply", 20);
            await Task.Delay(400);
            await shot("bot-screen-setup-send");   // ScreenSetupWalkProof.FinalShot
        }
        finally
        {
            window?.Close();
            await Task.Delay(300);
            try { await ScreenPhaseAsync(url, "setup"); } catch (Exception e) { AppLog.Note("automation", $"walk bot-screen-setup-send: reset failed ({e.GetType().Name})"); }
        }
    }

    /// [WIN-SCREEN-SETUP-LAYOUT] Set Up with Hermes' bounding rectangle, in the window's content, lies inside the content
    /// (the window's client area) and inside the screenshots page's visible viewport: ScreenSetupWalkProof.InView, given
    /// at least 10 s for the page's layout to settle (the frame fits on SizeChanged).
    private static async Task ButtonInViewAsync(ScreenWindow window, FrameworkElement button, LatestScreenshotsView fallback)
    {
        var until = DateTime.UtcNow.AddSeconds(10);
        string? why;
        while ((why = ButtonInView(window, button, fallback)) != null && DateTime.UtcNow < until) await Task.Delay(100);
        if (why != null) throw new InvalidOperationException(why);
        AppLog.Note("automation", "walk: Set Up with Hermes is inside the Screen window's client area");
    }

    private static string? ButtonInView(ScreenWindow window, FrameworkElement button, LatestScreenshotsView fallback)
    {
        if (window.Content is not FrameworkElement content || content.ActualWidth <= 0) return "layout: the Screen's window has no content";
        var b = button.TransformToVisual(window.Content).TransformBounds(new global::Windows.Foundation.Rect(0, 0, button.ActualWidth, button.ActualHeight));
        var view = fallback.Page;
        var p = view.TransformToVisual(window.Content).TransformBounds(new global::Windows.Foundation.Rect(0, 0, view.ViewportWidth, view.ViewportHeight));
        return ScreenSetupWalkProof.InView(new Hermes.Core.Screen.ScreenRect(b.X, b.Y, b.Width, b.Height),
            new Hermes.Core.Screen.ScreenSize(content.ActualWidth, content.ActualHeight), new Hermes.Core.Screen.ScreenRect(p.X, p.Y, p.Width, p.Height));
    }
}
