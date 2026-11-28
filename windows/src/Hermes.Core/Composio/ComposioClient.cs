using System.Globalization;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Capabilities;
using Hermes.Core.Gateways;

namespace Hermes.Core.Composio;

// Port of HermesKit/Composio/ComposioClient.swift (docs/spec/3x-capabilities.md §10.2, §10.3):
// Direct HTTPS client to https://backend.composio.dev with `x-api-key`, `AllowAutoRedirect = false`, no cookies,
// strict destination check, key-redacted error words, tool router sessions, toolkits, Connect Links, connected accounts,
// tools, who-am-I execution, catalog, and auth configs.

public enum ComposioErrorKind
{
    BadKey,
    NotFound,
    RateLimited,
    Server,
    Rejected,
    NoKey,
    Network,
}

public sealed class ComposioException(ComposioErrorKind kind, string message) : Exception(message)
{
    public ComposioErrorKind Kind { get; } = kind;

    public static ComposioException NoKey => new(ComposioErrorKind.NoKey, "Add your Composio API key first.");
    public static ComposioException Problem => new(ComposioErrorKind.Server, "Composio had a problem. Try again.");
}

/// Per-account Composio API key storage abstraction (`ComposioKeychain` on macOS, DPAPI on Windows).
public interface IComposioKeyStore
{
    string? ReadKey(string accountId);
    void SaveKey(string accountId, string apiKey);
    void DeleteKey(string accountId);
}

public static class ComposioKeyStoreExtensions
{
    public static (bool Saved, string Hint) Status(this IComposioKeyStore store, string accountId)
    {
        var key = store.ReadKey(accountId);
        if (string.IsNullOrEmpty(key)) return (false, "");
        return (true, key.Length >= 4 ? key[^4..] : key);
    }
}

/// Validation rules for Composio API keys (`ComposioKeychain.plausible`).
public static class ComposioKeyRules
{
    private static readonly Regex PlausiblePattern = new(@"^[A-Za-z0-9_.\-]{8,256}$", RegexOptions.CultureInvariant);

    /// 8 to 256 characters of `[A-Za-z0-9_.-]`.
    public static bool Plausible(string? key) => !string.IsNullOrEmpty(key) && PlausiblePattern.IsMatch(key);
}

/// In-memory key store for unit tests and automation runs.
public sealed class MemoryComposioKeyStore : IComposioKeyStore
{
    private readonly Dictionary<string, string> _keys = new(StringComparer.Ordinal);

    public string? ReadKey(string accountId)
    {
        lock (_keys) return _keys.TryGetValue(accountId, out var k) && k.Length > 0 ? k : null;
    }

    public void SaveKey(string accountId, string apiKey)
    {
        if (!ComposioKeyRules.Plausible(apiKey))
            throw new ComposioException(ComposioErrorKind.BadKey, "That doesn’t look like a Composio key.");
        lock (_keys) _keys[accountId] = apiKey;
    }

    public void DeleteKey(string accountId)
    {
        lock (_keys) _keys.Remove(accountId);
    }
}

// ------------------------------------------------------------------ Wire models

public sealed record ComposioSession(string Id, string McpUrl, string UserId, bool? MultiAccount = null)
{
    private static readonly Regex McpSessionPattern = new(@"/tool_router/(?:v\d+/)?([^/?#]+)/mcp", RegexOptions.CultureInvariant);

    /// Extracts `<id>` from `/tool_router/(v<n>/)?<id>/mcp`.
    public static string? IdFromMcpUrl(string? url)
    {
        if (string.IsNullOrEmpty(url)) return null;
        var m = McpSessionPattern.Match(url);
        return m.Success ? m.Groups[1].Value : null;
    }

    public static ComposioSession? Read(JsonNode? value)
    {
        var id = value.Text("session_id") ?? value.Text("id");
        if (id == null) return null;
        return new ComposioSession(
            Id: id,
            McpUrl: value.Obj("mcp").Str("url") ?? "",
            UserId: value.Obj("config").Text("user_id") ?? value.Str("user_id") ?? "",
            MultiAccount: value.Obj("config").Obj("multi_account").Bool("enable")
                ?? value.Obj("multi_account").Bool("enable"));
    }

