using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Model;

namespace Hermes.Core.Transcripts;

/// The glyph a step line leads with (App/Chat/Render/ChatGlyphs.swift, the ones the transcript's work lines use).
public enum StepGlyph { File, Explore, Terminal, Other, Thinking, Worked, Subagent }

/// The one grey line that stands in for a run of tool calls ("Explored 3 files, ran 5 commands"; App/Chat/Render/
/// ChatRunSummary.swift, the renderer's run-summary.ts; spec 06 §3.2, spec 03 §8.3).
public static class RunSummary
{
    public enum Category { Edit, Explore, Search, Read, Browse, Interact, Analyze, Run, Delegate, Other }

    private static readonly string[] Past = ["Edited", "Explored", "Searched", "Read", "Opened", "Performed", "Analyzed", "Ran", "Delegated", "Used"];
    private static readonly string[] Present = ["Editing", "Exploring", "Searching", "Reading", "Opening", "Performing", "Analyzing", "Running", "Delegating", "Using"];
    private static readonly (string, string)[] Nouns =
    [
        ("file", "files"), ("file", "files"), ("query", "queries"), ("page", "pages"), ("page", "pages"),
        ("browser action", "browser actions"), ("image", "images"), ("command", "commands"), ("task", "tasks"), ("tool", "tools"),
    ];

    public static readonly HashSet<string> FileEditTools = ["edit_file", "patch", "write_file"];
    public static readonly HashSet<string> CardTools = ["clarify", "delegate_task", "image_generate", "manage_catalog", "manage_connections"];
    public static readonly HashSet<string> SilentTools = ["react_to_message", "todo", "todo_list"];

    public static bool IsFileEdit(string name) => FileEditTools.Contains(name);
    /// Tools that never join a run: file edits and card tools draw their own row.
    public static bool StandsAlone(string name) => FileEditTools.Contains(name) || CardTools.Contains(name);
    public static bool IsSilent(string name) => SilentTools.Contains(name);
    /// A successful silent tool (a to-do update) draws nothing and counts for nothing.
    public static bool Hidden(ToolCall c) => IsSilent(c.Name) && c.State != ToolState.Failed;

    public static Category CategoryOf(string name)
    {
        if (IsFileEdit(name)) return Category.Edit;
        return name switch
        {
            "browser_navigate" => Category.Browse,
            "delegate_task" => Category.Delegate,
            "execute_code" or "terminal" => Category.Run,
            "list_files" or "read_file" or "search_files" => Category.Explore,
            "session_search_recall" or "web_search" => Category.Search,
            "vision_analyze" => Category.Analyze,
            "web_extract" => Category.Read,
            _ => name.StartsWith("browser_") ? Category.Interact : Category.Other,
        };
    }

    /// `summarizeToolRun(tools, live)`.
    public static string Summarize(IReadOnlyList<ToolCall> tools, bool live)
    {
        var narrating = live ? tools.FirstOrDefault(t => t.State == ToolState.Running) ?? tools.LastOrDefault() : null;
        Category? liveCategory = narrating == null ? null : CategoryOf(narrating.Name);
        // Clauses in the order their first step happened (Mac full pass 2026-11-14), not a fixed category order.
        var slots = new List<object>();
        var groups = new Dictionary<Category, List<ToolCall>>();
        foreach (var tool in tools)
        {
            if (SkillTitle(tool, live) is { } skill) { slots.Add(skill); continue; }
            if (tool.State != ToolState.Failed && ToolWords.PlainLabel(tool.Name, ToolArgs.Of(tool), tool.ArgsText ?? "") is { } plain)
            { slots.Add(plain); continue; }
            var cat = CategoryOf(tool.Name);
            if (!groups.TryGetValue(cat, out var list)) { groups[cat] = list = []; slots.Add(cat); }
            list.Add(tool);
        }
        var clauses = slots.Select(s => s is string w ? w : Clause((Category)s, groups[(Category)s], (Category)s == liveCategory)).ToList();
        var failed = tools.Count(t => t.State == ToolState.Failed);
        if (failed > 0) clauses.Add($"{failed} tool call{(failed == 1 ? "" : "s")} failed");
        return string.Join(", ", clauses.Select((c, i) => i == 0 ? c : LowerFirst(c)));
    }

    private static string Clause(Category cat, List<ToolCall> tools, bool live)
    {
        var verb = live ? Present[(int)cat] : Past[(int)cat];
        // Edits count files, not calls (n20 F10): a file touched twice is one file, as the files card says.
        var count = cat == Category.Edit ? UniqueEditCount(tools) : tools.Sum(UnitCount);
        var target = count == 1 && cat != Category.Interact ? ToolTarget(tools[0]) : "";
        if (target.Length > 0 && (live || cat != Category.Run)) return $"{verb} {target}";
        var (one, many) = Nouns[(int)cat];
        return $"{verb} {count} {(count == 1 ? one : many)}";
    }

