using System.Text.Json;
using Hermes.Core.Model;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Workspace;

/// The chat last on screen, as Files and Changes need it: whose it is, its stored id, its folder when the chat said
/// one, its title. Kept per account (`pages.filesChat.<account>`), as MoreChatFolderRecord.
public sealed record ChatFolderRecord(string Profile, string? SessionId, string? Cwd, string? Title)
{
    public static string Key(string account) => $"pages.filesChat.{account}";

    public static ChatFolderRecord? Read(IPreferences prefs, string account)
    {
        if (prefs.Get(Key(account)) is not { } json) return null;
        try { return JsonSerializer.Deserialize<ChatFolderRecord>(json); } catch (JsonException) { return null; }
    }

    public void Write(IPreferences prefs, string account)
    {
        var json = JsonSerializer.Serialize(this);
        if (prefs.Get(Key(account)) != json) prefs.Set(Key(account), json);
    }

    public static void Forget(IPreferences prefs, string account) => prefs.Set(Key(account), null);

    /// The folder for `profile`'s Files: this chat's own, else the folder its row on the Sessions list carries; null
    /// when the chat is another bot's or has no folder.
    public string? FolderFor(string profile, IReadOnlyDictionary<string, string?>? sessionFolders = null)
    {
        var mine = Profile.Length == 0 ? "default" : Profile;
        if (mine != (profile.Length == 0 ? "default" : profile)) return null;
        if (WorkspaceRoot.Folder(Cwd) is { } own) return own;
        if (SessionId == null || sessionFolders == null || !sessionFolders.TryGetValue(SessionId, out var row)) return null;
        return WorkspaceRoot.Folder(row);
    }

    /// The live chat's newer word on the saved record (MoreChatFolder.current): a chat often learns its folder only
    /// after it has opened.
    public static ChatFolderRecord Merge(ChatFolderRecord saved, ChatFolderRecord now)
    {
        if (now.Profile != saved.Profile || (now.SessionId != saved.SessionId && saved.SessionId != null) || now == saved) return saved;
        return now.Cwd == null ? saved with { Title = now.Title ?? saved.Title, SessionId = now.SessionId ?? saved.SessionId } : now;
    }
}

/// What the pages of one visit share (MoreWorkspace in MoreWorkspacePages.swift): the bot, the root and where it
/// comes from, the gateway user's home for "~".
public sealed class WorkspaceVisit
{
    public enum Kind { Files, Review }

    private readonly IWorkspaceRest _rest;
    private readonly IPreferences _prefs;
    private readonly Func<ChatFolderRecord?> _lastChat;

    public string Account { get; }
    public Kind PageKind { get; }
    public string Profile { get; private set; }
    public WorkspaceRoot.Root? Root { get; private set; }
    public string? ChatTitle { get; private set; }
    public string? Home { get; private set; }
    /// The bots to choose between (more than one shows the Bot picker).
    public IReadOnlyList<Bot> Bots { get; }

    public WorkspaceVisit(IWorkspaceRest rest, IPreferences prefs, string account, Kind kind, IReadOnlyList<Bot> bots,
        Func<ChatFolderRecord?> lastChat)
    {
        _rest = rest;
        _prefs = prefs;
        _lastChat = lastChat;
        Account = account;
        PageKind = kind;
        Bots = bots;
        Profile = ReadBot(prefs, account, bots);
    }

    public string Row => PageKind == Kind.Files ? "files" : "review";
    /// The chat ⋯ menu's word for the same list.
    public string Title => PageKind == Kind.Files ? "Files" : "Changes";
    public ChatWorkspace Workspace => new(_rest, Profile);
    public string? Chosen => WorkspaceRoot.Chosen(_prefs, Account, Profile);

    // MARK: The bot (MoreBotChoice "workspace", `pages.more.bot.workspace.<account>`)

    public static string BotKey(string account) => $"pages.more.bot.workspace.{account}";

    public static string ReadBot(IPreferences prefs, string account, IReadOnlyList<Bot> bots)
    {
        var saved = prefs.Get(BotKey(account));
        if (saved != null && bots.Any(b => b.Name == saved)) return saved;
        return bots.FirstOrDefault(b => b.IsDefault)?.Name ?? bots.FirstOrDefault()?.Name ?? "default";
    }

    public string BotName(string profile) => Bots.FirstOrDefault(b => b.Name == profile)?.DisplayName ?? profile;

    public void SetProfile(string next)
    {
        Profile = next;
        _prefs.Set(BotKey(Account), next);
        Root = null;
    }

    public void SetChosen(string? path)
    {
        WorkspaceRoot.SetChosen(_prefs, path, Account, Profile);
        Root = null;
    }

    /// The root by precedence; asks the gateway only when nothing is chosen and the last chat has no folder.
    public async Task<WorkspaceRoot.Root?> ResolveRootAsync(CancellationToken ct = default)
    {
        var chat = _lastChat();
        var chatFolder = chat?.FolderFor(Profile);
        ChatTitle = chatFolder == null ? null : chat?.Title;
        string? gateway = null;
        if (WorkspaceRoot.NeedsGatewayDefault(Chosen, chatFolder)) gateway = await Workspace.DefaultCwdAsync(ct);
        Root = WorkspaceRoot.Resolve(Chosen, chatFolder, gateway);
        return Root;
    }

    public async Task AskHomeAsync(CancellationToken ct = default)
    {
        if (Home != null) return;
        Home = await Workspace.HomeAsync(ct);
    }

    public string Display(string path) => WorkspaceRoot.Display(path, Home);

    /// Where Choose Folder… starts: the folder holding the root, else home, else "/".
    public string ChooserStart => Root is { } r ? WorkspaceRoot.Parent(r.Path) ?? r.Path : Home ?? "/";
}
