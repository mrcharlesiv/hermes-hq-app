using Hermes.Core.Bots;

namespace Hermes.Core.Jobs;

/// [WIN-JOBS-ROW-FIT] How a job row fits its words at every text size, measured off App/Pages/Jobs/JobRowView.swift
/// (93f984bb1, lines 34–115) so Features/Jobs/JobsPage.cs `Row` draws from one place:
///   - ordinary sizes: the title in 2 lines, then one subtitle line (the coloured lead and the schedule in words), and
///     when it runs next at the trailing edge of the title's line;
///   - the accessibility sizes (`typeSize.isAccessibilitySize`; on Windows Settings › Accessibility › Text size at 150 %
///     or more, the threshold the Undo pill already uses): the title in up to 4 lines, the subtitle wraps with no limit,
///     and the edge follows the schedule after a non-breaking " · " instead, so the title keeps the row's width;
///   - the owner's face: 22 grown with the text and UI Scale, capped at 32 drawn; none for a job with no owner;
///   - 20 in from each side, 12 top and bottom in the Desktop Look (9 in the iOS look), at least 56 tall (52).
/// UI Scale on Windows scales the whole window (ThemeService.ApplyScale), so the padding is given unscaled and the face
/// in layout units whose drawn size is capped.
public enum JobRowTone { Label2, Tint, Red, Orange }

/// One coloured piece of the subtitle line.
public sealed record JobRowRun(string Text, JobRowTone Tone, bool Semibold = false);

/// The row's sizing. `SubtitleLines` 0 means no limit (the words wrap). Padding is inside the list's own side inset.
public sealed record JobRowFit(bool Large, int TitleLines, int SubtitleLines, bool EdgeAtTrailing, bool ShowsFace, double FaceSize, double FaceTop,
    double PadTop, double PadLeading, double PadBottom, double PadTrailing, double MinHeight);

public static class JobRowLayout
{
    /// The list's own side inset (the selection mark's, `DesktopRows.pressInset`); the row adds the rest of the Mac's 20.
    public const double ListSide = Shell.DesktopLook.MarkInsetSide;
    public const double Side = 20;
    /// The face at the default text size (`@ScaledMetric(relativeTo: .callout) textFaceSize = 22`) and its drawn cap.
    public const double Face = 22, FaceCap = 32;
    /// The Windows title's size (JobsPage `Row`) and Segoe UI's line height for it, for centring the face on line one.
    public const double TitleSize = 15, LineHeightRatio = 1.33;

    public static bool Large(double textScale) => UndoPillClock.AccessibilityTextScale(textScale);

    public static JobRowFit Fit(double textScale, double uiScale, bool desktopLook, string owner, RowEdge? edge)
    {
        var t = textScale > 0 && double.IsFinite(textScale) ? textScale : 1;
        var u = uiScale > 0 && double.IsFinite(uiScale) ? uiScale : 1;
        var large = Large(t);
        // `min(32, faceSize).rounded()` on the drawn size, then back to layout units under the window's scale.
        var drawn = Math.Round(Math.Min(FaceCap, Face * t * u), MidpointRounding.AwayFromZero);
        var face = drawn / u;
        var firstLine = TitleSize * t * LineHeightRatio;
        var faceTop = Math.Round((firstLine - face) / 2, 1);
        var vertical = desktopLook ? 12 : 9;
        return new JobRowFit(
            Large: large,
            TitleLines: large ? 4 : 2,
            SubtitleLines: large ? 0 : 1,
            EdgeAtTrailing: !large && edge != null,
            ShowsFace: !string.IsNullOrEmpty(owner),
            FaceSize: face,
            FaceTop: faceTop,
            PadTop: vertical, PadLeading: Side - ListSide, PadBottom: vertical, PadTrailing: Side - ListSide,
            MinHeight: desktopLook ? 56 : 52);
    }

    /// The subtitle line (`JobRowView.subtitle`): the lead in its colour (Paused semibold), the schedule in grey, and at the
    /// accessibility sizes the edge once after "\u00A0· " in its own tone.
    public static IReadOnlyList<JobRowRun> Subtitle(RowLead lead, string schedule, RowEdge? edge, bool large)
    {
        var runs = new List<JobRowRun>(4);
        if (lead != RowLead.None)
            runs.Add(new(JobWords.LeadWords(lead), lead switch
            {
                RowLead.Running => JobRowTone.Tint,
                RowLead.Failed => JobRowTone.Red,
                RowLead.Overdue => JobRowTone.Orange,
                _ => JobRowTone.Label2,
            }, Semibold: lead == RowLead.Paused));
        runs.Add(new(schedule, JobRowTone.Label2));
        if (large && edge != null)
        {
            runs.Add(new("\u00A0· ", JobRowTone.Label2));
            runs.Add(new(edge.Text, EdgeTone(edge)));
        }
        return runs;
    }

    /// The edge's colour (`edgeColor`): grey, orange when late, the tint while running.
    public static JobRowTone EdgeTone(RowEdge edge) => edge.Tone switch
    {
        Jobs.EdgeTone.Late => JobRowTone.Orange,
        Jobs.EdgeTone.Running => JobRowTone.Tint,
        _ => JobRowTone.Label2,
    };

    /// The row's one spoken name (`accessibilityLabel`): "title, lead+schedule[, spoken edge]", the same at every size.
    public static string AccessibleName(string title, RowLead lead, string schedule, RowEdge? edge) =>
        $"{title}, {JobWords.LeadWords(lead)}{schedule}{(edge != null ? ", " + edge.Spoken : "")}";
}
