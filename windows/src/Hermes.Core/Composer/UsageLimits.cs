using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Hermes.Core.Composer;

// ⋯ › Usage & Limits (HermesKit/Chat/UsageLimits.swift): what is left on each signed-in plan, read from the model
// catalog (`model.options` rows' `usage`, `plan_usage` and `limit`), the chat's own tokens (`session.usage`), and the
// pay-as-you-go logins' balances where Hermes gives one (/usage, billing.state). Pure.

/// One subscription window (`ProviderUsageWindow`).
public sealed record UsageWindow(string Label, double UsedPercent, DateTimeOffset? ResetsAt = null, bool ModelScoped = false)
{
    public static UsageWindow? Parse(JsonNode? json) =>
        json.Str("label") is { } label && json.Num("used_percent") is { } used && double.IsFinite(used)
            ? new UsageWindow(label, used, UsageDates.Parse(json.Str("resets_at")), json.Str("scope") == "model")
            : null;
}

public enum UsageAccountState { Ready, Limited, Unknown, Unavailable }

/// One login of a provider's credential pool (`ProviderUsageAccount`).
public sealed record UsageAccount(string Id, string Label, IReadOnlyList<UsageWindow> Windows, UsageAccountState State,
    DateTimeOffset? ResetsAt)
{
    public static UsageAccount? Parse(JsonNode? json)
    {
        if (json.Str("id") is not { } id) return null;
        var state = json.Str("state") switch
        {
            "ready" => UsageAccountState.Ready, "limited" => UsageAccountState.Limited,
            "unavailable" => UsageAccountState.Unavailable, _ => UsageAccountState.Unknown,
        };
        return new UsageAccount(id, json.Str("label") ?? "",
            [.. (json.Arr("windows") ?? []).Select(UsageWindow.Parse).OfType<UsageWindow>()], state,
            UsageDates.Parse(json.Str("resets_at")));
    }
}

/// `ProviderUsage`: one account's windows, or (a pool of several logins) one row per account.
public sealed record ProviderUsage(IReadOnlyList<UsageWindow> Windows, IReadOnlyList<UsageAccount>? Accounts)
{
    public static ProviderUsage? Parse(JsonNode? json) => json is JsonObject
        ? new ProviderUsage([.. (json.Arr("windows") ?? []).Select(UsageWindow.Parse).OfType<UsageWindow>()],
            json.Arr("accounts") is { } a ? [.. a.Select(UsageAccount.Parse).OfType<UsageAccount>()] : null)
        : null;
}

/// A usage-window plan's allowances (`PlanUsage`, the Nous Portal plans).
public sealed record PlanUsage(string? Plan, IReadOnlyList<PlanUsage.Gauge> Gauges, string? PausedReason)
{
    public sealed record Gauge(string Label, string Title, double LeftFraction, DateTimeOffset? ResetsAt);

    public static PlanUsage? Parse(JsonNode? json) => json is JsonObject
        ? new PlanUsage(json.Str("plan"),
            [
                .. (json.Arr("gauges") ?? []).Select(g =>
                    g.Str("label") is { } label && g.Num("left_fraction") is { } left && double.IsFinite(left)
                        ? new Gauge(label, g.Str("title") ?? "", left,
                            g.Num("resets_at_ms") is { } ms ? DateTimeOffset.FromUnixTimeMilliseconds((long)ms) : null)
                        : null).OfType<Gauge>(),
            ], json.Str("paused_reason"))
        : null;
}

/// `ProviderLimit`: the whole login is rate-limited until a time, or only some of its models are.
public sealed record ProviderLimit(bool Account, DateTimeOffset? ResetsAt, IReadOnlyList<string> Models)
{
    public static ProviderLimit? Parse(JsonNode? json) => json.Str("scope") is { } scope
        ? new ProviderLimit(scope == "account", UsageDates.Parse(json.Str("resets_at")),
            [.. (json.Obj("models") ?? []).Select(p => p.Key).Order(StringComparer.Ordinal)])
        : null;
}

