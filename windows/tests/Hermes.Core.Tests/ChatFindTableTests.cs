using Hermes.Core.Model;
using Hermes.Core.Transcripts;
using Hermes.Core.Voice;

namespace Hermes.Core.Tests;

// ChatTranscript.readableText(linkAddresses: false) and SpeechText.tables in Mac build 1240.
public class ChatFindTableTests
{
    [Theory]
    [InlineData("| Place | Value |\n| --- | :---: |\n| East | 17 |", "Place\tValue\nEast\t17")]
    [InlineData("> | Food | Note |\n> | --- | ---: |\n> | Tea | sun\\|rise |", "Food\tNote\nTea\tsun|rise")]
    [InlineData("**A** | [B](https://example.com)\n--- | ---\n`C` | **D**", "A\tB\nC\tD")]
    [InlineData("| A |\r\n| :--- |\r\n| Water |", "A\nWater")]
    [InlineData("| Place | Walk |\n| --- | --- |\n| Café | ☕ |", "Place\tWalk\nCafé\t☕")]
    [InlineData("   > > A | B\n> > :--- | ---\n> > C | D | E\n> outside | row", "A\tB\nC\tD\tE\noutside | row")]
    [InlineData("A | B\n--- | ---\nx\\\\|y | z\\|end", "A\tB\nx\\\\\ty\tz|end")]
    [InlineData("| | B |\n| --- | --- |\n| C | |\n", "\tB\nC\t\n")]
    [InlineData("|\n| --- |\n| water |", "\nwater")]
    [InlineData("A \u0600\\| B\n--- | ---\nC | D", "A \u0600\\\tB\nC\tD")]
    [InlineData(">\u0301 A | B\n--- | ---\nC | D", "\u0301 A\tB\nC\tD")]
    [InlineData("    \u0301A | B\n--- | ---\nC | D", "\u0301A\tB\nC\tD")]
    [InlineData("A | B\n| ---\u2028 | --- |\nC | D", "A\tB\nC\tD")]
    [InlineData("| A\v | B |\n| --- | --- |\n| x|\u0301y | z |", "A\v\tB\nx|\u0301y\tz")]
    public void RecognizedRowsKeepTheirCellsInOrder(string markdown, string expected)
    {
        Assert.Equal(expected, Assert.Single(ChatFind.Units([Reply(markdown)])).Text);
    }

    [Theory]
    [InlineData("```text\n| **A** | B |\n| --- | --- |\n| X\\|Y | `Z` |\n```", "| **A** | B |\n| --- | --- |\n| X\\|Y | `Z` |")]
    [InlineData("~~~\nA | B\n--- | ---", "A | B\n--- | ---")]
    [InlineData("ordinary \\| words\nnot a table | here", "ordinary \\| words\nnot a table | here")]
    [InlineData("A | B\n| --- | --- | --- |\nnot a table", "A | B\n| --- | --- | --- |\nnot a table")]
    [InlineData("A | B\n--- | --", "A | B\n--- | --")]
    [InlineData("A |\n--- |", "A |\n--- |")]
    [InlineData("> A | B\n--- | ---", "A | B\n--- | ---")]
    [InlineData("    A | B\n--- | ---", "    A | B\n--- | ---")]
    [InlineData("A | B\n\t--- | ---", "A | B\n\t--- | ---")]
    [InlineData("A | B\n|\v---\v| --- |\nC | D", "A | B\n|\v---\v| --- |\nC | D")]
    public void FencesAndNonTablesKeepTheirLiteralPipesAndDashes(string markdown, string expected)
    {
        Assert.Equal(expected, Assert.Single(ChatFind.Units([Reply(markdown)])).Text);
    }

    [Fact]
    public void FindCountsCellWordsAndLiteralPipesWhileSpeechKeepsOnlyHeaders()
    {
        const string markdown = "> | Café | Sun\\|rise |\n> | --- | :---: |\n> | café | sun\\|rise |";
        var units = ChatFind.Units([Reply(markdown)]);
        Assert.Empty(ChatFind.Matches("---", units));
        Assert.Equal(2, ChatFind.Matches("|", units).Count);
        Assert.Equal(2, ChatFind.Matches("sun|rise", units).Count);
        Assert.Equal([0, 1], ChatFind.Matches("cafe", units).Select(match => match.Occurrence));
        Assert.Equal("Café, Sun rise.", SpeechText.SummarizeTables(markdown));
    }

    [Fact]
    public void DashesTypedByTheUserOrWrittenInABodyCellStillMatch()
    {
        const string markdown = "| Item | Value |\r| --- | --- |\r| Dash | --- |";
        var typed = new ChatMessage("typed", Role.User, [new TextPart(markdown)]);
        Assert.Equal([("typed", 0), ("typed", 1), ("typed", 2), ("reply", 0)],
            ChatFind.Matches("---", new[] { typed, Reply(markdown) }).Select(m => (m.MessageId, m.Occurrence)));
    }

    [Theory]
    [InlineData("\u00A0")]
    [InlineData("\u2009")]
    [InlineData("\u202F")]
    [InlineData("\u200B")]
    public void HorizontalCellPaddingIsNotSearchableOrSpoken(string pad)
    {
        var markdown = $"|{pad}Key{pad}| Value |\n|{pad}---{pad}| :---: |\n| Café | sun\\|rise |";
        var units = ChatFind.Units([Reply(markdown)]);
        Assert.Equal("Key\tValue\nCafé\tsun|rise", Assert.Single(units).Text);
        Assert.Empty(ChatFind.Matches("---", units));
        Assert.Single(ChatFind.Matches("sun|rise", units));
        Assert.Equal("Key, Value.", SpeechText.SummarizeTables(markdown));
    }

    [Theory]
    [InlineData("|\u0301", 3)]
    [InlineData("|\uFE0F", 3)]
    [InlineData("\u0600|", 2)]
    public void ACompositePipeIsNotAColumnSeparator(string pipe, int literalPipeMatches)
    {
        var markdown = $"A {pipe} B\n--- | ---\nC | D";
        var units = ChatFind.Units([Reply(markdown)]);
        Assert.Equal(markdown, Assert.Single(units).Text);
        Assert.Equal(2, ChatFind.Matches("---", units).Count);
        Assert.Equal(literalPipeMatches, ChatFind.Matches("|", units).Count);
        Assert.Equal(markdown, SpeechText.SummarizeTables(markdown));
    }

    [Theory]
    [InlineData("\u0301", true)]    // combining acute
    [InlineData("\U000E0100", true)] // supplementary variation selector
    [InlineData("\u09BE", true)]    // Bengali vowel sign AA extends the preceding character
    [InlineData("\u0903", false)]   // a spacing mark, not an extender
    [InlineData("\u200D", false)]   // zero-width joiner
    public void EscapedCellPipesHaveTheSameBoundaryForFindAndSpeech(string suffix, bool keepEscape)
    {
        var markdown = $"| A\\|{suffix}Z | B |\n| --- | --- |\n| x\\|y | z |";
        Assert.Equal("A" + (keepEscape ? @"\|" : "|") + suffix + "Z\tB\nx|y\tz",
            Assert.Single(ChatFind.Units([Reply(markdown)])).Text);
        Assert.Equal("A" + (keepEscape ? @"\|" : " ") + suffix + "Z, B.", SpeechText.SummarizeTables(markdown));
    }

    private static ChatMessage Reply(string markdown) => new("reply", Role.Assistant, [new TextPart(markdown)]);
}
