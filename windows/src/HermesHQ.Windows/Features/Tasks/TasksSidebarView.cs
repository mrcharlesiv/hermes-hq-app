using Hermes.Core.Tasks;
using HermesHQ.Features.Kanban;
using HermesHQ.Features.QuickActions;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.Tasks;

/// Collapsible 3-section Tasks sidebar (`App/Pages/Tasks/TasksNavigationViews.swift`, commits 58708c584 / 1da255c07):
/// **Views** (Today, Upcoming, Inbox, Goals), **My Lists** (icon, color, count, context menu, + New List),
/// and **Agents** (Suggested, Bots' Tasks). Width `TasksNavigationLayout.SidebarWidth` (216 DIP).
internal sealed class TasksSidebarView : UserControl
{
    private readonly StackPanel _body = new() { Spacing = 2, Padding = new Thickness(10, 8, 10, 16) };

    public Action<TodoView>? OnPickView { get; set; }
    public Action? OnNewList { get; set; }
    public Func<string, MenuFlyout>? BuildListMenu { get; set; }

    public TasksSidebarView()
    {
        Width = TasksNavigationLayout.SidebarWidth;
        IsTabStop = false;
        Content = new Border
        {
            BorderThickness = new Thickness(0, 0, 1, 0),
            BorderBrush = Brush("DividerStrokeColorDefaultBrush"),
            Background = Brush("LayerFillColorDefaultBrush"),
            Child = new ScrollViewer
            {
                Content = _body,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollMode = ScrollMode.Disabled,
            },
        };
        AutomationProperties.SetName(this, "Tasks Sidebar");
        AutomationProperties.SetAutomationId(this, "tasks.sidebar");
    }

    public void Render(TasksStore store, TaskIdeasStore? ideasStore, TodoView current, DateTimeOffset now, TimeZoneInfo zone)
    {
        _body.Children.Clear();
        if (!store.HasList || store.NeedsAddOn) return;

        var sections = store.Sections;
        var goalsPill = GoalsAddOn.Pill(store.GoalsSupported, store.GoalsNeedAddOn, store.Goals);

        // 1. Views
        AddSectionHeader("Views");
        AddNavRow(
            TodoView.Today,
            TasksCopy.Today,
            GlyphForSymbol("sun.max"),
            Accent,
            TodoViews.OpenCount(store.Tasks, TodoView.Today, sections, now, zone),
            subtitle: null,
            current: current,
            contextMenu: ViewFavoriteMenu(TodoView.Today, TasksCopy.Today));

        AddNavRow(
            TodoView.Upcoming,
            TasksCopy.Upcoming,
            GlyphForSymbol("calendar"),
            Solid(Red),
            TodoViews.OpenCount(store.Tasks, TodoView.Upcoming, sections, now, zone),
            subtitle: null,
            current: current,
            contextMenu: ViewFavoriteMenu(TodoView.Upcoming, TasksCopy.Upcoming));

        AddNavRow(
            TodoView.Inbox,
            TasksCopy.Inbox,
            GlyphForSymbol("tray"),
            Secondary,
            TodoViews.OpenCount(store.Tasks, TodoView.Inbox, sections, now, zone),
            subtitle: null,
            current: current,
            contextMenu: ViewFavoriteMenu(TodoView.Inbox, TasksCopy.Inbox));

        if (goalsPill.Shows)
        {
            AddNavRow(
                TodoView.Goals,
                GoalsCopy.Goals,
                GlyphForSymbol("smallcircle.filled.circle"),
                Solid(Green),
                goalsPill.Count,
                subtitle: null,
                current: current,
                contextMenu: ViewFavoriteMenu(TodoView.Goals, GoalsCopy.Goals));
        }

        // 2. My Lists
        if (sections.Count > 0 || store.EditsLists)
        {
            AddSectionHeader("My Lists", store.EditsLists ? "New List" : null, OnNewList);
            foreach (var sec in sections)
            {
                var view = TodoView.List(sec.Id);
                var rgb = GoalTints.Rgb(sec.Color ?? "blue");
                var tint = sec.Color != null ? Solid(Rgb(rgb.R, rgb.G, rgb.B)) : Secondary;
                var count = TodoViews.OpenCount(store.Tasks, view, sections, now, zone);
                var menu = store.EditsLists && BuildListMenu != null
                    ? BuildListMenu(sec.Id)
                    : ViewFavoriteMenu(view, sec.Name);
                AddNavRow(
                    view,
                    sec.Name,
                    GlyphForSymbol(sec.Icon ?? TodoListIcons.Fallback),
                    tint,
                    count,
                    subtitle: sec.Bot != null ? BotName(sec.Bot) : null,
                    current: current,
                    contextMenu: menu);
            }
            if (sections.Count == 0 && store.EditsLists)
            {
                var hint = Text("No lists yet", 12, color: Tertiary);
                hint.Margin = new Thickness(10, 2, 8, 4);
                _body.Children.Add(hint);
            }
        }

        // 3. Agents (Suggested + Bots' Tasks)
        var showSuggested = ideasStore != null && (store.Settings.Ideas != null || ideasStore.Page.On || ideasStore.VisibleIdeas.Count > 0);
        var showBots = TodoViews.ShowsBots(store.Tasks);
        if (showSuggested || showBots)
        {
            AddSectionHeader("Agents");
            if (showSuggested && ideasStore != null)
            {
                var page = ideasStore.Page;
                var looking = ideasStore.Looking || page.Running;
                var isOn = page.On || store.Settings.Ideas == true;
                var count = ideasStore.Loaded ? ideasStore.VisibleIdeas.Count : store.IdeasCount;
                var subtitle = looking ? "Looking…" : !isOn ? "Off" : null;
                AddNavRow(
                    TodoView.Suggested,
                    TasksCopy.Suggested,
                    GlyphForSymbol("sparkle"),
                    Accent,
                    isOn && !looking ? count : null,
                    subtitle: subtitle,
                    current: current,
                    contextMenu: ViewFavoriteMenu(TodoView.Suggested, TasksCopy.Suggested));
            }
            if (showBots)
            {
                AddNavRow(
                    TodoView.Bots,
                    TasksCopy.BotsTasks,
                    GlyphForSymbol("person.2"),
                    Solid(Blue),
                    TodoViews.OpenCount(store.Tasks, TodoView.Bots, sections, now, zone),
                    subtitle: null,
                    current: current,
                    contextMenu: ViewFavoriteMenu(TodoView.Bots, TasksCopy.BotsTasks));
            }
        }
    }

