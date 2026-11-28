using Hermes.Core.Transcripts;

namespace Hermes.Core.Settings;

/// Hermes HQ Discord invite and permanent community links (App/Pages/More/CommunityInvite.swift &
/// App/Pages/MoreViewController.swift `MoreLinksFooter`, commit `dcf89ffb1`).
public static class CommunityInvite
{
    /// Permanent Hermes HQ Discord invite URL.
    public const string DiscordUrl = "https://discord.gg/KP9cDXD6ET";

    /// Discord's official Blurple brand color.
    public const string BlurpleHex = "#5865F2";
    public const uint BlurpleRgb = 0x5865F2;
    public static readonly Rgba Blurple = Rgba.Hex(BlurpleRgb);

    /// Permanent website and repository URLs.
    public const string WebsiteUrl = "https://gethermeshq.com";
    public const string GitHubUrl = "https://github.com/mrcharlesiv/hermes-hq-app";

    /// Preference key recording that the dismissible invite card was closed (`HQCommunity.dismissedKey`).
    public const string DismissedKey = "hqn.more.discordInvite.closed";

    // Copy strings matching App/Pages/More/CommunityInvite.swift (`DiscordInviteCard`).
    public const string BannerTitle = "Join the Hermes HQ Discord";
    public const string BannerBody = "Chat with other people using Hermes HQ, share feedback and hear about new builds first. Close this and the link stays at the bottom of About.";
    public const string BannerJoinLabel = "Join the Discord";
    public const string BannerJoinHint = "Opens the Hermes HQ server in Discord.";
    public const string BannerCloseLabel = "Close";
    public const string BannerCloseHint = "Hides this card. The Discord link stays in About.";

    public const string DiscordLabel = "Discord";
    public const string WebsiteLabel = "Website";
    public const string GitHubLabel = "GitHub";

    public static IPreferences? Store { get; set; }
    public static event Action? Changed;

    public static bool IsDismissed(IPreferences? prefs) => prefs?.Get(DismissedKey) == "true";

    public static void Dismiss(IPreferences? prefs)
    {
        if (prefs == null) return;
        prefs.Set(DismissedKey, "true");
        Changed?.Invoke();
    }

    public static void Reset(IPreferences? prefs)
    {
        if (prefs == null) return;
        prefs.Set(DismissedKey, null);
        Changed?.Invoke();
    }

    public static bool CardClosed
    {
        get => IsDismissed(Store);
        set
        {
            if (Store == null) return;
            Store.Set(DismissedKey, value ? "true" : null);
            Changed?.Invoke();
        }
    }
}
