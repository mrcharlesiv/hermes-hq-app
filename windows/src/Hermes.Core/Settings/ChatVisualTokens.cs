namespace Hermes.Core.Settings;

/// The chat and open sidebar of the shipping Mac at 2b547a2b0. Colours are sRGB, not the
/// monitor-profile bytes in a screenshot. Lengths returned to the view are DIPs at UI Scale 100%;
/// apply Catalyst's point conversion once. Windows' window transform and accessibility text size
/// are separate. Keep skins/contrast in ThemeResolver and ThemeService, downstream of these defaults.
public static class ChatVisualTokens
{
    // App/Theme/MacTypeSteps.swift:12–13 (not the optional debug font-snapping trial).
    public const double Dip = 0.77;

    // HermesKit/Theme/ThemeTokens.swift:142–149,162–164: dark accent and dark outgoing differ.
    public sealed record Palette(Rgba Page, Rgba Ink, Rgba Accent, Rgba Incoming, Rgba Outgoing, Rgba OutgoingTime);
    public static readonly Palette Light = new(Rgba.Hex(0xFEFEFE), Rgba.Hex(0x1F2328), Rgba.Hex(0x0053FD),
        Rgba.Hex(0xE9E9EB), Rgba.Hex(0x0053FD), Rgba.White.Alpha(0.85));
    public static readonly Palette Dark = new(Rgba.Hex(0x0D1015), Rgba.Hex(0xE6EDF3), Rgba.Hex(0x4A84FE),
        Rgba.Hex(0x26282C), Rgba.Hex(0x3863BF), Rgba.White.Alpha(0.88));

    // App/Mac/MacSidebar.swift:2025–2042: interpolate RGB, not premultiplied ink. The solid panel takes alpha 1.
    public static Rgba GlassTint(Rgba page, Rgba ink, bool dark)
    {
        var t = dark ? 0.14 : 0.10;
        return new(page.R + (ink.R - page.R) * t, page.G + (ink.G - page.G) * t, page.B + (ink.B - page.B) * t, 0.85);
    }

    // HermesKit/Theme/ThemeState.swift:53–57; App/Chat/ChatPalette.swift:105–112. Preferences stay in app points.
    public const int DefaultCorners = 12, DesktopCorners = 4;
    public const double Side = 16 * Dip, PadH = 16 * Dip, PadV = 9 * Dip;
    // App/Chat/Activity/ActivityRows.swift:1274–1277: tool cells keep their inset even when unpainted.
    public const double ToolPadH = 12 * Dip, ToolPadV = 8 * Dip;
    // ChatPalette.swift:113,126–129; App/Chat/Render/ChatGlyphs.swift:257–265,278–285.
    public const double TailWidth = 8 * Dip, TailHeight = 17 * Dip, TailOverlap = Dip;
    public const double TimeTrailing = 10 * Dip, TimeBottom = 5 * Dip, TimeGap = 12 * Dip;
    // ChatPalette.swift:130–157. At slider values over 12, move the clock in to keep the same clearance.
    public static double ClockInset(int corner, bool square)
    {
        if (square || corner <= DefaultCorners) return 0;
        const double a = TimeTrailing / Dip, b = TimeBottom / Dip;
        static double Gap(double r) => r - Math.Sqrt((r - a) * (r - a) + (r - b) * (r - b));
        var want = Gap(DefaultCorners);
        if (Gap(corner) >= want) return 0;
        var reach = corner - want;
        return Math.Ceiling((2 * corner - a - b - Math.Sqrt(2 * reach * reach - (a - b) * (a - b))) / 2) * Dip;
    }
    // HermesKit/Layout/PaneLayout.swift:85–98; App/Chat/ChatPalette.swift:114–124;
    // App/Chat/Render/TextLayout.swift:925–927,949–958. A wide table alone may outgrow the reply cap.
    public const double Column = 1280 * Dip, BubbleMax = 728 * Dip, RunGap = 2 * Dip, TurnGap = 6 * Dip;
    public const int RunSeconds = 300;
    public static double BubbleWidth(double innerWidth, bool mine, bool largeText, bool table = false) =>
        !mine && table ? innerWidth : mine && largeText ? innerWidth * 0.9 : Math.Min(BubbleMax, mine ? innerWidth * 0.8 : innerWidth);

