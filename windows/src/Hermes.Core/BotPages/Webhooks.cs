using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Hermes.Core.BotPages;

/// One webhook subscription (HermesKit/Pages/More/WebhooksAPI.swift `WebhookRoute`).
public sealed record WebhookRoute(string Name, string Description = "", IReadOnlyList<string>? Events = null,
    IReadOnlyList<string>? Skills = null, string Deliver = "log", bool DeliverOnly = false, string Prompt = "",
    bool Enabled = true, bool SecretSet = false, string Url = "", DateTimeOffset? CreatedAt = null)
{
    public IReadOnlyList<string> EventList => Events ?? [];
    public IReadOnlyList<string> SkillList => Skills ?? [];

    public static WebhookRoute? From(JsonNode? json)
    {
        var name = PagesRest.PgString(json.Get("name"))?.Trim();
        if (string.IsNullOrEmpty(name)) return null;
        IReadOnlyList<string> Strings(string key) =>
            [.. (json.Arr(key) ?? []).Select(PagesRest.PgString).OfType<string>().Select(s => s.Trim()).Where(s => s.Length > 0)];
        var deliver = json.Str("deliver")?.Trim() ?? "";
        return new WebhookRoute(name, json.Str("description") ?? "", Strings("events"), Strings("skills"),
            deliver.Length == 0 ? "log" : deliver, json.Bool("deliver_only") ?? false, json.Str("prompt") ?? "",
            // Default-on: only an explicit `false` turns a route off.
            json.Bool("enabled") ?? true, json.Bool("secret_set") ?? false, json.Str("url") ?? "",
            PagesRest.ParseDate(json.Get("created_at")));
    }

    private string EventsText => EventList.Count == 0 ? "All Events" : string.Join(", ", EventList);

    /// "push, pull_request → Telegram" / "All Events → Log Only".
    public string Summary => $"{EventsText} → {WebhookDeliver.Label(Deliver)}";

    /// `Summary` as a screen reader says it: "to" in words.
    public string SpokenSummary => $"{EventsText} to {WebhookDeliver.Label(Deliver)}";

    public bool Matches(string query)
    {
        var words = query.Trim().ToLowerInvariant();
        if (words.Length == 0) return true;
        return new[] { Name, Description, Deliver, WebhookDeliver.Label(Deliver) }.Concat(EventList)
            .Any(s => s.ToLowerInvariant().Contains(words));
    }
}

public sealed record WebhooksAnswer(bool Enabled, string BaseUrl, IReadOnlyList<WebhookRoute> Subscriptions)
{
    /// Null when the answer is not the webhooks object at all.
    public static WebhooksAnswer? From(JsonNode? json)
    {
        if (json is not JsonObject o || (!o.ContainsKey("enabled") && !o.ContainsKey("subscriptions"))) return null;
        var seen = new HashSet<string>();
        return new(json.Bool("enabled") ?? false, json.Str("base_url") ?? "",
            [.. (json.Arr("subscriptions") ?? []).Select(WebhookRoute.From).OfType<WebhookRoute>().Where(r => seen.Add(r.Name))]);
    }
}

public sealed record WebhookEnableResult(bool NeedsRestart, bool RestartStarted, string? RestartError = null)
{
    public static WebhookEnableResult From(JsonNode? json) =>
        new(json.Bool("needs_restart") ?? false, json.Bool("restart_started") ?? false, json.Str("restart_error"));

    /// The notice with Restart Gateway shows when a restart is needed and none is already on its way.
    public bool ShowsRestartNotice => NeedsRestart && !RestartStarted;
}

/// The create answer: the route and its secret, shown once, never stored or logged.
public sealed record WebhookCreated(string Name, string Url, string Secret)
{
    public static WebhookCreated? From(JsonNode? json) => json is JsonObject
        ? new(PagesRest.PgString(json.Get("name")) ?? "", json.Str("url") ?? "", json.Str("secret") ?? "")
        : null;
}

/// Where a webhook's result goes.
public static class WebhookDeliver
{
    public static readonly string[] Options = ["log", "telegram", "discord", "slack", "email", "github_comment"];

