using System.Globalization;
using System.Net.Http.Headers;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Browser;
using Hermes.Core.Capabilities;
using Hermes.Core.Settings;

namespace Hermes.Core.Notifications;

/// Port of HermesKit/Push/AddOnChanges.swift: parses release commits from mrcharlesiv/hermes-hq-plugins into
/// one line per version newer than Hermes's copy, merges live GitHub notes with curated built-in release notes
/// so offline or rate-limited checks still explain every HQ add-on update, and compares semver with pre-releases.
public static class AddOnChanges
{
    public const string PushPluginName = "hermes-hq-push";
    public const string PushWantedVersion = "0.9.74";
    public const string BrowserPluginName = "hermes-hq-browser";
    public const string ProactivePluginName = ProactivityBeta.PluginName;
    public const string DefaultRepo = "mrcharlesiv/hermes-hq-plugins";

    public sealed record Change(string Version, string Line);

    private sealed record ParsedVersion(int[] Core, string[] PreRelease);

    private static readonly HttpClient SharedHttp = new() { Timeout = TimeSpan.FromSeconds(10) };

    /// Any first-party Hermes HQ plugin published in `mrcharlesiv/hermes-hq-plugins` (including future `hermes-hq-*` plugins).
    public static bool IsHQPlugin(string? plugin) =>
        !string.IsNullOrWhiteSpace(plugin)
        && plugin.Trim().StartsWith("hermes-hq-", StringComparison.OrdinalIgnoreCase);

    /// Friendly display name shown in update sheets and reminders.
    public static string DisplayTitle(string plugin) => plugin switch
    {
        PushPluginName => "Hermes HQ Add-on",
        BrowserPluginName => "Browser Add-on",
        ProactivePluginName => ProactivityBeta.PageLabel,
        _ => DisplayName.Title(plugin),
    };

    /// Commit subject prefixes used in `mrcharlesiv/hermes-hq-plugins` for each plugin.
    public static IReadOnlyList<string> CommitAliases(string plugin) => plugin switch
    {
        ProactivePluginName => [plugin, "Proactivity"],
        _ => [plugin],
    };

    /// Minimum known target version for built-in HQ plugins when live GitHub notes are unavailable.
    public static string? DefaultTargetVersion(string plugin) => plugin switch
    {
        PushPluginName => PushWantedVersion,
        BrowserPluginName => BrowserAddOn.WantedVersion,
        ProactivePluginName => BuiltInNotes.TryGetValue(plugin, out var notes) && notes.Count > 0 ? notes[0].Version : null,
        _ => null,
    };

    /// GitHub's commit list for one add-on's folder, newest first.
    public static Uri? CommitsUrl(string plugin, string repo = DefaultRepo) =>
        Uri.TryCreate($"https://api.github.com/repos/{repo}/commits?path={Uri.EscapeDataString(plugin)}&per_page=60", UriKind.Absolute, out var uri)
            ? uri
            : null;

    // ---------------------------------------------------------------- Version parsing & semver comparison

    private static ParsedVersion? ParseVersion(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        var text = raw.Trim();
        if (text.StartsWith('v') || text.StartsWith('V')) text = text[1..];
        if (text.Length == 0) return null;
        var plus = text.IndexOf('+');
        if (plus >= 0) text = text[..plus];

        string coreText;
        string[] preRelease;
        var dash = text.IndexOf('-');
        if (dash >= 0)
        {
            coreText = text[..dash];
            var pre = text[(dash + 1)..];
            if (pre.Length == 0) return null;
            preRelease = pre.Split('.');
            if (preRelease.Any(p => p.Length == 0)) return null;
        }
        else
        {
            coreText = text;
            preRelease = [];
        }

        var rawParts = coreText.Split('.');
        if (rawParts.Length == 0) return null;
        var core = new int[rawParts.Length];
        for (var i = 0; i < rawParts.Length; i++)
        {
            if (rawParts[i].Length == 0 || !int.TryParse(rawParts[i], NumberStyles.None, CultureInfo.InvariantCulture, out var part))
                return null;
            core[i] = part;
        }
        return new ParsedVersion(core, preRelease);
    }

