using Hermes.Core.Composer;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Composer;

/// The slash and @ drawers' list above the message box (App/Chat/ComposerDrawer.swift): section headings, rows with a
/// title and a quieter description, a mark on the row Enter picks (Up and Down move it), a star on command rows.
internal sealed class DrawerView
{
    private readonly StackPanel _list = new() { Spacing = 0 };
    private readonly ScrollViewer _scroll;
    private readonly List<(ComposerDrawer.Row Row, Button View)> _pickable = [];
    private int _marked = -1;

    public Border View { get; }
    public Action<ComposerDrawer.Row>? OnPick { get; set; }
    /// Starred commands, and the star's toggle (a right-click on a command row).
    public Func<string, bool>? IsFavorite { get; set; }
    public Action<string>? ToggleFavorite { get; set; }

    public DrawerView()
    {
        _scroll = new ScrollViewer { Content = _list, MaxHeight = 300, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        View = new Border
        {
            Child = _scroll,
            Padding = new Thickness(4),
            CornerRadius = new CornerRadius(12),
            Background = Ui.Res<Brush>("AcrylicInAppFillColorDefaultBrush"),
            BorderBrush = Ui.Res<Brush>("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1),
            Visibility = Visibility.Collapsed,
        };
    }

    public bool IsOpen => View.Visibility == Visibility.Visible;
    public ComposerDrawer.Row? Marked => _marked >= 0 && _marked < _pickable.Count ? _pickable[_marked].Row : null;

    public void Close()
    {
        View.Visibility = Visibility.Collapsed;
        _list.Children.Clear();
        _pickable.Clear();
        _marked = -1;
    }

    /// Shows `sections` (null closes). `markFirst`: a command's name is being typed, so Enter picks the first match.
    public void Show(IReadOnlyList<ComposerDrawer.Section>? sections, bool markFirst)
    {
        if (sections == null || sections.Count == 0) { Close(); return; }
        var keep = Marked?.Id;
        _list.Children.Clear();
        _pickable.Clear();
        foreach (var section in sections)
        {
            if (section.Title != null) _list.Children.Add(Ui.Header(section.Title));
            foreach (var row in section.Rows) _list.Children.Add(RowView(row));
        }
        View.Visibility = Visibility.Visible;
        var again = keep == null ? -1 : _pickable.FindIndex(p => p.Row.Id == keep);
        _marked = again >= 0 ? again : markFirst && _pickable.Count > 0 ? 0 : -1;
        Paint();
    }

    private UIElement RowView(ComposerDrawer.Row row)
    {
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var title = new StackPanel { Orientation = Orientation.Horizontal };
        if (row.Parent != null) title.Children.Add(new TextBlock { Text = row.Parent, FontFamily = Ui.Res<FontFamily>("CodeFont"), Foreground = Ui.Res<Brush>("TextFillColorTertiaryBrush") });
        var name = new TextBlock
        {
            Text = row.Title, FontWeight = row.Action is ComposerDrawer.RowAction.Command ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal,
        };
        // Only a reference row takes the code face. Setting FontFamily to null throws ("'Unknown' is not a valid value for
        // property 'FontFamily'") and took the app down from the slash drawer in CI run 45020434210.
        if (row.RefFace) name.FontFamily = Ui.Res<FontFamily>("CodeFont");
        title.Children.Add(name);
        if (row.Spinner) grid.Children.Add(new ProgressRing { IsActive = true, Width = 14, Height = 14 });
        Grid.SetColumn(title, 0);
        grid.Children.Add(title);
        if (row.Detail.Length > 0)
        {
            var detail = Ui.Text(row.Detail, 13, secondary: true, wrap: false);
            Grid.SetColumn(detail, 1);
            grid.Children.Add(detail);
        }
        var command = ComposerDrawer.FavoriteCommand(row);
        if (command != null && IsFavorite?.Invoke(command) == true)
        {
            var star = Ui.Glyph("", 12);
            Grid.SetColumn(star, 2);
            grid.Children.Add(star);
        }
        if (!row.Pickable) return new Border { Child = grid, Padding = new Thickness(8, 6, 8, 6) };
        var button = Ui.Row(grid, (_, _) => OnPick?.Invoke(row));
        AutomationProperties.SetName(button, row.SpokenLabel);
        if (command != null)
        {
            var menu = new MenuFlyout();
            var item = new MenuFlyoutItem { Text = ComposerDrawer.FavoriteActionTitle(IsFavorite?.Invoke(command) == true) };
            item.Click += (_, _) => ToggleFavorite?.Invoke(command);
            menu.Items.Add(item);
            button.ContextFlyout = menu;
        }
        _pickable.Add((row, button));
        return button;
    }

    public void Move(int by)
    {
        if (_pickable.Count == 0) return;
        _marked = _marked < 0 ? (by > 0 ? 0 : _pickable.Count - 1) : Math.Clamp(_marked + by, 0, _pickable.Count - 1);
        Paint();
        _pickable[_marked].View.StartBringIntoView();
    }

    private void Paint()
    {
        for (var i = 0; i < _pickable.Count; i++)
            _pickable[i].View.Background = i == _marked
                ? Ui.Res<Brush>("SubtleFillColorSecondaryBrush")
                : new SolidColorBrush(Microsoft.UI.Colors.Transparent);
    }
}
