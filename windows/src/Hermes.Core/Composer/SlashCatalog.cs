using System.Collections.Concurrent;
using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Hermes.Core.Composer;

public sealed record CommandCatalogMeta(string? ArgumentMode, string? Desktop);
public sealed record SkillCatalogEntry(long? Usage, string? Origin);
public sealed record CommandCategory(string Name, IReadOnlyList<(string Command, string Description)> Pairs);

/// `commands.catalog`'s answer, the fields the app reads (HermesKit/Chat/SlashCatalog.swift).
public sealed record CommandsCatalog
{
    public IReadOnlyList<CommandCategory>? Categories { get; init; }
    public IReadOnlyList<(string Command, string Description)>? Pairs { get; init; }
    /// Absent (null) when the gateway sent no metadata or a value of the wrong type.
    public IReadOnlyDictionary<string, CommandCatalogMeta>? Commands { get; init; }
    public IReadOnlyDictionary<string, string>? Canon { get; init; }
    public IReadOnlyDictionary<string, SkillCatalogEntry>? Skills { get; init; }
    public string? Warning { get; init; }

    private static List<(string, string)>? PairList(JsonNode? value)
    {
        if (value is not JsonArray rows) return null;
        var list = new List<(string, string)>();
        foreach (var row in rows)
            if (row is JsonArray a && a.Count > 0 && J.AsString(a[0]) is { } command)
                list.Add((command, a.Count > 1 ? J.AsString(a[1]) ?? "" : ""));
        return list;
    }

    public static CommandsCatalog Parse(JsonNode? json)
    {
        var commands = json.Obj("commands") is { } co
            ? co.ToDictionary(p => p.Key, p => new CommandCatalogMeta(p.Value.Str("argument_mode"), p.Value.Str("desktop")))
            : null;
        var canon = json.Obj("canon") is { } cn
            ? cn.Where(p => J.AsString(p.Value) != null).ToDictionary(p => p.Key, p => J.AsString(p.Value)!)
            : null;
        var skills = json.Obj("skills") is { } sk
            ? sk.ToDictionary(p => p.Key, p => new SkillCatalogEntry(p.Value.Int("usage"), p.Value.Str("origin")))
            : null;
        return new CommandsCatalog
        {
            Categories = json.Arr("categories") is { } cats
                ? [.. cats.OfType<JsonObject>().Select(c => new CommandCategory(c.Str("name") ?? "", PairList(c.Get("pairs")) ?? []))]
                : null,
            Pairs = PairList(json.Get("pairs")),
            Commands = commands,
            Canon = canon,
            Skills = skills,
            Warning = json.Text("warning"),
        };
    }
}

/// How the app fulfils a command (`DesktopCommandSurface`).
public abstract record SlashSurface
{
    public sealed record Action(string Name) : SlashSurface;
    public sealed record Picker(string Name) : SlashSurface;
    public sealed record Rpc(string Method) : SlashSurface;
    public sealed record Exec : SlashSurface;
    public sealed record Unavailable(string Reason) : SlashSurface;
}

public sealed record SlashSpec(string Name, string? Description, SlashSurface Surface, string[]? Aliases = null,
    bool Hidden = false, string? ArgumentMode = null);

/// One row of the ☰ list and the slash drawer.
public sealed record CommandRow(string Command, string Description, bool Skill);
public sealed record CommandSection(string Title, IReadOnlyList<CommandRow> Rows);

public enum PickAction { Send, Models, Insert }

public sealed record PickConfirmation(string Title, string Message, string Button);

