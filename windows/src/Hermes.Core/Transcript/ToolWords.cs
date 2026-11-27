using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Hermes.Core.Transcripts;

/// Tool row wording (HermesKit/Chat/Transcript/ToolWords.swift; docs/spec/3x-transcript.md §5.1): sizes in words,
/// "Checked how to use …", background processes, failed tools as prose, one-line shell output, heredoc scripts.
public static class ToolWords
{
    // MARK: Sizes in words (r1-47)

    /// "10 KB output", as iOS counts file sizes (1000-based).
    public static string ByteCountLabel(double bytes, string what = "output")
    {
        if (!double.IsFinite(bytes) || bytes < 0) return "";
        string[] units = ["bytes", "KB", "MB", "GB"];
        var value = bytes;
        var unit = 0;
        while (value >= 1000 && unit < units.Length - 1) { value /= 1000; unit++; }
        string shown;
        if (unit == 0) shown = ((long)Math.Round(value, MidpointRounding.AwayFromZero)).ToString(CultureInfo.InvariantCulture);
        else if (value < 10)
        {
            var one = value.ToString("0.0", CultureInfo.InvariantCulture);
            shown = one.EndsWith(".0") ? one[..^2] : one;
        }
        else shown = ((long)Math.Round(value, MidpointRounding.AwayFromZero)).ToString(CultureInfo.InvariantCulture);
        return $"{shown} {units[unit]} {what}";
    }

    /// A finished row's size note: nil under 1 KB and for a call with no output.
    public static string? OutputSize(string? stdout, string? stderr)
    {
        var o = Utf8(stdout);
        var e = Utf8(stderr);
        if (o == 0 && e >= 1000) return ByteCountLabel(e, "error output");
        return o < 1000 ? null : ByteCountLabel(o);
    }

    private static int Utf8(string? s) => s == null ? 0 : System.Text.Encoding.UTF8.GetByteCount(s);

    /// The note at the trailing edge of a finished tool row: one short line of shell output (≤ 24 characters), else
    /// the output's size in words. nil for a failed call, a short answer, and a line that is JSON.
    public static string? RowNote(string name, string? stdout, string? stderr, string? detail, double? bytes, bool failed)
    {
        if (failed) return null;
        if (name == "terminal" && OneLineOutput(stdout) is { } line && line.Length <= 24 && !LooksLikeJson(line)) return line;
        if (bytes is { } b && b >= 1000) return ByteCountLabel(b);
        return OutputSize(stdout ?? detail, stderr);
    }

    public static bool LooksLikeJson(string line)
    {
        var t = line.TrimStart(' ', '\t');
        return t.Length > 0 && (t[0] == '{' || t[0] == '[');
    }

    // MARK: Checked how to use <tool>, background processes (r5-98)

    public static readonly IReadOnlyDictionary<string, string> Process = new Dictionary<string, string>
    {
        ["log"] = "Checked a background process’s log", ["kill"] = "Stopped a background process", ["stop"] = "Stopped a background process",
        ["poll"] = "Checked a background process", ["status"] = "Checked a background process", ["wait"] = "Waited for a background process",
        ["list"] = "Listed background processes", ["write"] = "Sent input to a background process", ["submit"] = "Sent input to a background process",
        ["input"] = "Sent input to a background process", ["close"] = "Closed a background process’s input",
        ["handoff"] = "Handed off a background process", ["spawn"] = "Started a background process", ["start"] = "Started a background process",
    };

    private static readonly Regex McpPrefix = new(@"^mcp__([^_]+(?:_[^_]+)*)__");
    private static readonly Regex ConnectorPrefix = new(@"^connectors__[^_]+__");
    private static readonly Regex Underscores = new(@"[_-]+");

    /// "web_search" → "web search".
    public static string Words(string name)
    {
        var o = McpPrefix.Replace(name, "$1 ", 1);
        o = ConnectorPrefix.Replace(o, "", 1);
        o = Underscores.Replace(o, " ");
        return o.Trim();
    }

    /// The row's title for the calls the gateway's own labels word badly; nil keeps the usual wording.
    public static string? PlainLabel(string name, IReadOnlyDictionary<string, JsonNode?> args, string preview = "")
    {
        var tool = name.Trim();
        if (tool == "tool_describe")
        {
            var names = DescribedNames(args);
            // "Looked up web search" read as if a web search ran: it is the bot reading how to use the tool.
            if (names.Count == 0) return "Checked how to use a tool";
            return names.Count == 1 ? $"Checked how to use {Words(names[0])}" : $"Checked how to use {names.Count} tools";
        }
        if (tool is "process_manage" or "process")
        {
            var action = (ToolArgs.Str(args, "action") ?? preview.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "")
                .ToLowerInvariant();
            return Process.TryGetValue(action, out var w) ? w : "Managed a background process";
        }
        return null;
    }

