using System.Diagnostics;
using System.Text;

namespace Hermes.Core.Shell;

/// Transient receipt for the synthetic walk only. No free-text input; each mark is closed before the next step.
public sealed class WalkShutdownReceipt
{
    private readonly string _path;
    private WalkShutdownReceipt(string path) => _path = path;

    public static WalkShutdownReceipt? StartIn(string directory)
    {
        try
        {
            using var self = Process.GetCurrentProcess();
            var path = Path.Combine(directory, $"shutdown-{self.Id}.mark");
            // Only the reader of this child uses its OS creation FILETIME to distinguish PID reuse. Never published.
            var birth = self.StartTime.ToFileTimeUtc();
            using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            file.Write(Encoding.ASCII.GetBytes($"birth={birth:X16}\n"));
            return new(path);
        }
        catch (Exception) { return null; } // a receipt is optional, including when the process start time is unavailable
    }

    public void Step(ShutdownStage stage, ShutdownProgress progress)
    {
        if (Enum.IsDefined(stage) && Enum.IsDefined(progress))
            Mark($"{stage.ToString().ToLowerInvariant()}.{progress.ToString().ToLowerInvariant()}");
    }

    public void ExitRequested() => Mark("exit.requested");
    public void ExitReturned() => Mark("exit.returned");

    private void Mark(string value)
    {
        try { File.AppendAllText(_path, value + "\n"); }
        catch (Exception) { } // only the evidence write, never the actual exit
    }
}