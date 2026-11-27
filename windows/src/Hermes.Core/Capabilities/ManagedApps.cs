using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Gateways;
using Hermes.Core.Net;
using Hermes.Core.Rpc;

namespace Hermes.Core.Capabilities;

// Managed apps: the apps a bot reaches through its Nous account (HermesKit/Connectors/*: ManagedConnectorsWire,
// ManagedConnectorsClient, ManagedApps). The gateway's `connectors.*` RPCs; errors carry `data.reason`.

public enum ConnectorErrorReason
{
    InvalidParams, NotOwner, UnsupportedRuntime, ConnectorRequestFailed, InvalidConnectorResponse, UnknownTarget, LinkStillValid,
    ReissueRefused, UnknownOperation, InvalidAnswer, NeedsNousAuth, ConnectorNotFound, ToolsUnavailable, ConnectorsUnavailable,
    CatalogUnavailable, AccountsUnavailable, ConnectionNotFound, PolicyUnavailable, PolicyConflict, ForbiddenScope, OrgRequired,
    OrgAccessDenied, InvalidPolicy, AliasTaken,
}

public static class ConnectorErrorReasons
{
    private static readonly Dictionary<string, ConnectorErrorReason> Wire = new()
    {
        ["INVALID_PARAMS"] = ConnectorErrorReason.InvalidParams, ["NOT_OWNER"] = ConnectorErrorReason.NotOwner,
        ["UNSUPPORTED_RUNTIME"] = ConnectorErrorReason.UnsupportedRuntime, ["CONNECTOR_REQUEST_FAILED"] = ConnectorErrorReason.ConnectorRequestFailed,
        ["INVALID_CONNECTOR_RESPONSE"] = ConnectorErrorReason.InvalidConnectorResponse, ["UNKNOWN_TARGET"] = ConnectorErrorReason.UnknownTarget,
        ["LINK_STILL_VALID"] = ConnectorErrorReason.LinkStillValid, ["REISSUE_REFUSED"] = ConnectorErrorReason.ReissueRefused,
        ["UNKNOWN_OPERATION"] = ConnectorErrorReason.UnknownOperation, ["INVALID_ANSWER"] = ConnectorErrorReason.InvalidAnswer,
        ["NEEDS_NOUS_AUTH"] = ConnectorErrorReason.NeedsNousAuth, ["CONNECTOR_NOT_FOUND"] = ConnectorErrorReason.ConnectorNotFound,
        ["TOOLS_UNAVAILABLE"] = ConnectorErrorReason.ToolsUnavailable, ["CONNECTORS_UNAVAILABLE"] = ConnectorErrorReason.ConnectorsUnavailable,
        ["CATALOG_UNAVAILABLE"] = ConnectorErrorReason.CatalogUnavailable, ["ACCOUNTS_UNAVAILABLE"] = ConnectorErrorReason.AccountsUnavailable,
        ["CONNECTION_NOT_FOUND"] = ConnectorErrorReason.ConnectionNotFound, ["POLICY_UNAVAILABLE"] = ConnectorErrorReason.PolicyUnavailable,
        ["POLICY_CONFLICT"] = ConnectorErrorReason.PolicyConflict, ["FORBIDDEN_SCOPE"] = ConnectorErrorReason.ForbiddenScope,
        ["ORG_REQUIRED"] = ConnectorErrorReason.OrgRequired, ["ORG_ACCESS_DENIED"] = ConnectorErrorReason.OrgAccessDenied,
        ["INVALID_POLICY"] = ConnectorErrorReason.InvalidPolicy, ["ALIAS_TAKEN"] = ConnectorErrorReason.AliasTaken,
    };

    public static ConnectorErrorReason? Parse(string? raw) => raw != null && Wire.TryGetValue(raw, out var r) ? r : null;

