using Hermes.Core.Jobs;
using HermesHQ.Controls;
using HermesHQ.Features.Artifacts;
using HermesHQ.Features.Settings;
using HermesHQ.Pages;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Navigation;
using Windows.ApplicationModel.DataTransfer;

namespace HermesHQ.Features.Jobs;

/// The Jobs place (App/Pages/Jobs/JobsViewController.swift + JobRowView.swift, docs/spec/1x-pages.md §3.4): the scope's
/// jobs in the web's sections (Needs Attention, Running, Scheduled, Paused, Completed folded), painted from the disk
/// cache, then read. A row: the bot's face, the title, the coloured lead and the schedule in words, when it runs next at
/// its trailing edge; click opens the job beside the list, right-click its menu (Run Now, Pause / Resume, Edit Job…,
/// Delete Job). The title bar: "Jobs", All Bots ⌄ with two bots or more, + (New Job), search. Blueprints follow the
/// jobs. With an argument (a job key) the place opens on that job.
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class JobsPage : Page
{
    private readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();
    private readonly StackPanel _list = new() { Padding = new Thickness(8, 0, 8, 16) };
    private readonly StackPanel _state = new() { Spacing = 8, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, MaxWidth = 280 };
    private readonly ProgressRing _loading = new() { IsActive = false, Width = 28, Height = 28 };
    private readonly Grid _pane = new();
    private readonly Grid _unopened = DetailPlaceholder.Make("No Job Open", "Choose a job from the list.");
    private readonly TextBox _search = new() { PlaceholderText = "Search Jobs", Visibility = Visibility.Collapsed, Margin = new Thickness(12, 0, 12, 8) };
    private readonly DropDownButton _scope = new() { Visibility = Visibility.Collapsed };
    private readonly Button _add, _magnifier;
    private readonly ColumnDefinition _listCol;
    private readonly Border _hud = new() { Visibility = Visibility.Collapsed };
    private readonly TextBlock _hudText = new() { FontSize = 13, FontWeight = FontWeights.SemiBold };
    private readonly DispatcherQueueTimer _clock, _hudTimer;
    private JobsStore? _store;
    private JobActions? _actions;
    private JobDetailView? _detail;
    private JobRunReader? _runReader;
    private JobsStore? _runReaderStore;
    private string? _selected;
    private bool _completedOpen, _reloadQueued;
    /// [WIN-JOBS-ROW-FIT] Held so its TextScaleFactorChanged keeps firing: the rows refit when the text size changes.
    private readonly Windows.UI.ViewManagement.UISettings _uiSettings = new();

    public JobsPage()
    {
        var root = new Grid();
        // Mac Jobs list: 340 DIPs on standard desktop panes (matching Sessions), narrowing to 247 DIPs on compact panes.
        _listCol = new ColumnDefinition { Width = new GridLength(340), MinWidth = 247 };
        root.ColumnDefinitions.Add(_listCol);
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        root.SizeChanged += (_, _) => _listCol.Width = new GridLength(root.ActualWidth >= 740 ? 340 : 247);

        var left = new Grid { BorderBrush = JobsUi.Brush("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(0, 0, 1, 0) };
        left.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        left.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        left.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        // [WIN-50] The Mac's page bar (MacWindow.pageBar, Shell/PageBar.cs): the page-title token, the page's side, and
        // the items as the Mac reads them with more than one bot (JobRowView.swift `update(scope:)`):
        // All Bots ⌄ · New Job · Search at the edge.
        var bar = new Grid { Padding = HermesHQ.Shell.PageBar.Padding(12, 8) };
        var title = new TextBlock { Text = "Jobs", VerticalAlignment = VerticalAlignment.Center };
        HermesHQ.Shell.PageBar.Title(title, "jobs");
        bar.Children.Add(title);
        var tools = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Spacing = 2 };
        AutomationProperties.SetAutomationId(_scope, "jobs.scope");
        tools.Children.Add(_scope);
        _add = JobsUi.Quiet(JobsUi.Glyph("", Hermes.Core.Shell.DesktopLook.BarGlyph), "New Job", (_, _) => _actions?.NewJob());
        AutomationProperties.SetAutomationId(_add, "jobs.new");
        tools.Children.Add(_add);
        _magnifier = JobsUi.Quiet(JobsUi.Glyph("", Hermes.Core.Shell.DesktopLook.BarGlyph), "Search Jobs", (_, _) => ToggleSearch());
        AutomationProperties.SetAutomationId(_magnifier, "jobs.search");
        tools.Children.Add(_magnifier);
        bar.Children.Add(tools);
        left.Children.Add(bar);
        AutomationProperties.SetName(_search, "Search Jobs");
        _search.TextChanged += (_, _) => Reload();
        _search.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Escape) { _search.Text = ""; ToggleSearch(); } };
        Grid.SetRow(_search, 1);
        left.Children.Add(_search);
        var scroll = new ScrollViewer { Content = _list };
        Grid.SetRow(scroll, 2);
        left.Children.Add(scroll);
        Grid.SetRow(_state, 2);
        left.Children.Add(_state);
        Grid.SetRow(_loading, 2);
        left.Children.Add(_loading);
        root.Children.Add(left);

        _unopened.Visibility = Visibility.Collapsed;
        Grid.SetColumn(_unopened, 1);
        root.Children.Add(_unopened);
        Grid.SetColumn(_pane, 1);
        root.Children.Add(_pane);

        _hud.Child = _hudText;
        _hud.Padding = new Thickness(16, 8, 16, 8);
        _hud.CornerRadius = new CornerRadius(18);
        _hud.Background = JobsUi.Brush("SystemControlAcrylicElementBrush");
        _hud.BorderBrush = JobsUi.Brush("CardStrokeColorDefaultBrush");
        _hud.BorderThickness = new Thickness(1);
        _hud.HorizontalAlignment = HorizontalAlignment.Center;
        _hud.VerticalAlignment = VerticalAlignment.Bottom;
        _hud.Margin = new Thickness(0, 0, 0, 24);
        AutomationProperties.SetLiveSetting(_hud, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        Grid.SetColumnSpan(_hud, 2);
        root.Children.Add(_hud);
        Content = root;

        // The rows' "in 12 min" and "2h late" move with the clock.
        _clock = _ui.CreateTimer();
        _clock.Interval = TimeSpan.FromSeconds(30);
        _clock.Tick += (_, _) => { if (!AppShutdown.Stopping && IsLoaded) Reload(); };
        _hudTimer = _ui.CreateTimer();
        _hudTimer.IsRepeating = false;
        _hudTimer.Tick += (_, _) => { if (!AppShutdown.Stopping) _hud.Visibility = Visibility.Collapsed; };
        Loaded += (_, _) =>
        {
            _uiSettings.TextScaleFactorChanged -= OnTextScaleChanged;
            _uiSettings.TextScaleFactorChanged += OnTextScaleChanged;
        };
        Unloaded += (_, _) =>
        {
            _uiSettings.TextScaleFactorChanged -= OnTextScaleChanged;
            _clock.Stop();
            _hudTimer.Stop();
        };
    }

    private void OnTextScaleChanged(Windows.UI.ViewManagement.UISettings sender, object args)
    {
        if (AppShutdown.Stopping) return;
        _ui.TryEnqueue(() => { if (!AppShutdown.Stopping && IsLoaded) Reload(); });
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        _store = JobsServices.Store;
        if (_store == null) { ShowState("Couldn’t Load Jobs", "Sign in to a gateway first.", retry: false); return; }
        _actions = new JobActions(_store, () => XamlRoot, Hud)
        {
            OnDeleted = job => { if (job.Key == _selected) Select(null); },
            OnCreated = key => { if (key != null && _store?.Job(key) != null) Select(key); },
            CurrentScope = () => _store?.Scope ?? "all",
        };
        _store.Changed += OnStoreChanged;
        _store.RefreshFailed += OnRefreshFailed;
        _store.JobRemoved += OnJobRemoved;
        var account = AppState.Client?.AccountId ?? "";
        _store.SetScope(EffectiveScope(JobsServices.Scope(account)));
        _store.NoteAppear();
        _clock.Start();
        if (AppState.Client is { Bots: null } client) _ = LoadBotsAsync(client);
        if (e.Parameter is PlaceArgs { Argument: string key }) Select(key);
        Reload();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        _clock.Stop();
        _runReader?.Leave();
        if (_store == null) return;
        _store.Changed -= OnStoreChanged;
        _store.RefreshFailed -= OnRefreshFailed;
        _store.JobRemoved -= OnJobRemoved;
        _store.NoteDisappear();
    }

    private async Task LoadBotsAsync(Hermes.Core.HermesClient client)
    {
        try { await client.BotsAsync(); } catch (Exception) { return; }
        _ui.TryEnqueue(Reload);
    }

    private void OnStoreChanged()
    {
        if (_reloadQueued) return;
        _reloadQueued = true;
        _ui.TryEnqueue(() => { _reloadQueued = false; Reload(); _detail?.StoreChanged(); });
    }

    private void OnRefreshFailed(string _) => _ui.TryEnqueue(() => Hud("Couldn’t refresh. Showing what was saved."));

    private void OnJobRemoved(string key) => _ui.TryEnqueue(() =>
    {
        if (key != _selected || _detail == null) return;
        _detail.MarkRemoved();
        Hud("Job Removed");
    });

    /// A scope whose bot left the roster reads as All.
    private static string EffectiveScope(string scope) =>
        scope == "all" || JobsServices.Bots().Count == 0 || JobsServices.Bots().Any(b => b.Name == scope) ? scope : "all";

    private void ToggleSearch()
    {
        var show = _search.Visibility != Visibility.Visible;
        _search.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        if (show) _search.Focus(FocusState.Programmatic);
        else if (_search.Text.Length > 0) _search.Text = "";
    }

    /// A notice over the page's foot for a moment ("Run Started", "Job Removed").
    private void Hud(string text)
    {
        _hudText.Text = text;
        _hud.Visibility = Visibility.Visible;
        _hudTimer.Stop();
        _hudTimer.Interval = TimeSpan.FromSeconds(text.Length > 24 ? 2.5 : 1.5);
        _hudTimer.Start();
    }

    // MARK: The list

    private void Reload()
    {
        if (_store is not { } store || _actions == null) return;
        DrawScope(store);
        _add.IsEnabled = !store.ReadOnlyGateway;
        var now = DateTimeOffset.Now;
        var words = _search.Text.Trim().ToLowerInvariant();
        var all = store.Jobs;
        var visible = words.Length == 0 ? all : all.Where(job => new[]
        {
            JobWords.JobTitle(job), store.Title(job), job.Prompt ?? "", job.ScheduleDisplay ?? "", job.Schedule?.Expr ?? "", job.Deliver ?? "",
        }.Any(f => f.Contains(words, StringComparison.OrdinalIgnoreCase))).ToList();
        _list.Children.Clear();
        var sections = visible.GroupBy(j => JobWords.Section(j, now)).ToDictionary(g => g.Key, g => g.ToList());
        var open = _completedOpen || words.Length > 0;
        foreach (var section in Enum.GetValues<JobSection>())
        {
            if (!sections.TryGetValue(section, out var jobs)) continue;
            _list.Children.Add(SectionHeader(section, jobs.Count, open));
            if (section == JobSection.Completed && !open)
            {
                var show = new HyperlinkButton { Content = $"Show {jobs.Count} Completed", Margin = new Thickness(4, 0, 0, 0) };
                AutomationProperties.SetAutomationId(show, "jobs.show-completed");
                show.Click += (_, _) => { _completedOpen = true; Reload(); };
                _list.Children.Add(show);
                continue;
            }
            foreach (var job in jobs) _list.Children.Add(Row(store, job, now, section));
        }
        // Blueprints follow the jobs (and the search); with no jobs the "No Jobs" words sit above them.
        var blueprints = store.HasList ? store.Blueprints.Where(b => JobBlueprints.Matches(b, words)).ToList() : [];
        // Empty Jobs with zero blueprints (Mac 1250): body already offers New Job…, so header shows "Jobs" alone.
        var bareEmpty = store.HasList && all.Count == 0 && store.Blueprints.Count == 0 && words.Length == 0;
        if (bareEmpty) _scope.Visibility = Visibility.Collapsed;
        _add.Visibility = bareEmpty ? Visibility.Collapsed : Visibility.Visible;
        _magnifier.Visibility = bareEmpty ? Visibility.Collapsed : Visibility.Visible;
        if (blueprints.Count > 0)
        {
            if (visible.Count == 0 && words.Length == 0)
            {
                var none = new StackPanel { Spacing = 4, Margin = new Thickness(12, 24, 12, 8) };
                none.Children.Add(JobsUi.Text("No Jobs", 18, bold: true));
                none.Children.Add(JobsUi.Text(EmptyText(store, blueprints: true), 13, JobsUi.Secondary));
                _list.Children.Add(none);
            }
            _list.Children.Add(PlainHeader("Blueprints", blueprints.Count));
            foreach (var bp in blueprints) _list.Children.Add(BlueprintRow(bp));
        }
        UpdateState(store, visible.Count, words, blueprints.Count > 0);
        _unopened.Visibility = _detail == null && (visible.Count > 0 || blueprints.Count > 0) ? Visibility.Visible : Visibility.Collapsed;
        if (_selected != null && _detail == null && store.Job(_selected) != null) Select(_selected);
    }

    private void DrawScope(JobsStore store)
    {
        var bots = JobsServices.Bots();
        _scope.Visibility = bots.Count >= 2 ? Visibility.Visible : Visibility.Collapsed;
        if (bots.Count < 2) return;
        var title = store.Scope == "all" ? "All Bots" : JobsServices.BotName(store.Scope);
        _scope.Content = title;
        AutomationProperties.SetName(_scope, $"Showing {title}. Change");
        var menu = new MenuFlyout();
        void Add(string text, string scope)
        {
            var item = new RadioMenuFlyoutItem { Text = text, IsChecked = store.Scope == scope, GroupName = "jobs-scope" };
            item.Click += (_, _) =>
            {
                JobsServices.SetScope(AppState.Client?.AccountId ?? "", scope);
                Select(null);
                store.SetScope(scope);
                Reload();
            };
            menu.Items.Add(item);
        }
        Add("All Bots", "all");
        foreach (var bot in bots) Add(bot.DisplayName, bot.Name);
        _scope.Flyout = menu;
    }

    private UIElement SectionHeader(JobSection section, int count, bool open)
    {
        var g = new Grid { Margin = new Thickness(4, 18, 4, 6) };
        var words = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        if (section == JobSection.NeedsAttention) words.Children.Add(JobsUi.Glyph("", 13, JobsUi.Red));
        if (section == JobSection.Running) words.Children.Add(new ProgressRing { IsActive = true, Width = 12, Height = 12 });
        var title = JobWords.SectionTitle(section);
        // Folded, Completed says no count of its own: "Show 1 Completed" under it does.
        var text = section == JobSection.Completed && !open ? title : $"{title} {count}";
        words.Children.Add(JobsUi.Text(text, 13, JobsUi.Secondary, bold: true, wrap: false));
        g.Children.Add(words);
        AutomationProperties.SetAutomationId(g, "jobs.section." + title);
        if (section == JobSection.Completed && open && _search.Text.Trim().Length == 0)
        {
            var hide = new HyperlinkButton { Content = "Hide", HorizontalAlignment = HorizontalAlignment.Right, Padding = new Thickness(0) };
            hide.Click += (_, _) => { _completedOpen = false; Reload(); };
            g.Children.Add(hide);
        }
        return g;
    }

    private static UIElement PlainHeader(string title, int count)
    {
        var t = JobsUi.Text($"{title} {count}", 13, JobsUi.Secondary, bold: true, wrap: false);
        t.Margin = new Thickness(4, 18, 4, 6);
        AutomationProperties.SetAutomationId(t, "jobs.section." + title);
        return t;
    }

    private Button Row(JobsStore store, CronJob job, DateTimeOffset now, JobSection section)
    {
        var failed = JobWords.LastRunFailed(job);
        var running = store.ShowsRunning(job) || JobWords.IsRunning(job);
        var paused = section == JobSection.Paused;
        var overdue = JobWords.NextRunOverdue(job, now) != null;
        var lead = JobWords.Lead(running, failed, overdue, paused);
        var edge = JobWords.Edge(job, now, running: running);
        var schedule = JobWords.RowSchedule(job, now, running: running);
        var title = store.Title(job);
        // [WIN-JOBS-ROW-FIT] Sized as the Mac's JobRowView at the current Windows text size (Hermes.Core.Jobs.JobRowLayout):
        // 2 title lines, one subtitle line and the edge at the side; at 150 % text or more 4 title lines, a wrapping
        // subtitle with the edge folded in once.
        var fit = JobRowLayout.Fit(TextScale(), ThemeService.State.Scale, ThemeService.State.DesktopLook, job.Owner, edge);

        // The 10 between the face and the words sits on the face, so a job with no owner starts its words at the side.
        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (fit.ShowsFace)
        {
            var face = (FrameworkElement)JobsUi.Face(job.Owner, fit.FaceSize);
            face.Margin = new Thickness(0, fit.FaceTop, 10, 0);
            g.Children.Add(face);
        }
        var words = new StackPanel { Spacing = 3 };
        words.Children.Add(JobsUi.Text(title, 15, maxLines: fit.TitleLines));
        var second = new TextBlock
        {
            FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = fit.SubtitleLines,
            TextWrapping = fit.SubtitleLines == 1 ? TextWrapping.NoWrap : TextWrapping.Wrap,
        };
        foreach (var piece in JobRowLayout.Subtitle(lead, schedule, edge, fit.Large))
        {
            var run = new Microsoft.UI.Xaml.Documents.Run { Text = piece.Text, Foreground = ToneBrush(piece.Tone) };
            if (piece.Semibold) run.FontWeight = FontWeights.SemiBold;
            second.Inlines.Add(run);
        }
        words.Children.Add(second);
        // Shipping Mac does not dim paused rows (0.55 opacity drops light contrast to 3.29:1 / 2.46:1).
        Grid.SetColumn(words, 1);
        g.Children.Add(words);
        if (fit.EdgeAtTrailing && edge != null)
        {
            var e = JobsUi.Text(edge.Text, 12, ToneBrush(JobRowLayout.EdgeTone(edge)), wrap: false);
            e.VerticalAlignment = VerticalAlignment.Top;
            e.Margin = new Thickness(10, 2, 0, 0);
            Grid.SetColumn(e, 2);
            g.Children.Add(e);
        }
        var selected = job.Key == _selected;
        var b = new Button
        {
            Content = g, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Center, MinHeight = fit.MinHeight,
            Padding = new Thickness(fit.PadLeading, fit.PadTop, fit.PadTrailing, fit.PadBottom), BorderThickness = new Thickness(0), CornerRadius = new CornerRadius(8),
            Background = selected ? JobsUi.Brush("SubtleFillColorSecondaryBrush") : new SolidColorBrush(Microsoft.UI.Colors.Transparent),
        };
        AutomationProperties.SetName(b, JobRowLayout.AccessibleName(title, lead, schedule, edge));
        AutomationProperties.SetAutomationId(b, "jobs.row." + job.Id);
        var key = job.Key;
        b.Click += (_, _) => Select(key);
        b.ContextFlyout = _actions!.Menu(job);
        b.ContextRequested += (_, _) => b.ContextFlyout = _actions.Menu(store.Job(key) ?? job);
        return b;
    }

    private static Brush ToneBrush(JobRowTone tone) => tone switch
    {
        JobRowTone.Tint => JobsUi.Accent,
        JobRowTone.Red => JobsUi.Red,
        JobRowTone.Orange => JobsUi.Orange,
        _ => JobsUi.Secondary,
    };

    /// Windows' text size (Settings › Accessibility › Text size, 1.0–2.25); 1 when it can't be read.
    private double TextScale()
    {
        try { return _uiSettings.TextScaleFactor; }
        catch (Exception) { return 1; }
    }

    private UIElement BlueprintRow(Blueprint bp)
    {
        var p = new StackPanel { Spacing = 2 };
        p.Children.Add(JobsUi.Text(bp.Title, 15));
        if (bp.Description.Length > 0) p.Children.Add(JobsUi.Text(bp.Description, 12, JobsUi.Secondary, maxLines: 2));
        var b = new Button
        {
            Content = p, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(10, 8, 10, 8), BorderThickness = new Thickness(0), CornerRadius = new CornerRadius(8),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
        };
        AutomationProperties.SetName(b, bp.Title);
        AutomationProperties.SetHelpText(b, "Starts a new job from this blueprint");
        b.Click += (_, _) => _actions?.NewJob(bp);
        return b;
    }

    /// "Jobs run a prompt[ for {Bot}] on a schedule. Click + to make one[, or start from a blueprint below]."
    private static string EmptyText(JobsStore store, bool blueprints)
    {
        var bot = store.Scope == "all" ? "" : $" for {JobsServices.BotName(store.Scope)}";
        // The Mac's state has its New Job… button, so the words don't send you to +.
        if (!blueprints) return $"Jobs run a prompt{bot} on a schedule.";
        if (store.ReadOnlyGateway) return $"Jobs run a prompt{bot} on a schedule. {JobsStore.ReadOnlyNotice}";
        return $"Jobs run a prompt{bot} on a schedule. {Hermes.Core.Gateways.DeviceWord.TapCap} + to make one, or start from a blueprint below.";
    }

    private void UpdateState(JobsStore store, int visibleCount, string words, bool blueprintsShown)
    {
        _loading.IsActive = !store.HasList && store.Loading;
        _loading.Visibility = _loading.IsActive ? Visibility.Visible : Visibility.Collapsed;
        if (visibleCount > 0 || (!store.HasList && store.Loading) || (blueprintsShown && words.Length == 0)) { HideState(); return; }
        if (words.Length > 0) ShowState($"No Results for “{_search.Text.Trim()}”", "Check the spelling, or try another word.", retry: false);
        else if (!store.HasList && store.LoadError is { } reason) ShowState("Couldn’t Load Jobs", reason, retry: true);
        else if (store.HasList) ShowState("No Jobs", EmptyText(store, blueprints: false), retry: false, newJob: !store.ReadOnlyGateway, glyph: "");
        else HideState();
    }

    private void HideState() { _state.Visibility = Visibility.Collapsed; _state.Children.Clear(); }

    private void ShowState(string title, string text, bool retry, bool newJob = false, string? glyph = null)
    {
        _state.Children.Clear();
        _state.Visibility = Visibility.Visible;
        if (glyph != null) { var g = JobsUi.Glyph(glyph, 36, JobsUi.Secondary); g.HorizontalAlignment = HorizontalAlignment.Center; _state.Children.Add(g); }
        var t = JobsUi.Text(title, 17, bold: true);
        t.HorizontalAlignment = HorizontalAlignment.Center;
        t.TextAlignment = TextAlignment.Center;
        _state.Children.Add(t);
        var body = JobsUi.Text(text, 13, JobsUi.Secondary);
        body.TextAlignment = TextAlignment.Center;
        _state.Children.Add(body);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center };
        if (retry)
        {
            var again = new Button { Content = "Try Again" };
            again.Click += (_, _) => _ = _store?.RefreshAsync();
            buttons.Children.Add(again);
            var copy = new Button { Content = "Copy Details" };
            copy.Click += (_, _) => HermesHQ.Services.SafeClipboard.TrySetText($"{title}\n{text}");
            buttons.Children.Add(copy);
        }
        if (newJob)
        {
            var make = new Button { Content = "New Job…" };
            make.Click += (_, _) => _actions?.NewJob();
            buttons.Children.Add(make);
        }
        if (buttons.Children.Count > 0) _state.Children.Add(buttons);
    }

    // MARK: The pane beside the list

    private void Select(string? key)
    {
        _selected = key;
        _runReader?.Leave();
        _pane.Children.Clear();
        _detail = null;
        if (key != null && _store is { } store && _actions != null && store.Job(key) != null)
        {
            _detail = new JobDetailView(store, _actions, key, OpenRun);
            _pane.Children.Add(_detail);
        }
        Reload();
    }

    /// A run opens its chat in the pane (Back returns to the job), or its saved output in the app's own read-only
    /// viewer (JobDetailViewController.swift `open(_:)`): Markdown with Preview | Source, its answer first, titled with
    /// the run's label, Back reading the job's name. Read for the job's own profile; nothing on the host changes.
    /// Not here yet: the Mac's Open in Quick Look for a document that can't be read (it stays open, see the card).
    private void OpenRun(CronJob job, CronRun run)
    {
        if (_store is not { } store) return;
        var title = store.Title(job);
        _runReader?.Leave();
        switch (run.Opens)
        {
            case RunOpens.Chat:
                var frame = new Frame();
                frame.Navigate(typeof(ChatPage), new ChatPage.Args(run.Profile ?? job.Owner, run.Id, title), new SuppressNavigationTransitionInfo());
                ShowPushed(title, frame);
                break;
            case RunOpens.Document when JobRunDocument.Opening(job, run, title) is { } opening:
                var reading = RunReader(store).Open(opening);
                var viewer = new ArtifactTextView(markdown: true, reading.LoadAsync) { Title = opening.Title };
                AutomationProperties.SetAutomationId(viewer, "job.run.document");
                ShowPushed(opening.BackTitle, viewer, viewer);
                break;
        }
    }

    /// The run-document reader for the store on show (a new account's store gets its own).
    private JobRunReader RunReader(JobsStore store)
    {
        if (_runReader == null || !ReferenceEquals(_runReaderStore, store))
        {
            _runReader?.Leave();
            _runReader = new JobRunReader(new GatewayJobRunDocumentSource(store.Api.Session));
            _runReaderStore = store;
        }
        return _runReader;
    }

    private void ShowPushed(string backTitle, UIElement content, ArtifactViewer? viewer = null)
    {
        var holder = new Grid();
        holder.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        holder.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var back = new Button { Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { JobsUi.Glyph("\uE72B", 12), JobsUi.Text(backTitle, 13, wrap: false) } },
            Style = JobsUi.Res<Style>("QuietButtonStyle"), Margin = new Thickness(8, 6, 0, 2) };
        AutomationProperties.SetName(back, "Back to " + backTitle);
        AutomationProperties.SetAutomationId(back, "job.run.back");
        var detail = _detail;
        back.Click += (_, _) =>
        {
            // Back ends the run document's reading: a late answer is dropped, never shown on the job.
            _runReader?.Leave();
            _pane.Children.Clear();
            if (detail != null) { _pane.Children.Add(detail); detail.StoreChanged(); }
        };
        var bar = new Grid { ColumnSpacing = 8 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.Children.Add(back);
        if (viewer != null)
        {
            // The viewer's title is the run's label (the Mac's navigation title); Preview | Source sits at the bar's
            // end once the document is read, gone while it couldn't be (the Mac's switch beside Share).
            var heading = JobsUi.Text(viewer.Title, 15, bold: true, wrap: false);
            heading.VerticalAlignment = VerticalAlignment.Center;
            heading.HorizontalAlignment = HorizontalAlignment.Center;
            heading.TextTrimming = TextTrimming.CharacterEllipsis;
            AutomationProperties.SetAutomationId(heading, "job.run.title");
            Grid.SetColumn(heading, 1);
            bar.Children.Add(heading);
            var trailing = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 12, 2), VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(trailing, 2);
            bar.Children.Add(trailing);
            void Refresh()
            {
                trailing.Children.Clear();
                if (viewer.HasModes) trailing.Children.Add(Look.Modes(viewer.Mode, viewer.SetMode));
            }
            viewer.Changed += Refresh;
            Refresh();
        }
        holder.Children.Add(bar);
        Grid.SetRow((FrameworkElement)content, 1);
        holder.Children.Add(content);
        _pane.Children.Clear();
        _pane.Children.Add(holder);
    }
}
