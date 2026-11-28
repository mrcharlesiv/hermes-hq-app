using Hermes.Core.Transcripts;

namespace Hermes.Core.Sessions;

/// One tab in the in-chat session strip (App/Chat/SessionStrip.swift `SessionStripEntry`).
public sealed record SessionStripEntry(
    string Id,
    string Title,
    bool IsBotChat,
    bool Working,
    bool Unread,
    bool Current,
    string Detail = "",
    bool Pinned = false);

/// One group in the inspector's Chats tab (App/Chat/SessionStrip.swift `BotChatGroup`, App/Mac/BotChatsPanel.swift).
public sealed record BotChatGroup(string Title, IReadOnlyList<SessionSummary> Chats);

/// A chat's project identity shown in the header subtitle for a project chat (App/Chat/ChatChrome.swift
/// `ChatProjectBadge`, 643492b44).
public sealed record ChatProjectBadge(string Name, string? Emoji = null, string? ColorKey = null);

/// Preference, filtering, settled tab ordering, and inspector Chats grouping for the in-chat session strip and
/// `BotChatsPanel` (App/Chat/SessionStrip.swift `SessionStripPref` & `SessionStripRules`, App/Mac/BotChatsPanel.swift).
public static class SessionStripRules
{
    public const string PrefKey = "hqn.sessionStrip";
    /// Maximum number of tabs shown in the strip (the current chat is always kept even if past the cap).
    public const int Most = 8;

    private static readonly IReadOnlyDictionary<string, string> EmptyBotNames = new Dictionary<string, string>();
    private static bool _fallbackEnabled = true;

    /// Backing preferences store wired by the app at startup (`FilePreferences.Shared`); when null, uses in-memory state.
    public static IPreferences? Store { get; set; }

    /// Fired whenever `IsEnabled` changes.
    public static event Action? Changed;

    /// Desktop default is on (`SessionStripPref.standard = DeviceWord.isMac`).
    public static bool Read(IPreferences? prefs) =>
        prefs == null ? _fallbackEnabled : prefs.Get(PrefKey) != "false";

    public static bool Set(IPreferences? prefs, bool on)
    {
        if (Read(prefs) == on) return false;
        _fallbackEnabled = on;
        prefs?.Set(PrefKey, on ? null : "false");
        Changed?.Invoke();
        return true;
    }

    /// Settings › Chat › Other Chats at the Top (`hqn.sessionStrip`): defaults to `true` on desktop.
    public static bool IsEnabled
    {
        get => Read(Store);
        set => Set(Store, value);
    }

    public static string NormalizeProfile(string? profile) =>
        string.IsNullOrWhiteSpace(profile) ? "default" : profile.Trim();

    public static bool SameBot(string? a, string? b) =>
        string.Equals(NormalizeProfile(a), NormalizeProfile(b), StringComparison.Ordinal);

    /// True for task-linked chats opened from Tasks (`TaskChatLinks.SessionTitle` prefixes `"Task: "`).
    public static bool IsTaskChatTitle(string? title) =>
        !string.IsNullOrEmpty(title) && title.StartsWith("Task: ", StringComparison.Ordinal);

    /// Whether the session strip may show for a chat: only on bot/session chats (never task chats or group rooms) when enabled.
    public static bool ShouldShow(bool isBotOrSessionChat, bool isTaskChat, bool isGroupRoom) =>
        ShouldShow(isBotOrSessionChat, isTaskChat, isGroupRoom, IsEnabled);

    public static bool ShouldShow(bool isBotOrSessionChat, bool isTaskChat, bool isGroupRoom, bool enabled) =>
        enabled && isBotOrSessionChat && !isTaskChat && !isGroupRoom;

    public static bool IsWorking(SessionSummary chat) =>
        chat.IsRunning || chat.Status == SessionStatus.Working;

    public static bool IsExcludedSource(string? source)
    {
        if (string.IsNullOrWhiteSpace(source)) return false;
        var clean = source.Trim();
        return string.Equals(clean, "cron", StringComparison.OrdinalIgnoreCase)
            || string.Equals(clean, "tool", StringComparison.OrdinalIgnoreCase);
    }

