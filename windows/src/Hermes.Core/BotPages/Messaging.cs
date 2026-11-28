using System.Text.Json.Nodes;
using Hermes.Core.Net;

namespace Hermes.Core.BotPages;

/// One key a messaging app takes (HermesKit/Pages/More/MessagingAPI.swift `MessagingEnvVar`).
public sealed record MessagingEnvVar(string Key, string Prompt = "", string Description = "", bool IsPassword = false,
    bool IsSet = false, string? RedactedValue = null, bool Required = false, bool Advanced = false, string? Url = null)
{
    public static MessagingEnvVar? From(JsonNode? json)
    {
        var key = json.Str("key")?.Trim();
        if (string.IsNullOrEmpty(key)) return null;
        return new MessagingEnvVar(key, json.Str("prompt") ?? "", json.Str("description") ?? "", json.Bool("is_password") ?? false,
            json.Bool("is_set") ?? false, json.Str("redacted_value"), json.Bool("required") ?? false, json.Bool("advanced") ?? false,
            json.Str("url"));
    }

    /// The row's label: the gateway's prompt, or the key when it has none.
    public string Label => Prompt.Trim() is { Length: > 0 } p ? p : Key;

    /// "Set" (with the redacted preview when it gives one), "Not Set", or "Required" (MessagingPlatformView.value).
    public string Value
    {
        get
        {
            if (!IsSet) return Required ? "Required" : "Not Set";
            return Preview(RedactedValue) is { } preview && preview.Any(char.IsLetterOrDigit) ? $"Set · {preview}" : "Set";
        }
    }

    /// EnvKeys.preview: "«redacted:abc»" → "abc", any other «redacted…» → dots.
    public static string? Preview(string? value)
    {
        if (string.IsNullOrEmpty(value)) return null;
        if (!value.StartsWith("«redacted", StringComparison.Ordinal)) return value;
        if (value.StartsWith("«redacted:", StringComparison.Ordinal) && value.EndsWith('»'))
        {
            var inner = value["«redacted:".Length..^1].Trim();
            if (inner.Length > 0) return inner;
        }
        return "••••••••";
    }
}

/// A platform's status line (`MessagingStatus`).
public sealed record MessagingStatus(string Text, MessagingStatus.Tone Kind)
{
    public enum Tone { Good, Muted, Warn, Bad }

    /// Error leads, then needs setup / other problems, then connected, then off.
    public static int SortRank(Tone t) => t switch { Tone.Bad => 0, Tone.Warn => 1, Tone.Good => 2, _ => 3 };

    public static MessagingStatus Of(MessagingPlatform p)
    {
        var state = p.State?.Trim().ToLowerInvariant() ?? "";
        var error = p.ErrorMessage?.Trim() ?? "";
        if (!p.Configured) return new("Needs setup", Tone.Warn);
        if (!p.Enabled) return new("Off", Tone.Muted);
        if (error.Length > 0) return new(error, Tone.Bad);
        if (!p.GatewayRunning)
            return state == "startup_failed" ? new("Startup failed", Tone.Bad) : new("Not running", Tone.Warn);
        return state switch
        {
            "connected" => new("Connected", Tone.Good),
            "connecting" => new("Connecting…", Tone.Warn),
            "retrying" => new("Retrying…", Tone.Warn),
            "fatal" => new("Error", Tone.Bad),
            "startup_failed" => new("Startup failed", Tone.Bad),
            "pending_restart" => new(p.UpdatedAt == null ? "Status unknown" : "Restart needed", Tone.Warn),
            "" or "status_unknown" => new("Status unknown", Tone.Warn),
            "disabled" => new("Off", Tone.Muted),
            "not_configured" => new("Needs setup", Tone.Warn),
            "gateway_stopped" => new("Not running", Tone.Warn),
            _ => new(Titled(state), Tone.Warn),
        };
    }

    /// "some_new_state" → "Some New State".
    public static string Titled(string state) => string.Join(" ",
        state.Split(['_', ' '], StringSplitOptions.RemoveEmptyEntries).Select(w => char.ToUpperInvariant(w[0]) + w[1..]));
}

