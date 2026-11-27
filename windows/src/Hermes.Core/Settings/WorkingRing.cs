using Hermes.Core.Bots;
using Hermes.Core.Sessions;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Settings;

/// Settings › Appearance › Bots & Sessions › Working Ring (Mac 1240 App/Settings/AppPreferences.swift, `WorkingRing`).
/// Off unless enabled. While on, a working bot's row and a working chat's row wear the
/// ring that travels round them (Windows: `WorkingRingView`). Off: no ring anywhere; the face's working mark, the row's
/// "Working…" line and the spoken name still say it is busy. Kept on this PC (the preferences file), under the Mac's key.
public static class WorkingRing
{
    public const string Key = "hqn.workingRing";
    public const string Label = "Working Ring";
    public const string Note = "Working Ring is the moving line around a bot or chat while it works. Off, its working dots and “Working…” still show.";
    /// The Mac's section (`AppearanceSection.lists`).
    public const string SectionTitle = "Bots & Sessions";
    public const string AutomationId = "theme.workingRing";
    /// The row's id on the page and Settings search's target (the Mac's `row:working-ring`).
    public const string RowTarget = "row:working-ring";
    /// One lap of the ring (`WorkingArc.lap`).
    public const double LapSeconds = 2.23;
    /// [WIN-SESSIONS-WORKING-CHIP] A row's ring (`WorkingArc.rowLine` / `rowCorner`, 93f984bb1 App/Kit/WorkingArc.swift):
    /// 1.25 wide, on the row's own box, in the desktop row's 2 pt corner in the Desktop Look and a 14 pt card corner in
    /// the iOS look. It is decoration over the row (no focus visual, scroll bar or selection mark), and its two bright
    /// spikes travel round it, so a still picture can catch one alone at the row's edge.
    public const double RowLine = 1.25;
    public static double RowCorner(bool desktopLook) => desktopLook ? 2 : 14;

    public static IPreferences? Store { get; set; }
    /// After the switch changes here: the bot and session lists draw their rows again at once.
    public static event Action? Changed;

    /// Missing or malformed reads off, as on the Mac. FilePreferences stores these booleans as strings.
    public static bool Read(IPreferences? prefs) => prefs?.Get(Key) == "true";

    /// Store both choices explicitly on change, so a reader with the older default also sees the choice.
    public static bool Write(IPreferences? prefs, bool on)
    {
        if (prefs == null || Read(prefs) == on) return false;
        prefs.Set(Key, on ? "true" : "false");
        return true;
    }

    public static bool IsOn
    {
        get => Read(Store);
        set { if (Write(Store, value)) Changed?.Invoke(); }
    }

    /// `BotList.showsArc`: a running turn, not one waiting on the person (whose orange cue is the louder one).
    public static bool ShowsBotRing(BotRow bot, bool ringOn) => ringOn && bot.IsWorking && bot.NeedsInput == null;

    /// The chat row's `showsArc`: running, not waiting on the person.
    public static bool ShowsChatRing(SessionSummary chat, bool ringOn) => ringOn && chat.Status == SessionStatus.Working;

    /// The ring laps unless the system asks for less motion (`HQMotion.reduced`); then it stands still at its start.
    public static bool Travels(bool animationsEnabled) => animationsEnabled;

    /// A sidebar chat's spoken name: its title, then its live state ("Working", its step) so the state is heard with or
    /// without the ring.
    public static string ChatSpokenName(SessionSummary chat) =>
        SessionRowWords.StatusWords(chat.Status, chat.Step) is { } status ? $"{chat.Title}, {status.Replace("…", "")}" : chat.Title;
}