    public static string CompactPreview(string? preview)
    {
        if (string.IsNullOrWhiteSpace(preview)) return "";
        return string.Join(' ', preview.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)).Trim();
    }

    /// Tooltip detail for a session strip tab: active step while working, otherwise the last preview line.
    public static string TabDetail(SessionSummary chat) =>
        IsWorking(chat) ? (string.IsNullOrWhiteSpace(chat.Step) ? "Working…" : chat.Step!.Trim()) : CompactPreview(chat.Preview);

    /// Second line in `BotChatsPanel`: shown only when the chat is working or has an unread reply (quiet single-line rows otherwise).
    public static string PanelDetail(SessionSummary chat, bool current)
    {
        if (IsWorking(chat)) return string.IsNullOrWhiteSpace(chat.Step) ? "Working…" : chat.Step!.Trim();
        return chat.Unread && !current ? CompactPreview(chat.Preview) : "";
    }

    /// Every chat of the bot a person would call one (non-archived, non-cron, non-tool, excluding the bot's canonical
    /// Bot Chat), sorted newest first (`SessionStripRules.chats`).
    public static IReadOnlyList<SessionSummary> ChatsForBot(
        string profile,
        IReadOnlyList<SessionSummary> sessions,
        string? botCanonicalSessionId = null)
    {
        var norm = NormalizeProfile(profile);
        var hasCanonical = !string.IsNullOrEmpty(botCanonicalSessionId);
        return sessions
            .Select((chat, index) => (Chat: chat, Index: index))
            .Where(x => SameBot(x.Chat.Profile, norm)
                && !x.Chat.Archived
                && !IsExcludedSource(x.Chat.Source)
                && (!hasCanonical || x.Chat.Id != botCanonicalSessionId))
            .OrderByDescending(x => x.Chat.LastActive ?? DateTimeOffset.MinValue)
            .ThenBy(x => x.Index)
            .Select(x => x.Chat)
            .ToList();
    }

    /// Builds the strip's entries for a bot: pinned Bot Chat slot on the left, followed by its live/current/kept session
    /// tabs in settled order (non-archived, non-cron, non-tool, excluding `dismissedIds` unless currently open).
    public static IReadOnlyList<SessionStripEntry> TabsForBot(
        string profile,
        IReadOnlyList<SessionSummary> sessions,
        string? currentSessionId,
        IReadOnlySet<string>? dismissedIds = null,
        string? botName = null,
        string? botCanonicalSessionId = null,
        bool botWorking = false,
        bool botUnread = false,
        bool? onBotChat = null,
        IReadOnlySet<string>? keptIds = null,
        IReadOnlyList<string>? previousOrder = null)
    {
        var norm = NormalizeProfile(profile);
        var title = string.IsNullOrWhiteSpace(botName) ? SessionRules.OwnerName(norm, EmptyBotNames) : botName.Trim();
        var isOnBotChat = onBotChat ?? (string.IsNullOrEmpty(currentSessionId)
            || (!string.IsNullOrEmpty(botCanonicalSessionId) && currentSessionId == botCanonicalSessionId));

        var raw = new List<SessionStripEntry>
        {
            new(
                Id: botCanonicalSessionId ?? "",
                Title: title,
                IsBotChat: true,
                Working: botWorking,
                Unread: botUnread && !isOnBotChat,
                Current: isOnBotChat),
        };

        foreach (var chat in ChatsForBot(norm, sessions, botCanonicalSessionId))
        {
            var isCurrent = !isOnBotChat && !string.IsNullOrEmpty(currentSessionId) && chat.Id == currentSessionId;
            if (!isCurrent && dismissedIds != null && dismissedIds.Contains(chat.Id)) continue;

            var working = IsWorking(chat);
            var kept = keptIds != null && keptIds.Contains(chat.Id);
            if (!isCurrent && !kept && !working && !chat.Unread && !chat.Pinned) continue;
            if (!isCurrent && raw.Count >= Most) continue;

            raw.Add(new SessionStripEntry(
                Id: chat.Id,
                Title: chat.Title,
                IsBotChat: false,
                Working: working,
                Unread: chat.Unread && !isCurrent,
                Current: isCurrent,
                Detail: TabDetail(chat),
                Pinned: chat.Pinned));
        }

        return Settled(raw, previousOrder ?? []).Entries;
    }

    /// `[bot-tabs-ux]` Keeps surviving tabs in their prior positions while letting newly arriving tabs enter ahead of
    /// them (working first, then unread, then the rest). The pinned Bot Chat slot always leads.
    public static (IReadOnlyList<SessionStripEntry> Entries, IReadOnlyList<string> Order) Settled(
        IReadOnlyList<SessionStripEntry> entries,
        IReadOnlyList<string> previousOrder)
    {
        var botEntries = entries.Where(e => e.IsBotChat).ToList();
        var chatEntries = entries.Where(e => !e.IsBotChat).ToList();
        var known = new HashSet<string>(previousOrder, StringComparer.Ordinal);

        static int Rank(SessionStripEntry entry) => entry.Working ? 0 : entry.Unread ? 1 : 2;

        var fresh = chatEntries
            .Where(e => !known.Contains(e.Id))
            .Select((entry, index) => (Entry: entry, Index: index))
            .OrderBy(x => Rank(x.Entry))
            .ThenBy(x => x.Index)
            .Select(x => x.Entry)
            .ToList();

        var byId = new Dictionary<string, SessionStripEntry>(StringComparer.Ordinal);
        foreach (var entry in chatEntries) byId.TryAdd(entry.Id, entry);

        var old = new List<SessionStripEntry>();
        foreach (var id in previousOrder)
            if (byId.TryGetValue(id, out var kept)) old.Add(kept);

        var placed = fresh.Concat(old).ToList();
        return ([.. botEntries, .. placed], placed.Select(e => e.Id).ToList());
    }

    /// Splits settled strip entries into the pinned Bot Chat slot and the horizontally scrolling session tabs.
    public static (SessionStripEntry? Bot, IReadOnlyList<SessionStripEntry> Sessions) Split(IReadOnlyList<SessionStripEntry> entries) =>
        (entries.FirstOrDefault(e => e.IsBotChat), entries.Where(e => !e.IsBotChat).ToList());

    /// Whether the desktop strip should render: whenever the bot has other chats or live tabs, or when viewing a child
    /// session so the pinned Bot Chat tab stays one click away (`SessionStripRules.macDrawsStrip`).
    public static bool DrawsStrip(SessionStripEntry? bot, IReadOnlyList<SessionStripEntry> sessions, int otherCount, bool onBotChat) =>
        otherCount > 0 || sessions.Count > 0 || (!onBotChat && bot != null);

    /// Groups a bot's chats for the inspector's Chats tab (`BotChatsPanel`): Active (working first, then unread), Pinned,
    /// Today, Earlier. Empty groups are omitted and newest-first order is preserved within each group.
    public static IReadOnlyList<BotChatGroup> GroupsForBot(
        string profile,
        IReadOnlyList<SessionSummary> sessions,
        DateTimeOffset now,
        string? botCanonicalSessionId = null,
        TimeZoneInfo? zone = null)
    {
        var chats = ChatsForBot(profile, sessions, botCanonicalSessionId);
        DateTimeOffset todayStart;
        if (zone != null)
        {
            var localNow = TimeZoneInfo.ConvertTime(now, zone);
            todayStart = new DateTimeOffset(localNow.Date, zone.GetUtcOffset(localNow.Date));
        }
        else
        {
            todayStart = new DateTimeOffset(now.Date, now.Offset);
        }

        var working = new List<SessionSummary>();
        var unread = new List<SessionSummary>();
        var pinned = new List<SessionSummary>();
        var today = new List<SessionSummary>();
        var earlier = new List<SessionSummary>();

        foreach (var chat in chats)
        {
            if (IsWorking(chat))
            {
                working.Add(chat);
                continue;
            }
            if (chat.Unread)
            {
                unread.Add(chat);
                continue;
            }
            if (chat.Pinned)
            {
                pinned.Add(chat);
                continue;
            }
            if ((chat.LastActive ?? DateTimeOffset.MinValue) >= todayStart)
                today.Add(chat);
            else
                earlier.Add(chat);
        }

        var active = new List<SessionSummary>(working.Count + unread.Count);
        active.AddRange(working);
        active.AddRange(unread);

        var groups = new List<BotChatGroup>(4);
        if (active.Count > 0) groups.Add(new BotChatGroup("Active", active));
        if (pinned.Count > 0) groups.Add(new BotChatGroup("Pinned", pinned));
        if (today.Count > 0) groups.Add(new BotChatGroup("Today", today));
        if (earlier.Count > 0) groups.Add(new BotChatGroup("Earlier", earlier));
        return groups;
    }

    /// Resolves the project subtitle badge for a non-BotChat project session (`AppModel.updateProjectBadge`, 643492b44).
    public static ChatProjectBadge? ResolveProjectBadge(
        string profile,
        string? cwd,
        IReadOnlyDictionary<string, List<SessionProject>> projectsByProfile,
        IReadOnlyList<SessionProjectEntry> projectEntries,
        bool isBotChat,
        bool isTaskChat = false,
        bool isGroupRoom = false,
        Func<string, (string? Emoji, string? ColorKey)>? lookFor = null)
    {
        if (isBotChat || isTaskChat || isGroupRoom || string.IsNullOrWhiteSpace(cwd)) return null;
        var norm = NormalizeProfile(profile);
        var key = SessionProjects.KeyOf(cwd, norm, projectsByProfile);
        if (key == SessionProjects.HomeKey) return null;

        string? label = null;
        if (projectsByProfile.TryGetValue(norm, out var projects))
        {
            if (SessionProject.OwnerOf(cwd, projects) is { } ownerId)
                label = projects.FirstOrDefault(p => p.Id == ownerId)?.Label;
            label ??= projects.FirstOrDefault(p => SessionProjects.KeyOf(p, norm) == key)?.Label;
        }
        label ??= projectEntries.FirstOrDefault(e => e.Key == key)?.Label;
        if (string.IsNullOrWhiteSpace(label))
        {
            var trimmedKey = key.TrimEnd('/', '\\');
            var slash = trimmedKey.LastIndexOfAny(['/', '\\']);
            label = slash >= 0 ? trimmedKey[(slash + 1)..] : trimmedKey;
        }
        var cleanLabel = label.Trim();
        if (cleanLabel.Length == 0) return null;

        var look = lookFor?.Invoke(key);
        var emoji = string.IsNullOrWhiteSpace(look?.Emoji) ? null : look!.Value.Emoji!.Trim();
        var color = string.IsNullOrWhiteSpace(look?.ColorKey) ? null : look!.Value.ColorKey!.Trim();
        return new ChatProjectBadge(cleanLabel, emoji, color);
    }
}
