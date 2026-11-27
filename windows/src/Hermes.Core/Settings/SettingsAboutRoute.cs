namespace Hermes.Core.Settings;

/// Where a search result, a deep link or another page's link to About's pages lands in the Settings pane
/// (App/Settings/SettingsNavigator.swift `openRoot` "about", "licenses", "about:<row>"; AboutView.swift `reveal`).
/// The category index (settings actions) and detail (version and logging) are different screens, both titled About.
/// The Mac keeps the index underneath the detail. Licenses goes over the detail, not directly over the index.
public static class SettingsAboutRoute
{
    /// The pane's root key for a category's own page (its title is the category's).
    public static string CategoryKey(SettingsCategory c) => "category:" + c.Key();

    /// The pages the pane holds, bottom first, after `target` opens; null when `target` is not one of About's.
    /// The same from any category, from the gateway card, from About itself or from a page over it.
    public static IReadOnlyList<string>? Pages(string target) => target switch
    {
        "about" or "about:detailed-log" or "about:perf-log" or "about:mark" => [CategoryKey(SettingsCategory.About), "about"],
        "licenses" => [CategoryKey(SettingsCategory.About), "about", "licenses"],
        _ => null,
    };

    /// The About row a target scrolls to and marks ("about.detailed-log"), or null.
    public static string? Reveal(string target) => target switch
    {
        "about:detailed-log" => "about.detailed-log",
        "about:perf-log" => "about.perf-log",
        "about:mark" => "about.mark",
        _ => null,
    };

    /// A page key's title in the pane (and so on the Back of the page over it).
    public static string Title(string key) => key switch
    {
        "about" => "About",
        "licenses" => LicenseNotices.PageTitle,
        _ when key.StartsWith("category:", StringComparison.Ordinal) =>
            SettingsCategories.All.FirstOrDefault(c => c.Key() == key["category:".Length..]).Title(),
        _ => key,
    };

    /// What Back says over the top page ("‹ About"), or null when the top page is the pane's first (no Back).
    public static string? BackLabel(IReadOnlyList<string> pages) => pages.Count > 1 ? "‹ " + Title(pages[^2]) : null;
}
