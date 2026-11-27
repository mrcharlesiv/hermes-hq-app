using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Hermes.Core.Composer;

/// The slash drawer and the @ drawer that open above the composer as you type (HermesKit/Chat/ComposerDrawerModel.swift;
/// docs/spec/3x-composer.md §9, §10). Pure: what opens for a text and caret, which rows show, what a pick does.
/// Offsets are UTF-16, as .NET strings (and the Mac's text view) count them.
public static class ComposerDrawer
{
    // ------------------------------------------------------------------ triggers

    public abstract record Mode
    {
        public sealed record Closed : Mode;
        /// The whole field is a command being typed (caret at the end).
        public sealed record Slash(string Text) : Mode;
        /// A "/word" typed after a space mid-text: skills only. Start/Length cover "/word".
        public sealed record Skill(string Word, int Start, int Length) : Mode;
        /// An "@word" before the caret: `Word` is what follows the "@". Start/Length cover "@word".
        public sealed record At(string Word, int Start, int Length) : Mode;

        public bool IsOpen => this is not Closed;

        /// A command's name is being typed ("/st", no space yet): the drawer marks its first match and Enter picks it.
        public bool MarksFirstMatch => this is Slash s && s.Text.Length > 1 && !s.Text.Any(char.IsWhiteSpace);
    }

    private static bool IsLetter(char u) => u is >= 'A' and <= 'Z' or >= 'a' and <= 'z';
    private static bool IsWord(char u) => IsLetter(u) || u is >= '0' and <= '9' || u == '_';
    private static bool IsSpace(char u) => u is '\t' or '\n' or '\v' or '\f' or '\r' or ' ' or '\u00A0' or '\u1680' or '\u2028'
        or '\u2029' or '\u202F' or '\u205F' or '\u3000' or '\uFEFF' || u is >= '\u2000' and <= '\u200A';

    /// The drawer's trigger for `text` with the caret at `caret`. The @ trigger wins when the word under the caret
    /// starts with "@".
    public static Mode ModeFor(string text, int caret)
    {
        caret = Math.Max(0, Math.Min(caret, text.Length));
        var before = text[..caret];
        if (AtTrigger(before) is { } at) return at;
        if (caret == text.Length && WholeFieldSlash(before)) return new Mode.Slash(text);
        if (InlineSkill(before) is { } skill) return skill;
        return new Mode.Closed();
    }

    /// `^(\/)((?:[a-zA-Z][\w-]*(?:\s+\S*)*)?)$`: "/" alone, or "/name" then anything after white space.
    public static bool WholeFieldSlash(string units)
    {
        if (units.Length == 0 || units[0] != '/') return false;
        if (units.Length == 1) return true;
        if (!IsLetter(units[1])) return false;
        var i = 2;
        while (i < units.Length && (IsWord(units[i]) || units[i] == '-')) i++;
        return i == units.Length || IsSpace(units[i]);
    }

    private static Mode? InlineSkill(string units)
    {
        var start = units.Length;
        while (start > 0 && (IsWord(units[start - 1]) || units[start - 1] == '-')) start--;
        if (start == 0 || units[start - 1] != '/') return null;
        var slash = start - 1;
        if (slash == 0 || !IsSpace(units[slash - 1])) return null;
        if (start < units.Length && !IsLetter(units[start])) return null;
        return new Mode.Skill(units[slash..], slash, units.Length - slash);
    }

    private static Mode? AtTrigger(string units)
    {
        var start = units.Length;
        while (start > 0 && !IsSpace(units[start - 1]) && units[start - 1] != '@') start--;
        if (start == 0 || units[start - 1] != '@') return null;
        var at = start - 1;
        if (at != 0 && !IsSpace(units[at - 1])) return null;
        return new Mode.At(units[start..], at, units.Length - at);
    }

    // ------------------------------------------------------------------ rows

