using System.Text.Json.Nodes;
using Hermes.Core.Tasks;
using HermesHQ.Features.Kanban;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.Tasks;

/// New Task (App/Pages/Tasks/NewTodoSheet.swift): the task's title, who's involved (You, or a bot: Work together / Give
/// to it), and Details (notes, date, priority, list). A task of your own leaves the sheet open for the next one ("Added
/// “Call mom”"); one with a bot closes it and opens that bot's chat.
internal static class NewTodoDialog
{
    public static async Task PresentAsync(XamlRoot? root, TasksStore store, string? section, DateTimeOffset? startDay, Action<TodoTask?> created)
    {
        var zone = TimeZoneInfo.Local;
        var title = new TextBox { PlaceholderText = TasksCopy.WhatNeedsToBeDone };
        AutomationProperties.SetAutomationId(title, "tasks.new.title");
        string? helper = null;
        var alone = false;
        DateTimeOffset? due = startDay;
        var priority = 0;
        var list = section;
        var status = Text("", 13, color: Secondary);

        var dateButton = new DropDownButton();
        AutomationProperties.SetAutomationId(dateButton, "tasks.new.due");
        var priorityButton = new DropDownButton();
        AutomationProperties.SetAutomationId(priorityButton, "tasks.new.priority");
        var listButton = new DropDownButton();
        AutomationProperties.SetAutomationId(listButton, "tasks.new.section");
        var buttons = new List<(string? Id, Border Tile)>();
        var mode = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16 };
        var together = new RadioButton { Content = TasksCopy.WorkTogether, GroupName = "mode", IsChecked = true };
        var give = new RadioButton { GroupName = "mode" };
        together.Checked += (_, _) => { alone = false; Paint(); };
        give.Checked += (_, _) => { alone = true; Paint(); };
        mode.Children.Add(together);
        mode.Children.Add(give);
        AutomationProperties.SetAutomationId(mode, "tasks.new.mode");

        var people = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        void Person(string name, string? id)
        {
            var face = new StackPanel { Spacing = 5 };
            FrameworkElement head = id == null
                ? new FontIcon { Glyph = "", FontSize = 32, Foreground = Tertiary }
                : Face(id, 40);
            head.HorizontalAlignment = HorizontalAlignment.Center;
            face.Children.Add(head);
            var label = Text(name, 12, color: Secondary, wrap: false);
            label.HorizontalAlignment = HorizontalAlignment.Center;
            face.Children.Add(label);
            var tile = new Border { Child = face, Padding = new Thickness(6), CornerRadius = new CornerRadius(12), MinWidth = 60 };
            var button = new Button { Content = tile, Padding = new Thickness(0), Style = Style("QuietButtonStyle") };
            AutomationProperties.SetName(button, name);
            AutomationProperties.SetAutomationId(button, "tasks.new.person." + (id ?? "you"));
            button.Click += (_, _) => { helper = id; if (id == null) alone = false; status.Tag = null; Paint(); };
            buttons.Add((id, tile));
            people.Children.Add(button);
        }
        Person(TasksCopy.You, null);
        foreach (var bot in PageKit.Bots.OrderBy(b => b.Name == "default" ? 0 : 1)) Person(bot.DisplayName, bot.Name);

        var notes = new TextBox { PlaceholderText = TasksCopy.Notes, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 48 };
        AutomationProperties.SetAutomationId(notes, "tasks.new.notes");

        MenuFlyoutItem Item(string text, Action run)
        {
            var item = new MenuFlyoutItem { Text = text };
            item.Click += (_, _) => { run(); Paint(); };
            return item;
        }

        void Paint()
        {
            foreach (var (id, tile) in buttons) tile.Background = id == helper ? AccentWash(0.14) : Solid(Microsoft.UI.Colors.Transparent);
            mode.Visibility = helper == null ? Visibility.Collapsed : Visibility.Visible;
            if (helper != null) give.Content = TasksCopy.GiveTo(BotName(helper));
            var now = DateTimeOffset.Now;
            dateButton.Content = due is { } d ? TodoWords.NewTaskDue(d, false, now, zone) : TasksCopy.Date;
            var dates = new MenuFlyout();
            dates.Items.Add(Item(TasksCopy.Today, () => due = now));
            dates.Items.Add(Item(TasksCopy.Tomorrow, () => due = now.AddDays(1)));
            dates.Items.Add(Item(TasksCopy.NextWeek, () => due = now.AddDays(7)));
            if (due != null) dates.Items.Add(Item("No Date", () => due = null));
            dateButton.Flyout = dates;
            priorityButton.Content = priority > 0 ? TodoViews.PriorityWord(priority) : TasksCopy.Priority;
            var levels = new MenuFlyout();
            foreach (var level in new[] { 1, 2, 3 }) { var l = level; levels.Items.Add(Item(TodoViews.PriorityWord(l), () => priority = l)); }
            if (priority > 0) levels.Items.Add(Item(TasksCopy.NoPriority, () => priority = 0));
            priorityButton.Flyout = levels;
            listButton.Content = list is { } shownId && store.Sections.FirstOrDefault(x => x.Id == shownId) is { } shown ? shown.Name : TasksCopy.List;
            var lists = new MenuFlyout();
            lists.Items.Add(Item(TasksCopy.NoList, () => list = null));
            foreach (var each in store.Sections) { var sid = each.Id; lists.Items.Add(Item(each.Name, () => list = sid)); }
            listButton.Flyout = lists;
            if (status.Tag as string != "added" && status.Tag as string != "failed")
            {
                status.Text = helper == null ? "" : alone ? TasksCopy.StartsRightAway(BotName(helper)) : TodoWords.NewTaskHelpNote(BotName(helper));
                status.Foreground = Secondary;
            }
        }

