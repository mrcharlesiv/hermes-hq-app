using System.Text.Json.Nodes;
using Hermes.Core.Tasks;
using HermesHQ.Features.Kanban;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.System;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.Tasks;

/// New Task (`App/Pages/Tasks/NewTodoSheet.swift`, commits 84263f4e4 / 36659bce1):
/// visible Title + Notes (no collapsed expander), live `TodoQuickParse` preview with Keep literal / Read details toggle,
/// visual bot grid (`Who's involved` + `Work together` / `Give to <Bot>`), structured **Schedule** (Due date+time, Start
/// Date, Repeat incl. shared-task repeat when `FieldsSupported`) & **Organize** (List, Priority, Tag Picker flyout,
/// Goal + Milestone), and unsaved-draft close guard.
internal static class NewTodoDialog
{
    public static async Task PresentAsync(
        XamlRoot? root,
        TasksStore store,
        string? section,
        DateTimeOffset? startDay,
        Action<TodoTask?> created,
        string? initialGoal = null,
        string? initialMilestone = null)
    {
        var zone = TimeZoneInfo.Local;
        var title = new TextBox { PlaceholderText = TasksCopy.WhatNeedsToBeDone };
        AutomationProperties.SetAutomationId(title, "tasks.new.title");

        // AcceptsReturn MUST be set BEFORE Text on multiline TextBox (WinUI rule).
        var notes = new TextBox
        {
            AcceptsReturn = true,
            Text = "",
            PlaceholderText = TasksCopy.Notes,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 56,
        };
        AutomationProperties.SetName(notes, TasksCopy.Notes);
        AutomationProperties.SetAutomationId(notes, "tasks.new.notes");

        string? helper = null;
        var alone = false;
        DateTimeOffset? manualDue = startDay;
        var manualDueHasTime = false;
        var dueExplicitlySet = startDay != null;
        DateTimeOffset? startsDate = null;
        string? manualRepeat = null;
        var repeatExplicitlySet = false;
        int? manualPriority = null;
        var list = section;
        var manualTags = new List<string>();
        string? goalId = initialGoal;
        string? milestoneId = initialMilestone;
        var keepLiteral = false;
        var allowDiscard = false;

        var parsePreviewBar = new Grid { ColumnSpacing = 8, Visibility = Visibility.Collapsed };
        parsePreviewBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        parsePreviewBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var parsePreviewText = Text("", 12, color: Accent);
        parsePreviewText.VerticalAlignment = VerticalAlignment.Center;
        parsePreviewBar.Children.Add(parsePreviewText);
        var literalToggle = new Button
        {
            Content = "Keep literal",
            Style = Style("QuietButtonStyle"),
            Padding = new Thickness(8, 2, 8, 2),
        };
        AutomationProperties.SetAutomationId(literalToggle, "tasks.new.literal");
        Grid.SetColumn(literalToggle, 1);
        parsePreviewBar.Children.Add(literalToggle);

        var status = Text("", 13, color: Secondary);

        // Inline unsaved-draft discard bar (avoids nested WinUI ContentDialog crash).
        var discardBar = new Border
        {
            Visibility = Visibility.Collapsed,
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(10, 8, 10, 8),
            Background = Brush("SystemFillColorCautionBackgroundBrush"),
            BorderBrush = Brush("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1),
        };
        ContentDialog? dialog = null;
        var discardGrid = new Grid { ColumnSpacing = 8 };
        discardGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        discardGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var discardPrompt = Text("Discard this draft?", 13, bold: true);
        discardPrompt.VerticalAlignment = VerticalAlignment.Center;
        discardGrid.Children.Add(discardPrompt);
        var discardBtns = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        var keepEditingBtn = Quiet("Keep Editing", () => discardBar.Visibility = Visibility.Collapsed);
        var discardConfirmBtn = Push("Discard", () => { allowDiscard = true; dialog?.Hide(); });
        discardConfirmBtn.Foreground = Critical;
        discardBtns.Children.Add(keepEditingBtn);
        discardBtns.Children.Add(discardConfirmBtn);
        Grid.SetColumn(discardBtns, 1);
        discardGrid.Children.Add(discardBtns);
        discardBar.Child = discardGrid;

        var dateButton = new DropDownButton();
        AutomationProperties.SetAutomationId(dateButton, "tasks.new.due");
        var startButton = new DropDownButton();
        AutomationProperties.SetAutomationId(startButton, "tasks.new.starts");
        var repeatButton = new DropDownButton();
        AutomationProperties.SetAutomationId(repeatButton, "tasks.new.repeat");
        var repeatRowHost = Row("Repeat", repeatButton);
        var listButton = new DropDownButton();
        AutomationProperties.SetAutomationId(listButton, "tasks.new.section");
        var priorityButton = new DropDownButton();
        AutomationProperties.SetAutomationId(priorityButton, "tasks.new.priority");
        var tagsButton = new DropDownButton();
        AutomationProperties.SetAutomationId(tagsButton, "tasks.new.tags");
        var goalButton = new DropDownButton();
        AutomationProperties.SetAutomationId(goalButton, "tasks.new.goal");

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
                ? new FontIcon { Glyph = "\uE77B", FontSize = 32, Foreground = Tertiary }
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

        bool RepeatAllowed()
        {
            var who = helper == null ? TodoWho.Me : alone ? TodoWho.Bot : TodoWho.Together;
            return who == TodoWho.Me || (who == TodoWho.Together && store.FieldsSupported);
        }

        TodoQuickRead CurrentParse(DateTimeOffset now) => TodoQuickParse.Read(
            title.Text,
            now,
            zone,
            dates: !dueExplicitlySet,
            goal: false,
            metadata: store.FieldsSupported,
            repeats: !repeatExplicitlySet && RepeatAllowed(),
            priorities: manualPriority == null && store.FieldsSupported,
            keepLiteral: keepLiteral);

        MenuFlyoutItem Item(string text, Action run)
        {
            var item = new MenuFlyoutItem { Text = text };
            item.Click += (_, _) => { run(); Paint(); };
            return item;
        }

        void OpenDateTimeFlyout(FrameworkElement anchor, DateTimeOffset? existing, bool existingHasTime, bool allowTime, Action<DateTimeOffset, bool> apply)
        {
            var start = existing ?? DateTimeOffset.Now.AddDays(1);
            var datePicker = new CalendarDatePicker { Date = start, HorizontalAlignment = HorizontalAlignment.Stretch };
            var timeCheck = new CheckBox { Content = "Include time", IsChecked = existingHasTime };
            var timePicker = new TimePicker { Time = existingHasTime ? TimeZoneInfo.ConvertTime(start, zone).TimeOfDay : new TimeSpan(9, 0, 0), IsEnabled = existingHasTime };
            timeCheck.Checked += (_, _) => timePicker.IsEnabled = true;
            timeCheck.Unchecked += (_, _) => timePicker.IsEnabled = false;

            var flyout = new Flyout();
            var panel = new StackPanel { Spacing = 8, Width = 280 };
            panel.Children.Add(datePicker);
            if (allowTime)
            {
                panel.Children.Add(timeCheck);
                panel.Children.Add(timePicker);
            }
            var setBtn = Push("Set", () =>
            {
                if (datePicker.Date is { } picked)
                {
                    var day = picked.Date;
                    var useTime = allowTime && timeCheck.IsChecked == true;
                    var local = useTime ? day + timePicker.Time : day;
                    apply(new DateTimeOffset(local, zone.GetUtcOffset(local)), useTime);
                    Paint();
                }
                flyout.Hide();
            }, accent: true);
            setBtn.HorizontalAlignment = HorizontalAlignment.Right;
            panel.Children.Add(setBtn);
            flyout.Content = panel;
            flyout.ShowAt(anchor);
        }

        void BuildTagsFlyout()
        {
            var allKnown = TodoViews.AllTags(store.Tasks);
            var flyout = new Flyout();
            var panel = new StackPanel { Spacing = 8, Width = 320 };
            var input = new TextBox { PlaceholderText = "Add tag (Enter or comma)" };
            AutomationProperties.SetName(input, "Add tag");
            var wrap = new TaskWrapPanel { HorizontalSpacing = 6, VerticalSpacing = 6 };

            void RebuildPills()
            {
                wrap.Children.Clear();
                var catalog = allKnown.Concat(manualTags).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
                var filter = input.Text.Trim().TrimStart('#').ToLowerInvariant();
                foreach (var t in catalog.Where(x => filter.Length == 0 || x.ToLowerInvariant().Contains(filter, StringComparison.Ordinal)))
                {
                    var tag = t;
                    var picked = manualTags.Any(x => string.Equals(x, tag, StringComparison.OrdinalIgnoreCase));
                    var pill = new Button
                    {
                        Content = (picked ? "✓ #" : "#") + tag,
                        Padding = new Thickness(8, 3, 8, 4),
                        CornerRadius = new CornerRadius(12),
                        Background = picked ? Brush("AccentFillColorDefaultBrush") : Brush("ControlFillColorDefaultBrush"),
                        Foreground = picked ? Brush("TextOnAccentFillColorPrimaryBrush") : Brush("TextFillColorPrimaryBrush"),
                        IsEnabled = picked || manualTags.Count < TaskTagPickerDialog.MaxTags,
                    };
                    pill.Click += (_, _) =>
                    {
                        var idx = manualTags.FindIndex(x => string.Equals(x, tag, StringComparison.OrdinalIgnoreCase));
                        if (idx >= 0) manualTags.RemoveAt(idx);
                        else if (manualTags.Count < TaskTagPickerDialog.MaxTags) manualTags.Add(tag);
                        RebuildPills();
                        Paint();
                    };
                    wrap.Children.Add(pill);
                }
            }

            void CommitTyped()
            {
                foreach (var t in TodoViews.TagsFrom(input.Text))
                {
                    if (manualTags.Count >= TaskTagPickerDialog.MaxTags) break;
                    if (!manualTags.Any(x => string.Equals(x, t, StringComparison.OrdinalIgnoreCase)))
                        manualTags.Add(t);
                }
                input.Text = "";
                RebuildPills();
                Paint();
            }

            input.TextChanged += (_, _) => { if (input.Text.Contains(',', StringComparison.Ordinal)) CommitTyped(); else RebuildPills(); };
            input.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) { e.Handled = true; CommitTyped(); } };

            panel.Children.Add(Text($"Tags ({manualTags.Count}/{TaskTagPickerDialog.MaxTags})", 12, bold: true, color: Secondary));
            panel.Children.Add(input);
            panel.Children.Add(new ScrollViewer { Content = wrap, MaxHeight = 180, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
            RebuildPills();
            flyout.Content = panel;
            tagsButton.Flyout = flyout;
        }

        void Paint()
        {
            var now = DateTimeOffset.Now;
            var parsed = CurrentParse(now);
            var rawParsed = TodoQuickParse.Read(title.Text, now, zone, dates: !dueExplicitlySet, metadata: store.FieldsSupported, repeats: !repeatExplicitlySet && RepeatAllowed(), priorities: manualPriority == null && store.FieldsSupported);

            // Live quick-parse preview bar with Keep literal / Read details toggle.
            if (rawParsed.HasParsedDetails)
            {
                parsePreviewBar.Visibility = Visibility.Visible;
                if (keepLiteral)
                {
                    parsePreviewText.Text = "Keeping text literal";
                    parsePreviewText.Foreground = Secondary;
                    literalToggle.Content = "Read details";
                }
                else
                {
                    var chips = new List<string>();
                    if (parsed.Due is { } pd) chips.Add("Due " + TodoWords.NewTaskDue(pd, parsed.HasTime, now, zone));
                    if (parsed.RepeatRule is { } pr) chips.Add(TodoWords.RepeatLabel(pr));
                    if (parsed.Priority is { } pp) chips.Add(pp == 0 ? "No Priority" : TodoViews.PriorityWord(pp) + " priority");
                    foreach (var tg in parsed.Tags) chips.Add("#" + tg);
                    parsePreviewText.Text = "Detected: " + string.Join(" · ", chips);
                    parsePreviewText.Foreground = Accent;
                    literalToggle.Content = "Keep literal";
                }
            }
            else
            {
                parsePreviewBar.Visibility = Visibility.Collapsed;
            }

            foreach (var (id, tile) in buttons) tile.Background = id == helper ? AccentWash(0.14) : Solid(Microsoft.UI.Colors.Transparent);
            mode.Visibility = helper == null ? Visibility.Collapsed : Visibility.Visible;
            if (helper != null) give.Content = TasksCopy.GiveTo(BotName(helper));

            // Effective values (manual overrides parsed).
            var effDue = dueExplicitlySet ? manualDue : parsed.Due;
            var effHasTime = dueExplicitlySet ? manualDueHasTime : parsed.HasTime;
            var effRepeat = repeatExplicitlySet ? manualRepeat : parsed.RepeatRule;
            var effPriority = manualPriority ?? parsed.Priority ?? 0;
            var effTags = manualTags.Concat(parsed.Tags).Distinct(StringComparer.OrdinalIgnoreCase).Take(TaskTagPickerDialog.MaxTags).ToList();

            // Due button
            dateButton.Content = effDue is { } d ? TodoWords.NewTaskDue(d, effHasTime, now, zone) : TasksCopy.NoDate;
            var dates = new MenuFlyout();
            dates.Items.Add(Item(TasksCopy.Today, () => { manualDue = now; manualDueHasTime = false; dueExplicitlySet = true; }));
            dates.Items.Add(Item(TasksCopy.Tomorrow, () => { manualDue = now.AddDays(1); manualDueHasTime = false; dueExplicitlySet = true; }));
            dates.Items.Add(Item(TasksCopy.NextWeek, () => { manualDue = now.AddDays(7); manualDueHasTime = false; dueExplicitlySet = true; }));
            dates.Items.Add(Item("Choose Date & Time…", () => OpenDateTimeFlyout(dateButton, effDue, effHasTime, allowTime: true, (dt, ht) => { manualDue = dt; manualDueHasTime = ht; dueExplicitlySet = true; })));
            if (effDue != null)
            {
                dates.Items.Add(new MenuFlyoutSeparator());
                dates.Items.Add(Item(TasksCopy.NoDueDate, () => { manualDue = null; manualDueHasTime = false; dueExplicitlySet = true; }));
            }
            dateButton.Flyout = dates;

            // Start Date button
            startButton.Content = startsDate is { } sd ? TodoWords.NewTaskDue(sd, false, now, zone) : "None";
            var startsMenu = new MenuFlyout();
            startsMenu.Items.Add(Item(TasksCopy.Today, () => startsDate = now));
            startsMenu.Items.Add(Item(TasksCopy.Tomorrow, () => startsDate = now.AddDays(1)));
            startsMenu.Items.Add(Item(TasksCopy.NextWeek, () => startsDate = now.AddDays(7)));
            startsMenu.Items.Add(Item(TasksCopy.ChooseDate, () => OpenDateTimeFlyout(startButton, startsDate, false, allowTime: false, (dt, _) => startsDate = dt)));
            if (startsDate != null)
            {
                startsMenu.Items.Add(new MenuFlyoutSeparator());
                startsMenu.Items.Add(Item("Clear Start Date", () => startsDate = null));
            }
            startButton.Flyout = startsMenu;

            // Repeat button
            repeatRowHost.Visibility = RepeatAllowed() ? Visibility.Visible : Visibility.Collapsed;
            repeatButton.Content = effRepeat != null ? TodoWords.RepeatLabel(effRepeat) : "Never";
            var repeatsMenu = new MenuFlyout();
            foreach (var r in TodoWords.RepeatRules)
            {
                var rule = r;
                repeatsMenu.Items.Add(Item(TodoWords.RepeatLabel(rule), () => { manualRepeat = rule; repeatExplicitlySet = true; }));
            }
            if (store.CustomRepeatSupported)
            {
                repeatsMenu.Items.Add(new MenuFlyoutSeparator());
                foreach (var cr in TodoWords.CustomRepeatPresets)
                {
                    var rule = cr;
                    repeatsMenu.Items.Add(Item(TodoWords.RepeatLabel(rule), () => { manualRepeat = rule; repeatExplicitlySet = true; }));
                }
            }
            if (effRepeat != null)
            {
                repeatsMenu.Items.Add(new MenuFlyoutSeparator());
                repeatsMenu.Items.Add(Item(TasksCopy.DontRepeat, () => { manualRepeat = null; repeatExplicitlySet = true; }));
            }
            repeatButton.Flyout = repeatsMenu;

            // Priority button
            priorityButton.Content = effPriority > 0 ? TodoViews.PriorityWord(effPriority) : "None";
            var levels = new MenuFlyout();
            foreach (var level in new[] { 1, 2, 3 }) { var l = level; levels.Items.Add(Item(TodoViews.PriorityWord(l), () => manualPriority = l)); }
            if (effPriority > 0 || manualPriority != null) levels.Items.Add(Item(TasksCopy.NoPriority, () => manualPriority = 0));
            priorityButton.Flyout = levels;

            // List button
            listButton.Content = list is { } shownId && store.Sections.FirstOrDefault(x => x.Id == shownId) is { } shown ? shown.Name : TasksCopy.NoList;
            var lists = new MenuFlyout();
            lists.Items.Add(Item(TasksCopy.NoList, () => list = null));
            foreach (var each in store.Sections) { var sid = each.Id; lists.Items.Add(Item(each.Name, () => list = sid)); }
            listButton.Flyout = lists;

            // Tags button
            tagsButton.Content = effTags.Count > 0 ? string.Join(", ", effTags.Select(t => "#" + t)) : "Add tags";
            BuildTagsFlyout();

            // Goal + Milestone button
            var activeGoals = GoalViews.Groups(store.Goals).Active;
            var pickedGoal = goalId != null ? store.FindGoal(goalId) : null;
            var pickedMs = pickedGoal?.Milestone(milestoneId);
            goalButton.Content = pickedGoal == null
                ? "No Goal"
                : pickedMs != null ? $"{pickedGoal.Shown} · {pickedMs.Title}" : pickedGoal.Shown;
            var goalMenu = new MenuFlyout();
            goalMenu.Items.Add(Item("No Goal", () => { goalId = null; milestoneId = null; }));
            foreach (var g in activeGoals)
            {
                var gg = g;
                var openMs = gg.Milestones.Where(m => !m.Done).ToList();
                if (openMs.Count > 0)
                {
                    var sub = new MenuFlyoutSubItem { Text = gg.Shown };
                    sub.Items.Add(Item("No Milestone", () => { goalId = gg.Id; milestoneId = null; }));
                    foreach (var m in openMs)
                    {
                        var mm = m;
                        sub.Items.Add(Item(mm.Title, () => { goalId = gg.Id; milestoneId = mm.Id; }));
                    }
                    goalMenu.Items.Add(sub);
                }
                else
                {
                    goalMenu.Items.Add(Item(gg.Shown, () => { goalId = gg.Id; milestoneId = null; }));
                }
            }
            goalButton.Flyout = goalMenu;

            if (status.Tag as string != "added" && status.Tag as string != "failed")
            {
                status.Text = helper == null ? "" : alone ? TasksCopy.StartsRightAway(BotName(helper)) : TodoWords.NewTaskHelpNote(BotName(helper));
                status.Foreground = Secondary;
            }
        }
        literalToggle.Click += (_, _) => { keepLiteral = !keepLiteral; Paint(); };

        var form = new StackPanel { Spacing = 8, Width = 480 };
        form.Children.Add(discardBar);
        form.Children.Add(Header(TasksCopy.TaskTitle));
        form.Children.Add(title);
        form.Children.Add(parsePreviewBar);
        form.Children.Add(notes);

        form.Children.Add(Header(TasksCopy.WhosInvolved));
        form.Children.Add(new ScrollViewer
        {
            Content = people,
            HorizontalScrollMode = ScrollMode.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollMode = ScrollMode.Disabled,
        });
        form.Children.Add(mode);

        // Structured Schedule section
        form.Children.Add(Header("Schedule"));
        var scheduleCard = new StackPanel { Spacing = 8 };
        scheduleCard.Children.Add(Row("Due", dateButton));
        if (store.FieldsSupported) scheduleCard.Children.Add(Row("Start Date", startButton));
        scheduleCard.Children.Add(repeatRowHost);
        form.Children.Add(Card(scheduleCard, 10));

        // Structured Organize section
        var activeGoalsInit = GoalViews.Groups(store.Goals).Active;
        if (store.Sections.Count > 0 || store.FieldsSupported || (store.GoalsSupported && activeGoalsInit.Count > 0))
        {
            form.Children.Add(Header("Organize"));
            var organizeCard = new StackPanel { Spacing = 8 };
            if (store.Sections.Count > 0) organizeCard.Children.Add(Row(TasksCopy.List, listButton));
            if (store.FieldsSupported)
            {
                organizeCard.Children.Add(Row(TasksCopy.Priority, priorityButton));
                organizeCard.Children.Add(Row("Tags", tagsButton));
            }
            if (store.GoalsSupported && activeGoalsInit.Count > 0)
                organizeCard.Children.Add(Row("Goal", goalButton));
            form.Children.Add(Card(organizeCard, 10));
        }

        form.Children.Add(status);
        Paint();

        dialog = new ContentDialog
        {
            Title = TasksCopy.NewTask,
            Content = new ScrollViewer { Content = form, MaxHeight = 600, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
            PrimaryButtonText = TasksCopy.Add,
            CloseButtonText = TasksCopy.Done,
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = false,
        };
        title.TextChanged += (_, _) =>
        {
            dialog.IsPrimaryButtonEnabled = title.Text.Trim().Length > 0;
            discardBar.Visibility = Visibility.Collapsed;
            Paint();
        };
        notes.TextChanged += (_, _) => discardBar.Visibility = Visibility.Collapsed;

        // Unsaved-draft close guard.
        dialog.Closing += (_, e) =>
        {
            if (e.Result == ContentDialogResult.Primary || allowDiscard) return;
            var hasDraft = title.Text.Trim().Length > 0 || notes.Text.Trim().Length > 0;
            if (!hasDraft) return;
            e.Cancel = true;
            discardBar.Visibility = Visibility.Visible;
        };

        dialog.PrimaryButtonClick += async (_, e) =>
        {
            var deferral = e.GetDeferral();
            dialog.IsPrimaryButtonEnabled = false;
            form.IsHitTestVisible = false;
            try
            {
                var now = DateTimeOffset.Now;
                var parsed = CurrentParse(now);
                var who = helper == null ? TodoWho.Me : alone ? TodoWho.Bot : TodoWho.Together;
                var effTitle = keepLiteral ? title.Text.Trim() : (parsed.Title.Length > 0 ? parsed.Title : title.Text.Trim());
                var effDue = dueExplicitlySet ? manualDue : parsed.Due;
                var effHasTime = dueExplicitlySet ? manualDueHasTime : parsed.HasTime;
                var effRepeat = repeatExplicitlySet ? manualRepeat : parsed.RepeatRule;
                var effPriority = manualPriority ?? parsed.Priority ?? 0;
                var effTags = manualTags.Concat(parsed.Tags).Distinct(StringComparer.OrdinalIgnoreCase).Take(TaskTagPickerDialog.MaxTags).ToList();

                var fields = TodoWire.NewTask(
                    title: effTitle,
                    who: who,
                    bot: helper,
                    due: effDue is { } d ? TodoDates.Wire(d, effHasTime, zone) : null,
                    repeatRule: effRepeat,
                    prep: false,
                    notes: notes.Text.Trim(),
                    steps: null,
                    sourceKind: "app",
                    fieldsSupported: store.FieldsSupported,
                    goal: store.GoalsSupported ? goalId : null,
                    milestone: store.GoalsSupported ? milestoneId : null);

                if (store.FieldsSupported)
                {
                    if (effPriority > 0) fields["priority"] = effPriority;
                    if (effTags.Count > 0) fields["tags"] = new JsonArray([.. effTags.Select(t => (JsonNode)t)]);
                    if (startsDate is { } sd) fields["starts"] = TodoDates.Wire(sd, false, zone);
                }
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
                    // Your own: the dialog stays open for rapid entry.
                    e.Cancel = true;
                    created(made);
                    title.Text = "";
                    notes.Text = "";
                    manualDue = startDay;
                    manualDueHasTime = false;
                    dueExplicitlySet = startDay != null;
                    startsDate = null;
                    manualRepeat = null;
                    repeatExplicitlySet = false;
                    manualPriority = null;
                    manualTags.Clear();
                    keepLiteral = false;
                    status.Tag = "added";
                    status.Text = "✓ " + TasksCopy.Added(made.Title);
                    status.Foreground = Secondary;
                    Paint();
                    title.Focus(FocusState.Programmatic);
                }
                else
                {
                    allowDiscard = true;
                    created(made);
                }
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
