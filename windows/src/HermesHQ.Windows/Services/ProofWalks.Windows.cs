using System.Runtime.InteropServices;
using Hermes.Core;
using Hermes.Core.Artifacts;
using Hermes.Core.Shell;
using HermesHQ.Features.Artifacts;
using HermesHQ.Features.Attachments;
using HermesHQ.Features.Bots;
using HermesHQ.Pages;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace HermesHQ.Services;

/// [WIN-34] The CI's walks for the window keys and the file windows (windows/ci/windows.yml asks for them on the composer
/// and artifacts stand-ins), each backed by the app's state and the stand-in's own record (`Hermes.Core.Shell.WalkProof`):
///   window-keys   The roster's first bot's chat; Ctrl+Down until it stops (every bot once, in the sidebar's order, the
///                 last bot's chat on show and Next Chat off), Ctrl+Up back to the first (WalkKeys, ChatWalk; the Mac's
///                 ⌘↓ / ⌘↑, no wraparound). Sessions on show: Ctrl+R reads the chats listing again (the stand-in logs a
///                 second GET /api/profiles/sessions/sidebar and no write), Ctrl+Down opens its first row beside it, from
///                 Sessions. Ctrl+3 opens the third numbered place and Ctrl+1 brings back the last bot chat (PlaceKeys;
///                 the Mac's ⌘1 following its Bots tab). Then the sidebar foot's menu open with Hermes HQ Support in it
///                 (not clicked: it would leave for the website).
///   file-windows  Project notes open in the main window; the release page (index.html) and the notes' index.md,
///                 downloaded from the stand-in and opened as a chat's file click opens them (MediaActions.OpenAsync →
///                 ArtifactFileWindow.OpenRouted): each in a window of its own whose bar reads Open in…, Share…, Save
///                 As…; the page opened again: no new window, its own brought forward; Ctrl+W in it closes it alone, the
///                 main window still showing Project notes (FileWindowKeys; the Mac's MacFileWindow).
/// Keys go in by SendInput; where they don't arrive, the walk calls what the key calls and says so in the app log.
internal static partial class ProofWalks
{
    private static void RegisterWindowWalks()
    {
        Automation.NamedWalks["window-keys"] = WindowKeysAsync;
        Automation.NamedWalks["file-windows"] = FileWindowsAsync;
    }

    private const ushort VkUp = 0x26, VkR = 0x52, Vk1 = 0x31;

    // ------------------------------------------------------------------ View › Next / Previous Chat, Ctrl+1…9, Refresh

    private static async Task WindowKeysAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var url = client.Session.Address.ToString();
        var shell = ShellPage.Current ?? throw new InvalidOperationException("the shell isn't showing");
        var hub = await Until(() => ListsHub.Current is { } h && h.Bots.HasRoster && h.Sessions.LiveSummaries().Count > 0 ? h : null,
            "the sidebar's bots and chats");
        var bots = await Until(() => shell.WalkState().Bots is { Count: >= 2 } b ? b : null, "two bots in the walk's order");

        // Sessions on show: Ctrl+R reads its list again; Ctrl+Down opens its first row, from Sessions.
        Navigator.Open("sessions");
        await Until(() => shell.WalkState() is { Pane: OpenPane.Place, PlaceId: "sessions", Sessions.Count: > 0 } f ? f : null,
            "Sessions with its rows");
        await Task.Delay(1500);   // the page's own first read settles before the mark
        var reads = hub.Sessions.Reads;
        var mark = ChatKeys.RestCount(await StandIn(url, "/__menus/state"));
        FocusNeutral();
        Keys.Front();
        var refreshed = Keys.Press(VkR, ctrl: true)
            && await RecordAsync(url, "/__menus/state", st => WalkProof.Refetched(st, mark)) == null;
        if (refreshed) AppLog.Note("automation", "walk keys: Ctrl+R by keyboard");
        else
        {
            AppLog.Note("automation", "walk window-keys: Ctrl+R unproven by keyboard; calling the shell's Refresh");
            if (!shell.KeyRefresh()) throw new InvalidOperationException("Refresh is off on Sessions");
            if (await RecordAsync(url, "/__menus/state", st => WalkProof.Refetched(st, mark)) is { } why) throw new InvalidOperationException(why);
        }

