using Hermes.Core.Tasks;
using HermesHQ.Features.Kanban;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.Tasks;

/// Unified searchable Completed Logbook (`App/Pages/Tasks/TaskLogbookSheet.swift`, commit 36659bce1):
/// groups completed tasks into Today, Yesterday, This Week, Earlier This Month, and month buckets, with Reopen action
/// and click-to-open.
internal static class TaskLogbookDialog
{
    public static async Task PresentAsync(XamlRoot? root, TasksStore store, Action<string> openTask)
    {
        var zone = TimeZoneInfo.Local;
        var ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        var query = "";
        string? taskToOpen = null;
        ContentDialog? dialog = null;

        var search = new TextBox { PlaceholderText = "Search completed tasks" };
        AutomationProperties.SetName(search, "Search completed tasks");
        AutomationProperties.SetAutomationId(search, "tasks.logbook.search");

        var list = new StackPanel { Spacing = 6 };
        var scroll = new ScrollViewer
        {
            Content = list,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Disabled,
            MaxHeight = 460,
        };

        void Build()
        {
            list.Children.Clear();
            var now = DateTimeOffset.Now;
            var groups = TodoViews.Logbook(store.Tasks, query, now, zone);
            if (groups.Count == 0)
            {
                var empty = Text(
                    string.IsNullOrWhiteSpace(query) ? "No completed tasks yet." : $"No completed tasks matching “{query.Trim()}”.",
                    14,
                    color: Secondary);
                empty.Margin = new Thickness(4, 24, 4, 24);
                empty.HorizontalAlignment = HorizontalAlignment.Center;
                list.Children.Add(empty);
                return;
            }

            foreach (var group in groups)
            {
                var heading = new TextBlock
                {
                    Text = $"{group.Title.ToUpperInvariant()}  ·  {group.Tasks.Count}",
                    FontSize = 11.5,
                    FontWeight = FontWeights.SemiBold,
                    CharacterSpacing = 45,
                    Foreground = Secondary,
                    Margin = new Thickness(4, 12, 4, 4),
                };
                AutomationProperties.SetHeadingLevel(heading, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
                list.Children.Add(heading);

                foreach (var item in group.Tasks)
                {
                    var task = item;
                    var row = new Grid { ColumnSpacing = 10 };
                    row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                    row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

                    var checkIcon = new FontIcon
                    {
                        Glyph = "\uE73E",
                        FontSize = 13,
                        Foreground = Accent,
                        VerticalAlignment = VerticalAlignment.Center,
                    };
                    row.Children.Add(checkIcon);

                    var info = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
                    info.Children.Add(Text(task.Title.Length == 0 ? TasksCopy.Untitled : task.Title, 14, color: Secondary, wrap: false));

                    var meta = new List<string>();
                    if (task.Section is { } sid && store.Sections.FirstOrDefault(s => s.Id == sid) is { } sec)
                        meta.Add(sec.Name);
                    if (task.Goal is { } gid && store.FindGoal(gid) is { } goal)
                        meta.Add(goal.Shown);
                    if (task.Helper != null)
                        meta.Add(TodoViews.Who(task, BotName));
                    if (TodoDates.Moment(task.DoneAt ?? task.UpdatedAt) is { } finished)
                        meta.Add(TodoWords.Clock(finished, zone));
                    if (meta.Count > 0)
                        info.Children.Add(Text(string.Join(" · ", meta), 12, color: Tertiary, wrap: false));

                    Grid.SetColumn(info, 1);
                    row.Children.Add(info);

                    var reopenBtn = Quiet("Reopen", () => _ = store.SetDoneAsync(task.Id, false));
                    reopenBtn.IsEnabled = !store.ReadOnlyGateway;
                    reopenBtn.VerticalAlignment = VerticalAlignment.Center;
                    AutomationProperties.SetName(reopenBtn, $"Reopen {task.Title}");
                    AutomationProperties.SetAutomationId(reopenBtn, "tasks.logbook.reopen." + task.Id);
                    Grid.SetColumn(reopenBtn, 2);
                    row.Children.Add(reopenBtn);

                    var card = Card(row, 10);
                    card.Tapped += (_, _) =>
                    {
                        taskToOpen = task.Id;
                        dialog?.Hide();
                    };
                    AutomationProperties.SetAutomationId(card, "tasks.logbook.row." + task.Id);
                    list.Children.Add(card);
                }
            }
        }

        void OnStoreChanged() => ui.TryEnqueue(Build);
        store.Changed += OnStoreChanged;
        search.TextChanged += (_, _) => { query = search.Text; Build(); };

        var body = new StackPanel { Spacing = 10, Width = 500 };
        body.Children.Add(search);
        body.Children.Add(scroll);
        Build();

        dialog = new ContentDialog
        {
            Title = "Completed Logbook",
            Content = body,
            CloseButtonText = TasksCopy.Done,
            DefaultButton = ContentDialogButton.Close,
        };
        try
        {
            await ShowAsync(root, dialog);
        }
        finally
        {
            store.Changed -= OnStoreChanged;
        }

        if (taskToOpen != null) openTask(taskToOpen);
    }
}
