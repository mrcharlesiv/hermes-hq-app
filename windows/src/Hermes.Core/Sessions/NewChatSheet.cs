using System.Text.Json;
using Hermes.Core.Bots;

namespace Hermes.Core.Sessions;

// The one New Chat sheet (App/Sessions/SessionsOrganizer.swift `compose`, `presentNewChat`, `NewChatSheetView`,
// `NewChatProjectRow`, `NewChatAllProjectsView`; App/Settings/AppPreferences.swift `NewChatLast`; HermesKit
// SessionStore+OwnFolder.swift `newChatEntries`). Opened by File › New Chat With… (the Mac's ⇧⌘N, Ctrl+Shift+N here)
// and the Sessions page's Compose. Pure: the Windows sheet (Features/NewChat) draws what this decides.

/// One row the sheet can list: a saved project, or (`IsFolder`) a folder Hermes found that is no bot's own.
public sealed record NewChatEntry(string Key, string Label, bool IsFolder = false);

/// A bot the sheet can offer as a pill.
public sealed record NewChatBot(string Id, string Name, bool Hidden = false);

/// The sheet's words, exactly as the Mac's.
public static class NewChatText
{
    public const string Title = "New Chat";
    public const string BotHeading = "Bot";
    /// "In a project " with "(optional)" in regular weight after it.
    public const string ProjectHeading = "In a project ";
    public const string ProjectHeadingOptional = "(optional)";
    public const string FolderHeading = "In a folder";
    public const string Start = "Start Chat";
    public const string NewProject = "New Project…";
    public const string LastUsed = "Last used";
    public const string AllProjects = "All Projects";
    public const string AllProjectsAndFolders = "All Projects and Folders";
    public const string SearchProjects = "Search projects";
    public const string SearchProjectsAndFolders = "Search projects and folders";
    public const string NoProjectsMatch = "No projects match.";
    public const string NothingMatches = "Nothing matches.";
    public const string ProjectsHeading = "Projects";
    public const string FoldersHeading = "Folders";

    /// The Start Chat button as a screen reader says it.
    public static string StartSpoken(string botName) => $"Start Chat with {botName}";

    /// All Projects' footer.
    public static string StartsWith(string botName) => $"Starts the chat with {botName}.";

    /// [own-folder] The row and the page that hold every entry: named for what they hold.
    public static string AllTitle(IEnumerable<NewChatEntry> entries) =>
        entries.Any(e => e.IsFolder) ? AllProjectsAndFolders : AllProjects;

    public static string SearchPlaceholder(IEnumerable<NewChatEntry> entries) =>
        entries.Any(e => e.IsFolder) ? SearchProjectsAndFolders : SearchProjects;

    // The Mac's accessibility identifiers, kept as Windows automation ids.
    public const string StartId = "new-chat-start";
    public const string NewProjectId = "new-chat-project-new";
    public const string AllId = "new-chat-project-all";
    public const string SearchId = "new-chat-all-search";
    public static string BotId(string bot) => $"new-chat-bot-{bot}";
    public static string RowId(NewChatEntry e) => $"new-chat-{(e.IsFolder ? "folder" : "project")}-{e.Label}";
    public static string AllRowId(NewChatEntry e) => $"new-chat-all-{e.Label}";
}

/// What the sheet last started, on this device only (`NewChatLast`): the bot (lit next time) and, per bot, the
/// project (its row carries "Last used") and the projects it started in, newest first.
public sealed class NewChatLast(IDeviceStore store)
{
    public const string BotKey = "hqn.newChat.lastBot";
    public const string ProjectsKey = "hqn.newChat.lastProjects";
    public const string RecentsKey = "hqn.newChat.recentProjects";
    /// A sheet with this many projects or fewer lists them all; with more, `ShownWhenMany` and All Projects.
    public const int ShowAllUpTo = 6;
    public const int ShownWhenMany = 5;
    /// The stored word for No Project (a project's key is a folder path, never empty).
    public const string None = "";

    public string? Bot => store.Read(BotKey) is { } s ? Decode<string>(s) : null;

    /// The project `bot` last started in: a key, `None`, or null when it has started nothing from the sheet.
    public string? Project(string bot) => Map<string>(ProjectsKey).GetValueOrDefault(bot);

