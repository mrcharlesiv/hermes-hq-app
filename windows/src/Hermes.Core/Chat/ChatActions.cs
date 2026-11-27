using System.Text.Json.Nodes;
using Hermes.Core.Model;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Chat;

/// [chat actions] A new chat made by Branch: its stored id (the one to open) and the runtime id the gateway already
/// bound (HermesKit/Chat/LiveChatSession+ChatActions.swift ChatBranchResult).
public sealed record ChatBranchResult(string StoredId, string? RuntimeId);

/// [chat actions] The Mac's words for Regenerate, Branch in New Chat, Rewind to Here and Edit, exactly
/// (App/Chat/Menus/ChatMenus+Actions.swift, App/Chat/Menus/AppModel+ChatMenus.swift openBranch,
/// HermesKit/Chat/LiveChatSession+ChatActions.swift).
public static class ChatActionWords
{
    // Branch
    public const string Branching = "Branching…";
    public const string Branched = "Branched into a new chat.";
    public const string BranchFailed = "Couldn’t Branch Chat";
    public const string StopBeforeBranch = "Stop the current reply before branching from it.";
    public const string NotInChat = "This message isn't in the chat anymore.";
    public const string NotSaved = "This message isn't saved on your gateway yet.";
    public const string NothingToBranch = "Nothing to branch — send a message first.";
    public const string BranchShape = "Hermes answered the branch in a shape this app doesn't read.";
    public const string Loading = "This chat is still loading. Try again when it is ready.";

    /// The branch's title as it opens (AppModel+ChatMenus.swift openBranch): "Branch of <parent>", or "Branch".
    public static string BranchTitle(string? parent) =>
        parent?.Trim() is { Length: > 0 } p ? $"Branch of {p}" : "Branch";

    // Regenerate
    public const string WaitForReply = "Wait for the reply to finish.";
    public const string Offline = "Offline";
    public const string CantRegenerate = "This reply can’t be regenerated.";
    public const string RegenerateFailed = "Couldn’t Regenerate";
    public const string RegenerateTitle = "Replace This Reply?";
    public const string RegenerateMessage = "The prompt runs again, and a new reply takes this one’s place.";
    public const string RegenerateButton = "Regenerate";
    public const string Cancel = "Cancel";

    // Rewind to Here
    public const string RewindTitle = "Rewind to Here?";
    public const string RewindMessage = "Everything after this message is removed from the chat, and it runs again from here.";
    public const string RewindButton = "Rewind and Rerun";
    public const string CantRewind = "This message can’t be rewound to.";
    public const string RewindFailed = "Couldn’t Rewind";

    // Edit
    public const string EditingTitle = "Editing Message";
    public const string EditingNote = "Later messages will be removed";
    public const string CancelEditing = "Cancel Editing";
    public const string EditTitle = "Send Edit?";
    public const string EditMessage = "Everything after this message is removed from the chat, and it runs again from your edit.";
    public const string EditButton = "Send and Rerun";
    public const string CantEdit = "This message can’t be edited anymore.";
    public const string EditFailed = "Couldn’t Edit Message";

    /// A rewind's send refused without a reason (rewindRefused).
    public const string NotAccepted = "Hermes didn't accept the change.";

    // The latest reply's action row (App/Chat/Cells/ChatCells.swift ChatActionsCell): its Regenerate and More.
    public const string RegenerateReplyId = "chat.regenerate-reply";
    public const string ReplyMoreId = "chat.reply-more";
    public const string MoreLabel = "More";
    /// The More menu's rows' ids (`reply-more.<id>`, Select Text's "select").
    public static string ReplyMoreRowId(MessageMenuItem id) => "reply-more." + id switch
    {
        MessageMenuItem.SelectText => "select",
        MessageMenuItem.Share => "share",
        MessageMenuItem.Branch => "branch",
        _ => id.ToString().ToLowerInvariant(),
    };
}

/// [chat actions] How a rewind, edit or regenerate names the turn it truncates before (HermesKit/Chat/
/// ChatActionsModel.swift RewindParams): the user row's id, `confirm_truncate`, and every loaded row id so the gateway
/// can tell the app the kept rows' new ids.
public static class RewindParams
{
    public static JsonObject Make(long beforeRowId, IEnumerable<long> loadedRowIds)
    {
        var survivors = new JsonArray();
        foreach (var row in loadedRowIds.Distinct()) survivors.Add(row);
        return new JsonObject
        {
            ["truncate_before_row_id"] = beforeRowId, ["confirm_truncate"] = true, ["confirm_empty_truncate"] = true,
            ["rebind_survivor_row_ids"] = survivors,
        };
    }

