using Hermes.Core.Bots;
using Hermes.Core.Sessions;
using WorkingRing = Hermes.Core.Settings.WorkingRing;
using DensitySizes = Hermes.Core.Settings.DensitySizes;
using ThemeService = HermesHQ.Features.Settings.ThemeService;
using HermesHQ.Controls;
using HermesHQ.Features.Bots;
using HermesHQ.Features.Sessions;
using HermesHQ.Shell;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.UI.Xaml.Shapes;

namespace HermesHQ.Pages;

/// Sessions (App/Sessions, the Mac's sessions pane): the Chats | Projects switch, the bot (or project) scope, the New
/// and Working counts, Filter & Sort, the filter strip, the groups (Pinned, the days, statuses, projects, bots), a
/// project's page (Pinned, Active, Done), search, and the picked chat beside the list. A failed scan says Retry, never
/// "No sessions" (spec 02 §9.1); background runs stay off unless Show › Background Runs.
public sealed partial class SessionsPage : Page, IKeyRefreshing
{
    private ListsHub? _hub;
    private SessionActions? _actions;
    private string? _openId;
    private string _query = "";

    private abstract record Row;
    private sealed record HeaderRow(SessionGroup Group) : Row;
    private sealed record ChatRow(SessionSummary Chat, bool Recent, bool YesterdayGroup = false) : Row;
    private sealed record MoreRow(SessionGroup Group) : Row;
    private sealed record ProjectRow(SessionGroup Group) : Row;

    public SessionsPage()
    {
        InitializeComponent();
        HermesHQ.Shell.PageBar.Title(BarTitle, "sessions");   // [WIN-49] the Mac's page-title token
        ChatPlaceholder.Children.Add(DetailPlaceholder.Make("No Chat Open", "Choose a chat from the list."));
    }

