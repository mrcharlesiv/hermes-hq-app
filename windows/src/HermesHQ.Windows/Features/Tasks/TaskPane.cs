using System.Text.Json.Nodes;
using Hermes.Core.Kanban;
using Hermes.Core.PhoneCalls;
using Hermes.Core.Tasks;
using HermesHQ.Features.Kanban;
using HermesHQ.Features.PhoneCalls;
using HermesHQ.Shell;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.Windows.Storage.Pickers;
using Windows.System;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.Tasks;

/// A task beside the list (App/Pages/Tasks/TaskPlainView.swift, the plain task view): ✕ · its list · ⋯; the circle and
/// the title; one line each for when it's due and who has it (with what its bot is doing, and Assign); "+ Notes
/// + Repeat + Priority + Tags" for what it doesn't have yet; what a bot has for you; Notes; Steps with Add step.
internal sealed class TaskPane : UserControl
{
    private readonly TasksStore _store;
    private readonly string _id;
    private readonly TasksPage _page;
    private readonly StackPanel _body = new() { Spacing = 8, Padding = new Thickness(16, 4, 16, 24) };
    private readonly TextBlock _barTitle = Text("", 14, bold: true, wrap: false);
    private string? _notes;
    private TextBox? _titleBox, _notesBox, _stepBox;
    private static readonly TimeZoneInfo Zone = TimeZoneInfo.Local;

    public TaskPane(TasksStore store, string id, TasksPage page)
    {
        _store = store;
        _id = id;
        _page = page;
        AutomationProperties.SetAutomationId(this, "tasks.task");
        var close = new Button { Content = new FontIcon { Glyph = "", FontSize = 14 }, Style = Style("QuietButtonStyle") };
        AutomationProperties.SetName(close, "Close Task");
        close.Click += (_, _) => _page.CloseTask();
        var menu = new MenuFlyout();
        var delete = new MenuFlyoutItem { Text = TasksCopy.Delete, Icon = new FontIcon { Glyph = "" }, Foreground = Critical };
        delete.Click += (_, _) => _ = _page.ConfirmDeleteAsync(_id);
        menu.Items.Add(delete);
        var more = new Button { Content = new FontIcon { Glyph = "", FontSize = 14 }, Style = Style("QuietButtonStyle"), Flyout = menu };
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
        Render();
    }

    private bool Typing => new[] { _titleBox, _notesBox, _stepBox }.Any(b => b != null && b.FocusState != FocusState.Unfocused);

    private Task<bool> Patch(JsonObject fields) => _store.PatchAsync(_id, fields);

    public void Render()
    {
        if (Typing) return;   // what is typed stays; the next change draws it
        _body.Children.Clear();
        if (_store.Find(_id) is not { } task)
        {
            _barTitle.Text = TasksCopy.Title;
            _body.Children.Add(Text(TasksCopy.ThisTaskWasDeleted, 14, color: Secondary));
            return;
        }
        var now = DateTimeOffset.Now;
        _barTitle.Text = TodoViews.ListTitle(task, _store.Sections);

        // The circle and the title (edited in place; Enter or leaving the field saves it).
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
        if (task.IsDone) _body.Children.Add(Text(TodoWords.Completed(task, now, Zone), 13, color: Secondary));

        _body.Children.Add(Line("", DueButton(task, now)));
        _body.Children.Add(Line("", WhoButton(task)));
        if (task.RepeatRule != null) _body.Children.Add(Line("", RepeatButton(task, TodoWords.RepeatLabel(task.RepeatRule))));
        if (task.Priority > 0) _body.Children.Add(Line("", PriorityButton(task, TodoViews.PriorityWord(task.Priority))));
        if (task.Tags.Count > 0) _body.Children.Add(Line("", Quiet(string.Join(", ", task.Tags.Select(t => "#" + t)), () => _ = EditTagsAsync(task))));

        // What it doesn't have yet, as quiet words.
        var adds = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, Margin = new Thickness(30, 0, 0, 0) };
        if (task.Notes.Length == 0 && _notes == null) adds.Children.Add(Quiet(TasksCopy.PlusNotes, () => { _notes = ""; Render(); _notesBox?.Focus(FocusState.Programmatic); }));
        if (task.RepeatRule == null && task.WhoKind != TodoWho.Bot) adds.Children.Add(RepeatButton(task, TasksCopy.PlusRepeat));
        if (task.Priority == 0 && _store.FieldsSupported) adds.Children.Add(PriorityButton(task, TasksCopy.PlusPriority));
        if (task.Tags.Count == 0 && _store.FieldsSupported) adds.Children.Add(Quiet(TasksCopy.PlusTags, () => _ = EditTagsAsync(task)));
        if (adds.Children.Count > 0) _body.Children.Add(adds);

