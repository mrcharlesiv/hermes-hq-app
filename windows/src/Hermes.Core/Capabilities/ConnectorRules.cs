using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Hermes.Core.Capabilities;

/// Port of HermesKit/Store/McpToolFilter.swift (the web's mcp-tool-filter.ts, spec 3x §5.5): a server's optional
/// `tools.include` (whitelist) / `tools.exclude` (denylist) decide which discovered tools the agent registers.
public static class McpToolFilter
{
    private static List<string>? Names(JsonNode? v) => v is JsonArray a ? [.. a.Select(J.AsString).OfType<string>()] : null;

    public static (List<string>? Include, List<string>? Exclude) Read(JsonNode? server)
    {
        var tools = server.Obj("tools");
        return (Names(tools.Get("include")), Names(tools.Get("exclude")));
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
