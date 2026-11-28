using System.Text.Json.Nodes;
using Hermes.Core.Capabilities;
using Hermes.Core.Gateways;
using Hermes.Core.Insights;
using Hermes.Core.Notifications;
using Hermes.Core.Sessions;
using Hermes.Core.Settings;
using Hermes.Core.Shell;
using Hermes.Core.Transcripts;
using Hermes.Core.Updates;
using HermesHQ.Features.Attachments;
using HermesHQ.Features.Capabilities;
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

/// Settings' pages (SettingsRootView's 7 Mac categories in two columns, and the pages their rows open), in the Mac's words.
internal static class SettingsPanes
{
    private static IPreferences Prefs => FilePreferences.Shared;
    private static Windows.UI.ViewManagement.UISettings? _uiSettings;

    private static bool SystemReduceTransparency()
    {
        try { return !(_uiSettings ??= new Windows.UI.ViewManagement.UISettings()).AdvancedEffectsEnabled; }
        catch { return false; }
    }

    // Segoe Fluent glyphs for the Mac's SF Symbols.
    private const string GBell = "", GHalf = "", GPalette = "", GDesktop = "", GText = "",
        GWrench = "", GClock = "", GClip = "", GFolder = "", GSmile = "", GSpeaker = "",
        GNote = "", GMic = "", GInfo = "", GPlay = "", GLink = "", GRing = "\uEA3A", GDensity = "\uE8FD",
        GBubbles = "\uE8F2", GSidebar = "\uE90C", GSparkle = "\uE734", GKey = "\uE8D7", GBolt = "\uE945",
        GCard = "\uE8C7", GPeople = "\uE77B", GHook = "\uE71B", GImport = "\uE896", GTransparency = "\uE7F4",
        GCorners = "\uE739", GStrip = "\uE8A1", GSend = "\uE724", GResume = "\uE777", GTip = "\uE82F", GUpdate = "\uE895";

