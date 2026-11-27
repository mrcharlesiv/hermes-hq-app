using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using Hermes.Core;
using Hermes.Core.Shell;
using Hermes.Core.BotPages;
using Hermes.Core.Tasks;
using HermesHQ.Features.Bots;
using Hermes.Core.Settings;
using HermesHQ.Features.OpenQuickly;
using HermesHQ.Features.Shortcuts;
using HermesHQ.Features.Transcript;
using HermesHQ.Pages;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using ChatFindText = Hermes.Core.Transcripts.ChatFind;
using OpenQuicklyText = Hermes.Core.Shell.OpenQuickly;
using SettingsWindow = HermesHQ.Features.Settings.SettingsWindow;

namespace HermesHQ.Services;

/// The CI's pictures of integrated features (Services/Automation.cs named walks; windows/ci/windows.yml asks for them on
/// the composer, settings and tasks stand-ins), each backed by the app's real state and, where something goes over the
/// wire, the stand-in's own record (`Hermes.Core.Shell.WalkProof`):
///   new-chat-draft            "/new draft words" typed in a chat and Enter: a new chat in its place with "draft words" in
///                             its box, and the stand-in made one chat and took no prompt (NewChatCommand; the Mac's
///                             `AppModel.openNewChat`).
///   new-chat-bare             "/new" typed in the bot's chat: Enter picks /new in the drawer ("/new " in the box, nothing
///                             sent), Enter again: a new chat titled New Chat in its place, its box empty, one chat made
///                             and no prompt (the Mac's `openNewChat` with no words).
///   settings-auto-archive-on  Settings › Archiving & Project Folder: Auto-Archive Stale Chats on, Archive After 14, the
///                             debounce, and the stand-in's PUT /api/config holding sessions.auto_archive true and 14 days.
///   shortcuts-sheet           Ctrl+/ shows `shortcuts.sheet`; Esc closes it.
///   open-quickly              Ctrl+K: Recent; a bot's name typed (its row marked, the groups' headings); ↓ moves the mark,
///                             Enter opens that row. Find Default Project Folder and open its Settings page; then
///                             Ctrl+K, "zzqx": the no-results words; Esc.
///   chat-find                 Ctrl+F in Trip planning, "food" typed: "2 of 2" (the newest), F3 "1 of 2", F3 "2 of 2";
///                             Shift+F3 "1 of 2", Ctrl+Shift+G "2 of 2" (wraps). Esc closes the bar: no highlights left,
///                             the keyboard in neither the box nor the field (the Mac's nothing-focused,
///                             "chat-find-closed"); X then lands "x" in the box, which has the keyboard (type-to-chat).
///   type-to-chat              The transcript focused, H and I pressed: the message box has the keyboard and reads "hi".
///   tasks-sort-select         Tasks › Home, ⋯ › Sort By › Due Date by keyboard: the rows in due order and the stand-in's
///                             PUT /tasks/settings with sort "due"; ⋯ › Select Tasks, two rows clicked and picked; Esc
///                             keeps Select and both picks; Done ends it.
///   sidebar-search            A pointer click on the sidebar's Search: Open Quickly up, Esc closes it; Ctrl+Shift+S folds
///                             the sidebar (Search and New Chat side by side in the rail); a click on the rail's Search
///                             opens Open Quickly with the sidebar still folded; Esc, Ctrl+Shift+S opens it again
///                             (SidebarTools; the Mac's MacSidebarTools).
///   about-licenses            Settings › About; a click on Open-Source Licenses (Hermes first, every notice) and on
///                             Hermes's row: its text, reflowed (AboutView.swift `LicensesView`, `LicenseTextView`).
///   about-detailed-log        Search Settings, "verbose": Detailed Logging the first result; Enter opens About at it;
///                             Space turns it off and on again: the app log has no [http] request line while it is off and
///                             the probe's line before and after, and preferences.json keeps each choice (DetailedLogging).
///   chat-keys                 Trip planning open, Ctrl+W: the pane says No Chat Open and the sidebar has the keyboard;
///                             Trip planning again, Ctrl+Alt+A: the stand-in took the sidebar's PATCH archived true, the
///                             chat left the pane and "Archived “Trip planning”" with Undo shows (ChatKeys; the Mac's ⌘W
///                             and ⌃⌘A). The pill's clock runs free for the Mac's 4 s and the pill is gone within 10 s
///                             (ProofWalks.UndoPill.cs). Then the chat is unarchived again for the stand-in's next walk.
///   quick-actions             Ctrl+Shift+K: the Quick Actions page with the starter set seeded for the roster's first bot
///                             (Memo, Talk, New Chat wide, Add Task, Search Chats); a click on Edit; Shift+F10 on Memo and
///                             Move Down from its menu by keyboard; a click on Search Chats's − badge; Space on Done; the
///                             saved list (quick-actions.json read afresh) in that order; then a click on Add Task opens the
///                             Tasks page (QuickActionsPage; the Mac's QuickActionsViewController).
///   new-chat-sheet            Ctrl+Shift+N: the New Chat sheet (Hermes lit, the stand-in's projects); Space on the second
///                             pill (Research) and on Research's project Reading: the stand-in's session.create is for
///                             Research in /home/hermes/reading, and the new chat opens with its message box holding the
///                             keyboard (NewChatSheet; the Mac's NewChatSheetView).
///   quick-action-send         The walk's own tiles saved as the list (a Send a Message tile with Open the Chat on, a Run
///                             Job tile); Ctrl+Shift+K and a click on Send a Message: the bot's own chat opens and the
///                             composer stand-in takes one prompt.submit of the tile's words (QuickActionsFeature.SendInOpenChat;
///                             the Mac's NewChatRouter.send(_:inBotChatOf:)).
///   quick-action-run          The same list on the jobs stand-in; a click on Run Job: the page stays and says
///                             "✓ Running Morning inbox triage", and the stand-in took one trigger for inbox
///                             (QuickTileRun.RunJobAsync; the Mac's RunJobIntent.run without the wait).
///   tasks-select-actions      After tasks-sort-select (Home by Due Date): Select, two rows clicked, Space on Mark Done (one
///                             PATCH status done each, both fold into Done); Select, one row, Move To › Work by pointer (its
///                             PATCH section sec_work); Select, the last row, Delete and the confirmation's Delete (its
///                             DELETE): Home has no open rows left.
///   sidebar-group-chats       On the settings stand-in with --group-rooms: the two rooms' rows under Unassigned among its
///                             bot, newest first, Launch Room read aloud with Ivy's line; a click on it opens the room's
///                             chat with its row marked (WIN-41); Ctrl+Shift+S: the same heads in
///                             the rail with no headings ("sidebar-group-chats-rail"); then the sidebar opens again
///                             (MacBotsRail.titledGroups / groups, GroupRowView, GroupAvatarView).
/// Everything is found by its UI Automation id. Keys go in through Windows' own input (SendInput) with the window in front;
/// where the runner's desktop doesn't deliver them, the walk takes the UI Automation path a person would (the Send button,
/// the account menu's Keyboard Shortcuts) and says so in automation.log. Any state that isn't so throws, failing the walk.
internal static partial class ProofWalks
{
    public static void Register()
    {
        Automation.NamedWalks["new-chat-draft"] = NewChatDraftAsync;
        Automation.NamedWalks["new-chat-bare"] = NewChatBareAsync;
        Automation.NamedWalks["settings-auto-archive-on"] = AutoArchiveOnAsync;
        Automation.NamedWalks["shortcuts-sheet"] = ShortcutsSheetAsync;
        Automation.NamedWalks["open-quickly"] = OpenQuicklyAsync;
        Automation.NamedWalks["chat-find"] = ChatFindAsync;
        Automation.NamedWalks["type-to-chat"] = TypeToChatAsync;
        Automation.NamedWalks["tasks-sort-select"] = TasksSortSelectAsync;
        Automation.NamedWalks["chat-keys"] = ChatKeysAsync;
        Automation.NamedWalks["sidebar-search"] = SidebarSearchAsync;
        Automation.NamedWalks["about-licenses"] = AboutLicensesAsync;
        Automation.NamedWalks["about-detailed-log"] = AboutDetailedLogAsync;
        Automation.NamedWalks["quick-actions"] = QuickActionsAsync;
        Automation.NamedWalks["new-chat-sheet"] = NewChatSheetAsync;
        Automation.NamedWalks["quick-action-send"] = QuickActionSendAsync;
        Automation.NamedWalks["quick-action-run"] = QuickActionRunAsync;
        Automation.NamedWalks["tasks-select-actions"] = TasksSelectActionsAsync;
        RegisterWindowWalks();   // [WIN-34] Services/ProofWalks.Windows.cs
        Automation.NamedWalks["sidebar-group-chats"] = SidebarGroupChatsAsync;
        RegisterTranscriptWalks();   // [WIN-36] Services/ProofWalks.Transcript.cs
        RegisterGroupRoomWalks();   // [WIN-41] Services/ProofWalks.GroupRoom.cs
        RegisterChatActionsWalks();   // [WIN-43] Services/ProofWalks.ChatActions.cs
        RegisterGoalsWalks();   // [WIN-42] Services/ProofWalks.Goals.cs
        RegisterGroupManageWalks();   // [WIN-46] Services/ProofWalks.GroupManage.cs
        RegisterSettingsWindowWalks();   // [WIN-48] Services/ProofWalks.SettingsWindow.cs
        RegisterSelectionAndBarsWalks();   // [WIN-49] Services/ProofWalks.SelectionAndBars.cs
        RegisterA11yAuditWalks();   // [WIN-55] Services/ProofWalks.A11yAudit.cs
        RegisterReadAloudWalks();   // [WIN-54] Services/ProofWalks.ReadAloud.cs
        RegisterToastsWalks();   // [WIN-56] Services/ProofWalks.Toasts.cs
        RegisterGroupActivityWalks();   // [WIN-57] Services/ProofWalks.GroupActivity.cs
        RegisterKeyboardOnlyWalks();   // [WIN-58] Services/ProofWalks.KeyboardOnly.cs
        RegisterGroupMentionsWalks();   // [WIN-59] Services/ProofWalks.GroupMentions.cs
        RegisterTextScaleWalks();   // [WIN-60] Services/ProofWalks.TextScale.cs
        RegisterReadRepliesAloudWalks();   // [WIN-62] Services/ProofWalks.ReadRepliesAloud.cs
        RegisterSettingsFileWalks();   // [WIN-06] Services/ProofWalks.SettingsFile.cs
        RegisterChatIntroWalks();   // [WIN-CHAT-INTRO] Services/ProofWalks.ChatIntro.cs
        RegisterNewChatHereWalks();   // [WIN-CHAT-HERE-PROOF] Services/ProofWalks.NewChatHere.cs
        RegisterArchiveUndoWalks();   // [WIN-ARCHIVE-UNDO] Services/ProofWalks.ArchiveUndo.cs
        RegisterStarMapFirstOpenWalks();
        RegisterAppearanceWalks();   // [WIN-APPEARANCE-WALK] Services/ProofWalks.Appearance.cs
        RegisterPageCardsWalks();   // [WIN-PAGE-CARDS] Services/ProofWalks.PageCards.cs
        RegisterMathWalks();   // [WIN-MATH-UI] Services/ProofWalks.Math.cs
        RegisterSettledQuestionsWalks();   // [WIN-QUESTIONS-SETTLED-WALK] Services/ProofWalks.SettledQuestions.cs
        RegisterScreenWalks();   // [WIN-SCREEN-PAGE] Services/ProofWalks.Screen.cs
        RegisterScreenSetupWalks();   // [WIN-SCREEN-SETUP-SEND-WALK] Services/ProofWalks.ScreenSetup.cs
        RegisterDeliveryWalks();   // [WIN-DELIVERY-WALK] Services/ProofWalks.Delivery.cs
        RegisterRowStepsWalks();   // [WIN-ROWS-STEP-WALK] Services/ProofWalks.RowSteps.cs
        RegisterThinkingWalks();   // [WIN-THINKING-WALK] Services/ProofWalks.Thinking.cs
        RegisterSessionsHeaderWalks();   // [WIN-SESSIONS-WORKING-CHIP] Services/ProofWalks.SessionsHeader.cs
        RegisterAttachmentsWalks();   // Services/ProofWalks.Attachments.cs
    }

    private const string Draft = "draft words";

    // ------------------------------------------------------------------ /new

