using Hermes.Core.Capabilities;
using Hermes.Core.Gateways;
using DensitySizes = Hermes.Core.Settings.DensitySizes;
using ThemeService = HermesHQ.Features.Settings.ThemeService;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;

namespace HermesHQ.Features.Capabilities;

/// One list for one bot: Skills, Tools, Connectors or Plugins (App/Capabilities/CapabilitiesViewController.swift and
/// the *Sections files). The Bot row, "Couldn’t refresh", then the list's sections.
internal sealed class ListScreen : Screen
{
    public CapabilitiesModel Model { get; }
    private readonly bool _locked;

    public ListScreen(CapabilitiesTab tab, string? profile, bool locked, string? focus = null)
    {
        Model = new CapabilitiesModel(tab, profile) { Focus = focus };
        _locked = locked;
        Model.Changed += Render;
    }

    public override string Title => Model.Tab.Title();
    public override string? SearchPrompt => Model.Tab.Prompt();

    public override void Shown()
    {
        Model.RootSource = () => Root;
        Model.Query = Query;
        Model.Appear();
    }

    public override void Hidden() => Model.Disappear();
    public override Task RefreshAsync() => Model.Refresh();

    public override IEnumerable<MenuFlyoutItemBase> Menu()
    {
        var m = Model;
        yield return Kit.Item("Refresh", Kit.Refresh, () => _ = m.Refresh());
        switch (m.Tab)
        {
            case CapabilitiesTab.Skills:
                yield return Kit.Item("Marketplace", Kit.Bag, () => Push(new MarketplaceScreen(m, MarketplaceKind.Skills)));
                if (m.HasUsage && !m.ReadOnly) yield return Kit.Item("Disable Unused", "", m.DisableUnused, m.UnusedSkills.Count > 0 && m.Disabling == null);
                break;
            case CapabilitiesTab.Tools:
                var sort = new MenuFlyoutSubItem { Text = "Sort", Icon = new FontIcon { Glyph = Kit.Sort } };
                foreach (var (s, title) in new[] { (ToolSort.Most, "Most Used"), (ToolSort.Least, "Least Used"), (ToolSort.Name, "A–Z") })
                    sort.Items.Add(Kit.CheckItem(title, m.EffectiveSort == s, () => m.Sort = s, m.ToolUsage != null || s == ToolSort.Name));
                yield return sort;
                break;
            case CapabilitiesTab.Connectors:
                if (!m.ReadOnly) yield return Kit.Item("Add Your Own…", Kit.Add, AddConnector);
                break;
            case CapabilitiesTab.Plugins:
                yield return Kit.Item("Marketplace", Kit.Bag, () => Push(new MarketplaceScreen(m, MarketplaceKind.Plugins)));
                if (!m.ReadOnly && !m.PluginsUnavailable) yield return Kit.Item("Install from Git…", Kit.Add, () => Push(new PluginInstallScreen(m)));
                break;
        }
    }

    public async void AddConnector()
    {
        if (await AddConnectorDialog.ShowAsync(Model) is { } name && Model.Servers?.FirstOrDefault(s => s.Name == name) is { } server)
            Push(new ConnectorScreen(Model, server));
    }

    public override void Build(StackPanel page)
    {
        Model.Query = Query;
        page.Children.Add(BotRow.Make(Model.Profile, _locked, Model.SetProfile));
        if (Model.RefreshFailed)
        {
            var g = new Grid { ColumnSpacing = 12 };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.Children.Add(Kit.Text(CapabilitiesWords.RefreshFailed, 13, secondary: true));
            var b = Kit.Button("Try Again", () => _ = Model.Refresh());
            Grid.SetColumn(b, 1);
            g.Children.Add(b);
            page.Children.Add(Kit.Section(null, [Kit.Pad(g)]));
        }
        switch (Model.Tab)
        {
            case CapabilitiesTab.Skills: Skills(page); break;
            case CapabilitiesTab.Tools: Tools(page); break;
            case CapabilitiesTab.Connectors: Connectors(page); break;
            default: Plugins(page); break;
        }
    }

    private bool Waiting(StackPanel page)
    {
        if (Model.IsConnected) return false;
        page.Children.Add(Kit.Section(null, [Kit.Plain(CapabilitiesWords.Waiting)]));
        return true;
    }

