using Hermes.Core.Attachments;
using Hermes.Core.Model;
using Hermes.Core.Shell;
using Hermes.Core.Transcripts;
using Xunit;

namespace Hermes.Core.Tests;

// [page-cards] [page-fold] An HTML page a bot hands over alone on its line draws as a page card (App/Chat/Cells/
// PageCardView.swift, App/Chat/Viewer/PageOrder.swift, MarkdownRenderer's BlockBuilder and ChatViewController+Pins'
// pageCardMenu at 93f984bb1). Synthetic paths only.

public class PageCardsTests
{
    private static List<string> Shape(IReadOnlyList<ReplySegment> segments) =>
        [.. segments.Select(s => s switch
        {
            PageSegment p => "page:" + p.Path + "|" + p.Name,
            WordsSegment w => "words:" + w.Markdown,
            _ => "?",
        })];

    [Fact]
    public void SizesAreTheMacs()
    {
        Assert.Equal(260, PageCards.PictureHeight);
        Assert.Equal(480, PageCards.Widest);
        Assert.Equal(12, PageCards.PadH);
        Assert.Equal(9, PageCards.PadV);
        // pictureHeight + padV + body line + 2 + time line + padV; folded: the caption alone.
        Assert.Equal(260 + 9 + 21 + 2 + 15 + 9, PageCards.Height(21, 15));
        Assert.Equal(9 + 21 + 2 + 15 + 9, PageCards.FoldedHeight(21, 15));
        Assert.Equal(480, PageCards.Width(760));
        Assert.Equal(300, PageCards.Width(300));
    }

    [Fact]
    public void OnlyHtmlPagesOpenAsPages()
    {
        Assert.True(PageCards.Opens("/home/me/site/index.html"));
        Assert.True(PageCards.Opens("chart.HTM"));
        Assert.False(PageCards.Opens("/home/me/report.pdf"));
        Assert.False(PageCards.Opens("/home/me/index.html.md"));
    }

    [Fact]
    public void APageAloneOnItsLineIsACardInItsPlace()
    {
        var text = "Here is the chart.\n\n::preview{file=\"/home/me/out/followups.html\"}\n\nTell me what to change.";
        Assert.Equal(
            ["words:Here is the chart.", "page:/home/me/out/followups.html|followups.html", "words:Tell me what to change."],
            Shape(PageCards.Split(text)));
        Assert.Equal(["page:/home/me/site/index.html|index.html"], Shape(PageCards.Split("MEDIA:/home/me/site/index.html")));
        Assert.Equal(["page:/home/me/a b/page.html|page.html"], Shape(PageCards.Split("MEDIA:\"/home/me/a b/page.html\"")));
        // Two pages one line after the other: a card each.
        Assert.Equal(["page:/a/one.html|one.html", "page:/a/two.html|two.html"],
            Shape(PageCards.Split("MEDIA:/a/one.html\nMEDIA:/a/two.html")));
    }

    [Fact]
    public void APageInsideASentenceListQuoteOrCodeStaysWords()
    {
        foreach (var text in new[]
                 {
                     "Open MEDIA:/a/one.html when you can.",
                     "- MEDIA:/a/one.html",
                     "> ::preview{file=\"/a/one.html\"}",
                     "```\nMEDIA:/a/one.html\n```",
                     "MEDIA:/a/report.pdf",
                     "    MEDIA:/a/one.html",
                     "~~~\n::preview{file=\"/a/one.html\"}\n~~~",
                 })
            Assert.Equal(["words:" + text], Shape(PageCards.Split(text)));
        // Alone on its line is the rule (as AttachmentHydration.ReplyParts lifts a lone MEDIA: line): the words around it
        // stay words, before and after the card.
        Assert.Equal(["words:Done:", "page:/a/one.html|one.html", "words:and a word after it"],
            Shape(PageCards.Split("Done:\nMEDIA:/a/one.html\nand a word after it")));
    }

