using System.Globalization;

namespace Hermes.Core.Tasks;

// Natural-language quick-add parser (`HermesKit/Pages/Tasks/TodoQuickParse.swift`, commit 84263f4e4 / 36659bce1).
// Reads dates, times, repeats, #tags, and priority (!high / !1 / p1–p4) out of a typed line while keeping the rest as
// the title. Avoids false positives on cooking fractions (1/2, 3/4), ALL-CAPS short weekdays (SAT, MON), bare "sun",
// single-letter "a"/"p" without minutes ("2a"), and non-trailing bare recurrences ("Send weekly report").

/// Result of parsing a typed task or goal line.
public sealed record TodoQuickRead
{
    /// The task or goal title with recognized tokens stripped (or the full literal line if nothing would remain).
    public string Title { get; init; } = "";
    /// The parsed due date (midnight in the caller's zone when `HasTime` is false, exact moment when `HasTime` is true).
    public DateTimeOffset? Due { get; init; }
    public bool HasTime { get; init; }
    public string? RepeatRule { get; init; }
    public IReadOnlyList<string> Tags { get; init; } = [];
    /// 1 = High, 2 = Medium, 3 = Low, 0 = None (`p4`/`!none`), null = not specified.
    public int? Priority { get; init; }
    /// The date/repeat words as typed ("friday 9am"), for live preview chips.
    public string? DateWords { get; init; }

    public bool HasParsedDetails => Due != null || RepeatRule != null || Tags.Count > 0 || Priority != null;
}

public static class TodoQuickParse
{
    private static readonly Dictionary<string, DayOfWeek> Weekdays = new(StringComparer.Ordinal)
    {
        ["sunday"] = DayOfWeek.Sunday,
        ["monday"] = DayOfWeek.Monday,
        ["mon"] = DayOfWeek.Monday,
        ["tuesday"] = DayOfWeek.Tuesday,
        ["tue"] = DayOfWeek.Tuesday,
        ["tues"] = DayOfWeek.Tuesday,
        ["wednesday"] = DayOfWeek.Wednesday,
        ["wed"] = DayOfWeek.Wednesday,
        ["weds"] = DayOfWeek.Wednesday,
        ["thursday"] = DayOfWeek.Thursday,
        ["thu"] = DayOfWeek.Thursday,
        ["thur"] = DayOfWeek.Thursday,
        ["thurs"] = DayOfWeek.Thursday,
        ["friday"] = DayOfWeek.Friday,
        ["fri"] = DayOfWeek.Friday,
        ["saturday"] = DayOfWeek.Saturday,
        ["sat"] = DayOfWeek.Saturday,
    };

    private static readonly Dictionary<string, int> Months = new(StringComparer.Ordinal)
    {
        ["january"] = 1, ["jan"] = 1,
        ["february"] = 2, ["feb"] = 2,
        ["march"] = 3, ["mar"] = 3,
        ["april"] = 4, ["apr"] = 4,
        ["may"] = 5,
        ["june"] = 6, ["jun"] = 6,
        ["july"] = 7, ["jul"] = 7,
        ["august"] = 8, ["aug"] = 8,
        ["september"] = 9, ["sep"] = 9, ["sept"] = 9,
        ["october"] = 10, ["oct"] = 10,
        ["november"] = 11, ["nov"] = 11,
        ["december"] = 12, ["dec"] = 12,
    };

    private static readonly Dictionary<string, int> Counts = new(StringComparer.Ordinal)
    {
        ["a"] = 1, ["an"] = 1, ["one"] = 1, ["two"] = 2, ["three"] = 3, ["four"] = 4, ["five"] = 5, ["six"] = 6,
    };

    private static readonly Dictionary<string, int> Priorities = new(StringComparer.Ordinal)
    {
        ["!high"] = 1, ["!1"] = 1, ["p1"] = 1,
        ["!medium"] = 2, ["!med"] = 2, ["!2"] = 2, ["p2"] = 2,
        ["!low"] = 3, ["!3"] = 3, ["p3"] = 3,
        ["!none"] = 0, ["!4"] = 0, ["p4"] = 0,
    };

