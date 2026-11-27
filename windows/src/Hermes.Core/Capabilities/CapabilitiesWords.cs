using System.Text.RegularExpressions;
using Hermes.Core.Gateways;
using Hermes.Core.Net;

namespace Hermes.Core.Capabilities;

/// The words Capabilities shows, kept apart from the screens so they are tested (CapabilitiesModel.swift,
/// CapabilitiesModel+More.swift, CapabilitiesStore.swift, ConnectorLook.swift).
public static class CapabilitiesWords
{
    public const string HubFooter = "Each bot has its own. Choose the bot at the top of each page.";
    public const string ComposioFooter = "Apps through your own Composio API key, shared by the bots you choose.";
    public const string Waiting = "Waiting for your gateway…";
    public const string RefreshFailed = "Couldn’t refresh. Showing the last list.";
    public const string ChangesApply = "Changes apply to new chats.";

    public static string Plural(long n, string one, string many) => $"{n} {(n == 1 ? one : many)}";

    /// A catalog's search field: "Search 12 apps", "Search 1 app", or "Search apps" before the list has loaded.
    public static string SearchApps(int n) => n > 0 ? $"Search {Plural(n, "app", "apps")}" : "Search apps";

    /// The gateway's `detail` from an HTTP error body, else plain words (CapabilitiesStore.detail).
    public static string Detail(Exception error)
    {
        if (error is GatewayException g)
        {
            if (g.Code == "http")
            {
                if (g.Body != null && J.Parse(g.Body).Text("detail") is { } detail) return detail;
                return g.Status == 404 ? "Your gateway doesn’t know this one." : g.Message;
            }
            if (g.Code == "rpc" || g.IsConnectionLost) return g.PlainReason;
            if (g.Code is "offline" or "timeout") return "Can’t reach your gateway right now. Try again when it’s back.";
            return g.Message;
        }
        if (error is CapabilityException c) return c.Reason;
        return "Something went wrong. Try again.";
    }

    public static bool IsNotFound(Exception error) => error is GatewayException { Code: "http", Status: 404 };

    /// JSON-RPC "method not found": an older Hermes without this method.
    public static bool IsUnknownMethod(Exception error) =>
        error is GatewayException { Code: "rpc" } g && (g.RpcCode == -32601 || g.Message.Contains("method not found", StringComparison.OrdinalIgnoreCase)
            || g.Message.Contains("unknown method", StringComparison.OrdinalIgnoreCase));

    public static bool IsTransport(Exception error) => error is GatewayException { Code: "offline" or "timeout" };

    // ---------------------------------------------------------------- Skills

    /// "Research · Used 30 times", or just the category.
    public static string SkillCaption(SkillInfo skill)
    {
        var category = DisplayName.Title(skill.Category ?? "general");
        var used = skill.Usage ?? 0;
        return used > 0 ? $"{category} · Used {used} {(used == 1 ? "time" : "times")}" : category;
    }

    /// The Mac's one subtitle line: category and use, then what it does.
    public static string SkillLine(SkillInfo skill) =>
        string.Join(" · ", new[] { SkillCaption(skill), skill.Description }.Where(s => s.Length > 0));

    public static string OfficialLine(OfficialSkill skill) =>
        string.Join(" · ", new[] { skill.Category is { } c ? DisplayName.Title(c) : "", skill.Description }.Where(s => s.Length > 0));

    /// [WIN-SKILLS-ROW-ONELINE] How many lines an Installed or Available skill row's subtitle (`SkillLine`,
    /// `OfficialLine`) takes: the Mac's `.lineLimit(typeSize.isAccessibilitySize ? nil : 1)` (SkillRow /
    /// OfficialSkillRow, 93f984bb1), one line at Standard and Compact alike, cut at its tail. 0 means no limit: at the
    /// accessibility sizes (Windows' text size at 150 % or more, `UndoPillClock.AccessibilityTextScale`) it wraps.
    public static int SkillLineLines(double textScale) => Bots.UndoPillClock.AccessibilityTextScale(textScale) ? 0 : 1;

