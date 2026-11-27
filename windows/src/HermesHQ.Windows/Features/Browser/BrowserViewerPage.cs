// Watch Browser viewer page (C# twin of App/Browser/BrowserViewerController.swift's UI, matching
// Features/Screen/ScreenViewerPage.cs): header bar (title, Tabs dropdown, Browser Settings, Close), address bar,
// orange-striped Ask card, live stage with empty/setup overlay + "No Page Open" note + notice/hint pills, responsive
// control bar (Watch / Waiting / SomeoneElse / Mine / LastPage), hidden BrowserKeyField, and page dialog / popups
// update ContentDialogs.

using Hermes.Core.Browser;
using Hermes.Core.Screen;
using HermesHQ.Features.Capabilities;
using HermesHQ.Features.Settings;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;
using Windows.UI;
using Kit = HermesHQ.Features.Capabilities.Kit;

namespace HermesHQ.Features.Browser;

public sealed class BrowserViewerPage : Grid, IBrowserViewerHost, IDisposable
{
    private static readonly SolidColorBrush AskOrange = new(Color.FromArgb(0xFF, 0xF7, 0x63, 0x0C));
    private static readonly SolidColorBrush AskTint = new(Color.FromArgb(0x1E, 0xF7, 0x63, 0x0C));

    public BrowserViewerController Viewer { get; private set; } = null!;
    public BrowserViewerState? Last { get; private set; }
    public Action? OnDismiss { get; set; }
    public Action? OnOpenSettings { get; set; }

    private BrowserStageView _stage = null!;
    private readonly TextBlock _title = new()
    {
        FontSize = 15,
        FontWeight = FontWeights.SemiBold,
        TextTrimming = TextTrimming.CharacterEllipsis,
        VerticalAlignment = VerticalAlignment.Center,
    };
    private readonly DropDownButton _tabsButton;
    private readonly MenuFlyout _tabsMenu = new();
    private readonly Button _settingsButton;
    private readonly Button _closeButton;
    private readonly BrowserAddressField _addressField = new();

    private readonly Border _askCard;
    private readonly TextBlock _askTitle = new() { FontSize = 13, FontWeight = FontWeights.SemiBold };
    private readonly TextBlock _askBody = new() { FontSize = 13, TextWrapping = TextWrapping.Wrap };

    private readonly Grid _content = new();
    private readonly Grid _emptyPanel = new() { Visibility = Visibility.Collapsed };
    private readonly ProgressRing _emptySpinner = new() { Width = 32, Height = 32, Visibility = Visibility.Collapsed };
    private readonly FontIcon _emptyIcon = new() { Glyph = "\uE774", FontSize = 36, Visibility = Visibility.Collapsed };
    private readonly TextBlock _emptyTitle = CentredText(19, bold: true);
    private readonly TextBlock _emptyBody = CentredText(14, bold: false);
    private readonly Button _emptyAction = new() { MinHeight = 44, HorizontalAlignment = HorizontalAlignment.Stretch, Visibility = Visibility.Collapsed };
    private readonly TextBlock _emptyProblem = CentredText(13, bold: false);

    private readonly Border _blankNote;
    private readonly TextBlock _blankTitle = CentredText(18, bold: true);
    private readonly TextBlock _blankBody = CentredText(14, bold: false);

    private readonly Border _noticePill;
    private readonly TextBlock _noticeText = new() { FontSize = 13, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, MaxLines = 3 };
    private readonly Border _hintPill;
    private readonly TextBlock _hintText = new() { FontSize = 13, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, MaxLines = 3 };