public static class SlashCatalog
{
    /// `DESKTOP_COMMAND_SPECS` (V:lib/desktop-slash-commands.ts:179-304).
    public static readonly SlashSpec[] LocalSpecs =
    [
        new("/new", "Start a new chat", new SlashSurface.Action("new"), ["/reset", "/clear"]),
        new("/stop", "Stop the active turn and background processes", new SlashSurface.Action("stop")),
        new("/branch", "Branch the latest message into a new chat", new SlashSurface.Action("branch"), ["/fork"]),
        new("/yolo", "Toggle YOLO — auto-approve dangerous commands", new SlashSurface.Action("yolo")),
        new("/reasoning", "Reasoning effort or display [<level> [--global]|show|hide|full|clamp]", new SlashSurface.Action("reasoning"), ArgumentMode: "options"),
        new("/wake", "Control the desktop wake-word listener [on|off|status]", new SlashSurface.Action("wake"), ArgumentMode: "options"),
        new("/handoff", "Hand off this session to a messaging platform", new SlashSurface.Action("handoff"), ArgumentMode: "options"),
        new("/profile", "Switch the active Hermes profile", new SlashSurface.Action("profile")),
        new("/skin", "Switch desktop theme or cycle to the next one", new SlashSurface.Action("skin"), ArgumentMode: "options"),
        new("/title", "Rename the current session", new SlashSurface.Action("title"), ArgumentMode: "text"),
        new("/help", "Show desktop slash commands", new SlashSurface.Action("help"), ["/commands"]),
        new("/browser", "Manage browser CDP connection [connect|disconnect|status] (local gateway only)", new SlashSurface.Action("browser"), ArgumentMode: "options"),
        new("/journey", "Open the memory graph — skills + memories over time", new SlashSurface.Action("journey"), ["/learning", "/memory-graph"]),
        new("/model", "Switch the model for this session", new SlashSurface.Picker("model"), Hidden: true),
        new("/resume", "Resume a saved session", new SlashSurface.Picker("session"), ["/sessions", "/switch"], ArgumentMode: "mixed"),
        new("/compress", "Compress this conversation context", new SlashSurface.Action("compress"), ["/compact"], ArgumentMode: "text"),
        new("/btw", "Ask a side question about this conversation without interrupting it", new SlashSurface.Action("btw"), ArgumentMode: "text"),
        new("/bg", "Run a prompt in a background session", new SlashSurface.Action("background"), ["/background"], ArgumentMode: "text"),
        new("/pet", "Toggle or adopt a petdex mascot (/pet, /pet list, /pet boba)", new SlashSurface.Action("pet"), ArgumentMode: "options"),
        new("/hatch", "Generate a new pet (opens the pet generator)", new SlashSurface.Action("hatch"), ["/generate-pet"]),
        new("/save", "Save the current transcript to JSON", new SlashSurface.Rpc("session.save")),
        new("/status", "Show current session status", new SlashSurface.Rpc("session.status")),
    ];

    private static readonly Dictionary<string, SlashSpec> SpecByName = LocalSpecs.GroupBy(s => s.Name).ToDictionary(g => g.Key, g => g.First());
    private static readonly Dictionary<string, string> AliasToCanonical =
        LocalSpecs.SelectMany(s => (s.Aliases ?? []).Select(a => (a, s.Name))).ToDictionary(p => p.a, p => p.Name);

    /// Desktop actions the app can't do yet: hidden from the list; typed, they answer "isn't available".
    public static readonly HashSet<string> NativeUnsupported =
    [
        "branch", "fork", "resume", "sessions", "switch", "profile", "skin", "wake", "handoff", "browser", "journey",
        "learning", "memory-graph", "pet", "hatch", "generate-pet",
    ];

    /// Commands with nothing to show here.
    public static readonly HashSet<string> PhoneHidden = ["timestamps", "ts", "focus", "egress", "codex-runtime", "codex_runtime", "debug", "worktree"];

    /// "/Name args" → "/name".
    public static string Normalize(string command)
    {
        var trimmed = command.Trim();
        var slashed = trimmed.StartsWith('/') ? trimmed : "/" + trimmed;
        return (slashed.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "").ToLowerInvariant();
    }

    /// "Name args" → "name" (no slash).
    public static string BareName(string command) => Normalize(command) is { Length: > 0 } n ? n[1..] : "";

