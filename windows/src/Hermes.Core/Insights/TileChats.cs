using System.Text.Json.Nodes;
using Hermes.Core.Composer;
using Hermes.Core.Sessions;

namespace Hermes.Core.Insights;

/// [tile-chats] A tile's own chat (HermesKit/Pages/TileChats.swift): chats made for a tile (New Tile, Change…,
/// Duplicate…, Keep Updated…, live button turns, or roll-back updates) are born hidden on the gateway
/// (`session.create {hidden: true}`). Older tile chats created in the open are detected by how the app's ask begins
/// or by tile pin linkage so Sessions lists hide them cleanly.
public static class TileChats
{
    private const string StorePrefix = "hqn.tileChats.";
    private const int RememberLimit = 300;
    private static readonly HashSet<string> KnownSessions = new(StringComparer.Ordinal);

    /// How tile maker asks begin (`TilePromptBuilder` / `TileJobs`): kept to their leading phrases, which fit the
    /// gateway's preview length.
    public static readonly string[] Openings =
    [
        "Make me a live tile for my Hermes HQ Dashboard",
        "Make me a new live tile for my Hermes HQ Dashboard",
        "Change my Hermes HQ Dashboard tile",
        "Keep my Hermes HQ Dashboard tile",
        "I rolled my Hermes HQ tile",
    ];

    /// Records a session id known to be a tile chat in memory (so `IsTileChat` recognizes it by id too).
    public static void RememberSession(string? sessionId)
    {
        var id = sessionId?.Trim();
        if (string.IsNullOrEmpty(id)) return;
        lock (KnownSessions) KnownSessions.Add(id);
    }

    public static void ForgetSession(string? sessionId)
    {
        var id = sessionId?.Trim();
        if (string.IsNullOrEmpty(id)) return;
        lock (KnownSessions) KnownSessions.Remove(id);
    }

    /// Persists a tile chat session id under `hqn.tileChats.<accountId>` (newest 300, matching Mac `TileMaker.rememberChat`).
    public static void RememberChat(string accountId, string? sessionId, IKeyValueStore store)
    {
        var id = sessionId?.Trim();
        if (string.IsNullOrEmpty(id)) return;
        RememberSession(id);
        var ids = ChatIds(accountId, store).Where(x => x != id).ToList();
        ids.Add(id);
        var kept = ids.Skip(Math.Max(0, ids.Count - RememberLimit)).ToList();
        store.Set(StorePrefix + accountId, new JsonArray([.. kept.Select(x => (JsonNode)x)]).ToJsonString());
    }

    public static IReadOnlyList<string> ChatIds(string accountId, IKeyValueStore store)
    {
        var raw = store.Get(StorePrefix + accountId);
        if (string.IsNullOrWhiteSpace(raw) || J.Parse(raw) is not JsonArray arr) return [];
        return arr.Select(J.AsString).OfType<string>().Where(s => s.Length > 0).ToList();
    }

    /// True when `title` (a chat's preview or title) starts with one of the app's tile prompts / display titles,
    /// or `sessionId` is a remembered tile chat session id.
    public static bool IsTileChat(string? title, string? sessionId = null)
    {
        if (!string.IsNullOrWhiteSpace(sessionId))
        {
            var id = sessionId.Trim();
            lock (KnownSessions)
                if (KnownSessions.Contains(id)) return true;
        }
        var text = title?.Trim();
        if (string.IsNullOrEmpty(text)) return false;
        foreach (var opening in Openings)
            if (text.StartsWith(opening, StringComparison.Ordinal)) return true;
        if (text.StartsWith("New tile: ", StringComparison.Ordinal)) return true;
        if (text.StartsWith("Change tile: ", StringComparison.Ordinal)) return true;
        if (text.StartsWith("Change tile ", StringComparison.Ordinal) && text.Contains(": ", StringComparison.Ordinal))
            return true;
        return false;
    }

    /// Returns the set of session IDs from `sessions` that are tile chats (either matched by opening/display title
    /// on the session's preview/title, or linked as a dedicated tile chat on `pins`).
    public static IReadOnlySet<string> ToHide(IEnumerable<SessionSummary> sessions, IEnumerable<TilePin> pins)
    {
        var pinTileSessions = new HashSet<string>(StringComparer.Ordinal);
        foreach (var pin in pins)
        {
            if (string.IsNullOrWhiteSpace(pin.SessionId)) continue;
            if (pin.ChatAt != null || IsTileChat(pin.SessionTitle, pin.SessionId))
                pinTileSessions.Add(pin.SessionId);
        }

        var hide = new HashSet<string>(StringComparer.Ordinal);
        foreach (var session in sessions)
        {
            if (string.IsNullOrWhiteSpace(session.Id)) continue;
            if (pinTileSessions.Contains(session.Id)
                || IsTileChat(session.Preview, session.Id)
                || IsTileChat(session.Title, session.Id))
            {
                hide.Add(session.Id);
            }
        }
        return hide;
    }
}
