using System.Text.Json.Nodes;
using Hermes.Core.Shell;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Tests;

/// [WIN-36] The checks behind the transcript-extras walk (Services/ProofWalks.Transcript.cs): each answers null for what
/// the Mac shows and names what is wrong otherwise.
public class TranscriptWalkProofTests
{
    private static JsonNode State(string[] sends, string[] reads) =>
        new JsonObject { ["sends"] = new JsonArray([.. sends.Select(s => (JsonNode)s)]), ["linkReads"] = new JsonArray([.. reads.Select(r => (JsonNode)r)]) };

    [Fact]
    public void TheTableFooterCountsBodyRowsAndColumnsAsTheMac()
    {
        // ChatTextViews.swift TableFooterControl.configure: "\(rows) rows · \(columns) columns", singular at one.
        Assert.Equal("3 rows · 7 columns", TableText.FooterCounts(3, 7));
        Assert.Equal("1 row · 1 column", TableText.FooterCounts(1, 1));
        Assert.Equal(("Expand", "Expand table", "chat.table.expand"), (TableText.ExpandWord, TableText.ExpandName, TableText.ExpandId));
        Assert.Equal(("Table", "Copy as Text", "table.sheet"), (TableText.SheetTitle, TableText.CopyTitle, TableText.SheetId));
    }

    [Fact]
    public void TheChipMustShowTheTitleTheStandInServed()
    {
        var read = State([], ["/example.com/releases/2-4", "/example.com/favicon.ico"]);
        Assert.Null(WalkProof.ChipShowsFetched("Link, Release 2.4 notes, example.com", read));
        // Before the read: the address in words.
        var unread = LinkChips.Face(WalkProof.ExtrasLink, new Uri(WalkProof.ExtrasLink), null).AccessibleName;
        Assert.Contains("not \u201CLink, Release 2.4 notes, example.com\u201D", WalkProof.ChipShowsFetched(unread, read));
        // A title the stand-in never served (a stub, a cache) isn't proof.
        Assert.Contains("no read of /example.com/releases/2-4", WalkProof.ChipShowsFetched("Link, Release 2.4 notes, example.com", State([], [])));
    }

    [Fact]
    public void TheOtherExtrasAreNamedInTheMacsWords()
    {
        string[] all = [TimelineNotes.Note(WalkProof.ExtrasModelNote).Text!, CronDeliveries.Header("Hermes", "Morning brief"), "2 files changed", "3 rows · 7 columns"];
        Assert.Null(WalkProof.ExtrasShown(all, "Hermes"));
        var why = WalkProof.ExtrasShown(all[..2], "Hermes");
        Assert.Contains("\u201C2 files changed\u201D", why);
        Assert.Contains("\u201C3 rows · 7 columns\u201D", why);
        Assert.Contains("Model changed to", WalkProof.ExtrasShown(all[1..], "Hermes"));
    }

    [Fact]
    public void TheTableSheetReadsTableWithCopyAsTextAndDone()
    {
        Assert.Null(WalkProof.TableSheetReads("Table", ["Copy as Text", "Done"]));
        Assert.NotNull(WalkProof.TableSheetReads("Table", ["Copy", "Done"]));
        Assert.NotNull(WalkProof.TableSheetReads(null, ["Copy as Text", "Done"]));
    }

    [Fact]
    public void TheStandInsLimitMakesAChooseAModelCard()
    {
        // What composer-gateway.py's EXTRAS_LIMIT makes of the card (ErrorCard.Make, as MessageView draws it).
        var words = ErrorCard.Make("Error code: 429 - usage limit reached for claude-sonnet-5 (fixture)", "Hermes", retry: true);
        Assert.True(words.ChooseModel);
        Assert.False(words.Retry);
        Assert.Null(WalkProof.LimitCardReads(words.Title, ["Choose a Model", "Copy Details"]));
        Assert.NotNull(WalkProof.LimitCardReads(words.Title, ["Try Again", "Copy Details"]));
        Assert.NotNull(WalkProof.LimitCardReads(ErrorCard.Title("Hermes"), ["Choose a Model", "Copy Details"]));
    }

    [Fact]
    public void TheRefusalMakesTheCouldntSendCard()
    {
        Assert.Null(WalkProof.CouldntSendReads("Couldn’t Send", "Your message is still in the box below. The gateway is restarting."));
        Assert.NotNull(WalkProof.CouldntSendReads("Couldn't Send", "Your message is still in the box below. The gateway is restarting."));
        Assert.NotNull(WalkProof.CouldntSendReads("Couldn’t Send", "Your message is still in the box below."));
    }

    [Fact]
    public void ChooseAModelOpensOneModelsSheet()
    {
        Assert.Null(WalkProof.ModelsSheetOpened(["Models"]));
        Assert.NotNull(WalkProof.ModelsSheetOpened([]));
        Assert.NotNull(WalkProof.ModelsSheetOpened(["Table"]));
        Assert.NotNull(WalkProof.ModelsSheetOpened(["Models", "Models"]));
    }

    [Fact]
    public void TheSendsAfterTheMarkAreJudged()
    {
        var state = State(["earlier", WalkProof.ExtrasLimitWords, WalkProof.ExtrasRefused], []);
        Assert.Equal(3, WalkProof.ExtrasSendCount(state));
        Assert.Null(WalkProof.ExtrasSent(state, 1, [WalkProof.ExtrasLimitWords, WalkProof.ExtrasRefused]));
        Assert.NotNull(WalkProof.ExtrasSent(state, 0, [WalkProof.ExtrasLimitWords, WalkProof.ExtrasRefused]));
        Assert.NotNull(WalkProof.ExtrasSent(state, 2, [WalkProof.ExtrasLimitWords, WalkProof.ExtrasRefused]));
    }

    [Fact]
    public void TheWalksLinkReaderOnlyReadsALoopbackStandIn()
    {
        Assert.Throws<ArgumentException>(() => LinkPreviewFetcher.LoopbackStandIn(new Uri("http://192.168.1.5:9750/")));
        Assert.Throws<ArgumentException>(() => LinkPreviewFetcher.LoopbackStandIn(new Uri("https://127.0.0.1:9750/")));
        Assert.NotNull(LinkPreviewFetcher.LoopbackStandIn(new Uri("http://127.0.0.1:9750/")));
        Assert.Equal("http://127.0.0.1:9750/__extras/link/example.com/releases/2-4?x=1",
            LinkPreviewFetcher.StandInRoute(new Uri("http://127.0.0.1:9750/"), new Uri("https://example.com/releases/2-4?x=1")).AbsoluteUri);
    }
}

/// [WIN-36] Found by the walk's comparison: the Mac's timeline note names the model as the switch toast does
/// (TimelineNotes.swift `modelSwitchLabel`'s default `ModelNames.displayModelName`), not by its id.
public class ModelNoteNameTests
{
    [Fact]
    public void TheModelChangeNoteNamesTheModelByDefault()
    {
        var note = TimelineNotes.Note(WalkProof.ExtrasModelNote);
        Assert.Equal($"Model changed to {Hermes.Core.Composer.ModelNames.DisplayModelName("claude-sonnet-5")}", note.Text);
        Assert.NotEqual("Model changed to claude-sonnet-5", note.Text);
        // A caller's own namer still wins.
        Assert.Equal("Model changed to X", TimelineNotes.Note(WalkProof.ExtrasModelNote, displayName: _ => "X").Text);
    }
}
