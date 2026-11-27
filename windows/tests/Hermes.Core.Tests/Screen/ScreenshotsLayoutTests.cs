// [WIN-SCREEN-SETUP-LAYOUT] The latest-screenshots page's frame rule (Hermes.Core/Screen/ScreenshotsLayout.cs), from the
// constants of 93f984bb1 App/Screen/LatestScreenshotsView.swift: the page's stack 16 in from each side, 8 under the top
// and 24 over the bottom; the frame 16:10 of its width until a picture loads (`multiplier: 10.0 / 16.0`), then the
// picture's own shape kept within 0.3…2.2; the status line at least 14 inside the frame's top and bottom; 12 under the
// frame. CI on Windows has no Swift on disk, so the values are written here.

using Hermes.Core.Screen;
using Layout = Hermes.Core.Screen.ScreenshotsLayout;

namespace Hermes.Core.Tests.Screen;

public sealed class ScreenshotsLayoutTests
{
    [Fact]
    public void TheConstantsAreTheMacs()
    {
        Assert.Equal(10.0 / 16.0, Layout.EmptyAspect);
        Assert.Equal(0.3, Layout.MinAspect);
        Assert.Equal(2.2, Layout.MaxAspect);
        Assert.Equal(14, Layout.StatusInset);
        Assert.Equal(16, Layout.Side);
        Assert.Equal(8, Layout.Top);
        Assert.Equal(24, Layout.Bottom);
        Assert.Equal(12, Layout.FrameGap);
    }

    [Fact]
    public void APicturesShapeIsKeptWithinReason()
    {
        Assert.Equal(400.0 / 640.0, Layout.Aspect(640, 400));
        Assert.Equal(0.3, Layout.Aspect(4000, 100));          // a very wide strip
        Assert.Equal(2.2, Layout.Aspect(400, 4000));          // a very tall page
        Assert.Equal(Layout.EmptyAspect, Layout.Aspect(0, 400));
    }

    [Fact]
    public void WithRoomTheEmptyFrameIsTheMacs16By10()
    {
        // The Mac's pane: a 600 pt wide frame is 375 tall, with room to spare.
        Assert.Equal(375, Layout.FrameHeight(width: 600, aspect: null, room: 1000, statusHeight: 18));
    }

    [Fact]
    public void TheEmptyFrameNeverStretchesPastTheCardsButtons()
    {
        // The Windows CI shot (207): a 1000 × 700 window, the frame 952 wide, 16:10 was 595 tall and pushed Set Up with
        // Hermes below the window. With 230 of room it is 230, so the buttons stay in view.
        var room = Layout.Room(viewport: 605, frameTop: 87, frameToButtons: 264);
        Assert.Equal(230, room);
        Assert.Equal(230, Layout.FrameHeight(952, null, room, statusHeight: 18));
        Assert.True(Layout.FrameHeight(952, null, room, 18) < 952 * Layout.EmptyAspect);
    }

    [Fact]
    public void TheEmptyFrameStillHoldsItsStatusLine()
    {
        // A small window (480 × 360): no room at all; the frame keeps the status line and its 14 above and below, and the
        // page scrolls to the card as the Mac's does.
        Assert.Equal(18 + 28, Layout.FrameHeight(440, null, room: -120, statusHeight: 18));
        Assert.Equal(40 + 28, Layout.FrameHeight(440, null, room: 50, statusHeight: 40));
    }

    [Fact]
    public void APictureKeepsItsOwnShapeAndThePageScrolls()
    {
        // As on the Mac: a loaded screenshot is never squeezed to make room; the card is below it, by scrolling.
        Assert.Equal(952 * 0.625, Layout.FrameHeight(952, aspect: 0.625, room: 100, statusHeight: 18));
        Assert.Equal(400 * 2.2, Layout.FrameHeight(400, aspect: 5, room: 100, statusHeight: 18));
    }

    [Fact]
    public void NoWidthIsNoFrame()
    {
        Assert.Equal(0, Layout.FrameHeight(0, null, 300, 18));
        Assert.Equal(0, Layout.FrameHeight(-5, 0.5, 300, 18));
    }
}
