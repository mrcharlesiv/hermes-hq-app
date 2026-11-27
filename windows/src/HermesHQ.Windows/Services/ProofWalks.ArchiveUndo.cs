using System.Text.Json.Nodes;
using Hermes.Core;
using Hermes.Core.Sessions;
using Hermes.Core.Shell;
using HermesHQ.Features.Bots;
using HermesHQ.Features.Sessions;
using HermesHQ.Pages;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;

namespace HermesHQ.Services;

/// [WIN-ARCHIVE-UNDO] The walk `archive-undo` (composer stand-in, after `chat-keys`, which leaves Trip planning
/// unarchived): Trip planning open, the shell's Archive Chat (the same call Ctrl+Alt+A makes; the keys themselves are
/// the chat-keys walk's), then the pill's own Undo button invoked twice in one turn through its UI Automation peer —
/// in-app, no mouse or keyboard sent to the desktop. The stand-in must log exactly one PATCH of Trip planning with
/// archived false after the press and no write to any other chat since the archive; after a fresh sidebar read the
/// same bot's same chat is listed with its title, the pill has gone, and the undo sent one write
/// (App/Sessions/SessionsOrganizer.swift `archive(_:)`, App/Kit/UndoPill.swift `undo()` at 93f984bb1).
/// If the walk fails before the Undo landed, it puts Trip planning back for the stand-in's next walk.
internal static partial class ProofWalks
{
    private static void RegisterArchiveUndoWalks()
    {
        Automation.NamedWalks["archive-undo"] = ArchiveUndoAsync;
    }