    /// Windows' text size (Settings › Accessibility › Text size), read as the rows are drawn; 1 when it can't be read.
    private static double TextScale()
    {
        try { return new Windows.UI.ViewManagement.UISettings().TextScaleFactor; }
        catch { return 1; }
    }

    private static UIElement NoResults(string q) => Kit.Section(null, [Kit.Plain($"No Results for “{q}”")]);

    // ---------------------------------------------------------------- Skills

    private void Skills(StackPanel page)
    {
        var m = Model;
        if (m.Skills is not { } skills)
        {
            if (m.SkillsError is { } error) page.Children.Add(Kit.LoadError("Couldn’t Load Skills", error, () => _ = m.ReloadSkills()));
            else if (!Waiting(page)) page.Children.Add(Kit.Skeletons());
            return;
        }
        var shown = m.ShownSkills;
        var available = m.Available;
        var notices = m.Notices.Where(n => n.Profile == m.Profile).ToList();
        if (m.Trimmed.Length > 0 && shown.Count == 0 && available.Count == 0)
        {
            page.Children.Add(NoResults(m.Trimmed));
            Hub(page);
            return;
        }
        var rows = new List<UIElement>();
        if (m.SkillsNotice is { } notice) rows.Add(Kit.Notice(notice, Kit.Check));
        if (skills.Count == 0 && m.Trimmed.Length == 0)
        {
            // What an empty list means and where skills come from, with a way to find them (UX study #55).
            var words = CapabilitiesWords.SkillsEmpty(m.BotName, available.Count > 0);
            var empty = new StackPanel { Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center };
            empty.Children.Add(Kit.Glyph(Kit.Sparkles, 28, Kit.Secondary));
            empty.Children.Add(Kit.Text(words.Title, 17, bold: true).Also(t => t.HorizontalAlignment = HorizontalAlignment.Center));
            empty.Children.Add(Kit.Text(words.Text, 13, secondary: true).Also(t => t.TextAlignment = TextAlignment.Center));
            rows.Add(Kit.Pad(empty, 18));
        }
        foreach (var skill in shown)
        {
            var row = Kit.Row(DisplayName.Title(skill.Name), CapabilitiesWords.SkillLine(skill), tip: CapabilitiesWords.SkillTip(skill.Description),
                subtitleLines: CapabilitiesWords.SkillLineLines(TextScale()),
                trailing: Kit.Switch(skill.Enabled, DisplayName.Title(skill.Name), on => m.SetSkill(skill, on), !m.Toggling.Contains(skill.Name) && !m.ReadOnly),
                click: () => Push(new SkillScreen(m, skill)));
            AutomationProperties.SetAutomationId(row, $"skill-row-{skill.Name}");
            rows.Add(row);
        }
        string? footer = m.Disabling is { } d ? CapabilitiesWords.Disabling(d.Done, d.Total)
            : available.Count == 0 && notices.Count == 0 && skills.Count > 0 ? CapabilitiesWords.ChangesApply : null;
        // No "Installed" over the empty state that says nothing is installed (UX study #99).
        page.Children.Add(Kit.Section(skills.Count == 0 && m.Trimmed.Length == 0 ? null : "Installed", rows, footer));
        if (available.Count > 0 || notices.Count > 0)
        {
            var more = new List<UIElement>();
            foreach (var n in notices)
            {
                var g = new Grid { ColumnSpacing = 12 };
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var w = new StackPanel { Spacing = 3 };
                w.Children.Add(Kit.Text(n.Title, 14, bold: true));
                w.Children.Add(Kit.Text(n.Message, 13, secondary: true));
                g.Children.Add(w);
                var end = n.Done ? Kit.Glyph(Kit.Check, 18, Kit.Success) : Kit.Spinner(18);
                Grid.SetColumn((FrameworkElement)end, 1);
                g.Children.Add(end);
                more.Add(n.Done ? Kit.Row(n.Title, n.Message, trailing: Kit.Glyph(Kit.Check, 18, Kit.Success), click: () => m.Dismiss(n), boldTitle: true) : Kit.Pad(g));
            }
            foreach (var o in available)
            {
                UIElement end = m.Running.Contains(o.Identifier) ? Kit.Spinner()
                    : m.ReadOnly ? Kit.Text("", 1) : Kit.RowAction("Get", () => m.Install(o), $"Get {o.Name}");
                more.Add(Kit.Row(DisplayName.Title(o.Name), CapabilitiesWords.OfficialLine(o), tip: CapabilitiesWords.SkillTip(o.Description), trailing: end,
                    subtitleLines: CapabilitiesWords.SkillLineLines(TextScale())));
            }
            page.Children.Add(Kit.Section("Available from Hermes", more, CapabilitiesWords.ChangesApply));
        }
        Hub(page);
        SkillsMarketplace(page);
    }