    /// The row's tooltip, the whole description (`.help(skill.description)`); none for a skill without one.
    public static string? SkillTip(string description) => description.Length > 0 ? description : null;

    /// UX study #55: what an empty Skills list means and where skills come from (SkillsEmptyWords.swift).
    public static (string Title, string Text, string? Action) SkillsEmpty(string botName, bool hasAvailable) => hasAvailable
        ? ("No Skills Installed", $"Install one from the list below, or ask {botName} in a chat to make one.", "Search Skills")
        : ("No Skills Installed", $"Ask {botName} in a chat to make one.", null);

    public static string InstallTitle(string name, bool done) => done ? $"Installed {DisplayName.Title(name)}" : $"Installing {DisplayName.Title(name)}…";
    public static string InstallMessage(string bot, bool done) => done ? $"{bot} can use it in new chats." : $"For {bot}. This can take a minute.";

    public static string InstallAsk(string name, string bot) => $"Install {DisplayName.Title(name)} for {bot}?";
    public static string InstallAskMessage(string bot) =>
        $"{bot} can use it in new chats. The gateway downloads it and checks it before it is installed.";

    public static string HubInstallAskMessage(HubSkill skill, string bot) =>
        (skill.IsCommunity
            ? $"It comes from the community ({skill.SourceWord}), not from Nous. Read it before you trust the author. "
            : $"It comes from {skill.SourceWord}. ")
        + $"The gateway downloads it and checks it before it is installed. {bot} can use it in new chats.";

    /// The security scan refused the install (`parseInstallBlocked`).
    public static (int Findings, bool Unverified)? InstallBlocked(IEnumerable<string> lines)
    {
        var text = string.Join("\n", lines);
        var current = Regex.Match(text, @"Not installed:\s+the security scan found\s+(?:(\d+)\s+)?high-risk\s+pattern", RegexOptions.IgnoreCase);
        if (current.Success)
        {
            var unverified = Regex.IsMatch(text, @"never installs\s+unverified", RegexOptions.IgnoreCase);
            return (int.TryParse(current.Groups[1].Value, out var n) ? n : 0, unverified);
        }
        var legacy = Regex.Match(text, @"Installation blocked:.*?\(([a-z_-]+) source \+ ([a-z_]+) verdict, (\d+) findings?\)", RegexOptions.IgnoreCase);
        if (!legacy.Success) return null;
        return (int.TryParse(legacy.Groups[3].Value, out var f) ? f : 0, legacy.Groups[1].Value != "official");
    }

    public static string BlockedMessage(int findings, bool unverified)
    {
        var what = findings > 0 ? $"{findings} item{(findings == 1 ? "" : "s")}" : "risky patterns";
        return $"The security scan flagged {what} to review{(unverified ? " and the skill comes from an unverified source" : "")}. "
            + "Read the scan before deciding whether to trust the author.";
    }

    public static string DisableUnusedTitle(int count, string bot) => $"Turn Off {Plural(count, "Unused Skill", "Unused Skills")} for {bot}?";
    public const string DisableUnusedMessage = "These skills have never been used. You can turn any of them back on.";
    public static string Disabling(int done, int total) => $"Turning off {done} of {total}…";
    public static string Updated(int n) => $"Updated {Plural(n, "item", "items")} for new chats.";

    // ---------------------------------------------------------------- Tools

    /// "1.2K uses" when its tools have calls, else "3 tools".
    public static string ToolMeta(Toolset set, IReadOnlyDictionary<string, int>? usage)
    {
        var used = Calls(set, usage);
        return used > 0 ? $"{Toolset.Compact(used)} {(used == 1 ? "use" : "uses")}" : Plural(set.Tools.Count, "tool", "tools");
    }

    public static long Calls(Toolset set, IReadOnlyDictionary<string, int>? usage) =>
        set.Tools.Sum(t => (long)(usage?.GetValueOrDefault(t) ?? 0));

    public static string ToolsTooOld => $"This gateway’s Hermes is too old to list tools here. Update Hermes on {HostWord.UpdateTarget}.";
    public static string PluginsTooOld => $"This gateway’s Hermes is too old to manage plugins here. Update Hermes on {HostWord.UpdateTarget}.";

