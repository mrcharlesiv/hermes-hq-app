using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Hermes.Core.Jobs;

/// Wall clocks in a zone, as HermesKit's Calendar does them (a zone is "the phone's", or a gateway's fixed offset).
public static class JobClock
{
    public static DateTimeOffset Local(DateTimeOffset d, TimeZoneInfo zone) => TimeZoneInfo.ConvertTime(d, zone);

    public static TimeZoneInfo Fixed(int minutesEast) =>
        TimeZoneInfo.CreateCustomTimeZone($"UTC{minutesEast:+0;-0}", TimeSpan.FromMinutes(minutesEast), "fixed", "fixed");

    /// The instant a wall-clock time names in `zone` (a skipped hour moves on by the gap, a repeated one is its first
    /// pass, as Calendar.date(from:) does). Null for a date that doesn't exist.
    public static DateTimeOffset? FromWall(int y, int mo, int d, int h, int mi, int s, TimeZoneInfo zone)
    {
        if (y < 1 || y > 9998 || mo < 1 || mo > 12 || d < 1 || d > DateTime.DaysInMonth(y, mo)) return null;
        var wall = new DateTime(y, mo, d, h, mi, 0, DateTimeKind.Unspecified).AddSeconds(s);
        return FromWall(wall, zone);
    }

    public static DateTimeOffset FromWall(DateTime wall, TimeZoneInfo zone)
    {
        wall = DateTime.SpecifyKind(wall, DateTimeKind.Unspecified);
        if (zone.IsInvalidTime(wall))
        {
            var before = zone.GetUtcOffset(wall.AddHours(-3));
            return new DateTimeOffset(wall, before).ToOffset(zone.GetUtcOffset(wall.AddHours(3)));
        }
        if (zone.IsAmbiguousTime(wall)) return new DateTimeOffset(wall, zone.GetAmbiguousTimeOffsets(wall).Max());
        return new DateTimeOffset(wall, zone.GetUtcOffset(wall));
    }

    public static int OffsetMinutes(DateTimeOffset at, TimeZoneInfo zone) => (int)zone.GetUtcOffset(at).TotalMinutes;
}

/// `JS new Date(iso)` for the gateway's ISO times (HermesKit/Pages/JobWords.swift `PagesDate`).
public static partial class PagesDate
{
    [GeneratedRegex(@"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?)?\s*(Z|[+-]\d{2}:?\d{2})?$")]
    private static partial Regex Iso();

    /// With a zone ("-05:00", "Z", "+0530") that instant; without one, the wall clock in `zone` (date-only strings are
    /// UTC midnight, as JS reads them). Null when unreadable.
    public static DateTimeOffset? Parse(string? text, TimeZoneInfo? zone = null)
    {
        zone ??= TimeZoneInfo.Local;
        var t = text?.Trim();
        if (string.IsNullOrEmpty(t)) return null;
        var g = Iso().Match(t);
        if (!g.Success) return null;
        int y = int.Parse(g.Groups[1].Value), mo = int.Parse(g.Groups[2].Value), d = int.Parse(g.Groups[3].Value);
        int h = g.Groups[4].Success ? int.Parse(g.Groups[4].Value) : 0, mi = g.Groups[5].Success ? int.Parse(g.Groups[5].Value) : 0;
        int s = g.Groups[6].Success ? int.Parse(g.Groups[6].Value) : 0;
        if (mo < 1 || mo > 12 || d < 1 || d > 31 || h >= 24 || mi >= 60 || s >= 61) return null;
        var fraction = g.Groups[7].Success ? double.Parse("0." + g.Groups[7].Value, CultureInfo.InvariantCulture) : 0;
        TimeZoneInfo cal = g.Groups[8].Success ? JobClock.Fixed(OffsetMinutes(g.Groups[8].Value))
            : !g.Groups[4].Success ? TimeZoneInfo.Utc : zone;
        var at = JobClock.FromWall(y, mo, d, h, mi, s, cal);
        return at?.AddTicks((long)Math.Round(fraction * TimeSpan.TicksPerSecond));
    }

    /// "-05:00" → -300, "Z" → 0, "+0530" → 330.
    public static int OffsetMinutes(string zone)
    {
        if (zone == "Z") return 0;
        var digits = zone[1..].Replace(":", "");
        if (digits.Length != 4 || !int.TryParse(digits[..2], out var hh) || !int.TryParse(digits[2..], out var mm)) return 0;
        return (zone.StartsWith('-') ? -1 : 1) * (hh * 60 + mm);
    }
}

public enum JobSection { NeedsAttention, Running, Scheduled, Paused, Completed }

public enum RowLead { None, Running, Failed, Overdue, Paused }

public enum EdgeTone { Plain, Late, Running }

/// What a job row says at its trailing edge, where a bot row has its time.
public sealed record RowEdge(string Text, EdgeTone Tone, string Spoken);

/// The Jobs page's words (HermesKit/Pages/JobWords.swift, docs/spec/1x-pages.md §3.3). en-US words and clock, never the
/// PC's locale; every function takes `now` and a zone (the PC's) so tests pin America/Chicago.
public static partial class JobWords
{
    public static readonly string[] Days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
    public static readonly string[] ShortDays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    public static readonly string[] Months = ["January", "February", "March", "April", "May", "June", "July", "August",
        "September", "October", "November", "December"];
    public static readonly string[] ShortMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

    /// The scheduler's grace before a run is overdue.
    public static readonly TimeSpan OverdueGrace = TimeSpan.FromMinutes(15);

    private static TimeZoneInfo Z(TimeZoneInfo? zone) => zone ?? TimeZoneInfo.Local;
    internal static long Round(double x) => (long)Math.Round(x, MidpointRounding.AwayFromZero);

    // MARK: Formatting

    public static int? Int(string value) =>
        value.Length > 0 && value.All(c => c is >= '0' and <= '9') && int.TryParse(value, out var n) ? n : null;

    /// "8:15 AM".
    public static string Clock(int hour, int minute)
    {
        var h = ((hour % 24) + 24) % 24;
        var twelve = h % 12 == 0 ? 12 : h % 12;
        return $"{twelve}:{(minute < 10 ? "0" : "")}{minute} {(h < 12 ? "AM" : "PM")}";
    }

