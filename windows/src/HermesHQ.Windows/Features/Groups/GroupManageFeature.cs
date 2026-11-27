using Hermes.Core.Bots;
using Hermes.Core.Groups;
using HermesHQ.Controls;
using HermesHQ.Features.Bots;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Groups;

/// [groups] A room's management (App/Groups/GroupActions.swift, GroupInfoSheet.swift, GroupBotsPicker.swift,
/// AddToGroupController.swift): the room row's right-click menu, Group Info, the bots picker (New Group Chat in the
/// list's + menu, Edit Bots from Group Info) and Add to Group Chat… in a bot's menu. Decisions and words are
/// Hermes.Core.Groups (GroupRowMenu, GroupInfoWords, GroupPickRules, GroupJoinRules); the writes are GroupManager's.
/// [WIN-51] Members show their faces, and Name & Photo has the room's photo (GroupPhoto.swift).
/// Not here yet: Group Info's section picker, its Activity tile, a member's Bot Info, and the Hide Undo pill for a room.
public static class GroupManageFeature
{
    public static void Register()
    {
        ShellExtensions.RoomMenu = FillRoomMenu;
        BotActions.PlaceItems.Add(AddToGroupItem);
        BotActions.AddItems.Add(NewGroupItem);
    }

    private static ListsHub? Hub => ListsHub.Current;
    internal static bool Writable(ListsHub hub) => hub.Groups.IsOnline() && !hub.Bots.ReadOnly;