        // What a bot has for you.
        var words = TodoViews.Row(task, TodoGroupKind.Open, now, Zone, BotName);
        if (words.Note is { } note && !task.IsDone)
        {
            var card = Card(Text(note, 13, color: Solid(words.Tone == TodoTone.Ready ? Green : words.Tone == TodoTone.NeedsYou ? Red : Blue)));
            _body.Children.Add(card);
        }

        // [tasks-v2] Close offer banner ("Mark Done" / "Keep Open").
        if (task.Offer is { Kept: false } closeOffer && !task.IsDone)
        {
            var offerStack = new StackPanel { Spacing = 6 };
            offerStack.Children.Add(Text($"{BotName(closeOffer.By)} thinks this looks done", 13, bold: true, color: Solid(Green)));
            if (!string.IsNullOrWhiteSpace(closeOffer.Text)) offerStack.Children.Add(Text(closeOffer.Text, 13));
            var btns = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            btns.Children.Add(Push(TasksCopy.MarkDone, () => _ = _page.ToggleDone(task), accent: true));
            btns.Children.Add(Quiet("Keep Open", () => _ = _store.KeepTaskOpenAsync(task.Id)));
            offerStack.Children.Add(btns);
            _body.Children.Add(Card(offerStack, 10));
        }

        // [tasks-v2] Task Page summary gist & Task Chat / Now actions.
        if (task.Page is { } pageGist)
        {
            var pageStack = new StackPanel { Spacing = 4 };
            if (!string.IsNullOrWhiteSpace(pageGist.Summary)) pageStack.Children.Add(Text(pageGist.Summary, 13));
            if (!string.IsNullOrWhiteSpace(pageGist.Next)) pageStack.Children.Add(Text("Next: " + pageGist.Next, 12, color: Accent));
            _body.Children.Add(Card(pageStack, 10));
        }

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

        // [tasks-v2] Origin source row ("Email · Ivy · Nov 13").
        if (task.SourceFrom?.Line(now, Zone) is { Length: > 0 } fromLine)
            _body.Children.Add(Line("\uE71B", Text("From " + fromLine, 12, color: Secondary)));

        if (task.Notes.Length > 0 || _notes != null)
        {
            _body.Children.Add(Header(TasksCopy.Notes));
            var notes = _notesBox = new TextBox { AcceptsReturn = true, Text = _notes ?? task.Notes, TextWrapping = TextWrapping.Wrap, MinHeight = 60, PlaceholderText = TasksCopy.Notes };
            notes.LostFocus += (_, _) =>
            {
                var text = notes.Text.Trim();
                _notes = null;
                if (text != task.Notes.Trim()) _ = Patch(new JsonObject { ["notes"] = text });
                else Render();
            };
            _body.Children.Add(notes);
        }

