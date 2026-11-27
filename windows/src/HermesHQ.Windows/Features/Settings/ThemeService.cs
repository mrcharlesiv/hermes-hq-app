using Hermes.Core.Settings;
using HermesHQ.Features.Transcript;
using HermesHQ.Services;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;
using Windows.UI;

namespace HermesHQ.Features.Settings;

/// The app's palette, in one place (the Mac's Theme.shared + ThemeTable + AppearanceSetting.applyEverywhere): Light or
/// Dark on the window's root (RequestedTheme), the chosen skin, Desktop Look and High Contrast resolved by
/// Hermes.Core.Settings.ThemeResolver into tokens, and those tokens painted into brushes under the WinUI resource keys
/// every page already uses (TextFillColorPrimaryBrush, AccentFillColorDefaultBrush, CardBackgroundFillColorDefaultBrush…)
/// plus the app's own HQ* keys. Each key has one brush object, in both the Light and Dark theme dictionaries, whose
/// colour is the mode on show (and the HQ* keys a brush of their own in HighContrast, the Windows contrast theme's colour). Code
/// looks a brush up through ThemeBrushes.Get (Services/ThemeBrushes.cs), never Application.Current.Resources[…], which
/// resolves in the application's (the system's) theme, not the mode on show [WIN-THEME-APP-RESOURCES]. UI Scale scales the window's content; Ctrl+Plus, Ctrl+Minus and Ctrl+0 step it (the Mac's View › Make Text
/// Bigger / Smaller / Actual Size).
public static class ThemeService
{
    public static ThemeStore Store { get; } = new(FilePreferences.Shared);
    public static ThemeState State { get; private set; } = ThemeState.Default;
    public static ThemeSet Set { get; private set; } = ThemeResolver.Resolve(ThemeState.Default);
    public static AppearanceSetting Chosen { get; private set; } = AppearanceSetting.System;
    /// The mode on show now.
    public static bool Dark { get; private set; }
    public static ThemeTokens Tokens => Set.Tokens(Dark);
    /// After any change (on the UI thread).
    public static event Action? Changed;