    internal static List<string> DescribedNames(IReadOnlyDictionary<string, JsonNode?> args)
    {
        JsonNode? raw = null;
        foreach (var k in new[] { "names", "name", "tool", "tools", "tool_name" })
            if (args.TryGetValue(k, out var v) && v != null) { raw = v; break; }
        var names = raw switch
        {
            JsonArray a => a.Select(J.AsString).Where(s => s != null).Select(s => s!).ToList(),
            JsonValue v when v.TryGetValue(out string? s) => [s],
            _ => new List<string>(),
        };
        return names.Where(n => n.Trim().Length > 0).ToList();
    }

    // MARK: Failed tools (r4-94)

    private static readonly Regex StatusLine = new(@"^\s*(?:[-*•]\s*)?(?:error|success|ok|status|message|exit_?code)\s*:", RegexOptions.IgnoreCase);
    private static readonly Regex StatusOnly = new(@"^\s*(?:[-*•]\s*)?(?:success|ok|status|exit_?code)\s*:", RegexOptions.IgnoreCase);
    private static readonly Regex AlreadyFailed = new(@"^(?:failed|couldn[’']t|could not|error)\b", RegexOptions.IgnoreCase);
    private static readonly Regex Marks = new(@"[`*_]");
    private static readonly Regex Spaces = new(@"\s+");
    private static readonly Regex ErrorKey = new(@"^\s*(?:[-*•]\s*)?(?:error|message)\s*:\s*", RegexOptions.IgnoreCase);

    private static string Plain(string text) => Spaces.Replace(Marks.Replace(text, ""), " ").Trim().ToLowerInvariant();

    /// A failed tool's explanation without the key/value dump that repeats it.
    public static string ToolErrorBody(string summary, string body) =>
        string.Join("\n", body.Split('\n').Where(l => l.Trim().Length > 0 && !StatusLine.IsMatch(l) && Plain(l) != Plain(summary))).Trim();

    /// "Failed: Scheduling create", unless the title already says so.
    public static string FailedToolTitle(string title) => AlreadyFailed.IsMatch(title.Trim()) ? title : $"Failed: {title}";

    /// A failed tool as prose: the error's own words; "This step didn’t finish." when nothing is left.
    public static string FailedProse(string? errorText, string summary = "")
    {
        var raw = (errorText ?? "").Trim();
        if (raw.Length == 0) return "This step didn’t finish.";
        if (raw.StartsWith('{') && J.Parse(raw) is JsonObject o)
        {
            foreach (var key in new[] { "error", "message", "detail", "stderr" })
                if (o.Str(key) is { } words && words.Trim().Length > 0) return words.Trim();
            return "This step didn’t finish.";
        }
        var lines = raw.Split('\n', StringSplitOptions.RemoveEmptyEntries).Where(l => !StatusOnly.IsMatch(l))
            .Select(l => ErrorKey.Replace(l, "", 1)).Where(l => l.Trim().Length > 0 && Plain(l) != Plain(summary));
        var body = string.Join("\n", lines).Trim();
        return body.Length == 0 ? "This step didn’t finish." : body;
    }

    // MARK: One-line shell output (r5-99)

    public static string? OneLineOutput(string? stdout)
    {
        var t = stdout?.Trim();
        if (string.IsNullOrEmpty(t) || t.Length > 120 || t.Contains('\n') || t.Contains('\r')) return null;
        return t;
    }

    // MARK: Heredoc scripts (r6-13)

    public static readonly HashSet<string> Interpreters =
        ["python", "python3", "python2", "node", "bash", "sh", "zsh", "ruby", "perl", "php", "osascript", "deno", "bun", "lua",
         "Rscript", "swift", "sqlite3", "psql", "mysql", "jq"];
    private static readonly Regex Heredoc = new(@"(?<!<)<<(-?)\s*(['""]?)([A-Za-z_][\w-]*)\2");
    private static readonly Regex Assignment = new(@"^[A-Za-z_]\w*=");
    private static readonly Regex LeadingTabs = new(@"^\t+");

    /// The script with each heredoc's body folded into its command.
    public static string CollapseHeredocs(string text)
    {
        if (!Heredoc.IsMatch(text)) return text;
        var output = new List<string>();
        string? end = null;
        var tabs = false;
        foreach (var line in text.Split('\n'))
        {
            if (end != null)
            {
                var candidate = tabs ? LeadingTabs.Replace(line, "") : line;
                if (candidate.Trim(' ', '\t') == end) end = null;
                continue;
            }
            var m = Heredoc.Match(line);
            if (!m.Success) { output.Add(line); continue; }
            end = m.Groups[3].Value;
            tabs = m.Groups[1].Value == "-";
            var at0 = line.IndexOf(m.Value, StringComparison.Ordinal);
            var rest = line[..at0] + " " + line[(at0 + m.Value.Length)..];
            rest = Spaces.Replace(rest, " ").Trim(' ', '\t');
            var words = rest.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            var at = 0;
            while (at < words.Length && Assignment.IsMatch(words[at])) at++;
            var head = at < words.Length ? words[at].Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? "" : "";
            output.Add(Interpreters.Contains(head) ? $"{head} script" : rest);
        }
        return string.Join("\n", output);
    }

