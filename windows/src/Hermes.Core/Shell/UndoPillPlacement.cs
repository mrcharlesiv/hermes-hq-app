namespace Hermes.Core.Shell;

/// [WIN-RAIL-TOOLS-FIT] Where the shell's Undo pill stands ("Archived “title”" with its way back, a bot's "Hidden ·
/// Undo"): over the pane beside the sidebar, never in the sidebar. App/Kit/UndoPill.swift `show(…)` at 93f984bb1: the
/// list that asks for the pill (the Bots list, the tab controller) is folded out of sight on the Mac — its rows are the
/// sidebar's — so `shownPane` puts the pill over the detail pane on show beside it (Mac polish #32), open sidebar or
/// folded alike: centred, at least 16 in from either edge, 8 above the pane's foot, and above a chat's message box while
/// one is there. Windows stood it in the sidebar's foot, where the folded rail (64 wide) cut "Archived" to "Arc".
public static class UndoPillPlacement
{
    /// `pill.leadingAnchor ≥ view.leadingAnchor + 16`, `trailing ≤ −16`; `wrapLines(within: view.bounds.width − 32)`.
    public const double Inset = 16;

    /// `pill.bottomAnchor = view.safeAreaLayoutGuide.bottomAnchor − 8`, and `≤ messageBar.topAnchor − 8`.
    public const double Above = 8;

    /// The width the pill's words wrap within over a pane `paneWidth` wide.
    public static double WrapWidth(double paneWidth) =>
        double.IsFinite(paneWidth) && paneWidth > 2 * Inset ? paneWidth - 2 * Inset : 0;

    /// How far the pill's bottom stands above the pane's foot: 8, or 8 above a message box whose top is `messageBarTop`
    /// down a pane `paneHeight` tall (both in the pane's own coordinates).
    public static double Lift(double paneHeight, double? messageBarTop)
    {
        if (messageBarTop is not { } top || !double.IsFinite(top) || !double.IsFinite(paneHeight) || top >= paneHeight)
            return Above;
        return Math.Max(0, paneHeight - Math.Max(0, top)) + Above;
    }

    /// What is wrong with a pill laid out at `pill` (window coordinates, as the pane and the sidebar), or null: it stands
    /// within the pane, at least `Inset` in from its sides (a pixel's rounding allowed), clear of the sidebar, and its
    /// words are whole (`labelTrimmed` false). The archive-undo walk asks this of the real pill.
    public static string? Misplaced((double X, double Y, double W, double H) pill, (double X, double Y, double W, double H) pane,
        (double X, double Y, double W, double H) sidebar, bool labelTrimmed)
    {
        const double slack = 1;
        if (pill.W <= 0 || pill.H <= 0) return "the pill has no size";
        if (pill.X < sidebar.X + sidebar.W - slack && pill.X + pill.W > sidebar.X + slack)
            return $"the pill ({pill.X:0}…{pill.X + pill.W:0}) is over the sidebar ({sidebar.X:0}…{sidebar.X + sidebar.W:0})";
        if (pill.X < pane.X + Inset - slack || pill.X + pill.W > pane.X + pane.W - Inset + slack)
            return $"the pill ({pill.X:0}…{pill.X + pill.W:0}) isn't {Inset:0} in from the pane ({pane.X:0}…{pane.X + pane.W:0})";
        if (pill.Y < pane.Y - slack || pill.Y + pill.H > pane.Y + pane.H - Above + slack)
            return $"the pill ({pill.Y:0}…{pill.Y + pill.H:0}) isn't {Above:0} above the pane's foot ({pane.Y + pane.H:0})";
        if (labelTrimmed) return "the pill's words are cut short";
        return null;
    }
}
