using Hermes.Core.Sessions;
using Hermes.Core.Shell;
using HermesHQ.Features.Bots;
using HermesHQ.Features.Sessions;
using HermesHQ.Pages;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace HermesHQ.Services;

/// [WIN-SESSIONS-WORKING-CHIP] sessions-working-chip: the row under Sessions' bar (Chats | Projects, All Bots, the New and
/// Working counts) laid out as the Mac's `macRow` (93f984bb1 App/Sessions/SessionsHeaderView.swift, Hermes.Core
/// SessionsHeaderRow), on the synthetic sessions stand-in (ci/fixtures/sessions-gateway.py, its `live` mode naming Trip
/// to Lisbon working in session.active_list). Every check reads the drawn row:
///   sessions-working-chip         the list at its usual 360: "● 1 working" (or "● 1" where its words don't fit) stands
///                                 whole inside the list's right edge, the menu and the counts at the right.
///   sessions-working-chip-narrow  the list at its least width (ListColumn's MinWidth, 280): a later drawing (the counts'
///                                 words gone, then the switch's glyphs), the count still whole inside the edge.
/// The list goes back to 360 and the stand-in's live mode is cleared whatever happens.
/// windows/ci/windows.yml runs this after "new-chat-here" on the sessions stand-in.
internal static partial class ProofWalks
{
    private static void RegisterSessionsHeaderWalks() =>
        Automation.NamedWalks["sessions-working-chip"] = SessionsWorkingChipAsync;

    private static async Task SessionsWorkingChipAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var shell = ShellPage.Current ?? throw new InvalidOperationException("the shell isn't showing");
        var url = client.Session.Address.ToString();
        var hub = await Until(() => ListsHub.Current is { } h && h.Bots.HasRoster ? h : null, "the roster");

        await DeliveryPostAsync(url, "/__fixture/mode", "{\"live\":{\"s-trip\":\"working\"}}");
        ColumnDefinition? column = null;
        try
        {
            Navigator.Open("sessions");
            await Until(() => shell.WalkState() is { Pane: OpenPane.Place, PlaceId: "sessions" } f ? f : null, "Sessions in the main window", 20);
            var page = await Until(() => Shown(Root).OfType<SessionsPage>().FirstOrDefault(p => p.IsLoaded), "the Sessions page", 20);
            await hub.Sessions.RefreshAsync();
            await hub.Sessions.ReadLiveAsync();   // session.active_list: Trip to Lisbon working
            column = page.FindName("ListColumn") as ColumnDefinition ?? throw new InvalidOperationException("the list has no ListColumn");
            var pane = page.FindName("ListPane") as Grid ?? throw new InvalidOperationException("the list has no ListPane");

            await UntilChecked(() => ChipWhole(page, pane), "the Working count whole in the 360 list", 20);
            AppLog.Note("automation", $"walk sessions-working-chip: 360 list, drawing {page.HeaderVariant}, \"{ChipWords(page)}\"");
            await Task.Delay(400);
            await shot("sessions-working-chip");

            // The list at its least width.
            var least = column.MinWidth;
            column.Width = new GridLength(least);
            await UntilChecked(() => pane.ActualWidth <= least + 1.5 ? ChipWhole(page, pane) : $"the list is {pane.ActualWidth:0.#} wide",
                $"the Working count whole in the {least:0} list", 20);
            if (page.HeaderVariant < 1)
                throw new InvalidOperationException($"at {least:0} the row kept its widest drawing ({page.HeaderVariant}), which the Mac's numbers say can't fit");
            AppLog.Note("automation", $"walk sessions-working-chip: {least:0} list, drawing {page.HeaderVariant}, \"{ChipWords(page)}\"");
            await Task.Delay(400);
            await shot("sessions-working-chip-narrow");
        }
        finally
        {
            if (column != null) column.Width = new GridLength(360);
            try { await DeliveryPostAsync(url, "/__fixture/mode", "{\"live\":{}}"); }
            catch (Exception x) { AppLog.Note("automation", $"walk sessions-working-chip: live reset failed ({x.GetType().Name})"); }
        }
    }

    private static FrameworkElement? WorkingChip(SessionsPage page) =>
        FindIn(page, SessionsHeaderBar.CountAutomationId(SessionStatusChip.Working));

    private static string ChipWords(SessionsPage page) =>
        WorkingChip(page) is { } chip ? string.Join(" ", Shown(chip).OfType<TextBlock>().Select(t => t.Text)) : "";

    /// Null when the Working count says 1 (with or without its word) and stands whole inside the list's right edge
    /// (the pane's 8 padding and its 1 line), with the switch and the menu inside the left one.
    private static string? ChipWhole(SessionsPage page, Grid pane)
    {
        if (WorkingChip(page) is not { ActualWidth: > 0 } chip) return "no Working count is drawn";
        var words = ChipWords(page);
        if (words != SessionsHeaderRow.CountText(SessionStatusChip.Working, 1, words: true) && words != SessionsHeaderRow.CountText(SessionStatusChip.Working, 1, words: false))
            return $"the Working count says \"{words}\"";
        var at = chip.TransformToVisual(pane).TransformPoint(new Point(0, 0));
        var right = at.X + chip.ActualWidth;
        var edge = pane.ActualWidth - pane.Padding.Right - pane.BorderThickness.Right;
        if (right > edge + 0.5) return $"the Working count ends at {right:0.#}, past the list's edge {edge:0.#}";
        if (at.X < pane.Padding.Left - 0.5) return $"the Working count starts at {at.X:0.#}";
        if (FindIn(page, SessionsHeaderBar.RowAutomationId) is FrameworkElement row)
        {
            var start = row.TransformToVisual(pane).TransformPoint(new Point(0, 0)).X;
            if (start < pane.Padding.Left - 0.5) return $"the row starts at {start:0.#}, before the list's edge";
        }
        return null;
    }
}
