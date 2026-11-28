using Hermes.Core;
using Hermes.Core.Bots;
using Hermes.Core.Net;
using Hermes.Core.Rpc;
using Hermes.Core.Sessions;
using Hermes.Core.Settings;
using WorkingRing = Hermes.Core.Settings.WorkingRing;
using DensitySizes = Hermes.Core.Settings.DensitySizes;
using Hermes.Core.Shell;
using HermesHQ.Features.Bots;
using HermesHQ.Features.OpenQuickly;
using HermesHQ.Features.Settings;
using HermesHQ.Features.Shortcuts;
using HermesHQ.Features.Transcript;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Navigation;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace HermesHQ.Pages;

/// The window's layout, as the Mac's (App/Mac/MacSidebar.swift): Search (Open Quickly) and New Chat, the bots in their groups (Pinned,
/// the user's sections, Unassigned) with each bot's step and its chats under it, New Bot, the places, Tools, and the
/// gateway at the foot; whatever was picked fills the rest. The sidebar folds to a rail of heads (with or without their
/// names), its edge drags and the width is kept, and its rows are edited in place: right-click to move or remove a
/// place, add pages, drag to reorder; bots move between sections by menu or by drag (App/Mac/SidebarEditing.swift).
public sealed partial class ShellPage : Page
{
    private HermesClient? _client;
    private ListsHub? _hub;
    private BotActions? _actions;
    /// [WIN-55] The bots' actions, for the a11y-audit walk to open Bot Info as the menu's item does.
    internal BotActions? Actions => _actions;
    private readonly FileDeviceStore _disk = new(ListsHub.DevicePath);
    private SidebarLayout _layout;
    private string? _openKey;
    private IDisposable? _notice;
    private SidebarItem? _dragged;
    private bool _narrow, _openedWhileNarrow, _autoOpened;
    private bool? _toolsRail;   // the form Search and New Chat were last drawn in
    // The edge's drag.
    private bool _gripping;
    private double _gripStartX, _gripStartWidth;
    private bool _detached;
    // Top open-chats-only workspace bar, tabs, navigation history, and Hide/Show List toggle (App/Mac/MacWorkspaceBar.swift).
    private readonly WorkspaceBar _workspaceBar = new();
    private WorkspaceTabList _tabList = new();
    private readonly WorkspaceHistory _history = new();
    private string? _closingTabId;
    private bool _navigatingHistory;
    private bool _listHidden;
    private MenuFlyoutItem? _updateMenuItem;
    private Action? _onUpdateChanged;

    public ShellPage()
    {
        InitializeComponent();
        BotChatsStylePrefs.Store ??= FilePreferences.Shared;
        Unloaded += (_, _) => DetachShell();
        _layout = SidebarLayout.Load(_disk);
        SidebarColumn.Width = new GridLength(_layout.Collapsed ? _layout.RailWidth : SidebarLayout.ClampOpen(_layout.OpenWidth));
        // Top workspace bar above the floating rounded canvas card.
        _workspaceBar.BackClicked += GoWorkspaceBack;
        _workspaceBar.ForwardClicked += GoWorkspaceForward;
        _workspaceBar.ToggleListClicked += () => ToggleList();
        _workspaceBar.NewChatClicked += () => NewChat_Click(this, new RoutedEventArgs());
        _workspaceBar.TabSelected += ActivateWorkspaceBarTab;
        _workspaceBar.TabCloseRequested += CloseWorkspaceTab;
        _workspaceBar.CloseOthersRequested += CloseOtherWorkspaceTabs;
        _workspaceBar.CloseToRightRequested += CloseWorkspaceTabsToRight;
        _workspaceBar.CloseAllRequested += CloseAllWorkspaceTabs;
        WorkspaceBarHost.Children.Add(_workspaceBar);
        // [WIN-49] The Mac's selection mark on the sidebar (MacSelection): the accent while a click last landed here and
        // the window is in front, grey otherwise.
        SelectionMark.Install(Sidebar, SidebarPane, ContentFrame.Parent as UIElement ?? ContentFrame);
        // [WIN-RAIL-TOOLS-FIT] The Undo pill stands over the pane, above a chat's message box while one is there.
        ContentFrame.Navigated += (_, e) => WatchMessageBox(e.Content);
        PaneGrid.SizeChanged += (_, _) => LiftPill();
        // The keys come from Hermes.Core's ShellKeys, the table Help › Keyboard Shortcuts lists (KeyShortcuts).
        // Ctrl+K: Open Quickly, the Mac's ⌘K panel (Features/OpenQuickly); the sidebar's Search button opens the same.
        AddShortcut(ShellKeys.OpenQuickly, ShowOpenQuickly);
        AddShortcut(ShellKeys.QuickActions, () => Navigator.Open("quick-actions"));   // Edit › Quick Actions…, the Mac's ⇧⌘K (Features/QuickActions)
        AddShortcut(ShellKeys.NewChat, () => NewChat_Click(this, new RoutedEventArgs()));
        // File › New Chat Here, Close Chat and Archive Chat (the Mac's ⌥⌘N, ⌘W, ⌃⌘A; Hermes.Core.Shell.ChatKeys).
        AddShortcut(ShellKeys.NewChatHere, () =>
        {
            if (_hub == null || !ChatKeys.CanNewChatHere(KeyState())) return false;
            NewChatHere();
            return true;
        });
        AddShortcut(ShellKeys.NewChatWith, () => HermesHQ.Features.NewChat.NewChatSheet.Show(XamlRoot));   // ⇧⌘N: the New Chat sheet
        AddShortcut(ShellKeys.CloseChat, () =>
        {
            if (!ChatKeys.CanCloseChat(KeyState())) return false;
            CloseChat();
            return true;
        });
        AddShortcut(ShellKeys.ArchiveChat, () =>
        {
            if (ChatKeys.Archive(KeyState()) == ArchiveStep.None || _hub == null || _openChat == null || _archiving) return false;
            _ = ArchiveChatAsync();
            return true;
        });
        AddShortcut(ShellKeys.Settings, () => SettingsWindows.Show());   // [mac-layout] Settings in a window of its own (MacSettingsWindow)
        // View › Refresh: the Mac's ⌘R is Ctrl+R here, and F5 as every Windows app refreshes. The page on show's own
        // refresh, the lists beside a chat; a page with none lets the key pass on (RefreshKeys).
        AddShortcut(ShellKeys.Refresh, KeyRefresh);
        AddShortcut(ShellKeys.RefreshAlt, KeyRefresh);
        // View › Next Chat / Previous Chat, the Mac's ⌘↓ / ⌘↑ (WalkKeys): off at either end, over a dialog, and while a
        // field holds words (the caret's Ctrl+Down / Ctrl+Up then).
        AddShortcut(ShellKeys.NextChat, () => Walk(forward: true));
        AddShortcut(ShellKeys.PreviousChat, () => Walk(forward: false));
        AddShortcut(ShellKeys.HideSidebar, ToggleFold);
        AddShortcut(ShellKeys.HideList, ToggleList);
        AddShortcut(ShellKeys.NextTab, () => CycleWorkspaceTabs(+1));
        AddShortcut(ShellKeys.PreviousTab, () => CycleWorkspaceTabs(-1));
        AddShortcut(ShellKeys.NextTabBracket, () => CycleWorkspaceTabs(+1));
        AddShortcut(ShellKeys.PreviousTabBracket, () => CycleWorkspaceTabs(-1));
        AddShortcut(ShellKeys.KeyboardShortcuts, ShowShortcuts);   // Help › Keyboard Shortcuts, the Mac's ⌘/
        // Ctrl+1…9: the places in the Mac's numbered order (PlaceKeys: Bots, the places, the Tools; Ctrl+9 the last).
        for (var i = 1; i <= 9; i++)
        {
            var n = i;
            AddShortcut(ShellKeys.Place(n), () => PickNth(n));
        }
        // The Mac's Help menu has Keyboard Shortcuts; here the sidebar foot's menu does, above Sign out.
        var shortcuts = new MenuFlyoutItem
        {
            Text = "Keyboard Shortcuts", Icon = new FontIcon { Glyph = "\uE765" },
            KeyboardAcceleratorTextOverride = ShellKeys.KeyboardShortcuts.Display,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(shortcuts, "shell.keyboardShortcuts");
        shortcuts.Click += (_, _) => ShowShortcuts();
        AccountMenu.Items.Insert(AccountMenu.Items.Count - 1, shortcuts);
        // Help › Hermes HQ Support (MacWindow.trimMenus): the website's support page, as Settings › About › Support opens it.
        var support = new MenuFlyoutItem { Text = HelpMenu.SupportTitle, Icon = new FontIcon { Glyph = "\uE897" } };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(support, "shell.support");
        support.Click += async (_, _) =>
        {
            try { await Windows.System.Launcher.LaunchUriAsync(new Uri(HelpMenu.SupportUrl)); }
            catch (Exception ex) { AppLog.Error("shell", ex); }
        };
        AccountMenu.Items.Insert(AccountMenu.Items.Count - 1, support);

        _updateMenuItem = new MenuFlyoutItem { Text = "Check for Updates…", Icon = new FontIcon { Glyph = "\uE895" } };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(_updateMenuItem, "shell.updates");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_updateMenuItem, "Check for Updates");
        _updateMenuItem.Click += (_, _) =>
        {
            SettingsWindows.Show("about");
            if (WindowsUpdateService.State is WindowsUpdateUiState.Idle or WindowsUpdateUiState.UpToDate or WindowsUpdateUiState.Failed)
                _ = WindowsUpdateService.CheckAsync(silent: false);
        };
        AccountMenu.Items.Insert(AccountMenu.Items.Count - 1, _updateMenuItem);
        _onUpdateChanged = RefreshUpdateMenuItem;
        WindowsUpdateService.Changed += _onUpdateChanged;
        RefreshUpdateMenuItem();
    }