public sealed record MessagingPlatform(string Id, string Name, string Description = "", string? DocsUrl = null,
    bool Configured = false, bool Enabled = false, bool GatewayRunning = false, string? State = null, string? ErrorCode = null,
    string? ErrorMessage = null, string? UpdatedAt = null, IReadOnlyList<MessagingEnvVar>? EnvVars = null)
{
    public IReadOnlyList<MessagingEnvVar> Vars => EnvVars ?? [];

    public static MessagingPlatform? From(JsonNode? json)
    {
        var id = PagesRest.PgString(json.Get("id"))?.Trim();
        if (string.IsNullOrEmpty(id)) return null;
        var seen = new HashSet<string>();
        var vars = (json.Arr("env_vars") ?? []).Select(MessagingEnvVar.From).OfType<MessagingEnvVar>().Where(v => seen.Add(v.Key)).ToList();
        var name = json.Str("name") ?? "";
        return new MessagingPlatform(id, name.Length == 0 ? id : name, json.Str("description") ?? "", json.Str("docs_url"),
            json.Bool("configured") ?? false, json.Bool("enabled") ?? false, json.Bool("gateway_running") ?? false,
            json.Str("state"), PagesRest.PgString(json.Get("error_code")), json.Str("error_message"),
            PagesRest.PgString(json.Get("updated_at")), vars);
    }

    /// `{"platforms":[…]}`: bad rows skipped, a repeated id kept once.
    public static IReadOnlyList<MessagingPlatform> List(JsonNode? json)
    {
        var seen = new HashSet<string>();
        return [.. (json.Arr("platforms") ?? []).Select(From).OfType<MessagingPlatform>().Where(p => seen.Add(p.Id))];
    }

    public IReadOnlyList<MessagingEnvVar> Keys => [.. Vars.Where(v => !v.Advanced)];
    public IReadOnlyList<MessagingEnvVar> AdvancedKeys => [.. Vars.Where(v => v.Advanced)];
    public MessagingStatus Status => MessagingStatus.Of(this);

    /// The setup guide, only when it is a real web link.
    public Uri? Guide => Uri.TryCreate(DocsUrl, UriKind.Absolute, out var u) && u.Scheme is "https" or "http" ? u : null;

    /// Segoe Fluent glyphs standing in for the Mac's SF symbols per platform id.
    public string Glyph => Id.ToLowerInvariant() switch
    {
        "telegram" => "",       // Send
        "discord" => "",        // Game
        "slack" => "",          // Hashtag-ish (Characters)
        "email" => "",          // Mail
        "sms" => "",            // Message
        "whatsapp" => "",       // Phone
        "signal" => "",         // Chat bubble
        "matrix" => "",         // Grid
        "webhook" => "",        // Link
        "api_server" => "",     // Network
        "homeassistant" => "",  // Home
        _ => "",
    };

    public bool Matches(string query)
    {
        var words = query.Trim().ToLowerInvariant();
        if (words.Length == 0) return true;
        return new[] { Id, Name, Description, Status.Text }.Any(s => s.ToLowerInvariant().Contains(words));
    }

    /// Item 22: the app with a problem leads; alphabetical within each group.
    public static IReadOnlyList<MessagingPlatform> Sorted(IEnumerable<MessagingPlatform> rows, string query) =>
        [.. rows.Where(p => p.Matches(query))
            .OrderBy(p => MessagingStatus.SortRank(p.Status.Kind))
            .ThenBy(p => p.Name, StringComparer.CurrentCultureIgnoreCase)];
}

/// Catalog platform offered in `GET /api/messaging/platforms` (`available[]`, Hermes 0.23.5+).
public sealed record MessagingCatalogPlatform(
    string Name,
    string Title = "",
    string Summary = "",
    string Badge = "verified",
    string Disclosure = "",
    string Blocked = "",
    string BlockedReason = "",
    string InstallCommand = "")
{
    public bool IsBlocked => !string.IsNullOrWhiteSpace(Blocked);
    public string BadgeWord => Badge.Equals("official", StringComparison.OrdinalIgnoreCase) ? "Official" : "Verified";

    public static MessagingCatalogPlatform? From(JsonNode? json)
    {
        var name = PagesRest.PgString(json.Get("name"))?.Trim();
        if (string.IsNullOrEmpty(name)) return null;
        var title = json.Str("title") ?? "";
        var badge = json.Str("badge") ?? "";
        return new MessagingCatalogPlatform(
            name,
            title.Length == 0 ? name : title,
            json.Str("summary") ?? "",
            badge.Length == 0 ? "verified" : badge,
            json.Str("disclosure") ?? "",
            json.Str("blocked") ?? "",
            json.Str("blocked_reason") ?? "",
            json.Str("install_command") ?? "");
    }

    public static IReadOnlyList<MessagingCatalogPlatform> List(JsonNode? json)
    {
        var seen = new HashSet<string>();
        return [.. (json.Arr("available") ?? []).Select(From).OfType<MessagingCatalogPlatform>().Where(c => seen.Add(c.Name))];
    }

    public bool Matches(string query)
    {
        var words = query.Trim().ToLowerInvariant();
        if (words.Length == 0) return true;
        return new[] { Name, Title, Summary }.Any(s => s.ToLowerInvariant().Contains(words));
    }
}

