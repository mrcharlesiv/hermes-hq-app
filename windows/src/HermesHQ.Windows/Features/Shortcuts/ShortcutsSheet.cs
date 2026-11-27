using Hermes.Core.Shell;
using HermesHQ.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace HermesHQ.Features.Shortcuts;

/// Help › Keyboard Shortcuts (App/Mac/MacShortcutsSheet.swift): a sheet listing every key the app offers, section by
/// section in the Mac's menus' order, each command's name with its keys on the right (`Hermes.Core.Shell.KeyShortcuts`).
/// Opened by Ctrl+/ (the Mac's ⌘/) and the sidebar foot's menu; closed by Done or Escape. A second Ctrl+/ while it is
/// up leaves the one on show, as the Mac's does.
public static class ShortcutsSheet
{
    private static ContentDialog? _open;

    public static bool IsOpen => _open != null;

    public static async Task ShowAsync(XamlRoot? root, IReadOnlyList<ShortcutSection> sections)
    {
        if (root == null || _open != null) return;
        AppLog.Note("keys", "keyboard shortcuts");
        var dialog = new ContentDialog
        {
            Title = "Keyboard Shortcuts",
            CloseButtonText = "Done",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = root,
            Content = Build(sections, root),
        };
        AutomationProperties.SetAutomationId(dialog, "shortcuts.sheet");
        AutomationProperties.SetName(dialog, "Keyboard Shortcuts");
        _open = dialog;
        try { await dialog.ShowAsync(); }
        catch (Exception e) { AppLog.Error("keys", e); }   // another dialog was already up
        finally { _open = null; }
    }

    private static FrameworkElement Build(IReadOnlyList<ShortcutSection> sections, XamlRoot root)
    {
        var column = new StackPanel { Spacing = 18, MinWidth = 420, MaxWidth = 478 };
        for (var s = 0; s < sections.Count; s++)
        {
            var section = sections[s];
            var block = new StackPanel { Spacing = 4 };
            var header = new TextBlock { Text = section.Title, Style = Style("BodyStrongTextBlockStyle") };
            AutomationProperties.SetHeadingLevel(header, AutomationHeadingLevel.Level2);
            block.Children.Add(header);

            // One list per section: Narrator reads its name, then each row's name and keys ("Settings…, Control Comma").
            var list = new ListView
            {
                SelectionMode = ListViewSelectionMode.None,
                IsItemClickEnabled = false,
                Padding = new Thickness(0),
            };
            ScrollViewer.SetVerticalScrollMode(list, ScrollMode.Disabled);
            ScrollViewer.SetVerticalScrollBarVisibility(list, ScrollBarVisibility.Disabled);
            AutomationProperties.SetAutomationId(list, $"shortcuts.section.{s}");
            AutomationProperties.SetName(list, section.Title);
            for (var r = 0; r < section.Rows.Count; r++)
                list.Items.Add(Row(section.Rows[r], s, r));
            block.Children.Add(list);

            if (section.Footer is { } footer)
                block.Children.Add(new TextBlock
                {
                    Text = footer, TextWrapping = TextWrapping.Wrap, Style = Style("CaptionTextBlockStyle"),
                    Foreground = Brush("TextFillColorSecondaryBrush"), Margin = new Thickness(12, 2, 12, 0),
                });
            column.Children.Add(block);
        }
        var scroller = new ScrollViewer
        {
            Content = column,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            // Up to the room of the window it opens over (the Mac's MacSheetFit.cap), less the title and Done.
            MaxHeight = Math.Max(240, root.Size.Height - 220),
        };
        AutomationProperties.SetAutomationId(scroller, "shortcuts.list");
        return scroller;
    }

    private static ListViewItem Row(ShortcutRow row, int section, int index)
    {
        var grid = new Grid { ColumnSpacing = 24 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var title = new TextBlock { Text = row.Title, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        var keys = new TextBlock
        {
            Text = row.KeysText, Foreground = Brush("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        Grid.SetColumn(keys, 1);
        grid.Children.Add(title);
        grid.Children.Add(keys);
        var item = new ListViewItem { Content = grid, MinHeight = 32, Padding = new Thickness(12, 2, 12, 2), HorizontalContentAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(item, row.AccessibleName);
        AutomationProperties.SetAutomationId(item, $"shortcuts.row.{section}.{index}");
        if (row.Keys.Count > 0) AutomationProperties.SetAcceleratorKey(item, row.Keys[0].Display);
        return item;
    }

    private static Style? Style(string key) =>
        Application.Current.Resources.TryGetValue(key, out var s) ? s as Style : null;

    private static Brush? Brush(string key) =>
        Application.Current.Resources.TryGetValue(key, out var b) ? b as Brush : null;
}

/// A `KeyChord` as a WinUI accelerator (the shell registers its keys through this).
public static class ShortcutKeys
{
    public static KeyboardAccelerator Accelerator(KeyChord chord)
    {
        var mods = VirtualKeyModifiers.None;
        if (chord.Ctrl) mods |= VirtualKeyModifiers.Control;
        if (chord.Shift) mods |= VirtualKeyModifiers.Shift;
        if (chord.Alt) mods |= VirtualKeyModifiers.Menu;
        return new KeyboardAccelerator { Key = Key(chord.Key), Modifiers = mods };
    }

    public static VirtualKey Key(string key) => key switch
    {
        "," => (VirtualKey)188,   // VK_OEM_COMMA
        "/" => (VirtualKey)191,   // VK_OEM_2, the / ? key
        "-" => (VirtualKey)189,   // VK_OEM_MINUS
        "Plus" => (VirtualKey)187, // VK_OEM_PLUS
        "Enter" => VirtualKey.Enter,
        "Tab" => VirtualKey.Tab,
        "Esc" => VirtualKey.Escape,
        "F5" => VirtualKey.F5,
        "Down" => VirtualKey.Down,
        "Up" => VirtualKey.Up,
        [var c] when c is >= 'A' and <= 'Z' => VirtualKey.A + (c - 'A'),
        [var c] when c is >= '0' and <= '9' => VirtualKey.Number0 + (c - '0'),
        _ => throw new ArgumentException($"no virtual key for {key}"),
    };
}
