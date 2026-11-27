using System.Text.RegularExpressions;
using Hermes.Core.Gateways;

namespace Hermes.Core.Artifacts;

/// The Artifacts page's words (docs/spec/1x-pages.md §5.5, §5.7; HermesKit/Pages/ArtifactWords.swift): day headers
/// and row subtitles (`S/ui-pages/artifact-list.tsx:22-63`) and the empty texts (`S/fe-pages-r6.ts:63-76`). Times are
/// in `zone` (the PC's own by default).
public static class ArtifactListWords
{
    public static readonly string[] Days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
    private static readonly string[] ShortDays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    public static readonly string[] Months = ["January", "February", "March", "April", "May", "June", "July", "August",
        "September", "October", "November", "December"];
    private static readonly string[] ShortMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

    private static DateTime Local(double ms, TimeZoneInfo zone) =>
        TimeZoneInfo.ConvertTime(DateTimeOffset.FromUnixTimeMilliseconds((long)Math.Round(ms)), zone).DateTime;

    private static DateTime Local(DateTimeOffset at, TimeZoneInfo zone) => TimeZoneInfo.ConvertTime(at, zone).DateTime;

    private static int DaysAgo(DateTime date, DateTime now) => (int)(now.Date - date.Date).TotalDays;

    /// "6:20 PM" (JobWords.clock).
    public static string Clock(DateTime d)
    {
        var twelve = d.Hour % 12 == 0 ? 12 : d.Hour % 12;
        return $"{twelve}:{d.Minute:00} {(d.Hour < 12 ? "AM" : "PM")}";
    }

    /// The list's short time (App/Root/ListTime.swift): today's clock, "Yesterday", "Mon" within the week, else "Aug 2"
    /// ("Aug 2, 2025" another year).
    public static string ListTime(DateTime date, DateTime now)
    {
        var d = (int)(date.Date - now.Date).TotalDays;
        if (d >= 0) return d == 0 ? Clock(date) : DayMonth(date, now);
        if (d == -1) return "Yesterday";
        if (d > -7) return ShortDays[(int)date.DayOfWeek];
        return DayMonth(date, now);
    }

    private static string DayMonth(DateTime date, DateTime now) =>
        $"{ShortMonths[date.Month - 1]} {date.Day}" + (date.Year == now.Year ? "" : $", {date.Year}");

    /// "Today", "Yesterday", the weekday within the week, else "September 10" ("September 10, 2025").
    public static string Day(double timestamp, DateTimeOffset? now = null, TimeZoneInfo? zone = null)
    {
        if (!double.IsFinite(timestamp)) return "Earlier";
        zone ??= TimeZoneInfo.Local;
        var date = Local(timestamp, zone);
        var today = Local(now ?? DateTimeOffset.Now, zone);
        var days = DaysAgo(date, today);
        if (days <= 0) return "Today";
        if (days == 1) return "Yesterday";
        if (days < 7) return Days[(int)date.DayOfWeek];
        var @base = $"{Months[date.Month - 1]} {date.Day}";
        return date.Year == today.Year ? @base : $"{@base}, {date.Year}";
    }

    private static readonly Regex RunStamp = new(""" · (?:[A-Z][a-z]{2,8},? )?[A-Z][a-z]{2} \d{1,2}(?:, \d{4})?,? \d{1,2}:\d{2}(?:\s?[AP]M)?$""",
        RegexOptions.CultureInvariant);

    /// The row's two halves: the chat it came from ("" when untitled, a run title's own stamp removed) and when
    /// ("6:20 PM" within the week, else a date).
    public static (string Chat, string When) Parts(string sessionTitle, double timestamp, DateTimeOffset? now = null, TimeZoneInfo? zone = null)
    {
        zone ??= TimeZoneInfo.Local;
        var date = Local(timestamp, zone);
        var today = Local(now ?? DateTimeOffset.Now, zone);
        var when = DaysAgo(date, today) < 7 ? Clock(date) : ListTime(date, today);
        return (RunStamp.Replace(sessionTitle.Trim(), "", 1), when);
    }

