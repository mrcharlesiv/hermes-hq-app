namespace Hermes.Core.Heads;

/// What a renderer draws for a head at a size (HeadRenderer.swift `picture`): a Shapes head as geometry, or a themed
/// or dot-matrix head as SVG (with an Emoji head's words, which the SVG renderer can't draw). Always the app's own
/// drawing: eyes only, the normal ones, resting looking to the right (`Head.Plain`).
public abstract record HeadPicture
{
    public sealed record Shapes(ShapeHeadLayout Layout) : HeadPicture;
    public sealed record Svg(string Markup, ThemeHeadSvg.GlyphLabel? Label) : HeadPicture;

    /// A small picture (a list row, a header: under 64) is the compact drawing, with bolder eyes.
    public const double CompactBelow = 64;

    /// `dark`: the page (null: unknown, as for the desktop copy). A themed head looks the same on either page.
    public static HeadPicture For(Head head, double side, bool? dark, HeadState state = HeadState.Idle)
    {
        head = head.Plain;
        var compact = side < CompactBelow;
        if (head.Themed is { } record)
            return new Svg(ThemeHeadSvg.Svg(record, state == HeadState.Idle ? null : state, compact, plain: true, restLook: true, d2d: true),
                record.Theme == "glyph" ? ThemeHeadSvg.Label(record) : null);
        if (head.Theme == HeadTheme.Matrix)
            return new Svg(MatrixHeadSvg.Svg(head, side, dark == true, state == HeadState.Thinking ? new MatrixPose(Gaze: 1, Lift: -1) : MatrixPose.Look), null);
        return new Shapes(HeadGeometry.Layout(head, state, compact, dark));
    }

    /// What a picture is cached on: the head, the size class, and the page where it matters.
    public static string Key(Head head, double side, bool? dark) =>
        $"{head.Plain.CacheKey}|{(side < CompactBelow ? "c" : "f")}|{(head.Themed != null ? "-" : dark switch { true => "d", false => "l", null => "u" })}"
        + (head.Theme == HeadTheme.Matrix ? $"|{Math.Round(side)}" : "");
}
