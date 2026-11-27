using System.Text.Json;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Terminal;

/// What the Terminal page keeps on this PC (App/Terminal/TerminalSettings.swift, under the Mac's keys): whether the
/// person turned it on for a computer (per account), whether opening it asks for Windows Hello (on at first), the text
/// size and font, and the shells this PC has open there, one per tab, with the names given to the tabs.
public sealed class TerminalSettings(IPreferences prefs)
{
    public const int MaxTabs = 8;
    public const double MinSize = 8, MaxSize = 32;
    /// Windows draws at 100 %: Terminal.app's and Windows Terminal's 12 pt reads as 16 px here (the Mac's 16 at 77 %).
    public const double DefaultSize = 16;

    public bool Allowed(string account) => prefs.Get("hq.terminal.allowed." + account) == "true";
    public void SetAllowed(bool on, string account) => prefs.Set("hq.terminal.allowed." + account, on ? "true" : "false");

    /// Windows Hello (or the PC's PIN) each time the page opens. On at first.
    public bool RequiresUnlock
    {
        get => prefs.Get("hq.terminal.lock") != "false";
        set => prefs.Set("hq.terminal.lock", value ? "true" : "false");
    }

    public double FontSize
    {
        get => double.TryParse(prefs.Get("hq.terminal.fontSize"), System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture, out var v) && v > 0
            ? Math.Clamp(v, MinSize, MaxSize) : DefaultSize;
        set => prefs.Set("hq.terminal.fontSize", Math.Clamp(value, MinSize, MaxSize).ToString(System.Globalization.CultureInfo.InvariantCulture));
    }

    /// ⋯ › Font. Windows' own monospaced faces stand in for the Mac's: Cascadia Mono for SF Mono (the system's), Consolas
    /// for Menlo. Hack Nerd Font is used when it is installed on the PC (the Mac ships it; this app doesn't yet), else
    /// the text falls back to Cascadia Mono. Kept under the Mac's values ("system", "menlo", "hack").
    public enum Face { System, Menlo, Hack }

    public static string Title(Face face) => face switch
    {
        Face.Menlo => "Consolas",
        Face.Hack => "Hack Nerd Font",
        _ => "Cascadia Mono",
    };

    /// The font family to draw with (fallbacks after the comma).
    public static string Family(Face face) => face switch
    {
        Face.Menlo => "Consolas, Cascadia Mono",
        Face.Hack => "Hack Nerd Font Mono, Hack Nerd Font, Cascadia Mono, Consolas",
        _ => "Cascadia Mono, Consolas",
    };

    public Face FontFace
    {
        get => prefs.Get("hq.terminal.font") switch { "menlo" => Face.Menlo, "hack" => Face.Hack, _ => Face.System };
        set => prefs.Set("hq.terminal.font", value switch { Face.Menlo => "menlo", Face.Hack => "hack", _ => "system" });
    }

    // MARK: Tabs

    /// The shells this PC has open on that computer, one per tab; a first one is made when there is none.
    public List<string> Sessions(string account)
    {
        var list = Strings("hq.terminal.sessions." + account).Where(TerminalWire.IsSession).Take(MaxTabs).ToList();
        if (list.Count == 0 && prefs.Get("hq.terminal.session." + account) is { } old && TerminalWire.IsSession(old)) list.Add(old);
        if (list.Count == 0)
        {
            list.Add(TerminalWire.NewSession());
            SetSessions(list, account);
        }
        return list;
    }

    public void SetSessions(IEnumerable<string> sessions, string account) => SetStrings("hq.terminal.sessions." + account, sessions);

    /// What the person named each tab, in tab order beside `Sessions`: "" for one named by what runs in it.
    public List<string> TabNames(string account) => Strings("hq.terminal.names." + account);
    public void SetTabNames(IEnumerable<string> names, string account) => SetStrings("hq.terminal.names." + account, names);

    public int SelectedTab(string account) => int.TryParse(prefs.Get("hq.terminal.tab." + account), out var v) ? v : 0;
    public void SetSelectedTab(int index, string account) => prefs.Set("hq.terminal.tab." + account, index.ToString());

    private List<string> Strings(string key)
    {
        if (prefs.Get(key) is not { } json) return [];
        try { return JsonSerializer.Deserialize<List<string>>(json) ?? []; } catch (JsonException) { return []; }
    }

    private void SetStrings(string key, IEnumerable<string> values) => prefs.Set(key, JsonSerializer.Serialize(values.ToList()));

    /// What each tab is called: its given name, else its number then the title its program set or its shell ("1 zsh",
    /// "2 vim"), else "Shell 2".
    public static List<string> TabTitles(IReadOnlyList<(string CustomName, string? Name)> tabs) =>
        [.. tabs.Select((t, i) => t.CustomName.Length > 0 ? t.CustomName : t.Name is { } n ? $"{i + 1} {n}" : $"Shell {i + 1}")];
}
