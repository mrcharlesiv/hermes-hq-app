using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Model;

namespace Hermes.Core.Transcripts;

/// One tool call as a line, worded the way Hermes words its own Telegram progress lines (HermesKit/Activity/
/// ToolLine.swift; R:src/ui-chat/tool-line.ts): the registry emoji, a verb and the call's main argument; a terminal
/// command or code apart as Code. Used by Bubbles, In Header and the Steps list.
public sealed record ToolLine(string Emoji, string Text, string? Code = null)
{
    /// "💻 npm test" (the code's first line) or "🔍 Searching the web for …": the In Header status words.
    public string StatusWords => Code?.Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() is { } first
        ? $"{Emoji} {first.Trim()}" : $"{Emoji} {Text}";

    public string CopyText => Code != null ? $"{Emoji} {Text}\n{Code}" : $"{Emoji} {Text}";
}

public static class ToolLines
{
    public static readonly IReadOnlyDictionary<string, string> Emoji = new Dictionary<string, string>
    {
        ["terminal"] = "💻", ["execute_code"] = "🐍", ["process_manage"] = "⚙️", ["read_terminal"] = "🖥️", ["close_terminal"] = "🖥️",
        ["read_file"] = "📖", ["write_file"] = "✍️", ["patch"] = "🔧", ["search_files"] = "🔎",
        ["web_search"] = "🔍", ["web_extract"] = "📄", ["x_search"] = "🐦",
        ["browser_navigate"] = "🌐", ["browser_snapshot"] = "📸", ["browser_click"] = "👆", ["browser_type"] = "⌨️", ["browser_press"] = "⌨️",
        ["browser_scroll"] = "📜", ["browser_back"] = "◀️", ["browser_get_images"] = "🖼️", ["browser_vision"] = "👁️", ["browser_console"] = "🖥️",
        ["browser_exec"] = "🌐", ["browser_cdp"] = "🧪", ["browser_dialog"] = "💬",
        ["image_generate"] = "🎨", ["video_generate"] = "🎬", ["video_analyze"] = "🎬", ["vision_analyze"] = "👁️", ["desktop_preview"] = "🖼️",
        ["skill_view"] = "📚", ["skills_list"] = "📚", ["skill_manage"] = "📝", ["delegate_task"] = "🔀", ["cronjob_manage"] = "⏰",
        ["clarify"] = "❓", ["memory"] = "🧠", ["todo_list"] = "📋", ["todo"] = "📋", ["react_to_message"] = "💛",
        ["message_agent"] = "💬", ["tool_describe"] = "📖", ["hermes_tool_search"] = "🔎",
    };

    public static readonly IReadOnlyDictionary<string, string> Verb = new Dictionary<string, string>
    {
        ["web_search"] = "Searching the web", ["web_extract"] = "Reading", ["browser_navigate"] = "Browsing", ["browser_click"] = "Clicking",
        ["browser_type"] = "Typing", ["read_file"] = "Reading", ["write_file"] = "Writing", ["patch"] = "Editing", ["search_files"] = "Searching files",
        ["terminal"] = "Running", ["execute_code"] = "Running code", ["image_generate"] = "Generating image", ["video_generate"] = "Generating video",
        ["text_to_speech"] = "Generating speech", ["vision_analyze"] = "Looking at the image", ["session_search"] = "Searching past sessions",
        ["skill_view"] = "Reading skill", ["skills_list"] = "Listing skills", ["skill_manage"] = "Updating skill", ["delegate_task"] = "Delegating",
        ["cronjob_manage"] = "Scheduling", ["clarify"] = "Asking", ["memory"] = "Updating memory", ["todo_list"] = "Updating tasks",
        ["message_agent"] = "Messaging", ["tool_describe"] = "Checking tool instructions", ["hermes_tool_search"] = "Finding the right tool",
    };

