using Hermes.Core.Settings;
using HermesHQ.Features.Transcript;
using HermesHQ.Services;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.Windows.Storage.Pickers;
using Windows.Foundation;
using Windows.UI;

namespace HermesHQ.Features.Settings;

/// Renders a configured App or Chat background (Studio Matte solid, Theme Tint, Custom OKLab-adapted color,
/// Classic / Photo / Illustrated / Painted / Doodles gradient preset, or local photo) into a WinUI Brush.
public static class BackdropPainter
{
    public static BackdropPrefs Prefs { get; } = new(FilePreferences.Shared);

    public static string PhotoFolder(BackdropPlace place) =>
        Path.Combine(AppPaths.Root, place == BackdropPlace.App ? "app-background" : "chat-background");

    /// Returns null when Hermes Look is active, High Contrast is active, or no background is chosen.
    public static Brush? CreateBrush(BackdropPlace place)
    {
        if (ThemeService.State.DesktopLook || ThemeService.SystemHighContrast) return null;
        var appState = Prefs.Load(BackdropPlace.App);
        var state = place == BackdropPlace.App ? appState : Prefs.Load(BackdropPlace.Chats);
        var source = state.EffectiveSource(appState);
        if (source == null) return null;
        var tokens = ThemeService.Tokens;
        var dark = ThemeService.Dark;
        var wash = Math.Clamp(state.Dim / 100.0, 0, 0.8);

        if (source is BackdropSource.Photo photo)
        {
            var folder = place == BackdropPlace.Chats && state.SameAsApp ? PhotoFolder(BackdropPlace.App) : PhotoFolder(place);
            var full = Path.Combine(folder, photo.FileName);
            if (!File.Exists(full)) return null;
            return new ImageBrush { ImageSource = new BitmapImage(new Uri(full)), Stretch = Stretch.UniformToFill, Opacity = 1.0 - wash * 0.5 };
        }

        if (source.IsSolid)
        {
            var baseColor = BackdropCatalog.ResolveSolidBase(source, dark, tokens.Tint);
            var (top, mid, bottom) = BackdropCatalog.StudioMatteStops(baseColor, dark);
            top = BlendVeil(top, tokens.Page, wash);
            mid = BlendVeil(mid, tokens.Page, wash);
            bottom = BlendVeil(bottom, tokens.Page, wash);
            var brush = new LinearGradientBrush { StartPoint = new Point(0.5, 0), EndPoint = new Point(0.5, 1) };
            brush.GradientStops.Add(new GradientStop { Offset = 0.0, Color = ThemeService.ToColor(top) });
            brush.GradientStops.Add(new GradientStop { Offset = 0.45, Color = ThemeService.ToColor(mid) });
            brush.GradientStops.Add(new GradientStop { Offset = 1.0, Color = ThemeService.ToColor(bottom) });
            return brush;
        }

        if (source is BackdropSource.Preset preset && BackdropCatalog.Find(preset.Id) is { } info)
        {
            var c1 = preset.Id == "glow"
                ? OkLabSolidAdapt.Adapt(tokens.Tint, dark, isTint: true)
                : Rgba.Hex(dark ? info.DarkHex : info.LightHex);
            var c2 = info.LightAccent != 0
                ? Rgba.Hex(dark ? info.DarkAccent : info.LightAccent)
                : c1;
            c1 = BlendVeil(c1, tokens.Page, wash);
            c2 = BlendVeil(c2, tokens.Page, wash);
            var brush = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(1, 1) };
            brush.GradientStops.Add(new GradientStop { Offset = 0.0, Color = ThemeService.ToColor(c1) });
            brush.GradientStops.Add(new GradientStop { Offset = 1.0, Color = ThemeService.ToColor(c2) });
            return brush;
        }
        return null;
    }

    private static Rgba BlendVeil(Rgba color, Rgba page, double wash) =>
        wash <= 0 ? color : page.Alpha(wash).Over(color);
}

