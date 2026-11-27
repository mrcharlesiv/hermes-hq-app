using Hermes.Core.Bots;
using Hermes.Core.Groups;
using Hermes.Core.Shell;
using HermesHQ.Features.Bots;
using HermesHQ.Pages;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Services;

/// [WIN-41] The CI's walk for an open group chat (windows/ci/windows.yml asks for it on the groups stand-in,
/// settings-gateway.py --group-rooms), backed by the app's state (`Hermes.Core.Shell.GroupRoomWalkProof`):
///   group-room  Launch Room marked unread, a click on its sidebar row: the room's chat in the pane, its row marked, the
///               title "Launch Room" with Ivy's and Research's faces, the row read (no bold, no dot) ("group-room-open").
///               A synthetic line typed and Enter: Ivy's and Research's replies under it, each under its own name
///               ("group-room-replies"). A second line, and the composer's Stop square clicked while its round runs: the
///               room's Activity says Stopped before the round's end, the room no longer runs, the button is Send again
///               ("group-room").
///               [WIN-52] While that second round runs, the typing row at the transcript's end names the member answering and
///               wears its face ("group-room-typing"); after Stop, ⋯ › Find in Chat finds "noted" in the members' replies
///               and counts them in the chat's own bar ("group-room-find").
/// Keys and clicks go in by SendInput; where they don't arrive, the walk does what they do and says so in the app log.
internal static partial class ProofWalks
{
    private static void RegisterGroupRoomWalks()
    {
        Automation.NamedWalks["group-room"] = GroupRoomAsync;
    }

    /// A sidebar row once it is laid out: below the sidebar's tools (Search and New Chat) and in the same box on two
    /// reads 150 ms apart, re-found each time (the sidebar may swap the row while it redraws).
    private static async Task<FrameworkElement> LaidOutRowAsync(string id, string what)
    {
        WalkProof.Box? last = null;
        var until = DateTime.UtcNow.AddSeconds(10);
        while (DateTime.UtcNow < until)
        {
            WalkProof.Box? box = null;
            if (Find(id) is { ActualWidth: > 0, ActualHeight: > 0 } row && Find(SidebarSearch.ToolsAutomationId) is { } tools)
            {
                var b = BoxOf(row);
                var t = BoxOf(tools);
                if (b.Y >= t.Y + t.Height) box = b;
                if (box != null && box == last)
                {
                    AppLog.Note("automation", $"walk pointer: {what} laid out at ({b.X:0},{b.Y:0}) {b.Width:0}x{b.Height:0}, under the tools at y {t.Y + t.Height:0}");
                    return row;
                }
            }
            last = box;
            await Task.Delay(150);
        }
        throw new TimeoutException($"waited too long for {what} to be laid out under the sidebar's tools (last {last?.ToString() ?? "none"})");
    }

