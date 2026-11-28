using System.Text.Json.Nodes;

namespace Hermes.Core.Model;

/// A row of /api/profiles/sessions/sidebar (HermesKit/Model/RosterSessions.swift).
public sealed record SessionRow(string Id, string Title, string? Preview, string Profile, string? Source,
    DateTimeOffset? LastActive, long? MessageCount, bool Pinned, bool Unread, bool Archived, string? Model,
    string? Cwd = null, string? Branch = null)
{
    public static SessionRow? From(JsonNode? n)
    {
        if (n?.Text("id") is not { } id) return null;
        return new SessionRow(id, n.Text("title") ?? n.Text("preview") ?? "Untitled session", n.Text("preview"),
            n.Text("profile") ?? n.Text("profile_name") ?? "default", n.Text("source"),
            n.UnixTime("last_active") ?? n.UnixTime("started_at"), n.Int("message_count"),
            n.Bool("pinned") ?? false, n.Bool("unread") ?? false, n.Bool("archived") ?? false, n.Text("model"),
            n.Text("cwd"), n.Text("git_branch") ?? n.Text("branch"));
    }
}

/// One slice of the sidebar. Failed means the gateway's scan failed: show "Retry", not "No sessions".
public sealed record SessionSlice(IReadOnlyList<SessionRow> Rows, bool Failed)
{
    public static SessionSlice From(JsonNode? slice) => slice.Arr("sessions") is { } rows
        ? new SessionSlice([.. rows.Select(SessionRow.From).OfType<SessionRow>()], false)
        : new SessionSlice([], true);
}

public sealed record Sidebar(SessionSlice Recents, SessionSlice Cron, SessionSlice Messaging)
{
    public static Sidebar Parse(JsonNode? j) =>
        new(SessionSlice.From(j.Get("recents")), SessionSlice.From(j.Get("cron")), SessionSlice.From(j.Get("messaging")));

    public static readonly KeyValuePair<string, string>[] Query =
    [
        new("recents_profile", "all"), new("recents_limit", "50"), new("cron_limit", "50"), new("messaging_limit", "100"),
        new("recents_exclude", "acp,cron,kanban,oneshot,subagent,telegram,discord,slack,mattermost,matrix,signal,whatsapp,bluebubbles,photon,homeassistant,email,sms,webhook,api_server,weixin,wecom,qqbot,yuanbao,dingtalk,feishu"),
        new("messaging_exclude", "cron,acp,cli,codex,desktop,gateway,kanban,local,tui"),
        new("profile", "default"),
    ];
}
