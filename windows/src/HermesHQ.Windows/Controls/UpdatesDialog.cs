using System.Globalization;
using Hermes.Core.Model;
using Hermes.Core.Transcripts;
using HermesHQ.Services;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Controls;

/// Detail dialog for folded update groups and bot exchanges (port of App/Chat/UpdatesSheet.swift):
/// shows the run's title, subtitle, and each member on a card beside a vertical rail, with expandable long text,
/// clickable tool steps, and copy menu.
public static class UpdatesDialog
{
    private const int CollapseThresholdChars = 360;
    private const int CollapseThresholdLines = 6;
    private static readonly CultureInfo EnUs = CultureInfo.GetCultureInfo("en-US");

    public static async Task ShowAsync(
        XamlRoot? xamlRoot,
        UpdatesOpened opened,
        Action<string, ToolCall>? onOpenStep = null)
    {
        if (xamlRoot == null) return;

        var labelBrush = ThemeBrushes.Get("TextFillColorPrimaryBrush");
        var secondaryBrush = ThemeBrushes.Get("TextFillColorSecondaryBrush");
        var cardBg = ThemeBrushes.Get("CardBackgroundFillColorDefaultBrush");
        var cardStroke = ThemeBrushes.Get("CardStrokeColorDefaultBrush");
        var subtleBg = ThemeBrushes.Get("SubtleFillColorSecondaryBrush");
        var monoFont = TryCodeFont();

        var root = new StackPanel { Spacing = 10, MinWidth = 460, MaxWidth = 560 };
        if (!string.IsNullOrEmpty(opened.Subtitle))
        {
            root.Children.Add(new TextBlock
            {
                Text = opened.Subtitle,
                FontSize = 12.5,
                Foreground = secondaryBrush,
            });
        }

        var list = new StackPanel { Spacing = 10 };
        AutomationProperties.SetAutomationId(list, "updates.list");

        ContentDialog? dialog = null;
        for (var i = 0; i < opened.Members.Count; i++)
        {
            var member = opened.Members[i];
            var isLast = i == opened.Members.Count - 1;
            list.Children.Add(BuildMemberRow(member, isLast, labelBrush, secondaryBrush, cardBg, cardStroke, subtleBg, monoFont,
                (msgId, call) =>
                {
                    dialog?.Hide();
                    onOpenStep?.Invoke(msgId, call);
                }));
        }

        var scroll = new ScrollViewer
        {
            Content = list,
            MaxHeight = 520,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        root.Children.Add(scroll);

        dialog = new ContentDialog
        {
            Title = opened.Title,
            Content = root,
            CloseButtonText = "Done",
            DefaultButton = ContentDialogButton.Close,
        };
        await SafeDialog.ShowAsync(xamlRoot, dialog);
    }

    private static FrameworkElement BuildMemberRow(
        UpdateMemberRow member,
        bool isLast,
        Brush labelBrush,
        Brush secondaryBrush,
        Brush cardBg,
        Brush cardStroke,
        Brush subtleBg,
        FontFamily monoFont,
        Action<string, ToolCall>? onOpenStep)
    {
        var row = new Grid { ColumnSpacing = 10 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(28) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        // Vertical timeline rail + node avatar/glyph.
        var rail = new Grid();
        if (!isLast)
        {
            rail.Children.Add(new Border
            {
                Width = 2,
                Background = cardStroke,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Stretch,
                Margin = new Thickness(0, 28, 0, -10),
            });
        }
        FrameworkElement node;
        if (member.Mark.Kind == UpdateMarkKind.Face && member.Mark.Face is { } face)
        {
            node = new BotHead
            {
                DisplayName = face.Name,
                Width = 24,
                Height = 24,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(0, 2, 0, 0),
            };
        }
        else
        {
            node = new Border
            {
                Width = 24,
                Height = 24,
                CornerRadius = new CornerRadius(12),
                Background = subtleBg,
                BorderBrush = cardStroke,
                BorderThickness = new Thickness(1),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(0, 2, 0, 0),
                Child = new FontIcon
                {
                    Glyph = GlyphFor(member.Mark.Glyph, member.Notice),
                    FontSize = 11,
                    Foreground = secondaryBrush,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            };
        }
        rail.Children.Add(node);
        row.Children.Add(rail);

        // Card content.
        var body = new StackPanel { Spacing = 6 };
        var headGrid = new Grid { ColumnSpacing = 8 };
        headGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        headGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        headGrid.Children.Add(new TextBlock
        {
            Text = member.Title,
            FontSize = 13,
            FontWeight = member.Notice ? FontWeights.Normal : FontWeights.SemiBold,
            Foreground = member.Notice ? secondaryBrush : labelBrush,
            TextWrapping = TextWrapping.Wrap,
        });

        var stamp = FormatStamp(member.Day, member.Time);
        if (stamp.Length > 0)
        {
            var timeBlock = new TextBlock
            {
                Text = stamp,
                FontSize = 11.5,
                Foreground = secondaryBrush,
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(timeBlock, 1);
            headGrid.Children.Add(timeBlock);
        }
        body.Children.Add(headGrid);

        if (!string.IsNullOrEmpty(member.Full))
        {
            var needsCollapse = member.Full.Length > CollapseThresholdChars
                || member.Full.Count(c => c == '\n') >= CollapseThresholdLines;
            var expanded = !needsCollapse;
            var textBlock = new TextBlock
            {
                Text = expanded ? member.Full : ClipPreview(member.Full),
                FontSize = member.Process ? 12 : 13,
                FontFamily = member.Process ? monoFont : new FontFamily("Segoe UI Variable Text, Segoe UI"),
                Foreground = labelBrush,
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
            };
            body.Children.Add(textBlock);

            if (needsCollapse)
            {
                var toggle = new HyperlinkButton
                {
                    Content = "Show More",
                    Padding = new Thickness(0),
                    FontSize = 12,
                };
                toggle.Click += (_, _) =>
                {
                    expanded = !expanded;
                    textBlock.Text = expanded ? member.Full : ClipPreview(member.Full);
                    toggle.Content = expanded ? "Show Less" : "Show More";
                };
                body.Children.Add(toggle);
            }
        }
        else if (!string.IsNullOrEmpty(member.Preview) && !member.Notice)
        {
            body.Children.Add(new TextBlock
            {
                Text = member.Preview,
                FontSize = 12.5,
                Foreground = secondaryBrush,
                TextWrapping = TextWrapping.Wrap,
            });
        }

        if (!string.IsNullOrEmpty(member.Thought))
        {
            body.Children.Add(new TextBlock
            {
                Text = member.Thought,
                FontSize = 12,
                Foreground = secondaryBrush,
                TextWrapping = TextWrapping.Wrap,
            });
        }

        if (member.Steps is { Count: > 0 } steps)
        {
            var stepsPanel = new StackPanel { Spacing = 4 };
            foreach (var step in steps)
            {
                var captured = step;
                var stepBtn = new Button
                {
                    Content = new TextBlock
                    {
                        Text = captured.Title,
                        FontSize = 12,
                        Foreground = secondaryBrush,
                        TextTrimming = TextTrimming.CharacterEllipsis,
                    },
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Left,
                    Padding = new Thickness(8, 4, 8, 4),
                    Background = subtleBg,
                    BorderThickness = new Thickness(0),
                    CornerRadius = new CornerRadius(6),
                };
                stepBtn.Click += (_, _) => onOpenStep?.Invoke(member.MessageId, captured);
                stepsPanel.Children.Add(stepBtn);
            }
            body.Children.Add(stepsPanel);
        }

        var card = new Border
        {
            Padding = new Thickness(12, 9, 12, 9),
            CornerRadius = new CornerRadius(10),
            Background = member.Notice ? subtleBg : cardBg,
            BorderBrush = cardStroke,
            BorderThickness = new Thickness(member.Notice ? 0 : 1),
            Child = body,
        };
        if (!string.IsNullOrEmpty(member.Full))
        {
            var menu = new MenuFlyout();
            var copy = new MenuFlyoutItem { Text = "Copy", Icon = new FontIcon { Glyph = "\uE8C8" } };
            copy.Click += (_, _) => SafeClipboard.TrySetText(member.Full);
            menu.Items.Add(copy);
            card.ContextFlyout = menu;
        }
        AutomationProperties.SetAutomationId(card, member.Id);
        Grid.SetColumn(card, 1);
        row.Children.Add(card);
        return row;
    }

    private static string ClipPreview(string full)
    {
        var lines = full.Split('\n');
        var joined = lines.Length > CollapseThresholdLines
            ? string.Join('\n', lines.Take(CollapseThresholdLines))
            : full;
        if (joined.Length > CollapseThresholdChars) joined = joined[..CollapseThresholdChars].TrimEnd();
        return joined + "…";
    }

    private static string FormatStamp(string? day, DateTimeOffset? time)
    {
        var clock = time is { } t ? t.LocalDateTime.ToString("h:mm tt", EnUs) : "";
        if (!string.IsNullOrEmpty(day) && clock.Length > 0) return $"{day} {clock}";
        return clock.Length > 0 ? clock : (day ?? "");
    }

    private static string GlyphFor(StepGlyph glyph, bool notice)
    {
        if (notice) return "\uE946";
        return glyph switch
        {
            StepGlyph.File => "\uE8A5",
            StepGlyph.Explore => "\uE721",
            StepGlyph.Terminal => "\uE756",
            StepGlyph.Subagent => "\uE716",
            StepGlyph.Thinking => "\uE8BD",
            _ => "\uE945",
        };
    }

    private static FontFamily TryCodeFont()
    {
        try { return ThemeBrushes.Res<FontFamily>("CodeFont"); }
        catch (Exception) { return new FontFamily("Cascadia Mono, Consolas"); }
    }
}