    /// "Hermes Projects · 6:02 AM": where it came from and when.
    public static string Subtitle(string sessionTitle, double timestamp, DateTimeOffset? now = null, TimeZoneInfo? zone = null)
    {
        var (chat, when) = Parts(sessionTitle, timestamp, now, zone);
        return string.Join(" · ", new[] { chat, when }.Where(s => s.Length > 0));
    }

    /// "Today at 3:28 PM", "Yesterday at …", "Mon at …", else "Sep 30 at …" (JobWords.relativeDateTime): the image
    /// viewer's Info.
    public static string RelativeDateTime(double timestamp, DateTimeOffset? now = null, TimeZoneInfo? zone = null)
    {
        zone ??= TimeZoneInfo.Local;
        var date = Local(timestamp, zone);
        var today = Local(now ?? DateTimeOffset.Now, zone);
        var time = Clock(date);
        var d = (int)(date.Date - today.Date).TotalDays;
        if (d == 0) return $"Today at {time}";
        if (d == -1) return $"Yesterday at {time}";
        if (d == 1) return $"Tomorrow at {time}";
        if (Math.Abs(d) < 7) return $"{ShortDays[(int)date.DayOfWeek]} at {time}";
        return $"{DayMonth(date, today)} at {time}";
    }

    /// Rows grouped by day, in the order given (newest first).
    public static List<(string Day, List<ArtifactRecord> Items)> DaysOf(IEnumerable<ArtifactRecord> items, DateTimeOffset? now = null,
        TimeZoneInfo? zone = null)
    {
        var out_ = new List<(string, List<ArtifactRecord>)>();
        var at = new Dictionary<string, int>();
        foreach (var item in items)
        {
            var day = Day(item.Timestamp, now, zone);
            if (!at.TryGetValue(day, out var i)) { at[day] = i = out_.Count; out_.Add((day, [])); }
            out_[i].Item2.Add(item);
        }
        return out_;
    }

    /// What an empty list says (it looked only at recent chats).
    public static (string Title, string Description) Empty(ArtifactKind? filter, string? bot, string query)
    {
        var words = query.Trim();
        var kind = filter switch
        {
            ArtifactKind.Image => "images",
            ArtifactKind.File => "files",
            ArtifactKind.Link => "links",
            _ => "artifacts",
        };
        var Kind = char.ToUpperInvariant(kind[0]) + kind[1..];
        if (words.Length > 0)
            return ($"No Results for “{words}”", filter != null ? $"No {kind} match. Try All, or another word." : "Check the spelling, or try another word.");
        var what = filter switch
        {
            ArtifactKind.Image => "Images your bots make or share",
            ArtifactKind.File => "Files your bots create or send",
            ArtifactKind.Link => "Links from your chats",
            _ => "Images, files and links from your chats",
        };
        if (bot != null)
            return ($"No {Kind} in {bot}’s Recent Chats", $"{what} appear here. Artifacts looks through {bot}’s 50 most recent chats.");
        return ($"No {Kind} in Recent Chats", $"{what} appear here. Artifacts looks through the 50 most recent chats of each bot.");
    }
}

/// The page's other words (App/Pages/Artifacts/ArtifactsViewController.swift, PinnedArtifacts.swift).
public static class ArtifactPageWords
{
    public const string Title = "Artifacts";
    public const string SearchPlaceholder = "Search Artifacts";
    public static readonly string[] Segments = ["All", "Images", "Files", "Links"];
    public static readonly ArtifactKind?[] SegmentKinds = [null, ArtifactKind.Image, ArtifactKind.File, ArtifactKind.Link];
    public const string ImagesHeader = "Images";
    public const string AllBots = "All Bots";
    public const string CouldntLoad = "Couldn’t Load Artifacts";
    public const string CloseFile = "Close File";
    /// All shows the newest 24 pictures, then "Show All N Images".
    public const int ImagesOnAll = 24;
    /// Files and links show 100 at a time.
    public const int FileLimit = 100;