    /// True for standard (`0.9.91`, `3.13.1`) and pre-release (`0.4.0-beta.2`) version strings.
    public static bool IsValidVersion(string? raw) => ParseVersion(raw) != null;

    /// True when `raw` looks like a Git commit SHA (7–40 hex characters, no dot) rather than a version number.
    public static bool IsCommitSha(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return false;
        var text = raw.Trim();
        if (text.Length is < 7 or > 40 || text.Contains('.')) return false;
        foreach (var ch in text)
        {
            if (!char.IsAsciiHexDigit(ch)) return false;
        }
        return true;
    }

    /// Semver comparison supporting pre-release tags (`0.4.0` > `0.4.0-beta.10` > `0.4.0-beta.2` > `0.4.0-beta.1` > `0.3.0-beta.3`).
    /// Returns `< 0` if `lhs < rhs`, `0` if equal, `> 0` if `lhs > rhs`, or `null` if either isn't a valid version.
    public static int? CompareVersions(string lhs, string rhs)
    {
        var a = ParseVersion(lhs);
        var b = ParseVersion(rhs);
        if (a == null || b == null) return null;
        var count = Math.Max(a.Core.Length, b.Core.Length);
        for (var i = 0; i < count; i++)
        {
            var av = i < a.Core.Length ? a.Core[i] : 0;
            var bv = i < b.Core.Length ? b.Core[i] : 0;
            if (av != bv) return av < bv ? -1 : 1;
        }
        if (a.PreRelease.Length == 0 && b.PreRelease.Length == 0) return 0;
        if (a.PreRelease.Length == 0) return 1; // stable > pre-release of same core
        if (b.PreRelease.Length == 0) return -1;
        var preCount = Math.Max(a.PreRelease.Length, b.PreRelease.Length);
        for (var i = 0; i < preCount; i++)
        {
            if (i >= a.PreRelease.Length) return -1;
            if (i >= b.PreRelease.Length) return 1;
            var ap = a.PreRelease[i];
            var bp = b.PreRelease[i];
            if (string.Equals(ap, bp, StringComparison.Ordinal)) continue;
            var aIsInt = int.TryParse(ap, NumberStyles.None, CultureInfo.InvariantCulture, out var ai);
            var bIsInt = int.TryParse(bp, NumberStyles.None, CultureInfo.InvariantCulture, out var bi);
            if (aIsInt && bIsInt) return ai < bi ? -1 : 1;
            if (aIsInt) return -1; // numeric identifier has lower precedence than non-numeric
            if (bIsInt) return 1;
            var cmp = string.Compare(ap, bp, StringComparison.OrdinalIgnoreCase);
            if (cmp != 0) return cmp < 0 ? -1 : 1;
            return string.CompareOrdinal(ap, bp) < 0 ? -1 : 1;
        }
        return 0;
    }

    /// Semver `version >= minimum` (supports pre-release tags like `0.4.0-beta.2`).
    public static bool VersionAtLeast(string? version, string minimum) =>
        version != null && (CompareVersions(version, minimum) ?? -1) >= 0;

    /// Strict weak ordering, newest version first: compares semver components including pre-release tags
    /// and breaks equivalent ties (e.g. "1.0" vs "1.0.0") deterministically by raw string order.
    public static bool IsNewer(string lhs, string rhs)
    {
        if (CompareVersions(lhs, rhs) is { } cmp && cmp != 0) return cmp > 0;
        return string.CompareOrdinal(lhs, rhs) > 0;
    }

    // ---------------------------------------------------------------- Parsing release commits

