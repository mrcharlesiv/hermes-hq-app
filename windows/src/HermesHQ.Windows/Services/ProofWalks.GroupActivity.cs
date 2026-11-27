using Hermes.Core.Shell;
using HermesHQ.Features.Bots;
using HermesHQ.Features.Groups;
using HermesHQ.Pages;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Services;

/// [WIN-57] The CI's walk for a room's Activity, its ⋯ menu, its empty view and its moving typing dots
/// (windows/ci/windows.yml asks for it on its own stand-in, settings-gateway.py --group-rooms --quiet-room), backed by
/// `Hermes.Core.Shell.GroupActivityWalkProof`:
///   group-room-activity  Quiet Room (nothing said yet) opened from its sidebar row: the empty room, its name, Ivy and
///                        Research, the hint ("group-room-empty"); ⋯ › Activity there: titled Activity, "No activity in
///                        this turn yet." ("group-room-activity-empty"), Esc closes it. Launch Room, a synthetic line
///                        sent: while its round runs the typing row's three dots each run their wave and move (or stand
///                        still when the desktop's animations are off, said in the log). After the round, the room's ⋯:
///                        Find in Chat, Group Info, Activity, Delete Group Chat in that order ("group-room-menu"); its
///                        Activity: newest first down to "You sent a message", each row timed ("group-room-activity");
///                        Esc closes it.
/// Keys and clicks go in by SendInput; where they don't arrive, the walk does what they do and says so in the app log.
internal static partial class ProofWalks
{
    private static void RegisterGroupActivityWalks()
    {
        Automation.NamedWalks["group-room-activity"] = GroupActivityAsync;
    }

