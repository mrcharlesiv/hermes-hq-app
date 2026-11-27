using System.Text.Json.Nodes;
using Hermes.Core.Bots;
using Hermes.Core.Heads;
using Hermes.Core.Model;

namespace Hermes.Core.Groups;

// [groups] Deliveries from another bot in an ordinary chat (HermesKit/Groups/DeliveryMessages.swift;
// docs/spec/3x-groups.md §7.12, row L301): a user-role message that starts with a delivery prefix becomes an incoming
// message with its sender, the prefix removed. The sender is found in the roster by handle, then display name, then
// `hermes` → the default bot (`S/ui-chat/chat-identity.ts:100-112`); an unknown sender keeps the prefix's name and the
// default head.
public static class DeliveryMessages
{
    /// What the lookup needs of a bot.
    public sealed record Seat(string Profile, string Name, JsonNode? Head)
    {
        public bool Equals(Seat? o) => o != null && Profile == o.Profile && Name == o.Name && JsonNode.DeepEquals(Head, o.Head);
        public override int GetHashCode() => HashCode.Combine(Profile, Name);
    }

    /// Cheap test before the regular expression: only a text that starts like a delivery is parsed.
    public static bool MayBeDelivery(string text) =>
        text.StartsWith("Message from ", StringComparison.Ordinal) || text.StartsWith("[Message from agent '", StringComparison.Ordinal);

    public static ChatSender Sender(DeliverySender.Parsed parsed, IReadOnlyList<Seat> roster)
    {
        var handle = parsed.Handle.ToLowerInvariant();
        var name = parsed.Name.Trim(' ').ToLowerInvariant();
        var found = roster.FirstOrDefault(s => RosterRules.Handle(s.Profile) == handle)
            ?? roster.FirstOrDefault(s => s.Name.Trim(' ').ToLowerInvariant() == name)
            ?? (handle == "hermes" || name == "hermes" ? roster.FirstOrDefault(s => s.Profile == "default") : null);
        if (found != null)
            return new ChatSender("delivery:" + found.Profile, found.Name, found.Head, found.Profile, ChatSenderColors.Hex(found.Head, found.Profile));
        // Unknown: the name as written, the default head, the label colour.
        return new ChatSender("delivery:?" + handle, parsed.Name, null, "default", null);
    }

    /// `messages` with every delivery turned into its sender's message. The same list comes back when there is none.
    public static (IReadOnlyList<ChatMessage> Messages, bool Found) Resolve(IReadOnlyList<ChatMessage> messages, IReadOnlyList<Seat> roster)
    {
        List<ChatMessage>? o = null;
        for (var i = 0; i < messages.Count; i++)
        {
            var message = messages[i];
            if (message.Role != Role.User || message.Sender != null || message.Parts.Count == 0 || message.Parts[0] is not TextPart first
                || !MayBeDelivery(first.Text) || DeliverySender.Parse(first.Text) is not { } parsed) continue;
            o ??= [.. messages];
            var parts = message.Parts.ToList();
            parts[0] = new TextPart(parsed.Body);
            o[i] = message with { Sender = Sender(parsed, roster), Parts = parts };
        }
        return (o ?? messages, o != null);
    }

    public static bool HasDelivery(IReadOnlyList<ChatMessage> messages) =>
        messages.Any(m => m.Role == Role.User && m.Parts.Count > 0 && m.Parts[0] is TextPart t && MayBeDelivery(t.Text) && DeliverySender.Parse(t.Text) != null);
}

/// The roster the chat screens resolve deliveries against, and who to tell when it changes (set up by the app model).
/// Read and written on the UI thread, as the Mac's is main-actor.
public static class DeliveryRoster
{
    public static IReadOnlyList<DeliveryMessages.Seat> Seats { get; private set; } = [];
    private static readonly Dictionary<Guid, System.Action> Listeners = [];

    public static void Set(IReadOnlyList<DeliveryMessages.Seat> next)
    {
        if (next.SequenceEqual(Seats)) return;
        Seats = [.. next];
        foreach (var listener in Listeners.Values.ToList()) listener();
    }

    public static Guid Observe(System.Action change)
    {
        var id = Guid.NewGuid();
        Listeners[id] = change;
        return id;
    }

    public static void StopObserving(Guid id) => Listeners.Remove(id);
}

/// A sender's colour before the contrast step: its head's accent (the colour the row's face uses)
/// (HermesKit/Groups/GroupRoomSession.swift `ChatSenderColors`).
public static class ChatSenderColors
{
    /// A name follows its own face (V13): a white/black face (ink, paper) has no colour of its own, so its name is the
    /// label colour (null).
    public static string? Hex(JsonNode? head, string profile)
    {
        var resolved = Head.Resolve(head, profile);
        if (resolved.Color is HeadColor.Ink or HeadColor.Paper) return null;
        return HeadTones.Accent(resolved.Color).ToString();
    }
}