public static class UsageDates
{
    /// Python's `isoformat()`, with or without fractional seconds.
    public static DateTimeOffset? Parse(string? text) =>
        !string.IsNullOrEmpty(text) && DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal, out var d) ? d : null;

    /// "in 6d 3h", "in 2h 14m", "in 5m", "soon" (under a minute or past).
    public static string Until(DateTimeOffset date, DateTimeOffset now)
    {
        var minutes = (int)Math.Ceiling((date - now).TotalMinutes);
        if (minutes <= 0) return "soon";
        int days = minutes / 1440, hours = minutes % 1440 / 60, mins = minutes % 60;
        if (days > 0) return hours > 0 ? $"in {days}d {hours}h" : $"in {days}d";
        if (hours > 0) return mins > 0 ? $"in {hours}h {mins}m" : $"in {hours}h";
        return $"in {mins}m";
    }
}

/// Whether an allowance lasts until it fills again, at the rate it has been used this window.
public abstract record UsagePace
{
    public sealed record Steady : UsagePace;
    public sealed record RunsOut(string When) : UsagePace;
    public sealed record UsedUp : UsagePace;

    public string Text => this switch
    {
        RunsOut r => $"Runs out {r.When} at this pace",
        UsedUp => "Used up",
        _ => "On pace to last until it resets",
    };
}

/// One allowance as a bar.
public sealed record UsageGauge(string Id, string Title, double Left, string? Reset = null, DateTimeOffset? ResetsAt = null,
    double? Elapsed = null, UsagePace? Pace = null)
{
    /// "86% left"
    public string LeftText => $"{UsageLimitsModel.Percent(Left)} left";
    /// "86% left · resets in 6d 3h"
    public string Detail => string.Join(" · ", new[] { LeftText, Reset }.OfType<string>());
    public bool Low => Left < 0.1;
    public bool Warning => Left < 0.25;
}

/// One provider (or one login of a pool) on the page.
public sealed record UsageBlock(string Id, string Provider, string Title, string? Account, bool Current,
    IReadOnlyList<UsageGauge> Gauges, IReadOnlyList<string> Notes);

/// A pay-as-you-go login's credits as Hermes gives them.
public abstract record UsageBalance
{
    public sealed record Checking : UsageBalance;
    public sealed record Amount(string Value) : UsageBalance;
    public sealed record Unlimited : UsageBalance;
    public sealed record Unavailable : UsageBalance;
    public sealed record Offline : UsageBalance;
    public sealed record Failed(string Why) : UsageBalance;
}

/// One read the page makes: not made, still out, its answer, or why it failed.
public abstract record UsageRead<T>
{
    public sealed record NotAsked : UsageRead<T>;
    public sealed record Pending : UsageRead<T>;
    public sealed record Done(T Value) : UsageRead<T>;
    public sealed record Failed(string Why) : UsageRead<T>;
}

/// One pay-as-you-go login on the page.
public sealed record UsageBalanceRow(string Provider, string Title, bool Current, UsageBalance Balance, string? Note)
{
    /// "OpenRouter · This Chat"
    public string Label => Current ? $"{Title} · This Chat" : Title;
    /// No balance and nothing coming: folded under one row.
    public bool Quiet => Balance is UsageBalance.Unavailable && Note != UsageLimitsModel.BalanceNotStartedNote;

    public string Value => Balance switch
    {
        UsageBalance.Checking => UsageLimitsModel.BalanceChecking,
        UsageBalance.Amount a => a.Value,
        UsageBalance.Unlimited => UsageLimitsModel.BalanceUnlimited,
        UsageBalance.Offline => UsageLimitsModel.BalanceOffline,
        UsageBalance.Failed => UsageLimitsModel.BalanceFailed,
        _ => UsageLimitsModel.BalanceUnavailable,
    };
}

public static class UsageLimitsModel
{
    public const string Title = "Usage & Limits";
    public const string NotReported = "Not reported yet";
    public const string RefilledNote = "Refilled";
    public const string PlanLimits = "Plan Limits";
    public const string PayAsYouGo = "Pay As You Go";
    public const string ThisChat = "This Chat";
    public const string Credits = "Credits";
    public const string UsageReport = "Usage Report";
    public const string FullUsageReport = "Full Usage Report";
    public const string FullReportFooter = "Hermes’s full usage report for this chat, asked live from its provider.";
    public const string NoPlans = "None of your signed-in providers report a plan limit.";
    public const string Checking = "Checking your plans…";
    public const string CouldNotRead = "Couldn’t read your plans.";
    public const string NoReport = "No report.";
    public const string ReportFailed = "Couldn’t Get the Report";

