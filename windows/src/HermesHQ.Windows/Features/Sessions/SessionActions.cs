using Hermes.Core.Bots;
using Hermes.Core.Sessions;
using HermesHQ.Features.Bots;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;

namespace HermesHQ.Features.Sessions;

/// A Sessions row's right-click (App/Sessions/SessionsOrganizer.swift menuNodes): Pin, Mark Read / Unread | Rename…,
/// Branch in New Chat, New Chat in <project>, Move to Project ▸ | Chat Info, Copy Chat ID | Archive | Delete Chat; and the
/// Filter & Sort menu (SessionFilterMenu) drawn as a MenuFlyout.
public sealed class SessionActions(ListsHub hub, Func<XamlRoot> root, Panel pillHost)
{
    private SessionStore Store => hub.Sessions;

    private static MenuFlyoutItem Item(string text, string glyph, Action run, bool enabled = true)
    {
        var i = new MenuFlyoutItem { Text = text, IsEnabled = enabled };
        if (glyph.Length > 0) i.Icon = new FontIcon { Glyph = glyph };
        i.Click += (_, _) => run();
        return i;
    }

    public void FillRowMenu(IList<MenuFlyoutItemBase> items, SessionSummary s)
    {
        items.Clear();
        items.Add(Item(s.Pinned ? "Unpin" : "Pin", s.Pinned ? "" : "", () => _ = Pin(s)));
        items.Add(Item(s.Unread ? "Mark Read" : "Mark Unread", s.Unread ? "" : "", () => _ = Store.SetUnreadAsync(s, !s.Unread)));
        items.Add(new MenuFlyoutSeparator());
        items.Add(Item("Rename…", "", () => _ = RenameAsync(s)));
        items.Add(Item("Branch in New Chat", "", () => _ = BranchAsync(s)));
        if (Store.ProjectOf(s) is { } project)
            items.Add(Item($"New Chat in {project.Label}", "", () => _ = NewChatAsync(s.Profile, project.Root)));
        items.Add(MoveMenu(s));
        items.Add(new MenuFlyoutSeparator());
        items.Add(Item(ChatInfoRows.Title, "", () => _ = InfoAsync(s)));
        items.Add(Item("Copy Chat ID", "", () => Copy(s.Id)));
        items.Add(new MenuFlyoutSeparator());
        items.Add(Item(s.Archived ? "Unarchive" : "Archive", "", () => _ = ArchiveAsync(s)));
        items.Add(new MenuFlyoutSeparator());
        var delete = Item("Delete Chat", "", () => _ = DeleteAsync(s));
        delete.Foreground = ThemeBrushes.Get("SystemFillColorCriticalBrush");
        items.Add(delete);
    }

    private MenuFlyoutSubItem MoveMenu(SessionSummary s)
    {
        var sub = new MenuFlyoutSubItem { Text = "Move to Project", Icon = new FontIcon { Glyph = "" } };
        var current = Store.ProjectOf(s);
        foreach (var p in Store.MoveTargets(s))
        {
            var t = new ToggleMenuFlyoutItem { Text = p.Label, IsChecked = current?.Id == p.Id };
            t.Click += (_, _) => { if (current?.Id != p.Id) _ = Prompts.RunAsync(root(), "Couldn’t Move Chat", () => Store.MoveAsync(s, p)); };
            sub.Items.Add(t);
        }
        if (sub.Items.Count > 0) sub.Items.Add(new MenuFlyoutSeparator());
        sub.Items.Add(Item("New Project…", "", () => _ = NewProjectAsync(s.Profile, s)));
        return sub;
    }

    private static void Copy(string text) => HermesHQ.Services.SafeClipboard.TrySetText(text);

    public Task Pin(SessionSummary s) =>
        Prompts.RunAsync(root(), s.Pinned ? "Couldn’t Unpin Chat" : "Couldn’t Pin Chat", () => Store.SetPinnedAsync(s, !s.Pinned));

