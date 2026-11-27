using Hermes.Core.Bots;
using Hermes.Core.Sessions;
using HermesHQ.Controls;
using HermesHQ.Features.Bots;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.NewChat;

/// The one New Chat sheet (App/Sessions/SessionsOrganizer.swift `compose`, `presentNewChat`, `NewChatSheetView`,
/// `NewChatProjectRow`, `NewChatAllProjectsView`), opened by File › New Chat With… (Ctrl+Shift+N, the Mac's ⇧⌘N) and the
/// Sessions page's Compose. The bots as pills, one lit; under "In a project (optional)" the projects (all of them while
/// there are few, else the lit bot's five most recent and All Projects), folders Hermes found under "In a folder", then
/// New Project…; Start Chat (Enter) starts the chat with the lit bot in no project, a project's row starts it there.
/// Every chat starts through `SessionStore.NewChatAsync(bot, folder)`, as New Chat Here does. What it shows and decides
/// is Hermes.Core.Sessions.NewChatSheetModel; this draws it.
public static class NewChatSheet
{
    private static bool _open;

    /// `picked`: the Sessions page's bot chip; `asksProject`: the caller is the go-to (Compose), so a picked bot still
    /// asks for a project.
    public static async void Show(XamlRoot? root, string? picked = null, bool asksProject = false)
    {
        if (root == null || _open || ListsHub.Current is not { } hub) return;
        _open = true;
        try { await ShowAsync(root, hub, picked, asksProject); }
        catch (Exception ex) { AppLog.Error("new-chat", ex); }
        finally { _open = false; }
    }

    private static async Task ShowAsync(XamlRoot root, ListsHub hub, string? picked, bool asksProject)
    {
        AppLog.Note("keys", "new chat with");
        var store = hub.Sessions;
        var bots = hub.Bots.Rows.Select(b => new NewChatBot(b.Id, b.Name, b.Hidden)).ToList();
        var step = NewChatCompose.Decide(SessionFilterWords.EffectiveProjects(store.FilterState()), picked, asksProject, bots);
        if (step is NewChatStep.Direct direct)
        {
            await StartAsync(root, store, direct.Bot, NewChatCompose.Folder(direct.ProjectKey, direct.Bot, store.ProjectsByProfile));
            return;
        }
        // The Mac reads the projects as the sheet opens; a first read (once a minute at most) gets a moment.
        await Task.WhenAny(store.LoadProjectsAsync(), Task.Delay(TimeSpan.FromSeconds(3)));
        var last = new NewChatLast(new FileDeviceStore(ListsHub.DevicePath));
        var chats = store.LiveSummaries();
        var model = new NewChatSheetModel(bots, NewChatCompose.Entries(store.ProjectsByProfile, store.BotOrder), picked, last,
            bot => NewChatCompose.Recent(bot, last, chats, store.ProjectsByProfile));
        var view = new SheetView(model, hub);
        var dialog = new ContentDialog
        {
            Title = NewChatText.Title, PrimaryButtonText = NewChatText.Start, CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary, XamlRoot = root, Content = view.Root,
        };
        AutomationProperties.SetAutomationId(dialog, "new-chat-sheet");
        view.Picked += () => dialog.Hide();
        // Return on a pill: Start Chat with the lit bot (the Mac's `onReturn`), as the dialog's own Enter does elsewhere.
        view.StartRequested += () => dialog.Hide();
        // Escape (or Cancel) on All Projects goes back one step to the sheet's first page, not out of the sheet.
        dialog.Closing += (_, e) =>
        {
            if (e.Result == ContentDialogResult.None && !view.HasPick && view.OnAll) { e.Cancel = true; view.Back(); }
        };
        var result = await SafeDialog.ShowAsync(root, dialog);
        string? project;
        if (view.HasPick) project = view.Pick;
        else if (result == ContentDialogResult.Primary || view.Started) project = null;   // Start Chat (Enter): no project
        else return;
        var bot = model.Bot;
        model.Note(project);
        if (project == NewChatCompose.NewProjectTag) { await NewProjectAsync(root, store, bot); return; }
        await StartAsync(root, store, bot, NewChatCompose.Folder(project, bot, store.ProjectsByProfile));
    }

    /// The chat, through the same call New Chat Here makes, opened at once.
    private static async Task StartAsync(XamlRoot root, SessionStore store, string bot, string? folder)
    {
        string? id = null;
        await Prompts.RunAsync(root, "Couldn’t Start a New Chat", async () => id = await store.NewChatAsync(bot, folder));
        if (id != null) Navigator.Go(new ChatDestination(bot, id, "New Chat"));
    }

