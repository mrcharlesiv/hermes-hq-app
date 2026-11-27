using Hermes.Core.Shell;
using HermesHQ.Features.Bots;
using HermesHQ.Pages;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.System;

namespace HermesHQ.Services;

/// [WIN-59] The CI's walk for a room's @ list (windows/ci/windows.yml asks for it on its own stand-in,
/// settings-gateway.py --group-rooms), backed by `Hermes.Core.Shell.GroupMentionsWalkProof`:
///   group-mentions  Launch Room opened from its sidebar row; "@Re" typed in its box: the @ list above the box offers
///                   Research alone, its face and "@research" under its name ("group-mention-drawer"). ↓ marks it (drawn
///                   in the window's selection), Return picks it: the box reads "@research ", the caret after it, the list
///                   closed ("group-mention-picked"). "@Re" again and Esc: the list closes with the words kept, and the
///                   next letter opens it again. "@Re" again and Tab (nothing marked): the first row, "@research " again.
///                   The rest typed and Return: the round asks Research alone (the room's Activity since the send names
///                   no one else) and only Research answers under the line ("group-mentions").
/// The list's keys go through the page's own key handling (GroupRoomPage.AutomationKey), never an injected key; the
/// letters go in by SendInput, and where they don't arrive the walk types them as the box does and says so in the log.
internal static partial class ProofWalks
{
    private static void RegisterGroupMentionsWalks()
    {
        Automation.NamedWalks["group-mentions"] = GroupMentionsAsync;
    }

