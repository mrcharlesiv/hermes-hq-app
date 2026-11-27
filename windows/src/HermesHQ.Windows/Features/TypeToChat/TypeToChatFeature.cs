using HermesHQ.Features.OpenQuickly;
using HermesHQ.Features.Shortcuts;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;
using Windows.UI.Core;
using Rules = Hermes.Core.Shell.TypeToChat;

namespace HermesHQ.Features.TypeToChat;

/// Type-to-chat (App/Mac/MacTypeToChat.swift, `TypeToChatKeys`): while a chat is open, a key that types, pressed with no
/// text field holding the keyboard (after a click on a sidebar row, a chat in Sessions, a button), goes into the chat's
/// message box, and the box keeps the keyboard. The decision is `Hermes.Core.Shell.TypeToChat`.
///
/// The Mac holds the press in an AppKit monitor, focuses the box and sends the press round again so it reaches the box
/// through its input method. Windows hands a key's character out after its key-down, to whatever has the keyboard then:
/// the window's PreviewKeyDown (which sees the press before any element) moves the keyboard to the box and leaves the
/// press alone, so the character, an accent's dead key and an input method's letter go to the box as if it had been
/// clicked first. Should the character still reach the element that had the keyboard, the box takes it once
/// (`TypeToChat.Relay`). Hooked on the window's root while the chat is open; dropped when it closes.
public static class TypeToChatFeature
{
    public static void Register() => ChatExtensions.OnOpen.Add(Attach);

    private static void Attach(ChatContext ctx)
    {
        UIElement? root = null;
        var relay = new Rules.Relay();
        var box = ctx.Composer;

        void OnKey(object sender, KeyRoutedEventArgs e)
        {
            var forwarded = false;
            try
            {
                if (e.Handled || box.XamlRoot is not { } xamlRoot) return;
                var ctrl = Down(VirtualKey.Control);
                var alt = Down(VirtualKey.Menu);
                var win = Down(VirtualKey.LeftWindows) || Down(VirtualKey.RightWindows);
                var key = (int)e.Key;
                if (!Rules.Takes(key, ctrl, alt, win)) return;   // most presses stop here, before the tree is walked
                var scene = new Rules.Scene(
                    ChatOnShow: ctx.Page.IsLoaded && ctx.Page.XamlRoot == xamlRoot,
                    WindowActive: xamlRoot.IsHostVisible,
                    Covered: Covered(xamlRoot),
                    Focused: FocusKind(FocusManager.GetFocusedElement(xamlRoot) as DependencyObject, ctx.Dock),
                    BoxDocked: ctx.Dock.Content != null,
                    BoxReady: Rules.BoxReady(Shown(box), box.IsEnabled, box.IsReadOnly));
                if (!Rules.Forwards(key, ctrl, alt, win, scene)) return;
                AppLog.Note("keys", "typed with nothing focused: the message box takes the keyboard");
                forwarded = box.Focus(FocusState.Programmatic);
            }
            finally { relay.KeyDown(forwarded); }
        }

        void OnCharacter(UIElement sender, CharacterReceivedRoutedEventArgs e)
        {
            var inBox = e.OriginalSource is DependencyObject source && Within(source, box);
            if (!relay.Character(inBox) || e.Handled) return;
            if (char.IsControl(e.Character)) return;
            e.Handled = true;
            Insert(box, e.Character.ToString());
        }

        void Hook()
        {
            if (root != null || ctx.Page.XamlRoot?.Content is not UIElement content) return;
            root = content;
            root.PreviewKeyDown += OnKey;
            root.CharacterReceived += OnCharacter;
        }

        RoutedEventHandler loaded = (_, _) => Hook();
        ctx.Page.Loaded += loaded;
        if (ctx.Page.IsLoaded) Hook();
        ctx.Closed += () =>
        {
            ctx.Page.Loaded -= loaded;
            if (root == null) return;
            root.PreviewKeyDown -= OnKey;
            root.CharacterReceived -= OnCharacter;
            root = null;
        };
    }

    private static bool Down(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    /// Something over the window takes the keys: a dialog, a menu or flyout, Open Quickly, the Keyboard Shortcuts sheet
    /// (a tooltip is no cover).
    private static bool Covered(XamlRoot root) =>
        OpenQuicklyPanel.IsOpen || ShortcutsSheet.IsOpen
        || VisualTreeHelper.GetOpenPopupsForXamlRoot(root).Any(p => p.Child is not ToolTip);

    private static Rules.Focus FocusKind(DependencyObject? focused, ContentControl dock)
    {
        if (focused == null) return Rules.Focus.Nothing;
        if (Within(focused, dock)) return Rules.Focus.QuestionDock;
        for (var at = focused; at != null; at = VisualTreeHelper.GetParent(at))
        {
            switch (at)
            {
                case TextBox or RichEditBox or PasswordBox or AutoSuggestBox or NumberBox or RichTextBlock or TextBlock:
                    return Rules.Focus.TextInput;
                case ComboBox:
                    return Rules.Focus.ChoiceBox;
            }
        }
        return Rules.Focus.Other;
    }

    /// Shown: the box and every element it sits in are visible.
    private static bool Shown(UIElement box)
    {
        for (DependencyObject? at = box; at != null; at = VisualTreeHelper.GetParent(at))
            if (at is UIElement { Visibility: Visibility.Collapsed }) return false;
        return true;
    }

    private static bool Within(DependencyObject element, DependencyObject ancestor)
    {
        for (var at = element; at != null; at = VisualTreeHelper.GetParent(at))
            if (ReferenceEquals(at, ancestor)) return true;
        return false;
    }

    /// The character in place of the box's selection, the caret after it.
    private static void Insert(TextBox box, string typed)
    {
        var start = Math.Clamp(box.SelectionStart, 0, box.Text.Length);
        var length = Math.Clamp(box.SelectionLength, 0, box.Text.Length - start);
        box.Text = box.Text.Remove(start, length).Insert(start, typed);
        box.SelectionStart = start + typed.Length;
    }
}