    private SessionStore? Store => _hub?.Sessions;

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        _hub = ListsHub.Current;
        if (_hub == null) return;
        _actions = new SessionActions(_hub, () => XamlRoot, PillHost);
        _hub.Changed += Rebuild;
        WorkingRing.Changed += OnWorkingRing;
        DensitySizes.Changed += OnDensity;
        ThemeService.Changed += OnThemeChanged;
        // View Sessions / "N more" open here with that bot's chip picked.
        if (e.Parameter is PlaceArgs { Argument: string bot })
        {
            if (_hub.Sessions.Prefs.Pills == SessionPills.Projects) _hub.Sessions.ApplyFilter(new(SessionFilterActionKind.Group, SessionGroupBy.Date), bot);
            _hub.Sessions.BotFilter = bot;
        }
        if (_hub.Sessions.Prefs.ShowArchived || _hub.Sessions.Prefs.Pills == SessionPills.Projects) _ = _hub.Sessions.LoadArchivedAsync();
        Rebuild();
        if (!_hub.Sessions.Loaded) _ = _hub.Sessions.RefreshAsync();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        CloseEmbeddedChat();
        ListLoading.IsActive = false;
        if (_hub == null) return;
        _hub.Changed -= Rebuild;
        WorkingRing.Changed -= OnWorkingRing;
        DensitySizes.Changed -= OnDensity;
        ThemeService.Changed -= OnThemeChanged;
        // Chats read here keep their New rank until the page is left.
        _hub.Sessions.KeepNew.Clear();
    }

    private void CloseEmbeddedChat()
    {
        if (ChatFrame.Content is ChatPage chat) _ = chat.EndForQuitAsync();
        ChatFrame.Content = null;
        ChatFrame.BackStack.Clear();
        _openId = null;
        ChatPlaceholder.Visibility = Visibility.Visible;
    }

    private void OnThemeChanged() => Rebuild();

    private string HomeBot => Store?.Selected?.Profile ?? _hub?.Bots.Layout.Flat.FirstOrDefault()?.Id ?? "default";

    // ------------------------------------------------------------------ drawing

    /// [working-ring] The switch moved in Settings: a working chat's ring goes or comes back at once.
    private void OnWorkingRing() => Rebuild();
    /// [density] Theme › Density: the rows again at the new sizes.
    private void OnDensity() => Rebuild();

    private void Rebuild()
    {
        if (Store is not { } store || _hub == null) return;
        var prefs = store.Prefs;
        var filter = store.FilterState();
        var input = store.Input();

        FilterGlyph.Foreground = ThemeBrushes.Get(SessionFilterWords.FilterCount(filter) > 0 ? "AccentTextFillColorPrimaryBrush" : "TextFillColorPrimaryBrush");
        ToolTipService.SetToolTip(FilterButton, SessionFilterWords.ButtonLabel(filter));
        StripText.Text = SessionFilterWords.StripText(filter) ?? "";
        Strip.Visibility = StripText.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;

        List<SessionGroup> groups;
        if (_query.Length > 0)
        {
            var hits = store.Search(_query);
            groups = hits.Count == 0 ? [] : [new SessionGroup { Id = SessionListPipeline.FlatId, Sessions = hits }];
        }
        else groups = SessionListPipeline.Groups(input);

        var page = groups.FirstOrDefault(g => g.Id == SessionListPipeline.PageId);
        DrawHeader(store, input, onPage: page != null);
        PageHeader.Visibility = page != null ? Visibility.Visible : Visibility.Collapsed;
        if (page != null)
        {
            PageTitle.Text = page.LatestTitle ?? "";
            var parts = new List<string>();
            if (page.Needs > 0) parts.Add($"{page.Needs} need{(page.Needs == 1 ? "s" : "")} you");
            if (page.Ready > 0) parts.Add($"{page.Ready} new");
            if (page.Busy > 0) parts.Add($"{page.Busy} working");
            if (page.Branch != null) parts.Add(page.Branch);
            parts.Add(string.Join(", ", page.Profiles.Select(p => SessionRules.OwnerName(p, store.BotNames))));
            PageLine.Text = string.Join(" · ", parts.Where(p => p.Length > 0));
        }

        var rows = new List<Row>();
        var recentRows = prefs.RecentRows;
        var searching = _query.Length > 0;
        foreach (var g in groups.Where(g => g.Id != SessionListPipeline.PageId))
        {
            if (SessionListPipeline.IsProject(g.Id)) rows.Add(new ProjectRow(g));
            else if (g.Title.Length > 0) rows.Add(new HeaderRow(g));
            var yesterday = !searching && g.Id == "yesterday";
            rows.AddRange(g.Sessions.Select(s => new ChatRow(s, recentRows, yesterday)));
            if (g.More > 0 || g.Expanded) rows.Add(new MoreRow(g));
        }
        var items = rows.Select(r => Make(r, store)).ToList();
        SessionList.ItemsSource = items;
        var openItem = _openId != null ? items.FirstOrDefault(i => i.Tag is ChatRow c && c.Chat.Profile + "/" + c.Chat.Id == _openId) : null;
        if (_openId != null && openItem == null && store.Loaded && _query.Length == 0
            && !store.LiveSummaries().Any(s => s.Profile + "/" + s.Id == _openId && (!s.Archived || store.Prefs.ShowArchived)))
        {
            CloseEmbeddedChat();
        }
        SessionList.SelectedItem = openItem;
        ListLoading.IsActive = !store.Loaded;
        Empty(store, filter, items.Count == 0);
    }

    private static string ScopeWords(SessionStore store)
    {
        if (store.Prefs.Pills == SessionPills.Projects)
        {
            var picked = store.Prefs.ProjectFilter.Intersect(store.ProjectEntries().Select(p => p.Key)).ToList();
            return picked.Count == 1 ? store.ProjectEntries().FirstOrDefault(p => p.Key == picked[0])?.Label ?? "All Projects" : "All Projects";
        }
        return store.BotFilter is { } bot ? SessionRules.OwnerName(bot, store.BotNames) : "All Bots";
    }

    /// The Mac's "All Bots" / "All Projects" menu: All, then each bot (or project), the picked one checked.
    private MenuFlyout ScopeMenu(SessionStore store)
    {
        var menu = new MenuFlyout();
        void Add(string text, bool on, Action pick)
        {
            var i = new ToggleMenuFlyoutItem { Text = text, IsChecked = on };
            i.Click += (_, _) => { pick(); Rebuild(); };
            menu.Items.Add(i);
        }
        if (store.Prefs.Pills == SessionPills.Projects)
        {
            var projects = store.ProjectEntries().Where(p => p.Key != SessionProjects.HomeKey).ToList();
            Add("All Projects", store.Prefs.ProjectFilter.Count == 0, () => store.Prefs.ProjectFilter.Clear());
            if (projects.Count > 0) menu.Items.Add(new MenuFlyoutSeparator());
            foreach (var p in projects) Add(p.Label, store.Prefs.ProjectFilter.SetEquals([p.Key]), () => OpenProject(p.Key));
        }
        else
        {
            Add("All Bots", store.BotFilter == null, () => store.BotFilter = null);
            menu.Items.Add(new MenuFlyoutSeparator());
            foreach (var b in _hub!.Bots.Rows.Where(b => !b.Hidden).OrderBy(b => b.Name, StringComparer.CurrentCultureIgnoreCase))
                Add(b.Name, store.BotFilter == b.Id, () => { store.BotFilter = b.Id; _ = store.RefreshAsync(); });
        }
        return menu;
    }

    // ------------------------------------------------------------------ the row under the bar

    private IReadOnlyList<SessionsHeaderRowPanel> _headerRows = [];
    private IReadOnlyList<double>? _headerIdeals;
    /// [WIN-SESSIONS-WORKING-CHIP] Which of the Mac's four drawings is showing (`SessionsHeaderRow.Variants`), for the walk.
    internal int HeaderVariant { get; private set; } = -1;

    /// The Mac's `macRow`: Chats | Projects, the view's menu, and "● 3 new" / "● 2 working" (each lists those chats alone;
    /// again: all). Not on a project's page, whose header says its own. Four drawings are built; the first that fits shows.
    private void DrawHeader(SessionStore store, SessionListInput input, bool onPage)
    {
        var counts = new List<(SessionStatusChip, int, bool, Action)>();
        if (SessionsHeaderRow.ShowsCounts(onPage))
        {
            var numbers = SessionListPipeline.ChipCounts(input);
            foreach (var chip in Enum.GetValues<SessionStatusChip>())
            {
                var n = numbers[chip];
                if (n == 0 && store.StatusChip != chip) continue;
                var c = chip;
                counts.Add((c, n, store.StatusChip == c, () => { store.StatusChip = store.StatusChip == c ? null : c; Rebuild(); }));
            }
        }
        var projects = store.Prefs.Pills == SessionPills.Projects;
        var header = new SessionsHeaderInput(true, projects,
            () => { if (projects) ChatsSwitch_Click(this, new RoutedEventArgs()); else ProjectsSwitch_Click(this, new RoutedEventArgs()); },
            ScopeWords(store), () => ScopeMenu(store), counts);
        var (leading, trailing) = SessionsHeaderRow.Insets(RowInset, SessionsHeaderRow.MenuEndsRow(true, onPage, counts.Count));
        HeaderHost.Margin = new Thickness(leading, 0, trailing, 0);
        HeaderHost.Child = null;
        _headerRows = [.. SessionsHeaderRow.Variants.Select(v => SessionsHeaderBar.Build(header, v))];
        _headerIdeals = null;
        PlaceHeader();
    }

    /// The list rows' own room either side (each ListViewItem's padding): the row's edges stand on theirs.
    private const double RowInset = 6;

    private void HeaderHost_SizeChanged(object sender, SizeChangedEventArgs e) => PlaceHeader();

    /// `ViewThatFits`: the first drawing whose ideal width fits the row, else the last.
    private void PlaceHeader()
    {
        if (_headerRows.Count == 0) return;
        var width = HeaderHost.ActualWidth;
        if (width <= 0 || !HeaderHost.IsLoaded) { if (HeaderHost.Child == null) Show(0); return; }
        if (_headerIdeals == null || _headerIdeals.Any(w => w <= 0))
        {
            HeaderHost.Child = null;   // a drawing is measured in the probe, so none may stay in the row
            _headerIdeals = SessionsHeaderBar.Ideals(_headerRows, HeaderProbe);
        }
        Show(SessionsHeaderRow.Pick(_headerIdeals, width));

        void Show(int index)
        {
            if (HeaderVariant == index && HeaderHost.Child == _headerRows[index]) return;
            HeaderHost.Child = null;
            HeaderHost.Child = _headerRows[index];
            HeaderVariant = index;
        }
    }

    private void Empty(SessionStore store, SessionFilterState filter, bool empty)
    {
        ChatPlaceholder.Visibility = !empty && _openId == null ? Visibility.Visible : Visibility.Collapsed;
        ListEmpty.Visibility = empty && store.Loaded ? Visibility.Visible : Visibility.Collapsed;
        EmptyCompose.Visibility = EmptyClear.Visibility = RetryButton.Visibility = Visibility.Collapsed;
        if (!empty) return;
        if (store.Failure is { } failure)
        {
            ListEmptyTitle.Text = "Couldn’t Load Sessions";
            ListEmptyText.Text = failure;
            RetryButton.Visibility = Visibility.Visible;
        }
        else if (_query.Length > 0)
        {
            ListEmptyTitle.Text = "No Results";
            ListEmptyText.Text = $"No chats match “{_query}”.";
        }
        else if (store.BotFilter is { } bot && filter.Prefs.StatusFilter.Count == 0 && store.StatusChip == null)
        {
            var name = SessionRules.OwnerName(bot, store.BotNames);
            ListEmptyTitle.Text = $"{name} Has No Chats Yet";
            ListEmptyText.Text = $"New chats you start with {name} appear here.";
            EmptyCompose.Visibility = EmptyClear.Visibility = Visibility.Visible;
        }
        else if (SessionFilterWords.FiltersActive(filter) || store.StatusChip != null)
        {
            ListEmptyTitle.Text = "No Matching Chats";
            ListEmptyText.Text = "No chats match these filters.";
            EmptyClear.Visibility = Visibility.Visible;
        }
        else
        {
            ListEmptyTitle.Text = "No Chats Yet";
            ListEmptyText.Text = "Chats you start with your bots appear here.";
            EmptyCompose.Visibility = Visibility.Visible;
        }
    }

    private static Brush Res(string key) => ThemeBrushes.Get(key);

    private ListViewItem Make(Row row, SessionStore store)
    {
        UIElement view = row switch
        {
            HeaderRow h => HeaderView(h.Group),
            ProjectRow p => ProjectView(p.Group, store),
            MoreRow m => new TextBlock
            {
                Text = m.Group.Expanded ? "Show Less" : $"Show More ({m.Group.More})", FontSize = 13, Margin = new Thickness(30, 4, 0, 4),
                Foreground = Res("AccentTextFillColorPrimaryBrush"),
            },
            ChatRow c => ChatView(c, store),
            _ => new Border(),
        };
        var item = new ListViewItem { Content = view, Tag = row, Padding = new Thickness(6, 0, 6, 0), MinHeight = row is ChatRow ? DensitySizes.Sessions(ThemeService.State.Compact).Row : 26, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        if (row is MoreRow m2) Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(item, SessionRowWords.ShowMoreLabel(m2.Group.Expanded ? 0 : m2.Group.More));
        if (row is ProjectRow proj && SessionListPipeline.ProjectKey(proj.Group.Id) is { } projKey)
        {
            var projMenu = new MenuFlyout();
            var folder = projKey != SessionProjects.HomeKey && !projKey.StartsWith("id:") ? projKey : null;
            var pipelineItem = new MenuFlyoutItem { Text = "Open Coding Pipeline", Icon = new FontIcon { Glyph = "\uE943" } };
            pipelineItem.Click += (_, _) => HermesHQ.Features.Coding.CodingFeature.OpenProjectPipeline(
                new HermesHQ.Features.Coding.CodingProjectContext(projKey, proj.Group.Title, folder, proj.Group.Sessions));
            var repoItem = new MenuFlyoutItem { Text = "Project Repository…", Icon = new FontIcon { Glyph = "\uE8B7" } };
            repoItem.Click += (_, _) => HermesHQ.Features.Coding.CodingFeature.OpenProjectRepository(
                new HermesHQ.Features.Coding.CodingProjectContext(projKey, proj.Group.Title, folder, proj.Group.Sessions));
            var settingsItem = new MenuFlyoutItem { Text = "Project Settings…", Icon = new FontIcon { Glyph = "\uE713" } };
            settingsItem.Click += (_, _) => _ = HermesHQ.Features.Coding.CodingFeature.OpenProjectSettingsAsync(XamlRoot, projKey, proj.Group.Title, folder);
            projMenu.Items.Add(pipelineItem);
            projMenu.Items.Add(repoItem);
            projMenu.Items.Add(settingsItem);
            item.ContextFlyout = projMenu;
        }
        if (row is ChatRow chat)
        {
            var menu = new MenuFlyout();
            menu.Opening += (_, _) => _actions?.FillRowMenu(menu.Items, chat.Chat);
            item.ContextFlyout = menu;
            var detail = store.Prefs.ShownDetail;
            var timeText = chat.YesterdayGroup ? ListTime.FormatClock(chat.Chat.LastActive) : ListTime.Format(chat.Chat.LastActive);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(item, SessionRowWords.AccessibilityLabel(chat.Chat.Title, chat.Chat,
                SessionRules.OwnerName(chat.Chat.Profile, store.BotNames), detail, timeText,
                _hub?.Bots.MuteOf(chat.Chat.Profile, DateTimeOffset.UtcNow) != null));
        }
        return item;
    }

    private static UIElement HeaderView(SessionGroup g)
    {
        // [density] breakAbove: a caption stands closer under the group above it in Compact.
        var s = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Padding = new Thickness(0, DensitySizes.HeaderAbove(ThemeService.State.Compact), 0, 2) };
        s.Children.Add(new TextBlock { Text = g.Title, FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = Res("TextFillColorSecondaryBrush") });
        if (SessionListPipeline.Folds(g))
            s.Children.Add(new FontIcon { Glyph = g.Collapsed ? "" : "", FontSize = 9, Foreground = Res("TextFillColorTertiaryBrush") });
        if (g.Collapsed)
            s.Children.Add(new TextBlock
            {
                Text = g.Unread > 0 ? $"{g.Total} · {g.Unread} unread" : $"{g.Total}", FontSize = 12, Foreground = Res("TextFillColorTertiaryBrush"),
            });
        return s;
    }

    /// A project's row: its folder (a house for Home), name, count and ›, its unread count and newest time.
    private static UIElement ProjectView(SessionGroup g, SessionStore store)
    {
        // [density] ProjectCard: Compact's shorter row, smaller folder, callout name and narrower gap.
        var z = DensitySizes.Project(ThemeService.State.Compact);
        var grid = new Grid { ColumnSpacing = z.Gap, Padding = new Thickness(0, z.Pad, 0, z.Pad) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var home = SessionListPipeline.ProjectKey(g.Id) == SessionProjects.HomeKey;
        grid.Children.Add(new FontIcon { Glyph = home ? "" : "", FontSize = z.Folder, VerticalAlignment = VerticalAlignment.Center });
        var name = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        name.Children.Add(new TextBlock { Text = g.Title, FontSize = z.Name, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
        name.Children.Add(new TextBlock { Text = $"{g.Total}", Foreground = Res("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center });
        name.Children.Add(new FontIcon { Glyph = "", FontSize = 10, Foreground = Res("TextFillColorTertiaryBrush") });
        Grid.SetColumn(name, 1);
        grid.Children.Add(name);
        var trail = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        if (g.Unread > 0)
            trail.Children.Add(new Border
            {
                Background = Res("AccentFillColorDefaultBrush"), CornerRadius = new CornerRadius(8), Padding = new Thickness(6, 0, 6, 0),
                Child = new TextBlock { Text = $"{g.Unread}", FontSize = 11, Foreground = Res("TextOnAccentFillColorPrimaryBrush") },
            });
        trail.Children.Add(new TextBlock
        {
            Text = ListTime.Format(g.Newest), FontSize = 12,
            Foreground = Res(g.Unread > 0 ? "AccentTextFillColorPrimaryBrush" : "TextFillColorSecondaryBrush"),
        });
        Grid.SetColumn(trail, 2);
        grid.Children.Add(trail);
        return grid;
    }

    /// A chat: its bot's face (Show › Bot Faces), title (bold while unread), Row Detail's trailing words and the unread
    /// dot; the second line is its live state or (Row Detail › Preview) the preview.
    private static UIElement ChatView(ChatRow row, SessionStore store)
    {
        var s = row.Chat;
        var prefs = store.Prefs;
        var detail = prefs.ShownDetail;
        var owner = SessionRules.OwnerName(s.Profile, store.BotNames);
        // [density] macTight: Compact's shorter row and smaller face.
        var z = DensitySizes.Sessions(ThemeService.State.Compact);
        var grid = new Grid { ColumnSpacing = 10, Padding = new Thickness(0, z.Pad, 0, z.Pad) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (prefs.BotFaces)
            grid.Children.Add(new BotHead { DisplayName = owner, Width = z.Face, Height = z.Face, VerticalAlignment = VerticalAlignment.Center });
        var lines = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        lines.Children.Add(new TextBlock
        {
            Text = s.Title, TextTrimming = TextTrimming.CharacterEllipsis,
            FontWeight = s.Unread ? FontWeights.Bold : FontWeights.SemiBold,
        });
        var status = SessionRowWords.StatusWords(s.Status, s.Step);
        var second = status
            ?? (row.Recent && !detail.Contains(SessionRowDetail.Preview) ? null : SessionRowWords.DetailText(s, detail));
        if (status == null && s.Pending is { } pending && second != null)
        {
            // [WIN-LOST-SEND-MARKER] The pending line: its lead semibold, "Not Delivered:" red (SessionRowViews `secondLine`).
            var line = new TextBlock { FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis, Foreground = Res("TextFillColorSecondaryBrush") };
            if (!row.Recent) line.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = $"{owner} · " });
            line.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run
            {
                Text = pending.Prefix, FontWeight = FontWeights.SemiBold,
                Foreground = Res(pending.Failed ? "SystemFillColorCriticalBrush" : "TextFillColorPrimaryBrush"),
            });
            line.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = " " + pending.Text });
            lines.Children.Add(line);
        }
        else if (second != null)
            lines.Children.Add(new TextBlock
            {
                Text = row.Recent ? second : $"{owner} · {second}", FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis,
                Foreground = Res(s.Status is SessionStatus.NeedsInput ? "SystemFillColorCautionBrush"
                    : s.Status is SessionStatus.Working ? "AccentTextFillColorPrimaryBrush" : "TextFillColorSecondaryBrush"),
            });
        Grid.SetColumn(lines, 1);
        grid.Children.Add(lines);
        var trail = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        if (s.Pinned && !prefs.RecentRows) trail.Children.Add(new FontIcon { Glyph = "", FontSize = 10, Foreground = Res("TextFillColorTertiaryBrush") });
        if (s.Archived) trail.Children.Add(new FontIcon { Glyph = "", FontSize = 10, Foreground = Res("TextFillColorTertiaryBrush") });
        var timeLabel = row.YesterdayGroup ? ListTime.FormatClock(s.LastActive) : ListTime.Format(s.LastActive);
        if (SessionRowWords.Trailing(s, detail, timeLabel) is { } words)
            trail.Children.Add(new TextBlock { Text = words, FontSize = 12, Foreground = Res("TextFillColorSecondaryBrush") });
        if (s.Unread) trail.Children.Add(new Ellipse { Width = 7, Height = 7, Fill = Res("AccentFillColorDefaultBrush") });
        Grid.SetColumn(trail, 2);
        grid.Children.Add(trail);
        // [working-ring] The ring round a working chat while Working Ring is on; its "Working…" line stays either way.
        // [WIN-SESSIONS-WORKING-CHIP] Flush on the row's box at the sides (its RowInset of padding), in the Mac's row corner
        // (`WorkingArc.rowCorner`): the line seen at a working row's right edge is this ring's travelling spike.
        return WorkingRingView.Wrap(grid, WorkingRing.ShowsChatRing(s, WorkingRing.IsOn), new Thickness(RowInset, 1, RowInset, 1),
            WorkingRing.RowCorner(ThemeService.State.DesktopLook));
    }

    // ------------------------------------------------------------------ picks

    private void SessionList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (Store is not { } store) return;
        var row = (e.ClickedItem as ListViewItem)?.Tag as Row ?? SessionList.Items.OfType<ListViewItem>().FirstOrDefault(i => i.Content == e.ClickedItem)?.Tag as Row;
        switch (row)
        {
            case HeaderRow { Group: var g } when SessionListPipeline.Folds(g):
                if (g.Collapsed)
                {
                    store.OpenGroups.Add(g.Id);
                    store.SetCollapsed(g.Id, false);
                }
                else
                {
                    store.OpenGroups.Remove(g.Id);
                    store.SetCollapsed(g.Id, true);
                }
                break;
            case ProjectRow { Group: var g } when SessionListPipeline.ProjectKey(g.Id) is { } key:
                OpenProject(key);
                break;
            case MoreRow { Group: var g }:
                store.Toggle(store.ExpandedGroups, g.Id);
                break;
            case ChatRow { Chat: var s }:
                Open(s);
                break;
        }
    }

    /// A project's row opens its page: the project pill with that one project.
    private void OpenProject(string key)
    {
        if (Store is not { } store) return;
        if (store.Prefs.Pills != SessionPills.Projects) store.ApplyFilter(new(SessionFilterActionKind.Group, SessionGroupBy.Project), HomeBot);
        store.Prefs.ProjectFilter.Clear();
        store.Prefs.ProjectFilter.Add(key);
        _ = store.LoadArchivedAsync();
        store.Changed_();
    }

    private void PageBack_Click(object sender, RoutedEventArgs e)
    {
        Store?.Prefs.ProjectFilter.Clear();
        Store?.Changed_();
    }

    private void PageCompose_Click(object sender, RoutedEventArgs e)
    {
        if (Store is not { } store || _actions == null) return;
        var key = store.Prefs.ProjectFilter.FirstOrDefault();
        var profile = store.BotFilter ?? HomeBot;
        var folder = key != null && key != SessionProjects.HomeKey && !key.StartsWith("id:") ? key : null;
        _ = _actions.NewChatAsync(profile, folder);
    }

    private void Open(SessionSummary s)
    {
        if (Store is not { } store) return;
        var key = s.Profile + "/" + s.Id;
        if (key == _openId) return;
        _openId = key;
        store.Selected = (s.Profile, s.Id);
        store.KeepNew.Add(SessionListPipeline.Key(s));
        _ = store.OpenedAsync(s.Profile, s.Id);
        ChatPlaceholder.Visibility = Visibility.Collapsed;
        ChatFrame.Navigate(typeof(ChatPage), new ChatPage.Args(s.Profile, s.Id, s.Title), new SuppressNavigationTransitionInfo());
        ChatFrame.BackStack.Clear();
    }

    private void Filter_Click(object sender, RoutedEventArgs e) => _actions?.FilterMenu(HomeBot).ShowAt(FilterButton);

    private void SearchToggle_Click(object sender, RoutedEventArgs e)
    {
        var on = SearchBox.Visibility != Visibility.Visible;
        SearchBox.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        if (on) SearchBox.Focus(FocusState.Keyboard);
        else { SearchBox.Text = ""; _query = ""; Rebuild(); }
    }

    private void SearchBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        _query = SearchBox.Text.Trim();
        Rebuild();
    }

    private void ChatsSwitch_Click(object sender, RoutedEventArgs e)
    {
        if (Store is { } store && store.Prefs.Pills != SessionPills.Bots) store.ApplyFilter(new(SessionFilterActionKind.Group, SessionGroupBy.Date), HomeBot);
        else Rebuild();
    }

    private void ProjectsSwitch_Click(object sender, RoutedEventArgs e)
    {
        if (Store is not { } store) return;
        if (store.Prefs.Pills != SessionPills.Projects)
        {
            store.ApplyFilter(new(SessionFilterActionKind.Group, SessionGroupBy.Project), HomeBot);
            _ = store.LoadProjectsAsync();
            _ = store.LoadArchivedAsync();
        }
        else Rebuild();
    }

    private void StripClear_Click(object sender, RoutedEventArgs e)
    {
        if (Store is not { } store) return;
        store.Prefs.StatusFilter.Clear();
        if (store.Prefs.Pills != SessionPills.Projects) store.Prefs.ProjectFilter.Clear();
        store.StatusChip = null;
        if (ReferenceEquals(sender, EmptyClear)) store.BotFilter = null;
        store.ApplyFilter(new(SessionFilterActionKind.Sort, store.Prefs.SortBy), HomeBot);   // keeps and redraws
    }

    /// Compose (and the empty page's New Chat): the one New Chat sheet, lit on the picked chip's bot, as the Mac's
    /// `compose(profile: pickedBot, asksProject: true)` (Features/NewChat).
    private void Compose_Click(object sender, RoutedEventArgs e)
    {
        if (Store is { } store) HermesHQ.Features.NewChat.NewChatSheet.Show(XamlRoot, store.BotFilter, asksProject: true);
    }

    private void Refresh_Click(object sender, RoutedEventArgs e) => _ = Store?.RefreshAsync();

    /// View › Refresh (Ctrl+R, F5): the list's refresh, as its Refresh button.
    public void KeyRefresh() => _ = Store?.RefreshAsync();
}
