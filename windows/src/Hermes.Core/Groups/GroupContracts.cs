using System.Text.Json.Nodes;

namespace Hermes.Core.Groups;

// [groups] Contract additions for group chats (HermesKit/Contracts+groups.swift; docs/spec/3x-groups.md §3.4): the
// sender decoration rooms and deliveries share, a typing row, a refused send and the name-taken error. The Mac's
// `ChatRoomSurface` and `GroupServices` protocols are screen glue: they arrive with the room screen slice.

/// A sender other than you or the chat's own bot, drawn on a bubble (rooms, and deliveries: row L301).
public sealed record ChatSender(string Key, string Name, JsonNode? Head, string Profile, string? ColorHex);

/// One member answering now (a typing row): `Ivy is replying…` / `Waiting for your answer` / `Replying…`.
public sealed record RoomTyping(ChatSender? Sender, string Label);

/// A send a room refused.
public abstract record RoomSendRefusal
{
    /// `Slash commands are not supported in group chats. …` as a notice in the list.
    public sealed record SlashCommand : RoomSendRefusal;
    /// The "Can’t Send" alert (no member on this gateway).
    public sealed record NoMembers(string Room) : RoomSendRefusal;
}

public sealed class GroupNameTakenException(string name) : Exception($"A group named “{name}” already exists.")
{
    public string Name { get; } = name;
}
