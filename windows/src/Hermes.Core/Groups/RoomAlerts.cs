using System.Globalization;
using System.Text;
using Hermes.Core.Notifications;

namespace Hermes.Core.Groups;

/// [groups] The alert for a member's reply that lands while its room is off screen (App/Groups/AppModel+Groups.swift
/// GroupsHub: `focused`, `speakers`, `setFocused`, `replied`, `alertSpeaker`, `alertId`; docs/spec/3x-groups.md §7.15).
/// The decision is made here and posted through the app's own local alerts (LocalAlerts.ObserveRoomReply, the Mac's
/// NotificationHub.post); the platform only shows the toast it returns. `active`: the app is on screen (the Mac's
/// `UIApplication.shared.applicationState == .active`).
public sealed class RoomAlerts(LocalAlerts alerts, Func<bool> active)
{
    private readonly object _gate = new();
    /// Who spoke last in each room (by the room's mute key), for the face on its alert.
    private readonly Dictionary<string, string> _speakers = [];

    /// The room on screen (its uid).
    public Guid? Focused { get { lock (_gate) return _focused; } }
    private Guid? _focused;

    /// A room's screen came on or went (GroupsHub.setFocused). A room on screen is no chat of the notification hub's:
    /// its members' replies are told apart here (`model?.notificationsFocus(runtime: nil, stored: nil)`).
    public void SetFocused(Guid uid, bool on)
    {
        lock (_gate)
        {
            if (on) _focused = uid;
            else if (_focused == uid) _focused = null;
        }
        if (on) alerts.Focus(null, null);
    }

    /// The account left (GroupsHub.tearDown): no room on screen, nobody spoke.
    public void Clear()
    {
        lock (_gate)
        {
            _focused = null;
            _speakers.Clear();
        }
    }

    /// A member's reply arrived in `room` (GroupEngine.OnReply → GroupsHub.replied): the room on screen shows it itself
    /// (no alert and no peek over its title, as a bot's open chat); any other room alerts as a message.complete from
    /// the member, in the room, under the room's mute.
    public AlertDecision Replied(GroupRoom room, GroupMessage entry, GroupSeat? seat)
    {
        var muteKey = GroupKeys.MuteKey(room.Key);
        lock (_gate)
        {
            if (room.Uid == _focused && active()) return AlertDecision.Skip("room on screen");
            if (seat != null) _speakers[muteKey] = seat.Name;
        }
        var name = seat?.Display ?? entry.From.Name;
        var who = new NotificationWho(Sender: name, Chat: "", Group: room.Name, Bot: true);
        // The room's mute, not the member's: the entry's profile is the room's mute key.
        var session = AlertId(room);
        var alert = new LocalAlertEntry(who, session, muteKey);
        return alerts.ObserveRoomReply(session, MessageId(entry), NotificationText.Preview(entry.Text), alert, Face(muteKey));
    }

    /// The member whose face a room's alert wears: the one who spoke (`profile` is the alert's, the room's mute key).
    public string? AlertSpeaker(string profile)
    {
        lock (_gate) return _speakers.GetValueOrDefault(profile);
    }

    /// The face an alert for `profile` wears (AppModel+Notifications.swift peekFace: `alertSpeaker(profile) ?? profile`).
    public string Face(string profile) => AlertSpeaker(profile) ?? profile;

    /// The alert's request id: `room:` and the entry's id, or its time in whole milliseconds when it has none.
    public static string MessageId(GroupMessage entry) =>
        "room:" + (entry.Id ?? ((long)entry.At).ToString(CultureInfo.InvariantCulture));

    /// An id the notification rules accept (letters, digits, `_`, `-`).
    public static string AlertId(GroupRoom room)
    {
        var raw = "room-" + (room.RoomId ?? room.Name);
        var clean = new StringBuilder();
        foreach (var rune in raw.EnumerateRunes())
            clean.Append(Alphanumeric(rune) || rune.Value is '-' or '_' ? rune.ToString() : "-");
        // Swift's `prefix(120)` counts characters (grapheme clusters), as .NET's text elements do.
        var text = clean.ToString();
        var info = new StringInfo(text);
        return info.LengthInTextElements <= 120 ? text : info.SubstringByTextElements(0, 120);
    }

    /// Foundation's CharacterSet.alphanumerics: the Unicode letters, marks and numbers (L*, M*, N*).
    private static bool Alphanumeric(Rune rune) => Rune.GetUnicodeCategory(rune) switch
    {
        UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter or UnicodeCategory.TitlecaseLetter
            or UnicodeCategory.ModifierLetter or UnicodeCategory.OtherLetter
            or UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark
            or UnicodeCategory.DecimalDigitNumber or UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber => true,
        _ => false,
    };
}
