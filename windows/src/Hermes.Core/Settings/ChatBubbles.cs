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
    /// [plain-replies] Chat Bubbles › Reply Bubbles (`1a1f7200d`, ThemeSettingsView.swift `replyBubblesRow`).
    public const string ReplyBubblesLabel = "Reply Bubbles";
    public const string ReplyBubblesId = "theme.replyBubbles";
    public const string ReplyBubblesNoteId = "theme.replyBubblesNote";
    public const string ReplyBubblesNote = "Off: a bot’s replies have no bubble. Their words go the full width of the chat, straight on the page. Your own messages keep theirs.";
    public const string HermesPlainRepliesNote = "Hermes Look draws replies straight on the page unless High Contrast is on.";

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

    /// The row's value: Hermes Look's effective corner, or the shown style.
    public static string Value(ThemeState state) => state.DesktopLook ? CornersValue(state.AppliedDesktopCorners) : Shown(state.BubbleStyle).Title();

    /// The look in use's corner (the slider's value).
    public static int Corners(ThemeState state) => state.DesktopLook ? state.AppliedDesktopCorners : state.BubbleCorners;
    /// The Reset target for Corners in the current look (12 pt in Native Look, or `DesktopRadius` in Hermes Look).
    public static int StandardCorners(ThemeState state) =>
        state.DesktopLook ? (int)Math.Round(state.DesktopRadius, MidpointRounding.AwayFromZero) : ThemeState.DefaultBubbleCorners;
    public static string CornersValue(int points) => $"{points} pt";
    public static string CornersSpoken(int points) => $"{points} points";

    /// Style is Native Look's (Hermes Look keeps its own boxes).
    public static bool ShowsStyle(ThemeState state) => !state.DesktopLook;

    /// True when the active skin draws replies straight on the page (e.g. Paper), so Reply Bubbles is synced off.
    public static bool SkinDrawsPlainReplies(ThemeState state, bool dark = false)
    {
        var own = state.Skin.OwnLook?.Pick(dark);
        return own != null && own.Reply == own.Page;
    }

    public static string SkinPlainRepliesNote(Skin skin) => $"{skin.Label} draws replies straight on the page.";

    /// Disabled explanation shown beneath Reply Bubbles when the look or skin already draws plain replies; null when interactive.
    public static string? ReplyBubblesDisabledNote(ThemeState state, bool dark = false)
    {
        if (state.DesktopLook)
            return state.ContrastApplies ? null : HermesPlainRepliesNote;
        return SkinDrawsPlainReplies(state, dark) ? SkinPlainRepliesNote(state.Skin) : null;
    }

    public static bool ReplyBubblesEnabled(ThemeState state, bool dark = false) => ReplyBubblesDisabledNote(state, dark) == null;

    /// Toggle visual state for Reply Bubbles (`!forcedPlain && !state.PlainReplies`, ThemeSettingsView.swift:277).
    public static bool ReplyBubblesOn(ThemeState state, bool dark = false) => ReplyBubblesEnabled(state, dark) && !state.PlainReplies;

    /// `Theme.setBubbleCorners`: the slider writes the look in use's corner.
    public static void SetCorners(ThemeStore store, ThemeState state, int points) => store.SetBubbleCorners(points, desktop: state.DesktopLook);

    /// `ChatBubblesSettingsView.note` where glass isn't offered.
    public static string Note =>
        $"How round the corners of messages in chats are, and whether they’re Tinted with the colors of your Chat Background. 12 pt is the standard. With Reduce Transparency on, messages stay solid. The Hermes Look has its own Corners, here once it is on. {Gateways.DeviceWord.OnlyHere}";

    /// `tintedNeedsBackground`.
    public const string TintedNeedsBackground = "Tinted takes its colors from your Chat Background. Choose one in Appearance › Backgrounds; until then, messages are solid.";

    /// `ThemeSettingsView.desktopChatsNote` (the message box fixed) for Hermes Look.
    public const string DesktopNote = "How round your messages and the text box are. Follows Hermes Look’s Corners (4 pt) unless changed here. Native Look has its own Corners, Style and Color, here once Hermes Look is off.";

    /// Dynamic Hermes Look note reflecting the active `DesktopRadius`.
    public static string DesktopNoteFor(ThemeState state) =>
        $"How round your messages and the text box are. Follows Hermes Look’s Corners ({(int)Math.Round(state.DesktopRadius, MidpointRounding.AwayFromZero)} pt) unless changed here.";

    /// The page's footer, paragraph by paragraph.
    public static IReadOnlyList<string> Footer(ThemeState state, bool hasChatBackground)
    {
        if (state.DesktopLook)
            return [Math.Abs(state.DesktopRadius - ThemeState.DefaultDesktopRadius) < 0.001 ? DesktopNote : DesktopNoteFor(state)];
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
            && was.AppliedBubbleStyle == now.AppliedBubbleStyle && was.AppliedPlainReplies == now.AppliedPlainReplies
            && Math.Abs(was.AppliedDesktopRadius - now.AppliedDesktopRadius) < 0.001) return false;
        Changed?.Invoke();
        return true;
    }
}
