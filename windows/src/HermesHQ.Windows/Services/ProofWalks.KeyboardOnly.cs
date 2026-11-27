using Hermes.Core.Shell;
using HermesHQ.Features.Bots;
using HermesHQ.Features.Settings;
using HermesHQ.Pages;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.System;

namespace HermesHQ.Services;

/// [WIN-58] keyboard-only (windows/ci/windows.yml's "keyboard-only" extra on the pages stand-in), judged by
/// Hermes.Core.Shell.KeyboardOnlyWalkProof: the main window used with the keyboard alone, as the Mac's key loop. Focus
/// moves only as Tab and Shift+Tab move it (FocusManager.TryMoveFocus Next / Previous, ↓ in a list as Down), never a
/// pointer and never an injected key. Where a key's own handler can't be raised from inside the app (Enter on a sidebar
/// row is the ListView's ItemClick, Ctrl+, and Esc are KeyboardAccelerators), the walk checks the key is wired and does
/// what it does, and says so in the app log. From the sidebar's first stop it reaches a chat's row, opens it, Tabs to
/// Chat Actions, Inspector and the message box, types and sends, Shift+Tabs back out to the sidebar (not trapped), opens
/// Settings with Ctrl+, and closes it with Esc, then on Tasks Tabs to Search Tasks and a task's row and back. Every stop
/// must have a size, lie inside the window and draw a focus visual; the order of the named stops must be the Mac's.
/// Every finding is listed in the app log before the walk fails. Pictures: keyboard-only-composer, keyboard-only-tasks.
internal static partial class ProofWalks
{
    private static void RegisterKeyboardOnlyWalks() => Automation.NamedWalks["keyboard-only"] = KeyboardOnlyAsync;

    /// Tab presses allowed between two named stops before the walk calls the focus lost.
    private const int KeyMoves = 40;

