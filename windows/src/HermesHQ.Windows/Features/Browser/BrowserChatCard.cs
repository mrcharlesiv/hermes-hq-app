// The chat's compact browser shelf chip (C# twin of App/Browser/BrowserChatCard.swift):
// appears above the message box only while this chat is driving its bot's browser (or during the same running turn),
// tinted orange when the bot is waiting on the user, and opens Watch Browser when clicked.

using Hermes.Core.Browser;
using Hermes.Core.Chat;
using HermesHQ.Features.Capabilities;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace HermesHQ.Features.Browser;

public sealed class BrowserChatCard : UserControl, IDisposable
{
    private static readonly SolidColorBrush AskBackground = new(Color.FromArgb(0x22, 0xF7, 0x63, 0x0C));
    private static readonly SolidColorBrush AskBorder = new(Color.FromArgb(0x70, 0xF7, 0x63, 0x0C));
    private static readonly SolidColorBrush AskAccent = new(Color.FromArgb(0xFF, 0xF7, 0x63, 0x0C));

    private readonly ChatSession _session;
    private readonly BrowserChatCardModel _model;
    private readonly DispatcherQueue _ui;
    private readonly Border _frame;
    private readonly Button _button;
    private readonly FontIcon _icon;
    private readonly TextBlock _label;
    private bool _disposed;

    public Action<BrowserScope>? OnOpen { get; set; }

    public BrowserChatCard(ChatSession session, BrowserService service, Func<BrowserScope> scope)
    {
        _session = session;
        _ui = DispatcherQueue.GetForCurrentThread();
        _model = new BrowserChatCardModel(service, scope, () => session.Busy);

        Margin = new Thickness(0, 0, 0, 4);
        Visibility = Visibility.Collapsed;
        AutomationProperties.SetAutomationId(this, "browser.chatCard");

        _icon = new FontIcon
        {
            Glyph = "\uE774",
            FontSize = 15,
            VerticalAlignment = VerticalAlignment.Center,
        };
        _label = new TextBlock
        {
            FontSize = 13,
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 2,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var chevron = new FontIcon
        {
            Glyph = "\uE76C",
            FontSize = 11,
            Foreground = Kit.Tertiary,
            VerticalAlignment = VerticalAlignment.Center,
        };

        var row = new Grid { ColumnSpacing = 10 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(_icon);
        Grid.SetColumn(_label, 1);
        row.Children.Add(_label);
        Grid.SetColumn(chevron, 2);
        row.Children.Add(chevron);

        _button = new Button
        {
            Content = row,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(12, 8, 12, 8),
            CornerRadius = new CornerRadius(11),
        };
        _button.Click += (_, _) => OnOpen?.Invoke(_model.CurrentScope());
        _frame = new Border
        {
            CornerRadius = new CornerRadius(12),
            BorderThickness = new Thickness(1),
            Child = _button,
        };
        Content = _frame;

        _model.Changed += OnModelChanged;
        _session.RunningChanged += OnSessionRunningChanged;
        _session.RuntimeBound += OnSessionRuntimeBound;
        _session.StoredIdResolved += OnSessionStoredIdResolved;

        Loaded += (_, _) => { if (!_disposed) _model.SetVisible(true); };
        Unloaded += (_, _) => _model.SetVisible(false);
    }

    private void OnSessionRunningChanged(bool _)
    {
        if (_disposed || Services.AppShutdown.Stopping) return;
        _ui.TryEnqueue(() => { if (!_disposed && !Services.AppShutdown.Stopping) _model.Update(); });
    }
    private void OnSessionRuntimeBound(string _)
    {
        if (_disposed || Services.AppShutdown.Stopping) return;
        _ui.TryEnqueue(() => { if (!_disposed && !Services.AppShutdown.Stopping) _model.Update(); });
    }
    private void OnSessionStoredIdResolved(string _, string __)
    {
        if (_disposed || Services.AppShutdown.Stopping) return;
        _ui.TryEnqueue(() => { if (!_disposed && !Services.AppShutdown.Stopping) _model.Update(); });
    }

    private void OnModelChanged(BrowserChatChip? chip)
    {
        if (_disposed || Services.AppShutdown.Stopping) return;
        _ui.TryEnqueue(() => Apply(chip));
    }

    private void Apply(BrowserChatChip? chip)
    {
        if (_disposed || Services.AppShutdown.Stopping) return;
        if (chip == null)
        {
            Visibility = Visibility.Collapsed;
            return;
        }
        Visibility = Visibility.Visible;
        _label.Text = chip.Words;
        _label.FontWeight = chip.Asking ? FontWeights.SemiBold : FontWeights.Normal;
        AutomationProperties.SetName(_button, chip.Words);
        if (chip.Asking)
        {
            _frame.Background = AskBackground;
            _frame.BorderBrush = AskBorder;
            _icon.Foreground = AskAccent;
        }
        else
        {
            _frame.Background = Kit.Brush("HQPromptCardBrush");
            _frame.BorderBrush = Kit.Brush("HQPromptEdgeBrush");
            _icon.Foreground = Kit.Accent;
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _model.Changed -= OnModelChanged;
        _session.RunningChanged -= OnSessionRunningChanged;
        _session.RuntimeBound -= OnSessionRuntimeBound;
        _session.StoredIdResolved -= OnSessionStoredIdResolved;
        _model.Dispose();
    }
}