    // App/Mac/MacSidebar.swift:25–37,54–60,148–158,202–205. Use the default only when no width was saved.
    public const double OpenWidth = 300 * Dip, HeadingHeight = 30 * Dip;
    // App/Mac/SidebarType.swift:54–66,79–82; App/Mac/MacBotsRail.swift:33–40,1028–1032. Pitch
    // includes the stack's 2 pt gap except for chats; centre the content, don't add another gap in padding.
    public static DensitySizes.SidebarSizes Sidebar(bool compact) => compact
        ? new(28 * Dip, (38 + 2) * Dip, 18 * Dip, (32 + 2) * Dip, 32 * Dip, 15.5 * Dip)
        : new(34 * Dip, (43.5 + 2) * Dip, 19.5 * Dip, (37 + 2) * Dip, 36 * Dip, 17 * Dip);
    // SidebarType.swift:60–66; MacSidebar.font (MacSidebar.swift:54–60) floors 14.5 pt at
    // HQFont.macSmallest (App/Theme/ThemeFonts.swift:49–68). MacBotsRail.swift:452–453,822,948–951,1132,1152.
    public const double SidebarSmall = 15 * Dip, SidebarMore = 15.5 * Dip, SidebarCount = 16 * Dip, SidebarSearch = 17 * Dip;
    // MacSidebar.swift:174,1364–1365,2446,2533–2537; MacBotsRail.swift:539–544. Weight numbers are
    // the Windows equivalents of UIKit regular, medium and semibold (ThemeFonts.swift:13–26).
    public const double PlaceIcon = 18 * Dip;
    public const ushort Regular = 400, Medium = 500, Semibold = 600;

    // Default content size (.large), before Windows text scaling. UIKit's preferred sizes / weights →
    // HQFont.preferred: App/Theme/ThemeFonts.swift:13–26,49–68,96–109; per-look multipliers:
    // HermesKit/Theme/ThemeState.swift:69–75,81–105. Round in *app points*, before converting to DIPs.
    public readonly record struct Face(double Size, ushort Weight);
    public sealed record TypeRamp(Face LargeTitle, Face Title1, Face Title2, Face Title3, Face Headline, Face Body,
        Face Callout, Face Subhead, Face Footnote, Face Caption1, Face Caption2)
    {
        // App/Chat/ChatStyle.swift:85–123: chatText = 1 at the shipping macBody; headings are semibold.
        public double BodyLine => Math.Ceiling(Body.Size / Dip * 1.45) * Dip;
        public double InlineCode => Math.Round(Body.Size / Dip * 0.9, MidpointRounding.AwayFromZero) * Dip;
        public double CodeLine => Math.Ceiling(Footnote.Size / Dip * 1.5) * Dip;
        public double TableLine => Math.Ceiling(Footnote.Size / Dip * 1.4) * Dip;
        // App/Chat/Render/MarkdownRenderer.swift:419; keep the ceiling in app points, just like the body.
        public double HeadingLine(int level) => Math.Ceiling(Heading(level).Size / Dip * 1.3) * Dip;
        public Face Heading(int level) => new(Math.Round(Body.Size / Dip * (level switch { 1 => 1.25, 2 => 1.125, _ => 1.0625 }),
            MidpointRounding.AwayFromZero) * Dip, Semibold);
        public double ParagraphGap => Math.Round(11.2 * Body.Size / Dip / 17, MidpointRounding.AwayFromZero) * Dip;
    }
    private static TypeRamp MakeType(bool desktop)
    {
        Face Font(double apple, double desktopPt, ushort appleWeight = Regular, ushort desktopWeight = Regular)
        {
            var points = Math.Round((desktop ? desktopPt * 1.3 : apple * 1.15) * 2, MidpointRounding.AwayFromZero) / 2;
            return new((desktop ? Math.Max(15, points) : points) * Dip, desktop ? desktopWeight : appleWeight);
        }
        // Catalyst substitutes footnote for caption1/2 in the standard look, not in Desktop Look.
        return new(Font(34, 22, Regular, Semibold), Font(28, 20, Regular, Semibold), Font(22, 18, Regular, Semibold),
            Font(20, 16, Regular, Semibold), Font(17, 15, Semibold, Semibold), Font(17, 15), Font(16, 14),
            Font(15, 13.5), Font(13, 12.5), Font(13, 12), Font(13, 11));
    }
    private static readonly TypeRamp StandardType = MakeType(false), DesktopType = MakeType(true);
    public static TypeRamp Type(bool desktop) => desktop ? DesktopType : StandardType;
}