    private static string? CatalogCanonical(string normalized, CommandsCatalog? catalog) =>
        catalog?.Canon is { } canon ? canon.GetValueOrDefault(normalized) ?? canon.GetValueOrDefault(normalized.ToLowerInvariant()) : null;

    public static string Canonical(string command, CommandsCatalog? catalog)
    {
        var n = Normalize(command);
        return AliasToCanonical.GetValueOrDefault(n) ?? CatalogCanonical(n, catalog) ?? n;
    }

    public static CommandCatalogMeta? CatalogMeta(string command, CommandsCatalog? catalog)
    {
        if (catalog?.Commands is not { } commands) return null;
        var n = Normalize(command);
        var c = AliasToCanonical.GetValueOrDefault(n) ?? CatalogCanonical(n, catalog) ?? n;
        return commands.GetValueOrDefault(c) ?? commands.GetValueOrDefault(n);
    }

    private static readonly HashSet<string> UnavailableReasons = ["advanced", "composer-voice", "messaging", "settings", "terminal"];
    private static readonly HashSet<string> ArgumentModes = ["options", "text", "mixed"];

    private static SlashSpec? SpecFromCatalog(string command, CommandsCatalog? catalog)
    {
        if (CatalogMeta(command, catalog) is not { } meta) return null;
        var name = Canonical(command, catalog);
        if (meta.Desktop is { } reason && UnavailableReasons.Contains(reason)) return new SlashSpec(name, null, new SlashSurface.Unavailable(reason));
        return new SlashSpec(name, null, new SlashSurface.Exec(), Hidden: meta.Desktop == "hidden",
            ArgumentMode: meta.ArgumentMode is { } m && ArgumentModes.Contains(m) ? m : null);
    }

    /// A command's surface: the local table wins, else the catalog's metadata; null = an extension (skill, plugin).
    public static SlashSpec? Resolve(string command, CommandsCatalog? catalog) =>
        SpecByName.GetValueOrDefault(Canonical(command, catalog)) ?? SpecFromCatalog(command, catalog);

    public static bool IsAlias(string command, CommandsCatalog? catalog)
    {
        var n = Normalize(command);
        if (AliasToCanonical.ContainsKey(n)) return true;
        return CatalogCanonical(n, catalog) is { } resolved && resolved.ToLowerInvariant() != n;
    }

    private static bool IsKnown(string command, CommandsCatalog? catalog)
    {
        var n = Normalize(command);
        return SpecByName.ContainsKey(n) || AliasToCanonical.ContainsKey(n) || CatalogMeta(n, catalog) != null;
    }

    /// Not one of Hermes' built-in commands: a skill, a quick command, a plugin command.
    public static bool IsExtension(string command, CommandsCatalog? catalog)
    {
        var n = Normalize(command);
        return n.Length > 0 && n != "/" && !IsKnown(n, catalog);
    }

    /// Offered in the list: not an alias, not unavailable, not hidden — or an extension.
    public static bool IsSuggestion(string command, CommandsCatalog? catalog)
    {
        var n = Normalize(command);
        if (IsAlias(n, catalog)) return false;
        if (Resolve(n, catalog) is { } spec) return spec.Surface is not SlashSurface.Unavailable && !spec.Hidden;
        return IsExtension(n, catalog);
    }

    public static string? ArgumentMode(string command, CommandsCatalog? catalog) =>
        Resolve(command, catalog)?.ArgumentMode
        ?? (CatalogMeta(command, catalog)?.ArgumentMode is { } m && ArgumentModes.Contains(m) ? m : null);

    /// The web's line for a known command with no desktop surface.
    public static string UnavailableMessage(string reason, string command) => reason switch
    {
        "advanced" => $"{command} is not shown in the desktop slash palette. Use the relevant desktop control or terminal interface instead.",
        "composer-voice" => "Voice chat lives in the composer here: click the microphone button and choose \"Start voice chat\", or use the voice shortcut from Settings → Keyboard Shortcuts.",
        "messaging" => $"{command} is only used from messaging platforms.",
        "settings" => $"{command} is managed from the desktop sidebar.",
        _ => $"{command} is only available in the terminal interface.",
    };