    private static async Task GroupRoomAsync(Func<string, Task> shot)
    {
        if (AppState.Client == null) throw new InvalidOperationException("not signed in");
        var shell = ShellPage.Current ?? throw new InvalidOperationException("the shell isn't showing");
        const string key = GroupRoomWalkProof.LaunchKey;
        await Until(() => Find(SidebarSearch.ToolsAutomationId), "the sidebar");
        if (Find(SidebarSearch.ToolsAutomationId) is not Grid) await FoldAsync(shell, fold: false);
        var hub = await Until(() => ListsHub.Current is { } h && h.Groups.Room(key) != null ? h : null, "Launch Room in the group chats", 30);
        GroupRowModel? Row() => hub.Groups.Rows().FirstOrDefault(r => r.Id == key);

        // Off the room (an earlier walk may have left it open), then Launch Room unread: its row bold with the dot.
        if (GroupRoomPage.Current != null)
        {
            Navigator.Open("sessions");
            await Until(() => GroupRoomPage.Current == null ? shell : null, "the room to leave the pane");
        }
        hub.Groups.SetUnread(key, true);
        await Until(() => Row() is { Unread: true } ? shell : null, "Launch Room's row unread");
        await Until(() => Find("sidebar.room." + key), "Launch Room's row");
        await Task.Delay(500);   // the sidebar's redraw of the unread row settles
        // Aimed only once the row is laid out where the open sidebar draws it: under the sidebar's tools, the same box
        // twice running. CI run 45095225249 read its box while the sidebar was opening again from the rail (the tools
        // already a Grid, the rows not yet arranged) and the click landed on the title bar at (44,15).
        var launch = await LaidOutRowAsync("sidebar.room." + key, "Launch Room's row");
        try
        {
            Mouse.Click(launch);
            AppLog.Note("automation", "walk group-room: Launch Room's row clicked by pointer");
        }
        catch (InvalidOperationException e)
        {
            AppLog.Note("automation", $"walk group-room: the row wasn't clicked ({e.Message}); opening the room as the click does");
            Navigator.Go(new RoomDestination(key));
        }
        var page = await Until(() => GroupRoomPage.Current is { IsLoaded: true } p && p.RoomKey == key ? p : null, "Launch Room's chat", 20);
        if (shell.MarkedKey != BotListHead.RoomKey(key)) throw new InvalidOperationException($"the sidebar marks {shell.MarkedKey}, not the room");
        await Until(() => Row() is { Unread: false } ? page : null, "Launch Room's row read");
        if (GroupRoomWalkProof.Opened(page.ShownTitle, page.ShownFaces, Row()?.Unread ?? true) is { } openWrong) throw new InvalidOperationException(openWrong);
        await Task.Delay(500);   // the sidebar row without its dot and the room's rows settle before the picture
        await shot("group-room-open");

        // A synthetic line: both members answer under their own names.
        var box = (TextBox)await Until(() => FindIn(page, "chat.composer"), "the room's message box");
        box.Focus(FocusState.Keyboard);
        const string line = GroupRoomWalkProof.Line;
        if (!await KeysAsync(() => Keys.Type(line), () => box.Text == line, "typing"))
        {
            box.Text = line;   // a WinUI TextBox's peer gives no managed Value pattern
            box.SelectionStart = line.Length;
        }
        if (box.Text != line) throw new InvalidOperationException($"the box reads \"{box.Text}\"");
        if (!await KeysAsync(() => Keys.Press(Keys.Enter), () => box.Text.Length == 0, "Enter"))
        {
            AppLog.Note("automation", "walk group-room: Enter unproven by keyboard; sending as Enter does");
            page.AutomationSend(line);
        }
        var until = DateTime.UtcNow.AddSeconds(60);
        string? why;
        while (((why = GroupRoomWalkProof.Replies(page.ShownRows())) != null || page.RoomRunning) && DateTime.UtcNow < until) await Task.Delay(250);
        if (why != null) throw new InvalidOperationException(why);
        if (page.RoomRunning) throw new InvalidOperationException("the round didn't settle");
        await Task.Delay(500);
        await shot("group-room-replies");

        // Stop mid-round: a second line, and the Stop square clicked while the round runs. Each member's turn takes 6 s on
        // the stand-in for this round (POST /__settings/turn): at its usual half second the round could end during the
        // typing shot, before the click (CI run 45034520666: "the round was not stopped (… Passed, Settled)").
        var standIn = AppState.Client.Session.Address.ToString();
        await StandInPost(standIn, "/__settings/turn", new System.Text.Json.Nodes.JsonObject { ["seconds"] = 6 });
        try { await StopMidRoundAsync(page, hub, key, shot); }
        finally { await StandInPost(standIn, "/__settings/turn", new System.Text.Json.Nodes.JsonObject { ["seconds"] = 0 }); }
    }

