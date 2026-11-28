using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Hermes.Core.Composio;

// Port of HermesKit/Composio/ComposioIdentity.swift (docs/spec/3x-capabilities.md §10.12):
// Read-only who-am-I tool lookup per app so multi-account rows show the signed-in email/name without logging addresses.

public sealed record ComposioIdentity(string Email, string Name = "");

public static class ComposioWhoAmI
{
    public sealed record Entry(
        string Tool,
        JsonObject Arguments,
        string[][] EmailPaths,
        string[][] NamePaths,
        bool CheckedLive = false);

    private static JsonObject Obj(params (string Key, string Value)[] pairs)
    {
        var o = new JsonObject();
        foreach (var (k, v) in pairs) o[k] = v;
        return o;
    }

    public static readonly IReadOnlyDictionary<string, Entry> Table = new Dictionary<string, Entry>(StringComparer.Ordinal)
    {
        ["googledrive"] = new("GOOGLEDRIVE_GET_ABOUT", Obj(("fields", "user")),
            [["user", "emailAddress"]], [["user", "displayName"]], CheckedLive: true),
        ["notion"] = new("NOTION_GET_ABOUT_ME", new JsonObject(),
            [["response_data", "bot", "owner", "user", "person", "email"]],
            [["response_data", "bot", "owner", "user", "name"]], CheckedLive: true),
        ["clickup"] = new("CLICKUP_GET_AUTHORIZED_USER", new JsonObject(),
            [["user", "email"]], [["user", "username"]], CheckedLive: true),
        ["salesforce"] = new("SALESFORCE_GET_USER_INFO", new JsonObject(),
            [["response_data", "email"], ["response_data", "preferred_username"]],
            [["response_data", "name"]], CheckedLive: true),
        ["gmail"] = new("GMAIL_GET_PROFILE", Obj(("user_id", "me")),
            [["response_data", "emailAddress"], ["emailAddress"]], []),
        ["googlecalendar"] = new("GOOGLECALENDAR_GET_CALENDAR", Obj(("calendar_id", "primary")),
            [["calendar_data", "id"], ["calendar_data", "summary"], ["id"]], []),
        ["linear"] = new("LINEAR_GET_CURRENT_USER", new JsonObject(),
            [["user", "email"]], [["user", "name"]]),
        ["outlook"] = new("OUTLOOK_OUTLOOK_GET_PROFILE", Obj(("user_id", "me")),
            [["response_data", "mail"], ["response_data", "userPrincipalName"]],
            [["response_data", "displayName"]]),
        ["github"] = new("GITHUB_GET_THE_AUTHENTICATED_USER", new JsonObject(),
            [["email"], ["response_data", "email"]],
            [["name"], ["login"], ["response_data", "name"], ["response_data", "login"]]),
    };

    private static readonly Regex EmailPattern = new(@"^[^\s@]+@[^\s@]+\.[^\s@]+$", RegexOptions.CultureInvariant);

    private static readonly IReadOnlySet<string> EmailKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "emailaddress", "email", "mail", "userprincipalname", "primary_email",
    };

    public static Entry? ForToolkit(string slug) =>
        Table.TryGetValue(slug.ToLowerInvariant(), out var entry) ? entry : null;

    public static bool LooksLikeEmail(string text) =>
        text.Length <= 254 && EmailPattern.IsMatch(text);

    /// Reads the person's identity from a tool execution response (`{"successful":true,"data":{...}}`).
    public static ComposioIdentity? Read(JsonNode? answer, Entry entry)
    {
        if (answer == null || answer.Bool("successful") == false) return null;
        if (answer.Obj("data") is not { } data) return null;

        string? At(string[] path)
        {
            JsonNode? cur = data;
            foreach (var key in path) cur = cur.Get(key);
            return J.AsString(cur)?.Trim() is { Length: > 0 } s ? s : null;
        }

        var email = entry.EmailPaths.Select(At).FirstOrDefault(v => v != null && LooksLikeEmail(v))
            ?? Search(data, depth: 0)
            ?? "";
        var name = entry.NamePaths.Select(At).FirstOrDefault(v => v is { Length: > 0 and <= 120 }) ?? "";
        if (email.Length == 0 && name.Length == 0) return null;
        return new ComposioIdentity(email, string.Equals(name, email, StringComparison.Ordinal) ? "" : name);
    }

    private static string? Search(JsonNode? value, int depth)
    {
        if (depth >= 5 || value == null) return null;
        if (value is JsonObject obj)
        {
            var keys = obj.Select(p => p.Key).OrderBy(k => k, StringComparer.Ordinal).ToList();
            foreach (var key in keys)
            {
                if (!EmailKeys.Contains(key)) continue;
                var text = J.AsString(obj[key])?.Trim();
                if (text != null && LooksLikeEmail(text)) return text;
            }
            foreach (var key in keys)
            {
                if (Search(obj[key], depth + 1) is { } found) return found;
            }
        }
        else if (value is JsonArray arr)
        {
            var count = Math.Min(arr.Count, 5);
            for (var i = 0; i < count; i++)
            {
                if (Search(arr[i], depth + 1) is { } found) return found;
            }
        }
        return null;
    }
}
