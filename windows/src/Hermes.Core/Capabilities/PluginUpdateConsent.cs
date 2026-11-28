using System.Text.Json.Nodes;
using Hermes.Core.Gateways;
using Hermes.Core.Net;
using Hermes.Core.Notifications;

namespace Hermes.Core.Capabilities;

/// One structured finding reported by Hermes's security scan for a plugin update (`PluginScanFinding`).
public sealed record PluginScanFinding(string? Severity = null, string? Category = null, string? File = null, int? Line = null)
{
    public JsonObject ToJson()
    {
        var o = new JsonObject();
        if (!string.IsNullOrEmpty(Severity)) o["severity"] = Severity;
        if (!string.IsNullOrEmpty(Category)) o["category"] = Category;
        if (!string.IsNullOrEmpty(File)) o["file"] = File;
        if (Line is { } line) o["line"] = line;
        return o;
    }

    public static PluginScanFinding? Read(JsonNode? node)
    {
        if (node is not JsonObject) return null;
        return new PluginScanFinding(
            node.Text("severity"),
            node.Text("category"),
            node.Text("file"),
            node.Int("line") is { } l ? (int)l : null);
    }
}

/// How updating one bot's copy of a plugin ended (App/Capabilities/PluginUpdates.swift `CopyResult`).
public abstract record PluginUpdateCopyResult
{
    public sealed record Done : PluginUpdateCopyResult;
    public sealed record DoneNeedsRestart : PluginUpdateCopyResult;
    public sealed record Consent(IReadOnlyList<string> Lines) : PluginUpdateCopyResult;
    public sealed record Caution(IReadOnlyList<string> Findings, IReadOnlyList<PluginScanFinding> Found) : PluginUpdateCopyResult;
    public sealed record Declined : PluginUpdateCopyResult;
    public sealed record Computer(string Packages) : PluginUpdateCopyResult;
    public sealed record Failed(string Reason) : PluginUpdateCopyResult;
}

/// Port of App/Capabilities/PluginUpdates.swift `PluginUpdateConsent`: calls `hermes-hq-push` 0.9.52+
/// (`POST` / `GET /api/plugins/hermes-hq-push/plugins/update`) to apply plugin updates that require
/// approving new Python packages or verified caution-scan findings.
public static class PluginUpdateConsent
{
    public const string Path = "/plugins/update";
    public static string Route => PushPolicy.PluginRoute + Path;

    public readonly record struct Support(bool Offered = false, bool Checked = false);

    /// True when `/api/plugins/hermes-hq-push/status` advertises `pluginUpdates == true` (0.9.52+).
    public static bool Offered(JsonObject? status) => status?.Bool("pluginUpdates") == true;

    /// True when `/api/plugins/hermes-hq-push/status` advertises `pluginUpdatesChecked == true` (0.9.58+).
    public static bool Checked(JsonObject? status) => status?.Bool("pluginUpdatesChecked") == true;

    /// Queries the gateway add-on status for plugin update consent support.
    public static async Task<Support> GetSupportAsync(GatewaySession session, CancellationToken ct = default)
    {
        try
        {
            var answer = await session.SendAsync(HttpMethod.Get, PushPolicy.PluginRoute + "/status", timeout: TimeSpan.FromSeconds(10), ct: ct)
                .ConfigureAwait(false);
            if (!answer.Ok || answer.Json is not JsonObject body) return default;
            var offered = Offered(body);
            return new Support(offered, offered && Checked(body));
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception)
        {
            return default;
        }
    }

    public static async Task<bool> IsAvailableAsync(GatewaySession session, CancellationToken ct = default) =>
        (await GetSupportAsync(session, ct).ConfigureAwait(false)).Offered;

    /// What the owner was shown and approved; omitted fields are answered no by add-on 0.9.58+.
    public sealed class Approved
    {
        public string? Packages { get; }
        public IReadOnlyList<PluginScanFinding>? Findings { get; }
        public IReadOnlyList<string>? Capabilities { get; }
        public bool AcceptCapabilities { get; }
        public bool Force { get; }

        public Approved(
            string? packages = null,
            IReadOnlyList<PluginScanFinding>? findings = null,
            IReadOnlyList<string>? capabilities = null,
            bool? acceptCapabilities = null,
            bool? force = null)
        {
            Packages = packages;
            Findings = findings;
            Capabilities = capabilities;
            AcceptCapabilities = acceptCapabilities ?? (capabilities != null);
            Force = force ?? (findings != null);
        }

        public JsonObject ToBody(string profile, string name)
        {
            var body = new JsonObject
            {
                ["profile"] = profile,
                ["name"] = name,
                ["accept_capabilities"] = AcceptCapabilities,
                ["force"] = Force,
            };
            if (Packages != null) body["packages"] = Packages;
            if (Findings != null) body["findings"] = new JsonArray([.. Findings.Select(f => (JsonNode)f.ToJson())]);
            if (Capabilities != null) body["capabilities"] = new JsonArray([.. Capabilities.Select(c => (JsonNode)c)]);
            return body;
        }
    }

