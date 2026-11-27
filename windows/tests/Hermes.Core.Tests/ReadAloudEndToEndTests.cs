using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Shell;
using Hermes.Core.Voice;

namespace Hermes.Core.Tests;

/// [WIN-54] Read Aloud and Read Replies Aloud through Hermes.Core against the composer stand-in: Trip planning's history
/// is never read on show, Read Aloud on its latest reply hands the voice that reply's cleaned words, and a reply that
/// completes after a send in the bot's own chat is the one Read Replies Aloud reads (once). Run through
/// windows/scripts/e2e.sh; without the credentials it passes vacuously.
[Collection(ComposerStandIn.Name)]
[Trait("Category", "E2E")]
public class ReadAloudEndToEndTests
{
    private sealed class FakeVoice : IReadAloudVoice
    {
        public readonly List<IReadOnlyList<string>> Spoken = [];
        public Task SpeakAsync(IReadOnlyList<string> sentences, Action started, CancellationToken cancel)
        {
            lock (Spoken) Spoken.Add(sentences);
            started();
            return Task.Delay(Timeout.Infinite, cancel);
        }
    }

    private static async Task Until(Func<bool> condition, int seconds = 20)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (!condition())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException("condition not met");
            await Task.Delay(50);
        }
    }

    [Fact]
    public async Task HistoryIsNeverReadReadAloudSaysTheReplyAndANewReplyIsReadOnce()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_COMPOSER_CREDENTIALS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(cred.Str("url")!),
            cred.Str("username")!, cred.Str("password")!);
        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        var voice = new FakeVoice();
        var failures = new List<string>();
        var center = new ReadAloudCenter(voice) { OnFailure = (_, reason) => failures.Add(reason) };

        await using (var trip = client.OpenChat(ChatActionsProof.TripBot, ChatActionsProof.TripStoredId, ChatActionsProof.TripTitle))
        {
            var watch = new ReadRepliesWatch();
            watch.Appeared(trip.Messages, trip.Busy);
            await trip.OpenAsync();
            await Until(() => trip.Messages.Count >= 4);
            // The history arriving is not a reply completing in front of the person.
            Assert.Null(watch.SessionChanged(trip.Messages, trip.Busy, switchOn: true, readingHere: false));
            // Read Aloud on the latest reply: its words, cleaned for a voice, in sentences.
            var reply = SpokenReply.Newest(trip.Messages)!;
            center.Toggle(reply.MessageId, reply.Text, "trip");
            Assert.Equal(ReadAloudState.Speaking(reply.MessageId), center.State);
            var said = string.Join(" ", Assert.Single(voice.Spoken));
            Assert.Equal(SpeechText.SanitizeForSpeech(reply.Text), said);
            Assert.NotEmpty(said);
            Assert.DoesNotContain("**", said);
            center.Stop("trip");
            Assert.Equal(ReadAloudState.Idle, center.State);
        }

        // Read Replies Aloud in the bot's own chat: the reply to a send, read once it completes.
        var bot = (await client.BotsAsync()).First(b => b.Name == "default");
        await using var chat = client.OpenChat(bot.Name, await client.BotChatIdAsync(bot), bot.DisplayName);
        var replies = new ReadRepliesWatch();
        var read = new List<string>();
        replies.Appeared(chat.Messages, chat.Busy);
        void Changed()
        {
            lock (read)
            {
                var messages = chat.Messages;
                if (replies.SessionChanged(messages, chat.Busy, switchOn: true, readingHere: false) is { } id)
                    read.Add(SpokenReply.Of(messages.Last(m => m.Id == id)).Text);
            }
        }
        chat.Changed += Changed;
        await chat.OpenAsync();
        // The shared stand-in may still be finishing an earlier test's turn in this chat; a turn seen running that
        // completes on screen is read on the Mac too (ChatReadAloudHost.screenAppeared sets sawRunning). Only the reply
        // to this send is checked.
        await Until(() => !chat.Busy);
        await Task.Delay(500);
        lock (read) read.Clear();
        Assert.Equal(SendOutcome.Accepted, await chat.SendAsync("Read this back"));
        await Until(() => !chat.Busy && chat.Messages.LastOrDefault() is { Role: Role.Assistant, IsStreaming: false });
        Changed();
        await Until(() => { lock (read) return read.Count > 0; });
        chat.Changed -= Changed;
        Changed();
        // Read once, with the reply's words, though the stored row takes the live reply's place under another id.
        lock (read) Assert.Equal([SpokenReply.Of(chat.Messages.Last()).Text], read);
        Assert.Empty(failures);
    }
}