    /// Multi-account session config (`ComposioSession.multiAccountConfig`).
    public static JsonObject MultiAccountConfig() => new()
    {
        ["enable"] = true,
        ["max_accounts_per_toolkit"] = 5,
        ["require_explicit_selection"] = false,
    };

    /// Whether this session supports multiple accounts per toolkit.
    public static bool IsMultiAccount(ComposioSession session, IReadOnlySet<string> known) =>
        session.MultiAccount ?? known.Contains(session.Id);
}

public sealed record ComposioAccount(
    string Id,
    string Status,
    string Reason,
    string CreatedAt,
    string Alias = "",
    string WordId = "")
{
    public bool IsActive => Status == "ACTIVE";

    /// ACTIVE, EXPIRED or INACTIVE: the app was connected at some point (INITIATED sign-ins are excluded).
    public bool WasConnected => Status is "ACTIVE" or "EXPIRED" or "INACTIVE";

    public bool NeedsSignIn => Status is "EXPIRED" or "INACTIVE";

    public static ComposioAccount? Read(JsonNode? value)
    {
        if (value == null) return null;
        var id = value.Text("id") ?? value.Text("nanoid");
        if (id == null) return null;
        return new ComposioAccount(
            Id: id,
            Status: (value.Text("status") ?? "").ToUpperInvariant(),
            Reason: value.Text("status_reason") ?? value.Str("statusReason") ?? "",
            CreatedAt: value.Text("created_at") ?? value.Str("createdAt") ?? "",
            Alias: value.Text("alias") ?? "",
            WordId: value.Text("word_id") ?? "");
    }

    /// Display title without identity: alias ("Work Drive"), else "Account <n>".
    public string Title(int number) =>
        string.IsNullOrEmpty(Alias) ? $"Account {number}" : ComposioAlias.Shown(Alias);

    /// Display title with identity (§10.12): alias, else email, else "Account <n>".
    public string Title(int number, ComposioIdentity? identity)
    {
        if (!string.IsNullOrEmpty(Alias)) return ComposioAlias.Shown(Alias);
        if (!string.IsNullOrEmpty(identity?.Email)) return identity.Email;
        return $"Account {number}";
    }

    /// Subtitle email line when the title is the alias (an email used as title is not repeated).
    public string? EmailLine(ComposioIdentity? identity) =>
        !string.IsNullOrEmpty(Alias) && !string.IsNullOrEmpty(identity?.Email) ? identity.Email : null;
}

/// Account short-name normalization and suggestions (`ComposioAlias` in `ComposioClient.swift` & `ComposioIdentity.swift`).
public static class ComposioAlias
{
    public const int MaxLength = 32;

    /// Normalizes typed text into Composio's rule: ASCII lowercase letters, digits, and single `-` separators, <= 32 chars.
    public static string? Normalized(string typed)
    {
        var sb = new StringBuilder(Math.Min(typed.Length, MaxLength));
        var dash = false;
        foreach (var ch in typed.ToLowerInvariant())
        {
            if (ch <= 0x7F && (char.IsAsciiLetter(ch) || char.IsAsciiDigit(ch)))
            {
                sb.Append(ch);
                dash = false;
            }
            else if ((ch is '-' or '_' || char.IsWhiteSpace(ch)) && sb.Length > 0 && !dash)
            {
                sb.Append('-');
                dash = true;
            }
        }
        while (sb.Length > 0 && sb[^1] == '-') sb.Length--;
        if (sb.Length > MaxLength) sb.Length = MaxLength;
        while (sb.Length > 0 && sb[^1] == '-') sb.Length--;
        return sb.Length == 0 ? null : sb.ToString();
    }

    /// `"work-drive"` -> `"Work Drive"`.
    public static string Shown(string alias) =>
        string.Join(" ", alias.Split('-', StringSplitOptions.RemoveEmptyEntries)
            .Select(part => char.ToUpperInvariant(part[0]) + part[1..]));

