using Hermes.Core.Transcripts;

namespace Hermes.Core.Tests;

public class ChatFindLayoutTests
{
    // Mac ChatFindBar.wantsStacked(width:): outer width minus its measured content insets.
    [Theory]
    [InlineData(800, 1, false, false)]
    [InlineData(220, 1, false, true)]
    [InlineData(0, 1, false, false)]
    [InlineData(0, 1, true, true)]
    [InlineData(800, 1.5, false, true)]
    [InlineData(220, 2.25, false, true)]
    [InlineData(0, 1.5, false, true)]
    [InlineData(800, 1, true, false)]
    public void WidthAndAccessibilityAsOnTheShippingMac(double outer, double scale, bool previous, bool stacked) =>
        Assert.Equal(stacked, ChatFindLayout.Stacked(Math.Max(0, outer - 22), 79.2, 0, 44, scale, previous));

    [Fact]
    public void EqualityLeavesTheMinimumReadableFieldAndAChangeInControlMetricsIsRespected()
    {
        // 88 field + 4 gap + ceil(79.2) count + 10 gap + two 44 arrows + 4 gap + 44 Done.
        Assert.False(ChatFindLayout.Stacked(318, 79.2, 0, 44, 1, true));
        Assert.True(ChatFindLayout.Stacked(317.9, 79.2, 0, 44, 1, false));
        Assert.True(ChatFindLayout.Stacked(318, 80.5, 0, 44, 1, false));
        Assert.True(ChatFindLayout.Stacked(318, 79.2, 0, 46, 1, false));
    }

    [Theory]
    [InlineData(100.84375, 43.21875, 115.25)] // Courier New: reserve, 2 of 2, 100000 of 100000
    [InlineData(101, 44, 116)]                // the same advances rounded to whole DIP
    public void EditableRoomSurvivesCountAndWidthChanges(double reserve, double shortCount, double longCount)
    {
        const double left = 25, right = 6, delete = 30, done = 44;
        bool stacked = false;
        void Check(double inner, double live, bool expectStacked, double scale = 1)
        {
            stacked = ChatFindLayout.Stacked(inner - left - right - delete, reserve, live, done, scale, stacked);
            Assert.Equal(expectStacked, stacked);
            // The Auto column takes the live label (not the reserve) and its controls.
            double field = stacked ? inner : inner - (4 + live + 10 + 44 + 44 + 4 + done);
            foreach (var clear in new[] { delete, 0 })
                Assert.True(field - left - right - clear >= 88, "Too little room inside the native edit");
        }
        Check(405, shortCount, false);
        Check(405, longCount, true);  // only the count changed
        Check(420, longCount, false);
        Check(414.875, longCount, true);
        Check(415, longCount, false);
        Check(405, longCount, true);
        Check(405, shortCount, false);
        Check(399.875, shortCount, true); // a short count must not discard the stable reserve
        Check(400, shortCount, false);
        Check(800, shortCount, true, 1.5);
    }

    [Fact]
    public void InsetFollowsTheWholeDrawnBarNotAccumulatedHeightOrThePreviousOpening()
    {
        const double baseTop = 13;
        Assert.Equal(69, ChatFindLayout.TranscriptTop(baseTop, true, 0));      // first layout: Mac's 48+8
        Assert.Equal(69, ChatFindLayout.TranscriptTop(baseTop, true, 48));
        Assert.Equal(111, ChatFindLayout.TranscriptTop(baseTop, true, 90));   // controls moved below the field
        Assert.Equal(143, ChatFindLayout.TranscriptTop(baseTop, true, 122));  // Earlier added beneath them
        Assert.Equal(111, ChatFindLayout.TranscriptTop(baseTop, true, 90));
        Assert.Equal(13, ChatFindLayout.TranscriptTop(baseTop, false, 90));
        Assert.Equal(63, ChatFindLayout.TranscriptTop(7, true, 0));          // new host padding on reopen
    }
}
