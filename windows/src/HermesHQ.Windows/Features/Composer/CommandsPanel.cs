using Hermes.Core.Composer;
using Hermes.Core.Net;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;
using DispatcherQueue = Microsoft.UI.Dispatching.DispatcherQueue;
using DispatcherQueueTimer = Microsoft.UI.Dispatching.DispatcherQueueTimer;

namespace HermesHQ.Features.Composer;

/// The ☰ Commands pop-up (App/Chat/Menus/CommandsSheetViewController.swift, the Mac's): "Search Commands", the
/// catalog's sections led by Favorites, a star on each command (right-click to add or remove), a click picks it.
/// Loading, "Couldn’t Load Commands" with Try Again and Show Details, "No Commands Available" with Check Again, and
/// "No Results for “…”".
internal sealed class CommandsPanel
{
    private readonly ChatComposer _c;
    private readonly Action<CommandRow> _pick;
    private readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();
    private readonly TextBox _search = new() { PlaceholderText = "Search Commands" };
    private readonly StackPanel _list = new();
    private CommandsCatalog? _catalog;
    private Exception? _failure;
    private bool _loading;
    private CommandRow? _first;

    public FrameworkElement View { get; }
    public Action? Done { get; set; }

    public CommandsPanel(ChatComposer c, Action<CommandRow> pick)
    {
        _c = c;
        _pick = pick;
        AutomationProperties.SetName(_search, "Search Commands");
        _search.TextChanged += (_, _) => Draw();
        _search.KeyDown += OnSearchKey;
        var root = new Grid { Width = 420, RowSpacing = 6 };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(Ui.Text("Commands", 15, bold: true));
        Grid.SetRow(_search, 1);
        root.Children.Add(_search);
        var scroll = new ScrollViewer { Content = _list, MaxHeight = 440 };
        Grid.SetRow(scroll, 2);
        root.Children.Add(scroll);
        View = root;
        Load(fresh: false);
    }

    public void Focus() => _search.Focus(FocusState.Programmatic);

    private void OnSearchKey(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter || _first is not { } row) return;
        e.Handled = true;
        Done?.Invoke();
        _pick(row);
    }

    private void Load(bool fresh)
    {
        _loading = true;
        _failure = null;
        Draw();
        _ = Task.Run(async () =>
        {
            try
            {
                var catalog = await _c.LoadCommandsAsync(fresh);
                _ui.TryEnqueue(() => { _catalog = catalog; _loading = false; Draw(); });
            }
            catch (Exception x)
            {
                _ui.TryEnqueue(() => { _failure = x; _loading = false; Draw(); });
            }
        });
    }

    private void Draw()
    {
        HermesHQ.Services.UiTree.ClearPanel(_list);
        _first = null;
        if (_catalog == null)
        {
            if (_loading)
            {
                var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(8, 16, 8, 16) };
                row.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
                row.Children.Add(Ui.Text("Loading Commands", 14, secondary: true));
                _list.Children.Add(row);
                return;
            }
            if (_failure is { } failure)
            {
                Empty(CommandsLoad.Title, CommandsLoad.Words(failure), "Try Again", () => Load(fresh: true), MenusText.Details(failure));
                return;
            }
        }
        var favorites = _c.Prefs.FavoriteCommands;
        var all = SlashCatalog.Sections(_catalog!, _c.IsBotChat);
        if (all.Count == 0)
        {
            Empty(ComposerDrawer.NoCommands, ComposerDrawer.NoCommandsText, ComposerDrawer.CheckAgain, () => Load(fresh: true), null);
            return;
        }
        var query = _search.Text.Trim();
        var shown = query.Length == 0
            ? SlashCatalog.FavoritesLeading(all, all, favorites)
            : SlashCatalog.Ranked(SlashCatalog.Filter(all, query), query, favorites);
        if (shown.Count == 0)
        {
            Empty($"No Results for “{query}”", null, null, null, null);
            return;
        }
        foreach (var section in shown)
        {
            _list.Children.Add(Ui.Header(section.Title));
            foreach (var row in section.Rows)
            {
                _first ??= row;
                _list.Children.Add(Row(row, favorites.Contains(SlashCatalog.Normalize(row.Command))));
            }
        }
    }

    private UIElement Row(CommandRow row, bool starred)
    {
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var words = new StackPanel();
        words.Children.Add(Ui.Text(row.Command, 14, bold: true, wrap: false));
        if (row.Description.Length > 0) words.Children.Add(Ui.Text(row.Description, 12, secondary: true));
        grid.Children.Add(words);
        var star = Ui.Quiet(Ui.Glyph(starred ? "" : "", 13), $"Favorite {row.Command}", (_, _) =>
        {
            _c.Prefs.ToggleFavoriteCommand(row.Command);
            Draw();
        });
        Grid.SetColumn(star, 1);
        grid.Children.Add(star);
        var button = Ui.Row(grid, (_, _) =>
        {
            Done?.Invoke();
            _pick(row);
        });
        AutomationProperties.SetName(button, $"{row.Command}, {row.Description}");
        var menu = new MenuFlyout();
        var fav = new MenuFlyoutItem { Text = ComposerDrawer.FavoriteActionTitle(starred) };
        fav.Click += (_, _) => { _c.Prefs.ToggleFavoriteCommand(row.Command); Draw(); };
        menu.Items.Add(fav);
        button.ContextFlyout = menu;
        return button;
    }

    private void Empty(string title, string? text, string? action, Action? act, string? details)
    {
        var box = new StackPanel { Spacing = 6, Margin = new Thickness(12, 20, 12, 20), HorizontalAlignment = HorizontalAlignment.Center };
        box.Children.Add(new TextBlock { Text = title, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center });
        if (text != null)
        {
            var t = Ui.Text(text, 13, secondary: true);
            t.TextAlignment = TextAlignment.Center;
            box.Children.Add(t);
        }
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center };
        if (action != null && act != null)
        {
            var b = new Button { Content = action, Style = Ui.Res<Style>("AccentButtonStyle") };
            b.Click += (_, _) => act();
            buttons.Children.Add(b);
        }
        if (details != null)
        {
            var d = new Button { Content = "Show Details" };
            d.Click += (_, _) => _ = Ui.Alert(View.XamlRoot, title, details);
            buttons.Children.Add(d);
        }
        box.Children.Add(buttons);
        _list.Children.Add(box);
    }
}
