using Hermes.Core.Chat;
using Hermes.Core.Model;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace HermesHQ.Features.Threads;

/// Inline thread card drawn inside a parent chat (port of App/Chat/Threads/ChatThreadCell.swift):
/// - Open: vertical accent line, header ("Thread" or short title + count tail + chevron), and the latest
///   question/answer (or working / problem indicator).
/// - Folded: one compact line ("<Title> · N messages ›").
public static class ThreadCardView
{
    private static readonly Brush ProblemBrush = new SolidColorBrush(Color.FromArgb(255, 220, 38, 38));

    public static UIElement Build(ChatThread thread, bool isOpen, Action<ChatThread> onOpen) =>
        isOpen ? BuildOpen(thread, onOpen) : BuildFolded(thread, onOpen);

    private static UIElement BuildOpen(ChatThread thread, Action<ChatThread> onOpen)
    {
        var labelBrush = ThemeBrushes.Get("TextFillColorPrimaryBrush");
        var secondaryBrush = ThemeBrushes.Get("TextFillColorSecondaryBrush");
        var accentBrush = TryBrush("AccentFillColorDefaultBrush", secondaryBrush);
        var cardBg = ThemeBrushes.Get("CardBackgroundFillColorDefaultBrush");
        var cardStroke = ThemeBrushes.Get("CardStrokeColorDefaultBrush");

        var (name, tail) = ThreadRules.Header(thread);
        var (shown, _) = ThreadRules.Shown(thread);

        var outer = new Grid { ColumnSpacing = 10 };
        outer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(3) });
        outer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var accentBar = new Border
        {
            Width = 3,
            CornerRadius = new CornerRadius(1.5),
            Background = thread.Problem != null ? ProblemBrush : accentBrush,
            VerticalAlignment = VerticalAlignment.Stretch,
        };
        outer.Children.Add(accentBar);

        var body = new StackPanel { Spacing = 6 };

        // Header line: glyph, name, optional count tail, chevron.
        var header = new Grid { ColumnSpacing = 6 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var glyph = new FontIcon
        {
            Glyph = "\uE8BD",
            FontSize = 12,
            Foreground = secondaryBrush,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var nameLabel = new TextBlock
        {
            Text = name,
            FontSize = 12.5,
            FontWeight = FontWeights.SemiBold,
            Foreground = secondaryBrush,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var tailLabel = new TextBlock
        {
            Text = tail != null ? $"· {tail}" : "",
            FontSize = 12,
            Foreground = thread.Problem != null ? ProblemBrush : secondaryBrush,
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Visibility = tail != null ? Visibility.Visible : Visibility.Collapsed,
        };
        var chevron = new FontIcon
        {
            Glyph = "\uE76C",
            FontSize = 10,
            Foreground = secondaryBrush,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(nameLabel, 1);
        Grid.SetColumn(tailLabel, 2);
        Grid.SetColumn(chevron, 3);
        header.Children.Add(glyph);
        header.Children.Add(nameLabel);
        header.Children.Add(tailLabel);
        header.Children.Add(chevron);
        body.Children.Add(header);

        // Shown messages (latest user message + bot reply).
        foreach (var msg in shown)
        {
            var text = msg.Text.Trim();
            if (text.Length == 0) continue;
            var isUser = msg.Role == Role.User;
            var preview = text.Length > 240 ? text[..239].TrimEnd() + "…" : text;
            body.Children.Add(new TextBlock
            {
                Text = isUser ? $"You: {preview}" : preview,
                FontSize = 13,
                FontWeight = isUser ? FontWeights.Medium : FontWeights.Normal,
                Foreground = isUser ? secondaryBrush : labelBrush,
                TextWrapping = TextWrapping.Wrap,
            });
        }

        if (thread.Problem is { Length: > 0 } problem)
        {
            body.Children.Add(new TextBlock
            {
                Text = problem,
                FontSize = 12,
                Foreground = ProblemBrush,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        else if (thread.Running)
        {
            var working = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            working.Children.Add(new ProgressRing { IsActive = true, Width = 12, Height = 12 });
            working.Children.Add(new TextBlock
            {
                Text = "Replying in thread…",
                FontSize = 12,
                Foreground = secondaryBrush,
                VerticalAlignment = VerticalAlignment.Center,
            });
            body.Children.Add(working);
        }

        Grid.SetColumn(body, 1);
        outer.Children.Add(body);

        var button = new Button
        {
            Content = outer,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            MaxWidth = 540,
            Padding = new Thickness(10, 8, 12, 8),
            CornerRadius = new CornerRadius(10),
            Background = cardBg,
            BorderBrush = cardStroke,
            BorderThickness = new Thickness(1),
            Margin = new Thickness(0, 4, 0, 4),
        };
        button.Click += (_, _) => onOpen(thread);
        AutomationProperties.SetAutomationId(button, "chat.thread");
        AutomationProperties.SetName(button, tail != null ? $"{name}, {tail}" : name);
        return button;
    }

    private static UIElement BuildFolded(ChatThread thread, Action<ChatThread> onOpen)
    {
        var secondaryBrush = ThemeBrushes.Get("TextFillColorSecondaryBrush");
        var subtleBg = ThemeBrushes.Get("SubtleFillColorSecondaryBrush");
        var stroke = ThemeBrushes.Get("CardStrokeColorDefaultBrush");

        var name = ThreadRules.Name(thread);
        var tail = ThreadRules.FoldedTail(thread);
        var label = tail != null ? $"{name} · {tail}" : name;

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        row.Children.Add(new FontIcon { Glyph = "\uE8BD", FontSize = 11, Foreground = secondaryBrush, VerticalAlignment = VerticalAlignment.Center });
        row.Children.Add(new TextBlock
        {
            Text = label,
            FontSize = 12,
            Foreground = secondaryBrush,
            VerticalAlignment = VerticalAlignment.Center,
        });
        row.Children.Add(new FontIcon { Glyph = "\uE76C", FontSize = 9, Foreground = secondaryBrush, VerticalAlignment = VerticalAlignment.Center });

        var button = new Button
        {
            Content = row,
            HorizontalAlignment = HorizontalAlignment.Left,
            Padding = new Thickness(10, 5, 10, 5),
            CornerRadius = new CornerRadius(12),
            Background = subtleBg,
            BorderBrush = stroke,
            BorderThickness = new Thickness(1),
            Margin = new Thickness(0, 3, 0, 3),
        };
        button.Click += (_, _) => onOpen(thread);
        AutomationProperties.SetAutomationId(button, "chat.thread");
        AutomationProperties.SetName(button, label);
        return button;
    }

    private static Brush TryBrush(string key, Brush fallback)
    {
        try { return ThemeBrushes.Get(key); }
        catch (Exception) { return fallback; }
    }
}