    public static FrameworkElement Category(SettingsPage page, SettingsCategory c) => c switch
    {
        SettingsCategory.General => General(page),
        SettingsCategory.Appearance => Appearance(page),
        SettingsCategory.Chat => Chat(page),
        SettingsCategory.Gateway => HermesCategory(page),
        SettingsCategory.Accounts => AccountsCategory(page),
        SettingsCategory.Tools => ToolsCategory(page),
        SettingsCategory.About => AboutCategory(page),
        SettingsCategory.Sounds => General(page),
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
        "proactivity-beta" => (ProactivityBeta.PageLabel, () => ProactivityBetaPane.Make(page)),
        "models" => (SettingsWords.ModelsLabel, () => ModelSettingsPane.MakeHub(page)),
        "main-model" => (SettingsWords.MainModelLabel, () => ModelSettingsPane.MakeMainModel(page)),
        "fallback-models" => (SettingsWords.FallbackModelsLabel, () => ModelSettingsPane.MakeFallbackModels(page)),
        "auxiliary-models" => (SettingsWords.AuxiliaryModelsLabel, () => ModelSettingsPane.MakeAuxiliaryModels(page)),
        "moa" => (SettingsWords.MoaLabel, () => ModelSettingsPane.MakeMoa(page)),
        "tile-model" => ("Tile Model", () => TileModelPane.Make(page)),
        "voice" => ("Voice", () => Voice()),
        "sessions" => (SettingsWords.SessionsPageTitle, () => Sessions()),
        "browser-cloud" => ("Browser Use Cloud", () => Browser.BrowserFeature.BuildCloudSettingsContent()),
        "vault" => ("Passwords", () => VaultPane(page)),
        "providers" => ("Providers", () => ModelSettingsPane.MakeProviders()),
        "keys" => ("Keys", () => ModelSettingsPane.MakeKeys()),
        "billing" => ("Billing", () => ModelSettingsPane.MakeBilling()),
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

    // ---------------------------------------------------------------- General (SettingsRootView.swift `e27566897`: System & Alerts + App & Sharing)

    private static FrameworkElement General(SettingsPage page)
    {
        var host = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var soundPrefs = new CompletionSoundPrefs(Prefs);
        var configStore = AppState.Client is { } client ? ConfigStore(client) : null;
        var disposed = false;

        bool ResumeLastSession()
        {
            if (configStore?.Config != null && configStore.Value("display.resume_last_session") is JsonValue v && v.TryGetValue(out bool b))
                return b;
            return ChatPrefs.ResumeLastSessionFallback;
        }

        void SetResumeLastSession(bool on)
        {
            ChatPrefs.ResumeLastSessionFallback = on;
            if (configStore == null) return;
            if (configStore.Config == null)
            {
                _ = configStore.LoadAsync().ContinueWith(_ => configStore.Set("display.resume_last_session", JsonValue.Create(on)));
            }
            else
            {
                configStore.Set("display.resume_last_session", JsonValue.Create(on));
            }
        }

        void Draw()
        {
            var n = NotificationPrefs.Load(Prefs);
            UIElement? soundRow = null;
            if (soundPrefs.IsOn)
            {
                var name = CompletionSoundSynth.Find(soundPrefs.Variant).Name;
                var trailing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
                var play = new Button
                {
                    Content = new FontIcon { Glyph = GPlay, FontSize = 14 },
                    Padding = new Thickness(8, 6, 8, 6),
                    Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                    BorderThickness = new Thickness(0),
                };
                AutomationProperties.SetName(play, $"Play {name}");
                ToolTipService.SetToolTip(play, $"Play {name}");
                play.Click += (_, _) => CompletionCue.Preview(soundPrefs.Variant);
                trailing.Children.Add(play);
                var box = new ComboBox { MinWidth = 160, MaxWidth = Kit.DefaultPickerMaxWidth };
                foreach (var p in CompletionSoundSynth.Presets) box.Items.Add(p.Name);
                box.SelectedIndex = CompletionSoundSynth.Presets.ToList().FindIndex(p => p.Id == soundPrefs.Variant);
                AutomationProperties.SetName(box, "Sound");
                AutomationProperties.SetAutomationId(box, "settings.sound");
                box.SelectionChanged += (_, _) =>
                {
                    if (box.SelectedIndex < 0) return;
                    var id = CompletionSoundSynth.Presets[box.SelectedIndex].Id;
                    if (id == soundPrefs.Variant) return;
                    soundPrefs.Variant = id;
                    CompletionCue.Preview(id);
                    Draw();
                };
                trailing.Children.Add(box);
                soundRow = Kit.Row(GNote, "Sound", null, trailing, "row:sound");
            }

            UIElement? addOnSection = null;
            if (AddOnReminder.HasUpdate && AppState.Client is { } activeClient)
            {
                var badge = ReminderBadge("1");
                var rowTitle = AddOnReminder.TargetVersion is { Length: > 0 } targetVer
                    ? $"Add-on Update Available ({targetVer})"
                    : "Add-on Update Available";
                addOnSection = Kit.Section(null, AddOnReminder.Summary,
                    ReminderNavRow(GUpdate, rowTitle, badge,
                        () => _ = AddOnUpdateDialog.ShowAsync(page.XamlRoot, activeClient),
                        "settings.addon-update"));
            }

            UIElement? pluginSection = null;
            if (PluginUpdateReminder.AvailableCount > 0)
            {
                var label = PluginUpdateReminder.BadgeLabel ?? PluginUpdateReminder.AvailableCount.ToString();
                var rowTitle = PluginUpdateReminder.Title ?? "Plugin Update Available";
                pluginSection = Kit.Section(null, PluginUpdateReminder.Footer,
                    ReminderNavRow(GWrench, rowTitle, ReminderBadge(label),
                        () => Navigator.Open("capabilities"),
                        "settings.plugin-update"));
            }

            host.Content = Kit.Page(
                addOnSection,
                pluginSection,
                Kit.Section("System & Alerts", null,
                    Kit.Nav(GBell, "Notifications", n.Enabled ? "On" : "Off", () => Go(page, "notifications"), "settings.notifications"),
                    Kit.Toggle(GSpeaker, "Completion Sound", null, soundPrefs.IsOn, on => { soundPrefs.IsOn = on; Draw(); }, "row:completion-sound"),
                    soundRow,
                    Kit.Nav(GMic, "Voice", null, () => Go(page, "voice"), "settings.general.voice"),
                    configStore != null
                        ? Kit.Nav(GSparkle, ProactivityBeta.PageLabel, "Beta", () => Go(page, "proactivity-beta"), "settings.proactivity-beta")
                        : null),
                Kit.Section("App & Sharing", null,
                    configStore != null
                        ? Kit.Toggle(GResume, SettingsWords.ResumeLastChatLabel, SettingsWords.ResumeLastChatNote,
                            ResumeLastSession(), SetResumeLastSession, "row:resume-last-chat")
                        : null,
                    Kit.Toggle(GTip, SettingsWords.InAppTipsLabel, null, ChatPrefs.InAppTips, on => ChatPrefs.InAppTips = on, "row:tips")));
        }

        void OnConfigChanged()
        {
            if (disposed) return;
            host.DispatcherQueue?.TryEnqueue(() => { if (!disposed) Draw(); });
        }

        if (configStore != null)
        {
            configStore.Changed += OnConfigChanged;
            _ = configStore.LoadAsync();
        }
        AddOnReminder.Changed += OnConfigChanged;
        PluginUpdateReminder.Changed += OnConfigChanged;
        host.Unloaded += (_, _) =>
        {
            disposed = true;
            AddOnReminder.Changed -= OnConfigChanged;
            PluginUpdateReminder.Changed -= OnConfigChanged;
            if (configStore != null)
            {
                configStore.Changed -= OnConfigChanged;
                _ = configStore.Flush();
            }
        };

        Draw();
        return host;
    }

    private static Border ReminderBadge(string text) => new()
    {
        CornerRadius = new CornerRadius(10),
        Padding = new Thickness(7, 1, 7, 2),
        Background = Kit.B("SystemFillColorCriticalBrush"),
        VerticalAlignment = VerticalAlignment.Center,
        Child = new TextBlock
        {
            Text = text,
            FontSize = 11,
            FontWeight = FontWeights.SemiBold,
            Foreground = new SolidColorBrush(Microsoft.UI.Colors.White),
        },
    };

    private static Button ReminderNavRow(string glyph, string title, UIElement badge, Action open, string id)
    {
        var trailing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        trailing.Children.Add(badge);
        trailing.Children.Add(new FontIcon { Glyph = "", FontSize = 11, Foreground = Kit.B("TextFillColorTertiaryBrush"), VerticalAlignment = VerticalAlignment.Center });
        var row = Kit.Row(glyph, title, null, trailing, id);
        var button = new Button
        {
            Content = row,
            Padding = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(0),
            Tag = id,
        };
        AutomationProperties.SetName(button, title);
        AutomationProperties.SetAutomationId(button, id);
        button.Click += (_, _) => open();
        return button;
    }

    // ---------------------------------------------------------------- Appearance (AppearancePage.swift: LookModePicker, HermesCornersRow, Window Transparency, BotChatsStyle, Reset)

    private static FrameworkElement Appearance(SettingsPage page)
    {
        var state = ThemeService.State;
        var reduceTransparency = SystemReduceTransparency();

        UIElement lightOrDark;
        if (global::Hermes.Core.Settings.Appearance.ForcedBy(state.Skin) is { } forced)
        {
            lightOrDark = Kit.Row(GHalf, "Light or Dark", null,
                new TextBlock { Text = forced.Title(), Foreground = Kit.B("TextFillColorSecondaryBrush") },
                "row:appearance");
        }
        else
        {
            lightOrDark = Kit.Picker(GHalf, "Light or Dark", null,
                [.. Enum.GetValues<AppearanceSetting>().Select(a => (a.Title(), a))], ThemeService.Chosen,
                a => ThemeService.SetAppearance(a), "row:appearance");
        }

        var transparencyToggle = Kit.Toggle(GTransparency, SettingsWords.WindowTransparencyLabel, null,
            WindowTransparency.IsEffective(reduceTransparency),
            on => ThemeService.SetWindowTransparency(on),
            "row:window-transparency", enabled: !reduceTransparency);
        foreach (var t in transparencyToggle.Children.OfType<ToggleSwitch>())
            AutomationProperties.SetAutomationId(t, "settings.window-transparency");

        UIElement? highContrastRow = null;
        UIElement? cornersRow = null;
        if (state.DesktopLook)
        {
            highContrastRow = Kit.Toggle(GHalf, "High Contrast", null, state.HighContrast,
                on => ThemeService.SetHighContrast(on), "row:high-contrast");
            foreach (var t in ((Grid)highContrastRow).Children.OfType<ToggleSwitch>())
                AutomationProperties.SetAutomationId(t, "theme.highContrast");
            cornersRow = HermesCornersRow(state);
        }

        var resetButton = Kit.Push(SettingsWords.ResetAppearanceLabel, async () =>
        {
            var dialog = new ContentDialog
            {
                Title = SettingsWords.ResetAppearanceTitle,
                Content = new TextBlock { Text = SettingsWords.ResetAppearanceMessage, TextWrapping = TextWrapping.Wrap },
                PrimaryButtonText = SettingsWords.ResetAppearanceAction,
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Close,
            };
            if (await SafeDialog.ShowAsync(page.XamlRoot, dialog) != ContentDialogResult.Primary) return;
            ThemeService.ResetAppearance();
            BackdropPainter.Prefs.Reset(BackdropPlace.App);
            BackdropPainter.Prefs.Reset(BackdropPlace.Chats);
            BotChatsStylePrefs.Current = BotChatsStyleKind.Branch;
        }, destructive: true);
        resetButton.HorizontalAlignment = HorizontalAlignment.Center;
        AutomationProperties.SetAutomationId(resetButton, "settings.appearance-reset");
        var resetWrap = new StackPanel { Padding = new Thickness(14, 10, 14, 10), HorizontalAlignment = HorizontalAlignment.Stretch };
        resetWrap.Children.Add(resetButton);

        return Kit.Page(
            Kit.Section("Look", SettingsWords.AppearanceLookFooter(state, reduceTransparency),
                LookModePicker(state),
                lightOrDark,
                Kit.Nav(GPalette, "Theme", state.Skin.Label, () => Go(page, "theme"), "settings.theme-row"),
                transparencyToggle,
                highContrastRow,
                cornersRow),
            Kit.Section("Text Size", SettingsWords.ScaleNote, UiScaleRow()),
            // [theme-pages] Chats (AppearancePage `chats`): Chat Bubbles, Backgrounds (Native look), Thinking Bar.
            Kit.Section(ChatBubbles.SectionTitle, null,
                Kit.Nav(GBubbles, ChatBubbles.Label, ChatBubbles.Value(state), () => Go(page, ChatBubbles.Target), ChatBubbles.RowId),
                !state.DesktopLook ? Kit.Nav(GPalette, BackdropPrefs.Title, BackdropPainter.Prefs.Load(BackdropPlace.Chats).Summary(BackdropPainter.Prefs.Load(BackdropPlace.App)), () => Go(page, BackdropPrefs.Target), "settings.backgrounds") : null,
                ThinkingBarControl()),
            // [density] [working-ring] [chats-under] Bots & Sessions (AppearancePage `lists`): Density, BotChatsStyle, Working Ring.
            Kit.Section(WorkingRing.SectionTitle, DensityRow.ListsNote(state),
                DensityRow.Shown(state) ? DensityControl(state) : null,
                BotChatsStyleControl(),
                WorkingRingRow()),
            // [taborder] App (AppearancePage `app`): Sidebar, plus Chats Under Bots limit.
            Kit.Section(SidebarPage.AppSection, null,
                Kit.Nav(GSidebar, SidebarPage.Title, null, () => Go(page, SidebarPage.Target), SidebarPage.RowId),
                ChatsUnderBotsControl()),
            Kit.Section(null, SettingsWords.AppearanceStayFooter, resetWrap));
    }

    /// Visual two-card Look switcher (`Native` | `Hermes`) at the top of Settings › Appearance
    /// (App/Settings/Appearance/AppearancePage.swift `LookModePicker`).
    private static FrameworkElement LookModePicker(ThemeState state)
    {
        var grid = new Grid { ColumnSpacing = 10, Padding = new Thickness(14, 12, 14, 12), Tag = "row:desktop-look" };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        AutomationProperties.SetAutomationId(grid, "theme.desktopLook");

        var nativeCard = LookCard("Native", isHermes: false, selected: !state.DesktopLook, state);
        var hermesCard = LookCard("Hermes", isHermes: true, selected: state.DesktopLook, state);
        grid.Children.Add(nativeCard);
        Grid.SetColumn(hermesCard, 1);
        grid.Children.Add(hermesCard);
        return grid;
    }

    private static Button LookCard(string title, bool isHermes, bool selected, ThemeState state)
    {
        var outerCorner = state.DesktopLook ? state.ShapeRadius(ShapeRole.Card, 12) : 12;
        var miniCorner = isHermes ? Math.Min(9, state.ShapeRadius(ShapeRole.Card, 9)) : 9;
        var miniBubble = isHermes ? Math.Min(5.5, state.ShapeRadius(ShapeRole.Control, 5.5)) : 5.5;

        var previewContent = new StackPanel { Spacing = 6 };
        if (isHermes)
        {
            previewContent.Children.Add(new Border
            {
                Width = 68, Height = 6, CornerRadius = new CornerRadius(3), HorizontalAlignment = HorizontalAlignment.Left,
                Background = Kit.B("TextFillColorSecondaryBrush"), Opacity = 0.5,
            });
            previewContent.Children.Add(new Border
            {
                Width = 48, Height = 11, CornerRadius = new CornerRadius(miniBubble), HorizontalAlignment = HorizontalAlignment.Right,
                Background = Kit.B("HQMeBubbleBrush"), BorderBrush = Kit.B("AccentTextFillColorPrimaryBrush"), BorderThickness = new Thickness(1),
            });
        }
        else
        {
            previewContent.Children.Add(new Border
            {
                Width = 62, Height = 10, CornerRadius = new CornerRadius(5), HorizontalAlignment = HorizontalAlignment.Left,
                Background = Kit.B("HQBotBubbleBrush"),
            });
            previewContent.Children.Add(new Border
            {
                Width = 44, Height = 10, CornerRadius = new CornerRadius(5), HorizontalAlignment = HorizontalAlignment.Right,
                Background = Kit.B("AccentFillColorDefaultBrush"),
            });
        }

        var mini = new Border
        {
            Child = previewContent,
            Padding = new Thickness(8),
            MinHeight = 46,
            CornerRadius = new CornerRadius(miniCorner),
            Background = Kit.B("HQPageBrush"),
            BorderBrush = Kit.B("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1),
        };
        AutomationProperties.SetAccessibilityView(mini, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);

        var labelRow = new Grid();
        labelRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        labelRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        labelRow.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        if (selected)
        {
            var check = new FontIcon
            {
                Glyph = "\uE73E", FontSize = 12, VerticalAlignment = VerticalAlignment.Center,
                Foreground = Kit.B("AccentTextFillColorPrimaryBrush"),
            };
            Grid.SetColumn(check, 1);
            labelRow.Children.Add(check);
        }

        var content = new StackPanel { Spacing = 8 };
        content.Children.Add(mini);
        content.Children.Add(labelRow);

        var btn = new Button
        {
            Content = content,
            Padding = new Thickness(9),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            CornerRadius = new CornerRadius(outerCorner),
            Background = Kit.B("HQGroupedBrush"),
            BorderBrush = Kit.B(selected ? "AccentTextFillColorPrimaryBrush" : "CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(selected ? 2 : 1),
        };
        AutomationProperties.SetName(btn, $"{title} Look" + (selected ? ", selected" : ""));
        AutomationProperties.SetAutomationId(btn, isHermes ? "theme.desktopLook.desktop" : "theme.desktopLook.ios");
        btn.Click += (_, _) =>
        {
            if (ThemeService.State.DesktopLook != isHermes) ThemeService.SetDesktopLook(isHermes);
        };
        return btn;
    }

    /// [desktop-radius] Appearance › Look › Corners: continuous slider (0–20 pt) + live miniature corner preview +
    /// tappable preset ticks + Reset back to 4 pt (App/Settings/Appearance/AppearancePage.swift `HermesCornersRow`).
    private static FrameworkElement HermesCornersRow(ThemeState state)
    {
        var stored = (int)Math.Round(state.DesktopRadius);
        var stack = new StackPanel { Padding = new Thickness(14, 10, 14, 12), Spacing = 10, Tag = "row:hermes-corners" };

        var header = new Grid { ColumnSpacing = 8 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var titleStack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        titleStack.Children.Add(new FontIcon { Glyph = GCorners, FontSize = 16, VerticalAlignment = VerticalAlignment.Center });
        titleStack.Children.Add(new TextBlock { Text = SettingsWords.HermesCornersLabel, VerticalAlignment = VerticalAlignment.Center });
        header.Children.Add(titleStack);

        var pointsText = new TextBlock
        {
            Text = $"{stored} pt",
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = Kit.B("TextFillColorSecondaryBrush"),
        };
        Grid.SetColumn(pointsText, 1);
        header.Children.Add(pointsText);

        var resetBtn = new HyperlinkButton
        {
            Content = "Reset",
            Padding = new Thickness(4, 0, 4, 0),
            Visibility = stored != 4 ? Visibility.Visible : Visibility.Collapsed,
        };
        AutomationProperties.SetAutomationId(resetBtn, "theme.desktopRadiusReset");
        resetBtn.Click += (_, _) => ThemeService.ResetDesktopRadius();
        Grid.SetColumn(resetBtn, 2);
        header.Children.Add(resetBtn);
        stack.Children.Add(header);

        // Live miniature showing a Hermes card, Primary button, outlined Button, Tag pill, and bubble morphing together.
        var primaryBtn = new Border
        {
            Padding = new Thickness(10, 4, 10, 4),
            Background = Kit.B("AccentFillColorDefaultBrush"),
            Child = new TextBlock { Text = "Primary", FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = Kit.B("TextOnAccentFillColorPrimaryBrush") },
        };
        var outlinedBtn = new Border
        {
            Padding = new Thickness(10, 4, 10, 4),
            BorderBrush = Kit.B("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1),
            Child = new TextBlock { Text = "Button", FontSize = 11, Foreground = Kit.B("TextFillColorPrimaryBrush") },
        };
        var tagChip = new Border
        {
            Padding = new Thickness(8, 3, 8, 3),
            Background = Kit.B("HQSettingsFieldBrush"),
            Child = new TextBlock { Text = "Tag", FontSize = 10, FontWeight = FontWeights.Medium, Foreground = Kit.B("TextFillColorSecondaryBrush") },
        };
        var hiBubble = new Border
        {
            Padding = new Thickness(9, 3, 9, 3),
            HorizontalAlignment = HorizontalAlignment.Right,
            Background = Kit.B("HQMeBubbleBrush"),
            BorderBrush = Kit.B("HQMeBorderBrush"),
            BorderThickness = new Thickness(1),
            Child = new TextBlock { Text = "Hi!", FontSize = 11, Foreground = Kit.B("HQMeTextBrush") },
        };
        var previewGrid = new Grid { ColumnSpacing = 8 };
        previewGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        previewGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        previewGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        previewGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        previewGrid.Children.Add(primaryBtn);
        Grid.SetColumn(outlinedBtn, 1); previewGrid.Children.Add(outlinedBtn);
        Grid.SetColumn(tagChip, 2); previewGrid.Children.Add(tagChip);
        Grid.SetColumn(hiBubble, 3); previewGrid.Children.Add(hiBubble);

        var previewCard = new Border
        {
            Child = previewGrid,
            Padding = new Thickness(10),
            Background = Kit.B("HQEditorBrush"),
            BorderBrush = Kit.B("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1),
        };
        AutomationProperties.SetAccessibilityView(previewCard, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        stack.Children.Add(previewCard);

        void PaintPreview(double pts)
        {
            var probe = state with { DesktopRadius = pts };
            var cardR = probe.ShapeRadius(ShapeRole.Card, 12);
            var ctrlR = Math.Min(13, probe.ShapeRadius(ShapeRole.Control, 8));
            var pillR = Math.Min(11, probe.ShapeRadius(ShapeRole.Capsule, 11));
            var bubbleR = Math.Min(13, cardR);
            previewCard.CornerRadius = new CornerRadius(cardR);
            primaryBtn.CornerRadius = new CornerRadius(ctrlR);
            outlinedBtn.CornerRadius = new CornerRadius(ctrlR);
            tagChip.CornerRadius = new CornerRadius(pillR);
            hiBubble.CornerRadius = new CornerRadius(bubbleR);
        }
        PaintPreview(stored);

        var slider = new Slider
        {
            Minimum = 0, Maximum = 20, StepFrequency = 1, Value = stored,
            IsThumbToolTipEnabled = false, HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        AutomationProperties.SetName(slider, "Hermes Corners");
        AutomationProperties.SetAutomationId(slider, "theme.desktopRadius");
        AutomationProperties.SetItemStatus(slider, $"{stored} points");

        void Commit()
        {
            var at = Math.Round(slider.Value);
            if (Math.Abs(at - ThemeService.State.DesktopRadius) >= 0.5) ThemeService.SetDesktopRadius(at);
        }

        slider.ValueChanged += (_, e) =>
        {
            var at = (int)Math.Round(e.NewValue);
            pointsText.Text = $"{at} pt";
            resetBtn.Visibility = at != 4 ? Visibility.Visible : Visibility.Collapsed;
            AutomationProperties.SetItemStatus(slider, $"{at} points");
            PaintPreview(at);
        };
        slider.AddHandler(UIElement.PointerReleasedEvent, new Microsoft.UI.Xaml.Input.PointerEventHandler((_, _) => Commit()), true);
        slider.AddHandler(UIElement.PointerCaptureLostEvent, new Microsoft.UI.Xaml.Input.PointerEventHandler((_, _) => Commit()), true);
        slider.AddHandler(UIElement.KeyUpEvent, new Microsoft.UI.Xaml.Input.KeyEventHandler((_, _) => Commit()), true);
        slider.LostFocus += (_, _) => Commit();

        var track = new Grid { ColumnSpacing = 10 };
        track.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        track.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var square = new Border { Width = 14, Height = 14, CornerRadius = new CornerRadius(2), BorderThickness = new Thickness(1.5), BorderBrush = Kit.B("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center };
        var capsule = new Border { Width = 22, Height = 12, CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(1.5), BorderBrush = Kit.B("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetAccessibilityView(square, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        AutomationProperties.SetAccessibilityView(capsule, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        track.Children.Add(square);
        Grid.SetColumn(slider, 1); track.Children.Add(slider);
        Grid.SetColumn(capsule, 2); track.Children.Add(capsule);
        stack.Children.Add(track);

        // Tappable preset ticks 0, 4, 8, 12, 16, 20.
        int[] ticks = [0, 4, 8, 12, 16, 20];
        var tickGrid = new Grid { Margin = new Thickness(20, 0, 20, 0) };
        for (var i = 0; i < ticks.Length; i++)
        {
            var tick = ticks[i];
            tickGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var btn = new Button
            {
                Content = tick.ToString(),
                FontSize = 11,
                FontWeight = tick == stored ? FontWeights.SemiBold : FontWeights.Normal,
                Foreground = Kit.B(tick == stored ? "TextFillColorPrimaryBrush" : "TextFillColorTertiaryBrush"),
                Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                BorderThickness = new Thickness(0),
                Padding = new Thickness(4, 2, 4, 2),
                HorizontalAlignment = HorizontalAlignment.Center,
            };
            AutomationProperties.SetName(btn, $"{tick} points");
            AutomationProperties.SetAutomationId(btn, $"theme.desktopRadius.{tick}");
            btn.Click += (_, _) => ThemeService.SetDesktopRadius(tick);
            Grid.SetColumn(btn, i);
            tickGrid.Children.Add(btn);
        }
        stack.Children.Add(tickGrid);
        return stack;
    }

    /// [theme-pages] Settings › Appearance › Chat Bubbles (ThemeSettingsView.swift `ChatBubblesSettingsView`):
    /// live `hasChatBackground` from `BackdropPainter.Prefs` + Reply Bubbles toggle (`ThemeService.SetPlainReplies`).
    private static FrameworkElement ChatBubblesPage()
    {
        var state = ThemeService.State;
        var appBg = BackdropPainter.Prefs.Load(BackdropPlace.App);
        var hasChatBackground = BackdropPainter.Prefs.Load(BackdropPlace.Chats).EffectiveSource(appBg) != null;
        var footer = string.Join("\n\n", ChatBubbles.Footer(state, hasChatBackground: hasChatBackground));
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

        // [plain-replies] Reply Bubbles toggle (ThemeSettingsView.swift `replyBubblesRow`).
        var replyDisabledNote = ChatBubbles.ReplyBubblesDisabledNote(state, ThemeService.Dark);
        var replyBubblesRow = Kit.Toggle(null, ChatBubbles.ReplyBubblesLabel,
            replyDisabledNote ?? ChatBubbles.ReplyBubblesNote,
            ChatBubbles.ReplyBubblesOn(state, ThemeService.Dark),
            on => ThemeService.SetPlainReplies(!on),
            "row:reply-bubbles", enabled: replyDisabledNote == null);
        foreach (var t in replyBubblesRow.Children.OfType<ToggleSwitch>())
            AutomationProperties.SetAutomationId(t, ChatBubbles.ReplyBubblesId);

        var root = Kit.Page(Kit.Section(null, footer, BubbleCornersRow(state), tinted, replyBubblesRow));
        AutomationProperties.SetAutomationId(root, ChatBubbles.PageId);
        return root;
    }

    /// [theme-pages] Corners (`BubbleCornersRow`): a reply and your message as the chat draws them, then "Corners" and its
    /// points, then the slider (square to capsule).
    private static FrameworkElement BubbleCornersRow(ThemeState state)
    {
        var stored = ChatBubbles.Corners(state);
        var stack = new StackPanel { Padding = new Thickness(14, 10, 14, 12), Spacing = 12, Tag = ChatBubbles.CornersId };
        var preview = new StackPanel { Spacing = 10 };
        var replyText = new TextBlock
        {
            Text = "Your report is ready. It’s in Files, and I can send it to Ivy as well.", TextWrapping = TextWrapping.Wrap,
            Foreground = Kit.B("TextFillColorPrimaryBrush"),
        };
        if (state.AppliedPlainReplies)
        {
            preview.Children.Add(replyText);
        }
        else
        {
            preview.Children.Add(new Border
            {
                Child = replyText,
                Padding = new Thickness(12, 8, 12, 8),
                CornerRadius = new CornerRadius(stored),
                HorizontalAlignment = HorizontalAlignment.Left,
                Background = Kit.B("HQBotBubbleBrush"),
            });
        }
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
        AutomationProperties.SetAccessibilityView(line, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        stack.Children.Add(line);
        var slider = new Slider
        {
            Minimum = ChatBubbles.Range.Min, Maximum = ChatBubbles.Range.Max, StepFrequency = 1, Value = stored,
            IsThumbToolTipEnabled = false, HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        AutomationProperties.SetName(slider, ChatBubbles.CornersName);
        AutomationProperties.SetAutomationId(slider, ChatBubbles.CornersId);
        AutomationProperties.SetItemStatus(slider, ChatBubbles.CornersSpoken(stored));
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

    /// [density] Standard / Compact as two segments at the row's end.
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

    private static FrameworkElement BotChatsStyleControl()
    {
        var options = BotChatsStylePrefs.All.Select(k => (BotChatsStylePrefs.Label(k), k)).ToList();
        return Kit.Picker(null, SettingsWords.BotChatsStyleLabel, null, options, BotChatsStylePrefs.Current,
            v => BotChatsStylePrefs.Current = v, "row:bot-chats-style");
    }

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
        var cols = ThemeService.AccessibilityTextSize ? 1 : 2;
        var grid = new Grid { ColumnSpacing = 12, RowSpacing = 12 };
        for (var c = 0; c < cols; c++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var skins = SkinCatalog.All;
        for (var i = 0; i < skins.Count; i++)
        {
            if (i % cols == 0) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var card = SkinCard(skins[i], skins[i].Id == state.SkinId, state);
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
            state.DesktopLook
                ? Kit.Section(null, SettingsWords.ContrastNote,
                    Kit.Toggle(null, "High Contrast", null, state.HighContrast, on => ThemeService.SetHighContrast(on), "theme.highContrast"))
                : null);
    }

    private static FrameworkElement SkinCard(Skin skin, bool chosen, ThemeState state)
    {
        var preview = new Grid { Height = 72, CornerRadius = new CornerRadius(state.DesktopLook ? Math.Min(6, state.ShapeRadius(ShapeRole.Control, 6)) : 6) };
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
            VerticalContentAlignment = VerticalAlignment.Top,
            CornerRadius = new CornerRadius(state.ShapeRadius(ShapeRole.Card, 10)),
            BorderThickness = new Thickness(chosen ? 2 : 1), Background = Kit.B("CardBackgroundFillColorDefaultBrush"),
            BorderBrush = chosen ? Kit.B("AccentFillColorDefaultBrush") : Kit.B("CardStrokeColorDefaultBrush"),
        };
        AutomationProperties.SetName(button, skin.Label + (chosen ? ", chosen" : ""));
        AutomationProperties.SetHelpText(button, skin.Description);
        AutomationProperties.SetAutomationId(button, "theme.skin." + skin.Id);
        button.Click += (_, _) => { if (!chosen) ThemeService.PickSkin(skin.Id); };
        return button;
    }

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

    // ---------------------------------------------------------------- Chat (ChatSettingsPage.swift `e27566897`: 4 grouped sections)

    private static FrameworkElement Chat(SettingsPage page)
    {
        var attachment = new StackPanel { Padding = new Thickness(14, 10, 14, 10), Tag = "row:attachment-limit" };
        attachment.Children.Add(new LargestAttachmentRow());

        var sessionStripRow = Kit.Toggle(GStrip, SettingsWords.SessionStripLabel, null,
            SessionStripRules.IsEnabled, on => SessionStripRules.IsEnabled = on, "row:session-strip");
        foreach (var t in sessionStripRow.Children.OfType<ToggleSwitch>())
            AutomationProperties.SetAutomationId(t, "settings.session-strip");

        UIElement? clearModelsRow = null;
        if (AppState.Client is { } client && client.AccountId is { } account)
        {
            var models = Composer.ComposerServices.Prefs(account);
            var clearStatus = new TextBlock
            {
                FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(14, 0, 14, 0),
                Visibility = Visibility.Collapsed, Foreground = Kit.B("TextFillColorSecondaryBrush"),
            };
            var clearWrap = new StackPanel { Spacing = 4 };
            var ui = new SettingsFileUi(clearWrap, (_, _) => { });
            var actions = new SettingsFileActions(ConfigStore(client), ui) { Models = models };
            page.FileActions = (actions, clearWrap);
            actions.StatusChanged += text => clearWrap.DispatcherQueue?.TryEnqueue(() =>
            {
                clearStatus.Text = text ?? "";
                clearStatus.Visibility = text == null ? Visibility.Collapsed : Visibility.Visible;
            });
            var clearBtn = Kit.Push(SettingsFileWords.ClearModels, () => _ = actions.ConfirmClearModelsAsync());
            AutomationProperties.SetAutomationId(clearBtn, "settings.clear-models");
            clearWrap.Children.Add(Kit.Row(GSparkle, "Favorite & Recent Models", null, clearBtn, "row:clear-models"));
            clearWrap.Children.Add(clearStatus);
            clearModelsRow = clearWrap;
        }

        return Kit.Page(
            // 1. Conversation Display
            Kit.Section("Conversation Display", null,
                Kit.Nav(GWrench, "Tool Calls", ChatDisplaySettings.Style.Title(), () => Go(page, "tool-calls"), "settings.tool-calls"),
                Kit.Toggle(GClock, "Fewer Timestamps", SettingsWords.FewerTimestampsNote, ChatDisplaySettings.FewerTimestamps,
                    on => ChatDisplaySettings.FewerTimestamps = on, "row:fewer-timestamps"),
                Kit.Toggle(GSmile, "Message Reactions", SettingsWords.MessageReactionsNote, ChatDisplaySettings.Reactions,
                    on => ChatDisplaySettings.Reactions = on, "row:message-reactions"),
                Kit.Toggle(null, SettingsWords.IntroSplashLabel, null, Hermes.Core.Chat.ChatIntro.IsOn,
                    on => Hermes.Core.Chat.ChatIntro.IsOn = on, "row:intro-splash")),
            // 2. Toolbar & Navigation
            Kit.Section("Toolbar & Navigation", null,
                Kit.Toggle(GFolder, SettingsWords.FileBrowserLabel, null, ChatPrefs.FileBrowser, on => ChatPrefs.FileBrowser = on, "row:file-browser"),
                sessionStripRow),
            // 3. Sending & New Chats
            Kit.Section("Sending & New Chats", null,
                Kit.Picker(GSend, SettingsWords.SendWhileBusyLabel, SettingsWords.SendWhileBusyNote,
                    [("Steer", "steer"), ("Queue", "queue")], ChatPrefs.SendWhileBusy,
                    v => ChatPrefs.SendWhileBusy = v, "row:send-while-busy"),
                Kit.Toggle(GFolder, SettingsWords.NewChatAsksProjectLabel, SettingsWords.NewChatAsksProjectNote,
                    ChatPrefs.NewChatAsksProject, on => ChatPrefs.NewChatAsksProject = on, "row:new-chat-asks-project"),
                attachment),
            // 4. Models
            Kit.Section(SettingsWords.ModelsLabel, null,
                Kit.Nav(GBolt, SettingsWords.ModelsLabel, null, () => Go(page, "models"), "settings.models"),
                Kit.Nav(GSparkle, SettingsWords.AuxiliaryModelsLabel, null, () => Go(page, "auxiliary-models"), "settings.auxiliary-models"),
                clearModelsRow));
    }

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

    // ---------------------------------------------------------------- Hermes (Gateway): Behavior & Runtime + Backup & Reset

    private static FrameworkElement HermesCategory(SettingsPage page)
    {
        page.FileActions = null;
        return Kit.Page(
            Kit.Section("Behavior & Runtime",
                $"Voice’s Read Replies Aloud and Send Memo on Release, and the default project folder, are kept on this {DeviceWord.Name}.",
                Kit.Nav(GBolt, SettingsWords.ModelsLabel, null, () => Go(page, "models"), "settings.config.models"),
                Kit.Nav(GMic, "Voice", null, () => Go(page, "voice"), "settings.config.voice"),
                Kit.Nav(GFolder, SettingsWords.SessionsPageTitle, null, () => Go(page, "sessions"), "settings.sessions"),
                Kit.Nav(GLink, "Browser Use Cloud", null, () => Go(page, "browser-cloud"), "settings.browser-cloud")),
            AppState.Client is { } client
                ? FileActionsSection(page, ConfigStore(client), client.AccountId is { } account ? Composer.ComposerServices.Prefs(account) : null)
                : null);
    }

    private static readonly System.Runtime.CompilerServices.ConditionalWeakTable<global::Hermes.Core.HermesClient, GatewayConfigStore> ConfigStores = new();

    private static GatewayConfigStore ConfigStore(global::Hermes.Core.HermesClient client)
    {
        GatewayConfigStore.Log ??= line => AppLog.Note("settings", line);
        return ConfigStores.GetValue(client, c => new GatewayConfigStore(new GatewayConfigApi(c.Session)));
    }

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
        var status = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
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
            copy!.Content = "Copied";
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

    // ---------------------------------------------------------------- Accounts & Keys (SettingsRootView.swift `e27566897`)

    private static FrameworkElement AccountsCategory(SettingsPage page)
    {
        var info = SettingsFeature.Gateway();
        return Kit.Page(
            Kit.Section(null, null,
                Kit.Nav(GDesktop, "Gateway", info.Name, () => page.OpenGateway(), "settings.accounts.gateway"),
                Kit.Nav(GKey, "Passwords", null, () => Go(page, "vault"), "settings.vault"),
                Kit.Nav(GBolt, "Providers", null, () => Go(page, "providers"), "settings.providers"),
                Kit.Nav(GKey, "Keys", null, () => Go(page, "keys"), "settings.keys"),
                Kit.Nav(GCard, "Billing", null, () => Go(page, "billing"), "settings.billing")));
    }

    private static FrameworkElement VaultPane(SettingsPage page)
    {
        var openGateway = Kit.Push("Open Gateway Settings", () => page.OpenGateway());
        var wrap = new StackPanel { Padding = new Thickness(14, 10, 14, 10) };
        wrap.Children.Add(openGateway);
        return Kit.Page(
            Kit.Section("Passwords",
                $"Sign-in credentials on this PC are protected in {DeviceWord.Keychain}. Gateway vault entries live on {HostWord.Phrase}.",
                Kit.Value("Saved Sign-In", DeviceWord.Keychain),
                wrap));
    }

    // ---------------------------------------------------------------- Bots & Tools (SettingsRootView.swift `e27566897`)

    private static FrameworkElement ToolsCategory(SettingsPage page)
    {
        var host = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var checking = false;
        string? checkStatus = null;
        var checkStatusIsIssue = false;
        var disposed = false;

        void Dispatch(Action work)
        {
            if (disposed) return;
            if (host.DispatcherQueue is { } q) q.TryEnqueue(() => { if (!disposed) work(); });
            else work();
        }

        async Task CheckNowAsync()
        {
            if (checking || AppState.Client is not { } client) return;
            checking = true;
            checkStatus = null;
            checkStatusIsIssue = false;
            Dispatch(Draw);
            try
            {
                PluginUpdateReminder.Use(client.AccountId);
                var profiles = (client.Bots ?? []).Where(b => !b.Hidden).Select(b => b.Name).ToList();
                if (profiles.Count == 0) profiles.Add("default");
                await PluginUpdateReminder.CheckNowAsync(client, profiles, CancellationToken.None);
                checkStatus = PluginUpdateReminder.AvailableCount > 0
                    ? (PluginUpdateReminder.Footer ?? PluginUpdateReminder.BadgeLabel)
                    : "All plugins are up to date.";
            }
            catch (Exception ex)
            {
                checkStatus = SettingsErrorText.Load(ex);
                checkStatusIsIssue = true;
            }
            finally
            {
                checking = false;
                Dispatch(Draw);
            }
        }

        void Draw()
        {
            if (disposed) return;
            UiTree.DeactivateProgressRings(host);
            var client = AppState.Client;
            if (client != null) PluginUpdateReminder.Use(client.AccountId);

            var tileModelValue = client != null
                ? TileModels.DefaultValue(TileModelPane.SettingsFor(client.AccountId).DefaultModel)
                : null;

            var checkAuto = Kit.Toggle(GUpdate, "Check Automatically", null, PluginUpdateReminder.IsAutomatic,
                on =>
                {
                    PluginUpdateReminder.IsAutomatic = on;
                    AppLog.Note("settings", $"automatic plugin update checks {(on ? "on" : "off")}");
                },
                "row:plugin-update-checks", enabled: client != null);
            foreach (var t in checkAuto.Children.OfType<ToggleSwitch>())
                AutomationProperties.SetAutomationId(t, "settings.plugin-update-checks");

            var checkTrailing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            if (checking)
                checkTrailing.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
            else if (PluginUpdateReminder.BadgeLabel is { } badgeLabel)
                checkTrailing.Children.Add(ReminderBadge(badgeLabel));
            var checkNow = Kit.Push(checking ? "Checking…" : "Check for Plugin Updates", () => _ = CheckNowAsync());
            checkNow.IsEnabled = client != null && !checking;
            AutomationProperties.SetAutomationId(checkNow, "settings.check-plugin-updates");
            checkTrailing.Children.Add(checkNow);

            UIElement? statusRow = null;
            if (!string.IsNullOrEmpty(checkStatus))
            {
                statusRow = new TextBlock
                {
                    Text = checkStatus,
                    FontSize = 12,
                    TextWrapping = TextWrapping.Wrap,
                    Margin = new Thickness(14, 8, 14, 10),
                    Foreground = Kit.B(checkStatusIsIssue ? "SystemFillColorCriticalBrush" : "TextFillColorSecondaryBrush"),
                };
            }

            host.Content = Kit.Page(
                Kit.Section("Capabilities & Channels", null,
                    Kit.Nav(GWrench, "Capabilities", PluginUpdateReminder.BadgeLabel, () => Navigator.Open("capabilities"), "settings.capabilities"),
                    Kit.Nav(GSparkle, "Tile Model", tileModelValue, () => Go(page, "tile-model"), "settings.tile-model"),
                    Kit.Nav(GPeople, "Bot Profiles", null, () => Navigator.Open("profiles"), "settings.more.profiles"),
                    Kit.Nav(GBubbles, "Messaging", null, () => Navigator.Open("messaging"), "settings.more.messaging"),
                    Kit.Nav(GHook, "Webhooks", null, () => Navigator.Open("webhooks"), "settings.more.webhooks"),
                    Kit.Nav(GImport, "Import Sessions", null, () => Navigator.Open("import-sessions"), "settings.more.import-sessions")),
                Kit.Section(SettingsWords.PluginUpdatesHeader, PluginUpdateReminder.AutoCheckFooter,
                    checkAuto,
                    Kit.Row(GUpdate, "Check for Plugin Updates", null, checkTrailing, "row:check-plugin-updates"),
                    statusRow));
        }

        void OnReminderChanged() => Dispatch(Draw);
        void OnTileModelChanged(string _) => Dispatch(Draw);
        PluginUpdateReminder.Changed += OnReminderChanged;
        TileModelSync.Shared.Changed += OnTileModelChanged;
        host.Unloaded += (_, _) =>
        {
            disposed = true;
            PluginUpdateReminder.Changed -= OnReminderChanged;
            TileModelSync.Shared.Changed -= OnTileModelChanged;
            UiTree.DeactivateProgressRings(host);
        };

        Draw();
        return host;
    }

    // ---------------------------------------------------------------- Notifications

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

    // ---------------------------------------------------------------- About + Community Invite (`dcf89ffb1`)

    private static FrameworkElement AboutCategory(SettingsPage page)
    {
        page.FileActions = null;
        var host = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };

        void Draw()
        {
            host.Content = Kit.Page(
                !CommunityInvite.IsDismissed(Prefs) ? DiscordInviteBanner(Draw) : null,
                Kit.Section(null, null,
                    Kit.Nav(GInfo, "About", SettingsFeature.AppVersion, () => Go(page, "about"), "settings.about")),
                Kit.Section("Community & Links", null,
                    LinkRow(CommunityInvite.DiscordLabel, CommunityInvite.DiscordUrl, "row:discord"),
                    LinkRow(CommunityInvite.WebsiteLabel, CommunityInvite.WebsiteUrl),
                    LinkRow(CommunityInvite.GitHubLabel, CommunityInvite.GitHubUrl),
                    LinkRow("Support", SettingsWords.SupportUrl, "row:support"),
                    LinkRow("Privacy Policy", SettingsWords.PrivacyUrl)));
        }

        Draw();
        return host;
    }

    /// Dismissible "Join the Hermes HQ Discord" card (App/Pages/More/CommunityInvite.swift `DiscordInviteCard`).
    private static FrameworkElement DiscordInviteBanner(Action redraw)
    {
        var blurple = new SolidColorBrush(ThemeService.ToColor(CommunityInvite.Blurple));
        var white = new SolidColorBrush(Microsoft.UI.Colors.White);

        var mark = new Border
        {
            Width = 40, Height = 40,
            CornerRadius = new CornerRadius(10),
            Background = blurple,
            VerticalAlignment = VerticalAlignment.Top,
            Child = new FontIcon { Glyph = GBubbles, FontSize = 18, Foreground = white },
        };
        AutomationProperties.SetAccessibilityView(mark, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);

        var copy = new StackPanel { Spacing = 4 };
        copy.Children.Add(new TextBlock { Text = CommunityInvite.BannerTitle, FontSize = 15, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
        copy.Children.Add(new TextBlock
        {
            Text = CommunityInvite.BannerBody,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            Foreground = Kit.B("TextFillColorSecondaryBrush"),
        });

        var closeBtn = new Button
        {
            Content = new FontIcon { Glyph = "\uE711", FontSize = 11 },
            Width = 28, Height = 28,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(14),
            VerticalAlignment = VerticalAlignment.Top,
            Background = Kit.B("HQSettingsFieldBrush"),
            BorderThickness = new Thickness(0),
        };
        AutomationProperties.SetName(closeBtn, CommunityInvite.BannerCloseLabel);
        AutomationProperties.SetHelpText(closeBtn, CommunityInvite.BannerCloseHint);
        AutomationProperties.SetAutomationId(closeBtn, "more.discord.close");
        closeBtn.Click += (_, _) => { CommunityInvite.Dismiss(Prefs); redraw(); };

        var header = new Grid { ColumnSpacing = 12 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(mark);
        Grid.SetColumn(copy, 1); header.Children.Add(copy);
        Grid.SetColumn(closeBtn, 2); header.Children.Add(closeBtn);

        var joinBtn = new Button
        {
            Content = CommunityInvite.BannerJoinLabel,
            Background = blurple,
            Foreground = white,
            FontWeight = FontWeights.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            CornerRadius = new CornerRadius(ThemeService.State.ShapeRadius(ShapeRole.Capsule, 18)),
            Padding = new Thickness(14, 7, 14, 7),
        };
        AutomationProperties.SetHelpText(joinBtn, CommunityInvite.BannerJoinHint);
        AutomationProperties.SetAutomationId(joinBtn, "more.discord.join");
        joinBtn.Click += async (_, _) =>
        {
            AppLog.Note("screen", "discord invite: about card join");
            await Windows.System.Launcher.LaunchUriAsync(new Uri(CommunityInvite.DiscordUrl));
        };

        var cardStack = new StackPanel { Spacing = 12, Padding = new Thickness(14, 14, 14, 14) };
        cardStack.Children.Add(header);
        cardStack.Children.Add(joinBtn);
        return Kit.Card(cardStack);
    }

    /// Export Settings…, Import Settings…, Clear Model Favorites… and Reset to Defaults… under Hermes › Backup & Reset
    /// (SettingsRootView.swift `e27566897`).
    private static FrameworkElement FileActionsSection(SettingsPage page, GatewayConfigStore store, Hermes.Core.Composer.ModelPrefs? models)
    {
        SettingsFileActions.Log ??= line => AppLog.Note("settings", line);
        var section = new StackPanel { Spacing = 6 };
        section.Children.Add(new TextBlock
        {
            Text = "Backup & Reset", FontSize = 13, FontWeight = FontWeights.SemiBold, Margin = new Thickness(14, 0, 0, 0),
            Foreground = Kit.B("TextFillColorSecondaryBrush"),
        });
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
        page.FileActions = (actions, section);

        var export = Kit.Push(SettingsFileWords.Export, () => _ = actions.ExportAsync());
        AutomationProperties.SetAutomationId(export, "settings.export");
        var import = Kit.Push(SettingsFileWords.Import, () => _ = actions.PickImportAsync());
        AutomationProperties.SetAutomationId(import, "settings.import");
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
                    LinkRow(CommunityInvite.DiscordLabel, CommunityInvite.DiscordUrl),
                    LinkRow(CommunityInvite.WebsiteLabel, CommunityInvite.WebsiteUrl),
                    LinkRow(CommunityInvite.GitHubLabel, CommunityInvite.GitHubUrl),
                    LinkRow("Support", SettingsWords.SupportUrl),
                    LinkRow("Privacy Policy", SettingsWords.PrivacyUrl),
                    Kit.Nav(null, LicenseNotices.PageTitle, null, () => Go(page, "licenses"), "about.licenses")),
                Kit.Section("Troubleshooting", null,
                    Kit.Nav(null, "Diagnostics", null, () => Go(page, "diagnostics"), "about.diagnostics"),
                    Kit.Toggle(null, PerformanceLogPrefs.Title, null, perfOn,
                        on => { PerformanceLogPrefs.SetEnabled(Prefs, on, AppLog.Note); Draw(); }, "about.perf-log"),
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
        if (notice.Meta.Length > 0 && row.Content is Grid grid
            && grid.Children.OfType<StackPanel>().FirstOrDefault(p => p.Children.OfType<TextBlock>().Any(t => t.Text == notice.Name)) is { } words)
        {
            words.Children.Add(new TextBlock { Text = notice.Meta, FontSize = 12, TextWrapping = TextWrapping.Wrap, Foreground = Kit.B("TextFillColorSecondaryBrush") });
            AutomationProperties.SetName(row, $"{notice.Name}, {notice.Meta}");
        }
        return row;
    }

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

    private static Button LinkRow(string title, string url, string? id = null)
    {
        var row = Kit.Row(null, title, null, new FontIcon { Glyph = GLink, FontSize = 12, Foreground = Kit.B("TextFillColorTertiaryBrush") }, id);
        var b = new Button
        {
            Content = row, Padding = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0), CornerRadius = new CornerRadius(0), Tag = id,
        };
        AutomationProperties.SetName(b, title);
        AutomationProperties.SetHelpText(b, $"Opens {new Uri(url).Host} in your browser.");
        if (id != null) AutomationProperties.SetAutomationId(b, id);
        b.Click += async (_, _) => await Windows.System.Launcher.LaunchUriAsync(new Uri(url));
        return b;
    }

    // ---------------------------------------------------------------- the gateway card's page

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