    public static string Words(this ConnectorErrorReason reason) => reason switch
    {
        ConnectorErrorReason.InvalidParams => "Hermes didn’t accept this request. Update Hermes, then try again.",
        ConnectorErrorReason.NotOwner => "This can only be changed from the place it was started.",
        ConnectorErrorReason.UnsupportedRuntime => "This bot’s apps are managed on the computer it runs on.",
        ConnectorErrorReason.ConnectorRequestFailed => "The connector service didn’t answer. Try again.",
        ConnectorErrorReason.InvalidConnectorResponse => "The connector service sent an answer Hermes couldn’t read. Try again later.",
        ConnectorErrorReason.UnknownTarget => "That sign-in is no longer open. Connect again.",
        ConnectorErrorReason.LinkStillValid => "The sign-in link is still open. Finish the sign-in in your browser, or open the link again.",
        ConnectorErrorReason.ReissueRefused => "This sign-in can’t be started again. Close it, then connect again.",
        ConnectorErrorReason.UnknownOperation => "That sign-in has already ended.",
        ConnectorErrorReason.InvalidAnswer => "That answer wasn’t accepted. Try again.",
        ConnectorErrorReason.NeedsNousAuth => "Sign in to Nous to use managed apps.",
        ConnectorErrorReason.ConnectorNotFound => "This app is no longer in the catalog.",
        ConnectorErrorReason.ToolsUnavailable => "Tool list unavailable.",
        ConnectorErrorReason.ConnectorsUnavailable => "Managed apps are not available for this account yet.",
        ConnectorErrorReason.CatalogUnavailable => "The app catalog is unavailable right now. Try again later.",
        ConnectorErrorReason.AccountsUnavailable => "Nous could not reach your connected accounts right now. Try again later.",
        ConnectorErrorReason.ConnectionNotFound => "That sign-in was already removed.",
        ConnectorErrorReason.PolicyUnavailable => "Rules cannot be changed right now.",
        ConnectorErrorReason.PolicyConflict => "Someone changed this rule while you were editing.",
        ConnectorErrorReason.ForbiddenScope => "This account isn’t allowed to change connector rules.",
        ConnectorErrorReason.OrgRequired => "Select an organization in Nous to manage connector rules.",
        ConnectorErrorReason.OrgAccessDenied => "This account cannot manage connectors for this organization.",
        ConnectorErrorReason.InvalidPolicy => "That change isn’t allowed by your connector rules.",
        _ => "That name is already used.",
    };
}

public sealed class ConnectorFailure : Exception
{
    public ConnectorErrorReason? Reason { get; }
    public long? Code { get; }

    public ConnectorFailure(ConnectorErrorReason? reason, long? code, string message) : base(message) { Reason = reason; Code = code; }

    public static ConnectorFailure From(Exception error) => error switch
    {
        ConnectorFailure f => f,
        GatewayException { Code: "rpc" } g => new(ConnectorErrorReasons.Parse(J.Parse(g.Body ?? "").Str("reason")), g.RpcCode, g.Message),
        GatewayException g => new(null, null, g.Message) { Transport = g.Code is "offline" or "timeout" },
        _ => new(null, null, error.Message),
    };

    public bool Transport { get; private init; }

    public bool TooOld => Code == -32601 || Message.Contains("unknown method", StringComparison.OrdinalIgnoreCase)
        || Message.Contains("method not found", StringComparison.OrdinalIgnoreCase);

    public static string TooOldWords => $"This gateway’s Hermes doesn’t have managed apps yet. Update Hermes on {HostWord.UpdateTarget} to use them.";

    public string Words(string fallback = "Something went wrong. Try again.")
    {
        if (Reason is { } r) return r.Words();
        if (TooOld) return TooOldWords;
        if (Transport) return "Can’t reach your gateway right now. Try again when it’s back.";
        return fallback;
    }
}

public sealed record ConnectorListRow(string Connector, bool Enabled, bool Connected, string? ConnectionStatus, string? StatusReason,
    IReadOnlyList<string> GatewayDisabledTools);

public sealed record ConnectorListResult(bool Available, IReadOnlyList<ConnectorListRow> Connectors);

public sealed record ConnectorCatalogRow(string Slug, string Name, string Description, string Category, string? LogoUrl);

public sealed record ConnectorAccountRow(string ConnectionId, string Connector, string Status, string? StatusReason, string Label,
    string? Alias, bool Active, string CreatedAt, string UpdatedAt, bool Disabled = false)
{
    public string Name => Alias ?? Label;
    public bool NeedsReconnect => Status is "expired" or "failed" or "inactive" or "revoked";

    public string? StatusWords
    {
        get
        {
            if (Disabled) return "Replaced by a reconnect";
            return Status switch
            {
                "active" => null,
                "expired" => "Access expired",
                "failed" => "Couldn’t connect",
                "inactive" => "Inactive",
                "pending" => "Waiting for sign-in",
                "revoked" => "Access revoked",
                _ => Status.Length == 0 ? Status : char.ToUpperInvariant(Status[0]) + Status[1..],
            };
        }
    }

    public static bool AliasValid(string alias) => Regex.IsMatch(alias, "^[a-z0-9][a-z0-9-]{0,31}$");

    public static string? AliasProblem(string alias, IEnumerable<ConnectorAccountRow> among, string? renaming = null)
    {
        if (!AliasValid(alias)) return AccountWords.AliasInvalid;
        return among.Any(a => a.Alias == alias && a.ConnectionId != renaming) ? AccountWords.AliasTaken : null;
    }
}