    /// Each verb above as done ("Read big.txt", not "Reading big.txt", in the Steps list and the Mac inspector).
    public static readonly IReadOnlyDictionary<string, string> PastVerb = new Dictionary<string, string>
    {
        ["Searching the web"] = "Searched the web", ["Reading"] = "Read", ["Browsing"] = "Browsed", ["Clicking"] = "Clicked",
        ["Typing"] = "Typed", ["Writing"] = "Wrote", ["Editing"] = "Edited", ["Searching files"] = "Searched files", ["Running"] = "Ran",
        ["Running code"] = "Ran code", ["Generating image"] = "Generated image", ["Generating video"] = "Generated video",
        ["Generating speech"] = "Generated speech", ["Looking at the image"] = "Looked at the image",
        ["Searching past sessions"] = "Searched past sessions", ["Reading skill"] = "Read skill", ["Listing skills"] = "Listed skills",
        ["Updating skill"] = "Updated skill", ["Delegating"] = "Delegated", ["Scheduling"] = "Scheduled", ["Asking"] = "Asked",
        ["Updating memory"] = "Updated memory", ["Updating tasks"] = "Updated tasks", ["Messaging"] = "Messaged",
        ["Checking tool instructions"] = "Checked tool instructions", ["Finding the right tool"] = "Found the right tool",
    };

    /// `text` with its leading verb put in the past; text with no known verb comes back as it is.
    public static string Done(string text)
    {
        foreach (var present in PastVerb.Keys.OrderByDescending(k => k.Length))
        {
            if (!text.StartsWith(present, StringComparison.Ordinal)) continue;
            var rest = text[present.Length..];
            if (rest.Length > 0 && rest[0] != ' ') continue;
            return PastVerb[present] + rest;
        }
        return text;
    }

    public static readonly IReadOnlySet<string> NoPreview = new HashSet<string>(["skills_list", "session_search", "memory", "todo_list", "tool_describe", "hermes_tool_search"]);
    public static readonly IReadOnlySet<string> ForConnector = new HashSet<string>(["web_search", "search_files"]);
    private static readonly IReadOnlyDictionary<string, string> Primary = new Dictionary<string, string>
    {
        ["terminal"] = "command", ["web_search"] = "query", ["web_extract"] = "urls", ["read_file"] = "path", ["write_file"] = "path", ["patch"] = "path",
        ["search_files"] = "pattern", ["browser_navigate"] = "url", ["browser_click"] = "ref", ["browser_type"] = "text", ["image_generate"] = "prompt",
        ["text_to_speech"] = "text", ["vision_analyze"] = "question", ["skill_view"] = "name", ["skills_list"] = "category", ["cronjob_manage"] = "action",
        ["execute_code"] = "code", ["browser_exec"] = "code", ["delegate_task"] = "goal", ["skill_manage"] = "name", ["message_agent"] = "target",
    };
    private static readonly string[] FallbackKeys = ["query", "text", "command", "path", "name", "prompt", "code", "goal"];
    private static readonly HashSet<string> PathTools = ["read_file", "write_file", "patch"];
    private static readonly HashSet<string> UrlTools = ["browser_navigate", "web_extract"];