    [Fact]
    public void PathsAreThePagesHandedOverAloneOnALine()
    {
        var text = "::preview{file=\"/a/one.html\"}\nMEDIA:`/a/two.htm`\n/a/three.html\n`~/four.html`\nsee /a/five.html too\nMEDIA:/a/one.html";
        Assert.Equal(["/a/one.html", "/a/two.htm", "/a/three.html", "~/four.html"], PageCards.Paths(text));
        Assert.Empty(PageCards.Paths("No pages here."));
    }

    private static ChatMessage Msg(string id, Role role, string text) => new(id, role, [new TextPart(text)]);

    [Fact]
    public void AnEarlierCardFoldsWhenALaterReplyHandsTheSamePageOverAgain()
    {
        var messages = new[]
        {
            Msg("u1", Role.User, "Make a chart."),
            Msg("a1", Role.Assistant, "::preview{file=\"/a/chart.html\"}\n\nMEDIA:/a/other.html"),
            Msg("u2", Role.User, "Make it blue. MEDIA:/a/chart.html"),
            Msg("a2", Role.Assistant, "Done.\n\nMEDIA:/a/chart.html"),
        };
        var latest = PageCards.Latest(messages);
        Assert.Equal("a2", latest["/a/chart.html"]);
        Assert.Equal("a1", latest["/a/other.html"]);
        Assert.Equal(["/a/chart.html"], PageCards.UpdatedBelow(messages[1].Text, "a1", latest));
        Assert.Empty(PageCards.UpdatedBelow(messages[3].Text, "a2", latest));
        // Your own words never fold a card.
        Assert.False(latest.ContainsKey("nothing"));
        Assert.Empty(PageCards.UpdatedBelow("MEDIA:/a/chart.html", "a1", new Dictionary<string, string>()));
    }

    [Fact]
    public void TheCaptionSaysWhatTheMacSays()
    {
        var plain = PageCards.Face("followups.html", null, folded: false, building: false, pictured: false);
        Assert.Equal(("followups.html", "Interactive page", "Page, followups.html"), (plain.Name, plain.Hint, plain.AccessibleName));
        var named = PageCards.Face("followups.html", "Replies per 100 follow-ups", folded: false, building: false, pictured: true);
        Assert.Equal(("Replies per 100 follow-ups", "Interactive page · followups.html", "Page, Replies per 100 follow-ups, followups.html"),
            (named.Name, named.Hint, named.AccessibleName));
        var folded = PageCards.Face("followups.html", "Replies per 100 follow-ups", folded: true, building: false, pictured: false);
        Assert.Equal(("Replies per 100 follow-ups", "Updated below", "Page, Replies per 100 follow-ups, followups.html, updated below"),
            (folded.Name, folded.Hint, folded.AccessibleName));
        var building = PageCards.Face("followups.html", null, folded: false, building: true, pictured: false);
        Assert.Equal("Building page…", building.Hint);
        Assert.Equal("Interactive page", PageCards.Face("followups.html", null, false, building: true, pictured: true).Hint);
        // A title that is only the file's name says nothing new.
        Assert.Equal("Interactive page", PageCards.Face("index.html", "INDEX.HTML", false, false, false).Hint);
        Assert.Equal("Opens the page", PageCards.AccessibleHint);
        Assert.Equal("chat.page-card", PageCards.AutomationId);
    }

    [Fact]
    public void TheMenuIsThePagesOwnInTheMacsOrder()
    {
        Assert.Equal(["Open", "Pin as Tile", "Share…", "Save As…", "Copy Path"],
            PageCards.Menu(canPin: true, pinned: false).Select(i => i.Title));
        Assert.Equal(["Open", "Unpin", "Share…", "Save As…", "Copy Path"],
            PageCards.Menu(canPin: true, pinned: true).Select(i => i.Title));
        Assert.Equal(["Open", "Share…", "Save As…", "Copy Path"], PageCards.Menu(canPin: false, pinned: false).Select(i => i.Title));
        Assert.Equal(["page.open", "page.pin", "page.share", "page.save", "page.copy-path"],
            PageCards.Menu(canPin: true, pinned: false).Select(i => i.Id));
    }

