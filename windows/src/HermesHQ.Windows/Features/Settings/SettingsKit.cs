using Hermes.Core.Settings;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Settings;

/// The Settings window's form, as the Mac draws it (App/Mac/MacForm, SettingsRowLabel, NavRow, HQSectionLabel,
/// HQSectionFooter): a readable column of cards, each a run of rows with a symbol, a title (and its note under it), and
/// the control at the trailing edge; a quiet label over a card and a small note under it. Row ids ("row:…") let a search
/// result scroll to its row and mark it.
internal static class Kit
{
    /// Maximum width for trailing dropdown pickers and model chooser buttons so long model names truncate cleanly
    /// inside their card instead of overflowing (App/Settings/Config/MacForm.swift, #616).
    public const double DefaultPickerMaxWidth = 240;
    public const double DefaultChooserMaxWidth = 260;

    public static Brush B(string key) => ThemeService.BrushFor(key);

    /// Room between cards. SettingsPage owns the horizontal insets once, outside nested and asynchronously built forms.
    public static FrameworkElement Page(params UIElement?[] sections)
    {
        var stack = new StackPanel { Spacing = 22, Padding = new Thickness(0, 8, 0, 32) };
        foreach (var s in sections) if (s != null) stack.Children.Add(s);
        return stack;
    }

    /// A card with its label over it and its note under it.
    public static StackPanel Section(string? header, string? footer, params UIElement?[] rows)
    {
        var section = new StackPanel { Spacing = 6 };
        if (header != null)
            section.Children.Add(new TextBlock
            {
                Text = header, FontSize = 13, FontWeight = FontWeights.SemiBold, Margin = new Thickness(14, 0, 0, 0),
                Foreground = B("TextFillColorSecondaryBrush"),
            });
        section.Children.Add(Card(rows));
        if (footer != null) section.Children.Add(Footer(footer));
        return section;
    }

    public static TextBlock Footer(string text) => new()
    {
        Text = text, FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(14, 0, 14, 0),
        Foreground = B("TextFillColorSecondaryBrush"), IsTextSelectionEnabled = false,
    };

    /// Rows in one card, a hairline between each. Follows `ThemeState.ShapeRadius(ShapeRole.Card, 10)` so Hermes Look
    /// Corners morph every settings card live.
    public static Border Card(params UIElement?[] rows)
    {
        var stack = new StackPanel();
        var first = true;
        foreach (var row in rows)
        {
            if (row == null) continue;
            if (!first)
                stack.Children.Add(new Border { Height = 1, Margin = new Thickness(48, 0, 0, 0), Background = B("DividerStrokeColorDefaultBrush") });
            stack.Children.Add(row);
            first = false;
        }
        return new Border
        {
            Child = stack,
            CornerRadius = new CornerRadius(ThemeService.State.ShapeRadius(ShapeRole.Card, 10)),
            BorderThickness = new Thickness(1),
            Background = B("CardBackgroundFillColorDefaultBrush"),
            BorderBrush = B("CardStrokeColorDefaultBrush"),
        };
    }

    /// A row: its symbol, its title with an optional note under it, and what goes at its end.
    public static Grid Row(string? glyph, string title, string? note = null, UIElement? trailing = null, string? id = null)
    {
        var grid = new Grid { Padding = new Thickness(14, 10, 14, 10), ColumnSpacing = 12, MinHeight = 44, Tag = id };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(22) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (glyph != null)
            grid.Children.Add(new FontIcon { Glyph = glyph, FontSize = 16, VerticalAlignment = VerticalAlignment.Center, Foreground = B("TextFillColorPrimaryBrush") });
        var words = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(new TextBlock { Text = title, TextWrapping = TextWrapping.Wrap, Foreground = B("TextFillColorPrimaryBrush") });
        if (note != null)
            words.Children.Add(new TextBlock { Text = note, FontSize = 12, TextWrapping = TextWrapping.Wrap, Foreground = B("TextFillColorSecondaryBrush") });
        Grid.SetColumn(words, glyph == null ? 0 : 1);
        if (glyph == null) Grid.SetColumnSpan(words, 2);
        grid.Children.Add(words);
        if (trailing is FrameworkElement t)
        {
            t.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(t, 2);
            grid.Children.Add(t);
        }
        return grid;
    }

    /// A switch row (the Mac's Toggle with its SettingsRowLabel).
    public static Grid Toggle(string? glyph, string title, string? note, bool on, Action<bool> set, string? id = null, bool enabled = true)
    {
        var toggle = new ToggleSwitch { IsOn = on, OnContent = "", OffContent = "", MinWidth = 0, IsEnabled = enabled };
        AutomationProperties.SetName(toggle, title);
        if (id != null) AutomationProperties.SetAutomationId(toggle, id);
        toggle.Toggled += (_, _) => set(toggle.IsOn);
        return Row(glyph, title, note, toggle, id);
    }

