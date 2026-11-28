using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Browser;
using Hermes.Core.Kanban;
using Hermes.Core.PhoneCalls;
using Hermes.Core.Tasks;
using HermesHQ.Features.Artifacts;
using HermesHQ.Features.Attachments;
using HermesHQ.Features.Browser;
using HermesHQ.Features.Kanban;
using HermesHQ.Features.PhoneCalls;
using HermesHQ.Features.Workspace;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.Windows.Storage.Pickers;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.Tasks;

/// A task beside the list (`App/Pages/Tasks/TaskPlainView.swift`, commits 882d6161f / 6efec2a92 / c1502804b):
/// live question `Choices` buttons + `AskActionLinks` pills + `browser_ask_user` Watch Browser handoff card,
/// inline step edit/reorder/handoff/promote ("Turn into Task"), pill `TaskTagPickerDialog`, `SuggestedTitle` accept row,
/// `FlushUnsavedEdits` on unload, remote gateway task document download/preview/Share/Save As, and WebView2 Task Page.
internal sealed class TaskPane : UserControl
{
    private readonly TasksStore _store;
    private readonly string _id;
    private readonly TasksPage _page;
    private readonly Microsoft.UI.Dispatching.DispatcherQueue _ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
    private readonly StackPanel _body = new() { Spacing = 8, Padding = new Thickness(16, 4, 16, 24) };
    private readonly TextBlock _barTitle = Text("", 14, bold: true, wrap: false);
    private string? _notes;
    private TextBox? _titleBox, _notesBox, _stepBox;
    private string? _draggingStepId;
    private BrowserSubscription? _browserSub;
    private static readonly TimeZoneInfo Zone = TimeZoneInfo.Local;

    public TaskPane(TasksStore store, string id, TasksPage page)
    {
        _store = store;
        _id = id;
        _page = page;
        AutomationProperties.SetAutomationId(this, "tasks.task");

        var close = new Button { Content = new FontIcon { Glyph = "\uE711", FontSize = 14 }, Style = Style("QuietButtonStyle") };
        AutomationProperties.SetName(close, "Close Task");
        close.Click += (_, _) => _page.CloseTask();

        var menu = new MenuFlyout();
        menu.Opening += (_, _) => FillMoreMenu(menu);
        var more = new Button { Content = new FontIcon { Glyph = "\uE712", FontSize = 14 }, Style = Style("QuietButtonStyle"), Flyout = menu };
        AutomationProperties.SetName(more, "More");

        _barTitle.HorizontalAlignment = HorizontalAlignment.Center;
        _barTitle.VerticalAlignment = VerticalAlignment.Center;

        var bar = new Grid { Padding = new Thickness(8, 8, 8, 4) };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.Children.Add(close);
        Grid.SetColumn(_barTitle, 1);
        bar.Children.Add(_barTitle);
        Grid.SetColumn(more, 2);
        bar.Children.Add(more);

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(bar);
        var scroll = new ScrollViewer { Content = _body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Disabled };
        Grid.SetRow(scroll, 1);
        root.Children.Add(scroll);
        Content = root;

        Loaded += (_, _) => SubscribeBrowser();
        Unloaded += (_, _) =>
        {
            FlushUnsavedEdits();
            UnsubscribeBrowser();
        };
        Render();
    }

    private void SubscribeBrowser()
    {
        if (_browserSub != null || BrowserFeature.Service is not { } service) return;
        _browserSub = service.Activity.Subscribe(() => _ui.TryEnqueue(() => { if (!AppShutdown.Stopping) Render(); }));
    }

    private void UnsubscribeBrowser()
    {
        _browserSub?.Cancel();
        _browserSub = null;
    }

    private bool Typing => new[] { _titleBox, _notesBox, _stepBox }.Any(b => b != null && b.FocusState != FocusState.Unfocused);

    private Task<bool> Patch(JsonObject fields) => _store.PatchAsync(_id, fields);

    /// Commits any pending inline Title or Notes edits before unloading, closing, or switching tasks.
    public void FlushUnsavedEdits()
    {
        if (_store.Find(_id) is not { } task) return;
        if (_titleBox != null)
        {
            var nextTitle = _titleBox.Text.Trim();
            if (nextTitle.Length > 0 && nextTitle != task.Title)
                _ = Patch(new JsonObject { ["title"] = nextTitle });
        }
        if (_notesBox != null)
        {
            var nextNotes = _notesBox.Text.Trim();
            _notes = null;
            if (nextNotes != task.Notes.Trim())
                _ = Patch(new JsonObject { ["notes"] = nextNotes });
        }
    }

