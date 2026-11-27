// [WIN-SCREEN-VIEWER-CORE] What the Bot Screen viewer draws, as plain values: the models of the Mac's
// ScreenStatePanel, ScreenNotesView and ScreenControlBar (App/Screen/ScreenViewerController.swift and
// ScreenControlBar.swift at 93f984bb1), the short note over the picture (the pill), the latest-screenshots page's
// inputs, and the zoom keys (HermesKit/Layout/ViewerKeys.swift's ZoomStep). The words are the Swift's.

namespace Hermes.Core.Screen;

/// The centred words and buttons of the states that are not a picture (S0, S1, S3, S4, S5, S7).
public sealed record ScreenPanelModel
{
    public bool Hidden { get; init; }
    public string Id { get; init; } = "";
    public bool Spinner { get; init; }
    public string? Title { get; init; }
    public string Body { get; init; } = "";
    public string? Footnote { get; init; }
    public string? Code { get; init; }
    public string? Primary { get; init; }
    public string PrimaryId { get; init; } = "";
    public string? Secondary { get; init; }
    public string SecondaryId { get; init; } = "";
    public bool Working { get; init; }
    /// Drawn over the (dimmed) picture: light text, no page behind it.
    public bool OverPicture { get; init; }
}

/// One line of the notes over the picture.
public sealed record ScreenNoteLine(string Text, string Id, bool Warning = false);

/// The notes over the picture: the error line, the held / other / Mac lines, and the Enable Control row.
public sealed record ScreenNotesModel
{
    public string? Error { get; init; }
    public IReadOnlyList<ScreenNoteLine> Lines { get; init; } = [];
    /// The Mac's input is not ready: a row that opens the control-only setup card.
    public bool EnableControl { get; init; }
}

/// The control bar under the picture.
public sealed record ScreenBarModel
{
    public string Caption { get; init; } = "";
    /// "You were in control": drawn as a labelled orange badge.
    public bool Held { get; init; }
    public string? Take { get; init; }
    public bool TakeEnabled { get; init; } = true;
    public bool Give { get; init; }
    public bool Force { get; init; }
    public ScreenSession.Busy? Busy { get; init; }
    public bool Fit { get; init; }
    public bool Keyboard { get; init; }
    public bool Typing { get; init; }
    public bool Mac { get; init; }
    public IReadOnlySet<ScreenKeys.Modifier> Armed { get; init; } = new HashSet<ScreenKeys.Modifier>();
}

/// The short note above the bar (`BrowserPill`): its words and identifier stay after it fades (Swift keeps both).
public sealed record ScreenPill(string Text, string Id, bool Shown);

/// The latest-screenshots page (LatestScreenshotsView) while the gateway has no live screen.
public sealed record ScreenFallbackModel(ScreenSession.Fallback Reason, string? Blocker, bool Managed, bool Visible);

/// Everything the viewer draws, after one render.
public sealed record ScreenViewerState
{
    public string Title { get; init; } = "";
    /// The navigation subtitle: the screen's label, none on the fallback page, while compact typing, or with no label.
    public string? Subtitle { get; init; }
    public string StageLabel { get; init; } = "";
    public bool StageHidden { get; init; }
    public bool StageDimmed { get; init; }
    public bool StageControl { get; init; }
    public bool StageCovered { get; init; }
    public bool BarHidden { get; init; }
    public ScreenBarModel Bar { get; init; } = new();
    public ScreenNotesModel Notes { get; init; } = new();
    public ScreenPanelModel Panel { get; init; } = new();
    /// Null until the fallback page is first made; afterwards its visibility rides in `Visible` (null reason: hidden).
    public ScreenFallbackModel? Fallback { get; init; }
    public bool FallbackShown { get; init; }
    public bool KeepAwake { get; init; }
    /// [mac] Zoom In / Zoom Out beside the title, and the = / - / 0 keys.
    public bool Zoomable { get; init; }
    public bool InCompact { get; init; }
    public ScreenPill? Pill { get; init; }
}

/// A zoom key or button (ZoomStep). Ctrl+= and Ctrl+- stay the app's UI Scale, so the viewer takes the keys unmodified.
public enum ScreenZoomStep { ZoomIn, ZoomOut, Fit }

public static class ScreenZoomSteps
{
    /// One press: the stage's Zoom in / Zoom out already step by this much.
    public const double StepFactor = 1.5;

    /// = (or +, Shift-=) zooms in, - (or _) zooms out, 0 fits.
    public static ScreenZoomStep? ForKey(string input) => input switch
    {
        "=" or "+" => ScreenZoomStep.ZoomIn,
        "-" or "_" => ScreenZoomStep.ZoomOut,
        "0" => ScreenZoomStep.Fit,
        _ => null,
    };

    /// The factor a step multiplies the zoom by; null for Fit.
    public static double? Factor(this ScreenZoomStep step) => step switch
    {
        ScreenZoomStep.ZoomIn => StepFactor,
        ScreenZoomStep.ZoomOut => 1 / StepFactor,
        _ => null,
    };

    /// A scroll of `dy` points as a zoom factor (ViewerKeys.swift `ZoomStep.scrollFactor`): content pulled down (a
    /// wheel turned up) zooms in. A trackpad doubles the zoom every 200 pt of travel; a mouse wheel's notch (about
    /// 10 pt) is a fifth of a step more. One event never moves it more than a step either way.
    public static double ScrollFactor(double dy, bool discrete)
    {
        if (!double.IsFinite(dy) || dy == 0) return 1;
        var factor = Math.Pow(2, dy / (discrete ? 40 : 200));
        return Math.Min(StepFactor, Math.Max(1 / StepFactor, factor));
    }

    /// The viewer's key commands while a live picture is up and the key field does not type (`keyCommands`).
    public static readonly IReadOnlyList<(string Input, bool Shift, string Title)> Keys =
        [("=", false, "Zoom In"), ("+", true, "Zoom In"), ("-", false, "Zoom Out"), ("0", false, "Fit Screen")];
}
