using System.Text;
using Hermes.Core.Gateways;

namespace Hermes.Core.Jobs;

/// The job editor's seven frequency presets (HermesKit/Pages/JobSchedule.swift, docs/spec/3x-jobs.md §6.5).
public enum JobFrequency { Daily, Weekdays, Weekly, Monthly, Hourly, Every15, Custom }

public static class JobFrequencies
{
    public static readonly JobFrequency[] All =
        [JobFrequency.Daily, JobFrequency.Weekdays, JobFrequency.Weekly, JobFrequency.Monthly, JobFrequency.Hourly, JobFrequency.Every15, JobFrequency.Custom];

    /// The picker's word.
    public static string Title(this JobFrequency f) => f switch
    {
        JobFrequency.Daily => "Daily",
        JobFrequency.Weekdays => "Weekdays",
        JobFrequency.Weekly => "Weekly",
        JobFrequency.Monthly => "Monthly",
        JobFrequency.Hourly => "Hourly",
        JobFrequency.Every15 => "Every 15 minutes",
        _ => "Custom",
    };

    /// The chip's word ("Every 15 Min" fits the row).
    public static string ChipTitle(this JobFrequency f) => f == JobFrequency.Every15 ? "Every 15 Min" : f.Title();

    /// The preset's own expression; null for Custom.
    public static string? PresetExpr(this JobFrequency f) => f switch
    {
        JobFrequency.Daily => "0 9 * * *",
        JobFrequency.Weekdays => "0 9 * * 1-5",
        JobFrequency.Weekly => "0 9 * * 1",
        JobFrequency.Monthly => "0 9 1 * *",
        JobFrequency.Hourly => "0 * * * *",
        JobFrequency.Every15 => "*/15 * * * *",
        _ => null,
    };

    /// The presets with time and day controls.
    public static bool IsTimed(this JobFrequency f) => f is not (JobFrequency.Every15 or JobFrequency.Custom);
}

/// The time and day a cron line pins down, over the web's defaults (9:00, Monday, the 1st).
public sealed record JobTimeFields
{
    public int Hour { get; init; } = 9;
    public int Minute { get; init; }
    private readonly int[] _weekdays = [1];
    /// Weekly's days, 0 = Sunday … 6 = Saturday, sorted, never empty.
    public int[] Weekdays { get => _weekdays; init => _weekdays = CleanDays(value); }
    public int Day { get; init; } = 1;

    public JobTimeFields() { }
    public JobTimeFields(int hour = 9, int minute = 0, int weekday = 1, int day = 1)
    { Hour = hour; Minute = minute; _weekdays = [weekday]; Day = day; }
    public JobTimeFields(int hour, int minute, int[] weekdays, int day = 1)
    { Hour = hour; Minute = minute; _weekdays = CleanDays(weekdays); Day = day; }

    public int Weekday => _weekdays.FirstOrDefault(1);

    /// Sorted, 7 read as Sunday, no repeats; nothing left is Monday.
    public static int[] CleanDays(IEnumerable<int> days)
    {
        var clean = days.Where(d => d is >= 0 and <= 7).Select(d => d % 7).Distinct().Order().ToArray();
        return clean.Length == 0 ? [1] : clean;
    }

    public bool Equals(JobTimeFields? other) => other is not null && Hour == other.Hour && Minute == other.Minute
        && Day == other.Day && _weekdays.SequenceEqual(other._weekdays);

    public override int GetHashCode() => HashCode.Combine(Hour, Minute, Day, string.Join(",", _weekdays));
}

public static class JobSchedule
{
    public static string ClockNote => $"Times follow the clock on {HostWord.Phrase}.";
    public const string CustomPlaceholder = "0 9 * * * or weekdays at 9am";
    public const string CustomHint = "Cron expression, or phrases like \"every hour\" or \"weekdays at 9am\".";