public static class AccountWords
{
    public const string AliasHint = "Lowercase letters, numbers and dashes, up to 32. For example work or home.";
    public const string AliasInvalid = "Use lowercase letters, numbers and dashes, starting with a letter or number.";
    public const string AliasTaken = "That name is already used.";
    public const string RenameGone = "That account is no longer there. It was removed or replaced by a reconnect.";
    public const string RemoveBody = "Hermes stops acting as this account. Your other accounts stay connected.";
    public static string RemoveTitle(string app, string name) => $"Remove the {name} {app} account?";
}

public sealed record ConnectorTool(string Slug, string Name, string Description, string Facet, IReadOnlyList<string> Hints,
    IReadOnlyList<string> Categories, bool Deprecated);

public sealed record ConnectorToolsResult(string Connector, bool Stale, IReadOnlyList<ConnectorTool> Tools);

public sealed record ConnectorPolicyRules(IReadOnlySet<string>? Allowed, IReadOnlySet<string> Denied, string Revision,
    IReadOnlyList<string> TagsEnable, IReadOnlyList<string> TagsDisable, IReadOnlyDictionary<string, IReadOnlyList<string>> Tools)
{
    public bool Allows(string slug) => (Allowed == null || Allowed.Contains(slug)) && !Denied.Contains(slug);
}

public sealed record ConnectorPolicyView(ConnectorPolicyRules? Member, IReadOnlyList<ConnectorPolicyRules> Others)
{
    public static readonly ConnectorPolicyView Empty = new(null, []);
    public bool MemberEnables(string slug) => Member?.Allows(slug) ?? true;
    public bool OrgLocks(string slug) => Others.Any(o => !o.Allows(slug));
    public IReadOnlyList<string> MemberDisabledTools(string slug) => Member?.Tools.GetValueOrDefault(slug) ?? [];
    public string? MemberRevision => Member?.Revision;

    public HashSet<string> OrgLockedTools(string slug, IEnumerable<ConnectorTool> tools)
    {
        var locked = new HashSet<string>();
        foreach (var rules in Others)
        {
            locked.UnionWith(rules.Tools.GetValueOrDefault(slug) ?? []);
            foreach (var t in tools)
            {
                var hints = t.Hints.ToHashSet();
                var byTag = rules.TagsDisable.Any(hints.Contains);
                var missing = rules.TagsEnable.Count > 0 && !rules.TagsEnable.Any(hints.Contains);
                if (byTag || missing) locked.Add(t.Slug);
            }
        }
        return locked;
    }
}

public enum ConnectionTargetState { Pending, Initiated, Connected, Skipped, Failed, Expired, NotConnected }

public sealed record ConnectionTarget(string Name, ConnectionTargetState State, string Detail, string? ConnectUrl, string ConnectionId);

public sealed record ConnectionOperation(string OpId, IReadOnlyList<string> Connectors, long Seq, double DeadlineAt, bool Settled,
    string? SettledBy, IReadOnlyList<ConnectionTarget> Targets)
{
    public ConnectionTarget? Target(string slug) => Targets.FirstOrDefault(t => t.Name == slug);
    public string? Link => Targets.FirstOrDefault(t => t.ConnectUrl != null)?.ConnectUrl;

    /// A newer snapshot of the same operation (a broadcast must move `seq` on). Broadcasts carry no link: the held one stays.
    public ConnectionOperation? Applying(ConnectionOperation snapshot, bool broadcast)
    {
        if (snapshot.OpId != OpId || (broadcast ? snapshot.Seq <= Seq : snapshot.Seq < Seq)) return null;
        var targets = snapshot.Targets.Select(t =>
        {
            if (Targets.FirstOrDefault(h => h.Name == t.Name) is not { } held) return t;
            var row = t;
            var reissued = t.State == ConnectionTargetState.Initiated && held.State != ConnectionTargetState.Initiated;
            if (row.ConnectUrl == null && !reissued && t.State == ConnectionTargetState.Initiated) row = row with { ConnectUrl = held.ConnectUrl };
            if (row.ConnectionId.Length == 0) row = row with { ConnectionId = held.ConnectionId };
            return row;
        }).ToList();
        return this with { Seq = snapshot.Seq, DeadlineAt = snapshot.DeadlineAt, Settled = snapshot.Settled, SettledBy = snapshot.SettledBy, Targets = targets };
    }
}