    private static bool Passed(DateTimeOffset? date, DateTimeOffset now) => date is { } d && d <= now;

    /// Every signed-in provider that reports a plan, a window or a limit; the chat's provider first.
    public static IReadOnlyList<UsageBlock> Blocks(ModelOptions options, string currentProvider, DateTimeOffset now)
    {
        var result = new List<UsageBlock>();
        foreach (var row in options.Providers)
        {
            if (row.Authenticated == false) continue;
            var title = ProviderTitle(row);
            var current = row.Matches(currentProvider);
            var limitNotes = new List<string>();
            if (row.Limit is { } limit && !Passed(limit.ResetsAt, now))
            {
                var when = limit.ResetsAt is { } r ? $" · back {UsageDates.Until(r, now)}" : "";
                limitNotes.Add(limit.Account ? $"Rate limited{when}"
                    : $"{(limit.Models.Count == 1 ? "1 model" : $"{limit.Models.Count} models")} rate limited{when}");
            }
            if (row.Plan is { } plan)
            {
                var notes = new List<string>(limitNotes);
                if (!string.IsNullOrEmpty(plan.PausedReason)) notes.Add(plan.PausedReason);
                var gauges = plan.Gauges.Select((g, i) => MakeGauge($"{row.Slug}.plan.{i}", PlanWord(g), g.LeftFraction, g.ResetsAt, now)).ToList();
                result.Add(new UsageBlock($"{row.Slug}.plan", row.Slug, title, plan.Plan, current, gauges, notes));
            }
            else if (row.Usage?.Accounts is { Count: > 0 } accounts)
            {
                for (var i = 0; i < accounts.Count; i++)
                {
                    var account = accounts[i];
                    var notes = i == 0 ? new List<string>(limitNotes) : [];
                    switch (account.State)
                    {
                        case UsageAccountState.Unavailable: notes.Add("Signed out"); break;
                        case UsageAccountState.Unknown when account.Windows.Count == 0: notes.Add(NotReported); break;
                        case UsageAccountState.Limited when account.Windows.Count == 0 && Passed(account.ResetsAt, now):
                            notes.Add(RefilledNote); break;
                        case UsageAccountState.Limited when account.Windows.Count == 0:
                            notes.Add("Used up" + (account.ResetsAt is { } r ? $" · resets {UsageDates.Until(r, now)}" : "")); break;
                    }
                    var label = account.Label.Trim();
                    result.Add(new UsageBlock($"{row.Slug}.{account.Id}", row.Slug, title, label.Length == 0 ? $"Account {i + 1}" : label,
                        current, WindowGauges(account.Windows, $"{row.Slug}.{account.Id}", now), notes));
                }
            }
            else if (row.Usage?.Windows is { Count: > 0 } windows)
                result.Add(new UsageBlock(row.Slug, row.Slug, title, null, current, WindowGauges(windows, row.Slug, now), limitNotes));
            else if (limitNotes.Count > 0)
                result.Add(new UsageBlock(row.Slug, row.Slug, title, null, current, [], limitNotes));
        }
        return [.. result.Where(b => b.Current), .. result.Where(b => !b.Current)];
    }

    /// Whether asking again in a moment can fill something in (the gateway refreshes usage after each catalog read).
    public static bool WorthAskingAgain(ModelOptions options) => options.Providers.Any(row =>
    {
        if (row.Authenticated == false || row.Models.Count == 0) return false;
        if (row.Usage?.Accounts is { } accounts) return accounts.Any(a => a.State == UsageAccountState.Unknown && a.Windows.Count == 0);
        return row.Usage == null && row.Plan == null;
    });

    /// The ⋯ row's subtitle: the chat's provider's tightest allowance ("Weekly · 86% left"), or its rate limit.
    public static string? MenuSubtitle(ModelOptions? options, string provider, DateTimeOffset? at = null)
    {
        var now = at ?? DateTimeOffset.UtcNow;
        if (options?.Row(provider) is not { } row) return null;
        if (row.Limit is { Account: true } limit && !Passed(limit.ResetsAt, now))
            return "Rate limited" + (limit.ResetsAt is { } r ? $" · back {UsageDates.Until(r, now)}" : "");
        var gauges = Blocks(new ModelOptions([row]), provider, now).SelectMany(b => b.Gauges).ToList();
        if (gauges.Count == 0) return null;
        var tightest = gauges.MinBy(g => g.Left)!;
        return $"{tightest.Title} · {tightest.LeftText}";
    }

