using System.Text;
using Hermes.Core.Gateways;
using Hermes.Core.Terminal;
using HermesHQ.Features.Attachments;
using HermesHQ.Features.Transcript;
using HermesHQ.Services;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using Windows.ApplicationModel.DataTransfer;
using Windows.Security.Credentials.UI;
using VirtualKey = Windows.System.VirtualKey;

namespace HermesHQ.Features.Workspace;

/// The Terminal page (docs/spec/terminal.md, App/Terminal/TerminalViewController.swift): a shell on the Hermes computer,
/// typed into from here. Opening it the first time for a computer asks whether to turn it on (Not Now leaves it off),
/// then Windows Hello each time (the Mac's Touch ID or password), then the add-on is asked whether it has the Terminal
/// (hermes-hq-push 0.9.25+) before the sockets dial. Tabs: + (Ctrl+Shift+T) opens another shell, up to 8; a strip of
/// tabs shows once there are two. Leaving the page keeps the shells 15 minutes on the computer; ⋯ › End Shell ends one,
/// New Shell starts another. Copy: a click-drag and Ctrl+C, ⋯ › Copy All, ⋯ › Select Text…, and programs (OSC 52).
/// Paste: Ctrl+V or ⋯ › Paste; several lines ask first unless the shell has bracketed paste on.
[Microsoft.UI.Xaml.Data.Bindable]
public sealed class TerminalPage : Page
{
    private abstract record State
    {
        public sealed record Asking : State;
        public sealed record Consent : State;
        public sealed record Off : State;
        public sealed record Locked(string? Why) : State;
        public sealed record Checking : State;
        public sealed record NeedsAddOn : State;
        public sealed record Connection(TerminalConnection.Phase Phase) : State;
    }

    private sealed class Tab(string session, string customName)
    {
        public string Session = session;
        public string CustomName = customName;
        public readonly TerminalView View = new();
        public TerminalConnection? Connection;
        public TerminalConnection.Phase? Phase;
        /// The program's title (OSC 0/2) or the shell's name: "1 zsh", "2 vim".
        public string? Name;
        public bool EndedHere, NewAfterEnd, Closing;
        /// Single-line initial command waiting to run once this tab's fresh shell is live.
        public string? PendingCommand;
        public CancellationTokenSource? CommandCts;
        public bool SawOutput;
        public bool Resumed;
    }

    private static WeakReference<TerminalPage>? _active;

    /// Strips surrounding whitespace and rejects empty or multi-line input (`\n`, `\r`, `\0`) so an initial command
    /// never injects extra lines (`TerminalViewController.sanitizeInitialCommand`, `7b264e66d`).
    public static string? SanitizeInitialCommand(string? command) =>
        Hermes.Core.Chat.ModelFallbackRow.DetailModel.SanitizeInitialCommand(command);

    /// Opens the Terminal (or a fresh tab if already open) and runs `command + "\r"` once the shell is ready.
    public static void OpenWithCommand(string command)
    {
        var clean = SanitizeInitialCommand(command);
        if (clean == null) return;
        if (_active?.TryGetTarget(out var page) == true && !page._navigatedOut && page.ShellsOpen)
        {
            page._ui?.TryEnqueue(() => page.OpenFreshTabWithCommand(clean));
            return;
        }
        HermesHQ.Shell.Navigator.Open("terminal", clean);
    }

    private readonly TerminalSettings _settings = new(FilePreferences.Shared);
    private readonly List<Tab> _tabs = [];
    private int _current;
    private string _account = "";
    private DispatcherQueue _ui = null!;
    private State _state = new State.Asking();
    private bool _updateAsked, _relocked, _unlocking;
    private string? _relockWhy;
    private string? _pendingCommand;
    private bool _hadAllowedAtInit;

