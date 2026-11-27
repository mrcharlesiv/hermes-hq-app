using Hermes.Core.Settings;
using Hermes.Core.Shell;
using Hermes.Core.Voice;
using HermesHQ.Features.Transcript;
using HermesHQ.Features.Voice;
using HermesHQ.Pages;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Services;

/// [WIN-62] The CI's walk for Read Replies Aloud (windows/ci/windows.yml asks for it on the composer stand-in, after
/// read-aloud), in the stand-in's own bot chat, checked by `Hermes.Core.Shell.ReadRepliesAloudWalkProof`:
///   read-replies  The ⋯ menu's Read Replies Aloud (unticked, between Model and Prompts) turns it on: the chat says
///                 “Read Replies Aloud is on” and the switch is kept on this PC (picture read-replies-on). A send makes the
///                 stand-in reply; that reply is handed to the voice (the app's log: “read replies aloud: reading the
///                 newest reply”). The header's speaker, “Read Replies Aloud is on”, opens “Replies are read aloud” ›
///                 Stop Reading Replies Aloud (picture read-replies-indicator); Stop turns it off: “Read Replies Aloud is
///                 off”, the speaker goes, and the stand-in's next reply is not read.
/// The voice is a held one that sounds at once (a CI machine may have no voice or sound device). Rows are clicked by
/// SendInput; where the click doesn't arrive, the walk does what the row does and says so in the app log. The switch is
/// put back as it was.
internal static partial class ProofWalks
{
    private static void RegisterReadRepliesAloudWalks()
    {
        Automation.NamedWalks["read-replies"] = ReadRepliesAloudAsync;
    }

    /// A voice that starts at once, keeps what it was handed, and holds until it is stopped.
    private sealed class KeptVoice : IReadAloudVoice
    {
        public readonly List<string> Spoken = [];
        public async Task SpeakAsync(IReadOnlyList<string> sentences, Action started, CancellationToken cancel)
        {
            lock (Spoken) Spoken.Add(string.Join(" ", sentences));
            started();
            await Task.Delay(Timeout.Infinite, cancel);
        }
    }

    private static async Task ReadRepliesAloudAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var prefs = FilePreferences.Shared;
        var was = prefs.Get(VoicePrefs.ReadRepliesKey);
        bool On() => VoicePrefs.ReadsRepliesAloud(prefs);
        void Check(string? wrong) { if (wrong != null) throw new InvalidOperationException(wrong); }
        VoicePrefs.SetReadsRepliesAloud(prefs, false);

