using Hermes.Core;
using Hermes.Core.Composer;
using Hermes.Core.Insights;
using Hermes.Core.Model;
using Hermes.Core.Rpc;
using HermesHQ.Controls;
using HermesHQ.Shell;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;

namespace HermesHQ.Features.Insights;

/// Spawn Tree (App/Pages/More/SpawnTree/SpawnTreePage.swift, SpawnDashboard.swift; spec 3x §16): the subagents running
/// on the gateway right now, grouped by bot and by the chat that owns them, indented by depth. Read-only: a click opens
/// the chat. Read on appear and every 3 s while the page is on screen (10 s after a failed read), and on `subagent.*`
/// events. Wide (SpawnTree.WideAt = 742 DIPs), it is the dashboard: a headline, four tiles, a table per bot;
/// narrower, the list. Preserves the ScrollViewer instance, scroll offset, and matching row controls across refreshes.
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class SpawnTreePage : InsightsPage
{
    private const double ColModel = 144, ColTools = 62, ColStatus = 96, ColTime = 78, ColGap = 10;
    /// The Mac's solid branch glyph (arrow.triangle.branch).
    private const string BranchGlyph = "";

    private readonly SpawnTreeLoader _loader = new();
    private readonly StackPanel _dashColumn = new() { Spacing = 10, Padding = new Thickness(14, 4, 14, 20) };
    private readonly ScrollViewer _dashScroll;
    private readonly StackPanel _listColumn;
    private readonly ScrollViewer _listScroll;
    private DashLiveView? _dashView;
    private ListLiveView? _listView;
    private CancellationTokenSource? _life;
    private HermesClient? _client;
    private Dictionary<string, SpawnTree.Session> _sessions = [];
    private DateTimeOffset _sessionsReadAt;
    private bool _reading, _again, _wide;
    private SemaphoreSlim _kick = new(0);

    public SpawnTreePage()
    {
        _dashScroll = new ScrollViewer { Content = _dashColumn, HorizontalScrollMode = ScrollMode.Disabled };
        AutomationProperties.SetAutomationId(_dashScroll, "spawn-tree.dashboard");
        _listScroll = Kit.Column(out _listColumn);
        AutomationProperties.SetAutomationId(_listScroll, "spawn-tree.list");
        SizeChanged += (_, e) =>
        {
            var wide = SpawnTree.IsWide(e.NewSize.Width);
            if (wide != _wide) { _wide = wide; Render(); }
        };
    }

    protected override void Shown()
    {
        Hidden();
        _client = Client;
        _loader.Reset();
        _dashView = null;
        _listView = null;
        _wide = SpawnTree.IsWide(ActualWidth);
        Render();
        if (_client == null) return;
        _life = new CancellationTokenSource();
        _kick = new SemaphoreSlim(0);
        _client.Rpc.Event += OnEvent;
        _ = PollAsync(_client, _kick, _life.Token);
    }

    protected override void Hidden()
    {
        if (_client != null) _client.Rpc.Event -= OnEvent;
        _life?.Cancel();
        _life = null;
        _again = false;
    }

    private void OnEvent(RpcEvent e)
    {
        if (!e.Type.StartsWith("subagent.", StringComparison.Ordinal)) return;
        if (_kick.CurrentCount == 0) _kick.Release();
    }

    private async Task PollAsync(HermesClient client, SemaphoreSlim kick, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            await ReadAsync(client, ct);
            var wait = _loader.LastFailed ? SpawnTreeCopy.ErrorInterval : SpawnTreeCopy.Interval;
            try { await kick.WaitAsync(wait, ct); }
            catch (OperationCanceledException) { return; }
        }
    }

    private void Retry() => Shown();

    private async Task ReadAsync(HermesClient client, CancellationToken ct)
    {
        // A `subagent.*` event during a read gets one more read after it, never more.
        if (_reading) { _again = true; return; }
        _reading = true;
        try
        {
            do
            {
                _again = false;
                var bots = client.Bots ?? await SafeBots(client, ct);
                var profiles = bots.OrderBy(b => b.IsDefault || b.Name == "default" ? 0 : 1).Select(b => b.Name).ToList();
                if (_sessions.Count == 0 || DateTimeOffset.UtcNow - _sessionsReadAt > TimeSpan.FromSeconds(30))
                {
                    try { _sessions = SpawnTreeLoader.Sessions(await client.SessionsAsync(ct)); _sessionsReadAt = DateTimeOffset.UtcNow; }
                    catch (Exception e) when (e is not OperationCanceledException) { }
                }
                bool changed;
                try { changed = await _loader.ReadAsync(client, profiles, _sessions, ct); }
                catch (OperationCanceledException) { return; }
                if (ct.IsCancellationRequested) return;
                if (changed) OnUi(Render);
            } while (_again && !ct.IsCancellationRequested);
        }
        finally { _reading = false; }
    }

    private static async Task<IReadOnlyList<Bot>> SafeBots(HermesClient client, CancellationToken ct)
    {
        try { return await client.BotsAsync(ct); } catch (Exception e) when (e is not OperationCanceledException) { return []; }
    }

    // ------------------------------------------------------------------ drawing (in-place updates preserve ScrollViewer & rows)

    private void Render()
    {
        var tree = _loader.Tree;
        switch (_loader.State)
        {
            case SpawnTreeLoader.Load.Loading:
                _dashView = null; _listView = null;
                Body.Child = Kit.Loading(SpawnTreeCopy.Loading, Retry);
                return;
            case SpawnTreeLoader.Load.Failed:
                _dashView = null; _listView = null;
                Body.Child = Kit.Error(SpawnTreeCopy.LoadFailed, _loader.Reason, Retry);
                return;
            case SpawnTreeLoader.Load.Older:
                _dashView = null; _listView = null;
                Body.Child = Kit.Empty(BranchGlyph, InsightsWire.NotAvailableTitle, InsightsWire.NotAvailableBody(SpawnTreeCopy.Title));
                return;
            default:
                if (tree.IsEmpty && !tree.Paused && !_loader.RefreshFailed)
                {
                    _dashView = null; _listView = null;
                    Body.Child = Kit.Empty(BranchGlyph, SpawnTreeCopy.EmptyTitle, SpawnTreeCopy.EmptyText);
                    return;
                }
                if (_wide)
                {
                    _listView = null;
                    SyncDashboard(tree);
                    if (!ReferenceEquals(Body.Child, _dashScroll)) Body.Child = _dashScroll;
                }
                else
                {
                    _dashView = null;
                    SyncList(tree);
                    if (!ReferenceEquals(Body.Child, _listScroll)) Body.Child = _listScroll;
                }
                return;
        }
    }

    private string StructureKey(SpawnTree tree) =>
        (tree.Paused ? "P|" : "|") + (_loader.RefreshFailed ? "F|" : "|") + (tree.IsEmpty ? "E|" : "|")
        + string.Join(";", tree.Bots.Select(b => b.Id + ":" +
            string.Join(",", b.Chats.Select(c => c.Id + "=" + c.Title + "/" + (c.SessionId != null ? "1" : "0") + "["
                + string.Join(",", c.Rows.Select(r => $"{r.Id}/{r.Level}")) + "]"))));

    private Bot? BotOf(string profile) => _client?.Bots?.FirstOrDefault(b => b.Name == profile);

    private string BotName(string profile) => BotOf(profile)?.DisplayName ?? Bot.TitleCase(profile);

    private UIElement Head(string profile, double size) =>
        new BotHead { Bot = BotOf(profile), DisplayName = BotName(profile), Width = size, Height = size, VerticalAlignment = VerticalAlignment.Center };

    private static void Open(SpawnTree.Chat chat, string profile)
    {
        if (chat.SessionId is not { } id) return;
        Navigator.Go(new ChatDestination(profile, id, chat.Title));
    }

    // ---- the list (narrow)

    private sealed class ListRowHandle(FrameworkElement root, Border glyphHost, TextBlock goal, TextBlock detail, SpawnStatus status)
    {
        public FrameworkElement Root { get; } = root;
        public Border GlyphHost { get; } = glyphHost;
        public TextBlock Goal { get; } = goal;
        public TextBlock Detail { get; } = detail;
        public SpawnStatus LastStatus { get; set; } = status;
    }

    private sealed class ListLiveView(string structureKey, TextBlock header, Dictionary<string, ListRowHandle> rows)
    {
        public string StructureKey { get; } = structureKey;
        public TextBlock Header { get; } = header;
        public Dictionary<string, ListRowHandle> Rows { get; } = rows;
    }

    private void SyncList(SpawnTree tree)
    {
        var key = StructureKey(tree);
        if (_listView is { } live && live.StructureKey == key)
        {
            live.Header.Text = tree.Header;
            foreach (var bot in tree.Bots)
            {
                foreach (var chat in bot.Chats)
                {
                    foreach (var row in chat.Rows)
                    {
                        if (!live.Rows.TryGetValue(row.Id, out var h)) continue;
                        var r = row.Record;
                        if (h.LastStatus != r.Status)
                        {
                            h.LastStatus = r.Status;
                            var g = StatusGlyph(r.Status, 16);
                            g.VerticalAlignment = VerticalAlignment.Top;
                            g.Margin = new Thickness(0, 2, 0, 0);
                            h.GlyphHost.Child = g;
                        }
                        h.Goal.Text = r.Goal ?? "Subagent";
                        h.Detail.Text = SpawnTree.Detail(r, _loader.Now);
                        h.Detail.Foreground = r.Status == SpawnStatus.Failed
                            ? new SolidColorBrush(Kit.Red)
                            : Kit.Brush("TextFillColorSecondaryBrush");
                        AutomationProperties.SetName(h.Root, SpawnTree.Spoken(row, _loader.Now));
                    }
                }
            }
            return;
        }

        _listColumn.Children.Clear();
        var top = new List<UIElement>();
        if (_loader.RefreshFailed)
        {
            var t = Kit.Text(SpawnTreeCopy.RefreshFailed, 13, secondary: true);
            t.Margin = new Thickness(16, 10, 16, 0);
            AutomationProperties.SetAutomationId(t, "spawn-tree.refresh-failed");
            top.Add(t);
        }
        var header = Kit.Text(tree.Header, 13, bold: true);
        header.Margin = new Thickness(16, 12, 16, 12);
        AutomationProperties.SetAutomationId(header, "spawn-tree.header");
        top.Add(header);
        if (tree.Paused) top.Add(PausedLine(boxed: false));
        _listColumn.Children.Add(new StackPanel { Margin = new Thickness(0, 10, 0, 10), Children = { Kit.Card(top) } });
        if (tree.IsEmpty)
        {
            var none = Kit.Text(SpawnTreeCopy.NoLive, 14, secondary: true);
            none.Margin = new Thickness(16, 12, 16, 12);
            _listColumn.Children.Add(Kit.Section(null, [none]));
        }
        var handles = new Dictionary<string, ListRowHandle>();
        foreach (var bot in tree.Bots)
        {
            var rows = new List<UIElement>();
            foreach (var chat in bot.Chats)
            {
                rows.Add(ChatTitle(chat, bot.Id));
                foreach (var row in chat.Rows)
                {
                    var handle = ListRow(row, chat, bot.Id);
                    handles[row.Id] = handle;
                    rows.Add(handle.Root);
                }
            }
            var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(16, 0, 0, 6) };
            head.Children.Add(Head(bot.Id, 22));
            var name = Kit.Text(BotName(bot.Id), 13, secondary: true, bold: true);
            name.VerticalAlignment = VerticalAlignment.Center;
            head.Children.Add(name);
            AutomationProperties.SetName(head, BotName(bot.Id));
            AutomationProperties.SetAutomationId(head, "spawn-tree.bot." + bot.Id);
            AutomationProperties.SetHeadingLevel(head, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
            _listColumn.Children.Add(new StackPanel { Margin = new Thickness(0, 10, 0, 10), Children = { head, Kit.Card(rows) } });
        }
        _listView = new ListLiveView(key, header, handles);
    }

    private static FrameworkElement PausedLine(bool boxed)
    {
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        line.Children.Add(new FontIcon { Glyph = "", FontSize = 13, Foreground = new SolidColorBrush(Kit.Orange), VerticalAlignment = VerticalAlignment.Center });
        line.Children.Add(Kit.Text(SpawnTreeCopy.Paused, boxed ? 12 : 14));
        AutomationProperties.SetName(line, SpawnTreeCopy.Paused);
        AutomationProperties.SetAutomationId(line, "spawn-tree.paused");
        if (!boxed) { line.Margin = new Thickness(16, 6, 16, 12); return line; }
        var o = Kit.Orange;
        return new Border
        {
            Child = line, Padding = new Thickness(10, 5, 10, 5), CornerRadius = new CornerRadius(12), VerticalAlignment = VerticalAlignment.Center,
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(41, o.R, o.G, o.B)),
        };
    }

    /// The chat a group of subagents belongs to, with the chevron its subagents' rows draw when it can be opened.
    private static FrameworkElement ChatTitle(SpawnTree.Chat chat, string profile)
    {
        var g = new Grid { Padding = new Thickness(16, 10, 14, 10), ColumnSpacing = 10 };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.Children.Add(new FontIcon { Glyph = "", FontSize = 13, Foreground = Kit.Brush("TextFillColorSecondaryBrush") });
        var t = Kit.Text(chat.Title, 12, secondary: true, bold: true);
        t.MaxLines = 2;
        Put(g, t, 1);
        if (chat.SessionId == null)
        {
            AutomationProperties.SetName(g, chat.Title);
            AutomationProperties.SetAutomationId(g, "spawn-tree.chat.none");
            return g;
        }
        g.Children.Add(Chevron(2));
        return Clickable(g, chat.Title, () => Open(chat, profile), "spawn-tree.chat." + chat.SessionId);
    }

    /// One subagent: its goal (two lines), then "<model> · N tools · running 2m 10s", indented 16 a level (four at most).
    private ListRowHandle ListRow(SpawnTree.Row row, SpawnTree.Chat chat, string profile)
    {
        var r = row.Record;
        var g = new Grid { Padding = new Thickness(16 + row.Indent * SpawnTree.IndentWidth, 10, 14, 10), ColumnSpacing = 10 };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(20) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var glyph = StatusGlyph(r.Status, 16);
        glyph.VerticalAlignment = VerticalAlignment.Top;
        glyph.Margin = new Thickness(0, 2, 0, 0);
        var glyphHost = new Border { Child = glyph };
        g.Children.Add(glyphHost);
        var text = new StackPanel { Spacing = 3 };
        var goal = Kit.Text(r.Goal ?? "Subagent", 14);
        goal.MaxLines = 2;
        goal.TextTrimming = TextTrimming.CharacterEllipsis;
        text.Children.Add(goal);
        var detail = Kit.Text(SpawnTree.Detail(r, _loader.Now), 12, secondary: true);
        detail.MaxLines = 2;
        if (r.Status == SpawnStatus.Failed) detail.Foreground = new SolidColorBrush(Kit.Red);
        text.Children.Add(detail);
        Put(g, text, 1);
        var spoken = SpawnTree.Spoken(row, _loader.Now);
        var id = "spawn-tree.row." + r.Id;
        FrameworkElement root;
        if (chat.SessionId == null)
        {
            AutomationProperties.SetName(g, spoken);
            AutomationProperties.SetAutomationId(g, id);
            AttachMenu(g, r, chat, profile);
            root = g;
        }
        else
        {
            var chev = Chevron(2);
            chev.VerticalAlignment = VerticalAlignment.Top;
            chev.Margin = new Thickness(0, 4, 0, 0);
            g.Children.Add(chev);
            var b = Clickable(g, spoken, () => Open(chat, profile), id);
            AttachMenu(b, r, chat, profile);
            root = b;
        }
        return new ListRowHandle(root, glyphHost, goal, detail, r.Status);
    }

    private static FontIcon Chevron(int column)
    {
        var c = new FontIcon { Glyph = "", FontSize = 11, Foreground = Kit.Brush("TextFillColorTertiaryBrush"), VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(c, column);
        return c;
    }

    private static Button Clickable(UIElement content, string name, Action click, string id)
    {
        var b = new Button
        {
            Content = content, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(0),
            CornerRadius = new CornerRadius(8),
        };
        AutomationProperties.SetName(b, name);
        AutomationProperties.SetHelpText(b, SpawnTreeCopy.OpensChat);
        AutomationProperties.SetAutomationId(b, id);
        b.Click += (_, _) => click();
        return b;
    }

    /// A right-click on a subagent: its chat, its task's words (Mac AAA 2026-11-16).
    private static void AttachMenu(UIElement target, SpawnRecord r, SpawnTree.Chat chat, string profile)
    {
        var menu = new MenuFlyout();
        if (chat.SessionId != null)
        {
            var open = new MenuFlyoutItem { Text = SpawnTreeCopy.OpenChat, Icon = new FontIcon { Glyph = "" } };
            open.Click += (_, _) => Open(chat, profile);
            menu.Items.Add(open);
        }
        if (r.Goal is { Length: > 0 } goalText)
        {
            var copy = new MenuFlyoutItem { Text = SpawnTreeCopy.CopyTask, Icon = new FontIcon { Glyph = "" } };
            copy.Click += (_, _) => HermesHQ.Services.SafeClipboard.TrySetText(goalText);
            menu.Items.Add(copy);
        }
        if (menu.Items.Count > 0) target.ContextFlyout = menu;
    }

    /// running: a small ring; queued: a clock; done: a green tick; failed: a red mark.
    private static FrameworkElement StatusGlyph(SpawnStatus s, double size) => s switch
    {
        SpawnStatus.Running => new ProgressRing { IsActive = true, Width = size, Height = size },
        SpawnStatus.Queued => new FontIcon { Glyph = "", FontSize = size, Foreground = Kit.Brush("TextFillColorTertiaryBrush") },
        SpawnStatus.Done => new FontIcon { Glyph = "", FontSize = size, Foreground = new SolidColorBrush(Kit.Green) },
        _ => new FontIcon { Glyph = "", FontSize = size, Foreground = new SolidColorBrush(Kit.Red) },
    };

    // ---- the dashboard (wide)

    private sealed class DashRowHandle(Grid root, TextBlock goal, TextBlock model, TextBlock tools, Border statusHost, TextBlock time, SpawnStatus status)
    {
        public Grid Root { get; } = root;
        public TextBlock Goal { get; } = goal;
        public TextBlock Model { get; } = model;
        public TextBlock Tools { get; } = tools;
        public Border StatusHost { get; } = statusHost;
        public TextBlock Time { get; } = time;
        public SpawnStatus LastStatus { get; set; } = status;
    }

    private sealed class DashLiveView(
        string structureKey,
        FontIcon headlineIcon,
        TextBlock headlineTitle,
        TextBlock headlineDetail,
        List<(StackPanel Panel, TextBlock Value, TextBlock Note)> tiles,
        Dictionary<string, (Grid Head, TextBlock Summary, string BotDisplayName)> botHeaders,
        Dictionary<string, DashRowHandle> rows)
    {
        public string StructureKey { get; } = structureKey;
        public FontIcon HeadlineIcon { get; } = headlineIcon;
        public TextBlock HeadlineTitle { get; } = headlineTitle;
        public TextBlock HeadlineDetail { get; } = headlineDetail;
        public List<(StackPanel Panel, TextBlock Value, TextBlock Note)> Tiles { get; } = tiles;
        public Dictionary<string, (Grid Head, TextBlock Summary, string BotDisplayName)> BotHeaders { get; } = botHeaders;
        public Dictionary<string, DashRowHandle> Rows { get; } = rows;
    }

    private void SyncDashboard(SpawnTree tree)
    {
        var key = StructureKey(tree);
        if (_dashView is { } live && live.StructureKey == key)
        {
            live.HeadlineIcon.Foreground = tree.Active > 0
                ? Kit.Brush("AccentTextFillColorPrimaryBrush")
                : Kit.Brush("TextFillColorSecondaryBrush");
            live.HeadlineTitle.Text = tree.Headline;
            live.HeadlineDetail.Text = tree.HeadlineDetail;
            var tileData = tree.Tiles(_loader.Now);
            for (var i = 0; i < tileData.Count && i < live.Tiles.Count; i++)
            {
                var (title, value, note, red) = tileData[i];
                var (panel, valueBlock, noteBlock) = live.Tiles[i];
                valueBlock.Text = value;
                noteBlock.Text = note;
                noteBlock.Foreground = red ? new SolidColorBrush(Kit.Red) : Kit.Brush("TextFillColorSecondaryBrush");
                AutomationProperties.SetName(panel, $"{title}, {value}, {note}");
            }
            foreach (var bot in tree.Bots)
            {
                if (live.BotHeaders.TryGetValue(bot.Id, out var bh))
                {
                    var summary = SpawnTree.BotSummary(bot);
                    bh.Summary.Text = summary;
                    AutomationProperties.SetName(bh.Head, $"{bh.BotDisplayName}, {summary}");
                }
                foreach (var chat in bot.Chats)
                {
                    foreach (var row in chat.Rows)
                    {
                        if (!live.Rows.TryGetValue(row.Id, out var h)) continue;
                        var r = row.Record;
                        h.Goal.Text = r.Goal ?? "Subagent";
                        h.Model.Text = r.Model != null ? ModelNames.DisplayModelName(r.Model) : "—";
                        h.Tools.Text = r.ToolCount?.ToString() ?? "—";
                        if (h.LastStatus != r.Status)
                        {
                            h.LastStatus = r.Status;
                            h.StatusHost.Child = StatusPill(r.Status);
                        }
                        var time = r.Status == SpawnStatus.Running ? SpawnTree.Duration(r.StartedAt is { } st ? _loader.Now - st : null) : null;
                        h.Time.Text = time ?? "—";
                        AutomationProperties.SetName(h.Root, SpawnTree.Spoken(row, _loader.Now));
                    }
                }
            }
            return;
        }

        _dashColumn.Children.Clear();
        var (headline, headIcon, headTitle, headDetail) = BuildHeadline(tree);
        _dashColumn.Children.Add(headline);
        var (tilesGrid, tileHandles) = BuildTiles(tree);
        _dashColumn.Children.Add(tilesGrid);
        if (tree.IsEmpty)
        {
            var card = new StackPanel { Spacing = 6 };
            card.Children.Add(Kit.Text(SpawnTreeCopy.Subagents, 14, bold: true));
            card.Children.Add(Kit.Text(SpawnTreeCopy.NoLive, 12.5, secondary: true));
            _dashColumn.Children.Add(DashCard(card, new Thickness(14, 11, 14, 11)));
        }
        var botHeaders = new Dictionary<string, (Grid, TextBlock, string)>();
        var rowHandles = new Dictionary<string, DashRowHandle>();
        foreach (var bot in tree.Bots) _dashColumn.Children.Add(BotCard(bot, botHeaders, rowHandles));
        _dashView = new DashLiveView(key, headIcon, headTitle, headDetail, tileHandles, botHeaders, rowHandles);
    }

    private (FrameworkElement Element, FontIcon Icon, TextBlock Title, TextBlock Detail) BuildHeadline(SpawnTree tree)
    {
        var g = new Grid { ColumnSpacing = 12, Padding = new Thickness(0, 2, 0, 2) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = new FontIcon
        {
            Glyph = BranchGlyph, FontSize = 24, VerticalAlignment = VerticalAlignment.Center,
            Foreground = tree.Active > 0 ? Kit.Brush("AccentTextFillColorPrimaryBrush") : Kit.Brush("TextFillColorSecondaryBrush"),
        };
        g.Children.Add(icon);
        var words = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
        var title = Kit.Text(tree.Headline, 18, bold: true);
        AutomationProperties.SetHeadingLevel(title, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
        AutomationProperties.SetAutomationId(title, "spawn-tree.header");
        words.Children.Add(title);
        var detail = Kit.Text(tree.HeadlineDetail, 12, secondary: true);
        words.Children.Add(detail);
        if (_loader.RefreshFailed)
        {
            var f = Kit.Text(SpawnTreeCopy.RefreshFailed, 11.5);
            f.Foreground = new SolidColorBrush(Kit.Orange);
            AutomationProperties.SetAutomationId(f, "spawn-tree.refresh-failed");
            words.Children.Add(f);
        }
        Put(g, words, 1);
        if (tree.Paused) Put(g, PausedLine(boxed: true), 2);
        return (g, icon, title, detail);
    }

    private (FrameworkElement Grid, List<(StackPanel Panel, TextBlock Value, TextBlock Note)> Handles) BuildTiles(SpawnTree tree)
    {
        var g = new Grid { ColumnSpacing = 12 };
        var handles = new List<(StackPanel, TextBlock, TextBlock)>();
        var i = 0;
        foreach (var (title, value, note, red) in tree.Tiles(_loader.Now))
        {
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var valueBlock = Kit.Text(value, 22, bold: true, wrap: false);
            var noteBlock = Kit.Text(note, 11, secondary: true, wrap: false);
            if (red) noteBlock.Foreground = new SolidColorBrush(Kit.Red);
            var s = new StackPanel { Spacing = 2 };
            s.Children.Add(Kit.Text(title.ToUpperInvariant(), 10.5, secondary: true, bold: true, wrap: false));
            s.Children.Add(valueBlock);
            s.Children.Add(noteBlock);
            AutomationProperties.SetName(s, $"{title}, {value}, {note}");
            handles.Add((s, valueBlock, noteBlock));
            Put(g, DashCard(s, new Thickness(12, 9, 12, 9)), i++);
        }
        return (g, handles);
    }

    private static Border DashCard(UIElement child, Thickness padding) => new()
    {
        Child = child, Padding = padding, CornerRadius = new CornerRadius(12),
        Background = Kit.Brush("CardBackgroundFillColorDefaultBrush"),
        BorderBrush = Kit.Brush("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1),
    };

    private FrameworkElement BotCard(SpawnTree.BotGroup bot,
        Dictionary<string, (Grid Head, TextBlock Summary, string BotDisplayName)> botHeaders,
        Dictionary<string, DashRowHandle> rowHandles)
    {
        var stack = new StackPanel { Padding = new Thickness(0, 0, 0, 4) };
        var head = new Grid { Padding = new Thickness(14, 9, 14, 9), ColumnSpacing = 8 };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.Children.Add(Head(bot.Id, 24));
        var botDisplayName = BotName(bot.Id);
        var name = Kit.Text(botDisplayName, 14, bold: true, wrap: false);
        name.VerticalAlignment = VerticalAlignment.Center;
        Put(head, name, 1);
        var count = Kit.Text(SpawnTree.BotSummary(bot), 11.5, secondary: true, wrap: false);
        count.VerticalAlignment = VerticalAlignment.Center;
        Put(head, count, 2);
        AutomationProperties.SetName(head, $"{botDisplayName}, {SpawnTree.BotSummary(bot)}");
        AutomationProperties.SetAutomationId(head, "spawn-tree.bot." + bot.Id);
        AutomationProperties.SetHeadingLevel(head, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
        botHeaders[bot.Id] = (head, count, botDisplayName);
        stack.Children.Add(head);
        stack.Children.Add(Headings());
        foreach (var chat in bot.Chats)
        {
            stack.Children.Add(Hairline(0));
            stack.Children.Add(ChatBand(chat, bot.Id));
            foreach (var row in chat.Rows)
            {
                stack.Children.Add(Hairline(14));
                var handle = TaskRow(row, chat, bot.Id);
                rowHandles[row.Id] = handle;
                stack.Children.Add(handle.Root);
            }
        }
        return DashCard(stack, new Thickness(0));
    }

    private static Border Hairline(double left) => new() { Height = 1, Margin = new Thickness(left, 0, 0, 0), Background = Kit.Brush("DividerStrokeColorDefaultBrush") };

    private static Grid TableGrid(Thickness padding)
    {
        var g = new Grid { ColumnSpacing = 10, Padding = padding };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(ColModel) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(ColTools) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(ColStatus + ColGap) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(ColTime) });
        return g;
    }

    private static void Put(Grid g, FrameworkElement e, int col) { Grid.SetColumn(e, col); g.Children.Add(e); }

    private static FrameworkElement Headings()
    {
        var g = TableGrid(new Thickness(14, 0, 14, 6));
        var h = SpawnTreeCopy.Headings;
        for (var i = 0; i < h.Length; i++)
        {
            var t = Kit.Text(h[i], 10, secondary: true, bold: true, wrap: false);
            if (i is 2 or 4) t.HorizontalAlignment = HorizontalAlignment.Right;
            if (i == 3) t.Margin = new Thickness(ColGap, 0, 0, 0);
            Put(g, t, i);
        }
        AutomationProperties.SetAccessibilityView(g, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return g;
    }

    /// The chat a group of subagents works for, with the button that opens it.
    private static FrameworkElement ChatBand(SpawnTree.Chat chat, string profile)
    {
        var g = new Grid { ColumnSpacing = 8, Padding = new Thickness(14, 5, 14, 5), MinHeight = 32, Background = Kit.Brush("SubtleFillColorSecondaryBrush") };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Put(g, new FontIcon { Glyph = "", FontSize = 12, Foreground = Kit.Brush("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center }, 0);
        var t = Kit.Text(chat.Title, 12.5, bold: true, wrap: false);
        t.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetHeadingLevel(t, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level3);
        Put(g, t, 1);
        var n = Kit.Text(chat.Rows.Count.ToString(), 11.5, secondary: true, wrap: false);
        n.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetName(n, $"{chat.Rows.Count} {(chat.Rows.Count == 1 ? "subagent" : "subagents")}");
        Put(g, n, 2);
        if (chat.SessionId != null)
        {
            var b = new Button { Content = SpawnTreeCopy.OpenChat, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Padding = new Thickness(8, 2, 8, 3) };
            AutomationProperties.SetAutomationId(b, "spawn-tree.chat." + chat.SessionId);
            b.Click += (_, _) => Open(chat, profile);
            Put(g, b, 4);
        }
        return g;
    }

    private DashRowHandle TaskRow(SpawnTree.Row row, SpawnTree.Chat chat, string profile)
    {
        var r = row.Record;
        var g = TableGrid(new Thickness(14, 5, 14, 5));
        g.MinHeight = 34;
        g.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        var cell = new Grid { ColumnSpacing = 6, VerticalAlignment = VerticalAlignment.Center };
        cell.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        cell.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        if (row.Indent > 0)
            cell.Children.Add(new FontIcon
            {
                Glyph = "", FontSize = 10, Foreground = Kit.Brush("TextFillColorTertiaryBrush"), VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness((row.Indent - 1) * 18, 3, 0, 0),
            });
        var goal = Kit.Text(r.Goal ?? "Subagent", 12.5);
        goal.MaxLines = 2;
        goal.TextTrimming = TextTrimming.CharacterEllipsis;
        goal.VerticalAlignment = VerticalAlignment.Center;
        Put(cell, goal, 1);
        Put(g, cell, 0);
        var model = Kit.Text(r.Model != null ? ModelNames.DisplayModelName(r.Model) : "—", 12, secondary: true, wrap: false);
        model.VerticalAlignment = VerticalAlignment.Center;
        Put(g, model, 1);
        var tools = Kit.Text(r.ToolCount?.ToString() ?? "—", 12, secondary: true, wrap: false);
        tools.HorizontalAlignment = HorizontalAlignment.Right;
        tools.VerticalAlignment = VerticalAlignment.Center;
        Put(g, tools, 2);
        var statusHost = new Border { Margin = new Thickness(ColGap, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, Child = StatusPill(r.Status) };
        Put(g, statusHost, 3);
        var time = r.Status == SpawnStatus.Running ? SpawnTree.Duration(r.StartedAt is { } st ? _loader.Now - st : null) : null;
        var tt = Kit.Text(time ?? "—", 12, secondary: true, wrap: false);
        tt.HorizontalAlignment = HorizontalAlignment.Right;
        tt.VerticalAlignment = VerticalAlignment.Center;
        Put(g, tt, 4);
        AutomationProperties.SetName(g, SpawnTree.Spoken(row, _loader.Now));
        AutomationProperties.SetAutomationId(g, "spawn-tree.row." + r.Id);
        AttachMenu(g, r, chat, profile);
        return new DashRowHandle(g, goal, model, tools, statusHost, tt, r.Status);
    }

    private static Border StatusPill(SpawnStatus s)
    {
        var color = s switch
        {
            SpawnStatus.Running => Kit.Blue,
            SpawnStatus.Queued => Kit.Grey,
            SpawnStatus.Done => Kit.Green,
            _ => Kit.Red,
        };
        var brush = new SolidColorBrush(color);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5 };
        row.Children.Add(s switch
        {
            SpawnStatus.Running => new ProgressRing { IsActive = true, Width = 10, Height = 10, Foreground = brush },
            SpawnStatus.Queued => new FontIcon { Glyph = "", FontSize = 10, Foreground = brush },
            SpawnStatus.Done => new FontIcon { Glyph = "", FontSize = 10, Foreground = brush },
            _ => (UIElement)new FontIcon { Glyph = "", FontSize = 10, Foreground = brush },
        });
        row.Children.Add(new TextBlock { Text = s.Word(), FontSize = 11, FontWeight = FontWeights.Medium, Foreground = brush, VerticalAlignment = VerticalAlignment.Center });
        return new Border
        {
            Child = row, Padding = new Thickness(7, 2, 7, 2), CornerRadius = new CornerRadius(9),
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center,
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(38, color.R, color.G, color.B)),
        };
    }
}
