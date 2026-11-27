using System.Drawing;
using Hermes.Core.Shell;
using static Hermes.Core.Shell.TaskPillViewportProof.Boundary;

namespace Hermes.Core.Tests;

public class TaskPillViewportTests
{
    // Root coordinates after layout: 16 DIP of rail padding on both ends, 4 above and 8 below.
    private static readonly RectangleF View = new(16, 4, 328, 36), Rail = new(0, 0, 360, 48), Window = new(0, 0, 900, 600);

    [Theory]
    [InlineData(16, 102, true, true)]    // ordinary picked and unpicked pair
    [InlineData(-70, 102, false, true)]  // the picked fill reaches only the left padding
    [InlineData(16, 350, true, false)]   // the unpicked fill reaches only the right padding
    [InlineData(-64, 344, false, false)] // touching the content viewport isn't positive area
    [InlineData(-63, 343, true, true)]   // one DIP of each fill really is visible
    public void BothWitnessesUseTheirPaintInsideTheContentViewport(int pickedX, int otherX, bool pickedVisible, bool otherVisible)
    {
        bool? Visible(int x) => TaskPillViewportProof.InView(new(x, 4, 80, 32),
            [(ContentViewport, View), (ScrollViewer, Rail), (Root, Window)]);
        Assert.Equal(pickedVisible, Visible(pickedX));
        Assert.Equal(otherVisible, Visible(otherX));
    }

    [Fact]
    public void ClipToTheRootAndEveryEnclosingContentViewportInBothDimensions()
    {
        var fill = new RectangleF(40, 8, 80, 32);
        Assert.False(TaskPillViewportProof.InView(fill, [(ContentViewport, View), (ScrollViewer, Rail), (Root, new(120, 0, 200, 100))]));
        Assert.False(TaskPillViewportProof.InView(fill, [(ContentViewport, View), (ScrollViewer, Rail),
            (ContentViewport, new(0, 40, 240, 80)), (ScrollViewer, Window), (Root, Window)]));
        Assert.True(TaskPillViewportProof.InView(fill, [(ContentViewport, View), (ScrollViewer, Rail),
            (ContentViewport, new(0, 39, 240, 80)), (ScrollViewer, Window), (Root, Window)]));
        Assert.False(TaskPillViewportProof.InView(fill, [(ContentViewport, View), (ScrollViewer, new(120, 0, 200, 48)), (Root, Window)]));
    }

    [Fact]
    public void MissingOrAmbiguousViewportCannotCertifyAVisibleFill()
    {
        var fill = new RectangleF(40, 8, 80, 32);
        Assert.Null(TaskPillViewportProof.InView(fill, [(Root, Window)]));
        Assert.Null(TaskPillViewportProof.InView(fill, [(ScrollViewer, Rail), (Root, Window)]));
        Assert.Null(TaskPillViewportProof.InView(fill, [(ContentViewport, View), (Root, Window)]));
        Assert.Null(TaskPillViewportProof.InView(fill, [(ContentViewport, View), (ContentViewport, View), (ScrollViewer, Rail), (Root, Window)]));
        Assert.Null(TaskPillViewportProof.InView(fill, [(ContentViewport, View), (ScrollViewer, Rail), (ScrollViewer, Window), (Root, Window)]));
        Assert.Null(TaskPillViewportProof.InView(fill, [(ContentViewport, View), (ScrollViewer, Rail)]));
        Assert.Null(TaskPillViewportProof.InView(fill, [(ContentViewport, new(16, 4, float.PositiveInfinity, 36)), (ScrollViewer, Rail), (Root, Window)]));
    }
}