    private static async Task StopMidRoundAsync(GroupRoomPage page, ListsHub hub, string key, Func<string, Task> shot)
    {
        page.AutomationSend(GroupRoomWalkProof.StopLine);
        await Until(() => page.StopShown ? page : null, "the Stop square while the round runs", 10);
        await Until(() => GroupRoomWalkProof.Typing(page.ShownTyping) == null ? page : null, "a member's typing row with its face", 10);
        await shot("group-room-typing");
        var stop = Need(page, "chat.send");
        try
        {
            Mouse.Click(stop);
            AppLog.Note("automation", "walk group-room: Stop clicked by pointer");
        }
        catch (InvalidOperationException e)
        {
            AppLog.Note("automation", $"walk group-room: Stop wasn't clicked ({e.Message}); invoking it");
            Invoke(stop);
        }
        var stoppedBy = DateTime.UtcNow.AddSeconds(10);
        while (!hub.Groups.Activity(key).Any(a => a.Kind == GroupActivityKind.Stopped) && page.StopShown && DateTime.UtcNow < stoppedBy) await Task.Delay(100);
        if (!hub.Groups.Activity(key).Any(a => a.Kind == GroupActivityKind.Stopped) && page.StopShown)
        {
            AppLog.Note("automation", "walk group-room: the click didn't stop the round; invoking Stop");
            Invoke(stop);
        }
        await Until(() => !page.RoomRunning && !page.StopShown ? page : null, "the round to stop", 15);
        var activity = hub.Groups.Activity(key).Select(a => a.Kind).ToList();
        var queued = activity.LastIndexOf(GroupActivityKind.Queued);
        if (GroupRoomWalkProof.StoppedMidRound(activity.Skip(Math.Max(0, queued)).ToList(), page.RoomRunning, page.StopShown) is { } stopWrong)
            throw new InvalidOperationException(stopWrong);
        AppLog.Note("automation", "walk group-room: stopped mid-round");
        await Task.Delay(500);
        await shot("group-room");   // after Stop: the composer's Send again

        // ⋯ › Find in Chat: the chat's own bar over the room's transcript, the members' replies found and counted.
        if (!page.MoreIds().Contains("room.more.find")) throw new InvalidOperationException($"the room's ⋯ has {string.Join(", ", page.MoreIds())}");
        var roomTranscript = (Control)Need(page, "chat.transcript");
        var originalRoomPadding = roomTranscript.Padding;
        var more = Need(page, GroupRoomPage.MoreId);
        try
        {
            Mouse.Click(more);
            var find = await Until(() => MenuItem("Find in Chat"), "Find in Chat in the room's ⋯", 10);
            Mouse.Click(find);
            AppLog.Note("automation", "walk group-room: ⋯ › Find in Chat clicked by pointer");
        }
        catch (Exception e) when (e is InvalidOperationException or TimeoutException)
        {
            AppLog.Note("automation", $"walk group-room: ⋯ › Find in Chat wasn't clicked ({e.Message}); opening Find as it does");
            page.CloseMore();
            page.AutomationFindInChat();
        }
        var bar = await Until(() => page.FindBar is { IsOpen: true } b ? b : null, "Find over the room", 10);
        bar.AutomationFind(GroupRoomWalkProof.FindQuery);
        var foundBy = DateTime.UtcNow.AddSeconds(10);
        while (GroupRoomWalkProof.Found(bar.CountText, bar.MatchCount) != null && DateTime.UtcNow < foundBy) await Task.Delay(100);
        if (GroupRoomWalkProof.Found(bar.CountText, bar.MatchCount) is { } findWrong) throw new InvalidOperationException(findWrong);
        await Task.Delay(500);   // the highlights paint before the picture
        await shot("group-room-find");
        await FindReflowAsync(roomTranscript, originalRoomPadding, Need(page, "chatfind.bar"), (TextBox)Need(page, "chatfind.field"), shot, "group-room-find");
        bar.Close();
        if (!roomTranscript.Padding.Equals(originalRoomPadding)) throw new InvalidOperationException("Find did not restore the room's transcript");
        // The room's box takes the keyboard back, so Find's rest element must not stay behind as an invisible tab stop.
        await Task.Delay(300);
        if (HermesHQ.Features.ChatFind.ChatFindBar.StrayRests(page) is var stray and > 0)
            throw new InvalidOperationException($"after Find closed in the room {stray} invisible Find rest element(s) are still tab stops");
        AppLog.Note("automation", "walk group-room: Find closed, no stray tab stop");
    }
}
