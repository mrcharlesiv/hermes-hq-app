using Hermes.Core.Settings;
using Hermes.Core.Shell;
using Hermes.Core.Transcripts;
using Hermes.Core.Voice;

namespace Hermes.Core.Tests;

/// [WIN-62] Read Replies Aloud in a chat: the ⋯ row, its notices, the header's speaker and its Stop item
/// (App/Chat/Voice/ChatReadAloudHost.swift `repliesItem` / `saySwitch` / `switchChanged`, App/Chat/ChatViewController.swift
/// `makeReadAloudButton` / `showsReadAloudButton`, App/Chat/Voice/TalkController.swift `readsRepliesAloud` at 93f984bb1).
public class ReadRepliesAloudTests
{
    private sealed class HeldVoice : IReadAloudVoice
    {
        public Task SpeakAsync(IReadOnlyList<string> sentences, Action started, CancellationToken cancel)
        {
            started();
            return Task.Delay(Timeout.Infinite, cancel);
        }
    }

    [Fact]
    public void TheMacsWordsAndNames()
    {
        Assert.Equal("Read Replies Aloud", ReadRepliesAloud.MenuTitle);
        Assert.Equal("Read Replies Aloud is on", ReadRepliesAloud.IsOn);
        Assert.Equal("Read Replies Aloud is off", ReadRepliesAloud.IsOff);
        Assert.Equal("Replies are read aloud", ReadRepliesAloud.IndicatorTitle);
        Assert.Equal("Stop Reading Replies Aloud", ReadRepliesAloud.StopTitle);
        Assert.Equal("Read Replies Aloud is on", ReadRepliesAloud.IndicatorName);
        Assert.Equal("chat.menu.read-replies", ReadRepliesAloud.MenuId);
        Assert.Equal("chat.readAloud", ReadRepliesAloud.IndicatorId);
        Assert.Equal("chat.readAloud.off", ReadRepliesAloud.StopId);
        Assert.Equal(TimeSpan.FromSeconds(3), ReadRepliesAloud.NoticeDuration);
        Assert.Equal("Read Replies Aloud is on", ReadRepliesAloud.Notice(true));
        Assert.Equal("Read Replies Aloud is off", ReadRepliesAloud.Notice(false));
    }

    [Fact]
    public void TheMenuRowFlipsTheSwitchKeptOnThisPcAndSaysWhatItIsNow()
    {
        var prefs = new MemoryPrefs();
        // Off by default; the ⋯ row turns it on, stored under the Mac's key, and says so.
        Assert.Equal("Read Replies Aloud is on", ReadRepliesAloud.Toggle(prefs));
        Assert.Equal("true", prefs.Get(VoicePrefs.ReadRepliesKey));
        Assert.True(VoicePrefs.ReadsRepliesAloud(prefs));
        Assert.Equal("Read Replies Aloud is off", ReadRepliesAloud.Toggle(prefs));
        Assert.Equal("false", prefs.Get(VoicePrefs.ReadRepliesKey));
        // On from the gateway's voice.auto_tts: the row turns it off, and that choice outranks the gateway.
        var gateway = new MemoryPrefs();
        gateway.Set(VoicePrefs.ReadRepliesGatewayKey, "true");
        Assert.Equal("Read Replies Aloud is off", ReadRepliesAloud.Toggle(gateway));
        Assert.False(VoicePrefs.ReadsRepliesAloud(gateway));
        // The indicator's Stop turns it off whatever it was, and the choice is kept even when unchanged.
        var stop = new MemoryPrefs();
        Assert.Equal("Read Replies Aloud is off", ReadRepliesAloud.TurnOff(stop));
        Assert.Equal("false", stop.Get(VoicePrefs.ReadRepliesKey));
    }

    [Fact]
    public void EveryChatHearsTheSwitchChangeOnlyWhenItChanges()
    {
        var prefs = new MemoryPrefs();
        var heard = new List<bool>();
        void Heard(IPreferences p, bool on) { if (ReferenceEquals(p, prefs)) lock (heard) heard.Add(on); }
        VoicePrefs.ReadRepliesChanged += Heard;
        try
        {
            VoicePrefs.SetReadsRepliesAloud(prefs, false);   // already off: stored, nobody told
            VoicePrefs.SetReadsRepliesAloud(prefs, true);
            VoicePrefs.SetReadsRepliesAloud(prefs, true);
            ReadRepliesAloud.TurnOff(prefs);
        }
        finally { VoicePrefs.ReadRepliesChanged -= Heard; }
        Assert.Equal([true, false], heard);
    }

