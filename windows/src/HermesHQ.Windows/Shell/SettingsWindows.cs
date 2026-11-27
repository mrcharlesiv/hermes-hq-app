namespace HermesHQ.Shell;

/// [mac-layout] Settings in a window of its own (App/Mac/MacSettingsWindow.swift), for the shell's Settings commands
/// (Ctrl+, the sidebar foot's gear, Sidebar Settings…) without knowing who draws it: the Settings feature sets `Open`
/// (SettingsWindow.Open). It answers false when there is no main window to sit beside or the window couldn't be made;
/// Settings then opens in the main window, as it did.
public static class SettingsWindows
{
    /// (the page or row to show, or null) → true when the window took it.
    public static Func<string?, bool>? Open { get; set; }

    /// KeyCommands.hqSettings: the Settings window, else the Settings place.
    public static void Show(string? argument = null)
    {
        if (Open?.Invoke(argument) == true) return;
        Navigator.Open("settings", argument);
    }
}