    /// The projects `bot` started chats in from the sheet, newest first.
    public IReadOnlyList<string> Recents(string bot) => Map<List<string>>(RecentsKey).GetValueOrDefault(bot) ?? [];

    public void Note(string bot, string? project)
    {
        store.Write(BotKey, JsonSerializer.Serialize(bot));
        var all = Map<string>(ProjectsKey);
        all[bot] = project ?? None;
        store.Write(ProjectsKey, JsonSerializer.Serialize(all));
        if (project == null) return;
        var recents = Map<List<string>>(RecentsKey);
        recents[bot] = new[] { project }.Concat((recents.GetValueOrDefault(bot) ?? []).Where(k => k != project)).Take(8).ToList();
        store.Write(RecentsKey, JsonSerializer.Serialize(recents));
    }

    private Dictionary<string, T> Map<T>(string key) =>
        store.Read(key) is { } s ? Decode<Dictionary<string, T>>(s) ?? [] : [];

    private static T? Decode<T>(string s)
    {
        try { return JsonSerializer.Deserialize<T>(s); }
        catch (JsonException) { return default; }
    }

    /// The projects the sheet lists, from `all` (their keys, in the list's own order): every one while there are few;
    /// with many, the `recent` ones first (newest first), filled from the list, and All Projects holds the rest.
    public static (IReadOnlyList<string> Keys, bool More) Shown(IReadOnlyList<string> all, IEnumerable<string> recent)
    {
        if (all.Count <= ShowAllUpTo) return (all, false);
        var keys = new List<string>();
        foreach (var key in recent.Concat(all))
            if (all.Contains(key) && !keys.Contains(key)) keys.Add(key);
        return (keys.Take(ShownWhenMany).ToList(), true);
    }

    /// Whether the row for `row` (null: No Project) carries "Last used", given what is stored for the bot.
    public static bool Marks(string? stored, string? row) =>
        stored != null && (stored == None ? row == null : row == stored);

    /// The bot lit when the sheet opens: the picked pill's, else the one used last while it is still offered, else
    /// Hermes, else the first.
    public static string OpensOn(string? picked, string? last, IReadOnlyList<string> ids)
    {
        if (picked != null && ids.Contains(picked)) return picked;
        if (last != null && ids.Contains(last)) return last;
        return ids.Contains("default") ? "default" : ids.FirstOrDefault() ?? "default";
    }
}

/// What Compose does before any sheet shows (`compose(profile:asksProject:)`).
public abstract record NewChatStep
{
    /// A chat at once: `bot` in `ProjectKey` (null: no project).
    public sealed record Direct(string Bot, string? ProjectKey) : NewChatStep;
    /// The sheet, lit on `Picked` when it is offered.
    public sealed record Sheet(string? Picked) : NewChatStep;
}

/// Where a pick in the sheet starts the chat.
public sealed record NewChatStart(string Bot, string? Folder);

public static class NewChatCompose
{
    /// The New Project… row (never a project's key, which is a folder path).
    public const string NewProjectTag = "\u001Fnew-project";

    /// `compose`: Filter › Project on one project starts the chat in it with no sheet; a `picked` bot from a caller
    /// that is not the go-to (or with Settings › Chat › New Chat Asks for a Project off) starts it in no project;
    /// with no bot to offer, a chat with `picked` (else Hermes) at once; else the sheet.
    public static NewChatStep Decide(IReadOnlyCollection<string> effectiveProjects, string? picked, bool asksProject,
        IReadOnlyList<NewChatBot> bots, bool projectChoiceOn = true)
    {
        if (effectiveProjects.Count == 1 && effectiveProjects.First() is var only && only != SessionProjects.HomeKey)
            return new NewChatStep.Direct(picked ?? "default", only);
        if (picked != null && !(asksProject && projectChoiceOn)) return new NewChatStep.Direct(picked, null);
        if (Offered(bots, picked).Count == 0) return new NewChatStep.Direct(picked ?? "default", null);
        return new NewChatStep.Sheet(picked);
    }

    /// The pills: hidden bots left out (Hermes and the picked one are always offered), Hermes first.
    public static IReadOnlyList<NewChatBot> Offered(IReadOnlyList<NewChatBot> bots, string? picked)
    {
        var shown = bots.Where(b => !b.Hidden || b.Id == "default" || b.Id == picked).ToList();
        return shown.Where(b => b.Id == "default").Concat(shown.Where(b => b.Id != "default")).ToList();
    }

