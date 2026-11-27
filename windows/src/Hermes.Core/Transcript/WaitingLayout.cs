// [WIN-THINKING-FACE] The thinking row's drawing as numbers: App/Chat/Render/TextLayout.swift at 93f984bb1
// (`WaitingLayout` and the `.waiting` case of the row layout), App/Chat/Cells/ChatCells.swift `ChatWaitingCell`
// (`configure`: the dots and the pill inset; `tick`: the words trim before the timer; `placePill`) and
// App/Chat/Activity/GlyphSpinner.swift `Shimmer` (the desktop's band on running text).

namespace Hermes.Core.Transcripts;

/// A frame in the row, in points (the Mac's CGRect).
public readonly record struct WaitingRect(double X, double Y, double Width, double Height)
{
    public double MaxX => X + Width;
    public double MidY => Y + Height / 2;
}

/// [thinking] The bot's face, then the typing dots' capsule (it replaced the desktop's dither square), then the words.
/// `Face`: nil in a room's typing row (the member's face sits in the face column) or with no bot known. `Text`: where
/// the wait text ("Ivy is thinking…", then the timer) starts; one line, centred on the capsule.
public sealed record WaitingLayout(double Height, WaitingRect? Face, WaitingRect Capsule, WaitingRect Text)
{
    public const double FaceSide = 24;
    public const double CapsuleWidth = 40, CapsuleHeight = 24;
    /// The face, 6 pt, the capsule, 8 pt, the words (TextLayout.swift).
    public const double FaceGap = 6, TextGap = 8, TrailingInset = 16, MinHeight = 30;
    /// The dots: 6 pt, 5 pt apart (ChatWaitingCell `configure`).
    public const double DotSide = 6, DotSpacing = 5;
    /// The timer stands 5 pt after the words (`tick`).
    public const double TimerGap = 5;
    /// [backdrop] On a chat background the pill sits 3 pt round the face and dots and runs 10 pt past the words.
    public const double PillInsetOnBackdrop = 3, PillTrail = 10;
    /// On the pill the dots start 12 pt in from its round end (owner, 2026-11-01).
    public const double DotsOnPill = 12;

    /// Swift's `.rounded()`: half away from zero.
    private static double Round(double v) => Math.Round(v, MidpointRounding.AwayFromZero);

    /// The row for `width`, with the line's height `lineHeight` (`style.notice.lineHeight`), `gap` above it, the
    /// content's leading edge `lead`. A room's typing row (`plain`) leaves the face column (`senderColumn`) free.
    public static WaitingLayout Make(double width, double lineHeight, double gap, double lead, bool bot, bool plain,
        double senderColumn = 0)
    {
        var textH = Math.Ceiling(lineHeight);
        var h = Math.Max(MinHeight, textH);
        var x = lead + (plain ? senderColumn : 0);
        WaitingRect? face = null;
        if (!plain && bot)
        {
            face = new WaitingRect(x, gap + Round((h - FaceSide) / 2), FaceSide, FaceSide);
            x += FaceSide + FaceGap;
        }
        var capsule = new WaitingRect(x, gap + Round((h - CapsuleHeight) / 2), CapsuleWidth, CapsuleHeight);
        var textX = capsule.MaxX + TextGap;
        return new WaitingLayout(gap + h, face, capsule,
            new WaitingRect(textX, gap + (h - textH) / 2, Math.Max(0, width - textX - TrailingInset), textH));
    }

    /// The pill's inset: 3 pt on a chat background, none without one (`Backdrop.chats.shows`).
    public static double PillInset(bool backdrop) => backdrop ? PillInsetOnBackdrop : 0;

    /// Where the first dot starts in the capsule: centred, or 12 pt in from the pill's round end.
    public static double DotsStart(double capsuleWidth, double pillInset) =>
        pillInset > 0 ? DotsOnPill - pillInset : Round((capsuleWidth - (3 * DotSide + 2 * DotSpacing)) / 2);

    public static double DotTop(double capsuleHeight) => Round((capsuleHeight - DotSide) / 2);

    /// The room the words and the timer share: the text frame's width, less the pill's far end on a background.
    public static double Room(double textWidth, double pillInset) =>
        Math.Max(0, textWidth - (pillInset > 0 ? pillInset + PillTrail : 0));

