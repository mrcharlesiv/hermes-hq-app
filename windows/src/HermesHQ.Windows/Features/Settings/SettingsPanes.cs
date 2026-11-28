using Hermes.Core.Gateways;
using Hermes.Core.Settings;
using Hermes.Core.Shell;
using Hermes.Core.Transcripts;
using Hermes.Core.Updates;
using HermesHQ.Features.Attachments;
using HermesHQ.Features.Gateways;
using HermesHQ.Features.Transcript;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;

namespace HermesHQ.Features.Settings;

/// Where other features add to Settings' pages without editing them: the notifications feature's rows (Send Test
/// Notification, the add-on), the voice feature's (Voice Model, Live Words, Voice Diagnostics). Each makes its card when
/// the page is drawn; null leaves it out.
public static class SettingsHooks
{
    /// Cards under Notifications' switches.
    public static readonly List<Func<FrameworkElement?>> Notifications = [];
    /// Cards under Voice's switches.
    public static readonly List<Func<FrameworkElement?>> Voice = [];
    public static readonly List<Func<FrameworkElement?>> Sidebar = [];
}

/// Settings' pages (SettingsRootView's categories in two columns, and the pages their rows open), in the Mac's words.
internal static class SettingsPanes
{
    private static IPreferences Prefs => FilePreferences.Shared;

    // Segoe Fluent glyphs for the Mac's SF Symbols.
    private const string GBell = "", GHalf = "", GPalette = "", GDesktop = "", GText = "",
        GWrench = "", GClock = "", GClip = "", GFolder = "", GSmile = "", GSpeaker = "",
        GNote = "", GMic = "", GInfo = "", GPlay = "", GLink = "", GRing = "\uEA3A", GDensity = "\uE8FD",
        // bubble.left.and.bubble.right (Segoe Fluent ChatBubbles).
        GBubbles = "\uE8F2",
        // sidebar.left (Segoe Fluent DockLeft).
        GSidebar = "\uE90C";

    public static FrameworkElement Category(SettingsPage page, SettingsCategory c) => c switch
    {
        SettingsCategory.General => General(page),
        SettingsCategory.Appearance => Appearance(page),
        SettingsCategory.Chat => Chat(page),
        SettingsCategory.Sounds => Sounds(),
        SettingsCategory.Gateway => HermesCategory(page),
        _ => AboutCategory(page),
    };

    /// A page a target names ("theme", "tool-calls"…), for search results and deep links.
    public static (string Title, Func<FrameworkElement> Make)? PageFor(SettingsPage page, string target) => target switch
    {
        "theme" => ("Theme", () => Theme()),
        ChatBubbles.Target => (ChatBubbles.Label, () => ChatBubblesPage()),
        BackdropPrefs.Target => (BackdropPrefs.Title, () => BackgroundsPane.Make()),
        "tool-calls" => ("Tool Calls", () => ToolCalls()),
        "notifications" => ("Notifications", () => Notifications()),
        "voice" => ("Voice", () => Voice()),
        "sessions" => (SettingsWords.SessionsPageTitle, () => Sessions()),
        "browser-cloud" => ("Browser Use Cloud", () => Browser.BrowserFeature.BuildCloudSettingsContent()),
        SidebarPage.Target => (SidebarPage.Title, () => SidebarSettingsPage.Make()),
        "about" => ("About", () => About(page)),
        "diagnostics" => ("Diagnostics", () => DiagnosticsPane.Make()),
        "licenses" => (LicenseNotices.PageTitle, () => Licenses(page)),
        _ => null,
    };

    private static void Go(SettingsPage page, string target)
    {
        if (PageFor(page, target) is { } p) page.Push(p.Title, p.Make);
    }

    // ---------------------------------------------------------------- General

    private static FrameworkElement General(SettingsPage page)
    {
        var n = NotificationPrefs.Load(Prefs);
        return Kit.Page(
            Kit.Section(null, null,
                Kit.Nav(GBell, "Notifications", n.Enabled ? "On" : "Off", () => Go(page, "notifications"), "settings.notifications")));
    }

    // ---------------------------------------------------------------- Appearance (AppearanceSections: Look, Text Size, Bots & Sessions)

    private static FrameworkElement Appearance(SettingsPage page)
    {
        var state = ThemeService.State;
        UIElement lightOrDark;
        if (global::Hermes.Core.Settings.Appearance.ForcedBy(state.Skin) is { } forced)
        {
            // A skin with one look: the row says so instead of offering a choice that does nothing.
            lightOrDark = Kit.Row(GHalf, "Light or Dark", null, new TextBlock { Text = forced.Title(), Foreground = Kit.B("TextFillColorSecondaryBrush") },
                "row:appearance");
        }
        else
        {
            lightOrDark = Kit.Picker(GHalf, "Light or Dark", null,
                [.. Enum.GetValues<AppearanceSetting>().Select(a => (a.Title(), a))], ThemeService.Chosen,
                a => ThemeService.SetAppearance(a), "row:appearance");
        }
        return Kit.Page(
            Kit.Section("Look", SettingsWords.LookFooter(state),
                lightOrDark,
                Kit.Nav(GPalette, "Theme", state.Skin.Label, () => Go(page, "theme"), "settings.theme-row"),
                Kit.Toggle(GDesktop, "Desktop Look", null, state.DesktopLook, on => ThemeService.SetDesktopLook(on), "row:desktop-look")),
            Kit.Section("Text Size", SettingsWords.ScaleNote, UiScaleRow()),
            // [theme-pages] Chats (AppearancePage `chats`): Chat Bubbles, Backgrounds (iOS look), Thinking Bar.
            Kit.Section(ChatBubbles.SectionTitle, null,
                Kit.Nav(GBubbles, ChatBubbles.Label, ChatBubbles.Value(state), () => Go(page, ChatBubbles.Target), ChatBubbles.RowId),
                !state.DesktopLook ? Kit.Nav(GPalette, BackdropPrefs.Title, BackdropPainter.Prefs.Load(BackdropPlace.Chats).Summary(BackdropPainter.Prefs.Load(BackdropPlace.App)), () => Go(page, BackdropPrefs.Target), "settings.backgrounds") : null,
                ThinkingBarControl()),
            // [density] [working-ring] Bots & Sessions (AppearancePage `lists`): Density, then Working Ring.
            Kit.Section(WorkingRing.SectionTitle, DensityRow.ListsNote(state), DensityRow.Shown(state) ? DensityControl(state) : null, WorkingRingRow()),
            // [taborder] App (AppearancePage `app`): Sidebar, the Mac's `tabsRow`, plus Chats Under Bots.
            Kit.Section(SidebarPage.AppSection, null,
                Kit.Nav(GSidebar, SidebarPage.Title, null, () => Go(page, SidebarPage.Target), SidebarPage.RowId),
                ChatsUnderBotsControl()));
    }

    /// [theme-pages] Settings › Appearance › Chat Bubbles (ThemeSettingsView.swift `ChatBubblesSettingsView`): no header under
    /// a bar already titled Chat Bubbles. The iOS look: Corners, then the Tinted switch (the Mac's branch with no Liquid
    /// Glass); the Desktop Look: its own Corners (no Text Box: this desktop keeps its own message box, as the Mac).
    private static FrameworkElement ChatBubblesPage()
    {
        var state = ThemeService.State;
        var footer = string.Join("\n\n", ChatBubbles.Footer(state, hasChatBackground: false));
        UIElement? tinted = null;
        if (ChatBubbles.ShowsStyle(state))
        {
            var shown = ChatBubbles.Shown(state.BubbleStyle);
            tinted = Kit.Toggle(null, ChatBubbles.TintedLabel, null, shown == BubbleStyle.Tinted, on =>
            {
                var next = on ? BubbleStyle.Tinted : BubbleStyle.Solid;
                if (next != ChatBubbles.Shown(ThemeService.State.BubbleStyle)) ThemeService.SetBubbleStyle(next);
            }, ChatBubbles.TintedId);
        }
        var root = Kit.Page(Kit.Section(null, footer, BubbleCornersRow(state), tinted));
        AutomationProperties.SetAutomationId(root, ChatBubbles.PageId);
        return root;
    }