    /// Brush keys and the token each paints. The WinUI keys restyle every page; the HQ keys are the app's own palette for
    /// features to draw with (your message, the bot's, code, the sidebar…).
    private static readonly (string Key, Func<ThemeTokens, Hermes.Core.Settings.Rgba> Pick)[] Map =
    [
        ("TextFillColorPrimaryBrush", t => t.Label),
        ("TextFillColorSecondaryBrush", t => t.Label2),
        ("TextFillColorTertiaryBrush", t => t.Label3),
        ("AccentFillColorDefaultBrush", t => t.Tint),
        ("AccentFillColorSecondaryBrush", t => t.Tint.Alpha(0.9)),
        ("AccentFillColorTertiaryBrush", t => t.Tint.Alpha(0.8)),
        ("AccentTextFillColorPrimaryBrush", t => t.TintText),
        ("AccentTextFillColorSecondaryBrush", t => t.TintText),
        ("AccentTextFillColorTertiaryBrush", t => t.TintText.Alpha(0.8)),
        ("TextOnAccentFillColorPrimaryBrush", t => t.OnTint),
        ("ApplicationPageBackgroundThemeBrush", t => t.Page),
        ("SolidBackgroundFillColorBaseBrush", t => t.Page),
        ("LayerFillColorDefaultBrush", t => t.Page),
        ("CardBackgroundFillColorDefaultBrush", t => t.GroupedCard),
        ("CardStrokeColorDefaultBrush", t => t.Separator),
        ("DividerStrokeColorDefaultBrush", t => t.Separator),
        ("SurfaceStrokeColorDefaultBrush", t => t.StrokePrimary),
        ("SystemFillColorCriticalBrush", t => t.Red),
        ("SystemFillColorSuccessBrush", t => t.Green),
        ("SystemFillColorCautionBrush", t => t.Orange),
        // Controls' own keys that are made from the accent inside WinUI's dictionary (a lookup there doesn't see ours).
        ("ToggleSwitchFillOn", t => t.Tint),
        ("ToggleSwitchFillOnPointerOver", t => t.Tint.Alpha(0.9)),
        ("ToggleSwitchFillOnPressed", t => t.Tint.Alpha(0.8)),
        ("ToggleSwitchStrokeOn", t => t.Tint),
        ("ToggleSwitchKnobFillOn", t => t.OnTint),
        ("ToggleSwitchKnobFillOnPointerOver", t => t.OnTint),
        ("ToggleSwitchKnobFillOnPressed", t => t.OnTint),
        ("AccentButtonBackground", t => t.Tint),
        ("AccentButtonBackgroundPointerOver", t => t.Tint.Alpha(0.9)),
        ("AccentButtonBackgroundPressed", t => t.Tint.Alpha(0.8)),
        ("AccentButtonForeground", t => t.OnTint),
        ("AccentButtonForegroundPointerOver", t => t.OnTint),
        ("AccentButtonForegroundPressed", t => t.OnTint),
        ("ToggleButtonBackgroundChecked", t => t.Tint),
        ("ToggleButtonBackgroundCheckedPointerOver", t => t.Tint.Alpha(0.9)),
        ("ToggleButtonBackgroundCheckedPressed", t => t.Tint.Alpha(0.8)),
        ("ToggleButtonForegroundChecked", t => t.OnTint),
        ("ToggleButtonForegroundCheckedPointerOver", t => t.OnTint),
        ("ToggleButtonForegroundCheckedPressed", t => t.OnTint),
        ("RadioButtonOuterEllipseCheckedStroke", t => t.Tint),
        ("RadioButtonOuterEllipseCheckedFill", t => t.Tint),
        ("RadioButtonOuterEllipseCheckedStrokePointerOver", t => t.Tint.Alpha(0.9)),
        ("RadioButtonOuterEllipseCheckedFillPointerOver", t => t.Tint.Alpha(0.9)),
        ("CheckBoxCheckBackgroundFillChecked", t => t.Tint),
        ("CheckBoxCheckBackgroundStrokeChecked", t => t.Tint),
        ("CheckBoxCheckGlyphForegroundChecked", t => t.OnTint),
        ("HyperlinkButtonForeground", t => t.TintText),
        ("HyperlinkButtonForegroundPointerOver", t => t.TintText.Alpha(0.8)),
        ("ListViewItemSelectionIndicatorBrush", t => t.Tint),
        ("HQPageBrush", t => t.Page),
        ("HQSidebarBrush", t => t.Sidebar),
        // [WIN-ROW-FACE-RING-PANEL] The Mac sidebar's panel: what a sidebar face's badges are ringed in.
        ("HQSidebarPanelBrush", t => t.SidebarPanel),
        ("HQGroupedBrush", t => t.Grouped),
        ("HQCardBrush", t => t.GroupedCard),
        ("HQLabelBrush", t => t.Label),
        ("HQLabel2Brush", t => t.Label2),
        ("HQLabel3Brush", t => t.Label3),
        ("HQTintBrush", t => t.Tint),
        ("HQTintTextBrush", t => t.TintText),
        ("HQOnTintBrush", t => t.OnTint),
        ("HQSeparatorBrush", t => t.Separator),
        ("HQSettingsPaneLineBrush", t => SettingsColumnLayout.PaneLine(t, State.DesktopLook, Dark)),
        ("HQSettingsMarkBrush", t => Hermes.Core.Shell.DesktopLook.Accent(t.ChosenRow, Dark)),
        ("HQSettingsFieldBrush", t => t.Fill3),
        ("HQChosenRowBrush", t => t.ChosenRow.Alpha(t.ChosenRow.A * 0.22)),
        ("HQPressedBrush", t => t.CellPressed),
        ("HQBotBubbleBrush", t => t.BotBubble),
        ("HQReplyFillBrush", t => t.ReplyFill),
        ("HQReplyEdgeBrush", t => t.ReplyEdge),
        ("HQPromptCardBrush", t => t.PromptCard),
        ("HQPromptEdgeBrush", t => t.PromptEdge),
        ("HQMeBubbleBrush", t => t.MeBubble),
        ("HQMeTextBrush", t => t.MeText),
        ("HQMeTimeBrush", t => t.MeTime),
        ("HQMeBorderBrush", t => t.MeBorder),
        ("HQCodeFillBrush", t => t.CodeFill),
        ("HQCodeTextBrush", t => t.CodeText),
        ("HQEditorBrush", t => t.Editor),
        ("HQRedBrush", t => t.Red),
        ("HQGreenBrush", t => t.Green),
        ("HQOrangeBrush", t => t.Orange),
    ];