    private void RefreshUpdateMenuItem()
    {
        if (_updateMenuItem is not { } item) return;
        DispatcherQueue?.TryEnqueue(() =>
        {
            if (_detached) return;
            if (WindowsUpdateService.State == WindowsUpdateUiState.Available && WindowsUpdateService.AvailableRelease is { } rel)
            {
                var label = $"Update Available ({rel.Version.ToString(3)})…";
                item.Text = label;
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(item, label);
            }
            else
            {
                item.Text = "Check for Updates…";
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(item, "Check for Updates");
            }
        });
    }

    private void AddShortcut(KeyChord chord, Action run) => AddShortcut(chord, () => { run(); return true; });

    /// `run` answers whether the key acted; a key that can't act now (its Mac item dimmed) passes on, unhandled.
    private void AddShortcut(KeyChord chord, Func<bool> run)
    {
        var a = chord.Key switch
        {
            "[" => new KeyboardAccelerator { Key = (VirtualKey)219, Modifiers = ModifiersOf(chord) }, // VK_OEM_4
            "]" => new KeyboardAccelerator { Key = (VirtualKey)221, Modifiers = ModifiersOf(chord) }, // VK_OEM_6
            _ => ShortcutKeys.Accelerator(chord),
        };
        a.Invoked += (_, e) =>
        {
            // AltGr is Ctrl+Alt: with the right Alt key down a Ctrl+Alt chord is a typed letter, left to the field.
            if (!ChatKeys.Takes(chord, RightAltDown())) return;
            e.Handled = run();
        };
        KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        KeyboardAccelerators.Add(a);
    }

    private static VirtualKeyModifiers ModifiersOf(KeyChord chord)
    {
        var mods = VirtualKeyModifiers.None;
        if (chord.Ctrl) mods |= VirtualKeyModifiers.Control;
        if (chord.Shift) mods |= VirtualKeyModifiers.Shift;
        if (chord.Alt) mods |= VirtualKeyModifiers.Menu;
        return mods;
    }