    private void FillMoreMenu(MenuFlyout menu)
    {
        menu.Items.Clear();
        if (_store.Find(_id) is not { } task) return;
        var dup = new MenuFlyoutItem { Text = TasksCopy.Duplicate, Icon = new FontIcon { Glyph = "\uE8C8" } };
        dup.Click += async (_, _) =>
        {
            if (await _store.DuplicateAsync(_id) is { } made)
                _page.ShowNotice($"Duplicated “{(made.Title.Length == 0 ? TasksCopy.Untitled : made.Title)}”");
        };
        menu.Items.Add(dup);
        if (task.Log.Count > 0)
        {
            var history = new MenuFlyoutItem { Text = "History", Icon = new FontIcon { Glyph = "\uE81C" } };
            history.Click += (_, _) => _ = ShowHistoryDialogAsync(task);
            menu.Items.Add(history);
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        var delete = new MenuFlyoutItem { Text = TasksCopy.Delete, Icon = new FontIcon { Glyph = "\uE74D" }, Foreground = Critical };
        delete.Click += (_, _) => _ = _page.ConfirmDeleteAsync(_id);
        menu.Items.Add(delete);
    }

    private async Task ShowHistoryDialogAsync(TodoTask task)
    {
        var now = DateTimeOffset.Now;
        var stack = new StackPanel { Spacing = 8, Width = 380 };
        foreach (var entry in task.Log.Reverse())
        {
            var when = TodoWords.Ago(entry.At, now, Zone);
            var who = entry.By == "you" ? "You" : BotName(entry.By);
            var row = new StackPanel { Spacing = 2 };
            row.Children.Add(Text(entry.Text, 13));
            row.Children.Add(Text(string.Join(" · ", new[] { who, when }.Where(s => s.Length > 0)), 11.5, color: Secondary));
            stack.Children.Add(Card(row, 8));
        }
        await ShowAsync(XamlRoot, new ContentDialog
        {
            Title = "Task History",
            Content = new ScrollViewer { Content = stack, MaxHeight = 420 },
            CloseButtonText = TasksCopy.Done,
            DefaultButton = ContentDialogButton.Close,
        });
    }

    private (BrowserRow Row, BrowserScope Scope)? LiveBrowserAsk(TodoTask task)
    {
        if (task.IsDone || task.Helper is not { } profile || BrowserFeature.Service is not { } service) return null;
        var sessionIds = new List<string>();
        if (!string.IsNullOrEmpty(task.Chat?.SessionId)) sessionIds.Add(task.Chat!.SessionId);
        if (!string.IsNullOrEmpty(task.SourceSessionId) && !sessionIds.Contains(task.SourceSessionId, StringComparer.Ordinal))
            sessionIds.Add(task.SourceSessionId);
        var ownChats = new List<string>();
        if (PageKit.Bots.FirstOrDefault(b => b.Name == profile)?.Canonical?.OpenId is { Length: > 0 } cid)
            ownChats.Add(cid);
        var scope = new BrowserScope(profile, BotName(profile), sessionIds: sessionIds, ownChats: ownChats);
        var row = scope.DrivenRow(service.Activity.Rows) ?? scope.Row(service.Activity.Rows);
        if (row == null || (row.Control != BrowserControl.Waiting && string.IsNullOrWhiteSpace(row.Ask))) return null;
        return (row, scope);
    }

    public void Render()
    {
        if (Typing) return;
        _body.Children.Clear();
        if (_store.Find(_id) is not { } task)
        {
            _barTitle.Text = TasksCopy.Title;
            _body.Children.Add(Text(TasksCopy.ThisTaskWasDeleted, 14, color: Secondary));
            return;
        }
        var now = DateTimeOffset.Now;
        _barTitle.Text = TodoViews.ListTitle(task, _store.Sections);

        // The circle and inline-editable title.
        var head = new Grid { ColumnSpacing = 10 };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.Children.Add(TasksPage.Circle(task, () => _page.ToggleDone(task)));
        var title = _titleBox = new TextBox
        {
            Text = task.Title, FontSize = 20, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, PlaceholderText = TasksCopy.Untitled,
            BorderThickness = new Thickness(0), Background = Solid(Microsoft.UI.Colors.Transparent),
        };
        AutomationProperties.SetName(title, "Title");
        void SaveTitle()
        {
            var text = title.Text.Trim();
            if (text.Length > 0 && text != task.Title) _ = Patch(new JsonObject { ["title"] = text });
        }
        title.LostFocus += (_, _) => SaveTitle();
        title.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) { e.Handled = true; SaveTitle(); Focus(FocusState.Programmatic); } };
        Grid.SetColumn(title, 1);
        head.Children.Add(title);
        _body.Children.Add(head);

        // Suggested title accept row (`AcceptSuggestedTitleAsync`).
        if (TodoViews.CurrentSuggestedTitle(task) is { } suggestedTitle && !task.IsDone)
        {
            var sgGrid = new Grid { ColumnSpacing = 8 };
            sgGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            sgGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var sgInfo = new StackPanel { Spacing = 1 };
            sgInfo.Children.Add(Text("Suggested title", 11, bold: true, color: Accent));
            sgInfo.Children.Add(Text(suggestedTitle, 13));
            sgGrid.Children.Add(sgInfo);
            var useBtn = Push("Use", () => _ = _store.AcceptSuggestedTitleAsync(task.Id, suggestedTitle, task.Title), accent: true);
            useBtn.VerticalAlignment = VerticalAlignment.Center;
            useBtn.IsEnabled = !_store.ReadOnlyGateway;
            AutomationProperties.SetAutomationId(useBtn, "task.suggested-title.accept");
            Grid.SetColumn(useBtn, 1);
            sgGrid.Children.Add(useBtn);
            var sgCard = Card(sgGrid, 8);
            AutomationProperties.SetAutomationId(sgCard, "task.suggested-title");
            _body.Children.Add(sgCard);
        }

        if (task.IsDone) _body.Children.Add(Text(TodoWords.Completed(task, now, Zone), 13, color: Secondary));

        // Core metadata lines
        _body.Children.Add(Line("\uE787", DueButton(task, now)));
        if (TodoViews.StartWords(task, now, Zone) is { } startWords)
            _body.Children.Add(Line("\uE768", StartDateButton(task, startWords)));
        _body.Children.Add(Line("\uE77B", WhoButton(task)));
        if (task.RepeatRule != null) _body.Children.Add(Line("\uE8EE", RepeatButton(task, TodoWords.RepeatLabel(task.RepeatRule))));
        if (task.Priority > 0) _body.Children.Add(Line("\uE7C1", PriorityButton(task, TodoViews.PriorityWord(task.Priority))));
        if (task.Tags.Count > 0) _body.Children.Add(Line("\uE8EC", Quiet(string.Join(", ", task.Tags.Select(t => "#" + t)), () => _ = EditTagsAsync(task))));
        if (_store.GoalsSupported && task.Goal is { } gid && _store.FindGoal(gid) is { } linkedGoal)
        {
            var msTitle = linkedGoal.Milestone(task.Milestone)?.Title;
            var label = msTitle != null ? $"{linkedGoal.Shown} · {msTitle}" : linkedGoal.Shown;
            _body.Children.Add(Line("\uE91F", GoalButton(task, label)));
        }

        // Quick "+ Add" chips for empty metadata
        var adds = new TaskWrapPanel { HorizontalSpacing = 2, VerticalSpacing = 2 };
        adds.Margin = new Thickness(30, 0, 0, 0);
        if (task.Notes.Length == 0 && _notes == null)
            adds.Children.Add(Quiet(TasksCopy.PlusNotes, () => { _notes = ""; Render(); _notesBox?.Focus(FocusState.Programmatic); }));
        if (task.Starts == null && _store.FieldsSupported)
            adds.Children.Add(StartDateButton(task, TasksCopy.PlusStartDate));
        var canRepeat = task.WhoKind == TodoWho.Me || (task.WhoKind == TodoWho.Together && _store.FieldsSupported);
        if (task.RepeatRule == null && canRepeat)
            adds.Children.Add(RepeatButton(task, TasksCopy.PlusRepeat));
        if (task.Priority == 0 && _store.FieldsSupported)
            adds.Children.Add(PriorityButton(task, TasksCopy.PlusPriority));
        if (task.Tags.Count == 0 && _store.FieldsSupported)
            adds.Children.Add(Quiet(TasksCopy.PlusTags, () => _ = EditTagsAsync(task)));
        if (task.Goal == null && _store.GoalsSupported && GoalViews.Groups(_store.Goals).Active.Count > 0)
            adds.Children.Add(GoalButton(task, "+ Goal"));
        if (adds.Children.Count > 0) _body.Children.Add(adds);