    /// The Skills Hub section, while the search has words (HubSkillsSection.swift).
    private void Hub(StackPanel page)
    {
        var m = Model;
        var term = m.Trimmed;
        if (term.Length == 0 || m.HubUnsupported) return;
        var results = m.ShownHub;
        var rows = new List<UIElement>();
        string? footer;
        if (m.HubSearching)
        {
            rows.Add(Kit.Busy("Searching the Skills Hub…"));
            footer = "This can take a while. Hermes asks every hub it knows.";
        }
        else if (results != null)
        {
            if (results.Count == 0) rows.Add(Kit.Plain("No matching skills found in the hub."));
            foreach (var h in results)
            {
                var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
                line.Children.Add(new Border
                {
                    Child = Kit.Text(h.TrustWord, 11, bold: true, color: h.IsCommunity ? Kit.Caution : Kit.Secondary, wrap: false),
                    Padding = new Thickness(7, 1, 7, 1), CornerRadius = new CornerRadius(8), Background = Kit.Brush("SubtleFillColorSecondaryBrush"),
                });
                line.Children.Add(Kit.Text(string.Join(" · ", new[] { h.SourceWord, h.Repo ?? "" }.Where(s => s.Length > 0)), 12, secondary: true, wrap: false));
                var words = new StackPanel { Spacing = 2 };
                if (h.Description.Length > 0) words.Children.Add(Kit.Text(h.Description, 12, secondary: true).Also(t => t.MaxLines = DensitySizes.DescriptionLines(ThemeService.State.Compact)));
                words.Children.Add(line);
                AutomationProperties.SetName(line, h.Provenance);
                UIElement end = m.HubIsInstalled(h) ? Kit.Text("Installed", 13, secondary: true, wrap: false)
                    : m.Running.Contains(h.Identifier) ? Kit.Spinner()
                    : m.ReadOnly ? Kit.Text("", 1) : Kit.RowAction("Get", () => m.Install(h), $"Get {h.Name}");
                rows.Add(Kit.Row(DisplayName.Title(h.Name), subtitleElement: words, trailing: end));
            }
            footer = results.Any(r => r.IsCommunity) ? "Community skills come from outside Nous. The gateway checks each one before it is installed." : null;
        }
        else
        {
            if (m.HubError is { } error) rows.Add(Kit.Pad(Kit.Text(error, 13, color: Kit.Caution)));
            rows.Add(Kit.Row($"Search the Skills Hub for “{term}”", leading: Kit.Glyph(Kit.Search, 14, Kit.Accent), click: m.SearchHub));
            footer = "Find skills beyond Hermes’s own: the official index, GitHub and community sources.";
        }
        page.Children.Add(Kit.Section("Skills Hub", rows, footer));
    }

