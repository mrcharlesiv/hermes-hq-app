using Hermes.Core.Shell;
using HermesHQ.Features.Artifacts;
using HermesHQ.Features.Transcript;
using HermesHQ.Pages;
using HermesHQ.Shell;
using HermesHQ.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace HermesHQ.Services;

/// [page-cards] The CI's walk for page cards, on the pages stand-in run with `--page-cards` (pages-fixture-gateway.py's
/// “The release page”: index.html handed over by `::preview{file=…}`, then again by `MEDIA:` after a change), backed by
/// the app's state (`Hermes.Core.Shell.PageCardsWalkProof`):
///   page-cards  Both replies draw a page card: the earlier folded to its caption (“Updated below”, 56 tall), the newest
///               at its fixed 316 (“Interactive page”), no pin; the newest card's picture of the page (more than one
///               colour) lands within 30 s and its height stays 316 (shots page-cards, both cards; page-card). Its right-click menu reads Open, Pin as
///               Tile, Share…, Save As…, Copy Path (page-card-menu); Pin as Tile puts the pin on its corner
///               (page-card-pinned) and Unpin takes it off again. A click opens index.html, downloaded from the stand-in,
///               live in a page window of its own (page-card-open), closed after.
/// Clicks go in by SendInput; where they don't arrive, the walk calls what the click calls and says so in the app log.
internal static partial class ProofWalks
{
    private static void RegisterPageCardsWalks()
    {
        Automation.NamedWalks["page-cards"] = PageCardsAsync;
    }

    private static async Task PageCardsAsync(Func<string, Task> shot)
    {
        _ = AppState.Client ?? throw new InvalidOperationException("not signed in");
        Navigator.Go(new ChatDestination(PageCardsWalkProof.Bot, PageCardsWalkProof.Session, PageCardsWalkProof.Title));
        var chat = await Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId == PageCardsWalkProof.Session && p.MessageCount >= 4 ? p : null,
            "The release page's messages");
        var list = await Until(() => Shown(chat).OfType<ListView>().FirstOrDefault(), "the transcript");
        var items = (list.ItemsSource as IEnumerable<object>)?.OfType<MessageItem>().ToList() ?? [];
        list.ScrollIntoView(items[^1], ScrollIntoViewAlignment.Leading);
        await Task.Delay(600);
        var cards = await Until(() => Shown(list).OfType<PageCardView>().ToList() is { Count: >= 2 } c ? c : null, "two page cards", 20);
        await Task.Delay(400);   // laid out at their fixed sizes
        static PageCardsWalkProof.Card Read(PageCardView v) => new(v.PagePath, v.Folded, v.ActualHeight, v.NameShown, v.HintShown, v.PinShown);
        var read = cards.Select(Read).ToList();
        if (PageCardsWalkProof.Cards(read, PageCardView.CardHeight, PageCardView.FoldedCardHeight) is { } wrong) throw new InvalidOperationException(wrong);
        var card = cards.First(c => !c.Folded);
        list.ScrollIntoView(items[^1], ScrollIntoViewAlignment.Leading);
        await Task.Delay(400);
        // The page's picture (PagePictures: drawn off screen in WebView2): it lands within the bounded wait, holds more
        // than one colour, and the card's height doesn't move.
        await Until(() => card.PictureShown != null ? card : null, "the page card's picture", (int)PageCardsWalkProof.PictureWait.TotalSeconds);
        await Task.Delay(400);   // its fade
        if (PageCardsWalkProof.Pictured(card.PictureShown, card.PictureTook ?? TimeSpan.MaxValue,
                card.HeightBeforePicture is > 0 and var heightBefore ? heightBefore : read.First(c => !c.Folded).Height, card.ActualHeight,
                PageCardView.CardHeight) is { } unpictured)
            throw new InvalidOperationException(unpictured);
        AppLog.Note("automation", $"walk page-cards: picture {card.PictureShown!.Width}×{card.PictureShown.Height} px, {card.PictureShown.Colours()} colours, "
            + $"in {card.PictureTook?.TotalSeconds:0.0} s, card {card.ActualHeight} tall");
        // The walk's own picture: the chat's two cards, the earlier folded above the newest with its picture.
        list.ScrollIntoView(items[Math.Max(0, items.Count - 3)], ScrollIntoViewAlignment.Leading);
        await Task.Delay(400);
        await shot("page-cards");
        list.ScrollIntoView(items[^1], ScrollIntoViewAlignment.Leading);
        await Task.Delay(400);
        await shot("page-card");

        // The page's own menu, then Pin as Tile and Unpin through it.
        async Task<List<MenuFlyoutItem>> MenuAsync()
        {
            var flyout = (MenuFlyout)card.ContextFlyout;
            flyout.ShowAt(card);
            await Until(() => flyout.Items.Count > 0 && InPopups().OfType<MenuFlyoutPresenter>().Any() ? flyout : null, "the page card's menu");
            await Task.Delay(300);
            return [.. flyout.Items.OfType<MenuFlyoutItem>()];
        }
        void Choose(MenuFlyoutItem item)
        {
            ((IInvokeProvider)FrameworkElementAutomationPeer.CreatePeerForElement(item)).Invoke();
            ((MenuFlyout)card.ContextFlyout).Hide();
        }
        var menu = await MenuAsync();
        if (PageCardsWalkProof.MenuReads([.. menu.Select(i => i.Text)], pinned: false) is { } menuWrong) throw new InvalidOperationException(menuWrong);
        await shot("page-card-menu");
        Choose(menu.First(i => i.Text == "Pin as Tile"));
        await Until(() => card.PinShown ? card : null, "the pin on the card's corner");
        await shot("page-card-pinned");
        menu = await MenuAsync();
        if (PageCardsWalkProof.MenuReads([.. menu.Select(i => i.Text)], pinned: true) is { } pinnedWrong) throw new InvalidOperationException(pinnedWrong);
        Choose(menu.First(i => i.Text == "Unpin"));
        await Until(() => card.PinShown ? null : card, "the pin gone after Unpin");

        // A click: the page live in its own window.
        var before = ArtifactFileWindow.OpenKeys;
        try { Mouse.Click(card); }
        catch (InvalidOperationException e)
        {
            AppLog.Note("automation", $"walk page-cards: the card wasn't clicked ({e.Message}); opening it");
            _ = card.OpenAsync();
        }
        var key = await Until(() => ArtifactFileWindow.OpenKeys.Except(before).FirstOrDefault(), "the page's window", 30);
        var window = ArtifactFileWindow.Showing(key) ?? throw new InvalidOperationException("the page's window went away");
        await PageDrawnAsync(window, "the page card's window");
        await ShotOfAsync(window, () => shot("page-card-open"));
        window.Close();
        // The walk's own picture (windows.yml fails the run without *-page-cards.png): the chat as it ends, pin gone.
        await Task.Delay(300);
        await shot("page-cards");
    }
}