    private static List<UsageGauge> WindowGauges(IReadOnlyList<UsageWindow> windows, string id, DateTimeOffset now) =>
        [.. windows.Select((w, i) => MakeGauge($"{id}.{i}", w.Label, 1 - w.UsedPercent / 100, w.ResetsAt, now))];

    private static UsageGauge MakeGauge(string id, string title, double left, DateTimeOffset? resetsAt, DateTimeOffset now)
    {
        var name = title.Length == 0 ? "Allowance" : title;
        // The catalog can be hours old: a window whose reset time has passed has filled again.
        if (Passed(resetsAt, now)) return new UsageGauge(id, name, 1, RefilledNote.ToLowerInvariant());
        var clamped = Math.Max(0, Math.Min(1, double.IsFinite(left) ? left : 0));
        var (elapsed, pace) = Pace(clamped, resetsAt, WindowLength(title), now);
        return new UsageGauge(id, name, clamped, resetsAt is { } r ? $"resets {UsageDates.Until(r, now)}" : null, resetsAt, elapsed, pace);
    }

    /// A window's length from its name ("Session" 5 h, "Weekly" 7 d, "This Month" 30 d, "Today" 1 d).
    public static TimeSpan? WindowLength(string title)
    {
        var name = title.ToLowerInvariant();
        if (name.Contains("session") || name.Contains("5-hour") || name.Contains("5 hour") || name.Contains("5h")) return TimeSpan.FromHours(5);
        if (name.Contains("week")) return TimeSpan.FromDays(7);
        if (name.Contains("month")) return TimeSpan.FromDays(30);
        if (name.Contains("today") || name.Contains("daily") || name == "day") return TimeSpan.FromDays(1);
        return null;
    }

    /// How far into its window an allowance is, and whether it lasts at the rate used so far.
    public static (double? Elapsed, UsagePace? Pace) Pace(double left, DateTimeOffset? resetsAt, TimeSpan? length, DateTimeOffset now)
    {
        double? elapsed = null;
        double gone = 0, untilReset = 0;
        if (resetsAt is { } r && length is { } len)
        {
            untilReset = (r - now).TotalSeconds;
            if (untilReset > 0 && untilReset <= len.TotalSeconds * 1.05)
            {
                gone = Math.Max(0, len.TotalSeconds - untilReset);
                elapsed = Math.Min(1, gone / len.TotalSeconds);
            }
        }
        if (left <= 0.005) return (elapsed, new UsagePace.UsedUp());
        if (elapsed == null || length is not { } l) return (null, null);
        var used = 1 - left;
        if (gone < Math.Max(l.TotalSeconds * 0.1, 600) || used <= 0.02) return (elapsed, new UsagePace.Steady());
        var emptyIn = left * gone / used;
        if (emptyIn >= untilReset * 0.8) return (elapsed, new UsagePace.Steady());
        return (elapsed, new UsagePace.RunsOut(UsageDates.Until(now.AddSeconds(emptyIn), now)));
    }

    /// The allowance the page leads with: the chat's provider's tightest.
    public static (UsageBlock Block, UsageGauge Gauge)? Headline(IReadOnlyList<UsageBlock> blocks)
    {
        var pairs = blocks.Where(b => b.Current).SelectMany(b => b.Gauges.Select(g => (b, g))).ToList();
        return pairs.Count == 0 ? null : pairs.MinBy(p => p.g.Left);
    }

    /// Under the page's title: "Updated just now", "Updated 4 min ago", "Updated 9:12 AM"; "Offline · " first offline.
    public static string? Freshness(DateTimeOffset? updated, DateTimeOffset now, bool offline)
    {
        if (updated is not { } u) return offline ? "Offline" : null;
        var minutes = (int)((now - u).TotalMinutes);
        var age = minutes < 1 ? "Updated just now" : minutes < 60 ? $"Updated {minutes} min ago"
            : $"Updated {u.ToLocalTime().ToString("t", CultureInfo.CurrentCulture)}";
        return offline ? "Offline · " + age.Replace("Updated", "updated") : age;
    }