    /// The kept rows' new ids from a rewind's answer: `survivor_row_id_map` {"old": new|null}; null maps a row away.
    public static IReadOnlyDictionary<long, long?> SurvivorMap(JsonNode? result)
    {
        var o = new Dictionary<long, long?>();
        if (result?["survivor_row_id_map"] is not JsonObject map) return o;
        foreach (var (key, value) in map)
        {
            if (!long.TryParse(key, System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out var old)) continue;
            o[old] = value is JsonValue v && v.TryGetValue(out double d) && double.IsFinite(d) ? (long)d : null;
        }
        return o;
    }

    /// Text-bearing user and assistant messages up to and including `messageId` (`session.branch`'s `count`).
    public static int? BranchCount(string messageId, IReadOnlyList<ChatMessage> messages)
    {
        var index = -1;
        for (var i = 0; i < messages.Count; i++) if (messages[i].Id == messageId) { index = i; break; }
        if (index < 0) return null;
        return messages.Take(index + 1).Count(m => m.Role is Role.User or Role.Assistant && MessageMenu.Blocks(m).Length > 0);
    }
}

/// [chat actions] The decisions behind the menu rows (LiveChatSession+ChatActions.swift, ChatMenus+Actions.swift).
public static class ChatActionRules
{
    /// Whether a message can be edited / rewound to: your stored text message (not pending, not failed, a row id,
    /// nothing attached, some words).
    public static bool CanRewind(ChatMessage m) =>
        m.Role == Role.User && !m.IsPending && m.Error == null && m.RowId is > 0
        && !m.Attachments.Any() && m.Text.Trim().Length > 0;

    /// The prompt of the newest reply: the user turn before the last reply (`planReload`); null when there is none.
    public static int? RegeneratePrompt(IReadOnlyList<ChatMessage> messages)
    {
        var reply = -1;
        for (var i = messages.Count - 1; i >= 0; i--) if (messages[i].Role == Role.Assistant) { reply = i; break; }
        for (var i = reply - 1; i >= 0; i--) if (messages[i].Role == Role.User) return i;
        return null;
    }

    /// Whether a later message of yours follows this one: its edit removes those turns too (editing your latest
    /// message loses nothing).
    public static bool HasLaterMessages(IReadOnlyList<ChatMessage> messages, string messageId)
    {
        for (var i = 0; i < messages.Count; i++)
            if (messages[i].Id == messageId) return messages.Skip(i + 1).Any(m => m.Role == Role.User);
        return false;
    }

    /// The newest reply that has settled: the one the action row (Copy · Regenerate · More) and the menu's
    /// Regenerate belong to.
    public static string? LatestReplyId(IReadOnlyList<ChatMessage> messages) =>
        messages.LastOrDefault(m => m.Role == Role.Assistant)?.Id;

    /// What a Regenerate press says instead of acting (ChatMenus+Actions.swift regenerateLatest / confirmRegenerate):
    /// "Wait for the reply to finish." while a reply runs, "Offline" offline; null to go ahead.
    public static string? RegenerateBlocked(bool running, bool offline) =>
        running ? ChatActionWords.WaitForReply : offline ? ChatActionWords.Offline : null;

    /// The More at the end of the latest reply's action row (MessageMenuModel.replyMore): Share…, Select Text, Branch in
    /// New Chat; Branch waits for the turn and needs the gateway.
    public static IReadOnlyList<MessageMenuRow> ReplyMore(bool running, bool offline) =>
    [
        new(MessageMenuItem.Share, MessageMenu.ShareWord),
        new(MessageMenuItem.SelectText, "Select Text"),
        running ? new(MessageMenuItem.Branch, "Branch in New Chat", true, MessageMenu.StillReplying)
            : offline ? new(MessageMenuItem.Branch, "Branch in New Chat", true, "Offline")
            : new(MessageMenuItem.Branch, "Branch in New Chat"),
    ];

    /// Edit: the text to send, or null when nothing changed or nothing is typed (`planEdit`).
    public static string? EditedText(ChatMessage original, string typed)
    {
        var t = typed.Trim();
        if (t.Length == 0 || t == original.Text.Trim()) return null;
        return t;
    }
}
