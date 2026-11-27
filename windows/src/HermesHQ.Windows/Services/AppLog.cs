namespace HermesHQ.Services;

/// %LOCALAPPDATA%\HermesHQ\logs\hermes-hq.log. Never logs tokens, cookies, passwords or message text.
public static class AppLog
{
    private static readonly object Gate = new();
    private static readonly string FilePath = Path.Combine(AppPaths.Root, "logs", "hermes-hq.log");

    /// Every note as it is written (Settings › About › Diagnostics keeps the failures for Recent errors).
    public static event Action<string, string>? Noted;

    public static void Note(string area, string text)
    {
        try { Noted?.Invoke(area, text); } catch (Exception) { /* a listener never stops the log */ }
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
                if (File.Exists(FilePath) && new FileInfo(FilePath).Length > 2_000_000)
                    File.Move(FilePath, FilePath + ".1", overwrite: true);
                File.AppendAllText(FilePath, $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss.fff} [{area}] {text}{Environment.NewLine}");
            }
        }
        catch (Exception) { /* best-effort file sink, including read-only or inaccessible storage */ }
    }

    public static void Error(string area, Exception e) => Note(area, $"{e.GetType().Name}: {e.Message}");
}

public static class AppPaths
{
    public static string Root { get; } = Automation.AppOnly
        ? Path.Combine(Path.GetDirectoryName(Path.GetFullPath(Environment.GetEnvironmentVariable("HQW_AUTOMATION")!))!, "app-data")
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "HermesHQ");
    public static string Transcripts => Path.Combine(Root, "transcripts");
    /// What the sidebar of each gateway last showed (the gateway news check reads it).
    public static string Lists => Path.Combine(Root, "lists");
}
