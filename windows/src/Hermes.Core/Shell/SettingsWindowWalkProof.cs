namespace Hermes.Core.Shell;

/// [WIN-48] What the settings-window walk (HermesHQ.Windows Services/ProofWalks.SettingsWindow.cs) checks on the settings
/// stand-in: one window titled Settings, the main window as it was, and the category on show and marked. Null when so,
/// else what is wrong. Kept apart from WalkProof.cs so lanes don't collide.
public static class SettingsWindowWalkProof
{
    /// Exactly one Settings window, titled "Settings".
    public static string? OneWindow(int open, string? title)
    {
        if (open == 0) return "no Settings window is open";
        if (open != 1) return $"{open} Settings windows are open, not one";
        return title == Settings.SettingsWindowLayout.Title ? null : $"the Settings window is titled {title}";
    }

    /// The main window shows what it did before Settings opened, and not Settings.
    public static string? MainUnchanged(WalkFacts before, WalkFacts after, bool mainShowsSettings)
    {
        if (before.Pane != after.Pane || before.PlaceId != after.PlaceId || before.Profile != after.Profile || before.StoredId != after.StoredId)
            return $"the main window went from {WalkProof.Showing(before)} to {WalkProof.Showing(after)}";
        return mainShowsSettings ? "the main window shows Settings" : null;
    }

    /// The window's page is `expected`'s and its column marks it.
    public static string? ShowsCategory(string expected, string? pageTitle, string? marked)
    {
        if (pageTitle != expected) return $"the window shows {pageTitle}, not {expected}";
        return marked == expected ? null : $"the column marks {marked}, not {expected}";
    }
}