    private async Task RenameAsync(SessionSummary s)
    {
        var title = await Prompts.TextAsync(root(), "Rename Chat", s.Title, "Untitled Chat", "Save", requireChange: true);
        if (title != null) await Prompts.RunAsync(root(), "Couldn’t Rename Chat", () => Store.RenameAsync(s, title));
    }

    /// Archive shows its Undo pill and where to find it again. [WIN-ARCHIVE-UNDO] Undo unarchives this chat once, and a
    /// failure is the Mac's "Couldn’t Unarchive Chat" with Try Again (ArchiveUndoRoute).
    private async Task ArchiveAsync(SessionSummary s)
    {
        if (s.Archived) { await Prompts.RunAsync(root(), "Couldn’t Unarchive Chat", () => Store.SetArchivedAsync(s, false)); return; }
        if (await Prompts.RunAsync(root(), "Couldn’t Archive Chat", () => Store.SetArchivedAsync(s, true)))
            UndoPill.Show(pillHost, "Archived", SessionStore.ArchivedWayBack, ArchiveUndoRoute.For(root, Store, s));
    }

    private async Task DeleteAsync(SessionSummary s)
    {
        if (!await Prompts.ConfirmAsync(root(), $"Delete “{s.Title}”?", SessionStore.DeleteMessage, "Delete Chat")) return;
        await Prompts.RunAsync(root(), "Couldn’t Delete Chat", () => Store.DeleteAsync(s));
    }

    private async Task BranchAsync(SessionSummary s)
    {
        string? id = null;
        await Prompts.RunAsync(root(), "Couldn’t Branch Chat", async () => id = await Store.BranchAsync(s));
        if (id != null) Navigator.Go(new ChatDestination(s.Profile, id, s.Title));
    }

    /// Compose: a new chat with a bot (in a project's folder when given), opened at once.
    public async Task NewChatAsync(string profile, string? folder = null)
    {
        string? id = null;
        await Prompts.RunAsync(root(), "Couldn’t Start a New Chat", async () => id = await Store.NewChatAsync(profile, folder));
        if (id != null) Navigator.Go(new ChatDestination(profile, id, "New Chat"));
    }

    /// New Project…: a name and (optionally) a folder; a project owns its chats by folder. `moving`: then that chat moves in.
    public async Task NewProjectAsync(string profile, SessionSummary? moving)
    {
        var name = new TextBox { Header = "Name", PlaceholderText = "Project Name", MinWidth = 320 };
        var folder = new TextBox { Header = "Folder", PlaceholderText = "~/Projects/…", Description = "Leave it blank to make a new folder named after the project." };
        var dialog = new ContentDialog
        {
            Title = "New Project", PrimaryButtonText = "Create", CloseButtonText = "Cancel", XamlRoot = root(), DefaultButton = ContentDialogButton.Primary,
            Content = new StackPanel { Spacing = 12, Children = { name, folder } }, IsPrimaryButtonEnabled = false,
        };
        name.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = name.Text.Trim().Length > 0;
        if (await HermesHQ.Services.SafeDialog.ShowAsync(root(), dialog) != ContentDialogResult.Primary) return;
        await Prompts.RunAsync(root(), "Couldn’t Create Project", async () =>
        {
            var project = await Store.CreateProjectAsync(name.Text, folder.Text, profile);
            if (moving != null) await Store.MoveAsync(moving, project);
        });
    }