        var bot = (await client.BotsAsync()).FirstOrDefault(b => b.Name == "default") ?? throw new InvalidOperationException("the stand-in has no Hermes");
        var stored = await client.BotChatIdAsync(bot);
        Navigator.Go(new ChatDestination(bot.Name, stored, bot.DisplayName));
        var chat = await Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId == stored && !p.IsBusy ? p : null, "Hermes's own chat", 20);
        await Task.Delay(800);   // the transcript is read in

        var center = ReadAloudFeature.Center;
        var real = center.Voice;
        var voice = new KeptVoice();
        center.Voice = voice;
        var handed = new List<string>();
        var voiceLog = new List<string>();
        void Handed(string id, string words) { lock (handed) handed.Add(words); }
        void Noted(string area, string text) { if (area == "voice") lock (voiceLog) voiceLog.Add(text); }
        ReadAloudFeature.RepliesRead += Handed;
        AppLog.Noted += Noted;
        try
        {
            // ⋯ › Read Replies Aloud, unticked, in its section.
            var more = Shown(chat).OfType<Button>().FirstOrDefault(b => b.Name == "MoreButton") ?? throw new InvalidOperationException("the chat has no ⋯");
            more.Flyout.ShowAt(more);
            var row = await Until(() => InPopups().OfType<ToggleMenuFlyoutItem>().FirstOrDefault(i => i.Text == ReadRepliesAloud.MenuTitle),
                "Read Replies Aloud in the ⋯ menu");
            await Task.Delay(300);
            Check(ReadRepliesAloudWalkProof.MenuRow(MoreMenuEntries(), on: false));
            await ReadRepliesClickUntil(row, ReadRepliesAloud.MenuTitle, On, () => ReadRepliesAloud.Toggle(prefs), chat);
            await Until(() => On() ? chat : null, "Read Replies Aloud to turn on", 10);
            Check(ReadRepliesAloudWalkProof.Stored(prefs.Get(VoicePrefs.ReadRepliesKey), on: true));
            await Until(() => chat.NoticeText != null ? chat : null, "the chat's notice", 10);
            Check(ReadRepliesAloudWalkProof.Notice(chat.NoticeText, on: true));
            AppLog.Note("automation", $"walk read-replies: the chat says “{chat.NoticeText}”");
            await shot("read-replies-on");

            // The stand-in replies: the reply is handed to the voice.
            await Until(() => !chat.IsBusy ? chat : null, "the chat to be idle", 20);
            lock (handed) handed.Clear();
            lock (voiceLog) voiceLog.Clear();
            chat.AutomationSend("Read this back");
            await Until(() => { lock (handed) return handed.Count > 0 ? chat : null; }, "the stand-in's reply to be read", 30);
            await Until(() => center.State.Phase == ReadAloudPhase.Speaking ? center : null, "the voice to speak", 15);
            await Until(() => !chat.IsBusy ? chat : null, "the turn to end", 20);
            await Task.Delay(800);   // a second read of the same reply would show here
            string words;
            string? spoken;
            lock (handed) words = handed[0];
            lock (voice.Spoken) spoken = voice.Spoken.FirstOrDefault();
            lock (handed) lock (voiceLog)
                Check(ReadRepliesAloudWalkProof.Read(handed.Count, voiceLog, spoken, SpeechText.SanitizeForSpeech(words)));
            AppLog.Note("automation", $"walk read-replies: the reply was handed to the voice ({words.Length} characters)");

            // The header's speaker while it is on; its menu turns it off.
            var speaker = await Until(() => FindIn(chat, ReadRepliesAloud.IndicatorId) as Button, "the header's speaker", 10);
            speaker.Flyout.ShowAt(speaker);
            var stop = await Until(() => InPopups().OfType<MenuFlyoutItem>().FirstOrDefault(i => i.Text == ReadRepliesAloud.StopTitle),
                "Stop Reading Replies Aloud in the speaker's menu");
            await Task.Delay(300);
            var titles = InPopups().OfType<MenuFlyoutItem>().Select(i => i.Text).ToList();
            Check(ReadRepliesAloudWalkProof.Indicator(speaker.Visibility == Visibility.Visible, AutomationProperties.GetName(speaker),
                ToolTipService.GetToolTip(speaker) as string, titles));
            await shot("read-replies-indicator");
            await ReadRepliesClickUntil(stop, ReadRepliesAloud.StopTitle, () => !On(), () => ReadRepliesAloud.TurnOff(prefs), chat);
            await Until(() => !On() ? chat : null, "Read Replies Aloud to turn off", 10);
            Check(ReadRepliesAloudWalkProof.Stored(prefs.Get(VoicePrefs.ReadRepliesKey), on: false));
            await Until(() => chat.NoticeText == ReadRepliesAloud.IsOff ? chat : null, "the chat's notice to say it is off", 10);
            Check(ReadRepliesAloudWalkProof.Notice(chat.NoticeText, on: false));
            // The reply it was reading stops with it.
            await Until(() => center.State.Phase == ReadAloudPhase.Idle ? center : null, "the reading to stop", 10);

            // The stand-in's next reply is not read.
            await Until(() => InPopups().OfType<MenuFlyoutItem>().Any() ? null : chat, "the speaker's menu to close", 10);
            var rows = chat.MessageCount;
            lock (handed) handed.Clear();
            lock (voiceLog) voiceLog.Clear();
            chat.AutomationSend("Read this back too");
            await Until(() => chat.MessageCount >= rows + 2 && !chat.IsBusy ? chat : null, "the stand-in's next reply", 30);
            await Task.Delay(1500);   // a reading would have started by now
            lock (handed) lock (voiceLog)
                Check(ReadRepliesAloudWalkProof.NotRead(handed.Count, voiceLog.Count(l => l == ReadRepliesAloudWalkProof.ReadLog),
                    FindIn(chat, ReadRepliesAloud.IndicatorId) != null));
            AppLog.Note("automation", "walk read-replies: off, the next reply was not read and the speaker is gone");
            await shot("read-replies");
        }
        finally
        {
            ReadAloudFeature.RepliesRead -= Handed;
            AppLog.Noted -= Noted;
            center.Stop();
            center.Voice = real;
            VoicePrefs.SetReadsRepliesAloud(prefs, false);
            prefs.Set(VoicePrefs.ReadRepliesKey, was);
        }
    }

    /// The ⋯ menu's rows as shown: (title, tick); a separator is (null, null), a row that isn't a switch has no tick.
    private static List<(string?, bool?)> MoreMenuEntries() =>
        [.. InPopups().OfType<MenuFlyoutItemBase>().Select(i => i switch
        {
            MenuFlyoutSeparator => ((string?)null, (bool?)null),
            ToggleMenuFlyoutItem t => (t.Text, t.IsChecked),
            MenuFlyoutItem m => (m.Text, null),
            MenuFlyoutSubItem s => (s.Text, null),
            _ => (null, null),
        })];

    /// Clicks a menu row by SendInput; where the click doesn't arrive within 10 s, does what the row does and says so
    /// (the menu is closed first, as the click would close it).
    private static async Task ReadRepliesClickUntil(MenuFlyoutItemBase item, string name, Func<bool> done, Func<string> act, ChatPage chat)
    {
        try { Mouse.Click(item); }
        catch (InvalidOperationException e) { AppLog.Note("automation", $"walk read-replies: {name} wasn't clicked ({e.Message}); doing what it does"); Act(); return; }
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (DateTime.UtcNow < deadline && !done()) await Task.Delay(100);
        if (done()) return;
        AppLog.Note("automation", $"walk read-replies: the click on {name} didn't arrive; doing what it does");
        Act();

        void Act()
        {
            // A plain row's Invoke is its click; the switch row's automation toggles its tick only, so the walk closes the
            // menu and does what the click does (the switch, then the notice).
            if (item is not ToggleMenuFlyoutItem && FrameworkElementAutomationPeer.CreatePeerForElement(item) is IInvokeProvider invoke)
            {
                invoke.Invoke();
                return;
            }
            if (Root.XamlRoot is { } xr)
                foreach (var popup in VisualTreeHelper.GetOpenPopupsForXamlRoot(xr)) popup.IsOpen = false;
            chat.ShowNotice(act(), ReadRepliesAloud.NoticeDuration);
        }
    }
}
