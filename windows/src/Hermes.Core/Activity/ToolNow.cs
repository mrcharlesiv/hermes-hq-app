// [toolnow] What the bot is doing this moment, in a few words (HermesKit/Activity/ToolNow.swift at 93f984bb1; owner,
// 2026-10-27: show the running tool instead of "is thinking…"). A few words that fit one line: the verb of the tool's
// line (ToolLines) in lower case and its subject made short. A path is its file name, an address its site, a command
// its program and arguments without the `cd … &&` in front or the folders, and any subject is cut at `SubjectLimit`
// characters. [WIN-LIVE-STEPS] The Bots and Sessions rows name the running step with these words (LiveSteps).

using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Notifications;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Activity;

public static class ToolNow
{
    /// The longest subject kept whole; longer ones end in "…" (the row cuts what still doesn't fit).
    public const int SubjectLimit = 36;

    /// Tools whose subject reads badly after the verb: their own words, nothing after.
    private static readonly IReadOnlyDictionary<string, string> Plain = new Dictionary<string, string>
    {
        ["image_generate"] = "making an image", ["video_generate"] = "making a video", ["text_to_speech"] = "recording audio",
        ["vision_analyze"] = "looking at an image", ["video_analyze"] = "watching a video", ["browser_click"] = "clicking in the browser",
        ["browser_scroll"] = "scrolling the page", ["browser_snapshot"] = "looking at the page", ["browser_back"] = "going back a page",
        ["browser_press"] = "pressing a key", ["browser_vision"] = "looking at the page", ["browser_console"] = "reading the console",
        ["browser_get_images"] = "looking at the page's images", ["cronjob_manage"] = "updating a scheduled job",
        ["execute_code"] = "running code", ["process_manage"] = "checking a background task", ["read_terminal"] = "reading the terminal",
        ["close_terminal"] = "closing the terminal", ["memory"] = "updating memory", ["todo_list"] = "updating tasks", ["todo"] = "updating tasks",
        ["skills_list"] = "looking through skills", ["session_search"] = "searching past chats", ["clarify"] = "asking you something",
        ["x_search"] = "searching X",
    };

    /// The tool a bot messages another bot with (BotDMs.tool).
    public const string MessageAgent = "message_agent";

    /// "running npm test", "reading package.json", "searching the web for swift actors" (no capital, no ellipsis).
    public static string Phrase(Model.ToolCall call) => Phrase(call.Name, ToolArgs.Of(call));