    [Fact]
    public void TheHeaderSpeakerShowsOnlyWhileTheChatOffersTheRowAndTheSwitchIsOn()
    {
        Assert.True(ReadRepliesAloud.ShowsIndicator(offered: true, switchOn: true));
        Assert.False(ReadRepliesAloud.ShowsIndicator(offered: true, switchOn: false));
        // A chat with no Read Replies Aloud row (a group room) never shows the speaker.
        Assert.False(ReadRepliesAloud.ShowsIndicator(offered: false, switchOn: true));
    }

    [Fact]
    public void TheRowSitsInTheMacsSectionAfterTheChatsOwnRowsAndBeforeItsTools()
    {
        // Share…, Rename…, Model, —, Prompts: Model's section, a separator, the row, a separator, then the tools.
        var placed = ReadRepliesAloud.Place(["Share…", "Rename…", "Model", null, "Prompts", "Usage & Limits"], "Prompts");
        Assert.Equal(new ReadRepliesAloud.Placement(4, SeparatorBefore: false, SeparatorAfter: true), placed);
        // No separator before the tools: one goes on each side.
        Assert.Equal(new ReadRepliesAloud.Placement(2, SeparatorBefore: true, SeparatorAfter: true),
            ReadRepliesAloud.Place(["Model", "Rename…", "Prompts"], "Prompts"));
        // No tools: at the end, after a separator.
        Assert.Equal(new ReadRepliesAloud.Placement(2, SeparatorBefore: true, SeparatorAfter: false), ReadRepliesAloud.Place(["Share…", "Rename…"], "Prompts"));
        // An empty menu: the row alone.
        Assert.Equal(new ReadRepliesAloud.Placement(0, SeparatorBefore: false, SeparatorAfter: false), ReadRepliesAloud.Place([], "Prompts"));
    }

    [Fact]
    public void TurningTheSwitchOffStopsOnlyTheReplyItWasReading()
    {
        var center = new ReadAloudCenter(new HeldVoice());
        // A reply Read Replies Aloud started: the switch going off stops it.
        Assert.True(center.Read("r1", "One reply.", "chat-a", auto: true));
        Assert.True(center.ReadingReplies);
        Assert.False(center.StopReplies("chat-b"));
        Assert.Equal(ReadAloudState.Speaking("r1"), center.State);
        Assert.True(center.StopReplies("chat-a"));
        Assert.Equal(ReadAloudState.Idle, center.State);
        // Read Aloud asked for by hand keeps reading (the Mac's owner is .readAloud, not .repliesAloud).
        center.Toggle("r2", "Asked for.", "chat-a");
        Assert.False(center.ReadingReplies);
        Assert.False(center.StopReplies("chat-a"));
        Assert.Equal(ReadAloudState.Speaking("r2"), center.State);
        center.Stop();
    }
}

/// [WIN-62] The read-replies walk's checks (Hermes.Core.Shell.ReadRepliesAloudWalkProof).
public class ReadRepliesAloudWalkProofTests
{
    [Fact]
    public void TheMenuRowItsTickAndItsPlace()
    {
        (string? Title, bool? Checked)[] off = [("Share…", null), ("Model", null), (null, null), ("Read Replies Aloud", false), (null, null), ("Prompts", null)];
        Assert.Null(ReadRepliesAloudWalkProof.MenuRow(off, on: false));
        Assert.Equal("Read Replies Aloud is unticked while the switch is on", ReadRepliesAloudWalkProof.MenuRow(off, on: true));
        Assert.Equal("the ⋯ menu has no Read Replies Aloud", ReadRepliesAloudWalkProof.MenuRow([("Model", null), ("Prompts", null)], on: false));
        Assert.Equal("Read Replies Aloud sits after Prompts, not between Model and Prompts",
            ReadRepliesAloudWalkProof.MenuRow([("Model", null), ("Prompts", null), ("Read Replies Aloud", true)], on: true));
        Assert.Equal("Read Replies Aloud isn't a switch row with a tick",
            ReadRepliesAloudWalkProof.MenuRow([("Model", null), ("Read Replies Aloud", null), ("Prompts", null)], on: false));
    }

