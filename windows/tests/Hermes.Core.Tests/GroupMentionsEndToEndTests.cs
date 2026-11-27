using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Bots;
using Hermes.Core.Groups;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Shell;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-59] The group-mentions walk's path over a real wire, headless (Services/ProofWalks.GroupMentions.cs draws the
/// same): settings-gateway.py --group-rooms's Launch Room offers Research alone for "@Re", ↓ marks it, Return and Tab
/// each put "@research " in the box, Esc closes the list until the words change, and the line sent asks Research alone.
/// e2e.sh and windows.yml start that stand-in (HQW_E2E_GROUPMENTIONS_CREDENTIALS); without it this passes vacuously.
[Trait("Category", "E2E")]
public class GroupMentionsEndToEndTests
{
    private const string Key = GroupMentionsWalkProof.LaunchKey;

    [Fact]
    public async Task AtReOffersResearchAndTheLineAsksResearchAlone()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_GROUPMENTIONS_CREDENTIALS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(cred.Str("url")!), cred.Str("username")!, cred.Str("password")!);
        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(30)).Token);

        var gw = new ClientGateway(client);
        var bots = new BotStore(gw, new MemoryDeviceStore());
        await bots.RefreshAsync();
        var store = new GroupStore { Roster = new BotStoreGroupRoster(bots) };
        var sync = new GroupSync(store, gw);
        sync.Pulled(bots.DefaultProfileRow());
        sync.Shutdown();
        store.OnMirrorChange = null;
        Assert.NotNull(store.Room(Key));

        using var loop = new GroupLoop();
        var engine = await loop.Run(() => new GroupEngine(store, new ClientGroupGateway(client),
            new GroupTiming { Poll = TimeSpan.FromSeconds(2), Base = TimeSpan.FromSeconds(60), HardCap = TimeSpan.FromSeconds(120) }));
        var room = await loop.Run(() => GroupRoomSession.Open(Key, store, engine, "acct")!);
        try
        {
            await loop.Run(() => { GroupRoomChrome.Open(room); return true; });
            var choices = await loop.Run(() => room.MentionChoices);
            var list = new GroupMentionList();
            string text = "";
            var caret = 0;
            void Type(string words) { text += words; caret = text.Length; list.Update(text, text[..caret], choices); }
            void Pick(string? tag)
            {
                Assert.NotNull(tag);
                (text, caret) = GroupMentionList.Insert(text, caret, tag!, replacingQuery: true);
                list.Update(text, text[..caret], choices);
            }

            // "@Re": Research alone, with its face; ↓ marks it; Return picks it.
            Type(GroupMentionsWalkProof.Typed);
            Assert.Null(GroupMentionsWalkProof.Drawer(list.IsOpen, list.Rows, [.. list.Rows.Select(r => r.Sender?.Profile)]));
            list.Key(GroupMentionList.DrawerKey.Down);
            Assert.Null(GroupMentionsWalkProof.Marked(list.Marked, list.Rows, list.Marked));
            Pick(list.PickMarked());
            Assert.Null(GroupMentionsWalkProof.AfterPick(text, caret, list.IsOpen));

            // Again with Tab (nothing marked: the first row).
            text = "";
            Type(GroupMentionsWalkProof.Typed);
            Pick(list.Key(GroupMentionList.DrawerKey.Tab));
            Assert.Null(GroupMentionsWalkProof.AfterPick(text, caret, list.IsOpen));

            // Esc closes it with the words kept; the next letter opens it again.
            text = "";
            Type(GroupMentionsWalkProof.Typed);
            Assert.True(list.Escape(text));
            var closed = list.IsOpen;
            list.Update(text, text, choices);   // the same words: it stays closed
            closed |= list.IsOpen;
            var escText = text;
            Type("s");
            Assert.Null(GroupMentionsWalkProof.Escaped(escText, closed, list.IsOpen));

            // Picked, the rest typed and sent: Research alone is asked and answers.
            text = "";
            Type(GroupMentionsWalkProof.Typed);
            Pick(list.Key(GroupMentionList.DrawerKey.Tab));
            Type(GroupMentionsWalkProof.Rest);
            Assert.Equal(GroupMentionsWalkProof.Line, text);
            Assert.False(list.IsOpen);
            await loop.Run(() => { room.Send(text); return true; });
            List<(string?, string, string)> Rows()
            {
                var messages = room.Messages;
                return [.. messages.Select((m, i) => (GroupRoomChrome.ShowsSenderName(messages, i) ? m.Sender?.Name : null,
                    m.Role == Role.User ? "user" : m.Role == Role.Assistant ? "assistant" : "system", m.Text))];
            }
            List<(GroupActivityKind, string)> Since()
            {
                var all = store.Activity(Key).Select(a => (a.Kind, a.Member)).ToList();
                var queued = all.FindLastIndex(a => a.Kind == GroupActivityKind.Queued);
                return [.. all.Skip(Math.Max(0, queued))];
            }
            await loop.Until(() => GroupMentionsWalkProof.Addressed(Since(), Rows()) == null && !room.RoomRunning && !engine.IsDriving(Key), "Research's reply and the round's end", 60);
            Assert.Null(await loop.Run(() => GroupMentionsWalkProof.Addressed(Since(), Rows())));
        }
        finally
        {
            await loop.Run(() => { room.Dispose(); engine.Shutdown(); return true; });
        }
    }
}