    private static int UnitCount(ToolCall tool)
    {
        if (tool.Name != "web_extract") return 1;
        return ToolArgs.Of(tool).TryGetValue("urls", out var u) && u is JsonArray { Count: > 0 } a ? a.Count : 1;
    }

    private static int UniqueEditCount(List<ToolCall> tools)
    {
        var paths = new HashSet<string>();
        for (var i = 0; i < tools.Count; i++)
        {
            var path = ToolArgs.FirstString(ToolArgs.Of(tools[i]), "path", "file_path", "file", "filepath", "target_file");
            paths.Add(path.Length == 0 ? $"|{i}" : path);
        }
        return paths.Count;
    }

    private static string ToolTarget(ToolCall tool)
    {
        var a = ToolArgs.Of(tool);
        switch (CategoryOf(tool.Name))
        {
            case Category.Run:
                // A heredoc script is named by its command, not by its first setup line (§5.1).
                return SummarizeShellCommand(ToolWords.ScriptTitleSource(ToolArgs.FirstString(a, "command", "code")));
            case Category.Search:
                var q = ToolArgs.FirstString(a, "query", "search_term");
                return q.Length == 0 ? "" : $"“{CompactPreview(q, 48)}”";
            case Category.Read:
            case Category.Browse:
                return Hostname(FindFirstUrl(new JsonObject(a.Select(kv => KeyValuePair.Create(kv.Key, kv.Value?.DeepClone())))));
            default:
                var path = ToolArgs.FirstString(a, "path", "file", "filepath");
                return path.Length == 0 ? ToolArgs.FirstString(a, "query", "url") : FileBasename(path);
        }
    }

    private static string? SkillTitle(ToolCall tool, bool live)
    {
        if (tool.Name is not ("skill_view" or "skills_list")) return null;
        var a = ToolArgs.Of(tool);
        var failed = tool.State == ToolState.Failed;
        var pending = live && tool.State == ToolState.Running;
        var missing = !pending && tool.Summary == null && tool.State == ToolState.Running;
        var file = ToolArgs.FirstString(a, "file_path");
        var name = ToolArgs.FirstString(a, "name");
        var target = string.Join(" → ", new[] { name, file }.Where(s => s.Length > 0));
        (string pending, string done, string failed) words = tool.Name == "skills_list"
            ? ("Listing skills", "Listed skills", "Failed to list skills")
            : file.Length > 0 ? ("Reading skill resource", "Read skill resource", "Failed to read skill resource")
            : ("Loading skill", "Loaded skill", "Failed to load skill");
        var label = failed ? words.failed : missing ? "Skill result unavailable" : pending ? words.pending : words.done;
        return target.Length == 0 ? label : $"{label}: {target}";
    }

    // MARK: Helpers (lib/text.ts)