    public static string Clock(DateTimeOffset date, TimeZoneInfo? zone = null)
    {
        var l = JobClock.Local(date, Z(zone));
        return Clock(l.Hour, l.Minute);
    }

    public static int WeekdayIndex(DateTimeOffset date, TimeZoneInfo? zone = null) => (int)JobClock.Local(date, Z(zone)).DayOfWeek;

    /// "Wed, Sep 30" (+ ", 2025").
    public static string DayDate(DateTimeOffset date, TimeZoneInfo? zone = null, bool year = false)
    {
        var l = JobClock.Local(date, Z(zone));
        var b = $"{ShortDays[(int)l.DayOfWeek]}, {ShortMonths[l.Month - 1]} {l.Day}";
        return year ? b + $", {l.Year}" : b;
    }

    /// "Sep 30" (+ ", 2025").
    public static string MonthDay(DateTimeOffset date, TimeZoneInfo? zone = null, bool year = false)
    {
        var l = JobClock.Local(date, Z(zone));
        var b = $"{ShortMonths[l.Month - 1]} {l.Day}";
        return year ? b + $", {l.Year}" : b;
    }

    public static bool SameYear(DateTimeOffset a, DateTimeOffset b, TimeZoneInfo? zone = null) =>
        JobClock.Local(a, Z(zone)).Year == JobClock.Local(b, Z(zone)).Year;

    /// Calendar days from `now` to `date` (0 today, -1 yesterday, 1 tomorrow).
    public static int DaysFrom(DateTimeOffset date, DateTimeOffset now, TimeZoneInfo? zone = null) =>
        (JobClock.Local(date, Z(zone)).Date - JobClock.Local(now, Z(zone)).Date).Days;

    public static string List(IReadOnlyList<string> items) =>
        items.Count <= 1 ? string.Concat(items) : string.Join(", ", items.Take(items.Count - 1)) + " and " + items[^1];

    // MARK: Schedules

    private static string? DayField(string field)
    {
        if (field == "*") return "";
        if (field == "1-5") return "weekdays";
        if (Regex.IsMatch(field, "^(0,6|6,0|6,7|7,6|6-7)$")) return "weekends";
        var range = Regex.Match(field, @"^(\d)-(\d)$");
        if (range.Success) return $"{ShortDays[int.Parse(range.Groups[1].Value) % 7]}–{ShortDays[int.Parse(range.Groups[2].Value) % 7]}";
        var values = field.Split(',').Select(Int).ToList();
        if (values.Any(v => v == null || v > 7)) return null;
        return values.Count == 1 ? $"every {Days[values[0]!.Value % 7]}" : List([.. values.Select(v => ShortDays[v!.Value % 7])]);
    }

