using Hermes.Core.QuickActions;
using HermesHQ.Features.Kanban;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Windows.ApplicationModel.DataTransfer;

namespace HermesHQ.Features.QuickActions;

/// Horizontal Favorites page pill strip (`App/QuickActions/FavoritePagesBar.swift`): hidden while only the default
/// "Home" page exists; supports switching pages, rename, 12-icon submenu, keyboard/context/drag reorder, deleting a
/// custom page (moving tiles back to Home), and adding a new page.
internal sealed class FavoritePagesBar : UserControl
{
    private readonly StackPanel _strip = new() { Orientation = Orientation.Horizontal, Spacing = 6 };
    private readonly Button _addBtn;
    private readonly Button _menuBtn;
    private IReadOnlyList<FavoritePage> _pages = [FavoritePage.Main];
    private string _currentPageId = FavoritePage.MainId;

    public event Action<string>? PageSelected;
    public event Action? AddPageRequested;
    public event Action<FavoritePage>? RenamePageRequested;
    public event Action<FavoritePage, string?>? ChangeSymbolRequested;
    public event Action<FavoritePage, int>? MovePageRequested;
    public event Action<string, string>? ReorderPageRequested;
    public event Action<FavoritePage>? DeletePageRequested;

    public FavoritePagesBar()
    {
        Visibility = Visibility.Collapsed;
        Padding = new Thickness(16, 2, 16, 6);

        var scroll = new ScrollViewer
        {
            Content = _strip,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollMode = ScrollMode.Disabled,
        };

        _addBtn = new Button
        {
            Content = new FontIcon { Glyph = "\uE710", FontSize = 12 },
            Height = 28,
            Padding = new Thickness(8, 0, 8, 0),
            CornerRadius = new CornerRadius(14),
            VerticalAlignment = VerticalAlignment.Center,
        };
        ToolTipService.SetToolTip(_addBtn, "New Page");
        AutomationProperties.SetAutomationId(_addBtn, "favorites.page.add");
        AutomationProperties.SetName(_addBtn, "New Page");
        _addBtn.Click += (_, _) => AddPageRequested?.Invoke();

        _menuBtn = new Button
        {
            Content = new FontIcon { Glyph = "\uE712", FontSize = 12 },
            Height = 28,
            Padding = new Thickness(8, 0, 8, 0),
            CornerRadius = new CornerRadius(14),
            VerticalAlignment = VerticalAlignment.Center,
        };
        ToolTipService.SetToolTip(_menuBtn, "Page Options");
        AutomationProperties.SetAutomationId(_menuBtn, "favorites.page.menu");
        AutomationProperties.SetName(_menuBtn, "Page Options");

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        actions.Children.Add(_addBtn);
        actions.Children.Add(_menuBtn);

        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(scroll);
        Grid.SetColumn(actions, 1);
        row.Children.Add(actions);
        Content = row;
        AutomationProperties.SetName(this, "Favorite Pages");
    }