    /// Parses GitHub's JSON array of commits into versions newer than `after`, newest first.
    public static List<Change> Parse(string json, string plugin, string? after, int limit = 3)
    {
        if (J.Parse(json) is not JsonArray commits) return [];
        var subjects = new List<string>(commits.Count);
        foreach (var item in commits)
        {
            if (item.Obj("commit").Str("message") is not { } msg) continue;
            var newline = msg.IndexOf('\n');
            var firstLine = newline >= 0 ? msg[..newline] : msg;
            subjects.Add(firstLine.TrimEnd('\r'));
        }
        return Changes(subjects, plugin, after, limit);
    }

    /// Parses commit subjects into versions newer than `after`, newest first (oldest commit per version wins).
    public static List<Change> Changes(IEnumerable<string> subjects, string plugin, string? after, int limit = 3)
    {
        if (limit <= 0) return [];
        var order = new List<string>();
        var lines = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var subject in subjects)
        {
            var colon = subject.IndexOf(':');
            if (colon < 0) continue;
            var header = subject[..colon];
            if (ExtractVersion(header, plugin) is not { } version) continue;
            if (!string.IsNullOrWhiteSpace(after) && VersionAtLeast(after, version)) continue;
            var words = Tidy(subject[(colon + 1)..]);
            if (words.Length == 0) continue;
            if (!lines.ContainsKey(version)) order.Add(version);
            lines[version] = words; // older commits come later: the release's own words win
        }
        order.Sort(CompareDescending);
        return [.. order.Take(limit).Select(v => new Change(v, lines[v]))];
    }

    private static int CompareDescending(string a, string b)
    {
        if (string.Equals(a, b, StringComparison.Ordinal)) return 0;
        return IsNewer(a, b) ? -1 : 1;
    }

    /// Extracts `<version>` for `plugin` from a commit header before `:`.
    /// Supports single headers (`hermes-hq-push 0.9.91`), aliases (`Proactivity 0.4.0-beta.2`),
    /// and compound headers (`hermes-hq-push 0.9.89 & hermes-hq-browser 3.13.1`).
    private static string? ExtractVersion(string header, string plugin)
    {
        var aliases = CommitAliases(plugin);
        var parts = header.Split(['&', '+']);
        foreach (var rawPart in parts)
        {
            var segment = rawPart.Trim();
            foreach (var alias in aliases)
            {
                var prefix = alias + " ";
                if (segment.Length <= prefix.Length || !segment.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                    continue;
                var candidate = segment[prefix.Length..].Trim();
                if (candidate.StartsWith('v') || candidate.StartsWith('V')) candidate = candidate[1..];
                if (candidate.Length == 0 || !char.IsAsciiDigit(candidate[0]) || !IsValidVersion(candidate))
                    continue;
                return candidate;
            }
        }
        return null;
    }

    /// Merges live GitHub release lines with curated built-in notes so future releases appear automatically while
    /// offline, rate-limited, or unusually formatted commits still explain what changed.
    public static List<Change> Merge(IEnumerable<Change> live, string plugin, string? after, int limit = 25)
    {
        if (limit <= 0) return [];
        var byVersion = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var change in live)
        {
            if (!IsValidVersion(change.Version)) continue;
            if (!string.IsNullOrWhiteSpace(after) && VersionAtLeast(after, change.Version)) continue;
            if (!string.IsNullOrEmpty(change.Line)) byVersion[change.Version] = change.Line;
        }
        foreach (var change in BuiltInChanges(plugin, after, limit))
            byVersion[change.Version] = change.Line;
        var sorted = byVersion.Keys.ToList();
        sorted.Sort(CompareDescending);
        return [.. sorted.Take(limit).Select(v => new Change(v, byVersion[v]))];
    }

    /// Curated built-in release notes newer than `after`, newest first.
    public static List<Change> BuiltInChanges(string plugin, string? after, int limit = 25)
    {
        if (limit <= 0 || !BuiltInNotes.TryGetValue(plugin, out var all)) return [];
        var hasValidAfter = !string.IsNullOrWhiteSpace(after) && IsValidVersion(after);
        return [.. all.Where(c => !hasValidAfter || !VersionAtLeast(after, c.Version)).Take(limit)];
    }

    /// The newest version the list names (the one an update gets), or null.
    public static string? Newest(IReadOnlyList<Change> changes) => changes.Count > 0 ? changes[0].Version : null;

    /// Best human-readable target version for an update card: prefers a real version from `changes` over a raw Git SHA
    /// or older minimum target, and falls back to `fallbackTo` or the plugin's known required version.
    public static string? BestTargetVersion(string? liveNewest, string? fallbackTo, string plugin)
    {
        var trimmedFallback = string.IsNullOrWhiteSpace(fallbackTo) ? null : fallbackTo.Trim();
        var knownDefault = DefaultTargetVersion(plugin);
        var baseline = trimmedFallback != null && !IsCommitSha(trimmedFallback)
            ? trimmedFallback
            : knownDefault ?? trimmedFallback;
        var live = string.IsNullOrWhiteSpace(liveNewest) ? null : liveNewest.Trim();
        if (live == null) return baseline;
        if (baseline == null || IsCommitSha(baseline)) return live;
        return CompareVersions(live, baseline) is { } cmp ? (cmp >= 0 ? live : baseline) : live;
    }

    /// "0.9.33 → 0.9.40", "0.9.40 · newer build", "New · 0.9.40", "To 0.9.40", "0.9.33 → newest", or null.
    public static string? VersionLine(string? from, string? to, bool setUp)
    {
        var f = string.IsNullOrWhiteSpace(from) ? null : from.Trim();
        var t = string.IsNullOrWhiteSpace(to) ? null : to.Trim();
        return (f, t) switch
        {
            (not null, not null) => string.Equals(f, t, StringComparison.Ordinal) ? $"{f} · newer build" : $"{f} → {t}",
            (null, not null) => setUp ? $"New · {t}" : $"To {t}",
            (not null, null) => $"{f} → newest",
            _ => null,
        };
    }

    /// Guaranteed plain-English explanation when an update card has no per-version lines.
    public static string FallbackSummary(string plugin, string? from, string? to, bool setUp, string? botsNote = null, string? description = null)
    {
        var title = DisplayTitle(plugin);
        if (setUp)
        {
            return plugin switch
            {
                PushPluginName => "Installs the Hermes HQ Add-on for lock-screen alerts, question and draft cards, shared tasks, goals, and live activity updates.",
                BrowserPluginName => "Installs the Browser Add-on so you can watch a bot’s browser live and take over when it needs you.",
                ProactivePluginName => "Installs Proactivity (Beta) for open-loop tracking, quiet background checks, and daily briefs (starts off until enabled).",
                _ => !string.IsNullOrWhiteSpace(description) ? description.Trim() : $"Installs {title} on Hermes.",
            };
        }
        if (!string.IsNullOrWhiteSpace(from) && !string.IsNullOrWhiteSpace(to) && string.Equals(from, to, StringComparison.Ordinal))
        {
            if (!string.IsNullOrWhiteSpace(botsNote))
                return $"Brings the remaining bots onto version {to} so every bot has the same features and fixes.";
            return $"Reinstalls version {to} with the latest build fixes for {title}.";
        }
        return plugin switch
        {
            PushPluginName => "Upgrades the Hermes HQ Add-on with the latest fixes and features for notifications, interactive cards, tasks, and goals.",
            BrowserPluginName => "Upgrades the Browser Add-on with the latest live browser watching, takeover, and Hermes compatibility fixes.",
            ProactivePluginName => "Upgrades Proactivity (Beta) with the latest improvements to open-loop tracking, suggestions, and chat hand-offs.",
            _ => !string.IsNullOrWhiteSpace(description)
                ? $"Updates {title} to the newest available version. {description.Trim()}"
                : $"Updates {title} with the latest fixes and improvements.",
        };
    }

    /// Fetches live release commits from GitHub for `plugin`; returns empty on offline/rate-limit/error.
    public static async Task<List<Change>> FetchLiveAsync(string plugin, string? after, int limit = 25,
        HttpClient? http = null, CancellationToken ct = default)
    {
        if (CommitsUrl(plugin) is not { } url) return [];
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
            req.Headers.UserAgent.ParseAdd("HermesHQ");
            using var res = await (http ?? SharedHttp).SendAsync(req, HttpCompletionOption.ResponseContentRead, ct).ConfigureAwait(false);
            if (!res.IsSuccessStatusCode) return [];
            var text = await res.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            return Parse(text, plugin, after, limit);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception)
        {
            return [];
        }
    }

    // ---------------------------------------------------------------- Cleaning commit lines

    /// A bracketed aside with a code name in it: a snake_case word, a dotted name or anything in backticks.
    private static readonly Regex CodeAside = new(
        @"\s*\([^()]*(?:\b[A-Za-z0-9]+_\w+|\b[a-z]\w+\.[a-z]\w+\b|`[^`]*`)[^()]*\)",
        RegexOptions.Compiled);

    /// A bracketed internal attribution or issue tag: `(owner 2026-11-23)`, `(issue #11)`, `(hermes-hq-app#413)`.
    private static readonly Regex MetaAside = new(
        @"\s*\((?:owner\b[^()]*|issue\s+#\d+[^()]*|[a-z0-9-]+#\d+[^()]*)\)",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    /// "after an update the app reads …; the add-on says …" → "After an update the app reads …".
    public static string Tidy(string text)
    {
        var words = text.Trim();
        var semicolon = words.IndexOf(';');
        if (semicolon >= 0) words = words[..semicolon].Trim();
        if (words.Count(c => c == '(') > words.Count(c => c == ')'))
        {
            var open = words.LastIndexOf('(');
            if (open >= 0) words = words[..open].Trim();
        }
        words = CodeAside.Replace(words, "");
        words = MetaAside.Replace(words, "").Trim();
        if (words.Length > 120) words = words[..119].Trim() + "…";
        if (words.Length == 0) return "";
        return char.ToUpperInvariant(words[0]) + words[1..];
    }

    // ---------------------------------------------------------------- Curated built-in release notes

    public static readonly IReadOnlyDictionary<string, IReadOnlyList<Change>> BuiltInNotes =
        new Dictionary<string, IReadOnlyList<Change>>(StringComparer.Ordinal)
        {
            [PushPluginName] =
            [
                new("0.9.91", "Shows context before clarify question cards and replies in chat when asked to explain"),
                new("0.9.90", "Lets other add-ons send suggestions directly to Tasks › Ideas"),
                new("0.9.89", "Fixes vault login autofill on Hermes 0.23.4 and alerts when a bot asks for your browser"),
                new("0.9.88", "Adds Tasks › Ideas source toggles and multi-bot sweeps"),
                new("0.9.87", "Bots show flights, hotels, and products as interactive cards instead of plain tables"),
                new("0.9.86", "Adds travel cards, Cc and Bcc on email drafts, product links on orders, and connector ask-before-running rules"),
                new("0.9.85", "Goal tasks carry attached files, links, and notes through when accepted"),
                new("0.9.82", "Bots ask once before buying and tasks note when awaited items arrive"),
                new("0.9.81", "1Password logins only fill on the exact site requested"),
                new("0.9.80", "Restores pull request status badges on Hermes 0.23.3+"),
                new("0.9.79", "Matches pull request badges to the right public PR after notes-only merges"),
                new("0.9.76", "Shows public pull request numbers for merged work"),
                new("0.9.75", "Tracks every pull request and branch per chat"),
                new("0.9.74", "Suggests titles for new tasks without renaming existing ones, and adds Goals"),
                new("0.9.73", "Keeps empty branches from showing as open pull request work"),
                new("0.9.71", "Speeds up pull request status checks for coding projects"),
                new("0.9.70", "Marks merged and closed branches immediately and links projects to repositories"),
                new("0.9.68", "Shows each chat’s branch status (open, merged locally, or merged publicly)"),
                new("0.9.67", "Tracks what became of pull requests opened from a chat"),
                new("0.9.65", "Silences alerts for the chat you already have open on screen"),
                new("0.9.64", "Shows images a bot made before asking about them, plus ask-to-act cards"),
                new("0.9.62", "Delivers login and one-time code requests from sign-in frames inside a page"),
                new("0.9.61", "Adds the Soft look for dashboard tiles"),
                new("0.9.60", "Adds shopping product and order cards with payment approval safeguards"),
                new("0.9.59", "Lets bots check for emailed/texted codes first and request a single 1Password login on approval"),
                new("0.9.58", "Applies plugin updates only when packages, findings, and capabilities match what you approved"),
                new("0.9.57", "Shows approval and question cards when a bot handles a scheduled job report"),
                new("0.9.54", "Opens the parent chat when tapping a helper agent’s approval alert"),
                new("0.9.53", "Adds task priority, tags, reminders, start dates, repeat schedules, and files"),
                new("0.9.52", "Lets you approve and install plugin updates that add Python packages from the app"),
                new("0.9.50", "Improves dashboard tile layout so status boards fit cleanly at every size"),
                new("0.9.47", "Adds draft message cards so you can review, edit, or send before a bot messages anyone"),
                new("0.9.45", "Fixes daily Task Ideas runs saving suggestions on newer Hermes gateways"),
                new("0.9.44", "Matches login and code prompts to the exact site tab the bot asked for"),
                new("0.9.42", "Keeps scheduled job images when a bot summarizes them in its chat"),
                new("0.9.40", "Refreshes the task list after updates and reports the add-on’s version"),
                new("0.9.39", "Adds Task Ideas suggestions"),
                new("0.9.38", "Adds a dedicated Task Page for every task"),
                new("0.9.37", "Adds per-task chats, watches, and pre-due checks"),
                new("0.9.36", "Adds custom task sections and lets you turn Tasks off completely"),
                new("0.9.32", "Adds shared Tasks between you and your bots"),
            ],
            [BrowserPluginName] =
            [
                new("3.13.1", "Alerts when a bot asks for your browser and improves manual checkout fallback"),
                new("3.13.0", "Adds opt-in on-demand Chrome so browsers start only when needed"),
                new("3.12.0", "Sends every pointer drag sample in order for smoother dragging"),
                new("3.11.0", "Reports whether Hermes is hosted for Browser Use Cloud setup"),
                new("3.10.0", "Adds Use for All Bots for Browser Use Cloud"),
                new("3.9.0", "Adds Browser Use Cloud support so bots can browse in the cloud"),
                new("3.8.1", "Shows the active site the bot is viewing in the chat’s browsing chip"),
                new("3.8.0", "Adds compatibility with Hermes 0.22.6 and newer while supporting older gateways"),
                new("3.7.0", "Forwards browser alerts, prompts, and sign-in account choosers to your device"),
            ],
            [ProactivePluginName] =
            [
                new("0.4.0-beta.2", "Cleans up chat hand-off messages so dates are only stated once"),
                new("0.4.0-beta.1", "Posts proactive findings and morning briefs directly in the bot’s chat"),
                new("0.3.0-beta.3", "Automatically removes a suggestion when its open item is closed"),
                new("0.3.0-beta.2", "Polishes the Proactivity page layout and spacing"),
                new("0.3.0-beta.1", "Adds Tasks › Ideas integration and stability fixes for background checks"),
                new("0.2.0-beta.2", "Filters scheduled job sessions out of chat scans for cleaner tracking"),
                new("0.2.0-beta.1", "Adds the /proactivity command and read-only recent chat scanning"),
                new("0.1.0-beta.1", "Introduces opt-in Proactivity (Beta) with open-loop tracking, daily briefs, and its own page"),
            ],
        };
}