    public static string Percent(double fraction) => $"{(int)Math.Round(Math.Max(0, Math.Min(1, fraction)) * 100, MidpointRounding.AwayFromZero)}%";

    private static string PlanWord(PlanUsage.Gauge g) => g.Label switch
    {
        "day" => "Today",
        "week" => "This Week",
        "month" => "This Month",
        "top_tier" => "Large Models",
        _ => g.Title.Length == 0 ? CultureInfo.InvariantCulture.TextInfo.ToTitleCase(g.Label) : g.Title,
    };

    public static string ProviderTitle(ModelProviderRow row)
    {
        var name = ModelNames.PlainProviderName(row.Name);
        if (name.Length > 0) return name;
        var display = ModelNames.ProviderDisplayName(row.Slug);
        return display.Length == 0 ? row.Slug : display;
    }

    /// Nous credits as the gateway words them (`session.usage` `credits_lines`), blank and decoration-only lines out.
    public static IReadOnlyList<string> CreditLines(JsonNode? answer) =>
    [
        .. (answer.Arr("credits_lines") ?? answer.Obj("usage").Arr("credits_lines") ?? []).Select(J.AsString).OfType<string>()
            .Select(l => l.Trim()).Where(l => l.Any(char.IsLetterOrDigit)),
    ];

    /// One row of the chat's numbers: "Context 31%", its note and its bar (SessionInfoRows.usageRows).
    public sealed record ChatRow(string Label, string Value, string? Note = null, double? Bar = null);

    /// The chat's own numbers (`session.usage`): Context, Tokens, Cache, Speed or Calls, and Cost.
    public static IReadOnlyList<ChatRow> ChatRows(JsonNode? answer, string? price = null)
    {
        var rows = new List<ChatRow>();
        var u = answer.Obj("usage") ?? answer as JsonObject;
        if (u == null) return rows;
        long? Count(string key) => u.Num(key) is { } n && double.IsFinite(n) && n >= 0 ? (long)n : null;
        if (Count("context_max") is { } max && max > 0)
        {
            var used = Math.Min(Count("context_used") ?? 0, max);
            var percent = u.Num("context_percent") ?? (double)used / max * 100;
            var shown = (int)Math.Round(Math.Max(0, Math.Min(100, double.IsFinite(percent) ? percent : 0)), MidpointRounding.AwayFromZero);
            var note = $"{Tokens(used)} of {Tokens(max)} · {Tokens(max - used)} left";
            if (Count("compressions") is { } times && times > 0) note += $" · compressed {times}×";
            rows.Add(new ChatRow("Context", $"{(u.Bool("context_estimated") == true ? "~" : "")}{shown}%", note, shown / 100.0));
        }
        if (Count("total") is { } total && total > 0)
        {
            var sent = Count("prompt") is { } prompt && prompt > 0 ? prompt : Count("input") ?? 0;
            var parts = new List<string>();
            if (sent > 0 || (Count("output") ?? 0) > 0) parts.Add($"{Tokens(sent)} in · {Tokens(Count("output") ?? 0)} out");
            if (Count("reasoning") is { } reasoning && reasoning > 0) parts.Add($"{Tokens(reasoning)} reasoning");
            rows.Add(new ChatRow("Tokens", Tokens(total), parts.Count == 0 ? null : string.Join(" · ", parts)));
        }
        if (u.Num("cache_hit_pct") is { } hitRaw && hitRaw >= 0 && Count("prompt") is { } sentAll && sentAll > 0)
        {
            var hit = Math.Min(100, hitRaw);
            var shown = (int)Math.Round(hit, MidpointRounding.AwayFromZero);
            var parts = new List<string> { $"~{Tokens((long)Math.Round(sentAll * hit / 100))} from cache" };
            if (Count("input") is { } fresh && fresh > 0) parts.Add($"{Tokens(fresh)} new");
            rows.Add(new ChatRow("Cache", $"{shown}%", string.Join(" · ", parts), shown / 100.0));
        }
        var calls = Count("calls") is { } c && c > 0 ? (c == 1 ? "1 call" : $"{c} calls") : null;
        var latency = u.Num("avg_latency_s") is { } lat && lat > 0 ? $"{Decimal(lat, 1)} s a call" : null;
        if (u.Num("avg_tps") is { } speed && speed > 0)
        {
            var note = new[] { latency, calls }.OfType<string>().ToList();
            rows.Add(new ChatRow("Speed", $"{Decimal(speed, speed < 10 ? 1 : 0)} tokens/s", note.Count == 0 ? null : string.Join(" · ", note)));
        }
        else if (Count("calls") is { } callCount && callCount > 0) rows.Add(new ChatRow("Calls", callCount.ToString(CultureInfo.InvariantCulture), latency));
        if (u.Num("cost_usd") is { } cost && double.IsFinite(cost) && cost > 0)
        {
            string? note = null;
            if (price?.Trim() is { Length: > 0 } p)
                note = p == ModelPricesModel.Included ? "Included in your plan" : p == "Free" ? "Free model" : $"{p} per 1M";
            rows.Add(new ChatRow("Cost", "$" + cost.ToString(cost < 0.01 ? "F4" : "F2", CultureInfo.InvariantCulture), note));
        }
        return rows;
    }