/// Settings › Appearance › Backgrounds (App/Settings/Theme/BackgroundSettingsView.swift):
/// Wash slider, Blur toggle, 4-way Cards picker (Off | Tinted | Glass | Solid), category filter chips
/// (Classic, Solids, Photo, Illustrated, Painted, Doodles), and WinUI 3 ColorPicker for custom Studio Matte colors.
internal static class BackgroundsPane
{
    public static FrameworkElement Make()
    {
        var host = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var place = BackdropPlace.Chats;
        var selectedGroup = InitialGroup(BackdropPainter.Prefs.Load(place));

        void Draw()
        {
            var prefs = BackdropPainter.Prefs;
            var appState = prefs.Load(BackdropPlace.App);
            var state = place == BackdropPlace.App ? appState : prefs.Load(BackdropPlace.Chats);
            var effective = state.EffectiveSource(appState);
            var isSolid = state.EffectiveIsSolid(appState);
            var followsApp = place == BackdropPlace.Chats && state.SameAsApp && appState.Source != null;

            var placeSwitch = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 0 };
            foreach (var (label, targetPlace, idx) in new[] { ("Chats", BackdropPlace.Chats, 0), ("App", BackdropPlace.App, 1) })
            {
                var btn = new ToggleButton
                {
                    Content = label, IsChecked = place == targetPlace, Padding = new Thickness(16, 6, 16, 6),
                    CornerRadius = new CornerRadius(idx == 0 ? 6 : 0, idx == 1 ? 6 : 0, idx == 1 ? 6 : 0, idx == 0 ? 6 : 0),
                };
                AutomationProperties.SetAutomationId(btn, $"backgrounds.place.{label.ToLowerInvariant()}");
                btn.Click += (_, _) =>
                {
                    place = targetPlace;
                    selectedGroup = InitialGroup(prefs.Load(place));
                    Draw();
                };
                placeSwitch.Children.Add(btn);
            }

            var sections = new List<UIElement?>();
            sections.Add(placeSwitch);

            if (place == BackdropPlace.Chats)
            {
                sections.Add(Kit.Section(null, BackdropPrefs.SameAsAppNote,
                    Kit.Toggle(null, "Use App Background", null, state.SameAsApp, on => { prefs.SetSameAsApp(on); Draw(); }, "backgrounds.same-as-app")));
            }

            // Wash, Blur & 4-way Cards controls (Blur hidden when a solid wallpaper is active)
            if (effective != null)
            {
                var washSlider = new Slider
                {
                    Minimum = BackdropState.MinDim, Maximum = BackdropState.MaxDim, Value = state.Dim,
                    StepFrequency = 5, Width = 180, IsThumbToolTipEnabled = false,
                };
                AutomationProperties.SetName(washSlider, BackdropPrefs.WashLabel);
                var washLabel = new TextBlock { Text = $"{state.Dim}%", Foreground = Kit.B("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center };
                washSlider.ValueChanged += (_, e) =>
                {
                    var pct = (int)Math.Round(e.NewValue);
                    washLabel.Text = $"{pct}%";
                    prefs.SetDim(place, pct);
                };
                var washTrailing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                washTrailing.Children.Add(washSlider);
                washTrailing.Children.Add(washLabel);
                UIElement? blurRow = isSolid ? null : Kit.Toggle(null, "Blur", null, state.Blur, on => { prefs.SetBlur(place, on); Draw(); }, "backgrounds.blur");
                UIElement? cardsRow = place == BackdropPlace.App
                    ? BuildCardsPickerRow(prefs, state.CardStyle, Draw)
                    : null;
                var footer = isSolid
                    ? "Studio Matte solids stay crisp without blur."
                    : place == BackdropPlace.App ? BackdropPrefs.AppNote : BackdropPrefs.ChatNote;
                sections.Add(Kit.Section("Adjustments", footer,
                    Kit.Row(null, BackdropPrefs.WashLabel, null, washTrailing, "backgrounds.dim"), blurRow, cardsRow));
            }

            if (!followsApp)
            {
                // Actions row: None + Your Photo
                var actionStrip = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Padding = new Thickness(14, 10, 14, 10) };
                var noneBtn = new Button { Content = "None" };
                AutomationProperties.SetAutomationId(noneBtn, "backgrounds.none");
                noneBtn.Click += (_, _) => { prefs.Clear(place); Draw(); };
                var photoBtn = new Button { Content = "Choose Photo…" };
                AutomationProperties.SetAutomationId(photoBtn, "backgrounds.photo");
                photoBtn.Click += async (_, _) =>
                {
                    if (await PickPhotoAsync(place) is { } name) { prefs.SetPhoto(place, name); Draw(); }
                };
                actionStrip.Children.Add(noneBtn);
                actionStrip.Children.Add(photoBtn);
                sections.Add(Kit.Section(null, $"Current: {state.Summary(appState)}", actionStrip));

                // Category filter chips: Classic | Solids | Photo | Illustrated | Painted | Doodles
                sections.Add(BuildCategoryChips(selectedGroup, g => { selectedGroup = g; Draw(); }));

                // Active category grid
                var grid = selectedGroup == BackdropGroup.Solids
                    ? BuildSolidsGrid(prefs, place, state, Draw)
                    : BuildPresetGrid(prefs, place, state, BackdropCatalog.ByGroup(selectedGroup), Draw);
                sections.Add(TileSection(selectedGroup.Title(), grid));
            }

            if (ThemeService.State.DesktopLook)
                sections.Add(Kit.Footer(BackdropPrefs.DesktopNote));

            var page = Kit.Page([.. sections]);
            AutomationProperties.SetAutomationId(page, "settings.backgrounds");
            host.Content = page;
        }

        Draw();
        return host;
    }