/// Answer to `POST /api/messaging/catalog/{name}/install` (Hermes 0.23.5+).
public sealed record MessagingCatalogInstallResult(
    bool Ok,
    string? PluginName = null,
    IReadOnlyList<string>? Platforms = null,
    string? Error = null,
    string? InstallCommand = null,
    IReadOnlyList<string>? Warnings = null)
{
    public IReadOnlyList<string> RegisteredPlatforms => Platforms ?? [];
    public IReadOnlyList<string> WarningList => Warnings ?? [];

    public static MessagingCatalogInstallResult From(JsonNode? json)
    {
        var err = json.Str("error")?.Trim();
        var cmd = json.Str("install_command")?.Trim();
        return new MessagingCatalogInstallResult(
            json.Bool("ok") ?? false,
            PagesRest.PgString(json.Get("plugin_name")),
            [.. (json.Arr("platforms") ?? []).Select(PagesRest.PgString).Where(s => !string.IsNullOrEmpty(s)).OfType<string>()],
            string.IsNullOrEmpty(err) ? null : err,
            string.IsNullOrEmpty(cmd) ? null : cmd,
            [.. (json.Arr("warnings") ?? []).Select(J.AsString).Where(s => !string.IsNullOrEmpty(s)).OfType<string>()]);
    }
}

/// Live-apply verdict returned on `PUT /api/messaging/platforms/{id}` (`live`, Hermes 0.23.5+).
public sealed record MessagingLiveApply(bool Applied, string? State = null, string? Detail = null)
{
    public static MessagingLiveApply? From(JsonNode? json) =>
        json is JsonObject o ? new MessagingLiveApply(o.Bool("applied") ?? false, o.Str("state"), o.Str("detail")) : null;
}

/// Full result of `PUT /api/messaging/platforms/{id}` combining `live` (0.23.5+) and legacy `hot_served`.
public sealed record MessagingUpdateResult(bool HotServed = false, MessagingLiveApply? Live = null)
{
    public bool AppliedLive => Live?.Applied ?? HotServed;
    public bool NeedsCredentials => string.Equals(Live?.State?.Trim(), "not_configured", StringComparison.OrdinalIgnoreCase);
    public bool RequiresRestart => !NeedsCredentials && !AppliedLive;
    public string? RestartDetail => Live is { Applied: false } && Live.Detail?.Trim() is { Length: > 0 } d ? d : null;

    public static MessagingUpdateResult From(JsonNode? json) =>
        new(json.Bool("hot_served") ?? false, MessagingLiveApply.From(json.Get("live")));
}

public sealed record MessagingPlatformsPage(
    IReadOnlyList<MessagingPlatform> Platforms,
    IReadOnlyList<MessagingCatalogPlatform> Available,
    string? Signature = null);

public sealed record PairingPerson(string Platform, string UserId, string? UserName = null, string? RequestId = null, double? AgeMinutes = null)
{
    public string Id => $"{Platform}:{UserId}";
    public string Name => UserName?.Trim() is { Length: > 0 } n ? n : UserId;

    public static PairingPerson? From(JsonNode? json)
    {
        var platform = json.Str("platform")?.ToLowerInvariant();
        var user = PagesRest.PgString(json.Get("user_id"));
        if (string.IsNullOrEmpty(platform) || string.IsNullOrEmpty(user)) return null;
        var age = json.Num("age_minutes");
        return new PairingPerson(platform, user, PagesRest.PgString(json.Get("user_name")), PagesRest.PgString(json.Get("request_id")),
            age is { } a && double.IsFinite(a) ? a : null);
    }

    /// "Just now", "12 min ago", "3 hr ago", "2 days ago".
    public string? Age
    {
        get
        {
            if (AgeMinutes is not { } m) return null;
            var minutes = (int)Math.Max(0, m);
            if (minutes < 1) return "Just now";
            if (minutes < 60) return $"{minutes} min ago";
            if (minutes < 60 * 48) return $"{minutes / 60} hr ago";
            return $"{minutes / 1440} days ago";
        }
    }
}

public sealed record MessagingPairing(IReadOnlyList<PairingPerson> Pending, IReadOnlyList<PairingPerson> Approved)
{
    public static readonly MessagingPairing Empty = new([], []);