    public static string Phrase(string name, IReadOnlyDictionary<string, JsonNode?> args)
    {
        var tool = name.StartsWith("functions.", StringComparison.Ordinal) ? name["functions.".Length..] : name;
        if (Unwrap(tool, args) is { } inner) return Phrase(inner.Name, inner.Args);
        if (tool == "tool_call" && args.GetValueOrDefault("calls") is JsonArray { Count: > 1 } calls) return $"running {calls.Count} tools";
        if (Plain.TryGetValue(tool, out var words)) return words;
        switch (tool)
        {
            case "terminal":
                // Masked first: a password typed into a command must not reach the row.
                var command = Str(args.GetValueOrDefault("command")) is { } c ? Command(NotificationText.Redact(c)) : "";
                return command.Length == 0 ? "running a command" : "running " + Short(command);
            case "delegate_task":
                if (args.GetValueOrDefault("tasks") is JsonArray { Count: > 1 } tasks) return $"handing off {tasks.Count} tasks";
                return "handing off a task";
            case MessageAgent:
                var target = (Str(args.GetValueOrDefault("target")) ?? "").Trim('@', ' ');
                return target.Length == 0 ? "messaging another bot" : "messaging " + Short(target);
            case "browser_navigate" or "web_extract":
                var url = ToolLines.Preview(tool, args);
                var host = url.Split('/', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "";
                var verb = tool == "web_extract" ? "reading " : "opening ";
                return host.Length == 0 ? (tool == "web_extract" ? "reading a page" : "opening a page") : verb + Short(host);
            default:
                if (Mcp(tool, args) is { } mcp) return mcp;
                break;
        }
        if (!ToolLines.Verb.TryGetValue(tool, out var lineVerb)) return "using " + Short(HumanName(tool));
        var lead = Lower(lineVerb);
        var subject = ToolLines.NoPreview.Contains(tool) ? "" : ToolLines.Preview(tool, args);
        if (subject.Length == 0) return lead;
        return lead + (ToolLines.ForConnector.Contains(tool) ? " for " : " ") + Short(subject);
    }

    /// A command as a few words: its first line, without leading `cd <dir> &&`, `VAR=value` and `env`, each word that is
    /// a path as its last part ("python3 /a/b/run.py --fast" → "python3 run.py --fast"). `sudo` stays, once, in front:
    /// the row says when a bot runs as root.
    public static string Command(string raw)
    {
        var first = raw.Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "";
        var line = first.Trim(' ', '\t');
        // Keep the first of a `cd x && y && z` chain's commands that isn't a cd, else the line as it is.
        var steps = line.Split("&&").Select(s => s.Trim(' ', '\t')).Where(s => s.Length > 0).ToList();
        if (steps.FirstOrDefault(s => !s.StartsWith("cd ", StringComparison.Ordinal) && s != "cd") is { } real) line = real;
        var words = line.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
        var root = new List<string>();
        while (words.Count > 0 && words[0] is var head && (head == "sudo" || head == "env" || (head.Contains('=') && !head.StartsWith('-'))))
        {
            words.RemoveAt(0);
            if (head == "sudo") root = ["sudo"];
        }
        words = [.. root, .. words];
        words = [.. words.Select(word =>
        {
            if (!word.Contains('/') || word.Contains("://")) return word;
            var trimmed = word.EndsWith('/') ? word[..^1] : word;
            return trimmed.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? word;
        })];
        return string.Join(" ", words);
    }

    /// The gateway's `tool_call` wrapper (how bots reach Composio): the call inside it, so the row names that and not
    /// "tool call". Null when it holds none or several.
    public static (string Name, IReadOnlyDictionary<string, JsonNode?> Args)? Unwrap(string tool, IReadOnlyDictionary<string, JsonNode?> args)
    {
        if (tool != "tool_call" || args.GetValueOrDefault("calls") is not JsonArray { Count: 1 } calls
            || calls[0] is not JsonObject inner || Str(inner["name"]) is not { Length: > 0 } name) return null;
        IReadOnlyDictionary<string, JsonNode?> innerArgs = inner["arguments"] is JsonObject o ? o.ToDictionary(kv => kv.Key, kv => kv.Value) : Empty;
        if (innerArgs.Count == 0 && Str(inner["arguments"]) is { } text && J.Parse(text) is JsonObject parsed)
            innerArgs = parsed.ToDictionary(kv => kv.Key, kv => kv.Value);
        return (name, innerArgs);
    }

    /// An MCP server's tool: Composio's say the action inside the app (`Composio`); any other server's are its name and
    /// the tool's words without the server repeated, in lower case ("linear search issues").
    public static string? Mcp(string tool, IReadOnlyDictionary<string, JsonNode?> args)
    {
        if (!tool.StartsWith("mcp_", StringComparison.Ordinal)) return null;
        var words = HumanName(tool).Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 0) return null;
        var server = words[0].ToLowerInvariant();
        var rest = words.Skip(1).ToList();
        if (rest.Count > 0 && rest[0].ToLowerInvariant() == server) rest.RemoveAt(0);
        var action = string.Join("_", rest).ToUpperInvariant();
        if (server == "composio") return Composio(action, args);
        var plain = string.Join(" ", rest.Select(w => w == w.ToUpperInvariant() ? w.ToLowerInvariant() : w));
        return "using " + Short(plain.Length == 0 ? server : server + " " + plain);
    }

