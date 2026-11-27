using Hermes.Core.Settings;
using Hermes.Core.Voice;

namespace Hermes.Core.Shell;

/// [WIN-62] What the read-replies walk (HermesHQ.Windows/Services/ProofWalks.ReadRepliesAloud.cs) checks on the composer
/// stand-in's own bot chat: the ⋯ menu's Read Replies Aloud row (a switch with a tick, between Model and Prompts), the
/// notice the chat shows as it is switched, the switch kept on this PC, the stand-in's next reply handed to the voice
/// (the app's own log says so), the header's speaker with its menu, and, once it is off from that menu, nothing read and
/// no speaker. Each check answers null when right, otherwise the words of what is wrong.
public static class ReadRepliesAloudWalkProof
{
    public const string ReadLog = "read replies aloud: reading the newest reply";
    public const string Model = "Model";
    public const string Tools = Composer.PromptLibrary.Title;

    /// The ⋯ menu's rows as shown (title, its tick; null title: a separator; null tick: not a switch row).
    public static string? MenuRow(IReadOnlyList<(string? Title, bool? Checked)> entries, bool on)
    {
        var at = -1;
        for (var i = 0; i < entries.Count; i++)
            if (entries[i].Title == ReadRepliesAloud.MenuTitle) { at = i; break; }
        if (at < 0) return $"the ⋯ menu has no {ReadRepliesAloud.MenuTitle}";
        if (entries[at].Checked is not { } ticked) return $"{ReadRepliesAloud.MenuTitle} isn't a switch row with a tick";
        var model = -1;
        var tools = -1;
        for (var i = 0; i < entries.Count; i++)
        {
            if (entries[i].Title == Model && model < 0) model = i;
            if (entries[i].Title == Tools && tools < 0) tools = i;
        }
        if ((model >= 0 && at < model) || (tools >= 0 && at > tools))
            return $"{ReadRepliesAloud.MenuTitle} sits {(at > tools ? $"after {Tools}" : $"before {Model}")}, not between {Model} and {Tools}";
        if (ticked != on) return $"{ReadRepliesAloud.MenuTitle} is {(ticked ? "ticked" : "unticked")} while the switch is {(on ? "on" : "off")}";
        return null;
    }

    /// The chat's notice after the switch changed.
    public static string? Notice(string? shown, bool on)
    {
        var wanted = ReadRepliesAloud.Notice(on);
        if (shown == null) return $"the chat says nothing after the switch turned {(on ? "on" : "off")} ({wanted})";
        return shown == wanted ? null : $"the chat says “{shown}”, not “{wanted}”";
    }

    /// The switch as stored on this PC (the Mac's `hq.voice.readRepliesAloud`).
    public static string? Stored(string? value, bool on)
    {
        var wanted = on ? "true" : "false";
        return value == wanted ? null : $"{VoicePrefs.ReadRepliesKey} holds {value ?? "nothing"}, not {wanted}";
    }

    /// After the stand-in replied with the switch on: the voice was handed that reply once, with its words as a voice
    /// gets them, and the app's log says Read Replies Aloud read it.
    public static string? Read(int handed, IReadOnlyList<string> voiceLog, string? spoken, string replyWords)
    {
        if (handed != 1) return $"the voice was handed {handed} replies, not 1";
        if (!voiceLog.Contains(ReadLog)) return $"the app's log has no “{ReadLog}”";
        if (spoken != replyWords) return $"the voice was handed “{spoken}”, not the reply’s words “{replyWords}”";
        return null;
    }

    /// The header's speaker while the switch is on: shown, named and tipped as the Mac's, its menu its title then Stop.
    public static string? Indicator(bool shown, string? name, string? tip, IReadOnlyList<string> menu)
    {
        if (!shown) return "the header shows no speaker while Read Replies Aloud is on";
        if (name != ReadRepliesAloud.IndicatorName) return $"the header's speaker is named “{name}”, not “{ReadRepliesAloud.IndicatorName}”";
        if (tip != ReadRepliesAloud.IndicatorName) return $"the header's speaker has no tip “{ReadRepliesAloud.IndicatorName}”";
        string[] wanted = [ReadRepliesAloud.IndicatorTitle, ReadRepliesAloud.StopTitle];
        if (!menu.SequenceEqual(wanted)) return $"the speaker's menu reads {string.Join(", ", menu)}, not {string.Join(", ", wanted)}";
        return null;
    }

    /// After Stop Reading Replies Aloud and the stand-in's next reply: nothing handed to the voice, nothing logged as
    /// read, and the speaker gone from the header.
    public static string? NotRead(int handed, int logged, bool indicatorShown)
    {
        if (handed != 0) return $"the voice was handed {handed} {(handed == 1 ? "reply" : "replies")} with Read Replies Aloud off";
        if (logged != 0) return $"the app's log says it read {logged} {(logged == 1 ? "reply" : "replies")} with Read Replies Aloud off";
        if (indicatorShown) return "the header still shows the speaker with Read Replies Aloud off";
        return null;
    }
}