    private static BackdropGroup InitialGroup(BackdropState state) => state.Source switch
    {
        BackdropSource.CustomColor => BackdropGroup.Solids,
        BackdropSource.Preset p => BackdropCatalog.Find(p.Id)?.Group ?? BackdropGroup.Classic,
        _ => BackdropGroup.Classic,
    };

    private static FrameworkElement BuildCategoryChips(BackdropGroup active, Action<BackdropGroup> select)
    {
        var strip = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Padding = new Thickness(2, 2, 2, 2) };
        foreach (var group in BackdropGroups.All)
        {
            var isSelected = group == active;
            var chip = new ToggleButton
            {
                Content = group.ShortTitle(),
                IsChecked = isSelected,
                Padding = new Thickness(12, 5, 12, 5),
                CornerRadius = new CornerRadius(14),
                MinWidth = 0,
            };
            AutomationProperties.SetName(chip, group.Title());
            AutomationProperties.SetAutomationId(chip, $"backgrounds.category.{group.ToString().ToLowerInvariant()}");
            var target = group;
            chip.Click += (_, _) =>
            {
                if (target != active) select(target);
                else chip.IsChecked = true;
            };
            strip.Children.Add(chip);
        }
        return new ScrollViewer
        {
            Content = strip,
            HorizontalScrollMode = ScrollMode.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
            VerticalScrollMode = ScrollMode.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
    }