public static class ManagedWire
{
    private static List<string> Strings(JsonNode? v) => [.. (v as JsonArray ?? []).Select(s => J.AsString(s)?.Trim()).Where(s => !string.IsNullOrEmpty(s)).Select(s => s!)];

    public static ConnectorListResult List(JsonNode? v)
    {
        var rows = (v.Arr("connectors") ?? []).Select(r => r.Text("connector") is { } slug
            ? new ConnectorListRow(slug, r.Bool("enabled") ?? true, r.Bool("connected") ?? false, r.Text("connection_status"),
                r.Text("status_reason"), Strings(r.Get("gateway_disabled_tools"))) : null).OfType<ConnectorListRow>().ToList();
        return new(v.Bool("available") ?? rows.Count > 0, rows);
    }

    public static List<ConnectorCatalogRow> Catalog(JsonNode? v)
    {
        var seen = new HashSet<string>();
        return [.. (v.Arr("connectors") ?? []).Select(r => r.Text("slug") is { } slug && seen.Add(slug)
            ? new ConnectorCatalogRow(slug, r.Text("name") ?? Title(slug), r.Text("description") ?? "", r.Text("category") ?? "", r.Text("logo_url"))
            : null).OfType<ConnectorCatalogRow>()];
    }

    public static List<ConnectorAccountRow> Accounts(JsonNode? v) =>
        [.. (v.Arr("accounts") ?? []).Select(r => r.Text("connection_id") is { } id && r.Text("connector") is { } c
            ? new ConnectorAccountRow(id, c, r.Text("status") ?? "active", r.Text("status_reason"), r.Text("label") ?? "", r.Text("alias"),
                r.Bool("active") ?? false, r.Text("created_at") ?? "", r.Text("updated_at") ?? "", r.Bool("disabled") ?? false)
            : null).OfType<ConnectorAccountRow>()];

    public static ConnectorToolsResult Tools(JsonNode? v) => new(v.Text("connector") ?? "", v.Bool("stale") ?? false,
        [.. (v.Arr("tools") ?? []).Select(r => r.Text("slug") is { } slug
            ? new ConnectorTool(slug, r.Text("name") ?? slug, r.Text("description") ?? "", r.Text("facet") ?? "unclassified",
                Strings(r.Get("hints")), Strings(r.Get("categories")), r.Bool("deprecated") ?? false) : null).OfType<ConnectorTool>()]);

    public static ConnectorPolicyView Policy(JsonNode? v)
    {
        var layers = (v.Arr("layers") ?? []).OfType<JsonNode>().ToList();
        var member = layers.FirstOrDefault(l => l.Str("kind") == "member") is { } m ? Rules(m) : null;
        return new(member, [.. layers.Where(l => l.Str("kind") != "member").Select(Rules)]);
    }

    public static ConnectorPolicyRules Rules(JsonNode? layer)
    {
        var body = layer.Get("body");
        var revision = layer.Text("revision") ?? "";
        var tools = new Dictionary<string, IReadOnlyList<string>>();
        foreach (var (slug, list) in body.Obj("tools") ?? []) tools[slug] = Strings(list);
        var enable = Strings(body.Obj("tags").Get("enable")); var disable = Strings(body.Obj("tags").Get("disable"));
        return body.Str("mode") switch
        {
            "deny-all" => new(new HashSet<string>(), new HashSet<string>(), revision, [], [], new Dictionary<string, IReadOnlyList<string>>()),
            "allow" => new(Strings(body.Get("connectors")).ToHashSet(), new HashSet<string>(), revision, enable, disable, tools),
            "deny" => new(null, Strings(body.Get("disabled_connectors")).ToHashSet(), revision, enable, disable, tools),
            _ => new(null, new HashSet<string>(), revision, [], [], new Dictionary<string, IReadOnlyList<string>>()),
        };
    }

    public static ConnectionOperation? Operation(JsonNode? v, IReadOnlyList<string>? connectors = null)
    {
        if (v.Text("op_id") is not { } op) return null;
        var targets = (v.Arr("targets") ?? []).Select(r => r.Text("name") is { } n
            ? new ConnectionTarget(n, State(r.Text("state")), r.Text("detail") ?? "", r.Text("connect_url"), r.Text("connection_id") ?? "")
            : null).OfType<ConnectionTarget>().ToList();
        var settled = v.Bool("settled") ?? (v.Get("settled_at") is { } s && s.GetValueKind() != System.Text.Json.JsonValueKind.Null);
        return new(op, connectors is { Count: > 0 } ? connectors : [.. targets.Select(t => t.Name)], v.Int("seq") ?? 0, v.Num("deadline_at") ?? 0,
            settled, v.Text("settled_by"), targets);
    }

