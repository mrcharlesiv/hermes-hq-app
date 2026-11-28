using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Hermes.Core.Capabilities;

/// How far a bot may go with one tool of an MCP connector (`tools.permissions[tool]` in the connector's entry;
/// port of HermesKit/Store/McpToolFilter.swift `McpToolPermission`).
/// Hermes itself only knows on and off (`tools.include` / `tools.exclude`, which `Blocked` is written as);
/// the two asking levels are enforced by `hermes-hq-push` 0.9.86+ (`toolPermissions`).
public enum McpToolPermission
{
    AlwaysAllow,
    AutoReview,
    NeedsApproval,
    Blocked,
}

public static class McpToolPermissions
{
    public static readonly McpToolPermission[] All =
    [
        McpToolPermission.AlwaysAllow,
        McpToolPermission.AutoReview,
        McpToolPermission.NeedsApproval,
        McpToolPermission.Blocked,
    ];

    public static string Raw(this McpToolPermission level) => level switch
    {
        McpToolPermission.AlwaysAllow => "always_allow",
        McpToolPermission.AutoReview => "auto_review",
        McpToolPermission.NeedsApproval => "needs_approval",
        _ => "blocked",
    };

    public static McpToolPermission? Parse(string? raw) => raw switch
    {
        "always_allow" => McpToolPermission.AlwaysAllow,
        "auto_review" => McpToolPermission.AutoReview,
        "needs_approval" => McpToolPermission.NeedsApproval,
        "blocked" => McpToolPermission.Blocked,
        _ => null,
    };

    public static string Title(this McpToolPermission level) => level switch
    {
        McpToolPermission.AlwaysAllow => "Always allow",
        McpToolPermission.AutoReview => "Auto-review",
        McpToolPermission.NeedsApproval => "Needs approval",
        _ => "Blocked",
    };

    public static string ShortTitle(this McpToolPermission level) => level switch
    {
        McpToolPermission.AlwaysAllow => "Always",
        McpToolPermission.AutoReview => "Auto",
        McpToolPermission.NeedsApproval => "Approve",
        _ => "Blocked",
    };

    public static string Subtitle(this McpToolPermission level) => level switch
    {
        McpToolPermission.AlwaysAllow => "Runs without asking",
        McpToolPermission.AutoReview => "Asks before a call that changes something",
        McpToolPermission.NeedsApproval => "Asks you every time",
        _ => "Hidden from this bot",
    };

    public static string Glyph(this McpToolPermission level) => level switch
    {
        McpToolPermission.AlwaysAllow => "\uE83D",
        McpToolPermission.AutoReview => "\uE945",
        McpToolPermission.NeedsApproval => "\uE7BA",
        _ => "\uE711",
    };
}

/// Port of HermesKit/Store/McpToolFilter.swift (the web's mcp-tool-filter.ts, spec 3x §5.5): a server's optional
/// `tools.include` (whitelist) / `tools.exclude` (denylist) decide which discovered tools the agent registers, and
/// `tools.permissions` holds per-tool asking levels enforced by the add-on.
public static class McpToolFilter
{
    private static List<string>? Names(JsonNode? v) => v is JsonArray a ? [.. a.Select(J.AsString).OfType<string>()] : null;

    public static (List<string>? Include, List<string>? Exclude) Read(JsonNode? server)
    {
        var tools = server.Obj("tools");
        return (Names(tools.Get("include")), Names(tools.Get("exclude")));
    }

    /// Reads the stored `tools.permissions` map (tool name → permission).
    public static Dictionary<string, McpToolPermission> ReadPermissions(JsonNode? server)
    {
        var outMap = new Dictionary<string, McpToolPermission>(StringComparer.Ordinal);
        var map = server.Obj("tools").Obj("permissions");
        if (map == null) return outMap;
        foreach (var (k, v) in map)
        {
            if (v is JsonValue jv && jv.TryGetValue(out string? raw) && McpToolPermissions.Parse(raw) is { } perm)
                outMap[k] = perm;
        }
        return outMap;
    }