    /// New Project…: the New Project prompt for the lit bot, then the chat starts in the project made.
    private static async Task NewProjectAsync(XamlRoot root, SessionStore store, string bot)
    {
        var name = new TextBox { Header = "Name", PlaceholderText = "Project Name", MinWidth = 320 };
        var folder = new TextBox { Header = "Folder", PlaceholderText = "~/Projects/…", Description = "Leave it blank to make a new folder named after the project." };
        var dialog = new ContentDialog
        {
            Title = "New Project", PrimaryButtonText = "Create", CloseButtonText = "Cancel", XamlRoot = root, DefaultButton = ContentDialogButton.Primary,
            Content = new StackPanel { Spacing = 12, Children = { name, folder } }, IsPrimaryButtonEnabled = false,
        };
        name.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = name.Text.Trim().Length > 0;
        if (await SafeDialog.ShowAsync(root, dialog) != ContentDialogResult.Primary) return;
        SessionProject? made = null;
        await Prompts.RunAsync(root, "Couldn’t Create Project", async () => made = await store.CreateProjectAsync(name.Text, folder.Text, bot));
        if (made != null) await StartAsync(root, store, bot, made.Root);
    }

    /// The sheet's two pages: the first (pills, projects) and All Projects.
    private sealed class SheetView
    {
        private readonly NewChatSheetModel _model;
        private readonly ListsHub _hub;
        private readonly StackPanel _first = new() { Spacing = 4 };
        private readonly StackPanel _list = new() { Spacing = 2 };
        private readonly WrapPills _pills = new();
        private readonly ScrollViewer _scroll;

        public FrameworkElement Root => _scroll;
        public bool OnAll { get; private set; }
        public bool HasPick { get; private set; }
        public string? Pick { get; private set; }
        public event Action? Picked;
        /// Return on a pill (Start Chat with the lit bot, no project).
        public bool Started { get; private set; }
        public event Action? StartRequested;
        private readonly List<ToggleButton> _pillButtons = [];

        public SheetView(NewChatSheetModel model, ListsHub hub)
        {
            _model = model;
            _hub = hub;
            _scroll = new ScrollViewer { MinWidth = 360, MaxHeight = 560, Content = _first };
            _first.Children.Add(Heading(NewChatText.BotHeading));
            _first.Children.Add(_pills);
            _first.Children.Add(_list);
            DrawPills();
            DrawList();
        }

        private void Choose(string? project)
        {
            if (HasPick || Started) return;   // the pick is delivered once
            HasPick = true;
            Pick = project;
            Picked?.Invoke();
        }

        /// The pills are drawn once and lit in place: drawing them again took the keyboard's pill out from under it
        /// (WIN-30A: Space on a pill then reached Start Chat). SwiftUI keeps each pill by its bot (`.id(item.id)`).
        private void DrawPills()
        {
            _pills.Children.Clear();
            _pillButtons.Clear();
            foreach (var bot in _model.Bots)
            {
                var face = new BotHead { Width = 20, Height = 20, Bot = _hub.Bots.Bot(bot.Id)?.Model, DisplayName = bot.Name };
                var pill = new ToggleButton
                {
                    IsChecked = bot.Id == _model.Bot, CornerRadius = new CornerRadius(14), Padding = new Thickness(6, 3, 10, 3),
                    Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { face, new TextBlock { Text = bot.Name, VerticalAlignment = VerticalAlignment.Center } } },
                };
                AutomationProperties.SetAutomationId(pill, NewChatText.BotId(bot.Id));
                AutomationProperties.SetName(pill, bot.Name);
                var id = bot.Id;
                pill.Click += (_, _) => Light(id);
                // Space lights this bot and starts nothing; Return starts with the lit bot (NewChatSheetModel.PillKey).
                // Both are taken before the ToggleButton sees them, release too, so it never toggles or clicks.
                pill.PreviewKeyDown += (_, e) =>
                {
                    switch (_model.PillKey(id, KeyOf(e.Key)))
                    {
                        case NewChatKeyAction.Select: e.Handled = true; Light(id); break;
                        case NewChatKeyAction.Start: e.Handled = true; Start(); break;
                    }
                };
                pill.PreviewKeyUp += (_, e) => { if (NewChatSheetModel.SwallowsRelease(KeyOf(e.Key))) e.Handled = true; };
                _pills.Children.Add(pill);
                _pillButtons.Add(pill);
            }
        }

        private static NewChatKey KeyOf(Windows.System.VirtualKey key) => key switch
        {
            Windows.System.VirtualKey.Space => NewChatKey.Space,
            Windows.System.VirtualKey.Enter => NewChatKey.Enter,
            _ => NewChatKey.Other,
        };

        /// `bot` lit, every other pill dark, the keyboard left where it was; the projects follow the lit bot.
        private void Light(string bot)
        {
            _model.Bot = bot;
            for (var i = 0; i < _pillButtons.Count && i < _model.Bots.Count; i++)
                _pillButtons[i].IsChecked = _model.Bots[i].Id == _model.Bot;
            DrawList();
        }

