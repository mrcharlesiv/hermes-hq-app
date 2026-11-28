using Hermes.Core.Bots;
using Hermes.Core.Sessions;
using HermesHQ.Controls;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Bots;

/// Everything a bot row, a section heading and the sidebar's + offer (App/Bots/BotsOrganizer.swift, BotExtras.swift,
/// App/BotInfo/*): the Mac's right-click menu laid out flat in separated groups, Bot Info, Edit Bot, New Bot, sections,
/// pin, hide (with its Undo pill), mute, Duplicate and Delete.
public sealed class BotActions(ListsHub hub, Func<XamlRoot> root, Panel pillHost)
{
    private BotStore Store => hub.Bots;

    /// Opens a chat with a bot in Sessions (View Sessions, "N more"); set by the shell.
    public Action<string>? ViewSessions { get; set; }
    /// Starts a new chat with a bot (its own row's New Chat).
    public Action<string>? NewChat { get; set; }
    /// The heads feature's face editor (Change Face…). TODO(heads): HeadsFeature sets this.
    public static Action<BotRow, XamlRoot>? ChangeFace { get; set; }
    /// [groups] Items another feature adds to a bot's place group before Duplicate Bot (BotMenuHooks .addToGroup: Add to
    /// Group Chat…). Null answers add nothing.
    public static readonly List<Func<BotRow, XamlRoot, MenuFlyoutItemBase?>> PlaceItems = [];
    /// [groups] Items another feature adds to the list's + menu after New Bot (the Compose menu's New Group Chat).
    public static readonly List<Func<XamlRoot, MenuFlyoutItemBase>> AddItems = [];

