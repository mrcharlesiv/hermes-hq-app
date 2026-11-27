using System.Text.Json.Nodes;
using Hermes.Core.Bots;
using Hermes.Core.Groups;
using Hermes.Core.Shell;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-51] Name & Photo's photo and Group Info's member faces: App/Groups/GroupPhoto.swift (the square crop, the JPEG
/// data URL's ladder of sides and qualities under GroupLimits.syncImage) and GroupInfoSheet.swift (GroupNamePhotoModel,
/// the save's rename then `store.setImage` on the room's key after it).
public class GroupPhotoTests
{
    [Fact]
    public void TheWordsAreTheMacs()
    {
        Assert.Equal("Photo", GroupPhoto.Header);
        Assert.Equal("Choose Photo", GroupPhoto.ChoosePhoto);
        Assert.Equal("Remove Photo", GroupPhoto.RemovePhoto);
        Assert.Equal("Couldn’t Use That Photo", GroupPhoto.FailedTitle);
        Assert.Equal("The photo could not be read. Choose another one.", GroupPhoto.FailedReason);
        Assert.Equal("data:image/jpeg;base64,", GroupPhoto.Prefix);
        Assert.Equal([256, 224, 192, 160, 128, 112, 96, 80, 64, 48], GroupPhoto.Sides);
        Assert.Equal([0.8, 0.7, 0.6, 0.5, 0.4, 0.3], GroupPhoto.Qualities);
    }

    [Fact]
    public void TheSquareFillsTheSideFromTheCentre()
    {
        // A landscape image: scaled by height, its sides cut off evenly.
        var wide = GroupPhoto.Square(400, 200, 256)!.Value;
        Assert.Equal(512, wide.Width);
        Assert.Equal(256, wide.Height);
        Assert.Equal(-128, wide.X);
        Assert.Equal(0, wide.Y);
        // A portrait image: scaled by width, top and bottom cut off.
        var tall = GroupPhoto.Square(100, 300, 48)!.Value;
        Assert.Equal(48, tall.Width);
        Assert.Equal(144, tall.Height);
        Assert.Equal(0, tall.X);
        Assert.Equal(-48, tall.Y);
        // Nothing to draw for an empty image (the Mac leaves the white square).
        Assert.Null(GroupPhoto.Square(0, 10, 64));
    }

    [Fact]
    public void FitsCountsBase64BeforeEncoding()
    {
        var prefix = GroupPhoto.Prefix.Length;
        // 3 bytes → 4 characters; 4 bytes → 8.
        Assert.True(GroupPhoto.Fits(3, prefix + 4));
        Assert.False(GroupPhoto.Fits(4, prefix + 4));
        Assert.True(GroupPhoto.Fits(4, prefix + 8));
    }

    [Fact]
    public async Task TheDataUrlTakesTheFirstSideAndQualityThatFits()
    {
        var tried = new List<(int, double)>();
        // The encoder's size grows with the side and the quality; only 160 px at 0.5 or below fits the limit.
        Task<byte[]?> Encode(int side, double quality)
        {
            tried.Add((side, quality));
            return Task.FromResult<byte[]?>(new byte[side * 100 + (int)(quality * 10) * 1000]);
        }
        var limit = GroupPhoto.Prefix.Length + (160 * 100 + 5000 + 2) / 3 * 4;
        var url = await GroupPhoto.DataUrlAsync(Encode, limit);
        Assert.NotNull(url);
        Assert.StartsWith(GroupPhoto.Prefix, url, StringComparison.Ordinal);
        Assert.True(url!.Length <= limit);
        Assert.Equal((160, 0.5), tried[^1]);
        Assert.Equal((256, 0.8), tried[0]);
        Assert.Equal(160 * 100 + 5000, Convert.FromBase64String(url[GroupPhoto.Prefix.Length..]).Length);
    }

    [Fact]
    public async Task TheDataUrlIsNullWhenNothingFitsOrNothingEncodes()
    {
        Assert.Null(await GroupPhoto.DataUrlAsync((_, _) => Task.FromResult<byte[]?>(new byte[30_000])));
        Assert.Null(await GroupPhoto.DataUrlAsync((_, _) => Task.FromResult<byte[]?>(null)));
        // The default limit is the mirror's (GroupLimits.syncImage).
        var url = await GroupPhoto.DataUrlAsync((side, _) => Task.FromResult<byte[]?>(side == 48 ? new byte[100] : new byte[20_000]));
        Assert.NotNull(url);
        Assert.True(url!.Length <= GroupLimits.SyncImage);
    }

    [Fact]
    public void TheDraftFollowsGroupNamePhotoModel()
    {
        var draft = new GroupNamePhotoDraft("Desk", null);
        Assert.False(draft.HasChanges);
        Assert.False(draft.ShowsRemove);
        Assert.Equal("Save", draft.SaveTitle);
        draft.Image = "data:image/jpeg;base64,AAAA";
        Assert.True(draft.ImageChanged);
        Assert.True(draft.ShowsRemove);
        Assert.True(draft.CanSave);
        draft.Image = null;   // Remove Photo on a room that had none: nothing to save
        Assert.False(draft.HasChanges);
        draft.Name = "  Desk  ";
        Assert.False(draft.NameChanged);   // the cleaned name is the same
        draft.Name = "   ";
        Assert.False(draft.NameChanged);   // an empty name is never a change
        draft.Name = "  Front Desk ";
        Assert.Equal("Front Desk", draft.CleanName);
        Assert.True(draft.NameChanged);
        draft.Saving = true;
        Assert.False(draft.CanSave);
        Assert.Equal("Saving…", draft.SaveTitle);

        var withPhoto = new GroupNamePhotoDraft("Desk", "data:image/jpeg;base64,AAAA");
        Assert.True(withPhoto.ShowsRemove);
        withPhoto.Image = null;
        Assert.True(withPhoto.ImageChanged);
        Assert.True(withPhoto.HasChanges);
    }

    private sealed class Writer(params string[] profiles) : IGroupMetaWriter
    {
        public readonly Dictionary<string, JsonObject> Metas = profiles.ToDictionary(p => p, _ => new JsonObject());
        public IReadOnlyList<string> ProfileNames => [.. Metas.Keys];
        public JsonObject CurrentMeta(string profile) => (JsonObject)Metas[profile].DeepClone();
        public Task WriteAsync(string profile, string failureTitle, Func<JsonObject, JsonObject?> patch)
        {
            if (patch(CurrentMeta(profile)) is { } p) foreach (var (k, v) in p) Metas[profile][k] = v?.DeepClone();
            return Task.CompletedTask;
        }
    }

    private sealed class Roster(Writer w) : IGroupRoster
    {
        public bool Loaded => true;
        public IReadOnlyList<GroupRosterProfile> Profiles => [.. w.ProfileNames.Select(p => new GroupRosterProfile(p) { Meta = w.CurrentMeta(p) })];
    }

    [Fact]
    public async Task SaveRenamesThenSetsThePhotoOnTheRoomsKeyAfterAndReachesTheMirror()
    {
        var w = new Writer("ivy", "juno");
        var store = new GroupStore { Roster = new Roster(w) };
        var mirrored = new List<string>();
        store.OnMirrorChange = mirrored.Add;
        var m = new GroupManager(store, w);
        // A room with no id: its rename gives it a new key, which the photo must follow.
        var key = await m.CreateAsync("Desk", ["ivy", "juno"]);
        store.Update(key, r => r.RoomId = null, sync: false);
        var oldKey = store.Rooms.Single().Key;
        mirrored.Clear();

        const string photo = "data:image/jpeg;base64,AAAA";
        await m.SaveNameAndPhotoAsync(oldKey, "Front Desk", imageChanged: true, photo);
        var room = store.Rooms.Single();
        Assert.Equal("Front Desk", room.Name);
        Assert.NotEqual(oldKey, room.Key);
        Assert.Equal(photo, room.Image);
        Assert.Contains(room.Key, mirrored);
        Assert.Equal(photo, store.Rows().Single().Image);

        // The photo alone, then cleared: Remove Photo saves a null image.
        mirrored.Clear();
        await m.SaveNameAndPhotoAsync(room.Key, null, imageChanged: true, null);
        Assert.Null(store.Rooms.Single().Image);
        Assert.Equal([room.Key], mirrored);

        // Nothing changed: nothing written.
        mirrored.Clear();
        await m.SaveNameAndPhotoAsync(room.Key, null, imageChanged: false, photo);
        Assert.Null(store.Rooms.Single().Image);
        Assert.Empty(mirrored);
    }

    [Fact]
    public async Task ATakenNameKeepsThePhotoUnsaved()
    {
        var w = new Writer("ivy", "juno");
        var store = new GroupStore { Roster = new Roster(w) };
        var m = new GroupManager(store, w);
        var key = await m.CreateAsync("Desk", ["ivy", "juno"]);
        await m.CreateAsync("Plans", ["ivy", "juno"]);
        await Assert.ThrowsAsync<GroupNameTakenException>(() => m.SaveNameAndPhotoAsync(key, "Plans", true, "data:image/jpeg;base64,AAAA"));
        Assert.Null(store.Room(key)!.Image);
    }

    [Fact]
    public void TheWalkChecksMemberFacesAndTheNameAndPhotoPage()
    {
        Assert.Null(GroupManageWalkProof.Faces([("ivy", true), ("research", true)]));
        Assert.Equal("research has no face beside it", GroupManageWalkProof.Faces([("ivy", true), ("research", false)]));
        Assert.Equal("the members are ivy", GroupManageWalkProof.Faces([("ivy", true)]));

        Assert.Null(GroupManageWalkProof.NamePhoto(GroupInfoWords.NameAndPhoto, GroupInfoWords.RenameIntro, GroupManageWalkProof.LaunchTitle,
            hasPhoto: false, ["Choose Photo"], saveEnabled: false));
        Assert.Null(GroupManageWalkProof.NamePhoto(GroupInfoWords.NameAndPhoto, GroupInfoWords.RenameIntro, GroupManageWalkProof.LaunchTitle,
            hasPhoto: true, ["Choose Photo", "Remove Photo"], saveEnabled: true));
        Assert.Equal("Remove Photo shows with no photo", GroupManageWalkProof.NamePhoto(GroupInfoWords.NameAndPhoto, GroupInfoWords.RenameIntro,
            GroupManageWalkProof.LaunchTitle, hasPhoto: false, ["Choose Photo", "Remove Photo"], saveEnabled: false));
        Assert.Equal("Save is on with nothing changed", GroupManageWalkProof.NamePhoto(GroupInfoWords.NameAndPhoto, GroupInfoWords.RenameIntro,
            GroupManageWalkProof.LaunchTitle, hasPhoto: false, ["Choose Photo"], saveEnabled: true));
        Assert.Equal("the page is titled Rename", GroupManageWalkProof.NamePhoto("Rename", GroupInfoWords.RenameIntro,
            GroupManageWalkProof.LaunchTitle, hasPhoto: false, ["Choose Photo"], saveEnabled: false));
    }
}
