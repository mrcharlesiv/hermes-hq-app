using Hermes.Core.Model;
using Microsoft.UI.Xaml;

namespace HermesHQ.ViewModels;

public sealed class BotItem(Bot bot)
{
    public Bot Bot { get; } = bot;
    public string Name => Bot.DisplayName;
    public string Subtitle => Bot.Canonical?.Preview ?? Bot.Description ?? Bot.Model ?? "";
    public string When => Format.Relative(Bot.LastActive);
    public Visibility PinVisibility => Bot.Pinned ? Visibility.Visible : Visibility.Collapsed;
}

public sealed class SessionItem(SessionRow row)
{
    public SessionRow Row { get; } = row;
    public string Title => Row.Title;
    public string Subtitle => Row.Profile == "default" ? Row.Preview ?? "" : $"{Bot.TitleCase(Row.Profile)} · {Row.Preview}";
    public string When => Format.Relative(Row.LastActive);
    public Visibility UnreadVisibility => Row.Unread ? Visibility.Visible : Visibility.Collapsed;
    public string BotName => Row.Profile == "default" ? "Hermes" : Bot.TitleCase(Row.Profile);
}

/// The Sessions list's day groups: Pinned, Today, Yesterday, This Week, then by month.
public sealed class SessionGroup(string title, IEnumerable<SessionItem> items) : List<SessionItem>(items)
{
    public string Title { get; } = title;

    public static List<SessionGroup> ByDay(IEnumerable<SessionItem> rows)
    {
        var list = rows.ToList();
        var groups = new List<SessionGroup>();
        var pinned = list.Where(r => r.Row.Pinned).ToList();
        if (pinned.Count > 0) groups.Add(new SessionGroup("Pinned", pinned));
        foreach (var g in list.Where(r => !r.Row.Pinned)
                     .OrderByDescending(r => r.Row.LastActive ?? DateTimeOffset.MinValue)
                     .GroupBy(r => Label(r.Row.LastActive)))
            groups.Add(new SessionGroup(g.Key, g));
        return groups;
    }

    public static string Label(DateTimeOffset? when)
    {
        if (when is not { } w) return "Older";
        var day = w.ToLocalTime().Date;
        var today = DateTime.Today;
        if (day == today) return "Today";
        if (day == today.AddDays(-1)) return "Yesterday";
        if (day > today.AddDays(-7)) return "This Week";
        return day.Year == today.Year ? day.ToString("MMMM") : day.ToString("MMMM yyyy");
    }
}

public static class Format
{
    /// "now", "5m", "3h", "Tue", "Oct 4": the list's right-hand time, like the iPhone app's.
    public static string Relative(DateTimeOffset? when)
    {
        if (when is not { } w) return "";
        var local = w.ToLocalTime();
        var age = DateTimeOffset.Now - local;
        if (age < TimeSpan.FromMinutes(1)) return "now";
        if (age < TimeSpan.FromHours(1)) return $"{(int)age.TotalMinutes}m";
        if (local.Date == DateTime.Today) return local.ToString("t");
        if (age < TimeSpan.FromDays(6)) return local.ToString("ddd");
        return local.Year == DateTime.Today.Year ? local.ToString("MMM d") : local.ToString("MMM d, yyyy");
    }
}
