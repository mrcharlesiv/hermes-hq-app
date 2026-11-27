using Hermes.Core.Capabilities;
using HermesHQ.Shell;
using DensitySizes = Hermes.Core.Settings.DensitySizes;
using ThemeService = HermesHQ.Features.Settings.ThemeService;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Navigation;

namespace HermesHQ.Features.Capabilities;

/// The Marketplace place: the store front on its own, installing to Hermes until Install To says otherwise.
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class MarketplacePage : Page
{
    private readonly StackHost _host = new();

    public MarketplacePage() => Content = _host;

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        var profile = (e.Parameter as PlaceArgs)?.Argument as string;
        var model = new CapabilitiesModel(CapabilitiesTab.Plugins, profile);
        // The Mac's store front opens on Discover (the featured pick and the shelves).
        _host.Reset(new MarketplaceScreen(model, MarketplaceKind.All));
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        _host.Top?.Hidden();
    }
}

/// The Hermes Marketplace (App/Capabilities/Marketplace.swift), laid out as the Mac's store front: a side list
/// (Discover, Plugins and Skills with their kinds, Install To) and the cards: the featured pick and the shelves on
/// Discover, else the Official · Certified · Community chips, Sort By and the results. Plugins come from plugins.json,
/// skills from the Marketplace page; everything installs for the bot in Install To.
internal sealed class MarketplaceScreen : Screen
{
    private readonly CapabilitiesModel _m;
    private readonly MarketplaceState _state;

    public MarketplaceScreen(CapabilitiesModel model, MarketplaceKind kind, string query = "")
    {
        _m = model;
        _state = new MarketplaceState(kind, query);
        Query = query;
    }

    public override string Title => "Marketplace";
    public override string? SearchPrompt => MarketplaceWords.SearchPrompt;

    public override IEnumerable<MenuFlyoutItemBase> Menu()
    {
        var sort = new MenuFlyoutSubItem { Text = "Sort By", Icon = new FontIcon { Glyph = Kit.Sort } };
        foreach (var s in Enum.GetValues<MarketplaceSort>())
            sort.Items.Add(Kit.CheckItem(s.Title(), _state.Sort == s, () => { _state.Sort = s; _state.Limit = MarketplaceState.PageSize; Render(); }));
        yield return sort;
        yield return Kit.Item("Refresh", Kit.Refresh, () => _ = RefreshAsync());
    }

    public override async Task RefreshAsync()
    {
        await Task.WhenAll(CapabilitiesServices.PluginCatalog.LoadAsync(force: true), CapabilitiesServices.SkillCatalog.LoadAsync(force: true));
        Render();
    }

    public override async void Shown()
    {
        _m.RootSource = () => Root;
        _m.Changed += Render;
        var loads = new List<Task> { CapabilitiesServices.PluginCatalog.LoadAsync(), CapabilitiesServices.SkillCatalog.LoadAsync() };
        if (_m.Plugins == null) loads.Add(_m.ReloadPlugins());
        if (_m.Skills == null) loads.Add(_m.ReloadSkills());
        Render();
        await Task.WhenAll(loads);
        Render();
    }

    public override void Hidden() => _m.Changed -= Render;

    private IReadOnlyList<PluginCatalogEntry> Plugins => CapabilitiesServices.PluginCatalog.Entries ?? [];
    private IReadOnlyList<MarketSkill> Skills => CapabilitiesServices.SkillCatalog.Entries ?? [];

    private bool SkillInstalled(MarketSkill s) => _m.HubInstalled.Contains(s.InstallIdentifier) || (_m.Skills ?? []).Any(k => k.Name == s.Name);

    private void Choose(MarketplaceKind kind, string? category = null)
    {
        _state.Choose(kind);
        if (category != null) _state.Categories.Add(category);
        Render();
    }

