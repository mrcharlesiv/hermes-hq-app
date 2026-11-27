using Hermes.Core.Groups;
using HermesHQ.Features.Bots;
using HermesHQ.Features.Notifications;

namespace HermesHQ.Features.Groups;

/// [groups] The account's room engine and the room on screen (App/Groups/AppModel+Groups.swift `GroupsHub`): one
/// GroupEngine over the signed-in gateway's GroupStore (ListsHub.Groups), made on the UI thread the first time a room
/// opens and ended when the account changes (a round belongs to the account, not to the room's page). A member's reply
/// in a room not on screen raises the room's alert (`engine.onReply` → GroupsHub.replied: Hermes.Core RoomAlerts decides,
/// NotificationsFeature shows it). Not here yet: hosted rooms, the members' questions (D6).
internal static class GroupRooms
{
    private static ListsHub? _hub;
    private static GroupEngine? _engine;

    /// The room on screen (its replies are read as they arrive: `engine.isFocused`).
    public static string? Focused { get; private set; }

    /// The engine of the signed-in account's rooms; null when signed out.
    public static GroupEngine? Engine
    {
        get
        {
            var hub = ListsHub.Current;
            if (hub == null) return null;
            if (!ReferenceEquals(hub, _hub) || _engine == null)
            {
                _engine?.Shutdown();   // the account left (Sign Out, another gateway): its rounds end here
                _hub = hub;
                Focused = null;
                NotificationsFeature.Rooms.Clear();   // GroupsHub.tearDown: no room on screen, nobody spoke
                _engine = new GroupEngine(hub.Groups, new ClientGroupGateway(hub.Client))
                {
                    IsFocused = key => key == Focused,
                    OnReply = NotificationsFeature.RoomReplied,
                };
            }
            return _engine;
        }
    }

    /// A session for the room's screen (`GroupsHub.session(for:)`), or null when the room isn't known.
    public static GroupRoomSession? Open(string key)
    {
        if (Engine is not { } engine || _hub is not { } hub) return null;
        var session = GroupRoomSession.Open(key, hub.Groups, engine, hub.Client.Session.Address.ToString());
        if (session == null) return null;
        var uid = hub.Groups.Room(key)?.Uid;
        session.OnObservingChange = on =>
        {
            if (on) Focused = session.RoomKey;
            else if (Focused == session.RoomKey) Focused = null;
            if (uid is { } u) NotificationsFeature.Rooms.SetFocused(u, on);   // GroupsHub.setFocused
        };
        return session;
    }
}
