using Hermes.Core.Screen;
using HermesHQ.Features.Capabilities;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Screen;

/// [WIN-SCREEN-PAGE] The bar under the picture (App/Screen/ScreenControlBar.swift at 93f984bb1, §5.5, §5.6): who is in
/// control (an orange badge and orange words for "You were in control"), Take Control / Resume Control, Give Back, End
/// Their Control, Fit, the keyboard button and, while typing, Esc Tab ← ↑ ↓ →, then Ctrl (⌥ ⌘ on a Mac) and Paste. Keys
/// first, then modifiers and Paste, then the caption and buttons; the caption sits above the buttons when the bar is
/// narrower than 520 and two buttons show. Same words and identifiers as the Swift.
internal sealed class ScreenControlBar : StackPanel
{
    public Action? OnTake, OnGive, OnForce, OnFit, OnKeyboard, OnPaste;
    public Action<ScreenKeys.Named>? OnKey;
    public Action<ScreenKeys.Modifier>? OnModifier;

    private readonly Grid _controlRow = new() { ColumnSpacing = 10 };
    private readonly StackPanel _who = new() { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel _buttons = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
    private readonly TextBlock _caption = new() { TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center, FontSize = 13 };
    private readonly FontIcon _badge = new() { Glyph = "\uE814", FontSize = 13, Visibility = Visibility.Collapsed };
    private readonly ScrollViewer _keysScroll = KeysScroll("screen.keys");
    private readonly StackPanel _keysRow = new() { Orientation = Orientation.Horizontal, Spacing = 6 };
    private readonly ScrollViewer _modsScroll = KeysScroll("screen.mods");
    private readonly StackPanel _modsRow = new() { Orientation = Orientation.Horizontal, Spacing = 6 };
    private readonly Button _take, _give, _force, _fit, _keyboard, _paste;
    private readonly List<Button> _specials = [];
    private readonly Dictionary<ScreenKeys.Modifier, ToggleButton> _mods = [];
    private ScreenBarModel _model = new();

    private static readonly Brush Orange = new SolidColorBrush(Windows.UI.Color.FromArgb(0xFF, 0xF7, 0x63, 0x0C));

    public ScreenControlBar()
    {
        Spacing = 8;
        Padding = new Thickness(16, 8, 16, 8);
        AutomationProperties.SetAutomationId(this, "screen.bar");
        AutomationProperties.SetAutomationId(_caption, "screen.caption");
        _badge.Foreground = Orange;
        _who.Children.Add(_badge);
        _who.Children.Add(_caption);
        _take = Action(ControlWords.Take, "screen.take", prominent: true, () => OnTake?.Invoke());
        _give = Action(ControlWords.Give, "screen.give", prominent: false, () => OnGive?.Invoke());
        _force = Action(ControlWords.EndOther, "screen.force", prominent: false, () => OnForce?.Invoke());
        _fit = Key("Fit", "Fit screen", "screen.fit", () => OnFit?.Invoke());
        _keyboard = Key("\uE765", ControlWords.ShowKeyboard, "screen.keyboard.toggle", () => OnKeyboard?.Invoke(), glyph: true);
        _paste = Key("Paste", "Paste", "screen.paste", () => OnPaste?.Invoke());
        _buttons.Children.Add(_give);
        _buttons.Children.Add(_force);
        _buttons.Children.Add(_take);
        _controlRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _controlRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _controlRow.Children.Add(_who);
        _controlRow.Children.Add(_buttons);

        (string Face, string Spoken, ScreenKeys.Named Which, string Id)[] named =
        [
            ("Esc", "Escape", ScreenKeys.Named.Escape, "screen.key.esc"), ("Tab", "Tab", ScreenKeys.Named.Tab, "screen.key.tab"),
            ("←", "Left arrow", ScreenKeys.Named.Left, "screen.key.left"), ("↑", "Up arrow", ScreenKeys.Named.Up, "screen.key.up"),
            ("↓", "Down arrow", ScreenKeys.Named.Down, "screen.key.down"), ("→", "Right arrow", ScreenKeys.Named.Right, "screen.key.right"),
        ];
        foreach (var (face, spoken, which, id) in named) _specials.Add(Key(face, spoken, id, () => OnKey?.Invoke(which)));
        (string Face, string Spoken, ScreenKeys.Modifier Which, string Id)[] modifiers =
        [
            ("Ctrl", "Control", ScreenKeys.Modifier.Ctrl, "screen.mod.ctrl"), ("⌥", "Option", ScreenKeys.Modifier.Alt, "screen.mod.alt"),
            ("⌘", "Command", ScreenKeys.Modifier.Meta, "screen.mod.meta"),
        ];
        foreach (var (face, spoken, which, id) in modifiers)
        {
            var toggle = new ToggleButton { Content = face, MinWidth = 44, MinHeight = 44, Padding = new Thickness(10, 6, 10, 6) };
            AutomationProperties.SetName(toggle, spoken);
            AutomationProperties.SetAutomationId(toggle, id);
            toggle.Click += (_, _) => OnModifier?.Invoke(which);
            _mods[which] = toggle;
        }
        _keysScroll.Content = _keysRow;
        _modsScroll.Content = _modsRow;
        Children.Add(_keysScroll);
        Children.Add(_modsScroll);
        Children.Add(_controlRow);
        SizeChanged += (_, _) => Apply();
        Apply();
    }

    private static ScrollViewer KeysScroll(string id)
    {
        var scroll = new ScrollViewer
        {
            HorizontalScrollMode = ScrollMode.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        AutomationProperties.SetAutomationId(scroll, id);
        return scroll;
    }

    private static Button Action(string title, string id, bool prominent, Action run)
    {
        var button = new Button { Content = title, MinWidth = 120, MinHeight = 44 };
        if (prominent) button.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        AutomationProperties.SetAutomationId(button, id);
        button.Click += (_, _) => run();
        return button;
    }

    private static Button Key(string face, string spoken, string id, Action run, bool glyph = false)
    {
        var button = new Button
        {
            Content = glyph ? new FontIcon { Glyph = face, FontSize = 16 } : face, MinWidth = 44, MinHeight = 44, Padding = new Thickness(10, 6, 10, 6),
        };
        AutomationProperties.SetName(button, spoken);
        AutomationProperties.SetAutomationId(button, id);
        ToolTipService.SetToolTip(button, spoken);
        button.Click += (_, _) => run();
        return button;
    }

    public ScreenBarModel Model
    {
        get => _model;
        set
        {
            if (Same(value, _model)) return;
            _model = value;
            Apply();
        }
    }

    private static bool Same(ScreenBarModel a, ScreenBarModel b) =>
        a with { Armed = b.Armed } == b && a.Armed.SetEquals(b.Armed);

    private void Apply()
    {
        var m = _model;
        _caption.Text = m.Caption;
        _caption.Foreground = m.Held ? Orange : Kit.Primary;
        _badge.Visibility = m.Held ? Visibility.Visible : Visibility.Collapsed;
        AutomationProperties.SetName(_badge, m.Held ? "Held" : "");
        var busy = m.Busy;
        Configure(_take, m.Take ?? ControlWords.Take, m.Take != null, busy == ScreenSession.Busy.Take, m.TakeEnabled && busy == null);
        Configure(_give, ControlWords.Give, m.Give, busy == ScreenSession.Busy.Give, busy == null);
        Configure(_force, ControlWords.EndOther, m.Force, busy == ScreenSession.Busy.Force, busy == null);

        // Narrow with two buttons: the caption above full-width buttons (they would squeeze it into a column of letters).
        var shown = new[] { m.Take != null, m.Give, m.Force }.Count(b => b);
        var stacked = ActualWidth > 0 && ActualWidth < 520 && shown > 1;
        if (stacked)
        {
            Grid.SetRow(_buttons, 1); Grid.SetColumn(_buttons, 0); Grid.SetColumnSpan(_buttons, 2);
            if (_controlRow.RowDefinitions.Count == 0)
            {
                _controlRow.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                _controlRow.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            }
            _controlRow.RowSpacing = 8;
            _caption.TextWrapping = TextWrapping.Wrap;
            _buttons.HorizontalAlignment = HorizontalAlignment.Stretch;
        }
        else
        {
            Grid.SetRow(_buttons, 0); Grid.SetColumn(_buttons, 1); Grid.SetColumnSpan(_buttons, 1);
            _caption.TextWrapping = TextWrapping.NoWrap;
            _buttons.HorizontalAlignment = HorizontalAlignment.Right;
        }

        ((FontIcon)_keyboard.Content).Glyph = m.Typing ? "\uE96A" : "\uE765";
        var keyboardName = m.Typing ? ControlWords.HideKeyboard : ControlWords.ShowKeyboard;
        AutomationProperties.SetName(_keyboard, keyboardName);
        ToolTipService.SetToolTip(_keyboard, keyboardName);
        foreach (var (which, toggle) in _mods) toggle.IsChecked = m.Armed.Contains(which);

        var first = new List<UIElement>();
        if (m.Keyboard) first.Add(_keyboard);
        if (m.Fit) first.Add(_fit);
        var second = new List<UIElement>();
        if (m.Typing && m.Keyboard)
        {
            first.AddRange(_specials);
            second.Add(_mods[ScreenKeys.Modifier.Ctrl]);
            if (m.Mac) { second.Add(_mods[ScreenKeys.Modifier.Alt]); second.Add(_mods[ScreenKeys.Modifier.Meta]); }
            second.Add(_paste);
        }
        SetRow(_keysRow, first);
        SetRow(_modsRow, second);
        _keysScroll.Visibility = first.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        _modsScroll.Visibility = second.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private static void SetRow(StackPanel row, List<UIElement> views)
    {
        if (row.Children.SequenceEqual(views)) return;
        row.Children.Clear();
        foreach (var view in views) row.Children.Add(view);
    }

    private static void Configure(Button button, string title, bool shown, bool spinning, bool enabled)
    {
        button.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
        if (spinning)
        {
            button.Content = new StackPanel
            {
                Orientation = Orientation.Horizontal, Spacing = 6,
                Children = { new ProgressRing { IsActive = true, Width = 14, Height = 14 }, new TextBlock { Text = title } },
            };
        }
        else if (button.Content as string != title) button.Content = title;
        AutomationProperties.SetName(button, title);
        button.IsEnabled = enabled;
    }
}

/// [WIN-SCREEN-PAGE] The lines under the title bar (ScreenNotesView, §5.9): the error line in red with Dismiss, the
/// held / other / Mac lines (a warning gets an orange triangle), and the Enable Screen Control row. Never more than its
/// cap of the page: the lines scroll.
internal sealed class ScreenNotesView : Grid
{
    public Action? OnDismissError, OnEnableControl;
    private readonly StackPanel _stack = new() { Padding = new Thickness(16, 0, 16, 0) };
    private ScreenNotesModel _model = new();
    private static readonly Brush Orange = new SolidColorBrush(Windows.UI.Color.FromArgb(0xFF, 0xF7, 0x63, 0x0C));

    public ScreenNotesView()
    {
        Children.Add(new ScrollViewer { Content = _stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        AutomationProperties.SetAutomationId(this, "screen.notes");
        Visibility = Visibility.Collapsed;
    }

    /// The Swift's `Equatable` model: a render with the same notes changes nothing (and says nothing again).
    public void Set(ScreenNotesModel model, Action<string> announce)
    {
        if (model.Error == _model.Error && model.EnableControl == _model.EnableControl && model.Lines.SequenceEqual(_model.Lines)) return;
        var newError = model.Error != _model.Error;
        _model = model;
        _stack.Children.Clear();
        if (model.Error is { Length: > 0 } error)
        {
            var dismiss = new HyperlinkButton { Content = "Dismiss", MinHeight = 44, VerticalAlignment = VerticalAlignment.Center };
            AutomationProperties.SetAutomationId(dismiss, "screen.error.dismiss");
            dismiss.Click += (_, _) => OnDismissError?.Invoke();
            _stack.Children.Add(Row(error, Kit.Critical, warning: false, "screen.error", dismiss));
            if (newError) announce(error);
        }
        foreach (var line in model.Lines) _stack.Children.Add(Row(line.Text, Kit.Secondary, line.Warning, line.Id, null));
        if (model.EnableControl)
        {
            var button = new HyperlinkButton
            {
                Content = new StackPanel
                {
                    Orientation = Orientation.Horizontal, Spacing = 6,
                    Children = { new TextBlock { Text = "Enable Screen Control", FontSize = 12 }, new FontIcon { Glyph = "\uE76C", FontSize = 10 } },
                },
                Padding = new Thickness(0, 12, 0, 12),
            };
            AutomationProperties.SetName(button, "Enable Screen Control");
            AutomationProperties.SetAutomationId(button, "screen.enable-control");
            button.Click += (_, _) => OnEnableControl?.Invoke();
            _stack.Children.Add(button);
        }
        Visibility = _stack.Children.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private static UIElement Row(string text, Brush colour, bool warning, string id, UIElement? trailing)
    {
        var row = new Grid { ColumnSpacing = 8, Padding = new Thickness(0, 12, 0, 12) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (warning) row.Children.Add(new FontIcon { Glyph = "\uE7BA", FontSize = 12, Foreground = Orange, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0) });
        var label = new TextBlock { Text = text, FontSize = 12, Foreground = colour, TextWrapping = TextWrapping.Wrap };
        AutomationProperties.SetAutomationId(label, id);
        Grid.SetColumn(label, 1);
        row.Children.Add(label);
        if (trailing != null) { Grid.SetColumn((FrameworkElement)trailing, 2); row.Children.Add(trailing); }
        return row;
    }
}
