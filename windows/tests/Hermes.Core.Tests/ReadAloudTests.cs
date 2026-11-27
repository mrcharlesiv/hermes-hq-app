using Hermes.Core.Model;
using Hermes.Core.Shell;
using Hermes.Core.Transcripts;
using Hermes.Core.Voice;

namespace Hermes.Core.Tests;

/// SpeechText (HermesKit/Voice/SpeechText.swift): the vendor's vectors from Tests/Talk/TalkWordingTests.swift and
/// Tests/Talk/TalkSpeechFeedTests.swift at 93f984bb1, copied as they are.
public class SpeechTextTests
{
    [Fact]
    public void TheVendorsVectors()
    {
        (string Text, string Spoken)[] cases =
        [
            ("Here is code:\n```ts\nconst x = 1\n```\nDone.", "Here is code. Done."),
            ("Use `git status` after the change.", "Use git status after the change."),
            ("Here is the quick takeaway: the totals remain unchanged.\n\n| Item | Value | Notes |\n| --- | ---: | --- |\n| Example A | 10 | first row |\n| Example B | 20 | second row |\n\nFull detail stays visible on screen.",
             "Here is the quick takeaway: the totals remain unchanged. Item, Value, Notes. Full detail stays visible on screen."),
            ("Before the table.\n\n|   |   |\n| --- | --- |\n| a | b |\n\nAfter the table.", "Before the table. After the table."),
            ("Use the summary first | keep the table on screen when it matters.", "Use the summary first | keep the table on screen when it matters."),
            ("First sentence.\n\nSecond sentence.", "First sentence. Second sentence."),
            ("The files are below.\nMEDIA:/Users/me/Documents/inference-server-shopping-list.xlsx\nBye.", "The files are below. Bye."),
            ("See MEDIA:/tmp/report-2026-q3.xlsx. Then reply.", "See. Then reply."),
            ("See https://example.com/a-huge-page for details", "See for details"),
            ("This ~~is~~ old.", "This is old."),
            ("The file is below: MEDIA:/tmp/x.py", "The file is below."),
            ("The regex list:", "The regex list."),
            ("**First sentence.**\n\nSecond sentence.", "First sentence. Second sentence."),
            ("“First sentence.”\n\nSecond sentence.", "“First sentence.” Second sentence."),
            ("(First sentence.)\n\nSecond sentence.", "(First sentence.) Second sentence."),
            ("Main takeaway: total is unchanged.\n\nItem | Value\n--- | ---:\nExample A | 10\nExample B | 20\n\nDone.", "Main takeaway: total is unchanged. Item, Value. Done."),
            ("Before the table.\n\n> | Item | Value |\n> | --- | ---: |\n> | Example A | 10 |\n> | Example B | 20 |\n\nAfter the table.", "Before the table. Item, Value. After the table."),
            ("Before the table.\n\n| Item |\n| --- |\n| A |\n\nAfter the table.", "Before the table. Item. After the table."),
            ("Before the table.\n\n| Item \\| detail | Value |\n| --- | --- |\n| A | 1 |\n\nAfter the table.", "Before the table. Item detail, Value. After the table."),
            ("# Heading\n\n- one\n- two", "Heading. - one - two"),
            ("- one thing", "one thing"),
            ("[the docs](https://example.com/docs) say so", "the docs say so"),
            ("Done 🎉 and 👍🏽 ok", "Done and ok"),
        ];
        foreach (var (text, spoken) in cases) Assert.Equal(spoken, SpeechText.SanitizeForSpeech(text));
    }

    [Fact]
    public void NothingSpeakableGivesAnEmptyString()
    {
        foreach (var text in new[] { "```swift\nlet a = 1\n```", "🎉🎉", "https://example.com/page", "MEDIA:/tmp/a.png", "", "   \n ", "***", "> #" })
            Assert.Equal("", SpeechText.SanitizeForSpeech(text));
        Assert.Contains("Heading | Detail", SpeechText.SanitizeForSpeech("Heading | Detail\n--- | --- | ---\nA | B"));
        Assert.Contains("Item | Value", SpeechText.SanitizeForSpeech("    Item | Value\n    --- | ---"));
    }

