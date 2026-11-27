using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Gateways;
using Hermes.Core.Net;

namespace Hermes.Core.BotPages;

/// A Claude Code or Codex conversation found on the gateway computer (HermesKit/Pages/More/ForeignSessions.swift).
public sealed record ForeignSession(string Id, string Source, string Label, string Title, string? Cwd, DateTimeOffset? Modified,
    int TurnCount, string Excerpt)
{
    /// A row, or null when it has no usable id.
    public static ForeignSession? From(JsonNode? json)
    {
        if (json is not JsonObject || json.Get("id") is not JsonValue iv || !iv.TryGetValue(out string? raw)) return null;
        var id = raw.Trim();
        if (id.Length == 0) return null;
        var source = json.Str("source") ?? "";
        var label = json.Str("label")?.Trim() ?? "";
        var cwd = json.Str("cwd");
        var mtime = json.Num("mtime");
        return new ForeignSession(id, source, label.Length == 0 ? ForeignWords.SourceName(source) : label, json.Str("title") ?? "",
            string.IsNullOrWhiteSpace(cwd) ? null : cwd,
            mtime is { } m && double.IsFinite(m) && m > 0 ? DateTimeOffset.FromUnixTimeMilliseconds((long)(m * 1000)) : null,
            (int)Math.Max(0, json.Int("turn_count") ?? 0), json.Str("excerpt") ?? "");
    }
}

public sealed record ForeignPage(IReadOnlyList<ForeignSession> Sessions, int? NextOffset, string? Host, int Unreadable)
{
    public static ForeignPage From(JsonNode? json) => new(
        [.. (json.Arr("sessions") ?? []).Select(ForeignSession.From).OfType<ForeignSession>()],
        // A "next" that does not move forward would page for ever: only a positive offset counts.
        json.Int("next_offset") is { } n && n > 0 ? (int)n : null,
        json.Str("host") is { Length: > 0 } h ? h : null,
        (int)Math.Max(0, json.Int("unreadable") ?? 0));
}

public sealed record ForeignTurn(string Role, string Content)
{
    public bool IsUser => Role == "user";
}

public sealed record ForeignPreview(IReadOnlyList<ForeignTurn> Messages, int Total, bool Truncated, string? AlreadyImported, string? Cwd)
{
    public static ForeignPreview From(JsonNode? json)
    {
        if (json is not JsonObject) throw new PagesMessageException("The gateway’s answer could not be read.");
        var messages = (json.Arr("messages") ?? []).Select(t => t.Str("content") is { Length: > 0 } c
            ? new ForeignTurn(t.Str("role") ?? "assistant", c) : null).OfType<ForeignTurn>().ToList();
        return new(messages, (int)Math.Max(json.Int("total") ?? messages.Count, 0), json.Bool("truncated") ?? false,
            json.Str("already_imported") is { Length: > 0 } a ? a : null, json.Str("cwd") is { Length: > 0 } w ? w : null);
    }
}

public sealed record ForeignImportResult(string SessionId, bool AlreadyImported)
{
    public static ForeignImportResult From(JsonNode? json)
    {
        if (json.Str("session_id") is not { Length: > 0 } id) throw new PagesMessageException("The gateway did not say which chat it made.");
        return new(id, json.Bool("already_imported") ?? false);
    }
}

/// The three calls: `session.foreign.list`, `.preview`, `.import`. 60 s each. Hermes answers 4000 for any other key.
public sealed class ForeignSessionsApi(IPagesGateway gw)
{
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(60);
    public const int PageSize = 50;

    /// `{profile?, source?, offset?, limit?}`: `source` only for Claude Code or Codex, `offset` only past the first page.
    public static JsonObject ListParams(string? profile, string? source, int offset, int limit = PageSize)
    {
        var keys = new JsonObject { ["limit"] = limit };
        if (source is "claude" or "codex") keys["source"] = source;
        if (offset > 0) keys["offset"] = offset;
        return PagesRest.ProfileParams(profile, keys);
    }

    public static JsonObject IdParams(string? profile, string id) => PagesRest.ProfileParams(profile, new JsonObject { ["id"] = id });

