using Hermes.Core.Coding;
using Hermes.Core.Sessions;
using HermesHQ.Features.Bots;
using HermesHQ.Features.Kanban;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using Windows.UI;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.Coding;

/// Calm 4-bucket shipping pipeline page for a coding project (`App/Sessions/ProjectPage.swift`, `3e7f6374a`/`1f3a49712`/`997919566`):
/// single calm segmented 4-bucket header strip (`Ready`, `Needs You`, `Active`, `Shipped` collapsed by default),
/// honoring header toggles across `Needs Me First`, `By Status`, and `Newest` sorts, PR verdict badges, and side PR Card inspector.
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class CodingPipelinePage : Page, IKeyRefreshing
{
    private readonly Microsoft.UI.Dispatching.DispatcherQueue _ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
    private readonly CodingStore _store;
    private CodingProjectContext _project = new("default", "Coding Pipeline");
    private List<SessionSummary> _sessions = [];
    private ProjectPageSort _sort = ProjectPageSort.NeedsMeFirst;
    private CodingPipelineFilter _filter = new();
    private readonly HashSet<string> _expandedCollapsedSections = [];
    private string? _selectedSessionKey;

    private readonly TextBlock _pageTitle = new() { Text = "Coding Pipeline", VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBox _searchBox = new() { PlaceholderText = "Filter branches, PRs, titles", Width = 220, VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel _headerArea = new() { Spacing = 8, Padding = new Thickness(16, 4, 16, 8) };
    private readonly StackPanel _list = new() { Spacing = 4, Padding = new Thickness(16, 4, 16, 24) };
    private readonly ContentControl _paneHost = new() { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private readonly Border _pane;
    private readonly NoticeLine _notice = new();
    private bool _loading;

    public CodingPipelinePage()
    {
        _store = CodingFeature.GetStore();
        AutomationProperties.SetName(this, "Coding Pipeline");
        AutomationProperties.SetAutomationId(this, "coding.pipeline");

        HermesHQ.Shell.PageBar.Title(_pageTitle, "coding-pipeline");
        _searchBox.TextChanged += (_, _) => { _filter = _filter with { SearchQuery = _searchBox.Text }; Render(); };
        AutomationProperties.SetAutomationId(_searchBox, "coding.pipeline.search");

        var refreshBtn = new Button { Content = new FontIcon { Glyph = "\uE72C", FontSize = 14 }, Style = Style("QuietButtonStyle") };
        ToolTipService.SetToolTip(refreshBtn, "Refresh PR Status");
        AutomationProperties.SetName(refreshBtn, "Refresh PR Status");
        refreshBtn.Click += (_, _) => _ = RefreshAsync(fresh: true);

        var moreBtn = new Button { Content = new FontIcon { Glyph = "\uE712", FontSize = 14 }, Style = Style("QuietButtonStyle") };
        AutomationProperties.SetName(moreBtn, "Project Actions");
        var moreMenu = new MenuFlyout { Placement = FlyoutPlacementMode.BottomEdgeAlignedRight };
        moreMenu.Opening += (_, _) => FillMoreMenu(moreMenu);
        moreBtn.Flyout = moreMenu;

        var tools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        tools.Children.Add(_searchBox);
        tools.Children.Add(refreshBtn);
        tools.Children.Add(moreBtn);

        var bar = new Grid { Padding = HermesHQ.Shell.PageBar.Padding(12, 4), ColumnSpacing = 10 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.Children.Add(_pageTitle);
        Grid.SetColumn(tools, 1);
        bar.Children.Add(tools);

        var left = new Grid();
        left.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        left.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        left.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        left.Children.Add(bar);
        Grid.SetRow(_headerArea, 1);
        left.Children.Add(_headerArea);
        var scroller = new ScrollViewer { Content = _list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Disabled };
        Grid.SetRow(scroller, 2);
        left.Children.Add(scroller);
        Grid.SetRow(_notice.Bar, 2);
        left.Children.Add(_notice.Bar);

        _pane = new Border
        {
            Width = 460,
            Visibility = Visibility.Collapsed,
            Child = _paneHost,
            BorderThickness = new Thickness(1, 0, 0, 0),
            BorderBrush = Brush("DividerStrokeColorDefaultBrush"),
            Background = Brush("LayerFillColorDefaultBrush"),
        };

        var root = new Grid();
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        root.Children.Add(left);
        Grid.SetColumn(_pane, 1);
        root.Children.Add(_pane);
        Content = root;
    }

    public void KeyRefresh() => _ = RefreshAsync(fresh: true);

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (e.Parameter is PlaceArgs { Argument: CodingProjectContext ctx })
        {
            _project = ctx;
            if (ctx.Sessions != null) _sessions = [.. ctx.Sessions.Where(s => !SessionListPipeline.IsHiddenTileChat(s))];
        }
        else if (e.Parameter is CodingProjectContext directCtx)
        {
            _project = directCtx;
            if (directCtx.Sessions != null) _sessions = [.. directCtx.Sessions.Where(s => !SessionListPipeline.IsHiddenTileChat(s))];
        }
        _store.Changed += OnStoreChanged;
        Render();
        _ = RefreshAsync(fresh: false);
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        _store.Changed -= OnStoreChanged;
        UiTree.DeactivateProgressRings(_headerArea);
        UiTree.DeactivateProgressRings(_list);
    }

    private void OnStoreChanged() => _ui.TryEnqueue(Render);

    private async Task RefreshAsync(bool fresh)
    {
        _loading = true;
        Render();
        try
        {
            await _store.RefreshReposAsync();
            var settings = _store.SettingsFor(_project.ProjectKey);
            if (settings.CodingProject && _store.RepoFor(_project.ProjectKey) == null && !_store.HasAutoLinkFailed(_project.ProjectKey))
                await _store.LinkOwnFolderIfUnlinkedAsync(_project.ProjectKey, _project.RootFolder);

            if (_sessions.Count == 0 && AppState.Client is { } client)
            {
                try
                {
                    var sidebar = await client.SessionsAsync();
                    var projectRoot = RepoPathHelpers.NormalizeFolderPath(_project.RootFolder);
                    _sessions = [.. sidebar.Recents.Rows
                        .Select(r => new SessionSummary
                        {
                            Id = r.Id,
                            Profile = r.Profile,
                            Title = r.Title,
                            Preview = r.Preview,
                            LastActive = r.LastActive,
                            Source = r.Source,
                            Unread = r.Unread,
                            Pinned = r.Pinned,
                            Archived = r.Archived,
                            Model = r.Model,
                            MessageCount = r.MessageCount,
                            Cwd = r.Cwd,
                            Branch = r.Branch,
                        })
                        .Where(s => !SessionListPipeline.IsHiddenTileChat(s) && MatchesProject(s, projectRoot))];
                }
                catch (Exception ex)
                {
                    AppLog.Note("coding", $"sidebar read skipped: {ex.GetType().Name}");
                }
            }

            if (_sessions.Count > 0)
            {
                var targets = _sessions.Select(s => (s.Profile, s.Id)).Take(50).ToList();
                await _store.RefreshPRStatusAsync(targets, fresh: fresh, detail: targets.Count <= 4);
            }
        }
        finally
        {
            _loading = false;
            Render();
        }
    }

    private bool MatchesProject(SessionSummary session, string normalizedRoot)
    {
        if (string.IsNullOrEmpty(normalizedRoot) || _project.ProjectKey == "default") return true;
        if (ListsHub.Current?.Sessions.ProjectsByProfile is { Count: > 0 } byProfile
            && string.Equals(SessionProjects.KeyOf(session.Cwd, session.Profile, byProfile), _project.ProjectKey, StringComparison.Ordinal))
            return true;
        var cwd = RepoPathHelpers.NormalizeFolderPath(session.Cwd);
        return cwd.Equals(normalizedRoot, StringComparison.OrdinalIgnoreCase)
            || cwd.StartsWith(normalizedRoot + "/", StringComparison.OrdinalIgnoreCase)
            || cwd.StartsWith(normalizedRoot + "\\", StringComparison.OrdinalIgnoreCase);
    }

    private void Render()
    {
        var settings = _store.SettingsFor(_project.ProjectKey);
        var repo = _store.RepoFor(_project.ProjectKey);
        var prefix = !string.IsNullOrWhiteSpace(settings.Look.Emoji) ? settings.Look.Emoji + " " : "";
        _pageTitle.Text = prefix + _project.Label;

        RenderHeader(settings, repo);
        RenderList(settings);
        RenderSelectedPane();
    }

    private void RenderHeader(ProjectSettings settings, SessionPRRepo? repo)
    {
        UiTree.DeactivateProgressRings(_headerArea);
        _headerArea.Children.Clear();
        var bucketCounts = CodingPipelineEngine.ComputeBucketCounts(_sessions, _store.Statuses, _filter.FilterByBot, _filter.SearchQuery);

        // Project header card (`ProjectPage.swift` `codingPipelineBar`).
        var cardStack = new StackPanel { Spacing = 10 };
        var topRow = new Grid { ColumnSpacing = 12 };
        topRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        topRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var metaParts = new List<string>();
        var folderShown = RepoPathHelpers.ShortFolder(repo?.Path ?? _project.RootFolder);
        if (!string.IsNullOrWhiteSpace(folderShown)) metaParts.Add(folderShown);
        if (repo?.PublicRepo is { Length: > 0 } pub) metaParts.Add(pub);
        if (!string.IsNullOrWhiteSpace(repo?.Main)) metaParts.Add(repo.Main);
        var bots = _sessions.Select(s => BotName(s.Profile)).Distinct(StringComparer.Ordinal).Take(3).ToList();
        if (bots.Count > 0) metaParts.Add(string.Join(", ", bots));
        var metaText = metaParts.Count > 0 ? string.Join(" · ", metaParts) : "No linked repository yet";

        var metaLabel = Text(metaText, 12, color: Secondary, wrap: false);
        metaLabel.VerticalAlignment = VerticalAlignment.Center;
        topRow.Children.Add(metaLabel);

        var rightControls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        if (_loading) rightControls.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
        rightControls.Children.Add(BuildSortPicker());
        rightControls.Children.Add(BuildBotPicker());
        Grid.SetColumn(rightControls, 1);
        topRow.Children.Add(rightControls);
        cardStack.Children.Add(topRow);

        // Calm, lineless 4-bucket segmented shipping pipeline strip (`Ready` / `Needs You` / `Active` / `Shipped`).
        cardStack.Children.Add(BuildPipelineBar(bucketCounts));

        _headerArea.Children.Add(Card(cardStack, 12));

        // Quiet inline coding health banner (`ProjectPage.swift` `projectCodingHealth`).
        var rowStatuses = _sessions.Select(s => CodingPipelineEngine.ResolvePR(s, _store.Statuses)).ToList();
        if (CodingPipelineEngine.Health(
                settings.CodingProject || repo != null,
                repo,
                _store.ReposState,
                _store.HasAutoLinkFailed(_project.ProjectKey),
                _store.IsPRRouteUnsupported,
                rowStatuses) is { } health)
        {
            var bannerGrid = new Grid { ColumnSpacing = 12 };
            bannerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            bannerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var textStack = new StackPanel { Spacing = 2 };
            textStack.Children.Add(Text(health.Title, 13, bold: true));
            if (!string.IsNullOrWhiteSpace(health.Detail))
                textStack.Children.Add(Text(health.Detail, 12, color: Secondary));
            bannerGrid.Children.Add(textStack);
            if (health.ActionLabel != null)
            {
                var actionLabel = health.ActionLabel;
                var action = Push(actionLabel, () =>
                {
                    if (actionLabel == "Retry") _ = RefreshAsync(fresh: true);
                    else CodingFeature.OpenProjectRepository(_project);
                });
                action.VerticalAlignment = VerticalAlignment.Center;
                Grid.SetColumn(action, 1);
                bannerGrid.Children.Add(action);
            }
            _headerArea.Children.Add(Card(bannerGrid, 10));
        }
    }

    private Grid BuildPipelineBar(IReadOnlyDictionary<CodingPipelineBucket, int> counts)
    {
        var grid = new Grid { ColumnSpacing = 6 };
        for (var i = 0; i < CodingPipeline.AllBuckets.Count; i++)
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        for (var i = 0; i < CodingPipeline.AllBuckets.Count; i++)
        {
            var bucket = CodingPipeline.AllBuckets[i];
            var count = counts.GetValueOrDefault(bucket);
            var picked = _filter.SelectedBucket == bucket;
            var dim = count == 0 && !picked;
            var dotColor = bucket switch
            {
                CodingPipelineBucket.Ready => (Color?)Green,
                CodingPipelineBucket.NeedsYou => Orange,
                _ => null,
            };

            var countRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5, HorizontalAlignment = HorizontalAlignment.Center };
            if (dotColor is { } c && count > 0)
                countRow.Children.Add(Dot(c, 6));
            countRow.Children.Add(Text(
                count.ToString(),
                15,
                bold: true,
                color: dim ? Tertiary : bucket == CodingPipelineBucket.Shipped && !picked ? Secondary : null,
                wrap: false));

            var stack = new StackPanel { Spacing = 2, HorizontalAlignment = HorizontalAlignment.Center };
            stack.Children.Add(countRow);
            stack.Children.Add(Text(bucket.Label(), 11, bold: picked, color: picked ? null : Secondary, wrap: false));

            var spoken = $"{bucket.SectionTitle()}, {count} {(count == 1 ? "chat" : "chats")}";
            var seg = new ToggleButton
            {
                Content = stack,
                IsChecked = picked,
                IsEnabled = !dim,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Center,
                Padding = new Thickness(6, 6, 6, 6),
                CornerRadius = new CornerRadius(8),
                BorderThickness = new Thickness(1),
                BorderBrush = picked ? Brush("TextFillColorSecondaryBrush") : Solid(Microsoft.UI.Colors.Transparent),
                Background = picked ? Brush("SubtleFillColorSecondaryBrush") : Solid(Microsoft.UI.Colors.Transparent),
            };
            ToolTipService.SetToolTip(seg, spoken);
            AutomationProperties.SetName(seg, spoken);
            AutomationProperties.SetAutomationId(seg, $"coding.pipeline.bucket.{bucket.ToString().ToLowerInvariant()}");
            var pickedBucket = bucket;
            seg.Click += (_, _) =>
            {
                _filter = _filter with { SelectedBucket = _filter.SelectedBucket == pickedBucket ? null : pickedBucket };
                Render();
            };

            Grid.SetColumn(seg, i);
            grid.Children.Add(seg);
        }

        return grid;
    }

    private DropDownButton BuildSortPicker()
    {
        var menu = new MenuFlyout();
        foreach (var sort in new[] { ProjectPageSort.NeedsMeFirst, ProjectPageSort.ByStatus, ProjectPageSort.Newest })
        {
            var picked = sort;
            var item = new RadioMenuFlyoutItem
            {
                Text = CodingPipelineEngine.SortLabel(picked),
                GroupName = "coding-sort",
                IsChecked = _sort == picked,
            };
            item.Click += (_, _) => { _sort = picked; Render(); };
            menu.Items.Add(item);
        }
        var btn = new DropDownButton { Content = CodingPipelineEngine.SortLabel(_sort), Flyout = menu };
        AutomationProperties.SetAutomationId(btn, "coding.pipeline.sort");
        return btn;
    }

    private DropDownButton BuildBotPicker()
    {
        var bots = _sessions.Select(s => s.Profile).Distinct(StringComparer.Ordinal).OrderBy(p => p, StringComparer.Ordinal).ToList();
        var menu = new MenuFlyout();
        var allItem = new RadioMenuFlyoutItem { Text = "All Bots", GroupName = "coding-bot", IsChecked = _filter.FilterByBot == null };
        allItem.Click += (_, _) => { _filter = _filter with { FilterByBot = null }; Render(); };
        menu.Items.Add(allItem);
        foreach (var profile in bots)
        {
            var p = profile;
            var item = new RadioMenuFlyoutItem
            {
                Text = BotName(p),
                GroupName = "coding-bot",
                IsChecked = string.Equals(_filter.FilterByBot, p, StringComparison.OrdinalIgnoreCase),
            };
            item.Click += (_, _) => { _filter = _filter with { FilterByBot = p }; Render(); };
            menu.Items.Add(item);
        }
        var label = _filter.FilterByBot != null ? BotName(_filter.FilterByBot) : "All Bots";
        var btn = new DropDownButton { Content = label, Flyout = menu };
        AutomationProperties.SetAutomationId(btn, "coding.pipeline.bot-filter");
        return btn;
    }

    private void RenderList(ProjectSettings settings)
    {
        UiTree.DeactivateProgressRings(_list);
        _list.Children.Clear();
        var sections = CodingPipelineEngine.BuildBucketSections(_sessions, _store.Statuses, _sort, _filter);
        if (sections.Count == 0)
        {
            var empty = new StackPanel { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(24, 48, 24, 24), MaxWidth = 420 };
            empty.Children.Add(new FontIcon { Glyph = "\uE943", FontSize = 32, Foreground = Tertiary });
            var heading = Text(_sessions.Count == 0 ? "No Coding Sessions Yet" : "No Matching Chats", 16, bold: true);
            heading.TextAlignment = TextAlignment.Center;
            empty.Children.Add(heading);
            var sub = Text(_sessions.Count == 0
                ? "Start a coding chat in this project or link its Git repository to track branches, CI checks, and reviews."
                : "Tap the selected pipeline bucket or adjust your bot filter above to see all chats.", 13, color: Secondary);
            sub.TextAlignment = TextAlignment.Center;
            empty.Children.Add(sub);
            _list.Children.Add(empty);
            return;
        }

        foreach (var section in sections)
        {
            var collapsed = section.CollapsedByDefault && !_expandedCollapsedSections.Contains(section.Id);
            _list.Children.Add(SectionHeader(section, collapsed));
            if (collapsed) continue;
            foreach (var row in section.Rows)
                _list.Children.Add(SessionPipelineRow(row, settings));
        }
    }

    private FrameworkElement SectionHeader(CodingBucketSection section, bool collapsed)
    {
        var grid = new Grid { Margin = new Thickness(4, 12, 4, 4) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var left = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        if (section.Bucket is { } b && BucketDotColor(b) is { } dotColor)
            left.Children.Add(Dot(dotColor, 7));
        left.Children.Add(Text(section.Title, 14, bold: true));
        left.Children.Add(Text(section.Rows.Count.ToString(), 13, color: Secondary));
        grid.Children.Add(left);

        if (section.CollapsedByDefault)
        {
            var fold = new HyperlinkButton { Content = collapsed ? "Show" : "Hide", Padding = new Thickness(8, 0, 0, 0) };
            fold.Click += (_, _) =>
            {
                if (!_expandedCollapsedSections.Add(section.Id)) _expandedCollapsedSections.Remove(section.Id);
                Render();
            };
            Grid.SetColumn(fold, 1);
            grid.Children.Add(fold);
        }
        return grid;
    }

    private FrameworkElement SessionPipelineRow(CodingBucketRow row, ProjectSettings settings)
    {
        var grid = new Grid { ColumnSpacing = 12, Padding = new Thickness(10, 8, 10, 8) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        grid.Children.Add(Dot(BucketColor(row.Bucket), 9));

        var center = new StackPanel { Spacing = 2 };
        var titleLine = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        titleLine.Children.Add(Text(
            row.PrStatus?.Title ?? row.Session.Title,
            14,
            bold: row.Session.Unread || row.Bucket is CodingPipelineBucket.Ready or CodingPipelineBucket.NeedsYou,
            wrap: false));
        if (row.PrStatus?.Number is { } num)
            titleLine.Children.Add(Text($"#{num}", 12, color: Secondary, wrap: false));
        center.Children.Add(titleLine);

        var detailParts = new List<string>();
        if (settings.Look.ShowBranchOnRows && !string.IsNullOrWhiteSpace(row.Branch)) detailParts.Add(row.Branch!);
        detailParts.Add(BotName(row.Session.Profile));
        if (row.Session.Status == SessionStatus.NeedsInput) detailParts.Add("Needs your input");
        else if (row.Session.IsRunning || row.Session.Status == SessionStatus.Working) detailParts.Add(row.Session.Step ?? "Working…");
        if (row.PrStatus?.ReviewVerdict is { } rv and not PRReviewVerdict.None) detailParts.Add(rv.LabelWord());
        if ((row.PrStatus?.CommentsCount ?? 0) > 0) detailParts.Add($"{row.PrStatus!.CommentsCount} comments");
        center.Children.Add(Text(string.Join(" · ", detailParts), 12, color: Secondary, wrap: false));

        Grid.SetColumn(center, 1);
        grid.Children.Add(center);

        var trailing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        if (row.IsReadyToMerge && row.PrStatus?.Number is { } readyNum)
            trailing.Children.Add(BadgePill($"\u2713 #{readyNum}", Green));
        else if (row.HasFailingChecks)
        {
            var failed = Math.Max(1, row.PrStatus?.Checks?.Failed ?? 1);
            var label = row.PrStatus?.Number is { } fn ? $"\u2715 #{fn} · {failed} failed" : $"\u2715 {failed} failed";
            trailing.Children.Add(BadgePill(label, Red));
        }
        else if (row.Verdict is { } verdict)
            trailing.Children.Add(VerdictPill(verdict));
        else if (row.PrStatus?.DrawsMark == true && !(row.PrStatus.State == SessionPRState.Unknown && row.PrStatus.UnknownReason == SessionPRUnknownReason.Unmatched))
            trailing.Children.Add(BadgePill(row.PrStatus.Label, BucketColor(row.Bucket)));

        if ((row.IsReadyToMerge || row.HasFailingChecks) && row.PrStatus?.Size is { } size)
            trailing.Children.Add(Text(size.FormattedDelta, 12, color: Tertiary, wrap: false));

        var openChat = Quiet("Chat", () => Navigator.Go(new ChatDestination(row.Session.Profile, row.Session.Id, row.Session.Title)));
        trailing.Children.Add(openChat);
        Grid.SetColumn(trailing, 2);
        grid.Children.Add(trailing);

        var selected = _selectedSessionKey == row.Session.Key;
        var card = new Border
        {
            Child = grid,
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(1),
            BorderBrush = selected ? Accent : Brush("CardStrokeColorDefaultBrush"),
            Background = selected ? AccentWash(0.10) : Brush("CardBackgroundFillColorDefaultBrush"),
            Margin = new Thickness(0, 2, 0, 2),
        };
        AutomationProperties.SetAutomationId(card, "coding.row." + row.Session.Id);

        // Quick right-click PR actions (Merge PR… / Fix Failing Checks…) with confirm + direct delivery.
        if (row.PrStatus is { DrawsMark: true } pr)
        {
            var rowMenu = new MenuFlyout();
            rowMenu.Opening += (_, _) => FillRowContextMenu(rowMenu, row.Session, pr);
            card.ContextFlyout = rowMenu;
        }

        card.Tapped += (_, _) =>
        {
            _selectedSessionKey = row.Session.Key;
            _ = _store.RefreshPRStatusAsync([(row.Session.Profile, row.Session.Id)], fresh: false, detail: true);
            Render();
        };
        return card;
    }

    private void FillRowContextMenu(MenuFlyout menu, SessionSummary session, SessionPRStatus pr)
    {
        menu.Items.Clear();
        var botName = BotName(session.Profile);
        var chatWorking = session.IsRunning || session.Status == SessionStatus.Working;
        var card = PullRequestCardModel.Build(session, pr, botName: botName, chatWorking: chatWorking);
        var comments = CodingFeature.GetCommentStore(session.Key);

        if (CodingPipeline.IsReadyToMerge(session, pr)
            && card.Actions.FirstOrDefault(a => a.Kind == PullRequestQuickAction.Merge) is { } mergeAction)
        {
            var merge = new MenuFlyoutItem { Text = "Merge PR…", Icon = new FontIcon { Glyph = "\uE73E" } };
            merge.Click += (_, _) => _ = HandleActionAsync(session, pr, mergeAction, comments);
            menu.Items.Add(merge);
        }
        else if (CodingPipeline.HasFailingChecks(session, pr)
            && card.Actions.FirstOrDefault(a => a.Kind == PullRequestQuickAction.AskBotToFixCI) is { } fixAction)
        {
            var fix = new MenuFlyoutItem { Text = "Fix Failing Checks…", Icon = new FontIcon { Glyph = "\uE90F" } };
            fix.Click += (_, _) => _ = HandleActionAsync(session, pr, fixAction, comments);
            menu.Items.Add(fix);
        }
        else if (card.Actions.FirstOrDefault(a => a.Kind == PullRequestQuickAction.AskBotToOpenPR) is { } openPrAction)
        {
            var openPr = new MenuFlyoutItem { Text = openPrAction.Label + "…", Icon = new FontIcon { Glyph = "\uE943" } };
            openPr.Click += (_, _) => _ = HandleActionAsync(session, pr, openPrAction, comments);
            menu.Items.Add(openPr);
        }

        var openChat = new MenuFlyoutItem { Text = "Open Chat", Icon = new FontIcon { Glyph = "\uE8BD" } };
        openChat.Click += (_, _) => Navigator.Go(new ChatDestination(session.Profile, session.Id, session.Title));
        menu.Items.Add(openChat);
    }

    private void RenderSelectedPane()
    {
        if (_selectedSessionKey == null || _sessions.FirstOrDefault(s => s.Key == _selectedSessionKey) is not { } session)
        {
            _pane.Visibility = Visibility.Collapsed;
            _paneHost.Content = null;
            return;
        }
        var status = _store.StatusFor(session.Profile, session.Id)
            ?? session.PullRequest
            ?? new SessionPRStatus(SessionPRState.Unknown, SessionPRUnknownReason.Checking, Branch: session.Branch);
        var comments = CodingFeature.GetCommentStore(session.Key);
        _paneHost.Content = new PullRequestCardView(
            session,
            status,
            _store,
            comments,
            action => _ = HandleActionAsync(session, status, action, comments),
            onClose: () => { _selectedSessionKey = null; Render(); },
            botName: BotName(session.Profile),
            chatWorking: session.IsRunning || session.Status == SessionStatus.Working,
            onRepository: () => CodingFeature.OpenProjectRepository(_project));
        _pane.Visibility = Visibility.Visible;
    }

    private async Task HandleActionAsync(SessionSummary session, SessionPRStatus status, PullRequestActionItem action, DiffCommentStore comments)
    {
        var ok = await CodingFeature.ExecuteActionAsync(XamlRoot, session, status, action, _store, comments);
        if (ok) _notice.Show($"{action.Label.TrimEnd('…')} sent.");
    }

    private void FillMoreMenu(MenuFlyout menu)
    {
        menu.Items.Clear();
        var repoItem = new MenuFlyoutItem { Text = "Repository…", Icon = new FontIcon { Glyph = "\uE8B7" } };
        repoItem.Click += (_, _) => CodingFeature.OpenProjectRepository(_project);
        menu.Items.Add(repoItem);

        var settingsItem = new MenuFlyoutItem { Text = "Project Settings…", Icon = new FontIcon { Glyph = "\uE713" } };
        settingsItem.Click += async (_, _) =>
        {
            await CodingFeature.OpenProjectSettingsAsync(XamlRoot, _project.ProjectKey, _project.Label, _project.RootFolder, _store);
            Render();
        };
        menu.Items.Add(settingsItem);

        var settings = _store.SettingsFor(_project.ProjectKey);
        var codingToggle = new ToggleMenuFlyoutItem { Text = "Coding Project", IsChecked = settings.CodingProject };
        codingToggle.Click += (_, _) =>
        {
            var next = !settings.CodingProject;
            _store.SaveSettings(settings with { CodingProject = next });
            if (next) _ = _store.LinkOwnFolderIfUnlinkedAsync(_project.ProjectKey, _project.RootFolder);
        };
        menu.Items.Add(codingToggle);
    }

    internal static FrameworkElement VerdictPill(PRVerdict verdict)
    {
        var color = verdict.Tone switch
        {
            PRVerdictTone.Positive => Green,
            PRVerdictTone.Critical => Red,
            PRVerdictTone.Active => Blue,
            _ => Rgb(0x8E, 0x8E, 0x93),
        };
        return BadgePill(verdict.DisplayText, color);
    }

    internal static FrameworkElement BadgePill(string text, Color color) => new Border
    {
        CornerRadius = new CornerRadius(10),
        Padding = new Thickness(8, 2, 8, 2),
        Background = new SolidColorBrush(Color.FromArgb(28, color.R, color.G, color.B)),
        Child = Text(text, 12, bold: true, color: Solid(color), wrap: false),
        VerticalAlignment = VerticalAlignment.Center,
    };

    internal static Color? BucketDotColor(CodingPipelineBucket bucket) => bucket switch
    {
        CodingPipelineBucket.Ready => Green,
        CodingPipelineBucket.NeedsYou => Orange,
        _ => null,
    };

    internal static Color BucketColor(CodingPipelineBucket bucket) => bucket switch
    {
        CodingPipelineBucket.Ready => Green,
        CodingPipelineBucket.NeedsYou => Orange,
        CodingPipelineBucket.InFlight => Blue,
        CodingPipelineBucket.Shipped => Rgb(0xAF, 0x52, 0xDE),
        _ => Rgb(0x8E, 0x8E, 0x93),
    };

    internal static Color StageColor(CodingPipelineStage stage) => stage switch
    {
        CodingPipelineStage.NeedsAttention => Red,
        CodingPipelineStage.ReadyToMerge => Green,
        CodingPipelineStage.ChecksRunning => Blue,
        CodingPipelineStage.InReview => Orange,
        CodingPipelineStage.Draft => Rgb(0x8E, 0x8E, 0x93),
        CodingPipelineStage.Merged => Rgb(0xAF, 0x52, 0xDE),
        _ => Rgb(0x6C, 0x6C, 0x70),
    };
}