    private const string Reply = "Run `npm install` to start the server. You can read [the docs](https://example.com/guide) for more detail.\n\n"
        + "Here is the command:\n\n```sh\nls -la. It lists every file! Even hidden ones.\n```\n\n"
        + "That lists every file. **Done** and dusted, with `one more` span to finish it.";

    [Fact]
    public void AWholeReplyIsCleanedWhole()
    {
        var sent = SpeechText.SanitizeForSpeech(Reply);
        Assert.DoesNotContain("`", sent);
        Assert.DoesNotContain("https", sent);
        Assert.DoesNotContain("ls -la", sent);
        // No full stop is left standing alone where the code block was.
        Assert.Contains("Here is the command. That lists every file.", sent);
        Assert.Equal("Wait... what? Yes. Done.", SpeechText.SanitizeForSpeech("Wait... what? Yes. Done."));
    }

    [Fact]
    public void CutSentencesAndSentenceBuffer()
    {
        var cut = SpeechText.CutSentences("This is the first full sentence. And then it keeps goi", flush: false);
        Assert.Equal(["This is the first full sentence."], cut.Sentences);
        Assert.Equal("And then it keeps goi", cut.Rest);
        cut = SpeechText.CutSentences("e.g. it continues", flush: false);
        Assert.Empty(cut.Sentences);
        Assert.Equal("e.g. it continues", cut.Rest);
        cut = SpeechText.CutSentences("First complete sentence right here. tail bit", flush: true);
        Assert.Equal(["First complete sentence right here.", "tail bit"], cut.Sentences);
        Assert.Equal("", cut.Rest);
        cut = SpeechText.CutSentences("这是一个完整的中文句子，它的长度足够超过最小句子门槛，所以会被切分出来。 下一句", flush: true);
        Assert.Equal(2, cut.Sentences.Count);
        Assert.Contains("。", cut.Sentences[0]);
        const string text = "记得，叫团团。 然后我们再说第二句话，这一句要长一些才行。 ";
        Assert.Equal(["记得，叫团团。 然后我们再说第二句话，这一句要长一些才行。"], SpeechText.CutSentences(text, flush: false).Sentences);
        Assert.Equal(["记得，叫团团。", "然后我们再说第二句话，这一句要长一些才行。"], SpeechText.CutSentences(text, flush: false, minimum: 6).Sentences);
        var buffer = new SentenceBuffer();
        Assert.Equal(["Wrap the plan in a <thinking> tag first."], buffer.Append("Wrap the plan in a <thinking> tag first. "));
        Assert.Equal(["Then the answer follows here in prose."], buffer.Append("Then the answer follows here in prose. And a tail"));
        Assert.Equal(["And a tail"], buffer.Flush());
        Assert.Empty(buffer.Flush());
    }

    [Fact]
    public void AnOpenCodeBlockIsHeld()
    {
        var (text, held) = SpeechText.WithoutCodeBlocks("Here is the start of it all. ```swift\nlet a = 1. let b = 2. ");
        Assert.Equal("Here is the start of it all. ", text);
        Assert.StartsWith("```swift", held);
        Assert.Equal(("a\nb", ""), SpeechText.WithoutCodeBlocks("a```x```b"));
    }
}

/// ReadAloudCenter (App/Chat/Voice/ReadAloudCenter.swift; Tests/Talk/ReadAloudTests.swift at 93f984bb1), with the
/// on-device voice faked.
public class ReadAloudCenterTests
{
    /// A voice that starts when told and ends when told (the Swift tests' FakeSpeaker).
    private sealed class FakeVoice : IReadAloudVoice
    {
        public readonly List<IReadOnlyList<string>> Spoken = [];
        public int Stops;
        private Action? _started;
        private TaskCompletionSource? _done;