    private static async Task NewChatDraftAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var bots = await client.BotsAsync();
        var bot = bots.FirstOrDefault(b => b.Name == "default") ?? bots.FirstOrDefault() ?? throw new InvalidOperationException("no bots");
        var storedId = await client.BotChatIdAsync(bot);
        Navigator.Go(new ChatDestination(bot.Name, storedId, bot.DisplayName));
        var old = await Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId == storedId ? p : null, "the bot's chat");
        // /new needs the roster to know the bot (ComposerController.StartNewChat).
        await Until(() => Features.Bots.ListsHub.Current?.Bots.Bot(bot.Name) != null ? old : null, "the roster");
        await Task.Delay(1500);   // the chat's own binding (session.resume, the model, the catalog) settles before the mark
        var url = client.Session.Address.ToString();
        var mark = WalkProof.LastCallAt(await StandIn(url, "/__menus/state"));

        var box = (TextBox)await Until(() => FindIn(old, "chat.composer"), "the message box");
        box.Focus(FocusState.Keyboard);
        const string line = "/new " + Draft;
        if (!await KeysAsync(() => Keys.Type(line), () => box.Text == line, "typing"))
        {
            box.Text = line;   // a WinUI TextBox's peer gives no managed Value pattern (CI run 44976036331)
            box.SelectionStart = line.Length;
        }
        if (box.Text != line) throw new InvalidOperationException($"the box reads \"{box.Text}\"");
        if (!await KeysAsync(() => Keys.Press(Keys.Enter), () => ChatPage.Current != old, "Enter"))
            Invoke(Need(old, "chat.send"));

        var opened = await Until(() => ChatPage.Current is { IsLoaded: true } p && p != old && p.StoredId != storedId ? p : null, "the new chat");
        if (opened.ChatTitle != Hermes.Core.Composer.NewChatCommand.Title) throw new InvalidOperationException($"the new chat is titled {opened.ChatTitle}");
        var newBox = (TextBox)Need(opened, "chat.composer");
        await Until(() => newBox.Text == Draft ? newBox : null, "\"draft words\" in the new chat's box");
        await Task.Delay(1000);   // whatever the command might send has reached the stand-in
        if (WalkProof.NewChatSentNothing(await StandIn(url, "/__menus/state"), mark, bot.Name) is { } wrong)
            throw new InvalidOperationException(wrong);
        if (newBox.Text != Draft) throw new InvalidOperationException($"the new chat's box reads \"{newBox.Text}\"");
        await shot("new-chat-draft");
    }

    /// [WIN-03 review run 138] Bare "/new" typed in the bot's chat and Entered by keyboard. Typing the command's name opens
    /// the drawer with /new marked, so the first Enter picks it; /new takes words (argument mode "text"), so the pick puts
    /// "/new " in the box and sends nothing (SlashCatalog.PickActionFor, the Mac's `pickAction` → .insert; Mac Catalyst
    /// marks the first match the same way). The second Enter sends it: a new chat titled New Chat in its place, its box
    /// empty, and the stand-in made one chat for the bot and took no prompt.
    private static async Task NewChatBareAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var bots = await client.BotsAsync();
        var bot = bots.FirstOrDefault(b => b.Name == "default") ?? bots.FirstOrDefault() ?? throw new InvalidOperationException("no bots");
        var storedId = await client.BotChatIdAsync(bot);
        Navigator.Go(new ChatDestination(bot.Name, storedId, bot.DisplayName));
        var old = await Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId == storedId ? p : null, "the bot's chat");
        await Until(() => Features.Bots.ListsHub.Current?.Bots.Bot(bot.Name) != null ? old : null, "the roster");
        await Task.Delay(1500);   // the chat's own binding settles before the mark
        var url = client.Session.Address.ToString();
        var mark = WalkProof.LastCallAt(await StandIn(url, "/__menus/state"));

        var box = (TextBox)await Until(() => FindIn(old, "chat.composer"), "the message box");
        if (box.Text.Length != 0) throw new InvalidOperationException($"the bot's chat's box already reads \"{box.Text}\"");
        box.Focus(FocusState.Keyboard);
        const string line = "/new";
        if (!await KeysAsync(() => Keys.Type(line), () => box.Text == line, "typing"))
        {
            box.Text = line;   // a WinUI TextBox's peer gives no managed Value pattern (CI run 44976036331)
            box.SelectionStart = line.Length;
        }
        if (box.Text != line) throw new InvalidOperationException($"the box reads \"{box.Text}\"");

        // Enter on the drawer's marked /new: "/new " in the box, the same chat, nothing on the wire.
        const string picked = line + " ";
        if (await KeysAsync(() => Keys.Press(Keys.Enter), () => box.Text == picked || ChatPage.Current != old, "Enter on the drawer"))
        {
            if (ChatPage.Current != old) throw new InvalidOperationException("Enter on \"/new\" opened a chat without the drawer's pick first");
            AppLog.Note("automation", "walk new-chat-bare: Enter picked /new in the drawer; the box reads \"/new \"");
            await Task.Delay(500);
            if (WalkProof.NewChatPickSentNothing(await StandIn(url, "/__menus/state"), mark) is { } early)
                throw new InvalidOperationException(early);
            if (!await KeysAsync(() => Keys.Press(Keys.Enter), () => ChatPage.Current != old, "Enter"))
                Invoke(Need(old, "chat.send"));
        }
        else Invoke(Need(old, "chat.send"));   // no key reaches the window on this desktop: the Send button sends "/new"

        var opened = await Until(() => ChatPage.Current is { IsLoaded: true } p && p != old && p.StoredId != storedId ? p : null, "the new chat");
        if (opened.ChatTitle != Hermes.Core.Composer.NewChatCommand.Title) throw new InvalidOperationException($"the new chat is titled {opened.ChatTitle}");
        var newBox = (TextBox)Need(opened, "chat.composer");
        await Task.Delay(1000);   // whatever the command might send has reached the stand-in
        if (WalkProof.NewChatSentNothing(await StandIn(url, "/__menus/state"), mark, bot.Name) is { } wrong)
            throw new InvalidOperationException(wrong);
        if (newBox.Text.Length != 0) throw new InvalidOperationException($"the new chat's box reads \"{newBox.Text}\"");
        await shot("new-chat-bare");
    }

    // ------------------------------------------------------------------ Auto-Archive

    private static async Task AutoArchiveOnAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var url = client.Session.Address.ToString();
        Navigator.Open("settings", "sessions");
        var toggle = (ToggleSwitch)await Until(() => Find("sessions.auto-archive"), "Auto-Archive Stale Chats");
        if (toggle.IsOn) throw new InvalidOperationException("Auto-Archive Stale Chats was already on");
        await Task.Delay(800);
        var mark = WalkProof.LastWriteAt(await StandIn(url, "/__settings/state"));

        Pattern<IToggleProvider>(toggle, PatternInterface.Toggle).Toggle();
        var days = (TextBox)await Until(() => Find("sessions.auto-archive-days"), "Archive After");
        // Typed into the field and Enter, as a person does (SettingsPanes' KeyDown Enter → CommitDays). A WinUI TextBox's
        // peer hands UI Automation no managed Value pattern, so where keys don't arrive the field is set directly and left.
        days.Focus(FocusState.Keyboard);
        days.SelectAll();
        if (await KeysAsync(() => Keys.Type("14"), () => days.Text == "14", "typing the days")) Keys.Press(Keys.Enter);
        else days.Text = "14";
        if (days.Text != "14") throw new InvalidOperationException($"Archive After reads \"{days.Text}\"");
        toggle.Focus(FocusState.Keyboard);   // leaving the field commits it too (SettingsPanes' LostFocus → CommitDays)

        // The autosave's debounce, then the stand-in's record.
        var why = await SavedAsync(url, mark, 10);
        if (why != null)
        {
            // The field kept focus on this desktop: leaving the page commits it too (SettingsPanes' Unloaded).
            AppLog.Note("automation", $"walk auto-archive: {why} after leaving the field; leaving the page to commit");
            Navigator.Open("settings", "about");
            await Until(() => Find("sessions.auto-archive") == null ? Root : null, "the page to go");
            Navigator.Open("settings", "sessions");
            why = await SavedAsync(url, mark, 15);
            toggle = (ToggleSwitch)await Until(() => Find("sessions.auto-archive"), "Auto-Archive Stale Chats again");
            days = (TextBox)await Until(() => Find("sessions.auto-archive-days"), "Archive After again");
        }
        if (why != null) throw new InvalidOperationException(why);
        await Until(() => toggle.IsOn && days.Text == "14" ? toggle : null, "the page to show on and 14 days");
        await shot("settings-auto-archive-on");
    }

    /// Polls settings-gateway.py's record for `seconds` (at least 10): null once Auto-Archive is saved on with 14 days.
    private static async Task<string?> SavedAsync(string url, double mark, int seconds)
    {
        var until = DateTime.UtcNow.AddSeconds(Math.Max(10, seconds));
        while (true)
        {
            var why = WalkProof.AutoArchiveSaved(await StandIn(url, "/__settings/state"), mark, 14);
            if (why == null || DateTime.UtcNow > until) return why;
            await Task.Delay(250);
        }
    }

    // ------------------------------------------------------------------ Keyboard Shortcuts

    private static async Task ShortcutsSheetAsync(Func<string, Task> shot)
    {
        if (ShortcutsSheet.IsOpen) throw new InvalidOperationException("the sheet was already up");
        if (ChatPage.Current is { } chat && FindIn(chat, "chat.composer") is TextBox box) box.Focus(FocusState.Keyboard);
        var byKeyboard = await KeysAsync(() => Keys.Press(Keys.Slash, ctrl: true), () => SheetShowing() != null, "Ctrl+/");
        if (!byKeyboard)
        {
            var account = (Button)Need("shell.account");
            account.Flyout.ShowAt(account);
            var item = await Until(() => InPopups().FirstOrDefault(e => Id(e) == "shell.keyboardShortcuts"), "Keyboard Shortcuts in the account menu");
            Invoke(item);
        }
        var sheet = await Until(SheetShowing, "shortcuts.sheet");
        await Until(() => Shown(sheet).Any(e => Id(e).StartsWith("shortcuts.row.", StringComparison.Ordinal)) ? sheet : null, "the sheet's rows");
        await shot("shortcuts-sheet");
        if (await KeysAsync(() => Keys.Press(Keys.Escape), () => SheetShowing() == null && !ShortcutsSheet.IsOpen, "Esc")) return;
        // Ctrl+/ came in by keyboard, so keys reach the window: Esc not closing the sheet is the app's fault.
        if (byKeyboard) throw new InvalidOperationException("Esc didn't close shortcuts.sheet");
        // No key reaches the window on this desktop: Esc is unproven here; Done closes the sheet so the walk goes on.
        AppLog.Note("automation", "walk keys: Esc unproven (no keys reach the window); closing shortcuts.sheet with Done");
        sheet.Hide();
        await Until(() => SheetShowing() == null && !ShortcutsSheet.IsOpen ? sheet : null, "the sheet to close");
    }

    /// The sheet on screen: an open popup holding the `shortcuts.sheet` dialog.
    private static ContentDialog? SheetShowing() => InPopups().OfType<ContentDialog>().FirstOrDefault(d => Id(d) == "shortcuts.sheet");

    // ------------------------------------------------------------------ Open Quickly

    private static async Task OpenQuicklyAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        if (OpenQuicklyPanel.IsOpen) throw new InvalidOperationException("Open Quickly was already up");
        var bots = await client.BotsAsync();
        // The bot whose chat isn't on show (Sam on the composer stand-in), so opening it is a change of page.
        var bot = bots.FirstOrDefault(b => b.Name != "default") ?? bots.FirstOrDefault() ?? throw new InvalidOperationException("no bots");
        await Until(() => ListsHub.Current is { } hub && hub.Bots.Bot(bot.Name) != null && hub.Sessions.LiveSummaries().Count > 0 ? hub : null,
            "the sidebar's bots and chats");

        // Ctrl+K: the panel, its field focused, Recent before anything is typed.
        FocusInWindow();
        if (!await KeysAsync(() => Keys.Press(Keys.K, ctrl: true), () => OpenQuicklyPanel.IsOpen, "Ctrl+K"))
            throw new InvalidOperationException("Ctrl+K didn't open Open Quickly (no keys reach the window; it has no other door)");
        var (field, list) = await PanelAsync();
        await Until(() => Headings(list) is [var first] && first == OpenQuicklyText.RecentTitle
            && RowIds(list) is { Count: > 0 } rows && rows.All(r => r.StartsWith("openquickly.sessions.", StringComparison.Ordinal)) ? list : null,
            "Recent with the latest chats");
        if (RowIds(list).Count > OpenQuicklyText.RecentLimit) throw new InvalidOperationException($"Recent shows {RowIds(list).Count} chats");
        if (FocusedIn() != field) throw new InvalidOperationException("the panel's field doesn't have the keyboard");
        await shot("open-quickly-recent");

        // A bot's name: the groups under their headings, the bot's row marked (its name exactly, wherever its group is).
        var name = bot.DisplayName;
        if (!await KeysAsync(() => Keys.Type(name), () => field.Text == name, "typing in Open Quickly"))
        {
            field.Text = name;   // a WinUI TextBox's peer gives no managed Value pattern
            field.SelectionStart = name.Length;
        }
        var botRow = $"openquickly.bots.{bot.Name}";
        await Until(() => RowIds(list).Contains(botRow) && Marked(list) == botRow ? list : null, $"{botRow} marked");
        var headings = Headings(list);
        string[] groups = [.. Enum.GetValues<MoreSearch.Kind>().Select(MoreSearch.Title)];
        if (!headings.Contains(MoreSearch.Title(MoreSearch.Kind.Bots)) || headings.Any(h => !groups.Contains(h)))
            throw new InvalidOperationException($"the results' headings read {string.Join(", ", headings)}");
        await shot("open-quickly-results");

        // ↓ moves the mark to the next row (it stays on the last); Enter opens the marked row.
        var shown = RowIds(list);
        var target = shown[Math.Min(shown.IndexOf(botRow) + 1, shown.Count - 1)];
        if (!await KeysAsync(() => Keys.Press(Keys.Down), () => Marked(list) == target, "↓"))
            throw new InvalidOperationException($"↓ left the mark on {Marked(list)}, not {target}");
        AppLog.Note("automation", $"walk open-quickly: ↓ marked {target.Split('.')[1]}");
        async Task PickAsync(string row, Func<SettingsWindow, Task>? checkWindow = null)
        {
            if (row.StartsWith("openquickly.settings.", StringComparison.Ordinal) || row is "openquickly.goTo.settings" or "openquickly.actions.perf-logs")
            {
                var shell = ShellPage.Current ?? throw new InvalidOperationException("the shell isn't showing");
                var before = shell.WalkState();
                if (SettingsWindow.Showing != null) throw new InvalidOperationException("a Settings window was already open");
                if (!await KeysAsync(() => Keys.Press(Keys.Enter), () => !OpenQuicklyPanel.IsOpen && SettingsWindow.Showing != null, "Enter on a setting"))
                    throw new InvalidOperationException($"Enter on {row} didn't open the Settings window");
                var window = await Until(() => SettingsWindow.Showing, "the Settings window");
                try
                {
                    await Until(() => window.Page is { IsLoaded: true } p ? p : null, "Settings loaded in its own window");
                    if (SettingsWindowWalkProof.OneWindow(SettingsWindow.OpenCount, window.Title) is { } wrong) throw new InvalidOperationException(wrong);
                    if (SettingsWindowWalkProof.MainUnchanged(before, shell.WalkState(), Shown(Root).OfType<HermesHQ.Features.Settings.SettingsPage>().Any()) is { } changed)
                        throw new InvalidOperationException(changed);
                    if (checkWindow != null) await checkWindow(window);
                }
                finally { window.Close(); }
                await Until(() => SettingsWindow.OpenCount == 0 ? shell : null, "the walk's Settings window to close");
                return;
            }
            Destination? went = null;
            void Seen(Destination d) => went ??= d;
            Navigator.Requested += Seen;
            try
            {
                if (!await KeysAsync(() => Keys.Press(Keys.Enter), () => !OpenQuicklyPanel.IsOpen && went != null, "Enter"))
                    throw new InvalidOperationException($"Enter didn't open {row} (panel {(OpenQuicklyPanel.IsOpen ? "up" : "closed")})");
            }
            finally { Navigator.Requested -= Seen; }
            await OpenedAsync(client, bots, row, went!);
        }
        await PickAsync(target);

        // The Mac's app:default-folder entry opens .root("sessions"), not the literal entry id.
        FocusInWindow();
        if (!await KeysAsync(() => Keys.Press(Keys.K, ctrl: true), () => OpenQuicklyPanel.IsOpen, "Ctrl+K again"))
            throw new InvalidOperationException("Ctrl+K didn't open Open Quickly again");
        (field, list) = await PanelAsync();
        const string setting = "default project folder";
        if (!await KeysAsync(() => Keys.Type(setting), () => field.Text == setting, "typing a setting's name"))
            throw new InvalidOperationException("The setting's name didn't reach the Open Quickly field");
        const string settingRow = "openquickly.settings.app:default-folder";
        await Until(() => RowIds(list).Contains(settingRow) && Marked(list) == settingRow ? list : null, $"{settingRow} marked");
        if (!Headings(list).Contains(MoreSearch.Title(MoreSearch.Kind.Settings)))
            throw new InvalidOperationException("The Settings heading is missing");
        await shot("open-quickly-settings");
        await PickAsync(settingRow, async window =>
        {
            await Until(() => window.Page?.PageTitle == SettingsWords.SessionsPageTitle && window.Content is DependencyObject content
                ? FindIn(content, "sessions.default-folder") as TextBox : null, "the Default Project Folder field in the Settings window");
            await ShotOfAsync(window, () => shot("open-quickly-settings-opened"));
        });

        // Words nothing matches: the no-results words and no list; Esc closes it.
        FocusInWindow();
        if (!await KeysAsync(() => Keys.Press(Keys.K, ctrl: true), () => OpenQuicklyPanel.IsOpen, "Ctrl+K after Settings"))
            throw new InvalidOperationException("Ctrl+K didn't reopen Open Quickly after Settings closed");
        (field, list) = await PanelAsync();
        const string nothing = "zzqx";
        if (!await KeysAsync(() => Keys.Type(nothing), () => field.Text == nothing, "typing zzqx"))
        {
            field.Text = nothing;
            field.SelectionStart = nothing.Length;
        }
        var note = OpenQuicklyText.NoResults(nothing);
        await Until(() => InPopups().FirstOrDefault(e => Id(e) == "openquickly.empty") is TextBlock t && t.Text == note
            && list.Visibility == Visibility.Collapsed ? t : null, $"\u201C{note}\u201D");
        await shot("open-quickly");
        if (!await KeysAsync(() => Keys.Press(Keys.Escape), () => !OpenQuicklyPanel.IsOpen && InPopups().All(e => Id(e) != "openquickly"), "Esc"))
            throw new InvalidOperationException("Esc didn't close Open Quickly");
    }

    /// The panel's field and results list, once its popup is up.
    private static async Task<(TextBox Field, ListView List)> PanelAsync()
    {
        var field = (TextBox)await Until(() => InPopups().FirstOrDefault(e => Id(e) == "openquickly.field"), "openquickly.field");
        var list = (ListView)await Until(() => All(PopupRoots(), "openquickly.results"), "openquickly.results");
        await Until(() => FocusedIn() == field ? field : null, "the caret in the panel's field");
        return (field, list);
    }

    private static List<ListViewItem> Items(ListView list) => (list.ItemsSource as IEnumerable<object>)?.OfType<ListViewItem>().ToList() ?? [];

    /// The results' headings in order (each a row the mark skips): "Recent", or the groups' names.
    private static List<string> Headings(ListView list) =>
        [.. Items(list).Where(i => Id(i).StartsWith("openquickly.header.", StringComparison.Ordinal)).Select(i => AutomationProperties.GetName(i))];

    /// The rows the mark moves over, top to bottom, by their ids ("openquickly.<kind>.<id>").
    private static List<string> RowIds(ListView list) =>
        [.. Items(list).Select(Id).Where(id => !id.StartsWith("openquickly.header.", StringComparison.Ordinal))];

    private static string? Marked(ListView list) => list.SelectedItem is ListViewItem row ? Id(row) : null;

    /// What Enter opened against the marked row (`OpenQuickly.Route`): a bot's or a chat's page with that chat, or the place.
    private static async Task OpenedAsync(HermesClient client, IReadOnlyList<Hermes.Core.Model.Bot> bots, string row, Destination went)
    {
        var parts = row.Split('.', 3);
        var (kind, id) = (parts[1], parts[2]);
        switch (kind)
        {
            case "bots":
                if (went is not BotChatDestination b || b.Bot.Name != id) throw new InvalidOperationException($"Enter on {row} went to {went}");
                var stored = await client.BotChatIdAsync(bots.First(x => x.Name == id));
                await Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId == stored ? p : null, $"{id}'s chat");
                break;
            case "sessions":
                var cut = id.IndexOf('|');
                if (went is not ChatDestination c || c.Profile != id[..cut] || c.StoredId != id[(cut + 1)..])
                    throw new InvalidOperationException($"Enter on a chat went to {went}");
                await Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId == c.StoredId ? p : null, "the chat");
                break;
            case "goTo":
                if (went is not PlaceDestination d || d.PlaceId != id)
                    throw new InvalidOperationException($"Enter on {row} went to {went}");
                await Task.Delay(1500);
                break;
            default:
                throw new InvalidOperationException($"↓ landed on {row}, an action, not a place to open");
        }
    }

    // ------------------------------------------------------------------ Find in a chat

    private static async Task ChatFindAsync(Func<string, Task> shot)
    {
        if (AppState.Client == null) throw new InvalidOperationException("not signed in");
        Navigator.Go(new ChatDestination("default", WalkProof.TripStoredId, WalkProof.TripTitle));
        var page = await Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId == WalkProof.TripStoredId && p.MessageCount >= 6 ? p : null,
            "Trip planning's messages");
        await Task.Delay(1000);   // the chat's own binding settles
        var transcript = (Control)Need(page, "chat.transcript");
        var originalPadding = transcript.Padding;
        var bar = (FrameworkElement)(All([page], "chatfind.bar") ?? throw new InvalidOperationException(
            $"chatfind.bar isn't in the chat (the transcript's parent: {transcript.Parent?.GetType().Name ?? "none"}, " +
            $"visual parent: {VisualTreeHelper.GetParent(transcript)?.GetType().Name ?? "none"})"));
        if (bar.Visibility == Visibility.Visible) throw new InvalidOperationException("Find was already open");
        var box = (TextBox)Need(page, "chat.composer");
        box.Focus(FocusState.Keyboard);

        if (!await KeysAsync(() => Keys.Press(Keys.F, ctrl: true), () => bar.Visibility == Visibility.Visible, "Ctrl+F"))
            throw new InvalidOperationException("Ctrl+F didn't open Find (no keys reach the window; it has no other door)");
        var field = (TextBox)Need(page, "chatfind.field");
        await Until(() => FocusedIn() == field ? field : null, "the caret in Find's field");
        if (!await KeysAsync(() => Keys.Type(WalkProof.FindWord), () => field.Text == WalkProof.FindWord, "typing in Find"))
        {
            field.Text = WalkProof.FindWord;
            field.SelectionStart = WalkProof.FindWord.Length;
        }
        var count = (TextBlock)await Until(() => FindIn(page, "chatfind.count"), "chatfind.count");
        const int n = WalkProof.FindMatches;
        // Typed: the newest match (ChatFind.KeepCurrent); F3 wraps to the oldest, then steps on.
        await Until(() => count.Text == ChatFindText.CountText(n - 1, n, WalkProof.FindWord) ? count : null, $"\u201C{n} of {n}\u201D");
        if (!await KeysAsync(() => Keys.Press(Keys.F3), () => count.Text == ChatFindText.CountText(0, n, WalkProof.FindWord), "F3"))
            throw new InvalidOperationException($"F3 left the count at \u201C{count.Text}\u201D");
        if (!await KeysAsync(() => Keys.Press(Keys.F3), () => count.Text == ChatFindText.CountText(1, n, WalkProof.FindWord), "F3 again"))
            throw new InvalidOperationException($"F3 again left the count at \u201C{count.Text}\u201D");
        await shot("chat-find");
        await FindReflowAsync(transcript, originalPadding, bar, field, shot);
        // Find Previous both ways (the Mac's ⇧⌘G, mac1 D and D2): back to the oldest, then wrapping to the newest.
        if (!await KeysAsync(() => Keys.Press(Keys.F3, shift: true), () => count.Text == ChatFindText.CountText(0, n, WalkProof.FindWord), "Shift+F3"))
            throw new InvalidOperationException($"Shift+F3 left the count at \u201C{count.Text}\u201D");
        if (!await KeysAsync(() => Keys.Press(Keys.G, ctrl: true, shift: true), () => count.Text == ChatFindText.CountText(n - 1, n, WalkProof.FindWord), "Ctrl+Shift+G"))
            throw new InvalidOperationException($"Ctrl+Shift+G left the count at \u201C{count.Text}\u201D (no wrap to the newest)");
        if (HermesHQ.Features.ChatFind.ChatFindBar.Highlights(transcript) == 0) throw new InvalidOperationException("Find is open on two matches and nothing is highlighted");

        if (!await KeysAsync(() => Keys.Press(Keys.Escape), () => bar.Visibility == Visibility.Collapsed, "Esc"))
            throw new InvalidOperationException("Esc didn't close Find");
        if (field.Text.Length > 0) throw new InvalidOperationException("Find kept its words after closing");
        if (!transcript.Padding.Equals(originalPadding)) throw new InvalidOperationException("Find did not restore the transcript's original padding");
        // The Mac's close resigns the field and nothing has the keyboard (mac1 E): not the box, not Find's field.
        await Task.Delay(500);
        var after = FocusedIn();
        if (after == box || after == field || (after != null && Within(after, field)))
            throw new InvalidOperationException($"after Esc the keyboard is on {(after == box ? "the message box" : "Find's field")}, not nothing");
        if (after is TextBox or RichEditBox or PasswordBox) throw new InvalidOperationException($"after Esc the keyboard is in a text field ({Id(after)})");
        AppLog.Note("automation", $"walk chat-find: after Esc the keyboard is on {after?.GetType().Name ?? "nothing"}");
        if (HermesHQ.Features.ChatFind.ChatFindBar.StrayRests(page) is var stray and > 0)
            throw new InvalidOperationException($"after Esc {stray} invisible Find rest element(s) are tab stops without the keyboard");
        var left = HermesHQ.Features.ChatFind.ChatFindBar.Highlights(transcript);
        if (left > 0) throw new InvalidOperationException($"{left} Find highlights left after Esc");
        await shot("chat-find-closed");
        // A letter now goes to the box through type-to-chat, and the box keeps the keyboard (mac1 F).
        if (!await KeysAsync(() => Keys.Press(Keys.X), () => box.Text == "x" && FocusedIn() == box, "X"))
            throw new InvalidOperationException($"after Esc, X left the box reading \u201C{box.Text}\u201D and the keyboard on {FocusedIn()?.GetType().Name ?? "nothing"}");
        box.Text = "";   // no draft left behind
    }

    // ------------------------------------------------------------------ type-to-chat

    private static async Task TypeToChatAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var bots = await client.BotsAsync();
        var bot = bots.FirstOrDefault(b => b.Name != "default") ?? bots.FirstOrDefault() ?? throw new InvalidOperationException("no bots");
        var storedId = await client.BotChatIdAsync(bot);
        Navigator.Go(new ChatDestination(bot.Name, storedId, bot.DisplayName));
        var page = await Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId == storedId && p.MessageCount > 0 ? p : null, "the bot's chat");
        await Task.Delay(1500);   // the chat's own binding settles
        var box = (TextBox)Need(page, "chat.composer");
        if (box.Text.Length > 0)
        {
            AppLog.Note("automation", "walk type-to-chat: emptied the message box first");
            box.Text = "";
        }

        // The keyboard on the transcript: a list, nothing that types.
        Keys.Front();
        var transcript = (ListView)Need(page, "chat.transcript");
        static bool Types(DependencyObject f) => f is TextBox or RichEditBox or PasswordBox or RichTextBlock or TextBlock;
        if (!transcript.Focus(FocusState.Keyboard) || FocusedIn() is not { } first || !Within(first, transcript) || Types(first))
            (transcript.ContainerFromIndex(Math.Max(0, transcript.Items.Count - 1)) as Control)?.Focus(FocusState.Keyboard);
        var focused = await Until(() => FocusedIn() is { } f && Within(f, transcript) ? f : null, "the transcript to have the keyboard");
        if (Types(focused)) throw new InvalidOperationException($"the transcript's focus is text ({focused.GetType().Name}), not the list");
        AppLog.Note("automation", $"walk type-to-chat: the keyboard on the transcript's {focused.GetType().Name}");

        // H and I as a person presses them: the box takes the keyboard at the first and reads "hi".
        if (!await KeysAsync(() => Keys.Press(Keys.H) && Keys.Press(Keys.I), () => box.Text == "hi" && FocusedIn() == box, "H I"))
            throw new InvalidOperationException($"after H and I the box reads \u201C{box.Text}\u201D and the keyboard is on {FocusedIn()?.GetType().Name ?? "nothing"}");
        await shot("type-to-chat");
        box.Text = "";   // no draft left behind
    }

    // ------------------------------------------------------------------ Tasks Sort By and Select

    private static async Task TasksSortSelectAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var url = client.Session.Address.ToString();
        Navigator.Open("tasks");
        var pillId = "tasks.view." + TodoView.List(WalkProof.HomeList).Key;
        var pill = (ToggleButton)await Until(() => Find(pillId), "the Home list's pill");

        // Home, by keyboard: Space on its pill.
        pill.Focus(FocusState.Keyboard);
        if (!await KeysAsync(() => Keys.Press(Keys.Space), () => Find(pillId) is ToggleButton { IsChecked: true }, "Space on Home"))
        {
            Mouse.Click(pill);
            await Until(() => Find(pillId) is ToggleButton { IsChecked: true } p ? p : null, "Home picked");
        }
        await RowsAsync(WalkProof.HomeMyOrder, "Home in My Order");
        var mark = WalkProof.RestCount(await StandIn(url, "/__fixture/state"));

        // ⋯ › Sort By › Due Date, by keyboard.
        await MoreMenuAsync("tasks.sort.menu");
        if (!await KeysAsync(() => Keys.Press(Keys.Right), () => InPopups().Any(e => Id(e) == "tasks.sort.due"), "→ on Sort By"))
            Pattern<IExpandCollapseProvider>(Popped("tasks.sort.menu"), PatternInterface.ExpandCollapse).Expand();
        var due = await Until(() => InPopups().FirstOrDefault(e => Id(e) == "tasks.sort.due"), "Due Date");
        if (!(await KeyToAsync("tasks.sort.due", Keys.Down, 5)
              && await KeysAsync(() => Keys.Press(Keys.Enter), () => InPopups().All(e => Id(e) != "tasks.sort.due"), "Enter on Due Date")))
            Invoke(due);
        await RowsAsync(WalkProof.HomeByDue, "Home by Due Date");
        var why = await TasksSavedAsync(url, mark);
        if (why != null) throw new InvalidOperationException(why);
        await shot("tasks-sorted-due");

        // ⋯ › Select Tasks, then a click on each of two rows picks it.
        await MoreMenuAsync("tasks.select.start");
        if (!await KeysAsync(() => Keys.Press(Keys.Enter), () => Find("tasks.select.done") != null, "Enter on Select Tasks"))
            Invoke(Popped("tasks.select.start"));
        await Until(() => Find("tasks.select.done"), "Select's bar");
        string[] picks = [WalkProof.HomeByDue[0], WalkProof.HomeByDue[1]];
        foreach (var id in picks)
        {
            // Select rebuilds the rows: aim only once this one is laid out (CI run 45009956343 clicked a 0×0 row,
            // "tasks.row.t_cleaning is off the screen at (261,133)-(261,133)", though the shot showed it a moment later).
            Mouse.Click(await Until(() => Find("tasks.row." + id) is FrameworkElement { ActualWidth: > 0, ActualHeight: > 0 } laid ? laid : null,
                $"{id} laid out"));
            await Until(() => Find("tasks.row." + id) is { } row && AutomationProperties.GetItemStatus(row) == "Selected" ? row : null, $"{id} picked");
        }
        var picked = Shown(Root).Where(e => Id(e).StartsWith("tasks.row.", StringComparison.Ordinal) && AutomationProperties.GetItemStatus(e) == "Selected")
            .Select(e => Id(e)["tasks.row.".Length..]).ToList();
        if (!picked.Order().SequenceEqual(picks.Order())) throw new InvalidOperationException($"picked {string.Join(", ", picked)}");
        if (Need("tasks.select.mark-done") is not Button { IsEnabled: true }) throw new InvalidOperationException("Mark Done is greyed with two picked");
        await shot("tasks-select");

        // Esc decides nothing while selecting (the Mac's `[keys] escape: nothing`): the bar stays and both rows stay picked.
        ((Control)Need("tasks.select.done")).Focus(FocusState.Keyboard);
        Keys.Press(Keys.Escape);
        await Task.Delay(400);
        if (Find("tasks.select.done") == null || Find("tasks.more") != null) throw new InvalidOperationException("Esc ended Select");
        var kept = Shown(Root).Where(e => Id(e).StartsWith("tasks.row.", StringComparison.Ordinal) && AutomationProperties.GetItemStatus(e) == "Selected")
            .Select(e => Id(e)["tasks.row.".Length..]).ToList();
        if (!kept.Order().SequenceEqual(picks.Order())) throw new InvalidOperationException($"after Esc picked {string.Join(", ", kept)}");

        // Done ends Select: the page's own buttons back, nothing picked, nothing written.
        if (!await KeysAsync(() => Keys.Press(Keys.Space), () => Find("tasks.select.done") == null && Find("tasks.more") != null, "Space on Done"))
            Invoke(Need("tasks.select.done"));
        await Until(() => Find("tasks.select.done") == null && Find("tasks.more") != null ? Root : null, "Done to end Select");
        if (Shown(Root).Any(e => Id(e).StartsWith("tasks.row.", StringComparison.Ordinal) && AutomationProperties.GetItemStatus(e) == "Selected"))
            throw new InvalidOperationException("rows stayed picked after Select ended");
        await RowsAsync(WalkProof.HomeByDue, "Home after Select");
        if (WalkProof.TasksSortSaved(await StandIn(url, "/__fixture/state"), mark, "due") is { } wrong) throw new InvalidOperationException(wrong);
        await shot("tasks-sort-select");
    }

    /// The page's ⋯ open by keyboard (Enter on it; its flyout shown directly where keys don't arrive) and the keyboard
    /// moved down it to `id`.
    private static async Task MoreMenuAsync(string id)
    {
        var more = (Button)Need("tasks.more");
        more.Focus(FocusState.Keyboard);
        if (!await KeysAsync(() => Keys.Press(Keys.Enter), () => InPopups().Any(e => Id(e) == id), "Enter on ⋯"))
            more.Flyout.ShowAt(more);
        await Until(() => InPopups().FirstOrDefault(e => Id(e) == id), id);
        if (!await KeyToAsync(id, Keys.Down, 4)) AppLog.Note("automation", $"walk keys: ↓ didn't reach {id}; using UI Automation");
    }

    /// Presses `key` (at most `presses` times) until the keyboard is on `id`.
    private static async Task<bool> KeyToAsync(string id, ushort key, int presses)
    {
        for (var i = 0; i <= presses; i++)
        {
            var until = DateTime.UtcNow.AddSeconds(i == 0 ? 2 : 10);
            while (DateTime.UtcNow < until)
            {
                if (FocusedIn() is { } f && Id(f) == id) return true;
                await Task.Delay(100);
            }
            if (i < presses) { Keys.Front(); Keys.Press(key); }
        }
        return false;
    }

    private static FrameworkElement Popped(string id) => InPopups().FirstOrDefault(e => Id(e) == id) ?? throw new InvalidOperationException($"{id} isn't showing");

    /// The Tasks page's rows, top to bottom, until they are `expected` (15 s); otherwise what they are.
    private static async Task RowsAsync(IReadOnlyList<string> expected, string what)
    {
        var until = DateTime.UtcNow.AddSeconds(15);
        while (true)
        {
            var shown = Shown(Root).Select(Id).Where(id => id.StartsWith("tasks.row.", StringComparison.Ordinal)).Select(id => id["tasks.row.".Length..]).ToList();
            var why = WalkProof.Order(shown, expected, what);
            if (why == null) return;
            if (DateTime.UtcNow > until) throw new InvalidOperationException(why);
            await Task.Delay(200);
        }
    }

    /// Polls pages-fixture-gateway.py's REST log for 10 s: null once Sort By › Due Date is saved and nothing else written.
    private static async Task<string?> TasksSavedAsync(string url, int mark)
    {
        var until = DateTime.UtcNow.AddSeconds(10);
        while (true)
        {
            var why = WalkProof.TasksSortSaved(await StandIn(url, "/__fixture/state"), mark, "due");
            if (why == null || DateTime.UtcNow > until) return why;
            await Task.Delay(250);
        }
    }

    // ------------------------------------------------------------------ Tasks Select's actions (after tasks-sort-select)

    private static async Task TasksSelectActionsAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var url = client.Session.Address.ToString();
        // Where tasks-sort-select left the page: Tasks › Home by Due Date, Select ended.
        if (Find("tasks.more") == null || Find("tasks.select.done") != null)
            throw new InvalidOperationException("the Tasks page isn't showing out of Select (this walk follows tasks-sort-select)");
        await RowsAsync(WalkProof.HomeByDue, "Home by Due Date");

        // Two rows picked, Mark Done by keyboard (Space on it): Select ends, both fold into Done.
        var mark = WalkProof.RestCount(await StandIn(url, "/__fixture/state"));
        await StartSelectAsync();
        await PickAsync(WalkProof.TasksDonePicks);
        var markDone = (Button)Need("tasks.select.mark-done");
        markDone.Focus(FocusState.Keyboard);
        if (!await KeysAsync(() => Keys.Press(Keys.Space), () => Find("tasks.select.done") == null, "Space on Mark Done"))
            Mouse.Click(markDone);
        await Until(() => Find("tasks.select.done") == null ? Root : null, "Select to end after Mark Done");
        await RowsAsync(WalkProof.HomeAfterDone, "Home after Mark Done");
        if (await RecordAsync(url, "/__fixture/state", st => WalkProof.TasksMarkedDone(st, mark, WalkProof.TasksDonePicks)) is { } done)
            throw new InvalidOperationException(done);
        await shot("tasks-select-done");

        // One row picked, Move To › Work by pointer: Select ends, the row leaves Home.
        mark = WalkProof.RestCount(await StandIn(url, "/__fixture/state"));
        await StartSelectAsync();
        await PickAsync([WalkProof.TasksMovePick]);
        Mouse.Click(Need("tasks.select.move"));
        var work = await Until(() => InPopups().FirstOrDefault(e => Id(e) == "tasks.move." + WalkProof.TasksMoveTo), "Work in Move To");
        Mouse.Click(work);
        await Until(() => Find("tasks.select.done") == null ? Root : null, "Select to end after Move To");
        await RowsAsync(WalkProof.HomeAfterMove, "Home after Move To");
        if (await RecordAsync(url, "/__fixture/state", st => WalkProof.TasksMovedTo(st, mark, [WalkProof.TasksMovePick], WalkProof.TasksMoveTo)) is { } moved)
            throw new InvalidOperationException(moved);
        await shot("tasks-select-moved");

        // The last open synthetic row: inspect the confirmation, then use its app-local peer, never OS pointer input.
        mark = WalkProof.RestCount(await StandIn(url, "/__fixture/state"));
        await StartSelectAsync();
        await PickAsync([WalkProof.TasksDeletePick]);
        Mouse.Click(Need("tasks.select.delete"));
        var title = TodoSelection.DeleteTitle(1);
        var dialog = await Until(() => InPopups().OfType<ContentDialog>().FirstOrDefault(d => d.Title as string == title), $"\u201C{title}\u201D");
        if (dialog.PrimaryButtonText != TasksCopy.Delete || dialog.CloseButtonText != TasksCopy.Cancel)
            throw new InvalidOperationException($"the confirmation reads {dialog.PrimaryButtonText} / {dialog.CloseButtonText}");
        if ((await StandIn(url, "/__fixture/state")).Arr("rest")?.OfType<JsonNode>().Skip(mark).Any(r => r.Str("method") == "DELETE") == true)
            throw new InvalidOperationException("a DELETE reached the gateway before the confirmation");
        await shot("tasks-select-actions");
        var delete = await Until(() => Shown(dialog).OfType<Button>().FirstOrDefault(b => b.Name == "PrimaryButton" || b.Content as string == TasksCopy.Delete),
            "the confirmation's Delete");
        Invoke(delete); // verified local fixture CRUD dialog; no OS pointer into a confirmation
        await Until(() => InPopups().OfType<ContentDialog>().All(d => d != dialog) && Find("tasks.select.done") == null ? Root : null,
            "the confirmation to close and Select to end");
        await RowsAsync([], "Home after Delete");
        if (await RecordAsync(url, "/__fixture/state", st => WalkProof.TasksDeleted(st, mark, [WalkProof.TasksDeletePick])) is { } deleted)
            throw new InvalidOperationException(deleted);
        await shot("tasks-select-deleted");
    }

    /// ⋯ › Select Tasks (Enter on it; UI Automation where keys don't arrive): Select's bar up.
    private static async Task StartSelectAsync()
    {
        await MoreMenuAsync("tasks.select.start");
        if (!await KeysAsync(() => Keys.Press(Keys.Enter), () => Find("tasks.select.done") != null, "Enter on Select Tasks"))
            Invoke(Popped("tasks.select.start"));
        await Until(() => Find("tasks.select.done"), "Select's bar");
    }

    /// A pointer click on each row picks it; then exactly those are picked.
    private static async Task PickAsync(IReadOnlyList<string> ids)
    {
        foreach (var id in ids)
        {
            // Select rebuilds the rows: aim only once this one is laid out (CI run 45009956343 clicked a 0×0 row,
            // "tasks.row.t_cleaning is off the screen at (261,133)-(261,133)", though the shot showed it a moment later).
            Mouse.Click(await Until(() => Find("tasks.row." + id) is FrameworkElement { ActualWidth: > 0, ActualHeight: > 0 } laid ? laid : null,
                $"{id} laid out"));
            await Until(() => Find("tasks.row." + id) is { } row && AutomationProperties.GetItemStatus(row) == "Selected" ? row : null, $"{id} picked");
        }
        var picked = Shown(Root).Where(e => Id(e).StartsWith("tasks.row.", StringComparison.Ordinal) && AutomationProperties.GetItemStatus(e) == "Selected")
            .Select(e => Id(e)["tasks.row.".Length..]).ToList();
        if (!picked.Order().SequenceEqual(ids.Order())) throw new InvalidOperationException($"picked {string.Join(", ", picked)}");
    }

    /// Polls a stand-in's record for 10 s: null once `check` passes, else its last words.
    private static async Task<string?> RecordAsync(string url, string path, Func<JsonNode, string?> check)
    {
        var until = DateTime.UtcNow.AddSeconds(10);
        while (true)
        {
            var why = check(await StandIn(url, path));
            if (why == null || DateTime.UtcNow > until) return why;
            await Task.Delay(250);
        }
    }

    // ------------------------------------------------------------------ File › Close Chat and Archive Chat

    private static async Task<ChatPage> OpenTripAsync()
    {
        Navigator.Go(new ChatDestination("default", WalkProof.TripStoredId, WalkProof.TripTitle));
        var page = await Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId == WalkProof.TripStoredId && p.MessageCount > 0 ? p : null,
            "Trip planning's messages");
        await Task.Delay(1000);   // the chat's own binding settles
        ((TextBox)Need(page, "chat.composer")).Focus(FocusState.Keyboard);
        return page;
    }

    private static async Task ChatKeysAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var url = client.Session.Address.ToString();
        var shell = ShellPage.Current ?? throw new InvalidOperationException("the shell isn't showing");

        // Close Chat (Ctrl+W): no question, the pane empty, the sidebar with the keyboard.
        var trip = await OpenTripAsync();
        if (ChatKeys.CanCloseChat(shell.KeyState()) != true) throw new InvalidOperationException("Close Chat is off with Trip planning open");
        if (!await KeysAsync(() => Keys.Press(Keys.W, ctrl: true), () => shell.PaneEmpty, "Ctrl+W"))
        {
            AppLog.Note("automation", "walk chat-keys: Ctrl+W unproven by keyboard; calling the shell's Close Chat");
            shell.CloseChat();
        }
        await Until(() => shell.PaneEmpty ? shell : null, "the pane to empty after Close Chat");
        await Until(() => FocusedIn() is { } f && Within(f, shell.SidebarList) ? f : null, "the sidebar to have the keyboard");
        if (ChatKeys.CanCloseChat(shell.KeyState())) throw new InvalidOperationException("Close Chat still acts with nothing open");
        await shot("chat-keys-closed");

        // Archive Chat (Ctrl+Alt+A): the sidebar's own PATCH, the chat leaves, the Mac's note with Undo.
        trip = await OpenTripAsync();
        // Archive is off while the gateway link is down (the Mac's item dims offline), and the link redials when a chat
        // opens; wait for the facts to allow it, and name the one that doesn't if they never do.
        var deadline = DateTime.UtcNow.AddSeconds(15);
        while (ChatKeys.Archive(shell.KeyState()) != ArchiveStep.Archive)
        {
            if (DateTime.UtcNow > deadline) throw new InvalidOperationException($"Archive Chat is off in Trip planning ({shell.KeyState()})");
            await Task.Delay(100);
        }
        var mark = ChatKeys.RestCount(await StandIn(url, "/__menus/state"));
        if (!await KeysAsync(() => Keys.Press(Keys.A, ctrl: true, alt: true), () => shell.PaneEmpty, "Ctrl+Alt+A"))
        {
            AppLog.Note("automation", "walk chat-keys: Ctrl+Alt+A unproven by keyboard; calling the shell's Archive Chat");
            await shell.ArchiveChatAsync();
        }
        await Until(() => shell.PaneEmpty ? shell : null, "the chat to leave after Archive Chat");
        string? why = "not read yet";
        var until = DateTime.UtcNow.AddSeconds(10);
        while (why != null && DateTime.UtcNow < until)
        {
            why = ChatKeys.ArchivedOverRest(await StandIn(url, "/__menus/state"), mark, WalkProof.TripStoredId, archived: true);
            if (why != null) await Task.Delay(200);
        }
        if (why != null) throw new InvalidOperationException(why);
        var label = ChatKeys.ArchivedLabel(WalkProof.TripTitle);
        await Until(() => Shown(Root).OfType<TextBlock>().FirstOrDefault(t => t.Text == label), $"\"{label}\"");
        await Until(() => Shown(Root).OfType<TextBlock>().FirstOrDefault(t => t.Text == Hermes.Core.Sessions.SessionStore.ArchivedWayBack), "the way back");
        await shot("chat-keys");
        await UndoPillLeavesAsync();   // [WIN-44] Services/ProofWalks.UndoPill.cs

        // The stand-in as it was: Trip planning unarchived through the same call.
        var hub = Features.Bots.ListsHub.Current ?? throw new InvalidOperationException("no lists");
        var back = ChatKeys.RestCount(await StandIn(url, "/__menus/state"));
        await hub.Sessions.SetArchivedAsync(new Hermes.Core.Sessions.SessionSummary
            { Id = WalkProof.TripStoredId, Profile = "default", Title = WalkProof.TripTitle, Archived = true }, false);
        if (ChatKeys.ArchivedOverRest(await StandIn(url, "/__menus/state"), back, WalkProof.TripStoredId, archived: false) is { } left)
            throw new InvalidOperationException(left);
    }

    // ------------------------------------------------------------------ the sidebar's Search, open and folded

    private static async Task SidebarSearchAsync(Func<string, Task> shot)
    {
        if (AppState.Client == null) throw new InvalidOperationException("not signed in");
        var shell = ShellPage.Current ?? throw new InvalidOperationException("the shell isn't showing");
        if (OpenQuicklyPanel.IsOpen) throw new InvalidOperationException("Open Quickly was already up");
        // SidebarTools draws the open sidebar's tools as a Grid (Search fills the row) and the rail's as a column.
        static bool Folded() => Find(SidebarSearch.ToolsAutomationId) is StackPanel;
        static bool Opened() => Find(SidebarSearch.ToolsAutomationId) is Grid;
        await Until(() => Find(SidebarSearch.ToolsAutomationId), "the sidebar's Search and New Chat");
        if (!Opened()) throw new InvalidOperationException("the sidebar started folded");

        // Open: a pointer click on Search is Ctrl+K's Open Quickly, its field with the keyboard.
        Mouse.Click(Need(SidebarSearch.SearchAutomationId));
        await Until(() => OpenQuicklyPanel.IsOpen ? Root : null, "Open Quickly from the sidebar's Search");
        await PanelAsync();
        await shot("sidebar-search-open");
        if (!await KeysAsync(() => Keys.Press(Keys.Escape), () => !OpenQuicklyPanel.IsOpen, "Esc"))
            throw new InvalidOperationException("Esc didn't close Open Quickly");

        // Ctrl+Shift+S folds the sidebar to the rail: the two side by side on one line, the hairline under them.
        await FoldAsync(shell, fold: true);
        await Task.Delay(500);   // the rail's layout settles
        var pane = (FrameworkElement)(shell.FindName("SidebarPane") ?? throw new InvalidOperationException("no SidebarPane"));
        var search = Need(SidebarSearch.SearchAutomationId);
        var compose = Need(SidebarSearch.ComposeAutomationId);
        if (WalkProof.RailToolsSideBySide(BoxOf(search), BoxOf(compose), BoxOf(pane)) is { } why) throw new InvalidOperationException(why);
        await shot("sidebar-search-rail");

        // The rail's Search clicked: Open Quickly, and the sidebar stays folded.
        Mouse.Click(search);
        await Until(() => OpenQuicklyPanel.IsOpen ? Root : null, "Open Quickly from the rail's Search");
        await PanelAsync();
        if (!Folded()) throw new InvalidOperationException("the sidebar opened when the rail's Search was clicked");
        await shot("sidebar-search");
        if (!await KeysAsync(() => Keys.Press(Keys.Escape), () => !OpenQuicklyPanel.IsOpen, "Esc in the rail"))
            throw new InvalidOperationException("Esc didn't close Open Quickly opened from the rail");
        if (!Folded()) throw new InvalidOperationException("the sidebar opened when Open Quickly closed");

        // Opened again, as it was (the fold is kept across launches).
        await FoldAsync(shell, fold: false);
    }

    /// Ctrl+Shift+S (ShellKeys.HideSidebar) until the sidebar is folded (`fold`) or open; where the keys don't arrive, a
    /// pointer click on the sidebar's own fold button.
    private static async Task FoldAsync(ShellPage shell, bool fold)
    {
        bool Done() => fold ? Find(SidebarSearch.ToolsAutomationId) is StackPanel : Find(SidebarSearch.ToolsAutomationId) is Grid;
        var what = fold ? "the sidebar folded" : "the sidebar open";
        FocusInWindow();
        if (!await KeysAsync(() => Keys.Press(Keys.S, ctrl: true, shift: true), Done, $"Ctrl+Shift+S ({what})"))
        {
            AppLog.Note("automation", $"walk sidebar-search: Ctrl+Shift+S unproven by keyboard; clicking the fold button");
            Mouse.Click((FrameworkElement)(shell.FindName("FoldButton") ?? throw new InvalidOperationException("no FoldButton")));
        }
        await Until(() => Done() ? Root : null, what);
    }

    private static WalkProof.Box BoxOf(FrameworkElement e)
    {
        var at = e.TransformToVisual(Root).TransformPoint(new Windows.Foundation.Point(0, 0));
        return new WalkProof.Box(at.X, at.Y, e.ActualWidth, e.ActualHeight);
    }

    // ------------------------------------------------------------------ Settings › About and Open-Source Licenses

    private static async Task AboutLicensesAsync(Func<string, Task> shot)
    {
        if (AppState.Client == null) throw new InvalidOperationException("not signed in");
        var notices = LicenseNotices.Load() ?? throw new InvalidOperationException("the app's licences don't load");
        Navigator.Open("settings", "about");
        await Until(() => Find("about.version"), "About's Version");
        await Until(() => Shown(Root).OfType<ToggleSwitch>().FirstOrDefault(t => Id(t) == "about.detailed-log"), "Detailed Logging on About");
        var licenses = await Until(() => Find("about.licenses"), "Open-Source Licenses on About");
        await Task.Delay(800);   // the gateway's version read settles
        await shot("about-page");

        // A click on Open-Source Licenses: the intro, then a row for every notice, Hermes first.
        Mouse.Click(licenses);
        var hermes = await Until(() => Find(WalkProof.LicenseRowId(LicenseNotices.First)), "Hermes's notice on Open-Source Licenses");
        await Until(() => Find("licenses.intro") is TextBlock t && t.Text == LicenseNotices.Intro ? t : null, "the licences' intro");
        var rows = await Until(() => Shown(Root).Where(e => e is Button && Id(e).StartsWith("license-row-", StringComparison.Ordinal)).Select(Id).ToList()
            is { } r && r.Count == notices.Count ? r : null, $"{notices.Count} notices");
        if (rows[0] != WalkProof.LicenseRowId(LicenseNotices.First)) throw new InvalidOperationException($"the first notice is {rows[0]}");
        await shot("about-licenses");

        // A click on Hermes's row: its text, the licence file's paragraphs joined back up.
        Mouse.Click(hermes);
        var text = LicenseNotices.Reflow(notices[0].Text);
        await Until(() => Find("license.text") is TextBlock t && t.Text == text ? t : null, "Hermes's licence text");
        await shot("about-license-text");
        await AboutBackAsync(shot, fromLicenseText: true);
    }

    // ------------------------------------------------------------------ Detailed Logging, found by Settings search

    private const string LogProbe = "/api/config";

    private static async Task AboutDetailedLogAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        if (!DetailedLogging.Enabled) throw new InvalidOperationException("Detailed Logging was already off (it starts on)");

        // Search Settings, "verbose": Detailed Logging is the first result.
        Navigator.Open("settings");
        var search = (TextBox)await Until(() => Find("settings.search"), "Search Settings");
        Mouse.Click(search);
        if (FocusedIn() != search) search.Focus(FocusState.Keyboard);
        await Until(() => FocusedIn() == search ? search : null, "the caret in Search Settings");
        if (!await KeysAsync(() => Keys.Type(WalkProof.LogSearchWord), () => search.Text == WalkProof.LogSearchWord, "typing verbose"))
        {
            search.Text = WalkProof.LogSearchWord;   // a WinUI TextBox's peer gives no managed Value pattern
            search.SelectionStart = search.Text.Length;
        }
        var result = await Until(() => Find(WalkProof.LogSearchResultId), "Detailed Logging in the results");
        var first = Shown(Root).Select(Id).FirstOrDefault(id => id.StartsWith("search.", StringComparison.Ordinal));
        if (first != WalkProof.LogSearchResultId) throw new InvalidOperationException($"the first result is {first}");
        await shot("about-detailed-log-search");

        // Enter opens the first result: About, with Detailed Logging scrolled to and marked.
        static ToggleSwitch? Switch() => Shown(Root).OfType<ToggleSwitch>().FirstOrDefault(t => Id(t) == "about.detailed-log");
        search.Focus(FocusState.Keyboard);
        if (!await KeysAsync(() => Keys.Press(Keys.Enter), () => Switch() != null, "Enter on the results"))
            Mouse.Click(result);
        var toggle = await Until(Switch, "Detailed Logging on About");
        if (!toggle.IsOn) throw new InvalidOperationException("Detailed Logging shows off");

        // Off and on again by keyboard (Space on the switch); a request each time; the app log and the saved choice.
        await ProbeAsync(client);
        await SwitchAsync(toggle, on: false);
        await ProbeAsync(client);
        await SwitchAsync(toggle, on: true);
        await ProbeAsync(client);
        await Task.Delay(500);
        var log = await Task.Run(ReadLog);
        if (WalkProof.DetailedLogToggled(log, "GET " + LogProbe) is { } why) throw new InvalidOperationException(why);
        await shot("about-detailed-log");
        await AboutBackAsync(shot, fromLicenseText: false);
    }

    /// Space on the switch (its Toggle pattern where keys don't arrive) until it reads `on`; then the app's own state and
    /// a fresh read of preferences.json (what the next launch reads) say the same.
    private static async Task SwitchAsync(ToggleSwitch toggle, bool on)
    {
        var what = $"Space on Detailed Logging ({(on ? "on" : "off")})";
        toggle.Focus(FocusState.Keyboard);
        await Until(() => FocusedIn() == toggle ? toggle : null, "the keyboard on Detailed Logging");
        if (!await KeysAsync(() => Keys.Press(Keys.Space), () => toggle.IsOn == on, what))
            Pattern<IToggleProvider>(toggle, PatternInterface.Toggle).Toggle();
        if (toggle.IsOn != on) throw new InvalidOperationException($"Detailed Logging shows {(toggle.IsOn ? "on" : "off")}");
        await Until(() => DetailedLogging.Enabled == on ? toggle : null, $"Detailed Logging {(on ? "on" : "off")} in the app");
        var saved = new FilePreferences(Path.Combine(AppPaths.Root, "preferences.json"));
        if (DetailedLogging.Load(saved) != on || saved.Get(DetailedLogging.Key) != (on ? "true" : "false"))
            throw new InvalidOperationException($"preferences.json keeps {DetailedLogging.Key} = {saved.Get(DetailedLogging.Key) ?? "nothing"}, not {(on ? "true" : "false")}");
    }

    /// One gateway request the log can show (GatewaySession's request line); its answer doesn't matter.
    private static async Task ProbeAsync(HermesClient client)
    {
        try { await client.Session.GetJsonAsync(LogProbe); }
        catch (Hermes.Core.Net.GatewayException e) { AppLog.Note("automation", $"walk about-detailed-log: the probe answered {e.Code}"); }
        await Task.Delay(300);
    }

    /// The app log as written so far (the rolled-over half first), read beside the app's own writes.
    private static string ReadLog()
    {
        var path = Path.Combine(AppPaths.Root, "logs", "hermes-hq.log");
        var text = new System.Text.StringBuilder();
        foreach (var file in new[] { path + ".1", path })
        {
            if (!File.Exists(file)) continue;
            using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream);
            text.Append(reader.ReadToEnd());
        }
        return text.ToString();
    }

    // ------------------------------------------------------------------ Quick Actions (Ctrl+Shift+K)

    private static async Task QuickActionsAsync(Func<string, Task> shot)
    {
        if (AppState.Client == null) throw new InvalidOperationException("not signed in");
        var hub = await Until(() => ListsHub.Current is { } h && h.Bots.HasRoster && h.Bots.Rows.Count > 0 ? h : null, "the roster");
        var first = hub.Bots.Rows[0];
        // The starter set seeds only into a list never shown before (QuickTileStore.ListToShow); start from one.
        var store = HermesHQ.Features.QuickActions.QuickActionsFeature.Store;
        if (store.Get(Hermes.Core.QuickActions.QuickTileStore.Key) != null)
        {
            AppLog.Note("automation", "walk quick-actions: cleared an earlier list so the starter set seeds");
            store.Set(Hermes.Core.QuickActions.QuickTileStore.Key, null);
        }
        if (Find("quick-actions.page") != null) throw new InvalidOperationException("Quick Actions was already showing");

        // Ctrl+Shift+K (the Mac's Edit › Quick Actions…, ⇧⌘K): the page, and not Ctrl+K's Open Quickly.
        FocusInWindow();
        if (!await KeysAsync(() => Keys.Press(Keys.K, ctrl: true, shift: true), () => Find("quick-actions.page") != null, "Ctrl+Shift+K"))
            throw new InvalidOperationException("Ctrl+Shift+K didn't open Quick Actions");
        if (OpenQuicklyPanel.IsOpen) throw new InvalidOperationException("Ctrl+Shift+K opened Open Quickly too");
        var page = await Until(() => Find("quick-actions.page"), "quick-actions.page");

        // The starter set for the roster's first bot, read as a screen reader reads each tile.
        var starter = Hermes.Core.QuickActions.QuickTileStore.Starter(first.Id, first.Model.DisplayName);
        await TilesAsync(page, WalkProof.QuickStarterIds, "the starter set");
        foreach (var tile in starter)
        {
            var name = AutomationProperties.GetName(Need(page, WalkProof.QuickTileAutomationId(tile.Id)));
            var expected = $"{tile.Name}, {tile.Subtitle(first.Model.DisplayName)}";
            if (name != expected) throw new InvalidOperationException($"a starter tile reads \u201C{name}\u201D, not \u201C{expected}\u201D");
        }
        var edit = (Button)Need(page, "quick-actions.edit");
        if (edit.Content as string != "Edit") throw new InvalidOperationException($"the page's button reads {edit.Content}, not Edit");
        await shot("quick-actions");

        // Edit, by pointer: the − badges and the ＋ Add Action tile; the button reads Done.
        Mouse.Click(edit);
        await Until(() => FindIn(page, "quick-actions.add-tile") != null && edit.Content as string == "Done" ? edit : null, "Edit mode");

        // Move Down on Memo, by keyboard: Shift+F10 opens the tile's menu (its context menu), ↓ to Move Down, Enter.
        var moved = WalkProof.QuickStarterIds.ToList();
        var at = moved.IndexOf(WalkProof.QuickMovedDown);
        (moved[at], moved[at + 1]) = (moved[at + 1], moved[at]);
        var memo = (Control)Need(page, WalkProof.QuickTileAutomationId(WalkProof.QuickMovedDown));
        memo.Focus(FocusState.Keyboard);
        if (!await KeysAsync(() => Keys.Press(Keys.F10, shift: true), () => MenuItem("Move Down") != null, "Shift+F10 on Memo"))
            memo.ContextFlyout.ShowAt(memo);
        var moveDown = await Until(() => MenuItem("Move Down"), "Move Down in the tile's menu");
        if (!(await KeyToItemAsync("Move Down", Keys.Down, 5)
              && await KeysAsync(() => Keys.Press(Keys.Enter), () => TileIds(page).SequenceEqual(moved), "Enter on Move Down")))
            Invoke(moveDown);
        await TilesAsync(page, moved, "the tiles after Move Down");

        // Remove Search Chats, by pointer: its − badge.
        var removed = starter.Single(t => t.Id == WalkProof.QuickRemoved);
        // Laid out, not just in the tree: CI run 45104481282 found the badge while Move Down's reflow was re-creating
        // the tiles (a 0×0 box at (253,81)) and the click was refused as off the screen.
        var badge = await Until(() => Shown(page).OfType<Button>()
            .FirstOrDefault(b => Id(b) == "quick-tile.remove" && AutomationProperties.GetName(b) == $"Remove {removed.Name}"
                && b.IsLoaded && b.ActualWidth > 0 && b.ActualHeight > 0), $"Remove {removed.Name} laid out");
        Mouse.Click(badge);
        await TilesAsync(page, WalkProof.QuickEditedIds, "the tiles after Remove");
        await shot("quick-actions-editing");

        // Done, by keyboard (Space on it): out of Edit, and the list saved in that order.
        edit.Focus(FocusState.Keyboard);
        if (!await KeysAsync(() => Keys.Press(Keys.Space), () => edit.Content as string == "Edit", "Space on Done"))
            Mouse.Click(edit);
        await Until(() => edit.Content as string == "Edit" && FindIn(page, "quick-actions.add-tile") == null ? edit : null, "Edit mode to end");
        if (Shown(page).Any(e => Id(e) == "quick-tile.remove")) throw new InvalidOperationException("− badges stayed after Done");
        if (WalkProof.QuickTilesSaved(store, WalkProof.QuickEditedIds) is { } held) throw new InvalidOperationException(held);
        var onDisk = new Hermes.Core.Composer.JsonFileStore(Path.Combine(AppPaths.Root, "quick-actions.json"));
        if (WalkProof.QuickTilesSaved(onDisk, WalkProof.QuickEditedIds) is { } written) throw new InvalidOperationException($"quick-actions.json: {written}");
        await shot("quick-actions-edit");

        // A tile that opens a place: Add Task, clicked, opens the Tasks page.
        Destination? went = null;
        void Seen(Destination d) => went ??= d;
        Navigator.Requested += Seen;
        try
        {
            Mouse.Click(Need(page, WalkProof.QuickTileAutomationId(WalkProof.QuickPlaceTile)));
            await Until(() => went != null ? Root : null, "Add Task to open something");
        }
        finally { Navigator.Requested -= Seen; }
        if (went is not PlaceDestination { PlaceId: WalkProof.QuickPlaceId })
            throw new InvalidOperationException($"Add Task went to {went}, not the {WalkProof.QuickPlaceId} page");
        await Until(() => Find("quick-actions.page") == null && Find("tasks.more") != null ? Root : null, "the Tasks page from Add Task");
    }

    /// The page's tiles, top to bottom, by their QuickTile ids (the − badges' "quick-tile.remove" left out).
    private static List<string> TileIds(FrameworkElement page) =>
        [.. Shown(page).Select(Id).Where(id => id.StartsWith("quick-tile-", StringComparison.Ordinal)).Select(id => id["quick-tile-".Length..])];

    /// The page's tiles until they are `expected` (15 s); otherwise what they are.
    private static async Task TilesAsync(FrameworkElement page, IReadOnlyList<string> expected, string what)
    {
        var until = DateTime.UtcNow.AddSeconds(15);
        while (true)
        {
            var why = WalkProof.Order(TileIds(page), expected, what);
            if (why == null) return;
            if (DateTime.UtcNow > until) throw new InvalidOperationException(why);
            await Task.Delay(200);
        }
    }

    private static MenuFlyoutItem? MenuItem(string text) => InPopups().OfType<MenuFlyoutItem>().FirstOrDefault(i => i.Text == text);

    /// Presses `key` (at most `presses` times) until the keyboard is on the open menu's item reading `text`.
    private static async Task<bool> KeyToItemAsync(string text, ushort key, int presses)
    {
        for (var i = 0; i <= presses; i++)
        {
            var until = DateTime.UtcNow.AddSeconds(i == 0 ? 2 : 10);
            while (DateTime.UtcNow < until)
            {
                if (FocusedIn() is MenuFlyoutItem item && item.Text == text) return true;
                await Task.Delay(100);
            }
            if (i < presses) { Keys.Front(); Keys.Press(key); }
        }
        AppLog.Note("automation", $"walk keys: ↓ didn't reach {text}; using UI Automation");
        return false;
    }

    // ------------------------------------------------------------------ Quick Action tiles that run (WIN-24)

    /// The walk's tiles saved as the person's list (QuickTileStore.Save, as Done saves an edit; the starter set has
    /// neither kind), then Ctrl+Shift+K: the page with them, `run` drawn switched on.
    private static async Task<FrameworkElement> QuickTilesPageAsync(string sendBotName, string run)
    {
        if (Find("quick-actions.page") != null) throw new InvalidOperationException("Quick Actions was already showing");
        var store = HermesHQ.Features.QuickActions.QuickActionsFeature.Store;
        Hermes.Core.QuickActions.QuickTileStore.Save(new([WalkProof.QuickSendTile(sendBotName), WalkProof.QuickRunTile()], seeded: true), store);
        string[] ids = [WalkProof.QuickSendTileId, WalkProof.QuickRunTileId];
        if (WalkProof.QuickTilesSaved(store, ids) is { } saved) throw new InvalidOperationException(saved);
        AppLog.Note("automation", "walk quick-action: saved the walk's Send a Message and Run Job tiles as the list");
        FocusInWindow();
        if (!await KeysAsync(() => Keys.Press(Keys.K, ctrl: true, shift: true), () => Find("quick-actions.page") != null, "Ctrl+Shift+K"))
            throw new InvalidOperationException("Ctrl+Shift+K didn't open Quick Actions");
        var page = await Until(() => Find("quick-actions.page"), "quick-actions.page");
        await TilesAsync(page, ids, "the walk's tiles");
        var tile = Need(page, WalkProof.QuickTileAutomationId(run));
        if (AutomationProperties.GetItemStatus(tile) == "Unavailable") throw new InvalidOperationException($"{run} is drawn switched off");
        return page;
    }

    private static async Task QuickActionSendAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var url = client.Session.Address.ToString();
        var hub = await Until(() => ListsHub.Current is { } h && h.Bots.HasRoster && h.Bots.Bot(WalkProof.QuickSendBot) != null ? h : null, "the roster");
        var bot = hub.Bots.Bot(WalkProof.QuickSendBot)!;
        var storedId = await hub.Bots.BotChatIdAsync(WalkProof.QuickSendBot);
        var page = await QuickTilesPageAsync(bot.Model.DisplayName, WalkProof.QuickSendTileId);
        await shot("quick-action-tiles");

        // A click on Send a Message: the bot's own chat opens and the words go as typed words do.
        var mark = WalkProof.LastCallAt(await StandIn(url, "/__menus/state"));
        Mouse.Click(Need(page, WalkProof.QuickTileAutomationId(WalkProof.QuickSendTileId)));
        var chat = await Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId == storedId ? p : null, "the bot's chat from the tile");
        if (await RecordAsync(url, "/__menus/state", st => WalkProof.QuickSentInChat(st, mark, WalkProof.QuickSendWords)) is { } why)
            throw new InvalidOperationException(why);
        await Until(() => !chat.IsBusy ? chat : null, "the reply to settle", 60);
        var box = (TextBox)Need(chat, "chat.composer");
        if (box.Text == WalkProof.QuickSendWords) throw new InvalidOperationException("the words stayed in the message box");
        await shot("quick-action-send");
    }

    private static async Task QuickActionRunAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var url = client.Session.Address.ToString();
        var hub = await Until(() => ListsHub.Current is { } h && h.Bots.HasRoster && h.Bots.Rows.Count > 0 ? h : null, "the roster");
        var page = await QuickTilesPageAsync(hub.Bots.Bot(WalkProof.QuickSendBot)?.Model.DisplayName ?? WalkProof.QuickSendBot, WalkProof.QuickRunTileId);

        // A click on Run Job: Run Now's calls without the wait; the page stays and says so.
        var mark = WalkProof.RestCount(await StandIn(url, "/__fixture/state"));
        Mouse.Click(Need(page, WalkProof.QuickTileAutomationId(WalkProof.QuickRunTileId)));
        var notice = WalkProof.QuickRunNotice(WalkProof.QuickRunJobName);
        await Until(() => Shown(page).OfType<InfoBar>().FirstOrDefault(b => b.IsOpen && b.Message == notice), $"\u201C{notice}\u201D");
        await shot("quick-action-run");
        if (Find("quick-actions.page") != page) throw new InvalidOperationException("Run Job left the Quick Actions page");
        if (await RecordAsync(url, "/__fixture/state", st => WalkProof.QuickJobTriggered(st, mark, WalkProof.QuickRunJobId, WalkProof.QuickRunJobOwner)) is { } why)
            throw new InvalidOperationException(why);
    }

    // ------------------------------------------------------------------ New Chat With… (Ctrl+Shift+N)

    private static async Task NewChatSheetAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var url = client.Session.Address.ToString();
        await Until(() => ListsHub.Current is { } h && h.Bots.HasRoster && h.Bots.Bot(WalkProof.NewChatBot) != null ? h : null, "the roster");
        if (NewChatDialog() != null) throw new InvalidOperationException("the New Chat sheet was already up");

        // Ctrl+Shift+N (File › New Chat With…, the Mac's ⇧⌘N): the sheet, Hermes's pill first, the projects listed.
        FocusInWindow();
        if (!await KeysAsync(() => Keys.Press(Keys.N, ctrl: true, shift: true), () => NewChatDialog() != null, "Ctrl+Shift+N"))
            throw new InvalidOperationException("Ctrl+Shift+N didn't open the New Chat sheet");
        var dialog = await Until(NewChatDialog, "new-chat-sheet");
        if (dialog.Title as string != Hermes.Core.Sessions.NewChatText.Title || dialog.PrimaryButtonText != Hermes.Core.Sessions.NewChatText.Start)
            throw new InvalidOperationException($"the sheet reads {dialog.Title} / {dialog.PrimaryButtonText}");
        var pills = await Until(() => Pills() is { Count: > 1 } p ? p : null, "the sheet's bots");
        var second = Hermes.Core.Sessions.NewChatText.BotId(WalkProof.NewChatBot);
        if (Id(pills[0]) != Hermes.Core.Sessions.NewChatText.BotId("default") || Id(pills[1]) != second)
            throw new InvalidOperationException($"the pills are {string.Join(", ", pills.Select(Id))}");
        var rowId = Hermes.Core.Sessions.NewChatText.RowId(new(WalkProof.NewChatFolder, WalkProof.NewChatProject));
        await Until(() => InPopups().FirstOrDefault(e => Id(e) == rowId), $"{WalkProof.NewChatProject} in the sheet");
        await shot("new-chat-sheet");

        // The second bot, by keyboard: Space on its pill lights it (the pills are drawn again, Research's checked).
        static ToggleButton? Pill(string id) => InPopups().OfType<ToggleButton>().FirstOrDefault(p => Id(p) == id);
        bool Lit() => Pill(second) is { IsChecked: true } && Pills().Count(p => p.IsChecked == true) == 1;
        if (Lit()) throw new InvalidOperationException($"{WalkProof.NewChatBot} was lit before its pill was pressed");
        // [WIN-30A] The keyboard on the pill itself before Space (not Start Chat, the dialog's default button).
        pills[1].Focus(FocusState.Keyboard);
        await Until(() => FocusedIn() == pills[1] ? pills[1] : null, "the keyboard on the second pill");
        if (!await KeysAsync(() => Keys.Press(Keys.Space), Lit, "Space on the second pill"))
            Mouse.Click(Pill(second) ?? throw new InvalidOperationException($"{second} isn't showing"));
        await Until(() => Lit() ? Root : null, $"{WalkProof.NewChatBot} lit");
        // Space selects and starts nothing: the sheet is still up, the keyboard still on that pill, no chat made.
        await Task.Delay(500);
        if (NewChatDialog() == null) throw new InvalidOperationException("Space on a pill started a chat (only Return or Start Chat starts)");
        if (FocusedIn() != Pill(second)) throw new InvalidOperationException($"the keyboard left {WalkProof.NewChatBot}'s pill after Space ({Id(FocusedIn() ?? Root)})");

        // Its project, by keyboard: Space on Reading's row starts the chat there.
        var row = (Button)await Until(() => InPopups().FirstOrDefault(e => Id(e) == rowId), $"{WalkProof.NewChatProject} for {WalkProof.NewChatBot}");
        var mark = WalkProof.RpcCount(await StandIn(url, "/__fixture/state"));
        Destination? went = null;
        void Seen(Destination d) => went ??= d;
        Navigator.Requested += Seen;
        try
        {
            row.Focus(FocusState.Keyboard);
            if (!await KeysAsync(() => Keys.Press(Keys.Space), () => NewChatDialog() == null, $"Space on {WalkProof.NewChatProject}"))
                Mouse.Click(row);
            await Until(() => NewChatDialog() == null ? Root : null, "the sheet to close");
            await Until(() => went != null ? Root : null, "the new chat to open");
        }
        finally { Navigator.Requested -= Seen; }

        // The stand-in's record: one session.create for Research in Reading's folder, nothing sent.
        string? why = "not read yet";
        var until = DateTime.UtcNow.AddSeconds(10);
        while (why != null && DateTime.UtcNow < until)
        {
            why = WalkProof.NewChatStartedIn(await StandIn(url, "/__fixture/state"), mark, WalkProof.NewChatBot, WalkProof.NewChatFolder);
            if (why != null) await Task.Delay(200);
        }
        if (why != null) throw new InvalidOperationException(why);

        // The new chat open, its message box with the keyboard.
        if (went is not ChatDestination chat || chat.Profile != WalkProof.NewChatBot)
            throw new InvalidOperationException($"Start opened {went}, not a chat with {WalkProof.NewChatBot}");
        var opened = await Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId == chat.StoredId ? p : null, "the new chat");
        var box = (TextBox)Need(opened, "chat.composer");
        await Until(() => FocusedIn() == box ? box : null, "the new chat's message box to have the keyboard");
        await shot("new-chat-sheet-started");
    }

    private static ContentDialog? NewChatDialog() => InPopups().OfType<ContentDialog>().FirstOrDefault(d => Id(d) == "new-chat-sheet");

    /// The sheet's bot pills, in order.
    private static List<ToggleButton> Pills() =>
        [.. InPopups().OfType<ToggleButton>().Where(p => Id(p).StartsWith("new-chat-bot-", StringComparison.Ordinal))];

    // ------------------------------------------------------------------ keys

    /// Brings the window to the front, sends the keys, and waits 10 s for `landed`. False (and a note) when it never did.
    private static async Task<bool> KeysAsync(Func<bool> send, Func<bool> landed, string what)
    {
        Keys.Front();
        if (send())
        {
            var until = DateTime.UtcNow.AddSeconds(10);
            while (DateTime.UtcNow < until)
            {
                if (landed()) { AppLog.Note("automation", $"walk keys: {what} by keyboard"); return true; }
                await Task.Delay(100);
            }
        }
        AppLog.Note("automation", $"walk keys: {what} didn't reach the window (foreground {(Keys.InFront() ? "ours" : "another")}); using UI Automation");
        return landed();
    }

    /// Windows' own keyboard input (user32 SendInput), as a person's keys arrive.
    private static class Keys
    {
        public const ushort Enter = 0x0D, Escape = 0x1B, Slash = 0xBF, Shift = 0x10, Control = 0x11, Menu = 0x12, Space = 0x20, Right = 0x27,
            Down = 0x28, A = 0x41, F = 0x46, G = 0x47, H = 0x48, I = 0x49, K = 0x4B, N = 0x4E, S = 0x53, W = 0x57, X = 0x58, F3 = 0x72, F10 = 0x79;
        private const uint Extended = 0x0001, KeyUp = 0x0002, Unicode = 0x0004;

        [StructLayout(LayoutKind.Sequential)]
        public struct KeybdInput { public ushort Vk; public ushort Scan; public uint Flags; public uint Time; public IntPtr Extra; }

        [StructLayout(LayoutKind.Sequential)]
        public struct MouseInput { public int Dx; public int Dy; public uint Data; public uint Flags; public uint Time; public IntPtr Extra; }

        [StructLayout(LayoutKind.Explicit)]
        public struct Union { [FieldOffset(0)] public MouseInput Mouse; [FieldOffset(0)] public KeybdInput Key; }

        [StructLayout(LayoutKind.Sequential)]
        public struct Input { public uint Type; public Union U; }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint SendInput(uint count, Input[] inputs, int size);

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        public static IntPtr Handle => WinRT.Interop.WindowNative.GetWindowHandle(App.Window!);

        public static bool InFront() => GetForegroundWindow() == Handle;

        // Normal WinUI activation only. Never send keys to induce a foreground change.
        public static void Front()
        {
            if (InFront() || Automation.AppOnly) return;
            App.Window?.Activate();
        }

        public static bool Eligible(Window? target)
        {
            target ??= App.Window;
            if (!Automation.Enabled || (!Automation.AppOnly && Automation.Desktop == null)
                || target?.Content is not FrameworkElement { XamlRoot: { } root } content
                || ShellPage.Current is not { IsLoaded: true } || AppState.Client is not { } client
                || !Automation.FixtureAddress(client.Session.Address.ToString())) return false;
            if (client.Questions.Waiting().Count != 0) return false;
            var shown = Shown(content).Concat(VisualTreeHelper.GetOpenPopupsForXamlRoot(root)
                .Where(p => p.IsOpen && p.Child != null).SelectMany(p => Shown(p.Child)));
            // Sign-in/password fields, approval cards, and unclassified modal dialogs never receive OS input.
            if (shown.Any(e => !DesktopProof.SafeControl(Id(e), e is PasswordBox, e is ContentDialog))) return false;
            for (var focus = FocusManager.GetFocusedElement(root) as DependencyObject; focus != null; focus = VisualTreeHelper.GetParent(focus))
                if (focus is WebView2) return false; // no OS keys into an embedded page or its prompts
            return GetForegroundWindow() == WinRT.Interop.WindowNative.GetWindowHandle(target);
        }

        private static Input Key(ushort vk, uint flags, ushort scan = 0) =>
            new() { Type = 1, U = new Union { Key = new KeybdInput { Vk = vk, Scan = scan, Flags = flags } } };

        public static Input MouseButton(uint flags) => new() { Type = 0, U = new Union { Mouse = new MouseInput { Flags = flags } } };

        public static bool Send(Input[] inputs, Window? target = null) =>
            Eligible(target) && SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>()) == inputs.Length;

        public static bool Type(string text) =>
            Send([.. text.SelectMany(c => new[] { Key(0, Unicode, c), Key(0, Unicode | KeyUp, c) })]);

        public static bool Press(ushort vk, bool ctrl = false, bool alt = false, bool shift = false, Window? target = null)
        {
            var keys = new List<Input>();
            // The arrows are extended keys (their own block, not the number pad's). `alt` is the left Alt key (not
            // extended), so the shell's AltGr check (ChatKeys.Takes) lets Ctrl+Alt chords act.
            var extended = vk is >= 0x21 and <= 0x28 ? Extended : 0;
            if (ctrl) keys.Add(Key(Control, 0));
            if (shift) keys.Add(Key(Shift, 0));
            if (alt) keys.Add(Key(Menu, 0));
            keys.Add(Key(vk, extended));
            keys.Add(Key(vk, extended | KeyUp));
            if (alt) keys.Add(Key(Menu, KeyUp));
            if (shift) keys.Add(Key(Shift, KeyUp));
            if (ctrl) keys.Add(Key(Control, KeyUp));
            return Send([.. keys], target);
        }
    }


    /// Windows' own pointer input: the cursor put on an element's middle and the left button pressed and let go there.
    private static class Mouse
    {
        private const uint LeftDown = 0x0002, LeftUp = 0x0004;

        [StructLayout(LayoutKind.Sequential)]
        private struct Point { public int X; public int Y; }

        [DllImport("user32.dll")]
        private static extern bool ClientToScreen(IntPtr hwnd, ref Point point);

        [DllImport("user32.dll")]
        private static extern bool SetCursorPos(int x, int y);

        [DllImport("user32.dll")]
        private static extern int GetSystemMetrics(int index);

        [DllImport("user32.dll")]
        private static extern IntPtr WindowFromPoint(Point point);

        [DllImport("user32.dll")]
        private static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

        [DllImport("user32.dll")]
        private static extern IntPtr GetWindow(IntPtr hwnd, uint command);

        [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
        private static extern int GetWindowLong(IntPtr hwnd, int index);

        private const int VirtualLeft = 76, VirtualTop = 77, VirtualWidth = 78, VirtualHeight = 79, StyleIndex = -16;
        private const uint RootAncestor = 2, Owner = 4;

        /// [WIN-39] The window at the point as ClickAim judges it: its process, owners (nearest first) and style.
        private static AimTarget Target(IntPtr window)
        {
            GetWindowThreadProcessId(window, out var pid);
            var owners = new List<long>();
            for (var o = GetWindow(window, Owner); o != IntPtr.Zero && owners.Count < 16; o = GetWindow(o, Owner)) owners.Add(o.ToInt64());
            return new AimTarget(window.ToInt64(), (int)pid, owners, unchecked((uint)GetWindowLong(window, StyleIndex)));
        }

        /// The element sits in an open popup (a flyout, a menu or its submenu), not in the window's own content.
        private static bool InOpenPopup(FrameworkElement element)
        {
            if (element.XamlRoot is not { } xr) return false;
            var roots = VisualTreeHelper.GetOpenPopupsForXamlRoot(xr).Select(p => p.Child).OfType<DependencyObject>().ToHashSet();
            for (DependencyObject? at = element; at != null; at = VisualTreeHelper.GetParent(at))
                if (roots.Contains(at)) return true;
            return false;
        }

        /// The element's box on the screen (physical pixels): left, top, right, bottom.
        private static (int L, int T, int R, int B) OnScreen(FrameworkElement element)
        {
            var scale = element.XamlRoot?.RasterizationScale ?? 1;
            var to = element.TransformToVisual(null);
            var a = to.TransformPoint(new Windows.Foundation.Point(0, 0));
            var b = to.TransformPoint(new Windows.Foundation.Point(element.ActualWidth, element.ActualHeight));
            var tl = new Point { X = (int)Math.Round(a.X * scale), Y = (int)Math.Round(a.Y * scale) };
            var br = new Point { X = (int)Math.Round(b.X * scale), Y = (int)Math.Round(b.Y * scale) };
            ClientToScreen(Keys.Handle, ref tl);
            ClientToScreen(Keys.Handle, ref br);
            return (tl.X, tl.Y, br.X, br.Y);
        }

        /// The part of the element's box on the desktop (none: null).
        private static (int L, int T, int R, int B)? Visible((int L, int T, int R, int B) box)
        {
            int vl = GetSystemMetrics(VirtualLeft), vt = GetSystemMetrics(VirtualTop);
            int vr = vl + GetSystemMetrics(VirtualWidth), vb = vt + GetSystemMetrics(VirtualHeight);
            int l = Math.Max(box.L, vl), t = Math.Max(box.T, vt), r = Math.Min(box.R, vr), b = Math.Min(box.B, vb);
            return r - l >= 4 && b - t >= 4 ? (l, t, r, b) : null;
        }

        /// [WIN-30A] The walk's own aim: the cursor on the middle of the part of the element the desktop shows. On a
        /// screen smaller than the window (the CI runner's) the window hangs off an edge and SetCursorPos clamps a
        /// point past it onto whatever is at the edge (Quick Actions' Edit, at the window's top right, was never hit).
        /// An element wholly off the desktop moves the window onto it first; a point another window covers is refused
        /// (with what is there) rather than clicked.
        public static void Click(FrameworkElement element)
        {
            if (Automation.AppOnly) throw new InvalidOperationException("desktop pointer input is excluded from an app-only run");
            PointAt(element, click: true);
        }

        public static void MoveOffPill() => PointAt(Need("shell.account"), click: false);

        private static void PointAt(FrameworkElement element, bool click)
        {
            Keys.Front();
            if (Automation.AppOnly || element.XamlRoot != Root.XamlRoot || !Keys.Eligible(App.Window))
                throw new InvalidOperationException("refused pointer outside the foreground fixture window or over a prompt");
            var box = OnScreen(element);
            var seen = Visible(box);
            if (seen == null || (seen.Value.R - seen.Value.L) * 2 < box.R - box.L || (seen.Value.B - seen.Value.T) * 2 < box.B - box.T)
            {
                var window = App.Window!.AppWindow;
                var client = new Point();
                ClientToScreen(Keys.Handle, ref client);
                // The client area's top left onto the desktop's (the frame's invisible border stays off it).
                window.Move(new Windows.Graphics.PointInt32(window.Position.X + GetSystemMetrics(VirtualLeft) - client.X,
                    window.Position.Y + GetSystemMetrics(VirtualTop) - client.Y));
                AppLog.Note("automation", $"walk pointer: {Id(element)} was off the screen at ({box.L},{box.T})-({box.R},{box.B}); window moved onto it");
                box = OnScreen(element);
                seen = Visible(box) ?? throw new InvalidOperationException($"{Id(element)} is off the screen at ({box.L},{box.T})-({box.R},{box.B})");
            }
            var (l, t, r, b) = seen.Value;
            var point = new Point { X = (l + r) / 2, Y = (t + b) / 2 };
            // [WIN-39] A menu WinUI draws in a window of its own (Move To's submenu) is the app's own: ClickAim accepts it,
            // and still refuses another program's window or another of the app's windows over the point.
            var under = GetAncestor(WindowFromPoint(point), RootAncestor);
            var verdict = ClickAim.Judge(Target(under), Keys.Handle.ToInt64(), Environment.ProcessId, InOpenPopup(element));
            if (ClickAim.Refusal(verdict, Id(element), point.X, point.Y, under.ToInt64()) is { } refused)
                throw new InvalidOperationException(refused);
            if (verdict == AimVerdict.OwnPopup) AppLog.Note("automation", $"walk pointer: {Id(element)} is in the app's own popup window (0x{under.ToInt64():x})");
            if (!Keys.Eligible(App.Window) || GetAncestor(WindowFromPoint(point), RootAncestor) != under || !SetCursorPos(point.X, point.Y))
                throw new InvalidOperationException("pointer target moved");
            if (!click) return;
            if (GetAncestor(WindowFromPoint(point), RootAncestor) != under || !Keys.Send([Keys.MouseButton(LeftDown), Keys.MouseButton(LeftUp)]))
                throw new InvalidOperationException($"the click on {Id(element)} wasn't sent");
            AppLog.Note("automation", $"walk pointer: clicked {Id(element)} at ({point.X},{point.Y})");
        }
    }

    // ------------------------------------------------------------------ UI Automation helpers

    private static async Task<JsonNode> StandIn(string url, string path)
    {
        var lifetime = App.Window!.Lifetime;
        lifetime.RequireOpen();
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        var json = await http.GetStringAsync(url.TrimEnd('/') + path, lifetime.StopToken);
        lifetime.RequireOpen();
        return JsonNode.Parse(json)!;
    }

    private static string Id(DependencyObject e) => AutomationProperties.GetAutomationId(e) ?? "";

    private static FrameworkElement Root => (FrameworkElement)App.Window!.Content;

    private static IEnumerable<FrameworkElement> Shown(DependencyObject node)
    {
        if (node is UIElement { Visibility: Visibility.Collapsed }) yield break;
        if (node is FrameworkElement fe) yield return fe;
        var count = VisualTreeHelper.GetChildrenCount(node);
        for (var i = 0; i < count; i++)
            foreach (var child in Shown(VisualTreeHelper.GetChild(node, i))) yield return child;
    }

    private static IEnumerable<FrameworkElement> InPopups() =>
        Root.XamlRoot is { } xr ? VisualTreeHelper.GetOpenPopupsForXamlRoot(xr).Where(p => p.Child != null).SelectMany(p => Shown(p.Child)) : [];

    /// The element with the keyboard, in the window or an open popup.
    private static FrameworkElement? FocusedIn() =>
        Root.XamlRoot is { } xr ? FocusManager.GetFocusedElement(xr) as FrameworkElement : null;

    /// The keyboard somewhere in the window for the shell's own keys: the open chat's message box, else the account button.
    private static void FocusInWindow()
    {
        if (ChatPage.Current is { IsLoaded: true } chat && FindIn(chat, "chat.composer") is TextBox box) box.Focus(FocusState.Keyboard);
        else if (Find("shell.account") is Control account) account.Focus(FocusState.Keyboard);
    }

    private static bool Within(DependencyObject element, DependencyObject ancestor)
    {
        for (var at = element; at != null; at = VisualTreeHelper.GetParent(at))
            if (ReferenceEquals(at, ancestor)) return true;
        return false;
    }

    private static IEnumerable<DependencyObject> PopupRoots() =>
        Root.XamlRoot is { } xr ? VisualTreeHelper.GetOpenPopupsForXamlRoot(xr).Where(p => p.Child != null).Select(p => (DependencyObject)p.Child) : [];

    /// The element with `id` under `roots`, shown or collapsed.
    private static FrameworkElement? All(IEnumerable<DependencyObject> roots, string id)
    {
        foreach (var root in roots)
        {
            if (root is FrameworkElement fe && Id(fe) == id) return fe;
            var count = VisualTreeHelper.GetChildrenCount(root);
            for (var i = 0; i < count; i++)
                if (All([VisualTreeHelper.GetChild(root, i)], id) is { } hit) return hit;
        }
        return null;
    }

    private static FrameworkElement? Find(string id) => Shown(Root).FirstOrDefault(e => Id(e) == id);

    private static FrameworkElement? FindIn(DependencyObject under, string id) => Shown(under).FirstOrDefault(e => Id(e) == id);

    private static FrameworkElement Need(string id) => Find(id) ?? throw new InvalidOperationException($"{id} isn't showing");

    private static FrameworkElement Need(DependencyObject under, string id) => FindIn(under, id) ?? throw new InvalidOperationException($"{id} isn't showing");

    private static T Pattern<T>(FrameworkElement element, PatternInterface pattern) where T : class =>
        FrameworkElementAutomationPeer.CreatePeerForElement(element)?.GetPattern(pattern) as T
        ?? throw new InvalidOperationException($"{Id(element)} has no {pattern} pattern");

    private static void Invoke(FrameworkElement element)
    {
        if (FrameworkElementAutomationPeer.CreatePeerForElement(element) is IInvokeProvider invoke) invoke.Invoke();
        else throw new InvalidOperationException($"{Id(element)} can't be invoked");
    }

    /// Waits 15 s (never under 10) for `get` to give something.
    private static async Task<T> Until<T>(Func<T?> get, string what, int seconds = 15) where T : class
    {
        var lifetime = App.Window!.Lifetime;
        var until = DateTime.UtcNow.AddSeconds(Math.Max(10, seconds));
        while (true)
        {
            lifetime.RequireOpen(); // a queued poll is not permission to touch a closing page
            if (get() is { } found) return found;
            if (DateTime.UtcNow > until) throw new TimeoutException($"waited too long for {what}");
            await Task.Delay(100, lifetime.StopToken);
        }
    }

    // ------------------------------------------------------------------ group chats in the sidebar (WIN-35)

    private static async Task SidebarGroupChatsAsync(Func<string, Task> shot)
    {
        if (AppState.Client == null) throw new InvalidOperationException("not signed in");
        var shell = ShellPage.Current ?? throw new InvalidOperationException("the shell isn't showing");
        await Until(() => Find(SidebarSearch.ToolsAutomationId), "the sidebar");
        if (Find(SidebarSearch.ToolsAutomationId) is not Grid) await FoldAsync(shell, fold: false);
        // The mirror arrives with the roster's read: the rows, in the list's order, under Unassigned.
        var until = DateTime.UtcNow.AddSeconds(30);
        string? why;
        while ((why = WalkProof.SidebarGroupChats(shell.SidebarKeys(), rail: false)) != null && DateTime.UtcNow < until) await Task.Delay(250);
        if (why != null) throw new InvalidOperationException(why);
        var launch = (FrameworkElement)await Until(() => Find("sidebar.room.id:rfixture-launch"), "Launch Room's row");
        if (AutomationProperties.GetName(launch) != WalkProof.GroupChatsLaunchLabel)
            throw new InvalidOperationException($"Launch Room's row reads \"{AutomationProperties.GetName(launch)}\"");
        if (Find("sidebar.room.id:rfixture-weekend") == null) throw new InvalidOperationException("no Weekend Plans row");

        // [WIN-41] A click on the room opens the room's own chat (no placeholder page), its row marked; the room's walk
        // (Services/ProofWalks.GroupRoom.cs) checks what it shows.
        Mouse.Click(launch);
        await Until(() => GroupRoomPage.Current is { IsLoaded: true } p && p.RoomKey == "id:rfixture-launch" ? p : null, "Launch Room's chat after the click");
        if (shell.MarkedKey != "room:id:rfixture-launch") throw new InvalidOperationException($"a click on a group chat's row marked {shell.MarkedKey}");
        await shot("sidebar-group-chats");

        // Folded: the same heads in the rail, no headings.
        await FoldAsync(shell, fold: true);
        until = DateTime.UtcNow.AddSeconds(10);
        while ((why = WalkProof.SidebarGroupChats(shell.SidebarKeys(), rail: true)) != null && DateTime.UtcNow < until) await Task.Delay(250);
        if (why != null) throw new InvalidOperationException(why);
        await Until(() => Find("sidebar.room.id:rfixture-weekend"), "Weekend Plans's head in the rail");
        await Task.Delay(500);   // the rail's layout settles
        await shot("sidebar-group-chats-rail");
        await FoldAsync(shell, fold: false);
    }
}
