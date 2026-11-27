using Hermes.Core.Shell;
using Hermes.Core.Voice;
using HermesHQ.Controls;
using HermesHQ.Features.Voice;
using HermesHQ.Pages;
using HermesHQ.Shell;
using HermesHQ.ViewModels;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Services;

/// [WIN-54] The CI's walk for Read Aloud (windows/ci/windows.yml asks for it on the composer stand-in), on the
/// stand-in's Trip planning chat (menus-gateway.py `TRIP`), checked by `Hermes.Core.Shell.ReadAloudWalkProof`:
///   read-aloud  The latest reply's right-click menu reads Copy, Read Aloud, Share… (picture read-aloud-menu). Read
///               Aloud starts reading that reply; its menu then reads Stop Reading (picture read-aloud-speaking), and
///               Stop Reading stops it: nothing is read and the voice was told to stop once.
/// The reading plays through a held voice that sounds as soon as it is asked and goes on until it is stopped (a CI
/// machine may have no voice or no sound device, and a short reply could end before the menu opens again); the PC's
/// own voices are counted in the app log. The menu opens as a right-click opens it (MessageView.OpenMenu); its rows
/// are clicked by SendInput; where the click doesn't arrive, the walk invokes them and says so in the app log.
internal static partial class ProofWalks
{
    private static void RegisterReadAloudWalks()
    {
        Automation.NamedWalks["read-aloud"] = ReadAloudAsync;
    }

    /// A voice that starts at once and holds until it is stopped.
    private sealed class HeldVoice : IReadAloudVoice
    {
        public int Stops;
        public async Task SpeakAsync(IReadOnlyList<string> sentences, Action started, CancellationToken cancel)
        {
            started();
            try { await Task.Delay(Timeout.Infinite, cancel); }
            finally { Interlocked.Increment(ref Stops); }
        }
    }

    private static async Task ReadAloudAsync(Func<string, Task> shot)
    {
        Navigator.Go(new ChatDestination(ChatActionsProof.TripBot, ChatActionsProof.TripStoredId, ChatActionsProof.TripTitle));
        var chat = await Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId == ChatActionsProof.TripStoredId && p.MessageCount >= 4 && !p.IsBusy ? p : null,
            "Trip planning's messages");
        var list = await Until(() => Shown(chat).OfType<ListView>().FirstOrDefault(), "the transcript");
        List<MessageItem> Items() => (list.ItemsSource as IEnumerable<object>)?.OfType<MessageItem>().ToList() ?? [];
        var reply = await Until(() => Items().LastOrDefault(i => i.Role == Hermes.Core.Model.Role.Assistant), "the latest reply");
        list.ScrollIntoView(reply, ScrollIntoViewAlignment.Leading);
        await Task.Delay(500);
        var view = await Until(() => Shown(list).OfType<MessageView>().FirstOrDefault(v => v.Item?.Id == reply.Id), "the latest reply on screen");

        AppLog.Note("automation", $"walk read-aloud: the PC has {Windows.Media.SpeechSynthesis.SpeechSynthesizer.AllVoices.Count} voices");
        var center = ReadAloudFeature.Center;
        var real = center.Voice;
        var held = new HeldVoice();
        center.Voice = held;
        ReadAloudFeature.FailureShown = reason => AppLog.Note("automation", "walk read-aloud: Couldn’t Read Aloud shown");
        try
        {
            // The reply's menu: Read Aloud between Copy and Share….
            view.OpenMenu();
            var read = await Until(() => MenuItem(ReadAloudWalkProof.ReadAloud), "Read Aloud in the reply's menu");
            if (ReadAloudWalkProof.MenuReads(ReadAloudMenuEntries(), reading: false) is { } menuWrong) throw new InvalidOperationException(menuWrong);
            await Task.Delay(400);
            await shot("read-aloud-menu");
            await ReadAloudClickUntil(read, "Read Aloud", () => center.State == ReadAloudState.Speaking(reply.Id));
            await Until(() => center.State == ReadAloudState.Speaking(reply.Id) ? center : null, "the reply to be read", 15);

            // While it is read, the same menu says Stop Reading.
            await Until(() => MenuItem(ReadAloudWalkProof.ReadAloud) == null && MenuItem(ReadAloudWalkProof.StopReading) == null ? view : null, "the menu to close", 10);
            view.OpenMenu();
            var stop = await Until(() => MenuItem(ReadAloudWalkProof.StopReading), "Stop Reading in the reply's menu");
            if (ReadAloudWalkProof.MenuReads(ReadAloudMenuEntries(), reading: true) is { } speakingWrong) throw new InvalidOperationException(speakingWrong);
            await Task.Delay(400);
            await shot("read-aloud-speaking");
            await ReadAloudClickUntil(stop, "Stop Reading", () => center.State == ReadAloudState.Idle);
            await Until(() => center.State == ReadAloudState.Idle && held.Stops > 0 ? center : null, "the reading to stop", 15);
            if (ReadAloudWalkProof.Stopped(ReadAloudFeature.StateName, held.Stops) is { } stopWrong) throw new InvalidOperationException(stopWrong);
            await Until(() => MenuItem(ReadAloudWalkProof.StopReading) == null ? view : null, "the menu to close", 10);
            await shot("read-aloud");
        }
        finally
        {
            center.Stop();
            center.Voice = real;
            ReadAloudFeature.FailureShown = null;
        }
    }

    private static List<(string, bool)> ReadAloudMenuEntries() => [.. InPopups().OfType<MenuFlyoutItem>().Select(i => (i.Text, i.IsEnabled))];

    /// Clicks a menu row by SendInput; where the click doesn't arrive within 10 s, invokes it and says so.
    private static async Task ReadAloudClickUntil(MenuFlyoutItem item, string name, Func<bool> done)
    {
        try { Mouse.Click(item); }
        catch (InvalidOperationException e) { AppLog.Note("automation", $"walk read-aloud: {name} wasn't clicked ({e.Message}); invoking it"); Invoke(item); return; }
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (DateTime.UtcNow < deadline && !done()) await Task.Delay(100);
        if (done()) return;
        AppLog.Note("automation", $"walk read-aloud: the click on {name} didn't arrive; invoking it");
        Invoke(item);
    }
}