    /// [WIN-RAIL-TOOLS-FIT] What is wrong with where the pill on show stands, or null (`UndoPillPlacement.Misplaced`).
    private static string? PillPlacement(ShellPage shell)
    {
        var pill = Find("undo-pill") ?? throw new InvalidOperationException("the pill isn't showing");
        var pane = shell.FindName("PaneGrid") as FrameworkElement ?? throw new InvalidOperationException("no PaneGrid");
        var sidebar = shell.FindName("SidebarPane") as FrameworkElement ?? throw new InvalidOperationException("no SidebarPane");
        var root = App.Window?.Content as UIElement ?? throw new InvalidOperationException("no window");
        (double, double, double, double) Box(FrameworkElement e)
        {
            var at = e.TransformToVisual(root).TransformPoint(new Windows.Foundation.Point(0, 0));
            return (at.X, at.Y, e.ActualWidth, e.ActualHeight);
        }
        var trimmed = Descendants(pill).OfType<Microsoft.UI.Xaml.Controls.TextBlock>().Any(t => t.IsTextTrimmed);
        var wrong = UndoPillPlacement.Misplaced(Box(pill), Box(pane), Box(sidebar), trimmed);
        AppLog.Note("automation", $"walk archive-undo: pill at {Box(pill)} in pane {Box(pane)}, sidebar {Box(sidebar)}: {wrong ?? "placed"}");
        return wrong;

        static IEnumerable<DependencyObject> Descendants(DependencyObject at)
        {
            for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(at); i++)
            {
                var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(at, i);
                yield return child;
                foreach (var d in Descendants(child)) yield return d;
            }
        }
    }

    private static async Task ArchiveUndoAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var url = client.Session.Address.ToString();
        var shell = ShellPage.Current ?? throw new InvalidOperationException("the shell isn't showing");
        var hub = Features.Bots.ListsHub.Current ?? throw new InvalidOperationException("no lists");
        const string profile = "default";
        var path = SessionWrite.PathOf(WalkProof.TripStoredId);

        await OpenTripAsync();
        var deadline = DateTime.UtcNow.AddSeconds(15);
        while (ChatKeys.Archive(shell.KeyState()) != ArchiveStep.Archive)
        {
            if (DateTime.UtcNow > deadline) throw new InvalidOperationException($"Archive Chat is off in Trip planning ({shell.KeyState()})");
            await Task.Delay(100);
        }
        var before = ChatKeys.RestCount(await StandIn(url, "/__menus/state"));
        var restored = false;
        try
        {
            await shell.ArchiveChatAsync();
            await Until(() => shell.PaneEmpty ? shell : null, "the chat to leave after Archive Chat");
            if (ChatKeys.ArchivedOverRest(await StandIn(url, "/__menus/state"), before, WalkProof.TripStoredId, archived: true) is { } notArchived)
                throw new InvalidOperationException(notArchived);
            var button = await Until(() => Find("undo-pill.undo"), "the pill's Undo");
            var undo = ArchiveUndoRoute.Last ?? throw new InvalidOperationException("the archive made no undo");
            if (undo.Chat.Id != WalkProof.TripStoredId || undo.Chat.Profile != profile)
                throw new InvalidOperationException($"the pill would undo {undo.Chat.Profile}/{undo.Chat.Id}, not {profile}/{WalkProof.TripStoredId}");
            // [WIN-RAIL-TOOLS-FIT] Over the pane, 16 in and 8 up, clear of the sidebar, its words whole (UndoPillPlacement).
            if (PillPlacement(shell) is { } misplaced) throw new InvalidOperationException(misplaced);
            await shot("archive-undo-pill");

            // Two presses in one turn, through the button's own peer (a person's double click on Undo).
            var mark = ChatKeys.RestCount(await StandIn(url, "/__menus/state"));
            var peer = FrameworkElementAutomationPeer.CreatePeerForElement(button) as IInvokeProvider
                ?? throw new InvalidOperationException("undo-pill.undo can't be invoked");
            peer.Invoke();
            try { peer.Invoke(); }
            catch (Exception e) { AppLog.Note("automation", $"walk archive-undo: the second press was refused ({e.GetType().Name})"); }

            await Until(() => undo.Restored ? undo : null, "the Undo's unarchive to land");
            restored = true;
            await Task.Delay(500);   // a duplicate write, if one were sent, reaches the stand-in's log
            var state = await StandIn(url, "/__menus/state");
            var unarchives = Writes(state, mark).Count(r => r.Path == path && r.Archived == false);
            if (unarchives != 1) throw new InvalidOperationException($"Undo sent {unarchives} unarchive writes, not 1");
            if (undo.Writes != 1) throw new InvalidOperationException($"the undo started {undo.Writes} writes, not 1");
            if (Writes(state, before).FirstOrDefault(r => r.Path != path || r.Query?.Contains("profile=" + profile) == false) is { } other)
                throw new InvalidOperationException($"another chat was written: {other.Method} {other.Path}?{other.Query}");
            if (UndoPill.Current != null || Find("undo-pill") != null) throw new InvalidOperationException("the pill stayed after Undo");

            await hub.Sessions.RefreshAsync();
            var back = hub.Sessions.LiveSummaries().FirstOrDefault(s => s.Id == WalkProof.TripStoredId && s.Profile == profile)
                ?? throw new InvalidOperationException("Trip planning isn't listed after Undo and a fresh read");
            if (back.Title != WalkProof.TripTitle) throw new InvalidOperationException($"the chat came back as \"{back.Title}\"");
            AppLog.Note("automation", $"walk archive-undo: {profile}/{WalkProof.TripStoredId} back after one unarchive");
            await shot("archive-undo-back");
            await shot("archive-undo");
        }
        finally
        {
            if (!restored)
                await hub.Sessions.SetArchivedAsync(new SessionSummary
                    { Id = WalkProof.TripStoredId, Profile = profile, Title = WalkProof.TripTitle, Archived = true }, false);
        }
    }

    private sealed record RestWrite(string Method, string Path, string? Query, bool? Archived);

    /// The PATCH and DELETE requests the stand-in logged after the first `mark` entries.
    private static IEnumerable<RestWrite> Writes(JsonNode state, int mark) =>
        ((state["rest"] as JsonArray) ?? []).Skip(mark).OfType<JsonObject>()
            .Where(r => r.Str("method") is "PATCH" or "DELETE")
            .Select(r => new RestWrite(r.Str("method")!, r.Str("path") ?? "", r.Str("query"),
                r["body"]?["archived"] is JsonValue v && v.TryGetValue(out bool b) ? b : null));
}
