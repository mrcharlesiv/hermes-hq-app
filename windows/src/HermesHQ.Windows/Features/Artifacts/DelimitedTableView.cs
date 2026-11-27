using Hermes.Core.Artifacts;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Artifacts;

/// [WIN-FILE-DELIMITED] A .csv or .tsv in its file window as the app's own table (TableSheetController.filePage in the
/// Mac's file window): the counts under the bar ("first 400 of 1,234 rows · 3 columns"), a header row that stays put
/// while the body scrolls, a header click sorting up, down and back, search from 8 rows, and Copy as Text (with CSV and
/// Markdown beside it) taking the rows as shown. The window's bar keeps Open in…, Share… and Save As…. Every cell is a
/// plain TextBlock: what the file says, never a formula worked out or a link followed. The decisions are
/// Hermes.Core/Artifacts/DelimitedFile.cs (DelimitedTable).
internal sealed class DelimitedTableView : Grid
{
    private readonly DelimitedTable _table;
    private readonly TextBlock _subtitle = Look.Text("", 12, "TextFillColorSecondaryBrush");
    private readonly Grid _body = new();
    private readonly List<TextBlock[]> _rows = [];
    private readonly List<TextBlock> _headers = [];
    private readonly List<Button> _headerButtons = [];

    public DelimitedTableView(DelimitedSheet sheet, string title)
    {
        _table = new DelimitedTable(sheet, title);
        AutomationProperties.SetAutomationId(this, DelimitedTable.PageId);
        AutomationProperties.SetName(this, title);
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        // The counts, search and the copies.
        var top = new Grid { Padding = new Thickness(16, 4, 16, 8), ColumnSpacing = 8 };
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _subtitle.VerticalAlignment = VerticalAlignment.Center;
        _subtitle.TextWrapping = TextWrapping.NoWrap;
        _subtitle.TextTrimming = TextTrimming.CharacterEllipsis;
        top.Children.Add(_subtitle);
        if (_table.ShowsSearch)
        {
            var search = new TextBox { PlaceholderText = _table.SearchPlaceholder, Width = 240 };
            AutomationProperties.SetName(search, _table.SearchPlaceholder);
            AutomationProperties.SetAutomationId(search, DelimitedTable.SearchId);
            search.TextChanged += (_, _) =>
            {
                _table.Search(search.Text);
                Place();
            };
            Grid.SetColumn(search, 1);
            top.Children.Add(search);
        }
        var copy = new SplitButton { Content = DelimitedTable.CopyTitle };
        AutomationProperties.SetName(copy, DelimitedTable.CopyTitle);
        AutomationProperties.SetAutomationId(copy, "table.sheet.copy");
        copy.Click += (_, _) => Copy(_table.CopyText());
        var more = new MenuFlyout();
        more.Items.Add(Item(DelimitedTable.CopyCsvTitle, () => Copy(_table.CopyCsv())));
        more.Items.Add(Item(DelimitedTable.CopyMarkdownTitle, () => Copy(_table.CopyMarkdown())));
        copy.Flyout = more;
        Grid.SetColumn(copy, 2);
        top.Children.Add(copy);
        Children.Add(top);

        // The table: one sideways scroller holding the header (which stays put) over the body's own up-and-down one.
        var widths = Enumerable.Range(0, _table.Columns).Select(c => _table.ColumnWidth(c)).ToList();
        var header = new Grid { Background = Look.Brush("SubtleFillColorSecondaryBrush") };
        foreach (var w in widths)
        {
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(w) });
            _body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(w) });
        }
        for (var c = 0; c < _table.Columns; c++)
        {
            var column = c;
            var words = new TextBlock
            {
                Text = _table.Header[c], FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, MaxLines = 3,
                TextAlignment = _table.Numeric[c] ? TextAlignment.Right : TextAlignment.Left,
            };
            _headers.Add(words);
            var button = new Button
            {
                Content = words, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Padding = new Thickness(12, 9, 12, 9), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                BorderThickness = new Thickness(0), CornerRadius = new CornerRadius(0),
            };
            AutomationProperties.SetAutomationId(button, $"table.sheet.header.{c}");
            button.Click += (_, _) =>
            {
                var said = _table.CycleSort(column);
                Place();
                if (said.Length > 0) AutomationProperties.SetHelpText(this, said);
            };
            _headerButtons.Add(button);
            Grid.SetColumn(button, c);
            header.Children.Add(button);
        }
        for (var r = 0; r < _table.Body.Count; r++)
        {
            _body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var cells = new TextBlock[_table.Columns];
            for (var c = 0; c < _table.Columns; c++)
            {
                var cell = new TextBlock
                {
                    Text = _table.Body[r][c], TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, MaxLines = 6,
                    TextTrimming = TextTrimming.CharacterEllipsis, Padding = new Thickness(12, 8, 12, 8),
                    TextAlignment = _table.Numeric[c] ? TextAlignment.Right : TextAlignment.Left,
                };
                Grid.SetColumn(cell, c);
                _body.Children.Add(cell);
                cells[c] = cell;
            }
            _rows.Add(cells);
        }
        var bodyScroll = new ScrollViewer
        {
            Content = _body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollMode = ScrollMode.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalScrollMode = ScrollMode.Disabled,
        };
        var stack = new Grid { HorizontalAlignment = HorizontalAlignment.Left };
        stack.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        stack.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        stack.Children.Add(header);
        Grid.SetRow(bodyScroll, 1);
        stack.Children.Add(bodyScroll);
        var sideways = new ScrollViewer
        {
            Content = stack, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollMode = ScrollMode.Disabled,
        };
        var card = new Border
        {
            Child = sideways, Margin = new Thickness(16, 0, 16, 16), CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1),
            BorderBrush = Look.Brush("CardStrokeColorDefaultBrush"), Background = Look.Brush("CardBackgroundFillColorDefaultBrush"),
        };
        Grid.SetRow(card, 1);
        Children.Add(card);
        Place();
    }

    private static MenuFlyoutItem Item(string text, Action act)
    {
        var item = new MenuFlyoutItem { Text = text };
        item.Click += (_, _) => act();
        return item;
    }

    private void Copy(string? text)
    {
        if (string.IsNullOrEmpty(text)) return;
        try { ArtifactActions.Copy(text); }
        catch (Exception e) { ArtifactActions.Log($"table copy failed: {e.GetType().Name}"); }
    }

    /// Every body row where the current order and search put it; the rows the search hides collapse.
    private void Place()
    {
        var at = new int[_rows.Count];
        Array.Fill(at, -1);
        for (var i = 0; i < _table.Order.Count; i++) at[_table.Order[i]] = i;
        for (var r = 0; r < _rows.Count; r++)
            foreach (var cell in _rows[r])
            {
                cell.Visibility = at[r] >= 0 ? Visibility.Visible : Visibility.Collapsed;
                if (at[r] >= 0) Grid.SetRow(cell, at[r]);
            }
        for (var c = 0; c < _headerButtons.Count; c++)
        {
            var mark = _table.SortMark(c);
            _headers[c].Text = mark.Length == 0 ? _table.Header[c] : $"{_table.Header[c]} {mark}";
            var name = _table.Header[c].Length > 0 ? _table.Header[c] : $"column {c + 1}";
            AutomationProperties.SetName(_headerButtons[c], _table.Sort is { } s && s.Column == c
                ? $"{name}, sorted {(s.Ascending ? "ascending" : "descending")}" : $"{name}, sort");
        }
        _subtitle.Text = _table.Subtitle();
    }
}
