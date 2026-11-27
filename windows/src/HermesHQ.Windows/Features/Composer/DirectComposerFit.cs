using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;
using Windows.Foundation;

namespace HermesHQ.Features.Composer;

/// ComposerView.shownPlaceholder and macChipWidth: keep the word before the optional shortcut.
/// The lane spans the editor and chip columns *after* the other controls have taken their room.
internal sealed class DirectComposerFit
{
    private const string Word = "Message";
    private readonly Grid _row;
    private readonly Canvas _lane;
    private readonly TextBox _editor;
    private readonly Button _chip;
    private readonly TextBlock _word, _full, _model;

    internal DirectComposerFit(Grid row, Canvas lane, TextBox editor, Button chip)
    {
        (_row, _lane, _editor, _chip) = (row, lane, editor, chip);
        _word = Metric(editor, Word);
        _full = Metric(editor, Word);
        _model = Metric(chip, "");
        foreach (var part in new FrameworkElement[] { row, lane, editor, _word, _full, _model })
            part.SizeChanged += (_, _) => Fit();
        row.Loaded += (_, _) => Fit();
    }

    // In the same XAML tree: changes to the actual font, language, DPI or accessibility text size
    // remeasure these even while the shortcut is hidden. Canvas asks for no space for its children.
    private TextBlock Metric(Control source, string text)
    {
        var probe = new TextBlock { Text = text, TextWrapping = TextWrapping.NoWrap, UseLayoutRounding = false };
        foreach (var (property, name) in new[] {
            (TextBlock.FontFamilyProperty, nameof(source.FontFamily)), (TextBlock.FontSizeProperty, nameof(source.FontSize)),
            (TextBlock.FontStyleProperty, nameof(source.FontStyle)), (TextBlock.FontWeightProperty, nameof(source.FontWeight)),
            (TextBlock.FontStretchProperty, nameof(source.FontStretch)), (TextBlock.CharacterSpacingProperty, nameof(source.CharacterSpacing)),
            (TextBlock.IsTextScaleFactorEnabledProperty, nameof(source.IsTextScaleFactorEnabled)),
            (FrameworkElement.LanguageProperty, nameof(source.Language)) })
            probe.SetBinding(property, new Binding { Source = source, Path = new PropertyPath(name) });
        AutomationProperties.SetAccessibilityView(probe, AccessibilityView.Raw);
        _lane.Children.Add(probe);
        return probe;
    }

    internal void SetTitle(string title)
    {
        _full.Text = string.IsNullOrWhiteSpace(title) || !OneLine(title) ? Word : $"{Word} {title}";
        Fit();
    }

    internal void SetModel(string? name)
    {
        var caption = string.IsNullOrWhiteSpace(name) || !OneLine(name) ? "" : name;
        if (_model.Text == caption) return;
        _model.Text = caption;
        _chip.Content = caption;
        Fit();
    }

    private static bool OneLine(string text) => text.AsSpan().IndexOfAny("\r\n\v\f\u0085\u2028\u2029") < 0;
    private static double Across(Thickness t) => t.Left + t.Right;
    private static double Insets(Control c) => Across(c.Padding) + Across(c.BorderThickness);

    private static double Width(TextBlock probe)
    {
        probe.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        return Math.Ceiling(probe.DesiredSize.Width);
    }

    private void Fit()
    {
        if (_row.ActualWidth <= 0) return;
        var lane = _lane.ActualWidth;
        var minimum = Width(_word) + Insets(_editor);
        var chip = Math.Max(_chip.MinWidth, Width(_model) + Insets(_chip));
        // As on Mac, cap the shortcut, don't truncate its name, and leave the word 4 units to spare.
        var show = _model.Text.Length != 0 && chip <= Math.Min(240, 0.4 * lane)
            && minimum + 4 + Across(_chip.Margin) + chip <= lane;
        var visibility = show ? Visibility.Visible : Visibility.Collapsed;
        if (_chip.Visibility != visibility) _chip.Visibility = visibility;

        // At large type even the chip-free inline slot may be too small. Give the *same* editor
        // the row above the buttons. The measuring lane stays inline, so expansion is reversible.
        var stacked = minimum > lane;
        if ((Grid.GetRow(_editor) == 0) != stacked)
        {
            Grid.SetRow(_editor, stacked ? 0 : 1);
            Grid.SetColumn(_editor, stacked ? 0 : 1);
            Grid.SetColumnSpan(_editor, stacked ? _row.ColumnDefinitions.Count : 1);
        }

        // The default TextBox placeholder spans both template columns, inset by border + padding.
        // SizeChanged runs again when the chip yields. Never replace the edit, its text or its wrapping.
        var hint = Width(_full) <= _editor.ActualWidth - Insets(_editor) ? _full.Text : Word;
        if (_editor.PlaceholderText != hint) _editor.PlaceholderText = hint;
    }
}
