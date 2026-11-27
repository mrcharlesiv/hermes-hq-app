using System.Globalization;

namespace Hermes.Core.Insights;

/// [tiles-v2] How often a new tile should refresh (`NewTile.swift` `TileScheduleChoice`).
public sealed record TileScheduleChoice(string Kind, TileJobs.Frequency? Frequency = null)
{
    public static readonly TileScheduleChoice Auto = new("auto");
    public static readonly TileScheduleChoice OneTime = new("oneTime");
    public static TileScheduleChoice Every(TileJobs.Frequency frequency) => new("every", frequency);

    public string Title => Kind switch
    {
        "auto" => "Automatic",
        "oneTime" => "One-Time (Static)",
        _ => Frequency?.Title ?? "Automatic",
    };

    public string PromptSentence => Kind switch
    {
        "auto" => "Keep it up to date with a scheduled job on a sensible schedule, and tell me how often.",
        "oneTime" => "Make it a one-time static tile (do not create a scheduled job).",
        _ when Frequency is { } freq => $"Keep it up to date with a scheduled job running {freq.Short} (cron: {freq.Cron}), and tell me how often.",
        _ => "Keep it up to date with a scheduled job on a sensible schedule, and tell me how often.",
    };

    public static IReadOnlyList<TileScheduleChoice> AllChoices { get; } =
        [Auto, .. TileJobs.Frequencies.Select(Every), OneTime];
}

/// [tiles-v2] Ranks New Tile ideas for a chosen bot based on keywords in its role, name, or connected tools
/// (`HermesKit/Pages/TilePendingMakers.swift` `TileIdeaMatcher`).
public static class TileIdeaMatcher
{
    public const int FirstIdeas = 6;

    public sealed record Idea(string Words, string Symbol, IReadOnlyList<string> Keywords);
    public sealed record Ranked(string Words, string Symbol, bool Matched);

    public static readonly IReadOnlyList<Idea> Catalog =
    [
        new("Revenue this week, with a chart by day", "chart.bar.fill",
            ["revenue", "sales", "stripe", "finance", "billing", "business", "money", "metrics"]),
        new("Today’s calendar and the next meeting", "calendar",
            ["calendar", "schedule", "meeting", "assistant", "agenda", "google", "outlook"]),
        new("Unread emails that need a reply", "envelope.badge",
            ["mail", "email", "gmail", "inbox", "outlook", "assistant"]),
        new("Weather here for the next 12 hours", "cloud.sun.fill",
            ["weather", "home", "daily", "assistant", "morning"]),
        new("My open tasks, due soonest first", "checklist",
            ["task", "todo", "kanban", "project", "linear", "jira", "assistant"]),
        new("Jobs that ran today, and any that failed", "clock.badge.checkmark",
            ["ops", "devops", "job", "cron", "monitor", "infra", "hermes"]),
        new("Deals closing this month and their total", "target",
            ["sales", "crm", "hubspot", "deal", "revenue", "finance"]),
        new("Spending this month against last month", "dollarsign.circle",
            ["finance", "budget", "spend", "expense", "money", "bank"]),
        new("My stocks and crypto, today’s change", "chart.line.uptrend.xyaxis",
            ["finance", "stock", "crypto", "market", "portfolio", "trading"]),
        new("Messages that mention me in Slack", "bubble.left.and.exclamationmark.bubble.right",
            ["slack", "discord", "chat", "comms", "team"]),
        new("GitHub pull requests waiting on me", "arrow.triangle.pull",
            ["github", "git", "code", "dev", "engineer", "pr", "repo", "coding"]),
        new("Website and server status", "server.rack",
            ["ops", "devops", "server", "infra", "uptime", "site", "cloud", "monitor"]),
        new("My next trip: flights, hotel and times", "airplane",
            ["travel", "flight", "trip", "calendar", "mail", "assistant"]),
        new("Birthdays and follow-ups due this week", "person.2",
            ["crm", "contact", "people", "calendar", "assistant", "social"]),
        new("Steps, sleep and workouts this week", "figure.run",
            ["health", "fitness", "workout", "sleep", "meal", "nutrition", "whoop", "oura"]),
        new("Top headlines in my industry today", "newspaper",
            ["news", "research", "brief", "digest", "media", "web"]),
        new("A countdown to a date that matters", "hourglass",
            ["launch", "event", "calendar", "goal", "milestone"]),
        new("Quote or word of the day", "quote.bubble",
            ["daily", "quote", "journal", "morning"]),
    ];