    public abstract record RowAction
    {
        /// A command row (whole field): what `SlashCatalog.PickActionFor` says.
        public sealed record Command(string Name, bool Skill) : RowAction;
        /// An argument completion: the field becomes `Prefix + Text`.
        public sealed record Option(string Prefix, string Text) : RowAction;
        /// A skill typed mid-text: the "/word" becomes "/skill ".
        public sealed record SkillPick(string Name, int Start, int Length) : RowAction;
        /// An @ row: the "@word" becomes `Text` (plus a space unless it ends in ":" or "/").
        public sealed record Mention(string Text, int Start, int Length) : RowAction;
        /// "/resume <q>": open that chat.
        public sealed record OpenChat(string Id) : RowAction;
        /// The empty catalog's Check Again.
        public sealed record CheckAgain : RowAction;
        /// A loading, empty or folder-missing line: not pickable.
        public sealed record None : RowAction;
    }

    public sealed record Row(string Id, string Title, string Detail, RowAction Action, string? Parent = null, string? Bot = null,
        bool Spinner = false)
    {
        public bool Pickable => Action is not RowAction.None;
        public string SpokenLabel => Detail.Length == 0 ? Title : $"{Title}, {Detail}";
        /// Monospaced: a ref (a path, a folder, an @kind:).
        public bool RefFace => Bot == null && (Action is RowAction.Mention || (Action is RowAction.Option or RowAction.None
            && (Parent != null || Title.StartsWith('@'))));
    }

    public sealed record Section(string? Title, IReadOnlyList<Row> Rows);

    /// The command a row stars or unstars ("/name"); null for a row that is not a whole command.
    public static string? FavoriteCommand(Row row) =>
        row.Action is RowAction.Command c && SlashCatalog.Normalize(c.Name) is { Length: > 1 } n ? n : null;

    public static string FavoriteActionTitle(bool favorited) => favorited ? "Remove from Favorites" : "Add to Favorites";

    public const string LoadingCommands = "Loading commands…";
    public const string CommandsFailed = "Couldn’t load commands. Type / again to retry.";
    public const string Looking = "Looking…";
    public const string NoMatches = "No matches.";
    public const string NoCommands = "No Commands Available";
    public const string NoCommandsText = "Hermes sent no commands or skills for this chat. Skills added on the computer running Hermes show up here.";
    public const string CheckAgain = "Check Again";
    public const string FolderMissing = "This chat’s folder isn’t on the computer running Hermes.";

    public static IReadOnlyList<Section> Note(string text, bool spinner = false) =>
        [new Section(null, [new Row("note", text, "", new RowAction.None(), Spinner: spinner)])];

    public static IReadOnlyList<Section> NoCommandsNote() =>
        [new Section(null, [new Row("note", NoCommands, NoCommandsText, new RowAction.None()), new Row("check-again", CheckAgain, "", new RowAction.CheckAgain())])];

    // ------------------------------------------------------------------ gateway answers

    public sealed record Item(string Text, string? Display, string Meta, string? Kind);
    public sealed record Answer(IReadOnlyList<Item> Items, int? ReplaceFrom);

    public const int MaxItems = 200;

    /// One `complete.slash` / `complete.path` answer; items without a string `text` are dropped.
    public static Answer ParseAnswer(JsonNode? json, string asked)
    {
        var items = new List<Item>();
        foreach (var item in (json.Arr("items") ?? []).Take(MaxItems))
        {
            if (item.Str("text")?.Replace("\n", " ") is not { Length: > 0 and <= 1000 } text) continue;
            var display = item.Str("display") is { Length: > 0 } d ? d[..Math.Min(300, d.Length)].Replace("\n", " ") : null;
            var meta = item.Str("meta") ?? "";
            items.Add(new Item(text, display, meta[..Math.Min(300, meta.Length)].Replace("\n", " "), item.Str("kind")));
        }
        int? replaceFrom = null;
        if (json.Num("replace_from") is { } n && double.IsFinite(n) && n == Math.Round(n) && n >= 0 && n <= CodePoints(asked))
            replaceFrom = (int)n;
        return new Answer(items, replaceFrom);
    }