    /// The New Chat sheet's list: saved projects, then the folders Hermes found that are no bot's own (a bot's home
    /// under `.hermes`), each A to Z as Filter › Project lists them. Favorites are always offered.
    public static List<NewChatEntry> Entries(IReadOnlyDictionary<string, List<SessionProject>> byProfile,
        IReadOnlyList<string> order, IReadOnlySet<string>? favorites = null)
    {
        var saved = new HashSet<string>();
        var own = new HashSet<string>();
        foreach (var (profile, projects) in byProfile)
            foreach (var p in projects)
            {
                var key = SessionProjects.KeyOf(p, profile);
                if (!p.IsAuto) { saved.Add(key); continue; }
                if (IsAnyProfileHome(p.Root)) own.Add(key);
            }
        var all = SessionProjects.Entries(byProfile, order);
        var listed = all.Where(e => saved.Contains(e.Key)).Select(e => new NewChatEntry(e.Key, e.Label)).ToList();
        listed.AddRange(all.Where(e => !saved.Contains(e.Key) && (!own.Contains(e.Key) || favorites?.Contains(e.Key) == true))
            .Select(e => new NewChatEntry(e.Key, e.Label, IsFolder: true)));
        return listed;
    }

    /// Some bot's home: Hermes's folder itself, or `profiles/<name>` in it (exactly).
    public static bool IsAnyProfileHome(string folder)
    {
        var parts = folder.Trim().TrimEnd('/').Split('/', StringSplitOptions.RemoveEmptyEntries);
        var hermes = Array.LastIndexOf(parts, ".hermes");
        if (hermes < 0) return false;
        var rest = parts[(hermes + 1)..];
        return rest.Length == 0 || (rest.Length == 2 && rest[0] == "profiles");
    }

    /// A bot's recent projects: favorites, then the ones the sheet started for it, then the ones its newest chats are in.
    public static IEnumerable<string> Recent(string bot, NewChatLast last, IEnumerable<SessionSummary> chats,
        IReadOnlyDictionary<string, List<SessionProject>> byProfile, IEnumerable<string>? favorites = null) =>
        (favorites ?? []).Concat(last.Recents(bot)).Concat(chats.Where(c => c.Profile == bot)
            .OrderByDescending(c => c.LastActive ?? DateTimeOffset.MinValue)
            .Select(c => SessionProjects.KeyOf(c.Cwd, bot, byProfile)));

    /// `newChat(inProject:profile:)`: the folder the chat starts in. The project's own root for that bot when it holds
    /// it; another bot's project, or a folder Hermes found, starts in the key's folder (a key is the folder). A key
    /// without a folder (`id:…`) or Home: no folder.
    public static string? Folder(string? key, string bot, IReadOnlyDictionary<string, List<SessionProject>> byProfile)
    {
        if (key == null || key == SessionProjects.HomeKey || key.StartsWith("id:", StringComparison.Ordinal)) return null;
        if (byProfile.TryGetValue(bot, out var mine) && mine.FirstOrDefault(p => SessionProjects.KeyOf(p, bot) == key) is { } held
            && held.Root.Trim().Length > 0)
            return held.Root;
        return key;
    }
}

/// One row of the sheet's project sections.
public sealed record NewChatRow(NewChatEntry Entry, bool LastUsed);

/// The sheet's list for the lit bot (`NewChatSheetView.body`).
public sealed record NewChatLayout(
    IReadOnlyList<NewChatRow> Projects, IReadOnlyList<NewChatRow> Folders,
    /// All Projects under the projects (no folder shown) or under the folders.
    bool AllUnderProjects, bool AllUnderFolders,
    /// New Project… in the projects' section (no saved project), else in a section of its own.
    bool NewProjectInProjects, string AllTitle, int AllCount);

/// The sheet's state: the pills, the lit bot, and what the list shows for it.
/// The keys the sheet's bot pills answer (the app maps its platform keys to these).
public enum NewChatKey { Other, Space, Enter }

/// What a key on a pill does: nothing of the sheet's, light that bot, or start the chat with the lit bot.
public enum NewChatKeyAction { None, Select, Start }