    /// The level stored for `name`, whether or not the tool is on: what it comes back as when unblocked.
    /// Nothing stored (or stored `blocked`) maps to `AlwaysAllow`.
    public static McpToolPermission StoredLevel(JsonNode? server, string name)
    {
        var level = ReadPermissions(server).GetValueOrDefault(name, McpToolPermission.AlwaysAllow);
        return level == McpToolPermission.Blocked ? McpToolPermission.AlwaysAllow : level;
    }

    /// Effective permission for `name` on `server`: a tool that is off is `Blocked`, whatever is stored for it.
    public static McpToolPermission PermissionFor(JsonNode? server, string name) =>
        !IsEnabled(server, name) ? McpToolPermission.Blocked : StoredLevel(server, name);

    /// Effective permissions for all `discovered` tools.
    public static Dictionary<string, McpToolPermission> Permissions(JsonNode? server, IEnumerable<string> discovered)
    {
        var outMap = new Dictionary<string, McpToolPermission>(StringComparer.Ordinal);
        foreach (var name in discovered) outMap[name] = PermissionFor(server, name);
        return outMap;
    }

    /// Writes the levels: blocked tools through `tools.include` / `tools.exclude` (`SetDisabled`), the two asking
    /// levels into `tools.permissions`. Preserves entries for undiscovered tools and preserves a blocked tool's
    /// stored asking level so unblocking a tool never silently drops its approval requirement.
    public static JsonNode SetPermissions(JsonNode server, IReadOnlyDictionary<string, McpToolPermission> permissions, IReadOnlyList<string> discovered)
    {
        var blocked = discovered.Where(n => permissions.TryGetValue(n, out var level) && level == McpToolPermission.Blocked).ToList();
        var updated = SetDisabled(server, blocked, discovered);
        if (updated is not JsonObject next) return updated;

        var tools = next.Obj("tools") is { } t ? (JsonObject)t.DeepClone() : new JsonObject();
        var permMap = new JsonObject();
        // Only well-formed asking levels are preserved; junk values left in the wrong shape are cleaned up.
        foreach (var (name, level) in ReadPermissions(updated))
        {
            if (level is McpToolPermission.AutoReview or McpToolPermission.NeedsApproval)
                permMap[name] = level.Raw();
        }
        foreach (var name in discovered)
        {
            if (!permissions.TryGetValue(name, out var level)) continue;
            switch (level)
            {
                case McpToolPermission.AutoReview:
                    permMap[name] = McpToolPermission.AutoReview.Raw();
                    break;
                case McpToolPermission.NeedsApproval:
                    permMap[name] = McpToolPermission.NeedsApproval.Raw();
                    break;
                case McpToolPermission.AlwaysAllow:
                    permMap.Remove(name);
                    break;
                case McpToolPermission.Blocked:
                    break; // preserves what was stored
            }
        }
        if (permMap.Count == 0) tools.Remove("permissions");
        else tools["permissions"] = permMap;

        if (tools.Count == 0) next.Remove("tools");
        else next["tools"] = tools;
        return next;
    }

    /// Bottom-bar summary text for pending tool edits (`ConnectorPageModel.draftSummary`).
    public static string DraftSummary(bool levels, int changedCount, int blockedCount, int backOnCount, int autoReviewCount, int needsApprovalCount)
    {
        if (!levels)
            return $"{CapabilitiesWords.Plural(blockedCount, "tool", "tools")} off, {(backOnCount == 0 ? "none" : backOnCount.ToString())} back on";

        var parts = new List<string>(3);
        if (needsApprovalCount > 0) parts.Add($"{needsApprovalCount} {(needsApprovalCount == 1 ? "asks" : "ask")} every time");
        if (autoReviewCount > 0) parts.Add($"{autoReviewCount} auto-review");
        if (blockedCount > 0) parts.Add($"{blockedCount} blocked");
        if (parts.Count == 0) parts.Add("all run without asking");
        return $"{CapabilitiesWords.Plural(changedCount, "change", "changes")} · {string.Join(", ", parts)}";
    }

