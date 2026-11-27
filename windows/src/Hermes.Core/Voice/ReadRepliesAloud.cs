using Hermes.Core.Settings;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Voice;

/// [WIN-62] Read Replies Aloud in a chat (docs/spec/3x-talk.md §7.3-§7.4; at 93f984bb1): the ⋯ menu's switch row
/// (App/Chat/Voice/ChatReadAloudHost.swift `repliesItem`, its tick the switch's state), the notice the chat shows when it
/// is switched (`saySwitch`: on the Mac the menu closes on the click, so the chat says what the switch is now), and the
/// quiet speaker in the header while it is on, whose menu says what it is and turns it off
/// (App/Chat/ChatViewController.swift `makeReadAloudButton`, `showsReadAloudButton`). The switch itself is
/// `VoicePrefs.ReadsRepliesAloud`, kept on this PC under the Mac's key (TalkController.readsRepliesAloud).
public static class ReadRepliesAloud
{
    public const string MenuTitle = "Read Replies Aloud";
    public const string IsOn = "Read Replies Aloud is on";
    public const string IsOff = "Read Replies Aloud is off";
    /// The speaker's menu title (`UIMenu(title: "Replies are read aloud")`) and its one item.
    public const string IndicatorTitle = "Replies are read aloud";
    public const string StopTitle = "Stop Reading Replies Aloud";
    /// The speaker's VoiceOver label, which is also its tip on the Mac (`applyHeaderTips`).
    public const string IndicatorName = IsOn;
    public const string MenuId = "chat.menu.read-replies";
    public const string IndicatorId = "chat.readAloud";
    public const string StopId = "chat.readAloud.off";
    /// The chat's notice without an action stays 3 s (ChatChrome.swift `NoticeToast.show`).
    public static readonly TimeSpan NoticeDuration = TimeSpan.FromSeconds(3);

    public static string Notice(bool on) => on ? IsOn : IsOff;

    /// The ⋯ row: the switch flips and the chat says what it is now.
    public static string Toggle(IPreferences prefs)
    {
        var on = !VoicePrefs.ReadsRepliesAloud(prefs);
        VoicePrefs.SetReadsRepliesAloud(prefs, on);
        return Notice(on);
    }

    /// The speaker's Stop Reading Replies Aloud: off, and the chat says so.
    public static string TurnOff(IPreferences prefs)
    {
        VoicePrefs.SetReadsRepliesAloud(prefs, false);
        return IsOff;
    }

    /// The header's speaker shows while this chat offers the row (a bot's chat: `slotItems[.readAloud]`) and the switch
    /// is on (`showsReadAloudButton`).
    public static bool ShowsIndicator(bool offered, bool switchOn) => offered && switchOn;

    /// Where the row goes in the ⋯ menu.
    public sealed record Placement(int Index, bool SeparatorBefore, bool SeparatorAfter);

    /// The Mac's ⋯ sections (ChatMenus.swift `macSections`): the chat itself (Model, Pin, Unread, Rename…), then what it
    /// does as you watch (Read Replies Aloud), then its tools (Prompts…, Usage & Limits, Model Prices). `titles` are the
    /// menu's rows as they stand (null: a separator); `toolsFirst` is the tools' first row.
    public static Placement Place(IReadOnlyList<string?> titles, string toolsFirst)
    {
        var tools = -1;
        for (var i = 0; i < titles.Count; i++)
            if (titles[i] == toolsFirst) { tools = i; break; }
        if (tools < 0) return new(titles.Count, SeparatorBefore: titles.Count > 0 && titles[^1] != null, SeparatorAfter: false);
        var separated = tools > 0 && titles[tools - 1] == null;
        return new(tools, SeparatorBefore: !separated && tools > 0, SeparatorAfter: true);
    }
}