    /// Skills' Marketplace section (`SkillsMarketplaceSection`): a few of its skills that match, and a way in.
    private void SkillsMarketplace(StackPanel page)
    {
        var catalog = CapabilitiesServices.SkillCatalog;
        if (catalog.Entries is not { } entries || entries.Count == 0) return;
        var installed = (Model.Skills ?? []).Select(s => s.Name).ToHashSet();
        var matches = Model.Trimmed.Length == 0 ? [] : entries.Where(e => e.Score(Model.Trimmed) > 0).OrderByDescending(e => e.Score(Model.Trimmed)).ToList();
        var rows = new List<UIElement>();
        foreach (var s in matches.Take(5))
        {
            UIElement end = installed.Contains(s.Name) ? Kit.Text("Installed", 13, secondary: true, wrap: false)
                : Model.Running.Contains(s.InstallIdentifier) ? Kit.Spinner()
                : Kit.RowAction("Install", () => Model.Install(s), $"Install {s.Name}");
            rows.Add(Kit.Row(s.Name, string.Join(" · ", new[] { s.Badge, s.Description }.Where(x => x.Length > 0)), trailing: end));
        }
        rows.Add(Kit.BrowseRow(matches.Count > 5 ? "See All Results" : "Open the Marketplace", matches.Count > 5 ? matches.Count : entries.Count,
            () => Push(new MarketplaceScreen(Model, MarketplaceKind.Skills, matches.Count > 5 ? Model.Trimmed : ""))));
        page.Children.Add(Kit.Section("Hermes Marketplace", rows, "Skills from Hermes, Nous, NVIDIA, OpenAI, Hugging Face and Anthropic, ready to install."));
    }

    // ---------------------------------------------------------------- Tools

    private void Tools(StackPanel page)
    {
        var m = Model;
        if (m.Toolsets is { } toolsets)
        {
            var shown = m.ShownToolsets;
            if (toolsets.Count == 0)
            {
                var empty = new StackPanel { Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center };
                empty.Children.Add(Kit.Glyph(Kit.Hammer, 28, Kit.Secondary));
                empty.Children.Add(Kit.Text("No Tools", 17, bold: true).Also(t => t.HorizontalAlignment = HorizontalAlignment.Center));
                empty.Children.Add(Kit.Text("This gateway has no tools to turn on or off.", 13, secondary: true));
                page.Children.Add(Kit.Pad(empty, 40));
            }
            else if (shown.Count == 0) page.Children.Add(NoResults(m.Trimmed));
            else
            {
                var rows = new List<UIElement>();
                if (m.Trimmed.Length == 0 && !m.ReadOnly)
                    rows.Add(Kit.SwitchRow("All Tools", m.AllToolsOn, m.SetAllTools, m.ToolToggling.Count == 0, bold: true));
                foreach (var t in shown)
                {
                    var meta = new TextBlock { FontSize = 12, Foreground = Kit.Secondary, TextWrapping = TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis };
                    meta.Inlines.Add(new Run { Text = CapabilitiesWords.ToolMeta(t, m.ToolUsage) });
                    if (!t.Configured)
                    {
                        meta.Inlines.Add(new Run { Text = " · " });
                        meta.Inlines.Add(new Run { Text = "Needs keys", Foreground = Kit.Caution });
                    }
                    var words = new StackPanel { Spacing = 2 };
                    if (t.Description.Length > 0) words.Children.Add(Kit.Text(t.Description, 12, secondary: true).Also(x => x.MaxLines = DensitySizes.DescriptionLines(ThemeService.State.Compact)));
                    words.Children.Add(meta);
                    rows.Add(Kit.Row(t.Label, subtitleElement: words, chevron: true, click: () => Push(new ToolsetScreen(m, t)),
                        trailing: m.ReadOnly ? null : Kit.Switch(t.Enabled, t.Label, on => m.SetToolset(t, on), !m.ToolToggling.Contains(t.Name))));
                }
                page.Children.Add(Kit.Section(null, rows, CapabilitiesWords.ChangesApply));
            }
        }
        else if (m.ToolsTooOld) page.Children.Add(Kit.Section(null, [Kit.Plain(CapabilitiesWords.ToolsTooOld, secondary: false)]));
        else if (m.ToolsError is { } error) page.Children.Add(Kit.LoadError("Couldn’t Load Tools", error, () => _ = m.ReloadTools()));
        else if (!Waiting(page)) page.Children.Add(Kit.Skeletons());
    }

    // ---------------------------------------------------------------- Connectors