    // ------------------------------------------------------------------ descriptions

    /// `composer.commandDescs` (V:i18n/en.ts:3845-3918), keyed by canonical command.
    public static readonly Dictionary<string, string> CommandDescriptions = new()
    {
        ["/help"] = "Show desktop slash commands", ["/clear"] = "start a new session", ["/resume"] = "Resume a saved session",
        ["/details"] = "control transcript detail level", ["/copy"] = "copy selection or last assistant message", ["/quit"] = "exit hermes",
        ["/start"] = "Acknowledge platform start pings without a reply", ["/new"] = "Start a new chat",
        ["/topic"] = "Enable or inspect Telegram DM topic sessions", ["/save"] = "Save the current transcript to JSON",
        ["/retry"] = "Retry the last message (resend to agent)", ["/prompt"] = "Compose your next prompt in $EDITOR (markdown), then send it",
        ["/undo"] = "Back up N user turns and re-prompt (default 1)", ["/title"] = "Rename the current session",
        ["/handoff"] = "Hand off this session to a messaging platform", ["/branch"] = "Branch the latest message into a new chat",
        ["/worktree"] = "Show, list, create, or prune isolated git worktrees", ["/compress"] = "Compress this conversation context",
        ["/rollback"] = "List or restore filesystem checkpoints (restores keep your hand-edits; --all overrides)",
        ["/export"] = "Export a profile (config, skills, theme) to a shareable archive",
        ["/import"] = "Import a shared profile archive as a new profile", ["/stop"] = "Stop the active turn and background processes",
        ["/pause"] = "Pause new work globally (emergency stop); '/pause off' resumes",
        ["/bg"] = "Run a prompt in a separate background session",
        ["/btw"] = "Ask a side question about this conversation without interrupting it",
        ["/agents"] = "Show active agents and running tasks", ["/journey"] = "Open the memory graph — skills + memories over time",
        ["/queue"] = "Queue a prompt for the next turn, or list/edit/rm/move/clear queued prompts",
        ["/steer"] = "Inject a message after the next tool call without interrupting",
        ["/goal"] = "Set a standing goal Hermes works on across turns until achieved",
        ["/heartbeat"] = "Set a recurring prompt that re-enters this session when idle",
        ["/refine"] = "Review this conversation now and save lessons to memory/skills",
        ["/review"] = "Spawn an independent subagent to review the work just discussed (PR, code, docs)",
        ["/loop"] = "Re-run a prompt on a recurring interval in this session",
        ["/plan"] = "Write a markdown implementation plan to .hermes/plans/ without executing anything",
        ["/moa"] = "Run one prompt through the default Mixture of Agents preset, then restore your model",
        ["/subgoal"] = "Add or manage extra criteria on the active goal", ["/status"] = "Show current session status",
        ["/egress"] = "Show Docker egress proxy status",
        ["/context"] = "Show detailed context window view with usage gauge, category breakdown, compression stats, and throughput",
        ["/whoami"] = "Show your slash command access (admin / user)", ["/profile"] = "Switch the active Hermes profile",
        ["/codex-runtime"] = "Toggle codex app-server runtime for OpenAI/Codex models", ["/personality"] = "Set a predefined personality",
        ["/battery"] = "Toggle a color-coded battery indicator in the status bar",
        ["/timestamps"] = "Toggle [HH:MM] timestamps on messages and /history", ["/diff"] = "Show git changes in the working directory",
        ["/focus"] = "Toggle focus view — show only your prompt and the final response",
        ["/yolo"] = "Toggle YOLO — auto-approve dangerous commands",
        ["/approvals"] = "Show or set the persistent dangerous-command approval mode",
        ["/reasoning"] = "Reasoning effort or display [<level> [--global]|show|hide|full|clamp]",
        ["/skin"] = "Switch desktop theme or cycle to the next one", ["/wake"] = "Control the desktop wake-word listener [on|off|status]",
        ["/tools"] = "Manage tools: /tools [list|disable|enable] [name...]", ["/memory"] = "Review pending memory writes / toggle the approval gate",
        ["/bundles"] = "List skill bundles (aliases /<name> for multiple skills)",
        ["/pet"] = "Toggle or adopt a petdex mascot (/pet, /pet list, /pet boba)", ["/hatch"] = "Generate a new pet (opens the pet generator)",
        ["/learn"] = "Learn a reusable skill from anything you describe (dirs, URLs, this chat, notes)",
        ["/init"] = "Generate or update AGENTS.md project instructions from a repo scan",
        ["/suggestions"] = "Review suggested automations (accept/dismiss)", ["/blueprint"] = "Set up an automation from a blueprint template",
        ["/browser"] = "Manage browser CDP connection [connect|disconnect|status] (local gateway only)",
        ["/palette"] = "Open the fuzzy command palette (also Ctrl+P)",
        ["/usage"] = "Show token usage and rate limits; `reset` redeems a banked Codex limit reset",
        ["/subscription"] = "View your Nous plan and change it in the browser",
        ["/topup"] = "Show your Nous balance and manage billing on the portal",
        ["/platform"] = "Pause, resume, or list a failing gateway platform", ["/version"] = "Show Hermes Agent version",
        ["/debug"] = "Upload debug report (system info + logs) and get shareable links", ["/model"] = "Switch the model for this session",
    };

