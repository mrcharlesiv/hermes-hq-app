using Hermes.Core.Artifacts;

namespace Hermes.Core.Tests;

public class ArtifactGridLayoutTests
{
    // Shipping Mac 1245: gridImagesLayout and gridCardsLayout use the same width for the count and the floored cell.
    [Theory]
    [InlineData(320, 3, 82, 1, 272)]
    [InlineData(659, 3, 195, 1, 611)]
    [InlineData(660, 3, 196, 2, 300)]
    [InlineData(683, 3, 203, 2, 311)]
    [InlineData(684, 4, 150, 2, 312)]
    [InlineData(800, 4, 179, 2, 370)]
    [InlineData(1024, 6, 152, 3, 317)]
    [InlineData(1400, 8, 158, 4, 329)]
    public void FullListMatchesBothMacTracks(double width, int images, double side, int cards, double card)
    {
        var fit = ArtifactGridLayout.Fit(width, width);
        Assert.Equal(new ArtifactGridTrack(images, side), fit.Images);
        Assert.Equal(new ArtifactGridTrack(cards, card), fit.Cards);
    }

    [Theory]
    [InlineData(684, 700, 4, 150, 2, 312)] // stale larger viewport while the list shrinks
    [InlineData(684, 680, 4, 150, 2, 312)] // native took 4: only 4 more belong to the lane
    [InlineData(684, 676, 4, 150, 2, 312)] // native already took exactly 8
    [InlineData(684, 675.75, 3, 203, 2, 311)]
    [InlineData(684, 672, 3, 202, 2, 310)] // native took 12: don't take 8 again
    [InlineData(660, 652, 3, 196, 2, 300)]
    [InlineData(660, 648, 3, 194, 1, 608)]
    public void TrackWidthsFitTheActualViewportAndReserveTheLaneOnce(double full, double viewport, int images,
        double side, int cards, double card)
    {
        var fit = ArtifactGridLayout.Fit(full, viewport);
        Assert.Equal(new ArtifactGridTrack(images, side), fit.Images);
        Assert.Equal(new ArtifactGridTrack(cards, card), fit.Cards);
        foreach (var track in new[] { fit.Images, fit.Cards })
        {
            var end = 20 + track.Columns * track.ItemWidth + 12 * (track.Columns - 1);
            Assert.True(end <= full - 28 && end <= viewport - 20);
        }
    }

    [Theory]
    [InlineData(0, 684)]
    [InlineData(684, 0)]
    [InlineData(0, 0)]
    [InlineData(-1, 684)]
    [InlineData(684, -1)]
    [InlineData(double.NaN, 684)]
    [InlineData(684, double.NaN)]
    [InlineData(double.PositiveInfinity, 684)]
    [InlineData(684, double.PositiveInfinity)]
    public void NoUsableMeasurementDoesNotInventRoomForHiddenCells(double full, double viewport)
    {
        var fit = ArtifactGridLayout.Fit(full, viewport);
        Assert.Equal(new ArtifactGridTrack(3, 0), fit.Images);
        Assert.Equal(new ArtifactGridTrack(1, 0), fit.Cards);
    }

    [Theory]
    [InlineData(48, 0, 0)]
    [InlineData(50, 0, 2)]
    [InlineData(72, 0, 24)]
    [InlineData(75, 1, 27)]
    public void VeryNarrowListsKeepThreeImageSlotsWithoutNegativeSizes(double width, double side, double card)
    {
        var fit = ArtifactGridLayout.Fit(width, width);
        Assert.Equal(new ArtifactGridTrack(3, side), fit.Images);
        Assert.Equal(new ArtifactGridTrack(1, card), fit.Cards);
    }

    [Fact]
    public void ResizingAndReopeningUseCurrentWidthsEvenWhenColumnCountsMatch()
    {
        var wide = ArtifactGridLayout.Fit(684, 684);
        var wider = ArtifactGridLayout.Fit(692, 692);
        Assert.Equal((wide.Images.Columns, wide.Cards.Columns), (wider.Images.Columns, wider.Cards.Columns));
        Assert.Equal((150d, 312d), (wide.Images.ItemWidth, wide.Cards.ItemWidth));
        Assert.Equal((152d, 316d), (wider.Images.ItemWidth, wider.Cards.ItemWidth));

        // Detail opens before the next arrange, then its own narrow list is measured.
        Assert.Equal(ArtifactGridLayout.Fit(400, 400), ArtifactGridLayout.Fit(692, 692, detailListWidth: 400));
        Assert.Equal(new ArtifactGridTrack(1, 644), ArtifactGridLayout.Fit(692, 692, detailListWidth: 692).Cards);
        var beside = ArtifactGridLayout.Fit(400, 388, detailListWidth: 400);
        Assert.Equal(new ArtifactGridTrack(1, 348), beside.Cards);
        Assert.Equal(new ArtifactGridTrack(3, 108), beside.Images);
        Assert.Equal(wide, ArtifactGridLayout.Fit(684, 676)); // closed at a different width and native gutter
        Assert.Equal(beside, ArtifactGridLayout.Fit(400, 388, detailListWidth: 400));
    }
}
