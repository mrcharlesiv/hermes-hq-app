using Hermes.Core.Bots;
using Hermes.Core.Shell;
using HermesHQ.Features.Bots;
using HermesHQ.Features.Settings;
using HermesHQ.Pages;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Services;

/// [WIN-55] The CI's accessibility audit (windows/ci/windows.yml's "a11y-audit" extra on the pages stand-in), judged by
/// Hermes.Core.Shell.A11yAuditWalkProof: on Chats (the roster's first bot, its transcript and composer), Sessions,
/// Tasks, Jobs, Kanban, Files (Artifacts), the Settings window and that bot's Bot Info, the UI Automation tree is
/// walked from inside the app (FrameworkElementAutomationPeer, peer by peer, as Narrator reads it) and every Button,
/// ToggleButton, MenuFlyoutItem, TextBox, ListViewItem, HyperlinkButton and AppBarButton (and their subclasses) must have
/// a Name that is words: not empty, not an icon font's code, not a symbol alone. The Mac gives each one a VoiceOver
/// label (accessibilityLabel / accessibilityTitle). The walk lists every one that hasn't (page · type · x:Name or
/// automation id) and the count per page in the app log, then fails if any. Pictures: a11y-audit-chats, -settings.
internal static partial class ProofWalks
{
    private static void RegisterA11yAuditWalks() => Automation.NamedWalks["a11y-audit"] = A11yAuditAsync;

    private static async Task A11yAuditAsync(Func<string, Task> shot)
    {
        if (AppState.Client == null) throw new InvalidOperationException("not signed in");
        var shell = ShellPage.Current ?? throw new InvalidOperationException("the shell isn't showing");
        var findings = new List<A11yFinding>();
        var visited = new List<string>();

        // Chats: the roster's first bot, its transcript read (up to 10 s) and its composer showing.
        var hub = await Until(() => ListsHub.Current is { } h && h.Bots.HasRoster && h.Bots.Layout.Flat.Any() ? h : null, "the roster", 30);
        var first = hub.Bots.Layout.Flat.First().Id;
        var bot = hub.Bots.Bot(first) ?? throw new InvalidOperationException($"no bot {first}");
        Navigator.Go(new BotChatDestination(bot.Model));
        var chat = await Until(() => ChatPage.Current is { IsLoaded: true } c && FindIn(c, "chat.composer") != null ? c : null, $"{first}'s chat with its composer", 20);
        var transcript = (ListView)Need(chat, "chat.transcript");
        for (var by = DateTime.UtcNow.AddSeconds(10); transcript.Items.Count == 0 && DateTime.UtcNow < by; await Task.Delay(200)) { }
        AppLog.Note("automation", $"walk a11y-audit: {first}'s chat shows {transcript.Items.Count} rows");
        await Task.Delay(800);
        Audit("Chats", Root, findings, visited);
        await shot("a11y-audit-chats");

        // The main pages, each on show in the main window.
        foreach (var (place, page) in new[] { ("sessions", "Sessions"), ("tasks", "Tasks"), ("jobs", "Jobs"), ("kanban", "Kanban"), ("artifacts", "Files") })
        {
            Navigator.Open(place);
            await Until(() => shell.WalkState() is { Pane: OpenPane.Place } f && f.PlaceId == place ? f : null, $"{page} in the main window", 20);
            await Until(() => Find(PageBar.TitleId(place)), $"{page}' title", 20);
            await Task.Delay(1500);   // its list is read and laid out
            Audit(page, Root, findings, visited);
        }

        // The Settings window, on the category it opens on.
        SettingsWindows.Show();
        var window = await Until(() => SettingsWindow.Showing, "the Settings window");
        await Until(() => window.Page is { IsLoaded: true } p ? p : null, "Settings in its window");
        await Until(() => FindIn((DependencyObject)window.Content, "settings.search"), "Search Settings in the window");
        await Task.Delay(800);
        Audit("Settings", (UIElement)window.Content, findings, visited);
        await ShotOfAsync(window, () => shot("a11y-audit-settings"));
        window.Close();
        await Until(() => SettingsWindow.OpenCount == 0 ? shell : null, "the Settings window to close");

        // Bot Info for the same bot, as its menu's Bot Info opens it.
        var actions = shell.Actions ?? throw new InvalidOperationException("the bots' actions aren't ready");
        _ = actions.ShowInfoAsync(bot);
        var sheet = await Until(() => InPopups().OfType<ContentDialog>().FirstOrDefault(), "Bot Info", 20);
        await Task.Delay(800);
        Audit("Bot Info", sheet, findings, visited);
        await shot("a11y-audit");   // the walk's own picture: Bot Info over the window
        sheet.Hide();

        foreach (var (page, count) in A11yAuditWalkProof.Counts(findings, visited))
            AppLog.Note("automation", $"walk a11y-audit: {page} {count} unnamed");
        if (A11yAuditWalkProof.Report(findings, visited) is { } wrong) throw new InvalidOperationException(wrong);
    }

    /// Every audited control under `root` (and in the open popups of its XamlRoot) whose automation Name isn't words.
    private static void Audit(string page, UIElement root, List<A11yFinding> findings, List<string> visited)
    {
        visited.Add(page);
        var before = findings.Count;
        var seen = new HashSet<UIElement>();
        void Walk(AutomationPeer peer)
        {
            if (peer is FrameworkElementAutomationPeer { Owner: { } owner } && seen.Add(owner)
                && A11yAuditWalkProof.AuditedAs(TypeAndBases(owner)) is { } type
                && owner is not Control { IsEnabled: false } or TextBox   // a dimmed button is skipped by Tab, a box isn't
                && A11yAuditWalkProof.IsUnreadable(peer.GetName()))
            {
                var fe = owner as FrameworkElement;
                var id = fe == null ? "" : !string.IsNullOrEmpty(fe.Name) ? fe.Name : AutomationProperties.GetAutomationId(fe) ?? "";
                findings.Add(new A11yFinding(page, type, id));
            }
            if (peer.GetChildren() is { } children)
                foreach (var child in children) Walk(child);
        }
        if (FrameworkElementAutomationPeer.CreatePeerForElement(root) is { } top) Walk(top);
        if (root.XamlRoot is { } xr)
            foreach (var popup in Microsoft.UI.Xaml.Media.VisualTreeHelper.GetOpenPopupsForXamlRoot(xr).Where(p => p.Child != null))
                if (FrameworkElementAutomationPeer.CreatePeerForElement(popup.Child) is { } inPopup) Walk(inPopup);
        AppLog.Note("automation", $"walk a11y-audit: {page} audited, {findings.Count - before} unnamed");
    }

    /// The control's type name, then its base types' outward.
    private static IEnumerable<string> TypeAndBases(object o)
    {
        for (var t = o.GetType(); t != null && t != typeof(object); t = t.BaseType) yield return t.Name;
    }
}