    private static string[] Fields(string expr) => expr.Trim().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);

    private static string Cap(string s) => s.Length == 0 ? s : char.ToUpperInvariant(s[0]) + s[1..];

    /// "15 8 * * 1-5" → "Weekdays at 8:15 AM". Null for expressions it cannot say plainly.
    public static string? DescribeCron(string expr)
    {
        var parts = Fields(expr);
        if (parts.Length != 5) return null;
        var (minute, hour, dayOfMonth, month, dayOfWeek) = (parts[0], parts[1], parts[2], parts[3], parts[4]);
        if (month != "*") return null;
        if (DayField(dayOfWeek) is not { } on) return null;
        int? dom = dayOfMonth == "*" ? null : Int(dayOfMonth);
        if (dayOfMonth != "*" && (dom == null || on.Length > 0)) return null;
        var when = dom != null ? $"monthly on day {dom}" : on.Length == 0 ? "every day" : on;
        var m = Int(minute);
        var everyMinutes = Regex.Match(minute, @"^\*/(\d+)$");
        var everyHours = Regex.Match(hour, @"^\*/(\d+)$");
        var hourRange = Regex.Match(hour, @"^(\d+)-(\d+)$");
        var hours = hour.Split(',').Select(Int).ToList();
        if (m != null && hours.All(h => h != null))
            return Cap(when) + " at " + List([.. hours.Select(h => Clock(h!.Value, m.Value))]);
        var window = hourRange.Success
            ? $", {Clock(int.Parse(hourRange.Groups[1].Value), 0)}–{Clock(int.Parse(hourRange.Groups[2].Value), 59)}" : "";
        if (hour != "*" && !hourRange.Success && !everyHours.Success) return null;
        var suffix = when == "every day" ? "" : $" ({when})";
        if (everyMinutes.Success) return $"Every {everyMinutes.Groups[1].Value} minutes{window}{suffix}";
        if (minute == "*") return $"Every minute{window}{suffix}";
        if (m == null) return null;
        var mm = m < 10 ? $"0{m}" : $"{m}";
        if (everyHours.Success) return $"Every {everyHours.Groups[1].Value} hours at :{mm}{suffix}";
        return (m == 0 ? "Every hour, on the hour" : $"Every hour at :{mm}") + window + suffix;
    }

    /// Any stored schedule ("every 30m", a cron line, a one-off time) in words, or null.
    public static string? DescribeSchedule(string schedule, DateTimeOffset? now = null, TimeZoneInfo? zone = null)
    {
        var z = Z(zone);
        var n = now ?? DateTimeOffset.Now;
        var text = schedule.Trim();
        var every = Regex.Match(text, @"^every (\d+)\s*([mhd])$", RegexOptions.IgnoreCase);
        if (every.Success && int.TryParse(every.Groups[1].Value, out var count))
        {
            var unit = every.Groups[2].Value.ToLowerInvariant();
            var minutes = count * (unit == "h" ? 60 : unit == "d" ? 1440 : 1);
            if (minutes % 1440 == 0) return minutes == 1440 ? "Every day" : $"Every {minutes / 1440} days";
            if (minutes % 60 == 0) return minutes == 60 ? "Every hour" : $"Every {minutes / 60} hours";
            return $"Every {minutes} minutes";
        }
        var once = Regex.Match(text, @"^(?:once in )?(\d+)\s*([mhd])$", RegexOptions.IgnoreCase);
        if (once.Success) return $"Once, {once.Groups[1].Value}{once.Groups[2].Value.ToLowerInvariant()} after it was set";
        if (Regex.IsMatch(text, @"^\d{4}-\d{2}-\d{2}T") && PagesDate.Parse(text, z) is { } date) return OnceOn(date, n, z);
        var at = Regex.Match(text, @"^once at (\d{4})-(\d{2})-(\d{2})[ T](\d{1,2}):(\d{2})$", RegexOptions.IgnoreCase);
        if (at.Success)
        {
            var v = Enumerable.Range(1, 5).Select(i => int.TryParse(at.Groups[i].Value, out var x) ? x : -1).ToArray();
            if (v[1] < 1 || v[1] > 12 || v[3] >= 24 || v[4] >= 60) return null;
            if (JobClock.FromWall(v[0], v[1], v[2], v[3], v[4], 0, z) is not { } d) return null;
            return OnceOn(d, n, z);
        }
        return DescribeCron(text);
    }

    /// "Once on Wed, Sep 30 at 9:00 AM" (the year only when it is not this one).
    public static string OnceOn(DateTimeOffset date, DateTimeOffset now, TimeZoneInfo? zone = null) =>
        $"Once on {DayDate(date, zone, !SameYear(date, now, zone))} at {Clock(date, zone)}";

    public static string ZoneLabel(string offset)
    {
        if (Regex.IsMatch(offset, "^(Z|[+-]00:?00)$")) return "UTC";
        var g = Regex.Match(offset, @"^([+-])(\d{2}):?(\d{2})$");
        if (!g.Success) return "";
        var hh = int.Parse(g.Groups[2].Value);
        return $"UTC{(g.Groups[1].Value == "-" ? "−" : "+")}{hh}{(g.Groups[3].Value == "00" ? "" : ":" + g.Groups[3].Value)}";
    }

    /// A cron line the scheduler runs in another time zone than the PC's, said in the PC's time where that is plain
    /// (daily, or one weekday), else with the zone named. Null when they agree.
    public static string? LocalCronSchedule(string expr, string? nextRunAt, TimeZoneInfo? zone = null)
    {
        var z = Z(zone);
        var parts = Fields(expr);
        if (parts.Length != 5 || parts[2] != "*" || parts[3] != "*") return null;
        var written = Regex.Match(nextRunAt ?? "", @"T(\d{2}):(\d{2})(?::\d{2}(?:\.\d+)?)?(Z|[+-]\d{2}:?\d{2})$");
        if (Int(parts[0]) is not { } minute || Int(parts[1]) is not { } hour || !written.Success
            || PagesDate.Parse(nextRunAt, z) is not { } next) return null;
        if (int.Parse(written.Groups[1].Value) != hour || int.Parse(written.Groups[2].Value) != minute) return null;
        var local = JobClock.Local(next, z);
        if (local.Hour == hour && local.Minute == minute) return null;
        var time = Clock(local.Hour, local.Minute);
        if (parts[4] == "*") return $"Every day at {time}";
        if (Int(parts[4]) != null) return $"Every {Days[WeekdayIndex(next, z)]} at {time}";
        if (DescribeCron(expr) is not { } said) return null;
        return $"{said} {ZoneLabel(written.Groups[3].Value)}".Trim();
    }

    /// A job's schedule in words, in the PC's time.
    public static string JobScheduleWords(string expr, string display, string runAt, string? nextRunAt, string known = "",
        DateTimeOffset? now = null, TimeZoneInfo? zone = null)
    {
        if (LocalCronSchedule(expr, nextRunAt, zone) is { } local) return local;
        if (runAt.Length > 0 && DescribeSchedule(runAt, now, zone) is { } once) return once;
        if (known.Length > 0) return known;
        return DescribeSchedule(expr, now, zone) ?? DescribeSchedule(display, now, zone) ?? display;
    }

    private static string? NonEmpty(string? s) => string.IsNullOrEmpty(s) ? null : s;

    public static string ScheduleExpr(CronJob job) => NonEmpty(job.Schedule?.Expr) ?? NonEmpty(job.ScheduleDisplay) ?? "";

    public static string ScheduleDisplay(CronJob job) =>
        NonEmpty(job.ScheduleDisplay) ?? NonEmpty(job.Schedule?.Display) ?? NonEmpty(job.Schedule?.Expr) ?? "—";

    public static string ScheduleWords(CronJob job, DateTimeOffset? now = null, TimeZoneInfo? zone = null) =>
        JobScheduleWords(ScheduleExpr(job), ScheduleDisplay(job), job.Schedule?.RunAt ?? "", job.NextRunAt, now: now, zone: zone);

    // MARK: Next run

    /// Minutes east of UTC written at the end of an ISO time; null when it names none.
    public static int? WrittenOffset(string? iso)
    {
        var g = Regex.Match(iso ?? "", @"(Z|([+-])(\d{2}):?(\d{2}))$");
        if (!g.Success) return null;
        if (g.Groups[1].Value == "Z") return 0;
        return (g.Groups[2].Value == "-" ? -1 : 1) * (int.Parse(g.Groups[3].Value) * 60 + int.Parse(g.Groups[4].Value));
    }

    private static HashSet<int>? CronField(string text, int lo, int hi)
    {
        var allowed = new HashSet<int>();
        foreach (var part in text.Split(','))
        {
            var m = Regex.Match(part, @"^(\*|(\d+)(?:-(\d+))?)(?:/(\d+))?$");
            if (!m.Success) return null;
            var step = m.Groups[4].Success && int.TryParse(m.Groups[4].Value, out var st) ? st : 1;
            var star = m.Groups[1].Value == "*";
            var from = star ? lo : int.TryParse(m.Groups[2].Value, out var f) ? f : -1;
            var to = star ? hi : m.Groups[3].Success ? (int.TryParse(m.Groups[3].Value, out var t) ? t : -1) : m.Groups[4].Success ? hi : from;
            if (step == 0 || from < lo || to > hi || from > to) return null;
            for (var v = from; v <= to; v += step) allowed.Add(v);
        }
        return allowed;
    }

    /// The first time after `after` a five-field cron line fires, on the wall clock `offset` minutes east of UTC (the
    /// gateway's zone), or `zone` when null. Null for a line it cannot read or that never fires in a year.
    public static DateTimeOffset? NextCronFire(string expr, DateTimeOffset after, int? offset = null, TimeZoneInfo? zone = null)
    {
        var parts = Fields(expr);
        if (parts.Length != 5) return null;
        if (CronField(parts[0], 0, 59) is not { } minute || CronField(parts[1], 0, 23) is not { } hour
            || CronField(parts[2], 1, 31) is not { } dom || CronField(parts[3], 1, 12) is not { } month
            || CronField(parts[4], 0, 7) is not { } dow) return null;
        bool Weekday(int day) => dow.Contains(day) || (day == 0 && dow.Contains(7));
        var either = parts[2] != "*" && parts[4] != "*";
        bool DayMatches(int d, int m, int wd) => month.Contains(m) && (either ? dom.Contains(d) || Weekday(wd) : dom.Contains(d) && Weekday(wd));
        var cal = offset is { } o ? JobClock.Fixed(o) : Z(zone);
        var hours = Enumerable.Range(0, 24).Where(hour.Contains).ToList();
        var minutes = Enumerable.Range(0, 60).Where(minute.Contains).ToList();
        var baseDay = JobClock.Local(after, cal).Date;
        for (var i = 0; i <= 366; i++)
        {
            var p = baseDay.AddDays(i);
            if (!DayMatches(p.Day, p.Month, (int)p.DayOfWeek)) continue;
            foreach (var h in hours)
                foreach (var mi in minutes)
                {
                    var at = JobClock.FromWall(p.AddHours(h).AddMinutes(mi), cal);
                    if (at > after) return at;
                }
        }
        return null;
    }

    /// Whether the gateway's next run is later than the schedule's own next time by more than an hour, on every offset
    /// a daylight-saving change could have left.
    public static bool SkippedRuns(string expr, DateTimeOffset now, DateTimeOffset next, int? offset, TimeZoneInfo? zone = null)
    {
        int?[] offsets = offset is { } o ? [o, o - 60, o + 60] : [null];
        return offsets.All(z => NextCronFire(expr, now, z, zone) is { } due && (next - due).TotalSeconds > 3600);
    }

    private static string JobDay(DateTimeOffset date, DateTimeOffset now, TimeZoneInfo z)
    {
        var d = DaysFrom(date, now, z);
        if (d == 0) return "Today";
        if (d == 1) return "Tomorrow";
        if (d > 1 && d < 7) return Days[WeekdayIndex(date, z)];
        return DayDate(date, z);
    }

    /// What a job row says after its schedule: "", "Due now", "Overdue", "Next in 12 min", "Next tomorrow",
    /// "Next Sun 6:00 PM", "Skipped until Mon, Oct 5".
    public static string JobNextWords(string state, CronSchedule? schedule, string? nextRunAt, string scheduleWords,
        DateTimeOffset? now = null, TimeZoneInfo? zone = null)
    {
        var z = Z(zone);
        var n = now ?? DateTimeOffset.Now;
        if (state is "paused" or "completed" or "disabled" || schedule?.Kind == "once" || Regex.IsMatch(scheduleWords, @"^Once\b")) return "";
        if (PagesDate.Parse(nextRunAt, z) is not { } next) return "";
        var late = n - next;
        if (late > OverdueGrace) return "Overdue";
        if (late >= TimeSpan.Zero) return "Due now";
        var times = Regex.Matches(scheduleWords, @"\b\d{1,2}:\d{2}\s?[AP]M\b").Select(m => m.Value).ToList();
        var day = JobDay(next, n, z);
        var time = Clock(next, z);
        string when;
        if (times.Count == 1 && times[0] == time) when = day;
        else if (day == "Today") when = time;
        else
        {
            var lead = DaysFrom(next, n, z) >= 7 ? day + "," : day == "Tomorrow" ? day : ShortDays[WeekdayIndex(next, z)];
            when = $"{lead} {time}";
        }
        var kind = schedule?.Kind;
        var expr = kind == "cron" || (kind == null && !string.IsNullOrEmpty(schedule?.Expr)) ? schedule?.Expr : null;
        if (!string.IsNullOrEmpty(expr) && SkippedRuns(expr, n, next, WrittenOffset(nextRunAt), z)) return $"Skipped until {when}";
        var ahead = (next - n).TotalSeconds;
        if (ahead < 3600) return $"Next in {Math.Max(1, Round(ahead / 60))} min";
        return "Next " + (when.StartsWith("Today") || when.StartsWith("Tomorrow") ? char.ToLowerInvariant(when[0]) + when[1..] : when);
    }

    // MARK: Relative times

    /// "Today at 9:05 AM", "Yesterday at…", "Tomorrow at…", "Wed at 6:01 AM" within a week either side, else
    /// "Sep 12 at 4:07 PM" ("Dec 31, 2025 at 11:00 PM" in another year). "" for no time.
    public static string RelativeDateTime(DateTimeOffset? date, DateTimeOffset? now = null, TimeZoneInfo? zone = null)
    {
        if (date is not { } d) return "";
        var z = Z(zone);
        var n = now ?? DateTimeOffset.Now;
        var time = Clock(d, z);
        var days = DaysFrom(d, n, z);
        if (days == 0) return $"Today at {time}";
        if (days == -1) return $"Yesterday at {time}";
        if (days == 1) return $"Tomorrow at {time}";
        if (Math.Abs(days) < 7) return $"{ShortDays[WeekdayIndex(d, z)]} at {time}";
        return $"{MonthDay(d, z, !SameYear(d, n, z))} at {time}";
    }

    public static string RelativeDateTime(string? iso, DateTimeOffset? now = null, TimeZoneInfo? zone = null) =>
        RelativeDateTime(PagesDate.Parse(iso, Z(zone)), now, zone);

    // MARK: Runs

    [GeneratedRegex(@"^\s*\[(?:IMPORTANT|SYSTEM|NOTE|CONTEXT|SCHEDULED|CRON)\b[^\]]*(?:\]|$)\s*", RegexOptions.IgnoreCase)]
    private static partial Regex Injected();

    public static string RunPreview(string? text)
    {
        var value = (text ?? "").Trim();
        var previous = "";
        while (previous != value)
        {
            previous = value;
            value = Injected().Replace(value, "", 1).Trim();
        }
        return value;
    }

    [GeneratedRegex(@" · (?:[A-Z][a-z]{2,8},? )?[A-Z][a-z]{2} \d{1,2}(?:, \d{4})?,? \d{1,2}:\d{2}(?:\s?[AP]M)?$")]
    private static partial Regex AutoRunTitle();

    /// A run's title ("Fri, Oct 3, 1:00 PM") and detail ("4 messages · Weekly review sent", "Running", "Completed",
    /// "Failed · <reason>").
    public static (string Title, string Detail) CronRunLabel(CronRun run, TimeZoneInfo? zone = null)
    {
        var z = Z(zone);
        var seconds = run.StartedAt ?? run.LastActive;
        string title;
        if (seconds is { } s)
        {
            var date = DateTimeOffset.FromUnixTimeMilliseconds((long)(s * 1000));
            title = $"{DayDate(date, z)}, {Clock(date, z)}";
        }
        else title = "Scheduled run";
        if (run.Source == "cron_output")
        {
            var raw = run.Title ?? "";
            string status;
            var rest = "";
            var m = Regex.Match(raw, @"^([A-Z][A-Z ]+) · ([\s\S]*)$");
            if (m.Success) { status = m.Groups[1].Value; rest = m.Groups[2].Value; }
            else status = Regex.IsMatch(raw, @"^# [^\n]*\(FAILED\)") ? "FAILED" : "COMPLETED";
            var reason = status == "FAILED" && rest.Length > 0 && !rest.StartsWith('#')
                ? new Regex(@"^[A-Za-z_][\w.]*(?:Error|Exception):\s*").Replace(rest, "", 1) : "";
            if (status.Length > 0) status = status[..1] + status[1..].ToLowerInvariant();
            return (title, string.Join(" · ", new[] { status, reason }.Where(x => x.Length > 0)));
        }
        var said = new[] { run.Title, run.Preview }.Select(RunPreview).FirstOrDefault(x => x.Length > 0 && !AutoRunTitle().IsMatch(x)) ?? "";
        var count = run.MessageCount ?? 0;
        var st = run.IsActive ? "Running" : count > 0 ? $"{count} {(count == 1 ? "message" : "messages")}" : "";
        return (title, string.Join(" · ", new[] { st, said }.Where(x => x.Length > 0)));
    }

    // MARK: Delivery

    public static readonly Dictionary<string, string> PlatformNames = new()
    {
        ["telegram"] = "Telegram", ["discord"] = "Discord", ["slack"] = "Slack", ["email"] = "Email", ["whatsapp"] = "WhatsApp",
        ["signal"] = "Signal", ["matrix"] = "Matrix", ["sms"] = "SMS", ["homeassistant"] = "Home Assistant", ["mattermost"] = "Mattermost",
        ["imessage"] = "iMessage", ["webhook"] = "Webhook", ["groupme"] = "GroupMe", ["bluebubbles"] = "BlueBubbles",
        ["dingtalk"] = "DingTalk", ["wecom"] = "WeCom", ["wechat"] = "WeChat", ["qq"] = "QQ", ["line"] = "LINE",
    };

    /// "my_bridge" → "My Bridge"; "Url" → "URL", "Id" → "ID".
    public static string TitleCase(string key)
    {
        var spaced = Regex.Replace(key, "[_-]+", " ");
        var out_ = new StringBuilder();
        var previousIsWord = false;
        foreach (var ch in spaced)
        {
            var isWord = char.IsLetterOrDigit(ch) || ch == '_';
            out_.Append(!previousIsWord && isWord ? char.ToUpperInvariant(ch) : ch);
            previousIsWord = isWord;
        }
        return Regex.Replace(Regex.Replace(out_.ToString(), @"\bUrl\b", "URL"), @"\bId\b", "ID");
    }

    public static string PlatformName(string id, IReadOnlyDictionary<string, string>? labels = null) =>
        labels != null && labels.TryGetValue(id, out var l) ? l : PlatformNames.TryGetValue(id, out var n) ? n : TitleCase(id);

    public static string Known(string? value)
    {
        var text = (value ?? "").Trim();
        return text == "None" ? "" : text;
    }

    private static string UnnamedChat(string chat, bool full)
    {
        if (!Regex.IsMatch(chat, @"^-?\d+$")) return chat;
        var kind = Regex.IsMatch(chat, @"^-100\d+$") ? "group" : "chat";
        var shown = full || chat.Length <= 4 ? new Regex(@"^-100(?=\d)").Replace(chat, "", 1) : "…" + chat[^4..];
        return $"{kind} {shown}";
    }

    public static string HumanDeliverTarget(string target, CronOrigin? origin = null, IReadOnlyDictionary<string, string>? labels = null,
        bool full = false, IReadOnlyDictionary<string, string>? names = null)
    {
        var value = target.Trim();
        if (value.Length == 0) return "";
        if (value == "origin")
        {
            var platform = Known(origin?.Platform);
            var chatName = Known(origin?.ChatName);
            return string.Join(" · ", new[] { "Where it was created", platform.Length == 0 ? "" : PlatformName(platform, labels), chatName }
                .Where(x => x.Length > 0));
        }
        if (value == "local") return labels != null && labels.TryGetValue("local", out var l) ? l : "Keep in Hermes (no message)";
        var pieces = value.Split(':');
        string p = pieces[0], chat = pieces.Length > 1 ? pieces[1] : "", thread = pieces.Length > 2 ? pieces[2] : "";
        if (chat.Length == 0) return PlatformName(p, labels);
        var sameChat = Known(origin?.Platform) == p && Known(origin?.ChatId) == chat;
        var named = names != null && names.TryGetValue($"{p}:{chat}", out var nm) ? nm : "";
        var name = sameChat && Known(origin?.ChatName).Length > 0 ? Known(origin?.ChatName)
            : named.Length > 0 ? named : UnnamedChat(chat, full);
        return $"{PlatformName(p, labels)} · {name}{(thread.Length == 0 ? "" : $" (topic {thread})")}";
    }

    public static string HumanDeliver(string deliver, CronOrigin? origin = null, IReadOnlyDictionary<string, string>? labels = null,
        IReadOnlyDictionary<string, string>? names = null)
    {
        var targets = deliver.Split(',').Where(t => t.Trim().Length > 0).ToList();
        // `local` beside another place says nothing more: every result is kept in Run History anyway.
        if (targets.Any(t => t.Trim() != "local")) targets.RemoveAll(t => t.Trim() == "local");
        var shortSaid = targets.Select(t => HumanDeliverTarget(t, origin, labels, false, names)).ToList();
        var said = shortSaid.Select((label, i) => shortSaid.IndexOf(label) != shortSaid.LastIndexOf(label)
            ? HumanDeliverTarget(targets[i], origin, labels, true, names) : label);
        var joined = string.Join(" + ", said);
        return joined.Length == 0 ? HumanDeliverTarget("local", origin, labels) : joined;
    }

    /// Chat names the jobs' origins know, by "platform:chat id".
    public static Dictionary<string, string> KnownChatNames(IEnumerable<CronJob> jobs)
    {
        var names = new Dictionary<string, string>();
        foreach (var job in jobs)
        {
            string platform = Known(job.Origin?.Platform), chat = Known(job.Origin?.ChatId), name = Known(job.Origin?.ChatName);
            if (platform.Length > 0 && chat.Length > 0 && name.Length > 0) names.TryAdd($"{platform}:{chat}", name);
        }
        return names;
    }

    /// "Bot Chat (maple-revenue-operator)" → "Bot Chat (Maple Revenue Operator)".
    public static string ReadableTargetName(string name, IReadOnlyDictionary<string, string>? profiles = null) =>
        new Regex(@"\(([a-z0-9][a-z0-9_-]*)\)$", RegexOptions.IgnoreCase).Replace(name, g =>
        {
            var id = g.Groups[1].Value;
            if (id == "default") return "(Hermes)";
            var shown = profiles != null && profiles.TryGetValue(id, out var p) ? p
                : Regex.IsMatch(id, "[-_]") || Regex.IsMatch(id, "^[a-z]") ? TitleCase(id) : id;
            return $"({shown})";
        }, 1);

    /// The question Run Now asks. `Title` is "Run “name” now?"; alerts use `RunAlertTitle`.
    public static (string Title, string Description) RunNowCopy(string name, string deliver, CronOrigin? origin = null,
        IReadOnlyDictionary<string, string>? labels = null, IReadOnlyDictionary<string, string>? names = null)
    {
        var targets = deliver.Split(',').Select(t => t.Trim()).Where(t => t.Length > 0 && t != "local").ToList();
        var places = targets.Select(target =>
        {
            if (target == "origin")
            {
                string platform = Known(origin?.Platform), chat = Known(origin?.ChatName);
                if (chat.Length > 0 && platform.Length > 0) return $"{chat} on {PlatformName(platform, labels)}";
                return platform.Length == 0 ? "the chat it came from" : $"the {PlatformName(platform, labels)} chat it came from";
            }
            var said = HumanDeliverTarget(target, origin, labels, false, names).Split(" · ");
            return said.Length > 1 ? $"{said[1]} on {said[0]}" : said[0];
        }).ToList();
        var all = places.Count > 1 ? string.Join(", ", places.Take(places.Count - 1)) + " and " + places[^1] : places.FirstOrDefault() ?? "";
        var lead = all.Length == 0 ? "Its result is kept in its Run History." : $"It delivers to {all}.";
        return ($"Run “{name}” now?", $"{lead} Its schedule does not change.");
    }

    /// "Run “Weekly review” now?" → "Run “Weekly review” Now?" (alert titles are Title Case).
    public static string RunAlertTitle(string title) => new Regex(@" now\?$").Replace(title, " Now?", 1);

    // MARK: Titles

    [GeneratedRegex(@"^[a-z0-9]+(?:[-_][a-z0-9]+)+$")]
    private static partial Regex SlugName();

    private static readonly HashSet<string> Acronyms = ["ai", "api", "ap", "ci", "cpu", "crm", "csv", "dm", "dns", "gpu", "http", "id",
        "ios", "json", "kpi", "llm", "mcp", "os", "pdf", "pr", "qa", "rss", "seo", "sms", "sql", "ssh", "tts", "ui", "url", "ux"];
    private static readonly Dictionary<string, string> IosWords = new() { ["ios"] = "iOS", ["macos"] = "macOS", ["iphone"] = "iPhone", ["ipad"] = "iPad" };

    /// How other names spell a word ("GBrain", "NHB"), from titles that are already words.
    public static Dictionary<string, string> KnownWordCasing(IEnumerable<string> titles)
    {
        var casing = new Dictionary<string, string>();
        foreach (var title in titles)
        {
            if (SlugName().IsMatch(title)) continue;
            foreach (Match m in Regex.Matches(title, "[A-Za-z][A-Za-z0-9]*"))
            {
                var w = m.Value;
                if (w[1..].Any(char.IsUpper) || (w.Length > 1 && w == w.ToUpperInvariant())) casing[w.ToLowerInvariant()] = w;
            }
        }
        return casing;
    }

    /// A slug-like job name as words; any other name unchanged.
    public static string HumanJobTitle(string name, IReadOnlyDictionary<string, string>? casing = null)
    {
        var text = name.Trim();
        if (!SlugName().IsMatch(text)) return name;
        return string.Join(" ", text.Split('-', '_').Select((word, index) =>
        {
            if (IosWords.TryGetValue(word, out var k) || (casing != null && casing.TryGetValue(word, out k))) return k;
            if (Acronyms.Contains(word)) return word.ToUpperInvariant();
            return index == 0 ? char.ToUpperInvariant(word[0]) + word[1..] : word;
        }));
    }

    /// Effective state: explicit state wins; else from `enabled`. A scheduled job whose work is out is running.
    public static string JobState(CronJob job)
    {
        var stored = (job.State ?? "").Trim();
        var state = stored.Length > 0 ? stored : job.Enabled == false ? "disabled" : "scheduled";
        if (state is "scheduled" or "enabled" && WorkIsOut(job)) return "running";
        return state;
    }

    public static bool WorkIsOut(CronJob job) => RunIsOut(job) || job.BotWorking != null;

    /// The job's latest run attempt is claimed or running, and the job has not been marked run since it was claimed.
    public static bool RunIsOut(CronJob job)
    {
        var status = (job.LatestRunStatus ?? "").Trim().ToLowerInvariant();
        if (status is not ("claimed" or "running")) return false;
        if (PagesDate.Parse(job.LastRunAt) is not { } last || PagesDate.Parse(job.LatestRunClaimedAt) is not { } claimed) return true;
        return last < claimed;
    }

    public static bool IsRunning(CronJob job) => JobState(job) == "running" || WorkIsOut(job);

    /// name → first 60 of prompt → first 60 of script → id.
    public static string JobTitle(CronJob job)
    {
        static string Clip(string v) => v.Length > 60 ? v[..60] + "…" : v;
        string name = (job.Name ?? "").Trim(), prompt = (job.Prompt ?? "").Trim(), script = (job.Script ?? "").Trim();
        if (name.Length > 0) return name;
        if (prompt.Length > 0) return Clip(prompt);
        if (script.Length > 0) return Clip(script);
        return job.Id.Length == 0 ? "Cron job" : job.Id;
    }

    /// How long the stored next run sits past the grace, or null.
    public static TimeSpan? NextRunOverdue(CronJob job, DateTimeOffset? now = null)
    {
        if (JobState(job) is "paused" or "completed" or "disabled" || PagesDate.Parse(job.NextRunAt) is not { } next) return null;
        var overdue = (now ?? DateTimeOffset.Now) - next;
        return overdue > OverdueGrace ? overdue : null;
    }

    public static bool JobIsScriptOnly(CronJob job) => job.NoAgent && (job.Script ?? "").Trim().Length > 0;

    public static string JobDescription(CronJob job) => !string.IsNullOrEmpty(job.Prompt) ? job.Prompt : job.Script ?? "";

    [GeneratedRegex(@"^(?:[A-Za-z_][\w.]*(?:Error|Exception)|Exception):\s*")]
    private static partial Regex ErrorPrefix();
    [GeneratedRegex(@"^\[[a-z_]+(?::[a-z_]+)?\]\s*")]
    private static partial Regex ErrorMarker();
    [GeneratedRegex("^(?:⚠️?|\U0001F6D1|❌|\U0001F6AB)\\s*")]
    private static partial Regex ErrorEmoji();

    /// The first plain sentence of a scheduler error ("RuntimeError: …" → "…").
    public static string LastErrorSummary(string? lastError)
    {
        var text = (lastError ?? "").Trim();
        var previous = "";
        while (previous != text)
        {
            previous = text;
            text = ErrorPrefix().Replace(ErrorEmoji().Replace(ErrorMarker().Replace(text, "", 1), "", 1), "", 1).TrimStart();
        }
        if (Regex.IsMatch(text, "has no model configured", RegexOptions.IgnoreCase)) return "No model is set for this job. Choose one in Edit Job.";
        var end = Regex.Match(text, @"\. |\n");
        var sentence = (end.Success ? text[..(end.Index + 1)] : text).Trim();
        return sentence.Length > 200 ? sentence[..199].Trim(' ', '\t') + "…" : sentence;
    }

    /// A scheduled job whose last run failed.
    public static bool LastRunFailed(CronJob job)
    {
        var s = (job.State ?? "").Trim();
        var state = s.Length == 0 ? "scheduled" : s;
        if (state is not ("scheduled" or "enabled")) return false;
        return Regex.IsMatch(job.LastStatus ?? "", "^(error|failed|fail)$", RegexOptions.IgnoreCase) || !string.IsNullOrEmpty(job.LastError);
    }

    /// "Last ran today at 9:05 AM · OK".
    public static string? LastRunNote(CronJob job, DateTimeOffset? now = null, TimeZoneInfo? zone = null)
    {
        if (PagesDate.Parse(job.LastRunAt, Z(zone)) is not { } at) return null;
        var status = (job.LastStatus ?? "").ToLowerInvariant();
        var failed = !string.IsNullOrEmpty(job.LastError) || Regex.IsMatch(status, "^(error|failed|fail)$");
        var when = RelativeDateTime(at, now, zone);
        if (when.StartsWith("Today") || when.StartsWith("Yesterday")) when = char.ToLowerInvariant(when[0]) + when[1..];
        return $"Last ran {when} · {(failed ? "Failed" : "OK")}";
    }

    // MARK: Sections

    public static string SectionTitle(JobSection s) => s switch
    {
        JobSection.NeedsAttention => "Needs Attention",
        JobSection.Running => "Running",
        JobSection.Scheduled => "Scheduled",
        JobSection.Paused => "Paused",
        _ => "Completed",
    };

    /// Explicit inactive states win over stale next dates and errors from older runs.
    public static JobSection JobSectionFor(string state, TimeSpan? overdue, bool failed)
    {
        if (state == "completed") return JobSection.Completed;
        if (state is "paused" or "disabled") return JobSection.Paused;
        if (state == "running") return JobSection.Running;
        if (state == "error" || failed || overdue != null) return JobSection.NeedsAttention;
        return JobSection.Scheduled;
    }

    public static JobSection Section(CronJob job, DateTimeOffset? now = null) =>
        JobSectionFor(JobState(job), NextRunOverdue(job, now), LastRunFailed(job));

    /// The row's subtitle with the next-run words (the iPhone's; the Mac row draws `RowSchedule` with an edge).
    public static string RowSubtitle(CronJob job, DateTimeOffset? now = null, TimeZoneInfo? zone = null, bool running = false)
    {
        var schedule = ScheduleWords(job, now, zone);
        if (running || JobState(job) == "running") return schedule;
        var next = JobNextWords(JobState(job), job.Schedule, job.NextRunAt, schedule, now, zone);
        if (next == "Overdue" && !LastRunFailed(job)) return schedule;
        return next.Length == 0 ? schedule : $"{schedule} · {next}";
    }

    /// "4m", "2h", "3d": a short span for the row's edge.
    public static string ShortSpan(double seconds)
    {
        var minutes = Math.Max(1, Round(seconds / 60));
        if (minutes < 60) return $"{minutes}m";
        var hours = Round(seconds / 3600);
        return hours < 48 ? $"{hours}h" : $"{Round(seconds / 86400)}d";
    }

    private static string SpokenSpan(double seconds)
    {
        var minutes = Math.Max(1, Round(seconds / 60));
        if (minutes < 60) return minutes == 1 ? "1 minute" : $"{minutes} minutes";
        var hours = Round(seconds / 3600);
        if (hours < 48) return hours == 1 ? "1 hour" : $"{hours} hours";
        return $"{Round(seconds / 86400)} days";
    }

    private static string EdgeDay(DateTimeOffset date, DateTimeOffset now, TimeZoneInfo z)
    {
        var d = DaysFrom(date, now, z);
        if (d == 0) return "Today";
        if (d == 1) return "Tomorrow";
        if (d == -1) return "Yesterday";
        if (Math.Abs(d) < 7) return ShortDays[WeekdayIndex(date, z)];
        return MonthDay(date, z, !SameYear(date, now, z));
    }

    /// The row's trailing edge: when it runs next ("in 12 min", "6:00 PM", "Tomorrow", "Mon", "Nov 16"), "Now" while it
    /// is due, how late an overdue one is ("2h late"), how long a running one has been out ("4m so far"), or the day a
    /// completed one last ran.
    public static RowEdge? Edge(CronJob job, DateTimeOffset? now = null, TimeZoneInfo? zone = null, bool running = false)
    {
        var z = Z(zone);
        var n = now ?? DateTimeOffset.Now;
        var state = JobState(job);
        if (running || state == "running")
        {
            if (PagesDate.Parse(job.LatestRunClaimedAt, z) is not { } claimed) return null;
            var outFor = (n - claimed).TotalSeconds;
            if (outFor < 0 || outFor >= 86400) return null;
            return new RowEdge($"{ShortSpan(outFor)} so far", EdgeTone.Running, $"running for {SpokenSpan(outFor)}");
        }
        if (state == "completed")
        {
            if (PagesDate.Parse(job.LastRunAt, z) is not { } last) return null;
            var day = EdgeDay(last, n, z);
            return new RowEdge(day, EdgeTone.Plain, $"last ran {day}");
        }
        if (state is "paused" or "disabled" || PagesDate.Parse(job.NextRunAt, z) is not { } next) return null;
        var late = n - next;
        if (late > OverdueGrace) return new RowEdge($"{ShortSpan(late.TotalSeconds)} late", EdgeTone.Late, $"{SpokenSpan(late.TotalSeconds)} late");
        if (late >= TimeSpan.Zero) return new RowEdge("Now", EdgeTone.Plain, "due now");
        if (SkipsRuns(job, next, n, z)) return null;
        var ahead = -late.TotalSeconds;
        if (ahead < 3600)
        {
            var minutes = Math.Max(1, Round(ahead / 60));
            return new RowEdge($"in {minutes} min", EdgeTone.Plain, $"next in {minutes} min");
        }
        var dayWord = EdgeDay(next, n, z);
        var text = dayWord == "Today" ? Clock(next, z) : dayWord;
        return new RowEdge(text, EdgeTone.Plain, $"next {(dayWord == "Today" ? "today at " + text : text)}");
    }

    private static bool SkipsRuns(CronJob job, DateTimeOffset next, DateTimeOffset now, TimeZoneInfo z)
    {
        var kind = job.Schedule?.Kind;
        if (!(kind == "cron" || (kind == null && !string.IsNullOrEmpty(job.Schedule?.Expr))) || string.IsNullOrEmpty(job.Schedule?.Expr)) return false;
        return SkippedRuns(job.Schedule.Expr, now, next, WrittenOffset(job.NextRunAt), z);
    }

    /// The row's second line with the edge drawn: the schedule alone; only "Skipped until …" still follows it.
    public static string RowSchedule(CronJob job, DateTimeOffset? now = null, TimeZoneInfo? zone = null, bool running = false)
    {
        var schedule = ScheduleWords(job, now, zone);
        if (running || JobState(job) == "running") return schedule;
        var next = JobNextWords(JobState(job), job.Schedule, job.NextRunAt, schedule, now, zone);
        return next.StartsWith("Skipped") ? $"{schedule} · {next}" : schedule;
    }

    public static string LeadWords(RowLead lead) => lead switch
    {
        RowLead.Running => "Running · ",
        RowLead.Failed => "Last run failed · ",
        RowLead.Overdue => "Overdue · ",
        RowLead.Paused => "Paused · ",
        _ => "",
    };

    public static RowLead Lead(bool running, bool failed, bool overdue, bool paused) =>
        running ? RowLead.Running : failed ? RowLead.Failed : overdue ? RowLead.Overdue : paused ? RowLead.Paused : RowLead.None;

    /// Under the editor's Model row: what a pick changes and what Default (global model) means.
    public static string ModelScope(string? bot)
    {
        var b = bot?.Trim();
        return string.IsNullOrEmpty(b) ? "Applies to this job only. Default uses the bot’s own model."
            : $"Applies to this job only. Default uses {b}’s own model.";
    }

    /// The detail's status line: "Scheduled", "Running", "Paused", "Completed", "Off", "Overdue" or "Last run failed".
    public static string StatusWord(CronJob job, DateTimeOffset? now = null)
    {
        if (IsRunning(job)) return "Running";
        if (LastRunFailed(job)) return "Last run failed";
        if (JobState(job) != "error" && NextRunOverdue(job, now) != null) return "Overdue";
        return JobState(job) switch
        {
            "paused" => "Paused",
            "completed" => "Completed",
            "disabled" => "Off",
            "error" => "Last run failed",
            _ => "Scheduled",
        };
    }

    /// Paused for the actions: the state, or `enabled == false`.
    public static bool IsPaused(CronJob job)
    {
        var state = JobState(job);
        return state is "paused" or "disabled" || job.Enabled == false;
    }

    /// The job page's run document reordered so "## Response" / "## Error" / "## Script Error" come first.
    public static string RunDocumentFirst(string text)
    {
        var cuts = Regex.Matches(text, "^(?=## )", RegexOptions.Multiline).Select(m => m.Index).Where(i => i > 0).ToList();
        var pieces = new List<string>();
        var from = 0;
        foreach (var cut in cuts) { pieces.Add(text[from..cut]); from = cut; }
        pieces.Add(text[from..]);
        var head = pieces[0];
        var sections = pieces.Skip(1).ToList();
        var first = Enumerable.Range(0, sections.Count)
            .Where(i => Regex.IsMatch(sections[i].Split('\n')[0], @"^## (?:Response|Error|Script Error)[ \t]*$")).ToList();
        if (first.Count == 0 || (first.Count == 1 && first[0] == 0)) return text;
        static string Ended(string s) => new Regex(@"\n*$").Replace(s, "\n\n", 1);
        var ordered = first.Select(i => sections[i]).Concat(Enumerable.Range(0, sections.Count).Where(i => !first.Contains(i)).Select(i => sections[i]));
        return new Regex(@"\n+$").Replace(head + string.Concat(ordered.Select(Ended)), "\n", 1);
    }
}