    private static ConnectionTargetState State(string? s) => s switch
    {
        "initiated" => ConnectionTargetState.Initiated,
        "connected" => ConnectionTargetState.Connected,
        "skipped" => ConnectionTargetState.Skipped,
        "failed" => ConnectionTargetState.Failed,
        "expired" => ConnectionTargetState.Expired,
        "not_connected" => ConnectionTargetState.NotConnected,
        _ => ConnectionTargetState.Pending,
    };

    public static string Title(string slug) =>
        string.Join(" ", slug.Split(['_', '-'], StringSplitOptions.RemoveEmptyEntries).Select(w => char.ToUpperInvariant(w[0]) + w[1..]));
}

public enum ManagedState { Available, Broken, Connected, Connecting, Expired, Off, Unknown }
public enum ManagedVerb { Connect, Reconnect, TryAgain, StopWaiting, TurnBackOn }

public sealed record ManagedApp(string Slug, string Name, string Description, string Category, string? LogoUrl, bool InCatalog,
    bool Connected, string? ConnectionStatus, string? StatusReason, string? AccountLabel, string? ConnectedAt,
    IReadOnlyList<string> DisabledTools, bool Enabled, bool OrgLocked)
{
    public IReadOnlyList<ConnectorAccountRow> Accounts { get; init; } = [];
    public IReadOnlyList<ConnectorAccountRow> Retired { get; init; } = [];

    public ManagedState State
    {
        get
        {
            if (OrgLocked || !Enabled) return ManagedState.Off;
            if (!Connected) return ManagedState.Available;
            return (ConnectionStatus ?? "active") switch
            {
                "active" => ManagedState.Connected,
                "pending" => ManagedState.Connecting,
                "failed" => ManagedState.Broken,
                "expired" or "inactive" or "revoked" => ManagedState.Expired,
                _ => ManagedState.Unknown,
            };
        }
    }

    public ManagedVerb? Verb
    {
        get
        {
            if (OrgLocked) return null;
            if (!Enabled) return ManagedVerb.TurnBackOn;
            return State switch
            {
                ManagedState.Available => ManagedVerb.Connect,
                ManagedState.Connecting => ManagedVerb.StopWaiting,
                ManagedState.Broken => ManagedVerb.TryAgain,
                ManagedState.Expired => ManagedVerb.Reconnect,
                _ => null,
            };
        }
    }

    public static string VerbTitle(ManagedVerb verb) => verb switch
    {
        ManagedVerb.Connect => "Connect",
        ManagedVerb.Reconnect => "Reconnect",
        ManagedVerb.TryAgain => "Try Again",
        ManagedVerb.StopWaiting => "Stop Waiting",
        _ => "Turn Back On",
    };

    public string StateWord
    {
        get
        {
            if (OrgLocked) return "Off by your organisation";
            return State switch
            {
                ManagedState.Available => "Available",
                ManagedState.Broken => "Couldn’t connect",
                ManagedState.Connected => DisabledTools.Count == 0 ? "Connected"
                    : $"Connected · {DisabledTools.Count} tool{(DisabledTools.Count == 1 ? "" : "s")} off",
                ManagedState.Connecting => "Connecting",
                ManagedState.Expired => "Access expired",
                ManagedState.Off => "Off for you",
                _ => "State unknown",
            };
        }
    }

    public string? Reason => State switch
    {
        ManagedState.Connecting => "Finish the sign-in in your browser.",
        ManagedState.Broken or ManagedState.Expired => StatusReason ?? "Reconnect to keep this app working.",
        _ => null,
    };

    public bool NeedsAttention => State is ManagedState.Broken or ManagedState.Expired;
    public bool IsMine => Connected || !Enabled;

    public ConnectorTone Tone(bool connecting = false)
    {
        if (connecting) return ConnectorTone.Warn;
        return State switch
        {
            ManagedState.Connected => ConnectorTone.Good,
            ManagedState.Broken => ConnectorTone.Bad,
            ManagedState.Expired or ManagedState.Connecting => ConnectorTone.Warn,
            _ => ConnectorTone.Quiet,
        };
    }

    public bool Matches(string query)
    {
        var q = query.Trim();
        return q.Length == 0 || new[] { Name, Slug, Description, Category }.Any(s => s.Contains(q, StringComparison.OrdinalIgnoreCase));
    }
}

public static class ManagedJoin
{
    public static List<ConnectorAccountRow> Ordered(IEnumerable<ConnectorAccountRow> accounts) =>
        [.. accounts.Where(a => !a.Disabled).OrderByDescending(a => a.Active).ThenByDescending(a => a.CreatedAt, StringComparer.Ordinal)];