    /// Mail providers whose domains say nothing about the owner's organization: suggested as `"personal"`.
    public static readonly IReadOnlySet<string> PersonalDomains = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "icloud.com", "me.com", "mac.com",
        "yahoo.com", "ymail.com", "aol.com", "proton.me", "protonmail.com", "pm.me", "gmx.com", "gmx.net", "fastmail.com",
        "hey.com", "zoho.com", "yandex.com", "mail.com",
    };

    private static readonly IReadOnlySet<string> SecondLevelTlds = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "co", "com", "org", "net", "ac", "gov", "edu",
    };

    /// Suggests a short alias for an unnamed account from its email address (`ComposioAlias.suggestion`).
    public static string? Suggestion(string email, IReadOnlySet<string>? taken = null)
    {
        if (!ComposioWhoAmI.LooksLikeEmail(email)) return null;
        var at = email.IndexOf('@');
        if (at <= 0 || at >= email.Length - 1) return null;
        var local = email[..at].ToLowerInvariant();
        var domain = email[(at + 1)..].ToLowerInvariant();

        string? first;
        if (PersonalDomains.Contains(domain))
        {
            first = "personal";
        }
        else
        {
            var labels = domain.Split('.', StringSplitOptions.RemoveEmptyEntries).ToList();
            if (labels.Count > 1) labels.RemoveAt(labels.Count - 1);
            if (labels.Count > 1 && SecondLevelTlds.Contains(labels[^1])) labels.RemoveAt(labels.Count - 1);
            first = labels.Count > 0 ? Normalized(labels[^1]) : null;
        }

        var plus = local.IndexOf('+');
        var localBase = (plus >= 0 ? local[..plus] : local).Replace('.', '-');
        var local0 = Normalized(localBase);

        foreach (var candidate in new[] { first, local0 })
        {
            if (candidate != null && (taken == null || !taken.Contains(candidate)))
                return candidate;
        }
        return null;
    }
}

public sealed record ComposioToolkit(
    string Slug,
    string Name,
    string Logo,
    string Description,
    bool NoAuth,
    ComposioAccount? Account,
    IReadOnlyList<string> ManagedSchemes)
{
    public string Id => Slug;
    public bool Connected => Account?.WasConnected ?? false;
    public bool NeedsSignIn => Account?.NeedsSignIn ?? false;

    public static ComposioToolkit? Read(JsonNode? row)
    {
        if (row.Text("slug") is not { } slug) return null;
        var meta = row.Obj("meta");
        var managed = (row.Arr("composio_managed_auth_schemes") ?? [])
            .Select(J.AsString)
            .OfType<string>()
            .ToList();
        return new ComposioToolkit(
            Slug: slug,
            Name: row.Text("name") ?? slug,
            Logo: meta.Str("logo") ?? "",
            Description: meta.Str("description") ?? "",
            NoAuth: row.Bool("is_no_auth") ?? meta.Bool("isNoAuth") ?? false,
            Account: ComposioAccount.Read(row.Get("connected_account")),
            ManagedSchemes: managed);
    }
}

public sealed record ToolkitPage(IReadOnlyList<ComposioToolkit> Items, string Next);

public sealed record ConnectLink(string RedirectUrl, string AccountId);

public sealed record ComposioTool(string Slug, string Name, string Description)
{
    public string Id => Slug;
}

// ------------------------------------------------------------------ Client

/// Direct HTTPS client for Composio (`https://backend.composio.dev`).
/// Never follows redirects (`AllowAutoRedirect = false`), never stores cookies, sends `x-api-key` only to the
/// validated base host, and masks the key out of any error message.
public sealed class ComposioClient : IDisposable
{
    public static readonly Uri ProductionBase = new("https://backend.composio.dev");
    private const int MaxResponseBytes = 2 * 1024 * 1024;
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(20);

    public static Uri DefaultBase
    {
        get
        {
#if DEBUG
            if (Environment.GetEnvironmentVariable("HQN_COMPOSIO_BASE") is { } raw && Loopback(raw) is { } url)
                return url;
#endif
            return ProductionBase;
        }
    }

    public static Uri? Loopback(string raw)
    {
        if (!Uri.TryCreate(raw, UriKind.Absolute, out var uri)) return null;
        if (uri.Scheme != "http" || uri.UserInfo.Length > 0) return null;
        return uri.Host is "127.0.0.1" or "localhost" or "::1" or "[::1]" ? uri : null;
    }

    /// Creates the default transport handler: `AllowAutoRedirect = false` and `UseCookies = false`.
    public static SocketsHttpHandler CreateDefaultHandler() => new()
    {
        AllowAutoRedirect = false,
        UseCookies = false,
        ConnectTimeout = RequestTimeout,
        PooledConnectionIdleTimeout = TimeSpan.FromSeconds(60),
    };

