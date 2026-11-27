using System.Globalization;

namespace Hermes.Core.Groups;

/// [WIN-57] A room's Activity (App/Groups/GroupInfoSheet.swift GroupActivityController / GroupActivityView, opened by
/// the room's ⋯ › Activity, GroupRoomChrome.swift `actions.activity()`): titled "Activity", the current turn's events
/// newest first, each a symbol, its words (`GroupRowWords.activity`, red for a failure or a timeout) and its time
/// (`formatted(date: .omitted, time: .shortened)`); with none, "No activity in this turn yet.". A member's name is the
/// store's label for it (`GroupStore.labels`), else its key.
public static class GroupActivitySheet
{
    public const string Title = "Activity";
    public const string Empty = "No activity in this turn yet.";
    public const string ListId = "group-activity.list";
    public const string EmptyId = "group-activity.empty";
    public static string RowId(int index) => $"group-activity.row.{index}";

    public sealed record Row(string Text, string Symbol, string Glyph, bool Red, string Time)
    {
        /// The row read as one (`.accessibilityElement(children: .combine)`): the words, then the time.
        public string AccessibleName => Time.Length == 0 ? Text : $"{Text}, {Time}";
    }

    public static IReadOnlyList<Row> Rows(IReadOnlyList<GroupActivityEvent> events, IReadOnlyDictionary<string, string> labels, TimeZoneInfo zone, CultureInfo culture)
    {
        var rows = new List<Row>(events.Count);
        for (var i = events.Count - 1; i >= 0; i--)
        {
            var e = events[i];
            var line = GroupRowWords.Activity(e, labels.TryGetValue(e.Member, out var name) ? name : e.Member);
            var at = TimeZoneInfo.ConvertTime(DateTimeOffset.FromUnixTimeMilliseconds((long)e.At), zone);
            rows.Add(new Row(line.Text, line.Symbol, Glyph(line.Symbol), line.Red, ShortTime(at, culture)));
        }
        return rows;
    }

    /// The culture's short time, with ICU's narrow no-break space before AM/PM as a plain space (as the Mac shows it).
    public static string ShortTime(DateTimeOffset at, CultureInfo culture) =>
        at.ToString("t", culture).Replace('\u202F', ' ').Replace('\u00A0', ' ');

    /// The Mac's SF Symbol as its Segoe Fluent Icons glyph ("" for one it doesn't use).
    public static string Glyph(string symbol) => symbol switch
    {
        "bubble.left" => "\uE8BD",                   // Message
        "arrow.triangle.2.circlepath" => "\uE895",   // Sync
        "checkmark" => "\uE73E",                     // CheckMark
        "circle" => "\uEA3A",                        // CircleRing
        "clock" => "\uE823",                         // Recent
        "exclamationmark.circle" => "\uE783",        // Error
        "xmark" => "\uE711",                         // Cancel
        "checkmark.circle" => "\uE930",              // Completed
        "forward.end" => "\uE893",                   // Next
        "envelope.open" => "\uE8C3",                 // Read
        "pause" => "\uE769",                         // Pause
        "stop" => "\uE71A",                          // Stop
        _ => "",
    };
}