    /// An explicit `include` (even []) is a whitelist: the runtime registers nothing for `[]`.
    public static bool IsEnabled(JsonNode? server, string name)
    {
        var (include, exclude) = Read(server);
        if (include != null) return include.Contains(name);
        return !(exclude?.Contains(name) ?? false);
    }

    /// `setDisabledTools`: keeps the entry's mode and every stored name that was not discovered this time.
    public static JsonNode SetDisabled(JsonNode server, IEnumerable<string> disabled, IReadOnlyList<string> discovered)
    {
        if (server is not JsonObject src) return server.DeepClone();
        var next = (JsonObject)src.DeepClone();
        var (include, exclude) = Read(server);
        var off = disabled.ToHashSet(); var seen = discovered.ToHashSet();
        var tools = next.Obj("tools") is { } t ? (JsonObject)t.DeepClone() : new JsonObject();
        IEnumerable<string> Kept(List<string>? stored) => (stored ?? []).Where(n => !seen.Contains(n));
        if (include != null)
            tools["include"] = new JsonArray([.. discovered.Where(n => !off.Contains(n)).Concat(Kept(include)).Select(n => (JsonNode)n)]);
        else
        {
            var names = discovered.Where(off.Contains).Concat(Kept(exclude)).ToList();
            if (names.Count == 0) tools.Remove("exclude");
            else tools["exclude"] = new JsonArray([.. names.Select(n => (JsonNode)n)]);
        }
        if (tools.Count == 0) next.Remove("tools"); else next["tools"] = tools;
        return next;
    }

    public static int CountEnabled(JsonNode? server, IEnumerable<string> names) => names.Count(n => IsEnabled(server, n));

    /// A Hermes that redacts `/api/config` must never have a redacted secret written back: any string carrying a
    /// redaction mark makes the tool editor read-only.
    public static bool LooksRedacted(JsonNode? value) => value switch
    {
        JsonValue v when v.TryGetValue(out string? s) => s.Contains('•') || s.Contains("***") || s == McpEntryMask.MASK,
        JsonArray a => a.Any(LooksRedacted),
        JsonObject o => o.Any(p => LooksRedacted(p.Value)),
        _ => false,
    };
}

/// Readable connector names and the app's own words for a failed check (McpToolFilter.swift `ConnectorTitle`).
public static class ConnectorTitle
{
    public static readonly IReadOnlyDictionary<string, string> Known = new Dictionary<string, string>
    {
        ["github"] = "GitHub", ["gitlab"] = "GitLab", ["linkedin"] = "LinkedIn", ["youtube"] = "YouTube", ["hubspot"] = "HubSpot",
        ["clickup"] = "ClickUp", ["openai"] = "OpenAI", ["postgresql"] = "PostgreSQL", ["mongodb"] = "MongoDB", ["icloud"] = "iCloud",
        ["paypal"] = "PayPal", ["bigquery"] = "BigQuery", ["wordpress"] = "WordPress", ["airtable"] = "Airtable", ["composio"] = "Composio",
    };

    public static string Title(string name)
    {
        if (Known.TryGetValue(name.ToLowerInvariant(), out var k)) return k;
        var words = name.Split(['_', '-', ' '], StringSplitOptions.RemoveEmptyEntries).Select(w =>
        {
            var lower = w.ToLowerInvariant();
            if (lower == "mcp") return "MCP";
            if (lower == "api") return "API";
            if (Known.TryGetValue(lower, out var known)) return known;
            return char.ToUpperInvariant(w[0]) + w[1..];
        }).ToList();
        return words.Count == 0 ? name : string.Join(" ", words);
    }

    public const string BusyCheck = "The gateway was too busy to check this connector. Try again.";
    private static readonly Regex ClientTimeout = new(@"took too long to answer|didn.t answer in time|may be busy|too busy|gateway (?:is |was )?busy|request timed out after \d+", RegexOptions.IgnoreCase);