public sealed class NewChatSheetModel
{
    private readonly NewChatLast _last;
    private readonly Func<string, IEnumerable<string>> _recent;

    public IReadOnlyList<NewChatBot> Bots { get; }
    public IReadOnlyList<NewChatEntry> Projects { get; }
    public string Bot { get; set; }

    public NewChatSheetModel(IReadOnlyList<NewChatBot> bots, IReadOnlyList<NewChatEntry> projects, string? picked,
        NewChatLast last, Func<string, IEnumerable<string>>? recent = null)
    {
        _last = last;
        _recent = recent ?? (_ => []);
        Bots = NewChatCompose.Offered(bots, picked);
        Projects = projects;
        Bot = NewChatLast.OpensOn(picked, last.Bot, Bots.Select(b => b.Id).ToList());
    }

    public string BotName => Bots.FirstOrDefault(b => b.Id == Bot)?.Name ?? "Hermes";

    /// A key pressed on `bot`'s pill. Space lights that bot and starts nothing (the Mac's pill: `bot = item.id`);
    /// Return starts the chat with the lit bot (`NewChatKeysPage.onReturn`: `pick(box.bot, nil)`), as Start Chat does.
    public NewChatKeyAction PillKey(string bot, NewChatKey key)
    {
        switch (key)
        {
            case NewChatKey.Space when Bots.Any(b => b.Id == bot):
                Bot = bot;
                return NewChatKeyAction.Select;
            case NewChatKey.Enter:
                return NewChatKeyAction.Start;
            default:
                return NewChatKeyAction.None;
        }
    }

    /// The release of a key the sheet takes on a pill is the sheet's too: a ToggleButton clicks (and toggles) on
    /// Space's release, which would turn the lit pill off or act a second time.
    public static bool SwallowsRelease(NewChatKey key) => key is NewChatKey.Space or NewChatKey.Enter;
    public string StartSpoken => NewChatText.StartSpoken(BotName);

    public NewChatLayout Layout()
    {
        var listed = NewChatLast.Shown(Projects.Select(p => p.Key).ToList(), _recent(Bot));
        var last = _last.Project(Bot);
        var folderKeys = Projects.Where(p => p.IsFolder).Select(p => p.Key).ToHashSet();
        NewChatRow Row(string key) { var e = Projects.First(p => p.Key == key); return new(e, NewChatLast.Marks(last, key)); }
        var shownProjects = listed.Keys.Where(k => !folderKeys.Contains(k)).Select(Row).ToList();
        var shownFolders = listed.Keys.Where(folderKeys.Contains).Select(Row).ToList();
        var hasProjects = Projects.Count > folderKeys.Count;
        return new(shownProjects, shownFolders, listed.More && shownFolders.Count == 0, listed.More && shownFolders.Count > 0,
            !hasProjects, NewChatText.AllTitle(Projects), Projects.Count);
    }

    /// All Projects: every entry A to Z, saved projects then folders, narrowed by `query` (case-insensitive).
    public (IReadOnlyList<NewChatRow> Saved, IReadOnlyList<NewChatRow> Folders, string? Empty) All(string query)
    {
        var last = _last.Project(Bot);
        var words = query.Trim();
        var rows = Projects.OrderBy(p => p.Label, StringComparer.CurrentCultureIgnoreCase)
            .Where(p => words.Length == 0 || p.Label.Contains(words, StringComparison.CurrentCultureIgnoreCase))
            .Select(p => new NewChatRow(p, NewChatLast.Marks(last, p.Key))).ToList();
        var mixed = Projects.Any(p => p.IsFolder);
        string? empty = rows.Count == 0 ? (mixed ? NewChatText.NothingMatches : NewChatText.NoProjectsMatch) : null;
        return (rows.Where(r => !r.Entry.IsFolder).ToList(), rows.Where(r => r.Entry.IsFolder).ToList(), empty);
    }

    /// A pick (`project`: null for Start Chat, a key, or `NewChatCompose.NewProjectTag`): noted as the Mac notes it.
    /// New Project…: the bot's last project stays as it was (No Project stays No Project).
    public void Note(string? project)
    {
        if (project == NewChatCompose.NewProjectTag)
        {
            var kept = _last.Project(Bot);
            _last.Note(Bot, kept == NewChatLast.None ? null : kept);
            return;
        }
        _last.Note(Bot, project);
    }
}