    /// A pop-up row (the Mac's MacPopUp at the row's end), width-capped so long labels truncate cleanly inside their
    /// card instead of overflowing (`#616`).
    public static Grid Picker<T>(string? glyph, string title, string? note, IReadOnlyList<(string Title, T Value)> options, T selected,
        Action<T> set, string? id = null, double maxWidth = DefaultPickerMaxWidth, bool enabled = true)
    {
        var box = new ComboBox
        {
            MinWidth = 140,
            MaxWidth = maxWidth,
            HorizontalAlignment = HorizontalAlignment.Right,
            IsEnabled = enabled,
            CornerRadius = new CornerRadius(ThemeService.State.ShapeRadius(ShapeRole.Control, 6)),
        };
        foreach (var (t, _) in options) box.Items.Add(t);
        var idx = Math.Max(0, options.ToList().FindIndex(o => EqualityComparer<T>.Default.Equals(o.Value, selected)));
        if (options.Count > 0)
        {
            box.SelectedIndex = idx;
            ToolTipService.SetToolTip(box, options[idx].Title);
        }
        AutomationProperties.SetName(box, title);
        if (id != null) AutomationProperties.SetAutomationId(box, id);
        box.SelectionChanged += (_, _) =>
        {
            if (box.SelectedIndex >= 0 && box.SelectedIndex < options.Count)
            {
                ToolTipService.SetToolTip(box, options[box.SelectedIndex].Title);
                set(options[box.SelectedIndex].Value);
            }
        };
        return Row(glyph, title, note, box, id);
    }

    /// A trailing chooser button drawn as a bordered pop-up face (MacForm.swift `MacChooserButton` / `MacPopUpFace`, #616):
    /// single-line ellipsis truncation inside `maxWidth` so long model names never overflow their card.
    public static Grid ChooserButton(string? glyph, string title, string? note, string value, Action click,
        string? id = null, bool enabled = true, double maxWidth = DefaultChooserMaxWidth)
    {
        var face = new Grid { ColumnSpacing = 8 };
        face.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        face.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var label = new TextBlock
        {
            Text = value,
            MaxLines = 1,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = B(enabled ? "TextFillColorPrimaryBrush" : "TextFillColorSecondaryBrush"),
        };
        var chevrons = new FontIcon
        {
            Glyph = "\uE70D",
            FontSize = 10,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = B("TextFillColorSecondaryBrush"),
        };
        face.Children.Add(label);
        Grid.SetColumn(chevrons, 1);
        face.Children.Add(chevrons);

        var button = new Button
        {
            Content = face,
            MinWidth = 120,
            MaxWidth = maxWidth,
            IsEnabled = enabled,
            Padding = new Thickness(12, 5, 10, 5),
            HorizontalAlignment = HorizontalAlignment.Right,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            CornerRadius = new CornerRadius(ThemeService.State.ShapeRadius(ShapeRole.Control, 6)),
        };
        AutomationProperties.SetName(button, $"{title}, {value}");
        if (id != null) AutomationProperties.SetAutomationId(button, id);
        ToolTipService.SetToolTip(button, value);
        button.Click += (_, _) => click();
        return Row(glyph, title, note, button, id);
    }

    /// A row that opens a page: its value, then a chevron.
    public static Button Nav(string? glyph, string title, string? value, Action open, string? id = null)
    {
        var trailing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        if (value != null)
            trailing.Children.Add(new TextBlock
            {
                Text = value,
                MaxWidth = DefaultPickerMaxWidth,
                MaxLines = 1,
                TextTrimming = TextTrimming.CharacterEllipsis,
                Foreground = B("TextFillColorSecondaryBrush"),
                VerticalAlignment = VerticalAlignment.Center,
            });
        trailing.Children.Add(new FontIcon { Glyph = "", FontSize = 11, Foreground = B("TextFillColorTertiaryBrush"), VerticalAlignment = VerticalAlignment.Center });
        var row = Row(glyph, title, null, trailing, id);
        var button = new Button
        {
            Content = row, Padding = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0), CornerRadius = new CornerRadius(0), Tag = id,
        };
        AutomationProperties.SetName(button, value == null ? title : $"{title}, {value}");
        if (id != null) AutomationProperties.SetAutomationId(button, id);
        button.Click += (_, _) => open();
        return button;
    }

    /// A push button the Mac draws at a row's end or under a paragraph.
    public static Button Push(string title, Action click, bool destructive = false)
    {
        var b = new Button
        {
            Content = title,
            CornerRadius = new CornerRadius(ThemeService.State.ShapeRadius(ShapeRole.Control, 6)),
        };
        if (destructive) b.Foreground = B("SystemFillColorCriticalBrush");
        b.Click += (_, _) => click();
        return b;
    }

    /// A label and its value on one line (About's Version).
    public static Grid Value(string title, string value, string? id = null)
    {
        var text = new TextBlock { Text = value, Foreground = B("TextFillColorSecondaryBrush"), IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap };
        if (id != null) AutomationProperties.SetAutomationId(text, id);
        return Row(null, title, null, text);
    }

    /// Marks a row for a moment (a search result's landing, the Mac's `revealRow`).
    public static async void Flash(FrameworkElement row)
    {
        row.StartBringIntoView(new BringIntoViewOptions { VerticalAlignmentRatio = 0.4, AnimationDesired = true });
        if (row is not Panel and not Control) return;
        var before = row is Panel p ? p.Background : ((Control)row).Background;
        void Paint(Brush? b) { if (row is Panel pp) pp.Background = b; else ((Control)row).Background = b; }
        Paint(B("HQChosenRowBrush"));
        await Task.Delay(1400);
        Paint(before);
    }

    /// The row inside `root` whose Tag is `id`.
    public static FrameworkElement? Find(DependencyObject root, string id)
    {
        if (root is FrameworkElement f && Equals(f.Tag, id)) return f;
        var count = VisualTreeHelper.GetChildrenCount(root);
        for (var i = 0; i < count; i++)
            if (Find(VisualTreeHelper.GetChild(root, i), id) is { } hit) return hit;
        return null;
    }
}
