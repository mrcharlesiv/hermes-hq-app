using Hermes.Core.BotPages;
using Hermes.Core.Settings;
using Hermes.Core.Shell;
using HermesHQ.Features.BotPages;
using HermesHQ.Features.Bots;
using HermesHQ.Pages;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace HermesHQ.Features.OpenQuickly;

/// Open Quickly (App/Mac/MacOpenQuickly.swift): a panel near the window's top, over the whole window, opened by Ctrl+K
/// (the Mac's ⌘K). The latest chats show before typing, under "Recent"; typing searches what More's search finds, in
/// its groups (Go To, Bots, Sessions, Settings, Actions). ↑ and ↓ move the mark across the groups, Enter opens the
/// marked row, Esc or a click outside closes, the pointer moves the mark and a click opens. A result opens where its own
/// row, key or button opens it (`Hermes.Core.Shell.OpenQuickly.Route`), through the Navigator. Ctrl+K again while it is
/// up puts the caret back in its field.
public static class OpenQuicklyPanel
{
    /// What the shell runs for the actions that are its own: New Chat (Ctrl+N) and the sidebar's New Bot.
    public sealed record ShellActions(Action NewChat, Action NewBot);

    private static Panel? _shown;

    public static bool IsOpen => _shown != null;

    public static void Show(XamlRoot? root, ListsHub? hub, ShellActions actions)
    {
        if (root == null || hub == null) return;
        if (_shown != null) { _shown.Field.Focus(FocusState.Keyboard); return; }
        AppLog.Note("keys", "open quickly");
        _shown = new Panel(root, hub, actions);
        _shown.Open();
    }

    /// The groups the words find (More's search over what is on show now).
    private static IReadOnlyList<MoreSearch.Group> Results(ListsHub hub, string query)
    {
        var bots = hub.Bots.Rows.Select(r => r.Model).ToList();
        var pages = Places.All.Select(p => new MoreSearch.Item(p.Id, p.Title, "Sidebar",
            [.. p.Keywords, .. MoreSearch.MorePageWords.TryGetValue(p.Id, out var w) ? w : []], p.Glyph));
        var botItems = BotChoiceStore.Choices(bots).Select(b => new MoreSearch.Item(b.Name, b.DisplayName,
            MoreSearch.BotDetail(b.Name, b.DisplayName), [b.Name, b.Description ?? ""]));
        var sessions = hub.Sessions.LiveSummaries().Where(s => !MoreSearch.HiddenSession(s.Title)).Select(s => new MoreSearch.Item(
            s.Profile + "|" + s.Id, MoreSearch.SessionTitle(s.Title), Detail(hub, s.Profile, s.LastActive), [s.Preview ?? ""]));
        var facts = new MoreSearch.ActionFacts(Writable: true, Kanban: Ported("kanban"), CommandCenter: Ported("command-center"));
        return MoreSearch.Results(query, pages, botItems, sessions, MoreSearch.SettingsShown(SettingsSearch.Index), MoreSearch.Actions(facts));
    }

    /// The latest chats, before anything is typed.
    private static IReadOnlyList<MoreSearch.Group> Recent(ListsHub hub) =>
        Hermes.Core.Shell.OpenQuickly.Recent(hub.Sessions.LiveSummaries().Select(s =>
            new Hermes.Core.Shell.OpenQuickly.Chat(s.Profile, s.Id, s.Title, s.LastActive, Detail(hub, s.Profile, s.LastActive))));

    private static string Detail(ListsHub hub, string profile, DateTimeOffset? when)
    {
        var bot = hub.Bots.Bot(profile)?.Model.DisplayName ?? ProfileName.Readable(profile);
        return Hermes.Core.Shell.OpenQuickly.ChatDetail(bot, when?.ToLocalTime().DateTime, DateTime.Today);
    }

    private static bool Ported(string place) => Places.All.Any(p => p.Id == place && p.Page != typeof(PlaceholderPage));

    private static string Glyph(MoreSearch.Kind kind, MoreSearch.Item item) => item.Glyph is { Length: > 0 } g ? g : kind switch
    {
        MoreSearch.Kind.GoTo => "\uE72A",       // arrow
        MoreSearch.Kind.Bots => "\uE77B",       // person
        MoreSearch.Kind.Sessions => "\uE8BD",   // chat bubbles
        MoreSearch.Kind.Settings => "\uE713",   // gear
        _ => "\uE945",                          // bolt
    };