    public const string HelpDescription = "Show the commands list";

    private static readonly Regex UsageSuffix = new(@"\s+\(usage:\s+(.+)\)$", RegexOptions.Singleline);

    /// The English override, else the local spec's, else the catalog's text; a catalog " (usage: …)" suffix is kept.
    public static string DesktopDescription(string command, string fallback, CommandsCatalog? catalog)
    {
        var c = Canonical(command, catalog);
        var description = CommandDescriptions.GetValueOrDefault(c) ?? SpecByName.GetValueOrDefault(c)?.Description;
        if (description == null) return fallback;
        var usage = UsageSuffix.Match(fallback) is { Success: true } m ? m.Value : "";
        return description + usage;
    }

    /// Known commands in plain words (S:fe-convo-r5.ts:200-206).
    public static readonly Dictionary<string, string> PlainWords = new()
    {
        ["reasoning"] = "Reasoning effort, or show or hide the reasoning", ["usage"] = "Token usage and rate limits",
        ["tools"] = "Turn tools on or off", ["rollback"] = "List or restore file checkpoints", ["bundles"] = "List skill bundles",
        ["pet"] = "Show or adopt a pet mascot", ["browser"] = "Connect the gateway’s browser", ["pause"] = "Pause all new work (emergency stop)",
        ["undo"] = "Go back and re-prompt", ["queue"] = "Queue a prompt for the next turn",
        ["platform"] = "Pause, resume or list a messaging platform", ["prompt"] = "Compose your next prompt, then send it",
        ["clear"] = "Start a new session", ["details"] = "Transcript detail level", ["copy"] = "Copy the last reply", ["quit"] = "Exit Hermes",
    };

    private static readonly Regex Backticks = new("`([^`]*)`");
    private static readonly Regex CommandParens = new(@"\s*\((?:[^()]*?(?:\/\w|--\w|\baliases?\b|\be\.g\.)[^()]*)\)", RegexOptions.IgnoreCase);
    private static readonly Regex ColonCommandTail = new(@":\s*\/\w[\s\S]*$");
    private static readonly Regex SemicolonTail = new(@";\s*(?:['""]?\/\w|\w+\s+(?:redeems|resets|resumes))[\s\S]*$", RegexOptions.IgnoreCase);
    private static readonly Regex Flags = new(@"\s--?[\w-]+");
    private static readonly Regex Pipes = new(@"\s*\|\s*");
    private static readonly Regex Spaces = new(@"\s+");
    private static readonly Regex Trailing = new(@"[\s;:,.|]+$");