    /// "82", "1.2": a point, the places given, a trailing ".0" kept off.
    public static string Decimal(double value, int places)
    {
        var text = value.ToString("F" + places, CultureInfo.InvariantCulture);
        if (places > 0 && text.EndsWith("." + new string('0', places), StringComparison.Ordinal)) text = text[..^(places + 1)];
        return text;
    }

    /// 950, "1.2K", "48.2K", "1M": token counts as Session Info writes them.
    public static string Tokens(long value)
    {
        if (value < 1000) return value.ToString(CultureInfo.InvariantCulture);
        var scaled = value / 1000.0;
        foreach (var suffix in new[] { "K", "M", "B", "T" })
        {
            if (scaled < 999.95)
            {
                var text = scaled.ToString("F1", CultureInfo.InvariantCulture);
                if (text.EndsWith(".0", StringComparison.Ordinal)) text = text[..^2];
                return text + suffix;
            }
            scaled /= 1000;
        }
        return "999T+";
    }

    // ------------------------------------------------------------------ pay as you go

    public const string BalanceChecking = "Checking…";
    public const string BalanceUnlimited = "Unlimited";
    public const string BalanceUnavailable = "Balance not available";
    public const string BalanceOffline = "Offline";
    public const string BalanceFailed = "Couldn’t check";
    public const string BalanceElsewhereNote = "Shows in a chat that uses it";
    public const string BalanceNotStartedNote = "Shows once this chat has started";
    public const string BalanceFooter = "Balances as Hermes reports them. A provider paid by API key may not report one.";
    public static readonly HashSet<string> BalanceInItsOwnChat = ["openrouter", "openai-codex"];
    public const string Nous = "nous";