    private readonly Grid _root = new() { Background = TerminalView.Panel };
    private readonly TextBlock _title = W.Text("Terminal", 17, bold: true);
    private readonly TextBlock _subtitle = W.Text("", 12);
    private readonly Button _add = W.BarButton("", "New Tab", "terminal.newTab");
    private readonly Button _more = W.BarButton("", "More", "terminal.more");
    private readonly StackPanel _strip = new() { Orientation = Orientation.Horizontal, Spacing = 4, Padding = new Thickness(8, 4, 8, 4) };
    private readonly Grid _screens = new();
    private readonly ContentControl _notice = new() { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private readonly Border _banner = new()
    {
        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 8, 0, 0),
        Padding = new Thickness(14, 6, 14, 6), CornerRadius = new CornerRadius(14), Visibility = Visibility.Collapsed,
        Background = new SolidColorBrush(Windows.UI.Color.FromArgb(230, 50, 52, 58)),
    };
    private readonly Border _pill = new()
    {
        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 24),
        Padding = new Thickness(16, 8, 16, 8), CornerRadius = new CornerRadius(16), Visibility = Visibility.Collapsed,
        Background = new SolidColorBrush(Windows.UI.Color.FromArgb(235, 60, 62, 68)),
    };

    private static readonly Brush White = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 255, 255, 255));
    private static readonly Brush Grey = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 184, 184, 184));

    public TerminalPage()
    {
        NavigationCacheMode = NavigationCacheMode.Disabled;
        Content = _root;
        RequestedTheme = ElementTheme.Dark;   // a dark panel in every look
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        // [WIN-50] The Mac's page bar (MacWindow.pageBar, Shell/PageBar.cs): the page-title token and the page's side.
        HermesHQ.Shell.PageBar.Title(_title, "terminal");
        var bar = new Grid { Padding = HermesHQ.Shell.PageBar.Padding(10, 6) };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var heading = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        _title.Foreground = White;
        _subtitle.Foreground = Grey;
        AutomationProperties.SetAutomationId(_subtitle, "terminal.subtitle");
        heading.Children.Add(_title);
        heading.Children.Add(_subtitle);
        bar.Children.Add(heading);
        var tools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        _add.Click += (_, _) => NewTab();
        var menu = new MenuFlyout { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedRight };
        menu.Opening += (_, _) => FillMenu(menu);
        _more.Flyout = menu;
        tools.Children.Add(_add);
        tools.Children.Add(_more);
        Grid.SetColumn(tools, 1);
        bar.Children.Add(tools);
        _root.Children.Add(bar);

        AutomationProperties.SetAutomationId(_strip, "terminal.tabs");
        Grid.SetRow(_strip, 1);
        _root.Children.Add(_strip);

        var panel = new Grid();
        panel.Children.Add(_screens);
        panel.Children.Add(_notice);
        _banner.Child = new TextBlock { Text = TerminalWords.Reconnecting, Foreground = White, FontSize = 13 };
        AutomationProperties.SetAutomationId(_banner, "terminal.banner");
        panel.Children.Add(_banner);
        AutomationProperties.SetAutomationId(_pill, "terminal.pill");
        panel.Children.Add(_pill);
        Grid.SetRow(panel, 2);
        _root.Children.Add(panel);
        AutomationProperties.SetAutomationId(_notice, "terminal.notice");
        PreviewKeyDown += OnKey;
    }

    private string Computer => TerminalWords.ComputerName(HostWord.GatewayName);
    private Tab Front => _tabs[_current];
    private bool ShellsOpen => _state is State.Connection && !_relocked;
    private bool IsLive => _state is State.Connection { Phase: TerminalConnection.Phase.Live } && !_relocked;

    // MARK: The page coming and going

    private bool _navigatedOut;

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _navigatedOut = false;
        _active = new WeakReference<TerminalPage>(this);
        _ui = DispatcherQueue.GetForCurrentThread();
        if (AppState.Client is not { } client) return;
        _account = client.AccountId;
        var initialArg = (e.Parameter as HermesHQ.Shell.PlaceArgs)?.Argument as string ?? e.Parameter as string;
        _pendingCommand = SanitizeInitialCommand(initialArg);
        _hadAllowedAtInit = _settings.Allowed(_account);
        var names = _settings.TabNames(_account);
        var sessions = _settings.Sessions(_account);
        for (var i = 0; i < sessions.Count; i++) Install(new Tab(sessions[i], i < names.Count ? names[i] : ""));
        _current = Math.Clamp(_settings.SelectedTab(_account), 0, _tabs.Count - 1);
        ShowTabs();
        ApplyFont();
        if (App.Window is { } window) window.VisibilityChanged += OnWindowVisibility;
        try { await OpenAsync(); }
        catch (Exception ex) { AppLog.Error("terminal", ex); }
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        _navigatedOut = true;
        if (_active?.TryGetTarget(out var current) == true && ReferenceEquals(current, this)) _active = null;
        if (App.Window is { } window) window.VisibilityChanged -= OnWindowVisibility;
        // The sockets close; the shells stay on the computer for 15 minutes.
        foreach (var tab in _tabs)
        {
            CancelCommandTask(tab);
            tab.Connection?.Stop();
            tab.Connection = null;
        }
    }

    // MARK: Opening

    /// The first-time question, Windows Hello, the add-on, then the sockets.
    private async Task OpenAsync()
    {
        SetState(new State.Asking());
        if (!_settings.Allowed(_account)) { SetState(new State.Consent()); return; }
        switch (await TerminalUnlock.UnlockAsync(_settings.RequiresUnlock))
        {
            case TerminalUnlock.Answer.Refused: if (!_navigatedOut) SetState(new State.Locked(null)); return;
            case TerminalUnlock.Answer.Unavailable: if (!_navigatedOut) SetState(new State.Locked(TerminalWords.CantCheck)); return;
        }
        if (_navigatedOut || AppShutdown.Stopping) return;
        await CheckAndConnectAsync();
    }

    private async Task CheckAndConnectAsync()
    {
        if (_navigatedOut || AppShutdown.Stopping || AppState.Client is not { } client) return;
        SetState(new State.Checking());
        int status;
        System.Text.Json.Nodes.JsonNode? body = null;
        try
        {
            var a = await client.Session.SendAsync(HttpMethod.Get, TerminalWire.Route + "/status");
            status = a.Status;
            if (a.Ok) body = a.Json ?? new System.Text.Json.Nodes.JsonObject();
        }
        catch (Exception) { status = 0; }
        if (_navigatedOut || AppShutdown.Stopping) return;
        var addOn = TerminalWire.AddOnFrom(status, body);
        AppLog.Note("terminal", $"add-on says {addOn} (status {status})");
        switch (addOn)
        {
            case TerminalWire.AddOn.NeedsUpdate: SetState(new State.NeedsAddOn()); break;
            case TerminalWire.AddOn.Unsupported: SetState(new State.Connection(new TerminalConnection.Phase.Stopped(new(TerminalWire.EndingKind.Unsupported)))); break;
            case TerminalWire.AddOn.Off: SetState(new State.Connection(new TerminalConnection.Phase.Stopped(new(TerminalWire.EndingKind.Off)))); break;
            default:
                PreparePendingCommand();
                foreach (var tab in _tabs) Connect(tab);
                break;   // can't tell: the socket says itself
        }
    }

    /// Assigns `_pendingCommand` to a brand-new shell tab (or the unused first tab on first-time setup) so an existing
    /// shell is never clobbered. When all `MaxTabs` tabs are already open, keeps `_pendingCommand` to confirm once live.
    private void PreparePendingCommand()
    {
        if (_pendingCommand is not { } command) return;
        if (!_hadAllowedAtInit && _tabs.Count == 1)
        {
            _tabs[0].PendingCommand = command;
            _pendingCommand = null;
            return;
        }
        if (_tabs.Count >= TerminalSettings.MaxTabs) return;
        var tab = new Tab(TerminalWire.NewSession(), "") { PendingCommand = command };
        Install(tab);
        ApplyFont();
        _current = _tabs.Count - 1;
        SaveTabs();
        ShowTabs();
        _pendingCommand = null;
        AppLog.Note("terminal", $"new tab for initial command ({_tabs.Count} open)");
    }

    private void OpenFreshTabWithCommand(string command)
    {
        if (_tabs.Count >= TerminalSettings.MaxTabs)
        {
            if (IsLive) _ = ConfirmOverflowCommandAsync(command, Front);
            else _pendingCommand = command;
            return;
        }
        var tab = new Tab(TerminalWire.NewSession(), "") { PendingCommand = command };
        Install(tab);
        ApplyFont();
        Select(_tabs.Count - 1);
        _ui.TryEnqueue(DispatcherQueuePriority.Low, () => Connect(tab));
    }

    private void TurnOn()
    {
        if (_state is not (State.Consent or State.Off)) return;
        _settings.SetAllowed(true, _account);
        AppLog.Note("terminal", "turned on for this computer");
        _ = OpenAsync();
    }

    private void NotNow()
    {
        if (_state is State.Consent) SetState(new State.Off());
    }

    private void Connect(Tab tab)
    {
        if (AppState.Client is not { } client) return;
        CancelCommandTask(tab);
        tab.SawOutput = false;
        tab.Resumed = false;
        tab.Connection?.Stop();
        tab.EndedHere = false;
        var dial = TerminalDialer.For(client.Session);
        var connection = new TerminalConnection(tab.Session, (q, ct) => dial(q, ct));
        connection.Output += data => _ui.TryEnqueue(() =>
        {
            tab.View.Screen.Feed(data);
            if (data.Length > 0) NoteOutput(tab);
        });
        connection.Reset += () => _ui.TryEnqueue(() =>
        {
            tab.Resumed = true;
            tab.View.Clear();
        });
        connection.PhaseChanged += phase => _ui.TryEnqueue(() => PhaseChanged(phase, tab, connection));
        connection.Trace += line => AppLog.Note("terminal", line);
        tab.Connection = connection;
        tab.Phase = new TerminalConnection.Phase.Connecting();
        if (tab == Front) SetState(new State.Connection(tab.Phase));
        var (cols, rows) = tab.View.Cells;
        connection.Start(cols, rows);
    }

    private void PhaseChanged(TerminalConnection.Phase phase, Tab tab, TerminalConnection from)
    {
        if (tab.Connection != from) return;
        AppLog.Note("terminal", $"phase {phase.GetType().Name.ToLowerInvariant()} (tab {_tabs.IndexOf(tab) + 1} of {_tabs.Count})");
        if (phase is TerminalConnection.Phase.Live && from.Shell.Length > 0 && tab.View.Screen.Title.Length == 0) tab.Name = from.Shell;
        if (phase is TerminalConnection.Phase.Ended)
        {
            CancelCommandTask(tab);
            tab.PendingCommand = null;
            // The next open starts a fresh shell rather than dialling one that's gone.
            tab.Session = TerminalWire.NewSession();
            SaveTabs();
            if (tab.Closing) { Remove(tab); return; }
            if (tab.NewAfterEnd)
            {
                tab.NewAfterEnd = false;
                tab.View.Clear();
                Connect(tab);
                return;
            }
        }
        else if (phase is TerminalConnection.Phase.Stopped)
        {
            CancelCommandTask(tab);
            tab.PendingCommand = null;
        }
        tab.Phase = phase;
        FillStrip();
        if (phase is TerminalConnection.Phase.Live)
        {
            if (tab.PendingCommand is { } command)
            {
                if (tab.Resumed || from.Shown > 0)
                {
                    tab.PendingCommand = null;
                    if (tab == Front) _ = ConfirmOverflowCommandAsync(command, tab);
                }
                else
                {
                    SchedulePendingCommand(tab);
                }
            }
            else if (tab == Front && _pendingCommand is { } overflow)
            {
                _pendingCommand = null;
                _ = ConfirmOverflowCommandAsync(overflow, tab);
            }
        }
        if (tab != Front) return;
        SetState(new State.Connection(phase));
        if (phase is TerminalConnection.Phase.Live && !_relocked) tab.View.Focus(FocusState.Programmatic);
    }

    private static void CancelCommandTask(Tab tab)
    {
        var cts = tab.CommandCts;
        tab.CommandCts = null;
        if (cts != null)
        {
            try { cts.Cancel(); } catch (ObjectDisposedException) { }
            cts.Dispose();
        }
    }

    private void NoteOutput(Tab tab)
    {
        if (tab.PendingCommand == null || tab.SawOutput) return;
        tab.SawOutput = true;
        if (tab.Phase is TerminalConnection.Phase.Live) SchedulePendingCommand(tab);
    }

    /// Waits briefly for the fresh shell's initial prompt (120 ms after output, 800 ms fallback) before sending command + `\r`.
    private void SchedulePendingCommand(Tab tab)
    {
        if (tab.PendingCommand == null || tab.Phase is not TerminalConnection.Phase.Live || _relocked) return;
        CancelCommandTask(tab);
        var delay = tab.SawOutput ? 120 : 800;
        var cts = new CancellationTokenSource();
        tab.CommandCts = cts;
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(delay, cts.Token);
                if (!cts.Token.IsCancellationRequested && !_navigatedOut)
                    _ui.TryEnqueue(() => RunPendingCommand(tab));
            }
            catch (OperationCanceledException) { }
        });
    }

    private void RunPendingCommand(Tab tab)
    {
        if (tab.Phase is not TerminalConnection.Phase.Live || _relocked || tab.PendingCommand is not { } command) return;
        tab.PendingCommand = null;
        CancelCommandTask(tab);
        tab.Connection?.Send(Encoding.UTF8.GetBytes(command + "\r"));
        AppLog.Note("terminal", "ran initial command");
    }

    private async Task ConfirmOverflowCommandAsync(string command, Tab tab)
    {
        if (XamlRoot == null || _navigatedOut) return;
        var dialog = new ContentDialog
        {
            Title = "Run in Current Tab?",
            Content = new TextBlock
            {
                Text = $"All {TerminalSettings.MaxTabs} terminal tabs are open. Run “{command}” in this tab, or copy it to paste into an idle shell.",
                TextWrapping = TextWrapping.Wrap,
            },
            PrimaryButtonText = "Run Here",
            SecondaryButtonText = "Copy Command",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        var answer = await SafeDialog.ShowAsync(XamlRoot, dialog);
        if (answer == ContentDialogResult.Primary)
            tab.Connection?.Send(Encoding.UTF8.GetBytes(command + "\r"));
        else if (answer == ContentDialogResult.Secondary)
        {
            SafeClipboard.TrySetText(command);
            Pill("Copied");
        }
        FocusShell();
    }

    // MARK: Tabs

    private void Install(Tab tab)
    {
        _tabs.Add(tab);
        tab.View.Typed += data => { if (IsLive || tab != Front) tab.Connection?.Send(data); };
        tab.View.CellsChanged += (cols, rows) => tab.Connection?.Resize(cols, rows);
        tab.View.PasteRequested += () => _ = PasteAsync();
        tab.View.Screen.Respond += data => tab.Connection?.Send(data);
        tab.View.Screen.TitleChanged += title => { tab.Name = title.Length > 0 ? title : tab.Connection?.Shell; FillStrip(); ShowSubtitle(); };
        tab.View.Copied += _ => Pill(tab.View.SelectedText == null ? "Copied by the Shell" : "Copied");
        tab.View.Visibility = Visibility.Collapsed;
        _screens.Children.Add(tab.View);
    }

    private List<string> TabTitles => TerminalSettings.TabTitles([.. _tabs.Select(t => (t.CustomName, t.Name))]);

    private void SaveTabs()
    {
        _settings.SetSessions(_tabs.Select(t => t.Session), _account);
        _settings.SetTabNames(_tabs.Select(t => t.CustomName), _account);
        _settings.SetSelectedTab(_current, _account);
    }

    private void ShowTabs()
    {
        for (var i = 0; i < _tabs.Count; i++)
        {
            _tabs[i].View.Visibility = i == _current ? Visibility.Visible : Visibility.Collapsed;
            AutomationProperties.SetAutomationId(_tabs[i].View, i == _current ? "terminal.screen" : $"terminal.screen.{i + 1}");
        }
        FillStrip();
        ShowSubtitle();
    }

    private void ShowSubtitle() =>
        _subtitle.Text = _relocked || _tabs.Count == 0 ? "" : Front.View.Screen.Title.Length > 0 ? Front.View.Screen.Title : Front.Name ?? "";

    /// The strip of tabs, over the screens once there are two: "1 zsh", "2 vim"; ✕ on the one in front; right-click for
    /// Rename…, Move Left, Move Right, Close Tab.
    private void FillStrip()
    {
        _strip.Children.Clear();
        _strip.Visibility = _tabs.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        if (_tabs.Count <= 1) return;
        var titles = TabTitles;
        for (var i = 0; i < _tabs.Count; i++)
        {
            var index = i;
            var front = i == _current;
            var words = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            words.Children.Add(new TextBlock { Text = titles[i], Foreground = front ? White : Grey, FontSize = 13, FontWeight = front ? FontWeights.SemiBold : FontWeights.Normal, MaxWidth = 180, TextTrimming = TextTrimming.CharacterEllipsis });
            var button = new Button
            {
                Content = words, Padding = new Thickness(12, 4, front ? 6 : 12, 4), CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(0),
                Background = new SolidColorBrush(front ? Windows.UI.Color.FromArgb(255, 58, 60, 66) : Windows.UI.Color.FromArgb(0, 0, 0, 0)),
            };
            if (front)
            {
                var close = new Button { Content = W.Glyph("", 9, Grey), Padding = new Thickness(4), BorderThickness = new Thickness(0), Background = button.Background };
                AutomationProperties.SetName(close, "Close Tab");
                AutomationProperties.SetAutomationId(close, "terminal.tab.close");
                close.Click += (_, _) => _ = CloseTabAsync(index);
                words.Children.Add(close);
            }
            AutomationProperties.SetName(button, titles[i]);
            AutomationProperties.SetAutomationId(button, $"terminal.tab.{i + 1}");
            button.Click += (_, _) => Select(index);
            var menu = new MenuFlyout();
            Add(menu, "Rename…", "", () => _ = RenameTabAsync(index));
            Add(menu, "Move Left", "", () => MoveTab(index, index - 1), index > 0);
            Add(menu, "Move Right", "", () => MoveTab(index, index + 1), index < _tabs.Count - 1);
            menu.Items.Add(new MenuFlyoutSeparator());
            Add(menu, "Close Tab", "", () => _ = CloseTabAsync(index));
            button.ContextFlyout = menu;
            _strip.Children.Add(button);
        }
    }

    private void Select(int index)
    {
        if (index < 0 || index >= _tabs.Count) return;
        if (index != _current)
        {
            _current = index;
            SaveTabs();
        }
        ShowTabs();
        if (ShellsOpen) SetState(new State.Connection(Front.Phase ?? new TerminalConnection.Phase.Connecting()));
        Render();
        if (IsLive) Front.View.Focus(FocusState.Programmatic);
    }

    private void NewTab()
    {
        if (_tabs.Count >= TerminalSettings.MaxTabs || !ShellsOpen) return;
        var tab = new Tab(TerminalWire.NewSession(), "");
        Install(tab);
        ApplyFont();
        AppLog.Note("terminal", $"new tab ({_tabs.Count} open)");
        Select(_tabs.Count - 1);
        // The new screen has its size once it has been laid out.
        _ui.TryEnqueue(DispatcherQueuePriority.Low, () => Connect(tab));
    }

    /// Closing a tab ends its shell (asked first while it runs). The last tab isn't closed: End Shell is.
    private async Task CloseTabAsync(int index)
    {
        if (_tabs.Count <= 1 || index < 0 || index >= _tabs.Count) return;
        var tab = _tabs[index];
        if (tab.Phase is not TerminalConnection.Phase.Live) { Remove(tab); return; }
        var (title, message) = TerminalWords.CloseTabAsk;
        if (!await W.AskAsync(XamlRoot, title, message, "Close Tab", destructive: true)) { FocusShell(); return; }
        tab.Closing = true;
        tab.Connection?.EndShell();
        // The shell's exit closes it; a link that drops first doesn't leave the tab hanging.
        await Task.Delay(3000);
        if (_tabs.Contains(tab)) Remove(tab);
    }

    private void Remove(Tab tab)
    {
        var index = _tabs.IndexOf(tab);
        if (index < 0) return;
        tab.Connection?.Stop();
        tab.Connection = null;
        _screens.Children.Remove(tab.View);
        _tabs.RemoveAt(index);
        if (index < _current || _current >= _tabs.Count) _current = Math.Max(_current - 1, 0);
        SaveTabs();
        AppLog.Note("terminal", $"closed a tab ({_tabs.Count} open)");
        Select(_current);
    }

    private async Task RenameTabAsync(int index)
    {
        if (index < 0 || index >= _tabs.Count) return;
        var tab = _tabs[index];
        var field = new TextBox { Text = tab.CustomName, PlaceholderText = tab.Name ?? $"Shell {index + 1}", MaxLength = 40 };
        AutomationProperties.SetAutomationId(field, "terminal.tab.name");
        var (title, message) = TerminalWords.RenameAsk;
        if (await W.AskAsync(XamlRoot, title, message, "Rename", field: field))
        {
            tab.CustomName = field.Text.Trim() is var t && t.Length > 40 ? t[..40] : field.Text.Trim();
            SaveTabs();
            FillStrip();
            AppLog.Note("terminal", tab.CustomName.Length == 0 ? "tab name cleared" : "tab renamed");
        }
        FocusShell();
    }

    private void MoveTab(int from, int to)
    {
        if (from < 0 || from >= _tabs.Count || to < 0 || to >= _tabs.Count || from == to) return;
        var front = Front;
        var tab = _tabs[from];
        _tabs.RemoveAt(from);
        _tabs.Insert(to, tab);
        _current = _tabs.IndexOf(front);
        SaveTabs();
        ShowTabs();
        AppLog.Note("terminal", $"moved tab {from + 1} to {to + 1}");
    }

    private void Cycle(int step)
    {
        if (_tabs.Count > 1) Select((_current + step + _tabs.Count) % _tabs.Count);
    }

    // MARK: What shows over the panel

    private void SetState(State next)
    {
        if (_state == next) { Render(); return; }
        _state = next;
        Render();
    }

    private FrameworkElement Card(TerminalWords.Card card, Action? action = null, Action? secondary = null)
    {
        var view = W.State(card.Glyph, card.Title, card.Body,
            card.Button != null && action != null ? (card.Button, action) : null,
            card.Secondary != null && secondary != null ? (card.Secondary, secondary) : null, "terminal.card", White, Grey);
        return new Grid
        {
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb((byte)(card.Dim ? 209 : 255), 19, 20, 23)),
            Children = { view },
        };
    }

    private void Render()
    {
        if (_tabs.Count == 0) return;
        FrameworkElement? notice = null;
        var banner = false;
        if (_relocked)
            notice = Card(TerminalWords.LockedAgain(_relockWhy), () => _ = UnlockAgainAsync());
        else switch (_state)
        {
            case State.Asking:
                notice = _settings.RequiresUnlock && _settings.Allowed(_account) ? Card(TerminalWords.Unlock(Computer)) : LoadingCard(TerminalWords.Connecting);
                break;
            case State.Consent:
                notice = Consent();
                break;
            case State.Off:
                notice = Card(TerminalWords.Off(Computer), TurnOn);
                break;
            case State.Locked l:
                notice = Card(TerminalWords.Locked(l.Why), () => _ = OpenAsync());
                break;
            case State.Checking:
                notice = LoadingCard(TerminalWords.Connecting);
                break;
            case State.NeedsAddOn:
                notice = Card(TerminalWords.NeedsAddOn(Computer, _updateAsked), UpdateAddOn);
                break;
            case State.Connection { Phase: var phase }:
                var tab = Front;
                switch (phase)
                {
                    case TerminalConnection.Phase.Connecting: notice = LoadingCard(TerminalWords.Opening); break;
                    case TerminalConnection.Phase.Reconnecting: banner = true; break;
                    case TerminalConnection.Phase.Ended ended:
                        notice = Card(TerminalWords.Ended(ended.Code, tab.EndedHere), () => _ = NewShellAsync(confirm: false));
                        break;
                    case TerminalConnection.Phase.Stopped stopped:
                        notice = Card(TerminalWords.Stopped(stopped.Ending, Computer), () => Connect(tab));
                        break;
                }
                break;
        }
        // Emptied and taken off the page once the shell is live, not just hidden (a hidden spinner went on turning).
        _notice.Content = notice;
        _notice.Visibility = notice == null ? Visibility.Collapsed : Visibility.Visible;
        _banner.Visibility = banner ? Visibility.Visible : Visibility.Collapsed;
        _add.IsEnabled = ShellsOpen && _tabs.Count < TerminalSettings.MaxTabs;
        Front.View.IsHitTestVisible = notice == null;
        ShowSubtitle();
    }

    private FrameworkElement LoadingCard(string words)
    {
        var panel = new StackPanel { Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        panel.Children.Add(new ProgressRing { IsActive = true, Width = 28, Height = 28 });
        panel.Children.Add(new TextBlock { Text = words, Foreground = Grey, HorizontalAlignment = HorizontalAlignment.Center });
        return new Grid { Background = TerminalView.Panel, Children = { panel } };
    }

    /// The first-time question as the page's own card: three short points, the risk first in orange, then Turn On
    /// (Enter) and Not Now (Esc).
    private FrameworkElement Consent()
    {
        var panel = new StackPanel { Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 520, Margin = new Thickness(24) };
        AutomationProperties.SetAutomationId(panel, "terminal.consent");
        var card = TerminalWords.Consent(Computer, _settings.RequiresUnlock);
        panel.Children.Add(new FontIcon { Glyph = W.Symbol("terminal"), FontSize = 40, Foreground = Grey, HorizontalAlignment = HorizontalAlignment.Center });
        panel.Children.Add(new TextBlock { Text = card.Title, FontSize = 20, FontWeight = FontWeights.SemiBold, Foreground = White, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, HorizontalAlignment = HorizontalAlignment.Center });
        foreach (var point in TerminalWords.ConsentPoints(_settings.RequiresUnlock))
        {
            var row = new Grid { ColumnSpacing = 10 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(22) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.Children.Add(new FontIcon { Glyph = W.Symbol(point.Glyph), FontSize = 15, Foreground = point.Warning ? W.Orange : Grey, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0) });
            var words = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 14 };
            words.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = point.Lead, FontWeight = FontWeights.SemiBold, Foreground = White });
            words.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = point.Rest, Foreground = Grey });
            Grid.SetColumn(words, 1);
            row.Children.Add(words);
            panel.Children.Add(row);
        }
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 8, 0, 0) };
        var on = new Button { Content = card.Button, Style = W.Res<Style>("AccentButtonStyle") };
        AutomationProperties.SetAutomationId(on, "terminal.turnOn");
        on.Click += (_, _) => TurnOn();
        var not = new Button { Content = card.Secondary };
        AutomationProperties.SetAutomationId(not, "terminal.notNow");
        not.Click += (_, _) => NotNow();
        buttons.Children.Add(on);
        buttons.Children.Add(not);
        panel.Children.Add(buttons);
        return new Grid { Background = TerminalView.Panel, Children = { panel } };
    }

    /// The Mac's Update Add-on runs the push add-on's setup (PushSetupOffer, the Notifications feature's on Windows);
    /// here it asks the computer again once the add-on has been updated there.
    private void UpdateAddOn()
    {
        if (!_updateAsked) { _updateAsked = true; Render(); return; }
        _ = CheckAndConnectAsync();
    }

    // MARK: The ⋯ menu

    private static MenuFlyoutItem Add(MenuFlyout menu, string text, string glyph, Action act, bool enabled = true)
    {
        var item = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph }, IsEnabled = enabled };
        item.Click += (_, _) => act();
        menu.Items.Add(item);
        return item;
    }

    private void FillMenu(MenuFlyout menu)
    {
        menu.Items.Clear();
        var live = IsLive;
        var hasText = ShellsOpen;
        if (!_relocked)
        {
            Add(menu, "Paste", "", () => _ = PasteAsync(), live && SafeClipboard.TryContains(StandardDataFormats.Text));
            Add(menu, "Copy All", "", CopyAll, hasText);
            Add(menu, "Select Text…", "", () => _ = SelectTextAsync(), hasText);
            menu.Items.Add(new MenuFlyoutSeparator());
        }
        var size = _settings.FontSize;
        Add(menu, "Bigger", "", () => TextSize(+1), size < TerminalSettings.MaxSize);
        Add(menu, "Smaller", "", () => TextSize(-1), size > TerminalSettings.MinSize);
        var normal = Add(menu, "Default Size", "", () => TextSize(0), size != TerminalSettings.DefaultSize);
        normal.Icon = null;
        var font = new MenuFlyoutSubItem { Text = "Font", Icon = new FontIcon { Glyph = "" } };
        foreach (var face in Enum.GetValues<TerminalSettings.Face>())
        {
            var item = new ToggleMenuFlyoutItem { Text = TerminalSettings.Title(face), IsChecked = face == _settings.FontFace };
            var chosen = face;
            item.Click += (_, _) => { _settings.FontFace = chosen; ApplyFont(); AppLog.Note("terminal", $"font {chosen}"); };
            font.Items.Add(item);
        }
        menu.Items.Add(font);
        menu.Items.Add(new MenuFlyoutSeparator());
        var lockItem = new ToggleMenuFlyoutItem { Text = $"Require {TerminalWords.UnlockName}", IsChecked = _settings.RequiresUnlock, Icon = new FontIcon { Glyph = "" } };
        lockItem.Click += (_, _) => _ = ToggleLockAsync();
        menu.Items.Add(lockItem);
        // Locked again: only the text size and the lock until Windows Hello.
        if (_relocked) return;
        if (ShellsOpen || _tabs.Count > 1 || _state is State.Connection { Phase: not TerminalConnection.Phase.Connecting }) menu.Items.Add(new MenuFlyoutSeparator());
        if (ShellsOpen) Add(menu, "New Tab", "", NewTab, _tabs.Count < TerminalSettings.MaxTabs);
        if (_tabs.Count > 1)
        {
            Add(menu, "Rename Tab…", "", () => _ = RenameTabAsync(_current));
            Add(menu, "Close Tab", "", () => _ = CloseTabAsync(_current));
        }
        if (_state is State.Connection { Phase: not TerminalConnection.Phase.Connecting })
            Add(menu, "New Shell", "", () => _ = NewShellAsync(confirm: live));
        if (live) Add(menu, "End Shell", "", () => _ = EndShellAsync());
    }

    private async Task ToggleLockAsync()
    {
        if (!_settings.RequiresUnlock) { _settings.RequiresUnlock = true; return; }
        // Turning it off asks for Windows Hello first (audit 09-1); a PC that can't check at all may still turn it off.
        if (await TerminalUnlock.UnlockAsync(true, $"Turn off Require {TerminalWords.UnlockName} for the Terminal") == TerminalUnlock.Answer.Refused) return;
        _settings.RequiresUnlock = false;
        AppLog.Note("terminal", "lock turned off");
        if (_relocked) Unlocked();
        Render();
    }

    // MARK: Copy and paste

    /// A paste of several lines asks first unless the shell has bracketed paste on (each line would run as it lands).
    private async Task PasteAsync()
    {
        if (!IsLive) return;
        var content = SafeClipboard.TryGetContent();
        if (content == null || !content.Contains(StandardDataFormats.Text)) return;
        string text;
        try { text = await content.GetTextAsync(); } catch (Exception) { return; }
        if (text.Length == 0) return;
        var tab = Front;
        var bracketed = tab.View.Screen.BracketedPaste;
        if (TerminalWords.PasteAsks(text, bracketed))
        {
            var (title, message) = TerminalWords.PasteAsk(TerminalWords.PasteLines(text));
            if (!await W.AskAsync(XamlRoot, title, message, "Paste")) { FocusShell(); return; }
        }
        AppLog.Note("terminal", $"paste {Encoding.UTF8.GetByteCount(text)} bytes");
        tab.Connection?.Send(TerminalKeys.Paste(text, tab.View.Screen.BracketedPaste));
        tab.View.Focus(FocusState.Programmatic);
    }

    private void CopyAll()
    {
        MediaActions.CopyText(Front.View.Screen.AllText());
        Pill("Copied");
    }

    private async Task SelectTextAsync()
    {
        var box = new TextBox
        {
            AcceptsReturn = true, Text = Front.View.Screen.AllText(), IsReadOnly = true, TextWrapping = TextWrapping.NoWrap,
            FontFamily = new FontFamily(TerminalSettings.Family(_settings.FontFace)), FontSize = 13, Height = 420, Width = 560,
        };
        ScrollViewer.SetHorizontalScrollBarVisibility(box, Microsoft.UI.Xaml.Controls.ScrollBarVisibility.Auto);
        AutomationProperties.SetAutomationId(box, "terminal.text");
        var dialog = new ContentDialog { Title = "Select Text", Content = box, CloseButtonText = "Done" };
        box.Loaded += (_, _) => { box.Select(box.Text.Length, 0); };
        await SafeDialog.ShowAsync(XamlRoot, dialog);
        FocusShell();
    }

    /// "Copied", "Copied by the Shell": a pill at the panel's foot for two seconds (the Mac's UndoPill without Undo).
    private void Pill(string words)
    {
        _pill.Child = new TextBlock { Text = words, Foreground = White, FontSize = 13 };
        _pill.Visibility = Visibility.Visible;
        var shown = _pill.Child;
        _ = Task.Delay(2000).ContinueWith(_ =>
        {
            if (!_navigatedOut && !AppShutdown.Stopping)
                _ui.TryEnqueue(() => { if (!_navigatedOut && !AppShutdown.Stopping && _pill.Child == shown) _pill.Visibility = Visibility.Collapsed; });
        });
    }

    // MARK: Text size and font

    private void TextSize(int step)
    {
        _settings.FontSize = step == 0 ? TerminalSettings.DefaultSize : _settings.FontSize + step;
        ApplyFont();
    }

    private void ApplyFont()
    {
        var family = TerminalSettings.Family(_settings.FontFace);
        foreach (var tab in _tabs) tab.View.SetFont(family, _settings.FontSize);
    }

    // MARK: The shell

    private async Task NewShellAsync(bool confirm)
    {
        var tab = Front;
        if (confirm)
        {
            var (title, message) = TerminalWords.NewShellAsk;
            if (!await W.AskAsync(XamlRoot, title, message, "New Shell", destructive: true)) return;
        }
        if (tab.Phase is TerminalConnection.Phase.Live)
        {
            tab.NewAfterEnd = true;
            tab.Connection?.EndShell();
        }
        else
        {
            tab.Session = TerminalWire.NewSession();
            SaveTabs();
            tab.View.Clear();
            Connect(tab);
        }
    }

    private async Task EndShellAsync()
    {
        var (title, message) = TerminalWords.EndShellAsk;
        var tab = Front;
        if (!await W.AskAsync(XamlRoot, title, message, "End Shell", destructive: true)) { FocusShell(); return; }
        tab.EndedHere = true;
        tab.Connection?.EndShell();
    }

    private void FocusShell()
    {
        if (IsLive && _tabs.Count > 0) Front.View.Focus(FocusState.Programmatic);
    }

    // MARK: Away (audit 09-2, as the Mac: the window minimised locks the page again with the lock on)

    private void OnWindowVisibility(object sender, WindowVisibilityChangedEventArgs e)
    {
        if (!e.Visible)
        {
            if (!_settings.RequiresUnlock || _state is not (State.Checking or State.NeedsAddOn or State.Connection)) return;
            if (!_relocked) AppLog.Note("terminal", "locked again (the app went away)");
            _relocked = true;
            _relockWhy = null;
            Render();
        }
        else if (_relocked) _ = UnlockAgainAsync();
    }

    private async Task UnlockAgainAsync()
    {
        if (!_relocked || _unlocking) return;
        _unlocking = true;
        var answer = await TerminalUnlock.UnlockAsync(true);
        _unlocking = false;
        switch (answer)
        {
            case TerminalUnlock.Answer.Unlocked: Unlocked(); break;
            case TerminalUnlock.Answer.Refused: _relockWhy = null; break;
            case TerminalUnlock.Answer.Unavailable: _relockWhy = TerminalWords.CantCheck; break;
        }
        Render();
    }

    private void Unlocked()
    {
        _relocked = false;
        _relockWhy = null;
        ShowTabs();
        Render();
        if (_tabs.Count > 0 && IsLive && Front.PendingCommand != null) SchedulePendingCommand(Front);
        FocusShell();
    }

    // MARK: Keys

    private static bool Down(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    private void OnKey(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
    {
        bool ctrl = Down(VirtualKey.Control), shift = Down(VirtualKey.Shift);
        if (_state is State.Consent && !_relocked)
        {
            if (e.Key == VirtualKey.Enter) { TurnOn(); e.Handled = true; }
            else if (e.Key == VirtualKey.Escape) { NotNow(); e.Handled = true; }
            return;
        }
        if (!ctrl) return;
        switch (e.Key)
        {
            case VirtualKey.T when shift: NewTab(); e.Handled = true; break;
            case VirtualKey.W when shift: _ = CloseTabAsync(_current); e.Handled = true; break;
            case VirtualKey.Tab: Cycle(shift ? -1 : 1); e.Handled = true; break;
            case (VirtualKey)187 or VirtualKey.Add: TextSize(+1); e.Handled = true; break;          // Ctrl+= (Make Text Bigger)
            case (VirtualKey)189 or VirtualKey.Subtract when !shift: TextSize(-1); e.Handled = true; break;   // Ctrl+-
            case VirtualKey.Number0 or VirtualKey.NumberPad0: TextSize(0); e.Handled = true; break;
        }
    }
}

/// The lock each time the Terminal opens (TerminalUnlock on the Mac: Touch ID or the Mac's password): Windows Hello,
/// which asks for a face, a finger or the PIN. A PC with no Windows Hello set up counts as unlocked, as an iPhone
/// without a passcode does.
internal static class TerminalUnlock
{
    public enum Answer { Unlocked, Refused, Unavailable }

    public static async Task<Answer> UnlockAsync(bool required, string? reason = null)
    {
        if (!required) return Answer.Unlocked;
        try
        {
            var available = await UserConsentVerifier.CheckAvailabilityAsync();
            switch (available)
            {
                case UserConsentVerifierAvailability.DeviceNotPresent or UserConsentVerifierAvailability.NotConfiguredForUser:
                    return Answer.Unlocked;
                case UserConsentVerifierAvailability.DisabledByPolicy or UserConsentVerifierAvailability.DeviceBusy:
                    return Answer.Unavailable;
            }
            var message = reason ?? "Open the Terminal";
            var hwnd = MediaActions.WindowHandle();
            var result = await UserConsentVerifierInterop.RequestVerificationForWindowAsync(hwnd, message);
            return result == UserConsentVerificationResult.Verified ? Answer.Unlocked
                : result is UserConsentVerificationResult.DeviceNotPresent or UserConsentVerificationResult.NotConfiguredForUser ? Answer.Unlocked
                : result is UserConsentVerificationResult.DisabledByPolicy or UserConsentVerificationResult.DeviceBusy ? Answer.Unavailable
                : Answer.Refused;
        }
        catch (Exception e)
        {
            AppLog.Error("terminal", e);
            return Answer.Unavailable;
        }
    }
}