    /// A description without its terminal syntax (`slashDescription`, S:fe-convo-r5.ts:207-228).
    public static string PlainDescription(string command, string? text)
    {
        var name = BareName(command);
        if (name == "help") return HelpDescription;
        if (PlainWords.TryGetValue(name, out var plain)) return plain;
        var o = (text ?? "").Trim();
        if (o.Length == 0) return o;
        o = Backticks.Replace(o, "$1");
        o = CommandParens.Replace(o, "");
        o = ColonCommandTail.Replace(o, "");
        o = SemicolonTail.Replace(o, "");
        var depth = 0;
        var kept = new System.Text.StringBuilder();
        foreach (var ch in o)
        {
            if (ch is '[' or '<') { depth++; continue; }
            if (ch is ']' or '>' && depth > 0) { depth--; continue; }
            if (depth == 0) kept.Append(ch);
        }
        o = Flags.Replace(kept.ToString(), "");
        o = Pipes.Replace(o, " ");
        o = Spaces.Replace(o, " ");
        o = Trailing.Replace(o, "").Trim();
        return o.Length == 0 ? o : char.ToUpperInvariant(o[0]) + o[1..];
    }

    // ------------------------------------------------------------------ sections

    private static string WithSlash(string command) => command.StartsWith('/') ? command : "/" + command;

    /// /help and /commands only reopen the same list, a dead end from inside it.
    public static readonly HashSet<string> SheetOnly = ["help", "commands"];
    /// Commands the desktop leaves to its own picker that the slash drawer still lists.
    public static readonly HashSet<string> DrawerPickers = ["model"];

    public static bool IsListed(string command, CommandsCatalog catalog, bool isBotChat = false, bool forDrawer = false)
    {
        var name = BareName(command);
        if ((!forDrawer && SheetOnly.Contains(name)) || (isBotChat && name == "title")) return false;
        if (forDrawer && DrawerPickers.Contains(name)
            && (catalog.Commands?.ContainsKey(WithSlash(name)) == true || Resolve(WithSlash(name), catalog) != null)) return true;
        return IsSuggestion(command, catalog) && !PhoneHidden.Contains(name) && !NativeUnsupported.Contains(name);
    }

    /// The catalog as the Commands list's sections: its own categories, then "Skills" (ranked by use).
    public static IReadOnlyList<CommandSection> Sections(CommandsCatalog catalog, bool isBotChat = false, bool forDrawer = false)
    {
        var seen = new HashSet<string>();
        CommandRow Row(string command, string meta, bool skill)
        {
            seen.Add(WithSlash(command).ToLowerInvariant());
            var described = DesktopDescription(command, meta, catalog);
            return new CommandRow(WithSlash(command), PlainDescription(command, described), skill);
        }
        var groups = catalog.Categories is { Count: > 0 } cats ? cats
            : [new CommandCategory("Commands", catalog.Pairs ?? [])];
        var result = groups.Select(g => new CommandSection(g.Name.Length == 0 ? "Commands" : g.Name,
            [.. g.Pairs.Where(p => IsListed(p.Command, catalog, isBotChat, forDrawer)).Select(p => Row(p.Command, p.Description, false))])).ToList();
        var extensions = (catalog.Pairs ?? []).Where(p => !seen.Contains(WithSlash(p.Command).ToLowerInvariant())
            && IsExtension(p.Command, catalog) && IsListed(p.Command, catalog, isBotChat, forDrawer)).ToList();
        var skills = RankSkills(extensions, catalog.Skills, catalog, pruneUnusedBuiltins: true);
        if (skills.Count > 0) result.Add(new CommandSection("Skills", [.. skills.Select(p => Row(p.Command, p.Description, true))]));
        return [.. result.Where(s => s.Rows.Count > 0)];
    }