    private void Connectors(StackPanel page)
    {
        var m = Model;
        var q = m.Trimmed;
        if (m.ServersNotice is { } notice)
            page.Children.Add(Kit.Section(null, [Kit.Notice(notice, Kit.Check, close: () => { m.ServersNotice = null; Render(); })]));
        Connected(page);
        var quiet = ManagedSection.IsQuiet(m);
        if (!quiet) ManagedSection.Build(this, page);
        if (q.Length == 0) Popular(page); else CatalogMatches(page);
        if (q.Length == 0 && !m.ReadOnly && (m.Servers != null || m.Catalog != null))
            page.Children.Add(Kit.Section("More Ways to Connect",
                [Kit.Row("Add Your Own", "By web address or command", leading: Kit.Tile(Kit.Add, 34), click: AddConnector, chevron: true)]));
        if (quiet) ManagedSection.Build(this, page);
        if (m.Focus != null && m.Servers != null) m.Focus = null;
    }

    private void Connected(StackPanel page)
    {
        var m = Model;
        if (m.Servers is { } servers)
        {
            var shown = m.ShownServers;
            if (servers.Count > 0 && !(shown.Count == 0 && m.Trimmed.Length > 0))
            {
                var rows = shown.Select(s => ConnectorRow(s)).ToList();
                page.Children.Add(Kit.Section("Connected", rows, CapabilitiesWords.ConnectedFooter(m.BotName)));
            }
            else if (servers.Count == 0 && m.Trimmed.Length == 0)
                page.Children.Add(Kit.Section("Connected", [Kit.Plain(CapabilitiesWords.NoConnectors(m.ReadOnly, m.CatalogAvailable.Count > 0, m.BotName))]));
        }
        else if (m.ServersError is { } error) page.Children.Add(Kit.LoadError("Couldn’t Load Connectors", error, () => _ = m.ReloadServers()));
        else if (!Waiting(page)) page.Children.Add(Kit.Skeletons(3, "Connected"));
    }

    private UIElement ConnectorRow(McpServer s)
    {
        var m = Model;
        var switchable = !m.ReadOnly && s.Source != "plugin";
        var title = m.TitleOf(s);
        var row = Kit.Row(title, leading: Kit.Logo(null, s.Name),
            subtitleElement: Kit.StatusLine(CapabilitiesWords.ShownWords(s), ConnectorTones.Of(s), CapabilitiesWords.RowWords(s)),
            trailing: switchable ? Kit.Switch(s.Enabled, title, on => m.SetMcp(s, on), !m.McpToggling.Contains(s.Name)) : null,
            chevron: !switchable, click: () => Push(new ConnectorScreen(m, s)));
        if (m.Focus == s.Name && row is FrameworkElement fe) fe.Loaded += (_, _) => fe.StartBringIntoView(new BringIntoViewOptions { VerticalAlignmentRatio = 0.5 });
        return row;
    }

