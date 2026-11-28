using Hermes.Core.Chat;
using Hermes.Core.Model;
using HermesHQ.Services;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace HermesHQ.Features.Threads;

/// Calm proactive busy-chat routing banner shown in the composer shelf (`ThreadBusyBanner`)
/// + live thread sheet/dialog (`ThreadWindow.ShowAsync`).
public static class ThreadWindow
{
    /// Builds the proactive busy-thread banner strip shown above the composer when sends auto-route into a thread.
    public static FrameworkElement BuildBusyBanner(
        ThreadBusyBanner banner,
        Action onUseMain,
        Action<string>? onOpenThread = null)
    {
        var labelBrush = ThemeBrushes.Get("TextFillColorPrimaryBrush");
        var secondaryBrush = ThemeBrushes.Get("TextFillColorSecondaryBrush");
        var cardBg = ThemeBrushes.Get("CardBackgroundFillColorDefaultBrush");
        var cardStroke = ThemeBrushes.Get("CardStrokeColorDefaultBrush");

        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var icon = new FontIcon
        {
            Glyph = "\uE8BD",
            FontSize = 14,
            Foreground = secondaryBrush,
            VerticalAlignment = VerticalAlignment.Center,
        };

        var words = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(new TextBlock
        {
            Text = banner.Title,
            FontSize = 12.5,
            FontWeight = FontWeights.SemiBold,
            Foreground = labelBrush,
        });
        words.Children.Add(new TextBlock
        {
            Text = banner.Note,
            FontSize = 11.5,
            Foreground = secondaryBrush,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        if (banner.ThreadKey is { Length: > 0 } key && onOpenThread != null)
        {
            var openBtn = new Button { Content = "Open", Padding = new Thickness(10, 4, 10, 4), FontSize = 12 };
            AutomationProperties.SetAutomationId(openBtn, "chat.thread.open-busy");
            openBtn.Click += (_, _) => onOpenThread(key);
            actions.Children.Add(openBtn);
        }
        var useMainBtn = new Button { Content = "Use Main", Padding = new Thickness(10, 4, 10, 4), FontSize = 12 };
        AutomationProperties.SetAutomationId(useMainBtn, "chat.thread.use-main");
        useMainBtn.Click += (_, _) => onUseMain();
        actions.Children.Add(useMainBtn);

        Grid.SetColumn(words, 1);
        Grid.SetColumn(actions, 2);
        grid.Children.Add(icon);
        grid.Children.Add(words);
        grid.Children.Add(actions);

        var border = new Border
        {
            Child = grid,
            Padding = new Thickness(12, 8, 12, 8),
            CornerRadius = new CornerRadius(10),
            Background = cardBg,
            BorderBrush = cardStroke,
            BorderThickness = new Thickness(1),
            Margin = new Thickness(0, 0, 0, 6),
        };
        AutomationProperties.SetAutomationId(border, "chat.thread.busy-banner");
        AutomationProperties.SetName(border, $"{banner.Title}. {banner.Note}");
        return border;
    }

    /// Opens a live thread dialog/sheet displaying the thread's messages and an inline reply composer.
    public static async Task ShowAsync(
        XamlRoot? xamlRoot,
        ChatSession session,
        string title,
        Action? onClosed = null)
    {
        if (xamlRoot == null) return;
        var ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();

        var labelBrush = ThemeBrushes.Get("TextFillColorPrimaryBrush");
        var secondaryBrush = ThemeBrushes.Get("TextFillColorSecondaryBrush");
        var cardBg = ThemeBrushes.Get("CardBackgroundFillColorDefaultBrush");
        var cardStroke = ThemeBrushes.Get("CardStrokeColorDefaultBrush");
        var subtleBg = ThemeBrushes.Get("SubtleFillColorSecondaryBrush");

        var root = new Grid { RowSpacing = 10, MinWidth = 480, MaxWidth = 580, Height = 520 };
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var list = new StackPanel { Spacing = 8, Padding = new Thickness(2, 4, 8, 4) };
        AutomationProperties.SetAutomationId(list, "thread.messages");
        var scroll = new ScrollViewer
        {
            Content = list,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        root.Children.Add(scroll);

        var composerRow = new Grid { ColumnSpacing = 8 };
        composerRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        composerRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var input = new TextBox
        {
            PlaceholderText = "Reply in thread…",
            AcceptsReturn = false,
        };
        AutomationProperties.SetAutomationId(input, "thread.composer");

        var sendBtn = new Button { Content = "Send", Padding = new Thickness(14, 6, 14, 6) };
        AutomationProperties.SetAutomationId(sendBtn, "thread.send");
        Grid.SetColumn(sendBtn, 1);
        composerRow.Children.Add(input);
        composerRow.Children.Add(sendBtn);
        Grid.SetRow(composerRow, 1);
        root.Children.Add(composerRow);

        void Render()
        {
            UiTree.ClearPanel(list);
            var messages = session.Messages;
            if (messages.Count == 0 && !session.Busy)
            {
                list.Children.Add(new TextBlock
                {
                    Text = "No messages in this thread yet.",
                    FontSize = 13,
                    Foreground = secondaryBrush,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    Margin = new Thickness(0, 24, 0, 0),
                });
            }
            foreach (var msg in messages)
            {
                var text = msg.Text.Trim();
                if (text.Length == 0 && msg.Error == null) continue;
                var isUser = msg.Role == Role.User;
                var isSystem = msg.Role == Role.System;
                if (isSystem)
                {
                    list.Children.Add(new TextBlock
                    {
                        Text = text,
                        FontSize = 12,
                        Foreground = secondaryBrush,
                        HorizontalAlignment = HorizontalAlignment.Center,
                        TextWrapping = TextWrapping.Wrap,
                        Margin = new Thickness(0, 2, 0, 2),
                    });
                    continue;
                }
                var bubble = new Border
                {
                    Padding = new Thickness(11, 8, 11, 8),
                    CornerRadius = new CornerRadius(10),
                    Background = isUser ? subtleBg : cardBg,
                    BorderBrush = cardStroke,
                    BorderThickness = new Thickness(1),
                    HorizontalAlignment = isUser ? HorizontalAlignment.Right : HorizontalAlignment.Left,
                    MaxWidth = 440,
                    Child = new TextBlock
                    {
                        Text = text.Length > 0 ? text : (msg.Error ?? ""),
                        FontSize = 13.5,
                        Foreground = labelBrush,
                        TextWrapping = TextWrapping.Wrap,
                        IsTextSelectionEnabled = true,
                    },
                };
                list.Children.Add(bubble);
            }
            if (session.Busy)
            {
                var working = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(4, 2, 0, 2) };
                working.Children.Add(new ProgressRing { IsActive = true, Width = 14, Height = 14 });
                working.Children.Add(new TextBlock
                {
                    Text = session.Status ?? "Replying…",
                    FontSize = 12,
                    Foreground = secondaryBrush,
                    VerticalAlignment = VerticalAlignment.Center,
                });
                list.Children.Add(working);
            }
            sendBtn.Content = session.Busy ? "Stop" : "Send";
            scroll.ChangeView(null, scroll.ScrollableHeight, null, disableAnimation: true);
        }

        void DoSendOrStop()
        {
            if (session.Busy)
            {
                _ = session.StopAsync();
                return;
            }
            var text = input.Text.Trim();
            if (text.Length == 0) return;
            input.Text = "";
            _ = session.SendAsync(text);
        }

        sendBtn.Click += (_, _) => DoSendOrStop();
        input.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Enter) { DoSendOrStop(); e.Handled = true; }
        };

        void OnChanged() => ui.TryEnqueue(Render);

        session.Observing = true;
        session.Changed += OnChanged;
        Render();

        var dialog = new ContentDialog
        {
            Title = string.IsNullOrWhiteSpace(title) ? ThreadRules.DefaultTitle : title,
            Content = root,
            CloseButtonText = "Done",
            DefaultButton = ContentDialogButton.None,
        };

        try
        {
            await SafeDialog.ShowAsync(xamlRoot, dialog);
        }
        finally
        {
            session.Changed -= OnChanged;
            session.Observing = false;
            UiTree.DeactivateProgressRings(list);
            onClosed?.Invoke();
        }
    }
}