    public static MessagingPairing From(JsonNode? json)
    {
        IReadOnlyList<PairingPerson> People(string key, bool needsRequest)
        {
            var seen = new HashSet<string>();
            return [.. (json.Arr(key) ?? []).Select(PairingPerson.From).OfType<PairingPerson>()
                .Where(p => !needsRequest || !string.IsNullOrEmpty(p.RequestId)).Where(p => seen.Add(p.Id))];
        }
        return new(People("pending", true), People("approved", false));
    }

    public IReadOnlyList<PairingPerson> PendingFor(string platform) => [.. Pending.Where(p => p.Platform == platform.ToLowerInvariant())];
    public IReadOnlyList<PairingPerson> ApprovedFor(string platform) => [.. Approved.Where(p => p.Platform == platform.ToLowerInvariant())];
}

public sealed record MessagingTestResult(bool Ok, string Message)
{
    public static MessagingTestResult From(JsonNode? json)
    {
        var ok = json.Bool("ok") ?? false;
        var text = json.Str("message")?.Trim() ?? "";
        return new(ok, text.Length == 0 ? (ok ? "Connected." : "The gateway gave no answer for this test.") : text);
    }
}

public sealed record TelegramSetupStart(string PairingId, string DeepLink, string QrPayload, string? SuggestedUsername = null,
    DateTimeOffset? ExpiresAt = null)
{
    public static TelegramSetupStart? From(JsonNode? json)
    {
        var id = PagesRest.PgString(json.Get("pairing_id"));
        if (string.IsNullOrEmpty(id)) return null;
        var link = json.Str("deep_link") ?? "";
        var payload = json.Str("qr_payload") ?? "";
        if (link.Length == 0 && payload.Length == 0) return null;
        return new(id, link.Length == 0 ? payload : link, payload.Length == 0 ? link : payload, json.Str("suggested_username"),
            PagesRest.ParseDate(json.Get("expires_at")));
    }

    /// The link Open Telegram follows: Telegram's own scheme and web links only.
    public Uri? OpenUrl => Uri.TryCreate(DeepLink, UriKind.Absolute, out var u) && u.Scheme.ToLowerInvariant() is "https" or "tg" ? u : null;
}

public abstract record TelegramSetupStatus
{
    public sealed record Waiting : TelegramSetupStatus;
    public sealed record Ready(string? BotUsername, string? OwnerUserId) : TelegramSetupStatus;

    public static TelegramSetupStatus From(JsonNode? json)
    {
        if (json.Str("status") != "ready") return new Waiting();
        var owner = PagesRest.PgString(json.Get("owner_user_id"));
        return new Ready(json.Str("bot_username"), owner != null && TelegramSetup.IsUserId(owner) ? owner : null);
    }
}

public sealed record TelegramSetupApplied(string? BotUsername = null, bool NeedsRestart = false, bool RestartStarted = false,
    string? RestartError = null)
{
    public static TelegramSetupApplied From(JsonNode? json) => new(json.Str("bot_username"), json.Bool("needs_restart") ?? false,
        json.Bool("restart_started") ?? false, json.Str("restart_error"));
}

/// The request bodies, with exactly the keys the gateway lists (`MessagingBodies`).
public static class MessagingBodies
{
    public static JsonObject Enabled(bool on) => new() { ["enabled"] = on };
    public static JsonObject Env(string key, string value) => new() { ["env"] = new JsonObject { [key] = value } };
    public static JsonObject Clear(string key) => new() { ["clear_env"] = new JsonArray(key) };

    /// These two routes read the profile off the body, not the query.
    public static JsonObject Approve(string platform, string requestId, string? profile) =>
        PagesRest.ProfileParams(profile, new JsonObject { ["platform"] = platform, ["request_id"] = requestId });

    public static JsonObject Revoke(string platform, string userId, string? profile) =>
        PagesRest.ProfileParams(profile, new JsonObject { ["platform"] = platform, ["user_id"] = userId });

    public static JsonObject TelegramStart(string? botName) =>
        botName?.Trim() is { Length: > 0 } n ? new JsonObject { ["bot_name"] = n } : [];

    public static JsonObject TelegramApply(IEnumerable<string> allowed, string? profile) =>
        PagesRest.ProfileParams(profile, new JsonObject { ["allowed_user_ids"] = new JsonArray([.. allowed.Select(a => (JsonNode)a)]) });
}

/// The Messaging wire (`AG/hermes_cli/web_routers/messaging.py`). A key's value only ever travels in a PUT body.
public sealed class MessagingApi(IPagesGateway gw)
{
    private static readonly TimeSpan Thirty = TimeSpan.FromSeconds(30);