    private static string OneLine(string v) => string.Join(" ", v.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    private static string Basename(string path)
    {
        var p = path.Replace('\\', '/').TrimEnd('/');
        return p.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? path;
    }

    private static readonly Regex Scheme = new(@"^https?://(?:www\.)?", RegexOptions.IgnoreCase);

    private static string BareUrl(string url)
    {
        var u = Scheme.Replace(url, "", 1);
        return u.EndsWith('/') ? u[..^1] : u;
    }

    /// JavaScript's String(value) for the scalars a preview shows.
    private static string? Scalar(JsonNode? v) => v switch
    {
        JsonValue jv when jv.TryGetValue(out string? s) => s,
        JsonValue jv when jv.TryGetValue(out bool b) => b ? "true" : "false",
        JsonValue jv when jv.TryGetValue(out double d) => d == Math.Floor(d) && Math.Abs(d) < 1e15
            ? ((long)d).ToString(CultureInfo.InvariantCulture) : d.ToString("R", CultureInfo.InvariantCulture),
        _ => null,
    };

    public static string Preview(string tool, IReadOnlyDictionary<string, JsonNode?> args)
    {
        if (tool == "delegate_task" && args.TryGetValue("tasks", out var t) && t is JsonArray { Count: > 0 } tasks)
            return tasks.Count == 1 ? OneLine(Scalar(tasks[0].Get("goal")) ?? "") : $"{tasks.Count} tasks";
        var key = Primary.TryGetValue(tool, out var k) ? k : FallbackKeys.FirstOrDefault(f => args.ContainsKey(f) && args[f] != null);
        if (key == null || !args.TryGetValue(key, out var value) || value == null) return "";
        if (value is JsonArray items)
        {
            if (items.Count == 0) return "";
            value = items[0];
        }
        if (Scalar(value) is not { } raw) return "";
        var text = OneLine(raw);
        if (PathTools.Contains(tool)) return Basename(text);
        if (UrlTools.Contains(tool)) return BareUrl(text);
        return text;
    }

    public static ToolLine Line(string toolName, IReadOnlyDictionary<string, JsonNode?> values)
    {
        var tool = toolName.StartsWith("functions.") ? toolName["functions.".Length..] : toolName;
        // The gateway's `tool_call` wrapper is the call inside it; Composio's say the app's action, never "Composio"
        // (owner, 2026-10-29; ToolLine.swift at 93f984bb1).
        if (Hermes.Core.Activity.ToolNow.Unwrap(tool, values) is { } inner) return Line(inner.Name, inner.Args);
        if (tool.StartsWith("mcp_", StringComparison.Ordinal)
            && Hermes.Core.Activity.ToolNow.HumanName(tool).Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.ToLowerInvariant() == "composio"
            && Hermes.Core.Activity.ToolNow.Mcp(tool, values) is { Length: > 0 } composio)
            return new ToolLine(Emoji.TryGetValue(tool, out var c) ? c : "⚙️", composio[..1].ToUpperInvariant() + composio[1..]);
        var mark = Emoji.TryGetValue(tool, out var e) ? e : "⚙️";
        if (tool is "terminal" or "execute_code")
        {
            var command = (Scalar(values.GetValueOrDefault(tool == "terminal" ? "command" : "code")) ?? "").Trim();
            if (command.Length > 0) return new ToolLine(mark, tool == "terminal" ? "terminal" : "Running code", command);
        }
        var shown = NoPreview.Contains(tool) ? "" : Preview(tool, values);
        if (!Verb.TryGetValue(tool, out var words))
            return new ToolLine(mark, shown.Length == 0 ? $"{tool}…" : $"{tool}: “{shown}”");
        return new ToolLine(mark, shown.Length == 0 ? words : $"{words}{(ForConnector.Contains(tool) ? " for " : " ")}{shown}");
    }

    public static ToolLine Line(ToolCall call) => Line(call.Name, ToolArgs.Of(call));
}

/// The Steps list and step sheet's words (App/Chat/Activity/StepSheets.swift).
public static class StepWords
{
    /// A step's words: the chat row's own plain words when it has them, else Hermes's progress line, its verb in the
    /// past once the step is done ("Read big.txt", "Ran a command"; a running or failed step keeps "Reading …").
    public static string Words(ToolCall call, ToolLine line)
    {
        var failed = call.State == ToolState.Failed;
        if (!failed && ToolWords.PlainLabel(call.Name, ToolArgs.Of(call), call.ArgsText ?? "") is { } plain) return plain;
        if (call.Name == "terminal" && line.Text == "terminal") return call.State == ToolState.Running ? "Running a command" : "Ran a command";
        return call.State == ToolState.Done ? ToolLines.Done(line.Text) : line.Text;
    }

    public static string Words(ToolCall call) => Words(call, ToolLines.Line(call));

    public const int CodeLineCount = 3;

    /// The code's first lines (blank ones at either end dropped) and how many are left out ("+2 more lines").
    public static (IReadOnlyList<string> Lines, int More) CodePreview(string code)
    {
        var lines = code.Split('\n').Select(l => l.Replace("\t", "    ")).ToList();
        var kept = lines.SkipWhile(l => l.Trim().Length == 0).ToList();
        while (kept.Count > 0 && kept[^1].Trim().Length == 0) kept.RemoveAt(kept.Count - 1);
        return (kept.Take(CodeLineCount).ToList(), Math.Max(0, kept.Count - CodeLineCount));
    }

    public static string MoreLines(int more) => more == 1 ? "+1 more line" : $"+{more} more lines";

    public static bool IsTerminal(ToolCall call) => call.Name is "terminal" or "execute_code";

    /// The step sheet's title: "Terminal" for a command; else the step's own ("Edited app.ts", "Ran 1 command").
    public static string SheetTitle(ToolCall call) =>
        IsTerminal(call) ? "Terminal" : RunSummary.Summarize([call], call.State == ToolState.Running);

    /// `tool_describe`: the tools the bot read about, one per line in words, in the Input's place.
    public static string? DescribedTools(ToolCall call)
    {
        if (call.Name.Trim() != "tool_describe") return null;
        var names = ToolWords.DescribedNames(ToolArgs.Of(call)).Select(ToolWords.Words).Where(n => n.Length > 0).ToList();
        return names.Count == 0 ? null : string.Join("\n", names);
    }

