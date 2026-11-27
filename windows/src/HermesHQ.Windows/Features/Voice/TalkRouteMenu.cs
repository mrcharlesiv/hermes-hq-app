using Hermes.Core.Settings;
using Hermes.Core.Voice;
using HermesHQ.Features.Transcript;
using HermesHQ.Pages;
using HermesHQ.Shell;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace HermesHQ.Features.Voice;

/// Port of App/Chat/Voice/TalkMenus.swift and TalkRouteButton.swift:
/// builds the audio route selection flyout (Speaker / Windows audio devices + Speak Replies toggle)
/// and the Voice Options menu (Start/End Talk, Engine/Live Voice chooser, Read Replies Aloud,
/// Dictate with Hermes, How Voice Works, and Voice Settings).
public static class TalkRouteMenu
{
    public static MenuFlyout BuildAudioRouteFlyout(TalkController controller)
    {
        var routes = WindowsVoiceAudio.ListOutputRoutes();
        controller.SetRoutes(routes);
        var activeId = controller.ActiveRoute?.Id;

        var flyout = new MenuFlyout { Placement = FlyoutPlacementMode.TopEdgeAlignedRight };

        var header = new MenuFlyoutItem { Text = "Audio Output", IsEnabled = false };
        flyout.Items.Add(header);

        foreach (var route in routes)
        {
            var glyph = route.Kind switch
            {
                TalkRouteKind.Bluetooth => "\uE702",
                TalkRouteKind.Headphones => "\uE7F6",
                TalkRouteKind.Usb => "\uE88E",
                _ => "\uE767",
            };
            var item = new ToggleMenuFlyoutItem
            {
                Text = route.Name,
                Icon = new FontIcon { Glyph = glyph },
                IsChecked = route.Id == activeId,
            };
            var id = route.Id;
            item.Click += (_, _) => controller.SelectRoute(id);
            flyout.Items.Add(item);
        }

        flyout.Items.Add(new MenuFlyoutSeparator());

        var speakToggle = new ToggleMenuFlyoutItem
        {
            Text = "Speak Replies",
            Icon = new FontIcon { Glyph = "\uE995" },
            IsChecked = controller.CurrentState.SpeakReplies,
        };
        AutomationProperties.SetAutomationId(speakToggle, "talk.route.speakReplies");
        speakToggle.Click += (_, _) => controller.SetSpeakReplies(speakToggle.IsChecked);
        flyout.Items.Add(speakToggle);

        return flyout;
    }

    public static MenuFlyout BuildVoiceOptionsFlyout(ChatContext ctx, TalkController controller, bool liveOffered = false, bool grokOffered = false)
    {
        var flyout = new MenuFlyout { Placement = FlyoutPlacementMode.TopEdgeAlignedRight };
        var scope = ctx.Session.MemoScope ?? ctx.Session.DraftScope;
        var activeHere = controller.IsActiveIn(scope);

        var startStop = new MenuFlyoutItem
        {
            Text = activeHere ? "End Voice Conversation" : "Start Voice Conversation",
            Icon = new FontIcon { Glyph = activeHere ? "\uE71A" : "\uE995" },
        };
        AutomationProperties.SetAutomationId(startStop, "voice.menu.talk");
        startStop.Click += (_, _) =>
        {
            if (activeHere) controller.End(TalkEnd.User);
            else TalkFeature.StartTalk(ctx);
        };
        flyout.Items.Add(startStop);

        // Voice mode / engine submenu
        var modeSub = new MenuFlyoutSubItem
        {
            Text = $"Voice Mode ({controller.PreferredEngine.Label()})",
            Icon = new FontIcon { Glyph = "\uE7F5" },
        };
        AddEngineItem(modeSub, controller, TalkEngine.Classic, enabled: true);
        AddEngineItem(modeSub, controller, TalkEngine.GptLive, enabled: liveOffered);
        AddEngineItem(modeSub, controller, TalkEngine.GrokLive, enabled: grokOffered);
        flyout.Items.Add(modeSub);

        // Live voice picker when using GPT Live or Grok Live
        var prefEngine = controller.PreferredEngine;
        if (prefEngine.IsLive())
        {
            var voices = LiveVoices.For(prefEngine);
            var currentVoice = TalkPrefs.LiveVoice(FilePreferences.Shared, prefEngine);
            var voiceSub = new MenuFlyoutSubItem
            {
                Text = "Live Voice",
                Icon = new FontIcon { Glyph = "\uE720" },
            };
            foreach (var v in voices)
            {
                var item = new ToggleMenuFlyoutItem
                {
                    Text = $"{v.Name} — {v.Description}",
                    IsChecked = string.Equals(v.Id, currentVoice, StringComparison.OrdinalIgnoreCase),
                };
                var chosenId = v.Id;
                item.Click += (_, _) => TalkPrefs.SetLiveVoice(FilePreferences.Shared, prefEngine, chosenId);
                voiceSub.Items.Add(item);
            }
            flyout.Items.Add(voiceSub);
        }

        flyout.Items.Add(new MenuFlyoutSeparator());

        var dictate = new MenuFlyoutItem
        {
            Text = "Dictate with Hermes",
            Icon = new FontIcon { Glyph = "\uE720" },
        };
        AutomationProperties.SetAutomationId(dictate, "voice.menu.dictate");
        dictate.Click += (_, _) => DictationFeature.StartDictation(ctx);
        flyout.Items.Add(dictate);

        var readReplies = new ToggleMenuFlyoutItem
        {
            Text = ReadRepliesAloud.MenuTitle,
            Icon = new FontIcon { Glyph = "\uE767" },
            IsChecked = VoicePrefs.ReadsRepliesAloud(FilePreferences.Shared),
        };
        AutomationProperties.SetAutomationId(readReplies, "voice.menu.readReplies");
        readReplies.Click += (_, _) =>
        {
            var msg = ReadRepliesAloud.Toggle(FilePreferences.Shared);
            if (ctx.Page is ChatPage page) page.ShowNotice(msg, ReadRepliesAloud.NoticeDuration);
        };
        flyout.Items.Add(readReplies);

        flyout.Items.Add(new MenuFlyoutSeparator());

        var howItem = new MenuFlyoutItem
        {
            Text = TalkIntroModel.InfoTitle,
            Icon = new FontIcon { Glyph = "\uE946" },
        };
        AutomationProperties.SetAutomationId(howItem, "voice.menu.howItWorks");
        howItem.Click += (_, _) => _ = TalkIntroDialog.ShowHowVoiceWorksAsync(ctx.Page.XamlRoot, ctx.Session.Title, liveOffered || grokOffered);
        flyout.Items.Add(howItem);

        var settingsItem = new MenuFlyoutItem
        {
            Text = "Voice Settings…",
            Icon = new FontIcon { Glyph = "\uE713" },
        };
        AutomationProperties.SetAutomationId(settingsItem, "voice.menu.settings");
        settingsItem.Click += (_, _) => SettingsWindows.Show("voice");
        flyout.Items.Add(settingsItem);

        return flyout;
    }

    private static void AddEngineItem(MenuFlyoutSubItem parent, TalkController controller, TalkEngine engine, bool enabled)
    {
        var item = new ToggleMenuFlyoutItem
        {
            Text = engine.Label(),
            IsChecked = controller.PreferredEngine == engine,
            IsEnabled = enabled || controller.PreferredEngine == engine,
        };
        item.Click += (_, _) => controller.SetPreferredEngine(engine);
        parent.Items.Add(item);
    }
}
