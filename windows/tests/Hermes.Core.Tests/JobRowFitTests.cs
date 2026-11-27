using Hermes.Core.Jobs;

namespace Hermes.Core.Tests;

/// [WIN-JOBS-ROW-FIT] A job row's sizing at every text size, as App/Pages/Jobs/JobRowView.swift (93f984bb1, lines 34–115)
/// draws it: two title lines and one subtitle line with the edge at the trailing side at ordinary sizes; four title
/// lines, a wrapping subtitle and the edge folded into it (once) at the accessibility sizes. Synthetic rows only.
public class JobRowFitTests
{
    private static readonly RowEdge Next = new("in 12 min", EdgeTone.Plain, "next in 12 min");
    private static readonly RowEdge Late = new("2h late", EdgeTone.Late, "2 hours late");
    private static readonly RowEdge Out = new("4m so far", EdgeTone.Running, "running for 4 minutes");

    [Theory]
    [InlineData(1.0, false)]
    [InlineData(1.25, false)]
    [InlineData(1.49, false)]
    [InlineData(1.5, true)]
    [InlineData(2.25, true)]
    public void OrdinaryAndAccessibilityTextSizes(double textScale, bool large)
    {
        Assert.Equal(large, JobRowLayout.Large(textScale));
        var fit = JobRowLayout.Fit(textScale, uiScale: 1, desktopLook: true, owner: "otto", edge: Next);
        Assert.Equal(large, fit.Large);
        Assert.Equal(large ? 4 : 2, fit.TitleLines);
        Assert.Equal(large ? 0 : 1, fit.SubtitleLines);   // 0: no limit, the words wrap
        Assert.Equal(!large, fit.EdgeAtTrailing);
    }

    [Fact]
    public void TheAccessibilitySizesGiveTheTitleFourLines()
    {
        var fit = JobRowLayout.Fit(2.0, 1, true, "otto", Late);
        Assert.Equal(4, fit.TitleLines);
        Assert.False(fit.EdgeAtTrailing);
    }

    [Fact]
    public void TheEdgeIsFoldedIntoTheSubtitleOnceAtTheAccessibilitySizes()
    {
        var runs = JobRowLayout.Subtitle(RowLead.Overdue, "Every day at 9:00 AM", Late, large: true);
        Assert.Equal(["Overdue · ", "Every day at 9:00 AM", "\u00A0· ", "2h late"], runs.Select(r => r.Text));
        Assert.Equal([JobRowTone.Orange, JobRowTone.Label2, JobRowTone.Label2, JobRowTone.Orange], runs.Select(r => r.Tone));
        Assert.Single(runs, r => r.Text == Late.Text);

        // Ordinary sizes: the edge stands at the trailing side, never in the subtitle.
        var ordinary = JobRowLayout.Subtitle(RowLead.Overdue, "Every day at 9:00 AM", Late, large: false);
        Assert.Equal(["Overdue · ", "Every day at 9:00 AM"], ordinary.Select(r => r.Text));

        // No edge: nothing is folded in, and no stray " · ".
        Assert.Equal(["Every day at 9:00 AM"], JobRowLayout.Subtitle(RowLead.None, "Every day at 9:00 AM", null, large: true).Select(r => r.Text));
    }

    [Fact]
    public void LeadPrecedenceToneAndExactCopyAreKept()
    {
        Assert.Equal(("Running · ", JobRowTone.Tint), First(RowLead.Running));
        Assert.Equal(("Last run failed · ", JobRowTone.Red), First(RowLead.Failed));
        Assert.Equal(("Overdue · ", JobRowTone.Orange), First(RowLead.Overdue));
        Assert.Equal(("Paused · ", JobRowTone.Label2), First(RowLead.Paused));
        Assert.True(JobRowLayout.Subtitle(RowLead.Paused, "Weekdays at 8:15 AM", null, false)[0].Semibold);
        // Running beats failed beats overdue beats paused (JobWords.Lead).
        Assert.Equal(RowLead.Running, JobWords.Lead(running: true, failed: true, overdue: true, paused: true));
        Assert.Equal(RowLead.Failed, JobWords.Lead(false, true, true, true));
        // The running edge keeps its tint when folded in.
        Assert.Equal(JobRowTone.Tint, JobRowLayout.Subtitle(RowLead.Running, "Every hour, on the hour", Out, true).Last().Tone);
        Assert.Equal(JobRowTone.Label2, JobRowLayout.Subtitle(RowLead.None, "Every hour, on the hour", Next, true).Last().Tone);

        static (string, JobRowTone) First(RowLead lead) =>
            JobRowLayout.Subtitle(lead, "Weekdays at 8:15 AM", null, false) is var r ? (r[0].Text, r[0].Tone) : default;
    }

    [Fact]
    public void TheSpokenNameSaysTheEdgeOnceAtEverySize()
    {
        Assert.Equal("Morning brief, Overdue · Every day at 9:00 AM, 2 hours late",
            JobRowLayout.AccessibleName("Morning brief", RowLead.Overdue, "Every day at 9:00 AM", Late));
        Assert.Equal("Morning brief, Every day at 9:00 AM",
            JobRowLayout.AccessibleName("Morning brief", RowLead.None, "Every day at 9:00 AM", null));
    }