        var details = new StackPanel { Spacing = 8 };
        details.Children.Add(notes);
        details.Children.Add(Row(TasksCopy.Date, dateButton));
        if (store.FieldsSupported) details.Children.Add(Row(TasksCopy.Priority, priorityButton));
        if (store.Sections.Count > 0) details.Children.Add(Row(TasksCopy.List, listButton));
        var expander = new Expander
        {
            Header = TasksCopy.Details, Content = details, HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
        };
        AutomationProperties.SetAutomationId(expander, "tasks.new.details");

        var form = new StackPanel { Spacing = 8, Width = 460 };
        form.Children.Add(Header(TasksCopy.TaskTitle));
        form.Children.Add(title);
        form.Children.Add(Header(TasksCopy.WhosInvolved));
        form.Children.Add(new ScrollViewer { Content = people, HorizontalScrollMode = ScrollMode.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollMode = ScrollMode.Disabled });
        form.Children.Add(mode);
        form.Children.Add(expander);
        form.Children.Add(Text(TasksCopy.DetailsFooter, 12, color: Secondary));
        form.Children.Add(status);
        Paint();

        var dialog = new ContentDialog
        {
            Title = TasksCopy.NewTask, Content = new ScrollViewer { Content = form, MaxHeight = 560 },
            PrimaryButtonText = TasksCopy.Add, CloseButtonText = TasksCopy.Done, DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = false,
        };
        title.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = title.Text.Trim().Length > 0;
        dialog.PrimaryButtonClick += async (_, e) =>
        {
            var deferral = e.GetDeferral();
            dialog.IsPrimaryButtonEnabled = false;
            form.IsHitTestVisible = false;
            try
            {
                var who = helper == null ? TodoWho.Me : alone ? TodoWho.Bot : TodoWho.Together;
                var fields = TodoWire.NewTask(title.Text.Trim(), who, helper, due is { } d ? TodoDates.Wire(d, false, zone) : null, null, false, notes.Text.Trim());
                if (store.FieldsSupported && priority > 0) fields["priority"] = priority;
                if (list != null) fields["section"] = list;
                var made = await store.AddAsync(fields, quiet: true);
                if (made == null)
                {
                    e.Cancel = true;
                    status.Tag = "failed";
                    status.Text = store.AddFailure ?? TasksCopy.CheckConnection;
                    status.Foreground = Critical;
                    dialog.IsPrimaryButtonEnabled = true;
                    AutomationProperties.SetAutomationId(status, "tasks.new.failure");
                }
                else if (made.Helper == null)
                {
                    // Your own: the sheet stays for the next one.
                    e.Cancel = true;
                    created(made);
                    title.Text = "";
                    notes.Text = "";
                    due = startDay;
                    priority = 0;
                    status.Tag = "added";
                    status.Text = "✓ " + TasksCopy.Added(made.Title);
                    status.Foreground = Secondary;
                    Paint();
                    title.Focus(FocusState.Programmatic);
                }
                else created(made);
            }
            catch (Exception ex)
            {
                e.Cancel = true;
                HermesHQ.Services.AppLog.Error("tasks", ex);
                status.Tag = "failed";
                status.Text = TasksCopy.CheckConnection;
                status.Foreground = Critical;
                dialog.IsPrimaryButtonEnabled = true;
            }
            finally
            {
                form.IsHitTestVisible = true;
                deferral.Complete();
            }
        };
        title.Loaded += (_, _) => title.Focus(FocusState.Programmatic);
        await ShowAsync(root, dialog);
    }

    private static FrameworkElement Row(string label, FrameworkElement control)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var l = Text(label, 14);
        l.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(l);
        Grid.SetColumn(control, 1);
        grid.Children.Add(control);
        return grid;
    }
}