    private static async Task KeyboardOnlyAsync(Func<string, Task> shot)
    {
        if (AppState.Client == null) throw new InvalidOperationException("not signed in");
        var shell = ShellPage.Current ?? throw new InvalidOperationException("the shell isn't showing");
        var findings = new List<string>();
        var xamlRoot = Root.XamlRoot;

        // The roster read and the sidebar open.
        await Until(() => ListsHub.Current is { } h && h.Bots.HasRoster && h.Bots.Layout.Flat.Any() ? h : null, "the roster", 30);
        var pane = (FrameworkElement)await Until(() => Named(Root, "SidebarPane"), "the sidebar", 20);
        var chatRow = await Until(() => Descendants(pane).OfType<ListViewItem>().FirstOrDefault(i => i.Tag is SidebarBot && i.ActualWidth > 0), "a chat's row in the sidebar", 20);

        // Starting in the sidebar: its first stop (Search), as the window opens with the sidebar's focus (MacSelection).
        var start = FocusManager.FindFirstFocusableElement(pane) as Control ?? throw new InvalidOperationException("the sidebar has nothing the keyboard can reach");
        start.Focus(FocusState.Keyboard);
        var forward = new List<string> { Stop(start, findings) };
        // Tab into the list, then ↓ (the list's own arrows, a Down move) to a chat's row.
        await MoveUntil(FocusNavigationDirection.Next, k => k.StartsWith("sidebar.", StringComparison.Ordinal) && Focused() is ListViewItem, forward, findings, "the sidebar's list");
        for (var i = 0; i < KeyMoves && Focused() is ListViewItem { Tag: not SidebarBot }; i++)
            await MoveOnce(FocusNavigationDirection.Down, forward, findings);
        if (Focused() is not ListViewItem { Tag: SidebarBot bot } row)
            throw new InvalidOperationException($"↓ in the sidebar never reached a chat's row; the focus went: {string.Join(" → ", forward)}");

        // Enter on the row: the ListView's ItemClick opens the chat (ShellPage.Sidebar_ItemClick → Navigator.Go).
        AppLog.Note("automation", $"walk keyboard-only: Enter on {bot.Name}'s row; doing what its ItemClick does (no key injection)");
        Navigator.Go(new BotChatDestination(bot.Bot.Model));
        var chat = await Until(() => ChatPage.Current is { IsLoaded: true } c && FindIn(c, KeyboardOnlyWalkProof.Composer) != null ? c : null, $"{bot.Name}'s chat", 20);
        await Task.Delay(800);   // the transcript is read and the sidebar marks the row
        if (Focused() == null || !InTree(Focused()!))
        {
            findings.Add("opening the chat from the sidebar's row lost the keyboard's focus");
            var marked = Descendants(pane).OfType<ListViewItem>().FirstOrDefault(i => i.Tag is SidebarBot b && b.Bot.Id == bot.Bot.Id) ?? row;
            marked.Focus(FocusState.Keyboard);
        }

        // Tab: Chat Actions, Inspector, then the message box.
        await MoveUntil(FocusNavigationDirection.Next, k => k == KeyboardOnlyWalkProof.Composer, forward, findings, "the message box");
        if (KeyboardOnlyWalkProof.Order(forward, KeyboardOnlyWalkProof.ChatForward) is { } chatOrder) findings.Add("Tab in the chat: " + chatOrder);
        AppLog.Note("automation", $"walk keyboard-only: Tab went {string.Join(" → ", forward)}");

        // Type and send (Enter in the box sends: ChatPage.Composer_PreviewKeyDown → Send, as Send's own button does).
        var box = (TextBox)Need(chat, KeyboardOnlyWalkProof.Composer);
        var transcript = (ListView)Need(chat, "chat.transcript");
        var rows = transcript.Items.Count;
        box.Text = "Sent from the keyboard alone";
        var send = (Button)await Until(() => FindIn(chat, "chat.send") is Button { IsEnabled: true } b ? b : null, "Send enabled by the typing", 10);
        AppLog.Note("automation", "walk keyboard-only: Enter in the message box; doing what it does (Send)");
        ((IInvokeProvider)FrameworkElementAutomationPeer.CreatePeerForElement(send)).Invoke();
        // The pages stand-in runs no prompts, so the send is refused. Since WIN-SEND-REFUSE-WITHDRAW (7261d28d8, the Mac's
        // refuseSend) a refused send leaves the transcript and its words come back to the box under the one Couldn't Send
        // card (CI run 45120146387); a send the stand-in took is a new transcript row with the box emptied.
        var outcome = await Until(() =>
            transcript.Items.Count > rows && box.Text.Length == 0 ? "sent" :
            FindIn(chat, Hermes.Core.Chat.ComposerNotices.SendFailureId) != null && box.Text == "Sent from the keyboard alone" ? "refused" : null,
            "the message sent from the keyboard (a new row, or Couldn't Send with the words back in the box)", 15);
        AppLog.Note("automation", $"walk keyboard-only: the send {(outcome == "sent" ? "is in the transcript; the box emptied" : "was refused (the stand-in runs no prompts): Couldn't Send, the words back in the box")}");
        box.Focus(FocusState.Keyboard);
        await Task.Delay(400);
        if (Focused() != box) findings.Add($"after the send the focus is on {FocusKey(Focused())}, not the message box");
        Stop(box, findings);
        await shot("keyboard-only-composer");

        // Shift+Tab: Inspector, Chat Actions, and out of the chat to the sidebar again (never trapped).
        var back = new List<string>();
        await MoveUntil(FocusNavigationDirection.Previous, k => k.StartsWith("sidebar", StringComparison.Ordinal), back, findings, "the sidebar, going back");
        if (KeyboardOnlyWalkProof.Order(back, KeyboardOnlyWalkProof.ChatBackward) is { } backOrder) findings.Add("Shift+Tab from the message box: " + backOrder);
        AppLog.Note("automation", $"walk keyboard-only: Shift+Tab went {string.Join(" → ", back)}");

        // Ctrl+, opens Settings; Esc closes it and the keyboard is back in the main window.
        var comma = shell.KeyboardAccelerators.Any(a => a.Key == (VirtualKey)188 && a.Modifiers == VirtualKeyModifiers.Control);
        if (!comma) findings.Add("the main window has no Ctrl+, (KeyCommands.swift \"Settings…\", \",\", .command)");
        AppLog.Note("automation", $"walk keyboard-only: {KeyboardOnlyWalkProof.SettingsKey}; doing what its accelerator does (SettingsWindows.Show)");
        SettingsWindows.Show();
        var window = await Until(() => SettingsWindow.Showing, "the Settings window", 15);
        var content = await Until(() => window.Content as UIElement, "Settings in its window", 15);
        await Until(() => FindIn(content, "settings.search"), "Search Settings in the window", 15);
        if (!content.KeyboardAccelerators.Any(a => a.Key == VirtualKey.Escape && a.Modifiers == VirtualKeyModifiers.None))
            findings.Add("the Settings window has no Esc");
        AppLog.Note("automation", "walk keyboard-only: Esc in the Settings window; doing what it does (closes the window)");
        window.Close();
        await Until(() => SettingsWindow.OpenCount == 0 ? shell : null, "the Settings window to close", 15);
        App.Window!.Activate();
        var by = DateTime.UtcNow.AddSeconds(10);
        while ((Focused() is not { } f || !InTree(f)) && DateTime.UtcNow < by) await Task.Delay(100);
        if (Focused() is not { } after || !InTree(after)) findings.Add("after Settings closed nothing in the main window has the keyboard's focus");
        else AppLog.Note("automation", $"walk keyboard-only: after Esc the focus is on {FocusKey(after)}");

        // Tasks: from the page's first stop, Tab to Search Tasks and a task's row, and Shift+Tab back.
        Navigator.Open("tasks");
        await Until(() => shell.WalkState() is { Pane: OpenPane.Place } p && p.PlaceId == "tasks" ? p : null, "Tasks in the main window", 20);
        await Until(() => Find(KeyboardOnlyWalkProof.TasksSearch), "Search Tasks", 20);
        await Until(() => Shown(Root).FirstOrDefault(e => Id(e).StartsWith(KeyboardOnlyWalkProof.TaskRowPrefix, StringComparison.Ordinal)), "a task's row", 20);
        await Task.Delay(800);
        var page = (FrameworkElement)await Until(() => Named(Root, "ContentFrame"), "the main pane", 10);
        var first = FocusManager.FindFirstFocusableElement(page) as Control ?? throw new InvalidOperationException("Tasks has nothing the keyboard can reach");
        first.Focus(FocusState.Keyboard);
        var tasks = new List<string> { Stop(first, findings) };
        await MoveUntil(FocusNavigationDirection.Next, k => k.StartsWith(KeyboardOnlyWalkProof.TaskRowPrefix, StringComparison.Ordinal), tasks, findings, "a task's row");
        if (KeyboardOnlyWalkProof.Order(tasks, KeyboardOnlyWalkProof.TasksForward) is { } tasksOrder) findings.Add("Tab on Tasks: " + tasksOrder);
        AppLog.Note("automation", $"walk keyboard-only: Tab on Tasks went {string.Join(" → ", tasks)}");
        var taskStop = Focused() as Control;
        taskStop?.Focus(FocusState.Keyboard);
        await Task.Delay(400);
        await shot("keyboard-only-tasks");
        var tasksBack = new List<string>();
        await MoveUntil(FocusNavigationDirection.Previous, k => k == KeyboardOnlyWalkProof.TasksSearch, tasksBack, findings, "Search Tasks, going back");
        await shot("keyboard-only");

        foreach (var finding in findings) AppLog.Note("automation", "walk keyboard-only: " + finding);
        if (findings.Count > 0) throw new InvalidOperationException($"{findings.Count} keyboard-only findings:\n  " + string.Join("\n  ", findings));

        DependencyObject? Focused() => FocusManager.GetFocusedElement(xamlRoot) as DependencyObject;

        async Task MoveOnce(FocusNavigationDirection direction, List<string> went, List<string> found)
        {
            var before = Focused();
            bool moved;
            try { moved = FocusManager.TryMoveFocus(direction, new FindNextElementOptions { SearchRoot = xamlRoot.Content }); }
            catch (ArgumentException) { moved = FocusManager.TryMoveFocus(direction); }   // a root the overload refuses
            await Task.Delay(120);
            var now = Focused();
            if (!moved || now == null || ReferenceEquals(now, before))
                throw new InvalidOperationException($"{direction} from {FocusKey(before)} went nowhere (trapped); the focus went: {string.Join(" → ", went)}");
            went.Add(Stop(now, found));
        }

        async Task MoveUntil(FocusNavigationDirection direction, Func<string, bool> reached, List<string> went, List<string> found, string what)
        {
            for (var i = 0; i < KeyMoves; i++)
            {
                await MoveOnce(direction, went, found);
                if (reached(went[^1])) return;
            }
            throw new InvalidOperationException($"{KeyMoves} {direction} moves never reached {what}; the focus went: {string.Join(" → ", went)}");
        }

        // The stop's key, after checking it is drawn: a size, inside the window, a focus visual.
        string Stop(DependencyObject element, List<string> found)
        {
            var key = FocusKey(element);
            if (element is FrameworkElement fe)
            {
                var at = fe.TransformToVisual(Root).TransformPoint(new Point(0, 0));
                if (KeyboardOnlyWalkProof.OnScreen(key, fe.ActualWidth, fe.ActualHeight, at.X, at.Y, Root.ActualWidth, Root.ActualHeight) is { } off) found.Add(off);
            }
            if (element is Control c)
            {
                if (!KeyboardOnlyWalkProof.DrawsFocus(c.UseSystemFocusVisuals, c is TextBox, c.BorderThickness.Bottom))
                    found.Add($"{key} ({c.GetType().Name}) has the focus but draws no focus visual");
            }
            else found.Add($"{key} ({element.GetType().Name}) takes the focus but isn't a control that draws it");
            return key;
        }
    }

    /// A focus stop's key: its automation id, else its x:Name, else its type; a bot's sidebar row is "sidebar.chat";
    /// anything under the sidebar pane "sidebar." + its own key.
    private static string FocusKey(DependencyObject? element)
    {
        if (element == null) return "(nothing)";
        if (element is ListViewItem { Tag: SidebarBot }) return KeyboardOnlyWalkProof.SidebarChat;
        var own = element is FrameworkElement fe
            ? Id(fe) is { Length: > 0 } id ? id : !string.IsNullOrEmpty(fe.Name) ? fe.Name : fe.GetType().Name
            : element.GetType().Name;
        if (own.StartsWith("sidebar", StringComparison.Ordinal)) return own;
        for (var up = VisualTreeHelper.GetParent(element); up != null; up = VisualTreeHelper.GetParent(up))
            if (up is FrameworkElement { Name: "SidebarPane" }) return "sidebar." + own;
        return own;
    }

    private static bool InTree(DependencyObject element)
    {
        for (var up = element; up != null; up = VisualTreeHelper.GetParent(up))
            if (ReferenceEquals(up, Root)) return true;
        return false;
    }

    private static FrameworkElement? Named(DependencyObject under, string name) =>
        Descendants(under).OfType<FrameworkElement>().FirstOrDefault(e => e.Name == name);

    private static IEnumerable<DependencyObject> Descendants(DependencyObject node)
    {
        var count = VisualTreeHelper.GetChildrenCount(node);
        for (var i = 0; i < count; i++)
        {
            var child = VisualTreeHelper.GetChild(node, i);
            yield return child;
            foreach (var deeper in Descendants(child)) yield return deeper;
        }
    }
}