    /// Unified 4-way Cards picker (Off | Tinted | Glass | Solid) on App Background (BackgroundSettingsView.swift:340-375).
    private static FrameworkElement BuildCardsPickerRow(BackdropPrefs prefs, CardStyle current, Action redraw)
    {
        var strip = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 0 };
        AutomationProperties.SetName(strip, CardStyles.Label);
        AutomationProperties.SetAutomationId(strip, "backgrounds.cards");
        var options = CardStyles.All;
        for (var i = 0; i < options.Length; i++)
        {
            var style = options[i];
            var btn = new ToggleButton
            {
                Content = style.Title(),
                IsChecked = style == current,
                Padding = new Thickness(10, 4, 10, 4),
                MinWidth = 0,
                CornerRadius = new CornerRadius(i == 0 ? 4 : 0, i == options.Length - 1 ? 4 : 0, i == options.Length - 1 ? 4 : 0, i == 0 ? 4 : 0),
            };
            AutomationProperties.SetName(btn, style.Title());
            AutomationProperties.SetAutomationId(btn, $"backgrounds.cards.{style.Raw()}");
            btn.Click += (_, _) =>
            {
                if (style != current) { prefs.SetCardStyle(style); redraw(); }
                else btn.IsChecked = true;
            };
            strip.Children.Add(btn);
        }
        return Kit.Row(null, CardStyles.Label, current.Caption(), strip, "backgrounds.cards");
    }

    private static StackPanel TileSection(string title, FrameworkElement grid)
    {
        var section = new StackPanel { Spacing = 8 };
        section.Children.Add(new TextBlock
        {
            Text = title, FontSize = 13, FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(14, 0, 0, 0), Foreground = Kit.B("TextFillColorSecondaryBrush"),
        });
        section.Children.Add(grid);
        return section;
    }

    private static Grid BuildSolidsGrid(BackdropPrefs prefs, BackdropPlace place, BackdropState state, Action redraw)
    {
        var grid = new Grid { ColumnSpacing = 8, RowSpacing = 8 };
        const int cols = 4;
        for (var c = 0; c < cols; c++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var dark = ThemeService.Dark;
        var tint = ThemeService.Tokens.Tint;
        var total = BackdropCatalog.Solids.Count + 1; // + Custom tile
        for (var i = 0; i < total; i++)
        {
            if (i % cols == 0) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            FrameworkElement tile;
            if (i < BackdropCatalog.Solids.Count)
            {
                var preset = BackdropCatalog.Solids[i];
                var active = !state.SameAsApp && state.Source is BackdropSource.Preset p && p.Id == preset.Id;
                var color = BackdropCatalog.ResolveSolidBase(new BackdropSource.Preset(preset.Id), dark, tint);
                var (top, mid, bottom) = BackdropCatalog.StudioMatteStops(color, dark);
                tile = SwatchTile(preset.Label, top, mid, bottom, active, $"backgrounds.preset.{preset.Id}", () => { prefs.SetPreset(place, preset.Id); redraw(); });
            }
            else
            {
                var custom = !state.SameAsApp && state.Source is BackdropSource.CustomColor;
                var hex = state.Source is BackdropSource.CustomColor c ? c.Hex : 0x4A84FEu;
                var color = OkLabSolidAdapt.Adapt(Rgba.Hex(hex), dark, isTint: false);
                var (top, mid, bottom) = BackdropCatalog.StudioMatteStops(color, dark);
                tile = SwatchTile("Custom", top, mid, bottom, custom, "backgrounds.custom-color", async () =>
                {
                    if (await PickCustomHexAsync(hex) is { } chosen) { prefs.SetCustomColor(place, chosen); redraw(); }
                });
            }
            Grid.SetRow(tile, i / cols);
            Grid.SetColumn(tile, i % cols);
            grid.Children.Add(tile);
        }
        return grid;
    }

    private static Grid BuildPresetGrid(BackdropPrefs prefs, BackdropPlace place, BackdropState state, IReadOnlyList<BackdropPresetInfo> presets, Action redraw)
    {
        var grid = new Grid { ColumnSpacing = 8, RowSpacing = 8 };
        const int cols = 4;
        for (var c = 0; c < cols; c++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var dark = ThemeService.Dark;
        var tint = ThemeService.Tokens.Tint;
        for (var i = 0; i < presets.Count; i++)
        {
            if (i % cols == 0) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var preset = presets[i];
            var active = !state.SameAsApp && state.Source is BackdropSource.Preset p && BackdropCatalog.ResolveId(p.Id) == preset.Id;
            var c1 = preset.Id == "glow" ? OkLabSolidAdapt.Adapt(tint, dark, isTint: true) : Rgba.Hex(dark ? preset.DarkHex : preset.LightHex);
            var c2 = preset.LightAccent != 0 ? Rgba.Hex(dark ? preset.DarkAccent : preset.LightAccent) : c1;
            var tile = SwatchTile(preset.Label, c1, c1.Mix(50, c2), c2, active, $"backgrounds.preset.{preset.Id}", () => { prefs.SetPreset(place, preset.Id); redraw(); });
            Grid.SetRow(tile, i / cols);
            Grid.SetColumn(tile, i % cols);
            grid.Children.Add(tile);
        }
        return grid;
    }

    private static Button SwatchTile(string label, Rgba top, Rgba mid, Rgba bottom, bool chosen, string id, Action onClick)
    {
        var fill = new LinearGradientBrush { StartPoint = new Point(0.5, 0), EndPoint = new Point(0.5, 1) };
        fill.GradientStops.Add(new GradientStop { Offset = 0, Color = ThemeService.ToColor(top) });
        fill.GradientStops.Add(new GradientStop { Offset = 0.45, Color = ThemeService.ToColor(mid) });
        fill.GradientStops.Add(new GradientStop { Offset = 1, Color = ThemeService.ToColor(bottom) });
        var preview = new Border { Height = 64, CornerRadius = new CornerRadius(6), Background = fill };
        var stack = new StackPanel { Spacing = 4 };
        stack.Children.Add(preview);
        stack.Children.Add(new TextBlock { Text = label, FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
        var btn = new Button
        {
            Content = stack, Padding = new Thickness(6), HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch, CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(chosen ? 2 : 1),
            BorderBrush = chosen ? Kit.B("AccentFillColorDefaultBrush") : Kit.B("CardStrokeColorDefaultBrush"),
            Background = Kit.B("CardBackgroundFillColorDefaultBrush"),
        };
        AutomationProperties.SetName(btn, label + (chosen ? ", chosen" : ""));
        AutomationProperties.SetAutomationId(btn, id);
        btn.Click += (_, _) => onClick();
        return btn;
    }

    /// Conservative WinUI 3 ColorPicker dialog for selecting a custom Studio Matte background color (`#RRGGBB`).
    private static async Task<uint?> PickCustomHexAsync(uint initial)
    {
        var root = SettingsPage.Current?.XamlRoot ?? App.Window?.Content?.XamlRoot;
        if (root == null) return null;
        var initialColor = Color.FromArgb(255, (byte)((initial >> 16) & 0xFF), (byte)((initial >> 8) & 0xFF), (byte)(initial & 0xFF));
        var picker = new ColorPicker
        {
            Color = initialColor,
            IsAlphaEnabled = false,
            IsAlphaSliderVisible = false,
            IsAlphaTextInputVisible = false,
            IsColorSpectrumVisible = true,
            IsColorSliderVisible = true,
            IsColorPreviewVisible = true,
            IsHexInputVisible = true,
            IsColorChannelTextInputVisible = false,
            IsMoreButtonVisible = false,
        };
        AutomationProperties.SetAutomationId(picker, "backgrounds.color-picker");
        var stack = new StackPanel { Spacing = 8 };
        stack.Children.Add(new TextBlock
        {
            Text = "Pick a color or enter a hex value (#RRGGBB). Hermes adapts it in OKLab for Light and Dark modes.",
            TextWrapping = TextWrapping.Wrap,
            Foreground = Kit.B("TextFillColorSecondaryBrush"),
        });
        stack.Children.Add(picker);
        var dialog = new ContentDialog
        {
            Title = "Custom Color",
            Content = new ScrollViewer { Content = stack, MaxHeight = 460 },
            PrimaryButtonText = "Apply",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = root,
        };
        if (await SafeDialog.ShowAsync(root, dialog) != ContentDialogResult.Primary) return null;
        var c = picker.Color;
        return ((uint)c.R << 16) | ((uint)c.G << 8) | c.B;
    }

    private static async Task<string?> PickPhotoAsync(BackdropPlace place)
    {
        var owner = (Window?)SettingsWindow.Showing ?? App.Window;
        if (owner == null) return null;
        var picker = new FileOpenPicker(owner.AppWindow.Id) { ViewMode = PickerViewMode.Thumbnail, SuggestedStartLocation = PickerLocationId.PicturesLibrary };
        foreach (var ext in Hermes.Core.Attachments.MediaKinds.ImageExtensions) picker.FileTypeFilter.Add("." + ext);
        try
        {
            var file = await picker.PickSingleFileAsync();
            if (file == null || string.IsNullOrEmpty(file.Path)) return null;
            var folder = BackdropPainter.PhotoFolder(place);
            Directory.CreateDirectory(folder);
            var ext = Path.GetExtension(file.Path);
            if (string.IsNullOrEmpty(ext)) ext = ".jpg";
            var name = Guid.NewGuid().ToString("N") + ext;
            File.Copy(file.Path, Path.Combine(folder, name), overwrite: true);
            return name;
        }
        catch (Exception e) { AppLog.Error("backdrop", e); return null; }
    }
}