    private readonly StackPanel _barContainer = new() { Padding = new Thickness(16, 8, 16, 10), Spacing = 6, Visibility = Visibility.Collapsed };
    private readonly TextBlock _barCaption = new() { FontSize = 13, TextWrapping = TextWrapping.Wrap, HorizontalAlignment = HorizontalAlignment.Center, TextAlignment = TextAlignment.Center };
    private readonly Grid _barControlRow = new();
    private readonly Button _takeButton;
    private readonly StackPanel _waitingRow;
    private readonly ProgressRing _waitingSpinner = new() { Width = 16, Height = 16, IsActive = false };
    private readonly TextBlock _waitingText = new() { FontSize = 13, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _cancelTakeButton;

    private readonly Grid _mineBar = new() { Visibility = Visibility.Collapsed };
    private readonly StackPanel _mineIcons = new() { Orientation = Orientation.Horizontal, Spacing = BrowserBarLayout.Spacing };
    private readonly Button _backButton;
    private readonly Button _forwardButton;
    private readonly Button _reloadButton;
    private readonly Button _keyboardButton;
    private readonly Button _clipboardButton;
    private readonly Button _giveButton;

    private readonly BrowserKeyField _keyField = new();

    private ContentDialog? _activePageDialog;
    private bool _programmaticDialogHide;
    private bool _disposed;

    public BrowserViewerPage()
    {
        AutomationProperties.SetAutomationId(this, "browser.page");
        Background = ThemeService.BrushFor("HQPageBrush");

        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // 0: header
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // 1: address bar
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // 2: ask card
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) }); // 3: stage + overlays
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // 4: control bar

        // Header bar
        var header = new Grid { Padding = new Thickness(16, 8, 8, 6), ColumnSpacing = 6 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        AutomationProperties.SetHeadingLevel(_title, AutomationHeadingLevel.Level1);
        AutomationProperties.SetAutomationId(_title, "browser.title");
        header.Children.Add(_title);

        _tabsButton = new DropDownButton
        {
            Content = "Tabs",
            Flyout = _tabsMenu,
            MinHeight = 34,
            Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetName(_tabsButton, "Tabs");
        AutomationProperties.SetAutomationId(_tabsButton, "browser.tabs");
        Grid.SetColumn(_tabsButton, 1);
        header.Children.Add(_tabsButton);

        _settingsButton = IconButton("\uE713", "Browser Settings", "browser.settings");
        _settingsButton.Click += (_, _) => OnOpenSettings?.Invoke();
        Grid.SetColumn(_settingsButton, 2);
        header.Children.Add(_settingsButton);

        _closeButton = IconButton("\uE711", "Close", "browser.close");
        _closeButton.Click += (_, _) => Viewer?.Close();
        Grid.SetColumn(_closeButton, 3);
        header.Children.Add(_closeButton);
        Children.Add(header);

        // Address bar
        _addressField.Margin = new Thickness(16, 0, 16, 8);
        _addressField.Visibility = Visibility.Collapsed;
        Grid.SetRow(_addressField, 1);
        Children.Add(_addressField);

        // Ask card
        var askGrid = new Grid { ColumnSpacing = 10 };
        askGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(4) });
        askGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        askGrid.Children.Add(new Border { Background = AskOrange, CornerRadius = new CornerRadius(2) });
        var askWords = new StackPanel { Spacing = 2, Padding = new Thickness(0, 2, 0, 2) };
        _askTitle.Foreground = AskOrange;
        _askBody.Foreground = Kit.Primary;
        askWords.Children.Add(_askTitle);
        askWords.Children.Add(_askBody);
        Grid.SetColumn(askWords, 1);
        askGrid.Children.Add(askWords);

        _askCard = new Border
        {
            Child = askGrid,
            Background = AskTint,
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(10, 8, 12, 8),
            Margin = new Thickness(16, 0, 16, 8),
            Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetAutomationId(_askCard, "browser.ask");
        Grid.SetRow(_askCard, 2);
        Children.Add(_askCard);

        // Content grid (stage, empty panel, blank note, notices)
        Grid.SetRow(_content, 3);
        Children.Add(_content);

        // Empty / setup panel
        _emptyPanel.Background = ThemeService.BrushFor("HQPageBrush");
        _emptyIcon.Foreground = Kit.Secondary;
        _emptyBody.Foreground = Kit.Secondary;
        _emptyProblem.Foreground = Kit.Critical;
        _emptyProblem.Visibility = Visibility.Collapsed;
        _emptyAction.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        _emptyAction.Click += (_, _) => Viewer?.RunEmptyAction();
        AutomationProperties.SetAutomationId(_emptyAction, "browser.empty.action");

        var emptyStack = new StackPanel
        {
            MaxWidth = 420,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(28, 20, 28, 20),
            Spacing = 10,
        };
        emptyStack.Children.Add(_emptySpinner);
        emptyStack.Children.Add(_emptyIcon);
        emptyStack.Children.Add(_emptyTitle);
        emptyStack.Children.Add(_emptyBody);
        emptyStack.Children.Add(_emptyAction);
        emptyStack.Children.Add(_emptyProblem);
        _emptyPanel.Children.Add(new ScrollViewer { Content = emptyStack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });

        // Blank note overlay ("No Page Open")
        _blankTitle.Text = "No Page Open";
        _blankBody.Foreground = Kit.Secondary;
        var blankStack = new StackPanel { Spacing = 6, MaxWidth = 340 };
        blankStack.Children.Add(_blankTitle);
        blankStack.Children.Add(_blankBody);
        _blankNote = new Border
        {
            Child = blankStack,
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(20, 16, 20, 16),
            Background = Kit.Brush("AcrylicInAppFillColorDefaultBrush"),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
            IsHitTestVisible = false,
        };
        AutomationProperties.SetAutomationId(_blankNote, "browser.blank");

        // Notice (top pill) & Hint (bottom pill)
        _noticePill = new Border
        {
            Child = _noticeText,
            CornerRadius = new CornerRadius(18),
            Padding = new Thickness(14, 8, 14, 8),
            Background = Kit.Brush("AcrylicInAppFillColorDefaultBrush"),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(16, 12, 16, 0),
            Visibility = Visibility.Collapsed,
            IsHitTestVisible = false,
        };
        AutomationProperties.SetAutomationId(_noticePill, "browser.notice");

        _hintPill = new Border
        {
            Child = _hintText,
            CornerRadius = new CornerRadius(18),
            Padding = new Thickness(14, 8, 14, 8),
            Background = Kit.Brush("AcrylicInAppFillColorDefaultBrush"),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(16, 0, 16, 12),
            Visibility = Visibility.Collapsed,
            IsHitTestVisible = false,
        };
        AutomationProperties.SetAutomationId(_hintPill, "browser.hint");

        // Bottom bar
        AutomationProperties.SetAutomationId(_barContainer, "browser.bar");
        _barCaption.Foreground = Kit.Secondary;
        AutomationProperties.SetAutomationId(_barCaption, "browser.caption");

        _takeButton = new Button
        {
            Content = ControlWords.Take,
            MinWidth = 140,
            MinHeight = 40,
            HorizontalAlignment = HorizontalAlignment.Center,
            Style = (Style)Application.Current.Resources["AccentButtonStyle"],
            Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetAutomationId(_takeButton, "browser.take");
        _takeButton.Click += (_, _) => Viewer?.TakeControl();

        _cancelTakeButton = new Button { Content = "Cancel", MinHeight = 36 };
        AutomationProperties.SetAutomationId(_cancelTakeButton, "browser.cancelTake");
        _cancelTakeButton.Click += (_, _) => Viewer?.CancelTake();

        _waitingRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 10,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };
        _waitingRow.Children.Add(_waitingSpinner);
        _waitingRow.Children.Add(_waitingText);
        _waitingRow.Children.Add(_cancelTakeButton);

        // Mine bar: Back, Forward, Reload, Keyboard, Clipboard + Give Back
        _backButton = BarIconButton("\uE72B", "Back", "browser.back", () => Viewer?.NavigateBack());
        _forwardButton = BarIconButton("\uE72A", "Forward", "browser.forward", () => Viewer?.NavigateForward());
        _reloadButton = BarIconButton("\uE72C", "Reload", "browser.reload", () => Viewer?.Reload());
        _keyboardButton = BarIconButton("\uE765", ControlWords.ShowKeyboard, "browser.keyboard", () => Viewer?.ToggleKeyboard());

        var clipMenu = new MenuFlyout();
        clipMenu.Items.Add(Kit.Item("Paste", "\uE77F", () => _ = Viewer?.PasteAsync()));
        clipMenu.Items.Add(Kit.Item("Copy", "\uE8C8", () => Viewer?.CopySelection()));
        clipMenu.Items.Add(Kit.Item("Select All", "\uE8B3", () => Viewer?.SelectAll()));

        _clipboardButton = new Button
        {
            Content = new FontIcon { Glyph = "\uE77F", FontSize = 15 },
            MinWidth = 40,
            MinHeight = 40,
            Flyout = clipMenu,
        };
        AutomationProperties.SetName(_clipboardButton, "Clipboard");
        AutomationProperties.SetAutomationId(_clipboardButton, "browser.clipboard");
        ToolTipService.SetToolTip(_clipboardButton, "Clipboard");

        _mineIcons.Children.Add(_backButton);
        _mineIcons.Children.Add(_forwardButton);
        _mineIcons.Children.Add(_reloadButton);
        _mineIcons.Children.Add(_keyboardButton);
        _mineIcons.Children.Add(_clipboardButton);

        _giveButton = new Button
        {
            Content = ControlWords.Give,
            MinWidth = 112,
            MinHeight = 40,
        };
        AutomationProperties.SetAutomationId(_giveButton, "browser.give");
        _giveButton.Click += (_, _) => Viewer?.GiveBack();

        _mineBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _mineBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _mineBar.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _mineBar.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _mineBar.RowSpacing = BrowserBarLayout.Spacing;
        _mineBar.Children.Add(_mineIcons);
        _mineBar.Children.Add(_giveButton);

        _barControlRow.Children.Add(_takeButton);
        _barControlRow.Children.Add(_waitingRow);
        _barControlRow.Children.Add(_mineBar);

        _barContainer.Children.Add(_barCaption);
        _barContainer.Children.Add(_barControlRow);
        Grid.SetRow(_barContainer, 4);
        Children.Add(_barContainer);

        // Hidden keyboard catcher
        Children.Add(_keyField);

        SizeChanged += (_, _) => LayoutMineBar();
    }

    public void Attach(BrowserViewerController viewer)
    {
        Viewer = viewer;
        _stage = new BrowserStageView(viewer.Stage, viewer.Name)
        {
            OnLayoutChanged = () => viewer.LayoutChanged(),
        };

        _content.Children.Clear();
        _content.Children.Add(_stage);
        _content.Children.Add(_blankNote);
        _content.Children.Add(_emptyPanel);
        _content.Children.Add(_noticePill);
        _content.Children.Add(_hintPill);

        _addressField.OnTryBeginEdit = () =>
        {
            var ok = viewer.TryBeginAddressEdit(out var fullUrl);
            return (ok, fullUrl);
        };
        _addressField.OnCommit = typed => viewer.CommitAddress(typed);
        _addressField.OnCancel = () => viewer.EndAddressEdit();

        _keyField.OnText = text => viewer.KeyText(text);
        _keyField.OnKey = key => viewer.KeyPress(key);
        _keyField.OnCopyShortcut = () => viewer.CopySelection();
        _keyField.OnPasteShortcut = () => _ = viewer.PasteAsync();
        _keyField.OnSelectAllShortcut = () => viewer.SelectAll();
        _keyField.OnFocusChanged = focused => viewer.KeyboardFocusChanged(focused);
        _keyField.OnRequestFocusClear = () => Focus(FocusState.Programmatic);

        viewer.Load();
    }

    /// Window-level shortcut handler (Ctrl+W, Escape, Ctrl+L, Ctrl+R, F5, Alt+Left/Right).
    public bool HandleWindowKey(VirtualKey key, bool ctrl, bool alt)
    {
        if (Viewer == null) return false;
        if (ctrl && !alt && key == VirtualKey.W)
        {
            Viewer.Close();
            return true;
        }
        if (key == VirtualKey.Escape)
        {
            Viewer.Escape();
            return true;
        }
        if (ctrl && !alt && key == VirtualKey.L && Viewer.State.AddressVisible)
        {
            _addressField.FocusForEdit();
            return true;
        }
        if (Viewer.State.Mine)
        {
            if ((ctrl && !alt && key == VirtualKey.R) || (!ctrl && !alt && key == VirtualKey.F5))
            {
                Viewer.Reload();
                return true;
            }
            if (alt && !ctrl && key == VirtualKey.Left)
            {
                Viewer.NavigateBack();
                return true;
            }
            if (alt && !ctrl && key == VirtualKey.Right)
            {
                Viewer.NavigateForward();
                return true;
            }
        }
        return false;
    }

    // ------------------------------------------------------------------ IBrowserViewerHost

    public void Render(BrowserViewerState state)
    {
        if (_disposed) return;
        Last = state;
        _title.Text = state.Title;

        // Tabs menu
        RenderTabs(state);

        // Address bar
        _addressField.Visibility = state.AddressVisible ? Visibility.Visible : Visibility.Collapsed;
        _addressField.SetSite(state.AddressText, state.AddressSecure, state.EditingAddress);

        // Ask card
        _askCard.Visibility = state.AskVisible ? Visibility.Visible : Visibility.Collapsed;
        _askTitle.Text = state.AskTitle;
        _askBody.Text = state.AskBody;

        // Stage & empty panel
        if (_stage != null)
        {
            _stage.Visibility = state.StageHidden ? Visibility.Collapsed : Visibility.Visible;
            _stage.Place();
        }
        if (state.Empty is { } empty)
        {
            _emptyPanel.Visibility = Visibility.Visible;
            _emptySpinner.Visibility = empty.Spinner ? Visibility.Visible : Visibility.Collapsed;
            _emptySpinner.IsActive = empty.Spinner;
            _emptyIcon.Visibility = empty.Icon ? Visibility.Visible : Visibility.Collapsed;
            _emptyTitle.Text = empty.Title;
            _emptyTitle.Visibility = empty.Title.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            _emptyBody.Text = empty.Body;
            _emptyBody.Visibility = empty.Body.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            _emptyAction.Visibility = empty.ActionTitle != null ? Visibility.Visible : Visibility.Collapsed;
            _emptyAction.Content = empty.ActionTitle ?? "";
            _emptyAction.IsEnabled = empty.ActionEnabled;
            _emptyProblem.Text = empty.ProblemText ?? "";
            _emptyProblem.Visibility = !string.IsNullOrEmpty(empty.ProblemText) ? Visibility.Visible : Visibility.Collapsed;
        }
        else
        {
            _emptyPanel.Visibility = Visibility.Collapsed;
            _emptySpinner.IsActive = false;
        }

        // Blank note
        _blankNote.Visibility = state.BlankNoteVisible ? Visibility.Visible : Visibility.Collapsed;
        _blankBody.Text = state.BlankNoteBody;

        // Notices / hints
        _noticeText.Text = state.NoticeText ?? "";
        _noticePill.Visibility = !string.IsNullOrEmpty(state.NoticeText) ? Visibility.Visible : Visibility.Collapsed;
        _hintText.Text = state.HintText ?? "";
        _hintPill.Visibility = string.IsNullOrEmpty(state.NoticeText) && !string.IsNullOrEmpty(state.HintText)
            ? Visibility.Visible
            : Visibility.Collapsed;

        // Control bar
        RenderBar(state.Bar);
    }

    private void RenderTabs(BrowserViewerState state)
    {
        if (state.Tabs.Count == 0 || !state.Live)
        {
            _tabsButton.Visibility = Visibility.Collapsed;
            return;
        }
        _tabsButton.Visibility = Visibility.Visible;
        _tabsButton.Content = state.Tabs.Count == 1 ? "1 Tab" : $"{state.Tabs.Count} Tabs";
        _tabsMenu.Items.Clear();

        var followItem = new ToggleMenuFlyoutItem
        {
            Text = $"Follow {Viewer.Name}",
            IsChecked = state.Follow,
        };
        followItem.Click += (_, _) => Viewer?.FollowBot();
        _tabsMenu.Items.Add(followItem);
        _tabsMenu.Items.Add(new MenuFlyoutSeparator());

        foreach (var tab in state.Tabs)
        {
            var id = tab.Id;
            var host = BrowserAddress.Parse(tab.Url).Host;
            var label = string.IsNullOrWhiteSpace(tab.Title)
                ? (host.Length > 0 ? host : "New Tab")
                : tab.Title;
            var item = new ToggleMenuFlyoutItem
            {
                Text = label,
                IsChecked = !state.Follow && id == state.CurrentTabId,
            };
            item.Click += (_, _) => Viewer?.ShowTab(id);
            _tabsMenu.Items.Add(item);
        }
    }

    private void RenderBar(BrowserViewerBarState bar)
    {
        if (bar.Mode == BrowserViewerBarMode.None)
        {
            _barContainer.Visibility = Visibility.Collapsed;
            _waitingSpinner.IsActive = false;
            return;
        }
        _barContainer.Visibility = Visibility.Visible;
        _barCaption.Text = bar.Caption ?? "";
        _barCaption.Visibility = !string.IsNullOrEmpty(bar.Caption) ? Visibility.Visible : Visibility.Collapsed;

        _takeButton.Visibility = bar.Mode == BrowserViewerBarMode.Watch ? Visibility.Visible : Visibility.Collapsed;
        _takeButton.IsEnabled = bar.TakeEnabled;

        _waitingRow.Visibility = bar.Mode == BrowserViewerBarMode.Waiting ? Visibility.Visible : Visibility.Collapsed;
        _waitingSpinner.IsActive = bar.Mode == BrowserViewerBarMode.Waiting;
        _waitingText.Text = bar.WaitingText ?? "";

        _mineBar.Visibility = bar.Mode == BrowserViewerBarMode.Mine ? Visibility.Visible : Visibility.Collapsed;
        if (bar.Mode == BrowserViewerBarMode.Mine)
        {
            var icon = (FontIcon)_keyboardButton.Content;
            icon.Glyph = bar.Typing ? "\uE96A" : "\uE765";
            var kbName = bar.Typing ? ControlWords.HideKeyboard : ControlWords.ShowKeyboard;
            AutomationProperties.SetName(_keyboardButton, kbName);
            ToolTipService.SetToolTip(_keyboardButton, kbName);
            LayoutMineBar();
        }
    }

    private void LayoutMineBar()
    {
        if (_mineBar.Visibility != Visibility.Visible) return;
        var width = _barContainer.ActualWidth;
        var stacked = width > 0 && BrowserBarLayout.Stacks(accessibility: false, icons: 5 * 40, give: 112, width: width);
        if (stacked)
        {
            Grid.SetRow(_mineIcons, 0);
            Grid.SetColumn(_mineIcons, 0);
            Grid.SetColumnSpan(_mineIcons, 2);
            _mineIcons.HorizontalAlignment = HorizontalAlignment.Center;

            Grid.SetRow(_giveButton, 1);
            Grid.SetColumn(_giveButton, 0);
            Grid.SetColumnSpan(_giveButton, 2);
            _giveButton.HorizontalAlignment = HorizontalAlignment.Stretch;
        }
        else
        {
            Grid.SetRow(_mineIcons, 0);
            Grid.SetColumn(_mineIcons, 0);
            Grid.SetColumnSpan(_mineIcons, 1);
            _mineIcons.HorizontalAlignment = HorizontalAlignment.Left;

            Grid.SetRow(_giveButton, 0);
            Grid.SetColumn(_giveButton, 1);
            Grid.SetColumnSpan(_giveButton, 1);
            _giveButton.HorizontalAlignment = HorizontalAlignment.Right;
        }
    }

    public void ShowFrame(BrowserDecodedImage image, BrowserSize pageSize) => _stage?.Show(image, pageSize);
    public void ClearStage() => _stage?.Clear();
    public void Haptic(BrowserHaptic kind) { }

    public void Announce(string text)
    {
        if (string.IsNullOrEmpty(text)) return;
        var peer = FrameworkElementAutomationPeer.FromElement(_title) ?? FrameworkElementAutomationPeer.CreatePeerForElement(_title);
        peer?.RaiseNotificationEvent(AutomationNotificationKind.Other, AutomationNotificationProcessing.ImportantMostRecent, text, "browser");
    }

    public void CopyText(string text) => HermesHQ.Services.SafeClipboard.TrySetText(text);

    public async Task<string?> ReadClipboardAsync()
    {
        try
        {
            var view = Clipboard.GetContent();
            return view.Contains(StandardDataFormats.Text) ? await view.GetTextAsync() : null;
        }
        catch (Exception) { return null; }
    }

    public bool KeyboardFocused => _keyField.IsFocused;
    public BrowserKeyboardSlot? FocusedSlot => _keyField.FocusedSlot;
    public void RaiseKeyboard(BrowserKeyboardSlot slot, BrowserKeyboardKind kind) => _keyField.Raise(slot, kind);
    public void UpdateKeyboard(BrowserKeyboardKind kind) => _keyField.UpdateKind(kind);
    public void LowerKeyboard() => _keyField.Lower();
    public void TakeKeys() => Focus(FocusState.Programmatic);

    public (double Width, double Height, double Scale) StageMetrics => _stage?.Metrics ?? (0, 0, 1);

    public void ShowPageDialog(BrowserPageDialog dialog)
    {
        if (XamlRoot is not { } root || _disposed) return;
        _ = PresentPageDialogAsync(dialog, root);
    }

    private async Task PresentPageDialogAsync(BrowserPageDialog dialog, XamlRoot root)
    {
        DismissPageDialog();
        var answered = false;
        void Answer(bool accept, string? text = null, int? account = null)
        {
            if (answered) return;
            answered = true;
            Viewer?.AnswerDialog(dialog.Id, accept, text, account);
        }

        ContentDialog cd;
        TextBox? promptBox = null;

        switch (dialog.Kind)
        {
            case BrowserPageDialogKind.Alert:
                cd = new ContentDialog
                {
                    Title = dialog.Site ?? "Page Message",
                    Content = Kit.Text(dialog.Message, 14),
                    PrimaryButtonText = "OK",
                    DefaultButton = ContentDialogButton.Primary,
                };
                break;

            case BrowserPageDialogKind.Confirm:
                cd = new ContentDialog
                {
                    Title = dialog.Site ?? "Confirm",
                    Content = Kit.Text(dialog.Message, 14),
                    PrimaryButtonText = "OK",
                    CloseButtonText = "Cancel",
                    DefaultButton = ContentDialogButton.Primary,
                };
                break;

            case BrowserPageDialogKind.Prompt:
                promptBox = new TextBox { Text = dialog.DefaultText ?? "" };
                var promptStack = new StackPanel { Spacing = 10 };
                if (dialog.Message.Length > 0) promptStack.Children.Add(Kit.Text(dialog.Message, 14));
                promptStack.Children.Add(promptBox);
                cd = new ContentDialog
                {
                    Title = dialog.Site ?? "Prompt",
                    Content = promptStack,
                    PrimaryButtonText = "OK",
                    CloseButtonText = "Cancel",
                    DefaultButton = ContentDialogButton.Primary,
                };
                break;

            case BrowserPageDialogKind.Leave:
                cd = new ContentDialog
                {
                    Title = dialog.Site ?? "Leave Page?",
                    Content = Kit.Text(dialog.Message.Length > 0 ? dialog.Message : "Changes you made may not be saved.", 14),
                    PrimaryButtonText = "Leave",
                    CloseButtonText = "Stay",
                    DefaultButton = ContentDialogButton.Close,
                };
                break;

            case BrowserPageDialogKind.Accounts:
            {
                var list = new StackPanel { Spacing = 6 };
                if (dialog.Message.Length > 0) list.Children.Add(Kit.Text(dialog.Message, 13, secondary: true));
                cd = new ContentDialog
                {
                    Title = dialog.Site ?? "Choose an Account",
                    Content = new ScrollViewer { Content = list, MaxHeight = 320 },
                    CloseButtonText = "Cancel",
                    DefaultButton = ContentDialogButton.Close,
                };
                for (var i = 0; i < dialog.Accounts.Count; i++)
                {
                    var acct = dialog.Accounts[i];
                    var idx = i;
                    var title = !string.IsNullOrEmpty(acct.Name) ? acct.Name : (!string.IsNullOrEmpty(acct.Email) ? acct.Email : $"Account {idx + 1}");
                    var subtitle = !string.IsNullOrEmpty(acct.Name) && !string.IsNullOrEmpty(acct.Email) ? acct.Email : null;
                    list.Children.Add(Kit.Row(title, subtitle, click: () =>
                    {
                        Answer(true, account: idx);
                        cd.Hide();
                    }));
                }
                break;
            }

            case BrowserPageDialogKind.Signin:
                cd = new ContentDialog
                {
                    Title = dialog.Site ?? "Sign In",
                    Content = Kit.Text(dialog.Message.Length > 0 ? dialog.Message : "Continue signing in on this page?", 14),
                    PrimaryButtonText = "Continue",
                    CloseButtonText = "Cancel",
                    DefaultButton = ContentDialogButton.Primary,
                };
                break;

            case BrowserPageDialogKind.SigninError:
            default:
                cd = new ContentDialog
                {
                    Title = dialog.Site ?? "Sign-in Problem",
                    Content = Kit.Text(dialog.Message, 14),
                    PrimaryButtonText = "OK",
                    DefaultButton = ContentDialogButton.Primary,
                };
                break;
        }

        cd.XamlRoot = root;
        _activePageDialog = cd;
        _programmaticDialogHide = false;
        ContentDialogResult result;
        try { result = await cd.ShowAsync(); }
        catch (Exception) { result = ContentDialogResult.None; }
        finally
        {
            if (ReferenceEquals(_activePageDialog, cd)) _activePageDialog = null;
        }

        if (_programmaticDialogHide || answered) return;
        switch (dialog.Kind)
        {
            case BrowserPageDialogKind.Alert:
            case BrowserPageDialogKind.SigninError:
                Answer(true);
                break;
            case BrowserPageDialogKind.Prompt:
                Answer(result == ContentDialogResult.Primary, text: promptBox?.Text);
                break;
            default:
                Answer(result == ContentDialogResult.Primary);
                break;
        }
    }

    public void DismissPageDialog()
    {
        if (_activePageDialog is not { } active) return;
        _programmaticDialogHide = true;
        _activePageDialog = null;
        try { active.Hide(); } catch (Exception) { }
    }

    public void OfferPopupsUpdate(bool useUpdateSheet, string helperName)
    {
        if (XamlRoot is not { } root || _disposed) return;
        _ = PresentPopupsUpdateAsync(useUpdateSheet, helperName, root);
    }

    private async Task PresentPopupsUpdateAsync(bool useUpdateSheet, string helperName, XamlRoot root)
    {
        var cd = new ContentDialog
        {
            Title = "Update the Browser Add-on?",
            Content = Kit.Text("A newer browser add-on can show page popups and sign-in dialogs here while you control the browser.", 14),
            PrimaryButtonText = useUpdateSheet ? "Update Add-on" : $"Ask {helperName} to Update",
            CloseButtonText = "Not Now",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = root,
        };
        if (await Kit.Show(root, cd) != ContentDialogResult.Primary) return;
        if (useUpdateSheet) Viewer?.StartUpdate();
        else Viewer?.Install(BrowserSetupPrompt.Update);
    }

    public void ShowInstallFailure(string helperName, string reason)
    {
        var root = App.Window?.Content?.XamlRoot ?? XamlRoot;
        if (root == null) return;
        Kit.Fail(root, $"Couldn’t Ask {helperName}", reason);
    }

    public void OpenPlugins() { }
    public void Dismiss() => OnDismiss?.Invoke();

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        DismissPageDialog();
    }

    private static TextBlock CentredText(double size, bool bold) => new()
    {
        FontSize = size,
        FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
        TextWrapping = TextWrapping.Wrap,
        TextAlignment = TextAlignment.Center,
        HorizontalAlignment = HorizontalAlignment.Center,
    };

    private static Button IconButton(string glyph, string name, string automationId)
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 14 },
            MinWidth = 36,
            MinHeight = 36,
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
        };
        AutomationProperties.SetName(button, name);
        AutomationProperties.SetAutomationId(button, automationId);
        ToolTipService.SetToolTip(button, name);
        return button;
    }

    private static Button BarIconButton(string glyph, string name, string automationId, Action click)
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 15 },
            MinWidth = 40,
            MinHeight = 40,
        };
        AutomationProperties.SetName(button, name);
        AutomationProperties.SetAutomationId(button, automationId);
        ToolTipService.SetToolTip(button, name);
        button.Click += (_, _) => click();
        return button;
    }
}