    private static int CodePoints(string s)
    {
        var n = 0;
        for (var i = 0; i < s.Length; i++) { n++; if (char.IsHighSurrogate(s[i]) && i + 1 < s.Length) i++; }
        return n;
    }

    // ------------------------------------------------------------------ the slash drawer (§9.2)

    public sealed record RecentChat(string Id, string Title);
    public static readonly HashSet<string> ChatCommands = ["resume", "sessions", "switch"];

    /// What the slash drawer shows; null = the drawer stays closed. `remote`: the gateway's answer for exactly `text`.
    /// `starredOnce`: a bare "/" lists a starred command under Favorites only (the Mac).
    public static IReadOnlyList<Section>? SlashSections(string text, CommandsCatalog? catalog, bool catalogLoading, bool catalogFailed,
        bool isBotChat, Answer? remote, IReadOnlyList<RecentChat> recent, IReadOnlyList<string>? favorites = null, bool starredOnce = true)
    {
        favorites ??= [];
        var afterSlash = text.Length > 0 ? text[1..] : "";
        var space = afterSlash.IndexOfAny([' ', '\t', '\n', '\r']);
        if (space >= 0)
        {
            var name = afterSlash[..space].ToLowerInvariant();
            if (ChatCommands.Contains(name))
            {
                var query = afterSlash[space..].Trim().ToLowerInvariant();
                var rows = recent.Where(c => query.Length == 0 || c.Title.ToLowerInvariant().Contains(query)).Take(8)
                    .Select(c => new Row("chat." + c.Id, c.Title, "", new RowAction.OpenChat(c.Id))).ToList();
                return rows.Count == 0 ? null : [new Section("Chats", rows)];
            }
            return OptionSections(text, remote);
        }
        if (catalog == null)
        {
            if (catalogLoading) return Note(LoadingCommands, spinner: true);
            return catalogFailed ? Note(CommandsFailed) : null;
        }
        var all = SlashCatalog.Sections(catalog, isBotChat, forDrawer: true);
        var noneListed = all.All(s => s.Rows.Count == 0);
        var q = afterSlash.ToLowerInvariant();
        if (q.Length == 0)
        {
            List<Section> shown;
            var starred = SlashCatalog.FavoritesSection(all, favorites);
            if (starredOnce)
            {
                var led = SlashCatalog.FavoritesLeading(all, all, favorites);
                shown = [.. led.Select((s, i) => new Section(s.Title, [.. s.Rows.Select(r => starred != null && i == 0 ? FavoriteRow(CommandRowOf(r)) : CommandRowOf(r))]))
                    .Where(s => s.Rows.Count > 0)];
            }
            else
            {
                shown = [.. all.Select(s => new Section(s.Title, [.. s.Rows.Select(CommandRowOf)])).Where(s => s.Rows.Count > 0)];
                if (starred != null) shown.Insert(0, new Section(starred.Title, [.. starred.Rows.Select(r => FavoriteRow(CommandRowOf(r)))]));
            }
            return shown.Count == 0 ? (noneListed ? NoCommandsNote() : Note(NoMatches)) : shown;
        }
        IReadOnlyList<Section> sections = remote != null ? RemoteCommandSections(remote, catalog, isBotChat) : [];
        if (sections.Count == 0) sections = Grouped(Rank([.. all.SelectMany(s => s.Rows)], q));
        sections = FavoritesFirst(sections, q, favorites);
        return sections.Count == 0 ? (noneListed ? NoCommandsNote() : Note(NoMatches)) : sections;
    }

    private static Row FavoriteRow(Row row) => row with { Id = "fav." + row.Id };

