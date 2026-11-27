namespace Hermes.Core.Shell;

/// [WIN-54] What the read-aloud walk (HermesHQ.Windows/Services/ProofWalks.ReadAloud.cs) checks on the composer
/// stand-in's Trip planning chat: the reply's right-click menu carries Read Aloud between Copy and Share… (the Mac's
/// MessageMenuModel.tiles), it reads Stop Reading while that reply is read, and Stop Reading stops it. Each check answers
/// null when right, otherwise the words of what is wrong.
public static class ReadAloudWalkProof
{
    public const string ReadAloud = "Read Aloud";
    public const string StopReading = "Stop Reading";

    /// The menu's entries as shown: Copy, then Read Aloud (Stop Reading while `reading`), then Share…, none dimmed.
    public static string? MenuReads(IReadOnlyList<(string Title, bool Enabled)> entries, bool reading)
    {
        var row = reading ? StopReading : ReadAloud;
        if (!entries.Any(e => e.Title == row)) return $"the reply's menu has no {row}";
        string[] wanted = ["Copy", row, "Share…"];
        var titles = entries.Select(e => e.Title).Where(wanted.Contains).ToList();
        if (!titles.SequenceEqual(wanted)) return $"the reply's menu reads {string.Join(", ", titles)}, not {string.Join(", ", wanted)}";
        if (entries.First(e => e.Title == row) is { Enabled: false }) return $"{row} is dimmed on a settled reply";
        return null;
    }

    /// After Stop Reading: nothing is being read, and the voice was told to stop once.
    public static string? Stopped(string state, int stops)
    {
        if (state != "idle") return $"the reading is still {state} after Stop Reading";
        if (stops != 1) return $"the voice was stopped {stops} times, not once";
        return null;
    }
}