    private static readonly Dictionary<string, SolidColorBrush> Brushes = [];
    private static FrameworkElement? _root;
    private static Frame? _content;
    private static bool _paintedRoot;

    /// In App's constructor (the only time Application.RequestedTheme can be set): the saved Light or Dark, so pages and
    /// dialogs that look a resource up by key in code start in the right mode.
    public static void ApplyStartupTheme(Application app)
    {
        var skin = new ThemeStore(FilePreferences.Shared).Load().Skin;
        switch (Appearance.ForcedBy(skin) ?? Appearance.Read(FilePreferences.Shared))
        {
            case AppearanceSetting.Dark: app.RequestedTheme = ApplicationTheme.Dark; break;
            case AppearanceSetting.Light: app.RequestedTheme = ApplicationTheme.Light; break;
        }
    }

    /// At startup, before the window is made: the brushes exist under their keys before any page looks them up.
    public static void Install()
    {
        Store.Migrate();
        // [working-ring] The switch reads and writes the same file as the rest of Appearance.
        WorkingRing.Store = FilePreferences.Shared;
        ThinkingBarRow.Store = FilePreferences.Shared;
        ChatsUnderBotsRow.Store = FilePreferences.Shared;
        State = Store.Load();
        Chosen = Appearance.Read(FilePreferences.Shared);
        Set = ThemeResolver.Resolve(State);
        Dark = Application.Current.RequestedTheme == ApplicationTheme.Dark;
        var resources = Application.Current.Resources;
        var light = ThemeDictionary(resources, "Light");
        var dark = ThemeDictionary(resources, "Dark");
        // [WIN-60] Under a Windows contrast theme WinUI looks keys up in "HighContrast": without it the app's own HQ*
        // brushes weren't found there. Each has its own brush there, painted the theme's colour
        // (Hermes.Core.Shell.HighContrastWalkProof.Palette); WinUI's keys keep WinUI's own contrast values.
        var contrast = ThemeDictionary(resources, "HighContrast");
        foreach (var (key, _) in Map)
        {
            var brush = new SolidColorBrush();
            Brushes[key] = brush;
            light[key] = brush;
            dark[key] = brush;
            if (Hermes.Core.Shell.HighContrastWalkProof.SystemColourFor(key) is { } element)
            {
                var inContrast = new SolidColorBrush();
                ContrastBrushes[key] = (inContrast, Enum.Parse<Windows.UI.ViewManagement.UIElementType>(element));
                contrast[key] = inContrast;
            }
        }
        Paint();
    }

    private static readonly Dictionary<string, (SolidColorBrush Brush, Windows.UI.ViewManagement.UIElementType Element)> ContrastBrushes = [];
    // Made on first use, never in the type's initializer (ApplyStartupTheme runs in App's constructor).
    private static Windows.UI.ViewManagement.UISettings? _systemColours;
    private static Windows.UI.ViewManagement.UISettings SystemColours => _systemColours ??= new();

    // At the first accessibility category UIKit's .body is 28 pt vs 17 at .large. Map that
    // ratio to Windows' text-size factor for the 90%-width outgoing bubble; UI Scale is separate.
    internal static bool AccessibilityTextSize
    {
        get { try { return SystemColours.TextScaleFactor >= 28d / 17; } catch { return false; } }
    }

