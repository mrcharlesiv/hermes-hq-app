using Hermes.Core.Transcripts;

namespace Hermes.Core.Tests;

// Original UTF-16 spans from ChatFind.nsRanges in the shipping Swift matcher (484cd6acf).
public class ChatFindEmojiModifierTests
{
    [Theory]
    [InlineData("👋")]
    [InlineData("👋🏽")]
    [InlineData(" \t👋🏿\n")]
    public void WaveFindsAllThreeOriginalSlices(string query)
    {
        const string text = "🗂️ cafés: 👋🏽, 👋, 👋🏽";
        var hits = ChatFind.Ranges(query, text);
        Assert.Equal([(11, 4), (17, 2), (21, 4)], hits.Select(r => (r.Start, r.Length)));
        Assert.Equal(["👋🏽", "👋", "👋🏽"], hits.Select(r => text.Substring(r.Start, r.Length)));
    }

    [Theory]
    [InlineData("👋")]
    [InlineData("👋🏻")]
    [InlineData("👋🏼")]
    [InlineData("👋🏽")]
    [InlineData("👋🏾")]
    [InlineData("👋🏿")]
    public void PlainAndAllFiveTonesMatchOneAnother(string query) =>
        Check("🐋é:👋👋🏻👋🏼👋🏽👋🏾👋🏿|👋🏿👋🏾👋🏽👋🏼👋🏻👋", query,
            (4, 2), (6, 4), (10, 4), (14, 4), (18, 4), (22, 4),
            (27, 4), (31, 4), (35, 4), (39, 4), (43, 4), (47, 2));

    [Fact]
    public void TonesCanAttachToOtherTextAndDoNotReplaceCaseOrAccentSearch()
    {
        Check("p\\|🏻q and p|🏻q", "|", (2, 3), (12, 3));
        Check("Q 1🏽 1 1🏽 Z", "1🏻", (2, 3), (6, 1), (8, 3));
        Check("🐳 e\u0301🏻 CAFÉ🏿 cafe\u0301 café CAFE🏽", "  CaFé🏼\n", (8, 6), (15, 5), (21, 4), (26, 6));
        Check("x🏻Y🏿x🏽yxy", "yX", (3, 6), (9, 2));
    }

    [Fact]
    public void AdjacentMatchesAdvanceOverTheEntireOriginalMatch()
    {
        Check("👋🏻👋🏿👋👋🏻", "👋🏿👋🏻", (0, 8), (8, 6));
        Check("👋🏻🏿👋🏿👋", "👋🏻🏿", (0, 6), (6, 4), (10, 2));
        Check("🏺🏻🏽🐀🐿🏿🀀", "🐿", (8, 4)); // supplementary neighbours are not tones
    }

    [Fact]
    public void JoinedEmojiAndFlagsKeepTheirCharacterBoundaries()
    {
        const string people = "🧑🏻‍💻 🧑‍💻 🧑🏿 🧑";
        Check(people, "🧑🏽‍💻", (0, 7), (8, 5));
        Check(people, "🧑🏻", (14, 4), (19, 2));
        Check(people, "💻");
        Check("👩🏻‍💻 👩💻 👩🏻💻 👩‍💻", "👩🏿‍💻", (0, 7), (20, 5));
        // A tone between regional indicators breaks the flag into two Characters.
        Check("🇦🏻🇧 🇦🇧 🇦🇧🏻", "🇦🏿🇧", (0, 6));
        Check("🇦🏻🇧 🇦🇧 🇦🇧🏻", "🇦🇧", (7, 4), (12, 6));
        Check("✌️🏻 ✌🏿️ ✌︎ ✌", "✌️🏿", (0, 4), (5, 4), (10, 2), (13, 1));
    }

    [Fact]
    public void AnUnattachedModifierIsLiteralNotAnEmptyQueryOrAWildcard()
    {
        Check("👋🏻 👋🏿 👋", "🏻");
        Check("🏻", "🏿");
        Check("🏻 👋🏻\n🏻 y", "🏻", (0, 2), (8, 2));
        Check("🏻🏿👋🏻", "🏻🏿👋", (0, 8));
        Check("🏻🏿", "🏻");
        Check("\u0301🏻", "\u0301🏻", (0, 3));
        Check("🏻\u0301", "🏻");
        Check("\n🏻\u0301X \n🏻️X \n🏿X", "🏻\u0301X", (1, 4));
        Check("🏻ffi", "🏻ﬃ", (0, 5));
        Check("x\n🏻ß", "X\n🏻ss", (0, 5));
    }

    [Fact]
    public void FoldingAToneDoesNotEnableUnrelatedEquivalences()
    {
        Check("X|ः🏻", "|"); // U+0903 is not another tone.
        Check("Æe🏻", "aeE\u0301");
        Check("ffi👋🏻", "ﬃ👋🏻", (0, 7)); // already matched before tone folding
        Check("👩🏻👩💻👩‍💻", "👩🏿👩‍💻");
        Check("👩🏻👩🏻👩‍💻", "👩🏿👩‍💻", (4, 9));
        Check("🦋\U000E0100🦋🏻🦋", "🦋\U000E0100🏿", (0, 4), (4, 4), (8, 2));
        Check("🏻\U000E0100", "🏻");
        Check("🏻\U000E0100", "🏻\U000E0100", (0, 4));
    }

    [Fact]
    public void UnpairedCodeUnitsAreNotSkinTones()
    {
        // Ill-formed UTF-16 can reach a managed string; do not consume the stray halves as a modifier.
        Check("\ud83c!\udffd👋🏼👋", "👋🏾", (3, 4), (7, 2));
        Check("\ud83c!\udffd", "👋");
    }

    private static void Check(string text, string query, params (int, int)[] expected) =>
        Assert.Equal(expected, ChatFind.Ranges(query, text).Select(r => (r.Start, r.Length)));
}
