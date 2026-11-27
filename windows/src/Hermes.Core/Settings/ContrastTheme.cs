namespace Hermes.Core.Settings;

/// [WIN-CONTRAST-BUBBLE] Which of a Windows contrast theme's colours a fill that carries words takes.
///
/// The Mac keeps every shape, word and order under Increase Contrast and only strengthens the colours: your bubble is
/// still the tint with white words (App/Theme/ThemeTrait.swift `ThemedColor.make`, the bubble's 7:1 in
/// App/Chat/Cells/ChatCells.swift), the picked pill is still `hqTint` under `Theme.pickedPillInk` and the others
/// `hqFill3` under `hqLabel` (App/Sessions/SessionsHeaderView.swift `SessionPill`, App/Pages/Tasks/TaskViewsHeader.swift).
/// Windows' equivalent is a contrast theme, which is the person's own choice of colours: there a fill that carries words
/// is a pair of the theme's system colours (Windows.UI.ViewManagement.UIElementType names), so WinUI's text backplate
/// isn't needed: the tint becomes Highlight with HighlightText on it (your bubble, the picked pill, as WinUI's own
/// selected items), a pill not picked is a button (ButtonFace, ButtonText), and anything else the window's
/// (Window, WindowText).
public static class ContrastTheme
{
    public enum Surface
    {
        /// The page, a card, a reply's words: Window under WindowText.
        Window,
        /// Your message's bubble (and your reaction chips, the Chat Bubbles preview): the Mac's tint under white words.
        UserBubble,
        /// The picked view pill on Tasks (the Mac's `hqTint` fill).
        PickedPill,
        /// A pill not picked, and + New List (the Mac's `hqFill3` under `hqLabel`).
        Pill,
    }

    /// A fill, the words on it and its edge, each a UIElementType name.
    public readonly record struct Colours(string Fill, string Ink, string Edge);

    public static Colours For(Surface surface) => surface switch
    {
        Surface.UserBubble => new("Highlight", "HighlightText", "Highlight"),
        Surface.PickedPill => new("Highlight", "HighlightText", "Highlight"),
        Surface.Pill => new("ButtonFace", "ButtonText", "ButtonText"),
        _ => new("Window", "WindowText", "WindowText"),
    };

    /// A pill's surface.
    public static Surface PillSurface(bool picked) => picked ? Surface.PickedPill : Surface.Pill;

    /// Null when the drawn fill and words (0xRRGGBB, alpha ignored) are the surface's pair in the theme on show
    /// (`system`: UIElementType name → its colour) and the words draw without WinUI's backplate (`backplate` false: their
    /// HighContrastAdjustment is None); else the finding for `what`.
    public static string? Judge(string what, Surface surface, uint fill, uint ink, bool backplate, IReadOnlyDictionary<string, uint> system)
    {
        var want = For(surface);
        var wrong = new List<string>();
        if (!system.TryGetValue(want.Fill, out var f) || (f & 0xFFFFFF) != (fill & 0xFFFFFF))
            wrong.Add($"fill #{fill & 0xFFFFFF:X6} isn't {want.Fill}{(system.TryGetValue(want.Fill, out var wf) ? $" (#{wf & 0xFFFFFF:X6})" : "")}");
        if (!system.TryGetValue(want.Ink, out var i) || (i & 0xFFFFFF) != (ink & 0xFFFFFF))
            wrong.Add($"words #{ink & 0xFFFFFF:X6} aren't {want.Ink}{(system.TryGetValue(want.Ink, out var wi) ? $" (#{wi & 0xFFFFFF:X6})" : "")}");
        if (backplate) wrong.Add("words drawn on the system's backplate");
        return wrong.Count == 0 ? null : $"{what} ({surface}): {string.Join("; ", wrong)}";
    }
}
