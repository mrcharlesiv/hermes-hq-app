using Hermes.Core.Screen;
using HermesHQ.Features.Capabilities;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Screen;

/// [WIN-SCREEN-PAGE] "Set Up Viewing and Control" / "Enable Screen Control" (App/Screen/ScreenSetupCard.swift at
/// 93f984bb1, §5.13): the Windows-gateway sentence alone, or the heading, the three points (the last a warning), Set Up
/// with Hermes and Check Setup, the update line, the result and the error. Words are ScreenSetupCopy's; the state and
/// what each state shows are Hermes.Core's ScreenSetupCardState ([WIN-SCREEN-SETUP-SEND]: shared with the control-only
/// sheet, ScreenSetupSheet.cs).
internal sealed class ScreenSetupCard : Grid
{
    public ScreenSetupCardState State { get; }
    public Func<Task<ScreenSetupError?>>? OnSetup { get => State.OnSetup; set => State.OnSetup = value; }
    public Func<Task<string>>? OnCheck { get => State.OnCheck; set => State.OnCheck = value; }
    public Action<string>? Announce { get => State.Announce; set => State.Announce = value; }

    private readonly TextBlock _heading = Words(15, "screen.setup.heading", bold: true);
    private readonly TextBlock _update = Words(13, "screen.setup.update");
    private readonly TextBlock _message = Words(13, "screen.setup.message");
    private readonly TextBlock _error = Words(13, "screen.setup.error");
    private readonly TextBlock _windowsNote = Words(13, "screen.setup.windows");
    private readonly StackPanel _points = new() { Spacing = 12, Margin = new Thickness(0, 4, 0, 12) };
    private readonly StackPanel _buttonsBox = new() { Spacing = 10, Margin = new Thickness(0, 8, 0, 8) };
    private readonly Button _primary = new() { MinHeight = 48, HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly Button _second = new() { MinHeight = 48, HorizontalAlignment = HorizontalAlignment.Stretch };

    private static readonly Brush Orange = new SolidColorBrush(Windows.UI.Color.FromArgb(0xFF, 0xF7, 0x63, 0x0C));

    /// [WIN-SCREEN-SETUP-LAYOUT] How far down the card its buttons end (the screenshots page keeps them in view); a card
    /// without buttons (a Windows gateway's sentence): its whole height.
    public double ButtonsBottom
    {
        get
        {
            if (_buttonsBox.Visibility != Visibility.Visible || _buttonsBox.ActualHeight <= 0 || _buttonsBox.XamlRoot == null) return ActualHeight;
            var top = _buttonsBox.TransformToVisual(this).TransformPoint(new global::Windows.Foundation.Point(0, 0)).Y;
            return top + _buttonsBox.ActualHeight;
        }
    }

    public ScreenSetupCard(bool controlOnly) : this(new ScreenSetupCardState(controlOnly)) { }

    public ScreenSetupCard(ScreenSetupCardState state)
    {
        State = state;
        CornerRadius = new CornerRadius(22);
        Background = Kit.Brush("HQPromptCardBrush");
        BorderBrush = Kit.Brush("HQPromptEdgeBrush");
        BorderThickness = new Thickness(1);
        Padding = new Thickness(16, 4, 16, 8);
        AutomationProperties.SetAutomationId(this, state.Look.AutomationId);
        _update.Text = ScreenSetupCopy.Update;
        _windowsNote.Text = ScreenSetupCopy.Windows;
        _update.Foreground = _windowsNote.Foreground = Kit.Secondary;
        _error.Foreground = Kit.Critical;
        AutomationProperties.SetHeadingLevel(_heading, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
        _primary.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        AutomationProperties.SetAutomationId(_primary, "screen.setup.primary");
        AutomationProperties.SetAutomationId(_second, "screen.setup.check");
        _primary.Click += (_, _) => _ = State.SetupAsync();
        _second.Click += (_, _) => _ = State.CheckAsync();
        _buttonsBox.Children.Add(_primary);
        _buttonsBox.Children.Add(_second);
        var index = 0;
        foreach (var point in ScreenSetupCopy.Points)
        {
            var mark = new FontIcon
            {
                Glyph = point.Symbol switch { "arrow.down.circle" => "\uE896", "checkmark.circle" => "\uE73E", _ => "\uE7BA" },
                FontSize = 14, Width = 22, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0),
                Foreground = point.Warning ? Orange : Kit.Accent,
            };
            AutomationProperties.SetAccessibilityView(mark, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
            var words = Words(13, $"screen.setup.point.{index++}");
            words.Inlines.Add(new Run { Text = point.Lead, FontWeight = Microsoft.UI.Text.FontWeights.Bold, Foreground = Kit.Primary });
            words.Inlines.Add(new Run { Text = point.Rest, Foreground = Kit.Secondary });
            var row = new Grid { ColumnSpacing = 10 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.Children.Add(mark);
            Grid.SetColumn(words, 1);
            row.Children.Add(words);
            _points.Children.Add(row);
        }
        var stack = new StackPanel();
        foreach (var view in new UIElement[] { Padded(_windowsNote), Padded(_heading), _points, _buttonsBox, Padded(_update), Padded(_message), Padded(_error) })
            stack.Children.Add(view);
        Children.Add(stack);
        State.Changed += Apply;
        Apply();
    }

    private static TextBlock Words(double size, string id, bool bold = false)
    {
        var text = new TextBlock { FontSize = size, TextWrapping = TextWrapping.Wrap };
        if (bold) text.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        AutomationProperties.SetAutomationId(text, id);
        return text;
    }

    // CI run 45120146387: a Border's Child had no Parent yet on the runner (WinUI sets it only when the tree is entered),
    // so Show's ((Border)label.Parent) threw NullReferenceException while the card was built. Each wrapper is kept instead.
    private readonly Dictionary<TextBlock, Border> _wrappers = new();
    private Border Padded(TextBlock label)
    {
        var border = new Border { Padding = new Thickness(0, 12, 0, 12), Child = label };
        _wrappers[label] = border;
        return border;
    }
    private void Show(TextBlock label, bool on) => _wrappers[label].Visibility = on ? Visibility.Visible : Visibility.Collapsed;

    public bool Requested { get => State.Requested; set => State.Requested = value; }
    public bool NeedsUpdate { get => State.NeedsUpdate; set => State.NeedsUpdate = value; }
    public bool WindowsGateway { get => State.WindowsGateway; set => State.WindowsGateway = value; }

    private void Apply()
    {
        var look = State.Look;
        _heading.Text = look.Heading;
        _message.Text = look.Message;
        _error.Text = look.Error;
        Show(_windowsNote, look.WindowsNoteShown);
        Show(_heading, look.HeadingShown);
        _points.Visibility = look.PointsShown ? Visibility.Visible : Visibility.Collapsed;
        _buttonsBox.Visibility = look.ButtonsShown ? Visibility.Visible : Visibility.Collapsed;
        Show(_update, look.UpdateShown);
        Show(_message, look.MessageShown);
        Show(_error, look.ErrorShown);
        _primary.Content = look.Primary;
        _second.Content = look.Check;
        _primary.IsEnabled = _second.IsEnabled = look.Enabled;
    }

    public void ShowRequested() => State.ShowRequested();
}