    private static readonly Dictionary<string, string> EveryRules = new(StringComparer.Ordinal)
    {
        ["day"] = "daily", ["weekday"] = "weekdays", ["week"] = "weekly", ["month"] = "monthly", ["year"] = "yearly",
    };

    private static readonly Dictionary<string, string> BareRules = new(StringComparer.Ordinal)
    {
        ["daily"] = "daily", ["weekdays"] = "weekdays", ["weekly"] = "weekly",
        ["monthly"] = "monthly", ["yearly"] = "yearly", ["annually"] = "yearly",
    };

    private static readonly HashSet<string> MetaTriggers = new(StringComparer.Ordinal)
    {
        "today", "tonight", "tomorrow", "tmrw", "next", "in", "on", "this", "at", "noon",
    };

    private static readonly char[] Punctuation = [',', '.', ';'];
    private static readonly string[] OrdinalSuffixes = ["st", "nd", "rd", "th"];
    private static readonly string[] TimeSuffixes = ["am", "pm", "a", "p"];

    /// Parses natural-language dates, times, repeats, #tags and priorities from `text`.
    /// When `keepLiteral` is true, returns `text` trimmed without stripping any tokens.
    /// When `dates` is false, date/time/repeat words stay literal (e.g. after a manual date pick).
    /// When `goal` is true, parses only a day (including a leading "by"/"before"/"until") with no time, repeat, tags or priority.
    public static TodoQuickRead Read(
        string text,
        DateTimeOffset now,
        TimeZoneInfo? zone = null,
        bool dates = true,
        bool goal = false,
        bool metadata = true,
        bool repeats = true,
        bool priorities = true,
        bool keepLiteral = false)
    {
        var raw = SplitTokens(text);
        if (raw.Count == 0) return new TodoQuickRead();
        if (keepLiteral) return new TodoQuickRead { Title = string.Join(" ", raw) };

        var tz = zone ?? TimeZoneInfo.Local;
        var words = new string[raw.Count];
        for (var idx = 0; idx < raw.Count; idx++)
            words[idx] = raw[idx].ToLowerInvariant().Trim(Punctuation);

        var used = new HashSet<int>();
        var dateUsed = new HashSet<int>();
        var tags = new List<string>();
        string? repeatRule = null;
        int? priority = null;

        var todayLocal = TodoDates.LocalDay(now, tz);
        var today = TodoDates.StartOfDay(todayLocal, tz);
        DateTimeOffset? day = null;
        (int Hour, int Minute)? clock = null;

        void Take(int start, int end, bool isDate = true)
        {
            for (var k = start; k <= end; k++)
            {
                used.Add(k);
                if (isDate) dateUsed.Add(k);
            }
        }

        DateTimeOffset Coming(DayOfWeek target, bool includingToday = false)
        {
            var ahead = ((int)target - (int)todayLocal.DayOfWeek + 7) % 7;
            if (ahead == 0 && !includingToday) ahead = 7;
            return TodoDates.StartOfDay(todayLocal.AddDays(ahead), tz);
        }

        DateTimeOffset? MonthDay(int month, int dayOfMonth, int? year = null)
        {
            var y = year ?? todayLocal.Year;
            if (month is < 1 or > 12 || dayOfMonth < 1 || dayOfMonth > DateTime.DaysInMonth(y, month)) return null;
            var candidate = new DateTime(y, month, dayOfMonth);
            if (year == null && candidate < todayLocal)
            {
                y += 1;
                if (dayOfMonth > DateTime.DaysInMonth(y, month)) return null;
                candidate = new DateTime(y, month, dayOfMonth);
            }
            return TodoDates.StartOfDay(candidate, tz);
        }

        bool IsAllCapsShortWeekday(int index)
        {
            var clean = raw[index].Trim(Punctuation);
            return clean.Length <= 4
                && string.Equals(clean, clean.ToUpperInvariant(), StringComparison.Ordinal)
                && clean.Any(char.IsLetter);
        }

        bool IsTrailingOrMeta(string? nextWord)
        {
            if (nextWord == null) return true;
            if (nextWord.StartsWith('#')) return true;
            if (Priorities.ContainsKey(nextWord)) return true;
            if (MetaTriggers.Contains(nextWord)) return true;
            if (Weekdays.ContainsKey(nextWord) || Months.ContainsKey(nextWord) || ParseTime(nextWord, bare: false) != null) return true;
            return false;
        }

        for (var i = 0; i < words.Length; i++)
        {
            if (used.Contains(i)) continue;
            var word = words[i];
            var next = i + 1 < words.Length ? words[i + 1] : null;
            var after = i + 2 < words.Length ? words[i + 2] : null;

            // Tags and priority: read regardless of `dates`.
            if (!goal && metadata && word.StartsWith('#') && word.Length > 1)
            {
                var tag = raw[i][1..].Trim(Punctuation);
                if (tag.Length > 30) tag = tag[..30];
                if (tag.Length > 0 && !tags.Any(t => string.Equals(t, tag, StringComparison.OrdinalIgnoreCase)))
                    tags.Add(tag);
                Take(i, i, isDate: false);
                continue;
            }
            if (!goal && metadata && priorities && Priorities.TryGetValue(word, out var level))
            {
                priority = level;
                Take(i, i, isDate: false);
                continue;
            }
            if (!dates) continue;

            // Recurrence.
            if (!goal && repeats && word == "every" && next != null)
            {
                if (Weekdays.TryGetValue(next, out var everyDay) || (next == "sun" && (everyDay = DayOfWeek.Sunday) == DayOfWeek.Sunday))
                {
                    repeatRule = "weekly";
                    day ??= Coming(everyDay, includingToday: true);
                    Take(i, i + 1);
                    continue;
                }
                if (EveryRules.TryGetValue(next, out var everyRule))
                {
                    repeatRule = everyRule;
                    Take(i, i + 1);
                    continue;
                }
            }
            if (!goal && repeats && IsTrailingOrMeta(next) && BareRules.TryGetValue(word, out var bareRule))
            {
                repeatRule = bareRule;
                Take(i, i);
                continue;
            }

            // Unsupported recurrence stays entirely literal, including its weekday.
            if (!goal && !repeats && word == "every" && next != null && (Weekdays.ContainsKey(next) || next == "sun"))
            {
                i += 1;
                continue;
            }

            // Day expressions.
            if (word == "today") { day = today; Take(i, i); continue; }
            if (word == "tonight") { day = today; clock ??= (20, 0); Take(i, i); continue; }
            if (word is "tomorrow" or "tmrw") { day = TodoDates.StartOfDay(todayLocal.AddDays(1), tz); Take(i, i); continue; }
            if (word == "next" && next != null)
            {
                if (next == "week") { day = TodoDates.StartOfDay(todayLocal.AddDays(7), tz); Take(i, i + 1); continue; }
                if (next == "month") { day = TodoDates.StartOfDay(todayLocal.AddMonths(1), tz); Take(i, i + 1); continue; }
                if (Weekdays.TryGetValue(next, out var nextWd))
                {
                    var coming = TodoDates.LocalDay(Coming(nextWd), tz);
                    day = TodoDates.StartOfDay(coming.AddDays(7), tz);
                    Take(i, i + 1);
                    continue;
                }
            }
            if (word == "in" && next != null && after != null
                && (int.TryParse(next, NumberStyles.None, CultureInfo.InvariantCulture, out var count) || Counts.TryGetValue(next, out count))
                && count is >= 1 and <= 366)
            {
                DateTime? shifted = after switch
                {
                    "day" or "days" => todayLocal.AddDays(count),
                    "week" or "weeks" => todayLocal.AddDays(count * 7),
                    "month" or "months" => todayLocal.AddMonths(count),
                    _ => null,
                };
                if (shifted is { } targetDay)
                {
                    day = TodoDates.StartOfDay(targetDay, tz);
                    Take(i, i + 2);
                    continue;
                }
            }
            if (word is "on" or "this" && next != null && Weekdays.TryGetValue(next, out var onWd))
            {
                day = Coming(onWd);
                Take(i, i + 1);
                continue;
            }
            if (Weekdays.TryGetValue(word, out var bareWd) && !IsAllCapsShortWeekday(i))
            {
                day = Coming(bareWd);
                Take(i, i);
                continue;
            }
            if (Months.TryGetValue(word, out var month1) && next != null && TryDayNumber(next, out var dayNum1) && MonthDay(month1, dayNum1) is { } md1)
            {
                day = md1;
                Take(i, i + 1);
                continue;
            }
            if (TryDayNumber(word, out var dayNum2) && next != null && Months.TryGetValue(next, out var month2) && MonthDay(month2, dayNum2) is { } md2)
            {
                day = md2;
                Take(i, i + 1);
                continue;
            }

            // 11/20, 11/20/26, 11/20/2026 (month first), excluding common fractions like 1/2 or 3/4.
            var slash = word.Split('/');
            if (slash.Length is 2 or 3 && !IsCommonFraction(slash)
                && slash.All(p => p.Length > 0 && p.All(char.IsAsciiDigit))
                && int.TryParse(slash[0], NumberStyles.None, CultureInfo.InvariantCulture, out var sm) && sm is >= 1 and <= 12
                && int.TryParse(slash[1], NumberStyles.None, CultureInfo.InvariantCulture, out var sd) && sd is >= 1 and <= 31)
            {
                int? sy = null;
                if (slash.Length == 3 && int.TryParse(slash[2], NumberStyles.None, CultureInfo.InvariantCulture, out var rawYear))
                    sy = rawYear < 100 ? 2000 + rawYear : rawYear;
                if (MonthDay(sm, sd, sy) is { } slashDate)
                {
                    day = slashDate;
                    Take(i, i);
                    continue;
                }
            }

            // Time expressions (skipped for goals).
            if (goal) continue;
            if (word == "noon") { clock = (12, 0); Take(i, i); continue; }
            if (word == "at" && next != null)
            {
                if (next == "noon") { clock = (12, 0); Take(i, i + 1); continue; }
                if (after is "am" or "pm" && ParseTime(next + after, bare: false) is { } atAmPm)
                {
                    clock = atAmPm;
                    Take(i, i + 2);
                    continue;
                }
                if (ParseTime(next, bare: true) is { } atBare)
                {
                    clock = atBare;
                    Take(i, i + 1);
                    continue;
                }
            }
            if (next is "am" or "pm" && ParseTime(word + next, bare: false) is { } nextAmPm)
            {
                clock = nextAmPm;
                Take(i, i + 1);
                continue;
            }
            if (ParseTime(word, bare: false) is { } standaloneTime)
            {
                clock = standaloneTime;
                Take(i, i);
                continue;
            }
        }

        // Goals: "by", "before", or "until" just before the day is part of the date words.
        if (goal && dateUsed.Count > 0)
        {
            var first = dateUsed.Min();
            if (first > 0 && !used.Contains(first - 1) && words[first - 1] is "by" or "before" or "until")
                Take(first - 1, first - 1);
        }

        DateTimeOffset? finalDue = null;
        var hasTime = false;
        if (clock is { } clk && !goal)
        {
            var baseDay = TodoDates.LocalDay(day ?? today, tz);
            var localMoment = baseDay.AddHours(clk.Hour).AddMinutes(clk.Minute);
            var moment = new DateTimeOffset(localMoment, tz.GetUtcOffset(localMoment));
            if (day == null && moment <= now)
            {
                var nextDayMoment = localMoment.AddDays(1);
                moment = new DateTimeOffset(nextDayMoment, tz.GetUtcOffset(nextDayMoment));
            }
            finalDue = moment;
            hasTime = true;
        }
        else if (day is { } pickedDay)
        {
            finalDue = pickedDay;
        }
        else if (repeatRule != null)
        {
            finalDue = today; // "water the plants every day" starts today
        }

        var keptTokens = new List<string>(raw.Count);
        for (var idx = 0; idx < raw.Count; idx++)
            if (!used.Contains(idx)) keptTokens.Add(raw[idx]);
        var kept = string.Join(" ", keptTokens);

        // A line that is nothing but a date ("tomorrow") keeps its words as the title.
        if (string.IsNullOrWhiteSpace(kept))
            return new TodoQuickRead { Title = string.Join(" ", raw) };

        string? dateWords = null;
        if (dateUsed.Count > 0)
            dateWords = string.Join(" ", dateUsed.Order().Select(idx => raw[idx]));

        return new TodoQuickRead
        {
            Title = kept,
            Due = finalDue,
            HasTime = hasTime,
            RepeatRule = repeatRule,
            Tags = tags,
            Priority = priority,
            DateWords = dateWords,
        };
    }