    public static List<ManagedApp> Apps(IReadOnlyList<ConnectorCatalogRow> catalog, IReadOnlyList<ConnectorListRow> list,
        IReadOnlyList<ConnectorAccountRow> accounts, ConnectorPolicyView policy, bool rulesReadable, IReadOnlySet<string>? abandoned = null)
    {
        var bySlug = catalog.GroupBy(c => c.Slug).ToDictionary(g => g.Key, g => g.First());
        var rows = list.GroupBy(r => r.Connector).ToDictionary(g => g.Key, g => g.First());
        var accountsBySlug = accounts.GroupBy(a => a.Connector).ToDictionary(g => g.Key, g => g.ToList());
        var slugs = catalog.Select(c => c.Slug).ToList();
        var seen = slugs.ToHashSet();
        foreach (var r in list) if (seen.Add(r.Connector)) slugs.Add(r.Connector);
        return [.. slugs.Select(slug =>
        {
            bySlug.TryGetValue(slug, out var entry);
            rows.TryGetValue(slug, out var row);
            var all = accountsBySlug.GetValueOrDefault(slug) ?? [];
            var mine = Ordered(all);
            var account = mine.FirstOrDefault();
            var off = rulesReadable ? policy.MemberDisabledTools(slug) : row?.GatewayDisabledTools ?? [];
            var app = new ManagedApp(slug, entry?.Name ?? ManagedWire.Title(slug), entry?.Description ?? "", entry?.Category ?? "", entry?.LogoUrl,
                entry != null, account != null || row?.Connected == true, account?.Status ?? row?.ConnectionStatus,
                account?.StatusReason ?? row?.StatusReason, account?.Label, account?.CreatedAt, off,
                policy.MemberEnables(slug) && row?.Enabled != false, policy.OrgLocks(slug))
            { Accounts = mine, Retired = [.. all.Where(a => a.Disabled)] };
            if (abandoned?.Contains(slug) == true && app.ConnectionStatus == "pending")
                app = app with { Connected = false, ConnectionStatus = null, AccountLabel = null, ConnectedAt = null, Accounts = [.. app.Accounts.Where(a => a.Status != "pending")] };
            return app;
        })];
    }

    /// The apps this bot's account has (connected, or turned off), broken ones first, then A–Z.
    public static List<ManagedApp> Mine(IEnumerable<ManagedApp> apps) =>
        [.. apps.Where(a => a.IsMine).OrderByDescending(a => a.NeedsAttention).ThenBy(a => a.Name, StringComparer.CurrentCultureIgnoreCase)];

    public static List<string> Categories(IEnumerable<ManagedApp> apps) =>
        [.. apps.Where(a => a.Category.Length > 0).GroupBy(a => a.Category).OrderByDescending(g => g.Count()).ThenBy(g => g.Key, StringComparer.Ordinal).Select(g => g.Key)];
}

public static class ManagedToolWords
{
    public static string Facet(string facet) => facet switch
    {
        "read" => "Read",
        "write" => "Write",
        "destructive" => "Destructive",
        _ => "Unknown effect",
    };

    public static string FacetLong(string facet) => facet switch
    {
        "read" => "Reads data out of this app. It changes nothing.",
        "write" => "Creates or changes something in this app.",
        "destructive" => "Can remove something in this app for good.",
        _ => "The app never said what this tool does.",
    };

    public static string Draft(int off, int backOn) => $"{off} tool{(off == 1 ? "" : "s")} off, {(backOn == 0 ? "none" : backOn.ToString())} back on";
}

/// `connectors.*` for one bot's Nous account (ManagedConnectorsClient.swift). Every key outside a method's contract is
/// refused by Hermes, so each call sends exactly its own.
public sealed class ManagedConnectorsApi(RpcConnection rpc)
{
    public static JsonObject Owner => new() { ["type"] = "account" };
    public TimeSpan Timeout { get; set; } = TimeSpan.FromSeconds(45);

    private async Task<JsonNode> Call(string method, JsonObject p, string profile)
    {
        p["profile"] = profile;
        try { return await rpc.RequestAsync(method, p, Timeout); }
        catch (OperationCanceledException) { throw; }
        catch (Exception e) { throw ConnectorFailure.From(e); }
    }