    public async Task<ForeignPage> ListAsync(string? profile, string? source, int offset, int limit = PageSize, CancellationToken ct = default)
    {
        var json = await gw.CallAsync("session.foreign.list", ListParams(profile, source, offset, limit), Timeout, ct);
        if (json is not JsonObject) throw new PagesMessageException("The gateway’s answer could not be read.");
        return ForeignPage.From(json);
    }

    public async Task<ForeignPreview> PreviewAsync(string? profile, string id, CancellationToken ct = default) =>
        ForeignPreview.From(await gw.CallAsync("session.foreign.preview", IdParams(profile, id), Timeout, ct));

    public async Task<ForeignImportResult> ImportAsync(string? profile, string id, CancellationToken ct = default) =>
        ForeignImportResult.From(await gw.CallAsync("session.foreign.import", IdParams(profile, id), Timeout, ct));
}

/// Pure rules and words (`ForeignSessions`).
public static partial class ForeignWords
{
    public const string PageTitle = "Import Sessions";
    public const string Subtitle = "Bring a conversation into Hermes and pick up where you left off.";
    public const string Scanning = "Finding Conversations…";
    public const string EmptyTitle = "No Conversations Found";
    public static string EmptyText => $"Claude Code and Codex sessions on {HostWord.Phrase} will appear here.";
    public const string ScanErrorTitle = "Couldn’t Find Sessions";
    public const string ScanHelpText = "Check your connection to Hermes, then try again. An older Hermes may need an update.";
    public const string NoMatchesTitle = "No Matching Conversations";
    public const string NoMatchesText = "Try another title or folder, or load more sessions.";
    public const string Skipped = "Some logs were empty, unreadable, or too large to preview.";
    public const string LoadMore = "Load More Sessions";
    public const string SearchPrompt = "Search Loaded Sessions";
    public const string PreviewLimit = "Preview shortened for readability. The complete conversation is imported.";
    public const string CopyNotice = "Copies conversation text. Source files stay unchanged. Tool output and reasoning are not carried over.";
    public const string AlreadyHere = "This conversation is already in Hermes. Open your existing copy to continue.";
    public const string PreviewErrorTitle = "Preview Unavailable";
    public const string PreviewErrorText = "The source may have moved or changed. Refresh the list and try again.";
    public const string ImportErrorTitle = "Couldn’t Import This Conversation";
    public const string EmptyPreview = "This conversation has no messages to preview.";
    public const string OpeningPreview = "Opening Preview…";
    public const string Import = "Import";
    public const string Importing = "Importing…";
    public const string OpenInHermes = "Open in Hermes";
    public const string ImportInto = "Import Into";
    public const string Source = "Source";
    public const string ReadOnly = "This gateway is read-only, so nothing can be imported from here.";
    public static string ImportsInto(string bot) => $"Imports into {bot}.";
    public static string MoreFailed(string reason) => $"Couldn’t load more. {reason}";
    public static string LoadedCount(int n) => n == 1 ? "1 session loaded." : $"{n} sessions loaded.";
    public static string Count(int n) => n == 1 ? "1 session." : $"{n} sessions.";

    public static string SourceName(string source) => source switch
    {
        "claude" => "Claude Code",
        "codex" => "Codex",
        "" => "Another App",
        _ => CultureInfo.InvariantCulture.TextInfo.ToTitleCase(source.ToLowerInvariant()),
    };

    /// A page added to the rows already loaded: a row seen before keeps its place and takes the newer copy.
    public static IReadOnlyList<ForeignSession> Merge(IReadOnlyList<ForeignSession> loaded, IReadOnlyList<ForeignSession> page)
    {
        var seen = new HashSet<string>();
        var output = loaded.Where(r => seen.Add(r.Id)).ToList();
        var place = output.Select((r, i) => (r.Id, i)).ToDictionary(x => x.Id, x => x.i);
        foreach (var row in page)
        {
            if (place.TryGetValue(row.Id, out var i)) output[i] = row;
            else { place[row.Id] = output.Count; output.Add(row); }
        }
        return output;
    }

