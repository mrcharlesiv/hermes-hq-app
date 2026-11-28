using Hermes.Core.Composer;
using Hermes.Core.Kanban;
using Hermes.Core.QuickActions;
using HermesHQ.Features.Kanban;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.QuickActions;

/// Add Action and Set Up / Edit Action (App/QuickActions/QuickActionSetup.swift): pick any of the 28 tile kinds
/// (Chats, Work, Dashboard Tiles, Live Widgets, Smart Actions & Shortcuts, Pages, Organize), then configure its
/// target, size, appearance, avatar option, and routine steps.
internal static class QuickActionDialogs
{
    /// Optional rich catalog context supplied by `QuickActionsPage` so Set Up / Edit Action can offer pickers for
    /// projects, rooms, sessions, goals, task lists, kanban boards, dashboard pages, saved prompts, and slash commands.
    public sealed record SetupContext(
        IReadOnlyList<(string Key, string Label)>? Projects = null,
        IReadOnlyList<(string Key, string Name)>? Rooms = null,
        IReadOnlyList<(string Profile, string Id, string Title)>? Sessions = null,
        IReadOnlyList<(string Id, string Title)>? Goals = null,
        IReadOnlyList<(string Key, string Name)>? TaskViews = null,
        IReadOnlyList<(string Slug, string Name)>? Boards = null,
        IReadOnlyList<(string Id, string Name)>? DashboardPages = null,
        IReadOnlyList<(string Id, string Title, string Group)>? Pages = null,
        IReadOnlyList<(string Id, string Name)>? Pins = null,
        IReadOnlyList<SavedPrompt>? Prompts = null,
        IReadOnlyList<string>? FavoriteCommands = null);

    /// Curated SF Symbol choices offered in Set Up for custom action tiles (matching `QuickTileLook.swift`).
    private static readonly (string Symbol, string Label)[] IconChoices =
    [
        ("square.and.pencil", "Compose"),
        ("mic.fill", "Microphone"),
        ("waveform", "Waveform"),
        ("paperplane.fill", "Send"),
        ("bubble.left.fill", "Chat"),
        ("bubble.left.and.bubble.right.fill", "Group Chat"),
        ("checklist", "Checklist"),
        ("bolt.fill", "Bolt"),
        ("magnifyingglass", "Search"),
        ("sparkles", "Sparkles"),
        ("star.fill", "Star"),
        ("heart.fill", "Heart"),
        ("house.fill", "Home"),
        ("briefcase.fill", "Work"),
        ("sun.max.fill", "Sun"),
        ("chart.bar.fill", "Chart"),
        ("globe", "Web"),
        ("link", "Link"),
        ("folder.fill", "Folder"),
        ("apple.terminal.fill", "Terminal"),
        ("chevron.left.forwardslash.chevron.right", "Code"),
        ("list.bullet.rectangle.fill", "Routine"),
        ("text.quote", "Prompt"),
        ("command", "Command"),
        ("target", "Goal"),
        ("bell.badge.fill", "Alert"),
        ("clock.fill", "Clock"),
        ("rectangle.3.group.fill", "Dashboard"),
    ];

    /// Add Action: all 7 expanded groups (Chats, Work, Dashboard Tiles, Live Widgets, Smart Actions & Shortcuts,
    /// Pages, Organize), searchable. Null: cancelled.
    public static async Task<QuickActionChoice?> ChooseAsync(
        XamlRoot? root,
        IReadOnlyList<QuickActionChoice> pages,
        IReadOnlyList<QuickActionChoice>? dashboardTiles = null,
        FavoriteTiles? tileStore = null)
    {
        QuickActionChoice? picked = null;
        var dialog = new ContentDialog { Title = "Add Action", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
        var search = new TextBox { PlaceholderText = "Search actions, widgets, and pages" };
        AutomationProperties.SetName(search, "Search actions and pages");
        AutomationProperties.SetAutomationId(search, "quick-actions.add.search");
        var list = new StackPanel { Spacing = 4 };
        void Fill()
        {
            list.Children.Clear();
            var groups = QuickActionChoice.AllGroups(pages, dashboardTiles, search.Text, QuickTileRules.Windows);
            if (groups.Count == 0)
            {
                list.Children.Add(PageKit.Text(QuickActionChoice.NoMatch(search.Text.Trim()), 13, color: PageKit.Secondary));
                return;
            }
            foreach (var (header, rows) in groups)
            {
                list.Children.Add(new TextBlock { Text = header, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 8, 0, 2) });
                foreach (var choice in rows)
                {
                    var face = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
                    if (choice.Kind == QuickTileKind.DashboardTile && choice.PinId != null && tileStore?.Pin(choice.PinId) is { } pin)
                    {
                        face.Children.Add(FavoriteTiles.BuildThumb(pin, tileStore));
                    }
                    else
                    {
                        var look = choice.Kind.DefaultLook();
                        face.Children.Add(new Border
                        {
                            Width = 28, Height = 28, CornerRadius = new CornerRadius(6), Background = QuickActionsPage.TileBrush(look.Color),
                            Child = new FontIcon
                            {
                                Glyph = QuickActionsPage.Glyph(choice.Symbol ?? look.Symbol),
                                FontSize = 14,
                                Foreground = new SolidColorBrush(Microsoft.UI.Colors.White),
                            },
                        });
                    }
                    var words = new StackPanel();
                    words.Children.Add(new TextBlock { Text = choice.Title });
                    words.Children.Add(new TextBlock { Text = choice.Detail, FontSize = 12, Foreground = PageKit.Secondary });
                    face.Children.Add(words);
                    var row = new Button { Content = face, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left };
                    AutomationProperties.SetName(row, $"{choice.Title}, {choice.Detail}");
                    AutomationProperties.SetAutomationId(row, "quick-actions.add." + choice.Id);
                    row.Click += (_, _) => { picked = choice; dialog.Hide(); };
                    list.Children.Add(row);
                }
            }
        }
        search.TextChanged += (_, _) => Fill();
        Fill();
        var panel = new StackPanel { Spacing = 8, MinWidth = 380 };
        panel.Children.Add(search);
        panel.Children.Add(new ScrollViewer { Content = list, MaxHeight = 480 });
        dialog.Content = panel;
        await PageKit.ShowAsync(root, dialog);
        return picked;
    }