    /// Ranks `Catalog` so ideas matching `signals` (bot name, id, role, or tools) float first,
    /// preserving relative catalog order within each group.
    public static IReadOnlyList<Ranked> RankedFor(IEnumerable<string?> signals)
    {
        var haystack = string.Join(' ', signals.Where(s => !string.IsNullOrWhiteSpace(s))).ToLowerInvariant();
        var tokens = new HashSet<string>(StringComparer.Ordinal);
        var start = -1;
        for (var i = 0; i <= haystack.Length; i++)
        {
            var alnum = i < haystack.Length && char.IsLetterOrDigit(haystack[i]);
            if (alnum && start < 0) start = i;
            else if (!alnum && start >= 0) { tokens.Add(haystack[start..i]); start = -1; }
        }
        if (tokens.Count == 0) return Catalog.Select(c => new Ranked(c.Words, c.Symbol, false)).ToList();

        var matched = new List<Ranked>();
        var rest = new List<Ranked>();
        foreach (var idea in Catalog)
        {
            var hit = idea.Keywords.Any(kw => tokens.Contains(kw) || haystack.Contains(kw, StringComparison.Ordinal));
            var item = new Ranked(idea.Words, idea.Symbol, hit);
            if (hit) matched.Add(item);
            else rest.Add(item);
        }
        matched.AddRange(rest);
        return matched;
    }
}

/// [tiles] Change Tile's quick changes (`HermesKit/Pages/TileChangeWords.swift`): a tap adds a change to the person's
/// words, a second tap takes it out cleanly.
public static class TileChangeWords
{
    public sealed record QuickChange(string Label, string Words, string Symbol);

    public static readonly IReadOnlyList<QuickChange> Quick =
    [
        new("Bar Chart", "Make it a bar chart", "chart.bar.fill"),
        new("Vs Last Month", "Compare with last month", "calendar"),
        new("Trend", "Show the trend over time", "chart.line.uptrend.xyaxis"),
        new("Bigger Numbers", "Bigger numbers, fewer words", "textformat.size"),
        new("More Detail", "Show more detail", "list.bullet"),
        new("New Colors", "Change the colors", "paintpalette"),
        new("Fix What’s Wrong", "Fix anything that looks wrong", "wrench.and.screwdriver"),
        new("Update More Often", "Update it more often", "clock.arrow.circlepath"),
    ];

    private static readonly CompareInfo Compare = CultureInfo.InvariantCulture.CompareInfo;
    private const CompareOptions MatchOptions = CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace;

    public static bool Contains(string text, string change) =>
        !string.IsNullOrEmpty(change) && Compare.IndexOf(text, change, MatchOptions) >= 0;

    public static string Adding(string change, string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return change;
        if (Contains(trimmed, change)) return text;
        var last = trimmed[^1];
        var joiner = ".,;:!?".Contains(last) ? " " : ", ";
        var start = ".!?".Contains(last) ? change : LowerFirst(change);
        return trimmed + joiner + start;
    }

    public static string Removing(string change, string text)
    {
        var index = Compare.IndexOf(text.AsSpan(), change.AsSpan(), MatchOptions, out var matchLen);
        if (index < 0) return text;
        var lower = index;
        var upper = index + matchLen;
        // Trim preceding comma/semicolon if present, else trailing comma/semicolon.
        var before = lower - 1;
        while (before >= 0 && char.IsWhiteSpace(text[before])) before--;
        if (before >= 0 && (text[before] == ',' || text[before] == ';'))
        {
            lower = before;
        }
        else
        {
            var after = upper;
            while (after < text.Length && char.IsWhiteSpace(text[after])) after++;
            if (after < text.Length && (text[after] == ',' || text[after] == ';'))
            {
                after++;
                while (after < text.Length && char.IsWhiteSpace(text[after])) after++;
                upper = after;
            }
        }
        var left = (text[..lower] + text[upper..]).Trim();
        while (left.Length > 0 && (left[0] == ',' || left[0] == ';')) left = left[1..].Trim();
        return UpperFirst(left);
    }

    public static string Toggling(string change, string text) =>
        Contains(text, change) ? Removing(change, text) : Adding(change, text);

    private static string LowerFirst(string words)
    {
        if (words.Length == 0) return words;
        var end = 0;
        while (end < words.Length && !char.IsWhiteSpace(words[end])) end++;
        var firstWord = words[..end];
        if (firstWord.Length > 1 && firstWord == firstWord.ToUpperInvariant()) return words;
        return char.ToLowerInvariant(words[0]) + words[1..];
    }

    private static string UpperFirst(string words) =>
        words.Length == 0 ? words : char.ToUpperInvariant(words[0]) + words[1..];
}