        public Task SpeakAsync(IReadOnlyList<string> sentences, Action started, CancellationToken cancel)
        {
            Spoken.Add(sentences);
            _started = started;
            var done = _done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            cancel.Register(() => { Stops++; done.TrySetCanceled(); });
            return done.Task;
        }

        public void Begin() => _started?.Invoke();
        public void Complete() => _done?.TrySetResult();
        public void Fail(string reason) => _done?.TrySetException(new ReadAloudVoiceException(reason));
    }

    private static (ReadAloudCenter, FakeVoice, List<(string Scope, string Reason)>) Make()
    {
        var voice = new FakeVoice();
        var failures = new List<(string, string)>();
        var center = new ReadAloudCenter(voice) { OnFailure = (scope, reason) => { lock (failures) failures.Add((scope, reason)); } };
        return (center, voice, failures);
    }

    private static async Task<bool> WaitUntil(Func<bool> ok)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (DateTime.UtcNow < deadline) { if (ok()) return true; await Task.Delay(10); }
        return ok();
    }

    [Fact]
    public async Task AReplyIsPreparedSpokenAndDone()
    {
        var (center, voice, failures) = Make();
        Assert.Equal(ReadAloudState.Idle, center.State);
        Assert.Equal(ReadAloudButton.Idle, center.ButtonFor("m1"));
        center.Toggle("m1", "Here is **the plan**.", "chat");
        Assert.Equal(ReadAloudState.Preparing("m1"), center.State);
        Assert.Equal(ReadAloudButton.Preparing, center.ButtonFor("m1"));
        Assert.Equal(ReadAloudButton.Idle, center.ButtonFor("m2"));
        Assert.Equal("chat", center.Scope);
        // The cleaned reply, cut into sentences, handed over at once.
        Assert.Equal(["Here is the plan."], Assert.Single(voice.Spoken));
        voice.Begin();
        Assert.Equal(ReadAloudState.Speaking("m1"), center.State);
        Assert.Equal(ReadAloudButton.Speaking, center.ButtonFor("m1"));
        voice.Complete();
        Assert.True(await WaitUntil(() => center.State == ReadAloudState.Idle));
        Assert.Empty(failures);
    }

    [Fact]
    public async Task TappingTheSameReplyStopsAndAnotherReplyTakesOver()
    {
        var (center, voice, _) = Make();
        center.Toggle("m1", "One.", "chat");
        voice.Begin();
        // Another reply switches (T30): one voice at a time.
        center.Toggle("m2", "Two.", "chat");
        Assert.Equal(ReadAloudState.Preparing("m2"), center.State);
        Assert.Equal(2, voice.Spoken.Count);
        Assert.Equal(1, voice.Stops);
        Assert.Equal(ReadAloudButton.Idle, center.ButtonFor("m1"));
        voice.Begin();
        Assert.Equal(ReadAloudState.Speaking("m2"), center.State);
        // The same reply again stops.
        center.Toggle("m2", "Two.", "chat");
        Assert.Equal(ReadAloudState.Idle, center.State);
        Assert.Equal(2, voice.Stops);
        await Task.Delay(50);
        Assert.Equal(ReadAloudState.Idle, center.State);
    }

    [Fact]
    public void AReplyWithNothingToSaySaysSoAndReadRepliesAloudSkipsItQuietly()
    {
        var (center, voice, failures) = Make();
        center.Toggle("m1", "```swift\nlet a = 1\n```", "chat");
        Assert.Equal(ReadAloudState.Idle, center.State);
        Assert.Empty(voice.Spoken);
        Assert.Equal(["There’s nothing to read in this reply."], failures.Select(f => f.Reason));
        Assert.False(center.Read("m1", "   ", "chat", auto: true));
        Assert.Single(failures);
        Assert.Equal("Couldn’t Read Aloud", ReadAloudCenter.FailureTitle);
    }

    [Fact]
    public void AnUnreachableGatewaySaysSo()
    {
        var (center, voice, failures) = Make();
        center.Reachable = () => false;
        center.Toggle("m1", "Hello.", "chat");
        Assert.Empty(voice.Spoken);
        Assert.Equal(["The computer running Hermes isn’t reachable right now. Try again when it reconnects."], failures.Select(f => f.Reason));
        // Read Replies Aloud says nothing.
        Assert.False(center.Read("m1", "Hello.", "chat", auto: true));
        Assert.Single(failures);
    }

    [Fact]
    public async Task AFailureCarriesTheVoicesWordsAndNothingStaysOn()
    {
        var (center, voice, failures) = Make();
        center.Toggle("m1", "Hello.", "chat");
        voice.Fail("No voice is installed");
        Assert.True(await WaitUntil(() => failures.Count == 1));
        Assert.Equal(("chat", "No voice is installed"), failures[0]);
        Assert.Equal(ReadAloudState.Idle, center.State);
    }

    [Fact]
    public async Task NoAudioInTimeGivesUpWithItsOwnWords()
    {
        var (center, voice, failures) = Make();
        Assert.Equal(TimeSpan.FromSeconds(30), ReadAloudCenter.DefaultAnswerTimeout);
        center.AnswerTimeout = TimeSpan.FromMilliseconds(200);
        center.Toggle("m1", "Hello.", "chat");
        Assert.True(await WaitUntil(() => failures.Count == 1));
        Assert.Equal("The voice didn’t answer in time. Try again.", failures[0].Reason);
        Assert.Equal(ReadAloudState.Idle, center.State);
        Assert.Equal(1, voice.Stops);
        // Audio that began in time is never cut off by the timer.
        center.Toggle("m2", "Hello again.", "chat");
        voice.Begin();
        await Task.Delay(400);
        Assert.Equal(ReadAloudState.Speaking("m2"), center.State);
        Assert.Single(failures);
        center.Stop();
    }

    [Fact]
    public void LeavingTheChatStopsOnlyItsOwnReading()
    {
        var (center, _, _) = Make();
        center.Read("m1", "Hello.", "chat", auto: true);
        center.Stop("another chat");
        Assert.Equal(ReadAloudState.Preparing("m1"), center.State);
        center.Stop("chat");
        Assert.Equal(ReadAloudState.Idle, center.State);
    }

    [Fact]
    public void AReplyThatTakesItsStoredIdKeepsItsReading()
    {
        var (center, voice, _) = Make();
        center.Read("local-assistant-3", "Hello there.", "chat", auto: true);
        voice.Begin();
        center.Rebind("another chat", "local-assistant-3", "stored-row-26-assistant");
        Assert.Equal(ReadAloudState.Speaking("local-assistant-3"), center.State);
        center.Rebind("chat", "local-assistant-3", "stored-row-26-assistant");
        Assert.Equal(ReadAloudState.Speaking("stored-row-26-assistant"), center.State);
        Assert.True(center.IsReading("stored-row-26-assistant"));
        // The menu's Stop Reading on the stored row stops it.
        center.Toggle("stored-row-26-assistant", "Hello there.", "chat");
        Assert.Equal(ReadAloudState.Idle, center.State);
        Assert.Single(voice.Spoken);
    }

    [Fact]
    public void TheButtonsThreeNamesAndTheMenusRow()
    {
        Assert.Equal("Read Aloud", ReadAloudButton.Idle.Label());
        Assert.Equal("Preparing audio", ReadAloudButton.Preparing.Label());
        Assert.Equal("Stop reading", ReadAloudButton.Speaking.Label());
        // The hold menu's tile sits between Copy and Share (MessageMenuModel.tiles).
        Assert.Equal([MessageMenuItem.Copy, MessageMenuItem.Share], MessageMenu.Tiles(true, new MessageMenuContext()).Select(t => t.Id));
        var tiles = MessageMenu.Tiles(true, new MessageMenuContext(Reading: false));
        Assert.Equal([MessageMenuItem.Copy, MessageMenuItem.ReadAloud, MessageMenuItem.Share], tiles.Select(t => t.Id));
        Assert.Equal("Read Aloud", tiles[1].Title);
        Assert.Equal("Stop Reading", MessageMenu.Tiles(true, new MessageMenuContext(Reading: true))[1].Title);
        var streaming = MessageMenu.Tiles(true, new MessageMenuContext(Reading: false, Streaming: true))[1];
        Assert.True(streaming.Disabled);
        Assert.Equal("Still Replying", streaming.Subtitle);
        Assert.DoesNotContain(MessageMenu.Tiles(false, new MessageMenuContext(Reading: false)), t => t.Id == MessageMenuItem.ReadAloud);
    }
}