        // [WIN-39] Sessions' first row as the list shows it after Ctrl+R's read: the gateway lists the newest chat first
        // (the chat the new-chat-draft walk started tops it once read), so the row is read after every listing the
        // stand-in served since the mark is applied, not from the list as it was before Ctrl+R.
        var gets = WalkProof.ListReads(await StandIn(url, "/__menus/state"), mark);
        await Until(() => hub.Sessions.Reads - reads >= gets ? hub : null, $"the {gets} chats listing(s) Ctrl+R read, applied");
        var onSessions = shell.WalkState();
        if (onSessions is not { Pane: OpenPane.Place, PlaceId: "sessions", Sessions.Count: > 0 })
            throw new InvalidOperationException($"Ctrl+R on Sessions left {WalkProof.Showing(onSessions)} with {onSessions.Sessions.Count} rows");
        var firstRow = WalkKeys.Target(onSessions, forward: true) ?? throw new InvalidOperationException("Next Chat is off on Sessions");
        if (firstRow != onSessions.Sessions[0]) throw new InvalidOperationException($"Next Chat on Sessions would open {firstRow}, not its first row");
        var (rowProfile, rowId) = ChatWalk.SplitSessionKey(firstRow)!.Value;
        await PressAsync(shell, Keys.Down, false, () => shell.WalkState() is { Pane: OpenPane.Chat, FromSessions: true } f
            && f.Profile == rowProfile && f.StoredId == rowId, "Ctrl+Down on Sessions", expected: $"the chat {rowProfile}/{rowId} from Sessions (its first row)");
        await Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId == rowId ? p : null, "Sessions' first chat");
        await shot("window-keys-sessions");

        // The first bot's chat; Ctrl+Down until it stops; Ctrl+Up back to the first.
        var first = bots[0];
        Navigator.Go(new BotChatDestination(hub.Bots.Bot(first)?.Model ?? throw new InvalidOperationException($"no bot {first}")));
        await Until(() => shell.WalkState() is { Pane: OpenPane.BotChat } f && f.Profile == first ? shell : null, $"{first}'s chat");
        var down = await WalkBotsAsync(shell, first, forward: true);
        if (WalkProof.WalkedTo(bots, first, forward: true, down) is { } wrongDown) throw new InvalidOperationException(wrongDown);
        await shot("window-keys-last");
        var up = await WalkBotsAsync(shell, bots[^1], forward: false);
        if (WalkProof.WalkedTo(bots, bots[^1], forward: false, up) is { } wrongUp) throw new InvalidOperationException(wrongUp);
        await Until(() => ChatPage.Current is { IsLoaded: true } ? shell : null, $"{first}'s chat");
        await shot("window-keys-first");

        // Ctrl+3: the third numbered place; Ctrl+1: the last bot chat back.
        var places = shell.NumberedPlaces();
        var third = places[PlaceKeys.Place(2, places.Count) ?? throw new InvalidOperationException($"only {places.Count} numbered places")];
        await PressAsync(shell, (ushort)(Vk1 + 2), false, () => shell.WalkState() is { Pane: OpenPane.Place } f && f.PlaceId == third, "Ctrl+3",
            () => shell.PickNth(3), $"the {third} page");
        await PressAsync(shell, Vk1, false, () => shell.WalkState() is { Pane: OpenPane.BotChat } f && f.Profile == first, "Ctrl+1",
            () => shell.PickNth(1), $"{first}'s chat");
        await Until(() => ChatPage.Current is { IsLoaded: true } ? shell : null, $"{first}'s chat back");
        await shot("window-keys");

        // The sidebar foot's menu: Hermes HQ Support in it, not clicked.
        var account = (Button)Need("shell.account");
        var menu = shell.AccountMenuFlyout;
        try { Mouse.Click(account); }
        catch (InvalidOperationException e) { AppLog.Note("automation", $"walk window-keys: the account button wasn't clicked ({e.Message}); showing its menu"); }
        var shownBy = DateTime.UtcNow.AddSeconds(10);
        while (!InPopups().Any(e => Id(e) == "shell.support") && DateTime.UtcNow < shownBy) await Task.Delay(100);
        if (!InPopups().Any(e => Id(e) == "shell.support"))
        {
            AppLog.Note("automation", "walk window-keys: the click didn't open the account menu; showing it");
            menu.ShowAt(account);
        }
        else AppLog.Note("automation", "walk window-keys: the account menu open by pointer");
        await Until(() => InPopups().FirstOrDefault(e => Id(e) == "shell.support"), "Hermes HQ Support in the menu");
        var items = menu.Items.OfType<MenuFlyoutItem>().Where(i => i.Visibility == Visibility.Visible).Select(i => i.Text).ToList();
        if (WalkProof.SupportListed(items) is { } missing) throw new InvalidOperationException(missing);
        await shot("window-keys-support");
        menu.Hide();
        await Until(() => InPopups().All(e => Id(e) != "shell.support") ? shell : null, "the menu to close");
    }

    /// Presses Ctrl+Down (or Ctrl+Up) from `start` until the walk stops: the bots opened, in order. At the end the key is
    /// off (WalkKeys) and a further press changes nothing.
    private static async Task<List<string>> WalkBotsAsync(ShellPage shell, string start, bool forward)
    {
        var seen = new List<string>();
        var at = start;
        while (WalkKeys.Target(shell.WalkState(), forward) is { } next)
        {
            if (seen.Count > 50) throw new InvalidOperationException("the walk never stopped");
            await PressAsync(shell, forward ? Keys.Down : VkUp, false,
                () => shell.WalkState() is { Pane: OpenPane.BotChat } f && f.Profile == next, $"Ctrl+{(forward ? "Down" : "Up")} to {next}",
                expected: $"{next}'s chat");
            seen.Add(next);
            at = next;
        }
        // At the end: no wraparound. The key pressed again leaves the same bot on show.
        FocusNeutral();
        Keys.Front();
        Keys.Press(forward ? Keys.Down : VkUp, ctrl: true);
        await Task.Delay(2000);
        if (shell.WalkState() is not { Pane: OpenPane.BotChat } f || f.Profile != at)
            throw new InvalidOperationException($"Ctrl+{(forward ? "Down" : "Up")} past the {(forward ? "last" : "first")} bot left {at}");
        if (shell.Walk(forward)) throw new InvalidOperationException($"{(forward ? WalkKeys.NextTitle : WalkKeys.PreviousTitle)} still acts on {at}");
        return seen;
    }

    /// Ctrl+`vk` by SendInput with the keyboard off any field, waiting 10 s for `landed`. [WIN-39] Where the shell acted on
    /// the key (ShellPage.KeyActs moved: `[keys] next chat`, `select tab`) but `landed` never held, it fails with what the
    /// key opened instead of `expected`; only where the key did nothing is `fallback` (Next / Previous Chat by default)
    /// called, noted, and must land too.
    private static async Task PressAsync(ShellPage shell, ushort vk, bool shift, Func<bool> landed, string what, Func<bool>? fallback = null,
        string expected = "where the walk expected")
    {
        FocusNeutral();
        var acted = shell.KeyActs;
        if (await KeysAsync(() => Keys.Press(vk, ctrl: true, shift: shift), landed, what)) return;
        switch (WalkProof.Pressed(landed(), acted, shell.KeyActs))
        {
            case WalkProof.Press.Landed: return;
            case WalkProof.Press.Elsewhere: throw new InvalidOperationException(WalkProof.OpenedInstead(what, shell.WalkState(), expected));
        }
        AppLog.Note("automation", $"walk window-keys: {what} unproven by keyboard (the shell never acted on it); calling what the key calls");
        var called = fallback?.Invoke() ?? shell.Walk(forward: vk == Keys.Down);
        if (!called) throw new InvalidOperationException($"{what}: the shell's own command is off");
        await Until(() => landed() ? shell : null, what);
    }

    /// The keyboard on the sidebar foot's account button: no field holds it, so Ctrl+Up / Ctrl+Down aren't a caret's.
    private static void FocusNeutral()
    {
        if (Find("shell.account") is Control account) account.Focus(FocusState.Keyboard);
    }

    // ------------------------------------------------------------------ file and page windows

    private static async Task FileWindowsAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var shell = ShellPage.Current ?? throw new InvalidOperationException("the shell isn't showing");
        if (ArtifactFileWindow.OpenKeys.Count > 0) throw new InvalidOperationException($"{ArtifactFileWindow.OpenKeys.Count} file windows were already open");

        // The main window's chat, kept on show throughout.
        Navigator.Go(new ChatDestination(WalkProof.WalkNoteBot, WalkProof.WalkNoteSession, WalkProof.WalkChatTitle));
        var chat = await Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId == WalkProof.WalkNoteSession && p.MessageCount > 0 ? p : null,
            "Project notes' messages");

        // The files, fetched from the stand-in as the app fetches a chat's file.
        var folder = Path.Combine(Path.GetTempPath(), "hq-walk-files", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        async Task<string> Fetch(string path, string name, string session, string bot)
        {
            var file = Path.Combine(folder, name);
            await client.Session.DownloadToFileAsync("/api/fs/download", [new("path", path), new("session_id", session), new("profile", bot)],
                file, ArtifactFiles.FileLimit);
            if (!File.Exists(file) || new FileInfo(file).Length == 0) throw new InvalidOperationException($"{name} didn't download");
            return file;
        }
        var pageFile = await Fetch(WalkProof.WalkPagePath, WalkProof.WalkPageName, WalkProof.WalkPageSession, WalkProof.WalkPageBot);
        var noteFile = await Fetch(WalkProof.WalkNotePath, WalkProof.WalkNoteName, WalkProof.WalkNoteSession, WalkProof.WalkNoteBot);
        var pageKey = FileWindowKey.Page(null, pageFile);
        var noteKey = FileWindowKey.Page(null, noteFile);

        var pageWindow = await OpenFileWindowAsync(pageFile, WalkProof.WalkPageName, pageKey);
        await PageDrawnAsync(pageWindow, "the page's window");
        await ShotOfAsync(pageWindow, () => shot("file-windows-page"));
        var noteWindow = await OpenFileWindowAsync(noteFile, WalkProof.WalkNoteName, noteKey);
        await ShotOfAsync(noteWindow, () => shot("file-windows-note"));

        // The page opened again: no new window, its own forward.
        var before = ArtifactFileWindow.OpenKeys;
        await MediaActions.OpenAsync(pageFile, WalkProof.WalkPageName);
        if (WalkProof.BroughtForward(before, ArtifactFileWindow.OpenKeys, pageKey) is { } again) throw new InvalidOperationException(again);
        if (!ReferenceEquals(ArtifactFileWindow.Showing(pageKey), pageWindow)) throw new InvalidOperationException("the page's window was replaced");
        await PageDrawnAsync(pageWindow, "the page opened again");
        var pageHandle = WinRT.Interop.WindowNative.GetWindowHandle(pageWindow);
        var noteHandle = WinRT.Interop.WindowNative.GetWindowHandle(noteWindow);
        var front = IntPtr.Zero;
        var until = DateTime.UtcNow.AddSeconds(10);
        while (DateTime.UtcNow < until && (front = Foreground()) != pageHandle) await Task.Delay(100);
        if (front == noteHandle) throw new InvalidOperationException("opening the page again left the note's window in front");
        AppLog.Note("automation", front == pageHandle ? "walk file-windows: the page's window came forward"
            : "walk file-windows: forward unproven (another process holds the foreground)");

        // Ctrl+W in the page's window: it closes alone; the main window keeps Project notes.
        before = ArtifactFileWindow.OpenKeys;
        var closed = false;
        pageWindow.Closed += (_, _) => closed = true;
        pageWindow.Activate();
        if (Shown((DependencyObject)pageWindow.Content).OfType<Button>().FirstOrDefault(b => Id(b) == "file.window.share") is { } share)
            share.Focus(FocusState.Keyboard);
        // Not KeysAsync: that brings the main window in front first. Only with the page's window in front: Ctrl+W in the
        // main window is its chat's Close Chat, which is not what this proves.
        var inFront = DateTime.UtcNow.AddSeconds(10);
        while (Foreground() != pageHandle && DateTime.UtcNow < inFront) { pageWindow.Activate(); await Task.Delay(200); }
        if (Foreground() == pageHandle && Keys.Press(Keys.W, ctrl: true, target: pageWindow))
        {
            var by = DateTime.UtcNow.AddSeconds(10);
            while (!closed && DateTime.UtcNow < by) await Task.Delay(100);
        }
        if (closed) AppLog.Note("automation", "walk keys: Ctrl+W in the page's window by keyboard");
        else
        {
            AppLog.Note("automation", $"walk keys: Ctrl+W didn't reach the page's window (foreground {(Foreground() == pageHandle ? "it" : "another")})");
            AppLog.Note("automation", "walk file-windows: Ctrl+W unproven by keyboard; closing the page's window as the key does");
            pageWindow.Close();
        }
        await Until(() => closed ? shell : null, "the page's window to close");
        if (WalkProof.ClosedKeepingChat(before, ArtifactFileWindow.OpenKeys, pageKey, chat.StoredId, ChatPage.Current?.StoredId) is { } kept)
            throw new InvalidOperationException(kept);
        if (shell.PaneEmpty) throw new InvalidOperationException("the main window's chat closed with the file window");
        Keys.Front();
        await shot("file-windows");

        // The note's window closed too, so the next extra starts with none.
        noteWindow.Close();
        await Until(() => ArtifactFileWindow.OpenKeys.Count == 0 ? shell : null, "the note's window to close");
    }

    /// Opens `file` as a chat's file click does: a new window for it (no other), its bar reading Open in…, Share…, Save
    /// As….
    private static async Task<ArtifactFileWindow> OpenFileWindowAsync(string file, string name, string key)
    {
        var before = ArtifactFileWindow.OpenKeys;
        await MediaActions.OpenAsync(file, name);
        var window = await Until(() => ArtifactFileWindow.Showing(key), $"{name}'s window");
        if (WalkProof.WindowOpened(before, ArtifactFileWindow.OpenKeys, key) is { } wrong) throw new InvalidOperationException(wrong);
        var content = (FrameworkElement)window.Content;
        await Until(() => content.IsLoaded ? content : null, $"{name}'s window drawn");
        var bar = await Until(() => Shown(content).OfType<Button>().Where(b => Id(b).StartsWith("file.window.", StringComparison.Ordinal)).ToList() is { Count: 3 } b ? b : null,
            $"{name}'s bar");
        var app = ArtifactFileWindow.DefaultApp(file);
        if (WalkProof.BarReads([.. bar.Select(b => AutomationProperties.GetName(b))], app) is { } barWrong) throw new InvalidOperationException(barWrong);
        if (window.Title != name) throw new InvalidOperationException($"{name}'s window is titled {window.Title}");
        return window;
    }

    /// The page's Preview in `window` settled (ArtifactHtmlView, PagePreviewLife.StartLimit then DrawLimit) and drawn, its live page
    /// reading the release page's heading: a window whose bar came over a blank body fails here, with the view's own
    /// reason when it said why.
    private static async Task PageDrawnAsync(ArtifactFileWindow window, string what)
    {
        var view = window.Body as ArtifactHtmlView ?? throw new InvalidOperationException($"{what} shows no page Preview");
        var by = DateTime.UtcNow + PagePreviewLife.SettleLimit + TimeSpan.FromSeconds(5);
        while (view.Phase is PagePreviewPhase.Waiting or PagePreviewPhase.Loading && DateTime.UtcNow < by) await Task.Delay(100);
        var text = await view.PageTextAsync();
        if (WalkProof.PageDrawn(view.Phase, view.FailureReason, text, WalkProof.WalkPageHeading) is { } wrong)
            throw new InvalidOperationException($"{what}: {wrong}");
        AppLog.Note("automation", $"walk file-windows: {what} drew the page");
    }

    /// A shot of a file window's own content (Automation.ShotOf), not the main window's.
    private static async Task ShotOfAsync(Window window, Func<Task> take)
    {
        Automation.ShotOf = window.Content;
        try { await take(); }
        finally { Automation.ShotOf = null; }
    }

    [DllImport("user32.dll", EntryPoint = "GetForegroundWindow")]
    private static extern IntPtr Foreground();

}