    /// Interprets a `GET /api/plugins/hermes-hq-push/plugins/update/<job>` payload; returns null while still running.
    public static PluginUpdateCopyResult? ParseJobResult(JsonObject? job)
    {
        var state = job.Text("state");
        switch (state)
        {
            case "done":
                return job.Bool("unchanged") == true
                    ? new PluginUpdateCopyResult.Done()
                    : new PluginUpdateCopyResult.DoneNeedsRestart();
            case "failed":
                if (job.Obj("held") is { } held)
                {
                    if (held.Text("kind") == "packages"
                        && held.Bool("changed") == false
                        && held.Text("now") is { } now)
                    {
                        return new PluginUpdateCopyResult.Computer(now);
                    }
                    return new PluginUpdateCopyResult.Failed(PluginUpdateWords.ChangedSince);
                }
                var said = job.Str("output")?.Trim() ?? "";
                return new PluginUpdateCopyResult.Failed(said.Length == 0 ? "Hermes didn’t apply the update." : said);
            default:
                return null;
        }
    }

    /// Starts the add-on plugin update job and polls every 2 seconds until completion, 404, or timeout.
    public static async Task<PluginUpdateCopyResult> ApplyAsync(
        GatewaySession session,
        string profile,
        string name,
        Approved approved,
        TimeSpan? pollInterval = null,
        int maxLooks = 180,
        CancellationToken ct = default)
    {
        HttpAnswer started;
        try
        {
            started = await session.SendAsync(
                HttpMethod.Post,
                Route,
                body: approved.ToBody(profile, name),
                timeout: TimeSpan.FromSeconds(30),
                ct: ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (Exception)
        {
            return new PluginUpdateCopyResult.Failed("Hermes’s add-on didn’t answer.");
        }

        if (started.Status != 200 || started.Json is not JsonObject startBody || startBody.Text("job") is not { } jobId)
        {
            var detail = started.Json is JsonObject err ? err.Text("detail") : null;
            return new PluginUpdateCopyResult.Failed(detail ?? "Hermes’s add-on couldn’t start the update.");
        }

        var delay = pollInterval ?? TimeSpan.FromSeconds(2);
        var looks = 0;
        while (looks < maxLooks)
        {
            await Task.Delay(delay, ct).ConfigureAwait(false);
            HttpAnswer answer;
            try
            {
                answer = await session.SendAsync(
                    HttpMethod.Get,
                    $"{Route}/{Uri.EscapeDataString(jobId)}",
                    timeout: TimeSpan.FromSeconds(15),
                    ct: ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception)
            {
                continue; // transient network blip: keep looking
            }

            if (answer.Status == 404)
                return new PluginUpdateCopyResult.Failed("Hermes restarted before the update finished. Try again.");
            if (answer.Status != 200) continue;
            looks++;
            if (ParseJobResult(answer.Json as JsonObject) is { } result) return result;
        }

        return new PluginUpdateCopyResult.Failed("The update is taking too long. Look at it on Hermes’s computer.");
    }
}

/// Wording and parsing helpers for third-party plugin updates (App/Capabilities/PluginUpdates.swift `PluginUpdateWords`).
public static class PluginUpdateWords
{
    public const string ChangedSince =
        "The plugin changed after you approved it, so nothing changed. Try again to see what the new version asks for.";
    public const string ScanBlocked =
        "Hermes’s security scan stopped the update, and nothing changed. Look at what it found on Hermes’s computer (hermes plugins update).";
    public const string Checking = "Checking the plugins";
    public const string Paused = "Paused. Carries on when Hermes is back in reach.";
    public const string AwayTooLong = "Hermes stayed out of reach. Try again.";
    public const string OthersWentIn = "The other updates went in.";

    public static string Subject(IReadOnlyList<string> names) =>
        names.Count == 1 ? names[0] : $"{names.Count} plugins";

    public static string Asking(IReadOnlyList<string> names) =>
        names.Count == 1 ? $"Update {names[0]}?" : $"Update {names.Count} Plugins?";

    public static string Why(IReadOnlyList<string> names) =>
        names.Count == 1
            ? $"A newer version of {names[0]} is out for Hermes."
            : $"Newer versions of {names.Count} plugins are out for Hermes.";

    public static string Couldnt(IReadOnlyList<string> names) =>
        names.Count == 1
            ? $"Couldn’t Update {DisplayName.Title(names[0])}"
            : $"Couldn’t Update {names.Count} Plugins";

    public static string StillBehind(IReadOnlyList<string> names) =>
        names.Count == 1
            ? $"{DisplayName.Title(names[0])} Still Needs Its Update"
            : $"{names.Count} Plugins Still Need Their Update";

    public static string AddsPackages(IReadOnlyList<string> names) =>
        names.Count == 1
            ? $"{DisplayName.Title(names[0])} Adds Python Packages"
            : $"{names.Count} Plugins Add Python Packages";

    /// Hermes's refusal for an update that adds Python packages.
    public static bool IsForComputer(string message) =>
        message.Contains("declares new Python dependencies", StringComparison.Ordinal);

    /// Extracts the package list inside `dependencies (...); run`.
    public static string PackagesIn(string message)
    {
        const string openTag = "dependencies (";
        const string closeTag = "); run";
        var open = message.IndexOf(openTag, StringComparison.Ordinal);
        if (open < 0) return "";
        var start = open + openTag.Length;
        var close = message.IndexOf(closeTag, start, StringComparison.Ordinal);
        return close < 0 ? "" : message[start..close];
    }

    /// Bare package names without version pins or platform markers, preserving first-seen order.
    public static List<string> PackageNames(IEnumerable<string> specs)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var result = new List<string>();
        foreach (var raw in specs)
        {
            foreach (var part in raw.Split(", ", StringSplitOptions.None))
            {
                var trimmed = part.Trim();
                var len = 0;
                while (len < trimmed.Length)
                {
                    var ch = trimmed[len];
                    if (char.IsLetterOrDigit(ch) || ch is '-' or '_' or '.') len++;
                    else break;
                }
                if (len == 0) continue;
                var name = trimmed[..len];
                if (seen.Add(name)) result.Add(name);
            }
        }
        return result;
    }

    public static string NeedsBot(IReadOnlyList<string> names, IEnumerable<string> packages, string bot)
    {
        var one = names.Count == 1;
        var added = PackageNames(packages);
        var what = added.Count == 0 ? "Python packages" : $"Python packages ({AddOnReminder.Names(added)})";
        return $"{AddOnReminder.Names(names)} {(one ? "adds" : "add")} {what}, which Hermes only installs when asked on its own computer. {bot} can do that from its chat.";
    }

    public static string AskBot(string bot, int count) =>
        $"Ask {bot} to Update {(count == 1 ? "It" : "Them")}";

    public static string NeedsComputer(IReadOnlyList<string> names)
    {
        var one = names.Count == 1;
        var first = names.Count > 0 ? names[0] : "";
        return $"{AddOnReminder.Names(names)} {(one ? "adds" : "add")} Python packages, which Hermes only lets you approve on its computer. Run hermes plugins update {first} there{(one ? "" : $", and the same for the {(names.Count == 2 ? "other" : "others")}")}.";
    }

    public static string BotUpdateTitle(IReadOnlyList<string> names) =>
        $"Update {AddOnReminder.Names(names)} on this Hermes.";

    public static string BotUpdatePrompt(IReadOnlyList<(string Name, string Packages, IReadOnlyList<string> Profiles)> rows, string appName = "Hermes HQ")
    {
        var list = string.Join("\n", rows.Select(row =>
            $"- {row.Name}{(string.IsNullOrEmpty(row.Packages) ? "" : $" (adds: {row.Packages})")}, for {(row.Profiles.Count == 1 ? "the profile" : "the profiles")} {string.Join(", ", row.Profiles)}"));
        var one = rows.Count == 1;
        return $"""
            This is from me, through {appName}, the {DeviceWord.Name} app I'm chatting with you in; it connects to this Hermes's web dashboard. I asked it to update my Hermes plugins. Hermes refused {(one ? "this one" : "these")} from the app, because the new {(one ? "version adds" : "versions add")} Python packages, which it only installs when asked in a terminal:

            {list}

            I've seen those packages in {appName} and I approve them. Please update {(one ? "it" : "each one")} with your terminal tools: hermes plugins update <name> for the default profile, hermes -p <profile> plugins update <name> for another. If the command stops to ask about the Python packages, answer yes for me (for example: yes | hermes plugins update <name>). If it still refuses without a terminal, tell me what it said and stop; don't get around it another way. Don't restart anything unless the command says a restart is needed, and then tell me first.

            When you're done, tell me in a sentence or two which ones updated.
            """;
    }

    public static string RestartTitle(IReadOnlyList<string> names) =>
        $"Restart Hermes so the updated {(names.Count == 1 ? "plugin loads" : "plugins load")}.";

    public static string RestartPrompt(IReadOnlyList<string> names, IReadOnlyList<string> profiles, string appName = "Hermes HQ")
    {
        var what = names.Count == 1 ? $"the plugin {names[0]}" : $"these plugins: {AddOnReminder.Names(names)}";
        var whose = profiles.Any(p => p != "default") ? $" (for the profiles {string.Join(", ", profiles)})" : "";
        return $"""
            This is from me, through {appName}, the {DeviceWord.Name} app I'm chatting with you in; it connects to this Hermes's web dashboard. {appName} has just updated {what}{whose} through Hermes's own plugin manager (plugins.manage), the same update hermes plugins update makes, so nothing is left to install.

            Please restart Hermes (the dashboard / web server, and the gateway if it runs on its own) so the updated {(names.Count == 1 ? "plugin loads" : "plugins load")}.

            When you're done, tell me in a sentence what you did. {appName} checks the {(names.Count == 1 ? "plugin" : "plugins")} itself.
            """;
    }

    /// Distinct values preserving first-seen order.
    public static List<string> Distinct(IEnumerable<string> values)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var result = new List<string>();
        foreach (var v in values)
        {
            if (seen.Add(v)) result.Add(v);
        }
        return result;
    }
}