    public static string Label(string deliver) => deliver switch
    {
        "log" => "Log Only",
        "telegram" => "Telegram",
        "discord" => "Discord",
        "slack" => "Slack",
        "email" => "Email",
        "github_comment" => "GitHub Comment",
        _ => deliver.Length == 0 ? "Log Only" : deliver,
    };

    /// A chat platform takes a chat to deliver to (`deliver_chat_id`).
    public static bool IsChat(string deliver) => deliver is "telegram" or "discord" or "slack";
}

/// The New Webhook form.
public sealed partial record WebhookForm
{
    public string Name { get; init; } = "";
    public string Description { get; init; } = "";
    public string Events { get; init; } = "";
    public string Skills { get; init; } = "";
    public string Deliver { get; init; } = "log";
    public string DeliverChatId { get; init; } = "";
    public bool DeliverOnly { get; init; }
    public string Prompt { get; init; } = "";

    /// "a, b ,, c" → ["a","b","c"].
    public static IReadOnlyList<string> List(string typed) =>
        [.. typed.Split([',', '\n']).Select(s => s.Trim()).Where(s => s.Length > 0)];

    /// The name as the gateway will keep it: lower case, spaces as hyphens.
    public string NormalizedName => Name.Trim().ToLowerInvariant().Replace(' ', '-');

    [GeneratedRegex("^[a-z0-9][a-z0-9_-]*$")]
    private static partial Regex NameRule();

    public bool NameIsValid => NameRule().IsMatch(NormalizedName);
    /// Payload-only delivery needs a real target: the gateway refuses it with Log.
    public bool CanDeliverOnly => Deliver != "log";
    public bool CanCreate => NameIsValid;

    /// The three keys the web always sends, every other key only when it has a value.
    public JsonObject Payload()
    {
        var o = new JsonObject
        {
            ["name"] = Name.Trim(),
            ["deliver"] = Deliver,
            ["deliver_only"] = DeliverOnly && CanDeliverOnly,
        };
        if (Description.Trim() is { Length: > 0 } about) o["description"] = about;
        if (List(Events) is { Count: > 0 } ev) o["events"] = new JsonArray([.. ev.Select(e => (JsonNode)e)]);
        if (List(Skills) is { Count: > 0 } sk) o["skills"] = new JsonArray([.. sk.Select(e => (JsonNode)e)]);
        if (WebhookDeliver.IsChat(Deliver) && DeliverChatId.Trim() is { Length: > 0 } chat) o["deliver_chat_id"] = chat;
        if (Prompt.Trim() is { Length: > 0 } words) o["prompt"] = words;
        return o;
    }
}

/// Webhooks' words (App/Pages/More/Webhooks/WebhooksPages.swift).
public static class WebhookWords
{
    public const string NameTaken = "A webhook with that name already exists.";

    /// Why Create failed, in words: a 409 is the name being taken.
    public static string CreateFailure(Exception e) => PagesRest.Status(e) == 409 ? NameTaken : PagesRest.Reason(e);

    public static string ToggleFailure(string name, bool on) => $"Couldn’t turn “{name}” {(on ? "on" : "off")}";

    public const string Title = "Webhooks";
    public const string Loading = "Loading webhooks…";
    public const string LoadFailTitle = "Couldn’t Load Webhooks";
    public const string EmptyTitle = "No Webhooks Yet";
    public const string EmptyText = "A webhook lets another service start a bot.";
    public const string NewWebhookEllipsis = "New Webhook…";
    public const string NewWebhook = "New Webhook";
    public const string ReceiverOffTitle = "Webhook Receiver Is Off";
    public const string ReceiverOffText = "Turn it on to let other services send events to your bots.";
    public const string TurnOn = "Turn On Webhooks";
    public const string TurningOn = "Turning On…";
    public const string TurnOnFail = "Couldn’t Turn On Webhooks";
    public const string AreOn = "Webhooks Are On";
    public const string RestartNotice = "Webhooks are enabled, but the gateway still needs a restart before the receiver can come online.";
    public const string ListFooter = "Changes take effect right away once the receiver is running. A webhook that is off rejects incoming events.";
    public const string OffRejects = "A webhook that is off rejects incoming events.";
    public const string CopyUrl = "Copy URL";
    public const string Copy = "Copy";
    public const string Copied = "Copied";
    public const string Delete = "Delete";
    public const string DeleteTitle = "Delete Webhook?";
    public static string DeleteMessage(string name) => $"This will permanently remove {name}. This can’t be undone.";
    public static string DeleteFail(string name) => $"Couldn’t Delete “{name}”";
    public const string Deleted = "Webhook Deleted";
    public const string DeleteWebhook = "Delete Webhook";
    public const string Deleting = "Deleting…";
    public const string RemovedTitle = "Webhook Removed";
    public const string RemovedText = "This webhook is no longer on your gateway.";
    public const string Url = "Webhook URL";
    public const string NotKnown = "Not Known";
    public const string OpensHint = "Opens the webhook";

