using Hermes.Core.Groups;
using HermesHQ.Controls;
using HermesHQ.Features.Bots;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace HermesHQ.Pages;

/// [groups] [WIN-59] A room's @ suggestions above the composer (App/Groups/GroupRoomChrome.swift `updateMentions`,
/// RoomMentionList, RoomMentionRow): typing @ and letters lists @everyone and the members that match (each one's face,
/// its name, `@tag` under it), at most four and a half rows tall, 8 pt clear of the message box and on its edges. The
/// box's list keys (Mac polish #16): ↑ / ↓ mark a row, Tab picks it (or the first), Return picks a marked one (else sends
/// as ever), Esc closes the list and keeps the words until they change; a click picks too. A pick puts `@tag ` in place
/// of the @word being typed (`insertMention`). The decisions are Hermes.Core.Groups.GroupMentionList's.
public sealed partial class GroupRoomPage
{
    public const string MentionsId = GroupMentionList.ListId;
    /// RoomMentionList's rows are 48 pt; the list stands at most 4.5 rows tall.
    private const double MentionRowHeight = 48;

    private readonly GroupMentionList _mentions = new();
    private readonly StackPanel _mentionRows = new();
    private readonly ScrollViewer _mentionScroll = new() { HorizontalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MaxHeight = MentionRowHeight * 4.5 };
    private Border? _mentionBox;
    /// The rows as drawn: each one's button and the profile of the face it wears (null: @everyone's symbol).
    private readonly List<(Button Row, TextBlock Detail, string? Face)> _mentionDrawn = [];