        private void Start()
        {
            if (HasPick || Started) return;   // delivered once
            Started = true;
            StartRequested?.Invoke();
        }

        private void DrawList()
        {
            _list.Children.Clear();
            var layout = _model.Layout();
            var projectsHeading = new TextBlock { Margin = new Thickness(0, 12, 0, 4), Style = HeadingStyle() };
            projectsHeading.Inlines.Add(new Run { Text = NewChatText.ProjectHeading, FontWeight = FontWeights.SemiBold });
            projectsHeading.Inlines.Add(new Run { Text = NewChatText.ProjectHeadingOptional, FontWeight = FontWeights.Normal });
            _list.Children.Add(projectsHeading);
            foreach (var row in layout.Projects) _list.Children.Add(Row(row, NewChatText.RowId(row.Entry)));
            if (layout.AllUnderProjects) _list.Children.Add(AllRow(layout));
            if (layout.NewProjectInProjects) _list.Children.Add(NewProjectRow());
            if (layout.Folders.Count > 0)
            {
                _list.Children.Add(Heading(NewChatText.FolderHeading));
                foreach (var row in layout.Folders) _list.Children.Add(Row(row, NewChatText.RowId(row.Entry)));
                if (layout.AllUnderFolders) _list.Children.Add(AllRow(layout));
            }
            if (!layout.NewProjectInProjects)
            {
                _list.Children.Add(new Border { Height = 12 });
                _list.Children.Add(NewProjectRow());
            }
        }

        private static Style? HeadingStyle() =>
            Application.Current.Resources.TryGetValue("BodyStrongTextBlockStyle", out var s) ? s as Style : null;

        private static TextBlock Heading(string text) => new()
        {
            Text = text, Margin = new Thickness(0, 12, 0, 4), Style = HeadingStyle(),
        };

