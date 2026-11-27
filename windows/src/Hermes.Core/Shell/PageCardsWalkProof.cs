using Hermes.Core.Transcripts;

namespace Hermes.Core.Shell;

/// [page-cards] What the page-cards walk (HermesHQ.Windows/Services/ProofWalks.PageCards.cs) checks on the pages stand-in
/// run with `--page-cards` (pages-fixture-gateway.py's s-page-cards: the release page handed over by `::preview`, then
/// again by `MEDIA:` after a change). Each check answers null when right, otherwise the words of what is wrong.
public static class PageCardsWalkProof
{
    public const string Bot = "deploys";
    public const string Session = "s-page-cards";
    public const string Title = "The release page";
    public const string PagePath = "/home/hermes/site/index.html";
    public const string PageName = "index.html";

    /// One card as drawn: its page, folded or not, its height and its two lines.
    public sealed record Card(string Path, bool Folded, double Height, string Name, string Hint, bool Pinned);

    /// The chat's two cards: the earlier folded to its caption ("Updated below"), the newest at its full fixed height
    /// ("Interactive page"), both naming index.html, neither pinned yet.
    public static string? Cards(IReadOnlyList<Card> cards, double fullHeight, double foldedHeight)
    {
        if (cards.Count != 2) return $"{cards.Count} page cards are drawn, not 2";
        var (first, newest) = (cards[0], cards[1]);
        if (cards.Any(c => c.Path != PagePath)) return $"a card shows {cards.First(c => c.Path != PagePath).Path}, not {PagePath}";
        if (!first.Folded) return "the earlier card isn't folded though the page is handed over again below";
        if (newest.Folded) return "the newest card is folded";
        if (Math.Abs(first.Height - foldedHeight) > 0.5) return $"the folded card is {first.Height} tall, not {foldedHeight}";
        if (Math.Abs(newest.Height - fullHeight) > 0.5) return $"the card is {newest.Height} tall, not {fullHeight}";
        var folded = PageCards.Face(PageName, null, folded: true, building: false, pictured: false);
        var open = PageCards.Face(PageName, null, folded: false, building: false, pictured: false);
        if ((first.Name, first.Hint) != (folded.Name, folded.Hint)) return $"the folded card reads {first.Name} / {first.Hint}";
        if ((newest.Name, newest.Hint) != (open.Name, open.Hint)) return $"the card reads {newest.Name} / {newest.Hint}";
        if (cards.Any(c => c.Pinned)) return "a card shows a pin before anything was pinned";
        return null;
    }

    /// [page-cards] How long the walk waits for the newest card's picture: the page's load limit (15 s) and its settle,
    /// with room for the read and the capture.
    public static readonly TimeSpan PictureWait = TimeSpan.FromSeconds(30);

    /// The newest card's picture of the page (PageSnapshots): arrived within `PictureWait`, more than one colour (a page,
    /// not a blank or the waiting shape's flat fill), and the card no taller or shorter than before it came.
    public static string? Pictured(PagePixels? picture, TimeSpan took, double heightBefore, double heightAfter, double fullHeight)
    {
        if (picture == null) return $"no picture of the page arrived in {PictureWait.TotalSeconds:0} s";
        if (took > PictureWait) return $"the picture took {took.TotalSeconds:0.0} s, over {PictureWait.TotalSeconds:0} s";
        if (picture.Width < 8 || picture.Height < 8) return $"the picture is {picture.Width}×{picture.Height} pixels";
        if (picture.Colours() < 2) return "the picture is one colour: a blank page, not the page drawn";
        if (Math.Abs(heightBefore - fullHeight) > 0.5) return $"the card was {heightBefore} tall before its picture, not {fullHeight}";
        if (Math.Abs(heightAfter - heightBefore) > 0.5) return $"the card went from {heightBefore} to {heightAfter} tall when its picture came";
        return null;
    }

    /// The card's right-click menu, in the Mac's order (`pageCardMenu`).
    public static string? MenuReads(IReadOnlyList<string> titles, bool pinned)
    {
        var wanted = PageCards.Menu(canPin: true, pinned).Select(i => i.Title).ToList();
        return titles.SequenceEqual(wanted) ? null : $"the page card's menu reads {string.Join(", ", titles)}, not {string.Join(", ", wanted)}";
    }
}