/// Read Replies Aloud on one chat screen (App/Chat/Voice/ChatReadAloudHost.swift sessionChanged / readNext /
/// inputEnded at 93f984bb1).
public class ReadRepliesWatchTests
{
    private static ChatMessage Reply(string id, string text, bool streaming = false) =>
        new(id, Role.Assistant, [new TextPart(text)], IsStreaming: streaming);

    private static ChatMessage You(string id, string text) => new(id, Role.User, [new TextPart(text)]);

    [Fact]
    public void TheSpokenWordsOfAReplyAreItsTextPartsAndOnlyTheNewestCounts()
    {
        var reply = new ChatMessage("r1", Role.Assistant, [new TextPart("One."), new ReasoningPart("hidden"), new TextPart(""), new TextPart("Two.")]);
        Assert.Equal(new SpokenReply("r1", "One.\n\nTwo.", false), SpokenReply.Of(reply));
        Assert.Null(SpokenReply.Newest([reply, You("u1", "hi")]));
        Assert.Equal("r1", SpokenReply.Newest([You("u1", "hi"), reply])?.MessageId);
        Assert.True(SpokenReply.Newest([Reply("r2", "x", streaming: true)])!.Pending);
    }

    [Fact]
    public void HistoryOnShowIsNeverReadAndAReplyThatCompletesInFrontOfThePersonIs()
    {
        var watch = new ReadRepliesWatch();
        // The chat opens with history: its newest reply counts as heard.
        watch.Appeared([You("u1", "hi"), Reply("r1", "Old.")], running: false);
        Assert.Null(watch.SessionChanged([You("u1", "hi"), Reply("r1", "Old.")], running: false, switchOn: true, readingHere: false));
        // History arriving after the chat opened is not a reply completing either (no turn was seen running).
        Assert.Null(watch.SessionChanged([You("u1", "hi"), Reply("r1", "Old."), Reply("r9", "Older page.")], running: false, switchOn: true, readingHere: false));
        // A turn runs and its reply completes: read.
        Assert.Null(watch.SessionChanged([You("u2", "more"), Reply("r2", "New", streaming: true)], running: true, switchOn: true, readingHere: false));
        Assert.Equal("r2", watch.SessionChanged([You("u2", "more"), Reply("r2", "New.")], running: false, switchOn: true, readingHere: false));
        // Only once.
        Assert.Null(watch.SessionChanged([You("u2", "more"), Reply("r2", "New.")], running: false, switchOn: true, readingHere: false));
    }

