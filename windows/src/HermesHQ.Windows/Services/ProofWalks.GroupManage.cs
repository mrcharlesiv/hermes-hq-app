using Hermes.Core.Groups;
using Hermes.Core.Shell;
using HermesHQ.Controls;
using HermesHQ.Features.Bots;
using HermesHQ.Features.Groups;
using HermesHQ.Pages;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Services;

/// [WIN-46] The CI's walk for a room's management (windows/ci/windows.yml asks for it on the groups stand-in,
/// settings-gateway.py --group-rooms), backed by `Hermes.Core.Shell.GroupManageWalkProof`. It opens and shows; it writes
/// nothing, so the room walks that share the stand-in keep their seed:
///   group-manage  Launch Room's sidebar row's right-click menu: Group Info · Pin · Mute · Mark as Unread · Hide ·
///                 Delete Group Chat ("group-row-menu"). Group Info from it: the room's name, its line, Ivy and Research
///                 under Members ("group-info"). Its Edit Bots tile: the bots picker titled Launch Room, both members
///                 picked and locked at 2, the floor's footer ("group-bots-picker"); Cancel returns to Group Info, Done
///                 closes it ("group-manage").
///                 [WIN-51] Group Info's members each with a face (BotHead) beside the name ("group-info-faces"). From
///                 Group Info again, Name & Photo: a synthetic picture made a photo through the picked file's path,
///                 shown in its avatar with Remove Photo and Save on ("group-photo"); Remove Photo, then Cancel, writes
///                 nothing.
/// The walk's pointer has no right button: the row's menu opens as a right-click does (its ContextFlyout at the row).
internal static partial class ProofWalks
{
    private static void RegisterGroupManageWalks()
    {
        Automation.NamedWalks["group-manage"] = GroupManageAsync;
    }