    private void Popular(StackPanel page)
    {
        var m = Model;
        if (m.Catalog == null && m.IsConnected) { page.Children.Add(Kit.Skeletons(2, "Popular")); return; }
        var available = m.CatalogAvailable;
        var popular = available.Take(8).ToList();
        if (popular.Count == 0) return;
        var grid = new VariableSizedWrapGrid { Orientation = Orientation.Horizontal, ItemWidth = 168, ItemHeight = 88, Margin = new Thickness(8) };
        foreach (var e in popular)
        {
            var face = new StackPanel { Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center };
            face.Children.Add(Kit.Tile(Kit.SymbolFor(e.Name), 40).Also(t => ((FrameworkElement)t).HorizontalAlignment = HorizontalAlignment.Center));
            face.Children.Add(Kit.Text(e.Title, 12).Also(t => { t.TextAlignment = TextAlignment.Center; t.MaxLines = 2; t.HorizontalAlignment = HorizontalAlignment.Center; }));
            var b = new Button { Content = face, Width = 160, Height = 82, Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0) };
            AutomationProperties.SetName(b, e.Title);
            ToolTipService.SetToolTip(b, e.ShortDescription);
            b.Click += (_, _) => Push(new CatalogAppScreen(m, e));
            grid.Children.Add(b);
        }
        var rows = new List<UIElement> { grid };
        if (available.Count > popular.Count)
            rows.Add(Kit.BrowseRow("See All Apps", available.Count, () => Push(new CatalogBrowseScreen(m)), $"See all {available.Count} apps"));
        page.Children.Add(Kit.Section("Popular", rows));
    }

    private void CatalogMatches(StackPanel page)
    {
        var m = Model;
        var all = m.CatalogAvailable;
        if (m.Catalog == null || all.Count == 0) return;
        var shown = all.Where(e => e.Matches(m.Trimmed)).ToList();
        var rows = new List<UIElement>();
        if (shown.Count == 0) rows.Add(Kit.Plain($"No app matches “{m.Trimmed}”."));
        rows.AddRange(shown.Select(e => CatalogRow(m, e, this)));
        page.Children.Add(Kit.Section("Apps", rows));
    }

    public static UIElement CatalogRow(CapabilitiesModel m, McpCatalogEntry e, Screen from) =>
        Kit.Row(e.Title, e.ShortDescription, leading: Kit.Tile(Kit.SymbolFor(e.Name), 34), chevron: true, click: () => from.Push(new CatalogAppScreen(m, e)));

    // ---------------------------------------------------------------- Plugins

    private void Plugins(StackPanel page)
    {
        var m = Model;
        if (m.Plugins is { } plugins)
        {
            var shown = m.ShownPlugins;
            var q = m.Trimmed;
            UIElement Install() => Kit.Row("Install from Git…", leading: Kit.Glyph(Kit.Add, 14, Kit.Accent), click: () => Push(new PluginInstallScreen(m)));
            if (plugins.Count == 0 && m.PluginNotice == null)
            {
                if (q.Length == 0)
                {
                    var rows = new List<UIElement> { Kit.Plain(m.ReadOnly ? $"{m.BotName} has no plugins." : "None yet. Pick one below to add it.", secondary: false) };
                    if (!m.ReadOnly) rows.Add(Install());
                    page.Children.Add(Kit.Section($"Plugins for {m.BotName}", rows, "Plugins add tools, memory, models and more. Changes take effect after your gateway restarts."));
                }
                FindPlugins(page);
            }
            else if (shown.Count == 0 && m.PluginNotice == null && q.Length > 0) FindPlugins(page);
            else
            {
                var rows = new List<UIElement>();
                if (m.PluginNotice is { } notice)
                    rows.Add(Kit.Notice(notice, Kit.Info, Kit.Accent, m.PluginNeedsKeys ? "Open Keys" : null,
                        m.PluginNeedsKeys ? () => HermesHQ.Shell.Navigator.Open("settings", "keys") : null,
                        () => { m.PluginNotice = null; m.PluginNeedsKeys = false; Render(); }));
                if (plugins.Count == 0) rows.Add(Kit.Plain($"No plugins for {m.BotName}."));
                else if (shown.Count == 0) rows.Add(Kit.Plain($"No Results for “{q}”"));
                foreach (var p in shown) rows.Add(PluginRow(p));
                if (!m.ReadOnly) rows.Add(Install());
                page.Children.Add(Kit.Section($"Plugins for {m.BotName}", rows,
                    plugins.Count == 0 && !m.ReadOnly ? "Find one below, or install one from Git." : "Plugin changes take effect after your gateway restarts."));
                FindPlugins(page);
            }
        }
        else if (m.PluginsUnavailable) page.Children.Add(Kit.Section(null, [Kit.Plain(CapabilitiesWords.PluginsTooOld, secondary: false)]));
        else if (m.PluginsError is { } error) page.Children.Add(Kit.LoadError("Couldn’t Load Plugins", error, () => _ = m.ReloadPlugins()));
        else if (!Waiting(page)) page.Children.Add(Kit.Skeletons());
    }

    private UIElement PluginRow(PluginInfo p)
    {
        var m = Model;
        var words = new StackPanel { Spacing = 2 };
        var title = new TextBlock { FontSize = 14, TextWrapping = TextWrapping.Wrap };
        title.Inlines.Add(new Run { Text = p.Title, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        if (p.Version.Length > 0) title.Inlines.Add(new Run { Text = "  " + p.Version, FontSize = 12, Foreground = Kit.Secondary });
        words.Children.Add(title);
        if (p.Description.Length > 0) words.Children.Add(Kit.Text(p.Description, 12, secondary: true).Also(t => t.MaxLines = DensitySizes.DescriptionLines(ThemeService.State.Compact)));
        foreach (var w in p.Servers.Select(s => s.Words).OfType<string>()) words.Children.Add(Kit.Text(w, 12, color: Kit.Caution));
        foreach (var w in m.PluginWarnings.GetValueOrDefault(p.Name) ?? []) words.Children.Add(Kit.Text(McpEntryMask.Phone.Text(w), 12, color: Kit.Caution));
        if (p.UpdateAvailable) words.Children.Add(Kit.Text("Update available", 12, color: Kit.Accent));
        if (p.Key == null) words.Children.Add(Kit.Text($"Update Hermes on {HostWord.UpdateTarget} to turn this plugin on or off here.", 12, secondary: true));
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(words);
        var chevron = Kit.Glyph(Kit.Chevron, 12, Kit.Tertiary);
        chevron.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(chevron, 1);
        grid.Children.Add(chevron);
        var open = new Button
        {
            Content = grid, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(14, 9, 8, 9),
        };
        AutomationProperties.SetName(open, p.Title);
        open.Click += (_, _) => Push(new PluginScreen(m, p));
        var outer = new Grid();
        outer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        outer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        outer.Children.Add(open);
        if (p.Key != null && !m.ReadOnly)
        {
            var sw = Kit.Switch(p.Enabled, p.Title, on => m.SetPlugin(p, on), !m.PluginBusy.Contains(p.Name));
            sw.VerticalAlignment = VerticalAlignment.Center;
            sw.Margin = new Thickness(0, 0, 4, 0);
            Grid.SetColumn(sw, 1);
            outer.Children.Add(sw);
        }
        return outer;
    }

    /// Find Plugins: the catalog's most-starred this bot doesn't have, at most two of a kind; matches while searching.
    private void FindPlugins(StackPanel page)
    {
        var m = Model;
        var catalog = CapabilitiesServices.PluginCatalog;
        var q = m.Trimmed;
        if (catalog.Entries is { } entries)
        {
            if (q.Length == 0)
            {
                var rows = PluginCatalogEntry.Picks(m.PluginCatalogAvailable, 5).Select(e => PluginCatalogRow(m, e, this)).ToList();
                rows.Add(Kit.BrowseRow("Open the Marketplace", entries.Count, () => Push(new MarketplaceScreen(m, MarketplaceKind.Plugins)), $"Open the Marketplace, {entries.Count} plugins"));
                page.Children.Add(Kit.Section("Find Plugins", rows, "Popular plugins from the Hermes Marketplace. Nous reviews every one before it is listed."));
            }
            else
            {
                var matches = PluginCatalogEntry.Search(entries, q);
                var rows = new List<UIElement>();
                if (matches.Count == 0) rows.Add(Kit.Plain($"No plugin in the Hermes catalog matches “{q}”."));
                rows.AddRange(matches.Take(8).Select(e => PluginCatalogRow(m, e, this)));
                if (matches.Count > 8) rows.Add(Kit.BrowseRow("See All Results", matches.Count, () => Push(new MarketplaceScreen(m, MarketplaceKind.Plugins, q))));
                page.Children.Add(Kit.Section("Hermes Marketplace", rows));
            }
        }
        else if (catalog.Error is { } error)
            page.Children.Add(Kit.Section("Find Plugins", [Kit.Plain(error), Kit.Pad(Kit.Button("Try Again", async () => { await catalog.LoadAsync(force: true); Render(); }))]));
        else if (q.Length == 0) page.Children.Add(Kit.Skeletons(3, "Find Plugins"));
    }

    public static UIElement PluginCatalogRow(CapabilitiesModel m, PluginCatalogEntry e, Screen from)
    {
        var installed = m.InstalledPlugin(e) != null;
        var line = string.Join(" · ", new[] { e.TierWord ?? "", e.Maintainer, e.Summary }.Where(s => s.Length > 0));
        UIElement? end = installed ? Kit.Text("Installed", 13, color: Kit.Success, wrap: false)
            : e.Stars is { } stars ? Kit.Text($"★ {Toolset.Compact(stars)}", 12, secondary: true, wrap: false) : null;
        return Kit.Row(e.Title, line, trailing: end, chevron: true, click: () => from.Push(new PluginCatalogEntryScreen(m, e)),
            subtitleLines: DensitySizes.DescriptionLines(ThemeService.State.Compact));
    }
}