    /// A Composio tool by what it does in the app, never "Composio" (owner, 2026-10-29): "running SOQL query in
    /// Salesforce", "finding file in Google Drive", "running 3 actions in Gmail", "reading how to use download file in
    /// Google Drive", "checking the Gmail connection".
    public static string Composio(string action, IReadOnlyDictionary<string, JsonNode?> args)
    {
        if (action.Contains("SEARCH_TOOLS"))
        {
            // The use case it looks for, when short enough to read ("looking for a tool to upload a file to Drive").
            if (args.GetValueOrDefault("queries") is JsonArray { Count: 1 } queries
                && Str(queries[0].Get("use_case"))?.Trim() is { Length: > 0 } use)
                return Short("looking for a tool to " + Lower(use));
            return "looking for the right tool";
        }
        var slugs = new List<string>();
        if (args.GetValueOrDefault("tools") is JsonArray tools) slugs.AddRange(tools.Select(t => Str(t.Get("tool_slug"))).OfType<string>());
        if (args.GetValueOrDefault("tool_slugs") is JsonArray list) slugs.AddRange(list.Select(Str).OfType<string>());
        if (Str(args.GetValueOrDefault("tool_slug")) is { } one) slugs.Add(one);
        if (action.Contains("WORKBENCH") && (Str(args.GetValueOrDefault("code_to_execute")) ?? Str(args.GetValueOrDefault("code"))) is { } code)
            slugs.AddRange(WorkbenchSlugs(code));
        if (action.Contains("GET_TOOL_SCHEMAS"))
        {
            if (slugs.Count == 0) return "reading how to use a tool";
            return Short("reading how to use " + (slugs.Count == 1 ? ActionWords(slugs[0], ing: false) + " in " + AppName(slugs[0]) : $"{slugs.Count} tools"));
        }
        if (action.Contains("MANAGE_CONNECTIONS") || action.Contains("WAIT_FOR_CONNECTION"))
        {
            var kits = args.GetValueOrDefault("toolkits") is JsonArray k ? k.Select(Str).OfType<string>().Select(AppName).ToList() : [];
            var what = kits.Count == 1 ? $"the {kits[0]} connection" : "app connections";
            return Short((action.Contains("WAIT") ? "waiting for " : "checking ") + what);
        }
        if (action.Contains("BASH")) return "running a command";
        if (slugs.Count == 0) return action.Contains("WORKBENCH") ? "running a script" : "using a connected app";
        var apps = new List<string>();
        foreach (var slug in slugs)
        {
            var app = AppName(slug);
            if (app.Length > 0 && !apps.Contains(app)) apps.Add(app);
        }
        var place = apps.Count == 1 ? apps[0] : apps.Count == 2 ? $"{apps[0]} and {apps[1]}" : $"{apps.Count} apps";
        var lead = action.Contains("WORKBENCH") ? "running a script that does " : "";
        if (slugs.Distinct().Count() == 1) return Short(lead + ActionWords(slugs[0], ing: lead.Length == 0) + " in " + place);
        return Short((lead.Length == 0 ? "running " : lead) + $"{slugs.Count} actions in " + place);
    }

    private static readonly Regex WorkbenchCall = new("""run_composio_tool\(\s*['"]([A-Z0-9_]+)['"]""");

    /// The tool slugs a workbench script runs (`run_composio_tool('GOOGLEDRIVE_DOWNLOAD_FILE', …)`), each once, in order.
    public static IReadOnlyList<string> WorkbenchSlugs(string code)
    {
        var o = new List<string>();
        foreach (Match m in WorkbenchCall.Matches(code))
            if (!o.Contains(m.Groups[1].Value)) o.Add(m.Groups[1].Value);
        return o;
    }

    /// Words kept in capitals in an action ("run SOQL query").
    private static readonly HashSet<string> Acronyms = ["soql", "sql", "url", "urls", "id", "ids", "pdf", "api", "csv", "html", "sms", "crm"];
    /// Verbs that double their last letter before "-ing".
    private static readonly HashSet<string> Doubles = ["run", "get", "set", "put", "stop", "plan", "chat", "tag", "pin", "ship", "scan"];