    /// Typed: in each section, the starred commands whose names start with the words go first, in starred order.
    public static IReadOnlyList<Section> FavoritesFirst(IReadOnlyList<Section> sections, string query, IReadOnlyList<string> favorites)
    {
        if (favorites.Count == 0) return sections;
        var q = query.ToLowerInvariant();
        var order = new Dictionary<string, int>();
        for (var i = 0; i < favorites.Count; i++) order.TryAdd(SlashCatalog.Normalize(favorites[i]), i);
        int? RankOf(Row row) => row.Action is RowAction.Command c && SlashCatalog.BareName(c.Name).StartsWith(q, StringComparison.Ordinal)
            && order.TryGetValue(SlashCatalog.Normalize(c.Name), out var at) ? at : null;
        return
        [
            .. sections.Select(s =>
            {
                var starred = s.Rows.Select(r => (r, k: RankOf(r))).Where(x => x.k != null).OrderBy(x => x.k).Select(x => x.r).ToList();
                if (starred.Count == 0) return s;
                var ids = starred.Select(r => r.Id).ToHashSet();
                return new Section(s.Title, [.. starred, .. s.Rows.Where(r => !ids.Contains(r.Id))]);
            }),
        ];
    }

    /// Prefix matches first, then names that contain the query; within each, catalog order.
    public static IReadOnlyList<CommandRow> Rank(IReadOnlyList<CommandRow> rows, string query)
    {
        var q = query.ToLowerInvariant();
        string Name(CommandRow r) => r.Command[1..].ToLowerInvariant();
        return [.. rows.Where(r => Name(r).StartsWith(q, StringComparison.Ordinal)),
            .. rows.Where(r => !Name(r).StartsWith(q, StringComparison.Ordinal) && Name(r).Contains(q))];
    }

    private static Row CommandRowOf(CommandRow r) => new("cmd." + r.Command, r.Command, r.Description, new RowAction.Command(r.Command, r.Skill));

    /// Commands, then Skills (each de-duplicated by name).
    private static IReadOnlyList<Section> Grouped(IReadOnlyList<CommandRow> rows)
    {
        var seen = new HashSet<string>();
        var unique = rows.Where(r => seen.Add(r.Command.ToLowerInvariant())).ToList();
        var result = new List<Section>
        {
            new("Commands", [.. unique.Where(r => !r.Skill).Select(CommandRowOf)]),
            new("Skills", [.. unique.Where(r => r.Skill).Select(CommandRowOf)]),
        };
        return [.. result.Where(s => s.Rows.Count > 0)];
    }

    /// A `complete.slash` item's command: its display when that is "/name", else "/" + its text.
    public static string CommandName(Item item)
    {
        if (item.Display?.Trim() is { } display && display.StartsWith('/') && !display.Contains(' ')) return display;
        var bare = item.Text.Trim();
        return bare.StartsWith('/') ? bare : "/" + bare;
    }

    /// The gateway's command-stage items as rows, through this app's filters.
    public static IReadOnlyList<Section> RemoteCommandSections(Answer answer, CommandsCatalog? catalog, bool isBotChat)
    {
        var rows = new List<CommandRow>();
        foreach (var item in answer.Items)
        {
            var command = CommandName(item);
            if (command.Length <= 1 || command[1..].Contains('/')) continue;
            var skill = item.Kind == "skill";
            if (!skill)
            {
                var name = SlashCatalog.BareName(command);
                if (SlashCatalog.PhoneHidden.Contains(name) || SlashCatalog.NativeUnsupported.Contains(name)) continue;
                if (catalog != null && !SlashCatalog.IsListed(command, catalog, isBotChat, forDrawer: true)) continue;
            }
            var described = SlashCatalog.DesktopDescription(command, item.Meta, catalog);
            rows.Add(new CommandRow(command, SlashCatalog.PlainDescription(command, described), skill));
        }
        return Grouped(rows);
    }

    /// The argument stage: the gateway's options only (none = closed).
    public static IReadOnlyList<Section>? OptionSections(string text, Answer? remote)
    {
        if (remote == null || remote.Items.Count == 0) return null;
        var prefix = OptionPrefix(text, remote.ReplaceFrom);
        var seen = new HashSet<string>();
        return [new Section("Options", [.. remote.Items.Where(i => seen.Add(i.Text))
            .Select(i => new Row("opt." + i.Text, i.Display ?? i.Text, i.Meta, new RowAction.Option(prefix, i.Text)))])];
    }