    public static string ShowAllImages(int count) => $"Show All {count} Images";
    public static string Unavailable(int count) => $"Unavailable ({count})";
    public static string UnavailableSpoken(int count) => $"Unavailable, {count}";
    public static string ShowingScope(string title) => $"Showing {title}. Change";

    public const string Open = "Open", ShowInChat = "Show in Chat", Share = "Share…", SaveAs = "Save As…",
        CopyPath = "Copy Path", CopyLink = "Copy Link", Remove = "Remove", Copied = "Copied", Removed = "Removed";

    public static string CopyAction(ArtifactKind kind) => kind == ArtifactKind.Link ? CopyLink : CopyPath;

    /// The Remove question, worded as the Delete questions are: what goes, what stays, and that it can't be undone.
    public static string RemoveTitle(string name) => name.Length == 0 ? "Remove This Artifact?" : $"Remove “{name}”?";
    public const string RemoveMessage = "It’s removed from Artifacts, Tiles and Bot Info in every chat that names it. "
        + "The file or link itself isn’t deleted. This can’t be undone.";
    public const string RemoveAction = "Remove Artifact";

    public static string Downloading(string label) => $"Downloading {label}…";
    public static string CouldntDo(string verb, string label) => $"Couldn’t {verb} {label}";
    public static string ListingFailed(IEnumerable<string> names) =>
        $"Couldn’t list {string.Join(", ", names)}’s chats, so their artifacts are missing.";
    public static string Skipped(int failed, int total) => $"Skipped {failed} of {total} recent sessions while indexing artifacts.";
    public const string RefreshFailed = "Couldn’t refresh. Showing what was saved.";

    /// The row's accessible name ("report.pdf, The 2.4 report").
    public static string TileSpoken(ArtifactRecord r, bool hosted) =>
        hosted ? $"{r.Label}, on another site, {r.SessionTitle}" : $"{r.Label}, {r.SessionTitle}";

    /// A row's kind tile (`ArtifactRowView.glyph`): the SF Symbol's name, mapped to a Segoe glyph by the app.
    public static string Glyph(ArtifactRecord record)
    {
        if (record.Kind == ArtifactKind.Link) return "link";
        if (record.Kind == ArtifactKind.Image) return "photo";
        return ArtifactFiles.FileExtension(record.Value) switch
        {
            "html" or "htm" => "safari",
            "md" or "markdown" or "mdx" or "txt" or "text" or "log" or "json" or "jsonl" or "yaml" or "yml" or "toml" or "xml"
                or "py" or "js" or "ts" or "swift" or "sh" or "rb" or "go" or "rs" or "java" or "kt" or "c" or "h" or "cpp"
                or "css" or "sql" => "doc.text",
            "pdf" => "doc.richtext",
            "csv" or "tsv" or "xlsx" or "xls" or "ods" => "tablecells",
            "mp3" or "wav" or "ogg" or "opus" or "m4a" or "flac" or "m2a" => "music.note",
            "mp4" or "mov" or "avi" or "mkv" or "webm" or "3gp" => "film",
            "zip" or "tar" or "gz" or "tgz" or "bz2" or "xz" or "7z" or "rar" => "doc.zipper",
            _ => "doc",
        };
    }

    /// The text viewer's words (ArtifactTextViewController.swift).
    public const string Preview = "Preview", Source = "Source", TryAgain = "Try Again", CouldntOpenFile = "Couldn’t Open This File",
        OpenInWindow = "Open in Window", OpenInDefaultApp = "Open in Default App", NotPlainText = "This file isn’t plain text.";
    public static string Loading(string name) => $"Loading {name}…";
    public static string CouldntOpenHere(string name) => $"Couldn’t open {name} here.";
    public const string Back = "Back";
}
