using Hermes.Core.Settings;

namespace Hermes.Core.Shell;

/// What the Mac does with one kind of words when the text is larger: in `Area`, words Windows lets run onto more lines
/// (`Wraps`) or keeps to one line or a line limit; whether the Mac cuts them short there (`MacTruncates`), what they are
/// and the Swift that says so.
public sealed record CutRule(string Area, bool Wraps, bool MacTruncates, string What, string Swift);

/// A TextBlock the walk found cut short (TextBlock.IsTextTrimmed): its area, its key (its own x:Name or automation id,
/// else its nearest ancestor's), whether it wraps (TextWrapping on and no MaxLines), its MaxLines and its length. Never
/// its words: a message's text stays out of the log.
public sealed record CutText(string Area, string Key, bool Wraps, int MaxLines, int Length);

/// [WIN-60] Larger text on Windows, judged against the Mac. The Mac follows the system's text size (Dynamic Type,
/// `adjustsFontForContentSizeCategory`, `preferredContentSizeCategory`); WinUI follows Settings › Accessibility › Text
/// size (UISettings.TextScaleFactor) in every TextBlock and TextBox unless IsTextScaleFactorEnabled is turned off (the
/// source test TextScaleWalkTests.NoTextTurnsWindowsTextScalingOff keeps it on). The "text-scale" walk (HermesHQ.Windows
/// Services/ProofWalks.TextScale.cs) runs with TextScaleFactor=150 set on the CI runner, opens Chats, Tasks and Settings
/// and judges every TextBlock cut short by these rules: one-line words cut short where the Mac cuts them too pass;
/// running words cut short (a fixed size clipping them) fail, as the Mac wraps them whole.
///
/// 1.5 is below the Mac's first accessibility size (AX1, body 28 pt against the default 17 pt, 1.65×), so the Mac's
/// `large` branches (`preferredContentSizeCategory.isAccessibilityCategory`) are not taken: the rules are the Mac's
/// ordinary ones.
public static class TextScaleWalkProof
{
    /// The value the CI writes to HKCU\Software\Microsoft\Accessibility TextScaleFactor (a percentage).
    public const int RegistryPercent = 150;
    public const double Factor = RegistryPercent / 100.0;

    public const string Sidebar = "sidebar";
    public const string Chat = "chat";
    public const string Transcript = "transcript";
    public const string Tasks = "tasks";
    public const string Settings = "settings";
    public static readonly string[] Areas = [Sidebar, Chat, Transcript, Tasks, Settings];

    /// The pages the walk must visit, in order, and their shots.
    public static readonly string[] Pages = ["Chats", "Tasks", "Settings"];
    public static readonly string[] Shots = ["text-scale-chat", "text-scale-tasks", "text-scale-settings"];
    /// [WIN-FOOTER-GATEWAY-CLIP] After the three pages: the sidebar's foot at this text size, at the sidebar's narrowest
    /// open width (SidebarLayout.NarrowestOpen), the gateway's name judged by Hermes.Core.Gateways.GatewayFootFit.Judge
    /// at the kept width and at the narrowest, and its shot taken there. A clip there isn't IsTextTrimmed, so the
    /// TextBlock pass alone never saw it.
    public const string FootShot = "text-scale-foot";

    public static readonly CutRule[] Rules =
    [
        // The sidebar's rows: a bot's name and status, a chat's title and line all end in "…" on the Mac.
        new(Sidebar, false, true, "a sidebar row's name, status or line",
            "App/Mac/MacBotsRail.swift `name.lineBreakMode = .byTruncatingTail` / `status.lineBreakMode = .byTruncatingTail`"),
        // The chat's header (its name) and the composer's chips.
        new(Chat, false, true, "the chat's name in its header, a chip by the message box",
            "App/Chat/ChatChrome.swift `nameLabel.lineBreakMode = .byTruncatingTail`"),
        new(Chat, true, false, "the chat's running words (a note, a placeholder)",
            "App/Chat/ChatChrome.swift `label.numberOfLines = lines` (\"`lines` 0 wraps\")"),
        // The transcript: a step's title and a sender's name are cut; a message's words wrap at the bubble's width.
        new(Transcript, false, true, "a step's title, a sender's name, a code preview's line",
            "App/Chat/Cells/ChatCells.swift `title.lineBreakMode = .byTruncatingTail`"),
        new(Transcript, true, false, "a message's words",
            "App/Chat/Cells/ChatTextViews.swift `/// Draws one piece of laid-out text … Redraws only when its text or width changes`"),
        // Tasks: a task's name runs to two lines (four at the largest sizes); the bot's line under it is one line.
        new(Tasks, true, false, "a task's name",
            "App/Pages/Tasks/TaskRowViews.swift `.lineLimit(large ? 4 : 2)`"),
        new(Tasks, false, true, "a task's bot line, its date, a goal's line",
            "App/Pages/Tasks/TaskRowViews.swift `.lineLimit(large ? nil : 1)`"),
        // Settings: a row's title and note wrap; a value beside its button is one line, cut in the middle.
        new(Settings, true, false, "a setting's title or note",
            "App/Settings/Config/SettingsComponents.swift `Text(title).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)`"),
        new(Settings, false, true, "a setting's value, a gateway's host",
            "App/Settings/Config/MacForm.swift `.lineLimit(1)` `.truncationMode(.middle)`"),
    ];