    [Fact]
    public void AReplysLonePageLineStaysInItsWordsToDrawAsACard()
    {
        // History lifts a lone MEDIA: file into a file row; a page stays in place, where the words draw it as a card.
        var parts = AttachmentHydration.ReplyParts("Here it is:\n\nMEDIA:/a/chart.html\nMEDIA:/a/report.pdf");
        Assert.Equal("Here it is:\n\nMEDIA:/a/chart.html", Assert.IsType<TextPart>(parts[0]).Text);
        Assert.Equal("report.pdf", Assert.IsType<AttachmentPart>(Assert.Single(parts.Skip(1))).Attachment.Name);
        Assert.IsType<TextPart>(Assert.Single(AttachmentHydration.ReplyParts("MEDIA:/a/chart.html")));
    }
}

public class PageCardsWalkProofTests
{
    private static PageCardsWalkProof.Card C(bool folded, double h, string name, string hint, bool pinned = false) =>
        new(PageCardsWalkProof.PagePath, folded, h, name, hint, pinned);

    [Fact]
    public void TheWalkWantsTheFoldedCardThenTheFullOne()
    {
        const double full = 316, fold = 56;
        var good = new[] { C(true, fold, "index.html", "Updated below"), C(false, full, "index.html", "Interactive page") };
        Assert.Null(PageCardsWalkProof.Cards(good, full, fold));
        Assert.Contains("isn't folded", PageCardsWalkProof.Cards([good[1], good[1]], full, fold));
        Assert.Contains("1 page cards", PageCardsWalkProof.Cards([good[1]], full, fold));
        Assert.Contains("tall", PageCardsWalkProof.Cards([good[0], good[1] with { Height = 300 }], full, fold));
        Assert.Contains("pin", PageCardsWalkProof.Cards([good[0], good[1] with { Pinned = true }], full, fold));
        Assert.Null(PageCardsWalkProof.MenuReads(["Open", "Pin as Tile", "Share…", "Save As…", "Copy Path"], pinned: false));
        Assert.NotNull(PageCardsWalkProof.MenuReads(["Open", "Share…", "Copy Path"], pinned: false));
    }

    private static string Repo(params string[] parts)
    {
        var dir = AppContext.BaseDirectory;
        while (dir != null && !File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir);
        return Path.Combine([dir ?? throw new InvalidOperationException("no windows/ folder"), .. parts]);
    }

    private static string Source(params string[] parts) => File.ReadAllText(Repo(parts)).Replace("\r\n", "\n");

    [Fact]
    public void AReplysWordsDrawTheirPageCardsAndTheStandInHandsAPageOverTwice()
    {
        var view = Source("src", "HermesHQ.Windows", "Controls", "MessageView.cs");
        Assert.Contains("page: (item.Owner, m.Id));   // [page-cards]", view);
        var words = Source("src", "HermesHQ.Windows", "Features", "Transcript", "LinkChipView.cs");
        Assert.Contains("new PageCardView(card, chat.Owner, chat.MessageId, building: !settled)", words);
        var card = Source("src", "HermesHQ.Windows", "Features", "Transcript", "PageCardView.cs");
        Assert.Contains("PageCards.Width(available.Width), _folded ? FoldedCardHeight : CardHeight", card);
        Assert.Contains("PageCards.Menu(canPin, Pinned)", card);
        // The rule is drawn over the caption's top (the Mac's rule.frame at y = pictureHeight), taking no row of its own,
        // so the caption keeps its whole height and the hint's descenders aren't cut (CI run 45084955836, 197-page-card).
        Assert.Contains("SetRow(_rule, 2);", card);
        Assert.DoesNotContain("new GridLength(folded ? 0 : 1)", card);
        var walks = Source("src", "HermesHQ.Windows", "Services", "ProofWalks.cs");
        Assert.Contains("RegisterPageCardsWalks();", walks);
        var fixture = Source("ci", "fixtures", "pages-fixture-gateway.py");
        Assert.Contains("parser.add_argument('--page-cards'", fixture);
        Assert.Contains("add_session('s-page-cards', 'deploys', 'The release page'", fixture);
        Assert.Contains("::preview{{file=\"{HOME}/site/index.html\"}}", fixture);
        Assert.Contains("MEDIA:{HOME}/site/index.html", fixture);
    }
}