    /// The field up to `replace_from` (code points, as Python counts); without a usable offset, up to the last space.
    public static string OptionPrefix(string text, int? replaceFrom)
    {
        if (replaceFrom is { } from && from >= 1 && from <= CodePoints(text))
        {
            var units = 0;
            for (var n = 0; n < from; n++) units += char.IsHighSurrogate(text[units]) && units + 1 < text.Length ? 2 : 1;
            return text[..units];
        }
        var space = text.LastIndexOf(' ');
        return space < 0 ? text : text[..(space + 1)];
    }

    /// Skills for a "/word" typed mid-text (null = closed).
    public static IReadOnlyList<Section>? SkillSections(string word, int start, int length, CommandsCatalog? catalog, bool isBotChat)
    {
        if (catalog == null) return null;
        var skills = SlashCatalog.Sections(catalog, isBotChat, forDrawer: true).SelectMany(s => s.Rows).Where(r => r.Skill).ToList();
        var ranked = Rank(skills, word.Length > 0 ? word[1..] : "");
        if (ranked.Count == 0) return null;
        return [new Section("Skills", [.. ranked.Select(r => new Row("skill." + r.Command, r.Command, r.Description, new RowAction.SkillPick(r.Command, start, length)))])];
    }

    // ------------------------------------------------------------------ the @ drawer (§10.2)

    public sealed record BotEntry(string Profile, string Name);

    public static readonly (string Text, string Detail)[] Starters =
    [
        ("@file:", "Attach a file from the chat’s folder"), ("@folder:", "Attach a folder from the chat’s folder"),
        ("@url:", "Attach a web page"), ("@diff", "Changes not yet committed"), ("@staged", "Changes staged for commit"),
    ];

    public static readonly Dictionary<string, string> MetaWords = new()
    {
        ["git diff"] = "Changes not yet committed", ["staged diff"] = "Changes staged for commit",
        ["attach file"] = "Attach a file from the chat’s folder", ["attach folder"] = "Attach a folder from the chat’s folder",
        ["fetch url"] = "Attach a web page", ["git log"] = "Recent commits", ["dir"] = "Folder",
    };

    public const string MainBot = "Your main bot";
    public const string AnotherBot = "Another bot";

    public static string PlainMeta(string meta) => MetaWords.GetValueOrDefault(meta.Trim().ToLowerInvariant()) ?? meta;
    public static bool IsProfileMeta(string meta) => meta.Trim().ToLowerInvariant().StartsWith("agent profile", StringComparison.Ordinal);

    /// The handle a bot is mentioned by: its profile, and the main bot (`default`) as "hermes".
    public static string Handle(BotEntry bot, IReadOnlyList<BotEntry> bots) =>
        bot.Profile == "default" && !bots.Any(b => b.Profile.Equals("hermes", StringComparison.OrdinalIgnoreCase)) ? "hermes" : bot.Profile;

    public static string ProfileForHandle(string handle, IReadOnlyList<BotEntry> bots)
    {
        var h = handle.ToLowerInvariant();
        return h == "hermes" && !bots.Any(b => b.Profile.Equals("hermes", StringComparison.OrdinalIgnoreCase)) ? "default" : h;
    }

    public static string BotDetail(string profile, IReadOnlyList<BotEntry> bots) =>
        profile == "default" ? MainBot
            : bots.FirstOrDefault(b => b.Profile.Equals(profile, StringComparison.OrdinalIgnoreCase))?.Name ?? AnotherBot;

    /// The last path segment of a file or folder ref ("@file:src/.env" → ".env"); null for other refs.
    public static string? RefLeaf(string text)
    {
        if (!(text.StartsWith("@file:", StringComparison.Ordinal) || text.StartsWith("@folder:", StringComparison.Ordinal))) return null;
        var path = text[(text.IndexOf(':') + 1)..];
        var trimmed = path.EndsWith('/') ? path[..^1] : path;
        return trimmed.Split('/').Last();
    }

