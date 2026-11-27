namespace Hermes.Core.Settings;

/// [glass-bubbles] [tinted-bubbles] How chat bubbles are filled in the iOS look (Mac 93f984bb1 HermesKit/Theme/ThemeState.swift
/// `BubbleStyle`; Theme › Chats › Chat Bubbles › Style).
public enum BubbleStyle { Solid, Glass, Tinted, Card }

public static class BubbleStyles
{
    /// The Mac's raw value, as stored in `hqn.theme.bubbleStyle`.
    public static string Raw(this BubbleStyle s) => s switch
    {
        BubbleStyle.Glass => "glass",
        BubbleStyle.Tinted => "tinted",
        BubbleStyle.Card => "card",
        _ => "solid",
    };

    /// `BubbleStyle(rawValue:)`: exact raw values only, anything else null.
    public static BubbleStyle? Parse(string? raw) => raw switch
    {
        "solid" => BubbleStyle.Solid,
        "glass" => BubbleStyle.Glass,
        "tinted" => BubbleStyle.Tinted,
        "card" => BubbleStyle.Card,
        _ => null,
    };

    /// `BubbleStyle.title`.
    public static string Title(this BubbleStyle s) => s switch
    {
        BubbleStyle.Glass => "Glass",
        BubbleStyle.Tinted => "Tinted",
        BubbleStyle.Card => "Card",
        _ => "Solid",
    };
}

/// [theme-pages] Settings › Appearance › Chats › Chat Bubbles (AppearancePage.swift `chatBubblesRow`; ThemeSettingsView.swift
/// `ChatBubblesSettingsView`, `BubbleCornersRow`, `BubbleStyles`). In the iOS look the page holds Corners and Style; in the
/// Desktop Look, that look's own Corners (and, off the Mac, its Text Box). This desktop has no Liquid Glass, so it takes the
/// Mac's branch for where glass isn't offered (`GlassBubbles.offered` false): Solid or Tinted, as a Tinted switch, and the
/// note that goes with it. Glass and Card read as Solid here. The renderer respects stored plain replies;
/// Reply Bubbles and Color aren't offered on this PC's settings page yet.
public static class ChatBubbles
{
    public const string SectionTitle = "Chats";
    public const string Label = "Chat Bubbles";
    public const string RowId = "settings.chat-bubbles-row";
    /// The page's id (`SettingsNavigator.openRoot("chat-bubbles")`), and Settings search's target.
    public const string Target = "chat-bubbles";
    public const string PageId = "settings.chat-bubbles";

    public const string CornersLabel = "Corners";
    /// The slider's own name (`Text("Bubble Corners")`), the accessible one.
    public const string CornersName = "Bubble Corners";
    public const string CornersId = "theme.bubbleCorners";
    public const string TintedLabel = "Tinted";
    public const string TintedId = "theme.tintedBubbles";

    /// `ThemeState.bubbleCornerRange`.
    public static (int Min, int Max) Range => (ThemeState.MinCorners, ThemeState.MaxCorners);

    /// `GlassBubbles.offered`: no Liquid Glass on Windows.
    public static bool GlassOffered => false;
    /// [mac] `ThemeState.textBoxIsFixed`: this desktop keeps its own message box, as the Mac.
    public static bool TextBoxIsFixed => true;

    /// `BubbleStyles.offered`.
    public static IReadOnlyList<BubbleStyle> Offered { get; } =
        GlassOffered ? [BubbleStyle.Solid, BubbleStyle.Glass, BubbleStyle.Tinted, BubbleStyle.Card] : [BubbleStyle.Solid, BubbleStyle.Tinted];

    /// `BubbleStyles.shown`: a stored style as it draws here; one not offered is Solid.
    public static BubbleStyle Shown(BubbleStyle stored) => Offered.Contains(stored) ? stored : BubbleStyle.Solid;

    /// The row's value: the Desktop Look's corner, or the shown style.
    public static string Value(ThemeState state) => state.DesktopLook ? CornersValue(state.DesktopCorners) : Shown(state.BubbleStyle).Title();

    /// The look in use's stored corner (the slider's value).
    public static int Corners(ThemeState state) => state.DesktopLook ? state.DesktopCorners : state.BubbleCorners;
    public static string CornersValue(int points) => $"{points} pt";
    public static string CornersSpoken(int points) => $"{points} points";

    /// Style is the iOS look's (the Desktop Look keeps its own boxes).
    public static bool ShowsStyle(ThemeState state) => !state.DesktopLook;

    /// `Theme.setBubbleCorners`: the slider writes the look in use's corner.
    public static void SetCorners(ThemeStore store, ThemeState state, int points) => store.SetBubbleCorners(points, desktop: state.DesktopLook);

    /// `ChatBubblesSettingsView.note` where glass isn't offered.
    public static string Note =>
        $"How round the corners of messages in chats are, and whether they’re Tinted with the colors of your Chat Background. 12 pt is the standard. With Reduce Transparency on, messages stay solid. The Desktop Look has its own Corners, here once it is on. {Gateways.DeviceWord.OnlyHere}";

    /// `tintedNeedsBackground`.
    public const string TintedNeedsBackground = "Tinted takes its colors from your Chat Background. Choose one in Appearance › Backgrounds; until then, messages are solid.";

    /// `ThemeSettingsView.desktopChatsNote` (the message box fixed) + the Desktop Look section's own sentence.
    public const string DesktopNote = "How round your messages and the message box are. 4 pt is the desktop app’s. The iOS look has its own Corners, Style and Color, here once the Desktop Look is off.";

    /// The page's footer, paragraph by paragraph.
    public static IReadOnlyList<string> Footer(ThemeState state, bool hasChatBackground)
    {
        if (state.DesktopLook) return [DesktopNote];
        var style = Shown(state.BubbleStyle);
        return (style is BubbleStyle.Tinted or BubbleStyle.Card) && !hasChatBackground ? [Note, TintedNeedsBackground] : [Note];
    }

    /// The corner in DIPs; the slider and its saved value stay in Swift app points.
    public static double MessageCorner(ThemeState state) => state.AppliedBubbleCorners * ChatVisualTokens.Dip;

    /// How bubbles are filled in a chat: the applied style as shown here; Tinted with no Chat Background is solid.
    public static BubbleStyle Drawn(ThemeState state, bool hasChatBackground)
    {
        var style = Shown(state.AppliedBubbleStyle);
        return style == BubbleStyle.Tinted && !hasChatBackground ? BubbleStyle.Solid : style;
    }

    /// Raised when what the chats draw changed (the corner in use, the look, the style): open chats redraw their
    /// messages. The Mac lays every open chat out again on a change.
    public static event Action? Changed;

    /// Raises `Changed` when the bubbles drawn differ between `was` and `now`; true when it did.
    public static bool Notify(ThemeState was, ThemeState now)
    {
        if (was.AppliedBubbleCorners == now.AppliedBubbleCorners && was.DesktopLook == now.DesktopLook
            && was.AppliedBubbleStyle == now.AppliedBubbleStyle && was.AppliedPlainReplies == now.AppliedPlainReplies) return false;
        Changed?.Invoke();
        return true;
    }
}