    private static async Task GroupManageAsync(Func<string, Task> shot)
    {
        if (AppState.Client == null) throw new InvalidOperationException("not signed in");
        var shell = ShellPage.Current ?? throw new InvalidOperationException("the shell isn't showing");
        const string key = GroupManageWalkProof.LaunchKey;
        await Until(() => Find(SidebarSearch.ToolsAutomationId), "the sidebar");
        if (Find(SidebarSearch.ToolsAutomationId) is not Grid) await FoldAsync(shell, fold: false);
        var hub = await Until(() => ListsHub.Current is { } h && h.Groups.Room(key) != null ? h : null, "Launch Room in the group chats", 30);
        hub.Groups.SetUnread(key, false);

        // The row's menu, as a right-click opens it.
        var row = (FrameworkElement)await Until(() => Find("sidebar.room." + key), "Launch Room's row");
        var holder = Holder(row) ?? throw new InvalidOperationException("Launch Room's row has no menu");
        AppLog.Note("automation", "walk group-manage: opening the room's menu as a right-click does");
        holder.ContextFlyout.ShowAt(holder);
        var info = await Until(() => MenuItem("Group Info"), "Group Info in the room's menu");
        var entries = InPopups().OfType<MenuFlyoutItemBase>()
            .Select(i => i switch { MenuFlyoutItem m => (m.Text, m.IsEnabled), MenuFlyoutSubItem s => (s.Text, s.IsEnabled), _ => ((string?)null, false) })
            .Where(e => e.Item1 != null).Select(e => (e.Item1!, e.Item2)).ToList();
        if (GroupManageWalkProof.RowMenu(entries) is { } menuWrong) throw new InvalidOperationException(menuWrong);
        await Task.Delay(400);
        await shot("group-row-menu");

        // Group Info from the menu.
        try { Mouse.Click(info); }
        catch (InvalidOperationException e) { AppLog.Note("automation", $"walk group-manage: Group Info wasn't clicked ({e.Message}); invoking it"); Invoke(info); }
        var sheet = await Until(() => GroupManageFeature.InfoDialog is { IsLoaded: true } d ? d : null, "Group Info", 15);
        await Until(() => FindIn(sheet, "group-info.name"), "Group Info's name");
        var members = Shown(sheet).Select(Id).Where(id => id.StartsWith("group-info.member.", StringComparison.Ordinal))
            .Select(id => id["group-info.member.".Length..]).ToList();
        if (GroupManageWalkProof.Info(sheet.Title as string, (FindIn(sheet, "group-info.name") as TextBlock)?.Text,
                (FindIn(sheet, "group-info.subtitle") as TextBlock)?.Text, members) is { } infoWrong)
            throw new InvalidOperationException(infoWrong);
        await Task.Delay(400);
        await shot("group-info");

        // [WIN-51] Each member with its face beside the name (GroupInfoView.memberRow's HeadImage).
        var faces = Shown(sheet).Where(e => Id(e).StartsWith("group-info.member.", StringComparison.Ordinal))
            .Select(e => (Id(e)["group-info.member.".Length..], Shown(e).OfType<BotHead>().Any(h => h.ActualWidth >= 32 && h.Children.Count > 0))).ToList();
        if (GroupManageWalkProof.Faces(faces) is { } facesWrong) throw new InvalidOperationException(facesWrong);
        if (FindIn(sheet, "group-info.member.ivy") is { } firstMember) firstMember.StartBringIntoView();
        await Task.Delay(400);
        await shot("group-info-faces");

        // Edit Bots: the picker in edit mode.
        var tile = Need(sheet, "group-info.tile.add");
        try { Mouse.Click(tile); }
        catch (InvalidOperationException e) { AppLog.Note("automation", $"walk group-manage: Edit Bots wasn't clicked ({e.Message}); invoking it"); Invoke(tile); }
        var picker = await Until(() => GroupManageFeature.PickerDialog is { IsLoaded: true } d ? d : null, "the bots picker", 15);
        await Until(() => FindIn(picker, "group-picker.bot.ivy"), "the picker's bots");
        var bots = Shown(picker).OfType<CheckBox>().Where(b => Id(b).StartsWith("group-picker.bot.", StringComparison.Ordinal))
            .Select(b => (Id(b)["group-picker.bot.".Length..], b.IsChecked == true, b.IsEnabled)).ToList();
        if (GroupManageWalkProof.Picker(picker.Title as string, (FindIn(picker, "group-picker.line") as TextBlock)?.Text, bots,
                (FindIn(picker, "group-picker.footer") as TextBlock)?.Text) is { } pickWrong)
            throw new InvalidOperationException(pickWrong);
        await Task.Delay(400);
        await shot("group-bots-picker");

        // Cancel: back to Group Info; Done closes it.
        picker.Hide();
        var again = await Until(() => GroupManageFeature.InfoDialog is { IsLoaded: true } d && d != sheet ? d : null, "Group Info again", 15);

        // [WIN-51] Name & Photo: a synthetic picture through the picked photo's path (square crop, JPEG under the
        // mirror's limit), shown in the page's avatar with Remove Photo and Save on; Remove Photo, then Cancel: no write.
        var namePhoto = Need(again, "group-info.name-photo");
        namePhoto.StartBringIntoView();
        await Task.Delay(400);
        try { Mouse.Click(namePhoto); }
        catch (InvalidOperationException e) { AppLog.Note("automation", $"walk group-manage: Name & Photo wasn't clicked ({e.Message}); invoking it"); Invoke(namePhoto); }
        var page = await Until(() => GroupManageFeature.NamePhotoDialog is { IsLoaded: true } d ? d : null, "Name & Photo", 15);
        await Until(() => FindIn(page, "group-settings.name"), "Name & Photo's name field");
        string? PageWrong(bool hasPhoto) => GroupManageWalkProof.NamePhoto(page.Title as string, (FindIn(page, "group-settings.intro") as TextBlock)?.Text,
            (FindIn(page, "group-settings.name") as TextBox)?.Text, hasPhoto,
            [.. Shown(page).OfType<Button>().Where(b => Id(b).StartsWith("group-settings.", StringComparison.Ordinal)).Select(b => b.Content as string ?? "")],
            page.IsPrimaryButtonEnabled);
        if (PageWrong(hasPhoto: false) is { } bareWrong) throw new InvalidOperationException(bareWrong);
        string? url;
        using (var picture = await GroupPhotoImaging.SyntheticPngAsync(640, 400)) url = await GroupPhotoImaging.DataUrlAsync(picture);
        if (url == null || !url.StartsWith(GroupPhoto.Prefix, StringComparison.Ordinal) || url.Length > GroupLimits.SyncImage)
            throw new InvalidOperationException($"the synthetic picture made no room photo ({url?.Length ?? 0} characters)");
        AppLog.Note("automation", $"walk group-manage: the synthetic picture is a {url.Length}-character photo");
        (GroupManageFeature.NamePhotoSetImage ?? throw new InvalidOperationException("Name & Photo takes no photo"))(url);
        await Until(() => FindIn(page, "group-settings.remove-photo"), "Remove Photo");
        await Until(() => FindIn(page, "group-settings.photo") is { } a && Shown(a).OfType<Microsoft.UI.Xaml.Shapes.Ellipse>().Any(e => e.Fill is ImageBrush) ? a : null,
            "the photo in Name & Photo's avatar");
        if (PageWrong(hasPhoto: true) is { } photoWrong) throw new InvalidOperationException(photoWrong);
        await Task.Delay(400);
        await shot("group-photo");
        var removePhoto = Need(page, "group-settings.remove-photo");
        try { Mouse.Click(removePhoto); }
        catch (InvalidOperationException e) { AppLog.Note("automation", $"walk group-manage: Remove Photo wasn't clicked ({e.Message}); invoking it"); Invoke(removePhoto); }
        await Until(() => FindIn(page, "group-settings.remove-photo") == null ? page : null, "Remove Photo to go");
        if (PageWrong(hasPhoto: false) is { } removedWrong) throw new InvalidOperationException(removedWrong);
        page.Hide();
        if (ListsHub.Current?.Groups.Room(key)?.Image != null) throw new InvalidOperationException("Name & Photo wrote a photo");
        var before = again;
        again = await Until(() => GroupManageFeature.InfoDialog is { IsLoaded: true } d && d != sheet && d != before ? d : null, "Group Info after Name & Photo", 15);
        again.Hide();
        await Until(() => GroupManageFeature.InfoDialog == null ? shell : null, "Group Info to close", 10);
        await Task.Delay(400);
        await shot("group-manage");
    }

    /// The row's container that carries its right-click menu.
    private static FrameworkElement? Holder(DependencyObject? node)
    {
        for (; node != null; node = VisualTreeHelper.GetParent(node))
            if (node is FrameworkElement { ContextFlyout: not null } e) return e;
        return null;
    }
}
