using Hermes.Core.Tasks;
using HermesHQ.Features.Kanban;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;
using Windows.System;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.Tasks;

/// Pill Tag Picker (`App/Pages/Tasks/TaskTagPickerSheet.swift`, commit 36659bce1):
/// populated from `TodoViews.AllTags`, live filter + comma-add, toggleable pills with checkmark, cap 10.
internal static class TaskTagPickerDialog
{
    public const int MaxTags = 10;

    /// Presents the pill Tag Picker. Returns the chosen list of tags on Save, or null on Cancel.
    public static async Task<List<string>?> PresentAsync(
        XamlRoot? root,
        IReadOnlyList<string> currentTags,
        IReadOnlyList<string> allKnownTags)
    {
        var selected = new List<string>();
        foreach (var raw in currentTags)
        {
            var clean = CleanTag(raw);
            if (clean.Length > 0 && !selected.Any(t => string.Equals(t, clean, StringComparison.OrdinalIgnoreCase)) && selected.Count < MaxTags)
                selected.Add(clean);
        }

        var catalog = new List<string>();
        foreach (var raw in allKnownTags.Concat(selected))
        {
            var clean = CleanTag(raw);
            if (clean.Length > 0 && !catalog.Any(t => string.Equals(t, clean, StringComparison.OrdinalIgnoreCase)))
                catalog.Add(clean);
        }

        var countText = Text("", 12, color: Secondary);
        var input = new TextBox { PlaceholderText = "Add or filter tags (comma to add)" };
        AutomationProperties.SetName(input, "Add or filter tags");
        AutomationProperties.SetAutomationId(input, "tasks.tags.input");

        var selectedWrap = new TaskWrapPanel { HorizontalSpacing = 6, VerticalSpacing = 6 };
        var availableWrap = new TaskWrapPanel { HorizontalSpacing = 6, VerticalSpacing = 6 };
        var selectedHead = Header("Selected");
        var availableHead = Header("All Tags");
        var emptyAvailable = Text("No matching tags. Press Add or Enter to create one.", 12, color: Tertiary);

        var addBtn = new Button { Content = TasksCopy.Add };
        AutomationProperties.SetAutomationId(addBtn, "tasks.tags.add");

        void CommitInput()
        {
            var raw = input.Text;
            if (string.IsNullOrWhiteSpace(raw)) return;
            foreach (var part in TodoViews.TagsFrom(raw))
            {
                if (selected.Count >= MaxTags) break;
                if (!selected.Any(t => string.Equals(t, part, StringComparison.OrdinalIgnoreCase)))
                    selected.Add(part);
                if (!catalog.Any(t => string.Equals(t, part, StringComparison.OrdinalIgnoreCase)))
                    catalog.Add(part);
            }
            input.Text = "";
            Render();
        }
        addBtn.Click += (_, _) => CommitInput();

        void ToggleTag(string tag)
        {
            var idx = selected.FindIndex(t => string.Equals(t, tag, StringComparison.OrdinalIgnoreCase));
            if (idx >= 0) selected.RemoveAt(idx);
            else if (selected.Count < MaxTags) selected.Add(tag);
            Render();
        }

        Button MakePill(string tag, bool isPicked, bool enabled)
        {
            var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5 };
            if (isPicked)
                content.Children.Add(new FontIcon { Glyph = "\uE73E", FontSize = 11, Foreground = Brush("TextOnAccentFillColorPrimaryBrush") });
            content.Children.Add(new TextBlock
            {
                Text = "#" + tag,
                FontSize = 13,
                FontWeight = isPicked ? FontWeights.SemiBold : FontWeights.Normal,
                Foreground = isPicked ? Brush("TextOnAccentFillColorPrimaryBrush") : Brush("TextFillColorPrimaryBrush"),
            });
            var btn = new Button
            {
                Content = content,
                IsEnabled = enabled,
                Padding = new Thickness(10, 4, 10, 5),
                CornerRadius = new CornerRadius(14),
                Background = isPicked ? Brush("AccentFillColorDefaultBrush") : Brush("ControlFillColorDefaultBrush"),
                BorderBrush = isPicked ? Brush("AccentFillColorDefaultBrush") : Brush("ControlStrokeColorDefaultBrush"),
                BorderThickness = new Thickness(1),
            };
            AutomationProperties.SetName(btn, isPicked ? $"Remove tag {tag}" : $"Add tag {tag}");
            AutomationProperties.SetAutomationId(btn, "tasks.tags.pill." + tag);
            btn.Click += (_, _) => ToggleTag(tag);
            return btn;
        }