    private static bool RightAltDown() =>
        Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.RightMenu).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    /// Help › Keyboard Shortcuts: the sheet as it reads now (Ctrl+1…9 named for the rows they open, the Terminal's keys
    /// while the Terminal is in the sidebar).
    private void ShowShortcuts()
    {
        var numbered = NumberedPlaces().Select(id => id == PlaceKeys.Bots ? PlaceKeys.BotsTitle : Places.Get(id).Title).ToList();
        var infos = PlaceInfos();
        var terminal = _layout.Shown(infos).Contains("terminal") || _layout.Tools(infos).Contains("terminal");
        // The titles the Mac's `validate` gives now: New Chat for the bot Ctrl+N starts with, the sidebar's and the
        // inspector's rows for what their keys would do.
        var bot = NewChatBotId();
        var state = new ShortcutState(ShortcutState.BotName(bot, bot == null ? null : _hub?.Bots.Bot(bot)?.Model.DisplayName),
            SidebarFolded: Rail, InspectorShown: ChatPage.Current?.InspectorShown == true);
        _ = ShortcutsSheet.ShowAsync(XamlRoot, KeyShortcuts.Sections(numbered, terminal, state));
    }

    /// The shell on show (the chat-keys walk presses its keys through it where the runner's desktop delivers none).
    internal static ShellPage? Current { get; private set; }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        _detached = false;
        Current = this;
        _client = AppState.Client;
        _hub = ListsHub.Current;
        if (_client == null || _hub == null) { App.Window?.ShowSignIn(); return; }
        _actions = new BotActions(_hub, () => XamlRoot, PillHost)
        {
            ViewSessions = bot => Navigator.Open("sessions", bot),
            NewChat = bot => _ = NewChatWithAsync(bot),
        };
        var account = _client.Session.Account;
        AccountLabel.Text = account.Label ?? _client.Session.Address.Base.Host;
        AccountItem.Text = (account.Username.StartsWith("nous:") ? "Nous account" : account.Username) + " on " + _client.Session.Address;
        // [gateways] The foot's gateway line and switcher, the account menu's gateway items, the connection notice.
        if (ShellExtensions.GatewayFoot is { } foot) GatewayFootHost.Content = foot(_client);
        var at = AccountMenu.Items.IndexOf(AccountItem) + 2;
        foreach (var make in ShellExtensions.AccountMenu) AccountMenu.Items.Insert(at++, make());
        _notice = ShellExtensions.ConnectionNotice?.Invoke(_client, ConnectionBar);
        _client.Rpc.StateChanged += OnConnection;
        _client.Session.Ended += OnEnded;
        _hub.Changed += Rebuild;
        Places.BadgesChanged += Rebuild;
        WorkingRing.Changed += OnWorkingRing;
        DensitySizes.Changed += OnDensity;
        SidebarLayout.Changed += OnSidebarChanged;
        BotChatsStylePrefs.Changed += OnBotChatsStyleChanged;
        ThemeService.Changed += OnShellSurfaceChanged;
        WindowTransparency.Changed += OnShellSurfaceChanged;
        BackdropPrefs.Changed += OnShellSurfaceChanged;
        Navigator.Requested += Show;
        _history.Clear();
        _closingTabId = null;
        _tabList = Automation.Enabled
            ? new WorkspaceTabList()
            : WorkspaceTabList.Load(_client.AccountId, FilePreferences.Shared);
        OnConnection(_client.Rpc.State);
        ApplyWidth();
        RestyleShellSurface();
        Rebuild();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        App.Window?.DismissToolTips();
        DetachShell();
    }

    private void DetachShell()
    {
        if (_detached) return;
        _detached = true;
        if (Current == this) Current = null;
        _notice?.Dispose();
        _notice = null;
        Navigator.Requested -= Show;
        if (_hub != null) _hub.Changed -= Rebuild;
        Places.BadgesChanged -= Rebuild;
        WorkingRing.Changed -= OnWorkingRing;
        DensitySizes.Changed -= OnDensity;
        SidebarLayout.Changed -= OnSidebarChanged;
        BotChatsStylePrefs.Changed -= OnBotChatsStyleChanged;
        ThemeService.Changed -= OnShellSurfaceChanged;
        WindowTransparency.Changed -= OnShellSurfaceChanged;
        BackdropPrefs.Changed -= OnShellSurfaceChanged;
        if (_onUpdateChanged != null)
        {
            WindowsUpdateService.Changed -= _onUpdateChanged;
            _onUpdateChanged = null;
        }
        if (_client != null)
        {
            _client.Rpc.StateChanged -= OnConnection;
            _client.Session.Ended -= OnEnded;
        }
    }

    private void DetachForQuit()
    {
        DetachShell();
        // Leave whichever page sits in ContentFrame (Jobs, GroupRoom, Tiles, Artifacts, Settings, etc.)
        // while XAML is still live so its OnNavigatedFrom/Unloaded stops timers and UISettings handlers
        // before gateway teardown and drain.
        if (ContentFrame.Content is not null and not EmptyPane)
        {
            ContentFrame.Navigate(typeof(EmptyPane), null, new SuppressNavigationTransitionInfo());
            ContentFrame.BackStack.Clear();
        }
    }

    /// Stops shell listeners, active content page timers, background ListsHub polling, and live row-step timers.
    internal static void StopForQuit()
    {
        try { Current?.DetachForQuit(); }
        finally
        {
            try { App.Window?.DetachForQuit(); }
            finally
            {
                Features.Transcript.LinkChipView.StopForQuit();
                ListsHub.StopForQuit();
                ChatRowsWorking.StopForQuit();
                Features.Questions.QuestionsFeature.StopForQuit();
                Features.Settings.SettingsFeature.StopForQuit();
            }
        }
    }

    // ------------------------------------------------------------------ the sidebar's rows

    private bool Rail => _layout.Collapsed || (_narrow && !_openedWhileNarrow);

    private static List<PlaceInfo> PlaceInfos() => Places.All.Select(p => new PlaceInfo(p.Id, p.Title, p.Section == Places.Tools)).ToList();

    private List<SidebarItem> Items()
    {
        var items = new List<SidebarItem>();
        if (_hub == null) return items;
        var store = _hub.Bots;
        var now = DateTimeOffset.UtcNow;
        var rail = Rail;
        var sessions = _hub.Sessions.LiveSummaries();
        var allChoice = BotChatsChoice.Parse(store.Device.ChatsUnder.GetValueOrDefault("*")) ?? BotChatsChoice.Initial;
        // [groups] The rooms among the bots' blocks, as the Mac's sidebar and rail draw them (MacBotsRail.titledGroups):
        // filed in their user sections or Unassigned, else a Group Chats block; pinned ones with the pins.
        var (sections, _) = BotListRooms.Compose(store.Sections, _hub.Groups.Rows(), store.Device.Sections);
        var groups = BotList.SidebarGroups(sections, store.Device.ShowHidden);
        foreach (var group in groups)
        {
            var collapsed = store.Device.Collapsed.Contains(group.Key);
            var heads = group.Heads;
            if (rail)
            {
                if (heads.Count == 0) continue;
                if (items.Count > 0) items.Add(new SidebarDivider());
            }
            else if (group.Title is { Length: > 0 } || group.Block != BotBlock.Everything)
                items.Add(new SidebarHeader(group.Title ?? "", group.Key, collapsed, group.Block == BotBlock.User ? group.SectionId : null));
            if (collapsed && !rail) continue;
            foreach (var head in heads)
            {
                if (head.Room is { } room)
                {
                    items.Add(new SidebarRoom(room, group.Block, group.Block == BotBlock.User ? group.SectionId : null));
                    continue;
                }
                var bot = head.Bot!;
                items.Add(new SidebarBot(bot, store.MuteOf(bot.Id, now) != null, group.Block, group.Block == BotBlock.User ? group.SectionId : null));
                if (rail || bot.Hidden) continue;
                var choice = BotChatsChoice.Parse(store.Device.ChatsUnder.GetValueOrDefault(bot.Id)) ?? allChoice;
                var (shown, more) = BotChatsUnder.Pick(sessions, bot.Id, choice);
                for (var i = 0; i < shown.Count; i++)
                    items.Add(new SidebarChat(
                        shown[i],
                        bot.Id,
                        last: i == shown.Count - 1 && more == 0,
                        first: i == 0,
                        showsPin: BotChatsUnder.ShowsPin(shown[i], shown),
                        botModel: bot.Model));
                if (shown.Count > 0 && more > 0)
                    items.Add(new SidebarMore(bot.Id, more, first: shown.Count == 0, botModel: bot.Model));
            }
        }
        items.Add(new SidebarAction("New Bot", "", () => _ = _actions?.NewBotAsync()));
        items.Add(new SidebarDivider());
        var infos = PlaceInfos();
        // A Tool turned on in Settings › Appearance › Sidebar moves up to the places (TabOrderPage: "Turn one on to move it up
        // to the places above"): there it is a place like the rest, dragged and moved with them, no longer a Tool.
        foreach (var id in _layout.Shown(infos)) items.Add(new SidebarPlace(Places.Get(id), false));
        var tools = _layout.Tools(infos);
        if (rail)
        {
            if (tools.Count > 0) items.Add(new SidebarAction("Tools", "", ShowToolsMenu));
        }
        else
        {
            var toolsClosed = store.Device.Collapsed.Contains("tools");
            items.Add(new SidebarHeader("Tools", "tools", toolsClosed));
            if (!toolsClosed) items.AddRange(tools.Select(id => new SidebarPlace(Places.Get(id), true)));
        }
        return items;
    }

    private static string? KeyOf(SidebarItem item) => item switch
    {
        SidebarBot b => "bot:" + b.Bot.Id,
        SidebarRoom r => BotListHead.RoomKey(r.Room.Id),
        SidebarPlace p => "place:" + p.Place.Id,
        SidebarChat c => "chat:" + c.Chat.Profile + "/" + c.Chat.Id,
        _ => null,
    };

    /// [working-ring] Settings › Appearance › Working Ring: the rows are drawn again at once, so a working row's ring goes
    /// (or comes back) the moment the switch moves.
    private void OnWorkingRing() => Rebuild();
    /// [density] Theme › Density: the rows again at the new sizes.
    private void OnDensity() => Rebuild();
    /// Settings › Appearance › Chats Under Bots connector style changed: redraw sidebar connectors immediately.
    private void OnBotChatsStyleChanged()
    {
        if (_detached || AppShutdown.Stopping) return;
        DispatcherQueue.TryEnqueue(() =>
        {
            if (!_detached && !AppShutdown.Stopping) Rebuild();
        });
    }
    /// Theme, Window Transparency, or App Background changed: restyle the floating canvas, sidebar veil, and top bar.
    private void OnShellSurfaceChanged()
    {
        if (_detached || AppShutdown.Stopping) return;
        DispatcherQueue.TryEnqueue(() =>
        {
            if (!_detached && !AppShutdown.Stopping) RestyleShellSurface();
        });
    }

    private void RestyleShellSurface()
    {
        if (_detached || AppShutdown.Stopping) return;
        var appBackdrop = BackdropPainter.CreateBrush(BackdropPlace.App);
        GlassShell.StyleCanvas(CanvasBorder, appBackdrop, CanvasShadowReceiver);
        GlassShell.StyleSidebar(SidebarPane);
        if (Sidebar.ItemsSource is List<ListViewItem> rows)
            foreach (var row in rows)
                if (row.Tag is not SidebarDivider) SelectionMark.Shape(row);
        _workspaceBar.Recolor();
    }
    /// [taborder] Settings › Appearance › Sidebar saved a change (or this page did): the places again from disk, as the
    /// Mac's sidebar follows `TabOrder.didChange`. Width and fold are saved as they change, so nothing is lost.
    private void OnSidebarChanged()
    {
        if (_detached || AppShutdown.Stopping) return;
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_detached || AppShutdown.Stopping) return;
            _layout = SidebarLayout.Load(_disk);
            Rebuild();
        });
    }

    private void Rebuild()
    {
        if (_hub == null || _detached || AppShutdown.Stopping) return;
        App.Window?.DismissToolTips();
        var sidebarFocused = XamlRoot != null
            && FocusManager.GetFocusedElement(XamlRoot) is DependencyObject focused && Inside(focused, Sidebar);
        var rail = Rail;
        var containers = Items().Select(item =>
        {
            var c = SidebarRowView.Make(item, rail, _layout.RailNamed);
            c.CanDrag = item is SidebarBot || (item is SidebarPlace p && !rail && !p.IsTool);
            if (item is not SidebarDivider and not SidebarAction && (item is not SidebarRoom || ShellExtensions.RoomMenu != null))
            {
                var menu = new MenuFlyout();
                menu.Opening += (_, _) => FillMenu(menu, item);
                c.ContextFlyout = menu;
            }
            return c;
        }).ToList();
        Sidebar.ItemsSource = containers;
        Sidebar.SelectedItem = containers.FirstOrDefault(c => KeyOf((SidebarItem)c.Tag) is { } k && k == SelectedKey());
        if (sidebarFocused) Sidebar.Focus(FocusState.Programmatic);
        ListLoading.IsActive = !_hub.Bots.HasRoster;
        SyncWorkspaceBar();
        // At launch the first bot's chat opens, once.
        if (!_autoOpened && _hub.Bots.HasRoster && _openKey == null && _hub.Bots.Layout.Flat.FirstOrDefault() is { } first)
        {
            _autoOpened = true;
            // [gateways] The last chat, reopened at launch, when there was one.
            var bots = _hub.Bots.Layout.Flat.Select(r => r.Model).ToList();
            Navigator.Go(ShellExtensions.FirstDestination?.Invoke(bots) ?? new BotChatDestination(first.Model));
        }
    }

    private string? _selectedKey;
    private string? SelectedKey() => _selectedKey;

    private void Mark(string? key)
    {
        _selectedKey = key;
        if (Sidebar.ItemsSource is List<ListViewItem> items)
            Sidebar.SelectedItem = items.FirstOrDefault(c => KeyOf((SidebarItem)c.Tag) is { } k && k == key);
    }

    private void Sidebar_ItemClick(object sender, ItemClickEventArgs e)
    {
        var item = (e.ClickedItem as ListViewItem)?.Tag as SidebarItem ?? Sidebar.Items.OfType<ListViewItem>().FirstOrDefault(c => c.Content == e.ClickedItem)?.Tag as SidebarItem;
        switch (item)
        {
            case SidebarHeader h:
                _hub?.Bots.SetCollapsed(h.Key, !h.Collapsed);
                break;
            case SidebarBot b:
                Navigator.Go(new BotChatDestination(b.Bot.Model));
                break;
            case SidebarRoom room:
                // [groups] The room's own chat in the pane (AppModel+Groups.swift `openRoom`); it reads the room as it shows.
                Navigator.Go(new RoomDestination(room.Room.Id));
                break;
            case SidebarChat c:
                _nextOrigin = "bots";   // a chat under its bot: the Bots list's
                Navigator.Go(new ChatDestination(c.Chat.Profile, c.Chat.Id, c.Chat.Title));
                break;
            case SidebarMore m:
                Navigator.Open("sessions", m.Bot);
                break;
            case SidebarPlace p:
                Navigator.Open(p.Place.Id);
                break;
            case SidebarAction a:
                a.Run();
                break;
        }
    }

    /// The places Ctrl+1…9 number, in the Mac's order (`MainTabController.placedTabs`): Bots, the places shown above
    /// Tools, then the Tools.
    internal List<string> NumberedPlaces()
    {
        var infos = PlaceInfos();
        return PlaceKeys.Numbered(_layout.Shown(infos), _layout.Tools(infos));
    }

    /// Ctrl+n (the Mac's `hqSelectTab`): the place with that number. Bots, whose rows are the sidebar itself, brings back
    /// the chat last opened from the bots, as the Mac's right pane follows its Bots tab (`followSelectedTab`), else
    /// "No Chat Open". A number with no place does nothing.
    internal bool PickNth(int n)
    {
        var places = NumberedPlaces();
        if (PlaceKeys.Place(n - 1, places.Count) is not { } at) return false;
        AppLog.Note("keys", "select tab");
        KeyActs++;
        SelectionMark.SetFocus(Hermes.Core.Shell.DesktopLook.Pane.Sidebar);   // [WIN-49] MacSelection.focus(on:): a tab by key gives the sidebar the focus
        if (places[at] != PlaceKeys.Bots) { Navigator.Open(places[at]); return true; }
        if (_openChat != null && !_fromSessions) return true;   // the Bots place is on show already
        if (_botsChat is { } back) Navigator.Go(back);
        else ClosePane();
        return true;
    }

    // ------------------------------------------------------------------ View › Next Chat / Previous Chat (WalkKeys)

    private bool _fromSessions;      // the chat on show was opened from Sessions (the Mac's tab it is on)
    private string? _nextOrigin;     // "sessions" or "bots": where the next chat shown comes from, when known
    private Destination? _botsChat;  // the chat last opened from the bots (what Ctrl+1 brings back)
    /// [botslist] The bot whose chat is still finding its id (before its chat page has it): its row's "Waking up…" wait.
    private string? _wakingBot;

    /// [WIN-39] How many times Next / Previous Chat or a place number acted (each `[keys] next chat`, `previous chat`,
    /// `select tab`): the CI's window-keys walk calls what a key calls only when the key itself did nothing.
    internal int KeyActs { get; private set; }

    /// The walk's facts now (KeyCommands.walkList's lists, `validate`'s dimming).
    internal WalkFacts WalkState()
    {
        var state = KeyState();
        var place = _openKey?.StartsWith("place:", StringComparison.Ordinal) == true ? _openKey["place:".Length..] : null;
        IReadOnlyList<string> bots = [], sessions = [];
        if (_hub != null)
        {
            var store = _hub.Bots;
            bots = ChatWalk.BotOrder(BotList.SidebarGroups(store.Sections, store.Device.ShowHidden), store.Device.Collapsed);
            sessions = ChatWalk.SessionOrder(_hub.Sessions.Groups());
        }
        return new WalkFacts(state.Pane, state.Profile, state.StoredId, place, _fromSessions, bots, sessions,
            Covered: XamlRoot != null && Microsoft.UI.Xaml.Media.VisualTreeHelper.GetOpenPopupsForXamlRoot(XamlRoot).Any(p => p.Child is ContentDialog),
            FieldHasText: FieldHasText());
    }

    /// The caret is in a field holding words: Ctrl+Up / Ctrl+Down are its own then.
    private bool FieldHasText()
    {
        if (XamlRoot == null) return false;
        switch (FocusManager.GetFocusedElement(XamlRoot))
        {
            case TextBox t: return t.Text.Length > 0;
            case PasswordBox p: return p.Password.Length > 0;
            case RichEditBox r:
                r.TextDocument.GetText(Microsoft.UI.Text.TextGetOptions.None, out var text);
                return text.Trim().Length > 0;
            default: return false;
        }
    }

    /// Ctrl+Down / Ctrl+Up (`hqNextChat`, `hqPreviousChat`): the next or previous row of the list the chat on show came
    /// from, opened in the pane. Off (the key passes on) at either end: no wraparound, as on the Mac.
    internal bool Walk(bool forward)
    {
        var facts = WalkState();
        if (_hub == null || WalkKeys.Target(facts, forward) is not { } key)
        {
            AppLog.Note("keys", forward ? "next chat: at the end" : "previous chat: at the start");
            return false;
        }
        AppLog.Note("keys", forward ? "next chat" : "previous chat");
        if (WalkKeys.ListFor(facts) == WalkList.Sessions)
        {
            if (ChatWalk.SplitSessionKey(key) is not { } row) return false;
            var (profile, id) = row;
            var title = _hub.Sessions.LiveSummaries().FirstOrDefault(s => s.Profile == profile && s.Id == id)?.Title ?? "";
            _nextOrigin = "sessions";
            Navigator.Go(new ChatDestination(profile, id, title));
        }
        else
        {
            if (_hub.Bots.Bot(key) is not { } bot) return false;
            _nextOrigin = "bots";
            Navigator.Go(new BotChatDestination(bot.Model));
        }
        KeyActs++;
        return true;
    }

    /// Ctrl+R / F5 (`hqRefresh`): the page on show's own refresh, the lists with a chat or nothing on show; on a page
    /// with none the key passes on (its own key, if it has one, still acts).
    internal bool KeyRefresh()
    {
        var page = ContentFrame.Content as IKeyRefreshing;
        switch (RefreshKeys.Target(KeyState().Pane, page != null))
        {
            case RefreshTarget.Page:
                AppLog.Note("keys", "refresh");
                page!.KeyRefresh();
                return true;
            case RefreshTarget.Lists:
                AppLog.Note("keys", "refresh");
                Refresh_Click(this, new RoutedEventArgs());
                return true;
            default:
                return false;
        }
    }

    // ------------------------------------------------------------------ menus (right-click)

    private void FillMenu(MenuFlyout menu, SidebarItem item)
    {
        menu.Items.Clear();
        if (_hub == null || _actions == null) return;
        switch (item)
        {
            case SidebarBot b when _hub.Bots.Bot(b.Bot.Id) is { } fresh:
                _actions.FillBotMenu(menu.Items, fresh);
                break;
            case SidebarRoom r when _hub.Groups.Rows().FirstOrDefault(x => x.Id == r.Room.Id) is { } room:
                ShellExtensions.RoomMenu?.Invoke(menu.Items, room, XamlRoot);   // [groups] the room's own menu
                break;
            case SidebarHeader { SectionId: { } id }:
                _actions.FillSectionMenu(menu.Items, id);
                break;
            case SidebarHeader { Key: "tools" }:
                FillSpaceMenu(menu.Items);
                break;
            case SidebarHeader:
                _actions.FillAddMenu(menu.Items);
                break;
            case SidebarChat c:
                FillChatMenu(menu.Items, c.Chat);
                break;
            case SidebarPlace p:
                FillPlaceMenu(menu.Items, p);
                break;
        }
    }

    private static MenuFlyoutItem Item(string text, string glyph, Action run, bool enabled = true)
    {
        var i = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph }, IsEnabled = enabled };
        i.Click += (_, _) => run();
        return i;
    }

    /// A place's right-click (SidebarEditing.rowMenu): Move Up, Move Down, Remove from Sidebar; a tool's: Move to Places;
    /// then the sidebar's own menu.
    private void FillPlaceMenu(IList<MenuFlyoutItemBase> items, SidebarPlace p)
    {
        var infos = PlaceInfos();
        var shown = _layout.Shown(infos);
        if (shown.Contains(p.Place.Id))
        {
            items.Add(Item("Move Up", "", () => { _layout.Move(p.Place.Id, -1, infos); SaveLayout(); }, _layout.CanMove(p.Place.Id, -1, infos)));
            items.Add(Item("Move Down", "", () => { _layout.Move(p.Place.Id, 1, infos); SaveLayout(); }, _layout.CanMove(p.Place.Id, 1, infos)));
            if (_layout.CanRemove(p.Place.Id, infos))
            {
                items.Add(new MenuFlyoutSeparator());
                items.Add(Item("Remove from Sidebar", "", () => { _layout.Remove(p.Place.Id, infos); SaveLayout(); }));
            }
        }
        else items.Add(Item("Move to Places", "", () => { _layout.Add(p.Place.Id, infos); SaveLayout(); }));
        items.Add(new MenuFlyoutSeparator());
        FillSpaceMenu(items);
    }

    /// The sidebar's own menu: Add to Sidebar ▸ (dimmed when nothing is left to add), Sidebar Settings….
    private void FillSpaceMenu(IList<MenuFlyoutItemBase> items)
    {
        var infos = PlaceInfos();
        var addable = _layout.Addable(infos);
        if (addable.Count == 0) items.Add(Item("Add to Sidebar", "", () => { }, false));
        else
        {
            var sub = new MenuFlyoutSubItem { Text = "Add to Sidebar", Icon = new FontIcon { Glyph = "" } };
            foreach (var p in addable)
                sub.Items.Add(Item(p.Title, Places.Get(p.Id).Glyph, () => { _layout.Add(p.Id, infos); SaveLayout(); }));
            items.Add(sub);
        }
        items.Add(new MenuFlyoutSeparator());
        items.Add(Item("Sidebar Settings…", "", () => SettingsWindows.Show("sidebar")));
    }

    private void FillChatMenu(IList<MenuFlyoutItemBase> items, SessionSummary chat)
    {
        var store = _hub!.Sessions;
        items.Add(Item(chat.Pinned ? "Unpin" : "Pin", chat.Pinned ? "" : "",
            () => _ = Prompts.RunAsync(XamlRoot, chat.Pinned ? "Couldn’t Unpin Chat" : "Couldn’t Pin Chat", () => store.SetPinnedAsync(chat, !chat.Pinned))));
        items.Add(Item(chat.Unread ? "Mark Read" : "Mark Unread", chat.Unread ? "" : "", () => _ = store.SetUnreadAsync(chat, !chat.Unread)));
        items.Add(new MenuFlyoutSeparator());
        items.Add(Item("Archive", "", () => _ = ArchiveFromSidebarAsync(store, chat)));
    }

    private async Task ArchiveFromSidebarAsync(SessionStore store, SessionSummary chat)
    {
        if (!await Prompts.RunAsync(XamlRoot, "Couldn’t Archive Chat", () => store.SetArchivedAsync(chat, true))) return;
        if (_openChat?.StoredId == chat.Id && _openChat.Profile == chat.Profile) ClosePane();
        UndoPill.Show(PillHost, ChatKeys.ArchivedLabel(chat.Title), SessionStore.ArchivedWayBack,
            HermesHQ.Features.Sessions.ArchiveUndoRoute.For(() => XamlRoot, store, chat));
    }

    private void Add_Click(object sender, RoutedEventArgs e)
    {
        if (_actions == null) return;
        var menu = new MenuFlyout();
        _actions.FillAddMenu(menu.Items);
        menu.Items.Add(new MenuFlyoutSeparator());
        FillSpaceMenu(menu.Items);
        menu.ShowAt((FrameworkElement)sender);
    }

    private void ShowToolsMenu()
    {
        var menu = new MenuFlyout();
        foreach (var id in _layout.Tools(PlaceInfos()))
        {
            var place = Places.Get(id);
            menu.Items.Add(Item(place.Title, place.Glyph, () => Navigator.Open(place.Id)));
        }
        if (Sidebar.ItemsSource is List<ListViewItem> rows && rows.FirstOrDefault(r => r.Tag is SidebarAction { Title: "Tools" }) is { } anchor)
            menu.ShowAt(anchor);
    }

    private void SaveLayout()
    {
        _layout.Save(_disk);
        Rebuild();
        SidebarLayout.NotifyChanged();   // an open Settings › Sidebar page follows (the Mac's TabOrder.didChange)
    }

    // ------------------------------------------------------------------ drag to reorder places, or file a bot

    private void Sidebar_DragItemsStarting(object sender, DragItemsStartingEventArgs e)
    {
        _dragged = (e.Items.FirstOrDefault() as ListViewItem)?.Tag as SidebarItem;
        if (_dragged is not (SidebarBot or SidebarPlace)) { e.Cancel = true; return; }
        e.Data.SetText("hermes-hq-sidebar");
        e.Data.RequestedOperation = DataPackageOperation.Move;
    }

    private void Sidebar_DragOver(object sender, DragEventArgs e)
    {
        e.AcceptedOperation = _dragged != null ? DataPackageOperation.Move : DataPackageOperation.None;
    }

    private void Sidebar_Drop(object sender, DragEventArgs e)
    {
        var dragged = _dragged;
        _dragged = null;
        if (dragged == null || _hub == null || _actions == null) return;
        var target = RowAt(e.GetPosition(Sidebar));
        switch (dragged)
        {
            case SidebarPlace p:
            {
                var infos = PlaceInfos();
                var shown = _layout.Shown(infos);
                var before = target is SidebarPlace tp && shown.Contains(tp.Place.Id) ? tp.Place.Id : null;
                if (target is SidebarPlace or SidebarHeader { Key: "tools" } || target == null) { _layout.MoveBefore(p.Place.Id, before, infos); SaveLayout(); }
                break;
            }
            case SidebarBot b:
            {
                var bot = b.Bot;
                switch (target)
                {
                    case SidebarHeader { SectionId: { } id }: _ = _actions.Move(bot, id); break;
                    case SidebarBot { Block: BotBlock.User, SectionId: { } id } when id != b.SectionId: _ = _actions.Move(bot, id); break;
                    case SidebarBot { Block: BotBlock.Tiles or BotBlock.Pinned } when !bot.Pinned: _ = _actions.Pin(bot, true); break;
                    case SidebarBot { Block: BotBlock.Unassigned } when b.Block == BotBlock.User: _ = _actions.Move(bot, null); break;
                }
                break;
            }
        }
    }

    private SidebarItem? RowAt(Windows.Foundation.Point point)
    {
        if (Sidebar.ItemsSource is not List<ListViewItem> rows) return null;
        foreach (var row in rows)
        {
            var top = row.TransformToVisual(Sidebar).TransformPoint(new Windows.Foundation.Point(0, 0)).Y;
            if (point.Y >= top && point.Y < top + row.ActualHeight) return row.Tag as SidebarItem;
        }
        return null;
    }

    // ------------------------------------------------------------------ fold, rail, width

    private void Fold_Click(object sender, RoutedEventArgs e) => ToggleFold();

    /// The sidebar's button: folds it to the rail, or opens it (kept across launches). While the window is too narrow it
    /// opens for now without saving.
    private void ToggleFold()
    {
        if (_listHidden) { _listHidden = false; ApplyWidth(); SyncWorkspaceBar(); return; }
        if (_narrow && !_layout.Collapsed) _openedWhileNarrow = !_openedWhileNarrow;
        else { _layout.Collapsed = !_layout.Collapsed; _layout.Save(_disk); }
        ApplyWidth();
        Rebuild();
    }

    private bool CanToggleList => _openChat != null || _listHidden;

    /// View › Hide List / Show List (Ctrl+Shift+L, App/Root/KeyCommands.swift `toggleList`): hides or restores the
    /// sidebar list column beside an open chat for full-width reading.
    private bool ToggleList()
    {
        if (!CanToggleList) return false;
        _listHidden = !_listHidden;
        ApplyWidth();
        SyncWorkspaceBar();
        return true;
    }

    private void ApplyWidth()
    {
        if (_listHidden)
        {
            SidebarColumn.Width = new GridLength(0);
            SidebarPane.Visibility = Visibility.Collapsed;
            Grip.Visibility = Visibility.Collapsed;
            return;
        }
        SidebarPane.Visibility = Visibility.Visible;
        Grip.Visibility = Visibility.Visible;
        var rail = Rail;
        SidebarColumn.Width = new GridLength(rail ? _layout.RailWidth : SidebarLayout.ClampOpen(_layout.OpenWidth, ActualWidth));
        if (_toolsRail != rail)
        {
            _toolsRail = rail;
            ToolsHost.Content = SidebarTools.Build(rail, ShowOpenQuickly, () => NewChat_Click(this, new RoutedEventArgs()));
        }
        // The gateway's line shows open only, the feature's (GatewayFoot) as the default's (MacSidebar `showGateway`:
        // `shown = tidy && !isCollapsed`; the rail has no room for words).
        GatewayFootHost.Visibility = rail ? Visibility.Collapsed : Visibility.Visible;
        FootButtons.Orientation = rail ? Orientation.Vertical : Orientation.Horizontal;
        AddButton.Visibility = rail ? Visibility.Collapsed : Visibility.Visible;
        Foot.ColumnDefinitions[0].Width = GridLength.Auto;
        Grid.SetColumn(FootButtons, rail ? 0 : 2);
        Grid.SetRow(FoldButton, 0);
        FoldButton.Visibility = Visibility.Visible;
        SidebarPane.Padding = rail ? new Thickness(4, 0, 4, 8) : new Thickness(8, 0, 6, 8);
        ToolTipService.SetToolTip(FoldButton, rail ? "Show Sidebar (Ctrl+Shift+S)" : "Hide Sidebar (Ctrl+Shift+S)");
        // [WIN-55] MacSidebar.swift: `toggle.accessibilityLabel = folded ? "Show Sidebar" : "Hide Sidebar"`.
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(FoldButton, rail ? "Show Sidebar" : "Hide Sidebar");
        if (rail)
        {
            // The fold button sits under the rail's other buttons.
            if (FoldButton.Parent is Grid) { Foot.Children.Remove(FoldButton); FootButtons.Children.Add(FoldButton); }
        }
        else if (FoldButton.Parent is StackPanel s) { s.Children.Remove(FoldButton); Foot.Children.Insert(0, FoldButton); Grid.SetColumn(FoldButton, 0); }
    }

    private void Page_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var narrow = SidebarLayout.NarrowWindow(e.NewSize.Width);
        if (narrow == _narrow) { if (!Rail) ApplyWidth(); return; }
        _narrow = narrow;
        if (!narrow) _openedWhileNarrow = false;
        ApplyWidth();
        Rebuild();
    }

    private void Grip_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        _gripping = Grip.CapturePointer(e.Pointer);
        _gripStartX = e.GetCurrentPoint(this).Position.X;
        _gripStartWidth = SidebarColumn.ActualWidth;
        e.Handled = true;
    }

    private void Grip_PointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_gripping) return;
        var width = _gripStartWidth + e.GetCurrentPoint(this).Position.X - _gripStartX;
        SidebarColumn.Width = new GridLength(Rail
            ? Math.Clamp(width, SidebarLayout.CompactRailWidth, SidebarLayout.NamedRailWidth + 20)
            : SidebarLayout.ClampOpen(width, ActualWidth));
        e.Handled = true;
    }

    private void Grip_PointerReleased(object sender, PointerRoutedEventArgs e)
    {
        Grip.ReleasePointerCapture(e.Pointer);
        EndGrip();
    }

    private void Grip_PointerCaptureLost(object sender, PointerRoutedEventArgs e) => EndGrip();

    /// The rail settles to faces alone or faces with names; the open sidebar keeps its width.
    private void EndGrip()
    {
        if (!_gripping) return;
        _gripping = false;
        if (Rail)
        {
            var (_, named) = SidebarLayout.SettleRail(SidebarColumn.ActualWidth);
            _layout.RailNamed = named;
        }
        else _layout.OpenWidth = SidebarLayout.ClampOpen(SidebarColumn.ActualWidth, ActualWidth);
        _layout.Save(_disk);
        ApplyWidth();
        Rebuild();
    }

    // ------------------------------------------------------------------ the content pane

    private int _navGeneration;

    private async void Show(Destination d)
    {
        if (_client == null || _hub == null) return;
        var gen = ++_navGeneration;
        EndWaking(d);
        App.Window?.DismissToolTips();
        try
        {
            switch (d)
            {
                case BotChatDestination { Bot: var bot }:
                    _nextOrigin = null;
                    _fromSessions = false;
                    _botsChat = d;
                    Mark("bot:" + bot.Name);
                    _hub.Bots.VisibleBot = bot.Name;
                    _hub.Sessions.Selected = null;
                    // [botslist] Its row says "Waking up…" once this has taken a second (AppModel.chat(for:) at 93f984bb1); the
                    // chat page ends the wait when its open settles or it is left.
                    var bots = _hub.Bots;
                    bots.NoteBotOpening(bot.Name, true);
                    _wakingBot = bot.Name;
                    try
                    {
                        var id = await bots.BotChatIdAsync(bot.Name);
                        if (_wakingBot == bot.Name) _wakingBot = null;
                        if (gen != _navGeneration || _detached || AppShutdown.Stopping)
                        {
                            bots.NoteBotOpening(bot.Name, false);
                            return;
                        }
                        // The chat already on screen opens no page, so nothing else would end the wait.
                        if (!OpenChat(new ChatDestination(bot.Name, id, bot.DisplayName), botChat: true)) bots.NoteBotOpening(bot.Name, false);
                        bots.MarkRead(bot.Name);
                        RecordWorkspaceOpen(
                            new WorkspaceTabRecord(WorkspaceTabKind.Bot, bot.Name, bot.Name, bot.DisplayName),
                            new WorkspaceBotNav(bot.Name));
                    }
                    catch (Exception x) when (x is GatewayException or BotWriteException)
                    {
                        if (_wakingBot == bot.Name) _wakingBot = null;
                        bots.NoteBotOpening(bot.Name, false);   // the open failed: the wait is over
                        if (gen != _navGeneration || _detached || AppShutdown.Stopping) return;
                        AppLog.Note("open", "bot chat failed");
                        if (RosterRules.IsGatewayBusy(x)) ShowMessage("Your gateway is busy", $"Couldn’t open {bot.DisplayName}’s chat in time. Try again in a moment.");
                        else ShowMessage($"Could not open {bot.DisplayName}’s chat", "Try again.");
                    }
                    break;
                case ChatDestination chat:
                    // Opened from Sessions (its page on show, or the walk through its rows) or from the bots.
                    _fromSessions = _nextOrigin == "sessions" || (_nextOrigin == null && _openKey == "place:sessions");
                    _nextOrigin = null;
                    if (!_fromSessions) _botsChat = d;
                    Mark("chat:" + chat.Profile + "/" + chat.StoredId);
                    _hub.Bots.VisibleBot = null;
                    _hub.Sessions.Selected = (chat.Profile, chat.StoredId);
                    OpenChat(chat);
                    _ = _hub.Sessions.OpenedAsync(chat.Profile, chat.StoredId);
                    var sessionTitle = _hub.Sessions.LiveSummaries()
                        .FirstOrDefault(s => s.Profile == chat.Profile && s.Id == chat.StoredId)?.Title;
                    RecordWorkspaceOpen(
                        new WorkspaceTabRecord(
                            WorkspaceTabKind.Session,
                            chat.Profile,
                            chat.StoredId,
                            !string.IsNullOrWhiteSpace(sessionTitle) ? sessionTitle : !string.IsNullOrWhiteSpace(chat.Title) ? chat.Title : "Chat"),
                        new WorkspaceSessionNav(chat.Profile, chat.StoredId));
                    break;
                case RoomDestination { Key: var roomKey }:
                    // [groups] A group chat (Pages/GroupRoomPage.cs): its row marked, no bot's or session's chat selected.
                    _nextOrigin = null;
                    _fromSessions = false;
                    _botsChat = d;
                    var marked = Hermes.Core.Bots.BotListHead.RoomKey(roomKey);
                    Mark(marked);
                    _hub.Bots.VisibleBot = null;
                    _hub.Sessions.Selected = null;
                    _openChat = null;
                    ContentPlaceholder.Visibility = Visibility.Collapsed;
                    if (_openKey == marked && GroupRoomPage.Current?.RoomKey == roomKey)
                    {
                        if (!_navigatingHistory) _history.Record(new WorkspaceRoomNav(roomKey));
                        SyncWorkspaceBar();
                        break;
                    }
                    _openKey = marked;
                    ContentFrame.Navigate(typeof(GroupRoomPage), new GroupRoomPage.Args(roomKey), new SuppressNavigationTransitionInfo());
                    ContentFrame.BackStack.Clear();
                    if (!_navigatingHistory) _history.Record(new WorkspaceRoomNav(roomKey));
                    SyncWorkspaceBar();
                    break;
                case PlaceDestination { PlaceId: var id, Argument: var arg }:
                    var place = Places.Get(id);
                    Mark("place:" + id);
                    _hub.Bots.VisibleBot = null;
                    _openKey = "place:" + id;
                    _openChat = null;
                    ContentPlaceholder.Visibility = Visibility.Collapsed;
                    try { ContentFrame.Navigate(place.Page, new PlaceArgs(place, arg), new SuppressNavigationTransitionInfo()); }
                    catch (Exception e)
                    {
                        // A page that throws while it is built shows what went wrong instead of closing the app.
                        AppLog.Note("shell", $"couldn't open {id}: {e}");
                        ContentFrame.Navigate(typeof(PlaceholderPage), new PlaceArgs(place, e), new SuppressNavigationTransitionInfo());
                    }
                    ContentFrame.BackStack.Clear();
                    if (!_navigatingHistory) _history.Record(new WorkspacePlaceNav(id, arg as string));
                    SyncWorkspaceBar();
                    break;
            }
        }
        catch (Exception ex) { AppLog.Error("shell", ex); }
    }

    /// False when that chat is the one already open (no page is made).
    private bool OpenChat(ChatDestination chat, bool botChat = false)
    {
        var key = "chat:" + chat.Profile + "/" + chat.StoredId;
        _openChat = chat;
        _openIsBotChat = botChat;
        ContentPlaceholder.Visibility = Visibility.Collapsed;
        if (key == _openKey) return false;
        _openKey = key;
        ContentFrame.Navigate(typeof(ChatPage), new ChatPage.Args(chat.Profile, chat.StoredId, chat.Title, chat.Draft, botChat),
            new SuppressNavigationTransitionInfo());
        ContentFrame.BackStack.Clear();
        return true;
    }

    /// [botslist] Going anywhere but that bot's chat while its id is still being found leaves the chat: the wait ends
    /// (AppModel.chatLeft at 93f984bb1).
    private void EndWaking(Destination? next)
    {
        if (_wakingBot is not { } waking || next is BotChatDestination { Bot.Name: var name } && name == waking) return;
        _wakingBot = null;
        _hub?.Bots.NoteBotOpening(waking, false);
    }

    private void ShowMessage(string title, string text)
    {
        PlaceholderTitle.Text = title;
        PlaceholderText.Text = text;
        ContentPlaceholder.Visibility = Visibility.Visible;
    }

    // ------------------------------------------------------------------ connection, account

    private void OnConnection(ConnectionState state)
    {
        if (_detached || AppShutdown.Stopping) return;
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_detached || AppShutdown.Stopping) return;
            if (state == ConnectionState.SignedOut) { OnEnded(); return; }
            if (_notice != null) return; // the gateways feature words the notice and draws the foot's dot
            ConnectionBar.IsOpen = state is ConnectionState.Connecting or ConnectionState.Offline;
            ConnectionBar.Severity = state == ConnectionState.Offline ? InfoBarSeverity.Warning : InfoBarSeverity.Informational;
            ConnectionBar.Message = state == ConnectionState.Offline ? "Can't reach your gateway. Trying again…" : "Connecting…";
            ConnectionDot.Fill = ThemeBrushes.Get(state switch
            {
                ConnectionState.Open => "SystemFillColorSuccessBrush",
                ConnectionState.Offline => "SystemFillColorCautionBrush",
                _ => "SystemFillColorNeutralBrush",
            });
        });
    }

    private void OnEnded()
    {
        if (_detached || AppShutdown.Stopping) return;
        DispatcherQueue.TryEnqueue(async () =>
        {
            if (_detached || AppShutdown.Stopping) return;
            _hub?.Stop();
            if (ShellExtensions.SessionEnded is { } ended) { ended(); return; }
            await AppState.SignOutAsync();
            App.Window?.ShowSignIn("Your sign-in ended. Sign in again.");
        });
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e)
    {
        try { if (_hub != null) await _hub.RefreshAsync(); }
        catch (Exception ex) { AppLog.Error("shell", ex); }
    }

    private void Settings_Click(object sender, RoutedEventArgs e) => SettingsWindows.Show();

    /// New Chat: a fresh session with the open bot (the Mac's ⌘N), the first bot when none is open.
    private void NewChat_Click(object sender, RoutedEventArgs e)
    {
        var bot = NewChatBotId();
        if (bot != null) _ = NewChatWithAsync(bot);
    }

    /// The bot Ctrl+N starts a chat with: the open bot, the selected chat's, else the first (the shortcuts sheet names it).
    private string? NewChatBotId() =>
        _hub?.Bots.VisibleBot ?? _hub?.Sessions.Selected?.Profile ?? _hub?.Bots.Layout.Flat.FirstOrDefault()?.Id;

    private async Task NewChatWithAsync(string bot, string? folder = null)
    {
        if (_hub == null || App.Window?.Lifetime is not { IsClosing: false } lifetime) return;
        string? id = null;
        await Prompts.RunAsync(XamlRoot, "Couldn’t Start a New Chat", async () => id = await _hub.Sessions.NewChatAsync(bot, folder, lifetime.StopToken), lifetime.StopToken);
        if (!lifetime.IsClosing && id != null) Navigator.Go(new ChatDestination(bot, id, "New Chat"));
    }

    // ------------------------------------------------------------------ File's chat keys (Hermes.Core.Shell.ChatKeys)

    private ChatDestination? _openChat;   // the chat in the pane (a bot's own chat too), null for a place or nothing
    private bool _openIsBotChat, _archiving;

    /// What the pane holds, as the chat keys decide on it (App/Root/KeyCommands.swift `validate`).
    internal ChatKeyState KeyState()
    {
        if (_openChat is not { } chat)
            return new(_openKey?.StartsWith("place:", StringComparison.Ordinal) == true ? OpenPane.Place : OpenPane.Nothing, null, null);
        var row = _openIsBotChat ? null : _hub?.Sessions.Row(chat.Profile, chat.StoredId);
        return new(_openIsBotChat ? OpenPane.BotChat : OpenPane.Chat, chat.Profile, chat.StoredId,
            Online: _client?.Rpc.State == ConnectionState.Open, Archived: row?.Archived == true);
    }

    /// The pane shows "No Chat Open" with no chat in it (the chat-keys walk checks it).
    internal bool PaneEmpty => _openChat == null && ContentPlaceholder.Visibility == Visibility.Visible && ChatPage.Current == null;

    /// [groups] The sidebar's rows top to bottom as the group chats walk reads them (`WalkProof.SidebarGroupChats`).
    internal IReadOnlyList<string> SidebarKeys() => Sidebar.ItemsSource is List<ListViewItem> rows
        ? [.. rows.Select(r => r.Tag switch
        {
            SidebarHeader h => "header:" + h.Title,
            SidebarDivider => "divider",
            SidebarBot b => b.Bot.Id,
            SidebarRoom room => Hermes.Core.Bots.BotListHead.RoomKey(room.Room.Id),
            _ => "",
        })]
        : [];

    /// The key of the row the sidebar marks (null: none).
    /// [WIN-49] The sidebar's chosen row (the walk measures its mark).
    internal ListViewItem? MarkedRow => Sidebar.SelectedItem as ListViewItem;
    internal object? SidebarResource(string key) => Sidebar.Resources.TryGetValue(key, out var value) ? value : null;

    internal string? MarkedKey => (Sidebar.SelectedItem as ListViewItem)?.Tag is SidebarItem item ? KeyOf(item) : null;

    /// The sidebar's list (the chat-keys walk checks it has the keyboard after a close).
    internal ListView SidebarList => Sidebar;
    /// [WIN-FOOTER-GATEWAY-CLIP] The foot's gear and the gateway's line, for the text-scale walk.
    internal Button FootSettingsButton => SettingsButton;
    internal FrameworkElement FootGateway => GatewayFootHost;

    /// The text-scale walk's narrowest sidebar: the open sidebar drawn `width` wide for now (never saved), or as kept
    /// again with null.
    internal void ShowOpenWidthForWalk(double? width)
    {
        if (width is { } w && !Rail) SidebarColumn.Width = new GridLength(SidebarLayout.ClampOpen(w, ActualWidth));
        else ApplyWidth();
    }

    /// The sidebar foot's menu (the account button's), for the CI's walks (Services/ProofWalks.Windows.cs).
    internal MenuFlyout AccountMenuFlyout => AccountMenu;

    /// Ctrl+W, the Mac's ⌘W (`hqCloseChat` / `MacWorkspaceBar.closeActiveTab`): closes the active workspace tab,
    /// selecting its neighbor (right → left) when another tab is open, or emptying the pane to "No Chat Open" with
    /// focus in the sidebar when the last tab closes. During automation walks (`chat-keys`, `new-chat-here`), empties
    /// the pane directly so existing proof checks observe `PaneEmpty`.
    internal void CloseChat()
    {
        if (!ChatKeys.CanCloseChat(KeyState())) return;
        AppLog.Note("keys", "close chat");
        var activeId = ActiveWorkspaceTabId();
        if (activeId != null)
        {
            var (removed, next) = _tabList.Close(activeId, activeId);
            if (removed)
            {
                PersistWorkspaceTabs();
                _closingTabId = activeId;
                if (!Automation.Enabled && next != null)
                {
                    ActivateWorkspaceTab(next);
                    return;
                }
            }
        }
        ClosePane();
    }

    /// The pane empty, "No Chat Open" in it, no sidebar row marked, the sidebar focused (the Mac pops to its list).
    private void ClosePane()
    {
        EndWaking(null);
        _openChat = null;
        _fromSessions = false;
        _botsChat = null;
        _openIsBotChat = false;
        _openKey = null;
        if (_listHidden)
        {
            _listHidden = false;
            ApplyWidth();
        }
        if (_hub != null)
        {
            _hub.Bots.VisibleBot = null;
            _hub.Sessions.Selected = null;
        }
        Mark(null);
        App.Window?.DismissToolTips();
        ContentFrame.Navigate(typeof(EmptyPane), null, new SuppressNavigationTransitionInfo());   // the chat page lets go of its chat
        ContentFrame.BackStack.Clear();
        PlaceholderTitle.Text = "No Chat Open";
        PlaceholderText.Text = "Choose a bot to open its chat.";
        ContentPlaceholder.Visibility = Visibility.Visible;
        SyncWorkspaceBar();
        Sidebar.Focus(FocusState.Keyboard);
        App.Window?.DismissToolTips();
    }

    /// Ctrl+Alt+N, the Mac's ⌥⌘N (`hqNewChatHere`, `SessionsOrganizer.newChat(like:)`): a new chat with the open chat's
    /// bot, in the project holding its folder; it opens in the pane as New Chat's does. The folder is the open chat's live
    /// one, as the Mac's `chat.workingDirectory` (`Hermes.Core.Shell.NewChatHere`): a bot's own chat has no list row.
    internal void NewChatHere()
    {
        var state = KeyState();
        if (_hub == null || !ChatKeys.CanNewChatHere(state)) return;
        var live = ChatPage.Current is { } page && page.StoredId == state.StoredId ? page.LiveCwd : null;
        var row = _hub.Sessions.Row(state.Profile ?? "", state.StoredId ?? "")?.Cwd;
        if (Hermes.Core.Shell.NewChatHere.Plan(state, live, row, _hub.Sessions.ProjectsByProfile) is not { } start) return;
        AppLog.Note("keys", "new chat here");
        _ = NewChatWithAsync(start.Profile, start.Folder);
    }

    /// Ctrl+Alt+A, the Mac's ⌃⌘A (`hqArchiveChat`): the chat's own ⋯ › Archive (or Unarchive) through the sidebar's own
    /// call (`SessionStore.SetArchivedAsync`), no question first. Archived: the chat leaves the pane and the lists,
    /// "Archived “title”" with the way back and Undo shows, the sidebar has the keyboard. A failure is the ⋯ menu's alert.
    internal async Task ArchiveChatAsync()
    {
        var step = ChatKeys.Archive(KeyState());
        if (step == ArchiveStep.None || _hub == null || _openChat is not { } chat || _archiving) return;
        AppLog.Note("keys", step == ArchiveStep.Archive ? "archive chat" : "unarchive chat");
        var store = _hub.Sessions;
        var title = ChatPage.Current is { } page && page.StoredId == chat.StoredId ? page.ChatTitle : chat.Title;
        var s = new SessionSummary { Id = chat.StoredId, Profile = chat.Profile, Title = title ?? "", Archived = step == ArchiveStep.Unarchive };
        var archived = step == ArchiveStep.Archive;
        _archiving = true;
        bool done;
        try { done = await Prompts.RunAsync(XamlRoot, ChatKeys.FailureTitle(step), () => store.SetArchivedAsync(s, archived)); }
        finally { _archiving = false; }
        if (!done || !archived) return;
        var archivedTabId = $"session:{chat.Profile}:{chat.StoredId}";
        if (_tabList.Close(archivedTabId, ActiveWorkspaceTabId()).Removed) PersistWorkspaceTabs();
        if (_openChat?.StoredId == chat.StoredId && _openChat.Profile == chat.Profile) ClosePane();
        UndoPill.Show(PillHost, ChatKeys.ArchivedLabel(title), SessionStore.ArchivedWayBack,
            HermesHQ.Features.Sessions.ArchiveUndoRoute.For(() => XamlRoot, store, s));   // [WIN-ARCHIVE-UNDO]
        await KeepKeyboardInSidebarAsync();
    }

    /// [WIN-RAIL-TOOLS-FIT] The message box of the page in the pane (a chat's `ComposerBox`), which the Undo pill stands
    /// above as the Mac's stands above `ChatViewController.composer` (UndoPill.swift `shownPane`); none on other pages.
    private FrameworkElement? _messageBox;

    private void WatchMessageBox(object? content)
    {
        if (_messageBox != null) _messageBox.SizeChanged -= MessageBoxMoved;
        _messageBox = (content as FrameworkElement)?.FindName("ComposerBox") as FrameworkElement;
        if (_messageBox != null) _messageBox.SizeChanged += MessageBoxMoved;
        LiftPill();
    }

    private void MessageBoxMoved(object sender, SizeChangedEventArgs e) => LiftPill();

    /// 8 above the pane's foot, or 8 above the message box (`UndoPillPlacement.Lift`); the pill's own margin is 6.
    private void LiftPill()
    {
        double? top = null;
        if (_messageBox is { IsLoaded: true, ActualHeight: > 0 } box && box.Visibility == Visibility.Visible
            && ContentPlaceholder.Visibility != Visibility.Visible)
        {
            try { top = box.TransformToVisual(PaneGrid).TransformPoint(new Windows.Foundation.Point(0, 0)).Y; }
            catch (ArgumentException) { }   // not in the pane's tree any more
        }
        PillHost.Margin = new Thickness(UndoPillPlacement.Inset - 6, 0, UndoPillPlacement.Inset - 6,
            Math.Max(0, UndoPillPlacement.Lift(PaneGrid.ActualHeight, top) - 6));
    }

    /// The chat page holding the keyboard goes after ClosePane has focused the sidebar, and WinUI's fallback can then hand
    /// the keyboard to the pill's Undo: its focus hold (Narrator's, the Mac's VoiceOver) kept the pill up for good (CI run
    /// 45029354385, "the Undo pill is held (VoiceOver)"). Once the page has gone, a keyboard that fell to the pill, or
    /// to nothing, goes back to the sidebar, as the Mac's does; one moved there on purpose later still holds the pill.
    private async Task KeepKeyboardInSidebarAsync()
    {
        foreach (var wait in new[] { 0, 250 })
        {
            await Task.Delay(wait);
            await Task.Yield();
            if (XamlRoot == null) return;
            var focused = Microsoft.UI.Xaml.Input.FocusManager.GetFocusedElement(XamlRoot) as DependencyObject;
            var inPill = focused != null && UndoPill.Current is { } pill && Inside(focused, pill);
            if (focused != null && !inPill) continue;
            var back = Sidebar.Focus(FocusState.Keyboard);
            AppLog.Note("keys", $"archive chat: the keyboard fell to {(inPill ? "the Undo pill" : "nothing")}; to the sidebar: {back}");
        }
    }

    private static bool Inside(DependencyObject element, DependencyObject ancestor)
    {
        for (var at = element; at != null; at = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(at))
            if (ReferenceEquals(at, ancestor)) return true;
        return false;
    }

    private async void SignOut_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            if (ShellExtensions.SignOut is { } signOut) { await signOut(XamlRoot); return; }
            var confirm = new ContentDialog
            {
                Title = "Sign out of Hermes?",
                Content = "Your chats stay on your gateway. This PC forgets the sign-in and its cached chats.",
                PrimaryButtonText = "Sign out",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Close,
            };
            if (await SafeDialog.ShowAsync(XamlRoot, confirm) != ContentDialogResult.Primary) return;
            _hub?.Stop();
            await AppState.SignOutAsync();
            App.Window?.ShowSignIn();
        }
        catch (Exception ex) { AppLog.Error("shell", ex); }
    }

    // ------------------------------------------------------------------ Workspace tab bar & navigation history

    private string? ActiveWorkspaceTabId()
    {
        if (_openChat is not { } chat) return null;
        return _openIsBotChat ? $"bot:{chat.Profile}" : $"session:{chat.Profile}:{chat.StoredId}";
    }

    private void PersistWorkspaceTabs()
    {
        if (Automation.Enabled || _client == null) return;
        _tabList.Save(_client.AccountId, FilePreferences.Shared);
    }

    private void RecordWorkspaceOpen(WorkspaceTabRecord record, WorkspaceNavDestination nav)
    {
        if (record.TabId != _closingTabId)
        {
            _closingTabId = null;
            if (_tabList.Open(record)) PersistWorkspaceTabs();
        }
        if (!_navigatingHistory) _history.Record(nav);
        SyncWorkspaceBar();
    }

    private void SyncWorkspaceBar()
    {
        if (_detached || AppShutdown.Stopping) return;
        var activeId = ActiveWorkspaceTabId();
        var sessions = _hub?.Sessions.LiveSummaries();
        var tabsChanged = false;
        var items = new List<WorkspaceBarTab>(_tabList.Tabs.Count);

        foreach (var record in _tabList.Tabs)
        {
            var title = record.Title;
            var working = false;
            var unread = false;
            if (record.Kind == WorkspaceTabKind.Session)
            {
                var summary = sessions?.FirstOrDefault(s => s.Id == record.Id && s.Profile == record.Profile)
                    ?? sessions?.FirstOrDefault(s => s.Id == record.Id);
                if (summary != null)
                {
                    if (!string.IsNullOrWhiteSpace(summary.Title))
                    {
                        title = summary.Title;
                        if (_tabList.UpdateTitle(record.TabId, title)) tabsChanged = true;
                    }
                    working = summary.IsRunning || summary.Status == SessionStatus.Working;
                    unread = summary.Unread;
                }
            }
            else if (_hub?.Bots.Bot(record.Id) is { } bot)
            {
                if (!string.IsNullOrWhiteSpace(bot.Name))
                {
                    title = bot.Name;
                    if (_tabList.UpdateTitle(record.TabId, title)) tabsChanged = true;
                }
                working = bot.IsWorking;
                unread = BotList.ShowsUnread(bot);
            }

            items.Add(new WorkspaceBarTab(
                record.TabId,
                record.Kind,
                record.Profile,
                record.Id,
                string.IsNullOrWhiteSpace(title) ? "Chat" : title,
                IsActive: string.Equals(activeId, record.TabId, StringComparison.Ordinal),
                IsWorking: working,
                IsUnread: unread));
        }

        if (tabsChanged) PersistWorkspaceTabs();
        _workspaceBar.Update(items, _history.CanGoBack, _history.CanGoForward, CanToggleList, _listHidden);
    }

    /// Window › Show Next Tab / Show Previous Tab (`Ctrl+Tab`, `Ctrl+Shift+Tab`, `Ctrl+Shift+[`, `Ctrl+Shift+]`,
    /// `f451f7fd4`): cycles open workspace tabs, yielding to Terminal when Terminal is active.
    private bool CycleWorkspaceTabs(int step)
    {
        if (_openKey == "place:terminal" || ContentFrame.Content is HermesHQ.Features.Workspace.TerminalPage)
            return false;
        var tabs = _tabList.Tabs;
        var activeId = ActiveWorkspaceTabId();
        int? activeIdx = null;
        if (activeId != null)
        {
            for (var i = 0; i < tabs.Count; i++)
            {
                if (tabs[i].TabId == activeId) { activeIdx = i; break; }
            }
        }
        if (WorkspaceTabList.CycledIndex(tabs.Count, activeIdx, step) is not { } nextIdx)
            return false;
        ActivateWorkspaceTab(tabs[nextIdx]);
        return true;
    }

    private void ActivateWorkspaceBarTab(WorkspaceBarTab tab) =>
        ActivateWorkspaceTab(new WorkspaceTabRecord(tab.Kind, tab.Profile, tab.Id, tab.Title));

    private void ActivateWorkspaceTab(WorkspaceTabRecord record)
    {
        if (record.Kind == WorkspaceTabKind.Bot)
        {
            if (_hub?.Bots.Bot(record.Id) is { } bot)
            {
                Navigator.Go(new BotChatDestination(bot.Model));
                return;
            }
            var fallback = _hub?.Bots.Layout.Flat.FirstOrDefault(b => b.Id == record.Id)?.Model;
            if (fallback != null) { Navigator.Go(new BotChatDestination(fallback)); return; }
        }
        Navigator.Go(new ChatDestination(record.Profile, record.Id, record.Title));
    }

    private void CloseWorkspaceTab(string tabId)
    {
        var activeId = ActiveWorkspaceTabId();
        var (removed, next) = _tabList.Close(tabId, activeId);
        if (!removed) return;
        PersistWorkspaceTabs();
        if (WorkspaceTabList.ClosingGuardId(new HashSet<string>(StringComparer.Ordinal) { tabId }, activeId) is { } guard)
        {
            _closingTabId = guard;
            if (next != null) { ActivateWorkspaceTab(next); return; }
            ClosePane();
            return;
        }
        SyncWorkspaceBar();
    }

    private void CloseOtherWorkspaceTabs(string keepingTabId)
    {
        var activeId = ActiveWorkspaceTabId();
        var beforeIds = _tabList.Tabs.Select(t => t.TabId).ToHashSet(StringComparer.Ordinal);
        if (!_tabList.CloseOthers(keepingTabId)) return;
        PersistWorkspaceTabs();
        beforeIds.ExceptWith(_tabList.Tabs.Select(t => t.TabId));
        if (WorkspaceTabList.ClosingGuardId(beforeIds, activeId) is { } guard)
            _closingTabId = guard;
        if (activeId != keepingTabId && _tabList.Tabs.FirstOrDefault(t => t.TabId == keepingTabId) is { } kept)
        {
            ActivateWorkspaceTab(kept);
            return;
        }
        SyncWorkspaceBar();
    }

    private void CloseWorkspaceTabsToRight(string tabId)
    {
        var activeId = ActiveWorkspaceTabId();
        var beforeIds = _tabList.Tabs.Select(t => t.TabId).ToHashSet(StringComparer.Ordinal);
        if (!_tabList.CloseToRight(tabId)) return;
        PersistWorkspaceTabs();
        beforeIds.ExceptWith(_tabList.Tabs.Select(t => t.TabId));
        if (WorkspaceTabList.ClosingGuardId(beforeIds, activeId) is { } guard)
        {
            _closingTabId = guard;
            if (_tabList.Tabs.FirstOrDefault(t => t.TabId == tabId) is { } anchor)
            {
                ActivateWorkspaceTab(anchor);
                return;
            }
        }
        SyncWorkspaceBar();
    }

    private void CloseAllWorkspaceTabs()
    {
        var activeId = ActiveWorkspaceTabId();
        var beforeIds = _tabList.Tabs.Select(t => t.TabId).ToHashSet(StringComparer.Ordinal);
        if (!_tabList.CloseAll()) return;
        PersistWorkspaceTabs();
        if (WorkspaceTabList.ClosingGuardId(beforeIds, activeId) is { } guard)
        {
            _closingTabId = guard;
            ClosePane();
            return;
        }
        SyncWorkspaceBar();
    }

    private void GoWorkspaceBack()
    {
        if (_history.GoBack() is not { } target) return;
        NavigateHistoryTo(target);
    }

    private void GoWorkspaceForward()
    {
        if (_history.GoForward() is not { } target) return;
        NavigateHistoryTo(target);
    }

    private void NavigateHistoryTo(WorkspaceNavDestination target)
    {
        _navigatingHistory = true;
        try
        {
            switch (target)
            {
                case WorkspaceBotNav bot:
                    if (_hub?.Bots.Bot(bot.BotId) is { } found) Navigator.Go(new BotChatDestination(found.Model));
                    break;
                case WorkspaceSessionNav session:
                    var title = _tabList.Tabs.FirstOrDefault(t => t.TabId == session.TabId)?.Title
                        ?? _hub?.Sessions.LiveSummaries().FirstOrDefault(s => s.Id == session.SessionId)?.Title
                        ?? "Chat";
                    Navigator.Go(new ChatDestination(session.Profile, session.SessionId, title));
                    break;
                case WorkspaceRoomNav room:
                    Navigator.Go(new RoomDestination(room.RoomKey));
                    break;
                case WorkspacePlaceNav place:
                    Navigator.Open(place.PlaceId, place.Argument);
                    break;
            }
        }
        finally
        {
            _navigatingHistory = false;
            SyncWorkspaceBar();
        }
    }

    // ------------------------------------------------------------------ Open Quickly (Ctrl+K and the sidebar's Search)

    /// Open Quickly (App/Mac/MacOpenQuickly.swift): New Chat and New Bot results run as Ctrl+N and the sidebar's row do.
    /// It searches what the old sidebar field did (Go To, Bots, Sessions, Settings, Actions), in More's groups.
    private void ShowOpenQuickly() => OpenQuicklyPanel.Show(XamlRoot, _hub, new OpenQuicklyPanel.ShellActions(
        () => NewChat_Click(this, new RoutedEventArgs()), () => _ = _actions?.NewBotAsync()));
}
