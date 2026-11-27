namespace Hermes.Core.Settings;

/// [density] Theme › Density (Mac 93f984bb1 HermesKit/Theme/ThemeState.swift `ListDensity`): the iOS look's own rows, or
/// Compact's smaller faces and type and shorter rows. The Desktop Look keeps its own rows (`ThemeState.Compact`).
public enum ListDensity { Standard, Compact }

/// [top-edge] How rows meet the top bar where they scroll under it (`TopEdge`): the blur fading out going down, or a
/// frosted band the height of the bar cut off on a straight line.
public enum TopEdge { Soft, Hard }

public static class ListDensities
{
    /// The Mac's raw value.
    public static string Raw(this ListDensity d) => d == ListDensity.Compact ? "compact" : "standard";

    /// `ListDensity(rawValue:)`: exact raw values only, anything else null.
    public static ListDensity? Parse(string? raw) => raw switch
    {
        "standard" => ListDensity.Standard,
        "compact" => ListDensity.Compact,
        _ => null,
    };
}

public static class TopEdges
{
    public static string Raw(this TopEdge e) => e == TopEdge.Soft ? "soft" : "hard";

    public static TopEdge? Parse(string? raw) => raw switch
    {
        "soft" => TopEdge.Soft,
        "hard" => TopEdge.Hard,
        _ => null,
    };
}

/// [density] Appearance › Bots & Sessions › Density (AppearancePage.swift `DensityRow`, `lists`, `compactNote`): a
/// Standard / Compact segmented control, first in the group, only in the iOS look.
public static class DensityRow
{
    public const string Label = "Density";
    public const string AutomationId = "theme.density";
    /// The row's id on the page and Settings search's target (`AppearanceRows.density`).
    public const string RowTarget = "row:density";
    public static readonly (string Title, ListDensity Value)[] Options = [("Standard", ListDensity.Standard), ("Compact", ListDensity.Compact)];
    /// The Mac's words (its bots are in the sidebar and its rows have one line of preview whatever the density).
    public const string CompactNote = "Compact fits more in the sidebar's bots and on the Sessions page: smaller faces and shorter rows.";

    /// The Desktop Look keeps its own rows, so the row is the iOS look's.
    public static bool Shown(ThemeState state) => !state.DesktopLook;

    /// The group's footer (`listsNote`): Compact's note in the iOS look, then Working Ring's.
    public static string ListsNote(ThemeState state) =>
        string.Join(" ", new[] { state.DesktopLook ? null : CompactNote, WorkingRing.Note }.Where(s => s != null));
}

/// [top-edge] Appearance › App › Top Edge (AppearancePage.swift `TopEdgeRow`, `topEdgeShown`; App/Theme/TopEdgeStyle.swift).
/// The Mac never offers it (`TopEdgeStyle.offered` is false under Mac Catalyst): its bars have a backing and it draws no
/// top edge, so the choice is the iPhone's and iPad's. This desktop follows the Mac: the stored value is kept (an
/// import or a Reset handles it like any `hqn.theme.*` key) and no row is drawn.
public static class TopEdgeRow
{
    public const string Label = "Top Edge";
    public const string AutomationId = "theme.topEdge";
    public const string RowTarget = "row:top-edge";
    public static readonly (string Title, TopEdge Value)[] Options = [("Soft", TopEdge.Soft), ("Hard", TopEdge.Hard)];
    /// `ThemeSettingsView.topEdgeNote`.
    public const string Note = "Where rows scroll under the top of every tab. Chats always fade softly. Soft blurs them out gradually. Hard is a frosted band with a straight bottom edge.";

    /// `TopEdgeStyle.offered` on the Mac.
    public static bool Offered => false;

    /// `topEdgeShown`: offered, and not in the Desktop Look.
    public static bool Shown(ThemeState state) => Offered && !state.DesktopLook;

    /// `TopEdgeStyle.current`: soft where it isn't offered; hard in the Desktop Look; else the choice.
    public static TopEdge Applied(ThemeState state)
    {
        if (!Offered) return TopEdge.Soft;
        return state.DesktopLook ? TopEdge.Hard : state.TopEdge;
    }
}