    /// One line of words: line breaks and runs of spaces become single spaces.
    public static string OneLine(string text) => string.Join(" ", text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    /// The row's first line: its title, else the app it came from.
    public static string Title(ForeignSession s)
    {
        var title = OneLine(s.Title);
        if (title.Length > 0) return title;
        return s.Label.Length == 0 ? "Untitled Conversation" : $"{s.Label} Conversation";
    }

    public static string Messages(int count) => count == 1 ? "1 message" : $"{count} messages";

    /// "site · 12 messages · 2 hours ago".
    public static string Detail(ForeignSession s, DateTimeOffset now)
    {
        var parts = new List<string>();
        if (s.Cwd?.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() is { } name) parts.Add(name);
        parts.Add(Messages(s.TurnCount));
        if (s.Modified is { } m) parts.Add(Relative(m, now));
        return string.Join(" · ", parts);
    }

    /// "just now", "2 hours ago", "3 days ago" (RelativeDateTimeFormatter's full style, in English).
    public static string Relative(DateTimeOffset date, DateTimeOffset now)
    {
        var s = (now - date).TotalSeconds;
        if (s < 60) return "just now";
        static string Unit(long n, string one) => n == 1 ? $"1 {one} ago" : $"{n} {one}s ago";
        if (s < 3600) return Unit((long)(s / 60), "minute");
        if (s < 86400) return Unit((long)(s / 3600), "hour");
        if (s < 7 * 86400) return Unit((long)(s / 86400), "day");
        if (s < 30 * 86400) return Unit((long)(s / (7 * 86400)), "week");
        if (s < 365 * 86400) return Unit((long)(s / (30 * 86400)), "month");
        return Unit((long)(s / (365 * 86400)), "year");
    }

    /// The row's last lines: the excerpt on one line; null when there is none.
    public static string? Excerpt(ForeignSession s)
    {
        var text = OneLine(s.Excerpt);
        return text.Length == 0 ? null : text.Length > 400 ? text[..400] : text;
    }

    /// What a screen reader says for a row.
    public static string Spoken(ForeignSession s, DateTimeOffset now) =>
        string.Join(", ", new[] { Title(s), s.Label, Detail(s, now) }.Where(x => x.Length > 0));

    /// Search over the loaded rows: title, folder and excerpt, any case.
    public static IReadOnlyList<ForeignSession> Filter(IReadOnlyList<ForeignSession> rows, string query)
    {
        var needle = query.Trim().ToLowerInvariant();
        if (needle.Length == 0) return rows;
        return [.. rows.Where(r => $"{r.Title} {r.Cwd ?? ""} {r.Excerpt}".ToLowerInvariant().Contains(needle))];
    }

    [GeneratedRegex(@"^\d{1,3}(\.\d{1,3}){3}$")]
    private static partial Regex Ip();

    [GeneratedRegex(@"^(.+?)s-(Mac-mini|Mac-Studio|Mac-Pro|MacBook|iMac|Mac)\b", RegexOptions.IgnoreCase)]
    private static partial Regex Possessive();

    /// "Studio’s Mac mini" for "Studios-Mac-mini.local"; an address is left as it is.
    public static string FriendlyHost(string? host)
    {
        var name = (host ?? "").Trim();
        foreach (var suffix in new[] { ".local", ".lan", ".home", ".localdomain" })
            if (name.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) { name = name[..^suffix.Length]; break; }
        if (name.Length == 0 || Ip().IsMatch(name)) return name;
        var shortName = name;
        if (name.Contains('.') && !name.Any(char.IsWhiteSpace)) shortName = name.Split('.')[0];
        shortName = Possessive().Replace(shortName, "$1’s-$2");
        return string.Join(" ", shortName.Split('-', StringSplitOptions.RemoveEmptyEntries)).Trim();
    }

    public static string ReadingFrom(string? host)
    {
        var name = FriendlyHost(host);
        return $"Reading from {(name.Length == 0 ? HostWord.Phrase : name)}";
    }

    /// Why the list could not be read, from the error itself (`importScanHelp`).
    public static string ScanHelp(Exception e)
    {
        if (PagesRest.IsMissingRoute(e)) return PagesRest.OlderHermes;
        if (PagesRest.Status(e) is 401 or 403) return ScanHelp(PagesRest.Status(e)!.Value.ToString(CultureInfo.InvariantCulture));
        if (PagesRest.IsSlowAnswer(e)) return ScanHelp("timed out");
        if (e is GatewayException { Code: "offline" }) return ScanHelp("could not connect");
        return ScanHelp(PagesRest.Reason(e));
    }

    public static string ScanHelp(string message)
    {
        bool Has(string pattern) => Regex.IsMatch(message, pattern, RegexOptions.IgnoreCase);
        if (Has(@"\b(?:401|403)\b|authentication expired|rejected|sign in again"))
            return "Your sign-in to Hermes has expired or was rejected. Sign in again, then try again.";
        if (Has(@"\b404\b")) return $"This Hermes doesn’t offer importing sessions yet. Update Hermes on {HostWord.UpdateTarget} to use it.";
        if (Has(@"timed? ?out|timeout|took too long|\b(?:408|504)\b"))
            return $"Reading the Claude Code and Codex logs on {HostWord.Phrase} took too long. Try again in a moment.";
        if (Has("offline|could not connect|couldn’t connect|can’t reach|connection was lost|not connected|network|failed to fetch|load failed"))
            return $"Hermes HQ can’t reach {HostWord.Phrase}. Check the connection, then try again.";
        var detail = OneLine(message);
        return detail.Length > 0 && detail.Length <= 160 ? $"{ScanHelpText} ({detail})" : ScanHelpText;
    }

    [GeneratedRegex(@"^\[ran tool: ([^\]]*)\]$")]
    private static partial Regex ToolLine();

    /// A preview turn's text: runs of "[ran tool: x]" lines become one "Used x (2×) and y" line.
    public static string PreviewText(string text)
    {
        var output = new List<string>();
        var run = new List<(string Name, int Count)>();
        void Flush()
        {
            if (run.Count == 0) return;
            var names = run.Select(r => r.Count > 1 ? $"{r.Name} ({r.Count}×)" : r.Name).ToList();
            output.Add("Used " + JoinList(names));
            run.Clear();
        }
        foreach (var line in text.Split('\n'))
        {
            var trimmed = line.Trim();
            if (ToolLine().Match(trimmed) is { Success: true } m)
            {
                var name = m.Groups[1].Value.Trim();
                var i = run.FindIndex(r => r.Name == name);
                if (i >= 0) run[i] = (name, run[i].Count + 1); else run.Add((name, 1));
            }
            else if (trimmed.Length == 0 && run.Count > 0) continue;   // blank lines between tool lines belong to the run
            else { Flush(); output.Add(line); }
        }
        Flush();
        return string.Join("\n", output);
    }

    /// ListFormatter in English: "a", "a and b", "a, b, and c".
    public static string JoinList(IReadOnlyList<string> items) => items.Count switch
    {
        0 => "",
        1 => items[0],
        2 => $"{items[0]} and {items[1]}",
        _ => string.Join(", ", items.Take(items.Count - 1)) + ", and " + items[^1],
    };

    /// Who said a turn: "You", or the app the conversation came from.
    public static string Speaker(ForeignTurn t, string label) => t.IsUser ? "You" : label.Length == 0 ? "Assistant" : label;
}

/// The list's state: which source and bot, the rows loaded so far, paging, the first read's outcome
/// (`ForeignSessionsStore`). Changed is raised on the caller's synchronization context.
public sealed class ForeignSessionsStore(IPagesGateway gw, string profile)
{
    public enum SourceKind { All, Claude, Codex }