    /// Null when TextScaleFactor is 1.5, else what Windows gave.
    public static string? Scale(double factor) =>
        Math.Abs(factor - Factor) < 0.001 ? null
        : $"UISettings.TextScaleFactor is {factor:0.##}, not 1.5: Windows didn't take TextScaleFactor={RegistryPercent}";

    /// The rule for words in `area` that wrap (or keep to a line or a limit).
    public static CutRule? RuleFor(string area, bool wraps) => Rules.FirstOrDefault(r => r.Area == area && r.Wraps == wraps);

    /// Null when `cut` is cut short where the Mac cuts it too, else why it fails. A line limit (MaxLines) counts as a cut
    /// the text was made to take, as the Mac's numberOfLines and lineLimit do.
    public static string? Judge(CutText cut)
    {
        var wraps = cut.Wraps && cut.MaxLines == 0;
        if (RuleFor(cut.Area, wraps) is not { } rule)
            return $"{cut.Area} · {Key(cut)} · {(wraps ? "wrapping" : "one-line")} text cut short ({cut.Length} characters): no Mac rule for it";
        if (rule.MacTruncates) return null;
        return $"{cut.Area} · {Key(cut)} · {rule.What} cut short ({cut.Length} characters, a fixed size clips it): the Mac wraps it ({rule.Swift})";
    }

    /// Null when every page was visited and nothing is cut short where the Mac wraps it, else all that is wrong.
    public static string? Report(IReadOnlyList<CutText> cut, IReadOnlyList<string> visited)
    {
        var wrong = cut.Select(Judge).OfType<string>().ToList();
        var missed = Pages.Where(p => !visited.Contains(p)).Select(p => $"{p} was never visited").ToList();
        if (wrong.Count == 0 && missed.Count == 0) return null;
        var lines = new List<string>();
        if (wrong.Count > 0) lines.Add($"{wrong.Count} text{(wrong.Count == 1 ? "" : "s")} cut short at {RegistryPercent} % where the Mac wraps {(wrong.Count == 1 ? "it" : "them")}:");
        lines.AddRange(wrong);
        lines.AddRange(missed);
        return string.Join("\n", lines);
    }

    private static string Key(CutText cut) => cut.Key.Length == 0 ? "(unnamed)" : cut.Key;
}

/// [WIN-60] High contrast on Windows. The Mac follows Increase Contrast (`traitCollection.accessibilityContrast == .high`,
/// App/Chat/Cells/ChatCells.swift: its bubbles' tint is taken to a 7:1 ratio); Windows' counterpart is a contrast theme
/// (Settings › Accessibility › Contrast themes), under which WinUI draws its own controls in the theme's eight colours from
/// the "HighContrast" theme dictionary. The app's own brushes (ThemeService's "HQ…Brush" keys) must be in that dictionary
/// too, each one of those colours, and no text may keep a colour of its own. The "high-contrast" walk (HermesHQ.Windows
/// Services/ProofWalks.TextScale.cs) checks both on Chats, Tasks and Settings while the CI runner has a contrast theme on.
public static class HighContrastWalkProof
{
    /// Windows' contrast colours (Windows.UI.ViewManagement.UIElementType).
    public static readonly string[] SystemColours = ["ButtonFace", "ButtonText", "GrayText", "Highlight", "HighlightText", "Hotlight", "Window", "WindowText"];

    public static readonly string[] Shots = ["high-contrast-chat", "high-contrast-tasks", "high-contrast-settings"];

