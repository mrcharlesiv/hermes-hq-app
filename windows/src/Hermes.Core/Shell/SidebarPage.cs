namespace Hermes.Core.Shell;

/// Settings › Appearance › Sidebar, the Mac's TabOrderPage at 93f984bb1 (App/Settings/TabOrderPage.swift; the row is
/// AppearancePage's `tabsRow` in its App section, "Sidebar" with sidebar.left, `settings.tab-order`). Its words and ids;
/// the rules are `SidebarLayout`'s (the Mac's `TabOrder.tabs`, which the sidebar's own menu edits too).
/// Not on Windows (no surface here): Bots in Sidebar (Windows builds only the bots listed in the sidebar), the Kanban or
/// Artifacts picker (Windows has no Kanban Tab choice: Artifacts and Kanban are places of their own), and a page's
/// "Not on this gateway" (Windows' places don't come from the gateway).
public static class SidebarPage
{
    /// `SettingsWords.tabsPageTitle()` on the Mac.
    public const string Title = "Sidebar";
    /// The Settings target that opens the page (the Mac's root "tab-order"; the sidebar's Sidebar Settings… opens it).
    public const string Target = "sidebar";
    public const string RowId = "settings.tab-order";
    /// AppearanceSections.Part.app: the row's section, last on Appearance.
    public const string AppSection = "App";

    /// `barName` on the Mac.
    public const string ShownHeader = "Sidebar";
    public const string AddHeader = "Add to Sidebar";
    public const string UseDefault = "Use Default Tabs";
    public const string UseDefaultId = "tab-order.default";

    /// `addFooter` on the Mac, its "Control‑click" (DeviceWord.hold) as Windows' right-click.
    public const string AddFooter = "These pages already show in the sidebar under Tools, or open from Settings. Turn one on to move it up "
        + "to the places above. You can also right-click a row under Tools and choose Move to Places.";

    /// `barFooter` on the Mac. Bots is never hidden on Windows (the bots stand in the sidebar), so only Sessions' clause can show.
    public static string ShownFooter(IReadOnlyCollection<string> shown)
    {
        var words = "Bots or Sessions always stays: chats open there.";
        if (!shown.Contains("sessions")) words += " With Sessions hidden, a chat opens on Bots.";
        return words;
    }

    /// `tab-order.<TabChoice.key>`: a main tab by its key (Artifacts is tab 3, "workspace"), a page as "page.<id>".
    public static string RowAutomationId(string placeId) => "tab-order." + placeId switch
    {
        "sessions" or "jobs" => placeId,
        "artifacts" => "workspace",
        _ => "page." + placeId,
    };
}