    private sealed class Panel
    {
        private readonly XamlRoot _root;
        private readonly ListsHub _hub;
        private readonly ShellActions _actions;
        private readonly OpenQuicklyState _state;
        private readonly Popup _popup = new();
        private readonly Grid _overlay = new() { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        private readonly Border _panel = new();
        private readonly ListView _list = new();
        private readonly TextBlock _empty = new();
        private readonly List<ListViewItem> _rows = [];
        private readonly Dictionary<ListViewItem, (int Section, int Row)> _at = [];
        private bool _closing;
        public TextBox Field { get; } = new();

        public Panel(XamlRoot root, ListsHub hub, ShellActions actions)
        {
            _root = root;
            _hub = hub;
            _actions = actions;
            _state = new OpenQuicklyState(q => Results(hub, q), () => Recent(hub));
            Build();
        }

        private void Build()
        {
            AutomationProperties.SetAutomationId(_panel, "openquickly");
            AutomationProperties.SetName(_panel, Hermes.Core.Shell.OpenQuickly.FieldName);
            _panel.Background = Brush("AcrylicBackgroundFillColorDefaultBrush") ?? Brush("SolidBackgroundFillColorBaseBrush");
            _panel.BorderBrush = Brush("SurfaceStrokeColorDefaultBrush");
            _panel.BorderThickness = new Thickness(1);
            _panel.CornerRadius = new CornerRadius(8);
            _panel.VerticalAlignment = VerticalAlignment.Top;
            _panel.HorizontalAlignment = HorizontalAlignment.Center;
            _panel.Shadow = new ThemeShadow();
            _panel.Translation = new System.Numerics.Vector3(0, 0, 32);

            // The field inside one shaded rounded box with the magnifier inline (MacOpenQuickly.swift).
            var fieldBox = new Grid { ColumnSpacing = 8 };
            fieldBox.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            fieldBox.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var glass = new FontIcon { Glyph = "\uE721", FontSize = 15, Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, Foreground = Brush("TextFillColorSecondaryBrush") };
            AutomationProperties.SetAccessibilityView(glass, AccessibilityView.Raw);
            fieldBox.Children.Add(glass);
            Field.PlaceholderText = Hermes.Core.Shell.OpenQuickly.Placeholder;
            Field.IsSpellCheckEnabled = false;
            Field.IsTextPredictionEnabled = false;
            Field.FontSize = 15;
            Field.BorderThickness = new Thickness(0);
            Field.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
            AutomationProperties.SetName(Field, Hermes.Core.Shell.OpenQuickly.FieldName);
            AutomationProperties.SetAutomationId(Field, "openquickly.field");
            Field.TextChanged += (_, _) => Typed();
            // Before the field's own caret moves: ↑ ↓ move the mark, Enter opens it, Esc closes.
            Field.PreviewKeyDown += OnKey;
            Grid.SetColumn(Field, 1);
            fieldBox.Children.Add(Field);
            var fieldFrame = new Border
            {
                Margin = new Thickness(12, 12, 12, 0),
                CornerRadius = new CornerRadius(8),
                Background = Brush("ControlFillColorSecondaryBrush") ?? Brush("SubtleFillColorSecondaryBrush"),
                BorderBrush = Brush("ControlStrokeColorDefaultBrush"),
                BorderThickness = new Thickness(1),
                Child = fieldBox,
            };

            _list.SelectionMode = ListViewSelectionMode.Single;
            _list.IsItemClickEnabled = true;
            _list.Margin = new Thickness(12, 6, 12, 6);
            _list.Padding = new Thickness(0, 0, 0, 6);
            _list.TabNavigation = KeyboardNavigationMode.Once;
            AutomationProperties.SetAutomationId(_list, "openquickly.results");
            AutomationProperties.SetName(_list, "Results");
            _list.ItemClick += (_, e) =>
            {
                if (e.ClickedItem is ListViewItem row && _at.TryGetValue(row, out var at)) { _state.Mark(at.Section, at.Row); OpenMarked(); }
            };
            _list.PreviewKeyDown += OnKey;

            _empty.Height = 80;
            _empty.TextAlignment = TextAlignment.Center;
            _empty.VerticalAlignment = VerticalAlignment.Center;
            _empty.Padding = new Thickness(12, 30, 12, 0);
            _empty.Foreground = Brush("TextFillColorSecondaryBrush");
            AutomationProperties.SetAutomationId(_empty, "openquickly.empty");
            AutomationProperties.SetLiveSetting(_empty, AutomationLiveSetting.Polite);

            var column = new StackPanel();
            column.Children.Add(fieldFrame);
            column.Children.Add(_list);
            column.Children.Add(_empty);
            _panel.Child = column;

            _overlay.Children.Add(_panel);
            // A click outside the panel closes it.
            _overlay.Tapped += (_, e) => { if (ReferenceEquals(e.OriginalSource, _overlay)) Close(); };
            _overlay.KeyDown += (_, e) => { if (e.Key == VirtualKey.Escape) { e.Handled = true; Close(); } };
            _popup.Child = _overlay;
            _popup.XamlRoot = _root;
            _popup.Closed += (_, _) =>
            {
                _root.Changed -= OnRootChanged;
                if (ReferenceEquals(_shown, this)) _shown = null;
            };
        }

        public void Open()
        {
            Fit();
            _root.Changed += OnRootChanged;
            _popup.IsOpen = true;
            Typed();
            Field.Loaded += (_, _) => Field.Focus(FocusState.Programmatic);
            Field.Focus(FocusState.Programmatic);
        }

        private void OnRootChanged(XamlRoot sender, XamlRootChangedEventArgs args) => Fit();

        /// 640 wide (at most the window less 80), a tenth of the way down; the list at most what the window leaves.
        private void Fit()
        {
            var size = _root.Size;
            _overlay.Width = size.Width;
            _overlay.Height = size.Height;
            _panel.Width = Hermes.Core.Shell.OpenQuickly.PanelWidthIn(size.Width);
            _panel.Margin = new Thickness(0, Hermes.Core.Shell.OpenQuickly.TopRoom(size.Height), 0, 0);
            // As tall as its rows (+6, the list's foot padding), up to the room left.
            _list.MaxHeight = Hermes.Core.Shell.OpenQuickly.ListHeight(size.Height, double.MaxValue, empty: false);
        }

        private void Typed()
        {
            _state.Type(Field.Text);
            _rows.Clear();
            _at.Clear();
            var items = new List<ListViewItem>();
            for (var s = 0; s < _state.Groups.Count; s++)
            {
                var group = _state.Groups[s];
                items.Add(Header(_state.Header(s), s));
                for (var r = 0; r < group.Rows.Count; r++)
                {
                    var row = Row(group.Kind, group.Rows[r]);
                    _at[row] = (s, r);
                    _rows.Add(row);
                    items.Add(row);
                }
            }
            _list.ItemsSource = items;
            var note = _state.EmptyNote;
            _list.Visibility = note == null ? Visibility.Visible : Visibility.Collapsed;
            _empty.Visibility = note == null ? Visibility.Collapsed : Visibility.Visible;
            _empty.Text = note ?? "";
            ShowMark(announce: false);
        }

        private static ListViewItem Header(string title, int section)
        {
            var text = new TextBlock { Text = title, Style = Style("CaptionTextBlockStyle"), Foreground = Brush("TextFillColorSecondaryBrush") };
            var item = new ListViewItem
            {
                Content = text, IsHitTestVisible = false, IsTabStop = false, MinHeight = 24,
                Padding = new Thickness(12, 6, 12, 2),
            };
            AutomationProperties.SetName(item, title);
            AutomationProperties.SetHeadingLevel(item, AutomationHeadingLevel.Level2);
            AutomationProperties.SetAutomationId(item, $"openquickly.header.{section}");
            return item;
        }

        private ListViewItem Row(MoreSearch.Kind kind, MoreSearch.Item item)
        {
            var grid = new Grid { ColumnSpacing = 12 };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.Children.Add(new FontIcon { Glyph = Glyph(kind, item), FontSize = 18, Foreground = Brush("TextFillColorSecondaryBrush") });
            var lines = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            lines.Children.Add(new TextBlock { Text = item.Title, TextTrimming = TextTrimming.CharacterEllipsis });
            if (item.Detail.Length > 0)
                lines.Children.Add(new TextBlock
                {
                    Text = item.Detail, TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1,
                    Style = Style("CaptionTextBlockStyle"), Foreground = Brush("TextFillColorSecondaryBrush"),
                });
            Grid.SetColumn(lines, 1);
            grid.Children.Add(lines);
            var row = new ListViewItem { Content = grid, MinHeight = 40, Padding = new Thickness(12, 4, 12, 4), HorizontalContentAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetName(row, Hermes.Core.Shell.OpenQuickly.SpokenName(item));
            AutomationProperties.SetAutomationId(row, Hermes.Core.Shell.OpenQuickly.RowAutomationId(kind, item));
            // The pointer moves the mark, as the keys do (only a pointer that moved: entering is a move).
            row.PointerMoved += (_, _) =>
            {
                if (_at.TryGetValue(row, out var at) && at != _state.Marked) { _state.Mark(at.Section, at.Row); ShowMark(announce: false); }
            };
            return row;
        }

        private void OnKey(object sender, KeyRoutedEventArgs e)
        {
            switch (e.Key)
            {
                case VirtualKey.Up:
                    e.Handled = true;
                    if (_state.Move(-1)) ShowMark(announce: true);
                    break;
                case VirtualKey.Down:
                    e.Handled = true;
                    if (_state.Move(1)) ShowMark(announce: true);
                    break;
                case VirtualKey.Enter:
                    e.Handled = true;
                    OpenMarked();
                    break;
                case VirtualKey.Escape:
                    e.Handled = true;
                    Close();
                    break;
            }
        }

        /// The marked row selected and scrolled into view; with `announce`, Narrator reads it (the caret stays in the field).
        private void ShowMark(bool announce)
        {
            var marked = _rows.FirstOrDefault(r => _at[r] == _state.Marked);
            _list.SelectedItem = marked;
            if (marked == null) return;
            _list.ScrollIntoView(marked);
            if (announce && _state.MarkedRow is { } m)
                (FrameworkElementAutomationPeer.FromElement(Field) ?? FrameworkElementAutomationPeer.CreatePeerForElement(Field))?
                    .RaiseNotificationEvent(AutomationNotificationKind.ActionCompleted, AutomationNotificationProcessing.ImportantMostRecent,
                        Hermes.Core.Shell.OpenQuickly.SpokenName(m.Item), "openquickly.mark");
        }

        /// Enter or a click: the panel goes at once, then the marked row opens where its own row would.
        private void OpenMarked()
        {
            if (_state.MarkedRow is not { } marked) return;
            AppLog.Note("keys", "open quickly: " + Hermes.Core.Shell.OpenQuickly.KindId(marked.Kind));
            Close();
            switch (Hermes.Core.Shell.OpenQuickly.Route(marked.Kind, marked.Item))
            {
                case Hermes.Core.Shell.OpenQuickly.OpenChat c:
                    Navigator.Go(new ChatDestination(c.Profile, c.Id, c.Title));
                    break;
                case Hermes.Core.Shell.OpenQuickly.OpenBot b when _hub.Bots.Bot(b.Id) is { } bot:
                    Navigator.Go(new BotChatDestination(bot.Model));
                    break;
                case Hermes.Core.Shell.OpenQuickly.OpenPlace p:
                    Navigator.Open(p.Id, p.Argument);
                    break;
                case Hermes.Core.Shell.OpenQuickly.OpenSettings s:
                    SettingsWindows.Show(s.Argument);
                    break;
                case Hermes.Core.Shell.OpenQuickly.NewChat:
                    _actions.NewChat();
                    break;
                case Hermes.Core.Shell.OpenQuickly.NewBot:
                    _actions.NewBot();
                    break;
            }
        }

        private void Close()
        {
            if (_closing) return;
            _closing = true;
            _root.Changed -= OnRootChanged;
            _popup.IsOpen = false;
            if (ReferenceEquals(_shown, this)) _shown = null;
        }

        private static Style? Style(string key) =>
            Application.Current.Resources.TryGetValue(key, out var s) ? s as Style : null;

        private static Brush? Brush(string key) =>
            Application.Current.Resources.TryGetValue(key, out var b) ? b as Brush : null;
    }
}