    /// Chat Info: the rows the list holds, each copyable, and Copy Chat Info.
    public async Task InfoAsync(SessionSummary s)
    {
        if (Store.Row(s.Profile, s.Id) is not { } row) return;
        var bot = SessionRules.OwnerName(s.Profile, Store.BotNames);
        var state = ChatInfoPanel.GatewayNote(hub.Client.Rpc.State);
        var rows = ChatInfoRows.Rows(row, bot, hub.Client.Session.Address.Base.Host, state);
        var secondary = ThemeBrushes.Get("TextFillColorSecondaryBrush");
        var list = new StackPanel { Spacing = 10, MinWidth = 380 };
        list.Children.Add(new TextBlock { Text = string.IsNullOrWhiteSpace(s.Title) ? "This chat" : s.Title, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
        foreach (var r in rows)
        {
            var g = new Grid { ColumnSpacing = 12, ColumnDefinitions = { new ColumnDefinition { Width = new GridLength(90) }, new ColumnDefinition() } };
            g.Children.Add(new TextBlock { Text = r.Label, Foreground = secondary });
            var value = new StackPanel();
            value.Children.Add(new TextBlock
            {
                Text = r.Value, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap,
                FontFamily = r.Mono ? (FontFamily)Application.Current.Resources["CodeFont"] : FontFamily.XamlAutoFontFamily,
            });
            if (r.Note != null) value.Children.Add(new TextBlock { Text = r.Note, FontSize = 12, Foreground = secondary });
            Grid.SetColumn(value, 1);
            g.Children.Add(value);
            var copy = new MenuFlyout();
            copy.Items.Add(Item("Copy", "", () => Copy(r.Note is { } n ? $"{r.Label}: {r.Value} ({n})" : $"{r.Label}: {r.Value}")));
            g.ContextFlyout = copy;
            list.Children.Add(g);
        }
        var dialog = new ContentDialog
        {
            Title = ChatInfoRows.Title, CloseButtonText = "Done", PrimaryButtonText = ChatInfoRows.CopyAll,
            Content = new ScrollViewer { Content = list, MaxHeight = 480 },
        };
        if (await HermesHQ.Services.SafeDialog.ShowAsync(root(), dialog) == ContentDialogResult.Primary) Copy(ChatInfoRows.CopyText(rows, s.Profile));
    }

    // ---------------------------------------------------------------- Filter & Sort

    /// The menu from `SessionFilterMenu.Nodes`: inline groups between separators, submenus, checks (radio in a
    /// single-pick submenu). `homeBot`: what All Bots ✓ picks when it is turned off.
    public MenuFlyout FilterMenu(string homeBot)
    {
        var menu = new MenuFlyout();
        void Add(IList<MenuFlyoutItemBase> into, SessionFilterNode node, string? radioGroup)
        {
            if (node.Inline)
            {
                if (into.Count > 0) into.Add(new MenuFlyoutSeparator());
                foreach (var c in node.Children ?? []) Add(into, c, null);
                return;
            }
            if (node.Children != null)
            {
                var sub = new MenuFlyoutSubItem { Text = node.Title };
                foreach (var c in node.Children) Add(sub.Items, c, node.Single ? node.Id : null);
                into.Add(sub);
                return;
            }
            MenuFlyoutItem item = radioGroup != null
                ? new RadioMenuFlyoutItem { GroupName = radioGroup, IsChecked = node.Checked }
                : node.Action?.Kind is SessionFilterActionKind.NewProject or SessionFilterActionKind.ReadAll or SessionFilterActionKind.Clear
                    ? new MenuFlyoutItem()
                    : new ToggleMenuFlyoutItem { IsChecked = node.Checked };
            item.Text = node.Title;
            item.IsEnabled = !node.Disabled;
            if (node.Action is { } action) item.Click += (_, _) => Pick(action, homeBot);
            into.Add(item);
        }
        foreach (var node in SessionFilterMenu.Nodes(Store.FilterState())) Add(menu.Items, node, null);
        return menu;
    }

    private void Pick(SessionFilterAction action, string homeBot)
    {
        switch (action.Kind)
        {
            case SessionFilterActionKind.NewProject:
                _ = NewProjectAsync(Store.BotFilter ?? homeBot, null);
                break;
            case SessionFilterActionKind.ReadAll:
                _ = Store.MarkAllReadAsync();
                break;
            default:
                var deepen = Store.RecentsLimit;
                Store.ApplyFilter(action, homeBot);
                if (Store.RecentsLimit > deepen) _ = Store.RefreshAsync();       // a filter reads deeper (§3.6)
                if (action.Kind == SessionFilterActionKind.Group && Store.Prefs.GroupBy == SessionGroupBy.Project) _ = Store.LoadProjectsAsync();
                break;
        }
    }
}