    /// The step sheet's sections in order (name, text, monospaced): Command / Tools / Input, Output or Error, Duration,
    /// and "No details for this step." when nothing else shows. Empty or "{}" values are left out, as the Mac's.
    public static IReadOnlyList<(string Name, string Text, bool Mono)> Sections(ToolCall call)
    {
        var o = new List<(string, string, bool)>();
        void Add(string name, string? value, bool mono = true)
        {
            if (string.IsNullOrWhiteSpace(value)) return;
            var bare = string.Concat(value.Where(c => !char.IsWhiteSpace(c)));
            if (bare is "{}" or "[]") return;
            o.Add((name, value, mono));
        }
        var args = ToolArgs.Of(call);
        var isEdit = RunSummary.IsFileEdit(call.Name);
        if (IsTerminal(call)) Add("Command", ToolArgs.FirstString(args, "command", "code"));
        else if (DescribedTools(call) is { } tools) Add("Tools", tools);
        else if (!isEdit) Add("Input", call.ArgsJson ?? call.ArgsText);
        var output = call.ResultText ?? call.Summary;
        Add(call.State == ToolState.Failed ? "Error" : "Output", output);
        if (call.DurationSeconds is { } d && FormatDuration(d).Length > 0) Add("Duration", FormatDuration(d), mono: false);
        if (o.Count(s => s.Item3) == 0) Add("Details", "No details for this step.", mono: false);
        return o;
    }

    /// The subtitle under the title: a file edit's full path when it differs from the title, then "Failed".
    public static string? Subtitle(ToolCall call)
    {
        var parts = new List<string>();
        var title = RunSummary.Summarize([call], call.State == ToolState.Running);
        if (RunSummary.IsFileEdit(call.Name))
        {
            var path = ToolArgs.FirstString(ToolArgs.Of(call), "path", "file", "filepath");
            if (path.Length > 0 && path != title) parts.Add(path);
        }
        if (call.State == ToolState.Failed) parts.Add("Failed");
        return parts.Count == 0 ? null : string.Join(" · ", parts);
    }

    /// What Copy puts on the clipboard for a step: its title and each section, as the Mac's Copy.
    public static string CopyText(ToolCall call) =>
        string.Join("\n\n", new[] { RunSummary.Summarize([call], call.State == ToolState.Running) }
            .Concat(Sections(call).Where(s => s.Name != "Details").Select(s => $"{s.Name}\n{s.Text}")));

    /// `formatDurationSeconds` (ToolCards.swift): "Nms" under 1 s, "4.2s" under 10 s, "42s", "Xm Ys"/"Xm", "Xh Ym"/"Xh".
    public static string FormatDuration(double seconds)
    {
        if (!double.IsFinite(seconds) || seconds < 0) return "";
        if (seconds < 1) return $"{Math.Max(1, (int)Math.Round(seconds * 1000, MidpointRounding.AwayFromZero))}ms";
        if (seconds < 60) return seconds >= 10 ? $"{(int)Math.Round(seconds, MidpointRounding.AwayFromZero)}s"
            : seconds.ToString("0.0", CultureInfo.InvariantCulture) + "s";
        var whole = (int)Math.Round(seconds, MidpointRounding.AwayFromZero);
        int minutes = whole / 60, rem = whole % 60;
        if (minutes < 60) return rem > 0 ? $"{minutes}m {rem}s" : $"{minutes}m";
        int hours = minutes / 60, remMinutes = minutes % 60;
        return remMinutes > 0 ? $"{hours}h {remMinutes}m" : $"{hours}h";
    }

    /// "Ns" under a minute, else "m:ss", "h:mm:ss" (SubagentRules.formatElapsed).
    public static string FormatElapsed(int seconds)
    {
        var s = Math.Max(0, seconds);
        if (s < 60) return $"{s}s";
        if (s < 3600) return $"{s / 60}:{s % 60:00}";
        return $"{s / 3600}:{s / 60 % 60:00}:{s % 60:00}";
    }

    /// "Thinking" while open; "Thought for 7s" / "Thought briefly" when measured; "Thought" from history.
    public static string ThoughtTitle(double? seconds, bool live)
    {
        if (live) return "Thinking";
        if (seconds is not { } s) return "Thought";
        var whole = (int)s;
        return whole == 0 ? "Thought briefly" : $"Thought for {FormatElapsed(whole)}";
    }
}
