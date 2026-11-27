using Hermes.Core.Voice;
using HermesHQ.Features.Transcript;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.Voice;

/// Port of App/Chat/Voice/TalkIntroSheet.swift: first-time "Talk with <Bot>" onboarding dialog
/// (persisting `hq.voice.introSeen`) and the "How Voice Works" informational sheet.
public static class TalkIntroDialog
{
    /// Shows the first-time Talk intro if it hasn't been seen yet; returns true when Talk should start.
    public static async Task<bool> EnsureIntroAcceptedAsync(XamlRoot? root, string botName, bool isLiveOffered)
    {
        if (TalkPrefs.IntroSeen(FilePreferences.Shared)) return true;
        if (root == null) return true;

        var dialog = new ContentDialog
        {
            Title = TalkIntroModel.Title(botName),
            Content = BuildBody(botName, isLiveOffered),
            PrimaryButtonText = TalkIntroModel.StartButton,
            CloseButtonText = TalkIntroModel.LaterButton,
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = root,
        };
        AutomationProperties.SetAutomationId(dialog, "talk.intro.dialog");
        try
        {
            var result = await dialog.ShowAsync();
            if (result == ContentDialogResult.Primary)
            {
                TalkPrefs.MarkIntroSeen(FilePreferences.Shared);
                return true;
            }
            return false;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// Shows the "How Voice Works" informational sheet from the Voice Options menu.
    public static async Task ShowHowVoiceWorksAsync(XamlRoot? root, string botName, bool isLiveOffered)
    {
        if (root == null) return;
        var dialog = new ContentDialog
        {
            Title = TalkIntroModel.InfoTitle,
            Content = BuildBody(botName, isLiveOffered),
            CloseButtonText = TalkIntroModel.DoneButton,
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = root,
        };
        AutomationProperties.SetAutomationId(dialog, "talk.howItWorks.dialog");
        try { await dialog.ShowAsync(); }
        catch (Exception) { }
    }

    private static UIElement BuildBody(string botName, bool isLiveOffered)
    {
        var panel = new StackPanel { Spacing = 14, MaxWidth = 420, Margin = new Thickness(0, 6, 0, 0) };
        foreach (var row in TalkIntroModel.Rows(botName, isLiveOffered))
        {
            var grid = new Grid { ColumnSpacing = 12 };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

            var badge = new Border
            {
                Width = 34,
                Height = 34,
                CornerRadius = new CornerRadius(17),
                Background = ThemeBrushes.Get("SubtleFillColorSecondaryBrush"),
                VerticalAlignment = VerticalAlignment.Top,
                Child = new FontIcon
                {
                    Glyph = row.Glyph,
                    FontSize = 15,
                    Foreground = ThemeBrushes.Get("AccentFillColorDefaultBrush"),
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            };

            var words = new StackPanel { Spacing = 2 };
            words.Children.Add(new TextBlock { Text = row.Title, FontSize = 13, FontWeight = FontWeights.SemiBold });
            words.Children.Add(new TextBlock
            {
                Text = row.Detail,
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            });

            Grid.SetColumn(badge, 0);
            Grid.SetColumn(words, 1);
            grid.Children.Add(badge);
            grid.Children.Add(words);
            panel.Children.Add(grid);
        }
        return panel;
    }
}