    /// [toolnow] What the timer keeps of the room: nothing while there is none, else its measured width and its gap.
    public static double Reserve(string time, double timerWidth = 0) =>
        time.Length == 0 ? 0 : Math.Ceiling(timerWidth) + TimerGap;

    /// A long step's words end in "…" before the timer, which always shows whole (owner, 2026-10-28: the step ran under
    /// the timer and off the row).
    public static double WordsWidth(double room, double reserve, double natural) => Math.Max(0, Math.Min(room - reserve, natural));

    public static double TimerX(double wordsX, double wordsWidth) => wordsX + wordsWidth + TimerGap;

    /// [backdrop] The one pill that holds the face (or the dots), the words and the timer: 3 pt round where the face or
    /// the capsule starts, 10 pt past the timer (or the words), as tall as the capsule or the line, plus its inset.
    public static WaitingRect Pill(double? faceX, WaitingRect capsule, double wordsMaxX, bool timerShown, double timerMaxX,
        double lineHeight)
    {
        var lead = (faceX ?? capsule.X) - PillInsetOnBackdrop;
        var trail = (timerShown ? timerMaxX : wordsMaxX) + PillTrail;
        var h = Math.Max(capsule.Height, Math.Ceiling(lineHeight)) + 2 * PillInsetOnBackdrop;
        return new WaitingRect(lead, Round(capsule.MidY - h / 2), trail - lead, h);
    }

    public static double PillRadius(WaitingRect pill) => pill.Height / 2;
}

/// The desktop's `shimmer` on running text (tw-shimmer 0.4.12): a band `4ch + 80px` wide leaning 15°, one pass taking
/// (200 + band + 200·tan 15°) / 200 s with a 100 ms rest after it, its edges on a 17-stop sine falloff. Light: the band
/// fades the text to a fifth of its alpha. Dark: it lights the text up with the primary label. One clock for every
/// shimmer. Off when the system asks for fewer animations (the Mac's Reduce Motion).
public static class WaitingShimmer
{
    public const double Speed = 200, Track = 200, Rest = 0.1;
    public static readonly double Lean = Math.Tan(15 * Math.PI / 180);
    /// The stops, as a share of the band from its centre, and how much of the resting colour each holds.
    public static readonly IReadOnlyList<double> Stops =
        [-0.5, -0.44, -0.37, -0.31, -0.25, -0.19, -0.12, -0.06, 0, 0.06, 0.12, 0.19, 0.25, 0.31, 0.37, 0.44, 0.5];
    public static readonly IReadOnlyList<double> Resting =
        [1, 0.96, 0.83, 0.67, 0.5, 0.33, 0.17, 0.04, 0, 0.04, 0.17, 0.33, 0.5, 0.67, 0.83, 0.96, 1];

    /// `4ch + 80px`: four widths of the text's "0".
    public static double Band(double zeroWidth) => 4 * zeroWidth + 80;

    public static double Pass(double band) => (Track + band + Track * Lean) / Speed;

    public static double Lap(double band) => Pass(band) + Rest;

    /// How far into its lap the shimmer is at `nowSeconds` on the shared clock.
    public static double Offset(double nowSeconds, double band)
    {
        var lap = Lap(band);
        var x = nowSeconds % lap;
        return x < 0 ? x + lap : x;
    }

    public static bool Runs(bool animationsEnabled, double width, double height) => animationsEnabled && width > 0 && height > 0;

    /// Light: the text's alpha at a stop holding `resting` of the resting colour.
    public static double LightAlpha(double resting) => resting + (1 - resting) * 0.2;

    /// Dark: how much of the primary label lies over the text at that stop.
    public static double DarkGlow(double resting) => 1 - resting;

    /// The moving gradient: `Width` wide with its stops at `Locations` (0…1), moved from `From` to `To` along x over a
    /// pass, leaning 15° (a skew of −tan 15° on x).
    public sealed record SweepPlan(double Slack, double Reach, double Width, double From, double To, IReadOnlyList<double> Locations);

    public static SweepPlan Sweep(double width, double height, double band)
    {
        var slack = height / 2 * Lean + 1;
        var reach = width + slack;
        var total = 2 * reach + band + 2 * slack;
        var locations = Stops.Select(s => (slack + reach + band * (s + 0.5)) / total).ToList();
        return new SweepPlan(slack, reach, total, -slack - band - reach - slack, -slack, locations);
    }
}
