using Hermes.Core.Model;

namespace HermesHQ.Shell;

/// What the content pane shows. Features navigate through this, never through each other's pages.
public abstract record Destination;
public sealed record BotChatDestination(Bot Bot) : Destination;
/// `Draft`: words for the chat's message box as it opens (`/new <words>`); empty leaves the box as it was.
public sealed record ChatDestination(string Profile, string StoredId, string Title, string Draft = "") : Destination;
/// [groups] A group chat by its room key (`AppModel.openRoom`): the room's own chat in the pane (Pages/GroupRoomPage.cs).
public sealed record RoomDestination(string Key) : Destination;
public sealed record PlaceDestination(string PlaceId, object? Argument = null) : Destination;

public static class Navigator
{
    /// Raised on the UI thread; ShellPage shows it.
    public static event Action<Destination>? Requested;

    public static void Go(Destination d) => Requested?.Invoke(d);
    /// The signed-in shell is up and shows what is asked (a toast clicked at a cold launch waits for it).
    public static bool Listening => Requested != null;
    public static void Open(string placeId, object? argument = null) => Go(new PlaceDestination(placeId, argument));
}

/// What a place's page receives in OnNavigatedTo.
public sealed record PlaceArgs(Place Place, object? Argument);
