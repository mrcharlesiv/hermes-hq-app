using Hermes.Core.PhoneCalls;

namespace Hermes.Core.Tests.PhoneCalls;

public class PhoneOutcomeAndTranscriptTests
{
    [Theory]
    [InlineData("+15550100123", "+15550100123")]
    [InlineData("(555) 010-0123", "+15550100123")]
    [InlineData("555.010.0123", "+15550100123")]
    [InlineData("1-555-010-0123", "+15550100123")]
    [InlineData("+44 20 7946 0958", "+442079460958")]
    [InlineData("12345", null)]
    [InlineData("not a number", null)]
    public void NormalizeDestinationProducesStrictE164(string input, string? expected)
    {
        Assert.Equal(expected, PhoneFormatting.NormalizeDestination(input));
    }

    [Fact]
    public void FormatShownAndTimersFormatCleanly()
    {
        Assert.Equal("+1 555 010 0123", PhoneFormatting.FormatShown("+15550100123"));
        Assert.Equal("0:09", PhoneFormatting.FormatTimer(TimeSpan.FromSeconds(9)));
        Assert.Equal("2:05", PhoneFormatting.FormatTimer(TimeSpan.FromSeconds(125)));
        Assert.Equal("45s", PhoneFormatting.FormatDuration(TimeSpan.FromSeconds(45)));
        Assert.Equal("2m 5s", PhoneFormatting.FormatDuration(TimeSpan.FromSeconds(125)));
        Assert.NotNull(PhoneFormatting.StraightToVoicemailNote(TimeSpan.FromSeconds(2)));
        Assert.Null(PhoneFormatting.StraightToVoicemailNote(TimeSpan.FromSeconds(8)));
    }

    [Fact]
    public void PhoneVerdictDerivesOutcomesFromEventsSipCodesAndTranscript()
    {
        Assert.Equal(PhoneOutcomeKind.Voicemail,
            PhoneVerdict.Derive([new PhoneCallEvent("call.machine.detection.ended", MachineResult: "machine")], null, PhoneLocalEnd.None, [], true).Kind);

        Assert.Equal(PhoneOutcomeKind.NoSuchNumber,
            PhoneVerdict.Derive([new PhoneCallEvent("call.hangup", HangupCause: "unallocated_number")], null, PhoneLocalEnd.None, [], false).Kind);

        Assert.Equal(PhoneOutcomeKind.Busy,
            PhoneVerdict.Derive([new PhoneCallEvent("call.hangup", SipCode: "486")], null, PhoneLocalEnd.None, [], false).Kind);

        Assert.Equal(PhoneOutcomeKind.Declined,
            PhoneVerdict.Derive([new PhoneCallEvent("call.hangup", SipCode: "603")], null, PhoneLocalEnd.None, [], false).Kind);

        Assert.Equal(PhoneOutcomeKind.NoAnswer,
            PhoneVerdict.Derive([], null, PhoneLocalEnd.RingTimeout, [], false).Kind);

        var vmLines = new[] { new PhoneTranscriptLine("1", PhoneSpeaker.Them, "Please leave a message after the tone.") };
        Assert.Equal(PhoneOutcomeKind.Voicemail,
            PhoneVerdict.Derive([], null, PhoneLocalEnd.None, vmLines, true).Kind);

        var liveLines = new[] { new PhoneTranscriptLine("1", PhoneSpeaker.Them, "Tuesday at 10 AM works great.") };
        Assert.Equal(PhoneOutcomeKind.Finished,
            PhoneVerdict.Derive([], null, PhoneLocalEnd.YouHungUp, liveLines, true).Kind);
    }

    [Fact]
    public void PhoneTranscriptStripsEmotionsDeduplicatesAskOwnerAndMergesPendingOwner()
    {
        var messages = new List<samplehostMessage>
        {
            new("m1", "assistant", "<emotion happy>Hello!</emotion> Calling about Tuesday."),
            new("m2", "user", "[long silence]"),
            new("m3", "user", "What time works best?"),
            new("m4", "assistant", "", ToolCalls: [new samplehostToolCall("tc1", PhoneAskOwner.ToolName, """{"question":"10 AM or 2 PM?","choices":["10 AM","2 PM"]}""")]),
            new("m5", "assistant", "", ToolCalls: [new samplehostToolCall("tc2", PhoneAskOwner.ToolName, """{"question":"10 AM or 2 PM?","choices":["10 AM","2 PM"]}""")]),
            new("m6", "system", "Owner instruction: Ask for morning."),
        };

        var pending = new[]
        {
            new PhoneTranscriptLine("p1", PhoneSpeaker.You, "Ask for morning.", Pending: true),
            new PhoneTranscriptLine("p2", PhoneSpeaker.You, "Mention flexible Wednesday.", Pending: true),
        };

        var snap = PhoneTranscript.Read(messages, pending);
        // Emotion tag stripped, [long silence] suppressed, duplicate owner line not doubled, pending line retained
        Assert.Equal(4, snap.Lines.Count);
        Assert.Equal("Hello! Calling about Tuesday.", snap.Lines[0].Text);
        Assert.Equal(PhoneSpeaker.Them, snap.Lines[1].Speaker);
        Assert.Equal("Ask for morning.", snap.Lines[2].Text);
        Assert.False(snap.Lines[2].Pending);
        Assert.Equal("Mention flexible Wednesday.", snap.Lines[3].Text);
        Assert.True(snap.Lines[3].Pending);

        // Duplicate ask_owner deduplicated to latest live tool call id
        Assert.NotNull(snap.PendingQuestion);
        Assert.Equal("tc2", snap.PendingQuestion!.ToolCallId);
        Assert.Equal(["10 AM", "2 PM"], snap.PendingQuestion.Choices);

        // Answering moves it from PendingQuestion to QAs
        var answeredSnap = PhoneTranscript.Read(messages, localAnswers: new Dictionary<string, string> { ["tc2"] = "10 AM" });
        Assert.Null(answeredSnap.PendingQuestion);
        var qa = Assert.Single(answeredSnap.QAs);
        Assert.Equal("10 AM or 2 PM?", qa.Question);
        Assert.Equal("10 AM", qa.Answer);
    }
}
