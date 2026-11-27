// Watch Browser's hidden keyboard catcher (C# twin of App/Browser/BrowserKeyField.swift):
// forwards typed characters (including UTF-16 surrogate pairs), named navigation/editing keys, and Ctrl+C / Ctrl+V /
// Ctrl+A clipboard shortcuts straight to the bot's browser without keeping any text locally. Uses a PasswordBox for
// password slots so Windows treats input as sensitive.

using Hermes.Core.Browser;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;
using Windows.UI.Core;

namespace HermesHQ.Features.Browser;

internal sealed class BrowserKeyField : Grid
{
    private readonly TextBox _textBox;
    private readonly PasswordBox _passwordBox;

    private BrowserKeyboardSlot _activeSlot = BrowserKeyboardSlot.Text;
    private BrowserKeyboardSlot? _focusedSlot;
    private char _highSurrogate;

    public Action<string>? OnText { get; set; }
    public Action<string>? OnKey { get; set; }
    public Action? OnCopyShortcut { get; set; }
    public Action? OnPasteShortcut { get; set; }
    public Action? OnSelectAllShortcut { get; set; }
    public Action<bool>? OnFocusChanged { get; set; }
    public Action? OnRequestFocusClear { get; set; }

    public bool IsFocused => _focusedSlot != null;
    public BrowserKeyboardSlot? FocusedSlot => _focusedSlot;

    public BrowserKeyField()
    {
        Width = 1;
        Height = 1;
        Opacity = 0;
        HorizontalAlignment = HorizontalAlignment.Left;
        VerticalAlignment = VerticalAlignment.Top;

        _textBox = new TextBox
        {
            Width = 1,
            Height = 1,
            IsTabStop = false,
            AcceptsReturn = false,
        };
        _textBox.GotFocus += (_, _) => SetFocus(_activeSlot == BrowserKeyboardSlot.Password ? BrowserKeyboardSlot.Text : _activeSlot);
        _textBox.LostFocus += (_, _) => ClearFocus(isPassword: false);
        _textBox.PreviewKeyDown += OnPreviewKeyDown;
        _textBox.CharacterReceived += OnCharacterReceived;
        _textBox.BeforeTextChanging += (_, e) => { if (e.NewText.Length > 0) e.Cancel = true; };

        _passwordBox = new PasswordBox
        {
            Width = 1,
            Height = 1,
            IsTabStop = false,
        };
        _passwordBox.GotFocus += (_, _) => SetFocus(BrowserKeyboardSlot.Password);
        _passwordBox.LostFocus += (_, _) => ClearFocus(isPassword: true);
        _passwordBox.PreviewKeyDown += OnPreviewKeyDown;
        _passwordBox.CharacterReceived += OnCharacterReceived;
        _passwordBox.PasswordChanged += (_, _) => { if (_passwordBox.Password.Length > 0) _passwordBox.Password = ""; };

        Children.Add(_textBox);
        Children.Add(_passwordBox);
    }

    public void Raise(BrowserKeyboardSlot slot, BrowserKeyboardKind kind)
    {
        _activeSlot = slot;
        _highSurrogate = '\0';
        if (slot == BrowserKeyboardSlot.Password)
        {
            _passwordBox.Focus(FocusState.Programmatic);
        }
        else
        {
            ApplyKind(kind);
            _textBox.Focus(FocusState.Programmatic);
        }
    }

    public void UpdateKind(BrowserKeyboardKind kind)
    {
        if (_activeSlot != BrowserKeyboardSlot.Password) ApplyKind(kind);
    }

    public void Lower()
    {
        _highSurrogate = '\0';
        if (_focusedSlot != null) OnRequestFocusClear?.Invoke();
    }

    private void ApplyKind(BrowserKeyboardKind kind)
    {
        var nameValue = kind switch
        {
            BrowserKeyboardKind.Email => InputScopeNameValue.EmailSmtpAddress,
            BrowserKeyboardKind.Url => InputScopeNameValue.Url,
            BrowserKeyboardKind.Tel => InputScopeNameValue.TelephoneNumber,
            BrowserKeyboardKind.Decimal => InputScopeNameValue.Number,
            BrowserKeyboardKind.Search => InputScopeNameValue.Search,
            _ => InputScopeNameValue.Default,
        };
        var scope = new InputScope();
        scope.Names.Add(new InputScopeName(nameValue));
        _textBox.InputScope = scope;
    }

    private void SetFocus(BrowserKeyboardSlot slot)
    {
        var wasFocused = _focusedSlot != null;
        _focusedSlot = slot;
        _highSurrogate = '\0';
        if (!wasFocused) OnFocusChanged?.Invoke(true);
    }

    private void ClearFocus(bool isPassword)
    {
        var matches = isPassword ? _focusedSlot == BrowserKeyboardSlot.Password : _focusedSlot != BrowserKeyboardSlot.Password;
        if (!matches) return;
        _focusedSlot = null;
        _highSurrogate = '\0';
        OnFocusChanged?.Invoke(false);
    }

    private static bool IsDown(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    private void OnPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var ctrl = IsDown(VirtualKey.Control);
        var alt = IsDown(VirtualKey.Menu);

        if (ctrl && !alt)
        {
            if (e.Key == VirtualKey.C) { OnCopyShortcut?.Invoke(); e.Handled = true; return; }
            if (e.Key == VirtualKey.V) { OnPasteShortcut?.Invoke(); e.Handled = true; return; }
            if (e.Key == VirtualKey.A) { OnSelectAllShortcut?.Invoke(); e.Handled = true; return; }
        }

        var mapped = e.Key switch
        {
            VirtualKey.Enter => "Enter",
            VirtualKey.Back => "Backspace",
            VirtualKey.Tab => "Tab",
            VirtualKey.Escape => "Escape",
            VirtualKey.Left => "ArrowLeft",
            VirtualKey.Right => "ArrowRight",
            VirtualKey.Up => "ArrowUp",
            VirtualKey.Down => "ArrowDown",
            VirtualKey.Delete => "Delete",
            VirtualKey.Home => "Home",
            VirtualKey.End => "End",
            VirtualKey.PageUp => "PageUp",
            VirtualKey.PageDown => "PageDown",
            _ => null,
        };
        if (mapped == null) return;
        _highSurrogate = '\0';
        OnKey?.Invoke(mapped);
        e.Handled = true;
    }

    private void OnCharacterReceived(UIElement sender, CharacterReceivedRoutedEventArgs e)
    {
        e.Handled = true;
        var ch = e.Character;
        var ctrl = IsDown(VirtualKey.Control);
        var alt = IsDown(VirtualKey.Menu);
        // Ctrl without AltGr is a shortcut chord, not printable text.
        if (ctrl && !alt) return;
        if (ch < 0x20 || ch == 0x7F) return;

        if (char.IsHighSurrogate(ch))
        {
            _highSurrogate = ch;
            return;
        }
        if (char.IsLowSurrogate(ch))
        {
            if (_highSurrogate != '\0')
            {
                var pair = new string([_highSurrogate, ch]);
                _highSurrogate = '\0';
                OnText?.Invoke(pair);
            }
            return;
        }
        _highSurrogate = '\0';
        OnText?.Invoke(ch.ToString());
    }
}
