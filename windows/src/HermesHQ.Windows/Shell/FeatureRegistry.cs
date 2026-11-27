namespace HermesHQ.Shell;

/// Each ported feature adds one line here: its Register() claims places, chat hooks and part renderers.
/// One line per feature keeps parallel work from colliding anywhere else.
public static class FeatureRegistry
{
    public static void RegisterAll()
    {
        // Features register below, one line each, in PARITY.md order.
        Features.Gateways.GatewaysFeature.Register();
        Features.Heads.HeadsFeature.Register();
        Features.Questions.QuestionsFeature.Register();
        Features.Transcript.TranscriptFeature.Register();
        Features.Attachments.AttachmentsFeature.Register();
        HermesHQ.Features.Composer.ComposerFeature.Register();
        Features.Bots.BotsFeature.Register();
        Features.Sessions.SessionsFeature.Register();
        HermesHQ.Features.Jobs.JobsFeature.Register();
        Features.Settings.SettingsFeature.Register();
        Features.Workspace.WorkspaceFeature.Register();
        Features.Kanban.KanbanFeature.Register();
        Features.Tasks.TasksFeature.Register();
        Features.Artifacts.ArtifactsFeature.Register();
        HermesHQ.Features.BotPages.BotPagesFeature.Register();
        HermesHQ.Features.Insights.InsightsFeature.Register();
        HermesHQ.Features.Capabilities.CapabilitiesFeature.Register();
        HermesHQ.Features.Notifications.NotificationsFeature.Register();
        HermesHQ.Features.TypeToChat.TypeToChatFeature.Register();   // MacTypeToChat: keys typed with nothing focused go to the open chat
        HermesHQ.Features.ChatFind.ChatFindFeature.Register();
        HermesHQ.Features.QuickActions.QuickActionsFeature.Register();   // the Quick Actions page (Ctrl+Shift+K, the Mac's ⇧⌘K)
        HermesHQ.Features.Groups.GroupManageFeature.Register();   // [groups] the room row menu, Group Info, the bots picker, Add to Group Chat…
        HermesHQ.Features.Voice.ReadAloudFeature.Register();   // [WIN-54] Read Aloud on a reply, Read Replies Aloud
        HermesHQ.Features.Voice.VoiceMemosFeature.Register();  // Voice Memos recorder, draft chip & transcript player
        HermesHQ.Features.Voice.DictationFeature.Register();   // Dictation with live words
        HermesHQ.Features.Voice.TalkFeature.Register();        // Live & Classic Talk voice sessions
        HermesHQ.Features.Browser.BrowserFeature.Register();   // Watch Browser viewer, tabs, Chrome profiles & chat card
        HermesHQ.Features.Coding.CodingFeature.Register();     // Coding Pipeline View, PR Cards & interactive diffs
        HermesHQ.Features.PhoneCalls.PhoneCallsFeature.Register(); // Phone Calls, samplehost setup, live call window & history
        HermesHQ.Features.ChatIntro.ChatIntroFeature.Register();   // [WIN-CHAT-INTRO] the empty chat's intro
        Services.ProofWalks.Register();   // the CI's /new, Auto-Archive and Keyboard Shortcuts pictures
    }
}
