using Hermes.Core.Groups;
using Hermes.Core.Model;
using Hermes.Core.Transcripts;
using Hermes.Core.Voice;
using Xunit;

namespace Hermes.Core.Tests;

/// The voice-memo text format (HermesKit/Voice/MemoText.swift and Tests/Voice/MemoPolicyTextTests.swift "Memo text
/// (A-U3)" at 93f984bb1): building the stored, prompt and optimistic text, parsing it back, the bubble/copy/line words,
/// and the Find and Groups routes that read it. Expected strings were checked against the Mac parser itself (a swiftc
/// probe of MemoText.swift at 93f984bb1). Invented paths and words only; nothing is read, recorded, copied or sent.
public class VoiceMemoTextTests
{
    private const string Gateway = "/Users/me/.hermes/profiles/ivy/attachments/voice-memo-2.m4a";
    private static VoiceMemo P(string text) => VoiceMemo.Parse(text) ?? throw new Xunit.Sdk.XunitException($"not a memo: {text}");

    [Fact]
    public void StoredRoundTrip()
    {
        var text = MemoText.Reference(Gateway, MemoSaid.Words("Pick up milk on the way home."));
        Assert.Equal($"MEDIA:\"{Gateway}\"\n\nVoice memo transcript: Pick up milk on the way home.", text);
        var memo = P(text);
        Assert.Equal(Gateway, memo.Path);
        Assert.Equal(MemoTranscript.Words("Pick up milk on the way home."), memo.Transcript);
        Assert.Equal("", memo.Rest);
        Assert.Equal("Voice Memo", memo.Title);
        // Words are trimmed going in.
        Assert.Equal("MEDIA:\"/a/voice-memo.m4a\"\n\nVoice memo transcript: Hi", MemoText.Reference("/a/voice-memo.m4a", MemoSaid.Words("  Hi\n ")));
    }

    [Fact]
    public void OptimisticFailedOffEmptyAndTyped()
    {
        const string local = @"C:\Users\me\AppData\Local\HermesHQ\memos\abc\1\voice-memo.m4a";
        Assert.Equal($"MEDIA:\"{local}\"", MemoText.Optimistic(local, ""));
        var optimistic = P(MemoText.Optimistic(local, ""));
        Assert.Equal(local, optimistic.Path);
        Assert.Equal(MemoTranscript.Pending, optimistic.Transcript);
        Assert.Equal("MEDIA:\"/l/voice-memo.m4a\"\n\nand", MemoText.Optimistic("/l/voice-memo.m4a", " \n and \n"));
        Assert.Equal("and this", P(MemoText.Optimistic(local, "  and this  ")).Rest);

        Assert.Equal($"MEDIA:\"{Gateway}\"\n\nVoice memo transcript: (unavailable)", MemoText.Reference(Gateway, MemoSaid.Failed));
        Assert.Equal($"MEDIA:\"{Gateway}\"\n\nVoice memo transcript: (unavailable: speech-to-text is off on the gateway)",
            MemoText.Reference(Gateway, MemoSaid.Off));
        Assert.Equal(MemoTranscript.Failed, P(MemoText.Reference(Gateway, MemoSaid.Failed)).Transcript);
        Assert.Equal(MemoTranscript.Off, P(MemoText.Reference(Gateway, MemoSaid.Off)).Transcript);
        var empty = MemoText.Reference(Gateway, MemoSaid.Empty);
        Assert.Equal($"MEDIA:\"{Gateway}\"\n\nVoice memo transcript: (No speech detected)", empty);
        Assert.Equal(MemoTranscript.Words("(No speech detected)"), P(empty).Transcript);
        Assert.EndsWith("(No speech detected)", MemoText.Reference(Gateway, MemoSaid.Words("   ")), StringComparison.Ordinal);

        var withText = MemoText.Prompt(MemoText.Reference(Gateway, MemoSaid.Words("Hello.")), "See you at six\n");
        Assert.Equal($"MEDIA:\"{Gateway}\"\n\nVoice memo transcript: Hello.\n\nSee you at six", withText);
        var both = P(withText);
        Assert.Equal(MemoTranscript.Words("Hello."), both.Transcript);
        Assert.Equal("See you at six", both.Rest);
        Assert.Equal("R", MemoText.Prompt("R", ""));
        Assert.Equal("R", MemoText.Prompt("R", " \n\t"));
    }