    private static string Normalized(string expr) => string.Join(" ", expr.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    private static string[]? Parts(string expr)
    {
        var p = expr.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        return p.Length == 5 ? p : null;
    }

    private static bool IsInteger(string t) => t.Length > 0 && t.All(c => c is >= '0' and <= '9');

    private static int? InRange(string token, int low, int high) =>
        IsInteger(token) && int.TryParse(token, out var v) && v >= low && v <= high ? v : null;

    /// The preset an expression opens on; anything it cannot classify is Custom.
    public static JobFrequency Frequency(string expr)
    {
        var line = Normalized(expr);
        foreach (var f in JobFrequencies.All) if (f.PresetExpr() == line) return f;
        if (Parts(line) is not { } p) return JobFrequency.Custom;
        var (minute, hour, dayOfMonth, month, dayOfWeek) = (p[0], p[1], p[2], p[3], p[4]);
        var timed = InRange(minute, 0, 59) != null && InRange(hour, 0, 23) != null;
        if (dayOfMonth == "*" && month == "*" && dayOfWeek == "*" && timed) return JobFrequency.Daily;
        if (dayOfMonth == "*" && month == "*" && dayOfWeek == "1-5" && timed) return JobFrequency.Weekdays;
        if (dayOfMonth == "*" && month == "*" && DayList(dayOfWeek) != null && timed) return JobFrequency.Weekly;
        if (month == "*" && dayOfWeek == "*" && InRange(dayOfMonth, 1, 31) != null && timed) return JobFrequency.Monthly;
        if (hour == "*" && dayOfMonth == "*" && month == "*" && dayOfWeek == "*" && InRange(minute, 0, 59) != null) return JobFrequency.Hourly;
        return JobFrequency.Custom;
    }

    /// Weekly's days as written: one day number or a comma list of them ("1,3,5"), 0-7.
    public static int[]? DayList(string token)
    {
        var days = new List<int>();
        foreach (var piece in token.Split(','))
        {
            if (InRange(piece, 0, 7) is not { } d) return null;
            days.Add(d);
        }
        return days.Count == 0 ? null : JobTimeFields.CleanDays(days);
    }

    /// Only plain numbers (and Weekly's list of days) count; everything else keeps `base`.
    public static JobTimeFields Fields(string expr, JobTimeFields? @base = null)
    {
        var out_ = @base ?? new JobTimeFields();
        if (Parts(expr) is not { } p) return out_;
        if (InRange(p[0], 0, 59) is { } minute) out_ = out_ with { Minute = minute };
        if (InRange(p[1], 0, 23) is { } hour) out_ = out_ with { Hour = hour };
        if (InRange(p[2], 1, 31) is { } day) out_ = out_ with { Day = day };
        if (DayList(p[4]) is { } days) out_ = out_ with { Weekdays = days };
        return out_;
    }

    /// Every 15 minutes and Custom have no fields: their own line (Custom: "").
    public static string Compose(JobFrequency frequency, JobTimeFields f) => frequency switch
    {
        JobFrequency.Hourly => $"{f.Minute} * * * *",
        JobFrequency.Weekdays => $"{f.Minute} {f.Hour} * * 1-5",
        JobFrequency.Weekly => $"{f.Minute} {f.Hour} * * " + string.Join(",", JobTimeFields.CleanDays(f.Weekdays)),
        JobFrequency.Monthly => $"{f.Minute} {f.Hour} {f.Day} * *",
        JobFrequency.Daily => $"{f.Minute} {f.Hour} * * *",
        JobFrequency.Every15 => "*/15 * * * *",
        _ => "",
    };

    /// The line a preset switch starts from: a timed preset keeps the time and day `current` already set; going to
    /// Custom keeps the current expression.
    public static string Expression(JobFrequency preset, string current)
    {
        if (preset.PresetExpr() is not { } own) return current;
        return preset.IsTimed() ? Compose(preset, Fields(current, Fields(own))) : own;
    }

    /// The hourly minute choices: :00 … :55, plus the current minute when it is off the grid.
    public static List<int> MinuteChoices(int current)
    {
        var grid = Enumerable.Range(0, 12).Select(i => i * 5).ToList();
        if (!grid.Contains(current)) { grid.Add(current); grid.Sort(); }
        return grid;
    }

    /// "9:00 AM" or "09:00".
    public static string Clock(int hour, int minute, bool uses24Hour)
    {
        if (uses24Hour) return $"{hour:00}:{minute:00}";
        var h = hour % 12 == 0 ? 12 : hour % 12;
        return $"{h}:{minute:00}" + (hour < 12 ? " AM" : " PM");
    }

    /// The sentence under the fields. Empty for Custom.
    public static string Summary(JobFrequency frequency, string expr, bool uses24Hour = false)
    {
        if (Parts(expr) is not { } p) return frequency == JobFrequency.Every15 ? "Every 15 minutes" : "";
        var time = IsInteger(p[0]) && IsInteger(p[1]) && int.TryParse(p[1], out var hour) && int.TryParse(p[0], out var minute)
            && hour is >= 0 and <= 23 && minute is >= 0 and <= 59 ? Clock(hour, minute, uses24Hour) : $"{p[1]}:{p[0]}";
        switch (frequency)
        {
            case JobFrequency.Daily: return $"Every day at {time}";
            case JobFrequency.Weekdays: return $"Weekdays at {time}";
            case JobFrequency.Weekly:
                if (DayList(p[4]) is not { } days) return $"Every day {p[4]} at {time}";
                if (days.Length == 1) return $"Every {JobWords.Days[days[0]]} at {time}";
                if (days.Length == 7) return $"Every day at {time}";
                if (days.SequenceEqual([1, 2, 3, 4, 5])) return $"Weekdays at {time}";
                if (days.SequenceEqual([0, 6])) return $"Weekends at {time}";
                return $"Every {DayNames(days)} at {time}";
            case JobFrequency.Monthly: return $"Monthly on day {p[2]} at {time}";
            case JobFrequency.Hourly: return p[0] == "0" ? "At the top of every hour" : "Every hour at :" + (p[0].Length < 2 ? "0" + p[0] : p[0]);
            case JobFrequency.Every15: return "Every 15 minutes";
            default: return "";
        }
    }

    /// "Mon, Wed and Fri", Monday first (Sunday last).
    public static string DayNames(IEnumerable<int> days)
    {
        var names = days.OrderBy(d => (d + 6) % 7).Select(d => JobWords.ShortDays[d]).ToList();
        if (names.Count <= 1) return names.FirstOrDefault() ?? "";
        return string.Join(", ", names.Take(names.Count - 1)) + " and " + names[^1];
    }

    /// When a schedule next fires, on the gateway's clock (`hostOffset` minutes east of UTC; the PC's zone when null).
    public static DateTimeOffset? NextRun(string expr, int? hostOffset, DateTimeOffset? now = null, TimeZoneInfo? zone = null) =>
        JobWords.NextCronFire(CleanCustom(expr), now ?? DateTimeOffset.Now, hostOffset, zone);

    /// "Months without day 31 skip this run." above 28.
    public static string? SkipNote(JobFrequency frequency, JobTimeFields fields) =>
        frequency == JobFrequency.Monthly && fields.Day > 28 ? $"Months without day {fields.Day} skip this run." : null;

    /// What a typed or pasted Custom schedule is sent as: whitespace runs collapse to one space, smart quotes and dashes
    /// become plain ones, full-width digits plain digits, trimmed.
    public static string CleanCustom(string text)
    {
        var out_ = new StringBuilder();
        var lastWasSpace = false;
        foreach (var rune in text.EnumerateRunes())
        {
            var v = rune.Value;
            int c = v switch
            {
                0x2018 or 0x2019 => '\'',
                0x201C or 0x201D => '"',
                0x2013 or 0x2014 or 0x2212 => '-',
                >= 0xFF10 and <= 0xFF19 => v - 0xFF10 + '0',
                _ => v,
            };
            if (System.Text.Rune.IsWhiteSpace(new System.Text.Rune(c)) || c == 0x00A0 || c == 0x202F)
            {
                if (!lastWasSpace && out_.Length > 0) out_.Append(' ');
                lastWasSpace = true;
            }
            else
            {
                out_.Append(new System.Text.Rune(c).ToString());
                lastWasSpace = false;
            }
        }
        return out_.ToString().Trim(' ', '\t');
    }

    /// The preview under the Custom field: a five-field cron the app can say plainly, else null.
    public static string? CustomPreview(string text)
    {
        var line = CleanCustom(text);
        return Parts(line) == null ? null : JobWords.DescribeCron(line);
    }
}