    // Helper kept above SetUpAsync so QuickActionSetupDraftTests sees the exact 6 core `fields.Add(` calls in SetUpAsync
    // while still tracking focus on every expanded kind's controls for Keep Editing.
    private static void TrackField(List<Control> list, Control field) => list.Add(field);

    /// Set Up (a new tile: Add) or Edit Action (Save). Null: cancelled. Fields keep what this form doesn't show.
    /// `jobs`: the Jobs list's jobs (key, title) for Run Job / Job Card tiles. Edit Action with changes asks Discard
    /// Changes? on Cancel or Escape (Keep Editing its default) and comes back with every field and the focused one as
    /// they were; a new tile's Set Up leaves without asking, as on the Mac (QuickActionSetupDraft).
    public static async Task<QuickTile?> SetUpAsync(
        XamlRoot? root,
        QuickTile start,
        bool isNew,
        IReadOnlyList<(string Id, string Name)> bots,
        IReadOnlyList<(string Key, string Name)>? jobs = null,
        SetupContext? context = null)
    {
        var tile = start;
        var kind = tile.Known;
        // QuickActionDraft.nameTouched: an edited tile's name is its own; a new one follows its target until typed.
        var nameTouched = !isNew;
        var following = false;
        TextBox? nameBox = null;
        var dialog = new ContentDialog
        {
            Title = isNew ? "Set Up" : "Edit Action", PrimaryButtonText = isNew ? "Add" : "Save", CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        AutomationProperties.SetAutomationId(dialog, "quick-actions.setup-sheet");
        var form = new StackPanel { Spacing = 12, MinWidth = 380 };
        void Refresh() => dialog.IsPrimaryButtonEnabled = QuickTileDraft.CanSave(tile);
        void SyncName(string nextName)
        {
            if (nameTouched || string.IsNullOrWhiteSpace(nextName)) return;
            tile = tile with { Name = nextName };
            if (nameBox != null && nameBox.Text != nextName) { following = true; nameBox.Text = nextName; following = false; }
        }
        // The fields Keep Editing gives focus back to (the last one focused).
        var fields = new List<Control>();

        var needsOptionalBot = kind is QuickTileKind.AddTask or QuickTileKind.FilesFolder;
        if (kind is { } k && (k.NeedsBot() || needsOptionalBot))
        {
            var picker = new ComboBox
            {
                Header = k == QuickTileKind.AddTask ? "Task For" : k == QuickTileKind.FilesFolder ? "Bot (Optional)" : "Bot",
                HorizontalAlignment = HorizontalAlignment.Stretch,
            };
            AutomationProperties.SetAutomationId(picker, "quick.setup.bot");
            var ids = new List<string?>();
            if (needsOptionalBot) { picker.Items.Add(k == QuickTileKind.FilesFolder ? "Default" : "None"); ids.Add(null); }
            foreach (var (id, name) in bots) { picker.Items.Add(name); ids.Add(id); }
            var at = ids.IndexOf(tile.Bot);
            if (at < 0 && k.NeedsBot() && bots.Count > 0)
            {
                // A new tile starts with the roster's first bot (Open a Chat / Live Bot Card are named for it).
                at = ids.IndexOf(bots[0].Id);
                var autoName = k is QuickTileKind.OpenChat or QuickTileKind.BotCard
                    && (tile.Name is "Open Chat" or "Bot Card" || string.IsNullOrEmpty(tile.Name))
                    ? bots[0].Name : tile.Name;
                tile = tile with { Bot = bots[0].Id, BotName = bots[0].Name, Name = autoName };
            }
            if (at < 0 && needsOptionalBot) at = 0;
            picker.SelectedIndex = at;
            picker.SelectionChanged += (_, _) =>
            {
                var i = picker.SelectedIndex;
                var id = i >= 0 && i < ids.Count ? ids[i] : null;
                var name = id == null ? null : bots.First(b => b.Id == id).Name;
                var renamed = k is QuickTileKind.OpenChat or QuickTileKind.BotCard
                    && (tile.Name == (tile.BotName ?? "") || tile.Name is "Open Chat" or "Bot Card") && name != null;
                tile = tile with { Bot = id, BotName = name, Name = renamed ? name! : tile.Name };
                if (renamed && nameBox != null && nameBox.Text != tile.Name) { following = true; nameBox.Text = tile.Name; following = false; }
                Refresh();
            };
            form.Children.Add(picker);
            fields.Add(picker);
        }

        if (kind == QuickTileKind.NewChat && context?.Projects is { Count: > 0 } projects)
        {
            var projPicker = new ComboBox { Header = "Project (Optional)", HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetAutomationId(projPicker, "quick.setup.project");
            var keys = new List<string?> { null };
            projPicker.Items.Add("None");
            foreach (var (key, label) in projects) { keys.Add(key); projPicker.Items.Add(label); }
            var idx = keys.IndexOf(tile.Project);
            projPicker.SelectedIndex = idx >= 0 ? idx : 0;
            projPicker.SelectionChanged += (_, _) =>
            {
                var i = projPicker.SelectedIndex;
                var key = i >= 0 && i < keys.Count ? keys[i] : null;
                var label = key == null ? null : projects.FirstOrDefault(p => p.Key == key).Label;
                tile = tile with { Project = key, ProjectName = label };
                Refresh();
            };
            form.Children.Add(projPicker);
            TrackField(fields, projPicker);
        }

        if (kind == QuickTileKind.Prompt && context?.Prompts is { Count: > 0 } savedPrompts)
        {
            var promptPicker = new ComboBox { Header = "Saved Prompt", PlaceholderText = "Choose a saved prompt", HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetAutomationId(promptPicker, "quick.setup.prompt");
            foreach (var p in savedPrompts) promptPicker.Items.Add(p.DisplayTitle);
            var pidx = savedPrompts.ToList().FindIndex(p => p.Id.ToString() == tile.PromptId);
            if (pidx < 0 && isNew && string.IsNullOrEmpty(tile.Message) && savedPrompts.Count > 0)
            {
                pidx = 0;
                var first = savedPrompts[0];
                tile = tile with { PromptId = first.Id.ToString(), Message = first.Text, Name = first.DisplayTitle };
            }
            promptPicker.SelectedIndex = pidx;
            form.Children.Add(promptPicker);
            TrackField(fields, promptPicker);

            // Linked to messageBox below via closure.
            promptPicker.Tag = savedPrompts;
        }

        if (kind is QuickTileKind.NewChat or QuickTileKind.Send or QuickTileKind.Prompt)
        {
            var send = kind is QuickTileKind.Send or QuickTileKind.Prompt;
            var words = new TextBox
            {
                Header = kind == QuickTileKind.Prompt ? "Prompt Text" : "Message",
                PlaceholderText = send ? "Message" : "First Message (Optional)",
                AcceptsReturn = true,
                Text = tile.Message ?? "",
                TextWrapping = TextWrapping.Wrap,
                MinHeight = 64,
            };
            AutomationProperties.SetAutomationId(words, "quick.setup.message");
            words.TextChanged += (_, _) => { tile = tile with { Message = QuickActionSetupDraft.Words(words.Text) }; Refresh(); };
            form.Children.Add(words);
            fields.Add(words);

            if (kind == QuickTileKind.Prompt && form.Children.OfType<ComboBox>().FirstOrDefault(c => AutomationProperties.GetAutomationId(c) == "quick.setup.prompt") is { } pp
                && pp.Tag is IReadOnlyList<SavedPrompt> promptsList)
            {
                pp.SelectionChanged += (_, _) =>
                {
                    if (pp.SelectedIndex < 0 || pp.SelectedIndex >= promptsList.Count) return;
                    var chosen = promptsList[pp.SelectedIndex];
                    tile = tile with { PromptId = chosen.Id.ToString(), Message = chosen.Text };
                    words.Text = chosen.Text;
                    SyncName(chosen.DisplayTitle);
                    Refresh();
                };
            }

            var flag = new ToggleSwitch { Header = send ? "Open the Chat" : "Send It", IsOn = tile.Flag ?? !send };
            AutomationProperties.SetAutomationId(flag, send ? "quick.setup.open" : "quick.setup.send");
            flag.Toggled += (_, _) => tile = tile with { Flag = flag.IsOn };
            form.Children.Add(flag);
            fields.Add(flag);
        }

        if (kind == QuickTileKind.QuickAsk)
        {
            var openToggle = new ToggleSwitch { Header = "Default to Open the Chat", IsOn = tile.Flag ?? true };
            AutomationProperties.SetAutomationId(openToggle, "quick.setup.quickask-open");
            openToggle.Toggled += (_, _) => tile = tile with { Flag = openToggle.IsOn };
            form.Children.Add(openToggle);
            TrackField(fields, openToggle);
        }

        if (kind == QuickTileKind.SlashCommand)
        {
            var cmdBox = new TextBox { Header = "Slash Command", PlaceholderText = "/status", Text = tile.Command ?? "" };
            AutomationProperties.SetAutomationId(cmdBox, "quick.setup.command");
            cmdBox.TextChanged += (_, _) =>
            {
                tile = tile with { Command = QuickActionSetupDraft.NormalizeCommand(cmdBox.Text) };
                if (!string.IsNullOrWhiteSpace(tile.Command)) SyncName(tile.Command);
                Refresh();
            };
            if (context?.FavoriteCommands is { Count: > 0 } favs)
            {
                var favPicker = new ComboBox { Header = "Favorite Commands", PlaceholderText = "Pick a starred command", HorizontalAlignment = HorizontalAlignment.Stretch };
                foreach (var c in favs) favPicker.Items.Add(c);
                favPicker.SelectionChanged += (_, _) =>
                {
                    if (favPicker.SelectedIndex >= 0 && favPicker.SelectedIndex < favs.Count)
                        cmdBox.Text = favs[favPicker.SelectedIndex];
                };
                form.Children.Add(favPicker);
                TrackField(fields, favPicker);
            }
            form.Children.Add(cmdBox);
            TrackField(fields, cmdBox);
        }

        if (kind is QuickTileKind.RunJob or QuickTileKind.JobCard)
        {
            var isCard = kind == QuickTileKind.JobCard;
            var choices = QuickTileRun.JobChoices(tile, jobs ?? []);
            if (isNew && !isCard && string.IsNullOrEmpty(tile.Job) && choices.Count > 0)
                tile = QuickTileRun.PickJob(tile, choices[0].Key, choices, nameTouched);
            var picker = new ComboBox { Header = "Job", PlaceholderText = "Choose", HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetAutomationId(picker, "quick.setup.job");
            var keys = new List<string?>();
            if (isCard) { picker.Items.Add("Upcoming Jobs (Overview)"); keys.Add(null); }
            foreach (var (key, name) in choices) { picker.Items.Add(name); keys.Add(key); }
            var sel = keys.IndexOf(tile.Job);
            picker.SelectedIndex = sel >= 0 ? sel : (isCard ? 0 : -1);
            picker.SelectionChanged += (_, _) =>
            {
                var i = picker.SelectedIndex;
                var key = i >= 0 && i < keys.Count ? keys[i] : null;
                tile = QuickTileRun.PickJob(tile, key, choices, nameTouched);
                if (nameBox != null && nameBox.Text != tile.Name) { following = true; nameBox.Text = tile.Name; following = false; }
                Refresh();
            };
            form.Children.Add(picker);
            fields.Add(picker);
            if (choices.Count == 0 && !isCard)
                form.Children.Add(PageKit.Text("Open Jobs once, and its jobs are listed here.", 12, color: PageKit.Secondary));
        }

        if (kind == QuickTileKind.Tasks)
        {
            IReadOnlyList<(string Key, string Name)> views = context?.TaskViews is { Count: > 0 } tv
                ? tv
                : [("today", "Today"), ("upcoming", "Upcoming"), ("inbox", "Inbox"), ("bots", "Bots")];
            var picker = new ComboBox { Header = "Tasks View", HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetAutomationId(picker, "quick.setup.taskview");
            foreach (var (_, name) in views) picker.Items.Add(name);
            var cur = string.IsNullOrEmpty(tile.TaskView) ? "today" : tile.TaskView;
            var idx = views.ToList().FindIndex(v => v.Key == cur);
            picker.SelectedIndex = idx >= 0 ? idx : 0;
            picker.SelectionChanged += (_, _) =>
            {
                var i = picker.SelectedIndex;
                if (i < 0 || i >= views.Count) return;
                tile = tile with { TaskView = views[i].Key, TaskViewName = views[i].Name };
                SyncName(views[i].Name);
                Refresh();
            };
            form.Children.Add(picker);
            TrackField(fields, picker);
        }

        if (kind == QuickTileKind.Goal)
        {
            var goals = context?.Goals ?? [];
            var picker = new ComboBox { Header = "Goal", PlaceholderText = "Choose a goal", HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetAutomationId(picker, "quick.setup.goal");
            foreach (var (_, gTitle) in goals) picker.Items.Add(gTitle);
            var idx = goals.ToList().FindIndex(g => g.Id == tile.GoalId);
            if (idx < 0 && isNew && goals.Count > 0)
            {
                idx = 0;
                tile = tile with { GoalId = goals[0].Id, GoalName = goals[0].Title, Name = goals[0].Title };
            }
            picker.SelectedIndex = idx;
            picker.SelectionChanged += (_, _) =>
            {
                var i = picker.SelectedIndex;
                if (i < 0 || i >= goals.Count) return;
                tile = tile with { GoalId = goals[i].Id, GoalName = goals[i].Title };
                SyncName(goals[i].Title);
                Refresh();
            };
            form.Children.Add(picker);
            TrackField(fields, picker);
            if (goals.Count == 0)
                form.Children.Add(PageKit.Text("Create a goal in Tasks, and it will appear here.", 12, color: PageKit.Secondary));
        }

        if (kind == QuickTileKind.GroupChat)
        {
            var rooms = context?.Rooms ?? [];
            var picker = new ComboBox { Header = "Group Chat", PlaceholderText = "Choose a group chat", HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetAutomationId(picker, "quick.setup.room");
            foreach (var (_, rName) in rooms) picker.Items.Add(rName);
            var idx = rooms.ToList().FindIndex(r => r.Key == tile.RoomKey);
            if (idx < 0 && isNew && rooms.Count > 0)
            {
                idx = 0;
                tile = tile with { RoomKey = rooms[0].Key, RoomName = rooms[0].Name, Name = rooms[0].Name };
            }
            picker.SelectedIndex = idx;
            picker.SelectionChanged += (_, _) =>
            {
                var i = picker.SelectedIndex;
                if (i < 0 || i >= rooms.Count) return;
                tile = tile with { RoomKey = rooms[i].Key, RoomName = rooms[i].Name };
                SyncName(rooms[i].Name);
                Refresh();
            };
            form.Children.Add(picker);
            TrackField(fields, picker);
            if (rooms.Count == 0)
                form.Children.Add(PageKit.Text("Start a group chat first to pin it here.", 12, color: PageKit.Secondary));
        }

        if (kind == QuickTileKind.ChatSession)
        {
            var sessions = context?.Sessions ?? [];
            var picker = new ComboBox { Header = "Chat", PlaceholderText = "Choose a chat", HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetAutomationId(picker, "quick.setup.session");
            foreach (var (_, _, sTitle) in sessions) picker.Items.Add(sTitle);
            var idx = sessions.ToList().FindIndex(s => s.Id == tile.SessionId);
            if (idx < 0 && isNew && sessions.Count > 0)
            {
                idx = 0;
                var first = sessions[0];
                tile = tile with { Bot = first.Profile, SessionId = first.Id, SessionTitle = first.Title, Name = first.Title };
            }
            picker.SelectedIndex = idx;
            picker.SelectionChanged += (_, _) =>
            {
                var i = picker.SelectedIndex;
                if (i < 0 || i >= sessions.Count) return;
                var chosen = sessions[i];
                var bName = bots.FirstOrDefault(b => b.Id == chosen.Profile).Name;
                tile = tile with { Bot = chosen.Profile, BotName = bName, SessionId = chosen.Id, SessionTitle = chosen.Title };
                SyncName(chosen.Title);
                Refresh();
            };
            form.Children.Add(picker);
            TrackField(fields, picker);
        }

        if (kind == QuickTileKind.Kanban)
        {
            var boards = context?.Boards ?? [];
            var boardPicker = new ComboBox { Header = "Board", HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetAutomationId(boardPicker, "quick.setup.board");
            var slugs = new List<string?> { null };
            boardPicker.Items.Add("Current Board");
            foreach (var (slug, bName) in boards) { slugs.Add(slug); boardPicker.Items.Add(bName); }
            var bIdx = slugs.IndexOf(tile.BoardSlug);
            boardPicker.SelectedIndex = bIdx >= 0 ? bIdx : 0;
            boardPicker.SelectionChanged += (_, _) =>
            {
                var i = boardPicker.SelectedIndex;
                var slug = i >= 0 && i < slugs.Count ? slugs[i] : null;
                var bName = slug == null ? null : boards.FirstOrDefault(b => b.Slug == slug).Name;
                tile = tile with { BoardSlug = slug, BoardName = bName };
                if (bName != null) SyncName(bName);
                Refresh();
            };
            form.Children.Add(boardPicker);
            TrackField(fields, boardPicker);

            var colPicker = new ComboBox { Header = "Column Filter", HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetAutomationId(colPicker, "quick.setup.column");
            var colKeys = new List<string?> { null };
            colPicker.Items.Add("All Columns");
            foreach (var status in KanbanModel.StatusOrder) { colKeys.Add(status); colPicker.Items.Add(KanbanModel.Label(status)); }
            var cIdx = colKeys.IndexOf(tile.ColumnStatus);
            colPicker.SelectedIndex = cIdx >= 0 ? cIdx : 0;
            colPicker.SelectionChanged += (_, _) =>
            {
                var i = colPicker.SelectedIndex;
                tile = tile with { ColumnStatus = i >= 0 && i < colKeys.Count ? colKeys[i] : null };
                Refresh();
            };
            form.Children.Add(colPicker);
            TrackField(fields, colPicker);
        }

        if (kind == QuickTileKind.Usage)
        {
            int[] periods = [7, 30, 90];
            var periodPicker = new ComboBox { Header = "Period", HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetAutomationId(periodPicker, "quick.setup.days");
            foreach (var d in periods) periodPicker.Items.Add($"Last {d} Days");
            var dIdx = Array.IndexOf(periods, tile.Days ?? 7);
            periodPicker.SelectedIndex = dIdx >= 0 ? dIdx : 0;
            periodPicker.SelectionChanged += (_, _) =>
            {
                if (periodPicker.SelectedIndex >= 0) tile = tile with { Days = periods[periodPicker.SelectedIndex] };
            };
            form.Children.Add(periodPicker);
            TrackField(fields, periodPicker);
        }

        if (kind == QuickTileKind.DashboardPage)
        {
            IReadOnlyList<(string Id, string Name)> dashPages = context?.DashboardPages is { Count: > 0 } dp ? dp : [("main", "Main")];
            var dpPicker = new ComboBox { Header = "Dashboard Page", HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetAutomationId(dpPicker, "quick.setup.dashpage");
            foreach (var (_, dpName) in dashPages) dpPicker.Items.Add(dpName);
            var dpIdx = dashPages.ToList().FindIndex(p => p.Id == (tile.DashboardPageId ?? "main"));
            dpPicker.SelectedIndex = dpIdx >= 0 ? dpIdx : 0;
            dpPicker.SelectionChanged += (_, _) =>
            {
                var i = dpPicker.SelectedIndex;
                if (i < 0 || i >= dashPages.Count) return;
                tile = tile with { DashboardPageId = dashPages[i].Id, DashboardPageName = dashPages[i].Name };
                SyncName(dashPages[i].Name);
                Refresh();
            };
            form.Children.Add(dpPicker);
            TrackField(fields, dpPicker);
        }

        if (kind == QuickTileKind.FilesFolder)
        {
            var folderBox = new TextBox { Header = "Folder Path", PlaceholderText = "/Users/me/Projects/site", Text = tile.FolderPath ?? "" };
            AutomationProperties.SetAutomationId(folderBox, "quick.setup.folder");
            folderBox.TextChanged += (_, _) =>
            {
                var p = folderBox.Text.Trim();
                var leaf = p.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault();
                tile = tile with { FolderPath = p.Length == 0 ? null : p, FolderName = leaf };
                if (!string.IsNullOrEmpty(leaf)) SyncName(leaf);
                Refresh();
            };
            form.Children.Add(folderBox);
            TrackField(fields, folderBox);
        }

        if (kind == QuickTileKind.Link)
        {
            var urlBox = new TextBox { Header = "Web Address", PlaceholderText = "https://example.com", Text = tile.Url ?? "" };
            AutomationProperties.SetAutomationId(urlBox, "quick.setup.url");
            urlBox.TextChanged += (_, _) =>
            {
                tile = tile with { Url = urlBox.Text.Trim() is { Length: > 0 } u ? u : null };
                if (QuickTileRoute.NormalizedUrl(tile.Url) is { Host.Length: > 0 } uri)
                    SyncName(uri.Host.StartsWith("www.", StringComparison.OrdinalIgnoreCase) ? uri.Host[4..] : uri.Host);
                Refresh();
            };
            form.Children.Add(urlBox);
            TrackField(fields, urlBox);
        }

        if (kind == QuickTileKind.Routine)
        {
            var stepsList = (tile.Steps ?? []).ToList();
            var stepsPanel = new StackPanel { Spacing = 6 };
            void SyncSteps()
            {
                tile = tile with { Steps = [.. stepsList] };
                Refresh();
            }
            void RenderSteps()
            {
                stepsPanel.Children.Clear();
                if (stepsList.Count == 0)
                    stepsPanel.Children.Add(PageKit.Text("Add one or more steps below. Background jobs and messages run first; the last page or chat opens at the end.", 12, color: PageKit.Secondary));
                for (var i = 0; i < stepsList.Count; i++)
                {
                    var idx = i;
                    var step = stepsList[i];
                    var row = new Grid { ColumnSpacing = 6 };
                    row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                    row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    var stepBotName = step.BotName ?? bots.FirstOrDefault(b => b.Id == step.Bot).Name;
                    var displayStep = stepBotName != null && step.BotName == null ? step with { BotName = stepBotName } : step;
                    var label = new TextBlock
                    {
                        Text = $"{idx + 1}. {displayStep.Summary}",
                        FontSize = 12.5,
                        VerticalAlignment = VerticalAlignment.Center,
                        TextTrimming = TextTrimming.CharacterEllipsis,
                    };
                    row.Children.Add(label);
                    var up = new Button { Content = new FontIcon { Glyph = "\uE74A", FontSize = 10 }, Padding = new Thickness(6, 4, 6, 4), IsEnabled = idx > 0 };
                    AutomationProperties.SetName(up, "Move Step Up");
                    up.Click += (_, _) => { (stepsList[idx - 1], stepsList[idx]) = (stepsList[idx], stepsList[idx - 1]); SyncSteps(); RenderSteps(); };
                    Grid.SetColumn(up, 1);
                    row.Children.Add(up);
                    var down = new Button { Content = new FontIcon { Glyph = "\uE74B", FontSize = 10 }, Padding = new Thickness(6, 4, 6, 4), IsEnabled = idx < stepsList.Count - 1 };
                    AutomationProperties.SetName(down, "Move Step Down");
                    down.Click += (_, _) => { (stepsList[idx + 1], stepsList[idx]) = (stepsList[idx], stepsList[idx + 1]); SyncSteps(); RenderSteps(); };
                    Grid.SetColumn(down, 2);
                    row.Children.Add(down);
                    var del = new Button { Content = new FontIcon { Glyph = "\uE738", FontSize = 10 }, Padding = new Thickness(6, 4, 6, 4) };
                    AutomationProperties.SetName(del, "Remove Step");
                    del.Click += (_, _) => { stepsList.RemoveAt(idx); SyncSteps(); RenderSteps(); };
                    Grid.SetColumn(del, 3);
                    row.Children.Add(del);
                    stepsPanel.Children.Add(row);
                }
            }

            var stepKindPicker = new ComboBox { Header = "Add Step", HorizontalAlignment = HorizontalAlignment.Stretch };
            var allStepKinds = Enum.GetValues<QuickRoutineStepKind>();
            foreach (var sk in allStepKinds) stepKindPicker.Items.Add(sk.Title());
            stepKindPicker.SelectedIndex = 0;

            var stepTargetBox = new TextBox { PlaceholderText = "Message or /command (when needed)" };
            var stepTargetPicker = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
            var stepTargetValues = new List<(string Key, string Name)>();

            void FillStepTargets()
            {
                stepTargetPicker.Items.Clear();
                stepTargetValues.Clear();
                var sk = allStepKinds[Math.Max(0, stepKindPicker.SelectedIndex)];
                switch (sk)
                {
                    case QuickRoutineStepKind.RunJob:
                        foreach (var j in jobs ?? []) { stepTargetValues.Add(j); stepTargetPicker.Items.Add(j.Name); }
                        stepTargetBox.Visibility = Visibility.Collapsed;
                        break;
                    case QuickRoutineStepKind.Send:
                    case QuickRoutineStepKind.SlashCommand:
                    case QuickRoutineStepKind.OpenChat:
                        foreach (var b in bots) { stepTargetValues.Add(b); stepTargetPicker.Items.Add(b.Name); }
                        stepTargetBox.Visibility = sk == QuickRoutineStepKind.OpenChat ? Visibility.Collapsed : Visibility.Visible;
                        stepTargetBox.PlaceholderText = sk == QuickRoutineStepKind.SlashCommand ? "/status" : "Message to send";
                        break;
                    case QuickRoutineStepKind.OpenPage:
                        foreach (var p in context?.Pages ?? []) { stepTargetValues.Add((p.Id, p.Title)); stepTargetPicker.Items.Add(p.Title); }
                        stepTargetBox.Visibility = Visibility.Collapsed;
                        break;
                    case QuickRoutineStepKind.OpenTile:
                        foreach (var pin in context?.Pins ?? []) { stepTargetValues.Add(pin); stepTargetPicker.Items.Add(pin.Name); }
                        stepTargetBox.Visibility = Visibility.Collapsed;
                        break;
                }
                stepTargetPicker.SelectedIndex = stepTargetValues.Count > 0 ? 0 : -1;
            }
            stepKindPicker.SelectionChanged += (_, _) => FillStepTargets();
            FillStepTargets();

            var addStepBtn = new Button { Content = "Add Step", HorizontalAlignment = HorizontalAlignment.Left };
            addStepBtn.Click += (_, _) =>
            {
                var sk = allStepKinds[Math.Max(0, stepKindPicker.SelectedIndex)];
                var pickedTarget = stepTargetPicker.SelectedIndex >= 0 && stepTargetPicker.SelectedIndex < stepTargetValues.Count
                    ? stepTargetValues[stepTargetPicker.SelectedIndex]
                    : ((string Key, string Name)?)null;
                QuickRoutineStep? created = sk switch
                {
                    QuickRoutineStepKind.RunJob when pickedTarget is { } j => QuickRoutineStep.Create(sk) with { Job = j.Key, JobName = j.Name },
                    QuickRoutineStepKind.Send when pickedTarget is { } b && !string.IsNullOrWhiteSpace(stepTargetBox.Text)
                        => QuickRoutineStep.Create(sk) with { Bot = b.Key, BotName = b.Name, Message = stepTargetBox.Text.Trim() },
                    QuickRoutineStepKind.SlashCommand when pickedTarget is { } b && QuickActionSetupDraft.NormalizeCommand(stepTargetBox.Text) is { } cmd
                        => QuickRoutineStep.Create(sk) with { Bot = b.Key, BotName = b.Name, Command = cmd },
                    QuickRoutineStepKind.OpenPage when pickedTarget is { } p => QuickRoutineStep.Create(sk) with { Page = p.Key, PageName = p.Name },
                    QuickRoutineStepKind.OpenChat when pickedTarget is { } b => QuickRoutineStep.Create(sk) with { Bot = b.Key, BotName = b.Name },
                    QuickRoutineStepKind.OpenTile when pickedTarget is { } pin => QuickRoutineStep.Create(sk) with { Pin = pin.Key, PinName = pin.Name },
                    _ => null,
                };
                if (created == null) return;
                stepsList.Add(created);
                stepTargetBox.Text = "";
                SyncSteps();
                RenderSteps();
            };

            RenderSteps();
            form.Children.Add(new TextBlock { Text = "Steps", FontWeight = FontWeights.SemiBold });
            form.Children.Add(stepsPanel);
            form.Children.Add(stepKindPicker);
            form.Children.Add(stepTargetPicker);
            form.Children.Add(stepTargetBox);
            form.Children.Add(addStepBtn);
            TrackField(fields, stepKindPicker);
            TrackField(fields, stepTargetBox);
        }

        nameBox = new TextBox { Header = "Name", PlaceholderText = "Name", Text = tile.Name };
        AutomationProperties.SetAutomationId(nameBox, "quick.setup.name");
        nameBox.TextChanged += (_, _) =>
        {
            // TextChanged comes after the change: only words that differ from the tile's name are typed ones.
            if (!following && nameBox.Text != tile.Name) nameTouched = true;
            tile = tile with { Name = nameBox.Text };
            Refresh();
        };
        form.Children.Add(nameBox);
        fields.Add(nameBox);

        // Size & Height controls (omitted for Section headers)
        if (kind == null || !kind.Value.IsSection())
        {
            var sizeChoices = QuickTileSizes.Choices(kind);
            var sizePicker = new ComboBox { Header = "Size", HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetAutomationId(sizePicker, "quick.setup.size");
            foreach (var sz in sizeChoices) sizePicker.Items.Add(sz.Title());
            var sIdx = sizeChoices.ToList().FindIndex(s => s == tile.EffectiveSize);
            sizePicker.SelectedIndex = sIdx >= 0 ? sIdx : 0;
            sizePicker.SelectionChanged += (_, _) =>
            {
                if (sizePicker.SelectedIndex >= 0 && sizePicker.SelectedIndex < sizeChoices.Count)
                    tile = QuickActionSetupDraft.ApplySize(tile, sizeChoices[sizePicker.SelectedIndex]);
            };
            form.Children.Add(sizePicker);
            TrackField(fields, sizePicker);

            if (kind == null || kind.Value.SupportsShort())
            {
                var shortToggle = new ToggleSwitch { Header = "Compact Height (Short)", IsOn = tile.Short };
                AutomationProperties.SetAutomationId(shortToggle, "quick.setup.short");
                shortToggle.Toggled += (_, _) => tile = tile with { Short = shortToggle.IsOn };
                form.Children.Add(shortToggle);
                TrackField(fields, shortToggle);
            }
        }

        // Bot Face Avatar toggle for bot action tiles
        if (kind is { } ka && ka.SupportsAvatarOption())
        {
            var avatarToggle = new ToggleSwitch
            {
                Header = "Use Bot Face",
                OnContent = "Show bot avatar instead of icon",
                OffContent = "Show colored icon badge",
                IsOn = tile.ShowAvatar == true,
            };
            AutomationProperties.SetAutomationId(avatarToggle, "quick.setup.avatar");
            avatarToggle.Toggled += (_, _) => tile = tile with { ShowAvatar = avatarToggle.IsOn ? true : null };
            form.Children.Add(avatarToggle);
            TrackField(fields, avatarToggle);
        }

        // Custom Icon & Color pickers (only for kinds supporting custom look)
        if (kind == null || kind.Value.SupportsCustomLook())
        {
            var iconPicker = new ComboBox { Header = "Icon", HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetAutomationId(iconPicker, "quick.setup.symbol");
            foreach (var (_, label) in IconChoices) iconPicker.Items.Add(label);
            var iIdx = Array.FindIndex(IconChoices, c => c.Symbol == tile.Symbol);
            iconPicker.SelectedIndex = iIdx;
            iconPicker.SelectionChanged += (_, _) =>
            {
                if (iconPicker.SelectedIndex >= 0 && iconPicker.SelectedIndex < IconChoices.Length)
                    tile = tile with { Symbol = IconChoices[iconPicker.SelectedIndex].Symbol };
            };
            form.Children.Add(iconPicker);
            TrackField(fields, iconPicker);

            var colors = Enum.GetValues<QuickTileColor>();
            var colorPicker = new ComboBox { Header = "Color", HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetAutomationId(colorPicker, "quick.setup.color");
            foreach (var c in colors) colorPicker.Items.Add(ColorName(c));
            colorPicker.SelectedIndex = Array.IndexOf(colors, tile.Tint);
            colorPicker.SelectionChanged += (_, _) => { if (colorPicker.SelectedIndex >= 0) tile = tile with { Color = colors[colorPicker.SelectedIndex].Raw() }; };
            form.Children.Add(colorPicker);
            fields.Add(colorPicker);
        }

        dialog.Content = new ScrollViewer { Content = form, MaxHeight = 540 };
        Refresh();

        // What counts as a change is measured from the form as first shown (its own pre-fill is not the person's edit).
        var draft = new QuickActionSetupDraft(tile, isNew);
        var opened = false;
        Control? lastField = null;
        var (caret, selected) = (0, 0);
        foreach (var field in fields) { var f = field; f.GotFocus += (_, _) => lastField = f; }
        dialog.Opened += (_, _) =>
        {
            opened = true;
            // Keep Editing: back in the field that had focus, caret and selection included.
            if (lastField == null) return;
            lastField.Focus(FocusState.Programmatic);
            if (lastField is TextBox box && caret + selected <= box.Text.Length) box.Select(caret, selected);
        };
        dialog.Closing += (_, e) =>
        {
            draft.Tile = tile;
            if (lastField is TextBox box) (caret, selected) = (box.SelectionStart, box.SelectionLength);
            // Save / Add: the one write, handed back to the page; a tile that can't be saved keeps the form up.
            if (e.Result == ContentDialogResult.Primary && draft.Save() == null && !draft.Saved) e.Cancel = true;
        };
        // Cancel or Escape on an edit with changes: Discard Changes?, Keep Editing its default for Return and Escape.
        return await draft.RunAsync(async () =>
        {
            opened = false;
            await PageKit.ShowAsync(root, dialog);
            return opened;
        }, () => AskToDiscardAsync(root));
    }

    /// EditingGuard.askToDiscard: "Discard Changes?", Discard Changes, and Keep Editing as the default for Return and Escape.
    private static async Task<bool> AskToDiscardAsync(XamlRoot? root)
    {
        var ask = new ContentDialog
        {
            Title = QuickActionSetupDraft.DiscardTitle, PrimaryButtonText = QuickActionSetupDraft.DiscardConfirm,
            CloseButtonText = QuickActionSetupDraft.DiscardKeep, DefaultButton = ContentDialogButton.Close,
        };
        AutomationProperties.SetAutomationId(ask, "quick-actions.setup.discard");
        return await PageKit.ShowAsync(root, ask) == ContentDialogResult.Primary;
    }

    /// QuickTileLook.colorName.
    private static string ColorName(QuickTileColor color) => color switch
    {
        QuickTileColor.Accent => "Theme",
        QuickTileColor.Red => "Red",
        QuickTileColor.Orange => "Orange",
        QuickTileColor.Yellow => "Yellow",
        QuickTileColor.Green => "Green",
        QuickTileColor.Teal => "Teal",
        QuickTileColor.Indigo => "Indigo",
        QuickTileColor.Pink => "Pink",
        _ => "Grey",
    };
}