    /// A segment that only sets up the script: assignments with no command, or a comment.
    public static bool SetupSegment(IReadOnlyList<string> words)
    {
        if (words.Count == 0) return false;
        return words[0].StartsWith('#') || words.All(w => Assignment.IsMatch(w));
    }

    /// The command a shell row is titled by: heredocs folded, setup-only lines dropped.
    public static string ScriptTitleSource(string command)
    {
        var folded = CollapseHeredocs(command);
        var lines = folded.Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Where(l => !SetupSegment(l.Split(' ', StringSplitOptions.RemoveEmptyEntries))).ToList();
        return lines.Count == 0 ? folded : string.Join("\n", lines);
    }
}

/// A call's arguments as a key → value map (ChatRunSummary.args, ToolArgs.parse/scan): parsed in full up to 8 KB; a
/// bigger or cut-short text gives the keys the wording reads by a cheap scan.
public static class ToolArgs
{
    public const int ParseLimit = 8_192;
    private static readonly IReadOnlyDictionary<string, JsonNode?> Empty = new Dictionary<string, JsonNode?>();

    public static IReadOnlyDictionary<string, JsonNode?> Of(Hermes.Core.Model.ToolCall call) => Parse(call.ArgsJson ?? call.ArgsText);

    public static IReadOnlyDictionary<string, JsonNode?> Parse(string? text)
    {
        if (string.IsNullOrEmpty(text)) return Empty;
        if (System.Text.Encoding.UTF8.GetByteCount(text) > ParseLimit) return ScanHead(text);
        if (J.Parse(text) is JsonObject o) return o.ToDictionary(kv => kv.Key, kv => kv.Value);
        return Scan(text);
    }

    public static string? Str(IReadOnlyDictionary<string, JsonNode?> args, string key) =>
        args.TryGetValue(key, out var v) ? J.AsString(v) : null;

    /// `firstString`: the first of `keys` with a non-blank string value, trimmed; "" when none.
    public static string FirstString(IReadOnlyDictionary<string, JsonNode?> args, params string[] keys)
    {
        foreach (var k in keys)
            if (args.TryGetValue(k, out var v) && v is JsonValue jv && jv.TryGetValue(out string? s) && s.Trim().Length > 0)
                return s.Trim();
        return "";
    }

    private static readonly Regex StringField = new(
        @"""(path|file|filepath|file_path|command|code|query|search_term|url|name)""\s*:\s*""((?:[^""\\]|\\.){0,4096})""");
    private static readonly Regex UrlsField = new(@"""urls""\s*:\s*\[([^\]]{0,6000})");
    private static readonly Regex StringLiteral = new(@"""((?:[^""\\]|\\.)*)""");

    /// ChatRunSummary.scannedArgs: the wording's keys from the first 8 KB of a big argument object.
    private static IReadOnlyDictionary<string, JsonNode?> ScanHead(string text)
    {
        var bytes = System.Text.Encoding.UTF8.GetBytes(text);
        var head = System.Text.Encoding.UTF8.GetString(bytes, 0, Math.Min(bytes.Length, ParseLimit));
        var o = new Dictionary<string, JsonNode?>();
        foreach (Match m in StringField.Matches(head))
            o.TryAdd(m.Groups[1].Value, JsonValue.Create(Unescape(m.Groups[2].Value)));
        if (UrlsField.Match(head) is { Success: true } u)
            o["urls"] = new JsonArray([.. StringLiteral.Matches(u.Groups[1].Value).Select(x => (JsonNode?)JsonValue.Create(Unescape(x.Groups[1].Value)))]);
        return o;
    }

    private static readonly Regex Field = new(
        @"""(path|command|code|pattern|query|url|prompt|goal|text|name|ref|question|category|action|file|file_path|aspect_ratio)""\s*:\s*""((?:[^""\\]|\\.)*)(""|\\?$)");
    private static readonly Regex UrlsOne = new(@"""urls""\s*:\s*\[\s*""((?:[^""\\]|\\.)*)(""|\\?$)");

    /// ToolArgs.scan: the first value of each key the lines read from (possibly cut) JSON.
    public static IReadOnlyDictionary<string, JsonNode?> Scan(string text)
    {
        var o = new Dictionary<string, JsonNode?>();
        foreach (Match m in Field.Matches(text)) o.TryAdd(m.Groups[1].Value, JsonValue.Create(Unescape(m.Groups[2].Value)));
        if (UrlsOne.Match(text) is { Success: true } u) o["urls"] = new JsonArray(JsonValue.Create(Unescape(u.Groups[1].Value)));
        return o;
    }

    private static string Unescape(string raw)
    {
        if (!raw.Contains('\\')) return raw;
        var body = raw;
        if (body.EndsWith('\\') && !body.EndsWith("\\\\")) body = body[..^1];
        try { return JsonSerializer.Deserialize<string>("\"" + body + "\"") ?? body; }
        catch (JsonException) { return body.Replace("\\n", "\n").Replace("\\\"", "\""); }
    }
}