    [Fact]
    public void TheNoticeAndTheStoredSwitch()
    {
        Assert.Null(ReadRepliesAloudWalkProof.Notice("Read Replies Aloud is on", on: true));
        Assert.Equal("the chat says nothing after the switch turned on (Read Replies Aloud is on)", ReadRepliesAloudWalkProof.Notice(null, on: true));
        Assert.Equal("the chat says “Read Replies Aloud is on”, not “Read Replies Aloud is off”",
            ReadRepliesAloudWalkProof.Notice("Read Replies Aloud is on", on: false));
        Assert.Null(ReadRepliesAloudWalkProof.Stored("true", on: true));
        Assert.Equal("hq.voice.readRepliesAloud holds false, not true", ReadRepliesAloudWalkProof.Stored("false", on: true));
        Assert.Equal("hq.voice.readRepliesAloud holds nothing, not false", ReadRepliesAloudWalkProof.Stored(null, on: false));
    }

    [Fact]
    public void TheReplyWasHandedToTheVoiceOnceWithItsWords()
    {
        string[] log = ["read replies aloud: reading the newest reply"];
        Assert.Null(ReadRepliesAloudWalkProof.Read(1, log, "Hello. Two.", "Hello. Two."));
        Assert.Equal("the voice was handed 0 replies, not 1", ReadRepliesAloudWalkProof.Read(0, log, null, "Hello."));
        Assert.Equal("the voice was handed 2 replies, not 1", ReadRepliesAloudWalkProof.Read(2, log, "Hello.", "Hello."));
        Assert.Equal("the app's log has no “read replies aloud: reading the newest reply”", ReadRepliesAloudWalkProof.Read(1, [], "Hello.", "Hello."));
        Assert.Equal("the voice was handed “Other.”, not the reply’s words “Hello.”", ReadRepliesAloudWalkProof.Read(1, log, "Other.", "Hello."));
    }

    [Fact]
    public void TheHeaderSpeakerAndItsMenu()
    {
        string[] menu = ["Replies are read aloud", "Stop Reading Replies Aloud"];
        Assert.Null(ReadRepliesAloudWalkProof.Indicator(true, "Read Replies Aloud is on", "Read Replies Aloud is on", menu));
        Assert.Equal("the header shows no speaker while Read Replies Aloud is on", ReadRepliesAloudWalkProof.Indicator(false, null, null, []));
        Assert.Equal("the header's speaker is named “Speaker”, not “Read Replies Aloud is on”",
            ReadRepliesAloudWalkProof.Indicator(true, "Speaker", "Read Replies Aloud is on", menu));
        Assert.Equal("the header's speaker has no tip “Read Replies Aloud is on”",
            ReadRepliesAloudWalkProof.Indicator(true, "Read Replies Aloud is on", null, menu));
        Assert.Equal("the speaker's menu reads Stop Reading Replies Aloud, not Replies are read aloud, Stop Reading Replies Aloud",
            ReadRepliesAloudWalkProof.Indicator(true, "Read Replies Aloud is on", "Read Replies Aloud is on", ["Stop Reading Replies Aloud"]));
    }

    [Fact]
    public void OffNothingIsReadAndTheSpeakerIsGone()
    {
        Assert.Null(ReadRepliesAloudWalkProof.NotRead(0, 0, indicatorShown: false));
        Assert.Equal("the voice was handed 1 reply with Read Replies Aloud off", ReadRepliesAloudWalkProof.NotRead(1, 0, indicatorShown: false));
        Assert.Equal("the app's log says it read 1 reply with Read Replies Aloud off", ReadRepliesAloudWalkProof.NotRead(0, 1, indicatorShown: false));
        Assert.Equal("the header still shows the speaker with Read Replies Aloud off", ReadRepliesAloudWalkProof.NotRead(0, 0, indicatorShown: true));
    }
}
