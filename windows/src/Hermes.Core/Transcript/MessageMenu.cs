using System.Text.Json.Nodes;
using Hermes.Core.Model;

namespace Hermes.Core.Transcripts;

/// One emoji reaction on a message: one per author (Tapback rules). Author is "user" (you) or "agent" (the bot)
/// (HermesKit/Chat/ChatGatewayExtras.swift MessageReaction).
public sealed record MessageReaction(string Emoji, string Author, double? At = null)
{
    public bool IsMine => Author == "user";
}

/// One badge on a bubble: an emoji, how many reacted with it, and whether one of them is yours.
public sealed record ReactionChip(string Emoji, int Count, bool Mine)
{
    public string Text => Count > 1 ? $"{Emoji} {Count}" : Emoji;
}

public static class MessageReactions
{
    /// The six iOS Tapbacks, in Apple's order.
    public static readonly IReadOnlyList<string> Quick = ["❤️", "👍", "👎", "😂", "‼️", "❓"];

    public static string Name(string emoji) => emoji switch
    {
        "❤️" => "Heart", "👍" => "Thumbs Up", "👎" => "Thumbs Down", "😂" => "Ha Ha", "‼️" => "Exclamation Marks",
        "❓" => "Question Mark", _ => emoji,
    };

    /// A reactions list, leniently: an array of {emoji, author, at}; malformed items skipped; an author twice keeps its
    /// newest. At most 64.
    public static IReadOnlyList<MessageReaction> Decode(JsonNode? json)
    {
        if (json is not JsonArray items) return [];
        IReadOnlyList<MessageReaction> o = [];
        foreach (var item in items.Take(500))
        {
            var emoji = item.Str("emoji")?.Trim();
            if (string.IsNullOrEmpty(emoji) || new System.Globalization.StringInfo(emoji).LengthInTextElements > 16) continue;
            var author = item.Str("author")?.Trim().ToLowerInvariant() ?? "";
            var at = item.Get("at") is JsonValue v && v.TryGetValue(out double d) && double.IsFinite(d) ? d : (double?)null;
            o = Merge(o, [new MessageReaction(emoji, author.Length == 0 ? "user" : author, at)]);
        }
        return o.Take(64).ToList();
    }

    /// The reactions a transcript row carries: `reactions` on the row, else inside `display_metadata` (an object, or a
    /// JSON string from an older backend).
    public static IReadOnlyList<MessageReaction> FromRow(JsonObject row)
    {
        if (row.Get("reactions") is JsonArray direct) return Decode(direct);
        var meta = row.Get("display_metadata") switch
        {
            JsonObject o => o,
            JsonValue v when v.TryGetValue(out string? s) => J.Parse(s) as JsonObject,
            _ => null,
        };
        return meta == null ? [] : Decode(meta.Get("reactions"));
    }

    /// Two lists as one: per author, the later one wins (b wins a tie or a missing time). Order: authors' first reaction.
    public static IReadOnlyList<MessageReaction> Merge(IReadOnlyList<MessageReaction> a, IReadOnlyList<MessageReaction> b)
    {
        var o = a.ToList();
        foreach (var r in b)
        {
            var i = o.FindIndex(x => x.Author == r.Author);
            if (i >= 0) { if ((o[i].At ?? double.NegativeInfinity) <= (r.At ?? double.PositiveInfinity)) o[i] = r; }
            else o.Add(r);
        }
        return o;
    }

    /// The local half of a Tapback: one per author; the same emoji again, or null, removes it.
    public static IReadOnlyList<MessageReaction> Applying(IReadOnlyList<MessageReaction> reactions, string? emoji, string author = "user", double? at = null)
    {
        var previous = reactions.FirstOrDefault(r => r.Author == author);
        var without = reactions.Where(r => r.Author != author).ToList();
        if (emoji == null || previous?.Emoji == emoji) return without;
        without.Add(new MessageReaction(emoji, author, at ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0));
        return without;
    }

    /// Badges in the order their emoji first appear.
    public static IReadOnlyList<ReactionChip> Chips(IReadOnlyList<MessageReaction> reactions)
    {
        var o = new List<ReactionChip>();
        foreach (var r in reactions)
        {
            var i = o.FindIndex(c => c.Emoji == r.Emoji);
            if (i >= 0) o[i] = o[i] with { Count = o[i].Count + 1, Mine = o[i].Mine || r.IsMine };
            else o.Add(new ReactionChip(r.Emoji, 1, r.IsMine));
        }
        return o;
    }

    /// Narrator's words for a message's badges: "Reactions: Heart from you, Thumbs Up from Ivy".
    public static string Spoken(IReadOnlyList<MessageReaction> reactions, string bot) =>
        "Reactions: " + string.Join(", ", reactions.Select(r => $"{Name(r.Emoji)} from {(r.IsMine ? "you" : bot)}"));
}

public enum MessageMenuItem { Copy, Share, Edit, SelectText, Regenerate, Branch, Steps, Rewind, Retry, Delete, ReadAloud }

/// One entry of a message's menu (HermesKit/Chat/ChatActionsModel.swift MessageMenuRow).
public sealed record MessageMenuRow(MessageMenuItem Id, string Title, bool Disabled = false, string? Subtitle = null, bool Destructive = false);