    /// The typed part after the last "/" (or after "file:").
    public static string TypedSegment(string word)
    {
        foreach (var prefix in new[] { "file:", "folder:" })
            if (word.StartsWith(prefix, StringComparison.Ordinal)) word = word[prefix.Length..];
        return word.Split('/').Last();
    }

    public static bool IsFolderQuery(string word) => word.StartsWith("file:", StringComparison.Ordinal) || word.StartsWith("folder:", StringComparison.Ordinal);

    /// Every bot but this chat's, by handle or name prefix.
    public static List<Row> BotRows(string word, IReadOnlyList<BotEntry> bots, string own, int start, int length)
    {
        var q = word.ToLowerInvariant();
        var self = (own.Length == 0 ? "default" : own).ToLowerInvariant();
        var rows = new List<Row>();
        foreach (var bot in bots.Where(b => b.Profile.ToLowerInvariant() != self))
        {
            var handle = Handle(bot, bots);
            if (q.Length > 0 && !handle.ToLowerInvariant().StartsWith(q, StringComparison.Ordinal) && !bot.Name.ToLowerInvariant().StartsWith(q, StringComparison.Ordinal)) continue;
            rows.Add(new Row("bot." + handle, "@" + handle, BotDetail(bot.Profile, bots), new RowAction.Mention("@" + handle, start, length), Bot: bot.Profile));
        }
        return rows;
    }

    private static readonly Regex MentionRx = new(@"^@[\w.-]+$");

    /// What the @ drawer shows (never null: starters and Bots are local).
    public static IReadOnlyList<Section> AtSections(string word, int start, int length, IReadOnlyList<BotEntry> bots, string own,
        Answer? remote, bool waiting, bool failed, bool folderMissing, IReadOnlyList<Section>? previous)
    {
        if (word.Length == 0)
        {
            var result = new List<Section> { new(null, [.. Starters.Select(s => new Row("start." + s.Text, s.Text, s.Detail, new RowAction.Mention(s.Text, start, length)))]) };
            var botRows0 = BotRows("", bots, own, start, length);
            if (botRows0.Count > 0) result.Add(new Section("Bots", botRows0));
            return result;
        }
        if (IsFolderQuery(word) && folderMissing) return Note(FolderMissing);
        var plainWord = !word.Contains(':') && !word.Contains('/');
        var botRows = plainWord ? BotRows(word, bots, own, start, length) : [];
        var other = new List<Row>();
        if (remote != null)
        {
            var self = (own.Length == 0 ? "default" : own).ToLowerInvariant();
            var showDots = TypedSegment(word).StartsWith('.');
            var seen = botRows.Select(r => r.Title).ToHashSet();
            foreach (var item in remote.Items)
            {
                if (!showDots && RefLeaf(item.Text) is { } leaf0 && leaf0.StartsWith('.')) continue;
                if (!seen.Add(item.Text)) continue;
                if (MentionRx.IsMatch(item.Text) && IsProfileMeta(item.Meta))
                {
                    var handle = item.Text[1..];
                    var primary = item.Meta.ToLowerInvariant().Contains("primary");
                    var profile = primary ? "default" : ProfileForHandle(handle, bots);
                    if (profile.ToLowerInvariant() == self) continue;
                    if (botRows.Any(r => r.Bot?.ToLowerInvariant() == profile.ToLowerInvariant())) continue;
                    botRows.Add(new Row("bot." + handle, item.Text, BotDetail(profile, bots), new RowAction.Mention(item.Text, start, length), Bot: profile));
                    continue;
                }
                var row = new Row("item." + item.Text, item.Display ?? item.Text, PlainMeta(item.Meta), new RowAction.Mention(item.Text, start, length));
                if (RefLeaf(item.Text) is { } leaf && item.Text.IndexOf(':') is var colon and >= 0)
                {
                    var path = item.Text[(colon + 1)..];
                    var shownLeaf = leaf + (path.EndsWith('/') ? "/" : "");
                    var parent = path[..^shownLeaf.Length];
                    row = row with { Title = shownLeaf.Length == 0 ? item.Display ?? item.Text : shownLeaf, Parent = parent.Length == 0 ? null : parent };
                }
                other.Add(row);
            }
        }
        var outList = new List<Section>();
        if (botRows.Count > 0) outList.Add(new Section("Bots", botRows));
        if (other.Count > 0) outList.Add(new Section(null, other));
        if (outList.Count > 0) return outList;
        if (remote == null && waiting && !failed) return previous is { Count: > 0 } ? previous : Note(Looking, spinner: true);
        return Note(NoMatches);
    }