    [Fact]
    public void MissingTranscriptsAreNotReused()
    {
        Assert.True(MemoText.TranscriptMissing(MemoText.Reference(Gateway, MemoSaid.Off)));
        Assert.True(MemoText.TranscriptMissing(MemoText.Reference(Gateway, MemoSaid.Failed)));
        Assert.False(MemoText.TranscriptMissing(MemoText.Reference(Gateway, MemoSaid.Words("Hi"))));
        Assert.False(MemoText.TranscriptMissing(MemoText.Reference(Gateway, MemoSaid.Empty)));
        // Only a bare reference: once something is typed after it, it no longer ends with the marker.
        Assert.False(MemoText.TranscriptMissing(MemoText.Reference(Gateway, MemoSaid.Off) + "\n\ntyped"));
    }

    [Fact]
    public void GatewayMemoPathAcceptsWindowsAndPosixOnly()
    {
        Assert.Equal("/a/voice-memo.m4a", MemoText.GatewayMemoPath("/a/voice-memo.m4a"));
        Assert.Equal(@"C:\x\voice-memo.wav", MemoText.GatewayMemoPath(@"C:\x\voice-memo.wav"));
        Assert.Equal("C:/x/voice-memo.wav", MemoText.GatewayMemoPath("C:/x/voice-memo.wav"));
        Assert.Equal("c:/x.ogg", MemoText.GatewayMemoPath("c:/x.ogg"));
        Assert.Equal("/a/b.OPUS", MemoText.GatewayMemoPath("/a/b.OPUS"));
        Assert.Equal("/a/.m4a", MemoText.GatewayMemoPath("/a/.m4a"));
        Assert.Null(MemoText.GatewayMemoPath("/a/voi\"ce.m4a"));          // a quote
        Assert.Null(MemoText.GatewayMemoPath("/a/voice\nmemo.m4a"));      // a newline
        Assert.Null(MemoText.GatewayMemoPath("/a/b.m4a\r"));              // a carriage return
        Assert.Null(MemoText.GatewayMemoPath("a/voice-memo.m4a"));        // relative
        Assert.Null(MemoText.GatewayMemoPath(@"/a\b/voice-memo.m4a"));    // a backslash in a POSIX path
        Assert.Null(MemoText.GatewayMemoPath("/a/notes.txt"));            // not audio
        Assert.Null(MemoText.GatewayMemoPath("/a/b.weba"));
        Assert.Null(MemoText.GatewayMemoPath("/a/voice-memo.m4a.txt"));
        Assert.Null(MemoText.GatewayMemoPath("1:/x.ogg"));                // not a drive letter
        Assert.Null(MemoText.GatewayMemoPath("C:voice.m4a"));             // drive-relative
        Assert.Null(MemoText.GatewayMemoPath(@"\\server\share\voice-memo.wav")); // UNC
        Assert.Null(MemoText.GatewayMemoPath(""));
        Assert.Null(MemoText.GatewayMemoPath(null));
        // A malformed path is not a memo at all: the message stays ordinary text.
        Assert.Null(VoiceMemo.Parse("MEDIA:\"a/voice-memo.m4a\"\n\nVoice memo transcript: Hi"));
        Assert.Null(VoiceMemo.Parse("MEDIA:\"/a\\b/voice-memo.m4a\""));
        Assert.Null(VoiceMemo.Parse("MEDIA:\"c:x/voice-memo.wav\""));
        Assert.Null(VoiceMemo.Parse("MEDIA:\"/a/notes.txt\"\n\nVoice memo transcript: Hi"));
        Assert.Null(VoiceMemo.Parse("MEDIA: \"/a/voice-memo.m4a\""));
        Assert.Null(VoiceMemo.Parse("MEDIA:\"/a/voice-memo.m4a\" trailing"));
        Assert.Null(VoiceMemo.Parse("Look: MEDIA:\"/a/voice-memo.m4a\""));
        Assert.Null(VoiceMemo.Parse("plain words"));
        Assert.Null(VoiceMemo.Parse(null));
    }