    public static string SourceTitle(SourceKind s) => s switch { SourceKind.All => "All", SourceKind.Claude => "Claude Code", _ => "Codex" };
    private static string? Wire(SourceKind s) => s switch { SourceKind.Claude => "claude", SourceKind.Codex => "codex", _ => null };

    public abstract record Phase
    {
        public sealed record Loading : Phase;
        public sealed record Loaded : Phase;
        public sealed record Failed(string Help, string Reason) : Phase;
    }

    private readonly ForeignSessionsApi _api = new(gw);
    public Phase Current { get; private set; } = new Phase.Loading();
    public IReadOnlyList<ForeignSession> Rows { get; private set; } = [];
    public int? NextOffset { get; private set; }
    public string? Host { get; private set; }
    public int Unreadable { get; private set; }
    public bool LoadingMore { get; private set; }
    public string? MoreError { get; private set; }
    public SourceKind Source { get; private set; } = SourceKind.All;
    public string Profile { get; private set; } = profile;
    public string Query { get; set; } = "";
    public event Action? Changed;
    /// The first read's result (null = it answered).
    public event Action<Exception?>? FirstRead;

    private int _generation;
    private Task _task = Task.CompletedTask;

    public IReadOnlyList<ForeignSession> Visible => ForeignWords.Filter(Rows, Query);
    public bool HasMore => NextOffset != null;
    public bool Searching => Query.Trim().Length > 0;

