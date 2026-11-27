using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Model;

namespace Hermes.Core.Gateways;

/// One bot's chat on a gateway that isn't in use, as this PC last saw it there (HermesKit/Model/GatewayNews.swift).
/// `Baseline` is the chat's last_active when this PC last showed that gateway's bots; `Marked` a chat left unread.
public sealed record ParkedChat(string Owner, string Id, string? Profile, double? Baseline, bool Marked = false);

/// What `GET /api/sessions/<id>` answered for one parked chat. `Id` is the id asked for, never the answer's own (the
/// gateway resolves prefixes and lineage).
public sealed record ParkedChatLive(string Id, double? LastActive, long? MessageCount)
{
    public static ParkedChatLive? From(JsonNode? json, string id) => json is JsonObject
        ? new ParkedChatLive(id, json.Num("last_active"), json.Int("message_count"))
        : null;
}

/// News on the gateways that aren't in use (spec 1x-settings §4.7). Pure.
public static partial class GatewayNews
{
    public const int MaxChats = 40;

    [GeneratedRegex(@"^[A-Za-z0-9][A-Za-z0-9_.-]{0,159}$")] public static partial Regex SessionIdPattern();

    /// `parkedChats`: the last roster's bots with a chat, without hidden bots or empty chats, each with its baseline.
    /// At most 40. The C# roster drops hidden bots already.
    public static IReadOnlyList<ParkedChat> Parked(IEnumerable<Bot> roster)
    {
        var chats = new List<ParkedChat>();
        foreach (var bot in roster)
        {
            if (bot.Hidden || bot.Canonical is not { } c) continue;
            if (c.MessageCount == 0) continue;
            var id = c.OpenId;
            if (id.Length == 0) continue;
            chats.Add(new ParkedChat(bot.Name, id, bot.Name == "default" ? null : bot.Name,
                c.LastActive is { } at ? at.ToUnixTimeMilliseconds() / 1000.0 : null));
            if (chats.Count >= MaxChats) break;
        }
        return chats;
    }

    /// `unreadCount`: chats still marked unread, or answered since this PC last saw them (no baseline: not news).
    public static int UnreadCount(IEnumerable<ParkedChat> chats, IEnumerable<ParkedChatLive> live)
    {
        var now = new Dictionary<string, ParkedChatLive>();
        foreach (var l in live) now.TryAdd(l.Id, l);
        return chats.Count(chat =>
        {
            if (chat.Marked) return true;
            if (!now.TryGetValue(chat.Id, out var answer) || answer.LastActive is not { } last || chat.Baseline is not { } baseline)
                return false;
            return last > baseline && answer.MessageCount != 0;
        });
    }

    /// "1 New" … "9 New", "9+ New" above nine.
    public static string? NewsLabel(int count) => count <= 0 ? null : count > 9 ? "9+ New" : $"{count} New";

    /// What Narrator says for the gateway switcher: "On Studio, 2 new on other gateways"; while a switch runs:
    /// "Switching to Beta"; with the link down: "On Studio, offline".
    public static string SwitcherLabel(string? page, string gateway, string? switchingTo, string? link, int otherNews)
    {
        var parts = new List<string>();
        if (!string.IsNullOrEmpty(page)) parts.Add(page);
        if (!string.IsNullOrEmpty(switchingTo))
        {
            parts.Add($"switching to {switchingTo}");
            return Sentence(parts);
        }
        if (gateway.Length > 0) parts.Add($"on {gateway}");
        if (link?.Trim('…', ' ', '.') is { Length: > 0 } l) parts.Add(l.ToLowerInvariant());
        if (otherNews > 9) parts.Add("more than 9 new on other gateways");
        else if (otherNews > 0) parts.Add($"{otherNews} new on other gateways");
        return Sentence(parts);
    }

    private static string Sentence(List<string> parts)
    {
        var line = string.Join(", ", parts);
        return line.Length == 0 ? line : char.ToUpperInvariant(line[0]) + line[1..];
    }
}

/// What Sign Out and Remove Gateway say before they run (App/Settings/SignOutWords.swift).
public static class SignOutWords
{
    public static (string Title, string Message) SignOut(string name, string? next, int unsent = 0, int recordings = 0)
    {
        var lost = Lost(unsent, recordings);
        var sentences = new List<string>();
        if (next != null) sentences.Add($"{name} leaves this list and Hermes HQ switches to {next}.");
        sentences.Add(char.ToUpperInvariant(lost[0]) + lost[1..] + $" on this {DeviceWord.Name} are deleted.");
        sentences.Add($"Your bots and chats stay on {name}. You can sign in again any time.");
        return ($"Sign out of {name}?", string.Join(" ", sentences));
    }

    public static string Remove(string accountName, int unsent = 0, int recordings = 0) =>
        $"{accountName} is signed out of this gateway on this {DeviceWord.Name}, and " + Lost(unsent, recordings)
        + " here are deleted. You can add it again.";

    /// "its drafts", or "its drafts, 2 unsent messages and 1 voice recording".
    public static string Lost(int unsent, int recordings)
    {
        var parts = new List<string> { "its drafts" };
        if (unsent > 0) parts.Add(unsent == 1 ? "1 unsent message" : $"{unsent} unsent messages");
        if (recordings > 0) parts.Add(recordings == 1 ? "1 voice recording" : $"{recordings} voice recordings");
        if (parts.Count == 1) return parts[0];
        return string.Join(", ", parts.Take(parts.Count - 1)) + " and " + parts[^1];
    }
}
