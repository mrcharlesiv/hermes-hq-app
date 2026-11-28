using Hermes.Core.Chat;
using HermesHQ.Services;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using VirtualKey = Windows.System.VirtualKey;

namespace HermesHQ.Features.Composer;

/// Inline verification-code banner shown above the chat composer when an agent's latest message asks for an email,
/// SMS, or authenticator one-time code (Mac: App/Chat/VerificationCodeBanner.swift). Compact elevated pill with a
/// numeric-pin code field, clipboard paste helper, one-tap Send, and Dismiss.
public sealed class VerificationCodeBanner : UserControl
{
    public const string Identifier = "composer.verificationCode";

    private readonly TextBox _codeBox;
    private readonly Button _sendButton;

    /// The assistant message this banner is currently answering (kept so refreshes don't disturb focus or typed input).
    public string? MessageId { get; private set; }

    /// Raised with the trimmed code when the user taps Send or presses Enter.
    public event Action<string>? SendRequested;

    /// Raised when the user dismisses the banner.
    public event Action? DismissRequested;

    public VerificationCodeBanner()
    {
        Visibility = Visibility.Collapsed;
        AutomationProperties.SetAutomationId(this, Identifier);
        AutomationProperties.SetName(this, "Verification code");

        var icon = new FontIcon
        {
            Glyph = "\uE8D7", // Key / Permissions
            FontSize = 14,
            Foreground = Ui.Res<Brush>("AccentTextFillColorPrimaryBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        };

        var pinScope = new InputScope();
        pinScope.Names.Add(new InputScopeName(InputScopeNameValue.NumericPin));
        _codeBox = new TextBox
        {
            PlaceholderText = "Verification code",
            AcceptsReturn = false,
            TextWrapping = TextWrapping.NoWrap,
            IsSpellCheckEnabled = false,
            IsTextPredictionEnabled = false,
            InputScope = pinScope,
            BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            MinHeight = 36,
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetName(_codeBox, "Verification code");
        AutomationProperties.SetAutomationId(_codeBox, $"{Identifier}.field");
        _codeBox.TextChanged += (_, _) => UpdateSendState();
        _codeBox.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Enter)
            {
                e.Handled = true;
                Submit();
            }
            else if (e.Key == VirtualKey.Escape)
            {
                e.Handled = true;
                Dismiss();
            }
        };

        var pasteButton = new Button
        {
            Content = new FontIcon { Glyph = "\uE77F", FontSize = 13 }, // Paste
            Style = Ui.Res<Style>("QuietButtonStyle"),
            MinWidth = 36,
            MinHeight = 36,
            Padding = new Thickness(6),
            VerticalAlignment = VerticalAlignment.Center,
        };
        ToolTipService.SetToolTip(pasteButton, "Paste code");
        AutomationProperties.SetName(pasteButton, "Paste verification code");
        AutomationProperties.SetAutomationId(pasteButton, $"{Identifier}.paste");
        pasteButton.Click += (_, _) => _ = PasteFromClipboardAsync();

        _sendButton = new Button
        {
            Content = "Send",
            IsEnabled = false,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Foreground = Ui.Res<Brush>("AccentTextFillColorPrimaryBrush"),
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            Padding = new Thickness(10, 6, 10, 6),
            MinHeight = 36,
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetName(_sendButton, "Send Verification Code");
        AutomationProperties.SetAutomationId(_sendButton, $"{Identifier}.send");
        _sendButton.Click += (_, _) => Submit();

        var dismissButton = new Button
        {
            Content = new FontIcon { Glyph = "\uE711", FontSize = 12 }, // ChromeClose
            Style = Ui.Res<Style>("QuietButtonStyle"),
            MinWidth = 36,
            MinHeight = 36,
            Padding = new Thickness(6),
            VerticalAlignment = VerticalAlignment.Center,
        };
        ToolTipService.SetToolTip(dismissButton, "Dismiss Verification Code");
        AutomationProperties.SetName(dismissButton, "Dismiss Verification Code");
        AutomationProperties.SetAutomationId(dismissButton, $"{Identifier}.dismiss");
        dismissButton.Click += (_, _) => Dismiss();

        var row = new Grid { ColumnSpacing = 4 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(icon);
        Grid.SetColumn(_codeBox, 1);
        row.Children.Add(_codeBox);
        Grid.SetColumn(pasteButton, 2);
        row.Children.Add(pasteButton);
        Grid.SetColumn(_sendButton, 3);
        row.Children.Add(_sendButton);
        Grid.SetColumn(dismissButton, 4);
        row.Children.Add(dismissButton);

        var pill = new Border
        {
            Child = row,
            CornerRadius = new CornerRadius(22),
            Padding = new Thickness(14, 4, 6, 4),
            MinHeight = 44,
            Background = Ui.Res<Brush>("CardBackgroundFillColorDefaultBrush"),
            BorderBrush = Ui.Res<Brush>("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1),
        };
        pill.Resources["TextControlBorderThemeThicknessFocused"] = new Thickness(0);
        pill.Resources["TextControlBackgroundPointerOver"] = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        pill.Resources["TextControlBackgroundFocused"] = new SolidColorBrush(Microsoft.UI.Colors.Transparent);

        Content = pill;
    }

    public string? TrimmedCode
    {
        get
        {
            var cleaned = VerificationCodePrompt.Normalize(_codeBox.Text);
            return cleaned.Length == 0 ? null : cleaned;
        }
    }

    public bool IsSendEnabled => _sendButton.IsEnabled;

    /// Shows the banner for `messageId`. Calling Show again with the same `messageId` preserves focus and typed text.
    public void Show(string messageId)
    {
        if (MessageId == messageId && Visibility == Visibility.Visible) return;
        if (MessageId != messageId)
        {
            MessageId = messageId;
            _codeBox.Text = "";
            UpdateSendState();
        }
        Visibility = Visibility.Visible;
    }

    /// Hides the banner and clears any typed code.
    public void Hide()
    {
        MessageId = null;
        _codeBox.Text = "";
        UpdateSendState();
        Visibility = Visibility.Collapsed;
    }

    public void FocusCodeField() => _codeBox.Focus(FocusState.Programmatic);

    public void Submit()
    {
        if (TrimmedCode is not { } code) return;
        _codeBox.Text = "";
        UpdateSendState();
        SendRequested?.Invoke(code);
    }

    private void Dismiss()
    {
        _codeBox.Text = "";
        UpdateSendState();
        Visibility = Visibility.Collapsed;
        DismissRequested?.Invoke();
        MessageId = null;
    }

    private void UpdateSendState() => _sendButton.IsEnabled = TrimmedCode != null;

    private async Task PasteFromClipboardAsync()
    {
        var content = SafeClipboard.TryGetContent();
        if (content == null || !content.Contains(StandardDataFormats.Text)) return;
        string raw;
        try { raw = await content.GetTextAsync(); }
        catch (Exception) { return; }
        var cleaned = VerificationCodePrompt.Normalize(raw);
        if (cleaned.Length == 0) return;
        _codeBox.Text = cleaned;
        _codeBox.SelectionStart = cleaned.Length;
        UpdateSendState();
        _codeBox.Focus(FocusState.Programmatic);
    }
}