    public async Task<MessagingPlatformsPage> PlatformsPageAsync(string? profile, CancellationToken ct = default)
    {
        var answer = await PagesRest.JsonAsync(gw, "GET", "/api/messaging/platforms", PagesRest.ProfileQuery(profile), timeout: Thirty, ct: ct);
        if (answer.Arr("platforms") == null) throw PagesRest.UnreadableAnswer(answer);
        return new MessagingPlatformsPage(
            MessagingPlatform.List(answer),
            MessagingCatalogPlatform.List(answer),
            PagesRest.PgString(answer.Get("signature")));
    }

    public async Task<IReadOnlyList<MessagingPlatform>> PlatformsAsync(string? profile, CancellationToken ct = default) =>
        (await PlatformsPageAsync(profile, ct)).Platforms;

    /// Lightweight digest polled for platform list changes (`GET /api/messaging/platforms/signature`, Hermes 0.23.5+).
    public async Task<string?> SignatureAsync(string? profile, CancellationToken ct = default)
    {
        var answer = await PagesRest.JsonAsync(gw, "GET", "/api/messaging/platforms/signature",
            PagesRest.ProfileQuery(profile), timeout: TimeSpan.FromSeconds(15), ct: ct);
        return PagesRest.PgString(answer.Get("signature"));
    }

    /// Installs and enables one catalog platform (`POST /api/messaging/catalog/{name}/install`, 300 s timeout).
    public async Task<MessagingCatalogInstallResult> InstallCatalogAsync(string name, string? profile, CancellationToken ct = default)
    {
        var answer = await PagesRest.JsonAsync(gw, "POST", $"/api/messaging/catalog/{PagesRest.Segment(name)}/install",
            PagesRest.ProfileQuery(profile), new JsonObject(), TimeSpan.FromSeconds(300), ct);
        return MessagingCatalogInstallResult.From(answer);
    }

    /// Full update response carrying both `live` (0.23.5+) and legacy `hot_served`.
    public async Task<MessagingUpdateResult> UpdateWithLiveAsync(string platform, JsonObject body, string? profile, CancellationToken ct = default)
    {
        var answer = await PagesRest.JsonAsync(gw, "PUT", "/api/messaging/platforms/" + PagesRest.Segment(platform),
            PagesRest.ProfileQuery(profile), body, Thirty, ct);
        return MessagingUpdateResult.From(answer);
    }

    /// Returns whether the running gateway applied the change live (`live.applied` or legacy `hot_served`).
    public async Task<bool> UpdateAsync(string platform, JsonObject body, string? profile, CancellationToken ct = default) =>
        (await UpdateWithLiveAsync(platform, body, profile, ct)).AppliedLive;

    public async Task<MessagingTestResult> TestAsync(string platform, string? profile, CancellationToken ct = default) =>
        MessagingTestResult.From(await PagesRest.JsonAsync(gw, "POST", $"/api/messaging/platforms/{PagesRest.Segment(platform)}/test",
            PagesRest.ProfileQuery(profile), timeout: TimeSpan.FromSeconds(45), ct: ct));

    public async Task<MessagingPairing> PairingAsync(string? profile, CancellationToken ct = default) =>
        MessagingPairing.From(await PagesRest.JsonAsync(gw, "GET", "/api/pairing", PagesRest.ProfileQuery(profile), timeout: Thirty, ct: ct));

    public Task ApproveAsync(string platform, string requestId, string? profile, CancellationToken ct = default) =>
        gw.RestAsync("POST", "/api/pairing/approve", body: MessagingBodies.Approve(platform, requestId, profile), timeout: Thirty, ct: ct);

    public Task RevokeAsync(string platform, string userId, string? profile, CancellationToken ct = default) =>
        gw.RestAsync("POST", "/api/pairing/revoke", body: MessagingBodies.Revoke(platform, userId, profile), timeout: Thirty, ct: ct);

    // Telegram: every call of one flow carries the same profile scope.

    public async Task<TelegramSetupStart> TelegramStartAsync(string? botName, string? profile, CancellationToken ct = default)
    {
        var answer = await PagesRest.JsonAsync(gw, "POST", "/api/messaging/telegram/onboarding/start", PagesRest.ProfileQuery(profile),
            MessagingBodies.TelegramStart(botName), TimeSpan.FromSeconds(45), ct);
        return TelegramSetupStart.From(answer) ?? throw new PagesMessageException("Telegram’s setup service gave an answer that couldn’t be read.");
    }

