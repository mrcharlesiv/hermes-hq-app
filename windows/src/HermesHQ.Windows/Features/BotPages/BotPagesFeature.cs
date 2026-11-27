using HermesHQ.Shell;

namespace HermesHQ.Features.BotPages;

/// Bot Profiles (with New Bot and the SOUL.md editor), Messaging, Webhooks, Import Sessions, and More search behind the
/// sidebar's search field (App/Pages/More/{Profiles,Messaging,Webhooks,ImportSessions,Kit}, MoreSearchUI.swift).
/// `PageSearchBox` is the search box any list page can put on its bar.
public static class BotPagesFeature
{
    public static void Register()
    {
        Places.Register("profiles", typeof(ProfilesPage));   // Navigator.Open("profiles", "new") opens New Bot
        Places.Register("messaging", typeof(MessagingPage));
        Places.Register("webhooks", typeof(WebhooksPage));
        Places.Register("import-sessions", typeof(ImportSessionsPage));
        ShellExtensions.Search = MoreSearchHook.Results;
    }
}