    /// Most-used first, A–Z within a tie; `pruneUnusedBuiltins` drops bundled skills never used.
    public static List<(string Command, string Description)> RankSkills(IReadOnlyList<(string Command, string Description)> rows,
        IReadOnlyDictionary<string, SkillCatalogEntry>? skills, CommandsCatalog? catalog, bool pruneUnusedBuiltins)
    {
        if (skills == null) return [.. rows];
        SkillCatalogEntry? Entry((string Command, string) row) => skills.GetValueOrDefault(Canonical(row.Command, catalog));
        long Usage((string, string) row) => Entry(row)?.Usage ?? 0;
        var kept = pruneUnusedBuiltins
            ? rows.Where(r => Entry(r) is not { } e || e.Origin != "bundled" || (e.Usage ?? 0) > 0).ToList()
            : [.. rows];
        return [.. kept.Select((r, i) => (r, i)).OrderByDescending(x => Usage(x.r))
            .ThenBy(x => x.r.Command, StringComparer.Create(CultureInfo.InvariantCulture, CompareOptions.IgnoreCase))
            .ThenBy(x => x.i).Select(x => x.r)];
    }

    public const string FavoritesTitle = "Favorites";

    /// The starred rows in starred order, taken from `sections`; null when none is listed.
    public static CommandSection? FavoritesSection(IReadOnlyList<CommandSection> sections, IReadOnlyList<string> favorites)
    {
        if (favorites.Count == 0) return null;
        var byName = new Dictionary<string, CommandRow>();
        foreach (var row in sections.SelectMany(s => s.Rows)) byName.TryAdd(Normalize(row.Command), row);
        var rows = favorites.Select(f => byName.GetValueOrDefault(Normalize(f))).OfType<CommandRow>().ToList();
        return rows.Count == 0 ? null : new CommandSection(FavoritesTitle, rows);
    }

    /// The Mac's lists: led by Favorites, the starred commands taken out of their own sections below.
    public static IReadOnlyList<CommandSection> FavoritesLeading(IReadOnlyList<CommandSection> shown, IReadOnlyList<CommandSection> all,
        IReadOnlyList<string> favorites)
    {
        if (FavoritesSection(all, favorites) is not { } starred) return shown;
        var names = starred.Rows.Select(r => Normalize(r.Command)).ToHashSet();
        var rest = shown.Select(s => new CommandSection(s.Title, [.. s.Rows.Where(r => !names.Contains(Normalize(r.Command)))]))
            .Where(s => s.Rows.Count > 0);
        return [starred, .. rest];
    }

    /// Rows whose command or description holds every typed word (a leading "/" ignored).
    public static IReadOnlyList<CommandSection> Filter(IReadOnlyList<CommandSection> sections, string query)
    {
        var q = query.ToLowerInvariant();
        if (q.StartsWith('/')) q = q[1..];
        var words = q.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 0) return sections;
        return
        [
            .. sections.Select(s => new CommandSection(s.Title,
                [.. s.Rows.Where(r => words.All($"{r.Command} {r.Description}".ToLowerInvariant().Contains))])).Where(s => s.Rows.Count > 0),
        ];
    }

    /// The ☰ list's order for a search: names that start with the typing (starred first), then names that hold it,
    /// then rows found only by their description; a section led by a better match goes first.
    public static IReadOnlyList<CommandSection> Ranked(IReadOnlyList<CommandSection> sections, string query, IReadOnlyList<string>? favorites = null)
    {
        var q = query.Trim().ToLowerInvariant();
        if (q.StartsWith('/')) q = q[1..];
        if (q.Length == 0) return sections;
        var starred = new Dictionary<string, int>();
        for (var i = 0; i < (favorites?.Count ?? 0); i++) starred.TryAdd(Normalize(favorites![i]), i);
        (int, int, int) Rank(CommandRow? row, int offset)
        {
            if (row == null) return (4, 0, offset);
            var name = BareName(row.Command);
            if (name.StartsWith(q, StringComparison.Ordinal))
                return starred.TryGetValue(Normalize(row.Command), out var at) ? (0, at, offset) : (1, 0, offset);
            return (name.Contains(q) ? 2 : 3, 0, offset);
        }
        var ordered = sections.Select(s => new CommandSection(s.Title,
            [.. s.Rows.Select((r, i) => (r, i)).OrderBy(x => Rank(x.r, x.i)).Select(x => x.r)])).ToList();
        return [.. ordered.Select((s, i) => (s, i)).OrderBy(x => Rank(x.s.Rows.FirstOrDefault(), x.i)).Select(x => x.s)];
    }

    /// What a pick does: a skill or a command that takes more inserts "/cmd "; /model opens the Models list; anything
    /// else sends.
    public static PickAction PickActionFor(CommandRow row, CommandsCatalog? catalog)
    {
        if (row.Skill) return PickAction.Insert;
        var surface = Resolve(row.Command, catalog)?.Surface;
        if (surface is SlashSurface.Picker { Name: "model" }) return PickAction.Models;
        if (surface is SlashSurface.Picker) return PickAction.Insert;
        return ArgumentMode(row.Command, catalog) == null ? PickAction.Send : PickAction.Insert;
    }

    /// The few picks that change the session at once and are hard to take back ask first.
    public static PickConfirmation? Confirmation(string command, bool yoloOn) => BareName(command) switch
    {
        "yolo" => yoloOn ? null : new PickConfirmation("Turn On YOLO?",
            "Dangerous commands will run without asking you first, until you run /yolo again.", "Turn On"),
        "pause" => new PickConfirmation("Pause All Work?", "New work stops until it’s resumed.", "Pause"),
        "undo" => new PickConfirmation("Undo the Last Turn?", "Your last message and its reply are taken back, so you can prompt again.", "Undo"),
        _ => null,
    };
}

