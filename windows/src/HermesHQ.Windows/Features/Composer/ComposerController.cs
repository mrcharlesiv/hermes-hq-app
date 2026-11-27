using Hermes.Core.Composer;
using Hermes.Core.Net;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;
using DispatcherQueue = Microsoft.UI.Dispatching.DispatcherQueue;
using DispatcherQueueTimer = Microsoft.UI.Dispatching.DispatcherQueueTimer;
using Windows.UI.Core;

namespace HermesHQ.Features.Composer;

/// One open chat's composer (the Mac's ChatViewController composer parts, ComposerView, ChatMenus): ☰ and the model
/// chip in the message box, the queue card, the switch notices and the edit strip on the shelf, the slash and @
/// drawers, the keys (Enter sends or steers, Ctrl+Enter queues, Up/Down/Tab/Esc in a drawer), and the ⋯ rows Model,
/// Prompts, Usage & Limits and Model Prices.
internal sealed class ComposerController : IModelSwitchUi
{
    private readonly ChatContext _ctx;
    private readonly ChatComposer _c;
    /// [WIN-MEMO-SEND-WIRE] The chat's memo send (the draft chip's Send, the recorder's take, the refusal's card).
    private readonly ComposerMemo _memo;
    private readonly DispatcherQueue _ui;
    private readonly QueueCard _queue;
    private readonly DrawerView _drawer = new();
    private readonly TextBlock _notice = Ui.Text("", 12, secondary: true);
    private readonly Border _noticeBox;
    private readonly Border _editStrip;
    private readonly Button _commands;

    private readonly DispatcherQueueTimer _noticeTimer;
    private readonly DispatcherQueueTimer _drawerTimer;
    private readonly CompletionGate _gate = new();
    private readonly CompletionMemory _memory = new();
    private MenuFlyoutItem? _modelItem, _promptsItem, _usageItem, _pricesItem;
    private CommandsCatalog? _catalog;
    private bool _catalogLoading, _catalogFailed;
    private string? _editingId;
    private string _setAside = "";
    private IReadOnlyList<ComposerDrawer.Section>? _atShown;

    /// [WIN-SCREEN-SETUP-SEND] Each open chat page's composer, so "Set up with Hermes" (Features/Screen/ScreenSetupHost.cs)
    /// sends through this chat's own queue rather than a second one.
    private static readonly System.Runtime.CompilerServices.ConditionalWeakTable<Page, ComposerController> Live = new();
    internal static ComposerController? For(Page page) => Live.TryGetValue(page, out var c) ? c : null;
    internal ChatComposer Composer => _c;
    /// The chat's status line over "Replying…" (null gives it back).
    internal void SetStatus(string? words) => _ctx.SetStatus(words);

