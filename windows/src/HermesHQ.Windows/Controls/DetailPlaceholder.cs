using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Controls;

/// The unopened right pane (DetailPlaceholderViewController.followOnMac, MacTokens). The caller hides it
/// beside an empty list. Centre the heading, not the stack: wrapping the detail must not move the title.
internal static class DetailPlaceholder
{
    public static Grid Make(string title, string detail)
    {
        var block = new Grid { MaxWidth = 480, Margin = new Thickness(24, 0, 24, 80), IsHitTestVisible = false };
        block.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        block.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        block.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var icon = new FontIcon { Glyph = "\uEA49", FontSize = 34, VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 0, 14), Foreground = ThemeBrushes.Get("TextFillColorTertiaryBrush") };
        block.Children.Add(icon);
        var heading = new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, FontSize = 20,
            TextWrapping = TextWrapping.WrapWholeWords, TextAlignment = TextAlignment.Center };
        Grid.SetRow(heading, 1);
        block.Children.Add(heading);
        var line = new TextBlock { Text = detail, VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 6, 0, 0), TextWrapping = TextWrapping.WrapWholeWords, TextAlignment = TextAlignment.Center,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush") };
        Grid.SetRow(line, 2);
        block.Children.Add(line);
        AutomationProperties.SetAutomationId(block, "pane.placeholder");
        AutomationProperties.SetName(block, $"{title}. {detail}");
        return block;
    }
}
