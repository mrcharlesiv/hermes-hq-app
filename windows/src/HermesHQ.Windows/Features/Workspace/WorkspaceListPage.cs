using System.Security.Cryptography;
using System.Text;
using Hermes.Core.Attachments;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Workspace;
using HermesHQ.Features.Attachments;
using HermesHQ.Features.Transcript;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using VirtualKey = Windows.System.VirtualKey;

namespace HermesHQ.Features.Workspace;

/// More › Workspace › Files (App/Pages/More/Workspace/MoreWorkspacePages.swift, MacFilesTable.swift): the gateway
/// computer's folders as the Mac's table, read-only.
[Microsoft.UI.Xaml.Data.Bindable]
public sealed class FilesPage : WorkspaceListPage
{
    public FilesPage() : base(WorkspaceVisit.Kind.Files) { }
}

/// More › Workspace › Changes (the place "review"): a project's uncommitted changes, each opening its diff.
[Microsoft.UI.Xaml.Data.Bindable]
public sealed class ChangesPage : WorkspaceListPage
{
    public ChangesPage() : base(WorkspaceVisit.Kind.Review) { }
}

/// The Mac's Files and Changes table: the bar (the page's name, the Bot pop-up, Refresh and the folder's ⋯ menu), a
/// path trail with the count, the columns' names, one-line rows (Name and Kind; or Name, Status and Lines), a folder
/// opened in place, and the file or diff on show in a pane beside the table with its row marked. The root is the folder
/// chosen here, else the last chat's folder, else the gateway's default (`WorkspaceRoot`). Nothing here writes.
public abstract class WorkspaceListPage : Page
{
    private readonly WorkspaceVisit.Kind _kind;
    private WorkspaceVisit? _visit;
    private ListingContent _content = new ListingContent.Loading();
    private string? _browsed;
    private string? _directory;
    private string? _markedPath;
    private string? _busyPath;
    private CancellationTokenSource? _load, _opening;
    private DispatcherQueue _ui = null!;