/// [tiles-v2] Aggregated tile update activity (`HermesKit/Pages/TilePendingMakers.swift` `TileActivitySummary`).
public sealed record TileActivitySummary(
    int TotalJobs,
    int ActiveJobs,
    int PausedJobs,
    int FailingJobs,
    int ScriptJobs,
    int EstimatedModelRunsPerDay)
{
    public static TileActivitySummary Summarize(IEnumerable<TileCronJob> jobs, DateTimeOffset? now = null)
    {
        var at = now ?? DateTimeOffset.UtcNow;
        int total = 0, active = 0, paused = 0, failing = 0, scripts = 0;
        var modelRuns = 0.0;
        foreach (var job in jobs)
        {
            total++;
            var isScript = TileJobs.IsScriptOnly(job);
            if (isScript) scripts++;
            if (TileJobs.IsPaused(job)) { paused++; continue; }
            active++;
            if (TileJobs.HealthOf(job, at).Kind == TileJobs.HealthKind.Failed) failing++;
            if (!isScript && TileJobs.EstimatedRunsPerDay(job) is { } runs) modelRuns += runs;
        }
        return new TileActivitySummary(total, active, paused, failing, scripts,
            (int)Math.Round(modelRuns, MidpointRounding.AwayFromZero));
    }

    public string Headline
    {
        get
        {
            if (TotalJobs == 0) return "No scheduled tiles yet";
            var activeWord = ActiveJobs == 1 ? "1 active tile" : $"{ActiveJobs} active tiles";
            if (ActiveJobs == 0) return PausedJobs == 1 ? "1 tile paused" : $"{PausedJobs} tiles paused";
            if (EstimatedModelRunsPerDay > 0) return $"{activeWord} · ~{EstimatedModelRunsPerDay} model runs/day";
            return ScriptJobs == ActiveJobs ? $"{activeWord} (scripts only)" : activeWord;
        }
    }

    public string? Detail
    {
        get
        {
            var parts = new List<string>();
            if (FailingJobs > 0) parts.Add(FailingJobs == 1 ? "1 failing" : $"{FailingJobs} failing");
            if (PausedJobs > 0 && ActiveJobs > 0) parts.Add($"{PausedJobs} paused");
            if (ScriptJobs > 0 && ScriptJobs < ActiveJobs) parts.Add($"{ScriptJobs} script-only");
            return parts.Count == 0 ? null : string.Join(" · ", parts);
        }
    }
}

/// Prompt builders matching Mac `TileMaker` (`NewTile.swift`).
public static class TilePromptBuilder
{
    public static string NewTilePrompt(string what, TileSize? size = null, TileScheduleChoice? schedule = null)
    {
        var sizeNote = size is { } s ? $" Design it to look great especially at {s.ShapeWords()}." : "";
        var sched = (schedule ?? TileScheduleChoice.Auto).PromptSentence;
        return $"Make me a live tile for my Hermes HQ Dashboard showing: {what}\n\n"
            + $"Use the hermes-hq-push:dashboard-tile skill (open it with skill_view first) and follow it: make the tile the way it says, with the real numbers in, run its check_tile.py until it passes, and look at the pictures it makes.{sizeNote} {sched}\n\n"
            + "If that skill isn't there: one self-contained .html file that fills its window exactly at any size from about 160×160 to 800×600 (100vw/100vh, text in em from a size that grows with the window, charts in SVG with a viewBox, no scrolling, nothing loaded from the network), with a light and a dark look.\n\n"
            + "When it's ready, end your reply with the page alone on its own line: MEDIA:/absolute/path/to/the/tile.html (the app pins it to my Dashboard by itself, so don't tell me how to pin it)";
    }

    public static string ChangePrompt(string path, string what) =>
        $"Change my Hermes HQ Dashboard tile {path}: {what}\n\n"
        + "Use the hermes-hq-push:dashboard-tile skill (open it with skill_view first). Change that same tile in place, the way the skill says: keep its path, its name (unless I asked for a new one), the job that keeps it fresh (its <meta name=\"hq-tile-job\">) and everything I didn't ask to change. If a scheduled job or a refresh script rewrites this tile, change it too so the next update keeps the change. Run check_tile.py until it passes and look at the pictures it makes.\n\n"
        + $"If you need something from me first (which data, a sign-in), ask me and leave out the MEDIA line. When it's done, say in a line or two what you changed, then end your reply with the page alone on its own line: MEDIA:{path}";

    public static string RolledBackPrompt(string path, string name, int version) =>
        $"I rolled my Hermes HQ tile “{name}” ({path}) back to its version {version}. The file is already restored and looks the way I want: don't change its look, layout, <title> or <meta> tags.\n\n"
        + "If a scheduled job or a refresh script rewrites this tile, make sure its next run keeps this version's look and fills in the data this version shows (change the script or the job's prompt if it would bring the newer look back). Then refresh the tile's data once so it's current. Reply in a line or two.";
}