    private static async Task GroupMentionsAsync(Func<string, Task> shot)
    {
        if (AppState.Client == null) throw new InvalidOperationException("not signed in");
        var shell = ShellPage.Current ?? throw new InvalidOperationException("the shell isn't showing");
        const string key = GroupMentionsWalkProof.LaunchKey;
        await Until(() => Find(SidebarSearch.ToolsAutomationId), "the sidebar");
        if (Find(SidebarSearch.ToolsAutomationId) is not Grid) await FoldAsync(shell, fold: false);
        var hub = await Until(() => ListsHub.Current is { } h && h.Groups.Room(key) != null ? h : null, "Launch Room in the group chats", 30);

        // Launch Room, from its sidebar row.
        var row = (FrameworkElement)await Until(() => Find("sidebar.room." + key), "Launch Room's row");
        await Task.Delay(300);
        row = Find("sidebar.room." + key) ?? row;
        try
        {
            Mouse.Click(row);
            AppLog.Note("automation", "walk group-mentions: Launch Room's row clicked by pointer");
        }
        catch (InvalidOperationException e)
        {
            AppLog.Note("automation", $"walk group-mentions: the row wasn't clicked ({e.Message}); opening the room as the click does");
            Navigator.Go(new RoomDestination(key));
        }
        var page = await Until(() => GroupRoomPage.Current is { IsLoaded: true } p && p.RoomKey == key ? p : null, "Launch Room's chat", 20);
        var box = (TextBox)await Until(() => FindIn(page, "chat.composer"), "the room's message box");
        if (box.Text.Length > 0) await ClearAsync();

        // "@Re": the list with Research alone.
        await TypeAsync(GroupMentionsWalkProof.Typed);
        var drawerBy = DateTime.UtcNow.AddSeconds(10);
        while (GroupMentionsWalkProof.Drawer(page.MentionsOpen, page.MentionRows, page.MentionFaces) != null && DateTime.UtcNow < drawerBy) await Task.Delay(100);
        if (GroupMentionsWalkProof.Drawer(page.MentionsOpen, page.MentionRows, page.MentionFaces) is { } drawerWrong) throw new InvalidOperationException(drawerWrong);
        await Task.Delay(400);
        await shot("group-mention-drawer");

        // ↓ marks it; Return picks it.
        if (!page.AutomationKey(VirtualKey.Down)) throw new InvalidOperationException("the page didn't take ↓ with the @ list open");
        if (GroupMentionsWalkProof.Marked(page.MentionMarked, page.MentionRows, page.MentionMarkedDrawn) is { } markWrong) throw new InvalidOperationException(markWrong);
        if (!page.AutomationKey(VirtualKey.Enter)) throw new InvalidOperationException("the page didn't take Return with a row marked");
        await PickedAsync("Return");
        await Task.Delay(400);
        await shot("group-mention-picked");

        // Esc closes it, keeping the words; the next letter opens it again.
        await ClearAsync();
        await TypeAsync(GroupMentionsWalkProof.Typed);
        await Until(() => page.MentionsOpen ? page : null, "the @ list again", 10);
        if (!page.AutomationKey(VirtualKey.Escape)) throw new InvalidOperationException("the page didn't take Esc with the @ list open");
        await Task.Delay(300);   // a late TextChanged must not open it again
        var escText = box.Text;
        var openAfterEsc = page.MentionsOpen;
        page.AutomationType("s");
        var openBy = DateTime.UtcNow.AddSeconds(10);
        while (!page.MentionsOpen && DateTime.UtcNow < openBy) await Task.Delay(100);
        if (GroupMentionsWalkProof.Escaped(escText, openAfterEsc, page.MentionsOpen) is { } escWrong) throw new InvalidOperationException(escWrong);
        AppLog.Note("automation", "walk group-mentions: Esc closed the @ list; typing opened it again");

        // Tab with nothing marked picks the first row.
        await ClearAsync();
        await TypeAsync(GroupMentionsWalkProof.Typed);
        await Until(() => page.MentionsOpen && page.MentionRows.Count > 0 ? page : null, "the @ list for Tab", 10);
        if (!page.AutomationKey(VirtualKey.Tab)) throw new InvalidOperationException("the page didn't take Tab with the @ list open");
        await PickedAsync("Tab");

        // The rest, and Return: the round asks Research alone.
        await TypeAsync(GroupMentionsWalkProof.Rest, expected: GroupMentionsWalkProof.Line);
        if (page.MentionsOpen) throw new InvalidOperationException("the @ list shows over a finished tag");
        if (!page.AutomationKey(VirtualKey.Enter)) throw new InvalidOperationException("the page didn't take Return to send");
        List<(Hermes.Core.Groups.GroupActivityKind, string)> Since()
        {
            var all = hub.Groups.Activity(key).Select(a => (a.Kind, a.Member)).ToList();
            var queued = all.FindLastIndex(a => a.Kind == Hermes.Core.Groups.GroupActivityKind.Queued);
            return [.. all.Skip(Math.Max(0, queued))];
        }
        var until = DateTime.UtcNow.AddSeconds(60);
        string? why;
        while (((why = GroupMentionsWalkProof.Addressed(Since(), page.ShownRows())) != null || page.RoomRunning) && DateTime.UtcNow < until) await Task.Delay(250);
        if (why != null) throw new InvalidOperationException(why);
        if (page.RoomRunning) throw new InvalidOperationException("the round didn't settle");
        AppLog.Note("automation", $"walk group-mentions: the line asked {string.Join(", ", Since().Where(a => a.Item2.Length > 0).Select(a => a.Item2).Distinct())}");
        await Task.Delay(500);   // Research's reply settles before the picture
        await shot("group-mentions");

        async Task TypeAsync(string words, string? expected = null)
        {
            var want = expected ?? box.Text + words;
            box.Focus(FocusState.Keyboard);
            box.SelectionStart = box.Text.Length;
            if (!await KeysAsync(() => Keys.Type(words), () => box.Text == want, "typing"))
            {
                if (box.Text != want && want.StartsWith(box.Text, StringComparison.Ordinal)) page.AutomationType(want[box.Text.Length..]);
            }
            if (box.Text != want) throw new InvalidOperationException($"the box reads \"{box.Text}\", not \"{want}\"");
        }

        async Task ClearAsync()
        {
            box.Text = "";
            await Until(() => box.Text.Length == 0 && !page.MentionsOpen ? page : null, "the box and the @ list to clear", 10);
        }

        async Task PickedAsync(string how)
        {
            var by = DateTime.UtcNow.AddSeconds(10);
            while (GroupMentionsWalkProof.AfterPick(box.Text, page.ComposerCaret, page.MentionsOpen) != null && DateTime.UtcNow < by) await Task.Delay(100);
            if (GroupMentionsWalkProof.AfterPick(box.Text, page.ComposerCaret, page.MentionsOpen) is { } pickWrong) throw new InvalidOperationException($"{how}: {pickWrong}");
            AppLog.Note("automation", $"walk group-mentions: {how} picked Research");
        }
    }
}