    private readonly Grid _root = new();
    private readonly StackPanel _barLead = new() { Orientation = Orientation.Horizontal, Spacing = 10, VerticalAlignment = VerticalAlignment.Center };
    private readonly ComboBox _botPicker = new() { MinWidth = 120, VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel _trail = new() { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _count = W.Text("", 12, null);
    private readonly Grid _columns = new() { Padding = new Thickness(16, 0, 16, 4) };
    private readonly ListView _list = new()
    {
        SelectionMode = ListViewSelectionMode.Single, IsItemClickEnabled = true, Padding = new Thickness(0, 0, 0, 12),
    };
    private readonly ContentControl _body = new() { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private readonly ColumnDefinition _paneColumn = new() { Width = new GridLength(0) };
    private readonly ContentControl _pane = new() { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private bool _suppressBotChange;

    protected WorkspaceListPage(WorkspaceVisit.Kind kind)
    {
        _kind = kind;
        NavigationCacheMode = NavigationCacheMode.Disabled;
        Content = _root;
        _count.Foreground = W.Secondary;
        _list.ItemClick += (_, e) => Clicked(e.ClickedItem as FrameworkElement);
        _list.ContainerContentChanging += (_, e) => { if (e.ItemContainer is ListViewItem item) { item.MinHeight = 28; item.Padding = new Thickness(8, 0, 8, 0); } };
        AutomationProperties.SetAutomationId(_list, kind == WorkspaceVisit.Kind.Files ? "more.files" : "more.review");
        KeyDown += OnKeyDown;
        Build();
    }

    private bool IsReview => _kind == WorkspaceVisit.Kind.Review;
    private string Title => IsReview ? "Changes" : "Files";

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _ui = DispatcherQueue.GetForCurrentThread();
        if (AppState.Client is not { } client) { Show(new ListingContent.State(new("Not Signed In", ""), "exclamationmark.triangle", false, false)); return; }
        IReadOnlyList<Bot> bots;
        try { bots = client.Bots ?? await client.BotsAsync(); }
        catch (Exception x) { AppLog.Error("workspace", x); bots = []; }
        var choices = bots.Where(b => !b.Hidden).ToList();
        _visit = new WorkspaceVisit(new SessionWorkspaceRest(client.Session), FilePreferences.Shared, client.AccountId, _kind, choices,
            () => ChatFolders.Current(client.AccountId));
        FillBotPicker();
        _ = AskHomeAsync();
        Reload();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        _load?.Cancel();
        _opening?.Cancel();
    }

    // MARK: Building

    private void Build()
    {
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        // The bar: "Files" and the Bot pop-up at the left, Refresh and the folder's ⋯ at the right.
        // [WIN-50] The Mac's page bar (MacWindow.pageBar, Shell/PageBar.cs): the page-title token and the page's side;
        // Refresh · Folder Options as the Mac's [folder, again] read trailing inward (MoreWorkspacePages.swift).
        var bar = new Grid { Padding = HermesHQ.Shell.PageBar.Padding(12, 8) };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var title = W.Text(Title, 17, bold: true);
        HermesHQ.Shell.PageBar.Title(title, null);
        _barLead.Children.Add(title);
        AutomationProperties.SetAutomationId(_botPicker, "more.bot-picker");
        AutomationProperties.SetName(_botPicker, "Bot");
        _botPicker.SelectionChanged += (_, _) => BotChosen();
        bar.Children.Add(_barLead);
        var tools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        var refresh = W.BarButton("", "Refresh", "workspace.refresh");
        refresh.Click += (_, _) => Reload();
        var menu = W.BarButton("", "Folder Options", "workspace.root.menu");
        var flyout = new MenuFlyout { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedRight };
        flyout.Opening += (_, _) => FillRootMenu(flyout);
        menu.Flyout = flyout;
        tools.Children.Add(refresh);
        tools.Children.Add(menu);
        Grid.SetColumn(tools, 1);
        bar.Children.Add(tools);
        _root.Children.Add(bar);

        // The table and the pane beside it.
        var split = new Grid();
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 260 });
        split.ColumnDefinitions.Add(_paneColumn);
        Grid.SetRow(split, 1);
        _root.Children.Add(split);

        var table = new Grid();
        table.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        table.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        table.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var trailRow = new Grid { Padding = new Thickness(16, 2, 20, 6) };
        trailRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        trailRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        trailRow.Children.Add(_trail);
        Grid.SetColumn(_count, 1);
        trailRow.Children.Add(_count);
        table.Children.Add(trailRow);
        Grid.SetRow(_columns, 1);
        _columns.BorderBrush = W.Res<Brush>("CardStrokeColorDefaultBrush");
        _columns.BorderThickness = new Thickness(0, 0, 0, 1);
        _columns.Margin = new Thickness(0, 0, 0, 4);
        table.Children.Add(_columns);
        Grid.SetRow(_body, 2);
        table.Children.Add(_body);
        split.Children.Add(table);

        var paneBorder = new Border
        {
            BorderBrush = W.Res<Brush>("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1, 0, 0, 0), Child = _pane,
        };
        Grid.SetColumn(paneBorder, 1);
        split.Children.Add(paneBorder);
    }

    /// The columns' widths (MacFilesTable.Column): Kind a quarter of the table between 112 and 260; Status and Lines.
    private ColumnDefinition[] RowColumns()
    {
        if (IsReview)
            return [new() { Width = new GridLength(26) }, new() { Width = new GridLength(1, GridUnitType.Star) },
                new() { Width = new GridLength(130) }, new() { Width = new GridLength(120) }];
        return [new() { Width = new GridLength(26) }, new() { Width = new GridLength(1, GridUnitType.Star) }, new() { Width = new GridLength(170) }];
    }

    private void FillColumns(bool show)
    {
        _columns.Children.Clear();
        _columns.ColumnDefinitions.Clear();
        _columns.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        if (!show) return;
        foreach (var c in RowColumns()) _columns.ColumnDefinitions.Add(c);
        string[] names = IsReview ? ["Name", "Status", "Lines"] : ["Name", "Kind"];
        for (var i = 0; i < names.Length; i++)
        {
            var t = W.Text(names[i], 12, W.Secondary, bold: true);
            Grid.SetColumn(t, i + 1);
            _columns.Children.Add(t);
        }
    }

    private void FillBotPicker()
    {
        if (_visit == null) return;
        _barLead.Children.Remove(_botPicker);
        if (_visit.Bots.Count <= 1) return;
        _suppressBotChange = true;
        _botPicker.Items.Clear();
        foreach (var bot in _visit.Bots) _botPicker.Items.Add(new ComboBoxItem { Content = bot.DisplayName, Tag = bot.Name });
        _botPicker.SelectedIndex = Math.Max(0, _visit.Bots.ToList().FindIndex(b => b.Name == _visit.Profile));
        _suppressBotChange = false;
        _barLead.Children.Add(_botPicker);
    }

    private void BotChosen()
    {
        if (_suppressBotChange || _visit == null || (_botPicker.SelectedItem as ComboBoxItem)?.Tag is not string profile || profile == _visit.Profile) return;
        _visit.SetProfile(profile);
        AutomationProperties.SetName(_botPicker, "Bot: " + _visit.BotName(profile));
        _browsed = null;
        ClosePane();
        Reload();
    }

    private void FillRootMenu(MenuFlyout flyout)
    {
        flyout.Items.Clear();
        var choose = new MenuFlyoutItem { Text = "Choose Folder…", Icon = new FontIcon { Glyph = "" } };
        choose.Click += async (_, _) => await ChooseFolderAsync();
        flyout.Items.Add(choose);
        if (_visit?.Chosen != null)
        {
            var chat = new MenuFlyoutItem { Text = "Use Chat’s Folder", Icon = new FontIcon { Glyph = "" } };
            chat.Click += (_, _) =>
            {
                _visit.SetChosen(null);
                _browsed = null;
                ClosePane();
                Reload();
            };
            flyout.Items.Add(chat);
        }
    }

    private async Task AskHomeAsync()
    {
        if (_visit == null) return;
        await _visit.AskHomeAsync();
        FillTrail();
    }

    // MARK: Loading

    /// Reads the root again (after a new folder or bot) and then its entries.
    public void Reload()
    {
        if (_visit is not { } visit) return;
        _load?.Cancel();
        _opening?.Cancel();
        _busyPath = null;
        var cts = _load = new CancellationTokenSource();
        Show(new ListingContent.Loading());
        var browsed = _browsed;
        _ = Task.Run(async () =>
        {
            try
            {
                var (content, directory) = await WorkspaceListing.LoadRootAsync(visit, browsed, cts.Token);
                _ui.TryEnqueue(() =>
                {
                    if (cts.IsCancellationRequested) return;
                    _directory = directory;
                    if (directory != visit.Root?.Path) _browsed = directory; else _browsed = null;
                    AppLog.Note("pages", $"workspace {(IsReview ? "review" : "files")} root resolved: {visit.Root?.Source.ToString().ToLowerInvariant() ?? "none"}");
                    Show(content);
                });
            }
            catch (OperationCanceledException) { }
        });
    }

    /// Lists `path` in place (a folder's row, or a folder in the trail).
    private void Browse(string path)
    {
        if (_visit?.Root?.Path is not { } root || !WorkspaceRoot.IsUnder(path, root)) return;
        ClosePane();
        _browsed = path == root ? null : path;
        _directory = path;
        _load?.Cancel();
        _opening?.Cancel();
        _busyPath = null;
        var cts = _load = new CancellationTokenSource();
        var visit = _visit;
        Show(new ListingContent.Loading());
        _ = Task.Run(async () =>
        {
            try
            {
                var content = await WorkspaceListing.ReadAsync(visit, path, isRoot: true, chooser: false, cts.Token);
                _ui.TryEnqueue(() => { if (!cts.IsCancellationRequested) Show(content); });
            }
            catch (OperationCanceledException) { }
        });
    }

    private void Show(ListingContent content)
    {
        _content = content;
        _list.Items.Clear();
        switch (content)
        {
            case ListingContent.Loading:
                _body.Content = W.Loading();
                break;
            case ListingContent.State s:
                _body.Content = W.State(s.Glyph, s.Words.Title, s.Words.Body,
                    s.Retry ? ("Try Again", Reload) : s.Choose ? ("Choose Folder…", () => _ = ChooseFolderAsync()) : null,
                    s.Retry && s.Choose ? ("Choose Folder…", () => _ = ChooseFolderAsync()) : null);
                break;
            case ListingContent.Entries e:
                for (var i = 0; i < e.Rows.Count; i++) _list.Items.Add(EntryRow(e.Rows[i], i));
                _body.Content = _list;
                AppLog.Note("pages", $"workspace files: {e.Rows.Count} entries");
                break;
            case ListingContent.Changes c:
                for (var i = 0; i < c.Rows.Count; i++) _list.Items.Add(ChangeRow(c.Rows[i], i));
                _body.Content = _list;
                AppLog.Note("pages", $"workspace review: {c.Rows.Count} changes");
                break;
        }
        FillColumns(content is ListingContent.Entries or ListingContent.Changes);
        FillTrail();
        RestoreMark();
    }

    /// The trail from the root's folder down to the one listed, and the count.
    private void FillTrail()
    {
        _trail.Children.Clear();
        _trail.Children.Add(new FontIcon { Glyph = "", FontSize = 15, Foreground = W.Accent, Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center });
        if (_visit?.Root is { } root)
        {
            var crumbs = WorkspaceRoot.Crumbs(root.Path, _browsed);
            for (var i = 0; i < crumbs.Count; i++)
            {
                var (name, path) = crumbs[i];
                if (i > 0) _trail.Children.Add(W.Glyph("", 10, W.Tertiary));
                // MacFilesHeaderView: the last component names this folder; only its ancestors navigate.
                var current = i == crumbs.Count - 1;
                var words = W.Text(name, 14, current ? null : W.Secondary, bold: current);
                FrameworkElement crumb;
                if (current)
                {
                    words.Margin = new Thickness(4, 2, 4, 2);
                    AutomationProperties.SetName(words, name);
                    crumb = words;
                }
                else
                {
                    var link = new HyperlinkButton
                    {
                        Content = words, Padding = new Thickness(4, 2, 4, 2), Foreground = W.Res<Brush>("TextFillColorPrimaryBrush"),
                    };
                    var target = path;
                    link.Click += (_, _) => Browse(target);
                    crumb = link;
                }
                AutomationProperties.SetAutomationId(crumb, i == 0 ? "workspace.root.name" : $"workspace.crumb.{i}");
                if (i == 0)
                {
                    var source = WorkspaceRoot.SourceLine(root.Source, _visit.ChatTitle);
                    ToolTipService.SetToolTip(crumb, _visit.Display(root.Path) + "\n" + source);
                    AutomationProperties.SetHelpText(crumb, _visit.Display(root.Path) + ", " + source);
                }
                else
                {
                    ToolTipService.SetToolTip(crumb, path);
                }
                _trail.Children.Add(crumb);
            }
        }
        else
        {
            _trail.Children.Add(W.Text(_content is ListingContent.Loading ? "Finding the Folder…" : "No Folder", 14, bold: true));
        }
        _count.Text = _content switch
        {
            ListingContent.Entries e => WorkspaceRoot.ItemCount(e.Rows.Count),
            ListingContent.Changes c => WorkspaceRoot.ChangeCount(c.Rows.Count),
            _ => "",
        };
    }

    // MARK: Rows

    private Grid RowGrid(int index, string id, string spoken)
    {
        var grid = new Grid { Height = 28, Padding = new Thickness(8, 0, 8, 0), CornerRadius = new CornerRadius(5) };
        if (index % 2 == 1) grid.Background = W.Res<Brush>("SubtleFillColorSecondaryBrush");
        foreach (var c in RowColumns()) grid.ColumnDefinitions.Add(c);
        AutomationProperties.SetAutomationId(grid, id);
        AutomationProperties.SetName(grid, spoken);
        return grid;
    }

    private FrameworkElement EntryRow(WorkspaceEntry entry, int index)
    {
        var kind = WorkspaceRoot.KindWord(entry.Name, entry.IsDirectory);
        var grid = RowGrid(index, "workspace.entry." + entry.Name, $"{entry.Name}, {kind}");
        grid.Tag = entry;
        var glyph = entry.IsDirectory ? W.Glyph("", 15, W.Accent) : W.Glyph(MediaKinds.Glyph(MediaKinds.Kind(entry.Name)), 15, W.Secondary);
        Grid.SetColumn(glyph, 0);
        grid.Children.Add(glyph);
        var name = W.Text(entry.Name, 14);
        name.TextTrimming = TextTrimming.CharacterEllipsis;
        Grid.SetColumn(name, 1);
        grid.Children.Add(name);
        var kindText = W.Text(kind, 13, W.Secondary);
        if (_busyPath == entry.Path)
        {
            var busy = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            busy.Children.Add(new ProgressRing { IsActive = true, Width = 14, Height = 14 });
            busy.Children.Add(kindText);
            Grid.SetColumn(busy, 2);
            grid.Children.Add(busy);
        }
        else
        {
            Grid.SetColumn(kindText, 2);
            grid.Children.Add(kindText);
        }
        grid.ContextFlyout = RowMenu(entry, null);
        return grid;
    }

    private FrameworkElement ChangeRow(WorkspaceChange change, int index)
    {
        var word = WorkspaceRoot.LinesWord(change.Added, change.Removed, change.Status, change.Path);
        var spokenLines = word != null ? word == "Binary" ? ", Binary" : "" : $", {change.Added} added, {change.Removed} removed";
        var grid = RowGrid(index, "workspace.change." + change.Path, $"{change.Path}, {change.StatusName}{spokenLines}");
        grid.Tag = change;
        var tint = WorkspaceRoot.Tint(change.Status) switch
        {
            WorkspaceRoot.ChangeTint.Added => W.Green,
            WorkspaceRoot.ChangeTint.Deleted => W.Red,
            _ => W.Orange,
        };
        var glyph = W.Glyph(WorkspaceRoot.StatusGlyph(change.Status), 14, tint);
        grid.Children.Add(glyph);
        // The file's name in the label colour, its folder before it in grey ("src/" then "app.js").
        var slash = change.Path.LastIndexOf('/');
        var name = new TextBlock { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, FontSize = 14 };
        if (slash > 0) name.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = change.Path[..(slash + 1)], Foreground = W.Secondary });
        name.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = change.Path[(slash + 1)..] });
        Grid.SetColumn(name, 1);
        grid.Children.Add(name);
        var status = W.Text(change.StatusName, 13, W.Secondary);
        Grid.SetColumn(status, 2);
        grid.Children.Add(status);
        var lines = new TextBlock { FontSize = 13, VerticalAlignment = VerticalAlignment.Center };
        if (word != null) lines.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = word, Foreground = W.Secondary });
        else
        {
            if (change.Added > 0 || change.Removed == 0) lines.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = $"+{Math.Max(0, change.Added)}", Foreground = W.Green });
            if (change.Removed > 0) lines.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = (lines.Inlines.Count > 0 ? " " : "") + $"−{change.Removed}", Foreground = W.Red });
        }
        Grid.SetColumn(lines, 3);
        grid.Children.Add(lines);
        grid.ContextFlyout = RowMenu(null, change);
        return grid;
    }

    /// A changed file's whole path (the list names it from the repository's root).
    private string? FullPath(WorkspaceChange change) =>
        WorkspaceRoot.FullPath(change, (_content as ListingContent.Changes)?.RepoRoot, _directory);

    /// A row's right-click menu (Mac audit J2): Open, Save As…, Copy Path, Share…; a folder or a deleted file: Open and
    /// Copy Path.
    private MenuFlyout RowMenu(WorkspaceEntry? entry, WorkspaceChange? change)
    {
        var menu = new MenuFlyout();
        var open = new MenuFlyoutItem { Text = "Open", Icon = new FontIcon { Glyph = "" } };
        open.Click += (_, _) => { if (entry != null) Open(entry); else if (change != null) OpenDiff(change); };
        menu.Items.Add(open);
        var shown = entry?.Path ?? (change != null ? FullPath(change) : null);
        var handed = entry != null ? entry.IsDirectory ? null : entry.Path
            : change != null && WorkspaceRoot.StatusLetter(change.Status) != "D" ? FullPath(change) : null;
        if (handed != null)
        {
            var save = new MenuFlyoutItem { Text = "Save As…", Icon = new FontIcon { Glyph = "" } };
            save.Click += (_, _) => HandOver(handed, "Couldn’t Save This File", (file, name) => MediaActions.SaveAsAsync(file, name));
            menu.Items.Add(save);
        }
        if (shown != null)
        {
            var copy = new MenuFlyoutItem { Text = "Copy Path", Icon = new FontIcon { Glyph = "" } };
            copy.Click += (_, _) => CopyPath(shown);
            menu.Items.Add(copy);
        }
        if (handed != null)
        {
            var share = new MenuFlyoutItem { Text = "Share…", Icon = new FontIcon { Glyph = "" } };
            share.Click += (_, _) => HandOver(handed, "Couldn’t Share This File", (file, name) => MediaActions.ShareAsync(file, name));
            menu.Items.Add(share);
        }
        return menu;
    }

    private void CopyPath(string path)
    {
        MediaActions.CopyText(path);
        _count.Text = "Copied";   // the Mac's "Copied" HUD, where the count stands
        _ = Task.Delay(1500).ContinueWith(_ => _ui.TryEnqueue(() => { if (_count.Text == "Copied") FillTrail(); }));
        AppLog.Note("pages", "workspace path copied");
    }

    // MARK: Clicks

    private void Clicked(FrameworkElement? row)
    {
        switch (row?.Tag)
        {
            case WorkspaceEntry { IsDirectory: true } folder: Browse(folder.Path); break;
            case WorkspaceEntry file: Open(file); break;
            case WorkspaceChange change: OpenDiff(change); break;
        }
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var alt = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Menu).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        var ctrl = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        if ((e.Key == VirtualKey.Back && e.OriginalSource is not TextBox) || (alt && e.Key == VirtualKey.Left) || e.Key == VirtualKey.GoBack)
        {
            // Up one folder, as Finder's Back (InPlaceBack), while a folder is open in place.
            if (_browsed != null && _visit?.Root?.Path is { } root)
            {
                Browse(WorkspaceRoot.Parent(_browsed) is { } up && WorkspaceRoot.IsUnder(up, root) ? up : root);
                e.Handled = true;
            }
        }
        else if (e.Key == VirtualKey.F5 || (ctrl && e.Key == VirtualKey.R))
        {
            Reload();
            e.Handled = true;
        }
        else if (e.Key == VirtualKey.Escape && _markedPath != null)
        {
            ClosePane();
            e.Handled = true;
        }
    }

    // MARK: Opening

    private void SetBusy(string? path)
    {
        var old = _busyPath;
        _busyPath = path;
        if (_content is not ListingContent.Entries e) return;
        foreach (var target in new[] { old, path })
        {
            if (target == null) continue;
            var i = e.Rows.ToList().FindIndex(r => r.Path == target);
            if (i >= 0 && i < _list.Items.Count) _list.Items[i] = EntryRow(e.Rows[i], i);
        }
        RestoreMark();
    }

    /// Where a downloaded file is kept for opening and Save As… (the cache: it may be cleared).
    private string CachePath(string path)
    {
        var digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes($"{_visit?.Profile}|{path}")))[..20].ToLowerInvariant();
        var name = AttachmentCenter.SafeName(Path.GetFileName(path.TrimEnd('/')).Replace(':', '_'));
        return Path.Combine(AppPaths.Root, "cache", "workspace-" + digest, name.Length == 0 ? "file" : name);
    }

    /// A text file is read and shown beside the table (with the notice when only its start is shown); anything else is
    /// downloaded and opened in its own app, the Windows stand-in for the Mac's Quick Look window. A newer click
    /// supersedes the one before it.
    private void Open(WorkspaceEntry entry)
    {
        if (_visit is not { } visit) return;
        if (entry.IsDirectory) { Browse(entry.Path); return; }
        _opening?.Cancel();
        var cts = _opening = new CancellationTokenSource();
        SetBusy(entry.Path);
        var workspace = visit.Workspace;
        _ = Task.Run(async () =>
        {
            try
            {
                if (WorkspaceRoot.Opening(entry.Name) == WorkspaceRoot.OpeningKind.Text)
                {
                    WorkspaceFileText? read;
                    try { read = await workspace.ReadTextAsync(entry.Path, cts.Token); }
                    catch (ChatWorkspace.TooLargeException) { read = null; }   // past the text read: downloaded and opened instead
                    if (read is { Binary: false } file)
                    {
                        string? markdown = null;
                        if (WorkspaceRoot.IsMarkdown(entry.Name))
                        {
                            if (!file.Truncated) markdown = file.Text;
                            else if (file.ByteSize is { } size && size <= 2 << 20)
                            {
                                var whole = CachePath(entry.Path);
                                try { await workspace.DownloadAsync(entry.Path, whole, cts.Token); markdown = await File.ReadAllTextAsync(whole, cts.Token); }
                                catch (Exception x) when (x is not OperationCanceledException) { }
                            }
                        }
                        _ui.TryEnqueue(() =>
                        {
                            if (cts.IsCancellationRequested) return;
                            SetBusy(null);
                            var notice = file.Truncated && markdown == null ? WorkspaceRoot.TruncatedNotice(file.ByteSize) : null;
                            ShowPane(entry.Path, new FileTextView(entry.Name, markdown ?? file.Text, diff: false, notice, markdown != null,
                                () => SaveWholeAsync(entry.Path, entry.Name, file), ClosePane));
                        });
                        return;
                    }
                }
                var target = CachePath(entry.Path);
                await workspace.DownloadAsync(entry.Path, target, cts.Token);
                _ui.TryEnqueue(async () =>
                {
                    if (cts.IsCancellationRequested) return;
                    SetBusy(null);
                    RestoreMark();
                    try { await MediaActions.OpenAsync(target, entry.Name); }
                    catch (Exception x) { await W.AskAsync(XamlRoot, "Couldn’t Open This File", x.Message); }
                });
            }
            catch (OperationCanceledException) { }
            catch (Exception x)
            {
                _ui.TryEnqueue(async () =>
                {
                    if (cts.IsCancellationRequested) return;
                    SetBusy(null);
                    await W.AskAsync(XamlRoot, "Couldn’t Open This File", ChatWorkspace.Reason(x));
                });
            }
        });
    }

    /// Save As… from a file's pane: the whole file (a file shown only in part is fetched whole).
    private async Task SaveWholeAsync(string path, string name, WorkspaceFileText file)
    {
        if (!file.Truncated)
        {
            var copy = CachePath(path);
            Directory.CreateDirectory(Path.GetDirectoryName(copy)!);
            await File.WriteAllTextAsync(copy, file.Text);
            await MediaActions.SaveAsAsync(copy, name);
            return;
        }
        HandOver(path, "Couldn’t Save This File", (f, n) => MediaActions.SaveAsAsync(f, n));
    }

    /// Downloads `path` (the row's spinner while it does) and hands the file over.
    private void HandOver(string path, string failure, Func<string, string, Task> deliver)
    {
        if (_visit is not { } visit) return;
        _opening?.Cancel();
        var cts = _opening = new CancellationTokenSource();
        SetBusy(path);
        var target = CachePath(path);
        var name = Path.GetFileName(path);
        _ = Task.Run(async () =>
        {
            try
            {
                await visit.Workspace.DownloadAsync(path, target, cts.Token);
                _ui.TryEnqueue(async () =>
                {
                    SetBusy(null);
                    try { await deliver(target, name); }
                    catch (Exception x) { await W.AskAsync(XamlRoot, failure, x.Message); }
                });
            }
            catch (OperationCanceledException) { }
            catch (Exception x)
            {
                _ui.TryEnqueue(async () => { SetBusy(null); await W.AskAsync(XamlRoot, failure, ChatWorkspace.Reason(x)); });
            }
        });
    }

    private void OpenDiff(WorkspaceChange change)
    {
        if (_visit is not { } visit || _directory is not { } directory) return;
        var workspace = visit.Workspace;
        var name = Path.GetFileName(change.Path);
        var view = new FileTextView(name, null, diff: true, notice: null, markdown: false, save: null, ClosePane);
        ShowPane(change.Path, view);
        _ = Task.Run(async () =>
        {
            try
            {
                var diff = await workspace.DiffAsync(directory, change);
                _ui.TryEnqueue(() => view.SetText(diff.Length == 0 ? "No differences to show." : diff));
            }
            catch (Exception x) { _ui.TryEnqueue(() => view.Failed(ChatWorkspace.Reason(x))); }
        });
    }

    // MARK: The pane beside the table

    private void ShowPane(string path, FrameworkElement page)
    {
        _markedPath = path;
        _pane.Content = page;
        _paneColumn.Width = new GridLength(1.2, GridUnitType.Star);
        RestoreMark();
    }

    private void ClosePane()
    {
        _markedPath = null;
        _pane.Content = null;
        _paneColumn.Width = new GridLength(0);
        _list.SelectedItem = null;
    }

    /// The row of the file on show beside the table, marked again after the rows were made again.
    private void RestoreMark()
    {
        if (_markedPath == null) { _list.SelectedItem = null; return; }
        foreach (var item in _list.Items)
        {
            var path = (item as FrameworkElement)?.Tag switch { WorkspaceEntry e => e.Path, WorkspaceChange c => c.Path, _ => null };
            if (path == _markedPath) { _list.SelectedItem = item; return; }
        }
        _list.SelectedItem = null;
    }

    // MARK: Choosing

    private async Task ChooseFolderAsync()
    {
        if (_visit is not { } visit) return;
        var chosen = await FolderChooser.ShowAsync(XamlRoot, visit, visit.ChooserStart);
        if (chosen == null) return;
        visit.SetChosen(chosen);
        _browsed = null;
        ClosePane();
        Reload();
    }
}