    public async Task<TelegramSetupStatus> TelegramStatusAsync(string pairingId, string? profile, CancellationToken ct = default) =>
        TelegramSetupStatus.From(await PagesRest.JsonAsync(gw, "GET", "/api/messaging/telegram/onboarding/" + PagesRest.Segment(pairingId),
            PagesRest.ProfileQuery(profile), timeout: TimeSpan.FromSeconds(20), ct: ct));

    public async Task<TelegramSetupApplied> TelegramApplyAsync(string pairingId, IReadOnlyList<string> allowed, string? profile,
        CancellationToken ct = default) =>
        TelegramSetupApplied.From(await PagesRest.JsonAsync(gw, "POST", $"/api/messaging/telegram/onboarding/{PagesRest.Segment(pairingId)}/apply",
            PagesRest.ProfileQuery(profile), MessagingBodies.TelegramApply(allowed, profile), TimeSpan.FromSeconds(60), ct));

    public Task TelegramCancelAsync(string pairingId, string? profile, CancellationToken ct = default) =>
        gw.RestAsync("DELETE", "/api/messaging/telegram/onboarding/" + PagesRest.Segment(pairingId), PagesRest.ProfileQuery(profile),
            timeout: TimeSpan.FromSeconds(15), ct: ct);
}

/// What More's Messaging row says when a messaging app is failing (MessagingIssues.swift).
public static class MessagingIssues
{
    public static IReadOnlyList<MessagingPlatform> Failing(IEnumerable<MessagingPlatform> platforms) =>
        [.. platforms.Where(p => p.Status.Kind == MessagingStatus.Tone.Bad)];

    /// "1 Issue", "2 Issues", and what a screen reader says after the title. Null when nothing is failing.
    public static (string Text, string Spoken)? RowWords(IEnumerable<MessagingPlatform> platforms)
    {
        var failing = Failing(platforms);
        if (failing.Count == 0) return null;
        return (failing.Count == 1 ? "1 Issue" : $"{failing.Count} Issues",
            string.Join(". ", failing.Select(p => $"{(p.Name.Length == 0 ? p.Id : p.Name)}: {p.Status.Text}")));
    }
}

/// Messaging's words (App/Pages/More/Messaging/MessagingPages.swift, TelegramSetupView.swift).
public static class MessagingWords
{
    public const string Title = "Messaging";
    public const string Loading = "Loading messaging apps…";
    public const string LoadFailTitle = "Couldn’t Load Messaging";
    public const string EmptyTitle = "No Messaging Apps";
    public const string EmptyText = "This gateway has no messaging apps to set up.";
    public static string For(string botName) => $"For {botName}";
    public const string NoLongerTitle = "No Longer Listed";
    public const string NoLongerText = "Your gateway no longer lists this messaging app.";
    public const string SetUpTelegram = "Set Up with Telegram";
    public const string SetUpTelegramFooter = "Hermes creates the bot and finds your Telegram user ID for you. You confirm it in Telegram.";
    public const string On = "On";
    public const string Keys = "Keys";
    public const string NoKeysReadOnly = "This messaging app has no keys.";
    public const string NoKeys = "Nothing to paste for this messaging app. Turn it on with the switch above.";
    public const string AllAdvanced = "Every key of this messaging app is under Advanced.";
    public const string Advanced = "Advanced";
    public const string TestConnection = "Test Connection";
    public const string Testing = "Testing…";
    public const string WhoCanMessage = "Who Can Message This Bot";
    public const string NoOne = "No one has asked to message this bot here.";
    public const string Waiting = "Waiting";
    public const string Approved = "Approved";
    public const string Approve = "Approve";
    public const string Approving = "Approving…";
    public const string Remove = "Remove";
    /// The Mac's "Control‑click a person to remove them." with Windows' click.
    public const string RemoveHint = "Right‑click a person to remove them.";
    public const string SetupGuide = "Setup Guide";
    public static string TurnOnFail(string name) => $"Couldn’t Turn On {name}";
    public static string TurnOffFail(string name) => $"Couldn’t Turn Off {name}";
    public static string ApproveFail(string name) => $"Couldn’t Approve {name}";
    public static string RemoveFail(string name) => $"Couldn’t Remove {name}";
    public static string RemoveTitle(string name) => $"Remove {name}?";
    public const string RemoveMessage = "They won’t be able to message this bot until you approve them again.";
    public const string TypeValue = "Type a value first.";
    public const string TelegramSaved = "Telegram Saved";
    public const string TelegramConnected = "Telegram Connected";
    public const string Restarting = "Your gateway is restarting.";