    private static MenuFlyoutItem Item(string text, string glyph, Action run, bool enabled = true)
    {
        var i = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph }, IsEnabled = enabled };
        i.Click += (_, _) => run();
        return i;
    }

    private static void Group(IList<MenuFlyoutItemBase> items, params MenuFlyoutItemBase[] group)
    {
        if (group.Length == 0) return;
        if (items.Count > 0) items.Add(new MenuFlyoutSeparator());
        foreach (var g in group) items.Add(g);
    }

    // ---------------------------------------------------------------- the bot's menu (BotsOrganizer.menuNodes, [mac-menu])

    public void FillBotMenu(IList<MenuFlyoutItemBase> items, BotRow bot)
    {
        items.Clear();
        var now = DateTimeOffset.UtcNow;
        // A hidden bot's pin would show nowhere: it offers Show in Bots, not Pin.
        if (!bot.Hidden || bot.Pinned)
            Group(items, Item(bot.Pinned ? "Unpin" : "Pin", bot.Pinned ? "" : "", () => _ = Pin(bot, !bot.Pinned)));

        var info = new List<MenuFlyoutItemBase>
        {
            Item("Bot Info", "", () => _ = ShowInfoAsync(bot)),
            Item("Edit Bot…", "", () => _ = EditAsync(bot)),
        };
        if (ChangeFace != null) info.Add(Item("Change Face…", "", () => ChangeFace(bot, root())));
        info.Add(Item("New Chat", "", () => NewChat?.Invoke(bot.Id)));
        if (!bot.Hidden) info.Add(Item("View Sessions", "", () => ViewSessions?.Invoke(bot.Id)));
        // [WIN-SCREEN-PAGE] Watch Screen / View Screen / Latest Screenshots, after View Sessions (BotsOrganizer.menuNodes).
        if (Screen.ScreenFeature.MenuItem(bot) is { } screen) info.Add(screen);
        if (Browser.BrowserFeature.MenuItem(bot) is { } browser) info.Add(browser);
        if (Browser.BrowserFeature.ChoiceMenuItem(bot, root) is { } browserChoice) info.Add(browserChoice);
        Group(items, [.. info]);

        var status = new List<MenuFlyoutItemBase>();
        var mute = Store.MuteOf(bot.Id, now);
        if (mute != null) status.Add(Item("Unmute", "", () => Store.SetMute(bot.Id, MuteChoice.Off, DateTimeOffset.UtcNow)));
        else
        {
            var sub = new MenuFlyoutSubItem { Text = "Mute", Icon = new FontIcon { Glyph = "" } };
            foreach (var choice in Enum.GetValues<MuteChoice>().Where(c => c != MuteChoice.Off))
                sub.Items.Add(Item(BotMutes.Title(choice), "", () => Store.SetMute(bot.Id, choice, DateTimeOffset.UtcNow)));
            status.Add(sub);
        }
        var read = bot.Unread
            ? Item("Mark as Read", "", () => Store.MarkRead(bot.Id))
            : Item("Mark as Unread", "", () => Store.MarkUnread(bot.Id), bot.OpenId != null);
        if (bot.Hidden) status.Add(Item("Show in Bots", "", () => _ = Hide(bot, false)));
        status.Add(read);
        if (!bot.Hidden) status.Add(ChatsUnderMenu(bot));
        Group(items, [.. status]);

        var place = new List<MenuFlyoutItemBase> { MoveMenu(bot) };
        if (bot.PinOrder is { } at)
        {
            if (at > 0) place.Add(Item("Move Pin Up", "", () => Store.MovePin(bot.Id, -1)));
            if (at < Store.Layout.Tiles.Count - 1) place.Add(Item("Move Pin Down", "", () => Store.MovePin(bot.Id, 1)));
        }
        foreach (var extra in PlaceItems) if (extra(bot, root()) is { } added) place.Add(added);
        place.Add(QuickActions.FavoritesPinAction.ForBot(bot.Id, bot.Name));
        place.Add(Item("Duplicate Bot", "", () => _ = DuplicateAsync(bot)));
        Group(items, [.. place]);
        if (!bot.Hidden) Group(items, Item("Hide from Bots", "", () => _ = Hide(bot, true)));
        if (!Store.IsDefaultBot(bot.Id))
        {
            var delete = Item("Delete Bot…", "", () => _ = DeleteAsync(bot));
            delete.Foreground = ThemeBrushes.Get("SystemFillColorCriticalBrush");
            Group(items, delete);
        }
    }

    /// "Chats Under <bot>": Same as All Bots, Off, Active, Pinned Only, Pinned + Recent (1, 2, 3, 5).
    private MenuFlyoutSubItem ChatsUnderMenu(BotRow bot)
    {
        var sub = new MenuFlyoutSubItem { Text = $"Chats Under {bot.Name}", Icon = new FontIcon { Glyph = "" } };
        var own = BotChatsChoice.Parse(Store.Device.ChatsUnder.GetValueOrDefault(bot.Id));
        var all = BotChatsChoice.Parse(Store.Device.ChatsUnder.GetValueOrDefault("*")) ?? BotChatsChoice.Initial;
        var same = new ToggleMenuFlyoutItem { Text = "Same as All Bots", IsChecked = own == null };
        same.Click += (_, _) => Store.SetChatsUnder(bot.Id, null);
        sub.Items.Add(same);
        sub.Items.Add(new MenuFlyoutSeparator());
        foreach (var mode in new[] { BotChatsMode.Off, BotChatsMode.Active, BotChatsMode.Pinned })
        {
            var t = new ToggleMenuFlyoutItem { Text = BotChatsChoice.Title(mode), IsChecked = own?.Mode == mode };
            t.Click += (_, _) => Store.SetChatsUnder(bot.Id, new BotChatsChoice(mode, 2).Stored);
            sub.Items.Add(t);
        }
        foreach (var count in BotChatsChoice.Counts)
        {
            var t = new ToggleMenuFlyoutItem { Text = $"Pinned + {count} Recent", IsChecked = own?.Mode == BotChatsMode.Recent && own.Count == count };
            t.Click += (_, _) => Store.SetChatsUnder(bot.Id, new BotChatsChoice(BotChatsMode.Recent, count).Stored);
            sub.Items.Add(t);
        }
        sub.Items.Add(new MenuFlyoutSeparator());
        var every = new MenuFlyoutSubItem { Text = "All Bots" };
        foreach (var mode in new[] { BotChatsMode.Off, BotChatsMode.Active, BotChatsMode.Pinned, BotChatsMode.Recent })
        {
            var choice = mode == BotChatsMode.Recent ? BotChatsChoice.Standard : new BotChatsChoice(mode, 2);
            var t = new ToggleMenuFlyoutItem { Text = BotChatsChoice.Title(mode), IsChecked = all.Mode == mode };
            t.Click += (_, _) => Store.SetChatsUnder("*", choice.Stored);
            every.Items.Add(t);
        }
        sub.Items.Add(every);
        return sub;
    }

    /// Move to Section ▸: the sections (the bot's own checked), New Section…, Remove from Section.
    private MenuFlyoutSubItem MoveMenu(BotRow bot)
    {
        var sub = new MenuFlyoutSubItem { Text = "Move to Section", Icon = new FontIcon { Glyph = "" } };
        var current = PinnedSection.ShownSectionId(Store.CurrentMeta(bot.Id), PinnedSection.Current(Store.CurrentMeta(bot.Id)));
        foreach (var record in Store.Device.Sections.Where(s => s.Id != RosterRules.PinnedSectionId))
        {
            var t = new ToggleMenuFlyoutItem { Text = record.Name, IsChecked = record.Id == current };
            t.Click += (_, _) => { if (record.Id != current) _ = Move(bot, record.Id); };
            sub.Items.Add(t);
        }
        if (sub.Items.Count > 0) sub.Items.Add(new MenuFlyoutSeparator());
        sub.Items.Add(Item("New Section…", "", () => _ = NewSectionAsync(bot)));
        if (current != null) sub.Items.Add(Item("Remove from Section", "", () => _ = Move(bot, null)));
        return sub;
    }

    // ---------------------------------------------------------------- a section heading's menu

    public void FillSectionMenu(IList<MenuFlyoutItemBase> items, string sectionId)
    {
        items.Clear();
        Group(items, Item("Rename…", "", () => _ = RenameSectionAsync(sectionId)));
        Group(items, Item("Move Up", "", () => Store.MoveSection(sectionId, -1), Store.CanMoveSection(sectionId, -1)),
            Item("Move Down", "", () => Store.MoveSection(sectionId, 1), Store.CanMoveSection(sectionId, 1)));
        var delete = Item("Delete Section", "", () => _ = DeleteSectionAsync(sectionId));
        delete.Foreground = ThemeBrushes.Get("SystemFillColorCriticalBrush");
        Group(items, delete);
    }

    /// The sidebar's + (and its Bots heading's menu): New Bot, New Section….
    public void FillAddMenu(IList<MenuFlyoutItemBase> items)
    {
        Group(items, [Item("New Bot", "", () => _ = NewBotAsync()), .. AddItems.Select(a => a(root())), Item("New Section…", "", () => _ = NewSectionAsync(null))]);
        var hidden = new ToggleMenuFlyoutItem { Text = $"Show Hidden Bots ({Store.Layout.Hidden.Count})", IsChecked = Store.Device.ShowHidden,
            IsEnabled = Store.Layout.Hidden.Count > 0 || Store.Device.ShowHidden };
        hidden.Click += (_, _) => Store.SetShowHidden(!Store.Device.ShowHidden);
        Group(items, hidden);
    }

    // ---------------------------------------------------------------- the writes

    public Task Pin(BotRow bot, bool pinned) =>
        Prompts.RunAsync(root(), pinned ? $"Couldn’t Pin {bot.Name}" : $"Couldn’t Unpin {bot.Name}", () => Store.SetPinnedAsync(bot.Id, bot.Name, pinned));

    public Task Move(BotRow bot, string? section) =>
        Prompts.RunAsync(root(), $"Couldn’t Move {bot.Name}", () => Store.MoveAsync(bot.Id, bot.Name, section));

    /// Hide shows its Undo pill with the change, not after the gateway answered.
    public async Task Hide(BotRow bot, bool hidden)
    {
        Action? dismiss = null;
        if (hidden && !Store.ReadOnly)
            dismiss = UndoPill.Show(pillHost, "Hidden", "Find it under Hidden, below your bots.", () => _ = Hide(bot, false));
        if (!await Prompts.RunAsync(root(), hidden ? $"Couldn’t Hide {bot.Name}" : $"Couldn’t Show {bot.Name}",
                () => Store.SetHiddenAsync(bot.Id, bot.Name, hidden)))
            dismiss?.Invoke();
    }

    public async Task NewSectionAsync(BotRow? filing)
    {
        var name = await Prompts.TextAsync(root(), "New Section", "", "e.g. Clients", "Create", 40,
            n => BotList.SectionNameProblem(n, Store.Device.Sections.Select(s => s.Name)));
        if (name == null) return;
        var record = Store.AppendSection(name);
        if (filing != null) await Move(filing, record.Id);
    }

    private async Task RenameSectionAsync(string id)
    {
        if (Store.Device.Sections.FirstOrDefault(s => s.Id == id) is not { } record) return;
        var name = await Prompts.TextAsync(root(), "Rename Section", record.Name, record.Name, "Save", 40,
            n => BotList.SectionNameProblem(n, Store.Device.Sections.Where(s => s.Id != id).Select(s => s.Name)));
        if (name == null || name == record.Name) return;
        await Prompts.RunAsync(root(), $"Couldn’t Rename {record.Name}", () => Store.RenameSectionAsync(id, name));
    }

    /// Deleting a section that holds bots asks first; then "Deleted “Name” · Undo" shows at once (8 s).
    private async Task DeleteSectionAsync(string id)
    {
        if (Store.Device.Sections.FirstOrDefault(s => s.Id == id) is not { } record) return;
        var message = BotList.DeleteSectionMessage(Store.Members(id).Count);
        if (message != null && !await Prompts.ConfirmAsync(root(), $"Delete “{record.Name}”?", message, "Delete Section")) return;
        await Prompts.RunAsync(root(), $"Couldn’t Delete “{record.Name}”", async () =>
        {
            if (Store.BeginDeleteSection(id) is not { } deletion) return;
            var dismiss = UndoPill.Show(pillHost, $"Deleted “{record.Name}”", null, () => Store.UndoDeleteSection(deletion), 8);
            try { await Store.FinishDeleteSectionAsync(deletion); }
            catch { dismiss(); throw; }
        });
    }

    private async Task DuplicateAsync(BotRow bot)
    {
        await Prompts.RunAsync(root(), $"Couldn’t Duplicate {bot.Name}", () => Store.DuplicateAsync(bot.Id, bot.Name));
        _ = Store.RefreshAsync();
    }

    public async Task<bool> DeleteAsync(BotRow bot)
    {
        if (!await Prompts.ConfirmAsync(root(), $"Delete “{bot.Name}”?",
                $"{bot.Name}’s memory, skills, settings and chats are deleted from the computer running Hermes. This can’t be undone.", "Delete Bot"))
            return false;
        return await Prompts.RunAsync(root(), $"Couldn’t Delete {bot.Name}", () => Store.DeleteAsync(bot.Id, bot.Name));
    }

    // ---------------------------------------------------------------- New Bot (App/Bots/NewBotViewController.swift)

    public async Task NewBotAsync()
    {
        var name = new TextBox { Header = "Name", PlaceholderText = "inbox-triage", Description = "Lowercase letters, numbers and dashes. Spaces become dashes." };
        var title = new TextBox { Header = "Display Name", PlaceholderText = "Inbox Triage", Description = "The name shown in lists. Leave it blank to use the Name." };
        var about = new TextBox { Header = "Description", PlaceholderText = "What should this bot help with?", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 72 };
        var note = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 12, Foreground = ThemeBrushes.Get("SystemFillColorCriticalBrush") };
        var footer = new TextBlock
        {
            Text = "The bot gets a shape from its name. You can change it once the bot is created.", TextWrapping = TextWrapping.Wrap, FontSize = 12,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
        };
        var dialog = new ContentDialog
        {
            Title = "New Bot", PrimaryButtonText = "Create", CloseButtonText = "Cancel", XamlRoot = root(), DefaultButton = ContentDialogButton.Primary,
            Content = new StackPanel { Spacing = 12, MinWidth = 360, Children = { name, note, title, about, footer } },
        };
        void Check()
        {
            var (slug, _) = BotIdentity.ProfileIdentity(name.Text, title.Text);
            var taken = slug.Length > 0 && Store.IsTaken(slug);
            note.Text = taken ? $"A bot named “{slug}” already exists." : "";
            dialog.IsPrimaryButtonEnabled = BotIdentity.IsValidProfileId(slug) && !taken;
        }
        name.TextChanged += (_, _) => Check();
        title.TextChanged += (_, _) => Check();
        Check();
        dialog.PrimaryButtonClick += async (d, e) =>
        {
            var deferral = e.GetDeferral();
            d.PrimaryButtonText = "Creating…";
            d.IsPrimaryButtonEnabled = false;
            try
            {
                var made = await Store.CreateBotAsync(name.Text, title.Text, about.Text);
                hub.Bots.VisibleBot = made.Name;
                if (Store.Bot(made.Name) is { } row) Navigator.Go(new BotChatDestination(row.Model));
            }
            catch (BotStore.NewBotNameException x)
            {
                note.Text = x.Message;
                e.Cancel = true;
            }
            catch (BotWriteException x)
            {
                e.Cancel = true;
                note.Text = x.Reason;
            }
            catch (Exception x)
            {
                e.Cancel = true;
                HermesHQ.Services.AppLog.Error("bots", x);
                note.Text = "Couldn’t create bot. Try again.";
            }
            finally
            {
                d.PrimaryButtonText = "Create";
                d.IsPrimaryButtonEnabled = true;
                deferral.Complete();
            }
        };
        await HermesHQ.Services.SafeDialog.ShowAsync(root(), dialog);
    }

    // ---------------------------------------------------------------- Edit Bot (App/BotInfo/EditBotController.swift)

    public async Task EditAsync(BotRow bot)
    {
        var title = new TextBox { Header = "Display Name", Text = bot.Name, PlaceholderText = bot.Name };
        var about = new TextBox
        {
            Header = "Description", AcceptsReturn = true, Text = bot.Role ?? "", PlaceholderText = "What should this bot help with?",
            TextWrapping = TextWrapping.Wrap, MinHeight = 72,
        };
        var dialog = new ContentDialog
        {
            Title = "Edit Bot", PrimaryButtonText = "Save", CloseButtonText = "Cancel", XamlRoot = root(), DefaultButton = ContentDialogButton.Primary,
            Content = new StackPanel
            {
                Spacing = 12, MinWidth = 360,
                Children =
                {
                    new TextBlock { Text = $"Appearance and role for {bot.Name}.", Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush") },
                    title, about,
                },
            },
        };
        if (await HermesHQ.Services.SafeDialog.ShowAsync(root(), dialog) != ContentDialogResult.Primary) return;
        var newTitle = title.Text.Trim() == bot.Name ? null : title.Text.Trim();
        var newAbout = about.Text.Trim() == (bot.Role ?? "") ? null : about.Text.Trim();
        if (newTitle == null && newAbout == null) return;
        try
        {
            var outcome = await Store.SaveEditAsync(bot.Id, newTitle, newAbout);
            if (!outcome.Succeeded)
                await Prompts.FailureAsync(root(), outcome.TitleApplied == false ? "Couldn’t Save Changes" : "Couldn’t Save the Description",
                    outcome.Reason ?? BotWriteException.NotSavedReason);
        }
        catch (BotWriteException x) { await Prompts.FailureAsync(root(), x.Title, x.Reason); }
    }

    // ---------------------------------------------------------------- Bot Info (App/BotInfo/BotInfoSheet.swift)

    public async Task ShowInfoAsync(BotRow bot)
    {
        var secondary = ThemeBrushes.Get("TextFillColorSecondaryBrush");
        var head = new BotHead { Bot = bot.Model, Width = 72, Height = 72, HorizontalAlignment = HorizontalAlignment.Center };
        var header = new StackPanel { Spacing = 4, HorizontalAlignment = HorizontalAlignment.Center, Children = { head } };
        header.Children.Add(new TextBlock { Text = bot.Name, FontSize = 20, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center });
        if (bot.Role is { } role) header.Children.Add(new TextBlock { Text = role, Foreground = secondary, HorizontalAlignment = HorizontalAlignment.Center, TextWrapping = TextWrapping.Wrap });
        if (BotList.InfoStatus(bot, DateTimeOffset.UtcNow) is { } st)
            header.Children.Add(new TextBlock { Text = st, FontSize = 12, Foreground = secondary, HorizontalAlignment = HorizontalAlignment.Center });

        ContentDialog? dialog = null;
        void Close() => dialog?.Hide();
        Button Row(string text, Action run, string? value = null)
        {
            var g = new Grid { ColumnDefinitions = { new ColumnDefinition(), new ColumnDefinition { Width = GridLength.Auto } } };
            g.Children.Add(new TextBlock { Text = text });
            if (value != null) { var v = new TextBlock { Text = value, Foreground = secondary }; Grid.SetColumn(v, 1); g.Children.Add(v); }
            var b = new Button { Content = g, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
            // [WIN-55] The row read as one, as BotInfoSheet.swift's SwiftUI rows are: its words, then its value.
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(b, value == null ? text : $"{text}, {value}");
            b.Click += (_, _) => run();
            return b;
        }
        TextBlock Label(string text) => new() { Text = text, FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = secondary, Margin = new Thickness(0, 8, 0, 0) };

        var about = new StackPanel { Spacing = 6 };
        if (bot.Role is { Length: > 0 } description) about.Children.Add(new TextBlock { Text = description, TextWrapping = TextWrapping.Wrap });
        about.Children.Add(Row("Handle", () => { }, "@" + bot.Handle));
        if (bot.ModelName is { } model) about.Children.Add(Row("Model", () => { }, model));

        var chats = new StackPanel { Spacing = 6 };
        chats.Children.Add(Row("Bot Chat", () => { Close(); Navigator.Go(new BotChatDestination(bot.Model)); }));
        foreach (var s in hub.Sessions.LiveSummaries().Where(s => s.Profile == bot.Id).OrderByDescending(s => s.LastActive).Take(3))
            chats.Children.Add(Row(s.Title, () => { Close(); Navigator.Go(new ChatDestination(s.Profile, s.Id, s.Title)); }, ListTime.Format(s.LastActive)));
        chats.Children.Add(Row("New Chat", () => { Close(); NewChat?.Invoke(bot.Id); }));
        if (bot.OpenId != null || bot.Unread)
            chats.Children.Add(Row(bot.Unread ? "Mark Bot Chat as Read" : "Mark Bot Chat as Unread", () =>
            { if (bot.Unread) Store.MarkRead(bot.Id); else Store.MarkUnread(bot.Id); Close(); }));

        var settings = new StackPanel { Spacing = 6 };
        settings.Children.Add(Label("Notifications"));
        var muteButton = new DropDownButton { Content = "Mute Notifications · " + BotMutes.Value(Store.MuteOf(bot.Id, DateTimeOffset.UtcNow), DateTimeOffset.UtcNow), HorizontalAlignment = HorizontalAlignment.Stretch };
        var muteMenu = new MenuFlyout();
        foreach (var c in Enum.GetValues<MuteChoice>())
        {
            var item = new MenuFlyoutItem { Text = BotMutes.Title(c) };
            item.Click += (_, _) =>
            {
                Store.SetMute(bot.Id, c, DateTimeOffset.UtcNow);
                muteButton.Content = "Mute Notifications · " + BotMutes.Value(Store.MuteOf(bot.Id, DateTimeOffset.UtcNow), DateTimeOffset.UtcNow);
            };
            muteMenu.Items.Add(item);
        }
        muteButton.Flyout = muteMenu;
        settings.Children.Add(muteButton);
        settings.Children.Add(new TextBlock { Text = BotMutes.Scope, FontSize = 12, Foreground = secondary, TextWrapping = TextWrapping.Wrap });
        settings.Children.Add(Label("Organize"));
        var pinned = new ToggleSwitch { Header = "Pinned", IsOn = bot.Pinned };
        pinned.Toggled += (_, _) => { if (pinned.IsOn != bot.Pinned) _ = Pin(bot, pinned.IsOn); };
        var shown = new ToggleSwitch { Header = "Show in Bots", IsOn = !bot.Hidden };
        shown.Toggled += (_, _) => { if (shown.IsOn == bot.Hidden) _ = Hide(bot, !shown.IsOn); };
        settings.Children.Add(pinned);
        settings.Children.Add(shown);
        var current = PinnedSection.ShownSectionId(Store.CurrentMeta(bot.Id), PinnedSection.Current(Store.CurrentMeta(bot.Id)));
        var sectionButton = new DropDownButton
        {
            Content = "Section · " + (Store.Device.Sections.FirstOrDefault(s => s.Id == current)?.Name ?? BotList.UnassignedName),
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        var sectionMenu = new MenuFlyout();
        var unassigned = new ToggleMenuFlyoutItem { Text = BotList.UnassignedName, IsChecked = current == null };
        unassigned.Click += (_, _) => { Close(); _ = Move(bot, null); };
        sectionMenu.Items.Add(unassigned);
        foreach (var r in Store.Device.Sections)
        {
            var t = new ToggleMenuFlyoutItem { Text = r.Name, IsChecked = r.Id == current };
            t.Click += (_, _) => { Close(); _ = Move(bot, r.Id); };
            sectionMenu.Items.Add(t);
        }
        sectionMenu.Items.Add(new MenuFlyoutSeparator());
        var newSection = new MenuFlyoutItem { Text = "New Section…" };
        newSection.Click += (_, _) => { Close(); _ = NewSectionAsync(bot); };
        sectionMenu.Items.Add(newSection);
        sectionButton.Flyout = sectionMenu;
        settings.Children.Add(sectionButton);
        settings.Children.Add(Row("Duplicate Bot", () => { Close(); _ = DuplicateAsync(bot); }));
        if (!Store.IsDefaultBot(bot.Id))
        {
            var delete = Row("Delete Bot", () => { Close(); _ = DeleteAsync(bot); });
            delete.Foreground = ThemeBrushes.Get("SystemFillColorCriticalBrush");
            settings.Children.Add(delete);
        }
        settings.Children.Add(new TextBlock { Text = $"Bot ID {bot.Id} · {hub.Client.Session.Account.Label ?? hub.Client.Session.Address.Base.Host}", FontSize = 12, Foreground = secondary });

        var pivot = new Pivot();
        pivot.Items.Add(new PivotItem { Header = "About", Content = new ScrollViewer { Content = about, MaxHeight = 360 } });
        pivot.Items.Add(new PivotItem { Header = "Chats", Content = new ScrollViewer { Content = chats, MaxHeight = 360 } });
        pivot.Items.Add(new PivotItem { Header = "Settings", Content = new ScrollViewer { Content = settings, MaxHeight = 360 } });
        dialog = new ContentDialog
        {
            Title = "Bot Info", CloseButtonText = "Done", PrimaryButtonText = "Edit", XamlRoot = root(),
            Content = new StackPanel { Spacing = 12, MinWidth = 420, Children = { header, pivot } },
        };
        if (await HermesHQ.Services.SafeDialog.ShowAsync(root(), dialog) == ContentDialogResult.Primary) await EditAsync(bot);
    }
}