    public void Update(IReadOnlyList<FavoritePage> pages, string currentPageId, double sidePadding)
    {
        _pages = pages;
        _currentPageId = currentPageId;
        Padding = new Thickness(sidePadding, 2, sidePadding, 6);
        Visibility = pages.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        if (pages.Count <= 1) return;

        _strip.Children.Clear();
        var current = pages.FirstOrDefault(p => p.Id == currentPageId) ?? pages[0];
        var currentIndex = pages.ToList().FindIndex(p => p.Id == current.Id);
        _menuBtn.Flyout = BuildPageMenu(current, currentIndex, pages.Count);

        for (var i = 0; i < pages.Count; i++)
        {
            var page = pages[i];
            var index = i;
            var active = page.Id == current.Id;
            var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            if (!string.IsNullOrEmpty(page.Symbol))
                content.Children.Add(new FontIcon { Glyph = QuickActionsPage.Glyph(page.Symbol), FontSize = 12 });
            content.Children.Add(new TextBlock
            {
                Text = page.Name,
                FontSize = 12.5,
                FontWeight = active ? FontWeights.SemiBold : FontWeights.Normal,
            });

            var pill = new ToggleButton
            {
                Content = content,
                IsChecked = active,
                Height = 28,
                Padding = new Thickness(10, 0, 10, 0),
                CornerRadius = new CornerRadius(14),
                ContextFlyout = BuildPageMenu(page, index, pages.Count),
            };
            AutomationProperties.SetAutomationId(pill, "favorites.page." + page.Id);
            AutomationProperties.SetName(pill, page.Name);
            pill.Click += (_, _) =>
            {
                pill.IsChecked = true;
                PageSelected?.Invoke(page.Id);
            };

            if (page.Id != FavoritePage.MainId)
            {
                pill.CanDrag = true;
                pill.AllowDrop = true;
                pill.DragStarting += (_, e) =>
                {
                    e.Data.SetText("favorite-page:" + page.Id);
                    e.Data.RequestedOperation = DataPackageOperation.Move;
                };
                pill.DragOver += (_, e) =>
                {
                    e.AcceptedOperation = DataPackageOperation.Move;
                    e.Handled = true;
                };
                pill.Drop += async (_, e) =>
                {
                    if (!e.DataView.Contains(StandardDataFormats.Text)) return;
                    var payload = await e.DataView.GetTextAsync();
                    if (payload.StartsWith("favorite-page:", StringComparison.Ordinal))
                    {
                        var sourceId = payload["favorite-page:".Length..];
                        if (sourceId != page.Id) ReorderPageRequested?.Invoke(sourceId, page.Id);
                    }
                };
            }

            _strip.Children.Add(pill);
        }
    }

    private MenuFlyout BuildPageMenu(FavoritePage page, int index, int total)
    {
        var menu = new MenuFlyout();

        var rename = new MenuFlyoutItem { Text = "Rename…", Icon = new FontIcon { Glyph = "\uE8AC" } };
        rename.Click += (_, _) => RenamePageRequested?.Invoke(page);
        menu.Items.Add(rename);

        var iconSub = new MenuFlyoutSubItem { Text = "Icon", Icon = new FontIcon { Glyph = "\uE734" } };
        var noneIcon = new RadioMenuFlyoutItem { Text = "None", GroupName = "page-icon-" + page.Id, IsChecked = string.IsNullOrEmpty(page.Symbol) };
        noneIcon.Click += (_, _) => ChangeSymbolRequested?.Invoke(page, null);
        iconSub.Items.Add(noneIcon);
        iconSub.Items.Add(new MenuFlyoutSeparator());
        foreach (var (symbol, label) in FavoritePage.SymbolChoices)
        {
            var sym = symbol;
            var item = new RadioMenuFlyoutItem
            {
                Text = label,
                GroupName = "page-icon-" + page.Id,
                IsChecked = page.Symbol == sym,
                Icon = new FontIcon { Glyph = QuickActionsPage.Glyph(sym) },
            };
            item.Click += (_, _) => ChangeSymbolRequested?.Invoke(page, sym);
            iconSub.Items.Add(item);
        }
        menu.Items.Add(iconSub);

        if (page.Id != FavoritePage.MainId)
        {
            if (index > 1)
            {
                var left = new MenuFlyoutItem { Text = "Move Left", Icon = new FontIcon { Glyph = "\uE76B" } };
                left.Click += (_, _) => MovePageRequested?.Invoke(page, -1);
                menu.Items.Add(left);
            }
            if (index >= 1 && index < total - 1)
            {
                var right = new MenuFlyoutItem { Text = "Move Right", Icon = new FontIcon { Glyph = "\uE76C" } };
                right.Click += (_, _) => MovePageRequested?.Invoke(page, 1);
                menu.Items.Add(right);
            }
            menu.Items.Add(new MenuFlyoutSeparator());
            var delete = new MenuFlyoutItem { Text = "Delete Page…", Icon = new FontIcon { Glyph = "\uE74D" } };
            delete.Click += (_, _) => DeletePageRequested?.Invoke(page);
            menu.Items.Add(delete);
        }

        return menu;
    }
}