    public ComposerController(ChatContext ctx)
    {
        _ctx = ctx;
        Live.AddOrUpdate(ctx.Page, this);
        _ui = ctx.Page.DispatcherQueue;
        _c = new ChatComposer(ctx.Session, ComposerServices.Prefs(ctx.Session.Client.AccountId));
        _memo = new ComposerMemo(ctx, _c, MemoApp.Stores, MemoApp.Controller, MemoApp.Player, SetText,
            text => SwitchNotice(text, TimeSpan.FromSeconds(5), false));
        _noticeTimer = _ui.CreateTimer();
        _noticeTimer.IsRepeating = false;
        _noticeTimer.Tick += (_, _) => HideSwitchNotice();
        _drawerTimer = _ui.CreateTimer();
        _drawerTimer.IsRepeating = false;
        _drawerTimer.Interval = TimeSpan.FromMilliseconds(120);
        _drawerTimer.Tick += (_, _) => AskDrawer();

        // ☰ first in the box (the + the attachments feature adds goes after it), the model chip before mic and voice.
        _commands = Ui.Quiet(Ui.Glyph("", 16), "Commands", (_, _) => ShowCommands());
        _commands.VerticalAlignment = VerticalAlignment.Bottom;
        ctx.ComposerLeading.Children.Insert(0, _commands);
        ctx.OpenModelPicker = () => ShowModels(null);

        // The shelf: the switch notice, the queue card, the edit strip, then the drawer nearest the box.
        _noticeBox = new Border { Child = _notice, Padding = new Thickness(4, 0, 4, 0), Visibility = Visibility.Collapsed };
        _queue = new QueueCard(_c.Queue, () => _c.Running) { OnEdit = BeginEdit };
        _editStrip = EditStrip();
        ctx.Shelf.Children.Add(_noticeBox);
        ctx.Shelf.Children.Add(_queue.View);
        ctx.Shelf.Children.Add(_editStrip);
        ctx.Shelf.Children.Add(_drawer.View);
        _drawer.OnPick = PickDrawerRow;
        _drawer.IsFavorite = c => _c.Prefs.FavoriteCommands.Contains(SlashCatalog.Normalize(c));
        _drawer.ToggleFavorite = c => { _c.Prefs.ToggleFavoriteCommand(c); UpdateDrawer(); };

        AddMenuItems();
        ctx.SendHandler = OnSend;
        ctx.ComposerKeys.Add(OnKey);
        ctx.Composer.TextChanged += OnTextChanged;
        ctx.Composer.SelectionChanged += OnTextChanged;

        _c.Hooks.Prefill = text => Enqueue(() => SetText(text));
        _c.Hooks.OpenModels = q => Enqueue(() => ShowModels(q));
        _c.Hooks.OpenCommands = () => Enqueue(ShowCommands);
        _c.Hooks.Alert = (t, m) => Enqueue(() => _ = Ui.Alert(ctx.Page.XamlRoot, t, m));
        _c.Hooks.NewChat = StartNewChat;
        HermesHQ.Controls.MessageView.ChooseModelRequested += OnChooseModelRequested;
        _c.StateChanged += Refresh;
        _c.Queue.Changed += Refresh;
        _c.Notice += text => Enqueue(() => SwitchNotice(text, TimeSpan.FromSeconds(5), false));
        ctx.Session.Changed += Refresh;
        ctx.Closed += Close;
        RefreshNow();
        _c.WarmUp();
    }

    private bool _closed;

    private void Enqueue(Action run)
    {
        if (_closed || AppShutdown.Stopping) return;
        _ui.TryEnqueue(() => { if (!_closed && !AppShutdown.Stopping) run(); });
    }

    /// `/new [words]` (3x-composer §8.2): a new chat with this chat's bot, made as Bots › New Chat makes one
    /// (`SessionStore.NewChatAsync`), opened in this chat's place with the words in its box; nothing goes to this chat.
    /// False (the dispatcher's “Couldn’t start a new chat with this bot.”): signed out or a bot the roster doesn't have.
    private bool StartNewChat(string arg)
    {
        if (Features.Bots.ListsHub.Current is not { } hub) return false;
        var root = _ctx.Page.XamlRoot;
        return NewChatCommand.Start(_ctx.Session.Profile, arg, p => hub.Bots.Bot(p) != null, p => hub.Sessions.NewChatAsync(p),
            o => _ui.TryEnqueue(() => Navigator.Go(new ChatDestination(o.Profile, o.StoredId, NewChatCommand.Title, o.Draft))),
            e => _ui.TryEnqueue(() =>
            {
                var title = e is Hermes.Core.Bots.BotWriteException { Title.Length: > 0 } w ? w.Title : "Couldn’t Start a New Chat";
                var reason = e is Hermes.Core.Bots.BotWriteException b ? b.Reason : Hermes.Core.Sessions.SessionStore.ReasonOf(e);
                _ = Features.Bots.Prompts.FailureAsync(root, title, reason, () => { StartNewChat(arg); return Task.CompletedTask; });
            })) != null;
    }

    private void Close()
    {
        _closed = true;
        if (For(_ctx.Page) == this) Live.Remove(_ctx.Page);
        HermesHQ.Controls.MessageView.ChooseModelRequested -= OnChooseModelRequested;
        _ctx.Session.Changed -= Refresh;
        _ctx.Composer.TextChanged -= OnTextChanged;
        _ctx.Composer.SelectionChanged -= OnTextChanged;
        _noticeTimer.Stop();
        _drawerTimer.Stop();
        _memo.Dispose();
        _c.Dispose();
    }