    // The form.
    public const string NameHeader = "Name";
    public const string NamePlaceholder = "e.g. github-push";
    public const string NameRule = "Use lowercase letters, numbers, hyphens and underscores, starting with a letter or number.";
    public const string DescriptionHeader = "Description";
    public const string DescriptionPlaceholder = "What this webhook does (optional)";
    public const string EventsHeader = "Events";
    public const string EventsPlaceholder = "comma-separated, leave empty for all";
    public const string SkillsHeader = "Skills";
    public const string SkillsPlaceholder = "comma-separated skill names (optional)";
    public const string DeliverTo = "Deliver To";
    public const string ChatId = "Chat ID (optional)";
    public const string DeliverOnly = "Deliver Payload Only";
    public const string DeliverOnlyOn = "Payload only sends the event as it came, without a bot’s reply.";
    public const string DeliverOnlyOff = "Payload only needs somewhere to deliver to other than Log Only.";
    public const string PromptHeader = "Prompt";
    public const string PromptPlaceholder = "Instructions for the agent when this webhook fires (optional)";
    public const string Create = "Create";
    public const string Creating = "Creating…";

    // Webhook Created.
    public const string CreatedTitle = "Webhook Created";
    public const string CopyNow = "Copy the secret now. It is only shown once.";
    public const string Secret = "Secret";
    public const string NoSecret = "Your gateway didn’t send a secret for this webhook.";
    public const string Done = "Done";
}

/// The Webhooks wire (`AG/hermes_cli/web_routers/ops.py`).
public sealed class WebhooksApi(IPagesGateway gw)
{
    private static readonly TimeSpan Thirty = TimeSpan.FromSeconds(30);

    public async Task<WebhooksAnswer> ListAsync(CancellationToken ct = default)
    {
        var answer = await PagesRest.JsonAsync(gw, "GET", "/api/webhooks", timeout: Thirty, ct: ct);
        return WebhooksAnswer.From(answer) ?? throw PagesRest.UnreadableAnswer(answer);
    }

    public async Task<WebhookEnableResult> EnableAsync(CancellationToken ct = default) =>
        WebhookEnableResult.From(await PagesRest.JsonAsync(gw, "POST", "/api/webhooks/enable", timeout: TimeSpan.FromSeconds(60), ct: ct));

    public async Task<WebhookCreated> CreateAsync(WebhookForm form, CancellationToken ct = default)
    {
        var answer = await PagesRest.JsonAsync(gw, "POST", "/api/webhooks", body: form.Payload(), timeout: Thirty, ct: ct);
        return WebhookCreated.From(answer) ?? throw PagesRest.UnreadableAnswer(answer);
    }

    /// `PUT /api/webhooks/<name>/enabled` with `{"enabled": bool}`.
    public Task SetEnabledAsync(string name, bool on, CancellationToken ct = default) =>
        gw.RestAsync("PUT", $"/api/webhooks/{PagesRest.Segment(name)}/enabled", body: new JsonObject { ["enabled"] = on }, timeout: Thirty, ct: ct);

    public Task DeleteAsync(string name, CancellationToken ct = default) =>
        gw.RestAsync("DELETE", "/api/webhooks/" + PagesRest.Segment(name), timeout: Thirty, ct: ct);
}
