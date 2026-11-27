using Hermes.Core.Bots;

namespace Hermes.Core.Groups;

/// [groups] The roster a room seats its members from (`GroupStore.Roster`; the Mac's `BotStore` through
/// `groupChatMemberBots`): each bot's merged `hermes-bots` meta (its `groups` list names its rooms), names and head.
public sealed class BotStoreGroupRoster(BotStore store) : IGroupRoster
{
    public bool Loaded => store.HasRoster;

    public IReadOnlyList<GroupRosterProfile> Profiles => [.. store.Rows.Select(r => new GroupRosterProfile(r.Id)
    {
        Meta = store.CurrentMeta(r.Id), DisplayName = r.Model.DisplayName, BotName = r.Name, Head = r.Model.HeadRaw,
    })];
}