    /// Each of the app's own brushes under a contrast theme: grounds are Window, words and rules WindowText, the tint
    /// Highlight with HighlightText on it, a link's tint Hotlight. Coloured words (red, green, orange) are plain text there,
    /// as WinUI's own SystemFillColorCritical/Success/Caution are.
    public static readonly (string Key, string Element)[] Palette =
    [
        ("HQPageBrush", "Window"), ("HQSidebarBrush", "Window"), ("HQSidebarPanelBrush", "Window"), ("HQGroupedBrush", "Window"), ("HQCardBrush", "Window"),
        ("HQLabelBrush", "WindowText"), ("HQLabel2Brush", "WindowText"), ("HQLabel3Brush", "WindowText"),
        ("HQTintBrush", "Highlight"), ("HQTintTextBrush", "Hotlight"), ("HQOnTintBrush", "HighlightText"),
        ("HQSeparatorBrush", "WindowText"), ("HQChosenRowBrush", "Highlight"), ("HQPressedBrush", "Highlight"),
        ("HQSettingsPaneLineBrush", "WindowText"), ("HQSettingsMarkBrush", "Highlight"), ("HQSettingsFieldBrush", "Window"),
        // [WIN-CONTRAST-BUBBLE] Your bubble is the Mac's tint under white words: the theme's Highlight pair
        // (Hermes.Core.Settings.ContrastTheme, UserBubble), its edge the fill.
        ("HQBotBubbleBrush", "Window"),
        ("HQReplyFillBrush", ContrastTheme.For(ContrastTheme.Surface.Window).Fill),
        ("HQReplyEdgeBrush", ContrastTheme.For(ContrastTheme.Surface.Window).Edge),
        ("HQPromptCardBrush", ContrastTheme.For(ContrastTheme.Surface.Window).Fill),
        ("HQPromptEdgeBrush", ContrastTheme.For(ContrastTheme.Surface.Window).Edge),
        ("HQMeBubbleBrush", ContrastTheme.For(ContrastTheme.Surface.UserBubble).Fill),
        ("HQMeTextBrush", ContrastTheme.For(ContrastTheme.Surface.UserBubble).Ink),
        ("HQMeTimeBrush", ContrastTheme.For(ContrastTheme.Surface.UserBubble).Ink),
        ("HQMeBorderBrush", ContrastTheme.For(ContrastTheme.Surface.UserBubble).Edge),
        ("HQCodeFillBrush", "Window"), ("HQCodeTextBrush", "WindowText"), ("HQEditorBrush", "Window"),
        ("HQWhisperLineBrush", "WindowText"), ("HQFrostedBarBrush", "Window"),
        ("HQGlassVeilBrush", "Window"), ("HQGlassCanvasSurfaceBrush", "Window"), ("HQGlassCanvasBorderBrush", "WindowText"),
        ("HQRedBrush", "WindowText"), ("HQGreenBrush", "WindowText"), ("HQOrangeBrush", "WindowText"),
    ];

    /// The contrast colour (a UIElementType name) the brush `key` takes, or null for a key with none.
    public static string? SystemColourFor(string key) => Palette.FirstOrDefault(p => p.Key == key).Element;

    /// Null when Windows has a contrast theme on, else why the walk can't judge.
    public static string? On(bool highContrast) =>
        highContrast ? null : "SPI_GETHIGHCONTRAST is off: Windows didn't switch to a contrast theme";

    /// Null when the text's ink (0xRRGGBB, alpha ignored) is one of the theme's colours `system`, else the finding.
    public static string? Ink(string page, string key, uint rgb, IReadOnlyCollection<uint> system) =>
        system.Any(s => (s & 0xFFFFFF) == (rgb & 0xFFFFFF)) ? null
        : $"{page} · {(key.Length == 0 ? "(unnamed)" : key)} · ink #{rgb & 0xFFFFFF:X6} isn't a contrast theme colour";

    public static string? Report(IReadOnlyList<string> findings, IReadOnlyList<string> visited)
    {
        var missed = TextScaleWalkProof.Pages.Where(p => !visited.Contains(p)).Select(p => $"{p} was never visited").ToList();
        if (findings.Count == 0 && missed.Count == 0) return null;
        var lines = new List<string>();
        if (findings.Count > 0) lines.Add($"{findings.Count} text{(findings.Count == 1 ? "" : "s")} drawn in {(findings.Count == 1 ? "its" : "their")} own colour under a contrast theme:");
        lines.AddRange(findings);
        lines.AddRange(missed);
        return string.Join("\n", lines);
    }
}
