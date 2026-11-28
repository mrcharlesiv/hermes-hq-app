using Hermes.Core.QuickActions;
using HermesHQ.Features.Kanban;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.QuickActions;

/// Starter Presets picker (`FavoritePresetsSheet` in `QuickActionsViewController.swift`): lets users add or apply one
/// of the 4 curated starter layouts (`CommandCenter`, `DailyFocus`, `VoiceFirst`, `BuilderOps`) to the current page.
internal static class FavoritePresetsDialog
{
    public sealed record Result(FavoritePreset Preset, bool ReplaceCurrentPage);

    public static async Task<Result?> ShowAsync(XamlRoot? root, string currentPageName)
    {
        if (root == null) return null;
        FavoritePreset? picked = null;

        var replaceToggle = new ToggleSwitch
        {
            Header = $"Replace tiles on “{currentPageName}”",
            OnContent = "Replace current page",
            OffContent = "Add to current page",
            IsOn = false,
        };
        AutomationProperties.SetAutomationId(replaceToggle, "favorites.presets.replace");

        var dialog = new ContentDialog
        {
            Title = "Starter Presets",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        AutomationProperties.SetAutomationId(dialog, "favorites.presets-sheet");

        var cards = new StackPanel { Spacing = 8 };
        foreach (var preset in FavoritePresets.All)
        {
            var p = preset;
            var icon = new Border
            {
                Width = 34,
                Height = 34,
                CornerRadius = new CornerRadius(8),
                Background = QuickActionsPage.TileBrush(PresetColor(p)),
                VerticalAlignment = VerticalAlignment.Center,
                Child = new FontIcon
                {
                    Glyph = QuickActionsPage.Glyph(p.Symbol()),
                    FontSize = 16,
                    Foreground = new SolidColorBrush(Microsoft.UI.Colors.White),
                },
            };

            var words = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
            words.Children.Add(new TextBlock
            {
                Text = p.Title(),
                FontSize = 14,
                FontWeight = FontWeights.SemiBold,
            });
            words.Children.Add(new TextBlock
            {
                Text = p.Subtitle(),
                FontSize = 12,
                Foreground = PageKit.Secondary,
                TextWrapping = TextWrapping.WrapWholeWords,
            });

            var row = new Grid { ColumnSpacing = 12 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.Children.Add(icon);
            Grid.SetColumn(words, 1);
            row.Children.Add(words);

            var btn = new Button
            {
                Content = row,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Padding = new Thickness(12, 10, 12, 10),
                CornerRadius = new CornerRadius(10),
            };
            AutomationProperties.SetAutomationId(btn, "favorites.preset." + p.Raw());
            AutomationProperties.SetName(btn, $"{p.Title()}, {p.Subtitle()}");
            btn.Click += (_, _) =>
            {
                picked = p;
                dialog.Hide();
            };
            cards.Children.Add(btn);
        }

        var body = new StackPanel { Spacing = 12, MinWidth = 380 };
        body.Children.Add(PageKit.Text("Pick a layout to kick-start this Favorites page.", 13, color: PageKit.Secondary));
        body.Children.Add(cards);
        body.Children.Add(replaceToggle);
        dialog.Content = new ScrollViewer { Content = body, MaxHeight = 520 };

        await PageKit.ShowAsync(root, dialog);
        return picked is { } chosen ? new Result(chosen, replaceToggle.IsOn) : null;
    }

    private static QuickTileColor PresetColor(FavoritePreset preset) => preset switch
    {
        FavoritePreset.CommandCenter => QuickTileColor.Indigo,
        FavoritePreset.DailyFocus => QuickTileColor.Orange,
        FavoritePreset.VoiceFirst => QuickTileColor.Green,
        FavoritePreset.BuilderOps => QuickTileColor.Teal,
        _ => QuickTileColor.Accent,
    };
}
