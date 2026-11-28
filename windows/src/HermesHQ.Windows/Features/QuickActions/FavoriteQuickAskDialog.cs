using Hermes.Core.Composer;
using HermesHQ.Features.Composer;
using HermesHQ.Features.Kanban;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.QuickActions;

/// Lightweight prompt composer over Favorites (`App/QuickActions/FavoriteQuickAskSheet.swift`): lets the user ask a bot
/// without leaving Favorites (or open the chat with `"Open the Chat"` toggled on), plus quick picks from the top 5
/// saved prompts in `ComposerServices.Prompts`.
internal static class FavoriteQuickAskDialog
{
    public sealed record Result(string Message, bool OpenChat);

    public static async Task<Result?> ShowAsync(
        XamlRoot? root,
        string botProfile,
        string botName,
        bool defaultOpenChat,
        string? initialMessage = null)
    {
        if (root == null) return null;

        var dialog = new ContentDialog
        {
            Title = $"Ask {botName}",
            PrimaryButtonText = "Send",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(initialMessage),
        };
        AutomationProperties.SetAutomationId(dialog, "favorites.quick-ask-sheet");

        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, VerticalAlignment = VerticalAlignment.Center };
        header.Children.Add(PageKit.Face(botProfile, 28));
        header.Children.Add(new TextBlock
        {
            Text = $"Message {botName}",
            FontSize = 13,
            Foreground = PageKit.Secondary,
            VerticalAlignment = VerticalAlignment.Center,
        });

        // AcceptsReturn = true MUST come before Text assignment (WinUI 3 RichEditBox strips newlines otherwise).
        var input = new TextBox
        {
            AcceptsReturn = true,
            Text = initialMessage ?? "",
            PlaceholderText = $"Ask {botName} anything…",
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 96,
            MaxHeight = 200,
        };
        AutomationProperties.SetAutomationId(input, "favorites.quick-ask.input");
        AutomationProperties.SetName(input, $"Message for {botName}");
        input.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(input.Text);

        var openToggle = new ToggleSwitch
        {
            Header = "Open the Chat",
            OnContent = "Jump to chat after sending",
            OffContent = "Send in background",
            IsOn = defaultOpenChat,
        };
        AutomationProperties.SetAutomationId(openToggle, "favorites.quick-ask.open");

        var body = new StackPanel { Spacing = 10, MinWidth = 380 };
        body.Children.Add(header);
        body.Children.Add(input);
        body.Children.Add(openToggle);

        var prompts = ComposerServices.Prompts.Prompts.Take(5).ToList();
        if (prompts.Count > 0)
        {
            body.Children.Add(new TextBlock
            {
                Text = "Saved Prompts",
                FontSize = 12,
                FontWeight = FontWeights.SemiBold,
                Foreground = PageKit.Secondary,
                Margin = new Thickness(0, 4, 0, 0),
            });
            var list = new StackPanel { Spacing = 4 };
            foreach (var prompt in prompts)
            {
                var p = prompt;
                var row = new StackPanel { Spacing = 1 };
                row.Children.Add(new TextBlock
                {
                    Text = p.DisplayTitle,
                    FontSize = 12.5,
                    FontWeight = FontWeights.SemiBold,
                    MaxLines = 1,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                });
                if (!string.IsNullOrEmpty(p.Preview))
                {
                    row.Children.Add(new TextBlock
                    {
                        Text = p.Preview,
                        FontSize = 11.5,
                        Foreground = PageKit.Secondary,
                        MaxLines = 1,
                        TextTrimming = TextTrimming.CharacterEllipsis,
                    });
                }
                var btn = new Button
                {
                    Content = row,
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Left,
                    Padding = new Thickness(10, 6, 10, 6),
                };
                AutomationProperties.SetName(btn, $"Use prompt {p.DisplayTitle}");
                btn.Click += (_, _) =>
                {
                    input.Text = p.Text;
                    input.SelectionStart = input.Text.Length;
                    input.Focus(FocusState.Programmatic);
                };
                list.Children.Add(btn);
            }
            body.Children.Add(list);
        }

        dialog.Content = new ScrollViewer { Content = body, MaxHeight = 520 };
        input.Loaded += (_, _) => input.Focus(FocusState.Programmatic);

        var outcome = await PageKit.ShowAsync(root, dialog);
        if (outcome != ContentDialogResult.Primary) return null;
        var text = input.Text.Trim();
        return text.Length == 0 ? null : new Result(text, openToggle.IsOn);
    }
}