    /// The balances in Hermes' /usage (`slash.exec usage`): "Credits balance: $12.34" under a provider's line; the Nous
    /// block's "Total usable: $7.50".
    public static IReadOnlyDictionary<string, UsageBalance> ReportedBalances(string text)
    {
        var result = new Dictionary<string, UsageBalance>();
        string? provider = null;
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Replace("**", "").Trim();
            if (line.Length == 0 || line.StartsWith("📈", StringComparison.Ordinal)) { provider = null; continue; }
            if (line.StartsWith("Provider: ", StringComparison.Ordinal))
            {
                provider = line["Provider: ".Length..].Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.ToLowerInvariant();
                continue;
            }
            if (provider == null || result.ContainsKey(provider)) continue;
            var label = provider == Nous ? "Total usable:" : "Credits balance:";
            if (!line.StartsWith(label, StringComparison.Ordinal)) continue;
            var value = line[label.Length..].Trim();
            if (provider != Nous && value == "unlimited") result[provider] = new UsageBalance.Unlimited();
            else if (Dollars(value) is { } amount) result[provider] = new UsageBalance.Amount(amount);
        }
        return result;
    }

    /// Nous's balance from `billing.state`.
    public static UsageBalance NousBalance(JsonNode? state)
    {
        if (state.Bool("free_tier_account") == true) return new UsageBalance.Unavailable();
        if (state.Bool("logged_in") == true)
        {
            var usage = state.Obj("usage");
            var total = usage.Bool("available") == true && usage.Str("total_spendable_display") is { } t ? Dollars(t) : null;
            var amount = total ?? (state.Str("balance_display") is { } bd ? Dollars(bd) : null)
                ?? (state.Str("balance_usd") is { } bu ? Dollars("$" + bu) : null);
            if (amount != null) return new UsageBalance.Amount(amount);
        }
        if (state.Str("error")?.Trim() is { Length: > 0 } error) return new UsageBalance.Failed(error);
        return new UsageBalance.Unavailable();
    }

    private static readonly Regex DollarsRx = new(@"^(-\$|\$-?)[0-9][0-9,]*(\.[0-9]+)?$");

    /// "$12.34", "$1,234.50", "$7"; a debt "$-1.23" turned round ("-$1.23"). Anything else is no amount.
    public static string? Dollars(string text)
    {
        var t = text.Trim();
        if (!DollarsRx.IsMatch(t)) return null;
        var digits = t.Replace("-", "").Replace("$", "");
        return (t.Contains('-') ? "-$" : "$") + digits;
    }

    /// One row per signed-in provider with no plan, window or limit to show, the chat's first, each with the best any
    /// read gave.
    public static IReadOnlyList<UsageBalanceRow> BalanceRows(ModelOptions options, IReadOnlyList<UsageBlock> blocks,
        string currentProvider, UsageRead<IReadOnlyDictionary<string, UsageBalance>> report, UsageRead<JsonNode> billing, bool offline)
    {
        var shown = blocks.Select(b => b.Provider).ToHashSet();
        var seen = new HashSet<string>();
        var reported = report is UsageRead<IReadOnlyDictionary<string, UsageBalance>>.Done d ? d.Value : new Dictionary<string, UsageBalance>();
        UsageBalance? billed = billing is UsageRead<JsonNode>.Done bd ? NousBalance(bd.Value) : null;
        var notStarted = report is UsageRead<IReadOnlyDictionary<string, UsageBalance>>.NotAsked && !offline;
        var ordered = options.Providers.Where(r => r.Matches(currentProvider)).Concat(options.Providers.Where(r => !r.Matches(currentProvider)));
        var rows = new List<UsageBalanceRow>();
        foreach (var row in ordered)
        {
            var title = ProviderTitle(row);
            if (row.Authenticated == false || shown.Contains(row.Slug) || row.Models.Count == 0 || !seen.Add(title)) continue;
            var current = row.Matches(currentProvider);
            var reads = new List<UsageBalance>();
            if (reported.TryGetValue(row.Slug, out var figure)) reads.Add(figure);
            else if ((current && BalanceInItsOwnChat.Contains(row.Slug)) || row.Slug == Nous) reads.Add(Waiting(report, offline));
            if (row.Slug == Nous && billing is not UsageRead<JsonNode>.NotAsked) reads.Add(billed ?? Waiting(billing, offline));
            var balance = reads.Count == 0 ? new UsageBalance.Unavailable() : reads.MaxBy(Rank)!;
            string? note = balance switch
            {
                UsageBalance.Failed f => f.Why,
                UsageBalance.Unavailable when !current && BalanceInItsOwnChat.Contains(row.Slug) => BalanceElsewhereNote,
                UsageBalance.Unavailable when notStarted && ((current && BalanceInItsOwnChat.Contains(row.Slug)) || (row.Slug == Nous && billed == null))
                    => BalanceNotStartedNote,
                _ => null,
            };
            rows.Add(new UsageBalanceRow(row.Slug, title, current, balance, note));
        }
        return rows;
    }

    private static UsageBalance Waiting<T>(UsageRead<T> read, bool offline) => read switch
    {
        UsageRead<T>.NotAsked => offline ? new UsageBalance.Offline() : new UsageBalance.Unavailable(),
        UsageRead<T>.Pending => offline ? new UsageBalance.Offline() : new UsageBalance.Checking(),
        UsageRead<T>.Failed f => offline ? new UsageBalance.Offline() : new UsageBalance.Failed(f.Why),
        _ => new UsageBalance.Unavailable(),
    };

    private static int Rank(UsageBalance b) => b switch
    {
        UsageBalance.Amount or UsageBalance.Unlimited => 5,
        UsageBalance.Checking => 4,
        UsageBalance.Failed => 3,
        UsageBalance.Offline => 2,
        _ => 1,
    };
}