    private void Refresh() => Enqueue(RefreshNow);

    private void RefreshNow()
    {
        _queue.Update();
        var current = _c.Current();
        _ctx.SetModelChip(current.Id.Length != 0 ? current.Name : _c.Options != null ? "Model" : null);
    }

    // ------------------------------------------------------------------ sending and keys

    private bool OnSend(string text)
    {
        var trimmed = ComposerText.SendText(text);
        if (_editingId != null)
        {
            if (trimmed.Length > 0) SaveEdit(trimmed);
            return false; // SaveEdit set the box itself
        }
        // A memo showing (the recorder's locked or review take, or the draft chip) goes with the field's words.
        if (_memo.PrimarySend())
        {
            _drawer.Close();
            return true;
        }
        if (trimmed.Length == 0)
        {
            _c.Queue.EmptyReturnNow();
            if (ComposerText.IsLeftoverLineBreaks(text)) SetText("");
            return false;
        }
        _drawer.Close();
        _c.Send(text);
        return true;
    }

    private static bool Down(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    private bool OnKey(KeyRoutedEventArgs e)
    {
        if (_drawer.IsOpen)
        {
            switch (e.Key)
            {
                case VirtualKey.Down: _drawer.Move(1); return true;
                case VirtualKey.Up: _drawer.Move(-1); return true;
                case VirtualKey.Escape: _drawer.Close(); return true;
                case VirtualKey.Tab when _drawer.Marked is { } tabbed: PickDrawerRow(tabbed); return true;
                case VirtualKey.Enter when !Down(VirtualKey.Shift) && !Down(VirtualKey.Control) && _drawer.Marked is { } row:
                    PickDrawerRow(row);
                    return true;
            }
        }
        if (e.Key == VirtualKey.Escape && _editingId != null) { CancelEdit(); return true; }
        // Ctrl+Enter (the Mac's ⌘Return): this send waits in the queue behind a running reply instead of going into it.
        if (e.Key == VirtualKey.Enter && Down(VirtualKey.Control) && _editingId == null)
        {
            var text = _ctx.Composer.Text;
            // The draft chip waits in the queue the same way (the next SendMemo reads QueuesNextSend).
            if (_memo.HasDraft)
            {
                _c.Queue.QueuesNextSend = true;
                if (_memo.PrimarySend()) { _drawer.Close(); SetText(""); return true; }
                _c.Queue.QueuesNextSend = false;
            }
            if (ComposerText.SendText(text).Length == 0) return true;
            _drawer.Close();
            _c.Send(text, queue: true);
            SetText("");
            return true;
        }
        return false;
    }

    private void SetText(string text)
    {
        _ctx.Composer.Text = text;
        _ctx.Composer.SelectionStart = text.Length;
        _ctx.Composer.Focus(FocusState.Programmatic);
    }

    // ------------------------------------------------------------------ the drawers

    private void OnTextChanged(object sender, RoutedEventArgs e) => UpdateDrawer();

    private ComposerDrawer.Mode CurrentMode() =>
        _editingId != null ? new ComposerDrawer.Mode.Closed()
            : ComposerDrawer.ModeFor(_ctx.Composer.Text, _ctx.Composer.SelectionStart + _ctx.Composer.SelectionLength);

    private void UpdateDrawer()
    {
        var mode = CurrentMode();
        switch (mode)
        {
            case ComposerDrawer.Mode.Slash s:
                if (_catalog == null && !_catalogLoading) LoadCatalog(fresh: _catalogFailed);
                var hasArgs = s.Text.Length > 1 && s.Text.Skip(1).Any(char.IsWhiteSpace);
                var key = "slash|" + s.Text;
                var remote = s.Text.Length > 1 ? _memory.Answer(key) : null;
                _drawer.Show(ComposerDrawer.SlashSections(s.Text, _catalog, _catalogLoading, _catalogFailed, false, remote, [],
                    _c.Prefs.FavoriteCommands), mode.MarksFirstMatch);
                if (s.Text.Length > 1 && (hasArgs || _catalog != null) && _memory.WantsAsk(key)) Want(key);
                else _gate.Clear();
                break;
            case ComposerDrawer.Mode.Skill k:
                _gate.Clear();
                _drawer.Show(ComposerDrawer.SkillSections(k.Word, k.Start, k.Length, _catalog, false), false);
                break;
            case ComposerDrawer.Mode.At a:
                var atKey = "path|@" + a.Word;
                var answer = _memory.Answer(atKey);
                var waiting = a.Word.Length > 0 && (_memory.WantsAsk(atKey) || _gate.InFlight == atKey);
                _atShown = ComposerDrawer.AtSections(a.Word, a.Start, a.Length, [], _ctx.Session.Profile, answer, waiting,
                    _memory.Failed(atKey) || _c.Offline, false, _atShown);
                _drawer.Show(_atShown, false);
                if (a.Word.Length > 0 && _memory.WantsAsk(atKey)) Want(atKey);
                break;
            default:
                _gate.Clear();
                _atShown = null;
                _drawer.Close();
                break;
        }
    }

    private void Want(string key)
    {
        _gate.Want(key);
        _drawerTimer.Stop();
        _drawerTimer.Start();
    }

    private void AskDrawer()
    {
        if (_c.Offline || _gate.Next() is not { } key) return;
        _ = Task.Run(async () =>
        {
            try
            {
                var answer = key.StartsWith("slash|", StringComparison.Ordinal)
                    ? await _c.CompleteSlashAsync(key["slash|".Length..])
                    : await _c.CompletePathAsync(key["path|".Length..]);
                _ui.TryEnqueue(() =>
                {
                    _memory.Remember(key, answer);
                    if (_gate.Finished(key)) UpdateDrawer();
                    AskDrawer();
                });
            }
            catch (Exception x) when (x is GatewayException or OperationCanceledException)
            {
                _ui.TryEnqueue(() =>
                {
                    _memory.Fail(key);
                    if (_gate.Finished(key)) UpdateDrawer();
                    AskDrawer();
                });
            }
        });
    }

    private void LoadCatalog(bool fresh)
    {
        _catalogLoading = true;
        _ = Task.Run(async () =>
        {
            CommandsCatalog? catalog = null;
            try { catalog = await _c.LoadCommandsAsync(fresh); }
            catch (GatewayException x) { AppLog.Note("composer", $"commands catalog: {x.Code}"); }
            _ui.TryEnqueue(() =>
            {
                _catalog = catalog ?? _catalog;
                _catalogLoading = false;
                _catalogFailed = catalog == null;
                UpdateDrawer();
            });
        });
    }

    private void PickDrawerRow(ComposerDrawer.Row row)
    {
        var text = _ctx.Composer.Text;
        switch (row.Action)
        {
            case ComposerDrawer.RowAction.Command c:
                PickCommand(new CommandRow(c.Name, row.Detail, c.Skill), fromDrawer: true);
                break;
            case ComposerDrawer.RowAction.Option o:
                var (edit, keepOpen) = ComposerDrawer.ApplyOption(o.Prefix, o.Text);
                SetText(edit.Text);
                if (!keepOpen) _drawer.Close();
                break;
            case ComposerDrawer.RowAction.SkillPick s:
                Apply(ComposerDrawer.ApplyMention(s.Name, s.Start, s.Length, text));
                break;
            case ComposerDrawer.RowAction.Mention m:
                Apply(ComposerDrawer.ApplyMention(m.Text, m.Start, m.Length, text));
                break;
            case ComposerDrawer.RowAction.CheckAgain:
                LoadCatalog(fresh: true);
                break;
        }
    }

    private void Apply(ComposerDrawer.Edit edit)
    {
        _ctx.Composer.Text = edit.Text;
        _ctx.Composer.SelectionStart = Math.Min(edit.Caret, edit.Text.Length);
        _ctx.Composer.Focus(FocusState.Programmatic);
    }

    /// What a command pick does (☰ or the drawer): a skill or a command that takes more puts "/cmd " in the box; /model
    /// opens the Models list; anything else sends (a few ask first).
    public async void PickCommand(CommandRow row, bool fromDrawer)
    {
        switch (SlashCatalog.PickActionFor(row, _catalog ?? _c.LatestCommands))
        {
            case PickAction.Models:
                SetText("");
                ShowModels(null);
                return;
            case PickAction.Insert:
                SetText(row.Command + " ");
                return;
        }
        if (SlashCatalog.Confirmation(row.Command, _c.ModelState.Yolo) is { } ask)
        {
            var result = await Ui.Show(_ctx.Page.XamlRoot, new ContentDialog
            {
                Title = ask.Title, Content = Ui.Text(ask.Message), PrimaryButtonText = ask.Button, CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Close,
            });
            if (result != ContentDialogResult.Primary) return;
        }
        if (fromDrawer) SetText("");
        _drawer.Close();
        _c.Send(row.Command);
    }

    // ------------------------------------------------------------------ Edit on a queued message (spec §15.5)

    private Border EditStrip()
    {
        var grid = new Grid { ColumnSpacing = 6 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var label = Ui.Text("Editing Queued Message", 13, bold: true, wrap: false);
        label.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(label);
        var cancel = new Button { Content = "Cancel" };
        cancel.Click += (_, _) => CancelEdit();
        Grid.SetColumn(cancel, 1);
        grid.Children.Add(cancel);
        var save = new Button { Content = "Save", Style = Ui.Res<Style>("AccentButtonStyle") };
        save.Click += (_, _) =>
        {
            var text = ComposerText.SendText(_ctx.Composer.Text);
            if (text.Length > 0) SaveEdit(text);
        };
        Grid.SetColumn(save, 2);
        grid.Children.Add(save);
        return new Border
        {
            Child = grid, Padding = new Thickness(12, 6, 6, 6), CornerRadius = new CornerRadius(10),
            Background = Ui.Res<Brush>("SubtleFillColorSecondaryBrush"), Visibility = Visibility.Collapsed,
        };
    }

    private void BeginEdit(string id)
    {
        if (_editingId != null) CancelEdit();
        if (_c.Queue.BeginEdit(id) is not { } words) return;
        _editingId = id;
        _setAside = _ctx.Composer.Text;
        _editStrip.Visibility = Visibility.Visible;
        _drawer.Close();
        SetText(words);
    }

    private void EndEditStrip()
    {
        _editingId = null;
        _editStrip.Visibility = Visibility.Collapsed;
    }

    private void CancelEdit()
    {
        if (_editingId == null) return;
        EndEditStrip();
        _c.Queue.EndEdit();
        SetText(_setAside);
    }

    private void SaveEdit(string text)
    {
        if (_editingId is not { } id) return;
        EndEditStrip();
        var saved = _c.Queue.SaveEdit(id, text);
        // The row went meanwhile: the words stay in the box, over the set-aside draft.
        SetText(saved ? _setAside : QueueWords.EditedField(text, _setAside));
    }

    // ------------------------------------------------------------------ ⋯ rows

    private void AddMenuItems()
    {
        var menu = _ctx.MoreMenu;
        _modelItem = new MenuFlyoutItem { Text = "Model", Icon = Ui.Glyph("") };
        _modelItem.Click += (_, _) => ShowModels(null);
        _promptsItem = new MenuFlyoutItem { Text = PromptLibrary.Title, Icon = Ui.Glyph("") };
        _promptsItem.Click += (_, _) => _ = PromptsDialog.ShowAsync(_ctx.Page.XamlRoot, ComposerServices.Prompts, _ctx.Composer);
        _usageItem = new MenuFlyoutItem { Text = UsageLimitsModel.Title, Icon = Ui.Glyph("") };
        _usageItem.Click += (_, _) => _ = UsageDialog.ShowAsync(_ctx.Page.XamlRoot, _c);
        _pricesItem = new MenuFlyoutItem { Text = ModelPricesModel.Title, Icon = Ui.Glyph("") };
        _pricesItem.Click += (_, _) => _ = PricesDialog.ShowAsync(_ctx.Page.XamlRoot, _c);
        // The Mac's sections: the chat itself (Model first), then its tools (Prompts, Usage & Limits, Model Prices).
        menu.Items.Add(_modelItem);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(_promptsItem);
        menu.Items.Add(_usageItem);
        menu.Items.Add(_pricesItem);
        menu.Opening += (_, _) => UpdateMenuItems();
    }

    /// Every open reads the current state with no network wait; the catalog is warmed for the next one.
    private void UpdateMenuItems()
    {
        _c.WarmUp();
        var node = ModelMenuModel.Build(_c.MenuInput());
        var current = _c.Current();
        var offline = _c.Offline;
        _modelItem!.KeyboardAcceleratorTextOverride = node.Subtitle;
        _promptsItem!.KeyboardAcceleratorTextOverride = ComposerServices.Prompts.MenuSubtitle ?? "";
        _usageItem!.KeyboardAcceleratorTextOverride = offline ? "Offline" : UsageLimitsModel.MenuSubtitle(_c.Options, current.Provider) ?? "";
        _pricesItem!.KeyboardAcceleratorTextOverride = offline ? "Offline"
            : ModelPricesModel.MenuSubtitle(_c.Options, current.Id, current.Provider, ComposerServices.ModelsDev.Stored()) ?? "";
        _usageItem.IsEnabled = !offline;
        _pricesItem.IsEnabled = !offline;
    }

    // ------------------------------------------------------------------ panels

    private void ShowCommands()
    {
        var panel = new CommandsPanel(_c, row => PickCommand(row, fromDrawer: false));
        var flyout = new Flyout { Content = panel.View, Placement = FlyoutPlacementMode.TopEdgeAlignedLeft };
        flyout.Opened += (_, _) => panel.Focus();
        panel.Done = flyout.Hide;
        flyout.ShowAt(_commands);
    }

    private void OnChooseModelRequested(Hermes.Core.Chat.ChatSession? session)
    {
        if (ReferenceEquals(session, _ctx.Session)) ShowModels(null);
    }

    private void ShowModels(string? query) => _ = ModelsDialog.ShowAsync(_ctx.Page.XamlRoot, _c, this, query);

    // ------------------------------------------------------------------ IModelSwitchUi

    public Task<bool> ConfirmModelChange(string message)
    {
        if (_closed || AppShutdown.Stopping) return Task.FromResult(false);
        var done = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var queued = _ui.TryEnqueue(async () =>
        {
            try
            {
                if (_closed || AppShutdown.Stopping) { done.TrySetResult(false); return; }
                var result = await Ui.Show(_ctx.Page.XamlRoot, new ContentDialog
                {
                    Title = "Change Model?", Content = message.Length == 0 ? null : Ui.Text(message),
                    PrimaryButtonText = "Change Model", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary,
                });
                done.TrySetResult(result == ContentDialogResult.Primary);
            }
            catch (Exception) { done.TrySetResult(false); }
        });
        if (!queued) done.TrySetResult(false);
        return done.Task;
    }

    public void ModelChangeFailed(string reason) =>
        Enqueue(() => _ = Ui.Alert(_ctx.Page.XamlRoot, "Couldn’t Change Model", reason));

    public void SwitchNotice(string text, TimeSpan? duration, bool spinner) => Enqueue(() =>
    {
        _notice.Text = text;
        _noticeBox.Visibility = Visibility.Visible;
        _noticeTimer.Stop();
        if (duration is { } d)
        {
            _noticeTimer.Interval = d;
            _noticeTimer.Start();
        }
    });

    public void HideSwitchNotice() => Enqueue(() =>
    {
        _noticeTimer.Stop();
        _noticeBox.Visibility = Visibility.Collapsed;
    });
}
