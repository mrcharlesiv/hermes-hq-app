using System.Runtime.CompilerServices;
using Hermes.Core.Activity;
using Hermes.Core.Chat;
using Hermes.Core.Coding;
using Hermes.Core.Model;
using Hermes.Core.Sessions;
using Hermes.Core.Transcripts;
using HermesHQ.Controls;
using HermesHQ.Features.Coding;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Transcript;

/// The inspector beside a chat (App/Mac/MacInspector.swift): Info, Steps, Files, Helpers and Chats tabs across its top;
/// the tab kept across launches. Info shows Chat Info rows, Pull Request facts rows (opening `PullRequestCardView`),
/// and 3-second polled Running Commands (`process.list` / `process.kill`). Steps lists the latest turn's steps;
/// Helpers lists the turn's subagents; Files shows the chat's folder; Chats lists every chat of the bot (`BotChatsPanel`).
public sealed class ChatInspector : IDisposable
{
    public enum Tab { Info, Steps, Files, Helpers, Chats }
    private static readonly string[] Titles = ["Info", "Steps", "Files", "Helpers", "Chats"];
    private const string TabKey = "HQMacInspectorTab";
    private static readonly ConditionalWeakTable<FrameworkElement, ChatInspector> Owners = new();

    private readonly ChatSession _session;
    private readonly Func<ChatActivity> _activity;
    private readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();
    private readonly Grid _root = new();
    private readonly StackPanel _tabs = new() { Orientation = Orientation.Horizontal, Spacing = 2, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly ToggleButton[] _tabButtons = new ToggleButton[Titles.Length];
    private readonly ContentControl _page = new() { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private Tab _tab;
    /// The step whose sheet is open (Steps tab), by message id and call id.
    private (string Message, string Call)? _step;
    private string? _lastKey;
    private string? _filesCwd;
    private FrameworkElement? _filesView;
    private BotChatsPanel? _chatsView;

    // Info tab: PR facts subscription + 3-second Running Commands poll (`App/Chat/ChatSheets.swift`).
    private CodingStore? _codingStore;
    private string? _prFetchedKey;
    private CancellationTokenSource? _commandsCts;
    private IReadOnlyList<BackgroundProcess> _commands = [];
    private bool _commandsUnsupported;
    private bool _disposed;

    public FrameworkElement View => _root;

    public Tab CurrentTab => _tab;

    /// Whether the chat beside this inspector is a bot's own canonical Bot Chat (forwarded by `ChatPage`).
    public bool IsBotChat { get; set; }

    /// Looks up the `ChatInspector` owning a hosted inspector view (`ChatPage`'s `Inspector.Content`).
    public static ChatInspector? FromView(object? content) =>
        content is FrameworkElement fe && Owners.TryGetValue(fe, out var inspector) ? inspector : null;

    /// [workspace] Draws the Files tab for a chat (the Workspace feature's browser of the chat's folder); null, or no
    /// hook, keeps the Mac's "No Folder" note.
    public static Func<ChatSession, FrameworkElement?>? FilesView { get; set; }

    public ChatInspector(ChatSession session, Func<ChatActivity> activity)
    {
        _session = session;
        _activity = activity;
        Owners.AddOrUpdate(_root, this);
        _tab = Enum.TryParse<Tab>(FilePreferences.Shared.Get(TabKey), out var kept) ? kept : Tab.Info;
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        foreach (var t in Enum.GetValues<Tab>())
        {
            var button = new ToggleButton
            {
                Content = Titles[(int)t], IsChecked = t == _tab, Padding = new Thickness(8, 4, 8, 4), FontSize = 12,
                CornerRadius = new CornerRadius(6), MinWidth = 44,
            };
            AutomationProperties.SetAutomationId(button, $"mac.inspector.{t.ToString().ToLowerInvariant()}");
            var tab = t;
            button.Click += (_, _) => Show(tab);
            _tabButtons[(int)t] = button;
            _tabs.Children.Add(button);
        }
        var bar = new Border
        {
            Child = _tabs, Padding = new Thickness(8, 8, 8, 8),
            BorderBrush = Res<Brush>("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(0, 0, 0, 1),
        };
        _root.Children.Add(bar);
        Grid.SetRow(_page, 1);
        _root.Children.Add(_page);
        _root.Loaded += OnLoaded;
        _root.Unloaded += OnUnloaded;
        Refresh(force: true);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        StopCommandsPolling();
        DetachCodingStore();
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (_disposed) return;
        AttachCodingStore();
        if (_tab == Tab.Info)
        {
            EnsurePRStatusLoaded();
            StartCommandsPolling();
        }
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        StopCommandsPolling();
        DetachCodingStore();
    }

    private void AttachCodingStore()
    {
        var store = CodingFeature.GetStore();
        if (ReferenceEquals(_codingStore, store)) return;
        DetachCodingStore();
        _codingStore = store;
        _codingStore.Changed += OnCodingStoreChanged;
    }

    private void DetachCodingStore()
    {
        if (_codingStore == null) return;
        _codingStore.Changed -= OnCodingStoreChanged;
        _codingStore = null;
    }

    private void OnCodingStoreChanged()
    {
        if (_disposed || _tab != Tab.Info) return;
        _ui.TryEnqueue(() => { if (!_disposed && _tab == Tab.Info) Refresh(); });
    }

    public void Show(Tab tab)
    {
        _tab = tab;
        _step = null;
        FilePreferences.Shared.Set(TabKey, tab.ToString());
        if (_tab == Tab.Info && _root.IsLoaded)
        {
            AttachCodingStore();
            EnsurePRStatusLoaded();
            StartCommandsPolling();
        }
        else
        {
            StopCommandsPolling();
        }
        Refresh(force: true);
    }

    /// Selects a specific inspector tab (used by `SessionStrip`'s "All N" button to jump to `Tab.Chats`).
    public void SelectTab(Tab tab) => Show(tab);

    /// Opens the 5th inspector tab (`Chats`, hosting `BotChatsPanel`).
    public void OpenChats() => Show(Tab.Chats);

    /// A bubble asked for one of its steps: the Steps tab, that step's sheet.
    public void ShowStep(ChatMessage message, ToolCall? call)
    {
        _tab = Tab.Steps;
        _step = call == null ? null : (message.Id, call.Id);
        StopCommandsPolling();
        Refresh(force: true);
    }

    /// Redraws the open tab (the chat changed). Skips rebuilding if the shown tab's data did not change.
    public void Refresh(bool force = false)
    {
        for (var i = 0; i < _tabButtons.Length; i++)
            _tabButtons[i].IsChecked = i == (int)_tab;

        if (_tab == Tab.Info && _root.IsLoaded)
        {
            AttachCodingStore();
            EnsurePRStatusLoaded();
            StartCommandsPolling();
        }
        else if (_tab != Tab.Info)
        {
            StopCommandsPolling();
        }

        var key = ContentFingerprint();
        if (!force && key == _lastKey && _page.Content != null) return;
        _lastKey = key;

        if (_tab == Tab.Files)
        {
            if (_filesView == null || _filesCwd != _session.Cwd)
            {
                _filesCwd = _session.Cwd;
                _filesView = FilesView?.Invoke(_session);
            }
            _page.Content = _filesView ?? Note("", "No Folder", "This chat isn’t working in a folder, so there are no files to show.");
            return;
        }

        if (_tab == Tab.Chats)
        {
            var onBotChat = ResolveIsBotChat();
            _chatsView ??= new BotChatsPanel(_session, onBotChat);
            _chatsView.Follow(_session, onBotChat);
            _chatsView.Refresh(force);
            _page.Content = _chatsView;
            return;
        }

        HermesHQ.Services.UiTree.DeactivateProgressRings(_page);
        _page.Content = _tab switch
        {
            Tab.Info => Info(),
            Tab.Steps => _step is { } s && Find(s) is { } call ? StepSheet(call) : Steps(),
            Tab.Helpers => Helpers(),
            _ => Helpers(),
        };
    }

    private bool ResolveIsBotChat()
    {
        if (IsBotChat || _session.Title == Bot.BotChatTitle) return true;
        var bot = Features.Bots.ListsHub.Current?.Bots.Bot(_session.Profile);
        return bot != null && !string.IsNullOrEmpty(_session.StoredId)
            && (_session.StoredId == bot.RegistryId || _session.StoredId == bot.OpenId);
    }

    private string ContentFingerprint() => _tab switch
    {
        Tab.Info => InfoFingerprint(),
        Tab.Files => $"files|{_session.Cwd}",
        Tab.Steps => _step is { } s && Find(s) is { } c
            ? $"step|{c.Id}|{(int)c.State}|{StepWords.Subtitle(c)}|{StepWords.Sections(c).Sum(sec => sec.Text.Length)}"
            : $"steps|{string.Join(",", LatestSteps.Of(_session.Messages).Select(x => $"{x.Call.Id}:{(int)x.Call.State}"))}",
        Tab.Chats => $"chats|{_session.Profile}|{_session.StoredId}|{ResolveIsBotChat()}|{Features.Bots.ListsHub.Current?.Sessions.Reads ?? 0}",
        Tab.Helpers => $"helpers|{string.Join(",", _activity().Subagents.Select(h => $"{h.Id}:{(int)h.Status}:{h.Goal}:{SubagentWords.RowLine(h)}"))}",
        _ => $"helpers|{string.Join(",", _activity().Subagents.Select(h => $"{h.Id}:{(int)h.Status}:{h.Goal}:{SubagentWords.RowLine(h)}"))}",
    };

    private string InfoFingerprint()
    {
        var pr = CurrentPRStatus();
        var prSig = pr == null ? "" : $"{(int)pr.State}:{pr.Number}:{pr.Manual}:{pr.AllItems.Count}:{pr.Checks?.State}:{pr.Checks?.Failed}";
        var cmdSig = _commands.Count == 0
            ? ""
            : string.Join(",", _commands.Select(c => $"{c.Id}:{c.Status}:{c.UptimeSeconds}:{c.OutputTail?.Length ?? 0}"));
        return $"info|{_session.Title}|{_session.Cwd}|{_session.StoredId}|{Features.Bots.ListsHub.Current?.Client.Rpc.State}|{prSig}|{cmdSig}";
    }

    private SessionPRStatus? CurrentPRStatus() =>
        !string.IsNullOrEmpty(_session.StoredId)
            ? (_codingStore ?? CodingFeature.GetStore()).StatusFor(_session.Profile, _session.StoredId)
            : null;

    private void EnsurePRStatusLoaded()
    {
        if (string.IsNullOrEmpty(_session.StoredId)) return;
        var key = $"{_session.Profile}:{_session.StoredId}";
        if (_prFetchedKey == key) return;
        _prFetchedKey = key;
        var store = _codingStore ?? CodingFeature.GetStore();
        if (store.StatusFor(_session.Profile, _session.StoredId) != null) return;
        _ = store.RefreshPRStatusAsync([(_session.Profile, _session.StoredId)], fresh: false, detail: false);
    }

    private void StartCommandsPolling()
    {
        if (_disposed || _commandsUnsupported || _tab != Tab.Info || _commandsCts != null) return;
        var sessionId = _session.RuntimeId ?? _session.StoredId;
        if (string.IsNullOrEmpty(sessionId)) return;
        var cts = new CancellationTokenSource();
        _commandsCts = cts;
        _ = PollCommandsLoopAsync(cts);
    }

    private void StopCommandsPolling()
    {
        var cts = Interlocked.Exchange(ref _commandsCts, null);
        if (cts == null) return;
        try { cts.Cancel(); } catch (ObjectDisposedException) { }
        cts.Dispose();
    }

    private async Task PollCommandsLoopAsync(CancellationTokenSource cts)
    {
        var token = cts.Token;
        try
        {
            using var timer = new PeriodicTimer(TimeSpan.FromSeconds(3));
            while (!token.IsCancellationRequested && !_disposed && _tab == Tab.Info)
            {
                var client = _session.Client;
                var sessionId = _session.RuntimeId ?? _session.StoredId;
                if (!string.IsNullOrEmpty(sessionId))
                {
                    try
                    {
                        var list = await BackgroundProcessesApi.ListProcessesAsync(client, sessionId, _session.Profile, token);
                        if (token.IsCancellationRequested || _disposed) break;
                        if (list == null)
                        {
                            // -32601 unsupported: silently omit Running Commands and stop polling.
                            _commandsUnsupported = true;
                            if (_commands.Count > 0)
                            {
                                _commands = [];
                                _ui.TryEnqueue(() => { if (!_disposed && _tab == Tab.Info) Refresh(); });
                            }
                            break;
                        }
                        var running = list.Where(p => p.IsRunning).ToList();
                        if (!CommandsEqual(_commands, running))
                        {
                            _commands = running;
                            _ui.TryEnqueue(() => { if (!_disposed && _tab == Tab.Info) Refresh(); });
                        }
                    }
                    catch (OperationCanceledException) { break; }
                    catch (Exception) { /* transient error: retry on the next 3s tick */ }
                }

                if (!await timer.WaitForNextTickAsync(token)) break;
            }
        }
        catch (OperationCanceledException) { }
        finally
        {
            if (ReferenceEquals(_commandsCts, cts)) _commandsCts = null;
        }
    }

    private static bool CommandsEqual(IReadOnlyList<BackgroundProcess> a, IReadOnlyList<BackgroundProcess> b)
    {
        if (a.Count != b.Count) return false;
        for (var i = 0; i < a.Count; i++)
        {
            if (!string.Equals(a[i].Id, b[i].Id, StringComparison.Ordinal)
                || !string.Equals(a[i].Status, b[i].Status, StringComparison.Ordinal)
                || !Equals(a[i].UptimeSeconds, b[i].UptimeSeconds)
                || !string.Equals(a[i].OutputTail, b[i].OutputTail, StringComparison.Ordinal)
                || !string.Equals(a[i].Command, b[i].Command, StringComparison.Ordinal))
                return false;
        }
        return true;
    }

    private async Task StopCommandAsync(BackgroundProcess proc)
    {
        var client = _session.Client;
        var sessionId = _session.RuntimeId ?? _session.StoredId;
        if (string.IsNullOrEmpty(sessionId)) return;

        _commands = [.. _commands.Where(c => !string.Equals(c.Id, proc.Id, StringComparison.Ordinal))];
        Refresh(force: true);

        try
        {
            await BackgroundProcessesApi.KillProcessAsync(client, sessionId, proc.Id, _session.Profile);
            var list = await BackgroundProcessesApi.ListProcessesAsync(client, sessionId, _session.Profile);
            if (!_disposed && list != null)
            {
                _commands = [.. list.Where(p => p.IsRunning)];
                _ui.TryEnqueue(() => { if (!_disposed && _tab == Tab.Info) Refresh(force: true); });
            }
        }
        catch (Exception) { /* next 3s poll reconciles */ }
    }

    private ToolCall? Find((string Message, string Call) s) =>
        _session.Messages.LastOrDefault(m => m.Id == s.Message)?.Tools.FirstOrDefault(t => t.Id == s.Call)
        ?? _session.Messages.SelectMany(m => m.Tools).LastOrDefault(t => t.Id == s.Call);

    // MARK: Info

    /// [WIN-INSPECTOR-INFO-ROWS] Chat Info in the panel (ChatInfoSheet.makeContent with `panel`, ChatSheets.swift): the
    /// face and the chat's name ("This chat" when blank), Chat Info's rows (`ChatInfoPanel.Content`), Pull Request rows
    /// opening `PullRequestCardView`, Running Commands polled every 3 s (`process.list` / `process.kill`), and Copy Chat Info.
    private FrameworkElement Info()
    {
        var hub = Features.Bots.ListsHub.Current;
        var bot = hub?.Bots.Bot(_session.Profile);
        var botName = Hermes.Core.Sessions.SessionRules.OwnerName(_session.Profile, hub?.Sessions.BotNames ?? new Dictionary<string, string>());
        var content = Hermes.Core.Sessions.ChatInfoPanel.Content(_session.Title, _session.Profile,
            hub?.Sessions.Row(_session.Profile, _session.StoredId), _session.StoredId, bot?.Profile.Model, botName,
            hub?.Client.Session.Address.Base.Host ?? "",
            Hermes.Core.Sessions.ChatInfoPanel.GatewayNote(hub?.Client.Rpc.State ?? Hermes.Core.Rpc.ConnectionState.Offline));
        if (content == null) return Note("\uE946", Hermes.Core.Sessions.ChatInfoPanel.EmptyTitle, Hermes.Core.Sessions.ChatInfoPanel.EmptyHint);

        const double margin = 16;
        var secondary = Res<Brush>("TextFillColorSecondaryBrush");
        var stack = new StackPanel { Padding = new Thickness(0, 0, 0, 16) };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(stack, "info.list");

        // macHeader: a 36 px face and the name beside it, in a 60 px band.
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, MinHeight = 60, Padding = new Thickness(margin, 0, 20, 0) };
        var face = new BotHead { Width = 36, Height = 36, VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false };
        if (bot?.Model is { } model) face.Bot = model; else face.DisplayName = botName;
        header.Children.Add(face);
        var title = new TextBlock
        {
            Text = content.Name, FontWeight = FontWeights.SemiBold, MaxLines = 2, TextWrapping = TextWrapping.Wrap,
            TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(title, "info.title");
        header.Children.Add(title);
        stack.Children.Add(header);

        // The rows: the label in a narrow column (as wide as the widest label needs, the Mac's 64 px at least), the
        // value and its note beside it, a hairline from margin to margin under each row.
        var grid = new Grid { ColumnSpacing = 12, Padding = new Thickness(margin, 0, margin, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto, MinWidth = 64 });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var rule = Res<Brush>("CardStrokeColorDefaultBrush");
        foreach (var r in content.Rows)
        {
            var at = grid.RowDefinitions.Count;
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var label = new TextBlock { Text = r.Label, FontSize = 13, Foreground = secondary, Margin = new Thickness(0, 9, 0, 9) };
            Grid.SetRow(label, at);
            grid.Children.Add(label);
            var value = new StackPanel { Margin = new Thickness(0, 9, 0, 9) };
            var oneWord = !r.Value.Any(c => char.IsWhiteSpace(c) || c == '/');
            var text = new TextBlock
            {
                Text = r.Value, FontSize = r.Mono ? 12 : 13, IsTextSelectionEnabled = true,
                TextWrapping = oneWord ? TextWrapping.NoWrap : TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis,
                MaxLines = oneWord ? 1 : r.Mono ? 2 : 0,
            };
            if (r.Mono) text.FontFamily = Res<FontFamily>("CodeFont");
            value.Children.Add(text);
            if (r.Note != null) value.Children.Add(new TextBlock { Text = r.Note, FontSize = 12, Foreground = secondary, TextWrapping = TextWrapping.Wrap });
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(value, "info.row." + r.Label.ToLowerInvariant().Replace(' ', '-'));
            var line = Hermes.Core.Sessions.ChatInfoRows.CopyText([r], content.Profile);
            var menu = new MenuFlyout();
            var copy = new MenuFlyoutItem { Text = "Copy", Icon = new FontIcon { Glyph = "\uE8C8" } };
            copy.Click += (_, _) => MessageView.CopyText(line);
            menu.Items.Add(copy);
            value.ContextFlyout = menu;
            Grid.SetRow(value, at);
            Grid.SetColumn(value, 1);
            grid.Children.Add(value);
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var hairline = new Border { Height = 1, Background = rule };
            Grid.SetRow(hairline, at + 1);
            Grid.SetColumnSpan(hairline, 2);
            grid.Children.Add(hairline);
        }

        // Pull Request rows (`App/Chat/ChatSheets.swift` `prRows`): each row opens `PullRequestCardView`.
        if (CurrentPRStatus() is { DrawsMark: true } pr
            && !(pr.State == SessionPRState.Unknown && pr.UnknownReason == SessionPRUnknownReason.Unmatched))
        {
            var prEntries = BuildPRInfoRows(pr);
            for (var i = 0; i < prEntries.Count; i++)
            {
                var (rowLabel, rowStatus, display, focus) = prEntries[i];
                var at = grid.RowDefinitions.Count;
                grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                var label = new TextBlock { Text = rowLabel, FontSize = 13, Foreground = secondary, Margin = new Thickness(0, 9, 0, 9), VerticalAlignment = VerticalAlignment.Center };
                Grid.SetRow(label, at);
                grid.Children.Add(label);

                var btnContent = new Grid { ColumnSpacing = 6 };
                btnContent.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                btnContent.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var valStack = new StackPanel { Spacing = 1 };
                valStack.Children.Add(new TextBlock
                {
                    Text = display, FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis,
                    Foreground = Res<Brush>("AccentTextFillColorPrimaryBrush"),
                });
                if (PRVerdict.ForActiveRow(rowStatus) is { } verdict)
                {
                    valStack.Children.Add(new TextBlock
                    {
                        Text = verdict.DisplayText, FontSize = 11.5,
                        Foreground = Res<Brush>(verdict is PRVerdict.Failing ? "SystemFillColorCriticalBrush" : "TextFillColorSecondaryBrush"),
                    });
                }
                btnContent.Children.Add(valStack);
                var chevron = new FontIcon { Glyph = "\uE76C", FontSize = 10, Foreground = Res<Brush>("TextFillColorTertiaryBrush"), VerticalAlignment = VerticalAlignment.Center };
                Grid.SetColumn(chevron, 1);
                btnContent.Children.Add(chevron);

                var openBtn = new Button
                {
                    Content = btnContent,
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Stretch,
                    Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                    BorderThickness = new Thickness(0),
                    Padding = new Thickness(0, 9, 0, 9),
                };
                AutomationProperties.SetAutomationId(openBtn, i == 0 ? "info.pull-request" : $"info.pull-request.{i}");
                AutomationProperties.SetName(openBtn, $"{rowLabel}, {display}");
                var capturedPr = pr;
                var capturedFocus = focus;
                openBtn.Click += (_, _) => _ = OpenPRCardFromInspectorAsync(capturedPr, capturedFocus);
                Grid.SetRow(openBtn, at);
                Grid.SetColumn(openBtn, 1);
                grid.Children.Add(openBtn);

                grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                var hairline = new Border { Height = 1, Background = rule };
                Grid.SetRow(hairline, at + 1);
                Grid.SetColumnSpan(hairline, 2);
                grid.Children.Add(hairline);
            }
        }
        stack.Children.Add(grid);

        // Running Commands (`process.list` polled every 3 s, silently omitted when empty or -32601 unsupported).
        if (!_commandsUnsupported && _commands.Count > 0)
        {
            var sectionHeader = new TextBlock
            {
                Text = "Running Commands",
                FontSize = 12,
                FontWeight = FontWeights.SemiBold,
                Foreground = secondary,
                Margin = new Thickness(margin, 16, margin, 6),
            };
            AutomationProperties.SetAutomationId(sectionHeader, "info.commands.header");
            stack.Children.Add(sectionHeader);

            var codeFont = Res<FontFamily>("CodeFont");
            var critical = Res<Brush>("SystemFillColorCriticalBrush");
            for (var i = 0; i < _commands.Count; i++)
            {
                var cmd = _commands[i];
                var rowGrid = new Grid { ColumnSpacing = 8, Padding = new Thickness(margin, 7, margin, 7) };
                rowGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                rowGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

                var cmdStack = new StackPanel { Spacing = 3 };
                var headline = !string.IsNullOrWhiteSpace(cmd.Headline)
                    ? cmd.Headline
                    : !string.IsNullOrWhiteSpace(cmd.Command) ? cmd.Command : "Background command";
                cmdStack.Children.Add(new TextBlock
                {
                    Text = headline,
                    FontFamily = codeFont,
                    FontSize = 12.5,
                    MaxLines = 2,
                    TextWrapping = TextWrapping.Wrap,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                });
                var detail = FormatCommandDetail(cmd);
                var tail = FormatCommandTail(cmd.OutputTail);
                var secondaryText = string.IsNullOrEmpty(tail) ? detail : detail + "\n" + tail;
                cmdStack.Children.Add(new TextBlock
                {
                    Text = secondaryText,
                    FontFamily = codeFont,
                    FontSize = 11.5,
                    Foreground = secondary,
                    MaxLines = 3,
                    TextWrapping = TextWrapping.Wrap,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                });
                rowGrid.Children.Add(cmdStack);

                var captured = cmd;
                var stopBtn = new Button
                {
                    Content = "Stop",
                    FontSize = 12,
                    Foreground = critical,
                    Padding = new Thickness(8, 3, 8, 3),
                    VerticalAlignment = VerticalAlignment.Top,
                };
                AutomationProperties.SetAutomationId(stopBtn, $"info.command.{i}.stop");
                AutomationProperties.SetName(stopBtn, $"Stop {headline}");
                stopBtn.Click += (_, _) => _ = StopCommandAsync(captured);
                Grid.SetColumn(stopBtn, 1);
                rowGrid.Children.Add(stopBtn);

                AutomationProperties.SetAutomationId(rowGrid, $"info.command.{i}");
                stack.Children.Add(rowGrid);
                stack.Children.Add(new Border { Height = 1, Background = rule, Margin = new Thickness(margin, 0, margin, 0) });
            }
        }

        // macFooter: Copy Chat Info at the labels' edge, 14 px under the rows.
        var all = new Button { Content = Hermes.Core.Sessions.ChatInfoRows.CopyAll, Margin = new Thickness(margin, 14, 0, 0) };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(all, "info.copy-all");
        all.Click += (_, _) => MessageView.CopyText(content.CopyText);
        stack.Children.Add(all);
        return new ScrollViewer { Content = stack };
    }

    private static List<(string Label, SessionPRStatus Status, string Display, PullRequestCardFocus Focus)> BuildPRInfoRows(SessionPRStatus pr)
    {
        var items = pr.AllItems;
        if (items.Count <= 1 && !(pr.Manual && items.Count > 0))
            return [(pr.Number == null ? "Branch" : "Pull Request", pr, pr.Summary, new PullRequestCardFocus.Lead())];

        var list = new List<(string, SessionPRStatus, string, PullRequestCardFocus)>();
        if (pr.Manual)
            list.Add(("Code Changes", pr, "Closed, marked by you", new PullRequestCardFocus.Lead()));
        for (var i = 0; i < items.Count; i++)
        {
            var item = items[i];
            list.Add((item.Number == null ? "Branch" : "Pull Request", item.ToStatus(pr.Manual), item.Label, new PullRequestCardFocus.Item(i)));
        }
        return list;
    }

    private async Task OpenPRCardFromInspectorAsync(SessionPRStatus pr, PullRequestCardFocus focus)
    {
        var store = _codingStore ?? CodingFeature.GetStore();
        var summary = new SessionSummary
        {
            Id = _session.StoredId,
            Profile = _session.Profile,
            Title = _session.Title,
            Cwd = _session.Cwd,
            IsRunning = _session.Busy,
            Status = _session.Busy ? SessionStatus.Working : SessionStatus.Idle,
            PullRequest = pr,
        };
        await store.RefreshPRStatusAsync([(summary.Profile, summary.Id)], fresh: true, detail: true);
        var latest = store.StatusFor(summary.Profile, summary.Id) ?? pr;
        await CodingFeature.OpenPullRequestCardAsync(_root.XamlRoot, summary, latest, store, initialFocus: focus);
    }

    private static string FormatCommandDetail(BackgroundProcess proc)
    {
        if (!proc.IsRunning)
            return proc.ExitCode is { } code ? $"Exited (code {code})" : "Exited";
        var uptime = FormatUptime(proc.UptimeSeconds);
        return uptime != null ? $"Running · {uptime}" : "Running";
    }

    private static string? FormatUptime(double? seconds) => seconds is { } s && double.IsFinite(s) ? FormatDuration((int)Math.Max(0, s)) : null;

    private static string FormatDuration(int seconds)
    {
        var s = Math.Max(0, seconds);
        if (s < 60) return $"{s}s";
        if (s < 3600) return $"{s / 60}m";
        var m = (s % 3600) / 60;
        return m == 0 ? $"{s / 3600}h" : $"{s / 3600}h {m}m";
    }

    private static string FormatCommandTail(string? rawTail)
    {
        if (string.IsNullOrWhiteSpace(rawTail)) return "";
        var lines = rawTail.Replace("\r\n", "\n").Split('\n')
            .Select(l => l.Trim())
            .Where(l => l.Length > 0)
            .TakeLast(2)
            .Select(l => l.Length > 160 ? l[..159] + "…" : l);
        return string.Join("\n", lines);
    }

    // MARK: Steps

    private FrameworkElement Steps()
    {
        // [WIN-STEPS-AFTER-REPLY] The latest turn's (LatestSteps, the Mac's `turnSteps(endingAt: nil)`): kept after the
        // reply writes, from the stored turn the turn-end read brings; the Mac's live panel's words when it ran none.
        var steps = LatestSteps.Of(_session.Messages);
        if (steps.Count == 0) return Note("", LatestSteps.EmptyTitle, LatestSteps.EmptyHint);
        var stack = new StackPanel { Spacing = 0, Padding = new Thickness(10, 10, 10, 10) };
        stack.Children.Add(new TextBlock
        {
            Text = steps.Count == 1 ? "1 step" : $"{steps.Count} steps", FontSize = 12, Margin = new Thickness(6, 0, 0, 6),
            Foreground = Res<Brush>("TextFillColorSecondaryBrush"),
        });
        foreach (var (message, call) in steps)
        {
            var m = message;
            var c = call;
            stack.Children.Add(MessageView.StepRow(null, call, () => { _step = (m.Id, c.Id); Refresh(); }));
            stack.Children.Add(new Border { Height = 1, Margin = new Thickness(6, 0, 0, 0), Background = Res<Brush>("CardStrokeColorDefaultBrush") });
        }
        return new ScrollViewer { Content = stack };
    }

    /// The step sheet (StepSheets.swift StepDetailViewController): Back, the title ("Terminal" or the step's own),
    /// the step's words under it for a command, the subtitle, its sections (Command / Tools / Input, Output or Error,
    /// Duration), and Copy.
    private FrameworkElement StepSheet(ToolCall call)
    {
        var stack = new StackPanel { Spacing = 6, Padding = new Thickness(14, 10, 14, 16) };
        var head = new Grid();
        var back = new HyperlinkButton { Content = "‹ Back", Padding = new Thickness(0) };
        back.Click += (_, _) => { _step = null; Refresh(); };
        head.Children.Add(back);
        head.Children.Add(new TextBlock
        {
            Text = StepWords.SheetTitle(call), FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(60, 0, 60, 0),
        });
        stack.Children.Add(head);
        if (StepWords.IsTerminal(call))
            stack.Children.Add(new TextBlock
            {
                Text = RunSummary.Summarize([call], call.State == ToolState.Running), FontSize = 15, FontWeight = FontWeights.SemiBold,
                Margin = new Thickness(0, 8, 0, 0),
            });
        if (StepWords.Subtitle(call) is { } sub)
            stack.Children.Add(new TextBlock
            {
                Text = sub, FontSize = 12, TextWrapping = TextWrapping.Wrap,
                Foreground = Res<Brush>(call.State == ToolState.Failed ? "SystemFillColorCriticalBrush" : "TextFillColorSecondaryBrush"),
            });
        foreach (var (name, text, mono) in StepWords.Sections(call))
        {
            stack.Children.Add(new TextBlock { Text = name, FontSize = 12, Margin = new Thickness(0, 8, 0, 0),
                Foreground = Res<Brush>("TextFillColorSecondaryBrush") });
            var body = new TextBlock
            {
                Text = text.Length > 20_000 ? text[..20_000] : text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
                FontSize = mono ? 12.5 : 14,
            };
            // Only code takes the code face: a null FontFamily throws ("'Unknown' is not a valid value"), as the slash
            // drawer's did in CI run 45020434210.
            if (mono) body.FontFamily = Res<FontFamily>("CodeFont");
            stack.Children.Add(new Border
            {
                Child = body,
                Padding = new Thickness(10, 8, 10, 8), CornerRadius = new CornerRadius(6),
                Background = Res<Brush>("SubtleFillColorSecondaryBrush"),
            });
        }
        var copy = new Button { Content = "Copy", Margin = new Thickness(0, 10, 0, 0) };
        copy.Click += (_, _) => MessageView.CopyText(StepWords.CopyText(call));
        stack.Children.Add(copy);
        return new ScrollViewer { Content = stack };
    }

    // MARK: Helpers

    private FrameworkElement Helpers()
    {
        var helpers = _activity().Subagents;
        if (helpers.Count == 0) return Note("", "No Helpers", "Helpers the bot starts for this chat show here.");
        var stack = new StackPanel { Spacing = 8, Padding = new Thickness(14, 12, 14, 12) };
        stack.Children.Add(new TextBlock { Text = SubagentWords.CountLine(helpers), FontSize = 12, Foreground = Res<Brush>("TextFillColorSecondaryBrush") });
        foreach (var child in helpers) stack.Children.Add(ActivityShelf.HelperRow(_session, child, compact: false));
        return new ScrollViewer { Content = stack };
    }

    private static FrameworkElement Note(string glyph, string title, string hint)
    {
        var stack = new StackPanel { Spacing = 6, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Padding = new Thickness(24) };
        stack.Children.Add(new FontIcon { Glyph = glyph, FontSize = 28, Foreground = Res<Brush>("TextFillColorTertiaryBrush") });
        if (title.Length > 0) stack.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center });
        stack.Children.Add(new TextBlock { Text = hint, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, FontSize = 12,
            Foreground = Res<Brush>("TextFillColorSecondaryBrush") });
        return stack;
    }

    private static T Res<T>(string key) => ThemeBrushes.Res<T>(key);
}
