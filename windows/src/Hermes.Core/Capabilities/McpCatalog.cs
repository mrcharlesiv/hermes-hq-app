using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Hermes.Core.Capabilities;

/// The Nous-approved MCP catalog Hermes ships (`GET /api/mcp/catalog`, HermesKit/Store/McpCatalog.swift).
public sealed record McpCatalogEntry(string Name, string Description, string? ConnectorSlug, string Source, string Transport,
    string AuthType, IReadOnlyList<McpCatalogEntry.EnvKey> RequiredEnv, string? Command, IReadOnlyList<string> Args, string? Url,
    string? InstallUrl, string PostInstall, bool Installed, bool Enabled)
{
    public sealed record EnvKey(string Name, string Prompt, bool Required);

    public string Title => McpCatalog.Title(ConnectorSlug, Name);
    public bool NeedsSignIn => AuthType == "oauth";
    public bool NeedsBuild => InstallUrl != null;

    public bool Matches(string query)
    {
        var q = query.Trim();
        if (q.Length == 0) return true;
        return Title.Contains(q, StringComparison.OrdinalIgnoreCase) || Name.Contains(q, StringComparison.OrdinalIgnoreCase)
            || Description.Contains(q, StringComparison.OrdinalIgnoreCase);
    }

    /// The description without a leading "Title: " (ConnectorLook.swift `shortDescription`).
    public string ShortDescription
    {
        get
        {
            var text = Description.Trim();
            foreach (var prefix in new[] { Title, DisplayName.Title(Name) })
            {
                if (prefix.Length == 0) continue;
                foreach (var joiner in new[] { ": ", " — ", " - " })
                {
                    if (!text.StartsWith(prefix + joiner, StringComparison.OrdinalIgnoreCase)) continue;
                    var rest = text[(prefix.Length + joiner.Length)..];
                    return rest.Length == 0 ? rest : char.ToUpperInvariant(rest[0]) + rest[1..];
                }
            }
            return text;
        }
    }
}

public static class McpCatalog
{
    public static List<McpCatalogEntry> Entries(JsonNode? value)
    {
        var o = new List<McpCatalogEntry>();
        foreach (var row in value.Arr("entries") ?? [])
        {
            if (row.Text("name") is not { } name) continue;
            var env = (row.Arr("required_env") ?? []).Select(k => k.Text("name") is { } n
                ? new McpCatalogEntry.EnvKey(n, k.Text("prompt") ?? n, k.Bool("required") ?? true) : null).OfType<McpCatalogEntry.EnvKey>().ToList();
            o.Add(new(name, row.Str("description") ?? "", row.Text("connector_slug"), row.Str("source") ?? "", row.Text("transport") ?? "stdio",
                row.Text("auth_type") ?? "none", env, row.Text("command"), [.. (row.Arr("args") ?? []).Select(a => J.AsString(a) ?? "")],
                row.Text("url"), row.Text("install_url"), row.Str("post_install") ?? "", row.Bool("installed") ?? false, row.Bool("enabled") ?? false));
        }
        return o;
    }

    private static readonly Dictionary<string, string> Titles = new()
    {
        ["github"] = "GitHub", ["gitlab"] = "GitLab", ["stripe_mcp"] = "Stripe", ["sentry_mcp"] = "Sentry", ["vercel_mcp"] = "Vercel",
        ["hugging_face"] = "Hugging Face", ["n8n-official"] = "n8n", ["aws-knowledge"] = "AWS Knowledge", ["deepwiki"] = "DeepWiki",
        ["clickup"] = "ClickUp", ["circleci"] = "CircleCI", ["motherduck"] = "MotherDuck", ["paypal"] = "PayPal", ["wordpress-com"] = "WordPress.com",
        ["betterstack"] = "Better Stack", ["twelve-data"] = "Twelve Data", ["twilio-docs"] = "Twilio Docs", ["context7"] = "Context7",
        ["microsoft-learn"] = "Microsoft Learn", ["prisma-postgres"] = "Prisma Postgres", ["comfy-cloud"] = "Comfy Cloud",
        ["unreal-engine"] = "Unreal Engine", ["alltrails"] = "AllTrails", ["googlecalendar"] = "Google Calendar", ["googledrive"] = "Google Drive",
        ["googledocs"] = "Google Docs", ["googlesheets"] = "Google Sheets",
    };

    public static string Title(string? connectorSlug, string name)
    {
        if (connectorSlug != null && Titles.TryGetValue(connectorSlug, out var a)) return a;
        if (Titles.TryGetValue(name, out var b)) return b;
        var words = Regex.Replace(name, "[_-]+", " ").Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Select(w => char.ToUpperInvariant(w[0]) + w[1..]);
        return Regex.Replace(string.Join(" ", words), @"\bMcp\b", "MCP");
    }

    /// A key that holds an address rather than a secret (`N8N_MCP_SERVER_URL`, `…_HOST`): typed in the open.
    public static bool IsAddress(McpCatalogEntry.EnvKey key)
    {
        var parts = key.Name.ToUpperInvariant().Split('_');
        return parts.Contains("URL") || parts.Contains("HOST") || parts.Contains("ENDPOINT");
    }

    /// The apps the Popular grid leads with, the rest A–Z.
    public static readonly string[] LeadOrder = ["notion", "linear", "figma", "todoist", "asana", "airtable", "dropbox", "atlassian", "canva", "stripe",
        "supabase", "github", "gitlab", "miro", "monday", "clickup", "calendly", "sentry", "vercel", "netlify"];

    public static List<McpCatalogEntry> Ordered(IEnumerable<McpCatalogEntry> entries)
    {
        var rank = LeadOrder.Select((n, i) => (n, i)).ToDictionary(p => p.n, p => p.i);
        return [.. entries.OrderBy(e => rank.GetValueOrDefault(e.Name, int.MaxValue)).ThenBy(e => e.Title, StringComparer.CurrentCultureIgnoreCase)];
    }

    /// Slugs logos.composio.dev may know this app by, best first.
    public static List<string> LogoSlugs(McpCatalogEntry entry)
    {
        var o = new List<string>();
        void Add(string? s) { if (!string.IsNullOrEmpty(s) && !o.Contains(s)) o.Add(s); }
        Add(entry.ConnectorSlug);
        Add(entry.Name);
        Add(Regex.Replace(entry.Name, "[_-]", ""));
        Add(entry.Name.Replace('-', '_'));
        if (entry.ConnectorSlug is { } slug && slug.EndsWith("_mcp")) Add(slug[..^4]);
        return o;
    }
}
