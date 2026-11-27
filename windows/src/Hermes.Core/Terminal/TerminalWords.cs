namespace Hermes.Core.Terminal;

/// The words the Terminal page shows over its panel (App/Terminal/TerminalViewController.swift `render`, `stopped`,
/// `TerminalConsentWords`). `Glyph` is the Mac's SF Symbol name; the page maps it.
public static class TerminalWords
{
    public sealed record Card(string Glyph, string Title, string Body, string? Button = null, string? Secondary = null,
        bool Dim = false);

    /// What the lock is called here (the Mac's Touch ID / Face ID): Windows Hello asks for a face, a finger or the PIN.
    public const string UnlockName = "Windows Hello";
    public const string UnlockMeans = "Windows Hello or your PIN";

    public static string ComputerName(string? label) => string.IsNullOrEmpty(label) ? "This Computer" : label;

    public static Card Unlock(string computer) =>
        new("lock.fill", "Unlock the Terminal", $"Use {UnlockMeans} to open a shell on {computer}.");

    public sealed record Point(string Glyph, string Lead, string Rest, bool Warning = false);

    /// The consent card's three points: what it does (the risk, in orange), when to turn it on, and the unlock asked
    /// each time (left out when no unlock is set).
    public static List<Point> ConsentPoints(bool unlock)
    {
        var o = new List<Point>
        {
            new("exclamationmark.triangle.fill", "What you type runs on that computer,", " with the same access Hermes has there, including its files.", true),
            new("checkmark.shield", "Turn it on only for a computer you trust.", ""),
        };
        if (unlock) o.Add(new("lock", $"{UnlockMeans[..1].ToUpperInvariant()}{UnlockMeans[1..]} is asked", " each time the Terminal opens."));
        return o;
    }

    public static Card Consent(string computer, bool unlock) =>
        new("terminal", $"Open a Terminal on {computer}?", string.Join(" ", ConsentPoints(unlock).Select(p => p.Lead + p.Rest)),
            "Turn On", "Not Now");

    public static Card Off(string computer) =>
        new("terminal", "Terminal Is Off", $"Turn it on to type commands on {computer}. They run with the same access Hermes has there.", "Turn On");

    public static Card Locked(string? why) =>
        new("lock.fill", "Terminal Locked", why ?? $"Unlock with {UnlockMeans} to open the shell.", "Unlock");

    public static Card LockedAgain(string? why) =>
        new("lock.fill", "Terminal Locked", why ?? $"Unlock with {UnlockMeans} to see the shell again.", "Unlock");

    /// Why the lock can't be asked for at all.
    public const string CantCheck = $"This PC can’t check {UnlockName} right now. You can turn off Require {UnlockName} in the ⋯ menu.";

    public static Card NeedsAddOn(string computer, bool asked) =>
        new("arrow.down.circle", "Update the Add-on",
            asked ? $"Once the Hermes HQ add-on on {computer} is updated and Hermes has restarted, try again."
                  : $"The Terminal needs version 0.9.25 or later of the Hermes HQ add-on on {computer}.",
            asked ? "Try Again" : "Update Add-on");

    public const string Connecting = "Connecting…";
    public const string Opening = "Opening a shell…";
    public const string Reconnecting = "Reconnecting…";

    public static Card Ended(int? code, bool endedHere) =>
        new("checkmark.circle", "Shell Ended",
            endedHere ? "You ended this shell." : code is { } c ? $"It exited with code {c}." : "The shell has closed.", "New Shell", Dim: true);

    public static Card Stopped(TerminalWire.Ending ending, string computer) => ending.Kind switch
    {
        TerminalWire.EndingKind.Replaced => new("rectangle.on.rectangle", "Open in Another Window",
            "This shell was opened somewhere else in the app.", "Open Here"),
        TerminalWire.EndingKind.Off => new("terminal", $"Turned Off on {computer}",
            "The Terminal was turned off on that computer. To turn it back on, delete terminal.off from the Hermes HQ add-on’s data folder there."),
        TerminalWire.EndingKind.Unsupported => new("exclamationmark.triangle", "No Terminal Here",
            $"{computer} can’t open a terminal. On a Windows computer, run hermes pm repair there, then restart Hermes."),
        TerminalWire.EndingKind.Full => new("square.stack.3d.up", "Too Many Shells Open",
            $"{computer} has {TerminalSettings.MaxTabs} shells open. Close a tab or end one in another window, or wait a few minutes.", "Try Again"),
        TerminalWire.EndingKind.Refused => new("exclamationmark.triangle", "Couldn’t Open a Shell", ending.Reason ?? "The computer refused the terminal.", "Try Again"),
        TerminalWire.EndingKind.Blocked => new("shield.lefthalf.filled", "Terminal Blocked on the Way",
            $"Something between this PC and {computer} turned the Terminal away. If you set up the connection with the Hermes HQ connect command, run that command again on {computer} to update it, then try again.",
            "Try Again"),
        TerminalWire.EndingKind.Unreachable => new("exclamationmark.triangle", "Can’t Reach the Shell",
            $"{computer} didn’t open a shell after several tries. Check that Hermes is running there, then try again.", "Try Again"),
        _ => new("exclamationmark.triangle", "Disconnected", $"The link to {computer} closed.", "Try Again"),
    };

    // MARK: Questions (alerts)

    public static (string Title, string Message) PasteAsk(int lines) =>
        (lines == 1 ? "Paste and Run?" : $"Paste {lines} Lines?", "Each line runs as soon as it’s pasted, as if you typed it and pressed Return.");

    public static readonly (string Title, string Message) NewShellAsk = ("Start a New Shell?", "The shell open now ends, with anything still running in it.");
    public static readonly (string Title, string Message) EndShellAsk = ("End This Shell?", "Anything still running in it stops.");
    public static readonly (string Title, string Message) CloseTabAsk = ("Close This Tab?", "Its shell ends, with anything still running in it.");
    public static readonly (string Title, string Message) RenameAsk = ("Rename Tab", "Leave it empty to name it after what runs in it.");

    /// How many lines a paste runs (a trailing newline doesn't count as a line of its own); 1 for a single line.
    public static int PasteLines(string text)
    {
        var lines = text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        return lines[^1].Length == 0 ? lines.Length - 1 : lines.Length;
    }

    /// Whether a paste asks first: more than one line, and the shell hasn't turned bracketed paste on.
    public static bool PasteAsks(string text, bool bracketed) =>
        !bracketed && text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n').Length > 1;
}