    /// The list over the composer, framed as the message box below it (its margins, its width), 8 pt above it.
    private Border MakeMentions()
    {
        _mentionRows.Padding = new Thickness(0, 4, 0, 4);
        _mentionScroll.Content = _mentionRows;
        _mentionBox = new Border
        {
            CornerRadius = new CornerRadius(20), Margin = new Thickness(16, 0, 16, 8), MaxWidth = 900,
            BorderThickness = new Thickness(1), BorderBrush = Brush("CardStrokeColorDefaultBrush"), Background = Brush("AcrylicInAppFillColorDefaultBrush"),
            Child = _mentionScroll, Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetAutomationId(_mentionBox, MentionsId);
        AutomationProperties.SetName(_mentionBox, "Mention suggestions");
        return _mentionBox;
    }

    // ------------------------------------------------------------------ what the walk reads

    public bool MentionsOpen => _mentionBox?.Visibility == Visibility.Visible;
    public IReadOnlyList<GroupMentionList.Row> MentionRows => _mentions.Rows;
    public int? MentionMarked => _mentions.Marked;
    /// The faces the drawn rows wear, by profile (null where a row has none).
    public IReadOnlyList<string?> MentionFaces => [.. _mentionDrawn.Select(d => d.Face)];
    /// The row drawn marked (its fill), or null.
    public int? MentionMarkedDrawn => _mentionDrawn.FindIndex(d => d.Row.Tag is true) is var i and >= 0 ? i : null;
    public int ComposerCaret => _composer.SelectionStart;

    /// The walk's typing when SendInput's letters don't arrive: the words added at the end of the box, as typing does.
    public void AutomationType(string words)
    {
        _composer.Text += words;
        _composer.SelectionStart = _composer.Text.Length;
        UpdateMentions();
    }

    /// The walk's key into the message box: the page's own handling of it (the box's PreviewKeyDown), no injected key.
    public bool AutomationKey(VirtualKey key) => HandleKey(key, shift: false);

    // ------------------------------------------------------------------ the list

    /// The words up to the caret (a suggestion follows what is being typed there); all of them when the box isn't focused.
    private string CaretText()
    {
        var text = _composer.Text;
        if (_composer.FocusState == FocusState.Unfocused) return text;
        return text[..Math.Clamp(_composer.SelectionStart, 0, text.Length)];
    }

    private void UpdateMentions()
    {
        var choices = _session?.MentionChoices ?? [];
        if (_mentions.Update(_composer.Text, CaretText(), choices) || MentionsOpen != _mentions.IsOpen) DrawMentions();
    }

    /// The list's keys while it shows (`ComposerTextView.onDrawerKey` / `onHardwareReturnPick` / `onDrawerEscape`): true
    /// when the key was the list's.
    private bool MentionKey(VirtualKey key, bool shift)
    {
        if (!MentionsOpen) return false;
        switch (key)
        {
            case VirtualKey.Down: _mentions.Key(GroupMentionList.DrawerKey.Down); MarkMentions(); return true;
            case VirtualKey.Up: _mentions.Key(GroupMentionList.DrawerKey.Up); MarkMentions(); return true;
            case VirtualKey.Tab when !shift:
                if (_mentions.Key(GroupMentionList.DrawerKey.Tab) is { } tabbed) PickMention(tabbed);
                return true;
            case VirtualKey.Enter when !shift:
                if (_mentions.PickMarked() is not { } marked) return false;   // nothing marked: Return sends as ever
                PickMention(marked);
                return true;
            case VirtualKey.Escape:
                if (_mentions.Escape(_composer.Text)) DrawMentions();
                return true;
        }
        return false;
    }

    /// `insertMention(tag, replacingQuery: true)`: `@tag ` in place of the @word, the caret after it, the list closed.
    private void PickMention(string tag)
    {
        var caret = _composer.FocusState == FocusState.Unfocused ? _composer.Text.Length : _composer.SelectionStart;
        var (text, at) = GroupMentionList.Insert(_composer.Text, caret, tag, replacingQuery: true);
        _composer.Text = text;
        _composer.Focus(FocusState.Programmatic);
        _composer.SelectionStart = at;
        _composer.SelectionLength = 0;
        UpdateMentions();
    }

    private void DrawMentions()
    {
        if (_mentionBox == null) return;
        _mentionRows.Children.Clear();
        _mentionDrawn.Clear();
        foreach (var row in _mentions.Rows)
        {
            var button = MentionRow(row, out var detail, out var face);
            _mentionRows.Children.Add(button);
            _mentionDrawn.Add((button, detail, face));
        }
        _mentionBox.Visibility = _mentions.IsOpen ? Visibility.Visible : Visibility.Collapsed;
        MarkMentions();
    }

    /// RoomMentionRow: the 28 pt face 14 pt in (the two-people symbol for @everyone), the name semibold over the detail,
    /// at least 48 pt tall. A click picks it; it takes no Tab stop (the box's keys work the list).
    private Button MentionRow(GroupMentionList.Row row, out TextBlock detail, out string? faceProfile)
    {
        FrameworkElement face;
        faceProfile = null;
        if (row.Sender is { } sender)
        {
            var head = new BotHead { Width = 28, Height = 28, IsHitTestVisible = false };
            if (ListsHub.Current?.Bots.Bot(sender.Profile)?.Model is { } bot) head.Bot = bot;
            else head.DisplayName = sender.Name;
            AutomationProperties.SetAutomationId(head, "room.mention.face");
            face = head;
            faceProfile = sender.Profile;
        }
        else face = new FontIcon { Glyph = "\uE716", FontSize = 18, Width = 28, Height = 28, Foreground = Brush("TextFillColorSecondaryBrush") };
        face.VerticalAlignment = VerticalAlignment.Center;
        var name = new TextBlock { Text = row.Name, FontSize = 13, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
        detail = new TextBlock { Text = row.Detail, FontSize = 12, Foreground = Brush("TextFillColorSecondaryBrush"), TextTrimming = TextTrimming.CharacterEllipsis };
        var texts = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center, Children = { name, detail } };
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.Children.Add(face);
        Grid.SetColumn(texts, 1);
        grid.Children.Add(texts);
        var button = new Button
        {
            Content = grid, MinHeight = MentionRowHeight, Padding = new Thickness(14, 7, 14, 7), IsTabStop = false,
            HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            BorderThickness = new Thickness(0), CornerRadius = new CornerRadius(0), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
        };
        AutomationProperties.SetAutomationId(button, row.AutomationId);
        AutomationProperties.SetName(button, row.Spoken);
        button.Click += (_, _) => PickMention(row.Tag);
        return button;
    }

    /// The marked row wears the window's selection (as the drawer marks its rows), and is scrolled into view.
    private void MarkMentions()
    {
        for (var i = 0; i < _mentionDrawn.Count; i++)
        {
            var (button, detail, _) = _mentionDrawn[i];
            var marked = i == _mentions.Marked;
            button.Tag = marked;
            button.Background = marked ? Brush("AccentFillColorDefaultBrush") : new SolidColorBrush(Microsoft.UI.Colors.Transparent);
            button.Foreground = marked ? Brush("TextOnAccentFillColorPrimaryBrush") : Brush("TextFillColorPrimaryBrush");
            detail.Foreground = marked ? Brush("TextOnAccentFillColorSecondaryBrush") : Brush("TextFillColorSecondaryBrush");
            AutomationProperties.SetItemStatus(button, marked ? "Selected" : "");
            if (marked) button.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false });
        }
    }
}