        private static Button RowButton(UIElement content, string automationId, string name, Action click)
        {
            var button = new Button
            {
                Content = content, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), MinHeight = 40,
                Padding = new Thickness(8, 4, 8, 4),
            };
            AutomationProperties.SetAutomationId(button, automationId);
            AutomationProperties.SetName(button, name);
            button.Click += (_, _) => click();
            return button;
        }

        private static Brush Secondary => ThemeBrushes.Get("TextFillColorSecondaryBrush");
        private static Brush Accent => ThemeBrushes.Get("AccentTextFillColorPrimaryBrush");

        /// `NewChatProjectRow`: the folder, the name on one line (two on All Projects), "Last used" on the bot's last.
        private Button Row(NewChatRow row, string automationId, int lines = 1)
        {
            var grid = new Grid { ColumnSpacing = 12 };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.Children.Add(new FontIcon { Glyph = "\uE8B7", FontSize = 16, Foreground = Secondary });
            var title = new TextBlock
            {
                Text = row.Entry.Label, MaxLines = lines, TextTrimming = TextTrimming.CharacterEllipsis,
                TextWrapping = lines > 1 ? TextWrapping.Wrap : TextWrapping.NoWrap, VerticalAlignment = VerticalAlignment.Center,
            };
            ToolTipService.SetToolTip(title, row.Entry.Label);
            Grid.SetColumn(title, 1);
            grid.Children.Add(title);
            if (row.LastUsed)
            {
                var badge = new Border
                {
                    CornerRadius = new CornerRadius(7), Padding = new Thickness(8, 3, 8, 3), VerticalAlignment = VerticalAlignment.Center,
                    Background = ThemeBrushes.Get("AccentFillColorTertiaryBrush"), Opacity = 0.9,
                    Child = new TextBlock { Text = NewChatText.LastUsed, FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = ThemeBrushes.Get("TextOnAccentFillColorPrimaryBrush") },
                };
                Grid.SetColumn(badge, 2);
                grid.Children.Add(badge);
            }
            var key = row.Entry.Key;
            return RowButton(grid, automationId, row.LastUsed ? $"{row.Entry.Label}, {NewChatText.LastUsed}" : row.Entry.Label, () => Choose(key));
        }

        private Button NewProjectRow()
        {
            var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
            panel.Children.Add(new FontIcon { Glyph = "\uE8F4", FontSize = 16, Foreground = Accent });
            panel.Children.Add(new TextBlock { Text = NewChatText.NewProject, Foreground = Accent });
            return RowButton(panel, NewChatText.NewProjectId, NewChatText.NewProject, () => Choose(NewChatCompose.NewProjectTag));
        }

        private Button AllRow(NewChatLayout layout)
        {
            var grid = new Grid { ColumnSpacing = 12 };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.Children.Add(new FontIcon { Glyph = "\uE8B7", FontSize = 16, Foreground = Secondary });
            var title = new TextBlock { Text = layout.AllTitle, Foreground = Secondary };
            Grid.SetColumn(title, 1);
            var count = new TextBlock { Text = layout.AllCount.ToString(System.Globalization.CultureInfo.CurrentCulture), Foreground = Secondary };
            Grid.SetColumn(count, 2);
            var chevron = new FontIcon { Glyph = "\uE76C", FontSize = 12, Foreground = Secondary };
            Grid.SetColumn(chevron, 3);
            grid.Children.Add(title);
            grid.Children.Add(count);
            grid.Children.Add(chevron);
            return RowButton(grid, NewChatText.AllId, $"{layout.AllTitle}, {layout.AllCount}", ShowAll);
        }

        // ------------------------------------------------------------------ All Projects (`NewChatAllProjectsView`)

        private readonly StackPanel _allRows = new() { Spacing = 2 };
        private TextBox? _search;

        private void ShowAll()
        {
            OnAll = true;
            var page = new StackPanel { Spacing = 6 };
            var back = new Button { Content = new FontIcon { Glyph = "\uE72B", FontSize = 14 }, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0) };
            AutomationProperties.SetName(back, "Back");
            back.Click += (_, _) => Back();
            var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            header.Children.Add(back);
            header.Children.Add(new TextBlock { Text = NewChatText.AllTitle(_model.Projects), Style = HeadingStyle(), VerticalAlignment = VerticalAlignment.Center });
            page.Children.Add(header);
            _search = new TextBox { PlaceholderText = NewChatText.SearchPlaceholder(_model.Projects), IsSpellCheckEnabled = false };
            AutomationProperties.SetAutomationId(_search, NewChatText.SearchId);
            _search.TextChanged += (_, _) => DrawAll();
            page.Children.Add(_search);
            page.Children.Add(_allRows);
            DrawAll();
            _scroll.Content = page;
            _search.Focus(FocusState.Programmatic);
        }

        private void DrawAll()
        {
            _allRows.Children.Clear();
            var (saved, folders, empty) = _model.All(_search?.Text ?? "");
            var mixed = _model.Projects.Any(p => p.IsFolder);
            if (saved.Count > 0 || folders.Count == 0)
            {
                if (mixed && saved.Count > 0) _allRows.Children.Add(Heading(NewChatText.ProjectsHeading));
                foreach (var row in saved) _allRows.Children.Add(Row(row, NewChatText.AllRowId(row.Entry), lines: 2));
                if (empty != null) _allRows.Children.Add(new TextBlock { Text = empty, Foreground = Secondary, Margin = new Thickness(8, 6, 0, 6) });
                if (folders.Count == 0) _allRows.Children.Add(Footer());
            }
            if (folders.Count > 0)
            {
                _allRows.Children.Add(Heading(NewChatText.FoldersHeading));
                foreach (var row in folders) _allRows.Children.Add(Row(row, NewChatText.AllRowId(row.Entry), lines: 2));
                _allRows.Children.Add(Footer());
            }
        }

        private TextBlock Footer() => new()
        {
            Text = NewChatText.StartsWith(_model.BotName), FontSize = 12, Foreground = Secondary, Margin = new Thickness(8, 4, 0, 0),
        };

        public void Back()
        {
            OnAll = false;
            _search = null;
            _scroll.Content = _first;
        }
    }

    /// The pills wrap to another line (the Mac's `PagesFlowLayout` on the Mac: a mouse wheel can't move a sideways strip).
    private sealed partial class WrapPills : Panel
    {
        private const double Gap = 8;

        protected override Windows.Foundation.Size MeasureOverride(Windows.Foundation.Size available)
        {
            double x = 0, y = 0, line = 0, widest = 0;
            foreach (var child in Children)
            {
                child.Measure(new Windows.Foundation.Size(available.Width, double.PositiveInfinity));
                var size = child.DesiredSize;
                if (x > 0 && x + size.Width > available.Width) { y += line + Gap; x = 0; line = 0; }
                x += size.Width + Gap;
                line = Math.Max(line, size.Height);
                widest = Math.Max(widest, x - Gap);
            }
            return new Windows.Foundation.Size(double.IsInfinity(available.Width) ? widest : Math.Min(widest, available.Width), y + line);
        }

        protected override Windows.Foundation.Size ArrangeOverride(Windows.Foundation.Size final)
        {
            double x = 0, y = 0, line = 0;
            foreach (var child in Children)
            {
                var size = child.DesiredSize;
                if (x > 0 && x + size.Width > final.Width) { y += line + Gap; x = 0; line = 0; }
                child.Arrange(new Windows.Foundation.Rect(x, y, size.Width, size.Height));
                x += size.Width + Gap;
                line = Math.Max(line, size.Height);
            }
            return final;
        }
    }
}
