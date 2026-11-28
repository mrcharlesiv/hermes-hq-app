using Hermes.Core.Capabilities;
using Hermes.Core.Composio;
using Hermes.Core.Gateways;
using Hermes.Core.Model;
using HermesHQ.Controls;
using HermesHQ.Features.Capabilities;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using Windows.System;
using Windows.UI;

namespace HermesHQ.Features.ConnectApps;

/// Connect Apps (Composio) page: API key setup / gateway reveal, Home (Connected + Popular + Categories + Search),
/// Bots assignment & All Bots, per-app Connect Link OAuth, multi-account management, Try It prompts, and Account Options
/// (`App/ConnectApps/ConnectAppsViews.swift`).
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class ConnectAppsPage : Page, IKeyRefreshing
{
    private abstract record Route
    {
        public sealed record Root : Route;
        public sealed record Bots : Route;
        public sealed record Category(ComposioCategory Value) : Route;
        public sealed record AllApps : Route;
        public sealed record AppDetail(ComposioToolkit Toolkit) : Route;
        public sealed record AccountDetail(ComposioToolkit Toolkit, string AccountId) : Route;
        public sealed record Actions(string AppName, IReadOnlyList<ComposioTool> Tools) : Route;
    }

    private readonly List<Route> _stack = [new Route.Root()];
    private readonly Button _backBtn = new() { Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(6, 4, 10, 4) };
    private readonly TextBlock _backWords = new() { FontSize = 14 };
    private readonly TextBlock _title = new() { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly TextBox _search = new() { Width = 240, Visibility = Visibility.Collapsed, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _moreBtn = new() { Content = Kit.Glyph(Kit.More, 14), Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(8, 6, 8, 6) };
    private readonly ScrollViewer _scroll = new() { HorizontalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    private readonly StackPanel _column = new() { MaxWidth = 760, Padding = new Thickness(24, 16, 24, 32) };

    private ComposioModel? _model;
    private string _setupKeyDraft = "";
    private ComposioNotice? _pasteNotice;
    private bool _triedGatewayKey;

    // Sub-route state
    private string _categoryFilter = "";
    private List<ComposioToolkit>? _categoryItems;
    private string? _categoryError;
    private string _allAppsQuery = "";
    private List<ComposioToolkit>? _allAppsItems;
    private string _allAppsNext = "";
    private string? _allAppsError;
    private bool _allAppsLoadingMore;
    private int _allAppsGen;
    private string _actionsFilter = "";

    // App / Account detail state
    private ComposioToolkit? _detailToolkit;
    private List<ComposioTool>? _detailTools;
    private bool _disconnecting;
    private string? _disconnectError;
    private string? _askingPrompt;
    private bool _addingAccount;
    private string? _accountNotice;
    private string? _busyAccountId;
    private bool _suppressSearchEvent;

    public ConnectAppsPage()
    {
        NavigationCacheMode = NavigationCacheMode.Disabled;
        AutomationProperties.SetName(this, "Connect Apps");
        AutomationProperties.SetAutomationId(this, "connect-apps.page");

        var backFace = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        backFace.Children.Add(Kit.Glyph(Kit.Back, 12));
        backFace.Children.Add(_backWords);
        _backBtn.Content = backFace;
        AutomationProperties.SetName(_backBtn, "Back");
        _backBtn.Click += (_, _) => GoBack();

        PageBar.Title(_title, "connect-apps");

        _search.TextChanged += OnSearchChanged;

        AutomationProperties.SetName(_moreBtn, "Account Options");
        AutomationProperties.SetAutomationId(_moreBtn, "connect-apps.account");
        ToolTipService.SetToolTip(_moreBtn, "Account Options");
        _moreBtn.Click += (_, _) => ShowAccountMenu();

        var bar = new Grid { Padding = PageBar.Padding(10, 10), ColumnSpacing = 8 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.Children.Add(_backBtn);
        Grid.SetColumn(_title, 1);
        bar.Children.Add(_title);
        Grid.SetColumn(_search, 2);
        bar.Children.Add(_search);
        Grid.SetColumn(_moreBtn, 3);
        bar.Children.Add(_moreBtn);

        _scroll.Content = _column;
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(bar);
        Grid.SetRow(_scroll, 1);
        root.Children.Add(_scroll);
        Content = root;

        KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        var findAccel = new KeyboardAccelerator { Key = VirtualKey.F, Modifiers = VirtualKeyModifiers.Control };
        findAccel.Invoked += (_, e) => { if (_search.Visibility == Visibility.Visible) { _search.Focus(FocusState.Keyboard); e.Handled = true; } };
        KeyboardAccelerators.Add(findAccel);
        var backAccel = new KeyboardAccelerator { Key = VirtualKey.Left, Modifiers = VirtualKeyModifiers.Menu };
        backAccel.Invoked += (_, e) => { GoBack(); e.Handled = true; };
        KeyboardAccelerators.Add(backAccel);
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _model?.Dispose();
        _model = new ComposioModel();
        _model.Changed += Render;
        _stack.Clear();
        _stack.Add(new Route.Root());
        _setupKeyDraft = "";
        _pasteNotice = null;
        Render();
        _ = _model.StartAsync();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        UiTree.DeactivateProgressRings(_column);
        if (_model != null)
        {
            _model.Changed -= Render;
            _model.Dispose();
            _model = null;
        }
    }

    public void KeyRefresh()
    {
        if (_model == null) return;
        if (_model.Phase == ComposioPhase.Ready) _ = RefreshReadyAsync();
        else _ = _model.StartAsync();
    }

    private async Task RefreshReadyAsync()
    {
        if (_model == null) return;
        await Task.WhenAll(_model.LoadHomeAsync(), _model.LoadBotsAsync());
    }

    private Route Top => _stack[^1];

    private void Push(Route route)
    {
        _stack.Add(route);
        OnEnterRoute(route);
        _scroll.ChangeView(null, 0, null, true);
        Render();
    }

    private void GoBack()
    {
        if (_stack.Count <= 1)
        {
            Navigator.Open("capabilities");
            return;
        }
        if (Top is Route.AppDetail) _model?.CancelConnect();
        _stack.RemoveAt(_stack.Count - 1);
        if (Top is Route.Root && _model?.Phase == ComposioPhase.Ready) _ = _model.LoadHomeAsync();
        Render();
    }

    private void OnEnterRoute(Route route)
    {
        switch (route)
        {
            case Route.Category cat:
                _categoryFilter = "";
                _categoryItems = null;
                _categoryError = null;
                _ = LoadCategoryAsync(cat.Value);
                break;
            case Route.AllApps:
                _allAppsQuery = "";
                _allAppsItems = null;
                _allAppsNext = "";
                _allAppsError = null;
                _allAppsLoadingMore = false;
                _ = LoadAllAppsAsync(reset: true);
                break;
            case Route.AppDetail app:
                _detailToolkit = app.Toolkit;
                _detailTools = null;
                _disconnecting = false;
                _disconnectError = null;
                _askingPrompt = null;
                _addingAccount = false;
                _accountNotice = null;
                _busyAccountId = null;
                _model?.ReadIdentities();
                _ = LoadAppDetailAsync(app.Toolkit);
                break;
            case Route.AccountDetail acc:
                _accountNotice = null;
                _disconnecting = false;
                _busyAccountId = null;
                if (_model != null && _model.AppAccounts.TryGetValue(acc.Toolkit.Slug, out var accs))
                {
                    var found = accs.FirstOrDefault(a => a.Id == acc.AccountId);
                    if (found != null) _ = _model.LoadIdentitiesAsync(acc.Toolkit.Slug, [found], again: !_model.Identities.ContainsKey(found.Id));
                }
                break;
            case Route.Actions:
                _actionsFilter = "";
                break;
        }
    }

    private void OnSearchChanged(object sender, TextChangedEventArgs e)
    {
        if (_suppressSearchEvent || _model == null) return;
        var text = _search.Text;
        switch (Top)
        {
            case Route.Root:
                _model.SetQuery(text);
                break;
            case Route.Category:
                _categoryFilter = text;
                Render();
                break;
            case Route.AllApps:
                _allAppsQuery = text;
                _allAppsGen++;
                var mine = _allAppsGen;
                _ = Task.Run(async () =>
                {
                    await Task.Delay(300);
                    DispatcherQueue.TryEnqueue(() => { if (mine == _allAppsGen) _ = LoadAllAppsAsync(reset: true); });
                });
                break;
            case Route.Actions:
                _actionsFilter = text;
                Render();
                break;
        }
    }

    private void Render()
    {
        if (_model == null || AppShutdown.Stopping) return;

        UpdateChrome();
        var offset = _scroll.VerticalOffset;
        UiTree.ClearPanel(_column);

        switch (Top)
        {
            case Route.Root:
                BuildRoot();
                break;
            case Route.Bots:
                BuildBots();
                break;
            case Route.Category cat:
                BuildCategory(cat.Value);
                break;
            case Route.AllApps:
                BuildAllApps();
                break;
            case Route.AppDetail app:
                BuildAppDetail(_detailToolkit ?? app.Toolkit);
                break;
            case Route.AccountDetail acc:
                BuildAccountDetail(_detailToolkit ?? acc.Toolkit, acc.AccountId);
                break;
            case Route.Actions actions:
                BuildActions(actions.Tools);
                break;
        }

        _scroll.UpdateLayout();
        _scroll.ChangeView(null, offset, null, true);
    }

    private void UpdateChrome()
    {
        _backWords.Text = _stack.Count <= 1 ? "Capabilities" : RouteTitle(_stack[^2]);
        _title.Text = RouteTitle(Top);
        _moreBtn.Visibility = Top is Route.Root ? Visibility.Visible : Visibility.Collapsed;

        string? prompt = null;
        var currentText = "";
        switch (Top)
        {
            case Route.Root when _model?.Phase == ComposioPhase.Ready:
                prompt = "Search apps";
                currentText = _model.Query;
                break;
            case Route.Category cat:
                prompt = $"Search {cat.Value.Title}";
                currentText = _categoryFilter;
                break;
            case Route.AllApps:
                prompt = "Search apps";
                currentText = _allAppsQuery;
                break;
            case Route.Actions:
                prompt = "Search actions";
                currentText = _actionsFilter;
                break;
        }

        _suppressSearchEvent = true;
        _search.Visibility = prompt != null ? Visibility.Visible : Visibility.Collapsed;
        _search.PlaceholderText = prompt ?? "";
        if (_search.Text != currentText) _search.Text = currentText;
        AutomationProperties.SetName(_search, prompt ?? "Search");
        _suppressSearchEvent = false;
    }

    private string RouteTitle(Route route) => route switch
    {
        Route.Root => "Composio",
        Route.Bots => "Bots",
        Route.Category c => c.Value.Title,
        Route.AllApps => "All Apps",
        Route.AppDetail a => (_detailToolkit ?? a.Toolkit).Name,
        Route.AccountDetail => "Account",
        Route.Actions act => $"{act.AppName} Actions",
        _ => "Composio",
    };

    // ------------------------------------------------------------------ Account menu (§10.9)

    private void ShowAccountMenu()
    {
        if (_model == null) return;
        var menu = new MenuFlyout();
        if (_model.Phase == ComposioPhase.Ready)
        {
            var (_, hint) = _model.Keys.Status(_model.AccountId);
            var keyLabel = string.IsNullOrEmpty(hint) ? $"Composio Key — Saved on this {DeviceWord.Name}" : $"Composio Key — •••• {hint}";
            menu.Items.Add(Kit.Item(keyLabel, Kit.Key, () => { }, enabled: false));
            menu.Items.Add(Kit.Item("Open Composio", Kit.OpenOut, () => Kit.Open(ComposioSignIn.Dashboard.ToString())));
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(Kit.Item("Remove Composio", Kit.Close, () => _ = ConfirmRemoveComposioAsync()));
        }
        else
        {
            menu.Items.Add(Kit.Item("Open Composio", Kit.OpenOut, () => Kit.Open(ComposioSignIn.Dashboard.ToString())));
        }
        menu.ShowAt(_moreBtn);
    }

    private async Task ConfirmRemoveComposioAsync()
    {
        if (_model == null) return;
        var ok = await Kit.Confirm(
            XamlRoot,
            "Remove Composio?",
            $"Your bots lose these apps, and this {DeviceWord.Name} forgets the key. Connected accounts stay in your Composio project.",
            "Remove",
            destructive: true);
        if (!ok || _model == null) return;
        await _model.RemoveAsync();
        _stack.Clear();
        _stack.Add(new Route.Root());
        Render();
    }

    // ------------------------------------------------------------------ Root (Loading / Setup / Ready / Failed)

    private void BuildRoot()
    {
        var model = _model!;
        switch (model.Phase)
        {
            case ComposioPhase.Loading:
                _column.Children.Add(Kit.Section(null, [Kit.Busy("Loading…")]));
                break;
            case ComposioPhase.Setup:
                BuildSetup(model);
                break;
            case ComposioPhase.Ready:
                BuildHome(model);
                break;
            case ComposioPhase.Failed:
                _column.Children.Add(Kit.LoadError("Couldn’t Load Composio", model.FailedReason, () => _ = model.StartAsync()));
                break;
        }
    }

    private void BuildSetup(ComposioModel model)
    {
        // Hero header
        var hero = new StackPanel { Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center, Padding = new Thickness(12, 16, 12, 16) };
        var logos = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center };
        foreach (var slug in ComposioCatalog.Hero)
            logos.Children.Add(AppLogo(slug, slug, "", 44));
        hero.Children.Add(logos);
        var heading = Kit.Text("Let your bots use your apps", 20, bold: true);
        heading.HorizontalTextAlignment = TextAlignment.Center;
        hero.Children.Add(heading);
        var blurb = Kit.Text("All it takes is your Composio API key. Paste it to connect Gmail, Calendar, GitHub and hundreds more, then choose which bots can use them.", 13, secondary: true);
        blurb.HorizontalTextAlignment = TextAlignment.Center;
        hero.Children.Add(blurb);
        _column.Children.Add(hero);

        // One-click gateway key reveal
        if (model.GatewayKeyProfile != null)
        {
            var useGatewayBtn = Kit.Button(
                model.SettingUp ? "Setting Up…" : "Use the Key on Your Gateway",
                () =>
                {
                    _triedGatewayKey = true;
                    _pasteNotice = null;
                    _ = model.SetUpAsync(typed: null);
                },
                accent: true,
                enabled: !model.SettingUp);
            AutomationProperties.SetAutomationId(useGatewayBtn, "connect-apps.use-gateway-key");
            useGatewayBtn.HorizontalAlignment = HorizontalAlignment.Center;
            _column.Children.Add(Kit.Section(null, [Kit.Pad(useGatewayBtn, 12)],
                "Your gateway already has a Composio key. To use a different one, paste it below."));

            if (_triedGatewayKey && model.SetupNotice is { } gwNotice)
                _column.Children.Add(NoticeCard(gwNotice, "connect-apps.notice"));
        }

        // API key entry
        var keyRow = new Grid { ColumnSpacing = 10 };
        keyRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        keyRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var pwd = new PasswordBox
        {
            PlaceholderText = "Composio API key",
            Password = _setupKeyDraft,
        };
        AutomationProperties.SetName(pwd, "Composio API key");
        AutomationProperties.SetAutomationId(pwd, "connect-apps.key");
        pwd.PasswordChanged += (_, _) => _setupKeyDraft = pwd.Password;
        pwd.KeyDown += (_, args) =>
        {
            if (args.Key == VirtualKey.Enter && !string.IsNullOrWhiteSpace(_setupKeyDraft) && !model.SettingUp)
            {
                _triedGatewayKey = false;
                _ = model.SetUpAsync(_setupKeyDraft);
            }
        };
        keyRow.Children.Add(pwd);

        var pasteBtn = Kit.Button("Paste", () => _ = PasteKeyAsync(model, pwd));
        AutomationProperties.SetAutomationId(pasteBtn, "connect-apps.paste");
        Grid.SetColumn(pasteBtn, 1);
        keyRow.Children.Add(pasteBtn);

        _column.Children.Add(Kit.Section("Your Composio API Key", [Kit.Pad(keyRow, 10)]));

        var activeNotice = (model.GatewayKeyProfile != null && _triedGatewayKey ? null : model.SetupNotice) ?? _pasteNotice;
        if (activeNotice != null)
            _column.Children.Add(NoticeCard(activeNotice, "connect-apps.notice"));

        // Continue button
        var continueBtn = Kit.Button(
            model.SettingUp ? "Checking your key…" : "Continue",
            () =>
            {
                _triedGatewayKey = false;
                _ = model.SetUpAsync(_setupKeyDraft);
            },
            accent: true,
            enabled: !model.SettingUp);
        AutomationProperties.SetAutomationId(continueBtn, "connect-apps.continue");
        continueBtn.HorizontalAlignment = HorizontalAlignment.Right;
        _column.Children.Add(Kit.Section(null, [Kit.Pad(continueBtn, 10)],
            $"Your key stays encrypted on this {DeviceWord.Name} ({DeviceWord.Keychain}). Nothing changes on your gateway until you turn on a bot."));

        // Don't have a key?
        var openBtn = Kit.RowAction("Open", () => Kit.Open(ComposioSignIn.Dashboard.ToString()));
        AutomationProperties.SetAutomationId(openBtn, "connect-apps.open-composio");
        _column.Children.Add(Kit.Section(null, [
            Kit.Row("Don’t have a key?", "Composio is free. Sign up, then copy a key from Settings › API Keys.", trailing: openBtn),
        ]));
    }

    private async Task PasteKeyAsync(ComposioModel model, PasswordBox pwd)
    {
        model.SetupNotice = null;
        _triedGatewayKey = false;
        var text = await Kit.Paste();
        if (string.IsNullOrWhiteSpace(text))
        {
            _pasteNotice = new ComposioNotice("Nothing to Paste", $"Copy your key in Composio first, then {DeviceWord.Tap} Paste.", IsError: false);
            Render();
            return;
        }
        _pasteNotice = null;
        _setupKeyDraft = text.Trim();
        pwd.Password = _setupKeyDraft;
        Render();
    }

    // ------------------------------------------------------------------ Home (§10.5)

    private void BuildHome(ComposioModel model)
    {
        if (!string.IsNullOrWhiteSpace(model.Query))
        {
            BuildSearchResults(model);
            return;
        }

        // Connected count banner
        if (model.Connected is { } connected)
        {
            if (connected.Count == 0)
            {
                var intro = new StackPanel { Spacing = 4 };
                intro.Children.Add(Kit.Text("Connect your first app", 16, bold: true));
                intro.Children.Add(Kit.Text($"{DeviceWord.TapCap} an app below to sign in to it. Then choose which bots can use it.", 13, secondary: true));
                _column.Children.Add(Kit.Section(null, [Kit.Pad(intro, 12)]));
            }
            else
            {
                var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, VerticalAlignment = VerticalAlignment.Center };
                var strip = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
                foreach (var app in connected.Take(3)) strip.Children.Add(AppLogo(app.Slug, app.Name, app.Logo, 28));
                row.Children.Add(strip);
                row.Children.Add(Kit.Text(connected.Count == 1 ? "1 app connected" : $"{connected.Count} apps connected", 15, bold: true));
                var box = Kit.Pad(row, 10);
                AutomationProperties.SetAutomationId(box, "connect-apps.count");
                _column.Children.Add(Kit.Section(null, [box]));
            }
        }
        else
        {
            _column.Children.Add(Kit.Skeletons(1));
        }

        // Bots row
        var (botsTitle, botsSub, choose) = model.BotsRowWords;
        UIElement botsLeading;
        if (model.OnBots.Count == 0)
        {
            botsLeading = Kit.Tile(Kit.Add, 30);
        }
        else
        {
            var heads = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            foreach (var b in model.OnBots.Take(3)) heads.Children.Add(new BotHead { Bot = b, Width = 26, Height = 26 });
            botsLeading = heads;
        }
        var botsRow = Kit.Row(botsTitle, botsSub, leading: botsLeading, click: () => Push(new Route.Bots()),
            chevron: true, subtitleColor: choose ? Kit.Accent : null);
        AutomationProperties.SetAutomationId(botsRow, "connect-apps.bots-row");
        _column.Children.Add(Kit.Section(null, [botsRow]));

        // Connected error
        if (model.ConnectedError is { } err)
        {
            _column.Children.Add(Kit.LoadError("Couldn’t Load Your Apps", err, () => _ = model.LoadHomeAsync()));
        }

        // Connected list
        if (model.Connected is { Count: > 0 } connList)
        {
            _column.Children.Add(Kit.Section("Connected", connList.Select(t => ToolkitRow(t, connectedStyle: true))));
        }
        else if (model.Connected == null)
        {
            _column.Children.Add(Kit.Skeletons(2, "Connected"));
        }

        // Popular apps grid
        if (model.Popular == null)
        {
            _column.Children.Add(Kit.Skeletons(2, "Popular"));
        }
        else if (model.PopularShown.Count == 0)
        {
            _column.Children.Add(Kit.Section("Popular", [Kit.Row("You’ve connected every popular app", "Find more under Browse.")]));
        }
        else
        {
            var grid = new Grid { ColumnSpacing = 10, RowSpacing = 10, Padding = new Thickness(12) };
            for (var c = 0; c < 4; c++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var shown = model.PopularShown;
            var rows = (shown.Count + 3) / 4;
            for (var r = 0; r < rows; r++) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

            for (var i = 0; i < shown.Count; i++)
            {
                var toolkit = shown[i];
                var tileContent = new StackPanel { Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center };
                tileContent.Children.Add(AppLogo(toolkit.Slug, toolkit.Name, toolkit.Logo, 40));
                var lbl = Kit.Text(toolkit.Name, 12, wrap: false);
                lbl.HorizontalTextAlignment = TextAlignment.Center;
                tileContent.Children.Add(lbl);

                var btn = new Button
                {
                    Content = tileContent,
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    Background = new SolidColorBrush(Colors.Transparent),
                    BorderThickness = new Thickness(0),
                    Padding = new Thickness(6, 10, 6, 10),
                };
                AutomationProperties.SetName(btn, toolkit.Name);
                AutomationProperties.SetAutomationId(btn, $"connect-app-tile-{toolkit.Slug}");
                btn.Click += (_, _) => Push(new Route.AppDetail(toolkit));
                Grid.SetRow(btn, i / 4);
                Grid.SetColumn(btn, i % 4);
                grid.Children.Add(btn);
            }
            _column.Children.Add(Kit.Section("Popular", [grid]));
        }

        // Browse categories + All Apps
        var browseRows = new List<UIElement>();
        foreach (var cat in ComposioCatalog.Categories)
        {
            var row = Kit.Row(cat.Title, leading: ColorTile(cat.Glyph, cat.Color), click: () => Push(new Route.Category(cat)), chevron: true);
            AutomationProperties.SetAutomationId(row, $"connect-category-{cat.Id}");
            browseRows.Add(row);
        }
        var allRow = Kit.Row("All Apps", leading: ColorTile("\uF0E2", 0x636366), click: () => Push(new Route.AllApps()), chevron: true);
        AutomationProperties.SetAutomationId(allRow, "connect-apps.all");
        browseRows.Add(allRow);
        _column.Children.Add(Kit.Section("Browse", browseRows));
    }

    private void BuildSearchResults(ComposioModel model)
    {
        if (model.SearchError is { } err)
        {
            _column.Children.Add(NoticeCard(new ComposioNotice("Couldn’t Search", err, IsError: true)));
        }
        else if (model.Results is { } results)
        {
            if (results.Count == 0)
                _column.Children.Add(Kit.Section("Results", [Kit.Plain($"No Results for “{model.Query.Trim()}”")]));
            else
                _column.Children.Add(Kit.Section("Results", results.Select(t => ToolkitRow(t, connectedStyle: false))));
        }
        else
        {
            _column.Children.Add(Kit.Skeletons(3, "Results"));
        }
    }

    // ------------------------------------------------------------------ Category & All Apps

    private async Task LoadCategoryAsync(ComposioCategory category)
    {
        if (_model?.Session is not { } session) return;
        _ = _model.LoadSignInRulesAsync();
        try
        {
            var page = await _model.Client.ToolkitsAsync(session.Id, slugs: category.Slugs, limit: 30);
            var order = category.Slugs.Select((s, i) => (s, i)).ToDictionary(x => x.s, x => x.i, StringComparer.Ordinal);
            _categoryItems = [.. page.Items.OrderBy(t => order.GetValueOrDefault(t.Slug, 99))];
        }
        catch (ComposioException ex)
        {
            _categoryError = ex.Message;
        }
        Render();
    }

    private void BuildCategory(ComposioCategory category)
    {
        if (_categoryError != null)
        {
            _column.Children.Add(Kit.LoadError("Couldn’t Load Apps", _categoryError, () => _ = LoadCategoryAsync(category)));
            return;
        }
        if (_categoryItems == null)
        {
            _column.Children.Add(Kit.Skeletons(3));
            return;
        }
        var filter = _categoryFilter.Trim();
        var shown = (_model?.Shown(_categoryItems) ?? _categoryItems)
            .Where(t => filter.Length == 0 || t.Name.Contains(filter, StringComparison.CurrentCultureIgnoreCase))
            .ToList();
        var rows = shown.Count == 0
            ? new List<UIElement> { Kit.Plain(filter.Length == 0 ? "No Apps" : $"No Results for “{filter}”") }
            : [.. shown.Select(t => ToolkitRow(t, connectedStyle: false))];
        _column.Children.Add(Kit.Section(null, rows,
            $"{DeviceWord.TapCap} an app to see what your bots can do with it, then connect it."));
    }

    private async Task LoadAllAppsAsync(bool reset)
    {
        if (_model?.Session is not { } session) return;
        if (!reset && _allAppsLoadingMore) return;
        var mine = _allAppsGen;
        if (reset) { _allAppsItems = null; _allAppsNext = ""; _allAppsError = null; }
        else _allAppsLoadingMore = true;
        Render();

        try
        {
            var page = await _model.Client.ToolkitsAsync(session.Id, search: _allAppsQuery.Trim(), cursor: reset ? "" : _allAppsNext, limit: 30);
            if (mine != _allAppsGen) return;
            var baseList = reset ? new List<ComposioToolkit>() : [.. (_allAppsItems ?? [])];
            var seen = baseList.Select(t => t.Slug).ToHashSet(StringComparer.Ordinal);
            foreach (var item in page.Items) if (seen.Add(item.Slug)) baseList.Add(item);
            _allAppsItems = baseList;
            _allAppsNext = page.Next;
        }
        catch (ComposioException ex)
        {
            if (mine != _allAppsGen) return;
            _allAppsError = ex.Message;
        }
        finally
        {
            _allAppsLoadingMore = false;
            Render();
        }
    }

    private void BuildAllApps()
    {
        if (_allAppsError != null && _allAppsItems == null)
        {
            _column.Children.Add(Kit.LoadError("Couldn’t Load Apps", _allAppsError, () => _ = LoadAllAppsAsync(reset: true)));
            return;
        }
        if (_allAppsItems == null)
        {
            _column.Children.Add(Kit.Skeletons(3));
            return;
        }
        var shown = _model?.Shown(_allAppsItems) ?? _allAppsItems;
        var rows = new List<UIElement>();
        if (shown.Count == 0)
        {
            var q = _allAppsQuery.Trim();
            rows.Add(Kit.Plain(q.Length == 0 ? "No Apps" : $"No Results for “{q}”"));
        }
        else
        {
            rows.AddRange(shown.Select(t => ToolkitRow(t, connectedStyle: false)));
        }
        if (_allAppsLoadingMore)
        {
            rows.Add(Kit.Busy("Loading more"));
        }
        else if (!string.IsNullOrEmpty(_allAppsNext))
        {
            var moreBtn = Kit.Button("Show More", () => _ = LoadAllAppsAsync(reset: false));
            AutomationProperties.SetAutomationId(moreBtn, "connect-apps.show-more");
            rows.Add(Kit.Pad(moreBtn, 10));
        }
        _column.Children.Add(Kit.Section(null, rows));
    }

    // ------------------------------------------------------------------ Bots (§10.7)

    private void BuildBots()
    {
        var model = _model!;
        if (model.ReadOnly)
        {
            _column.Children.Add(Kit.Section(null, [Kit.Plain("This gateway is read-only. Turn bots on from a gateway you can change.")]));
        }
        else
        {
            if (model.BotsNotice is { } notice)
                _column.Children.Add(NoticeCard(notice, "connect-apps.bots-notice"));

            UIElement trailing = model.ApplyingAll
                ? Kit.Spinner(16)
                : Kit.Switch(model.AllBots, "All bots can use your apps", on => _ = model.SetAllBotsAsync(on), enabled: model.BotStates != null);
            var allRow = Kit.Row("All Bots", "Includes bots you create later", leading: ColorTile("\uE716", 0x0A84FF), trailing: trailing);
            AutomationProperties.SetAutomationId(allRow, "connect-apps.all-bots");
            var allFooter = model.AllBots
                ? "Every bot can use your apps. When you add a bot, Hermes HQ gives it your apps too; a bot made on another computer gets them the next time Hermes HQ opens."
                : "Or choose bots one by one. A bot that’s on can use every app you connect.";
            _column.Children.Add(Kit.Section(null, [allRow], allFooter));
        }

        var header = model.Bots.Count == 1 ? "1 bot" : $"{model.Bots.Count} bots";
        if (model.BotStates == null)
        {
            _column.Children.Add(Kit.Skeletons(Math.Clamp(model.Bots.Count, 3, 5), header));
            return;
        }

        var botRows = model.Bots.Select(bot =>
        {
            var state = model.BotStates.GetValueOrDefault(bot.Name) ?? new ComposioBotState.Off();
            var isOn = state is ComposioBotState.On;
            var head = new BotHead { Bot = bot, Width = 28, Height = 28 };

            UIElement? subtitleEl = null;
            if (state is ComposioBotState.Failed failed)
            {
                var stack = new StackPanel { Spacing = 4 };
                stack.Children.Add(Kit.Text($"Couldn’t turn {(failed.IntendedOn ? "on" : "off")}: {failed.Reason}", 12, color: Kit.Critical));
                if (!model.ReadOnly)
                {
                    var retry = Kit.RowAction("Try Again", () => _ = model.SetBotAsync(bot, failed.IntendedOn));
                    retry.HorizontalAlignment = HorizontalAlignment.Left;
                    AutomationProperties.SetAutomationId(retry, $"connect-bot-retry-{bot.Name}");
                    stack.Children.Add(retry);
                }
                subtitleEl = stack;
            }

            UIElement? trailing = null;
            if (model.BotBusy.Contains(bot.Name))
                trailing = Kit.Spinner(16);
            else if (model.ReadOnly)
                trailing = isOn ? Kit.Glyph(Kit.Check, 14, Kit.Accent) : null;
            else if (model.AllBots && isOn)
                trailing = Kit.Glyph(Kit.Check, 14, Kit.Accent);
            else
            {
                var sw = Kit.Switch(isOn, $"{bot.DisplayName} can use your apps", next => _ = model.SetBotAsync(bot, next));
                AutomationProperties.SetAutomationId(sw, $"connect-bot-switch-{bot.Name}");
                trailing = sw;
            }

            return Kit.Row(bot.DisplayName, leading: head, trailing: trailing, subtitleElement: subtitleEl);
        });

        _column.Children.Add(Kit.Section(header, botRows,
            model.ReadOnly ? null : "Turning a bot on adds Composio to it on your gateway. Turning it off takes Composio away again; your connected apps stay."));
    }

    // ------------------------------------------------------------------ App Detail (§10.8, §10.11)

    private async Task LoadAppDetailAsync(ComposioToolkit toolkit)
    {
        if (_model == null) return;
        try { _detailTools = await _model.Client.ToolsAsync(toolkit.Slug); }
        catch (Exception) { _detailTools = []; }
        await RefreshDetailToolkitAsync(toolkit.Slug);
    }

    private async Task RefreshDetailToolkitAsync(string slug)
    {
        if (_model?.Session is not { } session) return;
        try
        {
            var page = await _model.Client.ToolkitsAsync(session.Id, slugs: [slug], limit: 5);
            if (page.Items.FirstOrDefault(t => t.Slug == slug) is { } fresh)
                _detailToolkit = fresh;
        }
        catch (Exception) { }
        if (_detailToolkit?.Connected == true)
        {
            try { await _model.LoadAccountsAsync(slug); }
            catch (Exception) { }
        }
        else
        {
            _model.SetAccounts(slug, null);
        }
        Render();
    }

    private void BuildAppDetail(ComposioToolkit toolkit)
    {
        var model = _model!;
        var fine = toolkit.Account?.IsActive == true;

        // Header
        var header = new StackPanel { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, Padding = new Thickness(12, 12, 12, 14) };
        header.Children.Add(AppLogo(toolkit.Slug, toolkit.Name, toolkit.Logo, 64));
        var title = Kit.Text(toolkit.Name, 20, bold: true);
        title.HorizontalTextAlignment = TextAlignment.Center;
        header.Children.Add(title);

        if (fine)
        {
            var connText = Kit.Text("Connected", 14, bold: true, color: Kit.Success);
            connText.HorizontalTextAlignment = TextAlignment.Center;
            AutomationProperties.SetAutomationId(connText, "connect-app.connected");
            header.Children.Add(connText);
            var who = model.AllBots ? "All your bots can use it now."
                : model.OnBots.Count == 0 ? "No bots use your apps yet."
                : $"{ComposioCatalog.NameList([.. model.OnBots.Select(b => b.DisplayName)])} can use it now.";
            var whoText = Kit.Text(who, 13, secondary: true);
            whoText.HorizontalTextAlignment = TextAlignment.Center;
            header.Children.Add(whoText);
        }
        else if (toolkit.NeedsSignIn)
        {
            var warn = Kit.Text("Needs a new sign-in", 14, bold: true, color: Kit.Caution);
            warn.HorizontalTextAlignment = TextAlignment.Center;
            header.Children.Add(warn);
            var reason = string.IsNullOrEmpty(toolkit.Account?.Reason)
                ? $"Your bots can’t use {toolkit.Name} until you sign in again."
                : toolkit.Account!.Reason;
            var rText = Kit.Text(reason, 13, secondary: true);
            rText.HorizontalTextAlignment = TextAlignment.Center;
            header.Children.Add(rText);
        }
        else if (!string.IsNullOrEmpty(toolkit.Description))
        {
            var desc = Kit.Text(toolkit.Description, 13, secondary: true);
            desc.HorizontalTextAlignment = TextAlignment.Center;
            header.Children.Add(desc);
        }
        _column.Children.Add(header);

        // Connect section
        if (!fine)
        {
            if (toolkit.NoAuth)
            {
                _column.Children.Add(Kit.Section(null, [Kit.Plain($"No sign-in needed. Bots that use your apps can use {toolkit.Name} already.")]));
            }
            else
            {
                var btnRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center };
                var connectBtn = Kit.Button(
                    model.ConnectLabel ?? (toolkit.NeedsSignIn ? $"Sign In to {toolkit.Name} Again" : $"Connect {toolkit.Name}"),
                    () => _ = StartConnectAsync(toolkit, alias: null),
                    accent: true,
                    enabled: model.ConnectPhase == ComposioConnectPhase.Idle);
                AutomationProperties.SetAutomationId(connectBtn, "connect-app.connect");
                btnRow.Children.Add(connectBtn);
                if (model.ConnectPhase != ComposioConnectPhase.Idle)
                    btnRow.Children.Add(Kit.Button("Cancel", () => model.CancelConnect()));

                UIElement? footerEl = null;
                var outcome = _addingAccount ? null : model.ConnectOutcome;
                if (outcome is ComposioConnectOutcome.Failed f)
                    footerEl = Kit.Text(f.Reason, 12, color: Kit.Critical);
                else if (outcome is ComposioConnectOutcome.Unfinished)
                    footerEl = Kit.Text($"Sign-in not finished. {DeviceWord.TapCap} Connect to try again.", 12, secondary: true);
                else if (outcome is ComposioConnectOutcome.NeedsOwnApp)
                    footerEl = OwnAppFooter(toolkit.Name);
                else
                    footerEl = Kit.Text($"You sign in to {toolkit.Name} in a secure browser window. Composio keeps the sign-in; Hermes HQ never sees your password.", 12, secondary: true);

                _column.Children.Add(Kit.Section(null, [Kit.Pad(btnRow, 12)], footerElement: footerEl));
            }
        }

        // Try It prompts
        if (fine && model.OnBots.FirstOrDefault() is { } firstBot)
        {
            var prompts = ComposioCatalog.TryIt(toolkit.Slug, toolkit.Name);
            var tryRows = prompts.Select((prompt, idx) =>
            {
                UIElement tail = _askingPrompt == prompt
                    ? Kit.Spinner(14)
                    : Kit.Text($"Ask {firstBot.DisplayName}", 13, color: Kit.Accent, wrap: false);
                var row = Kit.Row($"“{prompt}”", trailing: tail, click: _askingPrompt == null ? () => _ = TryPromptAsync(firstBot, prompt) : null);
                AutomationProperties.SetAutomationId(row, $"connect-app.try-{idx}");
                return row;
            });
            _column.Children.Add(Kit.Section("Try It", tryRows));
        }

        // What Your Bots Can Do
        if (_detailTools == null)
        {
            _column.Children.Add(Kit.Skeletons(3, "What Your Bots Can Do"));
        }
        else if (_detailTools.Count == 0)
        {
            _column.Children.Add(Kit.Section("What Your Bots Can Do", [Kit.Plain("Composio lists no actions for this app yet")]));
        }
        else
        {
            var toolRows = _detailTools.Take(3)
                .Select(t => Kit.Row(t.Name, leading: Kit.Glyph(Kit.Check, 13, Kit.Accent)))
                .ToList();
            if (_detailTools.Count > 3)
            {
                var seeAll = Kit.BrowseRow("See All Actions", _detailTools.Count, () => Push(new Route.Actions(toolkit.Name, _detailTools)));
                AutomationProperties.SetAutomationId(seeAll, "connect-app.actions");
                toolRows.Add(seeAll);
            }
            _column.Children.Add(Kit.Section("What Your Bots Can Do", toolRows));
        }

        // Bots That Will Use It
        if (!fine)
        {
            if (model.BotStates == null)
            {
                _column.Children.Add(Kit.Skeletons(1, "Bots That Will Use It"));
            }
            else if (model.OnBots.Count == 0)
            {
                _column.Children.Add(Kit.Section("Bots That Will Use It", [
                    Kit.Row("No bots use your apps yet", "Choose Bots", click: () => Push(new Route.Bots()), chevron: true, subtitleColor: Kit.Accent),
                ]));
            }
            else
            {
                _column.Children.Add(Kit.Section("Bots That Will Use It",
                    model.OnBots.Select(b => Kit.Row(b.DisplayName, leading: new BotHead { Bot = b, Width = 26, Height = 26 })),
                    "These are the bots you turned on. Change them under Bots on the Composio page."));
            }
        }

        // Accounts section (§10.11)
        if (toolkit.Account is { } primaryAccount && toolkit.Connected)
        {
            var list = model.AppAccounts.TryGetValue(toolkit.Slug, out var loaded) && loaded.Count > 0 ? loaded : [primaryAccount];
            var rows = new List<UIElement>();
            for (var i = 0; i < list.Count; i++)
            {
                rows.Add(BuildAccountRow(toolkit, list[i], i + 1, list.Count > 1, list));
            }
            if (!toolkit.NoAuth)
            {
                var addBtn = Kit.Row(
                    _addingAccount && model.ConnectPhase != ComposioConnectPhase.Idle
                        ? (model.ConnectLabel ?? "Add Another Account")
                        : "Add Another Account",
                    leading: _addingAccount && model.ConnectPhase != ComposioConnectPhase.Idle ? Kit.Spinner(16) : Kit.Glyph(Kit.Add, 14, Kit.Accent),
                    click: model.ConnectPhase == ComposioConnectPhase.Idle && _busyAccountId == null ? () => _ = PromptAddAccountAsync(toolkit, list) : null);
                AutomationProperties.SetAutomationId(addBtn, "connect-app.add-account");
                rows.Add(addBtn);
            }

            UIElement? accFooter = null;
            if (!string.IsNullOrEmpty(_accountNotice))
                accFooter = Kit.Text(_accountNotice, 12, color: Kit.Critical);
            else if (_addingAccount && model.ConnectOutcome is ComposioConnectOutcome.Failed f)
                accFooter = Kit.Text(f.Reason, 12, color: Kit.Critical);
            else if (_addingAccount && model.ConnectOutcome is ComposioConnectOutcome.NeedsOwnApp)
                accFooter = OwnAppFooter(toolkit.Name);
            else if (_addingAccount && model.ConnectOutcome is ComposioConnectOutcome.Unfinished)
                accFooter = Kit.Text($"Sign-in not finished. {DeviceWord.TapCap} Add Another Account to try again.", 12, secondary: true);
            else if (list.Count > 1)
                accFooter = Kit.Text("Your bots pick an account by its name.", 12, secondary: true);
            else if (!toolkit.NoAuth)
                accFooter = Kit.Text($"Add a second {toolkit.Name} account, like a work one, under its own name.", 12, secondary: true);

            _column.Children.Add(Kit.Section(list.Count == 1 ? "Account" : "Accounts", rows, footerElement: accFooter));

            if (list.Count == 1)
            {
                var discBtn = Kit.Button(_disconnecting ? "Disconnecting…" : $"Disconnect {toolkit.Name}",
                    () => _ = ConfirmDisconnectSingleAsync(toolkit, list[0]), enabled: !_disconnecting);
                discBtn.Foreground = Kit.Critical;
                AutomationProperties.SetAutomationId(discBtn, "connect-app.disconnect");
                _column.Children.Add(Kit.Section(null, [Kit.Pad(discBtn, 10)],
                    _disconnectError != null ? $"Couldn’t disconnect: {_disconnectError}" : "Your bots lose access to this account. You can connect it again anytime."));
            }
        }
    }

    private UIElement BuildAccountRow(ComposioToolkit toolkit, ComposioAccount account, int number, bool several, List<ComposioAccount> all)
    {
        var identity = _model!.Identities.GetValueOrDefault(account.Id);
        var title = account.Title(number, identity);
        var lines = new StackPanel { Spacing = 2 };
        if (account.EmailLine(identity) is { } email) lines.Children.Add(Kit.Text(email, 12, secondary: true, wrap: false));
        if (account.NeedsSignIn)
            lines.Children.Add(Kit.Text("Needs a new sign-in", 12, color: Kit.Caution, wrap: false));
        else
        {
            var date = ComposioCatalog.ConnectedDate(account.CreatedAt);
            lines.Children.Add(Kit.Text(string.IsNullOrEmpty(date) ? "Connected" : $"Connected {date}", 12, secondary: true, wrap: false));
        }

        UIElement trailing;
        if (_busyAccountId == account.Id)
        {
            trailing = Kit.Spinner(16);
        }
        else
        {
            var optBtn = new Button
            {
                Content = Kit.Glyph(Kit.More, 14, Kit.Accent),
                Background = new SolidColorBrush(Colors.Transparent),
                BorderThickness = new Thickness(0),
                Padding = new Thickness(6),
            };
            AutomationProperties.SetName(optBtn, $"{title} Options");
            AutomationProperties.SetAutomationId(optBtn, $"connect-app.account-menu-{number}");
            optBtn.Click += (_, _) =>
            {
                var flyout = new MenuFlyout();
                flyout.Items.Add(Kit.Item(string.IsNullOrEmpty(account.Alias) ? "Name This Account…" : "Rename…", "\uE70F",
                    () => _ = PromptRenameAccountAsync(toolkit, account, number, all)));
                if (several)
                {
                    flyout.Items.Add(Kit.Item("Disconnect", Kit.Close,
                        () => _ = ConfirmDisconnectAccountAsync(toolkit, account, title, popAfter: false)));
                }
                flyout.ShowAt(optBtn);
            };
            trailing = optBtn;
        }

        var row = Kit.Row(title, subtitleElement: lines, trailing: trailing,
            click: () => Push(new Route.AccountDetail(toolkit, account.Id)), chevron: true);
        AutomationProperties.SetAutomationId(row, $"connect-app.account-{number}");
        return row;
    }

    private void BuildAccountDetail(ComposioToolkit toolkit, string accountId)
    {
        var model = _model!;
        var list = model.AppAccounts.GetValueOrDefault(toolkit.Slug) ?? [];
        var idx = list.FindIndex(a => a.Id == accountId);
        if (idx < 0)
        {
            _column.Children.Add(Kit.Section(null, [Kit.Plain("This account is no longer connected.")]));
            return;
        }
        var account = list[idx];
        var number = idx + 1;
        var identity = model.Identities.GetValueOrDefault(account.Id);
        var title = account.Title(number, identity);

        var header = new StackPanel { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, Padding = new Thickness(12) };
        header.Children.Add(AppLogo(toolkit.Slug, toolkit.Name, toolkit.Logo, 56));
        var hTitle = Kit.Text(title, 18, bold: true);
        hTitle.HorizontalTextAlignment = TextAlignment.Center;
        header.Children.Add(hTitle);
        var stateLabel = account.NeedsSignIn ? "Needs a new sign-in" : account.IsActive ? "Connected" : account.Status;
        var stateText = Kit.Text(stateLabel, 14, bold: true, color: account.NeedsSignIn ? Kit.Caution : account.IsActive ? Kit.Success : Kit.Secondary);
        stateText.HorizontalTextAlignment = TextAlignment.Center;
        header.Children.Add(stateText);
        _column.Children.Add(header);

        if (account.NeedsSignIn && !toolkit.NoAuth)
        {
            var signInBtn = Kit.Button(model.ConnectLabel ?? "Sign In Again",
                () => _ = StartConnectAsync(toolkit, alias: null), accent: true, enabled: model.ConnectPhase == ComposioConnectPhase.Idle);
            AutomationProperties.SetAutomationId(signInBtn, "connect-account.sign-in");
            signInBtn.HorizontalAlignment = HorizontalAlignment.Center;
            _column.Children.Add(Kit.Section(null, [Kit.Pad(signInBtn, 10)],
                $"You sign in to {toolkit.Name} again in a secure browser window."));
        }

        var fields = new List<UIElement>();
        UIElement renameCtrl = _busyAccountId == account.Id
            ? Kit.Spinner(14)
            : Kit.Link(string.IsNullOrEmpty(account.Alias) ? "Name This Account…" : "Rename…",
                () => _ = PromptRenameAccountAsync(toolkit, account, number, list));
        fields.Add(Kit.Row("Name", string.IsNullOrEmpty(account.Alias) ? "Not named" : ComposioAlias.Shown(account.Alias), trailing: renameCtrl));
        if (identity != null && !string.IsNullOrEmpty(identity.Email))
            fields.Add(Kit.Row("Email", identity.Email));
        if (identity != null && !string.IsNullOrEmpty(identity.Name))
            fields.Add(Kit.Row($"Name in {toolkit.Name}", identity.Name));
        var date = ComposioCatalog.ConnectedDate(account.CreatedAt);
        if (!string.IsNullOrEmpty(date))
            fields.Add(Kit.Row("Connected", date));

        var footerText = !string.IsNullOrEmpty(_accountNotice)
            ? _accountNotice
            : !string.IsNullOrEmpty(account.WordId)
                ? $"Your bots pick an account by its name. Composio code: {account.WordId}"
                : "Your bots pick an account by its name.";
        _column.Children.Add(Kit.Section(null, fields, footerText));

        var discBtn = Kit.Button(_disconnecting ? "Disconnecting…" : "Disconnect This Account",
            () => _ = ConfirmDisconnectAccountAsync(toolkit, account, title, popAfter: true), enabled: !_disconnecting && _busyAccountId == null);
        discBtn.Foreground = Kit.Critical;
        AutomationProperties.SetAutomationId(discBtn, "connect-account.disconnect");
        _column.Children.Add(Kit.Section(null, [Kit.Pad(discBtn, 10)],
            $"Your bots lose access to this {toolkit.Name} account. You can connect it again anytime."));
    }

    private void BuildActions(IReadOnlyList<ComposioTool> tools)
    {
        var filter = _actionsFilter.Trim();
        var shown = tools.Where(t => filter.Length == 0
            || t.Name.Contains(filter, StringComparison.CurrentCultureIgnoreCase)
            || t.Description.Contains(filter, StringComparison.CurrentCultureIgnoreCase)).ToList();
        if (shown.Count == 0)
            _column.Children.Add(Kit.Section(null, [Kit.Plain($"No Results for “{filter}”")]));
        else
            _column.Children.Add(Kit.Section(null, shown.Select(t => Kit.Row(t.Name, t.Description))));
    }

    // ------------------------------------------------------------------ Actions

    private async Task StartConnectAsync(ComposioToolkit toolkit, string? alias, Func<Task<string>>? prepare = null)
    {
        if (_model == null) return;
        _addingAccount = alias != null;
        await _model.ConnectAppAsync(toolkit.Slug, alias, prepare);
        await RefreshDetailToolkitAsync(toolkit.Slug);
        await _model.LoadHomeAsync();
    }

    private async Task TryPromptAsync(Bot bot, string prompt)
    {
        _askingPrompt = prompt;
        Render();
        var error = await ComposioModel.OpenTryItAsync(bot, prompt);
        _askingPrompt = null;
        Render();
        if (error != null) Kit.Fail(XamlRoot, $"Couldn’t Open {bot.DisplayName}", error);
    }

    private async Task PromptAddAccountAsync(ComposioToolkit toolkit, List<ComposioAccount> existing)
    {
        if (_model == null) return;
        _accountNotice = null;
        var input = new TextBox { PlaceholderText = "work", MaxLength = ComposioAlias.MaxLength };
        AutomationProperties.SetName(input, "Account name");
        AutomationProperties.SetAutomationId(input, "connect-app.alias");
        var content = new StackPanel { Spacing = 8 };
        content.Children.Add(Kit.Text("Give it a short name, like “work”. Your bots use the name to pick the account.", 13, secondary: true));
        content.Children.Add(input);

        var dialog = new ContentDialog
        {
            Title = $"Add Another {toolkit.Name} Account",
            Content = content,
            PrimaryButtonText = "Continue",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await Kit.Show(XamlRoot, dialog) != ContentDialogResult.Primary) return;

        var alias = ComposioAlias.Normalized(input.Text);
        if (alias == null) { _accountNotice = "Use letters or numbers in the name."; Render(); return; }
        if (existing.Any(a => a.Alias == alias))
        {
            _accountNotice = $"You already have a {toolkit.Name} account named “{ComposioAlias.Shown(alias)}”.";
            Render();
            return;
        }
        await StartConnectAsync(toolkit, alias, async () => (await _model.MultiAccountSessionAsync()).Id);
    }

    private async Task PromptRenameAccountAsync(ComposioToolkit toolkit, ComposioAccount account, int number, List<ComposioAccount> all)
    {
        if (_model == null) return;
        _accountNotice = null;
        var identity = _model.Identities.GetValueOrDefault(account.Id);
        var taken = all.Where(a => a.Id != account.Id && !string.IsNullOrEmpty(a.Alias))
            .Select(a => a.Alias).ToHashSet(StringComparer.Ordinal);
        var suggested = string.IsNullOrEmpty(account.Alias) && identity != null
            ? ComposioAlias.Suggestion(identity.Email, taken)
            : null;

        var input = new TextBox
        {
            PlaceholderText = "work",
            MaxLength = ComposioAlias.MaxLength,
            Text = suggested ?? account.Alias,
        };
        AutomationProperties.SetName(input, "Account name");
        AutomationProperties.SetAutomationId(input, "connect-app.alias");
        var content = new StackPanel { Spacing = 8 };
        content.Children.Add(Kit.Text("A short name, like “work”. Your bots use the name to pick the account.", 13, secondary: true));
        content.Children.Add(input);

        var dialog = new ContentDialog
        {
            Title = string.IsNullOrEmpty(account.Alias) ? "Name This Account" : $"Rename {account.Title(number, identity)}",
            Content = content,
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await Kit.Show(XamlRoot, dialog) != ContentDialogResult.Primary) return;

        var alias = ComposioAlias.Normalized(input.Text);
        if (alias == null) { _accountNotice = "Use letters or numbers in the name."; Render(); return; }
        if (taken.Contains(alias))
        {
            _accountNotice = $"You already have a {toolkit.Name} account named “{ComposioAlias.Shown(alias)}”.";
            Render();
            return;
        }

        _busyAccountId = account.Id;
        Render();
        try
        {
            await _model.RenameAccountAsync(toolkit.Slug, account.Id, alias);
        }
        catch (ComposioException ex)
        {
            _accountNotice = $"Couldn’t save the name: {ex.Message}";
        }
        finally
        {
            _busyAccountId = null;
            Render();
        }
    }

    private async Task ConfirmDisconnectSingleAsync(ComposioToolkit toolkit, ComposioAccount account)
    {
        if (_model == null) return;
        var ok = await Kit.Confirm(XamlRoot, $"Disconnect {toolkit.Name}?",
            $"Your bots lose access to this {toolkit.Name} account. You can connect it again anytime.",
            "Disconnect", destructive: true);
        if (!ok || _model == null) return;
        _disconnecting = true;
        _disconnectError = null;
        Render();
        try
        {
            await _model.DisconnectAccountAsync(toolkit.Slug, account.Id);
            if (_detailToolkit != null) _detailToolkit = _detailToolkit with { Account = null };
            await RefreshDetailToolkitAsync(toolkit.Slug);
        }
        catch (ComposioException ex)
        {
            _disconnectError = ex.Message;
        }
        finally
        {
            _disconnecting = false;
            Render();
        }
    }

    private async Task ConfirmDisconnectAccountAsync(ComposioToolkit toolkit, ComposioAccount account, string title, bool popAfter)
    {
        if (_model == null) return;
        var ok = await Kit.Confirm(XamlRoot, $"Disconnect “{title}”?",
            $"Your bots lose access to this {toolkit.Name} account. You can connect it again anytime.",
            "Disconnect", destructive: true);
        if (!ok || _model == null) return;
        _accountNotice = null;
        _busyAccountId = account.Id;
        _disconnecting = popAfter;
        Render();
        try
        {
            await _model.DisconnectAccountAsync(toolkit.Slug, account.Id);
            if (popAfter && _stack.Count > 1) _stack.RemoveAt(_stack.Count - 1);
            await RefreshDetailToolkitAsync(toolkit.Slug);
        }
        catch (ComposioException ex)
        {
            _accountNotice = $"Couldn’t disconnect: {ex.Message}";
        }
        finally
        {
            _busyAccountId = null;
            _disconnecting = false;
            Render();
        }
    }

    // ------------------------------------------------------------------ Shared UI helpers

    private UIElement ToolkitRow(ComposioToolkit toolkit, bool connectedStyle)
    {
        string? subtitle;
        Brush? subColor = null;
        if (toolkit.NeedsSignIn)
        {
            subtitle = "Needs a new sign-in";
            subColor = Kit.Caution;
        }
        else if (connectedStyle)
        {
            var date = ComposioCatalog.ConnectedDate(toolkit.Account?.CreatedAt, shortFormat: true);
            subtitle = string.IsNullOrEmpty(date) ? "Connected" : $"Connected {date}";
        }
        else
        {
            subtitle = toolkit.Description;
        }

        UIElement? trailing = !connectedStyle && toolkit.Connected && !toolkit.NeedsSignIn
            ? Kit.Text("Connected", 13, secondary: true, wrap: false)
            : null;

        var row = Kit.Row(toolkit.Name, subtitle, leading: AppLogo(toolkit.Slug, toolkit.Name, toolkit.Logo, 34),
            trailing: trailing, click: () => Push(new Route.AppDetail(toolkit)), chevron: true, subtitleColor: subColor, subtitleLines: 1);
        AutomationProperties.SetAutomationId(row, $"connect-app-row-{toolkit.Slug}");
        return row;
    }

    private static UIElement AppLogo(string slug, string name, string logo, double size)
    {
        var url = ComposioClient.LogoUrl(slug, logo)?.ToString();
        return Kit.Logo(url, name, size);
    }

    private static UIElement ColorTile(string glyph, uint rgb)
    {
        var color = Color.FromArgb(255, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);
        return new Border
        {
            Width = 28,
            Height = 28,
            CornerRadius = new CornerRadius(7),
            Background = new SolidColorBrush(color),
            Child = new FontIcon
            {
                Glyph = glyph,
                FontSize = 13,
                Foreground = new SolidColorBrush(Colors.White),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            },
        };
    }

    private static UIElement NoticeCard(ComposioNotice notice, string? automationId = null)
    {
        var content = new StackPanel { Spacing = 2 };
        content.Children.Add(Kit.Text(notice.Title, 13, bold: true));
        content.Children.Add(Kit.Text(notice.Message, 13, secondary: true));
        var row = new Grid { ColumnSpacing = 10 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(Kit.Glyph(notice.IsError ? Kit.Warning : Kit.Info, 16, notice.IsError ? Kit.Critical : Kit.Caution));
        Grid.SetColumn(content, 1);
        row.Children.Add(content);
        var card = Kit.Section(null, [Kit.Pad(row, 10)]);
        if (automationId != null) AutomationProperties.SetAutomationId(card, automationId);
        return card;
    }

    private static UIElement OwnAppFooter(string name)
    {
        var panel = new StackPanel { Spacing = 4 };
        panel.Children.Add(Kit.Text(ComposioSignIn.OwnAppMessage(name), 12, color: Kit.Critical));
        var link = Kit.Link("Open Composio Dashboard", () => Kit.Open(ComposioSignIn.Dashboard.ToString()));
        AutomationProperties.SetAutomationId(link, "connect-app.open-dashboard");
        panel.Children.Add(link);
        return panel;
    }
}
