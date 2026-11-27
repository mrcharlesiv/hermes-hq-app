using Hermes.Core.Shell;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Settings;

/// SettingsRootView.SettingsCategoryColumn, MacForm.side, MacInset and HQFont at 484cd6acf. Layout DIPs in
/// the separate, untransformed Settings frame. The main frame already has ThemeService.ApplyScale; it does not use this.
public readonly record struct SettingsColumnLayout(ThemeState State)
{
    private const double Catalyst = ChatStyle.Catalyst;
    public const double ColumnInset = 12 * Catalyst, TopInset = 20 * Catalyst, BottomInset = 14 * Catalyst;
    public const double RowSide = 10 * Catalyst, RowVertical = 8 * Catalyst, RowGap = 2 * Catalyst;
    public const double IconSlot = 30 * Catalyst, IconGap = 10 * Catalyst, BlockGap = 10 * Catalyst;
    public const double FieldSide = 8 * Catalyst, FieldVertical = 6 * Catalyst, FieldGap = 6 * Catalyst, FieldRadius = 8 * Catalyst;
    public const double WordGap = 1 * Catalyst, FormGutter = DesktopLook.PageSide * Catalyst;

    private static double Round(double n) => Math.Round(n, MidpointRounding.AwayFromZero);
    private static double Half(double n) => Round(n * 2) / 2;
    private static double Dpi(double dpi) => double.IsFinite(dpi) && dpi > 0 ? dpi : 1;

    // Snap the end of the column to the display grid, then give the divider exactly one physical pixel.
    public double ColumnWidth(double dpi) => Round(Round(270 * State.UiScalePercent / 100d) * Catalyst * Dpi(dpi)) / Dpi(dpi);
    public static double Hairline(double dpi) => 1 / Dpi(dpi);

    // MacForm caps the cards, not the list: center them in the available viewport, with a fixed minimum gutter.
    private double ReadablePoints => Round(720 * State.UiScalePercent / 100d * ChatStyle.MacBase(false));
    public double FormSide(double viewport) => Math.Max(FormGutter, Round((viewport / Catalyst - ReadablePoints) / 2) * Catalyst);

    private double TypeScale => State.Scale * ChatStyle.MacBase(State.DesktopLook);
    private double Style(double standard, double desktop) => Catalyst * (State.DesktopLook
        ? Math.Max(ChatStyle.MacSmallest, Half(desktop * TypeScale)) : Half(standard * TypeScale));
    public double Body => Style(17, 15); // headline has the same size, semibold
    public double SearchIcon => Style(15, 13.5);
    public double Footnote => Catalyst * ChatStyle.NoticePoints(State.DesktopLook, State.UiScalePercent, 1);
    public double GatewayIcon => Catalyst * Half(20 * TypeScale); // HQFont.scaled, not the fixed icon slot
    public double MarkRadius => Catalyst * DesktopLook.MarkRadius(State.DesktopLook);

    // Settings uses MacSelection.accent even when focus moves into the pane; the keyboard focus ring is separate.
    public static Rgba PaneLine(ThemeTokens tokens, bool desktop, bool dark) =>
        !desktop ? tokens.Separator : dark ? Rgba.White.Alpha(.1) : Rgba.Black.Alpha(.12);
    public static int SelectedIndex(SettingsCategory category, bool gateway, bool searching) =>
        gateway || searching ? -1 : Array.IndexOf(SettingsCategories.All, category);
}
