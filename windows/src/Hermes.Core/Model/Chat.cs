using Hermes.Core.Attachments;

namespace Hermes.Core.Model;

public enum Role { User, Assistant, System }
public enum ToolState { Running, Done, Failed }

public abstract record ChatPart;
public sealed record TextPart(string Text) : ChatPart;
public sealed record ReasoningPart(string Text) : ChatPart;
public sealed record ToolPart(ToolCall Call) : ChatPart;
/// A photo, file, folder or link in a message (your sends, history refs, inline parts, a reply's MEDIA:).
public sealed record AttachmentPart(MessageAttachment Attachment) : ChatPart;
/// The picture an image_generate call made, in place of its tool row (spec 1x-attachments §7.7).
public sealed record GeneratedImagePart(string ToolId, GeneratedImageInfo Image) : ChatPart;

public sealed record ToolCall(string Id, string Name, string? ArgsText, string? Summary, ToolState State,
    double? DurationSeconds = null, string? ArgsJson = null, string? ResultText = null)
{
    // ArgsJson: the call's whole arguments as JSON text (HermesKit ToolCall.argsText), for the step wording
    // (Transcript/RunSummary.cs). ResultText: the result as the gateway sent it (bounded), for the step sheet.

    /// "terminal · printf synthetic-step-0": what a compact tool row shows.
    public string Title => ArgsText is { Length: > 0 } a ? $"{Name} · {FirstLine(a, 80)}" : Name;

    internal static string FirstLine(string s, int max)
    {
        var line = s.Split('\n', 2)[0].Trim();
        return line.Length > max ? line[..(max - 1)] + "…" : line;
    }
}

/// One bubble (HermesKit/Contracts.swift ChatMessage). Immutable: every change makes a new value with a bumped
/// Revision, so the UI can redraw only what changed.
public sealed record ChatMessage(string Id, Role Role, IReadOnlyList<ChatPart> Parts, DateTimeOffset? Timestamp = null,
    long? RowId = null, bool IsStreaming = false, bool IsPending = false, bool Interrupted = false,
    string? Error = null, int Revision = 0, IReadOnlyList<Hermes.Core.Transcripts.MessageReaction>? Reactions = null,
    long? ReactionRow = null)
{
    // Reactions: Tapbacks from every row folded in (HermesKit ChatMessage.reactions); ReactionRow: the row holding the
    // words, where a new reaction goes (reactionRow / reactionTarget).
    public string Text => string.Concat(Parts.OfType<TextPart>().Select(p => p.Text));
    /// [groups] Another bot's or a room member's name and face on this bubble (ChatMessage.sender; rooms and
    /// deliveries, docs/spec/3x-groups.md §3.4). Null: you, or the chat's own bot.
    public Hermes.Core.Groups.ChatSender? Sender { get; init; }
    public IEnumerable<ToolCall> Tools => Parts.OfType<ToolPart>().Select(p => p.Call);
    public IEnumerable<MessageAttachment> Attachments => Parts.OfType<AttachmentPart>().Select(p => p.Attachment);
}