    [Fact]
    public void RecordedAndOtherAudioTitles()
    {
        Assert.Equal("Voice Memo", P("MEDIA:\"/a/voice-memo.m4a\"").Title);
        Assert.Equal("Voice Memo", P("MEDIA:\"/a/voice-memo-12.WAV\"").Title);
        Assert.Equal("Voice Memo", P("MEDIA:\"C:/x/Voice-Memo-3.ogg\"").Title);
        Assert.Equal("voice-memo-x.wav", P("MEDIA:\"/a/voice-memo-x.wav\"").Title);
        Assert.Equal("Otter Song.MP3", P("  MEDIA:\"/a/Otter Song.MP3\"").Title);
        Assert.Equal("otter.wav", P("MEDIA:\"C:/x/otter.wav\"").Title);
        // Windows reads a backslash drive path's file name (the Mac's NSString keeps the whole path here).
        Assert.Equal("otter.wav", P("MEDIA:\"C:\\x\\otter.wav\"").Title);
        Assert.Equal("Voice Memo", P("MEDIA:\"C:\\x\\voice-memo.wav\"").Title);
        Assert.True(VoiceMemo.IsRecordedMemoName("voice-memo.flac"));
        Assert.False(VoiceMemo.IsRecordedMemoName("my-voice-memo.m4a"));
        Assert.False(VoiceMemo.IsRecordedMemoName("voice-memo-.m4a"));
    }

    /// Every transcript state: the parsed kind, the bubble's words, the plain-text line and what Copy takes.
    [Theory]
    // text, then typed text on the next bubble
    [InlineData("MEDIA:\"/a/voice-memo.m4a\"\n\nVoice memo transcript: Hi\n\ntyped", "Text", "Hi", "typed",
        "Hi", "Voice Memo: Hi\ntyped", "Hi\n\ntyped")]
    // a multi-line rest keeps its own breaks
    [InlineData("MEDIA:\"/a/voice-memo.m4a\"\n\nVoice memo transcript: Hi\nsecond\n\nthird", "Text", "Hi", "second\n\nthird",
        "Hi", "Voice Memo: Hi\nsecond\n\nthird", "Hi\n\nsecond\n\nthird")]
    // no speech is words, unlike no transcript
    [InlineData("MEDIA:\"/a/voice-memo.m4a\"\n\nVoice memo transcript: (No speech detected)", "Text", "(No speech detected)", "",
        "(No speech detected)", "Voice Memo: (No speech detected)", "(No speech detected)")]
    // off, with typed text
    [InlineData("MEDIA:\"/a/voice-memo.m4a\"\n\nVoice memo transcript: (unavailable: speech-to-text is off on the gateway)\n\nok", "Off", "", "ok",
        "No transcript: speech-to-text is off on your gateway.", "Voice Memo: (no transcript)\nok", "ok")]
    // off, alone: Copy takes the line
    [InlineData("MEDIA:\"/a/voice-memo.m4a\"\n\nVoice memo transcript: (unavailable: speech-to-text is off on the gateway)", "Off", "", "",
        "No transcript: speech-to-text is off on your gateway.", "Voice Memo: (no transcript)", "Voice Memo: (no transcript)")]
    // failed, padded, after a whitespace-only line
    [InlineData("MEDIA:\"/a/voice-memo.m4a\"\n \t\n\nVoice memo transcript:   (unavailable)  \n\ntyped", "Failed", "", "typed",
        "No transcript", "Voice Memo: (no transcript)\ntyped", "typed")]
    // an empty transcript line is still pending
    [InlineData("MEDIA:\"/a/voice-memo.m4a\"\n\nVoice memo transcript: ", "Pending", "", "",
        "No transcript", "Voice Memo: (no transcript)", "Voice Memo: (no transcript)")]
    // no transcript line at all: everything after is typed text
    [InlineData("MEDIA:\"/a/voice-memo.m4a\"\n\ntyped only", "Pending", "", "typed only",
        "No transcript", "Voice Memo: (no transcript)\ntyped only", "typed only")]
    // another audio file's name is the title
    [InlineData("  MEDIA:\"/a/Otter Song.MP3\"", "Pending", "", "",
        "No transcript", "Otter Song.MP3: (no transcript)", "Otter Song.MP3: (no transcript)")]
    // the transcript words lose Unicode spaces (Foundation's .whitespaces)
    [InlineData("MEDIA:\"/a/voice-memo.m4a\"\n\nVoice memo transcript: \u00A0Hi\u3000", "Text", "Hi", "",
        "Hi", "Voice Memo: Hi", "Hi")]
    // a lower-case or indented marker, or one with no space, is typed text
    [InlineData("MEDIA:\"/a/voice-memo.m4a\"\n\nvoice memo transcript: Hi", "Pending", "", "voice memo transcript: Hi",
        "No transcript", "Voice Memo: (no transcript)\nvoice memo transcript: Hi", "voice memo transcript: Hi")]
    [InlineData("MEDIA:\"/a/voice-memo.m4a\"\n\n  Voice memo transcript: Hi", "Pending", "", "Voice memo transcript: Hi",
        "No transcript", "Voice Memo: (no transcript)\nVoice memo transcript: Hi", "Voice memo transcript: Hi")]
    [InlineData("MEDIA:\"/a/voice-memo.m4a\"\n\nVoice memo transcript:Hi", "Pending", "", "Voice memo transcript:Hi",
        "No transcript", "Voice Memo: (no transcript)\nVoice memo transcript:Hi", "Voice memo transcript:Hi")]
    // the directive may end the text with one line terminator (NSRegularExpression's `$`)
    [InlineData("MEDIA:\"/a/voice-memo.m4a\"\r", "Pending", "", "", "No transcript", "Voice Memo: (no transcript)", "Voice Memo: (no transcript)")]
    [InlineData("MEDIA:\"/a/voice-memo.m4a\"\u2028", "Pending", "", "", "No transcript", "Voice Memo: (no transcript)", "Voice Memo: (no transcript)")]
    [InlineData("MEDIA:\"/a/voice-memo.m4a\" \t\n", "Pending", "", "", "No transcript", "Voice Memo: (no transcript)", "Voice Memo: (no transcript)")]
    [InlineData("\u00A0\nMEDIA:\"/a/voice-memo.m4a\"", "Pending", "", "", "No transcript", "Voice Memo: (no transcript)", "Voice Memo: (no transcript)")]
    public void TranscriptStatesReadAsTheMacDoes(string text, string kind, string words, string rest, string shown, string line, string copy)
    {
        var memo = P(text);
        Assert.Equal(Enum.Parse<MemoTranscriptKind>(kind), memo.Transcript.Kind);
        Assert.Equal(words, memo.Transcript.Text);
        Assert.Equal(rest, memo.Rest);
        Assert.Equal(shown, memo.TranscriptText);
        Assert.Equal(line, memo.TranscriptLine);
        Assert.Equal(copy, memo.CopyText);
    }