    private static List<string> SplitTokens(string text)
    {
        var result = new List<string>();
        var start = -1;
        for (var i = 0; i < text.Length; i++)
        {
            var sep = text[i] is ' ' or '\n' or '\r' or '\t';
            if (sep)
            {
                if (start >= 0) { result.Add(text[start..i]); start = -1; }
            }
            else if (start < 0)
            {
                start = i;
            }
        }
        if (start >= 0) result.Add(text[start..]);
        return result;
    }

    private static bool TryDayNumber(string word, out int value)
    {
        value = 0;
        var digits = word;
        foreach (var suffix in OrdinalSuffixes)
        {
            if (digits.EndsWith(suffix, StringComparison.Ordinal) && digits.Length > suffix.Length)
            {
                digits = digits[..^suffix.Length];
                break;
            }
        }
        if (digits.Length == 0 || !digits.All(char.IsAsciiDigit)) return false;
        return int.TryParse(digits, NumberStyles.None, CultureInfo.InvariantCulture, out value) && value is >= 1 and <= 31;
    }

    /// "9am", "9:30pm", "17:00"; with `bare`, "5" and "5:30" too (after "at").
    /// Single-letter "a"/"p" suffixes require minutes ("9:30a") so tokens like "2a" ("Buy 2a fuses") stay literal.
    private static (int Hour, int Minute)? ParseTime(string word, bool bare)
    {
        var body = word;
        char? half = null;
        var shortSuffix = false;
        foreach (var mark in TimeSuffixes)
        {
            if (body.EndsWith(mark, StringComparison.Ordinal)
                && body.Length > mark.Length
                && char.IsAsciiDigit(body[body.Length - mark.Length - 1]))
            {
                half = mark[0];
                shortSuffix = mark.Length == 1;
                body = body[..^mark.Length];
                break;
            }
        }

        var pieces = body.Split(':');
        if (shortSuffix && pieces.Length != 2) return null;
        if (pieces.Length is < 1 or > 2) return null;
        if (pieces[0].Length == 0 || !pieces[0].All(char.IsAsciiDigit)) return null;
        if (!int.TryParse(pieces[0], NumberStyles.None, CultureInfo.InvariantCulture, out var hour)) return null;

        var minute = 0;
        if (pieces.Length == 2)
        {
            if (pieces[1].Length != 2 || !pieces[1].All(char.IsAsciiDigit)) return null;
            if (!int.TryParse(pieces[1], NumberStyles.None, CultureInfo.InvariantCulture, out minute) || minute is < 0 or >= 60) return null;
        }

        if (half is { } h)
        {
            if (hour is < 1 or > 12) return null;
            return ((hour % 12) + (h == 'p' ? 12 : 0), minute);
        }

        if (pieces.Length == 2 && hour is >= 0 and <= 23 && (!bare || hour > 12 || hour == 0))
            return (hour, minute);
        if (!bare || hour is < 1 or > 12) return null;
        // "at 5" is afternoon; "at 9" is morning; "at 12" is noon.
        return (hour == 12 ? 12 : (hour <= 7 ? hour + 12 : hour), minute);
    }

    /// Common measurement/cooking fractions ("1/2 gallon", "3/4 inch") should not be misread as month/day dates.
    private static bool IsCommonFraction(string[] slash)
    {
        if (slash.Length != 2 || slash[0].Length != 1 || slash[1].Length != 1) return false;
        if (!int.TryParse(slash[0], NumberStyles.None, CultureInfo.InvariantCulture, out var num)) return false;
        if (!int.TryParse(slash[1], NumberStyles.None, CultureInfo.InvariantCulture, out var den)) return false;
        return (num, den) is (1, 2) or (1, 3) or (1, 4) or (2, 3) or (3, 4) or (1, 8) or (3, 8) or (5, 8) or (7, 8);
    }
}