    /// A slug's action without its app: "NOTION_SEARCH_NOTION_PAGE" → "searching page" (`ing`) or "search page".
    public static string ActionWords(string slug, bool ing)
    {
        var parts = slug.ToLowerInvariant().Split('_', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0) return "";
        var head = parts[0];
        var words = parts.Skip(1).Where(w => w != head).ToList();
        if (words.Count == 0) return "using it";
        if (ing) words[0] = Gerund(words[0]);
        return string.Join(" ", words.Select(w => Acronyms.Contains(w) ? w.ToUpperInvariant() : w));
    }

    public static string Gerund(string verb)
    {
        if (verb.EndsWith("ing", StringComparison.Ordinal)) return verb;
        if (Doubles.Contains(verb) && verb.Length > 0) return verb + verb[^1] + "ing";
        if (verb.EndsWith('e') && !verb.EndsWith("ee", StringComparison.Ordinal) && verb.Length > 2) return verb[..^1] + "ing";
        return verb + "ing";
    }

    private static readonly IReadOnlyDictionary<string, string> AppNames = new Dictionary<string, string>
    {
        ["gmail"] = "Gmail", ["googlecalendar"] = "Google Calendar", ["googledrive"] = "Google Drive", ["googledocs"] = "Google Docs",
        ["googlesheets"] = "Google Sheets", ["github"] = "GitHub", ["gitlab"] = "GitLab", ["hubspot"] = "HubSpot", ["clickup"] = "ClickUp",
        ["youtube"] = "YouTube", ["linkedin"] = "LinkedIn", ["whatsapp"] = "WhatsApp", ["one_drive"] = "OneDrive", ["metaads"] = "Meta Ads",
        ["googleads"] = "Google Ads", ["googlemeet"] = "Google Meet", ["googletasks"] = "Google Tasks", ["googlephotos"] = "Google Photos",
        ["outlook"] = "Outlook", ["onedrive"] = "OneDrive", ["quickbooks"] = "QuickBooks", ["openai"] = "OpenAI", ["exa"] = "Exa",
    };

    /// A Composio tool slug's app: "GMAIL_FETCH_EMAILS" → "Gmail", "GOOGLECALENDAR_FIND_EVENT" → "Google Calendar".
    public static string AppName(string slug)
    {
        var head = slug.Split('_', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.ToLowerInvariant() ?? "";
        if (head.Length == 0) return "";
        return AppNames.TryGetValue(head, out var name) ? name : char.ToUpperInvariant(head[0]) + head[1..];
    }

    /// "mcp__linear__search_issues" → "linear search issues".
    public static string HumanName(string tool)
    {
        var name = tool.StartsWith("mcp__", StringComparison.Ordinal) ? tool[5..] : tool.StartsWith("mcp_", StringComparison.Ordinal) ? tool[4..] : tool;
        return string.Join(" ", name.Replace("__", " ").Replace("_", " ").Split(' ', StringSplitOptions.RemoveEmptyEntries));
    }

    /// The text on one line, cut at `SubjectLimit` characters with "…".
    public static string Short(string text)
    {
        var one = string.Join(" ", text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        var info = new StringInfo(one);
        if (info.LengthInTextElements <= SubjectLimit) return one;
        return info.SubstringByTextElements(0, SubjectLimit - 1).Trim(' ', '\t') + "…";
    }

    private static readonly IReadOnlyDictionary<string, JsonNode?> Empty = new Dictionary<string, JsonNode?>();

    private static string Lower(string words) => words.Length == 0 ? words : words[..1].ToLowerInvariant() + words[1..];

    /// A JSON string's value (the Swift `.string`); null for anything else.
    internal static string? Str(JsonNode? v) =>
        v is JsonValue jv && jv.GetValueKind() == JsonValueKind.String ? jv.GetValue<string>() : null;
}