    [Fact]
    public void LineTerminatorMidTextIsNotADirectiveEnd()
    {
        Assert.Null(VoiceMemo.Parse("MEDIA:\"/a/voice-memo.m4a\"\u2028Voice memo transcript: Hi"));
        Assert.Null(VoiceMemo.Parse("MEDIA:\"/a/voice-memo.m4a\"\rVoice memo transcript: Hi"));
    }

    /// The bubble's words for every transcript state (spec §4.5, §5; MemoBubbleInfo.make(…).wordsText).
    [Fact]
    public void BubbleWords()
    {
        var stored = P(MemoText.Reference(Gateway, MemoSaid.Off));
        Assert.Equal("No transcript: speech-to-text is off on your gateway.", MemoText.BubbleWords(stored, pending: false, failed: false));
        var pending = P($"MEDIA:\"{Gateway}\"");
        Assert.Equal("Transcribing…", MemoText.BubbleWords(pending, pending: true, failed: false));
        Assert.Equal("No transcript", MemoText.BubbleWords(pending, pending: false, failed: false));
        Assert.Equal("Transcription unavailable. Check the memo’s delivery status.", MemoText.BubbleWords(pending, pending: true, failed: true));
        var failed = P(MemoText.Reference(Gateway, MemoSaid.Failed));
        Assert.Equal("No transcript", MemoText.BubbleWords(failed, pending: false, failed: false));
        Assert.Equal("No transcript", MemoText.BubbleWords(failed, pending: true, failed: true));
        var said = P(MemoText.Reference(Gateway, MemoSaid.Words("Ship it")));
        Assert.Equal("Ship it", MemoText.BubbleWords(said, pending: true, failed: true));
    }