    public async Task<ConnectorListResult> ListAsync(string profile) => ManagedWire.List(await Call("connectors.list", new() { ["owner"] = Owner }, profile));
    public async Task<List<ConnectorCatalogRow>> CatalogAsync(string profile) => ManagedWire.Catalog(await Call("connectors.catalog", [], profile));
    public async Task<List<ConnectorAccountRow>> AccountsAsync(string profile) => ManagedWire.Accounts(await Call("connectors.accounts", [], profile));
    public async Task<ConnectorPolicyView> PolicyAsync(string profile) => ManagedWire.Policy(await Call("connectors.policy.get", [], profile));

    public async Task<ConnectorToolsResult> ToolsAsync(string slug, bool refresh, string profile) =>
        ManagedWire.Tools(await Call("connectors.tools", new() { ["slug"] = slug, ["refresh"] = refresh }, profile));

    public async Task<ConnectionOperation> ConnectAsync(string slug, bool reconnect, string profile, string? alias = null, string? connectionId = null)
    {
        var p = new JsonObject { ["owner"] = Owner, ["connectors"] = new JsonArray(slug), ["reconnect"] = reconnect };
        if (alias != null) p["alias"] = alias;
        else if (reconnect && connectionId != null) p["connection_id"] = connectionId;
        return ManagedWire.Operation(await Call("connectors.connect", p, profile), [slug])
            ?? throw new ConnectorFailure(ConnectorErrorReason.InvalidConnectorResponse, null, "no operation");
    }

    public async Task<ConnectionOperation> StatusAsync(string opId, IReadOnlyList<string> connectors, string profile) =>
        ManagedWire.Operation(await Call("connectors.operation.status", new() { ["op_id"] = opId, ["owner"] = Owner }, profile), connectors)
            ?? throw new ConnectorFailure(ConnectorErrorReason.InvalidConnectorResponse, null, "no operation");

    public Task WakeAsync(string opId, string profile) => Call("connectors.operation.wake", new() { ["op_id"] = opId, ["owner"] = Owner }, profile);

    public Task GiveUpAsync(string opId, string profile) =>
        Call("connection.respond", new() { ["op_id"] = opId, ["owner"] = Owner, ["result"] = new JsonObject { ["settled_by"] = "continue" } }, profile);

    public Task RemoveAsync(string connectionId, string profile) => Call("connectors.accounts.remove", new() { ["connection_id"] = connectionId }, profile);

    public async Task<string?> SetEnabledAsync(string slug, bool enabled, string revision, string profile)
    {
        var change = new JsonObject { ["type"] = "connector", ["connector"] = slug, ["enabled"] = enabled };
        return (await Call("connectors.policy.set", new() { ["change"] = change, ["expected_revision"] = revision }, profile)).Text("revision");
    }

    public async Task<string?> SetDisabledToolsAsync(string slug, IEnumerable<string> disabled, string revision, string profile)
    {
        var change = new JsonObject { ["type"] = "tools", ["connector"] = slug, ["disabled_tools"] = new JsonArray([.. disabled.Select(d => (JsonNode)d)]) };
        return (await Call("connectors.policy.set", new() { ["change"] = change, ["expected_revision"] = revision }, profile)).Text("revision");
    }
}

/// What the Managed Apps section shows (ManagedAppsModel.swift `Phase`).
public abstract record ManagedPhase
{
    public sealed record Loading : ManagedPhase;
    public sealed record SignedOut : ManagedPhase;
    public sealed record Unavailable : ManagedPhase;
    public sealed record TooOld : ManagedPhase;
    public sealed record Failed(string Reason) : ManagedPhase;
    public sealed record Ready : ManagedPhase;
}

/// One bot's managed apps, read together (`ManagedAppsModel.reload`), and the sign-in operations it started. An
/// operation moves on the gateway's `connection.update` broadcasts (Apply), and is read once when the browser hands back.
public sealed class ManagedAppsState(ManagedConnectorsApi api, string profile)
{
    public string Profile { get; } = profile;
    public ManagedConnectorsApi Api { get; } = api;
    public ManagedPhase Phase { get; private set; } = new ManagedPhase.Loading();
    public IReadOnlyList<ConnectorCatalogRow> Catalog { get; private set; } = [];
    public IReadOnlyList<ConnectorListRow> List { get; private set; } = [];
    public IReadOnlyList<ConnectorAccountRow> Accounts { get; private set; } = [];
    public ConnectorPolicyView Policy { get; private set; } = ConnectorPolicyView.Empty;
    public ConnectorFailure? PolicyFailure { get; private set; }
    public ConnectorFailure? CatalogFailure { get; private set; }
    public Dictionary<string, ConnectionOperation> Operations { get; } = [];
    public HashSet<string> Abandoned { get; } = [];
    public DateTimeOffset? LoadedAt { get; private set; }