        void Render()
        {
            countText.Text = $"Tags ({selected.Count}/{MaxTags})";
            addBtn.IsEnabled = !string.IsNullOrWhiteSpace(input.Text) && selected.Count < MaxTags;

            selectedWrap.Children.Clear();
            foreach (var t in selected)
                selectedWrap.Children.Add(MakePill(t, isPicked: true, enabled: true));
            selectedHead.Visibility = selected.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            selectedWrap.Visibility = selected.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

            availableWrap.Children.Clear();
            var filter = input.Text.Trim().TrimStart('#').ToLowerInvariant();
            var matches = catalog
                .Where(t => filter.Length == 0 || t.ToLowerInvariant().Contains(filter, StringComparison.Ordinal))
                .ToList();
            foreach (var t in matches)
            {
                var isPicked = selected.Any(s => string.Equals(s, t, StringComparison.OrdinalIgnoreCase));
                availableWrap.Children.Add(MakePill(t, isPicked, enabled: isPicked || selected.Count < MaxTags));
            }
            availableHead.Visibility = catalog.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            emptyAvailable.Visibility = matches.Count == 0 && filter.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        }

        input.TextChanged += (_, _) =>
        {
            if (input.Text.Contains(',', StringComparison.Ordinal)) CommitInput();
            else Render();
        };
        input.KeyDown += (_, e) =>
        {
            if (e.Key != VirtualKey.Enter) return;
            e.Handled = true;
            CommitInput();
        };

        var inputRow = new Grid { ColumnSpacing = 8 };
        inputRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        inputRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        inputRow.Children.Add(input);
        Grid.SetColumn(addBtn, 1);
        inputRow.Children.Add(addBtn);

        var body = new StackPanel { Spacing = 8, Width = 420 };
        body.Children.Add(countText);
        body.Children.Add(inputRow);
        body.Children.Add(selectedHead);
        body.Children.Add(selectedWrap);
        body.Children.Add(availableHead);
        body.Children.Add(availableWrap);
        body.Children.Add(emptyAvailable);
        Render();

        var dialog = new ContentDialog
        {
            Title = "Tags",
            Content = new ScrollViewer { Content = body, MaxHeight = 460, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
            PrimaryButtonText = TasksCopy.Save,
            CloseButtonText = TasksCopy.Cancel,
            DefaultButton = ContentDialogButton.Primary,
        };
        input.Loaded += (_, _) => input.Focus(FocusState.Programmatic);

        if (await ShowAsync(root, dialog) != ContentDialogResult.Primary) return null;
        if (!string.IsNullOrWhiteSpace(input.Text)) CommitInput();
        return selected;
    }

    private static string CleanTag(string raw)
    {
        var tag = raw.Trim().TrimStart('#').Trim();
        return tag.Length > 30 ? tag[..30] : tag;
    }
}

/// Lightweight wrapping flow panel for pills & chips using pure WinUI 3 `Panel` (no external toolkit dependency).
internal sealed class TaskWrapPanel : Panel
{
    public double HorizontalSpacing { get; set; } = 6;
    public double VerticalSpacing { get; set; } = 6;

    protected override Size MeasureOverride(Size availableSize)
    {
        var maxWidth = double.IsInfinity(availableSize.Width) ? double.PositiveInfinity : availableSize.Width;
        double lineWidth = 0, lineHeight = 0, totalHeight = 0, maxLineWidth = 0;

        foreach (var child in Children)
        {
            child.Measure(new Size(maxWidth, double.PositiveInfinity));
            var sz = child.DesiredSize;
            if (lineWidth > 0 && lineWidth + HorizontalSpacing + sz.Width > maxWidth)
            {
                maxLineWidth = Math.Max(maxLineWidth, lineWidth);
                totalHeight += lineHeight + VerticalSpacing;
                lineWidth = sz.Width;
                lineHeight = sz.Height;
            }
            else
            {
                lineWidth = lineWidth == 0 ? sz.Width : lineWidth + HorizontalSpacing + sz.Width;
                lineHeight = Math.Max(lineHeight, sz.Height);
            }
        }
        maxLineWidth = Math.Max(maxLineWidth, lineWidth);
        totalHeight += lineHeight;
        return new Size(double.IsInfinity(availableSize.Width) ? maxLineWidth : Math.Min(availableSize.Width, maxLineWidth), totalHeight);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        double x = 0, y = 0, lineHeight = 0;
        foreach (var child in Children)
        {
            var sz = child.DesiredSize;
            if (x > 0 && x + sz.Width > finalSize.Width + 0.5)
            {
                x = 0;
                y += lineHeight + VerticalSpacing;
                lineHeight = 0;
            }
            child.Arrange(new Rect(x, y, sz.Width, sz.Height));
            x += sz.Width + HorizontalSpacing;
            lineHeight = Math.Max(lineHeight, sz.Height);
        }
        return finalSize;
    }
}