    public static bool IsBusy(string error) => ClientTimeout.IsMatch(error);

    /// Safe, actionable guidance: never shows raw provider URLs, headers or tokens.
    public static string FailureDetail(string error, bool hasCommand, bool hasUrl)
    {
        if (IsBusy(error)) return BusyCheck;
        if (!hasCommand && !hasUrl) return "This connector has no server address or launch command. Correct its gateway configuration, then try again.";
        var text = error.ToLowerInvariant();
        if (Regex.IsMatch(text, "no such file|enoent|cannot find module|module not found"))
            return "A required program or file is missing on the gateway. Install it or correct the launch path there, then try again.";
        if (Regex.IsMatch(text, "401|403|unauthori[sz]ed|token|oauth|api.?key|authentication"))
            return "The connector needs valid credentials on the gateway. Update its sign-in or API key there, then try again.";
        if (Regex.IsMatch(text, "timeout|timed out"))
            return "The gateway could not reach this connector in time. Check the server address and network, then try again.";
        if (Regex.IsMatch(text, "reset|refused|closed|connect"))
            return "The connector ended or refused the connection. Check that its server is running and its address is correct, then try again.";
        return "The gateway could not start this connector. Check its launch command, server address and gateway logs, then try again.";
    }
}

/// Add a Connector's form (App/Capabilities/AddConnectorController.swift `ConnectorDraft`).
public sealed class ConnectorDraft
{
    public sealed class Pair { public string Key { get; set; } = ""; public string Value { get; set; } = ""; }
    public enum Kinds { Web, Command }
    public enum Auths { None, OAuth, Bearer }

    public static string AuthTitle(Auths a) => a switch { Auths.None => "None", Auths.OAuth => "OAuth", _ => "Bearer Token" };

    public string Name { get; set; } = "";
    public Kinds Kind { get; set; } = Kinds.Web;
    public string Url { get; set; } = "";
    public Auths Auth { get; set; } = Auths.None;
    public string Token { get; set; } = "";
    public List<Pair> Headers { get; } = [];
    public string Command { get; set; } = "";
    public List<Pair> Args { get; } = [];
    public List<Pair> Env { get; } = [];
    public string Cwd { get; set; } = "";

    private static readonly Regex NameRule = new("^[A-Za-z0-9._-]{1,64}$");

    public string TrimmedName => Name.Trim();
    public bool NameValid => NameRule.IsMatch(TrimmedName);
    public bool NameTaken(IEnumerable<string> existing) => existing.Any(e => string.Equals(e, TrimmedName, StringComparison.OrdinalIgnoreCase));

    public bool UrlValid =>
        Uri.TryCreate(Url.Trim(), UriKind.Absolute, out var u) && (u.Scheme == "http" || u.Scheme == "https") && u.Host.Length > 0;

    private static bool PairsComplete(IEnumerable<Pair> pairs) => pairs.All(p => p.Key.Trim().Length > 0 || p.Value.Length == 0);

    public bool IsComplete(IEnumerable<string> existing)
    {
        if (!NameValid || NameTaken(existing)) return false;
        return Kind == Kinds.Web
            ? UrlValid && PairsComplete(Headers) && (Auth != Auths.Bearer || Token.Trim().Length > 0)
            : Command.Trim().Length > 0 && PairsComplete(Env);
    }

    public bool HasContent => Name.Length > 0 || Kind != Kinds.Web || Url.Length > 0 || Auth != Auths.None || Token.Length > 0
        || Headers.Count > 0 || Command.Length > 0 || Args.Count > 0 || Env.Count > 0 || Cwd.Length > 0;

    private static JsonObject Map(IEnumerable<Pair> pairs)
    {
        var o = new JsonObject();
        foreach (var p in pairs) if (p.Key.Trim() is { Length: > 0 } k) o[k] = p.Value;
        return o;
    }