/// What the menu needs about the message and the chat.
public sealed record MessageMenuContext(bool Streaming = false, bool Running = false, bool Offline = false,
    bool CanEdit = false, bool Latest = false, bool? ShowSteps = null, bool CanRewind = false, bool Undelivered = false,
    bool? Reading = null);

/// A message's right-click menu, in the Mac's order: the tiles (yours: Copy, Edit; a reply's: Copy, Read Aloud, Share),
/// then Select Text, and for a reply Regenerate, Branch in New Chat, Show / Hide Steps; for yours Rewind to Here,
/// Send Again and Delete (MessageMenuModel).
public static class MessageMenu
{
    public const string StillReplying = "Still Replying";
    /// MenuWords.share on the Mac.
    public const string ShareWord = "Share…";

    private static MessageMenuRow Row(MessageMenuItem id, string title, MessageMenuContext ctx, bool destructive = false,
        bool writes = false, bool waitsForTurn = false)
    {
        var row = new MessageMenuRow(id, title, Destructive: destructive);
        if (ctx.Streaming && id is not (MessageMenuItem.Copy or MessageMenuItem.SelectText))
            return row with { Disabled = true, Subtitle = StillReplying };
        if (waitsForTurn && ctx.Running) return row with { Disabled = true, Subtitle = StillReplying };
        if (writes && ctx.Offline) return row with { Disabled = true, Subtitle = "Offline" };
        return row;
    }

    public static IReadOnlyList<MessageMenuRow> Tiles(bool reply, MessageMenuContext ctx)
    {
        var copy = Row(MessageMenuItem.Copy, "Copy", ctx);
        if (!reply) return ctx.CanEdit ? [copy, Row(MessageMenuItem.Edit, "Edit", ctx, writes: true)] : [copy];
        var o = new List<MessageMenuRow> { copy };
        if (ctx.Reading is { } reading) o.Add(Row(MessageMenuItem.ReadAloud, reading ? "Stop Reading" : "Read Aloud", ctx));
        o.Add(Row(MessageMenuItem.Share, ShareWord, ctx));
        return o;
    }

    public static IReadOnlyList<MessageMenuRow> Rows(bool reply, MessageMenuContext ctx)
    {
        var o = new List<MessageMenuRow> { Row(MessageMenuItem.SelectText, "Select Text", ctx) };
        if (reply)
        {
            if (ctx.Latest) o.Add(Row(MessageMenuItem.Regenerate, "Regenerate", ctx, writes: true, waitsForTurn: true));
            o.Add(Row(MessageMenuItem.Branch, "Branch in New Chat", ctx, writes: true, waitsForTurn: true));
            if (ctx.ShowSteps is { } show) o.Add(Row(MessageMenuItem.Steps, show ? "Show Steps" : "Hide Steps", ctx));
        }
        else
        {
            if (ctx.CanRewind) o.Add(Row(MessageMenuItem.Rewind, "Rewind to Here", ctx, destructive: true, writes: true));
            if (ctx.Undelivered)
            {
                o.Add(Row(MessageMenuItem.Retry, "Send Again", ctx, writes: true));
                o.Add(Row(MessageMenuItem.Delete, "Delete", ctx, destructive: true));
            }
        }
        return o;
    }

    /// The menu's title: "<sender> · <model> · <when>", the model only when it isn't the chat's current one.
    public static string Title(string sender, string? model, string? currentModel, string when) =>
        string.Join(" · ", new[] { sender, string.IsNullOrEmpty(model) || model == currentModel ? "" : model, when }.Where(s => s.Length > 0));

    /// The message's text blocks as the web joins them (ChatTranscript.blocks): text parts run together, a tool call
    /// ends a block, reasoning is skipped; blocks trimmed and joined by a blank line.
    public static string Blocks(ChatMessage message)
    {
        var blocks = new List<string>();
        string? current = null;
        foreach (var part in message.Parts)
        {
            if (part is TextPart t) current = (current ?? "") + t.Text;
            else if (part is ToolPart && current != null) { blocks.Add(current); current = null; }
        }
        if (current != null) blocks.Add(current);
        return string.Join("\n\n", blocks.Select(b => b.Trim()).Where(b => b.Length > 0));
    }

    private static readonly System.Text.RegularExpressions.Regex ManyNewlines = new(@"\n{3,}");

    /// ⋯ › Share…: the chat as plain text (ChatTranscript.text): the title, a blank line, then "You:" / "<Bot>:" on its
    /// own line over each message. System notices and tool rows are left out.
    public static string Transcript(IEnumerable<ChatMessage> messages, string botName, string? title = null)
    {
        var lines = new List<string>();
        if (title?.Trim() is { Length: > 0 } t) lines.AddRange([t, ""]);
        var bot = botName.Trim();
        foreach (var m in messages.Where(m => m.Role is Role.User or Role.Assistant))
        {
            var text = ManyNewlines.Replace(Blocks(m), "\n\n").Trim();
            if (text.Length == 0) continue;
            lines.AddRange([m.Role == Role.User ? "You:" : $"{(bot.Length == 0 ? "Hermes" : bot)}:", text, ""]);
        }
        return string.Join("\n", lines).Trim() + "\n";
    }
}