    private readonly IComposioKeyStore _keys;
    private readonly string _accountId;
    private readonly HttpClient _http;
    private readonly Uri _base;
    private readonly bool _ownsHttp;

    public ComposioClient(
        IComposioKeyStore keys,
        string accountId = "default",
        HttpMessageHandler? handler = null,
        Uri? baseUri = null)
    {
        _keys = keys;
        _accountId = accountId;
        _base = baseUri ?? DefaultBase;
        var ownedHandler = handler == null;
        _http = new HttpClient(handler ?? CreateDefaultHandler(), disposeHandler: ownedHandler)
        {
            Timeout = RequestTimeout,
        };
        _ownsHttp = true;
    }

    public void Dispose()
    {
        if (_ownsHttp) _http.Dispose();
    }

    public static string Segment(string value)
    {
        if (value is "." or "..") return "_";
        return Uri.EscapeDataString(value);
    }

    private async Task<JsonNode?> SendAsync(
        HttpMethod method,
        string path,
        IEnumerable<KeyValuePair<string, string>>? query = null,
        JsonNode? body = null,
        string? keyOverride = null,
        CancellationToken ct = default)
    {
        var key = keyOverride ?? _keys.ReadKey(_accountId);
        if (string.IsNullOrEmpty(key)) throw ComposioException.NoKey;

        var url = BuildUrl(path, query);
        if (url == null || !string.Equals(url.Host, _base.Host, StringComparison.OrdinalIgnoreCase)
            || !string.Equals(url.Scheme, _base.Scheme, StringComparison.OrdinalIgnoreCase))
            throw ComposioException.Problem;

        using var req = new HttpRequestMessage(method, url);
        req.Headers.TryAddWithoutValidation("x-api-key", key);
        req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (body != null)
            req.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");

        HttpResponseMessage res;
        byte[] data;
        try
        {
            res = await _http.SendAsync(req, HttpCompletionOption.ResponseContentRead, ct).ConfigureAwait(false);
            using (res)
            {
                data = await res.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (TaskCanceledException)
        {
            throw new ComposioException(ComposioErrorKind.Network, "Composio took too long to answer");
        }
        catch (HttpRequestException ex) when (ex.StatusCode == null)
        {
            throw new ComposioException(ComposioErrorKind.Network, "Couldn’t reach Composio");
        }
        catch (HttpRequestException)
        {
            throw new ComposioException(ComposioErrorKind.Network, "Couldn’t reach Composio");
        }

        if (data.Length > MaxResponseBytes) throw ComposioException.Problem;
        var text = data.Length > 0 ? Encoding.UTF8.GetString(data) : "";
        var value = text.Length > 0 ? J.Parse(text) : null;
        var status = (int)res.StatusCode;
        if (status is >= 200 and < 300) return value;
        throw Error(status, value, key);
    }

    private Uri? BuildUrl(string path, IEnumerable<KeyValuePair<string, string>>? query)
    {
        var sb = new StringBuilder(_base.GetLeftPart(UriPartial.Authority)).Append(path);
        if (query != null)
        {
            var first = true;
            foreach (var (k, v) in query)
            {
                sb.Append(first ? '?' : '&')
                    .Append(Uri.EscapeDataString(k))
                    .Append('=')
                    .Append(Uri.EscapeDataString(v));
                first = false;
            }
        }
        return Uri.TryCreate(sb.ToString(), UriKind.Absolute, out var url) ? url : null;
    }

    /// Composio's `error.message` / `message`, capped at 300 chars with the API key and secret-shaped tokens masked.
    public static string? Message(JsonNode? body, string key = "")
    {
        var raw = body.Obj("error").Text("message") ?? body.Text("message");
        if (raw == null) return null;
        var stripped = string.IsNullOrEmpty(key) ? raw : raw.Replace(key, McpEntryMask.MASK, StringComparison.Ordinal);
        var masked = McpEntryMask.Phone.Text(stripped);
        return masked.Length > 300 ? masked[..300] : masked;
    }

    public static ComposioException Error(int status, JsonNode? body, string key = "")
    {
        var own = Message(body, key);
        return status switch
        {
            401 => new ComposioException(ComposioErrorKind.BadKey, "Composio didn’t accept this API key."),
            403 => new ComposioException(ComposioErrorKind.BadKey, own ?? "This API key can’t use that Composio project."),
            404 => new ComposioException(ComposioErrorKind.NotFound, own ?? "Composio couldn’t find that."),
            429 => new ComposioException(ComposioErrorKind.RateLimited, "Composio is rate-limiting requests. Try again in a minute."),
            408 or >= 500 => ComposioException.Problem,
            >= 300 and < 400 => ComposioException.Problem, // refused redirect
            _ => new ComposioException(ComposioErrorKind.Rejected, own ?? $"Composio refused the request ({status})."),
        };
    }

    private static ComposioSession RequireSession(JsonNode? value) =>
        ComposioSession.Read(value) ?? throw ComposioException.Problem;

    public async Task<ComposioSession> CreateSessionAsync(string userId, CancellationToken ct = default)
    {
        var body = new JsonObject
        {
            ["user_id"] = userId,
            ["manage_connections"] = new JsonObject { ["enable"] = true },
            ["multi_account"] = ComposioSession.MultiAccountConfig(),
        };
        return RequireSession(await SendAsync(HttpMethod.Post, "/api/v3.1/tool_router/session", body: body, ct: ct).ConfigureAwait(false));
    }

    public async Task<ComposioSession> ReadSessionAsync(string id, CancellationToken ct = default) =>
        RequireSession(await SendAsync(HttpMethod.Get, $"/api/v3.1/tool_router/session/{Segment(id)}", ct: ct).ConfigureAwait(false));

    /// Validates an unsaved API key by reading an existing session (falling back to creating one on 404).
    public async Task<ComposioSession> CheckAsync(string key, string userId, string? sessionId = null, CancellationToken ct = default)
    {
        if (!string.IsNullOrEmpty(sessionId))
        {
            try
            {
                return RequireSession(await SendAsync(HttpMethod.Get, $"/api/v3.1/tool_router/session/{Segment(sessionId)}",
                    keyOverride: key, ct: ct).ConfigureAwait(false));
            }
            catch (ComposioException ex) when (ex.Kind == ComposioErrorKind.NotFound) { }
        }
        var body = new JsonObject
        {
            ["user_id"] = userId,
            ["manage_connections"] = new JsonObject { ["enable"] = true },
            ["multi_account"] = ComposioSession.MultiAccountConfig(),
        };
        return RequireSession(await SendAsync(HttpMethod.Post, "/api/v3.1/tool_router/session",
            body: body, keyOverride: key, ct: ct).ConfigureAwait(false));
    }

    public async Task<ToolkitPage> ToolkitsAsync(
        string sessionId,
        string search = "",
        IReadOnlyList<string>? slugs = null,
        string cursor = "",
        int limit = 30,
        bool connectedOnly = false,
        CancellationToken ct = default)
    {
        var query = new List<KeyValuePair<string, string>> { new("limit", limit.ToString(CultureInfo.InvariantCulture)) };
        if (!string.IsNullOrEmpty(search)) query.Add(new("search", search));
        if (slugs is { Count: > 0 }) query.Add(new("toolkits", string.Join(",", slugs)));
        if (!string.IsNullOrEmpty(cursor)) query.Add(new("cursor", cursor));
        if (connectedOnly) query.Add(new("is_connected", "true"));

        var value = await SendAsync(HttpMethod.Get, $"/api/v3.1/tool_router/session/{Segment(sessionId)}/toolkits", query, ct: ct).ConfigureAwait(false);
        var items = (value.Arr("items") ?? []).Select(ComposioToolkit.Read).OfType<ComposioToolkit>().ToList();
        var next = value.Text("next_cursor") ?? (value.Int("next_cursor") is { } n ? n.ToString(CultureInfo.InvariantCulture) : "");
        return new ToolkitPage(items, next);
    }

    /// Creates a single-use Connect Link. When `alias` is specified, uses the v3.1 named-link route.
    public async Task<ConnectLink> LinkAsync(
        string sessionId,
        string toolkit,
        string? alias = null,
        string? callback = null,
        CancellationToken ct = default)
    {
        var path = alias != null
            ? $"/api/v3.1/tool_router/session/{Segment(sessionId)}/link"
            : $"/api/v3/tool_router/session/{Segment(sessionId)}/link";
        var body = new JsonObject { ["toolkit"] = toolkit };
        if (alias != null) body["alias"] = alias;
        if (!string.IsNullOrEmpty(callback)) body["callback_url"] = callback;

        var value = await SendAsync(HttpMethod.Post, path, body: body, ct: ct).ConfigureAwait(false);
        var url = value.Text("redirect_url") ?? throw ComposioException.Problem;
        return new ConnectLink(url, value.Str("connected_account_id") ?? "");
    }

    public async Task<ComposioAccount> AccountAsync(string id, CancellationToken ct = default) =>
        ComposioAccount.Read(await SendAsync(HttpMethod.Get, $"/api/v3/connected_accounts/{Segment(id)}", ct: ct).ConfigureAwait(false))
        ?? throw ComposioException.Problem;

    public async Task DisconnectAsync(string id, CancellationToken ct = default) =>
        await SendAsync(HttpMethod.Delete, $"/api/v3/connected_accounts/{Segment(id)}", ct: ct).ConfigureAwait(false);

    /// Lists all connected/expired/inactive accounts for `userId` and `toolkit`, sorted oldest first.
    public async Task<List<ComposioAccount>> AccountsAsync(string userId, string toolkit, CancellationToken ct = default)
    {
        KeyValuePair<string, string>[] query =
        [
            new("user_ids", userId),
            new("toolkit_slugs", toolkit),
            new("order_by", "created_at"),
            new("order_direction", "asc"),
            new("limit", "50"),
        ];
        var value = await SendAsync(HttpMethod.Get, "/api/v3.1/connected_accounts", query, ct: ct).ConfigureAwait(false);
        var all = (value.Arr("items") ?? [])
            .Select(ComposioAccount.Read)
            .OfType<ComposioAccount>()
            .Where(a => a.WasConnected)
            .Select((a, idx) => (Account: a, Index: idx, Date: ComposioCatalog.ParseDate(a.CreatedAt)))
            .ToList();

        all.Sort((a, b) =>
        {
            if (a.Date.HasValue && b.Date.HasValue && a.Date.Value != b.Date.Value)
                return a.Date.Value.CompareTo(b.Date.Value);
            return a.Index.CompareTo(b.Index);
        });
        return [.. all.Select(x => x.Account)];
    }

    /// Sets or clears an account's alias via `PATCH /api/v3.1/connected_accounts/<id>`.
    public async Task RenameAsync(string id, string alias, CancellationToken ct = default) =>
        await SendAsync(HttpMethod.Patch, $"/api/v3.1/connected_accounts/{Segment(id)}",
            body: new JsonObject { ["alias"] = alias }, ct: ct).ConfigureAwait(false);

    /// Runs the app's read-only who-am-I tool against a single account (`ComposioWhoAmI.Table` only).
    public async Task<ComposioIdentity?> IdentityAsync(string accountId, string toolkit, string userId, CancellationToken ct = default)
    {
        var entry = ComposioWhoAmI.ForToolkit(toolkit);
        if (entry == null || string.IsNullOrEmpty(accountId) || string.IsNullOrEmpty(userId)) return null;
        var body = new JsonObject
        {
            ["connected_account_id"] = accountId,
            ["user_id"] = userId,
            ["arguments"] = entry.Arguments.DeepClone(),
        };
        var answer = await SendAsync(HttpMethod.Post, $"/api/v3/tools/execute/{Segment(entry.Tool)}", body: body, ct: ct).ConfigureAwait(false);
        return ComposioWhoAmI.Read(answer, entry);
    }

    /// Reads up to 5 pages of `/api/v3/toolkits` to identify OAuth-only toolkits without Composio-managed auth (§10.13).
    public async Task<HashSet<string>> AppsNeedingOwnSignInAsync(CancellationToken ct = default)
    {
        var result = new HashSet<string>(StringComparer.Ordinal);
        var cursor = "";
        for (var i = 0; i < 5; i++)
        {
            var query = new List<KeyValuePair<string, string>> { new("limit", "1000") };
            if (!string.IsNullOrEmpty(cursor)) query.Add(new("cursor", cursor));
            var value = await SendAsync(HttpMethod.Get, "/api/v3/toolkits", query, ct: ct).ConfigureAwait(false);
            foreach (var row in value.Arr("items") ?? [])
            {
                if (ComposioSignIn.NeedsOwnApp(row) && row.Text("slug") is { } slug)
                    result.Add(slug.ToLowerInvariant());
            }
            cursor = value.Text("next_cursor") ?? "";
            if (cursor.Length == 0) break;
        }
        return result;
    }

    /// Reads `/api/v3/auth_configs` returning toolkit slugs with non-disabled user auth configs.
    public async Task<HashSet<string>> AppsWithOwnAuthConfigAsync(CancellationToken ct = default)
    {
        var value = await SendAsync(HttpMethod.Get, "/api/v3/auth_configs", [new("limit", "200")], ct: ct).ConfigureAwait(false);
        var result = new HashSet<string>(StringComparer.Ordinal);
        foreach (var row in value.Arr("items") ?? [])
        {
            if (string.Equals(row.Text("status"), "DISABLED", StringComparison.OrdinalIgnoreCase)) continue;
            if (row.Obj("toolkit").Text("slug") is { } slug) result.Add(slug.ToLowerInvariant());
        }
        return result;
    }

    /// Fetches actions for `toolkit`: queries `important=true` first, falling back without the filter when empty.
    public async Task<List<ComposioTool>> ToolsAsync(string toolkit, CancellationToken ct = default)
    {
        static List<ComposioTool> ReadTools(JsonNode? v) =>
        [
            .. (v.Arr("items") ?? [])
                .Select(row => row.Text("slug") is { } s
                    ? new ComposioTool(s, row.Text("name") ?? s, row.Str("description") ?? "")
                    : null)
                .OfType<ComposioTool>(),
        ];

        var important = ReadTools(await SendAsync(HttpMethod.Get, "/api/v3/tools",
            [new("toolkit_slug", toolkit), new("limit", "50"), new("important", "true")], ct: ct).ConfigureAwait(false));
        if (important.Count > 0) return important;
        return ReadTools(await SendAsync(HttpMethod.Get, "/api/v3/tools",
            [new("toolkit_slug", toolkit), new("limit", "50")], ct: ct).ConfigureAwait(false));
    }

    /// Validates a Connect Link URL: must be `https` on `composio.dev` or `*.composio.dev` with no userinfo
    /// (or matching the stand-in loopback base in DEBUG/testing).
    public static Uri? ConnectLinkUrl(string raw, Uri? baseUri = null)
    {
        if (!Uri.TryCreate(raw, UriKind.Absolute, out var uri)) return null;
        if (uri.UserInfo.Length > 0 || string.IsNullOrEmpty(uri.Host)) return null;
        var host = uri.Host.ToLowerInvariant();
        if (uri.Scheme == "https" && (host == "composio.dev" || host.EndsWith(".composio.dev", StringComparison.Ordinal)))
            return uri;
        var effectiveBase = baseUri ?? DefaultBase;
        if (!effectiveBase.Equals(ProductionBase)
            && uri.Scheme == effectiveBase.Scheme
            && string.Equals(host, effectiveBase.Host, StringComparison.OrdinalIgnoreCase)
            && uri.Port == effectiveBase.Port)
            return uri;
        return null;
    }

    /// Validates a toolkit logo URL (never sends the API key).
    public static Uri? LogoUrl(string slug, string logo, Uri? baseUri = null)
    {
        var effectiveBase = baseUri ?? DefaultBase;
        var cleanSlug = new string(slug.Where(char.IsLetterOrDigit).ToArray());
        if (!effectiveBase.Equals(ProductionBase))
            return Uri.TryCreate(effectiveBase, $"/__mock/logo/{cleanSlug}", out var mock) ? mock : null;
        if (Uri.TryCreate(logo, UriKind.Absolute, out var u) && u.Scheme == "https" && !string.IsNullOrEmpty(u.Host) && u.UserInfo.Length == 0)
            return u;
        return Uri.TryCreate($"https://logos.composio.dev/api/{cleanSlug}", UriKind.Absolute, out var fallback) ? fallback : null;
    }

    public static string OfflineMessage => $"This {DeviceWord.Name} is offline";
}

// ------------------------------------------------------------------ Catalog & wording

public sealed record ComposioCategory(string Id, string Title, string Glyph, uint Color, IReadOnlyList<string> Slugs);

public static class ComposioCatalog
{
    public static readonly IReadOnlyList<string> Popular =
    [
        "gmail", "googlecalendar", "googledrive", "slack", "github", "notion", "outlook", "googlesheets",
        "linear", "dropbox", "hubspot", "googledocs", "jira", "asana", "trello", "zoom",
    ];

    public const int PopularShown = 8;

    public static readonly IReadOnlyList<string> Hero = ["gmail", "googlecalendar", "github", "slack", "notion"];

    public static readonly IReadOnlyList<ComposioCategory> Categories =
    [
        new("email", "Email & Calendar", "\uE715", 0xD93025,
            ["gmail", "googlecalendar", "outlook", "calendly", "cal", "mailchimp", "sendgrid"]),
        new("docs", "Docs & Files", "\uE8A5", 0x1A5FD0,
            ["googledrive", "googledocs", "googlesheets", "notion", "dropbox", "box", "one_drive", "airtable", "confluence"]),
        new("chat", "Chat & Meetings", "\uE8BD", 0x248A3D,
            ["slack", "discord", "microsoft_teams", "zoom", "telegram", "whatsapp"]),
        new("dev", "Developer Tools", "\uE943", 0x3A3A3C,
            ["github", "gitlab", "linear", "jira", "sentry", "vercel", "supabase", "bitbucket"]),
        new("sales", "Sales & CRM", "\uE821", 0xB45309,
            ["hubspot", "salesforce", "pipedrive", "attio", "apollo", "zoho"]),
        new("tasks", "Tasks & Projects", "\uE762", 0x6D28D9,
            ["asana", "trello", "todoist", "clickup", "monday", "linear", "notion"]),
    ];

    private static readonly IReadOnlyDictionary<string, IReadOnlyList<string>> Prompts = new Dictionary<string, IReadOnlyList<string>>(StringComparer.Ordinal)
    {
        ["gmail"] = ["What’s new in my inbox today?", "Draft a reply to my latest email"],
        ["outlook"] = ["What’s new in my inbox today?", "Draft a reply to my latest email"],
        ["googlecalendar"] = ["What’s on my calendar tomorrow?", "Find a free hour this week"],
        ["googledrive"] = ["Find my most recent documents", "What’s in my shared folders?"],
        ["googledocs"] = ["Summarize my latest document", "Start a new doc with meeting notes"],
        ["googlesheets"] = ["What’s in my most recent spreadsheet?", "Add a row to my latest sheet"],
        ["slack"] = ["What did I miss in Slack today?", "Draft a message to my team"],
        ["github"] = ["What pull requests need my review?", "Summarize my open issues"],
        ["notion"] = ["Find my most recent Notion pages", "Add a to-do to my Notion"],
        ["linear"] = ["What issues are assigned to me?", "Create an issue for a bug I found"],
        ["jira"] = ["What issues are assigned to me?", "Summarize this sprint"],
        ["hubspot"] = ["Show my newest contacts", "Which deals closed this month?"],
    };

    public static IReadOnlyList<string> TryIt(string slug, string name) =>
        Prompts.TryGetValue(slug, out var list) ? list : [$"What can you do with {name}?"];

    /// `"Hermes"`, `"Hermes and Inbox"`, `"Hermes, Inbox and Ivy"`, `"Hermes, Inbox and 3 more"`.
    public static string NameList(IReadOnlyList<string> names) => names.Count switch
    {
        0 => "",
        1 => names[0],
        2 => $"{names[0]} and {names[1]}",
        3 => $"{names[0]}, {names[1]} and {names[2]}",
        _ => $"{names[0]}, {names[1]} and {names.Count - 2} more",
    };

    public static DateTimeOffset? ParseDate(string? iso)
    {
        if (string.IsNullOrWhiteSpace(iso)) return null;
        return DateTimeOffset.TryParse(iso, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var dt) ? dt : null;
    }

    public static string ConnectedDate(string? iso, bool shortFormat = false, CultureInfo? culture = null)
    {
        if (ParseDate(iso) is not { } dt) return "";
        var fmt = shortFormat ? "MMM d" : "MMM d, yyyy";
        return dt.ToLocalTime().ToString(fmt, culture ?? CultureInfo.CurrentCulture);
    }
}