        // Steps.
        var done = task.Steps.Count(s => s.Done);
        var stepsHead = new TextBlock { Margin = new Thickness(0, 14, 0, 4), FontSize = 15 };
        stepsHead.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = TasksCopy.Steps, FontWeight = FontWeights.SemiBold });
        if (task.Steps.Count > 0) stepsHead.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = $"  {done}/{task.Steps.Count}", Foreground = Secondary });
        _body.Children.Add(stepsHead);
        foreach (var step in task.Steps)
        {
            var s = step;
            var check = new CheckBox { IsChecked = s.Done, MinWidth = 0 };
            var label = new TextBlock { TextWrapping = TextWrapping.Wrap };
            label.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = s.Title });
            // Whose it is, on a task you share: "You" on yours, the bot's name on its.
            if (task.WhoKind == TodoWho.Together)
                label.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = "  " + (s.Who == "me" ? TasksCopy.You : BotName(task.Helper)), Foreground = Secondary, FontSize = 12 });
            check.Content = label;
            check.Click += (_, _) => _ = _store.SetStepAsync(_id, s.Id, check.IsChecked == true);
            var menu = new MenuFlyout();
            var remove = new MenuFlyoutItem { Text = TasksCopy.DeleteStep, Icon = new FontIcon { Glyph = "" }, Foreground = Critical };
            remove.Click += (_, _) => _ = Patch(new JsonObject { ["steps"] = TodoWire.Steps(task.Steps.Where(x => x.Id != s.Id)) });
            menu.Items.Add(remove);
            check.ContextFlyout = menu;
            _body.Children.Add(check);
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

        // [tasks-v2] File & Link Attachments (`task.Made`) with Add File / Add Link / Remove.
        var attachHead = new Grid { Margin = new Thickness(0, 14, 0, 4) };
        attachHead.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        attachHead.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        attachHead.Children.Add(Text(task.Made.Count > 0 ? $"Attachments  {task.Made.Count}" : "Attachments", 15, bold: true));
        var attachTools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        attachTools.Children.Add(Quiet("+ File", () => _ = PickAndAttachFileAsync(task)));
        attachTools.Children.Add(Quiet("+ Link", () => _ = PromptAttachLinkAsync(task)));
        Grid.SetColumn(attachTools, 1);
        attachHead.Children.Add(attachTools);
        _body.Children.Add(attachHead);

        if (task.Made.Count == 0)
        {
            _body.Children.Add(Text("No files or links attached yet.", 12, color: Tertiary));
        }
        else
        {
            foreach (var made in task.Made)
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
                    mBtns.Children.Add(Quiet("Open", () => _ = Launcher.LaunchUriAsync(uri)));
                else if (!string.IsNullOrWhiteSpace(item.Ref))
                    mBtns.Children.Add(Quiet("Copy", () => Copy(item.Ref)));

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
                OpenTaskChat(task, "Can you help me break down and tackle this task?");
                break;
            case TaskNowKind.OpenFile:
                if (!string.IsNullOrWhiteSpace(action.Target))
                {
                    if (File.Exists(action.Target))
                        _ = HermesHQ.Features.Attachments.MediaActions.OpenAsync(action.Target, Path.GetFileName(action.Target));
                    else if (Uri.TryCreate(action.Target, UriKind.Absolute, out var targetUri) && targetUri.Scheme is "http" or "https")
                        _ = Windows.System.Launcher.LaunchUriAsync(targetUri);
                    else
                        Copy(action.Target);
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

    private async Task OpenTaskPageAsync(TodoTask task)
    {
        string? page = null;
        try { page = await _store.Api.GetTaskPageHtmlAsync(task.Id); } catch (Exception) { }
        var bodyText = !string.IsNullOrWhiteSpace(page)
            ? StripHtmlToText(page!)
            : $"{task.Title}\n\n{task.Page?.Summary ?? task.Notes}\n\n{(task.Page?.Next is { Length: > 0 } nx ? "Next: " + nx : "")}".Trim();
        var dialog = new ContentDialog
        {
            Title = task.Title.Length == 0 ? "Task Page" : task.Title,
            Content = new ScrollViewer { Content = Text(bodyText, 13), MaxHeight = 480 },
            CloseButtonText = "Done",
            DefaultButton = ContentDialogButton.Close,
        };
        await ShowAsync(XamlRoot, dialog);
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
            if (info.Length > 10 * 1024 * 1024)
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

    /// Choose Date…: a day, and a time if one is set.
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

    /// Who has it: "You", "You & Hermes", "Finance", with what its bot is doing. A menu: Just Me; With Me: a bot;
    /// By Itself: a bot.
    private FrameworkElement WhoButton(TodoTask task)
    {
        var face = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        if (task.Helper is { } helper) face.Children.Add(Face(helper, 18));
        face.Children.Add(Text(TodoViews.Who(task, BotName), 14, wrap: false));
        if (task.Watch.Length > 0 && task.Helper is { } watcher) face.Children.Add(Text($"· watched by {BotName(watcher)}", 14, color: Secondary, wrap: false));
        if (TodoViews.BotState(task) is { } state) face.Children.Add(Text("· " + state.Words, 14, color: Solid(state.Tone == TodoTone.Ready ? Green : state.Tone == TodoTone.NeedsYou ? Red : Blue), wrap: false));
        if (task.WhoKind == TodoWho.Me) face.Children.Add(Text("  " + TasksCopy.Assign, 13, color: Secondary, wrap: false));
        var menu = new MenuFlyout();
        menu.Items.Add(new ToggleMenuFlyoutItem
        {
            Text = TasksCopy.JustMe, IsChecked = task.WhoKind == TodoWho.Me,
            Command = new Do(() => _ = Patch(new JsonObject
            {
                ["who"] = "me", ["bot"] = null,
                // A bot's steps become yours (there's no bot to do them).
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
        if (TasksPage.PriorityColor(task.Priority) is { } c) button.Foreground = HermesHQ.Features.Settings.ThemeService.Ink(c);   // [WIN-60] the theme's text colour under a contrast theme
        AutomationProperties.SetName(button, task.Priority > 0 ? $"{words} priority. Change" : "Priority");
        return button;
    }

    private async Task EditTagsAsync(TodoTask task)
    {
        var text = await PromptAsync(XamlRoot, "Tags", "", string.Join(", ", task.Tags), TasksCopy.Save, "hiring, q4");
        if (text == null) return;
        await Patch(new JsonObject { ["tags"] = new JsonArray([.. TodoViews.TagsFrom(text).Select(t => (JsonNode)t)]) });
    }

    private static MenuFlyoutItem MenuItem(string text, Action run)
    {
        var item = new MenuFlyoutItem { Text = text };
        item.Click += (_, _) => run();
        return item;
    }
}
