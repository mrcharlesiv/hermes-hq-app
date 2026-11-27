namespace HermesHQ.Shell;

/// A file in a window of its own (App/Mac/MacFileWindow.swift), for features that open files without knowing who
/// draws them: the Artifacts feature sets `Open` (ArtifactFileWindow.OpenRouted). It answers false when nothing here
/// draws the file (it then goes to its own app); unset, every file goes to its own app as before.
public static class FileWindows
{
    /// (path on this PC, name, path on the bot's computer or null) → true when a window took it, or said why not.
    public static Func<string, string, string?, bool>? Open { get; set; }
}