    [Fact]
    public void AnEmptyOwnerDrawsNoFace()
    {
        Assert.False(JobRowLayout.Fit(1, 1, true, "", Next).ShowsFace);
        Assert.True(JobRowLayout.Fit(1, 1, true, "otto", Next).ShowsFace);
    }

    [Theory]
    [InlineData(1.0, 1.0, 22)]
    [InlineData(1.25, 1.0, 28)]       // 27.5 rounds away from zero, as Swift's .rounded()
    [InlineData(1.5, 1.0, 32)]        // 33 → capped at 32
    [InlineData(2.25, 1.0, 32)]
    [InlineData(1.0, 1.25, 27.5 / 1.25)]  // UI Scale scales the window: the face's layout size times 1.25 draws 28
    [InlineData(1.0, 1.5, 32 / 1.5)]      // 33 drawn → capped at 32 drawn
    public void TheFaceGrowsWithTheTextAndIsCappedAt32(double textScale, double uiScale, double layout)
    {
        var fit = JobRowLayout.Fit(textScale, uiScale, true, "otto", Next);
        Assert.Equal(Math.Round(layout * uiScale), Math.Round(fit.FaceSize * uiScale, 6));
        Assert.True(fit.FaceSize * uiScale <= 32 + 1e-9);
    }

    [Fact]
    public void ThePaddingIsTheMacsAndUiScaleIsNotAppliedTwice()
    {
        foreach (var ui in new[] { 0.9, 1.0, 1.5 })
        {
            var desk = JobRowLayout.Fit(1, ui, desktopLook: true, "otto", Next);
            Assert.Equal((12, 12), (desk.PadTop, desk.PadBottom));
            Assert.Equal(56, desk.MinHeight);
            // 20 in from the list's edge on both sides: the list's own inset plus the row's.
            Assert.Equal(20, JobRowLayout.ListSide + desk.PadLeading);
            Assert.Equal(20, JobRowLayout.ListSide + desk.PadTrailing);
            var ios = JobRowLayout.Fit(1, ui, desktopLook: false, "otto", Next);
            Assert.Equal((9, 9), (ios.PadTop, ios.PadBottom));
            Assert.Equal(52, ios.MinHeight);
            Assert.Equal(20, JobRowLayout.ListSide + ios.PadLeading);
        }
    }

    [Fact]
    public void ANormalListKeepsItsTwoLineRows()
    {
        var rows = new[]
        {
            (lead: RowLead.None, schedule: "Every day at 9:00 AM", edge: (RowEdge?)Next, owner: "otto"),
            (lead: RowLead.Failed, schedule: "Weekdays at 8:15 AM", edge: (RowEdge?)new RowEdge("Tomorrow", EdgeTone.Plain, "next Tomorrow"), owner: "ivy"),
            (lead: RowLead.Paused, schedule: "Every Monday at 7:30 AM", edge: (RowEdge?)null, owner: ""),
        };
        foreach (var row in rows)
        {
            var fit = JobRowLayout.Fit(1, 1, true, row.owner, row.edge);
            Assert.Equal(2, fit.TitleLines);
            Assert.Equal(1, fit.SubtitleLines);
            Assert.Equal(row.edge != null, fit.EdgeAtTrailing);
            Assert.Equal(22, fit.FaceSize);
            Assert.DoesNotContain(JobRowLayout.Subtitle(row.lead, row.schedule, row.edge, fit.Large), r => r.Text == "\u00A0· ");
        }
    }

    // ------------------------------------------------------------------ the page draws from the fit

    private static string JobsPageSource()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine(dir, "src", "HermesHQ.Windows", "Features", "Jobs", "JobsPage.cs"));
    }

    private static string RowSource()
    {
        var src = JobsPageSource();
        var start = src.IndexOf("private Button Row(", StringComparison.Ordinal);
        var end = src.IndexOf("private UIElement BlueprintRow(", StringComparison.Ordinal);
        Assert.True(start > 0 && end > start);
        return src[start..end];
    }

    [Fact]
    public void TheRowIsSizedByTheFitNotFixedNumbers()
    {
        var row = RowSource();
        Assert.Contains("JobRowLayout.Fit(", row);
        Assert.Contains("JobRowLayout.Subtitle(", row);
        Assert.Contains("JobRowLayout.AccessibleName(", row);
        Assert.Contains("fit.TitleLines", row);
        Assert.Contains("fit.EdgeAtTrailing", row);
        Assert.DoesNotContain("maxLines: 2", row);
        Assert.DoesNotContain("JobsUi.Face(job.Owner, 22)", row);
        // The click still opens the job, and its menu is still the job's.
        Assert.Contains("b.Click += (_, _) => Select(key);", row);
        Assert.Contains("_actions!.Menu(job)", row);
    }

    [Fact]
    public void ThePageRedrawsWhenWindowsTextSizeChanges()
    {
        var src = JobsPageSource();
        Assert.Contains("TextScaleFactor", src);
        Assert.Contains("TextScaleFactorChanged", src);
    }
}
