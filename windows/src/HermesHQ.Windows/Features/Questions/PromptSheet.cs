using Hermes.Core.Questions;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using VirtualKey = Windows.System.VirtualKey;
using static HermesHQ.Features.Questions.QuestionUi;

namespace HermesHQ.Features.Questions;

/// A sudo / secret / vault sheet (spec 1x §4.5; Mac: App/Questions/PromptSheets.swift) as a dialog over the chat: the
/// title, the words, the command (sudo) or the key's name (secret), the fields, the primary verb, and the red decline
/// under the fields. Close tucks it: nothing is sent, the dialog is kept with its text, and the chip over the message
/// box brings it back. Typed values live only in these fields (Q15): never logged, cached or copied, and cleared when
/// the request goes.
internal sealed class PromptSheet
{
    private readonly List<Control> _fields = [];
    private readonly Button _decline;
    private bool _sending;

    public ValuePrompt Prompt { get; }
    public PromptSheetCopy Copy { get; }
    public ContentDialog Dialog { get; }
    /// Closed without an answer: the chip shows it.
    public bool Tucked { get; set; }
    public bool Showing { get; private set; }

    /// The primary or the decline ("") was chosen; the sheet is closing.
    public Action<PromptSheet, string>? OnAnswer;

    public PromptSheet(ValuePrompt prompt, string? botName)
    {
        Prompt = prompt;
        Copy = PromptSheetCopy.Make(prompt, botName);
        var stack = new StackPanel { Spacing = 10, MinWidth = 360 };
        if (Copy.Command is { } command)
        {
            stack.Children.Add(Text("Command", 12, "TextFillColorSecondaryBrush"));
            stack.Children.Add(new Border
            {
                Padding = new Thickness(12), CornerRadius = new CornerRadius(8), Background = Brush("SubtleFillColorSecondaryBrush"),
                Child = new TextBlock
                {
                    Text = command, FontFamily = Mono, FontSize = 12.5, TextWrapping = TextWrapping.Wrap, MaxLines = ApprovalCard.CommandClampLines,
                    TextTrimming = TextTrimming.CharacterEllipsis, IsTextSelectionEnabled = true,
                },
            });
        }
        else if (Copy.CommandMissing is { } missing) stack.Children.Add(Text(missing, 12, "TextFillColorSecondaryBrush"));
        stack.Children.Add(Text(Copy.Text, 14));
        if (Copy.Key is { } key)
        {
            var k = Text(key, 12.5, "TextFillColorSecondaryBrush");
            k.FontFamily = Mono;
            stack.Children.Add(k);
        }
        foreach (var f in Copy.Fields)
        {
            Control field = f.Kind is PromptFieldKind.Secure or PromptFieldKind.Password
                ? new PasswordBox { PlaceholderText = f.Placeholder, Header = f.Label }
                : new TextBox
                {
                    PlaceholderText = f.Placeholder, Header = f.Label, IsSpellCheckEnabled = false, IsTextPredictionEnabled = false,
                    InputScope = Scope(f.Kind == PromptFieldKind.Code ? InputScopeNameValue.NumericPin : InputScopeNameValue.EmailNameOrAddress),
                };
            if (field is PasswordBox pb) pb.PasswordChanged += (_, _) => Validate();
            if (field is TextBox tb) tb.TextChanged += (_, _) => Validate();
            field.KeyDown += FieldKeyDown;
            _fields.Add(field);
            stack.Children.Add(field);
        }
        _decline = new Button
        {
            Content = Copy.Decline, HorizontalAlignment = HorizontalAlignment.Center, MinHeight = 36,
            Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0),
            Foreground = Brush("SystemFillColorCriticalBrush"),
        };
        _decline.Click += (_, _) => Answer("");
        stack.Children.Add(_decline);

        Dialog = new ContentDialog
        {
            Title = Copy.Title, Content = stack, PrimaryButtonText = Copy.Primary, CloseButtonText = "Close",
            DefaultButton = ContentDialogButton.Primary, IsPrimaryButtonEnabled = false,
        };
        Dialog.PrimaryButtonClick += (_, e) =>
        {
            if (Value() is not { } v) { e.Cancel = true; return; }
            Answer(v, hide: false);
        };
        Dialog.Opened += (_, _) => _fields.FirstOrDefault()?.Focus(FocusState.Programmatic);
    }

    private static InputScope Scope(InputScopeNameValue name)
    {
        var scope = new InputScope();
        scope.Names.Add(new InputScopeName(name));
        return scope;
    }

    private IReadOnlyList<string> Values() =>
        _fields.Select(f => f switch { PasswordBox p => p.Password, TextBox t => t.Text, _ => "" }).ToList();

    private string? Value() => PromptSheetCopy.Answer(Prompt.Kind, Values());

    private void Validate() => Dialog.IsPrimaryButtonEnabled = !_sending && Value() != null;

    /// Enter moves to the next field; on the last it sends when the sheet is valid.
    private void FieldKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter) return;
        e.Handled = true;
        var i = _fields.IndexOf((Control)sender);
        if (i < _fields.Count - 1) _fields[i + 1].Focus(FocusState.Programmatic);
        else if (Value() is { } v) Answer(v);
    }

    private void Answer(string value, bool hide = true)
    {
        if (_sending) return;
        _sending = true;
        _decline.IsEnabled = false;
        Validate();
        Tucked = false;
        if (hide) Dialogs.Hide(Dialog);
        OnAnswer?.Invoke(this, value);
    }

    /// The answer didn't go out: the sheet can be sent again with its text.
    public void Reopen()
    {
        _sending = false;
        _decline.IsEnabled = true;
        Validate();
    }

    /// Shows the sheet; returns when it closes. A close with no answer tucks it.
    public async Task ShowAsync(XamlRoot? root)
    {
        if (Showing || Dialogs.Busy || root == null) return;
        Showing = true;
        Tucked = false;
        try
        {
            var result = await Dialogs.ShowAsync(Dialog, root);
            if (result == ContentDialogResult.None && !_sending) Tucked = true;
        }
        finally { Showing = false; }
    }

    /// The request went (answered, withdrawn, signed out): close without a chip and clear the text.
    public void Drop()
    {
        Dialogs.Hide(Dialog);
        foreach (var f in _fields)
        {
            if (f is PasswordBox p) p.Password = "";
            else if (f is TextBox t) t.Text = "";
        }
    }
}