/// Slash text (SH:slash.ts:9-39).
public static class SlashCommand
{
    private static readonly Regex Pattern = new(@"^/[^\s/]*(?:\s|$)");

    /// `/usage`, `/plan do it` are commands; `/usr/local/bin` and `run /x` are prose. Tested on the trimmed text.
    public static bool Matches(string text) => Pattern.IsMatch(text.Trim());

    /// Name (lower-cased, no slash; "" for "/", "/ words") and the argument with its outer white space trimmed.
    public static (string Name, string Arg) Parse(string command)
    {
        var s = command.TrimStart('/');
        if (s.Length == 0 || char.IsWhiteSpace(s[0])) return ("", "");
        var end = 0;
        while (end < s.Length && !char.IsWhiteSpace(s[end])) end++;
        return (s[..end].ToLowerInvariant(), s[end..].Trim());
    }
}

/// The commands catalog cache (spec 1x §3.5: 1 hour per key); the newest per account and profile answers typed commands.
public sealed class CommandsCatalogCache
{
    public static CommandsCatalogCache Shared { get; } = new();
    public static readonly TimeSpan FreshFor = TimeSpan.FromHours(1);

    private readonly ConcurrentDictionary<(string Account, string Scope), (CommandsCatalog Catalog, DateTimeOffset At)> _entries = new();
    private readonly ConcurrentDictionary<(string Account, string Profile), CommandsCatalog> _latest = new();

    public CommandsCatalog? Fresh(string account, string scope) =>
        _entries.TryGetValue((account, scope), out var e) && DateTimeOffset.UtcNow - e.At < FreshFor ? e.Catalog : null;

    public CommandsCatalog? Cached(string account, string scope) => _entries.TryGetValue((account, scope), out var e) ? e.Catalog : null;

    public void Store(CommandsCatalog catalog, string account, string scope, string profile)
    {
        _entries[(account, scope)] = (catalog, DateTimeOffset.UtcNow);
        _latest[(account, profile)] = catalog;
    }

    public CommandsCatalog? Latest(string account, string profile) => _latest.GetValueOrDefault((account, profile));

    public void Forget(string account)
    {
        foreach (var k in _entries.Keys.Where(k => k.Account == account)) _entries.TryRemove(k, out _);
        foreach (var k in _latest.Keys.Where(k => k.Account == account)) _latest.TryRemove(k, out _);
    }
}
