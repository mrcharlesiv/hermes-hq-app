using Hermes.Core.Tasks;
using HermesHQ.Features.Kanban;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.Tasks;

/// "Where to Look" Ideas Sources dialog (`App/Pages/Tasks/TaskIdeasViews.swift`, commit f3a9b867a):
/// Built-in sources (`chats`, `chat_bots`, `memory`, `files`, `web`), opt-in Connected Apps (auto-enabling owning bot
/// via `TaskIdeasSummary.ToggleConnector`), Participating Bots picker (min 1), and 800-char Focus & Skip note.
internal static class IdeasSourcesDialog
{
    public const int NoteMaxLength = 800;

    public static async Task<bool> PresentAsync(XamlRoot? root, TasksStore store, TaskIdeasStore? ideasStore)
    {
        var ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        var roster = PageKit.Bots.Select(b => (Id: b.Name, Name: BotName(b.Name))).ToList();
        if (roster.Count == 0) roster.Add(("default", "Hermes"));

        var sources = store.Settings.IdeasSources ?? ideasStore?.Page.Sources ?? new TodoIdeasSources();
        var activeBots = store.Settings.ActiveIdeasBots.ToList();
        if (activeBots.Count == 0) activeBots.Add(roster[0].Id);
        var note = store.Settings.IdeasNote ?? ideasStore?.Page.Note ?? "";

        var available = ideasStore?.Page.AvailableSources ?? TaskIdeasAvailableSources.Empty;
        var loadingApps = ideasStore != null;

        var body = new StackPanel { Spacing = 8, Width = 460 };
        var scroll = new ScrollViewer { Content = body, MaxHeight = 560, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        AutomationProperties.SetAutomationId(scroll, "tasks.ideas.sources");

        TextBox? noteBox = null;

        FrameworkElement SwitchRow(string title, string? subtitle, bool isOn, string automationId, Action<bool> onToggle)
        {
            var grid = new Grid { ColumnSpacing = 12, MinHeight = 36 };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var left = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
            left.Children.Add(Text(title, 14));
            if (!string.IsNullOrEmpty(subtitle)) left.Children.Add(Text(subtitle, 11.5, color: Secondary));
            grid.Children.Add(left);

            var toggle = new ToggleSwitch { IsOn = isOn, OnContent = "", OffContent = "", MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
            AutomationProperties.SetName(toggle, title);
            AutomationProperties.SetAutomationId(toggle, automationId);
            toggle.Toggled += (_, _) => onToggle(toggle.IsOn);
            Grid.SetColumn(toggle, 1);
            grid.Children.Add(toggle);
            return grid;
        }

        void Build()
        {
            if (noteBox != null) note = noteBox.Text;
            body.Children.Clear();

            // 1. Built-in Sources
            body.Children.Add(Header("Built-in Sources"));
            body.Children.Add(SwitchRow(
                "Chats",
                TaskIdeasSummary.ChatBotsSubtitle(sources, roster),
                sources.Chats,
                "tasks.ideas.sources.chats",
                on => { sources = sources with { Chats = on }; Build(); }));

            if (sources.Chats && roster.Count > 1)
            {
                var chatBotsPanel = new StackPanel { Spacing = 4, Margin = new Thickness(16, 0, 0, 4) };
                chatBotsPanel.Children.Add(Text("Include chats from:", 12, color: Secondary));
                var allChecked = sources.ChatBots.Count == 0;
                var botWrap = new TaskWrapPanel { HorizontalSpacing = 10, VerticalSpacing = 4 };
                foreach (var (botId, botName) in roster)
                {
                    var id = botId;
                    var included = allChecked || sources.ChatBots.Contains(id, StringComparer.Ordinal);
                    var cb = new CheckBox { Content = botName, IsChecked = included, MinWidth = 0 };
                    AutomationProperties.SetAutomationId(cb, "tasks.ideas.sources.chatbot." + id);
                    cb.Click += (_, _) =>
                    {
                        var current = sources.ChatBots.Count == 0 ? roster.Select(r => r.Id).ToList() : sources.ChatBots.ToList();
                        if (cb.IsChecked == true)
                        {
                            if (!current.Contains(id, StringComparer.Ordinal)) current.Add(id);
                        }
                        else
                        {
                            current.RemoveAll(x => string.Equals(x, id, StringComparison.Ordinal));
                        }
                        if (current.Count == 0)
                        {
                            sources = sources with { Chats = false, ChatBots = [] };
                        }
                        else if (current.Count >= roster.Count)
                        {
                            sources = sources with { ChatBots = [] };
                        }
                        else
                        {
                            sources = sources with { ChatBots = current };
                        }
                        Build();
                    };
                    botWrap.Children.Add(cb);
                }
                chatBotsPanel.Children.Add(botWrap);
                body.Children.Add(chatBotsPanel);
            }

            body.Children.Add(SwitchRow(
                "Memory",
                "What your bots remember about ongoing projects",
                sources.Memory,
                "tasks.ideas.sources.memory",
                on => { sources = sources with { Memory = on }; }));

            body.Children.Add(SwitchRow(
                "Files",
                "Workspace notes and documents your bots can read",
                sources.Files,
                "tasks.ideas.sources.files",
                on => { sources = sources with { Files = on }; }));

            body.Children.Add(SwitchRow(
                "Web",
                "Check live pages or feeds when relevant",
                sources.Web,
                "tasks.ideas.sources.web",
                on => { sources = sources with { Web = on }; }));

            // 2. Connected Apps (opt-in)
            body.Children.Add(Header("Connected Apps"));
            if (loadingApps && available.Connectors.Count == 0)
            {
                var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                row.Children.Add(new ProgressRing { IsActive = true, Width = 14, Height = 14 });
                row.Children.Add(Text("Checking connected apps…", 12, color: Secondary));
                body.Children.Add(row);
            }
            else if (available.Connectors.Count == 0)
            {
                body.Children.Add(Text("No connected apps discovered on your bots yet. New apps start off until you enable them here.", 12, color: Secondary));
            }
            else
            {
                foreach (var conn in available.Connectors)
                {
                    var c = conn;
                    var enabled = sources.Connectors.Contains(c.Id, StringComparer.Ordinal);
                    var owners = c.Bots.Count > 0 ? string.Join(", ", c.Bots.Select(BotName)) : "";
                    var sub = string.Join(" · ", new[] { c.Kind == "composio" ? "Composio" : "MCP", owners }.Where(s => s.Length > 0));
                    body.Children.Add(SwitchRow(
                        c.Name,
                        sub,
                        enabled,
                        "tasks.ideas.sources.connector." + c.Id,
                        on =>
                        {
                            var (nextSources, nextBots) = TaskIdeasSummary.ToggleConnector(c.Id, on, c, sources, activeBots);
                            sources = nextSources;
                            activeBots = [.. nextBots];
                            Build();
                        }));
                }
            }

            // 3. Participating Bots
            if (roster.Count > 1)
            {
                body.Children.Add(Header("Participating Bots"));
                var botsStack = new StackPanel { Spacing = 4 };
                foreach (var (botId, botName) in roster)
                {
                    var id = botId;
                    var picked = activeBots.Contains(id, StringComparer.Ordinal);
                    var cb = new CheckBox
                    {
                        Content = botName,
                        IsChecked = picked,
                        IsEnabled = !picked || activeBots.Count > 1, // at least 1 bot stays enabled
                    };
                    AutomationProperties.SetAutomationId(cb, "tasks.ideas.sources.bot." + id);
                    cb.Click += (_, _) =>
                    {
                        if (cb.IsChecked == true)
                        {
                            if (!activeBots.Contains(id, StringComparer.Ordinal)) activeBots.Add(id);
                        }
                        else if (activeBots.Count > 1)
                        {
                            activeBots.RemoveAll(b => string.Equals(b, id, StringComparison.Ordinal));
                        }
                        Build();
                    };
                    botsStack.Children.Add(cb);
                }
                body.Children.Add(botsStack);
            }

            // 4. Focus & Skip note (800-char limit; AcceptsReturn set BEFORE Text per WinUI rule)
            body.Children.Add(Header("Focus & Skip Note"));
            var counter = Text($"{note.Length}/{NoteMaxLength}", 11.5, color: Secondary);
            counter.HorizontalAlignment = HorizontalAlignment.Right;

            noteBox = new TextBox
            {
                AcceptsReturn = true,
                Text = note,
                PlaceholderText = "e.g. Focus on launch blockers and invoices. Skip newsletters.",
                TextWrapping = TextWrapping.Wrap,
                MinHeight = 84,
                MaxLength = NoteMaxLength,
            };
            AutomationProperties.SetName(noteBox, "Focus and Skip Note");
            AutomationProperties.SetAutomationId(noteBox, "tasks.ideas.sources.note");
            noteBox.TextChanged += (_, _) =>
            {
                note = noteBox.Text;
                counter.Text = $"{note.Length}/{NoteMaxLength}";
            };
            body.Children.Add(noteBox);
            body.Children.Add(counter);
        }

        Build();

        // Fetch fresh auto-discovered connectors asynchronously while dialog is open.
        if (ideasStore != null)
        {
            _ = LoadAvailableAsync();
            async Task LoadAvailableAsync()
            {
                try
                {
                    var fresh = await ideasStore.GetAvailableSourcesAsync();
                    available = fresh;
                }
                catch (Exception) { }
                finally
                {
                    loadingApps = false;
                    ui.TryEnqueue(Build);
                }
            }
        }

        var dialog = new ContentDialog
        {
            Title = "Where to Look",
            Content = scroll,
            PrimaryButtonText = TasksCopy.Save,
            CloseButtonText = TasksCopy.Cancel,
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await ShowAsync(root, dialog) != ContentDialogResult.Primary) return false;

        if (noteBox != null) note = noteBox.Text;
        var cleanNote = note.Trim();
        if (cleanNote.Length > NoteMaxLength) cleanNote = cleanNote[..NoteMaxLength];

        var nextSettings = store.Settings with
        {
            IdeasSources = sources,
            IdeasBots = [.. activeBots],
            IdeasBot = activeBots.FirstOrDefault() ?? store.Settings.IdeasBot ?? "default",
            IdeasNote = cleanNote,
        };
        var saved = await store.SaveSettingsAsync(nextSettings);
        if (saved && ideasStore != null) _ = ideasStore.RefreshAsync(force: true);
        return saved;
    }
}