    /// [theme-pages] Corners (`BubbleCornersRow`): a reply and your message as the chat draws them, then "Corners" and its
    /// points, then the slider (square to capsule). The preview follows the drag; the chats change when it is let go, or
    /// at once from the keyboard.
    private static FrameworkElement BubbleCornersRow(ThemeState state)
    {
        var stored = ChatBubbles.Corners(state);
        var stack = new StackPanel { Padding = new Thickness(14, 10, 14, 12), Spacing = 12, Tag = ChatBubbles.CornersId };
        var preview = new StackPanel { Spacing = 10 };
        preview.Children.Add(new TextBlock
        {
            Text = "Your report is ready. It’s in Files, and I can send it to Ivy as well.", TextWrapping = TextWrapping.Wrap,
            Foreground = Kit.B("TextFillColorPrimaryBrush"),
        });
        var thanks = new TextBlock { Text = "Thanks!", Foreground = Kit.B("HQMeTextBrush") };
        ThemeService.ContrastWords(thanks);   // [WIN-CONTRAST-BUBBLE] your bubble's Highlight pair, no backplate
        var mine = new Border
        {
            Child = thanks,
            Padding = new Thickness(12, 8, 12, 8), CornerRadius = new CornerRadius(stored), HorizontalAlignment = HorizontalAlignment.Right,
            Background = Kit.B("HQMeBubbleBrush"), BorderBrush = Kit.B("HQMeBorderBrush"), BorderThickness = new Thickness(1),
        };
        preview.Children.Add(mine);
        AutomationProperties.SetAccessibilityView(preview, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        stack.Children.Add(preview);
        var line = new Grid();
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        line.Children.Add(new TextBlock { Text = ChatBubbles.CornersLabel, Foreground = Kit.B("TextFillColorPrimaryBrush") });
        var points = new TextBlock { Text = ChatBubbles.CornersValue(stored), Foreground = Kit.B("TextFillColorSecondaryBrush") };
        Grid.SetColumn(points, 1);
        line.Children.Add(points);
        AutomationProperties.SetAccessibilityView(line, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);   // the slider says both
        stack.Children.Add(line);
        var slider = new Slider
        {
            Minimum = ChatBubbles.Range.Min, Maximum = ChatBubbles.Range.Max, StepFrequency = 1, Value = stored,
            IsThumbToolTipEnabled = false, HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        AutomationProperties.SetName(slider, ChatBubbles.CornersName);
        AutomationProperties.SetAutomationId(slider, ChatBubbles.CornersId);
        AutomationProperties.SetItemStatus(slider, ChatBubbles.CornersSpoken(stored));
        // Applied when the pointer lets go, a key is let up (the arrow keys apply at once) or the slider loses focus: each
        // change draws Settings and every open chat again, so never in the middle of a drag.
        void Finish()
        {
            var at = (int)Math.Round(slider.Value);
            if (at != ChatBubbles.Corners(ThemeService.State)) ThemeService.SetBubbleCorners(at);
        }
        slider.ValueChanged += (_, e) =>
        {
            var at = (int)Math.Round(e.NewValue);
            points.Text = ChatBubbles.CornersValue(at);
            mine.CornerRadius = new CornerRadius(at);
            AutomationProperties.SetItemStatus(slider, ChatBubbles.CornersSpoken(at));
        };
        slider.AddHandler(UIElement.PointerReleasedEvent, new Microsoft.UI.Xaml.Input.PointerEventHandler((_, _) => Finish()), true);
        slider.AddHandler(UIElement.PointerCaptureLostEvent, new Microsoft.UI.Xaml.Input.PointerEventHandler((_, _) => Finish()), true);
        slider.AddHandler(UIElement.KeyUpEvent, new Microsoft.UI.Xaml.Input.KeyEventHandler((_, _) => Finish()), true);
        slider.LostFocus += (_, _) => Finish();
        var track = new Grid { ColumnSpacing = 10 };
        track.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        track.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        // square … capsule, as the Mac's minimum and maximum value labels.
        var square = new Border { Width = 14, Height = 14, CornerRadius = new CornerRadius(2), BorderThickness = new Thickness(1.5), BorderBrush = Kit.B("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center };
        var capsule = new Border { Width = 22, Height = 12, CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(1.5), BorderBrush = Kit.B("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetAccessibilityView(square, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        AutomationProperties.SetAccessibilityView(capsule, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        track.Children.Add(square);
        Grid.SetColumn(slider, 1);
        track.Children.Add(slider);
        Grid.SetColumn(capsule, 2);
        track.Children.Add(capsule);
        stack.Children.Add(track);
        return stack;
    }

    /// [density] Standard / Compact as two segments at the row's end (the Mac's `HQSegmentedPicker` in `DensityRow`), the
    /// chosen one filled. The row is "row:density" (search scrolls to it), the strip the Mac's "theme.density".
    private static FrameworkElement DensityControl(ThemeState state)
    {
        var strip = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 0 };
        AutomationProperties.SetName(strip, DensityRow.Label);
        AutomationProperties.SetAutomationId(strip, DensityRow.AutomationId);
        var options = DensityRow.Options;
        for (var i = 0; i < options.Length; i++)
        {
            var (title, value) = options[i];
            var b = new ToggleButton
            {
                Content = title, IsChecked = state.Density == value, Padding = new Thickness(12, 4, 12, 4), MinWidth = 0,
                CornerRadius = new CornerRadius(i == 0 ? 4 : 0, i == options.Length - 1 ? 4 : 0, i == options.Length - 1 ? 4 : 0, i == 0 ? 4 : 0),
            };
            AutomationProperties.SetName(b, title);
            AutomationProperties.SetAutomationId(b, $"{DensityRow.AutomationId}.{value.Raw()}");
            b.Click += (_, _) =>
            {
                if (ThemeService.State.Density != value) ThemeService.SetDensity(value);
                else b.IsChecked = true;
            };
            strip.Children.Add(b);
        }
        return Kit.Row(GDensity, DensityRow.Label, null, strip, DensityRow.RowTarget);
    }

    /// [working-ring] The switch: the row is "row:working-ring" (search scrolls to it), the switch the Mac's
    /// "theme.workingRing". The write tells the bot and session lists, which draw their rows again at once.
    private static FrameworkElement WorkingRingRow()
    {
        var row = Kit.Toggle(GRing, WorkingRing.Label, null, WorkingRing.IsOn, on => WorkingRing.IsOn = on, WorkingRing.RowTarget);
        foreach (var toggle in row.Children.OfType<ToggleSwitch>()) AutomationProperties.SetAutomationId(toggle, WorkingRing.AutomationId);
        return row;
    }

    private static FrameworkElement ThinkingBarControl()
    {
        var row = Kit.Toggle(null, ThinkingBarRow.Label, ThinkingBarRow.Note, ThinkingBarRow.IsOn, on => ThinkingBarRow.IsOn = on, ThinkingBarRow.RowTarget);
        foreach (var toggle in row.Children.OfType<ToggleSwitch>()) AutomationProperties.SetAutomationId(toggle, ThinkingBarRow.AutomationId);
        return row;
    }

    private static FrameworkElement ChatsUnderBotsControl() =>
        Kit.Picker(null, ChatsUnderBotsRow.Label, ChatsUnderBotsRow.Note, ChatsUnderBotsRow.Options, ChatsUnderBotsRow.Current,
            v => ChatsUnderBotsRow.Current = v, ChatsUnderBotsRow.RowTarget);

    /// UI Scale's presets as one strip of segments, the chosen one filled.
    private static FrameworkElement UiScaleRow()
    {
        var strip = new Grid { ColumnSpacing = 0, Margin = new Thickness(0, 8, 0, 0) };
        var presets = ThemeState.ScalePresets;
        for (var i = 0; i < presets.Length; i++)
        {
            var percent = presets[i];
            strip.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var b = new ToggleButton
            {
                Content = $"{percent}%", IsChecked = ThemeService.State.UiScalePercent == percent, HorizontalAlignment = HorizontalAlignment.Stretch,
                Padding = new Thickness(1, 4, 1, 4), MinWidth = 0,
                CornerRadius = new CornerRadius(i == 0 ? 4 : 0, i == presets.Length - 1 ? 4 : 0, i == presets.Length - 1 ? 4 : 0, i == 0 ? 4 : 0),
            };
            AutomationProperties.SetName(b, $"UI Scale {percent}%");
            AutomationProperties.SetAutomationId(b, $"theme.uiScale.{percent}");
            b.Click += (_, _) =>
            {
                if (ThemeService.State.UiScalePercent != percent) ThemeService.SetUiScale(percent);
                else b.IsChecked = true;
            };
            Grid.SetColumn(b, i);
            strip.Children.Add(b);
        }
        var stack = new StackPanel { Padding = new Thickness(14, 10, 14, 12), Tag = "row:ui-scale" };
        var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        title.Children.Add(new FontIcon { Glyph = GText, FontSize = 16 });
        title.Children.Add(new TextBlock { Text = "UI Scale" });
        stack.Children.Add(title);
        stack.Children.Add(strip);
        return stack;
    }

    // ---------------------------------------------------------------- Theme (the grid, High Contrast)

    private static FrameworkElement Theme()
    {
        var state = ThemeService.State;
        // Reflow to 1 column at accessibility text sizes so theme cards never crush horizontally.
        var cols = ThemeService.AccessibilityTextSize ? 1 : 2;
        var grid = new Grid { ColumnSpacing = 12, RowSpacing = 12 };
        for (var c = 0; c < cols; c++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var skins = SkinCatalog.All;
        for (var i = 0; i < skins.Count; i++)
        {
            if (i % cols == 0) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var card = SkinCard(skins[i], skins[i].Id == state.SkinId, state.DesktopLook);
            Grid.SetRow(card, i / cols);
            Grid.SetColumn(card, i % cols);
            grid.Children.Add(card);
        }
        var notes = new StackPanel { Spacing = 6 };
        notes.Children.Add(Kit.Footer(SettingsWords.GridNote));
        if (state.Skin.HasOneLook) notes.Children.Add(Kit.Footer(SettingsWords.OneLookNote(state.Skin)));
        var top = new StackPanel { Spacing = 8 };
        top.Children.Add(grid);
        top.Children.Add(notes);
        return Kit.Page(
            top,
            // High Contrast is the Desktop Look's: it only draws there.
            state.DesktopLook
                ? Kit.Section(null, SettingsWords.ContrastNote,
                    Kit.Toggle(null, "High Contrast", null, state.HighContrast, on => ThemeService.SetHighContrast(on), "theme.highContrast"))
                : null);
    }

    /// A theme's card: its light and dark palettes side by side (one panel for a one-look theme), its name with a check
    /// when chosen and its "Dark Only" tag, and its description.
    private static FrameworkElement SkinCard(Skin skin, bool chosen, bool desktop)
    {
        var preview = new Grid { Height = 72, CornerRadius = new CornerRadius(desktop ? 2 : 6) };
        var looks = skin.HasOneLook ? new[] { skin.Light } : [skin.Light, skin.Dark!];
        for (var i = 0; i < looks.Length; i++)
        {
            preview.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var panel = Swatch(looks[i]);
            Grid.SetColumn(panel, i);
            preview.Children.Add(panel);
        }
        var name = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        name.Children.Add(new TextBlock { Text = skin.Label, FontSize = 16, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        if (skin.OnlyModeTag is { } tag)
        {
            var pill = new Border { CornerRadius = new CornerRadius(9), Padding = new Thickness(8, 1, 8, 2), Background = Kit.B("HQPressedBrush") };
            var tagRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            tagRow.Children.Add(new FontIcon { Glyph = tag == "Dark Only" ? "" : "", FontSize = 11, VerticalAlignment = VerticalAlignment.Center });
            tagRow.Children.Add(new TextBlock { Text = tag, FontSize = 12, FontWeight = FontWeights.SemiBold });
            pill.Child = tagRow;
            name.Children.Add(pill);
        }
        var head = new Grid();
        head.Children.Add(name);
        if (chosen)
            head.Children.Add(new FontIcon { Glyph = "", FontSize = 14, HorizontalAlignment = HorizontalAlignment.Right, Foreground = Kit.B("AccentTextFillColorPrimaryBrush") });
        var stack = new StackPanel { Spacing = 6 };
        stack.Children.Add(preview);
        stack.Children.Add(head);
        stack.Children.Add(new TextBlock { Text = skin.Description, FontSize = 13, TextWrapping = TextWrapping.Wrap, Foreground = Kit.B("TextFillColorSecondaryBrush") });
        var button = new Button
        {
            Content = stack, Padding = new Thickness(10), HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Top, CornerRadius = new CornerRadius(desktop ? 4 : 10),
            BorderThickness = new Thickness(chosen ? 2 : 1), Background = Kit.B("CardBackgroundFillColorDefaultBrush"),
            BorderBrush = chosen ? Kit.B("AccentFillColorDefaultBrush") : Kit.B("CardStrokeColorDefaultBrush"),
        };
        AutomationProperties.SetName(button, skin.Label + (chosen ? ", chosen" : ""));
        AutomationProperties.SetHelpText(button, skin.Description);
        AutomationProperties.SetAutomationId(button, "theme.skin." + skin.Id);
        button.Click += (_, _) => { if (!chosen) ThemeService.PickSkin(skin.Id); };
        return button;
    }

    /// One palette drawn small: its page, an accent pill, two lines of text, a box.
    private static FrameworkElement Swatch(SkinSeeds s)
    {
        SolidColorBrush C(Rgba c) => new(ThemeService.ToColor(c));
        var g = new Grid { Background = C(s.Background), Padding = new Thickness(8) };
        var lines = new StackPanel { Spacing = 5 };
        var top = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        top.Children.Add(new Border { Width = 26, Height = 8, CornerRadius = new CornerRadius(2), Background = C(s.Brand) });
        top.Children.Add(new Border { Width = 46, Height = 4, CornerRadius = new CornerRadius(2), Background = C(s.Foreground), VerticalAlignment = VerticalAlignment.Center });
        lines.Children.Add(top);
        lines.Children.Add(new Border { Width = 76, Height = 3, CornerRadius = new CornerRadius(1.5), HorizontalAlignment = HorizontalAlignment.Left, Background = C(s.MutedForeground) });
        lines.Children.Add(new Border { Height = 12, CornerRadius = new CornerRadius(2), Background = C(s.Card) });
        g.Children.Add(lines);
        g.Children.Add(new Border
        {
            Width = 28, Height = 9, CornerRadius = new CornerRadius(2), BorderThickness = new Thickness(1), BorderBrush = C(s.Border),
            Background = C(s.Input), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
        });
        return g;
    }

    // ---------------------------------------------------------------- Chat

    private static FrameworkElement Chat(SettingsPage page)
    {
        // Largest Attachment: the attachments feature's row (its number field, "MB" and help), in a row of this card.
        var attachment = new StackPanel { Padding = new Thickness(14, 10, 14, 10), Tag = "row:attachment-limit" };
        attachment.Children.Add(new LargestAttachmentRow());
        return Kit.Page(
            Kit.Section(null, null,
                Kit.Nav(GWrench, "Tool Calls", ChatDisplaySettings.Style.Title(), () => Go(page, "tool-calls"), "settings.tool-calls"),
                Kit.Toggle(GClock, "Fewer Timestamps", SettingsWords.FewerTimestampsNote, ChatDisplaySettings.FewerTimestamps,
                    on => ChatDisplaySettings.FewerTimestamps = on, "row:fewer-timestamps"),
                attachment,
                // [WIN-CHAT-INTRO] SettingsRootView.swift's "settings.intro-splash" (§7), on by default.
                Kit.Toggle(null, SettingsWords.IntroSplashLabel, null, Hermes.Core.Chat.ChatIntro.IsOn,
                    on => Hermes.Core.Chat.ChatIntro.IsOn = on, "row:intro-splash"),
                Kit.Toggle(GFolder, SettingsWords.FileBrowserLabel, null, ChatPrefs.FileBrowser, on => ChatPrefs.FileBrowser = on, "row:file-browser"),
                Kit.Toggle(GSmile, "Message Reactions", SettingsWords.MessageReactionsNote, ChatDisplaySettings.Reactions,
                    on => ChatDisplaySettings.Reactions = on, "row:message-reactions")));
    }

    /// Settings › Chat › Tool Calls (App/Settings/ToolCallsSettingsView.swift): Tool Call Style as a radio list, each
    /// with its own line; Tool Calls After Reply (not under In Header).
    private static FrameworkElement ToolCalls()
    {
        var host = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        void Draw()
        {
            var style = ChatDisplaySettings.Style;
            var styles = Enum.GetValues<ToolCallStyle>().Select(s => Radio("style", s.Title(), s.Detail(), s == style, () =>
            {
                ChatDisplaySettings.Style = s;
                AppLog.Note("settings", $"tool call style set to {s}");
                Draw();
            }, "settings.tool-call-style." + s.Title())).ToArray();
            var after = ChatDisplaySettings.AfterReply;
            var afters = Enum.GetValues<ToolCallsAfterReply>().Select(a => Radio("after", a.Title(), null, a == after, () =>
            {
                ChatDisplaySettings.AfterReply = a;
                AppLog.Note("settings", $"tool calls after reply set to {a}");
                Draw();
            }, "settings.tool-calls-after-reply." + a.Title())).ToArray();
            host.Content = Kit.Page(
                Kit.Section("Tool Call Style", SettingsWords.ToolCallStyleFooter, styles),
                style != ToolCallStyle.Header ? Kit.Section("Tool Calls After Reply", SettingsWords.AfterReplyFooter, afters) : null);
        }
        Draw();
        return host;
    }

    private static UIElement Radio(string group, string title, string? detail, bool on, Action pick, string id)
    {
        var words = new StackPanel { Spacing = 3 };
        words.Children.Add(new TextBlock { Text = title, TextWrapping = TextWrapping.Wrap });
        if (detail != null) words.Children.Add(new TextBlock { Text = detail, FontSize = 12, TextWrapping = TextWrapping.Wrap, Foreground = Kit.B("TextFillColorSecondaryBrush") });
        var radio = new RadioButton { Content = words, GroupName = group, IsChecked = on, Margin = new Thickness(14, 6, 14, 6), HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(radio, title);
        AutomationProperties.SetAutomationId(radio, id);
        if (detail != null) AutomationProperties.SetHelpText(radio, detail);
        radio.Checked += (_, _) => { if (!on) pick(); };
        return radio;
    }

    // ---------------------------------------------------------------- Sounds

    private static FrameworkElement Sounds()
    {
        var prefs = new CompletionSoundPrefs(Prefs);
        var host = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        void Draw()
        {
            UIElement? sound = null;
            if (prefs.IsOn)
            {
                var name = CompletionSoundSynth.Find(prefs.Variant).Name;
                var trailing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
                var play = new Button { Content = new FontIcon { Glyph = GPlay, FontSize = 14 }, Padding = new Thickness(8, 6, 8, 6),
                    Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0) };
                AutomationProperties.SetName(play, $"Play {name}");
                ToolTipService.SetToolTip(play, $"Play {name}");
                play.Click += (_, _) => CompletionCue.Preview(prefs.Variant);
                trailing.Children.Add(play);
                var box = new ComboBox { MinWidth = 180 };
                foreach (var p in CompletionSoundSynth.Presets) box.Items.Add(p.Name);
                box.SelectedIndex = CompletionSoundSynth.Presets.ToList().FindIndex(p => p.Id == prefs.Variant);
                AutomationProperties.SetName(box, "Sound");
                AutomationProperties.SetAutomationId(box, "settings.sound");
                box.SelectionChanged += (_, _) =>
                {
                    if (box.SelectedIndex < 0) return;
                    var id = CompletionSoundSynth.Presets[box.SelectedIndex].Id;
                    if (id == prefs.Variant) return;
                    prefs.Variant = id;
                    CompletionCue.Preview(id); // choosing a sound plays it
                    Draw();
                };
                trailing.Children.Add(box);
                sound = Kit.Row(GNote, "Sound", null, trailing, "row:sound");
            }
            host.Content = Kit.Page(Kit.Section(null, SettingsWords.SoundsFooter,
                Kit.Toggle(GSpeaker, "Completion Sound", null, prefs.IsOn, on => { prefs.IsOn = on; Draw(); }, "row:completion-sound"),
                sound));
        }
        Draw();
        return host;
    }

    // ---------------------------------------------------------------- Hermes

    private static FrameworkElement HermesCategory(SettingsPage page) => Kit.Page(
        Kit.Section(null, $"Voice’s Read Replies Aloud and Send Memo on Release, and the default project folder, are kept on this {DeviceWord.Name}.",
            Kit.Nav(GMic, "Voice", null, () => Go(page, "voice"), "settings.config.voice"),
            Kit.Nav(GFolder, SettingsWords.SessionsPageTitle, null, () => Go(page, "sessions"), "settings.sessions"),
            Kit.Nav(GLink, "Browser Use Cloud", null, () => Go(page, "browser-cloud"), "settings.browser-cloud")));

    /// The gateway's config record, one store per signed-in gateway shared by every page that edits it
    /// (SettingsNavigator.swift `router.gatewaySettings?.configStore`).
    private static readonly System.Runtime.CompilerServices.ConditionalWeakTable<global::Hermes.Core.HermesClient, GatewayConfigStore> ConfigStores = new();

    private static GatewayConfigStore ConfigStore(global::Hermes.Core.HermesClient client)
    {
        GatewayConfigStore.Log ??= line => AppLog.Note("settings", line);
        return ConfigStores.GetValue(client, c => new GatewayConfigStore(new GatewayConfigApi(c.Session)));
    }

    /// Archiving & Project Folder (VaultBillingPages.swift `SessionsSettingsView`): the save-failure card, then Auto-Archive
    /// Stale Chats and Archive After … days (the gateway's `sessions.auto_archive` / `auto_archive_days`, autosaved as a
    /// sparse `PUT /api/config`), then Default Project Folder.
    private static FrameworkElement Sessions()
    {
        if (AppState.Client is not { } client || client.AccountId is not { } account)
            return Kit.Page(Kit.Section("Default Project Folder", SettingsWords.DefaultFolderFooter, Kit.Row(null, "Connect to your gateway to change these settings.")));
        var store = ConfigStore(client);
        return Kit.Page(AutoArchiveSections(store), DefaultFolderSection(account));
    }

    private static FrameworkElement AutoArchiveSections(GatewayConfigStore store)
    {
        var root = new StackPanel { Spacing = 22 };
        var status = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };   // failure card, loading, load failure
        var syncing = false;

        var toggle = new ToggleSwitch { OnContent = "", OffContent = "", MinWidth = 0 };
        AutomationProperties.SetName(toggle, AutoArchive.Title);
        AutomationProperties.SetAutomationId(toggle, "sessions.auto-archive");
        toggle.Toggled += (_, _) =>
        {
            if (syncing || toggle.IsOn == AutoArchive.Enabled(store)) return;
            AutoArchive.Toggle(store, toggle.IsOn);
        };
        var days = new TextBox { PlaceholderText = AutoArchive.DaysPlaceholder, Width = 70, TextAlignment = TextAlignment.Right, InputScope = NumberScope() };
        AutomationProperties.SetName(days, AutoArchive.DaysLabel);
        AutomationProperties.SetAutomationId(days, "sessions.auto-archive-days");
        void CommitDays() => days.Text = AutoArchive.CommitDays(store, days.Text);
        days.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; CommitDays(); } };
        days.LostFocus += (_, _) => CommitDays();
        var daysTrailing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        daysTrailing.Children.Add(days);
        daysTrailing.Children.Add(new TextBlock { Text = AutoArchive.DaysUnit, VerticalAlignment = VerticalAlignment.Center, Foreground = Kit.B("TextFillColorSecondaryBrush") });
        var daysRow = Kit.Row(null, AutoArchive.DaysLabel, null, daysTrailing, "row:auto-archive-days");
        // Archive After shows only while the switch is on: it and its hairline come and go together.
        var daysWrap = new StackPanel();
        daysWrap.Children.Add(new Border { Height = 1, Margin = new Thickness(48, 0, 0, 0), Background = Kit.B("DividerStrokeColorDefaultBrush") });
        daysWrap.Children.Add(daysRow);
        var rows = new StackPanel();
        rows.Children.Add(Kit.Row(null, AutoArchive.Title, null, toggle, "row:auto-archive"));
        rows.Children.Add(daysWrap);
        var section = Kit.Section(null, AutoArchive.Footer, rows);
        root.Children.Add(status);
        root.Children.Add(section);

        var daysFilled = false;
        void Sync()
        {
            syncing = true;
            try
            {
                var parts = new List<UIElement?>();
                if (store.Failure is { } failure) parts.Add(SaveFailureCard(store, failure));
                if (store.Config == null)
                {
                    if (store.Phase == GatewayConfigStore.LoadPhase.Failed)
                    {
                        var retry = Kit.Push("Try Again", () => { _ = store.LoadAsync(force: true); });
                        AutomationProperties.SetAutomationId(retry, "settings.load-retry");
                        parts.Add(Kit.Section(null, null, Kit.Row(null, AutoArchive.LoadFailedTitle, store.LoadError, retry, "settings.load-failure")));
                    }
                    else parts.Add(Kit.Section(null, null, Kit.Row(null, "Loading…", null, new ProgressRing { IsActive = true, Width = 18, Height = 18 })));
                }
                var stack = new StackPanel { Spacing = 22 };
                foreach (var part in parts) stack.Children.Add(part);
                status.Content = parts.Count == 0 ? null : stack;
                section.Visibility = store.Config == null ? Visibility.Collapsed : Visibility.Visible;
                var on = AutoArchive.Enabled(store);
                toggle.IsOn = on;
                daysWrap.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
                if (store.Config != null && !daysFilled)
                {
                    daysFilled = true;
                    days.Text = AutoArchive.StoredDays(store).ToString(System.Globalization.CultureInfo.InvariantCulture);
                }
            }
            finally { syncing = false; }
        }
        void OnChanged() => root.DispatcherQueue?.TryEnqueue(Sync);
        store.Changed += OnChanged;
        root.Unloaded += (_, _) =>
        {
            store.Changed -= OnChanged;
            CommitDays();
            _ = store.Flush();
        };
        Sync();
        _ = store.LoadAsync();
        return root;
    }

    private static Microsoft.UI.Xaml.Input.InputScope NumberScope()
    {
        var scope = new Microsoft.UI.Xaml.Input.InputScope();
        scope.Names.Add(new Microsoft.UI.Xaml.Input.InputScopeName(Microsoft.UI.Xaml.Input.InputScopeNameValue.Number));
        return scope;
    }

    /// "Couldn’t Save Your Change" (SettingsComponents.swift `SaveFailureSection`): the words, Details, Copy, Dismiss and
    /// Try Again, which sends the same change again.
    private static FrameworkElement SaveFailureCard(GatewayConfigStore store, GatewayConfigStore.SaveFailure failure)
    {
        var stack = new StackPanel { Spacing = 6, Padding = new Thickness(14, 12, 14, 12) };
        var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        title.Children.Add(new FontIcon { Glyph = "\uE7BA", FontSize = 14, Foreground = Kit.B("SystemFillColorCriticalBrush") });
        title.Children.Add(new TextBlock { Text = AutoArchive.SaveFailedTitle, FontWeight = FontWeights.SemiBold, Foreground = Kit.B("SystemFillColorCriticalBrush") });
        stack.Children.Add(title);
        stack.Children.Add(new TextBlock { Text = failure.Text, TextWrapping = TextWrapping.Wrap, Foreground = Kit.B("TextFillColorPrimaryBrush") });
        var detail = new TextBlock { Text = failure.Detail ?? "", FontFamily = new FontFamily("Consolas"), FontSize = 12, IsTextSelectionEnabled = true,
            Foreground = Kit.B("TextFillColorSecondaryBrush"), Visibility = Visibility.Collapsed };
        stack.Children.Add(detail);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 18, Margin = new Thickness(0, 4, 0, 0) };
        if (failure.Detail != null)
        {
            Button? details = null;
            details = Kit.Push("Details", () => { detail.Visibility = Visibility.Visible; details!.Visibility = Visibility.Collapsed; });
            buttons.Children.Add(details);
        }
        Button? copy = null;
        copy = Kit.Push("Copy", async () =>
        {
            if (!SafeClipboard.TrySetText(string.Join("\n", new[] { "Couldn’t save your change", failure.Text, failure.Detail ?? "" }.Where(t => t.Length > 0)))) return;
            copy!.Content = "Copied";   // "Copied" for two seconds, then "Copy" again
            await Task.Delay(2000);
            copy.Content = "Copy";
        });
        buttons.Children.Add(copy);
        buttons.Children.Add(Kit.Push("Dismiss", store.DismissFailure));
        var retry = Kit.Push("Try Again", () => { _ = store.Retry(); });
        retry.FontWeight = FontWeights.SemiBold;
        AutomationProperties.SetAutomationId(retry, "settings.save-failure.retry");
        buttons.Children.Add(retry);
        stack.Children.Add(buttons);
        AutomationProperties.SetAutomationId(stack, "settings.save-failure");
        return Kit.Card(stack);
    }

    /// Archiving & Project Folder's Default Project Folder (VaultBillingPages.swift `DefaultProjectFolderField`): typed in
    /// place, kept once the gateway says it is a folder; emptied, it is cleared.
    private static FrameworkElement DefaultFolderSection(string account)
    {
        var saved = DefaultProjectFolder.Path(account) ?? "";
        var field = new TextBox { Text = saved, PlaceholderText = "/Users/you/Projects/app", MinWidth = 300 };
        AutomationProperties.SetName(field, "Default Project Folder");
        AutomationProperties.SetAutomationId(field, "sessions.default-folder");
        var ring = new ProgressRing { IsActive = false, Width = 16, Height = 16, Visibility = Visibility.Collapsed };
        var problem = new TextBlock { FontSize = 12, Foreground = Kit.B("SystemFillColorCriticalBrush"), Visibility = Visibility.Collapsed, TextWrapping = TextWrapping.Wrap };
        AutomationProperties.SetAutomationId(problem, "sessions.default-folder.problem");
        var checking = false;
        async Task Commit()
        {
            var path = field.Text.Trim();
            if (path == (DefaultProjectFolder.Path(account) ?? "") || checking) return;
            problem.Visibility = Visibility.Collapsed;
            if (path.Length == 0) { DefaultProjectFolder.Set(null, account); return; }
            if (AppState.Client is not { } client) return;
            checking = true;
            field.IsEnabled = false;
            ring.IsActive = true; ring.Visibility = Visibility.Visible;
            try
            {
                if (await DefaultProjectFolder.ExistsAsync(client.Session, path)) DefaultProjectFolder.Set(path, account);
                else { problem.Text = SettingsWords.FolderMissing; problem.Visibility = Visibility.Visible; }
            }
            catch (Exception x) when (x is global::Hermes.Core.Net.GatewayException or HttpRequestException or OperationCanceledException)
            {
                AppLog.Note("settings", $"default folder check failed: {x.GetType().Name}");
                problem.Text = SettingsWords.FolderFailed;
                problem.Visibility = Visibility.Visible;
            }
            finally
            {
                checking = false;
                field.IsEnabled = true;
                ring.IsActive = false; ring.Visibility = Visibility.Collapsed;
            }
        }
        field.KeyDown += async (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; await Commit(); } };
        field.LostFocus += async (_, _) => await Commit();
        var trailing = new StackPanel { Spacing = 4 };
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        line.Children.Add(field);
        line.Children.Add(ring);
        trailing.Children.Add(line);
        trailing.Children.Add(problem);
        return Kit.Section("Default Project Folder", SettingsWords.DefaultFolderFooter, Kit.Row(null, "Folder", null, trailing, "row:default-folder"));
    }

    /// Settings › Voice, as far as it is this PC's: Read Replies Aloud and Send Memo on Release (the voice feature reads
    /// them, and adds its own cards through SettingsHooks.Voice).
    private static FrameworkElement Voice()
    {
        var host = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        void Draw()
        {
            var release = VoicePrefs.SendOnRelease(Prefs);
            var parts = new List<UIElement?>
            {
                Kit.Section("Read Aloud", SettingsWords.ReadRepliesHint,
                    Kit.Toggle(null, "Read Replies Aloud", null, VoicePrefs.ReadsRepliesAloud(Prefs), on => VoicePrefs.SetReadsRepliesAloud(Prefs, on),
                        "voice.settings.read-replies")),
                Kit.Section("Voice Memos", SettingsWords.MemoNote(release),
                    Kit.Toggle(null, "Send Memo on Release", SettingsWords.SendOnReleaseHint, release,
                        on => { VoicePrefs.SetSendOnRelease(Prefs, on); Draw(); }, "voice.settings.send-on-release")),
                Kit.Section("Phone Calls", "Configure samplehost calling, caller ID, and run setup checks.",
                    Kit.Nav(null, "Phone Calls Setup…", null, () => _ = PhoneCalls.PhoneCallsFeature.OpenSettingsAsync(SettingsPage.Current?.XamlRoot), "voice.settings.phone-calls")),
            };
            parts.AddRange(SettingsHooks.Voice.Select(make => (UIElement?)make()));
            host.Content = Kit.Page([.. parts]);
        }
        Draw();
        return host;
    }

    // ---------------------------------------------------------------- Notifications

    /// Settings › Notifications (App/Notifications/NotificationsSettingsView.swift), its switches as kept on this PC; the
    /// notifications feature reads them, and adds Send Test Notification and the add-on through SettingsHooks.
    private static FrameworkElement Notifications()
    {
        var host = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        void Draw()
        {
            var n = NotificationPrefs.Load(Prefs);
            void Save(NotificationPrefs next) { next.Save(Prefs); Draw(); }
            var rows = new List<UIElement?> { Kit.Toggle(null, "Enable Notifications", null, n.Enabled, on => Save(n with { Enabled = on }), "notifications.enabled") };
            rows.AddRange(NotificationPrefs.Shown.Select(kind => (UIElement?)Kit.Toggle(null, NotificationPrefs.Label(kind), NotificationPrefs.Detail(kind),
                n.Allows(kind), on => Save(n.WithKind(kind, on)), "notifications.kind." + kind, enabled: n.Enabled)));
            var parts = new List<UIElement?>
            {
                Kit.Section(null, SettingsWords.NotificationsOffFooter(outside: false), [.. rows]),
                Kit.Section(null, SettingsWords.PreviewsFooter,
                    Kit.Toggle(null, "Show Previews", null, n.Enabled && n.Previews, on => Save(n with { Previews = on }), "notifications.previews", enabled: n.Enabled)),
                Kit.Section(null, SettingsWords.BannersFooter,
                    Kit.Toggle(null, "Bot Activity Banners", null, NotificationPrefs.Banners(Prefs), on => NotificationPrefs.SetBanners(Prefs, on), "notifications.banners")),
            };
            parts.AddRange(SettingsHooks.Notifications.Select(make => (UIElement?)make()));
            host.Content = Kit.Page([.. parts]);
        }
        Draw();
        return host;
    }

    // ---------------------------------------------------------------- About

    private static FrameworkElement AboutCategory(SettingsPage page)
    {
        page.FileActions = null;
        return Kit.Page(Kit.Section(null, null, Kit.Nav(GInfo, "About", null, () => Go(page, "about"), "settings.about")),
            AppState.Client is { } client
                ? FileActionsSection(page, ConfigStore(client), client.AccountId is { } account ? Composer.ComposerServices.Prefs(account) : null)
                : null);
    }

    /// Export Settings…, Import Settings…, Clear Model Favorites… and Reset to Defaults… under About
    /// (SettingsRootView.swift, shown while the gateway's config can be reached): two pairs of push buttons, with
    /// the last action's words and "Exported files leave out keys, tokens and passwords." under them.
    /// `models`: this account's model stars and recents on this PC, which Clear Model Favorites… empties.
    private static FrameworkElement FileActionsSection(SettingsPage page, GatewayConfigStore store, Hermes.Core.Composer.ModelPrefs? models)
    {
        SettingsFileActions.Log ??= line => AppLog.Note("settings", line);
        var section = new StackPanel { Spacing = 6 };
        var hud = new InfoBar { IsOpen = false, IsClosable = true, Severity = InfoBarSeverity.Success };
        AutomationProperties.SetAutomationId(hud, "settings.import-done");
        var status = new TextBlock
        {
            FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(14, 0, 14, 0), Visibility = Visibility.Collapsed,
            Foreground = Kit.B("TextFillColorPrimaryBrush"),
        };
        AutomationProperties.SetAutomationId(status, "settings.file-status");
        AutomationProperties.SetLiveSetting(status, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);

        var hideHud = 0;
        var ui = new SettingsFileUi(section, (title, detail) =>
        {
            hud.Title = title;
            hud.Message = detail;
            hud.IsOpen = true;
            var mine = ++hideHud;
            _ = Task.Delay(2500).ContinueWith(_ => section.DispatcherQueue?.TryEnqueue(() => { if (mine == hideHud) hud.IsOpen = false; }));
        });
        var actions = new SettingsFileActions(store, ui) { Models = models };
        // [WIN-06b] What a search result for one of these buttons runs (SettingsPage.Open, SettingsNavigator.open `.action`).
        page.FileActions = (actions, section);

        var export = Kit.Push(SettingsFileWords.Export, () => _ = actions.ExportAsync());
        AutomationProperties.SetAutomationId(export, "settings.export");
        var import = Kit.Push(SettingsFileWords.Import, () => _ = actions.PickImportAsync());
        AutomationProperties.SetAutomationId(import, "settings.import");
        // [WIN-06a] Above Reset, matching the Mac's `settings.clear-models`.
        var clearModels = Kit.Push(SettingsFileWords.ClearModels, () => _ = actions.ConfirmClearModelsAsync());
        AutomationProperties.SetAutomationId(clearModels, "settings.clear-models");
        var reset = Kit.Push(SettingsFileWords.Reset, () => _ = actions.ConfirmResetAsync(), destructive: true);
        AutomationProperties.SetAutomationId(reset, "settings.reset");
        reset.IsEnabled = !actions.Resetting;

        actions.StatusChanged += text => section.DispatcherQueue?.TryEnqueue(() =>
        {
            status.Text = text ?? "";
            status.Visibility = text == null ? Visibility.Collapsed : Visibility.Visible;
            if (text != null) SettingsFileUi.Announce(status, text);
        });
        actions.ResettingChanged += on => section.DispatcherQueue?.TryEnqueue(() => reset.IsEnabled = !on);

        section.Children.Add(hud);
        section.Children.Add(SettingsFileActionGroups.InCard(export, import, clearModels, reset));
        section.Children.Add(status);
        section.Children.Add(Kit.Footer(SettingsFileWords.Footer));
        return section;
    }

    /// Settings › About (App/Settings/AboutView.swift): this app's version, the gateway's Hermes version; Support,
    /// Privacy Policy, Open-Source Licenses; then Troubleshooting: Diagnostics and Detailed Logging (default on; kept on
    /// this PC). The Mac's Send Performance Logs and Mark a Slow Moment (and the section footer about what they send) are
    /// not here: the Windows app sends no performance log.
    private static FrameworkElement About(SettingsPage page)
    {
        var host = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var gateway = new TextBlock { Text = SettingsFeature.Gateway().Version ?? "Unavailable", Foreground = Kit.B("TextFillColorSecondaryBrush") };
        AutomationProperties.SetAutomationId(gateway, "about.hermes-version");
        SettingsFeature.RefreshVersion(() => gateway.DispatcherQueue.TryEnqueue(() => gateway.Text = SettingsFeature.Gateway().Version ?? "Unavailable"));

        void Draw()
        {
            var perfOn = PerformanceLogPrefs.IsEnabled(Prefs);
            UIElement? markRow = null;
            if (perfOn)
            {
                var markBtn = Kit.Push(PerformanceLogPrefs.MarkLabel, () => { });
                AutomationProperties.SetAutomationId(markBtn, "about.mark");
                markBtn.Click += async (_, _) =>
                {
                    AppLog.Note("perf", "slow moment marked by user");
                    markBtn.Content = "Marked";
                    markBtn.IsEnabled = false;
                    await PerformanceLogPrefs.MarkSlowMomentAsync(AppState.Client?.Session, SettingsFeature.AppVersion);
                    await Task.Delay(2000);
                    markBtn.Content = PerformanceLogPrefs.MarkLabel;
                    markBtn.IsEnabled = true;
                };
                markRow = Kit.Row(null, PerformanceLogPrefs.MarkLabel, PerformanceLogPrefs.MarkNote, markBtn, "about.mark");
            }
            host.Content = Kit.Page(
                Kit.Section("Hermes HQ", SettingsWords.AboutFooter,
                    Kit.Value("Version", SettingsFeature.AppVersion, "about.version"),
                    UpdatesRow(),
                    Kit.Row(null, "Hermes on Your Gateway", null, gateway)),
                Kit.Section(null, null,
                    LinkRow("Support", SettingsWords.SupportUrl),
                    LinkRow("Privacy Policy", SettingsWords.PrivacyUrl),
                    Kit.Nav(null, LicenseNotices.PageTitle, null, () => Go(page, "licenses"), "about.licenses")),
                Kit.Section("Troubleshooting", null,
                    Kit.Nav(null, "Diagnostics", null, () => Go(page, "diagnostics"), "about.diagnostics"),
                    Kit.Toggle(null, PerformanceLogPrefs.Title, null, perfOn,
                        on => { PerformanceLogPrefs.SetEnabled(Prefs, on, AppLog.Note); Draw(); }, "about.perf-log"),
                    // Detailed Logging writes this PC's own log (Diagnostics' Share Logs), so it is always here.
                    Kit.Toggle(null, DetailedLogging.Title, DetailedLogging.Note, DetailedLogging.Enabled,
                        on => DetailedLogging.Set(Prefs, on, AppLog.Note), "about.detailed-log"),
                    markRow));
        }
        Action onUpdateChanged = () => host.DispatcherQueue?.TryEnqueue(() =>
        {
            if (host.IsLoaded) Draw();
        });
        host.Loaded += (_, _) => WindowsUpdateService.Changed += onUpdateChanged;
        host.Unloaded += (_, _) => WindowsUpdateService.Changed -= onUpdateChanged;
        Draw();
        return host;
    }

    private static Grid UpdatesRow()
    {
        var state = WindowsUpdateService.State;
        var release = WindowsUpdateService.AvailableRelease;
        var detail = WindowsUpdateService.StatusDetail;

        static Button ActionButton(string label, string id, string a11yName, Action click, bool enabled = true)
        {
            var b = Kit.Push(label, click);
            b.IsEnabled = enabled;
            AutomationProperties.SetAutomationId(b, id);
            AutomationProperties.SetName(b, a11yName);
            return b;
        }

        switch (state)
        {
            case WindowsUpdateUiState.Checking:
                return Kit.Row(null, "Software Update", detail ?? "Checking GitHub Releases…",
                    ActionButton("Checking…", "about.updates", "Checking for Updates", () => { }, enabled: false),
                    "about.updates.row");

            case WindowsUpdateUiState.Available when release != null:
            {
                var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                buttons.Children.Add(ActionButton(
                    "Install & Restart",
                    "about.updates.install",
                    $"Install Hermes HQ {release.Version.ToString(3)} and restart",
                    () => _ = WindowsUpdateService.InstallAvailableAsync()));
                buttons.Children.Add(ActionButton(
                    "Release Notes",
                    "about.updates.notes",
                    "Open Release Notes in Browser",
                    async () =>
                    {
                        try { await Windows.System.Launcher.LaunchUriAsync(new Uri(release.HtmlUrl)); }
                        catch (Exception ex) { AppLog.Error("update", ex); }
                    }));
                return Kit.Row(null, "Update Available",
                    detail ?? $"Version {release.Version.ToString(3)} is ready to install.",
                    buttons, "about.updates.row");
            }

            case WindowsUpdateUiState.Downloading:
            case WindowsUpdateUiState.Applying:
                return Kit.Row(null, "Updating Hermes HQ",
                    detail ?? "Downloading update…",
                    ActionButton("Updating…", "about.updates", "Updating Hermes HQ", () => { }, enabled: false),
                    "about.updates.row");

            case WindowsUpdateUiState.Failed:
            {
                var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                buttons.Children.Add(ActionButton(
                    "Try Again",
                    "about.updates",
                    "Try Checking for Updates Again",
                    () => _ = WindowsUpdateService.CheckAsync(silent: false)));
                buttons.Children.Add(ActionButton(
                    "GitHub Releases",
                    "about.updates.releases",
                    "Open GitHub Releases in Browser",
                    async () =>
                    {
                        try { await Windows.System.Launcher.LaunchUriAsync(new Uri(release?.HtmlUrl ?? WindowsAppUpdater.ReleasesPageUrl)); }
                        catch (Exception ex) { AppLog.Error("update", ex); }
                    }));
                return Kit.Row(null, "Software Update",
                    detail ?? "Couldn’t check for updates.",
                    buttons, "about.updates.row");
            }

            default:
                return Kit.Row(null, "Software Update",
                    detail ?? "Checks GitHub Releases for newer Windows builds.",
                    ActionButton("Check for Updates", "about.updates", "Check for Updates",
                        () => _ = WindowsUpdateService.CheckAsync(silent: false)),
                    "about.updates.row");
        }
    }

    /// Settings › About › Open-Source Licenses (AboutView.swift `LicensesView`): the intro, then one row per notice (name
    /// over "version · license"); a row opens its text. Read off the UI thread when the page opens.
    private static FrameworkElement Licenses(SettingsPage page)
    {
        var intro = new TextBlock
        {
            Text = LicenseNotices.Intro, FontSize = 13, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(14, 0, 14, 8),
            Foreground = Kit.B("TextFillColorSecondaryBrush"),
        };
        AutomationProperties.SetAutomationId(intro, "licenses.intro");
        var card = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var loading = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Padding = new Thickness(14, 12, 14, 12) };
        loading.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
        loading.Children.Add(new TextBlock { Text = "Loading…", Foreground = Kit.B("TextFillColorSecondaryBrush") });
        card.Content = Kit.Card(loading);
        var list = new StackPanel { Spacing = 6 };
        list.Children.Add(intro);
        list.Children.Add(card);
        AutomationProperties.SetAutomationId(list, "licenses.list");
        _ = Task.Run(LicenseNotices.Load).ContinueWith(t => list.DispatcherQueue?.TryEnqueue(() =>
        {
            if (t.IsCompletedSuccessfully && t.Result is { } notices)
            {
                card.Content = Kit.Card([.. notices.Select(n => (UIElement)LicenseRow(page, n))]);
                return;
            }
            var failed = new TextBlock { Text = LicenseNotices.Failure, Foreground = Kit.B("TextFillColorSecondaryBrush"), Margin = new Thickness(14, 12, 14, 12) };
            AutomationProperties.SetAutomationId(failed, "licenses.failed");
            card.Content = Kit.Card(failed);
        }));
        return Kit.Page(list);
    }

    private static Button LicenseRow(SettingsPage page, LicenseNotice notice)
    {
        var row = Kit.Nav(null, notice.Name, null, () => page.Push(notice.Name, () => LicenseText(notice)), "license-row-" + notice.Name);
        // Name over "version · license", as the Mac's row draws it (the row's own words, with the meta as its note).
        if (notice.Meta.Length > 0 && row.Content is Grid grid
            && grid.Children.OfType<StackPanel>().FirstOrDefault(p => p.Children.OfType<TextBlock>().Any(t => t.Text == notice.Name)) is { } words)
        {
            words.Children.Add(new TextBlock { Text = notice.Meta, FontSize = 12, TextWrapping = TextWrapping.Wrap, Foreground = Kit.B("TextFillColorSecondaryBrush") });
            AutomationProperties.SetName(row, $"{notice.Name}, {notice.Meta}");
        }
        return row;
    }

    /// One notice's text, re-flowed so the window wraps it.
    private static FrameworkElement LicenseText(LicenseNotice notice)
    {
        var stack = new StackPanel { Spacing = 12, Padding = new Thickness(14, 16, 14, 16) };
        if (notice.Meta.Length > 0)
            stack.Children.Add(new TextBlock { Text = notice.Meta, FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = Kit.B("TextFillColorPrimaryBrush") });
        var text = new TextBlock
        {
            FontSize = 12, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, Foreground = Kit.B("TextFillColorSecondaryBrush"),
        };
        AutomationProperties.SetAutomationId(text, "license.text");
        stack.Children.Add(text);
        _ = Task.Run(() => LicenseNotices.Reflow(notice.Text)).ContinueWith(t => text.DispatcherQueue?.TryEnqueue(() =>
        {
            if (t.IsCompletedSuccessfully) text.Text = t.Result;
        }));
        return stack;
    }

    private static Button LinkRow(string title, string url)
    {
        var row = Kit.Row(null, title, null, new FontIcon { Glyph = GLink, FontSize = 12, Foreground = Kit.B("TextFillColorTertiaryBrush") });
        var b = new Button
        {
            Content = row, Padding = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0), CornerRadius = new CornerRadius(0),
        };
        AutomationProperties.SetName(b, title);
        AutomationProperties.SetHelpText(b, $"Opens {new Uri(url).Host} in your browser.");
        b.Click += async (_, _) => await Windows.System.Launcher.LaunchUriAsync(new Uri(url));
        return b;
    }

    // ---------------------------------------------------------------- the gateway card's page

    /// The gateway in use (App/Settings/GatewayPageView.swift): its name, address, account, saved sign-in and state;
    /// Manage Gateways… (switch, rename, remove, add) and Sign Out.
    public static FrameworkElement GatewayPage(SettingsPage page)
    {
        var info = SettingsFeature.Gateway();
        if (AppState.Client is not { } client) return Kit.Page(Kit.Section(null, null, Kit.Row(null, "Signed Out")));
        var copy = Kit.Push("Copy", () => SafeClipboard.TrySetText(client.Session.Address.ToString()));
        var address = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        address.Children.Add(new TextBlock { Text = info.Host, Foreground = Kit.B("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center, IsTextSelectionEnabled = true });
        address.Children.Add(copy);
        var signOut = Kit.Push("Sign Out", async () =>
        {
            if (ShellExtensions.SignOut is { } so) { await so(page.XamlRoot); return; }
            await AppState.SignOutAsync();
            App.Window?.ShowSignIn();
        }, destructive: true);
        AutomationProperties.SetAutomationId(signOut, "settings.sign-out");
        var manage = Kit.Push(GatewaySwitchWords.ManageGateways, ManageGatewaysView.Present);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Padding = new Thickness(14, 10, 14, 10) };
        buttons.Children.Add(manage);
        buttons.Children.Add(signOut);
        return Kit.Page(
            Kit.Section("Connection", null,
                Kit.Value("Name", info.Name),
                Kit.Row(null, "Address", null, address),
                Kit.Value("Account", GatewayNaming.AccountName(client.Session.Account.Username)),
                Kit.Value("Saved Sign-In", DeviceWord.Keychain),
                Kit.Value("Status", SettingsWords.StatusLine(info.State, info.Bots, info.Version), "settings.gateway-status")),
            Kit.Card(buttons));
    }
}
