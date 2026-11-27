using HermesHQ.Services;
using static HermesHQ.Services.FindPaneEvidence;

namespace Hermes.Core.Tests;

// Deliberately constructed good/bad readings for the walk's judge. These are not Windows frames.
public class FindPaneProofTests
{
    private static string WalkSource()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !File.Exists(Path.Combine(dir.FullName, "HermesHQ.sln"))) dir = dir.Parent;
        return File.ReadAllText(Path.Combine(dir!.FullName, "src", "HermesHQ.Windows", "Services", "ProofWalks.FindReflow.cs")).ReplaceLineEndings("\n");
    }

    [Fact]
    public void TheWalkNeverMakesTheBarOrTranscriptProduceTheRequestedWidth()
    {
        var walk = WalkSource();
        Assert.DoesNotMatch(@"\b(bar|transcript|field)\.(MaxWidth|Width|MinWidth)\s*=", walk);
        Assert.Matches(@"\bpane\.MaxWidth\s*=", walk);
        Assert.Contains("new(pane.ActualWidth, transcript.ActualWidth, bar.ActualWidth)", walk);
        Assert.Contains("Widths.Narrow(bar.Margin.Left, bar.Margin.Right)", walk);
        Assert.Contains("TransformToVisual(pane)", walk);
        Assert.Contains("(object?)pane.GetBindingExpression(dp) ?? pane.ReadLocalValue(dp)", walk);
        Assert.Contains("pane.ClearValue(dp)", walk);
        Assert.DoesNotContain("SetBinding(", walk);
    }

    [Fact]
    public void OnlyTheActualChatColumnOrGroupRootCanBeBorrowed()
    {
        var walk = WalkSource();
        foreach (var check in new[] { "VisualTreeHelper.GetParent(transcript) is not Grid pane", "VisualTreeHelper.GetParent(bar), pane",
                 "InCell(transcript, 1)", "InCell(bar, 1)", "Grid.GetColumn(e) == 0", "Grid.GetColumnSpan(e) == 1", "Grid.GetRowSpan(e) == 1",
                 "chat.FindName(\"Messages\"), transcript", "VisualTreeHelper.GetParent(pane), outer", "InCell(pane, 0)",
                 "room.Content, pane", "page.XamlRoot, root", "FindIn(bar, \"chatfind.field\"), field" })
            Assert.Contains(check, walk);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task TheTemporaryLimitIsRemovedAndRestorationMeasuredEvenIfCaptureThrows(bool fail)
    {
        object unset = new(), local = unset;
        var steps = new List<string>();
        var limit = new FindPaneLimit(unset, () => local, w => { steps.Add("limit"); local = w; }, () => { steps.Add("clear"); local = unset; });
        var run = limit.UseAsync(252, async () =>
        {
            await Task.Yield();
            Assert.Equal(252d, local);
            steps.Add("capture");
            if (fail) throw new IOException("test capture failed");
        }, () => { Assert.Same(unset, local); steps.Add("restored"); return Task.CompletedTask; });
        if (fail) await Assert.ThrowsAsync<IOException>(() => run); else await run;
        Assert.Equal(["limit", "capture", "clear", "restored"], steps);
    }

    [Theory]
    [InlineData("bound")]
    [InlineData("literal")]
    [InlineData("rebound during capture")]
    [InlineData("replaced during capture")]
    public async Task AnExistingOrNewOwnerIsNeverOverwrittenOrCleared(string scenario)
    {
        object unset = new(), binding = new();
        object owner = scenario is "bound" or "rebound during capture" ? binding : 405d;
        var changesLater = scenario.Contains("during capture");
        object local = changesLater ? unset : owner;
        var writes = 0;
        var limit = new FindPaneLimit(unset, () => local, w => { writes++; local = w; }, () => Assert.Fail("another owner's value was cleared"));
        await Assert.ThrowsAsync<InvalidOperationException>(() => limit.UseAsync(252, async () =>
        {
            await Task.Yield();
            Assert.True(changesLater);
            local = owner;
        }, () => throw new Exception("must not claim a restoration")));
        Assert.Same(owner, local);
        Assert.Equal(changesLater ? 1 : 0, writes);
    }

    [Fact]
    public async Task ClearingWithoutActualWidthRecoveryIsNotSuccess()
    {
        object unset = new(), local = unset;
        var limit = new FindPaneLimit(unset, () => local, w => local = w, () => local = unset);
        await Assert.ThrowsAsync<TimeoutException>(() => limit.UseAsync(252, () => Task.CompletedTask,
            () => throw new TimeoutException("test transcript is still narrow")));
        Assert.Same(unset, local);
    }

    [Fact]
    public void TheTwoNamedCapturesPrecedeARealNarrowCloseAndWideReopen()
    {
        var walk = WalkSource();
        var from = 0;
        foreach (var step in new[] { "Check(\"wide\", wide", "Check(\"narrow\", narrow", "shot(tag + \"-narrow\")", "Check(\"expanded\", wide",
                 "shot(tag + \"-expanded\")", "Check(\"before-close\", narrow", "finder.Close();", "finder.Open();", "field.SelectedText = query;",
                 "WaitForWidths(\"reopened\", wide)", "Check(\"reopened\", wide" })
        {
            var next = walk.IndexOf(step, from, StringComparison.Ordinal);
            Assert.True(next >= from, "missing or out of order: " + step);
            from = next + step.Length;
        }
        Assert.Contains("field.LostFocus += FocusLeft", walk);
        Assert.Contains("field.SelectionChanged += SelectionMoved", walk);
        Assert.Contains("TextScaleWalkProof.Scale(actualScale)", walk);
        Assert.DoesNotContain(".Focus(FocusState", walk);
    }

    [Theory]
    [InlineData(16, 16, 252)]
    [InlineData(9, 23, 252)]
    [InlineData(20, 24, 264)]
    public void TheNarrowTargetIncludesBothRealInsets(double left, double right, double expectedPane)
    {
        Assert.Equal(new Widths(expectedPane, expectedPane, 220), Widths.Narrow(left, right));
    }

    [Fact]
    public void ABarOnlyResizeAndEachPartiallyRestoredOrStaleReopenedWidthFail()
    {
        var narrow = Widths.Narrow(16, 16);
        var wide = new Widths(720, 720, 688);
        Assert.True(wide.WiderThan(narrow));
        Assert.False((wide with { Bar = 220 }).Matches(narrow));       // previous walk
        Assert.False((narrow with { Transcript = 720 }).Matches(narrow));
        Assert.False((narrow with { Pane = 720 }).Matches(narrow));
        Assert.False((wide with { Transcript = 252 }).Matches(wide));
        Assert.False((wide with { Pane = 252 }).Matches(wide));
        var stale = wide with { Bar = 220 };
        Assert.True(stale.SamePane(wide));   // restoring while closed: no bar to measure yet
        Assert.False(stale.Matches(wide));   // reopened: the last narrow width is not evidence
        Assert.False(wide.WiderThan(narrow with { Pane = wide.Pane }));
        Assert.False(wide.WiderThan(narrow with { Transcript = wide.Transcript }));
        Assert.True(new Widths(252.3, 251.8, 219.7).Matches(narrow));
        Assert.False((wide with { Pane = double.NaN }).Matches(wide));
    }

    // Actual judge inputs are TransformToVisual(pane) bounds. Offset the transcript below a header;
    // a bar-local rectangle or an element whose exit edge is fine but whose origin is clipped must fail.
    private static FindPaneEvidence Frame(double paneWidth = 252, bool stacked = true, bool earlier = false)
    {
        var width = Math.Min(900, paneWidth - 32);
        var x = (paneWidth - width) / 2;
        var h = (stacked ? 90 : 48) + (earlier ? 32 : 0);
        var bar = new Box(x, 66, width, h);
        var cy = stacked ? 112 : 70;
        var cx = bar.Right - 8 - 168;
        return new(new(0, 0, paneWidth, 640), new(0, 60, paneWidth, 500), bar,
            new(x + 14, 70, stacked ? width - 22 : cx - (x + 14) - 4, 36),
            [new(cx, cy + 6, 31, 22), new(cx + 36, cy, 44, 40), new(cx + 80, cy, 44, 40), new(cx + 128, cy, 40, 40)],
            earlier ? new Box(x + 14, bar.Bottom - 30, width - 22, 26) : null);
    }

    private static string? Judge(FindPaneEvidence frame, bool stacked = true, double? inset = null) =>
        frame.Problem(stacked, 16, 6, 16, 900, 12, 12 + (inset ?? frame.Bar.Height + 8));

    [Fact]
    public void ACorrectPaddingDeltaMustAlsoClearThePhysicalBar()
    {
        var f = Frame();
        f = f with { Bar = f.Bar with { Y = f.Transcript.Y + 30 } };
        Assert.Contains("inset", f.Problem(true, 16, 30, 16, 900, 0, f.Bar.Height + 8));
    }

    [Fact]
    public void ABarAtItsOwnMaxWidthStillBelongsToTheCentredColumn()
    {
        var f = Frame(1100, stacked: false);
        f = f with { Bar = f.Bar with { X = f.Bar.X - 10 } };
        Assert.Contains("bar", Judge(f, stacked: false)); // both margins still fit, but the centre is wrong
    }

    [Theory]
    [InlineData(252, true, true)]
    [InlineData(252, true, false)]
    [InlineData(720, false, true)]
    [InlineData(720, true, true)]    // stacked even when wide on the genuine large-text walk
    [InlineData(1100, false, false)] // the feature's unmodified 900-DIP cap, not a forced full-width child
    public void DrawnRowsFitTheirPaneAndInset(double width, bool stacked, bool earlier) =>
        Assert.Null(Judge(Frame(width, stacked, earlier), stacked));

    [Theory]
    [InlineData("wide-transcript", "transcript")]
    [InlineData("wrong-column", "transcript")]
    [InlineData("bar-only", "bar")]
    [InlineData("missing-left-margin", "bar")]
    [InlineData("missing-right-margin", "bar")]
    [InlineData("wrong-row", "bar")]
    [InlineData("stale-inset", "inset")]
    [InlineData("field-left-of-pane", "field")]
    [InlineData("field-above-bar", "field")]
    [InlineData("unreadable-field", "field")]
    [InlineData("zero-size", "field")]
    [InlineData("not-finite", "field")]
    [InlineData("count-outside", "chatfind.count")]
    [InlineData("lost-next", "missing Find control")]
    [InlineData("buttons-overlap", "chatfind.next")]
    [InlineData("done-beyond-pane", "chatfind.done")]
    [InlineData("done-below-bar", "chatfind.done")]
    [InlineData("another-row", "share a row")]
    [InlineData("controls-in-edit", "wrong row")]
    [InlineData("earlier-overlap", "Earlier")]
    [InlineData("earlier-outside", "Earlier")]
    public void BadPaneReadingsCannotPass(string defect, string expected)
    {
        var f = Frame(earlier: true);
        FindPaneEvidence Move(int i, Box bounds) { var cells = f.Controls.ToArray(); cells[i] = bounds; return f with { Controls = cells }; }
        f = defect switch
        {
            "wide-transcript" => f with { Transcript = f.Transcript with { Width = 720 } },
            "wrong-column" => f with { Transcript = f.Transcript with { X = 8 } },
            "bar-only" => f with { Pane = f.Pane with { Width = 720 }, Transcript = f.Transcript with { Width = 720 } },
            "missing-left-margin" => f with { Bar = f.Bar with { X = 12 } },
            "missing-right-margin" => f with { Bar = f.Bar with { X = 20 } },
            "wrong-row" => f with { Bar = f.Bar with { Y = 6 } },
            "field-left-of-pane" => f with { Field = f.Field with { X = -5 } },
            "field-above-bar" => f with { Field = f.Field with { Y = 64 } },
            "unreadable-field" => f with { Field = f.Field with { Width = 80 } },
            "zero-size" => f with { Field = f.Field with { Height = 0 } },
            "not-finite" => f with { Field = f.Field with { X = double.NaN } },
            "count-outside" => Move(0, f.Controls[0] with { X = -6 }),
            "lost-next" => f with { Controls = [.. f.Controls.Where((_, i) => i != 2)] },
            "buttons-overlap" => Move(2, f.Controls[2] with { X = f.Controls[1].Right - 3 }),
            "done-beyond-pane" => Move(3, f.Controls[3] with { X = 240 }),
            "done-below-bar" => Move(3, f.Controls[3] with { Y = f.Bar.Bottom - 30 }),
            "another-row" => Move(0, f.Controls[0] with { Y = 159 }),
            "controls-in-edit" => Move(0, f.Controls[0] with { Y = f.Field.Y }),
            "earlier-overlap" => f with { Earlier = f.Earlier!.Value with { Y = 145 } },
            "earlier-outside" => f with { Earlier = f.Earlier!.Value with { X = 55 } },
            "stale-inset" => f,
            _ => throw new ArgumentException(defect),
        };
        Assert.Contains(expected, Judge(f, inset: defect == "stale-inset" ? 56 : null));
    }

    [Fact]
    public void AFrameCannotSubstituteTheOtherRowArrangement()
    {
        Assert.NotNull(Judge(Frame(720, stacked: false), stacked: true));
        Assert.NotNull(Judge(Frame(720, stacked: true), stacked: false));
    }
}