    // ── The existing routes, fed synthetic strings ──

    private static ChatMessage User(string id, string text) => new(id, Role.User, [new TextPart(text)]);

    [Theory]
    [InlineData("MEDIA:\"/a/voice-memo.m4a\"\n\nVoice memo transcript: an otter\n\nand an otter typed", "and an otter typed")]
    [InlineData("MEDIA:\"C:\\x\\voice-memo.wav\"\n\nVoice memo transcript: (unavailable)\n\nlater", "later")]
    [InlineData("MEDIA:\"/a/voice-memo.m4a\"\n\nVoice memo transcript: \u00A0otter\u3000", "")]
    [InlineData("MEDIA:\"/a/voice-memo.m4a\"\r", "")]
    [InlineData("MEDIA:\"/a/voice-memo.m4a\"\u2028", "")]
    public void FindSearchesOnlyWhatWasTypedWithAMemo(string text, string rest)
    {
        Assert.Equal(rest, ChatFind.VoiceMemoRest(text));
        var units = ChatFind.Units([User("u1", text)]);
        if (rest.Length == 0) Assert.Empty(units);
        else Assert.Equal([("u1|b1", rest)], units.Select(u => (u.RowId, u.Text)));
    }

    [Theory]
    [InlineData("MEDIA:\"a/voice-memo.m4a\"\n\nVoice memo transcript: otter")]   // relative: ordinary text
    [InlineData("MEDIA:\"/a\\b/voice-memo.m4a\"\n\nVoice memo transcript: otter")]
    [InlineData("MEDIA:\"/a/otter.txt\"\n\nVoice memo transcript: otter")]
    public void FindSearchesAMalformedMemoAsTypedText(string text)
    {
        Assert.Null(ChatFind.VoiceMemoRest(text));
        Assert.Equal([("u1|b0", text)], ChatFind.Units([User("u1", text)]).Select(u => (u.RowId, u.Text)));
    }

    [Theory]
    [InlineData("MEDIA:\"/a/voice-memo.m4a\"\n\nVoice memo transcript: Call me back", "You: Voice Memo: Call me back",
        "Owner (user): Voice Memo: Call me back")]
    [InlineData("MEDIA:\"/a/voice-memo.m4a\"\n\nVoice memo transcript: (No speech detected)\n\nsee notes", "You: Voice Memo: (No speech detected) see notes",
        "Owner (user): Voice Memo: (No speech detected)\nsee notes")]
    [InlineData("MEDIA:\"/a/voice-memo.m4a\"\n\nVoice memo transcript: (unavailable: speech-to-text is off on the gateway)\n\nok", "You: Voice Memo: (no transcript) ok",
        "Owner (user): Voice Memo: (no transcript)\nok")]
    [InlineData("MEDIA:\"/a/voice-memo.m4a\"\n\nVoice memo transcript: (unavailable)", "You: Voice Memo: (no transcript)",
        "Owner (user): Voice Memo: (no transcript)")]
    [InlineData("MEDIA:\"C:\\x\\Otter Song.mp3\"", "You: Otter Song.mp3: (no transcript)",
        "Owner (user): Otter Song.mp3: (no transcript)")]
    [InlineData("MEDIA:\"/a/voice-memo.m4a\"\n\nVoice memo transcript: \u00A0Hi\u3000", "You: Voice Memo: Hi", "Owner (user): Voice Memo: Hi")]
    [InlineData("MEDIA:\"/a/voice-memo.m4a\"\r", "You: Voice Memo: (no transcript)", "Owner (user): Voice Memo: (no transcript)")]
    [InlineData("MEDIA:\"a/voice-memo.m4a\"", "You: MEDIA:\"a/voice-memo.m4a\"", "Owner (user): MEDIA:\"a/voice-memo.m4a\"")]
    public void GroupsPreviewAndPromptReadTheMemoLine(string text, string preview, string prompt)
    {
        var none = new Dictionary<string, string>();
        Assert.Equal(preview, GroupRowWords.Preview(G.You(text), none));
        var you = new GroupMessage(null, 1, new GroupAuthor(GroupAuthorKind.User, "Owner", null), text, "t1");
        Assert.Equal(prompt, GroupPrompt.Line(you, "ivy", none));
    }
}
