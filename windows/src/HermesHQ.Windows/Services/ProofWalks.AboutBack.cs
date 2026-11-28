using Hermes.Core.Settings;
using HermesHQ.Features.Settings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Services;

internal static partial class ProofWalks
{
    private enum AboutPane { Notice, Licenses, Detail, Category }
    private enum AboutPhase
    {
        ObserveNotice, NoticeToLicenses, ObserveLicenses, LicensesToDetail, ObserveLicensesDetail, ObserveLoggingDetail,
        LicensesDetailToCategory, LoggingDetailToCategory, ObserveLicensesCategory, ObserveLoggingCategory
    }
    private enum AboutGuard
    {
        DesktopWalk, FixtureClient, FixtureAddress, CurrentClient, DesktopStamp, CurrentWindow, PageThread, CurrentPage,
        PageLoaded, PageOwner, XamlRoot, Sheet, MarkedCategory, Search, OpenPopup, RouteMarker, OtherRouteMarker,
        DuplicateMarker, RouteTitle, DetailedLogRow, DiscordRow, SupportRow, BackStack, BackControl, BackOwner,
        BackEnabled, BackUri, BackLabel
    }

    // Only Back on this fixture page is invoked. File actions are markers of the category, never targets.
    private static async Task AboutBackAsync(Func<string, Task> shot, bool fromLicenseText)
    {
        if (Automation.AppOnly) return; // The separately selected app-only plan has its own frame list.
        var phase = fromLicenseText ? AboutPhase.ObserveNotice : AboutPhase.ObserveLoggingDetail;
        string Receipt(AboutGuard failed) => $"about-back-stop/v1 phase={phase} guard={failed}";
        InvalidOperationException Stop(AboutGuard failed) => new(Receipt(failed));
        void Require(bool holds, AboutGuard guard) { if (!holds) throw Stop(guard); }

        var proof = Automation.Desktop ?? throw Stop(AboutGuard.DesktopWalk);
        var client = AppState.Client ?? throw Stop(AboutGuard.FixtureClient);
        var window = App.Window ?? throw Stop(AboutGuard.CurrentWindow);
        var page = SettingsPage.Current ?? throw Stop(AboutGuard.CurrentPage);
        FrameworkElement? owner = null;
        XamlRoot? ownerXamlRoot = null;
        void RequirePage()
        {
            // Stop on the first failed observation; never sample it again to guess what went wrong.
            Require(!Automation.AppOnly, AboutGuard.DesktopWalk);
            Require(client.Session.Address.ToString() == "http://127.0.0.1:9830", AboutGuard.FixtureAddress);
            Require(AppState.Client == client, AboutGuard.CurrentClient);
            Require(Automation.Desktop?.Stamp == proof.Stamp, AboutGuard.DesktopStamp);
            Require(App.Window == window, AboutGuard.CurrentWindow);
            Require(page.DispatcherQueue?.HasThreadAccess == true, AboutGuard.PageThread);
            Require(SettingsPage.Current == page, AboutGuard.CurrentPage);
            Require(page.IsLoaded, AboutGuard.PageLoaded);
            if (window.Content is not FrameworkElement root || (owner != null && root != owner) || !Within(page, root))
                throw Stop(AboutGuard.PageOwner);
            if (root.XamlRoot is not { } xr || page.XamlRoot != xr || (ownerXamlRoot != null && xr != ownerXamlRoot))
                throw Stop(AboutGuard.XamlRoot);
            Require(!window.SheetShown, AboutGuard.Sheet);
            Require(page.MarkedCategory == "About", AboutGuard.MarkedCategory);
            Require(!page.Searching, AboutGuard.Search);
            // Inspect the checked root itself. Even an open popup without a child is not an empty collection.
            Require(VisualTreeHelper.GetOpenPopupsForXamlRoot(xr).Count == 0, AboutGuard.OpenPopup);
            owner ??= root;
            ownerXamlRoot ??= xr;
        }
        FrameworkElement? Visible(string id)
        {
            var matches = Shown(page).Where(e => Id(e) == id && e.IsLoaded && e.ActualWidth > 0 && e.ActualHeight > 0).Take(2).ToArray();
            return matches.Length switch { 0 => null, 1 => matches[0], _ => throw Stop(AboutGuard.DuplicateMarker) };
        }
        static (string Marker, string Title) Identity(AboutPane pane) => pane switch
        {
            AboutPane.Notice => ("license.text", LicenseNotices.First),
            AboutPane.Licenses => ("licenses.intro", LicenseNotices.PageTitle),
            AboutPane.Detail => ("about.version", "About"),
            AboutPane.Category => ("settings.about", "About"),
            _ => throw new ArgumentOutOfRangeException(nameof(pane))
        };
        void RequireRoute(AboutPane pane)
        {
            var (marker, title) = Identity(pane);
            Require(page.PageTitle == title, AboutGuard.RouteTitle);
            Require(Visible(marker) != null, AboutGuard.RouteMarker);
            foreach (var other in Enum.GetValues<AboutPane>())
                if (other != pane) Require(Visible(Identity(other).Marker) == null, AboutGuard.OtherRouteMarker);
            if (pane == AboutPane.Detail) Require(Visible("about.detailed-log") != null, AboutGuard.DetailedLogRow);
            if (pane != AboutPane.Category) return;
            Require(!page.CanGoBack, AboutGuard.BackStack);
            Require(Visible("settings.back") == null, AboutGuard.BackControl);
            Require(Visible("row:discord") != null, AboutGuard.DiscordRow);
            Require(Visible("row:support") != null, AboutGuard.SupportRow);
        }
        async Task Observe(AboutPhase at, AboutPane pane, string? frame = null)
        {
            phase = at;
            var id = Identity(pane).Marker;
            // Only the expected marker may take time to appear. Loss of any fixture guard ends the walk immediately.
            await Until(() => { RequirePage(); return Visible(id); }, Receipt(AboutGuard.RouteMarker));
            RequirePage();
            RequireRoute(pane);
            if (frame != null) await shot(frame);
        }
        void Back(AboutPhase at, AboutPane source, string expected)
        {
            phase = at;
            RequirePage();
            RequireRoute(source); // Observation or capture may have yielded; a matching Back label alone is not a route.
            Require(page.CanGoBack, AboutGuard.BackStack);
            if (Visible("settings.back") is not HyperlinkButton back) throw Stop(AboutGuard.BackControl);
            Require(Within(back, page), AboutGuard.BackOwner);
            Require(back.IsEnabled, AboutGuard.BackEnabled);
            Require(back.NavigateUri == null, AboutGuard.BackUri);
            Require(Equals(back.Content, "‹ " + expected), AboutGuard.BackLabel);
            Invoke(back); // The original app-owned control; never desktop input, focus, or a fallback.
        }

        if (fromLicenseText)
        {
            await Observe(AboutPhase.ObserveNotice, AboutPane.Notice);
            Back(AboutPhase.NoticeToLicenses, AboutPane.Notice, LicenseNotices.PageTitle);
            await Observe(AboutPhase.ObserveLicenses, AboutPane.Licenses);
            Back(AboutPhase.LicensesToDetail, AboutPane.Licenses, "About");
        }
        await Observe(fromLicenseText ? AboutPhase.ObserveLicensesDetail : AboutPhase.ObserveLoggingDetail, AboutPane.Detail,
            fromLicenseText ? "licenses-back-about-detail" : null);
        Back(fromLicenseText ? AboutPhase.LicensesDetailToCategory : AboutPhase.LoggingDetailToCategory, AboutPane.Detail, "About");
        await Observe(fromLicenseText ? AboutPhase.ObserveLicensesCategory : AboutPhase.ObserveLoggingCategory, AboutPane.Category,
            fromLicenseText ? "licenses-back-about-category" : "detailed-log-back-about-category");
    }
}