    /// Reads the first page again. Rows on screen stay until the answer when `keeping`.
    public Task Reload(bool keeping = false)
    {
        var mine = ++_generation;
        LoadingMore = false;
        MoreError = null;
        if (!keeping || Rows.Count == 0) { Current = new Phase.Loading(); Rows = []; NextOffset = null; Unreadable = 0; }
        Changed?.Invoke();
        var p = Profile; var source = Wire(Source);
        return _task = Run();

        async Task Run()
        {
            try
            {
                var page = await _api.ListAsync(p, source, 0);
                if (_generation != mine) return;
                Rows = ForeignWords.Merge([], page.Sessions);
                NextOffset = page.NextOffset;
                Host = page.Host ?? Host;
                Unreadable = page.Unreadable;
                Current = new Phase.Loaded();
                FirstRead?.Invoke(null);
            }
            catch (Exception e)
            {
                if (_generation != mine) return;
                FirstRead?.Invoke(e);
                if (keeping && Rows.Count > 0) Current = new Phase.Loaded();
                else { Rows = []; NextOffset = null; Current = new Phase.Failed(ForeignWords.ScanHelp(e), PagesRest.Reason(e)); }
            }
            Changed?.Invoke();
        }
    }

    /// Waits for the read in flight.
    public Task Settle() => _task;

    /// The next page. A second click while one is on its way does nothing.
    public Task LoadMore()
    {
        if (Current is not Phase.Loaded || LoadingMore || NextOffset is not { } offset) return Task.CompletedTask;
        LoadingMore = true;
        MoreError = null;
        Changed?.Invoke();
        var mine = _generation; var p = Profile; var source = Wire(Source);
        return _task = Run();

        async Task Run()
        {
            try
            {
                var page = await _api.ListAsync(p, source, offset);
                if (_generation != mine) return;
                var before = Rows.Count;
                Rows = ForeignWords.Merge(Rows, page.Sessions);
                NextOffset = page.NextOffset is { } n && n > offset ? n : null;
                if (Rows.Count == before && page.Sessions.Count == 0) NextOffset = null;
                Unreadable += page.Unreadable;
            }
            catch (Exception e)
            {
                if (_generation != mine) return;
                if (e is not OperationCanceledException) MoreError = PagesRest.Reason(e);
            }
            LoadingMore = false;
            Changed?.Invoke();
        }
    }

    public Task SetSource(SourceKind next)
    {
        if (next == Source) return Task.CompletedTask;
        Source = next;
        return Reload();
    }

    public Task SetProfile(string next)
    {
        if (next == Profile) return Task.CompletedTask;
        Profile = next;
        return Reload();
    }

    public Task<ForeignPreview> PreviewAsync(ForeignSession s) => _api.PreviewAsync(Profile, s.Id);
    public Task<ForeignImportResult> ImportAsync(ForeignSession s) => _api.ImportAsync(Profile, s.Id);
}