    // The key page (App/Settings/Config/KeysPages.swift EnvKeyEditor).
    public const string Status = "Status";
    public const string SetOnGateway = "Set on Your Gateway";
    public const string NotSet = "Not Set";
    public const string Saved = "Saved";
    public const string Replace = "Replace";
    public const string Add = "Add";
    public const string NewValue = "New value";
    public const string ValuePlaceholder = "Value";
    public const string Save = "Save";
    public const string GetAKey = "Get a Key";
    public const string RemoveKey = "Remove Key";
    public static string RemoveKeyFooter(string key, string platformName) =>
        $"Removes {key} from {Gateways.HostWord.Phrase}. {platformName} may stop working until you add it again.";

    // Telegram's sheet.
    public const string Starting = "Starting…";
    public const string Saving = "Saving…";
    public const string LinkExpired = "Link Expired";
    public const string StartAgain = "Start Again";
    public const string StartFailTitle = "Couldn’t Start Telegram Setup";
    public const string TryAgain = "Try Again";
    public static string WaitingIntro(bool canOpen) => canOpen
        ? $"{Gateways.DeviceWord.TapCap} Open Telegram and confirm there. Hermes creates the bot and finds your Telegram user ID for you."
        : "Scan the code with Telegram and confirm there. Hermes creates the bot and finds your Telegram user ID for you.";
    public const string OpenTelegram = "Open Telegram";
    public static string OpenFailed => $"Telegram didn’t open. Install Telegram on this {Gateways.DeviceWord.Name}, or scan the code with Telegram on another device.";
    public const string QrNote = "The QR code is for Telegram on another device.";
    public const string QrName = "Telegram setup code";
    public const string WaitingForTelegram = "Waiting for Telegram…";
    public static string ExpiresIn(string left) => $"Expires in {left}";
    public static string OnlyYou(string owner) => $"Only you (Telegram user {owner}) can message this bot at first. You can approve more people later.";
    public const string UserIdLabel = "Telegram User ID";
    public const string UserIdHelp = "Telegram didn’t say who you are. Type your numeric Telegram user ID (the bot @userinfobot tells you), so only you can message this bot.";
    public const string Finish = "Finish";

    public static string Connected(string? bot)
    {
        var name = (bot ?? "").Trim('@', ' ');
        return name.Length == 0 ? "Connected to Telegram" : $"Connected to @{name}";
    }
}

/// "Set Up with Telegram" from start to Finish (MessagingAPI.swift `TelegramSetup`): start → waiting (polled every 2 s
/// until `expires_at`) → ready → applying → applied. An expired or forgotten pairing says so and offers Start Again.
/// Closing before Finish sends the DELETE. Events are raised on the caller's context (the UI thread).
public sealed class TelegramSetup
{
    public abstract record Phase
    {
        public sealed record Idle : Phase;
        public sealed record Starting : Phase;
        public sealed record Waiting(TelegramSetupStart Start) : Phase;
        public sealed record Ready(string? BotUsername, string? OwnerUserId) : Phase;
        public sealed record Applying : Phase;
        public sealed record Applied(TelegramSetupApplied Result) : Phase;
        public sealed record Expired : Phase;
        public sealed record Failed(string Reason) : Phase;
    }

    public sealed record Calls(
        Func<CancellationToken, Task<TelegramSetupStart>> Start,
        Func<string, CancellationToken, Task<TelegramSetupStatus>> Status,
        Func<string, IReadOnlyList<string>, CancellationToken, Task<TelegramSetupApplied>> Apply,
        Func<string, Task> Cancel);

    public const string ExpiredText = "This link expired. Start again.";

    public Phase Current { get; private set; } = new Phase.Idle();
    /// A status read that failed while waiting, or a refused Finish.
    public string? Notice { get; private set; }
    public DateTimeOffset? ExpiresAt { get; private set; }
    public TimeSpan Interval { get; set; } = TimeSpan.FromSeconds(2);
    public Func<DateTimeOffset> Now { get; set; } = () => DateTimeOffset.UtcNow;

    public event Action? Changed;
    public event Action<TelegramSetupApplied>? AppliedEvent;
    public event Action? FinishRefused;

    private readonly Calls _calls;
    private string? _pairingId;
    private CancellationTokenSource? _task;
    public Task? CancelTask { get; private set; }

    public TelegramSetup(Calls calls) => _calls = calls;

    /// Telegram user ids are whole numbers.
    public static bool IsUserId(string text) => text.Length is > 0 and <= 20 && text.All(char.IsAsciiDigit);