        // 1) Live `browser_ask_user` Watch Browser handoff card (882d6161f)
        if (LiveBrowserAsk(task) is { } liveBrowser)
        {
            var bStack = new StackPanel { Spacing = 8 };
            var bHead = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            bHead.Children.Add(Face(liveBrowser.Scope.Profile, 18));
            bHead.Children.Add(Text($"{BotName(liveBrowser.Scope.Profile)} needs you in its browser", 12.5, bold: true, color: HermesHQ.Features.Settings.ThemeService.Ink(Orange)));
            bStack.Children.Add(bHead);
            bStack.Children.Add(Text(string.IsNullOrWhiteSpace(liveBrowser.Row.Ask) ? "Waiting for you in the browser." : liveBrowser.Row.Ask!, 13.5, bold: true));
            var watchBtn = Push("Watch Browser", () => BrowserFeature.Open(liveBrowser.Scope), accent: true);
            watchBtn.HorizontalAlignment = HorizontalAlignment.Stretch;
            AutomationProperties.SetAutomationId(watchBtn, "task.browser-ask.open");
            bStack.Children.Add(watchBtn);
            var bCard = Card(bStack, 12);
            bCard.BorderBrush = Solid(Orange);
            AutomationProperties.SetAutomationId(bCard, "task.browser-ask");
            _body.Children.Add(bCard);
        }

        // 2) Live Question Ask Card (`TodoViews.AsksYou`: status note / summary + AskActionLinks pills + Choices buttons)
        var actionLinks = TodoViews.AskActionLinks(task);
        if (TodoViews.AsksYou(task))
        {
            var isNeedsYou = task.Status == "needs_you";
            var accentColor = isNeedsYou ? Orange : Green;
            var askStack = new StackPanel { Spacing = 8 };
            var askHead = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            if (task.Helper is { } h) askHead.Children.Add(Face(h, 18));
            var stateTime = TodoWords.StateTime(task, now, Zone);
            askHead.Children.Add(Text(
                (isNeedsYou ? $"{BotName(task.Helper)} asks" : $"{BotName(task.Helper)} finished its part")
                + (stateTime != null ? $" · {stateTime}" : ""),
                12.5, bold: true, color: HermesHQ.Features.Settings.ThemeService.Ink(accentColor)));
            askStack.Children.Add(askHead);

            if (TodoWords.BotWords(task) is { } botWords)
                askStack.Children.Add(Text(botWords, 13.5));
            if (isNeedsYou && !string.IsNullOrWhiteSpace(task.StatusNote) && task.StatusNote.Trim() != task.Page?.Summary?.Trim())
                askStack.Children.Add(Text(task.StatusNote.Trim(), 13.5, bold: true));

            if (actionLinks.Count > 0)
            {
                var linksPanel = new StackPanel { Spacing = 6 };
                for (var idx = 0; idx < actionLinks.Count; idx++)
                {
                    var link = actionLinks[idx];
                    var primary = task.Choices.Count == 0 && idx == 0;
                    var linkBtn = Push((string.IsNullOrWhiteSpace(link.Title) ? link.Ref : link.Title) + "  ↗",
                        () => { if (link.LinkUrl is { } u && Uri.TryCreate(u, UriKind.Absolute, out var uri)) _ = Launcher.LaunchUriAsync(uri); },
                        accent: primary);
                    linkBtn.HorizontalAlignment = HorizontalAlignment.Stretch;
                    AutomationProperties.SetAutomationId(linkBtn, $"task.ask.link.{idx}");
                    linksPanel.Children.Add(linkBtn);
                }
                askStack.Children.Add(linksPanel);
            }

            if (task.Choices.Count > 0)
            {
                var choicesWrap = new TaskWrapPanel { HorizontalSpacing = 6, VerticalSpacing = 6 };
                for (var idx = 0; idx < task.Choices.Count; idx++)
                {
                    var choice = task.Choices[idx];
                    var btn = Push(choice, () => AnswerChoice(task, choice), accent: idx == 0);
                    AutomationProperties.SetName(btn, $"Answer {BotName(task.Helper)}: {choice}");
                    AutomationProperties.SetAutomationId(btn, $"task.choice.{idx}");
                    choicesWrap.Children.Add(btn);
                }
                askStack.Children.Add(choicesWrap);
            }

            var askCard = Card(askStack, 12);
            askCard.BorderBrush = Solid(accentColor);
            AutomationProperties.SetAutomationId(askCard, "task.ask");
            _body.Children.Add(askCard);
        }
        else
        {
            var words = TodoViews.Row(task, TodoGroupKind.Open, now, Zone, BotName);
            if (words.Note is { } note && !task.IsDone)
            {
                var toneColor = words.Tone == TodoTone.Ready ? Green : words.Tone == TodoTone.NeedsYou ? Red : Blue;
                _body.Children.Add(Card(Text(note, 13, color: HermesHQ.Features.Settings.ThemeService.Ink(toneColor))));
            }
        }

        // 3) Close offer banner ("Mark Done" / "Keep Open")
        if (task.Offer is { Kept: false } closeOffer && !task.IsDone)
        {
            var offerStack = new StackPanel { Spacing = 6 };
            offerStack.Children.Add(Text($"{BotName(closeOffer.By)} thinks this looks done", 13, bold: true, color: HermesHQ.Features.Settings.ThemeService.Ink(Green)));
            if (!string.IsNullOrWhiteSpace(closeOffer.Text)) offerStack.Children.Add(Text(closeOffer.Text, 13));
            var btns = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            btns.Children.Add(Push(TasksCopy.MarkDone, () => _ = _page.ToggleDone(task), accent: true));
            btns.Children.Add(Quiet("Keep Open", () => _ = _store.KeepTaskOpenAsync(task.Id)));
            offerStack.Children.Add(btns);
            _body.Children.Add(Card(offerStack, 10));
        }

        // 4) Task Page gist (when not already shown in Ask Card)
        if (!TodoViews.AsksYou(task) && task.Page is { } pageGist)
        {
            var pageStack = new StackPanel { Spacing = 4 };
            if (!string.IsNullOrWhiteSpace(pageGist.Summary)) pageStack.Children.Add(Text(pageGist.Summary, 13));
            if (!string.IsNullOrWhiteSpace(pageGist.Next)) pageStack.Children.Add(Text("Next: " + pageGist.Next, 12, color: Accent));
            _body.Children.Add(Card(pageStack, 10));
        }