    /// Is a Windows contrast theme on (Settings › Accessibility › Contrast themes)? Read through SystemParametersInfo
    /// (SPI_GETHIGHCONTRAST, HCF_HIGHCONTRASTON), not a WinRT AccessibilitySettings: with one made for the Tasks rows the
    /// app ended every CI run in a stowed exception (0xC000027B) after Application.Exit (runs 45023549767, 45026381364).
    public static bool SystemHighContrast
    {
        get
        {
            var hc = new HighContrastInfo { Size = (uint)System.Runtime.InteropServices.Marshal.SizeOf<HighContrastInfo>() };
            if (SystemParametersInfo(SpiGetHighContrast, hc.Size, ref hc, 0)) return (hc.Flags & HcfHighContrastOn) != 0;
            AppLog.Note("settings", $"contrast theme not read: error {System.Runtime.InteropServices.Marshal.GetLastWin32Error()}");
            return false;
        }
    }

    private const uint SpiGetHighContrast = 0x0042, HcfHighContrastOn = 0x1;

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private struct HighContrastInfo
    {
        public uint Size;
        public uint Flags;
        public IntPtr DefaultScheme;
    }

    [System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
    private static extern bool SystemParametersInfo(uint action, uint param, ref HighContrastInfo info, uint winIni);

    /// [WIN-60] Words in a colour of their own (a task's tone, a priority): that colour, or under a Windows contrast
    /// theme the theme's text colour, as WinUI's own coloured text turns plain there.
    public static Brush Ink(Color colour)
    {
        if (!SystemHighContrast) return new SolidColorBrush(colour);
        try { return new SolidColorBrush(SystemColours.UIElementColor(Windows.UI.ViewManagement.UIElementType.WindowText)); }
        catch (Exception x) { AppLog.Note("settings", $"contrast text colour not read: {x.GetType().Name}"); return new SolidColorBrush(colour); }
    }

    private static ResourceDictionary ThemeDictionary(ResourceDictionary resources, string theme)
    {
        if (resources.ThemeDictionaries.TryGetValue(theme, out var found) && found is ResourceDictionary d) return d;
        var made = new ResourceDictionary();
        resources.ThemeDictionaries[theme] = made;
        return made;
    }

    /// Once the window is up: Light or Dark on its root, the system's mode followed, UI Scale and its keys.
    public static void Attach(Window window)
    {
        if (window.Content is not FrameworkElement root || _root == root) return;
        _root = root;
        _content = (root as Panel)?.Children.OfType<Frame>().FirstOrDefault();
        root.ActualThemeChanged += (_, _) => { if (!AppShutdown.Stopping) Refresh(); };
        root.SizeChanged += (_, _) => { if (!AppShutdown.Stopping) ApplyScale(); };
        AddKey(root, (VirtualKey)187, +1); // Ctrl+= / Ctrl++ (VK_OEM_PLUS)
        AddKey(root, VirtualKey.Add, +1);
        AddKey(root, (VirtualKey)189, -1); // Ctrl+- (VK_OEM_MINUS)
        AddKey(root, VirtualKey.Subtract, -1);
        AddKey(root, VirtualKey.Number0, 0);
        Refresh();
    }

    private static void AddKey(UIElement root, VirtualKey key, int by)
    {
        var a = new KeyboardAccelerator { Key = key, Modifiers = VirtualKeyModifiers.Control };
        a.Invoked += (_, e) =>
        {
            if (ThemeStore.StepScale(State.UiScalePercent, by) is { } next && next != State.UiScalePercent)
            {
                SetUiScale(next);
                e.Handled = true;
            }
        };
        root.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        root.KeyboardAccelerators.Add(a);
    }

    // ---------------------------------------------------------------- changes (Settings writes through these)

    public static void SetAppearance(AppearanceSetting value)
    {
        Appearance.Write(FilePreferences.Shared, value);
        Chosen = value;
        AppLog.Note("settings", $"appearance {value}");
        Refresh();
    }

    public static void PickSkin(string id)
    {
        Store.PickSkin(id);
        AppLog.Note("settings", $"theme {id}");
        Reload();
    }

    public static void SetDesktopLook(bool on)
    {
        Store.SetDesktopLook(on);
        AppLog.Note("settings", $"desktop look {(on ? "on" : "off")}");
        Reload();
    }

    public static void SetHighContrast(bool on)
    {
        Store.SetHighContrast(on);
        Reload();
    }

    public static void SetUiScale(int percent)
    {
        Store.SetUiScale(percent);
        AppLog.Note("settings", $"ui scale {percent}");
        Reload();
    }

    /// [density] Theme › Density: the lists draw their rows again at once (`DensitySizes.Changed`).
    public static void SetDensity(ListDensity density)
    {
        Store.SetDensity(density);
        AppLog.Note("settings", $"density {density.Raw()}");
        Reload();
    }

    /// [theme-pages] Chat Bubbles › Corners: the look in use's own corner (`Theme.setBubbleCorners`). Open chats redraw
    /// their messages (`ChatBubbles.Changed`).
    public static void SetBubbleCorners(int points)
    {
        ChatBubbles.SetCorners(Store, State, points);
        AppLog.Note("settings", $"bubble corners {points}{(State.DesktopLook ? " desktop" : "")}");
        Reload();
    }

    /// [tinted-bubbles] Chat Bubbles › Tinted (the iOS look).
    public static void SetBubbleStyle(BubbleStyle style)
    {
        Store.SetBubbleStyle(style);
        AppLog.Note("settings", $"bubble style {style.Raw()}");
        Reload();
    }

    private static void Reload()
    {
        var was = State;
        State = Store.Load();
        Set = ThemeResolver.Resolve(State);
        Refresh();
        // [density] Density picked, or the Desktop Look turned on or off over Compact.
        DensitySizes.Notify(was, State);
        // [theme-pages] The corner or style your messages draw with moved (or the look did): open chats redraw them.
        ChatBubbles.Notify(was, State);
    }

    /// Paints everything for the state and mode now.
    public static void Refresh()
    {
        if (_root != null)
        {
            var forced = Appearance.ForcedBy(State.Skin) ?? Chosen;
            _root.RequestedTheme = forced switch
            {
                AppearanceSetting.Dark => ElementTheme.Dark,
                AppearanceSetting.Light => ElementTheme.Light,
                _ => ElementTheme.Default,
            };
            Dark = _root.ActualTheme == ElementTheme.Dark;
        }
        Paint();
        // [WIN-THEME-APP-RESOURCES] The shots' ground in the mode on show, before the window is painted over it.
        if (Automation.Enabled) Automation.PaintShotGround(Dark);
        PaintWindow();
        ApplyScale();
        Changed?.Invoke();
    }

    private static void Paint()
    {
        var tokens = Set.Tokens(Dark);
        foreach (var (key, pick) in Map) Brushes[key].Color = ToColor(pick(tokens));
        RefreshContrastBrushes();
        try { Application.Current.Resources["BubbleCorner"] = new CornerRadius(State.AppliedBubbleCorners); }
        catch (Exception x) { AppLog.Note("settings", $"bubble corner not set: {x.GetType().Name}"); }
    }

    // Settings can receive an OS colour change without a change to the app theme or its scale.
    internal static void RefreshContrastBrushes()
    {
        foreach (var (brush, element) in ContrastBrushes.Values)
        {
            try { brush.Color = SystemColours.UIElementColor(element); }
            catch (Exception x) { AppLog.Note("settings", $"contrast colour {element} not read: {x.GetType().Name}"); }
        }
    }

    /// The window around the pages: a skin paints the sidebar's ground (the standard look keeps Mica); the caption
    /// buttons take the text colour; the Desktop Look draws a skin's own typeface.
    private static void PaintWindow()
    {
        if (_root is Panel panel)
        {
            if (!Set.IsStandardLook)
            {
                panel.Background = Brushes["HQSidebarBrush"];
                _paintedRoot = true;
            }
            else if (_paintedRoot)
            {
                panel.Background = Automation.Enabled ? Automation.ShotBackground() : null;
                _paintedRoot = false;
            }
        }
        if (_content != null)
        {
            if (State.DesktopLook && State.Skin.SansFamily is { } family) _content.FontFamily = new FontFamily(family);
            else _content.ClearValue(Control.FontFamilyProperty);
        }
        if (App.Window?.AppWindow.TitleBar is { } bar)
        {
            var ink = ToColor(Set.Tokens(Dark).Label);
            bar.ButtonForegroundColor = ink;
            bar.ButtonHoverForegroundColor = ink;
            bar.ButtonInactiveForegroundColor = ToColor(Set.Tokens(Dark).Label3);
            bar.ButtonBackgroundColor = Colors.Transparent;
            bar.ButtonInactiveBackgroundColor = Colors.Transparent;
        }
    }

    /// UI Scale: the window's content laid out at 1/scale of the room and scaled up to fill it, so text, faces and
    /// rows all grow together and nothing is cut off.
    private static void ApplyScale()
    {
        if (_content == null || _root is not Grid grid) return;
        var scale = State.Scale;
        if (Math.Abs(scale - 1) < 0.001)
        {
            if (_content.RenderTransform is ScaleTransform)
            {
                _content.RenderTransform = null;
                _content.ClearValue(FrameworkElement.WidthProperty);
                _content.ClearValue(FrameworkElement.HeightProperty);
                _content.HorizontalAlignment = HorizontalAlignment.Stretch;
                _content.VerticalAlignment = VerticalAlignment.Stretch;
                _content.ClearValue(FrameworkElement.MarginProperty);
            }
            return;
        }
        var row = Grid.GetRow(_content);
        var height = grid.RowDefinitions.Count > row ? grid.RowDefinitions[row].ActualHeight : grid.ActualHeight;
        if (grid.ActualWidth <= 0 || height <= 0) return;
        _content.HorizontalAlignment = HorizontalAlignment.Left;
        _content.VerticalAlignment = VerticalAlignment.Top;
        _content.Width = grid.ActualWidth / scale;
        _content.Height = height / scale;
        // Below 100 % the content is laid out larger than its cell: a negative margin widens the slot, so nothing is
        // clipped to the cell before it is scaled down into it.
        _content.Margin = new Thickness(0, 0, Math.Min(0, grid.ActualWidth - grid.ActualWidth / scale), Math.Min(0, height - height / scale));
        _content.RenderTransform = new ScaleTransform { ScaleX = scale, ScaleY = scale };
    }

    public static Color ToColor(Hermes.Core.Settings.Rgba c) =>
        Color.FromArgb(Hermes.Core.Settings.Rgba.Byte(c.A), Hermes.Core.Settings.Rgba.Byte(c.R), Hermes.Core.Settings.Rgba.Byte(c.G),
            Hermes.Core.Settings.Rgba.Byte(c.B));

    /// A brush of the palette by its key (one object per key; its colour follows the theme).
    public static Brush BrushFor(string key) => ThemeBrushes.Get(key);

    /// The brush this paints under `key` (one object, coloured for the mode on show), if it paints that key.
    /// [WIN-CONTRAST-BUBBLE] Under a Windows contrast theme an HQ* key is its brush in the theme's colour (the one in the
    /// HighContrast dictionary, as `{ThemeResource}` gives in markup) and a WinUI key this paints is left to WinUI's own
    /// contrast value (null: ThemeBrushes looks it up): before, code got the skin's brush there, so your bubble kept the
    /// accent blue under a contrast theme (CI run 45171524778, high-contrast/02-high-contrast-chat.png).
    public static Brush? Painted(string key)
    {
        if (!Brushes.TryGetValue(key, out var b)) return null;
        if (!SystemHighContrast) return b;
        return ContrastBrushes.TryGetValue(key, out var inContrast) ? inContrast.Brush : null;
    }

    /// [WIN-CONTRAST-BUBBLE] One of the contrast theme's colours by its UIElementType name (Hermes.Core.Settings
    /// ContrastTheme), as a brush; null when Windows won't say.
    public static SolidColorBrush? SystemBrush(string element)
    {
        try { return new SolidColorBrush(SystemColours.UIElementColor(Enum.Parse<Windows.UI.ViewManagement.UIElementType>(element))); }
        catch (Exception x) { AppLog.Note("settings", $"contrast colour {element} not read: {x.GetType().Name}"); return null; }
    }

    /// [WIN-CONTRAST-BUBBLE] Words on a fill of the contrast theme's own pair: drawn in that pair, without WinUI's
    /// backplate (which would draw them WindowText on Window over the fill). Nothing changes without a contrast theme.
    public static void ContrastWords(UIElement words)
    {
        if (SystemHighContrast) words.HighContrastAdjustment = ElementHighContrastAdjustment.None;
    }
}