    /// The entry `mcp.servers.add` takes. A bearer token never goes in it (`Bearer` travels beside it).
    public JsonObject Config
    {
        get
        {
            var o = new JsonObject();
            if (Kind == Kinds.Web)
            {
                o["url"] = Url.Trim();
                if (Auth == Auths.OAuth) o["auth"] = "oauth";
                var h = Map(Headers);
                if (h.Count > 0) o["headers"] = h;
            }
            else
            {
                o["command"] = Command.Trim();
                var args = Args.Select(a => a.Value).Where(v => v.Length > 0).ToList();
                if (args.Count > 0) o["args"] = new JsonArray([.. args.Select(a => (JsonNode)a)]);
                var env = Map(Env);
                if (env.Count > 0) o["env"] = env;
                if (Cwd.Trim() is { Length: > 0 } cwd) o["cwd"] = cwd;
            }
            return o;
        }
    }

    public string? Bearer => Kind == Kinds.Web && Auth == Auths.Bearer ? Token.Trim() : null;

    /// The words for a refused add; null when the name is taken (the form says so under the name).
    public static string? Reason(Exception error)
    {
        if (error is not Net.GatewayException { Code: "rpc" } rpc) return CapabilitiesWords.Detail(error);
        var message = rpc.Message.ToLowerInvariant();
        if (rpc.RpcCode == 4090) return message.Contains("already exists") ? null : "A plugin already provides a connector with this name.";
        if (rpc.RpcCode == 4063) return "Enter a web address or a command.";
        if (rpc.RpcCode == 4001 && message.Contains("suspicious"))
            return "Your gateway refused this command because it looks unsafe. Check the command and its arguments.";
        return McpEntryMask.Phone.Text(rpc.Message);
    }
}

/// A connector's log (ConnectorAdvancedController.swift `ConnectorLogsModel`): its last run's section of the MCP log.
public static class ConnectorLogs
{
    private static readonly Regex Marker = new("^=+ starting MCP server '(.+)' =+$");

    public static List<string>? Section(IReadOnlyList<string> lines, string name)
    {
        int? start = null;
        for (var i = 0; i < lines.Count; i++)
            if (Marker.Match(lines[i].Trim()) is { Success: true } m && m.Groups[1].Value == name) start = i;
        if (start is not { } s) return null;
        var o = new List<string>();
        foreach (var line in lines.Skip(s + 1))
        {
            if (Marker.IsMatch(line.Trim())) break;
            o.Add(line);
        }
        return o;
    }

    public static List<string> Clean(IReadOnlyList<string> lines) =>
        [.. lines.Skip(Math.Max(0, lines.Count - 500)).Select(line =>
        {
            var masked = McpEntryMask.Phone.Text(line.Length > 2000 ? line[..2000] : line);
            return line.Length > 2000 ? masked + "…" : masked;
        })];
}

/// The connector sign-in page must be https and must send the browser back to this PC's listener
/// (App/Capabilities/McpSignIn.swift `accepts`). Loopback http is allowed only when `allowLoopbackHttp` (the stand-in).
public static class McpSignInRules
{
    public static Uri? Accepts(string authUrl, string redirect, bool allowLoopbackHttp = false)
    {
        if (!Uri.TryCreate(authUrl, UriKind.Absolute, out var url)) return null;
        var allowed = url.Scheme == "https" || (allowLoopbackHttp && url.Scheme == "http" && url.Host is "127.0.0.1" or "localhost");
        if (!allowed) return null;
        var q = url.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Select(p => p.Split('=', 2)).FirstOrDefault(p => Uri.UnescapeDataString(p[0]) == "redirect_uri");
        return q is { Length: 2 } && Uri.UnescapeDataString(q[1].Replace('+', ' ')) == redirect ? url : null;
    }

    public static string TooOld =>
        $"This gateway’s Hermes is too old to sign in to connectors from your {Gateways.DeviceWord.Name}. Update Hermes on {Gateways.HostWord.UpdateTarget}, or sign in there.";
}