    // ------------------------------------------------------------------ picks

    public sealed record Edit(string Text, int Caret);

    /// The field after an @ pick: the "@word" replaced, a space after unless the ref goes on (":" or "/").
    public static Edit ApplyMention(string reference, int start, int length, string text)
    {
        var s = Math.Min(start, text.Length);
        var l = Math.Max(0, Math.Min(length, text.Length - s));
        var insert = reference.EndsWith(':') || reference.EndsWith('/') ? reference : reference + " ";
        return new Edit(text[..s] + insert + text[(s + l)..], s + insert.Length);
    }

    /// The field after an option pick, and whether the drawer stays (the option leads to more).
    public static (Edit Edit, bool KeepOpen) ApplyOption(string prefix, string text)
    {
        var o = prefix + text;
        return (new Edit(o, o.Length), text.EndsWith(' '));
    }
}

/// The drawer's gateway calls: one at a time; an answer for a query no longer wanted is dropped.
public sealed class CompletionGate
{
    public string? InFlight { get; private set; }
    public string? Wanted { get; private set; }

    public void Want(string? key) => Wanted = key;

    public string? Next(Func<string, bool>? skip = null)
    {
        if (InFlight != null || Wanted is not { } w || skip?.Invoke(w) == true) return null;
        InFlight = w;
        return w;
    }

    /// The call for `key` ended: whether its answer is for what is wanted now.
    public bool Finished(string key)
    {
        if (InFlight == key) InFlight = null;
        if (key != Wanted) return false;
        Wanted = null;
        return true;
    }

    public void Clear() => Wanted = null;
}

/// The drawer's gateway answers and failures, by query ("slash|/mo", "path|@src/").
public sealed class CompletionMemory
{
    public static readonly TimeSpan PathAnswerFor = TimeSpan.FromSeconds(30);
    public static readonly TimeSpan FailureFor = TimeSpan.FromSeconds(5);
    public const int MaxAnswers = 100;

    private readonly Dictionary<string, (ComposerDrawer.Answer Answer, DateTimeOffset At)> _answers = [];
    private readonly Dictionary<string, DateTimeOffset> _failures = [];

    public ComposerDrawer.Answer? Answer(string key) => _answers.TryGetValue(key, out var a) ? a.Answer : null;

    public bool Failed(string key, DateTimeOffset? now = null) =>
        _failures.TryGetValue(key, out var at) && (now ?? DateTimeOffset.UtcNow) - at < FailureFor;

    public bool WantsAsk(string key, DateTimeOffset? now = null)
    {
        var t = now ?? DateTimeOffset.UtcNow;
        if (Failed(key, t)) return false;
        if (!_answers.TryGetValue(key, out var kept)) return true;
        return key.StartsWith("path|", StringComparison.Ordinal) && t - kept.At >= PathAnswerFor;
    }

    public void Remember(string key, ComposerDrawer.Answer answer, DateTimeOffset? now = null)
    {
        if (!_answers.ContainsKey(key) && _answers.Count >= MaxAnswers) _answers.Clear();
        _answers[key] = (answer, now ?? DateTimeOffset.UtcNow);
        _failures.Remove(key);
    }

    public void Fail(string key, DateTimeOffset? now = null) => _failures[key] = now ?? DateTimeOffset.UtcNow;
}
