using System.Globalization;
using System.Text.Json.Nodes;

namespace Hermes.Core.Model;

public sealed record SessionRef(string Id, string? ResolvedId, string? Title, string? RootTitle, string? Preview,
    DateTimeOffset? LastActive, long? MessageCount)
{
    /// Open resolved_id || id (spec 02 §8.1).
    public string OpenId => ResolvedId ?? Id;

    public static SessionRef? From(JsonNode? n) => n?.Text("id") is { } id
        ? new SessionRef(id, n.Text("resolved_id"), n.Text("title"), n.Text("root_title"), n.Text("preview"),
            n.UnixTime("last_active"), n.Int("message_count"))
        : null;
}

/// One bot = one Hermes profile (HermesKit/Model/RosterWire.swift).
public sealed record Bot(string Name, string DisplayName, string? Description, string? Model, bool IsDefault,
    bool Pinned, bool Hidden, string? SectionName, bool HasAvatar, SessionRef? Canonical, SessionRef? Last)
{
    public const string BotChatTitle = "Bot Chat";

    public string Initials => string.Concat(DisplayName.Split(' ', StringSplitOptions.RemoveEmptyEntries)
        .Take(2).Select(w => char.ToUpperInvariant(w[0])));

    public DateTimeOffset? LastActive => Canonical?.LastActive ?? Last?.LastActive;

    /// [heads] The saved head, raw (`ui_meta["dispatch-head"]`; null: none, the name's default) and the revisions of the
    /// two ui_meta keys a face depends on (`ui_meta_revisions`): the head's for its compare-and-swap save, both for when
    /// a bot's photo is fetched again (Hermes.Core/Heads).
    public JsonNode? HeadRaw { get; init; }
    public int HeadRevision { get; init; }
    public int BotsRevision { get; init; }

    /// A `ui_meta_revisions` entry: a whole number ≥ 0, else 0 (BotStore+Editing.swift `uiMetaRevision`).
    public static int MetaRevision(JsonNode? row, string key) =>
        row.Obj("ui_meta_revisions").Get(key) is JsonValue v && v.TryGetValue(out double n) && n >= 0 && Math.Round(n) == n ? (int)n : 0;

    public static Bot? From(JsonNode? n)
    {
        if (n?.Text("name") is not { } name) return null;
        var meta = n.Obj("ui_meta").Obj("hermes-bots");
        var display = meta.Text("title") ?? n.Text("display_name") ?? meta.Text("display_name")
            ?? (name == "default" ? "Hermes" : TitleCase(name));
        return new Bot(name, display, meta.Text("description") ?? n.Text("description"), n.Text("model"),
            n.Bool("is_default") ?? name == "default", meta.Bool("pinned") ?? false, meta.Bool("hidden") ?? false,
            meta.Text("sectionName"), n.Bool("has_avatar") ?? false,
            SessionRef.From(n.Get("canonical_session")), SessionRef.From(n.Get("last_session")))
        {
            HeadRaw = n.Obj("ui_meta").Get("dispatch-head") is { } head && head.GetValueKind() != System.Text.Json.JsonValueKind.Null ? head : null,
            HeadRevision = MetaRevision(n, "dispatch-head"),
            BotsRevision = MetaRevision(n, "hermes-bots"),
        };
    }

    public static string TitleCase(string name) =>
        CultureInfo.InvariantCulture.TextInfo.ToTitleCase(name.Replace('-', ' ').Replace('_', ' '));
}

public static class Roster
{
    /// profiles.list result → visible bots, pinned first, then most recently active, then by name.
    public static IReadOnlyList<Bot> Parse(JsonNode? result)
    {
        if (result.Arr("profiles") is not { } profiles)
            throw new Net.GatewayException("not-hermes", "The gateway's bot list wasn't readable.");
        return [.. profiles.Select(Bot.From).OfType<Bot>().Where(b => !b.Hidden)
            .OrderByDescending(b => b.Pinned)
            .ThenByDescending(b => b.LastActive ?? DateTimeOffset.MinValue)
            .ThenBy(b => b.DisplayName, StringComparer.CurrentCultureIgnoreCase)];
    }
}