    [Fact]
    public void TheSwitchOffReadsNothingAndTheReplyCountsAsHeard()
    {
        var watch = new ReadRepliesWatch();
        watch.Appeared([], running: false);
        watch.SessionChanged([Reply("r1", "x", streaming: true)], running: true, switchOn: false, readingHere: false);
        Assert.Null(watch.SessionChanged([Reply("r1", "Done.")], running: false, switchOn: false, readingHere: false));
        Assert.Null(watch.SessionChanged([Reply("r1", "Done.")], running: false, switchOn: true, readingHere: false));
        Assert.True(ReadRepliesWatch.ReadsCompletedReply(switchOn: true, voiceNotice: false));
        Assert.False(ReadRepliesWatch.ReadsCompletedReply(switchOn: true, voiceNotice: true));
        Assert.False(ReadRepliesWatch.ReadsCompletedReply(switchOn: false, voiceNotice: false));
    }

    [Fact]
    public void WhileAReplyIsReadOnlyTheNewestWaitsAndASendDropsIt()
    {
        var watch = new ReadRepliesWatch();
        watch.Appeared([], running: false);
        watch.SessionChanged([Reply("r1", "x", streaming: true)], running: true, switchOn: true, readingHere: false);
        Assert.Null(watch.SessionChanged([Reply("r1", "Done.")], running: false, switchOn: true, readingHere: true));
        // The reading ended: the reply that waited is read if it is still the newest.
        Assert.Equal("r1", watch.ReadingEnded([Reply("r1", "Done.")], switchOn: true));
        Assert.Null(watch.ReadingEnded([Reply("r1", "Done.")], switchOn: true));
        // A message sent from the chat drops the waiting reply.
        watch.SessionChanged([Reply("r2", "x", streaming: true)], running: true, switchOn: true, readingHere: true);
        watch.SessionChanged([Reply("r2", "Two.")], running: false, switchOn: true, readingHere: true);
        watch.MessageSent();
        Assert.Null(watch.ReadingEnded([Reply("r2", "Two.")], switchOn: true));
        // Leaving the chat drops it too, and nothing is read off screen.
        watch.SessionChanged([Reply("r3", "x", streaming: true)], running: true, switchOn: true, readingHere: true);
        watch.SessionChanged([Reply("r3", "Three.")], running: false, switchOn: true, readingHere: true);
        watch.Left();
        Assert.Null(watch.ReadingEnded([Reply("r3", "Three.")], switchOn: true));
        Assert.Null(watch.SessionChanged([Reply("r4", "x", streaming: true)], running: true, switchOn: true, readingHere: false));
    }