    public override void Build(StackPanel page)
    {
        _state.Query = Query;
        var wide = Host.ActualWidth >= 900;
        var main = new StackPanel();
        if (wide)
        {
            var grid = new Grid { ColumnSpacing = 24 };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(200) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.Children.Add(Side());
            Grid.SetColumn(main, 1);
            grid.Children.Add(main);
            page.Children.Add(grid);
        }
        else
        {
            // Mac 1270 ordinary pane (~767 px): All / Plugins / Skills segments above full-width content instead of a 200 px sidebar.
            page.Children.Add(CompactBar());
            page.Children.Add(main);
        }
        if (_state.Browsing) Discover(main); else Results(main);
    }

    private UIElement CompactBar()
    {
        var bar = new Grid { Margin = new Thickness(0, 0, 0, 12), ColumnSpacing = 12 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var segs = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        void Seg(string label, bool on, Action pick)
        {
            var b = new Button
            {
                Content = label, Padding = new Thickness(12, 5, 12, 5), CornerRadius = new CornerRadius(14),
                BorderThickness = new Thickness(1),
                Background = on ? Kit.Accent : Kit.Brush("SubtleFillColorSecondaryBrush"),
                Foreground = on ? Kit.Brush("TextOnAccentFillColorPrimaryBrush") : Kit.Brush("TextFillColorPrimaryBrush"),
                BorderBrush = on ? Kit.Accent : Kit.Brush("ControlStrokeColorDefaultBrush"),
            };
            AutomationProperties.SetName(b, label);
            b.Click += (_, _) => pick();
            segs.Children.Add(b);
        }
        Seg("All", _state.Kind == MarketplaceKind.All, () => { _state.Choose(MarketplaceKind.All); _state.Tiers.Clear(); Render(); });
        Seg("Plugins", _state.Kind == MarketplaceKind.Plugins, () => Choose(MarketplaceKind.Plugins));
        Seg("Skills", _state.Kind == MarketplaceKind.Skills, () => Choose(MarketplaceKind.Skills));
        bar.Children.Add(segs);
        var bots = CapabilitiesServices.Bots();
        if (bots.Count > 1)
        {
            var box = new ComboBox { MinWidth = 120 };
            var names = bots.Select(b => b.Name).ToList();
            if (!names.Contains(_m.Profile)) { names.Insert(0, _m.Profile); box.Items.Add(_m.BotName); }
            foreach (var b in bots) box.Items.Add(b.DisplayName);
            box.SelectedIndex = names.IndexOf(_m.Profile);
            AutomationProperties.SetName(box, "Install To");
            box.SelectionChanged += (_, _) =>
            {
                if (box.SelectedIndex < 0 || names[box.SelectedIndex] == _m.Profile) return;
                _m.SetProfile(names[box.SelectedIndex]);
                _ = _m.ReloadSkills();
            };
            Grid.SetColumn(box, 2);
            bar.Children.Add(box);
        }
        return bar;
    }

    // ---------------------------------------------------------------- The side list

    private UIElement Side()
    {
        var side = new StackPanel { Spacing = 2 };
        UIElement Row(string title, string glyph, int? count, bool on, Action pick)
        {
            var g = new Grid { ColumnSpacing = 8 };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.Children.Add(Kit.Glyph(glyph, 13, on ? Kit.Accent : Kit.Secondary));
            var t = Kit.Text(title, 13, bold: on, wrap: false);
            Grid.SetColumn(t, 1);
            g.Children.Add(t);
            if (count is { } n) { var c = Kit.Text(n.ToString("N0"), 12, secondary: true, wrap: false); Grid.SetColumn(c, 2); g.Children.Add(c); }
            var b = new Button
            {
                Content = g, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Padding = new Thickness(8, 5, 8, 5), BorderThickness = new Thickness(0),
                Background = on ? Kit.Brush("SubtleFillColorSecondaryBrush") : new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent),
            };
            AutomationProperties.SetName(b, title);
            b.Click += (_, _) => pick();
            return b;
        }
        UIElement Head(string text) => Kit.Text(text, 12, bold: true, color: Kit.Secondary).Also(t => t.Margin = new Thickness(8, 12, 0, 4));
        side.Children.Add(Row("Discover", "", null, _state.Browsing, () => { _state.Choose(MarketplaceKind.All); _state.Tiers.Clear(); _state.Sort = MarketplaceSort.Stars; Query = ""; Host.Render(this); ClearSearch(); }));
        side.Children.Add(Head("Plugins"));
        side.Children.Add(Row("All Plugins", Kit.Puzzle, CapabilitiesServices.PluginCatalog.Entries?.Count, _state.Kind == MarketplaceKind.Plugins && _state.Categories.Count == 0, () => Choose(MarketplaceKind.Plugins)));
        foreach (var c in PluginCatalogCategories.All)
        {
            var n = Plugins.Count(p => p.Category == c);
            if (n == 0) continue;
            side.Children.Add(Row(c.Title(), "", n, _state.Kind == MarketplaceKind.Plugins && _state.Categories.Contains(c.Raw()), () => Choose(MarketplaceKind.Plugins, c.Raw())));
        }
        side.Children.Add(Head("Skills"));
        side.Children.Add(Row("All Skills", Kit.Sparkles, CapabilitiesServices.SkillCatalog.Entries?.Count, _state.Kind == MarketplaceKind.Skills && _state.Categories.Count == 0, () => Choose(MarketplaceKind.Skills)));
        foreach (var g in Skills.GroupBy(s => s.Category).OrderBy(g => g.Key == "other" ? 1 : 0).ThenBy(g => g.First().CategoryLabel, StringComparer.CurrentCultureIgnoreCase))
            side.Children.Add(Row(g.First().CategoryLabel, "", g.Count(), _state.Kind == MarketplaceKind.Skills && _state.Categories.Contains(g.Key), () => Choose(MarketplaceKind.Skills, g.Key)));
        side.Children.Add(Kit.Text("Install To", 12, secondary: true).Also(t => t.Margin = new Thickness(8, 16, 0, 4)));
        var bots = CapabilitiesServices.Bots();
        var box = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(8, 0, 0, 0) };
        var names = bots.Select(b => b.Name).ToList();
        if (!names.Contains(_m.Profile)) { names.Insert(0, _m.Profile); box.Items.Add(_m.BotName); }
        foreach (var b in bots) box.Items.Add(b.DisplayName);
        box.SelectedIndex = names.IndexOf(_m.Profile);
        AutomationProperties.SetName(box, "Install To");
        box.SelectionChanged += (_, _) =>
        {
            if (box.SelectedIndex < 0 || names[box.SelectedIndex] == _m.Profile) return;
            _m.SetProfile(names[box.SelectedIndex]);
            _ = _m.ReloadSkills();
        };
        side.Children.Add(box);
        return side;
    }

    private void ClearSearch() => Host.Render(this);

    // ---------------------------------------------------------------- Discover

    private void Discover(StackPanel main)
    {
        var plugins = CapabilitiesServices.PluginCatalog;
        var skills = CapabilitiesServices.SkillCatalog;
        if (plugins.Entries is { } entries)
        {
            var featured = MarketplaceFeatured.Picks(entries);
            if (featured.Count == 1) main.Children.Add(Hero(featured[0]));
            else if (featured.Count > 1)
            {
                // Mac 1270: horizontal scrollable row exposing all ranked featured picks (not just featured[0]).
                var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Padding = new Thickness(0, 0, 12, 8) };
                foreach (var pick in featured)
                {
                    var card = Hero(pick);
                    if (card is FrameworkElement fe) fe.Width = 340;
                    row.Children.Add(card);
                }
                main.Children.Add(new ScrollViewer
                {
                    Content = row, HorizontalScrollMode = ScrollMode.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                    VerticalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
                    Margin = new Thickness(0, 0, 0, 14),
                });
            }
            var quality = MarketplaceFeatured.QualityOfLife(entries);
            if (quality.Count > 0)
                main.Children.Add(Shelf("Quality of Life Improvements", MarketplaceWords.QualityBlurb, quality.Select(PluginCard),
                    ("See All", () => Choose(MarketplaceKind.Plugins, PluginCatalogCategory.Tools.Raw()))));
            if (MarketplaceFeatured.Spotlight(entries) is var (maker, picks))
                main.Children.Add(Shelf($"Spotlight: {maker}", $"{picks.Count} picks from the community maintainer with the most plugins in the catalog.",
                    picks.Select(PluginCard), ("See All", () => { _state.Choose(MarketplaceKind.Plugins); Query = maker; Host.Render(this); })));
        }
        else Loading(main, "plugins", plugins.Error, () => plugins.LoadAsync(force: true));
        if (skills.Entries is { } skillEntries)
        {
            var nous = skillEntries.Where(s => s.IsOfficial).Take(6).ToList();
            if (nous.Count > 0)
                main.Children.Add(Shelf("Skills from Nous", MarketplaceWords.SkillsBlurb, nous.Select(SkillCard),
                    ($"See All {skillEntries.Count:N0} Skills", () => Choose(MarketplaceKind.Skills))));
        }
        else Loading(main, "skills", skills.Error, () => skills.LoadAsync(force: true));
        main.Children.Add(Kit.Section("Talk to Hermes Anywhere", MarketplaceFeatured.Anywhere.Select(a =>
            Kit.Row(a.Name, a.Words, leading: Kit.Tile("", 34), chevron: true, click: () => Navigator.Open("messaging"))),
            "Chat where you already are. Set each one up in Messaging, or add more chat apps with a plugin."));
        main.Children.Add(Kit.Section("More",
        [
            Kit.Row("Connectors", "Connect Hermes to the apps you already use, with one sign-in each.", leading: Kit.Tile(Kit.Plug, 34), chevron: true,
                click: () => Push(new ListScreen(CapabilitiesTab.Connectors, _m.Profile, false))),
            Kit.Row("Make a Hermes Plugin", "Build a plugin or a skill for Hermes and send it to Nous to be listed.", leading: Kit.Tile("", 34),
                trailing: Kit.Glyph(Kit.OpenOut, 12, Kit.Tertiary), click: () => Kit.Open(MarketplaceFeatured.DeveloperUrl)),
            Kit.Row("Open the Marketplace Website", "Everything in the Marketplace, in your browser.", leading: Kit.Tile(Kit.Globe, 34),
                trailing: Kit.Glyph(Kit.OpenOut, 12, Kit.Tertiary), click: () => Kit.Open(MarketplaceFeatured.WebsiteUrl)),
        ]));
    }

    private void Loading(StackPanel main, string what, string? error, Func<Task> retry)
    {
        if (error != null)
            main.Children.Add(Kit.Section(null, [Kit.Plain($"The Marketplace’s {what} didn’t load. {error}"), Kit.Pad(Kit.Button("Try Again", async () => { await retry(); Render(); }))]));
        else main.Children.Add(Kit.Section(null, [Kit.Busy($"Loading {what}…")]));
    }

    private UIElement Hero(PluginCatalogEntry e)
    {
        var s = new StackPanel { Spacing = 8 };
        s.Children.Add(Kit.Text("FEATURED THIS WEEK", 11, bold: true, color: Kit.Accent));
        s.Children.Add(Kit.Text(e.Title, 22, bold: true));
        s.Children.Add(Kit.Text(string.Join(" · ", new[] { e.TierWord ?? "", e.Maintainer.Length > 0 ? $"by {e.Maintainer}" : "" }.Where(x => x.Length > 0)), 13, secondary: true));
        s.Children.Add(Kit.Text(e.Summary, 14));
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        if (_m.InstalledPlugin(e) != null) line.Children.Add(Kit.Text("✓ Installed", 13, bold: true, color: Kit.Success));
        else line.Children.Add(Kit.Button("Install", () => AskPlugin(e), accent: true, name: $"Install {e.Title}"));
        line.Children.Add(Kit.Button("Details", () => Push(new PluginCatalogEntryScreen(_m, e))));
        s.Children.Add(line);
        AutomationProperties.SetName(s, $"Featured: {e.Title}, by {e.Maintainer}");
        return Kit.Section(null, [Kit.Pad(s, 16)]);
    }

    private UIElement Shelf(string title, string about, IEnumerable<UIElement> cards, (string Title, Action Run)? seeAll)
    {
        var head = new Grid();
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var words = new StackPanel { Spacing = 2 };
        words.Children.Add(Kit.Text(title, 16, bold: true));
        words.Children.Add(Kit.Text(about, 12, secondary: true));
        head.Children.Add(words);
        if (seeAll is var (t, run)) { var l = Kit.Link(t, run); Grid.SetColumn(l, 1); head.Children.Add(l); }
        var wrap = new VariableSizedWrapGrid { Orientation = Orientation.Horizontal, ItemWidth = 250, ItemHeight = 120 };
        foreach (var c in cards) wrap.Children.Add(c);
        var s = new StackPanel { Spacing = 8, Margin = new Thickness(0, 0, 0, 22) };
        s.Children.Add(head);
        s.Children.Add(wrap);
        return s;
    }

    private UIElement Card(string title, string by, string summary, string? badge, UIElement action, Action open)
    {
        var s = new StackPanel { Spacing = 4 };
        var top = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        top.Children.Add(Kit.Text(title, 14, bold: true, wrap: false));
        if (badge != null) top.Children.Add(Kit.Badge(badge, ConnectorTone.Quiet));
        s.Children.Add(top);
        if (by.Length > 0) s.Children.Add(Kit.Text(by, 12, secondary: true, wrap: false));
        s.Children.Add(Kit.Text(summary, 12, secondary: true).Also(t => t.MaxLines = DensitySizes.DescriptionLines(ThemeService.State.Compact)));
        var g = new Grid { RowSpacing = 6 };
        g.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        g.Children.Add(s);
        Grid.SetRow((FrameworkElement)action, 1);
        g.Children.Add(action);
        var b = new Button
        {
            Content = g, Width = 240, Height = 112, Padding = new Thickness(12, 10, 12, 10), HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Stretch, Background = Kit.Brush("CardBackgroundFillColorDefaultBrush"),
            BorderBrush = Kit.Brush("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8),
        };
        AutomationProperties.SetName(b, title);
        b.Click += (_, _) => open();
        return b;
    }

    private UIElement PluginCard(PluginCatalogEntry e)
    {
        UIElement action = _m.InstalledPlugin(e) != null ? Kit.Text("✓ Installed", 12, bold: true, color: Kit.Success)
            : Kit.Link("Install", () => AskPlugin(e)).Also(l => AutomationProperties.SetName(l, $"Install {e.Title}"));
        var by = string.Join(" · ", new[] { e.Maintainer, e.Stars is { } n ? $"★ {Toolset.Compact(n)}" : "" }.Where(x => x.Length > 0));
        return Card(e.Title, by, e.Summary, e.TierWord, action, () => Push(new PluginCatalogEntryScreen(_m, e)));
    }

    private UIElement SkillCard(MarketSkill s)
    {
        UIElement action = SkillInstalled(s) ? Kit.Text("✓ Installed", 12, bold: true, color: Kit.Success)
            : _m.Running.Contains(s.InstallIdentifier) ? Kit.Spinner()
            : Kit.Link("Install", () => _m.Install(s)).Also(l => AutomationProperties.SetName(l, $"Install {s.Name}"));
        return Card(s.Name, s.SourceWord, s.Description, s.Badge, action, () => { if (s.PageUrl is { } u) Kit.Open(u.ToString()); });
    }

    private async void AskPlugin(PluginCatalogEntry e)
    {
        try
        {
            if (await Kit.Confirm(Root, $"Install {e.Title} for {_m.BotName}?", MarketplaceWords.PluginInstallMessage(e), "Install"))
                Push(new PluginCatalogEntryScreen(_m, e, autoInstall: true));
        }
        catch (Exception ex) { HermesHQ.Services.AppLog.Error("capabilities", ex); }
    }

    // ---------------------------------------------------------------- Results

    private void Results(StackPanel main)
    {
        var items = _state.Scoped(Plugins, Skills);
        var category = _state.Categories.Count == 1 ? _state.Categories.First() : null;
        var plugin = category != null ? PluginCatalogCategories.Parse(category) : null;
        var title = _state.Trimmed.Length > 0 ? $"Results for “{_state.Trimmed}”"
            : plugin is { } pc && _state.Kind == MarketplaceKind.Plugins ? pc.Title()
            : category != null ? Skills.FirstOrDefault(s => s.Category == category)?.CategoryLabel ?? category
            : _state.Kind == MarketplaceKind.Plugins ? "All Plugins" : _state.Kind == MarketplaceKind.Skills ? "All Skills" : "Plugins and Skills";
        var blurb = _state.Trimmed.Length == 0 ? plugin is { } p2 && _state.Kind == MarketplaceKind.Plugins ? p2.Blurb()
            : category == null && _state.Kind == MarketplaceKind.Skills ? MarketplaceWords.SkillsBlurb : null : null;
        main.Children.Add(Kit.Text(title, 20, bold: true));
        if (blurb != null) main.Children.Add(Kit.Text(blurb, 13, secondary: true));

        // Official · Certified · Community.
        var tiers = _state.TierRows(items);
        if (tiers.Count > 0)
        {
            var chips = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(0, 10, 0, 0) };
            foreach (var (tier, count) in tiers)
            {
                var on = _state.Tiers.Contains(tier);
                var chip = new ToggleButton { Content = $"{tier.Title()} {count}", IsChecked = on, CornerRadius = new CornerRadius(12), Padding = new Thickness(10, 3, 10, 4) };
                chip.Click += (_, _) => { if (!_state.Tiers.Remove(tier)) _state.Tiers.Add(tier); _state.Limit = MarketplaceState.PageSize; Render(); };
                chips.Children.Add(chip);
            }
            main.Children.Add(chips);
        }
        main.Children.Add(Kit.Text($"Sort: {_state.Sort.Title()}", 12, secondary: true).Also(t => t.Margin = new Thickness(0, 8, 0, 8)));

        var plugins = CapabilitiesServices.PluginCatalog;
        var skills = CapabilitiesServices.SkillCatalog;
        if (_state.Kind != MarketplaceKind.Skills && plugins.Entries == null) Loading(main, "plugins", plugins.Error, () => plugins.LoadAsync(force: true));
        if (_state.Kind != MarketplaceKind.Plugins && skills.Entries == null) Loading(main, "skills", skills.Error, () => skills.LoadAsync(force: true));
        var results = _state.Ordered(_state.Filter(items));
        if (results.Count == 0 && (plugins.Entries != null || skills.Entries != null))
        {
            main.Children.Add(Kit.Section(null, [Kit.Plain(_state.Trimmed.Length == 0 ? MarketplaceWords.NothingMatches : MarketplaceWords.NothingFor(_state.Trimmed))]));
            return;
        }
        var rows = results.Take(_state.Limit).Select(i => i.Plugin is { } p
            ? ListScreen.PluginCatalogRow(_m, p, this)
            : SkillRow(i.Skill!)).ToList();
        var left = results.Count - _state.Limit;
        if (left > 0) rows.Add(Kit.BrowseRow($"Show {left:N0} More", null, () => { _state.Limit += MarketplaceState.PageSize; Render(); }, $"Show more, {left} left"));
        var footer = _state.Kind == MarketplaceKind.Skills ? MarketplaceWords.SkillsFooter : _state.Kind == MarketplaceKind.Plugins ? MarketplaceWords.PluginsFooter : null;
        main.Children.Add(Kit.Section(null, rows, footer));
    }

    private UIElement SkillRow(MarketSkill s)
    {
        UIElement end = SkillInstalled(s) ? Kit.Text("Installed", 13, color: Kit.Success, wrap: false)
            : _m.Running.Contains(s.InstallIdentifier) ? Kit.Spinner()
            : _m.ReadOnly ? Kit.Text("", 1) : Kit.RowAction("Install", () => _m.Install(s), $"Install {s.Name}");
        return Kit.Row(s.Name, string.Join(" · ", new[] { s.Badge, s.CategoryLabel, s.Description }.Where(x => x.Length > 0)), trailing: end,
            click: s.PageUrl is { } u ? () => Kit.Open(u.ToString()) : null, subtitleLines: DensitySizes.DescriptionLines(ThemeService.State.Compact));
    }
}