    /// "42, 43" → ["42","43"]; null when any piece is not a number or nothing is left.
    public static IReadOnlyList<string>? UserIds(string typed)
    {
        var pieces = typed.Split([',', ' ', '\n'], StringSplitOptions.RemoveEmptyEntries);
        if (pieces.Length == 0 || !pieces.All(IsUserId)) return null;
        var seen = new HashSet<string>();
        return [.. pieces.Where(seen.Add)];
    }

    /// The gateway no longer knows this pairing (404), or says it expired (410).
    public static bool IsTerminal(Exception e) => PagesRest.Status(e) is 404 or 410;

    private void Set(Phase phase, string? notice = null) { Current = phase; Notice = notice; Changed?.Invoke(); }

    public void Start()
    {
        if (Current is not (Phase.Idle or Phase.Expired or Phase.Failed)) return;
        _task?.Cancel();
        Forget();
        Set(new Phase.Starting());
        var cts = _task = new CancellationTokenSource();
        _ = Run(cts.Token);
    }

    private async Task Run(CancellationToken ct)
    {
        TelegramSetupStart started;
        try { started = await _calls.Start(ct); }
        catch (Exception e)
        {
            if (!ct.IsCancellationRequested) Set(new Phase.Failed(PagesRest.Reason(e)));
            return;
        }
        if (ct.IsCancellationRequested)
        {
            try { await _calls.Cancel(started.PairingId); } catch (Exception) { }   // closed while starting: given back
            return;
        }
        _pairingId = started.PairingId;
        ExpiresAt = started.ExpiresAt;
        Set(new Phase.Waiting(started));
        await Poll(started, ct);
    }

    private async Task Poll(TelegramSetupStart started, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try { await Task.Delay(Interval, ct); } catch (OperationCanceledException) { return; }
            if (Current is not Phase.Waiting) return;
            if (ExpiresAt is { } ex && Now() >= ex) { Expire(); return; }
            try
            {
                var status = await _calls.Status(started.PairingId, ct);
                if (ct.IsCancellationRequested || Current is not Phase.Waiting) return;
                if (status is TelegramSetupStatus.Ready r) { Set(new Phase.Ready(r.BotUsername, r.OwnerUserId)); return; }
                if (Notice != null) Set(Current);
            }
            catch (Exception e)
            {
                if (ct.IsCancellationRequested || Current is not Phase.Waiting) return;
                if (IsTerminal(e) || ExpiresAt is { } x && Now() >= x) { Expire(); return; }
                Set(Current, $"Still waiting for Telegram. {PagesRest.Reason(e)}");
            }
        }
    }

    private void Expire()
    {
        _pairingId = null;   // the gateway has already dropped it: nothing to DELETE
        Set(new Phase.Expired());
    }

    /// Finish: saves the bot with the people allowed to message it.
    public void Finish(IReadOnlyList<string> allowed)
    {
        if (Current is not Phase.Ready ready || _pairingId is not { } id) return;
        if (allowed.Count == 0) { Set(Current, "Add at least one Telegram user ID."); return; }
        Set(new Phase.Applying());
        var cts = _task = new CancellationTokenSource();
        _ = ApplyRun(id, allowed, ready, cts.Token);
    }

    private async Task ApplyRun(string id, IReadOnlyList<string> allowed, Phase.Ready ready, CancellationToken ct)
    {
        try
        {
            var applied = await _calls.Apply(id, allowed, ct);
            _pairingId = null;
            Set(new Phase.Applied(applied));
            AppliedEvent?.Invoke(applied);
        }
        catch (Exception e)
        {
            if (ct.IsCancellationRequested) return;
            if (IsTerminal(e)) { Expire(); return; }
            Set(ready, PagesRest.Reason(e));
            FinishRefused?.Invoke();
        }
    }

    /// The sheet closed. Before Finish this gives the pairing back (DELETE); after it there is nothing to undo.
    public void Close()
    {
        if (Current is Phase.Applying) return;
        _task?.Cancel();
        _task = null;
        Forget();
        if (Current is Phase.Applied) return;
        Set(new Phase.Idle());
    }

    private void Forget()
    {
        if (_pairingId is not { } id) return;
        _pairingId = null;
        CancelTask = Task.Run(async () => { try { await _calls.Cancel(id); } catch (Exception) { } });
    }

    /// "9:41" left on the link at `date`; null once it has run out or when the gateway gave no time.
    public string? Remaining(DateTimeOffset date)
    {
        if (ExpiresAt is not { } ex) return null;
        var seconds = (int)Math.Floor((ex - date).TotalSeconds);
        return seconds > 0 ? $"{seconds / 60}:{seconds % 60:00}" : null;
    }
}