    private static async Task GroupActivityAsync(Func<string, Task> shot)
    {
        if (AppState.Client == null) throw new InvalidOperationException("not signed in");
        var shell = ShellPage.Current ?? throw new InvalidOperationException("the shell isn't showing");
        await Until(() => Find(SidebarSearch.ToolsAutomationId), "the sidebar");
        if (Find(SidebarSearch.ToolsAutomationId) is not Grid) await FoldAsync(shell, fold: false);
        var hub = await Until(() => ListsHub.Current is { } h && h.Groups.Room(GroupActivityWalkProof.QuietKey) != null && h.Groups.Room(GroupActivityWalkProof.LaunchKey) != null ? h : null,
            "Quiet Room and Launch Room in the group chats", 30);

        // Quiet Room: the empty room, then its empty Activity.
        var quiet = await OpenRoomAsync(GroupActivityWalkProof.QuietKey);
        await Until(() => quiet.EmptyShown && quiet.EmptyName.Length > 0 ? quiet : null, "Quiet Room's empty view", 10);
        if (GroupActivityWalkProof.EmptyRoom(quiet.EmptyShown, quiet.EmptyName, quiet.EmptyMembers, quiet.EmptyHint) is { } emptyWrong) throw new InvalidOperationException(emptyWrong);
        await Task.Delay(500);
        await shot("group-room-empty");
        await OpenActivityAsync(quiet, shootMenu: false);
        var emptyBy = DateTime.UtcNow.AddSeconds(10);
        while (GroupActivityWalkProof.EmptyActivity(GroupActivityDialog.ShownTitle, Shown(), GroupActivityDialog.ShownEmpty) != null && DateTime.UtcNow < emptyBy) await Task.Delay(100);
        if (GroupActivityWalkProof.EmptyActivity(GroupActivityDialog.ShownTitle, Shown(), GroupActivityDialog.ShownEmpty) is { } emptyActivityWrong) throw new InvalidOperationException(emptyActivityWrong);
        await Task.Delay(500);
        await shot("group-room-activity-empty");
        await CloseActivityAsync();

        // Launch Room: a line sent, the dots while the round runs.
        var launch = await OpenRoomAsync(GroupActivityWalkProof.LaunchKey);
        AppLog.Note("automation", "walk group-room-activity: sending the walk's line as Enter does (the group-room walk proves the keys)");
        launch.AutomationSend(GroupActivityWalkProof.Line);
        await Until(() => launch.ShownTyping.Count > 0 ? launch : null, "a typing row while the round runs", 15);
        var first = launch.DotsNow();
        await Task.Delay(300);
        var second = launch.DotsNow();
        // The first typing row's three dots: each one's wave running (false where it has none) and its clock at two looks.
        var perRow = Hermes.Core.Groups.TypingDots.Count;
        if (launch.DotsShown < perRow) throw new InvalidOperationException($"the typing row shows {launch.DotsShown} dots");
        List<T> Dots<T>(IReadOnlyList<T> seen, T none) => [.. Enumerable.Range(0, perRow).Select(i => i < seen.Count ? seen[i] : none)];
        if (GroupActivityWalkProof.DotsMoving(first.Animations, Dots(second.Running, false), Dots(first.Times, 0.0), Dots(second.Times, 0.0)) is { } dotsWrong)
            throw new InvalidOperationException(dotsWrong);
        AppLog.Note("automation", first.Animations
            ? $"walk group-room-activity: the typing dots move ({string.Join(", ", first.Times.Take(perRow).Zip(second.Times.Take(perRow)).Select(p => $"{p.First:0.00}→{p.Second:0.00}s"))})"
            : "walk group-room-activity: Windows' animations are off on this desktop: the typing dots stand still at 60 %");
        var until = DateTime.UtcNow.AddSeconds(60);
        while (launch.RoomRunning && DateTime.UtcNow < until) await Task.Delay(250);
        if (launch.RoomRunning) throw new InvalidOperationException("the round didn't settle");

        // The room's ⋯, then its Activity.
        if (GroupActivityWalkProof.Menu(launch.MoreIds()) is { } menuWrong) throw new InvalidOperationException(menuWrong);
        await OpenActivityAsync(launch, shootMenu: true);
        var rowsBy = DateTime.UtcNow.AddSeconds(10);
        while (GroupActivityWalkProof.Activity(GroupActivityDialog.ShownTitle, Shown(), GroupActivityDialog.ShownEmpty != null) != null && DateTime.UtcNow < rowsBy) await Task.Delay(100);
        if (GroupActivityWalkProof.Activity(GroupActivityDialog.ShownTitle, Shown(), GroupActivityDialog.ShownEmpty != null) is { } activityWrong) throw new InvalidOperationException(activityWrong);
        AppLog.Note("automation", $"walk group-room-activity: Activity shows {GroupActivityDialog.ShownRows.Count} rows, newest first");
        await Task.Delay(500);
        await shot("group-room-activity");
        await CloseActivityAsync();

        static List<(string Text, string Time)> Shown() => [.. GroupActivityDialog.ShownRows.Select(r => (r.Text, r.Time))];

        async Task<GroupRoomPage> OpenRoomAsync(string key)
        {
            var row = (FrameworkElement)await Until(() => Find("sidebar.room." + key), $"{key}'s sidebar row");
            await Task.Delay(300);
            row = Find("sidebar.room." + key) ?? row;
            try
            {
                Mouse.Click(row);
                AppLog.Note("automation", $"walk group-room-activity: {key}'s row clicked by pointer");
            }
            catch (InvalidOperationException e)
            {
                AppLog.Note("automation", $"walk group-room-activity: {key}'s row wasn't clicked ({e.Message}); opening the room as the click does");
                Navigator.Go(new RoomDestination(key));
            }
            return await Until(() => GroupRoomPage.Current is { IsLoaded: true } p && p.RoomKey == key ? p : null, $"{key}'s chat", 20);
        }

        async Task OpenActivityAsync(GroupRoomPage page, bool shootMenu)
        {
            var more = Need(page, GroupRoomPage.MoreId);
            try
            {
                Mouse.Click(more);
                var item = await Until(() => MenuItem("Activity"), "Activity in the room's ⋯", 10);
                if (shootMenu)
                {
                    await Task.Delay(400);   // the menu's open transition settles before the picture
                    await shot("group-room-menu");
                }
                Mouse.Click(item);
                AppLog.Note("automation", "walk group-room-activity: ⋯ › Activity clicked by pointer");
            }
            catch (Exception e) when (e is InvalidOperationException or TimeoutException)
            {
                if (shootMenu) throw;   // the menu's picture is the point: no stand-in for it
                AppLog.Note("automation", $"walk group-room-activity: ⋯ › Activity wasn't clicked ({e.Message}); opening it as it does");
                page.CloseMore();
                page.AutomationActivity();
            }
            var openBy = DateTime.UtcNow.AddSeconds(10);
            while (GroupActivityDialog.Current == null && DateTime.UtcNow < openBy) await Task.Delay(100);
            if (GroupActivityDialog.Current == null)
            {
                AppLog.Note("automation", "walk group-room-activity: the click didn't open Activity; opening it as the item does");
                page.CloseMore();
                page.AutomationActivity();
            }
            await Until(() => GroupActivityDialog.Current, "the Activity sheet", 10);
        }

        async Task CloseActivityAsync()
        {
            if (!await KeysAsync(() => Keys.Press(Keys.Escape), () => GroupActivityDialog.Current == null, "Esc on Activity"))
            {
                AppLog.Note("automation", "walk group-room-activity: Esc unproven by keyboard; closing Activity as Esc does");
                GroupActivityDialog.Close();
            }
            await Until(() => GroupActivityDialog.Current == null ? shell : null, "the Activity sheet to close", 10);
        }
    }
}