/// [density] Where Density takes effect on the Mac: the sidebar's bots, chats and places (App/Mac/SidebarType.swift
/// `current`, MacBotsRail `rowFace` / `sidebarRowHeight` / `nameSize`, `MacSidebar.openRowHeight` / `placeSize`, the chat
/// rows' `rowHeight` / `titleSize`) and the Sessions page's chat rows (SessionRowViews.swift `macTight`). The open sidebar
/// uses the Mac points in ChatVisualTokens; Sessions still scales its own standard sizes by the Compact ratios.
public static class DensitySizes
{
    public sealed record SidebarSizes(double Face, double BotRow, double Name, double PlaceRow, double ChatRow, double ChatTitle);
    public sealed record SessionSizes(double Row, double Pad, double Face);

    private static readonly SidebarSizes SidebarStandard = ChatVisualTokens.Sidebar(false), SidebarCompact = ChatVisualTokens.Sidebar(true);
    /// Windows' Standard Sessions chat row: 34 tall, 5 over and under, a 22 owner's face.
    public static readonly SessionSizes SessionsStandard = new(Row: 34, Pad: 5, Face: 22);

    // The Mac's Sessions pairs (Standard, Compact).
    private const double MacSessionRow = 36, MacSessionRowCompact = 32;
    private const double MacSessionPad = 6, MacSessionPadCompact = 5;
    private const double MacSessionFace = 22, MacSessionFaceCompact = 18;

    /// `size` × compact ÷ standard, to the nearest half point.
    public static double Step(double size, double macStandard, double macCompact) =>
        Math.Round(size * macCompact / macStandard * 2, MidpointRounding.AwayFromZero) / 2;

    public static SidebarSizes Sidebar(bool compact) => compact ? SidebarCompact : SidebarStandard;

    public static SessionSizes Sessions(bool compact)
    {
        var s = SessionsStandard;
        if (!compact) return s;
        return new SessionSizes(
            Row: Step(s.Row, MacSessionRow, MacSessionRowCompact),
            Pad: Step(s.Pad, MacSessionPad, MacSessionPadCompact),
            Face: Step(s.Face, MacSessionFace, MacSessionFaceCompact));
    }

    // ProjectCard.swift: a closed project's row is rowPad + face + rowPad, 4 + 28 + 4 at Standard on the Mac (rowPad's
    // macTight `mac: 4`), 5 + 22 + 5 in Compact; its name body → callout (`nameFont`, 17 → 16); the face column's gap
    // `Density.ios(12, 10)`. SessionRowViews.swift `breakAbove`: 20 over a group's caption, 12 in Compact.
    private const double MacProjectRow = 36, MacProjectRowCompact = 32;
    private const double MacProjectFace = 28, MacProjectFaceCompact = 22;
    private const double MacBody = 17, MacCallout = 16;
    private const double MacColumnGap = 12, MacColumnGapCompact = 10;
    private const double MacBreakAbove = 20, MacBreakAboveCompact = 12;

    public sealed record ProjectSizes(double Pad, double Folder, double Name, double Gap);

    /// Windows' Standard project row on Sessions: 6 over and under, a 16 folder, a 15 name, 10 between folder and name.
    public static readonly ProjectSizes ProjectStandard = new(Pad: 6, Folder: 16, Name: 15, Gap: 10);
    /// Windows' Standard room over a group's caption (Pinned, the days, statuses, bots).
    public const double HeaderAboveStandard = 10;

    public static ProjectSizes Project(bool compact)
    {
        var s = ProjectStandard;
        if (!compact) return s;
        return new ProjectSizes(
            Pad: Step(s.Pad, MacProjectRow, MacProjectRowCompact),
            Folder: Step(s.Folder, MacProjectFace, MacProjectFaceCompact),
            Name: Step(s.Name, MacBody, MacCallout),
            Gap: Step(s.Gap, MacColumnGap, MacColumnGapCompact));
    }

    public static double HeaderAbove(bool compact) =>
        compact ? Step(HeaderAboveStandard, MacBreakAbove, MacBreakAboveCompact) : HeaderAboveStandard;

    /// [ui-sizing] A Capabilities or Marketplace row's description (toolsets, plugins, hub skills, catalog plugins and
    /// skills): `.lineLimit(Density.compact ? 1 : 2)`.
    public static int DescriptionLines(bool compact) => compact ? 1 : 2;

    /// After the drawn density changes (Density picked, or the Desktop Look turned on or off over Compact): the sidebar,
    /// Sessions and the Capabilities pages draw their rows again at once.
    public static event Action? Changed;

    /// Tells the lists when `was` and `now` draw at different densities. True when it did.
    public static bool Notify(ThemeState was, ThemeState now)
    {
        if (was.Compact == now.Compact) return false;
        Changed?.Invoke();
        return true;
    }
}
