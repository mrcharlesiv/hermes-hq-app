// Watch Browser's address bar (C# twin of App/Browser/BrowserAddressField.swift):
// shows the site's host centered with a lock icon when secure; clicking it in control switches to a left-aligned
// editable TextBox with the full URL selected so the user can type a URL or search query, press Enter to go, or
// press Escape to cancel.

using HermesHQ.Features.Capabilities;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace HermesHQ.Features.Browser;

internal sealed class BrowserAddressField : Grid
{
    private readonly Border _pill;
    private readonly Button _displayButton;
    private readonly FontIcon _lockIcon;
    private readonly TextBlock _siteText;
    private readonly TextBox _editBox;

    private bool _editing;
    private bool _committing;

    public Func<(bool Allowed, string FullUrl)>? OnTryBeginEdit { get; set; }
    public Action<string>? OnCommit { get; set; }
    public Action? OnCancel { get; set; }

    public bool IsEditing => _editing;

    public BrowserAddressField()
    {
        AutomationProperties.SetAutomationId(this, "browser.address");

        _lockIcon = new FontIcon
        {
            Glyph = "\uE72E",
            FontSize = 11,
            Foreground = Kit.Secondary,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };
        _siteText = new TextBlock
        {
            FontSize = 14,
            Foreground = Kit.Primary,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var displayRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        displayRow.Children.Add(_lockIcon);
        displayRow.Children.Add(_siteText);

        _displayButton = new Button
        {
            Content = displayRow,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Center,
            VerticalContentAlignment = VerticalAlignment.Center,
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(12, 6, 12, 6),
            MinHeight = 36,
        };
        AutomationProperties.SetName(_displayButton, "Address");
        AutomationProperties.SetAutomationId(_displayButton, "browser.address.display");
        _displayButton.Click += (_, _) => TryBeginEdit();

        _editBox = new TextBox
        {
            FontSize = 14,
            PlaceholderText = "Search or enter website",
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(12, 7, 12, 7),
            MinHeight = 36,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetName(_editBox, "Address");
        AutomationProperties.SetAutomationId(_editBox, "browser.address.input");
        _editBox.KeyDown += OnEditKeyDown;
        _editBox.LostFocus += OnEditLostFocus;

        var inner = new Grid();
        inner.Children.Add(_displayButton);
        inner.Children.Add(_editBox);

        _pill = new Border
        {
            CornerRadius = new CornerRadius(10),
            Background = Kit.Brush("ControlFillColorDefaultBrush"),
            BorderBrush = Kit.Brush("ControlStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1),
            MinHeight = 38,
            Child = inner,
        };
        Children.Add(_pill);
    }

    public void SetSite(string text, bool secure, bool editing)
    {
        _siteText.Text = text;
        _lockIcon.Visibility = secure && !editing && text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (!editing && _editing)
        {
            _editing = false;
            _editBox.Visibility = Visibility.Collapsed;
            _displayButton.Visibility = Visibility.Visible;
        }
    }

    public void FocusForEdit() => TryBeginEdit();

    private void TryBeginEdit()
    {
        if (_editing) return;
        if (OnTryBeginEdit is not { } ask) return;
        var (allowed, fullUrl) = ask();
        if (!allowed) return;
        _editing = true;
        _committing = false;
        _editBox.Text = fullUrl;
        _displayButton.Visibility = Visibility.Collapsed;
        _editBox.Visibility = Visibility.Visible;
        _editBox.Focus(FocusState.Programmatic);
        _editBox.SelectAll();
    }

    private void OnEditKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            e.Handled = true;
            _committing = true;
            var typed = _editBox.Text;
            _editing = false;
            _editBox.Visibility = Visibility.Collapsed;
            _displayButton.Visibility = Visibility.Visible;
            OnCommit?.Invoke(typed);
        }
        else if (e.Key == VirtualKey.Escape)
        {
            e.Handled = true;
            CancelEdit();
        }
    }

    private void OnEditLostFocus(object sender, RoutedEventArgs e)
    {
        if (_committing || !_editing) return;
        CancelEdit();
    }

    private void CancelEdit()
    {
        if (!_editing) return;
        _editing = false;
        _editBox.Visibility = Visibility.Collapsed;
        _displayButton.Visibility = Visibility.Visible;
        OnCancel?.Invoke();
    }
}