    public static string CompactPreview(string value, int max)
    {
        var line = string.Join(" ", value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return line.Length > max ? line[..(max - 1)] + "…" : line;
    }

    public static string FileBasename(string path)
    {
        var n = path.Replace('\\', '/').Trim(' ');
        return n.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? n;
    }

    private static readonly Regex UrlRx = new(@"https?://[^\s'""<>)\]]+", RegexOptions.IgnoreCase);

    public static string FindFirstUrl(JsonNode? value) => value switch
    {
        JsonValue v when v.TryGetValue(out string? s) => UrlRx.Match(s) is { Success: true } m ? m.Value : "",
        JsonArray a => a.Select(FindFirstUrl).FirstOrDefault(f => f.Length > 0) ?? "",
        JsonObject o => o.OrderBy(kv => kv.Key, StringComparer.Ordinal).Select(kv => FindFirstUrl(kv.Value)).FirstOrDefault(f => f.Length > 0) ?? "",
        _ => "",
    };

    public static string Hostname(string value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var url) || url.Host.Length == 0) return value;
        var path = url.AbsolutePath;
        return url.Host + (path.Length == 0 || path == "/" ? "" : path);
    }

    private static string LowerFirst(string s) => s.Length == 0 ? s : char.ToLowerInvariant(s[0]) + s[1..];

    // MARK: summarizeShellCommand (lib/summarize-command.ts)

    private static readonly HashSet<string> SilentHeads = ["cd", "pushd", "popd", "export", "set", "unset", "source", ".", "true", "false", ":"];
    private static readonly HashSet<string> PipeTailHeads = ["head", "tail", "wc", "sort", "uniq"];

    public static string SummarizeShellCommand(string raw)
    {
        var original = raw.Trim();
        if (original.Length == 0) return "";
        var segments = SplitCompound(original);
        if (segments.Count <= 1)
        {
            var cleaned = CleanSegment(original);
            return cleaned.Length == 0 ? original : cleaned;
        }
        var core = segments.Select(CleanSegment).Where(s => s.Length > 0 && !SilentHeads.Contains(HeadWord(s)) && !IsBoundaryEcho(s)).ToList();
        if (core.Count == 0) return original;
        if (core.Count == 1) return core[0];
        return $"{core[0]} + {core.Count - 1} {(core.Count == 2 ? "command" : "commands")}";
    }

    private static string Basename(string head)
    {
        var last = head.Split('/').Last();
        return last.Length == 0 ? head : last;
    }

    private static List<string> SplitCompound(string input)
    {
        var segments = new List<string>();
        var buf = new System.Text.StringBuilder();
        char? quote = null;
        for (var i = 0; i < input.Length; i++)
        {
            var ch = input[i];
            if (quote is { } q)
            {
                buf.Append(ch);
                if (ch == q && (i == 0 || input[i - 1] != '\\')) quote = null;
                continue;
            }
            if (ch is '"' or '\'') { quote = ch; buf.Append(ch); continue; }
            if (i + 1 < input.Length && ((ch == '&' && input[i + 1] == '&') || (ch == '|' && input[i + 1] == '|')))
            {
                segments.Add(buf.ToString()); buf.Clear(); i++; continue;
            }
            if (ch is ';' or '\n') { segments.Add(buf.ToString()); buf.Clear(); continue; }
            buf.Append(ch);
        }
        segments.Add(buf.ToString());
        return segments.Select(s => StripPipeTail(s.Trim())).Where(s => s.Length > 0).ToList();
    }

    private static List<string> SplitWords(string segment)
    {
        var words = new List<string>();
        var buf = new System.Text.StringBuilder();
        char? quote = null;
        for (var i = 0; i < segment.Length; i++)
        {
            var ch = segment[i];
            if (quote is { } q)
            {
                buf.Append(ch);
                if (ch == q && (i == 0 || segment[i - 1] != '\\')) quote = null;
                continue;
            }
            if (ch is '"' or '\'') { quote = ch; buf.Append(ch); continue; }
            if (char.IsWhiteSpace(ch))
            {
                if (buf.Length > 0) { words.Add(buf.ToString()); buf.Clear(); }
                continue;
            }
            buf.Append(ch);
        }
        if (buf.Length > 0) words.Add(buf.ToString());
        return words;
    }

    private static readonly Regex AssignmentWord = new(@"^[A-Za-z_]\w*=");

    private static string HeadWord(string segment)
    {
        var tokens = SplitWords(segment);
        var i = 0;
        while (i < tokens.Count && AssignmentWord.IsMatch(tokens[i])) i++;
        return Basename(i < tokens.Count ? tokens[i] : "");
    }

    private static string StripPipeTail(string segment)
    {
        var words = SplitWords(segment);
        var o = new List<string>();
        for (var i = 0; i < words.Count; i++)
        {
            if (words[i] == "|" && i + 1 < words.Count && PipeTailHeads.Contains(Basename(words[i + 1]))) break;
            o.Add(words[i]);
        }
        return string.Join(" ", o).Trim(' ');
    }

    private static readonly Regex Redirect = new(@"^\d*(?:>>?|<)$");
    private static readonly Regex DupRedirect = new(@"^\d*(?:>&|<&)\d+$");

    private static string CleanSegment(string segment)
    {
        var words = SplitWords(segment);
        var o = new List<string>();
        for (var i = 0; i < words.Count; i++)
        {
            if (Redirect.IsMatch(words[i])) { i++; continue; }
            if (DupRedirect.IsMatch(words[i])) continue;
            o.Add(words[i]);
        }
        return string.Join(" ", o).Trim(' ');
    }

    private static readonly Regex BoundaryEcho = new(@"-{2,}|_exit=|(?:^|\s|=)\$[?{]|PIPESTATUS");

    private static bool IsBoundaryEcho(string segment)
    {
        var words = SplitWords(segment);
        if (Basename(words.FirstOrDefault() ?? "") != "echo") return false;
        return BoundaryEcho.IsMatch(string.Join(" ", words.Skip(1)));
    }

    /// A run's glyph from its summary's first word (trail-model.ts `summaryKind`).
    public static StepGlyph GlyphFor(string summary)
    {
        if (summary.StartsWith("Edited") || summary.StartsWith("Editing")) return StepGlyph.File;
        if (summary.StartsWith("Explored") || summary.StartsWith("Exploring")) return StepGlyph.Explore;
        if (summary.StartsWith("Ran") || summary.StartsWith("Running")) return StepGlyph.Terminal;
        return StepGlyph.Other;
    }
}
