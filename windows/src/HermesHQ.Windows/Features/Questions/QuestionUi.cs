using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Questions;

/// The cards' shared shell and pieces (App/Questions/PromptRows.swift: every card of this kind looks the same — a
/// reply bubble's fill, a header of a round mark and a semibold title, then the content).
internal static class QuestionUi
{
    public static T Res<T>(string key) => ThemeBrushes.Res<T>(key);

    public static Brush Brush(string key) => Res<Brush>(key);

    /// The card: a reply bubble's fill, radius 14, padding 12 / 14, 16 from the sides.
    public static Border Card(UIElement child) => new()
    {
        Child = child,
        CornerRadius = new CornerRadius(14),
        Padding = new Thickness(14, 12, 14, 12),
        Margin = new Thickness(16, 6, 16, 6),
        Background = Brush("HQPromptCardBrush"),
        BorderBrush = Brush("HQPromptEdgeBrush"),
        BorderThickness = new Thickness(1),
    };

    /// A round mark (accent, or grey when dim) with a Segoe Fluent glyph, and the title beside it.
    public static StackPanel Header(string title, string glyph, bool dim = false)
    {
        var mark = new Border
        {
            Width = 26, Height = 26, CornerRadius = new CornerRadius(13),
            Background = Brush(dim ? "ControlStrongFillColorDisabledBrush" : "AccentFillColorDefaultBrush"),
            Child = new FontIcon
            {
                Glyph = glyph, FontSize = 13, Foreground = Brush("TextOnAccentFillColorPrimaryBrush"),
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            },
        };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        row.Children.Add(mark);
        row.Children.Add(new TextBlock
        {
            Text = title, FontWeight = FontWeights.SemiBold, FontSize = 14, VerticalAlignment = VerticalAlignment.Center,
            TextWrapping = TextWrapping.Wrap,
        });
        return row;
    }

    public static TextBlock Text(string text, double size = 14, string brush = "TextFillColorPrimaryBrush", bool semibold = false) => new()
    {
        Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap, Foreground = Brush(brush),
        FontWeight = semibold ? FontWeights.SemiBold : FontWeights.Normal,
    };

    /// A capsule button (the Mac's card buttons): accent for the primary, plain for the rest.
    public static Button Capsule(string title, bool accent = false, bool plain = false)
    {
        var b = new Button
        {
            Content = title, CornerRadius = new CornerRadius(16), Padding = new Thickness(14, 6, 14, 6), MinHeight = 32,
            FontWeight = FontWeights.SemiBold,
        };
        if (accent) b.Style = Res<Style>("AccentButtonStyle");
        else if (plain)
        {
            b.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
            b.BorderThickness = new Thickness(0);
            b.Foreground = Brush("TextFillColorSecondaryBrush");
        }
        return b;
    }

    /// A small spinner in place of a tapped button's label (every button is disabled while an answer is on its way).
    public static ProgressRing Spinner() => new() { IsActive = true, Width = 16, Height = 16 };

    public static FontFamily Mono => Res<FontFamily>("CodeFont");
}

/// Dialogs over the chat. WinUI shows one ContentDialog at a time per window: a second ShowAsync while one is up
/// throws, so this waits its turn instead (the Mac presents one sheet or alert at a time too).
internal static class Dialogs
{
    private static ContentDialog? _open;

    public static bool Busy => _open != null;

    public static async Task<ContentDialogResult> ShowAsync(ContentDialog dialog, XamlRoot? root)
    {
        if (root == null || _open != null) return ContentDialogResult.None;
        dialog.XamlRoot = root;
        _open = dialog;
        try { return await dialog.ShowAsync(); }
        catch (Exception) { return ContentDialogResult.None; }
        finally { if (_open == dialog) _open = null; }
    }

    public static void Hide(ContentDialog dialog)
    {
        if (_open == dialog) dialog.Hide();
    }

    /// A two-button confirm ("Always Allow This Command?", "Skip All Questions?"); true when the primary was chosen.
    public static async Task<bool> ConfirmAsync(XamlRoot? root, string title, string message, string primary, string cancel = "Cancel")
    {
        var dialog = new ContentDialog
        {
            Title = title,
            Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true },
            PrimaryButtonText = primary,
            CloseButtonText = cancel,
            DefaultButton = ContentDialogButton.Close,
        };
        return await ShowAsync(dialog, root) == ContentDialogResult.Primary;
    }
}