    public IReadOnlyList<ManagedApp> Apps =>
        ManagedJoin.Apps(Catalog, List, Accounts, Policy, PolicyFailure == null && Policy.Member != null, Abandoned);

    public ManagedApp? App(string slug) => Apps.FirstOrDefault(a => a.Slug == slug);

    public ConnectionOperation? OperationFor(string slug)
    {
        var mine = Operations.Values.Where(o => o.Connectors.Contains(slug)).OrderBy(o => o.Seq).ToList();
        return mine.FirstOrDefault(o => !o.Settled) ?? mine.LastOrDefault();
    }

    public bool Waiting(string slug)
    {
        if (OperationFor(slug) is not { Settled: false } op || Abandoned.Contains(slug)) return false;
        return op.Target(slug) is not { } t || t.State is ConnectionTargetState.Pending or ConnectionTargetState.Initiated;
    }

    private static async Task<(T? Value, ConnectorFailure? Failure)> Attempt<T>(Func<Task<T>> work)
    {
        try { return (await work(), null); }
        catch (Exception e) { return (default, ConnectorFailure.From(e)); }
    }

    public async Task ReloadAsync()
    {
        var listRead = Attempt(() => Api.ListAsync(Profile));
        var catalogRead = Attempt(() => Api.CatalogAsync(Profile));
        var accountsRead = Attempt(() => Api.AccountsAsync(Profile));
        var policyRead = Attempt(() => Api.PolicyAsync(Profile));
        await Task.WhenAll(listRead, catalogRead, accountsRead, policyRead);
        var (list, failure) = await listRead;
        if (failure != null)
        {
            // Signed out and unavailable are empty states, not failures; anything else keeps the last list.
            if (failure.Reason == ConnectorErrorReason.NeedsNousAuth) { Phase = new ManagedPhase.SignedOut(); Clear(); }
            else if (failure.Reason == ConnectorErrorReason.ConnectorsUnavailable) { Phase = new ManagedPhase.Unavailable(); Clear(); }
            else if (failure.TooOld) { Phase = new ManagedPhase.TooOld(); Clear(); }
            else if (Phase is not ManagedPhase.Ready) Phase = new ManagedPhase.Failed(failure.Words("Couldn’t reach the managed apps."));
            return;
        }
        if (!list!.Available) { Phase = new ManagedPhase.Unavailable(); Clear(); return; }
        List = list.Connectors;
        var (catalog, cf) = await catalogRead;
        if (catalog != null) { Catalog = catalog; CatalogFailure = null; } else CatalogFailure = cf;
        if ((await accountsRead).Value is { } accounts) Accounts = accounts;
        var (policy, pf) = await policyRead;
        if (policy != null) { Policy = policy; PolicyFailure = null; } else PolicyFailure = pf;
        Phase = new ManagedPhase.Ready();
        LoadedAt = DateTimeOffset.UtcNow;
    }

    public async Task ReloadAccountsAndListAsync()
    {
        if ((await Attempt(() => Api.AccountsAsync(Profile))).Value is { } a) Accounts = a;
        if ((await Attempt(() => Api.ListAsync(Profile))).Value is { } l) List = l.Connectors;
    }

    public async Task ReloadPolicyAsync()
    {
        var (p, f) = await Attempt(() => Api.PolicyAsync(Profile));
        if (p != null) { Policy = p; PolicyFailure = null; } else PolicyFailure = f;
    }

    private void Clear()
    {
        Catalog = []; List = []; Accounts = []; Policy = ConnectorPolicyView.Empty; PolicyFailure = null; CatalogFailure = null;
    }

    /// A `connection.update` broadcast. True when it moved one of this bot's operations on.
    public bool Apply(JsonNode? payload)
    {
        if (ManagedWire.Operation(payload) is not { } snapshot || !Operations.TryGetValue(snapshot.OpId, out var held)) return false;
        if (held.Applying(snapshot, broadcast: true) is not { } next) return false;
        Operations[next.OpId] = next;
        return true;
    }

    public void Remember(ConnectionOperation op, string slug)
    {
        Abandoned.Remove(slug);
        foreach (var k in Operations.Where(p => p.Value.Settled && p.Value.Connectors.Contains(slug)).Select(p => p.Key).ToList()) Operations.Remove(k);
        Operations[op.OpId] = op;
    }

    public void Store(ConnectionOperation op)
    {
        if (Operations.TryGetValue(op.OpId, out var held) && held.Applying(op, broadcast: false) is { } next) Operations[op.OpId] = next;
        else if (!Operations.ContainsKey(op.OpId)) Operations[op.OpId] = op;
    }
}