    // ---------------------------------------------------------------- Connectors

    /// "Connected · 31 tools", "Connecting…", "Couldn’t connect", "Off", "Starts when needed", "Not started", plus the plugin.
    public static string StatusLine(McpServer server)
    {
        var words = (server.Status ?? (server.Enabled ? "configured" : "disabled")) switch
        {
            "connected" => $"Connected · {server.Tools ?? 0} {(server.Tools == 1 ? "tool" : "tools")}",
            "connecting" => "Connecting…",
            "failed" => "Couldn’t connect",
            "disabled" => "Off",
            "lazy" => "Starts when needed",
            _ => "Not started",
        };
        if (server.Enabled && ServerIssues.KindOf(server) == IssueKind.NeedsAuth) words = "Needs sign-in";
        if (!server.Enabled) words = "Off";
        if (server.Source == "plugin" && server.Plugin is { } plugin) words += $" · Added by the {DisplayName.Title(plugin)} plugin";
        return words;
    }

    /// The row's words (ConnectorRow.words): a plugin's server says "· Plugin".
    public static string RowWords(McpServer server)
    {
        var line = StatusLine(server);
        var cut = line.IndexOf(" · Added by the ", StringComparison.Ordinal);
        if (server.Source == "plugin" && cut >= 0) line = line[..cut] + " · Plugin";
        return line;
    }

    /// What the row shows: "5 tools", not "Connected · 5 tools" (the green dot says connected).
    public static string ShownWords(McpServer server)
    {
        var line = RowWords(server);
        return line.StartsWith("Connected · ", StringComparison.Ordinal) ? line["Connected · ".Length..] : line;
    }

    public static string ConnectedFooter(string bot) => $"Changes apply to {bot}’s new chats.";

    public static string NoConnectors(bool readOnly, bool catalogHasApps, string bot) =>
        readOnly ? "No connectors yet."
        : catalogHasApps ? $"No connectors yet. Pick an app below to connect it to {bot}."
        : "No connectors yet. Add one below.";

    public static string CatalogFooter(string bot) =>
        $"Apps Hermes ships with, approved by Nous. Installing one adds it to {bot} on {HostWord.Phrase}.";

    public static string KeysFooter(string bot) => $"Saved in {bot}’s settings on {HostWord.Phrase}, never on this {DeviceWord.Name}.";

    public static string ConfigFooter =>
        $"Read-only on {DeviceWord.Name}, with keys, tokens and passwords hidden. Edit this connector’s configuration on {HostWord.Phrase}.";

    public static string RemoveMessage(string bot) => $"{bot} stops using it. Nothing else is deleted from {HostWord.Phrase}.";

    public static string ComposioTitle(bool keySaved) => keySaved ? "Your Composio Apps" : "Use Your Composio API Key";
    public static string ComposioDetail(bool keySaved) => keySaved ? "Not here? Look in your Composio apps" : "Not here? Composio has hundreds more apps";
}

/// A refusal the app words itself (read-only gateway, a configuration that wasn't one).
public sealed class CapabilityException(string title, string reason) : Exception(reason)
{
    public string Title { get; } = title;
    public string Reason { get; } = reason;
    public const string ReadOnlyReason = "This gateway is read-only.";
}

/// The connector's tone: its dot and the colour of its words (ConnectorLook.swift `ConnectorTone`).
public enum ConnectorTone { Good, Quiet, Busy, Warn, Bad }

public static class ConnectorTones
{
    public static ConnectorTone Of(McpServer s)
    {
        if (!s.Enabled) return ConnectorTone.Quiet;
        if (ServerIssues.KindOf(s) == IssueKind.NeedsAuth) return ConnectorTone.Warn;
        return s.Status switch
        {
            "connected" => ConnectorTone.Good,
            "failed" => ConnectorTone.Bad,
            "connecting" => ConnectorTone.Busy,
            _ => ConnectorTone.Quiet,
        };
    }
}