    private static MenuFlyoutItem Item(string text, string glyph, string id, Action run, bool enabled = true)
    {
        var i = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph }, IsEnabled = enabled };
        AutomationProperties.SetAutomationId(i, id);
        i.Click += (_, _) => run();
        return i;
    }

    private static Brush Critical => ThemeBrushes.Get("SystemFillColorCriticalBrush");
    private static Brush Secondary => ThemeBrushes.Get("TextFillColorSecondaryBrush");

    // ---------------------------------------------------------------- the room row's menu (GroupActions.menuNodes)

    public static void FillRoomMenu(IList<MenuFlyoutItemBase> items, GroupRowModel room, XamlRoot root)
    {
        items.Clear();
        if (Hub is not { } hub) return;
        var key = room.Id;
        foreach (var node in GroupRowMenu.Items(room, Writable(hub)))
        {
            if (node.Separated) items.Add(new MenuFlyoutSeparator());
            var id = "room.menu." + node.Id;
            switch (node.Id)
            {
                case "info":
                    items.Add(Item(node.Title, "\uE946", id, () => _ = ShowInfoAsync(root, key)));
                    break;
                case "pin":
                    items.Add(Item(node.Title, room.Pinned ? "\uE77A" : "\uE718", id, () => hub.Groups.SetPinned(key, !room.Pinned)));
                    break;
                case "mute" when node.Durations.Count == 0:
                    items.Add(Item(node.Title, "\uEA8F", id, () => hub.Bots.SetMute(GroupKeys.MuteKey(key), MuteChoice.Off, DateTimeOffset.UtcNow)));
                    break;
                case "mute":
                    var sub = new MenuFlyoutSubItem { Text = node.Title, Icon = new FontIcon { Glyph = "\uE7ED" } };
                    AutomationProperties.SetAutomationId(sub, id);
                    foreach (var choice in node.Durations)
                        sub.Items.Add(Item(BotMutes.Title(choice), "", id + "." + choice, () => hub.Bots.SetMute(GroupKeys.MuteKey(key), choice, DateTimeOffset.UtcNow)));
                    items.Add(sub);
                    break;
                case "unread":
                    items.Add(Item(node.Title, room.Unread ? "\uE8C3" : "\uE715", id, () => hub.Groups.SetUnread(key, !hub.Groups.IsUnread(key))));
                    break;
                case "hide":
                    items.Add(Item(node.Title, room.Hidden ? "\uE7B3" : "\uED1A", id, () => hub.Groups.SetHidden(key, !room.Hidden)));
                    break;
                case "delete":
                    var delete = Item(node.Title, "\uE74D", id, () => _ = ConfirmDeleteAsync(root, key), node.Enabled);
                    if (node.Enabled) delete.Foreground = Critical;
                    if (node.Subtitle != null) ToolTipService.SetToolTip(delete, node.Subtitle);
                    items.Add(delete);
                    break;
            }
        }
    }

    /// Delete Group Chat's question (a centred alert on the Mac, as here), then the delete.
    public static async Task<bool> ConfirmDeleteAsync(XamlRoot root, string key)
    {
        if (Hub is not { } hub || hub.Groups.Room(key) is not { } room) return false;
        if (!await Prompts.ConfirmAsync(root, GroupManageWords.DeleteTitle(room.Name), GroupManageWords.DeleteMessage, GroupManageWords.DeleteAction))
            return false;
        if (GroupRoomPageOpen(key)) Navigator.Open("sessions");
        await Prompts.RunAsync(root, GroupManageWords.CouldNotDelete(room.Name), () => hub.GroupManager.DeleteAsync(key));
        return true;
    }

    private static bool GroupRoomPageOpen(string key) => Pages.GroupRoomPage.Current is { } p && p.RoomKey == key;

    // ---------------------------------------------------------------- Group Info (GroupInfoSheet)

    /// The open Group Info (the walk reads it).
    public static ContentDialog? InfoDialog { get; private set; }

    public static async Task ShowInfoAsync(XamlRoot root, string key)
    {
        if (Hub is not { } hub || hub.Groups.Room(key) == null) return;
        var dialog = new ContentDialog { Title = GroupInfoWords.Title, CloseButtonText = "Done", XamlRoot = root, DefaultButton = ContentDialogButton.Close };
        AutomationProperties.SetAutomationId(dialog, "group-info");
        Func<Task>? next = null;
        void Then(Func<Task> after) { next = after; dialog.Hide(); }
        void Draw()
        {
            if (hub.Groups.Room(key) is not { } room) { dialog.Hide(); return; }
            dialog.Content = InfoContent(hub, room, Then);
        }
        void Changed() => dialog.DispatcherQueue.TryEnqueue(Draw);
        Draw();
        hub.Groups.Changed += Changed;
        hub.Bots.Changed += Changed;
        InfoDialog = dialog;
        try { await SafeDialog.ShowAsync(root, dialog); }
        finally
        {
            hub.Groups.Changed -= Changed;
            hub.Bots.Changed -= Changed;
            if (InfoDialog == dialog) InfoDialog = null;
        }
        if (next != null) await next();
    }

    private static UIElement InfoContent(ListsHub hub, GroupRoom room, Action<Func<Task>> then)
    {
        var key = room.Key;
        var root = new StackPanel { Spacing = 10, MinWidth = 420, MaxWidth = 478 };
        var row = hub.Groups.Rows().FirstOrDefault(r => r.Id == key);
        var seats = hub.Groups.Seated(room);
        var online = Writable(hub);
        var floor = GroupInfoWords.IsFloor(seats.Count);

        // The header: the room's face, its name, its line, the tiles.
        if (row != null) root.Children.Add(new GroupAvatar(row, 80, p => hub.Bots.Bot(p)?.Model) { HorizontalAlignment = HorizontalAlignment.Center });
        root.Children.Add(Named(new TextBlock { Text = room.Name, FontSize = 20, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center }, "group-info.name"));
        root.Children.Add(Named(new TextBlock { Text = GroupInfoWords.Subtitle(row, seats.Count), Foreground = Secondary, HorizontalAlignment = HorizontalAlignment.Center, TextWrapping = TextWrapping.Wrap }, "group-info.subtitle"));
        var muted = row?.Muted ?? false;
        var tiles = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center };
        tiles.Children.Add(Button(GroupInfoWords.EditBots(floor), "group-info.tile.add", online && !room.IsHosted,
            () => then(() => ShowPickerAsync(hub, root: null, editing: key))));
        tiles.Children.Add(Button(GroupActivitySheet.Title, "group-info.tile.activity", true,
            () => then(async () =>
            {
                await GroupActivityDialog.ShowAsync(XamlRootOf(), hub, key);
                if (hub.Groups.Room(key) != null) await ShowInfoAsync(XamlRootOf(), key);
            })));
        tiles.Children.Add(Button(GroupInfoWords.MuteTile(muted), "group-info.tile.mute", true,
            () => hub.Bots.SetMute(GroupKeys.MuteKey(key), muted ? MuteChoice.Off : MuteChoice.Always, DateTimeOffset.UtcNow)));
        root.Children.Add(tiles);

        // Members.
        root.Children.Add(Header(GroupInfoWords.Members));
        foreach (var seat in seats) root.Children.Add(MemberRow(hub, room, seat));
        if (floor) root.Children.Add(Named(Footer(GroupInfoWords.Floor), "group-info.floor"));

        // Group Chat: Name & Photo, Mark as Read / Unread.
        root.Children.Add(Header(GroupInfoWords.GroupChat));
        root.Children.Add(Button(GroupInfoWords.NameAndPhoto, "group-info.name-photo", online, () => then(() => NamePhotoAsync(hub, key))));
        var unread = hub.Groups.IsUnread(key);
        root.Children.Add(Button(GroupInfoWords.Unread(unread), "group-info.unread", true, () => hub.Groups.SetUnread(key, !unread)));

        // Notifications: Mute Notifications with its durations.
        root.Children.Add(Header(GroupInfoWords.Notifications));
        var mute = new DropDownButton { Content = $"{GroupInfoWords.MuteNotifications}: {BotMutes.Value(hub.Bots.MuteOf(GroupKeys.MuteKey(key), DateTimeOffset.UtcNow), DateTimeOffset.UtcNow)}" };
        AutomationProperties.SetAutomationId(mute, "group-info.mute");
        var muteMenu = new MenuFlyout();
        foreach (var choice in Enum.GetValues<MuteChoice>())
        {
            var item = new MenuFlyoutItem { Text = BotMutes.Title(choice) };
            item.Click += (_, _) => hub.Bots.SetMute(GroupKeys.MuteKey(key), choice, DateTimeOffset.UtcNow);
            muteMenu.Items.Add(item);
        }
        mute.Flyout = muteMenu;
        root.Children.Add(mute);

        // Organize: Pinned, Show in Bots.
        root.Children.Add(Header(GroupInfoWords.Organize));
        var pinned = new ToggleSwitch { Header = GroupInfoWords.Pinned, IsOn = room.Pinned };
        AutomationProperties.SetAutomationId(pinned, "group-info.pinned");
        pinned.Toggled += (_, _) => { if (pinned.IsOn != hub.Groups.Room(key)?.Pinned) hub.Groups.SetPinned(key, pinned.IsOn); };
        root.Children.Add(pinned);
        var shown = new ToggleSwitch { Header = GroupInfoWords.ShowInBots, IsOn = !room.Hidden };
        AutomationProperties.SetAutomationId(shown, "group-info.shown");
        shown.Toggled += (_, _) => { if (shown.IsOn == hub.Groups.Room(key)?.Hidden) hub.Groups.SetHidden(key, !shown.IsOn); };
        root.Children.Add(shown);
        if (!online) root.Children.Add(Named(Footer(GroupInfoWords.OfflineFooter), "group-info.offline"));

        var delete = Button(GroupManageWords.DeleteAction, "group-info.delete", online, () => then(async () =>
        {
            if (!await ConfirmDeleteAsync(XamlRootOf(), key)) await ShowInfoAsync(XamlRootOf(), key);
        }));
        delete.Foreground = Critical;
        root.Children.Add(delete);
        return new ScrollViewer { Content = root, MaxHeight = 560 };
    }

    private static XamlRoot XamlRootOf() => Pages.ShellPage.Current?.XamlRoot ?? throw new InvalidOperationException("the shell isn't showing");

    private static T Named<T>(T e, string id) where T : FrameworkElement { AutomationProperties.SetAutomationId(e, id); return e; }
    private static TextBlock Header(string text) => new() { Text = text, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 8, 0, 0) };
    private static TextBlock Footer(string text) => new() { Text = text, FontSize = 12, Foreground = Secondary, TextWrapping = TextWrapping.Wrap };

    private static Button Button(string text, string id, bool enabled, Action run)
    {
        var b = new Button { Content = text, IsEnabled = enabled };
        AutomationProperties.SetAutomationId(b, id);
        b.Click += (_, _) => run();
        return b;
    }

    /// A member's row (GroupInfoView.memberRow): the face, the name, and its second line when there is one.
    private static Grid MemberRow(ListsHub hub, GroupRoom room, GroupSeat seat)
    {
        var bot = hub.Bots.Bot(seat.Name);
        var line = GroupInfoWords.MemberLine(seat, room, bot?.Role);
        var row = new Grid { ColumnSpacing = 12, Padding = new Thickness(0, 4, 0, 4) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var face = new BotHead { Width = 40, Height = 40, VerticalAlignment = VerticalAlignment.Center };
        if (bot?.Model is { } model) face.Bot = model; else face.DisplayName = seat.Display;
        AutomationProperties.SetAccessibilityView(face, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        row.Children.Add(face);
        var words = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(new TextBlock { Text = seat.Display });
        if (line != null)
            words.Children.Add(new TextBlock
            {
                Text = line, FontSize = 13, MaxLines = 2, TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis,
                Foreground = line == "Replying…" ? ThemeBrushes.Get("AccentTextFillColorPrimaryBrush") : Secondary,
            });
        Grid.SetColumn(words, 1);
        row.Children.Add(words);
        AutomationProperties.SetName(row, line == null ? seat.Display : $"{seat.Display}, {line}");
        return Named(row, "group-info.member." + seat.Name);
    }

    // ---------------------------------------------------------------- Name & Photo (GroupNamePhotoController)

    /// The open Name & Photo (the walk reads it), and its photo's setter (the walk's synthetic pick).
    public static ContentDialog? NamePhotoDialog { get; private set; }
    public static Action<string?>? NamePhotoSetImage { get; private set; }

    /// Name & Photo: the line, the photo with Choose Photo and Remove Photo, the name, Save. A taken name shows under the
    /// field and keeps the page; Cancel with changes asks Discard Changes?. Back to Group Info after.
    private static async Task NamePhotoAsync(ListsHub hub, string key)
    {
        if (hub.Groups.Room(key) is not { } room) return;
        var root = XamlRootOf();
        var uid = room.Uid;
        var draft = new GroupNamePhotoDraft(room.Name, room.Image);
        var dialog = new ContentDialog
        {
            Title = GroupInfoWords.NameAndPhoto, PrimaryButtonText = draft.SaveTitle, CloseButtonText = "Cancel", XamlRoot = root,
            DefaultButton = ContentDialogButton.Primary,
        };
        AutomationProperties.SetAutomationId(dialog, "group-settings");
        var panel = new StackPanel { Spacing = 10, MinWidth = 380 };
        panel.Children.Add(Named(new TextBlock { Text = GroupInfoWords.RenameIntro, Foreground = Secondary, TextWrapping = TextWrapping.Wrap }, "group-settings.intro"));
        panel.Children.Add(Header(GroupPhoto.Header));
        var photoRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16, Padding = new Thickness(0, 12, 0, 12) };
        var avatar = new Border { Width = 64, Height = 64, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetAutomationId(avatar, "group-settings.photo");
        photoRow.Children.Add(avatar);
        var buttons = new StackPanel { Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        var choose = Button(GroupPhoto.ChoosePhoto, "group-settings.choose-photo", true, () => { });
        var remove = Button(GroupPhoto.RemovePhoto, "group-settings.remove-photo", true, () => { });
        remove.Foreground = Critical;
        buttons.Children.Add(choose);
        buttons.Children.Add(remove);
        photoRow.Children.Add(buttons);
        panel.Children.Add(photoRow);
        panel.Children.Add(Header(GroupInfoWords.GroupName));
        var name = new TextBox { Text = draft.Name, PlaceholderText = GroupInfoWords.GroupName, MaxLength = GroupLimits.NameMax };
        AutomationProperties.SetName(name, GroupInfoWords.GroupName);
        AutomationProperties.SetAutomationId(name, "group-settings.name");
        panel.Children.Add(name);
        var problem = Named(new TextBlock { Foreground = Critical, TextWrapping = TextWrapping.Wrap, FontSize = 12 }, "group-settings.problem");
        panel.Children.Add(problem);
        dialog.Content = new ScrollViewer { Content = panel, MaxHeight = 560 };

        string? drawnImage = "\u0000";
        void Draw()
        {
            if (draft.Image != drawnImage)
            {
                drawnImage = draft.Image;
                var row = hub.Groups.Rows().FirstOrDefault(r => r.Id == key)
                    ?? new GroupRowModel(key, draft.OriginalName, "", GroupRowWords.Tone.Secondary);
                avatar.Child = new GroupAvatar(row with { Image = draft.Image }, 64, p => hub.Bots.Bot(p)?.Model);
            }
            remove.Visibility = draft.ShowsRemove ? Visibility.Visible : Visibility.Collapsed;
            problem.Text = draft.Problem ?? "";
            problem.Visibility = draft.Problem == null ? Visibility.Collapsed : Visibility.Visible;
            dialog.PrimaryButtonText = draft.SaveTitle;
            dialog.IsPrimaryButtonEnabled = draft.CanSave;
            panel.IsHitTestVisible = !draft.Saving;
        }
        var failed = false;
        choose.Click += async (_, _) =>
        {
            try
            {
                var url = await PickPhotoAsync();
                if (url is { Length: 0 }) return;   // cancelled: nothing changes
                if (url == null) { failed = true; dialog.Hide(); return; }
                draft.Image = url;
                Draw();
            }
            catch (Exception ex) { AppLog.Error("groups", ex); }
        };
        remove.Click += (_, _) => { draft.Image = null; Draw(); };
        name.TextChanged += (_, _) => { draft.Name = name.Text; draft.Problem = null; Draw(); };
        Exception? failure = null;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            if (!draft.CanSave) { args.Cancel = true; return; }
            var deferral = args.GetDeferral();
            draft.Problem = null;
            draft.Saving = true;
            Draw();
            try
            {
                await hub.GroupManager.SaveNameAndPhotoAsync(key, draft.NameChanged ? draft.CleanName : null, draft.ImageChanged, draft.Image);
            }
            catch (GroupNameTakenException e) { draft.Problem = e.Message; args.Cancel = true; }
            catch (Exception e) when (e is BotWriteException or Hermes.Core.Net.GatewayException) { failure = e; }
            catch (Exception e) { AppLog.Error("groups", e); failure = e; }
            finally
            {
                draft.Saving = false;
                Draw();
                deferral.Complete();
            }
        };
        Draw();
        NamePhotoDialog = dialog;
        NamePhotoSetImage = image => { draft.Image = image; Draw(); };
        try
        {
            while (true)
            {
                failure = null;
                var result = await SafeDialog.ShowAsync(root, dialog);
                if (failed)
                {
                    failed = false;
                    await Prompts.FailureAsync(root, GroupPhoto.FailedTitle, GroupPhoto.FailedReason);
                    continue;
                }
                if (result == ContentDialogResult.Primary) break;
                // Cancel (or Escape) with changes: Discard Changes?, Keep Editing its default.
                if (failure == null && draft.HasChanges && !await DiscardAsync(root) && hub.Groups.Rooms.Any(r => r.Uid == uid)) continue;
                break;
            }
        }
        finally
        {
            if (NamePhotoDialog == dialog) { NamePhotoDialog = null; NamePhotoSetImage = null; }
        }
        if (failure != null)
        {
            var title = failure is BotWriteException { Title.Length: > 0 } w ? w.Title : GroupManageWords.CouldNotRename(draft.OriginalName);
            var reason = failure is BotWriteException b ? b.Reason : Hermes.Core.Sessions.SessionStore.ReasonOf(failure);
            await Prompts.FailureAsync(root, title, reason, () => Prompts.RunAsync(root, GroupManageWords.CouldNotRename(draft.OriginalName),
                () => hub.GroupManager.SaveNameAndPhotoAsync(KeyOf(hub, uid) ?? key, draft.NameChanged ? draft.CleanName : null, draft.ImageChanged, draft.Image)));
        }
        if (KeyOf(hub, uid) is { } now) await ShowInfoAsync(root, now);
    }

    /// EditingGuard.askToDiscard on the Mac: “Discard Changes?”, Keep Editing its default for Return and Escape.
    private static async Task<bool> DiscardAsync(XamlRoot root)
    {
        var ask = new ContentDialog
        {
            Title = "Discard Changes?", PrimaryButtonText = "Discard Changes", CloseButtonText = "Keep Editing",
            DefaultButton = ContentDialogButton.Close,
        };
        AutomationProperties.SetAutomationId(ask, "group-settings.discard");
        return await SafeDialog.ShowAsync(root, ask) == ContentDialogResult.Primary;
    }

    private static string? KeyOf(ListsHub hub, Guid uid) => hub.Groups.Rooms.FirstOrDefault(r => r.Uid == uid)?.Key;

    /// The system's photo picker (images only, one): the photo's data URL; "" when cancelled; null when it couldn't be
    /// read or made small enough (Couldn’t Use That Photo).
    private static async Task<string?> PickPhotoAsync()
    {
        if (App.Window is not { } window) return null;
        var picker = new Microsoft.Windows.Storage.Pickers.FileOpenPicker(window.AppWindow.Id)
        {
            ViewMode = Microsoft.Windows.Storage.Pickers.PickerViewMode.Thumbnail,
            SuggestedStartLocation = Microsoft.Windows.Storage.Pickers.PickerLocationId.PicturesLibrary,
        };
        foreach (var ext in Hermes.Core.Attachments.MediaKinds.ImageExtensions) picker.FileTypeFilter.Add("." + ext);
        Microsoft.Windows.Storage.Pickers.PickFileResult? file;
        try { file = await picker.PickSingleFileAsync(); }
        catch (Exception e) { AppLog.Error("groups", e); return null; }
        if (file == null || string.IsNullOrEmpty(file.Path)) return "";
        try
        {
            await using var fs = new FileStream(file.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 64 * 1024, useAsync: true);
            using var stream = fs.AsRandomAccessStream();
            return await GroupPhotoImaging.DataUrlAsync(stream);
        }
        catch (Exception e) { AppLog.Error("groups", e); return null; }
    }

    // ---------------------------------------------------------------- the bots picker (GroupBotsPicker)

    public static ContentDialog? PickerDialog { get; private set; }

    private static MenuFlyoutItemBase NewGroupItem(XamlRoot root)
    {
        var hub = Hub;
        var reason = hub == null ? null : GroupManageWords.NewGroupDisabledReason(hub.Bots.Rows.Count(r => !r.Hidden), Writable(hub));
        var item = Item(GroupManageWords.NewGroupChat, "\uE902", "bots.add.new-group", () => { if (Hub is { } h) _ = ShowPickerAsync(h, root, editing: null); },
            hub != null && reason == null);
        if (reason != null) ToolTipService.SetToolTip(item, reason);
        return item;
    }

    /// New Group Chat (editing null) or Edit Bots for a room: pick 2–6 bots.
    public static async Task ShowPickerAsync(ListsHub hub, XamlRoot? root, string? editing)
    {
        root ??= XamlRootOf();
        var room = editing == null ? null : hub.Groups.Room(editing);
        if (editing != null && room == null) return;
        var picked = room == null ? new List<string>() : hub.Groups.Seated(room).Where(s => !s.Remote).Select(s => s.Name).ToList();
        var initial = picked.ToHashSet(StringComparer.Ordinal);
        var dialog = new ContentDialog
        {
            Title = GroupPickRules.Title(room?.Name), PrimaryButtonText = GroupPickRules.Save(room != null), CloseButtonText = "Cancel",
            XamlRoot = root, DefaultButton = ContentDialogButton.Primary,
        };
        AutomationProperties.SetAutomationId(dialog, "group-bots-picker");
        var panel = new StackPanel { Spacing = 8, MinWidth = 420, MaxWidth = 478 };
        panel.Children.Add(Named(new TextBlock { Text = GroupPickRules.Line(room?.Name), TextWrapping = TextWrapping.Wrap, Foreground = Secondary }, "group-picker.line"));
        var chipsScroll = new ScrollViewer { HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollMode = ScrollMode.Disabled, Visibility = Visibility.Collapsed };
        var chips = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Padding = new Thickness(0, 2, 0, 2) };
        chipsScroll.Content = chips;
        panel.Children.Add(chipsScroll);
        var name = new TextBox { MaxLength = GroupLimits.NameMax };
        AutomationProperties.SetName(name, GroupInfoWords.GroupName);
        AutomationProperties.SetAutomationId(name, "group-picker.name");
        if (room == null) panel.Children.Add(name);
        var search = new TextBox { PlaceholderText = GroupPickRules.Search };
        AutomationProperties.SetAutomationId(search, "group-picker.search");
        panel.Children.Add(search);
        var list = new StackPanel { Spacing = 4 };
        panel.Children.Add(new ScrollViewer { Content = list, MaxHeight = 360 });
        var footer = Named(Footer(""), "group-picker.footer");
        panel.Children.Add(footer);
        dialog.Content = panel;

        List<BotRow> Bots() => [.. hub.Bots.Rows.Where(r => !r.Hidden || picked.Contains(r.Id))];
        string NameOf(string id) => hub.Bots.Bot(id)?.Name ?? id;
        void Draw()
        {
            chips.Children.Clear();
            foreach (var id in picked)
            {
                var chipBody = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
                var chipFace = new BotHead { Width = 18, Height = 18, VerticalAlignment = VerticalAlignment.Center };
                if (hub.Bots.Bot(id)?.Model is { } cm) chipFace.Bot = cm; else chipFace.DisplayName = NameOf(id);
                chipBody.Children.Add(chipFace);
                chipBody.Children.Add(new TextBlock { Text = NameOf(id), FontSize = 12, VerticalAlignment = VerticalAlignment.Center });
                chips.Children.Add(new Border
                {
                    Child = chipBody, CornerRadius = new CornerRadius(12), Padding = new Thickness(8, 3, 10, 3),
                    Background = ThemeBrushes.Get("HQBotBubbleBrush"),
                });
            }
            chipsScroll.Visibility = picked.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

            list.Children.Clear();
            var shown = Bots().Where(b => GroupPickRules.Matches(b.Name, b.Id, b.Role, search.Text)).ToList();
            foreach (var bot in shown)
            {
                var on = picked.Contains(bot.Id);
                var locked = on && room != null && picked.Count <= GroupLimits.MinMembers;
                var rowContent = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
                var face = new BotHead { Width = 32, Height = 32, VerticalAlignment = VerticalAlignment.Center };
                if (bot.Model is { } bm) face.Bot = bm; else face.DisplayName = bot.Name;
                AutomationProperties.SetAccessibilityView(face, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
                rowContent.Children.Add(face);
                var wordsPanel = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Spacing = 1 };
                wordsPanel.Children.Add(new TextBlock { Text = bot.Name, FontSize = 14 });
                if (!string.IsNullOrWhiteSpace(bot.Role))
                    wordsPanel.Children.Add(new TextBlock { Text = bot.Role, FontSize = 12, Foreground = Secondary, MaxLines = 1, TextTrimming = TextTrimming.CharacterEllipsis });
                rowContent.Children.Add(wordsPanel);
                var box = new CheckBox { Content = rowContent, IsChecked = on, IsEnabled = !locked, HorizontalAlignment = HorizontalAlignment.Stretch, Padding = new Thickness(8, 4, 8, 4) };
                AutomationProperties.SetName(box, string.IsNullOrWhiteSpace(bot.Role) ? bot.Name : $"{bot.Name}, {bot.Role}");
                AutomationProperties.SetAutomationId(box, "group-picker.bot." + bot.Id);
                box.Click += (_, _) =>
                {
                    picked = GroupPickRules.Toggle(bot.Id, picked, room != null).Picked;
                    Draw();
                };
                list.Children.Add(box);
            }
            if (shown.Count == 0) list.Children.Add(Named(Footer(GroupPickRules.None(search.Text)), "group-picker.none"));
            var words = GroupPickRules.Footer(picked.Count, room != null);
            footer.Text = words ?? "";
            footer.Visibility = words == null ? Visibility.Collapsed : Visibility.Visible;
            name.PlaceholderText = GroupPickRules.Placeholder([.. picked.Select(NameOf)]);
            // Mac GroupBotsPicker: Save stays disabled until the set of group members actually changes.
            var changed = room == null || !initial.SetEquals(picked);
            dialog.IsPrimaryButtonEnabled = GroupPickRules.CanCreate(picked.Count) && changed && Writable(hub);
        }
        search.TextChanged += (_, _) => Draw();
        Draw();
        PickerDialog = dialog;
        ContentDialogResult result;
        try { result = await SafeDialog.ShowAsync(root, dialog); }
        finally { if (PickerDialog == dialog) PickerDialog = null; }
        if (result != ContentDialogResult.Primary)
        {
            if (room != null) await ShowInfoAsync(root, room.Key);
            return;
        }
        if (room != null)
        {
            await Prompts.RunAsync(root, GroupManageWords.CouldNotChangeBots(room.Name), () => hub.GroupManager.SetMembersAsync(room.Key, picked));
            await ShowInfoAsync(root, room.Key);
            return;
        }
        var typed = GroupKeys.CleanName(name.Text);
        var title = typed.Length > 0 ? typed : GroupKeys.CleanName(GroupPickRules.Placeholder([.. picked.Select(NameOf)]));
        string? key = null;
        if (await Prompts.RunAsync(root, GroupManageWords.CouldNotCreate(title), async () => key = await hub.GroupManager.CreateAsync(title, picked)) && key != null)
            Navigator.Go(new RoomDestination(key));
    }

    // ---------------------------------------------------------------- Add to Group Chat… (AddToGroupController)

    public static ContentDialog? AddToGroupDialog { get; private set; }

    private static MenuFlyoutItemBase? AddToGroupItem(BotRow bot, XamlRoot root)
    {
        if (Hub is not { } hub) return null;
        return Item(GroupManageWords.AddToGroupChat, "\uE902", "bot.add-to-group", () => _ = ShowAddToGroupAsync(hub, root, bot.Id), Writable(hub));
    }

    public static async Task ShowAddToGroupAsync(ListsHub hub, XamlRoot root, string profile)
    {
        var botName = hub.Bots.Bot(profile)?.Name ?? profile;
        var dialog = new ContentDialog { Title = GroupJoinRules.Title(botName), CloseButtonText = "Done", XamlRoot = root, DefaultButton = ContentDialogButton.Close };
        AutomationProperties.SetAutomationId(dialog, "add-to-group");
        var busy = new HashSet<string>();
        var problem = (string?)null;
        var newName = "";
        var removeAll = false;
        void Draw()
        {
            var mine = hub.Groups.RoomsOf(profile).Select(r => r.Key).ToHashSet();
            var rows = hub.Groups.Rooms.Select(r => (Room: r, Member: mine.Contains(r.Key), Count: hub.Groups.Seated(r).Count))
                .OrderBy(r => r.Room.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
            var online = Writable(hub);
            var working = busy.Count > 0;
            var panel = new StackPanel { Spacing = 8, MinWidth = 380 };
            panel.Children.Add(new TextBlock { Text = GroupJoinRules.Intro, Foreground = Secondary, TextWrapping = TextWrapping.Wrap });
            foreach (var (room, member, count) in rows)
            {
                var line = new Grid { ColumnSpacing = 12 };
                line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var words = new StackPanel();
                words.Children.Add(new TextBlock { Text = room.Name });
                words.Children.Add(new TextBlock { Text = GroupJoinRules.Subtitle(member, count), FontSize = 12, Foreground = Secondary });
                line.Children.Add(words);
                var state = GroupJoinRules.Of(member, count);
                var toggle = new ToggleSwitch { IsOn = member, OnContent = "", OffContent = "", IsEnabled = state == GroupJoinRules.State.Open && online && !working };
                AutomationProperties.SetName(toggle, room.Name);
                AutomationProperties.SetAutomationId(toggle, "add-to-group.switch." + room.Name);
                Grid.SetColumn(toggle, 1);
                var key = room.Key;
                toggle.Toggled += async (_, _) =>
                {
                    if (toggle.IsOn == member || busy.Contains(key)) return;
                    busy.Add(key);
                    Draw();
                    try { await hub.GroupManager.SetMembershipAsync(profile, key, toggle.IsOn, botName); }
                    catch (BotWriteException e) { problem = e.Reason; }
                    catch (Exception e) { AppLog.Error("groups", e); problem = "Couldn’t update group membership."; }
                    finally { busy.Remove(key); Draw(); }
                };
                line.Children.Add(toggle);
                panel.Children.Add(line);
            }
            if (!rows.Any(r => r.Member))
                panel.Children.Add(Named(Footer(GroupJoinRules.EmptyLine(botName, rows.Count > 0)), "add-to-group.empty"));
            var name = new TextBox { PlaceholderText = GroupJoinRules.NewName, Text = newName, MaxLength = GroupLimits.NameMax };
            AutomationProperties.SetAutomationId(name, "add-to-group.name");
            var create = Button(GroupJoinRules.CreateAndJoin, "add-to-group.create", GroupKeys.CleanName(newName).Length > 0 && online && !working, () => { });
            name.TextChanged += (_, _) => { newName = name.Text; problem = null; create.IsEnabled = GroupKeys.CleanName(newName).Length > 0 && online && busy.Count == 0; };
            create.Click += async (_, _) =>
            {
                busy.Add("+create");
                Draw();
                try { await hub.GroupManager.CreateSoloAsync(newName, profile, botName); newName = ""; }
                catch (GroupNameTakenException e) { problem = e.Message; }
                catch (BotWriteException e) { problem = e.Reason; }
                catch (Exception e) { AppLog.Error("groups", e); problem = "Couldn’t create group chat."; }
                finally { busy.Remove("+create"); Draw(); }
            };
            panel.Children.Add(name);
            panel.Children.Add(create);
            if (problem != null)
                panel.Children.Add(Named(new TextBlock { Text = problem, Foreground = Critical, TextWrapping = TextWrapping.Wrap }, "add-to-group.problem"));
            if (GroupJoinRules.CanRemoveAll([.. rows.Where(r => r.Member).Select(r => r.Count)]))
            {
                var remove = Button(GroupJoinRules.RemoveAll, "add-to-group.remove-all", online && !working, () => { removeAll = true; dialog.Hide(); });
                remove.Foreground = Critical;
                panel.Children.Add(remove);
            }
            dialog.Content = new ScrollViewer { Content = panel, MaxHeight = 560 };
        }
        void Changed() => dialog.DispatcherQueue.TryEnqueue(() => { if (busy.Count == 0) Draw(); });
        Draw();
        hub.Groups.Changed += Changed;
        AddToGroupDialog = dialog;
        try { await SafeDialog.ShowAsync(root, dialog); }
        finally
        {
            hub.Groups.Changed -= Changed;
            if (AddToGroupDialog == dialog) AddToGroupDialog = null;
        }
        if (!removeAll) return;
        // Asked first: it leaves every room at once.
        if (await Prompts.ConfirmAsync(root, GroupJoinRules.RemoveAllTitle(botName), GroupJoinRules.RemoveAllMessage, GroupJoinRules.RemoveAll))
        {
            var keys = hub.Groups.RoomsOf(profile).Select(r => r.Key).ToList();
            await Prompts.RunAsync(root, GroupManageWords.CouldNotChangeGroupChats(botName), async () =>
            {
                foreach (var key in keys) await hub.GroupManager.SetMembershipAsync(profile, key, false, botName);
            });
        }
        await ShowAddToGroupAsync(hub, root, profile);
    }
}