        // 5) Quick actions bar
        var nowPlan = TaskNow.Pick(task, BotName);
        var quickRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(0, 4, 0, 4) };
        if (nowPlan.Primary is { } primaryAct)
            quickRow.Children.Add(Push(primaryAct.Title, () => ExecuteNowAction(task, primaryAct), accent: true));
        quickRow.Children.Add(Quiet(task.Chat != null ? "Open Task Chat" : "Task Chat", () => OpenTaskChat(task)));
        if (_store.PagesSupported || task.PageAt != null || task.Page != null)
            quickRow.Children.Add(Quiet("Task Page", () => _ = OpenTaskPageAsync(task)));
        foreach (var sec in nowPlan.Secondary.Take(2))
        {
            var s = sec;
            quickRow.Children.Add(Quiet(s.Title, () => ExecuteNowAction(task, s)));
        }
        _body.Children.Add(new ScrollViewer
        {
            Content = quickRow, HorizontalScrollMode = ScrollMode.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollMode = ScrollMode.Disabled,
        });

        if (task.SourceFrom?.Line(now, Zone) is { Length: > 0 } fromLine)
            _body.Children.Add(Line("\uE71B", Text("From " + fromLine, 12, color: Secondary)));

        // 6) Notes (AcceptsReturn set BEFORE Text per WinUI rule)
        if (task.Notes.Length > 0 || _notes != null)
        {
            _body.Children.Add(Header(TasksCopy.Notes));
            var notes = _notesBox = new TextBox
            {
                AcceptsReturn = true,
                Text = _notes ?? task.Notes,
                TextWrapping = TextWrapping.Wrap,
                MinHeight = 60,
                PlaceholderText = TasksCopy.Notes,
            };
            AutomationProperties.SetName(notes, TasksCopy.Notes);
            notes.LostFocus += (_, _) =>
            {
                var text = notes.Text.Trim();
                _notes = null;
                if (text != task.Notes.Trim()) _ = Patch(new JsonObject { ["notes"] = text });
                else Render();
            };
            _body.Children.Add(notes);
        }

        // 7) Steps with inline edit, reorder (Up/Down + drag), handoff, Turn into Task, delete
        var done = task.Steps.Count(s => s.Done);
        var stepsHead = new TextBlock { Margin = new Thickness(0, 14, 0, 4), FontSize = 15 };
        stepsHead.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = TasksCopy.Steps, FontWeight = FontWeights.SemiBold });
        if (task.Steps.Count > 0) stepsHead.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = $"  {done}/{task.Steps.Count}", Foreground = Secondary });
        _body.Children.Add(stepsHead);

        for (var i = 0; i < task.Steps.Count; i++)
        {
            var s = task.Steps[i];
            var index = i;
            var stepRow = new Grid { ColumnSpacing = 6, Padding = new Thickness(4, 2, 4, 2) };
            stepRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            stepRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var check = new CheckBox { IsChecked = s.Done, MinWidth = 0 };
            var label = new TextBlock { TextWrapping = TextWrapping.Wrap };
            label.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = s.Title });
            if (task.WhoKind == TodoWho.Together)
                label.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = "  " + (s.Who == "me" ? TasksCopy.You : BotName(task.Helper)), Foreground = Secondary, FontSize = 12 });
            check.Content = label;
            check.Click += (_, _) => _ = _store.SetStepAsync(_id, s.Id, check.IsChecked == true);
            stepRow.Children.Add(check);

            var stepMenu = new MenuFlyout();
            stepMenu.Items.Add(MenuItem("Edit Step…", () => _ = EditStepPromptAsync(s)));
            if (index > 0) stepMenu.Items.Add(MenuItem("Move Up", () => _ = _store.MoveStepAsync(_id, s.Id, -1)));
            if (index < task.Steps.Count - 1) stepMenu.Items.Add(MenuItem("Move Down", () => _ = _store.MoveStepAsync(_id, s.Id, 1)));
            if (task.WhoKind == TodoWho.Together && task.Helper is { } botId)
            {
                var handoffLabel = s.Who == "bot" ? "Take It Myself" : $"Give to {BotName(botId)}";
                var nextWho = s.Who == "bot" ? "me" : "bot";
                stepMenu.Items.Add(MenuItem(handoffLabel, () => _ = _store.SetStepWhoAsync(_id, s.Id, nextWho)));
            }
            stepMenu.Items.Add(MenuItem("Turn into Task", () => _ = PromoteStepWithNoticeAsync(s)));
            stepMenu.Items.Add(new MenuFlyoutSeparator());
            var remove = new MenuFlyoutItem { Text = TasksCopy.DeleteStep, Icon = new FontIcon { Glyph = "\uE74D" }, Foreground = Critical };
            remove.Click += (_, _) => _ = _store.DeleteStepAsync(_id, s.Id);
            stepMenu.Items.Add(remove);

            var stepActionsBtn = new Button
            {
                Content = new FontIcon { Glyph = "\uE712", FontSize = 12 },
                Style = Style("QuietButtonStyle"),
                Flyout = stepMenu,
                VerticalAlignment = VerticalAlignment.Center,
            };
            AutomationProperties.SetName(stepActionsBtn, $"Actions for step {s.Title}");
            Grid.SetColumn(stepActionsBtn, 1);
            stepRow.Children.Add(stepActionsBtn);

            var stepBorder = new Border { Child = stepRow, CornerRadius = new CornerRadius(6), ContextFlyout = stepMenu };
            if (!_store.ReadOnlyGateway && task.Steps.Count > 1)
            {
                stepBorder.CanDrag = true;
                stepBorder.AllowDrop = true;
                stepBorder.DragStarting += (_, e) =>
                {
                    _draggingStepId = s.Id;
                    e.Data.SetText(s.Title);
                    e.Data.RequestedOperation = DataPackageOperation.Move;
                };
                stepBorder.DropCompleted += (_, _) => _draggingStepId = null;
                stepBorder.DragOver += (_, e) =>
                {
                    if (_draggingStepId == null || _draggingStepId == s.Id) return;
                    e.AcceptedOperation = DataPackageOperation.Move;
                    e.Handled = true;
                };
                stepBorder.Drop += (_, e) =>
                {
                    if (_draggingStepId is not { } fromId || fromId == s.Id) return;
                    _draggingStepId = null;
                    e.Handled = true;
                    _ = _store.ReorderStepAsync(_id, fromId, s.Id);
                };
            }
            _body.Children.Add(stepBorder);
        }

        var add = _stepBox = new TextBox { PlaceholderText = TasksCopy.AddStep };
        AutomationProperties.SetName(add, "Add a Step");
        add.KeyDown += (_, e) =>
        {
            if (e.Key != VirtualKey.Enter || add.Text.Trim().Length == 0) return;
            e.Handled = true;
            var steps = task.Steps.Append(new TodoStep(TodoIds.Make(), add.Text.Trim(), "me", false));
            add.Text = "";
            _ = Patch(new JsonObject { ["steps"] = TodoWire.Steps(steps) });
        };
        _body.Children.Add(add);

        // 8) Attachments & Bot Documents (`task.Made`) with remote download/preview/Share/Save As
        var shownMade = TodoWords.ShownMade(task);
        var attachHead = new Grid { Margin = new Thickness(0, 14, 0, 4) };
        attachHead.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        attachHead.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        attachHead.Children.Add(Text(shownMade.Count > 0 ? $"Attachments  {shownMade.Count}" : "Attachments", 15, bold: true));
        var attachTools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        attachTools.Children.Add(Quiet("+ File", () => _ = PickAndAttachFileAsync(task)));
        attachTools.Children.Add(Quiet("+ Link", () => _ = PromptAttachLinkAsync(task)));
        Grid.SetColumn(attachTools, 1);
        attachHead.Children.Add(attachTools);
        _body.Children.Add(attachHead);

        if (shownMade.Count == 0)
        {
            _body.Children.Add(Text("No files or links attached yet.", 12, color: Tertiary));
        }
        else
        {
            foreach (var made in shownMade)
            {
                var item = made;
                var mGrid = new Grid { ColumnSpacing = 8 };
                mGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                mGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                mGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

                var glyph = item.IsLink ? "\uE71B" : item.IsFile ? "\uE8A5" : "\uE70B";
                mGrid.Children.Add(new FontIcon { Glyph = glyph, FontSize = 14, Foreground = Secondary, VerticalAlignment = VerticalAlignment.Center });

                var mInfo = new StackPanel { Spacing = 1 };
                mInfo.Children.Add(Text(string.IsNullOrWhiteSpace(item.Title) ? item.Ref : item.Title, 13, bold: true, wrap: false));
                if (!string.IsNullOrWhiteSpace(item.Ref) && item.Ref != item.Title)
                    mInfo.Children.Add(Text(item.Ref, 11, color: Secondary, wrap: false));
                Grid.SetColumn(mInfo, 1);
                mGrid.Children.Add(mInfo);

                var mBtns = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
                if (item.LinkUrl is { } linkUrl && Uri.TryCreate(linkUrl, UriKind.Absolute, out var uri))
                {
                    mBtns.Children.Add(Quiet("Open", () => _ = Launcher.LaunchUriAsync(uri)));
                }
                else if (item.IsFile && !string.IsNullOrWhiteSpace(item.Ref))
                {
                    mBtns.Children.Add(Quiet("Open", () => _ = OpenMadeDocumentAsync(task, item)));
                    var fileMenu = new MenuFlyout();
                    fileMenu.Items.Add(MenuItem("Preview", () => _ = OpenMadeDocumentAsync(task, item)));
                    fileMenu.Items.Add(MenuItem("Share…", () => _ = ShareMadeDocumentAsync(task, item)));
                    fileMenu.Items.Add(MenuItem("Save As…", () => _ = SaveAsMadeDocumentAsync(task, item)));
                    fileMenu.Items.Add(MenuItem("Copy Path", () => Copy(item.Ref)));
                    var fileMoreBtn = new Button { Content = new FontIcon { Glyph = "\uE712", FontSize = 12 }, Style = Style("QuietButtonStyle"), Flyout = fileMenu };
                    AutomationProperties.SetName(fileMoreBtn, $"More options for {(string.IsNullOrWhiteSpace(item.Title) ? item.Ref : item.Title)}");
                    mBtns.Children.Add(fileMoreBtn);
                }
                else if (!string.IsNullOrWhiteSpace(item.Ref))
                {
                    mBtns.Children.Add(Quiet("View", () => _ = ShowNotePreviewAsync(item)));
                }

                var removeBtn = new Button { Content = new FontIcon { Glyph = "\uE74D", FontSize = 12 }, Style = Style("QuietButtonStyle") };
                AutomationProperties.SetName(removeBtn, "Remove Attachment");
                removeBtn.Click += (_, _) => _ = ConfirmDetachAsync(task.Id, item);
                mBtns.Children.Add(removeBtn);
                Grid.SetColumn(mBtns, 2);
                mGrid.Children.Add(mBtns);
                _body.Children.Add(Card(mGrid, 8));
            }
        }
    }

    private async Task EditStepPromptAsync(TodoStep step)
    {
        var edited = await PromptAsync(XamlRoot, "Edit Step", "", step.Title, TasksCopy.Save, TasksCopy.AddStep);
        if (edited == null) return;
        await _store.EditStepAsync(_id, step.Id, edited);
    }

    private async Task PromoteStepWithNoticeAsync(TodoStep step)
    {
        if (await _store.PromoteStepAsync(_id, step.Id) is { } created)
            _page.ShowNotice($"Turned “{created.Title}” into a task");
    }

    private void AnswerChoice(TodoTask task, string choice)
    {
        if (task.Chat is { } chat)
        {
            Navigator.Go(new ChatDestination(chat.Profile, chat.SessionId, TaskChatLinks.SessionTitle(task), choice));
            return;
        }
        OpenTaskChat(task, choice);
    }

    // ------------------------------------------------------------------ Remote document preview, Share, Save As (`c1502804b`)

    private async Task<(string LocalPath, string Name)?> FetchMadeFileAsync(TodoTask task, TodoMade item)
    {
        var name = string.IsNullOrWhiteSpace(item.Title) ? Path.GetFileName(item.Ref) : item.Title;
        if (File.Exists(item.Ref)) return (item.Ref, name);
        if (AppState.Client is not { } client) return null;
        var profile = task.Helper ?? task.SourceProfile ?? "default";
        var sessionId = task.Chat?.SessionId ?? task.SourceSessionId;
        try
        {
            var media = AttachmentsFeature.CenterFor(client).Media;
            var localPath = await media.GatewayFileAsync(item.Ref, name, profile, sessionId);
            return (localPath, Hermes.Core.Attachments.MediaStore.KeptName(name, item.Ref));
        }
        catch (Exception ex)
        {
            await FailedAsync(XamlRoot, "Couldn’t Download Document", ex.Message, () => FetchMadeFileAsync(task, item));
            return null;
        }
    }

    private async Task OpenMadeDocumentAsync(TodoTask task, TodoMade item)
    {
        if (await FetchMadeFileAsync(task, item) is not { } fetched) return;
        if (ArtifactFileWindow.OpenRouted(fetched.LocalPath, fetched.Name, item.Ref)) return;
        await MediaActions.OpenAsync(fetched.LocalPath, fetched.Name);
    }

    private async Task ShareMadeDocumentAsync(TodoTask task, TodoMade item)
    {
        if (await FetchMadeFileAsync(task, item) is not { } fetched) return;
        try { await MediaActions.ShareAsync(fetched.LocalPath, fetched.Name); }
        catch (Exception ex) { await FailedAsync(XamlRoot, "Couldn’t Share File", ex.Message, null); }
    }

    private async Task SaveAsMadeDocumentAsync(TodoTask task, TodoMade item)
    {
        if (await FetchMadeFileAsync(task, item) is not { } fetched) return;
        try { await MediaActions.SaveAsAsync(fetched.LocalPath, fetched.Name); }
        catch (Exception ex) { await FailedAsync(XamlRoot, "Couldn’t Save File", ex.Message, null); }
    }

    private async Task ShowNotePreviewAsync(TodoMade item)
    {
        ContentDialog? dialog = null;
        var title = string.IsNullOrWhiteSpace(item.Title) ? "Note" : item.Title;
        var viewer = new FileTextView(title, item.Ref, diff: false, notice: null, markdown: true, save: null, close: () => dialog?.Hide())
        {
            Width = 520,
            Height = 420,
        };
        dialog = new ContentDialog
        {
            Content = viewer,
            CloseButtonText = TasksCopy.Done,
            DefaultButton = ContentDialogButton.Close,
        };
        await ShowAsync(XamlRoot, dialog);
    }

    // ------------------------------------------------------------------ Now actions, Task Chat, WebView2 Task Page

    private void ExecuteNowAction(TodoTask task, TaskNowAction action)
    {
        switch (action.Kind)
        {
            case TaskNowKind.Reopen:
                _ = _store.SetDoneAsync(task.Id, false);
                break;
            case TaskNowKind.MarkDone:
                _ = _page.ToggleDone(task);
                break;
            case TaskNowKind.OpenLink:
                if (action.Target is { } raw && Uri.TryCreate(raw, UriKind.Absolute, out var uri))
                    _ = Launcher.LaunchUriAsync(uri);
                break;
            case TaskNowKind.Call:
                if (action.Target is { } phone)
                    PhoneCallsFeature.OpenCallWindow(new PhoneStartIntent(phone, task.Title), startInReview: false);
                break;
            case TaskNowKind.Share:
                Copy($"{task.Title}\n{task.Notes}".Trim());
                break;
            case TaskNowKind.Answer:
                OpenTaskChat(task, "Answering your question:");
                break;
            case TaskNowKind.AskUpdate:
                OpenTaskChat(task, "Can you share a quick update on this task?");
                break;
            case TaskNowKind.AskStart:
                OpenTaskChat(task, "Please start on this task and let me know what you need.");
                break;
            case TaskNowKind.AskHelp:
                OpenTaskChat(task, TodoWords.HelpQuestion);
                break;
            case TaskNowKind.OpenFile:
                if (!string.IsNullOrWhiteSpace(action.Target))
                {
                    if (task.Made.FirstOrDefault(m => m.Ref == action.Target) is { } matchedMade)
                        _ = OpenMadeDocumentAsync(task, matchedMade);
                    else if (File.Exists(action.Target))
                        _ = MediaActions.OpenAsync(action.Target, Path.GetFileName(action.Target));
                    else if (Uri.TryCreate(action.Target, UriKind.Absolute, out var targetUri) && targetUri.Scheme is "http" or "https")
                        _ = Launcher.LaunchUriAsync(targetUri);
                    else
                        _ = OpenMadeDocumentAsync(task, new TodoMade("", Path.GetFileName(action.Target), "file", action.Target, task.Helper));
                }
                break;
        }
    }

    private void OpenTaskChat(TodoTask task, string? note = null)
    {
        if (task.Chat is { } chat)
        {
            var draft = note != null ? TaskChatLinks.OutgoingTaskPrompt(task, note) : "";
            Navigator.Go(new ChatDestination(chat.Profile, chat.SessionId, TaskChatLinks.SessionTitle(task), draft));
            return;
        }
        var profile = task.Helper ?? "default";
        var bot = PageKit.Bots.FirstOrDefault(b => b.Name == profile) ?? PageKit.Bots.FirstOrDefault();
        if (bot == null) return;
        var prompt = TaskChatLinks.OutgoingTaskPrompt(task, note);
        if (bot.Canonical?.OpenId is { Length: > 0 } cid)
            Navigator.Go(new ChatDestination(bot.Name, cid, TaskChatLinks.SessionTitle(task), prompt));
        else
            Navigator.Go(new BotChatDestination(bot));
    }

    /// Opens the Task Page in a WebView2 window (`ArtifactFileWindow.ShowPage` + `ArtifactHtmlView`) instead of stripping HTML.
    private async Task OpenTaskPageAsync(TodoTask task)
    {
        var names = PageKit.Bots.ToDictionary(b => b.Name, b => b.DisplayName, StringComparer.Ordinal);
        string? html = null;
        try { html = await _store.Api.GetTaskPageHtmlAsync(task.Id, names); } catch (Exception) { }
        var pageTitle = task.Title.Length == 0 ? "Task Page" : task.Title;
        if (string.IsNullOrWhiteSpace(html))
        {
            var fallbackText = $"{pageTitle}\n\n{task.Page?.Summary ?? task.Notes}\n\n{(task.Page?.Next is { Length: > 0 } nx ? "Next: " + nx : "")}".Trim();
            html = WrapPlainAsHtml(pageTitle, fallbackText);
        }
        else if (!html.Contains("<html", StringComparison.OrdinalIgnoreCase) && !html.Contains("<body", StringComparison.OrdinalIgnoreCase))
        {
            html = WrapPlainAsHtml(pageTitle, html);
        }

        OpenHtmlInWebViewWindow($"task-page:{task.Id}", pageTitle, html);
    }

    internal static void OpenHtmlInWebViewWindow(string key, string title, string html)
    {
        var folder = Path.Combine(Path.GetTempPath(), "HermesHQPages");
        Directory.CreateDirectory(folder);
        var safeKey = string.Concat(key.Select(c => char.IsLetterOrDigit(c) ? c : '_'));
        var tempFile = Path.Combine(folder, safeKey + ".html");
        File.WriteAllText(tempFile, html, Encoding.UTF8);
        ArtifactFileWindow.ShowPage(key, title, tempFile, () => new ArtifactHtmlView(tempFile, html) { Title = title });
    }

    internal static string WrapPlainAsHtml(string title, string body)
    {
        var safeTitle = System.Net.WebUtility.HtmlEncode(title);
        var safeBody = System.Net.WebUtility.HtmlEncode(body).Replace("\n", "<br/>");
        return $"<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"color-scheme\" content=\"light dark\"><title>{safeTitle}</title>"
            + "<style>body{font-family:'Segoe UI',system-ui,sans-serif;line-height:1.55;max-width:720px;margin:28px auto;padding:0 20px;}</style></head>"
            + $"<body><h2>{safeTitle}</h2><div>{safeBody}</div></body></html>";
    }

    internal static string StripHtmlToText(string html)
    {
        var noScripts = System.Text.RegularExpressions.Regex.Replace(html, @"<(script|style)[^>]*>[\s\S]*?</\1>", "", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        var withBreaks = System.Text.RegularExpressions.Regex.Replace(noScripts, @"<(br|p|div|li|h[1-6]|tr)[^>]*>", "\n", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        var stripped = System.Text.RegularExpressions.Regex.Replace(withBreaks, @"<[^>]+>", "");
        var decoded = System.Net.WebUtility.HtmlDecode(stripped);
        return System.Text.RegularExpressions.Regex.Replace(decoded, @"\n{3,}", "\n\n").Trim();
    }

    private async Task PickAndAttachFileAsync(TodoTask task)
    {
        try
        {
            if (App.Window is not { } window) return;
            var picker = new FileOpenPicker(window.AppWindow.Id);
            picker.FileTypeFilter.Add("*");
            var file = await picker.PickSingleFileAsync();
            if (file == null || string.IsNullOrEmpty(file.Path)) return;
            var info = new FileInfo(file.Path);
            if (info.Length > TasksStore.FileLimit)
            {
                await FailedAsync(XamlRoot, "File Too Large", "Task attachments can be up to 10 MB.", null);
                return;
            }
            var bytes = await File.ReadAllBytesAsync(file.Path);
            await _store.AttachFileAsync(task.Id, Path.GetFileName(file.Path), bytes);
        }
        catch (Exception ex)
        {
            await FailedAsync(XamlRoot, "Couldn’t Attach File", ex.Message, null);
        }
    }

    private async Task PromptAttachLinkAsync(TodoTask task)
    {
        var urlBox = new TextBox { PlaceholderText = "https://example.com/doc" };
        var titleBox = new TextBox { PlaceholderText = "Title (optional)" };
        var panel = new StackPanel { Spacing = 8, MinWidth = 340 };
        panel.Children.Add(urlBox);
        panel.Children.Add(titleBox);
        var dialog = new ContentDialog
        {
            Title = "Attach Link",
            Content = panel,
            PrimaryButtonText = "Attach",
            CloseButtonText = TasksCopy.Cancel,
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = false,
        };
        urlBox.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = TodoMade.ValidLinkUrl(urlBox.Text) != null;
        if (await ShowAsync(XamlRoot, dialog) != ContentDialogResult.Primary) return;
        await _store.AttachLinkAsync(task.Id, titleBox.Text.Trim(), urlBox.Text.Trim());
    }

    private async Task ConfirmDetachAsync(string taskId, TodoMade item)
    {
        var label = string.IsNullOrWhiteSpace(item.Title) ? "this attachment" : $"“{item.Title}”";
        if (!await ConfirmAsync(XamlRoot, "Remove Attachment?", $"Remove {label} from this task?", "Remove")) return;
        await _store.DetachMadeAsync(taskId, item.Id);
    }

    // ------------------------------------------------------------------ Metadata rows

    private static FrameworkElement Line(string glyph, FrameworkElement value)
    {
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(20) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(new FontIcon { Glyph = glyph, FontSize = 14, Foreground = Secondary, VerticalAlignment = VerticalAlignment.Center });
        value.HorizontalAlignment = HorizontalAlignment.Left;
        Grid.SetColumn(value, 1);
        grid.Children.Add(value);
        return grid;
    }

    private FrameworkElement DueButton(TodoTask task, DateTimeOffset now)
    {
        var due = TodoDates.Due(task.Due, Zone);
        var words = due == null ? TasksCopy.NoDate : TodoWords.DueTile(task, now, Zone);
        var menu = new MenuFlyout();
        void Set(DateTimeOffset? date, bool hasTime) => _ = Patch(new JsonObject { ["due"] = date is { } d ? TodoDates.Wire(d, hasTime, Zone) : null });
        menu.Items.Add(MenuItem(TasksCopy.Today, () => Set(now, false)));
        menu.Items.Add(MenuItem(TasksCopy.Tomorrow, () => Set(now.AddDays(1), false)));
        menu.Items.Add(MenuItem(TasksCopy.NextWeek, () => Set(now.AddDays(7), false)));
        menu.Items.Add(MenuItem(TasksCopy.ChooseDate, () => _ = ChooseDateAsync(due)));
        if (due != null)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            var clear = MenuItem(TasksCopy.NoDueDate, () => Set(null, false));
            clear.Foreground = Critical;
            menu.Items.Add(clear);
        }
        var button = new DropDownButton { Content = words, Flyout = menu };
        if (due == null) button.Foreground = Tertiary;
        AutomationProperties.SetName(button, $"Due: {words}. Change");
        return button;
    }

    private FrameworkElement StartDateButton(TodoTask task, string words)
    {
        var now = DateTimeOffset.Now;
        var menu = new MenuFlyout();
        void Set(DateTimeOffset? date) => _ = Patch(new JsonObject { ["starts"] = date is { } d ? TodoDates.Wire(d, false, Zone) : null });
        menu.Items.Add(MenuItem(TasksCopy.Today, () => Set(now)));
        menu.Items.Add(MenuItem(TasksCopy.Tomorrow, () => Set(now.AddDays(1))));
        menu.Items.Add(MenuItem(TasksCopy.NextWeek, () => Set(now.AddDays(7))));
        menu.Items.Add(MenuItem(TasksCopy.ChooseDate, () => _ = ChooseStartDateAsync(task)));
        if (task.Starts != null)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            var clear = MenuItem("Clear Start Date", () => Set(null));
            clear.Foreground = Critical;
            menu.Items.Add(clear);
        }
        var button = new Button { Content = words, Flyout = menu, Style = Style("QuietButtonStyle") };
        AutomationProperties.SetName(button, task.Starts == null ? "Add Start Date" : $"Start Date: {words}. Change");
        return button;
    }

    private async Task ChooseStartDateAsync(TodoTask task)
    {
        var existing = task.Starts is { Length: >= 10 } raw ? TodoDates.Day(raw[..10], Zone) : null;
        var picker = new CalendarDatePicker { Date = existing ?? DateTimeOffset.Now.AddDays(1), HorizontalAlignment = HorizontalAlignment.Stretch };
        var dialog = new ContentDialog
        {
            Title = "Start Date",
            Content = picker,
            PrimaryButtonText = KanbanCopy.Set,
            CloseButtonText = TasksCopy.Cancel,
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await ShowAsync(XamlRoot, dialog) != ContentDialogResult.Primary || picker.Date is not { } picked) return;
        await Patch(new JsonObject { ["starts"] = TodoDates.Wire(picked, false, Zone) });
    }

    private async Task ChooseDateAsync(TodoDue? due)
    {
        var start = due?.Date ?? DateTimeOffset.Now.AddDays(1);
        var date = new CalendarDatePicker { Date = start, HorizontalAlignment = HorizontalAlignment.Stretch };
        var hasTime = new CheckBox { Content = "Time", IsChecked = due?.HasTime ?? false };
        var time = new TimePicker { Time = due?.HasTime == true ? TimeZoneInfo.ConvertTime(start, Zone).TimeOfDay : new TimeSpan(9, 0, 0) };
        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(date);
        panel.Children.Add(hasTime);
        panel.Children.Add(time);
        var dialog = new ContentDialog
        {
            Title = TasksCopy.Date, Content = panel, PrimaryButtonText = KanbanCopy.Set, CloseButtonText = TasksCopy.Cancel,
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await ShowAsync(XamlRoot, dialog) != ContentDialogResult.Primary || date.Date is not { } picked) return;
        var day = picked.Date;
        var local = hasTime.IsChecked == true ? day + time.Time : day;
        var moment = new DateTimeOffset(local, Zone.GetUtcOffset(local));
        await Patch(new JsonObject { ["due"] = TodoDates.Wire(moment, hasTime.IsChecked == true, Zone) });
    }

    private FrameworkElement WhoButton(TodoTask task)
    {
        var face = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        if (task.Helper is { } helper) face.Children.Add(Face(helper, 18));
        face.Children.Add(Text(TodoViews.Who(task, BotName), 14, wrap: false));
        if (task.Watch.Length > 0 && task.Helper is { } watcher) face.Children.Add(Text($"· watched by {BotName(watcher)}", 14, color: Secondary, wrap: false));
        if (TodoViews.BotState(task) is { } state)
        {
            var c = state.Tone == TodoTone.Ready ? Green : state.Tone == TodoTone.NeedsYou ? Red : Blue;
            face.Children.Add(Text("· " + state.Words, 14, color: HermesHQ.Features.Settings.ThemeService.Ink(c), wrap: false));
        }
        if (task.WhoKind == TodoWho.Me) face.Children.Add(Text("  " + TasksCopy.Assign, 13, color: Secondary, wrap: false));
        var menu = new MenuFlyout();
        menu.Items.Add(new ToggleMenuFlyoutItem
        {
            Text = TasksCopy.JustMe, IsChecked = task.WhoKind == TodoWho.Me,
            Command = new Do(() => _ = Patch(new JsonObject
            {
                ["who"] = "me", ["bot"] = null,
                ["steps"] = TodoWire.Steps(task.Steps.Select(s => s with { Who = "me" })),
            })),
        });
        var with = new MenuFlyoutSubItem { Text = TasksCopy.WithMe };
        var alone = new MenuFlyoutSubItem { Text = TasksCopy.ByItself };
        foreach (var bot in PageKit.Bots)
        {
            var name = bot.Name;
            with.Items.Add(new ToggleMenuFlyoutItem { Text = bot.DisplayName, IsChecked = task.WhoKind == TodoWho.Together && task.Helper == name, Command = new Do(() => _ = Patch(new JsonObject { ["who"] = "together", ["bot"] = name })) });
            alone.Items.Add(new ToggleMenuFlyoutItem { Text = bot.DisplayName, IsChecked = task.WhoKind == TodoWho.Bot && task.Helper == name, Command = new Do(() => _ = Patch(new JsonObject { ["who"] = "bot", ["bot"] = name })) });
        }
        if (with.Items.Count > 0) { menu.Items.Add(with); menu.Items.Add(alone); }
        var button = new DropDownButton { Content = face, Flyout = menu };
        AutomationProperties.SetName(button, $"Who: {TodoViews.Who(task, BotName)}. Change");
        return button;
    }

    private FrameworkElement RepeatButton(TodoTask task, string words)
    {
        var menu = new MenuFlyout();
        foreach (var rule in TodoWords.RepeatRules)
        {
            var r = rule;
            menu.Items.Add(new ToggleMenuFlyoutItem { Text = TodoWords.RepeatLabel(r), IsChecked = task.RepeatRule == r, Command = new Do(() => _ = Patch(new JsonObject { ["repeat"] = r })) });
        }
        if (_store.CustomRepeatSupported)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            foreach (var cr in TodoWords.CustomRepeatPresets)
            {
                var r = cr;
                menu.Items.Add(new ToggleMenuFlyoutItem { Text = TodoWords.RepeatLabel(r), IsChecked = task.RepeatRule == r, Command = new Do(() => _ = Patch(new JsonObject { ["repeat"] = r })) });
            }
        }
        if (task.RepeatRule != null)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            var stop = MenuItem(TasksCopy.DontRepeat, () => _ = Patch(new JsonObject { ["repeat"] = null }));
            stop.Foreground = Critical;
            menu.Items.Add(stop);
        }
        var button = new Button { Content = words, Flyout = menu, Style = Style("QuietButtonStyle") };
        AutomationProperties.SetName(button, task.RepeatRule == null ? "Repeat" : $"Repeats: {words}. Change");
        return button;
    }

    private FrameworkElement PriorityButton(TodoTask task, string words)
    {
        var menu = new MenuFlyout();
        foreach (var level in new[] { 1, 2, 3 })
        {
            var l = level;
            menu.Items.Add(new ToggleMenuFlyoutItem { Text = TodoViews.PriorityWord(l), IsChecked = task.Priority == l, Command = new Do(() => _ = Patch(new JsonObject { ["priority"] = l })) });
        }
        if (task.Priority > 0)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            var none = MenuItem(TasksCopy.NoPriority, () => _ = Patch(new JsonObject { ["priority"] = 0 }));
            none.Foreground = Critical;
            menu.Items.Add(none);
        }
        var button = new Button { Content = words, Flyout = menu, Style = Style("QuietButtonStyle") };
        if (TasksPage.PriorityColor(task.Priority) is { } c) button.Foreground = HermesHQ.Features.Settings.ThemeService.Ink(c);
        AutomationProperties.SetName(button, task.Priority > 0 ? $"{words} priority. Change" : "Priority");
        return button;
    }

    private FrameworkElement GoalButton(TodoTask task, string words)
    {
        var menu = new MenuFlyout();
        if (GoalChoices.Menu(task, _store.Goals, _store.GoalsSupported) is { } choices)
        {
            foreach (var choice in choices)
                menu.Items.Add(BuildGoalChoice(choice));
        }
        var button = new Button { Content = words, Flyout = menu, Style = Style("QuietButtonStyle") };
        AutomationProperties.SetName(button, task.Goal == null ? "Add to Goal" : $"Goal: {words}. Change");
        return button;
    }

    private MenuFlyoutItemBase BuildGoalChoice(GoalChoice choice)
    {
        if (choice.Children.Count > 0)
        {
            var sub = new MenuFlyoutSubItem { Text = choice.Title };
            foreach (var c in choice.Children) sub.Items.Add(BuildGoalChoice(c));
            return sub;
        }
        if (choice.Kind == GoalChoiceKind.OpenGoal && choice.Goal is { } gid)
            return MenuItem(choice.Title, () => _page.OpenGoal(gid));
        if (choice.Kind == GoalChoiceKind.NoGoal)
            return MenuItem(choice.Title, () => _ = _store.SetGoalAsync(_id, null, null));
        var item = new ToggleMenuFlyoutItem { Text = choice.Title, IsChecked = choice.Ticked };
        item.Click += (_, _) => _ = _store.SetGoalAsync(_id, choice.Goal, choice.Milestone);
        return item;
    }

    private async Task EditTagsAsync(TodoTask task)
    {
        var picked = await TaskTagPickerDialog.PresentAsync(XamlRoot, task.Tags, TodoViews.AllTags(_store.Tasks));
        if (picked == null) return;
        await Patch(new JsonObject { ["tags"] = new JsonArray([.. picked.Select(t => (JsonNode)t)]) });
    }

    private static MenuFlyoutItem MenuItem(string text, Action run)
    {
        var item = new MenuFlyoutItem { Text = text };
        item.Click += (_, _) => run();
        return item;
    }
}