    private void AddSectionHeader(string title, string? actionTitle = null, Action? action = null)
    {
        var grid = new Grid { Margin = new Thickness(8, 12, 4, 4) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var label = new TextBlock
        {
            Text = title.ToUpperInvariant(),
            FontSize = 11,
            FontWeight = FontWeights.SemiBold,
            CharacterSpacing = 45,
            Foreground = Secondary,
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetHeadingLevel(label, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
        grid.Children.Add(label);

        if (actionTitle != null && action != null)
        {
            var addListBtn = new Button
            {
                Content = new FontIcon { Glyph = "\uE710", FontSize = 11 },
                Style = Style("QuietButtonStyle"),
                Padding = new Thickness(5, 3, 5, 3),
            };
            AutomationProperties.SetName(addListBtn, actionTitle);
            AutomationProperties.SetAutomationId(addListBtn, "tasks.sidebar.new-list");
            ToolTipService.SetToolTip(addListBtn, actionTitle);
            addListBtn.Click += (_, _) => action();
            Grid.SetColumn(addListBtn, 1);
            grid.Children.Add(addListBtn);
        }

        _body.Children.Add(grid);
    }

    private void AddNavRow(
        TodoView view,
        string title,
        (string Glyph, bool Emoji) icon,
        Brush iconBrush,
        int? count,
        string? subtitle,
        TodoView current,
        MenuFlyout? contextMenu)
    {
        var selected = view == current;
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        FrameworkElement iconView = icon.Emoji
            ? new TextBlock { Text = icon.Glyph, FontSize = 13, FontFamily = new FontFamily("Segoe UI Emoji"), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center }
            : new FontIcon { Glyph = icon.Glyph, FontSize = 13.5, Foreground = selected ? Accent : iconBrush, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        grid.Children.Add(iconView);

        var textCol = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        textCol.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 13.5,
            FontWeight = selected ? FontWeights.SemiBold : FontWeights.Normal,
            Foreground = Brush("TextFillColorPrimaryBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap,
        });
        if (!string.IsNullOrEmpty(subtitle))
        {
            textCol.Children.Add(new TextBlock
            {
                Text = subtitle,
                FontSize = 11,
                Foreground = Secondary,
                TextTrimming = TextTrimming.CharacterEllipsis,
                TextWrapping = TextWrapping.NoWrap,
            });
        }
        Grid.SetColumn(textCol, 1);
        grid.Children.Add(textCol);

        if (TasksCopy.PillDetail(count) is { } badge)
        {
            var countBlock = new TextBlock
            {
                Text = badge,
                FontSize = 12,
                Foreground = selected ? Accent : Secondary,
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(countBlock, 2);
            grid.Children.Add(countBlock);
        }

        var btn = new Button
        {
            Content = grid,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(8, 6, 8, 6),
            CornerRadius = new CornerRadius(6),
            Background = selected ? AccentWash(0.14) : Solid(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
        };
        if (contextMenu != null) btn.ContextFlyout = contextMenu;
        AutomationProperties.SetName(btn, TasksCopy.PillName(title, count));
        AutomationProperties.SetAutomationId(btn, "tasks.sidebar.view." + view.Key);
        var target = view;
        btn.Click += (_, _) => OnPickView?.Invoke(target);
        _body.Children.Add(btn);
    }

    private static MenuFlyout ViewFavoriteMenu(TodoView view, string title)
    {
        var menu = new MenuFlyout();
        menu.Items.Add(FavoritesPinAction.ForTaskView(view.Key, title));
        return menu;
    }

    internal static (string Glyph, bool Emoji) GlyphForSymbol(string symbol) => symbol switch
    {
        "sun.max" => ("\uE706", false),
        "calendar" => ("\uE787", false),
        "tray" => ("\uE896", false),
        "smallcircle.filled.circle" => ("\uE91F", false),
        "sparkle" => ("\uE734", false),
        "person.2" => ("\uE716", false),
        "briefcase" => ("\uE821", false),
        "house" => ("\uE80F", false),
        "cart" => ("\uE7BF", false),
        "heart" => ("\uEB51", false),
        "star" => ("\uE734", false),
        "book" => ("\uE82D", false),
        "airplane" => ("\uE709", false),
        "dollarsign.circle" => ("\uE8C7", false),
        "wrench.and.screwdriver" => ("\uE90F", false),
        "leaf" => ("\U0001F343", true),
        "graduationcap" => ("\uE7BE", false),
        "gift" => ("\U0001F381", true),
        "pawprint" => ("\U0001F43E", true),
        "flag" => ("\uE7C1", false),
        _ => ("\uE8FD", false),
    };
}