    [Fact]
    public void TurningTheSwitchOnMarksTheNewestReplyHeard()
    {
        var watch = new ReadRepliesWatch();
        watch.Appeared([], running: false);
        watch.SessionChanged([Reply("r1", "x", streaming: true)], running: true, switchOn: false, readingHere: false);
        watch.SwitchChanged(on: true, [Reply("r1", "Done.")], running: false);
        Assert.Null(watch.SessionChanged([Reply("r1", "Done.")], running: false, switchOn: true, readingHere: false));
    }
}

/// [WIN-54] The read-aloud walk's checks (Hermes.Core.Shell.ReadAloudWalkProof).
public class ReadAloudWalkProofTests
{
    [Fact]
    public void TheMenuReadsReadAloudBetweenCopyAndShareThenStopReading()
    {
        Assert.Null(ReadAloudWalkProof.MenuReads([("Copy", true), ("Read Aloud", true), ("Share…", true), ("Select Text", true)], reading: false));
        Assert.Equal("the reply's menu has no Read Aloud", ReadAloudWalkProof.MenuReads([("Copy", true), ("Share…", true)], reading: false));
        Assert.Equal("the reply's menu reads Copy, Share…, Read Aloud, not Copy, Read Aloud, Share…",
            ReadAloudWalkProof.MenuReads([("Copy", true), ("Share…", true), ("Read Aloud", true)], reading: false));
        Assert.Equal("Read Aloud is dimmed on a settled reply", ReadAloudWalkProof.MenuReads([("Copy", true), ("Read Aloud", false), ("Share…", true)], reading: false));
        Assert.Null(ReadAloudWalkProof.MenuReads([("Copy", true), ("Stop Reading", true), ("Share…", true)], reading: true));
        Assert.Equal("the reply's menu has no Stop Reading", ReadAloudWalkProof.MenuReads([("Copy", true), ("Read Aloud", true), ("Share…", true)], reading: true));
        Assert.Null(ReadAloudWalkProof.Stopped("idle", 1));
        Assert.Equal("the reading is still speaking after Stop Reading", ReadAloudWalkProof.Stopped("speaking", 1));
        Assert.Equal("the voice was stopped 0 times, not once", ReadAloudWalkProof.Stopped("idle", 0));
    }
}
