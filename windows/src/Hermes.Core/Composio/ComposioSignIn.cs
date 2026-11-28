using System.Text.Json.Nodes;

namespace Hermes.Core.Composio;

// Port of HermesKit/Composio/ComposioSignIn.swift (docs/spec/3x-capabilities.md §10.13):
// Hides OAuth-only apps for which Composio provides no managed OAuth app unless the owner created their own auth config
// or already connected the app.

public static class ComposioSignIn
{
    public static readonly IReadOnlySet<string> OAuthSchemes = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "OAUTH1", "OAUTH2",
    };

    public static readonly Uri Dashboard = new("https://platform.composio.dev");

    /// True when a catalog row (`GET /api/v3/toolkits`) signs in only by OAuth that Composio doesn't manage.
    public static bool NeedsOwnApp(JsonNode? row)
    {
        if (row == null) return false;
        if (row.Bool("no_auth") == true || row.Bool("is_no_auth") == true) return false;
        var managed = (row.Arr("composio_managed_auth_schemes") ?? []).Select(J.AsString).OfType<string>().ToList();
        if (managed.Count > 0) return false;
        var schemes = (row.Arr("auth_schemes") ?? [])
            .Select(J.AsString)
            .OfType<string>()
            .Select(s => s.ToUpperInvariant())
            .ToList();
        return schemes.Count > 0 && schemes.All(OAuthSchemes.Contains);
    }

    /// True when lists should omit `toolkit` because it requires a developer OAuth app the owner hasn't configured.
    public static bool Hidden(ComposioToolkit toolkit, IReadOnlySet<string> needsOwnApp, IReadOnlySet<string> configured)
    {
        var slug = toolkit.Slug.ToLowerInvariant();
        if (!needsOwnApp.Contains(slug) || configured.Contains(slug)) return false;
        return !toolkit.NoAuth && !toolkit.Connected && toolkit.Account == null && toolkit.ManagedSchemes.Count == 0;
    }

    public static bool IsOwnAppRefusal(ComposioException error) =>
        error.Message.Contains("does not manage auth", StringComparison.OrdinalIgnoreCase);

    public static string OwnAppMessage(string name) =>
        $"Composio doesn’t provide a sign-in for {name}. To connect it, add your own {name} developer app as an auth config in your Composio dashboard, then try again.";
}
